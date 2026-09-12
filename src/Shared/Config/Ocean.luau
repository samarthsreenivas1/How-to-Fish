--!nonstrict
-- Ocean.luau
-- The water surface's look and motion, in one place.
--
-- The ocean is still a single flat part (WorldService.buildOcean) - nothing
-- needs buoyancy or real waves. The stylised look is a flat blue plane with
-- one tiling "caustics" texture (assets/water_gen.py) laid over it, tinted
-- and faded from here; the motion is the client sliding that layer slowly
-- (OceanController). The white rim where water meets sand is geometry, not
-- texture: Island_Foam in the island mesh (build_foam in
-- assets/island_gen.py). Both sides read this module so they can never
-- disagree on layer names or tile sizes.

local Ocean = {}

-- ---------------------------------------------------------------- assets

-- Image asset id for the tile water_gen.py produces. Rojo can't sync images,
-- so it is uploaded once by hand (assets/README.md) and the id pasted here.
-- 0 = not uploaded yet: the ocean stays a bare blue plane and WorldService
-- warns with the steps.
Ocean.TEXTURE_ID = 132930391524358

-- ---------------------------------------------------------------- look

-- The plane itself. The texture is transparent between its lines, so this is
-- the colour of the water. Darkened twice now (user, 2026-08-22).
-- These are the OPEN-SEA base values: near an island that declares a `water`
-- palette (Islands.luau), the client blends away from them (see Ocean.TINT).
Ocean.COLOR = Color3.fromRGB(18, 88, 150)
Ocean.REFLECTANCE = 0.04

-- The sea floor slab under every tile. A constant, not a per-tile literal,
-- because it is both the server's resting colour (WorldService.buildOcean)
-- and the client blend's reset value (OceanController).
Ocean.SEABED_COLOR = Color3.fromRGB(30, 45, 55)

-- ---------------------------------------------------------------- island tint
--
-- Per-island water colours (user, 2026-08-28: "when I visit a new island
-- there should be a new environment... for the swamp a green/brown murky
-- color... smoothly transition into that color"). Each island may declare a
-- `water` palette in Islands.luau; OceanController blends the visible sea
-- toward it as the camera approaches, and back to the base above on the way
-- out. All client-side and visual-only, like the tide.
Ocean.TINT = {
	-- The spatial band, measured in studs PAST the island's nominal radius:
	-- fully the island's palette inside radius + FADE_NEAR (docks stay fully
	-- tinted while you fish off them), fully the open-sea base beyond
	-- radius + FADE_FAR, smoothstepped between. FADE_FAR is sized so a boat
	-- crossing reads a ~15-25s colour roll on approach, the whole band sits
	-- inside the animation radius, and radius + FADE_FAR never reaches
	-- halfway to a neighbouring island (spacing is 4000+; radii <= 700).
	FADE_NEAR = 300,
	FADE_FAR = 1500,

	-- Time smoothing on top of the spatial band: the applied colour eases
	-- toward the target with this time-constant, so a teleport FADES over a
	-- couple of seconds instead of snapping the whole sea.
	TAU = 1.5, -- seconds

	-- How often the target is recomputed from the camera position. The
	-- probe is a handful of distance checks; between probes the per-frame
	-- easing keeps everything smooth.
	PROBE_INTERVAL = 0.25, -- seconds

	-- When every colour channel is within this of its target, the blend is
	-- settled and the per-frame writes stop entirely.
	EPSILON = 1 / 512,
}

