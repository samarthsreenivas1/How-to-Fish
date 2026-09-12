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
--
--     An authored arena may also declare `barrier` (BossArenas), and then it
--     gets an invisible containment ring on top of its mesh: solid to
--     characters, invisible to every raycast in the game. It is for a mesh
--     whose own boundary a player can walk over, jump over, or fall through -
--     all three of which the Ashfall Throne's lip and flank allow. See
--     "containment" below. Arenas without the field are untouched.
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
--     nonsensical without: Brinejaw's reef stones to bait slams onto, the
--     lighthouse its entire body is wrapped around, and - for the Choirfloor,
--     whose mesh is still unimported and whose fallback IS the fight today -
--     a pit for the maw to rise through, the seven collars the choir grows
--     out of, and the six shadow fins that are the only thing a lantern's
--     beam can be blocked by.
--
-- The fight itself never touches this service: the boss engine anchors to
-- wherever the boss rose (CreatureService.updateBoss takes its arena centre
-- from the spawn position), so BossService only needs centerFor, a ring of
-- drop-in points for the challengers, and - since the Ashfall Throne, which
-- is a mountain summit rather than a platform at sea level - floorY, the
-- height they all stand at. See "the floor" below.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BossArenas = require(Shared.Config.BossArenas)
local Bosses = require(Shared.Data.Bosses)
local BrinejawPath = require(Shared.Modules.BrinejawPath)
local Islands = require(Shared.Config.Islands)
local MeshColors = require(Shared.Config.MeshColors)
local Ocean = require(Shared.Config.Ocean)
local World = require(Shared.Config.World)

local BossArenaService = {}

local FOLDER_NAME = "BossArenas"

-- The folder `init` built, kept so the floor probe (see "the floor" below)
-- can cast against the arenas and NOTHING else. An Include filter, not a
-- distance test: without it a probe would happily land on a player, a boat,
-- or the ocean slab, and answer with a height that is real, plausible, and
-- not the arena's.
local arenaFolder: Instance? = nil

-- HOW FAR EACH AUTHORED ARENA WAS LIFTED OFF ITS OWN AUTHORED FRAME, by key.
--
-- Most arenas are lifted by zero and always will be: `meshBottom` is "that
-- mesh's authored bbox bottom" (BossArenas' header), so pinning the bbox floor
-- to it lands the mesh with authored z = 0 exactly on the waterline, and
-- authored coordinates ARE world coordinates. Two rows deliberately break that
-- - the two sealed interiors - because the ocean is a solid slab whose top face
-- is `World.WATER_Y` and nothing carves under an arena, so a room at sea level
-- is filled to the brim. `maelstrom_gullet` pins a -16 bbox floor at 584 and
-- `pyrelisk_heart` pins a -14 one at 586: both rooms' floor datum is world 600,
-- and both are lifted by exactly 600.
--
-- WHY IT HAS TO BE RECORDED RATHER THAN RECOMPUTED. The lift is
-- `meshBottom - the mesh's own authored bbox floor`, and after placement that
-- second number is GONE: `placeAuthored` has already pivoted the model, so its
-- bbox floor now reads `meshBottom` and the difference measures zero. The only
-- moment both halves exist is inside `placeAuthored`, which already computes
-- the difference as `delta.Y` in order to do the pivot. So it is kept, not
-- re-derived - one number, one source, and no second copy of the arithmetic to
-- get wrong separately.
--
-- WRITTEN ONLY ON THE AUTHORED PATH, which is the same path that creates the
-- lift. An arena whose mesh has not been imported is built by `buildFloor` at
-- the waterline and has no lift; it gets no entry here and every reader treats
-- a missing entry as zero, so the fallback keeps landing people exactly where
-- it always did.
local arenaLift: { [string]: number } = {}

