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

	-- ---- The kit engine (hostile revamp, 2026-08-28) ----
	-- A row with `moves` fights on CreatureService's kit engine - the boss
	-- attack book scaled down. Each move: the boss vocabulary
	-- (name/handler/windup/duration/recover/cooldown/damage/radius/tell/skin
	-- + any handler-specific params), plus `below` (only picked at/below this
	-- HP fraction - mini-phases), `follow` (forced next move - combos),
	-- `weight` (pick weighting), `range` (held until the player is this
	-- close), `expose` (seconds of double-damage daze after the recover).
	-- Rows WITHOUT `moves` behave exactly as before.
	moves: { { [string]: any } }?,
	-- The quirk layer (CreatureService GIMMICKS): { kind = "harden" |
	-- "frenzy" | "phasey" | "spines" | "static" | "slippery" | "leech" |
	-- "deathburst", ...params }.
	gimmick: { [string]: any }?,
	-- Between-moves locomotion for a kitted row: nil = the generic prowl
	-- (face + close + breathe); an archetype name opts into that archetype's
	-- FULL updater (its built-in attack then runs as part of the kit).
	movement: string?,
	-- Per-row overrides: Tuning.Creature keys (plus STANDOFF/TURN_RATE_DEG),
	-- the contact-damage band, and the pause between move picks.
	tuning: { [string]: number }?,
	contactDamage: { number }?, -- { min, max }; default = the archetype global
	attackGap: { number }?, -- { min, max } seconds; default = KIT_DEFAULTS
}

Creatures.items = {} :: { [string]: Creature }

-- Kit pacing defaults by rarity: how long a kitted creature pauses between
-- move picks when its row doesn't say. Tighter tiers fight busier.
Creatures.KIT_DEFAULTS = {
	Common = { gapMin = 2.5, gapMax = 3.5 },
	Uncommon = { gapMin = 2.0, gapMax = 3.0 },
	Rare = { gapMin = 1.6, gapMax = 2.6 },
	Epic = { gapMin = 1.2, gapMax = 2.0 },
	Legendary = { gapMin = 1.0, gapMax = 1.6 },
}

-- ============================================================ Common

