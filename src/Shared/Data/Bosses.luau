--!nonstrict
-- Bosses.luau
-- The island bosses, as data. One boss per island; beating it is what opens
-- travel to the next island (WorldService.handleTeleport checks the
-- `Cleared_<islandId>` Player attribute BossService sets).
--
-- A boss is a creature row (Creatures.luau, archetype "boss", rarity "Boss"
-- so it can never roll from a cast) plus this entry, which carries
-- everything the fight needs: who may summon it (`gate` - checked when a
-- cast with the island's capstone bait calls BossService.summonFor), where
-- it rises (`arena`, relative to its island), and its attack book. CreatureService's boss
-- archetype is generic - it reads `phases` to decide which attacks are on
-- the table at the current health fraction and `attacks` for each one's
-- numbers - so a second island's boss is another entry here with a
-- different mix, not new engine code.
--
-- An attack's engine behaviour is `handler` (CreatureService.BOSS_ATTACKS);
-- without one, the attack's NAME is the handler - Brinejaw's original book
-- works that way. The primitives (each parameterized per boss, so no two
-- islands' movesets share numbers, patterns, or skins):
--   snap       lunges forward and bites (a cone in front)
--   tail       lashes the whole body round (a ring)
--   volley     spits a fan of globs that land around the player
--   slam       rears up and crashes down: a shockwave ring
--   pull       drags players toward the maw for its duration
--   brood      coughs up minions (other creature rows)
--   dive       submerges, tunnels under the player, ring tell, bursts up
--              (`shatter` leaves a lingering pool at the burst)
--   spines     rains a volley of spines around the player
--   charge     rushes a line (leap / landing slam / hazard trail options)
--   beam       a sustained jet swept across an arc
--   poolvolley volley whose globs leave lingering hazard pools
--   barrage    telegraphed ground strikes in a pattern: scatter / everyone /
--              line (+fan) / wall / rings (expanding annulus novas)
--   snaretrap  marks every player's feet; whoever stays is rooted
--   decoys     glowing lures / drifting mines that blow on proximity
--   phantom    lights-out vanish, re-emerges at a flank mid-bite
--   undertow   a long arena-wide drag while wreckage rains
--   anchortoss hurls an anchor that CHAINS whoever it lands on to the spot
-- Every attack has windup (the tell) / duration / recover times, its own
-- cooldown, and its damage range; `tell` borrows a stock telegraph shape,
-- `skin` colors the client's effects per island; enrage (below
-- `enrageBelow` health) shortens cooldowns and raises damage.

local Bosses = {}

export type Gate = {
	level: number,
	rod: string?, -- a Rods id the player must own (optional)
	weapon: string?, -- a Weapons id the player must own (optional)
}

export type Boss = {
	id: string,
	name: string, -- the full title, for the HUD bar and banner
	shortName: string, -- for the travel menu's refusal ("Defeat Brinejaw first")
	creature: string, -- Creatures.luau row id
	islandId: string, -- Islands.luau id it guards
	gate: Gate,
	arena: { offset: Vector3, radius: number }, -- centre relative to the island's worldPosition (Y ignored), and how far it roams
	aggro: number, -- starts attacking a player within this, studs
	standoff: number, -- prowls no closer than this to a player, studs
	hitRadius: number?, -- how far its hide reaches from the pivot at scale 1; subtracted from melee distance
	submerge: number, -- how far below its resting height it sits in the water, studs
	riseDepth: number, -- where it starts the intro rise from, studs below
	riseTime: number,
	speed: number, -- prowl speed, studs/second
	turnRate: number, -- radians/second
	attackGapMin: number, -- pause between attacks, seconds
	attackGapMax: number,
	enrageBelow: number, -- health fraction
	enrageCooldownMult: number,
	enrageDamageMult: number,
	phases: { { below: number, attacks: { string } } },
	attacks: { [string]: { [string]: any } },
}

Bosses.items = {} :: { [string]: Boss }

-- ============================================================ Starter Cove
-- Brinejaw: a colossal drowned anglerfish-leviathan that rises out of the
-- water off the end of the dock. Armoured head, a maw of fangs, a lure on a
-- stalk, sail fins, a lashing tail. Three phases: bites and sweeps, then it
-- starts luring, spawning brood and diving, then it enrages and rains spines.
Bosses.items.brinejaw = {
	id = "brinejaw",
	name = "Brinejaw, the Drowned Leviathan",
	shortName = "Brinejaw",
	creature = "brinejaw",
	islandId = "tropical",
	-- Summoned by casting the Leviathan's Call bait (itself Lv 7 and crafted
	-- from the cove's signature drops), so the bait IS the gear gate: no
	-- rod/weapon requirement. Starter Cove is L1-7 and Brinejaw is its
	-- band-end capstone.
	gate = { level = 7 },

	-- ---------------------------------------------------------- the colossus
	--
	-- REDESIGNED 2026-08-29 (user: the bosses should be huge set-pieces you
	-- outthink, "not just running at the boss aimlessly and attacking and
	-- brute forcing"). Brinejaw no longer swims at anybody. It is coiled
	-- three times around the Tidebreak Spire in its own lair arena
	-- (BossArenas.tropical), and it fights by UNWINDING: the coils and the
	-- sweeping tail are one chain, so an attack re-poses the body rather
	-- than spawning anything (Shared/Modules/BrinejawPath).
	--
	-- The loop, and the grammar every later boss speaks harder:
	--   1. survive a pattern - low sweeps are JUMPED, high sweeps are STOOD
	--      UNDER, and reading which is coming is the whole dodge;
	--   2. earn the opening - bait a tail slam onto one of the arena's three
	--      REEF STONES. Sand absorbs the blow; rock does not, and the rattle
	--      cracks against it;
	--   3. spend it - the serpent loses its grip and its head comes down on
	--      the sand, targetable and Exposed, for `stagger` seconds. That is
	--      the ONLY time it can be hurt at all.
	-- Each stone shatters as it is spent, so a wasted bait costs something
	-- real; the fight stays winnable without them (a slam on bare sand still
	-- staggers it briefly - see `weakStagger`).
	--
	-- `stances = 3` is its three coils: every health phase it loses, the
	-- whole stack slides one turn down the tower, which drops the head lower
	-- and makes each window a little easier to reach - the fight literally
	-- comes down to you.
	entrenched = true,
	pose = "brinejaw",
	stances = 3,

	-- The old roam disc, kept because arena.offset is still the fallback
	-- spawn for an island with no lair row. Entrenched bosses never roam.
	arena = { offset = Vector3.new(0, 0, 210), radius = 28 },
	-- The head perches ~60 studs up, so "in the arena at all" has to count as
	-- aggro range; standoff and speed are dead numbers for a colossus.
	aggro = 220,
	standoff = 0,
	hitRadius = 8, -- the slumped head is a big target during a window
	submerge = 0,
	riseDepth = 0,
	riseTime = 4.2, -- the wake: the head lifts out of its slump, coils grind
	speed = 0,
	turnRate = math.rad(70),
	attackGapMin = 1.5,
	attackGapMax = 2.6,
	enrageBelow = 0.3,
	enrageCooldownMult = 0.6,
	enrageDamageMult = 1.35,

	-- Phase = coil. Sweeps arrive in pairs from the second coil down, and the
	-- third opens with CONSTRICT: a slow, near-full-circle high sweep with a
	-- fast low one chasing it.
	phases = {
		{ below = 1.0, attacks = { "sweeplow", "sweephigh", "tailslam", "rubble" } },
		{ below = 0.66, attacks = { "sweeplow", "sweephigh", "tailslam", "rubble", "sweeppair" } },
		{
			below = 0.33,
			attacks = { "sweeplow", "sweephigh", "tailslam", "sweeppair", "constrict", "rubble" },
		},
	},

	attacks = {
		-- Jump it. 2.6 s for ~340 degrees is a wave you can see coming from
		-- anywhere on the ring, which is the point at a level-7 capstone.
		sweeplow = {
			handler = "orbitsweep",
			tell = false, -- fires serpentSweep from its own windup instead
			windup = 1.5,
			duration = 2.6,
			recover = 1.0,
			cooldown = 5.0,
			arc = math.rad(340),
			girth = 3.4,
			damage = { 38, 55 },
		},
		-- Stand still. Panic-jumping this is how the cove teaches height.
		sweephigh = {
			handler = "orbitsweep",
			high = true,
			tell = false, -- fires serpentSweep from its own windup instead
			windup = 1.6,
			duration = 2.4,
			recover = 1.0,
			cooldown = 5.5,
			arc = math.rad(320),
			girth = 3.6,
			damage = { 40, 58 },
		},
		-- Low, then immediately high: jump, land, hold. The follow chains it.
		sweeppair = {
			handler = "orbitsweep",
			tell = false, -- fires serpentSweep from its own windup instead
			windup = 1.2,
			duration = 2.2,
			recover = 0.5,
			cooldown = 9.0,
			arc = math.rad(300),
			girth = 3.4,
			damage = { 38, 55 },
			follow = "sweephigh",
		},
		-- The opening. Long windup on purpose: the bait is a decision, not a
		-- reaction - you have to be STANDING at a stone when it lands.
		tailslam = {
			handler = "tailslam",
			tell = false, -- fires serpentSlam at the real impact point instead
			windup = 1.9,
			duration = 0.85,
			recover = 1.1,
			cooldown = 8.0,
			radius = 13,
			lift = 9,
			stoneReach = 11, -- how near a stone the blow has to land
			stagger = 8.0, -- the punish window a stone buys
			weakStagger = 2.2, -- sand only jars it: winnable, never the plan
			damage = { 52, 74 },
		},
		-- Masonry knocked off the tower by the grinding coils.
		rubble = {
			handler = "volley",
			tell = "burst",
			windup = 0.8,
			duration = 1.0,
			recover = 0.6,
			cooldown = 6.0,
			count = 6,
			spread = 22,
			flight = 1.1,
			stagger = 0.14,
			radius = 8,
			damage = { 20, 30 },
		},
		-- Phase 3: the squeeze. A slow high sweep all the way round with a
		-- low one chasing it, so the safe answer changes mid-move.
		constrict = {
			handler = "orbitsweep",
			high = true,
			tell = false, -- fires serpentSweep from its own windup instead
			windup = 1.8,
			duration = 4.4,
			recover = 0.6,
			cooldown = 14.0,
			arc = math.rad(400),
			girth = 3.8,
			damage = { 44, 62 },
			follow = "sweeplow",
		},
	},
}

-- ============================================================ Ashfall Caldera
-- Pyrelisk, the Caldera Wyrm: an obsidian-scaled magma serpent that rises
-- out of the boiling shallows off the shore jetty (the ponds move with every
-- mesh regen, so the arena sits in the sea off the dock - the one spot the
-- generator keeps stable). Summoned by casting Caldera's Call (Bait.luau).
-- Its fight is HEAT MANAGEMENT: lava-wake charges, hardening slag pools and
-- summit vent-storms burn the standable ground away all fight (see the
-- phases block). Tuned for the FINAL slot-4 band (L22-28, ~40k HP on the
-- creature row; docs/revamp-plan.md).
Bosses.items.pyrelisk = {
	id = "pyrelisk",
	name = "Pyrelisk, the Caldera Wyrm",
	shortName = "Pyrelisk",
	creature = "pyrelisk",
	islandId = "volcano",
	-- The bait is the gate, as with Brinejaw: level only, matching Caldera's
	-- Call's own recipe level (the volcano band's end).
	gate = { level = 28 },
	-- Off the END of the shore jetty: the dock STARTS at r~527 on +Z and its
	-- planks run 110 studs seaward to r~637 (island_gen.py volcano overrides),
	-- so the arena centre sits at 680 - the whole roam disc (Z 650-710) is
	-- open sea past the last plank, and it hauls itself TOWARD the deck the
	-- way Brinejaw does. (The 2026-08-25 review caught the original 590, which
	-- put the fight underneath the jetty's mid-span.)
	-- Keyed to the dock (walk-room re-key 2026-08-28; HANDOFF: planks run
	-- rel Z=532..597 on the +Z lane): the arena centre sits 40 studs of open
	-- sea past the last plank, fought from the dock end exactly like
	-- Brinejaw's - stable because the dock bearing/length are pinned
	-- overrides, not sampled geometry.
	arena = { offset = Vector3.new(0, 0, 637), radius = 30 },
	aggro = 90,
	standoff = 14,
	hitRadius = 6, -- at scale 1, pivot to the jaw; x1.5 = 9, matching Brinejaw's frame
	submerge = 2.4,
	riseDepth = 18,
	riseTime = 3.8,
	speed = 8,
	turnRate = math.rad(80),
	attackGapMin = 0.7,
	attackGapMax = 1.3,
	enrageBelow = 0.3,
	enrageCooldownMult = 0.55,
	enrageDamageMult = 1.4,
	-- THE FIGHT: heat management. Everything Pyrelisk does sets the arena on
	-- fire - the wake of its charge, its spit, the summit's vent-storms -
	-- so the space you can stand in shrinks all fight and the dodge is
	-- always "where WON'T be burning in two seconds". The magmajet beam
	-- sweeps you across whatever ground is left.
	phases = {
		{ below = 1.0, attacks = { "maul", "slagspit", "lavawake" } },
		{ below = 0.6, attacks = { "maul", "slagspit", "lavawake", "magmajet", "ventstorm" } },
		{ below = 0.3, attacks = { "maul", "lavawake", "magmajet", "ventstorm", "cinderring", "cinderring" } },
	},
	attacks = {
		-- The obsidian jaws: fast, short, its melee punish.
		maul = {
			handler = "snap",
			tell = "snap",
			skin = "lava",
			windup = 0.7,
			duration = 0.35,
			recover = 0.55,
			cooldown = 1.8,
			lunge = 14,
			radius = 17,
			cone = math.rad(65),
			damage = { 60, 85 },
		},
		-- Magma spit whose globs harden into burning pools where they land.
		slagspit = {
			handler = "poolvolley",
			skin = "lava",
			windup = 0.7,
			duration = 0.9,
			recover = 0.5,
			cooldown = 5.5,
			count = 4,
			spread = 11,
			flight = 1.0,
			stagger = 0.18,
			radius = 7,
			damage = { 22, 32 },
			pool = { radius = 6.5, duration = 6.5, min = 8, max = 12, skin = "lava" },
		},
		-- The signature: it surges across the shallows in a straight line and
		-- its wake IS lava - a burning fence laid straight through the arena.
		lavawake = {
			handler = "charge",
			skin = "lava",
			windup = 1.0,
			duration = 1.1,
			recover = 0.8,
			cooldown = 6.5,
			length = 36,
			width = 10,
			damage = { 58, 80 },
			trail = { every = 7, radius = 6.5, duration = 7, min = 10, max = 14, skin = "lava" },
		},
		-- Rears up and hoses a magma jet across a 120-degree arc; run WITH
		-- the sweep or eat ticks.
		magmajet = {
			handler = "beam",
			skin = "lava",
			windup = 0.9,
			duration = 2.2,
			recover = 0.7,
			cooldown = 8.0,
			sweep = 120,
			cone = 16,
			range = 30,
			tick = 0.3,
			damage = { 12, 16 },
		},
		-- The mountain answers: the summit rains bombs on marked rings - one
		-- under every player plus a scatter, arena-wide.
		ventstorm = {
			handler = "barrage",
			skin = "lava",
			windup = 0.8,
			duration = 2.2,
			recover = 0.6,
			cooldown = 10.0,
			pattern = "everyone",
			extra = 2,
			spread = 12,
			arm = 1.2,
			radius = 7,
			damage = { 40, 55 },
		},
		-- Concentric fire novas detonating outward from its body: step across
		-- a band before it blows, or stand in the gaps.
		cinderring = {
			handler = "barrage",
			skin = "lava",
			windup = 1.2,
			duration = 2.2,
			recover = 0.7,
			cooldown = 9.0,
			pattern = "rings",
			rings = { 9, 16, 24, 32 },
			ringWidth = 5,
			interval = 0.5,
			arm = 0.55,
			damage = { 42, 58 },
		},
	},
}

-- ============================================================ Blackmire Fen
-- Old Gnashroot, the Fen Tyrant: a moss-backed snapping horror - half gator,
-- half drowned oak - that heaves out of the arena pond in the fen's heart.
-- Summoned by casting Tyrant's Call (Bait.luau). Its fight is THE FEN
-- GRABBING YOU: root snares spring under your feet, its death-roll churns
-- the peat into clinging sludge, and root-spear waves march the banks - the
-- whole island is its body, and standing still is what kills you.
Bosses.items.old_gnashroot = {
	id = "old_gnashroot",
	name = "Old Gnashroot, the Fen Tyrant",
	shortName = "Old Gnashroot",
	creature = "old_gnashroot",
	islandId = "swamp",
	-- The bait is the gate, as always: level only, the fen band's end.
	gate = { level = 14 },
	-- The fen's interior boss mere: the swamp-restart marsh step authors its
	-- biggest pool AT this arena spot (step-3 HANDOFF: mere rel X=0 Z=74
	-- r=26 - the roam disc reaches a few studs onto the banks by design).
	-- It rises out of the peat murk in the island's heart, fought from the
	-- banks. Re-key from the swamp HANDOFF line after any marsh relayout.
	arena = { offset = Vector3.new(0, 0, 74), radius = 36 },
	aggro = 90,
	standoff = 14,
	hitRadius = 6, -- at scale 1, pivot to the jaws; x1.5 = 9, the Brinejaw frame
	submerge = 2.4,
	riseDepth = 18,
	riseTime = 3.8,
	speed = 7.5,
	turnRate = math.rad(78),
	attackGapMin = 0.7,
	attackGapMax = 1.35,
	enrageBelow = 0.3,
	enrageCooldownMult = 0.55,
	enrageDamageMult = 1.4,
	-- THE FIGHT: mobility denial. The snares root you, the sludge slows you,
	-- and everything that actually hurts - the death-roll, the root wave -
	-- is dodged by moving. Get grabbed at the wrong beat and the next thing
	-- through is what kills you.
	phases = {
		{ below = 1.0, attacks = { "gnash", "deathroll", "bogspit" } },
		{ below = 0.65, attacks = { "gnash", "deathroll", "bogspit", "rootwave", "snaretrap" } },
		{ below = 0.3, attacks = { "gnash", "deathroll", "rootwave", "rootwave", "snaretrap", "bogspit" } },
	},
	attacks = {
		-- The old jaws: its close-range punish.
		gnash = {
			handler = "snap",
			tell = "snap",
			skin = "peat",
			windup = 0.75,
			duration = 0.35,
			recover = 0.55,
			cooldown = 1.8,
			lunge = 13,
			radius = 16,
			cone = math.rad(65),
			damage = { 58, 82 },
		},
		-- The gator classic, island-sized: it throws itself into a rolling
		-- charge across the pond, and the churned peat it leaves behind is a
		-- clinging sludge lane that slows anyone wading it.
		deathroll = {
			handler = "charge",
			skin = "peat",
			windup = 1.0,
			duration = 1.1,
			recover = 0.85,
			cooldown = 6.0,
			length = 34,
			width = 10,
			damage = { 55, 76 },
			trail = { every = 7, radius = 6.5, duration = 6, min = 5, max = 8, slow = 0.55, skin = "peat" },
		},
		-- Lobbed gouts of peat that linger as sucking sludge pools.
		bogspit = {
			handler = "poolvolley",
			skin = "peat",
			windup = 0.7,
			duration = 0.8,
			recover = 0.5,
			cooldown = 5.5,
			count = 3,
			spread = 10,
			flight = 1.0,
			stagger = 0.2,
			radius = 7,
			damage = { 20, 30 },
			pool = { radius = 7, duration = 6, min = 5, max = 9, slow = 0.5, skin = "peat" },
		},
		-- A rank of root-spears erupts from the murk and marches straight at
		-- you - sidestep the line, don't outrun it.
		rootwave = {
			handler = "barrage",
			skin = "root",
			windup = 0.9,
			duration = 1.6,
			recover = 0.6,
			cooldown = 6.5,
			pattern = "line",
			count = 7,
			spacing = 5.5,
			startAt = 8,
			interval = 0.16,
			arm = 0.5,
			radius = 5,
			damage = { 30, 44 },
		},
		-- ITS gimmick: grasping roots coil up under every player's feet -
		-- the ring is the escape window; whoever is still inside when they
		-- close is ROOTED to the spot while the fight keeps coming.
		snaretrap = {
			handler = "snaretrap",
			skin = "root",
			windup = 0.8,
			duration = 0.5,
			recover = 0.5,
			cooldown = 9.0,
			arm = 1.1,
			radius = 6,
			damage = { 24, 34 },
			snare = 1.7,
		},
	},
}

-- ============================================================ Frostmaw Reach
-- Rimefang, the Glacier Serpent: a white serpent that hunts UNDER the ice
-- sheet - its undersheet dive is the island's own ice-hole fishing turned
-- against you. Summoned by casting Glacier's Call. Its fight is THE COLD
-- ITSELF: the breath and the frost slicks it leaves everywhere chill you
-- slow, and a slowed player can't clear the bergfall rings or the shard
-- novas in time - warmth (distance) is the resource you manage.
Bosses.items.rimefang = {
	id = "rimefang",
	name = "Rimefang, the Glacier Serpent",
	shortName = "Rimefang",
	creature = "rimefang",
	islandId = "ice",
	-- Bait-gated like every boss: level only, matching Glacier's Call (the
	-- ice band's end).
	gate = { level = 21 },
	-- Open water off the end of the fishing dock (planks end at Z=238): it
	-- rises from the sea and hauls itself toward the sheet's edge, so the
	-- fight happens off the planks and the shorefast ice.
	arena = { offset = Vector3.new(0, 0, 268), radius = 28 },
	aggro = 90,
	standoff = 14,
	hitRadius = 6, -- x1.6 scale = 9.6, Brinejaw's frame
	submerge = 2.4,
	riseDepth = 18,
	riseTime = 3.8,
	speed = 8,
	turnRate = math.rad(80),
	attackGapMin = 0.65,
	attackGapMax = 1.25,
	enrageBelow = 0.3,
	enrageCooldownMult = 0.55,
	enrageDamageMult = 1.4,
	-- THE FIGHT: stay warm, stay moving. Chill stacks up from the breath and
	-- the slicks its hunts leave on the surface; the punishes (bergfall,
	-- shardnova) are generous to a full-speed player and lethal to a chilled
	-- one. The undersheet hunt is weighted double from phase 2 - the island's
	-- fishing holes, hunting back.
	phases = {
		{ below = 1.0, attacks = { "bite", "frostbreath", "breach" } },
		{ below = 0.65, attacks = { "bite", "frostbreath", "breach", "undersheet", "undersheet", "bergfall" } },
		{
			below = 0.3,
			attacks = { "bite", "frostbreath", "undersheet", "undersheet", "bergfall", "shardnova", "shardnova" },
		},
	},
	attacks = {
		-- The needle jaws.
		bite = {
			handler = "snap",
			tell = "snap",
			skin = "frost",
			windup = 0.7,
			duration = 0.35,
			recover = 0.55,
			cooldown = 1.8,
			lunge = 14,
			radius = 17,
			cone = math.rad(65),
			damage = { 58, 82 },
		},
		-- Rears up and breathes a freezing jet across an arc: modest damage,
		-- but everything it touches is CHILLED - and slow is how you die to
		-- the rest of the kit.
		frostbreath = {
			handler = "beam",
			skin = "frost",
			windup = 0.9,
			duration = 2.2,
			recover = 0.6,
			cooldown = 7.0,
			sweep = 100,
			cone = 18,
			range = 26,
			tick = 0.35,
			damage = { 9, 13 },
			chill = { mult = 0.55, duration = 1.4 },
		},
		-- Launches clear of the water and arcs across the arena - airborne
		-- mid-leap, then the crash-down ring; the wake it skids out is a
		-- frost slick that chills anyone crossing it.
		breach = {
			handler = "charge",
			skin = "frost",
			windup = 1.1,
			duration = 1.0,
			recover = 0.9,
			cooldown = 7.5,
			length = 40,
			width = 9,
			leap = 6,
			slamRadius = 12,
			damage = { 55, 78 },
			trail = { every = 8, radius = 6, duration = 6, slow = 0.5, skin = "frost" },
		},
		-- THE signature: it hunts under the ice sheet after your live
		-- position, bursts up through it, and the shattered surface stays
		-- behind as a chilling slick. Weighted double from phase 2.
		undersheet = {
			handler = "dive",
			tell = "dive",
			skin = "frost",
			windup = 0.6,
			duration = 2.4,
			lock = 0.8,
			recover = 0.9,
			cooldown = 6.0,
			speed = 36,
			radius = 13,
			damage = { 58, 82 },
			shatter = { radius = 9, duration = 5.5, slow = 0.5, skin = "frost" },
		},
		-- The glacier calves: bergs come down on marked rings around you -
		-- a long fall you can read, unless you're chilled.
		bergfall = {
			handler = "barrage",
			skin = "frost",
			windup = 0.8,
			duration = 2.0,
			recover = 0.6,
			cooldown = 8.0,
			pattern = "scatter",
			count = 5,
			spread = 15,
			arm = 1.3,
			radius = 8,
			damage = { 45, 62 },
		},
		-- Expanding rings of shattering ice detonate outward from its body:
		-- cross each band before it blows.
		shardnova = {
			handler = "barrage",
			skin = "frost",
			windup = 1.2,
			duration = 2.0,
			recover = 0.7,
			cooldown = 9.0,
			pattern = "rings",
			rings = { 10, 18, 26 },
			ringWidth = 5,
			interval = 0.55,
			arm = 0.55,
			damage = { 40, 56 },
		},
	},
}

-- ============================================================ Gloomtrench
-- Noctyss, the Trench Mother - and the one fight in the saga where you never
-- see the animal. What stands in the arena is her CHOIR: seven angler-lure
-- stalks up through the Choirfloor's sockets, her fingers through a torn
-- ceiling. She is underneath, and surfaces only to be punished.
--
-- THE LOOP, and every number below serves it:
--   1. READ. The choir runs light patterns in near-blackness. A swept beam
--      IS the damage - being lit is being hit - so the answer is the dark
--      behind a shadow fin, which also takes the arena away from you.
--   2. EARN. Exactly one stalk is the TRUE lure, and it breathes half a cycle
--      out of step with the rest (NoctyssPath.pulse). Break its lantern and
--      she flinches; break a false one and it flares white and something
--      comes out of the dark for whoever shot it.
--   3. PUNISH. The maw rises through the pit and hangs open. You climb into
--      her mouth and hit the lure-root at the back of her throat until the
--      jaw closes. Then the choir grows back, with a different true lure.
--
-- Ranged breaks the lure (the lantern is 35 studs up - `choir_stalk` is
-- rangedOnly); melee burns the gullet. Both halves of the kit, different
-- beats, which is the boss-redesign standard this fight was built to.
Bosses.items.noctyss = {
	id = "noctyss",
	name = "Noctyss, the Trench Mother",
	shortName = "Noctyss",
	creature = "noctyss",
	islandId = "gloom",
	gate = { level = 35 },
	-- She is a set-piece, not a prowler: the pose driver owns her body and
	-- the choir, and `speed = 0` means the arena's geometry can be trusted -
	-- the sockets, the pit and the shadow fins stay where the fight expects
	-- them. Drawn client-side by NoctyssBodyController off this pose.
	pose = "noctyss",
	-- Open water off the end of the dock, for the in-place fallback; the real
	-- fight is at the Choirfloor (BossArenas.gloom), whose socket ring the
	-- choir grows from.
	arena = { offset = Vector3.new(0, 0, 246), radius = 36 },
	-- THE CHOIR. Seven stalks on the arena's authored collars (`at` takes the
	-- offsets from the arena row's `sockets`, so they land in their sockets
	-- rather than on a guessed circle), one of them MARKED as the true lure.
	-- `window` is how long the maw stays open once the true lure breaks;
	-- `regrow` is the beat of dark before the choir comes back.
	parts = {
		row = "choir_stalk",
		count = 7,
		ring = 34,
		at = "sockets",
		mark = true,
		window = 12,
		regrow = 5,
	},
	aggro = 130,
	standoff = 0,
	hitRadius = 6, -- x2.4 scale = 14.4: the maw, when it is up
	submerge = 0,
	riseDepth = 24,
	riseTime = 4.5,
	speed = 0,
	turnRate = math.rad(50),
	attackGapMin = 1.1,
	attackGapMax = 2.0,
	enrageBelow = 0.3,
	enrageCooldownMult = 0.55,
	enrageDamageMult = 1.4,
	-- The choir escalates by what it is allowed to do, not by growing: seven
	-- collars, seven stalks, always. Stance 3 is the dark answering - the
	-- lanterns start going out between attacks.
	phases = {
		{ below = 1.0, attacks = { "lightsweep", "lightsweep", "strobewave", "lurepull", "feelerstrike" } },
		{
			below = 0.65,
			attacks = { "lightsweep", "strobewave", "lurepull", "feelerstrike", "falselight", "inkveil", "abysscall" },
		},
		{
			below = 0.3,
			attacks = {
				"lightsweep",
				"lightsweep",
				"strobewave",
				"lurepull",
				"falselight",
				"abysscall",
				"dousehunt",
				"dousehunt",
			},
		},
	},
	attacks = {
		-- THE SIGNATURE. One stalk leans onto a bearing and scythes its light
		-- across the shelf. The lit wedge is the hitbox, it ticks rather than
		-- landing once, and it comes FROM a stalk you can see leaning - so
		-- the tell, the attack and the thing you shoot are all one object.
		lightsweep = {
			handler = "lightsweep",
			skin = "lure",
			windup = 1.1,
			duration = 2.6,
			recover = 0.8,
			cooldown = 5.5,
			arc = math.rad(155),
			girth = 3.0,
			tick = 0.45,
			damage = { 32, 44 },
		},
		-- The whole choir flashes as one and each flash throws a ring
		-- outward. It is also the only time the arena is fully lit: the
		-- strobe is how you learn where anything is, and it is trying to
		-- kill you while it shows you.
		strobewave = {
			handler = "barrage",
			skin = "lure",
			windup = 0.95,
			duration = 2.0,
			recover = 0.6,
			cooldown = 10.0,
			pattern = "rings",
			rings = { 14, 26, 38 },
			ringWidth = 5,
			interval = 0.5,
			arm = 0.5,
			damage = { 38, 52 },
		},
		-- The true lure flares and hauls the arena toward the pit - toward
		-- the hole she is under. Chased by a feeler, so being dragged into
		-- the open is not survivable on its own.
		lurepull = {
			handler = "pull",
			tell = "pull",
			skin = "lure",
			windup = 0.7,
			duration = 2.2,
			recover = 0.4,
			cooldown = 11.0,
			radius = 70,
			strength = 42,
			follow = "feelerstrike",
		},
		-- Something comes out of the dark under everyone at once. Short arm:
		-- the punish for standing still after a pull.
		feelerstrike = {
			handler = "barrage",
			skin = "ink",
			windup = 0.6,
			duration = 1.2,
			recover = 0.5,
			cooldown = 2.2,
			pattern = "everyone",
			extra = 1,
			spread = 9,
			arm = 0.75,
			radius = 8,
			damage = { 46, 62 },
			hitEvent = "emerge",
		},
		-- Ink bursts blot the water AND the screen of anyone caught in one:
		-- the dark is her weapon even where there is light.
		inkveil = {
			handler = "barrage",
			skin = "ink",
			windup = 0.8,
			duration = 1.4,
			recover = 0.5,
			cooldown = 9.0,
			pattern = "scatter",
			count = 4,
			spread = 12,
			arm = 0.9,
			radius = 9,
			damage = { 30, 42 },
			hitEvent = "inkBlast",
			pool = { radius = 8, duration = 5, min = 7, max = 11, skin = "ink" },
		},
		-- HER OLDEST TRICK, and it survives the redesign intact: false lures
		-- drift the shelf looking exactly like the thing you are hunting.
		-- Now they have a second job - in an arena where you are trying to
		-- read one light's rhythm, three more lights is the attack.
		falselight = {
			handler = "decoys",
			skin = "lure",
			windup = 0.9,
			duration = 0.6,
			recover = 0.5,
			cooldown = 14.0,
			count = 3,
			spread = 22,
			trigger = 7,
			blast = 10,
			lifetime = 12,
			drift = 3.5,
			damage = { 45, 62 },
		},
		-- The trench answers: fans of grasping arms march out of the pit.
		abysscall = {
			handler = "barrage",
			skin = "ink",
			windup = 0.9,
			duration = 1.6,
			recover = 0.6,
			cooldown = 8.5,
			pattern = "line",
			fan = { -28, 0, 28 },
			count = 5,
			spacing = 6,
			startAt = 8,
			interval = 0.15,
			arm = 0.5,
			radius = 5,
			damage = { 34, 46 },
		},
		-- EVERY LANTERN GOES OUT AT ONCE. Real darkness, for `dark` seconds,
		-- and then a strike where you were standing when the lights died.
		-- The fight's best scare and its cheapest attack: it spawns nothing,
		-- it just stops being able to be seen by.
		dousehunt = {
			handler = "dousehunt",
			skin = "ink",
			windup = 0.5,
			dark = 1.6,
			duration = 2.4,
			recover = 0.7,
			cooldown = 13.0,
			pattern = "everyone",
			spread = 7,
			arm = 0.55,
			radius = 9,
			damage = { 54, 74 },
			hitEvent = "emerge",
		},
	},
}

-- ============================================================ Wreckwater
-- Admiral Wrack, the Fleet-Eater: the drowned admiral fused into his
-- flagship's bow. His fight is a NAVAL ENGAGEMENT: ranked broadside walls
-- march across the bay, powder kegs drift after you, his dead crew boards
-- over YOUR rail (the island's raid mechanic pointed back at you) - and his
-- gimmick is the fouled anchor: it lands where you stand and CHAINS you to
-- the spot while the next broadside walks in.
Bosses.items.admiral_wrack = {
	id = "admiral_wrack",
	name = "Admiral Wrack, the Fleet-Eater",
	shortName = "Admiral Wrack",
	creature = "admiral_wrack",
	islandId = "wreck",
	gate = { level = 42 },
	-- The bay at the island's centre: a single stable water sheet (unlike
	-- the shifting pools elsewhere), kept clear of the harbor channel that
	-- opens toward +Z.
	arena = { offset = Vector3.new(0, 0, -20), radius = 30 },
	aggro = 95,
	standoff = 15,
	hitRadius = 7, -- x2.0 scale = 14: half ship, after all
	submerge = 2.8,
	riseDepth = 22,
	riseTime = 4.2,
	speed = 7,
	turnRate = math.rad(70),
	attackGapMin = 0.6,
	attackGapMax = 1.2,
	enrageBelow = 0.3,
	enrageCooldownMult = 0.55,
	enrageDamageMult = 1.4,
	-- THE FIGHT: position like a sailor. Broadsides come in ranked walls you
	-- slip between, kegs herd you, the boarding party demands attention -
	-- and the anchor is the killer: chained in place, every one of those
	-- becomes unavoidable. Break line of the pattern before he throws it.
	phases = {
		{ below = 1.0, attacks = { "anchorbite", "broadside", "keelrush" } },
		{
			below = 0.6,
			attacks = { "anchorbite", "broadside", "keelrush", "anchortoss", "boarding", "boarding", "powderkeg" },
		},
		{
			below = 0.3,
			attacks = { "anchorbite", "broadside", "broadside", "anchortoss", "boarding", "powderkeg", "keelrush" },
		},
	},
	attacks = {
		-- He swings the fouled anchor like a jaw: slow, huge, his melee.
		anchorbite = {
			handler = "snap",
			tell = "snap",
			skin = "wreck",
			windup = 0.85,
			duration = 0.4,
			recover = 0.6,
			cooldown = 2.0,
			lunge = 14,
			radius = 18,
			cone = math.rad(65),
			damage = { 66, 92 },
		},
		-- The signature: a full cannon broadside in RANKED WALLS that march
		-- across the bay - each rank telegraphed, each a line you step
		-- between, the whole pattern herding you.
		broadside = {
			handler = "barrage",
			skin = "ember",
			windup = 0.9,
			duration = 2.2,
			recover = 0.6,
			cooldown = 8.0,
			pattern = "wall",
			ranks = 5,
			width = 26,
			rankSpacing = 7,
			startAt = 10,
			interval = 0.4,
			arm = 0.55,
			radius = 6,
			damage = { 40, 54 },
		},
		-- HIS gimmick: the anchor flies at where you stand, and whoever it
		-- lands on is CHAINED to the spot - a short leash off the anchor
		-- while the rest of the engagement keeps firing.
		anchortoss = {
			handler = "anchortoss",
			skin = "wreck",
			windup = 0.9,
			duration = 0.6,
			recover = 0.7,
			cooldown = 10.0,
			flight = 0.8,
			radius = 8,
			damage = { 50, 70 },
			leash = 13,
			chainDuration = 3.5,
		},
		-- The boarding party - the island's raids pointed back at you: his
		-- dead crew comes over YOUR rail. Weighted double in phase 2.
		boarding = {
			handler = "brood",
			tell = "brood",
			skin = "wreck",
			windup = 0.8,
			duration = 0.4,
			recover = 0.6,
			cooldown = 9.0,
			count = 4,
			rows = { "drowned_boatswain", "cannonball_crab", "wailing_gunner" },
		},
		-- Powder kegs roll off the hull and DRIFT AFTER YOU, fuses lit -
		-- shoot them, outrun them, or feed them to the boarding party.
		powderkeg = {
			handler = "decoys",
			skin = "ember",
			windup = 0.8,
			duration = 0.5,
			recover = 0.5,
			cooldown = 11.0,
			count = 4,
			spread = 16,
			trigger = 6,
			blast = 11,
			lifetime = 14,
			drift = 4.5,
			damage = { 50, 68 },
		},
		-- The flagship rams: he heels over and drives the bow through the
		-- arena in a line, bowsprit first.
		keelrush = {
			handler = "charge",
			skin = "wreck",
			windup = 1.05,
			duration = 1.0,
			recover = 0.9,
			cooldown = 7.0,
			length = 42,
			width = 12,
			slamRadius = 10,
			damage = { 62, 85 },
		},
	},
}

-- ============================================================ The Maelstrom
-- The Kraken, Maw of the Maelstrom: the saga's finale. The head is
-- rangedOnly and invulnerable while any tentacle stands (vulnerableWhen =
-- "partsDown"): the fight loops melee-the-tentacles -> guns-on-the-head
-- exposure windows -> regrow. Its OWN storm carries the rest: tentacles
-- erupt under every player at once, wreckage and lightning come down on
-- marked ground, ink novas detonate outward in rings, and in the deep fight
-- the maelstrom itself drags everyone toward the maw while the sky rains -
-- the whirlpool the player sailed into, weaponized. Killing it sets
-- Heart_kraken and the finale banner; it unlocks nothing, because there is
-- nothing left to unlock.
Bosses.items.kraken = {
	id = "kraken",
	name = "The Kraken, Maw of the Maelstrom",
	shortName = "The Kraken",
	creature = "kraken",
	islandId = "maelstrom",
	-- Level 48 AND all six island hearts - owned, never spent. The bait's
	-- recipe checks the same six, so this is the belt to that braces.
	gate = { level = 48, hearts = { "brinejaw", "old_gnashroot", "rimefang", "pyrelisk", "noctyss", "admiral_wrack" } },
	-- The centre of the whirlpool at the site's heart; the rock platforms
	-- ring it at ~34-55 studs, inside tentacle reach by design.
	arena = { offset = Vector3.new(0, 0, 0), radius = 34 },
	-- Drawn by KrakenBodyController off Shared/Modules/KrakenPath: one domed
	-- head filling the middle of the whirlpool, eight arms off its crown. A
	-- posed boss holds its ground - updateBoss stops walking it at you, since
	-- its head IS the centre of the arena.
	pose = "kraken",
	-- The tentacle ring: `count` kraken_tentacle rows planted evenly on
	-- `ring` studs around the arena centre. While any lives, the head is
	-- untouchable; `regrow` seconds after the last one dies, they respawn
	-- (if the boss still lives). CreatureService.updateBoss owns this.
	--
	-- EIGHT, because it is an octopus and the renderer welds one arm into one
	-- crown socket per tentacle - `count` and KrakenPath.ARM_COUNT are the
	-- same number seen from two sides. `ring` sits outside the 28-stud head
	-- and out where the platforms are, so the arms have real length and you
	-- fight them from the rocks rather than off the hide.
	parts = {
		row = "kraken_tentacle",
		count = 8,
		ring = 46,
		regrow = 24,
	},
	aggro = 120,
	standoff = 18,
	hitRadius = 20, -- the authored dome's half-width; x1.4 = 28, the whole middle of the arena
	submerge = 3.0,
	riseDepth = 26,
	riseTime = 5.0,
	speed = 6,
	turnRate = math.rad(60),
	attackGapMin = 0.55,
	attackGapMax = 1.1,
	enrageBelow = 0.25,
	enrageCooldownMult = 0.5,
	enrageDamageMult = 1.4,
	-- THE FIGHT: the storm escalates. Early it's the beak and the arms; by
	-- the middle the sky is falling on marked ground; at the end the
	-- whirlpool itself pulls while everything else keeps coming. The
	-- tentacle-ring loop (parts, above) runs through all of it.
	phases = {
		{ below = 1.0, attacks = { "maw", "tentaclelash", "wreckhurl" } },
		{ below = 0.65, attacks = { "maw", "tentaclelash", "wreckhurl", "stormcall", "inknova" } },
		{
			below = 0.4,
			attacks = { "maw", "tentaclelash", "stormcall", "inknova", "undertow", "wreckhurl" },
		},
	},
	attacks = {
		-- The hooked beak, from a maw the size of a harbor mouth.
		maw = {
			handler = "snap",
			tell = "snap",
			skin = "ink",
			windup = 0.7,
			duration = 0.35,
			recover = 0.55,
			cooldown = 1.8,
			lunge = 15,
			radius = 19,
			cone = math.rad(70),
			damage = { 70, 95 },
		},
		-- The signature: an arm erupts under EVERY player at once - nobody
		-- spectates the Kraken. The ring under your feet is yours alone.
		tentaclelash = {
			handler = "barrage",
			skin = "ink",
			windup = 0.8,
			duration = 1.4,
			recover = 0.6,
			cooldown = 6.0,
			pattern = "everyone",
			extra = 1,
			spread = 10,
			arm = 1.0,
			radius = 8,
			damage = { 55, 75 },
			hitEvent = "emerge",
		},
		-- It tears wreckage off the maelstrom's floor and hurls it: marked
		-- ground, heavy hits.
		wreckhurl = {
			handler = "barrage",
			skin = "wreck",
			windup = 0.9,
			duration = 2.0,
			recover = 0.6,
			cooldown = 7.0,
			pattern = "scatter",
			count = 6,
			spread = 17,
			arm = 1.1,
			radius = 9,
			damage = { 48, 64 },
		},
		-- The storm answers it: lightning comes down on every player's
		-- position, short fuse.
		stormcall = {
			handler = "barrage",
			skin = "storm",
			windup = 0.8,
			duration = 1.2,
			recover = 0.5,
			cooldown = 8.0,
			pattern = "everyone",
			extra = 0,
			arm = 0.8,
			radius = 7,
			damage = { 58, 78 },
		},
		-- Ink novas detonate outward from the mantle in expanding rings.
		inknova = {
			handler = "barrage",
			skin = "ink",
			windup = 1.1,
			duration = 2.2,
			recover = 0.7,
			cooldown = 9.0,
			pattern = "rings",
			rings = { 12, 20, 28, 38 },
			ringWidth = 6,
			interval = 0.5,
			arm = 0.55,
			damage = { 48, 66 },
		},
		-- The maelstrom ITSELF: a long drag toward the maw while wreckage
		-- rains on whoever it's pulling - swim against the current or ride
		-- it past the beak.
		undertow = {
			handler = "undertow",
			skin = "storm",
			windup = 0.9,
			duration = 6.0,
			recover = 0.7,
			cooldown = 14.0,
			radius = 80,
			strength = 24,
			globEvery = 0.7,
			globRadius = 7,
			damage = { 30, 40 },
		},
	},
}

-- islandId -> boss, so the travel gate and BossService can look up "the
-- boss of this island" directly.
Bosses.byIsland = {} :: { [string]: Boss }
for _, boss in Bosses.items do
	Bosses.byIsland[boss.islandId] = boss
end

return Bosses