-- ...AND THE VERTICAL BAND EACH AUTHORED ARENA ACTUALLY OCCUPIES, by the same
-- key: `lo` is the placed model's bbox FLOOR and `hi` its bbox CEILING, both in
-- world Y.
--
-- This is the lift fix's guard rail, and it is here because the fix alone is
-- not enough. `ringPositions` now adds `arenaLift`, so the two sealed rooms
-- land correctly - but the CLASS of bug is "a placement computed in one frame
-- and used in another", and nothing about adding one term makes the next
-- instance of that loud. A room lifted by a mechanism this table does not know
-- about, a `spawnPad` authored pre-lifted by a lane that did not read the
-- convention, a future arena placed by some third path: each of those puts a
-- party somewhere its own arena is not, and every one of them is SILENT today.
-- `verifyWaterline` cannot see it (it probes World.WATER_Y +/- 200, so a room
-- at 600 is entirely outside its window) and it checks the arena's GEOMETRY
-- besides, which in every one of these cases is correct - it is the drop-in
-- that is in the wrong world.
--
-- So the band is recorded and every drop-in is measured against it. Same
-- sourcing rule as `arenaLift`: both numbers are `placeAuthored`'s own
-- `targetCenterY` and `boxSize.Y`, handed back rather than re-derived, because
-- the only frame in which the placed model's extent is known without asking
-- the model again is the frame that placed it.
--
-- AUTHORED PATH ONLY, like the lift. An arena built by `buildFloor` has no
-- imported mesh and therefore no bbox to bound; it records no band, and
-- `checkDropBand` returns on its first line for it. No band, no check - which
-- is the honest answer rather than a guess at where a procedural disc ends.
local arenaBand: { [string]: { lo: number, hi: number } } = {}

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
-- The Ashfall Throne's rim path, in the frame the checkers below share:
-- studs ABOVE THE WATERLINE. It is arena_gen.py's PY_RIM_WORLD_Y, and it
-- cannot be derived from anything in Shared - `meshBottom` pins the mesh's
-- bbox FLOOR (the cloud deck's lowest billow, -84.7) and how far the path
-- stands above that floor lives in the generator. So: re-key from
-- PY_RIM_WORLD_Y, and nowhere else.
--
-- Writing it down is safe because drift in it is LOUD: `verifyGround` measures
-- the mesh that actually got placed against this number and warns by name the
-- moment the two part company.
local PY_RIM_ABOVE_SEA = 292.0
-- ...and the outer radius of that path with OPEN SKY over it (arena_gen.py
-- PY_CLEAR_R, measured). Past r205 the containment lip's face undercuts back
-- over the path, so a downward probe out there lands on the lip's ROOF - 7.25
-- studs up at r231 - and not on the ground. It is where this arena's profile
-- stops being checkable, which is exactly what `groundTo` is for.
local PY_CLEAR_R = 200.0

-- THE CHOIRFLOOR'S GROUND, re-keyed from arena_gen.py's GL_PROFILE (the
-- `noctyss` builders). It lives here rather than being read off NoctyssPath
-- because that module publishes only the two heights the BODY needs -
-- SHELF_Y 1.5 and PIT_R 15 - while the arena needs the whole curve. When
-- NoctyssPath grows a `shelfY`, this should become a call to it, exactly as
-- the `brinejaw` row below reads BrinejawPath.sandY; until then, re-key from
-- GL_PROFILE and nowhere else.
--
-- It STOPS AT THE STONE'S EDGE. GL_PROFILE keeps going - (74, -2.4),
-- (80, -6.2), (86, SKIRT_BOTTOM) - and none of that is floor: the arena's
-- boundary is the drop into the dark, and a profile that kept going would ask
-- the fallback to build walkable ground under the sea, which is the one thing
-- verifyWaterline exists to shout about.
local GLOOM_PROFILE = {
	{ 0.0, -7.5 }, -- the pit's bed
	{ 11.0, -7.1 },
	{ 15.0, -2.6 }, -- the torn wall climbs
	{ 18.0, 1.9 }, -- the lip, bent proud of the shelf
	{ 24.0, 1.5 },
	{ 34.0, 1.6 }, -- the socket ring
	{ 50.0, 1.5 },
	{ 62.0, 1.3 },
	{ 68.0, 1.0 }, -- the stone ends
}

local function gloomShelfY(r: number): number
	for i = 1, #GLOOM_PROFILE - 1 do
		local a, b = GLOOM_PROFILE[i], GLOOM_PROFILE[i + 1]
		if r <= b[1] then
			local t = math.clamp((r - a[1]) / (b[1] - a[1]), 0, 1)
			return a[2] + (b[2] - a[2]) * t
		end
	end
	return GLOOM_PROFILE[#GLOOM_PROFILE][2]
end

-- The pit's LIP (GL_PROFILE r18, "bent proud of the shelf"), and NOT its
-- mouth at PIT_R 15. It is where the procedural floor cuts its hole - see
-- buildFloor, and `pit` in the row below - because everything between 15 and
-- 18 is the torn wall diving to -2.6, which is under the sea and therefore
-- unbuildable in the fallback.
local GLOOM_LIP_R = 18.0

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
	-- The Ashfall Throne: the one arena whose floor is not the waterline, and
	-- therefore the one row whose profile is a CONSTANT and whose constant is
	-- 292 rather than 0. `verifyGround` compares each probe against
	-- `World.WATER_Y + ground(r)`, so a profile written in the mesh's own
	-- frame - where the rim path is z = 0 - would assert this summit is at sea
	-- level and cry 292 studs' worth of wolf over a correctly placed arena.
	--
	-- The path really is dead flat (PY_PATH_Z: no dome, no camber), so there is
	-- nothing to interpolate. What else a probe can land on out there is all
	-- inside GROUND_TOLERANCE - the lava lake's surface is authored 0.10 above
	-- the path and the seam rings 0.06 - except the nine monoliths, which read
	-- high on the one bearing each of them blocks and are stepped past by the
	-- smallest-drift-across-bearings rule already written into the checker.
	--
	-- THIS ROW IS WHAT MAKES THAT CHECKER RUN AT ALL. `verifyGround` returns
	-- immediately when `pose.ground` is nil, so on this arena it has been
	-- checking NOTHING: the function was extended for a floor 292 studs up
	-- (FLOOR_PROBE_TOP, and the comment down there explaining why 200/-400
	-- could not reach it) and then never given the row that reaches that code.
	-- A checker that silently checks nothing is the exact failure the essay
	-- above it is about.
	--
	-- It also, per this table's contract, moves the PROCEDURAL fallback to the
	-- same 292 - so the stand-in and the imported mesh present the same ground
	-- and the fight does not jump 292 studs on import day. `buildRim` and
	-- `buildStones` follow the floor up with it; nothing else here changes,
	-- because every other arena's profile still answers within a few studs of
	-- the waterline.
	pyrelisk = {
		ground = function(): number
			return PY_RIM_ABOVE_SEA
		end,
		groundTo = PY_CLEAR_R,
	},
	-- THE CHOIRFLOOR, and the row that turns its fallback back into the fight.
	-- Its mesh (arena_gen.py's `noctyss` builders) is NOT imported, so this is
	-- the arena that actually runs today - and with no row here it took the
	-- `not ground` branch below: one flat plate at the waterline. Everything the
	-- Gloomtrench fight is made of was missing from it, and none of it loudly:
	--   * no PIT, so the maw rose through solid floor;
	--   * no SOCKETS, because the seven collars ride the arena row's `sockets`
	--     and the furniture builder only ever looked at `stones`, so the choir
	--     grew out of bare stone with no landmark under it;
	--   * no FINS - and those are not scenery. NoctyssPath.beamBlocked raycasts
	--     at the BossArenas folder, so an arena with nothing in it to hit can
	--     never block a beam: the fight's whole stated trade (stand in a fin's
	--     shadow and lose your view of the arena, or see and be seen) simply did
	--     not exist on this path;
	--   * and no profile, so `verifyGround` returned on its first line and the
	--     footing was never checked at all.
	noctyss = {
		ground = gloomShelfY,
		-- START OUTSIDE THE LIP. Between the pit's mouth (15) and its lip (18)
		-- the authored surface is a near-vertical torn wall whose radius wobbles
		-- +/-5.5% in the mesh, so a downward probe out there lands anywhere from
		-- -2.6 to +1.9 while the profile claims one number - the one band where
		-- this checker would cry wolf at a correctly placed arena. Inside it the
		-- fallback has no floor to probe at all (see `pit`), so on both paths
		-- there is nothing here worth asking about.
		groundFrom = 20,
		-- ...and stop where the stone stops: arena_gen's walkable shelf is r18-68
		-- and past it are the boundary teeth, the drop, and the drowned skirt.
		groundTo = 68,
		-- Floor out to that same edge - r68, of which FLOOR_MARGIN carries the
		-- last 20. The choir's beams travel further (NoctyssPath.BEAM_REACH 74,
		-- from a socket at r34) and that is deliberate: the wedge sweeps out past
		-- the shelf so there is nowhere to simply stand outside the light. Floor
		-- under THAT would be floor the authored arena does not have either.
		reach = 48,
		-- THE PIT, cut as a HOLE at the lip rather than sunk as a basin - the
		-- ocean is why. See buildFloor.
		pit = GLOOM_LIP_R,
		-- The six shadow fins: (radius, AUTHORED degrees, height, length),
		-- re-keyed from GL_FINS with heights and lengths taken from the
		-- generator's own bands (14-20 tall, 13-19 long) instead of its rng.
		-- THE BEARINGS ARE NOT FREE: NoctyssPath.LANES (56, 112, 168, 224, 284,
		-- 352) are the midpoints of these six, and Noctyss surfaces facing one of
		-- them - move a fin and the lanes stop being gaps.
		fins = {
			{ 47.0, 28.0, 17.0, 16.0 },
			{ 58.0, 84.0, 15.0, 18.0 },
			{ 50.0, 140.0, 19.0, 14.0 },
			{ 56.0, 196.0, 16.0, 17.0 },
			{ 48.0, 252.0, 20.0, 15.0 },
			{ 55.0, 316.0, 14.0, 19.0 },
		},
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

-- The invisible containment ring (see "containment" below). 64 segments, not
-- the palisade's 20: a 20-gon inscribed in r234 pulls its flat faces 2.9 studs
-- inside the circle at each midpoint, which would eat into the walkable path
-- it is placed just outside of. At 64 that sagitta is 0.28 studs, and the
-- segments are pushed out by half their thickness so the inner faces land on
-- the requested radius rather than inside it. Thick enough that a knocked-back
-- character cannot tunnel it, and skirted below the floor so nothing slips
-- under it on a step.
local BARRIER_SEGMENTS = 64
local BARRIER_THICKNESS = 6
local BARRIER_SKIRT = 8

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
	-- ...and `Seam`, for the same grandfathered reason one level up: the
	-- Ashfall Throne's four seam rings (`PyreliskArena_SeamDeco`) are the
	-- fight's DISTANCE DIAL - the bands its ring novas are keyed to, read off
	-- the ground instead of guessed against a 400-stud silhouette - and a dial
	-- that imports as flat paint on black basalt cannot be read at all. The
	-- name mirrors one PyreliskBodyController already forces to Neon on the
	-- body itself (`makePiece`: Core / Seam / Eyes), so the seams on the floor
	-- and the seams on the colossus glow by the same rule rather than by two.
	"Seam",
}

local function isGlow(instanceName: string): boolean
	for _, marker in GLOW_MARKERS do
		if string.find(instanceName, marker, 1, true) then
			return true
		end
	end
	return false
end

-- THE THIRD NAME CONTRACT: a hazard surface. Solid to look at, solid to
-- CAST at, and not there to stand on.
--
-- The Deco rule below drops collision AND queries together, because dressing
-- should be invisible to everything. A hazard is the opposite case, and the
-- Ashfall Throne's lava lake is the one that forced it apart:
--
--   * It cannot collide. The lake is authored FLUSH with the rim path (a pit
--     is a fall in an arena whose only rule is horizontal movement, and a
--     sunken floor would be authored inside the ocean slab besides), so left
--     collidable it is simply more floor - a player walks onto the magma, the
--     moat that makes melee geometrically impossible stops doing so, and the
--     burn never fires, because Pyrelisk's is a RADIUS CHECK against the
--     lake, not a Touched event.
--   * It must still answer casts. Drop CanQuery too and the lake becomes a
--     hole in the raycast world: `BossArenaService.floorY` probing the
--     caldera for the boss's footing finds nothing at all and falls back to
--     the waterline - the exact 292-stud bug it exists to prevent - and a
--     shot fired across the moat passes through the arena into the sea.
--
-- So: collision only. Marker on the object's NAME, matched as a substring,
-- the GLOW_MARKERS convention.
local HAZARD_MARKERS = {
	"Lava",
}

local function isHazard(instanceName: string): boolean
	for _, marker in HAZARD_MARKERS do
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
			-- ARENA-LOCAL WATER wears the palette of the island that OWNS
			-- the lair, over the top of the generated row (user, 2026-09-12:
			-- "for all of the boss arenas, make it so that the water is the
			-- same colour... as the island that it corresponds to"). The
			-- mirror of WorldService.applyMeshColors's INTERIOR_WATER_NAMES
			-- branch, which has dressed the islands' own pools from
			-- `entry.water` since 2026-08-28; this is the same three lines one
			-- ring out, and it is why the mere reads as the fen's peat and the
			-- floe's leads as the Frostmaw's ice-blue instead of each as
			-- whatever the builder happened to type.
			--
			-- WRITTEN AFTER the MeshColors branch rather than instead of it,
			-- on purpose: every name in ARENA_WATER_NAMES has a generated row,
			-- so short-circuiting it would only cost the un-painted-part audit
			-- its coverage - and `continue`ing past it would skip the Deco
			-- pass below, which is what keeps `DecoMere` and `DecoPitWater`
			-- wadeable. Overriding two properties is idempotent and leaves
			-- both intact.
			--
			-- COLOUR AND REFLECTANCE ONLY - no caustics layers. See
			-- Ocean.ARENA_WATER_NAMES: OceanController never adopts these
			-- parts, so a layer here would sit still on water that rides no
			-- tide. A room keyed as an island that does not exist
			-- (maelstrom_gullet, pyrelisk_heart) finds no entry and keeps the
			-- base dress; neither has a water part today.
			if Ocean.ARENA_WATER_NAMES[descendant.Name] then
				local island = Islands.items[arena.islandId]
				local palette = island and island.water
				descendant.Color = if palette then palette.color else Ocean.COLOR
				descendant.Material = Enum.Material.SmoothPlastic
				descendant.Reflectance = if palette and palette.reflectance
					then palette.reflectance
					else Ocean.REFLECTANCE
				local waterAppearance = descendant:FindFirstChildWhichIsA("SurfaceAppearance")
				if waterAppearance then
					waterAppearance:Destroy()
				end
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
			-- ...and hazard surfaces, which give up collision but KEEP their
			-- queries. See HAZARD_MARKERS: the lava lake is a hole to walk into
			-- and a surface to cast at, and those are not the same flag. Written
			-- after the Deco pass so a name that is somehow both still ends up
			-- non-collidable either way.
			if isHazard(descendant.Name) then
				descendant.CanCollide = false
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
	-- ...and hand the placed model back, WITH THE LIFT.
	--
	-- The model, because the caller arms the caldera listener on it (see
	-- `armCaldera`) and does that on the INSTANCE rather than by looking the
	-- name up again: `arenaTemplate` resolves a group by walking up from its
	-- `<model>_Base` part, so what the clone is actually NAMED depends on how
	-- the artist grouped the import and is not guaranteed to be `arena.model`.
	-- Returning it removes the guess.
	--
	-- The lift, because `delta.Y` IS it and this is the only place it exists.
	-- `targetCenterY - boxCFrame.Position.Y` expands to
	-- `(meshBottom + h/2) - (authoredCentreY)`, i.e. `meshBottom - the mesh's
	-- own authored bbox floor` - zero for every arena authored on the waterline
	-- convention, and 600 for the two sealed rooms. One line after the pivot it
	-- is unrecoverable, because the pivot is what consumed it. See `arenaLift`.
	--
	-- ...and the BAND, from the same two numbers and for the same reason. After
	-- the pivot the model's bbox floor is `arena.meshBottom` by construction -
	-- that is what the pivot was FOR - so `targetCenterY -/+ boxSize.Y / 2` is
	-- the placed model's floor and ceiling in world Y, without measuring
	-- anything twice. Handing it back costs one table per arena at startup and
	-- buys a check that fires for a whole class of placement bug rather than
	-- for the one instance of it that has been found. See `arenaBand`.
	return model, delta.Y, { lo = targetCenterY - boxSize.Y / 2, hi = targetCenterY + boxSize.Y / 2 }
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

-- ONE ANNULAR BAND of floor: a ring of `FLOOR_BAND_SEGMENTS` boxes spanning
-- r0..r1, top face at `top`. It is how an arena with a PIT gets its floor,
-- because a nested-disc stack physically cannot express one: a cylinder is
-- solid to its axis, and the Choirfloor's profile FALLS inward, so the
-- outermost disc alone would lid the pit at shelf height and every smaller
-- one would be buried under it. Rings leave the middle empty.
--
-- The chord is measured at the band's OUTER radius so consecutive segments
-- overlap on the inside instead of gapping at the outer corners (the palisade
-- convention, plus its 1.06); the inner faces then form a polygon whose
-- inradius is exactly r0 - at 24 segments the corners bulge 0.15 studs, which
-- is the same order as the disc stack's own 0.232 of approximation.
local FLOOR_BANDS = 10
local FLOOR_BAND_SEGMENTS = 24

local function buildBand(parent: Instance, arena, name: string, r0: number, r1: number, top: number, color: Color3)
	local mid = (r0 + r1) / 2
	local chord = 2 * r1 * math.sin(math.pi / FLOOR_BAND_SEGMENTS) * 1.06
	local y = top - FLOOR_THICKNESS / 2
	for i = 1, FLOOR_BAND_SEGMENTS do
		local angle = (i / FLOOR_BAND_SEGMENTS) * math.pi * 2
		local x = arena.center.X + math.cos(angle) * mid
		local z = arena.center.Z + math.sin(angle) * mid
		local part = Instance.new("Part")
		part.Name = name
		-- Facing the centre, so X runs tangentially and Z is the radial depth.
		part.Size = Vector3.new(chord, FLOOR_THICKNESS, r1 - r0)
		part.CFrame = CFrame.lookAt(Vector3.new(x, y, z), Vector3.new(arena.center.X, y, arena.center.Z))
		part.Anchored = true
		part.Color = color
		part.Material = Enum.Material.SmoothPlastic
		part.Parent = parent
	end
end

-- The floor. Flat when the pose has no opinion, otherwise a stack of nested
-- discs whose tops follow the pose's ground profile - each disc's top is the
-- profile's height at that disc's own radius, so the smaller (higher) ones
-- pile up inward into a shallow dome. They interpenetrate by design; every
-- one is thick enough to reach below the waterline, so nothing floats.
local function buildFloor(parent: Instance, arena, radius: number, ground, pit: number?)
	if not ground then
		disc(parent, arena.model .. "_Floor", arena.center, radius, World.WATER_Y + FLOOR_LIP, arena.palette.floor)
		return
	end
	if pit then
		-- A POSE WITH A PIT GETS AN ANNULUS, and the hole is left OPEN rather
		-- than floored, because the ocean has already floored it. WorldService's
		-- sea is a solid slab whose top face is exactly WATER_Y and nothing
		-- carves it under an arena, so there is no such thing as playable space
		-- below zero out here: the Choirfloor's authored bed at -7.5 would be
		-- filled to the brim and walked across, which is the very bug
		-- verifyWaterline was written to catch on this arena.
		--
		-- So the pit is a HOLE IN THE STONE with the sea standing in it. Read
		-- against the authored intent that is remarkably close: the mesh's pit is
		-- black water at -5 that you cannot see into and that the maw comes up
		-- through, and here it is the ocean surface at 0 doing the same job. What
		-- it gives up is DEPTH - the lip stands 1.9 above the water instead of
		-- 6.9 - so falling in is a step down rather than a fall, and the authored
		-- fallen-slab ramp back out is not needed, because every bearing is a
		-- 1.9-stud step-up and Roblox climbs that without a jump. What it keeps
		-- is the part the fight needs: the centre is not floor, so the maw rears
		-- through open space instead of out of the plate players stand on.
		for band = 1, FLOOR_BANDS do
			local r0 = pit + (radius - pit) * ((band - 1) / FLOOR_BANDS)
			local r1 = pit + (radius - pit) * (band / FLOOR_BANDS)
			buildBand(
				parent,
				arena,
				arena.model .. "_Floor",
				r0,
				r1,
				World.WATER_Y + ground((r0 + r1) / 2),
				arena.palette.floor
			)
		end
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

-- `base` is the world Y the floor's edge presents, NOT the waterline: the
-- fallback's palisade is the only thing keeping a fight off open water, and a
-- pose whose profile puts the floor on a mountain (Pyrelisk, +292) would
-- otherwise leave the wall lying on the sea 292 studs below the ground it is
-- supposed to ring. The caller probes it, so sea-level arenas pass
-- `World.WATER_Y` bit for bit and are unchanged.
local function buildRim(parent: Instance, arena, radius: number, base: number)
	local chord = 2 * radius * math.sin(math.pi / RIM_SEGMENTS) * 1.06
	for i = 1, RIM_SEGMENTS do
		local angle = (i / RIM_SEGMENTS) * math.pi * 2
		local x = arena.center.X + math.cos(angle) * radius
		local z = arena.center.Z + math.sin(angle) * radius
		local segment = Instance.new("Part")
		segment.Name = arena.model .. "_Rim"
		segment.Size = Vector3.new(chord, RIM_HEIGHT, RIM_THICKNESS)
		segment.CFrame = CFrame.lookAt(
			Vector3.new(x, base + RIM_HEIGHT / 2, z),
			Vector3.new(arena.center.X, base + RIM_HEIGHT / 2, arena.center.Z)
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
-- `base`, again the floor rather than the waterline, and for a sharper reason
-- than the palisade's: these are BAIT TARGETS. A stand-in arena whose floor is
-- 292 studs up would scatter its bait at sea level, where no slam can reach it
-- and no player can see it - the fight's punish window would simply not exist.
local function buildStones(parent: Instance, arena, base: number)
	for index, offset in (arena.stones or {}) do
		local name = arena.model .. "_ReefStone" .. index
		-- ...UNLESS `cover` already raised it. Brinejaw's three reef stones are
		-- in both tables - they are slam bait AND wave shadow - and the cover
		-- row carries the measured width and rise this one cannot, because
		-- these dimensions are shared with Pyrelisk's monoliths and Rimefang's
		-- bergs. So whichever builder runs first wins, `buildCover` runs first
		-- for the arena that has both, and neither table has to know about the
		-- other beyond this line.
		if parent:FindFirstChild(name) then
			continue
		end
		local stone = Instance.new("Part")
		stone.Name = name
		stone.Size = Vector3.new(5.5, 4.4, 5.5)
		stone.CFrame = CFrame.new(arena.center.X + offset.X, base + 1.6, arena.center.Z + offset.Z)
			* CFrame.Angles(0, index * 1.1, 0)
		stone.Anchored = true
		stone.Color = arena.palette.rim
		stone.Material = Enum.Material.Rock
		stone.Parent = parent
	end
end

-- THE COVER FIELD, and it is the same class of omission `buildFins` was: an
-- attack whose only counterplay is a piece of terrain, on a stand-in arena
-- that has no such terrain in it.
--
-- Riptide sends a wave across the whole ring and the answer is to stand in
-- something's shadow. On the authored mesh that is eight rocks; on the
-- fallback, before this, it was three squat blocks 4.4 studs tall, which is
-- shorter than the character trying to hide behind one. So the wave had no
-- answer anywhere on the procedural path, silently - the shadow test runs, it
-- returns false everywhere, and nothing anywhere says the arena is missing the
-- thing the test is for.
--
-- CanQuery stays TRUE, deliberately and for the fin's reason: the shadow test
-- is a raycast at this folder, and a piece of cover that raycasts pass through
-- is not cover, it is a picture of cover. The palisade turns querying off on
-- purpose (casts must cross a containment wall); doing it here would rebuild
-- the exact bug this function exists to remove.
--
-- Sizes come from the row, not from here: `radius` is the measured half-width
-- of the authored piece and `rise` how far its top stands over the beach at
-- its own radius, so the stand-in throws the same shadow the mesh will. It is
-- sunk COVER_SINK into the sand so a piece never floats over the step between
-- two floor discs.
local COVER_SINK = 2.0

local function buildCover(parent: Instance, arena, base: number, ground)
	for _, site in (arena.cover or {}) do
		local offset = site.offset
		local r = math.sqrt(offset.X * offset.X + offset.Z * offset.Z)
		local beach = base + (if ground then ground(r) else 0)
		local height = site.rise + COVER_SINK
		local rock = Instance.new("Part")
		-- The authored object's own name, so a lookup finds either build.
		rock.Name = arena.model .. "_" .. site.part
		-- RECTANGULAR WHERE THE ROW SAYS SO (the Kraken's deck cargo, whose
		-- footprints are crates rather than boulders). Opt-in, the rule the rest
		-- of this file runs on: a row without the pair builds the square-of-2r it
		-- always built, to the stud.
		rock.Size = Vector3.new((site.sizeX or site.radius) * 2, height, (site.sizeZ or site.radius) * 2)
		rock.CFrame = CFrame.new(arena.center.X + offset.X, beach + site.rise - height / 2, arena.center.Z + offset.Z)
			* CFrame.Angles(0, r, 0)
		rock.Anchored = true
		rock.Color = arena.palette.rim
		rock.Material = Enum.Material.Rock
		rock.Parent = parent
	end
end

-- THE BELL. Bell Toll has the serpent's head strike the lighthouse bell and
-- rings expand from the tower, so the fallback needs something at the row's
-- `bell` for the strike to land on and for the player to read the tell
-- against - an attack that plays out against empty air over the spire is an
-- attack with no telegraph. Full XYZ from the row, because unlike every other
-- piece of furniture in this file it hangs 53 studs up rather than standing on
-- the floor: `base` is not its ground, the row's Y is its height.
local BELL_SIZE = Vector3.new(6.4, 5.0, 6.4)
local BELL_COLOR = Color3.fromRGB(107, 128, 107) -- tarnished bronze (arena_gen BRONZE)

local function buildBell(parent: Instance, arena)
	if not arena.bell then
		return
	end
	local bell = Instance.new("Part")
	bell.Name = arena.model .. "_Bell"
	bell.Size = BELL_SIZE
	bell.CFrame = CFrame.new(arena.center.X + arena.bell.X, World.WATER_Y + arena.bell.Y, arena.center.Z + arena.bell.Z)
	bell.Anchored = true
	bell.Color = BELL_COLOR
	bell.Material = Enum.Material.Metal
	bell.Parent = parent
end

-- ...and the SAME IDEA FOR `sockets`, which until now nothing built.
--
-- The Choirfloor's seven chitin collars are furniture in exactly Brinejaw's
-- sense - the fight's code reads them (Bosses.gloom's stalks take their `at`
-- offsets from the arena row's `sockets`, and NoctyssPath.socketPoint puts
-- the choir's roots there) - but they ride a DIFFERENT FIELD, because they
-- are not slam bait, and `buildStones` only ever looked at `stones`. So the
-- procedural Choirfloor grew seven stalks out of flat, featureless stone: the
-- one ring of landmarks a lightless arena has to navigate by, missing, with
-- nothing anywhere saying so.
--
-- Dimensions from arena_gen's build_gl_sockets: the collar sits 1.4 into the
-- stone and stands 3.0 proud of it, r~4 - low enough to vault, wide enough to
-- read across a dark shelf. `ground` because the shelf is not flat: the collar
-- ring at r34 stands 1.6 up, and a socket pinned to the bare floor height
-- would sink a fifth of its rise.
local SOCKET_R = 4.0
local SOCKET_RISE = 3.0
local SOCKET_SINK = 1.4

local function buildSockets(parent: Instance, arena, base: number, ground)
	for index, offset in (arena.sockets or {}) do
		local r = math.sqrt(offset.X * offset.X + offset.Z * offset.Z)
		local shelf = base + (if ground then ground(r) else 0)
		local collar = Instance.new("Part")
		-- The authored object's name (`<Model>_Socket1..7`), so anything that
		-- ever looks one up finds either build the same way.
		collar.Name = arena.model .. "_Socket" .. index
		collar.Shape = Enum.PartType.Cylinder
		-- A cylinder part's axis is X, so it gets stood on end (the `disc` trick).
		collar.Size = Vector3.new(SOCKET_SINK + SOCKET_RISE, SOCKET_R * 2, SOCKET_R * 2)
		collar.CFrame = CFrame.new(
			arena.center.X + offset.X,
			shelf + (SOCKET_RISE - SOCKET_SINK) / 2,
			arena.center.Z + offset.Z
		) * CFrame.Angles(0, 0, math.rad(90))
		collar.Anchored = true
		-- `socket` if the palette ever grows one (the `spire` precedent): the
		-- authored collars are pale chitin, not the rim's black basalt, and in an
		-- arena this dark that difference is the landmark.
		collar.Color = arena.palette.socket or arena.palette.rim
		collar.Material = Enum.Material.Slate
		collar.Parent = parent
	end
end

-- THE SHADOW FINS, and they are the one piece of this file's furniture that is
-- load-bearing for a RAYCAST rather than for a silhouette.
--
-- NoctyssPath.beamBlocked casts from a lit lantern to the player against the
-- BossArenas folder and nothing else: if the folder holds only a floor and a
-- palisade that is `CanQuery = false`, no beam can ever be blocked, and the
-- arena's stated central mechanic - break the choir's line of sight behind a
-- blade, and lose your own view of the ring doing it - is not a hard fight,
-- it is an absent one. Six boxes are enough to give it back, because the
-- occlusion test is a ray and a ray does not care that the authored blade is
-- a splintered wedge.
--
-- So: KEEP CanQuery TRUE here. The palisade turns it off on purpose (casts
-- must pass through a containment wall); doing the same to these would build
-- the exact bug this function exists to fix, silently and invisibly.
--
-- Tangential, like the authored fins - each throws its shadow along the ring
-- rather than at the pit - and sunk into the shelf so a blade never floats
-- over the step between two floor bands.
local FIN_THICKNESS = 3
local FIN_SINK = 2

local function buildFins(parent: Instance, arena, pose, base: number)
	for index, fin in (pose.fins or {}) do
		local radius, degrees, height, length = fin[1], fin[2], fin[3], fin[4]
		-- THE MIRROR, the same one BossArenas' `sockets` and NoctyssPath's
		-- `authored()` apply: the generator's bearings are Blender's, and the
		-- glTF export maps blender +Y onto roblox -Z, so an authored degree is
		-- its own negative in here. Copying them straight across would put all
		-- six fins on the wrong side of the arena - and, worse than wrong, still
		-- plausible: six blades in mirrored positions still block beams, just
		-- never the ones NoctyssPath.LANES says are the way through.
		local angle = -math.rad(degrees)
		local shelf = base + (if pose.ground then pose.ground(radius) else 0)
		local y = shelf + height / 2 - FIN_SINK / 2
		local blade = Instance.new("Part")
		blade.Name = arena.model .. "_Fin" .. index
		blade.Size = Vector3.new(length, height + FIN_SINK, FIN_THICKNESS)
		blade.CFrame = CFrame.lookAt(
			Vector3.new(arena.center.X + math.cos(angle) * radius, y, arena.center.Z + math.sin(angle) * radius),
			Vector3.new(arena.center.X, y, arena.center.Z)
		)
		blade.Anchored = true
		blade.Color = arena.palette.rim
		blade.Material = Enum.Material.Rock
		blade.Parent = parent
	end
end

-- ============================================================ the floor

-- WHERE IS THIS ARENA'S FLOOR? Six of the seven answer "the waterline". The
-- Ashfall Throne does not, and everything downstream of that assumption broke
-- on it at once.
--
-- It is a volcano SUMMIT: `BossArenas.volcano.meshBottom = -84.7` pins the
-- mesh's authored z = 0 at world Y +292, and that plane is the rim path the
-- whole fight is fought on (arena_gen.py PY_RIM_WORLD_Y). Both customers of
-- this file hard-coded `World.WATER_Y` instead - `BossService.arenaPosition`
-- spawned the boss at it, `ringPositions` dropped the challengers 3.5 studs
-- above it - so summoning Pyrelisk teleported the party into open ocean 292
-- studs BELOW its own arena, beside a colossus standing in the sea. Worse
-- than the swim: CreatureService.updateBoss takes the fight's arena centre
-- from the spawn position, so every height the pose measures would have been
-- off by 292 as well, and nothing anywhere warns.
--
-- THE PROBE. Cast straight down onto the arena we actually placed, at the
-- radius the caller cares about, and take the LOWEST surface found. Lowest,
-- not first, and for the reason `verifyGround` already spells out: out here
-- the ground IS the lowest thing a ray can land on, so anything STANDING on
-- it - the nine monoliths, Brinejaw's reef stones, the lighthouse itself -
-- only ever reads high, and the minimum steps past all of it.
--
--   * Several bearings, so one monolith on one line cannot answer for the
--     whole circle.
--   * Several radii, working INWARD from the one asked for, because an arena
--     can overhang its own floor: the Ashfall Throne's containment lip
--     undercuts back to r205, and a downward ray at r231 lands on the lip's
--     roof 7.25 studs up rather than on the path (measured, arena_gen.py
--     PY_CLEAR_R). Taking the lowest steps back out from under the ceiling.
--     This assumes a floor that does not DROP as you walk inward - true of
--     every arena here (Pyrelisk's path is dead flat and its lava lake flush
--     with it; Brinejaw's beach domes upward) and the thing to re-check if
--     someone ever authors a pit arena above sea level.
--   * NEVER the centre column, which is why radius is required rather than
--     defaulted to zero: at r = 0 the Brinejaw arena's only honest answer is
--     the top of its lighthouse.
--
-- ...AND WHY THIS IS A NO-OP FOR EVERY OTHER ARENA, which matters more than
-- the fix. Six arenas sit at sea level by construction, and their fights are
-- measured from `World.WATER_Y`, not from their own sand: Brinejaw's sweep
-- bands, coil clearance and slam impacts are all `WATER_Y + sandY(r)`. A
-- probe that came back +3.2 on the beach's crown would move that arena's
-- anchor by 3.2 studs and shift every one of those bands against the players
-- standing on them - the identical symptom to the 3.47-stud anchor error this
-- file already carries a checker for. So the probe SNAPS: any floor within
-- SEA_LEVEL_BAND of the waterline returns `World.WATER_Y` exactly, bit for
-- bit, and so does every miss and every island that fights in place. The
-- separation is not close - the procedural fallback's floor is 0.15 up, the
-- deepest authored beach 3.2, and the Ashfall Throne 292 - so nothing can
-- land in between by accident, and the only arena this function can move is
-- the one that is genuinely on a mountain.

-- The probe's window: from this far above the waterline, straight down past
-- it. 900 clears the highest floor an arena can present today (292) with room
-- for the next one, and sits well above anything the meshes put over their
-- own paths (Pyrelisk's lip crests 11 studs up), so a ray never starts inside
-- the geometry it is trying to measure.
local FLOOR_PROBE_TOP = 900
local FLOOR_PROBE_DEPTH = 1400
-- Fractions of the requested radius to probe, outermost first. See the
-- undercut note above: 0.85 of a 232-stud path is r197, inside the Ashfall
-- Throne's measured clear radius of 200.
local FLOOR_PROBE_RADII = { 1.0, 0.85, 0.7 }
-- A floor this close to the waterline IS the waterline. Twenty studs: six
-- times the tallest sea-level arena's relief, a fourteenth of the volcano's
-- lift. Nothing has ever landed between the two, and a new arena that did
-- would be a design decision, not a rounding error.
local SEA_LEVEL_BAND = 20
-- A hit this far BELOW the highest thing the same sweep found is not floor,
-- it is a hole - and the arena mesh has holes. At r252..255 the Ashfall
-- Throne's Rim ends on a fixed circle while its Flank's top ring is jittered,
-- and on 22% of bearings the two do not meet: a downward ray goes straight
-- through, 300 studs, and lands at world Y -8.3 on the mountain's cut.
--
-- 100 studs, and the separation is the same kind SEA_LEVEL_BAND rests on
-- rather than a tuned threshold. The most relief any arena legitimately shows
-- inside one probe sweep is Brinejaw's 54-stud lighthouse standing on its own
-- beach; a fall-through is 300. Nothing has ever landed between them, and an
-- arena that did would be a design decision rather than a rounding error.
--
-- It is a filter, not a replacement for taking the minimum: everything that
-- survives it is still ranked lowest-first, so a monolith or a reef stone
-- standing on the floor still loses to the floor.
local FLOOR_HOLE_DROP = 100

-- The Y a body should stand at on this island's arena floor, `radius` studs
-- out from its centre. `World.WATER_Y` for a fight-in-place island, for the
-- procedural fallback, and for every arena that really is at sea level - see
-- the block above before changing any of that.
--
-- Also returns WHAT it landed on, when it landed on anything. Callers that
-- put a living body down want it: "the floor is at 292" and "the floor at 292
-- is the lava lake" are different answers, and only the second one tells you
-- the drop-in circle is over the moat (see ringPositions).
function BossArenaService.floorY(islandId: string, radius: number): (number, BasePart?)
	local center = BossArenas.centerFor(islandId)
	if not center or not arenaFolder then
		return World.WATER_Y, nil
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	-- Every arena, not just this one - they are 8k+ studs apart (BossArenas'
	-- placement rule), so no probe can reach a neighbour's geometry, and the
	-- filter's job here is only to exclude the ocean, boats and players.
	params.FilterDescendantsInstances = { arenaFolder }
	-- CLAMP THE PROBE TO GROUND THE ARENA ACTUALLY HAS.
	--
	-- `radius` comes from another file entirely - `Bosses.<island>.arena.radius`
	-- (+8 for the drop-in ring), fight tuning - and "lowest hit wins" turns
	-- hostile the moment the outermost probe leaves the floor. On the Ashfall
	-- Throne the outer ring of the mesh is not sealed (see FLOOR_HOLE_DROP), so
	-- at radius >= ~252 the 1.0 probe drops 300 studs to world Y -8.3, which is
	-- inside SEA_LEVEL_BAND, which snaps to the waterline - and the party is
	-- dropped 292 studs into the sea by the very function written to stop that.
	-- Today's 152 is nowhere near it; a re-tune to 252 would re-arm the whole
	-- bug from a number in a different file, silently.
	--
	-- A `barrier` row already states where the containable arena ends, so use
	-- it: nothing that walks can be outside it, and therefore no caller has a
	-- legitimate question about the floor out there. Arenas with no barrier
	-- keep the raw radius, exactly as before.
	local arena = BossArenas.items[islandId]
	local probeR = math.max(radius, 0)
	local barrier = arena and arena.barrier
	if barrier then
		probeR = math.min(probeR, barrier.radius)
	end
	local hits: { RaycastResult } = {}
	local highest: number? = nil
	for _, fraction in FLOOR_PROBE_RADII do
		local r = probeR * fraction
		for bearing = 0, GROUND_BEARINGS - 1 do
			local theta = (bearing / GROUND_BEARINGS) * math.pi * 2
			local from = Vector3.new(
				center.X + math.cos(theta) * r,
				World.WATER_Y + FLOOR_PROBE_TOP,
				center.Z + math.sin(theta) * r
			)
			local hit = Workspace:Raycast(from, Vector3.new(0, -FLOOR_PROBE_DEPTH, 0), params)
			if hit then
				table.insert(hits, hit)
				if not highest or hit.Position.Y > highest then
					highest = hit.Position.Y
				end
			end
		end
	end
	-- ...and the same guard from the other end, for the case the clamp cannot
	-- see: a hit that sits a fall's worth below everything else on the same
	-- arena is a ray that found a hole, not a ray that found the ground. It is
	-- dropped rather than allowed to win the minimum. With no barrier row and
	-- no holes this loop is exactly "the lowest hit", which is what it was.
	local lowest: number? = nil
	local lowestPart: BasePart? = nil
	for _, hit in hits do
		local y = hit.Position.Y
		if (highest :: number) - y <= FLOOR_HOLE_DROP and (not lowest or y < lowest) then
			lowest, lowestPart = y, hit.Instance
		end
	end
	if not lowest or math.abs(lowest - World.WATER_Y) <= SEA_LEVEL_BAND then
		return World.WATER_Y, lowestPart
	end
	return lowest, lowestPart
end

-- ============================================================ containment

-- AN AUTHORED MESH IS NOT ALWAYS ITS OWN WALL.
--
-- The procedural fallback rings itself with `buildRim` - solid to characters,
-- invisible to casts - and an authored arena is supposed to need no such
-- thing, because the artist built the boundary. The Ashfall Throne is the one
-- that does not, and the reason is a fair design trade rather than an
-- oversight: its outer lip is deliberately LOW and OVERHANGING so the five
-- vista notches stay open, and low loses. Measured off the exported glb:
--
--   * the lip is a thin ribbon whose inner apex is at r229, at 0.55 * crest.
--     At a notch the crest is 3.2, so the apex is 1.78 studs - BELOW Roblox's
--     ~2-stud automatic step-up. A player does not jump it, they WALK over
--     it, and the notches are 110 degrees of the circle: 30% of the rim.
--   * away from the notches the crest is 11.0, so the apex is 6.05 against a
--     stock jump of 6.37 to 7.2. Clearable everywhere, by 0.32 at worst.
--   * the Gate's two side blocks have flat tops at +6.00 at r~226, and one of
--     them stands inside a notch whose crest is 3.42. That is a staircase.
--   * above the apex the lip's top RAMPS outward - about 9 degrees at a
--     notch, 28 elsewhere - to r251, where it hands off to a mountainside
--     that falls 300 studs into the ocean slab.
--
-- Four ways off a summit whose one design rule is that the player moves
-- horizontally. So the containment is built here instead, as an invisible ring
-- just outside the walkable path. The generator's HANDOFF has been gesturing
-- at "invisible barriers" since the arena landed; this is them.
--
-- THE CONTRACT, which is the procedural rim's plus two:
--   * solid to characters (CanCollide, the default, stated anyway - the whole
--     point of a part nobody can see);
--   * `CanQuery = false`, so shots, creature aim, `floorY`, `verifyGround`
--     and `verifyWaterline` all pass through it as if it were not there. This
--     is load-bearing: a queryable wall at r234 would be the first thing every
--     downward probe in this file hit, and `floorY` would answer "the arena's
--     floor is the top of an invisible wall";
--   * `Transparency = 1` and no shadow, because the vista through those
--     notches is the entire reason the lip was authored too low to work.
--
-- DATA-DRIVEN and OPT-IN: it is built only from `BossArenas.<arena>.barrier`,
-- and only on the AUTHORED path (the fallback has `buildRim`). An arena with
-- no barrier row builds precisely what it built before this existed - five of
-- the six rows have none, and for them this function returns on its first
-- line without so much as a raycast.
local function buildBarrier(parent: Instance, arena, islandId: string)
	local barrier = arena.barrier
	if not barrier then
		return
	end
	-- The arena's OWN floor, probed, not the waterline - this ring has to
	-- stand on the summit with the players. `floorY` answers `World.WATER_Y`
	-- exactly for a sea-level arena, so a barrier row on any future arena
	-- lands right without a second height constant to keep in step. The probe
	-- cannot see this barrier (CanQuery = false) or be confused by the lip's
	-- roof, which is not the lowest thing it finds.
	local base = BossArenaService.floorY(islandId, barrier.radius)
	-- Top at `base + height`, bottom a skirt below the floor: the path is dead
	-- flat, but a wall that merely touches the ground is one physics step from
	-- not touching it. Hoisted above the shape branch below, because both
	-- shapes stand at the same height on the same probed floor.
	local midY = base + (barrier.height - BARRIER_SKIRT) / 2
	-- A BOX INSTEAD OF A RING, where the row asks for one. See `barrier` in
	-- BossArenas: the Kraken's arena is a 170 x 40 SHIP, and the smallest
	-- circle that contains a hull fences 70 studs of walkable sea off either
	-- beam - which on an arena whose containment IS the fight is not a wide
	-- ring, it is the exit. Four slabs, same contract as the ring's segments
	-- (solid to characters, invisible to every cast, no shadow) and the same
	-- half-thickness push outward so the INNER faces land on the requested
	-- extents rather than a thickness inside them.
	if barrier.sizeX and barrier.sizeZ then
		local hx = barrier.sizeX + BARRIER_THICKNESS / 2
		local hz = barrier.sizeZ + BARRIER_THICKNESS / 2
		-- Corners: each pair spans the full outer width of the other axis, so
		-- the four overlap at the corners instead of leaving a gap a shove
		-- could push somebody through.
		local walls = {
			{ Vector3.new(hx, 0, 0), Vector3.new(BARRIER_THICKNESS, 0, hz * 2 + BARRIER_THICKNESS) },
			{ Vector3.new(-hx, 0, 0), Vector3.new(BARRIER_THICKNESS, 0, hz * 2 + BARRIER_THICKNESS) },
			{ Vector3.new(0, 0, hz), Vector3.new(hx * 2 + BARRIER_THICKNESS, 0, BARRIER_THICKNESS) },
			{ Vector3.new(0, 0, -hz), Vector3.new(hx * 2 + BARRIER_THICKNESS, 0, BARRIER_THICKNESS) },
		}
		for _, wall in walls do
			local segment = Instance.new("Part")
			segment.Name = arena.model .. "_Barrier"
			segment.Size = Vector3.new(wall[2].X, barrier.height + BARRIER_SKIRT, wall[2].Z)
			segment.CFrame = CFrame.new(arena.center.X + wall[1].X, midY, arena.center.Z + wall[1].Z)
			segment.Anchored = true
			segment.CanCollide = true
			segment.CanQuery = false
			segment.Transparency = 1
			segment.CastShadow = false
			segment.Material = Enum.Material.SmoothPlastic
			segment.Parent = parent
		end
		return
	end
	-- Segment centres sit half a thickness OUT, so the polygon's inner faces
	-- land on `barrier.radius` itself instead of a chord's sagitta inside it.
	-- The radius is chosen to clear the walkable path; shaving it back here
	-- would quietly undo that.
	local centerR = barrier.radius + BARRIER_THICKNESS / 2
	local chord = 2 * centerR * math.sin(math.pi / BARRIER_SEGMENTS) * 1.06
	for i = 1, BARRIER_SEGMENTS do
		local angle = (i / BARRIER_SEGMENTS) * math.pi * 2
		local x = arena.center.X + math.cos(angle) * centerR
		local z = arena.center.Z + math.sin(angle) * centerR
		local segment = Instance.new("Part")
		segment.Name = arena.model .. "_Barrier"
		segment.Size = Vector3.new(chord, barrier.height + BARRIER_SKIRT, BARRIER_THICKNESS)
		segment.CFrame = CFrame.lookAt(Vector3.new(x, midY, z), Vector3.new(arena.center.X, midY, arena.center.Z))
		segment.Anchored = true
		segment.CanCollide = true
		segment.CanQuery = false
		segment.Transparency = 1
		-- An invisible part still casts a shadow, and a 64-segment ring of
		-- them would draw a wall on the rim path that nothing is standing on.
		segment.CastShadow = false
		segment.Material = Enum.Material.SmoothPlastic
		segment.Parent = parent
	end
end

-- ============================================================ the caldera

-- AN ARENA THAT CHANGES SHAPE MID-FIGHT, and the only one in the project.
--
-- The Ashfall Throne's lava lake is a moat: flush with the rim path, closed
-- underneath by a disc (`PyreliskArena_LakeFloor`) that is what actually holds
-- a body standing on the magma, and non-collidable on its surface by the
-- HAZARD_MARKERS rule above. When the colossus dies the caldera OPENS - the
-- lava drains, the disc goes, and a shaft that was always authored underneath
-- it (`PyreliskArena_Shaft`) becomes the way into act four.
--
-- WHY AN ATTRIBUTE AND NOT A FUNCTION CALL. This service requires nothing from
-- CreatureService (its five requires are BossArenas, Bosses, BrinejawPath,
-- MeshColors and World), so CreatureService COULD require it - but
-- CreatureService is at the Luau 200-local limit and a new file-scope `local`
-- there is forbidden. An attribute on a replicated Workspace instance costs no
-- local, is LEVEL-triggered rather than an edge, replicates to late joiners for
-- free, and is readable by the client VFX lane without a second wire. It is the
-- `WeakpointHot` idiom, one arena over.
--
-- The writer is `Fn.pyreliskOpenCaldera` in CreatureService, which finds this
-- model as `Workspace.BossArenas.<arena.model>` - which is why `armCaldera`
-- below WARNS when the placed model does not carry that name. See the handoff.
local CALDERA_ATTR = "PyreliskCaldera"

-- Open (1) or closed (0/nil). Written to be idempotent and to be safe to call
-- with the arena half-built: every object is looked up by name and a missing
-- one is reported ONCE by name rather than skipped, because the whole failure
-- mode here is a mesh that shipped without the two new objects and an arena
-- that then simply never opens - a fight that stops at act three, with nothing
-- in any log to say why.
local function applyCaldera(model: Instance, arena, open: boolean)
	local caldera = arena.caldera
	if not caldera then
		return
	end
	local missing: string? = nil
	local function piece(suffix: string): BasePart?
		local found = model:FindFirstChild(arena.model .. suffix, true)
		if found and found:IsA("BasePart") then
			return found
		end
		missing = missing or (arena.model .. suffix)
		return nil
	end

	local lakeFloor = piece(caldera.lakeFloor)
	local shaft = piece(caldera.shaft)
	local lava = piece(caldera.lava)

	if lakeFloor then
		-- THE FLOOR OF THE LAKE, which is the only thing holding anyone up over
		-- the shaft. Open: it stops colliding, stops drawing, and STOPS ANSWERING
		-- CASTS - and it gets all three back when the caldera closes, because this
		-- is a level and a fight that ends re-arms the moat.
		--
		-- THE QUERY IS THE ONE WORTH ARGUING, in both directions.
		--
		-- Left queryable, this plate becomes an INVISIBLE SHEET STRETCHED OVER AN
		-- OPEN HOLE: every shot fired down the shaft stops on nothing the player
		-- can see, and `floorY` - which decides where a body is PUT
		-- (`BossService.arenaPosition` raises the boss at it, `ringPositions`
		-- drops the party on it) - answers with the height of a floor that is no
		-- longer there. A body placed on a surface it will fall straight through
		-- is the mid-air spawn, and it is silent.
		--
		-- Dropped, the risk is the opposite one, and it is the exact failure
		-- HAZARD_MARKERS exists to prevent: a probe that finds NOTHING over the
		-- caldera falls back to `World.WATER_Y` and puts somebody 292 studs below
		-- the arena. So here is the arithmetic, because the first draft of this
		-- comment got it wrong.
		--
		-- `floorY` probes at `{1.0, 0.85, 0.7} * min(radius, barrier.radius 234)`.
		-- The SMALLEST radius any caller passes on this arena is `arena.radius`
		-- 152, so the innermost sample is r 106.4 - which is INSIDE the lake
		-- (r 120) and inside the shaft (r ~108). The probes DO reach over the
		-- hole; the claim that they never do was false.
		--
		-- What makes it safe is that `_Lava` KEEPS ITS QUERY (HAZARD_MARKERS, and
		-- this function deliberately does not touch that flag). The lake surface
		-- is authored flush with the rim path and 0.10 ABOVE it, never below, so
		-- the caldera column still answers at the path's own height with or
		-- without this plate - and because `floorY` returns the LOWEST hit that
		-- survives its hole filter, that 0.10 loses to the rim path every time and
		-- the answer does not move by a stud. The column is never a hole in the
		-- raycast world; only this sheet stops being one of its surfaces.
		lakeFloor.CanCollide = not open
		lakeFloor.CanQuery = not open
		lakeFloor.Transparency = if open then 1 else 0
	end
	if lava then
		-- The lake drains with its floor. Collision is NOT touched: `_Lava`
		-- matches HAZARD_MARKERS and is already non-collidable from placement,
		-- and re-asserting it here would put a second writer on a flag the
		-- name contract owns. Queries are not touched either, for the reason
		-- HAZARD_MARKERS states.
		lava.Transparency = if open then 1 else 0
	end
	if shaft then
		-- The walls of the drop: SOLID and QUERYABLE while the caldera is open,
		-- and stated rather than assumed in both flags.
		--
		-- Collidable either way in practice - nothing can reach them while the
		-- lake floor is closed over the top - but "the shaft was fine in the
		-- editor" is how a hollow tube ships with a default convex hull that
		-- filled it solid. The IMPORT is what actually decides that one:
		-- `_Shaft` needs PreciseConvexDecomposition or there is no shaft.
		--
		-- Queryable because with `_LakeFloor` no longer answering, these walls are
		-- most of what is left in the caldera column for a shot fired down it to
		-- hit. Set on every apply rather than once at placement, so a caldera that
		-- re-opens cannot inherit a flag some other pass turned off.
		shaft.CanCollide = true
		shaft.CanQuery = true
	end

	if missing then
		warn(
			string.format(
				"[BossArenaService] %s has a `caldera` row but no %q - the caldera cannot open, so the "
					.. "fight will end at act three with the lake still solid and nothing to jump into. "
					.. "Re-export the arena (arena_gen.py splits `_Base` into an annulus plus `_LakeFloor`, "
					.. "with `_Shaft` under it) and re-run `python3 tools/gen_mesh_colors.py`.",
				arena.model,
				missing
			)
		)
	end
end

-- Arm one arena's caldera: adopt whatever the attribute already says, then
-- follow it.
--
-- READ-ON-ADOPT IS NOT ABOUT LATE JOINERS. A client that joins mid-fight sees
-- the open caldera for free, because what changed is replicated Workspace
-- parts and not a message. What the read guards is INIT ORDER on the server:
-- this listener is connected during `BossArenaService.init`, and nothing in
-- the project promises that no other service has already written the attribute
-- by then. A pure `GetAttributeChangedSignal` connection would miss a value
-- that was already set and leave the arena closed for the rest of the round,
-- with the attribute reading 1 the whole time - the silent-absence shape, and
-- the reason every other level in this fight's contract is read as well as
-- watched.
--
-- FALL DAMAGE IS NOT SUPPRESSED HERE BECAUSE THERE IS NONE TO SUPPRESS. The
-- design asks for it and the answer is that the project has no fall-damage
-- system at all: grepped across `src/` for `FallDamage` / `Freefall` /
-- `FallingDown` / `StateChanged`, and every hit is something else - one
-- Jumping-or-Freefall test in CreatureService's outrun check, NpcService
-- disabling two humanoid states on held bodies, and CharacterSoundController's
-- footstep state machine. Roblox's own Humanoid does no fall damage unless a
-- game adds it. So a 120-stud drop costs nothing, and the thing that actually
-- has to be true about the shaft is the other half of the design's sentence:
-- that nothing in it can kill them and that they cannot get stuck at the
-- bottom. Both of those are CreatureService's (`Fn.pyreliskLavaWatch` must
-- stop burning and rescuing inside the lake once the caldera is open, or the
-- jump is undone by the rescue that was written to save it) and are recorded
-- in the handoff.
local function armCaldera(model: Instance, arena, islandId: string)
	if not arena.caldera then
		return
	end
	-- THE NAME IS A CONTRACT with a file that cannot require this one. See
	-- CALDERA_ATTR: the writer reaches this instance as
	-- `Workspace.BossArenas.<arena.model>`, so a group the artist imported
	-- under any other name is a fight whose caldera never opens, on an
	-- attribute written to a model nobody is listening to.
	if model.Name ~= arena.model then
		warn(
			string.format(
				"[BossArenaService] %s placed as %q, not %q - the caldera listener is armed on the right "
					.. "instance here, but CreatureService writes %s by NAME "
					.. "(Workspace.BossArenas.%s) and will not find it. Re-export the group under the "
					.. "model name, or give the import that name on the way in.",
				islandId,
				model.Name,
				arena.model,
				CALDERA_ATTR,
				arena.model
			)
		)
	end
	applyCaldera(model, arena, model:GetAttribute(CALDERA_ATTR) == 1)
	model:GetAttributeChangedSignal(CALDERA_ATTR):Connect(function()
		applyCaldera(model, arena, model:GetAttribute(CALDERA_ATTR) == 1)
	end)
end

-- ============================================================ public

-- The arena centre for an island's boss, or nil when it fights in place.
function BossArenaService.centerFor(islandId: string): Vector3?
	return BossArenas.centerFor(islandId)
end

-- How far outside its own arena a drop-in may land before this is a bug rather
-- than clearance. Four studs: the ring already adds 3.5 of settle clearance
-- over whatever it stood on (physics drops them the rest), so a correct
-- placement on the model's topmost surface sits 3.5 proud of `hi` by design and
-- the tolerance has to clear that. It does, by half a stud - and the failures
-- this is written for miss by HUNDREDS (594 studs, for the gullet), so nothing
-- turns on where between 4 and 500 the line is drawn.
local BAND_TOLERANCE = 4.0

-- IS THIS DROP-IN INSIDE THE ARENA IT IS A DROP-IN FOR?
--
-- Warn, never error. A hard failure here fires at the moment a fight starts -
-- `dropIn` on the summon and the `ArenaMove` listener on an act break - and
-- taking the fight down is a worse outcome than putting a party somewhere odd
-- with a line in the log naming the arena. Warn-by-name is this project's
-- convention for exactly this shape (`placeAuthored`'s uncoloured-parts count,
-- `ringPositions`' own hazard-surface warning, `verifyGround`, `verifyWaterline`),
-- and the reason is always the same: the failure has to be attributable at a
-- glance by someone who was not looking for it.
--
-- NO BAND, NO CHECK. An arena whose mesh has not been imported was built by
-- `buildFloor` at the waterline and recorded nothing; asking whether a
-- procedural disc's drop-in is inside a bbox that does not exist would mean
-- inventing the bbox, and an invented bound is a false positive waiting for the
-- first arena that does not fit it.
local function checkDropBand(islandId: string, y: number)
	local band = arenaBand[islandId]
	if not band then
		return
	end
	local lo, hi = band.lo - BAND_TOLERANCE, band.hi + BAND_TOLERANCE
	if y < lo or y > hi then
		warn(
			string.format(
				"[BossArenaService] drop-in for %s at Y %.1f is outside the arena band [%.1f, %.1f] - "
					.. "a lifted room without its lift? The party is being put down somewhere its own "
					.. "arena is not. Check BossArenas.%s.spawnPad against the room's floor datum, and "
					.. "that `placeAuthored` recorded a lift for it (an arena is lifted by "
					.. "`meshBottom` less its mesh's own authored bbox floor).",
				islandId,
				y,
				lo,
				hi,
				islandId
			)
		)
	end
end

-- `count` evenly spaced drop-in CFrames on a circle of `radius` around the
-- island's arena centre, each facing the centre - where the challengers
-- land. Y clears the floor lip; physics settles them the last few studs.
function BossArenaService.ringPositions(islandId: string, count: number, radius: number): { CFrame }
	local center = BossArenas.centerFor(islandId)
	if not center then
		return {}
	end
	-- THE PAD WINS WHERE A ROW AUTHORS ONE, and it is a different question
	-- from "where is the floor". `radius` arrives from another file entirely
	-- (`Bosses.<island>.arena.radius + 8`, fight tuning) and describes a circle
	-- around the arena CENTRE, which is the right shape for every disc arena in
	-- this file and the wrong one for the two the Kraken added: the Tidebreak's
	-- centre is its waist, so a 40-stud ring around it lands most of a party in
	-- the sea off both rails, and the gullet's is under the heart. Both meshes
	-- author a drop-in pad for precisely this, so a row that names one is
	-- answered from the row.
	--
	-- Y COMES FROM THE ROW TOO, not from `floorY`. That probe SNAPS anything
	-- within SEA_LEVEL_BAND of the waterline to WATER_Y exactly - deliberately,
	-- and correctly for a fight measured from the sea - so on a ship it cannot
	-- tell you where the quarterdeck is; it would answer 0 for a dais 17 studs
	-- up and drop the party through the hull into the ocean. See `spawnPad` in
	-- BossArenas: the pad's height is authored and it is quoted here.
	local pad = (BossArenas.items[islandId] or {}).spawnPad
	if pad then
		local ring = {}
		local count2 = math.max(count, 1)
		-- THE PAD IS ARENA-LOCAL AND `center.Y` IS ZERO, so a room that is not
		-- at sea level needs its lift adding here. This is the fix for a bug
		-- that was live in `maelstrom_gullet` and would have been live in
		-- `pyrelisk_heart` on the day its mesh imported.
		--
		-- `spawnPad.offset` is the authored z of the pad in its own mesh's
		-- frame - the Tidebreak's 17.4 is the quarterdeck above the waterline,
		-- the gullet's 2.4 is the entry pad above the room's floor datum, and
		-- the heart's 3.4 is the same. `center.Y` is 0 for every row by this
		-- file's own header ("Y ignored; the platform sits at the waterline"),
		-- which is TRUE of where the arena is placed on the map and says
		-- nothing about how high its floor ended up.
		--
		-- On a sea-level arena the two frames coincide and `center + offset`
		-- has always been right; the Tidebreak lands on its dais at world 17.4
		-- and still does, because its lift is zero. On a room pinned 600 studs
		-- up the lift never entered the sum, so the party was placed at world
		-- Y 2.4 - under a floor at 600, inside the ocean slab, with no warning
		-- from anything: `verifyWaterline` checks the arena's GEOMETRY, and the
		-- geometry was fine. It is the drop-in that was in the wrong world.
		--
		-- THE ROWS STAY IN ONE FRAME. The alternative was to pre-lift the two
		-- interiors' offsets in BossArenas (write 602.4 instead of 2.4), and
		-- the mesh lane's note on the heart's pad argues against it correctly:
		-- one room quietly using a different convention from the other is a
		-- worse bug than the one it works around. Every `spawnPad.offset` in
		-- that file means the same thing, and the lift is applied once, here.
		local at = center + pad.offset + Vector3.new(0, arenaLift[islandId] or 0, 0)
		for i = 1, count2 do
			local angle = (i / count2) * math.pi * 2
			-- One player stands ON the mark; a party rings it. `+ 3.5` is the
			-- same settle clearance the disc branch below uses.
			local spread = if count2 > 1 then pad.radius else 0
			local pos = Vector3.new(at.X + math.cos(angle) * spread, at.Y + 3.5, at.Z + math.sin(angle) * spread)
			-- A party faces the mark it is standing round; a solo arrival has
			-- no ring to face and would hand `lookAt` two identical points (a
			-- NaN CFrame, and a character dropped in with no heading at all),
			-- so it faces the ARENA CENTRE instead - which on both of these
			-- meshes is where the fight is: down the deck from the Tidebreak's
			-- stern dais, and at the heart from the gullet's entry pad.
			local face = if spread > 0 then Vector3.new(at.X, pos.Y, at.Z) else Vector3.new(center.X, pos.Y, center.Z)
			table.insert(ring, CFrame.lookAt(pos, face))
		end
		-- ONE CHECK FOR THE WHOLE RING, and it is COMPLETE rather than a
		-- sample: every position in this branch is built at `at.Y + 3.5`, so
		-- the ring has exactly one Y and checking it once checks all of it.
		checkDropBand(islandId, at.Y + 3.5)
		return ring
	end
	-- The arena's own floor at the drop-in radius, NOT the waterline: the
	-- Ashfall Throne's is 292 studs up, and the old constant landed the whole
	-- party in the sea underneath it. One probe for the ring rather than one
	-- per player - the drop-in circle is a circle, so they all stand on the
	-- same ground - and it is `World.WATER_Y` exactly for every other arena.
	-- See "the floor" above.
	local floorY, floorPart = BossArenaService.floorY(islandId, radius)
	-- IS THE DROP-IN CIRCLE OVER THE MOAT? Ask, because the answer changed
	-- underneath this function: a hazard surface no longer collides (see
	-- HAZARD_MARKERS), so a ring radius that lands on the Ashfall Throne's
	-- lava lake used to put the party on solid magma and now drops it 292
	-- studs into the sea. The radius is `Bosses.<island>.arena.radius + 8`,
	-- fight tuning that lives in another file, so this cannot be fixed here -
	-- but it can refuse to be silent. For the volcano the window is the rim
	-- path itself: outside PY_LAKE_R (120, whose edge wobbles +/-3.4, so call
	-- it 124) and inside PY_CLEAR_R (200, where the lip starts overhanging) -
	-- a roam radius of roughly 120-190.
	--
	-- It takes a real misplacement to fire. The lake surface is authored 0.10
	-- above the path, never below it, so an inner probe crossing the moat can
	-- never out-bid an outer one standing on rock: only a ring whose OWN
	-- radius is over the lava reaches this warn.
	if floorPart and isHazard(floorPart.Name) then
		warn(
			string.format(
				"[BossArenaService] %s drop-in ring (r=%.0f) stands on %q, a non-collidable hazard "
					.. "surface - the party will fall through it on summon. Move Bosses.%s.arena.radius "
					.. "out past the hazard and back inside the arena's clear radius.",
				islandId,
				radius,
				floorPart.Name,
				islandId
			)
		)
	end
	local ring = {}
	for i = 1, math.max(count, 1) do
		local angle = (i / math.max(count, 1)) * math.pi * 2
		local pos = Vector3.new(center.X + math.cos(angle) * radius, floorY + 3.5, center.Z + math.sin(angle) * radius)
		table.insert(ring, CFrame.lookAt(pos, Vector3.new(center.X, pos.Y, center.Z)))
	end
	-- ...and the same one check on the disc branch, where the single Y is
	-- `floorY + 3.5`. This branch takes its height from a PROBE against the
	-- arena's own geometry, so it should be inside the band by construction -
	-- which is the point: a warn from here would mean the probe and the placed
	-- model disagree about where this arena is, and that is worth hearing about
	-- even though no path known today can produce it.
	checkDropBand(islandId, floorY + 3.5)
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
	-- ...and `groundFrom`, the same idea from the other end, for an arena whose
	-- middle is not ground. The Choirfloor's is a pit: the fallback has no floor
	-- inside the lip at all, and the authored mesh has a wobbling near-vertical
	-- wall there, so every probe under this radius either misses or reports a
	-- face as though it were footing. Unset (every other row) it is 0 and the
	-- sweep is exactly what it was.
	local groundFrom = pose.groundFrom or 0
	local worst, worstAt = 0, 0
	local probes = 0
	for step = 1, GROUND_PROBES do
		local r = reach * (step / GROUND_PROBES)
		if r < groundFrom then
			continue
		end
		local best = nil
		for bearing = 0, GROUND_BEARINGS - 1 do
			local theta = (bearing / GROUND_BEARINGS) * math.pi * 2
			-- The floor probe's window, not a local 200/-400 pair. Those
			-- numbers were written when every arena was at the waterline, and
			-- they cannot REACH a floor 292 studs up: the first arena on a
			-- mountain to be given a POSE_ARENA row would have had all twelve
			-- probes miss, `probes == 0`, and the checker report success by
			-- finding nothing - a silent pass, which is the one failure mode
			-- this whole function exists to remove. Sea-level arenas are
			-- unaffected; the highest thing any of them puts under the window
			-- is Brinejaw's 54-stud lighthouse.
			local from = Vector3.new(
				arena.center.X + math.cos(theta) * r,
				World.WATER_Y + FLOOR_PROBE_TOP,
				arena.center.Z + math.sin(theta) * r
			)
			local hit = Workspace:Raycast(from, Vector3.new(0, -FLOOR_PROBE_DEPTH, 0), params)
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
	-- Hand the floor probe something to cast at. Set before the loop, so an
	-- arena placed below can be probed the moment it exists.
	arenaFolder = folder

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
			local placed, lift, band = placeAuthored(folder, arena, template)
			-- KEEP THE LIFT BEFORE IT IS GONE. See `arenaLift`: this is the
			-- only frame in which the mesh's authored floor and the row's
			-- `meshBottom` both exist, and `ringPositions` needs the
			-- difference to put a party down in a room that is not at sea
			-- level. Keyed by the BossArenas KEY, not by `arena.islandId`:
			-- they agree on every row today, and the two that matter most are
			-- exactly the rows whose key is not an island at all.
			-- ...and the caldera, on the instance placement just created. A
			-- no-op for every arena without a `caldera` row, which is all of
			-- them but the Ashfall Throne. It is armed HERE and not on the
			-- fallback path below for a reason that is not an oversight: the
			-- procedural stand-in builds discs and a rim, and has no
			-- `_LakeFloor` and no `_Shaft` to swap - an arena whose mesh has
			-- not been imported has no caldera to open, and `applyCaldera`
			-- would have nothing to do but warn about it on every server
			-- start.
			if placed then
				arenaLift[islandId] = lift
				arenaBand[islandId] = band
				armCaldera(placed, arena, islandId)
			end
			-- ...and the wall the mesh does not provide, where a row asks for
			-- one. AFTER the placement, because it stands on the floor that
			-- placement just created and probes for it. See "containment".
			buildBarrier(folder, arena, islandId)
		else
			buildFloor(folder, arena, radius, pose.ground, pose.pit)
			-- The floor the rest of the stand-in stands ON, probed off what
			-- buildFloor just built rather than assumed to be the sea. It is
			-- `World.WATER_Y` bit for bit for every sea-level arena - the
			-- SEA_LEVEL_BAND snap, so Brinejaw's 0.4-stud outer sand cannot
			-- nudge its palisade - and the summit for a pose whose profile is
			-- on a mountain. Pinning these to the waterline instead put the
			-- one thing keeping a fight out of the sea 292 studs below the
			-- ground it rings, and the bait stones with it.
			local base = BossArenaService.floorY(islandId, radius)
			buildRim(folder, arena, radius, base)
			buildSpire(folder, arena, pose)
			-- COVER BEFORE STONES, and the order is load-bearing: Brinejaw's
			-- three reef stones appear in both tables, and only `cover` carries
			-- the measured width and rise that make one big enough to hide
			-- behind. `buildStones` skips a name that already exists, so the
			-- cover row wins and the bait targets are the same rocks either way.
			buildCover(folder, arena, base, pose.ground)
			buildStones(folder, arena, base)
			-- ...and the bell the head strikes, which stands on nothing: it
			-- hangs off the tower at the row's own Y.
			buildBell(folder, arena)
			-- The other arena's furniture, on the same floor: the choir's seven
			-- collars, and the six blades that are the only thing in this folder a
			-- beam can be blocked by. Both are no-ops for an arena that declares
			-- neither. `pose.ground` goes with them because the shelf they stand on
			-- is not flat.
			buildSockets(folder, arena, base, pose.ground)
			buildFins(folder, arena, pose, base)
			-- ...and the containment wall, on the STAND-IN floor too. It was
			-- built only on the authored path, so every arena a player fights
			-- before its mesh is imported - which is all of them right now -
			-- had no barrier and could be left to dodge an attack (or be
			-- shoved out of by Riptide). Same opt-in `barrier` row, same probe:
			-- `floorY` answers the procedural floor here exactly as it answers
			-- the authored one.
			buildBarrier(folder, arena, islandId)
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
