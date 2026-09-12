--!nonstrict
-- BossArenas.luau
-- Where each island's boss LAIR sits: a dedicated arena far out in the open
-- ocean (user, 2026-08-28: the islands are too confined for the huge bosses -
-- "having a new arena also allows us to customize the boss to use its
-- surroundings more"). Summoning the boss teleports the challengers here
-- (BossService); the island itself stays a fishing ground.
--
-- Placement rule: a 24,000-stud ring, each arena pushed out along its
-- island's bearing from the origin (the starter, bearingless at the origin,
-- goes due west into the empty quadrant). Islands reach ~15.6k from the
-- origin and the ocean tile grid is guaranteed to +/-32.6k (WorldService
-- OCEAN_MIN_SPAN), so every center has 8k+ studs of clear water to the
-- nearest island and to the ocean's edge. The values are hand-typed products
-- of that rule - same convention as Islands.worldPosition - so any single
-- arena can be nudged without touching the others.
--
-- An island with NO row here fights its boss in place, exactly as before.
-- That WAS the Maelstrom's deliberate state - the Kraken's whirlpool site was
-- a purpose-built arena already - and it no longer is: the Kraken's rework
-- stages the fight on a ship (the Tidebreak) and then inside the animal
-- itself, so the Maelstrom takes its reserved ring slot at (8000, -22600) and
-- summoning there teleports out like every other boss. Today every island with
-- a boss has a row, and the fight-in-place branch is kept because the code
-- path is the honest fallback for the next arena that has not been built yet,
-- not because anything is using it.
--
-- `model` names the authored replacement mesh: import a group whose parts
-- are prefixed `<model>_` (with a `<model>_Base` present) into
-- ReplicatedStorage/Assets - either inside IslandPack or standalone - and
-- BossArenaService places it instead of the procedural platform, no code
-- change needed (the island-mesh convention, assets/island_gen.py).
-- `meshBottom` is that mesh's authored bbox bottom (the pack build's HANDOFF
-- line), so its z=0 lands exactly on the waterline.
--
-- The fight's roam disc stays in Bosses.luau (`arena.radius` - fight
-- tuning); this file is world layout only. Deliberately NOT in Islands.luau:
-- island footprints drive the containment sweep, raid HUD, weather, and cast
-- range, and an arena must never count as an island.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local World = require(Shared.Config.World)

local BossArenas = {}

export type Palette = {
	floor: Color3,
	rim: Color3,
	-- Fight furniture that must read against the floor (the Choirfloor's
	-- socket collars). Optional: rows without it fall back to `rim`.
	socket: Color3?,
}

