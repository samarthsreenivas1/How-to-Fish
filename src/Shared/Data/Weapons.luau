--!nonstrict
-- Weapons.luau
-- Weapons, as rows - the same id-keyed shape as Rods / Creatures / Materials.
-- Melee AND ranged: the old "never a ranged row here" rule was overturned by
-- the user on 2026-08-24 (docs/revamp-plan.md), and the ranged engine is live
-- (revamp Session 2). A row with a `ranged` block shoots (CombatService's shot
-- pipeline: hitscan at fire time, damage after the flight delay); a row
-- without one is pure melee, exactly as before. Flavor arc: fantasy early
-- (bow / crossbow / flintlock), modern firearms from the volcano island on.
--
-- THINNED 2026-08-25 (docs/revamp-plan.md): every island carries exactly five
-- craftable weapons, the fists apart, and each island's Legendary is gated on
-- that island's boss heart (recipe `requiresHearts` - owned, never spent).
-- Fourteen stat-shuffle weapons were cut; every perk effect survives on the
-- keepers or on later islands' weapons. The volcano currently fields only its
-- two kept melee weapons - its three guns land with the ranged engine.
--
-- The fists are the starter weapon every player owns and can't lose. Their
-- numbers are the ones CombatService always punched with (Tuning.Combat),
-- referenced here rather than copied so the inventory card can never drift
-- from what actually lands. Crafted weapons carry their own numbers in their
-- row. CombatService reads whichever row is equipped
-- (InventoryService.getEquippedWeapon) for damage / cooldown / reach /
-- knockback; the viewmodels read `swing` (which WeaponSwingAnim clip a hit
-- plays) and `model` (how WeaponModel builds the thing in the hand). A row
-- with no `model` is bare hands - FistsViewmodelController draws those with
-- the punch clips.
--
-- Ownership lives in InventoryService alongside rods (one mixed id list per
-- player). A `recipe` makes a row craftable through CraftingService - the
-- same shape a rod's recipe has, so crafting stays item-agnostic.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Tuning = require(Shared.Config.Tuning)

local Weapons = {}

-- What it costs to craft (CraftingService). Identical to Rods.Recipe;
-- duplicated rather than imported so this file stays a plain data row.
-- `requiresHearts` lists Bosses ids whose Heart_<bossId> attribute the player
-- must carry - checked, never spent.
export type Recipe = {
	requiresLevel: number,
	coins: number,
	materials: { [string]: number },
	requiresHearts: { string }?,
}

-- How the weapon is built in the hand (WeaponModel). Like the rod, a weapon
-- is authored standing along +Y: butt at 0, tip at `length`, and the hand
-- closes at `grip` studs up (the centre of the Weapon_Grip part).
--
-- Two ways to look: `shape` builds it procedurally (the starter club/blade);
-- `variant` (+ `model`) instead pulls a Blender mesh out of the shared
-- WeaponPack (assets/weapon_gen.py, WeaponModel.assembleVariant). A mesh row
-- keeps a `shape` too, as the pre-import fallback so it's never invisible; its
-- `length`/`grip` must match the variant in weapon_gen.py.
export type WeaponModel = {
	shape: string, -- procedural fallback builder: "club" | "blade"
	model: string?, -- pack under ReplicatedStorage/Assets for a mesh weapon (e.g. "WeaponPack")
	variant: string?, -- which variant's parts to pull from the pack; nil = procedural only
	length: number, -- butt to tip, studs
	grip: number, -- hand point up from the butt, studs
	color: Color3, -- haft / handle (Weapon_Haft/_Guard/_Pommel)
	accent: Color3, -- the business end: club head, blade, claws (Weapon_Head/_Edge/_Spike)
	wrap: Color3, -- the grip binding (Weapon_Grip)
	glow: Color3?, -- glowing runes / lights (Weapon_Glow), if any
	neon: { string }?, -- generic part names (e.g. "Weapon_Glow") that should glow
}

