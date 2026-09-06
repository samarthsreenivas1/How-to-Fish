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
local MeshColors = require(Shared.Config.MeshColors)
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
		-- How far out `ground` still describes ground. The floor runs further
		-- (the sweeps need it), but past this the arena is boundary rocks and
		-- foam, which are correctly placed and correctly not the beach.
		groundTo = 70,
		reach = BrinejawPath.SWEEP_REACH,
		drums = BrinejawPath.SPIRE_DRUMS,
		spireTop = BrinejawPath.SPIRE_TOP,
	},
}

-- How many nested discs approximate a ground profile.
--
-- 48, not the 14 this started at, and the reason is `verifyGround` below
-- rather than looks. Sampled densely rather than at a few radii, 14 discs sit
-- up to 0.597 studs off the profile where it bends fastest - which is MORE
-- than the half stud a wrong `meshBottom` costs, so no tolerance could have
-- told the two apart. 48 brings the approximation to 0.232 and leaves a clean
-- band. (Both of those are measured; the "0.2-stud steps" this comment used to
-- claim was an estimate, and it was wrong.)
local FLOOR_STEPS = 48
-- How many radii `verifyGround` samples, and how far the floor may sit from
-- the profile before it says so. 0.30 is above the fallback's own 0.232 of
-- stepping and below the 0.5 a wrong `meshBottom` costs, so it separates a
-- real misplacement from the approximation instead of straddling both.
local GROUND_PROBES = 12
-- ...and how many bearings at each radius. The beach is the LOWEST thing a
-- ray can land on out there, so taking the smallest drift across four
-- bearings finds it even when one of them is blocked by a reef stone.
local GROUND_BEARINGS = 4
-- How far a walkable surface may dip under the waterline before it is called
-- out. Small but non-zero: an arena whose outermost sand meets the sea at
-- exactly zero is correct and common, and float noise on a raycast against a
-- near-flush face should not be a warning.
local WATERLINE_TOLERANCE = 0.25
local GROUND_TOLERANCE = 0.30
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

-- Roblox's default part colour, and therefore what a part looks like when
-- nothing has coloured it. Compared EXACTLY, not by proximity: an authored
-- stone or sand colour never lands on this precise triplet, so an exact test
-- has no false positives while a "looks greyish" test would have many.
local DEFAULT_PART_GREY = Color3.fromRGB(163, 162, 165)

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
	local uncoloured, uncolouredName = 0, nil
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			-- REPAINT, then relight.
			--
			-- Studio's glTF importer does NOT carry colour across - every part
			-- arrives at Roblox's default grey, which is why the first import
			-- of the Tidebreak came up entirely flat, arena and boss alike.
			-- This file used to assert the opposite in a comment; the import
			-- settled it. `MeshColors` is GENERATED from the builders
			-- themselves (tools/gen_mesh_colors.py) rather than typed, because
			-- a hand-kept table is exactly where parts go missing silently -
			-- the islet half of WorldService's equivalent shipped 33 rows
			-- short with every gate green.
			local color = MeshColors.get(descendant.Name)
			if color then
				descendant.Color = color
				descendant.Material = Enum.Material.SmoothPlastic
				-- A textured PBR surface overrides Color outright. The packs
				-- are one flat material per object and never author one, so
				-- anything the importer attached is noise (the island rule).
				local appearance = descendant:FindFirstChildWhichIsA("SurfaceAppearance")
				if appearance then
					appearance:Destroy()
				end
			elseif descendant.Color == DEFAULT_PART_GREY then
				-- No row, and it still looks like an un-painted import. Counted
				-- and named below: a part added to a builder without
				-- regenerating the table reports itself instead of leaving
				-- someone to notice one grey rock.
				uncoloured += 1
				uncolouredName = uncolouredName or descendant.Name
			end
			-- Emissive accents, by the name contract above - AFTER the repaint,
			-- so the material assignment above cannot undo it.
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
	if uncoloured > 0 then
		warn(
			string.format(
				"[BossArenaService] %s has %d imported part(s) with no MeshColors row, still at the "
					.. "importer's default grey (first: %q). Run `python3 tools/gen_mesh_colors.py` - a "
					.. "builder gained an object and the generated table has not been refreshed.",
				arena.model,
				uncoloured,
				uncolouredName
			)
		)
	end
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