export type Arena = {
	islandId: string,
	center: Vector3, -- Y ignored; the platform sits at the waterline
	model: string, -- authored-mesh name (see header)
	meshBottom: number?,
	-- Optional INVISIBLE CONTAINMENT RING, arena-local. An authored mesh is
	-- supposed to wall its own play area in; when it does not - because the
	-- wall is a low decorative lip, or because two of its objects do not quite
	-- meet - this puts one there instead. `radius` is where the ring's INNER
	-- FACE stands (studs from `center`, so it is read in the same frame as
	-- `stones`), `height` how far its top sits above the arena's own floor,
	-- which BossArenaService probes rather than assumes - a summit arena gets
	-- its barrier at the summit, a sea-level one gets it at the waterline.
	--
	-- OPT-IN, and only on the authored path: an arena with no `barrier` row
	-- builds precisely what it built before this field existed - no part, no
	-- probe, no cost. Five of the six rows here have none.
	--
	-- `sizeX`/`sizeZ` OPT IN TO A BOX instead of the ring, and the Kraken's
	-- ship is why they exist. A ring is the right shape for a disc arena and
	-- the wrong one for a hull: the Tidebreak is 170 studs long on 40 of beam,
	-- so the smallest circle that contains it leaves 70 studs of open sea off
	-- either rail - and the sea is WALKABLE (WorldService's ocean tiles are
	-- 4-stud slabs whose top face is exactly WATER_Y), so that is not a wide
	-- arena, it is an exit. Half-extents from `center`, so the box's inner
	-- faces stand at +/-sizeX on X and +/-sizeZ on Z. `radius` is still
	-- required and is read as the barrier's BOUNDING radius by `floorY`'s
	-- probe clamp; a row without the two new fields builds the ring it always
	-- did.
	barrier: { radius: number, height: number, sizeX: number?, sizeZ: number? }?,
	palette: Palette,
	-- Fight furniture, arena-local XZ: the boss's own mechanics read these.
	-- Brinejaw's three reef stones are the slam-bait targets, and they match
	-- the `<Model>_ReefStone1..3` objects the authored mesh carries (their
	-- HANDOFF positions, converted from the generator's Blender axes).
	stones: { Vector3 }?,
	-- THE COVER FIELD: every place on this arena's floor that casts a
	-- WAVE SHADOW. Brinejaw's Riptide crosses the entire ring and the only
	-- answer to it is to put something solid between you and it, so "where can
	-- you hide" stopped being scenery the moment that attack existed - it is
	-- fight data, and it has to be ONE table or the three things that read it
	-- (the shadow test, the procedural stand-in, the authored mesh) will
	-- disagree about where safety is while all three look right in isolation.
	--
	-- `offset` is arena-local XZ, the same frame as `stones`. `radius` is the
	-- MEASURED half-width of the piece's shadow - use it, not a nominal
	-- "reached it" distance, because the wave is stopped by the rock's EDGE.
	-- `rise` is how far the top stands over the beach at that radius, and
	-- every entry clears 5 studs: a player has to fit behind it.
	-- `part` is the authored object's name minus the `<model>_` prefix, so the
	-- fallback builds a stand-in under the same name the mesh imports under,
	-- and either build answers a lookup identically.
	-- `sizeX`/`sizeZ` are the RECTANGULAR form, opt-in, half-extents in the
	-- same arena-local frame: a ship's deck cargo is a crate stack, not a
	-- boulder, and "am I behind it" on a 90-stud waist has to be asked against
	-- the footprint the artist actually built or the answer is generous on one
	-- axis and mean on the other. `radius` stays required (it is the circular
	-- fallback, and what the stand-in builds with when the pair is absent).
	cover: { { offset: Vector3, radius: number, rise: number, part: string, sizeX: number?, sizeZ: number? } }?,
	-- Where the lighthouse bell hangs, arena-local and FULL XYZ (unlike
	-- `stones`, whose Y is meaningless): Bell Toll has the serpent's head
	-- strike it and rings expand from the tower, so the attack needs a point in
	-- the air, not a footprint. Measured off the authored mesh; BrinejawPath
	-- and the pose read it from here rather than each keeping a constant.
	bell: Vector3?,
	-- Noctyss's seven socket collars: where the Lantern Choir grows. Same
	-- idea as `stones` - authored furniture the fight logic has to find - and
	-- the same numbers the arena's HANDOFF prints, mirrored into Roblox space
	-- (Blender +Y exports as -Z; see Shared/Modules/NoctyssPath).
	sockets: { Vector3 }?,
	-- THE FOUR WRAP POINTS on the Kraken's ship: the boarding gaps cut in the
	-- bulwark where an arm can take hold (arena_gen.py's KA_WRAPS, already
	-- mirrored into Roblox space - author +Y is PORT and exports as -Z). Same
	-- idea as `stones` and `sockets`: authored furniture the fight logic has to
	-- find, in ONE table, because the mesh's reinforcement marks, the arm's
	-- anchor and the wrench channel's counter all have to name the same four
	-- places. Full XYZ - Y is the deck the gap is cut in, and the arm plants at
	-- deck level, not at the waterline.
	wraps: { Vector3 }?,
	-- WHERE THE PARTY LANDS, arena-local and FULL XYZ. `ringPositions` drops
	-- challengers on a circle around the arena CENTRE, which is right for a
	-- disc and catastrophic for a ship: the Tidebreak's centre is its waist,
	-- and a ring of the Kraken's roam radius around it lands the whole party
	-- in the sea off both rails. The Kraken's arena authors a dais on the
	-- quarterdeck for exactly this (arena_gen's KA_SPAWN_X) and this is where
	-- that dais is. `radius` is the ring drawn ON the pad, so a party of six
	-- still arrives spread out rather than stacked in one column.
	--
	-- Y IS ABSOLUTE, not probed: `floorY` snaps anything within
	-- SEA_LEVEL_BAND of the waterline to WATER_Y exactly (which is correct -
	-- the Kraken is measured from the sea), so the probe cannot be asked
	-- where the quarterdeck is. The pad's own height is in the arena's HANDOFF
	-- and it goes here.
	spawnPad: { offset: Vector3, radius: number }?,
	-- HOW FAR THE FIGHT IS WALKED, in studs from `center`. Optional, and it
	-- overrides a formula rather than adding a new one: without it the service
	-- infers the walkable disc from the boss's roam radius and its longest
	-- attack reach, which is a good guess for an arena the procedural path
	-- built and a poor one for an authored mesh whose sand runs further than
	-- either number. The Careenage is walkable to r 132 against a roam of 80,
	-- so the fallback floor came out 32 studs short of the sand every number in
	-- that fight assumes, and both verifiers stopped probing before the head of
	-- the beach - the one place with only 0.65 studs of flight clearance.
	--
	-- ONE NUMBER, THREE READERS: the fallback floor's radius, `verifyGround`'s
	-- sweep and `verifyWaterline`'s. A row without it behaves exactly as it did
	-- before this field existed.
	floorRadius: number?,
	-- THE ONE ARENA WHOSE GEOMETRY CHANGES MID-FIGHT, named here rather than
	-- hard-coded in the service that swaps it.
	--
	-- The Ashfall Throne's caldera OPENS when the colossus dies: the lava
	-- drains, the disc that closes the lake floor goes, and a shaft is under
	-- it that the party jumps into (the Pyrelisk redesign, act 3 -> act 4).
	-- `BossArenaService` does the swap off the `PyreliskCaldera` attribute,
	-- and what it swaps is THESE OBJECTS - by name, out of this row, for the
	-- same reason `stones` and `sockets` are here: the generator authors the
	-- names, the fight has to find them, and a service that spelled them
	-- itself would be a second copy of a contract the exporter owns.
	--
	-- SUFFIXES, not full names: the reader prepends `<model>_`, exactly as
	-- `cover.part` is stored minus its prefix. So `_LakeFloor` is
	-- `PyreliskArena_LakeFloor` in Workspace.
	--
	-- `landing` is arena-local FULL XYZ (the `bell` / `spawnPad` convention,
	-- not `stones`' XZ-only): the foot of the shaft, which is where a fall
	-- that nothing catches ends up and where the inert slice-5 target puts a
	-- player back. Y is absolute over the arena's own floor datum.
	--
	-- OPT-IN. Every other row has no `caldera` and the swap never runs for
	-- them - no listener, no lookup, no cost.
	caldera: {
		lakeFloor: string,
		shaft: string,
		lava: string,
		landing: Vector3,
	}?,
	-- THE SIX WALL VENTS of the heart chamber, arena-local FULL XYZ: they are
	-- the room's shooters (`Fn.pyreliskHeartVents` picks among them and hands
	-- each to `Fn.throwGlob` as that glob's ORIGIN), and they stand at three
	-- different heights on the wall, so unlike `sockets` the Y is the whole
	-- point. Same rule as `sockets` otherwise: authored order, and the count
	-- is load-bearing.
	vents: { Vector3 }?,
}

BossArenas.items = {
	tropical = {
		islandId = "tropical",
		center = Vector3.new(-24000, 0, 0),
		model = "BrinejawArena",
		-- arena_gen's HANDOFF prints this as SKIRT_BOTTOM - 0.5. Leaving it to
		-- the -9 default landed the whole arena 0.5 studs high, which used to
		-- be shrugged off as cosmetic - it is not. Every height this fight
		-- reasons about is measured from `sandY`, so a lifted floor shifts the
		-- sweep bands against the players standing on it, and the procedural
		-- fallback now builds that profile exactly. Half a stud of daylight
		-- between the two would put the authored arena and the stand-in back
		-- to playing differently, which is the whole thing this pass removed.
		meshBottom = -9.5,
		palette = {
			floor = Color3.fromRGB(230, 207, 160), -- sun-bleached sand bar
			rim = Color3.fromRGB(124, 94, 62), -- driftwood palisade
		},
		stones = {
			Vector3.new(38.6, 0, -10.4),
			Vector3.new(-28.3, 0, -28.3),
			Vector3.new(-10.4, 0, 38.6),
		},
		-- RIPTIDE'S ANSWER, measured off the build (arena_gen.py's BJ_COVER,
		-- whose HANDOFF prints these lines already mirrored into Roblox space -
		-- paste from there, never from the generator's own build-space pairs).
		--
		-- The three reef stones alone could not be this list. They sit at one
		-- radius on three bearings 120 degrees apart, so a wave arriving on any
		-- of the three arcs between them had NO cover in it at all, and the
		-- authored `SeaStacks` that look like they would help stand at r 83-86 -
		-- outside the reef fence, past anywhere a player can stand. Five pieces
		-- were added inside the field to close that: two stacks at r22 and two
		-- at r58 on the bearings the stones leave open, and the hulk, which is
		-- the ship the beached rowboat came from, laid under the leaning mast
		-- that until now grew out of bare sand.
		--
		-- The stones were also GROWN to spec (they were 3.7 studs wide and stood
		-- 1.3 proud of the beach - something you trip over, not something you
		-- hide behind). Their CENTRES are untouched: Tail Slam baits onto them.
		--
		-- MEASURED COVERAGE, 24 bearings x radii 20/40/60: worst distance to the
		-- nearest cover EDGE is 25.7 studs (bearing 195, r20), 1.6 s at walk
		-- speed 16; worst centre-to-centre is 30.6. Re-run that math if any
		-- offset here moves.
		cover = {
			{ offset = Vector3.new(38.6, 0, -10.4), radius = 3.4, rise = 5.5, part = "ReefStone1" },
			{ offset = Vector3.new(-28.3, 0, -28.3), radius = 3.4, rise = 5.5, part = "ReefStone2" },
			{ offset = Vector3.new(-10.4, 0, 38.6), radius = 3.4, rise = 5.5, part = "ReefStone3" },
			{ offset = Vector3.new(-5.7, 0, -21.3), radius = 4.0, rise = 7.0, part = "CoverStack1" },
			{ offset = Vector3.new(5.7, 0, 21.3), radius = 4.0, rise = 7.0, part = "CoverStack2" },
			{ offset = Vector3.new(15.0, 0, -56.0), radius = 5.0, rise = 8.0, part = "CoverStack3" },
			{ offset = Vector3.new(-56.0, 0, 15.0), radius = 5.0, rise = 8.0, part = "CoverStack4" },
			{ offset = Vector3.new(41.0, 0, 41.0), radius = 5.5, rise = 7.0, part = "CoverHulk" },
		},
		-- The bell, hung off the lighthouse gallery on REST.BEARING (342 deg) -
		-- the bearing the head already rests over, so Bell Toll's strike reads
		-- without the pose moving. Y is arena-local and the arena centre is the
		-- waterline, so this is world Y 53 with `meshBottom` at -9.5.
		-- It used to lie half-buried in the sand 46 studs out, where no head
		-- strike could ever have reached it.
		bell = Vector3.new(8.6, 53.0, -2.8),
		-- THE ARENA HOLDS YOU IN. Radius 82 sits just past the wave's outer
		-- reach (76) and inside the floor edge (~86), so the fight renders
		-- fully but a player cannot walk - or be SHOVED - out to dodge an
		-- attack by leaving. Riptide throws you OUTWARD at push 46; without
		-- this wall that shove was an exit. Height 28 is far over a jump (7)
		-- plus the shove's tiny vertical arc (~1.3 studs), and the ring is
		-- CanQuery = false so every cast, aim and ground probe still passes
		-- through it - it stops characters and nothing else.
		barrier = { radius = 82, height = 28 },
	},
	swamp = {
		islandId = "swamp",
		center = Vector3.new(22200, 0, 9000),
		model = "GnashrootArena",
		-- arena_gen HANDOFF: the Rootmere's skirt closes at -9.5. The only
		-- arena row that lacked this; the -9 default floated it half a stud
		-- and verifyGround cannot see it (POSE_ARENA has no gnashroot row).
		meshBottom = -9.5,
		palette = {
			floor = Color3.fromRGB(54, 48, 34), -- packed peat
			rim = Color3.fromRGB(40, 52, 34), -- mangrove wall
		},
	},
	ice = {
		islandId = "ice",
		center = Vector3.new(19000, 0, 14600),
		model = "RimefangArena",
		-- HOW FAR THE FLOE IS WALKED. The Floe v2 (arena_gen.py, 2026-09-09) is
		-- one flat sheet out to r 120 with the pressure ridge at 122-132; the
		-- old mesh stopped at 70. Without this the service infers the disc from
		-- the roam radius and the longest attack reach, which for a boss that
		-- now leaps 70 studs and erupts through the ice is nowhere near the
		-- edge of the ice - and both verifiers would stop probing 50 studs
		-- short of ground the fight is played on. The procedural fallback
		-- builds its floor to the same number, so the two versions of this
		-- arena stay the same size.
		floorRadius = 120,
		-- THE THIN ICE, as the fight reads it. Four patches of young ice out by
		-- the rim, decorative until the boss's phase-two opener SHATTERS the sheet
		-- and they become open water: chill pools that persist for the rest of
		-- the fight.
		--
		-- THESE ARE SHARDS NOW (Floe v3, 2026-09-12). The walkable disc is 43
		-- separate MeshParts and the young ice IS four of them -
		-- `RimefangFloe.thinIce` = { 32, 35, 39, 42 } - so these four offsets are
		-- those shards' own area centroids, copied from `RimefangFloe.shards`,
		-- and `thinIceRadius` is sized to a shard (the plates are 200-1650 square
		-- studs) rather than to the old hand-measured patch.
		--
		-- WHY THE ROW STAYS POSITIONAL rather than holding the four ids: two
		-- readers want points, not ids. CreatureService's `Fn.rfShatterSites`
		-- resolves them against the boss's anchor for the chill pools, and
		-- CreatureEventController CROSS-CHECKS the server's `rimeShatter` sites
		-- against this row and warns when they disagree - both of which do
		-- Vector3 arithmetic on whatever is in here. FloeService owns the shard
		-- ids; this row owns where they are. If the floe is regenerated, copy the
		-- four centroids out of RimefangFloe again.
		thinIce = {
			Vector3.new(-75.37, 0, 72.8), -- Shard32
			Vector3.new(34.77, 0, 101.24), -- Shard35
			Vector3.new(73.91, 0, -75.88), -- Shard39
			Vector3.new(-73.19, 0, -80.07), -- Shard42
		},
		thinIceRadius = 20,
		-- THE FLOE HAS A HOLE IN THE MIDDLE, and anything that assumes floor at
		-- the centre of this arena is wrong. `RimefangFloe.hole` is the pre-cut
		-- breathing opening: r 14.4 at the arena centre, covered by no shard.
		-- It is where the boss rises (her anchor IS the centre) and where the
		-- Blowhole Cast window opens - so it is deliberately open water, and the
		-- party's drop-in ring (`BossService` asks for `arena.radius + 8` = 78)
		-- stands well outside it.
		-- NO COVER, ON PURPOSE (user brief, 2026-09-09: "redesign the arena to
		-- make it easier for the user to focus more on the boss rather than
		-- trying to dodge the arena's obstacles"). This row used to carry three
		-- `stones` echoing the authored Floe's bergs and whaler, and
		-- `washSheltered` raycast them as the wave wash's answer. The v2 floe
		-- has NOTHING standing inside r 120 - the bergs, the whaler and the
		-- bones are backdrop out past the ridge at r 150-158 - so those three
		-- entries would have pointed at bare ice and the shelter test would
		-- have been a lie told with numbers rather than an honest false.
		--
		-- The wash's counterplay is now the floor itself: the disc is nearly
		-- three times the area it was, and getting out of the wash's line is
		-- sidestepping, not finding furniture. `washSheltered` returns false
		-- everywhere on this arena by design; anything that treated a false as
		-- "the mechanic is broken" is reading the old arena.
		-- The Floe authors a -9.5 skirt (arena_gen.py's HANDOFF prints it).
		-- Without this the -9 default lands the whole raft half a stud high,
		-- which is cosmetic on its own but puts the authored arena and the
		-- procedural fallback on different ground - and the fallback now
		-- builds its floor from the fight's own profile, so they would play
		-- differently.
		meshBottom = -9.5,
		palette = {
			floor = Color3.fromRGB(200, 225, 240), -- sheet ice
			rim = Color3.fromRGB(140, 180, 210), -- pressure ridge
		},
	},
	volcano = {
		islandId = "volcano",
		center = Vector3.new(23400, 0, 5200),
		model = "PyreliskArena",
		-- MEASURED off the build, not the skirt convention. The Ashfall Throne
		-- is a volcano SUMMIT, not a platform at sea level: its walkable rim
		-- path is 292 studs up, and what hangs lowest in the mesh is not the
		-- mountain's cut flank (-302) but the cloud deck's billows (-376.7),
		-- which is the number placeAuthored actually pins. Taking the -9
		-- default would have lifted the whole arena - boss, fight and all -
		-- by 293 studs.
		--
		-- Re-derive from arena_gen.py's HANDOFF ("SET BossArenas meshBottom
		-- = ...") after any change to the cloud deck, since that is what sets
		-- the bbox floor. At this value the flank's cut sits just under the
		-- waterline and hides itself (-302 authored, the number above, so world
		-- Y -10), and nothing PLAYABLE is below Y = 0 - which matters because
		-- the ocean slab is solid to players with its top face there.
		--
		-- WHAT THIS LINE USED TO CLAIM, and could not: that the cloud deck
		-- floats clear ABOVE the waterline. `meshBottom` is derived FROM the
		-- deck - the deck's lowest billow IS the bbox floor, which is the whole
		-- reason this number is -84.7 and not the flank's -302 - so placing that
		-- floor at -84.7 puts the deck's underside exactly 84.7 studs BELOW the
		-- sea, by construction, for any value derived this way. The sentence was
		-- self-contradicting rather than merely wrong.
		--
		-- It costs nothing: `PyreliskArena_CloudDeco` is non-collidable and
		-- non-queryable by the `Deco` name rule, and it hangs 700+ studs out
		-- past anything walkable. The true statement, for whoever reasons from
		-- this next: the deck's PLANE sits 32 studs above the waterline
		-- (PY_CLOUD_Z -260 against the +292 rim) and its billows hang off it,
		-- the lowest of them through the sea.
		meshBottom = -84.7,
		-- THE CONTAINMENT THE MESH DOES NOT PROVIDE. The Ashfall Throne's outer
		-- lip is a low, overhanging ribbon, authored that way so the five vista
		-- notches stay open - and measured off the export it does not hold a
		-- player in. Its inner apex is at r229 and only 0.55 * crest high: 1.78
		-- studs at a notch (BELOW Roblox's ~2-stud automatic step-up, so it is
		-- WALKED over across 110 degrees of the circle) and 6.05 everywhere else
		-- (against a stock jump of 6.37-7.2 - clearable, worst case by 0.32).
		-- The Gate's two side blocks are worse: flat tops at +6.00 at r~226, one
		-- of them inside a notch, which is a staircase.
		--
		-- radius 234: two studs outside the walkable path's edge (PY_PATH_R
		-- 232), so the full path stays walkable and the barrier stands in the
		-- lip's own footprint. Rebuilding the lip taller is NOT the fix - the
		-- vista is the point of the notches - so the wall is invisible instead.
		--
		-- height 24: the highest ground a player can reach INSIDE the ring is
		-- the lip's top surface at r234, which is 9.08 studs up (it climbs from
		-- the 6.05 apex at r229 to crest+jitter 11.5 at r238, so 6.05 + 5/9 of
		-- 5.45); the Gate blocks' +6.00 is lower and does not set the ceiling.
		-- 9.08 + a 7.2-stud jump puts a player's feet at 16.3, so 24 clears the
		-- best case by 7.7 - more than another whole jump. See BossArenaService
		-- buildBarrier for the rest of the arithmetic and for why this ring is
		-- solid to characters but invisible to every raycast in the game.
		barrier = { radius = 234, height = 24 },
		-- WHAT OPENS WHEN THE COLOSSUS DIES. See `caldera` in the type block
		-- above for the contract; these three names are the ones
		-- `assets/arena_gen.py` authors for the caldera split (slice 5's mesh
		-- half: `build_py_base` becomes an ANNULUS from r118 out, and the
		-- centre disc it used to carry becomes `_LakeFloor`, with `_Shaft`
		-- underneath it).
		--
		-- `_Lava` ALREADY EXISTS and is already non-collidable (HAZARD_MARKERS
		-- in BossArenaService: the lake is a hole to walk into and a surface to
		-- cast at). It is named here because the drain has to hide it in the
		-- same step the floor goes - a lava surface still drawn over an open
		-- shaft is the fight telling the player the moat is still there while
		-- the geometry says otherwise.
		caldera = {
			lakeFloor = "_LakeFloor",
			shaft = "_Shaft",
			lava = "_Lava",
			-- MEASURED (Pyrelisk mesh lane, session 71, slice 5/6 export).
			-- arena_gen.py: "SET BossArenas.volcano.caldera.landing =
			-- Vector3.new(0, -120.0, 0)". The shaft is authored from the lake
			-- floor's datum (mesh z 0, the rim path) down to mesh z -120, and
			-- Y here is arena-local over that same datum - so the foot stands
			-- at world Y 172 with `meshBottom` at -84.7. It is quoted from the
			-- export rather than derived from PY_RIM_WORLD_Y and a depth
			-- constant, because the depth was a free variable until the tube
			-- was built and the generator now prints what it actually made.
			--
			-- NOTHING CATCHES A FALL HERE, and that is the design: the shaft
			-- watch moves a player out at 70 studs down (`K.PY_SHAFT_DROP`),
			-- 50 studs above this plane, so the foot is a contract value and a
			-- backstop rather than a floor anyone stands on.
			landing = Vector3.new(0, -120.0, 0),
		},
		palette = {
			floor = Color3.fromRGB(43, 39, 43), -- cooled basalt
			rim = Color3.fromRGB(23, 23, 31), -- obsidian teeth
		},
		-- The nine obsidian monoliths standing on the rim path, from
		-- arena_gen.py's HANDOFF lines (build_py_teeth). They are the fight's
		-- BAIT TARGETS, the Brinejaw reef-stone role: a hand-slam that comes
		-- down beside one shatters it and buys the long punish window, where
		-- the same blow on open rock only jars the colossus.
		--
		-- They are cover first and furniture second - every one is a POINT,
		-- so a player breaks line of sight behind it and can never stand on
		-- top of it (the arena's horizontal-movement-only rule). Re-key from
		-- the generator's HANDOFF if the monolith scatter is ever reseeded.
		-- MIRRORED ON PURPOSE relative to the generator's build-space numbers.
		-- The glTF export maps blender (x, y, z) -> (x, z, -y), so roblox Z is
		-- the NEGATIVE of blender y. Copying the build pair straight across
		-- put all nine stones on the wrong side of the arena - silently, since
		-- a stone in the mirror position still exists, still sits on the flat
		-- floor, and only ever disagrees with the rock the player can see.
		-- arena_gen.py now prints these already negated ("Monolith%d ROBLOX
		-- rel"), so re-key from that line and paste it straight in.
		stones = {
			Vector3.new(-116.9, 0, -182.8),
			Vector3.new(-163.5, 0, -98.9),
			Vector3.new(-151.4, 0, 48.1),
			Vector3.new(80.6, 0, 150.0),
			Vector3.new(187.2, 0, 21.8),
			Vector3.new(-12.8, 0, 207.7),
			Vector3.new(138.1, 0, -162.6),
			Vector3.new(-156.3, 0, 123.6),
			Vector3.new(81.0, 0, -179.5),
		},
	},
	gloom = {
		islandId = "gloom",
		center = Vector3.new(23600, 0, -4100),
		model = "NoctyssArena",
		-- The Choirfloor's authored bbox bottom, from its build's HANDOFF.
		-- Leaving this unset pins to the -9 default and lifts the whole arena
		-- half a stud - which puts the authored shelf, the socket collars and
		-- the pit's rim all half a stud off the numbers NoctyssPath measures
		-- against, and silently re-opens the gap between this mesh and the
		-- procedural stand-in that the arena pass closed.
		meshBottom = -9.5,
		palette = {
			floor = Color3.fromRGB(24, 28, 40), -- abyssal shelf
			rim = Color3.fromRGB(14, 16, 24), -- lightless drop
			-- The chitin collars the choir grows from (arena_gen GLOOM_CHITIN):
			-- painted in the rim's near-black they are bumps, not landmarks.
			socket = Color3.fromRGB(74, 66, 86),
		},
		sockets = {
			Vector3.new(33.3, 0, -7.1),
			Vector3.new(15.2, 0, -30.4),
			Vector3.new(-14.3, 0, -30.9),
			Vector3.new(-33.0, 0, -8.1),
			Vector3.new(-26.9, 0, 20.8),
			Vector3.new(-0.5, 0, 34.0),
			Vector3.new(26.3, 0, 21.6),
		},
	},
	wreck = {
		islandId = "wreck",
		center = Vector3.new(19100, 0, -14500),
		model = "WrackArena",
		-- MEASURED off the build (minimum vertex z over every object), not
		-- taken on the HANDOFF's word: on a shoal whose whole boundary is
		-- half-sunk hulls, "the skirt is still the lowest thing in the mesh"
		-- is exactly the assumption worth checking.
		--
		-- IT STOPPED HOLDING IN THE REBUILD, which is why this number moved.
		-- The new palisade's deepest keels bottom out around -11, three studs
		-- under the -9.5 the old 99-stud shoal closed at, so placement would
		-- have been handed to one randomly-seeded ship - the exact failure
		-- this comment warns about, arriving from the direction it warns about
		-- it from. arena_gen now closes a hidden underside cap (WK_CAP_Z)
		-- BELOW the whole fleet at -13.5, which restores the property this row
		-- states outright: the base's own skirt is the bbox floor
		-- placeAuthored pins. Left at -9.5 the whole Careenage imports four
		-- studs high.
		meshBottom = -13.5,
		-- THE REBUILT CAREENAGE'S SAND, measured: one plain beach walkable to
		-- r 132 with nothing standing on it, the palisade of grounded hulls
		-- starting at 141. The fight is tuned to that number throughout - balls
		-- retire at 140, `aggro` 165 covers it, the party rings in at 88 - so
		-- the stand-in floor and both verifiers have to know it too. See
		-- `floorRadius` in the type above.
		floorRadius = 132,
		-- Containment for the STAND-IN floor, the same gap tropical had: the
		-- authored palisade (grounded hulls, r 141+) walls the mesh version in,
		-- but the procedural fallback builds only the 132-stud sand and nothing
		-- to hold a player on it. Radius 130 sits just INSIDE that sand, not at
		-- the palisade's 141 - a wall only contains where there is floor under
		-- it, and the fallback floor ends at 132, so a ring at 136 would stand
		-- 4 studs out over open water. On the authored path 130 is well inside
		-- the hull ring and contains a touch tighter, which is harmless.
		barrier = { radius = 130, height = 24 },
		palette = {
			floor = Color3.fromRGB(78, 64, 48), -- rotten deck timber
			rim = Color3.fromRGB(60, 70, 62), -- barnacled gunwale
		},
	},
	-- ============================================================ the finale
	-- THE MAELSTROM NOW HAS A ROW, and the header's paragraph about it not
	-- having one is settled here: the Kraken's rework stages the fight on a
	-- SHIP - the Tidebreak, arena_gen.py's `kraken` builders - instead of on
	-- the whirlpool's rock stacks, so summoning at the site teleports out to
	-- the lair exactly as every other boss does. The reserved ring slot the
	-- header names is the one taken.
	--
	-- THE SHIP IS THE ARENA ORIGIN. `KrakenArena_Base` is the hull and it is
	-- centred on the authored origin, so `placeAuthored` lands the SHIP on
	-- `center` - the Kraken's HEAD is NOT here. It stands off the port beam at
	-- arena-local (0, -370) (author (0, +370); author +Y is port and exports
	-- as Roblox -Z), which is the fight logic's offset to apply and not this
	-- file's: CreatureService's K.KRAKEN.HEAD_AT carries it.
	--
	-- AXES, once, for everything below: X is the ship's length (bow +X, stern
	-- -X), Y is height with the waterline at 0, Z is the beam with PORT at -Z.
	maelstrom = {
		islandId = "maelstrom",
		center = Vector3.new(8000, 0, -22600),
		model = "KrakenArena",
		-- MEASURED off assets/arena_kraken.glb (minimum vertex y over every
		-- object), not taken on the keel's word: KA_KEEL_Z is -14 but the foam
		-- ring and the hull's own skirt hang to -15.4, and `placeAuthored` pins
		-- the model's BBOX floor, not the keel. Left at the -9 default the
		-- whole ship imports 6.4 studs high - which is not cosmetic here,
		-- because the sweep planes, the cover clearances and the standing/
		-- crouched head heights this fight is built out of are all quoted off
		-- the main deck at z 8.0 and every one of them would move with it.
		meshBottom = -15.4,
		-- The hull is 170 long on 40 of beam. Probing and floor-building past
		-- that is asking about open sea; `verifyWaterline` reads this too, and
		-- the hull below the waterline is correctly below it.
		floorRadius = 92,
		palette = {
			floor = Color3.fromRGB(74, 62, 47), -- deck planking (arena_gen KA_DECK_COL)
			rim = Color3.fromRGB(52, 43, 34), -- bulwarks (KA_RAIL)
			socket = Color3.fromRGB(95, 90, 79), -- the spawn dais (KA_PAD)
		},
		-- THE CONTAINMENT, and on this arena it is the fight rather than a
		-- safety net. arena_gen's HANDOFF puts it plainly: "THE SEA IS STILL
		-- SOLID" - the ocean tiles are 4-stud slabs a player stands on, the
		-- bulwark is 2.8 studs of decorative lip over an 8-stud drop, and no
		-- mesh in the glb can stop somebody simply walking off the rail and
		-- away from the finale across open water. Nothing about the Kraken
		-- fight survives that, so the wall has to be wiring.
		--
		-- A BOX, not a ring (see `barrier` in the type above): the hull is
		-- convex in plan and 170 x 40, so the smallest circle round it would
		-- fence 70 studs of walkable sea off either beam. sizeX 92 stands 7
		-- studs off the bow and stern posts; sizeZ 24 stands ~4 outboard of the
		-- widest bulwark line (|z| 19.0 amidships, from the HANDOFF's deck-edge
		-- table) - outside every boarding gap, so the four wrap points stay
		-- reachable, and inboard of nothing anyone can stand on.
		--
		-- height 34, measured the way the Ashfall Throne's 24 was: `floorY`
		-- snaps this sea-level arena to WATER_Y exactly, so the wall's base is
		-- 0 and the highest ground inside it is the quarterdeck at 17. 17 plus
		-- a stock 7.2-stud jump puts a player's feet at 24.2, so 34 clears the
		-- best case by nearly ten - more than another whole jump - and the
		-- skirt carries it 8 studs under the sea so nothing slips beneath it on
		-- a step off the rail.
		barrier = { radius = 92, height = 34, sizeX = 92, sizeZ = 24 },
		-- THE FOUR WRAP POINTS, from arena_gen's "WRAP POINT" HANDOFF lines
		-- with Roblox Z = -author Y. STAGGERED on X on purpose: no two arms
		-- opposite each other can own the whole width of the waist at once.
		-- Order is the authored one and it IS the WrapIndex the server stamps
		-- and the client claims an arm by, so these four lines may be re-keyed
		-- but never re-ordered.
		wraps = {
			Vector3.new(-26.0, 8.0, -18.88), -- 1 PortAft
			Vector3.new(34.0, 8.0, -16.51), -- 2 PortFore
			Vector3.new(-34.0, 8.0, 18.70), -- 3 StbdAft
			Vector3.new(22.0, 8.0, 17.78), -- 4 StbdFore
		},
		-- THE COVER FIELD, Brinejaw's role played by deck cargo: these four are
		-- what a lateral sweep passes over and what a sliding barrel breaks
		-- against. Every one is MEASURED off the build (arena_gen measures the
		-- stacks it actually made rather than asserting KA_COVER's `top`,
		-- because a crate that strayed above the sweep plane would delete the
		-- mechanic silently), tops 2.5-2.7 over the deck against a sweep plane
		-- at deck+3.0 and a standing head at deck+5.0. Rectangular, because
		-- they are crates: see `sizeX`/`sizeZ` in the type.
		--
		-- `rise` is the top over the deck, and the deck under all four is the
		-- main deck at 8 - every one of them is in the waist, which is the only
		-- floor phase one opens.
		cover = {
			{
				offset = Vector3.new(38.0, 0, -8.5),
				radius = 5.0,
				sizeX = 9.0,
				sizeZ = 4.5,
				rise = 2.6,
				part = "CoverCargoFore",
			},
			{
				offset = Vector3.new(2.0, 0, 1.0),
				radius = 5.0,
				sizeX = 8.5,
				sizeZ = 6.0,
				rise = 2.7,
				part = "CoverCoaming",
			},
			{
				offset = Vector3.new(-14.0, 0, -3.0),
				radius = 4.0,
				sizeX = 5.7,
				sizeZ = 5.7,
				rise = 2.5,
				part = "CoverCapstan",
			},
			{
				offset = Vector3.new(-30.0, 0, 9.0),
				radius = 4.0,
				sizeX = 6.0,
				sizeZ = 4.75,
				rise = 2.6,
				part = "CoverCargoAft",
			},
		},
		-- The drop-in dais, up on the quarterdeck at the stern (arena_gen
		-- KA_SPAWN_X -66, KA_QD_Z 17, dais r 7). Facing down the deck with the
		-- head off the party's left hand, and 26 studs aft of the quarterdeck's
		-- forward bulkhead - so the fight is something you walk INTO rather
		-- than something you materialise inside. 17.4 is the dais top, a
		-- fraction proud of the quarterdeck it stands on; `ringPositions` adds
		-- its own settle clearance on top.
		spawnPad = { offset = Vector3.new(-66.0, 17.4, 0), radius = 5.0 },
	},
	-- PHASE THREE, AND IT IS A DIFFERENT PLACE. `KrakenGullet_*` is a separate
	-- mesh authored about its OWN origin, where z = 0 is the FLOOR and not the
	-- waterline - so it is not an offset inside the ship's arena, it is a lair
	-- of its own that the fight teleports into through the siphon.
	--
	-- KEYED OFF AN ISLAND THAT DOES NOT EXIST, deliberately. `BossArenaService.
	-- init` walks this table by KEY and looks the key up in `Bosses.byIsland`
	-- for a roam radius and a pose; "maelstrom_gullet" misses both and takes
	-- the default 36 / no-profile branch, which is exactly right for a room
	-- whose geometry is authored and whose fight measures nothing off a ground
	-- profile. Nothing else in the project treats a BossArenas key as an island
	-- id: BossService reaches this table only through `centerFor`, with an id
	-- it took from a boss row.
	maelstrom_gullet = {
		islandId = "maelstrom_gullet",
		-- A CLEAN FAR SLOT, and it is off the 24,000-stud ring the header
		-- describes because this arena is not on that ring's business: nothing
		-- sails here and nothing is summoned here. Nearest neighbours are
		-- `tropical` at (-24000, 0) - 13.6k away - and the world origin; the
		-- ocean grid is guaranteed to +/-32,600 (WorldService OCEAN_MIN_SPAN)
		-- and this is comfortably inside it, so the room is not floating over
		-- the edge of the world where a fallen player would never land.
		center = Vector3.new(-20000, 0, -13000),
		model = "KrakenGullet",
		-- LIFTED 600 STUDS, and the lift is the whole reason this number is not
		-- the usual skirt convention. The gullet's floor is a shallow DISH -
		-- arena_gen's `_kg_floor` runs from -2.0 at the centre to +3.0 at the
		-- wall - and the ocean is a solid slab whose top face is exactly
		-- WATER_Y that nothing carves under an arena. At sea level the dais,
		-- the entry pad and the whole finale chamber would be filled to the
		-- brim and walked across, which is precisely what `verifyWaterline`
		-- exists to shout about; and the sea would be visible under a room the
		-- HANDOFF says has no sky and no sun.
		--
		-- So: the authored bbox floor (-16, measured off
		-- assets/arena_kraken_gullet.glb) goes to world Y 584, which puts the
		-- room's own z = 0 floor datum at 600. CreatureService derives every
		-- gullet height from those two numbers rather than keeping a third
		-- (K.KRAKEN.GULLET_LIFT), so this row moves the room and the fight
		-- follows it.
		meshBottom = 584.0,
		-- Playable footprint is ~236 across (KG_R 118 at the wall foot) with
		-- the floor running out to 132 so there is no crack at the join.
		floorRadius = 118,
		palette = {
			floor = Color3.fromRGB(74, 33, 38), -- gut wall (arena_gen KG_FLOOR)
			rim = Color3.fromRGB(55, 22, 28), -- the dome (KG_WALL)
			socket = Color3.fromRGB(106, 77, 117), -- the violet polyp collars (KG_COLLAR)
		},
		-- THE SIX POLYP SOCKETS, from the gullet's "Socket%d" HANDOFF lines
		-- with Roblox Z = -author Y. Order is the authored one and the fight
		-- plants polyp `i` on socket `i`. Y is the collar top over the room's
		-- floor datum - the dish is within a stud and a half of flat out at
		-- these radii (r 62-78 of a 118-stud room), so one number serves all
		-- six and the stalk stands on its own collar rather than in it.
		sockets = {
			Vector3.new(53.1, 1.6, -35.8),
			Vector3.new(-2.7, 1.6, -76.0),
			Vector3.new(-52.6, 1.6, -32.9),
			Vector3.new(-70.1, 1.6, 34.2),
			Vector3.new(-11.5, 1.6, 65.0),
			Vector3.new(51.4, 1.6, 53.2),
		},
		-- The entry pad (KG_ENTRY (0, -86), r 13, top 1.1 over the dish): drop
		-- the party here and the heart is dead ahead at 86 studs. It is the one
		-- place in this room a fight can begin from, so it is the spawn pad in
		-- the same sense the Tidebreak's dais is - and `ringPositions` reads
		-- the field the same way for both.
		spawnPad = { offset = Vector3.new(0, 2.4, 86.0), radius = 8.0 },
		-- The dome's wall is authored and collidable (the HANDOFF requires
		-- PreciseConvexDecomposition on `_Walls` or a default hull fills the
		-- room solid), so the containment here is a belt rather than the wall
		-- itself: the room is 600 studs up and a player who found a seam in a
		-- decomposed hollow dome would fall out of the world. r 116 stands two
		-- studs inside the wall foot; height 30 clears the dais (2.2) and a
		-- jump many times over, and the ring is CanQuery = false so nothing the
		-- fight casts can see it.
		barrier = { radius = 116, height = 30 },
	},
	-- ============================================================
	-- THE ASHFALL HEART - act 4 of the Pyrelisk fight, and the second key in
	-- this file that is NOT AN ISLAND.
	--
	-- Read `maelstrom_gullet` above first: this row is that row's shape, for
	-- that row's reasons. `BossArenaService.init` walks this table by key and
	-- looks each key up in `Bosses.byIsland` for a roam radius and a pose;
	-- "pyrelisk_heart" misses both and takes the default 36 / no-profile
	-- branch, which is correct for a room whose geometry is authored rather
	-- than inferred from a fight's numbers.
	--
	-- The BOSS row that fights here carries `islandId = "volcano"` - the same
	-- island, because the fight record, its participants and the ride home all
	-- key off it - and reaches this arena through its own `arenaKey` field
	-- (see BossService.arenaPosition). Those are two different questions and
	-- this file only answers the second one.
	--
	-- EVERY GEOMETRY NUMBER BELOW IS MEASURED, as of slice 6 (Pyrelisk mesh
	-- lane, session 71). `assets/arena_pyrelisk_heart.glb` exists now -
	-- `build_pyrelisk_heart` in arena_gen.py, 22 objects on the
	-- `build_kraken_gullet` template - and every field here is re-keyed from
	-- that export's HANDOFF lines rather than from the design's sketch. Where
	-- the two disagree the measurement won and the comment says so: the wall
	-- vents are the case worth reading (the design's flat r 92 is outside a
	-- dome above y 26), and `meshBottom` is the other (F-11).
	pyrelisk_heart = {
		islandId = "pyrelisk_heart",
		-- CHECKED AND KEPT (Pyrelisk mesh lane, session 71 - design flag F-10).
		-- The address the design proposed survives the check, so it stands:
		--
		--   nearest arena   `maelstrom_gullet` (-20000, 0, -13000)   26,000
		--   nearest arena   `tropical`         (-24000, 0,      0)   13,601
		--   nearest island  none - every island in Islands.luau is at
		--                   x >= 0 and |x| <= 15,400, so the whole -X half of
		--                   the world is empty but for the two rooms
		--   world edge      WorldService OCEAN_MIN_SPAN 65,280 (so +/-32,640);
		--                   this row is 23,853 from the origin, inside by 8,787
		--
		-- The gullet sits at the SAME X with the sign of Z flipped, which is
		-- why this was worth measuring rather than eyeballing: a typo between
		-- the two rows is a typo that still looks like a valid address.
		center = Vector3.new(-20000, 0, 13000),
		model = "PyreliskHeart",
		-- MEASURED (Pyrelisk mesh lane, session 71 - design flag F-11).
		-- arena_gen.py: "mesh bbox bottom z -14.000 (MEASURED across every
		-- object) ... SET meshBottom = 586.0".
		--
		-- LIFTED 600 STUDS for the gullet's reason and NOT by analogy with it:
		-- the ocean is a solid slab whose top face is exactly `World.WATER_Y`
		-- and nothing carves under an arena, so a sealed room at sea level is
		-- filled to the brim and walked across - which is precisely what
		-- `verifyWaterline` exists to shout about.
		--
		-- 586 AND NOT THE GULLET'S 584, which is the whole of F-11: the field
		-- is `(the world Y you want authored z = 0 at) + (the mesh's own bbox
		-- floor)`, the LIFT is what the two rooms share, and the bbox floors
		-- are different - the gullet's is -16 (its dish is deeper), this one's
		-- is -14 (`PyreliskHeart_Base`'s keel). Copying 584 across would have
		-- put this room's floor datum at 598 and dropped two studs of silent
		-- error into every height the fight reads off it.
		meshBottom = 586.0,
		-- MEASURED (Pyrelisk mesh lane, session 71). arena_gen.py builds the
		-- wall foot at r 96 with the floor running out to 108 so there is no
		-- crack at the join, and this field is the WALKABLE number, which both
		-- verifiers and the fallback floor read. The design's ask and the
		-- build agree, so the value does not move - but it is measured now
		-- rather than assumed.
		floorRadius = 96,
		-- Re-key from `build_pyrelisk_heart`'s own constants once it exists,
		-- the way every other palette in this file is re-keyed from its
		-- builder. Not geometry, so not a PLACEHOLDER in the same sense - but
		-- a palette typed here rather than generated is exactly where a colour
		-- goes quietly out of step with the mesh it is painting.
		-- RE-KEYED off `build_pyrelisk_heart`'s own constants (Pyrelisk mesh
		-- lane, session 71), which is the only way a palette typed here stays
		-- in step with the mesh it is painting. The room reuses the Pyrelisk's
		-- exterior palette rather than inventing one, and the VALUE LADDER is
		-- the point: the floor is basalt and is the brightest big surface, the
		-- walls are obsidian and sit deliberately under it, so what you fight
		-- on is never the darkest thing in frame. The two rock values are one
		-- LSB off the `volcano` row's (which rounded 0.170 -> 39 and 0.085 ->
		-- 23); these are what the builder's floats actually scale to.
		palette = {
			floor = Color3.fromRGB(43, 40, 43), -- cooled basalt (PH_FLOOR_COL = PY_BASALT)
			rim = Color3.fromRGB(22, 22, 29), -- obsidian (PH_WALL_COL = PY_OBSIDIAN)
			socket = Color3.fromRGB(120, 46, 20), -- the pillar collars (PH_COLLAR)
		},
		-- PLACEHOLDER: measured by the Pyrelisk mesh lane (session 71) after
		-- the heart build's HANDOFF. EIGHT pillar feet, and THE COUNT IS
		-- LOAD-BEARING: `PyreliskPillars` is a bitmask whose bit (i-1) is
		-- socket i in this table's authored order (design section 7.3), and
		-- `Bosses.items.pyrelisk_heart.parts.count` is 8 against these eight.
		-- A ninth socket with no bit behind it is the failure mode a bitmask
		-- has, and it is silent.
		--
		-- MEASURED (Pyrelisk mesh lane, session 71) - the eight
		-- "Socket%d ... ROBLOX rel" HANDOFF lines verbatim, with Roblox Z =
		-- -author Y, in the builder's own order. Y is each collar's TOP over
		-- the room's floor datum, and unlike the gullet's one-number-for-six
		-- these differ: the floor is a dish with a crust on it and the collars
		-- span r 44-70, so socket 7 seats 4.1 studs higher than socket 4.
		--
		-- Every radius is different and the bearings are staggered, which is
		-- the SPONSON RULE (the Wrack's casemates, applied to cover instead of
		-- to occlusion): no two pillars stand on the same line from the entry
		-- pad, because a pillar in another pillar's shadow is not cover and
		-- the room still looks like it has eight of them. The generator gates
		-- on it - `_ph_sponson_check` fails the build under 8 degrees of
		-- separation - and the built figure is 11.48.
		sockets = {
			Vector3.new(63.65, 1.37, -6.69), -- r 64, bearing 6
			Vector3.new(39.83, 1.54, -33.42), -- r 52, bearing 40
			Vector3.new(-5.85, 0.96, -47.64), -- r 48, bearing 97
			Vector3.new(-30.56, 0.42, -31.65), -- r 44, bearing 134
			Vector3.new(-55.79, 1.78, 4.88), -- r 56, bearing 185
			Vector3.new(-47.24, 2.17, 48.92), -- r 68, bearing 226
			Vector3.new(26.22, 4.54, 64.90), -- r 70, bearing 292
			Vector3.new(51.96, 1.63, 30.00), -- r 60, bearing 330
		},
		-- MEASURED (Pyrelisk mesh lane, session 71) - the six "Vent%d ... ROBLOX
		-- rel" HANDOFF lines, Roblox Z = -author Y. Six wall vents at three
		-- heights, and these are the points `Fn.pyreliskHeartVents` hands to
		-- `Fn.throwGlob` as each glob's ORIGIN, so a Z sign error here puts
		-- half the room's pressure behind the player instead of in front of
		-- them while every glob still flies correctly.
		--
		-- THE RADII ARE NOT 92, AND THAT IS THE MEASUREMENT THAT MATTERED. The
		-- design asks for "r 92" at y 14 / 26 / 38, which is a cylinder's
		-- number; the room is a DOME, and by y 38 its wall has already turned
		-- in to about 87. A vent authored at a flat 92 up there is OUTSIDE the
		-- room - buried in rock, invisible from every camera, throwing globs
		-- from a point no player can see or take cover from, and nothing
		-- anywhere would have said so. So each radius is the wall's own at
		-- that vent's height, less a 4-stud inset: 91.4 / 88.9 / 84.2 / 92.2 /
		-- 87.3 / 82.9 in the order below.
		vents = {
			Vector3.new(85.86, 14.00, -31.25), -- bearing 20, r 91.37
			Vector3.new(15.44, 26.00, -87.57), -- bearing 80, r 88.92
			Vector3.new(-64.49, 38.00, -54.12), -- bearing 140, r 84.19
			Vector3.new(-86.64, 14.00, 31.53), -- bearing 200, r 92.20
			Vector3.new(-15.15, 26.00, 85.93), -- bearing 260, r 87.26
			Vector3.new(63.47, 38.00, 53.26), -- bearing 320, r 82.86
		},
		-- MEASURED (Pyrelisk mesh lane, session 71). arena_gen.py: "ENTRY PAD
		-- centre (0.0, -74.0) r 11, TOP z 3.39 - Roblox-rel (0.0, 3.39, 74.0)".
		-- THE LANDING FLOOR: where the shaft's watch puts the party down, with
		-- the heart 74 studs dead ahead, and the one place in this room a
		-- fight can begin from.
		--
		-- Y IS AUTHORED, not probed, and that is not a shortcut - `floorY`
		-- SNAPS anything within SEA_LEVEL_BAND of the waterline to `WATER_Y`
		-- exactly, so on a room lifted 600 studs it cannot be asked where the
		-- pad is.
		--
		-- FLAGGED TO THE SERVER LANE, AND IT IS NOT THIS ROW'S TO FIX. This
		-- offset is ARENA-LOCAL - the gullet's 2.4 and the Tidebreak's 17.4
		-- are both the authored z of their own pad - but `ringPositions`
		-- computes `center + pad.offset` and `center.Y` is 0 by this file's own
		-- header ("Y ignored; the platform sits at the waterline"). On a
		-- SEA-LEVEL arena that is right and the Tidebreak lands correctly. On a
		-- room LIFTED by `meshBottom` it is not: the lift never enters the sum,
		-- so a party arriving here would be placed at world Y 3.4 under a floor
		-- at 600. `maelstrom_gullet` has exactly the same hole today (offset
		-- 2.4, room at 600), which is why the value below is written in the
		-- established frame rather than pre-lifted here - one room quietly
		-- using a different convention from the other is a worse bug than the
		-- one it works around. The fix belongs in `ringPositions`: add the
		-- row's own lift (`meshBottom` less the mesh's bbox floor) when a pad
		-- is on a lifted arena, and both rooms come right together.
		spawnPad = { offset = Vector3.new(0, 3.4, 74.0), radius = 11.0 },
		-- MEASURED (Pyrelisk mesh lane, session 71). The gullet's belt, one
		-- room over and for the same reason: the dome's wall is authored and
		-- collidable (the import owes PreciseConvexDecomposition on `_Walls`
		-- or a default hull fills the room solid), so this is a belt against a
		-- seam in a decomposed hollow dome - a room 600 studs up whose floor a
		-- player can find a crack in drops them out of the world. CanQuery =
		-- false, so nothing the fight casts can see it.
		--
		-- 94 IS TWO STUDS INSIDE THE WALL FOOT, and the wall foot is measured:
		-- the dome is faceted into 15 plates and its inner radius runs 91.74 to
		-- 97.18, nominal 96. So on the tightest facet this ring stands 2.3
		-- studs PROUD of the rock rather than inside it, which is the right
		-- side to be on - a belt behind the wall is a belt that never fires.
		-- 30 of height clears the dais (3.4) and a jump many times over.
		barrier = { radius = 94, height = 30 },
	},
}

