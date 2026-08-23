--!nonstrict
-- Islands.luau
-- Every travellable island in one data-driven table. Adding an island is a
-- single entry here (plus importing its mesh and letting WorldService place
-- it) - the teleport menu (IslandsController) and the server side that both
-- places islands and handles travel (WorldService) read only from this.
--
-- The whole world is one Roblox place on one shared ocean plane; "islands" are
-- just meshes placed far apart on that plane, and "teleporting" moves the
-- character to the destination's spawn point (no TeleportService, no loading
-- screen). WorldService sizes the ocean to cover whatever is listed here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local World = require(Shared.Config.World)

local Islands = {}

-- Display order in the teleport menu.
Islands.order = { "tropical", "volcano" }

-- Each island:
--   name          - shown in the menu.
--   blurb         - one line under the name.
--   model         - the child of ReplicatedStorage/Assets that WorldService
--                   clones (the Studio-imported mesh). The starter's model is
--                   "Island" for back-compat with the existing import.
--   worldPosition - where WorldService centres the island on the shared ocean.
--                   Only X/Z matter: every island's waterline is aligned to
--                   y = 0 by its skirt, so worldPosition.Y is ignored. The
--                   starter sits at the origin so every coordinate already in
--                   World.luau still holds.
--   radius        - nominal shoreline radius (the generator's ISLAND_RADIUS);
--                   used to space islands and to size the ocean around them.
--   spawn         - world position a teleport drops the player on. Only X/Z
--                   are authoritative: WorldService probes the real ground
--                   there (from above the rim) and stands the player on it;
--                   the Y is just the fallback if nothing collidable is found
--                   (and the probe's reference height), so it can't go stale
--                   when a mesh is regenerated.
--   unlockLevel   - minimum player Level to travel here (0 = always open).
--   boss          - Bosses.luau id of the boss that guards this island. The
--                   NEXT island in `order` can't be travelled to until it's
--                   beaten (WorldService checks the player's
--                   `Cleared_<islandId>` attribute, set by BossService).
Islands.items = {
	tropical = {
		name = "Starter Cove",
		blurb = "The home island - calm water, easy fish.",
		model = "Island",
		worldPosition = Vector3.new(0, 0, 0),
		radius = World.ISLAND_RADIUS,
		spawn = World.SPAWN_POSITION,
		unlockLevel = 0,
		boss = "brinejaw",
	},

	-- Enable once assets/island_volcano.glb is imported to
	-- ReplicatedStorage/Assets as "Volcano" (assets/README.md). Until the mesh
	-- exists the menu shows it as "coming soon" and travel is refused, so it is
	-- safe to leave listed. Placed far from the origin so it doesn't overlap the
	-- starter on the shared ocean; the spawn is a point on the crater rim
	-- (rim top ~= y 200 in the generator) - tune it after importing.
	volcano = {
		name = "Ashfall Caldera",
		blurb = "A towering volcano - fish the lava from the crater rim.",
		model = "Volcano",
		worldPosition = Vector3.new(3000, 0, 0),
		radius = 640, -- capped so the base mesh imports (Roblox's 2048-stud limit)
		spawn = Vector3.new(3124, 205, 215), -- X/Z: on the rim right in front of the pier mouth, facing inward onto it; Y (~200) is the probe's reference + fallback only
		unlockLevel = 5,
		-- Casts from the rim reach further than on the beach: the lake is a
		-- cliff-drop below and ~385 studs across (radius ~192, LAKE_U 0.30 x
		-- 640; the rim's inner edge is ~205 out). With Tuning.Cast.MAX_DISTANCE
		-- 80 this gives 160 studs - past the lake's centre - and 256 with the
		-- Abyssal Rod's 1.6x; 3.0 reached the far shore once the base rose to
		-- 80 (2026-08-23).
		castRangeMult = 2.0,
		-- The playable area is the crater rim - a flat ring at ~y 200 whose
		-- outline wobbles with the generator's COAST_TERMS - plus the fishing
		-- pier that runs inward from it over the lava. WorldService SAMPLES the
		-- placed mesh to find the ring's inner/outer edge per angle (no fixed
		-- circle could follow the jagged outline), walls it invisibly so
		-- players can't leave it or fall into the lake, and clamps every
		-- creature to it (user, 2026-08-23).
		rim = {
			height = 200, -- the flat rim's height (island_gen PROFILE); ground within `tolerance` of it counts as rim
			tolerance = 4,
			minRadius = 120, -- where the radial search starts / ends, studs from worldPosition
			maxRadius = 480,
			step = 3, -- radial sample spacing
			samples = 180, -- angular samples round the ring (2 degrees each)
			cliff = 12, -- lava shore -> cliff top (PROFILE u 0.30 -> 0.32 x 640); the inner wall sits here at least

			wallHeight = 80,
			margin = 2, -- creatures are kept this far inside the edges
		},
		-- The rim pier (island_gen build_volcano_dock): found at runtime from
		-- the Volcano_Dock_Planks part (it's radial, so its centre gives the
		-- direction); these are its authored dimensions.
		pier = {
			partName = "Volcano_Dock_Planks",
			length = 130,
			width = 16,
			endLength = 24,
			endWidth = 30,
			deckY = 198,
		},
	},
}

-- The cast-range multiplier that applies to a cast from `position`: the
-- multiplier of the island whose footprint it's inside (its radius plus a
-- margin for docks and piers), else 1. Shared so CastAim gives the client
-- and the server the same answer.
function Islands.castRangeMultAt(position: Vector3): number
	for _, entry in Islands.items do
		local mult = entry.castRangeMult
		if mult and mult ~= 1 then
			local d = Vector3.new(position.X - entry.worldPosition.X, 0, position.Z - entry.worldPosition.Z).Magnitude
			if d <= entry.radius * 1.3 then
				return mult
			end
		end
	end
	return 1
end

return Islands
