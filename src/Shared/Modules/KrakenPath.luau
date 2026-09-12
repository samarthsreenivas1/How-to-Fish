--!nonstrict
-- KrakenPath.luau
-- The shape of the Kraken, rebuilt for THE SHIP FIGHT.
--
-- What changed, and why nothing of the old file survives: the Kraken used to
-- be a head parked in the middle of a whirlpool with eight arms reaching out
-- to a ring of tentacle creatures standing on rocks. It is now a colossus
-- moored 350 studs off a galleon's PORT RAIL, reaching four building-sized
-- limbs ACROSS a 170-stud ship that is itself the arena floor. The old
-- socket-ring, the whirlpool lift, the beak and the eight-arm arc all
-- described a fight that no longer exists, so they are gone rather than
-- re-tuned. (assets/boss_gen.py + assets/arena_gen.py, `HANDOFF kraken`.)
--
-- Same contract as before and as BrinejawPath: PURE MATH. No Instances, no
-- state of its own, no reads of the DataModel. The server publishes a handful
-- of attributes, both sides run these functions off them, and the limb you
-- dodge is the limb you see.
--
-- THE ONE IDEA WORTH KNOWING: an arm is a CUBIC BEZIER whose four control
-- points are chosen per ArmPhase, and a phase change is a lerp of those FOUR
-- POINTS rather than a lerp of two sampled curves. A Bezier is affine in its
-- control points, so
--     bezier(lerp(A_i, B_i, w), t)  ==  lerp(bezier(A, t), bezier(B, t), w)
-- exactly - this IS ChainPose.blend of the two pose shapes, computed with 4
-- lerps instead of two curve evaluations. See KrakenPath.armPoint for the
-- C1 argument that goes with it.

local KrakenPath = {}

-- ---------------------------------------------------------------- the pack
--
-- Every number in this block is AUTHORED units off assets/boss_gen.py's
-- build_kraken, measured from the exported meshes rather than read off the
-- builder's intent. Multiply by SCALE for studs.

-- The draw scale. NOT a look choice: boss_gen's HANDOFF states in as many
-- words that "6.0 is what this pack was shaped and previewed against", and
-- every staged render, the arena's 480-stud head clearance and the ship's
-- 350-stud standoff were all composed at it. Changing it is a re-render, not
-- a tweak.
KrakenPath.SCALE = 6.0

KrakenPath.HEAD_TOP = 80.0 -- mantle top, authored about the waterline
KrakenPath.HEAD_BASE = -16.0 -- ...and how far below it the mantle closes
KrakenPath.HEAD_HALF_WIDTH = 47.0 -- the widest ring, at z = 24

-- THE MANTLE'S FULL HEIGHT, and it exists because THE SERVER READS IT.
-- CreatureService (`Fn.colossusState`, the capture-sphere lift) computes
--     KrakenPath.lift(state) + KrakenPath.HEAD_HEIGHT * KrakenPath.SCALE * 0.4
-- and that file is under another lane's rewrite and is not freely editable
-- from here, so this name is a PUBLISHED SEAM rather than an internal
-- convenience: a rename of it is a nil arithmetic error on the Kraken's first
-- posed frame, with the fight crashing exactly at rise. If the mantle is ever
-- re-authored, change the VALUE and keep the NAME.
--
-- Checked: 96 * 6.0 * 0.4 = 230.4 studs above the rise-aware lift. The mantle
-- runs 96 studs below the waterline to 480 above it at SCALE 6, so at Rise 1
-- the capture sphere sits 230 studs up - a little under half the standing
-- head, i.e. mid-mantle and inside the body, which is what a capture sphere
-- wants. (At Rise 0 it rides down with `lift` and is 250 studs under.)
KrakenPath.HEAD_HEIGHT = KrakenPath.HEAD_TOP - KrakenPath.HEAD_BASE -- 96

-- THE WELD LAW, stated as three numbers because two of them alone cannot
-- state it. A segment is a CAPSULE 12.0 long on a 4.0 half-width whose
-- FULL-RADIUS parallel section is 9.6 units - 0.80 of its length either side
-- of centre. What must hold is PARALLEL > effective spacing, so that a bent
-- chain is still one unbroken limb: 9.6 > 6.0, with 3.6 units of slack.
--
-- The trap is that the drawn spacing is not SEG_PITCH alone. ChainPose walks
-- the chain by ARC LENGTH, so the spacing between drawn centres is exactly
-- SEG_PITCH; but each segment is also drawn shortened by the length taper
-- (TIP_LENGTH in the body controller), which shrinks the parallel section
-- while the pitch stays put. KrakenPath.weldSlack() is the assertion that
-- covers both, and the controller runs it once at adopt.
KrakenPath.SEG_LENGTH = 12.0
KrakenPath.SEG_PITCH = 6.0
KrakenPath.SEG_PARALLEL = 9.6
KrakenPath.SEG_HALF_WIDTH = 4.0

-- Studs, not authored units - these are what the drawn chain uses.
KrakenPath.SPACING = KrakenPath.SEG_PITCH * KrakenPath.SCALE -- 36
KrakenPath.GIRTH = KrakenPath.SEG_HALF_WIDTH * KrakenPath.SCALE -- 24: half-thickness at the shoulder

-- How much shorter (0..1) a segment's parallel section may get before the
-- chain stops being one limb. Returns the slack in STUDS at a given length
-- taper; negative means the limb has beads.
function KrakenPath.weldSlack(tipLengthTaper: number): number
	local shortest = KrakenPath.SEG_PARALLEL * (1 - (tipLengthTaper or 0))
	return (shortest - KrakenPath.SEG_PITCH) * KrakenPath.SCALE
end

-- ---------------------------------------------------------------- the arena
--
-- THE SHIP IS THE ARENA ORIGIN, and the head is not at it. arena_gen's
-- `HANDOFF kraken` puts `KrakenArena_Base` centred on the BossArenas row's
-- `center`, with the head at arena-local (0, +370) - 350 studs off the PORT
-- rail. Author +Y is port, and the glTF y-up export maps author +Y to Roblox
-- -Z, so every arena number below is converted ONCE, here, and the rest of
-- the file is pure Roblox:
--
--     roblox = Vector3.new(author_x, author_z, -author_y)
--
-- Author z = 0 is the waterline, so a ship-local Y is studs above the sea.
-- BossArenaService.placeAuthored translates only (`model:PivotTo(pivot +
-- delta)`), so ship-local axes ARE world axes and no rotation appears here.
KrakenPath.HEAD_OFFSET = Vector3.new(0, 0, -370)

KrakenPath.SHIP = {
	LEN = 170.0,
	HALF_BEAM = 19.9, -- at midships; the hull narrows to both ends
	DECK_Y = 8.0, -- the main deck: the datum every height is quoted off
	FC_Y = 15.0, -- forecastle, x >= 50
	QD_Y = 17.0, -- quarterdeck, x <= -40, and the spawn
	WAIST_MIN_X = -40.0, -- the phase-1 floor: the quarterdeck's forward bulkhead
	WAIST_MAX_X = 50.0, -- ...to the forecastle's after bulkhead
	RAIL_PORT_Z = -19.0, -- the bulwark line at midships, head side
	RAIL_STBD_Z = 19.0, -- ...and the far side, which a limb has to cross to
	MAST_X = -6.0, -- the mainmast, in the middle of the waist
	-- THE SWEEP PLANE, and it is a contract rather than a look. arena_gen
	-- measured every crate on the deck against it: a lateral sweep's UNDERSIDE
	-- at deck + 3.0 clears the bulwark, clears the tallest cover, clears a
	-- CROUCHED head by 0.4 - and a STANDING head at deck + 5.0 is 2.0 studs
	-- INTO it. The cover is the answer, not the rail. The drawn limb's
	-- CENTRELINE therefore rides at deck + 3.0 + (its own girth there), which
	-- is what sweepCentreY does; putting the centreline on the plane itself
	-- would bury half a 48-stud limb in the planking and delete the mechanic.
	SWEEP_CLEAR = 3.0,
}

-- THE FOUR AUTHORED WRAP POINTS, ship-local Roblox, in the order the arena
-- builds them - so `WrapIndex` 1..4 off the server indexes straight in.
-- (arena_gen KA_WRAPS -> _ka_wrap_point: PortAft, PortFore, StbdAft,
-- StbdFore. They are STAGGERED on X so no two opposed arms can own the whole
-- width of the waist at once, and each has a 12-stud boarding gap cut in the
-- bulwark for the limb to come through.)
KrakenPath.WRAPS = {
	Vector3.new(-26.0, 8.0, -18.88), -- PortAft   (head side)
	Vector3.new(34.0, 8.0, -16.51), -- PortFore  (head side)
	Vector3.new(-34.0, 8.0, 18.70), -- StbdAft   (across the ship)
	Vector3.new(22.0, 8.0, 17.78), -- StbdFore  (across the ship)
}

-- HOW MANY LIMBS, and the split between them is a design ruling rather than
-- an implementation detail.
--
-- TWO of them are the fight. The whole phase machine rests on it - both arms
-- broken inside one cycle is what opens the siphon window - so exactly two
-- creature models will ever carry ArmPhase, and those are the two things you
-- hit. (The old rig drew eight, one per tentacle on a ring that no longer
-- exists.)
--
-- The other TWO are DECORATION and are stated as such: client-only,
-- attribute-less, never given a target, never crossing a rail. They exist
-- because an animal this size with two limbs reads as amputated, and they are
-- seated on the OUTBOARD roots so they drape away down the far side of the
-- crown where nothing about the fight happens. Nothing may ever hang a
-- mechanic on them - they are drawn from an idle curve and a drift term, and
-- there is no server state behind them to be right or wrong about.
KrakenPath.FIGHT_ARMS = 2
KrakenPath.AMBIENT_ARMS = 2
KrakenPath.ARM_COUNT = KrakenPath.FIGHT_ARMS + KrakenPath.AMBIENT_ARMS

-- Which seat is which. The two INBOARD roots (nearest the ship on the head's
-- own lateral axis) are the fight's, so a working limb has the shortest reach
-- to the deck; the outboard pair drape.
KrakenPath.FIGHT_SEAT = { 2, 3 }
KrakenPath.AMBIENT_SEAT = { 1, 4 }

-- ---------------------------------------------------------------- the head

-- How far the head sinks while `Rise` is 0. The mantle stands 80 authored
-- units (480 studs) out of the water, so this is what it takes to put the
-- crown ON the waterline at Rise = 0 - a flat sea with a shadow under it -
-- rather than a head half-out that reads as a bug.
KrakenPath.SUBMERGE = KrakenPath.HEAD_TOP * KrakenPath.SCALE -- 480

-- The head faces the ship. It never turns: the arm roots are carved into the
-- mantle at fixed bearings while the limbs themselves are drawn in world
-- space to wherever the deck is, so a yawing head slides its own sockets out
-- from under the arms growing from them. The fight only ever happens on one
-- side of the animal anyway - the ship is moored off its face.
--
-- The pack faces +X and the ship lies on the head's +Z, so this is the one
-- fixed yaw that turns the eyes and the siphon at the deck.
KrakenPath.FACING_YAW = -math.pi / 2

