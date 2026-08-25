--!nonstrict
-- Tuning.luau
-- Every balance constant in the game. One file so tuning passes are a single
-- diff and nothing hides a magic number inside a service.
--
-- Starts with just the two sections the reel minigame needs (per the plan's
-- Slice 3 scope); more sections land with the slices that need them, same as
-- World.luau growing its dock constants ahead of the dock itself.

local Tuning = {}

-- ============================================================ Fishing / reeling

Tuning.Reel = {
	-- Server rejects a click claiming a bar time further than this from what the
	-- server itself measured. Generous enough for high-ping mobile, tight enough
	-- that time-warping the client clock does not pay.
	CLICK_TIME_TOLERANCE = 0.45,

	-- A cast auto-resolves if the player never finishes reeling.
	MAX_REEL_DURATION = 30,

	-- Points awarded per click by the zone hit. Grade derives from the total, so
	-- these are the highest-leverage numbers in the fishing loop.
	POINTS_GREY = 0,
	POINTS_GREEN = 1,
	POINTS_RED = 3,

	-- Fraction of the maximum achievable score needed for each grade.
	HOOKED_THRESHOLD = 0.85, -- surfaces stunned; free burst window (Slice 5+)
	ENRAGED_THRESHOLD = 0.20, -- below this it surfaces angry

	-- Each score point multiplies the rarity roll by (1 + this). Unused until
	-- Slice 4 spawns anything off it - kept here so ReelMath.luckFor has a real
	-- number to return today.
	LUCK_PER_POINT = 0.18,

	-- A missed click shrinks every remaining zone by this factor. Pressure without
	-- a fail state: the cast still lands a fish, just a worse one.
	MISS_ZONE_SHRINK = 0.82,

	-- Minimum on-screen zone width as a fraction of the bar, so touch targets stay
	-- tappable no matter how much shrink has accumulated.
	MIN_ZONE_WIDTH = 0.035,
}

-- ============================================================ Casting

Tuning.Cast = {
	-- How far from the character the bobber can land, BASE reach. The player
	-- aims along the camera and the cast goes where that ray meets open
	-- water/lava (see CastAim); further out than this is "get closer". A rod's
	-- castRange perk and the island's castRangeMult multiply this (no island
	-- currently overrides it; the knob stays for future islands).
	MAX_DISTANCE = 80,

	-- The client reports where it aimed; the server accepts the claim only if
	-- it's within MAX_DISTANCE + this of the character, to absorb the two
	-- sides measuring from slightly different character positions.
	CLAIM_SLACK = 8,
}

-- ============================================================ Rarity

Tuning.Rarity = {
	-- Relative weight of each tier before luck. Luck (rod stat x reel score,
	-- see ReelMath.luckFor) multiplies every tier above Common, so a better
	-- reel or rod shifts the odds upward without ever making Common
	-- impossible. Tiers with no creature rows are skipped at roll time.
	WEIGHTS = {
		Common = 70,
		Uncommon = 30,
		Rare = 8,
		Epic = 2,
		-- Armed 2026-08-25 (revamp): every island now carries one Legendary
		-- chase creature, so the tier finally rolls. Rare enough that landing
		-- one is an event; high-luck rods and minRarity perks push it up.
		Legendary = 0.4,
	},
}

-- ============================================================ Creatures

