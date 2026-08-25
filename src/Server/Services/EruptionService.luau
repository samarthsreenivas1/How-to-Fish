--!nonstrict
-- EruptionService.luau
-- The volcano's island event (docs/revamp-plan.md Systems §4): now and then
-- the summit goes off and lava bombs rain around whoever is on the apron.
-- Each bomb is fully telegraphed - a pulsing ring on the ground (1.25s), a
-- glowing glob arcing down from the crater on the same clock - and then the
-- blast, damage falling off to the rim, exactly the spitter/bloater rule
-- (Hazards.damagePlayersInRadius, i-frame bypassed).
--
-- Everything the player sees is the EXISTING CreatureEvent vocabulary
-- (telegraph / spit / explode - CreatureEventController renders all three),
-- so this service ships no client half; the WorldEvent remote start/stop
-- (WeatherService's shape: { kind, islandId, active }) is for ambience -
-- WeatherController can rumble/tint while a window is open.
--
-- WeatherService owns recurring AMBIENT windows (blizzard: fog + spawner
-- bias, no damage); this owns the one that shoots at you. Same schedule
-- shape, different machinery - merging them would tangle bias cleanup with
-- a live bomb clock.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Islands = require(Shared.Config.Islands)
local Remotes = require(Shared.Net.Remotes)

local Hazards = require(script.Parent.Parent.Modules.Hazards)
local SpawnerService = require(script.Parent.SpawnerService)

local EruptionService = {}

local EVENT = {
	islandId = "volcano",
	kind = "eruption",
	intervalMin = 300, -- seconds of quiet between eruptions
	intervalMax = 480,
	duration = 24, -- seconds of falling bombs
	bombPeriod = 1.7, -- seconds between bombs
	telegraph = 1.25, -- ring-to-blast, the dodge window (spitter-landing rule)
	radius = 9,
	damageMin = 16,
	damageMax = 28,
	summitHeight = 850, -- where the arcing glob visually launches from
	ringMin = 5, -- bombs land this close to their mark...
	ringMax = 26, -- ...to this far, so standing still is the only mistake
}

local function bomb(event, root: BasePart)
	local landing = SpawnerService.groundPointNear(root.Position, event.ringMin, event.ringMax)
	if not landing then
		return
	end
	local entry = Islands.items[event.islandId]
	local summit = Vector3.new(entry.worldPosition.X, event.summitHeight, entry.worldPosition.Z)

	-- The tell and the falling glob share one clock, so the glob lands the
	-- moment the ring stops pulsing and the blast fires.
	Hazards.fireEvent("telegraph", landing, { kind = "slam", radius = event.radius, duration = event.telegraph })
	Hazards.fireEvent("spit", summit, { to = landing, flight = event.telegraph, arc = 60, boss = true })
	task.delay(event.telegraph, function()
		Hazards.damagePlayersInRadius(landing, event.radius, event.damageMin, event.damageMax, nil, 0.45)
		Hazards.fireEvent("explode", landing, { radius = event.radius })
	end)
end

local function eruptionWindow(event)
	Remotes.WorldEvent:FireAllClients({ kind = event.kind, islandId = event.islandId, active = true })
	local endsAt = os.clock() + event.duration
	while os.clock() < endsAt do
		local players = SpawnerService.playersOn(event.islandId)
		if #players > 0 then
			-- One bomb per period, aimed near a random person on the island
			-- (the offset ring keeps a direct hit impossible to pre-place).
			local target = players[math.random(#players)]
			local root = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
			if root then
				bomb(event, root)
			end
		end
		task.wait(event.bombPeriod)
	end
	Remotes.WorldEvent:FireAllClients({ kind = event.kind, islandId = event.islandId, active = false })
end

function EruptionService.init() end

function EruptionService.start()
	task.spawn(function()
		while true do
			task.wait(math.random(EVENT.intervalMin, EVENT.intervalMax))
			-- An eruption with nobody there is wasted thunder: hold the roll
			-- until someone is on the apron, checking each half-minute.
			while #SpawnerService.playersOn(EVENT.islandId) == 0 do
				task.wait(30)
			end
			eruptionWindow(EVENT)
		end
	end)
end

return EruptionService
