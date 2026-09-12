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
	-- ---- MULTI-ACT FIGHTS (Admiral Wrack, 2026-09-09) ----------------------
	-- All three are read by BossService and by nothing else, which is why they
	-- are in the type at all: the fight-shape fields below them (`parts`,
	-- `pose`, `staggerFor`, `rigging`, `acts`, `wreckMounts`) belong to one
	-- boss's own handlers and stay off it, as they always have.
	--
	-- `succeededBy` - this boss's death does NOT end the fight. Names the
	-- Bosses row that takes over: it is raised at the wreck, the running fight
	-- record is re-pointed at it, and no heart, coins, banner or ride home are
	-- paid until IT dies.
	succeededBy: string?,
	-- `heartAs` - pay out under another boss's name. A successor row is not a
	-- separate trophy: the player fought one Admiral Wrack across three acts,
	-- so the win mints `Heart_admiral_wrack` rather than an id nothing reads.
	heartAs: string?,
	-- `summonable` - false means the Call can never reach this row, and it is
	-- not the island's boss for lookup purposes either. Two consumers skip on
	-- it: `bossHere` in BossService, and the `byIsland` builder at the foot of
	-- this file (which feeds BossArenaService's floor). Absent = summonable.
	summonable: boolean?,
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
	-- COMBOS (Fn.rollCombo): a HAZARD attack started under whatever attack is
	-- beginning. `chance` is per phase index (1 = full health): none while the
	-- fight is being taught, rare from the second stance, uncommon in the
	-- third. `cooldown` keeps a streak from chaining. Only hazard rows can be
	-- secondaries - the ones that resolve in updateBrineHazards, so they can
	-- overlap a pose without fighting for the one attack slot.
	combo = {
		chance = { 0, 0.15, 0.25 },
		cooldown = 20.0,
		delay = 0.6,
		secondaries = { "riptide", "masonryrain", "geysers", "spines" },
	},

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
	-- VARIETY IS FRONT-LOADED (2026-09-08, the second playtest). The user played
	-- the fight and reported seeing FOUR attacks, and they were counting
	-- correctly: stance 1 held exactly four rows and stance 1 is most of the
	-- health bar, so the whole opening third of the fight was a four-move
	-- rotation. It is SEVEN now - the lunge, the bell and the new geysers move
	-- down out of stance 2 - and each of the seven asks a different question
	-- (jump it / run to a gap / bait it / walk out of the sector / stop camping
	-- / keep moving / jump the rings). Stance 2 and 3 still ADD rather than
	-- replace, so the fight gets denser rather than different.
	--
	-- `bite` and `whipback` are deliberately absent from every list: whipback is
	-- only ever reached as `doublewhip`'s follow, and `bite` is REACTIVE - the
	-- entrenched tick fires it at anyone who parks inside 14 studs of the tower
	-- (see Fn.updateBoss's brinejaw branch and the row's own note).
	phases = {
		{
			below = 1.0,
			attacks = {
				"whip",
				"riptide",
				"tailslam",
				"masonryrain",
				"lunge",
				"geysers",
				"belltoll",
			},
		},
		{
			below = 0.66,
			attacks = {
				"whip",
				"riptide",
				"tailslam",
				"masonryrain",
				"lunge",
				"geysers",
				"belltoll",
				"doublewhip",
				"undertow",
				"coilslam",
				"spines",
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
				"lunge",
				"geysers",
				"belltoll",
				"doublewhip",
				"undertow",
				"coilslam",
				"spines",
				"polyps",
				"spiral",
				"tidalsurge",
			},
		},
	},

	attacks = {
		-- THE WHIP. Jump it - and after the 2026-09-08 playtest ("undodgeable
		-- or really really hard to jump over") the read is now honest, which
		-- is a SPEED change and nothing else.
		--
		-- THE ONE NUMBER THE WHOLE FAMILY IS SET BY: the arm may not turn
		-- faster than 1.7453 rad/s (100.0 deg/s). It comes out of a single
		-- requirement - a player standing at r = 40 gets at least 0.45 s of
		-- warning between the arm entering the 45-degree lead cone on their
		-- side and the lethal lane arriving:
		--
		--   omega_max = rad(45) / 0.45 = 0.785398 / 0.45 = 1.745329 rad/s
		--   duration  = arc / omega_max
		--     whip       rad(340) = 5.934119 -> 5.934119 / 1.745329 = 3.400 s
		--     doublewhip rad(300) = 5.235988 -> 5.235988 / 1.745329 = 3.000 s
		--     whipback   rad(300) = 5.235988 -> 5.235988 / 1.745329 = 3.000 s
		--     spiral     rad(400) = 6.981317 -> 6.981317 / 1.745329 = 4.000 s
		--
		-- SPIRAL IS ALREADY SLOWER THAN THE CAP AND IS LEFT ALONE: at its 4.4 s
		-- it turns 1.5867 rad/s, which buys 0.495 s of lead. Speeding it up to
		-- the cap's 4.0 would be a nerf to the one whip nobody complained
		-- about, so the constraint binds on three rows, not four.
		--
		-- AND THE DRAG PAYS A BONUS THE SPEED CANNOT TAKE AWAY. The arm is a
		-- curve (BrinejawPath.sweepBearingAt): at r = 40 the lane trails the
		-- base bearing by WHIP_DRAG * (40 - 13) * omega, and in TIME that is
		-- WHIP_DRAG * 27 = 0.105 s regardless of how fast it turns. Total read
		-- at r = 40: 0.555 s.
		--
		-- WHY 0.45 IS THE RIGHT FLOOR, against the jump it is asking for: an
		-- R15 jump (JumpPower 50, gravity 196.2) is airborne 0.5097 s and its
		-- root clears the LOW band's ceiling (SWEEP_LOW 1.6 + girth 3.4 = 5.0,
		-- root standing at 3.0, so it needs +2.0) from t = 0.0437 to t = 0.4664
		-- - a 0.4227 s clearance window. The warning is therefore longer than
		-- the entire jump that answers it.
		--
		-- WHAT THE SLOWDOWN DOES NOT CHANGE: the lane's OCCUPANCY. The hit
		-- half-width at r = 40 is atan2(3.4, 40) = 0.08484 rad, so the lane
		-- sits on a fixed point for 2 * 0.08484 / 1.745329 = 0.0972 s - against
		-- 0.4227 s of clearance, a 4.3x margin. It was 0.0743 s before. The
		-- whip was never hard because the lane was wide; it was hard because it
		-- arrived faster than it could be read.
		whip = {
			handler = "orbitsweep",
			tell = false, -- the whip IS the telegraph; no serpentSweep marker
			windup = 1.5,
			duration = 3.4,
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
			tell = false, -- the whip IS the telegraph; no serpentSweep marker
			windup = 1.2,
			-- 2.2 -> 3.0: rad(300) / 1.745329, the whip's cap. See its note.
			duration = 3.0,
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
			tell = false, -- the whip IS the telegraph; no serpentSweep marker
			windup = 0.9,
			-- 2.0 -> 3.0: rad(300) / 1.745329, the whip's cap. The return
			-- stroke was the FASTEST arm in the book at 2.618 rad/s - 50% over
			-- the cap - which is why "jump, land, jump" was the pair players
			-- could not finish.
			duration = 3.0,
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
			-- 1.9 -> 2.5 after the second playtest ("the opening is too small"):
			-- the marker now stands ~3.0 s before the blow instead of ~2.4.
			windup = 2.5,
			duration = 0.85,
			recover = 1.1,
			-- 8.0 -> 12.0. The bait has to be a DECISION, and at 8 seconds
			-- against a stance-1 pool of four it came round often enough to be
			-- a rotation step. In the simulation it is the single largest term
			-- in the whole fight (roughly half the health bar arrives inside
			-- baited staggers), so its cadence is the fight's pace.
			cooldown = 12.0,
			-- 13 -> 10. The lock is already at the player's LIVE position on
			-- the first windup frame, ~2.4 s before the blow, so at walk speed
			-- 16 a player who keeps moving is 38 studs away when it lands; 13
			-- was already clear on paper, but 10 makes "keep moving" a
			-- guaranteed dodge with a stud of margin against a late read, and
			-- leaves the bait (stoneReach 13) the deliberate way to eat it.
			radius = 8.5, -- 10 -> 8.5, second playtest: a moving player must clear it
			lift = 9,
			-- 11 -> 13, and the mechanic is now VISIBLE as well as wider: the
			-- serpentSlam payload carries every standing stone's position, so
			-- the client glows the ones inside this reach of the live aim (the
			-- 2026-09-08 note: "the mechanic exists; nobody can see it").
			-- 13 is two studs of forgiveness on a bait that has to be committed
			-- to 1.9 s before the rattle lands.
			stoneReach = 13,
			-- 8 -> 10. The bait is the fight's main damage term and its
			-- cooldown is 12 s, so the window it buys is what the whole
			-- cadence is paid in. Two more seconds is roughly one more swing
			-- per bait for a party that ran in from mid-arena.
			stagger = 10.0,
			-- 2.2 -> 3.0 -> 4.0. Sand still only jars it, but 2.2 s was under
			-- the travel time to the tower foot from mid-arena - a window
			-- nobody could reach is not a floor, it is a taunt - and 3.0 left
			-- about a second of actual swinging. 4.0 makes a missed bait a
			-- consolation instead of a formality.
			weakStagger = 4.0,
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
			-- 1.1 -> 0.75. How far a chunk's ground marker leads its impact,
			-- and therefore how slowly the bombardment reads. At 1.1 s against
			-- a 0.22 s stagger, five markers were on the sand at once and the
			-- sector looked like a solid field of red rather than a rhythm you
			-- walk out of; at 0.75 it is three, and the walk is legible.
			fall = 0.75,
			radius = 7, -- per-chunk damage circle
			damage = { 24, 34 },
		},
		-- RIPTIDE, REDESIGNED (2026-09-08, contract REVISION 2 §1). It used to
		-- be a directional wall of slabs crossing the arena on one bearing,
		-- answered only by the lee of a rock - and in the playtest that read
		-- as a flat "go stand behind something or take it", with no movement
		-- in it. It is now an EXPANDING RING of sea heaved outward by the
		-- coils, with TWO GAP ARCS you RUN TO.
		--
		-- The ring launches at `inner` (the tower's own foot) and travels out
		-- to `outer` at `speed`; a player is hit once, in the frame the ring
		-- crosses their own radius, unless BrinejawPath.waveSafe says they are
		-- standing in a gap OR in a cover shadow. The cover geometry is KEPT -
		-- it is the secondary answer, and it is what makes the reef stones
		-- matter to more than the tailslam - but the gaps are the read, and
		-- they are marked with foam before the ring moves.
		--
		-- STILL TALL: there is no height band in the test, jumping never
		-- evades it, and it never will.
		riptide = {
			handler = "riptide",
			tell = false, -- fires serpentWave, and the ring is its own tell
			windup = 1.6,
			duration = 3.2,
			recover = 0.9,
			cooldown = 12.0,
			-- THE WATER OUTLIVES THE MOVE, ON PURPOSE. The ring's real clock is
			-- (outer - inner) / speed = 66 / 24 = 2.75 s measured from the END
			-- of the windup, so the serpent is already back at work while the
			-- sea is still going out and the arena has two things happening in
			-- it. Resolved by CreatureService's brine-hazard tick rather than
			-- by this row's `duration`, and BOTH sides read the same `start`.
			speed = 24, -- studs/second the ring expands
			inner = 10, -- launch radius: the ring is born at the tower's foot
			outer = 76, -- past where anybody can stand; it dies there
			-- HOW WIDE A GAP IS, as a half-angle. rad(14) is 28 degrees of open
			-- water, which at r = 40 is a 19.5-stud mouth - two strides wide at
			-- the radius most of the fight is played on, and it only gets wider
			-- as the ring goes out. Narrow enough that standing still is never
			-- the answer.
			gapHalf = math.rad(14), -- 16 -> 14 after the second playtest: a slightly narrower calm arc ("a little harder")
			-- ...and how far apart the two gaps are allowed to be picked. Under
			-- 100 degrees the pair reads as one wide mouth and the move stops
			-- asking anybody to choose; the picker draws a separation in
			-- 100..260 degrees, so the short way round is always 100..180.
			gapSpread = math.rad(100),
			push = 46, -- knockback, OUTWARD along the ring's own radius
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
		--
		-- LEFT AT 4.4 s BY THE 2026-09-08 WHIP SLOWDOWN, and that is a
		-- decision rather than an oversight: rad(400) / 4.4 = 1.5867 rad/s is
		-- already under the family's 1.745329 cap (0.495 s of lead at r = 40
		-- against the 0.45 required), so moving it to the cap's 4.0 would only
		-- speed up the one whip nobody complained about.
		spiral = {
			handler = "serpentspiral",
			tell = false, -- the closing arm is posed; no serpentSweep marker
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
			-- 0.035 -> 0.055 (user, 2026-09-09: "heal it more to make it more
			-- urgent, not too much"): three ignored polyps now return 16.5% of
			-- the bar instead of 10.5% - a real cost, still short of undoing a
			-- baited window.
			heal = 0.055, -- fraction of max health each survivor returns
			radius = 10, -- the detonation's damage circle
			damage = { 30, 40 },
		},

		-- ============================== the four the second pass added ======
		-- All four exist for one reason: the user played the fight and saw
		-- FOUR attacks. These are the ones that make stance 1 seven wide and
		-- stance 2 twelve, and each is a question the book was not yet asking.

		-- GEYSERS, the stance-1 pressure filler and the fight's answer to
		-- STANDING STILL. Eight columns of brine come up through the sand, one
		-- every 0.7 s, and every one of them is aimed at where somebody was
		-- STANDING WHEN THE MOVE BEGAN - the whole list is precomputed at fire
		-- time and sent in the payload (contract §2), so the later bursts are
		-- deliberately stale. Keep walking and none of them find you; stop and
		-- the last six land on your feet.
		--
		-- `scatter` against `radius` is the whole tuning: a burst is placed a
		-- uniform 0..10 studs off the player it was drawn from and hurts within
		-- 6, so standing exactly still is caught by roughly 6^2/10^2 = 36% of
		-- them and one stride out of the marker is caught by none.
		geysers = {
			handler = "serpentgeysers",
			tell = false, -- serpentGeysers' per-burst markers ARE the telegraph
			windup = 1.2, -- >= `lead`, so the first marker still gets its 0.9 s
			duration = 5.6, -- (count - 1) * interval + interval = 8 * 0.7
			recover = 0.7,
			cooldown = 10.0,
			count = 8,
			interval = 0.7, -- seconds between bursts
			radius = 6, -- per-burst damage circle
			-- 10 -> 4, and dealt in volleys of 3 re-aimed at LIVE positions
			-- (Fn.armGeysers): the spikes follow you now. The tight scatter is
			-- what makes it read as pursuit; the 0.9 s lead is what keeps it a
			-- dodge - move off the mark and it erupts behind you.
			-- Second playtest, "follow the user better": ONE burst per volley so
			-- every spike is re-aimed at the live position (paced at `lead`),
			-- and 4 -> 2.5 of scatter. Fn.armGeysers also leads the player's
			-- velocity now. `count` 8 still bounds the run.
			scatter = 2.5,
			volley = 1,
			lead = 0.9, -- how far each burst's marker leads it
			damage = { 22, 32 },
		},

		-- SPINES, the stance-2 volley with SAFE LANES. Ten spines leave the
		-- tower along ten evenly spaced bearings at once and fly outward fast;
		-- the ground BETWEEN them is untouched, so the answer is to be standing
		-- in a gap rather than to be somewhere else. Grounded or airborne makes
		-- no difference - this one is not jumped.
		--
		-- 10 lanes at rad(7) half-width is 140 degrees of lethal ring against
		-- 220 safe: the gaps are the majority of the arena, which is what makes
		-- a 55-stud/second volley fair. Lane k's centre is bearing0 +
		-- k * (2*pi/10) on BOTH sides (contract §3) - the server sends the
		-- bearing0 and the count, never the ten bearings.
		spines = {
			handler = "serpentspines",
			tell = false, -- serpentSpines draws the ten lanes during the windup
			windup = 1.5,
			duration = 1.6, -- reach / speed = 70 / 55 = 1.27 s, plus slack
			recover = 0.8,
			cooldown = 13.0,
			lanes = 10,
			laneHalf = math.rad(7),
			speed = 55, -- studs/second the spine radius travels
			reach = 70,
			damage = { 40, 56 },
		},

		-- COIL SLAM, the stance-2 move that is a THREAT AND AN INVITATION. A
		-- mid-body loop rises off the tower and crashes down along one LINE
		-- through it - a corridor, not a circle, so you step sideways off it -
		-- and then it LIES THERE on the sand for four and a half seconds.
		--
		-- That fallen loop is a FULL-DAMAGE melee window (BrinejawPath's
		-- "coilslam", U 0.50..0.85): the hittable proxy parks on
		-- `coilslamPoint`, the chip scaling steps aside exactly as it does for
		-- the lunge's plant, and the party gets a punish nobody had to bait.
		-- It is the second unearned window in the fight and the first one that
		-- is offered to everybody rather than to whoever is standing furthest
		-- away.
		--
		-- `duration` is not free: the handler spends K.COILSLAM_CRASH (0.22 s)
		-- coming down, K.COILSLAM_SETTLE (0.30) laying out, `hold` on the sand
		-- and K.COILSLAM_RISE (0.70) peeling back up, so it must be
		-- hold + 1.22.
		coilslam = {
			handler = "serpentcoilslam",
			tell = false, -- serpentCoilslam draws the line; the loop is the tell
			windup = 1.6,
			duration = 5.72, -- hold + 1.22
			recover = 1.0,
			cooldown = 15.0,
			hold = 4.5, -- how long the loop lies across the arena
			girth = 5.0, -- the line band's half-width, studs
			damage = { 50, 70 },
		},

		-- THE BITE, AND IT IS NOT IN ANY PHASE LIST. Every other move in this
		-- book comes round on a cooldown; this one is a REACTION. Park inside
		-- 14 studs of the tower for more than two seconds and the head comes
		-- off the coil and snaps at you - the fight's answer to hugging the
		-- masonry, which is otherwise the safest ground on the beach (the whip
		-- cannot reach inside SWEEP_INNER = 13 and the riptide's ring launches
		-- at 10).
		--
		-- And it pays for itself: U 0.45..0.75 leaves the head hanging LOW on
		-- the sand where you are standing - a mini punish window, damageable at
		-- full rate. Taking the bite on purpose is a real, tight play.
		--
		-- `cooldown` is the whole limit on it: 9 s, so a party that lives at
		-- the tower foot eats one every nine seconds rather than one a frame.
		-- See Fn.updateBoss's brinejaw branch for the dwell timer.
		bite = {
			handler = "serpentbite",
			tell = false, -- serpentBite's cone marker is fired from the windup
			windup = 0.7, -- short: it is a reaction, not a set-piece
			duration = 2.51, -- hold + 0.91
			recover = 0.6,
			cooldown = 9.0,
			hold = 1.6, -- how long the head hangs low afterwards
			radius = 9, -- the snap's footprint at the aim
			reach = 14, -- park inside this of the tower and it answers
			dwell = 2.0, -- ...for this long
			damage = { 44, 62 },
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
	-- TWO, NOT THREE, SINCE THE CLIMB WAS CUT - see the `phases` block: the act
	-- the third stance belonged to no longer exists. `stances - (phase - 1)` is
	-- the banner, so this and the row count move together or the banner lies.
	stances = 2,

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
	-- `seamStagger` IS GONE, and its absence is the redesign in one field. A
	-- filled meter no longer opens a fourteen-second window: it SCARS that
	-- flank, permanently, and the pair of scars is what brings both arms down
	-- (CreatureService, the seam cash-out). Act 1 has no punish window at all
	-- now - the window is act 2, and it is `K.PY_ARM_WINDOW` seconds long.

	-- THE TWO ARMS. Act 2's whole content: both come down across the moat onto
	-- the rim path and become creatures you can walk up to and hit, which is
	-- the first melee this fight has ever offered (the moat made act 1
	-- ranged-only by geometry - hitRadius 96 plus a 16-stud reach is eight
	-- studs inside the lake's edge).
	--
	-- NO `at`, AND NO `mounts` LIST. The arms are planted from
	-- `PyreliskPath.armJoints(state, side).fist` through the live pose -
	-- `Fn.pyreliskPlantArm`, the single-part form `Fn.plantKrakenArm` uses.
	-- A `mounts` list cannot express "mirrored by flank" and would be a second
	-- copy of geometry the path module already owns, to be got wrong
	-- separately; this arena has had that exact bug once, in its nine
	-- monoliths.
	--
	-- NO `regrow`, AND THE ABSENCE IS THE ACT BOUNDARY - exactly as it is on
	-- `Bosses.admiral_wrack`. With nothing to reset the count, the second kill
	-- opens act 3 forever.
	parts = {
		row = "pyrelisk_arm",
		count = 2,
	},

	-- HOW LONG THE FALL IS. `K.COLLAPSE_TIME` (2.5) is Brinejaw's, and this
	-- row overrides it because this death has two things to show rather than
	-- one: the colossus coming down, and the caldera opening underneath it.
	-- At 2.5 the lake would drain on the last frame of the body's fall and
	-- nobody would read it as cause and effect.
	--
	-- 4.0, with the caldera write at `K.PY_CALDERA_AT` (2.5): a second and a
	-- half of watching the lake go while the body is still sinking into it.
	-- The two numbers are ONE decision - the second has to land inside the
	-- first with room after it - so they are commented as a pair here and at
	-- the hook in `Fn.updateBossCollapse`.
	--
	-- Slice 4 lands the DURATION; the caldera write itself is slice 5, and
	-- until then this is simply a longer, slower death.
	collapseFor = 4.0,
	-- ...AND THE DEATH IS HANDED ON. `beginBossCollapse` sees this field, holds
	-- the death open for `collapseFor`, and `BossService.onKilled` then calls
	-- `handoff` instead of paying out: the heart is raised in its own room
	-- carrying this party's `healthMult`, `fight.bossId` is re-pointed, the
	-- abandon reaper's grace is re-armed, and nothing mints until the heart
	-- dies. `suppressDrops` is already true for a boss carrying `succeededBy`.
	--
	-- THE STRING IS A `Bosses.items` KEY and is checked by `check_content`.
	succeededBy = "pyrelisk_heart",

	-- PHASE = STANCE = ACT, and the threshold is 0.70 rather than 0.66 because
	-- the health bar stopped being a bar. Nothing damages this colossus
	-- directly; each milestone takes an exact fraction off it
	-- (`Fn.pyreliskChip`), and the two acts' chips are 0.30 and 0.70 - so they
	-- must land EXACTLY on this boundary or a stance change fires in the middle
	-- of an act, with a banner and a new attack pool, silently.
	--
	-- TWO PHASES, NOT THREE, SINCE THE CLIMB WAS CUT (2026-09-12). The arm
	-- climb was act 3 and held a third row at three tenths of the bar; the directive
	-- replaced it with the drop, so the second arm's death is the end of the
	-- fight on the summit and there is no third act to be in. `stances` moved
	-- 3 -> 2 with it: `bossPhaseIndex` -> `ATTR.STANCE` is
	-- `stances - (index - 1)`, so two phases give stance 2 at full health and
	-- stance 1 below 0.70, which is what the banner should say.
	--
	-- THE LEDGER IS GATED. `tools/check_content.py` reads `K.PY_*_FRACTION` out
	-- of CreatureService.luau and this `below` value out of this file and
	-- asserts two equalities across them, the second of which is that the whole
	-- ledger sums to 1.0. Re-tune a chip or the threshold alone and the gate
	-- fails instead of the fight.
	phases = {
		-- ACT 1, THE SHELL. `ventbreath` moves UP into it: act 1 is now the
		-- whole seam game, and `ventbreath` is the longest seam window in the
		-- book (2.4 + 2.6s, and it opens BOTH flanks), so the move that offers
		-- the most seam uptime cannot be locked behind a threshold that the
		-- seams are the only thing that crosses.
		{ below = 1.0, attacks = { "handfall", "rimsweep", "shardhurl", "ventbreath" } },
		-- ACT 2 IS NOT ENTERED BY AN ATTACK, and this row carries the act-1
		-- book rather than a pseudo-move. The act begins when the seam cash-out
		-- calls `Fn.pyreliskDropArms`, and for as long as the stun holds the
		-- boss picks nothing at all (`mode == "stagger"` returns before the
		-- pick).
		--
		-- SO WHAT IS THIS ROW FOR? The 120-second FAILURE branch. When the arms
		-- survive the window they are retired, the colossus stands back up at
		-- exactly health 0.70, and `Fn.pickBossAttack` starts drawing from
		-- HERE. A row holding only a pseudo-move would hand it an attack with
		-- no handler; a row holding the act-1 book hands it the fight it is
		-- returning to.
		{ below = 0.70, attacks = { "handfall", "rimsweep", "shardhurl", "ventbreath", "ashfall" } },
		-- (ACT 3's ROW STOOD HERE, its threshold three tenths of the bar, carrying
		-- { "ashfall", "ventbreath", "crownshed", "shardhurl" } - the climb's
		-- book, with `handfall` and `rimsweep` pruned because the arms were
		-- gone and `crownshed` appearing in this pool and no other. The climb is
		-- cut, the second arm's death ends the fight, and a phase nothing can
		-- reach is a book that cannot be cast. `crownshed`'s attack row and its
		-- handler go in the same unit.)
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
			-- The arm that swings is the arm that strains: this opens the
			-- committing flank's three seams (`state.aimSide`) for the whole
			-- windup and strike. The move you have the longest to read is
			-- also the one that offers the longest shot at a seam.
			seams = "arm",
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
			duration = 1.4, -- the handler lands the blow at 0.95 of this
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
			-- THE FIST STRIKES ONE BAND, ALWAYS. A rooted colossus's arm has
			-- one length, so where its fist can land is a property of the
			-- pose and not of where you are standing: PyreliskPath's
			-- `handfall` puts it at r 188 at the moment of impact, every
			-- time, and the 34-stud shockwave makes that a fixed ring of
			-- path from r 154 to r 222. THAT IS THE MOVE'S SHAPE. Everything
			-- inside r 154 is handfall-safe BY GEOMETRY - the thing cannot
			-- reach its own feet - and what takes that inner strip away from
			-- you is `ventbreath`'s cone and `ashfall`'s marks, not this.
			--
			-- 30, because the monoliths ring the arena at r 158.9 to r 217
			-- and the band has to be able to spend the nearest and the
			-- farthest of them: |188 - 158.9| = 29.1 and |217 - 188| = 29.0,
			-- so 30 covers both ends with a stud to spare and still will not
			-- spend a stone you were nowhere near. If the pose is ever
			-- retuned off r 188, re-derive this from the new radius - the two
			-- numbers are one decision.
			stoneReach = 30,
			-- `stagger` AND `weakStagger` ARE GONE. The twenty-second window
			-- this row used to buy was "the most important number in the
			-- file", and what replaced it is act 2 - a hundred and twenty
			-- seconds in which the colossus does nothing at all. There is no
			-- window to open in act 1 now: the body is untargetable and stays
			-- that way, which is what makes the seams the entire act.
			--
			-- WHAT THE BAIT BUYS INSTEAD. A monolith shattered by the fist
			-- fills this much of the COMMITTING flank's seam meter outright -
			-- two and a half baits is a flank. The nine stones, `stoneReach`,
			-- `Fn.spendStone`, `Fn.regrowStones` and `Fn.restoreStones` all
			-- survive unchanged and all keep meaning what they meant; only the
			-- payout moved, from a window onto the meter that replaced it.
			--
			-- 0.40 AND NOT 0.50, so the bait cannot be the whole route: two
			-- perfect baits leave a fifth of the flank to shoot, and the seams
			-- stay the thing that cannot be missed. It is still the fast lane,
			-- which is what the 2.6-second windup is priced against.
			seamCredit = 0.40,
		},
		-- (`crownshed` STOOD HERE and is cut with act 3: it was the climb's one
		-- aimed hazard, landings banded along the ramp, and there is no ramp and
		-- no third phase to draw it from. Its handler goes from CreatureService
		-- in the same unit, and `Fn.pyreliskRampPoints` - which existed to serve
		-- it - with them.)
		-- THE HERD. The arm draws back low and rakes an arc of the path.
		-- The forearm is the hazard along its whole length, so the danger is
		-- a BAND of the ring, and the band is the outer one: r 160 out to the
		-- arm's full 228, which is most of the walkable path and all of the
		-- shelf under the lip. The answer is to run round the ring, or to
		-- stand inside r 160 and give up the outer band while it passes.
		--
		-- NOT A PINCER WITH `handfall`, whatever the old note here claimed.
		-- The fist lands in a fixed band around r 188 because the arm has one
		-- length (see handfall's `stoneReach`), so this move cannot drive you
		-- onto ground the fist is about to take: the two overlap on the same
		-- middle of the path. What pressures the inner strip is `ventbreath`
		-- and `ashfall`, and the pairing to read is rimsweep with THOSE.
		-- Handler: `rimsweep` (CreatureService, concurrent lane).
		rimsweep = {
			handler = "rimsweep",
			-- The rake loads the whole shoulder: the raking flank's seams
			-- split for the length of it.
			seams = "arm",
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
			radius = 200, -- = PyreliskPath.RAKE_OUT, the outer edge it can rake
			inner = 160, -- and the strip inside this is the survivable one
			girth = 18, -- = PyreliskPath.WALK_ARM_SIZE.Z, the forearm's own width
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
			-- WHOLE-BODY STRAIN. The furnace runs through the trunk, not
			-- through an arm, so every flank seam on the body opens - and it
			-- is the longest window in the book (2.4 + 2.6s) with the boss
			-- committed to one bearing, which is the party's best seam shot.
			seams = "both",
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
			-- The summit sheds: the whole mass heaves and every flank seam
			-- opens with it.
			seams = "both",
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
			-- IT TEARS THE SLAB OFF ITSELF, which is where this whole
			-- system started: the seams it opens doing that are the shell the
			-- row's own comment has always promised you would be shooting.
			-- The throwing flank's.
			seams = "arm",
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

-- ============================================================ the Ashfall Heart
--
-- ACT 4, AND IT IS A SECOND BOSS ROW FOR ONE FIGHT. The colossus's death hands
-- off to this (its `succeededBy`); `handoff` raises it in the heart arena and
-- the party jumps down the caldera to meet it. One Pyrelisk across four acts,
-- so the win is his - see `heartAs`.
Bosses.items.pyrelisk_heart = {
	id = "pyrelisk_heart",
	name = "The Ashfall Heart",
	shortName = "The Heart",
	creature = "pyrelisk_heart",

	-- THE SAME ISLAND, DELIBERATELY. The fight record, the participant set,
	-- `Cleared_volcano` and the ride home all key off `islandId`, and this is
	-- still the volcano's boss - the party never left its fight, only its room.
	islandId = "volcano",
	-- ...WHICH IS WHY `arenaKey` EXISTS. `islandId` says which FIGHT; this says
	-- which ROOM. `BossService.arenaPosition` reads `arenaKey or islandId`, and
	-- without this field `handoff` would raise the heart on the Ashfall
	-- Throne's summit while the party is moved into an empty chamber 40,000
	-- studs away - a boss and its challengers in two different places, with the
	-- fight running. `Fn.spawnBossParts` reads the same field to find the eight
	-- pillar collars.
	--
	-- It is EXACTLY the BossArenas key, not the island id, and it must stay nil
	-- on every other boss: `handoff` uses its presence to decide whether to
	-- honour a dying boss's death position, which is what keeps Admiral Wrack
	-- leaping down onto the sand instead of standing at an arena centre.
	arenaKey = "pyrelisk_heart",
	-- MUST. `Bosses.byIsland` is built by walking `items` and keeping the last
	-- row per island whose `summonable ~= false`; this row and `pyrelisk` both
	-- carry `islandId = "volcano"`, so WITHOUT THIS FLAG which one wins is
	-- decided by Lua's table iteration order - a coin flip re-rolled every
	-- server start.
	--
	-- What it decides: `BossArenaService.init` reads `byIsland.volcano`'s
	-- `arena.radius` and `.pose` to build the Ashfall Throne's floor and pick
	-- the ground profile `verifyGround` checks it against. A heart row winning
	-- the flip builds the volcano at roam 96 with no pyrelisk pose profile, on
	-- some starts and not others, with nothing in the diff to blame. The same
	-- flag `bossHere` skips on, so it also keeps the volcano's Call pointed at
	-- the colossus. One flag, both consumers.
	summonable = false,
	-- MUST. The win has to mint `Heart_pyrelisk` - the id
	-- `Bosses.items.kraken.gate.hearts` already names. Without it the payout
	-- mints `Heart_pyrelisk_heart` and the Kraken's gate silently never opens
	-- for anyone who beat this fight.
	heartAs = "pyrelisk",

	arena = { offset = Vector3.new(0, 0, 0), radius = 96 },
	aggro = 140,
	-- Unreachable on purpose: it is a heart on a dais, and `standoff` is how
	-- close a PROWLING boss comes. This one has `speed = 0` and never moves.
	standoff = 200,
	speed = 0,
	turnRate = math.rad(40),
	-- 13, NOT 26, AND THE DIFFERENCE IS THE `body.scale` MULTIPLY.
	-- `Fn.updateBoss`'s first-frame branch sets
	-- `creature.hitRadius = (def.hitRadius or 0) * (creature.row.body.scale or 1)`,
	-- and the creature row's scale is 2.0 - so this authors a live capture
	-- sphere of 26, which is the number the design asks for.
	--
	-- Author 26 here and the live sphere is 52, in a room of radius 96 whose
	-- pillars stand at r44-70: ranged selection would eat the shots aimed at
	-- the very pillars that are supposed to gate the heart. The Kraken's heart
	-- dodges this by being assigned from an unscaled constant.
	--
	-- IF `body.scale` MOVES, THIS MOVES WITH IT. The two numbers are one
	-- decision and the product is what matters.
	hitRadius = 13,
	submerge = 0,
	riseDepth = 0,
	riseTime = 2.0,
	attackGapMin = 1.2,
	attackGapMax = 2.2,
	enrageBelow = 0.25,
	enrageCooldownMult = 0.55,
	enrageDamageMult = 1.35,
	stances = 1,

	-- THE EIGHT OBSIDIAN PILLARS. `at = "sockets"` takes the authored collars
	-- off `BossArenas.items.pyrelisk_heart` (found by `arenaKey`, above), so
	-- the pillars grow out of the room's own carved feet rather than a guessed
	-- circle.
	--
	-- THE COUNT IS LOAD-BEARING THREE TIMES: eight sockets, eight bits in
	-- `PyreliskPillars`, and this. A ninth socket with no bit behind it is the
	-- failure mode a bitmask has, and it is silent.
	--
	-- NO `regrow`. A broken pillar is broken - the absence is the rule, the
	-- same way it is on `admiral_wrack` and on the colossus's two arms.
	parts = {
		row = "pyrelisk_pillar",
		count = 8,
		at = "sockets",
	},

	phases = {
		{ below = 1.0, attacks = { "ventspit", "heartpulse", "magmarain" } },
		-- Phase two adds the wall, and adds it rather than replacing anything:
		-- the room does not change its language at 45%, it just gets one more
		-- sentence in it.
		{ below = 0.45, attacks = { "ventspit", "heartpulse", "magmarain", "ventbarrage" } },
	},

	attacks = {
		-- THE ROOM'S BREAD AND BUTTER: two to four of the six wall vents throw
		-- globs at marked ground. Handler: `ventspit` (CreatureService), which
		-- is `Fn.throwGlob` with the vent as its origin - the Kraken's
		-- `inkmortar` shape, zero new projectile code.
		ventspit = {
			handler = "ventspit",
			tell = false, -- the marks ARE the telegraph, one per glob
			skin = "lava",
			windup = 0.9,
			duration = 0.6,
			recover = 0.6,
			cooldown = 4.5,
			count = 3,
			spread = 22, -- around the party's own footing, not the room's centre
			flight = 1.6,
			stagger = 0.2,
			radius = 15,
			damage = { 44, 62 },
		},
		-- THE HEART BEATS, and a ring goes out from the dais. Safe at the
		-- middle and safe at the wall - the ring is the space between, which is
		-- most of the room, so the answer is to be committed to one side or the
		-- other rather than drifting.
		--
		-- THE METRONOME THE PILLARS TIGHTEN: every broken pillar multiplies the
		-- heart's cooldowns by `K.PY_PILLAR_STEP`, so this beat speeds up as
		-- the cover comes down.
		heartpulse = {
			handler = "heartpulse",
			tell = "ringTell",
			skin = "lava",
			windup = 1.1,
			duration = 0.8,
			recover = 0.7,
			cooldown = 7.0,
			arm = 1.2,
			inner = 26,
			radius = 84,
			damage = { 38, 54 },
		},
		-- THE CEILING SHEDS ON EVERYBODY. The shipped `barrage` `everyone`
		-- pattern - `ashfall`'s shape in a smaller room, so the marks are
		-- tighter and there is less floor to take them to.
		magmarain = {
			handler = "magmarain",
			tell = "mark",
			skin = "lava",
			pattern = "everyone",
			windup = 1.4,
			duration = 2.0,
			recover = 0.9,
			cooldown = 13.0,
			extra = 2,
			spread = 26,
			arm = 1.4,
			radius = 13,
			damage = { 48, 66 },
		},
		-- PHASE TWO ONLY. All six vents at once, one glob each, NO AIM - it is
		-- a wall you walk out of rather than a thing pointed at you, which is
		-- why it can be this big. Scattered on the floor rather than on the
		-- party, so there is always a somewhere to be.
		ventbarrage = {
			handler = "ventbarrage",
			tell = false,
			skin = "lava",
			windup = 1.5,
			duration = 1.2,
			recover = 1.0,
			cooldown = 16.0,
			count = 6,
			flight = 2.0,
			stagger = 0.12,
			radius = 13,
			damage = { 46, 64 },
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
	-- DRAWN BY A RIG, AND NOT BY `pose`. GnashrootBodyController draws the mud
	-- colossus off Shared/Modules/GnashrootPath; this is the opt-in that tells
	-- CreatureService to publish the channels that controller reads
	-- (Fn.gnashrootPublish). Nothing else in the fight looks at this field.
	--
	-- IT IS A SECOND FIELD RATHER THAN `pose = "gnashroot"` because those are
	-- two different claims, and it stays that way even now that this boss is
	-- rooted. `pose` routes a boss through updateBoss's POSED branch -
	-- placeColossus, colossusState, K.RIG_POSE - machinery built for the
	-- Pyrelisk and the Kraken, whose drawn bodies ARE their arenas. This one
	-- takes the plain branch for every line of its behaviour and is simply
	-- given no reason to walk (see `speed`), which is how Wrack does it too;
	-- only the DRAWING changes. Switching to `pose` would be a rewrite of the
	-- fight's whole update path for a result the row already has.
	rig = "gnashroot",
	-- ROOTED: this must exceed the band's own weapon range or the boss simply
	-- never picks an attack. Mire Flintlock reaches 150 and the hit sphere adds
	-- hitRadius*scale = 9, so 159 studs of pivot distance are connectable; 165
	-- covers it. Not a leash - only the beginBossAttack gates, snaretrap's
	-- x1.2 sweep and the (unused here) `everyone` barrage read it.
	aggro = 165,
	-- COMPLETELY STATIONARY (the user, 2026-09-12: "he must be COMPLETELY
	-- STATIONARY"), and it takes BOTH of the next two lines - Wrack's
	-- arrangement exactly.
	--
	-- `speed = 0` makes updateBoss's prowl move a no-op (it walks
	-- `flatUnit(...) * def.speed * dt`, which is the zero vector), and
	-- `standoff = 200` means that line is never reached in the first place:
	-- the branch is `if dist > def.standoff`, and no player can be 200 studs
	-- away inside an arena whose walkable bank ends at r 70. Belt and braces
	-- on purpose - a future edit that gives this row a speed for some other
	-- reason still cannot make it take a step.
	--
	-- The TURN RATE STAYS. Rooted is not inert: it turns to face whoever it is
	-- watching (`yaw0`, which the rig draws as GnashrootPath.bearing) and its
	-- arms do all the travelling. A boss that could not turn would present the
	-- same flank forever, which is Wrack's design and not this one's.
	standoff = 200,
	hitRadius = 6, -- at scale 1, pivot to the core; x1.5 = 9, the Brinejaw frame
	submerge = 2.4,
	riseDepth = 18,
	riseTime = 3.8,
	speed = 0,
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
			-- apart and never rejoin).
			lunge = 0,
			-- 33, NOT THE MERE'S 27. The old number was GN_MERE_R exactly, and
			-- on a boss that could walk that was a fine story - it waded at
			-- you and the bite owned the pool. Rooted at the centre it is a
			-- bite that can only ever reach open WATER: the mere is r 27 and
			-- the walkable bank starts at 29, so a cone of 27 from the middle
			-- has no player in it, ever. 33 is the snout's own reach (the
			-- authored jaw ends at x 18.4 = 27.6 world, and the gnash lean
			-- throws it further) plus the inner lip of the bank, so this is
			-- the punish for standing on the near peat and nothing more.
			radius = 33,
			-- ...AND IT IS ONLY OFFERED WHEN SOMEONE IS IN REACH. See
			-- `Fn.gnPickAllows`: a close-range move on a boss that cannot
			-- close the distance is otherwise picked at random against a party
			-- standing at r 60, whiffs completely, and burns one of the
			-- fight's attack slots looking broken. 36 is the radius plus the
			-- three studs a player can cover while the 0.75s windup runs.
			maxRange = 36,
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
			-- 48 IS THE ARMS' MEASURED REACH, not a number picked to feel
			-- generous. boss_gen prints it every build: at the row's 1.5 scale
			-- the `hammerLanded` fists stand 40.4 world studs out from the
			-- body's axis and their fingertips ~46, and the furthest planted
			-- pose in the whole book (heavePlant) reaches 47.4. A ring smaller
			-- than that is a slam whose own hands land outside it; a ring
			-- larger is damage with nothing on screen to explain it.
			--
			-- It was 30, sized for the mere's rim when this boss still waded
			-- at you. Rooted, a 30-stud ring never leaves the water: the bank
			-- starts at 29, so the party simply stood at 35 and the fight's
			-- one earned opening could not be earned. The outer bank (48-70)
			-- is `heave` and `wallow`'s ground - both march to ~70 - so
			-- backing out of the hammer is still a real choice and not a free
			-- one.
			radius = 48,
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
	-- ROAM RADIUS 28 -> 70. The sheet under the fight is being rebuilt at
	-- r = 120, and 28 studs of leash made every "it uses the arena" move a
	-- lie: the whale could not travel under the ice far enough to surface
	-- anywhere but on top of you, and Fn.clampToArena pinned every aimed lock
	-- point back toward the middle. The clamp is the one reader of this, so
	-- widening it widens the moves.
	arena = { offset = Vector3.new(0, 0, 268), radius = 70 },
	-- ...and the leash has to be able to REACH the roam. 90/14 was sized for
	-- a 28-stud circle; on a 70-stud one the whale disengaged from a player
	-- standing at the rim, and stood off inside its own kit's minimum ranges.
	aggro = 140,
	standoff = 18,
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
	-- PHASE TWO IS THE ENRAGE, and that is the point of these three numbers
	-- moving together. The fight used to redden the bar at 30% - the same
	-- threshold as its last phase - so the escalation the player could SEE
	-- (the red bar, ATTR.ENRAGED, the client's look) and the escalation they
	-- could FEEL (a bigger moveset) were one event, very late. At 0.5 the
	-- half-health line is the whole turn: the bar goes red, the sheet
	-- shatters, the storm closes and skyfall, flukeslam and whiteout join
	-- the pool. `phases[2].below` is the same 0.5 for the same reason.
	enrageBelow = 0.5,
	-- ...and the multipliers come DOWN as the threshold comes up, because
	-- they now cover half the fight rather than its last third. 0.65 still
	-- reads as pressure (a 9 s breach comes round in 5.9) without collapsing
	-- the gaps the punish windows live in, and 1.25 is what keeps the damage
	-- cap honest: the biggest base hit in the book is 70, and 70 x 1.25 =
	-- 87.5, so no move in this fight may ever one-shot a 100 HP player.
	enrageCooldownMult = 0.65,
	enrageDamageMult = 1.25,
	-- THE FIGHT, REBUILT (kit v2). The verdict on v1 was that nothing landed
	-- on you: the breach flew a fixed 46 studs and came down PAST a player at
	-- standoff, the fluke slam hammered the ice 56 studs behind the nose, and
	-- the carousel pulled on the arena's middle wherever you were standing.
	-- Only the bite connected, so the fight read as a whale rushing you.
	--
	-- THE PRINCIPLE NOW: every attack lands on the player's MARKED position,
	-- the body does the spectacle, and the arena is used in both directions -
	-- UNDER the ice (icebreach travels beneath the sheet and erupts through
	-- it under your feet) and INTO THE SKY (skyfall climbs 70 studs, hangs,
	-- and comes down on the mark with a shockwave you jump rather than
	-- outrun). Damage is still not the only pressure - the wash takes your
	-- footing and the slicks make every later dodge slower - but the marks
	-- are now honest, and both big moves pay for themselves with a beached
	-- window you can kill it in.
	-- THE THREE CHAPTERS, and what each one is FOR.
	--
	-- P1 (100-50%) is the teaching phase and it is deliberately SMALLER
	-- than it was: bite, wash, floequake and the ice breach. Four moves,
	-- one of which is the fight's signature set piece, and all four
	-- answerable from the ice. Skyfall used to open here; moving it out is
	-- what gives the 50% line something to give.
	--
	-- P2 (50-20%) is the turn. The sheet shatters once (`shatter`, forced
	-- by CreatureService's Fn.rfPhaseWatch and in no list here because it
	-- is an EVENT, not a rotation step), the blizzard closes for the rest
	-- of the fight, the ice breach starts chaining (`chain = 2`), and three
	-- moves are gained at once: skyfall, flukeslam and whiteout.
	--
	-- P3 (20-0%) is the same kit weighted: skyfall and whiteout twice each,
	-- so the last fifth is the two moves that use the whole arena.
	phases = {
		{ below = 1.0, attacks = { "bite", "wash", "floequake", "icebreach" } },
		{
			below = 0.5,
			attacks = {
				"bite",
				"wash",
				"icebreach",
				"skyfall",
				"flukeslam",
				"floequake",
				"whiteout",
			},
		},
		{
			below = 0.2,
			attacks = {
				"bite",
				"icebreach",
				"skyfall",
				"skyfall",
				"wash",
				"floequake",
				"whiteout",
				"whiteout",
				"flukeslam",
			},
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
			-- 1.8 -> 3.2. At 1.8 (0.99 enraged) against a 1.6s cycle the bite
			-- was off cooldown before anything else finished, so the picker
			-- came back to it every other roll and the whole fight read as
			-- "the whale rushes and bites". The set pieces are the fight; the
			-- bite is the punish for standing on its head.
			cooldown = 3.2,
			lunge = 14,
			radius = 17,
			cone = math.rad(65),
			damage = { 52, 70 }, -- the book's ceiling: x1.25 enrage = 87.5, under 100
		},
		-- It rises out of the water and LOOKS at someone. No damage: the beat
		-- where nothing is coming is what makes the rest readable, and the
		-- mark tells the party who the next move opens on.
		--
		-- NOT IN THE ROTATION as of kit v2 - the pause it bought is now bought
		-- by the two beached windows, and a third free beat on top of those was
		-- a fight standing still. The row, the handler and the pose are all
		-- kept intact and cost nothing while no phase names it; putting
		-- "spyhop" back in a phase list is the whole re-enable.
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
		-- THE ICE BREACH, and the move `breach` should always have been. The old
		-- one rode the shared `charge`: a FIXED 46-stud run on a bearing latched
		-- at the windup, which against a player standing at the 14-stud standoff
		-- landed 32 studs PAST them. It could not miss more reliably if it tried.
		--
		-- This one hunts UNDER the sheet. It sinks, travels to where you are
		-- GOING (rfAimPoint leads your velocity by 0.35 s) at 30 studs/s with
		-- the crack-web drawn over its head the whole way, and 0.6 s before the
		-- windup ends it LOCKS - stops moving, and the mark goes down on the
		-- ice. Then it comes up through that mark nose-first and topples onto
		-- the floe. The mark is the move: it is placed while you can still walk
		-- off it, and the 0.6 s lock is exactly the reaction budget.
		--
		-- The landing hands `burst` to `beached` and pays the same punish
		-- window the old breach did, shorter (2.0) because it now comes round
		-- on a 9 s cooldown rather than 8.5 s of a move nobody had to dodge.
		icebreach = {
			handler = "icebreach",
			-- Opts OUT of the stock tell, which is drawn at the pivot before any
			-- handler has run - and this whale's pivot spends the windup sliding
			-- across the arena under the ice. The handler fires the only marker,
			-- at the lock point, running through the burst.
			tell = false,
			skin = "frost",
			windup = 2.2,
			duration = 0.7,
			recover = 2.0,
			cooldown = 9.0,
			-- The undersheet hunt: how fast it closes, and how long before the
			-- windup ends it commits. Both are read by the handler, and the
			-- lock time is also the mark's honest countdown.
			hunt = 30,
			lock = 0.6,
			-- HOW MANY TIMES IT COMES UP, from phase two on. `chain = 2` means
			-- the first eruption's recover is cut to 0.8 s and pays NO punish
			-- window: the whale slides back through its own hole and hunts you
			-- again from wherever you ran to, and only the second eruption ends
			-- beached for the full `expose` below. One breach, two marks, one
			-- window - which is what stops the escalation from being 'the same
			-- move, more often'. Read by K.ATTACK_HANDLERS.icebreach, and only
			-- while enraged / phase >= 2; phase one is untouched.
			chain = 2,
			sink = 0.4, -- seconds to bury itself at the start of the windup
			rise = 0.2, -- seconds to shed the submerge as it erupts
			radius = 14,
			damage = { 40, 56 }, -- capped: x1.25 enrage = 70
			push = 62, -- the shattered sheet throws you OUT...
			lift = 34, -- ...and up, which is what makes it read as an eruption
			-- The shattered sheet, left at the burst point. `slick` rather than
			-- the old `trail`: there is no run to leave a trail along any more,
			-- and this is the same spawnPool spec the wash's `slick` uses.
			slick = { radius = 9, duration = 6, slow = 0.55, skin = "frost" },
			expose = 2.0,
			-- The window is the point of the move, so HOLD it: without this the
			-- 0.65-1.25s attack gap (0.36-0.69 enraged) lets the next attack
			-- start a third of the way into it, and the beached pose the punish
			-- is made of ends with it. Opt-in on purpose - see endBossAttack.
			holdExpose = true,
		},
		-- THE SKY SLAM. The other half of "use the arena": if the ice breach is
		-- the whale coming from underneath, this is the whale coming from
		-- ABOVE. It gathers, throws itself ~70 studs up, HANGS at the apex long
		-- enough that everyone in the arena has looked up, pitches over, and
		-- drops flat onto the mark.
		--
		-- TWO HITS, TWO ANSWERS. The 18-stud slam is dodged by leaving the
		-- mark. The shockwave that follows it half a second later reaches 40
		-- studs, and you do NOT outrun that - you JUMP it (the band is
		-- grounded-only; a player in Jumping/Freefall, or more than 3 studs
		-- clear of the impact plane, is spared). That is the one mechanic in
		-- the fight that asks for a timed input rather than a position, and it
		-- is why the hang at the apex is long: the hang is the count-in.
		--
		-- Damage is capped hard. 70 x 1.4 enrage = 98, which is under a 100 HP
		-- player by two points on purpose - this move may never one-shot.
		skyfall = {
			handler = "skyfall",
			tell = false, -- the handler marks the lock point; see icebreach
			skin = "frost",
			windup = 1.6,
			duration = 2.0,
			recover = 3.5,
			cooldown = 14.0,
			radius = 18,
			damage = { 60, 70 }, -- capped: x1.25 enrage = 87.5
			push = 90,
			lift = 55,
			-- THE SHOCKWAVE, and the one place both sides read its numbers.
			-- `shock` is the outer ring (rimeShock draws exactly this), `shockAt`
			-- is how long after the impact it arrives, and `shockDamage` is the
			-- light second pulse for anyone standing in 18 < d <= 40.
			shock = 40,
			shockAt = 0.5,
			shockDuration = 0.7,
			shockDamage = { 18, 26 },
			shockPush = 46,
			expose = 3.5,
			holdExpose = true,
		},
		-- THE FLOE QUAKE. A shoulder-down ram along the sheet: it latches a
		-- bearing toward you at the START of the windup (so the corridor is
		-- drawn once and stays put - a lane that re-aims is not a lane), runs
		-- 60 studs of cracking ice, and everything within 5 studs of that line
		-- is thrown up off the floe. The counter is a sidestep, and it is the
		-- only move in the book whose answer is lateral - which is what stops
		-- the fight from being "stand at range and strafe the marks".
		floequake = {
			handler = "lane",
			tell = false, -- the handler draws the corridor, at its own bearing
			skin = "frost",
			windup = 1.2,
			duration = 0.4,
			recover = 0.8,
			cooldown = 8.0,
			length = 60,
			width = 10, -- the DRAWN corridor's full width; `half` is the hit
			half = 5, -- point-to-segment distance that counts as hit
			damage = { 36, 50 }, -- capped: x1.25 enrage = 62.5
			push = 24,
			lift = 62, -- launched, not shoved: the sheet bucks under you
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
			-- 34 -> 40 and 70 -> 60 degrees, together: the arena went from a
			-- 28-stud circle to a 70-stud one, so a 34-stud wall no longer
			-- reached anybody playing at range - but a wedge that both reaches
			-- further AND stays 70 degrees wide is harder to leave, not easier.
			-- The reach is the buff; the narrower wedge is what keeps "move out
			-- of the way" a real answer at the new distances.
			radius = 40,
			cone = math.rad(60),
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
			damage = { 50, 68 }, -- capped: x1.25 enrage = 85
			-- GATED AT THE PICK, not at the aim. The fluke lands where the TAIL
			-- is, 56 studs behind the nose, and nothing steers it there: on a
			-- 70-stud arena the tail is usually pointing at open ice, so rolling
			-- this move was rolling "the whale does nothing for 2.1 seconds".
			-- With the flag set the picker only offers it when somebody is
			-- actually standing inside `radius` of the fluke's ground point, and
			-- otherwise re-rolls. Rimefang-only, honoured by Fn.rfPickAllows -
			-- a row without the field (which is every other row in the project)
			-- is untouched.
			needsFlukeTarget = true,
		},
		-- THE SHEET SHATTERS: the phase-two opener, fired EXACTLY ONCE per
		-- fight, the moment the health fraction first crosses 0.5. It is in
		-- NO phase list on purpose - it is an event, not a rotation step -
		-- and reaches the loop through the engine's own `forcedAttack`
		-- override, asserted by CreatureService's Fn.rfPhaseWatch until the
		-- move has actually landed (`creature.rfShattered`).
		--
		-- THE READ IS INVERTED. Every other move in this kit marks where YOU
		-- are going; this one marks where IT is - a 26-stud burst drawn on the
		-- whale's own body - so the answer is to be somewhere else rather than
		-- to sidestep. It is invulnerable for the windup and the strike (the
		-- handler stamps the deadline; `damage()` honours it, guarded on this
		-- row), which is the only such window in the fight and is what makes
		-- the beat read as a turn rather than a free 2 s of DPS.
		--
		-- WHAT IT LEAVES BEHIND is the real payload: the four `thinIce`
		-- patches on BossArenas.items.ice become open water - persistent chill
		-- pools, 13 studs, for the rest of the fight - and the blizzard closes
		-- over the arena for the whole of phase two. Damage is the smallest in
		-- the book (30-44, x1.25 = 55) because the arena change IS the cost.
		--
		-- `cooldown` is nominal: it can never come round again.
		shatter = {
			handler = "shatter",
			tell = false, -- the handler draws the burst, at the body
			skin = "frost",
			windup = 1.4,
			duration = 0.6,
			recover = 1.2,
			cooldown = 600.0,
			radius = 26,
			damage = { 30, 44 }, -- capped: x1.25 enrage = 55
			push = 80, -- thrown OUT, the sheet dropping from under you...
			lift = 20, -- ...and barely up, which is what separates it from the
			-- eruption's throw (lift 34). No `storm` block here: the blizzard it
			-- opens has to outlive the move, and Fn.endBossAttack closes any
			-- window the ROW declares. The handler signals it, and
			-- Fn.rfPhaseWatch re-signals it every 12 s for the rest of the phase.
		},
		-- The carousel is GONE (kit v2). It was anchored on the arena's middle
		-- - `at = "anchor"`, and `undertow` reads `creature.anchor` for both
		-- the pull and the bergs - so on the old 28-stud floe it was merely
		-- imprecise and on the new 70-stud one it would be a move that happens
		-- somewhere you are not. Nothing in the kit is allowed to land off the
		-- player's mark any more, and a bait-ball ring has no mark. The shared
		-- `undertow` handler stays; other rows use it.
		--
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
	-- THE DOOR, and it is a WINDOW EVENT rather than a book attack - so it
	-- lives here rather than under `attacks`. DOOR.LEAD (1.6s) before the jaw
	-- shuts, the two limbs flanking the entrance slam down across the doorway,
	-- one each side, landing on the exact frame of the bite. It never seals:
	-- `NoctyssPath.doorTargets` leaves 8 studs of walkable centreline, so the
	-- punish is having to run the middle of it. `false` puts the window back
	-- exactly as it was; the bars are paid at the `stalkslam` row's damage,
	-- because a bar IS a slam.
	portcullis = true,
	aggro = 130,
	standoff = 0,
	hitRadius = 6, -- x2.0 scale = 12: the maw, when it is up
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
	--
	-- AND ABOUT A THIRD OF EVERY LIST IS A LIMB SWINGING. Counting
	-- `feelerstrike`, which is a limb swing too: 3 of 7 in stance 1, 4 of 10 in
	-- stance 2 and 5 of 12 in stance 3 - so in practice a stalk is coming down
	-- on someone every second or third move.
	-- That is the point of the whole tentacle pass: the seven things standing
	-- round the arena are not scenery with hitboxes any more, and the fight has
	-- to keep saying so often enough to be believed.
	--
	-- ELEVEN ROTATION ROWS BECAME EIGHT (legibility pass, 2026-09-12). The kit
	-- was never broken; it was four telegraph languages layered on one unlit
	-- floor, peaking at ~30 lit shapes in five colour families. Three rows went,
	-- and each of them went for a reason that is about READING, not power:
	--
	--   * `abysscall` - twenty-one discs marching out of the pit is the same
	--     cognitive slot `strobewave` already owns (read an expanding shape, be
	--     where it is not) and was the single largest contributor to the mark
	--     count. It also used to be the engine's last-resort fallback; that hole
	--     is closed by DEFERRING instead (Fn.updateNoctyss), because during the
	--     punish window and the regrow dark the fight already has the door, the
	--     jaw and the dark and does not need a filler move.
	--   * `inkveil` - four blind scatter discs is `dousehunt`'s strike with a
	--     worse tell, and its `inkBlast` darkened the same screen `choirDouse`
	--     owns for a different reason. Two systems blacking out one screen is
	--     the "confusing to see what is going on" complaint in one row.
	--   * `falselight` - the only attack in the book with no drawn footprint at
	--     all, and it put three more untimed lights into the one read the whole
	--     fight is built on ("seven lanterns, find the one breathing out of
	--     step"). Its fiction survives in the six false lures already standing
	--     on the shelf; its WEIGHT moves onto the punish for shooting one, which
	--     is earned rather than ambient (Fn.updateNoctyss' flare: 55-75 in r18).
	--
	-- No cooldown, damage or timing number moved with the cut. `lurepull` is
	-- held out of stance 1 on purpose: it is the only move that takes control
	-- away, and it should arrive after the player has learned the floor.
	phases = {
		{
			below = 1.0,
			attacks = {
				"lightsweep",
				"lightsweep",
				"stalkslam",
				"gloomscythe",
				"feelerstrike",
				"strobewave",
				"herdingsnap",
			},
		}, -- 7 entries, limbs 3/7
		{
			below = 0.65,
			attacks = {
				"lightsweep",
				"lightsweep",
				"stalkslam",
				"stalkslam",
				"gloomscythe",
				"feelerstrike",
				"strobewave",
				"lurepull",
				"dousehunt",
				"herdingsnap",
			},
		}, -- 10 entries, limbs 4/10
		{
			below = 0.3,
			attacks = {
				"lightsweep",
				"lightsweep",
				"stalkslam",
				"stalkslam",
				"gloomscythe",
				"gloomscythe",
				"feelerstrike",
				"strobewave",
				"lurepull",
				"dousehunt",
				"dousehunt",
				"herdingsnap",
			},
		}, -- 12 entries, limbs 5/12
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
		-- ------------------------------------------- the limbs themselves
		--
		-- THE THREE PHASE LENGTHS ARE NOT FREE ON ANY OF THE NEXT THREE ROWS.
		-- A swing's pose, its floor mark and its hitbox are all derived from
		-- ONE descriptor's `start` against NoctyssPath's own phase table, on
		-- both sides - so a row whose windup disagreed with the path's would
		-- animate one attack while the server ticked another. Each row's
		-- numbers are named against the constant they have to equal, and the
		-- three of them always sum to `NoctyssPath.attackDuration`, so the
		-- engine's attack and the limb's swing retire on the same frame.
		--
		-- `tell = false` on all three, like everything else in her book: the
		-- client draws every one of these telegraphs itself, off the
		-- descriptor, at the exact radius the server tests.

		-- ONE STALK'S LANTERN GOES OUT, the limb rears, and the whole stalk
		-- comes down along a line drawn on the stone from its own collar.
		-- FAIR: the windup is 1.2s against a stripe 7 studs to either side, so
		-- the dodge costs 7 studs of walking - 0.44s at a walk of 16 - and the
		-- tell is the loudest thing that can happen in a room lit by seven
		-- lanterns, one of them going out. A heavy single hit, not a tick: the
		-- handler lands it at most once per player per swing.
		stalkslam = {
			handler = "stalkslam",
			tell = false,
			skin = "ink",
			windup = 1.2, -- = NoctyssPath.SLAM.WINDUP
			-- = SLAM.LIVE, not SLAM.STRIKE (0.25). The limb lying across the
			-- stone stays dangerous after it has stopped travelling, so the
			-- engine's strike phase is stretched to cover the whole window the
			-- path calls live - otherwise the last 0.15s of the hitbox would
			-- tick inside a phase whose handler is the recovery.
			duration = 0.4,
			recover = 1.45, -- = SLAM.RECOVER (1.6) less the 0.15 borrowed above
			cooldown = 6.5,
			damage = { 34, 40 },
		},
		-- IT BOWS UNTIL THE EYE IS ON THE STONE and then walks that eye around
		-- its own socket. The pool of light crawling across the floor arrives
		-- before the limb does - visible from behind as a glow rising off the
		-- ground - which is what makes a 75-degree sweep survivable in locked
		-- first person. FAIR: the dodge is the radial step out of the band,
		-- 6.5 studs and always available (0.41s at a walk of 16), not a
		-- footrace with the tip - at the clamp's far end (reach 30) the eye
		-- travels 17.9 studs/s and outruns a player, which is why the band is
		-- narrow and the bow is 0.9s of warning.
		gloomscythe = {
			handler = "gloomscythe",
			tell = false,
			skin = "lure",
			windup = 0.9, -- = NoctyssPath.SCYTHE.BOW
			duration = 2.2, -- = SCYTHE.SWEEP; the eye is live for exactly this
			recover = 1.1, -- = SCYTHE.RECOVER
			cooldown = 8.0,
			-- 0.45, ABOVE Tuning's 0.35 i-frame. A tick landing inside the
			-- contact window is refused outright, so a faster interval is not
			-- more damage - it is a number in the book that means nothing. The
			-- eye dwells ~1.0s over a player at the default reach, so standing
			-- in the band costs two ticks and a third if you are slow.
			tick = 0.45,
			damage = { 20, 24 },
		},
		-- Something comes out of the dark and spears the spot you are standing
		-- on. Short arm: the punish for standing still after a pull, and the
		-- move `lurepull` follows itself with.
		--
		-- IT IS A REAL LIMB NOW. This was a `barrage` of blind circles under
		-- everyone at once - no arm, no direction, nothing to read - and it is
		-- the same jab the other two are: one stalk, one latched point, coil
		-- and spear and snap back. The damage is untouched, because what it
		-- costs to be caught by it has not changed; only the honesty has.
		feelerstrike = {
			handler = "feelerstrike",
			tell = false,
			skin = "ink",
			windup = 0.5, -- = NoctyssPath.JAB.COIL
			duration = 0.22, -- = JAB.THRUST + JAB.HOLD, the whole live window
			recover = 0.45, -- = JAB.RETURN
			cooldown = 2.2,
			damage = { 38, 52 },
		},
		-- ------------------------------------ the head throwing the limbs
		--
		-- TWO ADJACENT LIMBS SLAM ONTO A V whose point is on the pit's rim,
		-- and then she snaps at that rim. This is the first move in the book
		-- that is the HEAD using the choir: the limbs are the ordinary slam -
		-- same pose, same capsule, same peel - and what is new is only who
		-- chose the two targets and what arrives after them.
		--
		-- THE V DOES NOT PUSH YOU IN. Its tips OVERLAP by 4 studs, so the
		-- point of the funnel is shut and its only opening is the wide end out
		-- at the collars. The trap is that the safe-looking direction - away
		-- from the two limbs, into the dark middle - is the pit, and the pit
		-- is what is about to bite.
		--
		-- THE THREE PHASE LENGTHS ARE NOT FREE, exactly as on the three rows
		-- above, and here they answer to TWO clocks that have to end together:
		--   windup  1.2 = NoctyssPath.SLAM.WINDUP, so the bars land on the
		--                 beat an ordinary slam would;
		--   the snap starts on that same frame and runs
		--                 SNAP.RISE 1.0 + SNAP.BITE 0.3 + SNAP.SINK 0.9 = 2.2;
		--   duration 0.4 = SLAM.LIVE, the bars' own live window;
		--   recover  1.8 = the remaining 2.2 - 0.4 of the snap.
		-- So the engine lets go on the frame `NoctyssPath.snapFor` retires the
		-- snap (1.2 + 2.2 = 3.4s), and the bars' descriptors - which need only
		-- 1.2 + 0.25 + 1.6 = 3.05 - expire under it rather than outliving it.
		--
		-- FAIR: a full second of mouth breaching out of the floor is the tell
		-- for the bite, and it arrives AFTER the bars have already drawn where
		-- the funnel points. The bitten disc is the pit plus SNAP.MARGIN 4, so
		-- a player herded onto the rim itself walks 4 studs to leave it - 0.25s
		-- at a walk of 16, against 1.0s of warning. It is bite-class damage
		-- because it is her bite: the same 70-95 the jaw deals to anyone still
		-- standing in her mouth when it shuts.
		--
		-- The 14s cooldown puts it at roughly once per punish cycle (15s of
		-- window plus 4s of dark), which is the cadence a set piece wants: the
		-- thing that happened last time round, not the thing that keeps
		-- happening. Gated out of the rotation whenever the maw is up, coming
		-- up or sinking - see Fn.choirMoveReady.
		herdingsnap = {
			handler = "herdingsnap",
			tell = false,
			skin = "ink",
			windup = 1.2, -- = NoctyssPath.SLAM.WINDUP; the bars land here
			duration = 0.4, -- = SLAM.LIVE
			recover = 1.8, -- = snapDuration (2.2) less the 0.4 above
			cooldown = 14.0,
			damage = { 70, 95 },
		},
		-- `inkveil`, `falselight` and `abysscall` STOOD HERE and were cut by
		-- the legibility pass (2026-09-12); the three paragraphs above `phases`
		-- say why, one each. The HANDLERS they rode (`barrage`, `decoys`) are
		-- shared with half the book and are untouched - only the rows went, so
		-- nothing outside this fight moves by a stud. Do not re-add one without
		-- reading the mark-count arithmetic in that note: eleven rotation rows
		-- is what "too confusing to see what is going on" looked like.
		--
		-- EVERY LANTERN GOES OUT AT ONCE. Real darkness, for `dark` seconds,
		-- and then a strike where you were standing when the lights died.
		-- The fight's best scare and its cheapest attack: it spawns nothing,
		-- it just stops being able to be seen by.
		dousehunt = {
			handler = "dousehunt",
			tell = false,
			-- LURE, NOT INK, and this row is the reason the split exists: the
			-- skin is the tell LANGUAGE, and her two languages are her lights
			-- (`lure`) and her limbs (`ink`/limb violet). `dousehunt` is the
			-- lights themselves going out, so it is a light attack in the only
			-- sense that matters to a player reading the floor. As `ink` its
			-- marks fell through to the stock PULSED draw - a mark that blinks
			-- under 1.6s of opaque blackout is a mark nobody sees - where the
			-- lure skin's persistent edge+fill holds steady for the whole
			-- `tellHold` window and is still there when the dark lifts. The
			-- readability arithmetic below (`arm` 0.65, `tellHold` 1.25) now
			-- buys a visible mark instead of a blinking one. CEC gates the
			-- lure-pull rim cache off these, so the 9-stud discs cannot steal
			-- it from the pull that owns it.
			skin = "lure",
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
			-- ...AND THE TELL HAS TO BE VISIBLE FOR THAT WHOLE 0.65s, which
			-- until now it was not: the strike's mark was drawn on the frame
			-- the lights died and landed 0.65s later, with 1.6s of opaque
			-- blackout on top of it. A 44-60 hit with a drawn, invisible tell,
			-- and the arithmetic above quietly assumed a player who knew which
			-- way to run. `tellHold` holds the HIT back (the mark is still
			-- drawn at the lights' death, where you were standing) until the
			-- blackout starts lifting, so the last `arm` seconds of the mark
			-- are the first `arm` seconds anyone can see it.
			--
			-- 1.25 IS `dark` (1.6) LESS 0.35, and 0.35 is exactly how long
			-- CreatureEventController holds the lift before the dark ends. The
			-- two numbers are one number; move either and move both.
			tellHold = 1.25,
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
	-- `regrow` IS GONE (see the note on its grave, below the mounts): the four
	-- corner cannons are permanent and the fourth kill is the act-one -> act-two
	-- transition. `staggerFor` survives it and changes job - it is no longer the
	-- silence at the top of a repeating window, it is the silence at the ACT
	-- BREAK: the guns fall quiet, the hull lights, the ports come open, and the
	-- ship starts shooting for herself.
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
			-- THE FOUR CORNERS, in the mesh's canonical order (WR_GUNS, and
			-- WrackBodyController's PIECES: Wrack_CannonBowStbd, BowPort,
			-- SternStbd, SternPort). Sponsons at +-30 / +-150 degrees,
			-- centroid r 19.0, wholly OUTBOARD of the hull - "all 4 corners of
			-- the main ship should be the 4 cannons" (user, 2026-09-09).
			Vector3.new(16.45, 13.20, -9.50), -- BowStbd:   bearing  -30, r 19.0
			Vector3.new(16.45, 13.20, 9.50), -- BowPort:   bearing  +30, r 19.0
			Vector3.new(-16.45, 14.00, -9.50), -- SternStbd: bearing -150, r 19.0
			Vector3.new(-16.45, 14.00, 9.50), -- SternPort: bearing +150, r 19.0
		},
		-- `regrow` IS DELETED, AND ITS ABSENCE IS THE ACT BOUNDARY.
		--
		-- It used to be 20: the four decks grew back twenty seconds after the
		-- last one fell, and the fight was a loop - silence them, burst the
		-- hull, watch them stand up, do it again against a denser phase. The
		-- user asked for something else: "when the 4 cannons are destroyed,
		-- phase 2 begins where the main ship is what is shooting out of now".
		--
		-- So the cannons are PERMANENT. Nothing else had to be built for that:
		-- `damage()` already refuses the hull while `partsAlive > 0` and
		-- `kill()` already counts down, so with nothing to reset the count the
		-- fourth kill opens the hull FOREVER and act one ends. The transition
		-- is the removal of a field, not a state machine - which is why there
		-- is a comment here at all. An empty line would read as an oversight
		-- and the next person would helpfully put the 20 back.
	},
	-- THE RIGGING: the three pieces of the ship that MOVE, in the same boss-local
	-- convention as `parts.mounts` above (X/Z local to the hull's authored frame,
	-- Y the piece's own CENTRE measured from the DRAWN hull's sand;
	-- `Fn.wrackMountPoint` applies the `halfThickness` and `submerge` corrections
	-- at the consumption site, so do not pre-apply either).
	--
	-- THE MESH HANDOFF LANDED (2026-09-09), restated by the mesh lane in THIS
	-- convention rather than converted here: Roblox space, boss-local, Y the
	-- piece's own CENTRE measured from the drawn hull's sand. Converting a
	-- Blender triple at this end would have been the same transform applied
	-- twice, once by each lane, with neither owning it.
	--
	-- `Fn.wrackRigging` reads these and stops warning; its geometry-derived
	-- fallbacks stay in place for the one entry that is still pending.
	rigging = {
		-- Where the figurehead unships: square on the centreline at the stem.
		-- The bow chaser is gone with the corner-sponson rebuild, so she comes
		-- off the stem itself rather than beside it.
		dock = Vector3.new(20.20, 6.40, 0.00),
		-- The main boom's pivot: the starboard rail socket. `boomLen` on the
		-- boomsweep row is 30.0 and comes from the same handoff, so the two
		-- numbers are now measured rather than provisional.
		boom = Vector3.new(-6.50, 12.57, -5.24),
		-- THREE HATCHES, NOT FOUR, and the count is load-bearing rather than
		-- incidental: `ATTR.WRACK_HATCHES` is a BITMASK whose bit (i-1) is
		-- piece `Hatch<i>` on the client, and the ship exports exactly
		-- Hatch1..Hatch3. A fourth entry here would set a bit with no piece
		-- behind it - the mask and the names would stop agreeing in silence,
		-- which is the whole failure mode a bitmask has. bilgeblow's mask
		-- writes are sized off `#hatches` for the same reason.
		hatches = {
			Vector3.new(-6.00, 11.01, 3.20), -- Hatch1: hinge on its forward edge
			Vector3.new(-9.00, 11.47, 3.40), -- Hatch2: clear of the boom socket
			Vector3.new(-10.00, 11.59, -3.80), -- Hatch3: hinge on its inboard edge
		},
	},
	-- The burst window's shape, read by the Wrack handlers in CreatureService
	-- (not by the engine): `staggerFor` seconds of true silence the moment the
	-- last deck falls, then a skeleton crew firing at `windowFire` of normal
	-- density for the rest of it. The window is a burst you dodge inside, not
	-- a free damage phase.
	staggerFor = 4.0,
	-- `windowFire` IS RETIRED, and it is retired rather than left at 0.3.
	--
	-- It meant "the density a skeleton crew keeps up while the hull is open,
	-- before the decks stand back up" - a number that only makes sense inside a
	-- loop that comes back. There is no coming back now: past the stagger the
	-- guns are gone for good and the SHIP is the emitter, at full strength.
	-- `Fn.wrackScale` returns 1.0 there. Leaving 0.3 on the row would have left
	-- act two firing at a third of its intended density with a field name that
	-- described the old fight, and nothing anywhere would have said so.
	--
	-- ACT TWO'S OWN WINDOW is a different mechanic with a different name below:
	-- `acts.crackEvery` / `acts.crackFor`, driven by DAMAGE TAKEN rather than
	-- by a clock, because a window the player earns is the point of act two.
	acts = {
		-- Every 20% of the hull's bar you take off her, she cracks open for
		-- `crackFor` seconds: `ATTR.EXPOSED` on, double damage through the
		-- shipped `exposedUntil` path, and the next attack held off until it
		-- shuts. Four cracks across act two, paid for in damage.
		--
		-- This reuses the engine's `expose` machinery whole rather than growing
		-- a second window: the same field the charger's turn and the kitted
		-- rows already set, the same 2x in `hitModifiers`, the same attribute
		-- the client already opens the shells on. Nothing new is drawn and
		-- nothing new is wired.
		crackEvery = 0.20,
		crackFor = 3.0,
	},
	-- THE FIGHT DOES NOT END WHEN THIS CREATURE DIES. The hull reaching zero is
	-- the act-two -> act-three transition: BossService's `onKilled` sees this
	-- field, spawns `wrack_duel` at the wreck as the island's active boss, and
	-- returns BEFORE the heart, the coins, the unlock banner or the ride home.
	-- Only the Admiral's own death pays any of that, and it pays it as
	-- `admiral_wrack` (see `heartAs` on the duel row).
	--
	-- The wreck beat is already aimed correctly and was not moved:
	-- `ProjectileService.watch` fires the ring of gun-deck explosions and the
	-- hull's splash when this creature goes, which IS the ship sinking. The
	-- Admiral gets his own, smaller, human-scale ending.
	succeededBy = "wrack_duel",
	-- HOW LONG SHE TAKES TO GO DOWN. `beginBossCollapse` takes her death and
	-- holds it open for this long while `ATTR.WRACK_WRECK` ramps 0 -> 1; the
	-- client eases her list and her mast fall off that level, and
	-- ProjectileService's closing volley of gun-deck explosions fires at the end
	-- of it, when the model finally goes. Without the hold she blew up on the
	-- same frame she stopped existing.
	wreckFor = 2.5,
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
	-- THE PHASE TABLE, AND THE RULE IT IS BUILT TO (re-cut 2026-09-09 for the
	-- ship's own three moves). Sort every move in the fight by WHAT THE PLAYER'S
	-- BODY HAS TO DO, because that is the only thing two live mechanics can
	-- actually contend for:
	--
	--   (a) READ AND WALK - a pattern with a shape and a hole in it: grapeshot,
	--       broadside(Heavy), wisps, anchorsweep, anchorline, and bilgeblow.
	--   (b) BREAK A CLOCK - something you must put damage into before its timer
	--       runs out: powderrun(Twin), ghostbraziers, cannonoverload, longboat,
	--       ladybelow, boomsweep.
	--
	-- A phase may run BOTH classes and no more, and this table keeps that promise
	-- structurally rather than by hope: the only mechanics that outlive the attack
	-- that made them are the powder keg's fuse and the longboat's march (both on
	-- `creature.wrackKit`), so those are the only two that can ever be live under a
	-- following move. All three of the new ones finish inside their own row - the
	-- Lady re-docks, the boom stows, the lids shut - which is why they can be added
	-- to a list this long without stacking a third thing on the screen.
	--
	-- WHY EACH ONE LANDS WHERE IT DOES:
	--   * `ladybelow` opens in PHASE 1, beside the powder keg. Both are class (b)
	--     and they teach the same verb in its two forms - the keg says "shoot the
	--     thing that is coming for you", the Lady says it again about something too
	--     fast to walk away from - and phase 1 is where a verb has room to be
	--     learned. She is the first thing in the fight that MOVES.
	--   * `boomsweep` arrives in PHASE 2 with the braziers and the anchor line,
	--     which is the phase that first asks the party to be somewhere specific.
	--     It is the fight's first statement about the NEAR RING, and it is a
	--     statement the player can answer twice (leave, or shoot the tackle).
	--   * `bilgeblow` waits for PHASE 3 and is there FOR `cannonoverload`. The
	--     overload is the one move that pays a party for standing still with its
	--     guns on one battery for three seconds; the geysers are the one move that
	--     takes the ground between the hull and the drop ring away. Scheduling them
	--     in the same list is the fight finally charging for greed in a way that is
	--     coherent rather than arbitrary - the jam is still worth taking, and it now
	--     costs footwork instead of nothing. (It sits alongside `longboat` for the
	--     same reason and with no class conflict: the boarders are class (b) and
	--     they march THROUGH the geysers unharmed, because eruptions damage
	--     players. That is not an oversight - they know their own ship.)
	--
	-- Phase 3 is a twelve-entry list, and that is a frequency decision, not a
	-- density one: only one attack is ever running, and the picker takes whatever
	-- is off cooldown. A longer list makes each move RARER and the phase more
	-- varied; the cooldowns are what set the pressure, and they were not touched.
	-- THE TABLE IS ACT-GATED NOW, AND IT DOES IT ON ONE SYNTHETIC DIAL.
	--
	-- Acts advance on EVENTS - the fourth permanent gun kill, then the hull
	-- reaching zero - while `Fn.bossPhaseAttacks` only speaks health fractions.
	-- Rather than teach the engine about acts, the Wrack tick writes
	-- `creature.actFraction` and `Fn.bossPhaseFraction` prefers it, monotonic
	-- and continuous across both acts of this creature:
	--
	--     act 1:  0.60 + 0.40 * (gunsAlive / 4)    4:1.00 3:0.90 2:0.80 1:0.70
	--     act 2:  0.60 * (hull hp / hull max)      full:0.60  dead:0.00
	--
	-- Act 1 therefore SUB-PHASES ON GUNS DESTROYED, which is the only clock it
	-- has: the hull is immune, so its health never moves and a health-fraction
	-- table would have left act one on band one forever. Act 2 sub-phases on
	-- real damage, as every other boss does. Nothing else in the game sets
	-- `actFraction`, so no other fight changes by a byte.
	--
	-- ACT 3 IS NOT HERE. It is a different creature with its own row
	-- (`wrack_duel`) and its own table on the ordinary health fraction.
	--
	-- THE TWO-CLASS CAP HOLDS IN ALL FIVE BANDS - (a) read-and-walk, (b) break
	-- a clock - and `assets/wrack_patterns_gen.py` now CHECKS it in its HANDOFF
	-- block rather than this comment asserting it.
	--
	-- WHAT MOVED BETWEEN THE ACTS, AND WHY. Act one is the CANNONS' kit: every
	-- row in its two bands is a move that comes out of a gun barrel (grapeshot,
	-- broadside, cannonoverload, anchorline, powderrun). Act two drops all five
	-- of those - the guns are wrecked, they cannot fire - and picks up the
	-- SHIP'S OWN body instead: the figurehead diving, the boom sweeping, the
	-- bilge blowing, the wisps, the braziers, the boarding party. Broadside is
	-- the one row that crosses the boundary, because it stops coming from four
	-- cannons and starts coming from the gunports, which is the same shape from
	-- a different mouth - and it is the signature, so the fight would lose its
	-- accent without it.
	phases = {
		-- ACT ONE, four and three guns standing.
		{ below = 1.0, attacks = { "grapeshot", "broadside", "powderrun", "cannonoverload" } },
		-- ACT ONE, two and one. The screen thins as they fall (every pattern's
		-- count scales with `partsAlive`), so the list gets heavier to
		-- compensate: heavy broadsides, and the anchor line's long telegraph.
		{
			below = 0.80,
			attacks = { "grapeshot", "broadsideHeavy", "powderrun", "cannonoverload", "anchorline" },
		},
		-- ACT TWO opens: the ship wakes and shoots for herself.
		{ below = 0.60, attacks = { "broadside", "wisps", "ladybelow", "bilgeblow" } },
		{
			below = 0.40,
			attacks = { "broadside", "wisps", "ladybelow", "boomsweep", "ghostbraziers", "longboat" },
		},
		{
			below = 0.20,
			attacks = {
				"broadsideHeavy",
				"wisps",
				"ladybelowTriple",
				"boomsweep",
				"ghostbraziers",
				"longboat",
				"bilgeblow",
				"anchorsweep",
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
		-- ============================================ the ship itself (2026-09-09)
		-- Eleven moves in, the HULL had still never moved. These three take a piece
		-- of her and swing it: the figurehead unships and hunts, the main boom
		-- sweeps the near ring, and the bilge hatches blow outward. Their handlers
		-- are in CreatureService's "Wrack: the ship itself" section and they inherit
		-- every rule of the five above - latched aim, their own telegraph, gated on
		-- `wrackWillFire`, and nothing touched on the phase machine.

		-- THE LADY BELOW. Two telegraphed lane dives, then she re-docks.
		--
		-- WHY THE NUMBERS ARE THESE NUMBERS:
		--   * `windup` IS `lead`, and both are the tell's own lead. She swings out
		--     from the prow to the lane's start over exactly that window, at a speed
		--     the handler computes from the distance (the anchor line's rule), so the
		--     telegraph's countdown and her arrival at it are one clock.
		--   * `approach`/`pastBy` 56/56 make the pass 112 studs long, CROSSING the
		--     latched player at its middle. The tell is drawn over that same 112
		--     studs: the lane that hurts is the lane that was drawn.
		--   * 54 studs/s crosses it in 2.1 s. The dodge is SIDEWAYS: a 12-stud lane
		--     wants 6 studs plus your own width of clearance, about 0.5 s at the
		--     16-stud walk, against a 1.1 s lead. Comfortable on purpose - she is a
		--     hunt, not a reflex test, and there are two or three of them.
		--   * `duration` 8.4 covers the whole flight: 2 x (lead 1.1 + pass 2.1 +
		--     re-arm 1.1) less the first lead (the windup already spent it), plus the
		--     0.8 re-dock. A move whose strike ran out under its own animation would
		--     have `finish` despawning her in mid-air.
		-- TELL: one "wrackTell" lane per dive, drawn over the exact span she flies.
		ladybelow = {
			handler = "ladybelow",
			tell = false,
			skin = "wisp",
			windup = 1.1,
			duration = 8.4,
			recover = 0.9,
			cooldown = 19.0,
			rows = { "wrack_figurehead" },
			dives = 2,
			lead = 1.1,
			rearm = 1.1,
			redock = 0.8,
			speed = 54,
			approach = 56,
			pastBy = 56,
			lane = 12,
			fly = 7,
			-- One pass, against the anchor line's 56-74 for a comparable telegraphed
			-- corridor. Eating both passes is 124-168: a bad night, not a death from
			-- full, which is the right price for a move you can also simply shoot.
			damage = { 62, 84 },
		},
		-- Phase 3's version: three passes and a tighter lead. Her health does not
		-- change, so the "end her a dive early" trade gets CHEAPER as the fight gets
		-- worse - the party that learned the verb is paid for it late.
		ladybelowTriple = {
			handler = "ladybelow",
			tell = false,
			skin = "wisp",
			windup = 1.0,
			duration = 11.6,
			recover = 0.9,
			cooldown = 21.0,
			rows = { "wrack_figurehead" },
			dives = 3,
			lead = 1.0,
			rearm = 1.0,
			redock = 0.8,
			speed = 56,
			approach = 56,
			pastBy = 56,
			lane = 12,
			fly = 7,
			damage = { 64, 88 },
		},

		-- THE MAIN BOOM. A 140-degree sweep of the near ring over three seconds.
		--
		-- THE ARITHMETIC IS THE MOVE, and it says one thing: THERE IS NO TANGENTIAL
		-- ESCAPE. 140 degrees in 3.0 s is 46.7 deg/s, which at the band's outer edge
		-- (34) is 27.7 studs/s against a 16-stud walk, and even at the inner edge
		-- (24) it is 19.6. Running around the ship loses at every radius. The exits
		-- are RADIAL - out past 34, or in against the hull - and there are 2.2 s of
		-- windup plus half the sweep to take one, about 0.5 s of walking from
		-- mid-band. So the move costs an attentive player nothing and takes a health
		-- bar off one standing on the near ring committed to something else. That is
		-- the point of it, and it is why the phase table puts it beside the moves
		-- that ask you to stand there.
		--   * `inner` 24 is the drawn hull's own half-length (the mesh HANDOFF's
		--     48 x 12.6 box): the sweep starts at the ship's side, not on top of it.
		--     It is provisional only in that the true hull-edge arrives with
		--     `rigging` below; it is a measurement, not a guess.
		--   * `width` 10 is the spar's own footprint, tested as a PERPENDICULAR
		--     distance so it is ten studs wide at every radius rather than a wedge
		--     that fattens as it goes out.
		-- TELL: a "ringTell" annulus over the band for the whole windup, a
		-- "wrackTell" lane along the bearing the swing STARTS from, and the spar
		-- itself - up, over the sand, and shootable from the first windup frame.
		boomsweep = {
			handler = "boomsweep",
			tell = false,
			skin = "chain",
			windup = 2.2,
			duration = 3.2,
			recover = 1.0,
			cooldown = 21.0,
			rows = { "wrack_boom_tackle" },
			arc = 140,
			sweep = 3.0,
			inner = 24,
			outer = 34,
			width = 10,
			boomLen = 30,
			tackleFly = 6,
			-- Once per sweep - a line crosses you once. High, because it is entirely
			-- avoidable and because the move is a punish rather than a pattern.
			damage = { 66, 88 },
		},

		-- BILGE BLOW. Three hatches in sequence, a geyser marching outward along
		-- each one's radial. THE ONLY MOVE IN THE FIGHT WITH NOTHING TO SHOOT.
		--
		--   * The columns run r 26 to r 71 (`startAt` + 5 x `spacing`) - the near
		--     ring and the whole middle of the beach, taken away in three lines.
		--   * `arm` 0.85 with 0.30 between steps: each disc is told while the one
		--     before it is still in the air, so a column reads as a DIRECTION to step
		--     off rather than as six separate dodges.
		--   * `hatchGap` 0.9 staggers the three, and the handler opens with the hatch
		--     whose radial points nearest the latched player - it takes the ground he
		--     is standing on first.
		--   * `duration` 4.6 covers the last hatch's last eruption (2 x 0.9 + 0.85 +
		--     5 x 0.30 + 0.3 = 4.45). It would be SAFE if it did not - the eruptions
		--     are `creature.strikes`, which the creature walk owns and drops with the
		--     boss - but the HATCH LIDS shut in `finish`, and a lid shutting over a
		--     live geyser would read as a bug in the ship.
		--   * 46-62 per geyser is the lowest band in the moveset on purpose: three
		--     columns of six discs can catch one player twice, and this move's job is
		--     to move him, not to kill him.
		-- TELL: a "ringTell" annulus over the whole column band during the windup,
		-- then the arsenal's own "mark" disc per eruption, one `arm` ahead of each.
		bilgeblow = {
			handler = "bilgeblow",
			tell = false,
			skin = "ember",
			windup = 1.3,
			duration = 4.6,
			recover = 0.9,
			cooldown = 24.0,
			hatchGap = 0.9,
			steps = 6,
			spacing = 9,
			startAt = 26,
			interval = 0.30,
			arm = 0.85,
			radius = 7,
			damage = { 46, 62 },
		},
	},
}

-- ============================================================ The Careenage, act three
-- ADMIRAL WRACK'S DUEL. The second Bosses row on one island, and the only one
-- in the project - which is why the machinery it needs is spelled out here.
--
-- WHY IT IS A ROW AT ALL. "after the main ship is defeated, you fight the main
-- admiral himself in like a dual" (user, 2026-09-09). Everything the boss
-- archetype provides - the rise, the phase table, the attack book, the HUD
-- name, the enrage - is reached through `creature.row.boss` -> `Bosses.items`,
-- one row per fight. A third phase of the ship would have had to be a planted
-- 41-stud gun platform and a running swordsman at the same time, sharing one
-- `speed`, one `turnRate`, one `hitRadius` and one attack book. Two rows cost
-- one field on the ship (`succeededBy`) and one branch in BossService.
--
-- HOW THE HANDOFF WORKS, in one place so nobody has to reconstruct it:
--   * the hull's death fires `Killed` as usual. BossService's `onKilled` sees
--     `succeededBy` on the hull's row, raises THIS row at the wreck, re-points
--     the running `fights` record at it, and returns before paying anything.
--   * the party scaling comes across intact: `raise` puts `healthMult` in the
--     spawn bag, `spawn` keeps it on the creature, and `kill` merges it into
--     the Killed info - so the handoff reads the factor the hull actually
--     spawned with rather than recounting a party that may have lost bodies.
--   * the HUD rebinds itself. It tracks the nearest model carrying `BossName`,
--     and maps `CreatureId` -> Bosses by walking `Bosses.items` on
--     `boss.creature`; this row registers itself there for free.
--   * `heartAs` below is what makes the payout say `admiral_wrack`.
--
-- HE IS THE INVERSE OF HIS OWN SHIP, deliberately and in every number: she
-- never took a step and never turned, he does nothing else; she could only be
-- hurt through her guns, he has no gate at all; she filled the screen, he
-- throws five things and each one is readable. Two acts of shooting fixed
-- brass from eighty studs, and then the fight ends in reach.
Bosses.items.wrack_duel = {
	id = "wrack_duel",
	name = "Admiral Wrack",
	shortName = "Admiral Wrack",
	creature = "wrack_admiral",
	islandId = "wreck",
	-- THE CALL CANNOT REACH HIM, and this flag says so to both readers.
	-- `bossHere` walks `Bosses.items` to find "the boss of the island you are
	-- standing on" and would otherwise be a coin flip between the ship and her
	-- captain; the `byIsland` builder at the foot of this file has the same
	-- problem with worse consequences (it feeds BossArenaService's floor).
	-- Act three is entered by killing act two, never by casting.
	summonable = false,
	-- ...but the ADMIN panel should still reach him: `AdminService` takes an
	-- explicit id rather than walking the island, so `adminStart("wrack_duel")`
	-- drops you straight into the duel from a cold start. That is most of what
	-- playtesting act three IS, and it costs nothing to leave open.
	--
	-- The gate is the ship's; nothing summons this one.
	gate = { level = 42 },
	-- WHAT THE FIGHT PAYS, AND UNDER WHOSE NAME. His death is the Careenage's
	-- win, so it must set `Cleared_wreck` (keyed by island - already right) and
	-- grant the heart the rest of the game asks for. Every recipe gate and the
	-- Kraken's own `gate.hearts` name `admiral_wrack`, and the player fought
	-- one Admiral Wrack across three acts, so the heart is his: `heartAs`
	-- overrides the id `onKilled` would otherwise build from `boss.id`.
	--
	-- Without this the win would quietly mint `Heart_wrack_duel` - an
	-- attribute nothing reads, on a save that would then never satisfy the
	-- finale's gate, with the fight looking completed the whole time.
	heartAs = "admiral_wrack",
	arena = { offset = Vector3.new(0, 0, -20), radius = 80 },
	aggro = 165,
	-- HE CLOSES. The ship's 200 put her past the whole shoal so the prowl
	-- branch never moved her; 6 is inside his own reach, so he comes to you and
	-- keeps coming. There is nowhere on this beach to be far from him.
	standoff = 6,
	hitRadius = 3.5,
	submerge = 0,
	-- HE LEAPS, HE DOES NOT RISE. `riseDepth` 0 and a short `riseTime`: the
	-- ship is wrecking as he lands, and a four-second climb out of the seabed
	-- would step on the beat that just played. It is also the abandon reaper's
	-- grace across the handoff (`startedAt` is reset with it), so it wants to
	-- be short but not zero.
	riseDepth = 0,
	riseTime = 1.6,
	speed = 22,
	turnRate = math.rad(140),
	-- TIGHTER THAN ANY OTHER BOSS'S. Five moves, each one readable, each one
	-- answerable - so the pressure has to come from how little air there is
	-- between them rather than from how many are on screen.
	attackGapMin = 0.9,
	attackGapMax = 1.6,
	enrageBelow = 0.35,
	enrageCooldownMult = 0.65,
	enrageDamageMult = 1.2,
	-- THE WRECK STILL ANSWERS HIM. `lastbroadside` is fired from the sunken
	-- ship's own gun positions, and rather than keeping the hull's resolved
	-- mounts alive across the handoff - state that would have to survive a
	-- creature's death for one rare move - they are authored here in the same
	-- boss-local convention, resolved against the arena centre. The ship is not
	-- going anywhere; her guns are where they fell.
	wreckMounts = {
		Vector3.new(16.45, 2.00, -9.50),
		Vector3.new(16.45, 2.00, 9.50),
		Vector3.new(-16.45, 2.00, -9.50),
		Vector3.new(-16.45, 2.00, 9.50),
	},
	-- Ordinary health fractions: he is one creature with one bar, so the dial
	-- the ship needed (`actFraction`) has no job here.
	--
	-- The two-class cap is trivially held - everything is (a) read-and-walk
	-- except `ripostestance`, which is (b) inverted: a clock you must NOT put
	-- damage into.
	phases = {
		-- The three he teaches you with. No stance yet: you learn to read a
		-- lane and a cone before the fight punishes you for answering one.
		{ below = 1.0, attacks = { "sabrelunge", "cleave", "flintlock" } },
		{ below = 0.66, attacks = { "sabrelunge", "cleave", "flintlock", "ripostestance" } },
		{
			below = 0.33,
			attacks = { "sabrelunge", "cleaveDouble", "flintlock", "ripostestance", "lastbroadside" },
		},
	},
	attacks = {
		-- THE THRUST. A charge with a latched bearing: he covers the lane in
		-- half a second and does not steer once committed, so the answer is to
		-- be off it before he goes - and the tell is the lane itself, drawn
		-- where he will actually travel.
		--
		-- MISSING COSTS HIM. `expose` 2.2 with `holdExpose`, so a whiffed lunge
		-- is a real window and not a beat before the next move.
		sabrelunge = {
			handler = "sabrelunge",
			tell = false,
			skin = "cannon",
			windup = 0.9,
			duration = 0.55,
			recover = 0.7,
			cooldown = 7.0,
			expose = 2.2,
			holdExpose = true,
			reach = 55,
			lane = 7,
			speed = 100,
			damage = { 62, 84 },
		},
		-- THE ARC. A 120-degree cone at sabre length, told as a wedge. Short
		-- reach, so the answer is one step back or one step behind him.
		cleave = {
			handler = "cleave",
			tell = false,
			skin = "cannon",
			windup = 0.7,
			duration = 0.5,
			recover = 0.6,
			cooldown = 5.5,
			beats = 1,
			arcDeg = 120,
			reach = 22,
			damage = { 54, 72 },
		},
		-- ...AND THE SECOND BEAT SWEEPS BACK THE OTHER WAY, so "dodge once" is
		-- not the answer any more. Phase 3's re-read of the same verb.
		cleaveDouble = {
			handler = "cleave",
			tell = false,
			skin = "cannon",
			windup = 0.65,
			duration = 1.1,
			recover = 0.7,
			cooldown = 7.5,
			beats = 2,
			beatGap = 0.45,
			arcDeg = 120,
			reach = 22,
			damage = { 50, 66 },
		},
		-- THE DUEL'S SIGNATURE, and the only move in the whole fight whose
		-- answer is to do nothing.
		--
		-- He plants and holds guard for `hold` seconds. Hit him inside that and
		-- he counters ONCE - everything within `punish` of him wears it, and the
		-- stance refreshes, so panicking into it is a loop you pay for twice.
		-- Let the window run out untouched and he over-commits: `expose` 3.0
		-- with `holdExpose`, the biggest open window in the fight, earned by
		-- putting your gun down.
		--
		-- It is readable rather than a gotcha: `ATTR.WRACK_RIPOSTE` is 1 for the
		-- whole stance and 2 for the counter (the client needs to tell "the
		-- counter landed" from "the window expired" and will not guess), and a
		-- ring tell is drawn at exactly `punish` so the radius is not a secret.
		ripostestance = {
			handler = "ripostestance",
			tell = false,
			skin = "wisp",
			windup = 0.55,
			hold = 3.5,
			duration = 3.9,
			recover = 0.8,
			cooldown = 16.0,
			expose = 3.0,
			holdExpose = true,
			punish = 12,
			counterFor = 0.45,
			damage = { 78, 104 },
		},
		-- THE PISTOL. One aimed ball, fast, no tracking - the windup is the
		-- whole dodge, and it is the fight's only ranged pressure once the ship
		-- is down.
		--
		-- ITS TELL IS A `mark` AT THE LANDING POINT, NOT A LANE, and that is a
		-- readability decision rather than a stylistic one: `sabrelunge` above
		-- already owns the lane, and two aimed moves wearing one telegraph
		-- shape cannot be told apart - by the player, or by the duel rig
		-- choosing which gesture to draw.
		flintlock = {
			handler = "flintlock",
			tell = false,
			skin = "grape",
			windup = 0.85,
			duration = 0.3,
			recover = 0.5,
			cooldown = 9.0,
			speed = 110,
			radius = 3.0,
			spawnAt = 4,
			lifetime = 1.6,
			damage = { 58, 76 },
		},
		-- THE LAST BROADSIDE. Rare, phase 3 only: he raises the sabre and the
		-- WRECK answers - one ring of cannonballs with a gap, out of the
		-- drowned ship's own gun positions (`wreckMounts` above).
		--
		-- It is the fight's closing rhyme. The first thing act one taught was
		-- "find the gap in the ring"; the last thing act three asks is the same
		-- question, from a ship that is already dead.
		lastbroadside = {
			handler = "lastbroadside",
			tell = false,
			skin = "cannon",
			windup = 1.6,
			duration = 0.8,
			recover = 1.0,
			cooldown = 34.0,
			count = 30,
			speed = 30,
			radius = 3.0,
			spawnAt = 16,
			markAt = 26,
			lifetime = 4.15,
			gapDeg = 40,
			damage = { 46, 60 },
		},
	},
}

-- ============================================================ The Maelstrom
-- The Kraken, Maw of the Maelstrom: the saga's finale, and after the 2026-09-09
-- rework it is the only fight in the project that is three fights.
--
-- IT IS NO LONGER A RING OF EIGHT ARMS AROUND A WHIRLPOOL. The party is
-- summoned at the Maelstrom and teleported to a SHIP - the Tidebreak,
-- BossArenas.maelstrom, arena_gen.py's `kraken` builders - with the animal's
-- head standing out of the sea 350 studs off the port beam. The head never
-- moves. What reaches you is two ARMS, and they are the fight:
--
--   PHASE 1, "the waist": the 90-stud midships deck between the two castles.
--     Slams, a lateral scythe at deck+3, a wrap-and-wrench channel with a
--     counter in it, and ink mortars.
--   PHASE 2, "the full ship": the forecastle and quarterdeck open, so the
--     floor is three heights instead of one and a single sweep plane stops
--     working. Faster tells, both arms at once, the main spar swinging, an
--     undertow toward the port rail and a lance out of one eye.
--   PHASE 3, "the gullet": the siphon opens and swallows the party into the
--     animal (BossArenas.maelstrom_gullet, 20,000 studs away). Six polyps
--     gate the heart; the room's own peristalsis, acid and heartbeat are what
--     you survive while you cut them.
--
-- THE PHASE MACHINE IS NOT HEALTH. See `machine` below: phases advance on
-- ARM-BREAK CYCLES - break both arms inside one cycle and the head slumps,
-- which is the only time its own health bar can be touched at all - so the
-- fight escalates because the party is winning it, not because a number
-- crossed a line. `phases` is still here and is still the attack pool per
-- phase; only the thing that CHOOSES the index changed.
--
-- Killing the heart sets Heart_kraken and the finale banner; it unlocks
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
	-- THE SHIP IS THE ARENA and `offset` is zero because BossArenas puts the
	-- hull on the arena centre exactly (`KrakenArena_Base` is the hull). The
	-- radius is the DISC THE FIGHT IS WALKED, and on a ship that is its own
	-- length: 88 covers the bow and stern posts at +/-85 with a couple of
	-- studs to spare. Three things read it - the boss's own clamp, the
	-- abandon reaper's presence test and (before `spawnPad` existed) the
	-- drop-in ring - and all three want the hull, not the waist.
	arena = { offset = Vector3.new(0, 0, 0), radius = 88 },
	-- Drawn by KrakenBodyController off Shared/Modules/KrakenPath. A posed
	-- boss holds its ground - updateBoss stops walking it at you - which is
	-- now literal rather than a concession: the head is planted 350 studs off
	-- the port rail and never takes a step for the whole fight.
	pose = "kraken",

	-- --------------------------------------------------------- the machine
	--
	-- WHY THIS IS NOT `parts` ANY MORE, and it is the load-bearing decision of
	-- the whole rework. The generic parts ring plants N bodies, gates the boss
	-- on `partsAlive > 0`, and regrows the WHOLE ring `regrow` seconds after
	-- the LAST one falls. Two of those three are exactly what this fight
	-- wants; the third is the opposite of it. Breaking ONE arm has to cost the
	-- Kraken that arm for twelve seconds while the other one keeps fighting -
	-- that pressure is the fight - and the generic clock cannot express it,
	-- because it only starts when the ring is empty.
	--
	-- So CreatureService owns the two arms directly (Fn.plantKrakenArm, and
	-- the `krakenarm` archetype which has no updater of its own). Everything
	-- the ring gave for free is kept, because the arms still carry `partOf`:
	-- `kill` counts `partsAlive` down and stamps Exposed at zero, `Fn.unaimable`
	-- still refuses the head while an arm stands (the row's `vulnerableWhen =
	-- "partsDown"`), `removeOwnedParts` still takes them with the boss, and the
	-- party's health multiplier still reaches them. There is no `parts` block
	-- here on purpose: with one, `Fn.updateBoss`'s generic regrow branch would
	-- replant both arms out from under the machine's own clock.
	machine = {
		-- The two arms, by rest position, arena-local XZ (Y is the deck they
		-- plant on and lives in CreatureService's K.KRAKEN.DECK_Y). Both rest
		-- OUTBOARD of the port rail, off the beam the head is on, because the
		-- client draws each arm as a chain from the crown to this point and an
		-- arm resting inboard would be drawn through the ship.
		--
		-- Staggered fore-and-aft to match the wrap points they reach for
		-- (BossArenas.maelstrom.wraps): arm 1 works the aft half of the waist,
		-- arm 2 the fore half, so two simultaneous attacks are two different
		-- questions instead of one asked twice.
		armRest = {
			Vector3.new(-26.0, 0, -34.0),
			Vector3.new(34.0, 0, -31.0),
		},
		-- A BROKEN ARM WITHDRAWS, IT DOES NOT DIE. Twelve seconds off the board
		-- and it comes back at full health - the parts-regrow bargain, per arm.
		-- Long enough that breaking one is real progress and the other arm has
		-- to carry the pressure alone; short enough that a party cannot simply
		-- hold one arm down and fight a one-armed Kraken forever.
		armReturn = 12.0,
		-- ...UNLESS BOTH ARE DOWN AT ONCE, which is the whole loop. With no arm
		-- standing the head slumps and the siphon opens: `Fn.unaimable` stops
		-- refusing the boss (partsAlive is 0) and its own health bar is the only
		-- thing in the arena worth shooting, for this long. A withdrawn arm's
		-- twelve seconds are HELD while the window is open, so a party that
		-- earned the window gets all of it.
		siphonWindow = 10.0,
		-- HOW MANY WINDOWS BUY THE NEXT PHASE. Two to open the castles, two more
		-- to be swallowed. Four in total is the fight's length, and it is a
		-- count rather than a health threshold so that the escalation is
		-- something the party did.
		windowsPerPhase = 2,
		-- FASTER TELLS AS IT ESCALATES, per phase index. Applied to every
		-- attack's windup at the moment it begins (Fn.beginBossAttack reads
		-- `creature.tellMult`), so it moves the telegraph and the damage
		-- together and there is no attack that has to be re-tuned by hand.
		-- Phase 3's is the mildest step because the gullet's own moves are
		-- already the tightest in the book.
		tellMult = { 1.0, 0.82, 0.78 },
		-- PHASE THREE'S SIX POLYPS, planted on the gullet's authored socket
		-- collars (BossArenas.maelstrom_gullet.sockets - the coordinates are
		-- there, not here, because the mesh owns them). The heart is unaimable
		-- while any of them stands.
		polyps = 6,
		-- ...and how far the heartbeat's metronome tightens per polyp broken:
		-- the ring wave's interval is multiplied by this once for each one
		-- down, so six deaths take it to 0.86^6 = 0.40 of its opening pace.
		-- The room gets louder as it gets shorter, which is the only reward
		-- structure a boss with no punish window can offer.
		polypStep = 0.86,
	},
	-- THE HEAD REACHES THE WHOLE SHIP, and then some: it stands 350 studs off
	-- the port beam and the far rail is another 20 past that, so an aggro that
	-- did not cover 400 would have the boss politely stop attacking whenever
	-- the party crossed to starboard. In the gullet it is nonsense in the other
	-- direction (the room is 236 across and the "boss" is the heart in the
	-- middle of it), which is harmless - it is a floor on engagement, not a
	-- leash.
	aggro = 420,
	-- Never used: the head is `pose`d, so `Fn.updateBoss` takes the branch that
	-- never walks it. Kept because the type requires it and a nonsense value
	-- here would read as a claim about a fight that does not have one.
	standoff = 18,
	-- THE HIDE IS THE SIZE OF THE ANIMAL, and 20 (x1.4 = a 28-stud capture
	-- sphere) was the whirlpool Kraken's dome. This one is the pack's mantle at
	-- its authored SCALE 6.0: 480 studs tall on a 564-stud beam, standing 350
	-- studs off the port rail. 200 x the body scale is 280, the mantle's own
	-- half-width - which puts its nearest FACE about 70 studs off the rail and
	-- therefore inside a weapon's reach during the siphon window. A 28-stud
	-- sphere 350 studs away would have made the fight's only damage window
	-- unusable, and nothing anywhere would have said so: the shots would simply
	-- have missed a head the size of a cathedral.
	--
	-- Phase three shrinks it back to 30 in code (Fn.krakenSwallow): the heart is
	-- a 34-stud mass in a 236-stud room, and a 280-stud sphere in there would BE
	-- the room - every shot aimed at a polyp would land on the heart instead.
	hitRadius = 200,
	submerge = 3.0,
	riseDepth = 26,
	riseTime = 5.0,
	speed = 6,
	turnRate = math.rad(60),
	-- TIGHTER THAN ANY OTHER BOSS'S, because this one's damage is gated on
	-- telegraphs a player is reading rather than on a rotation they are waiting
	-- out: a long gap on a stationary head is just dead air on a ship.
	attackGapMin = 0.5,
	attackGapMax = 1.0,
	enrageBelow = 0.25,
	enrageCooldownMult = 0.5,
	enrageDamageMult = 1.4,
	-- THE THREE POOLS, one per machine phase - and the `below` column is NOT
	-- what selects between them any more.
	--
	-- `Fn.pickBossAttack` reads `creature.krakenPhase` (the machine, above) and
	-- takes the list at that index directly. These thresholds are the FALLBACK
	-- that runs if that state is ever missing, and they are written so the
	-- fallback is phase one: a living boss's health fraction is greater than
	-- zero, so only the first row's `below = 1.0` can ever match and
	-- `Fn.bossPhaseAttacks` returns the waist's four moves. That is the right
	-- thing to degrade to - a fight that quietly plays its opening pool is
	-- survivable and obviously wrong, where one that quietly plays the gullet's
	-- pool on a ship would fire attacks at geometry 20,000 studs away.
	--
	-- ENTRY [1] IS THE FALLBACK WITHIN A POOL, the project-wide rule:
	-- `pickBossAttack` returns `attacks[1]` when everything else is still
	-- cooling, so each list leads with the move that can always land - a slam
	-- in the waist, a slam in the full ship, and the heartbeat in the gullet,
	-- which is the one move there that needs nothing but the room.
	--
	-- SIX MOVES IN THE WAIST AND THIRTEEN ON THE FULL SHIP (the new-attacks pass,
	-- 2026-09-12 - the owner's ask was "more unique attacks and more openings to hit
	-- the boss"). What the two new phase-one moves buy, stated as what was wrong
	-- before them: the opening pool was four moves of which exactly ONE (the wrench)
	-- had a window you could choose to play for, and one (the slam) had a window it
	-- handed you whether you wanted it or not. `gratingspear` adds a punish that is
	-- BUILT IN - the limb is stuck in the deck for four seconds every single cast, no
	-- counter needed - and `suckervolley` adds one handed over in exchange for the
	-- deck it just took away from you. So phase one now has four windows per rotation
	-- instead of two, which is the difference between a fight you survive and one you
	-- beat.
	--
	-- THE COOLDOWNS ARE WHAT KEEP IT FROM BEING NOISE. `Fn.pickBossAttack` rolls
	-- among whatever is off cooldown, so adding two moves to a four-move pool would
	-- otherwise halve the time between windows and the fight would become one long
	-- punish phase. The two new phase-one rows are priced at 13.0 and 12.0 - the long
	-- end of the pool, above the slam's 8.0 and the mortar's 9.5 - so the openings
	-- arrive about as often as the wrench's did and the bread-and-butter moves still
	-- carry the rotation. Phase two's two additions are 18.0 and 30.0, the two
	-- longest cooldowns in the fight: both are set pieces and a set piece that comes
	-- round twice a minute is a rotation step.
	phases = {
		{
			below = 1.0,
			attacks = { "pileslam", "deckscythe", "wrapwrench", "inkmortar", "gratingspear", "suckervolley" },
		},
		{
			below = 0.0,
			attacks = {
				"pileslam",
				"deckscythe",
				"wrapwrench",
				"inkmortar",
				"gratingspear",
				"suckervolley",
				"crossscythe",
				"mastbell",
				"undertowheave",
				"eyelance",
				"inkdeluge",
				"maelstromcoil",
				"siphonovercharge",
			},
		},
		{ below = 0.0, attacks = { "heartbeat", "peristalsis", "acidtide", "antibodies" } },
	},
	attacks = {
		-- EVERY MOVE IN THIS BOOK OBEYS THREE RULES, and they are worth stating
		-- once rather than fourteen times:
		--
		--   1. THE TELL LASTS EXACTLY AS LONG AS THE BLOW TAKES TO ARRIVE.
		--      `windup` IS the time-to-impact; nothing here fires damage on a
		--      clock the telegraph does not draw.
		--   2. THE TELL IS DRAWN AT THE IMPACT SITE, never at the boss. The
		--      head is 350 studs off the port beam and 480 studs tall - a
		--      warning flashed at its pivot points at the horizon. Every row
		--      here carries `tell = false` and its handler draws its own.
		--   3. EVERY MOVE FIRES A CLIENT EVENT. The server owns the damage and
		--      the geometry; KrakenBodyController owns what it looks like, and
		--      the two are joined by the named events in the replication
		--      contract at the top of CreatureService's kraken section.
		--   4. THE TELL IS LONG AND THE BLOW IS NOT (owner, 2026-09-12). Every
		--      `windup` below was roughly doubled and NO `duration` moved: the
		--      complaint was never that the fight hits too hard, it was that a
		--      limb 1200 studs long arrived before anyone could see it leave the
		--      water. `windup` IS the arm's own ArmPhase span - every handler
		--      passes `a.windup` straight into `arm.phaseFor` before calling
		--      Fn.krakenArmPhase (krakenpileslam :16895, krakenscythe /
		--      krakencross through Fn.krakenArmSweep, krakenwrench :17082) - so
		--      lengthening it here lengthens the DRAWN Rear and SweepCock by the
		--      same seconds, and KrakenPath's windup poses now HAUL over that
		--      span instead of snapping to their apex and waiting out the clock.
		--      No server constant needed changing for it.
		--
		--      The cost is accepted and stated rather than discovered: the
		--      fight's damage per minute falls by about a sixth. `attackGapMin /
		--      Max` were left alone, so what comes back is a tighter rotation
		--      rather than a telegraph nobody can read.
		--
		-- ---------------------------------------------------------- phase one
		--
		-- PILE SLAM: one arm rears clear of the rail and comes down on the
		-- deck. The bread-and-butter, and `attacks[1]` for both ship phases -
		-- the move that always has somewhere to land.
		--
		-- r14 impact inside an r22 telegraph, from the arena's own HANDOFF: the
		-- waist is 90 x 40 and a disc of 12-16 on the centreline owns its width
		-- without owning either cover stack, while 22 owns the room. Drawing
		-- the bigger one and hitting the smaller is deliberate - the arm is
		-- enormous and the read should be "get out of the middle", not "stand
		-- one stud outside a painted line".
		--
		-- `down` is the punish: the arm lies on the planking for three seconds
		-- with its knuckle glowing, which is the only time in phase one you can
		-- hit it for triple.
		pileslam = {
			tell = false, -- the DISC is the telegraph; see rule 2
			handler = "krakenpileslam",
			skin = "ink",
			windup = 2.4,
			duration = 0.45,
			recover = 0.7,
			cooldown = 8.0,
			radius = 14,
			tellRadius = 22,
			down = 3.0,
			damage = { 72, 96 },
		},
		-- DECK SCYTHE: the arm lays itself flat and sweeps the length of one
		-- deck at KNEE-TO-CHEST height. The measured numbers, off the build:
		-- the sweep's underside is deck+3.0, the bulwark tops out at deck+2.8
		-- (it clears by 0.2 - "the rail never saves you"), the tallest cargo
		-- stack at deck+2.7 (clears by 0.3), a crouched head is deck+2.6 and a
		-- STANDING head is deck+5.0, which is two studs INTO it.
		--
		-- So the answer is cover, and only cover. `lane` is the half-width of
		-- the swept strip; 20 covers the waist's 35.2 studs of clear planking
		-- with the strip centred, so there is no lane down the middle to stand
		-- in - the four cargo footprints are the whole of the counterplay.
		--
		-- ...AND IT NOW DRAGS TO A STOP (the new-attacks pass, 2026-09-12). `drape` is
		-- the seconds the arm lies spent over the NEAR bulwark with its knuckle lit at
		-- the end of the swing, instead of snapping straight back to Rest.
		--
		-- THE CHEAPEST OPENING IN THE BOOK and the best ratio of reward to new code in
		-- this pass: the scythe was already the move players read best (a strip of
		-- burning deck and a limb visibly drawing back along it), it fires every ten
		-- seconds, and until now the correct answer to it was to stand behind a crate and
		-- do nothing at all. 1.5s is deliberately the shortest window of the six - long
		-- enough for one burst from the cover you were already in, not long enough to
		-- become the fight's main damage source.
		deckscythe = {
			tell = false, -- the LANE is the telegraph (event "sweepLane")
			handler = "krakenscythe",
			skin = "ink",
			windup = 2.6,
			duration = 0.85,
			recover = 0.7,
			cooldown = 10.0,
			lane = 20,
			drape = 1.5,
			damage = { 80, 108 },
		},
		-- WRAP WRENCH: the arm takes hold of one of the four boarding gaps cut
		-- in the bulwark (BossArenas.maelstrom.wraps) and HAULS for four
		-- seconds. This is the set-piece of phase one and the only move in the
		-- book with a designed counter.
		--
		-- SUBSTITUTION A, owner-approved 2026-09-09: THE DECK DOES NOT TILT.
		-- Physically rolling the arena would mean moving the floor every player
		-- is standing on, every hitbox measured off it, and an authored mesh
		-- whose collision is decomposed per object - for a four-second effect.
		-- So the LIST is a client event ("shipList": camera roll, debris,
		-- rigging strain) and what the server ships is the CONSEQUENCE: loose
		-- cargo breaking free and sliding across the deck from the hauling side
		-- to the other. Anchored parts stepped by the fight tick, damage on a
		-- touch radius, and the four cover footprints stop them - so the same
		-- crates that answer the scythe answer this, which is what makes the
		-- deck's furniture legible instead of arbitrary.
		--
		-- THE COUNTER: the arm's knuckle is hot for the whole channel and
		-- `breakDamage` into it cancels the haul outright and leaves the arm
		-- Exposed for `expose` seconds. That is a real choice under pressure -
		-- turn and burn the arm while barrels cross the deck, or take the
		-- channel and keep your footing.
		wrapwrench = {
			tell = false, -- the WRAP MARK is the telegraph
			handler = "krakenwrench",
			skin = "ink",
			windup = 2.2,
			duration = 4.0,
			recover = 0.9,
			cooldown = 19.0,
			barrels = 4,
			barrelSpeed = 26,
			barrelRadius = 6,
			-- Damage on a rolling half-ton of cask, not on a tentacle: lower
			-- than a slam and it can hit you more than once if you stand still.
			damage = { 46, 62 },
			-- 2,200 of an arm's 9,000: a quarter of the bar inside four
			-- seconds, which two players focusing can do and one cannot.
			breakDamage = 2200,
			expose = 6.0,
			holdExpose = true,
		},
		-- INK MORTAR: the siphon flares and lobs four globs onto marked ground,
		-- each leaving a slick. The one move that is about the FLOOR rather
		-- than about the arms - it takes deck away and keeps taking it, so a
		-- party that never moves loses the room it needs for everything else.
		--
		-- Uses the existing glob tech end to end (Fn.throwGlob's flight clock
		-- plus K.BOSS_HEIGHT_TOLERANCE, and the pool tech for the slick), which
		-- is why it is the shortest row in phase one.
		inkmortar = {
			tell = false, -- the four DISCS are the telegraph
			handler = "krakenmortar",
			skin = "ink",
			windup = 2.0,
			duration = 2.4,
			recover = 0.7,
			cooldown = 9.5,
			count = 4,
			spread = 26,
			flight = 1.4,
			stagger = 0.25,
			radius = 9,
			damage = { 52, 70 },
			pool = { radius = 11, duration = 9.0, slow = 0.55, skin = "ink" },
		},
		-- GRATING SPEAR: the tip rises out of the sea, jabs three marked points walking
		-- down the deck toward you, and drives itself THROUGH THE PLANKING on the third -
		-- where it is stuck, and glowing, for four seconds.
		--
		-- THE OPENING IS NOT A COUNTER, IT IS THE MOVE'S OWN ENDING, and that is what
		-- this row is for. Every other punish in phase one has a price: the wrench's has
		-- to be bought with 2,200 damage under pressure, and the slam's only happens
		-- because the arm has to be on the deck for the blow to land at all. This one is
		-- UNCONDITIONAL - dodge it, eat it, ignore it, the limb is still stuck in your
		-- deck for four seconds at 3x - so it is the move that TEACHES the fight. A party
		-- that has never worked out that the arms are the damage race learns it here, and
		-- four seconds is long enough to learn in.
		--
		-- r7 INSIDE AN r11 TELL, the tightest pair in the book, because the counterplay is
		-- a side-step rather than a run: three marks 17 studs apart walking toward you is
		-- one sideways pace per 0.7 seconds, which you can always make and can always be
		-- caught failing to make. The damage is phase one's heaviest per hit (84-108
		-- against the slam's 72-96) on the smallest radius that carries it, which is the
		-- exchange rate the whole fight is written on.
		gratingspear = {
			tell = false, -- the THREE DISCS are the telegraph
			handler = "krakenspear",
			skin = "ink",
			windup = 2.2,
			-- Three stabs `stabStep` apart plus the last one's own travel: the strike
			-- phase has to outlast the rhythm, or the third jab would land in `recover`.
			duration = 2.1,
			recover = 0.8,
			cooldown = 13.0,
			stabs = 3,
			stabStep = 0.7,
			-- How far apart the three marks sit along the deck. One sideways pace at
			-- walking speed per step, measured against the waist's 90 studs of clear
			-- planking: three marks span 34, so the sequence reads as a line coming at
			-- you rather than as three unrelated discs.
			stabMarch = 17,
			radius = 7,
			tellRadius = 11,
			-- THE WINDOW. Four seconds at the 3x knuckle multiplier - the wrench's
			-- `expose` (6.0) scaled down for a move that costs nothing to earn and comes
			-- round half again as often.
			stuck = 4.0,
			damage = { 84, 108 },
		},
		-- SUCKER VOLLEY: the arm rears right back out of the water - the biggest
		-- silhouette in phase one - and whips over, throwing six suckers onto marked
		-- ground. Then it hangs over the bulwark, spent.
		--
		-- IT IS THE MORTAR'S TWIN AND THAT IS THE POINT. `inkmortar` takes deck away from
		-- above, at range, from a head that can never be punished for it - the owner rule
		-- is that the head does not physically attack, and a ranged head is never
		-- vulnerable for it. This one takes the same deck away with an ARM, which means
		-- the fight has to hand something back, and what it hands back is two and a half
		-- seconds of forearm lying on the rail you are standing at. So the two moves ask
		-- the same question and have opposite answers: run from one, turn and shoot the
		-- other.
		--
		-- SIX SMALL MARKS RATHER THAN FOUR BIG ONES (r8 against the mortar's r9, 30 studs
		-- of spread against 26, and no slick left behind). A volley is a FAN you step out
		-- of the middle of; a mortar is four holes punched in the floor that stay
		-- punched. No pool, because the arm is already paying for the move by being
		-- caught out in the open at the end of it.
		suckervolley = {
			tell = false, -- the SIX DISCS are the telegraph
			handler = "krakenvolley",
			skin = "ink",
			windup = 2.4,
			duration = 1.6,
			recover = 0.8,
			cooldown = 12.0,
			count = 6,
			spread = 30,
			flight = 1.1,
			stagger = 0.14,
			radius = 8,
			-- THE WINDOW, shorter than the spear's because it is a WIDER one: a forearm
			-- draped on the bulwark is a bigger, closer target than a tip buried in the
			-- planking, and both are worth 3x.
			drape = 2.5,
			damage = { 58, 76 },
		},
		-- ---------------------------------------------------------- phase two
		--
		-- The castles open, so the floor is THREE heights instead of one and
		-- every move below is written against that fact. A single world-height
		-- sweep does not work any more: it would be head-high in the waist and
		-- knee-high nowhere (arena_gen's own warning). The five moves here are
		-- the five different ways to ask "where on this ship are you".

		-- CROSS SCYTHE: both arms sweep at once, on DIFFERENT decks. The reason
		-- it is a phase-two move and not a harder deckscythe: with one deck
		-- there is nowhere for the second lane to be, and the whole read is
		-- "which of the three floors is safe this time".
		crossscythe = {
			tell = false, -- two LANES; two "sweepLane" events
			handler = "krakencross",
			skin = "ink",
			windup = 2.6,
			duration = 1.0,
			recover = 0.8,
			cooldown = 15.0,
			lane = 18,
			damage = { 76, 102 },
		},
		-- MAST BELL: the main spar tears loose and swings across the waist for
		-- six seconds while the rigging comes down in pieces.
		--
		-- ONE PART, STEPPED. The spar is an anchored part the fight tick
		-- CFrames along an arc and hurts on a touch radius each pass - the
		-- powder keg's and the figurehead's precedent, and the same bargain:
		-- the server owns where it is and the client draws it, so the hitbox
		-- and the picture cannot part company. `strikes` are the falling
		-- debris, ordinary queued marks, because rubble does not need to be
		-- simulated to be dodged.
		mastbell = {
			tell = false, -- the SPAR is the telegraph (event "mastBell")
			handler = "krakenmastbell",
			skin = "wreck",
			windup = 2.2,
			duration = 6.0,
			recover = 0.9,
			cooldown = 23.0,
			passes = 3,
			sparRadius = 7,
			strikes = 3,
			radius = 9,
			damage = { 62, 84 },
			debrisDamage = { 50, 68 },
		},
		-- UNDERTOW HEAVE: the sea itself heels toward the animal and everyone
		-- on deck slides with it, and then the arm comes down where they all
		-- ended up.
		--
		-- SUBSTITUTION B, owner-approved 2026-09-09: THE SHIP DOES NOT MOVE.
		-- Same reasoning as substitution A - the floor is authored geometry and
		-- moving it moves every measurement in the fight - so the drag is the
		-- EXISTING pull tech (the client leashes its own character, the
		-- undertow handler's channel) aimed at the port rail instead of at a
		-- whirlpool's centre. Braced players - inside a cover footprint - are
		-- exempt, which is the third job the deck cargo does.
		--
		-- THE FOLLOW-UP IS THE POINT. Five seconds of drag with nothing at the
		-- end of it is an inconvenience; a slam telegraphed on the port rail
		-- zone the moment the pull stops is a trap you have to have been
		-- walking out of the whole time.
		undertowheave = {
			tell = false, -- the PULL and then the DISC
			handler = "krakenheave",
			skin = "storm",
			windup = 2.0,
			duration = 5.0,
			recover = 0.9,
			cooldown = 21.0,
			strength = 22,
			-- The whole ship and then some: nobody is out of the current, the
			-- question is only what you are holding on to.
			radius = 120,
			-- The follow-up, which lands during `recover` on its own queued
			-- clock: a slam at the port rail, telegraphed for `slamTell`.
			slamTell = 1.8,
			slamRadius = 18,
			slamDamage = { 84, 112 },
			damage = { 30, 42 },
		},
		-- EYE LANCE: it picks one player, locks an eye on them for better than two
		-- and a half full
		-- seconds, and drives the arm's tip through where they will be.
		--
		-- THE ONLY SINGLE-TARGET MOVE IN THE BOOK, and the only one with a
		-- LINE OF SIGHT test: at the moment it fires, a ray goes from the eye
		-- to the player, and ship geometry in the way makes it a whiff (event
		-- "eyeLanceBlocked"). So the counterplay is not dodging - it is
		-- breaking the animal's view, which on a ship means putting the mast,
		-- a castle bulkhead or the cargo between you and 350 studs of open
		-- water. Two seconds was exactly enough to reach one; at 2.6 there is a
		-- little room to choose WHICH piece of the ship to put in the way, which is
		-- the version of this move that teaches the deck rather than testing a
		-- sprint.
		--
		-- `lead` is the small forward prediction that stops "stand still and
		-- take it, then walk away" from being strictly better than moving: it
		-- aims 0.35s ahead of the target's velocity at fire time. r6 is tight
		-- and the damage is the heaviest single hit the fight has.
		--
		-- ...AND THE EYE STAYS LIT AFTER IT FIRES (the new-attacks pass, 2026-09-12).
		-- `glint` is the seconds the orb holds its flare once the lance is away, and the
		-- HEAD takes 1.5x for exactly that window.
		--
		-- THIS IS THE ONLY OPENING ON THE ANIMAL ITSELF THAT IS NOT THE SIPHON WINDOW,
		-- and it exists because of a gap the owner rule opens: the head never physically
		-- attacks, so every head move is ranged, so until now NOTHING the head did could
		-- ever be punished - the only way to hurt it was to break both arms inside one
		-- cycle. A fight whose boss is untouchable except through a ten-second window
		-- every couple of minutes is a fight about the arms with a health bar attached.
		--
		-- 1.5x AND NOT 2x, deliberately. 2x is what `exposedUntil` means everywhere else
		-- in the game - a creature that has been made to over-commit and is standing
		-- there helpless - and an eye that has just shot someone has not over-committed.
		-- 2.5 seconds is also short enough that the window COMPETES with the arms for
		-- your attention rather than replacing them, which is the choice it is for.
		eyelance = {
			tell = false, -- the LOCK is the telegraph (event "eyeLock")
			handler = "krakeneyelance",
			skin = "storm",
			windup = 2.6,
			duration = 0.6,
			recover = 0.7,
			cooldown = 12.0,
			lead = 0.35,
			radius = 6,
			glint = 2.5,
			damage = { 118, 156 },
		},
		-- INK DELUGE: a long charge in the siphon, then a wall of ink crossing
		-- the MAIN DECK from one end to the other, leaving slicks behind it.
		--
		-- THE CASTLES ARE SAFE, and that is the move: it is the one attack in
		-- the fight that can be answered by climbing a staircase, so it is what
		-- teaches the party that phase two's three floors are a resource rather
		-- than more places to be hit. The long windup is the price - a party
		-- that runs for the quarterdeck is off the waist for four seconds.
		inkdeluge = {
			tell = false, -- the WALL is the telegraph
			handler = "krakendeluge",
			skin = "ink",
			windup = 3.2,
			duration = 2.8,
			recover = 1.0,
			cooldown = 26.0,
			ranks = 5,
			rankSpacing = 20,
			interval = 0.42,
			arm = 0.9,
			radius = 9,
			damage = { 70, 94 },
			pool = { radius = 10, duration = 7.0, slow = 0.6, skin = "ink" },
		},
		-- MAELSTROM COIL: the arm goes under completely and CIRCLES, tracking whoever it
		-- has picked, for three seconds - nothing on the surface but a churning wake and a
		-- moving glow - and then comes up through the water underneath them as a column.
		--
		-- IT IS THE ONLY BAIT IN THE FIGHT. Every other move in the book telegraphs a
		-- PLACE and asks you to leave it; this one telegraphs YOU and follows, so leaving
		-- is not an answer and the question becomes "when". The answer is the last half
		-- second: the mark stops tracking the instant the eruption commits, and a step
		-- taken then is a step out of it.
		--
		-- AND THE PUNISH IS THE WHIFF, which is what makes the bait a real choice rather
		-- than a damage tax. A column that comes up through nobody has nothing holding it
		-- up: the limb flops across the deck Exposed for three seconds with its knuckle
		-- lit. So a party that reads the move gets paid for reading it, and a party that
		-- eats it at least does not ALSO hand the boss a free window. Nothing else in this
		-- fight rewards a successful dodge with damage.
		--
		-- PHASE TWO ONLY, and not because it is harder - because in the waist there is
		-- nowhere for a tracked player to GO. The castles are what make three seconds of
		-- being followed a decision instead of a countdown.
		maelstromcoil = {
			tell = false, -- the WAKE is the telegraph (the arm's own deck mark, on the sea)
			handler = "krakencoil",
			skin = "storm",
			-- The track. Longer than any other windup in the book because it is not a
			-- wind-up at all - three seconds of being followed IS the move.
			windup = 3.0,
			duration = 0.6,
			recover = 0.8,
			cooldown = 18.0,
			-- How often the tracked station is re-published. NOT every frame: it is two
			-- replicated attributes on a limb 1200 studs long, so a sixth of a second is
			-- already smoother than the client's own ease and an eighth of the traffic.
			trackStep = 0.15,
			radius = 18,
			flop = 3.0,
			damage = { 96, 126 },
		},
		-- SIPHON OVERCHARGE: five seconds of the siphon gaping and its core winding up to
		-- something far bigger than a deluge - DURING WHICH THE HEAD TAKES DOUBLE - and if
		-- the party puts `breakDamage` into it in that time the whole thing MISFIRES and
		-- both arms crash to the deck.
		--
		-- THE BIGGEST RISK AND THE BIGGEST REWARD IN THE FIGHT, and the row is written so
		-- that all three lines through it are real:
		--   * take the trade and win it: five seconds of 2x on a colossus, and then a
		--     DOUBLE 3x knuckle window - two arms at once - for four more. That is the
		--     largest damage window the fight has, including the siphon window itself.
		--   * take the trade and lose it: a deluge at half again the normal coverage,
		--     seven ranks at r11 against the ordinary five at r9, landing on a party that
		--     spent five seconds standing still in the waist shooting instead of climbing.
		--   * do not take it at all: the deluge lands, you are on the quarterdeck, and
		--     nothing happened. That is a legitimate line and it should feel like one.
		--
		-- 3,600 IS THE NUMBER THE WHOLE ROW TURNS ON. The wrench asks 2,200 of ONE
		-- 9,000-point arm in four seconds; this asks 3,600 of the HEAD in five, at 2x, so
		-- it is 1,800 of real damage - comfortably less per second than the wrench, and
		-- deliberately so, because the head is a 280-stud sphere nobody has to aim at and
		-- the whole party can fire into it at once. What is hard here is not the number,
		-- it is standing in the waist for five seconds to put it in.
		siphonovercharge = {
			tell = false, -- the SIPHON itself is the telegraph
			handler = "krakenovercharge",
			skin = "ink",
			windup = 5.0,
			duration = 2.8,
			recover = 1.0,
			cooldown = 30.0,
			breakDamage = 3600,
			-- The misfire's reward: both arms Down, hot, for this long.
			down = 4.0,
			-- ...and the deluge it fires if nobody stops it. Every field below is
			-- `inkdeluge`'s own name at half again its value, because the handler REUSES
			-- that move's fire path verbatim off this row - one wall of ink, two sets of
			-- numbers, and no second implementation to keep in step.
			ranks = 7,
			rankSpacing = 20,
			interval = 0.36,
			arm = 0.9,
			radius = 11,
			damage = { 70, 94 },
			pool = { radius = 12, duration = 7.0, slow = 0.6, skin = "ink" },
		},

		-- -------------------------------------------------------- phase three
		--
		-- INSIDE THE ANIMAL. There are no arms here and no punish window: the
		-- heart is unaimable until all six polyps are cut, and everything below
		-- is what the room does to you while you cut them. The floor is a
		-- shallow dish 236 studs across with a dais in the middle and the heart
		-- slung over it on four vessels.

		-- HEARTBEAT: a ring expanding out of the heart on a metronome. The
		-- fight's clock, `attacks[1]` of this pool, and the one move that never
		-- needs anything to be true - which is why it is the fallback.
		--
		-- JUMPABLE, on the same terms every ring wave in this project is: the
		-- band is thin and it resolves as an annulus, so crossing it before it
		-- detonates is the answer and standing in it is not. The metronome
		-- TIGHTENS with every polyp broken (machine.polypStep), so the room
		-- audibly speeds up as the party wins.
		heartbeat = {
			tell = false, -- the RING is the telegraph
			handler = "krakenheartbeat",
			skin = "ink",
			windup = 1.5,
			duration = 3.8,
			recover = 0.5,
			cooldown = 7.0,
			rings = { 22, 46, 70, 94 },
			ringWidth = 7,
			interval = 0.62,
			arm = 0.85,
			damage = { 58, 78 },
		},
		-- PERISTALSIS: the gut contracts - one annulus travelling outward from
		-- the dais with a GAP cut in it, and the gap is the only safe ground.
		-- Different question from the heartbeat: that one asks when, this one
		-- asks where, and the two overlap on purpose once the polyps start
		-- falling.
		peristalsis = {
			tell = false,
			handler = "krakenperistalsis",
			skin = "ink",
			windup = 1.8,
			duration = 4.2,
			recover = 0.6,
			cooldown = 12.0,
			rings = { 26, 50, 74, 98 },
			ringWidth = 9,
			-- The safe gap, in radians of arc. 70 degrees at r50 is 61 studs of
			-- opening - a run, not a pixel - and the handler rolls its bearing
			-- per cast so it cannot be pre-walked.
			gap = math.rad(70),
			interval = 0.72,
			arm = 0.9,
			damage = { 64, 86 },
		},
		-- ACID TIDE: a flood wall crossing the whole room at floor level. The
		-- dais (2.2 up) and the rib arches' feet are ABOVE it, so this is the
		-- gullet's version of the deluge - the answer is height, and the room
		-- authors exactly two places that have any.
		acidtide = {
			tell = false,
			handler = "krakenacidtide",
			skin = "ink",
			windup = 2.3,
			duration = 3.0,
			recover = 0.8,
			cooldown = 17.0,
			ranks = 6,
			rankSpacing = 34,
			width = 250,
			interval = 0.36,
			arm = 0.85,
			radius = 12,
			-- Anything standing more than this far over the room's floor datum
			-- is over the flood. The dais top is 2.2 and the entry pad 1.1, so
			-- the dais is safe and the pad is not - the finale's high ground is
			-- the middle of the room, which is where the fight wants you.
			safeHeight = 1.8,
			damage = { 66, 88 },
			pool = { radius = 12, duration = 6.0, slow = 0.6, skin = "ink" },
		},
		-- ANTIBODIES: three to five chasers come out of the gut strands. The
		-- only ADDS in the fight, and they exist because every other move here
		-- is a floor pattern - without something that follows you, "keep
		-- moving" would be free.
		antibodies = {
			tell = false,
			handler = "krakenantibodies",
			skin = "ink",
			windup = 1.5,
			duration = 1.2,
			recover = 0.7,
			cooldown = 28.0,
			row = "kraken_antibody",
			countMin = 3,
			countMax = 5,
			-- Where they come from: the gut strands hang round the room's wall,
			-- so they arrive from the edge and converge, rather than appearing
			-- on top of anybody.
			spawnR = 96,
		},
	},
}

-- islandId -> boss, so the travel gate and BossService can look up "the
-- boss of this island" directly.
-- ...AND IT IS ONE ENTRY PER ISLAND, which stopped being safe the moment a
-- second row named an island a first row already named. `wrack_duel` is the
-- Careenage's act three and carries `islandId = "wreck"` exactly as
-- `admiral_wrack` does, so without this guard `byIsland.wreck` would be
-- decided by Lua's table iteration order - re-rolled on every server start.
--
-- That is not a cosmetic coin flip. `BossArenaService.init` reads
-- `Bosses.byIsland[islandId]` for `boss.arena.radius` and `boss.pose`, and
-- THAT IS WHAT BUILDS THE CAREENAGE'S FLOOR - the roam disc, the walkable
-- radius, the arena's shape. AdminController reads it too. Both rows are
-- authored at radius 80 today, which makes the hazard worse rather than
-- better: it would stay invisible until the two rows diverged, and then
-- surface intermittently on a fresh server with nothing in the diff to blame.
--
-- `summonable == false` already means "not this island's boss, a successor to
-- one" - it is the same flag `bossHere` skips on in BossService. One flag,
-- both consumers, no second concept.
Bosses.byIsland = {} :: { [string]: Boss }
for _, boss in Bosses.items do
	if boss.summonable ~= false then
		Bosses.byIsland[boss.islandId] = boss
	end
end

return Bosses
