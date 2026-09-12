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
	studio_adopt.lua - adopt hand-imported "Scene" groups for How-to-Fish

	WHAT IT DOES
	You already imported the 21 `.glb` files by hand through Studio's 3D Import
	Queue. Every one of them landed in Workspace as a top-level group named
	"Scene" (the glTF default scene name), with its children keeping the glb
	node names and with DEFAULT CollisionFidelity on everything. The meshes are
	right; the naming, the parent and the fidelity are wrong.

	This script finishes that job WITHOUT importing anything:
	  1. IDENTIFY - finds every top-level "Scene" (and "Scene1", "Scene2", ...)
	     under Workspace and ReplicatedStorage, and works out WHICH ledger row
	     each one is by looking for that row's sentinel child by exact name.
	  2. ADOPT    - renames the top-level group to the exact name the game looks
	     up under `ReplicatedStorage.Assets`, and parents it there.
	  3. FIDELITY - applies every row's per-part CollisionFidelity. THIS IS THE
	     WHOLE POINT: a MeshPart's CollisionFidelity is not writable from game
	     code, and a hand import gives everything Default - which caps the
	     volcano crater, seals the Frostmaw fishing holes, fills the NPC-house
	     doorways and turns Pyrelisk's overhang into a ramp.
	  4. NEON     - sets the three materials the ledger header says are
	     genuinely yours, and asserts the two that must stay dark.
	  5. REPORT   - what was found, what it was identified as, what moved, what
	     fidelity landed where, and every ledger row for which no "Scene" was
	     found.

	WHEN TO USE THIS vs tools/studio_import.lua
	  * studio_import.lua  - you have NOT imported yet and want Studio's
	    AssetImportService to do all 21 imports for you.
	  * studio_adopt.lua   - THIS ONE. You already imported by hand and are
	    looking at a pile of groups named "Scene". Nothing is imported here.
	Both scripts share the same ledger tables (copied verbatim from
	studio_import.lua, which verified them against the real glbs) and the same
	no-delete guarantee, so it is safe to run one after the other: rows this
	script cannot find are exactly the rows studio_import.lua should import.

	HOW TO RUN
	  1. Open the place in Roblox Studio (this only writes to the "Scene"
	     groups and to ReplicatedStorage.Assets).
	  2. View -> Command Bar.
	  3. Paste this whole file in and press Enter. Read the printed PLAN: it
	     names every "Scene" it found and what it believes each one is.
	  4. If the identification looks right, flip DRY_RUN to false below, paste
	     again, press Enter.
	  Or: save it as a local plugin script and run it from there - same code,
	  and you get a proper Output window without a long paste.

	THE ONE FLAG (top of the file)
	  DRY_RUN = true  -- default. Identifies everything and prints the full
	                     plan; changes NOTHING. Flip to false to do the work.
	  There is no SKIP_EXISTING: a target name that already exists under Assets
	  gets the _old_ treatment below rather than blocking the adoption.

	THE NO-DELETE GUARANTEE
	  NOTHING IS EVER DELETED. There is no :Destroy() and no
	  :ClearAllChildren() in this file. When a target name already exists under
	  Assets, the OLD group is renamed to "<Name>_old_<timestamp>" and left in
	  place; the report lists them so you can delete them BY HAND once you have
	  verified the new meshes in-game.

	CHILDREN ARE NEVER RENAMED. The glb child names are the contract that
	WorldService / BossArenaService / every BodyController looks parts up by.
	This script renames exactly three kinds of thing: a new Assets folder, an
	adopted top-level group, and a displaced old group.

	IDEMPOTENT. An adopted group is no longer named "Scene", so a re-run simply
	does not see it. Re-running with nothing left to adopt prints "nothing to
	adopt" plus the per-row presence check of ReplicatedStorage.Assets - that
	check runs on EVERY pass and doubles as the verification report.

	CollisionFidelity is writable at plugin security in current Studio builds.
	If an assignment throws anyway, it is pcall'd and the part is printed as a
	manual to-do (select it, Properties panel, CollisionFidelity) instead of
	killing the run.

	AFTER IT RUNS - the two manual steps it cannot do:
	  1. Right-click ReplicatedStorage.Assets -> Save to File... ->
	     assets/Assets.rbxm (overwrite).
	  2. Restart `rojo serve` and reconnect (it does not watch .rbxm).
]]

--=====================================================================
-- FLAGS
--=====================================================================

local DRY_RUN = true

--=====================================================================

local ReplicatedStorage = game:GetService("ReplicatedStorage")

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
-- HELPERS
--=====================================================================

