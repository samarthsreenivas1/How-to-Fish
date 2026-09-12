--!nonstrict
-- RimefangPath.luau
-- Where every piece of Rimefang is, right now: ONE boss's path shape.
--
-- The generic half lives in ChainPose (walking any path by arc length and
-- handing out CFrames). This file is only the whale's geometry.
--
-- WHY A WHALE IS A SHORT CHAIN. Brinejaw is ~100 vertebrae because a serpent
-- IS its spine - every attack is the whole body changing shape. A killer
-- whale is the opposite: a rigid forebody with a flexing tail. So Rimefang
-- is ~16 vertebrae, the undulation is VERTICAL (a lateral wave reads as an
-- eel and throws away the silhouette the mesh pack exists to sell), and the
-- flex grows toward the peduncle rather than running the whole body.
--
-- Server and client both require this file, and that is the point: the
-- server needs the head's position to stand its model on and to run its
-- damage tests, and the client needs every link - off the same inputs, so
-- the thing you dodge and the thing you see cannot disagree.
--
-- THE POSE VOCABULARY. The server writes these as attributes on the boss
-- Model; RimefangBodyController eases toward them and calls in here every
-- frame. Every one is a blend away from the swim pose and back:
--
--   swim (0..1)      how hard the tail is working
--   submerge (0..1)  0 surfaced, 1 running under the ice sheet
--   rise (0..1)      the SPY-HOP: stands on its tail and looks at you
--   roll (radians)   bank; the wave wash rolls it onto its side
--   arch (0..1)      the BREACH, as progress along the leap
--   burst (0..1)     the ICE BREACH, as progress: it runs BURST_DEPTH under
--                    the sheet, erupts VERTICALLY through `center` nose-first
--                    to BURST_HEIGHT at 0.55, then topples forward over the
--                    heading and lands flat at 1. `center` is the BURST
--                    POINT on the surface and does not move for the move.
--   skyfall (0..1)   the SKY SLAM, as progress: launches nose-up, apexes
--                    SKY_HEIGHT up at 0.45, pitches over onto its flank by
--                    ~0.58 and comes down flat onto `center` at 1. `center`
--                    is the ground point UNDER THE HEAD, which the server
--                    eases from the launch point to the impact point; the
--                    path supplies the whole vertical and the orientation.
--   beached (0..1)   landed on the floe and thrashing - the punish window
--   flukeUp (0..1)   the LOBTAIL, as progress through the whole swing:
--                    1 reared clear, ~0.2 hammered down, 0 back at rest
--   faceAngle (rad)  heading
--   gape, lunge      jaw and bite reach; the controller's business, not the
--                    centreline's, but they ride the same state table
--
-- Roll deliberately is NOT in the centreline: a bank rotates the body about
-- its own long axis and moves the spine barely at all, so ChainPose (which
-- derives orientation from the tangent with world up) cannot express it.
-- `RimefangPath.rollAt` hands the controller a per-link roll to post-apply.
--
-- ---------------------------------------------------------------------------
-- THE CURVE IS BUILT FROM ANGLES, NOT POINTS, and that is the whole design.
--
-- Every pose here used to be a function of `t` straight to a world POSITION,
-- and each one quietly resized the animal. Measured, at 16 links:
--
--   rise = 1      63.1 studs (+13%)   a 62-degree elbow at the t=0.34 seam
--   flukeUp = 1   63.0 studs (+12.5%) raising the tail lengthened the whale
--   arch = 0.5    66.7 studs (+19%)   a 53-degree kink at the launch point
--   arch = 1      73.7 studs (+32%)
--   rise = 0.5    52.5 studs (-6%)    every half-blend SHORTENED it again
--
-- The controller draws a FIXED sixteen vertebrae (ChainPose:eachN), so a
-- curve that grows 32% does not grow a whale - it stretches every vertebra
-- and slides the girth curve, the dorsal and the flippers along the body.
--
-- So a pose is now an INTRINSIC description: an anchor (where the head is)
-- plus a pitch and a yaw for the body's direction at each `t`. `pointAt`
-- integrates unit directions down the body, which makes the arc length
-- exactly BODY_LENGTH for every pose AND for every blend between poses -
-- lerping two 56-stud curves point-by-point does not, which is where the
-- half-blend shrinkage came from. Continuity comes free too: the direction
-- field is continuous, so the body cannot have a corner in it.
--
-- The cost is an integral per sample: STEPS midpoint steps, so ~1200 cheap
-- direction evaluations for a 96-sample update, and ZERO for `pointAt(s, 0)`
-- - the head, which is the only point the server needs every frame.
--
-- ---------------------------------------------------------------------------
-- UNITS, and which side is authoritative. Three of these constants used to
-- contradict Bosses.luau's rimefang row, in a file whose entire promise is
-- that the drawn body and the authoritative one agree:
--
--   SUBMERGE_DEPTH  now 18 = `riseDepth`. `rising` publishes submerge =
--                   1 - progress against a hidden model the server pivots
--                   from -riseDepth, so at 9 the whale you saw came up from
--                   half as deep as the whale you were fighting. DATA WINS.
--   ARCH_HEIGHT     now 9 = `breach.leap`. The charge handler hops the
--                   authority model sin(u*pi) * leap; the apex used to be
--                   drawn 26 studs up, 17 studs above its own hitbox.
--                   DATA WINS. Raise `leap` if the breach should fly higher.
--   ARCH_SPAN       now 46 = `breach.length`, the ground distance the charge
--                   actually covers in its strike. DATA WINS.
--   RISE_HEIGHT     24, and the PATH wins, because `spyhop.rise = 11` is
--                   read by nothing at all (the spy-hop handler has no pose
--                   hooks - the stand is published, not pivoted). 24 is
--                   chosen so 48% of the body is clear of the water, which
--                   is what "half its body clear" in the fight notes means.
--                   `spyhop.rise` should be deleted or set to 24.
--
-- `def.submerge = 2.4` is NOT one of these: it is how low the server's own
-- hidden model rides, a rest offset for the authority pivot, and the drawn
-- body's rest is the waterline. Both rise the same amount from their own
-- rest, which is the thing that has to match.

