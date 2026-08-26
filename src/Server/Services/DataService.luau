--!nonstrict
-- DataService.luau
-- Persistence (Slice 9). First service in ORDER: everything else may require
-- it and register a slice of per-player state to save and restore.
--
-- One DataStore key per player holds { lock, data }:
--   - lock: { id, at } session lock. Claimed with UpdateAsync on join; a live
--     foreign lock (younger than LOCK_STALE) means another server still owns
--     this profile - we retry, then kick rather than play on data we might
--     clobber. Released on leave. A crashed server's lock simply goes stale.
--   - data: { version, <sliceKey> = <slice>..., cleared, hearts, boatTier }.
--     Slices are whatever each registered service serializes (progression,
--     inventory, materials, bait); cleared/hearts/boatTier are owned here and
--     restored straight onto Player attributes (Cleared_* / Heart_* / BoatTier).
--
-- Contract with the owning services (registered in their init()):
--   DataService.register(key, { load = fn(player, slice?), serialize = fn(player), release = fn(player) })
-- Services seed their normal defaults on PlayerAdded as before; when the
-- profile arrives (async - DataStores yield), `load` overwrites those defaults
-- and re-pushes its own remotes/attributes. `serialize` must return a plain,
-- JSON-safe table and must not yield. `release` wipes the service's
-- per-player tables, and it is called HERE, after the final serialize -
-- registered services must NOT connect their own PlayerRemoving wipe.
-- (Roblox fires a signal's connections in reverse connection order, so
-- "connect first to run first" is exactly backwards - trusting it had every
-- disconnect serialize already-wiped tables and save a default profile over
-- the real one. The 2026-08-25 review caught it; ordering now lives in this
-- one function instead of in signal-connection trivia.)
--
-- The ONLY sanctioned way to play without persistence is Studio with no
-- DataStore API access, and it warns loudly. Everywhere else a failed load
-- kicks: silently playing in-memory and then saving would overwrite the real
-- profile with defaults. Saves are skipped entirely for a player whose
-- profile never loaded.
--
-- Not saved: selected bait, what's in the hands right now, live casts and
-- creatures. Migrations: bump CURRENT_VERSION and add MIGRATIONS[v] to
-- upgrade v-1 data in place; load runs them in order.

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local DataService = {}

local STORE_NAME = "PlayerData_v1"
local CURRENT_VERSION = 1
local LOCK_STALE = 90 -- seconds; a foreign lock older than this is a crashed server's
local LOAD_ATTEMPTS = 3
local AUTOSAVE_INTERVAL = 60
local KICK_MESSAGE = "Your data is still saving from another server - please rejoin in a minute."

-- Identifies this server in locks. JobId is "" in Studio.
local SERVER_ID = if game.JobId ~= "" then game.JobId else "studio-" .. HttpService:GenerateGUID(false)

-- Attribute prefixes owned here (set by BossService, read by WorldService/UI).
local CLEARED_PREFIX = "Cleared_"
local HEART_PREFIX = "Heart_"
local BOAT_ATTR = "BoatTier"
local LOADED_ATTR = "DataLoaded"

-- Studio without API access throws RIGHT HERE, at require time - and a service
-- module that fails to load takes the entire server boot with it (init.server
-- requires every service up front, DataService first). So acquire the store
-- defensively: a nil store routes through the same load-failure path as any
-- other DataStore error, which is exactly what arms the STUDIO FALLBACK below.
local storeOk, storeOrErr = pcall(function()
	return DataStoreService:GetDataStore(STORE_NAME)
end)
local store = if storeOk then storeOrErr else nil
if not store then
	warn(
		string.format(
			"[DataService] DataStore unavailable (%s) - persistence is OFF this session. "
				.. "In Studio: File > Game Settings > Security > Enable Studio Access to API Services "
				.. "(the place must be published first).",
			tostring(storeOrErr)
		)
	)
end

-- key -> { load, serialize }, in registration (= boot) order for stable saves.
local registered: { { key: string, load: (Player, any) -> (), serialize: (Player) -> any } } = {}

-- player -> { data: table?, loaded: boolean, saveDisabled: boolean, lastSave: number }
local profiles: { [Player]: { loaded: boolean, saveDisabled: boolean, lastSave: number } } = {}

