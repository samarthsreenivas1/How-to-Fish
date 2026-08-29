--!nonstrict
-- BossArenaService.luau
-- Builds each boss's lair arena (Shared/Config/BossArenas) out in the open
-- ocean at boot, and answers "where is island X's arena" for BossService.
--
-- Two paths per arena, decided at boot:
--   * AUTHORED: a mesh group named for the arena's `model` exists under
--     ReplicatedStorage/Assets (inside IslandPack or standalone, found by its
--     `<model>_Base` part - the same convention WorldService uses for
--     islands). It is cloned, anchored, and pivoted onto the arena centre
--     with its authored bottom pinned to `meshBottom`, exactly like
--     placeIsland does for islands. Importing an arena mesh later flips this
--     path on with no code change.
--   * PROCEDURAL (the fallback, and everything this pass ships with): a flat
--     themed disc a hair above the waterline, ringed by a low palisade wall
--     so the fight can't casually spill onto open water. The wall is
--     CanQuery = false so casts and creature raycasts pass through it (the
--     island rim-wall precedent); anyone who does glitch past lands on the
--     collidable ocean surface, which is safe.
--
-- The fight itself never touches this service: the boss engine anchors to
-- wherever the boss rose (CreatureService.updateBoss takes its arena centre
-- from the spawn position), so BossService only needs centerFor and a ring
-- of drop-in points for the challengers.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BossArenas = require(Shared.Config.BossArenas)
local Bosses = require(Shared.Data.Bosses)
local World = require(Shared.Config.World)

local BossArenaService = {}

local FOLDER_NAME = "BossArenas"

-- How far past the boss's roam disc the floor runs, and the wall past that.
local FLOOR_MARGIN = 20
local FLOOR_THICKNESS = 4
-- The floor's top sits this far above the waterline: enough that the theme
-- reads over the ocean, low enough that waterline effects (the bossDown
-- burst snaps to WATER_Y) still sit on it visually.
local FLOOR_LIP = 0.15
local RIM_HEIGHT = 10
local RIM_THICKNESS = 3
local RIM_SEGMENTS = 20

-- Matches an arena's authored bottom when the mesh's HANDOFF value isn't
-- recorded - the islands' skirt convention (WorldService SKIRT_BOTTOM).
local DEFAULT_MESH_BOTTOM = -9

-- ============================================================ authored path

-- Find an arena's imported mesh group by its `<model>_Base` part, first
-- inside the IslandPack, then as a standalone Assets/<model> import - the
-- same lookup WorldService.islandTemplate does for islands.
local function arenaTemplate(arena): Instance?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if not assets then
		return nil
	end
	local pack = assets:FindFirstChild("IslandPack")
	if pack then
		local base = pack:FindFirstChild(arena.model .. "_Base", true)
		if base then
			local group: Instance = base
			while group.Parent and group.Parent ~= pack do
				group = group.Parent
			end
			if group ~= pack then
				return group
			end
		end
	end
	return assets:FindFirstChild(arena.model)
end

-- Parts the artist authored as a light source, by name marker.
--
-- Studio's glTF importer carries geometry and colour across but lands every
-- MeshPart on Material.Plastic: the emission set in Blender does not survive
-- the trip, and neither does the material NAME (Studio names a MeshPart after
-- the OBJECT it came from, so `M_Wrack_Glow` never reaches runtime). Without
-- this, the ghost-fire, the careenage lanterns, the wisps and the magma all
-- import as flat grey lumps. arena_gen.py's `_py_glow` docstring already
-- states the intent - "in game these parts are Neon, set by name at
-- placement" - this is that placement.
--
-- THE CONTRACT for the arena mesh generators: an object whose NAME contains
-- `Glow` is rendered Enum.Material.Neon. Case-sensitive, matched as a
-- substring anywhere in the name, so `<Arena>_GlowKelp` and
-- `<Arena>_LampGlow` both work. Marker on the object, never the material.
--
-- The four names after it are grandfathered: emissive objects authored
-- BEFORE this marker existed, each mirroring a name WorldService already
-- treats as emissive on the islands (Volcano_Lava, M_Wisp, Wreckwater_
-- GhostGlow). New meshes use `Glow`; when these are renamed on their next
-- export, everything below "Glow" here can go.
local GLOW_MARKERS = {
	"Glow",
	"GhostFire",
	"GhostLamp",
	"Wisp",
	"Lava",
}

local function isGlow(instanceName: string): boolean
	for _, marker in GLOW_MARKERS do
		if string.find(instanceName, marker, 1, true) then
			return true
		end
	end
	return false
end