local RimefangPath = {}

-- Authored geometry, mirrored from assets/boss_gen.py's rimefang section.
-- BODY_LENGTH is nose-to-fluke at scale 1; SEG_SPACING is RF_SEG_SPACING.
RimefangPath.BODY_LENGTH = 56.0
RimefangPath.SEG_SPACING = 3.6
RimefangPath.HEAD_OFFSET = 5.2 -- how far ahead of the first vertebra the skull sits

-- THE ARENA MOVES' VERTICAL EXTENTS, public because three files need the same
-- numbers: the path draws them, RimefangBodyController sizes its settle kick
-- and camera cues off them, and CreatureService's rimefangDrive places the
-- telegraph, the hole in the ice and the impact test at them. One source.
--
--   BURST_DEPTH   how deep the whale runs under the sheet before it erupts.
--                 Deliberately the same 18 as SUBMERGE_DEPTH, so `burst = 0`
--                 and `submerge = 1` are the SAME body, and the server can
--                 hold submerge at 1 while burst ramps off zero with nothing
--                 to see at the seam.
--   BURST_HEIGHT  how far the head clears the surface at the top of the
--                 eruption (burst = 0.55), before it topples.
--   SKY_HEIGHT    the sky slam's apex (skyfall = 0.45), head above surface.
RimefangPath.BURST_DEPTH = 18.0
RimefangPath.BURST_HEIGHT = 22.0
RimefangPath.SKY_HEIGHT = 70.0

-- Swim cycle. Two thirds of a wave down the body, so the tail trails the
-- head rather than the whole animal snaking in step.
local SWIM_RATE = 2.1
local SWIM_WAVES = 0.66
local SWIM_AMP = 2.6
-- A second, quicker, shorter wave stacked on the first, weighted toward the
-- peduncle (grow 2.4 vs 1.6) so the tail carries a fine flick riding the main
-- stroke. A single pure sine reads mechanical; two incommensurate ones read
-- like an animal that is actually swimming. Small enough that the extra
-- curvature stays well inside the joint-angle budget.
local SWIM_AMP2 = 0.34
local SWIM_WAVES2 = 1.15
local SWIM_RATE2 = 1.9
-- The gait's shoulder roll: a whale rocks a little as it strokes, the roll
-- lagging the wave that drives it. Post-applied through rollAt, so it never
-- touches the centreline's arc length.
local SWIM_ROLL = math.rad(2.4)

-- TURN-INTO-BANK. The path is handed a heading, not a turn rate, so a body
-- drawn straight back from the head reads as a rigid train on the carousel's
-- ring. But a banked swimmer IS a turning one - bank angle and turn radius
-- are the same fact - so the body curves in proportion to `roll`, growing
-- toward the tail. The coupling saturates (roll / (1 + k|roll|)) so the wave
-- wash's hard capsize sweeps in a gentle arc rather than coiling up.
local TURN_MAX = math.rad(38.0)
local TURN_SAT = 0.9

-- Mirrors Bosses.rimefang.riseDepth. Read the header before changing it.
local SUBMERGE_DEPTH = 18.0
-- The spy-hop's stand: how far the head is above the waterline. See header.
local RISE_HEIGHT = 24.0
-- Mirrors Bosses.rimefang.breach.length / .leap. Read the header.
local ARCH_SPAN = 46.0
local ARCH_HEIGHT = 9.0
-- The corkscrew a breaching orca carries into its leap: a bank that swells to
-- the apex and unwinds to level at re-entry. Post-applied through rollAt.
local ARCH_BANK = math.rad(26.0)
local BEACHED_Y = 2.2 -- lying on the floe, which floats ~2.4 proud
local THRASH_RATE = 5.5
local THRASH_AMP = 4.4
-- The beached thrash's secondary curves: a slow forebody heave (toward the
-- head) and a lagged tail follow-through, both in radians of yaw.
local THRASH_HEAD = math.rad(7.5)
local THRASH_FOLLOW = math.rad(5.0)
-- The stranded roll: a whale on the floe lies part-over and rocks. A gentle
-- bank, breathing slowly, applied through rollAt so it stays off the
-- centreline. Not a full capsize - the lateral thrash must still read.
local BEACHED_ROLL = math.rad(24.0)

-- THE SPY-HOP'S SHAPE, as angles off vertical for the down-body direction.
-- STAND is how far off plumb the standing forebody leans; NECK is an extra
-- cock at the skull that decays over the front third of the body, so the
-- snout looks out over the floe (54 degrees of elevation) instead of at the
-- sky; TAIL is where the curl has got to by the flukes, reached by a smoothstep
-- of t so the bend eases in past the rigid forebody and eases out at the slack
-- fluke tip - the flex lives in the peduncle, where a whale's does.
--
-- STAND IS NOT ZERO ON PURPOSE. A dead-plumb body has a tangent of exactly
-- (0,1,0), and ChainPose.alongX derives orientation from the tangent's
-- AZIMUTH - which is undefined there. The old rise pose's front 34% was a
-- pure vertical line, so the head's CFrame came out byte-identical at yaw 0,
-- 45, 90, 180 and 270: the "slow scan, it is picking someone" beat was
-- geometrically invisible, and the pectorals (mounted at t = 0.20, inside
-- that vertical run) stuck out along world axes rather than the flanks.
-- 16 degrees of lean puts |right| at 0.28 - nowhere near the singularity -
-- and makes every frame down the body a function of the heading again.
local RISE_STAND = math.rad(16.0)
local RISE_NECK = math.rad(20.0)
-- Where the curl-back has got to by the flukes. The curl is now a smoothstep
-- of t (below), whose slope dies at the tail tip, so the flukes hang slack
-- instead of over-rotating - that dropped the worst joint from 12.5 to 7.9
-- degrees, back inside budget, without moving the snout's 54-degree lookout.
local RISE_TAIL = math.rad(100.0)
-- The relaxed slack in the hanging mid-body of a spy-hop; a mid-span dip only.
local RISE_RELAX = math.rad(6.0)