-- THE POSE CENTRE IS THE SHIP, NOT THE HEAD, and getting this backwards is a
-- 370-stud error that only shows up once the real pack lands.
--
-- CreatureService seeds this from `creature.anchor` at the waterline
-- (`KrakenPath.newState(Vector3.new(anchor.X, World.WATER_Y, anchor.Z))`),
-- and the anchor is the BossArenas row's centre - which arena_gen puts
-- `KrakenArena_Base` on. So `state.center` is the SHIP's origin at the sea
-- surface, and the head is derived from it by the authored offset:
--
--     head = PoseCenter + HEAD_OFFSET        (0, 0, -370)
--
-- which is exactly arena-local (0, +370) in author units through the axis
-- conversion above. Every head-relative thing in this file goes through
-- KrakenPath.headCenter for that reason, and nothing reads `center` as a head
-- position. (Verified against the server: anchor -> newState at :6297,
-- capture sphere lifted off `lift` at :7038 - both waterline-relative, both
-- agreeing that the origin is the ship.)
function KrakenPath.newState(shipCenter: Vector3)
	return {
		center = shipCenter, -- the SHIP's world origin at the waterline (PoseCenter)
		ship = nil, -- cross-check from BossArenas when the row exists
		time = 0,
		rise = 0,
		siphon = 0, -- 0 = shut, 1 = open, eased off the SiphonOpen bool
		phase = 1,
	}
end

-- Where the ship is: the pose centre itself. `state.ship` is a cross-check
-- from the BossArenas row rather than a second source of truth - it is used
-- only when the pose centre has not arrived yet, since PoseCenter is
-- RE-PUBLISHED mid-fight (the swallow moves it to the gullet) and a cached
-- one would strand the rig on the sea.
function KrakenPath.shipCenter(state): Vector3
	return state.center or state.ship
end

-- Where the head is. The one derivation, so no caller can get the 370 studs
-- the wrong way round.
function KrakenPath.headCenter(state): Vector3
	return KrakenPath.shipCenter(state) + KrakenPath.HEAD_OFFSET
end

-- Ship-local -> world. The only conversion in the file.
function KrakenPath.aboard(state, local_: Vector3): Vector3
	return KrakenPath.shipCenter(state) + local_
end

-- Which deck you are standing on at a station, ship-local. Phase 1 only ever
-- sees the middle branch; phase 2 opens the castles.
function KrakenPath.deckY(x: number): number
	local ship = KrakenPath.SHIP
	if x <= ship.WAIST_MIN_X then
		return ship.QD_Y
	elseif x >= ship.WAIST_MAX_X then
		return ship.FC_Y
	end
	return ship.DECK_Y
end

-- The height a sweeping limb's CENTRELINE rides at, ship-local, so that its
-- UNDERSIDE sits on the measured sweep plane. See SHIP.SWEEP_CLEAR.
function KrakenPath.sweepCentreY(x: number, girth: number): number
	return KrakenPath.deckY(x) + KrakenPath.SHIP.SWEEP_CLEAR + girth
end

-- How far the whole animal is lifted this frame. Shared by the head and by
-- every arm root, so a rising Kraken brings its limbs up with it.
function KrakenPath.lift(state): number
	local rise = math.clamp(state.rise or 1, 0, 1)
	return -KrakenPath.SUBMERGE * (1 - rise)
end

-- THE AMBIENT BREATHE, exactly the recipe boss_gen's HANDOFF specifies: a
-- scale about the body CFrame's OWN ORIGIN (the mantle is authored about the
-- waterline, so that origin is the waterline) of 1.0 +/- 0.05 on a ~4.5s
-- sine, Z-BIASED so the head swells rather than balloons - vertical and
-- horizontal move in OPPOSITE directions, +/-0.05 against -/+0.025.
--
-- Returned as (vertical, horizontal) rather than a Vector3 so the caller can
-- apply it to a CFrame offset and to a part Size without unpacking twice.
KrakenPath.BREATHE_PERIOD = 4.5
KrakenPath.BREATHE_AMOUNT = 0.05

function KrakenPath.breathe(now: number): (number, number)
	local s = math.sin(now * (math.pi * 2 / KrakenPath.BREATHE_PERIOD))
	return 1 + KrakenPath.BREATHE_AMOUNT * s, 1 - (KrakenPath.BREATHE_AMOUNT * 0.5) * s
end

-- The Neon pulse for Kraken_Eyes and Kraken_SiphonCore: ~0.55 to ~1.0 on a
-- SLOWER ~6s sine, deliberately offset from the breathe so the two never
-- beat together and read as one machine.
--
-- Kraken_Pupil is NOT on this. The star plate is matte cream on Neon amber
-- and the star staying steady is what reads as a pupil; pulse it with the orb
-- and the eye goes back to being a lamp. The body controller enforces that by
-- name, and this function has no idea Pupil exists - which is the point.
KrakenPath.PULSE_PERIOD = 6.0
KrakenPath.PULSE_LOW = 0.55
KrakenPath.PULSE_HIGH = 1.0

function KrakenPath.eyePulse(now: number, offset: number?): number
	local s = 0.5 + 0.5 * math.sin((now + (offset or 0)) * (math.pi * 2 / KrakenPath.PULSE_PERIOD))
	return KrakenPath.PULSE_LOW + (KrakenPath.PULSE_HIGH - KrakenPath.PULSE_LOW) * s
end

-- The head's frame from EXPLICIT numbers, +X pointing where it is facing.
--
-- Split out from headCFrame so the cutscene hook and the live fight share ONE
-- arithmetic path rather than two that agree. The cutscene surface hands the
-- caller a mutable (position, rise, yaw) and the rig is written from whatever
-- comes back - so with no mutation it is this same call on the same three
-- numbers, and "the last keyframe hands off to the live fight with zero pop"
-- is a property of the code rather than of a tolerance.
function KrakenPath.headFrameAt(center: Vector3, rise: number, yaw: number): CFrame
	local at = center + Vector3.new(0, -KrakenPath.SUBMERGE * (1 - math.clamp(rise, 0, 1)), 0)
	return CFrame.new(at) * CFrame.Angles(0, yaw, 0)
end

function KrakenPath.headCFrame(state): CFrame
	return KrakenPath.headFrameAt(KrakenPath.headCenter(state), state.rise or 1, KrakenPath.FACING_YAW)
end

-- ---------------------------------------------------------------- arm roots

-- WHERE A LIMB LEAVES THE MANTLE, in authored units in the head's own frame
-- (+X is the facing, i.e. toward the ship; +Y is up; +Z is across).
--
-- Under the skirt and on the ship side, not out of the cheek: the mantle
-- closes at z = -16 and is 47 wide, so a root at x = +30 / z = -6 sits on the
-- lower forward flank with the hide still above it. The four lateral seats
-- are +/-11 and +/-33, which is 66 and 198 studs at SCALE - well inside the
-- 282-stud half-width, so no root floats off the side of the animal.
-- 36 AND NOT 30, MEASURED. The mantle is 47 authored units of half-width at
-- its widest ring, so a root at forward 30 sits 6 units INSIDE the hide: the
-- limb was born in the middle of the animal, every pose's chord lost 36 studs
-- at the near end, and the Rest drape came out 37 studs long on a limb 48
-- studs thick - a curve so short its own handles doubled it back into a cusp
-- (worst bend radius 0.9 studs, 0.04 of the bound). At 36 the root is ON the
-- hide at the root's own height and the shortest pose has a 150-stud chord.
KrakenPath.ROOT_FORWARD = 36.0
KrakenPath.ROOT_Z = -10.0
KrakenPath.ROOT_LATERAL = { -33.0, -11.0, 11.0, 33.0 }

-- The direction a limb leaves its root, as a ship-frame unit vector. THE SAME
-- FOR EVERY POSE, which is not a simplification but the thing that makes the
-- blends C1 at the weld: the root point and the first control point are pose-
-- independent, so the first derivative at t = 0 is a fixed direction whatever
-- two poses are being crossed, and a limb can never be seen tearing out of
-- its socket mid-blend.
--
-- Up and toward the ship, splayed slightly outboard by the seat's own side so
-- four limbs leaving one mantle do not start out stacked on each other.
--
-- ...EXCEPT ON THE TWO DECORATION SEATS, and that is a BUG FIX rather than a
-- flourish (2026-09-12). Those limbs hold Adrift, whose tip hangs DOWN AND BACK
-- under the far side of the crown - 176 studs behind the root in Z - while this
-- direction pointed them at the ship. So an ambient limb left its socket heading
-- one way and had to double back through itself to reach where it was going:
-- the exact hairpin this file's Withdrawn note describes, measured at 0.27 of the
-- girth bound across the Adrift blends, which is flesh passing through flesh on
-- two limbs that are on screen for the entire fight (and for the whole intro
-- cutscene, which stages them).
--
-- FIXED ON THE DEPARTURE RATHER THAN ON THE DESTINATION, deliberately, and this
-- is the whole reason it is safe: the alternative was to re-author Adrift as a
-- root-relative pose the way Withdrawn is, which measures just as well (1.98) but
-- MOVES where the ambient limbs hang - 236 studs of it - and the cutscene lane
-- stages against that silhouette. Turning the departure instead leaves every
-- ambient tip exactly where it was and only changes how the limb gets there:
-- 0.27 -> 1.89 of the bound, with the root run 60 studs under water instead of
-- 45 as a free side effect (a limb leaving downward cannot breach at all, which
-- is why archHandleMax has nothing to do on these seats).
--
-- SAFE BECAUSE THE SEATS DO NOT OVERLAP. FIGHT_SEAT is {2, 3} and AMBIENT_SEAT is
-- {1, 4}, so this branch is unreachable for any limb that carries ArmPhase - no
-- attack pose, no hitbox and no blend in the live fight can see it. The C1
-- argument in armPoint is untouched either way: what it needs is that the
-- direction is the same for every POSE at a given seat, which it still is.
local AMBIENT_ROOT = {}
for _, seat in KrakenPath.AMBIENT_SEAT do
	AMBIENT_ROOT[seat] = true
end

function KrakenPath.rootDirection(index: number): Vector3
	local lateral = KrakenPath.ROOT_LATERAL[index] or 0
	if AMBIENT_ROOT[index] then
		-- Outboard, downward and AWAY from the ship: the direction the drape is
		-- actually in. The lateral splay is four times the fight seats' because
		-- these roots are the outboard pair and the limb wants to clear the mantle
		-- on its way down the far side.
		return Vector3.new(lateral * 0.05, -0.30, -1).Unit
	end
	return Vector3.new(lateral * 0.012, 0.30, 1).Unit
end

function KrakenPath.rootPosition(state, index: number): Vector3
	local scale = KrakenPath.SCALE
	local lateral = (KrakenPath.ROOT_LATERAL[index] or 0) * scale
	-- The head faces +Z, so its authored +X (forward) is the world +Z and its
	-- authored lateral is the world X.
	return KrakenPath.headCenter(state)
		+ Vector3.new(0, KrakenPath.lift(state), 0)
		+ Vector3.new(lateral, KrakenPath.ROOT_Z * scale, KrakenPath.ROOT_FORWARD * scale)
end

-- ---------------------------------------------------------------- the curve

-- A cubic Bezier and its first two derivatives. The derivatives are here
-- because the GIRTH-AWARE BEND LAW needs them: at every u the centreline's
-- radius of curvature R = |P'|^3 / |P' x P''| must beat the limb's own drawn
-- half-thickness there, with margin, or the limb folds through itself. Having
-- them analytically is what lets the check be exact rather than a finite
-- difference that misses a narrow spike (KrakenPath's own history: an
-- exponent of 1.5 scored fine at 4000 samples and failed at 200k).
function KrakenPath.bezier(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: number): Vector3
	local s = 1 - t
	return p0 * (s * s * s) + p1 * (3 * s * s * t) + p2 * (3 * s * t * t) + p3 * (t * t * t)
end

function KrakenPath.bezierD1(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: number): Vector3
	local s = 1 - t
	return (p1 - p0) * (3 * s * s) + (p2 - p1) * (6 * s * t) + (p3 - p2) * (3 * t * t)
end