-- Clone and place an authored arena mesh: anchor every part, pin the model's
-- bbox bottom to its authored depth, and centre its `<model>_Base` part on
-- the arena centre (the placeIsland pivot math).
local function placeAuthored(parent: Instance, arena, template: Instance)
	local model = template:Clone()
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			-- Emissive accents, by the name contract above. Colour is left to
			-- the import (the arena meshes are one flat material per object,
			-- untextured); only the material needs restoring.
			if isGlow(descendant.Name) then
				descendant.Material = Enum.Material.Neon
			end
			-- Dressing that must not catch feet or casts - the island
			-- NON_COLLIDE idea, by the arena naming convention (arena_gen.py):
			-- surf foam (which OceanController also rides on the tide),
			-- coral, plant tufts, and hanging cloth stay visual-only.
			-- `Deco` is the general form of the same rule (the Rootmere and
			-- every arena after it): an author marks a scatter object visual-
			-- only in its NAME, so it needs no import-time collision care and
			-- can never grow an invisible wall out of a convex hull.
			for _, tag in { "Deco", "Foam", "Coral", "Seaweed", "Kelp", "SailRag", "Starfish" } do
				if string.find(descendant.Name, tag, 1, true) then
					descendant.CanCollide = false
					descendant.CanQuery = false
					break
				end
			end
		end
	end

	local boxCFrame, boxSize = model:GetBoundingBox()
	local base = model:FindFirstChild(arena.model .. "_Base", true)
	local anchor = if base and base:IsA("BasePart") then base.Position else boxCFrame.Position
	local targetCenterY = (arena.meshBottom or DEFAULT_MESH_BOTTOM) + boxSize.Y / 2
	local delta =
		Vector3.new(arena.center.X - anchor.X, targetCenterY - boxCFrame.Position.Y, arena.center.Z - anchor.Z)
	model:PivotTo(model:GetPivot() + delta)
	model.Parent = parent
end

-- ============================================================ procedural path

local function buildFloor(parent: Instance, arena, radius: number)
	local floor = Instance.new("Part")
	floor.Name = arena.model .. "_Floor"
	floor.Shape = Enum.PartType.Cylinder
	-- A cylinder part's axis is X; stand it upright.
	floor.Size = Vector3.new(FLOOR_THICKNESS, radius * 2, radius * 2)
	floor.CFrame = CFrame.new(arena.center.X, World.WATER_Y + FLOOR_LIP - FLOOR_THICKNESS / 2, arena.center.Z)
		* CFrame.Angles(0, 0, math.rad(90))
	floor.Anchored = true
	floor.Color = arena.palette.floor
	floor.Material = Enum.Material.SmoothPlastic
	floor.Parent = parent
end

local function buildRim(parent: Instance, arena, radius: number)
	local chord = 2 * radius * math.sin(math.pi / RIM_SEGMENTS) * 1.06
	for i = 1, RIM_SEGMENTS do
		local angle = (i / RIM_SEGMENTS) * math.pi * 2
		local x = arena.center.X + math.cos(angle) * radius
		local z = arena.center.Z + math.sin(angle) * radius
		local segment = Instance.new("Part")
		segment.Name = arena.model .. "_Rim"
		segment.Size = Vector3.new(chord, RIM_HEIGHT, RIM_THICKNESS)
		segment.CFrame = CFrame.lookAt(
			Vector3.new(x, World.WATER_Y + RIM_HEIGHT / 2, z),
			Vector3.new(arena.center.X, World.WATER_Y + RIM_HEIGHT / 2, arena.center.Z)
		)
		segment.Anchored = true
		-- Solid to characters, invisible to raycasts: casts, creature aim,
		-- and ground probes all pass through (the island rim-wall rule).
		segment.CanQuery = false
		segment.Color = arena.palette.rim
		segment.Material = Enum.Material.SmoothPlastic
		segment.Parent = parent
	end
end

-- The fight furniture an arena's boss needs even before its authored mesh
-- lands: Brinejaw's reef stones are its slam-bait targets, so the fight is
-- unplayable without something standing there. Named to match the authored
-- objects, so the boss code finds either one the same way.
local function buildStones(parent: Instance, arena)
	for index, offset in (arena.stones or {}) do
		local stone = Instance.new("Part")
		stone.Name = arena.model .. "_ReefStone" .. index
		stone.Size = Vector3.new(5.5, 4.4, 5.5)
		stone.CFrame = CFrame.new(arena.center.X + offset.X, World.WATER_Y + 1.6, arena.center.Z + offset.Z)
			* CFrame.Angles(0, index * 1.1, 0)
		stone.Anchored = true
		stone.Color = arena.palette.rim
		stone.Material = Enum.Material.Rock
		stone.Parent = parent
	end
end

-- ============================================================ public

-- The arena centre for an island's boss, or nil when it fights in place.
function BossArenaService.centerFor(islandId: string): Vector3?
	return BossArenas.centerFor(islandId)
end

-- `count` evenly spaced drop-in CFrames on a circle of `radius` around the
-- island's arena centre, each facing the centre - where the challengers
-- land. Y clears the floor lip; physics settles them the last few studs.
function BossArenaService.ringPositions(islandId: string, count: number, radius: number): { CFrame }
	local center = BossArenas.centerFor(islandId)
	if not center then
		return {}
	end
	local ring = {}
	for i = 1, math.max(count, 1) do
		local angle = (i / math.max(count, 1)) * math.pi * 2
		local pos =
			Vector3.new(center.X + math.cos(angle) * radius, World.WATER_Y + 3.5, center.Z + math.sin(angle) * radius)
		table.insert(ring, CFrame.lookAt(pos, Vector3.new(center.X, pos.Y, center.Z)))
	end
	return ring
end

-- ============================================================ lifecycle

function BossArenaService.init()
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = Workspace

	for islandId, arena in BossArenas.items do
		local boss = Bosses.byIsland[islandId]
		local roam = if boss then boss.arena.radius else 36
		local radius = roam + FLOOR_MARGIN

		local template = arenaTemplate(arena)
		if template then
			placeAuthored(folder, arena, template)
		else
			buildFloor(folder, arena, radius)
			buildRim(folder, arena, radius)
			buildStones(folder, arena)
		end
	end
end

return BossArenaService
