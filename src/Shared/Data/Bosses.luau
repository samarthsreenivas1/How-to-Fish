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
-- Attack names are the handlers in CreatureService.BOSS_ATTACKS:
--   snap    lunges forward and bites (a cone in front)
--   tail    lashes the tail round (everyone within its radius, all round)
--   volley  spits a fan of brine globs that land around the player
--   slam    rears up and crashes down: a shockwave ring
--   pull    the lure flares and drags players toward the maw (then snaps)
--   brood   coughs up minions (other creature rows) thrown at the player
--   dive    submerges (untargetable), tunnels under the player, locks under
--           their feet for `lock` seconds (ring tell), bursts up
--   spines  fires a volley of spines that rain down around the player
-- Every attack has windup (the tell) / duration / recover times, its own
-- cooldown, and its damage range; enrage (below `enrageBelow` health)
-- shortens cooldowns and raises damage.

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
-- generator keeps stable; Session 4 can move it into the largest pond).
-- Summoned by casting Caldera's Call (Bait.luau). Three phases: bites and
-- broadsides, then it dives the shallows and coughs up oozes - splitters, so
-- the adds multiply - then it enrages and rains embers. Tuned for the FINAL
-- slot-4 band (L22-28, ~40k HP on the creature row; docs/revamp-plan.md).
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
	phases = {
		{ below = 1.0, attacks = { "snap", "volley", "slam" } },
		{ below = 0.6, attacks = { "snap", "volley", "slam", "dive", "brood", "pull" } },
		{ below = 0.3, attacks = { "snap", "slam", "dive", "brood", "pull", "tail", "spines", "spines" } },
	},
	attacks = {
		snap = {
			windup = 0.7,
			duration = 0.35,
			recover = 0.55,
			cooldown = 1.8,
			lunge = 14,
			radius = 17,
			cone = math.rad(65),
			damage = { 60, 85 },
		},
		-- The magma-glob broadside: its opening ranged pressure, so phase 1
		-- already teaches "keep moving" the way Brinejaw's volley does later.
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
			damage = { 24, 34 },
		},
		slam = { windup = 1.6, duration = 0.3, recover = 0.85, cooldown = 4.2, radius = 26, damage = { 60, 85 } },
		-- Swims the boiling shallows under the jetty after the player's live
		-- position, then locks and bursts - Brinejaw's dive with a lava wake.
		dive = {
			windup = 0.7,
			duration = 2.6,
			lock = 0.9,
			recover = 0.9,
			cooldown = 7.5,
			speed = 32,
			radius = 13,
			damage = { 60, 85 },
		},
		-- Coughs up magma oozes: splitters, so every add the players ignore
		-- becomes two. The swarm pressure IS this boss's signature.
		brood = {
			windup = 0.8,
			duration = 0.4,
			recover = 0.6,
			cooldown = 10.0,
			count = 3,
			rows = { "magma_ooze", "ember_swarm", "fumarole" },
		},
		pull = {
			windup = 0.5,
			duration = 2.4,
			recover = 0.2,
			cooldown = 6.5,
			radius = 65,
			strength = 36,
			follow = "snap",
		},
		tail = {
			windup = 0.9,
			duration = 0.45,
			recover = 0.65,
			cooldown = 2.4,
			radius = 21,
			damage = { 50, 70 },
		},
		-- The summit answers: embers rain down around the player. Skinned as
		-- an eruption by the client; numbers are Brinejaw's spines.
		spines = {
			windup = 0.8,
			duration = 1.6,
			recover = 0.5,
			cooldown = 5.0,
			count = 10,
			spread = 14,
			flight = 0.8,
			radius = 6,
			damage = { 30, 42 },
		},
	},
}