Tuning.Creature = {
	-- How long a surfaced creature is left ALONE before it wanders off. The
	-- timer resets on every hit (CreatureService.damage), so a creature never
	-- despawns mid-fight - only after this many seconds of the player not
	-- attacking it (user, 2026-08-22).
	LINGER = 30,

	-- Clearance between a resting creature's underside and whatever it's
	-- lying on (water, sand, dock). Its own half-thickness is added on top.
	SURFACE_OFFSET = 0.04,

	-- The throw: a landed catch is flung from the bobber at the player by
	-- the physics engine so the whole arc is visible.
	THROW_START_HEIGHT = 0.6, -- studs above the water it pops out at
	THROW_APEX = 9, -- peak height of the arc above the launch point, studs
	THROW_GRAVITY_SCALE = 0.5, -- 1 = real gravity; lower = floatier, longer arc
	THROW_PAST = 8, -- lands this far past the player on the inland side, studs
	THROW_TARGET_DROP = 2.5, -- root part -> feet, so it aims at the ground
	THROW_SPIN = 7, -- tumble rate in flight, radians per second
	THROW_SETTLE_SPEED = 1.5, -- slower than this after landing = at rest
	THROW_MAX_FLIGHT = 3.5, -- take it back from physics after this regardless
	THROW_SETTLE_TIME = 0.2, -- ease from where it stopped into the flat pose

	-- Flopping. The fish lies flat on its side and never rolls over; a flop
	-- is a vertical hop plus a side-to-side swish and a little nose pitch.
	-- Deliberately dramatic (user, 2026-08-22): a landed fish should look like
	-- it's throwing itself into the air, not twitching - hence the big height
	-- and the longer hop that gives the arc time to read.
	FLOP_HEIGHT = 3.2, -- peak of a hop, studs
	FLOP_HOP_MIN = 0.5, -- hop duration range, seconds
	FLOP_HOP_MAX = 0.75,
	FLOP_REST_MIN = 0.4, -- time resting between hops, seconds
	FLOP_REST_MAX = 1.3,
	FLOP_SWISH = math.rad(38), -- peak side-to-side yaw during a hop
	FLOP_SWISH_CYCLES = 1.5, -- swishes per hop
	FLOP_PITCH = math.rad(16), -- how much the nose tips during a hop

	-- Idle wiggle between hops, so it's never perfectly still.
	WIGGLE_RATE = 6, -- radians per second
	WIGGLE_IDLE = math.rad(5), -- yaw amplitude

	-- How fast a knocked-back creature slows, per second (exponential). The
	-- push itself comes from the hit (Tuning.Combat.KNOCKBACK_SPEED); this is
	-- how quickly it bleeds off. Higher = a shorter, snappier shove.
	KNOCKBACK_DAMPING = 9,

	-- Juggling: a hit also launches the creature straight UP (the lift comes
	-- from the weapon - Tuning.Combat.LAUNCH_SPEED), and it falls back under
	-- this gravity. Low gravity = long hang time = easy to combo it in the air.
	-- Hitting it again while airborne re-launches from its current height, so
	-- a fast weapon can keep a fish up. Horizontal push is unchanged by any of
	-- this (user, 2026-08-22: vertical only).
	JUGGLE_GRAVITY = 62, -- studs/second^2 while airborne
	-- Air drift damps at the SAME rate as the ground slide on purpose: an
	-- earlier 2.2 (vs the ground's 9) let a hit carry a creature roughly 4x
	-- further while it was airborne, which read as "the horizontal knockback
	-- got bigger" even though KNOCKBACK_SPEED never changed (user, 2026-08-22).
	-- Keep these two equal unless you actually want air hits to travel more.
	JUGGLE_AIR_DAMPING = 9,
	JUGGLE_SPIN = 7, -- tumble rate while airborne, radians/second
	JUGGLE_LAND_HEIGHT = 0.05, -- below this it has landed, studs

	-- How much of a hit's horizontal shove each archetype actually takes.
	-- Hostiles resist it (user, 2026-08-22): being able to punt an attacking
	-- creature across the beach made them harmless, so they now barely budge
	-- and have to be fought rather than pushed away. Anything not listed takes
	-- the full shove (the passive fish still slide as before).
	KNOCKBACK_MULT_BY_ARCHETYPE = {
		rusher = 0.25,
		shambler = 0.2,
		charger = 0.3,
		spitter = 0.6,
		bloater = 1.0, -- the urchin is MEANT to be shoved away before it pops
		drifter = 0.05, -- the jelly barely moves sideways - it goes UP instead
		burrower = 0.3,
		mimic = 0, -- a clam doesn't budge
		thief = 0.35,
		pulser = 0.25,
		boss = 0, -- an island boss does not get shoved
		companion = 0, -- your own hatchling isn't yours to punt around
		flyer = 0.15, -- a diving bird barely notices a shove (docs/revamp-plan.md §2)
		skythief = 0.15,
		-- Volcano hostiles, same principle as the ocean ones: they hold ground.
		crust = 0.1, -- a slag golem barely notices
		splitter = 0.7, -- a blob of magma sloshes
		thornback = 0.2,
		gascloud = 0.25, -- smoke, but it still has to walk to you
		magnetize = 0.3,
		reborn = 0.25,
		tentacle = 0, -- a Kraken arm is anchored to the storm floor
	},

	-- Same idea for the vertical juggle launch. Hostiles are at 0 - they stay
	-- on the ground, full stop (user, 2026-08-22): a creature held in the air
	-- can't attack, so juggling one was a free way to neutralise it, which is
	-- exactly the challenge the resist above was meant to restore. Juggling
	-- stays a thing you do to the passive catch (anything unlisted = 1).
	-- Two exceptions by design (enemies slice, 2026-08-22): the urchin, which
	-- you WANT to punt into the air away from you, and the jelly, whose whole
	-- gimmick is that every hit sends it floating up.
	LAUNCH_MULT_BY_ARCHETYPE = {
		rusher = 0,
		shambler = 0,
		charger = 0,
		spitter = 0.6,
		bloater = 1.2,
		drifter = 1.8,
		burrower = 0,
		mimic = 0,
		thief = 0,
		pulser = 0,
		boss = 0,
		companion = 0, -- a pet juggled into the air is a pet that can't help
		flyer = 0, -- already airborne; a launch would fight its own height track
		skythief = 0,
		-- Volcano hostiles stay on the ground, same rule as the ocean ones: a
		-- creature held in the air can't fight back, which removes the fight.
		crust = 0,
		splitter = 0,
		thornback = 0,
		gascloud = 0,
		magnetize = 0,
		reborn = 0,
		tentacle = 0,
	},

	-- Gravity while airborne, per archetype (x JUGGLE_GRAVITY). The jelly
	-- falls like a balloon; everything unlisted falls like a fish.
	GRAVITY_MULT_BY_ARCHETYPE = {
		drifter = 0.16,
	},

	-- The "rusher" archetype (the pufferfish): flops in place, then lunges at
	-- the nearest player and rams them. One idle->windup->rush->idle cycle.
	-- Speeds/timings raised for a real challenge (user, 2026-08-22): these
	-- creatures should pressure the player rather than be shoved aside.
	RUSH_AGGRO_RANGE = 80, -- won't start a lunge at a player further than this, studs
	RUSH_REST_MIN = 0.3, -- flops in place this long between lunges, seconds
	RUSH_REST_MAX = 0.7,
	RUSH_WINDUP = 0.28, -- telegraph: crouches and faces the target before lunging, seconds
	RUSH_WINDUP_PITCH = math.rad(20), -- nose-down tuck during the wind-up
	RUSH_TURN_RATE = math.rad(280), -- how fast it can turn to track the player while idle, per second
	RUSH_SPEED = 38, -- lunge speed, studs/second
	RUSH_DURATION = 0.65, -- how long a lunge lasts before giving up, seconds
	RUSH_HOP = 1.4, -- hop height during the lunge, so it reads as a flopping charge
	RUSH_HOPS = 2, -- hops per lunge
	RUSH_PITCH = math.rad(12), -- slight nose-down while lunging

	-- Contact damage to the player when a lunge connects.
	CONTACT_RADIUS = 4.5, -- horizontal distance to the player's centre that counts as a ram, studs
	CONTACT_COOLDOWN = 0.8, -- min time between one creature's rams, seconds
	CONTACT_DAMAGE_MIN = 8,
	CONTACT_DAMAGE_MAX = 14,
	CONTACT_BOUNCE = 2.5, -- how far it recoils back off a ram, studs

	-- The "shambler" archetype (the drowned zombies): stands upright and
	-- trudges straight at the nearest player, no windup, hitting on contact
	-- (reuses CONTACT_* above for the hit). Slow but relentless.
	-- Raised with the rusher's (user, 2026-08-22): still the slow relentless
	-- one, but fast enough to close distance and force a fight.
	SHAMBLE_SPEED = 12, -- walk speed toward the player, studs/second
	SHAMBLE_AGGRO = 90, -- starts advancing at a player within this, studs
	SHAMBLE_TURN_RATE = math.rad(170), -- how fast it can turn to track, per second
	SHAMBLE_BOB = 0.18, -- vertical trudge bob while walking, studs
	SHAMBLE_BOB_RATE = 6, -- bob speed, radians/second
	SHAMBLE_SWAY = math.rad(6), -- idle yaw sway amplitude when no target
	SHAMBLE_SWAY_RATE = 1.5, -- idle sway speed, radians/second

	-- ---------------------------------------------------------- enemies slice (2026-08-22)
	-- Eight new hostile archetypes, each a small state machine in
	-- CreatureService. They share CONTACT_COOLDOWN / CONTACT_RADIUS from above
	-- where they touch the player; their own numbers are here.

	-- Area hits (explosion, shockwave, snap, burst, splash) are measured
	-- horizontally; a player more than this far above or below the centre is
	-- out of it (a pulse on the dock doesn't hit a swimmer underneath).
	AOE_HEIGHT_TOLERANCE = 6,

	-- "charger" (Tideline Skipper): winds up, then dashes in a straight line
	-- PAST the player and has to turn back - exposed while it does.
	CHARGE_AGGRO = 70, -- starts a dash at a player within this, studs
	CHARGE_REST_MIN = 0.5, -- idle flop between dashes, seconds
	CHARGE_REST_MAX = 1.0,
	CHARGE_WINDUP = 0.45, -- the tell, seconds
	CHARGE_SPEED = 46, -- dash speed, studs/second
	CHARGE_OVERSHOOT = 14, -- runs this far past where the player stood, studs
	CHARGE_MAX_DIST = 60, -- a dash never covers more than this, studs
	CHARGE_HOP = 0.6, -- skittering hop height during the dash, studs
	CHARGE_HOP_RATE = 18, -- hop rate, radians/second
	CHARGE_DAMAGE_MIN = 10, -- one hit per dash, no recoil - it keeps going
	CHARGE_DAMAGE_MAX = 16,
	CHARGE_TURN_TIME = 1.1, -- the exposed turn-around after a dash, seconds
	CHARGE_TURN_RATE = math.rad(150), -- how fast it comes back around
	CHARGE_EXPOSED_DAMAGE_MULT = 2.0, -- hits land double while it's turning

	-- "spitter" (Gullet Cod): keeps its distance and spits a glob that lands
	-- where the player stood when it fired (server-simulated landing; the
	-- client draws the arc from the CreatureEvent "spit").
	SPIT_AGGRO = 80,
	SPIT_MIN_RANGE = 14, -- hops away if the player is closer than this, studs
	SPIT_MAX_RANGE = 30, -- hops closer if further than this
	SPIT_HOP_SPEED = 16, -- repositioning speed, studs/second
	SPIT_INTERVAL_MIN = 2.0, -- seconds between spits
	SPIT_INTERVAL_MAX = 3.2,
	SPIT_WINDUP = 0.55, -- rears up before spitting, seconds
	SPIT_REAR_PITCH = math.rad(35), -- how far the nose comes up in the windup
	SPIT_FLIGHT = 0.9, -- glob flight time, seconds (the dodge window)
	SPIT_ARC = 6, -- apex height of the glob's arc, studs (client drawing only)
	SPIT_SPLASH_RADIUS = 5, -- players within this of the landing take the hit
	SPIT_DAMAGE_MIN = 10,
	SPIT_DAMAGE_MAX = 16,

	-- "bloater" (Tidebomb Urchin): swells with every hit and explodes after
	-- enough hits or a fuse - hurting players AND other creatures in range.
	BLOAT_AGGRO = 60,
	BLOAT_ROLL_SPEED = 6, -- creeps toward the player, studs/second
	BLOAT_HITS_TO_POP = 5, -- pops on this many hits...
	BLOAT_FUSE = 4.0, -- ...or this long after the first hit, seconds
	BLOAT_SWELL_PER_HIT = 0.18, -- model scale added per hit
	BLOAT_RADIUS = 11, -- explosion radius, studs
	BLOAT_DAMAGE_MIN = 22, -- to players at the centre; falls off to 40% at the edge
	BLOAT_DAMAGE_MAX = 34,
	BLOAT_CREATURE_DAMAGE = 120, -- to every other creature in range
	BLOAT_CREATURE_KNOCKBACK = 30, -- and they get thrown outward...
	BLOAT_CREATURE_LIFT = 18, -- ...and up (subject to their launch mult)

	-- "drifter" (Moonbell Jelly): hovers toward the player and stings on
	-- contact. Hits send it floating up (see LAUNCH/GRAVITY mults).
	DRIFT_AGGRO = 70,
	DRIFT_SPEED = 5, -- studs/second
	DRIFT_HOVER = 1.2, -- rest height of the bell above the ground, studs
	DRIFT_BOB = 0.45, -- hover bob amplitude, studs
	DRIFT_BOB_RATE = 2.2, -- radians/second
	DRIFT_CONTACT_RADIUS = 4, -- sting range, studs
	DRIFT_DAMAGE_MIN = 6,
	DRIFT_DAMAGE_MAX = 10,

	-- "burrower" (Sand Lurker): surfaces for a while, digs in (hidden and
	-- untargetable), tunnels at the player, bursts up under them.
	BURROW_AGGRO = 90,
	BURROW_SURFACE_TIME = 3.5, -- hittable window after it comes up, seconds
	BURROW_SINK_TIME = 0.5, -- digging in, seconds
	BURROW_DEPTH = 2.5, -- how far under the ground it sinks, studs
	BURROW_SPEED = 13, -- tunnelling speed, studs/second
	BURROW_AMBUSH_RADIUS = 4.5, -- bursts up once within this of the player, studs
	BURROW_EMERGE_TIME = 0.4, -- the burst, seconds
	BURROW_EMERGE_HOP = 4, -- how high it leaps out, studs
	BURROW_EMERGE_RADIUS = 6, -- players within this of the burst take the bite
	BURROW_DAMAGE_MIN = 14,
	BURROW_DAMAGE_MAX = 22,

	-- "mimic" (Pearl Mimic): a shut clam, untargetable, until a player gets
	-- close - then it snaps, and stays open (hittable) for a moment.
	MIMIC_SNAP_RADIUS = 6, -- a player within this wakes it, studs
	MIMIC_SNAP_WINDUP = 0.35, -- lid cracks open as the tell, seconds
	MIMIC_SNAP_DAMAGE_RADIUS = 7, -- the snap hits players within this
	MIMIC_DAMAGE_MIN = 24,
	MIMIC_DAMAGE_MAX = 36,
	MIMIC_OPEN_TIME = 2.2, -- gaping, hittable, seconds
	MIMIC_CLOSED_MIN = 1.5, -- can't snap again sooner than this after shutting
	MIMIC_LID_OPEN = math.rad(75), -- how far the lid hinges open
	MIMIC_HINGE_BACK = 0.9, -- the hinge sits this far behind the shell's centre, studs (matches the stand-in)

	-- "thief" (Pickpocket Hermit): charges, steals coins on contact, flees
	-- zig-zagging, comes back for more. Kill it to get the loot back + a bonus.
	THIEF_AGGRO = 80,
	THIEF_SPEED = 20, -- chase, studs/second
	THIEF_FLEE_SPEED = 24, -- flee, studs/second
	THIEF_FLEE_TIME = 4.0, -- seconds of fleeing before it turns back
	THIEF_ZIGZAG = math.rad(50), -- flee path weave amplitude
	THIEF_ZIGZAG_RATE = 5, -- weave speed, radians/second
	THIEF_HOP = 0.5, -- scuttle hop height, studs
	THIEF_HOP_RATE = 14,
	THIEF_CONTACT_DAMAGE_MIN = 4,
	THIEF_CONTACT_DAMAGE_MAX = 8,
	THIEF_STEAL_FRACTION = 0.15, -- of the victim's coins per pickpocket...
	THIEF_STEAL_MIN = 5, -- ...at least this (if they have it)...
	THIEF_STEAL_MAX = 150, -- ...and at most this
	THIEF_BONUS = 0.5, -- killing it pays the loot back times (1 + this)

	-- "pulser" (Voltray): approaches, charges up (hitting it then shocks YOU),
	-- and discharges a ring that hurts everyone inside it.
	PULSE_AGGRO = 70,
	PULSE_SPEED = 7, -- studs/second
	PULSE_IDLE_MIN = 1.6, -- seconds between discharges
	PULSE_IDLE_MAX = 2.6,
	PULSE_TRIGGER_RANGE = 16, -- only charges with a player within this, studs
	PULSE_CHARGE = 1.3, -- charge-up (the tell), seconds
	PULSE_RADIUS = 12, -- discharge radius, studs
	PULSE_DAMAGE_MIN = 18, -- at the centre; half at the edge
	PULSE_DAMAGE_MAX = 28,
	PULSE_SHOCK_DAMAGE = 12, -- to an attacker who hits it while charging

	-- ---- Volcano archetypes (2026-08-23, docs/volcano-content-spec.md) ----
	-- Six signature mechanics layered onto existing movement, so each volcano
	-- hostile fights differently from anything in the ocean. Movement knobs are
	-- reused from the archetype each one is built on (shambler / rusher /
	-- charger); what's here is only the new behaviour.

	-- "crust" (Slagheart Golem): armoured in cooled slag. Almost everything
	-- bounces off until enough hits crack it, then its molten core is exposed
	-- for a short window and it takes FULL damage. Shambles either way, so the
	-- fight is about timing your damage, not about kiting.
	CRUST_DAMAGE_MULT = 0.25, -- what gets through while the crust holds
	CRUST_HITS = 5, -- hits to crack it (counted while armoured)
	CRUST_WINDOW = 4.0, -- seconds the core stays exposed
	CRUST_EXPOSED_MULT = 1.5, -- damage taken while exposed

	-- "splitter" (Magma Ooze): dies into two smaller oozes. The halves are
	-- weaker, smaller, and can't split again, so a fight is bounded at three
	-- bodies. Their payout is cut so splitting isn't a loot multiplier.
	SPLIT_COUNT = 2,
	SPLIT_HEALTH_MULT = 0.4,
	SPLIT_SCALE = 0.6,
	SPLIT_BOUNTY = 0.4, -- each half pays this share of a normal kill
	SPLIT_SPREAD = 4, -- studs the halves are placed either side of the death

	-- "reborn" (Ashfeather Phoenix): the first death isn't one. It drops,
	-- untouchable, then rises at a fraction of its health and has to be put
	-- down a second time. Once only.
	REBORN_DOWN = 2.5, -- seconds spent down
	REBORN_FRACTION = 0.4, -- health it comes back at

	-- "thornback" (Obsidian Shardback): plated at the front. Hitting the face
	-- barely scratches it and drives glass into your fist; its back is soft.
	-- The one enemy that asks you to move rather than trade.
	THORN_FRONT_DOT = 0.2, -- dot(facing, toAttacker) above this counts as "in front"
	THORN_FRONT_MULT = 0.35, -- damage it takes from the front
	THORN_BACK_MULT = 1.6, -- ...and from behind
	THORN_REFLECT = 9, -- damage dealt back to a front attacker

	-- "gascloud" (Cinder Djinn): leaves burning smoke where it walks. A moving
	-- hazard rather than a projectile - the danger is the ground it has covered,
	-- so chasing it through its own trail is the mistake.
	GAS_INTERVAL = 1.1, -- seconds between puffs it sheds
	GAS_LIFETIME = 5.0, -- how long a puff burns
	GAS_TICK = 0.6, -- seconds between damage ticks inside one
	GAS_RADIUS = 7,
	GAS_DAMAGE_MIN = 4,
	GAS_DAMAGE_MAX = 7,
	GAS_MAX_PUFFS = 8, -- oldest is dropped past this, so a long fight can't carpet the rim

	-- "magnetize" (Lodestone Eel): hauls you in on a cycle. It doesn't damage
	-- you directly - it ruins your spacing and lets everything else reach you.
	-- Reuses the boss lure's client-side `pull` event (a ramped VectorForce on
	-- the owning client), so these are in its units, not an impulse.
	MAG_INTERVAL = 3.2, -- seconds between pulls
	MAG_RANGE = 55, -- studs it can pull from
	MAG_STRENGTH = 22, -- force per unit mass; the boss lure uses 25
	MAG_DURATION = 1.1, -- seconds each drag lasts

	-- ---- Flyers (revamp Session 2, docs/revamp-plan.md Systems §2) ----
	-- "flyer": circles overhead out of melee reach, telegraphs, dives at where
	-- you WERE when the dive began (the dodge window, same rule as spitter
	-- landings), then spends a recovery window ON THE GROUND - the deliberate
	-- melee counterplay. Height rides the pose's hop term while `pos` stays
	-- ground-clamped, so bounds / knockback / LINGER all work untouched.
	FLY_HEIGHT = 16, -- cruise height above the ground, studs (out of melee reach)
	FLY_AGGRO = 90, -- circles / dives players within this, studs
	FLY_SPEED = 22, -- orbit speed, studs/second
	FLY_TURN_RATE = math.rad(240), -- how fast it can bank to track, per second
	FLY_ORBIT_RADIUS = 18, -- preferred horizontal ring around the player, studs
	FLY_BOB = 0.6, -- hover bob amplitude while circling, studs
	FLY_BOB_RATE = 3.2, -- radians/second
	FLY_CIRCLE_MIN = 2.0, -- seconds circling before it considers a dive
	FLY_CIRCLE_MAX = 3.6,
	FLY_WINDUP = 0.7, -- the hover tell before the dive, seconds
	FLY_DIVE_SPEED = 55, -- studs/second along the dive line
	FLY_DIVE_RADIUS = 5, -- players within this of the impact take the hit
	FLY_DIVE_DAMAGE_MIN = 12,
	FLY_DIVE_DAMAGE_MAX = 18,
	FLY_GROUNDED_MIN = 1.2, -- recovery on the deck after a dive - the melee window
	FLY_GROUNDED_MAX = 2.0,
	FLY_CLIMB_SPEED = 18, -- studs/second back up to cruise height

	-- "skythief": the aerial thief - circles like a flyer, but what it dives on
	-- is your RESTING CATCH: it snatches a passive fish off the ground, carries
	-- it up, and flies out to sea. Kill it to drop the cargo; let it escape and
	-- you lose both. With nothing to steal it dive-bombs like a plain flyer.
	SKYTHIEF_SEEK = 70, -- looks for a resting passive catch within this, studs
	SKYTHIEF_SWOOP_SPEED = 50, -- studs/second down at the fish
	SKYTHIEF_GRAB_RADIUS = 4, -- close enough to snatch, studs
	SKYTHIEF_CARRY_DROP = 2.4, -- the cargo hangs this far under the bird, studs
	SKYTHIEF_FLEE_SPEED = 26, -- studs/second while carrying
	SKYTHIEF_ESCAPE = 160, -- studs of flight before bird and cargo are gone for good

	-- ---- the finale's tentacle archetype (a Kraken arm; revamp Session 4) ----
	-- Planted where the boss's parts ring put it: it never walks, it slams a
	-- telegraphed ring around itself. Both knockback and launch multipliers
	-- are 0 (the tables above), so the counterplay is killing it, not
	-- shoving it - and killing the whole ring is what exposes the head.
	TENTACLE_AGGRO = 34, -- starts slamming with a player inside this, studs
	TENTACLE_WINDUP = 0.9, -- the rear-back tell (telegraph ring), seconds
	TENTACLE_RECOVER = 0.8, -- the opening after the slam, seconds
	TENTACLE_RADIUS = 12, -- the slam ring, studs
	TENTACLE_DAMAGE_MIN = 45,
	TENTACLE_DAMAGE_MAX = 65,
	TENTACLE_COOLDOWN_MIN = 3.5, -- between slams, seconds
	TENTACLE_COOLDOWN_MAX = 5.0,
}

-- ============================================================ Player

-- The player's own health (PlayerService, backed by the character Humanoid;
-- the HUD is PlayerHudController). Damage comes only from PlayerService.damage.
Tuning.Player = {
	MAX_HEALTH = 100,
	IFRAME = 0.35, -- brief invulnerability after any hit, so overlaps can't multi-drain, seconds
	REGEN_DELAY = 7, -- no healing until this long after the last hit, seconds
	REGEN_RATE = 6, -- then heals this many HP per second up to the max
}