-- THE LOBTAIL. `flukeUp` is progress through the WHOLE swing, not a lift:
-- the tail rears to FLUKE_RISE at 1, crosses its rest line at FLUKE_CROSS,
-- and drives to FLUKE_PUNCH below it around 0.22 before settling back at 0.
-- The old pose only ever LIFTED the back 45%, so the slam had nowhere to
-- land - the tail went up and the attack simply ended. Now the same
-- monotone ramp the server already publishes (windup 0 -> 1, strike 1 -> 0)
-- reads as a sink-and-heave anticipation and then a hammer through the
-- waterline: the fluke tip rears to +19.0, crosses rest at FLUKE_CROSS, and
-- drives to -11.5 studs before a small elastic rebound settles it back to rest
-- with follow-through (FLUKE_REBOUND), the peduncle curving through the swing.
--
-- Neither angle goes near 90: a vertical tail tip is the one case
-- ChainPose.alongX genuinely cannot orient, and the fluke is drawn on it.
--
-- THE ANGLES ARE NOT THE TRAVEL, and that distinction is what lets these
-- three numbers move without the attack changing. What the server times its
-- damage to and the rig eases against is where the fluke TIP goes and when:
-- +18.98 studs reared at 1, through the rest line at FLUKE_CROSS, -11.49 at
-- its deepest around 0.22. Those are held to a tenth of a stud below. The
-- angles fell (62 -> 55, 34 -> 31, 9 -> 8.2) only because FLUKE_START and
-- FLUKE_RAMP now spread the same travel over more peduncle, so it takes less
-- bend per vertebra to go the same distance. Re-tune the pair together or the
-- lobtail lands somewhere else.
local FLUKE_RISE = math.rad(55.0)
local FLUKE_PUNCH = math.rad(31.0)
local FLUKE_CROSS = 0.45
-- The follow-through: a small elastic rebound of the peduncle just after the
-- fluke hammers through, decaying to nothing at rest. Weight, not a wag.
local FLUKE_REBOUND = math.rad(8.2)
-- WHERE THE PEDUNCLE BENDS, and HOW SHARPLY AT ITS SHARPEST. The lobtail was
-- the one pose in this file still over the 8-degree-per-joint budget: 9.78
-- degrees at flukeUp = 1, at t = 0.59, and it had been there since the swing
-- was authored. The cause is arithmetic. A smoothstep envelope's slope peaks
-- at 1.5x its mean, so 62 degrees of bend spread over 0.72 of the body puts
-- 62 * 1.5 / 0.72 = 129 degrees per unit of t through the middle of the
-- peduncle - and a sixteenth of that is 8.1 degrees before the swim wave adds
-- anything at all. Widening the envelope alone would have fixed it only by
-- dragging the flex into the forebody, which is the one thing this whale's
-- silhouette cannot afford.
--
-- So the envelope is now flat-topped instead: FLUKE_RAMP of smoothstep at
-- each end - rigid forebody, slack fluke tip, both preserved - and a CONSTANT
-- rate between them. A constant rate is a circular arc, which is both what a
-- peduncle actually does and the shape that minimises peak curvature for a
-- given total bend, so the same travel costs 1/(1 - FLUKE_RAMP) rather than
-- 1.5x the mean. With the start moved only 0.28 -> 0.22 that lands the worst
-- joint at 7.25 degrees, and the tip still goes exactly as far as it did.
local FLUKE_START = 0.22
local FLUKE_RAMP = 0.20

-- THE ICE BREACH, and THE SKY SLAM. Both are PROGRESS channels like `arch`,
-- and both end lying flat on the floe, because the server hands each one off
-- to `beached` at 1. That handoff is the constraint that shapes both tails:
-- at progress 1 the direction field, the head's height and the roll are the
-- BEACHED ONES EXACTLY (`beachedYaw` is faded in over the last LAND_FADE of
-- progress, the pitch has already gone to zero, the anchor is at BEACHED_Y),
-- so the switch of channel moves no link at all. Measured: 0.000 studs.
--
-- BURST. The eruption is not a lift. `burst` 0..BURST_MID drives the head from
-- BURST_DEPTH under to BURST_HEIGHT over, with BURST_SAG studs of sink first -
-- the anticipation - and a late-weighted climb, so it gathers and then goes.
-- BURST_TILT is how far off horizontal the body stands at the top: 72 degrees,
-- not 90, for exactly the reason RISE_STAND is not zero (see the spy-hop's
-- note below) - a plumb body has no azimuth and ChainPose.alongX cannot orient
-- it. BURST_RELAX lets the tilt fall off toward the flukes so the rear trails
-- rather than following as a pole, and BURST_S adds the S: one full wave down
-- the body, zero at the nose and the flukes so it bends the middle only.
-- Past BURST_MID it topples: the tilt unwinds, the head falls to BEACHED_Y and
-- runs BURST_LEAD studs forward along the heading, so the skull lands ahead of
-- the hole it came out of.
local BURST_MID = 0.55
local BURST_FADE = 0.22 -- how much progress the stance takes to reach full weight
local BURST_TILT = math.rad(72.0)
local BURST_SAG = 4.0
local BURST_LEAD = 16.0
local BURST_RELAX = 0.30
local BURST_S = math.rad(9.0)
local BURST_BANK = math.rad(18.0)
-- Where both moves converge on the beached shape: the last 28% of progress.
local LAND_FADE = 0.28
--
-- SKYFALL. Nose-up at SKY_LAUNCH off the surface, swelling to SKY_TILT as it
-- climbs; apex at SKY_APEX; then the PITCH-OVER.
--
-- SKY_TURN0/SKY_TURN1 ARE WIDER THAN THE 0.45..0.58 THE MOVE IS DESCRIBED BY,
-- and that is a measurement, not a liberty. The rotation is 70-odd degrees of
-- a 56-stud body, so the far link's speed is (turn rate) x (28 studs): run
-- through a smootherstep, whose slope peaks at 1.875x its mean, a 0.13-wide
-- window put 604 studs per unit of progress into one link while the rest of
-- the move ran at 280 - a whip, not an animation. Spreading the same rotation
-- over 0.22 brings the peak to 393, in line with the move's own worst
-- elsewhere, at the cost of 6 degrees off plumb at 0.45 and 3 off flat at
-- 0.58. The eye reads the beat; it does not read the six degrees.
--
-- SKY_PIVOT is the other half of that fix: without it the body swings about
-- its HEAD (the anchor), so the flukes carry the whole 50-stud arc alone.
-- Dropping the head by SKY_PIVOT of the fall during the turn moves the pivot
-- to mid-body - which is where a whale's actually is - and halves the radius.
-- It also reads better: the animal HANGS while it turns over, instead of
-- hanging its head and flailing its tail.
local SKY_FADE = 0.18
local SKY_APEX = 0.45
local SKY_TURN0 = 0.40
local SKY_TURN1 = 0.62
local SKY_LAUNCH = math.rad(38.0)
local SKY_TILT = math.rad(72.0)
local SKY_PIVOT = 0.32
local SKY_RELAX = 0.28
local SKY_S = math.rad(8.0)
local SKY_SAG = math.rad(5.0)
-- The corkscrew: one continuous winding, not a swell-and-unwind like the
-- breach's, because this one has somewhere to arrive - the flank it lands on.
local SKY_FLANK = math.rad(70.0)

