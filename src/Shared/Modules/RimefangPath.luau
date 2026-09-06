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

-- Swim cycle. Two thirds of a wave down the body, so the tail trails the
-- head rather than the whole animal snaking in step.
local SWIM_RATE = 2.1
local SWIM_WAVES = 0.66
local SWIM_AMP = 2.6

-- Mirrors Bosses.rimefang.riseDepth. Read the header before changing it.
local SUBMERGE_DEPTH = 18.0
-- The spy-hop's stand: how far the head is above the waterline. See header.
local RISE_HEIGHT = 24.0
-- Mirrors Bosses.rimefang.breach.length / .leap. Read the header.
local ARCH_SPAN = 46.0
local ARCH_HEIGHT = 9.0
local BEACHED_Y = 2.2 -- lying on the floe, which floats ~2.4 proud
local THRASH_RATE = 5.5
local THRASH_AMP = 4.4

-- THE SPY-HOP'S SHAPE, as angles off vertical for the down-body direction.
-- STAND is how far off plumb the standing forebody leans; NECK is an extra
-- cock at the skull that decays over the first fifth of the body, so the
-- snout looks out over the floe (54 degrees of elevation) instead of at the
-- sky; TAIL is where the curl has got to by the flukes. FLEX > 1 keeps the
-- bend out of the rigid forebody and grows it toward the peduncle.
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
local RISE_TAIL = math.rad(112.0)
local RISE_FLEX = 2.4

-- THE LOBTAIL. `flukeUp` is progress through the WHOLE swing, not a lift:
-- the tail rears to FLUKE_RISE at 1, crosses its rest line at FLUKE_CROSS,
-- and drives to FLUKE_PUNCH below it around 0.22 before settling back at 0.
-- The old pose only ever LIFTED the back 45%, so the slam had nowhere to
-- land - the tail went up and the attack simply ended. Now the same
-- monotone ramp the server already publishes (windup 0 -> 1, strike 1 -> 0)
-- reads as a sink-and-heave anticipation and then a hammer through the
-- waterline: the fluke tip travels from +11.9 to -14.5 studs.
--
-- Neither angle goes near 90: a vertical tail tip is the one case
-- ChainPose.alongX genuinely cannot orient, and the fluke is drawn on it.
local FLUKE_RISE = math.rad(62.0)
local FLUKE_PUNCH = math.rad(34.0)
local FLUKE_CROSS = 0.45

-- Midpoint steps for the whole body. 24 puts the worst position error at
-- 0.018 studs against an exact integral, and the error varies smoothly with
-- t, so it cannot show up as a corner.
local STEPS = 24
local STEP_T = 1.0 / STEPS

local UP = Vector3.new(0, 1, 0)

local function smoothstep(x: number): number
	x = math.clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
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
	local phase = (state.time or 0) * SWIM_RATE - t * SWIM_WAVES * math.pi * 2
	local swim = state.swim or 1
	local slope = SWIM_AMP
		* swim
		* (1.6 * t ^ 0.6 * math.sin(phase) - t ^ 1.6 * math.cos(phase) * SWIM_WAVES * math.pi * 2)
	return math.atan(slope / RimefangPath.BODY_LENGTH)
end

-- The lobtail, as a bend that grows through the peduncle and holds out to
-- the flukes.
local function flukePitch(state, t: number): number
	local f = math.clamp(state.flukeUp or 0, 0, 1)
	if f <= 0 then
		return 0
	end
	local rear = smoothstep((t - 0.46) / 0.42)
	if rear <= 0 then
		return 0
	end
	local up = FLUKE_RISE * smoothstep((f - FLUKE_CROSS) / (1 - FLUKE_CROSS))
	-- A half-sine bump over 0..FLUKE_CROSS, squared so it leaves and rejoins
	-- the rest line with zero slope: the swing has no corner at either end.
	local dip = math.sin(math.pi * math.min(f, FLUKE_CROSS) / FLUKE_CROSS)
	return (up - FLUKE_PUNCH * dip * dip) * rear
end

-- THE SPY-HOP. It stands on its tail, cocks its head at someone, and the
-- rest of the body curls back and under. One curve, no seam.
local function risePitch(_state, t: number): number
	local phi = RISE_STAND + RISE_NECK * (1 - smoothstep(t / 0.20)) + (RISE_TAIL - RISE_STAND) * t ^ RISE_FLEX
	return phi - math.pi * 0.5
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
	-- the launch angle and eases to level over the next ~20 studs of itself,
	-- rather than snapping to flat the way a clamp would.
	return -ARCH_ANGLE0 * (1 - smoothstep(-sigma / 0.42))
end

-- BEACHED. Landed flat on the floe, working itself back toward water. The
-- thrash is LATERAL here and nowhere else - a stranded whale wallows on its
-- side, and the contrast with the vertical swim cycle is what sells that it
-- is out of its element and briefly killable.
local function beachedYaw(state, t: number): number
	local phase = (state.time or 0) * THRASH_RATE - t * 3.0
	local slope = THRASH_AMP * (1.4 * t ^ 0.4 * math.sin(phase) - t ^ 1.4 * math.cos(phase) * 3.0)
	return math.atan(slope / RimefangPath.BODY_LENGTH)
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
local function weights(state): (number, number, number, number)
	local arch = state.arch or 0
	-- Faded in over the first slice of the leap so leaving the water is a
	-- blend rather than a snap; full weight for the rest of the arc.
	local wArch = if arch > 0 then smoothstep(arch / 0.15) else 0
	local wRise = math.clamp(state.rise or 0, 0, 1)
	local wBeach = math.clamp(state.beached or 0, 0, 1)
	local total = wArch + wRise + wBeach
	if total > 1 then
		wArch, wRise, wBeach = wArch / total, wRise / total, wBeach / total
		total = 1
	end
	return wArch, wRise, wBeach, 1 - total
end

-- Where the head is. This is `pointAt(state, 0)` exactly, and it is the one
-- thing the server asks for every frame, so it costs no integration at all.
local function anchorOf(state): Vector3
	local wArch, wRise, wBeach, wBase = weights(state)
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
	return point
end

-- The unit direction DOWN-body (toward the flukes) at `t`.
local function directionAt(state, t: number): Vector3
	local wArch, wRise, wBeach, wBase = weights(state)
	local pitch, yaw = 0.0, 0.0
	if wBase > 0 then
		pitch += wBase * (swimPitch(state, t) + flukePitch(state, t))
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
function RimefangPath.rollAt(state, t: number): number
	local roll = state.roll or 0
	if roll == 0 then
		return 0
	end
	return roll * (1 - smoothstep((t - 0.35) / 0.65) * 0.7)
end

-- The shape function ChainPose.new wants.
function RimefangPath.shape(state, t: number): Vector3
	return RimefangPath.pointAt(state, t)
end

return RimefangPath
