--!nocheck
--[[
	studio_import_bundles.lua - THREE imports instead of twenty-two

	WHAT IT DOES
	`assets/bundle_gen.py` re-packs the 22 importable .glb files into three
	bundles under `assets/bundles/`, each holding its packs under an Empty
	named exactly the name the game looks up (`IslandPack`, `WrackArena`,
	`CreaturePack`, ...). This script is the other half: it imports those three
	bundles, splits each one's top-level children out under
	`ReplicatedStorage.Assets` under their exact names, applies the
	per-part CollisionFidelity and the Neon materials the ledger demands, and
	prints a verification report - object counts, sentinel children, every
	contract name that is missing, and which fidelity landed where.

	It is `tools/studio_import.lua` with one difference: the unit of import is
	a bundle rather than a file, so the rules below are keyed by PACK NAME
	instead of by filename. The rules themselves are that script's ROWS table,
	transcribed, plus the three packs it has no row for yet (KrakenArena,
	KrakenGullet, BrinejawFxPack - docs/import-checklist.md rows 7m and 7q)
	and four corrections noted inline where the ledger and the shipped mesh
	disagree.

	HOW TO RUN
	  1. Import the three bundles by hand first (File -> Import 3D..., or the
	     Home tab's Import button) - see docs/import-quick.md for the dialog
	     settings. This script will TRY to import them itself through
	     AssetImportService, and on many Studio builds that works; when it does
	     not, it tells you which file to import by hand and picks the result up
	     on the next run.
	  2. Open the place in Studio. View -> Command Bar.
	  3. Paste this whole file, press Enter, read the printed PLAN.
	  4. Flip DRY_RUN to false below, paste again, press Enter.

	THE FLAGS
	  DRY_RUN       = true  -- default: prints the plan, imports nothing.
	  SKIP_EXISTING = true  -- a pack already under Assets is left alone, so a
	                           re-run after a partial failure fills the gaps.
	  ADOPT_EXISTING = true -- if a bundle is already sitting in Workspace
	                           (you imported it by hand, or a previous run
	                           left it), use it instead of importing again.

	THE SKIP_EXISTING TRAP - read this before you trust a clean report
	  `SKIP_EXISTING = true` leaves a pack that is already under Assets exactly
	  as it is, which means THE OLD MESH IS STILL WHAT THE GAME USES: a re-run
	  after a regeneration reports success and changes nothing, and the game
	  goes on drawing last month's islands (no islets, no huts). A skipped pack
	  is therefore counted as a WARNING here, never as a success, and the
	  SUMMARY names every one. To actually replace them, set
	  `SKIP_EXISTING = false` and run again - the old pack is renamed
	  `<Name>_old_<timestamp>` (never deleted) and the new one takes its place.

	THE GEOMETRY CHECK - why names and counts are not enough
	  Every other check in this file is a NAME check, and an import can arrive
	  with every name right and still be wrong: leave the Import dialog on a
	  non-1 scale, or flip Use Imported Pivot, and the counts, sentinels and
	  contract names all pass while the world renders at the wrong size or with
	  its pieces in the wrong places. So `assets/bundle_gen.py` measures every
	  object's bounding box in Blender and splices the numbers into this file
	  between the two `GEOMETRY BEGIN` / `GEOMETRY ...END` marker comments below
	  (quoted with a break in the second one on purpose: the splice asserts each
	  marker appears exactly once, so this paragraph must not be a third). The
	  table is spliced in rather than required because the command bar cannot
	  `require` a second file. Every moved pack is then measured
	  against them: bbox size in studs, and bbox centre relative to the pack's
	  anchor object so the check is blind to where Studio dropped the import.
	  It names the two failure modes outright - every size off by one ratio is
	  a scaled import, sizes right with centres wrong is a shifted or rotated
	  one. Regenerate the table whenever you rebuild the bundles.

	CAVEATS
	  * NOTHING IS EVER DELETED. No :Destroy() in this file. A replaced pack is
	    renamed `<Name>_old_<timestamp>` and left in place; the report lists
	    them for you to delete by hand once the new meshes look right in game.
	  * Children are NEVER renamed. Object names are the contract MeshColors
	    and every lookup key off.
	  * THE IMPORT CONTAINER NEVER STAYS IN WORKSPACE. Whatever is left of it
	    (packs skipped by SKIP_EXISTING, strays, failures, or nothing at all) is
	    moved to `ReplicatedStorage.ImportStaging`, because a bundle sitting in
	    Workspace RENDERS: sixteen islands stacked at one point, uncoloured
	    (Studio drops all glTF colour), lifted so the lowest vertex sits at
	    y = 0. That is the scrambled world, and it is not a Studio bug - it is
	    the raw import being visible.
	  * DO NOT SCALE ON IMPORT. Several packs are authored at final size and
	    double-scale (Pyrelisk, Wrack, Kraken, Gnashroot, the islets).

	AFTER IT RUNS - the two manual steps it cannot do:
	  1. Right-click ReplicatedStorage.Assets -> Save to File... ->
	     assets/Assets.rbxm (overwrite).
	  2. Restart `rojo serve` and reconnect (it does not watch .rbxm).
]]

--=====================================================================
-- FLAGS
--=====================================================================

local DRY_RUN = true
local SKIP_EXISTING = true
local ADOPT_EXISTING = true

-- The ONE path this script knows. Everything else is derived from it, so a
-- checkout somewhere else needs exactly one edit.
local ASSET_DIR = "/Users/samarthsreenivas/Developer/How-to-Fish/assets/"

--=====================================================================

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AssetImportService = game:GetService("AssetImportService")

local PRECISE = Enum.CollisionFidelity.PreciseConvexDecomposition
local BOX = Enum.CollisionFidelity.Box
local DEFAULT = Enum.CollisionFidelity.Default

local BUNDLE_DIR = ASSET_DIR .. "bundles/"

--[[
	THE BUNDLES, as assets/bundle_gen.py writes them. `packs` is the set of
	top-level children to expect inside each import; anything else in there is
	reported rather than silently moved.
]]
local BUNDLES = {
	{
		file = "bundle_world.glb",
		packs = { "IslandPack" },
	},
	{
		file = "bundle_bosses.glb",
		packs = {
			"Maelstrom",
			"BrinejawArena",
			"BrinejawPack",
			"BrinejawFxPack",
			"GnashrootArena",
			"GnashrootPack",
			"RimefangArena",
			"RimefangPack",
			"WrackArena",
			"WrackPack",
			"NoctyssArena",
			"NoctyssPack",
			"PyreliskArena",
			"PyreliskHeart",
			"PyreliskPack",
			"KrakenArena",
			"KrakenGullet",
			"KrakenPack",
		},
	},
	{
		file = "bundle_gear.glb",
		packs = { "RodPack", "WeaponPack", "ArmorPack", "BoatPack", "FishPack", "CreaturePack" },
	},
}

--[[
	THE LEDGER, keyed by pack name. Transcribed from tools/studio_import.lua's
	ROWS (which transcribed docs/import-checklist.md), with the four places the
	ledger and the shipped mesh disagree fixed and flagged:

	  * KrakenPack's name list and count were written for an older mesh. The
	    shipped boss_kraken.glb holds 17 objects - `Kraken_Cap`,
	    `Kraken_TentacleSeg/_TentacleSucker/_TentacleTip` and the rest - not
	    the 9 `_Crown/_Beak/_ArmSeg/_ArmTip/_Sucker` names. MeshColors.luau has
	    rows for all 17, so the mesh is right and the list was stale.
	  * `Kraken_Sucker` (in studio_import.lua's NEON table) does not exist in
	    any mesh. The real part is `Kraken_TentacleSucker`, and
	    KrakenBodyController states its own Neon after the clone (row 7m: "no
	    material steps"), so nothing is owed here at import time.
	  * `NoctyssArena_Mantle` needs PreciseConvexDecomposition - row 7h says so
	    in as many words ("a default convex hull spans its inner opening and
	    caps the hole the maw rises through") and studio_import.lua's rule list
	    omits it.
	  * `PyreliskArena_Lava` and `_SeamDeco` are advisories in
	    studio_import.lua. They need nothing: BossArenaService's GLOW_MARKERS
	    contains "Lava" and "Seam" and its HAZARD_MARKERS contains "Lava", so
	    the runtime already sets Neon on both and clears CanCollide on the
	    lake. Left out deliberately, not forgotten.

	fidelity: {pattern, Enum.CollisionFidelity}, matched with string.find
	plain over every descendant MeshPart. ABSENT means the row says fidelity
	does not matter - a boss pack cloned into massless collision-free parts
	churns nothing.
]]
local RULES = {
	IslandPack = {
		row = "1 / 1c",
		sentinel = "Island_Base",
		names = {
			"Island_Base",
			"Swamp_Base",
			"Swamp_Water",
			"Volcano_Base",
			"Volcano_Lava",
			"Volcano_DeadTrees",
			"Frostmaw_Base",
			"Frostmaw_IceHoles",
			"Gloomtrench_Base",
			"Gloomtrench_DarkWater",
			"Wreckwater_Base",
			"Wreckwater_Bay",
			"Maelstrom_Base",
			"Maelstrom_Platforms",
			"Bellbuoy_Wedge",
			"Chapel_Roof",
			"Rookery_Stacks",
			"Ferryraft_Cabin",
			"Boilshoal_Rim",
			"Boilshoal_Lagoon",
			"Lampwork_Shop",
			"Anchorage_Iron",
			"Whalefall_Bones",
			"Loadstone_Spires",
		},
		fidelity = {
			-- "_Base" covers every island AND every islet landform. Frostmaw's
			-- walkable ice sheet IS Frostmaw_Base, and a default hull caps its
			-- pre-cut fishing holes: the volcano-crater gotcha.
			{ "_Base", PRECISE },
			{ "Volcano_DeadTrees", PRECISE },
			{ "Maelstrom_Platforms", PRECISE },
			-- The six NPC houses are WALK-IN: a hull fills the doorway.
			{ "_Hut_Walls", PRECISE },
			{ "_Hut_Roof", PRECISE },
			-- Row 1c: the ~28 islet parts a hull would seal, flatten or fill.
			{ "Bellbuoy_Wedge", PRECISE },
			{ "Bellbuoy_Dinghy", PRECISE },
			{ "Bellbuoy_Gantry", PRECISE },
			{ "Chapel_Roof", PRECISE },
			{ "Chapel_Stone", PRECISE },
			{ "Chapel_Yard", PRECISE },
			{ "Rookery_Stacks", PRECISE },
			{ "Rookery_Ledges", PRECISE },
			{ "Rookery_Eyrie", PRECISE },
			{ "Ferryraft_Cabin", PRECISE },
			{ "Ferryraft_Bridges", PRECISE },
			{ "Ferryraft_Bow", PRECISE },
			{ "Ferryraft_Barrels", PRECISE },
			{ "Ferryraft_Barge", PRECISE },
			{ "Ferryraft_Gear", PRECISE },
			{ "Boilshoal_Rim", PRECISE },
			{ "Boilshoal_Terraces", PRECISE },
			{ "Boilshoal_Hut", PRECISE },
			{ "Lampwork_Shop", PRECISE },
			{ "Anchorage_Shack", PRECISE },
			{ "Anchorage_Iron", PRECISE },
			{ "Whalefall_Bar", PRECISE },
			{ "Whalefall_Bones", PRECISE },
			{ "Loadstone_Rubble", PRECISE },
			{ "Loadstone_Shack", PRECISE },
			{ "Loadstone_Spires", PRECISE },
		},
	},
	Maelstrom = {
		row = "1b",
		sentinel = "Maelstrom_Base",
		expected = 9,
		expectedNote = "the same nine objects as IslandPack's Maelstrom group (row 1b: "
			.. "importing the pack covers it). Kept as its own pack so the Assets tree "
			.. "matches what the 22-file flow produced; it rides in bundle_bosses "
			.. "because two packs with the same object names cannot share one .glb.",
		names = { "Maelstrom_Base", "Maelstrom_Platforms" },
		fidelity = {
			{ "Maelstrom_Base", PRECISE },
			{ "Maelstrom_Platforms", PRECISE },
		},
	},
	WeaponPack = { row = "2", sentinel = "DriftwoodClub_Head", expected = 297 },
	BoatPack = { row = "3", sentinel = "CoveSkiff_Hull", expected = 53 },
	CreaturePack = { row = "4", sentinel = "Crab_Body", expected = 275 },
	FishPack = { row = "5", sentinel = "Bass_Body", expected = 135 },
	RodPack = { row = "6", sentinel = "Twig_Grip", expected = 216 },
	ArmorPack = {
		row = "7",
		sentinel = "Chitin_Helm",
		expected = 30,
		names = { "Chitin_Helm", "Chitin_Chest", "Chitin_Legs", "Boneplate_Helm" },
	},
	BrinejawArena = {
		row = "7b",
		sentinel = "BrinejawArena_Base",
		expected = 19,
		expectedNote = "the row says 13; the shipped mesh holds 19 (the SpireBand/"
			.. "SpireRail/SpireWindows/Bell/Boat/Mast/SailRag detail split). 19 is the "
			.. "number to trust.",
		names = {
			"BrinejawArena_Base",
			"BrinejawArena_Spire",
			"BrinejawArena_Rocks",
			"BrinejawArena_ReefStone1",
			"BrinejawArena_ReefStone2",
			"BrinejawArena_ReefStone3",
		},
		fidelity = {
			{ "BrinejawArena_Base", PRECISE },
			-- Substring, so _SpireBand/_SpireRail/_SpireWindows come with it -
			-- that is the lighthouse players fight on, so the fan-out is wanted.
			{ "BrinejawArena_Spire", PRECISE },
			{ "BrinejawArena_Rocks", PRECISE },
			{ "ReefStone", PRECISE },
		},
	},
	BrinejawPack = {
		row = "7c",
		sentinel = "Brinejaw_Head",
		expected = 9,
		names = {
			"Brinejaw_Head",
			"Brinejaw_HeadBone",
			"Brinejaw_Eyes",
			"Brinejaw_Frill",
			"Brinejaw_Jaw",
			"Brinejaw_JawBone",
			"Brinejaw_Seg",
			"Brinejaw_SegFin",
			"Brinejaw_Rattle",
		},
	},
	BrinejawFxPack = {
		row = "7q",
		sentinel = "BrinejawFx_Spike1",
		expected = 10,
		names = {
			"BrinejawFx_Spike1",
			"BrinejawFx_Spike2",
			"BrinejawFx_Spike3",
			"BrinejawFx_SpoutBase",
			"BrinejawFx_Crest1",
			"BrinejawFx_Crest2",
			"BrinejawFx_Foam",
			"BrinejawFx_Spine",
			"BrinejawFx_Rock1",
			"BrinejawFx_Rock2",
		},
		-- fidelity/material: row 7q says neither matters - every piece is cloned
		-- into anchored, collision-free, query-free markers and repainted.
	},
	GnashrootArena = {
		row = "7d",
		sentinel = "GnashrootArena_Base",
		expected = 16,
		names = {
			"GnashrootArena_Base",
			"GnashrootArena_Grove",
			"GnashrootArena_Stump1",
			"GnashrootArena_Stump2",
			"GnashrootArena_Stump3",
			"GnashrootArena_Stump4",
		},
		fidelity = {
			{ "GnashrootArena_Base", PRECISE },
			{ "GnashrootArena_Grove", PRECISE },
			{ "_Stump", PRECISE },
		},
	},
	GnashrootPack = {
		row = "7f",
		sentinel = "Gnashroot_Mass",
		expected = 14,
		-- Redesign 2026-09-12 (session 30): _Legs deleted, _Roots added,
		-- _Eyes renamed _Eye. Still 14 objects.
		names = {
			"Gnashroot_Mass",
			"Gnashroot_Roots",
			"Gnashroot_Head",
			"Gnashroot_Jaw",
			"Gnashroot_Maw",
			"Gnashroot_Teeth",
			"Gnashroot_Fangs",
			"Gnashroot_Eye",
			"Gnashroot_Core",
			"Gnashroot_Stones",
			"Gnashroot_Drips",
			"Gnashroot_Arm",
			"Gnashroot_ArmKnot",
			"Gnashroot_Hand",
		},
	},
	RimefangArena = {
		row = "7j",
		-- FLOE v3, 2026-09-12: 9 objects became 53. The walkable disc is no
		-- longer one sheet - it is 43 separate `_ShardNN` meshes the fight
		-- sinks and refreezes one at a time (a mesh cannot change at runtime,
		-- so the floor has to arrive already broken), plus `_Water`, the dark
		-- plate 1.2 studs under them that the cracks and the sunk shards show.
		--
		-- `RimefangArena_Base` IS STILL THE SENTINEL and still the right one.
		-- It is the ANNULUS now, r 120 out to the torn lip - not the fight
		-- floor - and it keeps the name because three things resolve this pack
		-- by exactly that string: BossArenaService.arenaTemplate walks up from
		-- it to find the group, placeAuthored anchors the arena on its XZ
		-- centre, and every GEOMETRY row below is measured relative to it.
		-- Naming a SHARD `_Base` instead would have satisfied all three checks
		-- and moved the whole arena by that shard's offset from the middle,
		-- 20 to 110 studs, with nothing anywhere reporting it.
		sentinel = "RimefangArena_Base",
		expected = 53,
		names = {
			"RimefangArena_Base",
			"RimefangArena_Ridge",
			"RimefangArena_ThinIce",
			"RimefangArena_Water",
			"RimefangArena_Shard01",
			"RimefangArena_Shard02",
			"RimefangArena_Shard03",
			"RimefangArena_Shard04",
			"RimefangArena_Shard05",
			"RimefangArena_Shard06",
			"RimefangArena_Shard07",
			"RimefangArena_Shard08",
			"RimefangArena_Shard09",
			"RimefangArena_Shard10",
			"RimefangArena_Shard11",
			"RimefangArena_Shard12",
			"RimefangArena_Shard13",
			"RimefangArena_Shard14",
			"RimefangArena_Shard15",
			"RimefangArena_Shard16",
			"RimefangArena_Shard17",
			"RimefangArena_Shard18",
			"RimefangArena_Shard19",
			"RimefangArena_Shard20",
			"RimefangArena_Shard21",
			"RimefangArena_Shard22",
			"RimefangArena_Shard23",
			"RimefangArena_Shard24",
			"RimefangArena_Shard25",
			"RimefangArena_Shard26",
			"RimefangArena_Shard27",
			"RimefangArena_Shard28",
			"RimefangArena_Shard29",
			"RimefangArena_Shard30",
			"RimefangArena_Shard31",
			"RimefangArena_Shard32",
			"RimefangArena_Shard33",
			"RimefangArena_Shard34",
			"RimefangArena_Shard35",
			"RimefangArena_Shard36",
			"RimefangArena_Shard37",
			"RimefangArena_Shard38",
			"RimefangArena_Shard39",
			"RimefangArena_Shard40",
			"RimefangArena_Shard41",
			"RimefangArena_Shard42",
			"RimefangArena_Shard43",
		},
		fidelity = {
			-- EVERY SHARD PRECISE. They are flat prisms, so this is cheap -
			-- and it is the jagged outline that makes the floor read as
			-- shattered rather than tiled, so a convex hull would quietly
			-- round off the one thing this rebuild exists for: it fills the
			-- notches, and every crack you can see becomes solid to walk on.
			-- Listed FIRST because `applyFidelity` matches by substring and
			-- takes the first rule that hits.
			{ "RimefangArena_Shard", PRECISE },
			-- The ridge leans IN over the floor and a default hull fills that
			-- undercut, turning containment into a ramp. `_Base` is the outer
			-- pack and the skirt now, but it is still walked on where it meets
			-- the shards at r 120.
			{ "RimefangArena_Base", PRECISE },
			{ "RimefangArena_Ridge", PRECISE },
			-- `_Water` takes the importer's DEFAULT hull, deliberately: it is a
			-- flat plate under the ice, the game makes it a non-collidable
			-- chill surface at placement, and a Precise decomposition of a
			-- 250-stud disc buys nothing for it.
			{ "RimefangArena_Water", DEFAULT },
		},
	},
	RimefangPack = {
		row = "7k",
		sentinel = "Rimefang_Head",
		expected = 11,
		names = {
			"Rimefang_Head",
			"Rimefang_Jaw",
			"Rimefang_TeethUpper",
			"Rimefang_TeethLower",
			"Rimefang_Eyes",
			"Rimefang_Rime",
			"Rimefang_Body",
			"Rimefang_Belly",
			"Rimefang_Fin",
			"Rimefang_Pec",
			"Rimefang_Fluke",
		},
	},
	WrackArena = {
		row = "7g",
		sentinel = "WrackArena_Base",
		expected = 10,
		names = {
			"WrackArena_Base",
			"WrackArena_Fleet",
			"WrackArena_FleetRibs",
			"WrackArena_FleetMasts",
			"WrackArena_DecoGhostGlow",
		},
		fidelity = {
			{ "WrackArena_Base", PRECISE },
			-- "_Fleet" covers _Fleet/_FleetRibs/_FleetMasts - the palisade is the
			-- only thing walked into now the breakwater hulks are gone.
			{ "_Fleet", PRECISE },
		},
	},
	WrackPack = {
		row = "7p",
		sentinel = "Wrack_Base",
		expected = 36,
		names = {
			"Wrack_Arm",
			"Wrack_Base",
			"Wrack_Boom",
			"Wrack_BoomTackle",
			"Wrack_CannonBowPort",
			"Wrack_CannonBowStbd",
			"Wrack_CannonSternPort",
			"Wrack_CannonSternStbd",
			"Wrack_Coat",
			"Wrack_Crust",
			"Wrack_EyeGlow",
			"Wrack_Facings",
			"Wrack_Figurehead",
			"Wrack_FigureheadGlow",
			"Wrack_Hat",
			"Wrack_Hatch1",
			"Wrack_Hatch2",
			"Wrack_Hatch3",
			"Wrack_HatchGlow",
			"Wrack_HeartCage",
			"Wrack_HeartGlow",
			"Wrack_Hull",
			"Wrack_HullCollider",
			"Wrack_Keel",
			"Wrack_Mast",
			"Wrack_MuzzleGlow",
			"Wrack_Pistol",
			"Wrack_Ribs",
			"Wrack_Rigging",
			"Wrack_Sabre",
			"Wrack_Sail",
			"Wrack_ShellLower",
			"Wrack_ShellUpper",
			"Wrack_Skull",
			"Wrack_Sponsons",
			"Wrack_Strakes",
		},
		fidelity = {
			-- The ONE collidable Wrack piece: CreatureService clones it into the
			-- World folder as the shot occluder, and its four folded-in casemates
			-- are concave - a Box/Default hull slabs over the cheeks and blocks
			-- shots at the near guns. There is no symptom but a fight that plays
			-- wrong.
			{ "Wrack_HullCollider", PRECISE },
		},
	},
	NoctyssArena = {
		row = "7h",
		sentinel = "NoctyssArena_Base",
		expected = 23,
		expectedNote = "the row says 23 objects and the mesh ships 23; studio_import.lua's "
			.. "row says 21, which is stale.",
		names = {
			"NoctyssArena_Base",
			"NoctyssArena_Mantle",
			"NoctyssArena_Rim",
			"NoctyssArena_Slab",
			"NoctyssArena_Fins",
			"NoctyssArena_Socket1",
			"NoctyssArena_Socket7",
			"NoctyssArena_DecoPitWater",
		},
		fidelity = {
			-- REQUIRED, not optional: the pit is a carved bowl and a default hull
			-- caps it - you would walk on air over the hole she rises through.
			{ "NoctyssArena_Base", PRECISE },
			-- The mantle is a seven-armed rolled ring AROUND the pit: a convex
			-- hull spans its inner opening and caps the same hole, and the roll
			-- is also the surface players cross to the sockets.
			{ "NoctyssArena_Mantle", PRECISE },
			{ "NoctyssArena_Rim", PRECISE },
			{ "NoctyssArena_Slab", PRECISE },
			{ "NoctyssArena_Fins", PRECISE },
			{ "_Socket", PRECISE },
		},
	},
	NoctyssPack = {
		row = "7i",
		sentinel = "Noctyss_StalkSeg",
		expected = 14,
		names = {
			"Noctyss_StalkSeg",
			"Noctyss_StalkFin",
			"Noctyss_StalkHood",
			"Noctyss_StalkCage",
			"Noctyss_StalkBulb",
			"Noctyss_StalkBarbs",
			"Noctyss_StalkRoot",
			"Noctyss_Skull",
			"Noctyss_SkullBone",
			"Noctyss_Jaw",
			"Noctyss_JawBone",
			"Noctyss_Gullet",
			"Noctyss_Eyes",
			"Noctyss_Barbels",
		},
	},
	PyreliskArena = {
		row = "7n",
		sentinel = "PyreliskArena_Base",
		-- 12 -> 14 on 2026-09-12 (Pyrelisk redesign slice 6): _LakeFloor and
		-- _Shaft, the hollow tube players drop through into the heart chamber.
		expected = 14,
		names = {
			"PyreliskArena_Base",
			"PyreliskArena_LakeFloor",
			"PyreliskArena_Shaft",
			"PyreliskArena_Rim",
			"PyreliskArena_Flank",
			"PyreliskArena_Teeth",
			"PyreliskArena_Gate",
			"PyreliskArena_Lava",
			"PyreliskArena_SeamDeco",
			"PyreliskArena_CloudDeco",
		},
		fidelity = {
			-- REQUIRED: _Rim's face LEANS BACK over the path and that overhang is
			-- the only thing containing the player.
			{ "PyreliskArena_Rim", PRECISE },
			{ "PyreliskArena_Flank", PRECISE },
			{ "PyreliskArena_Teeth", PRECISE },
			{ "PyreliskArena_Gate", PRECISE },
			-- REQUIRED: _Shaft is a hollow tube; a convex hull fills it solid and
			-- act 4 becomes unreachable with no log line to say why.
			{ "PyreliskArena_Shaft", PRECISE },
			-- _Base is dead flat: a default hull is correct, and a 232-stud
			-- decomposition is not free.
		},
	},
	PyreliskHeart = {
		row = "7n (heart)",
		sentinel = "PyreliskHeart_Base",
		expected = 22,
		expectedNote = "NEW 2026-09-12 (Pyrelisk redesign slice 6): the interior heart "
			.. "chamber, BossArenas row `pyrelisk_heart`, entered by ArenaMove for the "
			.. "final phase. Glow parts go Neon and _RubbleDeco loses collision via "
			.. "BossArenaService's marker rules - no material work at import time.",
		names = {
			"PyreliskHeart_Base",
			"PyreliskHeart_Walls",
			"PyreliskHeart_Dais",
			"PyreliskHeart_EntryPad",
			"PyreliskHeart_Heart",
			"PyreliskHeart_HeartGlow",
			"PyreliskHeart_VeinGlow",
			"PyreliskHeart_Socket1",
			"PyreliskHeart_Socket8",
			"PyreliskHeart_Vent1Glow",
			"PyreliskHeart_RubbleDeco",
		},
		fidelity = {
			-- The bowl and its walls are what contain the last act; a hull caps
			-- the bowl and fills the vents' wall openings.
			{ "PyreliskHeart_Base", PRECISE },
			{ "PyreliskHeart_Walls", PRECISE },
			-- _Dais/_EntryPad/_Socket1..8/_Heart: default hull is right.
		},
	},
	PyreliskPack = {
		row = "7o",
		sentinel = "Pyrelisk_Core",
		-- 14 -> 17 on 2026-09-12 (Pyrelisk redesign, final set): Pyrelisk_WalkNeck
		-- (the shoulder-to-neck climb plate, Box) plus Pyrelisk_ArmRock (one module
		-- in the glb, six instances placed at runtime) and Pyrelisk_NeckCore -
		-- both collision-free shells whose Neon the controller asserts.
		expected = 17,
		names = {
			"Pyrelisk_Core",
			"Pyrelisk_Torso",
			"Pyrelisk_Head",
			"Pyrelisk_Jaw",
			"Pyrelisk_Crown",
			"Pyrelisk_Eyes",
			"Pyrelisk_WalkDeck",
			"Pyrelisk_Shoulder",
			"Pyrelisk_UpperArm",
			"Pyrelisk_Forearm",
			"Pyrelisk_Hand",
			"Pyrelisk_WalkArm",
			"Pyrelisk_WalkNeck",
			"Pyrelisk_ArmRock",
			"Pyrelisk_NeckCore",
			"Pyrelisk_Seam",
			"Pyrelisk_Vent",
		},
		fidelity = {
			-- The one boss pack where fidelity matters: _WalkArm and _WalkDeck are
			-- the CLIMB ROUTE and the only collidable pieces. Box is exact for
			-- them.
			{ "Pyrelisk_WalkArm", BOX },
			{ "Pyrelisk_WalkDeck", BOX },
			{ "Pyrelisk_WalkNeck", BOX },
		},
	},
	KrakenArena = {
		row = "7m",
		sentinel = "KrakenArena_Base",
		expected = 19,
		names = {
			"KrakenArena_Base",
			"KrakenArena_MainDeck",
			"KrakenArena_Quarterdeck",
			"KrakenArena_Forecastle",
			"KrakenArena_Rails",
			"KrakenArena_CoverCapstan",
			"KrakenArena_CoverCargoAft",
			"KrakenArena_CoverCargoFore",
			"KrakenArena_CoverCoaming",
			"KrakenArena_SpawnPad",
			"KrakenArena_LampGlow",
		},
		fidelity = {
			-- Stairs become ramps or walls under a default hull; the four
			-- boarding gaps in _Rails ARE the mechanic and a hull fills them;
			-- the crouch-cover clearances are measured to fractions of a stud.
			{ "KrakenArena_MainDeck", PRECISE },
			{ "KrakenArena_Quarterdeck", PRECISE },
			{ "KrakenArena_Forecastle", PRECISE },
			{ "KrakenArena_Rails", PRECISE },
			{ "_Cover", PRECISE },
			-- _Base/_SpawnPad/_Masts/_Fittings: default hull fine.
			-- _LampGlow: Neon via BossArenaService's Glow rule.
		},
	},
	KrakenGullet = {
		row = "7m",
		sentinel = "KrakenGullet_Base",
		expected = 15,
		names = {
			"KrakenGullet_Base",
			"KrakenGullet_Walls",
			"KrakenGullet_Dais",
			"KrakenGullet_EntryPad",
			"KrakenGullet_Heart",
			"KrakenGullet_HeartGlow",
			"KrakenGullet_VeinGlow",
			"KrakenGullet_Socket1",
			"KrakenGullet_Socket6",
		},
		fidelity = {
			{ "KrakenGullet_Base", PRECISE },
			{ "KrakenGullet_Walls", PRECISE },
			-- _HeartGlow/_VeinGlow: Neon via code.
		},
	},
	KrakenPack = {
		row = "7m",
		sentinel = "Kraken_Head",
		expected = 17,
		expectedNote = "17 objects, read out of the shipped boss_kraken.glb and confirmed "
			.. "against MeshColors.luau's 17 Kraken_* rows. studio_import.lua's row still "
			.. "lists the old 9-name set (_Crown/_Beak/_ArmSeg/_ArmTip/_Sucker), none of "
			.. "which is in the mesh.",
		names = {
			"Kraken_Head",
			"Kraken_Cap",
			"Kraken_Crust",
			"Kraken_Eyes",
			"Kraken_Eyespots",
			"Kraken_Pupil",
			"Kraken_Lashes",
			"Kraken_Polyp",
			"Kraken_Barnacles",
			"Kraken_GutStrand",
			"Kraken_RibArch",
			"Kraken_Scrollwork",
			"Kraken_Siphon",
			"Kraken_SiphonCore",
			"Kraken_TentacleSeg",
			"Kraken_TentacleSucker",
			"Kraken_TentacleTip",
		},
		-- fidelity: row 7m says it does not matter (~170 massless clones).
	},
}

--[[
	MATERIALS. Set Neon on exactly these and nothing else.

	Everything else that glows is asserted in code after the clone - every
	BodyController's own glow pass, WrackBodyController's `Glow`-in-the-name
	rule, or BossArenaService's GLOW_MARKERS for arenas (which is why no arena
	part appears here, the Ashfall lava and seam rings included).

	`Noctyss_Gullet` is belt-and-braces: NoctyssBodyController.setLantern
	states it on whichever part it is handed. It costs nothing and the ledger
	header asks for it.
]]
local NEON = {
	Noctyss_Gullet = true,
}

-- Dark ON PURPOSE. Never Neon; the report asserts they came out non-Neon.
-- (Kraken_Pupil's slit stops reading as a pupil, and a second neon piece on
-- Gnashroot makes the punish target ambiguous.)
local MUST_NOT_BE_NEON = { "Kraken_Pupil", "Gnashroot_Eye" }

--=====================================================================
-- GEOMETRY (generated - the block below is rewritten by bundle_gen.py)
--=====================================================================

-- GEOMETRY BEGIN (generated by assets/bundle_gen.py - do not edit)
--[[
	Per pack, per object: the bounding box Studio should end up with, in
	ROBLOX axes and studs, measured in Blender on the very bundle in
	assets/bundles/. Each row is

	    { sizeX, sizeY, sizeZ, centreX, centreY, centreZ, anchorObjectName }

	where the centre is RELATIVE to the anchor object's own bbox centre, so
	the check is blind to where Studio dropped the import and to where the
	game moves the pack afterwards, and sees only the layout inside it.

	Regenerate with `blender --background --python assets/bundle_gen.py`;
	it rewrites everything between the two markers and nothing else.
]]
local GEOMETRY = {
	ArmorPack = {
		["Boneplate_Chest"] = { 2.439, 1.875, 2.017, 0.000, 0.000, 0.000, "Boneplate_Chest" },
		["Boneplate_Helm"] = { 1.706, 1.780, 2.827, 0.000, 0.308, 0.203, "Boneplate_Chest" },
		["Boneplate_Legs"] = { 2.396, 1.381, 1.593, -0.017, -0.189, -0.105, "Boneplate_Chest" },
		["Chitin_Chest_LeftHand_Under"] = { 1.120, 0.400, 1.120, 0.000, 0.012, -0.129, "Boneplate_Chest" },
		["Chitin_Chest_LeftLowerArm_Accent"] = { 0.729, 0.371, 0.116, -0.004, 0.274, 0.589, "Boneplate_Chest" },
		["Chitin_Chest_LeftLowerArm_Plate"] = { 1.117, 0.685, 0.178, 0.000, -0.104, 0.577, "Boneplate_Chest" },
		["Chitin_Chest_LeftLowerArm_Under"] = { 1.120, 0.980, 1.120, 0.000, 0.012, -0.129, "Boneplate_Chest" },
		["Chitin_Chest_LeftUpperArm_Plate"] = { 1.105, 0.919, 1.582, 0.000, 0.238, -0.119, "Boneplate_Chest" },
		["Chitin_Chest_LeftUpperArm_Under"] = { 1.120, 0.980, 1.120, 0.000, 0.012, -0.129, "Boneplate_Chest" },
		["Chitin_Chest_RightHand_Under"] = { 1.120, 0.400, 1.120, 0.000, 0.012, -0.129, "Boneplate_Chest" },
		["Chitin_Chest_RightLowerArm_Accent"] = { 0.729, 0.371, 0.116, 0.004, 0.274, 0.589, "Boneplate_Chest" },
		["Chitin_Chest_RightLowerArm_Plate"] = { 1.117, 0.685, 0.178, 0.000, -0.104, 0.577, "Boneplate_Chest" },
		["Chitin_Chest_RightLowerArm_Under"] = { 1.120, 0.980, 1.120, 0.000, 0.012, -0.129, "Boneplate_Chest" },
		["Chitin_Chest_RightUpperArm_Plate"] = { 1.105, 0.919, 1.582, 0.000, 0.238, -0.119, "Boneplate_Chest" },
		["Chitin_Chest_RightUpperArm_Under"] = { 1.120, 0.980, 1.120, 0.000, 0.012, -0.129, "Boneplate_Chest" },
		["Chitin_Chest_UpperTorso_Plate"] = { 1.976, 1.578, 1.600, 0.000, 0.181, -0.128, "Boneplate_Chest" },
		["Chitin_Chest_UpperTorso_Trim"] = { 1.065, 0.881, 0.109, 0.000, -0.292, 0.607, "Boneplate_Chest" },
		["Chitin_Chest_UpperTorso_Under"] = { 2.120, 1.720, 1.120, 0.000, 0.012, -0.129, "Boneplate_Chest" },
		["Chitin_Helm_Head_Accent"] = { 1.241, 0.180, 0.153, 0.000, -0.168, 0.677, "Boneplate_Chest" },
		["Chitin_Helm_Head_Plate"] = { 1.674, 1.393, 1.686, 0.000, 0.199, -0.077, "Boneplate_Chest" },
		["Chitin_Helm_Head_Trim"] = { 1.600, 0.645, 1.600, 0.000, 0.143, -0.129, "Boneplate_Chest" },
		["Chitin_Helm_Head_Under"] = { 1.320, 1.320, 1.320, 0.000, 0.012, -0.129, "Boneplate_Chest" },
		["Chitin_Legs_LeftFoot_Plate"] = { 1.260, 0.540, 0.780, 0.000, 0.012, 0.091, "Boneplate_Chest" },
		["Chitin_Legs_LeftFoot_Under"] = { 1.120, 0.400, 1.120, 0.000, 0.012, -0.129, "Boneplate_Chest" },
		["Chitin_Legs_LeftLowerLeg_Plate"] = { 1.178, 0.749, 0.185, 0.000, -0.091, 0.579, "Boneplate_Chest" },
		["Chitin_Legs_LeftLowerLeg_Under"] = { 1.120, 0.980, 1.120, 0.000, 0.012, -0.129, "Boneplate_Chest" },
		["Chitin_Legs_LeftUpperLeg_Accent"] = { 0.753, 0.421, 0.122, -0.004, -0.190, 0.588, "Boneplate_Chest" },
		["Chitin_Legs_LeftUpperLeg_Under"] = { 1.120, 0.980, 1.120, 0.000, 0.012, -0.129, "Boneplate_Chest" },
		["Chitin_Legs_LowerTorso_Plate"] = { 1.888, 0.597, 1.591, 0.003, -0.170, -0.124, "Boneplate_Chest" },
		["Chitin_Legs_LowerTorso_Trim"] = { 2.580, 0.326, 1.590, 0.000, 0.148, -0.124, "Boneplate_Chest" },
		["Chitin_Legs_LowerTorso_Under"] = { 2.120, 0.520, 1.120, 0.000, 0.012, -0.129, "Boneplate_Chest" },
		["Chitin_Legs_RightFoot_Plate"] = { 1.260, 0.540, 0.780, 0.000, 0.012, 0.091, "Boneplate_Chest" },
		["Chitin_Legs_RightFoot_Under"] = { 1.120, 0.400, 1.120, 0.000, 0.012, -0.129, "Boneplate_Chest" },
		["Chitin_Legs_RightLowerLeg_Plate"] = { 1.178, 0.749, 0.185, 0.000, -0.091, 0.579, "Boneplate_Chest" },
		["Chitin_Legs_RightLowerLeg_Under"] = { 1.120, 0.980, 1.120, 0.000, 0.012, -0.129, "Boneplate_Chest" },
		["Chitin_Legs_RightUpperLeg_Accent"] = { 0.753, 0.421, 0.122, 0.004, -0.190, 0.588, "Boneplate_Chest" },
		["Chitin_Legs_RightUpperLeg_Under"] = { 1.120, 0.980, 1.120, 0.000, 0.012, -0.129, "Boneplate_Chest" },
		["Cindershell_Chest"] = { 2.587, 1.821, 1.865, 0.000, -0.058, -0.072, "Boneplate_Chest" },
		["Cindershell_Helm"] = { 1.687, 1.888, 2.499, 0.000, 0.192, -0.426, "Boneplate_Chest" },
		["Cindershell_Legs"] = { 2.280, 1.290, 1.502, 0.000, -0.313, -0.042, "Boneplate_Chest" },
		["CorsairsRest_Chest"] = { 2.647, 1.896, 2.050, 0.000, 0.084, 0.196, "Boneplate_Chest" },
		["CorsairsRest_Helm"] = { 2.357, 1.750, 2.276, 0.000, 0.368, 0.077, "Boneplate_Chest" },
		["CorsairsRest_Legs"] = { 2.650, 1.705, 1.948, 0.000, -0.560, -0.129, "Boneplate_Chest" },
		["Duskveil_Chest"] = { 2.366, 2.336, 1.525, -0.007, 0.041, -0.036, "Boneplate_Chest" },
		["Duskveil_Helm"] = { 1.661, 2.280, 3.074, -0.019, -0.058, -0.061, "Boneplate_Chest" },
		["Duskveil_Legs"] = { 2.240, 1.805, 1.414, 0.003, -0.690, -0.208, "Boneplate_Chest" },
		["Mirewalker_Chest"] = { 2.491, 2.960, 1.813, -0.073, 0.663, 0.218, "Boneplate_Chest" },
		["Mirewalker_Helm"] = { 1.820, 2.415, 1.980, -0.022, 0.403, -0.158, "Boneplate_Chest" },
		["Mirewalker_Legs"] = { 2.320, 1.348, 1.575, 0.005, -0.323, -0.025, "Boneplate_Chest" },
		["Rimebound_Chest"] = { 2.640, 1.730, 1.550, 0.000, 0.082, -0.044, "Boneplate_Chest" },
		["Rimebound_Helm"] = { 2.044, 2.447, 2.081, 0.000, -0.074, -0.093, "Boneplate_Chest" },
		["Rimebound_Legs"] = { 2.469, 1.390, 1.512, 0.000, -0.373, -0.140, "Boneplate_Chest" },
		["Stormcaller_Chest"] = { 2.610, 2.237, 2.706, 0.000, 0.048, -0.132, "Boneplate_Chest" },
		["Stormcaller_Helm"] = { 2.158, 2.102, 2.434, 0.000, 0.589, -0.123, "Boneplate_Chest" },
		["Stormcaller_Legs"] = { 2.655, 1.610, 2.244, 0.000, -0.435, -0.208, "Boneplate_Chest" },
		["Tideward_Chest_LeftHand_Under"] = { 1.120, 0.400, 1.120, 0.000, 0.012, -0.129, "Boneplate_Chest" },
		["Tideward_Chest_LeftLowerArm_Accent"] = { 0.312, 0.268, 0.258, 0.000, 0.296, 0.524, "Boneplate_Chest" },
		["Tideward_Chest_LeftLowerArm_Plate"] = { 0.946, 0.645, 0.141, 0.000, -0.105, 0.550, "Boneplate_Chest" },
		["Tideward_Chest_LeftLowerArm_Under"] = { 1.120, 0.980, 1.120, 0.000, 0.012, -0.129, "Boneplate_Chest" },
		["Tideward_Chest_LeftUpperArm_Plate"] = { 0.943, 0.889, 1.492, 0.000, 0.258, -0.131, "Boneplate_Chest" },
		["Tideward_Chest_LeftUpperArm_Under"] = { 1.120, 0.980, 1.120, 0.000, 0.012, -0.129, "Boneplate_Chest" },
		["Tideward_Chest_RightHand_Under"] = { 1.120, 0.400, 1.120, 0.000, 0.012, -0.129, "Boneplate_Chest" },
		["Tideward_Chest_RightLowerArm_Accent"] = { 0.312, 0.268, 0.258, 0.000, 0.296, 0.524, "Boneplate_Chest" },
		["Tideward_Chest_RightLowerArm_Plate"] = { 0.946, 0.645, 0.141, 0.000, -0.105, 0.550, "Boneplate_Chest" },
		["Tideward_Chest_RightLowerArm_Under"] = { 1.120, 0.980, 1.120, 0.000, 0.012, -0.129, "Boneplate_Chest" },
		["Tideward_Chest_RightUpperArm_Plate"] = { 0.943, 0.889, 1.492, 0.000, 0.258, -0.131, "Boneplate_Chest" },
		["Tideward_Chest_RightUpperArm_Under"] = { 1.120, 0.980, 1.120, 0.000, 0.012, -0.129, "Boneplate_Chest" },
		["Tideward_Chest_UpperTorso_Accent"] = { 0.392, 0.337, 0.276, 0.000, 0.668, 0.513, "Boneplate_Chest" },
		["Tideward_Chest_UpperTorso_Plate"] = { 1.826, 1.351, 1.576, 0.000, 0.172, -0.132, "Boneplate_Chest" },
		["Tideward_Chest_UpperTorso_Under"] = { 2.120, 1.720, 1.120, 0.000, 0.012, -0.129, "Boneplate_Chest" },
		["Tideward_Helm_Head_Accent"] = { 0.364, 0.313, 0.276, 0.000, 0.252, 0.613, "Boneplate_Chest" },
		["Tideward_Helm_Head_Plate"] = { 1.760, 1.451, 1.760, 0.000, 0.059, -0.129, "Boneplate_Chest" },
		["Tideward_Helm_Head_Trim"] = { 1.600, 0.155, 1.640, 0.000, 0.444, -0.109, "Boneplate_Chest" },
		["Tideward_Helm_Head_Under"] = { 1.320, 1.320, 1.320, 0.000, 0.012, -0.129, "Boneplate_Chest" },
		["Tideward_Legs_LeftFoot_Plate"] = { 1.260, 0.540, 0.800, 0.000, 0.012, 0.071, "Boneplate_Chest" },
		["Tideward_Legs_LeftFoot_Under"] = { 1.120, 0.400, 1.120, 0.000, 0.012, -0.129, "Boneplate_Chest" },
		["Tideward_Legs_LeftLowerLeg_Plate"] = { 0.946, 0.711, 1.480, 0.000, -0.108, -0.131, "Boneplate_Chest" },
		["Tideward_Legs_LeftLowerLeg_Under"] = { 1.120, 0.980, 1.120, 0.000, 0.012, -0.129, "Boneplate_Chest" },
		["Tideward_Legs_LeftUpperLeg_Plate"] = { 0.800, 0.411, 0.138, 0.000, 0.059, 0.579, "Boneplate_Chest" },
		["Tideward_Legs_LeftUpperLeg_Under"] = { 1.120, 0.980, 1.120, 0.000, 0.012, -0.129, "Boneplate_Chest" },
		["Tideward_Legs_LowerTorso_Plate"] = { 1.826, 0.542, 1.509, 0.000, -0.196, -0.130, "Boneplate_Chest" },
		["Tideward_Legs_LowerTorso_Trim"] = { 2.540, 0.217, 1.570, 0.000, 0.172, -0.114, "Boneplate_Chest" },
		["Tideward_Legs_LowerTorso_Under"] = { 2.120, 0.520, 1.120, 0.000, 0.012, -0.129, "Boneplate_Chest" },
		["Tideward_Legs_RightFoot_Plate"] = { 1.260, 0.540, 0.800, 0.000, 0.012, 0.071, "Boneplate_Chest" },
		["Tideward_Legs_RightFoot_Under"] = { 1.120, 0.400, 1.120, 0.000, 0.012, -0.129, "Boneplate_Chest" },
		["Tideward_Legs_RightLowerLeg_Plate"] = { 0.946, 0.711, 1.480, 0.000, -0.108, -0.131, "Boneplate_Chest" },
		["Tideward_Legs_RightLowerLeg_Under"] = { 1.120, 0.980, 1.120, 0.000, 0.012, -0.129, "Boneplate_Chest" },
		["Tideward_Legs_RightUpperLeg_Plate"] = { 0.800, 0.411, 0.138, 0.000, 0.059, 0.579, "Boneplate_Chest" },
		["Tideward_Legs_RightUpperLeg_Under"] = { 1.120, 0.980, 1.120, 0.000, 0.012, -0.129, "Boneplate_Chest" },
		["Wraithbound_Chest"] = { 2.630, 2.542, 1.617, 0.006, -0.229, -0.117, "Boneplate_Chest" },
		["Wraithbound_Helm"] = { 2.396, 1.540, 2.069, -0.045, 0.254, -0.285, "Boneplate_Chest" },
		["Wraithbound_Legs"] = { 2.601, 1.923, 1.725, 0.006, -0.679, -0.044, "Boneplate_Chest" },
	},
	BoatPack = {
		["AbyssalLanterns_Bow"] = { 0.140, 3.725, 1.150, 0.000, 0.000, 0.000, "AbyssalLanterns_Bow" },
		["AbyssalLanterns_Deck"] = { 4.760, 0.140, 17.160, 0.000, 0.953, -12.145, "AbyssalLanterns_Bow" },
		["AbyssalLanterns_Helm"] = { 0.450, 0.840, 0.450, 0.000, 1.533, -17.425, "AbyssalLanterns_Bow" },
		["AbyssalLanterns_Hull"] = { 7.000, 3.800, 22.000, 0.000, -0.287, -10.825, "AbyssalLanterns_Bow" },
		["AbyssalLanterns_Lantern"] = { 5.889, 0.600, 12.508, 0.000, 2.793, -12.475, "AbyssalLanterns_Bow" },
		["AbyssalLanterns_Mast"] = { 0.260, 11.540, 6.753, 0.000, 6.782, -12.732, "AbyssalLanterns_Bow" },
		["AbyssalLanterns_Rail"] = { 6.440, 1.500, 16.130, 0.000, 1.863, -13.170, "AbyssalLanterns_Bow" },
		["AbyssalLanterns_Sail"] = { 0.080, 7.322, 6.200, 0.000, 7.977, -12.785, "AbyssalLanterns_Bow" },
		["AbyssalLanterns_Shelf"] = { 6.000, 0.600, 1.300, 0.000, 1.412, -20.065, "AbyssalLanterns_Bow" },
		["AshguardPlating_Bow"] = { 0.140, 3.450, 1.150, 0.000, -0.062, -1.000, "AbyssalLanterns_Bow" },
		["AshguardPlating_Deck"] = { 4.420, 0.140, 15.600, 0.000, 0.752, -12.025, "AbyssalLanterns_Bow" },
		["AshguardPlating_Helm"] = { 0.450, 0.840, 0.450, 0.000, 1.333, -16.825, "AbyssalLanterns_Bow" },
		["AshguardPlating_Hull"] = { 6.500, 3.500, 20.000, 0.000, -0.338, -10.825, "AbyssalLanterns_Bow" },
		["AshguardPlating_Mast"] = { 0.260, 10.500, 6.153, 0.000, 6.062, -12.552, "AbyssalLanterns_Bow" },
		["AshguardPlating_Rail"] = { 5.990, 0.360, 14.670, 0.000, 1.183, -12.960, "AbyssalLanterns_Bow" },
		["AshguardPlating_Sail"] = { 0.080, 6.656, 5.620, 0.000, 7.152, -12.615, "AbyssalLanterns_Bow" },
		["AshguardPlating_Shelf"] = { 5.900, 0.600, 1.300, 0.000, 1.212, -19.225, "AbyssalLanterns_Bow" },
		["AshguardPlating_Trim"] = { 6.360, 1.346, 10.400, 0.000, -0.014, -10.825, "AbyssalLanterns_Bow" },
		["CoveSkiff_Bow"] = { 0.140, 2.625, 1.150, 0.000, -0.250, -4.000, "AbyssalLanterns_Bow" },
		["CoveSkiff_Deck"] = { 3.400, 0.140, 10.920, 0.000, 0.153, -11.665, "AbyssalLanterns_Bow" },
		["CoveSkiff_Helm"] = { 0.450, 0.840, 0.450, 0.000, 0.733, -15.025, "AbyssalLanterns_Bow" },
		["CoveSkiff_Hull"] = { 5.000, 2.600, 14.000, 0.000, -0.487, -10.825, "AbyssalLanterns_Bow" },
		["CoveSkiff_Rail"] = { 4.640, 0.360, 10.290, 0.000, 0.583, -12.330, "AbyssalLanterns_Bow" },
		["CoveSkiff_Shelf"] = { 4.400, 0.600, 1.300, 0.000, 0.613, -16.705, "AbyssalLanterns_Bow" },
		["IcebreakerProw_Bow"] = { 0.280, 3.175, 1.150, 0.000, -0.125, -2.000, "AbyssalLanterns_Bow" },
		["IcebreakerProw_Deck"] = { 4.080, 0.140, 14.040, 0.000, 0.553, -11.905, "AbyssalLanterns_Bow" },
		["IcebreakerProw_Helm"] = { 0.450, 0.840, 0.450, 0.000, 1.133, -16.225, "AbyssalLanterns_Bow" },
		["IcebreakerProw_Hull"] = { 6.000, 3.200, 18.000, 0.000, -0.388, -10.825, "AbyssalLanterns_Bow" },
		["IcebreakerProw_Mast"] = { 0.260, 9.460, 5.553, 0.000, 5.343, -12.372, "AbyssalLanterns_Bow" },
		["IcebreakerProw_Rail"] = { 5.540, 0.360, 13.210, 0.000, 0.983, -12.750, "AbyssalLanterns_Bow" },
		["IcebreakerProw_Sail"] = { 0.080, 5.990, 5.040, 0.000, 6.328, -12.445, "AbyssalLanterns_Bow" },
		["IcebreakerProw_Shelf"] = { 5.400, 0.600, 1.300, 0.000, 1.012, -18.385, "AbyssalLanterns_Bow" },
		["IcebreakerProw_Trim"] = { 5.880, 0.400, 10.080, 0.000, -0.407, -10.825, "AbyssalLanterns_Bow" },
		["IronbogHull_Bow"] = { 0.140, 2.900, 1.150, 0.000, -0.187, -3.000, "AbyssalLanterns_Bow" },
		["IronbogHull_Deck"] = { 3.740, 0.140, 12.480, 0.000, 0.353, -11.785, "AbyssalLanterns_Bow" },
		["IronbogHull_Helm"] = { 0.450, 0.840, 0.450, 0.000, 0.933, -15.625, "AbyssalLanterns_Bow" },
		["IronbogHull_Hull"] = { 5.500, 2.900, 16.000, 0.000, -0.438, -10.825, "AbyssalLanterns_Bow" },
		["IronbogHull_Mast"] = { 0.260, 8.420, 4.953, 0.000, 4.623, -12.192, "AbyssalLanterns_Bow" },
		["IronbogHull_Rail"] = { 5.090, 0.360, 11.750, 0.000, 0.782, -12.540, "AbyssalLanterns_Bow" },
		["IronbogHull_Sail"] = { 0.080, 5.325, 4.460, 0.000, 5.505, -12.275, "AbyssalLanterns_Bow" },
		["IronbogHull_Shelf"] = { 4.900, 0.600, 1.300, 0.000, 0.813, -17.545, "AbyssalLanterns_Bow" },
		["IronbogHull_Trim"] = { 5.400, 0.400, 8.960, 0.000, -0.467, -10.825, "AbyssalLanterns_Bow" },
		["StormbreakerKeel_Bow"] = { 0.140, 4.000, 1.150, 0.000, 0.063, 1.000, "AbyssalLanterns_Bow" },
		["StormbreakerKeel_Deck"] = { 5.440, 0.140, 18.720, 0.000, 1.152, -12.265, "AbyssalLanterns_Bow" },
		["StormbreakerKeel_Figurehead"] = { 0.537, 0.640, 1.325, 0.000, 2.263, 1.562, "AbyssalLanterns_Bow" },
		["StormbreakerKeel_Helm"] = { 0.450, 0.840, 0.450, 0.000, 1.732, -18.025, "AbyssalLanterns_Bow" },
		["StormbreakerKeel_Hull"] = { 8.000, 4.100, 24.000, 0.000, -0.237, -10.825, "AbyssalLanterns_Bow" },
		["StormbreakerKeel_Lantern"] = { 6.669, 5.670, 15.924, 0.000, 0.458, -12.187, "AbyssalLanterns_Bow" },
		["StormbreakerKeel_Mast"] = { 0.260, 12.580, 7.353, 0.000, 7.503, -12.912, "AbyssalLanterns_Bow" },
		["StormbreakerKeel_Rail"] = { 7.340, 1.500, 17.590, 0.000, 2.063, -13.380, "AbyssalLanterns_Bow" },
		["StormbreakerKeel_Sail"] = { 0.080, 11.032, 16.800, 0.000, 7.278, -7.945, "AbyssalLanterns_Bow" },
		["StormbreakerKeel_Shelf"] = { 6.000, 0.600, 1.300, 0.000, 1.613, -20.905, "AbyssalLanterns_Bow" },
		["StormbreakerKeel_Trim"] = { 7.800, 0.400, 13.440, 0.000, -0.227, -10.825, "AbyssalLanterns_Bow" },
	},
	BrinejawArena = {
		["BrinejawArena_Base"] = { 176.219, 12.716, 177.302, 0.000, 0.000, 0.000, "BrinejawArena_Base" },
		["BrinejawArena_Bell"] = { 4.565, 4.691, 4.687, 26.833, 3.460, -39.409, "BrinejawArena_Base" },
		["BrinejawArena_Boat"] = { 9.649, 2.062, 8.413, -33.167, 4.942, -42.835, "BrinejawArena_Base" },
		["BrinejawArena_CoralPink"] = { 138.253, 2.800, 135.081, -1.108, 4.691, 0.811, "BrinejawArena_Base" },
		["BrinejawArena_CoralTeal"] = { 94.070, 2.829, 126.722, -4.892, 4.737, -2.403, "BrinejawArena_Base" },
		["BrinejawArena_Foam"] = { 171.298, 0.060, 172.599, 0.527, 3.392, -0.911, "BrinejawArena_Base" },
		["BrinejawArena_Kelp"] = { 153.778, 6.004, 143.450, -1.724, 7.064, -0.352, "BrinejawArena_Base" },
		["BrinejawArena_Mast"] = { 24.912, 10.465, 21.039, 52.713, 8.389, 44.040, "BrinejawArena_Base" },
		["BrinejawArena_ReefStone1"] = { 3.688, 3.366, 3.614, 39.693, 4.269, -11.271, "BrinejawArena_Base" },
		["BrinejawArena_ReefStone2"] = { 3.675, 2.556, 3.423, -27.273, 4.226, -28.952, "BrinejawArena_Base" },
		["BrinejawArena_ReefStone3"] = { 3.827, 2.745, 3.477, -9.420, 4.117, 37.643, "BrinejawArena_Base" },
		["BrinejawArena_Rocks"] = { 162.427, 15.856, 163.434, 1.706, 4.897, -0.394, "BrinejawArena_Base" },
		["BrinejawArena_Rubble"] = { 29.570, 3.801, 24.825, 7.639, 4.673, -2.105, "BrinejawArena_Base" },
		["BrinejawArena_SailRag"] = { 5.650, 7.697, 8.376, 55.410, 6.767, 47.076, "BrinejawArena_Base" },
		["BrinejawArena_SeaStacks"] = { 159.964, 23.642, 134.814, 2.182, 10.963, -1.017, "BrinejawArena_Base" },
		["BrinejawArena_Spire"] = { 21.400, 57.841, 21.400, 0.833, 32.562, -0.835, "BrinejawArena_Base" },
		["BrinejawArena_SpireBand"] = { 14.100, 23.000, 14.100, 0.833, 38.642, -0.835, "BrinejawArena_Base" },
		["BrinejawArena_SpireRail"] = { 14.280, 8.421, 14.280, 0.833, 63.552, -0.835, "BrinejawArena_Base" },
		["BrinejawArena_SpireWindows"] = { 13.737, 46.000, 17.159, 1.402, 27.242, 0.986, "BrinejawArena_Base" },
	},
	BrinejawFxPack = {
		["BrinejawFx_Crest1"] = { 3.855, 9.547, 12.000, 0.000, 0.000, 0.000, "BrinejawFx_Crest1" },
		["BrinejawFx_Crest2"] = { 3.853, 9.963, 12.000, 0.338, 0.208, 0.000, "BrinejawFx_Crest1" },
		["BrinejawFx_Foam"] = { 3.384, 1.371, 12.000, -0.115, -4.115, 0.000, "BrinejawFx_Crest1" },
		["BrinejawFx_Rock1"] = { 2.788, 2.760, 2.651, -0.244, -4.733, -0.204, "BrinejawFx_Crest1" },
		["BrinejawFx_Rock2"] = { 2.074, 2.143, 3.593, -0.139, -4.500, -0.067, "BrinejawFx_Crest1" },
		["BrinejawFx_Spike1"] = { 4.416, 8.600, 5.273, -0.276, -0.473, -0.372, "BrinejawFx_Crest1" },
		["BrinejawFx_Spike2"] = { 4.248, 7.200, 4.450, -0.189, -1.173, -0.680, "BrinejawFx_Crest1" },
		["BrinejawFx_Spike3"] = { 5.129, 9.000, 5.004, 0.011, -0.273, 0.452, "BrinejawFx_Crest1" },
		["BrinejawFx_Spine"] = { 4.030, 3.681, 0.805, 1.712, -4.874, 0.000, "BrinejawFx_Crest1" },
		["BrinejawFx_SpoutBase"] = { 4.722, 0.866, 4.590, -0.271, -4.340, 0.057, "BrinejawFx_Crest1" },
	},
	BrinejawPack = {
		["Brinejaw_Eyes"] = { 1.521, 1.700, 7.846, 0.000, 0.000, 0.000, "Brinejaw_Eyes" },
		["Brinejaw_Frill"] = { 5.461, 8.923, 14.738, -4.839, 0.643, -0.225, "Brinejaw_Eyes" },
		["Brinejaw_Head"] = { 14.900, 4.448, 7.565, 2.350, 0.124, -0.118, "Brinejaw_Eyes" },
		["Brinejaw_HeadBone"] = { 17.923, 7.622, 10.434, 0.852, 0.107, 0.000, "Brinejaw_Eyes" },
		["Brinejaw_Jaw"] = { 13.800, 4.564, 5.800, 2.300, -4.632, 0.000, "Brinejaw_Eyes" },
		["Brinejaw_JawBone"] = { 10.880, 1.529, 6.077, 3.000, -1.712, 0.000, "Brinejaw_Eyes" },
		["Brinejaw_Rattle"] = { 12.006, 6.500, 6.401, -2.403, -1.500, -0.100, "Brinejaw_Eyes" },
		["Brinejaw_Seg"] = { 4.600, 5.641, 5.000, 1.400, -1.205, 0.000, "Brinejaw_Eyes" },
		["Brinejaw_SegFin"] = { 4.760, 8.746, 9.623, 1.320, 0.170, 0.000, "Brinejaw_Eyes" },
	},
	CreaturePack = {
		["AdmiralWrack_Body"] = { 10.400, 8.186, 6.081, 0.000, 0.000, 0.000, "AdmiralWrack_Body" },
		["AdmiralWrack_Eyes"] = { 0.250, 0.400, 0.906, 1.060, 3.007, 0.023, "AdmiralWrack_Body" },
		["AdmiralWrack_Fins"] = { 10.118, 9.562, 6.139, -0.317, -0.374, 0.023, "AdmiralWrack_Body" },
		["AdmiralWrack_Marks"] = { 10.650, 5.431, 4.640, -0.325, -0.087, 0.023, "AdmiralWrack_Body" },
		["Angler_Body"] = { 3.125, 3.493, 1.919, 0.647, -1.268, 0.013, "AdmiralWrack_Body" },
		["Angler_Eyes"] = { 0.152, 0.200, 0.485, 0.600, -0.693, 0.023, "AdmiralWrack_Body" },
		["Angler_Fins"] = { 3.038, 4.390, 2.469, 0.931, -2.108, 0.124, "AdmiralWrack_Body" },
		["Angler_Marks"] = { 0.571, 2.138, 0.837, -0.940, -0.899, 0.023, "AdmiralWrack_Body" },
		["AuroraJelly_Body"] = { 2.187, 1.300, 2.300, 1.400, -2.043, 0.023, "AdmiralWrack_Body" },
		["AuroraJelly_Eyes"] = { 0.125, 0.140, 0.719, 0.850, -2.543, 0.023, "AdmiralWrack_Body" },
		["AuroraJelly_Fins"] = { 2.382, 1.684, 2.442, 1.339, -3.411, 0.023, "AdmiralWrack_Body" },
		["AuroraJelly_Marks"] = { 2.006, 0.988, 1.955, 1.387, -1.868, 0.074, "AdmiralWrack_Body" },
		["BlizzardWraith_Body"] = { 2.989, 3.896, 2.249, 1.480, -2.201, 0.047, "AdmiralWrack_Body" },
		["BlizzardWraith_Eyes"] = { 0.179, 0.240, 0.493, 0.920, -0.553, 0.023, "AdmiralWrack_Body" },
		["BlizzardWraith_Fins"] = { 4.129, 4.026, 2.040, 1.014, -2.036, 0.023, "AdmiralWrack_Body" },
		["BlizzardWraith_Marks"] = { 2.368, 1.555, 0.850, 0.170, -0.816, -0.232, "AdmiralWrack_Body" },
		["BogGull_Body"] = { 3.329, 1.300, 0.936, 0.764, -3.093, 0.023, "AdmiralWrack_Body" },
		["BogGull_Eyes"] = { 0.161, 0.180, 0.559, -0.050, -2.673, 0.023, "AdmiralWrack_Body" },
		["BogGull_Fins"] = { 4.700, 0.310, 4.100, 1.350, -2.938, 0.023, "AdmiralWrack_Body" },
		["BogGull_Marks"] = { 0.717, 0.050, 3.206, 2.500, -2.763, 0.023, "AdmiralWrack_Body" },
		["CannonballCrab_Body"] = { 1.574, 1.860, 1.720, 1.400, -3.413, 0.023, "AdmiralWrack_Body" },
		["CannonballCrab_Eyes"] = { 0.143, 0.160, 0.636, 0.480, -3.043, 0.023, "AdmiralWrack_Body" },
		["CannonballCrab_Fins"] = { 2.428, 1.229, 2.337, 0.666, -3.686, 0.023, "AdmiralWrack_Body" },
		["CannonballCrab_Marks"] = { 0.233, 0.260, 0.204, 1.760, -2.433, 0.173, "AdmiralWrack_Body" },
		["CinderDjinn_Body"] = { 1.502, 3.530, 1.500, 1.509, -2.498, 0.023, "AdmiralWrack_Body" },
		["CinderDjinn_Eyes"] = { 0.179, 0.220, 0.470, 0.900, -1.053, 0.023, "AdmiralWrack_Body" },
		["CinderDjinn_Fins"] = { 1.988, 1.908, 1.865, 0.894, -1.459, -0.057, "AdmiralWrack_Body" },
		["CinderDjinn_Marks"] = { 2.496, 2.138, 1.251, 0.548, -2.480, -0.145, "AdmiralWrack_Body" },
		["Crab_Body"] = { 2.194, 0.680, 2.100, 1.247, -3.803, 0.023, "AdmiralWrack_Body" },
		["Crab_Eyes"] = { 0.268, 0.300, 0.935, 0.310, -3.313, 0.023, "AdmiralWrack_Body" },
		["Crab_Fins"] = { 3.532, 1.560, 2.753, 0.492, -4.070, 0.021, "AdmiralWrack_Body" },
		["Crab_Marks"] = { 0.363, 0.927, 0.807, 0.352, -3.819, 0.030, "AdmiralWrack_Body" },
		["CroakjawToad_Body"] = { 3.175, 1.590, 2.657, 1.475, -3.498, 0.023, "AdmiralWrack_Body" },
		["CroakjawToad_Eyes"] = { 0.250, 0.260, 1.304, 0.780, -2.873, 0.023, "AdmiralWrack_Body" },
		["CroakjawToad_Fins"] = { 1.106, 0.196, 1.263, 1.854, -2.943, 0.011, "AdmiralWrack_Body" },
		["CroakjawToad_Marks"] = { 0.984, 0.700, 1.361, 0.450, -3.943, 0.023, "AdmiralWrack_Body" },
		["CursedChest_Body"] = { 2.050, 1.000, 1.400, 1.400, -3.793, 0.023, "AdmiralWrack_Body" },
		["CursedChest_Eyes"] = { 0.179, 0.200, 0.953, 0.450, -3.363, 0.023, "AdmiralWrack_Body" },
		["CursedChest_Fins"] = { 2.150, 0.880, 1.500, 1.385, -3.233, 0.023, "AdmiralWrack_Body" },
		["CursedChest_Marks"] = { 1.288, 0.930, 1.297, -0.093, -3.778, 0.039, "AdmiralWrack_Body" },
		["CycloneRay_Body"] = { 4.503, 0.600, 1.786, 1.952, -3.793, 0.023, "AdmiralWrack_Body" },
		["CycloneRay_Eyes"] = { 0.179, 0.160, 0.896, 0.350, -3.573, 0.023, "AdmiralWrack_Body" },
		["CycloneRay_Fins"] = { 2.200, 0.130, 3.800, 1.800, -3.793, 0.023, "AdmiralWrack_Body" },
		["CycloneRay_Marks"] = { 1.936, 0.120, 1.334, 1.516, -3.513, 0.165, "AdmiralWrack_Body" },
		["Deckhand_Body"] = { 2.597, 3.584, 1.965, 0.690, -2.485, -0.074, "AdmiralWrack_Body" },
		["Deckhand_Eyes"] = { 0.143, 0.200, 0.476, 0.440, -1.093, 0.023, "AdmiralWrack_Body" },
		["Deckhand_Fins"] = { 2.532, 3.133, 3.066, 1.681, -2.736, -0.327, "AdmiralWrack_Body" },
		["Deckhand_Marks"] = { 1.793, 3.084, 1.477, 0.924, -2.375, 0.063, "AdmiralWrack_Body" },
		["DreadDragonfly_Body"] = { 5.654, 0.819, 0.798, 1.677, -2.893, 0.044, "AdmiralWrack_Body" },
		["DreadDragonfly_Eyes"] = { 0.537, 0.560, 0.928, -0.600, -2.743, 0.023, "AdmiralWrack_Body" },
		["DreadDragonfly_Fins"] = { 1.800, 0.120, 4.100, 1.400, -2.703, 0.023, "AdmiralWrack_Body" },
		["DreadDragonfly_Marks"] = { 1.020, 0.248, 0.280, 3.690, -2.916, 0.023, "AdmiralWrack_Body" },
		["DrownedBoatswain_Body"] = { 1.621, 4.250, 2.362, 1.121, -2.168, -0.015, "AdmiralWrack_Body" },
		["DrownedBoatswain_Eyes"] = { 0.161, 0.220, 0.593, 0.900, -0.343, -0.027, "AdmiralWrack_Body" },
		["DrownedBoatswain_Fins"] = { 3.322, 3.960, 2.415, 0.741, -2.033, -0.162, "AdmiralWrack_Body" },
		["DrownedBoatswain_Marks"] = { 1.032, 2.261, 2.092, 0.676, -2.172, -0.055, "AdmiralWrack_Body" },
		["EmberSwarm_Body"] = { 3.358, 3.368, 3.089, 1.497, -2.549, -0.026, "AdmiralWrack_Body" },
		["EmberSwarm_Eyes"] = { 0.340, 0.360, 0.889, 0.520, -2.153, 0.023, "AdmiralWrack_Body" },
		["EmberSwarm_Fins"] = { 3.630, 0.446, 3.272, 2.189, -1.042, -0.108, "AdmiralWrack_Body" },
		["EmberSwarm_Marks"] = { 3.034, 3.157, 2.652, 1.520, -2.644, -0.079, "AdmiralWrack_Body" },
		["FenSerpent_Body"] = { 7.019, 2.050, 2.688, 1.326, -3.168, 0.101, "AdmiralWrack_Body" },
		["FenSerpent_Eyes"] = { 0.179, 0.180, 0.576, -1.750, -2.293, 0.023, "AdmiralWrack_Body" },
		["FenSerpent_Fins"] = { 0.900, 1.150, 0.920, -1.250, -2.718, 0.023, "AdmiralWrack_Body" },
		["FenSerpent_Marks"] = { 6.905, 0.897, 1.994, 1.352, -3.132, 0.049, "AdmiralWrack_Body" },
		["FlashbulbSquid_Body"] = { 1.240, 2.600, 1.178, 1.400, -1.393, 0.023, "AdmiralWrack_Body" },
		["FlashbulbSquid_Eyes"] = { 0.286, 0.320, 1.078, 0.950, -2.543, 0.023, "AdmiralWrack_Body" },
		["FlashbulbSquid_Fins"] = { 2.755, 3.400, 2.755, 1.400, -2.353, 0.023, "AdmiralWrack_Body" },
		["FlashbulbSquid_Marks"] = { 1.692, 1.750, 1.280, 1.204, -2.068, 0.043, "AdmiralWrack_Body" },
		["FrostbitePup_Body"] = { 4.115, 1.216, 1.280, 1.043, -3.613, 0.023, "AdmiralWrack_Body" },
		["FrostbitePup_Eyes"] = { 0.250, 0.280, 0.684, -0.550, -3.293, 0.023, "AdmiralWrack_Body" },
		["FrostbitePup_Fins"] = { 4.800, 0.320, 2.600, 1.500, -3.843, 0.023, "AdmiralWrack_Body" },
		["FrostbitePup_Marks"] = { 1.616, 0.160, 1.260, 1.550, -3.013, 0.048, "AdmiralWrack_Body" },
		["FrozenMariner_Body"] = { 2.420, 4.270, 1.903, 1.380, -2.158, -0.072, "AdmiralWrack_Body" },
		["FrozenMariner_Eyes"] = { 0.161, 0.220, 0.493, 0.560, -0.373, 0.023, "AdmiralWrack_Body" },
		["FrozenMariner_Fins"] = { 3.122, 3.130, 2.890, 0.814, -1.564, 0.220, "AdmiralWrack_Body" },
		["FrozenMariner_Marks"] = { 1.001, 2.008, 1.320, 0.399, -1.621, -0.054, "AdmiralWrack_Body" },
		["Fumarole_Body"] = { 2.778, 1.751, 2.120, 1.250, -3.437, 0.023, "AdmiralWrack_Body" },
		["Fumarole_Eyes"] = { 0.215, 0.220, 0.804, 0.100, -3.553, 0.023, "AdmiralWrack_Body" },
		["Fumarole_Fins"] = { 2.623, 0.644, 1.803, 1.324, -3.913, 0.023, "AdmiralWrack_Body" },
		["Fumarole_Marks"] = { 2.678, 1.506, 1.558, 1.196, -3.280, 0.023, "AdmiralWrack_Body" },
		["GalestreakFlyingfish_Body"] = { 3.700, 0.990, 0.900, 1.450, -3.393, 0.023, "AdmiralWrack_Body" },
		["GalestreakFlyingfish_Eyes"] = { 0.215, 0.240, 0.650, 0.050, -3.243, 0.023, "AdmiralWrack_Body" },
		["GalestreakFlyingfish_Fins"] = { 3.700, 1.200, 4.000, 2.250, -3.493, 0.023, "AdmiralWrack_Body" },
		["GalestreakFlyingfish_Marks"] = { 1.006, 0.110, 4.040, 3.199, -3.278, 0.023, "AdmiralWrack_Body" },
		["GhostfireJelly_Body"] = { 1.997, 1.180, 2.100, 1.400, -2.283, 0.023, "AdmiralWrack_Body" },
		["GhostfireJelly_Eyes"] = { 0.125, 0.140, 0.679, 0.900, -2.693, 0.023, "AdmiralWrack_Body" },
		["GhostfireJelly_Fins"] = { 2.240, 1.427, 2.411, 1.400, -3.483, 0.023, "AdmiralWrack_Body" },
		["GhostfireJelly_Marks"] = { 1.592, 1.314, 1.674, 1.316, -1.450, 0.023, "AdmiralWrack_Body" },
		["GlacialLurker_Body"] = { 4.400, 1.200, 2.000, 1.300, -3.673, 0.023, "AdmiralWrack_Body" },
		["GlacialLurker_Eyes"] = { 0.322, 0.160, 0.853, -0.300, -3.293, 0.023, "AdmiralWrack_Body" },
		["GlacialLurker_Fins"] = { 4.515, 1.555, 1.660, 0.758, -3.416, 0.023, "AdmiralWrack_Body" },
		["GlacialLurker_Marks"] = { 2.615, 0.259, 1.759, 1.298, -3.513, 0.023, "AdmiralWrack_Body" },
		["Gnashroot_Body"] = { 17.012, 3.264, 7.725, 1.656, -2.706, 0.023, "AdmiralWrack_Body" },
		["Gnashroot_Eyes"] = { 0.608, 0.440, 3.682, -3.150, -2.073, 0.023, "AdmiralWrack_Body" },
		["Gnashroot_Fins"] = { 17.844, 5.093, 9.128, 1.783, -1.724, 0.025, "AdmiralWrack_Body" },
		["Gnashroot_Marks"] = { 15.312, 4.099, 7.394, 2.672, -2.142, -0.002, "AdmiralWrack_Body" },
		["GulletCod_Body"] = { 3.650, 1.612, 1.225, 1.125, -3.867, 0.023, "AdmiralWrack_Body" },
		["GulletCod_Eyes"] = { 0.304, 0.340, 1.249, 0.350, -3.353, 0.023, "AdmiralWrack_Body" },
		["GulletCod_Fins"] = { 3.850, 1.501, 2.240, 1.525, -3.523, 0.023, "AdmiralWrack_Body" },
		["GulletCod_Marks"] = { 1.509, 1.306, 0.920, 0.296, -3.845, 0.023, "AdmiralWrack_Body" },
		["GulperEel_Body"] = { 6.118, 1.739, 2.037, 2.059, -3.130, 0.055, "AdmiralWrack_Body" },
		["GulperEel_Eyes"] = { 0.179, 0.200, 1.253, 1.050, -2.693, 0.023, "AdmiralWrack_Body" },
		["GulperEel_Fins"] = { 0.800, 0.400, 0.070, 5.300, -3.343, 0.223, "AdmiralWrack_Body" },
		["GulperEel_Marks"] = { 6.256, 1.090, 1.468, 2.256, -3.058, 0.023, "AdmiralWrack_Body" },
		["HailfinSkua_Body"] = { 3.807, 0.970, 0.817, 0.704, -2.928, 0.023, "AdmiralWrack_Body" },
		["HailfinSkua_Eyes"] = { 0.143, 0.160, 0.519, -0.280, -2.633, 0.023, "AdmiralWrack_Body" },
		["HailfinSkua_Fins"] = { 3.300, 0.240, 4.600, 2.350, -2.863, 0.023, "AdmiralWrack_Body" },
		["HailfinSkua_Marks"] = { 1.037, 0.050, 2.840, 1.400, -2.713, 0.023, "AdmiralWrack_Body" },
		["Hermit_Body"] = { 1.929, 1.705, 1.643, 2.098, -3.524, 0.023, "AdmiralWrack_Body" },
		["Hermit_Eyes"] = { 0.179, 0.200, 0.570, 0.600, -3.343, 0.023, "AdmiralWrack_Body" },
		["Hermit_Fins"] = { 1.798, 1.238, 2.034, 0.740, -3.682, 0.022, "AdmiralWrack_Body" },
		["Hermit_Marks"] = { 2.471, 0.579, 1.240, 1.231, -3.292, -0.107, "AdmiralWrack_Body" },
		["IceshardCrab_Body"] = { 2.458, 1.027, 2.533, 1.155, -3.788, 0.022, "AdmiralWrack_Body" },
		["IceshardCrab_Eyes"] = { 0.143, 0.160, 0.656, 0.330, -3.243, 0.023, "AdmiralWrack_Body" },
		["IceshardCrab_Fins"] = { 2.733, 1.430, 1.650, 0.673, -3.308, 0.078, "AdmiralWrack_Body" },
		["IceshardCrab_Marks"] = { 1.173, 0.240, 1.296, 1.404, -3.543, 0.069, "AdmiralWrack_Body" },
		["IceveinPike_Body"] = { 5.456, 1.012, 0.880, 1.172, -3.673, 0.023, "AdmiralWrack_Body" },
		["IceveinPike_Eyes"] = { 0.197, 0.220, 0.713, -0.650, -3.513, 0.023, "AdmiralWrack_Body" },
		["IceveinPike_Fins"] = { 6.325, 1.600, 2.000, 1.838, -3.593, 0.023, "AdmiralWrack_Body" },
		["IceveinPike_Marks"] = { 3.413, 0.349, 1.080, 1.099, -3.628, 0.023, "AdmiralWrack_Body" },
		["Jelly_Body"] = { 2.319, 1.170, 2.319, 1.400, -1.628, 0.023, "AdmiralWrack_Body" },
		["Jelly_Eyes"] = { 0.161, 0.180, 0.753, 0.400, -1.643, 0.023, "AdmiralWrack_Body" },
		["Jelly_Fins"] = { 2.469, 2.206, 2.454, 1.400, -3.196, 0.023, "AdmiralWrack_Body" },
		["Jelly_Marks"] = { 1.169, 2.495, 1.165, 1.400, -2.760, 0.019, "AdmiralWrack_Body" },
		["KrakenSpawn_Body"] = { 1.342, 1.400, 1.225, 1.400, -3.293, 0.023, "AdmiralWrack_Body" },
		["KrakenSpawn_Eyes"] = { 0.465, 0.480, 0.374, 0.780, -3.143, 0.023, "AdmiralWrack_Body" },
		["KrakenSpawn_Fins"] = { 2.764, 2.193, 2.727, 1.495, -2.761, -0.160, "AdmiralWrack_Body" },
		["KrakenSpawn_Marks"] = { 1.414, 0.160, 1.381, 1.439, -2.943, 0.049, "AdmiralWrack_Body" },
		["KrakenTentacle_Body"] = { 6.880, 8.246, 3.637, 0.060, -0.279, 0.023, "AdmiralWrack_Body" },
		["KrakenTentacle_Fins"] = { 7.760, 6.650, 0.878, -0.920, 0.732, 0.173, "AdmiralWrack_Body" },
		["KrakenTentacle_Marks"] = { 5.445, 7.853, 2.676, -0.283, 0.011, 0.095, "AdmiralWrack_Body" },
		["Kraken_Body"] = { 13.261, 11.495, 17.239, 1.469, 1.260, 0.033, "AdmiralWrack_Body" },
		["Kraken_Eyes"] = { 2.340, 2.680, 8.138, -0.648, 0.047, -0.301, "AdmiralWrack_Body" },
		["Kraken_Fins"] = { 11.517, 8.363, 17.151, 0.620, -0.568, 0.033, "AdmiralWrack_Body" },
		["Kraken_Marks"] = { 12.299, 11.227, 16.245, 1.443, 1.794, 0.032, "AdmiralWrack_Body" },
		["LanternjawAngler_Body"] = { 3.262, 2.912, 1.786, 1.112, -2.767, 0.023, "AdmiralWrack_Body" },
		["LanternjawAngler_Eyes"] = { 0.215, 0.240, 1.670, 0.850, -3.443, 0.023, "AdmiralWrack_Body" },
		["LanternjawAngler_Fins"] = { 2.360, 1.180, 1.786, 1.233, -3.353, 0.023, "AdmiralWrack_Body" },
		["LanternjawAngler_Marks"] = { 1.613, 2.100, 1.140, -0.201, -2.643, 0.023, "AdmiralWrack_Body" },
		["Leviathan_Body"] = { 12.800, 5.839, 5.038, 2.200, -1.510, 0.023, "AdmiralWrack_Body" },
		["Leviathan_Eyes"] = { 0.894, 0.840, 4.810, -2.200, -0.543, 0.023, "AdmiralWrack_Body" },
		["Leviathan_Fins"] = { 17.334, 8.300, 8.600, 2.233, 0.157, 0.023, "AdmiralWrack_Body" },
		["Leviathan_Marks"] = { 11.199, 4.850, 4.700, -0.792, -0.268, 0.023, "AdmiralWrack_Body" },
		["LodestoneEel_Body"] = { 5.691, 0.800, 0.996, 1.308, -3.783, 0.084, "AdmiralWrack_Body" },
		["LodestoneEel_Eyes"] = { 0.179, 0.200, 0.650, -1.260, -3.673, 0.023, "AdmiralWrack_Body" },
		["LodestoneEel_Fins"] = { 5.100, 1.580, 2.100, 1.600, -3.583, 0.023, "AdmiralWrack_Body" },
		["LodestoneEel_Marks"] = { 4.370, 1.856, 1.061, 0.804, -3.381, 0.023, "AdmiralWrack_Body" },
		["Lurker_Body"] = { 2.568, 0.691, 1.800, 1.350, -3.938, 0.023, "AdmiralWrack_Body" },
		["Lurker_Eyes"] = { 0.398, 0.300, 0.915, 0.355, -3.573, 0.023, "AdmiralWrack_Body" },
		["Lurker_Fins"] = { 3.535, 0.070, 2.293, 1.632, -4.103, 0.025, "AdmiralWrack_Body" },
		["Lurker_Marks"] = { 2.264, 0.190, 1.212, 1.112, -3.938, -0.038, "AdmiralWrack_Body" },
		["MagmaOoze_Body"] = { 2.473, 0.449, 2.200, 1.450, -4.097, 0.023, "AdmiralWrack_Body" },
		["MagmaOoze_Eyes"] = { 0.286, 0.280, 0.855, 0.540, -3.593, 0.023, "AdmiralWrack_Body" },
		["MagmaOoze_Fins"] = { 2.337, 0.761, 1.969, 1.516, -3.488, 0.023, "AdmiralWrack_Body" },
		["MagmaOoze_Marks"] = { 2.311, 1.280, 2.040, 1.464, -3.813, 0.023, "AdmiralWrack_Body" },
		["Mimic_Body"] = { 2.491, 0.500, 2.845, 1.361, -4.023, 0.023, "AdmiralWrack_Body" },
		["Mimic_Eyes"] = { 0.179, 0.200, 0.970, 0.350, -3.693, 0.023, "AdmiralWrack_Body" },
		["Mimic_Fins"] = { 2.532, 0.590, 2.887, 1.361, -3.438, 0.023, "AdmiralWrack_Body" },
		["Mimic_Marks"] = { 1.330, 0.720, 1.773, 0.878, -3.693, 0.023, "AdmiralWrack_Body" },
		["MireLeech_Body"] = { 4.110, 1.293, 1.577, 1.669, -3.746, 0.192, "AdmiralWrack_Body" },
		["MireLeech_Eyes"] = { 0.089, 0.100, 0.685, 0.250, -3.293, 0.023, "AdmiralWrack_Body" },
		["MireLeech_Fins"] = { 3.161, 1.290, 1.440, 1.031, -3.695, 0.246, "AdmiralWrack_Body" },
		["MireLeech_Marks"] = { 1.655, 0.212, 0.394, 1.543, -3.242, 0.315, "AdmiralWrack_Body" },
		["Noctyss_Body"] = { 10.232, 8.130, 4.884, 1.484, -0.328, 0.023, "AdmiralWrack_Body" },
		["Noctyss_Eyes"] = { 1.409, 1.975, 3.540, -1.871, 1.735, 0.023, "AdmiralWrack_Body" },
		["Noctyss_Fins"] = { 16.641, 10.938, 7.126, 0.479, 0.261, 0.023, "AdmiralWrack_Body" },
		["Noctyss_Marks"] = { 12.724, 5.956, 4.725, -1.496, 2.055, 0.023, "AdmiralWrack_Body" },
		["PeatRevenant_Body"] = { 2.380, 4.440, 2.715, 1.030, -2.073, 0.082, "AdmiralWrack_Body" },
		["PeatRevenant_Eyes"] = { 0.179, 0.240, 0.553, 0.740, -0.293, 0.083, "AdmiralWrack_Body" },
		["PeatRevenant_Fins"] = { 3.667, 3.824, 2.940, 0.513, -1.431, 0.083, "AdmiralWrack_Body" },
		["PeatRevenant_Marks"] = { 0.744, 2.160, 0.853, 1.200, -1.033, 0.023, "AdmiralWrack_Body" },
		["PhantomMoray_Body"] = { 6.462, 1.063, 2.650, 1.325, -3.673, 0.070, "AdmiralWrack_Body" },
		["PhantomMoray_Eyes"] = { 0.197, 0.220, 0.753, -1.200, -3.373, 0.023, "AdmiralWrack_Body" },
		["PhantomMoray_Fins"] = { 6.034, 1.274, 0.470, 1.383, -3.256, 0.023, "AdmiralWrack_Body" },
		["PhantomMoray_Marks"] = { 3.547, 1.313, 2.709, 1.511, -3.673, 0.039, "AdmiralWrack_Body" },
		["Phoenix_Body"] = { 4.490, 1.583, 3.014, 0.905, -3.443, 0.029, "AdmiralWrack_Body" },
		["Phoenix_Eyes"] = { 0.161, 0.180, 0.476, -0.840, -2.963, 0.023, "AdmiralWrack_Body" },
		["Phoenix_Fins"] = { 4.100, 0.400, 3.360, 2.600, -3.333, 0.023, "AdmiralWrack_Body" },
		["Phoenix_Marks"] = { 5.315, 1.780, 3.763, 2.107, -3.153, 0.023, "AdmiralWrack_Body" },
		["PlunderSprite_Body"] = { 2.567, 0.940, 1.240, 1.625, -3.603, 0.023, "AdmiralWrack_Body" },
		["PlunderSprite_Eyes"] = { 0.161, 0.200, 0.456, 0.640, -3.493, 0.023, "AdmiralWrack_Body" },
		["PlunderSprite_Fins"] = { 1.400, 0.685, 1.900, 1.820, -3.750, 0.023, "AdmiralWrack_Body" },
		["PlunderSprite_Marks"] = { 3.496, 0.780, 0.990, 1.608, -3.663, 0.038, "AdmiralWrack_Body" },
		["PressureCrab_Body"] = { 2.756, 1.174, 2.751, 1.140, -3.717, 0.021, "AdmiralWrack_Body" },
		["PressureCrab_Eyes"] = { 0.143, 0.160, 0.716, 0.280, -3.093, 0.023, "AdmiralWrack_Body" },
		["PressureCrab_Fins"] = { 2.985, 1.125, 1.950, 0.617, -3.405, 0.023, "AdmiralWrack_Body" },
		["PressureCrab_Marks"] = { 1.189, 0.100, 2.285, 1.400, -3.243, 0.023, "AdmiralWrack_Body" },
		["Pyrelisk_Body"] = { 19.645, 3.489, 4.561, 0.008, -2.660, 0.024, "AdmiralWrack_Body" },
		["Pyrelisk_Eyes"] = { 0.537, 0.440, 2.380, -7.450, -2.173, 0.023, "AdmiralWrack_Body" },
		["Pyrelisk_Fins"] = { 22.350, 3.476, 3.939, 1.725, -1.805, 0.023, "AdmiralWrack_Body" },
		["Pyrelisk_Marks"] = { 21.958, 4.286, 3.936, 1.629, -2.110, 0.006, "AdmiralWrack_Body" },
		["RiggingWraith_Body"] = { 2.960, 3.600, 5.240, 1.920, -2.193, 0.023, "AdmiralWrack_Body" },
		["RiggingWraith_Eyes"] = { 0.250, 0.340, 0.724, 0.800, -1.543, 0.023, "AdmiralWrack_Body" },
		["RiggingWraith_Fins"] = { 1.981, 3.703, 4.351, 1.567, -2.268, 0.026, "AdmiralWrack_Body" },
		["RiggingWraith_Marks"] = { 1.477, 1.921, 1.476, 1.439, -2.144, -0.118, "AdmiralWrack_Body" },
		["Rimefang_Body"] = { 20.936, 2.763, 6.476, -0.332, -2.973, 0.243, "AdmiralWrack_Body" },
		["Rimefang_Eyes"] = { 0.644, 0.520, 2.602, -8.850, -2.173, 0.023, "AdmiralWrack_Body" },
		["Rimefang_Fins"] = { 22.150, 5.036, 4.386, 0.625, -1.883, 0.183, "AdmiralWrack_Body" },
		["Rimefang_Marks"] = { 21.982, 2.462, 5.735, 0.227, -3.019, 0.236, "AdmiralWrack_Body" },
		["RiptideBarracuda_Body"] = { 5.605, 0.960, 0.800, 1.197, -3.673, 0.023, "AdmiralWrack_Body" },
		["RiptideBarracuda_Eyes"] = { 0.197, 0.220, 0.673, -0.750, -3.513, 0.023, "AdmiralWrack_Body" },
		["RiptideBarracuda_Fins"] = { 6.380, 1.500, 1.700, 1.810, -3.543, 0.023, "AdmiralWrack_Body" },
		["RiptideBarracuda_Marks"] = { 3.250, 0.417, 0.810, 1.300, -3.543, 0.023, "AdmiralWrack_Body" },
		["Shardback_Body"] = { 2.701, 0.949, 2.240, 1.500, -3.678, 0.023, "AdmiralWrack_Body" },
		["Shardback_Eyes"] = { 0.197, 0.220, 0.707, 0.690, -3.183, 0.023, "AdmiralWrack_Body" },
		["Shardback_Fins"] = { 2.985, 1.287, 2.822, 0.993, -3.616, 0.018, "AdmiralWrack_Body" },
		["Shardback_Marks"] = { 2.421, 0.677, 1.510, 1.668, -3.554, 0.023, "AdmiralWrack_Body" },
		["SiltStalker_Body"] = { 5.502, 0.666, 1.531, 2.259, -3.826, 0.023, "AdmiralWrack_Body" },
		["SiltStalker_Eyes"] = { 0.161, 0.160, 0.736, -0.300, -3.743, 0.023, "AdmiralWrack_Body" },
		["SiltStalker_Fins"] = { 5.300, 0.752, 2.300, 0.550, -3.817, 0.023, "AdmiralWrack_Body" },
		["SiltStalker_Marks"] = { 2.575, 0.140, 0.119, 1.825, -3.473, 0.023, "AdmiralWrack_Body" },
		["Skipper_Body"] = { 3.042, 1.140, 0.885, 1.229, -3.723, 0.023, "AdmiralWrack_Body" },
		["Skipper_Eyes"] = { 0.340, 0.380, 0.923, 0.150, -3.173, 0.023, "AdmiralWrack_Body" },
		["Skipper_Fins"] = { 3.269, 1.923, 2.166, 1.815, -3.454, 0.018, "AdmiralWrack_Body" },
		["Skipper_Marks"] = { 2.600, 0.370, 0.920, 1.000, -3.928, 0.023, "AdmiralWrack_Body" },
		["SlagGolem_Body"] = { 1.616, 3.340, 2.762, 1.183, -2.623, 0.050, "AdmiralWrack_Body" },
		["SlagGolem_Eyes"] = { 0.179, 0.220, 0.510, 0.800, -1.173, 0.023, "AdmiralWrack_Body" },
		["SlagGolem_Fins"] = { 2.840, 3.020, 2.920, 0.720, -2.143, 0.143, "AdmiralWrack_Body" },
		["SlagGolem_Marks"] = { 2.136, 2.777, 2.248, 0.658, -2.679, -0.053, "AdmiralWrack_Body" },
		["SnagtoothGator_Body"] = { 8.229, 1.192, 2.379, 1.414, -3.729, 0.025, "AdmiralWrack_Body" },
		["SnagtoothGator_Eyes"] = { 0.197, 0.200, 1.010, -0.300, -3.243, 0.023, "AdmiralWrack_Body" },
		["SnagtoothGator_Fins"] = { 4.491, 0.675, 1.125, 2.619, -3.363, 0.061, "AdmiralWrack_Body" },
		["SnagtoothGator_Marks"] = { 1.548, 0.420, 0.719, -1.906, -3.783, 0.013, "AdmiralWrack_Body" },
		["StormcallerDjinn_Body"] = { 2.366, 5.250, 2.643, 1.363, -1.568, 0.023, "AdmiralWrack_Body" },
		["StormcallerDjinn_Eyes"] = { 0.197, 0.260, 0.570, 0.900, 0.607, 0.023, "AdmiralWrack_Body" },
		["StormcallerDjinn_Fins"] = { 3.483, 2.820, 2.789, 0.643, -0.083, 0.023, "AdmiralWrack_Body" },
		["StormcallerDjinn_Marks"] = { 2.136, 4.208, 1.791, -0.259, -1.000, 0.023, "AdmiralWrack_Body" },
		["Stormpetrel_Body"] = { 3.084, 0.920, 0.766, 0.842, -2.953, 0.023, "AdmiralWrack_Body" },
		["Stormpetrel_Eyes"] = { 0.143, 0.160, 0.519, -0.000, -2.693, 0.023, "AdmiralWrack_Body" },
		["Stormpetrel_Fins"] = { 3.000, 0.275, 4.100, 2.400, -2.900, 0.023, "AdmiralWrack_Body" },
		["Stormpetrel_Marks"] = { 1.057, 0.050, 3.763, 2.192, -2.873, 0.023, "AdmiralWrack_Body" },
		["SunkenTrapper_Body"] = { 2.418, 1.640, 2.120, 1.241, -3.473, 0.023, "AdmiralWrack_Body" },
		["SunkenTrapper_Eyes"] = { 0.161, 0.180, 0.936, 0.450, -3.443, 0.023, "AdmiralWrack_Body" },
		["SunkenTrapper_Fins"] = { 1.997, 0.710, 2.100, 1.400, -2.798, 0.023, "AdmiralWrack_Body" },
		["SunkenTrapper_Marks"] = { 2.425, 0.750, 1.776, 1.067, -2.928, -0.070, "AdmiralWrack_Body" },
		["TempestRevenant_Body"] = { 2.960, 4.270, 1.932, 1.210, -2.158, -0.003, "AdmiralWrack_Body" },
		["TempestRevenant_Eyes"] = { 0.161, 0.220, 0.493, 0.540, -0.373, 0.023, "AdmiralWrack_Body" },
		["TempestRevenant_Fins"] = { 3.007, 3.239, 3.170, 2.249, -2.572, -0.692, "AdmiralWrack_Body" },
		["TempestRevenant_Marks"] = { 0.367, 1.466, 1.704, 0.805, -1.658, -0.006, "AdmiralWrack_Body" },
		["ThunderlanceMarlin_Body"] = { 6.800, 1.375, 1.100, 0.400, -3.443, 0.023, "AdmiralWrack_Body" },
		["ThunderlanceMarlin_Eyes"] = { 0.215, 0.240, 0.730, -0.300, -3.243, 0.023, "AdmiralWrack_Body" },
		["ThunderlanceMarlin_Fins"] = { 4.700, 2.100, 2.700, 2.550, -3.193, 0.023, "AdmiralWrack_Body" },
		["ThunderlanceMarlin_Marks"] = { 3.415, 1.202, 1.120, 1.498, -2.851, 0.023, "AdmiralWrack_Body" },
		["TrenchSkitterer_Body"] = { 4.352, 0.769, 1.446, 1.624, -3.817, 0.023, "AdmiralWrack_Body" },
		["TrenchSkitterer_Eyes"] = { 0.179, 0.160, 0.736, -0.450, -3.743, 0.023, "AdmiralWrack_Body" },
		["TrenchSkitterer_Fins"] = { 4.270, 0.747, 2.625, 0.425, -3.927, 0.023, "AdmiralWrack_Body" },
		["TrenchSkitterer_Marks"] = { 2.407, 0.120, 1.542, 1.550, -3.793, 0.023, "AdmiralWrack_Body" },
		["Urchin_Body"] = { 1.902, 1.440, 1.800, 1.400, -3.443, 0.023, "AdmiralWrack_Body" },
		["Urchin_Eyes"] = { 0.179, 0.200, 0.610, 0.450, -3.343, 0.023, "AdmiralWrack_Body" },
		["Urchin_Fins"] = { 3.613, 1.617, 3.288, 1.400, -3.375, 0.023, "AdmiralWrack_Body" },
		["Urchin_Marks"] = { 2.048, 1.273, 1.853, 1.400, -3.616, 0.023, "AdmiralWrack_Body" },
		["VampireSquid_Body"] = { 4.000, 2.152, 2.231, 1.300, -3.443, 0.058, "AdmiralWrack_Body" },
		["VampireSquid_Eyes"] = { 0.429, 0.440, 1.580, 0.650, -3.143, 0.023, "AdmiralWrack_Body" },
		["VampireSquid_Fins"] = { 4.350, 2.367, 2.480, 1.025, -3.443, 0.023, "AdmiralWrack_Body" },
		["VampireSquid_Marks"] = { 0.143, 0.160, 0.736, 2.950, -3.193, 0.023, "AdmiralWrack_Body" },
		["VoidRay_Body"] = { 4.904, 0.640, 1.871, 1.952, -3.743, 0.023, "AdmiralWrack_Body" },
		["VoidRay_Eyes"] = { 0.179, 0.160, 0.936, 0.250, -3.543, 0.023, "AdmiralWrack_Body" },
		["VoidRay_Fins"] = { 2.500, 0.140, 4.000, 1.850, -3.743, 0.023, "AdmiralWrack_Body" },
		["VoidRay_Marks"] = { 2.003, 0.370, 3.900, 1.989, -3.558, 0.023, "AdmiralWrack_Body" },
		["Voltray_Body"] = { 5.802, 0.800, 3.400, 2.801, -3.893, 0.023, "AdmiralWrack_Body" },
		["Voltray_Eyes"] = { 0.197, 0.220, 0.827, 0.280, -3.533, 0.023, "AdmiralWrack_Body" },
		["Voltray_Fins"] = { 6.295, 0.390, 3.502, 3.002, -3.788, 0.023, "AdmiralWrack_Body" },
		["Voltray_Marks"] = { 1.779, 0.310, 2.381, 1.300, -3.578, 0.023, "AdmiralWrack_Body" },
		["WailingGunner_Body"] = { 3.484, 1.802, 2.414, 0.291, -1.614, -0.506, "AdmiralWrack_Body" },
		["WailingGunner_Eyes"] = { 0.161, 0.220, 0.516, 1.260, -0.313, 0.023, "AdmiralWrack_Body" },
		["WailingGunner_Fins"] = { 1.869, 4.240, 1.838, 1.306, -2.093, 0.008, "AdmiralWrack_Body" },
		["WailingGunner_Marks"] = { 3.979, 1.773, 2.656, 0.549, -0.910, -0.301, "AdmiralWrack_Body" },
		["WhirlpoolHorror_Body"] = { 3.500, 2.058, 2.134, 1.850, -3.193, 0.056, "AdmiralWrack_Body" },
		["WhirlpoolHorror_Eyes"] = { 0.394, 0.400, 0.340, 1.300, -3.193, 0.023, "AdmiralWrack_Body" },
		["WhirlpoolHorror_Fins"] = { 4.626, 2.222, 2.265, 1.205, -3.211, 0.014, "AdmiralWrack_Body" },
		["WhirlpoolHorror_Marks"] = { 1.050, 1.700, 1.700, 0.975, -3.193, 0.023, "AdmiralWrack_Body" },
		["WillOWisp_Body"] = { 1.372, 1.653, 1.427, 1.336, -2.219, 0.023, "AdmiralWrack_Body" },
		["WillOWisp_Eyes"] = { 0.179, 0.260, 0.513, 0.980, -2.443, 0.023, "AdmiralWrack_Body" },
		["WillOWisp_Fins"] = { 1.492, 1.109, 1.315, 1.390, -3.596, -0.178, "AdmiralWrack_Body" },
		["WillOWisp_Marks"] = { 0.984, 1.200, 0.936, 1.400, -2.593, 0.023, "AdmiralWrack_Body" },
	},
	FishPack = {
		["Ashgill_Body"] = { 0.168, 0.264, 2.000, 0.000, 0.000, 0.000, "Ashgill_Body" },
		["Ashgill_Eyes"] = { 0.117, 0.078, 0.090, 0.000, 0.027, -0.760, "Ashgill_Body" },
		["Ashgill_Fins"] = { 0.364, 0.640, 1.840, 0.000, 0.000, 0.560, "Ashgill_Body" },
		["Ashgill_Marks"] = { 0.220, 0.347, 1.460, 0.000, 0.000, 0.030, "Ashgill_Body" },
		["AurorafinMarlin_Body"] = { 0.324, 0.536, 2.600, 0.008, 0.000, -35.500, "Ashgill_Body" },
		["AurorafinMarlin_Eyes"] = { 0.208, 0.087, 0.100, 0.000, 0.046, -35.920, "Ashgill_Body" },
		["AurorafinMarlin_Fins"] = { 0.668, 1.140, 2.000, 0.000, 0.090, -34.680, "Ashgill_Body" },
		["AurorafinMarlin_Marks"] = { 0.385, 0.060, 1.520, 0.000, 0.000, -35.200, "Ashgill_Body" },
		["BarnacleBlenny_Body"] = { 0.240, 0.293, 2.000, 0.000, 0.000, -51.200, "Ashgill_Body" },
		["BarnacleBlenny_Eyes"] = { 0.272, 0.087, 0.100, 0.000, 0.048, -51.920, "Ashgill_Body" },
		["BarnacleBlenny_Fins"] = { 0.509, 0.550, 2.000, 0.000, 0.047, -50.920, "Ashgill_Body" },
		["BarnacleBlenny_Marks"] = { 0.299, 0.236, 1.320, 0.000, 0.000, -51.200, "Ashgill_Body" },
		["BasaltCod_Body"] = { 0.331, 0.463, 2.000, 0.000, 0.000, -12.800, "Ashgill_Body" },
		["BasaltCod_Eyes"] = { 0.261, 0.087, 0.100, 0.000, 0.058, -13.540, "Ashgill_Body" },
		["BasaltCod_Fins"] = { 0.559, 0.864, 1.960, 0.000, 0.062, -12.460, "Ashgill_Body" },
		["BasaltCod_Marks"] = { 0.390, 0.145, 1.420, 0.000, 0.094, -12.840, "Ashgill_Body" },
		["Bass_Body"] = { 0.370, 0.616, 2.000, 0.000, 0.000, 16.000, "Ashgill_Body" },
		["Bass_Eyes"] = { 0.235, 0.095, 0.110, 0.000, 0.062, 15.280, "Ashgill_Body" },
		["Bass_Fins"] = { 0.606, 0.965, 1.760, 0.000, 0.067, 16.480, "Ashgill_Body" },
		["Bass_Marks"] = { 0.416, 0.079, 1.640, 0.000, 0.000, 16.020, "Ashgill_Body" },
		["BlindcaveSardine_Body"] = { 0.153, 0.264, 2.000, 0.000, 0.000, -41.600, "Ashgill_Body" },
		["BlindcaveSardine_Eyes"] = { 0.109, 0.035, 0.040, 0.000, 0.027, -42.360, "Ashgill_Body" },
		["BlindcaveSardine_Fins"] = { 0.352, 0.560, 1.760, 0.000, 0.000, -41.080, "Ashgill_Body" },
		["BlindcaveSardine_Marks"] = { 0.196, 0.021, 1.440, 0.000, 0.000, -41.600, "Ashgill_Body" },
		["Catfish_Body"] = { 1.096, 0.437, 2.000, 0.000, -0.020, 9.600, "Ashgill_Body" },
		["Catfish_Eyes"] = { 0.320, 0.061, 0.070, 0.000, 0.047, 8.840, "Ashgill_Body" },
		["Catfish_Fins"] = { 0.619, 0.733, 1.740, 0.000, 0.051, 10.070, "Ashgill_Body" },
		["Cod_Body"] = { 0.300, 0.442, 2.000, 0.000, -0.005, 12.800, "Ashgill_Body" },
		["Cod_Eyes"] = { 0.243, 0.087, 0.100, 0.000, 0.056, 12.060, "Ashgill_Body" },
		["Cod_Fins"] = { 0.533, 0.756, 1.920, 0.000, 0.036, 13.160, "Ashgill_Body" },
		["Cod_Marks"] = { 0.342, 0.050, 1.600, 0.000, 0.045, 12.800, "Ashgill_Body" },
		["Emberfin_Body"] = { 0.354, 0.639, 2.000, 0.000, 0.000, -6.400, "Ashgill_Body" },
		["Emberfin_Eyes"] = { 0.166, 0.087, 0.100, 0.000, 0.046, -7.140, "Ashgill_Body" },
		["Emberfin_Fins"] = { 0.504, 1.324, 1.800, 0.000, 0.105, -5.940, "Ashgill_Body" },
		["Emberfin_Marks"] = { 0.408, 0.637, 1.460, 0.000, 0.000, -6.420, "Ashgill_Body" },
		["FoamchaserMullet_Body"] = { 0.249, 0.360, 2.000, 0.000, 0.000, -73.600, "Ashgill_Body" },
		["FoamchaserMullet_Eyes"] = { 0.185, 0.087, 0.100, 0.000, 0.041, -74.340, "Ashgill_Body" },
		["FoamchaserMullet_Fins"] = { 0.480, 0.613, 1.680, 0.000, 0.027, -73.120, "Ashgill_Body" },
		["FoamchaserMullet_Marks"] = { 0.293, 0.033, 1.520, 0.000, 0.000, -73.600, "Ashgill_Body" },
		["FrostfinChar_Body"] = { 0.267, 0.421, 2.000, 0.000, 0.000, -28.800, "Ashgill_Body" },
		["FrostfinChar_Eyes"] = { 0.176, 0.087, 0.100, 0.000, 0.042, -29.540, "Ashgill_Body" },
		["FrostfinChar_Fins"] = { 0.493, 0.708, 1.700, 0.000, 0.054, -28.310, "Ashgill_Body" },
		["FrostfinChar_Marks"] = { 0.311, 0.068, 1.600, 0.000, 0.000, -28.800, "Ashgill_Body" },
		["GhostCarp_Body"] = { 0.998, 0.520, 2.000, 0.000, 0.000, -60.800, "Ashgill_Body" },
		["GhostCarp_Eyes"] = { 0.206, 0.087, 0.100, 0.000, 0.048, -61.540, "Ashgill_Body" },
		["GhostCarp_Fins"] = { 0.555, 0.824, 1.740, 0.000, 0.092, -60.290, "Ashgill_Body" },
		["GhostCarp_Marks"] = { 0.392, 0.060, 1.600, 0.000, 0.000, -60.800, "Ashgill_Body" },
		["GhostlightOarfish_Body"] = { 0.077, 0.222, 2.000, 0.000, 0.000, -48.000, "Ashgill_Body" },
		["GhostlightOarfish_Eyes"] = { 0.080, 0.087, 0.100, 0.000, 0.030, -48.760, "Ashgill_Body" },
		["GhostlightOarfish_Fins"] = { 0.238, 0.690, 2.100, 0.000, 0.205, -47.830, "Ashgill_Body" },
		["GhostlightOarfish_Marks"] = { 0.121, 0.018, 1.680, 0.000, 0.000, -48.000, "Ashgill_Body" },
		["IcemeltSmelt_Body"] = { 0.137, 0.229, 2.000, 0.000, 0.000, -22.400, "Ashgill_Body" },
		["IcemeltSmelt_Eyes"] = { 0.103, 0.078, 0.090, 0.000, 0.024, -23.160, "Ashgill_Body" },
		["IcemeltSmelt_Fins"] = { 0.343, 0.520, 1.740, 0.000, 0.000, -21.890, "Ashgill_Body" },
		["IcemeltSmelt_Marks"] = { 0.183, 0.027, 1.560, 0.000, 0.000, -22.420, "Ashgill_Body" },
		["Mackerel_Body"] = { 0.229, 0.320, 2.000, 0.000, 0.000, 25.600, "Ashgill_Body" },
		["Mackerel_Eyes"] = { 0.151, 0.078, 0.090, 0.000, 0.032, 24.840, "Ashgill_Body" },
		["Mackerel_Fins"] = { 0.427, 0.600, 1.800, 0.000, 0.000, 26.100, "Ashgill_Body" },
		["Mackerel_Marks"] = { 0.275, 0.382, 1.380, 0.000, 0.000, 25.670, "Ashgill_Body" },
		["MagmaGuppy_Body"] = { 0.265, 0.441, 2.000, 0.000, 0.000, -3.200, "Ashgill_Body" },
		["MagmaGuppy_Eyes"] = { 0.159, 0.095, 0.110, 0.000, 0.040, -3.920, "Ashgill_Body" },
		["MagmaGuppy_Fins"] = { 0.565, 1.147, 1.880, 0.000, 0.053, -2.620, "Ashgill_Body" },
		["MagmaGuppy_Marks"] = { 0.309, 0.092, 1.680, 0.000, 0.000, -3.200, "Ashgill_Body" },
		["MagmafinTuna_Body"] = { 0.533, 0.620, 2.000, 0.000, 0.000, -19.200, "Ashgill_Body" },
		["MagmafinTuna_Eyes"] = { 0.288, 0.087, 0.100, 0.000, 0.047, -19.960, "Ashgill_Body" },
		["MagmafinTuna_Fins"] = { 0.906, 1.148, 1.940, 0.000, 0.074, -18.630, "Ashgill_Body" },
		["MagmafinTuna_Marks"] = { 0.577, 0.603, 1.600, 0.000, 0.000, -19.200, "Ashgill_Body" },
		["ObsidianBass_Body"] = { 0.307, 0.701, 2.000, 0.016, 0.000, -9.600, "Ashgill_Body" },
		["ObsidianBass_Eyes"] = { 0.204, 0.087, 0.100, 0.000, 0.060, -10.320, "Ashgill_Body" },
		["ObsidianBass_Fins"] = { 0.554, 1.241, 1.880, 0.000, 0.084, -9.180, "Ashgill_Body" },
		["ObsidianBass_Marks"] = { 0.392, 0.673, 1.500, 0.000, 0.000, -9.620, "Ashgill_Body" },
		["PaleDace_Body"] = { 0.169, 0.281, 2.000, 0.000, 0.000, -38.400, "Ashgill_Body" },
		["PaleDace_Eyes"] = { 0.128, 0.087, 0.100, 0.000, 0.031, -39.140, "Ashgill_Body" },
		["PaleDace_Fins"] = { 0.386, 0.560, 1.700, 0.000, 0.020, -37.910, "Ashgill_Body" },
		["PaleDace_Marks"] = { 0.213, 0.029, 1.520, 0.000, 0.000, -38.400, "Ashgill_Body" },
		["Perch_Body"] = { 0.340, 0.589, 2.000, 0.000, 0.000, 28.800, "Ashgill_Body" },
		["Perch_Eyes"] = { 0.180, 0.087, 0.100, 0.000, 0.048, 28.060, "Ashgill_Body" },
		["Perch_Fins"] = { 0.526, 0.924, 1.700, 0.000, 0.087, 29.290, "Ashgill_Body" },
		["Perch_Marks"] = { 0.382, 0.478, 1.380, 0.000, 0.000, 28.760, "Ashgill_Body" },
		["Puffer_Body"] = { 1.252, 1.160, 1.701, 0.000, 0.000, 19.200, "Ashgill_Body" },
		["Puffer_Eyes"] = { 1.042, 0.346, 0.400, 0.000, 0.300, 18.680, "Ashgill_Body" },
		["Puffer_Fins"] = { 1.740, 1.131, 1.950, 0.000, 0.000, 19.525, "Ashgill_Body" },
		["Puffer_Marks"] = { 0.240, 0.180, 0.160, 0.000, 0.000, 18.230, "Ashgill_Body" },
		["PyreSalmon_Body"] = { 0.308, 0.485, 2.120, 0.000, 0.000, -16.060, "Ashgill_Body" },
		["PyreSalmon_Eyes"] = { 0.201, 0.087, 0.100, 0.000, 0.050, -16.760, "Ashgill_Body" },
		["PyreSalmon_Fins"] = { 0.564, 0.889, 1.840, 0.000, 0.084, -15.440, "Ashgill_Body" },
		["PyreSalmon_Marks"] = { 0.352, 0.106, 1.680, 0.000, 0.000, -16.000, "Ashgill_Body" },
		["RainfinMackerel_Body"] = { 0.229, 0.320, 2.000, 0.000, 0.000, -70.400, "Ashgill_Body" },
		["RainfinMackerel_Eyes"] = { 0.151, 0.078, 0.090, 0.000, 0.032, -71.160, "Ashgill_Body" },
		["RainfinMackerel_Fins"] = { 0.427, 0.600, 1.820, 0.000, 0.000, -69.890, "Ashgill_Body" },
		["RainfinMackerel_Marks"] = { 0.277, 0.382, 1.416, 0.000, 0.000, -70.348, "Ashgill_Body" },
		["RimeHerring_Body"] = { 0.187, 0.338, 2.000, 0.000, 0.000, -32.000, "Ashgill_Body" },
		["RimeHerring_Eyes"] = { 0.121, 0.087, 0.100, 0.000, 0.032, -32.760, "Ashgill_Body" },
		["RimeHerring_Fins"] = { 0.392, 0.660, 1.820, 0.000, 0.010, -31.450, "Ashgill_Body" },
		["RimeHerring_Marks"] = { 0.234, 0.032, 1.640, 0.000, 0.000, -32.020, "Ashgill_Body" },
		["RustscaleSnapper_Body"] = { 0.333, 0.577, 2.000, 0.000, 0.000, -57.600, "Ashgill_Body" },
		["RustscaleSnapper_Eyes"] = { 0.205, 0.095, 0.110, 0.000, 0.056, -58.320, "Ashgill_Body" },
		["RustscaleSnapper_Fins"] = { 0.538, 0.912, 1.760, 0.000, 0.071, -57.120, "Ashgill_Body" },
		["RustscaleSnapper_Marks"] = { 0.383, 0.528, 1.340, 0.000, 0.000, -57.620, "Ashgill_Body" },
		["Salmon_Body"] = { 0.308, 0.485, 2.120, 0.000, 0.000, 6.340, "Ashgill_Body" },
		["Salmon_Eyes"] = { 0.201, 0.087, 0.100, 0.000, 0.050, 5.640, "Ashgill_Body" },
		["Salmon_Fins"] = { 0.564, 0.791, 1.760, 0.000, 0.056, 6.920, "Ashgill_Body" },
		["Salmon_Marks"] = { 0.352, 0.073, 1.520, 0.000, 0.000, 6.400, "Ashgill_Body" },
		["SnowdriftSculpin_Body"] = { 0.317, 0.343, 2.000, 0.000, 0.000, -25.600, "Ashgill_Body" },
		["SnowdriftSculpin_Eyes"] = { 0.320, 0.078, 0.090, 0.000, 0.052, -26.320, "Ashgill_Body" },
		["SnowdriftSculpin_Fins"] = { 0.675, 0.643, 1.740, 0.000, 0.073, -25.170, "Ashgill_Body" },
		["SnowdriftSculpin_Marks"] = { 0.383, 0.339, 1.320, 0.000, 0.000, -25.620, "Ashgill_Body" },
		["SootgillHagfish_Body"] = { 1.005, 0.294, 2.000, 0.000, -0.053, -44.800, "Ashgill_Body" },
		["SootgillHagfish_Eyes"] = { 0.137, 0.043, 0.050, 0.000, 0.027, -45.600, "Ashgill_Body" },
		["SootgillHagfish_Fins"] = { 0.252, 0.324, 1.620, 0.000, 0.002, -44.350, "Ashgill_Body" },
		["SootgillHagfish_Marks"] = { 0.200, 0.117, 0.460, 0.000, 0.000, -45.380, "Ashgill_Body" },
		["SpectralSailfish_Body"] = { 0.267, 0.498, 2.600, 0.007, 0.000, -64.300, "Ashgill_Body" },
		["SpectralSailfish_Eyes"] = { 0.179, 0.087, 0.100, 0.000, 0.043, -64.720, "Ashgill_Body" },
		["SpectralSailfish_Fins"] = { 0.606, 1.198, 2.060, 0.000, 0.139, -63.530, "Ashgill_Body" },
		["SpectralSailfish_Marks"] = { 0.329, 0.342, 1.160, 0.000, 0.000, -64.000, "Ashgill_Body" },
		["SquallSprat_Body"] = { 0.127, 0.229, 2.000, 0.000, 0.000, -67.200, "Ashgill_Body" },
		["SquallSprat_Eyes"] = { 0.097, 0.078, 0.090, 0.000, 0.024, -67.960, "Ashgill_Body" },
		["SquallSprat_Fins"] = { 0.315, 0.520, 1.760, 0.000, 0.000, -66.680, "Ashgill_Body" },
		["SquallSprat_Marks"] = { 0.172, 0.019, 1.480, 0.000, 0.000, -67.220, "Ashgill_Body" },
		["StormkingTuna_Body"] = { 0.563, 0.640, 2.000, 0.000, 0.000, -76.800, "Ashgill_Body" },
		["StormkingTuna_Eyes"] = { 0.305, 0.087, 0.100, 0.000, 0.049, -77.560, "Ashgill_Body" },
		["StormkingTuna_Fins"] = { 0.951, 1.198, 1.960, 0.000, 0.079, -76.220, "Ashgill_Body" },
		["StormkingTuna_Marks"] = { 0.607, 0.617, 1.600, 0.000, 0.000, -76.800, "Ashgill_Body" },
		["Trout_Body"] = { 0.257, 0.405, 2.000, 0.000, 0.000, 22.400, "Ashgill_Body" },
		["Trout_Eyes"] = { 0.176, 0.087, 0.100, 0.000, 0.042, 21.660, "Ashgill_Body" },
		["Trout_Fins"] = { 0.487, 0.695, 1.700, 0.000, 0.047, 22.890, "Ashgill_Body" },
		["Trout_Marks"] = { 0.305, 0.071, 1.640, 0.000, 0.000, 22.380, "Ashgill_Body" },
		["Tuna_Body"] = { 0.510, 0.600, 2.000, 0.000, 0.000, 3.200, "Ashgill_Body" },
		["Tuna_Eyes"] = { 0.285, 0.087, 0.100, 0.000, 0.047, 2.440, "Ashgill_Body" },
		["Tuna_Fins"] = { 0.835, 0.988, 1.820, 0.000, 0.054, 3.750, "Ashgill_Body" },
		["Tuna_Marks"] = { 0.030, 0.541, 0.530, 0.000, 0.000, 3.735, "Ashgill_Body" },
		["WreckHerring_Body"] = { 0.186, 0.322, 2.000, 0.000, 0.000, -54.400, "Ashgill_Body" },
		["WreckHerring_Eyes"] = { 0.126, 0.087, 0.100, 0.000, 0.032, -55.160, "Ashgill_Body" },
		["WreckHerring_Fins"] = { 0.393, 0.616, 1.780, 0.000, 0.008, -53.870, "Ashgill_Body" },
		["WreckHerring_Marks"] = { 0.229, 0.386, 1.420, 0.000, 0.000, -54.350, "Ashgill_Body" },
	},
	GnashrootArena = {
		["GnashrootArena_Base"] = { 177.168, 11.705, 173.406, 0.000, 0.000, 0.000, "GnashrootArena_Base" },
		["GnashrootArena_DecoCanopy"] = { 203.252, 40.261, 201.250, -1.412, 34.364, -3.283, "GnashrootArena_Base" },
		["GnashrootArena_DecoLily"] = { 46.072, 0.100, 53.662, -3.082, 3.738, 0.229, "GnashrootArena_Base" },
		["GnashrootArena_DecoMere"] = { 54.269, 0.400, 54.049, -0.978, 3.448, -1.407, "GnashrootArena_Base" },
		["GnashrootArena_DecoMoss"] = { 187.352, 40.836, 187.123, -0.878, 30.328, -4.083, "GnashrootArena_Base" },
		["GnashrootArena_DecoReedHeads"] = { 140.244, 4.789, 140.515, 1.083, 8.094, 0.781, "GnashrootArena_Base" },
		["GnashrootArena_DecoReeds"] = { 140.476, 8.400, 141.452, 0.770, 6.040, 1.460, "GnashrootArena_Base" },
		["GnashrootArena_DecoShallows"] = { 70.827, 3.057, 70.259, -0.186, 3.841, -0.734, "GnashrootArena_Base" },
		["GnashrootArena_DecoVines"] = { 183.784, 41.909, 180.620, -2.408, 30.156, -0.768, "GnashrootArena_Base" },
		["GnashrootArena_DecoWisps"] = { 111.642, 5.416, 109.815, -2.995, 6.892, -2.840, "GnashrootArena_Base" },
		["GnashrootArena_Foam"] = { 175.691, 0.060, 177.436, -0.789, 3.898, -0.739, "GnashrootArena_Base" },
		["GnashrootArena_Grove"] = { 188.722, 55.441, 189.730, -1.054, 23.400, -3.636, "GnashrootArena_Base" },
		["GnashrootArena_Stump1"] = { 27.677, 8.635, 28.390, 28.371, 7.179, -29.973, "GnashrootArena_Base" },
		["GnashrootArena_Stump2"] = { 27.414, 8.670, 28.133, -29.566, 7.197, -29.844, "GnashrootArena_Base" },
		["GnashrootArena_Stump3"] = { 27.969, 8.684, 26.770, -29.843, 7.204, 27.998, "GnashrootArena_Base" },
		["GnashrootArena_Stump4"] = { 27.046, 8.596, 27.265, 28.056, 7.160, 28.246, "GnashrootArena_Base" },
	},
	GnashrootPack = {
		["Gnashroot_Arm"] = { 3.800, 6.760, 6.760, 0.000, 0.000, 0.000, "Gnashroot_Arm" },
		["Gnashroot_ArmKnot"] = { 4.565, 7.430, 7.800, 0.000, -0.335, 0.000, "Gnashroot_Arm" },
		["Gnashroot_Core"] = { 4.375, 4.600, 5.000, 8.200, 16.200, 0.000, "Gnashroot_Arm" },
		["Gnashroot_Drips"] = { 5.012, 19.698, 19.159, 3.833, 18.326, -0.012, "Gnashroot_Arm" },
		["Gnashroot_Eye"] = { 1.902, 1.840, 2.000, 0.000, 0.000, 0.000, "Gnashroot_Arm" },
		["Gnashroot_Fangs"] = { 10.109, 2.210, 5.150, 9.050, 22.580, 0.000, "Gnashroot_Arm" },
		["Gnashroot_Hand"] = { 8.793, 7.271, 10.928, -1.796, -0.236, -0.828, "Gnashroot_Arm" },
		["Gnashroot_Head"] = { 16.500, 7.648, 13.070, 6.850, 28.424, 0.000, "Gnashroot_Arm" },
		["Gnashroot_Jaw"] = { 15.060, 5.488, 10.367, 8.470, 21.656, 0.000, "Gnashroot_Arm" },
		["Gnashroot_Mass"] = { 19.935, 26.800, 23.455, -0.378, 13.400, 0.000, "Gnashroot_Arm" },
		["Gnashroot_Maw"] = { 12.700, 2.600, 8.600, 8.350, 23.200, 0.000, "Gnashroot_Arm" },
		["Gnashroot_Roots"] = { 47.078, 10.863, 40.202, 0.074, 5.432, 0.499, "Gnashroot_Arm" },
		["Gnashroot_Stones"] = { 8.162, 13.700, 15.059, -5.280, 16.950, 0.364, "Gnashroot_Arm" },
		["Gnashroot_Teeth"] = { 10.185, 2.441, 5.982, 8.150, 23.616, 0.000, "Gnashroot_Arm" },
	},
	IslandPack = {
		["Anchorage_Base"] = { 173.232, 10.019, 204.234, 0.000, 0.000, 0.000, "Anchorage_Base" },
		["Anchorage_Chain"] = { 209.506, 34.440, 149.614, -44.507, 12.697, -14.163, "Anchorage_Base" },
		["Anchorage_Iron"] = { 107.255, 33.871, 106.846, -5.774, 16.471, 3.269, "Anchorage_Base" },
		["Anchorage_Sand"] = { 113.001, 6.207, 120.836, 2.505, 4.678, -2.310, "Anchorage_Base" },
		["Anchorage_Shack"] = { 77.123, 38.649, 74.311, 17.556, 19.795, 39.225, "Anchorage_Base" },
		["Anchorage_Shallows"] = { 152.555, 7.412, 129.707, -8.630, 1.172, 11.434, "Anchorage_Base" },
		["Bellbuoy_Base"] = { 101.266, 6.862, 80.091, 0.000, 0.000, 0.000, "Bellbuoy_Base" },
		["Bellbuoy_Bell"] = { 4.602, 13.640, 4.720, -10.716, 13.689, 2.911, "Bellbuoy_Base" },
		["Bellbuoy_Crust"] = { 60.995, 2.858, 39.130, -2.827, 6.316, -0.284, "Bellbuoy_Base" },
		["Bellbuoy_Dinghy"] = { 14.418, 6.350, 4.809, 14.491, 10.744, 1.361, "Bellbuoy_Base" },
		["Bellbuoy_Gantry"] = { 36.360, 17.231, 10.800, 3.064, 18.104, 2.911, "Bellbuoy_Base" },
		["Bellbuoy_Kelp"] = { 48.964, 6.528, 45.203, 8.185, 5.717, -1.105, "Bellbuoy_Base" },
		["Bellbuoy_Lamp"] = { 0.480, 0.780, 0.480, 20.884, 10.899, -0.289, "Bellbuoy_Base" },
		["Bellbuoy_Pools"] = { 22.852, 3.370, 26.560, 8.938, 10.000, -0.431, "Bellbuoy_Base" },
		["Bellbuoy_Salvage"] = { 29.841, 6.531, 30.999, 9.172, 8.799, -0.545, "Bellbuoy_Base" },
		["Bellbuoy_Tally"] = { 5.600, 2.420, 7.100, 1.124, 8.819, 2.911, "Bellbuoy_Base" },
		["Bellbuoy_Wedge"] = { 63.351, 26.835, 38.323, -1.391, 10.387, -0.927, "Bellbuoy_Base" },
		["Boilshoal_Apron"] = { 44.104, 10.276, 46.565, -18.250, 3.238, -29.438, "Boilshoal_Base" },
		["Boilshoal_Base"] = { 173.180, 11.400, 157.672, 0.000, 0.000, 0.000, "Boilshoal_Base" },
		["Boilshoal_Glow"] = { 95.064, 12.705, 100.169, 1.310, 9.708, -1.880, "Boilshoal_Base" },
		["Boilshoal_Hut"] = { 25.235, 10.600, 25.818, -22.573, 12.000, -36.133, "Boilshoal_Base" },
		["Boilshoal_Lagoon"] = { 117.792, 1.700, 114.214, 1.831, 3.500, -0.004, "Boilshoal_Base" },
		["Boilshoal_Rim"] = { 139.019, 29.256, 130.154, 2.779, 9.328, -2.987, "Boilshoal_Base" },
		["Boilshoal_Smalls"] = { 123.032, 10.990, 117.346, -0.743, 3.585, -2.190, "Boilshoal_Base" },
		["Boilshoal_Steam"] = { 96.351, 21.721, 105.115, 1.229, 16.092, -2.040, "Boilshoal_Base" },
		["Boilshoal_Terraces"] = { 74.384, 13.055, 65.329, -0.524, 6.552, 6.538, "Boilshoal_Base" },
		["Boilshoal_Vents"] = { 100.749, 13.215, 104.735, 1.776, 8.603, -1.753, "Boilshoal_Base" },
		["Chapel_Base"] = { 157.265, 7.500, 142.060, 0.000, 0.000, 0.000, "Chapel_Base" },
		["Chapel_Bell"] = { 10.344, 23.370, 7.710, -5.177, 25.935, -4.293, "Chapel_Base" },
		["Chapel_Glow"] = { 31.881, 1.379, 19.133, -6.718, 8.086, 16.219, "Chapel_Base" },
		["Chapel_Hut"] = { 13.595, 6.219, 13.616, 1.292, 8.509, 11.295, "Chapel_Base" },
		["Chapel_Nave"] = { 36.950, 12.347, 20.600, 17.044, 2.473, -4.098, "Chapel_Base" },
		["Chapel_Roof"] = { 35.153, 11.120, 19.080, 16.608, 6.876, -4.058, "Chapel_Base" },
		["Chapel_Stone"] = { 38.830, 42.300, 29.800, 7.184, 22.000, -1.998, "Chapel_Base" },
		["Chapel_Weed"] = { 60.974, 35.164, 53.186, -0.250, 20.162, 5.563, "Chapel_Base" },
		["Chapel_Yard"] = { 68.997, 11.125, 57.513, -0.653, 7.062, 5.576, "Chapel_Base" },
		["Dock_Planks"] = { 18.412, 1.029, 52.008, 5.219, 2.115, 106.521, "Island_Base" },
		["Dock_Posts"] = { 18.260, 10.100, 51.405, 5.222, -0.750, 106.725, "Island_Base" },
		["Ferryraft_Barge"] = { 20.680, 5.150, 22.632, 17.005, 5.475, 10.514, "Ferryraft_Base" },
		["Ferryraft_Barrels"] = { 17.729, 5.250, 15.702, 12.947, 6.475, -16.096, "Ferryraft_Base" },
		["Ferryraft_Base"] = { 157.080, 7.600, 129.623, 0.000, 0.000, 0.000, "Ferryraft_Base" },
		["Ferryraft_Bow"] = { 17.692, 10.959, 40.290, -11.014, 7.580, 12.099, "Ferryraft_Base" },
		["Ferryraft_Bridges"] = { 41.367, 5.200, 29.677, -5.175, 8.700, 2.664, "Ferryraft_Base" },
		["Ferryraft_Cabin"] = { 14.600, 13.391, 17.800, -11.992, 13.205, -3.796, "Ferryraft_Base" },
		["Ferryraft_Cargo"] = { 42.929, 5.698, 43.336, 3.574, 9.999, -1.012, "Ferryraft_Base" },
		["Ferryraft_Chain"] = { 2.880, 13.418, 3.817, -10.732, 3.366, 21.773, "Ferryraft_Base" },
		["Ferryraft_Fenders"] = { 64.351, 4.850, 50.464, -5.645, 7.875, 1.036, "Ferryraft_Base" },
		["Ferryraft_Fish"] = { 56.900, 4.877, 41.600, -7.242, 10.788, 0.004, "Ferryraft_Base" },
		["Ferryraft_Gear"] = { 58.477, 7.470, 45.763, 1.169, 8.585, 0.486, "Ferryraft_Base" },
		["Ferryraft_Glow"] = { 50.391, 15.607, 36.871, -3.540, 17.145, 3.129, "Ferryraft_Base" },
		["Ferryraft_Logs"] = { 15.099, 2.983, 16.000, -29.585, 5.059, 18.054, "Ferryraft_Base" },
		["Ferryraft_Rig"] = { 64.915, 23.850, 54.008, -3.220, 16.475, 4.558, "Ferryraft_Base" },
		["Frostmaw_Arch"] = { 222.839, 77.598, 252.146, -30.888, 27.092, -17.276, "Frostmaw_Base" },
		["Frostmaw_Base"] = { 637.997, 56.812, 611.547, 0.000, 0.000, 0.000, "Frostmaw_Base" },
		["Frostmaw_Berg"] = { 164.103, 101.883, 61.579, -7.304, 43.026, -45.201, "Frostmaw_Base" },
		["Frostmaw_Crystals"] = { 420.283, 39.859, 348.825, -4.264, -0.081, -42.989, "Frostmaw_Base" },
		["Frostmaw_DeadTrees"] = { 408.322, 71.093, 321.707, 6.963, 17.553, -37.504, "Frostmaw_Base" },
		["Frostmaw_Dock_Planks"] = { 20.347, 1.026, 46.000, -7.746, -14.073, 212.995, "Frostmaw_Base" },
		["Frostmaw_Dock_Posts"] = { 20.260, 13.520, 45.405, -7.731, -18.646, 213.195, "Frostmaw_Base" },
		["Frostmaw_Foam"] = { 518.282, 0.100, 496.309, -1.610, -19.296, -0.970, "Frostmaw_Base" },
		["Frostmaw_Hut_Glow"] = { 24.552, 17.785, 6.475, 22.853, -3.347, 166.795, "Frostmaw_Base" },
		["Frostmaw_Hut_Props"] = { 27.059, 19.651, 24.691, 22.235, -4.230, 169.418, "Frostmaw_Base" },
		["Frostmaw_Hut_Roof"] = { 32.119, 12.812, 20.591, 29.421, -4.983, 165.369, "Frostmaw_Base" },
		["Frostmaw_Hut_Trim"] = { 13.691, 8.877, 24.159, 19.283, -9.414, 169.762, "Frostmaw_Base" },
		["Frostmaw_Hut_Walls"] = { 45.070, 9.679, 39.034, 28.353, -9.690, 163.568, "Frostmaw_Base" },
		["Frostmaw_IceHoles"] = { 346.099, 33.778, 371.813, 32.309, -1.471, 23.088, "Frostmaw_Base" },
		["Frostmaw_PineSnow"] = { 415.482, 71.557, 250.992, 6.084, 25.481, 3.015, "Frostmaw_Base" },
		["Frostmaw_Pines"] = { 418.731, 64.166, 254.141, 6.704, 20.854, 2.947, "Frostmaw_Base" },
		["Frostmaw_ShardLitter"] = { 461.699, 43.786, 452.165, 2.959, 1.462, -8.795, "Frostmaw_Base" },
		["Frostmaw_SnowCaps"] = { 515.307, 107.808, 454.057, -1.947, 41.214, -20.075, "Frostmaw_Base" },
		["Frostmaw_SnowMounds"] = { 446.821, 43.452, 410.796, -3.786, 3.182, -19.024, "Frostmaw_Base" },
		["Frostmaw_Terraces"] = { 361.664, 42.118, 342.640, -20.382, 4.419, 12.972, "Frostmaw_Base" },
		["Frostmaw_Walls"] = { 525.369, 53.633, 462.508, 0.089, 1.164, -18.360, "Frostmaw_Base" },
		["Gloomtrench_Base"] = { 600.281, 43.267, 520.816, 0.000, 0.000, 0.000, "Gloomtrench_Base" },
		["Gloomtrench_DarkWater"] = { 94.618, 4.600, 85.206, 1.422, -7.058, -5.342, "Gloomtrench_Base" },
		["Gloomtrench_Dock_Planks"] = { 20.379, 1.029, 44.000, -0.605, -3.193, 191.102, "Gloomtrench_Base" },
		["Gloomtrench_Dock_Posts"] = { 20.260, 10.100, 43.405, -0.577, -6.058, 191.302, "Gloomtrench_Base" },
		["Gloomtrench_Foam"] = { 482.629, 0.100, 425.160, 0.248, -4.998, 0.712, "Gloomtrench_Base" },
		["Gloomtrench_GlowCyan"] = { 513.102, 99.591, 448.402, -7.088, 29.911, 0.251, "Gloomtrench_Base" },
		["Gloomtrench_GlowViolet"] = { 518.362, 91.205, 426.778, -4.553, 33.934, -7.132, "Gloomtrench_Base" },
		["Gloomtrench_Hut_Glow"] = { 17.586, 28.296, 17.208, -23.416, 15.490, 156.488, "Gloomtrench_Base" },
		["Gloomtrench_Hut_Props"] = { 18.634, 21.267, 17.390, -21.552, 8.092, 156.516, "Gloomtrench_Base" },
		["Gloomtrench_Hut_Roof"] = { 17.942, 36.550, 18.097, -22.577, 16.741, 157.006, "Gloomtrench_Base" },
		["Gloomtrench_Hut_Walls"] = { 25.137, 28.784, 21.219, -20.095, 6.674, 157.033, "Gloomtrench_Base" },
		["Gloomtrench_Path"] = { 82.801, 32.946, 210.749, 22.668, 4.548, 69.464, "Gloomtrench_Base" },
		["Gloomtrench_Rift"] = { 128.342, 51.792, 74.330, 179.555, 14.073, -55.887, "Gloomtrench_Base" },
		["Gloomtrench_Spires"] = { 372.247, 115.876, 327.693, -13.065, 40.812, -6.183, "Gloomtrench_Base" },
		["Gloomtrench_Stalks"] = { 356.549, 52.013, 319.923, 52.830, 18.638, 19.010, "Gloomtrench_Base" },
		["Gloomtrench_TidePools"] = { 551.400, 42.771, 459.376, -3.262, 0.994, 4.414, "Gloomtrench_Base" },
		["Island_Base"] = { 288.748, 17.600, 231.657, 0.000, 0.000, 0.000, "Island_Base" },
		["Island_Bushes"] = { 91.036, 6.391, 87.878, 6.148, 7.757, 6.215, "Island_Base" },
		["Island_Foam"] = { 234.715, 0.100, 226.697, 1.371, 0.310, 19.345, "Island_Base" },
		["Island_Hut_Glow"] = { 7.066, 2.380, 13.492, 25.006, 8.774, -52.837, "Island_Base" },
		["Island_Hut_Props"] = { 15.700, 16.633, 19.301, 24.824, 13.981, -54.537, "Island_Base" },
		["Island_Hut_Roof"] = { 22.377, 7.383, 24.679, 24.698, 16.992, -54.373, "Island_Base" },
		["Island_Hut_Walls"] = { 19.196, 18.953, 24.028, 25.290, 11.488, -53.053, "Island_Base" },
		["Island_Rocks"] = { 151.135, 56.439, 136.676, 2.548, 27.457, 5.383, "Island_Base" },
		["Lampwork_Base"] = { 161.063, 20.426, 142.201, 0.000, 0.000, 0.000, "Lampwork_Base" },
		["Lampwork_Glow"] = { 1.300, 3.200, 4.400, -0.530, 13.740, -19.173, "Lampwork_Base" },
		["Lampwork_Lamps"] = { 46.987, 18.539, 104.184, -6.136, 16.206, 16.999, "Lampwork_Base" },
		["Lampwork_Moths"] = { 4.266, 7.909, 6.324, 2.197, 12.193, -19.460, "Lampwork_Base" },
		["Lampwork_Rock"] = { 122.651, 20.205, 119.420, -2.311, 1.173, -11.554, "Lampwork_Base" },
		["Lampwork_Shop"] = { 71.955, 33.453, 106.700, -3.922, 6.714, 17.277, "Lampwork_Base" },
		["Lampwork_Yard"] = { 71.859, 8.577, 66.504, -3.841, 12.251, -1.521, "Lampwork_Base" },
		["Loadstone_Base"] = { 139.133, 14.942, 112.783, 0.000, 0.000, 0.000, "Loadstone_Base" },
		["Loadstone_Compass"] = { 2.900, 3.900, 0.500, -3.692, 9.106, 28.207, "Loadstone_Base" },
		["Loadstone_Elmo"] = { 26.954, 83.097, 39.030, -0.169, 54.329, 0.323, "Loadstone_Base" },
		["Loadstone_Fulgurite"] = { 44.520, 21.418, 44.444, -0.403, 14.578, -5.138, "Loadstone_Base" },
		["Loadstone_Glow"] = { 33.593, 47.782, 41.162, -2.641, 28.034, -8.597, "Loadstone_Base" },
		["Loadstone_Rubble"] = { 87.983, 17.182, 84.077, -1.182, 3.346, -1.792, "Loadstone_Base" },
		["Loadstone_Scrap"] = { 58.551, 22.364, 58.922, -5.256, 14.032, -3.511, "Loadstone_Base" },
		["Loadstone_Shack"] = { 22.286, 16.079, 29.222, -0.817, 5.816, 32.178, "Loadstone_Base" },
		["Loadstone_Spires"] = { 39.177, 91.733, 33.025, -0.682, 48.629, -2.442, "Loadstone_Base" },
		["Maelstrom_Base"] = { 683.154, 7.056, 609.313, 0.000, 0.000, 0.000, "Maelstrom_Base" },
		["Maelstrom_Chains"] = { 289.409, 107.771, 239.190, -25.157, 57.132, 33.511, "Maelstrom_Base" },
		["Maelstrom_Debris"] = { 419.840, 3.268, 445.553, -37.039, 5.753, 3.479, "Maelstrom_Base" },
		["Maelstrom_Platforms"] = { 117.166, 17.951, 119.778, -21.018, 2.497, 10.687, "Maelstrom_Base" },
		["Maelstrom_Rocks"] = { 445.932, 12.029, 418.023, -24.508, 5.441, -1.633, "Maelstrom_Base" },
		["Maelstrom_Sails"] = { 352.450, 18.185, 279.659, -9.028, 22.004, -3.198, "Maelstrom_Base" },
		["Maelstrom_Spires"] = { 397.599, 114.635, 369.782, -25.589, 54.379, -31.057, "Maelstrom_Base" },
		["Maelstrom_StormGlow"] = { 389.527, 112.449, 367.699, -21.964, 55.944, -30.545, "Maelstrom_Base" },
		["Maelstrom_Wrecks"] = { 385.791, 46.437, 369.315, -23.123, 17.025, 11.528, "Maelstrom_Base" },
		["Palm_Coconuts"] = { 117.597, 13.514, 94.544, 8.452, 33.778, 13.468, "Island_Base" },
		["Palm_Fronds"] = { 145.913, 22.223, 122.375, 7.147, 31.891, 12.254, "Island_Base" },
		["Palm_Trunks"] = { 121.389, 40.482, 93.938, 8.046, 22.273, 12.300, "Island_Base" },
		["Rookery_Base"] = { 119.745, 7.224, 104.621, 0.000, 0.000, 0.000, "Rookery_Base" },
		["Rookery_Birds"] = { 83.938, 54.435, 64.156, -3.193, 38.101, 1.438, "Rookery_Base" },
		["Rookery_Eyrie"] = { 26.377, 15.461, 20.562, 17.665, 46.180, -0.790, "Rookery_Base" },
		["Rookery_Guano"] = { 76.076, 61.049, 35.082, -6.958, 33.113, 1.359, "Rookery_Base" },
		["Rookery_Ledges"] = { 77.485, 53.589, 36.034, -6.972, 36.094, 1.132, "Rookery_Base" },
		["Rookery_Litter"] = { 74.216, 54.265, 30.839, -6.107, 37.441, 2.181, "Rookery_Base" },
		["Rookery_Nests"] = { 72.796, 51.070, 31.206, -7.941, 38.463, 1.509, "Rookery_Base" },
		["Rookery_Rig"] = { 56.579, 43.709, 26.773, -16.097, 29.523, 1.641, "Rookery_Base" },
		["Rookery_Stacks"] = { 79.715, 65.200, 43.194, -3.932, 29.788, 1.419, "Rookery_Base" },
		["Swamp_Base"] = { 516.802, 12.804, 446.722, 0.000, 0.000, 0.000, "Swamp_Base" },
		["Swamp_CattailHeads"] = { 278.634, 3.397, 235.935, -9.328, 8.054, -0.256, "Swamp_Base" },
		["Swamp_Cattails"] = { 279.018, 6.454, 235.978, -9.078, 6.604, -0.282, "Swamp_Base" },
		["Swamp_Foam"] = { 420.035, 0.100, 361.333, 1.165, 2.708, 5.951, "Swamp_Base" },
		["Swamp_HangMoss"] = { 329.754, 30.018, 289.339, 2.748, 23.321, 10.604, "Swamp_Base" },
		["Swamp_Hut_Glow"] = { 25.549, 7.150, 9.383, -30.409, 9.433, 140.249, "Swamp_Base" },
		["Swamp_Hut_Props"] = { 26.337, 11.633, 15.400, -30.581, 10.453, 139.128, "Swamp_Base" },
		["Swamp_Hut_Roof"] = { 15.466, 10.347, 15.693, -36.401, 13.825, 137.840, "Swamp_Base" },
		["Swamp_Hut_Walls"] = { 30.045, 24.099, 19.501, -30.135, 16.397, 135.791, "Swamp_Base" },
		["Swamp_Lilies"] = { 228.610, 0.100, 141.053, -17.807, 4.828, 21.589, "Swamp_Base" },
		["Swamp_LilyBlooms"] = { 215.352, 0.598, 125.007, -19.516, 5.117, 18.567, "Swamp_Base" },
		["Swamp_Logs"] = { 312.144, 7.249, 282.882, 4.677, 7.293, 13.774, "Swamp_Base" },
		["Swamp_Mushrooms"] = { 271.844, 3.697, 234.955, -14.514, 6.819, 3.204, "Swamp_Base" },
		["Swamp_Stones"] = { 303.140, 2.547, 211.559, 9.043, 5.932, 16.876, "Swamp_Base" },
		["Swamp_TreeLeaves"] = { 336.464, 27.675, 247.225, 2.944, 25.479, 35.984, "Swamp_Base" },
		["Swamp_TreeLeaves2"] = { 333.008, 27.980, 282.234, 0.684, 26.130, 1.711, "Swamp_Base" },
		["Swamp_TreeLeaves3"] = { 300.934, 27.801, 259.361, 11.067, 26.252, 8.142, "Swamp_Base" },
		["Swamp_Trees"] = { 327.198, 33.652, 239.077, 3.962, 19.755, 36.218, "Swamp_Base" },
		["Swamp_Trees2"] = { 325.225, 35.403, 275.058, 0.549, 20.639, 2.881, "Swamp_Base" },
		["Swamp_Trees3"] = { 293.191, 34.296, 250.457, 10.428, 20.094, 7.579, "Swamp_Base" },
		["Swamp_Vines"] = { 324.350, 32.873, 287.435, 4.200, 19.904, 9.922, "Swamp_Base" },
		["Swamp_Water"] = { 327.057, 3.300, 283.580, 6.665, 3.148, 16.620, "Swamp_Base" },
		["Volcano_Base"] = { 1971.392, 932.227, 1784.443, 0.000, 0.000, 0.000, "Volcano_Base" },
		["Volcano_DeadTrees"] = { 1322.739, 120.908, 1157.516, -71.724, -398.490, 92.568, "Volcano_Base" },
		["Volcano_Dock_Planks"] = { 18.352, 1.030, 52.000, -37.432, -455.199, 645.851, "Volcano_Base" },
		["Volcano_Dock_Posts"] = { 18.260, 10.100, 51.405, -37.435, -458.063, 646.051, "Volcano_Base" },
		["Volcano_Foam"] = { 1574.871, 0.100, 1375.070, -6.252, -457.003, 21.656, "Volcano_Base" },
		["Volcano_Hut_Glow"] = { 23.881, 23.230, 36.726, 43.325, -441.519, 558.313, "Volcano_Base" },
		["Volcano_Hut_Props"] = { 32.899, 11.000, 22.666, 42.500, -448.611, 569.594, "Volcano_Base" },
		["Volcano_Hut_Roof"] = { 27.136, 8.591, 21.936, 42.491, -444.059, 566.221, "Volcano_Base" },
		["Volcano_Hut_Trim"] = { 19.393, 6.643, 24.548, 42.943, -447.433, 568.765, "Volcano_Base" },
		["Volcano_Hut_Walls"] = { 26.511, 24.450, 38.063, 42.624, -442.629, 562.154, "Volcano_Base" },
		["Volcano_Lava"] = { 1559.934, 923.971, 1260.554, 12.936, -0.928, 21.961, "Volcano_Base" },
		["Volcano_Rocks"] = { 1445.633, 84.803, 1219.392, -18.978, -423.208, 15.333, "Volcano_Base" },
		["Whalefall_Baleen"] = { 133.790, 10.357, 49.981, -3.174, 10.409, 22.220, "Whalefall_Base" },
		["Whalefall_Bar"] = { 184.180, 11.833, 125.190, -19.207, 3.639, -11.746, "Whalefall_Base" },
		["Whalefall_Base"] = { 317.941, 7.600, 315.626, 0.000, 0.000, 0.000, "Whalefall_Base" },
		["Whalefall_Bones"] = { 146.700, 19.776, 61.099, -10.850, 14.493, 18.252, "Whalefall_Base" },
		["Whalefall_Camp"] = { 144.393, 11.478, 52.298, -9.449, 10.670, 20.186, "Whalefall_Base" },
		["Whalefall_Embers"] = { 7.821, 1.235, 8.299, 46.223, 8.425, 16.180, "Whalefall_Base" },
		["Whalefall_Fish"] = { 21.043, 5.686, 28.858, 46.743, 9.015, 18.318, "Whalefall_Base" },
		["Whalefall_Grass"] = { 141.020, 4.121, 48.935, -8.647, 9.448, 18.915, "Whalefall_Base" },
		["Whalefall_Gulls"] = { 138.139, 17.550, 48.591, -4.323, 15.607, 17.680, "Whalefall_Base" },
		["Wreckwater_Base"] = { 610.923, 24.916, 510.902, 0.000, 0.000, 0.000, "Wreckwater_Base" },
		["Wreckwater_Bay"] = { 210.099, 3.000, 304.507, -8.041, 1.541, 38.740, "Wreckwater_Base" },
		["Wreckwater_Dock_Planks"] = { 20.337, 1.029, 46.000, -13.254, 4.736, 187.577, "Wreckwater_Base" },
		["Wreckwater_Dock_Posts"] = { 20.260, 10.100, 45.405, -13.331, 1.871, 187.777, "Wreckwater_Base" },
		["Wreckwater_Dunes"] = { 415.782, 25.712, 354.819, -11.044, -2.576, 1.504, "Wreckwater_Base" },
		["Wreckwater_Foam"] = { 492.783, 0.100, 421.210, -3.439, 2.931, 0.150, "Wreckwater_Base" },
		["Wreckwater_GhostGlow"] = { 889.478, 117.844, 753.812, 7.301, 60.578, -8.005, "Wreckwater_Base" },
		["Wreckwater_Hulks"] = { 413.695, 132.334, 387.778, -13.662, 52.802, 6.832, "Wreckwater_Base" },
		["Wreckwater_Hut_Canvas"] = { 34.005, 20.821, 22.978, -64.833, 14.984, 156.740, "Wreckwater_Base" },
		["Wreckwater_Hut_Glow"] = { 35.681, 12.690, 28.153, -65.806, 14.506, 155.296, "Wreckwater_Base" },
		["Wreckwater_Hut_Props"] = { 36.830, 22.601, 28.888, -65.674, 15.692, 154.750, "Wreckwater_Base" },
		["Wreckwater_Hut_Roof"] = { 36.713, 14.095, 31.006, -65.041, 10.409, 154.688, "Wreckwater_Base" },
		["Wreckwater_Hut_Walls"] = { 32.472, 22.228, 31.958, -68.817, 9.225, 153.895, "Wreckwater_Base" },
		["Wreckwater_Ironwork"] = { 409.073, 16.190, 380.453, -14.827, 7.513, -42.176, "Wreckwater_Base" },
		["Wreckwater_Quay_Planks"] = { 60.443, 2.000, 41.006, -13.386, 4.221, 149.553, "Wreckwater_Base" },
		["Wreckwater_Quay_Posts"] = { 59.500, 16.400, 41.992, -13.331, 4.021, 150.056, "Wreckwater_Base" },
		["Wreckwater_Rocks"] = { 536.835, 28.781, 455.547, -11.925, 7.413, -5.606, "Wreckwater_Base" },
		["Wreckwater_Sails"] = { 292.491, 78.557, 219.511, -0.332, 62.235, -44.535, "Wreckwater_Base" },
		["Wreckwater_SeaHulks"] = { 989.230, 53.884, 767.343, 19.335, 18.032, -9.451, "Wreckwater_Base" },
	},
	KrakenArena = {
		["KrakenArena_Base"] = { 176.852, 29.950, 51.075, 0.000, 0.000, 0.000, "KrakenArena_Base" },
		["KrakenArena_CoverCapstan"] = { 10.539, 2.500, 10.708, -16.426, 9.675, -2.997, "KrakenArena_Base" },
		["KrakenArena_CoverCargoAft"] = { 12.000, 2.590, 9.800, -32.426, 9.720, 9.000, "KrakenArena_Base" },
		["KrakenArena_CoverCargoFore"] = { 18.000, 2.470, 9.300, 35.574, 9.660, -8.500, "KrakenArena_Base" },
		["KrakenArena_CoverCoaming"] = { 17.000, 2.700, 12.000, -0.426, 9.775, 1.000, "KrakenArena_Base" },
		["KrakenArena_DebrisDeco"] = { 157.450, 10.766, 36.607, -4.346, 13.808, -0.056, "KrakenArena_Base" },
		["KrakenArena_Fittings"] = { 137.400, 8.800, 21.267, -8.426, 19.825, 0.000, "KrakenArena_Base" },
		["KrakenArena_FlagDeco"] = { 1.525, 5.400, 11.000, -8.187, 66.925, -6.500, "KrakenArena_Base" },
		["KrakenArena_Foam"] = { 207.427, 1.249, 51.138, 8.359, 0.705, 0.100, "KrakenArena_Base" },
		["KrakenArena_Forecastle"] = { 42.697, 8.400, 28.100, 61.225, 11.225, 0.000, "KrakenArena_Base" },
		["KrakenArena_LampGlow"] = { 125.932, 32.796, 14.021, -12.445, 33.556, 0.013, "KrakenArena_Base" },
		["KrakenArena_MainDeck"] = { 170.000, 0.790, 39.100, -2.426, 8.120, 0.000, "KrakenArena_Base" },
		["KrakenArena_Masts"] = { 128.354, 70.000, 46.000, 51.551, 35.425, 0.000, "KrakenArena_Base" },
		["KrakenArena_Quarterdeck"] = { 56.050, 10.300, 36.750, -60.401, 13.275, 0.000, "KrakenArena_Base" },
		["KrakenArena_Rails"] = { 170.932, 12.140, 39.890, -2.260, 14.495, 0.000, "KrakenArena_Base" },
		["KrakenArena_RiggingDeco"] = { 197.134, 49.073, 51.041, 13.068, 32.042, 0.000, "KrakenArena_Base" },
		["KrakenArena_SailDeco"] = { 69.885, 33.226, 40.889, 26.771, 35.899, 2.556, "KrakenArena_Base" },
		["KrakenArena_SpawnPad"] = { 14.000, 2.500, 14.000, -68.426, 18.575, 0.000, "KrakenArena_Base" },
		["KrakenArena_WrapMarkDeco"] = { 81.000, 0.780, 37.778, -2.426, 8.815, -0.089, "KrakenArena_Base" },
	},
	KrakenGullet = {
		["KrakenGullet_Base"] = { 264.000, 28.344, 264.000, 0.000, 0.000, 0.000, "KrakenGullet_Base" },
		["KrakenGullet_Dais"] = { 51.621, 5.800, 52.000, 0.000, -0.002, 0.000, "KrakenGullet_Base" },
		["KrakenGullet_EntryPad"] = { 27.063, 5.200, 26.000, 0.000, 4.948, 86.000, "KrakenGullet_Base" },
		["KrakenGullet_GutDeco"] = { 208.991, 11.376, 166.605, -1.576, 5.917, -16.571, "KrakenGullet_Base" },
		["KrakenGullet_Heart"] = { 51.812, 69.030, 52.329, 0.000, 38.820, 0.000, "KrakenGullet_Base" },
		["KrakenGullet_HeartGlow"] = { 36.913, 43.131, 34.312, 0.235, 23.187, -0.109, "KrakenGullet_Base" },
		["KrakenGullet_Ribs"] = { 225.834, 79.065, 222.156, -0.204, 41.150, -0.279, "KrakenGullet_Base" },
		["KrakenGullet_Socket1"] = { 15.455, 4.819, 15.517, 53.245, -0.165, -35.915, "KrakenGullet_Base" },
		["KrakenGullet_Socket2"] = { 15.520, 4.819, 15.530, -2.797, 4.160, -76.119, "KrakenGullet_Base" },
		["KrakenGullet_Socket3"] = { 15.606, 4.819, 15.465, -52.493, 3.016, -32.875, "KrakenGullet_Base" },
		["KrakenGullet_Socket4"] = { 15.615, 4.819, 15.578, -70.144, 2.811, 34.004, "KrakenGullet_Base" },
		["KrakenGullet_Socket5"] = { 15.645, 4.819, 15.364, -11.476, 3.027, 65.052, "KrakenGullet_Base" },
		["KrakenGullet_Socket6"] = { 15.598, 4.819, 15.569, 51.475, 1.263, 53.046, "KrakenGullet_Base" },
		["KrakenGullet_VeinGlow"] = { 228.165, 85.767, 224.603, -1.130, 40.907, -0.951, "KrakenGullet_Base" },
		["KrakenGullet_Walls"] = { 265.273, 106.783, 267.086, -2.015, 39.595, 0.072, "KrakenGullet_Base" },
	},
	KrakenPack = {
		["Kraken_Barnacles"] = { 71.989, 55.773, 100.240, 0.000, 0.000, 0.000, "Kraken_Barnacles" },
		["Kraken_Cap"] = { 100.132, 59.992, 94.895, 2.806, 0.092, -0.174, "Kraken_Barnacles" },
		["Kraken_Crust"] = { 59.308, 43.462, 75.260, -12.374, -42.172, -7.011, "Kraken_Barnacles" },
		["Kraken_Eyes"] = { 24.863, 25.000, 56.993, 39.745, -3.912, -0.174, "Kraken_Barnacles" },
		["Kraken_Eyespots"] = { 96.933, 74.284, 95.159, 2.312, -10.070, 0.565, "Kraken_Barnacles" },
		["Kraken_GutStrand"] = { 24.000, 5.155, 2.231, 3.203, -51.867, -0.208, "Kraken_Barnacles" },
		["Kraken_Head"] = { 97.749, 103.237, 102.963, 3.203, -21.531, -0.174, "Kraken_Barnacles" },
		["Kraken_Lashes"] = { 16.180, 12.974, 65.888, 41.871, 10.609, -0.174, "Kraken_Barnacles" },
		["Kraken_Polyp"] = { 6.857, 10.792, 6.800, 3.203, -46.608, -0.174, "Kraken_Barnacles" },
		["Kraken_Pupil"] = { 8.843, 16.800, 58.218, 50.342, -3.912, -0.174, "Kraken_Barnacles" },
		["Kraken_RibArch"] = { 4.504, 30.796, 39.185, 3.203, -36.386, -0.174, "Kraken_Barnacles" },
		["Kraken_Scrollwork"] = { 53.608, 18.288, 64.061, 4.457, 24.673, -0.174, "Kraken_Barnacles" },
		["Kraken_Siphon"] = { 21.863, 25.161, 26.400, 51.588, -23.628, -0.174, "Kraken_Barnacles" },
		["Kraken_SiphonCore"] = { 7.262, 9.707, 10.800, 57.948, -28.523, -0.174, "Kraken_Barnacles" },
		["Kraken_TentacleSeg"] = { 12.000, 8.000, 8.000, 3.203, -49.912, -0.174, "Kraken_Barnacles" },
		["Kraken_TentacleSucker"] = { 1.400, 6.240, 6.400, 3.353, -49.912, -0.174, "Kraken_Barnacles" },
		["Kraken_TentacleTip"] = { 36.000, 7.800, 7.800, -5.797, -49.912, -0.174, "Kraken_Barnacles" },
	},
	Maelstrom = {
		["Maelstrom_Base"] = { 683.154, 7.056, 609.313, 0.000, 0.000, 0.000, "Maelstrom_Base" },
		["Maelstrom_Chains"] = { 289.409, 107.771, 239.190, -25.157, 57.132, 33.511, "Maelstrom_Base" },
		["Maelstrom_Debris"] = { 419.838, 3.268, 445.577, -37.040, 6.173, 3.490, "Maelstrom_Base" },
		["Maelstrom_Platforms"] = { 117.166, 17.951, 119.778, -21.018, 2.497, 10.687, "Maelstrom_Base" },
		["Maelstrom_Rocks"] = { 445.932, 12.029, 418.023, -24.508, 5.441, -1.633, "Maelstrom_Base" },
		["Maelstrom_Sails"] = { 352.450, 18.185, 279.659, -9.028, 22.004, -3.198, "Maelstrom_Base" },
		["Maelstrom_Spires"] = { 397.599, 114.635, 369.782, -25.589, 54.379, -31.057, "Maelstrom_Base" },
		["Maelstrom_StormGlow"] = { 389.527, 113.699, 367.699, -21.964, 56.569, -30.545, "Maelstrom_Base" },
		["Maelstrom_Wrecks"] = { 387.543, 44.874, 369.315, -22.247, 17.806, 11.528, "Maelstrom_Base" },
	},
	NoctyssArena = {
		["NoctyssArena_Base"] = { 174.899, 11.442, 173.345, 0.000, 0.000, 0.000, "NoctyssArena_Base" },
		["NoctyssArena_Bones"] = { 88.468, 1.862, 107.151, 0.152, 5.481, 6.763, "NoctyssArena_Base" },
		["NoctyssArena_DecoCracks"] = { 83.039, 1.381, 80.805, 1.575, 5.037, -4.772, "NoctyssArena_Base" },
		["NoctyssArena_DecoPitWater"] = { 28.301, 0.400, 29.092, -0.217, -1.421, -0.304, "NoctyssArena_Base" },
		["NoctyssArena_DecoSilt"] = { 111.366, 0.771, 121.665, -9.446, 5.321, 1.520, "NoctyssArena_Base" },
		["NoctyssArena_DecoVeins"] = { 59.007, 3.692, 57.724, -0.227, 5.273, 1.145, "NoctyssArena_Base" },
		["NoctyssArena_Elders"] = { 59.192, 4.490, 97.392, -8.197, 6.815, -10.539, "NoctyssArena_Base" },
		["NoctyssArena_Fins"] = { 105.436, 22.364, 111.863, -6.072, 14.928, -6.920, "NoctyssArena_Base" },
		["NoctyssArena_Foam"] = { 183.116, 0.060, 180.570, -1.206, 4.009, 0.774, "NoctyssArena_Base" },
		["NoctyssArena_GlowCoral"] = { 78.491, 2.760, 73.018, 0.617, 6.965, -1.733, "NoctyssArena_Base" },
		["NoctyssArena_GlowKelp"] = { 145.935, 8.822, 144.475, 0.708, 5.212, 0.633, "NoctyssArena_Base" },
		["NoctyssArena_Mantle"] = { 92.288, 6.358, 90.582, -0.210, 4.308, 1.380, "NoctyssArena_Base" },
		["NoctyssArena_Rim"] = { 47.625, 11.297, 45.230, -1.056, 6.769, 2.225, "NoctyssArena_Base" },
		["NoctyssArena_Slab"] = { 8.951, 10.351, 21.524, -0.852, 0.766, 6.541, "NoctyssArena_Base" },
		["NoctyssArena_Socket1"] = { 12.097, 6.096, 11.597, 33.252, 7.027, -7.429, "NoctyssArena_Base" },
		["NoctyssArena_Socket2"] = { 12.586, 6.184, 11.739, 15.147, 7.071, -30.504, "NoctyssArena_Base" },
		["NoctyssArena_Socket3"] = { 12.200, 6.018, 11.113, -14.154, 6.988, -30.949, "NoctyssArena_Base" },
		["NoctyssArena_Socket4"] = { 12.214, 6.126, 11.601, -32.842, 7.042, -8.178, "NoctyssArena_Base" },
		["NoctyssArena_Socket5"] = { 12.367, 6.076, 11.575, -26.842, 7.017, 20.622, "NoctyssArena_Base" },
		["NoctyssArena_Socket6"] = { 11.402, 6.185, 11.449, -0.196, 7.072, 33.739, "NoctyssArena_Base" },
		["NoctyssArena_Socket7"] = { 11.707, 6.188, 11.614, 26.615, 7.073, 21.225, "NoctyssArena_Base" },
		["NoctyssArena_Stacks"] = { 175.280, 52.000, 176.198, -3.573, 23.779, -2.339, "NoctyssArena_Base" },
		["NoctyssArena_Teeth"] = { 151.163, 19.785, 154.612, 0.534, 7.583, 0.852, "NoctyssArena_Base" },
	},
	NoctyssPack = {
		["Noctyss_Barbels"] = { 20.297, 10.635, 13.815, 0.000, 0.000, 0.000, "Noctyss_Barbels" },
		["Noctyss_Eyes"] = { 16.386, 9.410, 11.351, 6.170, 2.857, 0.000, "Noctyss_Barbels" },
		["Noctyss_Gullet"] = { 6.592, 6.301, 6.042, -4.646, 6.013, -0.000, "Noctyss_Barbels" },
		["Noctyss_Jaw"] = { 18.800, 7.273, 11.200, 1.569, 2.376, 0.000, "Noctyss_Barbels" },
		["Noctyss_JawBone"] = { 14.839, 4.046, 11.683, -0.419, 7.818, -0.003, "Noctyss_Barbels" },
		["Noctyss_Skull"] = { 25.255, 6.188, 11.844, -0.359, 5.727, -0.078, "Noctyss_Barbels" },
		["Noctyss_SkullBone"] = { 25.748, 8.182, 11.548, 2.836, 3.886, -0.005, "Noctyss_Barbels" },
		["Noctyss_StalkBarbs"] = { 7.123, 3.551, 9.318, 0.416, 6.771, -0.878, "Noctyss_Barbels" },
		["Noctyss_StalkBulb"] = { 3.804, 5.602, 3.680, 7.369, 3.481, 0.000, "Noctyss_Barbels" },
		["Noctyss_StalkCage"] = { 3.433, 6.263, 5.088, 7.169, 5.097, -0.010, "Noctyss_Barbels" },
		["Noctyss_StalkFin"] = { 3.445, 5.415, 7.338, 0.546, 8.393, 0.000, "Noctyss_Barbels" },
		["Noctyss_StalkHood"] = { 8.491, 6.212, 10.777, 4.205, 7.606, 0.000, "Noctyss_Barbels" },
		["Noctyss_StalkRoot"] = { 7.240, 8.797, 9.540, -0.251, 7.464, 0.004, "Noctyss_Barbels" },
		["Noctyss_StalkSeg"] = { 3.000, 3.354, 5.024, 0.769, 7.362, 0.000, "Noctyss_Barbels" },
	},
	PyreliskArena = {
		["PyreliskArena_AshDeco"] = { 320.272, 0.000, 417.084, 19.141, 10.040, 11.300, "PyreliskArena_Base" },
		["PyreliskArena_Base"] = { 472.000, 20.000, 472.000, 0.000, 0.000, 0.000, "PyreliskArena_Base" },
		["PyreliskArena_BoneDeco"] = { 51.446, 21.897, 39.972, -98.565, 18.880, 153.810, "PyreliskArena_Base" },
		["PyreliskArena_CloudDeco"] = { 1807.326, 280.067, 1914.766, 15.577, -226.708, -40.609, "PyreliskArena_Base" },
		["PyreliskArena_CrustDeco"] = { 438.527, 0.000, 375.437, -1.199, 10.040, -19.902, "PyreliskArena_Base" },
		["PyreliskArena_Flank"] = { 990.751, 305.899, 986.164, 0.075, -140.988, -0.855, "PyreliskArena_Base" },
		["PyreliskArena_Gate"] = { 39.428, 32.300, 36.029, 0.027, 25.853, -212.726, "PyreliskArena_Base" },
		["PyreliskArena_LakeFloor"] = { 240.000, 3.000, 240.000, 0.000, 8.500, 0.000, "PyreliskArena_Base" },
		["PyreliskArena_Lava"] = { 240.127, 0.040, 241.641, 0.768, 10.120, 1.544, "PyreliskArena_Base" },
		["PyreliskArena_Rim"] = { 504.000, 11.770, 504.000, 0.000, 15.585, 0.000, "PyreliskArena_Base" },
		["PyreliskArena_SeamDeco"] = { 451.229, 0.010, 450.062, -0.206, 10.055, -0.138, "PyreliskArena_Base" },
		["PyreliskArena_Shaft"] = { 236.000, 120.000, 236.000, 0.000, -50.000, 0.000, "PyreliskArena_Base" },
		["PyreliskArena_Teeth"] = { 359.999, 21.701, 397.836, 12.010, 19.305, 11.918, "PyreliskArena_Base" },
		["PyreliskArena_VentDeco"] = { 442.029, 3.506, 442.742, 0.478, 11.353, -0.407, "PyreliskArena_Base" },
	},
	PyreliskHeart = {
		["PyreliskHeart_Base"] = { 216.000, 23.583, 216.000, 0.000, 0.000, 0.000, "PyreliskHeart_Base" },
		["PyreliskHeart_Dais"] = { 48.000, 8.212, 48.000, 0.000, 2.952, 0.000, "PyreliskHeart_Base" },
		["PyreliskHeart_EntryPad"] = { 22.190, 5.800, 22.599, 0.045, 5.300, 73.701, "PyreliskHeart_Base" },
		["PyreliskHeart_Heart"] = { 41.842, 62.735, 42.404, 0.000, 35.228, 0.000, "PyreliskHeart_Base" },
		["PyreliskHeart_HeartGlow"] = { 33.500, 37.650, 35.628, -0.013, 22.569, 0.822, "PyreliskHeart_Base" },
		["PyreliskHeart_RubbleDeco"] = { 192.008, 9.888, 184.668, 0.627, 7.028, 0.127, "PyreliskHeart_Base" },
		["PyreliskHeart_Socket1"] = { 16.400, 8.324, 16.400, 63.649, 4.338, -6.690, "PyreliskHeart_Base" },
		["PyreliskHeart_Socket2"] = { 16.400, 9.060, 16.400, 39.834, 4.883, -33.425, "PyreliskHeart_Base" },
		["PyreliskHeart_Socket3"] = { 16.400, 9.779, 16.400, -5.850, 4.660, -47.642, "PyreliskHeart_Base" },
		["PyreliskHeart_Socket4"] = { 16.400, 8.302, 16.400, -30.565, 3.384, -31.651, "PyreliskHeart_Base" },
		["PyreliskHeart_Socket5"] = { 16.400, 9.082, 16.400, -55.787, 5.129, 4.881, "PyreliskHeart_Base" },
		["PyreliskHeart_Socket6"] = { 16.400, 9.827, 16.400, -47.237, 5.891, 48.915, "PyreliskHeart_Base" },
		["PyreliskHeart_Socket7"] = { 16.400, 8.239, 16.400, 26.222, 7.471, 64.903, "PyreliskHeart_Base" },
		["PyreliskHeart_Socket8"] = { 16.400, 9.066, 16.400, 51.962, 4.967, 30.000, "PyreliskHeart_Base" },
		["PyreliskHeart_VeinGlow"] = { 189.001, 73.522, 191.023, -0.073, 36.530, 0.113, "PyreliskHeart_Base" },
		["PyreliskHeart_Vent1Glow"] = { 8.460, 17.271, 7.533, 88.094, 11.237, -31.242, "PyreliskHeart_Base" },
		["PyreliskHeart_Vent2Glow"] = { 7.504, 17.464, 8.368, 15.632, 23.283, -89.873, "PyreliskHeart_Base" },
		["PyreliskHeart_Vent3Glow"] = { 8.417, 17.574, 8.267, -66.224, 35.285, -55.406, "PyreliskHeart_Base" },
		["PyreliskHeart_Vent4Glow"] = { 8.595, 17.441, 7.351, -88.784, 11.323, 31.797, "PyreliskHeart_Base" },
		["PyreliskHeart_Vent5Glow"] = { 7.504, 17.372, 8.490, -14.961, 23.243, 88.207, "PyreliskHeart_Base" },
		["PyreliskHeart_Vent6Glow"] = { 8.521, 17.237, 8.413, 65.047, 35.113, 54.332, "PyreliskHeart_Base" },
		["PyreliskHeart_Walls"] = { 217.240, 94.610, 219.210, 0.694, 35.904, 0.115, "PyreliskHeart_Base" },
	},
	PyreliskPack = {
		["Pyrelisk_ArmRock"] = { 10.272, 7.435, 9.848, 0.000, 0.000, 0.000, "Pyrelisk_ArmRock" },
		["Pyrelisk_Core"] = { 88.683, 264.264, 224.552, -2.479, 64.281, 0.096, "Pyrelisk_ArmRock" },
		["Pyrelisk_Crown"] = { 39.935, 17.599, 41.093, 2.885, 42.996, 0.791, "Pyrelisk_ArmRock" },
		["Pyrelisk_Eyes"] = { 3.899, 3.320, 25.613, 24.910, 14.158, 0.035, "Pyrelisk_ArmRock" },
		["Pyrelisk_Forearm"] = { 77.164, 35.556, 41.168, 29.960, -3.415, 0.382, "Pyrelisk_ArmRock" },
		["Pyrelisk_Hand"] = { 34.145, 31.651, 35.227, 10.838, -1.666, 0.847, "Pyrelisk_ArmRock" },
		["Pyrelisk_Head"] = { 60.969, 52.578, 54.425, 1.343, 21.509, -0.013, "Pyrelisk_ArmRock" },
		["Pyrelisk_Jaw"] = { 35.746, 15.012, 29.968, 11.127, 8.077, 0.055, "Pyrelisk_ArmRock" },
		["Pyrelisk_NeckCore"] = { 24.243, 10.174, 25.586, -0.300, -1.261, 0.330, "Pyrelisk_ArmRock" },
		["Pyrelisk_Seam"] = { 22.418, 8.100, 30.000, -0.290, -3.601, 0.096, "Pyrelisk_ArmRock" },
		["Pyrelisk_Shoulder"] = { 56.508, 50.565, 51.522, 4.809, 3.059, 0.107, "Pyrelisk_ArmRock" },
		["Pyrelisk_Torso"] = { 100.696, 215.157, 168.798, -0.738, 46.353, -1.496, "Pyrelisk_ArmRock" },
		["Pyrelisk_UpperArm"] = { 69.330, 48.497, 47.656, 29.537, -2.144, 0.306, "Pyrelisk_ArmRock" },
		["Pyrelisk_Vent"] = { 21.448, 38.629, 20.911, -0.340, 7.263, -0.449, "Pyrelisk_ArmRock" },
		["Pyrelisk_WalkArm"] = { 48.000, 4.000, 18.000, 31.660, 16.449, 0.096, "Pyrelisk_ArmRock" },
		["Pyrelisk_WalkDeck"] = { 64.000, 14.200, 150.000, -14.340, 142.949, 0.096, "Pyrelisk_ArmRock" },
		["Pyrelisk_WalkNeck"] = { 46.280, 25.063, 52.756, -8.350, 148.990, -24.993, "Pyrelisk_ArmRock" },
	},
	RimefangArena = {
		["RimefangArena_Base"] = { 365.422, 12.143, 358.308, 0.000, 0.000, 0.000, "RimefangArena_Base" },
		["RimefangArena_Bergs"] = { 54.404, 31.160, 296.068, 78.691, 12.701, -1.967, "RimefangArena_Base" },
		["RimefangArena_Bones"] = { 52.696, 11.798, 34.317, -119.191, 9.461, -102.045, "RimefangArena_Base" },
		["RimefangArena_Foam"] = { 356.236, 0.060, 354.711, -2.263, 3.679, -0.677, "RimefangArena_Base" },
		["RimefangArena_Hull"] = { 32.467, 20.969, 29.879, -145.469, 12.466, 51.407, "RimefangArena_Base" },
		["RimefangArena_Ironwork"] = { 30.346, 21.752, 15.860, -149.366, 6.259, 67.877, "RimefangArena_Base" },
		["RimefangArena_Leads"] = { 153.281, 0.435, 156.936, 0.806, 6.153, 14.735, "RimefangArena_Base" },
		["RimefangArena_Ridge"] = { 270.244, 20.939, 269.950, -1.601, 14.612, -0.067, "RimefangArena_Base" },
		["RimefangArena_Shard01"] = { 24.764, 3.842, 14.714, -24.349, 4.506, 7.153, "RimefangArena_Base" },
		["RimefangArena_Shard02"] = { 29.703, 3.546, 21.520, -18.532, 4.492, 22.579, "RimefangArena_Base" },
		["RimefangArena_Shard03"] = { 33.932, 3.488, 25.009, 8.585, 4.635, 26.015, "RimefangArena_Base" },
		["RimefangArena_Shard04"] = { 25.640, 3.146, 23.760, 18.207, 4.785, 14.076, "RimefangArena_Base" },
		["RimefangArena_Shard05"] = { 24.210, 3.740, 21.253, 24.103, 4.282, -0.652, "RimefangArena_Base" },
		["RimefangArena_Shard06"] = { 29.624, 3.502, 23.852, 22.393, 4.591, -19.254, "RimefangArena_Base" },
		["RimefangArena_Shard07"] = { 28.140, 3.836, 24.809, 4.130, 4.554, -26.113, "RimefangArena_Base" },
		["RimefangArena_Shard08"] = { 23.346, 3.798, 25.649, -15.875, 4.306, -22.512, "RimefangArena_Base" },
		["RimefangArena_Shard09"] = { 27.577, 3.866, 28.306, -28.387, 4.327, -6.761, "RimefangArena_Base" },
		["RimefangArena_Shard10"] = { 34.809, 3.749, 46.281, -48.969, 4.454, 27.835, "RimefangArena_Base" },
		["RimefangArena_Shard11"] = { 40.253, 3.487, 37.235, -28.213, 4.644, 45.026, "RimefangArena_Base" },
		["RimefangArena_Shard12"] = { 33.599, 3.524, 38.333, 1.952, 4.517, 54.971, "RimefangArena_Base" },
		["RimefangArena_Shard13"] = { 32.585, 3.366, 34.725, 31.209, 4.515, 43.810, "RimefangArena_Base" },
		["RimefangArena_Shard14"] = { 48.527, 3.665, 31.077, 51.252, 4.371, 22.327, "RimefangArena_Base" },
		["RimefangArena_Shard15"] = { 41.169, 3.564, 39.637, 55.838, 4.623, -5.276, "RimefangArena_Base" },
		["RimefangArena_Shard16"] = { 41.058, 3.373, 40.337, 38.306, 4.613, -36.128, "RimefangArena_Base" },
		["RimefangArena_Shard17"] = { 32.903, 3.256, 40.699, 12.143, 4.483, -55.670, "RimefangArena_Base" },
		["RimefangArena_Shard18"] = { 34.153, 3.222, 38.832, -19.941, 4.727, -54.682, "RimefangArena_Base" },
		["RimefangArena_Shard19"] = { 40.322, 3.739, 40.565, -39.621, 4.522, -36.392, "RimefangArena_Base" },
		["RimefangArena_Shard20"] = { 28.061, 3.507, 43.271, -54.200, 4.392, -11.631, "RimefangArena_Base" },
		["RimefangArena_Shard21"] = { 46.172, 3.368, 44.858, -88.166, 4.458, 27.738, "RimefangArena_Base" },
		["RimefangArena_Shard22"] = { 44.150, 3.894, 37.342, -11.049, 4.307, 80.489, "RimefangArena_Base" },
		["RimefangArena_Shard23"] = { 52.686, 3.553, 31.654, 35.121, 4.619, 73.871, "RimefangArena_Base" },
		["RimefangArena_Shard24"] = { 40.909, 3.836, 51.664, 65.914, 4.430, 43.224, "RimefangArena_Base" },
		["RimefangArena_Shard25"] = { 36.183, 3.506, 59.770, 77.240, 4.534, -17.215, "RimefangArena_Base" },
		["RimefangArena_Shard26"] = { 54.993, 3.356, 44.283, 63.837, 4.610, -48.235, "RimefangArena_Base" },
		["RimefangArena_Shard27"] = { 49.868, 3.642, 40.197, 23.722, 4.576, -75.488, "RimefangArena_Base" },
		["RimefangArena_Shard28"] = { 52.026, 3.733, 36.699, -26.731, 4.257, -75.512, "RimefangArena_Base" },
		["RimefangArena_Shard29"] = { 53.590, 3.285, 47.037, -65.377, 4.666, -56.568, "RimefangArena_Base" },
		["RimefangArena_Shard30"] = { 41.223, 3.838, 44.904, -87.416, 4.509, -13.481, "RimefangArena_Base" },
		["RimefangArena_Shard31"] = { 41.899, 3.216, 57.294, -100.396, 4.511, 35.024, "RimefangArena_Base" },
		["RimefangArena_Shard32"] = { 41.858, 2.769, 54.060, -81.691, 4.752, 76.460, "RimefangArena_Base" },
		["RimefangArena_Shard33"] = { 38.071, 3.026, 57.521, -44.336, 4.636, 77.979, "RimefangArena_Base" },
		["RimefangArena_Shard34"] = { 63.645, 3.356, 28.369, -22.835, 4.369, 105.356, "RimefangArena_Base" },
		["RimefangArena_Shard35"] = { 61.929, 3.488, 31.343, 37.823, 4.319, 103.214, "RimefangArena_Base" },
		["RimefangArena_Shard36"] = { 47.817, 3.001, 56.561, 82.465, 4.577, 67.706, "RimefangArena_Base" },
		["RimefangArena_Shard37"] = { 42.042, 3.312, 50.033, 97.028, 4.574, 25.130, "RimefangArena_Base" },
		["RimefangArena_Shard38"] = { 28.933, 3.210, 60.298, 103.701, 4.470, -28.273, "RimefangArena_Base" },
		["RimefangArena_Shard39"] = { 54.941, 3.174, 51.443, 75.378, 4.501, -78.253, "RimefangArena_Base" },
		["RimefangArena_Shard40"] = { 56.272, 2.825, 29.867, 29.988, 4.712, -105.266, "RimefangArena_Base" },
		["RimefangArena_Shard41"] = { 59.633, 2.796, 29.245, -27.083, 4.734, -105.837, "RimefangArena_Base" },
		["RimefangArena_Shard42"] = { 52.753, 2.947, 49.828, -78.010, 4.629, -81.623, "RimefangArena_Base" },
		["RimefangArena_Shard43"] = { 43.044, 3.105, 68.428, -100.310, 4.434, -27.656, "RimefangArena_Base" },
		["RimefangArena_ThinIce"] = { 204.652, 0.244, 223.538, -0.782, 6.063, 6.365, "RimefangArena_Base" },
		["RimefangArena_Water"] = { 250.500, 0.700, 250.565, -1.624, 4.479, -0.764, "RimefangArena_Base" },
	},
	RimefangPack = {
		["Rimefang_Belly"] = { 11.793, 2.200, 6.000, 0.000, 0.000, 0.000, "Rimefang_Belly" },
		["Rimefang_Body"] = { 5.400, 14.400, 13.200, 0.000, 6.300, 0.000, "Rimefang_Belly" },
		["Rimefang_Eyes"] = { 7.990, 3.527, 14.380, -4.200, 7.200, 0.000, "Rimefang_Belly" },
		["Rimefang_Fin"] = { 13.150, 19.000, 2.900, -1.875, 15.800, 0.000, "Rimefang_Belly" },
		["Rimefang_Fluke"] = { 8.700, 3.600, 24.000, -1.750, 5.900, 0.000, "Rimefang_Belly" },
		["Rimefang_Head"] = { 16.400, 9.950, 13.900, 1.700, 9.075, 0.000, "Rimefang_Belly" },
		["Rimefang_Jaw"] = { 15.200, 4.800, 12.400, 1.600, 1.300, 0.000, "Rimefang_Belly" },
		["Rimefang_Pec"] = { 10.400, 4.560, 12.200, -1.700, 5.420, -6.100, "Rimefang_Belly" },
		["Rimefang_Rime"] = { 11.800, 3.353, 11.084, -1.700, 5.573, 0.000, "Rimefang_Belly" },
		["Rimefang_TeethLower"] = { 12.718, 2.980, 11.821, 1.212, 4.811, 0.000, "Rimefang_Belly" },
		["Rimefang_TeethUpper"] = { 12.718, 2.980, 13.086, 1.212, 2.989, 0.000, "Rimefang_Belly" },
	},
	RodPack = {
		["Angler_BobberBottom"] = { 0.440, 0.260, 0.440, 0.000, 0.000, 0.000, "Angler_BobberBottom" },
		["Angler_BobberTop"] = { 0.440, 0.680, 0.440, 0.000, 0.470, 0.000, "Angler_BobberBottom" },
		["Angler_Grip"] = { 0.528, 1.600, 0.531, -0.132, -2.732, -0.898, "Angler_BobberBottom" },
		["Angler_Line"] = { 0.133, 2.770, 0.932, 0.045, 2.189, -0.448, "Angler_BobberBottom" },
		["Angler_Trim"] = { 0.722, 7.400, 1.266, -0.088, 0.018, -0.550, "Angler_BobberBottom" },
		["Angler_Twig"] = { 0.300, 7.250, 0.300, -0.129, -0.057, -0.896, "Angler_BobberBottom" },
		["Auger_BobberBottom"] = { 0.180, 0.600, 0.180, -0.107, 0.057, 0.078, "Angler_BobberBottom" },
		["Auger_BobberTop"] = { 0.180, 0.800, 0.180, -0.107, 0.757, 0.078, "Angler_BobberBottom" },
		["Auger_Grip"] = { 0.552, 1.600, 0.527, -0.127, -2.732, -0.923, "Angler_BobberBottom" },
		["Auger_Line"] = { 0.159, 2.428, 1.016, -0.054, 2.363, -0.409, "Angler_BobberBottom" },
		["Auger_Trim"] = { 1.321, 5.730, 1.018, -0.023, -0.817, -0.813, "Angler_BobberBottom" },
		["Auger_Twig"] = { 0.400, 7.550, 0.400, -0.129, 0.093, -0.896, "Angler_BobberBottom" },
		["Aurora_BobberBottom"] = { 0.400, 0.400, 0.346, 0.107, 0.217, 0.234, "Angler_BobberBottom" },
		["Aurora_BobberTop"] = { 0.400, 0.520, 0.346, 0.107, 0.677, 0.234, "Angler_BobberBottom" },
		["Aurora_Grip"] = { 0.547, 1.600, 0.551, -0.131, -2.732, -0.898, "Angler_BobberBottom" },
		["Aurora_Line"] = { 0.126, 2.645, 0.997, 0.146, 2.252, -0.245, "Angler_BobberBottom" },
		["Aurora_Trim"] = { 0.897, 7.405, 1.479, -0.031, 0.021, -0.630, "Angler_BobberBottom" },
		["Aurora_Twig"] = { 0.715, 7.250, 0.365, -0.015, -0.057, -0.894, "Angler_BobberBottom" },
		["Bamboo_BobberBottom"] = { 0.180, 0.600, 0.180, -0.097, -0.163, 0.062, "Angler_BobberBottom" },
		["Bamboo_BobberTop"] = { 0.180, 0.800, 0.180, -0.097, 0.537, 0.062, "Angler_BobberBottom" },
		["Bamboo_Grip"] = { 0.509, 1.600, 0.511, -0.134, -2.732, -0.898, "Angler_BobberBottom" },
		["Bamboo_Line"] = { 0.156, 2.645, 0.997, -0.043, 2.252, -0.417, "Angler_BobberBottom" },
		["Bamboo_Trim"] = { 0.545, 7.470, 0.841, -0.120, 0.053, -0.752, "Angler_BobberBottom" },
		["Bamboo_Twig"] = { 0.430, 7.250, 0.430, -0.128, -0.057, -0.896, "Angler_BobberBottom" },
		["Bonecaster_BobberBottom"] = { 0.692, 0.376, 0.700, -0.030, 0.827, 0.890, "Angler_BobberBottom" },
		["Bonecaster_BobberTop"] = { 0.500, 0.440, 0.500, -0.066, 1.229, 0.850, "Angler_BobberBottom" },
		["Bonecaster_Grip"] = { 0.631, 1.830, 1.364, -0.127, -2.617, -0.514, "Angler_BobberBottom" },
		["Bonecaster_Line"] = { 0.108, 2.145, 1.176, -0.044, 2.509, 0.286, "Angler_BobberBottom" },
		["Bonecaster_Trim"] = { 0.599, 5.137, 1.047, -0.131, 1.170, -0.650, "Angler_BobberBottom" },
		["Bonecaster_Twig"] = { 0.840, 6.130, 1.351, -0.121, 0.691, -0.805, "Angler_BobberBottom" },
		["Brineheart_BobberBottom"] = { 0.440, 0.260, 0.440, -0.068, 0.421, 0.923, "Angler_BobberBottom" },
		["Brineheart_BobberTop"] = { 0.440, 0.680, 0.440, -0.068, 0.891, 0.923, "Angler_BobberBottom" },
		["Brineheart_Grip"] = { 0.691, 1.880, 1.438, -0.130, -2.592, -0.526, "Angler_BobberBottom" },
		["Brineheart_Line"] = { 0.121, 2.363, 1.193, -0.041, 2.400, 0.353, "Angler_BobberBottom" },
		["Brineheart_Trim"] = { 0.875, 4.982, 1.234, -0.132, 1.249, -0.682, "Angler_BobberBottom" },
		["Brineheart_Twig"] = { 1.222, 5.500, 1.280, -0.130, 0.818, -0.857, "Angler_BobberBottom" },
		["Cinderglass_BobberBottom"] = { 0.180, 0.600, 0.180, -0.057, 0.221, 0.764, "Angler_BobberBottom" },
		["Cinderglass_BobberTop"] = { 0.180, 0.800, 0.180, -0.057, 0.921, 0.764, "Angler_BobberBottom" },
		["Cinderglass_Grip"] = { 0.722, 1.970, 1.336, -0.083, -2.547, -0.509, "Angler_BobberBottom" },
		["Cinderglass_Line"] = { 0.115, 2.270, 1.143, -0.029, 2.445, 0.216, "Angler_BobberBottom" },
		["Cinderglass_Trim"] = { 0.616, 7.420, 1.030, -0.113, 0.028, -0.697, "Angler_BobberBottom" },
		["Cinderglass_Twig"] = { 0.461, 7.250, 0.806, -0.128, -0.057, -0.735, "Angler_BobberBottom" },
		["Cinderline_BobberBottom"] = { 0.480, 0.540, 0.480, 0.018, 0.554, 0.109, "Angler_BobberBottom" },
		["Cinderline_BobberTop"] = { 0.480, 0.460, 0.480, 0.018, 1.054, 0.109, "Angler_BobberBottom" },
		["Cinderline_Grip"] = { 0.555, 1.600, 0.545, -0.126, -2.732, -0.886, "Angler_BobberBottom" },
		["Cinderline_Line"] = { 0.199, 2.302, 1.058, 0.092, 2.426, -0.399, "Angler_BobberBottom" },
		["Cinderline_Trim"] = { 0.476, 2.630, 0.796, -0.095, -0.437, -0.683, "Angler_BobberBottom" },
		["Cinderline_Twig"] = { 0.391, 7.250, 0.423, -0.123, -0.057, -0.915, "Angler_BobberBottom" },
		["Doubloon_BobberBottom"] = { 0.440, 0.260, 0.440, -0.028, 0.255, 0.224, "Angler_BobberBottom" },
		["Doubloon_BobberTop"] = { 0.440, 0.680, 0.440, -0.028, 0.725, 0.224, "Angler_BobberBottom" },
		["Doubloon_Grip"] = { 0.599, 1.600, 0.596, -0.124, -2.732, -0.896, "Angler_BobberBottom" },
		["Doubloon_Line"] = { 0.152, 2.522, 1.056, 0.020, 2.316, -0.282, "Angler_BobberBottom" },
		["Doubloon_Trim"] = { 0.753, 7.420, 1.235, -0.087, 0.028, -0.614, "Angler_BobberBottom" },
		["Doubloon_Twig"] = { 0.381, 7.250, 0.370, -0.119, -0.057, -0.896, "Angler_BobberBottom" },
		["Eyewall_BobberBottom"] = { 0.480, 0.540, 0.480, -0.058, 0.482, 0.424, "Angler_BobberBottom" },
		["Eyewall_BobberTop"] = { 0.480, 0.460, 0.480, -0.058, 0.982, 0.424, "Angler_BobberBottom" },
		["Eyewall_Grip"] = { 0.973, 1.860, 1.524, -0.129, -2.632, -0.597, "Angler_BobberBottom" },
		["Eyewall_Line"] = { 0.115, 2.378, 1.146, -0.031, 2.390, -0.126, "Angler_BobberBottom" },
		["Eyewall_Trim"] = { 1.703, 5.450, 1.642, -0.084, 1.013, -0.880, "Angler_BobberBottom" },
		["Eyewall_Twig"] = { 0.873, 7.250, 0.765, -0.095, -0.057, -0.687, "Angler_BobberBottom" },
		["Fenpiercer_BobberBottom"] = { 0.180, 0.600, 0.180, -0.106, 0.241, 0.444, "Angler_BobberBottom" },
		["Fenpiercer_BobberTop"] = { 0.180, 0.800, 0.180, -0.106, 0.941, 0.444, "Angler_BobberBottom" },
		["Fenpiercer_Grip"] = { 0.649, 1.880, 1.396, -0.100, -2.642, -0.534, "Angler_BobberBottom" },
		["Fenpiercer_Line"] = { 0.105, 2.251, 1.181, -0.083, 2.454, -0.124, "Angler_BobberBottom" },
		["Fenpiercer_Trim"] = { 0.521, 3.590, 0.523, -0.128, 0.368, -0.893, "Angler_BobberBottom" },
		["Fenpiercer_Twig"] = { 1.025, 7.349, 0.400, -0.107, -0.007, -0.833, "Angler_BobberBottom" },
		["Frostheart_BobberBottom"] = { 0.380, 0.460, 0.329, -0.068, 0.691, 0.899, "Angler_BobberBottom" },
		["Frostheart_BobberTop"] = { 0.380, 0.440, 0.329, -0.068, 1.141, 0.899, "Angler_BobberBottom" },
		["Frostheart_Grip"] = { 0.668, 1.880, 1.431, -0.128, -2.642, -0.531, "Angler_BobberBottom" },
		["Frostheart_Line"] = { 0.108, 2.233, 1.223, -0.046, 2.464, 0.312, "Angler_BobberBottom" },
		["Frostheart_Trim"] = { 1.102, 5.719, 1.163, -0.112, 1.345, -0.813, "Angler_BobberBottom" },
		["Frostheart_Twig"] = { 0.966, 7.250, 0.942, -0.089, -0.057, -0.746, "Angler_BobberBottom" },
		["Gatorback_BobberBottom"] = { 0.480, 0.540, 0.480, -0.060, 0.335, 0.201, "Angler_BobberBottom" },
		["Gatorback_BobberTop"] = { 0.480, 0.460, 0.480, -0.060, 0.835, 0.201, "Angler_BobberBottom" },
		["Gatorback_Grip"] = { 0.655, 1.600, 0.653, -0.124, -2.732, -0.896, "Angler_BobberBottom" },
		["Gatorback_Line"] = { 0.175, 2.523, 1.060, -0.002, 2.316, -0.305, "Angler_BobberBottom" },
		["Gatorback_Trim"] = { 0.771, 7.070, 1.440, -0.110, -0.147, -0.544, "Angler_BobberBottom" },
		["Gatorback_Twig"] = { 0.475, 7.314, 1.431, -0.116, -0.025, -0.846, "Angler_BobberBottom" },
		["Ghostplank_BobberBottom"] = { 0.480, 0.540, 0.480, -0.097, 0.445, 0.104, "Angler_BobberBottom" },
		["Ghostplank_BobberTop"] = { 0.480, 0.460, 0.480, -0.097, 0.945, 0.104, "Angler_BobberBottom" },
		["Ghostplank_Grip"] = { 0.646, 1.600, 0.617, -0.126, -2.732, -0.928, "Angler_BobberBottom" },
		["Ghostplank_Line"] = { 0.172, 2.412, 1.061, -0.039, 2.371, -0.404, "Angler_BobberBottom" },
		["Ghostplank_Trim"] = { 0.675, 6.866, 0.766, -0.111, -0.249, -0.821, "Angler_BobberBottom" },
		["Ghostplank_Twig"] = { 0.857, 7.000, 0.199, -0.111, -0.182, -0.892, "Angler_BobberBottom" },
		["Gloomheart_BobberBottom"] = { 0.566, 0.452, 0.536, -0.064, 0.872, 1.035, "Angler_BobberBottom" },
		["Gloomheart_BobberTop"] = { 0.434, 0.480, 0.445, -0.064, 0.964, 0.976, "Angler_BobberBottom" },
		["Gloomheart_Grip"] = { 0.917, 1.930, 1.549, -0.127, -2.617, -0.581, "Angler_BobberBottom" },
		["Gloomheart_Line"] = { 0.111, 2.341, 1.232, -0.037, 2.423, 0.386, "Angler_BobberBottom" },
		["Gloomheart_Trim"] = { 0.913, 5.298, 1.017, -0.028, 0.685, -0.736, "Angler_BobberBottom" },
		["Gloomheart_Twig"] = { 1.380, 5.653, 1.411, 0.008, 0.755, -0.753, "Angler_BobberBottom" },
		["Inkveil_BobberBottom"] = { 0.418, 0.660, 0.429, -0.003, 0.572, 0.494, "Angler_BobberBottom" },
		["Inkveil_BobberTop"] = { 0.418, 0.400, 0.429, -0.003, 1.102, 0.494, "Angler_BobberBottom" },
		["Inkveil_Grip"] = { 0.582, 1.830, 1.315, -0.122, -2.617, -0.527, "Angler_BobberBottom" },
		["Inkveil_Line"] = { 0.112, 2.284, 1.099, 0.028, 2.435, -0.034, "Angler_BobberBottom" },
		["Inkveil_Trim"] = { 0.648, 7.415, 0.803, -0.129, 0.026, -0.819, "Angler_BobberBottom" },
		["Inkveil_Twig"] = { 0.748, 5.786, 0.620, -0.078, 0.675, -0.872, "Angler_BobberBottom" },
		["Krakenheart_BobberBottom"] = { 0.480, 0.280, 0.480, -0.055, 0.851, 1.134, "Angler_BobberBottom" },
		["Krakenheart_BobberTop"] = { 0.758, 0.354, 0.732, -0.055, 1.075, 1.134, "Angler_BobberBottom" },
		["Krakenheart_Grip"] = { 1.112, 1.930, 1.666, -0.141, -2.617, -0.630, "Angler_BobberBottom" },
		["Krakenheart_Line"] = { 0.111, 2.343, 1.233, -0.034, 2.410, 0.543, "Angler_BobberBottom" },
		["Krakenheart_Trim"] = { 1.376, 5.693, 1.959, -0.087, 0.897, -0.586, "Angler_BobberBottom" },
		["Krakenheart_Twig"] = { 1.339, 7.250, 1.776, -0.089, -0.057, -0.659, "Angler_BobberBottom" },
		["Lanternline_BobberBottom"] = { 0.400, 0.290, 0.346, -0.997, -0.225, 1.472, "Angler_BobberBottom" },
		["Lanternline_BobberTop"] = { 0.360, 0.300, 0.312, -0.997, 0.040, 1.472, "Angler_BobberBottom" },
		["Lanternline_Grip"] = { 0.571, 1.600, 0.563, -0.128, -2.732, -0.886, "Angler_BobberBottom" },
		["Lanternline_Line"] = { 0.152, 2.392, 1.100, -0.935, 1.358, 0.943, "Angler_BobberBottom" },
		["Lanternline_Trim"] = { 1.429, 7.148, 1.830, -0.530, -0.108, -0.287, "Angler_BobberBottom" },
		["Lanternline_Twig"] = { 1.616, 5.399, 1.829, -0.399, 0.766, -0.265, "Angler_BobberBottom" },
		["MagmaCore_BobberBottom"] = { 0.692, 0.376, 0.700, -0.032, 0.719, 0.843, "Angler_BobberBottom" },
		["MagmaCore_BobberTop"] = { 0.500, 0.440, 0.500, -0.068, 1.121, 0.803, "Angler_BobberBottom" },
		["MagmaCore_Grip"] = { 0.672, 2.530, 1.371, -0.129, -2.967, -0.510, "Angler_BobberBottom" },
		["MagmaCore_Line"] = { 0.118, 2.253, 1.184, -0.041, 2.454, 0.235, "Angler_BobberBottom" },
		["MagmaCore_Trim"] = { 0.583, 5.270, 0.979, -0.125, 1.103, -0.672, "Angler_BobberBottom" },
		["MagmaCore_Twig"] = { 0.501, 7.250, 0.889, -0.128, -0.057, -0.777, "Angler_BobberBottom" },
		["Mireheart_BobberBottom"] = { 0.360, 0.300, 0.360, -0.031, 0.581, 0.801, "Angler_BobberBottom" },
		["Mireheart_BobberTop"] = { 0.380, 0.560, 0.380, -0.031, 0.951, 0.801, "Angler_BobberBottom" },
		["Mireheart_Grip"] = { 1.298, 1.930, 1.747, -0.129, -2.617, -0.672, "Angler_BobberBottom" },
		["Mireheart_Line"] = { 0.128, 2.361, 1.190, 0.001, 2.400, 0.231, "Angler_BobberBottom" },
		["Mireheart_Trim"] = { 0.699, 4.875, 1.260, -0.060, 1.306, -0.507, "Angler_BobberBottom" },
		["Mireheart_Twig"] = { 1.478, 7.250, 1.648, -0.132, -0.057, -0.830, "Angler_BobberBottom" },
		["Obsidian_BobberBottom"] = { 0.480, 0.540, 0.480, -0.058, 0.463, 0.613, "Angler_BobberBottom" },
		["Obsidian_BobberTop"] = { 0.480, 0.460, 0.480, -0.058, 0.963, 0.613, "Angler_BobberBottom" },
		["Obsidian_Grip"] = { 0.609, 1.600, 0.603, -0.129, -2.732, -0.885, "Angler_BobberBottom" },
		["Obsidian_Line"] = { 0.132, 2.395, 1.102, -0.020, 2.380, 0.084, "Angler_BobberBottom" },
		["Obsidian_Trim"] = { 0.722, 7.430, 1.391, -0.084, 0.033, -0.527, "Angler_BobberBottom" },
		["Obsidian_Twig"] = { 0.481, 7.250, 0.665, -0.128, -0.057, -0.777, "Angler_BobberBottom" },
		["PhoenixAsh_BobberBottom"] = { 0.692, 0.376, 0.700, -0.044, 0.590, 0.636, "Angler_BobberBottom" },
		["PhoenixAsh_BobberTop"] = { 0.500, 0.440, 0.500, -0.080, 0.992, 0.596, "Angler_BobberBottom" },
		["PhoenixAsh_Grip"] = { 0.651, 1.880, 1.389, -0.131, -2.592, -0.530, "Angler_BobberBottom" },
		["PhoenixAsh_Line"] = { 0.108, 2.380, 1.149, -0.058, 2.390, 0.047, "Angler_BobberBottom" },
		["PhoenixAsh_Trim"] = { 0.798, 5.540, 0.920, -0.114, 1.388, -0.899, "Angler_BobberBottom" },
		["PhoenixAsh_Twig"] = { 1.024, 5.500, 0.978, -0.130, 0.818, -0.918, "Angler_BobberBottom" },
		["Reedlash_BobberBottom"] = { 0.180, 0.600, 0.180, 0.122, -0.035, 0.108, "Angler_BobberBottom" },
		["Reedlash_BobberTop"] = { 0.180, 0.800, 0.180, 0.122, 0.665, 0.108, "Angler_BobberBottom" },
		["Reedlash_Grip"] = { 0.510, 1.600, 0.500, -0.120, -2.732, -0.896, "Angler_BobberBottom" },
		["Reedlash_Line"] = { 0.199, 2.520, 1.053, 0.196, 2.316, -0.397, "Angler_BobberBottom" },
		["Reedlash_Trim"] = { 0.930, 3.935, 1.071, 0.044, 0.181, -0.843, "Angler_BobberBottom" },
		["Reedlash_Twig"] = { 0.775, 7.250, 0.556, 0.081, -0.057, -0.931, "Angler_BobberBottom" },
		["Reefmaw_BobberBottom"] = { 0.480, 0.540, 0.480, -0.025, 0.335, 0.242, "Angler_BobberBottom" },
		["Reefmaw_BobberTop"] = { 0.480, 0.460, 0.480, -0.025, 0.835, 0.242, "Angler_BobberBottom" },
		["Reefmaw_Grip"] = { 0.639, 1.600, 0.636, -0.122, -2.732, -0.895, "Angler_BobberBottom" },
		["Reefmaw_Line"] = { 0.185, 2.523, 1.060, 0.038, 2.316, -0.264, "Angler_BobberBottom" },
		["Reefmaw_Trim"] = { 0.765, 7.430, 1.412, -0.103, 0.033, -0.547, "Angler_BobberBottom" },
		["Reefmaw_Twig"] = { 0.439, 7.250, 0.492, -0.117, -0.057, -0.896, "Angler_BobberBottom" },
		["Riggingline_BobberBottom"] = { 0.180, 0.600, 0.180, -0.084, -0.146, 0.105, "Angler_BobberBottom" },
		["Riggingline_BobberTop"] = { 0.180, 0.800, 0.180, -0.084, 0.554, 0.105, "Angler_BobberBottom" },
		["Riggingline_Grip"] = { 0.557, 1.600, 0.555, -0.127, -2.732, -0.896, "Angler_BobberBottom" },
		["Riggingline_Line"] = { 0.198, 4.718, 1.047, -0.050, 1.217, -0.398, "Angler_BobberBottom" },
		["Riggingline_Trim"] = { 0.722, 7.420, 1.344, -0.090, 0.028, -0.551, "Angler_BobberBottom" },
		["Riggingline_Twig"] = { 0.361, 7.250, 0.370, -0.119, -0.057, -0.896, "Angler_BobberBottom" },
		["Rimebound_BobberBottom"] = { 0.480, 0.540, 0.480, -0.046, 0.353, 0.263, "Angler_BobberBottom" },
		["Rimebound_BobberTop"] = { 0.480, 0.460, 0.480, -0.046, 0.853, 0.263, "Angler_BobberBottom" },
		["Rimebound_Grip"] = { 0.619, 1.600, 0.617, -0.122, -2.732, -0.895, "Angler_BobberBottom" },
		["Rimebound_Line"] = { 0.152, 2.504, 1.100, 0.002, 2.325, -0.265, "Angler_BobberBottom" },
		["Rimebound_Trim"] = { 0.753, 6.455, 1.424, -0.098, -0.454, -0.530, "Angler_BobberBottom" },
		["Rimebound_Twig"] = { 0.491, 7.250, 0.479, -0.110, -0.057, -0.898, "Angler_BobberBottom" },
		["Riptide_BobberBottom"] = { 0.440, 0.260, 0.440, 0.064, 0.127, 0.200, "Angler_BobberBottom" },
		["Riptide_BobberTop"] = { 0.440, 0.680, 0.440, 0.064, 0.597, 0.200, "Angler_BobberBottom" },
		["Riptide_Grip"] = { 0.547, 1.600, 0.551, -0.131, -2.732, -0.898, "Angler_BobberBottom" },
		["Riptide_Line"] = { 0.126, 2.645, 0.997, 0.103, 2.252, -0.279, "Angler_BobberBottom" },
		["Riptide_Trim"] = { 0.722, 7.425, 1.695, -0.085, 0.030, -0.347, "Angler_BobberBottom" },
		["Riptide_Twig"] = { 0.460, 7.250, 0.555, -0.125, -0.057, -0.967, "Angler_BobberBottom" },
		["Sailcloth_BobberBottom"] = { 0.440, 0.260, 0.440, 0.129, 0.016, 0.163, "Angler_BobberBottom" },
		["Sailcloth_BobberTop"] = { 0.440, 0.680, 0.440, 0.129, 0.486, 0.163, "Angler_BobberBottom" },
		["Sailcloth_Grip"] = { 0.528, 1.600, 0.531, -0.130, -2.732, -0.898, "Angler_BobberBottom" },
		["Sailcloth_Line"] = { 0.136, 2.756, 0.983, 0.173, 2.197, -0.309, "Angler_BobberBottom" },
		["Sailcloth_Trim"] = { 1.364, 7.405, 1.284, 0.238, 0.021, -0.541, "Angler_BobberBottom" },
		["Sailcloth_Twig"] = { 0.445, 7.250, 0.323, -0.076, -0.057, -0.896, "Angler_BobberBottom" },
		["Silverscale_BobberBottom"] = { 0.440, 0.260, 0.440, -0.011, 0.000, 0.000, "Angler_BobberBottom" },
		["Silverscale_BobberTop"] = { 0.440, 0.680, 0.440, -0.011, 0.470, 0.000, "Angler_BobberBottom" },
		["Silverscale_Grip"] = { 0.528, 1.600, 0.531, -0.133, -2.732, -0.898, "Angler_BobberBottom" },
		["Silverscale_Line"] = { 0.133, 2.770, 0.932, 0.034, 2.189, -0.448, "Angler_BobberBottom" },
		["Silverscale_Trim"] = { 0.738, 7.300, 1.260, -0.096, 0.068, -0.548, "Angler_BobberBottom" },
		["Silverscale_Twig"] = { 0.300, 7.250, 0.300, -0.129, -0.057, -0.896, "Angler_BobberBottom" },
		["Squallcaster_BobberBottom"] = { 0.180, 0.600, 0.180, 0.082, -0.017, 0.147, "Angler_BobberBottom" },
		["Squallcaster_BobberTop"] = { 0.180, 0.800, 0.180, 0.082, 0.683, 0.147, "Angler_BobberBottom" },
		["Squallcaster_Grip"] = { 0.548, 1.600, 0.540, -0.119, -2.732, -0.895, "Angler_BobberBottom" },
		["Squallcaster_Line"] = { 0.189, 2.503, 1.096, 0.151, 2.325, -0.380, "Angler_BobberBottom" },
		["Squallcaster_Trim"] = { 1.192, 7.415, 1.501, -0.138, 0.026, -0.816, "Angler_BobberBottom" },
		["Squallcaster_Twig"] = { 0.480, 7.250, 0.551, -0.042, -0.057, -0.787, "Angler_BobberBottom" },
		["Thunderhead_BobberBottom"] = { 0.180, 0.600, 0.180, -0.094, 0.093, 0.272, "Angler_BobberBottom" },
		["Thunderhead_BobberTop"] = { 0.180, 0.800, 0.180, -0.094, 0.793, 0.272, "Angler_BobberBottom" },
		["Thunderhead_Grip"] = { 1.920, 1.630, 1.920, -0.129, -2.747, -0.896, "Angler_BobberBottom" },
		["Thunderhead_Line"] = { 0.109, 2.394, 1.099, -0.065, 2.380, -0.257, "Angler_BobberBottom" },
		["Thunderhead_Trim"] = { 0.722, 6.575, 1.425, -0.089, 0.855, -0.583, "Angler_BobberBottom" },
		["Thunderhead_Twig"] = { 0.400, 7.250, 0.346, -0.129, -0.057, -0.896, "Angler_BobberBottom" },
		["Trenchglass_BobberBottom"] = { 0.535, 0.300, 0.541, -0.069, 0.705, 0.227, "Angler_BobberBottom" },
		["Trenchglass_BobberTop"] = { 0.480, 0.387, 0.480, -0.069, 1.048, 0.227, "Angler_BobberBottom" },
		["Trenchglass_Grip"] = { 0.722, 1.960, 1.241, -0.087, -2.552, -0.528, "Angler_BobberBottom" },
		["Trenchglass_Line"] = { 0.116, 2.517, 1.049, -0.023, 2.406, -0.279, "Angler_BobberBottom" },
		["Trenchglass_Trim"] = { 0.554, 7.340, 0.742, -0.114, -0.012, -0.810, "Angler_BobberBottom" },
		["Trenchglass_Twig"] = { 0.455, 5.191, 0.374, -0.100, 0.693, -0.892, "Angler_BobberBottom" },
		["Twig_BobberBottom"] = { 0.480, 0.540, 0.480, 0.052, 0.463, 0.148, "Angler_BobberBottom" },
		["Twig_BobberTop"] = { 0.480, 0.460, 0.480, 0.052, 0.963, 0.148, "Angler_BobberBottom" },
		["Twig_Grip"] = { 0.596, 1.600, 0.585, -0.124, -2.732, -0.885, "Angler_BobberBottom" },
		["Twig_Line"] = { 0.222, 2.395, 1.102, 0.135, 2.380, -0.381, "Angler_BobberBottom" },
		["Twig_Trim"] = { 0.518, 2.750, 0.812, -0.076, -0.237, -0.676, "Angler_BobberBottom" },
		["Twig_Twig"] = { 0.457, 7.250, 0.443, -0.100, -0.057, -0.911, "Angler_BobberBottom" },
		["Voidline_BobberBottom"] = { 0.160, 0.140, 0.160, -0.100, 1.232, 0.445, "Angler_BobberBottom" },
		["Voidline_BobberTop"] = { 0.700, 0.666, 0.140, -0.100, 0.962, 0.445, "Angler_BobberBottom" },
		["Voidline_Grip"] = { 0.799, 1.670, 0.840, -0.129, -2.767, -0.896, "Angler_BobberBottom" },
		["Voidline_Line"] = { 0.095, 2.286, 1.103, -0.067, 2.435, -0.084, "Angler_BobberBottom" },
		["Voidline_Trim"] = { 0.126, 5.744, 0.889, -0.113, 0.390, -0.489, "Angler_BobberBottom" },
		["Voidline_Twig"] = { 0.560, 5.504, 0.396, -0.126, 0.819, -0.790, "Angler_BobberBottom" },
		["Wisplight_BobberBottom"] = { 0.692, 0.376, 0.700, 0.030, 0.609, 0.679, "Angler_BobberBottom" },
		["Wisplight_BobberTop"] = { 0.500, 0.440, 0.500, -0.006, 1.011, 0.640, "Angler_BobberBottom" },
		["Wisplight_Grip"] = { 0.552, 1.600, 0.544, -0.128, -2.732, -0.886, "Angler_BobberBottom" },
		["Wisplight_Line"] = { 0.132, 2.358, 1.183, 0.032, 2.400, 0.070, "Angler_BobberBottom" },
		["Wisplight_Trim"] = { 0.865, 6.586, 1.414, -0.013, -0.389, -0.603, "Angler_BobberBottom" },
		["Wisplight_Twig"] = { 0.351, 7.282, 0.910, -0.123, -0.041, -0.927, "Angler_BobberBottom" },
		["Wraithheart_BobberBottom"] = { 0.692, 0.376, 0.700, -0.032, 0.609, 0.594, "Angler_BobberBottom" },
		["Wraithheart_BobberTop"] = { 0.500, 0.440, 0.500, -0.068, 1.011, 0.554, "Angler_BobberBottom" },
		["Wraithheart_Grip"] = { 0.714, 2.034, 1.512, -0.129, -2.645, -0.458, "Angler_BobberBottom" },
		["Wraithheart_Line"] = { 0.108, 2.361, 1.190, -0.046, 2.400, -0.015, "Angler_BobberBottom" },
		["Wraithheart_Trim"] = { 1.352, 5.405, 0.985, -0.163, 1.471, -0.630, "Angler_BobberBottom" },
		["Wraithheart_Twig"] = { 0.521, 7.250, 0.460, -0.128, -0.057, -0.815, "Angler_BobberBottom" },
	},
	WeaponPack = {
		["AbyssalHarpooner_Action"] = { 0.488, 2.285, 0.545, 0.000, 0.000, 0.000, "AbyssalHarpooner_Action" },
		["AbyssalHarpooner_Grip"] = { 0.551, 0.440, 0.295, -0.109, -1.006, -0.011, "AbyssalHarpooner_Action" },
		["AbyssalHarpooner_Guard"] = { 0.270, 0.400, 0.100, -0.205, -0.840, -0.003, "AbyssalHarpooner_Action" },
		["AbyssalHarpooner_Haft"] = { 0.772, 3.060, 0.270, -0.101, -0.340, -0.003, "AbyssalHarpooner_Action" },
		["AbyssalHarpooner_Head"] = { 0.350, 2.777, 0.494, 0.085, -0.162, -0.003, "AbyssalHarpooner_Action" },
		["AbyssalHarpooner_Mag"] = { 0.460, 0.453, 0.340, -0.130, -0.240, -0.003, "AbyssalHarpooner_Action" },
		["AbyssalHarpooner_Muzzle"] = { 0.100, 0.100, 0.100, 0.210, 1.340, -0.003, "AbyssalHarpooner_Action" },
		["AbyssalHarpooner_Pommel"] = { 0.320, 0.100, 0.250, 0.030, -1.820, -0.003, "AbyssalHarpooner_Action" },
		["AbyssalHarpooner_Sight"] = { 0.140, 1.660, 0.130, 0.360, -0.045, -0.003, "AbyssalHarpooner_Action" },
		["AbyssalHarpooner_Spike"] = { 0.480, 2.680, 0.210, 0.210, 0.000, -0.003, "AbyssalHarpooner_Action" },
		["AdmiralsSaber_Edge"] = { 0.423, 2.540, 0.120, 0.301, 0.870, -0.003, "AbyssalHarpooner_Action" },
		["AdmiralsSaber_Glow"] = { 0.168, 2.300, 0.077, 0.421, 0.950, -0.003, "AbyssalHarpooner_Action" },
		["AdmiralsSaber_Grip"] = { 0.230, 0.880, 0.266, 0.210, -1.160, -0.003, "AbyssalHarpooner_Action" },
		["AdmiralsSaber_Guard"] = { 0.797, 0.310, 0.180, 0.210, -0.585, -0.003, "AbyssalHarpooner_Action" },
		["AdmiralsSaber_Haft"] = { 0.170, 1.100, 0.196, 0.210, -1.070, -0.003, "AbyssalHarpooner_Action" },
		["AdmiralsSaber_Head"] = { 0.301, 2.141, 0.116, 0.308, 0.820, -0.003, "AbyssalHarpooner_Action" },
		["AdmiralsSaber_Pommel"] = { 0.326, 0.288, 0.317, 0.210, -1.676, -0.012, "AbyssalHarpooner_Action" },
		["AdmiralsSaber_Spike"] = { 0.305, 1.020, 0.278, 0.221, -0.020, -0.003, "AbyssalHarpooner_Action" },
		["BasaltScattergun_Action"] = { 0.473, 0.317, 0.130, 0.183, -0.868, -0.003, "AbyssalHarpooner_Action" },
		["BasaltScattergun_Glow"] = { 0.260, 0.090, 0.360, 0.190, -0.760, -0.003, "AbyssalHarpooner_Action" },
		["BasaltScattergun_Grip"] = { 0.404, 0.572, 0.304, 0.014, -1.159, -0.011, "AbyssalHarpooner_Action" },
		["BasaltScattergun_Guard"] = { 0.290, 0.500, 0.110, 0.025, -0.880, -0.003, "AbyssalHarpooner_Action" },
		["BasaltScattergun_Haft"] = { 0.580, 1.820, 0.370, -0.090, -0.950, -0.003, "AbyssalHarpooner_Action" },
		["BasaltScattergun_Head"] = { 0.380, 0.493, 0.380, 0.150, -0.763, -0.003, "AbyssalHarpooner_Action" },
		["BasaltScattergun_Mag"] = { 0.365, 1.492, 0.580, 0.217, 0.024, -0.003, "AbyssalHarpooner_Action" },
		["BasaltScattergun_Muzzle"] = { 0.100, 0.100, 0.100, 0.210, 0.740, -0.003, "AbyssalHarpooner_Action" },
		["BasaltScattergun_Pommel"] = { 0.600, 0.090, 0.270, -0.090, -1.830, -0.003, "AbyssalHarpooner_Action" },
		["BasaltScattergun_Sight"] = { 0.080, 0.070, 0.070, 0.340, 0.600, -0.003, "AbyssalHarpooner_Action" },
		["BoardingAxe_Edge"] = { 0.954, 0.960, 0.190, 0.827, 0.980, -0.003, "AbyssalHarpooner_Action" },
		["BoardingAxe_Glow"] = { 0.150, 0.599, 0.088, 1.191, 0.979, -0.003, "AbyssalHarpooner_Action" },
		["BoardingAxe_Grip"] = { 0.289, 1.040, 0.334, 0.210, -1.160, -0.003, "AbyssalHarpooner_Action" },
		["BoardingAxe_Guard"] = { 0.429, 1.230, 0.418, 0.210, 0.825, -0.014, "AbyssalHarpooner_Action" },
		["BoardingAxe_Haft"] = { 0.199, 2.920, 0.230, 0.210, -0.340, -0.003, "AbyssalHarpooner_Action" },
		["BoardingAxe_Head"] = { 0.358, 0.463, 0.255, 0.270, 1.308, -0.001, "AbyssalHarpooner_Action" },
		["BoardingAxe_Pommel"] = { 0.240, 0.140, 0.230, 0.210, -1.790, -0.003, "AbyssalHarpooner_Action" },
		["BoardingAxe_Spike"] = { 0.656, 0.430, 0.300, 0.036, 1.060, -0.003, "AbyssalHarpooner_Action" },
		["BogwoodBow_Action"] = { 2.620, 0.130, 0.050, 0.210, -1.540, -0.003, "AbyssalHarpooner_Action" },
		["BogwoodBow_Grip"] = { 0.320, 0.263, 0.257, 0.030, -1.240, -0.010, "AbyssalHarpooner_Action" },
		["BogwoodBow_Haft"] = { 2.453, 0.741, 0.170, 0.210, -1.401, -0.003, "AbyssalHarpooner_Action" },
		["BogwoodBow_Mag"] = { 0.265, 2.530, 0.172, 0.210, -0.325, -0.027, "AbyssalHarpooner_Action" },
		["BogwoodBow_Muzzle"] = { 0.100, 0.100, 0.100, 0.210, 0.940, -0.003, "AbyssalHarpooner_Action" },
		["BogwoodBow_Sight"] = { 0.435, 0.110, 0.160, 0.372, -1.070, -0.058, "AbyssalHarpooner_Action" },
		["BogwoodBow_Spike"] = { 2.620, 0.220, 0.084, 0.210, -1.650, -0.003, "AbyssalHarpooner_Action" },
		["CinderlockCarbine_Action"] = { 0.593, 0.700, 0.350, 0.053, -0.400, -0.053, "AbyssalHarpooner_Action" },
		["CinderlockCarbine_Edge"] = { 0.267, 1.310, 0.124, 0.281, 0.595, -0.003, "AbyssalHarpooner_Action" },
		["CinderlockCarbine_Grip"] = { 0.558, 0.463, 0.295, -0.109, -0.806, -0.011, "AbyssalHarpooner_Action" },
		["CinderlockCarbine_Guard"] = { 0.270, 0.400, 0.100, -0.205, -0.660, -0.003, "AbyssalHarpooner_Action" },
		["CinderlockCarbine_Haft"] = { 0.965, 2.530, 0.270, -0.003, -0.585, -0.003, "AbyssalHarpooner_Action" },
		["CinderlockCarbine_Head"] = { 0.500, 1.750, 0.270, 0.190, -0.025, -0.003, "AbyssalHarpooner_Action" },
		["CinderlockCarbine_Mag"] = { 0.879, 0.339, 0.253, -0.491, -0.456, -0.003, "AbyssalHarpooner_Action" },
		["CinderlockCarbine_Muzzle"] = { 0.100, 0.100, 0.100, 0.210, 1.390, -0.003, "AbyssalHarpooner_Action" },
		["CinderlockCarbine_Pommel"] = { 0.620, 0.100, 0.270, -0.090, -1.820, -0.003, "AbyssalHarpooner_Action" },
		["CinderlockCarbine_Sight"] = { 0.140, 0.070, 0.130, 0.350, 0.000, -0.003, "AbyssalHarpooner_Action" },
		["CinderlockCarbine_Spike"] = { 0.537, 0.408, 0.170, 0.371, 1.224, -0.003, "AbyssalHarpooner_Action" },
		["CutlassOfTheFleet_Edge"] = { 0.790, 2.160, 0.130, 0.425, 0.660, -0.003, "AbyssalHarpooner_Action" },
		["CutlassOfTheFleet_Glow"] = { 0.296, 1.821, 0.078, 0.653, 0.700, -0.003, "AbyssalHarpooner_Action" },
		["CutlassOfTheFleet_Grip"] = { 0.251, 0.800, 0.290, 0.210, -1.210, -0.003, "AbyssalHarpooner_Action" },
		["CutlassOfTheFleet_Guard"] = { 1.084, 1.562, 0.200, 0.267, -0.873, -0.003, "AbyssalHarpooner_Action" },
		["CutlassOfTheFleet_Haft"] = { 0.173, 0.980, 0.200, 0.210, -1.070, -0.003, "AbyssalHarpooner_Action" },
		["CutlassOfTheFleet_Head"] = { 0.511, 1.792, 0.128, 0.417, 0.641, -0.003, "AbyssalHarpooner_Action" },
		["CutlassOfTheFleet_Pommel"] = { 0.268, 0.300, 0.238, 0.210, -1.620, -0.003, "AbyssalHarpooner_Action" },
		["CutlassOfTheFleet_Spike"] = { 0.331, 0.858, 0.132, 0.368, 0.228, -0.003, "AbyssalHarpooner_Action" },
		["CycloneRifle_Action"] = { 0.538, 0.282, 0.280, 0.005, -0.484, -0.003, "AbyssalHarpooner_Action" },
		["CycloneRifle_Edge"] = { 0.116, 1.260, 0.116, 0.210, 0.790, -0.003, "AbyssalHarpooner_Action" },
		["CycloneRifle_Grip"] = { 0.551, 0.443, 0.285, -0.129, -0.606, -0.011, "AbyssalHarpooner_Action" },
		["CycloneRifle_Guard"] = { 0.270, 0.400, 0.100, -0.225, -0.420, -0.003, "AbyssalHarpooner_Action" },
		["CycloneRifle_Haft"] = { 0.880, 2.780, 0.330, -0.065, -0.430, -0.003, "AbyssalHarpooner_Action" },
		["CycloneRifle_Head"] = { 0.495, 0.790, 0.305, 0.087, -0.205, -0.026, "AbyssalHarpooner_Action" },
		["CycloneRifle_Mag"] = { 1.030, 0.287, 0.253, -0.567, -0.237, -0.003, "AbyssalHarpooner_Action" },
		["CycloneRifle_Muzzle"] = { 0.100, 0.100, 0.100, 0.210, 1.590, -0.003, "AbyssalHarpooner_Action" },
		["CycloneRifle_Pommel"] = { 0.400, 0.100, 0.260, 0.110, -1.810, -0.003, "AbyssalHarpooner_Action" },
		["CycloneRifle_Sight"] = { 0.304, 0.709, 0.130, 0.452, -0.234, -0.003, "AbyssalHarpooner_Action" },
		["CycloneRifle_Spike"] = { 0.431, 0.590, 0.164, 0.354, 1.295, -0.003, "AbyssalHarpooner_Action" },
		["DriftwoodClub_Grip"] = { 0.468, 1.000, 0.456, 0.210, -1.160, -0.015, "AbyssalHarpooner_Action" },
		["DriftwoodClub_Haft"] = { 0.574, 3.053, 0.470, 0.225, -0.313, -0.013, "AbyssalHarpooner_Action" },
		["DriftwoodClub_Head"] = { 0.470, 0.503, 0.400, 0.212, 1.281, -0.013, "AbyssalHarpooner_Action" },
		["DriftwoodClub_Spike"] = { 0.886, 0.888, 0.344, 0.228, 0.231, -0.018, "AbyssalHarpooner_Action" },
		["Drowncleaver_Edge"] = { 0.940, 2.040, 0.170, 0.320, 0.820, -0.003, "AbyssalHarpooner_Action" },
		["Drowncleaver_Glow"] = { 0.415, 1.336, 0.240, 0.262, 0.978, -0.003, "AbyssalHarpooner_Action" },
		["Drowncleaver_Grip"] = { 0.320, 0.840, 0.312, 0.210, -1.160, -0.012, "AbyssalHarpooner_Action" },
		["Drowncleaver_Guard"] = { 0.440, 0.200, 0.280, 0.270, -0.280, -0.003, "AbyssalHarpooner_Action" },
		["Drowncleaver_Haft"] = { 0.331, 1.510, 0.298, 0.210, -1.095, -0.003, "AbyssalHarpooner_Action" },
		["Drowncleaver_Spike"] = { 0.312, 0.610, 0.304, 0.210, -1.170, -0.011, "AbyssalHarpooner_Action" },
		["Fenreaver_Edge"] = { 0.900, 1.820, 0.120, 0.180, 1.030, -0.003, "AbyssalHarpooner_Action" },
		["Fenreaver_Glow"] = { 0.454, 1.407, 0.136, 0.357, 1.059, -0.003, "AbyssalHarpooner_Action" },
		["Fenreaver_Grip"] = { 0.345, 0.920, 0.336, 0.210, -1.160, -0.012, "AbyssalHarpooner_Action" },
		["Fenreaver_Guard"] = { 0.361, 0.180, 0.352, 0.210, 0.070, -0.013, "AbyssalHarpooner_Action" },
		["Fenreaver_Haft"] = { 0.417, 1.813, 0.325, 0.239, -0.778, -0.001, "AbyssalHarpooner_Action" },
		["Fenreaver_Pommel"] = { 0.358, 0.320, 0.323, 0.210, -1.690, -0.003, "AbyssalHarpooner_Action" },
		["FrostbiteRevolver_Action"] = { 0.654, 0.418, 0.100, 0.163, -1.392, -0.003, "AbyssalHarpooner_Action" },
		["FrostbiteRevolver_Edge"] = { 0.236, 0.710, 0.164, 0.163, -0.415, -0.003, "AbyssalHarpooner_Action" },
		["FrostbiteRevolver_Glow"] = { 0.050, 0.440, 0.270, 0.260, -0.440, -0.003, "AbyssalHarpooner_Action" },
		["FrostbiteRevolver_Grip"] = { 0.509, 0.533, 0.304, -0.117, -1.517, -0.011, "AbyssalHarpooner_Action" },
		["FrostbiteRevolver_Guard"] = { 0.220, 0.340, 0.100, -0.100, -1.260, -0.003, "AbyssalHarpooner_Action" },
		["FrostbiteRevolver_Haft"] = { 0.860, 1.164, 0.285, -0.020, -1.322, -0.011, "AbyssalHarpooner_Action" },
		["FrostbiteRevolver_Head"] = { 0.070, 0.700, 0.110, 0.300, -0.440, -0.003, "AbyssalHarpooner_Action" },
		["FrostbiteRevolver_Mag"] = { 0.515, 0.990, 0.493, 0.035, -0.835, -0.003, "AbyssalHarpooner_Action" },
		["FrostbiteRevolver_Muzzle"] = { 0.100, 0.100, 0.100, 0.210, -0.060, -0.003, "AbyssalHarpooner_Action" },
		["FrostbiteRevolver_Pommel"] = { 0.160, 0.080, 0.200, -0.340, -1.830, -0.003, "AbyssalHarpooner_Action" },
		["FrostbiteRevolver_Sight"] = { 0.105, 1.135, 0.120, 0.362, -0.722, -0.003, "AbyssalHarpooner_Action" },
		["FrostboreRifle_Action"] = { 0.536, 0.394, 0.466, 0.024, -0.523, -0.160, "AbyssalHarpooner_Action" },
		["FrostboreRifle_Edge"] = { 0.170, 1.960, 0.170, 0.210, 1.060, -0.003, "AbyssalHarpooner_Action" },
		["FrostboreRifle_Grip"] = { 0.393, 0.642, 0.295, -0.006, -0.809, -0.011, "AbyssalHarpooner_Action" },
		["FrostboreRifle_Guard"] = { 0.270, 0.400, 0.100, -0.205, -0.540, -0.003, "AbyssalHarpooner_Action" },
		["FrostboreRifle_Haft"] = { 0.735, 2.860, 0.260, -0.058, -0.420, -0.003, "AbyssalHarpooner_Action" },
		["FrostboreRifle_Head"] = { 0.320, 0.800, 0.260, 0.140, -0.240, -0.003, "AbyssalHarpooner_Action" },
		["FrostboreRifle_Mag"] = { 0.379, 0.170, 0.253, -0.258, -0.200, -0.003, "AbyssalHarpooner_Action" },
		["FrostboreRifle_Muzzle"] = { 0.100, 0.100, 0.100, 0.210, 2.040, -0.003, "AbyssalHarpooner_Action" },
		["FrostboreRifle_Pommel"] = { 0.660, 0.080, 0.260, -0.090, -1.830, -0.003, "AbyssalHarpooner_Action" },
		["FrostboreRifle_Sight"] = { 0.308, 1.220, 0.216, 0.464, -0.050, -0.003, "AbyssalHarpooner_Action" },
		["FrostboreRifle_Spike"] = { 0.128, 0.090, 0.128, 0.210, 1.990, -0.003, "AbyssalHarpooner_Action" },
		["Galecleaver_Edge"] = { 1.560, 1.000, 0.210, 0.210, 1.320, -0.003, "AbyssalHarpooner_Action" },
		["Galecleaver_Glow"] = { 1.496, 0.768, 0.082, 0.210, 1.191, -0.003, "AbyssalHarpooner_Action" },
		["Galecleaver_Grip"] = { 0.284, 1.120, 0.328, 0.210, -1.160, -0.003, "AbyssalHarpooner_Action" },
		["Galecleaver_Guard"] = { 0.445, 0.920, 0.433, 0.210, 1.260, -0.015, "AbyssalHarpooner_Action" },
		["Galecleaver_Haft"] = { 0.199, 2.900, 0.230, 0.210, -0.150, -0.003, "AbyssalHarpooner_Action" },
		["Galecleaver_Head"] = { 0.340, 0.840, 0.310, 0.210, 1.520, -0.003, "AbyssalHarpooner_Action" },
		["Galecleaver_Pommel"] = { 0.358, 0.358, 0.340, 0.210, -1.651, -0.003, "AbyssalHarpooner_Action" },
		["Galecleaver_Spike"] = { 1.169, 0.492, 0.168, 0.210, 1.336, -0.003, "AbyssalHarpooner_Action" },
		["GatorjawCrossbow_Action"] = { 0.553, 1.207, 2.418, 0.053, -0.353, -0.003, "AbyssalHarpooner_Action" },
		["GatorjawCrossbow_Edge"] = { 0.170, 0.463, 2.428, 0.210, 0.428, -0.003, "AbyssalHarpooner_Action" },
		["GatorjawCrossbow_Glow"] = { 0.089, 0.100, 0.085, 0.450, -0.140, -0.003, "AbyssalHarpooner_Action" },
		["GatorjawCrossbow_Grip"] = { 0.395, 0.570, 0.295, 0.014, -1.109, -0.011, "AbyssalHarpooner_Action" },
		["GatorjawCrossbow_Guard"] = { 0.270, 0.400, 0.100, -0.185, -0.920, -0.003, "AbyssalHarpooner_Action" },
		["GatorjawCrossbow_Haft"] = { 0.670, 2.750, 0.250, 0.005, -0.485, -0.003, "AbyssalHarpooner_Action" },
		["GatorjawCrossbow_Head"] = { 0.220, 0.300, 0.220, 0.030, -0.420, -0.003, "AbyssalHarpooner_Action" },
		["GatorjawCrossbow_Mag"] = { 0.180, 1.220, 0.110, 0.230, 0.330, -0.003, "AbyssalHarpooner_Action" },
		["GatorjawCrossbow_Muzzle"] = { 0.100, 0.100, 0.100, 0.210, 0.940, -0.003, "AbyssalHarpooner_Action" },
		["GatorjawCrossbow_Pommel"] = { 0.540, 0.090, 0.240, -0.070, -1.830, -0.003, "AbyssalHarpooner_Action" },
		["GatorjawCrossbow_Sight"] = { 0.150, 0.920, 0.120, 0.385, 0.285, -0.003, "AbyssalHarpooner_Action" },
		["GatorjawCrossbow_Spike"] = { 0.694, 0.964, 2.000, -0.062, 0.479, -0.003, "AbyssalHarpooner_Action" },
		["GlacierMaul_Glow"] = { 0.708, 0.819, 0.740, 0.177, 1.834, -0.003, "AbyssalHarpooner_Action" },
		["GlacierMaul_Grip"] = { 0.334, 1.240, 0.386, 0.210, -1.060, -0.003, "AbyssalHarpooner_Action" },
		["GlacierMaul_Guard"] = { 0.507, 0.340, 0.494, 0.210, 1.390, -0.016, "AbyssalHarpooner_Action" },
		["GlacierMaul_Haft"] = { 0.251, 3.140, 0.290, 0.210, -0.070, -0.003, "AbyssalHarpooner_Action" },
		["GlacierMaul_Head"] = { 1.380, 1.020, 0.680, 0.240, 1.830, -0.003, "AbyssalHarpooner_Action" },
		["GlacierMaul_Pommel"] = { 0.334, 0.066, 0.386, 0.210, -1.520, -0.003, "AbyssalHarpooner_Action" },
		["GlacierMaul_Spike"] = { 1.840, 4.020, 0.295, 0.230, 0.170, 0.004, "AbyssalHarpooner_Action" },
		["GloomcallerDmr_Action"] = { 0.523, 0.677, 0.250, 0.018, -0.098, -0.103, "AbyssalHarpooner_Action" },
		["GloomcallerDmr_Edge"] = { 0.156, 1.440, 0.156, 0.210, 1.000, -0.003, "AbyssalHarpooner_Action" },
		["GloomcallerDmr_Glow"] = { 0.070, 0.620, 0.320, 0.190, -0.140, -0.003, "AbyssalHarpooner_Action" },
		["GloomcallerDmr_Grip"] = { 0.544, 0.418, 0.285, -0.129, -0.556, -0.011, "AbyssalHarpooner_Action" },
		["GloomcallerDmr_Guard"] = { 0.270, 0.400, 0.100, -0.205, -0.400, -0.003, "AbyssalHarpooner_Action" },
		["GloomcallerDmr_Haft"] = { 0.771, 2.860, 0.290, -0.121, -0.430, -0.003, "AbyssalHarpooner_Action" },
		["GloomcallerDmr_Head"] = { 0.340, 0.880, 0.270, 0.130, -0.140, -0.003, "AbyssalHarpooner_Action" },
		["GloomcallerDmr_Mag"] = { 0.896, 0.207, 0.253, -0.478, -0.247, -0.003, "AbyssalHarpooner_Action" },
		["GloomcallerDmr_Muzzle"] = { 0.100, 0.100, 0.100, 0.210, 1.940, -0.003, "AbyssalHarpooner_Action" },
		["GloomcallerDmr_Pommel"] = { 0.560, 0.090, 0.250, -0.010, -1.830, -0.003, "AbyssalHarpooner_Action" },
		["GloomcallerDmr_Sight"] = { 0.315, 1.160, 0.210, 0.477, 0.060, -0.003, "AbyssalHarpooner_Action" },
		["GloomcallerDmr_Spike"] = { 0.200, 0.260, 0.200, 0.210, 1.830, -0.003, "AbyssalHarpooner_Action" },
		["GraveBlunderbuss_Action"] = { 0.743, 0.442, 0.229, 0.168, -0.556, -0.093, "AbyssalHarpooner_Action" },
		["GraveBlunderbuss_Edge"] = { 0.647, 1.410, 0.680, 0.210, 0.285, -0.003, "AbyssalHarpooner_Action" },
		["GraveBlunderbuss_Grip"] = { 0.412, 0.611, 0.304, 0.014, -1.059, -0.011, "AbyssalHarpooner_Action" },
		["GraveBlunderbuss_Guard"] = { 0.270, 0.400, 0.100, -0.165, -0.740, -0.003, "AbyssalHarpooner_Action" },
		["GraveBlunderbuss_Haft"] = { 0.680, 2.360, 0.290, -0.110, -0.680, -0.003, "AbyssalHarpooner_Action" },
		["GraveBlunderbuss_Head"] = { 0.369, 0.460, 0.323, 0.234, -0.540, -0.030, "AbyssalHarpooner_Action" },
		["GraveBlunderbuss_Mag"] = { 0.060, 0.925, 0.070, 0.040, 0.163, -0.003, "AbyssalHarpooner_Action" },
		["GraveBlunderbuss_Muzzle"] = { 0.100, 0.100, 0.100, 0.210, 0.990, -0.003, "AbyssalHarpooner_Action" },
		["GraveBlunderbuss_Pommel"] = { 0.700, 0.090, 0.290, -0.110, -1.830, -0.003, "AbyssalHarpooner_Action" },
		["GraveBlunderbuss_Sight"] = { 0.090, 0.050, 0.050, 0.375, -0.300, -0.003, "AbyssalHarpooner_Action" },
		["GraveBlunderbuss_Spike"] = { 0.694, 1.305, 0.730, 0.210, 0.343, -0.003, "AbyssalHarpooner_Action" },
		["Heartrender_Edge"] = { 1.149, 2.880, 0.361, 0.210, 0.600, -0.013, "AbyssalHarpooner_Action" },
		["Heartrender_Glow"] = { 0.899, 1.830, 0.272, 0.210, 0.325, -0.003, "AbyssalHarpooner_Action" },
		["Heartrender_Grip"] = { 0.384, 0.840, 0.374, 0.210, -1.140, -0.013, "AbyssalHarpooner_Action" },
		["Heartrender_Haft"] = { 0.273, 0.980, 0.266, 0.210, -1.070, -0.010, "AbyssalHarpooner_Action" },
		["Heartrender_Spike"] = { 0.430, 0.410, 0.430, 0.210, -1.645, -0.003, "AbyssalHarpooner_Action" },
		["IcepickHatchet_Edge"] = { 1.880, 0.595, 0.176, 0.290, 0.438, -0.003, "AbyssalHarpooner_Action" },
		["IcepickHatchet_Glow"] = { 1.197, 0.250, 0.210, 0.230, 0.420, -0.003, "AbyssalHarpooner_Action" },
		["IcepickHatchet_Grip"] = { 0.248, 0.920, 0.286, 0.210, -1.360, -0.003, "AbyssalHarpooner_Action" },
		["IcepickHatchet_Guard"] = { 0.463, 0.496, 0.370, 0.291, 0.418, -0.003, "AbyssalHarpooner_Action" },
		["IcepickHatchet_Haft"] = { 0.165, 2.290, 0.190, 0.210, -0.665, -0.003, "AbyssalHarpooner_Action" },
		["IcepickHatchet_Head"] = { 0.440, 0.260, 0.240, 0.230, 0.480, -0.003, "AbyssalHarpooner_Action" },
		["IcepickHatchet_Pommel"] = { 0.200, 0.120, 0.190, 0.210, -1.800, -0.003, "AbyssalHarpooner_Action" },
		["IcepickHatchet_Spike"] = { 0.110, 0.105, 0.310, 0.230, 0.480, -0.003, "AbyssalHarpooner_Action" },
		["Krakenfang_Edge"] = { 0.963, 2.860, 0.150, 0.451, 1.110, -0.003, "AbyssalHarpooner_Action" },
		["Krakenfang_Glow"] = { 0.670, 3.847, 0.315, 0.477, 0.168, -0.003, "AbyssalHarpooner_Action" },
		["Krakenfang_Grip"] = { 0.281, 0.920, 0.324, 0.210, -1.110, -0.003, "AbyssalHarpooner_Action" },
		["Krakenfang_Guard"] = { 1.081, 2.872, 0.250, 0.249, 0.731, -0.003, "AbyssalHarpooner_Action" },
		["Krakenfang_Haft"] = { 0.199, 1.120, 0.230, 0.210, -1.000, -0.003, "AbyssalHarpooner_Action" },
		["Krakenfang_Head"] = { 0.497, 2.359, 0.104, 0.633, 1.137, -0.003, "AbyssalHarpooner_Action" },
		["Krakenfang_Pommel"] = { 0.360, 0.250, 0.320, 0.220, -1.685, -0.003, "AbyssalHarpooner_Action" },
		["Krakenfang_Spike"] = { 0.222, 0.192, 0.141, 0.510, 0.840, -0.003, "AbyssalHarpooner_Action" },
		["MagmaGauntlets_Edge"] = { 0.502, 2.250, 0.925, 0.457, 0.065, -0.021, "AbyssalHarpooner_Action" },
		["MagmaGauntlets_Glow"] = { 0.835, 1.055, 0.719, 0.275, -1.237, -0.003, "AbyssalHarpooner_Action" },
		["MagmaGauntlets_Grip"] = { 0.612, 0.520, 0.597, 0.210, -1.240, -0.019, "AbyssalHarpooner_Action" },
		["MagmaGauntlets_Guard"] = { 0.784, 0.947, 0.750, 0.226, -1.387, -0.003, "AbyssalHarpooner_Action" },
		["MagmaGauntlets_Haft"] = { 0.690, 0.930, 0.690, 0.210, -1.335, -0.003, "AbyssalHarpooner_Action" },
		["MagmaGauntlets_Spike"] = { 0.258, 0.678, 0.856, 0.580, 1.001, -0.003, "AbyssalHarpooner_Action" },
		["MireFlintlock_Action"] = { 0.688, 0.471, 0.229, 0.180, -1.161, -0.093, "AbyssalHarpooner_Action" },
		["MireFlintlock_Edge"] = { 0.200, 1.080, 0.200, 0.210, -0.600, -0.003, "AbyssalHarpooner_Action" },
		["MireFlintlock_Glow"] = { 0.334, 1.038, 0.260, 0.148, -0.839, -0.003, "AbyssalHarpooner_Action" },
		["MireFlintlock_Grip"] = { 0.478, 0.487, 0.285, -0.077, -1.457, -0.011, "AbyssalHarpooner_Action" },
		["MireFlintlock_Guard"] = { 0.210, 0.320, 0.100, -0.095, -1.360, -0.003, "AbyssalHarpooner_Action" },
		["MireFlintlock_Haft"] = { 0.830, 0.917, 0.314, -0.096, -1.458, -0.012, "AbyssalHarpooner_Action" },
		["MireFlintlock_Head"] = { 0.320, 0.270, 0.088, 0.250, -1.135, -0.147, "AbyssalHarpooner_Action" },
		["MireFlintlock_Mag"] = { 0.056, 0.890, 0.060, 0.075, -0.555, -0.003, "AbyssalHarpooner_Action" },
		["MireFlintlock_Muzzle"] = { 0.100, 0.100, 0.100, 0.210, -0.060, -0.003, "AbyssalHarpooner_Action" },
		["MireFlintlock_Pommel"] = { 0.250, 0.200, 0.221, -0.420, -1.830, -0.003, "AbyssalHarpooner_Action" },
		["MireFlintlock_Sight"] = { 0.115, 1.175, 0.110, 0.342, -0.783, -0.003, "AbyssalHarpooner_Action" },
		["MireFlintlock_Spike"] = { 0.216, 0.060, 0.216, 0.210, -1.000, -0.003, "AbyssalHarpooner_Action" },
		["ObsidianPiercer_Edge"] = { 0.550, 1.920, 0.230, 0.210, 0.680, -0.003, "AbyssalHarpooner_Action" },
		["ObsidianPiercer_Glow"] = { 0.422, 0.851, 0.260, 0.220, 0.450, -0.003, "AbyssalHarpooner_Action" },
		["ObsidianPiercer_Grip"] = { 0.346, 0.720, 0.329, 0.210, -1.220, -0.021, "AbyssalHarpooner_Action" },
		["ObsidianPiercer_Guard"] = { 0.652, 0.354, 0.271, 0.179, -0.330, -0.018, "AbyssalHarpooner_Action" },
		["ObsidianPiercer_Haft"] = { 0.342, 1.390, 0.326, 0.210, -1.135, -0.021, "AbyssalHarpooner_Action" },
		["ObsidianPiercer_Spike"] = { 0.076, 0.316, 0.184, 0.247, 1.458, -0.003, "AbyssalHarpooner_Action" },
		["PhantomRepeater_Action"] = { 0.446, 0.508, 0.090, -0.147, -0.578, -0.003, "AbyssalHarpooner_Action" },
		["PhantomRepeater_Edge"] = { 0.176, 1.530, 0.176, 0.210, 0.825, -0.003, "AbyssalHarpooner_Action" },
		["PhantomRepeater_Glow"] = { 0.200, 2.120, 0.300, 0.210, 0.550, -0.003, "AbyssalHarpooner_Action" },
		["PhantomRepeater_Grip"] = { 0.386, 0.602, 0.295, 0.014, -0.759, -0.011, "AbyssalHarpooner_Action" },
		["PhantomRepeater_Guard"] = { 0.270, 0.400, 0.100, -0.185, -0.580, -0.003, "AbyssalHarpooner_Action" },
		["PhantomRepeater_Haft"] = { 0.560, 2.540, 0.260, -0.070, -0.580, -0.003, "AbyssalHarpooner_Action" },
		["PhantomRepeater_Head"] = { 0.320, 0.720, 0.250, 0.140, -0.280, -0.003, "AbyssalHarpooner_Action" },
		["PhantomRepeater_Mag"] = { 0.118, 1.300, 0.136, 0.055, 0.770, -0.003, "AbyssalHarpooner_Action" },
		["PhantomRepeater_Muzzle"] = { 0.100, 0.100, 0.100, 0.210, 1.590, -0.003, "AbyssalHarpooner_Action" },
		["PhantomRepeater_Pommel"] = { 0.610, 0.235, 0.260, -0.070, -1.757, -0.003, "AbyssalHarpooner_Action" },
		["PhantomRepeater_Sight"] = { 0.140, 1.300, 0.150, 0.350, 0.775, -0.003, "AbyssalHarpooner_Action" },
		["RimefangLance_Edge"] = { 0.470, 1.100, 0.360, 0.210, 2.190, -0.003, "AbyssalHarpooner_Action" },
		["RimefangLance_Glow"] = { 0.448, 1.106, 0.437, 0.210, 2.047, -0.015, "AbyssalHarpooner_Action" },
		["RimefangLance_Grip"] = { 0.268, 1.100, 0.310, 0.210, -0.960, -0.003, "AbyssalHarpooner_Action" },
		["RimefangLance_Guard"] = { 0.448, 0.380, 0.437, 0.210, 1.530, -0.015, "AbyssalHarpooner_Action" },
		["RimefangLance_Haft"] = { 0.182, 3.060, 0.210, 0.210, -0.030, -0.003, "AbyssalHarpooner_Action" },
		["RimefangLance_Pommel"] = { 0.275, 0.059, 0.318, 0.210, -1.500, -0.003, "AbyssalHarpooner_Action" },
		["RimefangLance_Spike"] = { 0.774, 3.572, 0.774, 0.210, -0.074, -0.003, "AbyssalHarpooner_Action" },
		["RiptideSmg_Action"] = { 0.533, 0.567, 0.250, 0.023, -0.833, -0.103, "AbyssalHarpooner_Action" },
		["RiptideSmg_Edge"] = { 0.184, 0.560, 0.184, 0.210, -0.240, -0.003, "AbyssalHarpooner_Action" },
		["RiptideSmg_Grip"] = { 0.537, 0.401, 0.295, -0.109, -1.236, -0.011, "AbyssalHarpooner_Action" },
		["RiptideSmg_Guard"] = { 0.350, 0.590, 0.270, -0.165, -0.985, -0.003, "AbyssalHarpooner_Action" },
		["RiptideSmg_Haft"] = { 0.792, 0.801, 0.348, -0.110, -1.440, -0.003, "AbyssalHarpooner_Action" },
		["RiptideSmg_Head"] = { 0.410, 0.940, 0.320, 0.175, -0.940, -0.028, "AbyssalHarpooner_Action" },
		["RiptideSmg_Mag"] = { 1.007, 0.221, 0.264, -0.658, -0.837, -0.003, "AbyssalHarpooner_Action" },
		["RiptideSmg_Muzzle"] = { 0.100, 0.100, 0.100, 0.210, 0.040, -0.003, "AbyssalHarpooner_Action" },
		["RiptideSmg_Pommel"] = { 0.120, 0.090, 0.140, 0.040, -1.800, -0.003, "AbyssalHarpooner_Action" },
		["RiptideSmg_Sight"] = { 0.220, 1.300, 0.205, 0.370, -0.720, -0.003, "AbyssalHarpooner_Action" },
		["RiptideSmg_Spike"] = { 0.200, 0.215, 0.200, 0.210, -0.370, -0.003, "AbyssalHarpooner_Action" },
		["RustfangMachete_Edge"] = { 0.530, 2.120, 0.110, 0.245, 0.380, -0.003, "AbyssalHarpooner_Action" },
		["RustfangMachete_Grip"] = { 0.312, 0.760, 0.304, 0.210, -1.240, -0.011, "AbyssalHarpooner_Action" },
		["RustfangMachete_Guard"] = { 0.302, 0.140, 0.295, 0.210, -0.730, -0.011, "AbyssalHarpooner_Action" },
		["RustfangMachete_Haft"] = { 0.253, 0.940, 0.247, 0.210, -1.250, -0.010, "AbyssalHarpooner_Action" },
		["RustfangMachete_Pommel"] = { 0.322, 0.160, 0.314, 0.210, -1.720, -0.012, "AbyssalHarpooner_Action" },
		["RustfangMachete_Spike"] = { 0.142, 1.693, 0.124, 0.361, 0.435, -0.003, "AbyssalHarpooner_Action" },
		["Scaleblade_Edge"] = { 0.540, 1.870, 0.120, 0.260, 0.305, -0.003, "AbyssalHarpooner_Action" },
		["Scaleblade_Grip"] = { 0.349, 0.800, 0.340, 0.210, -1.260, -0.012, "AbyssalHarpooner_Action" },
		["Scaleblade_Haft"] = { 0.341, 0.900, 0.333, 0.210, -1.210, -0.012, "AbyssalHarpooner_Action" },
		["Scaleblade_Pommel"] = { 0.351, 0.350, 0.342, 0.210, -1.685, -0.012, "AbyssalHarpooner_Action" },
		["Scaleblade_Spike"] = { 0.924, 2.122, 0.200, 0.192, 0.121, -0.003, "AbyssalHarpooner_Action" },
		["Shellcrusher_Grip"] = { 0.411, 1.100, 0.401, 0.210, -1.060, -0.014, "AbyssalHarpooner_Action" },
		["Shellcrusher_Guard"] = { 0.302, 0.459, 0.330, 0.210, 0.722, -0.003, "AbyssalHarpooner_Action" },
		["Shellcrusher_Haft"] = { 0.516, 2.606, 0.334, 0.268, -0.525, 0.002, "AbyssalHarpooner_Action" },
		["Shellcrusher_Head"] = { 1.468, 1.039, 0.660, 0.316, 1.120, -0.003, "AbyssalHarpooner_Action" },
		["Shellcrusher_Spike"] = { 1.255, 0.832, 0.800, 0.246, 1.309, -0.003, "AbyssalHarpooner_Action" },
		["Stormlance_Edge"] = { 0.430, 1.080, 0.230, 0.210, 2.200, -0.003, "AbyssalHarpooner_Action" },
		["Stormlance_Glow"] = { 1.021, 1.633, 0.260, 0.210, 1.804, -0.003, "AbyssalHarpooner_Action" },
		["Stormlance_Grip"] = { 0.268, 1.100, 0.310, 0.210, -0.960, -0.003, "AbyssalHarpooner_Action" },
		["Stormlance_Guard"] = { 0.402, 0.300, 0.392, 0.210, 1.570, -0.014, "AbyssalHarpooner_Action" },
		["Stormlance_Haft"] = { 0.182, 3.060, 0.210, 0.210, 0.010, -0.003, "AbyssalHarpooner_Action" },
		["Stormlance_Head"] = { 1.320, 0.980, 0.110, 0.210, 1.350, -0.003, "AbyssalHarpooner_Action" },
		["Stormlance_Pommel"] = { 0.263, 0.055, 0.304, 0.210, -1.480, -0.003, "AbyssalHarpooner_Action" },
		["Stormlance_Spike"] = { 0.236, 2.183, 0.272, 0.210, -0.769, -0.003, "AbyssalHarpooner_Action" },
		["ThunderheadCannon_Action"] = { 0.773, 0.595, 0.130, 0.163, -1.421, -0.003, "AbyssalHarpooner_Action" },
		["ThunderheadCannon_Edge"] = { 0.470, 1.240, 0.470, 0.210, -0.280, -0.003, "AbyssalHarpooner_Action" },
		["ThunderheadCannon_Glow"] = { 0.316, 1.670, 0.400, 0.168, -0.475, -0.003, "AbyssalHarpooner_Action" },
		["ThunderheadCannon_Grip"] = { 0.630, 0.571, 0.361, -0.128, -1.355, -0.013, "AbyssalHarpooner_Action" },
		["ThunderheadCannon_Guard"] = { 0.250, 0.380, 0.130, -0.175, -1.200, -0.003, "AbyssalHarpooner_Action" },
		["ThunderheadCannon_Haft"] = { 0.869, 1.044, 0.340, -0.065, -1.392, -0.003, "AbyssalHarpooner_Action" },
		["ThunderheadCannon_Mag"] = { 0.500, 0.435, 0.500, 0.210, -1.097, -0.003, "AbyssalHarpooner_Action" },
		["ThunderheadCannon_Muzzle"] = { 0.100, 0.100, 0.100, 0.210, 0.340, -0.003, "AbyssalHarpooner_Action" },
		["ThunderheadCannon_Pommel"] = { 0.180, 0.100, 0.240, -0.380, -1.820, -0.003, "AbyssalHarpooner_Action" },
		["ThunderheadCannon_Sight"] = { 0.160, 0.985, 0.130, 0.450, -0.423, -0.003, "AbyssalHarpooner_Action" },
		["ThunderheadCannon_Spike"] = { 0.971, 1.988, 0.470, -0.041, -0.854, -0.003, "AbyssalHarpooner_Action" },
		["Trenchspike_Edge"] = { 1.480, 0.430, 0.120, 0.210, 0.225, -0.003, "AbyssalHarpooner_Action" },
		["Trenchspike_Glow"] = { 0.055, 0.680, 0.210, 0.210, 0.770, -0.003, "AbyssalHarpooner_Action" },
		["Trenchspike_Grip"] = { 0.253, 0.920, 0.292, 0.210, -1.260, -0.003, "AbyssalHarpooner_Action" },
		["Trenchspike_Guard"] = { 0.234, 0.240, 0.270, 0.210, 0.140, -0.003, "AbyssalHarpooner_Action" },
		["Trenchspike_Haft"] = { 0.173, 1.860, 0.200, 0.210, -0.830, -0.003, "AbyssalHarpooner_Action" },
		["Trenchspike_Head"] = { 0.600, 0.940, 0.184, 0.210, 0.670, -0.003, "AbyssalHarpooner_Action" },
		["Trenchspike_Pommel"] = { 0.206, 0.200, 0.196, 0.210, -1.750, -0.003, "AbyssalHarpooner_Action" },
		["Trenchspike_Spike"] = { 0.227, 0.485, 0.262, 0.210, -0.440, -0.003, "AbyssalHarpooner_Action" },
		["VoidglassSaber_Edge"] = { 1.160, 2.360, 0.120, 0.670, 0.760, -0.003, "AbyssalHarpooner_Action" },
		["VoidglassSaber_Glow"] = { 1.111, 3.470, 0.410, 0.588, 0.089, -0.003, "AbyssalHarpooner_Action" },
		["VoidglassSaber_Grip"] = { 0.241, 0.840, 0.278, 0.210, -1.160, -0.003, "AbyssalHarpooner_Action" },
		["VoidglassSaber_Guard"] = { 0.745, 0.149, 0.220, 0.210, -0.500, -0.003, "AbyssalHarpooner_Action" },
		["VoidglassSaber_Haft"] = { 0.173, 1.080, 0.200, 0.210, -1.100, -0.003, "AbyssalHarpooner_Action" },
		["VoidglassSaber_Head"] = { 0.952, 2.061, 0.136, 0.628, 0.745, -0.003, "AbyssalHarpooner_Action" },
		["VoidglassSaber_Pommel"] = { 0.295, 0.335, 0.264, 0.210, -1.687, -0.003, "AbyssalHarpooner_Action" },
		["VulkanRepeater_Action"] = { 0.568, 0.662, 0.285, 0.020, -0.346, -0.121, "AbyssalHarpooner_Action" },
		["VulkanRepeater_Edge"] = { 0.200, 1.380, 0.200, 0.210, 0.850, -0.003, "AbyssalHarpooner_Action" },
		["VulkanRepeater_Glow"] = { 0.330, 2.350, 0.360, 0.210, 0.595, -0.003, "AbyssalHarpooner_Action" },
		["VulkanRepeater_Grip"] = { 0.561, 0.466, 0.323, -0.129, -0.805, -0.012, "AbyssalHarpooner_Action" },
		["VulkanRepeater_Guard"] = { 0.270, 0.400, 0.120, -0.225, -0.640, -0.003, "AbyssalHarpooner_Action" },
		["VulkanRepeater_Haft"] = { 0.780, 1.296, 0.270, -0.121, -1.212, -0.003, "AbyssalHarpooner_Action" },
		["VulkanRepeater_Head"] = { 0.380, 1.470, 0.310, 0.140, -0.025, -0.003, "AbyssalHarpooner_Action" },
		["VulkanRepeater_Mag"] = { 0.710, 0.628, 0.400, -0.245, -0.360, -0.003, "AbyssalHarpooner_Action" },
		["VulkanRepeater_Muzzle"] = { 0.100, 0.100, 0.100, 0.210, 1.740, -0.003, "AbyssalHarpooner_Action" },
		["VulkanRepeater_Pommel"] = { 0.580, 0.100, 0.270, -0.070, -1.820, -0.003, "AbyssalHarpooner_Action" },
		["VulkanRepeater_Sight"] = { 0.345, 1.915, 0.130, 0.462, 0.307, -0.003, "AbyssalHarpooner_Action" },
		["VulkanRepeater_Spike"] = { 0.474, 1.455, 0.370, 0.133, 1.022, -0.003, "AbyssalHarpooner_Action" },
	},
	WrackArena = {
		["WrackArena_Base"] = { 349.464, 18.350, 352.975, 0.000, 0.000, 0.000, "WrackArena_Base" },
		["WrackArena_DecoGhostGlow"] = { 328.842, 21.900, 312.081, -2.489, 10.618, 3.748, "WrackArena_Base" },
		["WrackArena_DecoIronwork"] = { 290.583, 19.935, 215.246, -10.042, 4.052, 24.150, "WrackArena_Base" },
		["WrackArena_DecoSailRag"] = { 282.699, 25.665, 250.909, 0.910, 24.494, 5.421, "WrackArena_Base" },
		["WrackArena_DecoShallows"] = { 346.341, 13.677, 344.820, 1.948, 2.434, 2.221, "WrackArena_Base" },
		["WrackArena_DecoTideline"] = { 280.766, 1.031, 136.348, 2.640, 4.977, -71.173, "WrackArena_Base" },
		["WrackArena_Fleet"] = { 332.229, 53.330, 312.012, -0.047, 19.861, 10.760, "WrackArena_Base" },
		["WrackArena_FleetMasts"] = { 302.289, 54.578, 287.628, 1.697, 24.385, 12.178, "WrackArena_Base" },
		["WrackArena_FleetRibs"] = { 331.435, 29.773, 328.691, -4.676, 13.837, 4.317, "WrackArena_Base" },
		["WrackArena_Foam"] = { 335.555, 0.060, 335.557, 0.539, 4.575, 1.172, "WrackArena_Base" },
	},
	WrackPack = {
		["Wrack_Arm"] = { 4.583, 11.696, 9.443, 0.000, 0.000, 0.000, "Wrack_Arm" },
		["Wrack_Base"] = { 53.476, 2.838, 26.792, 13.695, -22.345, 0.011, "Wrack_Arm" },
		["Wrack_Boom"] = { 15.623, 9.734, 27.896, 13.924, -6.758, -18.536, "Wrack_Arm" },
		["Wrack_BoomTackle"] = { 2.969, 6.625, 4.728, 16.486, -7.534, -22.506, "Wrack_Arm" },
		["Wrack_CannonBowPort"] = { 12.394, 6.163, 9.911, 28.970, -9.991, 8.279, "Wrack_Arm" },
		["Wrack_CannonBowStbd"] = { 12.369, 6.163, 9.911, 28.983, -9.800, -8.852, "Wrack_Arm" },
		["Wrack_CannonSternPort"] = { 12.369, 6.163, 9.911, -1.397, -9.191, 8.279, "Wrack_Arm" },
		["Wrack_CannonSternStbd"] = { 12.394, 6.163, 9.911, -1.384, -9.000, -8.852, "Wrack_Arm" },
		["Wrack_Coat"] = { 6.008, 13.800, 8.510, -0.111, -4.795, -0.714, "Wrack_Arm" },
		["Wrack_Crust"] = { 37.966, 7.648, 15.343, 13.273, -19.127, -0.361, "Wrack_Arm" },
		["Wrack_EyeGlow"] = { 1.046, 0.900, 2.500, 0.043, 3.505, 0.813, "Wrack_Arm" },
		["Wrack_Facings"] = { 5.071, 12.274, 8.971, -0.196, 0.192, 0.324, "Wrack_Arm" },
		["Wrack_Figurehead"] = { 11.984, 8.995, 11.365, 36.058, -14.549, -0.287, "Wrack_Arm" },
		["Wrack_FigureheadGlow"] = { 3.817, 3.158, 0.960, 39.665, -11.799, -0.287, "Wrack_Arm" },
		["Wrack_Hat"] = { 3.739, 2.143, 7.840, -1.107, 4.826, 0.813, "Wrack_Arm" },
		["Wrack_Hatch1"] = { 3.295, 1.170, 3.400, 7.850, -11.501, 2.913, "Wrack_Arm" },
		["Wrack_Hatch2"] = { 2.895, 1.170, 3.400, 4.850, -11.037, 3.113, "Wrack_Arm" },
		["Wrack_Hatch3"] = { 2.740, 1.170, 3.400, 3.793, -10.919, -4.087, "Wrack_Arm" },
		["Wrack_HatchGlow"] = { 5.904, 0.979, 8.363, 5.841, -11.555, -0.516, "Wrack_Arm" },
		["Wrack_HeartCage"] = { 5.359, 7.028, 4.037, 16.793, -15.882, -0.287, "Wrack_Arm" },
		["Wrack_HeartGlow"] = { 3.614, 5.400, 3.800, 16.793, -16.295, -0.287, "Wrack_Arm" },
		["Wrack_Hull"] = { 41.000, 13.467, 14.528, 13.293, -15.262, -0.000, "Wrack_Arm" },
		["Wrack_HullCollider"] = { 43.837, 18.028, 29.928, 13.793, -13.109, -0.287, "Wrack_Arm" },
		["Wrack_Keel"] = { 45.280, 13.122, 10.340, 13.350, -16.650, -0.287, "Wrack_Arm" },
		["Wrack_Mast"] = { 37.815, 26.726, 23.500, 24.300, -8.632, 0.963, "Wrack_Arm" },
		["Wrack_MuzzleGlow"] = { 2.437, 2.031, 1.931, 14.575, -23.095, -0.385, "Wrack_Arm" },
		["Wrack_Pistol"] = { 4.118, 3.590, 0.817, -0.444, -3.870, -1.608, "Wrack_Arm" },
		["Wrack_Ribs"] = { 15.200, 10.285, 11.821, 16.793, -17.160, -0.346, "Wrack_Arm" },
		["Wrack_Rigging"] = { 49.157, 23.830, 23.571, 17.268, -9.259, 0.960, "Wrack_Arm" },
		["Wrack_Sabre"] = { 2.242, 6.864, 2.243, 2.015, 7.922, -2.792, "Wrack_Arm" },
		["Wrack_Sail"] = { 3.384, 12.941, 21.055, 7.293, -6.913, 2.135, "Wrack_Arm" },
		["Wrack_ShellLower"] = { 12.000, 11.459, 9.195, 16.793, -16.486, -2.334, "Wrack_Arm" },
		["Wrack_ShellUpper"] = { 12.000, 11.438, 6.667, 16.793, -16.475, 3.023, "Wrack_Arm" },
		["Wrack_Skull"] = { 3.958, 4.601, 3.406, -0.745, 2.904, 0.813, "Wrack_Arm" },
		["Wrack_Sponsons"] = { 44.549, 13.132, 30.508, 13.793, -10.244, -0.267, "Wrack_Arm" },
		["Wrack_Strakes"] = { 40.298, 14.548, 13.810, 13.261, -14.874, -0.255, "Wrack_Arm" },
	},
}
-- GEOMETRY END

-- Tolerance for the geometry comparison: 2% of the expected number, but never
-- less than 0.2 studs (a 3-stud detail part cannot be held to 0.06 studs -
-- Studio rounds MeshPart sizes, and a welded corner moves a face by a hair).
local GEOM_TOL_FRACTION = 0.02
local GEOM_TOL_MIN = 0.2

--[[
	THE SOUND PACK is not a 3D import and this script cannot create it: the
	Sounds come from Asset Manager -> Bulk Import -> Audio, dragged into a
	Folder named `SoundPack` under Assets. What it CAN do is check it, and the
	check reads the expected names from the generated catalogue at run time
	rather than hard-coding them - `src/Shared/Config/SoundSprites.luau` is
	regenerated whenever the audio pack changes (a pass currently in flight is
	re-cutting the sheets into ~10 `audio_sfx_N` / `audio_music_N` /
	`audio_ambience_N` bundles), and a list copied into this file would be
	wrong by the time you ran it.

	Every map in the module whose values are file basenames is read: `sheets`,
	`music`, `ambience`, and `files` if a future generator writes one. A Sound's
	Name is the only lookup key there is - `Sfx` finds a sheet by
	`SoundSprites.sheets[key]` and MusicController a track by `.music[key]` /
	`.ambience[key]`, both with FindFirstChild - so a renamed or missing Sound
	is silence with no error.
]]
local SOUND_MAPS = { "files", "sheets", "music", "ambience" }

--=====================================================================
-- IMPORT STRATEGY CHAIN (lifted from studio_import.lua)
--=====================================================================

--[[
	AssetImportService's surface differs between Studio builds and is not
	documented, so rather than bet on one method we try known shapes in order
	and take the first that yields an Instance. Each attempt is its own pcall,
	so a missing method costs one line in the report, not the run.
]]
local STRATEGIES = {
	{
		name = "ImportMesh(path)",
		run = function(path)
			return AssetImportService:ImportMesh(path)
		end,
	},
	{
		name = "ImportMesh(path, {})",
		run = function(path)
			return AssetImportService:ImportMesh(path, {})
		end,
	},
	{
		name = "ImportFile(path)",
		run = function(path)
			return AssetImportService:ImportFile(path)
		end,
	},
	{
		name = "LoadFile(path) -> session:Import()",
		run = function(path)
			local session = AssetImportService:LoadFile(path)
			if session == nil then
				return nil
			end
			if typeof(session) == "Instance" and session:IsA("Model") then
				return session
			end
			local ok, result = pcall(function()
				return session:Import()
			end)
			if ok and result ~= nil then
				return result
			end
			return nil
		end,
	},
	{
		name = "StartSession(path) -> session:Import()",
		run = function(path)
			local session = AssetImportService:StartSession(path)
			if session == nil then
				return nil
			end
			local ok, result = pcall(function()
				return session:Import()
			end)
			if ok and result ~= nil then
				return result
			end
			local ok2, result2 = pcall(function()
				return session:GetInstance()
			end)
			if ok2 then
				return result2
			end
			return nil
		end,
	},
	{
		name = "ImportMeshUserMayChooseModel(path) (dialog-driven)",
		run = function(path)
			return AssetImportService:ImportMeshUserMayChooseModel(path)
		end,
	},
}

--=====================================================================
-- HELPERS
--=====================================================================

local report = {}
local function say(line)
	table.insert(report, line)
end

local function snapshot(container)
	local seen = {}
	for _, child in ipairs(container:GetChildren()) do
		seen[child] = true
	end
	return seen
end

local function findNew(container, before)
	for _, child in ipairs(container:GetChildren()) do
		if not before[child] then
			return child
		end
	end
	return nil
end

local function countParts(root)
	local n = 0
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			n = n + 1
		end
	end
	return n
end

local function topLevelCount(root)
	local n = 0
	for _, child in ipairs(root:GetChildren()) do
		if child:IsA("BasePart") or child:IsA("Model") or child:IsA("Folder") then
			n = n + 1
		end
	end
	return n
end

local function namesPresent(root)
	local present = {}
	for _, d in ipairs(root:GetDescendants()) do
		present[d.Name] = true
	end
	present[root.Name] = true
	return present
end

--[[
	Studio's glTF importer wraps a mesh node in a Model named `<object>_Node`.
	Our pack wrappers are Empties, which come in under their plain name - but
	builds differ, so a `_Node` suffix is stripped when matching a top-level
	child to a pack rather than betting on one behaviour.
]]
local function packNameOf(instance)
	local name = instance.Name
	local stripped = string.match(name, "^(.*)_Node$")
	if stripped and RULES[stripped] then
		return stripped
	end
	return name
end

-- The pack groups are the Empties bundle_gen.py wrote, but Studio's importer
-- may nest them under one or two extra Models (`Scene`, the file name, a
-- `_Node` wrapper) depending on the build - so packs are searched for at ANY
-- depth, not just as direct children of the import.
local function findPackGroups(root)
	local groups = {}
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("Model") or d:IsA("Folder") then
			local pack = packNameOf(d)
			if RULES[pack] and groups[pack] == nil then
				groups[pack] = d
			end
		end
	end
	return groups
end

local function applyFidelity(root, rules)
	local applied = {}
	if rules == nil then
		return applied
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("MeshPart") then
			for _, rule in ipairs(rules) do
				local pattern, fidelity = rule[1], rule[2]
				if string.find(d.Name, pattern, 1, true) then
					local ok = pcall(function()
						d.CollisionFidelity = fidelity
					end)
					if ok then
						table.insert(applied, d.Name .. " -> " .. fidelity.Name)
					else
						table.insert(applied, d.Name .. " -> FAILED (" .. fidelity.Name .. ")")
					end
					break
				end
			end
		end
	end
	return applied
end

local function applyMaterials(root)
	local set = {}
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") and NEON[d.Name] then
			local ok = pcall(function()
				d.Material = Enum.Material.Neon
			end)
			table.insert(set, d.Name .. (ok and " -> Neon" or " -> FAILED"))
		end
	end
	return set
end

local function assertNotNeon(root)
	local findings = {}
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			for _, guarded in ipairs(MUST_NOT_BE_NEON) do
				if d.Name == guarded then
					if d.Material == Enum.Material.Neon then
						table.insert(findings, d.Name .. " IS NEON - it must not be; set it back by hand")
					else
						table.insert(findings, d.Name .. " is " .. d.Material.Name .. " (correct: not Neon)")
					end
				end
			end
		end
	end
	return findings
end

--[[
	GEOMETRY VERIFICATION - the only check here that is not a name check.

	`assets/bundle_gen.py` measured every object's world bounding box in the
	very bundle on disk and spliced the numbers in above. This measures the
	imported MeshParts and compares.

	TWO THINGS MAKE IT AWKWARD, and both are handled below:
	  * Studio SPLITS a multi-material object into `Name`, `Name2`, `Name3`...
	    (Island_Base is one Blender object with grass/sand/wet-sand materials
	    and arrives as three MeshParts). The union box of that family is the
	    object's box, so parts are bucketed by the table key they belong to -
	    longest match first, one trailing digit at a time, so a real name that
	    ENDS in a digit (`BrinejawArena_ReefStone1`, `BrinejawFx_Spike3`) is
	    matched as itself and its own split `...ReefStone12` folds into it.
	  * An imported MeshPart's CFrame axes are meaningless (rotation is baked
	    into the geometry), so the box is taken from the eight transformed
	    corners rather than from `Size` alone - that is correct either way.

	Centres are compared RELATIVE to the pack's anchor object, so it does not
	matter where Studio dropped the import or where the game moves the pack.
]]
local function partBounds(part)
	local cf, half = part.CFrame, part.Size * 0.5
	local low, high
	for _, sx in ipairs({ -1, 1 }) do
		for _, sy in ipairs({ -1, 1 }) do
			for _, sz in ipairs({ -1, 1 }) do
				local corner = cf:PointToWorldSpace(Vector3.new(sx * half.X, sy * half.Y, sz * half.Z))
				if low == nil then
					low, high = corner, corner
				else
					low = Vector3.new(math.min(low.X, corner.X), math.min(low.Y, corner.Y), math.min(low.Z, corner.Z))
					high =
						Vector3.new(math.max(high.X, corner.X), math.max(high.Y, corner.Y), math.max(high.Z, corner.Z))
				end
			end
		end
	end
	return low, high
end

-- Which table key a MeshPart's geometry belongs to, or nil if the table has
-- never heard of it. Exact name wins; otherwise trailing digits are peeled off
-- one at a time (Studio's multi-material split suffix).
local function geometryKey(rows, name)
	if rows[name] ~= nil then
		return name
	end
	local trimmed = name
	while true do
		local stem = string.match(trimmed, "^(.+)%d$")
		if stem == nil then
			return nil
		end
		if rows[stem] ~= nil then
			return stem
		end
		trimmed = stem
	end
end

local function geometryTolerance(want)
	return math.max(GEOM_TOL_MIN, math.abs(want) * GEOM_TOL_FRACTION)
end

local function verifyGeometry(pack, group)
	local lines = {}
	local rows = GEOMETRY[pack]
	if rows == nil or next(rows) == nil then
		table.insert(
			lines,
			"geometry: NO TABLE for this pack - run `blender --background --python assets/bundle_gen.py`"
				.. " to splice one in, then re-run this script. NOTHING about the size or the"
		)
		table.insert(lines, "          layout of this import has been verified.")
		return lines
	end

	-- Bucket the parts, union-ing each multi-material family into one box.
	local boxes, unknown = {}, {}
	for _, d in ipairs(group:GetDescendants()) do
		if d:IsA("MeshPart") then
			local key = geometryKey(rows, d.Name)
			if key == nil then
				table.insert(unknown, d.Name)
			else
				local low, high = partBounds(d)
				local box = boxes[key]
				if box == nil then
					boxes[key] = { low = low, high = high, parts = 1 }
				else
					box.low =
						Vector3.new(math.min(box.low.X, low.X), math.min(box.low.Y, low.Y), math.min(box.low.Z, low.Z))
					box.high = Vector3.new(
						math.max(box.high.X, high.X),
						math.max(box.high.Y, high.Y),
						math.max(box.high.Z, high.Z)
					)
					box.parts = box.parts + 1
				end
			end
		end
	end

	local centres = {}
	for key, box in pairs(boxes) do
		centres[key] = (box.low + box.high) * 0.5
	end

	local rowCount = 0
	for _ in pairs(rows) do
		rowCount = rowCount + 1
	end

	local verified, sizeBad, centreBad, missing = 0, {}, {}, {}
	local noAnchor = {}
	-- The spread of got/want across every axis worth measuring: a single ratio
	-- shared by all of them IS the dialog-scale fingerprint.
	local ratioLow, ratioHigh, ratioCount = math.huge, -math.huge, 0

	for name, row in pairs(rows) do
		local box = boxes[name]
		if box == nil then
			table.insert(missing, name)
			continue
		end
		local got = box.high - box.low
		local want = Vector3.new(row[1], row[2], row[3])
		local sizeOk = math.abs(got.X - want.X) <= geometryTolerance(want.X)
			and math.abs(got.Y - want.Y) <= geometryTolerance(want.Y)
			and math.abs(got.Z - want.Z) <= geometryTolerance(want.Z)

		for _, axis in ipairs({ "X", "Y", "Z" }) do
			-- Sub-stud axes (a flat plate's thickness) are all rounding noise;
			-- a ratio taken off one would drown the real signal.
			if want[axis] > 1 then
				local ratio = got[axis] / want[axis]
				ratioLow = math.min(ratioLow, ratio)
				ratioHigh = math.max(ratioHigh, ratio)
				ratioCount = ratioCount + 1
			end
		end

		local anchorCentre = centres[row[7]]
		local centreOk = nil
		if anchorCentre == nil then
			table.insert(noAnchor, name .. " (anchor " .. row[7] .. " not in the import)")
		else
			local gotOffset = centres[name] - anchorCentre
			local wantOffset = Vector3.new(row[4], row[5], row[6])
			centreOk = math.abs(gotOffset.X - wantOffset.X) <= geometryTolerance(wantOffset.X)
				and math.abs(gotOffset.Y - wantOffset.Y) <= geometryTolerance(wantOffset.Y)
				and math.abs(gotOffset.Z - wantOffset.Z) <= geometryTolerance(wantOffset.Z)
			if not centreOk then
				table.insert(
					centreBad,
					string.format(
						"%s centre off %s: got %.2f,%.2f,%.2f  expected %.2f,%.2f,%.2f",
						name,
						row[7],
						gotOffset.X,
						gotOffset.Y,
						gotOffset.Z,
						wantOffset.X,
						wantOffset.Y,
						wantOffset.Z
					)
				)
			end
		end

		if not sizeOk then
			table.insert(
				sizeBad,
				string.format(
					"%s size got %.2f,%.2f,%.2f  expected %.2f,%.2f,%.2f",
					name,
					got.X,
					got.Y,
					got.Z,
					want.X,
					want.Y,
					want.Z
				)
			)
		end
		if sizeOk and centreOk ~= false then
			verified = verified + 1
		end
	end

	local function listSome(label, entries, cap)
		table.insert(lines, label)
		for index, entry in ipairs(entries) do
			if index > cap then
				table.insert(lines, "          ... and " .. (#entries - cap) .. " more")
				break
			end
			table.insert(lines, "          " .. entry)
		end
	end

	if #sizeBad > 0 then
		listSome("geometry: " .. #sizeBad .. " of " .. rowCount .. " objects are the WRONG SIZE:", sizeBad, 12)
		local mid = (ratioLow + ratioHigh) * 0.5
		local uniform = ratioCount > 0 and (ratioHigh - ratioLow) <= 0.02 * math.max(math.abs(mid), 0.01)
		if uniform and math.abs(mid - 1) > GEOM_TOL_FRACTION then
			table.insert(
				lines,
				string.format(
					"          DIAGNOSIS: every axis of every object is off by the SAME ratio (%.4f-%.4f)"
						.. " - this bundle was imported with a scale of ~%.4g; re-import at 1"
						.. " (Scale Unit: Stud, no rescaling) and run this again.",
					ratioLow,
					ratioHigh,
					mid
				)
			)
		else
			table.insert(
				lines,
				string.format(
					"          DIAGNOSIS: the ratios are NOT uniform (%.4f-%.4f), so it is not a dialog"
						.. " scale - either the table is stale (re-run assets/bundle_gen.py after any"
						.. " generator change) or these meshes really did change.",
					ratioLow,
					ratioHigh
				)
			)
		end
	elseif #centreBad > 0 then
		listSome(
			"geometry: all " .. rowCount .. " sizes match but " .. #centreBad .. " centre(s) do NOT:",
			centreBad,
			12
		)
		table.insert(
			lines,
			"          DIAGNOSIS: SHIFTED or ROTATED import - the geometry is right and its placement"
				.. " is not. Re-import with Use Imported Pivot ON, no rotation and no rescaling, and"
				.. " check nothing was dragged in Workspace after the import."
		)
		table.insert(
			lines,
			"          (If EVERY pack reports this and the offsets are the expected ones with a"
				.. " SIGN FLIPPED on one axis, that is an axis convention, not your import - say so"
				.. " in assets/bundle_gen.py's world_aabb_rbx and regenerate the table.)"
		)
	elseif verified == 0 then
		-- No mismatches only because nothing MATCHED: "0 verified" must never
		-- read like a pass (the silent-absence shape - an empty check looks
		-- exactly like a check that succeeded).
		table.insert(lines, "geometry: NOTHING VERIFIED - not one of the " .. rowCount .. " objects in the table is in")
		table.insert(lines, "          this import. Wrong pack, or the table is stale - see the lines below.")
	else
		table.insert(
			lines,
			"geometry: "
				.. verified
				.. " objects verified (size within "
				.. math.floor(GEOM_TOL_FRACTION * 100)
				.. "% / "
				.. GEOM_TOL_MIN
				.. " studs, centre relative to the pack anchor)"
		)
	end

	if #missing > 0 then
		listSome("geometry: " .. #missing .. " object(s) in the table are ABSENT from the import:", missing, 10)
	end
	if #unknown > 0 then
		listSome(
			"geometry: " .. #unknown .. " imported MeshPart(s) the table does not know (stale table?):",
			unknown,
			10
		)
	end
	if #noAnchor > 0 then
		listSome("geometry: " .. #noAnchor .. " object(s) could not be placed - anchor missing:", noAnchor, 6)
	end
	return lines
end

-- Where a bundle container goes so it cannot render. A raw bundle left in
-- Workspace IS the scrambled world; ReplicatedStorage draws nothing.
local function getStagingFolder()
	local existing = ReplicatedStorage:FindFirstChild("ImportStaging")
	if existing then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "ImportStaging"
	folder.Parent = ReplicatedStorage
	return folder
end

local function getAssetsFolder()
	local existing = ReplicatedStorage:FindFirstChild("Assets")
	if existing then
		return existing, false
	end
	if DRY_RUN then
		return nil, true
	end
	local folder = Instance.new("Folder")
	folder.Name = "Assets"
	folder.Parent = ReplicatedStorage
	return folder, true
end

-- A bundle already sitting in Workspace from a hand import or an earlier run.
-- Recognised by its CONTENTS (a child named like one of its packs), never by
-- the name Studio gave the import, which is `Scene` as often as not.
local function findAdoptable(bundle)
	local wanted = {}
	for _, pack in ipairs(bundle.packs) do
		wanted[pack] = true
	end
	for _, container in ipairs({ workspace, ReplicatedStorage }) do
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Model") or child:IsA("Folder") then
				local hits = 0
				for pack in pairs(findPackGroups(child)) do
					if wanted[pack] then
						hits = hits + 1
					end
				end
				if hits > 0 and hits >= math.min(2, #bundle.packs) then
					return child, hits
				end
			end
		end
	end
	return nil, 0
end

local function importOne(path)
	local watched = { workspace, ReplicatedStorage }
	local before = {}
	for _, container in ipairs(watched) do
		before[container] = snapshot(container)
	end

	local tried = {}
	for _, strategy in ipairs(STRATEGIES) do
		local ok, result = pcall(strategy.run, path)
		if ok then
			if typeof(result) == "Instance" then
				return result, strategy.name, tried
			end
			for _, container in ipairs(watched) do
				local fresh = findNew(container, before[container])
				if fresh then
					return fresh, strategy.name, tried
				end
			end
			table.insert(tried, strategy.name .. ": returned nothing")
		else
			table.insert(tried, strategy.name .. ": " .. tostring(result))
		end
	end
	return nil, nil, tried
end

--=====================================================================
-- RUN
--=====================================================================

local timestamp = os.date("%Y%m%d_%H%M%S")
local oldGroups = {}
local misses = {}
local failures = 0
local moved = 0
local skipped = 0
local strays = {}
-- The packs SKIP_EXISTING left alone: a warning, never a success (the game is
-- still using whatever mesh was already there).
local skippedPacks = {}
-- Every bundle container this run moved out of Workspace, and whether it still
-- held anything when it went.
local stagedContainers = {}

say("")
say("================================================================")
say(DRY_RUN and "How-to-Fish BUNDLE import - DRY RUN (nothing imported)" or "How-to-Fish BUNDLE import - LIVE")
say("  bundles dir    : " .. BUNDLE_DIR)
say("  SKIP_EXISTING  : " .. tostring(SKIP_EXISTING))
say("  ADOPT_EXISTING : " .. tostring(ADOPT_EXISTING))
local packTotal = 0
for _, bundle in ipairs(BUNDLES) do
	packTotal = packTotal + #bundle.packs
end
say("  bundles        : " .. #BUNDLES .. "  (" .. packTotal .. " packs)")
say("================================================================")

local assets, createdAssets = getAssetsFolder()
if createdAssets then
	say(DRY_RUN and "* would CREATE ReplicatedStorage.Assets" or "* created ReplicatedStorage.Assets")
end

for _, bundle in ipairs(BUNDLES) do
	local path = BUNDLE_DIR .. bundle.file
	say("")
	say("================ " .. bundle.file .. "  (" .. #bundle.packs .. " packs)")

	local ok, err = pcall(function()
		if DRY_RUN then
			say("  PLAN: import " .. path)
			say("        and afterwards MOVE the import container to")
			say("        ReplicatedStorage.ImportStaging - a bundle left in Workspace renders as")
			say("        every pack inside it stacked at the import point, grey, sitting on y = 0.")
			local adoptedNow, hitsNow = findAdoptable(bundle)
			if adoptedNow then
				say(
					"  FOUND in place: '"
						.. adoptedNow:GetFullName()
						.. "' holds "
						.. hitsNow
						.. " of its "
						.. #bundle.packs
						.. " packs - would ADOPT it"
				)
			else
				say("  not found in Workspace yet - would try AssetImportService, else ask for a hand import")
			end
			for _, pack in ipairs(bundle.packs) do
				local rule = RULES[pack]
				local existing = assets and assets:FindFirstChild(pack) or nil
				local line = "        " .. pack .. "  [row " .. (rule and rule.row or "?") .. "]"
				if existing then
					if SKIP_EXISTING then
						line = line
							.. "  (EXISTS - would be LEFT ALONE: the OLD mesh stays in the"
							.. " game. Set SKIP_EXISTING = false to replace it.)"
					else
						line = line .. "  (EXISTS - would be renamed " .. pack .. "_old_" .. timestamp .. ")"
					end
				end
				say(line)
				if rule then
					say(
						"            sentinel "
							.. rule.sentinel
							.. (rule.expected and (", expect " .. rule.expected .. " objects") or ", no count stated")
					)
					if rule.fidelity then
						local parts = {}
						for _, entry in ipairs(rule.fidelity) do
							table.insert(parts, entry[1] .. "=" .. entry[2].Name)
						end
						say("            fidelity (" .. #rule.fidelity .. "): " .. table.concat(parts, ", "))
					else
						say("            fidelity: none - the row says it does not matter")
					end
				else
					say("            NO RULE for this pack name <-- fix the RULES table")
				end
			end
			return
		end

		local model, source
		if ADOPT_EXISTING then
			local adopted, hits = findAdoptable(bundle)
			if adopted then
				model, source = adopted, "adopted '" .. adopted:GetFullName() .. "' (" .. hits .. " packs inside)"
			end
		end
		if model == nil then
			local imported, strategyName, tried = importOne(path)
			if imported == nil then
				failures = failures + 1
				say("  FAILED: no import strategy worked.")
				for _, line in ipairs(tried) do
					say("          tried " .. line)
				end
				say("  MANUAL: File -> Import 3D... -> " .. path)
				say("          then run this script again - it will ADOPT the import from Workspace")
				return
			end
			model, source = imported, "imported via " .. strategyName
		end
		say("  " .. source)

		local wanted = {}
		for _, pack in ipairs(bundle.packs) do
			wanted[pack] = true
		end

		local groups = findPackGroups(model)
		for _, child in ipairs(model:GetChildren()) do
			local pack = packNameOf(child)
			if not wanted[pack] and next(findPackGroups(child)) == nil then
				table.insert(strays, bundle.file .. " -> " .. child.Name .. " (not a pack this bundle declares)")
			end
		end

		for _, pack in ipairs(bundle.packs) do
			local rule = RULES[pack]
			say("")
			say("  ---- " .. pack .. "  [row " .. (rule and rule.row or "?") .. "]")

			local existing = assets:FindFirstChild(pack)
			if existing and SKIP_EXISTING then
				skipped = skipped + 1
				table.insert(skippedPacks, pack)
				say("    SKIPPED (WARNING, not a success): already under Assets and SKIP_EXISTING is true.")
				say(
					"             top-level objects: " .. topLevelCount(existing) .. ", parts: " .. countParts(existing)
				)
				say("             THE OLD MESH IS STILL WHAT THE GAME USES. The freshly imported")
				say("             " .. pack .. " in this bundle was NOT installed; it stays in the")
				say("             container and is moved to ReplicatedStorage.ImportStaging below.")
				say("             To replace it: set SKIP_EXISTING = false at the top of this file and")
				say("             run again (the old pack is renamed " .. pack .. "_old_<timestamp>,")
				say("             never deleted).")
				continue
			end

			local group = groups[pack]
			if group == nil then
				failures = failures + 1
				say("    MISSING from the bundle <-- re-run assets/bundle_gen.py; the game will use a stand-in")
				table.insert(misses, pack .. " (whole pack)")
				continue
			end

			if existing then
				local oldName = pack .. "_old_" .. timestamp
				existing.Name = oldName
				table.insert(oldGroups, oldName)
			end

			-- The wrapper Empty IS the group the 22-file flow produced, so the
			-- only rename is stripping a `_Node` suffix if this Studio build
			-- added one. Children are never touched.
			group.Name = pack
			group.Parent = assets
			moved = moved + 1

			local objects = topLevelCount(group)
			local parts = countParts(group)
			say("    MOVED to Assets." .. pack .. "  (" .. objects .. " top-level objects, " .. parts .. " parts)")

			-- Sizes and relative layout, measured against the generated table.
			-- FIRST of the checks, and the only one that runs for a pack with no
			-- RULES row: everything below this is a name check, and a name check
			-- cannot see an import that arrived scaled or shifted.
			for _, line in ipairs(verifyGeometry(pack, group)) do
				say("    " .. line)
			end

			if rule == nil then
				say("    NO RULE - nothing verified, no fidelity applied. Fix the RULES table.")
				continue
			end

			if rule.expected then
				if objects == rule.expected then
					say("    count   : " .. objects .. " == " .. rule.expected .. " OK")
				else
					say("    count   : " .. objects .. " vs expected " .. rule.expected .. "  <-- MISMATCH")
				end
			else
				say("    count   : " .. objects .. " (no count stated)")
			end
			if rule.expectedNote then
				say("    note    : " .. rule.expectedNote)
			end

			local present = namesPresent(group)
			if present[rule.sentinel] then
				say("    sentinel: " .. rule.sentinel .. " present OK")
			else
				say("    sentinel: " .. rule.sentinel .. " MISSING <-- the game will not find this pack")
				table.insert(misses, pack .. "." .. rule.sentinel .. " (sentinel)")
			end

			if rule.names then
				local gone = {}
				for _, name in ipairs(rule.names) do
					if not present[name] then
						table.insert(gone, name)
						table.insert(misses, pack .. "." .. name)
					end
				end
				if #gone == 0 then
					say("    names   : all " .. #rule.names .. " contract names present OK")
				else
					say("    names   : MISSING " .. table.concat(gone, ", "))
				end
			end

			local appliedFidelity = applyFidelity(group, rule.fidelity)
			if rule.fidelity == nil then
				say("    fidelity: skipped by design - the row says it does not matter")
			elseif #appliedFidelity == 0 then
				say("    fidelity: NO PARTS MATCHED - the rules and the mesh disagree, check by hand")
			else
				say("    fidelity: " .. #appliedFidelity .. " parts set")
				for _, line in ipairs(appliedFidelity) do
					say("              " .. line)
				end
			end

			for _, line in ipairs(applyMaterials(group)) do
				say("    material: " .. line)
			end
			for _, line in ipairs(assertNotNeon(group)) do
				say("    assert  : " .. line)
			end
		end

		-- THE IMPORT CONTAINER NEVER STAYS IN WORKSPACE.
		--
		-- This is the whole scrambled-world bug. A bundle container in Workspace
		-- RENDERS, and what it renders is sixteen islands stacked on top of each
		-- other at the import point, uncoloured (Studio drops every glTF colour;
		-- MeshColors repaints only what the game clones out of Assets) and
		-- lifted so the model's lowest vertex sits at y = 0. It is not a broken
		-- import - it is a correct import that nobody moved out of the way, and
		-- it happens on the HAPPY path: SKIP_EXISTING leaves every pack inside.
		--
		-- So it is moved unconditionally, whether or not anything is left in it.
		-- Nothing is deleted (see the header); ReplicatedStorage draws nothing,
		-- and the container is sitting there under ImportStaging to be inspected
		-- or dragged from by hand.
		local leftover = #model:GetChildren()
		local remaining = {}
		for packName in pairs(findPackGroups(model)) do
			table.insert(remaining, packName)
		end
		table.sort(remaining)

		local stagedName = "BundleImport_" .. string.gsub(bundle.file, "%.glb$", "") .. "_" .. timestamp
		local wasIn = model.Parent and model.Parent:GetFullName() or "(nowhere)"
		model.Name = stagedName
		model.Parent = getStagingFolder()
		table.insert(stagedContainers, {
			file = bundle.file,
			name = stagedName,
			leftover = leftover,
			packs = remaining,
		})

		say("")
		if leftover > 0 then
			say("  ##################################################################")
			say("  #  THE IMPORT CONTAINER STILL HELD " .. leftover .. " CHILD(REN) AND HAS BEEN MOVED")
			say("  #  OUT OF " .. wasIn .. ".")
			say("  #")
			say("  #  HAD IT BEEN LEFT THERE, THE WORLD WOULD RENDER THE RAW BUNDLE:")
			say("  #  every pack still inside it drawn AT THE IMPORT POINT, all of")
			say("  #  them stacked on top of each other, UNCOLOURED (Studio drops")
			say("  #  all glTF colour and only the game's clone path repaints), and")
			say("  #  lifted so the lowest vertex sits at y = 0 - i.e. sixteen")
			say("  #  islands in a heap through the starter cove. That is the")
			say("  #  'scrambled world', and it is the raw import being visible.")
			say("  #")
			if #remaining > 0 then
				say("  #  STILL INSIDE (not installed under Assets): " .. table.concat(remaining, ", "))
			end
			say("  #  NOW AT: " .. model:GetFullName())
			say("  #  It renders nothing there. Delete it once the game looks right,")
			say("  #  or fix the reason it was skipped and run again.")
			say("  ##################################################################")
		else
			say("  the emptied import container is now " .. model:GetFullName())
			say("  (moved out of " .. wasIn .. " so it cannot render; delete it by hand)")
		end
	end)

	if not ok then
		failures = failures + 1
		say("  ERROR while handling this bundle: " .. tostring(err))
		say("  MANUAL: File -> Import 3D... -> " .. path .. ", then re-run (it adopts from Workspace)")
	end
end

--=====================================================================
-- SOUND PACK (not a 3D import - verified, never created)
--=====================================================================

say("")
say("================ SoundPack")

local soundOk, soundErr = pcall(function()
	local assetsNow = ReplicatedStorage:FindFirstChild("Assets")
	local pack = assetsNow and assetsNow:FindFirstChild("SoundPack")

	local config = ReplicatedStorage:FindFirstChild("Shared", true)
	local module = nil
	if config then
		local found = config:FindFirstChild("SoundSprites", true)
		if found and found:IsA("ModuleScript") then
			module = found
		end
	end
	if module == nil then
		local found = ReplicatedStorage:FindFirstChild("SoundSprites", true)
		if found and found:IsA("ModuleScript") then
			module = found
		end
	end

	if module == nil then
		say("  SoundSprites module not found in ReplicatedStorage (is rojo connected?).")
		say("  Cannot list the expected Sound names; import the audio per docs/import-quick.md")
		say("  and re-run this check with rojo serving.")
		if pack then
			say("  Assets.SoundPack exists with " .. #pack:GetChildren() .. " children.")
		else
			say("  Assets.SoundPack does NOT exist - music and ambience will be silent (no error).")
		end
		return
	end

	local ok, sprites = pcall(require, module)
	if not ok or type(sprites) ~= "table" then
		say("  SoundSprites failed to require: " .. tostring(sprites))
		return
	end

	-- Read whatever maps the GENERATED module happens to carry today. The audio
	-- pass in flight renames every file; a hard-coded list would be wrong.
	local expected = {}
	local order = {}
	for _, mapName in ipairs(SOUND_MAPS) do
		local map = sprites[mapName]
		if type(map) == "table" then
			local n = 0
			for key, value in pairs(map) do
				-- `files` is { audio_sfx_1 = true, ... }: the KEY is the name.
				-- Region maps ({ file = ... }) and the older string-valued maps
				-- name the file in the value.
				local name = nil
				if mapName == "files" then
					name = key
				elseif type(value) == "table" and type(value.file) == "string" then
					name = value.file
				elseif type(value) == "string" then
					name = value
				end
				if name and not expected[name] then
					expected[name] = mapName
					table.insert(order, name)
					n = n + 1
				end
			end
			say("  SoundSprites." .. mapName .. ": " .. n .. " file names")
		end
	end
	table.sort(order)

	if #order == 0 then
		say("  SoundSprites carries no file-name maps at all - nothing to check.")
		return
	end

	if not pack then
		say("  Assets.SoundPack does NOT exist. Expected a Folder holding " .. #order .. " Sounds:")
		say("    " .. table.concat(order, ", "))
		say("  Until it is there: Sfx falls back to the four rbxasset built-ins, sprite-only")
		say("  cues are silent, and MusicController plays nothing. No errors - by design.")
		return
	end

	if not pack:IsA("Folder") then
		say("  Assets.SoundPack is a " .. pack.ClassName .. ", not a Folder <-- Sfx requires a Folder.")
	end

	local found, missingSounds, wrongClass = 0, {}, {}
	for _, name in ipairs(order) do
		local child = pack:FindFirstChild(name)
		if child == nil then
			table.insert(missingSounds, name)
		elseif not child:IsA("Sound") then
			table.insert(wrongClass, name .. " is a " .. child.ClassName)
		else
			found = found + 1
		end
	end

	local extra = {}
	for _, child in ipairs(pack:GetChildren()) do
		if not expected[child.Name] then
			table.insert(extra, child.Name .. " (" .. child.ClassName .. ")")
		end
	end

	say("  Assets.SoundPack: " .. found .. " of " .. #order .. " expected Sounds present")
	if #missingSounds > 0 then
		say("  MISSING (silent, no error): " .. table.concat(missingSounds, ", "))
		say("  -> Asset Manager -> Bulk Import -> Audio, then drag each into Assets.SoundPack.")
		say("     A Sound's NAME is the only lookup key; it must equal the file basename.")
	end
	for _, line in ipairs(wrongClass) do
		say("  WRONG CLASS: " .. line)
	end
	if #extra > 0 then
		say("  extra children (harmless, but check for a typo): " .. table.concat(extra, ", "))
	end
	local sub = 0
	for _, child in ipairs(pack:GetChildren()) do
		if child:IsA("Folder") then
			sub = sub + 1
		end
	end
	if sub > 0 then
		say("  " .. sub .. " SUBFOLDER(S) inside SoundPack <-- the pack must be FLAT; move the Sounds up.")
	end
end)
if not soundOk then
	say("  ERROR checking the SoundPack: " .. tostring(soundErr))
end

--=====================================================================
-- REPORT TAIL
--=====================================================================

say("")
say("================================================================")
say("SUMMARY: " .. moved .. " packs moved, " .. skipped .. " skipped (WARNING), " .. failures .. " failed")

if #skippedPacks > 0 then
	say("")
	say("!! " .. #skippedPacks .. " PACK(S) WERE SKIPPED, WHICH IS NOT A SUCCESS:")
	say("!!   " .. table.concat(skippedPacks, ", "))
	say("!!")
	say("!! THE OLD MESH IS STILL WHAT THE GAME USES FOR EVERY PACK NAMED ABOVE.")
	say("!! SKIP_EXISTING = true LEFT THEM ALONE, SO THIS RUN CHANGED NOTHING FOR")
	say("!! THEM - A REGENERATED MESH IS NOT IN THE GAME, AND THE REPORT ABOVE SAYS")
	say("!! NOTHING ABOUT WHETHER THE OLD ONE IS CURRENT. A STALE IslandPack IS")
	say("!! EXACTLY HOW YOU END UP WITH NO ISLETS AND NO HUTS AFTER A 'CLEAN' RUN.")
	say("!!")
	say("!! TO REPLACE THEM: SET `local SKIP_EXISTING = false` AT THE TOP OF THIS")
	say("!! FILE AND PASTE IT AGAIN. THE OLD PACK IS RENAMED")
	say("!! `<Name>_old_" .. timestamp .. "` AND LEFT IN PLACE (NEVER DELETED), THE NEW")
	say("!! ONE TAKES ITS NAME, AND YOU DELETE THE `_old_` GROUPS BY HAND ONCE THE")
	say("!! GAME LOOKS RIGHT. THEN SAVE Assets.rbxm AND RESTART `rojo serve`.")
end

if #stagedContainers > 0 then
	say("")
	say("IMPORT CONTAINERS MOVED OUT OF WORKSPACE (they render if left there):")
	for _, entry in ipairs(stagedContainers) do
		local tail = if entry.leftover > 0
			then entry.leftover .. " child(ren) still inside" .. (#entry.packs > 0 and " - packs: " .. table.concat(
				entry.packs,
				", "
			) or "")
			else "empty"
		say("  ReplicatedStorage.ImportStaging." .. entry.name .. "  [" .. entry.file .. "] " .. tail)
	end
	say("  A bundle container in Workspace draws every pack inside it at the import")
	say("  point, stacked and uncoloured. Nothing under ReplicatedStorage draws.")
end

if #strays > 0 then
	say("")
	say("TOP-LEVEL CHILDREN THE BUNDLES DID NOT DECLARE (left where they were):")
	for _, line in ipairs(strays) do
		say("  " .. line)
	end
end

if #oldGroups > 0 then
	say("")
	say("OLD PACKS KEPT (nothing was deleted) - delete these BY HAND once you have")
	say("verified the new meshes in-game:")
	for _, name in ipairs(oldGroups) do
		say("  ReplicatedStorage.Assets." .. name)
	end
else
	say("")
	say("No packs were replaced, so there are no _old_ groups to clean up.")
end

if #misses > 0 then
	say("")
	say("the game will use a stand-in and warn for: " .. table.concat(misses, ", "))
else
	say("")
	say("No expected-name misses: every contract name was found.")
end

say("")
if DRY_RUN then
	say("THIS WAS A DRY RUN. Set DRY_RUN = false at the top and run again.")
else
	say("TWO MANUAL STEPS REMAIN:")
	say("  1. Right-click ReplicatedStorage.Assets -> Save to File... -> assets/Assets.rbxm")
	say("  2. Restart `rojo serve` and reconnect (it does not watch .rbxm files)")
end
say("================================================================")
say("")

print(table.concat(report, "\n"))
