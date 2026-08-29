--!nonstrict
-- NoctyssPath.luau
-- Where every piece of the Lantern Choir is, right now: ONE boss's shapes.
--
-- The generic half lives in ChainPose (walking a path by arc length and
-- handing out CFrames). This file is only the trench's geometry, and it
-- carries TWO shapes rather than Brinejaw's one, because this boss is two
-- things:
--
--   THE CHOIR - seven angler-lure stalks stood in the Choirfloor's sockets
--   (assets/arena_gen.py). Each is a chain: `stalkPoint(state, i, t)` with
--   t = 0 at the root in its collar and t = 1 at the hood. A stalk rises and
--   then CROOKS inward over the pit, so its lantern hangs free out over the
--   floor - an angler's illicium, not a lamppost. Every attack is this shape
--   leaning somewhere and coming back.
--
--   THE MAW - Noctyss herself, who is under the shelf and surfaces only in
--   the punish window. Not a chain at all: one rise, one hinge.
--
-- Server and client both require this file, and that is the point:
--   * the server needs the BULB positions (that is where a stalk's hitbox
--     lives - the light is the target) and analytic beam tests, so a
--     lightsweep costs it no geometry;
--   * the client walks each stalk every frame to draw it.
-- Sharing the math means the light you dodge and the light you see cannot
-- drift apart.
--
-- The numbers below ARE the pose in assets/boss_noctyss_staged.png - the
-- staged render is the review artifact for this table, and boss_gen.py
-- mirrors these constants so a render can never flatter a shape the fight
-- cannot hold. Coordinates are Roblox's (Y up), arena-local until
-- `state.center` is added.

local NoctyssPath = {}

local TAU = math.pi * 2

-- ---------------------------------------------------------------- the floor

-- The socket ring, mirroring arena_gen's GL_SOCKETS: seven collars at r 34,
-- the first at 12 degrees. A stalk grows out of collar `i` and nowhere else.
NoctyssPath.SOCKET_R = 34.0
NoctyssPath.SOCKETS = 7

-- The pit the maw comes up through (arena_gen GL_PIT_R), and the shelf's
-- walking height. The pit's water sits at -5 over a bed at -7.5.
NoctyssPath.PIT_R = 15.0
NoctyssPath.SHELF_Y = 1.5

-- The six gaps between the arena's shadow fins, in AUTHORED degrees (see
-- `authored` below). She surfaces facing one of these: a colossus that rose
-- facing a rock would be the arena fighting its own boss, and these lanes are
-- how the party moves.
NoctyssPath.LANES = { 56.0, 112.0, 168.0, 224.0, 284.0, 352.0 }

-- THE MIRROR. Blender's +Y exports as Roblox's -Z (export_yup, the pack
-- convention), so a bearing authored in arena_gen.py is its NEGATIVE in here.
-- Every authored angle in this file goes through `authored()` so the two
-- files can be read side by side without holding a mirror in your head - and
-- so the choir cannot end up growing out of bare stone 90 degrees from its
-- collars, which is the one mistake this whole module exists to prevent.
local function authored(degrees: number): number
	return -math.rad(degrees)
end

-- The bearing of socket `i` (1-based), in radians.
function NoctyssPath.socketAngle(index: number): number
	return authored(12.0 + (index - 1) * (360.0 / NoctyssPath.SOCKETS))
end

-- Socket `i`'s position, arena-local (the collar's mouth).
function NoctyssPath.socketPoint(index: number): Vector3
	local angle = NoctyssPath.socketAngle(index)
	return Vector3.new(math.cos(angle) * NoctyssPath.SOCKET_R, 2.2, math.sin(angle) * NoctyssPath.SOCKET_R)
end

-- ---------------------------------------------------------------- rest pose

NoctyssPath.REST = {
	HEIGHT = 33.0, -- root to the top of the rise
	CROOK = 11.0, -- studs the top arcs INWARD over the pit
	BOW = 2.6, -- a lazy S, alternating around the ring
	ROOT_Y = 2.2, -- the root sits down in the socket collar
}

-- How far a leaning stalk pushes its lantern toward what it is aiming at.
-- Big enough that a swept beam visibly comes FROM a stalk you can point at.
NoctyssPath.LEAN_REACH = 9.0

-- The beam a lit stalk paints on the floor: a wedge from the socket out past
-- the shelf's edge, so there is nowhere to simply stand outside the light.
NoctyssPath.BEAM_REACH = 74.0
NoctyssPath.BEAM_INNER = 5.0 -- directly under the crook is the one safe pocket
NoctyssPath.BEAM_HALF_ANGLE = math.rad(9.0)

-- The maw, in the punish window. PITCH is shallow on purpose: the lower jaw
-- is the floor players stand on, and a steeper rise would be a ramp nobody
-- could fight on. Y_UP is where the skull's origin ends up (matching
-- boss_gen's NC_MAW), Y_DOWN where it waits.
NoctyssPath.MAW = {
	PITCH = math.rad(26.0),
	GAPE = math.rad(44.0),
	Y_UP = 4.2,
	Y_DOWN = -26.0,
	SCALE = 2.4, -- the row's body.scale; the jaw floor is sized off it
}

