--!nonstrict
-- Creatures.luau
-- Everything that can come out of the water, as rows. Adding a creature is
-- adding an entry here (and, if it needs a new shape, a species dict in
-- assets/fish_gen.py): its look is one species' meshes picked out of the
-- shared FishPack, recoloured and rescaled by its `body` block, and its
-- behaviour (once behaviour exists) comes from the small archetype set its
-- `archetype` names.
--
-- Every row is a real fish (user direction, 2026-08-22): the species shapes
-- are built to read as the actual animal - a bass is deep with a spiny
-- dorsal and a dark stripe, a tuna is a torpedo with a crescent tail - and
-- the colours here are the real fish's, roughly.
--
-- `archetype` picks the behaviour CreatureService runs (one state machine
-- each, knobs in Tuning.Creature):
--   flopper  - the passive catch: lands, flops, waits to be punched (every
--              real fish - user decision 2026-08-22, they stay passive)
--   rusher   - flops, winds up, lunges (pufferfish, snapjaw crab)
--   shambler - upright, trudges at you (the drowned)
--   charger  - dashes past you, exposed while turning (Tideline Skipper)
--   spitter  - keeps its distance, spits a glob (Gullet Cod)
--   bloater  - swells when hit, explodes (Tidebomb Urchin)
--   drifter  - hovers at you, floats up when hit (Moonbell Jelly)
--   burrower - digs in, tunnels, bursts up under you (Sand Lurker)
--   mimic    - shut and untargetable until you're close (Pearl Mimic)
--   thief    - steals coins on contact and flees (Pickpocket Hermit)
--   pulser   - charges up, shockwave (Voltray)
--   crust    - armoured until cracked, then a vulnerable window (Slagheart Golem)
--   splitter - divides into two smaller copies on death (Magma Ooze)
--   reborn   - dies once, rises at part health, must be killed again (Ashfeather Phoenix)
--   thornback- armoured at the front, reflects; soft behind (Obsidian Shardback)
--   gascloud - trails burning smoke that keeps damaging (Cinder Djinn)
--   magnetize- periodically drags the player toward it (Lodestone Eel)
--   companion- NOT an enemy: fights hostiles for its owner (Roe Hatchling)
--
-- Rarity drives how often a row is rolled (Tuning.Rarity.WEIGHTS - a tier
-- with rows but no weight never rolls) and scales the fight and payout.
-- Every catch is fought; there is no auto-collect tier.

local Creatures = {}

export type Body = {
	model: string, -- template under ReplicatedStorage/Assets (see assets/README.md)
	species: string?, -- which species' parts to pick out of it: <species>_Body etc.
	shape: string?, -- procedural fallback built in CreatureModel when the pack lacks the species: "puffer" | "crab" | "zombie" | "skipper" | "gulletcod" | "urchin" | "jelly" | "lurker" | "mimic" | "hermit" | "ray"
	stance: string?, -- "flat" (default; laid on its side like a fish) | "upright" (stands; for bipeds)
	scale: number, -- uniform multiplier on the species' 2-stud body
	color: Color3,
	finColor: Color3,
	markColor: Color3?, -- stripes / bars / finlets, if the species has them
}

export type Rewards = {
	coins: { number }, -- { min, max }, rolled uniformly
	xp: number,
}

-- What killing it drops, beyond coins/XP. Optional and per-row: a row with
-- `drops.materials` overrides the rarity default in MaterialService; `items`
-- are rare direct drops (an existing Rods/Weapons id, granted at `chance`).
export type Drops = {
	materials: { [string]: { number } }?, -- matId -> { min, max }
	items: { { id: string, chance: number } }?, -- 0..1 chance each
}

export type Creature = {
	id: string,
	name: string,
	rarity: string,
	archetype: string,
	health: number, -- hit points at a Neutral grade; Tuning.Grade scales it
	-- What killing it pays, before the reel grade's rewardMult. Optional:
	-- rows without it use Tuning.Rewards.BY_RARITY for their rarity, which
	-- is every row today.
	rewards: Rewards?,
	drops: Drops?,
	-- Which water this row is caught in. Missing = the ocean (every existing
	-- row). "volcano" rows roll only when the cast lands in the lava, and ocean
	-- rows never roll there - FishingService.rollCreature filters the pool by
	-- the cast's surface (Ocean vs Volcano_Lava). See docs/volcano-content-spec.md.
	waters: string?,
	body: Body,
	-- An island boss: the Bosses.luau entry with its attack book. Such a
	-- row uses archetype "boss" and rarity "Boss" (never rolled from a cast;
	-- BossService spawns it), and must carry its own `rewards` + `drops`.
	boss: string?,
}

Creatures.items = {} :: { [string]: Creature }

-- ============================================================ Common

Creatures.items.perch = {
	id = "perch",
	name = "Yellow Perch",
	rarity = "Common",
	archetype = "flopper",
	health = 60,
	body = {
		model = "FishPack",
		species = "Perch",
		scale = 0.7,
		color = Color3.fromRGB(170, 172, 78),
		finColor = Color3.fromRGB(236, 122, 36),
		markColor = Color3.fromRGB(62, 70, 34),
	},
}

Creatures.items.mackerel = {
	id = "mackerel",
	name = "Atlantic Mackerel",
	rarity = "Common",
	archetype = "flopper",
	health = 70,
	body = {
		model = "FishPack",
		species = "Mackerel",
		scale = 0.8,
		color = Color3.fromRGB(96, 150, 172),
		finColor = Color3.fromRGB(80, 110, 128),
		markColor = Color3.fromRGB(28, 46, 66),
	},
}

Creatures.items.trout = {
	id = "trout",
	name = "Rainbow Trout",
	rarity = "Common",
	archetype = "flopper",
	health = 90,
	body = {
		model = "FishPack",
		species = "Trout",
		scale = 0.9,
		color = Color3.fromRGB(126, 160, 112),
		finColor = Color3.fromRGB(104, 128, 98),
		markColor = Color3.fromRGB(226, 108, 132),
	},
}

-- ============================================================ Uncommon

Creatures.items.bass = {
	id = "bass",
	name = "Largemouth Bass",
	rarity = "Uncommon",
	archetype = "flopper",
	health = 180,
	body = {
		model = "FishPack",
		species = "Bass",
		scale = 1.1,
		color = Color3.fromRGB(108, 142, 72),
		finColor = Color3.fromRGB(86, 112, 62),
		markColor = Color3.fromRGB(32, 46, 26),
	},
}

