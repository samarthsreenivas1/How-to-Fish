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
local Tuning = require(Shared.Config.Tuning)
local Remotes = require(Shared.Net.Remotes)

local DataService = require(script.Parent.DataService)
local MaterialService = require(script.Parent.MaterialService)

-- ProgressionService boots below us (it listens to Killed); addCoins has no
-- init-order dependence - the QuestService precedent.
local ProgressionService = nil
local function progression()
	if not ProgressionService then
		ProgressionService = require(script.Parent.ProgressionService)
	end
	return ProgressionService
end

local CollectionService = {}

-- Reel grades, worst to best, for "best". Enraged is the OVERRIDDEN grade
-- (a botched reel or Frenzy Bait), Hooked the clean one - the log records
-- craft, not difficulty.
local GRADE_RANK: { [string]: number } = { Enraged = 1, Neutral = 2, Hooked = 3 }

-- Land every rollable species of a waters and its set completes: a one-time
-- payout plus the permanent Collection_<waters> attribute (the title badge -
-- the Heart_ precedent). NEVER revoked: a roster edit that grows a set
-- leaves old completions standing (grant idempotently, no takebacks), which
-- is the only sane reading for a collector.
local SET_REWARDS: { [string]: { coins: number, materials: { [string]: number } } } = {
	ocean = { coins = 400, materials = { pearl = 2 } },
	swamp = { coins = 900, materials = { gator_scute = 3 } },
	ice = { coins = 1600, materials = { glacier_shard = 3 } },
	volcano = { coins = 2400, materials = { obsidian_shard = 3 } },
	gloom = { coins = 3600, materials = { lantern_gland = 3 } },
	wreck = { coins = 5000, materials = { tarnished_doubloon = 4 } },
	maelstrom = { coins = 8000, materials = { storm_glass = 4 } },
}
local COLLECTION_ATTRIBUTE_PREFIX = "Collection_"

local logs: { [Player]: { [string]: { n: number, best: string, first: number } } } = {}
local completedWaters: { [Player]: { [string]: boolean } } = {}

-- Every rollable species of one waters (rarity carries a roll weight -
-- bosses and specials excluded), cached: the data tables never change at
-- runtime.
local rosterCache: { [string]: { string } } = {}
local function rosterFor(waters: string): { string }
	local cached = rosterCache[waters]
	if cached then
		return cached
	end
	local out = {}
	for id, row in Creatures.items do
		if row.waters == waters and Tuning.Rarity.WEIGHTS[row.rarity] then
			table.insert(out, id)
		end
	end
	rosterCache[waters] = out
	return out
end

local function checkCompletion(player: Player, waters: string?)
	if not waters or not SET_REWARDS[waters] then
		return
	end
	local done = completedWaters[player]
	local log = logs[player]
	if not done or not log or done[waters] then
		return
	end
	local roster = rosterFor(waters)
	if #roster == 0 then
		return
	end
	for _, speciesId in roster do
		if not log[speciesId] then
			return
		end
	end
	done[waters] = true
	player:SetAttribute(COLLECTION_ATTRIBUTE_PREFIX .. waters, true)
	local reward = SET_REWARDS[waters]
	progression().addCoins(player, reward.coins)
	for matId, amount in reward.materials do
		MaterialService.grant(player, matId, amount)
	end
	Remotes.CollectionGranted:FireClient(player, { completedWaters = waters, coins = reward.coins })
end

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
	if isFirst then
		checkCompletion(player, Creatures.items[speciesId].waters)
	end
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
	-- Two shapes: the current { species = {...}, completedWaters = {...} }
	-- and the B1-era flat { [speciesId] = entry } (accepted forever - old
	-- profiles are never wrong).
	local speciesSlice = if type(slice.species) == "table" then slice.species else slice
	if type(slice.completedWaters) == "table" then
		local done = completedWaters[player]
		for waters in slice.completedWaters do
			if SET_REWARDS[waters] and done then
				done[waters] = true
				player:SetAttribute(COLLECTION_ATTRIBUTE_PREFIX .. waters, true)
			end
		end
	end
	for speciesId, entry in speciesSlice do
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
	local species = {}
	for speciesId, entry in logs[player] or {} do
		species[speciesId] = { n = entry.n, best = entry.best, first = entry.first }
	end
	return { species = species, completedWaters = table.clone(completedWaters[player] or {}) }
end

-- ============================================================ lifecycle

local function onPlayerAdded(player: Player)
	logs[player] = {}
	completedWaters[player] = {}
	push(player)
end

function CollectionService.init()
	DataService.register("collections", {
		load = loadSlice,
		serialize = serializeSlice,
		release = function(player: Player)
			logs[player] = nil
			completedWaters[player] = nil
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
