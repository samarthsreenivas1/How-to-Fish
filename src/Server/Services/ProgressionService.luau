--!nonstrict
-- ProgressionService.luau
-- Coins, XP and levels. Owns the numbers for every player, pays out when a
-- creature dies, and publishes the totals as replicated attributes on the
-- Player so the HUD (and anything else) reads them without a remote.
--
-- State lives in `states` and persists through DataService: this service
-- registers a load/serialize pair for its slice, so a rejoining player
-- resumes their coins, XP and level.
--
-- Payout is data, not code: Tuning.Rewards.BY_RARITY (or a row's own
-- `rewards`) times the reel grade's rewardMult. The only thing this service
-- decides is who gets paid - the killer CreatureService reports, if they're
-- still in the game.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Progression = require(Shared.Modules.Progression)
local Remotes = require(Shared.Net.Remotes)
local Tuning = require(Shared.Config.Tuning)

local CreatureService = require(script.Parent.CreatureService)
local DataService = require(script.Parent.DataService)

local ProgressionService = {}

local ATTR = Progression.ATTR
local P = Tuning.Progression

-- Player -> { coins, xp, level }
local states: { [Player]: { coins: number, xp: number, level: number } } = {}

-- ============================================================ state

local function publish(player: Player, state)
	player:SetAttribute(ATTR.coins, state.coins)
	player:SetAttribute(ATTR.xp, state.xp)
	player:SetAttribute(ATTR.level, state.level)
	player:SetAttribute(ATTR.xpToNext, Progression.xpToNext(state.level))
end

local function ensure(player: Player)
	local state = states[player]
	if not state then
		state = { coins = P.START_COINS, xp = 0, level = P.START_LEVEL }
		states[player] = state
		publish(player, state)
	end
	return state
end

-- ============================================================ API

function ProgressionService.getState(player: Player)
	local state = ensure(player)
	return { coins = state.coins, xp = state.xp, level = state.level }
end

function ProgressionService.addCoins(player: Player, amount: number)
	local state = ensure(player)
	state.coins = math.max(0, state.coins + math.floor(amount + 0.5))
	publish(player, state)
end

-- False (and no change) if they can't afford it. For the shop later.
function ProgressionService.spendCoins(player: Player, amount: number): boolean
	local state = ensure(player)
	amount = math.floor(amount + 0.5)
	if amount < 0 or state.coins < amount then
		return false
	end
	state.coins -= amount
	publish(player, state)
	return true
end

-- Adds XP, rolling over as many levels as it clears. Returns how many
-- levels were gained (0 most of the time).
function ProgressionService.addXp(player: Player, amount: number): number
	local state = ensure(player)
	state.xp += math.max(0, math.floor(amount + 0.5))

	local gained = 0
	while state.level < Progression.MAX_LEVEL do
		local needed = Progression.xpToNext(state.level)
		if state.xp < needed then
			break
		end
		state.xp -= needed
		state.level += 1
		gained += 1
	end
	if state.level >= Progression.MAX_LEVEL then
		-- Capped: the bar just sits full.
		state.xp = math.min(state.xp, Progression.xpToNext(state.level))
	end

	publish(player, state)
	return gained
end

-- ============================================================ payout

-- What a kill of `row` at reel `grade` is worth: (coins, xp).
local function rewardFor(row, grade: string): (number, number)
	local base = row.rewards or Tuning.Rewards.BY_RARITY[row.rarity]
	if not base then
		warn(string.format("[ProgressionService] no reward table for rarity %q (creature %s)", row.rarity, row.id))
		return 0, 0
	end

	local gradeTuning = Tuning.Grade[grade] or Tuning.Grade.Neutral
	local mult = gradeTuning.rewardMult or 1

	local coins = math.random(base.coins[1], base.coins[2]) * mult
	local xp = base.xp * mult
	return math.floor(coins + 0.5), math.floor(xp + 0.5)
end

local function onKilled(row, grade: string, killer: Player?, extra)
	if not killer or killer.Parent ~= Players then
		return -- despawned on its own, or the killer already left
	end

	local coins, xp = rewardFor(row, grade)

	-- A pickpocket's haul comes back with a bonus. CreatureService passes the
	-- coins it was carrying as Killed's 4th value ({ loot = n }).
	local loot = if type(extra) == "table" and type(extra.loot) == "number" then extra.loot else 0
	if loot > 0 then
		coins += math.floor(loot * (1 + Tuning.Creature.THIEF_BONUS) + 0.5)
	end

	-- A per-kill reward multiplier riding the same bag, set by the bait that
	-- spawned it (Frenzy Bait's enraged catch pays about double). MaterialService
	-- applies the same field to the material drop.
	local bounty = if type(extra) == "table" and type(extra.bounty) == "number" then extra.bounty else 1
	if bounty ~= 1 then
		coins = math.floor(coins * bounty + 0.5)
		xp = math.floor(xp * bounty + 0.5)
	end

	ProgressionService.addCoins(killer, coins)
	local levelsGained = ProgressionService.addXp(killer, xp)

	Remotes.RewardGranted:FireClient(killer, {
		coins = coins,
		xp = xp,
		creature = row.name,
		levelsGained = levelsGained,
	})
end

-- ============================================================ persistence

-- DataService slice: the whole state table, restored over the join defaults.
local function loadSlice(player: Player, slice)
	if type(slice) ~= "table" then
		return -- fresh profile: keep the ensure() defaults
	end
	local state = ensure(player)
	state.coins = math.max(0, math.floor(tonumber(slice.coins) or state.coins))
	state.xp = math.max(0, math.floor(tonumber(slice.xp) or state.xp))
	state.level = math.clamp(math.floor(tonumber(slice.level) or state.level), P.START_LEVEL, Progression.MAX_LEVEL)
	publish(player, state)
end

local function serializeSlice(player: Player)
	local state = ensure(player)
	return { coins = state.coins, xp = state.xp, level = state.level }
end

-- ============================================================ lifecycle

function ProgressionService.init()
	CreatureService.Killed.Event:Connect(onKilled)
	DataService.register("progression", { load = loadSlice, serialize = serializeSlice })
end

function ProgressionService.start()
	Players.PlayerAdded:Connect(ensure)
	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		ensure(player)
	end
end

return ProgressionService