Creatures.items.cod = {
	id = "cod",
	name = "Atlantic Cod",
	rarity = "Uncommon",
	archetype = "flopper",
	health = 220,
	body = {
		model = "FishPack",
		species = "Cod",
		scale = 1.6,
		color = Color3.fromRGB(150, 134, 92),
		finColor = Color3.fromRGB(118, 108, 78),
		markColor = Color3.fromRGB(210, 200, 170),
	},
}

Creatures.items.catfish = {
	id = "catfish",
	name = "Channel Catfish",
	rarity = "Uncommon",
	archetype = "flopper",
	health = 240,
	body = {
		model = "FishPack",
		species = "Catfish",
		scale = 1.4,
		color = Color3.fromRGB(102, 102, 88),
		finColor = Color3.fromRGB(76, 76, 66),
	},
}

-- The one hostile catch so far: it doesn't just flop, it rushes the player
-- and rams them for contact damage (archetype "rusher", handled in
-- CreatureService). It's a real low-poly species in the FishPack now (a
-- faceted spiky ball - see build_puffer in fish_gen.py); `shape = "puffer"`
-- is kept as the procedural fallback so it still shows before the pack is
-- (re)imported, and the example enemy is never invisible during testing.
Creatures.items.pufferfish = {
	id = "pufferfish",
	name = "Spineback Puffer",
	rarity = "Uncommon",
	archetype = "rusher",
	health = 150,
	body = {
		model = "FishPack",
		species = "Puffer",
		shape = "puffer", -- pre-import parts fallback; the pack's Puffer_* is preferred
		scale = 1.15,
		color = Color3.fromRGB(216, 196, 128),
		finColor = Color3.fromRGB(150, 120, 70),
	},
}

-- ============================================================ Rare

Creatures.items.salmon = {
	id = "salmon",
	name = "Sockeye Salmon",
	rarity = "Rare",
	archetype = "flopper",
	health = 320,
	body = {
		model = "FishPack",
		species = "Salmon",
		scale = 1.5,
		color = Color3.fromRGB(184, 188, 184),
		finColor = Color3.fromRGB(128, 128, 124),
		markColor = Color3.fromRGB(220, 96, 92),
	},
}

-- Not a fish: the first hostile things dragged up from the deep. They roll in
-- the same Rare/Epic pools as the fish and spawn through the same path. Their
-- look is the imported CreaturePack (assets/creatures_gen.py) picked by
-- `species`, with `shape` as a rough pre-import parts fallback; what's also
-- new is the `shambler` archetype, the upright `stance`, and per-creature
-- `drops`.

-- A wide armoured crab with an oversized "snapjaw" claw that scuttles up and
-- rams you claws-first. Reuses the rusher AI (like the puffer). Its front-back
-- (claws) is the longest axis so flatOrientation faces it head-on and lays it
-- flat.
Creatures.items.snapjaw_crab = {
	id = "snapjaw_crab",
	name = "Snapjaw Crab",
	rarity = "Rare",
	archetype = "rusher",
	health = 280,
	drops = {
		materials = { barnacle_chitin = { 1, 2 }, fish_scale = { 1, 2 } },
	},
	body = {
		model = "CreaturePack", -- imported mesh; `shape` below is the pre-import fallback
		species = "Crab",
		shape = "crab",
		scale = 1.0,
		color = Color3.fromRGB(196, 92, 72), -- shell
		finColor = Color3.fromRGB(150, 66, 52), -- claws + legs
		markColor = Color3.fromRGB(232, 216, 182), -- mouth plate
	},
}

-- A waterlogged undead sailor. Stands upright and shambles at you (the new
-- slow-melee `shambler` archetype), swinging on contact.
Creatures.items.drowned_deckhand = {
	id = "drowned_deckhand",
	name = "Drowned Deckhand",
	rarity = "Rare",
	archetype = "shambler",
	health = 300,
	drops = {
		materials = { cursed_bone = { 1, 2 }, pearl = { 1, 1 } },
	},
	body = {
		model = "CreaturePack",
		species = "Deckhand",
		shape = "zombie",
		stance = "upright",
		scale = 1.0,
		color = Color3.fromRGB(96, 126, 96), -- rotted skin
		finColor = Color3.fromRGB(70, 82, 96), -- waterlogged clothes
		markColor = Color3.fromRGB(60, 112, 78), -- seaweed / barnacles
	},
}

-- ============================================================ Epic

Creatures.items.tuna = {
	id = "tuna",
	name = "Bluefin Tuna",
	rarity = "Epic",
	archetype = "flopper",
	health = 600,
	body = {
		model = "FishPack",
		species = "Tuna",
		scale = 2.2,
		color = Color3.fromRGB(52, 72, 118),
		finColor = Color3.fromRGB(78, 88, 112),
		markColor = Color3.fromRGB(234, 198, 52),
	},
}

-- The zombie fisherman: bigger, tougher, in a rotted oilskin coat with a gaff.
-- Same upright shambler as the deckhand. On a kill it drops its mats and, rarely
-- (10%), a finished Scaleblade straight into your inventory (drops.items).
Creatures.items.drowned_angler = {
	id = "drowned_angler",
	name = "Drowned Angler",
	rarity = "Epic",
	archetype = "shambler",
	health = 500,
	drops = {
		materials = { cursed_bone = { 2, 3 }, barnacle_chitin = { 1, 2 } },
		items = { { id = "scale_blade", chance = 0.1 } },
	},
	body = {
		model = "CreaturePack",
		species = "Angler",
		shape = "zombie",
		stance = "upright",
		scale = 1.1,
		color = Color3.fromRGB(88, 116, 104), -- drowned skin
		finColor = Color3.fromRGB(120, 92, 52), -- oilskin coat
		markColor = Color3.fromRGB(96, 236, 214), -- the bioluminescent lure
	},
}

-- ============================================================ Enemies (2026-08-22)
-- Eight hostiles built around mechanics the fish don't have. Each names a
-- CreaturePack species for the art slice (not authored yet) and a procedural
-- `shape` stand-in, so every one is testable now from the admin spawn menu.

