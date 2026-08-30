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

function BrinejawPath.spireRadius(y: number): number
	local drums = BrinejawPath.SPIRE_DRUMS
	for _, drum in drums do
		local y0, y1, r0, r1 = drum[1], drum[2], drum[3], drum[4]
		if y <= y1 then
			local t = math.clamp((y - y0) / (y1 - y0), 0, 1)
			return r0 + (r1 - r0) * t
		end
	end
	return 5.2
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

local function smoothstep(x: number): number
	x = math.clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end

-- A fresh pose state. `coil` counts DOWN as it loses its grip.
function BrinejawPath.newState(center: Vector3)
	return {
		center = center,
		coil = BrinejawPath.MAX_COIL,
		unwind = 0, -- 0 coiled, 1 tail fully off the tower
		sweepAngle = 0,
		sweepHeight = BrinejawPath.SWEEP_LOW,
		slump = 0, -- 0 reared, 1 head down on the sand (the punish window)
		faceAngle = BrinejawPath.REST.BEARING - 0.8, -- who it is watching
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
		return top * (1 - u) ^ 2 + control * (2 * (1 - u) * u) + start * u ^ 2
	end

	if t <= rest.HELIX_END then
		return helix((t - rest.NECK_END) / (rest.HELIX_END - rest.NECK_END))
	end

	-- Slack: the tail leaves the tower, spirals down and lies on the sand.
	local k = (t - rest.HELIX_END) / (1 - rest.HELIX_END)
	local inner = BrinejawPath.spireRadius(bottomY) + rest.CLEARANCE
	local theta = rest.BEARING + rest.TURNS * TAU + rest.TAIL_TURN * TAU * k
	local r = inner + (rest.TAIL_OUT - inner) * k ^ 0.75
	local y = bottomY + (BrinejawPath.sandY(rest.TAIL_OUT) + 1.2 - bottomY) * k ^ 0.6
	return Vector3.new(math.cos(theta) * r, y, math.sin(theta) * r)
end

-- The swept pose: the tail laid out along one bearing, at sweep height. `t`
-- is remapped so the further down the body you are, the further out you lie.
local function sweptPoint(state, t: number, blendStart: number): Vector3
	local k = math.clamp((t - blendStart) / math.max(1 - blendStart, 1e-3), 0, 1)
	local r = BrinejawPath.SWEEP_INNER + (BrinejawPath.SWEEP_REACH - BrinejawPath.SWEEP_INNER) * k
	local theta = state.sweepAngle or 0
	local y = BrinejawPath.sandY(r) + (state.sweepHeight or BrinejawPath.SWEEP_LOW)
	return Vector3.new(math.cos(theta) * r, y, math.sin(theta) * r)
end

-- Where the head slumps when it loses its grip: off the tower, onto the sand,
-- jaw within reach. The neck drags after it, so the front of the body follows.
local function slumpPoint(state, t: number): Vector3
	local rest = BrinejawPath.REST
	-- It slumps toward whoever it was facing, so the punish window opens
	-- where the party already is instead of across the ring.
	local theta = state.faceAngle or (rest.BEARING - 0.8)
	-- `fall` is written only by the death collapse: the head slides further
	-- out and settles lower as the grip finally goes. Without it the collapse
	-- eases four values that are all already at their targets, and the killer
	-- watches a motionless skull for 2.5 seconds.
	local fall = math.clamp(state.fall or 0, 0, 1)
	local reach = 26.0 + 8.0 * fall
	local k = math.clamp(t / 0.30, 0, 1) -- the front 30% of the body comes down
	local bottomY = rest.BOTTOM_Y - coilOffset(state)
	local r = reach - (reach - (BrinejawPath.spireRadius(bottomY) + rest.CLEARANCE)) * k
	local y = BrinejawPath.sandY(r) + 2.6 - 1.8 * fall + 9.0 * k ^ 1.5
	return Vector3.new(math.cos(theta) * r, y, math.sin(theta) * r)
end

-- ---------------------------------------------------------------- public

-- Where body position `t` (0 = snout, 1 = rattle) is right now, in world
-- space. Blends rest -> swept for the tail, rest -> slumped for the head.
function BrinejawPath.pointAt(state, t: number): Vector3
	t = math.clamp(t, 0, 1)
	local point = restPoint(state, t)

	local unwind = state.unwind or 0
	if unwind > 0 then
		-- The higher the unwind, the further UP the body the peel reaches, so
		-- the tail visibly comes off the tower turn by turn.
		local blendStart = 1.0 - 0.40 * unwind
		local w = smoothstep((t - blendStart) / 0.14) * unwind
		if w > 0 then
			point = point:Lerp(sweptPoint(state, t, blendStart), w)
		end
	end

	local slump = state.slump or 0
	if slump > 0 and t < 0.34 then
		local w = smoothstep((0.34 - t) / 0.34) * slump
		point = point:Lerp(slumpPoint(state, t), w)
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
	-- wrote the warning.
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

-- Is `position` caught by the sweep the state describes? Pure geometry: the
-- arm is radial, so a hit is "on this bearing, out on the sand, at the wrong
-- height". A LOW sweep is jumped (get above it); a HIGH one is stood under.
function BrinejawPath.sweepHits(state, position: Vector3, girth: number): boolean
	local center = state.center or Vector3.zero
	local dx, dz = position.X - center.X, position.Z - center.Z
	local r = math.sqrt(dx * dx + dz * dz)
	if r < BrinejawPath.SWEEP_INNER or r > BrinejawPath.SWEEP_REACH then
		return false
	end
	-- Angular half-width shrinks with radius so the arm's real thickness is
	-- constant - being far out must not mean being easier to clip.
	local half = math.atan2(girth, math.max(r, 1))
	local delta = math.abs((math.atan2(dz, dx) - (state.sweepAngle or 0)) % TAU)
	if delta > math.pi then
		delta = TAU - delta
	end
	if delta > half then
		return false
	end
	local armY = center.Y + BrinejawPath.sandY(r) + (state.sweepHeight or BrinejawPath.SWEEP_LOW)
	return math.abs(position.Y - armY) <= girth
end

return BrinejawPath
