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
	-- 9000 -> 4400 (2026-09-06 rebalance). The old number was priced against a
	-- fight in which the boss was invulnerable outside an earned window, and a
	-- trace of it found 40 minutes solo at 5% uptime. The rebuild puts a chip
	-- floor under it (Bosses.items.brinejaw.chip = 0.25), so the SAME weapon
	-- now does real damage for the whole fight and the health bar has to come
	-- down to match. Simulated over 60 runs per tier at DPS 71/80/89: an
	-- engaged solo player (baits, punishes lunges, breaks polyps) lands at
	-- 8.5/7.5/6.6 minutes, and one who never baits and ignores the polyps at
	-- 13.6/11.8/10.7. Move this number and re-run that sim before shipping -
	-- everything about the fight's pace is priced off it.
	health = 4400,
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

-- Brinejaw's heal, made killable. `polyps` (Bosses.luau) grows three of these
-- on the arena's cover stones; every one still alive at the deadline detonates
-- and feeds its share of the serpent's health back. So this row is not an
-- enemy in the ordinary sense - it is a TIMER with hit points, and its health
-- is the whole difficulty of the mechanic: 260 is about three seconds of one
-- player's attention each, which is three of the twelve seconds the deadline
-- gives a solo player to break all three and still dodge whatever the boss is
-- doing meanwhile.
--
-- `archetype = "flopper"` because it must not move or fight: it sits where the
-- attack planted it and waits to be broken. `rarity = "Boss"` for the same
-- reason the leviathan's row carries it - that tier is not in FishingService's
-- RARITY_ORDER, so nothing can ever roll one out of a cast. No `waters`, no
-- drops, and zero rewards on purpose: killing one is paid for by the boss not
-- healing, and a payout here would make the mechanic a farm.
Creatures.items.brine_polyp = {
	id = "brine_polyp",
	name = "Brine Polyp",
	rarity = "Boss",
	archetype = "flopper",
	health = 260,
	rewards = { coins = { 0, 0 }, xp = 0 },
	body = {
		-- No polyp species in the pack yet: the jelly's shape (CreaturePack,
		-- the same place moonbell_jelly takes it from), shrunk and lit the
		-- serpent's lure-green, until creatures_gen.py grows one.
		model = "CreaturePack",
		species = "Jelly",
		shape = "jelly",
		stance = "upright", -- bell up, rooted on the stone; never on its side
		scale = 0.9,
		color = Color3.fromRGB(52, 96, 88), -- wet, dark holdfast
		finColor = Color3.fromRGB(96, 150, 130),
		markColor = Color3.fromRGB(120, 255, 214), -- the same neon as the lure
	},
}

