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
	--   1. survive a pattern - and after the 2026-09-06 rebuild each pattern
	--      asks a DIFFERENT question: a whip is jumped, a wave is hidden
	--      from, a bombardment is walked out of, the bell's rings are jumped
	--      in rhythm, the spiral's closing lane is backed out of. (The old
	--      low-vs-high sweep read is gone with `sweephigh`.)
	--   2. earn the opening - bait a tail slam onto one of the arena's three
	--      REEF STONES. Sand absorbs the blow; rock does not, and the rattle
	--      cracks against it;
	--   3. spend it - the serpent loses its grip and its head comes down on
	--      the sand, targetable and Exposed, for `stagger` seconds. That is
	--      when MOST of the damage happens; it is no longer the only time it
	--      can be hurt at all (see `chip` below, and the lunge's plant).
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

	-- ------------------------------------------------------------- the floor
	--
	-- THE CHIP FLOOR: BRINEJAW IS NEVER FULLY INVULNERABLE AGAIN.
	--
	-- The trace of the shipped fight found 40 minutes solo at 5% uptime,
	-- because "the ONLY time it can be hurt at all" (the note above) plus a
	-- stone economy that could not refill meant a party which misread three
	-- baits had NO way to damage the boss and no way to earn another window.
	-- With `chip` present the entrenched boss stays aimable and damageable at
	-- all times, taking this fraction of every hit OUTSIDE a punish window and
	-- the full hit INSIDE one (CreatureService.damage scales it; the windows
	-- are stagger mode, the lunge's held plant, and the post-surge stagger).
	--
	-- The field is the gate as well as the number: it exists on this row and
	-- nowhere else, so every other boss keeps `untargetable` and its meaning
	-- exactly as they are. See the note at CreatureService.damage.
	--
	-- 0.25 is simulated, not chosen. It is the value at which the chip carries
	-- about a third of the health bar and the earned windows carry the rest -
	-- low enough that ignoring the bait is still much slower (11.8 min against
	-- 7.5 at DPS 80), high enough that a party with no stones standing is
	-- making progress instead of waiting.
	chip = 0.25,
	-- ...and the other half of that fix: a spent reef stone stands again this
	-- many seconds later, not only when the boss changes stance. Three baits
	-- cannot produce a stance's worth of damage, so the stance-change restore
	-- alone was a deadlock; this is the timer that makes the stones a
	-- RESOURCE rather than a countdown to a stalemate. The stance-change
	-- restore is kept on top of it.
	stoneRegrow = 25.0,

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

	-- Phase = coil, and the book is REBUILT (2026-09-06, user-approved). What
	-- went, and why:
	--   * `sweephigh` and `rubble` are DELETED outright. The high sweep was
	--     half of a read the body could never sell at 100 parts of moving
	--     serpent, and `rubble` was a stock `volley` wearing a masonry name -
	--     the seeded bombardment below is the move it was pretending to be.
	--     NO HIGH SWEEP REMAINS ANYWHERE: every sweep in this book is low and
	--     is jumped.
	--   * `constrict` is superseded by `spiral`, which is the same idea done
	--     as geometry rather than as a pair of chained sweeps: the arm's REACH
	--     closes with U, so the lane you can stand in shrinks while it turns.
	--   * `sweeppair`'s low-then-high becomes `doublewhip`: a low whip whose
	--     follow is a REVERSED low whip. Jump, land, jump again - the second
	--     one comes back the other way, which is a read you make with your
	--     eyes rather than one you memorise.
	-- What arrived: the four event-driven attacks the serpent could never
	-- express as a pose (riptide, masonryrain, belltoll, tidalsurge), the two
	-- that punish standing still and standing off (lunge, undertow), and the
	-- heal the party has to answer (polyps).
	phases = {
		{ below = 1.0, attacks = { "whip", "riptide", "tailslam", "masonryrain" } },
		{
			below = 0.66,
			attacks = {
				"whip",
				"riptide",
				"tailslam",
				"masonryrain",
				"doublewhip",
				"belltoll",
				"lunge",
				"undertow",
				"polyps",
			},
		},
		{
			below = 0.33,
			attacks = {
				"whip",
				"riptide",
				"tailslam",
				"masonryrain",
				"doublewhip",
				"belltoll",
				"lunge",
				"undertow",
				"polyps",
				"spiral",
				"tidalsurge",
			},
		},
	},

	attacks = {
		-- THE WHIP. Jump it. 2.6 s for ~340 degrees is a wave you can see
		-- coming from anywhere on the ring, which is the point at a level-7
		-- capstone - and the arm is now a DRAG CURVE rather than a spoke
		-- (BrinejawPath.stepSweepRate / sweepBearingAt), so the tip trails the
		-- base by up to 28 degrees and the lane you have to leave is the lane
		-- you can see bending.
		whip = {
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
		-- Low, then low again the OTHER WAY: jump, land, jump. The follow
		-- chains `whipback`, and the whole read is that the second one is not
		-- a repeat - it comes back through the ground you just landed on.
		doublewhip = {
			handler = "orbitsweep",
			tell = false, -- fires serpentSweep from its own windup instead
			windup = 1.2,
			duration = 2.2,
			recover = 0.6,
			cooldown = 11.0,
			arc = math.rad(300),
			girth = 3.4,
			damage = { 38, 55 },
			follow = "whipback",
		},
		-- The return stroke, and it is NOT in any phase list: the only way to
		-- see it is to have just been shown a `doublewhip`. `reverse` makes
		-- aimSweep take the opposite direction to the sweep before it rather
		-- than rolling its own, so the pair always reads as one move that
		-- changed its mind.
		whipback = {
			handler = "orbitsweep",
			reverse = true,
			tell = false, -- fires serpentSweep from its own windup instead
			windup = 0.9,
			duration = 2.0,
			recover = 0.9,
			cooldown = 11.0,
			arc = math.rad(300),
			girth = 3.4,
			damage = { 38, 55 },
		},
		-- The opening. Long windup on purpose: the bait is a decision, not a
		-- reaction - you have to be STANDING at a stone when it lands.
		tailslam = {
			handler = "tailslam",
			tell = false, -- fires serpentSlam at the real impact point instead
			windup = 1.9,
			duration = 0.85,
			recover = 1.1,
			-- 8.0 -> 12.0. The bait has to be a DECISION, and at 8 seconds
			-- against a stance-1 pool of four it came round often enough to be
			-- a rotation step. In the simulation it is the single largest term
			-- in the whole fight (roughly half the health bar arrives inside
			-- baited staggers), so its cadence is the fight's pace.
			cooldown = 12.0,
			radius = 13,
			lift = 9,
			stoneReach = 11, -- how near a stone the blow has to land
			stagger = 8.0, -- the punish window a stone buys
			-- 2.2 -> 3.0. Sand still only jars it, but 2.2 s was under the
			-- travel time to the tower foot from mid-arena - a window nobody
			-- could reach is not a floor, it is a taunt. 3.0 buys about a
			-- second of actual swinging after the run in.
			weakStagger = 3.0,
			damage = { 52, 74 },
		},
		-- MASONRY RAIN. The grinding coils shed the lighthouse's own stonework
		-- over one SECTOR of the beach: leave the sector, or read the markers.
		-- Every chunk's landing point comes out of BrinejawPath.rainChunks off
		-- this row's numbers and the payload's seed, so the client's falling
		-- rock and the server's damage circle are one list computed twice, not
		-- two lists sent once. `count` stays at or under 36 - the client's
		-- pool - and 14 over 3.1 s is a rhythm you can walk out of.
		masonryrain = {
			handler = "masonryrain",
			tell = false, -- fires serpentRain, whose markers ARE the telegraph
			windup = 1.1,
			duration = 3.6,
			recover = 0.8,
			cooldown = 9.0,
			count = 14,
			width = 2.1, -- the sector's angular width, radians (~120 degrees)
			inner = 12,
			outer = 64,
			stagger = 0.22, -- seconds between impacts
			fall = 1.1, -- how far a chunk's ground marker leads its impact
			radius = 7, -- per-chunk damage circle
			damage = { 24, 34 },
		},
		-- RIPTIDE. A wall of water crosses the whole arena on one bearing.
		-- It is TALL: jumping is not an answer and never will be, and the only
		-- answer is the lee of a rock (BossArenas.tropical.cover plus the
		-- lighthouse itself). The client shades the safe wedge behind every
		-- piece from the same `waveSheltered` the server asks - the shadow is
		-- a promise, not a suggestion.
		riptide = {
			handler = "riptide",
			tell = false, -- fires serpentWave, and the wall is its own tell
			windup = 1.6,
			duration = 3.2,
			recover = 0.9,
			cooldown = 12.0,
			-- THE WATER OUTLIVES THE MOVE, ON PURPOSE. The front's real clock
			-- is 2 * reach / speed = 6.0 s, which is longer than the strike:
			-- the serpent throws the wave and goes back to work while it is
			-- still crossing, so a riptide overlaps whatever comes next and
			-- the arena has two things happening in it. The crossing is
			-- resolved by CreatureService's brine-hazard tick rather than by
			-- this row's `duration`, and BOTH sides read the same `start`.
			speed = 26, -- studs/second the front travels
			reach = 78, -- half-span: the front runs -78..+78 along its axis
			push = 46, -- knockback along the wave's own direction
			damage = { 42, 60 },
		},
		-- BELL TOLL. The head strikes the keeper's bell and three rings leave
		-- the tower. JUMP EACH ONE: the hit band is grounded-only, so an
		-- airborne player passes through it, and 26 studs/second with a 1.05 s
		-- gap is the rhythm that makes three jumps a phrase rather than a
		-- reaction test.
		belltoll = {
			handler = "belltoll",
			tell = false, -- the head pose IS the windup; serpentRings draws them
			windup = 1.4,
			duration = 2.6,
			recover = 1.0,
			cooldown = 13.0,
			count = 3,
			speed = 26,
			gap = 1.05, -- seconds between rings leaving the tower
			band = 2.6, -- the ring's thickness; hit inside band/2 of it
			damage = { 34, 48 },
		},
		-- LUNGE. This move exists to punish CAMPING: it picks the FARTHEST
		-- player past `minRange` and puts the skull on them. It tracks until
		-- BrinejawPath.LUNGE_COCK_U and then commits, the blow lands at
		-- LUNGE_IMPACT_U, and then the head is planted on the sand for `hold`
		-- seconds - level with a standing root, fully damageable. That plant
		-- is the fight's only punish window nobody has to earn, and it is
		-- offered to the player standing furthest away.
		--
		-- `duration` is not free: the handler spends 0.30 s falling, 0.35 s
		-- settling, `hold` planted and 0.85 s peeling back up the tower, so it
		-- must be hold + 1.5.
		lunge = {
			handler = "serpentlunge",
			tell = false, -- the shrinking ring is drawn from the pose channel
			windup = 1.3,
			duration = 5.5,
			recover = 1.0,
			cooldown = 11.0,
			hold = 4.0, -- how long the skull stays on the sand
			minRange = 25, -- nobody nearer than this is worth lunging at
			damage = { 56, 78 },
		},
		-- UNDERTOW. A bulge travels beneath the beach from the tower's foot
		-- out to where a player was standing when it started, at CONSTANT
		-- speed - the read is that it does not accelerate and does not turn,
		-- so you step off the line. It erupts at the far end.
		undertow = {
			handler = "serpentundertow",
			tell = false, -- the sand-bulge dust IS the telegraph
			windup = 1.2,
			duration = 2.4,
			recover = 0.9,
			cooldown = 12.0,
			radius = 14, -- the eruption at the end of the run
			damage = { 46, 64 },
		},
		-- SPIRAL, which replaces `constrict`. The same "the safe ground moves"
		-- idea, done as geometry instead of as two chained sweeps: this is an
		-- ordinary low sweep whose REACH contracts with U (BrinejawPath's
		-- `spiral` kind), so the arm closes in on the tower as it turns and
		-- the ring you are standing in gets smaller under your feet. Hugging
		-- the tower stops being the answer half-way through.
		spiral = {
			handler = "serpentspiral",
			tell = false, -- fires serpentSweep once; the closing edge is posed
			windup = 1.8,
			duration = 4.4,
			recover = 0.8,
			cooldown = 16.0,
			arc = math.rad(400),
			girth = 3.8,
			damage = { 44, 62 },
		},
		-- TIDAL SURGE, the stance-3 set-piece. It rears and holds while the
		-- sea comes up over everything outside `floodR` and its own masonry
		-- rains on the dry ground left inside it. Hold the shrinking band,
		-- then punish: the surge ENDS in a guaranteed 8-second stagger, which
		-- is the one window in the fight nobody has to bait.
		--
		-- `once = "stance"` is the cadence: a set-piece that came round on a
		-- cooldown would be a rotation step, and this one is an event.
		tidalsurge = {
			handler = "tidalsurge",
			tell = false, -- fires serpentSurge; the risen water is the tell
			windup = 2.0,
			duration = 10.0,
			recover = 1.0,
			cooldown = 45.0,
			once = "stance",
			floodR = 46, -- everything outside this radius is under water
			floodTick = 0.6, -- seconds between flood damage ticks
			shove = 30, -- how hard the flood pushes you back inward
			stagger = 8.0, -- the guaranteed window it ends on
			damage = { 16, 24 }, -- per flood tick, not per hit
		},
		-- POLYPS, the heal, and the only attack that is a question rather than
		-- a threat. Three brine polyps grow on the arena's cover stones; every
		-- one still alive at the deadline detonates, hurting everyone near it
		-- AND feeding its share of the serpent's health back up the beam.
		--
		-- `heal` is a fraction of MAX health per surviving polyp. 0.035 x 3 is
		-- 10.5% a cast, and `once = "stance"` caps the fight at two casts, so
		-- a party that ignores the mechanic entirely pays about 21% of a
		-- health bar - the ~2 minutes the rebalance budgets for it. (6% each,
		-- the first draft, cost 3.5-4 minutes: double the budget.)
		polyps = {
			handler = "serpentpolyps",
			tell = false, -- serpentPolyps draws the beams and the countdown
			windup = 1.0,
			duration = 1.2,
			recover = 0.8,
			cooldown = 45.0,
			once = "stance",
			count = 3,
			deadline = 12.0, -- seconds the party has to break them
			heal = 0.035, -- fraction of max health each survivor returns
			radius = 10, -- the detonation's damage circle
			damage = { 30, 40 },
		},
	},
}

-- ============================================================ Ashfall Caldera
-- Pyrelisk, the Ashfall Colossus: a 270-stud obsidian rock golem rooted in
-- the caldera lake of its own arena (BossArenas.volcano, the Ashfall
-- Throne). Summoned by casting Caldera's Call (Bait.luau).
--
-- REDESIGNED 2026-08-31. The book this replaces (maul / slagspit / lavawake
-- / magmajet / ventstorm / cinderring) belonged to a magma SERPENT that swam
-- at you off the shore jetty, and every one of those moves assumed a boss
-- that closes the distance. This one cannot and never will: it is rooted in
-- its own lake, `speed = 0`, and the arena is a ring of flat basalt across a
-- 120-stud moat of lava from it. Nothing it does is a charge, because
-- nothing it has can leave the lake.
--
-- THE LOOP - the Brinejaw grammar, spoken at colossus scale:
--   1. SURVIVE A PATTERN, and the pattern is a squeeze rather than a wall.
--      `rimsweep` rakes the OUTER path and herds you inward toward the
--      lava; `handfall` comes down on the inner band you were herded into;
--      `ventbreath` burns a wedge of the ring and leaves it burning, so the
--      ground you are being herded across gets smaller all fight.
--   2. EARN THE OPENING. Bait a hand-slam onto one of the arena's nine
--      obsidian MONOLITHS (BossArenas.volcano.stones). Bare basalt absorbs
--      the blow; obsidian does not, and the arm that shatters one is left
--      lying down across the moat.
--   3. SPEND IT. That arm IS the ramp. `stagger` is twenty seconds because
--      the window is not a damage phase, it is a journey: run the rim to
--      the planted arm, climb the forearm, cross the deck on its back and
--      break a vent before the body stands up again. Every other boss's
--      window is measured in swings; this one is measured in ground.
--
-- `stances = 3` is the ground it loses. Each health phase costs it a stance,
-- and the arm it can still lift comes down nearer to you.
--
-- Tuned for the volcano band's capstone (L22-28, 40,000 HP on the creature
-- row). Damage sits in the same family as Rimefang's - a player is 100 base
-- health plus their armour - because the pressure here is POSITION, not the
-- size of any one number.
Bosses.items.pyrelisk = {
	id = "pyrelisk",
	name = "Pyrelisk, the Ashfall Colossus",
	shortName = "Pyrelisk",
	creature = "pyrelisk",
	islandId = "volcano",
	-- The bait is the gate, as with Brinejaw: level only, matching Caldera's
	-- Call's own recipe level (the volcano band's end).
	gate = { level = 28 },

	entrenched = true,
	pose = "pyrelisk",
	stances = 3,

	-- `offset` is the old roam disc off the shore jetty, dead the moment
	-- BossArenas.volcano existed and kept only as BossService's fallback
	-- spawn for an island with no lair row.
	--
	-- `radius` IS NOT A ROAM RADIUS ANY MORE - this boss is `entrenched`
	-- with `speed = 0` and could not leave its lake if it wanted to. It
	-- survives as one thing: BossArenaService.ringPositions drops the
	-- challengers on a circle of `radius + 8`, so this number decides where
	-- the party lands at summon, and it is bounded on BOTH sides.
	--   * OUTSIDE r120, the caldera lava lake, whose edge wobbles +/-3.4
	--     studs - and the lake is deliberately non-collidable, so a ring
	--     inside it is not a burn, it is a 292-stud fall into the sea. The
	--     old 30 dropped the whole party at r38, in the lava.
	--   * INSIDE r200 (PY_CLEAR_R, measured): past that the rim path runs
	--     under the lip's undercut, and a drop-in under a ceiling puts
	--     players somewhere nothing aimed at the path can reach them.
	-- 152 lands the ring at 160: forty studs of margin off the lake's edge
	-- and forty inside the overhang, which is the middle of the band the
	-- fight is actually played on. ringPositions warns by name if this ever
	-- lands on a hazard, but that fires at summon time, after the players
	-- have already been moved - it is a net, not the decision.
	arena = { offset = Vector3.new(0, 0, 637), radius = 152 },

	-- The rim path runs r=120 (the lake's edge) to r=232 (the lip), so
	-- "anywhere a player can stand" is 232 studs out and aggro has to cover
	-- all of it plus the lip itself. Anything less and a party that spread
	-- to the outer band would watch a colossus stand idle in its own arena.
	aggro = 260,
	-- Dead numbers, stated rather than omitted: it is rooted. `standoff` is
	-- how close a PROWLING boss comes, and this one has no prowl.
	standoff = 0,
	speed = 0,
	-- 96, and the number is set by the MOAT rather than by the body.
	--
	-- `inRange` measures melee to `hitRadius * body.scale` off the pivot,
	-- and the row's scale is 1.0 (Creatures.luau), so this reads in real
	-- studs. The longest melee reach in Weapons.luau is 16; 96 + 16 = 112,
	-- eight studs inside the lake's 120-stud edge. That is the whole fight's
	-- ranged-only premise, and it is GEOMETRY rather than a `rangedOnly`
	-- flag: you cannot swing at it from the shore, so the only way to put a
	-- blade in it is to climb the planted arm. Every stud added here is a
	-- stud of free melee across the lava.
	--
	-- What it costs: `raycastNearest` captures a shot by its perpendicular
	-- distance from the PIVOT, and this pivot is at the feet of a 250-stud
	-- body. A shot aimed at the crown from the inner path passes ~130 studs
	-- off it and is dropped, so ranged fire lands on the mass and not on the
	-- head. The fix is a pivot-to-crown capsule in `raycastNearest`, not a
	-- bigger number here - which would trade the moat away for it.
	hitRadius = 96,
	submerge = 0,
	-- = PyreliskPath.RISE_DEPTH. It waits under the lava and comes up out of
	-- it, and the drawn rise reads the same 40 studs the server does.
	riseDepth = 40,
	riseTime = 6.5, -- a mountain standing up; Brinejaw's wake is 4.2
	-- A MOUNTAIN TURNING. ~28 deg/s, so a full half-turn is six and a half
	-- seconds - longer than any windup in the book. That is deliberate and
	-- it is the fight's one mercy: because it cannot spin to follow you,
	-- running around it is always an answer to something, and a party that
	-- splits the ring is genuinely making it choose.
	turnRate = math.rad(28),
	-- Long gaps. At this scale the beat between attacks is when you cross
	-- ground, and a colossus that chained blows would just be a wall.
	attackGapMin = 2.2,
	attackGapMax = 3.6,
	enrageBelow = 0.3,
	-- Gentler than the roster's usual 0.55/1.4. Every attack here is read
	-- and answered with your feet across a hundred studs of path; cutting
	-- the cooldowns hard would not make it fiercer, it would make it
	-- unreadable, which is the one thing this fight cannot be.
	enrageCooldownMult = 0.7,
	enrageDamageMult = 1.25,

	-- Phase = stance. It opens with the two arms it can still swing freely
	-- and the slabs it tears off itself; at the second stance the head comes
	-- into it; at the third the mountain itself starts falling on you.
	-- `handfall` is in every phase because it is the ONLY route to a punish
	-- window - drop it from a phase and that stretch of the fight becomes
	-- unwinnable rather than merely harder.
	phases = {
		{ below = 1.0, attacks = { "handfall", "rimsweep", "shardhurl" } },
		{ below = 0.66, attacks = { "handfall", "rimsweep", "shardhurl", "ventbreath" } },
		{
			below = 0.33,
			attacks = { "handfall", "rimsweep", "ventbreath", "ashfall", "shardhurl" },
		},
	},

	-- EVERY `tell` BELOW NAMES A REAL BRANCH of CreatureEventController's
	-- EVENTS.telegraph, and the branch is named in each attack's comment. An
	-- unrecognised kind does not error - it falls through the catch-all and
	-- draws a 3-stud sparkle, which on a blow from a 270-stud body is no
	-- warning at all, and is invisible from the far side of the ring.
	--
	-- The stock tell fires at the boss's PIVOT, which for this boss is the
	-- middle of the lake: it is the BODY flaring as it commits, not a mark
	-- on the ground. Where the blow actually lands is the handler's own
	-- telegraph, placed at the impact point (handfall already does this).
	attacks = {
		-- THE OPENER AND THE BAIT. A fist goes up over the rim and comes
		-- down on the path. Beside a monolith it shatters the rock and the
		-- arm stays down as the ramp; on bare basalt it only jars the body.
		-- Handler: ATTACK_HANDLERS.handfall (CreatureService).
		handfall = {
			handler = "handfall",
			-- Client branch: `slam` - a pulsing ember ring at `radius` plus
			-- a flash on the body. The handler fires a SECOND `slam` at the
			-- real impact point out on the path, and that one is the mark
			-- you read; this one is the mountain winding up.
			tell = "slam",
			skin = "lava",
			-- 2.6s, the longest windup in the book. The bait is a DECISION,
			-- not a reaction: you have to already be standing at a monolith
			-- when the fist arrives, and from the far side of the ring that
			-- is 200 studs of running.
			windup = 2.6,
			duration = 1.4, -- the handler lands the blow at 0.45 of this
			recover = 1.6,
			cooldown = 11.0,
			-- 34 studs of shockwave against 112 studs of path: a third of
			-- the width, so it is dodged by moving rather than by having
			-- guessed right, and a monolith is still a place you can stand.
			radius = 34,
			damage = { 78, 108 },
			-- WHERE A FIST MAY LAND. 120 is the lake's edge (PY_LAKE_R): it
			-- will not punch its own lava. 200 is PY_CLEAR_R, NOT the path's
			-- 232 - the lip undercuts back to r205, so the outer 32 studs of
			-- the path are a roofed shelf and a fist aimed there comes down
			-- through the ceiling. Measured with scratchpad/floor_check.py.
			minReach = 120,
			maxReach = 200,
			-- The monoliths stand out to r=217, so a blow capped at 200 is
			-- up to 17 studs short of the farthest of them radially; 28
			-- covers that gap plus the angular slop of an aim latched a full
			-- windup earlier, and still will not spend a stone you were
			-- nowhere near.
			stoneReach = 28,
			-- TWENTY SECONDS, and it is the most important number in the
			-- file. The window is a journey, not a burst: reach the arm,
			-- climb the forearm, cross the back, break a vent. A Brinejaw-
			-- sized 8s window would be spent entirely on the run there.
			stagger = 20.0,
			-- Bare basalt only jars it. Enough to keep the fight winnable
			-- with every stone wasted, far too short to be the plan.
			weakStagger = 3.0,
		},
		-- THE HERD. The arm draws back low and rakes an arc of the path.
		-- The forearm is the hazard along its whole length, so the danger is
		-- a BAND of the ring, and the band is the outer one - which is why
		-- this move and `handfall` are a pair: this drives you in toward the
		-- lava, and the fist lands on the inner strip you were driven onto.
		-- Handler: `rimsweep` (CreatureService, concurrent lane).
		rimsweep = {
			handler = "rimsweep",
			-- Client branch: `ringTell` - the annulus between `inner` and
			-- `radius`, drawn in the skin colour, which is exactly the shape
			-- of the hazard: safe inside it (the lake's edge) and safe
			-- outside it (under the lip). Note the stock draw defaults
			-- `inner` to radius * 0.7 when a handler does not pass one, so
			-- 228 alone still reads as a band from 160 out.
			tell = "ringTell",
			skin = "lava",
			windup = 2.2,
			duration = 1.8,
			recover = 1.4,
			cooldown = 12.0,
			arc = math.rad(150), -- less than half the ring: running is an answer
			radius = 228, -- = PyreliskPath.REACH, the outer edge it can rake
			inner = 160, -- and the strip inside this is the survivable one
			girth = 26, -- = PyreliskPath.WALK_ARM_SIZE.Z, the forearm's own width
			damage = { 62, 88 },
		},
		-- THE HEAD, finally in it. It rears, the jaw opens on the throat
		-- glow (PyreliskPath.jawAngle reads this attack by name) and a
		-- molten cone comes out along its facing. The ground it crosses
		-- stays burning, so this is the move that permanently takes path
		-- away rather than the one that kills you.
		-- Handler: `ventbreath` (CreatureService, concurrent lane).
		ventbreath = {
			handler = "ventbreath",
			-- Client branch: `coneTell` - rings marching out along `facing`
			-- for the whole windup, "step out of the line". The stock tell
			-- already passes `facing = bossFacing(creature)`, so this branch
			-- draws correctly without the handler placing anything.
			tell = "coneTell",
			skin = "lava",
			-- Long, because the answer is to leave the wedge before it
			-- opens and a turnRate of 28 deg/s means it cannot follow you.
			windup = 2.4,
			duration = 2.6,
			recover = 1.6,
			cooldown = 17.0,
			cone = math.rad(44),
			range = 250, -- clears the far lip: the wedge crosses the whole ring
			radius = 250, -- the tell reads `radius` as the wedge's length
			tick = 0.35,
			-- Per tick, not per hit. Standing in it is a decision that gets
			-- worse; clipping its edge on the way out is survivable.
			damage = { 20, 28 },
			-- What it leaves behind: the reason the arena shrinks.
			pool = { radius = 15, duration = 10, min = 12, max = 18, skin = "lava" },
		},
		-- THE MOUNTAIN ANSWERS. Phase three only: the summit sheds and rings
		-- of ash land on marked ground under EVERY player at once, plus a
		-- scatter. The one move in the book that cannot be solved by
		-- standing somewhere else on the ring, because it follows the ring.
		-- Handler: `ashfall` (CreatureService, concurrent lane).
		ashfall = {
			handler = "ashfall",
			-- Client branch: `mark` - a pulsing ring at each landing point
			-- for the whole arm window, in the skin colour. `barrage`-shaped
			-- handlers fire one of these per marked spot; the stock tell at
			-- the pivot is the sky closing over the boss.
			tell = "mark",
			skin = "lava",
			windup = 1.7,
			duration = 3.2,
			recover = 1.1,
			cooldown = 19.0,
			pattern = "everyone",
			extra = 3, -- plus a scatter, so standing on someone else is no answer
			spread = 30,
			arm = 1.5, -- the marks are readable for a second and a half
			radius = 16,
			damage = { 54, 76 },
		},
		-- CHIP DAMAGE, and the only thing it does that reaches the outer
		-- band under the lip. It tears a slab off its own shell - the seams
		-- it opens doing it are the shell the design wants you shooting -
		-- and throws it. The debris does NOT persist (arena state would have
		-- to be cleaned up on a wipe; decided against).
		-- Handler: `shardhurl` (CreatureService, concurrent lane).
		shardhurl = {
			handler = "shardhurl",
			-- Client branch: `slam` - the ember ring and flash on the body
			-- as it wrenches the slab loose. Same branch `handfall` borrows,
			-- and for the same reason: at the pivot, this kind reads as the
			-- body committing, and the landing marks are the handler's.
			tell = "slam",
			skin = "lava",
			windup = 1.9,
			duration = 1.3,
			recover = 1.0,
			cooldown = 8.5,
			count = 3,
			spread = 34, -- wide: it is throwing rock, not aiming
			flight = 1.7, -- a long arc across the moat - you can walk out of it
			stagger = 0.3,
			radius = 18,
			damage = { 46, 66 },
		},
	},
}

-- ============================================================ Blackmire Fen
-- Old Gnashroot: the fen itself standing up. A hunched colossus of wet mud
-- that hauls out of the mere - eyes scattered across its mass, bog stone set
-- into its back, arms long enough to drag, everything running off it. The
-- GNASHROOT is the black root-knot burning in its chest: the thing that is
-- actually alive, and the only part of it that can be hurt properly.
-- Summoned by casting Tyrant's Call (Bait.luau).
--
-- THE FIGHT is the ground turning against you. Everything it does either
-- takes footing away (sludge, snares, the wallow's lane) or punishes you for
-- having none. It is a slow, heavy boss with one earned opening: when it
-- plants both arms to hammer, its chest comes forward and the core is open.
-- Survive the reach, punish the plant.
Bosses.items.old_gnashroot = {
	id = "old_gnashroot",
	name = "Old Gnashroot, the Drowned Mire",
	shortName = "Old Gnashroot",
	creature = "old_gnashroot",
	islandId = "swamp",
	-- The bait is the gate, as always: level only, the fen band's end.
	gate = { level = 14 },
	-- `offset` is the IN-PLACE FALLBACK only: the swamp has a BossArenas row
	-- (model "GnashrootArena"), so the real fight is at the Rootmere lair out
	-- in open water and BossService.arenaPosition never reads this offset.
	-- `radius` is still live - it is the roam disc the fight actually uses.
	arena = { offset = Vector3.new(0, 0, 74), radius = 36 },
	-- ROOTED: this must exceed the band's own weapon range or the boss simply
	-- never picks an attack. Mire Flintlock reaches 150 and the hit sphere adds
	-- hitRadius*scale = 9, so 159 studs of pivot distance are connectable; 165
	-- covers it. Not a leash - only the beginBossAttack gates, snaretrap's
	-- x1.2 sweep and the (unused here) `everyone` barrage read it.
	aggro = 165,
	standoff = 14,
	hitRadius = 6, -- at scale 1, pivot to the core; x1.5 = 9, the Brinejaw frame
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
	-- THE FIGHT: mobility denial, then a plant you punish. Numbers are the
	-- shipped, tuned ones - this pass renamed and re-skinned the book onto
	-- the mud colossus and added `hammerfall`; it did not re-balance it.
	phases = {
		-- Phase 1 carries five, not three. With a three-move pool gnash's short
		-- cooldown made it every other pick for runs of 14, and an empty pool
		-- falls through to attacks[1] - which IS gnash - ignoring cooldowns.
		-- Pool size is the lever, not the cooldown.
		{ below = 1.0, attacks = { "gnash", "wallow", "disgorge", "heave", "hammerfall" } },
		{ below = 0.65, attacks = { "gnash", "wallow", "disgorge", "heave", "mire", "hammerfall" } },
		{ below = 0.3, attacks = { "gnash", "wallow", "heave", "heave", "mire", "hammerfall", "disgorge" } },
	},
	attacks = {
		-- The gape. It drops the head and takes a bite out of the bank in
		-- front of it - the close-range punish for standing under the mass.
		gnash = {
			handler = "snap",
			tell = "snap",
			skin = "peat",
			windup = 0.75,
			duration = 0.35,
			recover = 0.55,
			cooldown = 4.5,
			-- Rooted, so no lunge: the handler translates creature.pos, which a
			-- pinned boss cannot afford (the drawn body and the hitbox come
			-- apart and never rejoin). Radius 27 is GN_MERE_R exactly - the
			-- bite owns the pool and ends at its rim, so the dodge reads off
			-- the terrain rather than off a number.
			lunge = 0,
			radius = 27,
			cone = math.rad(65),
			damage = { 58, 82 },
		},
		-- It stops being a shape and becomes a WAVE: the whole mass surges
		-- forward in a line and leaves half of itself behind as clinging
		-- sludge. The lane it ploughs is the fight's slowest-to-clear hazard.
		wallow = {
			-- A `charge` cannot survive rooting: the handler walks creature.pos 34
			-- studs and the pin only runs on non-attack frames, so the hitbox
			-- leaves the drawn body and does not come back. Re-handlered to the
			-- identity its own comment already claimed - a WAVE - as a marching
			-- wall of ranks that needs no locomotion at all.
			handler = "barrage",
			pattern = "wall",
			tell = false, -- as heave: the ranks are the telegraph
			skin = "peat",
			windup = 1.0,
			duration = 2.6,
			recover = 0.85,
			cooldown = 9.0,
			width = 26, -- the face's span; across = floor(26/6)+1 = 5 points at
			-- 6.5 spacing, inside a 12-stud diameter, so the face is contiguous
			ranks = 8,
			startAt = 10,
			rankSpacing = 8, -- ranks at 10..66, outermost + radius 6 = 72
			interval = 0.34, -- 7 * 0.34 = 2.38s to cross 56 studs = 23.5 studs/s
			-- against WalkSpeed 16: you cross the 38-stud face, you do not outrun it
			arm = 0.7,
			radius = 6,
			damage = { 55, 76 },
		},
		-- It brings up the mere and throws it: gobs of itself that keep
		-- moving where they land.
		disgorge = {
			handler = "poolvolley",
			skin = "peat",
			windup = 0.7,
			duration = 0.8,
			recover = 0.5,
			cooldown = 5.5,
			count = 3,
			spread = 10,
			flight = 1.0,
			-- was 0.2, inside PlayerService's 0.35 i-frame, so glob 2 of 3 could
			-- never land on the same target
			stagger = 0.4,
			radius = 7,
			damage = { 20, 30 },
			pool = { radius = 7, duration = 6, min = 5, max = 9, slow = 0.5, skin = "peat" },
		},
		-- It sends itself UNDER the peat. A hump races out from where it
		-- planted a hand and heaves up in a marching rank - sidestep the
		-- line, do not try to outrun it.
		heave = {
			handler = "barrage",
			skin = "peat",
			windup = 0.9,
			duration = 1.6,
			recover = 0.6,
			cooldown = 6.5,
			tell = false, -- the generic tell is a 5-stud flash at the pivot for a
			-- 70-stud attack; the per-strike marks ARE this move's telegraph
			pattern = "line",
			count = 10,
			spacing = 6.4,
			startAt = 8, -- 8 + 9*6.4 + radius 5 = 70.6: the peat's exact edge
			fan = { -16, 0, 16 }, -- three bearings: 2.2-stud gaps at the root
			-- opening to 8.3 at the rim, so it is solid where you are close
			-- and runnable where you are far
			interval = 0.16,
			arm = 0.5,
			radius = 5,
			damage = { 30, 44 },
		},
		-- ITS GIMMICK: the ground under every player softens and closes. The
		-- ring is the escape window; whoever is still standing in it when it
		-- shuts is held while the rest of the fight keeps coming.
		-- NOT YET TRUE, do not write it into a design doc: the arena's stump
		-- platforms are meant to be footing this cannot reach, but snaretrap
		-- queues its strike at each player's own root and the strike height
		-- tolerance (14) dwarfs the stumps' ~5-stud lift, so standing on one
		-- changes nothing today. Making it real needs a safe-geometry concept
		-- in the handler - the reason BossArenas rows carry `stones`/`sockets`
		-- for other bosses - plus a `stumps` list on the swamp row.
		mire = {
			handler = "snaretrap",
			skin = "peat",
			windup = 0.8,
			duration = 0.5,
			recover = 0.5,
			cooldown = 9.0,
			arm = 1.1,
			radius = 6,
			damage = { 24, 34 },
			snare = 1.7,
		},
		-- THE EARNED OPENING. Both arms go up and come down together, and
		-- the shockwave is generous - but planting them pitches the chest
		-- forward and the core is wide open for the window afterwards.
		-- `expose` is the RIGHT path here, and not for the reason it is easy
		-- to assume: openStagger already writes its own cooldown, so the
		-- slam-window-slam-window degeneration is closed on both paths. The
		-- actual reason is that openStagger ends in setMode(..., "stagger"),
		-- and the only code that ever LEAVES stagger mode lives inside
		-- updateBoss's entrenched-colossus branch. Gnashroot is not
		-- entrenched and has no `pose`, so a hand-rolled opener would drop it
		-- into a mode with no exit and hang the fight outright.
		hammerfall = {
			handler = "slam",
			skin = "peat",
			windup = 1.15,
			duration = 0.5,
			recover = 1.0,
			tell = "slam", -- draws the ring at `radius`; without it a 22-stud
			-- AoE warns with a 3-stud flash at the boss's pivot, because the
			-- client keys telegraphs on `tell or name` and knows no "hammerfall"
			cooldown = 11.0,
			-- 30 traces the mere's rim (27) plus its lip: rooted, this is finally
			-- a concentric ring the arena itself draws for the player.
			radius = 30,
			damage = { 60, 84 },
			expose = 3.5,
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
	-- Reach is measured to the HIDE, not the pivot: inRange subtracts
	-- `hitRadius * body.scale`. The row's scale of 1.6 was sized for the old
	-- leviathan stand-in; the chain rig draws the pack at its authored size
	-- (girth peaks at 1.0), so the visible whale is ~6.6 studs half-width and
	-- the old 6 * 1.6 = 9.6 let you hit three studs of open water. 4.2 * 1.6
	-- = 6.7 puts the reach back on the body you can actually see.
	hitRadius = 4.2,
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
	-- THE FIGHT: it hunts you the way orcas actually hunt seals on pack ice.
	-- The spy-hop picks you out, the wash takes your footing, and the breach
	-- is the one move that puts it ON the floe with you - beached and
	-- thrashing for four seconds, which is the only window wide enough to
	-- kill it in. Damage is not the pressure here; POSITION is: chill from
	-- the slicks and the wash makes every later dodge slower, and the wash
	-- itself shoves you toward the holes rather than hurting you.
	phases = {
		{ below = 1.0, attacks = { "bite", "spyhop", "breach", "wash" } },
		{ below = 0.65, attacks = { "bite", "breach", "wash", "wash", "flukeslam", "carousel" } },
		{
			below = 0.3,
			attacks = { "bite", "breach", "wash", "flukeslam", "carousel", "whiteout", "whiteout" },
		},
	},
	attacks = {
		-- The jaws, for anyone who stands on its head.
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
			damage = { 52, 70 }, -- capped: x1.4 enrage on 82 one-shots a 100 HP player
		},
		-- It rises out of the water and LOOKS at someone. No damage: the beat
		-- where nothing is coming is what makes the rest readable, and the
		-- mark tells the party who the next move opens on.
		spyhop = {
			handler = "spyhop",
			tell = "mark",
			skin = "frost",
			windup = 1.0,
			duration = 0.8,
			recover = 0.7,
			cooldown = 11.0,
			-- No `rise` here. It carried 11 and NOTHING read it: how far the
			-- spy-hop stands is RimefangPath's RISE_HEIGHT (24), which is what
			-- both the drawn body and the hit chain are built from. A field
			-- that advertises a number the game does not run is worse than no
			-- field - it is a lie the next reader tunes. (Same ruling as the
			-- bait-effects purge.)
			radius = 7,
			hold = 1.1,
		},
		-- THE punish loop: it leaps clear of the sheet, lands flat on the floe,
		-- and is BEACHED for four seconds working itself back to water. The
		-- crash cracks the ice into a chilling slick behind it. `expose` is the
		-- data field, deliberately - it stamps the cooldown before opening the
		-- window, where a hand-rolled opener would skip it.
		breach = {
			handler = "charge",
			tell = "burst",
			skin = "frost",
			windup = 1.15,
			duration = 1.0,
			recover = 1.0,
			cooldown = 8.5,
			length = 46,
			width = 11,
			leap = 9,
			slamRadius = 15,
			radius = 15, -- tell only; `charge` never reads it

			damage = { 56, 70 }, -- capped, and this one has no distance falloff at all
			trail = { every = 9, radius = 7, duration = 6, slow = 0.55, skin = "frost" },
			expose = 4.0,
			-- ...and the window is the whole point of the move, so HOLD it:
			-- without this the 0.65-1.25s attack gap (0.36-0.69 enraged) let
			-- the next attack start a fifth of the way into the four seconds,
			-- which also ends the beached pose the punish is made of. Opt-in
			-- on purpose - see endBossAttack.
			holdExpose = true,
		},
		-- The signature. A wall of slush shouldered across the floe: light
		-- damage, heavy displacement, and the arena's bergs and frozen whaler
		-- are cover - anything solid between you and it saves you.
		wash = {
			handler = "wash",
			tell = "gustTell",
			skin = "frost",
			windup = 1.2,
			duration = 0.9,
			recover = 0.8,
			cooldown = 9.5,
			radius = 34,
			cone = math.rad(70),
			push = 74,
			-- THE WALL'S OWN CLOCK, and the one source both sides read. The
			-- crest is born at the whale's shoulder (`sweepFrom`) and crosses
			-- to `radius` in `sweep` seconds; the handler inverts that line to
			-- decide WHEN each player in the wedge is hit, so the damage rides
			-- the wall instead of landing on the whole floe at once. Mirrored
			-- on the client as WASH_SWEEP / WASH_INNER in
			-- CreatureEventController - if these move, move those.
			sweep = 0.22,
			sweepFrom = 7,
			damage = { 26, 38 },
			slick = { radius = 12, duration = 7, slow = 0.6, skin = "frost" },
		},
		-- The tail comes up through a hole beside you and hammers down.
		flukeslam = {
			-- ITS OWN HANDLER, not the shared `slam`. `slam` rings the boss's
			-- own position, and on a 56-stud animal that put a 24-stud circle
			-- at the HEAD while the fluke came down most of the arena away.
			-- This one aims at the tail and lands when the tail does.
			handler = "flukeslam",
			-- Opts OUT of the stock tell, which is drawn at the pivot (the
			-- nose) before any handler has run. The handler fires its own, at
			-- the fluke's landing point and running through the fall;
			-- `tellKind` is the shape it asks the client for.
			tell = false,
			tellKind = "burst",
			skin = "frost",
			windup = 0.9,
			duration = 0.5,
			recover = 0.7,
			cooldown = 7.5,
			radius = 24,
			damage = { 50, 68 }, -- capped
		},
		-- Orcas ring a bait ball and drive it inward. Here the current does
		-- the driving while bergs of shattered sheet rain on the middle.
		carousel = {
			handler = "undertow",
			-- NOT ringTell: an annulus reads "safe inside it AND outside it", but
			-- undertow pulls across the WHOLE radius and drops globs anywhere in
			-- it. There is no safe middle to promise.
			tell = "mark",
			-- ONE CENTRE. The pull and the bergs are both centred on the
			-- arena's middle (undertow reads `creature.anchor`), so the mark
			-- is drawn there too - it used to be drawn at the whale's nose,
			-- which is up to 28 studs away and moving.
			at = "anchor",
			skin = "frost",
			windup = 1.0,
			duration = 3.2,
			recover = 0.9,
			cooldown = 14.0,
			radius = 30,
			strength = 26,
			globEvery = 0.8,
			globRadius = 7,
			damage = { 30, 44 },
		},
		-- Phase three: the storm closes and icicles come down on marked ground
		-- under EVERY player at once. The `storm` block opens a timed weather
		-- window IN THE LAIR (WeatherController's arena storms) for the whole
		-- attack: the client stamps its own deadline on arrival, so the fog
		-- lifts on time even if the boss dies mid-attack and the close never
		-- comes. Duration covers windup + duration + recover end to end.
		whiteout = {
			handler = "barrage",
			tell = "mark",
			skin = "frost",
			windup = 1.1,
			duration = 2.4,
			recover = 0.8,
			cooldown = 16.0,
			pattern = "everyone",
			arm = 1.25,
			radius = 9,
			extra = 1,
			spread = 11,
			damage = { 48, 66 },
			storm = { mode = "blizzard", duration = 4.3 },
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
		-- 14s of window, 4s of dark. Measured against the band's real DPS
		-- (Voidglass Saber ~229, Gloomcaller DMR ~200): a party of three does
		-- ~9,000 inside one window, so her 46,000 is about five punish cycles
		-- - a capstone fight, not a twenty-minute grind. Solo is deliberately
		-- much longer; this is the island's raid-tier fight.
		-- 15, not 14: the window became POSITIONAL (damage needs the gullet
		-- in reach), and the gullet spends the first ~second of the rise
		-- still under the arena - the extra second gives back the ~7% of the
		-- DPS budget that change cost, so the five-cycle fight the health
		-- was priced against still holds.
		window = 15,
		regrow = 4,
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
			tell = false,
			skin = "lure",
			windup = 1.1,
			duration = 2.6,
			recover = 0.8,
			cooldown = 5.5,
			arc = math.rad(155),
			girth = 3.0,
			-- The wedge crosses a standing player in about 0.3s, so a 0.45
			-- tick made the fight's signature move land once or zero times.
			-- It ticks now, which is what "standing in a moving light is a
			-- continuous mistake" was supposed to mean.
			tick = 0.22,
			damage = { 18, 26 },
		},
		-- The whole choir flashes as one and each flash throws a ring
		-- outward. It is also the only time the arena is fully lit: the
		-- strobe is how you learn where anything is, and it is trying to
		-- kill you while it shows you.
		strobewave = {
			handler = "barrage",
			tell = false,
			skin = "lure",
			windup = 0.95,
			duration = 2.0,
			recover = 0.6,
			cooldown = 10.0,
			pattern = "rings",
			-- Out to the SHELF's edge (r 68), not to the roam radius. At
			-- {14, 26, 38} every band stopped at r 40.5 - so the party's own
			-- arrival ring (44) and every shadow fin (46-58) were immune, and
			-- the one attack that lights the whole arena could not touch
			-- anyone standing where the fight tells them to stand.
			rings = { 16, 30, 44, 58 },
			ringWidth = 6,
			interval = 0.5,
			arm = 0.5,
			damage = { 30, 42 },
		},
		-- The true lure flares and hauls the arena toward the pit - toward
		-- the hole she is under. Chased by a feeler, so being dragged into
		-- the open is not survivable on its own.
		lurepull = {
			-- Its own handler, not the stock `pull`, for one reason: the tell.
			-- Every borrowed telegraph fires at the boss's PIVOT, and hers is
			-- the submerged maw ~26 studs under the arena, so this - the only
			-- move in her book with no damage, no dodge and no counterplay -
			-- was hauling the party off their feet with nothing on screen to
			-- explain it. `lurepull` draws its warning at the pit's rim.
			handler = "lurepull",
			tell = false,
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
			tell = false,
			skin = "ink",
			windup = 0.6,
			duration = 1.2,
			recover = 0.5,
			cooldown = 2.2,
			pattern = "everyone",
			-- 0.5, not the 0.3 that `extra` defaults to: two strikes closer
			-- together than the 0.35s burst i-frame means the second one is
			-- silently swallowed for the player it was scattered around.
			extra = 1,
			extraDelay = 0.5,
			spread = 9,
			arm = 0.75,
			radius = 8,
			damage = { 38, 52 },
			hitEvent = "emerge",
		},
		-- Ink bursts blot the water AND the screen of anyone caught in one:
		-- the dark is her weapon even where there is light.
		inkveil = {
			handler = "barrage",
			tell = false,
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
			tell = false,
			skin = "lure",
			windup = 0.9,
			duration = 0.6,
			recover = 0.5,
			cooldown = 14.0,
			count = 3,
			-- The spawn floor is `spread * 0.35`, so at 22 a decoy could
			-- appear 7.7 studs away against a 7-stud trigger - 0.7 studs of
			-- margin, and none at all for an ally standing near the target.
			spread = 30,
			trigger = 7,
			blast = 10,
			lifetime = 12,
			drift = 3.5,
			damage = { 45, 62 },
		},
		-- The trench answers: fans of grasping arms march out of the pit.
		abysscall = {
			handler = "barrage",
			tell = false,
			skin = "ink",
			windup = 0.9,
			duration = 1.6,
			recover = 0.6,
			cooldown = 8.5,
			pattern = "line",
			fan = { -28, 0, 28 },
			-- The arms march from the PIT'S RIM outward across the stone.
			-- Starting at 8 put the first two ranks inside the pit and ended
			-- the last at r 37, so anyone at the cover ring was untouchable.
			count = 7,
			spacing = 8,
			startAt = 18,
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
			tell = false,
			skin = "ink",
			windup = 0.5,
			dark = 1.6,
			duration = 2.4,
			recover = 0.7,
			cooldown = 13.0,
			pattern = "everyone",
			spread = 7,
			-- 0.65s to clear r 9 needs 13.8 studs/s against a walk of 16. At
			-- 0.55 it needed 16.36 - a hair MORE than the player has, which
			-- made a blind sprint a coin flip decided by rounding rather than
			-- by the player. The dark is the attack; the escape should be
			-- possible and hard, not arithmetically impossible.
			arm = 0.65,
			radius = 9,
			damage = { 44, 60 },
			hitEvent = "emerge",
		},
	},
}

-- ============================================================ Wreckwater
-- Admiral Wrack, the Fleet-Eater: the drowned admiral fused into his
-- flagship's bow, careened on the tidal flat he died on. REDESIGNED
-- 2026-08-29 from a chase into a BULLET HELL.
--
-- He is a STATIC GUN PLATFORM, in both senses: he never takes a step AND he
-- never turns. `speed` is 0, which zeroes the only line in updateBoss's prowl
-- branch that moves a boss, and `standoff` is past the whole shoal so that
-- line is never reached anyway. `turnRate` is 0, which zeroes the two lines
-- that turn one - the prowl branch's face-the-player and updateBossAttack's
-- windup tracking at 1.5x. His yaw0 is therefore his spawn bearing (+X: the
-- bow) for the whole fight.
--
-- HE MUST NOT TURN, and this is the load-bearing half of the design. The
-- four gun decks are authored at four different BEARINGS (boss_gen's
-- WR_GUNS: +Y, -Y, -X, +X) so that no position on the shoal shows more than
-- two of them - repositioning to reach the far pair IS the fight's loop.
-- Face-the-player presents the same two forever and the loop dies. The
-- fiction says the same thing twice over: a first-rate hove down on a tidal
-- shoal, careened onto her starboard bilge, does not pivot; and `parts.at =
-- "mounts"` below resolves boss-local offsets ONCE against yaw0, which is
-- only correct for a hull that stays put.
--
-- Planting him with `speed`/`turnRate` rather than with `pose` is still
-- deliberate, for a DIFFERENT reason than it used to be: a posed boss goes
-- down the colossus path (placeColossus, hideColossusModel), which he has no
-- rig for - WrackBodyController draws him off `CreatureId` instead. Nothing
-- in his kit reads his heading: every pattern latches the nearest player's
-- bearing at windup (wrackAim), and bossFacing() is reached only as the
-- empty-arena fallback, where there is nobody to point at anyway.
--
-- THE LOOP. Four gun-deck batteries (`parts`) ring his hull. While any of
-- them stands he cannot be hurt (the creature row's vulnerableWhen =
-- "partsDown"), and every pattern's ball count scales with how many are left,
-- so silencing one visibly thins the screen. Silencing all four stops the
-- guns dead AND cracks the hull open: a four-second stagger of true silence,
-- then thin fire from a skeleton crew for the rest of `parts.regrow` while
-- the hull stays hittable - the melee burst window - and then the decks grow
-- back and the cycle repeats against a denser phase.
--
-- That window is NOT a bespoke opener. It is the shipped partsDown machinery
-- (the Kraken's), which lives entirely in damage() + kill() + updateBoss's
-- regrow clock and never touches the attack phase machine - so every pattern
-- still runs windup -> strike -> recover -> endBossAttack and still writes
-- its cooldown, silenced or not. A silenced volley emits nothing and changes
-- nothing else, so the window cannot be farmed.
--
-- THE ROSTER REWORK (2026-09-08), and the reason for it. The fight shipped as
-- nine rows of BALLS, and nine rows of balls is one verb: read the shape, walk
-- to the hole. Excellent for a minute and then finished, however many shapes
-- there are - a player who has learned to walk has learned all of it. The
-- answer is not more balls, it is more VERBS, so five of the nine ball rows
-- were retired and five mechanics that ask for something other than walking
-- took their place. What survives is the punctuation between them.
--
-- THE FOUR BALL ROWS THAT SURVIVE, and the answer to each:
--   broadside   a ring of slow cannonballs with ONE gap - walk to the gap,
--               and keep walking, because it rotates every volley. The
--               signature: the one shape the whole fight is read through.
--   grapeshot   a fast aimed fan - step out of the cone DURING the tell. The
--               shortest cooldown, so it is also the fallback pick.
--   wisps       slow homing lights - keep moving, and run a circle tighter
--               than their 15.6-stud turn radius. It is the row that COMPOSES
--               with the new mechanics: it taxes standing still, and every one
--               of the five below wants you to stand somewhere specific.
--   anchorsweep the one big telegraph - a wall across half the arena. The
--               answer is the other half, and the long windup is the time to
--               get there.
-- (broadsideHeavy is the phase-3 re-read of the signature and is counted with
-- it.) RETIRED: chainshot, slewfire, slewfireFast, grapeshotTwin. The first
-- three are all "read a rotation and cross it", which is the same cognitive
-- slot the braziers and the runner now occupy and which they held for 5-5.6
-- CONTINUOUS seconds each - there was no room in the fight's clock for a new
-- verb while they ran. grapeshotTwin was a denser copy of a row that stays.
--
-- THE FIVE NEW MECHANICS, and the verb each one adds:
--   powderrun     SHOOT THE CHASER. A fuse-lit keg homes on you at walk+2 for
--                 eight seconds. Shooting it detonates it WHERE IT IS, so the
--                 answer is a range decision, not a dodge: kill it across the
--                 beach, or eat your own grenade. Phase 3 sends two, and one
--                 blast sets off the other within twelve studs.
--   ghostbraziers SHOOT THE PILLAR. Three ghost-fires charge for six seconds
--                 and then sweep the WHOLE arena except the sector behind any
--                 brazier you doused. Nothing was doused: nowhere is safe.
--                 It is the one move that asks a party to split up.
--   cannonoverload SHOOT THE GUN THAT IS WINDING UP. One named battery glows
--                 for three seconds toward a mega-shot that bursts into a ring
--                 where it lands; fifteen percent of that battery's health
--                 during the windup JAMS it - no shot at all, and the gun
--                 takes a further ten percent for the trouble. The fight's
--                 two halves (dodge the screen / break the brass) finally
--                 point at each other.
--   anchorline    SHOOT THE CHAIN. An anchor lands twenty-five studs past you
--                 and drags a chain back at the hull across four seconds - a
--                 moving LINE, not a circle, so the answer is to leave by its
--                 end. Or break the glowing midlink and it dies on that frame.
--   longboat      SHOOT THE ONES RUNNING THE OTHER WAY. A boarding party
--                 beaches at the palisade and marches at the hull; each one
--                 that arrives repairs a gun deck by a quarter. For eleven
--                 seconds the fight is inverted and his health gate is yours
--                 to defend.
Bosses.items.admiral_wrack = {
	id = "admiral_wrack",
	name = "Admiral Wrack, the Fleet-Eater",
	shortName = "Admiral Wrack",
	creature = "admiral_wrack",
	islandId = "wreck",
	gate = { level = 42 },
	-- The Careenage (BossArenas.wreck, model "WrackArena") AS REBUILT: he is
	-- planted at its centre on one plain beach, walkable to r 132, with
	-- NOTHING standing on it - the six breakwater hulks, the cradle, the
	-- furrows, the spoil and the pools are all gone, and the boundary is now a
	-- palisade of grounded hulls at r 141-160 (measured off the build; the
	-- inner face is 141, not the 140 this used to round to). `offset` is dead
	-- for an arena'd
	-- island (BossService spawns at the arena centre) and kept only for the
	-- shape.
	--
	-- `radius` IS THE PARTY'S DROP RING, at radius + 8, and it is why this
	-- number had to move with the floor. His own hull reaches 48.2 studs, so
	-- the old 40 was ringing challengers in at 48 - INSIDE the boss's own
	-- footprint, which on the old 78-stud shoal was already wrong and on a
	-- 132-stud one is absurd. 80 drops them at 88: forty studs clear of the
	-- hull, forty-four short of the sand's edge, so there is real floor both
	-- in front of them and behind them, and the walk in is a walk.
	--
	-- It is also what `bound` is measured from - the Wrack handlers retire a
	-- ball at radius + WRACK_BOUND_MARGIN (60) = r 140, eight studs past the
	-- last walkable sand.
	arena = { offset = Vector3.new(0, 0, -20), radius = 80 },
	-- THE FOUR GUN DECKS - the things the player actually shoots, so they stand
	-- ON THE DRAWN BRASS rather than on a guessed circle. `at = "mounts"` is the
	-- three-dimensional placement mode: the offsets below are BOSS-LOCAL, with Y
	-- the piece's CENTRE measured from the DRAWN hull's sand (spawnBossParts
	-- takes off `halfThickness` and `submerge` itself, and takes the spawned
	-- battery's own half-height back off after it stands - do not pre-apply
	-- any of the three), and they are resolved ONCE at spawn against
	-- `creature.yaw0`.
	--
	-- THAT IS ONLY CORRECT BECAUSE HE IS STATIC. `turnRate = 0` below and this
	-- table are the same decision written twice: a hull that slewed would need
	-- these re-applied every frame, and until that exists a turning boss must
	-- not use this mode. Do not restore his slew without taking these out.
	--
	-- THE UPRIGHT REBUILD (mesh commit 7673cd1, 2026-09-08) REPLACED ALL FOUR.
	-- The ship no longer lies careened on her bilge: she stands, and she is
	-- less than half the size she was - hull 41 x 12.6 against 87 x 45, 48
	-- studs bow to stern - with four INTEGRAL cannons instead of four batteries
	-- bolted onto a hove-down deck. The numbers below come from `WR_CANNONS` in
	-- assets/boss_gen.py, the mesh's single source of truth for both the art
	-- and the muzzle handoff, and are in the same convention as the old ones:
	-- Roblox space, BOSS-local, Y the piece's centre measured from the drawn
	-- hull's sand. No heel term survives because there is no heel any more.
	--
	-- WHAT MOVED, AND WHAT THAT COST. The mounts used to stand at flat radii of
	-- 22-40 studs and heights of 10.6-35.7; they now stand at 13.5-20.0 and
	-- 9.0-12.4. Two consequences, both handled rather than inherited:
	--   * `Fn.wrackDeckReach` is now ~20 instead of ~40, so every tell measured
	--     from it (broadside's mark ring, slewfire's annulus, wisps' mark)
	--     draws twenty studs tighter on its own. That is correct - it tracks
	--     the guns, which is what it was rewritten to do - and needs no edit.
	--   * Anything authored as "near the hull" had to shrink WITH the hull, or
	--     it would name open sand. Two rows carry such a number and both were
	--     re-cut for this mesh: `longboat.reach` (where a boarder counts as
	--     having reached the ship) and `anchorline.stopAt` (where the chain's
	--     drag ends). Their comments carry the arithmetic.
	--   * The four mounts are only 10.9-13.5 studs apart from each other now,
	--     against 30-70 before. `cannonoverload.markAt` - the disc that says
	--     WHICH cannon is winding up - is sized against that gap, not against
	--     the old hull.
	--
	-- Order is the authored one - Bow, Starboard, Stern, Port - matching
	-- WR_CANNONS, the mesh HANDOFF and WrackBodyController's PIECES list.
	-- Nothing in HIS fight keys on the index (only the Kraken's livingArms and
	-- Noctyss's updateChoir read `socketIndex`; his patterns read the COUNT,
	-- `partsAlive`, and `cannonoverload` picks its gun by BEARING), so the
	-- order is for the reader.
	--
	-- `ring` IS GONE, not merely unused. It placed nothing (that is `mounts`),
	-- and its last two readers - wrackEmit's ProjectileService.watch radius and
	-- the death sequence's ring of gun-deck explosions - now take the resolved
	-- mount points instead, because an even r20 circle put the fight's closing
	-- shot on bare sand thirty studs inboard of the guns it was blowing up. A
	-- field whose only readers have been taken away is a number the next reader
	-- will believe.
	--
	-- `regrow` is the burst window, and its shape is `staggerFor` + the rest:
	-- 4 seconds of true silence with the hull open, then a skeleton crew firing
	-- at `windowFire` (0.3) of normal density for the remaining 16, and then
	-- the decks stand back up.
	parts = {
		row = "wrack_battery",
		count = 4,
		at = "mounts",
		-- Y IS THE PIECE'S CENTRE, measured from the DRAWN hull's sand - not
		-- the height its underside rests at, and not measured from the record's
		-- pivot (which floats `submerge` studs above the ship the player sees).
		-- spawnBossParts applies both corrections at the consumption site; do
		-- not pre-apply either here.
		-- Order matches WR_CANNONS / WrackBodyController.PIECES; four bearings
		-- 90 degrees apart, so no position on the shoal shows more than two of
		-- them and repositioning to reach the far pair is still the loop.
		mounts = {
			Vector3.new(19.05, 12.40, 1.40), -- Bow:       +X, r 19.1
			Vector3.new(12.50, 9.00, -7.30), -- Starboard: -Z, r 14.5
			Vector3.new(-19.95, 9.35, -1.30), -- Stern:     -X, r 20.0
			Vector3.new(-11.00, 9.20, 7.90), -- Port:      +Z, r 13.5
		},
		regrow = 20,
	},
	-- The burst window's shape, read by the Wrack handlers in CreatureService
	-- (not by the engine): `staggerFor` seconds of true silence the moment the
	-- last deck falls, then a skeleton crew firing at `windowFire` of normal
	-- density for the rest of it. The window is a burst you dodge inside, not
	-- a free damage phase.
	staggerFor = 4.0,
	windowFire = 0.3,
	-- Covers the whole beach: `dist <= def.aggro` is what gates him STARTING an
	-- attack at all, so anything short of the walkable edge hands the player a
	-- rest area simply by standing still out there - and on a floor of r 132
	-- that rest area would be most of the arena's area. 165 covers the sand
	-- (132) and the awash flat out to the palisade (140-152), so there is
	-- nowhere on this shoal a player can stand and not be shot at. He is
	-- planted, so a long aggro costs nothing but his attention.
	aggro = 165,
	standoff = 200, -- unreachable on purpose; see the header
	hitRadius = 7, -- x2.0 scale = 14: half ship, after all
	submerge = 2.8,
	riseDepth = 22,
	riseTime = 4.2,
	speed = 0, -- PLANTED. The gun platform never takes a step.
	-- AND NEVER TURNS. Zero, not a slow slew: the four gun decks are authored
	-- at four bearings so that only two ever face you, and repositioning to
	-- reach the others is the fight - a hull that turns to face you presents
	-- the same two forever. It also holds `parts.mounts` above still, since
	-- those are resolved once against yaw0. Zero is safe rather than
	-- degenerate: both consumers pass it straight to approachAngle as
	-- `maxStep`, which divides by nothing and returns `current` unchanged, and
	-- the third (placeColossus's `def.turnRate or math.rad(70)`) is behind
	-- `def.pose`, which he does not carry - and 0 is truthy in Luau anyway, so
	-- no fallback can quietly turn him back on.
	turnRate = 0,
	attackGapMin = 0.5,
	attackGapMax = 1.0,
	enrageBelow = 0.3,
	enrageCooldownMult = 0.6,
	-- 1.15, not the usual 1.4: damage now arrives as a sustained stream of
	-- small hits rather than a few big AoEs, and a multiplier on a stream
	-- compounds far harder than one on a 10-second slam.
	enrageDamageMult = 1.15,
	-- THE FIGHT BUILDS, AND IT BUILDS IN VERBS. Phase 1 teaches the two
	-- readable ball shapes, the movement tax, and ONE thing to shoot that is
	-- not a battery. Phase 2 adds the two mechanics that ask you to stand
	-- somewhere specific - the braziers' safe sector and the anchor line's open
	-- end - plus the big telegraph, so phase 2 is where "walk" and "shoot"
	-- first have to be spent against each other. Phase 3 adds the interplay
	-- move and the inverted one, and re-reads the signature.
	--
	-- PHASE 3 IS ALSO WHERE THE TIMERS TIGHTEN, and that is not authored here:
	-- `enrageBelow` is 0.30 and `enrageCooldownMult` 0.60, so every row in this
	-- book comes off cooldown 40% sooner across almost exactly the phase-3
	-- band, and the list itself is nine moves deep instead of four. Duplicating
	-- the whole roster as "-Fast" rows would say the same thing a second time
	-- in numbers that could then disagree with each other.
	phases = {
		{ below = 1.0, attacks = { "grapeshot", "broadside", "wisps", "powderrun" } },
		{
			below = 0.66,
			attacks = {
				"grapeshot",
				"broadside",
				"wisps",
				"powderrun",
				"ghostbraziers",
				"anchorline",
				"anchorsweep",
			},
		},
		{
			below = 0.33,
			attacks = {
				"grapeshot",
				"broadsideHeavy",
				"wisps",
				"powderrunTwin",
				"ghostbraziers",
				"anchorline",
				"anchorsweep",
				"cannonoverload",
				"longboat",
			},
		},
	},
	-- EVERY ROW CARRIES `tell = false`, the engine's documented opt-out, and
	-- every handler draws its own telegraph instead. The stock tell is drawn
	-- at the boss's PIVOT before a target is picked - which for Wrack is the
	-- middle of the hull, while the wall of cannonballs forms sixteen studs
	-- out on a rotating deck and lands eighty studs away. A telegraph that
	-- points somewhere wrong is worse than none.
	--
	-- `tell = false` does NOT cost the audio cue: Sfx.play("bossTell", pos)
	-- runs at the top of the client's EVENTS.telegraph for every telegraph
	-- event, so each handler's own event still announces itself - and does it
	-- from the position that is actually true.
	--
	-- The client implements exactly ten telegraph kinds and falls through to a
	-- 3-stud pivot sparkle for anything else, so each row names the branch it
	-- lands on. Change a `kind` in the handler, change the note here.
	attacks = {
		-- Bread and butter, and the shortest cooldown, so it is also the
		-- phase list's fallback pick.
		-- TELL: one "coneTell" wedge along the latched bearing, drawn at the
		-- gun deck that fires it and re-aimed from there.
		grapeshot = {
			handler = "grapeshot",
			tell = false,
			skin = "grape",
			windup = 0.8,
			duration = 0.45,
			recover = 0.5,
			cooldown = 6.0,
			-- RE-DENSIFIED FOR THE 132-STUD FLOOR. A fan's pellet lanes open
			-- with range and the range doubled: six across 48 degrees left 8.8
			-- studs of clear air between pellet centres where the party now
			-- stands, which is not a fan, it is a picket you walk between.
			-- Eight across 40 gives 2.2 studs at the muzzle - the readable
			-- floor, under which the pellets merge into a texture you cannot
			-- read a lane through - and 4.0 studs clear at the party ring,
			-- which is threadable and meant to be.
			--
			-- `spawnAt` IS NO LONGER A RADIUS ROUND THE ARENA CENTRE. The fan
			-- leaves ONE GUN DECK (the live battery best lined up with the
			-- shot), so this is how far in front of that gun's muzzle the
			-- pellets appear. 22 is what spreads them to the 2.2 studs above
			-- before they are anything the player can read.
			pellets = 8,
			fanDeg = 40,
			speed = 66,
			spawnAt = 22,
			radius = 1.6,
			-- REACH = spawnAt + speed x lifetime = 141, against a `bound` of
			-- r 140 and walkable sand to r 132. Every ballistic row below is
			-- authored this way: the ball expires within a stud of where the
			-- bound would have retired it, so the two knobs say the same
			-- thing. Before this retune bound was 88 against reaches of
			-- 106-183 - five rows could not even reach the floor's edge, and
			-- `lifetime` never fired on any of them.
			lifetime = 1.8,
			tellRange = 110,
			damage = { 40, 54 },
		},
		-- The signature. Three rings, one gap, the gap walking 46 degrees
		-- between each - never a divisor of 360, so it never returns to where
		-- it just was and pre-standing in it cannot work.
		-- TELL: a "mark" disc out on the sand where the gap will open - drawn
		-- at the GAP, not at the boss, because the gap is the whole answer.
		broadside = {
			handler = "broadside",
			tell = false,
			skin = "cannon",
			windup = 1.15,
			duration = 2.5,
			recover = 0.8,
			cooldown = 9.0,
			-- HEAVIER, BECAUSE AN ANGULAR WALL THINS WITH RADIUS. Twenty-two
			-- balls of radius 2.4 were solid only inside r 19; at the old
			-- party ring that left 7.6 studs of clear lane between neighbours
			-- and at the new one it would leave 15.5, which is a fence, not a
			-- broadside. Thirty at radius 3.0 hold the wall solid to r 30 and
			-- keep the lane at 11.5 studs where the party stands - the same
			-- lane-to-radius ratio the old fight shipped. A ring cannot be
			-- solid at r 132 without about a hundred balls, so this is the
			-- honest compromise and `solid_to_r` in the generator prints it.
			count = 30,
			speed = 30,
			radius = 3.0,
			spawnAt = 16,
			-- Both windup cues are drawn at deckReach + spawnAt + markAt, so
			-- they land outside the muzzle locus rather than inside the wall
			-- they are announcing.
			markAt = 26,
			lifetime = 4.15, -- reach 140.5
			-- 34 degrees, AND IT IS NOW 34 DEGREES. The balls used to sit half
			-- a step inside a span of (360 - gapDeg), which left the last one
			-- a half-step short of the first: the hole the player actually
			-- walked into was gapDeg PLUS one step - 48.8 degrees against an
			-- authored 34, a 44% lie in the one number this pattern is read
			-- by. PATTERNS.broadside now lays the balls inclusive of both
			-- ends, so the empty wedge is exactly this number. 34 degrees is
			-- 46 studs of arc at the party ring, 40 of it clear of the two
			-- balls that edge it.
			gapDeg = 34,
			gapStep = 46,
			volleys = 3,
			interval = 1.1,
			damage = { 44, 58 },
		},
		-- Phase 3: four rings, more balls, a gap two thirds the width moving
		-- further and faster.
		-- TELL: a "mark" disc at the gap, as above.
		broadsideHeavy = {
			handler = "broadside",
			tell = false,
			skin = "cannon",
			windup = 1.0,
			duration = 3.4,
			recover = 0.7,
			cooldown = 10.0,
			count = 40,
			speed = 34,
			radius = 3.0,
			spawnAt = 16,
			markAt = 26,
			lifetime = 3.65, -- reach 140.1
			-- Two thirds of the standard broadside's 34, and like it this is
			-- now the true empty wedge: 37 studs of arc at the party ring.
			-- Forty balls hold this wall solid to r 40.
			gapDeg = 24,
			gapStep = 58,
			volleys = 4,
			interval = 0.85,
			damage = { 48, 64 },
		},
		-- The one big telegraph. Twenty-three heavy balls overlapping across
		-- 180 degrees: a wall, not a pattern - you do not thread it, you
		-- leave. Over three seconds of windup, because on a 132-stud floor the
		-- answer is a long walk and the walk is the only answer left.
		-- TELL: a "ring" wrackTell round the player's own ground first
		-- (legible whichever way the camera faces), then a "lane" naming the
		-- half about to become a wall, drawn from the gun deck it leaves.
		anchorsweep = {
			handler = "anchorsweep",
			tell = false,
			skin = "anchor",
			-- 3.2 SECONDS OF WINDUP, up from 1.9, AND THAT IS THE WHOLE RETUNE
			-- OF THIS MOVE. Its two answers were "be in the other half" and
			-- "duck inside the spawn radius", and the second one died with the
			-- rebuild: 1.9 s of walk is 30 studs, which used to put you inside
			-- r 18 from a party ring at 48 and now leaves you at r 58 on a
			-- floor of 132 - nowhere. The first answer needs you to cross the
			-- line through the gun, 72 studs away at the drop ring, and
			-- 1.9 s of tell plus 2.2 s of flight only buys 65. 3.2 buys 86.
			-- The margin is deliberately thin: this is the fight's one big
			-- telegraph and it should be a walk you only just make.
			windup = 3.2,
			duration = 0.6,
			recover = 1.1,
			cooldown = 16.0,
			-- Twenty-three anchors of radius 4.2 across the half: solid out to
			-- 59 studs from the gun and within 2 studs of solid at the party
			-- ring, which is what "a wall, not a pattern" has to mean at this
			-- scale. Fifteen 3.4s would have left 14-stud lanes to stroll
			-- through.
			count = 23,
			arcDeg = 180,
			speed = 26,
			radius = 4.2,
			spawnAt = 16,
			lifetime = 4.8, -- reach 140.8
			-- The arc's own head start, scaled with it: 0.09 x 22 x 26 gives
			-- the leading end 51 studs and makes it arrive 2.0 s before the
			-- trailing end. That lag IS the second answer - commit to the
			-- trailing end and it is passable for a beat.
			ripple = 0.09,
			tellRange = 130,
			tellWidth = 150, -- the lane tell's width: the half it is about to wall off
			tellReach = 40, -- ring tell radius = deckReach + spawnAt + this
			damage = { 78, 104 },
		},
		-- Three slow lights that follow you. They barely hurt; what they do is
		-- take standing still off the table for the next six seconds. One
		-- lantern lifts off each live gun deck, so three decks down is three
		-- fewer places they can come from.
		-- TELL: a "mark" ring at the radius they are born from - which is the
		-- DECKS' ring, not a circle round the pivot.
		wisps = {
			handler = "wisps",
			tell = false,
			skin = "wisp",
			windup = 0.7,
			duration = 0.4,
			recover = 0.5,
			cooldown = 13.0,
			count = 3,
			-- SPEED AND TURN RATE ARE UNTOUCHED, and that is the point: 19
			-- against a 16 stud/s walk is a 3 stud/s close, and 70 deg/s at
			-- speed 19 is a 15.6-STUD TURN RADIUS. A player has no turn radius
			-- at all, so any circle run tighter than 15.6 studs is a circle a
			-- wisp physically cannot hold - it overshoots, swings wide, and
			-- comes back to overshoot again. That was always the answer; the
			-- hulks were only ever a landmark to run it around, and bare sand
			-- does the job identically.
			speed = 19,
			homingDeg = 70,
			radius = 2.2,
			spawnAt = 12,
			-- SIX SECONDS, DOWN FROM NINE - the one number that was actually
			-- broken. Nine survived NO straight-line heading out of 72, and
			-- the reason was not the closing speed (3 studs/s claws back 27
			-- studs against a 76-100 stud head start; it can never catch a
			-- runner in the open). It was the WALL: a straight line runs out
			-- of beach, and a player pinned on the rim is closed on at the
			-- full 19. Six seconds is the longest chase a runner can outlast
			-- from the drop ring, and it opens a real band - 26 of 72 headings
			-- survive, the widest of them a 90-degree arc of TANGENTIAL
			-- breaks (bearings 130-220 from the party ring) that keep sand
			-- ahead of you instead of spending it.
			lifetime = 6,
			spreadDeg = 360,
			damage = { 24, 32 },
		},
		-- ================================================== THE FIVE NEW VERBS
		-- Everything below this line was added by the 2026-09-08 roster rework
		-- (see the header). None of them is a projectile pattern in the sense
		-- the four rows above are: each one puts a SHOOTABLE OBJECT or an AREA
		-- RULE on the sand and asks a question walking cannot answer. Their
		-- rows still carry `tell = false` and still draw their own telegraphs
		-- from the handler, for the same reason every row above does, and every
		-- one of those telegraphs is gated on `wrackWillFire` so the burst
		-- window stays the silence it is supposed to be.
		--
		-- `rows` NAMES THE CREATURE ROW EACH ONE SPAWNS, in the brood handler's
		-- idiom and deliberately in the plural form even where it is one row:
		-- tools/check_content.py validates `rows = { ... }` against
		-- Creatures.items and does not look at a singular `row =`. A row id
		-- typo'd here would otherwise spawn nothing at all, silently, and read
		-- in play as "the mechanic didn't trigger".

		-- THE CHASER. A keg with a lit fuse rolls off a live gun deck and comes
		-- for one player at 18 studs/s against a 16-stud walk: 2 studs/s of
		-- closing speed, so it is not outrun and not outmanoeuvred either (it
		-- turns instantly - there is no wisp-style turn radius to exploit).
		-- Shooting it is the answer, and WHERE you shoot it is the move.
		--
		-- THE EIGHT-SECOND FUSE IS THE BUDGET. From a gun deck to the party
		-- ring is ~70 studs and it closes at 2, so a keg that spawns on you
		-- never reaches you inside its fuse from the drop ring - it reaches
		-- whoever has closed to melee, and it reaches anybody who ignored it
		-- while being herded by a broadside. Ignoring it entirely is survivable
		-- once and not twice, which is the pressure wanted.
		-- TELL: a "mark" disc at the gun deck it rolls off (the keg itself is a
		-- visible model with a lit fuse from that point on, so the telegraph
		-- only has to say WHERE, not what).
		powderrun = {
			handler = "powderrun",
			tell = false,
			skin = "ember",
			windup = 1.0,
			duration = 0.5,
			recover = 0.6,
			cooldown = 12.0,
			rows = { "wrack_powder_keg" },
			count = 1,
			-- Eight seconds of fuse; 18 studs/s against the 16-stud walk.
			fuse = 8.0,
			speed = 18,
			-- HOW FAR SHORT OF YOU IT LANDS, and this number is the move.
			-- The keg is LOBBED from the gun and comes down between you and the
			-- ship - it does not roll the whole way across the beach, and the
			-- difference is not flavour. It closes at 2 studs/s (18 against a
			-- 16-stud walk) for 8 seconds, so it gains SIXTEEN STUDS in its
			-- entire life: born at its own gun it would be 68 studs from the
			-- party ring and would need thirty-four seconds to arrive, which is
			-- a mechanic anybody could ignore forever. At 28 it ends its fuse 12
			-- studs from a player who ran flat out the whole time - inside
			-- `blastFuse` - so running does not beat it, and the answer to this
			-- one is the gun rather than the feet. It is also comfortably
			-- outside `blast`, so shooting it the moment it lands is free.
			spawnAt = 28,
			-- TWO RADII, ONE DAMAGE BAND, and this is the whole risk curve.
			-- `blast` is what a SHOT keg does - 15 studs, so anyone who killed
			-- it at any sensible range is untouched and anyone who let it get
			-- to arm's length is not. `blastFuse` is what the fuse running out
			-- does: 20 studs centred on the player it was chasing, which is not
			-- dodgeable at that point because the dodge was the eight seconds
			-- you just spent. Same damage either way - it is the same powder.
			blast = 15,
			blastFuse = 20,
			-- Chain radius: one keg's blast lights another within twelve studs.
			-- Inert in phase 1 (there is only ever one), so this number exists
			-- for `powderrunTwin` and is authored on both for one meaning.
			chainAt = 12,
			damage = { 58, 80 },
		},
		-- Phase 3: two at once, off two different decks, on a shorter fuse -
		-- and now `chainAt` is live, so a keg killed next to its partner sets
		-- the partner off as well. Killing them apart is worth doing.
		-- TELL: a "mark" disc at each gun deck, as above.
		powderrunTwin = {
			handler = "powderrun",
			tell = false,
			skin = "ember",
			windup = 0.9,
			duration = 0.5,
			recover = 0.6,
			cooldown = 13.0,
			rows = { "wrack_powder_keg" },
			count = 2,
			fuse = 7.0,
			speed = 18,
			spawnAt = 28,
			blast = 15,
			blastFuse = 20,
			chainAt = 12,
			damage = { 60, 84 },
		},
		-- THE PILLAR. Three ghost-fires rise on a 70-stud ring - just inside
		-- the party's 88-stud drop ring, so getting BEHIND one is a walk
		-- outward rather than a sprint across the arena - and charge for six
		-- seconds. Then a wave takes the whole floor except a 100-degree sector
		-- behind each brazier that has been doused.
		--
		-- 100 DEGREES AT r 70 IS 122 STUDS OF ARC, and the sector widens with
		-- radius, so the safe ground is a real place several people fit in and
		-- not a pixel to stand on. `behindAt` is the other half of "behind":
		-- the sector only counts from 8 studs inside the brazier ring outward,
		-- because standing between a doused brazier and the ship is not behind
		-- it in any sense the player would accept.
		--
		-- DOUSE NOTHING AND THERE IS NOWHERE. That is the point of the move and
		-- it is deliberately not a wipe: 72-96 is a hard hit and about a third
		-- of a healthy player, so a party that ignores one charge is punished
		-- and a party that ignores two is dead.
		-- TELL: a "ringTell" annulus over the brazier ring during the windup,
		-- then a "mark" disc on each brazier for its own charge - and, the
		-- moment one is doused, a "mark" out in the sector it just opened, so
		-- the reward for shooting it is drawn where the answer is.
		ghostbraziers = {
			handler = "ghostbraziers",
			tell = false,
			skin = "anchor",
			windup = 1.2,
			-- The strike has to outlast the charge with room for the wave to
			-- land inside it: 6.0 + 0.8. A wave that had to fire from `finish`
			-- would be a move whose damage lands after its own recover began.
			duration = 6.8,
			recover = 0.9,
			cooldown = 22.0,
			rows = { "wrack_ghost_brazier" },
			count = 3,
			ring = 70,
			charge = 6.0,
			safeDeg = 100,
			behindAt = 8,
			damage = { 72, 96 },
		},
		-- THE INTERPLAY. One LIVE battery lights up and winds for three seconds
		-- toward a mega-shot; putting 15% of THAT battery's health into it
		-- during the windup jams the gun - no shot at all - and cracks it for a
		-- further 10%. It is the first move in the fight where the two things
		-- the player is doing (dodging the screen, breaking the brass) are the
		-- same action.
		--
		-- THE NUMBERS ARE A DPS TEST, ON PURPOSE. 15% of 2800 is 420 damage
		-- inside three seconds, which is one player's committed burst or two
		-- players' incidental fire - so the jam is available to a solo who
		-- chooses it and free to a party that was already shooting that gun.
		-- The 10% bonus (280) is the reward for choosing it: the jam is not
		-- just defence, it is the fastest way to break that battery.
		--
		-- THE SHOT ITSELF IS SLOW AND HUGE, and outrunning it is trivial and
		-- not the question - the ring it bursts into where it stops is. So the
		-- answer to a shot you failed to jam is to not be near where it ends,
		-- and `lifetime` is authored so where it ends is the arena's far edge:
		-- 20 + 22 x 5.4 = 139, against `bound` at r 140.
		-- TELL: a "mark" disc ON the winding battery's own mount - which
		-- cannon is the entire question - plus one "coneTell" wedge along the
		-- shot's bearing from that gun.
		cannonoverload = {
			handler = "cannonoverload",
			tell = false,
			skin = "cannon",
			windup = 3.0,
			duration = 0.6,
			recover = 0.9,
			cooldown = 20.0,
			jam = 0.15,
			bonus = 0.10,
			-- THE DISC THAT NAMES THE CANNON, and its size is set by the
			-- upright hull rather than by legibility alone: the four mounts are
			-- 10.9-13.5 studs apart (Bow to Starboard is the closest pair), so
			-- a marker wider than half that stops naming ONE gun and starts
			-- covering two. 5 studs is comfortably inside that and still reads
			-- from the party ring, and it is not the only cue - the coneTell
			-- leaves the same gun along the shot's own bearing.
			markAt = 5,
			speed = 22,
			radius = 7,
			spawnAt = 20,
			lifetime = 5.4, -- reach 139
			tellRange = 120,
			damage = { 70, 92 },
			-- The second stage, handed straight to ProjectileService's
			-- `burstring` by the retiring mega-shot. 16 balls at 34 studs/s
			-- from a 3-stud ring is solid out to r 9 and has 13-stud lanes at
			-- r 30 - a burst you leave, not a wall you thread. `mult` cuts the
			-- parent's damage band: shrapnel off a shot you already failed to
			-- avoid, not sixteen more cannonballs.
			burst = {
				skin = "cannon",
				count = 16,
				speed = 34,
				radius = 2.6,
				spawnAt = 3,
				lifetime = 2.4,
				mult = 0.6,
			},
		},
		-- THE LINE. An anchor is lobbed over the target and lands 25 studs
		-- PAST them, and then its chain drags back at the hull over four
		-- seconds. A moving line segment is a shape this fight has never had:
		-- every other hazard is a disc or a ring, all of which are answered by
		-- walking sideways, and a 34-stud bar sweeping toward you is answered
		-- only by leaving past its END - or by breaking it.
		--
		-- THE CHAIN IS THE HITBOX, exactly as chainshot's is (same `link`
		-- machinery, same segment test), and `chainRadius` 4.0 is drawn on the
		-- client from the wire, so what you see is what hits you.
		--
		-- `stopAt` is where the drag ends - 18 studs from the arena centre,
		-- which is ON the upright hull (48 studs bow to stern, so its own
		-- extent is 24) rather than through it and out the other side. It was
		-- 22 against the careened wreck and had to come in with the mesh.
		-- The drag SPEED is not
		-- authored: the handler computes it from where the anchor actually
		-- landed so the sweep always takes `drag` seconds regardless of how far
		-- out the player was standing. A fixed speed would make the move a
		-- formality against someone standing at the rim and unsurvivable
		-- against someone hugging the hull.
		-- TELL: a "mark" disc where the anchor is about to land, then a "lane"
		-- wrackTell from there back to the ship - the corridor it will drag
		-- through, drawn before it exists.
		anchorline = {
			handler = "anchorline",
			tell = false,
			skin = "chain",
			windup = 1.6,
			duration = 4.6,
			recover = 0.8,
			cooldown = 17.0,
			rows = { "wrack_chain_link" },
			overshoot = 25,
			drag = 4.2,
			stopAt = 18,
			chain = 34,
			chainRadius = 4.0,
			radius = 3.0,
			-- LIFETIME EQUALS `drag`, and it has to: the pair travels at a
			-- speed computed to cover the whole distance in exactly `drag`
			-- seconds, so a longer lifetime is the chain carrying on THROUGH
			-- the ship and out the far side, dragging a hitbox over ground the
			-- lane tell never named. Change one of these two and change both.
			lifetime = 4.2,
			tellWidth = 40,
			tellRange = 120,
			damage = { 56, 74 },
		},
		-- THE INVERSION. A boarding party beaches at the palisade and marches
		-- at the hull at 9.5 studs/s. Every one that arrives repairs a gun deck
		-- by a quarter of its bar. They have no attack: the threat is not what
		-- they do to you, it is what they undo, and for the length of the march
		-- the fight's premise is upside down - his health gate is now yours to
		-- defend.
		--
		-- THE MARCH IS THE TIMER. They land at r 126 (arena radius 80 +
		-- `beachAt` 46, on the palisade's inner face at 141 minus the boat) and
		-- stop at `reach` 20, so the walk is 106 studs at 9.5 = 11.2 seconds,
		-- against 3 x 1300 health. `reach` IS THE UPRIGHT HULL, not a guess:
		-- the rebuilt ship's four cannons stand at flat radii 13.5-20.0, so 20
		-- is the outermost brass - a boarder that gets there is standing at a
		-- gun. It was 26 against the careened wreck whose mounts reached 40,
		-- and a number like that left unretuned would have had boarders
		-- "reaching the hull" six studs out in open sand.
		-- That is a party that has to STOP shooting
		-- the Admiral and spend a full move's worth of damage elsewhere, or
		-- give back 700 per boarder that lands.
		--
		-- ARRIVALS DURING THE BURST WINDOW DO NOTHING, deliberately. With every
		-- battery down there is nothing to repair, and letting a boarder stand
		-- one back up would end the one beat of the fight the party earned by
		-- silencing all four. The window silences the spawn as well, so this
		-- only ever applies to a party that opened the window mid-march.
		-- TELL: a "mark" disc on the sand where the longboat beaches.
		longboat = {
			handler = "longboat",
			tell = false,
			skin = "wreck",
			windup = 1.4,
			duration = 0.6,
			recover = 0.8,
			cooldown = 26.0,
			rows = { "wrack_boarder" },
			count = 3,
			beachAt = 46,
			spread = 11,
			speed = 9.5,
			reach = 20,
			-- A hard cap on the march, so a boarder that somehow cannot make
			-- progress (wedged on the palisade's lip) still leaves. It is also
			-- the creature row's spawn `lifetime`, from one number.
			march = 26,
			repair = 0.25,
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
	-- The tentacle ring: `count` kraken_tentacle rows planted on `ring` studs
	-- around the arena centre, at the bearings below. While any lives, the head is
	-- untouchable; `regrow` seconds after the last one dies, they respawn
	-- (if the boss still lives). CreatureService.updateBoss owns this.
	--
	-- EIGHT, because it is an octopus and the renderer welds one arm into one
	-- crown socket per tentacle - `count` and KrakenPath.ARM_COUNT are the
	-- same number seen from two sides. `ring` sits outside the 28-stud head
	-- and out where the platforms are, so the arms have real length and you
	-- fight them from the rocks rather than off the hide.
	--
	-- AN ARC, NOT A CIRCLE, and this is the fight's staging decision rather
	-- than a tweak. `bearings` names each arm's world bearing in radians
	-- (+X = 0, +Z = pi/2) in the order they are planted, so entry `i` is
	-- socket index `i` - the number the server stamps on the model and the
	-- client claims its arm by. Ascending, so the ring order the wave and the
	-- fist travel in is the order they are laid out in.
	--
	-- A 206-degree fan centred on +Z, which is where the players land: the
	-- Maelstrom's spawn stack is at (4800, 6, -13456), 44 studs up +Z of the
	-- arena centre. The even fallback would have put arm #2 at exactly pi/2 -
	-- two studs from the spawn point, so arriving at the finale meant
	-- materialising inside a slam. Centred at 90 degrees and opened out in
	-- pairs (+-25, +-51, +-77, +-103), the nearest two arms sit 21.2 studs
	-- from the spawn point (measured at ring 50; it was 19.6 at the old 46),
	-- clear of its 13.5-stud cap with room to walk out.
	--
	-- The far semicircle is DELIBERATELY empty water. The fight reads as a
	-- front you approach and fall back from rather than a pit you are dropped
	-- into, and there is always a behind - which is what makes the closing
	-- fist's open seat somewhere you can actually run to.
	parts = {
		row = "kraken_tentacle",
		count = 8,
		-- 50, and it is set by THREE things now, not just staging. Raising it
		-- from 46 is cheap in every one of them and the next person to shrink
		-- it should know what they are giving back:
		--   * ARM CURVATURE. The drawn arm bends hardest where it crests, and
		--     the tightest radius it can hold scales as the SQUARE of its
		--     radial span (socket 25.5 -> ring). 46 gives 20.5 studs of span
		--     and admits an arch of hump 2.85; 50 gives 24.5 and admits 3.93,
		--     a 38% gain for 4 studs. KrakenBodyController's BOUND comment
		--     carries the measurement and what it still does not buy.
		--   * THE PLATFORMS sit at r 38-52, so 50 puts the tentacles INSIDE
		--     the rock band instead of 4 studs inboard of it - they stand
		--     where the party stands, and melee reaches them off the rocks
		--     rather than off the edge.
		--   * SPAWN CLEARANCE improves rather than degrades: the two nearest
		--     arms (bearings 65 and 115) move from 19.6 to 21.2 studs from
		--     the spawn stack, further clear of its 13.5-stud cap.
		ring = 50,
		regrow = 24,
		bearings = {
			math.rad(-13),
			math.rad(13),
			math.rad(39),
			math.rad(65),
			math.rad(115),
			math.rad(141),
			math.rad(167),
			math.rad(193),
		},
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
	-- THE FIGHT: the storm escalates. Early it's the ink and the arms; by
	-- the middle the sky is falling on marked ground; at the end the
	-- whirlpool itself pulls while everything else keeps coming. The
	-- tentacle-ring loop (parts, above) runs through all of it.
	--
	-- `ringwave` LEADS EVERY LIST, and that is a rule rather than a taste.
	-- `pickBossAttack` falls back to `attacks[1]` when everything in the pool
	-- is still cooling, so entry [1] is the move this boss plays when it has
	-- nothing else - which means it has to be a move that can actually land.
	-- The arms reach the whole arc from the ring itself, so the wave always
	-- can. (This is also why the head's move is now ranged: nothing the head
	-- does physically reaches standable ground.)
	phases = {
		{ below = 1.0, attacks = { "ringwave", "inkspit", "wreckhurl" } },
		{ below = 0.65, attacks = { "ringwave", "inkspit", "wreckhurl", "stormcall", "inknova", "tentaclelash" } },
		{
			below = 0.4,
			attacks = {
				"ringwave",
				"inkspit",
				"closingfist",
				"tentaclelash",
				"stormcall",
				"inknova",
				"undertow",
				"wreckhurl",
			},
		},
	},
	attacks = {
		-- ARM ATTACKS. These are the only two moves that use the eight arms
		-- as arms - the boss orders its own ring (CreatureService.commandArm)
		-- instead of drawing markers on the floor, so what hits you is the
		-- limb you can see rearing. Neither carries a `damage` field on
		-- purpose: an arm hits with an arm's force, and the threat is how
		-- many of them move at once.
		--
		-- Both carry `tell = false`, which is not "no telegraph" - it is the
		-- engine's opt-out for a move that draws a BETTER one from its
		-- handler. Each arm fires its own 12-stud ring as it rears, at the
		-- arm, which is where the danger is. The generic tell would have
		-- flashed at the boss's pivot instead: the middle of the head, up to
		-- 46 studs from anything that is about to hit you, on an animal whose
		-- head is 55 studs wide. Worse than nothing, because it points.
		--
		-- The opener from full health, so the ring reads as one animal before
		-- the storm half of the fight starts.
		ringwave = {
			tell = false, -- the ARMS telegraph; see below
			handler = "armwave",
			skin = "ink",
			windup = 0.7,
			duration = 2.9,
			recover = 0.6,
			cooldown = 9.0,
			interval = 0.26, -- neighbour to neighbour: the wave's speed
			windupEach = 0.8,
			lift = 13,
		},
		-- Phase three only. FIVE arms up at once (three of the eight seats are
		-- left open) is the fight's loudest moment and it should not be
		-- something you have seen twenty times by then. On a ring ground down
		-- below eight the handler scales the gap to what is left rather than
		-- taking this number literally - see ATTACK_HANDLERS.armgap.
		closingfist = {
			tell = false, -- the ARMS telegraph; see below
			handler = "armgap",
			skin = "ink",
			windup = 0.6,
			duration = 2.8,
			recover = 0.8,
			cooldown = 15.0,
			gap = 3, -- seats left open; the tell is which arms stay down
			windupEach = 2.0,
			lift = 16,
		},
		-- INK SPIT: the head's only move, and it is RANGED, because the head
		-- is stationary furniture that never physically attacks. It cannot:
		-- it holds the middle of the arena, its own hide is 27.7 studs of
		-- half-width and the nearest standable rock is 38 studs out, so the
		-- bite this replaced (`snap`, a 15-stud lunge into a 19-stud cone)
		-- could not reach ground a player is able to occupy from ANY bearing.
		-- It was the boss's shortest cooldown and it had never once landed.
		--
		-- The volley is the answer that fits the animal: five globs bracketing
		-- wherever you are on the arc, so the counterplay is to keep moving
		-- across the platforms instead of standing and trading. `spread` is
		-- wider than the glob radius on purpose - it brackets you rather than
		-- landing on you, which is what makes stepping out of it work.
		--
		-- `at = "anchor"` puts the stock tell on the arena centre at water
		-- level. The pivot - the other option, and the default - is now
		-- carried 31 studs up inside the mantle so that the head's capture
		-- sphere sits in the drawn body, and a warning flashing in mid-air is
		-- not a warning.
		inkspit = {
			handler = "volley",
			tell = "burst",
			at = "anchor",
			skin = "ink",
			windup = 0.9,
			duration = 1.0,
			recover = 0.6,
			cooldown = 5.5,
			count = 5,
			spread = 14,
			flight = 1.1,
			stagger = 0.16,
			radius = 8,
			damage = { 40, 55 },
		},
		-- Arms erupting out of the WATER under each player - not the eight on
		-- the ring, which is `ringwave` above. Nobody spectates the Kraken:
		-- the ring under your feet is yours alone. Held back to phase two now
		-- that the real arms carry the opening.
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
