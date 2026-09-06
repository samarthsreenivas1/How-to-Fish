--!nonstrict
-- BrinejawPath.luau
-- Where every piece of Brinejaw is, right now: ONE boss's path shape.
--
-- The generic half lives in ChainPose (walking any path by arc length and
-- handing out CFrames) - Wrack's anchor chains and the Kraken's arms drive
-- the same machinery with their own path functions. This file is only the
-- serpent's geometry.
--
-- The serpent is one continuous chain of ~100 parts (assets/boss_gen.py),
-- and this module is the single function that says where each one sits:
-- `pointAt(state, t)` with t = 0 at the snout and t = 1 at the rattle. The
-- coils on the lighthouse and the sweeping tail are the SAME chain, so an
-- attack is never a new object - it is this path changing shape. That is why
-- the tail can lash across the arena without anything spawning: it UNWINDS
-- off the tower.
--
-- Server and client both require this file, and that is the point:
--   * the server needs one point (the head) to stand its model on, and does
--     its damage tests analytically (bearing + radius + height bands), so a
--     sweep costs it no geometry at all;
--   * the client walks the whole chain every frame to draw the body.
-- Sharing the math means the thing you dodge and the thing you see can never
-- drift apart.
--
-- The numbers below ARE the pose in assets/boss_brinejaw_staged.png - the
-- staged render is the review artifact for this table. Coordinates are
-- Roblox's (Y up), arena-local until `state.center` is added.
--
-- NOTE ON GROUND HEIGHT: sandY() mirrors the authored arena's beach profile
-- (assets/arena_gen.py). Before that mesh is imported the arena is a flat
-- procedural disc, so a resting tail rides a couple of studs high - cosmetic,
-- and it corrects itself the moment the real arena lands.
--
-- ==========================================================================
-- THE REPLICATED STATE CONTRACT
-- ==========================================================================
--
-- TEN ATTRIBUTES ON THE BOSS MODEL, AND NOTHING ELSE. The server writes
-- them; the client eases toward them and draws; both sides feed the SAME
-- state table to the SAME functions in this file. Every shape below has an
-- analytic hit-test twin here, computed from these ten values and nothing
-- more - that is the prime law of this boss, and every one of the fourteen
-- defects the 2026-08-30 audits found was a value that lived in one place
-- and was needed in another. If you need a new number, DERIVE it here.
--
--   attribute      state field    meaning
--   -----------    -----------    ---------------------------------------
--   Coil           coil           3..0, how many turns still grip the tower
--   Unwind         unwind         0 coiled, 1 tail fully off the tower
--   SweepAngle     sweepAngle     the sweep arm's BASE bearing, radians
--   SweepHeight    sweepHeight    the arm's centre height above the sand
--   Slump          slump          0 reared, 1 head down (the punish window)
--   FaceAngle      faceAngle      who it is watching, radians
--   AttackKind     attackKind     "" when idle, else one of ATTACK below
--   AttackU        attackU        0..1, progress through the CURRENT attack
--   AimX           aimX           arena-LOCAL x of the aim point, 0 if none
--   AimZ           aimZ           arena-LOCAL z of the aim point, 0 if none
--
-- Aim is arena-local (relative to `state.center`, the tower's FOOT), because
-- `center` is already replicated as PoseCenter and a world-space aim would
-- be the same number written twice.
--
-- TWO FIELDS ARE NOT ATTRIBUTES, ON PURPOSE:
--
--   state.time       each side's own clock; only ambient sway reads it, and
--                    sway is deliberately not authoritative.
--
--   state.sweepRate  the arm's SIGNED ANGULAR VELOCITY (rad/s), which is the
--                    whip's drag term. It is NOT replicated because it is
--                    the derivative of SweepAngle, which already is: adding
--                    an attribute for it would be the exact "one value, two
--                    homes" bug this contract exists to prevent. BOTH SIDES
--                    DIFFERENTIATE THE SAME SweepAngle and hand the result
--                    in as a CALLER-SUPPLIED FIELD, through the one filter
--                    below so the two derivatives cannot diverge:
--
--                      server: BrinejawPath.stepSweepRate(state, dir * arc /
--                              duration, dt)     -- it knows the exact rate
--                      client: BrinejawPath.stepSweepRate(state,
--                              wrapAngle(eased - lastEased) / dt, dt)
--
--                    `stepSweepRate` low-passes with WHIP_TAU. That is what
--                    makes the two agree: the client's eased angle responds
--                    to a step in the server's rate with a 1/55 s lag, so the
--                    two raw rates disagree badly for the first frames of
--                    every sweep. Running BOTH through one 0.35 s filter puts
--                    the worst-case tip divergence at 0.876 studs, against
--                    1.70 for half the LOW sweep's girth - so no player is
--                    ever hit by a curve they were not shown. Measured over
--                    all four sweeps in the book at 60 Hz, with the two
--                    controls that must fail: unfiltered raw rates diverge
--                    12.98 studs, and WHIP_TAU = 0.16 gives 1.71.
--                    A caller that supplies nothing gets rate 0: a straight
--                    arm that still matches its own hit test, which is wrong
--                    but never unfair.
--
-- PER-KIND SEMANTICS OF AttackU AND Aim. U is progress through the WHOLE
-- attack, 0 at the first windup frame and 1 when the boss is back at rest;
-- the server must RUN U TO 1 before clearing AttackKind, because the exit
-- ramp lives in the last few percent. Clearing the kind at U < 1 snaps.
--
--   "lunge"     head+neck leave the coil and strike DOWN at the aim point.
--               Aim = where the skull lands, on the sand.
--               U 0..0.35  rear and track: the head rises and swings onto
--                          the aim bearing (still trackable - the server may
--                          keep rewriting Aim through this window).
--               U 0.35..0.50 strike: fast descent. THE BLOW LANDS AT 0.50
--                          (LUNGE_IMPACT_U), so the tell's countdown must
--                          end there and not at the end of the windup.
--               U 0.50..0.72 held: the skull is planted on the sand at the
--                          aim point, 2.4 studs up - level with a standing
--                          R15 root. THE PUNISH WINDOW. Aim must be frozen
--                          from 0.35 on or the head slides sideways.
--               U 0.72..1  recover: the head peels back up the tower. This
--                          is the attack's `exit` ramp and it is 28% of U
--                          because the skull has 56 studs to climb: at the
--                          8% a first draft used, the body moved 5.1 studs
--                          in one step of U at 240 steps, and at 28% it
--                          moves 1.00. The punish window is therefore
--                          0.50..0.72, NOT 0.50..1 - hold U at 0.72 if you
--                          want it open longer.
--               Twins: lungeHeadPosition (park the authority model on it),
--               lungeImpactPoint, lungeHits.
--
--   "undertow"  a bulge travels BENEATH the sand from the tower's foot out
--               to the aim point at constant speed; the middle third of the
--               body is submerged either side of it.
--               Aim = the far end of the run. U 0..1 is the travel, LINEAR
--               in distance (constant speed is the read), so the bulge sits
--               at radius UNDER_INNER + (aimR - UNDER_INNER) * U the whole
--               way. Aim must be frozen at U = 0. The first and last 30% of
--               U are the body DIVING under the beach and surfacing again -
--               declared fast phases, like a strike (4.10 studs a step at
--               240 steps), because a third of a colossus has to unwind a
--               turn and a half of coil to get there.
--               Twins: undertowPoint (world XZ + progress - server damage
--               and client dust ride the SAME point), undertowHits.
--
--   "belltoll"  the head strikes the keeper's bell (REST.BELL).
--               Aim is UNUSED (write 0, 0).
--               U 0..0.35  windup, 0.35..0.55 strike, 0.55..1 recoil. THE
--               BELL IS STRUCK AT 0.55 (BELL_IMPACT_U). The rings are the
--               server's and the client's business; this file only poses the
--               head. Twin: bellStrikePoint.
--
--   "rear"      the whole front half rears to full height and HOLDS - the
--               Tidal Surge set-piece. Aim unused; it rears on the bearings
--               it already has, DISPLACING the front half outward and upward
--               rather than replacing its shape, so the coils rear with it.
--               U 0..0.30 rise, 0.30..0.84 hold, 0.84..1 come down. To hold
--               longer, hold U at 0.5; to come down, run U to 1.
--               Twin: rearHeadPosition.
--
--   "spiral"    constrict's new form. The SWEEP ARM's reach contracts with
--               U, so the lethal band closes in as the arm circles. This
--               kind does NOT pose the body on its own: the server drives
--               Unwind/SweepAngle/SweepHeight exactly as for a plain sweep
--               and this kind only shortens the arm. Aim unused.
--               U 0..1 maps reach SWEEP_REACH -> SWEEP_INNER + SPIRAL_CLOSE.
--               Twins: sweepReach, sweepHits/spiralHits (the same function).
--
--   "collapse"  THE DEATH FALL, and the closed loop for `state.fall`, which
--               used to be read by slumpPoint and written by nobody. `fall`
--               is now DERIVED: kind "collapse" means fall = U. Nothing on
--               either side writes state.fall; if you find code that does,
--               it is the bug. Drive Slump to 1 and AttackKind to "collapse"
--               and run U 0..1 over the collapse's duration.
--               Twin: fallAmount.
--
-- THE HIT TEST IS THE DRAWN CURVE. `sweepHits` no longer tests a radial
-- spoke: it asks `sweepBearingAt(state, r)` where the arm is at the player's
-- own radius, which is the same call `sweptCyl` makes to place the body.
-- CONSEQUENCE FOR THE SERVER WRITER: a probe table assembled by hand and
-- missing `sweepRate` (or `attackKind`/`attackU`) hit-tests a STRAIGHT arm
-- against a CURVED one and silently under-hits by up to 35 degrees of
-- bearing. Build probes with `BrinejawPath.sweepProbe(state, angle)`, which
-- carries every field the twins read, and never by table literal.
--
-- AND THE OTHER HALF OF THE FIGHT. Five of Brinejaw's attacks are not poses -
-- a wave crossing the arena, a seeded bombardment, the bell's rings, the
-- flood, the polyps - so they ride `fireEvent` payloads instead of the ten
-- attributes. Their geometry still lives in this file, under "THE EVENT
-- SHAPES" at the bottom: `lcg`, `waveFront`, `waveSheltered`, `rainChunks`,
-- `ringRadius`, `surgeRain`. Same law, different channel.

local BrinejawPath = {}

local TAU = math.pi * 2

-- ---------------------------------------------------------------- the tower

-- The lighthouse's radius at height y - arena_gen's three tapering drums.
-- EXPORTED, because two things build against it: the coils wrap this profile,
-- and until the authored mesh lands BossArenaService raises a stand-in tower
-- from the same table. A serpent coiled around a lighthouse that isn't there
-- is what the procedural arena shipped as.
BrinejawPath.SPIRE_DRUMS = { { 3.5, 20.0, 8.5, 7.4 }, { 20.0, 38.0, 7.2, 6.2 }, { 38.0, 54.0, 6.0, 5.2 } }
BrinejawPath.SPIRE_TOP = 54.0

-- THE TOWER STEPS; THE BODY DOES NOT. Each drum starts 0.2 studs narrower
-- than the one below it ends - a corbel, and correct masonry. But reading the
-- drums directly gave the coils a radius that TELEPORTED 0.2 studs across zero
-- height at y=20 and again at y=38, and the helix crosses both. On a spiral
-- this tight that showed up as a 73-degree corner in the body, twice, which is
-- worse than either of the two joins the curve was designed around.
--
-- So the clearance curve is the drums' endpoints as one continuous polyline.
-- It sits at or outside the masonry everywhere (equal at 3.5, 38 and 54, and
-- 0.2 proud just above each ledge), so the body still never clips the tower -
-- it rides over each step instead of snapping across it.
local SPIRE_PROFILE = { { 3.5, 8.5 }, { 20.0, 7.4 }, { 38.0, 6.2 }, { 54.0, 5.2 } }

function BrinejawPath.spireRadius(y: number): number
	for i = 1, #SPIRE_PROFILE - 1 do
		local a, b = SPIRE_PROFILE[i], SPIRE_PROFILE[i + 1]
		if y <= b[1] then
			local t = math.clamp((y - a[1]) / (b[1] - a[1]), 0, 1)
			return a[2] + (b[2] - a[2]) * t
		end
	end
	return SPIRE_PROFILE[#SPIRE_PROFILE][2]
end

-- The beach's height at radius r from the tower (arena_gen's BJ_PROFILE).
function BrinejawPath.sandY(r: number): number
	local profile = { { 0, 3.2 }, { 10, 3.0 }, { 16, 2.2 }, { 30, 1.6 }, { 48, 1.4 }, { 62, 1.0 }, { 70, 0.4 } }
	for i = 1, #profile - 1 do
		local a, b = profile[i], profile[i + 1]
		if r <= b[1] then
			local t = math.clamp((r - a[1]) / (b[1] - a[1]), 0, 1)
			return a[2] + (b[2] - a[2]) * t
		end
	end
	return 0.4
end

-- ---------------------------------------------------------------- rest pose

BrinejawPath.REST = {
	NECK_END = 0.11, -- t where the neck meets the top coil
	HELIX_END = 0.74, -- t where the bottom coil lets go of the tower
	TURNS = 3.0,
	TOP_Y = 44.0,
	BOTTOM_Y = 12.0,
	CLEARANCE = 3.4, -- body centre stands this far off the masonry
	HEAD_Y = 60.0,
	HEAD_OUT = 8.0, -- how far past the gallery the neck leans out
	BEARING = math.rad(342.0),
	TAIL_OUT = 31.0,
	TAIL_TURN = 0.85,
	-- THE KEEPER'S BELL, arena-local, and it HANGS OFF THE GALLERY. It used to
	-- lie half-buried in the sand at Roblox (26.0, 0.6, 38.0) - radius 46, out
	-- past the mid-beach - and Bell Toll is a head strike that rings the tower,
	-- so a bell 46 studs away from the tower could not be the thing struck.
	-- The arena pass moved it: arena_gen's `build_bj_dressing` now hangs it
	-- from a yoke off the lighthouse gallery on this same BEARING (342 deg),
	-- the bearing the head already rests over, so the strike reads without the
	-- rest pose moving at all.
	--
	-- BossArenas.items.tropical.bell IS THE TRUTH and this is its mirror, kept
	-- here rather than read off the Instance because the server hit-tests the
	-- bell before the model exists and the client draws it in the same frame
	-- the mesh streams in. MEASURED off the build (r 9.0 at 18 deg in Blender,
	-- z 53.0), not derived - re-key from arena_gen's `Bell ROBLOX rel` HANDOFF
	-- line and from that row, together, or the serpent tolls a bell that is
	-- somewhere else.
	BELL = Vector3.new(8.6, 53.0, -2.8),
}

-- One turn's pitch: what a lost grip costs it, and how far the head drops.
BrinejawPath.COIL_DROP = (BrinejawPath.REST.TOP_Y - BrinejawPath.REST.BOTTOM_Y) / BrinejawPath.REST.TURNS

-- How many coils it starts with, and so how many times it can be dropped.
BrinejawPath.MAX_COIL = 3

-- The sweeping tail reaches this far out - past the sand ring's edge, so
-- there is nowhere on the floor a sweep cannot find you.
BrinejawPath.SWEEP_REACH = 66.0
-- ...but never closer in than this, so hugging the tower is a real (if
-- dangerous) answer to a sweep.
BrinejawPath.SWEEP_INNER = 13.0

-- Sweep heights: LOW is jumped, HIGH is stood under. Far enough apart that
-- reading which one is coming is the whole skill.
-- These are the arm's CENTRE height above the sand, and `sweepHits` catches
-- anything within the attack's `girth` (3.4-3.8) of that line. So the two
-- numbers are not decoration - they have to be far enough apart that a
-- STANDING player is inside one and outside the other, or the fight's whole
-- read collapses. The arithmetic, against a standing R15 root that sits
-- ~3.0 studs over the ground (HipHeight 2 + half of a 2-stud root):
--
--   LOW  1.6 -> |3.0 - 1.6| = 1.4, inside girth 3.4. Standing is hit, so you
--               have to leave the ground: JUMP IT.
--   HIGH 8.5 -> |3.0 - 8.5| = 5.5, outside girth 3.8 with 1.7 studs to
--               spare. Standing is safe. A jump lifts the root to ~10.3 at
--               its apex and crosses the band from ~4.7 upward, so panic-
--               jumping puts you straight into it: STAND STILL.
--
-- HIGH was 5.4 and that was a real bug, caught before the first playtest:
-- |3.0 - 5.4| = 2.4 sat INSIDE girth 3.6, so standing under a high sweep was
-- hit and half the mechanic did the opposite of what it teaches. Keep at
-- least a stud of margin on both sides of any change here, and remember the
-- client draws the marker from these same constants - move one and the
-- warning moves with it.
BrinejawPath.SWEEP_LOW = 1.6
BrinejawPath.SWEEP_HIGH = 8.5

-- How far off the coil's bearing the head can swing to watch someone. A
-- cone, not free rotation: the neck is anchored to the top coil.
-- 75 degrees left 58% of the arena unlookable, including the reef stone at
-- bearing 105 - a party baiting slams there got a serpent permanently
-- staring at a fixed patch of sea. The coil is allowed to slide a little on
-- the drum, so the head can reach most of the ring.
BrinejawPath.HEAD_TURN = math.rad(125)

local function wrapAngle(a: number): number
	return (a + math.pi) % (math.pi * 2) - math.pi
end
BrinejawPath.wrapAngle = wrapAngle

local function smoothstep(x: number): number
	x = math.clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end

-- ------------------------------------------------------- cylindrical space
--
-- The spire axis is the arena-local Y axis, so "around the tower" is just
-- (theta, r, y). EVERY BLEND THAT CAN STRADDLE THE MASONRY RUNS HERE rather
-- than in world XYZ: a straight lerp between two points on opposite sides of
-- the lighthouse passes through the lighthouse, and the retraction at the end
-- of a sweep does exactly that whenever the arm stops far from the coil's
-- bearing. Measured, over 24 park bearings x 61 retraction steps x 241 body
-- positions: the positional lerp this replaces passed 7.98 studs INSIDE the
-- masonry (worst point 0.24 studs off the axis - straight through the
-- lantern); in cylindrical space the same sweep never comes nearer than 5.04
-- studs outside it. The binding minimum for the whole body is 1.14 studs and
-- it belongs to the REST pose's slack tail at t=0.85, which is pre-existing
-- and untouched (rest alone measures 1.05).
--
-- AND THE TRAP, because it cost an afternoon: A CYLINDRICAL BLEND MUST USE
-- UNWRAPPED BEARINGS. The obvious form - atan2 both points, lerp the short
-- way round - is DISCONTINUOUS along the body, because the rest pose is a
-- three-turn helix: neighbouring vertebrae sit up to a full turn apart in
-- bearing, so they pick opposite ways round and the curve tears. It measured
-- as a 144-degree kink in the middle of the tail at half weight. So the rest
-- side is unwrapped against the helix's own analytic winding (restBearing)
-- and every attack side is expressed on a branch chosen ONCE per state, never
-- per body position.
local function cylOf(p: Vector3): (number, number, number)
	local r = math.sqrt(p.X * p.X + p.Z * p.Z)
	return (if r > 1e-4 then math.atan2(p.Z, p.X) else 0), r, p.Y
end

local function fromCyl(theta: number, r: number, y: number): Vector3
	return Vector3.new(math.cos(theta) * r, y, math.sin(theta) * r)
end

-- The bearing the rest pose is WINDING THROUGH at `t` - continuous, and
-- growing without bound down the helix rather than wrapping at +-pi. The
-- reference is the pose's own analytic spiral; the measured curve never
-- strays half a turn from it, so one wrap against the reference recovers the
-- true branch for the neck, the coils and the slack tail alike.
local function restBearingRef(t: number): number
	local rest = BrinejawPath.REST
	if t <= rest.HELIX_END then
		local k = math.clamp((t - rest.NECK_END) / (rest.HELIX_END - rest.NECK_END), 0, 1)
		return rest.BEARING + rest.TURNS * TAU * k
	end
	local k = (t - rest.HELIX_END) / (1 - rest.HELIX_END)
	return rest.BEARING + rest.TURNS * TAU + rest.TAIL_TURN * TAU * k
end

local function restBearing(t: number, wrapped: number): number
	local ref = restBearingRef(t)
	return ref + wrapAngle(wrapped - ref)
end

-- Blend a rest point (already in unwrapped cylindrical form) toward a target
-- in the same space. One place, so no caller can reinvent the wrap.
local function cylBlend(theta, r, y, tTheta, tR, tY, w): Vector3
	return fromCyl(theta + (tTheta - theta) * w, r + (tR - r) * w, y + (tY - y) * w)
end

-- ------------------------------------------------------- the attack channel

-- Per-kind spans and ramps. `span` is how far down the body the pose reaches
-- (t = 0 at the snout); `entry`/`exit` are the fractions of U spent fading in
-- and out, which is why the server must run U all the way to 1.
--
-- THE RAMPS ARE SIZED FROM THE CONTINUITY AUDIT, not from taste. Each is the
-- shortest fade that keeps the worst single-step body jump under 1.5 studs
-- over U swept at 240 steps: the head has 56 studs to climb back up the tower
-- at the end of a lunge, so an 8% exit moved it 5.1 studs a step and a 28%
-- exit moves it 1.00. `mode` picks which mechanism poses the body:
--   "neck"     replace the front `span` with an arc to a head target
--   "rear"     DISPLACE the front `span` outward and upward, coils and all
--   "undertow" replace the middle third with a buried run
--   "sweep"    no body pose of its own; it re-shapes the sweep arm
--   "fall"     no body pose of its own; it drives `fall` for slumpPoint
BrinejawPath.ATTACK = {
	lunge = { mode = "neck", span = 0.26, entry = 0.10, exit = 0.28, arch = 5.0 },
	belltoll = { mode = "neck", span = 0.24, entry = 0.10, exit = 0.14, arch = 7.0 },
	rear = { mode = "rear", span = 0.50, entry = 0.16, exit = 0.16 },
	undertow = { mode = "undertow", entry = 0.30, exit = 0.30 },
	spiral = { mode = "sweep" },
	collapse = { mode = "fall" },
}

-- Where the aim point may be. The head cannot reach the tower's own foot and
-- cannot reach past the reef, and an unclamped aim is how a neck ends up
-- threaded through the masonry (AIM_MIN is outside spireRadius(sand) +
-- CLEARANCE = 11.9, with 4 studs of slack).
BrinejawPath.AIM_MIN = 16.0
BrinejawPath.AIM_MAX = 58.0

BrinejawPath.LUNGE_COCK_U = 0.35 -- rear/aim ends, the strike begins
BrinejawPath.LUNGE_IMPACT_U = 0.50 -- the skull lands HERE, not at windup's end
BrinejawPath.LUNGE_COCK_R = 16.0 -- how far out it draws the head back to
BrinejawPath.LUNGE_RISE = 12.0 -- how far above the rest head it cocks
BrinejawPath.LUNGE_SIT = 2.4 -- skull centre above the sand once planted:
-- low enough that an R15 root at ~3.0 is level with it, which is the whole
-- point of the punish window. Raise this and melee starts whiffing upward.

-- THE BLOW'S FOOTPRINT, and the bulge's. These are radii the SERVER passes to
-- `lungeHits` / `undertowHits` and the CLIENT draws its countdown ring and its
-- dust plume at, so they live here for the same reason every other number in
-- this file does: a book row carrying its own radius would put the drawn
-- circle and the lethal one in two files, and the drawn one is a promise.
-- Pass these to the hit twins; do not pass a row's own number.
-- 9.0 is a little over the planted skull's own width (LUNGE_SIT sits it 2.4
-- studs up and the head mesh is ~15 long at HEAD_SCALE 1.35), so the disc
-- reads as "where the head is" rather than as an invisible splash; 7.5 is the
-- bulge's crest, whose gaussian (UNDER_SIGMA 6.0) is still 2.6 studs proud at
-- 6 studs off centre and buried by 9.
BrinejawPath.LUNGE_RADIUS = 9.0
BrinejawPath.UNDERTOW_RADIUS = 7.5