-- ============================================================ Fishing minigames

-- Per-minigame tuning for the fishing minigames beyond the base reel (which
-- reads Tuning.Reel). Each cast randomly rolls one; see Shared/Modules/Minigames.
Tuning.Minigames = {
	-- Rapid-tap burst ("it's diving!"): mash to fill the bar before the timer.
	-- The window opens on the first tap and lasts DURATION; TARGET_TAPS is a
	-- full bar (so the pace to win is ~TARGET_TAPS / DURATION taps per second);
	-- MAX_TAPS_PER_SEC is the server's human-rate cap on counted taps;
	-- OPEN_TIMEOUT auto-ends the burst if the player never taps.
	Burst = {
		DURATION = 3.0,
		TARGET_TAPS = 20, -- slightly harder (user, 2026-08-22): ~6.7 taps/s to fill, up from 5.3
		MAX_TAPS_PER_SEC = 14,
		OPEN_TIMEOUT = 4.0,
	},

	-- Tap-targets ("snap"), whack-a-mole: one target appears at a random spot
	-- and vanishes after LIFETIME; tap it in time. COUNT targets in a row;
	-- perf = hits / COUNT. Touch-first (mobile-friendly), cursor freed on
	-- desktop so clicks land too.
	Snap = {
		COUNT = 5,
		LIFETIME = 1.5,
	},
}