local report = {}
local function say(line)
	table.insert(report, line)
end

-- "Scene", "Scene1", "Scene 2", "Scene_3" - Studio disambiguates repeat
-- imports with a numeric suffix, and the Import Queue is where they all
-- come from.
local function isSceneName(name)
	return string.match(name, "^Scene[%s_]*%d*$") ~= nil
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

-- A row claims a candidate iff the candidate holds that row's sentinel child
-- by EXACT name. Direct children first (that is where a glTF scene's nodes
-- land); a recursive look follows, because some builds wrap the nodes in an
-- extra container and the sentinels are unique across all 21 rows either way.
local function hasSentinel(candidate, sentinel)
	if candidate:FindFirstChild(sentinel) then
		return true
	end
	return candidate:FindFirstChild(sentinel, true) ~= nil
end

local function firstChildNames(candidate, limit)
	local names = {}
	for _, child in ipairs(candidate:GetChildren()) do
		table.insert(names, child.Name)
		if #names >= limit then
			break
		end
	end
	if #names == 0 then
		return "(no children)"
	end
	return table.concat(names, ", ")
end

-- Returns applied lines and the names of parts whose assignment threw, so a
-- build where CollisionFidelity is not writable degrades to a to-do list
-- rather than an error.
local function applyFidelity(root, rules)
	local applied = {}
	local failed = {}
	if rules == nil then
		return applied, failed
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
						table.insert(failed, d.Name .. " (wants " .. fidelity.Name .. ")")
					end
					break
				end
			end
		end
	end
	return applied, failed
end

-- DRY_RUN counterpart: how many MeshParts each rule would touch, reading only.
local function previewFidelity(root, rules)
	local n = 0
	if rules == nil then
		return 0
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("MeshPart") then
			for _, rule in ipairs(rules) do
				if string.find(d.Name, rule[1], 1, true) then
					n = n + 1
					break
				end
			end
		end
	end
	return n
end

local function applyMaterials(root)
	local set = {}
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") and NEON[d.Name] then
			local ok = pcall(function()
				d.Material = Enum.Material.Neon
			end)
			table.insert(set, d.Name .. (ok and " -> Neon" or " -> FAILED, set Material=Neon by hand"))
		end
	end
	return set
end

local function neonTargetsIn(root)
	local found = {}
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") and NEON[d.Name] then
			table.insert(found, d.Name)
		end
	end
	return found
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

--=====================================================================
-- 1. IDENTIFY
--=====================================================================

local timestamp = os.date("%Y%m%d_%H%M%S")

local candidates = {}
for _, container in ipairs({ workspace, ReplicatedStorage }) do
	for _, child in ipairs(container:GetChildren()) do
		if (child:IsA("Model") or child:IsA("Folder")) and isSceneName(child.Name) then
			table.insert(candidates, { instance = child, where = container.Name .. "." .. child.Name })
		end
	end
end

-- Every (candidate, row) sentinel hit, recorded both ways so the two shapes of
-- ambiguity - one candidate claimed by two rows, one row claimed by two
-- candidates - can be reported and refused rather than guessed at.
local rowsForCandidate = {}
local candidatesForRow = {}
for _, entry in ipairs(ROWS) do
	candidatesForRow[entry.name] = {}
end
for index, candidate in ipairs(candidates) do
	rowsForCandidate[index] = {}
	for _, entry in ipairs(ROWS) do
		if hasSentinel(candidate.instance, entry.sentinel) then
			table.insert(rowsForCandidate[index], entry)
			table.insert(candidatesForRow[entry.name], candidate)
		end
	end
end