-- A weapon's signature ability, on the rarer weapons only. `name`/`description`
-- are what the inventory and crafting cards show; the rest is the effect, each
-- read by exactly one place in CombatService:
--
--   poison       { damage, duration } - stacks damage-over-time on hit
--                (CreatureService.poison). Burns on through a creature that is
--                untargetable, so it beats a boss's dive.
--   uproot       launches even archetypes that are normally pinned to the
--                ground (CreatureService.applyKnockback), except the ones in
--                Tuning.Perks.UPROOT_IMMUNE.
--   frenzy       consecutive hits ramp damage (Tuning.Perks.FRENZY_*).
--
-- Optional: most weapons have none.
export type Perk = {
	id: string,
	name: string,
	description: string,
	poison: { damage: number, duration: number }?,
	uproot: boolean?,
	frenzy: boolean?,
	cleave: boolean?, -- also hits everything else in reach (Tuning.Perks.CLEAVE_FALLOFF)
	execute: boolean?, -- big bonus damage to a wounded target (EXECUTE_BELOW / _MULT)
	lifesteal: boolean?, -- heals the attacker for a share of the damage dealt (LIFESTEAL)
}

-- Makes a row a GUN (or bow): present = the row shoots through CombatService's
-- shot pipeline instead of swinging; nil = pure melee. `damage` on the row is
-- then per SHOT (per PELLET for a scattergun) and `cooldown` the time between
-- shots; `reach` and `swing` are unused for a ranged row. Balance rule
-- (docs/revamp-plan.md): ranged sustained DPS sits 10-20% under same-tier
-- melee (the safety premium), burst above it. Ranged rows use knockback 0-4
-- and never `launch`.
export type Ranged = {
	projectileSpeed: number, -- studs/second; sets the cosmetic flight delay (damage lands at distance/speed)
	range: number, -- the hitscan ray goes no further than this, studs
	fireMode: string, -- "single" | "scoped" | "auto" (auto = fires while the button is held)
	magazine: number, -- shots before a reload; the server tracks the count
	reloadTime: number, -- seconds the empty-mag reload takes (server-enforced); 0 = the cooldown IS the reload (bows)
	spread: number?, -- radians of random cone per pellet (shotguns)
	pellets: number?, -- pellets per shot, each its own ray (shotguns)
	arc: boolean?, -- bows: ballistic draw + a landing re-check, so a dodged arrow misses
	zoomFov: number?, -- scoped: FOV while aiming (default Tuning.Ranged.DEFAULT_ZOOM_FOV)
}

export type Weapon = {
	id: string,
	name: string,
	description: string,
	rarity: string, -- Common | Uncommon | Rare | Epic | Legendary
	icon: string, -- inventory image asset id ("rbxassetid://..."); "" shows the blank placeholder
	damage: { number }, -- { min, max } per hit (per shot / pellet for a ranged row)
	cooldown: number, -- seconds between swings or shots (server-enforced)
	reach: number, -- studs from the player a creature can be hit (melee only)
	knockback: number, -- shove speed on a non-killing hit, studs/sec (see Tuning.Combat.KNOCKBACK_SPEED)
	swing: string?, -- WeaponSwingAnim clip name; nil = the fist punch clips (melee only)
	model: WeaponModel?, -- nil = bare hands
	ranged: Ranged?, -- present = this row shoots; nil = pure melee
	recipe: Recipe?,
	perk: Perk?,
}

Weapons.items = {} :: { [string]: Weapon }

Weapons.items.fists = {
	id = "fists",
	name = "Fists",
	description = "Bare knuckles. Fast, close, and always with you.",
	rarity = "Common",
	icon = "rbxassetid://136932594248437", -- assets/icons/fists.png
	damage = { Tuning.Combat.PUNCH_DAMAGE_MIN, Tuning.Combat.PUNCH_DAMAGE_MAX },
	cooldown = Tuning.Combat.PUNCH_COOLDOWN,
	reach = Tuning.Combat.PUNCH_REACH,
	knockback = Tuning.Combat.KNOCKBACK_SPEED,
}

-- ============================================================ Starter Cove (L2-7)

-- Balance, as damage per second against a 150 HP pufferfish: fists land
-- ~57 dps (8 avg / 0.14 s), so a crafted weapon has to beat that or it's a
-- downgrade. The club is slow and heavy - big numbers, a long knockback -
-- the blade is quick and vicious. Recipes escalate in level, mats and coins
-- the way the rods do, and lean on the materials the fiction suggests.