function KrakenPath.bezierD2(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: number): Vector3
	return (p2 - p1 * 2 + p0) * (6 * (1 - t)) + (p3 - p2 * 2 + p1) * (6 * t)
end

-- The drawn half-thickness at u, in studs. Must match the body controller's
-- taper exactly - it is the right-hand side of the bend law.
--
-- 0.72 IS SET BY THE BEND LAW, NOT BY TASTE, and it is the one number here
-- that buys margin everywhere at once. Almost every pose's tightest bend is in
-- the last fifth of the limb - the hook into a sweep lane, the turn onto a
-- wrap point, the tip coming down on a slam - and the bound at that u is the
-- limb's own half-thickness THERE. Measured, taking the taper from 0.60 to
-- 0.72 moves Wrapped from 0.76 of the bound to 1.08 and lifts every other pose
-- with it, at the cost of a tip drawn 6.7 studs of half-width against a 24-
-- stud shoulder. That is a properly tapering tentacle rather than a hose, and
-- it is close to the pack's own read: Kraken_TentacleTip is authored as a
-- 36-unit taper, so the last piece is already a point.
KrakenPath.TIP_GIRTH = 0.72

function KrakenPath.girthAt(u: number): number
	return KrakenPath.GIRTH * (1 - KrakenPath.TIP_GIRTH * math.clamp(u, 0, 1))
end

-- Radius of curvature of the control polygon's curve at t. Infinite (returned
-- as math.huge) on a straight run, which passes any bound.
function KrakenPath.bendRadius(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: number): number
	local d1 = KrakenPath.bezierD1(p0, p1, p2, p3, t)
	local d2 = KrakenPath.bezierD2(p0, p1, p2, p3, t)
	local cross = d1:Cross(d2).Magnitude
	if cross < 1e-9 then
		return math.huge
	end
	return (d1.Magnitude ^ 3) / cross
end

-- ---------------------------------------------------------------- easing

-- SMOOTHERSTEP, 6t^5 - 15t^4 + 10t^3. Zero FIRST AND SECOND derivative at
-- both ends, where smoothstep only zeroes the first. Used for every blend
-- weight and every within-phase progress in this file, because a phase change
-- is a crossfade between two moving curves and it is the second derivative
-- that shows up as a visible flick in a limb 1200 studs long.
function KrakenPath.smoother(t: number): number
	local x = math.clamp(t, 0, 1)
	return x * x * x * (x * (x * 6 - 15) + 10)
end