-- A mudskipper on stilt legs. Winds up, then sprints in a straight line
-- straight past you and skids around to come back - hit it while it's
-- turning and the blow lands double (CHARGE_EXPOSED_DAMAGE_MULT).
Creatures.items.tideline_skipper = {
	id = "tideline_skipper",
	name = "Tideline Skipper",
	rarity = "Uncommon",
	archetype = "charger",
	health = 170,
	drops = {
		materials = { fish_scale = { 1, 2 } },
	},
	body = {
		model = "CreaturePack",
		species = "Skipper",
		shape = "skipper",
		scale = 1.0,
		color = Color3.fromRGB(128, 140, 92), -- mud-olive
		finColor = Color3.fromRGB(92, 96, 70), -- stilt legs + fins
		markColor = Color3.fromRGB(214, 206, 150), -- pale belly stripe
	},
}

-- A bloated cod that keeps its distance and hacks up globs of brine at you.
-- The glob lands where you were standing when it fired - keep moving.
Creatures.items.gullet_cod = {
	id = "gullet_cod",
	name = "Gullet Cod",
	rarity = "Uncommon",
	archetype = "spitter",
	health = 200,
	drops = {
		materials = { fish_scale = { 1, 2 } },
	},
	body = {
		model = "CreaturePack",
		species = "GulletCod",
		shape = "gulletcod",
		scale = 1.2,
		color = Color3.fromRGB(150, 134, 92),
		finColor = Color3.fromRGB(118, 108, 78),
		markColor = Color3.fromRGB(70, 40, 44), -- the gaping gullet
	},
}

-- A spiny ball that swells with every hit and bursts, hurting everything
-- around it. Knock it away before it pops - or into something else.
Creatures.items.tidebomb_urchin = {
	id = "tidebomb_urchin",
	name = "Tidebomb Urchin",
	rarity = "Rare",
	archetype = "bloater",
	health = 160,
	drops = {
		materials = { barnacle_chitin = { 1, 2 }, fish_scale = { 2, 3 } },
	},
	body = {
		model = "CreaturePack",
		species = "Urchin",
		shape = "urchin",
		scale = 1.0,
		color = Color3.fromRGB(72, 40, 70), -- dark violet ball
		finColor = Color3.fromRGB(120, 72, 118), -- spines
	},
}

-- A translucent jelly that drifts at you and stings. Nearly weightless: a
-- hit sends it floating high and it sinks back slowly - juggle bait.
Creatures.items.moonbell_jelly = {
	id = "moonbell_jelly",
	name = "Moonbell Jelly",
	rarity = "Uncommon",
	archetype = "drifter",
	health = 140,
	drops = {
		materials = { kelp_fiber = { 1, 2 }, pearl = { 1, 1 } },
	},
	body = {
		model = "CreaturePack",
		species = "Jelly",
		shape = "jelly",
		stance = "upright", -- bell up; never laid on its side
		scale = 1.0,
		color = Color3.fromRGB(200, 214, 236), -- the bell
		finColor = Color3.fromRGB(160, 178, 220), -- tendrils
		markColor = Color3.fromRGB(236, 200, 232), -- inner glow spots
	},
}

-- A flounder that digs into the sand. Only a moving puff of sand gives it
-- away - then it bursts up under you. Hittable only while surfaced.
Creatures.items.sand_lurker = {
	id = "sand_lurker",
	name = "Sand Lurker",
	rarity = "Rare",
	archetype = "burrower",
	health = 260,
	drops = {
		materials = { barnacle_chitin = { 1, 2 }, fish_scale = { 1, 2 } },
	},
	body = {
		model = "CreaturePack",
		species = "Lurker",
		shape = "lurker",
		scale = 1.1,
		color = Color3.fromRGB(196, 176, 130), -- sand-camouflage
		finColor = Color3.fromRGB(166, 146, 104),
		markColor = Color3.fromRGB(120, 100, 70), -- mottling
	},
}

-- A giant clam that sits shut like a rock. Come close and it snaps, then
-- hangs open for a moment - the only time it can be hurt. Full of pearls.
Creatures.items.pearl_mimic = {
	id = "pearl_mimic",
	name = "Pearl Mimic",
	rarity = "Rare",
	archetype = "mimic",
	health = 320,
	drops = {
		materials = { nacre = { 1, 2 }, pearl = { 2, 4 }, fish_scale = { 1, 2 } },
	},
	body = {
		model = "CreaturePack",
		species = "Mimic",
		shape = "mimic",
		stance = "upright", -- the lid hinges about the shell's own axes
		scale = 1.0,
		color = Color3.fromRGB(120, 112, 104), -- lower shell, rock-grey
		finColor = Color3.fromRGB(140, 130, 118), -- the lid
		markColor = Color3.fromRGB(246, 240, 248), -- the pearl
	},
}

