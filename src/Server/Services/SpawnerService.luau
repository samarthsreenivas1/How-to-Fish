--!nonstrict
-- SpawnerService.luau
-- The game's first NON-fishing spawns (docs/revamp-plan.md Systems §4):
-- ambient hostiles that wander the islands so the world isn't empty between
-- casts. Per-island rosters live in Islands.luau:
--
--   Islands.items[id].ambient = {
--       rows = { { id = "creatureId", weight = n }, ... },
--       maxAlive = n,            -- this island's ceiling
--       interval = seconds,      -- between spawn attempts (default TICK)
--       ring = { min, max },     -- distance band from the chosen player
--   }
--
-- Every tick, each island with players present and headroom rolls one row
-- and stands it up on solid ground 60-100 studs from a random player there -
-- resting, no throw. From there the creature engine owns it completely:
-- archetype behaviour, drops, and the LINGER timer are the free cleanup (an
-- ambient mob nobody fights evaporates on its own, so the cap never silts
-- up with forgotten crabs).
--
-- The blizzard/eruption hook (Systems §4's "spawner biases flyers x3"):
-- setBias(islandId, archetype, mult) multiplies the roll weight of every
-- row of that archetype on that island until clearBias(islandId).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Islands = require(Shared.Config.Islands)
local Tuning = require(Shared.Config.Tuning)
local World = require(Shared.Config.World)
local Creatures = require(Shared.Data.Creatures)

local CreatureService = require(script.Parent.CreatureService)
local WorldService = require(script.Parent.WorldService)

local SpawnerService = {}

local S = Tuning.Spawner
local PROBE_UP, PROBE_DOWN = 300, 600

-- islandId -> { Model } of the ambient creatures this service stood up.
local alive: { [string]: { Model } } = {}
-- islandId -> os.clock() of the next allowed attempt.
local nextAttempt: { [string]: number } = {}
-- islandId -> { [archetype] = mult } (the event bias).
local biases: { [string]: { [string]: number } } = {}

-- ============================================================ event bias

function SpawnerService.setBias(islandId: string, archetype: string, mult: number)
	local set = biases[islandId] or {}
	set[archetype] = mult
	biases[islandId] = set
end

function SpawnerService.clearBias(islandId: string)
	biases[islandId] = nil
end

-- ============================================================ helpers

-- Solid ground under (x, z): the top of the island mesh (or a dock), never
-- the open sea - ambient creatures live on land, and lava/foam are
-- non-collidable so the probe can't seat anything on them. nil = open water
-- or off the map.
function SpawnerService.groundAt(x: number, z: number): Vector3?
	local worldFolder = Workspace:FindFirstChild(World.FOLDER_NAME)
	if not worldFolder then
		return nil
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { worldFolder }
	params.RespectCanCollide = true
	local hit = Workspace:Raycast(Vector3.new(x, PROBE_UP, z), Vector3.new(0, -(PROBE_UP + PROBE_DOWN), 0), params)
	if not hit or hit.Instance.Name == World.OCEAN_NAME then
		return nil
	end
	return hit.Position
end

-- A standable point in the [minDist, maxDist] band around `around`, or nil
-- after a few tries (all water / off the mesh). Shared with RaidService.
function SpawnerService.groundPointNear(around: Vector3, minDist: number, maxDist: number): Vector3?
	for _ = 1, 6 do
		local angle = math.random() * 2 * math.pi
		local dist = minDist + math.random() * (maxDist - minDist)
		local ground = SpawnerService.groundAt(around.X + math.cos(angle) * dist, around.Z + math.sin(angle) * dist)
		if ground then
			return ground
		end
	end
	return nil
end

-- The players currently on an island (root inside its footprint + margin).
function SpawnerService.playersOn(islandId: string): { Player }
	local found = {}
	for _, player in Players:GetPlayers() do
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if root then
			local here = WorldService.islandAt(root.Position, 160)
			if here == islandId then
				table.insert(found, player)
			end
		end
	end
	return found
end

local function pruneAlive(islandId: string): number
	local list = alive[islandId]
	if not list then
		return 0
	end
	for i = #list, 1, -1 do
		if list[i].Parent == nil then
			table.remove(list, i)
		end
	end
	return #list
end

local function totalAlive(): number
	local total = 0
	for islandId in alive do
		total += pruneAlive(islandId)
	end
	return total
end

-- Weighted roll over the roster, bias applied per archetype. nil on a
-- roster whose every row is unknown (content not landed yet) - the island
-- just stays quiet, which is the safe behaviour while sessions land data.
local function rollRow(islandId: string, roster)
	local bias = biases[islandId]
	local total = 0
	local weighted = {}
	for _, entry in roster do
		local row = Creatures.items[entry.id]
		if row then
			local weight = entry.weight or 1
			if bias and bias[row.archetype] then
				weight *= bias[row.archetype]
			end
			if weight > 0 then
				total += weight
				table.insert(weighted, { row = row, weight = weight })
			end
		end
	end
	if total <= 0 then
		return nil
	end
	local pick = math.random() * total
	for _, entry in weighted do
		pick -= entry.weight
		if pick <= 0 then
			return entry.row
		end
	end
	return weighted[#weighted].row
end

-- ============================================================ the sweep

local function trySpawn(islandId: string, config)
	local now = os.clock()
	if now < (nextAttempt[islandId] or 0) then
		return
	end
	nextAttempt[islandId] = now + (config.interval or S.TICK)

	if pruneAlive(islandId) >= (config.maxAlive or 8) or totalAlive() >= S.GLOBAL_CAP then
		return
	end
	local players = SpawnerService.playersOn(islandId)
	if #players == 0 then
		return
	end

	local row = rollRow(islandId, config.rows or {})
	if not row then
		return
	end

	local around = players[math.random(#players)].Character:FindFirstChild("HumanoidRootPart")
	if not around then
		return
	end
	local ring = config.ring or S.RING
	local ground = SpawnerService.groundPointNear(around.Position, ring[1], ring[2])
	if not ground then
		return
	end

	-- Resting spawn, no throw target: it surfaces where it's put, and the
	-- creature engine owns everything from here (behaviour, drops, LINGER).
	local model = CreatureService.spawn(row, ground, nil, "Neutral", { ambient = true })
	if model then
		local list = alive[islandId] or {}
		table.insert(list, model)
		alive[islandId] = list
	end
end

-- ============================================================ lifecycle

function SpawnerService.init() end

function SpawnerService.start()
	task.spawn(function()
		while true do
			task.wait(S.TICK)
			for islandId, entry in Islands.items do
				if entry.ambient then
					trySpawn(islandId, entry.ambient)
				end
			end
		end
	end)
end

return SpawnerService