BrinejawPath.BELL_WINDUP_U = 0.35
BrinejawPath.BELL_IMPACT_U = 0.55 -- the bell is STRUCK here
-- Where on the bell the skull lands, above REST.BELL's centre. The bell is no
-- longer buried (see REST.BELL): the authored body runs z 50.5..55.5 with the
-- crown and yoke above that, so +1.7 puts the impact on its upper shoulder,
-- inside the mesh rather than on the sand it used to be sunk in. The value
-- survives the move unchanged; the reason for it does not.
BrinejawPath.BELL_LIFT = 1.7
BrinejawPath.BELL_COCK_R = 15.0
BrinejawPath.BELL_RISE = 14.0

BrinejawPath.REAR_U = 0.30 -- U at which the rear reaches full height
BrinejawPath.REAR_OUT = 10.0 -- how much further off the tower the front leans
BrinejawPath.REAR_LIFT = 24.0 -- how much higher the snout stands: 60 + 24
-- REAR IS A DISPLACEMENT, NOT A REPLACEMENT POSE, and that is the whole
-- reason it is safe. A "straighten the front half into an arc" version had to
-- unwind 1.86 turns of coil to reach a straight neck, which is both wrong
-- (a serpent rears off its coils, it does not shed them) and the fastest way
-- to stand a limb dead vertical. Pushing (r, y) outward and upward while
-- LEAVING EVERY BEARING ALONE keeps the coil's own pitch under the lift, so
-- nothing can corkscrew and nothing can wrap.
--
-- CAPPED all the same, and this is ChainPose's documented limit, not a taste
-- call: `alongX` picks its frame off the tangent's AZIMUTH, which is
-- undefined at exactly vertical, so a body that reaches |tangent.Y| = 1 gets
-- one frame of arbitrary roll. Measured over U 0..1 x the whole body, the
-- steepest tangent this pose produces is 77.8 degrees (|tangent.Y| = 0.9772),
-- inside the ~85 cap with room for the ambient bob - and note the rest pose
-- already reaches 77.7 at the snout, so the rear adds almost nothing to the
-- risk. Raise REAR_LIFT or drop REAR_OUT and re-measure.