Weapons.items.driftwood_club = {
	id = "driftwood_club",
	name = "Driftwood Club",
	description = "A knotted length of driftwood bound with kelp. Slow, heavy, and it sends a fish flying.",
	rarity = "Common",
	icon = "rbxassetid://103747711262343", -- assets/icons/driftwood_club.png
	damage = { 26, 38 }, -- ~71 dps
	cooldown = 0.45,
	reach = 15,
	knockback = 26,
	swing = "chop",
	model = {
		shape = "club", -- pre-import fallback; the WeaponPack's DriftwoodClub_* is preferred
		model = "WeaponPack",
		variant = "DriftwoodClub",
		length = 3.4,
		grip = 0.7,
		color = Color3.fromRGB(150, 112, 72),
		accent = Color3.fromRGB(118, 86, 54),
		wrap = Color3.fromRGB(86, 140, 84),
	},
	recipe = {
		requiresLevel = 2,
		coins = 80,
		materials = { driftwood = 10, kelp_fiber = 4 },
	},
}

Weapons.items.scale_blade = {
	id = "scale_blade",
	name = "Scaleblade",
	description = "Fish scales ground to an edge and set into a driftwood haft. Quick, light, and mean.",
	rarity = "Uncommon",
	icon = "rbxassetid://119578057079608", -- assets/icons/scale_blade.png
	damage = { 13, 19 }, -- ~80 dps
	cooldown = 0.2,
	reach = 14,
	knockback = 12,
	swing = "slash",
	model = {
		shape = "blade", -- pre-import fallback; the WeaponPack's Scaleblade_* is preferred
		model = "WeaponPack",
		variant = "Scaleblade",
		length = 3.1,
		grip = 0.6,
		color = Color3.fromRGB(128, 96, 62), -- wooden guard + pommel
		accent = Color3.fromRGB(184, 209, 230), -- the scale plates
		wrap = Color3.fromRGB(96, 70, 46), -- bound wooden handle
	},
	recipe = {
		requiresLevel = 3,
		coins = 260,
		materials = { driftwood = 6, fish_scale = 12, pearl = 1 },
	},
	perk = {
		id = "frenzy",
		name = "Frenzy",
		description = "It feeds on its own rhythm - every hit in an unbroken chain cuts deeper, up to half again.",
		frenzy = true,
	},
}

Weapons.items.shellcrusher = {
	id = "shellcrusher",
	name = "Shellcrusher",
	description = "A slab of barnacle chitin lashed to a driftwood haft. Ponderous, but it caves a fish in and hurls the pieces.",
	rarity = "Rare",
	icon = "rbxassetid://88199503112154", -- assets/icons/shellcrusher.png
	damage = { 40, 58 }, -- ~89 dps
	cooldown = 0.55,
	reach = 16,
	knockback = 34,
	swing = "chop",
	model = {
		shape = "club", -- pre-import fallback; the WeaponPack's Shellcrusher_* is preferred
		model = "WeaponPack",
		variant = "Shellcrusher",
		length = 3.6,
		grip = 0.8,
		color = Color3.fromRGB(140, 107, 68), -- driftwood haft
		accent = Color3.fromRGB(125, 150, 150), -- barnacle chitin head + claws
		wrap = Color3.fromRGB(74, 86, 78), -- bound grip
	},
	recipe = {
		requiresLevel = 4,
		coins = 340,
		materials = { barnacle_chitin = 10, driftwood = 8 },
	},
	perk = {
		id = "uproot",
		name = "Uproot",
		description = "Nothing stays planted. Its blows hurl even the things that brace against the ground - bosses excepted.",
		uproot = true,
	},
}

Weapons.items.drowncleaver = {
	id = "drowncleaver",
	name = "Drowncleaver",
	description = "A broad blade of cursed bone that never dries, its runes lit brine-green. Fast, cruel, and hungry.",
	rarity = "Epic",
	icon = "rbxassetid://100868335934438", -- assets/icons/drowncleaver.png
	damage = { 20, 30 }, -- ~113 dps
	cooldown = 0.22,
	reach = 15,
	knockback = 16,
	swing = "slash",
	model = {
		shape = "blade", -- pre-import fallback; the WeaponPack's Drowncleaver_* is preferred
		model = "WeaponPack",
		variant = "Drowncleaver",
		length = 3.7, -- a tall cleaver blade; matches weapon_gen.py FRAME
		grip = 0.7,
		color = Color3.fromRGB(150, 140, 110), -- bone handle
		accent = Color3.fromRGB(209, 205, 182), -- pale bone blade
		wrap = Color3.fromRGB(56, 66, 56), -- brine-dark grip
		glow = Color3.fromRGB(115, 242, 140), -- the runes
		neon = { "Weapon_Glow" },
	},
	recipe = {
		requiresLevel = 5,
		coins = 520,
		materials = { cursed_bone = 12, fish_scale = 8, pearl = 2 },
	},
	perk = {
		id = "brine_rot",
		name = "Brine Rot",
		description = "The wound never dries. Every cut festers, and the rot keeps eating even when its victim hides.",
		poison = { damage = 45, duration = 4 },
	},
}

