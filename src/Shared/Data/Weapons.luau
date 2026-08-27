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
	projectile: boolean?, -- the shot IS this weapon's Weapon_Mag flying (arrow/bolt/iron):
	-- RangedFxController clones it as the visible projectile instead of a tracer
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
	swing = "cudgel_bash",
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
	swing = "scale_flick",
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
	swing = "shell_crush",
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
	swing = "drown_cleave",
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
	icon = "rbxassetid://122879905048594", -- assets/icons/heartrender.png
	damage = { 30, 44 }, -- ~132 dps, and it feeds you while you fight
	cooldown = 0.28,
	reach = 16,
	knockback = 20,
	swing = "heartcut",
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
	icon = "rbxassetid://75169985339775", -- assets/icons/bogwood_bow.png
	damage = { 28, 40 }, -- ~76 dps sustained; the first answer to a circling flyer
	cooldown = 0.45,
	reach = 0,
	knockback = 3,
	model = {
		shape = "bow", -- pre-import fallback; the WeaponPack's BogwoodBow_* is preferred
		model = "WeaponPack",
		variant = "BogwoodBow",
		length = 2.8,
		grip = 0.62,
		color = Color3.fromRGB(110, 92, 58), -- steam-bent bogwood
		accent = Color3.fromRGB(214, 206, 180), -- the gut string
		wrap = Color3.fromRGB(74, 88, 58), -- moss-cord grip
	},
	ranged = {
		projectile = true, -- a real arrow/bolt/iron flies, not a tracer
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
	icon = "rbxassetid://76269593379820", -- assets/icons/rustfang_machete.png
	damage = { 24, 34 }, -- ~121 dps, and the rot on top
	cooldown = 0.24,
	reach = 15,
	knockback = 14,
	swing = "rust_saw",
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
	icon = "rbxassetid://100811340036104", -- assets/icons/gatorjaw_crossbow.png
	damage = { 90, 120 }, -- a heavy single bolt: burst over a melee blade, slower between
	cooldown = 1.3,
	reach = 0,
	knockback = 4,
	model = {
		shape = "bow", -- pre-import fallback; the WeaponPack's GatorjawCrossbow_* is preferred
		model = "WeaponPack",
		variant = "GatorjawCrossbow",
		length = 2.8,
		grip = 0.75,
		color = Color3.fromRGB(94, 116, 72), -- scute-plated stock
		accent = Color3.fromRGB(206, 198, 160), -- bone prod and bolt
		wrap = Color3.fromRGB(58, 70, 48),
	},
	ranged = {
		projectile = true, -- a real arrow/bolt/iron flies, not a tracer
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
	icon = "rbxassetid://99405786488675", -- assets/icons/mire_flintlock.png
	damage = { 110, 150 }, -- one thunderclap; double into a wounded target
	cooldown = 1.8,
	reach = 0,
	knockback = 4,
	model = {
		shape = "gun", -- pre-import fallback; the WeaponPack's MireFlintlock_* is preferred
		model = "WeaponPack",
		variant = "MireFlintlock",
		length = 1.8,
		grip = 0.4,
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
	icon = "rbxassetid://110706469054067", -- assets/icons/fenreaver.png
	damage = { 38, 54 }, -- ~170 dps, and it feeds you while you fight
	cooldown = 0.27,
	reach = 16,
	knockback = 18,
	swing = "root_reap",
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

-- ============================================================ Ashfall Caldera (L22-28)
-- The volcano's two kept melee weapons plus its three GUNS (revamp Session
-- 2) - the first modern firearms. Everything sits at the island's FINAL
-- slot-4 band (Session 4 re-gate brought the melee pair's gates, costs and
-- damage up to match the guns).

Weapons.items.obsidian_piercer = {
	id = "obsidian_piercer",
	name = "Obsidian Piercer",
	description = "A driftwood haft tipped in a shard of glass-black obsidian, honed to a wicked point. It finishes what it starts.",
	rarity = "Rare",
	icon = "rbxassetid://70552990256224", -- assets/icons/obsidian_piercer.png
	damage = { 62, 86 }, -- ~185 dps, and double into a wounded target
	cooldown = 0.4,
	reach = 15,
	knockback = 24,
	swing = "glass_pierce",
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
		requiresLevel = 23,
		coins = 1400,
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
	icon = "rbxassetid://100685218857815", -- assets/icons/magma_gauntlets.png
	damage = { 44, 60 }, -- ~236 dps
	cooldown = 0.22,
	reach = 15,
	knockback = 16,
	swing = "magma_piston",
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
		requiresLevel = 26,
		coins = 4800,
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
	icon = "rbxassetid://90210232121025", -- assets/icons/cinderlock_carbine.png
	damage = { 15, 21 }, -- per round; ~110 dps sustained across the reload
	cooldown = 0.13,
	reach = 0,
	knockback = 2,
	model = {
		shape = "gun", -- pre-import fallback; the WeaponPack's CinderlockCarbine_* is preferred
		model = "WeaponPack",
		variant = "CinderlockCarbine",
		length = 3.25,
		grip = 1.05,
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
	icon = "rbxassetid://117879470863407", -- assets/icons/basalt_scattergun.png
	damage = { 24, 34 }, -- per PELLET, six a shell: a point-blank thunderclap
	cooldown = 0.75,
	reach = 0,
	knockback = 4,
	model = {
		shape = "gun", -- pre-import fallback; the WeaponPack's BasaltScattergun_* is preferred
		model = "WeaponPack",
		variant = "BasaltScattergun",
		length = 2.6,
		grip = 0.7,
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
	icon = "rbxassetid://77070996422566", -- assets/icons/vulkan_repeater.png
	damage = { 24, 32 }, -- per round; ~200 dps sustained, and the burn on top
	cooldown = 0.11,
	reach = 0,
	knockback = 2,
	model = {
		shape = "gun", -- pre-import fallback; the WeaponPack's VulkanRepeater_* is preferred
		model = "WeaponPack",
		variant = "VulkanRepeater",
		length = 3.6,
		grip = 1.05,
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

-- ============================================================ Frostmaw Reach

-- Melee U: fast one-hander, the ice-fisher's sidearm. ~140 dps + frenzy ramp.
Weapons.items.icepick_hatchet = {
	id = "icepick_hatchet",
	name = "Icepick Hatchet",
	description = "Half tool, half temper. Light enough to swing all day, and it likes a rhythm.",
	rarity = "Uncommon",
	icon = "rbxassetid://82082988781512", -- assets/icons/icepick_hatchet.png
	damage = { 26, 36 },
	cooldown = 0.22,
	reach = 14,
	knockback = 12,
	swing = "ice_hew",
	model = {
		shape = "blade",
		model = "WeaponPack",
		variant = "IcepickHatchet",
		length = 2.6,
		grip = 0.5,
		color = Color3.fromRGB(120, 134, 150),
		accent = Color3.fromRGB(210, 228, 240),
		wrap = Color3.fromRGB(90, 104, 120),
	},
	recipe = {
		requiresLevel = 15,
		coins = 550,
		materials = { glacier_shard = 8, rime_pelt = 6, driftwood = 8 },
	},
	perk = {
		id = "cold_rhythm",
		name = "Cold Rhythm",
		description = "It likes a beat - consecutive landed hits ramp the damage higher and higher.",
		frenzy = true,
	},
}

-- Ranged R: the scoped precision piece that introduces the tier. One round,
-- a long bolt-throw between shots, and an execute that deletes the wounded.
Weapons.items.frostbore_long_rifle = {
	id = "frostbore_long_rifle",
	name = "Frostbore Long Rifle",
	description = "A whaler's long gun rebored for the reach. One round, one breath, one kill - if you've softened them first.",
	rarity = "Rare",
	icon = "rbxassetid://133494637931786", -- assets/icons/frostbore_long_rifle.png
	damage = { 160, 210 },
	cooldown = 2.6,
	reach = 14,
	knockback = 4,
	model = {
		shape = "gun",
		model = "WeaponPack",
		variant = "FrostboreRifle",
		length = 3.9,
		grip = 1.05,
		color = Color3.fromRGB(104, 96, 84),
		accent = Color3.fromRGB(170, 186, 202),
		wrap = Color3.fromRGB(70, 64, 56),
	},
	ranged = {
		projectileSpeed = 400,
		range = 220,
		fireMode = "scoped",
		magazine = 1,
		reloadTime = 1.2,
		zoomFov = 30,
	},
	recipe = {
		requiresLevel = 16,
		coins = 1100,
		materials = { glacier_shard = 10, everice = 4, bog_iron = 6 },
	},
	perk = {
		id = "one_breath",
		name = "One Breath",
		description = "A wounded target caught in the glass doesn't get to be wounded for long - heavy bonus damage low.",
		execute = true,
	},
}

-- Melee R: the two-handed slab. Slow, enormous, and it launches the pinned.
Weapons.items.glacier_maul = {
	id = "glacier_maul",
	name = "Glacier Maul",
	description = "A blue-hearted slab of everice on a whalebone haft. What it hits leaves the ground, whether it meant to or not.",
	rarity = "Rare",
	icon = "rbxassetid://118116501932214", -- assets/icons/glacier_maul.png
	damage = { 100, 138 },
	cooldown = 0.7,
	reach = 15,
	knockback = 30,
	swing = "maul_crash",
	model = {
		shape = "club",
		model = "WeaponPack",
		variant = "GlacierMaul",
		length = 4.2,
		grip = 0.8,
		color = Color3.fromRGB(150, 140, 124),
		accent = Color3.fromRGB(150, 196, 224),
		wrap = Color3.fromRGB(104, 96, 84),
		glow = Color3.fromRGB(120, 200, 255),
		neon = { "Weapon_Glow" },
	},
	recipe = {
		requiresLevel = 18,
		coins = 1700,
		materials = { everice = 8, glacier_shard = 12, rime_pelt = 8 },
	},
	perk = {
		id = "break_the_shelf",
		name = "Break the Shelf",
		description = "Hits launch even the things that cling to the ground - nothing stays planted in front of it.",
		uproot = true,
	},
}

-- Ranged E: six chambers of frostbite. Fast cylinder, brutal poison rounds.
Weapons.items.frostbite_revolver = {
	id = "frostbite_revolver",
	name = "Frostbite Revolver",
	description = "Six chambers packed with rime. What it doesn't kill outright, the cold finishes.",
	rarity = "Epic",
	icon = "rbxassetid://133617397525500", -- assets/icons/frostbite_revolver.png
	damage = { 38, 52 },
	cooldown = 0.45,
	reach = 14,
	knockback = 2,
	model = {
		shape = "gun",
		model = "WeaponPack",
		variant = "FrostbiteRevolver",
		length = 1.8,
		grip = 0.34,
		color = Color3.fromRGB(90, 100, 116),
		accent = Color3.fromRGB(200, 224, 240),
		wrap = Color3.fromRGB(60, 68, 82),
		glow = Color3.fromRGB(120, 200, 255),
		neon = { "Weapon_Glow" },
	},
	ranged = {
		projectileSpeed = 320,
		range = 110,
		fireMode = "single",
		magazine = 6,
		reloadTime = 1.8,
	},
	recipe = {
		requiresLevel = 19,
		coins = 2600,
		materials = { everice = 8, aurora_essence = 4, glacier_shard = 10 },
	},
	perk = {
		id = "deep_frost",
		name = "Deep Frost",
		description = "Every round leaves the cold in the wound, biting on for seconds after the hit.",
		poison = { damage = 30, duration = 4 },
	},
}

-- Melee L: the boss piece. ~204 dps, long reach, and an execute worthy of
-- the serpent whose fang it is.
Weapons.items.rimefang_lance = {
	id = "rimefang_lance",
	name = "Rimefang Lance",
	description = "The serpent's own fang, socketed on a spar of frozen keel. It ends fights the way winter ends things - all at once.",
	rarity = "Legendary",
	icon = "rbxassetid://97149237744973", -- assets/icons/rimefang_lance.png
	damage = { 75, 96 },
	cooldown = 0.42,
	reach = 16,
	knockback = 18,
	swing = "rime_lance",
	model = {
		shape = "blade",
		model = "WeaponPack",
		variant = "RimefangLance",
		length = 4.6,
		grip = 0.9,
		color = Color3.fromRGB(140, 180, 210),
		accent = Color3.fromRGB(236, 246, 252),
		wrap = Color3.fromRGB(80, 100, 126),
		glow = Color3.fromRGB(80, 220, 255),
		neon = { "Weapon_Glow" },
	},
	recipe = {
		requiresLevel = 21,
		coins = 3000,
		materials = { everice = 10, aurora_essence = 6, rime_pelt = 12 },
		requiresHearts = { "rimefang" },
	},
	perk = {
		id = "winters_end",
		name = "Winter's End",
		description = "The fang remembers how the serpent fed - heavy bonus damage to anything already wounded.",
		execute = true,
	},
}

-- ============================================================ Gloomtrench

-- Melee U: a pressure-forged pick of trench chitin. Plain, fast, dependable.
Weapons.items.trenchspike = {
	id = "trenchspike",
	name = "Trenchspike",
	description = "Chitin from the crush of the deep, ground to a point. It has no tricks. It doesn't need one.",
	rarity = "Uncommon",
	icon = "rbxassetid://120538462302608", -- assets/icons/trenchspike.png
	damage = { 62, 82 },
	cooldown = 0.42,
	reach = 14,
	knockback = 14,
	swing = "trench_stab",
	model = {
		shape = "blade",
		model = "WeaponPack",
		variant = "Trenchspike",
		length = 3.0,
		grip = 0.6,
		color = Color3.fromRGB(70, 78, 92),
		accent = Color3.fromRGB(130, 124, 142),
		wrap = Color3.fromRGB(48, 54, 66),
	},
	recipe = {
		requiresLevel = 29,
		coins = 3600,
		materials = { trench_chitin = 10, gloom_scale = 8, driftwood = 10 },
	},
}

-- Ranged R: a whaling gun for the dark. One heavy iron, punched deep.
Weapons.items.abyssal_harpooner = {
	id = "abyssal_harpooner",
	name = "Abyssal Harpooner",
	description = "A whaling gun re-rigged for things whales are scared of. One iron, thrown hard enough to matter.",
	rarity = "Rare",
	icon = "rbxassetid://123205462120006", -- assets/icons/abyssal_harpooner.png
	damage = { 140, 190 },
	cooldown = 1.2,
	reach = 14,
	knockback = 4,
	model = {
		shape = "gun",
		model = "WeaponPack",
		variant = "AbyssalHarpooner",
		length = 3.2,
		grip = 0.85,
		color = Color3.fromRGB(60, 66, 84),
		accent = Color3.fromRGB(140, 150, 170),
		wrap = Color3.fromRGB(44, 48, 62),
	},
	ranged = {
		projectile = true, -- a real arrow/bolt/iron flies, not a tracer
		projectileSpeed = 260,
		range = 140,
		fireMode = "single",
		magazine = 1,
		reloadTime = 1.0,
		arc = true,
	},
	recipe = {
		requiresLevel = 30,
		coins = 4800,
		materials = { trench_chitin = 12, gloom_scale = 10, bog_iron = 8 },
	},
}

-- Ranged R: the trench's chattergun. Full-auto, mag 30, ~160 sustained.
Weapons.items.riptide_smg = {
	id = "riptide_smg",
	name = "Riptide SMG",
	description = "Salvaged off a wreck that had no business carrying it. It talks fast and the dark talks back.",
	rarity = "Rare",
	icon = "rbxassetid://137795916963491", -- assets/icons/riptide_smg.png
	damage = { 17, 23 },
	cooldown = 0.125,
	reach = 14,
	knockback = 1,
	model = {
		shape = "gun",
		model = "WeaponPack",
		variant = "RiptideSmg",
		length = 1.9,
		grip = 0.62,
		color = Color3.fromRGB(76, 84, 100),
		accent = Color3.fromRGB(140, 220, 255),
		wrap = Color3.fromRGB(52, 58, 72),
	},
	ranged = {
		projectileSpeed = 300,
		range = 100,
		fireMode = "auto",
		magazine = 30,
		reloadTime = 1.9,
	},
	recipe = {
		requiresLevel = 32,
		coins = 6500,
		materials = { trench_chitin = 12, lantern_gland = 5, bog_iron = 10 },
	},
}

-- Melee E: a saber of polished voidglass that drinks what it cuts.
Weapons.items.voidglass_saber = {
	id = "voidglass_saber",
	name = "Voidglass Saber",
	description = "Glass from the trench floor, black past black, edged. What it takes from them it hands to you.",
	rarity = "Epic",
	icon = "rbxassetid://77334220892016", -- assets/icons/voidglass_saber.png
	damage = { 88, 118 },
	cooldown = 0.45,
	reach = 15,
	knockback = 14,
	swing = "void_cut",
	model = {
		shape = "blade",
		model = "WeaponPack",
		variant = "VoidglassSaber",
		length = 3.8,
		grip = 0.7,
		color = Color3.fromRGB(40, 36, 56),
		accent = Color3.fromRGB(66, 58, 90),
		wrap = Color3.fromRGB(30, 26, 42),
		glow = Color3.fromRGB(170, 120, 255),
		neon = { "Weapon_Glow" },
	},
	recipe = {
		requiresLevel = 33,
		coins = 8500,
		materials = { abyss_ichor = 4, trench_chitin = 12, gloom_scale = 12 },
	},
	perk = {
		id = "drink_the_dark",
		name = "Drink the Dark",
		description = "Every cut feeds you a share of what it took.",
		lifesteal = true,
	},
}

-- Ranged L: the boss piece. Scoped battle rifle; "Lights Out" execute.
Weapons.items.gloomcaller_dmr = {
	id = "gloomcaller_dmr",
	name = "Gloomcaller DMR",
	description = "Built around a lens of Noctyss's own lure-glass. It finds the wounded in the dark, and then there is no more dark to hide in.",
	rarity = "Legendary",
	icon = "rbxassetid://121204958591537", -- assets/icons/gloomcaller_dmr.png
	damage = { 180, 240 },
	cooldown = 0.8,
	reach = 14,
	knockback = 3,
	model = {
		shape = "gun",
		model = "WeaponPack",
		variant = "GloomcallerDmr",
		length = 3.8,
		grip = 1.3,
		color = Color3.fromRGB(56, 50, 72),
		accent = Color3.fromRGB(255, 226, 130),
		wrap = Color3.fromRGB(40, 36, 54),
		glow = Color3.fromRGB(255, 226, 130),
		neon = { "Weapon_Glow" },
	},
	ranged = {
		projectileSpeed = 420,
		range = 200,
		fireMode = "scoped",
		magazine = 8,
		reloadTime = 2.0,
		zoomFov = 34,
	},
	recipe = {
		requiresLevel = 35,
		coins = 12000,
		materials = { abyss_ichor = 6, lantern_gland = 8, trench_chitin = 14 },
		requiresHearts = { "noctyss" },
	},
	perk = {
		id = "lights_out",
		name = "Lights Out",
		description = "The lure-glass marks the faltering - heavy bonus damage to anything already wounded.",
		execute = true,
	},
}

-- ============================================================ Wreckwater

-- Melee U: the boarder's opener. Wide, mean, hits everything in reach.
Weapons.items.boarding_axe = {
	id = "boarding_axe",
	name = "Boarding Axe",
	description = "The fleet's own pattern, barnacled but keen. Made for clearing a deck, not duelling on one.",
	rarity = "Uncommon",
	icon = "rbxassetid://133938122170233", -- assets/icons/boarding_axe.png
	damage = { 90, 120 },
	cooldown = 0.5,
	reach = 15,
	knockback = 18,
	swing = "deck_hook",
	model = {
		shape = "club",
		model = "WeaponPack",
		variant = "BoardingAxe",
		length = 3.4,
		grip = 0.7,
		color = Color3.fromRGB(110, 96, 76),
		accent = Color3.fromRGB(160, 168, 176),
		wrap = Color3.fromRGB(76, 66, 54),
	},
	recipe = {
		requiresLevel = 36,
		coins = 7000,
		materials = { ghost_plank = 12, tarnished_doubloon = 8, bog_iron = 10 },
	},
	perk = {
		id = "clear_the_deck",
		name = "Clear the Deck",
		description = "A full swing catches everything in reach, not just the one in front.",
		cleave = true,
	},
}

-- Ranged R: eight pellets of grave-iron. Ruinous up close, mist at range.
Weapons.items.grave_blunderbuss = {
	id = "grave_blunderbuss",
	name = "Grave Blunderbuss",
	description = "Loaded with grave-iron scrap and worse opinions. Step in close and it settles arguments whole.",
	rarity = "Rare",
	icon = "rbxassetid://111322291667964", -- assets/icons/grave_blunderbuss.png
	damage = { 16, 24 },
	cooldown = 0.7,
	reach = 14,
	knockback = 3,
	model = {
		shape = "gun",
		model = "WeaponPack",
		variant = "GraveBlunderbuss",
		length = 2.85,
		grip = 0.8,
		color = Color3.fromRGB(104, 88, 66),
		accent = Color3.fromRGB(150, 156, 164),
		wrap = Color3.fromRGB(70, 60, 48),
	},
	ranged = {
		projectileSpeed = 240,
		range = 55,
		fireMode = "single",
		magazine = 2,
		reloadTime = 2.2,
		pellets = 8,
		spread = 0.08, -- radians per pellet - a touch wider than the Scattergun's cone
	},
	recipe = {
		requiresLevel = 37,
		coins = 9000,
		materials = { ghost_plank = 10, tarnished_doubloon = 10, bog_iron = 12 },
	},
}

-- Ranged R: the ghost-fleet's full-auto. Mag 32, ~240 sustained.
Weapons.items.phantom_repeater = {
	id = "phantom_repeater",
	name = "Phantom Repeater",
	description = "It was never made; it is remembered, by enough dead gunners to keep it firing.",
	rarity = "Rare",
	icon = "rbxassetid://79882944489764", -- assets/icons/phantom_repeater.png
	damage = { 25, 35 },
	cooldown = 0.125,
	reach = 14,
	knockback = 1,
	model = {
		shape = "gun",
		model = "WeaponPack",
		variant = "PhantomRepeater",
		length = 3.45,
		grip = 1.1,
		color = Color3.fromRGB(96, 116, 108),
		accent = Color3.fromRGB(160, 255, 210),
		wrap = Color3.fromRGB(64, 78, 72),
		glow = Color3.fromRGB(160, 255, 210),
		neon = { "Weapon_Glow" },
	},
	ranged = {
		projectileSpeed = 320,
		range = 120,
		fireMode = "auto",
		magazine = 32,
		reloadTime = 2.0,
	},
	recipe = {
		requiresLevel = 39,
		coins = 12000,
		materials = { spectral_sailcloth = 6, tarnished_doubloon = 12, ghost_plank = 10 },
	},
}

-- Melee E: the duellist's answer. Fast, hungry, ramps with the rhythm.
Weapons.items.cutlass_of_the_fleet = {
	id = "cutlass_of_the_fleet",
	name = "Cutlass of the Fleet",
	description = "Every officer of the fleet carried one; this is all of them at once. It fights faster the longer you let it.",
	rarity = "Epic",
	icon = "rbxassetid://114844417657503", -- assets/icons/cutlass_of_the_fleet.png
	damage = { 105, 140 },
	cooldown = 0.42,
	reach = 15,
	knockback = 14,
	swing = "fleet_flourish",
	model = {
		shape = "blade",
		model = "WeaponPack",
		variant = "CutlassOfTheFleet",
		length = 3.6,
		grip = 0.65,
		color = Color3.fromRGB(120, 134, 124),
		accent = Color3.fromRGB(200, 214, 206),
		wrap = Color3.fromRGB(84, 94, 88),
		glow = Color3.fromRGB(160, 255, 210),
		neon = { "Weapon_Glow" },
	},
	recipe = {
		requiresLevel = 40,
		coins = 16000,
		materials = { spectral_sailcloth = 8, wraith_essence = 3, tarnished_doubloon = 12 },
	},
	perk = {
		id = "fleet_tempo",
		name = "Fleet Tempo",
		description = "A drowned crew keeps the beat - consecutive landed hits ramp the damage.",
		frenzy = true,
	},
}

-- Melee L: the boss piece. ~360 dps and "Strike the Colors".
Weapons.items.admirals_saber = {
	id = "admirals_saber",
	name = "Admiral's Saber",
	description = "Wrack's own blade, surrendered only with his heart. When it lands on the faltering, the battle is simply over.",
	rarity = "Legendary",
	icon = "rbxassetid://120351080286742", -- assets/icons/admirals_saber.png
	damage = { 130, 172 },
	cooldown = 0.42,
	reach = 16,
	knockback = 16,
	swing = "admiral_cut",
	model = {
		shape = "blade",
		model = "WeaponPack",
		variant = "AdmiralsSaber",
		length = 4.0,
		grip = 0.7,
		color = Color3.fromRGB(96, 116, 108),
		accent = Color3.fromRGB(230, 190, 100),
		wrap = Color3.fromRGB(66, 80, 76),
		glow = Color3.fromRGB(160, 255, 210),
		neon = { "Weapon_Glow" },
	},
	recipe = {
		requiresLevel = 42,
		coins = 20000,
		materials = { wraith_essence = 6, spectral_sailcloth = 10, ghost_plank = 14 },
		requiresHearts = { "admiral_wrack" },
	},
	perk = {
		id = "strike_the_colors",
		name = "Strike the Colors",
		description = "The wounded see the blade and know the engagement is decided - heavy bonus damage low.",
		execute = true,
	},
}

-- ============================================================ Weapons

Weapons.items.galecleaver = {
	id = "galecleaver",
	name = "Galecleaver",
	description = "A broad blade that swings with the wind behind it, whichever way you face.",
	rarity = "Uncommon",
	icon = "rbxassetid://98979286259635", -- assets/icons/galecleaver.png
	damage = { 118, 158 },
	cooldown = 0.45,
	reach = 15,
	knockback = 18,
	swing = "gale_cleave",
	model = {
		shape = "club",
		model = "WeaponPack",
		variant = "Galecleaver",
		length = 3.8,
		grip = 0.7,
		color = Color3.fromRGB(110, 124, 140),
		accent = Color3.fromRGB(200, 214, 228),
		wrap = Color3.fromRGB(76, 86, 100),
	},
	recipe = {
		requiresLevel = 43,
		coins = 13000,
		materials = { storm_glass = 12, riptide_scale = 10, bog_iron = 12 },
	},
}

Weapons.items.cyclone_assault_rifle = {
	id = "cyclone_assault_rifle",
	name = "Cyclone Assault Rifle",
	description = "The storm taught someone automatic fire, and this is what they built. It does not stop to think.",
	rarity = "Rare",
	icon = "rbxassetid://72946834606393", -- assets/icons/cyclone_assault_rifle.png
	damage = { 34, 46 },
	cooldown = 0.125,
	reach = 14,
	knockback = 1,
	model = {
		shape = "gun",
		model = "WeaponPack",
		variant = "CycloneRifle",
		length = 3.45,
		grip = 1.25,
		color = Color3.fromRGB(76, 86, 104),
		accent = Color3.fromRGB(140, 200, 255),
		wrap = Color3.fromRGB(54, 62, 78),
	},
	ranged = {
		projectileSpeed = 340,
		range = 130,
		fireMode = "auto",
		magazine = 30,
		reloadTime = 2.0,
	},
	recipe = {
		requiresLevel = 44,
		coins = 17000,
		materials = { storm_glass = 12, riptide_scale = 12, bog_iron = 14 },
	},
}

Weapons.items.thunderhead_hand_cannon = {
	id = "thunderhead_hand_cannon",
	name = "Thunderhead Hand Cannon",
	description = "Five chambers, each loaded with a small argument about thunder. It wins all five.",
	rarity = "Rare",
	icon = "rbxassetid://96347745149327", -- assets/icons/thunderhead_hand_cannon.png
	damage = { 210, 280 },
	cooldown = 0.75,
	reach = 14,
	knockback = 4,
	model = {
		shape = "gun",
		model = "WeaponPack",
		variant = "ThunderheadCannon",
		length = 2.2,
		grip = 0.5,
		color = Color3.fromRGB(70, 80, 100),
		accent = Color3.fromRGB(220, 230, 255),
		wrap = Color3.fromRGB(50, 58, 74),
		glow = Color3.fromRGB(220, 230, 255),
		neon = { "Weapon_Glow" },
	},
	ranged = {
		projectileSpeed = 360,
		range = 120,
		fireMode = "single",
		magazine = 5,
		reloadTime = 2.4,
	},
	recipe = {
		requiresLevel = 46,
		coins = 24000,
		materials = { thunder_pearl = 6, storm_glass = 14, bog_iron = 12 },
	},
}

Weapons.items.stormlance = {
	id = "stormlance",
	name = "Stormlance",
	description = "A lance with a live current down the haft. What it wounds keeps burning with the charge.",
	rarity = "Epic",
	icon = "rbxassetid://104958053973602", -- assets/icons/stormlance.png
	damage = { 165, 220 },
	cooldown = 0.45,
	reach = 16,
	knockback = 16,
	swing = "storm_lance",
	model = {
		shape = "blade",
		model = "WeaponPack",
		variant = "Stormlance",
		length = 4.6,
		grip = 0.9,
		color = Color3.fromRGB(90, 110, 150),
		accent = Color3.fromRGB(220, 230, 255),
		wrap = Color3.fromRGB(62, 76, 104),
		glow = Color3.fromRGB(140, 200, 255),
		neon = { "Weapon_Glow" },
	},
	recipe = {
		requiresLevel = 47,
		coins = 32000,
		materials = { maelstrom_core = 5, thunder_pearl = 8, riptide_scale = 12 },
	},
	perk = {
		id = "static_charge",
		name = "Static Charge",
		description = "The current stays in the wound, burning on for seconds after every hit.",
		poison = { damage = 60, duration = 4 },
	},
}

Weapons.items.krakenfang = {
	id = "krakenfang",
	name = "Krakenfang",
	description = "A fang of the Maw itself, still hungry. Every cut feeds you what it takes - it is the last blade the sea will ever owe you.",
	rarity = "Legendary",
	icon = "rbxassetid://124847433165199", -- assets/icons/krakenfang.png
	damage = { 195, 262 },
	cooldown = 0.42,
	reach = 16,
	knockback = 18,
	swing = "kraken_rip",
	model = {
		shape = "blade",
		model = "WeaponPack",
		variant = "Krakenfang",
		length = 4.4,
		grip = 0.75,
		color = Color3.fromRGB(60, 44, 84),
		accent = Color3.fromRGB(220, 210, 240),
		wrap = Color3.fromRGB(44, 34, 60),
		glow = Color3.fromRGB(150, 120, 255),
		neon = { "Weapon_Glow" },
	},
	recipe = {
		requiresLevel = 50,
		coins = 55000,
		materials = { maelstrom_core = 8, thunder_pearl = 10, riptide_scale = 14 },
		requiresHearts = { "kraken" },
	},
	perk = {
		id = "devour_the_storm",
		name = "Devour the Storm",
		description = "The fang still feeds - every cut heals you a share of what it takes.",
		lifesteal = true,
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
	"icepick_hatchet",
	"frostbore_long_rifle",
	"glacier_maul",
	"frostbite_revolver",
	"rimefang_lance",
	"cinderlock_carbine",
	"obsidian_piercer",
	"basalt_scattergun",
	"magma_gauntlets",
	"vulkan_repeater",
	"trenchspike",
	"abyssal_harpooner",
	"riptide_smg",
	"voidglass_saber",
	"gloomcaller_dmr",
	"boarding_axe",
	"grave_blunderbuss",
	"phantom_repeater",
	"cutlass_of_the_fleet",
	"admirals_saber",
	"galecleaver",
	"cyclone_assault_rifle",
	"thunderhead_hand_cannon",
	"stormlance",
	"krakenfang",
}

-- Every player starts with (and can't lose) this one.
Weapons.STARTER_WEAPON_ID = "fists"

return Weapons