-- ============================================================ Combat

-- The first, minimal melee: a fists punch (CombatService). Placeholder
-- numbers - the point right now is that a hit lands and the feedback fires;
-- a real weapon/damage pass retunes these.
Tuning.Combat = {
	-- Seconds between punches. Shorter than the punch clip (~0.23 s) on
	-- purpose so mashing overlaps and chains; the client shows exactly the
	-- punches this lets through. The user asked for ~3x the original 0.4.
	PUNCH_COOLDOWN = 0.14,
	PUNCH_REACH = 14, -- how far from the player a creature can be hit, studs
	PUNCH_DAMAGE_MIN = 6, -- damage rolls in this range, so numbers vary
	PUNCH_DAMAGE_MAX = 10,

	-- Knockback: the initial speed (studs/sec) a punch shoves a fish away
	-- from the player. It decays at Tuning.Creature.KNOCKBACK_DAMPING, so the
	-- distance travelled is roughly SPEED / DAMPING (~1.5 studs at these
	-- numbers) - "a little bit". A killing blow skips it.
	KNOCKBACK_SPEED = 14,

	-- Vertical launch on a hit, studs/second up. With
	-- Tuning.Creature.JUGGLE_GRAVITY this sets the pop height (v^2 / 2g) and
	-- the hang time (2v/g). At 11 that's ~1 stud up and ~0.35 s hanging - a
	-- small pop you can still combo, after 26 (~5.5 studs) was way too high
	-- (user, 2026-08-22: "cut it down by over half"). A Weapons row may
	-- override this with its own `launch` field, so a heavy club can juggle
	-- harder than a blade; no row sets it yet, so every weapon uses this.
	LAUNCH_SPEED = 11,
}