-- ---------------------------------------------------------------- tide
--
-- The waves that run up the beach and back (user, 2026-08-22: the water
-- shouldn't sit stagnant). No new geometry and no texture work - it's the
-- beach's own slope doing the job: raise the flat water plane a few tenths of
-- a stud and its edge sweeps several studs inland, covering the darker wet
-- sand and lapping onto the pale dry sand; lower it and the wet sand comes
-- back out. Driven entirely by OceanController on the client (see the note
-- there about why this is visual-only).
--
-- The foam rim rides along: it's a separate MeshPart in the island mesh, so
-- it's lifted by the same amount AND scaled slightly inward, which keeps the
-- white line sitting on the water's edge instead of stranding it out at its
-- baked radius while the water moves past it.
Ocean.TIDE = {
	-- How far the water plane rises and falls either side of World.WATER_Y.
	-- Small on purpose - the sweep comes from the slope, not the height.
	HEIGHT = 0.35, -- studs

	-- NOTE: the rim moves VERTICALLY only - it is never scaled horizontally.
	-- Chasing the water's edge across the sand by scaling the foam MeshPart
	-- slid the whole ring off the coastline, because Size scales about the
	-- part's own bounding-box centre and that box is dragged off-island by
	-- the dock-post collars baked into the same mesh; the collars ended up
	-- floating on open water. Keep HEIGHT modest so the water's edge never
	-- wanders far from where the rim is baked. Making the rim genuinely sweep
	-- inland needs the mesh regenerated with the rim centred and the collars
	-- split out (assets/island_gen.py) plus a Studio re-import.

	-- One slow swell plus a smaller faster one at an incommensurate period, so
	-- the water never repeats on an obvious beat.
	PERIOD = 7.0, -- seconds, the main swell
	CHOP_PERIOD = 3.1, -- seconds, the smaller one
	CHOP = 0.3, -- 0 = pure swell, 1 = all chop

	-- No wet-sand line here: the island's dark band (Island_Base3) is baked
	-- terrain and can't move, and the clone-the-foam workaround needed the
	-- horizontal scaling that broke alignment. Making the dark line sweep
	-- needs the same mesh regeneration noted above.
}

-- ---------------------------------------------------------------- interior waters

-- Island pools that wear the SAME dress as the sea (user, 2026-08-27: every
-- island's water must be visibly THE water - colour, texture, animation,
-- "literally copy and paste the water from the original one"). These arrive
-- as flat matte slabs baked into their island meshes; WorldService restyles
-- each to the ocean's colour/material and lays the same caustics layers on
-- its top face, and OceanController scrolls those layers and rides the part
-- on the same tide as the sea. Deliberately NOT here:
--   Volcano_Lava     - it's lava; LavaController's molten crust owns it.
--   Maelstrom_Water  - the whirlpool spins with its own tinted caustics
--                      (MaelstromVfxController owns its CFrame - a second
--                      animator would fight it).
Ocean.INTERIOR_WATER_NAMES = {
	Swamp_Water = true,
	Frostmaw_IceHoles = true,
	Gloomtrench_DarkWater = true,
	Wreckwater_Bay = true,
}

-- ------------------------------------------------------------ arena waters

-- The same idea one ring out: the water baked into a boss ARENA's mesh, which
-- wears the palette of the island that OWNS the lair (user, 2026-09-12: "for
-- all of the boss arenas, make it so that the water is the same colour... as
-- the island that it corresponds to"). BossArenaService.placeAuthored dresses
-- these from `Islands.items[arena.islandId].water` and overrides the
-- generated MeshColors row for them, exactly as WorldService does for the
-- interior pools above.
--
-- COLOUR AND REFLECTANCE ONLY - no caustics layers, deliberately.
-- OceanController adopts (and scrolls, and tides) only parts named in
-- INTERIOR_WATER_NAMES or World.OCEAN_NAME, so a layer laid on one of these
-- would sit dead still on water that rides no tide, which reads worse than no
-- layer at all.
--
-- Deliberately ABSENT, and each for the same reason - they are not water:
--   WrackArena_DecoShallows  - drowned WET SAND (arena_gen WK_WET).
--   PyreliskArena_LakeFloor  - basalt under the lava (and `_Lava` is lava;
--                              the volcano's own Volcano_Lava is excluded
--                              from the interior list above for that reason).
--   RimefangArena_ThinIce    - ice you stand on; `_Leads` are the open leads
--                              cut through the floe, and those are the water.
--   GnashrootArena_DecoShallows - wet mud at the mere's edge.
Ocean.ARENA_WATER_NAMES = {
	GnashrootArena_DecoMere = true,
	RimefangArena_Leads = true,
	-- The trench's pit water, and the ONE part in this table whose colour gets
	-- LIGHTER: MeshColors has it at (6,11,22) and the gloom island's own
	-- palette is (10,22,38). The island's palette is the target the user
	-- named, so it wins here too; the pit stays near-black and opaque
	-- (arena_gen: "Opaque: you cannot see what is under it").
	NoctyssArena_DecoPitWater = true,
}

-- Texture layers on the water. One on purpose: two layers sliding against
-- each other read as "too many overlapping animations" (user, 2026-08-22).
-- The tile's lines are white; `color` tints them down to a pale blue so they
-- read as light in the water rather than foam on it. `name` is the contract
-- between WorldService (creates the Texture) and OceanController (scrolls
-- it); `wobble` is a slow sideways sine in studs so the drift isn't a
-- conveyor belt.
Ocean.LAYERS = {
	{
		name = "WaterCaustics",
		tileStuds = 40,
		transparency = 0.55,
		color = Color3.fromRGB(150, 225, 250),
		drift = Vector2.new(0.35, 0.2), -- studs/second
		wobble = 0.8,
	},
}
Ocean.WOBBLE_PERIOD = 10 -- seconds

return Ocean