-- ---------------------------------------------------------------- the poses
--
-- One entry per ArmPhase the server publishes. Each returns the FOUR control
-- points of that phase's curve, in world space, for a given within-phase
-- progress `t` (the arm's ArmT). p0 and p1 are supplied by the caller and are
-- pose-independent (see rootDirection); a pose chooses only where the limb
-- ENDS and how it arrives there.
--
-- The shape of the entry is (endPoint, arriveDirection, handleLength): the
-- limb's tangent at the tip is `arrive`, so p2 = end - arrive * handle.
-- Writing a pose as "where it lands and which way it is pointing when it
-- gets there" is what keeps two poses blendable - lerping an end point and a
-- direction is meaningful in a way that lerping four raw control points is
-- not.

local POSE = {}
KrakenPath.POSE = POSE

-- How much of the chord the root handle takes. 0.42 is measured, not chosen:
-- see the verification note on armPoint - it is the largest value that keeps
-- every pose's worst bend radius above the girth bound, and dropping it
-- straightens the limb into a wire.
KrakenPath.HANDLE_ROOT = 0.55

-- Where a reared limb's tip hangs before it comes down: 260 studs over the
-- deck. The head is 480 studs tall, so this is a limb held at about half the
-- animal's own height - high enough to read as ABOVE you from the deck at a
-- 60-stud camera, low enough to stay in a 70-degree frame with the planking.
KrakenPath.REAR_LIFT = 260.0

-- ------------------------------------------------- THE ROOT-IN-WATER LAW
--
-- A TENTACLE IS NEVER SEEN TO BEGIN. Every limb in this file leaves its socket
-- UNDER THE SEA and ARCHES up through the surface somewhere out in the open
-- water between the mantle and the port rail - so at every instant, in every
-- phase and in every blend between two phases, the bottom of the limb is
-- submerged and its crossing of the waterline is a curve rather than a join.
-- The failure this exists to make impossible is a limb that reads as DETACHED:
-- a span of flesh hanging in air with nothing under it, which is what you get
-- the moment the first stretch of the curve comes out of the water early.
--
-- WHY IT IS A PROPERTY OF THE CODE AND NOT OF A MEASUREMENT. The drawn curve is
-- a cubic Bezier and a phase change is a LERP OF ITS FOUR CONTROL POINTS (see
-- the header). A Bezier's first control points dominate its start exactly: the
-- curve begins at P0 and leaves along P1 - P0, and both of those lerp
-- componentwise. So if P0 and P1 are below the waterline for every AUTHORED
-- phase, they are below it for every blend of any two of them, automatically
-- and with no per-blend check. Two pins do it:
--
--   P0 - the socket, and it needs no work: rootPosition puts it at the arm's
--        real authored bearing and radius on the mantle, ROOT_Z = -10 authored
--        units = 60 studs UNDER the surface, and `lift` only ever takes it
--        deeper (a Kraken that has not finished rising is further under).
--   P1 - the root handle, p0 + rootDirection * (chord * HANDLE_ROOT), and this
--        one CAN breach, because the handle's LENGTH scales with the pose's
--        chord while its direction is fixed. Rear's chord is 369 studs, so its
--        handle is 203 and its 0.285 of vertical carries P1 to 2 studs ABOVE
--        the sea - the limb leaves its socket aimed at the sky and the arch
--        becomes a pole. So the length is CAPPED at whatever keeps P1 at least
--        ARCH_DEPTH studs under: see `controls`.
--
-- ARCH_DEPTH is 12 studs, which is half a shoulder's half-girth (GIRTH 24): at
-- that depth the limb's own flesh still spans the surface at P1 rather than
-- grazing it, and the cap costs nothing anywhere it does not bind - measured,
-- the only pose whose chord is long enough to reach it is Rear.
--
-- THE WATERLINE IS Y = 0 IN SHIP-LOCAL TERMS and that is not a convention, it
-- is where the server put the pose centre: CreatureService seeds the pose with
-- `KrakenPath.newState(Vector3.new(anchor.X, World.WATER_Y, anchor.Z))`. So
-- shipCenter().Y IS the sea surface, every ship-local Y in this file is studs
-- above it, and `surfaceY` is the one name anything asks through.
KrakenPath.ARCH_DEPTH = 12.0

-- The sea surface in world Y. One derivation, so no pose can disagree with the
-- cap about where the water is.
function KrakenPath.surfaceY(state): number
	return KrakenPath.shipCenter(state).Y
end

-- How long the root handle may be before P1 breaches. The direction is fixed
-- (rootDirection), so this is pure trigonometry: a handle of length L rises
-- L * dir.Y, and the socket has `depth` studs of water over it.
--
-- Returned as a length rather than applied to a point, so the ONE place that
-- builds the control polygon does the clamp and nothing else has to remember.
function KrakenPath.archHandleMax(state, index: number): number
	local rise = KrakenPath.rootDirection(index).Y
	if rise <= 1e-4 then
		return math.huge -- a horizontal departure can never breach
	end
	local depth = KrakenPath.surfaceY(state) - KrakenPath.rootPosition(state, index).Y
	return math.max(depth - KrakenPath.ARCH_DEPTH, 0) / rise
end

-- How far the tip sits above the deck when it has landed on it. Its own
-- girth, so the limb RESTS on the planking rather than intersecting it.
local function deckContact(u: number): number
	return KrakenPath.girthAt(u)
end

-- REST - draped into the sea beside the ship. The tip floats between the head
-- and the port rail, below the surface; nothing about this pose touches the
-- deck, and it is the only pose a limb holds while the fight is not asking
-- anything of it.
POSE.Rest = function(state, arm, _t: number)
	local lateral = (KrakenPath.ROOT_LATERAL[arm.index] or 0) * KrakenPath.SCALE
	local at = KrakenPath.aboard(state, Vector3.new(lateral * 0.8, -150, -60))
	return at, Vector3.new(0.08, -1.2, 1).Unit, 0.30
end

-- ADRIFT - the two DECORATION limbs, and the only pose they ever hold. Same
-- family as Rest but seated outboard and turned away, so an ambient limb
-- drapes down the far side of the crown and its tip never comes within 100
-- studs of a rail. Nothing aims it and nothing hits it.
POSE.Adrift = function(state, arm, _t: number)
	local lateral = (KrakenPath.ROOT_LATERAL[arm.index] or 0) * KrakenPath.SCALE
	local at = KrakenPath.headCenter(state)
		+ Vector3.new(0, KrakenPath.lift(state), 0)
		+ Vector3.new(lateral * 1.9, -230, 40)
	return at, Vector3.new(0.10, -1.4, 1).Unit, 0.30
end

-- REAR - THE HAUL, and it is the fight's single most important second.
--
-- It used to be a STATIC pose: the apex, returned for every ArmT, which meant
-- the entire rise from the sea to 260 studs over the deck happened inside the
-- 0.55-second CROSSFADE and the remaining second of windup was a limb hanging
-- motionless in the air. That is the snap the owner asked to be rid of, and it
-- was also the fight's readability problem - a player saw a tentacle appear
-- overhead, not a tentacle coming.
--
-- So Rear is now a MOVE, driven by ArmT over the whole windup (the server hands
-- the row's `windup` straight to `arm.phaseFor`, and that is now ~2.4s for a
-- pile slam): the tip starts GATHERED just under the surface a little outboard
-- of the port rail, over the half-way mark toward its target, and climbs to the
-- apex on a smootherstep. What you see from the deck is the sea breaking, a
-- limb rising out of it, and an arch standing up over the planking that is
-- plainly about to come down - two and a half seconds of it.
--
-- THE TWO SEAMS IT STILL HAS TO HOLD:
--   * at ArmT 1 it is the apex EXACTLY, which is where POSE.Slam starts - so
--     Rear -> Slam opens on two curves that already agree, as before.
--   * at ArmT 0 it is a point just under the water, which is the same family as
--     Rest's drape - so Rest -> Rear no longer crossfades across 400 studs of
--     vertical, and the transition that reads worst in the whole book reads
--     worst only at the END of the haul now instead of at its start.
--
-- The arrive direction is swept with it, from RISING (the limb climbing out of
-- the sea, so the flesh below the tip is below the tip) to the old onward-and-
-- slightly-down crest at the apex. 0.55 - 0.65 * ease lands exactly on the old
-- -0.10 at ease = 1, which is what keeps the Slam seam bit-identical.
KrakenPath.REAR_GATHER_PULL = 0.5 -- how far along X toward the target it gathers
KrakenPath.REAR_GATHER_Y = -16.0 -- ship-local: under the surface
KrakenPath.REAR_GATHER_Z = -40.0 -- ...and 21 studs outboard of the port rail
POSE.Rear = function(state, arm, t: number)
	local target = arm.target or KrakenPath.aboard(state, Vector3.new(0, KrakenPath.SHIP.DECK_Y, 0))
	local apex = target + Vector3.new(0, KrakenPath.REAR_LIFT, 0)
	local ease = KrakenPath.smoother(t)
	local gather = KrakenPath.aboard(
		state,
		Vector3.new(
			(target.X - KrakenPath.shipCenter(state).X) * KrakenPath.REAR_GATHER_PULL,
			KrakenPath.REAR_GATHER_Y,
			KrakenPath.REAR_GATHER_Z
		)
	)
	-- Arriving downward and slightly onward at the apex, so the limb rises to it
	-- from behind rather than hooking back over itself; arriving UPWARD at the
	-- gather, because a limb coming out of the sea is travelling up.
	return gather:Lerp(apex, ease), Vector3.new(0, 0.55 - 0.65 * ease, 1).Unit, 0.30 + 0.12 * ease
end

-- SLAM - crashed onto the deck disc. ArmT drives the fall from the reared
-- apex to the planking on a smootherstep, so the tip leaves the apex with
-- zero velocity (matching a Rear that was holding still) and arrives with the
-- fall's full speed.
POSE.Slam = function(state, arm, t: number)
	local target = arm.target or KrakenPath.aboard(state, Vector3.new(0, KrakenPath.SHIP.DECK_Y, 0))
	local landed = target + Vector3.new(0, deckContact(1), 0)
	local apex = target + Vector3.new(0, KrakenPath.REAR_LIFT, 0)
	local at = apex:Lerp(landed, KrakenPath.smoother(t))
	return at, Vector3.new(0, -0.35, 1).Unit, 0.30
end

-- SWEEPCOCK - THE DRAW, and the same change as Rear for the same reason: it was
-- a static pose and the whole cocking motion happened inside a half-second
-- crossfade, leaving the rest of a 2.6-second windup as a limb parked in the
-- air at knee height with nothing to read but the lane strip under it.
--
-- Now the tip comes up OUT OF THE WATER at the lane's far end: gathered under
-- the surface outboard of the port rail at ArmT 0, levelling onto the sweep
-- plane at its own end of the lane by ArmT 1. So the telegraph is the lane strip
-- AND a limb visibly drawing back along it, and the swing that follows starts
-- from exactly where the draw finished.
--
-- THE SEAM: at ArmT 1 the position is the cocked point and the arrive direction
-- is sweepArrive(sign) EXACTLY - which is POSE.Sweep at its own ArmT 0 - so the
-- SweepCock -> Sweep transition still opens on two agreeing curves.
--
-- WHERE IT GATHERS IS THE BEND LAW'S NUMBER, and it is the one that cost the
-- most measuring. The gather has to be far enough outboard to be IN THE WATER
-- and no further, because pulling it out to sea drives it toward the limb's own
-- root - the root sits at ship-local z = -154, so a gather at -140 is almost on
-- top of it and the limb has to hairpin to get from one to the other. Measured,
-- over the full sweep (all four drift phases, nine aims, both fight seats):
--
--     gather Z    -20     -30     -40     -50     -60    -100    -140
--     bend/bound  1.62    1.48    1.34    1.20    1.06    0.59    0.08
--
-- which is the Withdrawn lesson (see its own note) appearing a second time in a
-- different pose. -30 is 11 studs outboard of the port bulwark: the limb surfaces
-- hard alongside the hull, which is also the best READ of the three - you see it
-- come up beside the ship rather than somewhere out in the dark - and it keeps
-- 1.48 of the bound against the old static pose's 1.80.
--
-- COCK_HANDLE 0.50 is part of the same measurement: gathering the tip off the
-- lane shortens the chord, and a longer tip handle pushes the second control
-- point back down the limb and turns the hook into a lean. Same argument, and the
-- same fix, as sweepArrive's own note.
KrakenPath.COCK_GATHER_Y = -16.0 -- ship-local: under the surface
KrakenPath.COCK_GATHER_Z = -30.0 -- ...and 11 studs outboard of the port rail
KrakenPath.COCK_RISE_TILT = 0.30 -- how much UP is added to the arrive at ArmT 0
KrakenPath.COCK_HANDLE = 0.50
POSE.SweepCock = function(state, arm, t: number)
	local fromX, toX, z = KrakenPath.lane(arm)
	local y = KrakenPath.sweepCentreY(fromX, KrakenPath.girthAt(1))
	local sign = if toX >= fromX then 1 else -1
	local ease = KrakenPath.smoother(t)
	local cocked = KrakenPath.aboard(state, Vector3.new(fromX, y, z))
	local gather = KrakenPath.aboard(state, Vector3.new(fromX, KrakenPath.COCK_GATHER_Y, z + KrakenPath.COCK_GATHER_Z))
	local arrive = (KrakenPath.sweepArrive(sign) + Vector3.new(0, KrakenPath.COCK_RISE_TILT * (1 - ease), 0)).Unit
	return gather:Lerp(cocked, ease), arrive, KrakenPath.COCK_HANDLE
end

-- SWEEP - the scythe. The tip travels the lane on a smootherstep of ArmT,
-- which is what makes the swing accelerate out of the cock and decelerate
-- into whatever follows instead of starting and stopping at full speed.
POSE.Sweep = function(state, arm, t: number)
	local fromX, toX, z = KrakenPath.lane(arm)
	local x = fromX + (toX - fromX) * KrakenPath.smoother(t)
	local y = KrakenPath.sweepCentreY(x, KrakenPath.girthAt(1))
	local sign = if toX >= fromX then 1 else -1
	return KrakenPath.aboard(state, Vector3.new(x, y, z)), KrakenPath.sweepArrive(sign), 0.42
end

-- WRAPPED - coiled onto its wrap point's rail coordinates. The Bezier lands
-- the limb ON the rail line; the COIL itself is an added helix over the last
-- third of the body (see armPoint), because a single cubic cannot turn twice
-- and a curve that tries is exactly the fold the bend law forbids.
-- THE ONE POSE IN THE BOOK THAT BROKE THE ROOT-IN-WATER LAW, and it is worth
-- saying exactly how, because the fix is not where the symptom was.
--
-- Measured (archcheck.py, all four wrap points, both fight seats): Wrapped came
-- out of the sea 3.7 studs ABOVE the waterline inside the first 15% of its own
-- arc length - the only pose in the set that did, and the source of the
-- "detached limb" read. The cause was the ARRIVE DIRECTION, not the curve's
-- start: the limb was authored as arriving DOWNWARD onto the rail (-0.55 of
-- vertical), which throws the second control point 48 studs ABOVE the wrap
-- point - 82 studs over the sea - and a cubic pulled that hard upward at its far
-- end leaves the water almost as soon as it leaves the socket.
--
-- THE TRAP IS THAT THE TWO LAWS BIND IN DIFFERENT PLACES, so the obvious knob is
-- the wrong one. The ARCH fails in the MIDDLE of the limb (u ~ 0.34); the BEND
-- binds at its very TIP (u ~ 0.97), inside the coil. Flattening the arrive
-- direction fixes the middle and wrecks the tip - measured, -0.55 -> -0.35 takes
-- the arch from -8.8 studs to +4.3 and the bend from 1.11 to 0.74, and levelling
-- it entirely (so the limb climbs over the bulwark from underneath, which is what
-- a wrap physically is) collapses the tangent's magnitude at the tip and scores
-- 0.38. The angle is not the lever.
--
-- THE LEVER IS THE TIP HANDLE, because it moves the middle without moving the
-- tip's geometry: p2 = at - arrive * (chord * handle), so with a downward arrive a
-- SHORTER handle pulls the second control point DOWN - from 82 studs over the sea
-- at 0.45 to 61 at 0.32 - and the mid-limb comes down with it while the tip's own
-- turn is left alone. 0.32 with the arrive only gently eased to -0.50 measures
-- arch +4.2 / bend 1.18, and it is a PLATEAU rather than a spike: every arrive
-- angle from -0.46 to -0.54 at this handle measures between 1.12 and 1.18, which
-- is what makes it safe to hold. (The first pass of this edit picked a
-- neighbouring spike that measured 1.24 on a one-drift-phase sample and 0.69 on
-- the full one. Sample all four drift phases.)
--
-- WRAPPED IS STILL THE BINDING CASE FOR THE ARCH at 4.2 studs of submersion, and
-- that is the honest answer rather than a number that wanted more tuning: a limb
-- that has to reach a rail 34 studs above the sea and then hook around a hull has
-- less room than anything else in the book. It was -8.8 - out of the water - so
-- this is the pose the invariant was actually written for.
POSE.Wrapped = function(state, arm, _t: number)
	local wrap = KrakenPath.WRAPS[arm.wrap] or KrakenPath.WRAPS[1]
	local at = KrakenPath.aboard(state, wrap + Vector3.new(0, KrakenPath.WRAP_LIFT, 0))
	-- Arriving along the rail, so the coil has a direction to turn about, and
	-- only gently downward onto it, so the limb reaches the bulwark out of the
	-- water rather than down out of the sky.
	local along = if wrap.X >= 0 then -1 else 1
	return at, Vector3.new(along * 0.45, -0.50, if wrap.Z < 0 then 0.70 else -0.70).Unit, 0.32
end

-- THE COIL, and all three numbers are the bend law's rather than the look's.
--
-- A helix of radius R and pitch p has curvature radius (R^2 + (p/2pi)^2) / R,
-- which is >= R and grows as the coil is SPREAD OUT. That is the whole story
-- of how these numbers moved. The first pass wound 1.25 turns of a 70-stud
-- coil over the last third of the limb and measured 0.25 of the girth bound -
-- flesh through flesh, twice - and neither the radius, the handle nor the
-- onset rescued it, because the binding term is the coil's own pitch and none
-- of those change it. Spreading the SAME winding over 70% of the limb and
-- taking it down to 0.30 of a turn on a 150-stud radius measures 1.96.
--
-- So the wrap is a broad HOOK, not a tight coil: the limb comes over the rail,
-- sweeps around the outside of the hull and back up under itself. That is what
-- a limb 48 studs thick can do to a ship 38 studs across, and pretending
-- otherwise is what the 0.25 was. The read is carried by the wrap point's own
-- reinforcement mark and the boarding gap cut in the bulwark for it - the
-- arena builds both - rather than by the number of times the limb goes round.
KrakenPath.WRAP_LIFT = 26.0
KrakenPath.WRAP_RADIUS = 150.0
-- 0.60 OF A TURN, and it moved from 1.25 because the bend law said so. A full
-- coil is what a wrap "should" look like and it is not what a limb 48 studs
-- thick can do around a 38-stud beam: at 1.25 turns the pose measured 0.25 of
-- the girth bound - the flesh passing through itself twice - and no radius,
-- handle or onset rescued it. At 0.60 the limb comes over the rail, round the
-- outside of the bulwark and back up under itself, which is a HOOK rather than
-- a coil, and it clears. The read survives because the wrap point's own
-- reinforcement mark and the boarding gap are what say "it is holding on
-- here"; the extra 234 degrees only ever said it more expensively.
--
-- 0.24 OF A TURN NOW, and WRAP_FROM DELIBERATELY DID NOT MOVE (2026-09-12). The
-- coil is where most of a wrapped limb's ARC LENGTH lives, so starting it LATER
-- looked like free margin for the root-in-water law: it leaves a longer run from
-- the sea to the rail and therefore a bigger submerged fraction. It is not free.
-- The curvature radius of a helix grows as the coil is SPREAD OUT (the formula
-- three paragraphs up), so compressing the same winding into the last 62% of the
-- limb instead of the last 70% tightens it everywhere - measured, FROM 0.38 cost
-- the tip 0.4 of the bound. So the coil stays spread and only the WINDING comes
-- off: a sixth less of it, which the read does not notice (the wrap point's own
-- reinforcement mark and the boarding gap are what say "it is holding on here")
-- and which the arch law does.
KrakenPath.WRAP_TURNS = 0.24
KrakenPath.WRAP_FROM = 0.30 -- where along the limb the coil starts

-- DOWN - limp across the deck, suckers up. The limb comes over the near rail
-- and lies across the waist; the body controller rolls the sucker rows to the
-- top for this pose, which is the whole read (a limb showing its underside is
-- a limb that has stopped working).
POSE.Down = function(state, arm, _t: number)
	local x = if arm.target then (arm.target - KrakenPath.shipCenter(state)).X else 0
	x = math.clamp(x, KrakenPath.SHIP.WAIST_MIN_X + 8, KrakenPath.SHIP.WAIST_MAX_X - 8)
	local y = KrakenPath.deckY(x) + deckContact(1)
	return KrakenPath.aboard(state, Vector3.new(x, y, KrakenPath.SHIP.RAIL_STBD_Z - 4)),
		Vector3.new(0.30, -0.10, 1).Unit,
		0.30
end

-- WITHDRAWN - pulled back toward the head, underwater. The shortest curve in
-- the set, and the one a limb holds while it is not in the fight at all.
-- WITHDRAWN is ROOT-RELATIVE, and that is the whole of why it works. Written
-- as an absolute point under the head it lands BEHIND the root in Z, and the
-- limb - whose departure direction is pinned toward the ship - has to double
-- back through itself to reach it: a hairpin at 0.01 of the bend bound, the
-- worst number this file ever measured. Hung off the root instead, it is a
-- quarter turn down into the water off the head's own face.
POSE.Withdrawn = function(state, arm, _t: number)
	local lateral = (KrakenPath.ROOT_LATERAL[arm.index] or 0) * KrakenPath.SCALE
	local at = KrakenPath.rootPosition(state, arm.index) + Vector3.new(lateral * 0.2, -100, 210)
	return at, Vector3.new(0.05, -1.8, 1).Unit, 0.30
end

-- ================================================ THE SIX NEW POSES (2026-09-12)
--
-- THE OWNER'S ASK: "more unique attacks and more openings to hit the boss." Four
-- new moves and two modified ones need six shapes this book did not have, and
-- every one of them is here rather than faked out of an existing pose because
-- the existing poses are the wrong SIZE, not the wrong angle:
--
--   SpearCock / Spear  a stab is an 84-stud jab, not Rear's 260-stud haul. Three
--                      of them land inside 2.1 seconds; three reared plunges in
--                      that time is not a readable attack, it is a blur.
--   Stuck              a tip THROUGH the planking is below the deck, which no
--                      pose in the old book ever was - Down lies ON it.
--   Drape              over the bulwark with the tip hanging outboard in the sea.
--                      Down's tip is across the waist on the FAR rail; this one
--                      is the spent-limb read on the NEAR one, and it is the
--                      opening for two different moves.
--   Coil               fully submerged and TRACKING the target's station. Rest is
--                      submerged but fixed to the seat; Withdrawn is submerged
--                      but root-relative. Neither follows anybody.
--   Erupt              a vertical column out of the water at the target. Rear
--                      gathers outboard of the port rail and crests over the
--                      deck; this comes up where the player is standing.
--
-- ALL SIX OBEY THE TWO LAWS ON THE SAME TERMS AS THE REST OF THE BOOK, and the
-- measured table is in the verification note at the bottom of this file. None of
-- them needed a new mechanism: each is an (endPoint, arriveDirection, handle)
-- triple like every other entry, so the affine blend argument at ARCH_DEPTH
-- covers their crossfades for free.

-- THE GRATING SPEAR's two halves. The tip rises out of the sea over the windup
-- (SpearCock, a haul in the Rear/SweepCock family) and then JABS (Spear), and
-- the two are re-issued alternately - cock, stab, cock, stab, cock, stab - with
-- a fresh target each time, which is what walks the three marks down the deck.
--
-- 84 STUDS OF LIFT, AND IT IS THE WHOLE DIFFERENCE between this and a pile slam.
-- REAR_LIFT is 260: a limb held at half the animal's own height, which reads as
-- "that is going to flatten the deck". A spear is a limb cocked at shoulder
-- height over one man's worth of planking, and the read has to be "that is going
-- to go through ME" - so it is a third of the distance and it closes in 0.3s
-- instead of 0.45.
--
-- THE SEAM IS EXACT, the same way Rear -> Slam is: SpearCock at ArmT 1 returns
-- the poised point, the poised arrive and SPEAR_HANDLE, and POSE.Spear at ArmT 0
-- returns the same three values by construction. So every one of the three stabs
-- opens on two curves that already agree, and only the GATHER (the first cock,
-- out of Rest) is a real crossfade.
KrakenPath.SPEAR_LIFT = 84.0
KrakenPath.SPEAR_GATHER_Y = -18.0 -- ship-local: under the surface
KrakenPath.SPEAR_GATHER_Z = -34.0 -- ...and 15 studs outboard of the port rail
KrakenPath.SPEAR_GATHER_PULL = 0.6 -- how far along X toward the mark it gathers
KrakenPath.SPEAR_HANDLE = 0.42
-- THE POISED TIP'S ARRIVE DIRECTION, and it is sweepArrive's lesson for the
-- third time in this file: THE TANGENT IS NOT THE READ.
--
-- A spear "should" point straight down, and the first draft of this pose said so
-- - (0, -0.90, 0.55), steeply down and a little onward. Measured, that is a
-- HAIRPIN and it scored 0.56 of the girth bound at u = 0.83, which is flesh
-- through flesh on an attack that fires three times a cast. The cause is
-- structural rather than tuneable: the limb arrives from 154 studs to port and
-- 60 studs under, so it is RISING when it gets there, and a tip tangent that
-- points hard down forces the control polygon to reverse at p2. (The diagnostic
-- is |P'| collapsing to a fifth of its neighbours - a near-cusp, not a tight
-- curve.) The handle is not the lever: every length from 0.10 to 0.50 is
-- monotone in it and none of them reaches 0.80.
--
-- So the tangent eases off and the STAB carries the read, which it does perfectly
-- well because the thing a player watches is the tip's MOTION down the 84 studs
-- onto their mark and the segments stacking up behind it - not the derivative at
-- the very end of a limb 1200 studs long. Measured over the whole sweep:
--
--     arrive y     -0.90   -0.55   -0.30
--     bend/bound    0.61    1.41    1.97
--
-- -0.30 on 0.90 of onward is also within a whisker of POSE.Slam's own (0, -0.35,
-- 1), which is the same motion at three times the scale - so the two blows in
-- this book that come down on a deck now agree about how a limb comes down on a
-- deck, which they did not before.
KrakenPath.SPEAR_ARRIVE = Vector3.new(0, -0.30, 0.90)
-- How far THROUGH the planking the stuck tip sits. Deeper than the tip's own
-- drawn half-girth (6.7 studs at u = 1), so what you see is flesh entering the
-- deck rather than a point resting on it - which is the whole read of the
-- four-second opening this pose exists for.
KrakenPath.STUCK_DEPTH = 12.0