-- ============================================================ Blackmire Fen
-- Old Gnashroot, the Fen Tyrant: a moss-backed snapping horror - half gator,
-- half drowned oak - that heaves out of the murk off the fen's jetty.
-- Summoned by casting Tyrant's Call (Bait.luau), the Brinejaw ritual. Three
-- phases per the revamp plan: bites and sweeps, then it DIVES into the peat
-- murk and comes up under you while its brood (toads, gulls, leeches) swarms
-- and its roots drag you in, then it enrages into volleys and rains of
-- splintered root-spines.
Bosses.items.old_gnashroot = {
	id = "old_gnashroot",
	name = "Old Gnashroot, the Fen Tyrant",
	shortName = "Old Gnashroot",
	creature = "old_gnashroot",
	islandId = "swamp",
	-- The bait is the gate, as always: level only, the fen band's end.
	gate = { level = 14 },
	-- Off the end of the fen's jetty (the Swamp dock runs +Z from Z=140 to
	-- ~182 at radius 180): it rises from the open water past the planks, and
	-- can haul itself toward them.
	arena = { offset = Vector3.new(0, 0, 210), radius = 28 },
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
	phases = {
		{ below = 1.0, attacks = { "snap", "tail", "slam" } },
		{ below = 0.65, attacks = { "snap", "tail", "slam", "dive", "brood", "pull" } },
		{ below = 0.3, attacks = { "snap", "slam", "dive", "brood", "pull", "volley", "spines", "spines" } },
	},
	attacks = {
		snap = {
			windup = 0.75,
			duration = 0.35,
			recover = 0.55,
			cooldown = 1.8,
			lunge = 14,
			radius = 17,
			cone = math.rad(65),
			damage = { 58, 82 },
		},
		tail = {
			windup = 0.9,
			duration = 0.45,
			recover = 0.65,
			cooldown = 2.4,
			radius = 21,
			damage = { 48, 68 },
		},
		slam = { windup = 1.6, duration = 0.3, recover = 0.85, cooldown = 4.2, radius = 26, damage = { 58, 82 } },
		-- Slips under the peat murk after your live position, locks under
		-- your feet, and the fen floor erupts.
		dive = {
			windup = 0.7,
			duration = 2.6,
			lock = 0.9,
			recover = 0.9,
			cooldown = 7.5,
			speed = 31,
			radius = 13,
			damage = { 58, 82 },
		},
		-- The fen answers: toads, gulls and leeches - the gulls keep flying
		-- once the boss is dead, which is the point of learning them here.
		brood = {
			windup = 0.8,
			duration = 0.4,
			recover = 0.6,
			cooldown = 10.0,
			count = 4,
			rows = { "croakjaw_toad", "bog_gull", "mire_leech" },
		},
		pull = {
			windup = 0.5,
			duration = 2.4,
			recover = 0.2,
			cooldown = 6.5,
			radius = 65,
			strength = 36,
			follow = "snap",
		},
		-- A fan of peat-black globs.
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
			damage = { 24, 34 },
		},
		-- Splintered root-spines rain around the player.
		spines = {
			windup = 0.8,
			duration = 1.6,
			recover = 0.5,
			cooldown = 5.0,
			count = 10,
			spread = 14,
			flight = 0.8,
			radius = 6,
			damage = { 30, 42 },
		},
	},
}

-- ============================================================ Frostmaw Reach
-- Rimefang, the Glacier Serpent: a white serpent that hunts UNDER the ice
-- sheet - its dive is the island's own ice-hole fishing turned against you.
-- Summoned by casting Glacier's Call. Three phases: bites and ice-shard
-- volleys, then it tunnels under the sheet and calls the cold's brood, then
-- the sky whites out and icicles come down with the slams.
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
	phases = {
		{ below = 1.0, attacks = { "snap", "tail", "volley" } },
		{ below = 0.65, attacks = { "snap", "tail", "volley", "dive", "dive", "brood" } },
		{ below = 0.3, attacks = { "snap", "volley", "dive", "brood", "slam", "spines", "spines" } },
	},
	attacks = {
		snap = {
			windup = 0.7,
			duration = 0.35,
			recover = 0.55,
			cooldown = 1.8,
			lunge = 14,
			radius = 17,
			cone = math.rad(65),
			damage = { 58, 82 },
		},
		tail = {
			windup = 0.9,
			duration = 0.45,
			recover = 0.65,
			cooldown = 2.4,
			radius = 21,
			damage = { 48, 68 },
		},
		-- Ice-shard volley: frozen spray that lands around the player.
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
			damage = { 24, 34 },
		},
		-- THE signature: it tunnels under the ice sheet after your live
		-- position and bursts up through it - weighted double in phase 2.
		dive = {
			windup = 0.6,
			duration = 2.6,
			lock = 0.9,
			recover = 0.9,
			cooldown = 6.0,
			speed = 34,
			radius = 13,
			damage = { 58, 82 },
		},
		brood = {
			windup = 0.8,
			duration = 0.4,
			recover = 0.6,
			cooldown = 10.0,
			count = 3,
			rows = { "frostbite_pup", "iceshard_crab", "aurora_jelly" },
		},
		slam = { windup = 1.6, duration = 0.3, recover = 0.85, cooldown = 4.2, radius = 26, damage = { 58, 82 } },
		-- Icicle rain: the phase-3 whiteout answers every slam.
		spines = {
			windup = 0.8,
			duration = 1.6,
			recover = 0.5,
			cooldown = 5.0,
			count = 10,
			spread = 14,
			flight = 0.8,
			radius = 6,
			damage = { 30, 42 },
		},
	},
}

