--!nonstrict
-- BossService.luau
-- Raises each island's boss (Bosses.luau) when a player has earned it, and
-- records the win that opens the next island.
--
-- The boss is SUMMONED, never ambient: a cast with the island's capstone
-- bait (FishingService → BossService.summonFor) raises it at the island's
-- arena for a player who is on that island, at or above the boss's level,
-- owning its rod and its weapon (the island's best gear), and hasn't beaten
-- it yet - one at a time per island - and it stays (bosses don't linger
-- out) until it's killed. The fight itself is CreatureService's "boss"
-- archetype driven by the Bosses entry; this service only decides WHEN and
-- WHERE, and what a win means:
--
--   - every player who damaged it (Killed's `participants`) gets the row's
--     rewards (the killer already gets them through ProgressionService) and
--     the replicated `Cleared_<islandId>` attribute, which WorldService's
--     travel gate reads and the client can show;
--   - a "bossDown" CreatureEvent names what just opened up.
--
-- In-memory like everything else (persistence is Slice 9): a player who
-- rejoins has to beat it again.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Islands = require(Shared.Config.Islands)
local World = require(Shared.Config.World)
local Bosses = require(Shared.Data.Bosses)
local Creatures = require(Shared.Data.Creatures)
local Progression = require(Shared.Modules.Progression)
local Remotes = require(Shared.Net.Remotes)

local CreatureService = require(script.Parent.CreatureService)
local InventoryService = require(script.Parent.InventoryService)
local ProgressionService = require(script.Parent.ProgressionService)

local BossService = {}

-- A player counts as "on" an island within its radius plus this much
-- (the dock runs well past the shoreline).
local ISLAND_MARGIN = 160

-- Attribute name for a beaten island boss.
local function clearedAttribute(islandId: string): string
	return "Cleared_" .. islandId
end

-- islandId -> the live boss Model, while one is up.
local active: { [string]: Model } = {}

-- ============================================================ gate

local function onIsland(player: Player, islandId: string): boolean
	local entry = Islands.items[islandId]
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not entry or not root then
		return false
	end
	local d = Vector3.new(root.Position.X - entry.worldPosition.X, 0, root.Position.Z - entry.worldPosition.Z).Magnitude
	return d <= entry.radius + ISLAND_MARGIN
end

-- The level gate plus whatever gear the boss's entry names (none for
-- Brinejaw: its bait is the gate). Public so a HUD can explain what's missing.
function BossService.qualifies(player: Player, boss): boolean
	local level = player:GetAttribute(Progression.ATTR.level) or Progression.START_LEVEL
	if level < boss.gate.level then
		return false
	end
	if boss.gate.rod and not InventoryService.ownsItem(player, boss.gate.rod) then
		return false
	end
	if boss.gate.weapon and not InventoryService.ownsItem(player, boss.gate.weapon) then
		return false
	end
	return true
end

function BossService.isCleared(player: Player, islandId: string): boolean
	return player:GetAttribute(clearedAttribute(islandId)) == true
end

-- ============================================================ spawning

local function arenaPosition(boss): Vector3
	local island = Islands.items[boss.islandId]
	local origin = if island then island.worldPosition else Vector3.zero
	return Vector3.new(origin.X + boss.arena.offset.X, World.WATER_Y, origin.Z + boss.arena.offset.Z)
end

local function raise(boss)
	local row = Creatures.items[boss.creature]
	if not row then
		warn(string.format("[BossService] boss %q names unknown creature row %q", boss.id, boss.creature))
		return
	end
	-- No throw target: it surfaces where it's put and the boss archetype plays
	-- its own rise from the deep (Bosses.riseDepth / riseTime).
	local model = CreatureService.spawn(row, arenaPosition(boss), nil, "Neutral")
	active[boss.islandId] = model
	model.AncestryChanged:Connect(function(_, parent)
		if parent == nil and active[boss.islandId] == model then
			active[boss.islandId] = nil
		end
	end)
end

-- The boss of the island `player` is standing on, or nil.
local function bossHere(player: Player)
	for _, boss in Bosses.items do
		if onIsland(player, boss.islandId) then
			return boss
		end
	end
	return nil
end

-- Summon the boss of the island the player is on, for that player - the
-- capstone bait's cast (FishingService calls this when a cast uses it;
-- user, 2026-08-23: "the boss should be fished up"). The bait is the ONLY
-- way it appears - there is no automatic raise - and it REPLACES the old
-- best-rod + best-weapon rule: the only gate left is the boss's level (the
-- bait's own recipe is level-locked too). Returns ok and, when not, a
-- player-facing reason so the cast can say why (the caller should only
-- consume the bait on ok).
function BossService.summonFor(player: Player): (boolean, string?)
	local boss = bossHere(player)
	if not boss then
		return false, "Nothing answers the call here"
	end
	if BossService.isCleared(player, boss.islandId) then
		return false, string.format("%s is already defeated", boss.shortName)
	end
	if active[boss.islandId] then
		return false, string.format("%s is already here", boss.shortName)
	end
	local level = player:GetAttribute(Progression.ATTR.level) or Progression.START_LEVEL
	if level < boss.gate.level then
		return false, string.format("Reach level %d", boss.gate.level)
	end
	if not BossService.qualifies(player, boss) then
		return false, "You're not ready for this" -- only reachable for a boss whose gate names gear
	end
	raise(boss)
	return true
end

-- ============================================================ the win

local function onKilled(row, _grade: string, killer: Player?, extra)
	local boss = row.boss and Bosses.items[row.boss]
	if not boss then
		return
	end

	-- Everyone who hit it shares the win (and the payout; the killer's came
	-- through ProgressionService already).
	local winners = {}
	local seen = {}
	local function add(player)
		if player and player.Parent == Players and not seen[player] then
			seen[player] = true
			table.insert(winners, player)
		end
	end
	add(killer)
	if type(extra) == "table" and type(extra.participants) == "table" then
		for _, player in extra.participants do
			add(player)
		end
	end

	local rewards = row.rewards
	for _, player in winners do
		if rewards and player ~= killer then
			ProgressionService.addCoins(player, math.random(rewards.coins[1], rewards.coins[2]))
			ProgressionService.addXp(player, rewards.xp)
		end
		player:SetAttribute(clearedAttribute(boss.islandId), true)
	end

	-- What just opened up, for the banner.
	local index = table.find(Islands.order, boss.islandId)
	local nextEntry = index and Islands.items[Islands.order[index + 1] or ""]
	Remotes.CreatureEvent:FireAllClients("bossDown", arenaPosition(boss), {
		name = boss.name,
		unlocks = nextEntry and nextEntry.name or nil,
	})
end

-- ============================================================ lifecycle

function BossService.init()
	CreatureService.Killed.Event:Connect(onKilled)
end

function BossService.start()
	-- No polling: the boss only rises when summoned (summonFor, off the
	-- capstone bait's cast). The earlier auto-raise (first qualifying player
	-- on the island) was replaced on 2026-08-23 so the summon is a deliberate
	-- ritual rather than an ambush.
end

return BossService