-- Midpoint steps for the whole body. 24 puts the worst position error at
-- 0.018 studs against an exact integral, and the error varies smoothly with
-- t, so it cannot show up as a corner.
local STEPS = 24
local STEP_T = 1.0 / STEPS

local UP = Vector3.new(0, 1, 0)

-- Cubic ease, C1. Used for envelopes DOWN THE BODY (a pose's spatial shape),
-- where the lowest peak curvature for fixed ends with zero end-slope keeps the
-- per-joint bend inside budget, and C1 is all "no corner in the body" needs.
local function smoothstep(x: number): number
	x = math.clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end

-- Quintic ease: zero FIRST and SECOND derivative at both ends, where cubic
-- smoothstep leaves a second-derivative jump. Used for the TEMPORAL fades -
-- a stance easing in or out over the fight's clock - so weight arrives and
-- leaves with no kink in its acceleration. C2 is the bar the user set with
-- "really really smooth"; on a spatial envelope its higher peak slope would
-- cost joint-angle budget, so the two eases split those two jobs.
local function smootherstep(x: number): number
	x = math.clamp(x, 0, 1)
	return x * x * x * (x * (x * 6 - 15) + 10)
end

-- THE FLAT-TOPPED ENVELOPE, 0 to 1 across x, with FLUKE_RAMP of smoothstep at
-- each end and a constant rate between. Zero slope at both ends like
-- `smoothstep`, but its peak slope is 1/(1 - FLUKE_RAMP) instead of 1.5 - and
-- peak slope IS the per-joint angle, which is why the lobtail uses it. The
-- ramps are the integral of `smoothstep` scaled to meet the middle, so the
-- value, the slope AND the curvature all match at both joins.
local RAMP_K = 1.0 / (1.0 - FLUKE_RAMP)
local function peduncleBend(x: number): number
	if x <= 0 then
		return 0
	end
	if x >= 1 then
		return 1
	end
	if x < FLUKE_RAMP then
		local s = x / FLUKE_RAMP
		return RAMP_K * FLUKE_RAMP * (s * s * s - 0.5 * s * s * s * s)
	end
	if x > 1 - FLUKE_RAMP then
		local s = (1 - x) / FLUKE_RAMP
		return 1 - RAMP_K * FLUKE_RAMP * (s * s * s - 0.5 * s * s * s * s)
	end
	return RAMP_K * (x - 0.5 * FLUKE_RAMP)
end

-- A single travelling-sine SLOPE (d/dt of amp*t^grow*sin(phase), the wave
-- moving head->tail as time advances), returned as the vertical slope the
-- body has at `t`. Kept as a slope, not a position, because pointAt turns it
-- into an angle - which is what stops a swim wave from stretching the whale.
local function travellingSlope(t: number, phase: number, grow: number, waves: number): number
	local k = waves * math.pi * 2
	return grow * t ^ (grow - 1) * math.sin(phase) - t ^ grow * math.cos(phase) * k
end

-- The heading convention matches CreatureService.bossFacing, so a bearing
-- latched by an attack and the body drawn for it agree.
local function heading(state): Vector3
	local yaw = state.faceAngle or 0
	return Vector3.new(math.cos(yaw), 0, -math.sin(yaw))
end

local function sideways(forward: Vector3): Vector3
	return Vector3.new(-forward.Z, 0, forward.X)
end

function RimefangPath.newState(center: Vector3)
	return {
		center = center,
		swim = 1,
		submerge = 0,
		rise = 0,
		roll = 0,
		arch = 0,
		burst = 0,
		skyfall = 0,
		beached = 0,
		flukeUp = 0,
		faceAngle = 0,
		gape = 0,
		lunge = 0,
		time = 0,
	}
end

-- Girth down the body, mirrored from `_rf_girth` in assets/boss_gen.py. A
-- whale is not a cone: it holds full girth from behind the head to past
-- mid-body, then the peduncle pinches hard. That pinch is most of what
-- separates a whale silhouette from a fish's, so the taper must not be
-- linear.
function RimefangPath.girth(u: number): number
	u = math.clamp(u, 0, 1)
	if u < 0.16 then
		return 0.88 + 0.12 * (u / 0.16)
	end
	if u < 0.46 then
		return 1.0
	end
	return 1.0 - 0.78 * ((u - 0.46) / 0.54) ^ 1.45
end

-- How deep `submerge` actually puts the body. NOT linear, because one 0..1
-- channel carries two jobs: the intro rise drives it to 1 and has to start
-- from the data's riseDepth (18), while the prowl's breath cycle and three
-- attacks ride it at 0.12..0.7 and want the shallow dips they were tuned
-- for. The cubic keeps the small end at ~7.6 studs per unit - within a stud
-- of the old linear 9 - and still reaches 18 at full.
local function submergeDepth(s: number): number
	s = math.clamp(s, 0, 1)
	return SUBMERGE_DEPTH * (0.42 * s + 0.58 * s * s * s)
end

-- ---------------------------------------------------------------- shapes
--
-- Each shape contributes a PITCH (radians, positive = the body climbs as you
-- walk toward the tail) and sometimes a YAW (positive = toward `sideways`).
-- Nothing here returns a position; `pointAt` integrates them.

-- Cruising: the slope of the old travelling sine, so the shape is the one
-- the mesh pack's preview was authored against - but as an angle, which is
-- what stops the wave from stretching the animal.
local function swimPitch(state, t: number): number
	local time = state.time or 0
	local swim = state.swim or 1
	local phase1 = time * SWIM_RATE - t * SWIM_WAVES * math.pi * 2
	local phase2 = time * SWIM_RATE2 - t * SWIM_WAVES2 * math.pi * 2
	local slope = SWIM_AMP
		* swim
		* (travellingSlope(t, phase1, 1.6, SWIM_WAVES) + SWIM_AMP2 * travellingSlope(t, phase2, 2.4, SWIM_WAVES2))
	return math.atan(slope / RimefangPath.BODY_LENGTH)
end

-- The lobtail, as a bend that grows through the peduncle and holds out to
-- the flukes.
local function flukePitch(state, t: number): number
	local f = math.clamp(state.flukeUp or 0, 0, 1)
	if f <= 0 then
		return 0
	end
	-- The bend is spread over the rear 78% of the body (was 42%, then 72%), so
	-- the peduncle CURVES into the swing instead of hinging at one vertebra - the
	-- original envelope put a 13-degree kink at the pinch, and the smoothstep that
	-- replaced it still peaked at 9.8. It still reaches full at the flukes, and
	-- FLUKE_RISE is retuned against it, so the tip travels just as far.
	local rear = peduncleBend((t - FLUKE_START) / (1 - FLUKE_START))
	if rear <= 0 then
		return 0
	end
	local up = FLUKE_RISE * smootherstep((f - FLUKE_CROSS) / (1 - FLUKE_CROSS))
	-- `dipPhase` runs 0 (tail at rest line) -> 1 (fully hammered through) as the
	-- swing drives down through FLUKE_CROSS. A half-sine is the down-stroke;
	-- the rebound is one small over-shoot back up just after the blow, dying to
	-- zero exactly at rest, so the fluke SETTLES with follow-through rather than
	-- stopping dead the instant it crosses the waterline.
	local dipPhase = 1 - math.min(f, FLUKE_CROSS) / FLUKE_CROSS
	local punch = FLUKE_PUNCH * math.sin(math.pi * dipPhase)
	local settle = FLUKE_REBOUND * -math.sin(2 * math.pi * dipPhase) * dipPhase
	return (up - punch + settle) * rear
end

-- THE SPY-HOP. It stands on its tail, cocks its head at someone, and the
-- rest of the body curls back and under. One curve, no seam.
local function risePitch(_state, t: number): number
	-- The neck cock decays over the front 30% of the body, spread across an
	-- extra vertebra or two so the snout looks out over the floe without a kink.
	local neck = RISE_NECK * (1 - smoothstep(t / 0.30))
	-- The curl back and under. A smoothstep of t, so its slope is zero at BOTH
	-- ends: the rigid forebody stays rigid and the flukes hang slack, with the
	-- bend carried through the peduncle where a real whale's flex lives.
	local curl = (RISE_TAIL - RISE_STAND) * smoothstep(t)
	-- A gentle relaxed slack through the hanging mid-body - a real spy-hop is
	-- not a taut arc, the body dangles - as a mid-span dip that vanishes at both
	-- ends, so it adds an S without moving the anchor or the tail.
	local slack = -RISE_RELAX * math.sin(math.pi * t)
	return RISE_STAND + neck + curl + slack - math.pi * 0.5
end

-- THE BREACH. `arch` is PROGRESS along the leap, not a weight: the head is
-- at `arch` on the parabola and the body trails BY ARC LENGTH behind it, so
-- the whale follows its own head through the air without growing (the old
-- version trailed by a fraction of the ground SPAN, which ignored that the
-- arc is longer than the span and stretched the body by up to a third).
local ARCH_ARC = (function()
	-- Mean arc length per unit of leap progress, so "s studs behind the head"
	-- can be turned into "this much earlier in the leap" without a walk.
	local total = 0.0
	for i = 0, 199 do
		local sigma = (i + 0.5) / 200
		local dy = ARCH_HEIGHT * math.pi * math.cos(sigma * math.pi)
		total += math.sqrt(ARCH_SPAN * ARCH_SPAN + dy * dy) / 200
	end
	return total
end)()
local ARCH_ANGLE0 = math.atan2(ARCH_HEIGHT * math.pi, ARCH_SPAN)

local function archPitch(state, t: number): number
	local sigma = (state.arch or 0) - (t * RimefangPath.BODY_LENGTH) / ARCH_ARC
	if sigma > 0 then
		local ahead = math.min(sigma, 1.0)
		return -math.atan2(ARCH_HEIGHT * math.pi * math.cos(ahead * math.pi), ARCH_SPAN)
	end
	-- Behind the launch point the body is still in the water: it leaves on
	-- the launch angle and eases to level over the next ~30 studs of itself
	-- (was 20), rather than snapping to flat the way a clamp would. The wider,
	-- gentler ease spreads the waterline seam's curvature under the joint budget.
	return -ARCH_ANGLE0 * (1 - smoothstep(-sigma / 0.55))
end

-- BEACHED. Landed flat on the floe, working itself back toward water. The
-- thrash is LATERAL here and nowhere else - a stranded whale wallows on its
-- side, and the contrast with the vertical swim cycle is what sells that it
-- is out of its element and briefly killable.
local function beachedYaw(state, t: number): number
	local time = state.time or 0
	local phase = time * THRASH_RATE - t * 3.0
	-- The main wallow, the travelling sine the pose already had.
	local slope = THRASH_AMP * (1.4 * t ^ 0.4 * math.sin(phase) - t ^ 1.4 * math.cos(phase) * 3.0)
	local main = math.atan(slope / RimefangPath.BODY_LENGTH)
	-- Secondary curl toward the HEAD: a slow heave of the forebody that peaks at
	-- the skull and dies by mid-body, so the front hunts for the water too
	-- rather than lying inert while only the tail works.
	local headCurl = THRASH_HEAD * (1 - t) ^ 1.8 * math.sin(time * THRASH_RATE * 0.55 + 0.9)
	-- Follow-through at the TAIL: the same stroke arriving a beat late and
	-- weighted to the flukes, so the tail lags and overshoots the body it hangs
	-- off instead of snapping in step with it - weight, not a stiff wag.
	local follow = THRASH_FOLLOW * t ^ 2.0 * math.sin(phase - 1.15)
	return main + headCurl + follow
end

-- THE ICE BREACH. Four scalars of progress, then one pitch field.
--
-- `burstRot` is HOW FAR OVER the body has come: 0 lying flat under the sheet,
-- 1 stood up at BURST_TILT, back to 0 lying flat on top of it. `burstLift` is
-- where the head is vertically, `burstLead` how far forward the topple has
-- carried it, `burstLand` how much of the beached shape has arrived.
--
-- Every piece is built out of `smootherstep`, whose first AND second
-- derivatives vanish at both ends, and every seam (BURST_MID, 0 and 1) is a
-- join between two such ends - so the whole channel is C2 in progress with no
-- special-casing. That matters more here than anywhere else in the file: the
-- controller eases `burst` at 18/s, so a kink in shape-vs-progress arrives as
-- a kink in shape-vs-time at whatever rate the ease happens to be running.
local function burstRot(b: number): number
	if b <= BURST_MID then
		return smootherstep(b / BURST_MID)
	end
	local v = (b - BURST_MID) / (1 - BURST_MID)
	return 1 - (0.45 * smootherstep(v) + 0.55 * smootherstep(v) ^ 2)
end

local function burstLift(b: number): number
	if b <= BURST_MID then
		local u = b / BURST_MID
		-- Late-weighted, so the drive is a surge rather than a ride up: the
		-- squared term contributes almost nothing over the first third.
		local climb = 0.35 * smootherstep(u) + 0.65 * smootherstep(u) ^ 2
		-- The anticipation: it SINKS about two studs first, deepest at u ~ 0.36,
		-- and the sag is gone by the time it reaches the surface.
		local sag = BURST_SAG * math.sin(math.pi * u) ^ 2 * (1 - u)
		return -RimefangPath.BURST_DEPTH + (RimefangPath.BURST_HEIGHT + RimefangPath.BURST_DEPTH) * climb - sag
	end
	local v = (b - BURST_MID) / (1 - BURST_MID)
	-- The topple hangs a moment at the top and then drops with gravity's shape.
	local fall = 0.30 * smootherstep(v) + 0.70 * smootherstep(v) ^ 2
	return RimefangPath.BURST_HEIGHT + (BEACHED_Y - RimefangPath.BURST_HEIGHT) * fall
end

local function burstLead(b: number): number
	if b <= BURST_MID then
		return 0.0 -- it comes up THROUGH the burst point, not past it
	end
	local v = (b - BURST_MID) / (1 - BURST_MID)
	return BURST_LEAD * (0.45 * smootherstep(v) + 0.55 * smootherstep(v) ^ 2)
end

-- How much of the beached pose has arrived, for both arena moves: zero until
-- the last LAND_FADE of progress, one exactly at 1.
local function landFade(p: number): number
	return smootherstep((p - (1 - LAND_FADE)) / LAND_FADE)
end

local function burstPitch(state, t: number): number
	local b = math.clamp(state.burst or 0, 0, 1)
	local rot = burstRot(b)
	-- The tilt eases off through the back 60%, so the rear trails the drive
	-- instead of standing plumb with it.
	local spine = 1 - BURST_RELAX * smoothstep((t - 0.40) / 0.60)
	-- One full wave down the body, zero at both ends: the graceful S, and the
	-- reason the eruption is not a pole with a whale painted on it.
	return -BURST_TILT * rot * spine + BURST_S * math.sin(2 * math.pi * t) * rot
end

local function burstYaw(state, t: number): number
	return beachedYaw(state, t) * landFade(math.clamp(state.burst or 0, 0, 1))
end

-- THE SKY SLAM. Same four-scalar shape, with the pitch-over in the middle.

-- How far through the pitch-over: 0 climbing, 1 flat and side-on.
local function skyTurn(p: number): number
	return smootherstep((p - SKY_TURN0) / (SKY_TURN1 - SKY_TURN0))
end

-- The body's tilt off horizontal, as a fraction of SKY_TILT. The product of
-- two smootherstep factors - the climb winding it up, the turn winding it down
-- - which is why the two windows may overlap without a seam to defend.
local function skyRot(p: number): number
	local launch = SKY_LAUNCH / SKY_TILT
	return (launch + (1 - launch) * smootherstep(p / SKY_APEX)) * (1 - skyTurn(p))
end

-- The bell: 0 at the surface, SKY_HEIGHT at SKY_APEX, exactly 0 at 1. The fall
-- is two terms - SKY_PIVOT of it spent during the pitch-over (that is the head
-- dropping so the body turns about its middle) and the rest a hang-then-
-- accelerate down to the floe.
local function skyBell(p: number): number
	if p <= SKY_APEX then
		return RimefangPath.SKY_HEIGHT * smootherstep(p / SKY_APEX)
	end
	local v = (p - SKY_APEX) / (1 - SKY_APEX)
	local over = (SKY_TURN1 - SKY_APEX) / (1 - SKY_APEX)
	local fall = SKY_PIVOT * smootherstep(v / over)
		+ (1 - SKY_PIVOT) * (0.28 * smootherstep(v) + 0.72 * smootherstep(v) ^ 2)
	return RimefangPath.SKY_HEIGHT * (1 - fall)
end

-- The bell hits zero at 1 as promised; BEACHED_Y is the floe's own freeboard,
-- added only as the beached shape arrives, so the landed body rests exactly
-- where `beached` rests it and the handoff moves nothing.
local function skyLift(p: number): number
	return skyBell(p) + BEACHED_Y * landFade(p)
end

local function skyPitch(state, t: number): number
	local p = math.clamp(state.skyfall or 0, 0, 1)
	local rot = skyRot(p)
	local spine = 1 - SKY_RELAX * smoothstep((t - 0.38) / 0.62)
	-- A gentle single hump while it comes down flat, dying as the beached
	-- shape arrives: the tail hangs a little below the line rather than the
	-- whole animal falling as a plank.
	local flat = skyTurn(p) * (1 - landFade(p))
	return -SKY_TILT * rot * spine + SKY_S * math.sin(2 * math.pi * t) * rot - SKY_SAG * math.sin(math.pi * t) * flat
end

local function skyYaw(state, t: number): number
	return beachedYaw(state, t) * landFade(math.clamp(state.skyfall or 0, 0, 1))
end

-- ---------------------------------------------------------------- compose

-- HOW MUCH OF EACH STANCE, and this is a weighted average rather than a
-- stack of lerps for one reason: `rise` and `beached` can BOTH be non-zero
-- on the client. They ease at different rates (4.5/s and 4.0/s) off a server
-- that switches between them, and the old composition applied `beached`
-- LAST and at full strength - so a whale coming up out of a spy-hop was
-- dragged back down onto the floe by a stale weight. Normalising means no
-- stance can be applied on top of a body that is already fully somewhere
-- else, and the result no longer depends on the order they are written in.
local function weights(state): (number, number, number, number, number, number)
	local arch = state.arch or 0
	-- Faded in over the first ~28% of the leap (was 15%) so leaving the water is
	-- a gradual emergence rather than a lurch: while the stance ramps, the head
	-- blends off the submerged rest toward the parabola, and the wider window
	-- halves the worst per-frame slide at launch. Quintic, so the launch has no
	-- jump in acceleration as the stance takes hold.
	local wArch = if arch > 0 then smootherstep(arch / 0.28) else 0
	-- The two arena moves join the same normalised pool, for the same reason
	-- and by the same rule: at progress 0 they weigh NOTHING, so the ordinary
	-- poses own the body, and they fade in over their own launch window.
	local burst = state.burst or 0
	local wBurst = if burst > 0 then smootherstep(burst / BURST_FADE) else 0
	local skyfall = state.skyfall or 0
	local wSky = if skyfall > 0 then smootherstep(skyfall / SKY_FADE) else 0
	local wRise = math.clamp(state.rise or 0, 0, 1)
	local wBeach = math.clamp(state.beached or 0, 0, 1)
	local total = wArch + wRise + wBeach + wBurst + wSky
	if total > 1 then
		wArch, wRise, wBeach = wArch / total, wRise / total, wBeach / total
		wBurst, wSky = wBurst / total, wSky / total
		total = 1
	end
	return wArch, wRise, wBeach, wBurst, wSky, 1 - total
end

-- Where the head is. This is `pointAt(state, 0)` exactly, and it is the one
-- thing the server asks for every frame, so it costs no integration at all.
local function anchorOf(state): Vector3
	local wArch, wRise, wBeach, wBurst, wSky, wBase = weights(state)
	local center = state.center or Vector3.zero
	local point = Vector3.zero
	if wBase > 0 then
		point += (center - UP * submergeDepth(state.submerge or 0)) * wBase
	end
	if wArch > 0 then
		local a = math.clamp(state.arch or 0, 0, 1)
		local leap = heading(state) * (ARCH_SPAN * (a - 0.5)) + UP * (math.sin(a * math.pi) * ARCH_HEIGHT)
		point += (center + leap) * wArch
	end
	if wRise > 0 then
		point += (center + UP * RISE_HEIGHT) * wRise
	end
	if wBeach > 0 then
		point += (center + UP * BEACHED_Y) * wBeach
	end
	if wBurst > 0 then
		local b = math.clamp(state.burst or 0, 0, 1)
		point += (center + UP * burstLift(b) + heading(state) * burstLead(b)) * wBurst
	end
	if wSky > 0 then
		-- No horizontal term at all: `center` IS the ground point under the
		-- head, and the server walks it launch -> impact. The path owns the
		-- vertical, and nothing else.
		point += (center + UP * skyLift(math.clamp(state.skyfall or 0, 0, 1))) * wSky
	end
	return point
end

-- The unit direction DOWN-body (toward the flukes) at `t`.
local function directionAt(state, t: number): Vector3
	local wArch, wRise, wBeach, wBurst, wSky, wBase = weights(state)
	local pitch, yaw = 0.0, 0.0
	if wBase > 0 then
		pitch += wBase * (swimPitch(state, t) + flukePitch(state, t))
		-- TURN INTO THE BANK. `roll` is the only turn cue the path is handed, and
		-- a banked animal is a turning one, so the body arcs in proportion to the
		-- bank, growing toward the tail (quintic, zero curvature at the neck). On
		-- the carousel this is the difference between a body curving round the
		-- ring and a rigid pole swept round it; the saturation keeps the wave
		-- wash's hard capsize an arc, not a coil. Only in the cruise stances -
		-- the reared and beached poses author their own yaw.
		local roll = state.roll or 0
		if roll ~= 0 then
			yaw += wBase * TURN_MAX * (roll / (1 + TURN_SAT * math.abs(roll))) * smootherstep(t)
		end
	end
	if wArch > 0 then
		pitch += wArch * archPitch(state, t)
	end
	if wRise > 0 then
		pitch += wRise * risePitch(state, t)
	end
	if wBeach > 0 then
		yaw += wBeach * beachedYaw(state, t)
	end
	if wBurst > 0 then
		pitch += wBurst * burstPitch(state, t)
		yaw += wBurst * burstYaw(state, t)
	end
	if wSky > 0 then
		pitch += wSky * skyPitch(state, t)
		yaw += wSky * skyYaw(state, t)
	end
	-- AMBIENT, outside every blend, which is the idiom ChainPose's header
	-- prescribes: folded into one side of a blend it would be annihilated at
	-- exactly the moment the animal should look most alive - the spy-hop's
	-- hold, which is the longest the fight ever asks you to stare at it.
	-- Small enough (about a stud at the flukes) that no hit test cares.
	local time = state.time or 0
	local taper = 0.25 + 0.75 * t
	yaw += math.rad(1.1) * math.sin(time * 0.9 - t * 2.2) * taper
	pitch += math.rad(0.7) * math.sin(time * 1.3 - t * 1.7) * taper

	local forward = heading(state)
	local flat = forward * -math.cos(yaw) + sideways(forward) * math.sin(yaw)
	return flat * math.cos(pitch) + UP * math.sin(pitch)
end

-- Where body position `t` (0 = the neck joint, 1 = the flukes) is, in world
-- space: the head, plus the body's direction integrated down to `t`. The
-- integrand is a UNIT vector, so the arc length from 0 to 1 is exactly
-- BODY_LENGTH whatever the pose or the blend.
function RimefangPath.pointAt(state, t: number): Vector3
	t = math.clamp(t, 0, 1)
	local point = anchorOf(state)
	local step = STEP_T * RimefangPath.BODY_LENGTH
	local whole = math.floor(t * STEPS)
	for i = 0, whole - 1 do
		point += directionAt(state, (i + 0.5) * STEP_T) * step
	end
	-- The part step, sampled at ITS midpoint, so `pointAt` is continuous in t
	-- across every grid line instead of stepping at each one.
	local rest = t - whole * STEP_T
	if rest > 1e-9 then
		point += directionAt(state, whole * STEP_T + rest * 0.5) * (rest * RimefangPath.BODY_LENGTH)
	end
	return point
end

-- The direction "up-body" (toward the head) at `t` - what a piece's +X axis
-- points along (the pack's forward convention, assets/boss_gen.py). Exact
-- here rather than a finite difference, because the curve is DEFINED by its
-- directions; ChainPose derives its own from the samples it took, and the
-- two agree to the sampling error.
function RimefangPath.tangentAt(state, t: number): Vector3
	return -directionAt(state, math.clamp(t, 0, 1))
end

-- Bank, per link. Full roll through the forebody, easing out along the tail
-- so the flukes stay flat-ish - a whale rolls its shoulders, not its tail.
-- This is where every stance's bank is composed, so that the centreline
-- (arc-length-critical) never carries a roll and the hitboxes never move with
-- one. All of it is post-applied about each link's own long axis.
function RimefangPath.rollAt(state, t: number): number
	-- Forebody-weighted profile, quintic so the shoulder-to-tail falloff has no
	-- kink: full at the head, 30% by the flukes.
	local profile = 1 - smootherstep((t - 0.35) / 0.65) * 0.7
	local total = (state.roll or 0) * profile

	-- The swim gait's shoulder rock: a small roll riding the stroke, lagging the
	-- wave and weighted forward, that fades with how hard the tail is working.
	local time = state.time or 0
	local swim = state.swim or 1
	total += SWIM_ROLL * swim * math.sin(time * SWIM_RATE * 0.5 - t * 1.3) * (1 - 0.5 * t)

	-- The breach corkscrew: the body banks INTO its leap, the twist swelling to
	-- the apex and unwinding to level at re-entry so the whale knifes back in
	-- upright. Zero at both ends of the leap, so nothing snaps.
	local arch = math.clamp(state.arch or 0, 0, 1)
	if arch > 0 then
		total += ARCH_BANK * math.sin(smootherstep(arch) * math.pi)
	end

	-- The eruption's bank: a swell and an unwind, like the breach's but half
	-- the angle - the ice breach is a drive up a line, not an arc through the
	-- air, so there is less turn to bank into. Zero at both ends of the move,
	-- and killed off entirely as the beached rock takes over.
	local burst = math.clamp(state.burst or 0, 0, 1)
	if burst > 0 then
		total += BURST_BANK * math.sin(smootherstep(burst) * math.pi) * (1 - landFade(burst))
	end

	-- The sky slam's CORKSCREW, and the one bank in this file that does not
	-- come back to level: it winds one way the whole climb, reaches SKY_FLANK
	-- as the body pitches over, and holds there - which is what puts the
	-- animal on its FLANK for the landing rather than on its belly. Squared,
	-- so the twist is slow off the surface and fastest near the top, and it
	-- unwinds only over the last stretch, into the beached rock below.
	local skyfall = math.clamp(state.skyfall or 0, 0, 1)
	if skyfall > 0 then
		total += SKY_FLANK * smootherstep(skyfall / SKY_TURN1) ^ 2 * (1 - landFade(skyfall))
	end

	-- The stranded rock: part-over on the floe, breathing slowly side to side.
	-- Both arena moves end lying on the floe, so both bring this on with them
	-- as they land - which is what makes the handoff to `beached` cost nothing
	-- in roll as well as nothing in position.
	local landed = math.clamp(state.beached or 0, 0, 1) + landFade(burst) + landFade(skyfall)
	if landed > 0 then
		total += BEACHED_ROLL * math.min(landed, 1) * (0.72 + 0.28 * math.sin(time * 1.4)) * (1 - 0.3 * t)
	end

	return total
end

-- The shape function ChainPose.new wants.
function RimefangPath.shape(state, t: number): Vector3
	return RimefangPath.pointAt(state, t)
end

return RimefangPath
