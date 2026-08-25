--!nonstrict
-- RaidService.luau
-- Island raids (docs/revamp-plan.md Systems §4): now and then an island's
-- own hostiles come up the beach in waves. Per-island config in Islands.luau:
--
--   Islands.items[id].raid = {
--       interval = { min, max }, -- seconds of quiet between raids
--       announce = seconds?,     -- warning countdown (default 60)
--       waves = { { { id = "creatureId", count = n }, ... }, ... },
--       timeLimit = seconds?,    -- per wave before the raid overruns you (default 240)
--       reward = { coins = { min, max }, xp = n }, -- per participant on clear
--       bountyMult = mult?,      -- kill payouts during the raid (default 0.35)
--   }
--
-- One state machine per island: idle -> announced -> wave k of N ->
-- cleared | failed -> idle. Everything spawned is an ordinary creature with
-- three flags riding the engine's `extra` bag: `raid` (participation credit
-- + the HUD), `noLinger` (a raid mob must not evaporate mid-wave; the
-- despawn sweep honours it the way it honours bosses), and `suppressDrops` +
-- `bounty` (raid kills pay reduced coins and no materials, so a raid can
-- never out-earn fishing - the payout is the CLEAR reward, split evenly to
-- everyone who landed a hit, the BossService participants shape).
--
-- The whole thing broadcasts as one RaidState remote; RaidHudController
-- filters to the island the local player is standing on.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Islands = require(Shared.Config.Islands)
local Tuning = require(Shared.Config.Tuning)
local Creatures = require(Shared.Data.Creatures)
local Remotes = require(Shared.Net.Remotes)

local CreatureService = require(script.Parent.CreatureService)
local ProgressionService = require(script.Parent.ProgressionService)
local SpawnerService = require(script.Parent.SpawnerService)

local RaidService = {}

local R = Tuning.Raid

-- islandId -> the running state machine.
type RaidState = {
	phase: string, -- "idle" | "announced" | "wave" | "breather"
	wave: number,
	endsAt: number, -- current phase's clock
	nextRaidAt: number,
	alive: { Model },
	participants: { [Player]: boolean },
}
local raids: { [string]: RaidState } = {}

local function rollInterval(config): number
	local interval = config.interval or { 480, 780 }
	return os.clock() + interval[1] + math.random() * (interval[2] - interval[1])
end

local function stateFor(islandId: string, config): RaidState
	local state = raids[islandId]
	if not state then
		state = {
			phase = "idle",
			wave = 0,
			endsAt = 0,
			nextRaidAt = rollInterval(config),
			alive = {},
			participants = {},
		}
		raids[islandId] = state
	end
	return state
end

local function broadcast(islandId: string, state: RaidState, config)
	Remotes.RaidState:FireAllClients({
		islandId = islandId,
		phase = state.phase,
		wave = state.wave,
		waves = #(config.waves or {}),
		remaining = #state.alive,
		seconds = math.max(0, math.floor(state.endsAt - os.clock() + 0.5)),
	})
end

local function pruneAlive(state: RaidState): number
	for i = #state.alive, 1, -1 do
		if state.alive[i].Parent == nil then
			table.remove(state.alive, i)
		end
	end
	return #state.alive
end

-- Hand every still-standing raid mob back to the ordinary despawn rules (a
-- failed or abandoned raid must not leave immortal mobs squatting the beach):
-- clear noLinger on the live struct and zero its fought clock, so the next
-- engine sweep reaps it.
local function releaseAlive(state: RaidState)
	for _, model in state.alive do
		local part = model:FindFirstChildWhichIsA("BasePart", true)
		local creature = part and CreatureService.findByPart(part)
		if creature then
			creature.noLinger = nil
			creature.lastFoughtAt = 0
		end
	end
	table.clear(state.alive)
end