-- A hermit crab living in a coin pot. Scuttles at you, pickpockets a cut of
-- your coins on contact, and runs. Kill it for the coins back plus a bonus.
Creatures.items.pickpocket_hermit = {
	id = "pickpocket_hermit",
	name = "Pickpocket Hermit",
	rarity = "Uncommon",
	archetype = "thief",
	health = 150,
	drops = {
		materials = { pearl = { 1, 1 }, kelp_fiber = { 1, 2 } },
	},
	body = {
		model = "CreaturePack",
		species = "Hermit",
		shape = "hermit",
		scale = 1.0,
		color = Color3.fromRGB(150, 96, 64), -- the clay pot
		finColor = Color3.fromRGB(214, 120, 80), -- the crab
		markColor = Color3.fromRGB(255, 204, 92), -- coins (the HUD's coin gold)
	},
}

-- An electric ray. Slides at you, crackles as it charges - hit it then and
-- the shock is yours - and discharges a ring that hurts everyone inside it.
Creatures.items.voltray = {
	id = "voltray",
	name = "Voltray",
	rarity = "Epic",
	archetype = "pulser",
	health = 520,
	drops = {
		materials = { volt_gland = { 1, 2 }, fish_scale = { 3, 5 }, pearl = { 1, 2 }, cursed_bone = { 1, 1 } },
	},
	body = {
		model = "CreaturePack",
		species = "Voltray",
		shape = "ray",
		scale = 1.3,
		color = Color3.fromRGB(60, 66, 92), -- slate blue
		finColor = Color3.fromRGB(84, 92, 124), -- wing edges
		markColor = Color3.fromRGB(120, 220, 255), -- the electric organs (glow while charging)
	},
}

-- ============================================================ Legendary chase
-- One per island (docs/revamp-plan.md): a giant passive trophy fish at the
-- Legendary tier, so the tier finally rolls (Tuning.Rarity.WEIGHTS.Legendary)
-- and high-luck rods / minRarity perks have a real payoff. Big rewards, and it
-- drops the island's best materials generously.

Creatures.items.sunking_coelacanth = {
	id = "sunking_coelacanth",
	name = "Sunking Coelacanth",
	rarity = "Legendary",
	archetype = "flopper",
	health = 900,
	rewards = { coins = { 250, 400 }, xp = 600 },
	drops = {
		materials = { volt_gland = { 2, 3 }, pearl = { 2, 3 } },
	},
	body = {
		-- No Coelacanth species in the FishPack yet: rides the Tuna frame
		-- recoloured to burnished gold until fish_gen.py grows one.
		model = "FishPack",
		species = "Tuna",
		scale = 2.0,
		color = Color3.fromRGB(196, 158, 72), -- burnished gold flanks
		finColor = Color3.fromRGB(140, 104, 48), -- ancient bronze lobed fins
		markColor = Color3.fromRGB(240, 226, 170), -- pale royal speckling
	},
}

-- ============================================================ Bosses
-- Brinejaw, the Drowned Leviathan - Starter Cove's boss (Bosses.luau). A
-- colossal anglerfish-leviathan: armoured head, a maw of fangs, a glowing
-- lure, sail fins, a lashing tail. Rarity "Boss" keeps it out of every cast
-- roll; BossService raises it off the dock's end once a player qualifies.
Creatures.items.brinejaw = {
	id = "brinejaw",
	name = "Brinejaw, the Drowned Leviathan",
	rarity = "Boss",
	archetype = "boss",
	boss = "brinejaw",
	-- A true endgame wall: big HP so even the highest-DPS weapon (Drowncleaver,
	-- ~113 dps) is a long fight, on top of Bosses.luau's harder attacks. Tuned
	-- with roblox-game-83 against the boss fight loop's uptime.
	health = 9000,
	rewards = { coins = { 900, 1300 }, xp = 2600 },
	-- Its heart is NOT a material drop: BossService sets the permanent
	-- Heart_brinejaw attribute on every participant instead (the trophy that
	-- gates the island's Legendary crafts and, one day, the final summon).
	drops = {
		materials = {
			pearl = { 4, 6 },
			cursed_bone = { 4, 6 },
			barnacle_chitin = { 3, 5 },
			fish_scale = { 6, 10 },
		},
	},
	body = {
		model = "CreaturePack",
		species = "Leviathan",
		shape = "leviathan",
		stance = "upright", -- a standing monster: faces the player with +X, rides low in the water (Bosses.submerge)
		scale = 1.5, -- colossal: ~26 studs long. Bosses.luau range constants (standoff/aggro/snap/submerge) are scaled to match by roblox-game-83.
		color = Color3.fromRGB(46, 62, 74), -- drowned armour-grey hide
		finColor = Color3.fromRGB(96, 118, 128), -- fins, fangs, spines
		markColor = Color3.fromRGB(120, 255, 214), -- the lure + eye glow (neon)
	},
}

-- ============================================================ Companion
-- Not a catch: the hatchling Split Roe brings up, which fights hostiles ON THE
-- PLAYER'S SIDE for a minute and then leaves (CreatureService's "companion"
-- archetype, spawned from FishingService with extra.friendly). Rarity
-- "Companion" is a bucket nothing rolls from - RARITY_ORDER in FishingService
-- never walks it - which is how the boss row stays out of casts too.
--
-- It carries zero `rewards` deliberately rather than leaving them nil: a
-- hostile CAN kill it, and ProgressionService warns on a row with no reward
-- table for its rarity. Nothing should pay out for losing your own pet.
Creatures.items.hatchling = {
	id = "hatchling",
	name = "Roe Hatchling",
	rarity = "Companion",
	archetype = "companion",
	health = 120, -- kept in step with Tuning.Bait.HATCHLING_HEALTH
	rewards = { coins = { 0, 0 }, xp = 0 },
	body = {
		model = "FishPack",
		species = "Perch",
		scale = 0.4, -- a fry: clearly smaller than anything it fights
		color = Color3.fromRGB(244, 236, 190), -- roe-pale, matching Split Roe
		finColor = Color3.fromRGB(255, 214, 120),
		markColor = Color3.fromRGB(180, 150, 90),
	},
}

-- ============================================================ Volcano (2026-08-23)
-- The lava island's roster - an original set (not ocean reskins), from the
-- roster the user approved. Every row is `waters = "volcano"`, so it rolls ONLY
-- when the cast lands in the lava (FishingService filters the pool by surface;
-- ocean rows, having no `waters`, never roll there and these never roll in the
-- ocean). They drop the volcano material chain (Materials.luau).
--
-- REBALANCED 2026-08-25 (docs/revamp-plan.md): health x2.2 and explicit
-- `rewards` at x2 the Tuning.Rewards.BY_RARITY baseline - the volcano is the
-- second island now and pays like it. The rewards blocks re-scale to x6 when
-- the island slides to slot 4 (Session 4).
--
-- Meshes are a later pass (83's *_gen.py): the fish reuse a recolored FishPack
-- species and the hostiles a procedural `shape` stand-in, so all are testable
-- now. The hostiles ship on the closest existing archetype (they fight
-- immediately); the signature mechanic named in each comment is 2f's follow-up
-- (CreatureService), a graceful no-op until then. See docs/volcano-content-spec.md.

-- ---- Volcano fish (passive floppers, lava palette) ----

Creatures.items.emberfin_perch = {
	id = "emberfin_perch",
	name = "Emberfin Perch",
	rarity = "Common",
	archetype = "flopper",
	health = 155,
	waters = "volcano",
	rewards = { coins = { 8, 16 }, xp = 24 },
	drops = { materials = { ember = { 1, 2 } } },
	body = {
		model = "FishPack",
		species = "Emberfin",
		scale = 0.7,
		color = Color3.fromRGB(66, 38, 38),
		finColor = Color3.fromRGB(217, 82, 26),
		markColor = Color3.fromRGB(255, 158, 36),
	},
}

Creatures.items.ashgill_minnow = {
	id = "ashgill_minnow",
	name = "Ashgill Minnow",
	rarity = "Common",
	archetype = "flopper",
	health = 145,
	waters = "volcano",
	rewards = { coins = { 8, 16 }, xp = 24 },
	drops = { materials = { ember = { 1, 1 }, sulfur = { 1, 1 } } },
	body = {
		model = "FishPack",
		species = "Ashgill",
		scale = 0.75,
		color = Color3.fromRGB(51, 48, 54),
		finColor = Color3.fromRGB(112, 54, 31),
		markColor = Color3.fromRGB(255, 133, 31),
	},
}

Creatures.items.magma_guppy = {
	id = "magma_guppy",
	name = "Magma Guppy",
	rarity = "Common",
	archetype = "flopper",
	health = 175,
	waters = "volcano",
	rewards = { coins = { 8, 16 }, xp = 24 },
	drops = { materials = { ember = { 1, 2 } } },
	body = {
		model = "FishPack",
		species = "MagmaGuppy",
		scale = 0.6,
		color = Color3.fromRGB(247, 107, 26),
		finColor = Color3.fromRGB(184, 51, 20),
		markColor = Color3.fromRGB(255, 204, 77),
	},
}

Creatures.items.obsidian_bass = {
	id = "obsidian_bass",
	name = "Obsidian Bass",
	rarity = "Uncommon",
	archetype = "flopper",
	health = 460,
	waters = "volcano",
	rewards = { coins = { 24, 40 }, xp = 70 },
	drops = { materials = { obsidian_shard = { 1, 2 } } },
	body = {
		model = "FishPack",
		species = "ObsidianBass",
		scale = 1.1,
		color = Color3.fromRGB(33, 31, 41),
		finColor = Color3.fromRGB(54, 48, 64),
		markColor = Color3.fromRGB(255, 102, 26), -- molten cracks
	},
}

Creatures.items.basalt_cod = {
	id = "basalt_cod",
	name = "Basalt Cod",
	rarity = "Uncommon",
	archetype = "flopper",
	health = 550,
	waters = "volcano",
	rewards = { coins = { 24, 40 }, xp = 70 },
	drops = { materials = { obsidian_shard = { 1, 2 }, sulfur = { 1, 1 } } },
	body = {
		model = "FishPack",
		species = "BasaltCod",
		scale = 1.5,
		color = Color3.fromRGB(56, 54, 61),
		finColor = Color3.fromRGB(41, 38, 48),
		markColor = Color3.fromRGB(250, 122, 36),
	},
}

Creatures.items.pyre_salmon = {
	id = "pyre_salmon",
	name = "Pyre Salmon",
	rarity = "Rare",
	archetype = "flopper",
	health = 790,
	waters = "volcano",
	rewards = { coins = { 70, 110 }, xp = 180 },
	drops = { materials = { magma_core = { 1, 1 }, obsidian_shard = { 1, 2 } } },
	body = {
		model = "FishPack",
		species = "PyreSalmon",
		scale = 1.5,
		color = Color3.fromRGB(77, 36, 31),
		finColor = Color3.fromRGB(224, 87, 31),
		markColor = Color3.fromRGB(255, 179, 56),
	},
}

Creatures.items.magmafin_tuna = {
	id = "magmafin_tuna",
	name = "Magmafin Tuna",
	rarity = "Epic",
	archetype = "flopper",
	health = 1450,
	waters = "volcano",
	rewards = { coins = { 180, 280 }, xp = 440 },
	drops = { materials = { magma_core = { 1, 2 }, obsidian_shard = { 2, 3 } } },
	body = {
		model = "FishPack",
		species = "MagmafinTuna",
		scale = 2.2,
		color = Color3.fromRGB(31, 28, 36),
		finColor = Color3.fromRGB(148, 56, 31),
		markColor = Color3.fromRGB(255, 140, 31), -- molten finlets
	},
}

-- ---- Volcano hostiles ----
-- `archetype` = what ships (fights now); the â†’ note is the signature mechanic
-- 2f will build (a new CreatureService updater), then flip the field if it's a
-- brand-new archetype.

-- A rooted lava vent. Keeps its distance and lobs glowing globs of molten rock
-- where you stood. Fits `spitter` as-is - no new archetype needed.
Creatures.items.fumarole = {
	id = "fumarole",
	name = "Fumarole",
	rarity = "Uncommon",
	archetype = "spitter",
	health = 420,
	waters = "volcano",
	rewards = { coins = { 24, 40 }, xp = 70 },
	drops = { materials = { sulfur = { 1, 2 }, ember = { 1, 2 } } },
	body = {
		model = "CreaturePack",
		species = "Fumarole",
		shape = "gulletcod",
		scale = 1.2,
		color = Color3.fromRGB(74, 66, 62), -- cooled rock
		finColor = Color3.fromRGB(52, 46, 44),
		markColor = Color3.fromRGB(255, 128, 40), -- glowing vent mouth
	},
}

-- A hovering cloud of live embers. Drifts at you and burns on contact, floats
-- high when hit. Fits `drifter` as-is.
Creatures.items.ember_swarm = {
	id = "ember_swarm",
	name = "Ember Swarm",
	rarity = "Uncommon",
	archetype = "drifter",
	health = 330,
	waters = "volcano",
	rewards = { coins = { 24, 40 }, xp = 70 },
	drops = { materials = { ember = { 2, 3 } } },
	body = {
		model = "CreaturePack",
		species = "EmberSwarm",
		shape = "jelly",
		stance = "upright",
		scale = 1.0,
		color = Color3.fromRGB(247, 115, 30), -- the cinders, lit but not glowing
		finColor = Color3.fromRGB(184, 62, 26),
		markColor = Color3.fromRGB(255, 153, 36), -- the heart and the hot shards
	},
}

-- A blob of living magma. Rushes and rams, and killing it divides it into two
-- smaller oozes (the halves are weaker and can't split again).
Creatures.items.magma_ooze = {
	id = "magma_ooze",
	name = "Magma Ooze",
	rarity = "Rare",
	archetype = "splitter",
	health = 530,
	waters = "volcano",
	rewards = { coins = { 70, 110 }, xp = 180 },
	drops = { materials = { magma_core = { 1, 1 }, sulfur = { 1, 2 } } },
	body = {
		model = "CreaturePack",
		species = "MagmaOoze",
		shape = "urchin",
		scale = 1.0,
		-- The mesh puts the MOLTEN mass in the marks layer and lays cooled crust
		-- over it, so these read: body = the cooled skirt, fins = black basalt
		-- slabs, marks = the lava showing through the gaps.
		color = Color3.fromRGB(66, 34, 26),
		finColor = Color3.fromRGB(33, 28, 30),
		markColor = Color3.fromRGB(255, 96, 16), -- the melt itself
	},
}

-- A crab plated in volcanic glass. Rushes claws-first, and punching it in the
-- face barely scratches it and drives glass into your fist; its back is soft.
Creatures.items.obsidian_shardback = {
	id = "obsidian_shardback",
	name = "Obsidian Shardback",
	rarity = "Rare",
	archetype = "thornback",
	health = 700,
	waters = "volcano",
	rewards = { coins = { 70, 110 }, xp = 180 },
	drops = { materials = { obsidian_shard = { 2, 3 } } },
	body = {
		model = "CreaturePack",
		species = "Shardback",
		shape = "crab",
		scale = 1.1,
		color = Color3.fromRGB(44, 40, 52), -- obsidian shell
		finColor = Color3.fromRGB(58, 54, 66), -- claws + legs
		markColor = Color3.fromRGB(226, 96, 44), -- molten glow between plates
	},
}

-- A wraith of smoke and cinders. Shambles at you, shedding burning smoke that
-- keeps burning where it was dropped - chasing it through its own trail hurts.
Creatures.items.cinder_djinn = {
	id = "cinder_djinn",
	name = "Cinder Djinn",
	rarity = "Rare",
	archetype = "gascloud",
	health = 570,
	waters = "volcano",
	rewards = { coins = { 70, 110 }, xp = 180 },
	drops = { materials = { sulfur = { 1, 2 }, ember = { 2, 3 } } },
	body = {
		model = "CreaturePack",
		species = "CinderDjinn",
		shape = "zombie",
		stance = "upright",
		scale = 1.1,
		color = Color3.fromRGB(64, 56, 60), -- smoke-body
		finColor = Color3.fromRGB(44, 38, 42),
		markColor = Color3.fromRGB(255, 120, 48), -- ember eyes / core
	},
}

-- A magnetised eel that thrashes across the rim. Dashes past you like a
-- charger, and every few seconds hauls you bodily toward it.
Creatures.items.lodestone_eel = {
	id = "lodestone_eel",
	name = "Lodestone Eel",
	rarity = "Epic",
	archetype = "magnetize",
	health = 1050,
	waters = "volcano",
	rewards = { coins = { 180, 280 }, xp = 440 },
	drops = { materials = { magma_core = { 1, 1 }, obsidian_shard = { 1, 2 } } },
	body = {
		model = "CreaturePack",
		species = "LodestoneEel",
		shape = "skipper",
		scale = 1.2,
		color = Color3.fromRGB(72, 80, 98), -- dark magnetite
		finColor = Color3.fromRGB(50, 56, 70),
		markColor = Color3.fromRGB(150, 176, 210), -- polarised sheen
	},
}

-- A hulking figure of cooling slag around a molten heart. Shambles and pounds.
-- Armoured in cooled slag: nearly everything bounces off until enough hits
-- crack it open, and then its molten core is exposed for a few seconds.
Creatures.items.slagheart_golem = {
	id = "slagheart_golem",
	name = "Slagheart Golem",
	rarity = "Epic",
	archetype = "crust",
	health = 1010,
	waters = "volcano",
	rewards = { coins = { 180, 280 }, xp = 440 },
	drops = { materials = { magma_core = { 1, 2 }, obsidian_shard = { 2, 3 } } },
	body = {
		model = "CreaturePack",
		species = "SlagGolem",
		shape = "zombie",
		stance = "upright",
		scale = 1.4,
		color = Color3.fromRGB(58, 52, 54), -- blackened slag
		finColor = Color3.fromRGB(80, 44, 34),
		markColor = Color3.fromRGB(255, 116, 40), -- the molten heart-core
	},
}

-- A bird of fire and ash. Dives at you like a charger, and its first death
-- isn't one: it drops, then rises at ~40% health and has to be put down again.
-- Promoted to Legendary 2026-08-25: the volcano's chase creature, now that the
-- tier rolls (Tuning.Rarity.WEIGHTS.Legendary).
Creatures.items.ashfeather_phoenix = {
	id = "ashfeather_phoenix",
	name = "Ashfeather Phoenix",
	rarity = "Legendary",
	archetype = "reborn",
	health = 1100,
	waters = "volcano",
	rewards = { coins = { 500, 800 }, xp = 1200 },
	drops = { materials = { magma_core = { 2, 3 }, obsidian_shard = { 2, 3 } } },
	body = {
		model = "CreaturePack",
		species = "Phoenix",
		shape = "ray",
		scale = 1.3,
		-- Deep ember body, blazing wings: the fins ARE the plumage here, so they
		-- carry the bright colour and the body stays dark under it.
		color = Color3.fromRGB(184, 56, 23), -- body, under the wings
		finColor = Color3.fromRGB(242, 107, 26), -- wing and tail feathers
		markColor = Color3.fromRGB(255, 158, 30), -- the fire itself
	},
}

-- Pyrelisk, the Caldera Wyrm - Ashfall Caldera's boss (Bosses.luau). A
-- colossal obsidian-scaled magma serpent that rises out of the boiling
-- shallows off the shore jetty. Rarity "Boss" keeps it out of every cast
-- roll; it is summoned by casting Caldera's Call (Bait.luau), exactly the
-- Brinejaw ritual. Its heart is the Heart_pyrelisk attribute, not a drop.
Creatures.items.pyrelisk = {
	id = "pyrelisk",
	name = "Pyrelisk, the Caldera Wyrm",
	rarity = "Boss",
	archetype = "boss",
	boss = "pyrelisk",
	waters = "volcano",
	-- Interim tuning for the volcano's slot-2 band (L8-14): a wall the way
	-- Brinejaw is for L7, against island-2 gear (~130-180 dps). Re-tunes to
	-- ~40,000 when the island slides to slot 4 (docs/revamp-plan.md).
	health = 16000,
	rewards = { coins = { 2000, 2800 }, xp = 5000 },
	drops = {
		materials = {
			magma_core = { 2, 3 },
			obsidian_shard = { 4, 6 },
			ember = { 6, 10 },
			sulfur = { 4, 6 },
		},
	},
	body = {
		model = "CreaturePack",
		species = "Pyrelisk",
		shape = "leviathan", -- pre-import stand-in: the boss silhouette recoloured molten
		stance = "upright",
		scale = 1.5,
		color = Color3.fromRGB(38, 32, 40), -- cooled obsidian hide
		finColor = Color3.fromRGB(80, 44, 34), -- basalt fin plates
		markColor = Color3.fromRGB(255, 96, 16), -- the melt in every seam (neon)
	},
}

-- ============================================================ Blackmire Fen (revamp Session 2)
-- The swamp island's roster (docs/revamp-plan.md, Island 2): 13 rows + the
-- Golden Gar chase + Old Gnashroot. Every row is `waters = "swamp"`, rolled
-- only when the cast lands in Swamp_Water (the fen's interior murk pools);
-- the sea off the fen's dock fishes the ocean roster like anywhere else.
-- This island introduces the FLYERS (Systems §2): the gull, the wisp and the
-- dragonfly circle out of melee reach and dive - the grounded recovery after
-- each dive is the melee window, and the new guns reach them any time.
--
-- Health and explicit rewards sit at the island-2 multiplier (x2 the
-- Tuning.Rewards baseline), matching its L8-14 band. Meshes: the fish reuse
-- recoloured FishPack species and the hostiles procedural `shape` stand-ins
-- (the volcano pattern) until the art lane's swamp species land in the
-- CreaturePack - each row already names its final species.

-- ---- Fen fish (passive floppers, peat palette) ----

Creatures.items.peat_darter = {
	id = "peat_darter",
	name = "Peat Darter",
	rarity = "Common",
	archetype = "flopper",
	health = 140,
	waters = "swamp",
	rewards = { coins = { 8, 16 }, xp = 24 },
	drops = { materials = { bog_iron = { 1, 1 } } },
	body = {
		model = "FishPack",
		species = "Perch",
		scale = 0.65,
		color = Color3.fromRGB(96, 84, 52),
		finColor = Color3.fromRGB(140, 110, 58),
		markColor = Color3.fromRGB(52, 44, 30),
	},
}

Creatures.items.mudwhisker_catfish = {
	id = "mudwhisker_catfish",
	name = "Mudwhisker Catfish",
	rarity = "Common",
	archetype = "flopper",
	health = 165,
	waters = "swamp",
	rewards = { coins = { 8, 16 }, xp = 24 },
	drops = { materials = { bog_iron = { 1, 2 } } },
	body = {
		model = "FishPack",
		species = "Catfish",
		scale = 1.25,
		color = Color3.fromRGB(74, 68, 54),
		finColor = Color3.fromRGB(54, 50, 40),
	},
}

Creatures.items.bog_bream = {
	id = "bog_bream",
	name = "Bog Bream",
	rarity = "Common",
	archetype = "flopper",
	health = 150,
	waters = "swamp",
	rewards = { coins = { 8, 16 }, xp = 24 },
	drops = { materials = { bog_iron = { 1, 1 } } },
	body = {
		model = "FishPack",
		species = "Bass",
		scale = 0.9,
		color = Color3.fromRGB(104, 110, 70),
		finColor = Color3.fromRGB(76, 82, 52),
		markColor = Color3.fromRGB(46, 52, 34),
	},
}

Creatures.items.rustgill_gar = {
	id = "rustgill_gar",
	name = "Rustgill Gar",
	rarity = "Uncommon",
	archetype = "flopper",
	health = 330,
	waters = "swamp",
	rewards = { coins = { 24, 40 }, xp = 70 },
	drops = { materials = { bog_iron = { 1, 2 }, fish_scale = { 1, 2 } } },
	body = {
		model = "FishPack",
		species = "Mackerel",
		scale = 1.6,
		color = Color3.fromRGB(122, 96, 60),
		finColor = Color3.fromRGB(160, 84, 48),
		markColor = Color3.fromRGB(196, 118, 60),
	},
}

-- ---- Fen hostiles ----

-- The island's flyer tutor: circles overhead out of punching reach, then
-- dive-bombs where you stood. Shoot it down, or catch it in the grounded
-- recovery after each dive.
Creatures.items.bog_gull = {
	id = "bog_gull",
	name = "Bog Gull",
	rarity = "Uncommon",
	archetype = "flyer",
	health = 260,
	waters = "swamp",
	rewards = { coins = { 24, 40 }, xp = 70 },
	drops = { materials = { fish_scale = { 1, 2 } } },
	body = {
		model = "CreaturePack",
		species = "BogGull",
		shape = "ray", -- winged stand-in until the pack species lands
		scale = 1.0,
		color = Color3.fromRGB(214, 210, 198), -- dirty white feathers
		finColor = Color3.fromRGB(120, 116, 104), -- storm-grey wingtips
		markColor = Color3.fromRGB(228, 160, 62), -- the beak
	},
}

Creatures.items.croakjaw_toad = {
	id = "croakjaw_toad",
	name = "Croakjaw Toad",
	rarity = "Uncommon",
	archetype = "spitter",
	health = 300,
	waters = "swamp",
	rewards = { coins = { 24, 40 }, xp = 70 },
	drops = { materials = { gator_scute = { 1, 1 } } },
	body = {
		model = "CreaturePack",
		species = "CroakjawToad",
		shape = "gulletcod",
		scale = 1.1,
		color = Color3.fromRGB(92, 112, 62),
		finColor = Color3.fromRGB(66, 84, 48),
		markColor = Color3.fromRGB(214, 196, 120), -- the throat sac
	},
}

Creatures.items.mire_leech = {
	id = "mire_leech",
	name = "Mire Leech",
	rarity = "Uncommon",
	archetype = "rusher",
	health = 280,
	waters = "swamp",
	rewards = { coins = { 24, 40 }, xp = 70 },
	drops = { materials = { bog_iron = { 1, 2 } } },
	body = {
		model = "CreaturePack",
		species = "MireLeech",
		shape = "lurker",
		scale = 1.0,
		color = Color3.fromRGB(58, 46, 50),
		finColor = Color3.fromRGB(90, 58, 60),
		markColor = Color3.fromRGB(160, 60, 62), -- the sucker mouth
	},
}

Creatures.items.snagtooth_gator = {
	id = "snagtooth_gator",
	name = "Snagtooth Gator",
	rarity = "Rare",
	archetype = "charger",
	health = 620,
	waters = "swamp",
	rewards = { coins = { 70, 110 }, xp = 180 },
	drops = { materials = { gator_scute = { 1, 2 } } },
	body = {
		model = "CreaturePack",
		species = "SnagtoothGator",
		shape = "skipper",
		scale = 1.5,
		color = Color3.fromRGB(70, 88, 56),
		finColor = Color3.fromRGB(52, 66, 44),
		markColor = Color3.fromRGB(206, 198, 160), -- the snaggle teeth
	},
}

-- A cold flame that drifts above the murk. Flyer machine, but its "dive" is
-- the light swooping through you.
Creatures.items.will_o_wisp = {
	id = "will_o_wisp",
	name = "Will-o-Wisp",
	rarity = "Rare",
	archetype = "flyer",
	health = 480,
	waters = "swamp",
	rewards = { coins = { 70, 110 }, xp = 180 },
	drops = { materials = { wisp_light = { 1, 2 } } },
	body = {
		model = "CreaturePack",
		species = "WillOWisp",
		shape = "jelly", -- a hovering bell of light until the pack species lands
		scale = 0.9,
		color = Color3.fromRGB(150, 235, 200),
		finColor = Color3.fromRGB(110, 190, 170),
		markColor = Color3.fromRGB(220, 255, 235), -- the core
	},
}

-- The fen's skythief: it doesn't want you, it wants the catch flopping on
-- the bank. Kill it before it clears the treeline or lose the fish.
Creatures.items.dread_dragonfly = {
	id = "dread_dragonfly",
	name = "Dread Dragonfly",
	rarity = "Rare",
	archetype = "skythief",
	health = 440,
	waters = "swamp",
	rewards = { coins = { 70, 110 }, xp = 180 },
	drops = { materials = { wisp_light = { 1, 1 }, fish_scale = { 1, 2 } } },
	body = {
		model = "CreaturePack",
		species = "DreadDragonfly",
		shape = "ray",
		scale = 1.1,
		color = Color3.fromRGB(48, 66, 72), -- oil-dark body
		finColor = Color3.fromRGB(130, 190, 196), -- glass wings
		markColor = Color3.fromRGB(96, 226, 210), -- the eyes
	},
}

Creatures.items.sunken_trapper = {
	id = "sunken_trapper",
	name = "Sunken Trapper",
	rarity = "Rare",
	archetype = "mimic",
	health = 560,
	waters = "swamp",
	rewards = { coins = { 70, 110 }, xp = 180 },
	drops = { materials = { wisp_light = { 1, 1 }, pearl = { 1, 1 } } },
	body = {
		model = "CreaturePack",
		species = "SunkenTrapper",
		shape = "mimic",
		stance = "upright",
		scale = 1.2,
		color = Color3.fromRGB(78, 70, 50), -- a drowned crate's rotten boards
		finColor = Color3.fromRGB(58, 52, 40), -- the lid
		markColor = Color3.fromRGB(150, 235, 200), -- the wisp-light lure inside
	},
}

Creatures.items.fen_serpent = {
	id = "fen_serpent",
	name = "Fen Serpent",
	rarity = "Epic",
	archetype = "spitter",
	health = 1050,
	waters = "swamp",
	rewards = { coins = { 180, 280 }, xp = 440 },
	drops = { materials = { fen_venom = { 1, 2 } } },
	body = {
		model = "CreaturePack",
		species = "FenSerpent",
		shape = "gulletcod",
		scale = 1.8,
		color = Color3.fromRGB(56, 74, 58),
		finColor = Color3.fromRGB(88, 110, 66),
		markColor = Color3.fromRGB(178, 210, 90), -- the venom sheen
	},
}

Creatures.items.peat_revenant = {
	id = "peat_revenant",
	name = "Peat Revenant",
	rarity = "Epic",
	archetype = "shambler",
	health = 1150,
	waters = "swamp",
	rewards = { coins = { 180, 280 }, xp = 440 },
	drops = { materials = { fen_venom = { 1, 1 }, bog_iron = { 1, 2 } } },
	body = {
		model = "CreaturePack",
		species = "PeatRevenant",
		shape = "zombie",
		stance = "upright",
		scale = 1.15,
		color = Color3.fromRGB(70, 66, 50), -- peat-tanned hide
		finColor = Color3.fromRGB(50, 48, 38),
		markColor = Color3.fromRGB(150, 235, 200), -- wisp-lit eyes
	},
}

-- The fen's Legendary chase: an impossible golden gar older than the trees.
Creatures.items.golden_gar = {
	id = "golden_gar",
	name = "The Golden Gar",
	rarity = "Legendary",
	archetype = "flopper",
	health = 1900,
	waters = "swamp",
	rewards = { coins = { 500, 800 }, xp = 1200 },
	drops = {
		materials = { fen_venom = { 2, 3 }, pearl = { 2, 3 } },
	},
	body = {
		model = "FishPack",
		species = "Mackerel",
		scale = 2.2,
		color = Color3.fromRGB(212, 172, 74), -- old gold flanks
		finColor = Color3.fromRGB(150, 112, 44),
		markColor = Color3.fromRGB(244, 226, 150), -- pale royal banding
	},
}

-- Old Gnashroot, the Fen Tyrant - Blackmire Fen's boss (Bosses.luau). A
-- moss-backed snapping horror, half gator half drowned oak, summoned by
-- casting Tyrant's Call. Rarity "Boss" keeps it out of every roll; its heart
-- is the Heart_old_gnashroot attribute, never a drop.
Creatures.items.old_gnashroot = {
	id = "old_gnashroot",
	name = "Old Gnashroot, the Fen Tyrant",
	rarity = "Boss",
	archetype = "boss",
	boss = "old_gnashroot",
	waters = "swamp",
	-- A wall for L8-14 gear (~120-170 dps): a longer fight than Brinejaw
	-- because the brood (toads, gulls) keeps interrupting it.
	health = 16000,
	rewards = { coins = { 1800, 2600 }, xp = 5200 },
	drops = {
		materials = {
			bog_iron = { 6, 10 },
			gator_scute = { 4, 6 },
			wisp_light = { 3, 5 },
			fen_venom = { 2, 4 },
		},
	},
	body = {
		model = "CreaturePack",
		species = "Gnashroot",
		shape = "leviathan", -- pre-import stand-in: the boss silhouette, moss-dark
		stance = "upright",
		scale = 1.5,
		color = Color3.fromRGB(58, 66, 46), -- moss-backed hide
		finColor = Color3.fromRGB(88, 76, 52), -- root-bark plates
		markColor = Color3.fromRGB(150, 235, 200), -- wisp-lit eyes and maw (neon)
	},
}

-- Rarity -> list of rows, so a rarity roll can pick uniformly within the
-- tier. Built once here rather than rescanned per cast.
Creatures.byRarity = {} :: { [string]: { Creature } }
for _, row in Creatures.items do
	local bucket = Creatures.byRarity[row.rarity]
	if not bucket then
		bucket = {}
		Creatures.byRarity[row.rarity] = bucket
	end
	table.insert(bucket, row)
end

-- Stable iteration order for the buckets above (table iteration order isn't
-- guaranteed, and a rarity roll has to walk tiers deterministically).
for _, bucket in Creatures.byRarity do
	table.sort(bucket, function(a, b)
		return a.id < b.id
	end)
end

return Creatures
