--!nocheck
--[[
	SUPERSEDED (2026-09-12). The import flow the game actually uses is the
	THREE-BUNDLE one: assets/bundles/*.glb unpacked by
	tools/studio_import_bundles.lua, following docs/import-quick.md. This
	file's per-file ROWS/NEON ledger is no longer maintained (its Gnashroot
	and Kraken rows are already stale) - do not run it for a fresh import.
	Kept for reference only.
]]
--[[
	studio_import.lua - batch glTF import for How-to-Fish

	WHAT IT DOES
	Automates docs/import-checklist.md: imports all 21 owed `.glb` files from
	`assets/` in one pass, renames each imported top-level group to the exact
	name the game looks up under `ReplicatedStorage.Assets`, applies the
	per-part CollisionFidelity every ledger row demands (the part hands are
	worst at and the runtime cannot do - a MeshPart's CollisionFidelity is not
	writable from game code, only at import/edit time), sets the three Neon
	materials the ledger header says are genuinely yours, and prints a
	verification report: object counts vs the ledger, sentinel-child presence,
	which fidelity landed where, and every expected name that is missing.

	HOW TO RUN
	  1. Open the place in Roblox Studio (any place - this only writes to
	     ReplicatedStorage.Assets).
	  2. View -> Command Bar.
	  3. Paste this whole file in and press Enter. Read the printed PLAN.
	  4. Flip DRY_RUN to false below, paste again, press Enter.
	  Or: save it as a local plugin script and run it from there - same code,
	  and you get a proper Output window without a 100k-character paste.

	THE TWO FLAGS (top of the file)
	  DRY_RUN      = true  -- default. Prints the plan (every file, target
	                          name, fidelity rules, expected counts) and
	                          imports NOTHING. Flip to false to do the work.
	  SKIP_EXISTING = true -- default. A target that already exists under
	                          Assets is left alone, so a re-run after a
	                          partial failure only fills the gaps. Set false
	                          to force a re-import of everything (the old
	                          group is kept, renamed, never deleted).

	CAVEATS
	  * NOTHING IS EVER DELETED. There is no :Destroy() in this file. When a
	    target already exists and is being replaced, the OLD group is renamed
	    to "<Name>_old_<timestamp>" and left in place. Delete those by hand
	    after you have verified the new meshes in-game - the report lists them.
	  * Children are NEVER renamed. The glb child names are the contract that
	    WorldService / BossArenaService / every BodyController looks parts up
	    by; only the top-level group is renamed.
	  * Studio's import API differs between builds, and some builds pop a
	    PER-FILE CONFIRMATION DIALOG (the 3D Importer window) that this script
	    cannot click. If that happens, accept each dialog as it appears - the
	    script continues after each one - or fall back to the MANUAL line it
	    prints for any file it could not import.
	  * Do NOT scale anything on import. Several rows (Pyrelisk, Wrack, Kraken,
	    Gnashroot, the islets) are authored at final size and double-scale.

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

local ASSET_DIR = "/Users/samarthsreenivas/Developer/How-to-Fish/assets/"

--=====================================================================

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AssetImportService = game:GetService("AssetImportService")

local PRECISE = Enum.CollisionFidelity.PreciseConvexDecomposition
local BOX = Enum.CollisionFidelity.Box

--[[
	THE LEDGER, transcribed from docs/import-checklist.md.

	file          - basename under assets/
	name          - exact target name under ReplicatedStorage.Assets
	sentinel      - the child whose presence proves the import is the right
	                one (<Name>_Base for arenas; the row's first listed piece
	                for packs)
	expected      - object count the row states, or nil where it states none
	expectedNote  - discrepancy between the row's count and the actual glb
	names         - names the row spells out as a contract (code looks them up)
	fidelity      - {pattern, Enum.CollisionFidelity} applied by string.find,
	                plain, over every descendant BasePart after import.
	                ABSENT for every row that says fidelity does not matter -
	                boss packs cloned into massless collision-free parts churn
	                nothing here.
]]
local ROWS = {
	{
		file = "island_pack.glb",
		name = "IslandPack",
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
			-- row 1: the <Name>_Base landforms and solid props are walked on.
			-- "_Base" covers Island/Swamp/Volcano/Frostmaw/Gloomtrench/
			-- Wreckwater/Maelstrom AND every islet base (Bellbuoy_Base is
			-- called out by name in row 1c).
			{ "_Base", PRECISE },
			-- Frostmaw's walkable ice sheet IS Frostmaw_Base (island_gen.py
			-- :4943 builds it with M_IceSheet and cuts the fishing holes
			-- into it) - covered by "_Base" above. A default hull caps the
			-- holes: the volcano-crater gotcha.
			{ "Volcano_DeadTrees", PRECISE },
			{ "Maelstrom_Platforms", PRECISE },
			-- row 1, 2026-08-29: the six NPC houses are WALK-IN. A hull turns
			-- the shell into a solid block and fills the doorway.
			{ "_Hut_Walls", PRECISE },
			{ "_Hut_Roof", PRECISE },
			-- row 1c: the ~28 islet parts a hull would seal, flatten or fill.
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
	{
		file = "island_maelstrom.glb",
		name = "Maelstrom",
		row = "1b",
		sentinel = "Maelstrom_Base",
		expected = 9,
		names = { "Maelstrom_Base", "Maelstrom_Platforms" },
		fidelity = {
			{ "Maelstrom_Base", PRECISE },
			{ "Maelstrom_Platforms", PRECISE },
		},
	},
	{
		file = "weapon.glb",
		name = "WeaponPack",
		row = "2",
		sentinel = "DriftwoodClub_Head",
	},
	{
		file = "boat.glb",
		name = "BoatPack",
		row = "3",
		sentinel = "CoveSkiff_Hull",
	},
	{
		file = "creatures.glb",
		name = "CreaturePack",
		row = "4",
		sentinel = "Crab_Body",
	},
	{
		file = "fish.glb",
		name = "FishPack",
		row = "5",
		sentinel = "Bass_Body",
	},
	{
		file = "rod.glb",
		name = "RodPack",
		row = "6",
		sentinel = "Twig_Grip",
	},
	{
		file = "armor.glb",
		name = "ArmorPack",
		row = "7",
		sentinel = "Chitin_Helm",
		names = { "Chitin_Helm", "Chitin_Chest", "Chitin_Legs", "Boneplate_Helm" },
	},
	{
		file = "arena_brinejaw.glb",
		name = "BrinejawArena",
		row = "7b",
		sentinel = "BrinejawArena_Base",
		expected = 13,
		expectedNote = "the row says 13; the shipped glb actually holds 19 objects (the "
			.. "SpireBand/SpireRail/SpireWindows/Bell/Boat/Mast/SailRag detail split). "
			.. "19 is the number to trust - the row's count is stale, not the mesh.",
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
			-- "_Spire" is a substring match, so it also catches _SpireBand,
			-- _SpireRail and _SpireWindows. That is the lighthouse the row
			-- says players fight on, so the fan-out is wanted, not accidental.
			{ "BrinejawArena_Spire", PRECISE },
			{ "BrinejawArena_Rocks", PRECISE },
			{ "ReefStone", PRECISE },
		},
	},
	{
		file = "boss_brinejaw.glb",
		name = "BrinejawPack",
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
		-- fidelity: row says it does not matter (~60 massless collision-free clones)
	},
	{
		file = "arena_gnashroot.glb",
		name = "GnashrootArena",
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
	{
		file = "boss_gnashroot.glb",
		name = "GnashrootPack",
		row = "7f",
		sentinel = "Gnashroot_Mass",
		expected = 14,
		names = {
			"Gnashroot_Mass",
			"Gnashroot_Legs",
			"Gnashroot_Head",
			"Gnashroot_Jaw",
			"Gnashroot_Maw",
			"Gnashroot_Teeth",
			"Gnashroot_Fangs",
			"Gnashroot_Eyes",
			"Gnashroot_Core",
			"Gnashroot_Stones",
			"Gnashroot_Drips",
			"Gnashroot_Arm",
			"Gnashroot_ArmKnot",
			"Gnashroot_Hand",
		},
		-- fidelity: row says it does not matter. Neon on _Core is belt-and-
		-- braces (the controller sets it), so we do not touch materials here.
	},
	{
		file = "arena_rimefang.glb",
		name = "RimefangArena",
		row = "7j",
		sentinel = "RimefangArena_Base",
		expected = 9,
		-- Floe v2 (2026-09-09): `_Drifts` no longer exists and `_ThinIce` does.
		-- The bergs and the wreck moved OUTSIDE the pressure ridge as backdrop,
		-- so the only two things a player can touch - and the only two that
		-- need a real hull - are the sheet and the ridge that holds them on it.
		names = {
			"RimefangArena_Base",
			"RimefangArena_Ridge",
			"RimefangArena_ThinIce",
		},
		fidelity = {
			{ "RimefangArena_Base", PRECISE },
			{ "RimefangArena_Ridge", PRECISE },
		},
	},
	{
		file = "boss_rimefang.glb",
		name = "RimefangPack",
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
		-- fidelity + materials: both stated in code (RimefangBodyController)
	},
	{
		file = "arena_noctyss.glb",
		name = "NoctyssArena",
		row = "7h",
		sentinel = "NoctyssArena_Base",
		expected = 21,
		names = {
			"NoctyssArena_Base",
			"NoctyssArena_Rim",
			"NoctyssArena_Slab",
			"NoctyssArena_Fins",
			"NoctyssArena_Socket1",
			"NoctyssArena_Socket7",
			"NoctyssArena_DecoPitWater",
		},
		fidelity = {
			-- REQUIRED, not optional: the pit is a carved bowl and a default
			-- hull caps it - you would walk on air over the hole she rises
			-- through.
			{ "NoctyssArena_Base", PRECISE },
			{ "NoctyssArena_Rim", PRECISE },
			{ "NoctyssArena_Slab", PRECISE },
			{ "NoctyssArena_Fins", PRECISE },
			{ "_Socket", PRECISE },
			-- _Teeth/_Stacks/_Elders/_Bones: default hull is fine, per the row.
			-- _Deco*/_Glow*/_Foam: collision stripped at runtime.
		},
	},
	{
		file = "boss_noctyss.glb",
		name = "NoctyssPack",
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
		-- fidelity: row says it does not matter. Neon on _Gullet is handled
		-- by the global NEON list below (ledger header, 2026-08-30).
	},
	{
		file = "arena_wrack.glb",
		name = "WrackArena",
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
			-- "_Fleet" covers _Fleet, _FleetRibs and _FleetMasts - the
			-- palisade is the only thing walked into now that the breakwater
			-- hulks are gone.
			{ "_Fleet", PRECISE },
		},
	},
	{
		file = "boss_wrack.glb",
		name = "WrackPack",
		row = "7p",
		sentinel = "Wrack_Base",
		-- 2026-09-09 (f585013 / glb 28e7730): 25 -> 36 objects. This list is the
		-- full top-level set read out of the committed glb itself, not from the
		-- ledger prose - the old Battery* pieces are gone entirely.
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
			-- The ONE collidable Wrack piece: the server clones it into
			-- Workspace as the shot occluder (CanCollide/CanQuery) and its four
			-- folded-in casemates are concave - a Box/Default hull slabs over
			-- the cheeks and blocks shots at the near guns.
			{ "Wrack_HullCollider", PRECISE },
			-- Everything else: no requirement (planted gun platform, nothing
			-- walked on). Materials: none at import - the controller sets Neon
			-- on every "Glow"-named piece after clone, colours from MeshColors
			-- (HullCollider deliberately has no colour row; it is invisible).
		},
	},
	{
		file = "arena_pyrelisk.glb",
		name = "PyreliskArena",
		row = "7n",
		sentinel = "PyreliskArena_Base",
		-- 2026-09-12: 12 -> 14 (three-phase redesign, slice 6). The caldera
		-- split: _LakeFloor is the removable disc under the lava, _Shaft the
		-- 120-stud drop tube under THAT.
		expected = 14,
		names = {
			"PyreliskArena_Base",
			"PyreliskArena_Rim",
			"PyreliskArena_Flank",
			"PyreliskArena_Teeth",
			"PyreliskArena_Gate",
			"PyreliskArena_Lava",
			"PyreliskArena_LakeFloor",
			"PyreliskArena_Shaft",
			"PyreliskArena_SeamDeco",
			"PyreliskArena_CloudDeco",
		},
		fidelity = {
			-- REQUIRED: _Rim's face LEANS BACK over the path and that overhang
			-- is the only thing containing the player. A default hull fills
			-- the undercut and the containment becomes a ramp.
			{ "PyreliskArena_Rim", PRECISE },
			{ "PyreliskArena_Flank", PRECISE },
			{ "PyreliskArena_Teeth", PRECISE },
			{ "PyreliskArena_Gate", PRECISE },
			-- REQUIRED: _Shaft is a hollow tube. A default hull fills it solid
			-- and act 4's caldera opens onto rock, with nothing logged.
			{ "PyreliskArena_Shaft", PRECISE },
			-- _Base and _LakeFloor are dead flat: default hulls are fine.
			-- _LakeFloor must stay QUERYABLE (floorY probes it at Caldera=0).
		},
	},
	{
		file = "arena_pyrelisk_heart.glb",
		name = "PyreliskHeart",
		row = "7n2",
		sentinel = "PyreliskHeart_Base",
		-- NEW 2026-09-12 (slice 6): act 4's room, the volcano's heart. Closed
		-- obsidian dome; authored z = 0 is the FLOOR datum, meshBottom 586.0
		-- does the 600-stud lift. Do not scale.
		expected = 22,
		names = {
			"PyreliskHeart_Base",
			"PyreliskHeart_Walls",
			"PyreliskHeart_Dais",
			"PyreliskHeart_Heart",
			"PyreliskHeart_HeartGlow",
			"PyreliskHeart_EntryPad",
			"PyreliskHeart_Socket1",
			"PyreliskHeart_Socket8",
			"PyreliskHeart_Vent1Glow",
			"PyreliskHeart_Vent6Glow",
			"PyreliskHeart_VeinGlow",
			"PyreliskHeart_RubbleDeco",
		},
		fidelity = {
			-- The dome IS the containment and the floor is a dish; a hull caps
			-- or fills both.
			{ "PyreliskHeart_Walls", PRECISE },
			{ "PyreliskHeart_Base", PRECISE },
			-- _Dais/_EntryPad/_Socket*/_Heart: default hulls fine. The *Glow
			-- set goes Neon via placeAuthored's name rule; _RubbleDeco loses
			-- collision+query via the Deco rule. No manual material work.
		},
	},
	{
		file = "boss_pyrelisk.glb",
		name = "PyreliskPack",
		row = "7o",
		sentinel = "Pyrelisk_Core",
		-- 2026-09-12: 14 -> 17, the FINAL set. Pyrelisk_WalkNeck (the
		-- shoulder->neck climb plate, Box like its siblings), then _ArmRock (six
		-- instanced orange climb targets) and _NeckCore (the collar core) with
		-- slice 4 of the three-phase redesign.
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
			-- The one boss pack where fidelity matters: _WalkArm and _WalkDeck
			-- are the CLIMB ROUTE and the only collidable pieces. The row says
			-- box fidelity is exact and correct for them.
			{ "Pyrelisk_WalkArm", BOX },
			{ "Pyrelisk_WalkDeck", BOX },
			{ "Pyrelisk_WalkNeck", BOX },
		},
	},
	{
		file = "boss_kraken.glb",
		name = "KrakenPack",
		row = "7m",
		sentinel = "Kraken_Head",
		expected = 9,
		names = {
			"Kraken_Head",
			"Kraken_Crown",
			"Kraken_Crust",
			"Kraken_Eyes",
			"Kraken_Pupil",
			"Kraken_Beak",
			"Kraken_ArmSeg",
			"Kraken_ArmTip",
			"Kraken_Sucker",
		},
		-- fidelity: row says it does not matter (~170 massless clones)
	},
}