-- DOES THE ARENA WE ACTUALLY PLACED PRESENT THE GROUND THE FIGHT ASSUMES?
--
-- Every height a posed colossus reasons about is measured from its pose
-- module's profile. If the floor lands at the wrong height - one wrong
-- `meshBottom`, one decorative object that quietly became the model's bbox
-- floor, one generator constant that drifted from the build - then every one
-- of those numbers is off by the same amount and NOTHING says so. The fight
-- just plays wrong: sweeps that pass over a standing player, a slam that
-- resolves in the air. That is not hypothetical. A 3.47-stud anchor error did
-- exactly that to Brinejaw across 79% of its floor, and a wrong `meshBottom`
-- produces the identical symptom from an unrelated cause - which is the point,
-- because it means the symptom cannot tell you which one you have.
--
-- So probe the thing that got built and compare it to the profile it is
-- supposed to be. A handful of raycasts, once, at boot. It turns a silent
-- misplacement into a line naming the radius and the size of the error.
--
-- It runs on the PROCEDURAL path too, deliberately. That path builds from the
-- profile by construction, so it should always pass - and a checker that only
-- ever runs against the case it expects to fail is a checker nobody has
-- watched succeed. This way boot exercises it every time.
-- NOTHING WALKABLE MAY SIT BELOW THE WATERLINE, because the ocean is already
-- there and it is solid.
--
-- WorldService builds the sea as a grid of tiles centred at `WATER_Y - 2` with
-- `Size.Y = 4`, so their TOP FACE is exactly `World.WATER_Y`; the shared part
-- helper leaves `CanCollide = true`, and the WATER collision group is
-- non-collidable with BOATS only. Players stand on it. Nothing carves those
-- tiles under an arena. So a basin authored below zero is not a basin at
-- runtime - it is filled to the brim and a player walks across the lid.
--
-- Found by bd's audit on two SHIPPED arenas: the Rootmere's mere at -3.4 is a
-- painted puddle you stroll over, and the Choirfloor's pit at -7.5 is filled
-- so completely that Noctyss rises through a floor players are standing on.
-- Both survived every gate, both owning lanes' reviews, and a rendered
-- preview - because each mesh is exactly as authored. It fails only in
-- composition with a system nobody was thinking about, and it reads as "the
-- arena looks right" until somebody stands in it.
--
-- THE RULE IS NOT "no geometry below zero". Several arenas deliberately drown
-- decorative geometry outside the play area - the Careenage's awash flat, the
-- grounded fleet lying in it, six studs past its walkable sand. Forbidding
-- that outright would break authored content. So this probes only out to the
-- fight's own radius and says nothing about what lies beyond it.
--
-- It deliberately does NOT run inside `verifyGround`: that one returns early
-- unless the boss declares a ground profile, which today is Brinejaw alone -
-- so it would have missed both of the arenas that actually have this bug.
local function verifyWaterline(arena, folder: Instance, walkable: number)
	if walkable <= 0 then
		return
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { folder }
	local deepest, deepestAt = 0, 0
	for step = 1, GROUND_PROBES do
		local r = walkable * (step / GROUND_PROBES)
		for bearing = 0, GROUND_BEARINGS - 1 do
			local theta = (bearing / GROUND_BEARINGS) * math.pi * 2
			local from = Vector3.new(
				arena.center.X + math.cos(theta) * r,
				World.WATER_Y + 200,
				arena.center.Z + math.sin(theta) * r
			)
			local hit = Workspace:Raycast(from, Vector3.new(0, -400, 0), params)
			-- The DEEPEST surface, not the shallowest: a pit is what fills, and
			-- taking a minimum across bearings would let one dry bearing hide it.
			if hit then
				local under = World.WATER_Y - hit.Position.Y
				if under > deepest then
					deepest, deepestAt = under, r
				end
			end
		end
	end
	if deepest > WATERLINE_TOLERANCE then
		warn(
			string.format(
				"[BossArenaService] %s has walkable surface %.2f studs BELOW the waterline at "
					.. "r=%.0f. The ocean is a solid slab whose top face is exactly WATER_Y and "
					.. "nothing carves it under an arena, so that basin is filled to the brim at "
					.. "runtime - players walk across the lid and anything rising from it comes up "
					.. "through a floor. Raise the profile, or carve the tiles under this arena.",
				arena.model,
				deepest,
				deepestAt
			)
		)
	end
end

