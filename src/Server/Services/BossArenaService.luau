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
--   * PROCEDURAL (the fallback, and everything this pass ships with): a
--     themed floor a hair above the waterline, ringed by a low palisade wall
--     so the fight can't casually spill onto open water. The wall is
--     CanQuery = false so casts and creature raycasts pass through it (the
--     island rim-wall precedent); anyone who does glitch past lands on the
--     collidable ocean surface, which is safe.
--
--     The floor is NOT a flat disc, and the difference is mechanical rather
--     than decorative. A colossus measures its attacks against its arena's
--     ground profile, so a flat fallback silently shifts every one of those
--     heights - see POSE_ARENA below. The fallback builds to the pose's own
--     profile, and raises whatever furniture the fight is unplayable or
--     nonsensical without: Brinejaw's reef stones to bait slams onto, and the
--     lighthouse its entire body is wrapped around.
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
local BrinejawPath = require(Shared.Modules.BrinejawPath)
local World = require(Shared.Config.World)

local BossArenaService = {}

local FOLDER_NAME = "BossArenas"

-- THE POSE MODULE OWNS THE GROUND, and the procedural arena builds to it.
--
-- A colossus that stands on its arena reasons about heights in that arena's
-- frame: Brinejaw's two sweep bands, its coil clearance and its slam impacts
-- are all measured from `sandY`, the authored beach's profile. When the
-- procedural fallback was a flat disc, every one of those numbers was quietly
-- wrong by up to 2.8 studs - and the low band is only 3.4 thick, so "wrong by
-- 2.8" is most of the mechanic. Reading the profile off the pose module means
-- the fallback arena and the authored mesh present the SAME ground, so the
-- fight plays identically before and after the import.
--
-- `reach` is here for a related reason: a boss whose attacks travel further
-- than its roam disc needs floor under them, or the outer third of every
-- telegraph is drawn over open water.
local POSE_ARENA = {
	brinejaw = {
		ground = BrinejawPath.sandY,
		reach = BrinejawPath.SWEEP_REACH,
		drums = BrinejawPath.SPIRE_DRUMS,
		spireTop = BrinejawPath.SPIRE_TOP,
	},
}

-- How many nested discs approximate a ground profile. 14 puts Brinejaw's
-- 2.8-stud dome in 0.2-stud steps, which reads as a beach rather than stairs.
local FLOOR_STEPS = 14
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

-- One upright disc. A cylinder part's axis is X, so it gets stood on end.
local function disc(parent: Instance, name: string, center: Vector3, radius: number, top: number, color: Color3)
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(FLOOR_THICKNESS, radius * 2, radius * 2)
	part.CFrame = CFrame.new(center.X, top - FLOOR_THICKNESS / 2, center.Z) * CFrame.Angles(0, 0, math.rad(90))
	part.Anchored = true
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Parent = parent
	return part
end

-- The floor. Flat when the pose has no opinion, otherwise a stack of nested
-- discs whose tops follow the pose's ground profile - each disc's top is the
-- profile's height at that disc's own radius, so the smaller (higher) ones
-- pile up inward into a shallow dome. They interpenetrate by design; every
-- one is thick enough to reach below the waterline, so nothing floats.
local function buildFloor(parent: Instance, arena, radius: number, ground)
	if not ground then
		disc(parent, arena.model .. "_Floor", arena.center, radius, World.WATER_Y + FLOOR_LIP, arena.palette.floor)
		return
	end
	for step = FLOOR_STEPS, 1, -1 do
		local r = radius * (step / FLOOR_STEPS)
		disc(parent, arena.model .. "_Floor", arena.center, r, World.WATER_Y + ground(r), arena.palette.floor)
	end
end

-- The perch. Brinejaw spends the whole fight wrapped around a lighthouse, and
-- without the authored mesh there was nothing there: the coils described a
-- helix in open air, and the inner 13 studs the sweeps deliberately leave
-- alone - documented as "hugging the tower is a real, if dangerous, answer" -
-- was just free ground. Built from the same drum table the coils wrap, so the
-- stand-in cannot disagree with the body posed against it.
local function buildSpire(parent: Instance, arena, pose)
	if not pose.drums then
		return
	end
	local color = arena.palette.spire or arena.palette.rim
	for _, drum in pose.drums do
		local y0, y1, r0, r1 = drum[1], drum[2], drum[3], drum[4]
		local slices = math.max(math.floor((y1 - y0) / 4), 1)
		for i = 1, slices do
			local a, b = y0 + (y1 - y0) * ((i - 1) / slices), y0 + (y1 - y0) * (i / slices)
			local part = Instance.new("Part")
			part.Name = arena.model .. "_Spire"
			part.Shape = Enum.PartType.Cylinder
			local r = r0 + (r1 - r0) * ((i - 0.5) / slices)
			part.Size = Vector3.new(b - a, r * 2, r * 2)
			part.CFrame = CFrame.new(arena.center.X, World.WATER_Y + (a + b) / 2, arena.center.Z)
				* CFrame.Angles(0, 0, math.rad(90))
			part.Anchored = true
			part.Color = color
			part.Material = Enum.Material.Slate
			part.Parent = parent
		end
	end
	-- The gallery the head leans out over, so the silhouette reads as a
	-- lighthouse and not a chimney.
	local top = pose.spireTop or 54
	local lip = disc(parent, arena.model .. "_Gallery", arena.center, 7.6, World.WATER_Y + top + 2.2, color)
	lip.Material = Enum.Material.Slate
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
		local pose = (if boss then POSE_ARENA[boss.pose] else nil) or {}
		-- Floor out to whichever is further: the roam disc, or the furthest an
		-- attack actually travels. Brinejaw's sweeps reach 66 against a 28-stud
		-- roam, so the old roam-only rule left the outer 18 studs of every
		-- sweep marker hanging over open water.
		local radius = math.max(roam, pose.reach or 0) + FLOOR_MARGIN

		local template = arenaTemplate(arena)
		if template then
			placeAuthored(folder, arena, template)
		else
			buildFloor(folder, arena, radius, pose.ground)
			buildRim(folder, arena, radius)
			buildSpire(folder, arena, pose)
			buildStones(folder, arena)
		end
	end
end

return BossArenaService
