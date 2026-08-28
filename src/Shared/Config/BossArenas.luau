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
-- An island with NO row here fights its boss in place, exactly as before -
-- that is the Maelstrom's deliberate state: the Kraken's whirlpool site IS a
-- purpose-built arena already (site = true, fight stacks, undertow), so it
-- keeps its home. Its ring slot, (8000, -22600), stays reserved below.
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

local BossArenas = {}

export type Palette = {
	floor: Color3,
	rim: Color3,
}

export type Arena = {
	islandId: string,
	center: Vector3, -- Y ignored; the platform sits at the waterline
	model: string, -- authored-mesh name (see header)
	meshBottom: number?,
	palette: Palette,
}

BossArenas.items = {
	tropical = {
		islandId = "tropical",
		center = Vector3.new(-24000, 0, 0),
		model = "BrinejawArena",
		palette = {
			floor = Color3.fromRGB(230, 207, 160), -- sun-bleached sand bar
			rim = Color3.fromRGB(124, 94, 62), -- driftwood palisade
		},
	},
	swamp = {
		islandId = "swamp",
		center = Vector3.new(22200, 0, 9000),
		model = "GnashrootArena",
		palette = {
			floor = Color3.fromRGB(54, 48, 34), -- packed peat
			rim = Color3.fromRGB(40, 52, 34), -- mangrove wall
		},
	},
	ice = {
		islandId = "ice",
		center = Vector3.new(19000, 0, 14600),
		model = "RimefangArena",
		palette = {
			floor = Color3.fromRGB(200, 225, 240), -- sheet ice
			rim = Color3.fromRGB(140, 180, 210), -- pressure ridge
		},
	},
	volcano = {
		islandId = "volcano",
		center = Vector3.new(23400, 0, 5200),
		model = "PyreliskArena",
		palette = {
			floor = Color3.fromRGB(43, 39, 43), -- cooled basalt
			rim = Color3.fromRGB(23, 23, 31), -- obsidian teeth
		},
	},
	gloom = {
		islandId = "gloom",
		center = Vector3.new(23600, 0, -4100),
		model = "NoctyssArena",
		palette = {
			floor = Color3.fromRGB(24, 28, 40), -- abyssal shelf
			rim = Color3.fromRGB(14, 16, 24), -- lightless drop
		},
	},
	wreck = {
		islandId = "wreck",
		center = Vector3.new(19100, 0, -14500),
		model = "WrackArena",
		palette = {
			floor = Color3.fromRGB(78, 64, 48), -- rotten deck timber
			rim = Color3.fromRGB(60, 70, 62), -- barnacled gunwale
		},
	},
	-- maelstrom: no row ON PURPOSE - the Kraken fights at its whirlpool site
	-- (see header). Reserved ring slot if that ever changes: (8000, -22600).
}

-- The arena centre for an island, or nil when its boss fights in place.
function BossArenas.centerFor(islandId: string): Vector3?
	local arena = BossArenas.items[islandId]
	return arena and arena.center or nil
end

return BossArenas