BrinejawPath.UNDER_T0 = 0.34 -- the middle third of the body, and only it
BrinejawPath.UNDER_T1 = 0.67
BrinejawPath.UNDER_INNER = 10.0 -- the run starts just clear of the foot
-- The buried body EXTENDS with the bulge - it runs from the foot to the crest
-- plus this, not out to the aim point from the first frame. Laying the whole
-- line out at U = 0 made the dive travel 6.3 studs a step at 240 steps
-- (the mid-body had to unwind a turn and a half of coil AND reach 68 studs
-- out before the bulge had moved at all); growing it puts the same dive at
-- 4.10 and is what a body shoving itself under a beach actually does.
BrinejawPath.UNDER_OVERRUN = 10.0
BrinejawPath.UNDER_DEPTH = 4.5 -- how far under the beach the body rides
BrinejawPath.UNDER_HUMP = 7.1 -- so the crest sits 2.6 PROUD of the sand
BrinejawPath.UNDER_SIGMA = 6.0 -- the hump's width; wider reads as a swell

BrinejawPath.SPIRAL_CLOSE = 8.0 -- the arm's final reach is SWEEP_INNER + this

-- ---------------------------------------------------------------- the whip
--
-- THE ARM IS A DRAG CURVE, NOT A SPOKE. A radial arm rotating about the
-- tower is the single thing the user called out ("the tail is completely
-- stiff while it just rotates"): a rigid line has no tail in it. So the
-- bearing at radius r TRAILS the base bearing in proportion to how far out
-- it is and how fast the base is turning:
--
--   theta(r) = SweepAngle - WHIP_DRAG * (r - SWEEP_INNER) * sweepRate
--
-- WHIP_DRAG is set from the fastest sweep in the book (sweeppair, 300 deg
-- over 2.2 s = 2.380 rad/s): 0.0039 * (66 - 13) * 2.380 = 28.2 degrees of
-- trail at the tip, inside the 20-35 the design asks for. Constrict's slower
-- 1.587 rad/s gives 18.8, which is right - a slow squeeze should look less
-- whip-like. WHIP_RATE_MAX caps the curve at 35.5 degrees so a hitch or a
-- scripted snap can never coil the arm into something unreadable.
--
-- WHIP_TAU IS LOAD-BEARING AND IS NOT A FEEL KNOB. The server knows its own
-- angular rate exactly; the client can only differentiate the angle it is
-- easing toward SweepAngle at 55/s, so its rate lags by ~18 ms after any
-- step. Feeding those two different rates into the same drag term puts the
-- drawn arm and the hit arm 12.98 studs apart at the tip for the first
-- frames of every sweep. Running BOTH through one first-order filter fixes
-- it, because the filter becomes the slow pole and the 18 ms lag disappears
-- underneath it: worst-case tip divergence falls to 0.876 studs at r = 66,
-- against 1.70 for half the LOW sweep's 3.4-stud girth. At WHIP_TAU = 0.16
-- it is 1.71 and players eat hits from a curve they were never shown. It is
-- also the whole springback: the filtered rate decays through zero when the
-- sweep stops, so the tip unwinds over about a third of a second instead of
-- snapping flat.
BrinejawPath.WHIP_DRAG = 0.0039
BrinejawPath.WHIP_RATE_MAX = 3.0
BrinejawPath.WHIP_TAU = 0.35

-- Advance the shared angular-rate estimate. BOTH sides call this, with their
-- own raw rate, so the low-pass is identical on both. EXPONENTIAL, not
-- `rate * dt`: on a hitch the linear form races past its target, and a rate
-- that overshoots draws a curve nobody is standing in.
function BrinejawPath.stepSweepRate(state, rawRate: number, dt: number): number
	local previous = state.sweepRate or 0
	local a = 1 - math.exp(-math.max(dt, 0) / BrinejawPath.WHIP_TAU)
	state.sweepRate = previous + (rawRate - previous) * a
	return state.sweepRate
end

-- How far out the arm reaches right now. ONE function, so the drawn tip and
-- the lethal band cannot disagree - `spiral` contracts it with U and both
-- `sweptCyl` and `sweepHits` read it here.
function BrinejawPath.sweepReach(state): number
	if (state.attackKind or "") ~= "spiral" then
		return BrinejawPath.SWEEP_REACH
	end
	local closed = BrinejawPath.SWEEP_INNER + BrinejawPath.SPIRAL_CLOSE
	return BrinejawPath.SWEEP_REACH
		+ (closed - BrinejawPath.SWEEP_REACH) * smoothstep(math.clamp(state.attackU or 0, 0, 1))
end

-- THE ARM'S BEARING AT RADIUS `r`. The hit test and the drawing both call
-- this and nothing else, which is what makes the hitbox literally be the
-- curve on screen.
function BrinejawPath.sweepBearingAt(state, r: number): number
	local rate = math.clamp(state.sweepRate or 0, -BrinejawPath.WHIP_RATE_MAX, BrinejawPath.WHIP_RATE_MAX)
	local lead = math.max(r - BrinejawPath.SWEEP_INNER, 0)
	return (state.sweepAngle or 0) - BrinejawPath.WHIP_DRAG * lead * rate
end

-- A fresh pose state. `coil` counts DOWN as it loses its grip.
function BrinejawPath.newState(center: Vector3)
	return {
		center = center,
		coil = BrinejawPath.MAX_COIL,
		unwind = 0, -- 0 coiled, 1 tail fully off the tower
		sweepAngle = 0,
		sweepHeight = BrinejawPath.SWEEP_LOW,
		sweepRate = 0, -- DERIVED from sweepAngle; see the contract header
		slump = 0, -- 0 reared, 1 head down on the sand (the punish window)
		faceAngle = BrinejawPath.REST.BEARING - 0.8, -- who it is watching
		attackKind = "",
		attackU = 0,
		aimX = 0,
		aimZ = 0,
		time = 0,
	}
end

-- How far the whole stack has slid down the tower, in studs.
local function coilOffset(state): number
	local drop = (BrinejawPath.MAX_COIL - (state.coil or BrinejawPath.MAX_COIL)) * BrinejawPath.COIL_DROP
	-- CLAMPED to the beach. Unclamped, the third stance put 43% of the body
	-- underground (deepest 11.7 studs) and the death collapse buried two
	-- thirds of it 22 studs into the sand - for the last third of every
	-- fight. The stack can only slide as far as the bottom coil resting on
	-- the ground; past that it would be digging, not slipping.
	local floor = BrinejawPath.REST.BOTTOM_Y - BrinejawPath.sandY(0) - BrinejawPath.REST.CLEARANCE
	return math.clamp(drop, 0, math.max(floor, 0))
end

-- The coiled-on-the-lighthouse pose, arena-local.
local function restPoint(state, t: number): Vector3
	local rest = BrinejawPath.REST
	local drop = coilOffset(state)
	local topY = rest.TOP_Y - drop
	local bottomY = rest.BOTTOM_Y - drop

	local function helix(k: number): Vector3
		local y = topY + (bottomY - topY) * k
		local theta = rest.BEARING + rest.TURNS * TAU * k
		-- The coils TIGHTEN as the tail comes off the tower. Without this the
		-- 33 vertebrae on the drum move ~1 stud while the tail tip does 156
		-- studs/second - two thirds of the visible body inert during its own
		-- attack. It is also mechanically honest: it is holding on harder.
		local r = BrinejawPath.spireRadius(y) + rest.CLEARANCE * (1 - 0.10 * (state.unwind or 0))
		return Vector3.new(math.cos(theta) * r, y, math.sin(theta) * r)
	end

	-- The coil's own heading, by central difference. Both joins below have to
	-- leave on exactly the heading the helix arrives with, and `spireRadius` is
	-- a piecewise table - differentiating that by hand is how you get an
	-- expression that looks right and is off by a few degrees forever.
	local function helixTangent(k: number): Vector3
		local a, b = math.max(k - 1e-3, 0), math.min(k + 1e-3, 1)
		return (helix(b) - helix(a)) / (b - a)
	end

	if t <= rest.NECK_END then
		-- The reared neck: a quadratic sweep down onto the top coil. The
		-- control point sets the head's carry angle, so the skull looks out
		-- over the sand instead of at the sky.
		local u = t / rest.NECK_END
		-- IT WATCHES YOU. `faceAngle` tracks the nearest player (turn-rated
		-- by the server), but the neck is still wrapped round a lighthouse,
		-- so the swing is clamped to a cone off the coil's own bearing -
		-- beyond that it would have to tear off the tower. The slow sway and
		-- bob on top are what stop an idle colossus reading as a prop: this
		-- pose holds for most of the fight, and a serpent that never moves
		-- its head is a statue with a health bar.
		local anchor = rest.BEARING - 0.8
		local swing =
			math.clamp(wrapAngle((state.faceAngle or anchor) - anchor), -BrinejawPath.HEAD_TURN, BrinejawPath.HEAD_TURN)
		local theta = anchor + swing
		local headY = rest.HEAD_Y - drop
		local r = BrinejawPath.spireRadius(headY) + rest.CLEARANCE + rest.HEAD_OUT
		local top = Vector3.new(math.cos(theta) * r, headY, math.sin(theta) * r)
		local control = top - Vector3.new(math.cos(theta) * 11.0, 2.5, math.sin(theta) * 11.0)
		local start = helix(0)
		-- CUBIC, not quadratic. A quadratic has exactly one free control
		-- point, and it is already spent on the head's carry angle - so the
		-- far end arrived on whatever heading fell out of that choice, which
		-- was 64.5 degrees off the coil it was joining. A 64-degree corner in
		-- the neck, in the pose this boss holds for most of the fight. The
		-- second control point buys the join back: put it a third of the way
		-- down the helix's own entry tangent and the two meet on one heading.
		-- The head's carry angle is untouched - a cubic's start tangent is
		-- 3*(control - top) where the quadratic's was 2*(control - top), and
		-- only the direction of that vector was ever load-bearing.
		local enter = helixTangent(0) * (rest.NECK_END / (rest.HELIX_END - rest.NECK_END))
		local guide = start - enter / 3
		local v = 1 - u
		return top * v ^ 3 + control * (3 * v ^ 2 * u) + guide * (3 * v * u ^ 2) + start * u ^ 3
	end

	if t <= rest.HELIX_END then
		return helix((t - rest.NECK_END) / (rest.HELIX_END - rest.NECK_END))
	end

	-- Slack: the tail leaves the tower, spirals down and lies on the sand.
	--
	-- A HERMITE, so it leaves on the coil's heading too. The old form put the
	-- radius on k^0.75 and the height on k^0.6, and both of those have an
	-- INFINITE derivative at k=0: the tail left the bottom coil at 85.8
	-- degrees to it, the sharpest corner anywhere on the body. Starting from
	-- `helix(1)` rather than a re-derived point also closes a smaller gap -
	-- the old `inner` ignored the coils' tightening, so the two ends drifted
	-- apart by up to a third of a stud whenever the tail was unwinding.
	local k = (t - rest.HELIX_END) / (1 - rest.HELIX_END)
	local kScale = (1 - rest.HELIX_END) / (rest.HELIX_END - rest.NECK_END)
	local p0 = helix(1)
	local m0 = helixTangent(1) * kScale
	local endTheta = rest.BEARING + rest.TURNS * TAU + rest.TAIL_TURN * TAU
	local p1 = Vector3.new(
		math.cos(endTheta) * rest.TAIL_OUT,
		BrinejawPath.sandY(rest.TAIL_OUT) + 1.2,
		math.sin(endTheta) * rest.TAIL_OUT
	)
	-- The rattle still swings with the spiral as it settles, and lies flat.
	local swing = rest.TAIL_TURN * TAU * rest.TAIL_OUT * 0.35
	local m1 = Vector3.new(-math.sin(endTheta) * swing, 0, math.cos(endTheta) * swing)
	local k2, k3 = k * k, k * k * k
	return p0 * (2 * k3 - 3 * k2 + 1) + m0 * (k3 - 2 * k2 + k) + p1 * (3 * k2 - 2 * k3) + m1 * (k3 - k2)
end

-- The swept pose: the tail laid out along one bearing, at sweep height. `t`
-- is remapped so the further down the body you are, the further out you lie -
-- and the bearing now comes from `sweepBearingAt`, so the arm DRAGS.
-- Returned in UNWRAPPED cylindrical form, because the caller has to blend it
-- against a helix that has wound three turns. The branch (`turns`) is chosen
-- once per state, AT THE TIP: the tip is the part of the body that actually
-- swings, so it is the part that must take the short way round. Anchoring the
-- branch at the blend's start instead sent the tip 288 degrees the long way
-- for exactly the sweeps that end behind the coil. Everything nearer the
-- tower unwinds smoothly along the way, which is what peeling off a tower
-- looks like.
local function sweptCyl(state, t: number, blendStart: number): (number, number, number)
	local k = math.clamp((t - blendStart) / math.max(1 - blendStart, 1e-3), 0, 1)
	local reach = BrinejawPath.sweepReach(state)
	local r = BrinejawPath.SWEEP_INNER + (reach - BrinejawPath.SWEEP_INNER) * k
	local turns = math.round((restBearingRef(1.0) - BrinejawPath.sweepBearingAt(state, reach)) / TAU)
	local y = BrinejawPath.sandY(r) + (state.sweepHeight or BrinejawPath.SWEEP_LOW)
	return BrinejawPath.sweepBearingAt(state, r) + turns * TAU, r, y
end

-- HOW FAR INTO THE DEATH FALL, and the only reader of it. `state.fall` used
-- to be read here and written by nobody: the collapse eased four values that
-- were already at their targets and the killer watched a motionless skull for
-- 2.5 seconds. It is DERIVED now - kind "collapse" means fall = U - so the
-- loop is closed by the same channel every other attack rides. The raw field
-- is still honoured for a caller that has some other reason to drive it, but
-- nothing in the shipped code writes it.
function BrinejawPath.fallAmount(state): number
	if (state.attackKind or "") == "collapse" then
		return math.clamp(state.attackU or 0, 0, 1)
	end
	return math.clamp(state.fall or 0, 0, 1)
end

-- Where the head slumps when it loses its grip: off the tower, onto the sand,
-- jaw within reach. The neck drags after it, so the front of the body follows.
local function slumpPoint(state, t: number): Vector3
	local rest = BrinejawPath.REST
	-- It slumps toward whoever it was facing, so the punish window opens
	-- where the party already is instead of across the ring.
	local theta = state.faceAngle or (rest.BEARING - 0.8)
	-- The death collapse slides the head further out and settles it lower as
	-- the grip finally goes.
	local fall = BrinejawPath.fallAmount(state)
	local reach = 26.0 + 8.0 * fall
	local k = math.clamp(t / 0.30, 0, 1) -- the front 30% of the body comes down
	local bottomY = rest.BOTTOM_Y - coilOffset(state)
	local r = reach - (reach - (BrinejawPath.spireRadius(bottomY) + rest.CLEARANCE)) * k
	local y = BrinejawPath.sandY(r) + 2.6 - 1.8 * fall + 9.0 * k ^ 1.5
	return Vector3.new(math.cos(theta) * r, y, math.sin(theta) * r)
end

-- ------------------------------------------------------------ attack shapes

local function attackProgress(state): number
	return math.clamp(state.attackU or 0, 0, 1)
end

-- Fade in and out of an attack. `entry`/`exit` are fractions of U, so an
-- attack whose kind is cleared at U < 1 SNAPS - which is why the contract
-- makes running U to 1 the server's job, not a nicety.
local function attackEnvelope(u: number, entry: number, exit: number): number
	return math.min(smoothstep(u / math.max(entry, 1e-3)), smoothstep((1 - u) / math.max(exit, 1e-3)))
end

-- Aim as (bearing, radius), arena-local and clamped to the reachable ring.
local function aimCyl(state): (number, number)
	local ax, az = state.aimX or 0, state.aimZ or 0
	local r = math.sqrt(ax * ax + az * az)
	if r < 1e-3 then
		-- No aim written: strike where it is already looking, so a server
		-- that forgets AimX/AimZ gets a wrong-but-coherent attack rather
		-- than a head teleported to the tower's own axis.
		return state.faceAngle or (BrinejawPath.REST.BEARING - 0.8), BrinejawPath.AIM_MIN
	end
	return math.atan2(az, ax), math.clamp(r, BrinejawPath.AIM_MIN, BrinejawPath.AIM_MAX)
end

-- THE NECK, as one cylindrical arc from wherever the head is going to
-- wherever the body still grips the tower.
--
-- Cylindrical for the same reason the retraction is: a head striking a point
-- 170 degrees round from the coil it hangs off has to go AROUND the
-- lighthouse, and a straight lerp goes through it. LINEAR in k, not
-- smoothstepped: with all three of (theta, r, y) on the same parameter the
-- arc's tangent DIRECTION is constant along its length. Ease the parameter
-- instead and the r/theta terms flatten near the ends while the arch term
-- does not, and the neck stands itself dead vertical at exactly the joint.
--
-- `targetTheta` arrives UNWRAPPED and continuous in U (see the target
-- functions), and the anchor is unwrapped against the helix, so the arc
-- inherits the coil's winding and cannot flip branch. A head aiming behind
-- the tower therefore reaches round it rather than snapping through it, and
-- the neck carries whatever fraction of a turn that costs.
local function neckArc(state, target: Vector3, targetTheta: number, span: number, arch: number, t: number)
	local k = math.clamp(t / math.max(span, 1e-3), 0, 1)
	local aWrapped, r1, y1 = cylOf(restPoint(state, span))
	local t1 = restBearing(span, aWrapped)
	local _, r0, y0 = cylOf(target)
	local y = y0 + (y1 - y0) * k + arch * math.sin(math.pi * k)
	local r = r0 + (r1 - r0) * k
	-- A guard, not a shape: both endpoints stand clear of the masonry, so
	-- this only ever fires if someone widens AIM_MIN past its comment.
	return targetTheta + (t1 - targetTheta) * k,
		math.max(r, BrinejawPath.spireRadius(y) + BrinejawPath.REST.CLEARANCE),
		y
end

-- Where the skull is headed, per kind: (UNWRAPPED bearing, a point carrying
-- r and y). Each returns the rest pose's own head at U = 0 (and `belltoll`
-- again at U = 1), so the entry ramp has nothing to hide - and each expresses
-- its bearing as the rest head's plus a swing that never wraps, which is what
-- makes them continuous in U. Wrapping here put a 180-degree flip in the
-- middle of the bell's recoil: 15.6 studs of body in one step of U.
local function headRestCyl(state): (number, number, number)
	local wrapped, r, y = cylOf(restPoint(state, 0))
	return restBearing(0, wrapped), r, y