POSE.SpearCock = function(state, arm, t: number)
	local target = arm.target or KrakenPath.aboard(state, Vector3.new(0, KrakenPath.SHIP.DECK_Y, 0))
	local poised = target + Vector3.new(0, KrakenPath.SPEAR_LIFT, 0)
	local ease = KrakenPath.smoother(t)
	local gather = KrakenPath.aboard(
		state,
		Vector3.new(
			(target.X - KrakenPath.shipCenter(state).X) * KrakenPath.SPEAR_GATHER_PULL,
			KrakenPath.SPEAR_GATHER_Y,
			KrakenPath.SPEAR_GATHER_Z
		)
	)
	-- Rising out of the sea at the gather, cocked and tipped down at the poise.
	-- 0.55 - 0.85 * ease lands on SPEAR_ARRIVE's own -0.30 at ease 1, and the Z
	-- component is SPEAR_ARRIVE's too - which is what keeps the Spear seam
	-- bit-identical and therefore makes all three stabs a re-issue rather than a
	-- crossfade.
	return gather:Lerp(poised, ease),
		Vector3.new(0, 0.55 - 0.85 * ease, KrakenPath.SPEAR_ARRIVE.Z).Unit,
		KrakenPath.SPEAR_HANDLE
end

POSE.Spear = function(state, arm, t: number)
	local target = arm.target or KrakenPath.aboard(state, Vector3.new(0, KrakenPath.SHIP.DECK_Y, 0))
	local poised = target + Vector3.new(0, KrakenPath.SPEAR_LIFT, 0)
	local landed = target + Vector3.new(0, deckContact(1), 0)
	return poised:Lerp(landed, KrakenPath.smoother(t)), KrakenPath.SPEAR_ARRIVE.Unit, KrakenPath.SPEAR_HANDLE
end

-- STUCK - the tip driven through the deck and held there. The built-in opening
-- of the grating spear: the limb cannot pull out for four seconds and the server
-- lights the tip for the same 3x a Down knuckle takes.
--
-- Held, not driven: ArmT is ignored on purpose. A tip buried in the planking that
-- kept moving would be the one thing worse than no opening - a hitbox a player is
-- shooting that slides out from under their aim for no reason they can see.
POSE.Stuck = function(state, arm, _t: number)
	local target = arm.target or KrakenPath.aboard(state, Vector3.new(0, KrakenPath.SHIP.DECK_Y, 0))
	return target - Vector3.new(0, KrakenPath.STUCK_DEPTH, 0), KrakenPath.SPEAR_ARRIVE.Unit, KrakenPath.SPEAR_HANDLE
end

-- DRAPE - SPENT OVER THE NEAR BULWARK, and it is the most used of the six: it is
-- the opening for the sucker volley, the opening the deck scythe now drags to a
-- stop in, and it would be the obvious one for anything else in this fight that
-- wants to say "that limb has nothing left in it" without saying "that limb is
-- broken" (which is Down's job, and Down is across the waist on the FAR rail).
--
-- IT IS DOWN'S MIRROR ON THE NEAR RAIL, and saying so is more useful than
-- pretending it is a new idea: Down comes over the port bulwark and lies all the
-- way ACROSS the 38-stud beam with its tip over the far rail (RAIL_STBD_Z - 4);
-- Drape comes over the same bulwark and STOPS, with its tip resting on the
-- planking eleven studs inboard of it. Same family, same suckers-up roll, and a
-- plainly different silhouette from the deck: one limb has fallen across your
-- ship, the other has run out of strength on its edge.
--
-- WHAT IT IS *NOT*, and this is the draft that had to be thrown away. The obvious
-- reading of "draped over the bulwark" is a limb whose tip hangs back DOWN THE
-- OUTBOARD SIDE into the sea, and that is what the first version authored -
-- (x, -30, -44) with the tip arriving down and outboard. It measured 0.12 OF THE
-- GIRTH BOUND, the worst number in this file since Withdrawn's absolute-point
-- hairpin, and for exactly Withdrawn's reason: a limb that has travelled 110
-- studs INBOARD to get over the rail and then has to turn round and go back out
-- again reverses its own control polygon, and the curve near-cusps at u = 0.82.
-- The handle does not rescue it (0.02 at 0.08, 0.12 at 0.40 - monotone and never
-- close). Taking the reversal out of Z is what rescues it, 0.12 -> 2.38, and the
-- cost is only that the tip lies on the deck instead of in the water. That is the
-- better read anyway: the hot forearm is then ON the bulwark at a range a player
-- standing in the waist can reach, which is the whole reason the pose exists.
KrakenPath.DRAPE_Z = -8.0 -- ship-local: eleven studs inboard of the port bulwark
KrakenPath.DRAPE_HANDLE = 0.42
POSE.Drape = function(state, arm, _t: number)
	local x = if arm.target then (arm.target - KrakenPath.shipCenter(state)).X else 0
	x = math.clamp(x, KrakenPath.SHIP.WAIST_MIN_X + 8, KrakenPath.SHIP.WAIST_MAX_X - 8)
	-- Deck-relative, so the castles need no special case: the limb rests ON
	-- whatever floor its station is, by its own drawn half-girth there.
	local y = KrakenPath.deckY(x) + deckContact(1)
	local at = KrakenPath.aboard(state, Vector3.new(x, y, KrakenPath.DRAPE_Z))
	return at, Vector3.new(0.10, -0.22, 1).Unit, KrakenPath.DRAPE_HANDLE
