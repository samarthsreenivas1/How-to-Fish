--!nonstrict
-- WeatherService.luau
-- Island weather EVENTS, server-side: opens and closes timed windows (the
-- ice island's blizzard) and tells every client on the WorldEvent remote -
-- { kind, islandId, active }. The visuals are entirely the client's
-- (WeatherController fogs its own screen if it's standing there); the
-- server's half is the schedule plus the gameplay lean: while a blizzard
-- blows, the ambient spawner is biased toward the sky (flyers x3, per the
-- plan - the storm fills with wings).
--
-- Table-driven: EVENTS is one row per recurring window. The gloom island's
-- perpetual dark is NOT here - it never changes, so it's pure client
-- ambience (WeatherController keys it off position alone, no remote).
--
-- DORMANT until wired into init.server.luau's ORDER (after SpawnerService
-- exists - its setBias/clearBias is how the flyer lean lands). Late joiners
-- get the currently-active windows on PlayerAdded so they never miss the
-- fog.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)

local SpawnerService = require(script.Parent.SpawnerService)

local WeatherService = {}

-- One row per recurring weather window.
--   islandId / kind - what and where (the client matches both).
--   intervalMin/Max - seconds of clear sky between windows, rolled each time.
--   duration        - seconds a window lasts.
--   bias            - { archetype = mult } applied to the island's ambient
--                     spawner while the window is open.
local EVENTS = {
	{
		islandId = "ice",
		kind = "blizzard",
		intervalMin = 240,
		intervalMax = 420,
		duration = 90,
		bias = { flyer = 3, skythief = 3 },
	},
}

-- kind .. islandId -> true while a window is open (for late joiners).
local active: { [string]: { kind: string, islandId: string } } = {}

local function keyFor(event): string
	return event.kind .. ":" .. event.islandId
end

local function setActive(event, on: boolean)
	local key = keyFor(event)
	if on then
		active[key] = { kind = event.kind, islandId = event.islandId }
	else
		active[key] = nil
	end
	Remotes.WorldEvent:FireAllClients({ kind = event.kind, islandId = event.islandId, active = on })
	if event.bias then
		for archetype, mult in event.bias do
			if on then
				SpawnerService.setBias(event.islandId, archetype, mult)
			end
		end
		if not on then
			SpawnerService.clearBias(event.islandId)
		end
	end
end

local function runEvent(event)
	while true do
		task.wait(math.random(event.intervalMin, event.intervalMax))
		setActive(event, true)
		task.wait(event.duration)
		setActive(event, false)
	end
end

function WeatherService.init()
	Players.PlayerAdded:Connect(function(player)
		for _, window in active do
			Remotes.WorldEvent:FireClient(player, { kind = window.kind, islandId = window.islandId, active = true })
		end
	end)
end

function WeatherService.start()
	for _, event in EVENTS do
		task.spawn(runEvent, event)
	end
end

return WeatherService
