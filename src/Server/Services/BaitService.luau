--!nonstrict
-- BaitService.luau
-- Owns each player's bait: a stackable, consumable count (exactly the storage
-- model MaterialService uses) plus a single "selected bait" choice (exactly the
-- selection model InventoryService uses for the equipped rod). In-memory only
-- for now, keyed by Player and dropped on leave, like the other per-player
-- services (real persistence is a later slice).
--
-- Two halves:
--   - Counts: grant (from CraftingService when a bait recipe is crafted) and
--     spend (from FishingService, one per cast). Replicated the inventory way -
--     GetBait pulls, every change pushes BaitUpdated; BaitGranted carries just
--     the delta for the HUD pop.
--   - Selection: which bait id is active, published as the Equipment.BAIT_ATTRIBUTE
--     Player attribute so the client shows it. Orthogonal to the rod/weapon hand
--     mux (bait isn't "in hand"), so it is NOT an Equipment.KIND.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Bait = require(Shared.Data.Bait)
local Equipment = require(Shared.Config.Equipment)
local Remotes = require(Shared.Net.Remotes)

local BaitService = {}

-- player -> { [baitId]: number }
local counts: { [Player]: { [string]: number } } = {}
-- player -> baitId (the active selection), or nil for "no bait"
local selected: { [Player]: string? } = {}

-- ============================================================ granting

local function pushCounts(player: Player)
	Remotes.BaitUpdated:FireClient(player, counts[player] or {})
end

-- Adds a batch at once (one push, one pop), skipping unknown ids and
-- non-positive amounts. Returns what was actually applied, for the HUD.
local function grantBatch(player: Player, batch: { [string]: number }): { [string]: number }
	local owned = counts[player]
	if not owned then
		return {}
	end

	local applied = {}
	for baitId, amount in batch do
		amount = math.floor(amount)
		if amount > 0 and Bait.items[baitId] then
			owned[baitId] = (owned[baitId] or 0) + amount
			applied[baitId] = amount
		end
	end

	if next(applied) then
		pushCounts(player)
		Remotes.BaitGranted:FireClient(player, applied)
	end
	return applied
end

-- A single bait id, from CraftingService (amount = the recipe's yield).
function BaitService.grant(player: Player, baitId: string, amount: number)
	grantBatch(player, { [baitId] = amount })
end

-- ============================================================ queries

function BaitService.getCount(player: Player, baitId: string): number
	local owned = counts[player]
	return (owned and owned[baitId]) or 0
end

function BaitService.getAll(player: Player): { [string]: number }
	return counts[player] or {}
end

-- All-or-nothing spend, the same primitive MaterialService uses. `cost` is
-- { [baitId]: number }; FishingService spends { [selected] = 1 } per cast.
function BaitService.spend(player: Player, cost: { [string]: number }): boolean
	local owned = counts[player]
	if not owned then
		return false
	end
	for baitId, amount in cost do
		if (owned[baitId] or 0) < amount then
			return false
		end
	end
	for baitId, amount in cost do
		owned[baitId] = owned[baitId] - amount
	end
	pushCounts(player)
	return true
end

-- ============================================================ selection

-- The active bait id, or nil. FishingService reads this at cast time.
function BaitService.getSelected(player: Player): string?
	return selected[player]
end

-- Choose the active bait (or "" / nil to clear). Any real bait id is allowed
-- even at zero count: selection is intent, and a cast simply falls back to no
-- bait when the count is 0, so it resumes automatically once you craft more.
-- Mirrors InventoryService.setEquippedOf: store it and publish the attribute.
function BaitService.setSelected(player: Player, baitId: string?): boolean
	if baitId == nil or baitId == "" then
		selected[player] = nil
		player:SetAttribute(Equipment.BAIT_ATTRIBUTE, "")
		return true
	end
	if not Bait.items[baitId] then
		return false
	end
	selected[player] = baitId
	player:SetAttribute(Equipment.BAIT_ATTRIBUTE, baitId)
	return true
end

-- ============================================================ lifecycle

local function onPlayerAdded(player: Player)
	counts[player] = {}
	selected[player] = nil
	player:SetAttribute(Equipment.BAIT_ATTRIBUTE, "")
	pushCounts(player)
end

local function onPlayerRemoving(player: Player)
	counts[player] = nil
	selected[player] = nil
end

function BaitService.init()
	Remotes.GetBait.OnServerInvoke = function(player: Player)
		return counts[player] or {}
	end
	Remotes.RequestSelectBait.OnServerEvent:Connect(function(player: Player, baitId)
		if baitId ~= nil and type(baitId) ~= "string" then
			return
		end
		BaitService.setSelected(player, baitId)
	end)
end

function BaitService.start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return BaitService
