--!nonstrict
-- GnashrootPath.luau
-- Where every piece of Old Gnashroot is, right now: ONE boss's shapes.
--
-- The generic half lives in ChainPose (walking a path by arc length and
-- handing out CFrames) - BrinejawPath and KrakenPath are this file's
-- siblings. This one is only the mire colossus's geometry, and it carries two
-- kinds of shape because the creature is two things:
--
--   THE BODY - Mass, Legs, Head, Jaw, Maw, Fangs, Eyes, Core, Stones, Drips,
--   all authored in ONE shared space (assets/boss_gen.py) and placed with a
--   SINGLE CFrame, the Kraken's convention. `bodyCFrame` IS that CFrame.
--   Nothing inside it moves except the jaw, about its printed hinge.
--
--   THE ARMS - two chains, one hung off each shoulder socket.
--   `armShape(side)` hands back a ChainPose SHAPE: t = 0 in the socket, t = 1
--   at the fist. Every attack is that shape blended away from rest and back
--   (ChainPose.blend), which is the whole reason there is no per-attack limb
--   code past the POSE table below - and no second animation system to keep
--   in step with this one.
--
-- Server and client both require this file, and that is the point:
--   * the server needs the FIST (`heave`'s hump marches out from the hand
--     that planted it) and the CORE (the punish target), and gets both as one
--     function call with no geometry at all;
--   * the client walks both arms every frame to draw them.
-- Sharing the math means the fist you dodge and the fist you see cannot drift
-- apart.
--
-- PURE MATH, like its siblings: no Instances, no state of its own, nothing
-- read off the DataModel. The single require is ChainPose, which is pure math
-- too, so the server can call anything here.
--
-- Coordinates are Roblox's (Y up), body-local until `bodyCFrame` places them.
--
-- ------------------------------------------- BEFORE THE SERVER HALF LANDS
--
-- Three rules from the Brinejaw lane's animation audit (2026-08-30), written
-- here because this is the file that will be tempted to break them, and the
-- argument against each is easier to win before anyone is attached to a
-- prettier version.
--
--   * EVERY NUMBER THE HITBOX USES MUST BE A VALUE THE RENDERER ALSO
--     CONSUMES, NOT ONE IT RECOMPUTES. Send the girth, send the ground
--     reference, send both clocks. Their drawn arm lagged the damaging arm by
--     9.3 degrees - 10.8 studs at the tip against a 6.8-stud lane, so past
--     r=41 the two did not overlap at all.
--
--   * NAME THE FRACTION, DO NOT REPEAT IT. Any number the damage code knows
--     and the drawing code needs is a named constant both read. Their worst
--     telegraph bug was a bare 0.62 living in a strike handler and simply
--     ABSENT from the tell - nothing links a literal in one place to an
--     absence in another, so "which of these two is wrong" was unanswerable.
--
--   * THE HONEST DRAWING IS THE ONE THAT LOOKS WORSE. `hammerfall` is a
--     `slam`, and slam damages in a ring centred on creature.pos - the BODY,
--     not the fist (CreatureService ATTACK_HANDLERS.slam.fire, verified). The
--     fist lands off-centre inside that ring. Draw the ring on the body
--     anyway, with the fist wherever the pose puts it: the fight is the
--     ground shaking, not the fist punching. Drawing it at the fist because
--     it reads better is a CONSTANT offset - no jitter, no framerate
--     dependence, ~25 studs wrong every single time - and a constant offset
--     survives review as art direction where a varying one gets measured.
--
--     (Checked while writing this: slam's `fire` runs at the instant the
--     windup expires, so hammerfall's `tell = "slam"` marker completes on the
--     same frame the damage lands. Handlers that fire PART WAY into the
--     strike - phantom 0.80, lunge 0.72, ringpulse 0.95 - are the ones whose
--     stock tell finishes early; none of them is in this boss's book.)
--
-- ---------------------------------------------------------- THE CONTRACT
--
-- AIM IS LATCHED ONCE, AT WINDUP, AND HELD FOR THE WHOLE ATTACK.
--
-- Every shape in this file reads `state.aimAngle` and `state.aimSide` and
-- NEVER looks for a player. Whoever drives the state calls `latch()` once, as
-- the windup starts, and does not call it again until the attack is over.
-- This is a rule of the module, not a note at one call site:
--
--   * an arm is ~34 studs of reach at the row's 1.5 scale. Re-picking
--     "nearest player" between frames moves the fist most of the arena's
--     width in one frame, so the hand teleports - and `heave`'s marching hump
--     starts from that hand, so the hazard teleports with it;
--   * in a party the nearest player changes constantly (two people trading
--     places is enough), so a boss that re-aims per frame swings at the
--     moving average of a crowd and connects with nobody. That does not read
--     as a bug; it reads as a boss that cannot be fought;
--   * the tell is drawn from the latched geometry too, and a telegraph that
--     moves while you are reading it is a death the player cannot own. The
--     Kraken's arms and Wrack's batteries both landed on this rule the hard
--     way (CreatureService, `wrackAim`, 2026-08-29).
--
-- The corollary is what keeps it from looking stiff: `faceAngle` - the idle
-- watch - may chase whoever it likes, every frame. `bearing()` folds it into
-- the latched angle by the attack's own blend, so the body finishes turning
-- INTO the swing it committed to and never away from it.
--
-- ---------------------------------------------------------- THE STATE
--
-- What the server publishes and the client eases toward (the contract with
-- GnashrootBodyController):
--
--   Rise 0..1        - 0 under the peat, 1 fully up
--   FaceAngle        - the idle watch; free to move every frame
--   AimAngle         - LATCHED at windup. See above.
--   AimSide +1/-1    - LATCHED at windup: which arm `heave` plants
--   Attack           - the attack's id, "" between attacks
--   AttackBlend 0..1 - how far the body is into that attack's pose
--   Strike 0..1      - 0 wound up, 1 the blow has landed
--   Exposed          - the punish window (the stock stagger attribute)
--
-- Gape is NOT published: it falls out of Attack/AttackBlend/Strike, so there
-- is no way for the mouth and the bite to disagree (see `gape`).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChainPose = require(Shared.Modules.ChainPose)

local GnashrootPath = {}

local function clamp01(x: number?): number
	return math.clamp(x or 0, 0, 1)
end

local function wrapAngle(a: number): number
	return (a + math.pi) % (math.pi * 2) - math.pi
end

-- ---------------------------------------------------------------- the mirror

-- The pack is exported glTF-style (export_yup, assets/boss_gen.py), so a
-- point authored in Blender at (x, y, z) arrives in Roblox as (x, z, -y).
-- Every number lifted from a HANDOFF line goes through this, so the builder
-- and this file can be read side by side without holding a mirror in your
-- head - which is the one mistake that would put the arms on the wrong flanks
-- and be invisible until someone watched a slam from behind.
local function authored(x: number, y: number, z: number): Vector3
	return Vector3.new(x, z, -y)
end

-- The same, mirrored onto one flank. `side` = +1 is the arm on the authored
-- +Y side, which after the mirror is the creature's LEFT: it faces +X with +Y
-- up, so its right hand is toward +Z.
local function flank(side: number, x: number, y: number, z: number): Vector3
	return authored(x, y * side, z)
end

-- ---------------------------------------------------------------- the mesh
-- Every number here is measured off the authored model (assets/boss_gen.py,
-- build_gnashroot) at scale 1: it FACES +X and STANDS on z = 0, the underside
-- of its mud pool, so the model drops onto the mere's surface with no fudging.
-- Change the mesh, change these.
GnashrootPath.SCALE = 1.5 -- the creature row's body.scale (Creatures.old_gnashroot)
GnashrootPath.CROWN = 27.0 -- the top of the head, for anything drawn over it
GnashrootPath.JAW_HINGE = authored(9.0, 0.0, 9.6) -- Jaw + Fangs + Maw swing about this
GnashrootPath.CORE = authored(3.4, 0.0, 18.6) -- the gnashroot burning in its chest
GnashrootPath.ARM_SEGMENTS = 5 -- vertebrae, plus the fist at the tip
GnashrootPath.ARM_PITCH = 4.6 -- studs between vertebra centres at rest
GnashrootPath.ARM_HALF_WIDTH = 3.5 -- at the shoulder; the client tapers toward the fist
GnashrootPath.KNOT_EVERY = 3 -- every third vertebra is a knuckle (Gnashroot_ArmKnot)

-- How deep it waits before it rises - the row's `riseDepth`, so the drawn
-- body comes up out of the peat exactly as long as the server says it does.
GnashrootPath.RISE_DEPTH = 18.0

-- Full gape. Wide, because the jaw hinges down at the chest (the hinge is 9.6
-- up, the crown 27): this animal's mouth is most of its front, and a modest
-- swing on a head that size does not read at all from the bank.
GnashrootPath.JAW_MAX = math.rad(38)

-- Body pitch per attack, radians, POSITIVE = nose down over its legs. The
-- pitch hinges at the authored origin (the mud line), so a lean is a colossus
-- tipping over its feet rather than a model rotating about its chest.
local LEAN = {
	gnash = math.rad(17),
	wallow = math.rad(14),
	disgorge = math.rad(-16), -- it REARS: the only pose that goes backward
	heave = math.rad(10),
	mire = math.rad(19),
	hammerRaised = math.rad(-9),
	hammerLanded = math.rad(23),
	-- Held while the punish window is open, on top of whatever the attack
	-- left behind: the chest pitched forward IS the window's tell, and it is
	-- what puts the core inside a player's swing height.
	exposed = math.rad(21),
}

-- ---------------------------------------------------------------- arm poses
--
-- Each entry is { elbow, wrist } for the +1 flank, in AUTHORED coordinates,
-- so a line here can be checked against a HANDOFF line without conversion.
--
-- The SHOULDER is not in the table: it is the same socket in every pose,
-- which is what pins t = 0 into the body no matter how far an attack reaches.
-- (The Kraken's lesson, spelled out in KrakenPath.armPoint: any term that is
-- not zero at the socket tears the limb out of the animal.)
--
-- THE WRIST HEIGHTS ARE SET AGAINST THE LEAN, not against the mud. The body
-- pitches about the mud line (`lean`), so on a 27-stud animal a 20-degree
-- lean drives an outstretched fist several studs UNDER the ground: a wrist
-- authored at z = 0.4 for `mire` ends up buried, and the press reads as the
-- hands going through the floor. Each ground-contact pose therefore carries
-- z ~= x * tan(its lean), which lands the fist ON the surface at the moment
-- the pose is fully reached. Re-tune a LEAN entry and its pose's wrist z has
-- to move with it.
local SHOULDER = { -1.0, 8.8, 18.2 }

local POSE = {
	-- REST: hung forward off the shoulders, elbows kicked out, fists in the
	-- mud in front. This is the silhouette every attack is read against, so it
	-- is the one pose whose numbers came off the builder rather than out of
	-- this file. It measures 23.1 studs of arc, which over five vertebrae is a
	-- 4.62 pitch - the authored 4.6, to within rounding. That agreement is not
	-- a coincidence to be preserved by luck: it is what lets the client place a
	-- FIXED five pieces and have them sit at the spacing the pack was cut for.
	rest = { elbow = { 1.5, 13.2, 10.5 }, wrist = { 10.5, 9.0, 1.8 } },

	-- GNASH: the head comes down, so the arms have to take the weight - fists
	-- planted wide and BACK, elbows high. A bite with the arms still hanging
	-- forward reads as the head falling off rather than as a bite.
	gnash = { elbow = { 0.0, 15.2, 12.5 }, wrist = { 6.0, 12.5, 1.9 } },

	-- WALLOW: the mass ploughs forward and the arms rake behind it. The
	-- forward travel is NOT here - the server walks the creature and the
	-- drawn body follows its pivot, so a surge in the pose too would move it
	-- twice. What this pose owns is the drag.
	wallow = { elbow = { -2.5, 14.5, 11.0 }, wrist = { -7.0, 12.0, 2.5 } },

	-- DISGORGE: it rears and the throat swells, and the arms open out of the
	-- way of what is about to come up. Palms out, chest height.
	disgorge = { elbow = { 2.5, 14.5, 17.5 }, wrist = { 13.0, 10.5, 13.0 } },

	-- HEAVE: the latched arm drives a fist into the peat out front - that
	-- hand is where the marching hump starts, so it reaches further than any
	-- other pose and finishes low.
	heavePlant = { elbow = { 3.5, 13.0, 11.5 }, wrist = { 15.5, 8.5, 2.8 } },
	-- ...and the other arm braces, because a colossus putting its weight on
	-- one fist has to put it somewhere.
	heaveBrace = { elbow = { 0.5, 15.5, 12.0 }, wrist = { 5.0, 13.5, 1.1 } },

	-- MIRE: both palms flat on the ground, elbows high. The ground softening
	-- under the whole party has to have a visible cause, and this is it.
	mire = { elbow = { 2.5, 15.5, 12.5 }, wrist = { 12.5, 11.5, 4.4 } },

	-- HAMMERFALL, the earned opening: both fists over the crown (~27) and
	-- brought together, then driven into the mud out front. Two poses, one
	-- attack - `strike` carries the arms between them.
	hammerRaised = { elbow = { -2.0, 12.5, 25.0 }, wrist = { 5.0, 7.5, 33.0 } },
	hammerLanded = { elbow = { 3.0, 14.0, 13.5 }, wrist = { 15.0, 7.5, 6.5 } },
}

-- A quadratic through THREE points - and THROUGH the middle one, at t = 0.5,
-- not merely leaning toward it. The elbow is a real landmark (the kick is
-- what makes the limb read as an arm instead of a hose), and a plain Bezier
-- control point would pull it back inboard and lose exactly the thing the
-- pose is for.
local function through(a: Vector3, b: Vector3, c: Vector3, t: number): Vector3
	local control = b * 2 - (a + c) * 0.5
	local u = 1 - t
	return a * (u * u) + control * (2 * u * t) + c * (t * t)
end

local function joint(triple, side: number): Vector3
	return flank(side, triple[1], triple[2], triple[3])
end

-- One pose's curve, body-local and unscaled, t = 0 socket to t = 1 fist.
local function limb(pose, side: number, t: number): Vector3
	return through(joint(SHOULDER, side), joint(pose.elbow, side), joint(pose.wrist, side), t)
end

-- IDLE LIFE. A colossus that is perfectly still reads as scenery, so nothing
-- here is ever quite at rest. Added AFTER the pose blend rather than baked
-- into any pose, so a new attack never has to remember to breathe.
local function drift(state, side: number, t: number): Vector3
	local time = state.time or 0
	-- Golden-angle-ish offset: the two arms must never move as one, or the
	-- ambient reads as the whole animal shivering.
	local phase = if side > 0 then 0.0 else 2.399
	-- Zero at the socket, so none of this can pull an arm out of the body.
	local envelope = 4 * t * (1 - t)
	local swing = math.sin(time * 0.80 + phase) * 0.55 * envelope
	local bob = math.sin(time * 0.62 + phase) * 0.45 * envelope
	-- THE GRIP SHIFT. `^5` keeps the sign and squashes the middle, so the fist
	-- is still most of the time and then moves - a plain sine here is a
	-- metronome, which reads worse than not moving at all. Weighted by t^2, so
	-- it is the hand that shifts and not the shoulder.
	local grip = math.sin(time * 0.23 + phase) ^ 5 * 1.7 * t * t
	-- A committed swing does not idle-sway.
	local calm = 1 - 0.8 * clamp01(state.blend)
	return Vector3.new(grip, bob, swing * side) * calm
end

-- ---------------------------------------------------------------- state

function GnashrootPath.newState(center: Vector3)
	return {
		center = center,
		time = 0,
		rise = 0, -- 0 = under the peat, 1 = fully up
		faceAngle = 0, -- who it is watching; may move every frame
		aimAngle = 0, -- LATCHED - see THE CONTRACT
		aimSide = 1, -- LATCHED - which arm `heave` plants
		attack = "", -- the running attack's id
		blend = 0, -- 0 = the rest silhouette, 1 = fully into that attack's pose
		strike = 0, -- 0 = wound up, 1 = the blow has landed
		exposed = 0, -- the punish window: chest forward, core open
	}
end

-- Which arm should plant, for a target on `angle`. Its own flank, so the
-- animal reaches across itself only when it has to.
function GnashrootPath.plantSide(state, angle: number): number
	-- Body-local bearing. The +1 flank sits at local -Z (see `flank`), so a
	-- target it should reach with that arm is the one at a negative bearing.
	local bearing = wrapAngle(angle - (state.faceAngle or 0))
	return if math.sin(bearing) < 0 then 1 else -1
end

-- COMMIT TO A TARGET. The only supported way to set the aim: call it once, as
-- the windup starts, and not again until the attack has finished. Everything
-- in THE CONTRACT above is about this function being called exactly once.
function GnashrootPath.latch(state, angle: number, side: number?)
	state.aimAngle = angle
	state.aimSide = if side then (if side < 0 then -1 else 1) else GnashrootPath.plantSide(state, angle)
end

-- ---------------------------------------------------------------- the body

-- The slow swell of the mass. ~11 seconds a cycle: slow enough to read as
-- something alive rather than a bobbing prop, big enough to see at 27 studs
-- of crown.
function GnashrootPath.breath(state): number
	return math.sin((state.time or 0) * 0.57) * 0.9
end

-- How far the whole animal is lifted this frame, breath included. Shared by
-- the body and (through `bodyCFrame`) by both arms, so a rising Gnashroot
-- brings its arms up with it instead of leaving two fists in the peat.
function GnashrootPath.lift(state): number
	return GnashrootPath.RISE_DEPTH * (clamp01(state.rise) - 1) + GnashrootPath.breath(state)
end

-- Which way the body points this frame - the latch, made visible. See THE
-- CONTRACT: the idle watch is free, the attack's angle is not, and the blend
-- between them is the attack's own so nothing snaps at either end.
function GnashrootPath.bearing(state): number
	local face = state.faceAngle or 0
	local aim = state.aimAngle or face
	return face + wrapAngle(aim - face) * clamp01(state.blend)
end

-- Body pitch this frame, radians, positive = nose down.
function GnashrootPath.lean(state): number
	local blend, strike = clamp01(state.blend), clamp01(state.strike)
	local attack = state.attack
	local lean = 0
	if attack == "gnash" then
		-- The windup is the head RISING - that is the tell - and the strike is
		-- it coming down. A bite that starts falling during the windup has
		-- already spent the read.
		lean = LEAN.gnash * strike - LEAN.gnash * 0.4 * (1 - strike)
	elseif attack == "wallow" then
		lean = LEAN.wallow
	elseif attack == "disgorge" then
		lean = LEAN.disgorge
	elseif attack == "heave" then
		lean = LEAN.heave
	elseif attack == "mire" then
		lean = LEAN.mire
	elseif attack == "hammerfall" then
		-- Squared, because a hammer accelerates. A linear drop reads as the
		-- arms being lowered rather than thrown.
		lean = LEAN.hammerRaised + (LEAN.hammerLanded - LEAN.hammerRaised) * strike * strike
	end
	return lean * blend + LEAN.exposed * clamp01(state.exposed)
end

-- The ONE CFrame the whole body cluster is placed with (Mass, Legs, Head,
-- Eyes, Core, Stones, Drips - and the jaw group, off its hinge). Scale is
-- applied at this boundary and nowhere else, so every constant in this file
-- stays the authored number.
function GnashrootPath.bodyCFrame(state): CFrame
	local c = state.center or Vector3.zero
	local at = Vector3.new(c.X, c.Y + GnashrootPath.lift(state), c.Z)
	return CFrame.new(at)
		* CFrame.Angles(0, -GnashrootPath.bearing(state), 0)
		* CFrame.Angles(0, 0, -GnashrootPath.lean(state))
end

-- Body-local (authored, unscaled) to world.
local function toWorld(state, point: Vector3): Vector3
	return GnashrootPath.bodyCFrame(state) * (point * GnashrootPath.SCALE)
end

-- How wide the jaw is open, 0..1. DERIVED, not published: the mouth and the
-- blow come off the same two numbers, so they cannot disagree.
function GnashrootPath.gape(state): number
	local blend, strike = clamp01(state.blend), clamp01(state.strike)
	local attack = state.attack
	if attack == "gnash" then
		-- The bite IS the jaw closing, so the gape leads the blow and is shut
		-- by the time the strike lands.
		return blend * (1 - strike)
	elseif attack == "disgorge" then
		-- Open through the windup and widest as the gobs leave.
		return blend * (0.6 + 0.4 * strike)
	elseif attack == "hammerfall" then
		-- The bellow after the blow: a bell over the RECOVERY (strike done,
		-- blend on its way home), peaking mid-way and shut again by the time
		-- the arms are back - so the gape never hangs open into the window and
		-- becomes a second, false tell.
		return strike * math.sin(math.pi * (1 - blend))
	end
	return 0
end

-- Radians the jaw group swings about GnashrootPath.JAW_HINGE.
function GnashrootPath.jawAngle(state): number
	return GnashrootPath.gape(state) * GnashrootPath.JAW_MAX
end

-- The punish target's world position - what the HUD marker and the core's own
-- effects hang off.
function GnashrootPath.corePosition(state): Vector3
	return toWorld(state, GnashrootPath.CORE)
end

-- ---------------------------------------------------------------- the arms

local function poseShape(pose, side: number)
	return function(_state, t: number): Vector3
		return limb(pose, side, t)
	end
end

-- HEAVE picks its pose per arm off the LATCHED side, so an arm cannot change
-- its mind about whether it is the one planting halfway through the swing.
local function heaveShape(side: number)
	return function(state, t: number): Vector3
		local pose = if (state.aimSide or 1) == side then POSE.heavePlant else POSE.heaveBrace
		return limb(pose, side, t)
	end
end

-- HAMMERFALL is up at the windup and down on the strike. Both ends are the
-- same curve family, so the fists come down the arc they went up rather than
-- cutting the corner, and `strike` squared gives the blow its weight.
local function hammerShape(side: number)
	return function(state, t: number): Vector3
		local strike = clamp01(state.strike)
		return limb(POSE.hammerRaised, side, t):Lerp(limb(POSE.hammerLanded, side, t), strike * strike)
	end
end

-- An attack's weight: its own blend while it is the one running, zero
-- otherwise. ChainPose.blend short-circuits at 0, so the whole nest below
-- costs six string compares per sample while the animal is idle.
local function weightOf(name: string)
	return function(state): number
		return if state.attack == name then clamp01(state.blend) else 0
	end
end

local function buildArmShape(side: number)
	local shape = poseShape(POSE.rest, side)
	-- EVERY ATTACK IS A BLEND AWAY FROM REST AND BACK. That is ChainPose's
	-- stated idiom and it is why there is no per-attack limb code below this
	-- point: adding an attack is a POSE entry and one line here. The weights
	-- are mutually exclusive (the boss runs one attack at a time), so the
	-- order of the nest does not matter.
	shape = ChainPose.blend(shape, poseShape(POSE.gnash, side), weightOf("gnash"))
	shape = ChainPose.blend(shape, poseShape(POSE.wallow, side), weightOf("wallow"))
	shape = ChainPose.blend(shape, poseShape(POSE.disgorge, side), weightOf("disgorge"))
	shape = ChainPose.blend(shape, heaveShape(side), weightOf("heave"))
	shape = ChainPose.blend(shape, poseShape(POSE.mire, side), weightOf("mire"))
	shape = ChainPose.blend(shape, hammerShape(side), weightOf("hammerfall"))
	return function(state, t: number): Vector3
		return toWorld(state, shape(state, t) + drift(state, side, t))
	end
end

-- Built once, because a shape is stateless - everything it reads arrives as
-- `state`. Both chains and the server share these two closures.
local ARM_SHAPE = { [1] = buildArmShape(1), [-1] = buildArmShape(-1) }

-- The ChainPose shape for one arm. `side` = +1 is the creature's left.
function GnashrootPath.armShape(side: number)
	return ARM_SHAPE[if side >= 0 then 1 else -1]
end

-- The fist's world position. What `heave` needs on the SERVER: its marching
-- hump starts at the hand that planted it, and this is the same function the
-- drawn chain's last sample comes from, so the two can never disagree.
function GnashrootPath.handPosition(state, side: number): Vector3
	return GnashrootPath.armShape(side)(state, 1)
end

-- NOTE ON GROUND HEIGHT: the rest and press poses put the fists at z = 0.2 to
-- 1.8 authored, i.e. just proud of the model's own mud line, and the whole
-- body is placed off the server's pivot. So the hands sit on the mere's
-- surface wherever the boss is standing, and there is no terrain sampling
-- here at all - deliberately, because the Rootmere is one flat pool
-- (assets/island_gen.py, the swamp mere step) and a height profile that has
-- to be re-keyed after every marsh relayout is a bug waiting on a relayout.
-- If the mere ever gains a bed profile, it belongs here, the way
-- BrinejawPath.sandY does.

return GnashrootPath