-- ============================================================ Ranged weapons

-- The ranged engine (revamp Session 2, docs/revamp-plan.md Systems §1):
-- server-authoritative hitscan at fire time with a cosmetic flight delay.
-- Per-weapon numbers (damage, cooldown, magazine, reload, spread, speed)
-- live on the Weapons row's `ranged` block; these are the engine's own knobs.
Tuning.Ranged = {
	-- The client reports the ray's origin (its camera); the server accepts it
	-- only within this of the character's head, so a hacked client can't shoot
	-- from across the map. Generous enough for camera offset + a moving character.
	ORIGIN_SLACK = 6,

	-- Token bucket per player: bucket = min(CAP, bucket + elapsed/cooldown),
	-- one token per shot. A client spamming RequestShoot lands exactly
	-- 1/cooldown shots per second; the cap absorbs one queued shot of jitter.
	BUCKET_CAP = 2,

	-- Arc weapons (bows): the shot is re-checked at landing - a sphere this
	-- big at the predicted impact against live creatures - so a dodged arrow
	-- misses. Guns apply the fire-time hit verbatim.
	ARC_RECHECK_RADIUS = 3,

	-- A flight delay is never longer than this, however slow the projectile
	-- (keeps a mis-tuned row from queueing damage seconds into the future).
	MAX_FLIGHT = 2.0,

	-- Scoped weapons: the FOV the client zooms to while aiming (a row's
	-- `zoomFov` overrides). The default camera FOV is 70.
	DEFAULT_ZOOM_FOV = 30,
}