Weapons.items.heartrender = {
	id = "heartrender",
	name = "Heartrender",
	description = "Forged in the presence of Brinejaw's heart, which never stopped beating. It drinks what it kills.",
	rarity = "Legendary",
	icon = "",
	damage = { 30, 44 }, -- ~132 dps, and it feeds you while you fight
	cooldown = 0.28,
	reach = 16,
	knockback = 20,
	swing = "slash",
	model = {
		shape = "blade",
		model = "WeaponPack",
		variant = "Heartrender",
		length = 3.9,
		grip = 0.72,
		color = Color3.fromRGB(92, 62, 66), -- dark heartwood grip
		accent = Color3.fromRGB(196, 78, 82), -- the red blade
		wrap = Color3.fromRGB(58, 40, 44),
		glow = Color3.fromRGB(255, 96, 104), -- the beat
		neon = { "Weapon_Glow" },
	},
	-- The island's capstone: gated on the heart itself (owned, never spent).
	recipe = {
		requiresLevel = 7,
		coins = 1200,
		materials = { cursed_bone = 12, volt_gland = 6, nacre = 4 },
		requiresHearts = { "brinejaw" },
	},
	perk = {
		id = "devour",
		name = "Devour",
		description = "Every wound it opens feeds you - a share of the damage comes back as your own health.",
		lifesteal = true,
	},
}

-- ============================================================ Blackmire Fen (L8-14)
-- The swamp's five (revamp Session 2): TWO melee, THREE ranged - this is the
-- island that introduces guns, at the fantasy tier (bow / crossbow /
-- flintlock). Balance per the plan: ranged sustained DPS sits under
-- same-tier melee (the safety premium - you're shooting from outside contact
-- range), burst above it. Damage on a ranged row is per SHOT; `cooldown` the
-- time between shots; mag-1 weapons fold the reload into the cooldown
-- (reloadTime 0 - nocking IS the draw).

Weapons.items.bogwood_bow = {
	id = "bogwood_bow",
	name = "Bogwood Bow",
	description = "A recurve of steam-bent bogwood strung with gut. The fen's gulls learned to fear it first.",
	rarity = "Uncommon",
	icon = "",
	damage = { 28, 40 }, -- ~76 dps sustained; the first answer to a circling flyer
	cooldown = 0.45,
	reach = 0,
	knockback = 3,
	model = {
		shape = "bow", -- pre-import fallback; the WeaponPack's BogwoodBow_* is preferred
		model = "WeaponPack",
		variant = "BogwoodBow",
		length = 3.4,
		grip = 1.7,
		color = Color3.fromRGB(110, 92, 58), -- steam-bent bogwood
		accent = Color3.fromRGB(214, 206, 180), -- the gut string
		wrap = Color3.fromRGB(74, 88, 58), -- moss-cord grip
	},
	ranged = {
		projectileSpeed = 90,
		range = 110,
		fireMode = "single",
		magazine = 1,
		reloadTime = 0,
		arc = true, -- a real arrow: lobbed, and a dodged one misses
	},
	recipe = {
		requiresLevel = 8,
		coins = 350,
		materials = { bog_iron = 5, driftwood = 10, kelp_fiber = 6 },
	},
}