--[[
	MATERIALS - ledger header, "the ones that genuinely depend on you".
	Set Neon on exactly these three and nothing else. Everything else that
	glows is asserted by its own controller after the clone (Pyrelisk's
	_Core/_Seam/_Eyes, Gnashroot's _Core, Brinejaw's and Rimefang's _Eyes,
	Noctyss's stalk bulb) or by BossArenaService's `Glow`-in-the-name rule
	for arenas.
]]
local NEON = {
	Kraken_Eyes = true,
	Kraken_Sucker = true,
	Noctyss_Gullet = true,
}

-- Dark ON PURPOSE. Never set these Neon; the report asserts they came out
-- non-Neon (Kraken_Pupil's slit stops reading, and a second neon piece on
-- Gnashroot makes the punish target ambiguous).
local MUST_NOT_BE_NEON = { "Kraken_Pupil", "Gnashroot_Eyes" }

-- Two Neon asks live in row 7n that this script deliberately does NOT set,
-- because they are arena parts and the header reserves manual material work
-- for the three above. Printed as an advisory instead of silently skipped.
local MANUAL_MATERIAL_ADVISORIES = {
	"PyreliskArena_Lava wants Neon (+ CanCollide off) per row 7n - not set by this script",
	"PyreliskArena_SeamDeco wants Neon per row 7n (the four rings are the fight's distance dial) - not set by this script",
}

--=====================================================================
-- IMPORT STRATEGY CHAIN
--=====================================================================

--[[
	AssetImportService's surface differs between Studio builds and is not
	documented, so instead of betting on one method we try known shapes in
	order and take the first that yields an Instance. Each attempt is its own
	pcall, so a missing method or a changed signature costs one line in the
	report, not the run.

	ADDING A SHAPE LATER IS ONE TABLE ENTRY: append
	{ name = "...", run = function(path) ... return instanceOrNil end }.
	`run` may return the imported Instance directly, or return nil after the
	API has parented the result itself - the caller diffs Workspace and
	ReplicatedStorage for a new top-level child either way.
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
		name = "ImportFBXAnimationUserMayChooseModel-style dialog import",
		run = function(path)
			-- Some builds only expose the dialog-driven entry point. It blocks
			-- on the 3D Importer window; the user accepts it and we take the
			-- result.
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

-- Anything newly parented under one of the containers we watch, so a strategy
-- that parents its own result is handled the same as one that returns it.
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
	-- The ledger's "N objects" counts the groups/parts directly under the
	-- imported container, which is what a glTF node list gives you.
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
			-- the API may have parented the result itself
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
local imported = 0
local skipped = 0

say("")
say("================================================================")
say(DRY_RUN and "How-to-Fish batch import - DRY RUN (nothing imported)" or "How-to-Fish batch import - LIVE")
say("  assets dir     : " .. ASSET_DIR)
say("  SKIP_EXISTING  : " .. tostring(SKIP_EXISTING))
say("  rows in ledger : " .. #ROWS)
say("================================================================")

local assets, createdAssets = getAssetsFolder()
if createdAssets then
	say(DRY_RUN and "* would CREATE ReplicatedStorage.Assets" or "* created ReplicatedStorage.Assets")
end

for _, entry in ipairs(ROWS) do
	local path = ASSET_DIR .. entry.file
	say("")
	say("---- [row " .. entry.row .. "] " .. entry.file .. "  ->  Assets." .. entry.name)

	local ok, err = pcall(function()
		local existing = assets and assets:FindFirstChild(entry.name) or nil

		if existing and SKIP_EXISTING then
			skipped = skipped + 1
			say("  SKIPPED: Assets." .. entry.name .. " already exists and SKIP_EXISTING is true.")
			say("           top-level objects: " .. topLevelCount(existing) .. ", parts: " .. countParts(existing))
			return
		end

		if DRY_RUN then
			say("  PLAN: import " .. path)
			say("        rename top-level group -> " .. entry.name .. ", parent to ReplicatedStorage.Assets")
			if existing then
				local oldName = entry.name .. "_old_" .. timestamp
				say("        existing group would be RENAMED to " .. oldName .. " (kept, never deleted)")
			end
			if entry.expected then
				say("        expect " .. entry.expected .. " objects; sentinel child " .. entry.sentinel)
			else
				say("        no object count stated in the ledger; sentinel child " .. entry.sentinel)
			end
			if entry.expectedNote then
				say("        NOTE: " .. entry.expectedNote)
			end
			if entry.fidelity then
				local parts = {}
				for _, rule in ipairs(entry.fidelity) do
					table.insert(parts, rule[1] .. "=" .. rule[2].Name)
				end
				say("        fidelity rules (" .. #entry.fidelity .. "): " .. table.concat(parts, ", "))
			else
				say("        fidelity: none - the row says it does not matter (collision-free clones)")
			end
			return
		end

		local model, strategyName, tried = importOne(path)
		if model == nil then
			failures = failures + 1
			say("  FAILED: no import strategy worked.")
			for _, line in ipairs(tried) do
				say("          tried " .. line)
			end
			say("  MANUAL: File -> Import 3D... -> " .. path)
			say("          rename the group to '" .. entry.name .. "', drag into ReplicatedStorage.Assets")
			if entry.fidelity then
				for _, rule in ipairs(entry.fidelity) do
					say("          set CollisionFidelity=" .. rule[2].Name .. " on parts matching '" .. rule[1] .. "'")
				end
			end
			return
		end

		if existing then
			local oldName = entry.name .. "_old_" .. timestamp
			existing.Name = oldName
			table.insert(oldGroups, oldName)
		end

		-- Rename the TOP-LEVEL group only. Children are the contract.
		model.Name = entry.name
		model.Parent = assets
		imported = imported + 1

		local objects = topLevelCount(model)
		local parts = countParts(model)
		say("  IMPORTED via " .. strategyName .. "  (" .. objects .. " top-level objects, " .. parts .. " parts)")

		if entry.expected then
			if objects == entry.expected then
				say("  count  : " .. objects .. " == ledger's " .. entry.expected .. " OK")
			else
				say("  count  : " .. objects .. " vs ledger's " .. entry.expected .. "  <-- MISMATCH, check the row")
			end
		else
			say("  count  : " .. objects .. " (ledger states no count)")
		end
		if entry.expectedNote then
			say("  note   : " .. entry.expectedNote)
		end

		local present = namesPresent(model)
		if present[entry.sentinel] then
			say("  sentinel: " .. entry.sentinel .. " present OK")
		else
			say("  sentinel: " .. entry.sentinel .. " MISSING <-- the game will not find this group")
			table.insert(misses, entry.name .. "." .. entry.sentinel .. " (sentinel)")
		end

		if entry.names then
			local gone = {}
			for _, wanted in ipairs(entry.names) do
				if not present[wanted] then
					table.insert(gone, wanted)
					table.insert(misses, entry.name .. "." .. wanted)
				end
			end
			if #gone == 0 then
				say("  names  : all " .. #entry.names .. " contract names present OK")
			else
				say("  names  : MISSING " .. table.concat(gone, ", "))
			end
		end

		local appliedFidelity = applyFidelity(model, entry.fidelity)
		if entry.fidelity == nil then
			say("  fidelity: skipped by design - the row says it does not matter")
		elseif #appliedFidelity == 0 then
			say("  fidelity: NO PARTS MATCHED - the rules and the mesh disagree, check by hand")
		else
			say("  fidelity: " .. #appliedFidelity .. " parts set")
			for _, line in ipairs(appliedFidelity) do
				say("            " .. line)
			end
		end

		local materials = applyMaterials(model)
		if #materials > 0 then
			for _, line in ipairs(materials) do
				say("  material: " .. line)
			end
		end
		for _, line in ipairs(assertNotNeon(model)) do
			say("  assert  : " .. line)
		end
	end)

	if not ok then
		failures = failures + 1
		say("  ERROR while handling this row: " .. tostring(err))
		say("  MANUAL: File -> Import 3D... -> " .. path)
		say("          rename to '" .. entry.name .. "' under ReplicatedStorage.Assets")
	end
end

--=====================================================================
-- REPORT TAIL
--=====================================================================

say("")
say("================================================================")
say("SUMMARY of " .. #ROWS .. " rows: " .. imported .. " in, " .. skipped .. " skipped, " .. failures .. " failed")

if #oldGroups > 0 then
	say("")
	say("OLD GROUPS KEPT (nothing was deleted) - delete these BY HAND once you")
	say("have verified the new meshes in-game:")
	for _, name in ipairs(oldGroups) do
		say("  ReplicatedStorage.Assets." .. name)
	end
else
	say("")
	say("No groups were replaced, so there are no _old_ groups to clean up.")
end

if #misses > 0 then
	say("")
	say("the game will use a stand-in and warn for: " .. table.concat(misses, ", "))
else
	say("")
	say("No expected-name misses: every contract name the ledger states was found.")
end

say("")
say("MATERIAL ADVISORIES (ledger rows this script deliberately leaves to you):")
for _, line in ipairs(MANUAL_MATERIAL_ADVISORIES) do
	say("  " .. line)
end

say("")
if DRY_RUN then
	say("THIS WAS A DRY RUN. Set DRY_RUN = false at the top and run again.")
else
	say("TWO MANUAL STEPS REMAIN:")
	say("  1. Right-click ReplicatedStorage.Assets -> Save to File... -> assets/Assets.rbxm (overwrite)")
	say("  2. Restart `rojo serve` and reconnect (it does not watch .rbxm files)")
end
say("================================================================")
say("")

print(table.concat(report, "\n"))