-- ============================================================ Gear perks

-- The signature abilities on the rarer weapons (Weapons.luau `perk`). Rod
-- perks carry their own numbers in Rods.luau; these are the shared knobs the
-- combat side reads.
Tuning.Perks = {
	-- Brine Rot (Drowncleaver): hits stack a damage-over-time. Each stack
	-- ticks independently, so a fast weapon builds real pressure - and the
	-- rot keeps burning while a creature is untargetable (a boss mid-dive),
	-- which is the only way to hurt it during that phase.
	POISON_TICK = 0.5, -- seconds between ticks
	POISON_MAX_STACKS = 5,

	-- Frenzy (Scaleblade): consecutive hits ramp damage. The window is
	-- generous enough to survive a missed swing, short enough that walking
	-- away resets you.
	FRENZY_STEP = 0.12, -- +12% per hit in the chain
	FRENZY_MAX = 0.6, -- capped at +60%
	FRENZY_WINDOW = 2.0, -- seconds since the last hit before the chain drops

	-- Uproot (Shellcrusher): overrides an archetype's launch resistance so
	-- normally-grounded enemies can be popped and juggled. Archetypes listed
	-- here stay planted regardless - a boss is never juggled.
	-- Flyers are immune too: they are already airborne on their own height
	-- track, and an uproot's juggle track (airY) fighting it snaps the bird
	-- between two altitudes (review find, 2026-08-25). Ground them by
	-- fighting them, not by launching them.
	UPROOT_IMMUNE = { boss = true, flyer = true, skythief = true },

	-- Blast Radius (Tidebomb Maul): the swing also catches every OTHER
	-- creature within reach, at a fraction of the damage. Splash targets take
	-- no knockback and no on-hit perk - only the primary target gets those -
	-- so a cleave can't juggle a whole crowd or apply five poisons at once.
	CLEAVE_FALLOFF = 0.45,

	-- Overload (Voltfang): a wounded target takes far more. Reads the
	-- creature's own health fraction, so it scales with anything.
	EXECUTE_BELOW = 0.35, -- at or under this fraction of max health
	EXECUTE_MULT = 2.0,

	-- Devour (Heartrender): heals the attacker for this fraction of the
	-- damage actually dealt. Only the primary target feeds it.
	LIFESTEAL = 0.22,
}