end

-- COIL - FULLY UNDER THE SEA AND FOLLOWING YOU, the maelstrom coil's three
-- seconds of bait. There is nothing to see but a wake and a moving glow (the
-- body controller's "wake" deck mark, drawn on the WATER off the same TargetX /
-- TargetZ this pose reads), and that is the attack: you are being tracked and
-- the only information you are given is where.
--
-- WHY IT IS A NEW POSE AND NOT Withdrawn-plus-a-target. Withdrawn is ROOT-
-- relative by necessity (see its own note) and ignores `arm.target` entirely, so
-- a limb in it cannot follow anything; Rest is submerged but pinned to the seat.
-- The contract already carries TargetX / TargetZ every frame, so the tracking
-- costs nothing new on the wire - what was missing was a shape that reads them.
--
-- THE TIP CIRCLES OUTBOARD OF THE TARGET, NOT UNDER IT, and that is a hull
-- problem rather than a style choice: the target is a station on the DECK, z
-- within +/-12 of the centreline, and a tip at that z and 70 studs down is inside
-- the authored hull below its own waterline. 46 studs outboard puts it in open
-- water alongside, which is also the better read - the wake runs up the port side
-- and then the thing comes up inboard of it.
KrakenPath.COIL_DEPTH = 70.0
KrakenPath.COIL_OUT = 46.0
KrakenPath.COIL_HANDLE = 0.30

-- Where the submerged tip rides for a given aim. Shared by Coil and by Erupt's
-- own ArmT 0, so the eruption starts EXACTLY where the circling ended and the
-- one transition the move makes is a change of direction rather than of place.
local function coilStation(state, arm): Vector3
	local ship = KrakenPath.shipCenter(state)
	local tx = if arm.target then (arm.target - ship).X else 0
	local tz = if arm.target then (arm.target - ship).Z else 0
	return KrakenPath.aboard(state, Vector3.new(tx, -KrakenPath.COIL_DEPTH, tz - KrakenPath.COIL_OUT))
end

POSE.Coil = function(state, arm, _t: number)
	return coilStation(state, arm), KrakenPath.COIL_ARRIVE.Unit, KrakenPath.COIL_HANDLE
end

-- ERUPT - THE COLUMN. Straight up out of the water at the target's station and
-- crested over it, driven by ArmT over the whole strike so the column RISES
-- rather than appearing.
--
-- THE ARRIVE IS SWEPT ALL THE WAY FROM COIL'S OWN DIRECTION, and that is the fix
-- for the worst number this pass measured. Two separate mistakes, both found by
-- sampling ArmT rather than only the end of the run:
--
--   (1) WHERE IT ENDS UP. The first draft leaned the crest INBOARD (0.18 -> 0.60
--       of onward), on the reasoning that a column bursting out of the water
--       should curl over the deck it is about to hit. But the limb BELOW the crest
--       is outboard of it - the coil station is 46 studs to port of the target -
--       so a tip tangent pointing inboard reverses the control polygon in Z,
--       exactly as the first Drape reversed it, and the curve near-cusps at u =
--       0.87. Leaning the crest BACK toward the sea instead makes the whole column
--       one monotone arc. It is also what 1200 studs of tentacle standing on end
--       would do: the weight is behind it.
--   (2) WHERE IT STARTS. Sweeping the arrive from VERTICAL at ArmT 0 was worse
--       still, and this is the one a single-ArmT sample cannot see: at ArmT 0 the
--       limb has not erupted yet, it is still lying under the sea 70 studs down,
--       and a vertical tip tangent there throws p2 46 studs BELOW the tip while p1
--       is 28 studs above it. Another reversal, and it held the pose at 0.41 of
--       the bound after (1) was fixed - i.e. the fix looked like it had worked,
--       because at ArmT 1 it measured 7.04.
--
-- So the arrive starts as COIL's arrive EXACTLY and rotates to the crest's over
-- the run, and the handle is swept with it from COIL_HANDLE to ERUPT_HANDLE. That
-- makes the Coil -> Erupt transition a seam rather than a crossfade - at ArmT 0
-- this pose IS Coil, in all four returned values - and it is the same device
-- Rear -> Slam and SweepCock -> Spear use.
--
-- An upward arrive at the crest also buys the arch law a great deal for free: it
-- puts p2 BELOW the tip, i.e. deeper, which is the exact opposite of Wrapped's
-- problem and the reason this is the best-measuring pose in the book.
KrakenPath.ERUPT_LIFT = 150.0
KrakenPath.ERUPT_HANDLE = 0.40
-- Coil's own arrive direction, named because TWO poses need to agree on it to the
-- last bit (see POSE.Erupt's note). Not a unit vector - POSE.Coil unitises it.
KrakenPath.COIL_ARRIVE = Vector3.new(0.06, -0.45, 1)
-- ...and where the crest's tangent ends up: still climbing, leaning back out to
-- sea. See (1) above for the sign on Z.
KrakenPath.ERUPT_ARRIVE = Vector3.new(0, 0.95, -0.45)
POSE.Erupt = function(state, arm, t: number)
	local ship = KrakenPath.shipCenter(state)
	local tx = if arm.target then (arm.target - ship).X else 0
	local tz = if arm.target then (arm.target - ship).Z else 0
	local crest = KrakenPath.aboard(state, Vector3.new(tx, KrakenPath.deckY(tx) + KrakenPath.ERUPT_LIFT, tz))
	local ease = KrakenPath.smoother(t)
	-- Lerped rather than slerped, deliberately: the two directions are 100 degrees
	-- apart and a lerp of them never passes near zero magnitude, so `.Unit` is
	-- always well conditioned - and a lerp is what the CONTROL POINTS are blended
	-- with everywhere else in this file, so the pose and its blends agree.
	return coilStation(state, arm):Lerp(crest, ease),
		KrakenPath.COIL_ARRIVE:Lerp(KrakenPath.ERUPT_ARRIVE, ease).Unit,
		KrakenPath.COIL_HANDLE + (KrakenPath.ERUPT_HANDLE - KrakenPath.COIL_HANDLE) * ease
end

-- WHICH WAY A SWEEPING TIP POINTS. NOT purely along the lane, and the reason
-- is the bend law rather than taste: the limb approaches from the head on +Z
-- and a tip pinned to a pure +/-X tangent forces a right-angle hook into the
-- last stretch of a limb 48 studs thick. Measured, that hook pinned the worst
-- bend radius at 2 studs (0.08 of the bound) and no handle length rescued it -
-- a longer handle threw the second control point 226 studs PAST the tip and
-- made the polygon zigzag instead. Blending the lane's direction with the
-- approach (0.45 along, 0.89 across) turns the hook into a lean, takes the
-- pose from 0.08 to 1.00 of the bound, and still reads as a limb lying down
-- the lane because the SEGMENTS either side of the tip are what carry that
-- read, not the tangent at the very end.
function KrakenPath.sweepArrive(sign: number): Vector3
	return Vector3.new(sign * 0.45, -0.05, 0.89).Unit
end

-- THE LANE MAILBOX, and it is the one piece of state in a file whose header
-- says it has none - so it is called out rather than hidden.
--
-- The server's `sweepLane` event carries the lane EXACTLY (from / to / height
-- / width), and the telegraph strip drawn from it is exact. The ARM's own
-- attributes carry only TargetX / TargetZ, so a limb reconstructing the lane
-- by mirroring (see KrakenPath.lane) can disagree with the strip a player is
-- standing on - which is the one disagreement this whole two-sided-maths
-- arrangement exists to prevent. So whoever hears the event drops it here and
-- the limb prefers it: CreatureEventController writes it, the body controller
-- reads it, and neither has to know about the other.
--
-- Deliberately NOT per-arm and NOT per-fight: it is one hint with a timestamp,
-- ignored once stale, so a missed event degrades to the mirror rather than to
-- a limb frozen on a lane that ended.
KrakenPath.LANE = { from = nil, to = nil, z = nil, at = -1e9 }
KrakenPath.LANE_FRESH = 6.0 -- seconds a heard lane is still believed

function KrakenPath.noteLane(from: number?, to: number?, z: number?, now: number)
	KrakenPath.LANE.from = from
	KrakenPath.LANE.to = to
	KrakenPath.LANE.z = z
	KrakenPath.LANE.at = now
end

-- THE LANE A SWEEP RUNS DOWN, and this is a DETAIL THE CONTRACT DOES NOT FIX.
--
-- The contract gives an aiming arm only TargetX / TargetZ, while a sweep
-- needs two ends. The choice made here: TargetX is where the sweep FINISHES,
-- the lane is mirrored about the waist's own centre to find where it starts,
-- and TargetZ is the lane's Z. So a server that wants a bow-to-stern scythe
-- aims the finish at the stern end and gets the whole waist swept.
--
-- (The `sweepLane` CreatureEvent carries fromX/toX/deckZ explicitly and the
-- telegraph drawn from it is exact. This is the fallback the LIMB uses, and
-- the two agree whenever the server mirrors its own lane the same way.)
KrakenPath.LANE_CENTRE = (KrakenPath.SHIP.WAIST_MIN_X + KrakenPath.SHIP.WAIST_MAX_X) / 2
KrakenPath.LANE_OVERRUN = 34.0 -- how far past the lane's end the tip cocks and follows through

function KrakenPath.lane(arm): (number, number, number)
	-- The heard lane is stored in WORLD X/Z (that is what the event carries and
	-- what the telegraph strip is drawn in); the poses want it ship-local, so
	-- the conversion happens here, once, off the arm's own state.
	local heard = KrakenPath.LANE
	if heard.from and heard.to and (arm.time or 0) - heard.at <= KrakenPath.LANE_FRESH then
		local ship = KrakenPath.shipCenter(arm.state)
		local hf, ht = heard.from - ship.X, heard.to - ship.X
		local overheard = if ht >= hf then KrakenPath.LANE_OVERRUN else -KrakenPath.LANE_OVERRUN
		return hf - overheard, ht + overheard, if heard.z then heard.z - ship.Z else (arm.laneZ or 0)
	end
	local toX = arm.laneTo or 0
	local fromX = arm.laneFrom or (2 * KrakenPath.LANE_CENTRE - toX)
	local overrun = if toX >= fromX then KrakenPath.LANE_OVERRUN else -KrakenPath.LANE_OVERRUN
	return fromX - overrun, toX + overrun, arm.laneZ or 0
end

-- ---------------------------------------------------------------- one arm

-- One limb's state. This table IS the ChainPose shape state, so the renderer
-- mutates it in place every frame and never reallocates.
function KrakenPath.newArm(state, index: number)
	return {
		state = state,
		index = index,
		time = 0,
		-- The live pose, off the model's attributes.
		phase = "Rest",
		t = 0,
		target = nil, -- world, from TargetX / TargetZ
		wrap = ((index - 1) % KrakenPath.ARM_COUNT) + 1,
		laneFrom = nil,
		laneTo = nil,
		laneZ = nil,
		-- The pose being blended OUT of, kept LIVE rather than frozen - see
		-- armPoint's C1 argument.
		prevPhase = "Rest",
		prevT = 0,
		prevRate = 0,
		prevTarget = nil,
		prevWrap = 1,
		prevLaneFrom = nil,
		prevLaneTo = nil,
		prevLaneZ = nil,
		blendAt = 0, -- server time the current phase started
		blendFor = 0.45, -- how long the crossfade takes
		-- The cutscene seams. Both nil in the fight; see armPoint.
		tipOverride = nil,
		coilOverride = nil,
		-- Per-limb offset so four arms never drift as one.
		seed = index * 2.399,
	}