local function startWave(islandId: string, state: RaidState, config, wave: number)
	local players = SpawnerService.playersOn(islandId)
	if #players == 0 then
		return false
	end
	state.phase = "wave"
	state.wave = wave
	state.endsAt = os.clock() + (config.timeLimit or R.WAVE_TIME_LIMIT)

	for _, entry in config.waves[wave] do
		local row = Creatures.items[entry.id]
		if not row then
			warn(string.format("[RaidService] %s raid wave %d names unknown creature %q", islandId, wave, entry.id))
			continue
		end
		for _ = 1, entry.count or 1 do
			local around = players[math.random(#players)]
			local root = around.Character and around.Character:FindFirstChild("HumanoidRootPart")
			local ground = root and SpawnerService.groundPointNear(root.Position, R.SPAWN_RING[1], R.SPAWN_RING[2])
			if ground then
				local model = CreatureService.spawn(row, ground, nil, "Neutral", {
					raid = islandId,
					noLinger = true,
					suppressDrops = true,
					bounty = config.bountyMult or R.BOUNTY,
				})
				if model then
					table.insert(state.alive, model)
				end
			end
		end
	end
	return #state.alive > 0
end

local function finish(islandId: string, state: RaidState, config, phase: string)
	releaseAlive(state)
	state.phase = phase -- "cleared" | "failed"; one broadcast, then idle
	state.endsAt = os.clock()
	broadcast(islandId, state, config)

	if phase == "cleared" and config.reward then
		local coins = config.reward.coins
		for player in state.participants do
			if player.Parent == Players then
				if coins then
					ProgressionService.addCoins(player, math.random(coins[1], coins[2]))
				end
				if config.reward.xp then
					ProgressionService.addXp(player, config.reward.xp)
				end
			end
		end
	end

	table.clear(state.participants)
	state.phase = "idle"
	state.wave = 0
	state.nextRaidAt = rollInterval(config)
end

local function step(islandId: string, config)
	local state = stateFor(islandId, config)
	local now = os.clock()

	if state.phase == "idle" then
		if now >= state.nextRaidAt and #SpawnerService.playersOn(islandId) > 0 then
			state.phase = "announced"
			state.endsAt = now + (config.announce or R.ANNOUNCE)
			broadcast(islandId, state, config)
		end
		return
	end

	-- Everyone left mid-raid: stand down quietly (failed, but nobody is
	-- there to read the banner; the broadcast still clears any stale HUD).
	if #SpawnerService.playersOn(islandId) == 0 then
		finish(islandId, state, config, "failed")
		return
	end

	if state.phase == "announced" then
		if now >= state.endsAt then
			if not startWave(islandId, state, config, 1) then
				finish(islandId, state, config, "failed")
				return
			end
		end
	elseif state.phase == "breather" then
		if now >= state.endsAt then
			if not startWave(islandId, state, config, state.wave + 1) then
				finish(islandId, state, config, "failed")
				return
			end
		end
	elseif state.phase == "wave" then
		local remaining = pruneAlive(state)
		if remaining == 0 then
			if state.wave >= #(config.waves or {}) then
				finish(islandId, state, config, "cleared")
				return
			end
			state.phase = "breather"
			state.endsAt = now + R.WAVE_BREATHER
		elseif now >= state.endsAt then
			-- The raid overran its clock: the island keeps its mobs (released
			-- to normal despawn) and the defenders get nothing.
			finish(islandId, state, config, "failed")
			return
		end
	end

	broadcast(islandId, state, config)
end

-- Participation credit: any raid mob's killer joins the payout set, exactly
-- the BossService participants shape.
local function onKilled(_row, _grade: string, killer: Player?, info)
	if type(info) ~= "table" or type(info.raid) ~= "string" then
		return
	end
	local state = raids[info.raid]
	if state and state.phase ~= "idle" and killer and killer.Parent == Players then
		state.participants[killer] = true
	end
end

-- ============================================================ lifecycle

function RaidService.init()
	CreatureService.Killed.Event:Connect(onKilled)
end

function RaidService.start()
	task.spawn(function()
		while true do
			task.wait(1)
			for islandId, entry in Islands.items do
				if entry.raid then
					step(islandId, entry.raid)
				end
			end
		end
	end)
end

return RaidService
