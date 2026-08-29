--!nonstrict
-- KrakenPath.luau
-- The shape of the Kraken: one domed head parked in the middle of the
-- whirlpool, and eight arms leaving its crown.
--
-- Companion to BrinejawPath, and the same contract: PURE MATH, no Instances,
-- no state of its own. The server publishes a handful of numbers, both sides
-- run these functions off them, and the arm you dodge is the arm you see.
--
-- The difference from Brinejaw is what a "chain" means here. Brinejaw is ONE
-- body on one curve. The Kraken is eight independent curves that all start at
-- the same crown, so every arm carries its own state table (which IS the
-- ChainPose shape state) and they never talk to each other.
--
-- WHY THE ARMS ARE BOUND TO THE TENTACLE ROW: the fight spawns `parts.count`
-- kraken_tentacle creatures on a ring - those are the things you actually
-- hit. Rather than draw a separate monster at each one, each arm REACHES its
-- tentacle: t=0 is welded in the crown socket, t=1 lands on the tentacle's
-- hitbox. One octopus, eight targets, and no arm that points at nothing.

local KrakenPath = {}

-- ---------------------------------------------------------------- the mesh
-- Every number here is measured off the authored model (assets/boss_gen.py,
-- build_kraken) at scale 1, so a drawn arm leaves the socket the modelled
-- crown was actually cut for. Change the mesh, change these.
KrakenPath.HEAD_HEIGHT = 46.2 -- crown (z=0) to the top of the mantle
KrakenPath.HEAD_HALF_WIDTH = 19.8 -- the widest ring, at z = 14.5
KrakenPath.SOCKET_RADIUS = 18.2 -- the eight arm sockets' circle
KrakenPath.SOCKET_HEIGHT = -2.0 -- and how far below the crown they sit
KrakenPath.SEG_LENGTH = 5.4 -- one authored arm segment, tip to tip
KrakenPath.SEG_SPACING = 2.6 -- and the pitch they were authored to overlap at
-- How far an arm drops as it leaves the socket, before it starts to climb.
-- An arm has to come out from UNDER the mantle skirt; one that starts rising
-- immediately grows out of the head's cheek instead.
KrakenPath.SKIRT_DROP = 12.6

-- How big it is drawn. The arena is 34 studs to the platforms, and the brief
-- is that the head fills the middle of it: 19.8 x 1.4 = 27.7 studs of half-
-- width, standing 65 studs out of the water. You do not shoot over this.
KrakenPath.SCALE = 1.4

KrakenPath.ARM_COUNT = 8

-- The crown rides this far above the waterline once it is fully up. Low
-- enough that the arms come off the crown INTO the water rather than
-- hanging over it.
KrakenPath.CROWN_LIFT = 5.0
-- And this far under while it is still rising.
KrakenPath.RISE_DEPTH = 46.0

-- ---------------------------------------------------------------- head

function KrakenPath.newState(center: Vector3)
	return {
		center = center,
		time = 0,
		rise = 0, -- 0 = under the whirlpool, 1 = fully up
		faceAngle = 0,
		stance = 3,
	}
end

-- How far the whole animal is lifted this frame. Shared by the head and by
-- every arm, so a rising Kraken brings its arms up with it instead of
-- leaving them floating where the crown used to be.
function KrakenPath.lift(state): number
	local rise = math.clamp(state.rise or 1, 0, 1)
	return KrakenPath.CROWN_LIFT - KrakenPath.RISE_DEPTH * (1 - rise)
end

-- The head's frame: +X points where it is facing, the pack convention.
-- Sits at the crown, because that is where the mesh's origin is - the dome
-- is built upward from z=0 and the sockets hang just under it.
function KrakenPath.headCFrame(state): CFrame
	local c = state.center
	-- A slow swell so a waiting Kraken is never a statue.
	local swell = math.sin((state.time or 0) * 0.7) * 0.8
	local at = Vector3.new(c.X, c.Y + KrakenPath.lift(state) + swell, c.Z)
	return CFrame.new(at) * CFrame.Angles(0, -(state.faceAngle or 0), 0)