-- version -> function(data) upgrading from version-1 in place.
local MIGRATIONS: { [number]: (any) -> () } = {}

-- ============================================================ registration

function DataService.register(key: string, handlers)
	assert(type(key) == "string" and type(handlers) == "table", "[DataService] bad registration")
	assert(
		type(handlers.load) == "function" and type(handlers.serialize) == "function",
		string.format("[DataService] %q must register load + serialize", key)
	)
	table.insert(registered, {
		key = key,
		load = handlers.load,
		serialize = handlers.serialize,
		release = handlers.release,
	})
end

function DataService.isLoaded(player: Player): boolean
	local profile = profiles[player]
	return profile ~= nil and profile.loaded
end

-- ============================================================ profile <-> game

local function migrate(data)
	for v = (data.version or 0) + 1, CURRENT_VERSION do
		local step = MIGRATIONS[v]
		if step then
			step(data)
		end
	end
	data.version = CURRENT_VERSION
end

local function applyProfile(player: Player, data)
	if data then
		migrate(data)
		for _, entry in registered do
			entry.load(player, data[entry.key])
		end
		-- BoatTier BEFORE the hearts: BoatService's Heart_brinejaw watcher
		-- fires synchronously inside the hearts loop, and it must see the
		-- restored tier (not nil) or every returning owner is re-granted tier 1.
		if type(data.boatTier) == "number" and data.boatTier > 0 then
			player:SetAttribute(BOAT_ATTR, data.boatTier)
		end
		for islandId in (data.cleared or {}) do
			player:SetAttribute(CLEARED_PREFIX .. islandId, true)
		end
		for bossId in (data.hearts or {}) do
			player:SetAttribute(HEART_PREFIX .. bossId, true)
		end
	else
		-- Fresh profile: the services' PlayerAdded defaults already stand.
		for _, entry in registered do
			entry.load(player, nil)
		end
	end
	player:SetAttribute(LOADED_ATTR, true)
end

-- Must not yield: called synchronously on PlayerRemoving before the owning
-- services tear their tables down.
local function serializeProfile(player: Player)
	local data = { version = CURRENT_VERSION, cleared = {}, hearts = {} }
	for _, entry in registered do
		data[entry.key] = entry.serialize(player)
	end
	for name, value in player:GetAttributes() do
		if value == true then
			local islandId = string.match(name, "^" .. CLEARED_PREFIX .. "(.+)$")
			if islandId then
				data.cleared[islandId] = true
			end
			local bossId = string.match(name, "^" .. HEART_PREFIX .. "(.+)$")
			if bossId then
				data.hearts[bossId] = true
			end
		end
	end
	data.boatTier = player:GetAttribute(BOAT_ATTR) or 0
	return data
end

-- ============================================================ store I/O

-- Claims the session lock and returns ("ok", data) / ("locked") / ("error", err).
local function tryLoad(key: string): (string, any)
	if not store then
		return "error", "DataStore unavailable (Studio API access off?)"
	end
	local blocked = false
	local ok, result = pcall(function()
		return store:UpdateAsync(key, function(stored)
			stored = stored or {}
			local lock = stored.lock
			if lock and lock.id ~= SERVER_ID and os.time() - (lock.at or 0) < LOCK_STALE then
				blocked = true
				return nil -- cancel: someone else holds a live lock
			end
			stored.lock = { id = SERVER_ID, at = os.time() }
			return stored
		end)
	end)
	if not ok then
		return "error", result
	end
	if blocked then
		return "locked", nil
	end
	return "ok", result and result.data or nil
end

-- Writes `data` under our lock. `release` also clears the lock (leaving).
-- Skips (with a warn) if another server stole the lock - their data is newer.
local function writeProfile(key: string, data, release: boolean): boolean
	if not store then
		return false -- no store: nothing was ever loaded from it either
	end
	local stolen = false
	local ok, err = pcall(function()
		store:UpdateAsync(key, function(stored)
			stored = stored or {}
			local lock = stored.lock
			if lock and lock.id ~= SERVER_ID and os.time() - (lock.at or 0) < LOCK_STALE then
				stolen = true
				return nil
			end
			stored.data = data
			stored.lock = if release then nil else { id = SERVER_ID, at = os.time() }
			return stored
		end)
	end)
	if not ok then
		warn(string.format("[DataService] save failed for %s: %s", key, tostring(err)))
		return false
	end
	if stolen then
		warn(string.format("[DataService] lock on %s was taken by another server; skipped save", key))
		return false
	end
	return true
