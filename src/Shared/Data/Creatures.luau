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
		materials = { skitterfin = { 1, 2 }, fish_scale = { 1, 1 } },
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
		materials = { brine_gland = { 1, 2 }, fish_scale = { 1, 1 } },
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
		materials = { tidebomb_spine = { 1, 2 }, fish_scale = { 2, 3 }, barnacle_chitin = { 1, 1 } },
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
		materials = { moonjelly = { 1, 2 }, kelp_fiber = { 1, 2 } },
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
		materials = { lurker_hide = { 1, 2 }, fish_scale = { 1, 2 } },
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
		materials = { gild_shell = { 1, 2 }, kelp_fiber = { 1, 1 } },
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
	drops = {
		materials = {
			brineheart = { 1, 2 },
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
	health = 70,
	waters = "volcano",
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
	health = 65,
	waters = "volcano",
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
	health = 80,
	waters = "volcano",
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
	health = 210,
	waters = "volcano",
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
	health = 250,
	waters = "volcano",
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
	health = 360,
	waters = "volcano",
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
	health = 660,
	waters = "volcano",
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
	health = 190,
	waters = "volcano",
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
	health = 150,
	waters = "volcano",
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
	health = 240,
	waters = "volcano",
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
	health = 320,
	waters = "volcano",
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
	health = 260,
	waters = "volcano",
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
	health = 480,
	waters = "volcano",
	drops = { materials = { lodestone = { 1, 2 }, magma_core = { 1, 1 } } },
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
	health = 460,
	waters = "volcano",
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
Creatures.items.ashfeather_phoenix = {
	id = "ashfeather_phoenix",
	name = "Ashfeather Phoenix",
	rarity = "Epic",
	archetype = "reborn",
	health = 500,
	waters = "volcano",
	drops = { materials = { phoenix_ash = { 1, 1 }, magma_core = { 1, 1 } } },
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