Weapons.items.rustfang_machete = {
	id = "rustfang_machete",
	name = "Rustfang Machete",
	description = "A broad blade eaten to a ragged edge by bog water. What it cuts keeps rotting.",
	rarity = "Rare",
	icon = "",
	damage = { 24, 34 }, -- ~121 dps, and the rot on top
	cooldown = 0.24,
	reach = 15,
	knockback = 14,
	swing = "slash",
	model = {
		shape = "blade",
		model = "WeaponPack",
		variant = "RustfangMachete",
		length = 3.3,
		grip = 0.62,
		color = Color3.fromRGB(96, 78, 54), -- bog-oak handle
		accent = Color3.fromRGB(164, 98, 62), -- the rust-eaten blade
		wrap = Color3.fromRGB(64, 70, 50),
	},
	recipe = {
		requiresLevel = 9,
		coins = 550,
		materials = { bog_iron = 10, gator_scute = 4 },
	},
	perk = {
		id = "fen_rot",
		name = "Fen Rot",
		description = "The rust never sleeps - every cut festers on, even through hide or murk.",
		poison = { damage = 55, duration = 4 },
	},
}

Weapons.items.gatorjaw_crossbow = {
	id = "gatorjaw_crossbow",
	name = "Gatorjaw Crossbow",
	description = "A crossbow stocked in gator scute, its prod drawn by a jaw spring. It hits like the animal did.",
	rarity = "Rare",
	icon = "",
	damage = { 90, 120 }, -- a heavy single bolt: burst over a melee blade, slower between
	cooldown = 1.3,
	reach = 0,
	knockback = 4,
	model = {
		shape = "bow", -- pre-import fallback; the WeaponPack's GatorjawCrossbow_* is preferred
		model = "WeaponPack",
		variant = "GatorjawCrossbow",
		length = 3.0,
		grip = 0.8,
		color = Color3.fromRGB(94, 116, 72), -- scute-plated stock
		accent = Color3.fromRGB(206, 198, 160), -- bone prod and bolt
		wrap = Color3.fromRGB(58, 70, 48),
	},
	ranged = {
		projectileSpeed = 140,
		range = 140,
		fireMode = "single",
		magazine = 1,
		reloadTime = 0,
	},
	recipe = {
		requiresLevel = 11,
		coins = 900,
		materials = { gator_scute = 10, bog_iron = 8, kelp_fiber = 6 },
	},
}

Weapons.items.mire_flintlock = {
	id = "mire_flintlock",
	name = "Mire Flintlock",
	description = "A long-barrelled flintlock kept dry through the wettest place on earth. One shot, made to finish things.",
	rarity = "Epic",
	icon = "",
	damage = { 110, 150 }, -- one thunderclap; double into a wounded target
	cooldown = 1.8,
	reach = 0,
	knockback = 4,
	model = {
		shape = "gun", -- pre-import fallback; the WeaponPack's MireFlintlock_* is preferred
		model = "WeaponPack",
		variant = "MireFlintlock",
		length = 2.3,
		grip = 0.5,
		color = Color3.fromRGB(84, 62, 44), -- walnut stock
		accent = Color3.fromRGB(178, 160, 120), -- the brass barrel
		wrap = Color3.fromRGB(56, 46, 36),
	},
	ranged = {
		projectileSpeed = 220,
		range = 150,
		fireMode = "single",
		magazine = 1,
		reloadTime = 0,
	},
	recipe = {
		requiresLevel = 12,
		coins = 1400,
		materials = { bog_iron = 14, fen_venom = 2, pearl = 2 },
	},
	perk = {
		id = "powder_mercy",
		name = "Powder Mercy",
		description = "Made for the killing shot - a wounded target takes double from the ball.",
		execute = true,
	},
}

Weapons.items.fenreaver = {
	id = "fenreaver",
	name = "Fenreaver",
	description = "A root-bark glaive cut in the presence of Old Gnashroot's heart. The fen feeds whoever swings it.",
	rarity = "Legendary",
	icon = "",
	damage = { 38, 54 }, -- ~170 dps, and it feeds you while you fight
	cooldown = 0.27,
	reach = 16,
	knockback = 18,
	swing = "slash",
	model = {
		shape = "blade",
		model = "WeaponPack",
		variant = "Fenreaver",
		length = 3.8,
		grip = 0.7,
		color = Color3.fromRGB(58, 66, 46), -- moss-black root wood
		accent = Color3.fromRGB(150, 235, 200), -- the wisp-lit edge
		wrap = Color3.fromRGB(44, 48, 36),
		glow = Color3.fromRGB(150, 235, 200),
		neon = { "Weapon_Glow" },
	},
	-- The fen's capstone: gated on the Tyrant's heart (owned, never spent).
	recipe = {
		requiresLevel = 14,
		coins = 2600,
		materials = { fen_venom = 5, bog_iron = 12, wisp_light = 6, gator_scute = 8 },
		requiresHearts = { "old_gnashroot" },
	},
	perk = {
		id = "bog_feast",
		name = "Bog Feast",
		description = "Every wound it opens feeds you - a share of the damage comes back as your own health.",
		lifesteal = true,
	},
}