end

local function keyFor(player: Player): string
	return "p" .. player.UserId
end

-- ============================================================ lifecycle

local function loadPlayer(player: Player)
	local profile = { loaded = false, saveDisabled = false, lastSave = os.clock() }
	profiles[player] = profile

	local key = keyFor(player)
	local lastErr = nil
	for _ = 1, LOAD_ATTEMPTS do
		local status, result = tryLoad(key)
		if status == "ok" then
			if player.Parent ~= Players then
				-- Left while we were loading: release the lock we just took.
				writeProfile(key, result, true)
				profiles[player] = nil
				return
			end
			applyProfile(player, result)
			profile.loaded = true
			profile.lastSave = os.clock()
			return
		end
		lastErr = if status == "locked" then "profile locked by another server" else tostring(result)
		if not store then
			break -- no DataStore at all: retrying can't help, fall through to the fallback now
		end
		task.wait(if status == "locked" then 4 else 2)
	end

	if player.Parent ~= Players then
		profiles[player] = nil
		return
	end

	if RunService:IsStudio() then
		-- No API access (or Studio flakiness): play on defaults, never save.
		warn(
			string.format(
				"[DataService] STUDIO FALLBACK for %s - persistence is OFF this session (%s). "
					.. "Enable Studio API access to test saves.",
				player.Name,
				tostring(lastErr)
			)
		)
		profile.saveDisabled = true
		applyProfile(player, nil)
		profile.loaded = true
	else
		warn(string.format("[DataService] load failed for %s (%s); kicking", player.Name, tostring(lastErr)))
		player:Kick(KICK_MESSAGE)
		profiles[player] = nil
	end
end

-- Serializes NOW (synchronously), then writes. Safe to call from autosave,
-- PlayerRemoving and BindToClose alike.
local function savePlayer(player: Player, release: boolean): boolean
	local profile = profiles[player]
	if not profile or not profile.loaded or profile.saveDisabled then
		return false -- never write a profile we didn't load
	end
	local data = serializeProfile(player)
	profile.lastSave = os.clock()
	return writeProfile(keyFor(player), data, release)
end

local function onPlayerRemoving(player: Player)
	-- Serialize FIRST, then release: the registered services do not connect
	-- their own PlayerRemoving wipes (signal connections fire in reverse
	-- connection order, so no connection-order trick is trustworthy) - their
	-- `release` handlers run here, strictly after the final serialize.
	-- Serialize doesn't yield; the write can, so it moves to its own thread.
	local profile = profiles[player]
	if profile and profile.loaded and not profile.saveDisabled then
		local data = serializeProfile(player)
		local key = keyFor(player)
		task.spawn(writeProfile, key, data, true)
	end
	for _, entry in registered do
		if entry.release then
			entry.release(player)
		end
	end
	profiles[player] = nil
end

function DataService.start()
	Players.PlayerAdded:Connect(function(player)
		task.spawn(loadPlayer, player)
	end)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		task.spawn(loadPlayer, player)
	end

	-- Autosave sweep. Checking every few seconds and saving whoever is due
	-- staggers the writes naturally instead of stampeding once a minute.
	task.spawn(function()
		while true do
			task.wait(7)
			for _, player in Players:GetPlayers() do
				local profile = profiles[player]
				if
					profile
					and profile.loaded
					and not profile.saveDisabled
					and os.clock() - profile.lastSave >= AUTOSAVE_INTERVAL
				then
					savePlayer(player, false)
				end
			end
		end
	end)

	game:BindToClose(function()
		local pending = 0
		for _, player in Players:GetPlayers() do
			local profile = profiles[player]
			if profile and profile.loaded and not profile.saveDisabled then
				pending += 1
				local data = serializeProfile(player)
				local key = keyFor(player)
				profile.saveDisabled = true -- the removal handler must not double-save
				task.spawn(function()
					writeProfile(key, data, true)
					pending -= 1
				end)
			end
		end
		local deadline = os.clock() + 25
		while pending > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

return DataService
