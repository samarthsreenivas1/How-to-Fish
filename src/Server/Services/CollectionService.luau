--!nonstrict
-- CollectionService.luau
-- The fishing bestiary: every species a player has ever CAUGHT (kills
-- deliberately don't count - this is an angler's log), with how many, the
-- best reel grade it ever came up at, and when it was first landed.
--
-- State per player: { [speciesId] = { n = count, best = grade, first =
-- os.time() } }, persisted as the "collections" DataService slice (ids
-- validated against Creatures.items on load, so cut species drop out of old
-- profiles). Recording is ONE call from FishingService.resolveCast.
--
-- Replication is the materials idiom: GetCollections pulls the full table,
-- CollectionsUpdated pushes it wholesale, CollectionGranted carries the
-- delta - and its `isFirst` drives the "New species!" toast. Island set
-- completion (rewards, the Collection_<island> attribute) lands with B3.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Creatures = require(Shared.Data.Creatures)
local Remotes = require(Shared.Net.Remotes)

local DataService = require(script.Parent.DataService)

local CollectionService = {}

-- Reel grades, worst to best, for "best". Enraged is the OVERRIDDEN grade
-- (a botched reel or Frenzy Bait), Hooked the clean one - the log records
-- craft, not difficulty.
local GRADE_RANK: { [string]: number } = { Enraged = 1, Neutral = 2, Hooked = 3 }

local logs: { [Player]: { [string]: { n: number, best: string, first: number } } } = {}

local function push(player: Player)
	Remotes.CollectionsUpdated:FireClient(player, logs[player] or {})
end

-- The one recording call (FishingService.resolveCast).
function CollectionService.recordCatch(player: Player, speciesId: string, grade: string)
	local log = logs[player]
	if not log or not Creatures.items[speciesId] then
		return
	end
	local entry = log[speciesId]
	local isFirst = entry == nil
	if isFirst then
		entry = { n = 0, best = grade, first = os.time() }
		log[speciesId] = entry
	end
	entry.n += 1
	if (GRADE_RANK[grade] or 0) > (GRADE_RANK[entry.best] or 0) then
		entry.best = grade
	end
	Remotes.CollectionGranted:FireClient(player, {
		speciesId = speciesId,
		n = entry.n,
		best = entry.best,
		isFirst = isFirst,
	})
end

-- ============================================================ persistence

local function loadSlice(player: Player, slice)
	if type(slice) ~= "table" then
		return
	end
	local log = logs[player]
	if not log then
		return
	end
	for speciesId, entry in slice do
		if Creatures.items[speciesId] and type(entry) == "table" then
			local n = math.floor(tonumber(entry.n) or 0)
			if n > 0 then
				log[speciesId] = {
					n = n,
					best = if GRADE_RANK[entry.best] then entry.best else "Neutral",
					first = tonumber(entry.first) or os.time(),
				}
			end
		end
	end
	push(player)
end

local function serializeSlice(player: Player)
	local out = {}
	for speciesId, entry in logs[player] or {} do
		out[speciesId] = { n = entry.n, best = entry.best, first = entry.first }
	end
	return out
end

-- ============================================================ lifecycle

local function onPlayerAdded(player: Player)
	logs[player] = {}
	push(player)
end

function CollectionService.init()
	DataService.register("collections", {
		load = loadSlice,
		serialize = serializeSlice,
		release = function(player: Player)
			logs[player] = nil
		end,
	})
	Remotes.GetCollections.OnServerInvoke = function(player: Player)
		return logs[player] or {}
	end
end

function CollectionService.start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return CollectionService