-- ============================================================ Ashfall Caldera (interim L8-14)
-- The volcano's two kept melee weapons, buffed for their slot, plus its
-- three GUNS (revamp Session 2) - the first modern firearms, gated at the
-- island's FINAL L22-28 band (the volcano slides to slot 4; b8's re-gate
-- pass moves the melee pair to match).

Weapons.items.obsidian_piercer = {
	id = "obsidian_piercer",
	name = "Obsidian Piercer",
	description = "A driftwood haft tipped in a shard of glass-black obsidian, honed to a wicked point. It finishes what it starts.",
	rarity = "Rare",
	icon = "",
	damage = { 38, 54 }, -- ~115 dps, and double into a wounded target
	cooldown = 0.4,
	reach = 15,
	knockback = 24,
	swing = "slash",
	model = {
		shape = "blade", -- pre-import fallback; the WeaponPack's ObsidianPiercer_* is preferred
		model = "WeaponPack",
		variant = "ObsidianPiercer",
		length = 3.5,
		grip = 0.64,
		color = Color3.fromRGB(140, 107, 68), -- driftwood haft
		accent = Color3.fromRGB(48, 44, 60), -- glass-black obsidian
		wrap = Color3.fromRGB(60, 52, 46), -- dark binding
		glow = Color3.fromRGB(240, 132, 52), -- the hairline crack of heat inside the glass
		neon = { "Weapon_Glow" },
	},
	recipe = {
		requiresLevel = 9,
		coins = 400,
		materials = { obsidian_shard = 10, driftwood = 8 },
	},
	perk = {
		id = "glass_edge",
		name = "Glass Edge",
		description = "Cracked obsidian punches clean through anything already wounded - the weaker the target, the deeper it goes.",
		execute = true,
	},
}

Weapons.items.magma_gauntlets = {
	id = "magma_gauntlets",
	name = "Magma Gauntlets",
	description = "Magma-core knuckles wrapped in sulfur-cured fish scale, still warm from the vent. Every hit in a row lands harder.",
	rarity = "Epic",
	icon = "",
	damage = { 34, 46 }, -- ~182 dps
	cooldown = 0.22,
	reach = 15,
	knockback = 16,
	swing = "slash",
	model = {
		shape = "blade", -- pre-import fallback; the WeaponPack's MagmaGauntlets_* is preferred
		model = "WeaponPack",
		variant = "MagmaGauntlets",
		length = 3.2,
		grip = 0.62,
		color = Color3.fromRGB(70, 58, 56), -- dark vent-metal haft
		accent = Color3.fromRGB(226, 206, 88), -- sulfur-cured claws
		wrap = Color3.fromRGB(150, 186, 210), -- fish-scale binding
		glow = Color3.fromRGB(244, 96, 40), -- the magma vein
		neon = { "Weapon_Glow" },
	},
	recipe = {
		requiresLevel = 12,
		coins = 700,
		materials = { magma_core = 8, sulfur = 10, fish_scale = 8 },
	},
	perk = {
		id = "magma_flurry",
		name = "Magma Flurry",
		description = "The heat builds with every hit - land them in an unbroken chain and each one lands harder than the last.",
		frenzy = true,
	},
}

-- The volcano's three guns: the first full-auto tier. Final L22-28 gates.

Weapons.items.cinderlock_carbine = {
	id = "cinderlock_carbine",
	name = "Cinderlock Carbine",
	description = "A vent-forged carbine that never stops being warm. The first thing on any island that just keeps firing.",
	rarity = "Uncommon",
	icon = "",
	damage = { 15, 21 }, -- per round; ~110 dps sustained across the reload
	cooldown = 0.13,
	reach = 0,
	knockback = 2,
	model = {
		shape = "gun", -- pre-import fallback; the WeaponPack's CinderlockCarbine_* is preferred
		model = "WeaponPack",
		variant = "CinderlockCarbine",
		length = 3.2,
		grip = 0.9,
		color = Color3.fromRGB(70, 58, 56), -- vent-metal furniture
		accent = Color3.fromRGB(240, 132, 52), -- the heat-striped barrel
		wrap = Color3.fromRGB(50, 44, 42),
	},
	ranged = {
		projectileSpeed = 300,
		range = 180,
		fireMode = "auto",
		magazine = 24,
		reloadTime = 0.8,
	},
	recipe = {
		requiresLevel = 22,
		coins = 2200,
		materials = { ember = 10, obsidian_shard = 6, sulfur = 6 },
	},
}