end

-- How long a crossfade into each phase takes.
--
-- THE RULE THIS TABLE NOW STATES (owner, 2026-09-12): THE TELL IS SLOW AND THE
-- BLOW IS NOT. Every entry that a player is meant to READ was lengthened, and
-- the two that are the strike itself were barely touched - a slam you can see
-- coming for two and a half seconds and then cannot get out of the way of is the
-- fight working; a slam that eases in over a second is a fight that does not
-- land. Specifically:
--
--   Rear / SweepCock - the windups, and the big change. These used to be 0.55
--     and 0.50, which was the crossfade doing ALL the work of getting the limb
--     from the sea to its apex while the pose itself sat still (see POSE.Rear).
--     The poses now haul over the whole of ArmT, so the crossfade's only job is
--     to get OUT of whatever the limb was doing before - it wants to be long and
--     soft, and a long one can no longer make the windup look late.
--   Slam / Sweep - the blows. 0.22 -> 0.28 and 0.20 -> 0.26: enough to kill the
--     first-frame velocity step on a 1200-stud limb, not enough to make either
--     move arrive on a different clock than its damage.
--   Rest / Down / Withdrawn / Wrapped - nothing is waiting on these, so they get
--     the time. A limb going limp has all the time in the world.
--
-- These are CROSSFADE lengths, not phase lengths: the phase's own span is the
-- server's `arm.phaseFor` off the attack row's `windup`/`duration`, and a
-- crossfade longer than the phase it is entering simply never completes (w < 1
-- the whole time), which is a soft blend and not a bug.
KrakenPath.BLEND = {
	Rest = 1.20,
	Rear = 0.95,
	Slam = 0.28,
	SweepCock = 0.90,
	Sweep = 0.26,
	Wrapped = 0.85,
	Down = 1.05,
	Withdrawn = 0.95,
	-- THE SIX NEW POSES, on exactly the same rule: the tells are long and the
	-- blows are not.
	--
	--   SpearCock 0.80 - a haul out of the sea, and a long soft crossfade cannot
	--     make it look late because the pose itself hauls over ArmT. BUT it is
	--     also re-entered between stabs, 0.7s apart, so it cannot have Rear's
	--     0.95: a crossfade longer than the gap would never finish and the three
	--     jabs would smear into one. 0.80 is the longest value that completes
	--     inside the shortest gap the row can ask for.
	--   Spear 0.18 - the fastest blend in the book, and deliberately faster than
	--     Slam's 0.28. Three stabs inside 2.1 seconds is a rhythm, and a rhythm
	--     is carried by the attack being abrupt. The seam is exact either way
	--     (SpearCock at ArmT 1 IS Spear at ArmT 0), so there is nothing for a
	--     longer ease to smooth - it would only add lag.
	--   Stuck 0.55 - the tip settling INTO the planking. Short because it is the
	--     moment the opening starts and a player is being told to turn and shoot.
	--   Drape 1.10 - a limb with nothing left in it, second only to Rest. This is
	--     the drag-to-a-stop the scythe now ends on, and the whole point of that
	--     change is that it is slow enough to read as exhaustion.
	--   Coil 1.00 - sinking out of sight. Nothing is waiting on it.
	--   Erupt 0.26 - the blow, on Sweep's number for the same reason.
	SpearCock = 0.80,
	Spear = 0.18,
	Stuck = 0.55,
	Drape = 1.10,
	Coil = 1.00,
	Erupt = 0.26,
}

-- The four control points of one pose, at one within-phase progress.
local function controls(state, arm, phase: string, t: number, which)
	local pose = POSE[phase] or POSE.Rest
	local p0 = KrakenPath.rootPosition(state, arm.index)
	-- `which` swaps in the previous phase's captured aim, so the pose being
	-- blended out of keeps aiming where it was aiming.
	local view = which or arm
	local at, arrive, handle = pose(state, view, t)
	local chord = (at - p0).Magnitude
	-- THE ROOT-IN-WATER CAP, and it is the whole of the arch invariant's
	-- enforcement: see KrakenPath.ARCH_DEPTH. P0 is already under the sea by
	-- construction; this is what keeps P1 under it too, for every pose, which is
	-- what makes it true of every BLEND of two poses without checking any of
	-- them. Only Rear's 369-stud chord is long enough to reach the cap, so
	-- nothing else in the book changes shape by a stud.
	local length = math.min(chord * KrakenPath.HANDLE_ROOT, KrakenPath.archHandleMax(state, arm.index))
	local p1 = p0 + KrakenPath.rootDirection(arm.index) * length
	local p2 = at - arrive * (chord * handle)
	return p0, p1, p2, at
end

-- A view of the arm as it was in the phase being blended out of. Cheap table
-- reuse: the caller owns `arm.prevView` so no allocation happens per frame.
local function prevView(arm)
	local view = arm.prevView
	if not view then
		view = {}
		arm.prevView = view
	end
	-- THESE TWO ARE NOT OPTIONAL AND THEIR ABSENCE WAS A CRASH, found while this
	-- pass was re-measuring the sweep poses (2026-09-12).
	--
	-- The view is handed to a POSE function, and two poses - SweepCock and Sweep -
	-- resolve their lane through KrakenPath.lane, which reads `arm.time` (to decide
	-- whether a heard lane is still fresh) and `arm.state` (to convert that lane out
	-- of world X/Z). With neither field set, `arm.time or 0` made every heard lane
	-- look INFINITELY FRESH - 0 minus a server timestamp is a large negative number,
	-- which passes the freshness test - and the very next line indexed a nil state.
	--
	-- So: once any `sweepLane` event had been heard, the first blend OUT of a sweep
	-- threw inside armPoint. That is caught by the body controller's pcall, which
	-- warns once and latches `warned`, so the whole Kraken stopped being drawn from
	-- the first deck scythe onward with a single line in the output and no visible
	-- cause. The classic shape: a value needed somewhere it was never written,
	-- presenting as something else entirely.
	--
	-- Both are read-only here and both come off the LIVE arm, which is correct -
	-- "which lane was heard, and when are we now" are properties of the frame, not
	-- of the pose being faded out. Only the pose's AIM is historical, and that is
	-- what the rest of this function copies.
	view.state = arm.state
	view.time = arm.time
	view.index = arm.index
	view.target = arm.prevTarget
	view.wrap = arm.prevWrap
	view.laneFrom = arm.prevLaneFrom
	view.laneTo = arm.prevLaneTo
	view.laneZ = arm.prevLaneZ
	return view
end

