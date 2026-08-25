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

-- Display order in the teleport menu - AND the progression chain: travel to
-- entry N+1 requires the `Cleared_` attribute of entry N's boss
-- (WorldService.handleTeleport). This is the revamp's final 6-island line
-- (docs/revamp-plan.md band table); The Maelstrom finale site deliberately
-- stays OUT of this list (Session 4 adds it as `site = true`).
Islands.order = { "tropical", "swamp", "ice", "volcano", "gloom", "wreck" }

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

	-- Blackmire Fen (revamp Session 2, slot 2, L8-14): the swamp. A meshless
	-- island shows as "coming soon" and refuses travel, so every entry below
	-- is safe to list before its import lands. Its interior murk pools are
	-- the fishable Swamp_Water (the `waters = "swamp"` roster); the sea off
	-- its +Z dock is ordinary ocean.
	swamp = {
		name = "Blackmire Fen",
		blurb = "Peat, murk, and things with too many teeth. The fen's gulls hunt back.",
		model = "Swamp",
		worldPosition = Vector3.new(3000, 0, 0),
		radius = 180,
		spawn = Vector3.new(3000, 4, 122), -- X/Z: on the bank before the dock (planks run Z=140..182); Y is the probe's fallback
		unlockLevel = 8,
		boss = "old_gnashroot",
	},

	-- Frostmaw Reach (slot 3, L15-21). Skeleton entry: b8's Session 4 lane
	-- fills the boss (rimefang) + kit; the Frostmaw_IceHoles water wiring
	-- lands with it.
	ice = {
		name = "Frostmaw Reach",
		blurb = "A frozen shelf over black water. Fish the ice-holes - mind the blizzards.",
		model = "Frostmaw",
		worldPosition = Vector3.new(6000, 0, 0),
		radius = 230,
		spawn = Vector3.new(6000, 5, 174), -- X/Z: shore before the dock (planks run Z=192..238); Y is the probe's fallback
		unlockLevel = 15,
	},

	-- Ashfall Caldera - FINAL slot 4 (L22-28; revamp Session 2 moved it from
	-- the interim slot). Content re-gates to the band in b8's Session 4 pass;
	-- its three guns already sit at L22/25/28.
	--
	-- REDESIGNED 2026-08-24 (user): a ~940-stud jagged stratovolcano you never
	-- climb. The playable area is the flat ash APRON around the foot at sea
	-- level - ocean-bounded exactly like the starter, so there is deliberately
	-- no `rim`/`pier` bounds block any more (WorldService's rim sampler is
	-- dormant without one). The fishing dock is a plain shore jetty into the
	-- SEA (Roblox +Z side); lava pours from the summit into molten PONDS on
	-- the apron - the island's fishable lava (`waters = "volcano"`).
	volcano = {
		name = "Ashfall Caldera",
		blurb = "A towering volcano - fish its shore, brave the lava ponds.",
		model = "Volcano",
		worldPosition = Vector3.new(9000, 0, 0),
		radius = 640, -- capped so the base mesh imports (Roblox's 2048-stud limit)
		spawn = Vector3.new(9000, 12, 505), -- X/Z: on the ash apron right in front of the dock (dock starts at r~527 on +Z); Y is the probe's reference + fallback only
		unlockLevel = 22,
		-- Pyrelisk guards it (summoned by Caldera's Call, exactly the Brinejaw
		-- ritual) - the progression chain no longer dead-ends here.
		boss = "pyrelisk",
		-- No castRangeMult: the dock fishes open sea and the lava ponds are
		-- fished standing beside them, so the base reach is right.
	},

	-- Gloomtrench (slot 5, L29-35). Skeleton: b8 fills the boss (noctyss) +
	-- kit + the Gloomtrench_DarkWater wiring + the lantern mechanic.
	gloom = {
		name = "Gloomtrench",
		blurb = "Where the light gives up. Bring your own, and keep it lit.",
		model = "Gloomtrench",
		worldPosition = Vector3.new(12000, 0, 0),
		radius = 200,
		spawn = Vector3.new(12000, 4, 154), -- X/Z: shore before the dock (planks run Z=172..216); Y is the probe's fallback
		unlockLevel = 29,
	},

	-- Wreckwater (slot 6, L36-42). Skeleton: b8 fills the boss
	-- (admiral_wrack) + kit + the Wreckwater_Bay wiring + boarding raids.
	wreck = {
		name = "Wreckwater",
		blurb = "A graveyard of ghost ships that never finished sinking.",
		model = "Wreckwater",
		worldPosition = Vector3.new(15000, 0, 0),
		radius = 210,
		spawn = Vector3.new(15000, 4, 167), -- X/Z: shore before the dock (planks run Z=185..231); Y is the probe's fallback
		unlockLevel = 36,
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