local function verifyGround(arena, pose, folder: Instance, radius: number)
	if not pose.ground then
		return
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { folder }
	-- ONLY WHERE THE PROFILE CLAIMS SOMETHING, and on more than one bearing.
	--
	-- Both of those are corrections to the first version of this function, and
	-- both are the same mistake f9 hit measuring NPC pads: a wrong probe is not
	-- silent, it SUCCEEDS. It strikes real geometry on a real object and hands
	-- back a plausible height, so the instrument you built to stop yourself
	-- trusting assertions quietly starts producing assertions of its own.
	--
	-- Here it took two forms. The floor runs to `radius` (86 for Brinejaw,
	-- because the sweeps reach 66 and need floor under them) but `sandY` only
	-- describes the beach out to 70 - so a quarter of the probes were landing
	-- in the boundary rocks and the foam ring, which are correctly placed and
	-- correctly NOT the beach. And a single bearing means any one object on
	-- that line - a reef stone, a sea stack - reads as a placement error.
	--
	-- So: stop at the profile's own extent, and at each radius take the
	-- SMALLEST drift across several bearings. A real misplacement shifts every
	-- bearing equally and still fires; one rock on one bearing no longer does.
	-- A checker that cries wolf is worse than no checker, because the first
	-- false alarm is what teaches everyone to ignore the true one.
	local reach = math.min(radius, pose.groundTo or radius)
	local worst, worstAt = 0, 0
	local probes = 0
	for step = 1, GROUND_PROBES do
		local r = reach * (step / GROUND_PROBES)
		local best = nil
		for bearing = 0, GROUND_BEARINGS - 1 do
			local theta = (bearing / GROUND_BEARINGS) * math.pi * 2
			local from = Vector3.new(
				arena.center.X + math.cos(theta) * r,
				World.WATER_Y + 200,
				arena.center.Z + math.sin(theta) * r
			)
			local hit = Workspace:Raycast(from, Vector3.new(0, -400, 0), params)
			if hit then
				local drift = math.abs(hit.Position.Y - (World.WATER_Y + pose.ground(r)))
				if not best or drift < best then
					best = drift
				end
			end
		end
		if best then
			probes += 1
			if best > worst then
				worst, worstAt = best, r
			end
		end
	end
	if probes > 0 and worst > GROUND_TOLERANCE then
		warn(
			string.format(
				"[BossArenaService] %s floor is %.2f studs off its pose profile at r=%.0f "
					.. "(%d/%d probes). Every height this fight measures - sweep bands, coil "
					.. "clearance, slam impacts - is wrong by that much. Check BossArenas.%s.meshBottom "
					.. "against the MEASURED bbox floor arena_gen prints at export.",
				arena.model,
				worst,
				worstAt,
				probes,
				GROUND_PROBES,
				arena.islandId
			)
		)
	end
end

function BossArenaService.init()
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = Workspace

	for islandId, arena in BossArenas.items do
		local boss = Bosses.byIsland[islandId]
		local roam = if boss then boss.arena.radius else 36
		local pose = (if boss then POSE_ARENA[boss.pose] else nil) or {}
		-- HOW FAR THIS FIGHT IS WALKED. `floorRadius` is the measured answer
		-- where a row states one (the Careenage's 132), and the inference below
		-- is the fallback: whichever is further of the roam disc and the
		-- furthest an attack actually travels. Brinejaw's sweeps reach 66
		-- against a 28-stud roam, so the old roam-only rule left the outer 18
		-- studs of every sweep marker hanging over open water.
		--
		-- Both verifiers read this same number, so an arena cannot be checked
		-- over a smaller disc than the one it builds.
		local walkable = arena.floorRadius or math.max(roam, pose.reach or 0)
		-- ...and the floor itself, which is that disc plus the margin unless
		-- the row measured the sand directly, in which case the number IS the
		-- edge of the sand and there is nothing to add to it.
		local radius = arena.floorRadius or (math.max(roam, pose.reach or 0) + FLOOR_MARGIN)

		local template = arenaTemplate(arena)
		if template then
			placeAuthored(folder, arena, template)
		else
			buildFloor(folder, arena, radius, pose.ground)
			buildRim(folder, arena, radius)
			buildSpire(folder, arena, pose)
			buildStones(folder, arena)
		end
		-- Whichever path built it, check it presents the ground the fight was
		-- measured against. See verifyGround.
		verifyGround(arena, pose, folder, math.max(radius, walkable))
		-- ...and that none of the ground the fight uses is under the sea. This
		-- one runs for EVERY arena, profile or not - see verifyWaterline.
		verifyWaterline(arena, folder, walkable)
	end
end

return BossArenaService