-- The arena centre for an island, or nil when its boss fights in place.
function BossArenas.centerFor(islandId: string): Vector3?
	local arena = BossArenas.items[islandId]
	return arena and arena.center or nil
end

-- ---------------------------------------------------------- the mood footprint
--
-- WHICH LAIR IS THIS POSITION STANDING IN, answered ONCE for every system
-- that has to dress a lair in its island's clothes (user, 2026-09-12: "for
-- all of the boss arenas, make it so that the water is the same colour and
-- the air is the same as the island that it corresponds to"). Two consumers
-- read it today and they must never disagree:
--   * the AIR - WeatherController.refresh, which wears the owning island's
--     standing mood (or the lair's own, ARENA_MODES) out here;
--   * the WATER - OceanController.probeTint, which blends the sea to the
--     owning island's `water` palette.
-- This lived in WeatherController as `currentArenaIslandId` and moved here
-- verbatim when the water became the second consumer: one table and one loop,
-- so arena air and arena water are the same island by construction rather
-- than by a second copy of the numbers.

-- 140 studs. The lair floor is ~70 of walkable stone, its boundary ~75, foam
-- out to ~91; this clears the foam with room to spare, so a slam that throws
-- you off the rim never blinks the dark off mid-knockback. Erring wide is
-- free out here - the nearest island is 8k+ studs away (this file's header)
-- and there is nothing inside the circle but the lair.
BossArenas.MOOD_RADIUS = 140

-- ...except where a lair is not a disc at the waterline. The Ashfall Throne
-- is a volcano summit: its walkable rim path runs out to r = 232 and the
-- containment lip to 246 (arena_gen.py PY_PATH_R / PY_LIP_R), so the flat
-- 140 above drops out from under most of the path - the mood snapped to
-- clear as a player circled wide and back again as they came in, which broke
-- the ash mood in this arena before any summit mood existed. 340 covers the
-- path, the lip, and the same knockback margin the default leaves.
--
-- `minY` comes with the wider circle and only with it: the summit floor is
-- 292 studs up (PY_RIM_WORLD_Y), so the same XZ circle taken at the
-- waterline is open ocean UNDER the mountain, where a summit's air would be
-- nonsense. Arenas with no row here are discs at the waterline and want no
-- height gate at all. Keyed by `islandId` (the row key), so the two sealed
-- rooms - `maelstrom_gullet`, `pyrelisk_heart` - are keyed as themselves.
BossArenas.MOOD_BOUNDS = {
	volcano = { radius = 340, minY = 100 },
	-- ...and the Ashfall Heart is the opposite correction: a SMALL room, and
	-- the summit's 340 here would be three times its own wall. 150 covers the
	-- floor (r 108), the dome's outer shell (~117) and the same knockback
	-- margin the default leaves, and stops well short of claiming the empty
	-- ocean around it.
	--
	-- `minY` IS THE LIFT, not a cliff. This room is authored about its own
	-- floor datum and placed with `meshBottom = 586` against a bbox floor of
	-- -14, so its floor stands at world Y +600 and the walkable band runs 599
	-- to 601 with a 30-stud barrier over it. 520 sits comfortably below that
	-- and comfortably above the sea, which is the same job the summit's 100
	-- does at 292: the identical XZ circle taken at the waterline is open
	-- ocean, and open ocean must never wear a sealed chamber's air.
	pyrelisk_heart = { radius = 150, minY = 520 },
}

-- The boss lair a position is standing in, returned as the island that OWNS
-- it, the XZ distance to the arena centre, and the mood radius that claimed
-- it. A lair is its island's water even though it sits nowhere near the
-- footprint, so the moods have to travel out to it. Pure math over a table of
-- nine.
--
-- `ignoreHeightGate` drops the `minY` test. The AIR passes false: the
-- summit's gate exists so open ocean 292 studs below the Ashfall Throne does
-- not wear a mountaintop's sky. The WATER passes true, for exactly the same
-- reason read the other way - that sea IS the volcano's water, and it is the
-- only sea this arena has.
--
-- `slack` widens every radius by a fixed amount, for a consumer that wants a
-- FADE rather than an edge: OceanController passes the tint band's outer
-- reach so the sea starts turning before you are inside the lair, and gets
-- the distance back to blend with. The air passes nothing and keeps its
-- hard boundary.
function BossArenas.ownerIslandAt(
	position: Vector3,
	ignoreHeightGate: boolean?,
	slack: number?
): (string?, number?, number?)
	local here: string? = nil
	local bestDist = math.huge
	local bestRadius: number? = nil
	local reach = slack or 0
	for _, arena in BossArenas.items do
		local c = arena.center
		local bounds = BossArenas.MOOD_BOUNDS[arena.islandId]
		local radius = if bounds then bounds.radius else BossArenas.MOOD_RADIUS
		local dist = (Vector2.new(position.X, position.Z) - Vector2.new(c.X, c.Z)).Magnitude
		local gated = ignoreHeightGate == true or not bounds or position.Y - World.WATER_Y >= bounds.minY
		if dist < radius + reach and dist < bestDist and gated then
			bestDist = dist
			bestRadius = radius
			here = arena.islandId
		end
	end
	if not here then
		return nil, nil, nil
	end
	return here, bestDist, bestRadius
end

return BossArenas
