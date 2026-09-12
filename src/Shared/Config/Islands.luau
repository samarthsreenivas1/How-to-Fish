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
--
-- MAP REDESIGN (2026-08-27, user: "huge huge huge ocean... they just take the
-- boat"): the islands no longer sit on a straight 3000-stud line along X.
-- They are scattered across one vast open sea in a voyage ARC that wraps
-- around Archway Cove - each leg of the saga is a real boat crossing, longer
-- than the last (~4,000 studs for the first, ~8,700 for the run to the
-- Maelstrom), tuned so every leg takes ~90s at the boat tier that unlocks it.
-- Boats.luau's speed/seaworthiness ladder is keyed to these legs - move an
-- island and re-check the leg table in its header. The teleport menu still
-- works as fast travel on top; the boat is the intended way across.

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
--   meshBottom    - authored z of the island model's LOWEST vertex, needed
--                   only when that lowest point is not the standard -9 skirt
--                   (geometry authored below it: seabed dunes, sunken keels, a
--                   trench). WorldService aligns the imported bbox bottom on
--                   this so the authored waterline lands on the ocean instead
--                   of the whole island riding high by the overshoot (the
--                   2026-08-27 "floating ships and litter" bug). Re-key from
--                   the pack build's HANDOFF mesh-bottom lines after any
--                   island mesh regen.
--   water         - OPTIONAL per-island water palette (user, 2026-08-28:
--                   "when I visit a new island, there should be a new
--                   environment"). { color, caustics?, causticsTransparency?,
--                   reflectance?, seabed? }. The server dresses the island's
--                   interior pools in it at placement (WorldService.
--                   applyMeshColors) and the client blends the surrounding
--                   SEA toward it as the camera sails in (OceanController,
--                   tuned by Ocean.TINT). Absent = the open-sea base
--                   (Ocean.COLOR etc.) - the starter cove stays tropical
--                   blue by omission. Any field left out falls back to the
--                   matching Ocean/LAYERS base value.
--   islet         - OPTIONAL. Marks a tiny off-route islet (2026-08-29): a
--                   real mesh, placed exactly like an island, but deliberately
--                   ABSENT from Islands.order - so nothing gates it, the
--                   travel menu never lists it, and the only way to reach one
--                   is to sail there. WorldService has a separate pass for
--                   these; without the flag an islet would build in Blender
--                   and never appear in the world. An islet's POSITION is a
--                   gate, not decoration: the only way there is by boat, so
--                   it must sit inside the seaworthiness of some place the
--                   player can already stand on by the level its resident's
--                   quests are gated to, or the NPC can never be met and
--                   those quests are never offered. tools/check_quest_reach.py
--                   FAILS on a stranded giver - run it after moving one.
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
		name = "Archway Cove",
		blurb = "The home island. Calm water, easy fish, and the stone arch on the beach.",
		model = "Island",
		worldPosition = Vector3.new(0, 0, 0),
		radius = World.ISLAND_RADIUS,
		spawn = World.SPAWN_POSITION,
		unlockLevel = 0,
		boss = "brinejaw",

		-- Session 3: the island lives between casts. Ambient hostiles wander
		-- the beach (SpawnerService - light weights on the light mobs), and
		-- now and then the cove's own nasties raid it in waves (RaidService).
		ambient = {
			rows = {
				{ id = "snapjaw_crab", weight = 4 },
				{ id = "pufferfish", weight = 3 },
				{ id = "tideline_skipper", weight = 2 },
				{ id = "gullet_cod", weight = 2 },
				{ id = "moonbell_jelly", weight = 2 },
				{ id = "pickpocket_hermit", weight = 1 },
				{ id = "sand_lurker", weight = 1 },
				{ id = "drowned_deckhand", weight = 1 },
			},
			maxAlive = 6,
			interval = 6,
		},
		raid = {
			interval = { 600, 900 },
			announce = 45,
			waves = {
				{ { id = "snapjaw_crab", count = 4 } },
				{ { id = "snapjaw_crab", count = 3 }, { id = "pufferfish", count = 2 } },
				{ { id = "drowned_deckhand", count = 2 }, { id = "tideline_skipper", count = 2 } },
			},
			reward = { coins = { 120, 180 }, xp = 90 },
		},
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
		-- Leg 1 of the voyage: ~4,000 studs NE of the cove (tier-1 crossing).
		worldPosition = Vector3.new(3700, 0, 1500),
		radius = 180,
		-- Peat murk: opaque, dead-flat, light barely gets in (the fen's
		-- design is "you can't see what's biting").
		water = {
			color = Color3.fromRGB(62, 72, 38),
			caustics = Color3.fromRGB(168, 180, 110),
			causticsTransparency = 0.72,
			reflectance = 0.01,
			seabed = Color3.fromRGB(46, 38, 24),
		},
		spawn = Vector3.new(3700, 4, 1617), -- X/Z: rel Z=117, on the +Z shore shelf of the restarted island (shore at rel Z=147 since the marsh-enlarge pass; no dock yet); Y is the probe's fallback
		unlockLevel = 8,
		boss = "old_gnashroot",

		ambient = {
			rows = {
				{ id = "mire_leech", weight = 4 },
				{ id = "bog_gull", weight = 3 },
				{ id = "croakjaw_toad", weight = 3 },
				{ id = "will_o_wisp", weight = 2 },
				{ id = "dread_dragonfly", weight = 2 },
				{ id = "snagtooth_gator", weight = 1 },
				{ id = "peat_revenant", weight = 1 },
			},
			maxAlive = 7,
			interval = 6,
		},
		raid = {
			interval = { 600, 900 },
			waves = {
				{ { id = "mire_leech", count = 4 }, { id = "croakjaw_toad", count = 2 } },
				{ { id = "bog_gull", count = 3 }, { id = "snagtooth_gator", count = 2 } },
				{
					{ id = "peat_revenant", count = 2 },
					{ id = "fen_serpent", count = 2 },
					{ id = "will_o_wisp", count = 2 },
				},
			},
			reward = { coins = { 260, 380 }, xp = 200 },
		},
	},

	-- Frostmaw Reach (slot 3, L15-21). Skeleton entry: b8's Session 4 lane
	-- fills the boss (rimefang) + kit; the Frostmaw_IceHoles water wiring
	-- lands with it.
	ice = {
		name = "Frostmaw Reach",
		blurb = "A frozen shelf over black water. Fish the ice-holes - mind the blizzards.",
		model = "Frostmaw",
		-- Leg 2: ~4,800 studs on from the fen, deeper into the north-east.
		worldPosition = Vector3.new(6800, 0, 5200),
		radius = 230,
		-- Black-blue under-shelf water with hard, glassy glints.
		water = {
			color = Color3.fromRGB(22, 62, 92),
			caustics = Color3.fromRGB(185, 235, 255),
			causticsTransparency = 0.45,
			reflectance = 0.09,
			seabed = Color3.fromRGB(26, 40, 54),
		},
		spawn = Vector3.new(6800, 8, 5374), -- X/Z: shore before the dock (planks run rel Z=192..238); Y is the probe's fallback (ground ~7.4 after the soft-glacier rebuild)
		unlockLevel = 15,
		boss = "rimefang",
		ambient = {
			rows = {
				{ id = "frostbite_pup", weight = 4 },
				{ id = "iceshard_crab", weight = 3 },
				{ id = "hailfin_skua", weight = 3 },
				{ id = "aurora_jelly", weight = 2 },
				{ id = "frozen_mariner", weight = 2 },
				{ id = "glacial_lurker", weight = 1 },
				{ id = "icevein_pike", weight = 1 },
			},
			maxAlive = 7,
			interval = 6,
		},
		raid = {
			interval = { 600, 900 },
			announce = 45,
			waves = {
				{ { id = "frostbite_pup", count = 4 }, { id = "iceshard_crab", count = 2 } },
				{ { id = "hailfin_skua", count = 3 }, { id = "frozen_mariner", count = 2 } },
				{
					{ id = "icevein_pike", count = 2 },
					{ id = "blizzard_wraith", count = 2 },
					{ id = "glacial_lurker", count = 2 },
				},
			},
			reward = { coins = { 700, 1000 }, xp = 550 },
		},
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
	-- RESTARTED FROM SCRATCH (2026-08-27, user) - the swamp-restart playbook:
	-- the stratovolcano build (trail, lava rivers, props, dock) was deleted
	-- and the rebuild goes step-by-step, reviewed between steps. STEP 1 is
	-- the bare landform, resized on review ("really really really tall...
	-- jagged... more randomized"): a ~895-stud shattered spire (broken
	-- ridgeline to ~950) with heavy crag + a height-varying outline over the
	-- WHOLE cone, a summit crater dish, and a broad flat ash apron. STEP 2
	-- (same day): the LAVA is back - a crater lake and six notch-fed rivers
	-- pouring rim to sea, with mid-apron pools and molten sea deltas as the
	-- fishable Volcano_Lava (the `waters = "volcano"` roster and Phoenix
	-- chase are LIVE again). Still NO dock, NO props.
	volcano = {
		name = "Ashfall Caldera",
		blurb = "A towering volcano - fish its shore, brave the lava ponds.",
		model = "Volcano",
		-- Leg 3: ~5,600 studs south-east from the ice - the volcano stands
		-- alone in the middle of the map, visible for miles.
		worldPosition = Vector3.new(11800, 0, 2600),
		-- No meshBottom: the bare step-1 landform bottoms at the standard -9
		-- skirt (pack HANDOFF 2026-08-27; the old -9.74 was the deleted
		-- flank rocks). Re-key when a rebuild step dips below the skirt.
		radius = 660, -- near the 2048-stud import cap (bbox ~1971 measured 2026-08-28; the walk-room re-key)
		-- Ash-choked grey-teal with an ember-warm shimmer in the light.
		water = {
			color = Color3.fromRGB(38, 54, 60),
			caustics = Color3.fromRGB(255, 186, 120),
			causticsTransparency = 0.65,
			reflectance = 0.03,
			seabed = Color3.fromRGB(36, 30, 26),
		},
		spawn = Vector3.new(11800, 3, 3111), -- X/Z: rel Z=511 on the +Z ash apron, right in front of the dock (planks run rel Z=532..597, walk-room-re-key HANDOFF); Y is the probe's fallback
		unlockLevel = 22,
		-- Pyrelisk guards it (summoned by Caldera's Call, exactly the Brinejaw
		-- ritual). Its arena still keys off the OLD dock position (open sea
		-- past rel Z~680) - fine as an interim water arena (the Gnashroot
		-- precedent); re-key when the dock step lands.
		boss = "pyrelisk",

		-- The apron between the lava ponds is patrolled by these raid waves.
		-- (EruptionService's bomb windows were removed with the restart, and
		-- lava deals NO contact damage - both by user order, 2026-08-27.)
		ambient = {
			rows = {
				{ id = "ember_swarm", weight = 3 },
				{ id = "fumarole", weight = 3 },
				{ id = "magma_ooze", weight = 2 },
				{ id = "obsidian_shardback", weight = 2 },
				{ id = "lodestone_eel", weight = 1 },
				{ id = "cinder_djinn", weight = 1 },
				{ id = "slagheart_golem", weight = 1 },
			},
			maxAlive = 7,
			interval = 6,
		},
		raid = {
			interval = { 600, 900 },
			waves = {
				{ { id = "ember_swarm", count = 3 }, { id = "fumarole", count = 2 } },
				{ { id = "magma_ooze", count = 2 }, { id = "obsidian_shardback", count = 2 } },
				{
					{ id = "slagheart_golem", count = 1 },
					{ id = "cinder_djinn", count = 2 },
					{ id = "lodestone_eel", count = 2 },
				},
			},
			reward = { coins = { 450, 650 }, xp = 350 },
		},
	},

	-- Gloomtrench (slot 5, L29-35). Skeleton: b8 fills the boss (noctyss) +
	-- kit + the Gloomtrench_DarkWater wiring + the lantern mechanic.
	gloom = {
		name = "Gloomtrench",
		blurb = "Where the light gives up. Bring your own, and keep it lit.",
		model = "Gloomtrench",
		-- Leg 4: ~6,400 studs, crossing the equator of the map into the dark
		-- southern sea.
		worldPosition = Vector3.new(15400, 0, -2700),
		meshBottom = -16.53, -- the trench floor is authored well below the -9 skirt (pack 384c971)
		radius = 200,
		-- Ink. The light gives up here; the caustics barely register.
		water = {
			color = Color3.fromRGB(10, 22, 38),
			caustics = Color3.fromRGB(90, 160, 200),
			causticsTransparency = 0.78,
			reflectance = 0.02,
			seabed = Color3.fromRGB(12, 16, 24),
		},
		spawn = Vector3.new(15400, 4, -2546), -- X/Z: shore before the dock (planks run rel Z=172..216); Y is the probe's fallback
		unlockLevel = 29,
		boss = "noctyss",
		ambient = {
			rows = {
				{ id = "trench_skitterer", weight = 4 },
				{ id = "gulper_eel", weight = 3 },
				{ id = "flashbulb_squid", weight = 3 },
				{ id = "vampire_squid", weight = 2 },
				{ id = "pressure_crab", weight = 2 },
				{ id = "lanternjaw_angler", weight = 1 },
				{ id = "silt_stalker", weight = 1 },
			},
			maxAlive = 7,
			interval = 6,
		},
		raid = {
			interval = { 600, 900 },
			announce = 45,
			waves = {
				{ { id = "trench_skitterer", count = 4 }, { id = "gulper_eel", count = 2 } },
				{ { id = "flashbulb_squid", count = 3 }, { id = "pressure_crab", count = 2 } },
				{
					{ id = "void_ray", count = 2 },
					{ id = "silt_stalker", count = 2 },
					{ id = "vampire_squid", count = 2 },
				},
			},
			reward = { coins = { 2000, 2800 }, xp = 1400 },
		},
	},

	-- Wreckwater (slot 6, L36-42). Skeleton: b8 fills the boss
	-- (admiral_wrack) + kit + the Wreckwater_Bay wiring + boarding raids.
	wreck = {
		name = "Wreckwater",
		blurb = "A graveyard of ghost ships that never finished sinking.",
		model = "Wreckwater",
		-- Leg 5: ~7,400 studs back south-west - the graveyard sea.
		worldPosition = Vector3.new(12500, 0, -9500),
		-- Seabed dunes bottom the mesh at -18.25 (sunken keels -16.2); without
		-- this the bbox pin hoisted the island 9.3 studs and the whole ghost
		-- fleet hung above the water (user, 2026-08-27). Pack 384c971.
		meshBottom = -18.25,
		radius = 210,
		-- Ghost-ship grey-green with a spectral pale-green light.
		water = {
			color = Color3.fromRGB(46, 78, 78),
			caustics = Color3.fromRGB(152, 232, 200),
			causticsTransparency = 0.58,
			reflectance = 0.05,
			seabed = Color3.fromRGB(30, 42, 40),
		},
		spawn = Vector3.new(12500, 4, -9322), -- X/Z: shore before the dock (planks run rel Z=185..231); Y is the probe's fallback. Was rel Z=167, which is over Wreckwater_Bay (M_BayWater, top Y=0.17) - the landing stood the player on the harbour water. rel Z=178 is dry beach, ground Y=1.34
		unlockLevel = 36,
		boss = "admiral_wrack",
		ambient = {
			rows = {
				{ id = "cannonball_crab", weight = 4 },
				{ id = "rigging_wraith", weight = 3 },
				{ id = "drowned_boatswain", weight = 3 },
				{ id = "plunder_sprite", weight = 2 },
				{ id = "phantom_moray", weight = 2 },
				{ id = "cursed_chest", weight = 1 },
				{ id = "wailing_gunner", weight = 1 },
			},
			maxAlive = 8,
			interval = 6,
		},
		-- BOARDING raids - the island's signature: the fleet's dead come over
		-- the rail in waves.
		raid = {
			interval = { 540, 840 },
			announce = 45,
			waves = {
				{ { id = "drowned_boatswain", count = 3 }, { id = "cannonball_crab", count = 3 } },
				{ { id = "rigging_wraith", count = 3 }, { id = "wailing_gunner", count = 2 } },
				{
					{ id = "phantom_moray", count = 2 },
					{ id = "ghostfire_jelly", count = 2 },
					{ id = "drowned_boatswain", count = 2 },
				},
			},
			reward = { coins = { 3200, 4500 }, xp = 2200 },
		},
	},

	-- The Maelstrom (finale SITE, L43-50): not an island and not in
	-- Islands.order - the linear Cleared_ chain skips it, the travel menu
	-- veils it until all six island hearts are in hand, and WorldService
	-- builds it procedurally (site = true -> no mesh; buildMaelstromSite).
	-- Casting into its whirlpool (Maelstrom_Water -> waters "maelstrom")
	-- rolls the storm roster; Kraken's Call summons the Maw itself.
	maelstrom = {
		name = "The Maelstrom",
		blurb = "The storm at the end of the sea. It is waiting for you.",
		site = true,
		-- The authored storm-shoal (2026-08-27, island_gen.py `maelstrom`):
		-- once Assets/Maelstrom (or the pack's Maelstrom group) is imported,
		-- buildMaelstromSite places it through placeIsland; until then the
		-- procedural rock ring stands in. The whirlpool water disc is ALWAYS
		-- procedural - never part of the mesh.
		model = "Maelstrom",
		-- Fight-stack columns and the sunken fleet's keels dip well below the
		-- -9 skirt (generator HANDOFF, 2026-08-27 build).
		meshBottom = -11.95,

		-- Leg 6, the last crossing: ~8,700 studs of open storm-sea from
		-- Wreckwater, due south of home - the arc closes back toward the cove,
		-- so the finale rages on the starter island's own horizon.
		worldPosition = Vector3.new(4800, 0, -13500),
		radius = 260,
		-- Storm slate with an electric glint - echoes Maelstrom_StormGlow.
		-- Only the SEA around the site tints; the whirlpool disc itself is
		-- MaelstromVfxController's and is never touched by the blend.
		water = {
			color = Color3.fromRGB(26, 48, 66),
			caustics = Color3.fromRGB(140, 220, 255),
			causticsTransparency = 0.5,
			reflectance = 0.06,
			seabed = Color3.fromRGB(20, 30, 40),
		},
		spawn = Vector3.new(4800, 6, -13456), -- the spawn stack on +Z (authored top Y=6.0; the procedural platform matches)
		unlockLevel = 43,
		boss = "kraken",
	},

	-- ============================================================ THE ISLETS
	-- Nine tiny places scattered BETWEEN the six islands on the voyage arc.
	-- "Between" is load-bearing, not flavour: an islet inside the arc's empty
	-- middle is outside every seaworthiness circle and its resident is
	-- unmeetable (the Ferryman and Ansel both were, until 2026-09-12 - see
	-- their MOVED notes). Each one below is placed at ~85% of the range of the
	-- boat tier its quests' level can own, measured from a place reachable at
	-- that level, and off the legs so it stays optional.
	-- Every one carries `islet = true`: they are deliberately absent from
	-- Islands.order, so nothing gates them, the travel menu never lists them,
	-- and the only way to reach one is to sail there. Each holds a single NPC
	-- and their quests. None needs a `meshBottom` - all nine sit on the
	-- standard -9 skirt (the pack build's HANDOFF lines confirm it).
	--
	-- Redesign 2026-09-02: every spawn below is the builder's MEASURED pad -
	-- a downward raycast in the exported scene, printed in its HANDOFF line
	-- and re-verified against the .glb by pad_check (all deltas <= 0.01).
	-- `spawn` on an islet is NOT a teleport destination (there is no teleport
	-- to them); it is the anchor NpcService measures its resident from, so it
	-- is set to the flat pad each islet's builder reserved and measured.

	bellbuoy = {
		name = "The Bellbuoy",
		blurb = "A sea-bell the size of a room, bolted to a rock and rung by the swell.",
		model = "Bellbuoy",
		islet = true,
		worldPosition = Vector3.new(1900, 0, 500),
		radius = 40,
		spawn = Vector3.new(1925, 3.82, 496.4),
	},

	chapel = {
		name = "The Drowned Chapel",
		blurb = "A bell tower standing in open water. The rest of the church is underneath it.",
		model = "Chapel",
		islet = true,
		worldPosition = Vector3.new(5100, 0, 3600),
		radius = 60,
		spawn = Vector3.new(5100.4, 0.95, 3617.6),
	},

	rookery = {
		name = "The Rookery Stack",
		blurb = "A white stack of rock and a colony that was here first.",
		model = "Rookery",
		islet = true,
		worldPosition = Vector3.new(9500, 0, 4200),
		radius = 46,
		spawn = Vector3.new(9519.5, 34.02, 4199.0), -- X/Z moved 1.1 studs off the generator's mark (rel X=18.5 Z=-1.5): there the stack's own rock rises through the arriving body (check_npc_placement (c)). rel X=19.5 Z=-1.0 is the flat landing, ground Y=34.00
	},

	boilshoal = {
		name = "The Boiling Shoal",
		blurb = "Black glass and water too hot to swim. Some things only bite here.",
		model = "Boilshoal",
		islet = true,
		worldPosition = Vector3.new(13400, 0, 300),
		radius = 60,
		spawn = Vector3.new(13385.8, 3.4, 278.2),
	},

	lampwork = {
		name = "The Lampwright's Workshop",
		blurb = "A yard full of lamps, every one of them dark, and one lit window.",
		model = "Lampwork",
		islet = true,
		worldPosition = Vector3.new(13100, 0, -1200),
		radius = 55,
		spawn = Vector3.new(13094, 9.54, -1198),
	},

	anchorage = {
		name = "The Anchor Garden",
		blurb = "Two dozen anchors standing in the sand, and one chain still pulling.",
		model = "Anchorage",
		islet = true,
		worldPosition = Vector3.new(14200, 0, -6000),
		radius = 74,
		spawn = Vector3.new(14231.5, 3.45, -5967.5),
	},

	whalefall = {
		name = "The Whale Fall",
		blurb = "A skeleton on a sandbar, and the best fishing on the leg because of it.",
		model = "Whalefall",
		islet = true,
		worldPosition = Vector3.new(8400, 0, -11300),
		radius = 120,
		spawn = Vector3.new(8444.7, 2.89, -11290.8),
	},

	ferryraft = {
		name = "The Ferryman's Raft",
		blurb = "Someone lives out here on purpose, and will trade with whoever gets this far.",
		model = "Ferryraft",
		islet = true,
		-- MOVED 2026-09-12 (quest-reach audit): was (7000, -5000), inside the
		-- arc's empty southern void - 6,895 studs from the nearest shelter,
		-- which is past EVERY tier's seaworthiness, so the Ferryman could not
		-- be met at any level and `the_long_way_round` (L20) could never be
		-- offered. Now 3,100 studs due north of Frostmaw Reach (gap 2,810
		-- after both radii): a L20 player owns the tier-3 Iceberg Cutter
		-- (L15, seaworthiness 3,300), so the crossing lands with 490 studs of
		-- hull to spare - 85% of the range. First sailable at L15, when the
		-- Reach itself opens. Deliberately OFF every leg of the voyage arc
		-- (the legs run NE to the Reach and then SE to the Caldera; this is
		-- the empty water beyond the shelf), so the raft stays optional and
		-- still reads as the remotest place anyone lives.
		worldPosition = Vector3.new(6800, 0, 8300),
		radius = 60,
		spawn = Vector3.new(6793.35, 3.7, 8308.5), -- X/Z: the OPEN bow deck (rel X=-6.65 Z=8.5, same Ferryraft_Bow, Y=3.70) - the generator's mark (rel X=-9.65 Z=1.5) is the Ferryman's slot between his counter and the cabin and landed every visitor inside him. Moved with worldPosition by the same delta (-200, +13300); the offsets relative to the islet are unchanged
	},

	loadstone = {
		name = "The Loadstone Spire",
		blurb = "A black needle that pulls the storm onto itself. Your compass gives up here.",
		model = "Loadstone",
		islet = true,
		-- MOVED 2026-09-12 (quest-reach audit): was (3000, -8000), 5,527
		-- studs off the Maelstrom's rim and nothing else within reach - and
		-- the Maelstrom itself needs L43, so Ansel could not be met at any
		-- level and `struck_twice` (L38) could never be offered. Now 4,300
		-- studs west of the Whale Fall (gap 4,135 after both radii), which is
		-- first sailable at L36 off Wreckwater: a L38 player owns the tier-6
		-- Dreadnought (L36, seaworthiness 4,900), so the run out leaves 765
		-- studs of hull - 84% of the range. Still the deepest, loneliest
		-- water on the map (2,300 studs off the Maelstrom, 2,275 studs off
		-- leg 6's line), so the needle keeps its storm and stays optional.
		worldPosition = Vector3.new(4100, 0, -11300),
		radius = 45,
		spawn = Vector3.new(4100, 4.27, -11266.8), -- moved with worldPosition by the same delta (+1100, -3300); the pad offset relative to the islet is unchanged
	},
}

-- The island whose footprint contains `position` (XZ distance inside its
-- radius plus `margin`, default 0), or nil for open sea. Shared (Session 3)
-- so the server's gates/spawner and the client's raid HUD agree on what "on
-- this island" means. Consecutive islands sit 4,000+ studs apart with radii
-- under 700, so footprints never overlap.
function Islands.islandAt(position: Vector3, margin: number?): (string?, any)
	for id, entry in Islands.items do
		local d = Vector3.new(position.X - entry.worldPosition.X, 0, position.Z - entry.worldPosition.Z).Magnitude
		if d <= entry.radius + (margin or 0) then
			return id, entry
		end
	end
	return nil, nil
end

-- The nearest island (or the Maelstrom site) to `position` by XZ distance to
-- its centre, plus that distance - islandAt's smooth sibling: islandAt is a
-- binary in/out test, this one lets a caller measure HOW FAR into an
-- approach it is (OceanController's water-colour blend). Future
-- consolidation target for the hand-rolled nearest-island loops in
-- WeatherController, IslandsController and BoatController - not refactored
-- here to keep this change small.
--
-- `includeIslets` (default false) decides whether the nine islets can win.
-- They must NOT for anything asking "which island's ENVIRONMENT am I in",
-- because an islet has no environment - no `water`, no `ambient`, it is a
-- rock in open sea. Letting one win looks harmless (it falls back to the
-- ocean's base dress) and is not: nearest-wins flips on the perpendicular
-- bisector between the islet and the real island, and several islets sit
-- close enough to cut inside an island's colour band (the Bellbuoy crosses
-- the fen's at 1,030 studs of its 1,680). A boat weaving along that line
-- pulses the sea between murk and blue, because the flip is a step and the
-- blend behind it is a 1.5s roll, not a distance ramp. None of them reaches
-- an island's FULL-tint radius, so a shore is never wrong - it is the outer
-- fade that breaks, which is the half nobody would think to check.
-- Callers that mean "what can I sail to" (BoatController) do want them.
function Islands.nearestIsland(position: Vector3, includeIslets: boolean?): (string?, any, number)
	local bestId, bestEntry, bestDistance = nil, nil, math.huge
	for id, entry in Islands.items do
		if includeIslets or not entry.islet then
			local d = Vector3.new(position.X - entry.worldPosition.X, 0, position.Z - entry.worldPosition.Z).Magnitude
			if d < bestDistance then
				bestId, bestEntry, bestDistance = id, entry, d
			end
		end
	end
	return bestId, bestEntry, bestDistance
end

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