-- ============================================================ Gloomtrench
-- Noctyss, the Trench Mother: an abyssal angler-queen whose lure is the only
-- light in the arena. She opens with the pull - the lure flares and drags
-- you toward the maw - and in deep phases she dives the black water and
-- calls her brood. Enrage is the dark itself: the client douses her lure
-- between attacks so every tell starts from nothing.
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
	phases = {
		{ below = 1.0, attacks = { "pull", "snap", "volley" } },
		{ below = 0.6, attacks = { "pull", "snap", "volley", "dive", "brood" } },
		{ below = 0.3, attacks = { "pull", "snap", "volley", "dive", "brood", "spines", "slam", "slam" } },
	},
	attacks = {
		-- The signature, and her OPENER: the lure flares - the one light in
		-- the water - and drags you toward the maw, then the jaws follow.
		pull = {
			windup = 0.5,
			duration = 2.4,
			recover = 0.2,
			cooldown = 5.5,
			radius = 65,
			strength = 40,
			follow = "snap",
		},
		snap = {
			windup = 0.65,
			duration = 0.35,
			recover = 0.55,
			cooldown = 1.8,
			lunge = 14,
			radius = 17,
			cone = math.rad(65),
			damage = { 62, 88 },
		},
		-- Ink volley: blots of freezing dark that land around the player.
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
			damage = { 26, 36 },
		},
		dive = {
			windup = 0.7,
			duration = 2.6,
			lock = 0.9,
			recover = 0.9,
			cooldown = 7.0,
			speed = 34,
			radius = 13,
			damage = { 62, 88 },
		},
		brood = {
			windup = 0.8,
			duration = 0.4,
			recover = 0.6,
			cooldown = 10.0,
			count = 3,
			rows = { "gulper_eel", "flashbulb_squid", "trench_skitterer" },
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
			damage = { 32, 44 },
		},
		slam = { windup = 1.55, duration = 0.3, recover = 0.85, cooldown = 4.2, radius = 26, damage = { 62, 88 } },
	},
}

-- ============================================================ Wreckwater
-- Admiral Wrack, the Fleet-Eater: the drowned admiral fused into his
-- flagship's bow. Opens with cannon broadsides and the anchor-bite; his
-- brood is a BOARDING PARTY - the island's raid mechanic pointed back at
-- you - and in the last phase the whole wreck surfaces under your feet.
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
	phases = {
		{ below = 1.0, attacks = { "volley", "snap", "tail" } },
		{ below = 0.6, attacks = { "volley", "snap", "tail", "brood", "brood", "pull" } },
		{ below = 0.3, attacks = { "volley", "snap", "brood", "pull", "spines", "dive", "dive" } },
	},
	attacks = {
		-- The broadside: a heavier, wider volley than any serpent's spit.
		volley = {
			windup = 0.8,
			duration = 1.0,
			recover = 0.5,
			cooldown = 2.8,
			count = 7,
			spread = 13,
			flight = 1.0,
			stagger = 0.12,
			radius = 8,
			damage = { 28, 38 },
		},
		-- The anchor-bite: he swings the fouled anchor like a jaw.
		snap = {
			windup = 0.7,
			duration = 0.35,
			recover = 0.55,
			cooldown = 1.8,
			lunge = 14,
			radius = 18,
			cone = math.rad(65),
			damage = { 66, 92 },
		},
		-- The boom sweep: the flagship's spar comes round full circle.
		tail = {
			windup = 0.9,
			duration = 0.45,
			recover = 0.65,
			cooldown = 2.4,
			radius = 22,
			damage = { 52, 72 },
		},
		-- The boarding party - the raid inverted: his dead crew comes over
		-- YOUR rail. Weighted double in phase 2; count above every other
		-- boss's brood.
		brood = {
			windup = 0.8,
			duration = 0.4,
			recover = 0.6,
			cooldown = 9.0,
			count = 4,
			rows = { "drowned_boatswain", "cannonball_crab", "wailing_gunner" },
		},
		-- Grappling chains off the bow.
		pull = {
			windup = 0.5,
			duration = 2.4,
			recover = 0.2,
			cooldown = 6.0,
			radius = 65,
			strength = 38,
			follow = "snap",
		},
		-- Grapeshot rain.
		spines = {
			windup = 0.8,
			duration = 1.6,
			recover = 0.5,
			cooldown = 5.0,
			count = 12,
			spread = 15,
			flight = 0.8,
			radius = 6,
			damage = { 32, 44 },
		},
		-- The wreck surfaces under you: his dive, phase 3 only, twice-listed.
		dive = {
			windup = 0.7,
			duration = 2.6,
			lock = 0.9,
			recover = 0.9,
			cooldown = 6.5,
			speed = 32,
			radius = 14,
			damage = { 66, 92 },
		},
	},
}