Weapons.items.basalt_scattergun = {
	id = "basalt_scattergun",
	name = "Basalt Scattergun",
	description = "A twin-tube scattergun that throws a fistful of basalt shot. Everything close regrets it.",
	rarity = "Rare",
	icon = "",
	damage = { 24, 34 }, -- per PELLET, six a shell: a point-blank thunderclap
	cooldown = 0.75,
	reach = 0,
	knockback = 4,
	model = {
		shape = "gun", -- pre-import fallback; the WeaponPack's BasaltScattergun_* is preferred
		model = "WeaponPack",
		variant = "BasaltScattergun",
		length = 3.0,
		grip = 0.85,
		color = Color3.fromRGB(60, 62, 70), -- basalt-grey tubes
		accent = Color3.fromRGB(226, 206, 88), -- sulfur-brass fittings
		wrap = Color3.fromRGB(48, 44, 42),
	},
	ranged = {
		projectileSpeed = 250,
		range = 60, -- close-range by design; the spread eats it past this anyway
		fireMode = "single",
		magazine = 2,
		reloadTime = 1.7,
		pellets = 6,
		spread = 0.075,
	},
	recipe = {
		requiresLevel = 25,
		coins = 3800,
		materials = { obsidian_shard = 12, sulfur = 8, ember = 8 },
	},
}

Weapons.items.vulkan_repeater = {
	id = "vulkan_repeater",
	name = "Vulkan Repeater",
	description = "Forged in the presence of Pyrelisk's heart, it fires rounds that are still burning. The mountain, made portable.",
	rarity = "Legendary",
	icon = "",
	damage = { 24, 32 }, -- per round; ~200 dps sustained, and the burn on top
	cooldown = 0.11,
	reach = 0,
	knockback = 2,
	model = {
		shape = "gun", -- pre-import fallback; the WeaponPack's VulkanRepeater_* is preferred
		model = "WeaponPack",
		variant = "VulkanRepeater",
		length = 3.6,
		grip = 0.95,
		color = Color3.fromRGB(38, 32, 40), -- cooled obsidian housing
		accent = Color3.fromRGB(255, 96, 16), -- the melt in every seam
		wrap = Color3.fromRGB(50, 44, 42),
		glow = Color3.fromRGB(255, 96, 16),
		neon = { "Weapon_Glow" },
	},
	ranged = {
		projectileSpeed = 320,
		range = 200,
		fireMode = "auto",
		magazine = 40,
		reloadTime = 1.2,
	},
	-- The volcano's ranged capstone: gated on the Wyrm's heart (owned, never
	-- spent).
	recipe = {
		requiresLevel = 28,
		coins = 9000,
		materials = { magma_core = 6, obsidian_shard = 15, ember = 12 },
		requiresHearts = { "pyrelisk" },
	},
	perk = {
		id = "incendiary_rounds",
		name = "Incendiary Rounds",
		description = "Every round is still burning when it lands - the fire keeps eating after the hit.",
		poison = { damage = 40, duration = 3 },
	},
}

-- Stable display order for the inventory / crafting menus (table iteration
-- order isn't guaranteed). Starter first, then by island and level gate.
Weapons.order = {
	"fists",
	"driftwood_club",
	"scale_blade",
	"shellcrusher",
	"drowncleaver",
	"heartrender",
	"bogwood_bow",
	"rustfang_machete",
	"gatorjaw_crossbow",
	"mire_flintlock",
	"fenreaver",
	"cinderlock_carbine",
	"obsidian_piercer",
	"basalt_scattergun",
	"magma_gauntlets",
	"vulkan_repeater",
}

-- Every player starts with (and can't lose) this one.
Weapons.STARTER_WEAPON_ID = "fists"

return Weapons