-- RIMEFANG'S REFREEZE, as a thing you can break. Her heal mists three open
-- shards and each one that finishes pays her 6% of her health and comes back
-- SLICK; what cancels it is BREAKING THE GLOW, and a glow a weapon can hit has
-- to be a creature - that is the only thing CombatService's melee and shots
-- resolve against (the polyp above is the same trick for the same reason).
--
-- Rarity "Boss" keeps it out of every cast pool (FishingService's RARITY_ORDER
-- never walks that bucket) and the zero rewards say the right thing: denying a
-- heal is the reward. Health is a little under the polyp's because there are
-- three of these on a 12-second clock in a fight with no cover to break them
-- from.
Creatures.items.rime_rift = {
	id = "rime_rift",
	name = "Refreezing Rift",
	rarity = "Boss",
	archetype = "flopper",
	health = 220,
	rewards = { coins = { 0, 0 }, xp = 0 },
	body = {
		-- No rift species in the pack: the jelly's bell, shrunk and lit the
		-- floe's own ice blue, standing in until creatures_gen.py grows one.
		model = "CreaturePack",
		species = "Jelly",
		shape = "jelly",
		stance = "upright", -- it grows UP out of the water it is freezing
		scale = 0.85,
		color = Color3.fromRGB(150, 186, 214), -- wet new ice
		finColor = Color3.fromRGB(205, 232, 248),
		markColor = Color3.fromRGB(215, 240, 255), -- the glow FloeController draws over it
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

-- Pyrelisk, the Ashfall Colossus - Ashfall Caldera's boss (Bosses.luau). A
-- 270-stud obsidian rock golem rooted in the caldera lake of its own arena,
-- summoned by casting Caldera's Call (Bait.luau) exactly as Brinejaw is.
-- Rarity "Boss" keeps it out of every cast roll; its heart is the
-- Heart_pyrelisk attribute, never a drop.
Creatures.items.pyrelisk = {
	id = "pyrelisk",
	name = "Pyrelisk, the Ashfall Colossus",
	rarity = "Boss",
	archetype = "boss",
	boss = "pyrelisk",
	waters = "volcano",
	-- The volcano band's capstone (L22-28) against island-4 gear. 40,000 is
	-- unchanged by the redesign on purpose: none of it went into the health
	-- bar. What the colossus added was a fight where damage is only legal
	-- inside an EARNED window (`entrenched` keeps it untargetable otherwise),
	-- and the answer to that is a longer window - `handfall.stagger` is 20
	-- seconds - not a smaller bar. Re-tune the two together or not at all.
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
	-- AUTHORITY ONLY. Nothing here is ever seen: the body is 270 studs of
	-- rock drawn entirely client-side by PyreliskBodyController off
	-- PyreliskPath, and CreatureService.hideColossusModel makes every part of
	-- this model invisible the moment it rises. What survives is a hit volume
	-- and the HUD's health bar.
	--
	-- And the pack cannot build it either, which is the fact that decides the
	-- numbers below. `assembleSpecies` wants <Species>_Body / _Fins / _Eyes /
	-- _Marks; boss_gen.py's build_pyrelisk exports Pyrelisk_Torso, _Head,
	-- _Core, _Shoulder, _Seam, _Vent, _WalkArm ... and no _Body at all, so
	-- the species never resolves and the row always falls through to the
	-- procedural `shape`. The proxy is therefore a ~15-stud leviathan
	-- stand-in, and its bounding sphere is what `raycastNearest` adds to
	-- `hitRadius` when it decides whether a shot found the boss.
	body = {
		model = "CreaturePack",
		species = "Pyrelisk",
		-- The stand-in, and today the only thing this row ever builds. The
		-- day the pack grows a Pyrelisk_Body the proxy becomes the real
		-- shell at true size and the shot sphere widens to match it, which
		-- is an improvement and needs no change here - provided `scale`
		-- stays 1.0.
		shape = "leviathan",
		stance = "upright",
		-- 1.0 = PyreliskPath.SCALE, the Kraken convention (that row tracks
		-- KrakenPath.SCALE for the same reason). It was 1.5, sized for the
		-- pre-redesign serpent that was cut small and scaled up; the colossus
		-- is authored at TRUE SIZE, so there is nothing left to scale up.
		--
		-- The reason it matters at all: `creature.hitRadius` is
		-- Bosses.hitRadius * this, so at 1.0 that number reads in real studs
		-- and the moat arithmetic it is derived from (96 + a 16-stud melee
		-- reach must stay inside the lake's 120-stud edge) can be checked
		-- without a multiplication. Raising this raises the melee reach into
		-- the boss with it, and hands anyone standing at the lava's edge the
		-- window the climb is supposed to be the price of.
		scale = 1.0,
		color = Color3.fromRGB(38, 32, 40), -- cooled obsidian shell
		finColor = Color3.fromRGB(80, 44, 34), -- basalt plating, crown columns, claws
		markColor = Color3.fromRGB(255, 96, 16), -- the melt in every seam and vent (neon)
	},
}

-- ACT 2's TWO LIMBS. Both arms come down across the moat onto the rim path
-- and become these - the first melee this fight has ever offered. Everything
-- about it is the moat's fault: `pyrelisk.hitRadius` 96 plus the longest melee
-- reach in Weapons.luau (16) is eight studs inside the lake's 120-stud edge,
-- so act 1 is ranged-only BY GEOMETRY and there is nothing a blade can do in
-- it. The arms are the answer, and a `rangedOnly` flag here would take it back.
--
-- 7,000 EACH, and it is one decision with `K.PY_ARM_WINDOW`'s 120 seconds -
-- the window is ~1.6x the time a solo player is projected to need. Both halves
-- are guesses against a band-4 party DPS nobody has measured (design flag
-- F-2/F-3): re-derive them together off a real playtest or not at all. The
-- party's `healthMult` is carried in by `Fn.pyreliskPlantArm`, as the generic
-- parts ring has always carried it.
--
-- `shotRadius = 14` IS A SPHERE AT THE FIST, AND THE ARM IS 150 STUDS LONG.
-- Ship (a) of design flag F-5, knowingly: you fight the hand. The fist is
-- where the limb meets the rim path, which is where the party is standing and
-- where every telegraph in the act already points. The correct fix is
-- generalising `creature.hitHeight` (a vertical axis, and these arms lie flat)
-- to a `hitAxis` capsule in `raycastNearest` - the same eight lines this
-- fight's checklist already owes for the colossus's own pivot-to-crown
-- capture. That is a follow-on, not this slice.
--
-- `archetype = "pyreliskarm"` is NOT a no-op, which is what separates it from
-- `krakenarm` and `krakenpolyp`: see `Fn.updatePyreliskArm`. An arm bleeds a
-- lava pool onto the rim path near itself every seven seconds, so the ground
-- you have to stand on to hit it shrinks while you do. 120 seconds of a silent
-- boss and two inert limbs is a damage check, not an act.
Creatures.items.pyrelisk_arm = {
	id = "pyrelisk_arm",
	name = "Ashfall Limb",
	rarity = "Boss",
	archetype = "pyreliskarm",
	health = 7000,
	waters = "volcano",
	shotRadius = 14.0,
	rewards = { coins = { 240, 380 }, xp = 600 },
	body = {
		model = "CreaturePack",
		species = "Pyrelisk",
		-- The same stand-in the colossus row falls through to, for the same
		-- reason: `assembleSpecies` wants <Species>_Body and boss_gen exports
		-- no Pyrelisk_Body, so the species never resolves. The drawn limb is
		-- PyreliskBodyController's; this is the hit volume.
		shape = "leviathan",
		stance = "upright",
		scale = 2.2,
		color = Color3.fromRGB(38, 32, 40), -- the colossus's cooled obsidian
		finColor = Color3.fromRGB(80, 44, 34), -- its basalt plating
		markColor = Color3.fromRGB(255, 96, 16), -- the melt, brighter on a broken limb
	},
}

-- (`pyrelisk_ventrock` - act 3's six magma bleeders - and `pyrelisk_neckcore`
-- - the core at the top of the climb - stood here and are CUT (2026-09-12, the
-- directive). There is no climb: the second arm's death is the colossus's
-- death, the body collapses, the caldera opens and the party drops to the
-- heart. `pyrelisk_arm` above is act 2's and is unchanged; the two rows below
-- are the heart's room and are unchanged. `CreatureFamilies.luau` loses the
-- matching two rows in the same unit - that gate is two-directional.)

-- THE LAST ACT'S BOSS: the thing burning inside the mountain, on a dais in a sealed
-- room six hundred studs up. `archetype = "boss"` and `boss = "pyrelisk_heart"`
-- make it an ordinary boss creature; everything particular about it is the two
-- fields below.
--
-- `vulnerableWhen = "partsDown"` IS THE WHOLE GATE. The shipped declarative
-- rule (`Fn.unaimable`): the heart cannot be scratched while a single pillar
-- stands, and the eighth pillar's death stamps `Exposed` through `kill()`'s
-- existing path. No bespoke code, and it is the same mechanism that gates the
-- Kraken's head behind its arms.
--
-- 14,000 against the colossus's 40,000 dial - and unlike that one this IS a
-- bar: the heart is damaged, directly, with weapons, which nothing in acts 1-3
-- ever was. Unmeasured with the rest of the fight (design flag F-2).
Creatures.items.pyrelisk_heart = {
	id = "pyrelisk_heart",
	name = "The Ashfall Heart",
	rarity = "Boss",
	archetype = "boss",
	boss = "pyrelisk_heart",
	waters = "volcano",
	health = 14000,
	vulnerableWhen = "partsDown",
	-- THE ONLY PLACE THIS FIGHT CAN ANSWER ITS OWN DEATH, and the reason is the
	-- same one `kraken_heart` carries the field for: `Fn.updateBoss` is not
	-- called for a creature that is already dead, so putting the party back on
	-- the mountain they jumped off has nowhere else to live. `kill()` runs
	-- `gimmick.onKill` while `pos` still means something and before Killed pays
	-- anyone out.
	--
	-- It also closes the caldera behind them - see `K.GIMMICKS.pyreliskheart`.
	-- It carries no `onHit`, so `hitModifiers` falls straight through and
	-- nothing about how the heart takes damage changes.
	gimmick = { kind = "pyreliskheart" },
	rewards = { coins = { 9000, 13000 }, xp = 10000 },
	-- THE COLOSSUS'S DROPS MOVE HERE, because this is where the fight actually
	-- ends and `suppressDrops` is already true for a boss carrying
	-- `succeededBy`. Acts 1-3 pay nothing on their own.
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
		shape = "leviathan",
		stance = "upright",
		-- 2.0, AND IT IS HALF OF ONE DECISION. `creature.hitRadius` is
		-- `Bosses.pyrelisk_heart.hitRadius * this`, so the row authors 13
		-- against this 2.0 to land a live capture sphere of 26. Move one and
		-- move the other: the PRODUCT is the number that matters, and at 52 the
		-- sphere starts eating shots aimed at the pillars that gate it.
		scale = 2.0,
		color = Color3.fromRGB(43, 39, 43), -- cooled basalt, the chamber's own
		finColor = Color3.fromRGB(120, 46, 20), -- the socket collars' ember
		markColor = Color3.fromRGB(255, 210, 90), -- the molten mass itself (Neon)
	},
}

-- THE EIGHT OBSIDIAN PILLARS, on the chamber's authored socket collars. They
-- are cover and they are the gate, in one object: you hide behind them from the
-- six wall vents, and breaking them is the only way to reach the heart.
--
-- BREAKING ONE COSTS YOU THE GROUND IT STOOD ON. A permanent lava pool vents at
-- that socket (`K.PY_PILLAR_POOL`) and the heart's cooldowns tighten by
-- `K.PY_PILLAR_STEP` - so the room gets smaller, faster and less defensible
-- with every one you take, and the eighth is fought at roughly twice the
-- opening cadence with a floor full of holes. That is the same bargain the arms
-- and the arm rocks make: the reward for progress is a harder floor, which is
-- the only reward structure a fight with no punish window can offer.
--
-- `archetype = "krakenpolyp"` is the shipped no-op. A pillar is a pillar: it
-- does not walk and has no initiative, and the generic flop would send a
-- thirty-stud obsidian column hopping round a room somebody is standing in.
--
-- 1,500 EACH - eight of them is 12,000, comparable to the heart's own 14,000,
-- because clearing the cover IS half this act rather than a preamble to it.
Creatures.items.pyrelisk_pillar = {
	id = "pyrelisk_pillar",
	name = "Obsidian Pillar",
	rarity = "Boss",
	archetype = "krakenpolyp",
	health = 1500,
	waters = "volcano",
	-- ~24 studs across at the foot. Generous, because it is cover first and a
	-- target second: a player pressed against one to break it should not have
	-- to aim, and the eight of them stand at r44-70 where nothing else is.
	shotRadius = 12.0,
	rewards = { coins = { 120, 200 }, xp = 300 },
	body = {
		model = "CreaturePack",
		species = "Pyrelisk",
		shape = "urchin",
		scale = 1.4,
		color = Color3.fromRGB(23, 23, 31), -- obsidian (PY_OBSIDIAN)
		finColor = Color3.fromRGB(43, 39, 43), -- cooled basalt at the collar
		markColor = Color3.fromRGB(255, 120, 20), -- the seam of melt up its spine
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

-- Old Gnashroot, the Drowned Mire - Blackmire Fen's boss (Bosses.luau). A
-- hunched colossus of wet mud with the fen's black root-knot burning in its
-- chest, summoned by casting Tyrant's Call. Rarity "Boss" keeps it out of
-- every roll; its heart is the Heart_old_gnashroot attribute, never a drop.
Creatures.items.old_gnashroot = {
	id = "old_gnashroot",
	name = "Old Gnashroot, the Drowned Mire",
	rarity = "Boss",
	archetype = "boss",
	boss = "old_gnashroot",
	waters = "swamp",
	-- A wall for L8-14 gear (~120-170 dps): a longer fight than Brinejaw
	-- because the sludge, the mire snares and the wallow lane keep taking
	-- your footing away rather than because it out-heals you.
	health = 16000,
	rewards = { coins = { 1800, 2600 }, xp = 5200 },
	drops = {
		materials = {
			bog_iron = { 6, 10 },
			-- It drags up what the bog has SWALLOWED - including the gators.
			-- (Swapping this to mire_hide when the design stopped being a
			-- gator was a mistake: gator_scute is the fen's workhorse, wanted
			-- by nine recipes including both capstones this kill unlocks -
			-- Mireheart 10, Fenreaver 8 - while mire_hide's only sinks are
			-- Mirewalker legs/chest at L9-11, five levels below this gate.)
			gator_scute = { 4, 6 },
			wisp_light = { 3, 5 },
			fen_venom = { 2, 4 },
		},
	},
	body = {
		model = "CreaturePack",
		species = "Gnashroot",
		shape = "leviathan", -- pre-import stand-in: the boss silhouette, mud-dark
		stance = "upright",
		scale = 1.5,
		color = Color3.fromRGB(107, 71, 43), -- wet peat-mud
		finColor = Color3.fromRGB(94, 92, 85), -- the bog stone hauled up in its back
		markColor = Color3.fromRGB(150, 235, 200), -- the gnashroot burning in its chest (neon)
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
	-- A lantern is a lock, not a health bar: at 2,600 a solo player spent
	-- longer opening each cycle than fighting inside it.
	health = 1900,
	waters = "gloom",
	rangedOnly = true,
	rewards = { coins = { 70, 120 }, xp = 200 },
	body = {
		model = "CreaturePack",
		species = "Noctyss",
		shape = "leviathan",
		stance = "upright",
		-- THIS SCALE IS THE HITBOX, NOT THE STALK. The visible stalk is a
		-- 33-stud chain the client draws from NoctyssPath at its authored
		-- size; this row's model is the hidden authority standing at the
		-- BULB, and its scale is what sizes the sphere a shot has to find.
		-- The two are different objects that happen to share a field name -
		-- raising this to "match the stalk" would not grow anything you can
		-- see.
		--
		-- 0.846, NOT 0.55, AND IT IS SOLVED, NOT PICKED. The lantern is an
		-- EYE now (NoctyssPath.EYE_R), and the eye is drawn as a sphere of
		-- radius 4.0 centred exactly on NoctyssPath.bulbPosition - the same
		-- point this model stands on. The player is told "shoot the pupil",
		-- so the sphere behind the pupil has to be the sphere they are
		-- looking at, to the stud.
		--
		-- The mapping, read out of CreatureService (raycastNearest) rather
		-- than guessed: a creature with no `hitRadius` - and a part row has
		-- none, that field comes off the Bosses def - is captured within
		--     shotRadius = max(1.4, boundingBox.Magnitude * 0.3)
		-- of the shot ray, and CreatureModel applies the row's scale with
		-- `model:ScaleTo`, so the bounding box and therefore that radius are
		-- LINEAR in this number. 0.55 measured 2.6 studs, so
		--     0.55 * (4.0 / 2.6) = 0.846
		-- and the capture sphere is EYE_R exactly. (Well clear of the 1.4
		-- floor at either end, so the max() is not in play.)
		--
		-- HEALTH IS UNCHANGED at 1,900. The mapping does not force a
		-- rebalance - nothing about a stalk's damage taken depends on its
		-- size - and the 2.4x of extra cross-section is the point of the
		-- change, not a side effect of it: at 2.6 studs, 35 studs up, in a
		-- pitch-black arena, the fight's central act was a pixel hunt.
		scale = 0.846,
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
	-- 46,000, not 60,000: she is the only boss in the saga whose health bar is
	-- GATED - she can be hurt solely inside the maw window, roughly 40% of the
	-- fight's clock, and only after the party has solved which light is real.
	-- The same number as her neighbours would read as three times the fight.
	health = 46000,
	waters = "gloom",
	vulnerableWhen = "markedDown",
	rewards = { coins = { 18000, 26000 }, xp = 16000 },
	drops = { materials = { abyss_ichor = { 3, 4 }, lantern_gland = { 4, 6 }, trench_chitin = { 6, 8 } } },
	body = {
		model = "CreaturePack",
		species = "Noctyss",
		shape = "leviathan",
		stance = "upright",
		-- 2.0, and it MUST equal NoctyssPath.MAW.SCALE - that table's pose
		-- (FORWARD, Y_UP, the jaw floor, the gullet) is solved against this
		-- number, and CreatureService's K.NOCTYSS_GULLET_REACH is measured off
		-- the tongue slab it sizes. Editing one without the other moves the
		-- floor the party stands on out from under the mesh they see.
		--
		-- 2.0, not 2.4: at 2.4 the skull was 28.8 studs across against the
		-- arena pit's 30-stud mouth, so she came up wedged in the rim - the
		-- user's read was that the head has to FIT INSIDE the hole. At 2.0 it
		-- is 24 across with three studs of daylight each side. hitRadius 6 then
		-- reads as 12 studs of hide, which is what the eye sees.
		scale = 2.0,
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
	-- 24,000, DOWN FROM 58,000, and the bar did not shrink - it SPLIT. The
	-- three-act rework (2026-09-09) spends the same total across three health
	-- pools instead of one: 14,400 on the four permanent guns (act one),
	-- 24,000 on the hull here (act two), and 20,000 on the Admiral himself
	-- (act three, `wrack_admiral` below). 58,400 against the 58,000 this row
	-- used to carry alone, so the fight is the same length and it is now three
	-- fights long instead of one.
	health = 24000,
	waters = "wreck",
	-- THE HULL IS IMMUNE FOR THE WHOLE OF ACT ONE, and this one word is what
	-- says so. `damage()` refuses him while `partsAlive > 0`; the Bosses
	-- entry's `parts` ring plants the four corner cannons; `kill()` counts them
	-- down. What CHANGED is that `parts.regrow` is GONE, so the count only ever
	-- goes down: the fourth kill opens the hull permanently, and the loop this
	-- used to be (all down -> window -> regrow -> repeat) becomes a one-way ACT
	-- TRANSITION with no new engine state at all. The act boundary is the
	-- deletion of a field.
	vulnerableWhen = "partsDown",
	-- NO `rewards` AND NO `drops`. The hull's death is not the end of the
	-- fight, it is the end of act two: BossService's `onKilled` sees
	-- `succeededBy` on the Bosses row, hands off to the Admiral and returns
	-- before it pays anybody. The payout moved WITH the ending, onto
	-- `wrack_admiral` - and `raise` spawns this one with `suppressDrops` so the
	-- generic per-kill path cannot pay it either. A row that still carried the
	-- numbers would be a second, quieter claim about where the fight ends.
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

-- Admiral Wrack's four gun-deck batteries: the way into him. Planted by the
-- Bosses entry's `parts` ring on his gun-deck rail, never spawned by a cast
-- (rarity "Boss"). They do not attack on their own - Wrack's patterns ARE
-- these guns firing, which is why every one of them you silence visibly
-- thins the screen - so they carry the choirstalk no-op updater rather than
-- an archetype of their own: planted, inert, and there to be broken.
Creatures.items.wrack_battery = {
	id = "wrack_battery",
	name = "Flagship Cannon",
	rarity = "Boss",
	archetype = "choirstalk",
	-- 3,600, up from 2,800, because these four ARE act one now. With
	-- `parts.regrow` deleted they never come back, so this bar is not one cycle
	-- of a loop that repeats against a denser phase - it is the whole first act
	-- of the fight, once. 14,400 across the four.
	health = 3600,
	waters = "wreck",
	-- Same reason as `choir_stalk`'s: they are the ship's own cannons, 13.2 to
	-- 14.0 studs up in sponsons at her four corners (Bosses.admiral_wrack
	-- `parts.mounts`), so melee target-picking must not select one it can never
	-- reach.
	rangedOnly = true,
	-- THE FIGHT'S PRIMARY TARGET, and this number is not a comfort setting any
	-- more - IT IS GEOMETRY THE SHIP IS BUILT AGAINST. The corner sponsons are
	-- three-sided casemates (back wall and two cheeks, collidable, folded into
	-- `Wrack_HullCollider`) whose whole job is that only two cannons can be
	-- shot from any one bearing. The capture sphere has to fit inside that
	-- house, and it fits on TWO sides:
	--
	--     shotRadius <= cheek half-width          (4.0)
	--     plate top  >= tallest mount + shotRadius (14.0 + 4.0 = 18.0)
	--
	-- At 5.0 the sphere spans r 14-24 against a cheek mouth at r 23 and pokes
	-- straight through it: a third cannon becomes shootable past the casemate
	-- from the sand's edge, and the ship stops occluding the thing it exists to
	-- occlude. At 4.5 it still overhangs. 4.0 is the largest capture the
	-- geometry admits, and it is authored AT the half-width rather than near it.
	--
	-- THE SAME NUMBER IS BAKED INTO assets/boss_gen.py AS
	-- `WR_BATTERY_SHOT_RADIUS`, because the casemates are solved against it
	-- there. Two files, two languages, one number - and a stale value on either
	-- side leaves BOTH guards green while the boss is shootable through, so
	-- tools/check_content.py reads them both and FAILS on a mismatch. Change
	-- this and you change that, or the gate stops you.
	shotRadius = 4.0,
	rewards = { coins = { 120, 200 }, xp = 350 },
	-- Authority only, like the tentacles: a chunk of the flagship at gun-deck
	-- scale, so it reads as part of the hull it is bolted to.
	body = {
		model = "CreaturePack",
		species = "AdmiralWrack",
		shape = "leviathan",
		stance = "upright",
		scale = 0.5,
		color = Color3.fromRGB(96, 116, 108),
		finColor = Color3.fromRGB(70, 86, 82),
		markColor = Color3.fromRGB(255, 190, 120), -- the muzzle glow, lit until it is broken
	},
}

-- ---------------------------------------------------------------------------
-- ACT THREE: THE ADMIRAL HIMSELF (three-act rework, 2026-09-09)
--
-- User's mandate: "after the main ship is defeated, you fight the main admiral
-- himself in like a dual." So he is a SECOND CREATURE, not a phase - the hull
-- dies, the wreck lists, and he leaps down onto the sand as his own boss with
-- his own health bar and his own Bosses row (`wrack_duel`).
--
-- WHY A SECOND ROW AND NOT A THIRD PHASE. The boss archetype reaches
-- everything it needs - the rise, the phase table, the attack book, the HUD
-- name - through `row.boss` -> `Bosses.items[...]`, one row per fight. A third
-- phase would have had to be a mobile duellist and a planted gun platform at
-- the same time, sharing one `speed`, one `turnRate`, one `hitRadius` and one
-- attack book with a first-rate ship of the line. Two rows cost one field
-- (`succeededBy`) and a handoff in BossService; one row would have cost a
-- branch in every one of those numbers.
--
-- HE IS THE OPPOSITE OF THE THING THAT MADE HIM. The hull never took a step
-- and never turned; he does nothing but. The hull could only be hurt through
-- its guns; he has no gate at all - no `vulnerableWhen`, and deliberately no
-- `rangedOnly`, so sword and gun both reach him. After two acts of shooting
-- fixed brass from a distance, the fight ends in reach.
Creatures.items.wrack_admiral = {
	id = "wrack_admiral",
	name = "Admiral Wrack",
	rarity = "Boss",
	archetype = "boss",
	boss = "wrack_duel",
	-- 20,000: act three's third of the 58,400. Shorter than the hull's act on
	-- purpose - this is the tense one, not the long one.
	health = 20000,
	waters = "wreck",
	-- 8.6, AND IT IS NOT A COMFORT SETTING EITHER. The drawn duelist is 17.2
	-- studs tall while the server's stand-in body is a fraction of that, so
	-- without an authored capture BOTH sides derive one from the stand-in's
	-- bounding box - `raycastNearest` server-side and `aimDistance`
	-- client-side, independently, exactly the composition that made shots pass
	-- through the powder runner (user, 2026-09-08: "when i point my crosshair
	-- at something and shoot, it doesnt work"). Against a body this tall the
	-- symptom would not read as a miss at all: it reads as "the Admiral feels
	-- unhittable", which is a difficulty complaint about a targeting bug.
	--
	-- The duel rig's reach numbers are tuned against 8.6 (lunge reach 1.2 with
	-- the reach moved into the arm), so this value is shared with the client
	-- and not free to drift.
	shotRadius = 8.6,
	-- NO `rangedOnly` and NO `vulnerableWhen`: melee and guns both land on him,
	-- at all times. The duel's difficulty is its moves, never its access.
	rewards = { coins = { 40000, 55000 }, xp = 30000 },
	drops = { materials = { wraith_essence = { 3, 4 }, spectral_sailcloth = { 5, 7 }, tarnished_doubloon = { 8, 12 } } },
	-- `scale = 1`, and nothing added for the sabre. The mesh lane authors him
	-- at his true height (17.2, sole 0.73 BELOW the deck at his station) and
	-- the client draws that rig off `CreatureId`; a scale here would fight the
	-- drawn body rather than change it, and a capture padded for the blade
	-- would make the blade itself a hitbox.
	body = {
		model = "CreaturePack",
		species = "AdmiralWrack",
		shape = "leviathan",
		stance = "upright",
		scale = 1,
		color = Color3.fromRGB(30, 37, 62), -- WR_COAT, the drowned indigo
		finColor = Color3.fromRGB(201, 177, 102), -- WR_GOLD: lace, epaulettes, rank
		markColor = Color3.fromRGB(255, 204, 92), -- WR_EYE - the only light left in him
	},
}

-- ---------------------------------------------------------------------------
-- ADMIRAL WRACK'S FOUR SHOOTABLE PROPS (roster rework, 2026-09-08)
--
-- The redesign's premise is that a bullet hell whose only verb is "walk left"
-- runs out of things to say: four of the five new mechanics answer that by
-- putting something on the sand that SHOOTING is the answer to, and a shootable
-- thing in this engine is a creature row. So these four are rows, not a new
-- kind of object - they inherit targeting, the hit test, the damage numbers
-- floating off them and the health bar for free, and the fight's new verbs cost
-- the combat code nothing.
--
-- ALL FOUR SHARE THREE DECISIONS, each of which is load-bearing:
--
--  1. `archetype = "choirstalk"`, the no-op updater. Every one of them is
--     placed and moved by the Wrack handlers in CreatureService (the keg homes
--     on its target, the boarders march at the hull, the midlink rides its own
--     chain), so any archetype with a will of its own would fight the handler
--     for the same position. The generic flop would be worse still: a powder
--     keg hopping about on its own is not a fuse burning down.
--  2. `rarity = "Boss"`, so nothing ever casts one out of the water. They exist
--     only for the seconds their move owns them, and every one is spawned with
--     a `lifetime` backstop so a fight that ends underneath them - the boss
--     killed mid-charge, the party wiping - cannot strand one on the beach.
--  3. NO `drops`. They are hazards wearing a health bar, not catches: the
--     fight's loot is the Admiral's. The small `rewards` are there because
--     breaking one IS a correct play and the game should say so.
--
-- Health is the real tuning knob on all four, and it is set against the SECONDS
-- the mechanic gives you rather than against any hostile's bar: a brazier you
-- cannot douse inside its charge is not a puzzle, it is a cutscene.
--
-- AND ALL FOUR CARRY `shotRadius`, WHICH IS NOT DECORATION (user, 2026-09-08,
-- playing this build: "when i point my crosshair at something and shoot, it
-- doesnt work it doesnt hit the enemy properly, especially the little black
-- thing that follows me around"). Without it a creature's capture is derived,
-- twice and independently, as `max(1.4, boundingBox.Magnitude * 0.3)` - once by
-- CreatureService.raycastNearest to select what a shot hit, and once by
-- RangedController.aimDistance to decide how far down the cursor ray the target
-- is. For a keg-sized model that is about 1.8 studs, and the two estimates
-- compose badly rather than independently: when the client's sweep misses, the
-- aim depth falls through to the SAND BEHIND the target, and because the shot
-- leaves the shooter's root rather than the camera, that wrong depth bends the
-- fired direction by the rig's whole parallax. The server is then asked about a
-- ray that genuinely does miss. Nobody's arithmetic is wrong anywhere.
--
-- So the number is authored here, once, and both sides read it (the server off
-- the row, the client off the published `ShotRadius` attribute). The values are
-- deliberately GENEROUS - four to five and a half studs against models of two
-- to five - for three reasons, in order of weight: two of these move while you
-- shoot at them and a 100-200 ms round trip is 2-4 studs of travel at the keg's
-- 18 studs/s; they sit low on open sand, which is the exact geometry that makes
-- the depth fall through; and a hazard the fight is TELLING you to shoot should
-- be forgiving to shoot. Anything the player is meant to hunt down rather than
-- destroy on sight keeps the derived formula.
-- ---------------------------------------------------------------------------

-- THE CHASER. A fuse-lit powder keg that rolls off a live gun deck and homes
-- on one player at a walk plus two - it cannot be outrun, only answered. Shoot
-- it and it goes off WHERE IT IS, which is the whole mechanic: kill it early
-- across the beach and the blast is a firework, panic and kill it at your own
-- feet and you have thrown the Admiral's grenade for him. 900 is two or three
-- seconds of one player's fire, so a solo can always take it and a party can
-- always take it EARLY, which is the difference the move is about.
Creatures.items.wrack_powder_keg = {
	id = "wrack_powder_keg",
	name = "Powder Runner",
	rarity = "Boss",
	archetype = "choirstalk",
	health = 900,
	waters = "wreck",
	-- See the class note above: the one the complaint was about: ~2 studs of model, moving at 18 studs/s.
	shotRadius = 5.5,
	-- NOT `rangedOnly`, and unlike the battery that is not an oversight: the
	-- keg rolls on the sand at head height, so melee can reach it - and melee
	-- reaching it means detonating it inside your own blast radius. That is a
	-- real choice with a real cost, which is better than a rule forbidding it.
	rewards = { coins = { 60, 110 }, xp = 220 },
	body = {
		model = "CreaturePack",
		species = "AdmiralWrack",
		shape = "leviathan",
		stance = "upright",
		scale = 0.22,
		color = Color3.fromRGB(78, 62, 46),
		finColor = Color3.fromRGB(52, 42, 32),
		markColor = Color3.fromRGB(255, 168, 70), -- the fuse, burning down
	},
}

-- THE PILLAR. Ghost-fire rises out of the sand at three ring bearings and
-- charges for six seconds; the wave that follows covers the whole arena EXCEPT
-- the sector behind any brazier that has been doused, and dousing one is
-- shooting it. 1400 against a six-second charge is one player's full attention
-- or two players' half of it - the move asks the party to split, which is the
-- one thing a wall of cannonballs never asks.
Creatures.items.wrack_ghost_brazier = {
	id = "wrack_ghost_brazier",
	name = "Ghost Brazier",
	rarity = "Boss",
	archetype = "choirstalk",
	health = 1400,
	waters = "wreck",
	-- See the class note above: static, but a 6-second window to find and break three of them.
	shotRadius = 5.0,
	rewards = { coins = { 90, 150 }, xp = 300 },
	body = {
		model = "CreaturePack",
		species = "AdmiralWrack",
		shape = "leviathan",
		stance = "upright",
		scale = 0.5,
		color = Color3.fromRGB(64, 88, 82),
		finColor = Color3.fromRGB(44, 62, 58),
		markColor = Color3.fromRGB(160, 255, 210), -- his own ghost-fire, on a stick
	},
}

-- THE OFF SWITCH. The glowing midlink of the anchor chain being dragged back
-- across the sand: break it and the whole hazard dies on that frame
-- (ProjectileService.retireTag). Deliberately the lowest bar of the four - it
-- is a four-second hazard and the shot has to be worth taking inside it, so
-- 700 is about one clean burst.
Creatures.items.wrack_chain_link = {
	id = "wrack_chain_link",
	name = "Anchor Midlink",
	rarity = "Boss",
	archetype = "choirstalk",
	health = 700,
	waters = "wreck",
	-- See the class note above: moving with its own chain, and the only way to end that hazard.
	shotRadius = 5.0,
	rewards = { coins = { 50, 90 }, xp = 180 },
	body = {
		model = "CreaturePack",
		species = "AdmiralWrack",
		shape = "leviathan",
		stance = "upright",
		scale = 0.24,
		color = Color3.fromRGB(120, 128, 136),
		finColor = Color3.fromRGB(86, 92, 98),
		markColor = Color3.fromRGB(255, 96, 60), -- the link glowing where it is straining
	},
}

-- THE RACE. A skeleton boarding party beaches at the palisade and marches at
-- the hull; every one that arrives repairs a gun deck. They carry no attack at
-- all - the threat is not what they do to you, it is what they undo - so the
-- move inverts the fight for eleven seconds: the boss's own health gate is the
-- thing you are now defending. 1300 x 3 against a ten-second march is a party
-- that has to stop shooting the Admiral, which is exactly the cost intended.
Creatures.items.wrack_boarder = {
	id = "wrack_boarder",
	name = "Drowned Boarder",
	rarity = "Boss",
	archetype = "choirstalk",
	health = 1300,
	waters = "wreck",
	-- See the class note above: man-sized and walking; the derived number was close, this is honest.
	shotRadius = 4.5,
	rewards = { coins = { 110, 180 }, xp = 340 },
	body = {
		model = "CreaturePack",
		species = "DrownedBoatswain",
		shape = "zombie",
		stance = "upright",
		scale = 0.95,
		color = Color3.fromRGB(96, 116, 108),
		finColor = Color3.fromRGB(70, 86, 82),
		markColor = Color3.fromRGB(160, 255, 210),
	},
}

-- ---------------------------------------------------------------------------
-- ...AND THE SHIP'S OWN TWO (2026-09-09). The four above are things the Admiral
-- PUTS on the sand; these two are pieces of the hull, and they inherit every one
-- of the three decisions in the class note above (`choirstalk` so their handler
-- owns their position, `rarity = "Boss"` plus a spawned `lifetime` so neither can
-- be stranded, no drops) for the same reasons.
--
-- ONE THING IS DIFFERENT AND IT IS WORTH SAYING: both of these MOVE FAST and
-- both are the whole answer to the move that made them, so their `shotRadius` is
-- at the generous end of the band the note argues for - 5.0 against models of
-- three to four studs. The Lady crosses at 54 studs/s, which is three times the
-- keg's pace and therefore three times the round-trip lead, and a player who has
-- correctly read "shoot her" and led her properly should not lose the shot to
-- the capture geometry the note above was written about.
--
-- Their PROVENANCE, so the next reader knows what these numbers answer to: both
-- rows are consumed only by the Wrack handlers `ladybelow` and `boomsweep` in
-- CreatureService (via `p.rows` on Bosses.admiral_wrack's attacks of the same
-- names), and the geometry they are placed at - the figurehead's dock, the
-- boom's pivot and length - comes from the mesh lane's `WR_FIGUREHEAD` /
-- `WR_BOOM` handoff into that boss row's `rigging`. Health is set against the
-- SECONDS each move gives you, exactly as the four above are.
-- ---------------------------------------------------------------------------

-- THE LADY BELOW. The flagship's figurehead unships herself and makes two or
-- three telegraphed lane dives at one player before re-docking at the prow.
--
-- 900 IS THE "ONE DIVE EARLY" NUMBER, and it is the only number on this row the
-- design actually turns on. It was set by running the arithmetic rather than by
-- describing it, and the first answer was wrong: a dive cycle is 4.3 seconds
-- (lead 1.1 + a 2.1-second crossing + a 1.1 re-arm), so ending the TWO-dive
-- version before its last pass is that whole bar inside ONE cycle - 211 dps at
-- 900, against the braziers' 233 and the midlink's 167. That is a burst, or two
-- players looking at her, and it is deliberately not free.
--
-- The same 900 makes phase 3's three-dive version a much softer ask (two cycles,
-- 8.4 seconds, 107 dps), and that progression is the right way round: the party
-- that learned to shoot her in phase 1 is PAID for the verb late, when there is
-- most else to be doing. Her health does not scale with the number of dives -
-- the window does.
--
-- (`assets/wrack_patterns_gen.py` prints both numbers in its HANDOFF block, so a
-- retune that breaks the intent shows up in a diff of that output.)
--
-- DELIBERATELY NOT `rangedOnly`, and for the powder keg's reason rather than by
-- omission: she flies at head height down the lane she was telegraphed on, so
-- melee CAN reach her - by standing in the one strip of sand the tell says will
-- hurt. That is a real choice with a real cost, which is better than a rule
-- forbidding it.
Creatures.items.wrack_figurehead = {
	id = "wrack_figurehead",
	name = "The Lady Below",
	rarity = "Boss",
	archetype = "choirstalk",
	health = 900,
	waters = "wreck",
	-- See the class note above, and the lead argument in this block's header:
	-- 54 studs/s is 5 studs of travel across a 100 ms round trip.
	shotRadius = 5.0,
	rewards = { coins = { 100, 160 }, xp = 320 },
	body = {
		model = "CreaturePack",
		species = "AdmiralWrack",
		shape = "leviathan",
		stance = "upright",
		scale = 0.34,
		color = Color3.fromRGB(128, 120, 104), -- salt-bleached oak
		finColor = Color3.fromRGB(92, 86, 74),
		markColor = Color3.fromRGB(210, 240, 255), -- her eyes, and they are open
	},
}

-- THE BOOM TACKLE. The block and fall at the end of the main boom: shoot it and
-- the spar drops on the frame it breaks, mid-windup or mid-sweep.
--
-- 700 IS THE MIDLINK'S NUMBER ON PURPOSE - the same bar for the same shape of
-- decision. The window is bigger here (a 2.2-second windup plus a 3-second
-- sweep, against the midlink's 4.2), but so is the cost of taking it: the tackle
-- swings over the near ring, which is the ground the sweep is clearing, so the
-- shot is taken while walking backwards out of it.
--
-- `rangedOnly` FOR THE BATTERIES' REASON: it hangs six studs up off a spar that
-- is sweeping a band you are being told to leave, so melee target-picking must
-- not select a thing whose only melee approach is standing in the swing.
Creatures.items.wrack_boom_tackle = {
	id = "wrack_boom_tackle",
	name = "Boom Tackle",
	rarity = "Boss",
	archetype = "choirstalk",
	health = 700,
	waters = "wreck",
	rangedOnly = true,
	-- See the class note above: swinging at 28 studs/s at the band's edge, and
	-- the only thing that ends the sweep early.
	shotRadius = 5.0,
	rewards = { coins = { 60, 100 }, xp = 200 },
	body = {
		model = "CreaturePack",
		species = "AdmiralWrack",
		shape = "leviathan",
		stance = "upright",
		scale = 0.28,
		color = Color3.fromRGB(112, 96, 64), -- blocks and brass
		finColor = Color3.fromRGB(78, 66, 46),
		markColor = Color3.fromRGB(255, 214, 130), -- the fall, straining in the sun
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

-- ------------------------------------------------------- the reworked finale
-- THREE ROWS THE KRAKEN'S REWORK ADDED, and none of them replaces
-- `kraken_tentacle` above: that row is the eight-arm whirlpool ring, which is
-- a different fight in a different place and is left exactly as it is.
--
-- All three are `rarity = "Boss"`, spawned only by the fight and never by a
-- cast, and all three are drawn by KrakenBodyController rather than by their
-- own model - the `body` block here is the fallback a client that has not
-- adopted the boss yet sees, and the colours match the hide so the fallback is
-- wrong rather than garish.

-- THE TWO ARMS of phases one and two: the shootable HP bars the whole first
-- two thirds of the fight is about. The client draws each one as a chain of
-- Kraken_TentacleSeg capsules from the head's crown to wherever this hitbox
-- stands, so what you swing at is the limb you can see.
--
-- `archetype = "krakenarm"` has NO updater of its own, on purpose, and that is
-- the difference from `tentacle` above: a tentacle is an autonomous slam
-- machine that picks its own targets off its own cooldown, and these two are
-- CONDUCTED - every rear, sweep, wrap and withdrawal is a beat in the boss's
-- attack book, and an arm that also slammed on its own initiative would put
-- unannounced damage on a deck whose entire counterplay is reading telegraphs.
-- See ARCHETYPE_UPDATERS in CreatureService (the `choirstalk` precedent).
--
-- 9,000 against the boss's 130,000: two of them is 18,000, and breaking BOTH
-- inside one cycle is what opens the siphon. That has to be achievable by a
-- party inside the ~12s an arm stays away, or the fight has no rhythm - and it
-- must not be so cheap that one player alone can hold the window open forever.
Creatures.items.kraken_arm = {
	id = "kraken_arm",
	name = "Kraken Arm",
	rarity = "Boss",
	archetype = "krakenarm",
	health = 9000,
	waters = "maelstrom",
	rewards = { coins = { 200, 320 }, xp = 520 },
	body = {
		model = "CreaturePack",
		species = "KrakenTentacle",
		shape = "gulletcod",
		stance = "upright",
		scale = 2.2,
		color = Color3.fromRGB(33, 20, 51),
		finColor = Color3.fromRGB(51, 33, 77),
		markColor = Color3.fromRGB(150, 120, 255),
	},
}

-- PHASE THREE'S SIX GROWTHS, planted on the gullet's authored socket collars
-- (BossArenas.maelstrom_gullet.sockets). The heart is untouchable while any of
-- them lives, so this is the parts-gate idea again in a room instead of on a
-- ring - and every one that dies steps the heartbeat's metronome up, so the
-- fight gets louder as it gets shorter.
--
-- Stationary by the same rule the arms are: `archetype = "krakenpolyp"` has no
-- updater. A polyp is a node on a stalk grown into a wall; it does not walk.
Creatures.items.kraken_polyp = {
	id = "kraken_polyp",
	name = "Gullet Polyp",
	rarity = "Boss",
	archetype = "krakenpolyp",
	health = 5200,
	waters = "maelstrom",
	rewards = { coins = { 180, 280 }, xp = 460 },
	body = {
		model = "CreaturePack",
		species = "KrakenPolyp",
		shape = "urchin",
		scale = 1.5,
		color = Color3.fromRGB(106, 77, 117), -- the violet collar (arena_gen KG_COLLAR)
		finColor = Color3.fromRGB(122, 29, 38), -- gut flesh (KG_HEART)
		markColor = Color3.fromRGB(230, 74, 73), -- the Neon bulb (KG_HEARTGLOW)
	},
}

-- ...and the things the body sends after you when you cut one. Small, fast,
-- and a `rusher` - the archetype it borrows is the whole behaviour, exactly
-- the bargain `splitter` and `thornback` strike above: nothing here is new
-- code, it is a rusher with the gullet's colours and a boss-fight bounty.
Creatures.items.kraken_antibody = {
	id = "kraken_antibody",
	name = "Gullet Antibody",
	rarity = "Boss",
	archetype = "rusher",
	health = 1700,
	waters = "maelstrom",
	rewards = { coins = { 60, 110 }, xp = 180 },
	body = {
		model = "CreaturePack",
		species = "KrakenSpawn",
		shape = "urchin",
		scale = 0.9,
		color = Color3.fromRGB(122, 29, 38),
		finColor = Color3.fromRGB(74, 33, 38),
		markColor = Color3.fromRGB(230, 102, 90),
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
	-- THE ONLY PLACE THIS FIGHT CAN ANSWER ITS OWN DEATH. `Fn.updateBoss` is not
	-- called for a creature that is already dead, so the collapse at the end of
	-- phase three - the event, and putting the party back on the ship they were
	-- swallowed off - has nowhere else to live. `kill()` runs `gimmick.onKill`
	-- while `pos` still means something and before Killed pays anyone out, which
	-- is exactly the beat that is wanted. See K.GIMMICKS.krakenheart.
	--
	-- It carries no `onHit`, so `hitModifiers` falls straight through it and
	-- nothing about how the head takes damage changes.
	gimmick = { kind = "krakenheart" },
	rewards = { coins = { 90000, 120000 }, xp = 80000 },
	drops = { materials = { maelstrom_core = { 4, 6 }, thunder_pearl = { 6, 8 }, storm_glass = { 8, 12 } } },
	-- Authority only: this model is hidden the moment it rises
	-- (CreatureService.Fn.hideColossusModel, and KrakenBodyController hides it a
	-- second time at adopt as a belt) and the octopus the fight draws comes out of
	-- KrakenPack instead. Nothing about the fields below is ever seen.
	--
	-- `scale` IS STILL LOAD-BEARING and it is NOT the draw scale: it is what
	-- Fn.updateBoss multiplies the row's hitRadius by, so 200 x 1.4 = the 280-stud
	-- capture sphere the Bosses row's hitRadius note is written against. It has
	-- nothing to do with KrakenPath.SCALE (6.0, the pack's authored draw scale) -
	-- an earlier comment here claimed the two tracked each other, which was never
	-- true of 1.4 and would, if anyone had "fixed" it, have quadrupled the sphere
	-- a shot has to reach.
	--
	-- `species` is the PRE-REWORK mantle in CreaturePack (creatures_gen.py's
	-- Kraken_Body/_Fins/_Eyes/_Marks) and `shape` the procedural serpent that
	-- stands in if that species is ever dropped from the pack. Neither is drawn;
	-- both are kept because an unbuildable row is a crash and a hidden one is not.
	body = {
		model = "CreaturePack",
		species = "Kraken",
		shape = "leviathan",
		stance = "upright",
		scale = 1.4, -- hitRadius multiplier, NOT KrakenPath.SCALE
		color = Color3.fromRGB(33, 20, 51), -- deep dark purple, the octopus hide
		finColor = Color3.fromRGB(51, 33, 77), -- the lighter underside and arm crown
		markColor = Color3.fromRGB(150, 120, 255), -- storm-lit eyes and suckers
	},
}

-- ============================================================ hermit-saga minibosses
--
-- The three quest ELITES (2026-08-29). Each is the payoff of one hermit
-- islet's multi-chapter saga: sail out, meet the hermit, kill the named
-- thing, carry its key item home, craft the rod it unlocks.
--
-- They are NOT bosses: no `archetype = "boss"`, no Bosses.luau entry with an
-- arena and a heart, no `rarity = "Boss"`. They are ordinary rows on the kit
-- engine wound up hard - health above their band's Legendary chase fish and
-- far under its island boss, a full four-or-five-move book, and a gimmick
-- each. Health/rewards are keyed to the TTK re-curve in docs/revamp-plan.md,
-- one saga per late stretch of the voyage: ice (L15-21), gloom (L29-35),
-- wreck (L36-42).
--
-- Each carries `waters` so it stays in its own band's pool - a row without
-- one is an OCEAN row and would roll off the starter cove, which would put a
-- 14,000-HP gulper in front of a level-3 player.
--
-- Each DROPS its key item as { 1, 1 } - a range whose minimum is 1, which is
-- how MaterialService expresses "guaranteed" (it rolls uniformly in the
-- band, so a band of exactly one is a certainty). These are quest gates, not
-- luck rolls.

-- The Drowned Bell (hermit: bellkeeper_odd). It swallowed the clapper out of
-- the Drowned Chapel's bell and carried it north under the ice shelf, and it
-- has been ringing ever since. Huge, slow, and patient: a devouring lunge that crosses half the
-- beach, and a toll that comes out of it as a shockwave. `harden` is the
-- lesson - swinging into those long windups does almost nothing, and the
-- gulp's wide expose window is where the fight is actually won.
Creatures.items.tollmaw = {
	id = "tollmaw",
	name = "Tollmaw",
	rarity = "Epic",
	archetype = "rusher",
	-- BAND SWAP 2026-09-12 (quest-reach audit). It was the WRECK band's elite
	-- (14,000 HP, waters "wreck"), which put Bellkeeper Odd - on the chapel
	-- islet, first sailable L8 - behind Wreckwater's L36 gate and left his
	-- saga dead for ~30 levels. It is the ICE band's elite now (L15-21,
	-- Frostmaw's ice-holes, one of that pool's three Epics exactly as the Moth
	-- is one of the gloom's), and Old Ribbonjaw took these wreck numbers in
	-- exchange. Only the band moved: name, kit, model, lore and the guaranteed
	-- bell_clapper are its own.
	health = 3800,
	waters = "ice",
	rewards = { coins = { 1100, 1700 }, xp = 2800 },
	drops = {
		materials = {
			bell_clapper = { 1, 1 }, -- the quest gate: guaranteed
			everice = { 1, 2 },
			rime_pelt = { 2, 4 },
		},
	},
	moves = {
		{
			name = "gulp",
			handler = "lunge",
			windup = 1.4, -- enormous tell; `harden` makes interrupting it a mistake
			duration = 0.45,
			recover = 1.0,
			cooldown = 6.5,
			damage = { 38, 60 }, -- x BAND (see contactDamage)
			reach = 18,
			hop = 3.5,
			radius = 9,
			cone = math.rad(55),
			range = 26,
			expose = 1.4, -- the whole fight: bait the gulp, punish the miss
			tell = "snap",
			skin = "frost",
		},
		{
			name = "toll",
			handler = "ringpulse",
			windup = 1.8,
			duration = 1.6,
			recover = 1.2,
			cooldown = 11.0,
			damage = { 30, 47 }, -- x BAND
			radius = 34, -- the band sweeps outward; step across it or outrun it
			ringWidth = 6,
			tell = "burst",
			skin = "frost",
		},
		{
			name = "swallow",
			handler = "pull",
			windup = 1.1,
			duration = 0.9,
			recover = 0.5,
			cooldown = 12.0,
			damage = { 0, 0 }, -- the drag itself doesn't bite; the gulp it feeds does
			radius = 30,
			strength = 34,
			range = 34,
			follow = "gulp", -- dragged into the maw, then swallowed
			tell = "pull",
			skin = "frost",
		},
		{
			name = "deadtoll",
			handler = "ringpulse",
			windup = 1.6,
			duration = 0.9,
			recover = 1.0,
			cooldown = 14.0,
			damage = { 41, 63 }, -- x BAND
			radius = 30,
			safeRadius = 9,
			invert = true, -- the SAFE spot is under it - the ringTell says so
			below = 0.5, -- the bell's second half, once it is truly hurt
			skin = "frost",
		},
	},
	gimmick = { kind = "harden", mult = 0.3 },
	tuning = { SHAMBLE_SPEED = 6, STANDOFF = 9, TURN_RATE_DEG = 90 },
	-- BAND = 0.55, the one factor the band swap applied to every damage number
	-- in this row (2026-09-12). It is the ice band's contact figure over the
	-- wreck band's - {26,40} -> {14,22} - and the elite ladder the three hermit
	-- elites form is per-HIT, not per-second: what separates the bands is how
	-- much of a player's bar one landed blow takes, and a 110-damage gulp at
	-- L15 is a different game from the same gulp at L38. Cadence, tells,
	-- reaches and radii are the fight's own language and did NOT scale.
	contactDamage = { 14, 22 },
	attackGap = { 2.2, 3.2 }, -- ponderous: slower than the Epic default
	body = {
		model = "CreaturePack",
		species = "GulperEel",
		shape = "gulletcod",
		stance = "upright",
		scale = 3.2,
		color = Color3.fromRGB(58, 72, 66), -- drowned bronze
		finColor = Color3.fromRGB(96, 120, 104),
		markColor = Color3.fromRGB(150, 220, 186), -- verdigris, where the bell rubbed
	},
}

-- The Saltmother's Price (hermit: saltmother_vess). A ribbon of an eel that
-- works the wrecks of the bay and robs anything that walks over them. Its whole
-- identity is theft, so it runs the THIEF archetype as its kit locomotion:
-- it closes, takes coins off you on contact, and bolts. Killing it pays the
-- haul back with THIEF_BONUS on top (ProgressionService) - that IS "make it
-- give it back", already wired, no new code. `phasey` and a hit-and-run book
-- make catching it the hard part.
Creatures.items.old_ribbonjaw = {
	id = "old_ribbonjaw",
	name = "Old Ribbonjaw",
	rarity = "Epic",
	archetype = "thief",
	-- BAND SWAP 2026-09-12 (quest-reach audit). It was the ICE band's elite
	-- (3,800 HP, waters "ice"), while its hermit Saltmother Vess lives on the
	-- Whale Fall, which is not sailable until L36 - the whole saga was gated
	-- 20 levels above the thing it hunts. It holds the WRECK band now (L36-42,
	-- Wreckwater's bay) and Tollmaw took the ice numbers. Only the band moved:
	-- the theft kit, model, lore and the guaranteed whetstone_heart are its own.
	health = 14000,
	waters = "wreck",
	rewards = { coins = { 5200, 7800 }, xp = 12000 },
	drops = {
		materials = {
			whetstone_heart = { 1, 1 }, -- the quest gate: guaranteed
			ghost_plank = { 2, 4 },
			tarnished_doubloon = { 3, 5 },
		},
	},
	-- The full thief updater walks it between moves: chase, pickpocket on
	-- contact, zigzag away. Its built-in steal runs as part of the kit.
	movement = "thief",
	moves = {
		{
			name = "ribbonlash",
			handler = "snap",
			windup = 0.4,
			duration = 0.25,
			recover = 0.3,
			cooldown = 2.4,
			damage = { 40, 62 }, -- x BAND (see contactDamage)
			lunge = 7,
			radius = 7,
			cone = math.rad(75),
			range = 14,
			tell = "snap",
			skin = "wreck",
		},
		{
			name = "cutandrun",
			handler = "lunge",
			windup = 0.5,
			duration = 0.3,
			recover = 0.35,
			cooldown = 4.0,
			damage = { 47, 71 }, -- x BAND
			reach = 20,
			hop = 2.0,
			radius = 6,
			cone = math.rad(50),
			range = 26,
			follow = "vanish", -- cut, then gone before you can answer
			tell = "snap",
			skin = "wreck",
		},
		{
			name = "vanish",
			handler = "phantom",
			windup = 0.5,
			duration = 0.9,
			recover = 0.5,
			cooldown = 7.0,
			damage = { 53, 81 }, -- x BAND
			emergeAt = 6,
			radius = 7,
			cone = 70, -- phantom takes DEGREES, unlike snap/lunge
			weight = 0, -- follow-only: the back half of cutandrun
			skin = "wreck",
		},
		{
			name = "brinecoil",
			handler = "snaretrap",
			windup = 0.7,
			duration = 0.3,
			recover = 0.4,
			cooldown = 9.0,
			damage = { 28, 43 }, -- x BAND
			arm = 1.0, -- the window to step off the mark
			radius = 6,
			snare = 1.6, -- rooted: this is how it gets paid
			tell = "mark",
			skin = "wreck",
		},
	},
	gimmick = { kind = "phasey", hits = 3, gap = 0.8, hop = 14 },
	tuning = { TURN_RATE_DEG = 320 },
	-- BAND = 1.55, the one factor the band swap applied to every damage number
	-- in this row (2026-09-12), and deliberately NOT the 1.82 that the two
	-- bands' contact figures ({14,22} -> {26,40}) would give: this thing swings
	-- every 0.9-1.5s where the elite those wreck numbers came from swings every
	-- 2.2-3.2s, so the honest full step would have handed the band an elite of
	-- roughly twice its own DPS. 1.55 puts each hit at the low end of the
	-- band's per-hit language and leaves the harasser ahead on the clock, which
	-- is what a thief should be. Cadence, tells, reaches and radii unscaled.
	contactDamage = { 22, 34 }, -- the contact is the robbery, not the wound
	attackGap = { 0.9, 1.5 }, -- busier than the Epic default: it never settles
	body = {
		model = "CreaturePack",
		species = "PhantomMoray",
		shape = "skipper",
		scale = 2.0,
		color = Color3.fromRGB(198, 206, 210), -- salt-bleached hide
		finColor = Color3.fromRGB(150, 172, 186),
		markColor = Color3.fromRGB(96, 214, 236), -- the cold running down its ribbon
	},
}

-- The Lampwright's Debt (hermit: lampwright). It comes for the lamp, every
-- night, and one night it will take it. Fought in the ring of light the
-- Lampwright keeps burning, so the whole book is a light motif: the glare it
-- throws off its own wings, the burning scales it sheds, and the flight
-- INTO the lamp that a moth cannot help. `drifter` locomotion gives it the
-- hover-and-bob that reads as flight; `deathburst` is the scales going up
-- all at once when it finally falls.
Creatures.items.moth_of_the_deep = {
	id = "moth_of_the_deep",
	name = "Moth of the Deep",
	rarity = "Epic",
	archetype = "drifter",
	health = 9500,
	waters = "gloom",
	rewards = { coins = { 3200, 4800 }, xp = 7500 },
	drops = {
		materials = {
			unburnt_wick = { 1, 1 }, -- the quest gate: guaranteed
			lantern_gland = { 2, 3 },
			gloom_scale = { 4, 6 },
		},
	},
	movement = "drifter", -- hovers, bobs, floats up when hit
	moves = {
		{
			name = "wingbeat",
			handler = "gustpush",
			windup = 0.9,
			duration = 0.35,
			recover = 0.5,
			cooldown = 5.5,
			damage = { 40, 62 },
			radius = 22,
			cone = math.rad(60),
			push = 78, -- shoved out of the light, which is the point
			lift = 14,
			range = 24,
			tell = "gustTell",
			skin = "lure",
		},
		{
			name = "scalefall",
			handler = "mortar",
			windup = 1.0,
			duration = 0.4,
			recover = 0.6,
			cooldown = 8.0,
			damage = { 44, 68 },
			count = 5,
			spread = 12,
			delay = 1.1, -- tell-to-hit: the scales drift down slowly
			stagger = 0.22,
			aim = "player",
			radius = 6,
			tell = "mark",
			skin = "lure",
		},
		{
			name = "lampglare",
			handler = "beam",
			windup = 1.1,
			duration = 1.5,
			recover = 0.9,
			cooldown = 12.0,
			damage = { 16, 24 }, -- per tick; standing in it hurts, it doesn't shred
			sweep = 140, -- degrees swept over the strike
			cone = 16, -- degrees, half-angle
			range = 40,
			tick = 0.3,
			radius = 40, -- the coneTell's reach (the beam itself reads `range`)
			tell = "coneTell",
			skin = "lure",
		},
		{
			name = "candleflight",
			handler = "lunge",
			windup = 0.6,
			duration = 0.4,
			recover = 0.7,
			cooldown = 6.0,
			damage = { 38, 58 },
			reach = 26,
			hop = 6.0,
			radius = 7,
			cone = math.rad(60),
			range = 30,
			expose = 1.1, -- it flies into the light and cannot stop itself
			tell = "snap",
			skin = "lure",
		},
		{
			name = "mothstorm",
			handler = "decoys",
			windup = 1.0,
			duration = 0.4,
			recover = 0.6,
			cooldown = 14.0,
			damage = { 30, 46 },
			count = 4,
			spread = 16,
			trigger = 5, -- drifting lights that go off when you come near
			blast = 8,
			lifetime = 9,
			drift = 6,
			below = 0.45, -- the last of its scales, thrown all at once
			skin = "lure",
		},
	},
	gimmick = { kind = "deathburst", radius = 16, damage = { 55, 85 } },
	tuning = { TURN_RATE_DEG = 260 },
	contactDamage = { 20, 32 },
	attackGap = { 1.3, 2.1 },
	body = {
		model = "CreaturePack",
		species = "DreadDragonfly",
		shape = "ray",
		scale = 2.6,
		color = Color3.fromRGB(76, 66, 88), -- dust-grey body
		finColor = Color3.fromRGB(206, 196, 172), -- pale, powdery wings
		markColor = Color3.fromRGB(255, 214, 120), -- lantern-gold eyespots
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