end

local function lungeTarget(state, u: number): (number, Vector3)
	local aimT, aimR = aimCyl(state)
	local th0, r0, y0 = headRestCyl(state)
	local swing = wrapAngle(aimT - th0)
	local cock = BrinejawPath.LUNGE_COCK_U
	if u <= cock then
		local a = smoothstep(u / cock)
		return th0 + swing * a, fromCyl(0, r0 + (BrinejawPath.LUNGE_COCK_R - r0) * a, y0 + BrinejawPath.LUNGE_RISE * a)
	end
	local b = smoothstep(math.clamp((u - cock) / (BrinejawPath.LUNGE_IMPACT_U - cock), 0, 1))
	local yTop = y0 + BrinejawPath.LUNGE_RISE
	local yLand = BrinejawPath.sandY(aimR) + BrinejawPath.LUNGE_SIT
	return th0 + swing,
		fromCyl(0, BrinejawPath.LUNGE_COCK_R + (aimR - BrinejawPath.LUNGE_COCK_R) * b, yTop + (yLand - yTop) * b)
end

local function bellStrikeLocal(): Vector3
	local bell = BrinejawPath.REST.BELL
	return Vector3.new(bell.X, bell.Y + BrinejawPath.BELL_LIFT, bell.Z)
end

local function bellTarget(state, u: number): (number, Vector3)
	local bT, bR, bY = cylOf(bellStrikeLocal())
	local th0, r0, y0 = headRestCyl(state)
	local swing = wrapAngle(bT - th0)
	-- The windup cocks PART OF THE WAY round toward the bell, so the strike
	-- reads as aimed rather than as a head that suddenly appears over it.
	local cockR, cockY = BrinejawPath.BELL_COCK_R, y0 + BrinejawPath.BELL_RISE
	local windup, impact = BrinejawPath.BELL_WINDUP_U, BrinejawPath.BELL_IMPACT_U
	if u <= windup then
		local a = smoothstep(u / windup)
		return th0 + swing * 0.55 * a, fromCyl(0, r0 + (cockR - r0) * a, y0 + (cockY - y0) * a)
	elseif u <= impact then
		local b = smoothstep((u - windup) / (impact - windup))
		return th0 + swing * (0.55 + 0.45 * b), fromCyl(0, cockR + (bR - cockR) * b, cockY + (bY - cockY) * b)
	end
	local c = smoothstep((u - impact) / (1 - impact))
	return th0 + swing * (1 - c), fromCyl(0, bR + (r0 - bR) * c, bY + (y0 - bY) * c)
