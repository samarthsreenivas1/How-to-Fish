--!nonstrict
-- MaterialService.luau
-- Owns each player's crafting materials, keyed by Player - the same shape as
-- InventoryService and ProgressionService. Counts persist through DataService
-- (a "materials" slice); ids that no longer exist in Materials.luau are
-- dropped on load, so cutting a material retires it from old profiles.
--
-- Two earn paths, both wired here so nothing else needs to know the rules:
--   - grantCast: called from FishingService the moment a cast resolves,
--     paying out the basic mats (Tuning.Materials.CAST_GRANT).
--   - onKilled: listens to CreatureService.Killed and drops the rare mats
--     (Tuning.Materials.KILL_BY_RARITY, scaled by the reel grade), exactly
--     mirroring how ProgressionService pays coins/XP off the same event.
--
-- Counts are a table, so they can't ride a Player attribute the way coins do;
-- they replicate the inventory way instead - GetMaterials pulls, and every
-- change pushes MaterialsUpdated. MaterialGranted carries just the delta for
-- the HUD pop. `spend` is here for the crafting slice (Slice 2); nothing
-- calls it yet.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Materials = require(Shared.Data.Materials)
local Remotes = require(Shared.Net.Remotes)
local Tuning = require(Shared.Config.Tuning)

local CreatureService = require(script.Parent.CreatureService)
local DataService = require(script.Parent.DataService)

local MaterialService = {}

local M = Tuning.Materials

-- player -> { [matId]: number }
local counts: { [Player]: { [string]: number } } = {}

local function rollRange(range): number
	return math.random(range[1], range[2])
end

-- ============================================================ granting

local function pushCounts(player: Player)
	Remotes.MaterialsUpdated:FireClient(player, counts[player] or {})
end

-- Adds a whole batch at once (one push, one pop), skipping unknown ids and
-- non-positive amounts. Returns the batch actually applied, for the HUD.
local function grantBatch(player: Player, batch: { [string]: number }): { [string]: number }
	local owned = counts[player]
	if not owned then
		return {}
	end

	local applied = {}
	for matId, amount in batch do
		amount = math.floor(amount)
		if amount > 0 and Materials.items[matId] then
			owned[matId] = (owned[matId] or 0) + amount
			applied[matId] = amount
		end
	end

	if next(applied) then
		pushCounts(player)
		Remotes.MaterialGranted:FireClient(player, applied)
	end
	return applied
end

-- A single material, from anywhere that wants to hand one out.
function MaterialService.grant(player: Player, matId: string, amount: number)
	grantBatch(player, { [matId] = amount })
end

-- The basic mats every cast pulls up. Called from FishingService.resolveCast.
-- A reward-boost bait (cast.baitEffect.rewardMult) scales the haul; nil bait /
-- no mult is the plain roll.
function MaterialService.grantCast(player: Player, cast)
	local mult = (cast and cast.baitEffect and cast.baitEffect.rewardMult) or 1
	local batch = {}
	for matId, range in M.CAST_GRANT do
		batch[matId] = math.max(1, math.floor(rollRange(range) * mult + 0.5))
	end
	grantBatch(player, batch)
end