-- The choir breathes in unison, and the TRUE lure breathes against it. That
-- half-cycle offset is the whole tell, so it is defined once, here, rather
-- than in whichever controller happens to draw a bulb.
NoctyssPath.PULSE_PERIOD = 2.6
NoctyssPath.TRUE_LURE_OFFSET = 0.5 -- in cycles: dead against the choir

local function smoothstep(x: number): number
	x = math.clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end

-- A fresh pose state. One entry per socket, plus the maw's two numbers.
function NoctyssPath.newState(center: Vector3)
	local stalks = {}
	for i = 1, NoctyssPath.SOCKETS do
		stalks[i] = {
			alive = true,
			lean = 0, -- 0 at rest, 1 fully leaning into `beamAngle`
			beamAngle = NoctyssPath.socketAngle(i), -- the bearing its light is on
			douse = 0, -- 0 lit, 1 dark
			fall = 0, -- 0 standing, 1 collapsed (death)
		}
	end
	return {
		center = center,
		stalks = stalks,
		trueLure = 1, -- which socket carries the real lure this cycle
		mawRise = 0, -- 0 under the shelf, 1 fully up through the pit
		mawGape = 0, -- 0 shut, 1 open
		mawYaw = authored(NoctyssPath.LANES[1]),
		time = 0,
	}
end

-- ---------------------------------------------------------------- the choir

-- One stalk, root (t = 0) to hood (t = 1), arena-local.
--
-- A quadratic Bezier: straight up, then arcing INWARD over the pit so the
-- last tangent is near-horizontal and the hood overhangs. A lean rotates the
-- crook's end toward `beamAngle` and pushes it out; a fall drops the whole
-- curve to the stone and keeps only the root standing.
local function stalkCurve(state, index: number, t: number): Vector3
	local stalk = state.stalks[index]
	local angle = NoctyssPath.socketAngle(index)
	local inward = Vector3.new(-math.cos(angle), 0, -math.sin(angle))
	local lateral = Vector3.new(-inward.Z, 0, inward.X)
	local root = Vector3.new(
		math.cos(angle) * NoctyssPath.SOCKET_R,
		NoctyssPath.REST.ROOT_Y,
		math.sin(angle) * NoctyssPath.SOCKET_R
	)

	local rest = NoctyssPath.REST
	local fall = smoothstep(stalk.fall or 0)
	local height = rest.HEIGHT * (1 - 0.82 * fall)
	local bow = if index % 2 == 0 then rest.BOW else -rest.BOW

	-- Where the crook points. At rest it falls inward over the pit; leaning
	-- swings it onto the bearing the light is sweeping, and a collapse throws
	-- it outward and flat.
	local restTip = inward * rest.CROOK + lateral * (bow * 0.6)
	local aim = Vector3.new(math.cos(stalk.beamAngle or angle), 0, math.sin(stalk.beamAngle or angle))
	local leanTip = aim * (rest.CROOK + NoctyssPath.LEAN_REACH)
	local lean = smoothstep(stalk.lean or 0)
	local tip = restTip:Lerp(leanTip, lean) + aim * (28.0 * fall)

	local p0 = root
	local p1 = root + Vector3.new(0, height, 0) + lateral * bow
	local p2 = root + Vector3.new(0, height * 0.93 - 26.0 * fall, 0) + tip

	local inv = 1 - t
	return p0 * (inv * inv) + p1 * (2 * inv * t) + p2 * (t * t)
end

-- Arena-local -> world.
function NoctyssPath.stalkPoint(state, index: number, t: number): Vector3
	return state.center + stalkCurve(state, index, math.clamp(t, 0, 1))
end

-- The curve's direction at `t`, pointing UP-stalk toward the hood - the
-- pack's +X convention (assets/boss_gen.py: t = 0 at the root, so this is the
-- opposite sign to Brinejaw's head-first chain).
function NoctyssPath.stalkTangent(state, index: number, t: number): Vector3
	local step = 0.02
	local a = stalkCurve(state, index, math.clamp(t - step, 0, 1))
	local b = stalkCurve(state, index, math.clamp(t + step, 0, 1))
	local delta = b - a
	if delta.Magnitude < 1e-4 then
		return Vector3.new(0, 1, 0)
	end
	return delta.Unit
end

-- WHERE THE LANTERN IS. Three systems need this exact point and must agree:
-- the client parents the bulb's light to it, the server stands the stalk's
-- hitbox on it (the light IS the target - see the choir_stalk row), and the
-- fight's "shoot the true lure" check measures against it.
--
-- The hood is authored with its neck joint at the curve's end and the bulb
-- slung under its lip, so the bulb is the hood's own offset carried into
-- world space: forward along the tangent, and down.
function NoctyssPath.bulbPosition(state, index: number): Vector3
	local at = NoctyssPath.stalkPoint(state, index, 1)
	local forward = NoctyssPath.stalkTangent(state, index, 1)
	local up = if math.abs(forward.Y) > 0.99 then Vector3.new(0, 0, 1) else Vector3.new(0, 1, 0)
	local right = forward:Cross(up)
	if right.Magnitude < 1e-4 then
		right = Vector3.new(1, 0, 0)
	end
	local realUp = right.Unit:Cross(forward).Unit
	-- boss_gen NC_BULB scaled by the hood's 0.86: (6.6, 0, -3.2) in hood space.
	return at + forward * (6.6 * 0.86) + realUp * (-3.2 * 0.86)