end

-- `rear` is a DISPLACEMENT in (r, y) and touches no bearing at all - see the
-- REAR_* header. Returns how far out and how far up this body position is
-- pushed; both fade to nothing by REAR_SPAN, so the back half never moves.
local function rearOffset(state, t: number): (number, number)
	local shape = BrinejawPath.ATTACK.rear
	local u = attackProgress(state)
	local rise = smoothstep(math.clamp(u / BrinejawPath.REAR_U, 0, 1)) * attackEnvelope(u, shape.entry, shape.exit)
	local fade = 1 - smoothstep(math.clamp(t / shape.span, 0, 1))
	return BrinejawPath.REAR_OUT * rise * fade, BrinejawPath.REAR_LIFT * rise * fade
end

-- The submerged run, in UNWRAPPED cylindrical form. The middle third rides
-- UNDER the beach except where the travelling bulge lifts it proud - one
-- gaussian, so the hump has no corner anywhere and the body either side of it
-- is genuinely buried (sandY(r) - 4.5, i.e. 2.5 studs below the "< sandY - 2"
-- the design asks for, everywhere outside 8.7 studs of the crest).
--
-- The branch is chosen once, against the reference bearing at the middle of
-- the affected span, so the two ends of the run each unwind at most half a
-- turn - and they unwind where the edge weight is smallest.
local function undertowCyl(state, t: number): (number, number, number)
	local aimT, aimR = aimCyl(state)
	local inner = BrinejawPath.UNDER_INNER
	local k = math.clamp((t - BrinejawPath.UNDER_T0) / (BrinejawPath.UNDER_T1 - BrinejawPath.UNDER_T0), 0, 1)
	local travel = inner + (aimR - inner) * attackProgress(state)
	local r = inner + ((travel + BrinejawPath.UNDER_OVERRUN) - inner) * k
	local d = r - travel
	local hump = BrinejawPath.UNDER_HUMP
		* math.exp(-(d * d) / (2 * BrinejawPath.UNDER_SIGMA * BrinejawPath.UNDER_SIGMA))
	local ref = restBearingRef(0.5 * (BrinejawPath.UNDER_T0 + BrinejawPath.UNDER_T1))
	return ref + wrapAngle(aimT - ref), r, BrinejawPath.sandY(r) - BrinejawPath.UNDER_DEPTH + hump