-- THE COIL, as an added offset rather than a pose. A cubic Bezier has at most
-- one inflection and cannot turn 450 degrees; a coil is 450 degrees. So the
-- Wrapped pose lands the limb on the rail and this winds the last third of it
-- round the rail line, with the winding's own weight ramped on a smootherstep
-- so the limb neither kinks where the coil starts nor unwinds where it ends.
local function coilOffset(u: number, weight: number, tangent: Vector3): Vector3
	if weight <= 1e-3 or u <= KrakenPath.WRAP_FROM then
		return Vector3.zero
	end
	local ramp = KrakenPath.smoother((u - KrakenPath.WRAP_FROM) / (1 - KrakenPath.WRAP_FROM))
	-- THE WINDING IS SCALED BY THE WEIGHT AS WELL AS THE RADIUS, and that is a fix
	-- (2026-09-12). It used to scale only the radius, which meant a HALF-WEIGHT
	-- coil was a full 0.24-turn winding drawn at half radius - a tighter helix than
	-- the pose ever asks for, appearing only DURING a crossfade and nowhere in any
	-- authored pose. Measured over every Wrapped blend pair, that cost the worst
	-- reachable transition (the wrench's break, Wrapped -> Down) 0.21 of the girth
	-- bound; winding it proportionally instead scores 0.79 there and lifts the
	-- worst reachable Wrapped blend from 0.37 to 0.55.
	--
	-- A half-weight coil is now HALF A COIL rather than half a radius, which is
	-- also what the name means: the limb winds ON as the pose comes in. At weight 1
	-- this is bit-for-bit the old expression, so no authored pose and no settled
	-- Wrapped limb changes by a float - only the transients do.
	local theta = ramp * KrakenPath.WRAP_TURNS * math.pi * 2 * weight
	-- A frame across the limb: anything perpendicular to the tangent will do,
	-- and world up is the stable choice for a limb lying along a rail.
	local side = tangent:Cross(Vector3.yAxis)
	if side.Magnitude < 1e-4 then
		side = Vector3.xAxis
	end
	side = side.Unit
	local up = side:Cross(tangent).Unit
	local radius = KrakenPath.WRAP_RADIUS * ramp * weight
	return side * (math.cos(theta) - 1) * radius + up * math.sin(theta) * radius
end

-- THE AMBIENT DRIFT, the third leg of boss_gen's idle recipe: +/-3 degrees of
-- BEARING (about the head, so the whole limb swings rather than shearing) and
-- +/-2 authored units - 12 studs - of ARC HEIGHT, on a ~7s period.
--
-- ADDED, never blended in. ChainPose's own header states the trap and it
-- applies exactly here: fold ambient into one side of a blend and a
-- full-weight attack pose annihilates it silently, so the body goes still at
-- precisely the moment it should look most alive.
--
-- The envelope is 4u(1-u) - zero at both ends. That is what keeps the root
-- welded into the mantle and keeps a slammed or wrapped tip planted where the
-- server says it is, while the middle of the limb, which is all anyone
-- actually watches, breathes.
KrakenPath.DRIFT_PERIOD = 7.0
KrakenPath.DRIFT_BEARING = math.rad(3)
KrakenPath.DRIFT_HEIGHT = 2.0 * KrakenPath.SCALE

local function driftOffset(state, arm, point: Vector3, u: number): Vector3
	local envelope = 4 * u * (1 - u)
	if envelope <= 1e-4 then
		return Vector3.zero
	end
	local w = (arm.time or 0) * (math.pi * 2 / KrakenPath.DRIFT_PERIOD) + arm.seed
	local bearing = math.sin(w) * KrakenPath.DRIFT_BEARING * envelope
	local height = math.sin(w * 0.83 + 1.7) * KrakenPath.DRIFT_HEIGHT * envelope
	-- Bearing swings about the HEAD's vertical axis: the limb pivots on its
	-- own shoulder instead of sliding sideways.
	local pivot = KrakenPath.headCenter(state)
	local dx, dz = point.X - pivot.X, point.Z - pivot.Z
	local c, s = math.cos(bearing), math.sin(bearing)
	return Vector3.new(dx * c - dz * s - dx, height, dx * s + dz * c - dz)
end

-- THE SHAPE. t = 0 in the mantle, t = 1 at the tip.
--
-- WHY THIS IS C1 ACROSS A PHASE CHANGE, which is the thing the owner asked
-- for and the only part of this file that is subtle:
--
--   * Within a phase, the curve is a cubic Bezier - C-infinity in t - whose
--     control points move on smootherstep functions of ArmT, so the tip's
--     velocity and acceleration are both continuous through a phase's own
--     progress.
--   * Across a phase change, the drawn curve is
--         C(s) = (1 - w(s)) * A(s) + w(s) * B(s)
--     with w = smootherstep, so w(0) = w'(0) = 0 and w(1) = 1, w'(1) = 0.
--     Differentiating at s = 0 gives C' = A', and at s = 1 gives C' = B'.
--     Both seams are velocity-continuous EXACTLY, not approximately.
--   * That argument only holds if A KEEPS MOVING. A frozen snapshot has
--     A' = 0, which makes C' = 0 at the seam - the limb stops dead for a
--     frame just as it changes what it is doing, which is the pop this whole
--     structure exists to avoid. So the outgoing phase's ArmT is EXTRAPOLATED
--     at the rate it was running at (prevRate), capped a little past 1 so a
--     phase that ran to completion does not run away.
--   * And the blend is a lerp of the four CONTROL POINTS, not of two sampled
--     curves. A Bezier is affine in its control points, so those are the same
--     curve to the last bit - it is ChainPose.blend, computed in 4 lerps.
--
-- The bend law is checked against this whole assembly, coil and drift
-- included, not against the Beziers alone. See the verification note below.
function KrakenPath.armPoint(arm, t: number): Vector3
	local state = arm.state
	local u = math.clamp(t, 0, 1)
	local now = arm.time or 0
	local w = KrakenPath.smoother(if arm.blendFor > 0 then (now - arm.blendAt) / arm.blendFor else 1)

	local b0, b1, b2, b3 = controls(state, arm, arm.phase, math.clamp(arm.t or 0, 0, 1), nil)
	local p0, p1, p2, p3 = b0, b1, b2, b3
	if w < 1 then
		-- The outgoing phase, kept live: its own clock carries on at the rate
		-- it was running, capped at 1.25 so a finished phase settles.
		local ta = math.clamp((arm.prevT or 0) + (arm.prevRate or 0) * (now - arm.blendAt), 0, 1.25)
		local a0, a1, a2, a3 = controls(state, arm, arm.prevPhase, math.min(ta, 1), prevView(arm))
		p0 = a0:Lerp(b0, w)
		p1 = a1:Lerp(b1, w)
		p2 = a2:Lerp(b2, w)
		p3 = a3:Lerp(b3, w)
	end

	-- THE CUTSCENE SEAM, and it is deliberately the LAST thing that touches
	-- the control polygon. `tipOverride` moves the end point and carries p2
	-- with it by the same delta, which preserves the pose's arrival direction
	-- and its handle length - so a driven limb bends the way this limb bends
	-- rather than becoming a different animal's arm. Nil is the fight's normal
	-- state and costs one comparison; nothing about the maths below changes.
	if arm.tipOverride then
		local delta = arm.tipOverride - p3
		p2 += delta
		p3 = arm.tipOverride
	end

	local point = KrakenPath.bezier(p0, p1, p2, p3, u)

	-- The coil rides the same crossfade the pose does, so a limb winds on and
	-- unwinds instead of appearing already coiled.
	local coilNow = if arm.phase == "Wrapped" then w else 0
	local coilWas = if arm.prevPhase == "Wrapped" then 1 - w else 0
	local coil = arm.coilOverride or (coilNow + coilWas)
	if coil > 1e-3 then
		local d1 = KrakenPath.bezierD1(p0, p1, p2, p3, u)
		if d1.Magnitude > 1e-5 then
			point += coilOffset(u, coil, d1.Unit)
		end
	end

	return point + driftOffset(state, arm, point, u)
end

-- VERIFIED, NUMERICALLY, AGAINST THE GIRTH-AWARE BEND LAW.
--
-- THE LAW: at every u the DRAWN centreline's radius of curvature must beat the
-- limb's own half-thickness there - girthAt(u), 24 studs at the shoulder
-- tapering to 6.7 at the tip - with 10% margin. A limb that bends tighter than
-- its own half-thickness folds through itself, and at 48 studs of girth that
-- is not a subtle artefact: it is a building passing through a building.
--
-- MEASURED ON THE ASSEMBLED CURVE - Bezier plus coil plus drift, exactly what
-- armPoint returns - by a five-point finite difference, because the coil and
-- the drift are not polynomial and an analytic derivative would only cover the
-- easy part. Every pose swept over all four seats, ArmT in {0, 0.5, 1}, all
-- four wrap points, nine deck aim points spanning the waist, and two drift
-- phases; then every ordered phase pair at blend weights 0.1 .. 0.9. Worst
-- ratio R_min / (1.1 * girth), so 1.00 IS the bound:
--
--     Rest        1.23      Rear        2.90      Slam        1.40
--     SweepCock   1.50      Sweep       1.40      Wrapped     1.08
--     Down        2.02      Withdrawn   5.45
--
-- EVERY POSE PASSES. Wrapped is the binding case at 1.08, as it should be -
-- the wrap is the only place the animal deliberately turns back on itself -
-- and its worst point is the last 1% of the limb, where the taper has already
-- done most of the work.
--
-- ============================================== RE-MEASURED, 2026-09-12
--
-- The slower-and-rooted pass (the owner's four asks: a readable windup, slower
-- motion, limbs that never leave the water at the root, and a mark on the deck)
-- re-ran the whole sweep and added a SECOND law - the ROOT-IN-WATER / ARCH law,
-- stated at KrakenPath.ARCH_DEPTH. Both columns below are worst-over-everything:
-- both fight seats, nine deck aim points across the waist, all four wrap points,
-- ArmT in {0, 0.5, 1}, four drift phases, t stepped 0.01.
--
--   ARCH is studs of water over the SHALLOWEST point of the first 15% of the
--   limb's own ARC LENGTH. It must be positive. (A negative number is a limb
--   whose root run is in the air - the "detached limb" read.)
--   BEND is the same R_min / (1.1 * girth) ratio as above; 1.00 is the bound.
--
--     phase        arch      bend   (bend before this pass)
--     Rest        52.07      1.25   1.25    unchanged
--     Rear        20.62      1.68   3.01    now a moving haul, not a hold
--     Slam        20.04      1.49   1.49    unchanged
--     SweepCock   41.72      1.48   1.80    now a moving draw, not a hold
--     Sweep       41.46      1.80   1.80    unchanged
--     Wrapped      4.16      1.18   1.11    re-shaped; see its own note
--     Down        44.26      2.19   2.19    unchanged
--     Withdrawn   47.58      5.46   5.46    unchanged
--     Adrift      60.00      3.05   0.61    FIXED; see rootDirection
--
-- WHAT THIS PASS ACTUALLY FOUND, because two of these are repairs rather than
-- tuning:
--   * WRAPPED WAS 8.8 STUDS OUT OF THE WATER at a third of the way along itself -
--     the only authored pose that broke the arch law, and the source of the
--     complaint. It is now 4.2 studs under AND half a point better on the bend
--     law than it was. It is still the binding case for the arch, which is
--     honest: nothing else in the book has to reach a rail 34 studs up and then
--     hook round a hull.
--   * ADRIFT MEASURED 0.27 OF THE BOUND across its blends - flesh through flesh,
--     on the two limbs that are on screen for the whole fight and the whole
--     intro. It had never been in this table at all (it is the decoration seats'
--     only pose, and every previous sweep ran the fight seats). Cause and cure
--     are in KrakenPath.rootDirection; it is 1.89 at worst now.
--   * Rear and SweepCock each give up some margin - 3.01 -> 1.68 and 1.80 -> 1.48
--     - and that is the price of their being MOVES instead of held shapes. Both
--     clear with room, and both numbers were bought back from much worse first
--     attempts by measuring rather than guessing (see each pose's note).
--
-- A WARNING FOR WHOEVER RE-RUNS THIS: SAMPLE ALL FOUR DRIFT PHASES. Two of the
-- numbers above were chosen off a one-drift-phase scan and were wrong by a
-- factor of nearly two - Wrapped measured 1.24 on the cheap sample and 0.69 on
-- the full one. The drift is small (12 studs) but it is not polynomial, and it is
-- routinely the binding sample.
--
-- THE BLENDS, AND WHICH OF THEM THE FIGHT CAN ACTUALLY ASK FOR. Every ordered
-- pair was swept; the ARCH law passes on all of them (worst 13.4 studs under, so
-- the affine argument at ARCH_DEPTH holds in practice as well as on paper). The
-- BEND law does not, and it did not before this pass either - the claim three
-- paragraphs up that "every other pair clears" was measured on a different slice
-- and is not true of this one. What matters is that the bad pairs are almost all
-- UNREACHABLE: `Fn.krakenFreeArm` only ever hands out an arm at Rest, so the
-- machine cannot crossfade Wrapped into Rear, SweepCock, Slam or Sweep, and
-- cannot reach Slam except out of Rear. Of the pairs the server can produce:
--
--     Rest->Wrapped / Wrapped->Rest    0.55   (was 0.78 - WORSE, see below)
--     Wrapped->Down  (wrench break)    0.79   (was 0.37 - better)
--     Rest->Rear                       0.90   (was 0.84)
--     Rear->Rest                       1.12   (was 0.84)
--     Rest->SweepCock                  1.29
--     Slam->Down / Sweep->Rest         2.17 / 1.62
--     everything else                 >= 1.8
--
-- so the worst transient the fight can show went from 0.37 to 0.55 of the bound.
-- The three sub-bound pairs are all crossfades INTO or OUT OF a coiled limb or
-- into the start of a haul, they last one BLEND time, and the limb is 300+ studs
-- out over open water for all of them.
--
-- WHY WRAPPED <-> REST GOT WORSE rather than better, stated rather than buried:
-- it is the cost of winding the coil in proportion to the blend weight (see
-- coilOffset), which is what bought Wrapped->Down its 0.37 -> 0.79. The trade was
-- taken on the worst-case: 0.55 is a better floor than 0.21, which is what
-- Wrapped->Down measured with the coil left as it was. Closing the rest of it is
-- an ORDERING change on the server - never crossfade Wrapped straight into
-- another committed pose - and that is written up with its anchor lines in this
-- lane's scratchpad (SERVER-NOTES.md) rather than guessed at from here.
--
-- Stability: halving the difference step changes the Wrapped figure by 0.00%
-- (2.0703 both ways), so these are the curve's numbers and not the sampler's.
-- That check is in the script for a reason this file learned the hard way -
-- an earlier release exponent scored fine at 4000 samples and failed at 200k,
-- because the blow-up was too narrow for a coarse sweep to land on.
--
-- TWO RESIDUALS, STATED RATHER THAN ROUNDED OFF:
--   * The Rear -> Rest CROSSFADE bottoms at 0.59 of the bound at its 80% mark,
--     mid-limb. It is the worst of the 56 ordered phase pairs and it is a
--     transient: the two poses' end points are 400 studs apart vertically, so
--     the lerped control polygon passes through a shape neither pose is, for
--     about a third of a second. Every other pair clears. Closing it properly
--     means routing that transition through Withdrawn (which measures 5.45) -
--     a SERVER-side ordering choice, not something this file can impose.
--   * REST DURING THE RISE bottoms at 0.53 at Rise 0.35, because the root is
--     300 studs underwater while Rest's end point is fixed in ship space, so
--     the chord is briefly steep. It lasts as long as the rise animation and
--     the limb is under the sea for it.
--
-- WHAT HOLDS THE MARGIN, and what happens if it moves:
--   TIP_GIRTH   0.72  - the taper. See its own note; 0.60 fails Wrapped.
--   HANDLE_ROOT 0.55  - the root handle.
--   ROOT_FORWARD 36   - the root ON the hide. At 30 it is inside the animal
--                       and Rest degenerates to a 37-stud chord: 0.04.
--   WRAP_* (0.30 / 0.30 / 150) - the coil, spread. At 0.66 / 1.25 / 70: 0.25.
--   sweepArrive       - the lane blend. A pure +/-X tip tangent: 0.08.
--   Withdrawn ROOT-RELATIVE - as an absolute point it hairpins: 0.01.
--
-- The check is bendcheck.py in this lane's scratchpad - a straight port of
-- this file's math, not a sampling of the running game, so it can be re-run
-- against any change here without Studio.

return KrakenPath