say("")
say("================================================================")
say(DRY_RUN and "How-to-Fish adopt Scenes - DRY RUN (nothing changed)" or "How-to-Fish adopt Scenes - LIVE")
say("  candidates named Scene : " .. #candidates)
say("  rows in ledger         : " .. #ROWS)
say("================================================================")

local plan = {}
local unidentified = 0
local ambiguous = 0

say("")
say("---- IDENTIFICATION")
if #candidates == 0 then
	say('  no top-level group named "Scene" under Workspace or ReplicatedStorage.')
end
for index, candidate in ipairs(candidates) do
	local hits = rowsForCandidate[index]
	if #hits == 0 then
		unidentified = unidentified + 1
		say("  " .. candidate.where .. ": UNIDENTIFIED - no ledger sentinel found")
		say("      first children: " .. firstChildNames(candidate.instance, 5))
		local objects = topLevelCount(candidate.instance)
		say("      (" .. objects .. " top-level objects, " .. countParts(candidate.instance) .. " parts)")
	elseif #hits > 1 then
		ambiguous = ambiguous + 1
		local names = {}
		for _, entry in ipairs(hits) do
			table.insert(names, entry.name .. " (" .. entry.sentinel .. ")")
		end
		say("  " .. candidate.where .. ": AMBIGUOUS - matches " .. table.concat(names, " and "))
		say("      NOT TOUCHED. The sentinels are supposed to be distinct; sort this out by hand.")
	else
		local entry = hits[1]
		local rivals = candidatesForRow[entry.name]
		if #rivals > 1 then
			ambiguous = ambiguous + 1
			local wheres = {}
			for _, rival in ipairs(rivals) do
				table.insert(wheres, rival.where)
			end
			local claim = "row " .. entry.row .. " (" .. entry.name .. ") is also claimed by "
			say("  " .. candidate.where .. ": AMBIGUOUS - " .. claim .. table.concat(wheres, ", "))
			say("      NOT TOUCHED. Delete or rename the duplicate imports, then run again.")
		else
			local found = " (sentinel " .. entry.sentinel .. " found)"
			say("  " .. candidate.where .. ": row " .. entry.row .. " -> Assets." .. entry.name .. found)
			local objects = topLevelCount(candidate.instance)
			local parts = countParts(candidate.instance)
			if entry.expected == nil then
				say("      " .. objects .. " top-level objects, " .. parts .. " parts (ledger states no count)")
			elseif objects == entry.expected then
				local ok = " top-level objects == ledger's " .. entry.expected .. " OK, "
				say("      " .. objects .. ok .. parts .. " parts")
			else
				local vs = " top-level objects vs ledger's " .. entry.expected
				say("      WARNING: " .. objects .. vs .. " - adopting anyway")
			end
			if entry.expectedNote then
				say("      KNOWN STALE LEDGER COUNT: " .. entry.expectedNote)
			end
			table.insert(plan, { candidate = candidate, entry = entry })
		end
	end
end

--=====================================================================
-- 2-4. ADOPT / FIDELITY / NEON
--=====================================================================

local assets, createdAssets = getAssetsFolder()
if createdAssets then
	say("")
	say(DRY_RUN and "* would CREATE ReplicatedStorage.Assets" or "* created ReplicatedStorage.Assets")
end

local oldGroups = {}
local manualFidelity = {}
local adopted = 0
local misses = {}

for _, job in ipairs(plan) do
	local entry = job.entry
	local group = job.candidate.instance
	say("")
	say("---- [row " .. entry.row .. "] " .. job.candidate.where .. "  ->  Assets." .. entry.name)

	local existing = assets and assets:FindFirstChild(entry.name) or nil

	local ok, err = pcall(function()
		if DRY_RUN then
			say("  PLAN: rename to '" .. entry.name .. "', parent to ReplicatedStorage.Assets (children untouched)")
			if existing then
				local oldName = entry.name .. "_old_" .. timestamp
				say("        existing Assets." .. entry.name .. " would be RENAMED to " .. oldName .. " (kept)")
			end
			if entry.fidelity then
				local rules = {}
				for _, rule in ipairs(entry.fidelity) do
					table.insert(rules, rule[1] .. "=" .. rule[2].Name)
				end
				say("        fidelity rules (" .. #entry.fidelity .. "): " .. table.concat(rules, ", "))
				say("        would set fidelity on " .. previewFidelity(group, entry.fidelity) .. " MeshParts")
			else
				say("        fidelity: none - the row says it does not matter (collision-free clones)")
			end
			local neon = neonTargetsIn(group)
			if #neon > 0 then
				say("        would set Neon on: " .. table.concat(neon, ", "))
			end
			for _, line in ipairs(assertNotNeon(group)) do
				say("        assert: " .. line)
			end
			return
		end

		if existing and existing ~= group then
			local oldName = entry.name .. "_old_" .. timestamp
			existing.Name = oldName
			table.insert(oldGroups, oldName)
			say("  displaced: old Assets." .. entry.name .. " renamed to " .. oldName .. " (kept, never deleted)")
		end

		-- Rename the TOP-LEVEL group only. Children are the contract.
		group.Name = entry.name
		group.Parent = assets
		adopted = adopted + 1
		say("  ADOPTED: renamed and parented to ReplicatedStorage.Assets")

		local present = namesPresent(group)
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

		local appliedFidelity, failedFidelity = applyFidelity(group, entry.fidelity)
		if entry.fidelity == nil then
			say("  fidelity: skipped by design - the row says it does not matter")
		elseif #appliedFidelity == 0 and #failedFidelity == 0 then
			say("  fidelity: NO PARTS MATCHED - the rules and the mesh disagree, check by hand")
		else
			say("  fidelity: " .. #appliedFidelity .. " parts set")
			for _, line in ipairs(appliedFidelity) do
				say("            " .. line)
			end
		end
		for _, name in ipairs(failedFidelity) do
			table.insert(manualFidelity, "Assets." .. entry.name .. "." .. name)
			say("  fidelity: COULD NOT SET " .. name .. " - do it by hand in the Properties panel")
		end

		for _, line in ipairs(applyMaterials(group)) do
			say("  material: " .. line)
		end
		for _, line in ipairs(assertNotNeon(group)) do
			say("  assert  : " .. line)
		end
	end)

	if not ok then
		say("  ERROR while handling this row: " .. tostring(err))
		say("  MANUAL: rename the group to '" .. entry.name .. "' and drag it into ReplicatedStorage.Assets")
	end
end

--=====================================================================
-- 5. REPORT
--=====================================================================

say("")
say("================================================================")
if #candidates == 0 then
	say('NOTHING TO ADOPT: no group named "Scene" is left in Workspace or')
	say("ReplicatedStorage. If you have already run this script, that is exactly")
	say("what a second run should say - adopted groups are renamed, so they stop")
	say("being candidates. The presence check below is the verification report.")
else
	local counts = #plan .. " identified, " .. unidentified .. " unidentified, " .. ambiguous .. " ambiguous"
	say("SUMMARY: " .. #candidates .. " Scene groups found, " .. counts .. ", " .. adopted .. " adopted")
end

-- Runs on EVERY pass, dry or live: the state of Assets against the ledger.
say("")
say("PRESENCE CHECK - the 21 ledger rows against ReplicatedStorage.Assets:")
local missingRows = {}
for _, entry in ipairs(ROWS) do
	local group = assets and assets:FindFirstChild(entry.name) or nil
	if group then
		local sentinelOk = hasSentinel(group, entry.sentinel) and "sentinel OK" or "SENTINEL MISSING"
		local shape = topLevelCount(group) .. " objects, " .. countParts(group) .. " parts, "
		say("  present : Assets." .. entry.name .. "  (" .. shape .. sentinelOk .. ")")
	else
		table.insert(missingRows, entry)
		say("  MISSING : Assets." .. entry.name .. "  (row " .. entry.row .. ", from " .. entry.file .. ")")
	end
end

if #missingRows > 0 then
	say("")
	say("NO CANDIDATE FOUND for the rows above. Either the hand import for them")
	say("has not happened, or their groups were renamed to something other than")
	say('"Scene" (in which case rename them back and run this again). FALLBACK:')
	for _, entry in ipairs(missingRows) do
		say("  " .. entry.file .. " -> Assets." .. entry.name)
	end
	say("  * run tools/studio_import.lua, which imports these files itself, or")
	say("  * File -> Import 3D... each file by hand, then run this script again.")
end

if #oldGroups > 0 then
	say("")
	say("OLD GROUPS KEPT (nothing was deleted) - delete these BY HAND once you")
	say("have verified the new meshes in-game:")
	for _, name in ipairs(oldGroups) do
		say("  ReplicatedStorage.Assets." .. name)
	end
end

if #misses > 0 then
	say("")
	say("the game will use a stand-in and warn for: " .. table.concat(misses, ", "))
end

if #manualFidelity > 0 then
	say("")
	say("COLLISION FIDELITY TO SET BY HAND (the assignment threw on this build -")
	say("select each part, Properties panel, CollisionFidelity):")
	for _, name in ipairs(manualFidelity) do
		say("  " .. name)
	end
end

say("")
say("MATERIAL ADVISORIES (ledger rows this script deliberately leaves to you):")
for _, line in ipairs(MANUAL_MATERIAL_ADVISORIES) do
	say("  " .. line)
end

say("")
if DRY_RUN then
	say("THIS WAS A DRY RUN. Nothing was renamed, moved or changed. If the")
	say("identification above looks right, set DRY_RUN = false at the top and")
	say("run again.")
else
	say("TWO MANUAL STEPS REMAIN:")
	say("  1. Right-click ReplicatedStorage.Assets -> Save to File... -> assets/Assets.rbxm (overwrite)")
	say("  2. Restart `rojo serve` and reconnect (it does not watch .rbxm files)")
end
say("================================================================")
say("")

print(table.concat(report, "\n"))