end

-- ---------------------------------------------------------------- public

-- Where body position `t` (0 = snout, 1 = rattle) is right now, in world
-- space. Blends rest -> swept for the tail, rest -> slumped for the head,
-- rest -> attack for whichever span the current kind owns.
function BrinejawPath.pointAt(state, t: number): Vector3
	t = math.clamp(t, 0, 1)
	local point = restPoint(state, t)

	local kind = state.attackKind or ""
	local shape = BrinejawPath.ATTACK[kind]
	local mode = if shape then shape.mode else nil

	-- EVERY CYLINDRICAL BLEND BELOW IS GUARDED BY `w > 0`, and that is not
	-- just a shortcut. `fromCyl(cylOf(p))` is a round trip through atan2 and
	-- cos/sin, so entering cylindrical space when nothing is blending would
	-- move the rest pose by a float ulp or two for no reason at all. Guarded,
	-- the idle serpent and the slump come out BIT-IDENTICAL to what shipped
	-- (measured: 0 studs over 24 rest states and 36 slump states).
	local unwind = state.unwind or 0
	if unwind > 0 then
		-- The higher the unwind, the further UP the body the peel reaches, so
		-- the tail visibly comes off the tower turn by turn.
		local blendStart = 1.0 - 0.40 * unwind
		local w = smoothstep((t - blendStart) / 0.14) * unwind
		if w > 0 then
			-- CYLINDRICAL. The user's second complaint - the tail "moves back
			-- through the tower" - was this lerp: a positional blend between
			-- a point coiled at bearing 300 and an arm parked at bearing 120
			-- passes straight through the masonry. Measured worst case, over
			-- 24 park bearings: 7.98 studs INSIDE it, the body passing 0.24
			-- studs from the axis. In (theta, r, y) the same retraction never
			-- comes nearer than 5.04 studs OUTSIDE.
			local theta, r, y = cylOf(point)
			local aTheta, aR, aY = sweptCyl(state, t, blendStart)
			point = cylBlend(restBearing(t, theta), r, y, aTheta, aR, aY, w)
		end
	end

	local slump = state.slump or 0
	if slump > 0 and t < 0.34 then
		local w = smoothstep((0.34 - t) / 0.34) * slump
		point = point:Lerp(slumpPoint(state, t), w)
	end

	if mode == "neck" then
		local u = attackProgress(state)
		local w = attackEnvelope(u, shape.entry, shape.exit) * smoothstep((shape.span - t) / shape.span)
		if w > 0 then
			local targetTheta, target
			if kind == "lunge" then
				targetTheta, target = lungeTarget(state, u)
			else
				targetTheta, target = bellTarget(state, u)
			end
			local theta, r, y = cylOf(point)
			local aTheta, aR, aY = neckArc(state, target, targetTheta, shape.span, shape.arch, t)
			point = cylBlend(restBearing(t, theta), r, y, aTheta, aR, aY, w)
		end
	elseif mode == "undertow" and t > BrinejawPath.UNDER_T0 and t < BrinejawPath.UNDER_T1 then
		local edge = 0.06
		local w = attackEnvelope(attackProgress(state), shape.entry, shape.exit)
			* smoothstep(math.min((t - BrinejawPath.UNDER_T0) / edge, (BrinejawPath.UNDER_T1 - t) / edge))
		if w > 0 then
			local theta, r, y = cylOf(point)
			local aTheta, aR, aY = undertowCyl(state, t)
			point = cylBlend(restBearing(t, theta), r, y, aTheta, aR, aY, w)
		end
	elseif mode == "rear" then
		local dr, dy = rearOffset(state, t)
		if dr > 0 or dy > 0 then
			local theta, r, y = cylOf(point)
			point = fromCyl(theta, r + dr, y + dy)
		end
	end

	-- Ambient: a bulge travelling down the body, so it breathes even when
	-- nothing is happening. The amplitude GROWS toward the tail - a serpent
	-- is whip-like, and a uniform ripple reads as a wobbling pipe - while
	-- staying small enough that the server's analytic hit bands can ignore it.
	local time = state.time or 0
	local breath = math.sin(t * 9.0 - time * 1.7) * (0.45 + 1.05 * t * t)
	point += Vector3.new(0, breath, 0)

	-- The head's sway and bob live HERE, outside every blend, not inside the
	-- neck's own branch. Folded into one side of a lerp they were annihilated
	-- exactly when `slump` reached 1 - so the punish window, the state players
	-- stare at longest, was the deadest in the fight: 0.9 studs and 0.7
	-- degrees of yaw over eight seconds. This is the idiom ChainPose's header
	-- prescribes, and the bug it warns about, committed by the person who
	-- wrote the warning. EVERY attack kind added since rides outside these
	-- two blocks for the same reason: a lunged head planted on the sand for
	-- four seconds is the punish window all over again.
	local neckEnd = BrinejawPath.REST.NECK_END
	if t <= neckEnd then
		local k = 1 - t / neckEnd -- full at the snout, gone by the top coil
		local flat = Vector3.new(point.X, 0, point.Z)
		local side = if flat.Magnitude > 0.01 then Vector3.new(-flat.Z, 0, flat.X).Unit else Vector3.new(0, 0, 1)
		point += side * (math.sin(time * 0.55) * 2.1 * k)
		point += Vector3.new(0, math.sin(time * 0.83) * 1.25 * k, 0)
	end

	-- The last tenth flicks sideways: the rattle twitches. This is not
	-- decoration - it is the only part of the fight you are ever allowed to
	-- hit, so it has to be the part your eye is drawn to.
	if t > 0.86 then
		local k = (t - 0.86) / 0.14
		local flat = Vector3.new(point.X, 0, point.Z)
		if flat.Magnitude > 0.01 then
			local side = Vector3.new(-flat.Z, 0, flat.X).Unit
			point += side * (math.sin(time * 5.1 + t * 3.0) * 1.7 * k * k)
		end
	end

	return (state.center or Vector3.zero) + point