-- ============================================================ Rewards

-- What a kill pays, by the creature's rarity. Coins roll uniformly in the
-- range; XP is flat. Both are then multiplied by the reel grade's
-- rewardMult (Tuning.Grade below), so a sloppy Enraged reel pays 1.5x.
-- A row can override these with its own `rewards` field (Creatures.luau).
Tuning.Rewards = {
	BY_RARITY = {
		Common = { coins = { 4, 8 }, xp = 12 },
		Uncommon = { coins = { 12, 20 }, xp = 35 },
		Rare = { coins = { 35, 55 }, xp = 90 },
		Epic = { coins = { 90, 140 }, xp = 220 },
		Legendary = { coins = { 250, 400 }, xp = 600 },
	},
}

-- ============================================================ Progression

-- Level curve: XP to clear level L is XP_BASE * L ^ XP_EXPONENT.
--   L1 -> 60, L5 -> ~530, L10 -> ~1340, L20 -> ~3420 at these numbers,
-- so early levels come every couple of commons and later ones take a run
-- of rares. Coins and XP are in-memory only until persistence (Slice 9).
Tuning.Progression = {
	XP_BASE = 60,
	XP_EXPONENT = 1.35,
	START_LEVEL = 1,
	MAX_LEVEL = 50,
	START_COINS = 0,
}

-- ============================================================ Combat opening state

-- What grade the reel earns decides how the catch surfaces. Not consumed by
-- anything yet - creatures don't exist until Slice 4, combat until Slice 5 -
-- but it's the plan of record for the invariant "the reel sets the combat
-- opening", same reasoning as World.luau's still-unused dock constants.
Tuning.Grade = {
	Hooked = {
		stunDuration = 1.6,
		healthMult = 1.0,
		damageMult = 1.0,
		speedMult = 1.0,
		rewardMult = 1.0,
	},
	Neutral = {
		stunDuration = 0.35,
		healthMult = 1.0,
		damageMult = 1.0,
		speedMult = 1.0,
		rewardMult = 1.0,
	},
	Enraged = {
		stunDuration = 0,
		healthMult = 1.25,
		damageMult = 1.4,
		speedMult = 1.35,
		-- Sloppy reels are worth more, so a bad cast is a different fight rather
		-- than a punishment.
		rewardMult = 1.5,
	},
}

-- ============================================================ Bait