end

-- Where socket `index` (1..count) sits on the crown, in world space. The
-- angles match CreatureService.spawnBossParts exactly - it plants tentacle
-- `i` at `(i / count) * 2pi` - which is what lets an arm find its tentacle
-- by bearing alone.
function KrakenPath.socketAngle(index: number, count: number): number
	return (index / (count or KrakenPath.ARM_COUNT)) * math.pi * 2
end

function KrakenPath.socketPosition(state, index: number, count: number): Vector3
	local angle = KrakenPath.socketAngle(index, count)
	local c, r = state.center, KrakenPath.SOCKET_RADIUS * KrakenPath.SCALE
	return Vector3.new(
		c.X + math.cos(angle) * r,
		c.Y + KrakenPath.lift(state) + KrakenPath.SOCKET_HEIGHT * KrakenPath.SCALE,
		c.Z + math.sin(angle) * r
	)
end

-- ---------------------------------------------------------------- arms

-- One arm's state. This table IS the ChainPose shape state, so the renderer
-- mutates it in place every frame and never reallocates.
--   angle    - the socket's bearing; where the arm leaves the crown
--   reach    - horizontal studs from the arena centre to the arm's tip
--   tipY     - the tip's height relative to the crown socket
--   hump     - how high it arches on the way out (0 = a straight drape)
--   wave     - lateral sway, radians, biggest mid-arm
--   phase    - per-arm offset so eight arms never move as one
function KrakenPath.newArm(state, index: number, count: number)
	return {
		center = state.center,
		time = 0,
		lift = 0,
		angle = KrakenPath.socketAngle(index, count),
		reach = KrakenPath.SOCKET_RADIUS * KrakenPath.SCALE + 18,
		tipY = -6,
		hump = 7,
		wave = 0.10,
		breathe = 1.6,
		phase = index * 2.399, -- golden-angle-ish: no two arms in step
	}
end

-- The curve, t = 0 in the socket to t = 1 at the tip.
--
-- Three terms, and each one is zero at the socket ON PURPOSE - the arm can
-- swing, arch and breathe as much as it likes without ever tearing out of
-- the crown it is welded into.
function KrakenPath.armPoint(arm, t: number): Vector3
	local u = math.clamp(t, 0, 1)
	-- Segments bunch slightly toward the body, where the arm is thickest.
	local e = u ^ 0.92
	local socketR = KrakenPath.SOCKET_RADIUS * KrakenPath.SCALE
	local socketY = KrakenPath.SOCKET_HEIGHT * KrakenPath.SCALE

	-- 0 at both ends, 1 in the middle: the envelope every free term rides,
	-- which is what pins t=0 to the socket and t=1 to the tentacle.
	local bump = 4 * u * (1 - u)
	-- The arch, held off until the arm is clear of the head, and the dip that
	-- takes it there. Both are zero at u=0 and u=1 like everything else here,
	-- so the arm still starts in its socket and still ends on its tentacle.
	local climb = math.clamp((u - 0.14) / 0.86, 0, 1)
	local arch = math.sin(climb * math.pi) * arm.hump
	local skirt = -KrakenPath.SKIRT_DROP * math.sin(math.min(u / 0.16, 1) * math.pi)

	local radius = socketR + (arm.reach - socketR) * e
	local height = socketY
		+ (arm.tipY - socketY) * e
		+ arch
		+ skirt
		+ bump * math.sin(arm.time * 1.3 + arm.phase + u * 3.0) * arm.breathe
	local angle = arm.angle + bump * arm.wave * math.sin(arm.time * 0.9 + arm.phase)

	local c = arm.center
	return Vector3.new(c.X + math.cos(angle) * radius, c.Y + arm.lift + height, c.Z + math.sin(angle) * radius)
end

return KrakenPath