end

-- The direction "up-body" (toward the head) at `t` - what a piece's +X axis
-- points along (the pack's forward convention, assets/boss_gen.py).
function BrinejawPath.tangentAt(state, t: number): Vector3
	local step = 0.004
	local ahead = BrinejawPath.pointAt(state, math.max(t - step, 0))
	local behind = BrinejawPath.pointAt(state, math.min(t + step, 1))
	local delta = ahead - behind
	return if delta.Magnitude > 1e-4 then delta.Unit else Vector3.new(1, 0, 0)
end

-- The head's world position - all the server needs to stand its model on.
function BrinejawPath.headPosition(state): Vector3
	return BrinejawPath.pointAt(state, 0)
end

-- ------------------------------------------------------------ the hit twins
--
-- One rule below: every one of these is computed from the ten replicated
-- values and calls the SAME helpers the body curve calls. Nothing here has
-- its own copy of a radius, a height or a bearing.

-- Build the probe a stepped hit test needs. USE THIS, never a table literal:
-- the wedge-stepping loop in CreatureService assembles a probe by hand, and
-- the moment the arm gained a drag term a probe missing `sweepRate` began
-- testing a straight line against a curve that trails it by up to 35
-- degrees. Pass the bearing the step is testing; everything else is copied.
function BrinejawPath.sweepProbe(state, sweepAngle: number?)
	return {
		center = state.center,
		sweepAngle = sweepAngle or state.sweepAngle or 0,
		sweepHeight = state.sweepHeight,
		sweepRate = state.sweepRate,
		attackKind = state.attackKind,
		attackU = state.attackU,
	}
end

-- Is `position` caught by the sweep the state describes? Pure geometry, and
-- now against the CURVED arm: the bearing it compares against is the one
-- `sweptCyl` places the body on at this player's own radius, so the lane
-- you have to leave is exactly the lane you can see.
function BrinejawPath.sweepHits(state, position: Vector3, girth: number): boolean
	local center = state.center or Vector3.zero
	local dx, dz = position.X - center.X, position.Z - center.Z
	local r = math.sqrt(dx * dx + dz * dz)
	if r < BrinejawPath.SWEEP_INNER or r > BrinejawPath.sweepReach(state) then
		return false
	end
	-- Angular half-width shrinks with radius so the arm's real thickness is
	-- constant - being far out must not mean being easier to clip.
	local half = math.atan2(girth, math.max(r, 1))
	local delta = math.abs(wrapAngle(math.atan2(dz, dx) - BrinejawPath.sweepBearingAt(state, r)))
	if delta > half then
		return false
	end
	local armY = center.Y + BrinejawPath.sandY(r) + (state.sweepHeight or BrinejawPath.SWEEP_LOW)
	return math.abs(position.Y - armY) <= girth
end

-- `spiral` IS a sweep with a contracting reach, so it is the same test. The
-- alias exists so a caller reading the attack book finds the name it expects
-- and cannot invent a second, drifting copy.
function BrinejawPath.spiralHits(state, position: Vector3, girth: number): boolean
	return BrinejawPath.sweepHits(state, position, girth)
end

-- Where the lunging skull is: the head of the body curve, which is the same
-- point the client draws, ambient sway and all. Park the authority model on
-- this and the thing you swing at is the thing you see.
function BrinejawPath.lungeHeadPosition(state): Vector3
	return BrinejawPath.pointAt(state, 0)
end

-- The blow's centre on the sand - analytic, so the damage test does not
-- inherit the head's 2-stud idle sway.
function BrinejawPath.lungeImpactPoint(state): Vector3
	local aimT, aimR = aimCyl(state)
	local center = state.center or Vector3.zero
	return center + fromCyl(aimT, aimR, BrinejawPath.sandY(aimR))
end

-- Caught by the plant? A disc on the sand, live from the strike onward.
function BrinejawPath.lungeHits(state, position: Vector3, radius: number): boolean
	if (state.attackKind or "") ~= "lunge" or attackProgress(state) < BrinejawPath.LUNGE_COCK_U then
		return false
	end
	local at = BrinejawPath.lungeImpactPoint(state)
	local dx, dz = position.X - at.X, position.Z - at.Z
	if dx * dx + dz * dz > radius * radius then
		return false
	end
	return math.abs(position.Y - at.Y) <= 8.0
end

-- WHERE THE BULGE IS, and its progress. The server's damage disc and the
-- client's dust plume both ride this - one call, one point, no second copy
-- of "how fast does it travel".
function BrinejawPath.undertowPoint(state): (Vector3, number)
	local aimT, aimR = aimCyl(state)
	local u = attackProgress(state)
	local travel = BrinejawPath.UNDER_INNER + (aimR - BrinejawPath.UNDER_INNER) * u
	local center = state.center or Vector3.zero
	return center + fromCyl(aimT, travel, BrinejawPath.sandY(travel)), u
end

function BrinejawPath.undertowHits(state, position: Vector3, radius: number): boolean
	if (state.attackKind or "") ~= "undertow" then
		return false
	end
	local at = BrinejawPath.undertowPoint(state)
	local dx, dz = position.X - at.X, position.Z - at.Z
	if dx * dx + dz * dz > radius * radius then
		return false
	end
	-- Generous vertically: the crest lifts 2.6 studs proud and a player it
	-- passes under is thrown, not brushed.
	return math.abs(position.Y - at.Y) <= 6.0
end

-- The bell's crown, in world space. The rings are server/client territory;
-- this is only where the head lands and when (BELL_IMPACT_U).
function BrinejawPath.bellStrikePoint(state): Vector3
	return (state.center or Vector3.zero) + bellStrikeLocal()
end

-- The reared skull, for a camera to frame or a model to sit on.
function BrinejawPath.rearHeadPosition(state): Vector3
	return BrinejawPath.pointAt(state, 0)
end

-- ====================================================================== --
-- THE EVENT SHAPES
-- ====================================================================== --
--
-- Everything above is the POSE channel: shapes expressible as ten attributes
-- on the model. The five attacks below are not - a wave crossing the arena,
-- a seeded bombardment, expanding rings, the flood, are events broadcast
-- through `fireEvent` with a payload. They live here anyway, and for exactly
-- the reason the pose twins do: THE THING YOU DODGE AND THE THING YOU SEE
-- MUST BE ONE FUNCTION. The server's damage test and the client's marker
-- both call the helpers in this section and neither one re-derives a radius,
-- a bearing or a placement of its own.
--
-- Two rules that make that hold across the wire:
--   * every `start`/`impactAt` is a `Workspace:GetServerTimeNow()` value, so
--     a client that adopts the fight mid-attack computes the same phase as
--     one that saw it begin. No helper here takes a duration-from-receipt.
--   * anything scattered is scattered by the LCG below off the payload's
--     `seed`, consumed in a documented order, so both sides derive the same
--     placements without the placements having to be sent.
--
-- Arena data comes IN. `waveSheltered` takes the cover list rather than
-- reading BossArenas, because this module is required by the pose math on
-- both sides and a config dependency here would be a cycle waiting to
-- happen. Callers pass `BossArenas.items[islandId].cover` plus the implicit
-- spire entry { offset = Vector3.zero, radius = 9 } - the lighthouse is
-- cover too, and it is the one piece no table lists.

-- The shared deterministic RNG: a 31-bit LCG, and the ONE copy of it.
-- `math.random` cannot be used for any of this - the two sides would seed
-- differently and the client would draw a bombardment that lands somewhere
-- else. Returns the next seed alongside its 0..1 draw so a caller threads
-- the state explicitly and can never accidentally consume out of order.
function BrinejawPath.lcg(seed: number): (number, number)
	local nextSeed = (seed * 1103515245 + 12345) % 2147483648
	return nextSeed, nextSeed / 2147483648
end

-- --------------------------------------------------------------- the wave

-- HOW DEEP THE LEE OF A ROCK IS, and how much wider than the rock itself.
-- Exported because the boolean and the DRAWN wedge have to be the same
-- rectangle: the client shades the safe ground behind every cover entry and
-- the server asks whether a root is standing in it, and if those two numbers
-- lived in two files the shadow would be a suggestion instead of a promise.
-- 16 studs is about a second of walking, so a player who reaches cover as the
-- front arrives is inside it rather than one stride past; 1.2 is the pad that
-- keeps a body hugging the rock's edge from being clipped by its own width.
BrinejawPath.WAVE_SHELTER_DEPTH = 16.0
BrinejawPath.WAVE_SHELTER_PAD = 1.2

-- Where the wave's front is along its own axis at `now`, or nil once it has
-- left the arena. The front starts at -reach at `start` and travels at
-- `speed`, so this is the whole of the wave's clock: both sides ask it, and
-- the server damages a player in the frame the front's `along` passes theirs.
-- (`_bearing` is in the signature and unused ON PURPOSE: the front's position
-- is a scalar along its own axis, and every caller already has to hand the
-- bearing to `waveSheltered` next to this call. Dropping the argument would
-- let one side pass four numbers and the other five to the same-looking
-- helper, which is the kind of drift this whole section exists to prevent.)
function BrinejawPath.waveFront(_bearing: number, speed: number, reach: number, start: number, now: number): number?
	local along = -reach + speed * (now - start)
	if along > reach then
		return nil
	end
	return along
end

-- IS `worldPos` IN SOMETHING'S LEE? The wave is TALL - jumping does not
-- evade it - so this is the only answer to it, and it is the same function
-- that shades the ground.
--
-- `cover` is the arena's list ({ offset (arena-local XZ), radius }, extra
-- fields ignored), `center` the arena's world centre, `bearing` the direction
-- the wave TRAVELS. A point is sheltered when it stands BEHIND a piece
-- (along > 0, i.e. the wave reached the rock first) and no further behind it
-- than the lee runs, and within the piece's own width of its centre line.
function BrinejawPath.waveSheltered(cover, center: Vector3, bearing: number, worldPos: Vector3): boolean
	local dirX, dirZ = math.cos(bearing), math.sin(bearing)
	-- The perpendicular of (cos, sin) in the XZ plane, and the same one the
	-- client lays its wall's slabs along.
	local perpX, perpZ = -dirZ, dirX
	for _, piece in cover do
		local offset = piece.offset or Vector3.zero
		local dx = worldPos.X - (center.X + offset.X)
		local dz = worldPos.Z - (center.Z + offset.Z)
		local along = dx * dirX + dz * dirZ
		if along > 0 and along <= BrinejawPath.WAVE_SHELTER_DEPTH then
			local perp = math.abs(dx * perpX + dz * perpZ)
			if perp <= (piece.radius or 0) + BrinejawPath.WAVE_SHELTER_PAD then
				return true
			end
		end
	end
	return false
