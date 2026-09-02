--!nonstrict
-- World.luau
-- Island geometry, in one place.
--
-- This is shared rather than private to WorldService because later slices need
-- the same numbers: enemies have to rest exactly on the deck surface, and the
-- fishing code has to know where the arena is. Two copies of "the deck is at
-- y=3" that drift apart produce fish standing inside the floor, so there is
-- only ever one copy.

local World = {}

-- ---------------------------------------------------------------- instance names

-- WorldService parents everything it builds under one Workspace folder, and
-- the sea is a single part in it. Named here because the fishing code on both
-- sides raycasts against that folder and recognises the water by this name
-- (CastAim); a rename in WorldService alone would silently break casting.
World.FOLDER_NAME = "World"
World.OCEAN_NAME = "Ocean"

-- Every surface a cast may land on, by part name. The ocean is one flat
-- plane at WATER_Y; the volcano's lava lake is a mesh part ~165 studs up,
-- fished from the crater rim (user, 2026-08-23). CastAim accepts either and
-- hands back the landing at that surface's own height, so everything
-- downstream (bobber, splash, where the catch surfaces) follows the point's
-- Y instead of assuming the waterline.
World.FISHABLE_NAMES = {
	[World.OCEAN_NAME] = true,
	Volcano_Lava = true,
	-- Blackmire Fen's interior murk pools (the Swamp mesh, revamp S2). The
	-- sea around the fen is the ordinary ocean; these are the still black
	-- pools inland that fish the swamp roster.
	Swamp_Water = true,
	-- Frostmaw Reach's pre-cut fishing holes in the ice sheet (one object).
	Frostmaw_IceHoles = true,
	-- Gloomtrench's black pools; Wreckwater's central bay among the hulks.
	Gloomtrench_DarkWater = true,
	Wreckwater_Bay = true,
	-- The Maelstrom site's whirlpool disc (built procedurally by
	-- WorldService, not imported - the name is the contract all the same).
	Maelstrom_Water = true,
	-- The Boiling Shoal's hot lagoon (islet redesign 2026-09-02): its own
	-- milky-turquoise disc inside the caldera ring. Fishable, and it draws
	-- the OCEAN pool below - the islet quests are pinned waters="ocean", so
	-- a player standing in the lagoon still progresses them, and no creature
	-- roster exists for a "boilshoal" water. Give it one later if the shoal
	-- ever earns its own species; both tables change together then.
	Boilshoal_Lagoon = true,
}

-- Which POOL of creatures a fishable surface draws from, by part name. This is
-- what keeps a Yellow Perch out of the lava and a Magma Guppy out of the sea:
-- a creature row's `waters` (Creatures.luau) has to match the water the cast
-- landed in, and a row without one is an ocean row. Adding a fishable surface
-- means adding it to BOTH tables - a surface missing here would silently fish
-- the ocean pool.
World.WATERS_OCEAN = "ocean"
World.WATERS_BY_PART = {
	[World.OCEAN_NAME] = World.WATERS_OCEAN,
	Volcano_Lava = "volcano",
	Swamp_Water = "swamp",
	Frostmaw_IceHoles = "ice",
	Gloomtrench_DarkWater = "gloom",
	Wreckwater_Bay = "wreck",
	Maelstrom_Water = "maelstrom",
	Boilshoal_Lagoon = World.WATERS_OCEAN,
}

-- The two collision groups that make the world's invisible barriers ONE-WAY
-- (user, 2026-08-23). WorldService registers them and puts every barrier it
-- builds in BARRIER; CreatureModel puts every creature part in CREATURE; the
-- pair is set non-collidable, so a catch thrown in over a wall passes through
-- it while players are still stopped by it. Nothing keeps creatures IN except
-- WorldService.clampToBounds, which CreatureService runs every position
-- through - that is the "one way" half.
World.BARRIER_COLLISION_GROUP = "Barrier"
World.CREATURE_COLLISION_GROUP = "Creature"

-- The boat (Session 3) floats by holding its own Y at WATER_Y, so it must NOT
-- rest on the solid ocean slab: the ocean part sits in WATER and every boat
-- part in BOAT, and the pair is non-collidable (players still stand on both).
-- BOAT is also non-collidable with CREATURE so a thrown catch can't beach on
-- a parked hull mid-arc.
World.BOAT_COLLISION_GROUP = "Boat"
World.WATER_COLLISION_GROUP = "Water"

-- Parts a cast's aim ray passes straight through (CastAim). The barriers are
-- built non-query-able, which should already keep them out of every raycast;
-- naming them keeps casting working even if one is ever made query-able.
-- Anything with "Dock" in its name is passed through as well.
World.CAST_PASS_THROUGH_NAMES = {
	RimWall = true,
	PierRail = true,
}

-- ---------------------------------------------------------------- heights

World.WATER_Y = 0

-- The dock's walkable surface. A sand bank sits *low* - the reference look is
-- planks barely above the water, not a raised platform - so this is just
-- above the waterline. The dock is part of the island mesh; this number must
-- equal the DOCK_TOP that assets/island_gen.py prints when it regenerates.
-- Enemies later rest at exactly this height.
World.DECK_Y = 2.4

World.SEABED_Y = -70

-- ---------------------------------------------------------------- footprint

-- The island is a Blender-authored mesh (assets/island_gen.py); this is its
-- nominal shoreline radius (ISLAND_RADIUS in the generator) - the actual
-- coastline wobbles around it. Used for placing things relative to "the edge
-- of the sand".
World.ISLAND_RADIUS = 96

-- Dock geometry. The dock is built into the island mesh by build_dock() in
-- assets/island_gen.py; these mirror that script's DOCK_* constants so the
-- fishing code can find the end of the dock without re-deriving it.
World.DOCK_WIDTH = 10
World.DOCK_START_Z = 74.5 -- first plank, on dry sand (the generator prints this)
World.DOCK_LENGTH = 52
World.DOCK_END_WIDTH = 18 -- the wider square at the far end
World.DOCK_END_LENGTH = 13

-- The round platform at the end of the dock where fights happen.
--
-- It exists because a fight needs a stage. Creatures that keep their distance
-- would otherwise end up out over open water, somewhere a player standing on a
-- narrow dock could never reach - and a new player holding nothing but their
-- fists would simply be stuck. Later slices clamp enemies to this circle.
World.ARENA_RADIUS = 38

-- ---------------------------------------------------------------- derived

-- The island sits at the origin; the dock runs out along +Z.
World.ORIGIN = CFrame.new(0, World.DECK_Y, 0)

World.DOCK_END_Z = World.DOCK_START_Z + World.DOCK_LENGTH

-- Arena deck overlaps the dock end slightly so there is no gap to fall through.
World.ARENA_CENTER = Vector3.new(0, World.DECK_Y, World.DOCK_END_Z + World.ARENA_RADIUS - 4)

-- There is deliberately no fixed casting spot: you can cast from anywhere you
-- can see open water within Tuning.Cast.MAX_DISTANCE (CastAim decides).

-- South beach. Only X and Z matter: WorldService probes straight down from
-- SPAWN_PROBE_HEIGHT to find the sand's real height there and puts the spawn
-- pad on it, so the character can't start inside (or under) the mesh. The Y
-- here is just the fallback if the probe finds nothing to stand on.
World.SPAWN_POSITION = Vector3.new(0, 14, -50)
World.SPAWN_PROBE_HEIGHT = 200

return World
