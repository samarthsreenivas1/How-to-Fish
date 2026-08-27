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
	-- Summoned by casting the Leviathan's Call bait (Bait.luau, itself Lv 7
	-- and crafted from the cove's signature drops), so the bait IS the gear
	-- gate: no rod/weapon requirement (user, 2026-08-23 - it replaced the
	-- original "best rod + best weapon" rule). Re-gated 15 -> 7 in the
	-- revamp's level-band pass (docs/revamp-plan.md): Starter Cove is L1-7
	-- and Brinejaw is its band-end capstone.
	gate = { level = 7 },
	-- The open water just past the round arena deck at the dock's end (the
	-- deck spans z 122..198 - World.ARENA_CENTER / ARENA_RADIUS): it rises
	-- off the deck's far rim and can haul itself a few studs onto it, so
	-- players fight it from the planks.
	--
	-- Sized for the row's body.scale 1.5 (~26 studs long, 9,000 HP; user,
	-- 2026-08-22: "bigger, beefier, genuinely hard even with the best
	-- weapon"). Every range below is that scale's. `hitRadius` is how far its
	-- hide extends from the pivot toward the player at scale 1; CreatureService
	-- multiplies it by the row's scale and subtracts it from melee distance, so
	-- a 14-16 reach connects from the stand-off.
	arena = { offset = Vector3.new(0, 0, 210), radius = 28 },
	aggro = 90,
	standoff = 14, -- prowls no closer than this to a player
	hitRadius = 6, -- at scale 1: pivot (torso) to the jaw; x1.5 = 9
	submerge = 2.4,
	riseDepth = 18,
	riseTime = 3.8,
	speed = 7,
	turnRate = math.rad(75),
	attackGapMin = 0.7,
	attackGapMax = 1.4,
	enrageBelow = 0.35,
	enrageCooldownMult = 0.55,
	enrageDamageMult = 1.4,
	phases = {
		{ below = 1.0, attacks = { "snap", "tail", "volley", "slam" } },
		{ below = 0.7, attacks = { "snap", "tail", "volley", "slam", "pull", "brood", "dive" } },
		{ below = 0.35, attacks = { "snap", "tail", "slam", "pull", "brood", "dive", "spines", "spines", "volley" } },
	},
	attacks = {
		snap = {
			windup = 0.75,
			duration = 0.35,
			recover = 0.55,
			cooldown = 1.8,
			lunge = 13,
			radius = 17,
			cone = math.rad(65),
			damage = { 55, 80 },
		},
		-- Full circle round the pivot (the hide reaches 9 of those studs);
		-- dodged by backing out of the ring the tell draws.
		tail = {
			windup = 0.9,
			duration = 0.45,
			recover = 0.65,
			cooldown = 2.4,
			radius = 21,
			damage = { 45, 65 },
		},
		volley = {
			windup = 0.7,
			duration = 0.9,
			recover = 0.5,
			cooldown = 3.0,
			count = 6,
			spread = 12,
			flight = 1.0,
			stagger = 0.13,
			radius = 8,
			damage = { 22, 32 },
		},
		-- From the 14-stud stand-off the player has to clear the ring: 12
		-- studs in 1.6 s at walk speed 16 leaves ~0.8 s to read the tell -
		-- "dodgeable but not trivial" (playtest, 2026-08-22; 33 / 1.15 was
		-- physically undodgeable).
		slam = { windup = 1.6, duration = 0.3, recover = 0.85, cooldown = 4.2, radius = 26, damage = { 55, 80 } },
		pull = {
			windup = 0.5,
			duration = 2.4,
			recover = 0.2,
			cooldown = 6.5,
			radius = 65,
			strength = 36,
			follow = "snap",
		},
		brood = {
			windup = 0.8,
			duration = 0.4,
			recover = 0.6,
			cooldown = 10.0,
			count = 4,
			rows = { "pufferfish", "snapjaw_crab", "tidebomb_urchin", "voltray" },
		},
		-- Tunnels (obstacle-free, under the deck) after the player's live
		-- position for duration - lock, then locks under their feet for the
		-- last `lock` seconds with a ring tell, and bursts there: 13 studs to
		-- clear in 0.9 s means you move the instant the ring appears or eat it.
		dive = {
			windup = 0.7,
			duration = 2.6,
			lock = 0.9,
			recover = 0.9,
			cooldown = 7.5,
			speed = 30,
			radius = 13,
			damage = { 55, 80 },
		},
		spines = {
			windup = 0.8,
			duration = 1.6,
			recover = 0.5,
			cooldown = 5.0,
			count = 10,
			spread = 14,
			flight = 0.8,
			radius = 6,
			damage = { 28, 40 },
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
	-- VOLCANO RESTART NOTE (2026-08-27): the dock these numbers were keyed to
	-- was deleted with the island's step-1 restart, so this is open sea off
	-- the +Z shore (rel Z=541) for now - a fine interim water arena (the
	-- Gnashroot precedent). Re-key when the rebuild's dock step lands.
	arena = { offset = Vector3.new(0, 0, 680), radius = 30 },
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
-- Noctyss, the Trench Mother: an abyssal angler-queen whose lure is the only
-- light in the arena. Her fight is LIGHT ITSELF: the lure that drags you in
-- is also the only thing you can see by; she plants FALSE lures that
-- detonate on approach, her ink blots your sight where it bursts, and her
-- phantom hunts start by dousing every light in the water. Enrage is the
-- dark's answer: the client douses her lure between attacks so every tell
-- starts from nothing.
Bosses.items.noctyss = {
	id = "noctyss",
	name = "Noctyss, the Trench Mother",
	shortName = "Noctyss",
	creature = "noctyss",
	islandId = "gloom",
	gate = { level = 35 },
	-- Open water off the end of the dock (planks end at Z=216) - the stable
	-- spot; the dark pools inland shift with every mesh regen.
	arena = { offset = Vector3.new(0, 0, 246), radius = 28 },
	aggro = 90,
	standoff = 14,
	hitRadius = 6, -- x1.8 scale = 10.8
	submerge = 2.6,
	riseDepth = 20,
	riseTime = 4.0,
	speed = 8,
	turnRate = math.rad(80),
	attackGapMin = 0.6,
	attackGapMax = 1.2,
	enrageBelow = 0.3,
	enrageCooldownMult = 0.55,
	enrageDamageMult = 1.4,
	-- THE FIGHT: trust the right light. The real lure drags you in (then the
	-- jaws follow); the false lights blow up when approached; the ink blots
	-- your screen exactly where you'd want to watch her from; and when every
	-- light goes out at once, she's already under you.
	phases = {
		{ below = 1.0, attacks = { "lurepull", "needlefangs", "inkveil" } },
		{ below = 0.6, attacks = { "lurepull", "needlefangs", "inkveil", "falselight", "phantom" } },
		{
			below = 0.3,
			attacks = { "lurepull", "needlefangs", "phantom", "phantom", "falselight", "abysscall", "abysscall" },
		},
	},
	attacks = {
		-- The signature, and her OPENER: the lure flares - the one light in
		-- the water - and drags you toward the maw, then the jaws follow.
		lurepull = {
			handler = "pull",
			tell = "pull",
			skin = "lure",
			windup = 0.5,
			duration = 2.4,
			recover = 0.2,
			cooldown = 5.5,
			radius = 65,
			strength = 40,
			follow = "needlefangs",
		},
		-- The palisade of needles: fast, short-tell - the punish waiting at
		-- the end of every pull.
		needlefangs = {
			handler = "snap",
			tell = "snap",
			skin = "ink",
			windup = 0.55,
			duration = 0.35,
			recover = 0.55,
			cooldown = 1.6,
			lunge = 14,
			radius = 17,
			cone = math.rad(65),
			damage = { 62, 88 },
		},
		-- Ink shells burst around you: damage, a lingering blot of freezing
		-- dark on the water, and a BLINDING splash of black across the screen
		-- of anyone caught inside.
		inkveil = {
			handler = "barrage",
			skin = "ink",
			windup = 0.8,
			duration = 1.4,
			recover = 0.5,
			cooldown = 7.0,
			pattern = "scatter",
			count = 4,
			spread = 12,
			arm = 0.9,
			radius = 9,
			damage = { 30, 42 },
			hitEvent = "inkBlast",
			pool = { radius = 8, duration = 5, min = 7, max = 11, skin = "ink" },
		},
		-- HER gimmick: three false lures light up and drift the arena. They
		-- look like hers. Anything that comes close learns the difference.
		falselight = {
			handler = "decoys",
			skin = "lure",
			windup = 0.9,
			duration = 0.6,
			recover = 0.5,
			cooldown = 12.0,
			count = 3,
			spread = 20,
			trigger = 7,
			blast = 10,
			lifetime = 12,
			drift = 3.5,
			damage = { 45, 62 },
		},
		-- Every light in the water dies at once - hers too - and she is
		-- simply GONE. The splash you hear next is her surfacing at your
		-- flank, jaws first.
		phantom = {
			handler = "phantom",
			skin = "ink",
			windup = 0.8,
			duration = 1.6,
			recover = 0.6,
			cooldown = 8.0,
			emergeAt = 9,
			radius = 15,
			cone = 75,
			damage = { 62, 88 },
		},
		-- The trench answers her call: three fans of grasping abyssal arms
		-- erupt and march at you from her body.
		abysscall = {
			handler = "barrage",
			skin = "ink",
			windup = 0.9,
			duration = 1.6,
			recover = 0.6,
			cooldown = 7.5,
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
	-- The tentacle ring: `count` kraken_tentacle rows planted evenly on
	-- `ring` studs around the arena centre. While any lives, the head is
	-- untouchable; `regrow` seconds after the last one dies, they respawn
	-- (if the boss still lives). CreatureService.updateBoss owns this.
	parts = {
		row = "kraken_tentacle",
		count = 6,
		ring = 26,
		regrow = 24,
	},
	aggro = 120,
	standoff = 18,
	hitRadius = 8, -- x2.6 = ~21: the mantle is a fortress
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