-- ============================================================ The Maelstrom
-- The Kraken, Maw of the Maelstrom: the saga's finale. The head is
-- rangedOnly and invulnerable while any tentacle stands (vulnerableWhen =
-- "partsDown"): the fight loops melee-the-tentacles -> guns-on-the-head
-- exposure windows -> regrow. Every prior boss's signature returns - the
-- pull is Noctyss's, the dive is Rimefang's, the splitter brood is
-- Pyrelisk's, and the spines are Wrack's grapeshot as a thrown-wreckage
-- storm. Killing it sets Heart_kraken and the finale banner; it unlocks
-- nothing, because there is nothing left to unlock.
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
	phases = {
		{ below = 1.0, attacks = { "snap", "tail", "slam", "volley" } },
		{ below = 0.65, attacks = { "snap", "tail", "slam", "volley", "pull", "dive", "brood" } },
		{ below = 0.4, attacks = { "snap", "tail", "slam", "volley", "pull", "dive", "brood", "spines", "spines" } },
	},
	attacks = {
		snap = {
			windup = 0.7,
			duration = 0.35,
			recover = 0.55,
			cooldown = 1.8,
			lunge = 15,
			radius = 19,
			cone = math.rad(70),
			damage = { 70, 95 },
		},
		tail = {
			windup = 0.9,
			duration = 0.45,
			recover = 0.65,
			cooldown = 2.4,
			radius = 24,
			damage = { 55, 75 },
		},
		slam = { windup = 1.55, duration = 0.3, recover = 0.85, cooldown = 4.0, radius = 27, damage = { 70, 95 } },
		-- Ink-and-brine broadside.
		volley = {
			windup = 0.7,
			duration = 1.0,
			recover = 0.5,
			cooldown = 2.8,
			count = 8,
			spread = 14,
			flight = 1.0,
			stagger = 0.11,
			radius = 8,
			damage = { 30, 40 },
		},
		-- Noctyss's pull, from a maw the size of a harbor mouth.
		pull = {
			windup = 0.5,
			duration = 2.4,
			recover = 0.2,
			cooldown = 5.5,
			radius = 70,
			strength = 42,
			follow = "snap",
		},
		-- Rimefang's dive, under the whirlpool floor.
		dive = {
			windup = 0.7,
			duration = 2.6,
			lock = 0.9,
			recover = 0.9,
			cooldown = 6.5,
			speed = 34,
			radius = 14,
			damage = { 70, 95 },
		},
		-- Pyrelisk's splitter brood plus the storm's own wings.
		brood = {
			windup = 0.8,
			duration = 0.4,
			recover = 0.6,
			cooldown = 9.0,
			count = 4,
			rows = { "kraken_spawn", "stormpetrel", "galestreak_flyingfish" },
		},
		-- Wrack's grapeshot as a thrown-wreckage storm.
		spines = {
			windup = 0.8,
			duration = 1.8,
			recover = 0.5,
			cooldown = 4.5,
			count = 13,
			spread = 16,
			flight = 0.8,
			radius = 7,
			damage = { 34, 46 },
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
