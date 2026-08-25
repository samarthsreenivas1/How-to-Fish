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
-- the adds multiply - then it enrages and rains embers. Interim numbers for
-- the volcano's slot-2 band; re-tuned when the island slides to slot 4
-- (docs/revamp-plan.md).
Bosses.items.pyrelisk = {
	id = "pyrelisk",
	name = "Pyrelisk, the Caldera Wyrm",
	shortName = "Pyrelisk",
	creature = "pyrelisk",
	islandId = "volcano",
	-- The bait is the gate, as with Brinejaw: level only, matching Caldera's
	-- Call's own recipe level (the volcano band's end).
	gate = { level = 14 },
	-- Off the end of the shore jetty (the dock runs out past r~527 on +Z):
	-- it rises from the sea and can haul itself toward the planks, so players
	-- fight it from the jetty and the apron's edge.
	arena = { offset = Vector3.new(0, 0, 590), radius = 30 },
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

-- islandId -> boss, so the travel gate and BossService can look up "the
-- boss of this island" directly.
Bosses.byIsland = {} :: { [string]: Boss }
for _, boss in Bosses.items do
	Bosses.byIsland[boss.islandId] = boss
end

return Bosses