-- The rare mats a kill drops. Mirrors ProgressionService.onKilled: bail if the
-- killer left, look the drop up by rarity, scale by the grade's rewardMult.
local function onKilled(row, grade: string, killer: Player?, info)
	if not killer or killer.Parent ~= Players then
		return
	end
	-- A spawned-from-another-kill body that must not pay materials of its own:
	-- a Magma Ooze's split halves (CreatureService sets `extra.suppressDrops`).
	-- Without this the ooze would drop its materials three times over (parent +
	-- two halves), and the per-roll `math.max(1, ...)` floor below means even a
	-- 0.4 bounty can't shrink a half's premium drop below 1. The ooze is one
	-- loot unit: the parent pays the row's drops once, the halves pay nothing.
	-- (Coins/XP for the extra fight stay with the halves' bounty in
	-- ProgressionService - this only zeroes the materials I own.)
	if type(info) == "table" and info.suppressDrops == true then
		return
	end
	-- A creature can override the rarity default with its own material drops
	-- (Creatures.luau `drops.materials`) - the same per-row override idea as
	-- ProgressionService's `rewards`. Rows without it fall back to rarity.
	local table_ = (row.drops and row.drops.materials) or M.KILL_BY_RARITY[row.rarity]
	if not table_ then
		return
	end

	local gradeTuning = Tuning.Grade[grade] or Tuning.Grade.Neutral
	local mult = gradeTuning.rewardMult or 1

	-- A "guaranteed drop" bait (Gilded Chum) maxes every material roll instead
	-- of rolling the range. The flag rides in the Killed event's 4th-arg bag,
	-- carried from the cast's spawn `extra` (the same channel bait bounty uses).
	local guaranteed = type(info) == "table" and info.guaranteedDrop == true

	-- A per-kill reward multiplier carried in the same bag (Frenzy Bait's
	-- enraged catch pays it). Applied on top of the grade, exactly as
	-- ProgressionService applies it to coins and XP.
	if type(info) == "table" and type(info.bounty) == "number" then
		mult *= info.bounty
	end

	local batch = {}
	for matId, range in table_ do
		local amount = if guaranteed then range[2] else rollRange(range)
		batch[matId] = math.max(1, math.floor(amount * mult + 0.5))
	end
	grantBatch(killer, batch)
end

-- ============================================================ salvage

-- Gravelure's haul: a cast that brings up no fish at all, paying its materials
-- straight out of the water instead. Scaled by the minigame grade like every
-- other reward, so a salvage cast is still a cast you have to play. Coins are
-- ProgressionService's to grant - FishingService does that half.
function MaterialService.grantSalvage(player: Player, mult: number)
	local batch = {}
	for matId, range in Tuning.Bait.SALVAGE_MATERIALS do
		local amount = math.floor(rollRange(range) * mult + 0.5)
		if amount > 0 then
			batch[matId] = amount
		end
	end
	return grantBatch(player, batch)
end

-- ============================================================ queries

function MaterialService.getCount(player: Player, matId: string): number
	local owned = counts[player]
	return (owned and owned[matId]) or 0
end

function MaterialService.getAll(player: Player): { [string]: number }
	return counts[player] or {}
end

-- All-or-nothing spend for crafting (Slice 2). `cost` is { [matId]: number }.
-- Returns false and changes nothing if the player is short on any material.
function MaterialService.spend(player: Player, cost: { [string]: number }): boolean
	local owned = counts[player]
	if not owned then
		return false
	end
	for matId, amount in cost do
		if (owned[matId] or 0) < amount then
			return false
		end
	end
	for matId, amount in cost do
		owned[matId] = owned[matId] - amount
	end
	pushCounts(player)
	return true
end

-- ============================================================ persistence

local function loadSlice(player: Player, slice)
	if type(slice) ~= "table" then
		return
	end
	local owned = counts[player]
	if not owned then
		return
	end
	for matId, amount in slice do
		amount = math.floor(tonumber(amount) or 0)
		if amount > 0 and Materials.items[matId] then
			owned[matId] = amount
		end
	end
	pushCounts(player)
end

local function serializeSlice(player: Player)
	return table.clone(counts[player] or {})
end

-- ============================================================ lifecycle

local function onPlayerAdded(player: Player)
	counts[player] = {}
	pushCounts(player)
end

function MaterialService.init()
	-- The per-player wipe is DataService's `release`, run after the final
	-- serialize on leave - never our own PlayerRemoving connection.
	DataService.register("materials", {
		load = loadSlice,
		serialize = serializeSlice,
		release = function(player: Player)
			counts[player] = nil
		end,
	})
	Remotes.GetMaterials.OnServerInvoke = function(player: Player)
		return counts[player] or {}
	end
	CreatureService.Killed.Event:Connect(onKilled)
end

function MaterialService.start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return MaterialService