end

-- --------------------------------------------------------------- the rain

-- THE BOMBARDMENT, placed. One chunk per entry: `pos` is arena-local XZ (Y is
-- 0 - the ground under it is `sandY(r)`, which every caller already has, and
-- shipping a height here would be the same number in two homes), `impactAt`
-- is the server clock at which it lands and the server's damage circle opens.
--
-- THE LCG IS CONSUMED IN THIS ORDER AND NO OTHER: per chunk, u1 then u2.
-- Insert a third draw anywhere in this loop and every chunk after it moves on
-- one side of the wire and not the other.
--
-- The radius is sqrt-interpolated between inner^2 and outer^2 because a
-- uniform draw on r piles the bombardment up at the inner edge: area grows
-- with r^2, so uniform-in-r is 2x denser at 12 studs than at 64, and the band
-- reads as a ring around the tower rather than as a sector under it.
function BrinejawPath.rainChunks(payload)
	local seed = payload.seed or 0
	local inner, outer = payload.inner or 12, payload.outer or 64
	local sector, width = payload.sector or 0, payload.width or 2.1
	local start, stagger = payload.start or 0, payload.stagger or 0.22
	local chunks = {}
	for i = 1, math.max(math.floor(payload.count or 0), 0) do
		local u1, u2
		seed, u1 = BrinejawPath.lcg(seed)
		seed, u2 = BrinejawPath.lcg(seed)
		local angle = sector - width * 0.5 + u1 * width
		local r = math.sqrt(inner * inner + (outer * outer - inner * inner) * u2)
		chunks[i] = {
			pos = Vector3.new(math.cos(angle) * r, 0, math.sin(angle) * r),
			impactAt = start + (i - 1) * stagger,
		}
	end
	return chunks
end

-- --------------------------------------------------------------- the rings

-- The bell's rings leave the tower one every `gap` seconds and run outward at
-- `speed`. Ring `k` (1-based) at `now`, or nil while it has not left the
-- masonry yet and once it is past the reef.
--
-- The bounds are the arena's, not the ring's: 4 studs is inside the
-- lighthouse's own footprint (spireRadius at the sand is 8.5) so nothing is
-- ever drawn or hit-tested inside the tower, and 78 is past where a player
-- can stand. Both sides read the same nil, so a ring that has expired stops
-- being drawn in the same frame it stops hitting.
function BrinejawPath.ringRadius(start: number, speed: number, gap: number, k: number, now: number): number?
	local r = speed * (now - (start + (k - 1) * gap))
	if r < 4.0 or r > 78.0 then
		return nil
	end
	return r
end

-- --------------------------------------------------------------- the surge

-- TIDAL SURGE'S MASONRY, as a rain payload. The set-piece drops rubble around
-- the tower for its whole duration, and rather than have the server tick a
-- second scatter and the client guess at it, BOTH SIDES BUILD THIS TABLE HERE
-- and hand it to `rainChunks`. The numbers are the contract's and are not
-- knobs: a full circle (the surge has no sector - it is raining everywhere
-- you can still stand), the 10..24 band that is the dry ground left inside
-- floodR, one chunk every 0.45 s for as long as the flood holds, and a 1.0 s
-- marker lead, which is the shortest tell a player pinned inside a shrinking
-- band can still answer.
function BrinejawPath.surgeRain(payload)
	local duration = payload.duration or 10
	return {
		seed = payload.seed or 0,
		sector = 0,
		width = TAU,
		inner = 10,
		outer = 24,
		count = math.floor(duration / 0.45),
		start = (payload.start or 0) + 0.8,
		stagger = 0.45,
		fall = 1.0,
		radius = 6,
	}
end

return BrinejawPath