end

-- Is `position` standing in stalk `index`'s beam? A wedge from the socket,
-- out past the shelf's edge, with one safe pocket directly underneath.
--
-- Analytic on purpose: the beam is a bearing and a half-angle, so testing a
-- player is three cheap numbers, and the server never builds any geometry to
-- run the fight's signature attack.
function NoctyssPath.beamHits(state, index: number, position: Vector3, pad: number?): boolean
	local stalk = state.stalks[index]
	if not stalk or not stalk.alive or (stalk.douse or 0) > 0.5 then
		return false
	end
	local socket = state.center + NoctyssPath.socketPoint(index)
	local to = Vector3.new(position.X - socket.X, 0, position.Z - socket.Z)
	local distance = to.Magnitude
	if distance < NoctyssPath.BEAM_INNER or distance > NoctyssPath.BEAM_REACH then
		return false
	end
	local bearing = math.atan2(to.Z, to.X)
	local delta = math.abs((bearing - stalk.beamAngle + math.pi) % TAU - math.pi)
	-- The wedge widens with distance in world terms already; `pad` lets a
	-- caller forgive a stud or two of body width.
	local half = NoctyssPath.BEAM_HALF_ANGLE + (pad or 0) / math.max(distance, 1)
	return delta <= half
end

-- The choir's breathing, 0..1. The true lure runs half a cycle out of step -
-- the fight's whole read, and the reason this lives in shared code.
function NoctyssPath.pulse(state, index: number, clock: number): number
	local offset = if index == state.trueLure then NoctyssPath.TRUE_LURE_OFFSET else 0
	return 0.5 + 0.5 * math.sin((clock / NoctyssPath.PULSE_PERIOD + offset) * TAU)
end

-- ------------------------------------------------------------------ the maw

-- The lane she surfaces on: whichever fin gap the party's centre is nearest.
function NoctyssPath.laneFor(angle: number): number
	local best, bestDelta = authored(NoctyssPath.LANES[1]), math.huge
	for _, degrees in NoctyssPath.LANES do
		local lane = authored(degrees)
		local delta = math.abs((lane - angle + math.pi) % TAU - math.pi)
		if delta < bestDelta then
			best, bestDelta = lane, delta
		end
	end
	return best
end

-- The skull's CFrame: up through the pit, nose high, facing its lane. The
-- jaw is this turned about the authored hinge (the client does the hinge;
-- the server only needs the mouth).
function NoctyssPath.mawCFrame(state): CFrame
	local rise = smoothstep(state.mawRise or 0)
	local maw = NoctyssPath.MAW
	local y = maw.Y_DOWN + (maw.Y_UP - maw.Y_DOWN) * rise
	local at = state.center + Vector3.new(0, y, 0)
	return CFrame.new(at) * CFrame.Angles(0, -(state.mawYaw or 0), 0) * CFrame.Angles(0, 0, maw.PITCH)
end

-- WHERE THE PARTY FIGHTS during the punish window: the middle of the lower
-- jaw, in world space. The walkable floor is anchored parts pinned here (the
-- creature mesh itself is collision-free like every other creature part), and
-- the gullet - the weak point - sits at the back of it.
function NoctyssPath.mawMouth(state): CFrame
	-- boss_gen NC_JAW's widest section is at x = -1.2, the scoop floor at
	-- z = -5.6, both scaled by the row's body scale.
	return NoctyssPath.mawCFrame(state) * CFrame.new(-1.2 * NoctyssPath.MAW.SCALE, -5.0 * NoctyssPath.MAW.SCALE, 0)
end

function NoctyssPath.gulletPosition(state): Vector3
	-- boss_gen NC_GULLET, in the skull's space.
	return (NoctyssPath.mawCFrame(state) * CFrame.new(-5.4 * NoctyssPath.MAW.SCALE, -1.8 * NoctyssPath.MAW.SCALE, 0)).Position
end

-- Is `position` inside the closing mouth? The bite at the end of the window
-- catches whoever is still standing in there.
function NoctyssPath.insideMouth(state, position: Vector3): boolean
	local mouth = NoctyssPath.mawMouth(state)
	local local_ = mouth:PointToObjectSpace(position)
	local scale = NoctyssPath.MAW.SCALE
	return math.abs(local_.X) <= 7.0 * scale
		and math.abs(local_.Z) <= 5.6 * scale
		and local_.Y > -3.0
		and local_.Y < 9.0 * scale
end

return NoctyssPath
