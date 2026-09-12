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
-- ...AND ONE ELEVENTH THAT IS NOT ON THE WIRE AND NEVER WILL BE:
--
--   Entry          entry          nil = the fight pose; 0..1 = how far along
--                                 its ARRIVAL this animal is (cutscene only)
--
-- `Entry` is written by a client cutscene onto a client-only stand-in and by
-- NOTHING ELSE. THE SERVER MUST NEVER SEE `state.entry`: it builds its pose
-- with `newState`, which has no such field, so every server frame takes the
-- `entry == nil` path and every hit twin below is computed from the ten
-- attributes exactly as before. The client collapses the attribute back to
-- nil at >= 0.995 (BrinejawBodyController.drawBody), so the handoff to the
-- real rig is enforced rather than trusted. See "the ENTRY channel" below for
-- the parametrisation and why the track is walked tail-end first.
--
-- Aim is arena-local (relative to `state.center`, the tower's FOOT), because
-- `center` is already replicated as PoseCenter and a world-space aim would
-- be the same number written twice.
--
-- THREE FIELDS ARE NOT ATTRIBUTES, ON PURPOSE:
--
--   state.sweepBranch  which way round the tail is wound during a sweep,
--                      stepped by `stepSweepBranch` and derived from
--                      SweepAngle and Unwind, both of which already cross the
--                      wire. It is a DRAWING value and nothing else - no hit
--                      test reads it - and a caller that never steps it gets
--                      the old per-frame rounding. See stepSweepBranch for
--                      the 78.20-stud frame that made it necessary.
--
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
--   "coilslam"  a mid-body loop rises off the tower and CRASHES along the
--               line the aim points down, then lies there as a melee window.
--               Aim = the BEARING only (atan2 of AimZ/AimX); the magnitude is
--               unused, because the bar's length is SLAM_INNER..SLAM_OUTER
--               and not the aim's own radius. Freeze the aim at U = 0.
--               U 0..0.40 rise: the loop peels off the drum, GROWS out along
--                          the bearing and lifts to SLAM_LIFT. The client's
--                          line marker is live for all of it.
--               U 0.40..0.50 crash. THE BLOW LANDS AT 0.50 (SLAM_IMPACT_U),
--                          so the countdown ends there.
--               U 0.50..0.85 the fallen loop LIES ON THE SAND, underside
--                          0.13..0.68 studs proud of the beach the whole way
--                          out - a MELEE WINDOW on the body. The server makes
--                          the creature damageable at full rate here and
--                          parks the hittable proxy on `coilslamPoint`.
--               U 0.85..1  the loop is dragged back to the tower and the pose
--                          hands the body back to the coils. A DECLARED FAST
--                          span - 6.46 studs a step at 240 - and it cannot be
--                          made slower without lifting the bar off the sand
--                          while the window is still open.
--               THE LETHAL SHAPE IS A RAY, NOT A LINE, and this is deliberate
--               and must not be "fixed" for symmetry: the drawn loop is a
--               narrow V that leaves the tower on the aim bearing and comes
--               back, so there is NO BODY on the far side of the tower.
--               `coilslamHits` therefore tests distance along the aim RAY,
--               r 14..62 (SLAM_INNER..SLAM_OUTER), within COILSLAM_BAND (5.0)
--               of it. Widening it to the full line through the tower would
--               damage ground this file has not drawn anything on.
--               Twins: coilslamHits, coilslamPoint.
--
--   "bite"      the reactive close-range snap. NOT in any phase list: it
--               fires on its own cooldown when somebody stands inside ~14
--               studs of the tower. Aim = where the jaws shut, on the sand,
--               and `aimCyl` clamps it to AIM_MIN as it does for the lunge.
--               U 0..0.30  rear: the head cocks UP over the aim (it is
--                          already on top of you - it does not draw back).
--               U 0.30..0.45 snap. THE JAWS SHUT AT 0.45 (BITE_IMPACT_U),
--                          BITE_RADIUS (6.0) around the aim point.
--               U 0.45..0.75 the head HANGS LOW, jaw 0.91 studs off the sand:
--                          a mini punish window. Hold U at 0.75 to keep it
--                          open; the height comes from `headSitY`, so the jaw
--                          is on the beach and not in it.
--               U 0.75..1  recover back up the tower.
--               Twins: biteHits, biteHeadPoint.
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
-- AND THE OTHER HALF OF THE FIGHT. Several of Brinejaw's attacks are not
-- poses - a wave crossing the arena, a seeded bombardment, the bell's rings,
-- the flood, the polyps, the spine volley - so they ride `fireEvent` payloads
-- instead of the ten attributes. Their geometry still lives in this file,
-- under "THE EVENT SHAPES" at the bottom: `lcg`, `waveRing`, `waveSafe`,
-- `spineFront`, `spineLane`, `spineHits`, `rainChunks`, `ringRadius`,
-- `surgeRain`. Same law, different channel.
--
-- THE RIPTIDE IS A RING NOW. `waveRing` + `waveSafe` replace the directional
-- `waveFront` + `waveSheltered`: the wave leaves the tower as an expanding
-- ring with two GAP ARCS the player runs to, and safety is a BEARING question
-- with the old lee kept as the secondary answer. The two old functions are
-- still here and still work - the client is swapped over in the next pass and
-- they go with it. Do not add a third wave shape in the meantime.

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
	-- 0.85 -> 0.55, and only because the slack is now a real spiral. The old
	-- world-space Hermite reached the sand by CUTTING ACROSS (see the slack
	-- section below), so 0.85 of a turn cost 49 studs of body. Wound honestly
	-- at a growing radius the same 0.85 costs 111 studs - a third of the
	-- serpent sprawled over the beach, against 18% before. 0.55 puts the
	-- slack at 70 studs / 24% of a 288-stud body, which is the silhouette
	-- that shipped (49 / 18% of 268) with the wander taken out of it.
	TAIL_TURN = 0.55,
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

-- ------------------------------------------------------- the drawn skull
--
-- THE HEAD IS NOT AT `pointAt(0)` AND THE POSE MATH HAS TO KNOW THAT. The
-- chain's t=0 is the NECK JOINT; the client hangs the skull off a frame
-- HEAD_LEAD studs further along the tangent (the mesh is centred on its neck
-- joint and reaches forward from there, assets/boss_gen.py's HANDOFF), and
-- the mesh itself hangs HEAD_UNDER studs below that frame's axis. Both live
-- HERE rather than in the controller, because a pose that wants to put the
-- jaw on the sand is doing arithmetic with them - and a drawing constant the
-- pose math cannot see is the "one value, two homes" defect this file exists
-- to prevent. BrinejawBodyController reads these two and keeps no copy.
--
-- MEASURED, from boss_gen's BJ_JAW: the jaw's rings run to cz - hh =
-- -1.8 - 1.7 = -3.5 in mesh studs, so at HEAD_SCALE the solid underside of
-- the skull sits 3.5 * 1.35 = 4.73 studs below the frame. (The two chin
-- barbels are thinner and longer - 5.4 mesh studs, 7.3 scaled - and are
-- DELIBERATELY allowed to trail in the sand. They are 0.3-stud spikes; a sit
-- height that floated them would stand the whole skull 2.6 studs off the
-- beach and put the jaw out of melee reach.)
BrinejawPath.HEAD_LEAD = 8.9
BrinejawPath.HEAD_SCALE = 1.35
BrinejawPath.HEAD_UNDER = 3.5
-- Daylight under the jaw when the head is resting on the sand. 0.95, not the
-- 0.3 the eye needs, because the ambient bob is added AFTER every pose: at
-- full slump the head's own bob is damped to 1.25 * 0.15 = 0.19 and the
-- body-wide breath is 0.45 at the snout, so the worst downswing is 0.64 and
-- the jaw still clears by 0.31 at the bottom of every breath.
BrinejawPath.HEAD_CLEAR = 0.95

-- WHERE A RESTING HEAD'S FRAME MUST SIT, at radius `r` from the tower: high
-- enough that the skull's lowest solid point rests ON the beach with
-- HEAD_CLEAR of daylight, and no higher. Every pose that lays the head down
-- calls this - the slump, the bite's low hang - so "on the sand" means one
-- number in one place.
--
-- It is only the truth if the frame is LEVEL there, which is why every such
-- pose also runs flat for its first few studs (see `slumpPoint`): the client
-- places the skull along the TANGENT, so a curve that dives at t=0 drives the
-- skull into the beach however high this puts the joint. Measured on the
-- pose that shipped: the stagger's skull sat 10.11 studs UNDER the sand.
function BrinejawPath.headSitY(r: number): number
	return BrinejawPath.sandY(r) + BrinejawPath.HEAD_UNDER * BrinejawPath.HEAD_SCALE + BrinejawPath.HEAD_CLEAR
end

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
--   "coilslam" replace a mid-body span with a loop that rises and crashes
--
-- `level` is the fraction of a NECK span that runs FLAT out of the head
-- before the arc starts climbing to the coil. It is only meaningful for a
-- kind that PLANTS the skull, and it exists because the client draws the head
-- HEAD_LEAD studs along the tangent: a neck that starts climbing at k = 0
-- takes the skull down with it (the shipped lunge planted its jaw 4.5 studs
-- inside the beach). `belltoll` strikes upward and has none.
BrinejawPath.ATTACK = {
	lunge = { mode = "neck", span = 0.26, entry = 0.10, exit = 0.28, arch = 5.0, level = 0.22 },
	belltoll = { mode = "neck", span = 0.24, entry = 0.10, exit = 0.14, arch = 7.0 },
	rear = { mode = "rear", span = 0.50, entry = 0.16, exit = 0.16 },
	undertow = { mode = "undertow", entry = 0.30, exit = 0.30 },
	spiral = { mode = "sweep" },
	collapse = { mode = "fall" },
	-- The two new kinds. Their exits are sized by the same audit as every
	-- other row - the shortest fade that keeps the worst single-step body jump
	-- under 1.5 studs at 240 steps of U - and the numbers are in the header.
	-- ENTRY 0.35 IS SIZED, NOT PICKED: the loop has to unwind off the drum and
	-- reach the reef, which is the undertow's problem exactly, and the
	-- undertow's answer (0.30) is the neighbourhood. At 0.10 the entry moved
	-- 6.31 studs in one step of U at 240 steps; at 0.35 it moves 2.89. The
	-- EXIT is pinned at 0.15 by the contract - the fallen loop is a melee
	-- window until U 0.85 and the recover is what is left - so the recover is
	-- a DECLARED FAST span at 6.46 studs a step, in the same class as the
	-- undertow's 4.10 dive. Shortening it further would mean lifting the bar
	-- off the sand while the window is still open, which is worse.
	coilslam = { mode = "coilslam", entry = 0.35, exit = 0.15 },
	bite = { mode = "neck", span = 0.20, entry = 0.10, exit = 0.25, arch = 3.0, level = 0.22 },
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
-- LUNGE_SIT IS GONE, and its 2.4 with it. It was the skull CENTRE's height
-- above the sand, picked so an R15 root at ~3.0 was level with it - but the
-- centre it moved was the NECK JOINT's, and the client hangs the skull 8.9
-- studs further along the tangent with the mesh's own 4.73 below that. The
-- planted head therefore sat at Y = 0.37 against a beach at 1.60: the punish
-- window's jaw was 4.5 studs inside the sand. The plant now lands on
-- `headSitY(aimR)`, which is derived from the mesh, and the neck's `level`
-- run keeps the lead from diving into the beach on the way. The window's
-- meaning survives intact - the JAW is what melee swings at and it is now the
-- thing at root height.

-- THE BLOW'S FOOTPRINT, and the bulge's. These are radii the SERVER passes to
-- `lungeHits` / `undertowHits` and the CLIENT draws its countdown ring and its
-- dust plume at, so they live here for the same reason every other number in
-- this file does: a book row carrying its own radius would put the drawn
-- circle and the lethal one in two files, and the drawn one is a promise.
-- Pass these to the hit twins; do not pass a row's own number.
-- 9.0 is a little over the planted skull's own width (the head mesh is ~15
-- long at HEAD_SCALE 1.35 and `headSitY` rests it on the beach), so the disc
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

-- ---------------------------------------------------------------- the slam
--
-- THE COIL SLAM's numbers. The loop is the body between SLAM_T0 and SLAM_T1 -
-- the span just behind the neck, so the head is still free to watch the arena
-- while its own middle is lying on the beach, and so the span the `undertow`
-- owns (0.34..0.67) is not the one this kind reaches for. Overlapping spans
-- would be harmless (only one kind is ever live) but they would make two
-- attacks look like the same attack.
BrinejawPath.SLAM_T0 = 0.26
BrinejawPath.SLAM_T1 = 0.60
BrinejawPath.SLAM_INNER = 14.0 -- where the legs leave the tower's foot
BrinejawPath.SLAM_OUTER = 62.0 -- how far down the aim line the tip reaches
-- Half the angle between the loop's two legs: 3.5 degrees, so the legs run
-- 3.8 studs either side of the aim line at the tip and converge on the
-- tower's foot. An ANGLE rather than a width - see `coilslamCyl`.
BrinejawPath.SLAM_SPLAY = math.rad(3.5)
BrinejawPath.SLAM_LIFT = 26.0 -- how high the loop rises before it crashes
-- The fallen loop's CENTRE height: the drawn vertebra's own half-girth at
-- mid-body (2.5 authored, 2.0 after the client's taper at t ~ 0.45), so the
-- body lies ON the beach. Measured over the whole fallen span (the loop
-- proper, inside the 0.06 edge blends that reach back up to the coils): at
-- 2.2 the underside ran -0.37..0.18, i.e. a third of a stud of body inside
-- the sand at the near end where the beach is highest; at 2.7 it runs
-- 0.13..0.68 studs proud along the whole bar.
BrinejawPath.SLAM_SIT = 2.7
BrinejawPath.SLAM_RISE_U = 0.40 -- the loop is at full height here
BrinejawPath.SLAM_IMPACT_U = 0.50 -- IT LANDS HERE; the countdown ends here
BrinejawPath.SLAM_LIE_U = 0.85 -- the melee window closes and the recover starts
-- HOW WIDE THE BAR IS, and the one number the marker and the damage share.
-- 5.0 is a little over the legs' own half-spread plus a vertebra's girth, so
-- the lethal band is the drawn loop and not a studs-wide invisible margin.
-- The client resolves this name; do not give the row its own.
BrinejawPath.COILSLAM_BAND = 5.0
BrinejawPath.COILSLAM_HALF = BrinejawPath.COILSLAM_BAND -- the other name the client tries

-- ---------------------------------------------------------------- the bite
--
-- THE REACTIVE SNAP. It is not in any phase list (Bosses' own header says so):
-- it fires when somebody stands inside ~14 studs of the tower for two seconds,
-- so its aim is always close in and `aimCyl` clamps it to AIM_MIN anyway.
BrinejawPath.BITE_REAR_U = 0.30 -- the head cocks over the aim
BrinejawPath.BITE_IMPACT_U = 0.45 -- THE JAWS SHUT HERE
BrinejawPath.BITE_HANG_U = 0.75 -- the low hang ends; the recover begins
BrinejawPath.BITE_COCK_R = 18.0
BrinejawPath.BITE_RISE = 8.0 -- a short rear, not the lunge's 12
-- The snap's footprint, passed to `biteHits` by the server and drawn by the
-- client. Small: this is a bite, and its whole read is "do not stand on the
-- tower's foot", not "leave the arena".
BrinejawPath.BITE_RADIUS = 6.0

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

-- WHICH WAY ROUND THE TAIL IS WOUND, and why it may not be re-decided
-- mid-sweep. `sweptCyl` has to express the arm's bearing on the same
-- unwrapped branch as the three-turn helix it is blending away from, and the
-- shipped code picked that branch by ROUNDING to the nearest turn every
-- frame. Rounding is a step function: measured on a plain `whip` (arc 340
-- degrees, 3.4 s) the branch fell from 5 to 4 as the arm passed the coil's
-- antipode at t = 1.083 s, and in that ONE FRAME the drawn body moved 20.75
-- studs at link 35 and the chain's own length jumped to 310. That is the
-- user's "the tail swipe's animation is not smooth at all", and it happens
-- once in every whip in the book, because every one of them sweeps more than
-- 180 degrees.
--
-- The jump size is not tunable, either: a branch change rotates the blended
-- bearing by 2*pi*w, so it is invisible where the weight is 0 or 1 and worst
-- (a diameter) at w = 0.5, which is the middle of the peel band. No choice of
-- anchor removes it - the arm genuinely travels more than half a turn.
--
-- SO THE TAIL WINDS INSTEAD, which is also what a tail attached to a coil
-- does: the branch is LATCHED while any of the body is off the tower and only
-- re-taken when the tail is home (unwind at rest), where the peel weight is
-- ~0 and re-taking it costs 0.004 * 2*pi*r = under a stud. Both sides may
-- call this; the CLIENT must, because it draws the band. The server does not
-- have to and today does not: it reads `pointAt` only at t = 0 (the head) and
-- the peel never reaches past t = 0.6, and NO HIT TEST READS THE BRANCH -
-- `sweepHits` asks `sweepBearingAt`, which has no branch in it. A caller that
-- never steps it gets the old per-frame rounding, unchanged.
--
-- Derived, not replicated, for the same reason `sweepRate` is: it is a
-- function of SweepAngle and Unwind, both of which already cross the wire.
BrinejawPath.SWEEP_BRANCH_HOLD = 0.004 -- unwind at or below this is "home"
-- ...and the safety valve. A latched branch lets the tail wind with the arm,
-- which is right for one sweep and for a chained pair (the longest in the
-- book is doublewhip + whipback, 600 degrees = 1.67 turns). Past 2.5 turns
-- something is driving the arm in one direction forever, and a tail wound
-- three times round its own peel band is worse than the snap.
BrinejawPath.SWEEP_WIND_MAX = 2.5
function BrinejawPath.stepSweepBranch(state): number
	local reach = BrinejawPath.sweepReach(state)
	local ideal = (restBearingRef(1.0) - BrinejawPath.sweepBearingAt(state, reach)) / TAU
	local held = state.sweepBranch
	if
		held == nil
		or (state.unwind or 0) <= BrinejawPath.SWEEP_BRANCH_HOLD
		or math.abs(ideal - held) > BrinejawPath.SWEEP_WIND_MAX
	then
		state.sweepBranch = math.round(ideal)
	end
	return state.sweepBranch
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
	-- A HERMITE IN CYLINDRICAL SPACE, and the space is the fix. The Hermite
	-- itself was already right about the JOIN - it leaves on the coil's own
	-- heading, where the k^0.75 / k^0.6 form it replaced left the bottom coil
	-- at 85.8 degrees - but it ran in world XYZ, and a cubic in XZ whose start
	-- tangent is TANGENTIAL (the coil is going round the tower at that
	-- instant) and whose endpoint is 31 studs out cannot help bulging and then
	-- cutting back. Measured on the shipped curve at rest, radius by body
	-- position: 11.33 at t=0.74, out to 13.29 at 0.78, back IN to 9.77 at 0.86
	-- (1.53 studs off the masonry, tighter than the coils' own 3.4), and only
	-- then out to 31. That S is the user's "the last coil of the tail isn't
	-- around the building": the body swings off the drum, comes back at it,
	-- and leaves - one loop that visibly grips nothing. It is also the whole
	-- reason the bottom coil READS as detached while measuring fine: the three
	-- turns on the drum are within 3.35..3.43 of clearance at every stance,
	-- so nothing was ever wrong with them.
	--
	-- In (theta, r, y) the same four boundary conditions describe a continuing
	-- SPIRAL: bearing keeps winding, radius grows monotonically off the drum,
	-- height falls to the sand. Same tangent at the join (the helix's own
	-- cylindrical derivatives, taken numerically so the piecewise
	-- `spireRadius` is differentiated correctly), same endpoint, no bulge and
	-- no cut-back - the tail leaves only after the third turn is complete.
	local k = (t - rest.HELIX_END) / (1 - rest.HELIX_END)
	local kScale = (1 - rest.HELIX_END) / (rest.HELIX_END - rest.NECK_END)
	local p0 = helix(1)
	local theta0 = rest.BEARING + rest.TURNS * TAU
	local r0 = math.sqrt(p0.X * p0.X + p0.Z * p0.Z)
	local y0 = p0.Y
	-- The helix's own rates, expressed per unit of the SLACK parameter.
	local dTheta = rest.TURNS * TAU * kScale
	local dY = (bottomY - topY) * kScale
	local rEps = 0.05
	local dR = ((BrinejawPath.spireRadius(y0 + rEps) - BrinejawPath.spireRadius(y0 - rEps)) / (2 * rEps)) * dY
	local theta1 = theta0 + rest.TAIL_TURN * TAU
	local r1 = rest.TAIL_OUT
	local y1 = BrinejawPath.sandY(rest.TAIL_OUT) + 1.2
	-- The tip still swings with the spiral as it settles, and lies flat: it
	-- keeps the nominal winding rate, has stopped reaching outward, and has
	-- stopped falling.
	local k2, k3 = k * k, k * k * k
	local h00, h10, h01, h11 = 2 * k3 - 3 * k2 + 1, k3 - 2 * k2 + k, 3 * k2 - 2 * k3, k3 - k2
	local theta = theta0 * h00 + dTheta * h10 + theta1 * h01 + (rest.TAIL_TURN * TAU) * h11
	local r = r0 * h00 + dR * h10 + r1 * h01
	local y = y0 * h00 + dY * h10 + y1 * h01
	-- A guard, not a shape: the slack never wants to be inside the masonry,
	-- and after this rewrite it never is (measured minimum clearance 3.43 at
	-- the join, growing from there). It costs one compare and it is the only
	-- thing standing between a future TAIL_TURN edit and a tail through a wall.
	return fromCyl(theta, math.max(r, BrinejawPath.spireRadius(y) + rest.CLEARANCE), y)
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
	-- THE BRANCH IS LATCHED FOR THE WHOLE SWEEP - see `stepSweepBranch`. The
	-- `round` below is the fallback for a caller that never steps it, and it
	-- is exactly what shipped; the fallback is also what every hit test still
	-- gets, because none of them reads this number at all.
	local turns = state.sweepBranch
		or math.round((restBearingRef(1.0) - BrinejawPath.sweepBearingAt(state, reach)) / TAU)
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

-- How much of the slump's span runs FLAT before the neck starts climbing back
-- to the coil. k is the fraction of the front 30% of the body, so 0.22 is
-- about 4 studs of arc - four times ChainPose's own 1-stud tangent step,
-- which is the thing that has to see a level curve. At 0.10 the step still
-- reached into the climb and left tangent.Y = -0.082, which is 0.73 studs of
-- lead dropped and two thirds of the daylight under the jaw.
BrinejawPath.SLUMP_LEVEL = 0.22
-- What the drawn skull loses to the lead riding the ambient breath's own
-- slope: measured 0.73 studs at tangent.Y = -0.082 over HEAD_LEAD 8.9, less
-- the 0.55 the damped ambient gives back. TUNED AGAINST THE DRAWN SKULL, not
-- against the joint: with the lift at 0.20 the jaw's clearance runs 0.34 at
-- the bottom of the breath to 1.60 at the top, so the head rests on the beach
-- through the whole cycle and never intersects it.
BrinejawPath.SLUMP_LIFT = 0.20
-- How far the death collapse settles the resting head: it presses into the
-- beach as the grip finally goes, and 0.25 is what the jaw has to give -
-- the collapse's own reach carries the skull out to r 43 where the beach is
-- 0.09 lower again, so a deeper settle would bury it at U = 1.
BrinejawPath.SLUMP_SETTLE = 0.25

-- Where the head slumps when it loses its grip: off the tower, onto the sand,
-- jaw within reach. The neck drags after it, so the front of the body follows.
--
-- THE SKULL RESTS ON THE BEACH, WHICH IS NOT THE SAME THING AS THE JOINT
-- DOING SO, and the user found the difference: "the serpent's head stays
-- under the sand when it's stunned". Two compounding causes, both measured on
-- the shipped pose at slump = 1, coil = 3, faceAngle 250 degrees:
--
--   * THE LEAD RODE THE TANGENT DOWNWARD. The old y term put the joint at
--     sandY(r) + 2.6, but the curve CLIMBED steeply out of it (the front of
--     the body has to get back to a coil 8 studs up), so the drawn frame -
--     8.9 studs further along that tangent - came out at Y = -0.44 against a
--     beach at 1.56: the joint itself was already 2.0 studs underground.
--   * AND THE BLEND LEAKED THE REARED POSE IN. The slump's weight was
--     smoothstep((0.34 - t) / 0.34), which is 1 at exactly t = 0 and 0.9993
--     one stud of arc later - and the rest pose's head is 55 studs higher, so
--     that 0.07% tilted the front of the body by half a stud per stud:
--     tangent.Y = -0.541. The lead alone therefore dropped the skull 4.81
--     studs before the mesh's own 4.73 was subtracted. Total: the skull's
--     lowest point sat 10.11 studs UNDER the sand, which is the whole head.
--
-- So the pose now runs LEVEL for its first SLUMP_LEVEL of span (the lead has
-- nothing to dive along), sits the joint at `headSitY` (the mesh's own depth
-- plus daylight, derived - not a hand-picked 2.6), and the blend that
-- consumes it holds full weight over the same flat stretch instead of easing
-- from the first frame. Measured after: +0.95 of clearance under the jaw at
-- every slump value from 0.9 up and at every coil stance.
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
	-- The sit is measured where the SKULL ends up, not where the joint is:
	-- the lead carries it HEAD_LEAD studs further out over a beach that
	-- slopes, and reading the sand under the joint would hold the jaw 0.1
	-- studs high at r = 26 and 0.3 low out at the collapse's r = 34.
	local level = BrinejawPath.SLUMP_LEVEL
	local climb = 9.0 * (math.max(k - level, 0) / (1 - level)) ^ 1.5
	-- ...plus what the LEAD still costs. The ambient breath is added outside
	-- every pose (deliberately - see `pointAt`), and its own gradient at the
	-- snout is 0.45 * 9 per unit t, which tilts the front of the body by
	-- tangent.Y = -0.082 however level the pose itself is. Over the 8.9-stud
	-- lead that is 0.73 studs of skull, so the joint is lifted by the measured
	-- amount rather than the clearance being quietly eaten.
	local y = BrinejawPath.headSitY(reach + BrinejawPath.HEAD_LEAD)
		+ BrinejawPath.SLUMP_LIFT
		- BrinejawPath.SLUMP_SETTLE * fall
		+ climb
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
-- `level` (see ATTACK) FLATTENS THE HEAD END ONLY, and it is the other half
-- of the buried-skull fix: the height terms run on a parameter that does not
-- start moving until the arc is `level` of the way along, while theta and r
-- stay linear in k. So the neck leaves a planted head HORIZONTALLY - which
-- is what the client's HEAD_LEAD needs, and what a serpent with its jaw on
-- the sand looks like - and only then climbs. The header's warning about
-- easing the parameter is about the FAR end: ease all three terms and the arc
-- stands itself vertical at the joint. This eases neither theta nor r, and it
-- eases the height only away from the joint, where the arch's own derivative
-- is what shapes the curve. Measured over both planted kinds x 240 steps of
-- U x 121 body points x 4 aim bearings, the steepest tangent the change
-- produces is 81.6 degrees (lunge, t = 0.14; the bite's is 78.2) - inside
-- ChainPose's ~85 limit, against the rest pose's own 77.8 at the snout. Raise
-- `arch` or shorten a span and re-measure: this is the number that decides
-- whether a neck can get one frame of arbitrary roll.
local function neckArc(
	state,
	target: Vector3,
	targetTheta: number,
	span: number,
	arch: number,
	t: number,
	level: number?
)
	local k = math.clamp(t / math.max(span, 1e-3), 0, 1)
	local aWrapped, r1, y1 = cylOf(restPoint(state, span))
	local t1 = restBearing(span, aWrapped)
	local _, r0, y0 = cylOf(target)
	local flat = math.clamp(level or 0, 0, 0.5)
	local ky = math.clamp((k - flat) / (1 - flat), 0, 1)
	local y = y0 + (y1 - y0) * ky + arch * math.sin(math.pi * ky)
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
	local yLand = BrinejawPath.headSitY(aimR)
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

-- THE BITE'S HEAD TARGET. A short reactive snap: rear a little, snap down
-- onto the aim, HANG THERE with the jaw on the sand (the mini punish window),
-- then peel back up. Like every other target function it returns the rest
-- head at U = 0 and again at U = 1, and expresses its bearing as the rest
-- head's plus a swing that never wraps.
--
-- THE HANG LANDS ON `headSitY`, NOT ON A PICKED HEIGHT. That is the whole
-- point of the kind - a head hanging low enough to hit is worth nothing if it
-- hangs INSIDE the beach, which is what the stagger and the lunge were both
-- doing when this was written.
local function biteTarget(state, u: number): (number, Vector3)
	local aimT, aimR = aimCyl(state)
	local th0, r0, y0 = headRestCyl(state)
	local swing = wrapAngle(aimT - th0)
	local rear, impact, hang = BrinejawPath.BITE_REAR_U, BrinejawPath.BITE_IMPACT_U, BrinejawPath.BITE_HANG_U
	local yLand = BrinejawPath.headSitY(aimR)
	if u <= rear then
		-- The rear is short and mostly UP: the head cocks over the aim rather
		-- than drawing back off it, because the whole read of a bite is that
		-- it is already on top of you.
		local a = smoothstep(u / rear)
		return th0 + swing * a, fromCyl(0, r0 + (BrinejawPath.BITE_COCK_R - r0) * a, y0 + BrinejawPath.BITE_RISE * a)
	elseif u <= impact then
		local b = smoothstep((u - rear) / (impact - rear))
		local yTop = y0 + BrinejawPath.BITE_RISE
		return th0 + swing,
			fromCyl(0, BrinejawPath.BITE_COCK_R + (aimR - BrinejawPath.BITE_COCK_R) * b, yTop + (yLand - yTop) * b)
	elseif u <= hang then
		return th0 + swing, fromCyl(0, aimR, yLand)
	end
	local c = smoothstep((u - hang) / (1 - hang))
	return th0 + swing * (1 - c), fromCyl(0, aimR + (r0 - aimR) * c, yLand + (y0 - yLand) * c)
end

-- THE COIL SLAM, in UNWRAPPED cylindrical form. A mid-body loop lifts off the
-- tower, crashes along the line the aim points down, and LIES THERE - a bar
-- of serpent across the arena that you have to be off, and a melee window on
-- the body while it lasts.
--
-- THE SHAPE IS A HAIRPIN, and it has to be: both ends of the affected span
-- are still gripping the tower, so the loop leaves the drum, runs out along
-- the aim bearing, and comes back. The two legs are SLAM_SPREAD apart at the
-- tower and meet at the tip, which is what makes it read as a dropped loop
-- rather than as one thick line - and it is why `coilslamHits` tests a RAY and
-- not the infinite line through the tower: the far side of the tower has no
-- body on it, and this file does not damage ground it has not drawn.
--
-- THE FALLEN SPAN LIES ON THE SAND. `SLAM_SIT` is the body's own half-girth
-- at mid-body plus the daylight that keeps it out of the beach, and it is
-- measured rather than guessed: over U 0.5..0.85 the loop's underside runs
-- 0.13..0.68 studs proud of the sand along the whole bar, and never inside
-- it. Same standard as the slumped head, and for the same reason - this span
-- is a MELEE WINDOW, so half a body buried in the beach is half a window.
local function coilslamCyl(state, t: number): (number, number, number)
	local aimT = aimCyl(state)
	local u = attackProgress(state)
	local k = math.clamp((t - BrinejawPath.SLAM_T0) / (BrinejawPath.SLAM_T1 - BrinejawPath.SLAM_T0), 0, 1)
	-- s = -1 at the near end of the first leg, 0 at the tip, +1 at the near
	-- end of the second: r is a parabola in s (inner at the ends, outer at the
	-- tip) and the lateral offset is linear, so the two legs converge.
	local s = 2 * k - 1
	-- THE LOOP GROWS OUT AND IS DRAGGED BACK IN; it does not exist at full
	-- length from the first frame. This is the `UNDER_OVERRUN` lesson one
	-- attack over: laying all 62 studs of bar out at U = 0 moved the body
	-- 12.26 studs in one step of U at 240 steps, because the mid-body had to
	-- unwind off the drum AND reach the reef before the loop had begun to
	-- rise; the recover snapped 8.21 studs back the same way.
	local inner = BrinejawPath.SLAM_INNER
	local near = inner + 8.0
	local grow = smoothstep(math.clamp(u / BrinejawPath.SLAM_RISE_U, 0, 1))
	-- The drag-back finishes EARLY inside the recover (60% of it), so the
	-- envelope's own fade happens with the loop already near the tower: the
	-- fade's cost is a bearing swing of up to half a turn, and half a turn at
	-- r = 22 is a third of what it is at r = 62.
	local back = smoothstep(math.clamp((u - BrinejawPath.SLAM_LIE_U) / (0.60 * (1 - BrinejawPath.SLAM_LIE_U)), 0, 1))
	local outer = near + (BrinejawPath.SLAM_OUTER - near) * grow * (1 - back)
	-- The legs are split by a fixed ANGLE, not by a fixed lateral offset. Both
	-- forms draw the same V from the tower, but an offset in studs has to be
	-- turned into a bearing by atan2, and atan2 of a constant offset SWINGS as
	-- the loop's length changes - which put 40.91 studs of body in one step of
	-- U while the loop was still growing. At SLAM_SPLAY the legs are 3.8 studs
	-- off the aim line at the tip, inside the COILSLAM_BAND the damage uses.
	local r = inner + (outer - inner) * (1 - s * s)
	local ref = restBearingRef(0.5 * (BrinejawPath.SLAM_T0 + BrinejawPath.SLAM_T1))
	local theta = ref + wrapAngle(aimT + BrinejawPath.SLAM_SPLAY * s - ref)
	-- The lift: up over the rise, down through the crash, and nothing at all
	-- from the blow onward - the loop is on the ground for the whole window.
	local lift
	if u <= BrinejawPath.SLAM_RISE_U then
		lift = BrinejawPath.SLAM_LIFT * smoothstep(u / BrinejawPath.SLAM_RISE_U)
	elseif u <= BrinejawPath.SLAM_IMPACT_U then
		lift = BrinejawPath.SLAM_LIFT
			* (1 - smoothstep((u - BrinejawPath.SLAM_RISE_U) / (BrinejawPath.SLAM_IMPACT_U - BrinejawPath.SLAM_RISE_U)))
	else
		lift = 0
	end
	return theta, r, BrinejawPath.sandY(r) + BrinejawPath.SLAM_SIT + lift
end

-- ------------------------------------------------------- the ENTRY channel
--
-- ONE CUTSCENE-ONLY ATTRIBUTE, `Entry`, a level in 0..1 on the model: HOW FAR
-- ALONG ITS ARRIVAL THIS ANIMAL IS. Absent (nil) means "use the fight pose",
-- and that is not a default - it is the whole safety property. THE SERVER
-- NEVER SETS IT AND CANNOT: it builds its own state with `newState` (which
-- has no `entry` field) and publishes the ten attributes above, so
-- `state.entry` is nil on every server frame of every fight, `pointAt`
-- returns `restPoint` by the SAME code path it always did, and none of the
-- arc-length tables below are ever even built. `Entry` is written only by a
-- client cutscene onto a client-only stand-in (BrinejawIntro/CutsceneKit),
-- and BrinejawBodyController collapses it back to nil at >= 0.995 so the
-- handoff to the real rig is enforced by code rather than argued from a limit.
--
-- WHY THE RIG NEEDED IT (docs/boss-cutscenes-redesign.md SS1.4). This module
-- exposes exactly one topology - a serpent wrapped round the lighthouse - and
-- ten scalars that deform it. At `unwind = 1` the peel only reaches
-- `blendStart = 1 - 0.40` = t 0.6, so the front 61% of the body (measured)
-- cannot be asked to go anywhere, and there is no parameter whose meaning is
-- "how far along its journey is this animal". So the intro could not show the
-- serpent arriving, and faked the eruption with eight glass columns.
--
-- THE PARAMETRISATION, AND WHY THE TRACK RUNS TAIL-END FIRST. Work in a track
-- coordinate `x`:
--
--     J(x) = R(1 - x)   for x >= 0    -- the rest path, walked TAIL-end first
--     J(x) = E(-x)      for x <  0    -- the entry spline, E(0) = R(1)
--
-- with the head at `x_head = A + (1 - A) * Entry` and the body occupying
-- x in [x_head - 1, x_head] in head->tail order (one body length of track).
-- At `Entry = 1`, `x_head = 1`, so `J(1 - t) = R(1 - (1 - t)) = R(t)` - the
-- same call with the same argument, which is why the guard in `pointAt` is
-- `entry < 1` and the rest pose is reached by FALLING THROUGH it rather than
-- by a curve that converges on it.
--
-- The rest pose's head is at the TOP of the tower (HEAD_Y 60) and its tail is
-- on the beach (TAIL_OUT 31), and the helix ascends as `t` DECREASES. So
-- walking the rest path from t = 1 to t = 0 IS the path a serpent climbing
-- the lighthouse head-first takes: beach, up the slack spiral, three turns of
-- helix, over the gallery, snout. The rest pose is already a record of the
-- arrival. Join a spline to R(1), walk the whole thing forward, and three of
-- the four things the brief asks for fall out for free: every vertebra traces
-- the head's exact path (which is what a serpent does), head-first sequential
-- surfacing is automatic because each link crosses the water plane when the
-- head parameter reaches that link's own offset, and "curling around the
-- lighthouse" needs no new geometry at all - the last body length of the
-- track IS the helix.
--
-- THE KNOTS ARE CYLINDRICAL, and that is this file's oldest lesson (see the
-- cylindrical-space note above, and the slack Hermite): a positional lerp
-- between two bearings passes straight THROUGH the masonry - measured 7.98
-- studs inside it - while the same interpolation in (theta, r, y) never comes
-- nearer than 5.04 studs outside. The radius carries the same
-- `spireRadius(y) + CLEARANCE` floor the slack already carries.
--
-- KNOTS 1 AND 2 ARE COMPUTED AT RUN TIME, NEVER PASTED. Knot 2 is the JOIN,
-- `cylOf(restPoint(t = 1))`, and knot 1 is the Catmull-Rom ghost that supplies
-- the arrival tangent, `cylOf(restPoint(t = 0.90))` - so the join is C1
-- against the rest path BY CONSTRUCTION, and a future REST edit moves the
-- spline's mouth with it instead of leaving a pasted pair of numbers behind
-- (this codebase's most expensive defect class, and `tools/check_brinejaw_entry.py`
-- asserts exactly this). ENTRY_KNOTS below is therefore the AUTHORED tail of
-- the table, from the sand outward; `entryKnots()` returns all 18.
--
-- AND `Entry` IS RE-PARAMETRISED BY ARC LENGTH, in units of body-lengths.
-- This is the step that makes it work and the first draft failed without it:
-- with knots spaced by hand-chosen sigma the drawn `chain.length` swung from
-- 546 studs down to 212 as `Entry` advanced - the serpent visibly stretched to
-- double length and then shrank to two thirds. The spline is built on a
-- uniform auxiliary parameter, its arc length is integrated ONCE into a
-- table, and E(sigma) is the point at cumulative length sigma * L_rest, so
-- |dE/dsigma| = L_rest by construction and the body holds its length to
-- within the +-5% gate.
--
-- EVERYTHING HERE IS LAZY AND CACHED IN ONE TABLE FIELD. No new top-level
-- local (the 200-register limit that took the game down 2026-09-06 is
-- invisible to four of the five gates), and no cost at all on a server that
-- never reads the channel.

-- The arena-local height of the water plane. NOT an assumption: for this boss
-- `state.center` IS the waterline. CreatureService's `colossusState` builds
-- brinejaw's pose as `BrinejawPath.newState(Vector3.new(anchor.X,
-- World.WATER_Y, anchor.Z))` - snapped to the waterline on purpose, with its
-- own note saying why - and `World.WATER_Y` is 0, so arena-local y = world y -
-- WATER_Y and the plane is at 0.0 exactly. The cutscene side agrees by a
-- different route: `kit.center` is `BossArenaService.floorY(arenaKey, radius)`,
-- which returns `World.WATER_Y` unchanged for every sea-level arena, and
-- `kit.waterY` is `World.WATER_Y` itself. BrinejawIntro reads `kit.waterY -
-- kit.center.Y` and warns if the two ever disagree rather than trusting this
-- constant - if that warning ever fires, re-run tools/check_brinejaw_entry.py
-- with the new plane, because the breach sigma and ENTRY_A move with it.
BrinejawPath.ENTRY_WATER_Y = 0.0

-- How far under the plane the head starts, in body-lengths of track (0.10 is
-- 29 studs). It is what makes `Entry = 0` genuinely invisible rather than
-- merely level with the surface.
BrinejawPath.ENTRY_SUBMERGE = 0.10

-- Arc-length table sizes. 4000 over 782 studs is a 0.2-stud step, well inside
-- the 0.5-stud resolution any of the six gates measures at; the rest-length
-- integration matches the redesign doc's 2000-sample figure (288.47) rather
-- than ChainPose's own 160 (288.15), and the +-5% body-length gate is stated
-- against the 160 - see the harness.
BrinejawPath.ENTRY_SAMPLES = 4000
BrinejawPath.ENTRY_REST_SAMPLES = 2000

-- THE AUTHORED TAIL OF THE SPLINE: { bearing DEGREES (unwrapped, continuing
-- from the join's own 180.4), radius, arena-local y }. Bearings 240..270 are
-- kept from the shipped script for the reason its `N.sea` comment gives - the
-- party ring puts a challenger at bearing 0, so the arc sweeps ACROSS the
-- camera rather than at it, and the arrival lands short of where the head
-- rests (342).
BrinejawPath.ENTRY_KNOTS = {
	{ 196.000, 46.000, 11.000 }, -- the head lands on the sand, still moving inward
	{ 210.000, 70.000, 38.000 }, -- the descent limb of the arc
	{ 224.000, 96.000, 62.000 },
	{ 236.000, 122.000, 72.000 }, -- APEX, out over open water
	{ 244.000, 146.000, 46.000 },
	{ 248.000, 162.000, 0.000 }, -- THE BREACH: crosses the water plane
	{ 251.000, 178.000, -20.000 },
	{ 262.000, 190.000, -34.000 },
	{ 250.000, 196.000, -44.000 }, -- the submerged body is sinuous, which is
	{ 264.000, 206.000, -50.000 }, -- how it holds 288 studs of length without
	{ 252.000, 214.000, -54.000 }, -- running out to r 500
	{ 266.000, 224.000, -56.000 },
	{ 250.000, 232.000, -58.000 },
	{ 268.000, 242.000, -60.000 },
	{ 252.000, 252.000, -62.000 },
	{ 270.000, 262.000, -64.000 },
}

-- The 18 knots the spline is actually built on, in RADIANS: the two computed
-- anchors and then the authored table. Unwrapped forward from the first
-- authored bearing, because `cylOf` answers in (-pi, pi] and the join sits at
-- 180.4 - one ulp the wrong side of the branch cut would send the first
-- segment 359 degrees round the tower.
function BrinejawPath.entryKnots()
	local state = BrinejawPath.newState(Vector3.zero)
	local gTheta, gR, gY = cylOf(restPoint(state, 0.90))
	local jTheta, jR, jY = cylOf(restPoint(state, 1.00))
	local first = math.rad(BrinejawPath.ENTRY_KNOTS[1][1])
	jTheta = first + wrapAngle(jTheta - first)
	gTheta = jTheta + wrapAngle(gTheta - jTheta)
	local knots = { { gTheta, gR, gY }, { jTheta, jR, jY } }
	for _, knot in BrinejawPath.ENTRY_KNOTS do
		table.insert(knots, { math.rad(knot[1]), knot[2], knot[3] })
	end
	return knots
end

-- The spline's world point at auxiliary parameter `s` in [0, segments].
-- Uniform Catmull-Rom per component, in cylindrical space, with the radius
-- floored off the masonry exactly as the slack tail's guard does.
function BrinejawPath.entryAux(knots, s: number): Vector3
	local segments = #knots - 2
	local i = math.clamp(math.floor(s), 0, segments - 1)
	local u = math.clamp(s - i, 0, 1)
	local p0 = knots[i + 1]
	local p1 = knots[i + 2]
	local p2 = knots[i + 3]
	-- The far end has no knot beyond it, so its ghost is the last segment
	-- continued straight: a reflected tangent, which keeps the final metre of
	-- track from curling back on itself.
	local p3 = knots[i + 4]
		or {
			2 * knots[#knots][1] - knots[#knots - 1][1],
			2 * knots[#knots][2] - knots[#knots - 1][2],
			2 * knots[#knots][3] - knots[#knots - 1][3],
		}
	local u2, u3 = u * u, u * u * u
	local out = {}
	for c = 1, 3 do
		out[c] = 0.5
			* (
				2 * p1[c]
				+ (-p0[c] + p2[c]) * u
				+ (2 * p0[c] - 5 * p1[c] + 4 * p2[c] - p3[c]) * u2
				+ (-p0[c] + 3 * p1[c] - 3 * p2[c] + p3[c]) * u3
			)
	end
	local y = out[3]
	return fromCyl(out[1], math.max(out[2], BrinejawPath.spireRadius(y) + BrinejawPath.REST.CLEARANCE), y)
end

-- Built ONCE, on the first frame that reads the channel, and cached here.
-- Holds the sampled spline, its cumulative arc length, the rest path's length
-- (the unit `Entry` is measured in), the breach sigma and A.
function BrinejawPath.entryData()
	local data = BrinejawPath.entryCache
	if data then
		return data
	end

	local knots = BrinejawPath.entryKnots()
	local segments = #knots - 2
	local steps = BrinejawPath.ENTRY_SAMPLES
	local points, cumulative = {}, {}
	points[1] = BrinejawPath.entryAux(knots, 0)
	cumulative[1] = 0
	for i = 1, steps do
		points[i + 1] = BrinejawPath.entryAux(knots, segments * i / steps)
		cumulative[i + 1] = cumulative[i] + (points[i + 1] - points[i]).Magnitude
	end

	-- The rest path's own length, integrated the same way, at newState's
	-- defaults - which is where the entry holds Coil and Slump throughout.
	local state = BrinejawPath.newState(Vector3.zero)
	local restLength = 0
	local previous = restPoint(state, 0)
	for i = 1, BrinejawPath.ENTRY_REST_SAMPLES do
		local point = restPoint(state, i / BrinejawPath.ENTRY_REST_SAMPLES)
		restLength += (point - previous).Magnitude
		previous = point
	end

	-- WHERE THE HEAD BREAKS THE SURFACE, found rather than authored: the track
	-- crosses the plane exactly once (it leaves the sand, arcs over the water
	-- and dives), so the first downward crossing IS the breach. Everything
	-- timed off it - A, the per-link surfacing order, the splash cues - moves
	-- with the knots and with the plane instead of being remembered.
	local water = BrinejawPath.ENTRY_WATER_Y
	local breach = nil
	for i = 2, steps + 1 do
		if points[i].Y < water and points[i - 1].Y >= water then
			local span = points[i - 1].Y - points[i].Y
			local frac = if span > 1e-9 then (points[i - 1].Y - water) / span else 0
			breach = (cumulative[i - 1] + (cumulative[i] - cumulative[i - 1]) * frac) / restLength
			break
		end
	end

	data = {
		knots = knots,
		segments = segments,
		points = points,
		cumulative = cumulative,
		total = cumulative[steps + 1],
		restLength = restLength,
		breach = breach or 0,
		sigmaMax = cumulative[steps + 1] / restLength,
	}
	data.a = -(data.breach + BrinejawPath.ENTRY_SUBMERGE)
	BrinejawPath.entryCache = data
	return data
end

-- The entry spline at `sigma` body-lengths out from the join, arena-local.
function BrinejawPath.entrySpline(sigma: number): Vector3
	local data = BrinejawPath.entryData()
	local distance = math.clamp(sigma, 0, data.sigmaMax) * data.restLength
	local cumulative, points = data.cumulative, data.points
	-- Binary search: the table is 4001 entries and this is called 160 times a
	-- frame by ChainPose alone.
	local lo, hi = 1, #points
	while hi - lo > 1 do
		local mid = (lo + hi) // 2
		if cumulative[mid] <= distance then
			lo = mid
		else
			hi = mid
		end
	end
	local span = cumulative[hi] - cumulative[lo]
	local frac = if span > 1e-9 then (distance - cumulative[lo]) / span else 0
	return points[lo]:Lerp(points[hi], frac)
end

-- THE JOINED TRACK, arena-local. `x >= 0` is the rest path walked tail-end
-- first - the LIVE one, so the mouth of the spline stays attached to whatever
-- the rest pose currently is - and `x < 0` is the spline.
function BrinejawPath.entryJoined(state, x: number): Vector3
	if x >= 0 then
		return restPoint(state, 1 - math.min(x, 1))
	end
	return BrinejawPath.entrySpline(-x)
end

-- Where the head sits on the track at this `Entry`. A is one body-length of
-- track short of nothing: at Entry 0 the snout is ENTRY_SUBMERGE under the
-- plane and the whole 288 studs is behind it, at sea.
function BrinejawPath.entryHead(entry: number): number
	local a = BrinejawPath.entryData().a
	return a + (1 - a) * math.clamp(entry, 0, 1)
end

-- The `Entry` at which body position `t` crosses the water plane, or nil when
-- it never does inside 0..1. Closed form, because the track crosses the plane
-- once: link `t` breaches when `x_head = -breach + t`. Linear in `t`, which is
-- what makes the surfacing order monotonic in link index and the splash cues
-- computable before the run starts.
function BrinejawPath.entryOfBreach(t: number): number?
	local data = BrinejawPath.entryData()
	local entry = (t - data.breach - data.a) / (1 - data.a)
	return if entry > 0 and entry < 1 then entry else nil
end

-- ---------------------------------------------------------------- public

-- Where body position `t` (0 = snout, 1 = rattle) is right now, in world
-- space. Blends rest -> swept for the tail, rest -> slumped for the head,
-- rest -> attack for whichever span the current kind owns.
function BrinejawPath.pointAt(state, t: number): Vector3
	t = math.clamp(t, 0, 1)

	-- THE ENTRY CHANNEL IS FIRST, AND THE ORDER IS THE CONTRACT. It returns
	-- before the unwind/sweep blend, before the slump, before every attack
	-- mode and before anything that reads `state.sweepBranch` or
	-- `state.sweepRate` - so a body on its way in is never half-peeled off a
	-- tower it has not reached, and a cutscene can never trip the latched
	-- branch the fight's whip depends on. `entry == nil` (the server, always)
	-- and `entry >= 1` (the handoff) both FALL THROUGH to the code below
	-- unchanged, which is why `Entry = 1` is not a curve that converges on the
	-- rest pose - it IS the rest pose, same call, same argument.
	local entry = state.entry
	if entry and entry < 1 then
		local x = BrinejawPath.entryHead(entry) - t
		return (state.center or Vector3.zero) + BrinejawPath.entryJoined(state, x)
	end

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
		-- A PLATEAU, NOT A RAMP FROM THE FIRST FRAME. Dividing by (0.34 -
		-- SLUMP_LEVEL * 0.30) holds the weight FULL over the same flat stretch
		-- `slumpPoint` runs level through, and only then eases out to the coil.
		-- At the old (0.34 - t) / 0.34 the head carried 0.07% of a pose whose
		-- head is 55 studs higher one stud of arc in - a half-stud-per-stud
		-- tilt, which the 8.9-stud lead turned into 4.81 studs of buried skull.
		local w = smoothstep((0.34 - t) / (0.34 - BrinejawPath.SLUMP_LEVEL * 0.30)) * slump
		point = point:Lerp(slumpPoint(state, t), w)
	end

	if mode == "neck" then
		local u = attackProgress(state)
		-- THE SAME PLATEAU THE SLUMP GETS, for the same measured reason: over
		-- the arc's flat `level` run the neck must carry the attack's pose at
		-- FULL weight, because the rest head is 52 studs higher and a 0.27%
		-- leak one stud of arc in tilts the front of the body by 0.14 - which
		-- the client's 8.9-stud lead turns into 1.2 studs of skull, and the
		-- bite's jaw was 0.34 studs inside the beach with the level run
		-- already in place. A kind with no `level` (belltoll) is unchanged.
		local w = attackEnvelope(u, shape.entry, shape.exit)
			* smoothstep((shape.span - t) / (shape.span * (1 - (shape.level or 0))))
		if w > 0 then
			local targetTheta, target
			if kind == "lunge" then
				targetTheta, target = lungeTarget(state, u)
			elseif kind == "bite" then
				targetTheta, target = biteTarget(state, u)
			else
				targetTheta, target = bellTarget(state, u)
			end
			local theta, r, y = cylOf(point)
			local aTheta, aR, aY = neckArc(state, target, targetTheta, shape.span, shape.arch, t, shape.level)
			point = cylBlend(restBearing(t, theta), r, y, aTheta, aR, aY, w)
		end
	elseif mode == "coilslam" and t > BrinejawPath.SLAM_T0 and t < BrinejawPath.SLAM_T1 then
		-- Same edge treatment as the undertow: the loop's two ends have to
		-- reach the coils they are still attached to, so the weight tapers over
		-- `edge` of body at each end rather than starting at full strength.
		local edge = 0.06
		local w = attackEnvelope(attackProgress(state), shape.entry, shape.exit)
			* smoothstep(math.min((t - BrinejawPath.SLAM_T0) / edge, (BrinejawPath.SLAM_T1 - t) / edge))
		if w > 0 then
			local theta, r, y = cylOf(point)
			local aTheta, aR, aY = coilslamCyl(state, t)
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
		-- THE VERTICAL AMBIENT IS DAMPED WHEN THE HEAD IS DOWN, AND THE SWAY
		-- IS NOT. A skull lying on the beach cannot rise and fall: with the
		-- bob (1.25) and the snout's share of the breath (0.45) both live, the
		-- drawn jaw swung between 0.75 and 2.50 studs off the sand every
		-- breath - a resting head that floats a stud and a half, which reads
		-- as hovering rather than as lying down. Both vertical terms therefore
		-- fade to 15% at full slump (the breath by CANCELLING the share this
		-- region already took, so the body-wide term is untouched behind the
		-- neck), while the 2.1-stud lateral heave and the client's jaw are
		-- left at full strength - those are what keep the punish window alive,
		-- and this file's header is emphatic that killing the ambient there is
		-- the oldest bug in the fight. Idle (slump 0) is bit-identical.
		local settle = 0.85 * (state.slump or 0)
		point += Vector3.new(0, (math.sin(time * 0.83) * 1.25 * (1 - settle) - breath * settle) * k, 0)
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

-- WHERE THE FALLEN LOOP IS, in world space: the tip of the hairpin, on the
-- sand, on the aim line. The server parks the damageable proxy here for the
-- melee window and the client hangs the marker's far end off it - one point,
-- so the thing you swing at is the thing you can see lying there.
--
-- Analytic (no ambient breath), for the same reason `lungeImpactPoint` is:
-- a hit proxy that inherits a 2-stud ripple makes melee feel haunted.
function BrinejawPath.coilslamPoint(state): Vector3
	local aimT = aimCyl(state)
	local center = state.center or Vector3.zero
	local outer = BrinejawPath.SLAM_OUTER
	return center + fromCyl(aimT, outer, BrinejawPath.sandY(outer) + BrinejawPath.SLAM_SIT)
end

-- Caught by the bar? A band along the aim RAY - not the infinite line through
-- the tower, because the loop is a hairpin and the far side of the tower has
-- no body on it (see `coilslamCyl`).
--
-- Live from the crash's start rather than from the blow, so a server sampling
-- at its own tick rate cannot step over SLAM_IMPACT_U and miss it; the
-- attack's `hit` table is what makes it fire once. Vertically generous: the
-- loop falls from SLAM_LIFT and a player under it is crushed, not brushed.
function BrinejawPath.coilslamHits(state, position: Vector3, girth: number): boolean
	if (state.attackKind or "") ~= "coilslam" or attackProgress(state) < BrinejawPath.SLAM_RISE_U then
		return false
	end
	local center = state.center or Vector3.zero
	local aimT = aimCyl(state)
	local dx, dz = position.X - center.X, position.Z - center.Z
	local along = dx * math.cos(aimT) + dz * math.sin(aimT)
	if along < BrinejawPath.SLAM_INNER or along > BrinejawPath.SLAM_OUTER + 2.0 then
		return false
	end
	local side = math.abs(-dx * math.sin(aimT) + dz * math.cos(aimT))
	if side > (girth or BrinejawPath.COILSLAM_BAND) then
		return false
	end
	local barY = center.Y + BrinejawPath.sandY(along) + BrinejawPath.SLAM_SIT
	return math.abs(position.Y - barY) <= 7.0
end

-- Where the biting skull is: the head of the body curve, sway and all - the
-- same point the client draws, so the authority model stands in the mouth.
function BrinejawPath.biteHeadPoint(state): Vector3
	return BrinejawPath.pointAt(state, 0)
end

-- Caught by the snap? A small disc at the aim, live from the snap's start.
-- The aim is where the JAWS land, which `aimCyl` clamps to the reachable ring
-- exactly as the lunge's is - a bite that fires at somebody hugging the
-- masonry lands at AIM_MIN, which is where the head can actually reach.
function BrinejawPath.biteHits(state, position: Vector3, radius: number): boolean
	if (state.attackKind or "") ~= "bite" or attackProgress(state) < BrinejawPath.BITE_REAR_U then
		return false
	end
	local aimT, aimR = aimCyl(state)
	local center = state.center or Vector3.zero
	local at = center + fromCyl(aimT, aimR, BrinejawPath.sandY(aimR))
	local dx, dz = position.X - at.X, position.Z - at.Z
	if dx * dx + dz * dz > radius * radius then
		return false
	end
	return math.abs(position.Y - at.Y) <= 7.0
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

-- ------------------------------------------------------- the wave, RING FORM
--
-- THE RIPTIDE IS NOW A RING, and this pair replaces `waveFront`/
-- `waveSheltered` above (which stay, working, for one commit while the client
-- is swapped over - delete them next pass). The old wave was a directional
-- wall of slabs and the user read it as scenery; the coils HEAVE THE SEA, so
-- the wave leaves the tower as an expanding ring with TWO GAP ARCS you run
-- to. The read is angular, not lateral, which is why the shelter test is now
-- the SECONDARY answer and the gaps are the primary one.

-- Where the ring is at `now`, or nil before it launches and once it is past
-- `outer`. The whole of the wave's clock, both sides: the server damages a
-- player in the frame the ring crosses their radius and the client draws its
-- crest at the same number.
function BrinejawPath.waveRing(start: number, speed: number, inner: number, outer: number, now: number): number?
	local r = inner + speed * (now - start)
	if r < inner or r > outer then
		return nil
	end
	return r
end

-- IS `worldPos` SAFE FROM THE RING? Two ways, and the first is the one the
-- fight teaches:
--
--   * THE GAPS. Two arcs of calm, open water at bearings `gapA` and `gapB`,
--     each `gapHalf` wide either side of its centre. The player's BEARING
--     from the tower is what matters - not their distance, because the ring
--     is TALL and reaches every radius eventually. The client draws foam
--     markers on these arcs before the wave moves, so the answer exists
--     before the question does.
--   * AND THE LEE, kept. A reef stone still blocks water: the ring travels
--     radially outward, so the shelter direction at a point is that point's
--     OWN bearing from the tower, and with that the existing rectangle test
--     is exactly right. Reusing `waveSheltered` rather than restating it is
--     the point - the client shades the same ground the server forgives, and
--     WAVE_SHELTER_DEPTH / _PAD stay the one copy of how deep a lee is.
--
-- `cover` may be nil for a caller that has no arena list to hand (the marker
-- code that only wants the gap read); the gaps still answer.
function BrinejawPath.waveSafe(
	gapA: number,
	gapB: number,
	gapHalf: number,
	cover,
	center: Vector3,
	worldPos: Vector3
): boolean
	local dx, dz = worldPos.X - center.X, worldPos.Z - center.Z
	local bearing = if (dx * dx + dz * dz) > 1e-8 then math.atan2(dz, dx) else 0
	if math.abs(wrapAngle(bearing - gapA)) <= gapHalf or math.abs(wrapAngle(bearing - gapB)) <= gapHalf then
		return true
	end
	if not cover then
		return false
	end
	return BrinejawPath.waveSheltered(cover, center, bearing, worldPos)
end

-- -------------------------------------------------------------- the spines
--
-- A RADIAL VOLLEY WITH SAFE LANES: spines fly outward along `lanes` evenly
-- spaced bearings, and the ground BETWEEN them is safe. Both sides derive the
-- lane bearings from the same two payload fields - lane k's centre is
-- `bearing0 + k * TAU / lanes` - so nothing about where a spine is has to
-- cross the wire.
--
-- How thick a spine is when it passes you. It has to cover the distance the
-- volley travels between two of the CALLER's ticks, not between two frames: at
-- the book's 55 studs/second a 0.1 s server tick moves the front 5.5 studs, so
-- a caller slower than that must sample the interval the way the sweep's wedge
-- does rather than trusting one call.
BrinejawPath.SPINE_GIRTH = 4.0

-- How far out the volley has got, or nil before it launches and once it is
-- past its reach. Same clock rule as every other event helper: `start` is a
-- server-time value, so a client that adopts the fight mid-volley agrees.
function BrinejawPath.spineFront(payload, now: number): number?
	local r = (payload.speed or 55) * (now - (payload.start or 0))
	if r < 0 or r > (payload.reach or 70) then
		return nil
	end
	return r
end

-- AM I IN A LANE'S PATH? The bearing half of the test, on its own, because
-- the client's marker wants the lanes without a front and the server wants
-- both. Returns the lane index too, so a caller can colour the one that is
-- about to arrive.
function BrinejawPath.spineLane(payload, center: Vector3, worldPos: Vector3): (boolean, number)
	local lanes = math.max(math.floor(payload.lanes or 10), 1)
	local half = payload.laneHalf or math.rad(7)
	local dx, dz = worldPos.X - center.X, worldPos.Z - center.Z
	if (dx * dx + dz * dz) < 1e-8 then
		return true, 0 -- standing on the axis, where every lane starts
	end
	local bearing = math.atan2(dz, dx)
	local step = TAU / lanes
	-- Which lane is nearest, by rounding the offset from lane 0 - one modulo
	-- instead of a loop over ten bearings, and identical on both sides.
	local k = math.round(wrapAngle(bearing - (payload.bearing0 or 0)) / step)
	local delta = math.abs(wrapAngle(bearing - ((payload.bearing0 or 0) + k * step)))
	return delta <= half, (k % lanes + lanes) % lanes
end

-- Caught by the volley right now? The lane test and the front's crossing,
-- together - grounded or airborne, because a spine is as tall as the arena's
-- read needs it to be.
function BrinejawPath.spineHits(payload, center: Vector3, worldPos: Vector3, now: number): boolean
	local front = BrinejawPath.spineFront(payload, now)
	if not front then
		return false
	end
	local dx, dz = worldPos.X - center.X, worldPos.Z - center.Z
	local r = math.sqrt(dx * dx + dz * dz)
	if math.abs(r - front) > (payload.girth or BrinejawPath.SPINE_GIRTH) then
		return false
	end
	return (BrinejawPath.spineLane(payload, center, worldPos))
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
