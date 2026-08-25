--!nonstrict
-- Weapons.luau
-- Weapons, as rows - the same id-keyed shape as Rods / Creatures / Materials.
-- All rows are melee TODAY, but the old "never a ranged row here" rule was
-- overturned by the user on 2026-08-24 (docs/revamp-plan.md): ranged weapons
-- (bows -> flintlocks -> firearms) arrive with the ranged engine in Session 2,
-- as an optional `ranged` block on this same row shape.
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

export type Weapon = {
	id: string,
	name: string,
	description: string,
	rarity: string, -- Common | Uncommon | Rare | Epic | Legendary
	icon: string, -- inventory image asset id ("rbxassetid://..."); "" shows the blank placeholder
	damage: { number }, -- { min, max } per hit
	cooldown: number, -- seconds between swings (server-enforced)
	reach: number, -- studs from the player a creature can be hit
	knockback: number, -- shove speed on a non-killing hit, studs/sec (see Tuning.Combat.KNOCKBACK_SPEED)
	swing: string?, -- WeaponSwingAnim clip name; nil = the fist punch clips
	model: WeaponModel?, -- nil = bare hands
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

-- ============================================================ Ashfall Caldera (interim L8-14)
-- The volcano's two kept melee weapons, buffed for their slot; its three guns
-- (Cinderlock Carbine, Basalt Scattergun, Vulkan Repeater) arrive with the
-- ranged engine (Session 2, docs/revamp-plan.md). INTERIM GATES: L8-14 with
-- island-2-scale costs while the volcano is still island 2; they re-gate to
-- L22-28 when it slides to slot 4 in Session 4.

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

-- Stable display order for the inventory / crafting menus (table iteration
-- order isn't guaranteed). Starter first, then by island and level gate.
Weapons.order = {
	"fists",
	"driftwood_club",
	"scale_blade",
	"shellcrusher",
	"drowncleaver",
	"heartrender",
	"obsidian_piercer",
	"magma_gauntlets",
}

-- Every player starts with (and can't lose) this one.
Weapons.STARTER_WEAPON_ID = "fists"

return Weapons
