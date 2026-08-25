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
	-- starter on the shared ocean.
	--
	-- REDESIGNED 2026-08-24 (user): a ~940-stud jagged stratovolcano you never
	-- climb. The playable area is the flat ash APRON around the foot at sea
	-- level - ocean-bounded exactly like the starter, so there is deliberately
	-- no `rim`/`pier` bounds block any more (WorldService's rim sampler is
	-- dormant without one). The fishing dock is a plain shore jetty into the
	-- SEA (Roblox +Z side, same convention as the starter's dock; you fish
	-- ocean water off it). Lava pours from the summit crater down every flank
	-- and dies in molten PONDS on the apron - those ponds are the island's
	-- fishable lava (the `waters = "volcano"` roster), reached on foot, and
	-- the apron is littered with burnt snags / basalt columns / cinder vents.
	volcano = {
		name = "Ashfall Caldera",
		blurb = "A towering volcano - fish its shore, brave the lava ponds.",
		model = "Volcano",
		worldPosition = Vector3.new(3000, 0, 0),
		radius = 640, -- capped so the base mesh imports (Roblox's 2048-stud limit)
		spawn = Vector3.new(3000, 12, 505), -- X/Z: on the ash apron right in front of the dock (dock starts at r~527 on +Z); Y is the probe's reference + fallback only
		-- Interim gate (docs/revamp-plan.md): the volcano is island 2 until the
		-- swamp and ice islands ship, so it opens right after Brinejaw's L1-7
		-- band. When it slides to slot 4 this becomes 22 (and the position moves).
		unlockLevel = 8,
		-- Pyrelisk guards it (summoned by Caldera's Call, exactly the Brinejaw
		-- ritual) - the progression chain no longer dead-ends here.
		boss = "pyrelisk",
		-- No castRangeMult: the dock fishes open sea and the lava ponds are
		-- fished standing beside them, so the base reach is right.
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