-- Knobs for the bait effects that DO something you can watch (Bait.luau's
-- header explains why that's the rule). `luck` / `rewardMult` / `stun` /
-- `hostileOnly` / `guaranteedDrop` need no tuning - they are the number in the
-- row. These five do.
Tuning.Bait = {
	-- Chum's shoal: the spare fish that come up with the catch. They're thrown
	-- from a ring around the bobber so their arcs don't overlap into one pile,
	-- and they land at the plain grade - the bonus is that they exist at all.
	SHOAL_GRADE = "Neutral",
	SHOAL_SPREAD = 7, -- studs from the bobber each extra fish is thrown from

	-- Bloodbait's chain: how long the water stays quiet before the next one
	-- comes up, and how much luckier each link is rolled than the one before.
	-- The escalation is in the ROLL, not in a payout multiplier: link 3 is
	-- worth more because it's a rarer creature, which is also what you see.
	CHAIN_DELAY = 1.1, -- seconds after a kill before the next surfaces
	CHAIN_LUCK_STEP = 0.6, -- +60% luck per link already killed

	-- Frenzy Bait's enrage. The Enraged grade already pays 1.5x on a kill, so
	-- this is the top-up that takes the total to about double - it is NOT the
	-- whole multiplier. Rides the kill as `bounty`, which ProgressionService
	-- and MaterialService both apply.
	ENRAGE_BOUNTY = 1.35,

	-- Gravelure's salvage: a cast with no fish. Paid straight out of the water
	-- and scaled by the minigame grade, so it's still a cast you have to play.
	-- Sized to beat the bait's own recipe cost (200 coins + 8 scale + 1 pearl
	-- for three) by a clear margin, or nobody would ever craft it.
	SALVAGE_COINS = { 90, 180 },
	SALVAGE_MATERIALS = {
		driftwood = { 3, 6 },
		kelp_fiber = { 3, 6 },
		fish_scale = { 2, 4 },
		pearl = { 0, 1 }, -- a 0 roll is simply skipped by grantBatch
	},

	-- Split Roe's hatchling: the one friendly creature in the game. Fast and
	-- fragile - it out-runs what it hunts, and it is meant to be an extra pair
	-- of jaws, not a replacement for the player's own fists.
	HATCHLING_HEALTH = 120,
	HATCHLING_SEEK = 70, -- studs it will look for a hostile within
	HATCHLING_SPEED = 34, -- studs/second when hunting
	HATCHLING_FOLLOW_SPEED = 26, -- studs/second when trailing its owner
	HATCHLING_FOLLOW_RANGE = 14, -- gets no closer than this when idle
	HATCHLING_BITE_RANGE = 5.5,
	HATCHLING_BITE_COOLDOWN = 0.8,
	HATCHLING_DAMAGE_MIN = 10,
	HATCHLING_DAMAGE_MAX = 16,
	HATCHLING_HOP = 0.75, -- swim-bob height, studs
	HATCHLING_HOP_RATE = 9, -- bobs per second
}

-- ============================================================ Materials

-- Crafting materials (Materials.luau), earned two ways. Basic mats come up on
-- every completed cast - the debris your line drags in. Rare mats drop only
-- when you kill the surfaced catch, scaled by the reel grade's rewardMult
-- (Tuning.Grade), better catches dropping better mats. Counts roll uniformly
-- in each { min, max }. In-memory only until persistence (Slice 9).
Tuning.Materials = {
	-- Granted on every cast resolve, regardless of the catch.
	CAST_GRANT = {
		driftwood = { 1, 3 },
		kelp_fiber = { 1, 2 },
	},

	-- Dropped on a kill, keyed by the creature's rarity. A rarity absent here
	-- (or a kill with no killer) drops nothing. Amounts are then multiplied by
	-- the grade's rewardMult, same as coins/XP.
	KILL_BY_RARITY = {
		Common = { fish_scale = { 1, 1 } },
		Uncommon = { fish_scale = { 1, 2 } },
		Rare = { fish_scale = { 2, 3 }, pearl = { 1, 1 } },
		Epic = { fish_scale = { 3, 4 }, pearl = { 1, 2 } },
		Legendary = { fish_scale = { 4, 6 }, pearl = { 2, 3 } },
	},
}

-- ============================================================ Boat

-- The drivable boat (Boats.luau rows, BoatService/BoatController). Per-tier
-- numbers (speed, turn, hull, seaworthiness) live on the rows; this section
-- is how EVERY boat feels and how the open-sea attrition behaves.
Tuning.Boat = {
	-- Feel (the driver's client holds these).
	ACCELERATION = 24, -- studs/s^2 toward the throttle's target speed
	REVERSE_FACTOR = 0.4, -- reverse top speed, as a fraction of forward
	Y_GAIN = 4, -- P-gain pulling the hull to the waterline (per second)
	BOB_HEIGHT = 0.25, -- gentle idle bob, studs (visual only; matches the tide's scale)
	BOB_PERIOD = 3.2, -- seconds per bob
	SIDE_DAMPING = 3, -- how hard lateral drift is bled off (per second)

	-- Open-sea attrition (BoatService's 1s loop). Past the row's
	-- `seaworthiness` distance the hull takes DOT_BASE damage per second,
	-- ramping the further out you push: +100% per RAMP_DISTANCE studs beyond
	-- the line. The warning fires once when the DoT starts.
	DOT_BASE = 6,
	RAMP_DISTANCE = 300,
	WARNING = "The hull groans - this is more sea than she can take!",

	-- Sinking: at 0 hull the occupants are dumped in the drink (the under-map
	-- net and the solid sea rescue them) and the wreck despawns after a beat.
	SINK_LINGER = 2.5, -- seconds the dead hull lingers before despawning

	-- Housekeeping.
	PARK_SNAP_DELAY = 1.2, -- seconds after the seat empties before the server re-anchors
	SUMMON_COOLDOWN = 3, -- seconds between RequestBoat uses (anti-spam)
	REPAIR_ON_SUMMON = true, -- a fresh summon at shore is a free patch-up
}

-- ============================================================ Spawner

-- The ambient spawner (SpawnerService). Per-island rosters live on
-- Islands.items[id].ambient; this is the machinery's own pacing.
Tuning.Spawner = {
	TICK = 2, -- seconds between spawn sweeps
	GLOBAL_CAP = 40, -- ambient creatures across ALL islands (one Heartbeat serves everything)
	RING = { 60, 100 }, -- default distance band around the chosen player
}

-- ============================================================ Raid

-- Island raids (RaidService). Per-island waves/intervals/rewards live on
-- Islands.items[id].raid; these are the defaults and the shared feel.
Tuning.Raid = {
	ANNOUNCE = 60, -- warning countdown, seconds (a raid block may override)
	WAVE_TIME_LIMIT = 240, -- per wave before the raid counts as failed
	WAVE_BREATHER = 4, -- seconds between a cleared wave and the next
	BOUNTY = 0.35, -- kill payouts during a raid (the clear reward is the real payday)
	SPAWN_RING = { 34, 64 }, -- raid mobs land closer than ambient ones: they come FOR you
}

return Tuning