Creatures.items.perch = {
	id = "perch",
	name = "Yellow Perch",
	rarity = "Common",
	archetype = "rusher",
	health = 60,
	-- KIT PILOT (engine slice, 2026-08-28): the dojo's first lesson - one
	-- slow, honest leap, and a body that goes flying when you hit it back.
	moves = {
		{
			name = "flipslap",
			handler = "lunge",
			windup = 0.9,
			duration = 0.35,
			recover = 0.6,
			cooldown = 3.0,
			damage = { 4, 7 },
			reach = 8,
			hop = 2.5,
			radius = 4,
			tell = "snap",
			skin = "brine",
		},
	},
	gimmick = { kind = "slippery", mult = 2.2 },
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
	archetype = "charger",
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
	archetype = "rusher",
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
	archetype = "charger",
	health = 180,
	drops = {
		materials = { tidehide = { 1, 1 }, fish_scale = { 1, 2 } },
	},
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
	archetype = "spitter",
	health = 220,
	-- KIT PILOT: the classic spit rebuilt on the kit system (the boss
	-- `volley` handler at minnow scale), plus a close-range flare that
	-- leaves it wide open - punishing it is the lesson.
	moves = {
		{
			name = "loogie",
			handler = "volley",
			windup = 0.8,
			duration = 0.5,
			recover = 0.5,
			cooldown = 4.0,
			damage = { 6, 10 },
			count = 1,
			spread = 3,
			flight = 0.9,
			stagger = 0,
			radius = 5,
			range = 34,
			skin = "brine",
		},
		{
			name = "gillflare",
			handler = "snap",
			windup = 0.6,
			duration = 0.3,
			recover = 0.4,
			cooldown = 5.0,
			damage = { 5, 8 },
			lunge = 5,
			radius = 6,
			cone = math.rad(70),
			range = 10,
			expose = 1.2,
			tell = "snap",
			skin = "brine",
		},
	},
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
	archetype = "burrower",
	health = 240,
	drops = {
		materials = { tidehide = { 1, 1 }, fish_scale = { 1, 2 } },
	},
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
	archetype = "charger",
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
	-- KIT PILOT: the first Rare kit - a two-snip combo (`follow`), a cone
	-- gust that shoves you off its face, and a shell that hardens during
	-- windups: hit the recover windows, not the tells.
	moves = {
		{
			name = "snip",
			handler = "snap",
			windup = 0.55,
			duration = 0.3,
			recover = 0.35,
			cooldown = 2.6,
			damage = { 8, 12 },
			lunge = 5,
			radius = 7,
			cone = math.rad(70),
			range = 14,
			follow = "snip2",
			tell = "snap",
			skin = "brine",
		},
		{
			name = "snip2",
			handler = "snap",
			windup = 0.3,
			duration = 0.3,
			recover = 0.5,
			cooldown = 6.0,
			damage = { 8, 12 },
			lunge = 4,
			radius = 7,
			cone = math.rad(70),
			weight = 0, -- follow-only: the second half of the combo
			tell = "snap",
			skin = "brine",
		},
		{
			name = "bubblejet",
			handler = "gustpush",
			windup = 0.8,
			duration = 0.3,
			recover = 0.5,
			cooldown = 6.5,
			damage = { 5, 8 },
			radius = 12,
			cone = math.rad(45),
			push = 55,
			range = 11,
			tell = "gustTell",
			skin = "brine",
		},
	},
	gimmick = { kind = "harden", mult = 0.35 },
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
		materials = { brine_sinew = { 1, 1 }, cursed_bone = { 1, 2 }, pearl = { 1, 1 } },
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
	archetype = "charger",
	health = 600,
	drops = {
		materials = { tidehide = { 1, 2 }, fish_scale = { 3, 4 }, pearl = { 1, 2 } },
	},
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
		materials = { brine_sinew = { 1, 2 }, cursed_bone = { 2, 3 }, barnacle_chitin = { 1, 2 } },
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
		materials = { brine_sinew = { 1, 1 }, fish_scale = { 1, 2 } },
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
	archetype = "pulser",
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
-- REBALANCED for the FINAL slot-4 band (revamp Session 4): health at ~x6 the
-- island-1 baseline and explicit `rewards` at x6 Tuning.Rewards.BY_RARITY -
-- the L22-28 island between Frostmaw Reach (x3.5) and Gloomtrench (x10).
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
	archetype = "rusher",
	health = 420,
	waters = "volcano",
	rewards = { coins = { 24, 48 }, xp = 72 },
	drops = { materials = { cinder_scale = { 1, 1 }, ember = { 1, 2 } } },
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
	archetype = "rusher",
	health = 390,
	waters = "volcano",
	rewards = { coins = { 24, 48 }, xp = 72 },
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
	archetype = "charger",
	health = 470,
	waters = "volcano",
	rewards = { coins = { 24, 48 }, xp = 72 },
	drops = { materials = { cinder_scale = { 1, 1 }, ember = { 1, 2 } } },
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
	archetype = "charger",
	health = 1250,
	waters = "volcano",
	rewards = { coins = { 72, 120 }, xp = 210 },
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
	archetype = "spitter",
	health = 1480,
	waters = "volcano",
	rewards = { coins = { 72, 120 }, xp = 210 },
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
	archetype = "charger",
	health = 2130,
	waters = "volcano",
	rewards = { coins = { 210, 330 }, xp = 540 },
	drops = { materials = { cinder_scale = { 1, 2 }, magma_core = { 1, 1 }, obsidian_shard = { 1, 2 } } },
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
	archetype = "charger",
	health = 3900,
	waters = "volcano",
	rewards = { coins = { 540, 840 }, xp = 1320 },
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
	health = 1130,
	waters = "volcano",
	rewards = { coins = { 72, 120 }, xp = 210 },
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
	health = 890,
	waters = "volcano",
	rewards = { coins = { 72, 120 }, xp = 210 },
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
	health = 1430,
	waters = "volcano",
	rewards = { coins = { 210, 330 }, xp = 540 },
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
	health = 1890,
	waters = "volcano",
	rewards = { coins = { 210, 330 }, xp = 540 },
	drops = { materials = { basalt_weave = { 1, 2 }, obsidian_shard = { 2, 3 } } },
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
	health = 1540,
	waters = "volcano",
	rewards = { coins = { 210, 330 }, xp = 540 },
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
	health = 2840,
	waters = "volcano",
	rewards = { coins = { 540, 840 }, xp = 1320 },
	drops = { materials = { basalt_weave = { 1, 2 }, magma_core = { 1, 1 }, obsidian_shard = { 1, 2 } } },
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
	health = 2730,
	waters = "volcano",
	rewards = { coins = { 540, 840 }, xp = 1320 },
	drops = { materials = { basalt_weave = { 1, 3 }, magma_core = { 1, 2 }, obsidian_shard = { 2, 3 } } },
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
	health = 6000,
	waters = "volcano",
	rewards = { coins = { 1500, 2400 }, xp = 3600 },
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
	health = 40000,
	rewards = { coins = { 9000, 13000 }, xp = 10000 },
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
	archetype = "charger",
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
	archetype = "burrower",
	health = 165,
	waters = "swamp",
	rewards = { coins = { 8, 16 }, xp = 24 },
	drops = { materials = { mire_hide = { 1, 1 }, bog_iron = { 1, 2 } } },
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
	archetype = "rusher",
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
	archetype = "charger",
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
	drops = { materials = { mire_hide = { 1, 1 }, gator_scute = { 1, 1 } } },
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
	drops = { materials = { mire_hide = { 1, 2 }, gator_scute = { 1, 2 } } },
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
	drops = { materials = { fen_chitin = { 1, 1 }, wisp_light = { 1, 1 }, fish_scale = { 1, 2 } } },
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
	drops = { materials = { fen_chitin = { 1, 2 }, wisp_light = { 1, 1 }, pearl = { 1, 1 } } },
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
	drops = { materials = { fen_chitin = { 1, 2 }, fen_venom = { 1, 2 } } },
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
	archetype = "charger",
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

-- ============================================================ Frostmaw Reach
-- The frozen reach (island 3, L15-21). Casts land in the pre-cut ice holes
-- (Frostmaw_IceHoles -> waters "ice"). Rewards x3.5 the island-1 baseline.

Creatures.items.icemelt_smelt = {
	id = "icemelt_smelt",
	name = "Icemelt Smelt",
	rarity = "Common",
	archetype = "charger",
	health = 220,
	waters = "ice",
	rewards = { coins = { 14, 28 }, xp = 42 },
	drops = { materials = { glacier_shard = { 1, 2 } } },
	body = {
		model = "FishPack",
		species = "IcemeltSmelt",
		scale = 0.65,
		color = Color3.fromRGB(196, 224, 236),
		finColor = Color3.fromRGB(150, 190, 214),
		markColor = Color3.fromRGB(240, 250, 255),
	},
}

Creatures.items.frostfin_char = {
	id = "frostfin_char",
	name = "Frostfin Char",
	rarity = "Common",
	archetype = "rusher",
	health = 250,
	waters = "ice",
	rewards = { coins = { 14, 28 }, xp = 42 },
	drops = { materials = { glacier_shard = { 1, 2 } } },
	body = {
		model = "FishPack",
		species = "FrostfinChar",
		scale = 0.85,
		color = Color3.fromRGB(120, 150, 170),
		finColor = Color3.fromRGB(210, 234, 246),
		markColor = Color3.fromRGB(236, 130, 120),
	},
}

Creatures.items.snowdrift_sculpin = {
	id = "snowdrift_sculpin",
	name = "Snowdrift Sculpin",
	rarity = "Common",
	archetype = "rusher",
	health = 240,
	waters = "ice",
	rewards = { coins = { 14, 28 }, xp = 42 },
	drops = { materials = { rimewool = { 1, 1 }, rime_pelt = { 1, 1 }, glacier_shard = { 1, 1 } } },
	body = {
		model = "FishPack",
		species = "SnowdriftSculpin",
		scale = 0.75,
		color = Color3.fromRGB(168, 174, 186),
		finColor = Color3.fromRGB(120, 126, 142),
		markColor = Color3.fromRGB(228, 234, 244),
	},
}

Creatures.items.rime_herring = {
	id = "rime_herring",
	name = "Rime Herring",
	rarity = "Uncommon",
	archetype = "charger",
	health = 620,
	waters = "ice",
	rewards = { coins = { 42, 70 }, xp = 122 },
	drops = { materials = { rime_pelt = { 1, 2 } } },
	body = {
		model = "FishPack",
		species = "RimeHerring",
		scale = 1.0,
		color = Color3.fromRGB(178, 198, 216),
		finColor = Color3.fromRGB(140, 160, 186),
		markColor = Color3.fromRGB(244, 250, 255),
	},
}

-- Rusher: a shivering little seal-thing that bolts across the ice at you.
Creatures.items.frostbite_pup = {
	id = "frostbite_pup",
	name = "Frostbite Pup",
	rarity = "Uncommon",
	archetype = "rusher",
	health = 580,
	waters = "ice",
	rewards = { coins = { 42, 70 }, xp = 122 },
	drops = { materials = { rimewool = { 1, 1 }, rime_pelt = { 1, 2 } } },
	body = {
		model = "CreaturePack",
		species = "FrostbitePup",
		shape = "crab",
		scale = 1.1,
		color = Color3.fromRGB(214, 224, 234),
		finColor = Color3.fromRGB(170, 186, 202),
		markColor = Color3.fromRGB(90, 140, 190),
	},
}

-- Skythief: a screaming gull that circles the holes - and steals a resting
-- catch clean off the ice if you leave one lying (kill it to get it back).
Creatures.items.hailfin_skua = {
	id = "hailfin_skua",
	name = "Hailfin Skua",
	rarity = "Uncommon",
	archetype = "skythief",
	health = 540,
	waters = "ice",
	rewards = { coins = { 42, 70 }, xp = 122 },
	drops = { materials = { rimewool = { 1, 1 }, rime_pelt = { 1, 2 }, glacier_shard = { 1, 1 } } },
	body = {
		model = "CreaturePack",
		species = "HailfinSkua",
		shape = "ray",
		scale = 1.0,
		color = Color3.fromRGB(200, 208, 220),
		finColor = Color3.fromRGB(146, 156, 172),
		markColor = Color3.fromRGB(60, 70, 84),
	},
}

Creatures.items.iceshard_crab = {
	id = "iceshard_crab",
	name = "Iceshard Crab",
	rarity = "Uncommon",
	archetype = "rusher",
	health = 660,
	waters = "ice",
	rewards = { coins = { 42, 70 }, xp = 122 },
	drops = { materials = { glacier_shard = { 2, 3 } } },
	body = {
		model = "CreaturePack",
		species = "IceshardCrab",
		shape = "crab",
		scale = 1.15,
		color = Color3.fromRGB(150, 196, 224),
		finColor = Color3.fromRGB(200, 234, 250),
		markColor = Color3.fromRGB(96, 140, 176),
	},
}

-- Burrower: tunnels UNDER the ice sheet, bursts up through it.
Creatures.items.glacial_lurker = {
	id = "glacial_lurker",
	name = "Glacial Lurker",
	rarity = "Rare",
	archetype = "burrower",
	health = 1150,
	waters = "ice",
	rewards = { coins = { 122, 192 }, xp = 315 },
	drops = { materials = { everfrost_plate = { 1, 2 }, everice = { 1, 2 } } },
	body = {
		model = "CreaturePack",
		species = "GlacialLurker",
		shape = "lurker",
		scale = 1.3,
		color = Color3.fromRGB(174, 208, 224),
		finColor = Color3.fromRGB(120, 160, 186),
		markColor = Color3.fromRGB(230, 245, 255),
	},
}

-- Shambler: a sailor the reach kept. Walks out of the whiteout at you.
Creatures.items.frozen_mariner = {
	id = "frozen_mariner",
	name = "Frozen Mariner",
	rarity = "Rare",
	archetype = "shambler",
	health = 1250,
	waters = "ice",
	rewards = { coins = { 122, 192 }, xp = 315 },
	drops = { materials = { everfrost_plate = { 1, 2 }, everice = { 1, 2 }, rime_pelt = { 1, 2 } } },
	body = {
		model = "CreaturePack",
		species = "FrozenMariner",
		shape = "zombie",
		stance = "upright",
		scale = 1.1,
		color = Color3.fromRGB(160, 180, 196),
		finColor = Color3.fromRGB(104, 124, 144),
		markColor = Color3.fromRGB(210, 236, 250),
	},
}

-- Drifter: hovers off the holes glowing with the aurora, stings on contact.
Creatures.items.aurora_jelly = {
	id = "aurora_jelly",
	name = "Aurora Jelly",
	rarity = "Rare",
	archetype = "drifter",
	health = 1050,
	waters = "ice",
	rewards = { coins = { 122, 192 }, xp = 315 },
	drops = { materials = { aurora_essence = { 1, 1 }, everice = { 1, 1 } } },
	body = {
		model = "CreaturePack",
		species = "AuroraJelly",
		shape = "jelly",
		stance = "upright",
		scale = 1.2,
		color = Color3.fromRGB(150, 230, 200),
		finColor = Color3.fromRGB(140, 170, 250),
		markColor = Color3.fromRGB(230, 150, 230),
	},
}

-- Charger: a spear of a fish that dashes clean past you across the ice.
Creatures.items.icevein_pike = {
	id = "icevein_pike",
	name = "Icevein Pike",
	rarity = "Epic",
	archetype = "charger",
	health = 1900,
	waters = "ice",
	rewards = { coins = { 315, 490 }, xp = 770 },
	drops = { materials = { everfrost_plate = { 1, 3 }, aurora_essence = { 1, 2 } } },
	body = {
		model = "CreaturePack",
		species = "IceveinPike",
		shape = "skipper",
		scale = 1.5,
		color = Color3.fromRGB(140, 180, 204),
		finColor = Color3.fromRGB(200, 230, 246),
		markColor = Color3.fromRGB(80, 200, 255),
	},
}

-- Gascloud: a blizzard given a grudge; trails a freezing whiteout.
Creatures.items.blizzard_wraith = {
	id = "blizzard_wraith",
	name = "Blizzard Wraith",
	rarity = "Epic",
	archetype = "gascloud",
	health = 1750,
	waters = "ice",
	rewards = { coins = { 315, 490 }, xp = 770 },
	drops = { materials = { aurora_essence = { 1, 2 }, everice = { 1, 2 } } },
	body = {
		model = "CreaturePack",
		species = "BlizzardWraith",
		shape = "zombie",
		stance = "upright",
		scale = 1.25,
		color = Color3.fromRGB(224, 236, 248),
		finColor = Color3.fromRGB(170, 196, 220),
		markColor = Color3.fromRGB(120, 200, 255),
	},
}

-- The Legendary chase fish: seen once a season, sworn about forever.
Creatures.items.aurorafin_marlin = {
	id = "aurorafin_marlin",
	name = "Aurorafin Marlin",
	rarity = "Legendary",
	archetype = "charger",
	health = 3200,
	waters = "ice",
	rewards = { coins = { 875, 1400 }, xp = 2100 },
	drops = { materials = { aurora_essence = { 2, 3 }, pearl = { 1, 2 } } },
	body = {
		model = "FishPack",
		species = "AurorafinMarlin",
		scale = 1.9,
		color = Color3.fromRGB(96, 140, 190),
		finColor = Color3.fromRGB(150, 230, 200),
		markColor = Color3.fromRGB(230, 150, 230),
	},
}

-- The boss. Rises out of the big fishing hole; dives back UNDER the sheet
-- and bursts up through it - the island's own ice holes turned against you.
Creatures.items.rimefang = {
	id = "rimefang",
	name = "Rimefang, the Glacier Serpent",
	rarity = "Boss",
	archetype = "boss",
	boss = "rimefang",
	health = 26000,
	waters = "ice",
	rewards = { coins = { 4200, 6000 }, xp = 6500 },
	drops = { materials = { aurora_essence = { 3, 4 }, everice = { 4, 6 }, glacier_shard = { 6, 8 } } },
	body = {
		model = "CreaturePack",
		species = "Rimefang",
		shape = "leviathan",
		stance = "upright",
		scale = 1.6,
		color = Color3.fromRGB(190, 220, 240),
		finColor = Color3.fromRGB(120, 170, 210),
		markColor = Color3.fromRGB(80, 220, 255), -- ice-light lure and gills
	},
}

-- ============================================================ Gloomtrench
-- The abyss (island 5, L29-35). Perpetual dark; casts land in the black
-- water (Gloomtrench_DarkWater -> waters "gloom"). Rewards x10 baseline.

Creatures.items.pale_dace = {
	id = "pale_dace",
	name = "Pale Dace",
	rarity = "Common",
	archetype = "charger",
	health = 780,
	waters = "gloom",
	rewards = { coins = { 40, 80 }, xp = 120 },
	drops = { materials = { gloom_scale = { 1, 2 } } },
	body = {
		model = "FishPack",
		species = "PaleDace",
		scale = 0.75,
		color = Color3.fromRGB(216, 214, 224),
		finColor = Color3.fromRGB(170, 168, 184),
		markColor = Color3.fromRGB(140, 140, 158),
	},
}

Creatures.items.blindcave_sardine = {
	id = "blindcave_sardine",
	name = "Blindcave Sardine",
	rarity = "Common",
	archetype = "rusher",
	health = 720,
	waters = "gloom",
	rewards = { coins = { 40, 80 }, xp = 120 },
	drops = { materials = { gloom_scale = { 1, 2 } } },
	body = {
		model = "FishPack",
		species = "BlindcaveSardine",
		scale = 0.6,
		color = Color3.fromRGB(232, 226, 218),
		finColor = Color3.fromRGB(190, 182, 176),
		markColor = Color3.fromRGB(255, 246, 236),
	},
}

Creatures.items.sootgill_hagfish = {
	id = "sootgill_hagfish",
	name = "Sootgill Hagfish",
	rarity = "Common",
	archetype = "spitter",
	health = 850,
	waters = "gloom",
	rewards = { coins = { 40, 80 }, xp = 120 },
	drops = { materials = { gloom_scale = { 1, 1 }, trench_chitin = { 1, 1 } } },
	body = {
		model = "FishPack",
		species = "SootgillHagfish",
		scale = 0.9,
		color = Color3.fromRGB(70, 66, 78),
		finColor = Color3.fromRGB(50, 46, 58),
		markColor = Color3.fromRGB(120, 110, 130),
	},
}

-- Spitter: a gullet with a tail. Lobs bile from the dark.
Creatures.items.gulper_eel = {
	id = "gulper_eel",
	name = "Gulper Eel",
	rarity = "Uncommon",
	archetype = "spitter",
	health = 2000,
	waters = "gloom",
	rewards = { coins = { 120, 200 }, xp = 350 },
	drops = { materials = { duskhide = { 1, 1 }, gloom_scale = { 2, 3 } } },
	body = {
		model = "CreaturePack",
		species = "GulperEel",
		shape = "gulletcod",
		scale = 1.4,
		color = Color3.fromRGB(48, 44, 60),
		finColor = Color3.fromRGB(70, 62, 86),
		markColor = Color3.fromRGB(140, 220, 255),
	},
}

-- Drifter: hovers dark, then pops a blinding flash on contact.
Creatures.items.flashbulb_squid = {
	id = "flashbulb_squid",
	name = "Flashbulb Squid",
	rarity = "Uncommon",
	archetype = "drifter",
	health = 1850,
	waters = "gloom",
	rewards = { coins = { 120, 200 }, xp = 350 },
	drops = { materials = { abyss_silk = { 1, 1 }, lantern_gland = { 1, 1 }, gloom_scale = { 1, 2 } } },
	body = {
		model = "CreaturePack",
		species = "FlashbulbSquid",
		shape = "jelly",
		stance = "upright",
		scale = 1.15,
		color = Color3.fromRGB(90, 70, 110),
		finColor = Color3.fromRGB(130, 100, 160),
		markColor = Color3.fromRGB(255, 240, 180),
	},
}

-- Charger: all legs and hunger, skitters at you along the trench floor.
Creatures.items.trench_skitterer = {
	id = "trench_skitterer",
	name = "Trench Skitterer",
	rarity = "Uncommon",
	archetype = "charger",
	health = 2200,
	waters = "gloom",
	rewards = { coins = { 120, 200 }, xp = 350 },
	drops = { materials = { trench_chitin = { 2, 3 } } },
	body = {
		model = "CreaturePack",
		species = "TrenchSkitterer",
		shape = "crab",
		scale = 1.2,
		color = Color3.fromRGB(70, 78, 92),
		finColor = Color3.fromRGB(100, 110, 128),
		markColor = Color3.fromRGB(150, 220, 240),
	},
}

-- Mimic: a warm hanging light in the perpetual dark. It is not a lantern.
Creatures.items.lanternjaw_angler = {
	id = "lanternjaw_angler",
	name = "Lanternjaw Angler",
	rarity = "Rare",
	archetype = "mimic",
	health = 3400,
	waters = "gloom",
	rewards = { coins = { 350, 550 }, xp = 900 },
	drops = { materials = { abyss_silk = { 1, 2 }, lantern_gland = { 1, 2 } } },
	body = {
		model = "CreaturePack",
		species = "LanternjawAngler",
		shape = "mimic",
		stance = "upright",
		scale = 1.3,
		color = Color3.fromRGB(60, 54, 72),
		finColor = Color3.fromRGB(90, 80, 104),
		markColor = Color3.fromRGB(255, 226, 130), -- the lure - the only warmth down here
	},
}

-- Thief: wraps the catch of your coins in webbed arms and jets off.
Creatures.items.vampire_squid = {
	id = "vampire_squid",
	name = "Vampire Squid",
	rarity = "Rare",
	archetype = "thief",
	health = 3100,
	waters = "gloom",
	rewards = { coins = { 350, 550 }, xp = 900 },
	drops = { materials = { duskhide = { 1, 2 }, lantern_gland = { 1, 2 }, gloom_scale = { 2, 3 } } },
	body = {
		model = "CreaturePack",
		species = "VampireSquid",
		shape = "hermit",
		scale = 1.2,
		color = Color3.fromRGB(120, 40, 60),
		finColor = Color3.fromRGB(80, 26, 44),
		markColor = Color3.fromRGB(255, 120, 120),
	},
}

-- Thornback: armoured for the crush of the deep. Soft only from behind.
Creatures.items.pressure_crab = {
	id = "pressure_crab",
	name = "Pressure Crab",
	rarity = "Rare",
	archetype = "thornback",
	health = 3800,
	waters = "gloom",
	rewards = { coins = { 350, 550 }, xp = 900 },
	drops = { materials = { trench_chitin = { 2, 4 } } },
	body = {
		model = "CreaturePack",
		species = "PressureCrab",
		shape = "crab",
		scale = 1.35,
		color = Color3.fromRGB(90, 86, 100),
		finColor = Color3.fromRGB(130, 124, 142),
		markColor = Color3.fromRGB(200, 190, 220),
	},
}

-- Pulser: a silent wing of the abyss that charges and detonates the dark.
Creatures.items.void_ray = {
	id = "void_ray",
	name = "Void Ray",
	rarity = "Epic",
	archetype = "pulser",
	health = 4200,
	waters = "gloom",
	rewards = { coins = { 900, 1400 }, xp = 2200 },
	drops = { materials = { abyss_silk = { 1, 2 }, abyss_ichor = { 1, 2 } } },
	body = {
		model = "CreaturePack",
		species = "VoidRay",
		shape = "ray",
		scale = 1.6,
		color = Color3.fromRGB(40, 36, 56),
		finColor = Color3.fromRGB(66, 58, 90),
		markColor = Color3.fromRGB(170, 120, 255),
	},
}

-- Burrower: the silt itself stands up and takes you.
Creatures.items.silt_stalker = {
	id = "silt_stalker",
	name = "Silt Stalker",
	rarity = "Epic",
	archetype = "burrower",
	health = 4500,
	waters = "gloom",
	rewards = { coins = { 900, 1400 }, xp = 2200 },
	drops = { materials = { duskhide = { 1, 3 }, abyss_ichor = { 1, 2 }, trench_chitin = { 2, 3 } } },
	body = {
		model = "CreaturePack",
		species = "SiltStalker",
		shape = "lurker",
		scale = 1.5,
		color = Color3.fromRGB(66, 60, 54),
		finColor = Color3.fromRGB(90, 82, 72),
		markColor = Color3.fromRGB(140, 128, 110),
	},
}

-- The Legendary chase: a ribbon of pale light that shouldn't be down here.
Creatures.items.ghostlight_oarfish = {
	id = "ghostlight_oarfish",
	name = "Ghostlight Oarfish",
	rarity = "Legendary",
	archetype = "pulser",
	health = 8000,
	waters = "gloom",
	rewards = { coins = { 2500, 4000 }, xp = 6000 },
	drops = { materials = { abyss_ichor = { 2, 3 }, lantern_gland = { 2, 3 } } },
	body = {
		model = "FishPack",
		species = "GhostlightOarfish",
		scale = 2.2,
		color = Color3.fromRGB(224, 228, 240),
		finColor = Color3.fromRGB(255, 120, 120),
		markColor = Color3.fromRGB(180, 240, 255),
	},
}

-- ONE OF THE SEVEN. The Lantern Choir is Noctyss's fingers through the
-- Choirfloor's ceiling, and each stalk is an ordinary creature row planted on
-- the arena's socket ring (Bosses.noctyss `parts`) - so it has its own health
-- bar, takes ordinary damage, and dies like anything else.
--
-- `rangedOnly` is the design, not a limitation: the lantern hangs 35 studs up
-- at the end of a crooked stalk, and nothing in the melee arsenal reaches it.
-- Guns break the lure, and then melee burns the gullet inside her mouth - the
-- two halves of the kit matter in different beats of the same fight.
--
-- The client draws these as chains from NoctyssPack (NoctyssBodyController);
-- the model the server keeps is authority only and stands at the BULB, which
-- is why shooting the light is what registers.
Creatures.items.choir_stalk = {
	id = "choir_stalk",
	name = "Lantern Stalk",
	rarity = "Boss",
	archetype = "choirstalk",
	health = 2600,
	waters = "gloom",
	rangedOnly = true,
	rewards = { coins = { 70, 120 }, xp = 200 },
	body = {
		model = "CreaturePack",
		species = "Noctyss",
		shape = "leviathan",
		stance = "upright",
		scale = 0.55,
		color = Color3.fromRGB(44, 38, 58),
		finColor = Color3.fromRGB(70, 58, 92),
		markColor = Color3.fromRGB(255, 226, 130), -- the lantern
	},
}

-- The boss. She is UNDER the shelf for most of the fight: `vulnerableWhen`
-- keeps her untouchable until the true lure is broken and the maw comes up
-- through the pit, which is the only window anything can hurt her in.
Creatures.items.noctyss = {
	id = "noctyss",
	name = "Noctyss, the Trench Mother",
	rarity = "Boss",
	archetype = "boss",
	boss = "noctyss",
	health = 60000,
	waters = "gloom",
	vulnerableWhen = "markedDown",
	rewards = { coins = { 18000, 26000 }, xp = 16000 },
	drops = { materials = { abyss_ichor = { 3, 4 }, lantern_gland = { 4, 6 }, trench_chitin = { 6, 8 } } },
	body = {
		model = "CreaturePack",
		species = "Noctyss",
		shape = "leviathan",
		stance = "upright",
		-- 2.4, not 1.8: at 1.8 the maw was a crocodile in a hole. Here the
		-- skull is 28.8 studs across against the arena pit's 30-stud mouth -
		-- she FILLS it, jaws overhanging the lip, without clipping the rim
		-- (measured in assets/boss_noctyss_staged.png). hitRadius 6 then
		-- reads as 14.4 studs of hide, which is what the eye sees.
		scale = 2.4,
		color = Color3.fromRGB(44, 38, 58),
		finColor = Color3.fromRGB(70, 58, 92),
		markColor = Color3.fromRGB(255, 226, 130), -- the lure
	},
}

-- ============================================================ Wreckwater
-- The ghost-fleet graveyard (island 6, L36-42). Casts land in the bay water
-- threading the wrecks (Wreckwater_Bay -> waters "wreck"). Rewards x16.

Creatures.items.wreck_herring = {
	id = "wreck_herring",
	name = "Wreck Herring",
	rarity = "Common",
	archetype = "charger",
	health = 1250,
	waters = "wreck",
	rewards = { coins = { 64, 128 }, xp = 192 },
	drops = { materials = { ghost_plank = { 1, 2 } } },
	body = {
		model = "FishPack",
		species = "WreckHerring",
		scale = 0.8,
		color = Color3.fromRGB(150, 168, 160),
		finColor = Color3.fromRGB(110, 128, 122),
		markColor = Color3.fromRGB(200, 220, 210),
	},
}

Creatures.items.rustscale_snapper = {
	id = "rustscale_snapper",
	name = "Rustscale Snapper",
	rarity = "Common",
	archetype = "rusher",
	health = 1350,
	waters = "wreck",
	rewards = { coins = { 64, 128 }, xp = 192 },
	drops = { materials = { tarnished_doubloon = { 1, 1 }, ghost_plank = { 1, 1 } } },
	body = {
		model = "FishPack",
		species = "RustscaleSnapper",
		scale = 0.95,
		color = Color3.fromRGB(164, 106, 72),
		finColor = Color3.fromRGB(120, 74, 52),
		markColor = Color3.fromRGB(220, 160, 90),
	},
}

Creatures.items.barnacle_blenny = {
	id = "barnacle_blenny",
	name = "Barnacle Blenny",
	rarity = "Common",
	archetype = "rusher",
	health = 1300,
	waters = "wreck",
	rewards = { coins = { 64, 128 }, xp = 192 },
	drops = { materials = { ghost_plank = { 1, 2 } } },
	body = {
		model = "FishPack",
		species = "BarnacleBlenny",
		scale = 0.7,
		color = Color3.fromRGB(120, 130, 110),
		finColor = Color3.fromRGB(90, 100, 84),
		markColor = Color3.fromRGB(190, 196, 180),
	},
}

Creatures.items.ghost_carp = {
	id = "ghost_carp",
	name = "Ghost Carp",
	rarity = "Uncommon",
	archetype = "drifter",
	health = 3300,
	waters = "wreck",
	rewards = { coins = { 192, 320 }, xp = 560 },
	drops = { materials = { ghost_plank = { 2, 3 } } },
	body = {
		model = "FishPack",
		species = "GhostCarp",
		scale = 1.2,
		color = Color3.fromRGB(210, 224, 218),
		finColor = Color3.fromRGB(160, 180, 172),
		markColor = Color3.fromRGB(140, 220, 190),
	},
}

-- Flyer: a knot of rope and grave-cold air off the rigging, dive-bombs.
Creatures.items.rigging_wraith = {
	id = "rigging_wraith",
	name = "Rigging Wraith",
	rarity = "Uncommon",
	archetype = "flyer",
	health = 3000,
	waters = "wreck",
	rewards = { coins = { 192, 320 }, xp = 560 },
	drops = { materials = { spectral_sailcloth = { 1, 1 }, ghost_plank = { 1, 2 } } },
	body = {
		model = "CreaturePack",
		species = "RiggingWraith",
		shape = "ray",
		scale = 1.15,
		color = Color3.fromRGB(150, 190, 170),
		finColor = Color3.fromRGB(110, 150, 134),
		markColor = Color3.fromRGB(220, 250, 236),
	},
}

-- Rusher: an iron ball with legs and a temper.
Creatures.items.cannonball_crab = {
	id = "cannonball_crab",
	name = "Cannonball Crab",
	rarity = "Uncommon",
	archetype = "rusher",
	health = 3600,
	waters = "wreck",
	rewards = { coins = { 192, 320 }, xp = 560 },
	drops = { materials = { tarnished_doubloon = { 2, 3 } } },
	body = {
		model = "CreaturePack",
		species = "CannonballCrab",
		shape = "crab",
		scale = 1.25,
		color = Color3.fromRGB(60, 62, 68),
		finColor = Color3.fromRGB(90, 92, 100),
		markColor = Color3.fromRGB(180, 140, 80),
	},
}

-- Shambler: still keeping his watch, hauling a fouled anchor line.
Creatures.items.drowned_boatswain = {
	id = "drowned_boatswain",
	name = "Drowned Boatswain",
	rarity = "Rare",
	archetype = "shambler",
	health = 4600,
	waters = "wreck",
	rewards = { coins = { 560, 880 }, xp = 1440 },
	drops = { materials = { spectral_sailcloth = { 1, 2 }, tarnished_doubloon = { 2, 3 } } },
	body = {
		model = "CreaturePack",
		species = "DrownedBoatswain",
		shape = "zombie",
		stance = "upright",
		scale = 1.15,
		color = Color3.fromRGB(110, 130, 122),
		finColor = Color3.fromRGB(80, 96, 90),
		markColor = Color3.fromRGB(190, 214, 200),
	},
}

-- Charger: a moray the length of a longboat, all lunge.
Creatures.items.phantom_moray = {
	id = "phantom_moray",
	name = "Phantom Moray",
	rarity = "Rare",
	archetype = "charger",
	health = 4400,
	waters = "wreck",
	rewards = { coins = { 560, 880 }, xp = 1440 },
	drops = { materials = { spectral_sailcloth = { 1, 2 } } },
	body = {
		model = "CreaturePack",
		species = "PhantomMoray",
		shape = "skipper",
		scale = 1.6,
		color = Color3.fromRGB(140, 164, 158),
		finColor = Color3.fromRGB(100, 122, 118),
		markColor = Color3.fromRGB(200, 240, 224),
	},
}

-- Mimic: sits on the seabed looking exactly like salvage. It is not salvage.
Creatures.items.cursed_chest = {
	id = "cursed_chest",
	name = "Cursed Chest",
	rarity = "Rare",
	archetype = "mimic",
	health = 5000,
	waters = "wreck",
	rewards = { coins = { 560, 880 }, xp = 1440 },
	drops = { materials = { tarnished_doubloon = { 3, 5 } } },
	body = {
		model = "CreaturePack",
		species = "CursedChest",
		shape = "mimic",
		stance = "upright",
		scale = 1.3,
		color = Color3.fromRGB(104, 78, 50),
		finColor = Color3.fromRGB(140, 108, 70),
		markColor = Color3.fromRGB(230, 190, 100), -- the gold spilling out of the lid
	},
}

-- Thief: a cackling scrap of ghost-light that pockets your coins.
Creatures.items.plunder_sprite = {
	id = "plunder_sprite",
	name = "Plunder Sprite",
	rarity = "Rare",
	archetype = "thief",
	health = 4200,
	waters = "wreck",
	rewards = { coins = { 560, 880 }, xp = 1440 },
	drops = { materials = { tarnished_doubloon = { 3, 5 }, spectral_sailcloth = { 1, 1 } } },
	body = {
		model = "CreaturePack",
		species = "PlunderSprite",
		shape = "hermit",
		scale = 1.0,
		color = Color3.fromRGB(170, 220, 190),
		finColor = Color3.fromRGB(120, 170, 146),
		markColor = Color3.fromRGB(240, 210, 120),
	},
}

-- Gascloud: burning ghost-fire off a powder wreck that never went out.
Creatures.items.ghostfire_jelly = {
	id = "ghostfire_jelly",
	name = "Ghostfire Jelly",
	rarity = "Epic",
	archetype = "gascloud",
	health = 6000,
	waters = "wreck",
	rewards = { coins = { 1440, 2240 }, xp = 3520 },
	drops = { materials = { wraith_essence = { 1, 2 } } },
	body = {
		model = "CreaturePack",
		species = "GhostfireJelly",
		shape = "jelly",
		stance = "upright",
		scale = 1.4,
		color = Color3.fromRGB(120, 200, 170),
		finColor = Color3.fromRGB(90, 160, 136),
		markColor = Color3.fromRGB(160, 255, 210),
	},
}

-- Spitter: a gunner fused to his carronade, still firing spectral grapeshot.
Creatures.items.wailing_gunner = {
	id = "wailing_gunner",
	name = "Wailing Gunner",
	rarity = "Epic",
	archetype = "spitter",
	health = 6500,
	waters = "wreck",
	rewards = { coins = { 1440, 2240 }, xp = 3520 },
	drops = { materials = { wraith_essence = { 1, 2 }, tarnished_doubloon = { 3, 4 } } },
	body = {
		model = "CreaturePack",
		species = "WailingGunner",
		shape = "zombie",
		stance = "upright",
		scale = 1.3,
		color = Color3.fromRGB(120, 140, 132),
		finColor = Color3.fromRGB(86, 102, 96),
		markColor = Color3.fromRGB(200, 240, 220),
	},
}

-- The Legendary chase: a sail of light running before a wind nobody feels.
Creatures.items.spectral_sailfish = {
	id = "spectral_sailfish",
	name = "Spectral Sailfish",
	rarity = "Legendary",
	archetype = "charger",
	health = 11000,
	waters = "wreck",
	rewards = { coins = { 4000, 6400 }, xp = 9600 },
	drops = { materials = { wraith_essence = { 2, 3 }, spectral_sailcloth = { 2, 3 } } },
	body = {
		model = "FishPack",
		species = "SpectralSailfish",
		scale = 2.1,
		color = Color3.fromRGB(190, 226, 210),
		finColor = Color3.fromRGB(150, 255, 210),
		markColor = Color3.fromRGB(240, 255, 248),
	},
}

-- The boss. The drowned admiral fused into his flagship's bow; his brood is
-- a boarding party - the island's raid mechanic pointed back at you.
Creatures.items.admiral_wrack = {
	id = "admiral_wrack",
	name = "Admiral Wrack, the Fleet-Eater",
	rarity = "Boss",
	archetype = "boss",
	boss = "admiral_wrack",
	health = 85000,
	waters = "wreck",
	rewards = { coins = { 40000, 55000 }, xp = 30000 },
	drops = { materials = { wraith_essence = { 3, 4 }, spectral_sailcloth = { 5, 7 }, tarnished_doubloon = { 8, 12 } } },
	body = {
		model = "CreaturePack",
		species = "AdmiralWrack",
		shape = "leviathan",
		stance = "upright",
		scale = 2.0,
		color = Color3.fromRGB(96, 116, 108),
		finColor = Color3.fromRGB(70, 86, 82),
		markColor = Color3.fromRGB(160, 255, 210), -- the ghost-fire riding the bow
	},
}

-- ============================================================ Creatures (13 + tentacle + boss)

Creatures.items.squall_sprat = {
	id = "squall_sprat",
	name = "Squall Sprat",
	rarity = "Common",
	archetype = "rusher",
	health = 1900,
	waters = "maelstrom",
	rewards = { coins = { 100, 200 }, xp = 300 },
	drops = { materials = { storm_glass = { 1, 2 } } },
	body = {
		model = "FishPack",
		species = "SquallSprat",
		scale = 0.65,
		color = Color3.fromRGB(150, 176, 196),
		finColor = Color3.fromRGB(110, 134, 156),
		markColor = Color3.fromRGB(220, 235, 246),
	},
}

Creatures.items.rainfin_mackerel = {
	id = "rainfin_mackerel",
	name = "Rainfin Mackerel",
	rarity = "Common",
	archetype = "charger",
	health = 2000,
	waters = "maelstrom",
	rewards = { coins = { 100, 200 }, xp = 300 },
	drops = { materials = { storm_glass = { 1, 2 } } },
	body = {
		model = "FishPack",
		species = "RainfinMackerel",
		scale = 0.85,
		color = Color3.fromRGB(96, 130, 160),
		finColor = Color3.fromRGB(160, 200, 230),
		markColor = Color3.fromRGB(50, 70, 96),
	},
}

Creatures.items.foamchaser_mullet = {
	id = "foamchaser_mullet",
	name = "Foamchaser Mullet",
	rarity = "Common",
	archetype = "rusher",
	health = 2100,
	waters = "maelstrom",
	rewards = { coins = { 100, 200 }, xp = 300 },
	drops = { materials = { riptide_scale = { 1, 2 } } },
	body = {
		model = "FishPack",
		species = "FoamchaserMullet",
		scale = 0.8,
		color = Color3.fromRGB(176, 190, 198),
		finColor = Color3.fromRGB(220, 232, 238),
		markColor = Color3.fromRGB(130, 146, 158),
	},
}

Creatures.items.stormpetrel = {
	id = "stormpetrel",
	name = "Stormpetrel",
	rarity = "Uncommon",
	archetype = "flyer",
	health = 4600,
	waters = "maelstrom",
	rewards = { coins = { 300, 500 }, xp = 875 },
	drops = { materials = { storm_glass = { 2, 3 } } },
	body = {
		model = "CreaturePack",
		species = "Stormpetrel",
		shape = "ray",
		scale = 1.0,
		color = Color3.fromRGB(70, 76, 92),
		finColor = Color3.fromRGB(110, 118, 138),
		markColor = Color3.fromRGB(220, 230, 246),
	},
}

Creatures.items.galestreak_flyingfish = {
	id = "galestreak_flyingfish",
	name = "Galestreak Flyingfish",
	rarity = "Uncommon",
	archetype = "flyer",
	health = 4400,
	waters = "maelstrom",
	rewards = { coins = { 300, 500 }, xp = 875 },
	drops = { materials = { riptide_scale = { 2, 3 } } },
	body = {
		model = "CreaturePack",
		species = "GalestreakFlyingfish",
		shape = "ray",
		scale = 1.05,
		color = Color3.fromRGB(110, 160, 200),
		finColor = Color3.fromRGB(190, 220, 244),
		markColor = Color3.fromRGB(240, 250, 255),
	},
}

Creatures.items.riptide_barracuda = {
	id = "riptide_barracuda",
	name = "Riptide Barracuda",
	rarity = "Uncommon",
	archetype = "charger",
	health = 4400,
	waters = "maelstrom",
	rewards = { coins = { 300, 500 }, xp = 875 },
	drops = { materials = { riptide_scale = { 2, 3 } } },
	body = {
		model = "CreaturePack",
		species = "RiptideBarracuda",
		shape = "skipper",
		scale = 1.5,
		color = Color3.fromRGB(120, 150, 176),
		finColor = Color3.fromRGB(90, 116, 140),
		markColor = Color3.fromRGB(50, 66, 84),
	},
}

Creatures.items.cyclone_ray = {
	id = "cyclone_ray",
	name = "Cyclone Ray",
	rarity = "Rare",
	archetype = "pulser",
	health = 6400,
	waters = "maelstrom",
	rewards = { coins = { 875, 1375 }, xp = 2250 },
	drops = { materials = { thunder_pearl = { 1, 2 } } },
	body = {
		model = "CreaturePack",
		species = "CycloneRay",
		shape = "ray",
		scale = 1.6,
		color = Color3.fromRGB(80, 100, 140),
		finColor = Color3.fromRGB(120, 146, 190),
		markColor = Color3.fromRGB(140, 200, 255),
	},
}

Creatures.items.whirlpool_horror = {
	id = "whirlpool_horror",
	name = "Whirlpool Horror",
	rarity = "Rare",
	archetype = "burrower",
	health = 6600,
	waters = "maelstrom",
	rewards = { coins = { 875, 1375 }, xp = 2250 },
	drops = { materials = { thunder_pearl = { 1, 2 }, riptide_scale = { 2, 3 } } },
	body = {
		model = "CreaturePack",
		species = "WhirlpoolHorror",
		shape = "lurker",
		scale = 1.5,
		color = Color3.fromRGB(60, 80, 110),
		finColor = Color3.fromRGB(90, 116, 150),
		markColor = Color3.fromRGB(170, 210, 250),
	},
}

Creatures.items.tempest_revenant = {
	id = "tempest_revenant",
	name = "Tempest Revenant",
	rarity = "Rare",
	archetype = "shambler",
	health = 6200,
	waters = "maelstrom",
	rewards = { coins = { 875, 1375 }, xp = 2250 },
	drops = { materials = { thunder_pearl = { 1, 2 }, storm_glass = { 2, 3 } } },
	body = {
		model = "CreaturePack",
		species = "TempestRevenant",
		shape = "zombie",
		stance = "upright",
		scale = 1.2,
		color = Color3.fromRGB(100, 116, 140),
		finColor = Color3.fromRGB(70, 84, 106),
		markColor = Color3.fromRGB(180, 220, 255),
	},
}

Creatures.items.thunderlance_marlin = {
	id = "thunderlance_marlin",
	name = "Thunderlance Marlin",
	rarity = "Epic",
	archetype = "charger",
	health = 9500,
	waters = "maelstrom",
	rewards = { coins = { 2250, 3500 }, xp = 5500 },
	drops = { materials = { maelstrom_core = { 1, 2 } } },
	body = {
		model = "CreaturePack",
		species = "ThunderlanceMarlin",
		shape = "skipper",
		scale = 1.9,
		color = Color3.fromRGB(70, 110, 170),
		finColor = Color3.fromRGB(120, 170, 230),
		markColor = Color3.fromRGB(255, 240, 150),
	},
}

Creatures.items.stormcaller_djinn = {
	id = "stormcaller_djinn",
	name = "Stormcaller Djinn",
	rarity = "Epic",
	archetype = "gascloud",
	health = 9000,
	waters = "maelstrom",
	rewards = { coins = { 2250, 3500 }, xp = 5500 },
	drops = { materials = { maelstrom_core = { 1, 2 }, thunder_pearl = { 1, 2 } } },
	body = {
		model = "CreaturePack",
		species = "StormcallerDjinn",
		shape = "zombie",
		stance = "upright",
		scale = 1.35,
		color = Color3.fromRGB(90, 110, 150),
		finColor = Color3.fromRGB(130, 156, 200),
		markColor = Color3.fromRGB(255, 250, 200),
	},
}

Creatures.items.kraken_spawn = {
	id = "kraken_spawn",
	name = "Kraken Spawn",
	rarity = "Epic",
	archetype = "splitter",
	health = 8500,
	waters = "maelstrom",
	rewards = { coins = { 2250, 3500 }, xp = 5500 },
	drops = { materials = { maelstrom_core = { 1, 2 } } },
	body = {
		model = "CreaturePack",
		species = "KrakenSpawn",
		shape = "urchin",
		scale = 1.3,
		color = Color3.fromRGB(70, 60, 100),
		finColor = Color3.fromRGB(100, 86, 140),
		markColor = Color3.fromRGB(150, 120, 255),
	},
}

Creatures.items.stormking_tuna = {
	id = "stormking_tuna",
	name = "The Stormking Tuna",
	rarity = "Legendary",
	archetype = "charger",
	health = 16000,
	waters = "maelstrom",
	rewards = { coins = { 6250, 10000 }, xp = 15000 },
	drops = { materials = { maelstrom_core = { 2, 3 }, thunder_pearl = { 2, 3 } } },
	body = {
		model = "FishPack",
		species = "StormkingTuna",
		scale = 2.3,
		color = Color3.fromRGB(60, 90, 140),
		finColor = Color3.fromRGB(255, 240, 150),
		markColor = Color3.fromRGB(140, 200, 255),
	},
}

-- The Kraken's arms: planted AoE attackers ringing the arena. Spawned by
-- the Bosses entry's `parts` block, never by a cast (rarity "Boss") -
-- noLinger, modest bounty (they respawn; they must not out-earn fishing).
Creatures.items.kraken_tentacle = {
	id = "kraken_tentacle",
	name = "Kraken Tentacle",
	rarity = "Boss",
	archetype = "tentacle",
	health = 6000,
	waters = "maelstrom",
	rewards = { coins = { 150, 250 }, xp = 400 },
	-- Also authority only: KrakenBodyController hides each tentacle and draws
	-- an ARM to it from the head's crown, so what you swing at is the arm.
	-- The colours are the fallback for a client that has not adopted the boss
	-- yet, and match the hide.
	body = {
		model = "CreaturePack",
		species = "KrakenTentacle",
		shape = "gulletcod",
		stance = "upright",
		scale = 1.8,
		color = Color3.fromRGB(33, 20, 51),
		finColor = Color3.fromRGB(51, 33, 77),
		markColor = Color3.fromRGB(150, 120, 255),
	},
}

-- The final boss. rangedOnly: melee target-picking skips the head entirely
-- (the tentacles are the melee fight); vulnerableWhen = "partsDown": the
-- head takes damage only in the window after every tentacle is dead, until
-- they regrow. Killing it sets Heart_kraken and the finale banner - there
-- is no next island to unlock.
Creatures.items.kraken = {
	id = "kraken",
	name = "The Kraken, Maw of the Maelstrom",
	rarity = "Boss",
	archetype = "boss",
	boss = "kraken",
	health = 130000,
	waters = "maelstrom",
	rangedOnly = true,
	vulnerableWhen = "partsDown",
	rewards = { coins = { 90000, 120000 }, xp = 80000 },
	drops = { materials = { maelstrom_core = { 4, 6 }, thunder_pearl = { 6, 8 }, storm_glass = { 8, 12 } } },
	-- Authority only: this model is hidden the moment it rises
	-- (CreatureService.hideColossusModel) and KrakenBodyController draws the
	-- octopus instead. `scale` still matters - it is what hitRadius is
	-- multiplied by - so it tracks KrakenPath.SCALE exactly, or the hide you
	-- can hit stops matching the hide you can see.
	body = {
		model = "CreaturePack",
		species = "Kraken",
		shape = "leviathan",
		stance = "upright",
		scale = 1.4, -- = KrakenPath.SCALE
		color = Color3.fromRGB(33, 20, 51), -- deep dark purple, the octopus hide
		finColor = Color3.fromRGB(51, 33, 77), -- the lighter underside and arm crown
		markColor = Color3.fromRGB(150, 120, 255), -- storm-lit eyes and suckers
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
