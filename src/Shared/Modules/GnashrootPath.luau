--!nonstrict
-- GnashrootPath.luau
-- Where every piece of Old Gnashroot is, right now: ONE boss's shapes.
--
-- The generic half lives in ChainPose (walking a path by arc length and
-- handing out CFrames) - BrinejawPath and KrakenPath are this file's
-- siblings. This one is only the mire colossus's geometry, and it carries two
-- kinds of shape because the creature is two things:
--
--   THE BODY - Mass, Roots, Head, Jaw, Maw, Fangs, Eye (x10), Core, Stones,
--   Drips,
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
--   * a fist stands 42.5 world studs out from the body's own axis at the
--     row's 1.5 scale, measured across all nine poses at the 2026-09-12
--     SECOND re-author (`disgorge`, the furthest; `heavePlant` is the
--     furthest that touches the ground, 39.3, and its fingertips reach 44.2).
--     That is a REACH and not a length of arm - the rest curve's arc is
--     25.608 authored, 38.4 world, and quoting the arc is the mistake this
--     line used to make. Re-picking "nearest player" between frames swings
--     the fist through up to twice 42.5 in one frame, so the hand teleports -
--     `heave`'s marching hump starts from that hand, so the hazard teleports
--     with it;
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
-- ...and ONE CLIENT-ONLY CHANNEL, which the server must never write:
--
--   Eyes 0..1        - the fraction of the eye row that is LIT, applied in
--                      EYE_SEATS order. nil means 1, so a fight that never
--                      mentions it gets every eye open and nothing changes.
--
-- IT IS CLIENT-ONLY ON PURPOSE. The eye row is a LOOK - GnashrootIntro opens
-- them one at a time as its own beat - and nothing in the fight reads it: no
-- hitbox, no target pick, no HUD. Published from the server it would be a
-- replicated write per eye per frame for a decoration, and worse, it would
-- become a number two systems could disagree about. `Fn.gnashrootPublish`
-- does not write it and must not start.
--
-- Gape is NOT published either: it falls out of Attack/AttackBlend/Strike, so
-- there is no way for the mouth and the bite to disagree (see `gape`).

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
-- THE HEAD IS THE CROWN NOW. The 2026-09-12 SECOND pass stood this animal
-- up: the body is a vertical loft with a real neck, and the skull sits ON
-- TOP of it (z 24.6..32.3) with the jaw hinged under the back of it and
-- opening DOWNWARD, so the mouth is the top-front of the silhouette. The
-- user's words were "the jaw should maybe be at the top of the body not in
-- the middle... redesign it to make it easier to understand what it actually
-- is", and every constant in this block moved for that.
GnashrootPath.CROWN = 32.3 -- the top of the SKULL, for anything drawn over it
GnashrootPath.JAW_HINGE = authored(0.6, 0.0, 24.9) -- Jaw + Fangs + Maw swing about this
-- THE CORE IS IN THE CHEST HOLLOW, recessed between the collarbones and
-- under the chin, so the one bright thing on the animal is in the one place
-- a player reads as its heart. Measured at build (boss_gen's
-- `build_gnashroot` HANDOFF): the torso's front face at z 16.2 is x 9.20 and
-- the knot's front is 10.50, so 1.30 studs of it stand proud of a 2.3 radius
-- and the rest is in the chest; the jaw's underside at that x is z 18.93,
-- which clears the knot's crown by 0.43 at a shut mouth and swings away from
-- it at any gape.
GnashrootPath.CORE = authored(8.2, 0.0, 16.2)
-- EIGHT vertebrae, not five. Five 5.2-stud bones on a 5.21 pitch put a hinge
-- you can see at every joint, and the user's word for the result was
-- "choppy": the limb read as a string of beads. Eight shorter ones on the
-- same arc carry 16% overlap and sample the curve half again as often, so a
-- pose blend never turns one bone more than a few degrees.
GnashrootPath.ARM_SEGMENTS = 8 -- vertebrae, plus the fist at the tip
-- MEASURED, not chosen: the rest curve `through` walks below is 25.608
-- authored studs of arc and 25.608 / 8 is this. boss_gen's HANDOFF prints the
-- same number off the same three points, and every other pose in POSE is
-- authored to 0.97..1.07 of that arc so the client's STRETCH clamp is never
-- reached. Move a joint and this has to be re-measured, not re-guessed.
GnashrootPath.ARM_PITCH = 3.201
GnashrootPath.ARM_HALF_WIDTH = 3.38 -- at the shoulder; the client tapers toward the fist
GnashrootPath.KNOT_EVERY = 4 -- every fourth vertebra is a knuckle (Gnashroot_ArmKnot)

-- How deep it waits before it rises, in AUTHORED studs like everything else
-- here - `bodyCFrame` is the one place it becomes world (x1.5 = 42.0).
--
-- NOT the row's `riseDepth`, despite what this used to say. For a POSED boss
-- the server never pivots the model: CreatureService's rising mode publishes
-- `rise` and lets the client draw the whole climb (`if def.pose then ...
-- colossusState(creature, def).rise = e`), so the row's 18 moves nothing here
-- and this number has to clear the animal's own crown by itself. It did not:
-- 18 applied in world units left the crown (27 authored, 40.5 world) standing
-- 22.5 studs out of the mud at rise = 0. Taken off CROWN, so a re-measured
-- head cannot leave a buried boss with its face showing.
GnashrootPath.RISE_DEPTH = GnashrootPath.CROWN + 1.0 -- 33.3 authored, 49.95 world

-- Full gape. Wide, because the jaw hinges at the BACK OF THE SKULL (the
-- hinge is 24.9 up, the crown 32.3) and swings a 14-stud jaw off it: at 34
-- degrees the chin tip falls from authored z 22.4 to 14.8 and swings in to
-- x 11.1, which still clears the chest (the torso's front face at that height
-- is x 9.4). The mouth therefore opens as a gape at the TOP of the animal,
-- which is the whole point of the second pass, and it cannot reach the mud.
--
-- THE SIGN IS THE CONTROLLER'S AND IT IS NEGATIVE: it applies
-- `CFrame.Angles(0, 0, -jawAngle)` about JAW_HINGE, which takes the +X end of
-- the jaw (the chin, at authored x 17.6) DOWN and back along its own arc. The
-- skull never moves. Rendered and checked, not reasoned:
-- assets/boss_gnashroot_pose_gape.png is this exact rotation at full gape.
GnashrootPath.JAW_MAX = math.rad(34)

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
	-- ASKED FOR while the punish window is open, on top of whatever the attack
	-- left behind - and then CAPPED by the ground (see `groundLean`). Added
	-- outright it buried both fists 3 to 8.6 studs for the whole 3.5s window,
	-- which is the one beat the fight teaches the player to watch. What
	-- survives the cap is 8.4 degrees over the rest silhouette - where most of
	-- the window is actually spent, the blend easing home at 14/s against
	-- `exposed`'s 6/s - and nothing at all over a full-weight attack pose,
	-- because every one of those is already authored at its own limit.
	--
	-- It is NOT what "puts the core inside a player's swing height", and no
	-- pitch could be: the core stands 33.0 world studs up at rest, 31.6 at
	-- that cap, 28.1 at the full 21 degrees and still 18.5 at 44. The tell is
	-- the chest coming FORWARD - the core travels 4.7 studs out over the legs
	-- and the controller burns it - not the core coming DOWN.
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
-- to move with it - and `groundLean` reads the wrist back out to cap the
-- punish window's extra pitch, so the two cannot be re-tuned apart.
--
-- THE RULE IS SIGNED, and `wristLean` below still reads it that way even
-- though no pose currently rakes behind the hinge: a nose-down lean LIFTS a
-- fist that is behind x = 0, so x * tan(lean) is negative there and the
-- ground has no opinion at all. (The old `wallow` did rake back, and read as
-- "z must be positive, it is a height" it floated 6.18 world studs. The move
-- is a forward sweep now - a rooted colossus cannot plough anywhere - but the
-- signed form is kept because the next pose that reaches back will need it.)
--
-- THE SHOULDER IS ON A REAL SHOULDER NOW. The morning build hung it at
-- { 6.0, 9.2, 20.5 } on a horizontal mound, which put the sockets on the
-- front of a hump; the second pass lofts the body VERTICALLY, so this is a
-- point on the widest ring of the torso (z 21.4, the shoulders) at bearing
-- 1.15 radians round it - high, forward of the spine, and wide. It is
-- DERIVED, not guessed: boss_gen's `_gn_shoulder_seat` computes it off the
-- torso profile and raises at build time if this literal and that profile
-- ever disagree by more than 0.02 studs.
--
-- THE ARCS ARE THE TUNING. The client draws a FIXED eight vertebrae and
-- stretches them to cover whatever arc a pose comes to, clamped to
-- STRETCH_MIN/MAX 0.85/1.30; past the top of that a gap opens at the wrist -
-- a hand detached from its arm. Measured over this table against a rest of
-- 25.608: gnash 0.979, disgorge 0.993, heaveBrace 0.996, hammerRaised 1.038,
-- hammerLanded 1.040, wallow 1.040, mire 1.048, heavePlant 1.068. Nothing is
-- near the clamp, so no pose in the book can pull a hand off. Re-author a
-- joint and re-run the build: boss_gen prints the whole table every time.
local SHOULDER = { 2.87, 8.73, 21.40 }

local POSE = {
	-- REST: hung forward off the shoulders, elbows kicked out, fists in the
	-- mud in front. This is the silhouette every attack is read against, so its
	-- three JOINT POINTS came off the builder (assets/boss_gen.py,
	-- `_gn_arm_path`) rather than out of this file.
	--
	-- THE CURVE THROUGH THEM DID NOT, and that is worth saying plainly because
	-- the arc length looks like it agrees with the pack. The builder draws a
	-- quadratic BEZIER - `shoulder.lerp(elbow, t).lerp(elbow.lerp(wrist, t), t)`
	-- - so the elbow is a control point it leans toward and never reaches,
	-- while `through` below passes THROUGH it and bulges further out. Measured
	-- over the same three points: the builder's curve is 20.83 studs of arc, a
	-- 4.17 pitch over five vertebrae; this file's is 23.10, a 4.62 pitch. The
	-- authored ARM_PITCH is 4.6 because that is the pack's own spacing constant
	-- (GN_ARM_SPACING), not a measurement of either curve - and the builder's
	-- own rest arm divides into 4.17, not 4.6. So this file's agreement to
	-- within rounding IS an artifact of the fatter curve. Nothing enforces the
	-- match and nothing here should be tuned as if it did: move a
	-- joint and the two numbers move independently, and the client's FIXED five
	-- pieces stretch to cover whatever arc comes out (STRETCH_MIN/MAX).
	rest = { elbow = { 9.5, 13.0, 13.5 }, wrist = { 17.5, 11.0, 2.00 } },

	-- GNASH: the head comes down, so the arms have to take the weight - fists
	-- planted wide and BACK, elbows high. A bite with the arms still hanging
	-- forward reads as the head falling off rather than as a bite.
	gnash = { elbow = { 6.5, 17.0, 15.5 }, wrist = { 13.0, 14.5, 3.97 } },

	-- WALLOW: it shovels the mere forward. The mass used to PLOUGH here - the
	-- server walked the creature and the arms raked behind it - and a rooted
	-- boss cannot: `speed = 0` now, and an attack whose read is forward travel
	-- on an animal that never travels is a move with no tell at all. The
	-- handler was already a marching `barrage` wall rather than a charge
	-- (nothing about the damage changes); this is the pose finally agreeing
	-- with it. Both arms sweep low and wide across the FRONT, and the wall of
	-- peat goes out from there.
	wallow = { elbow = { 11.5, 15.0, 11.5 }, wrist = { 21.5, 14.5, 5.36 } },

	-- DISGORGE: it rears and the throat swells, and the arms open out of the
	-- way of what is about to come up. Palms out, chest height.
	disgorge = { elbow = { 9.5, 18.0, 19.5 }, wrist = { 21.0, 19.0, 13.00 } },

	-- HEAVE: the latched arm drives a fist into the peat out front - that
	-- hand is where the marching hump starts, so it reaches further than any
	-- other pose and finishes low.
	-- ...and it is also THE CRAWL. GnashrootIntro drives `Attack = "heave"`
	-- with AimSide flipping while the emergence walks the stand-in's pivot in,
	-- so this pair has to read as HAULING at a partial Rise and not only as a
	-- plant on a fully risen body: both fists forward on the jaw side, low,
	-- and pulling. Rendered at the intro's own rise
	-- (assets/boss_gnashroot_pose_emerge.png, Rise 0.62). It will not read at
	-- Rise 0.3 only because the second pass stood the animal up: the head is
	-- the CROWN now, so it breaks the surface at rise 0.03, the two big eyes
	-- at 0.15 and the shoulders at 0.36. The thing looks at you long before
	-- its chest is out of the water, which is exactly the beat the doc asks
	-- for and exactly what the morning build (face at z 14.6, clear only at
	-- rise 0.48) could not give it.
	heavePlant = { elbow = { 14.8, 10.4, 12.0 }, wrist = { 24.0, 10.5, 4.23 } },
	-- ...and the other arm braces, because a colossus putting its weight on
	-- one fist has to put it somewhere.
	heaveBrace = { elbow = { 8.5, 16.0, 14.5 }, wrist = { 14.0, 14.0, 2.46 } },

	-- MIRE: both palms flat on the ground, elbows high. The ground softening
	-- under the whole party has to have a visible cause, and this is it.
	mire = { elbow = { 10.0, 16.5, 16.0 }, wrist = { 20.5, 13.0, 7.05 } },

	-- HAMMERFALL, the earned opening: both fists over the crown (~27) and
	-- brought together, then driven into the mud out front. Two poses, one
	-- attack - `strike` carries the arms between them.
	hammerRaised = { elbow = { 1.0, 16.6, 29.2 }, wrist = { 9.0, 8.0, 37.00 } },
	hammerLanded = { elbow = { 12.0, 15.0, 17.5 }, wrist = { 23.0, 10.5, 9.75 } },
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

-- How far FORWARD of its pose the grip shift can carry a fist, authored
-- studs. Named because two places need it: `drift`, which spends it, and
-- `groundLean`, which has to cap the body's pitch against the fist's furthest
-- excursion rather than against the pose - the ground rule is only true at
-- the reach it is measured at.
local GRIP_REACH = 1.7

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
	local grip = math.sin(time * 0.23 + phase) ^ 5 * GRIP_REACH * t * t
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
		-- CLIENT-ONLY (see THE STATE): the fraction of the eye row that is
		-- lit, in EYE_SEATS order. 1 is every eye open, which is what the
		-- fight runs at - only the intro ever moves it.
		eyes = 1,
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

-- ---------------------------------------------------------------- the eyes
--
-- THE EYE ROW IS RIG GEOMETRY, and it is TEN INSTANCES of one authored lump
-- (`Gnashroot_Eye`) rather than one baked scatter. A single mesh has one
-- Material and one Transparency, so "the eyes open one at a time" - the beat
-- the intro is built on - cannot be expressed on it at all.
--
-- TWO BIG ONES AND EIGHT SMALL, which is the second pass's answer to "it's
-- just too confusing to look at right now". The morning build scattered
-- fourteen seats of much the same size over the head AND the whole body, and
-- the result had no face in it: nothing on the animal read as ITS EYES. Rows
-- 1 and 2 are now a forward-facing pair under the brow ridge at radius 1.70 -
-- more than five times the area of any other seat - and the remaining eight
-- are r 0.62..0.72 on the temples and cheeks. All ten are on the SKULL;
-- nothing on the body competes with the head any more.
--
-- Each entry is (x, y, z, radius) in AUTHORED studs, copied from
-- assets/boss_gen.py's GN_EYE_SEATS - which prints this exact table as a Luau
-- literal on every build, so the two are diffable rather than merely believed.
-- Every seat is on the skull, and the skull is a 32-sided loft, so the
-- inscribed-polygon sag that left a morning-build eye 0.34 studs adrift is
-- half a percent of a radius here and no sink guard is needed.
--
-- THE ORDER IS LOAD-BEARING. `eyeLit` walks this table in order, so the row
-- opens with the two BIG eyes and then works back over the temples and down
-- the cheeks - the thing looks at you before you can see the rest of it.
-- Re-ordering this table re-choreographs the intro.
local EYE_SEATS = {
	{ 10.60, 3.00, 28.30, 1.70 },
	{ 10.60, -3.00, 28.30, 1.70 },
	{ 7.60, 4.60, 28.80, 0.72 },
	{ 7.60, -4.60, 28.80, 0.72 },
	{ 4.40, 5.20, 29.60, 0.68 },
	{ 4.40, -5.20, 29.60, 0.68 },
	{ 12.60, 3.10, 26.60, 0.62 },
	{ 12.60, -3.10, 26.60, 0.62 },
	{ 9.20, 4.70, 26.20, 0.66 },
	{ 9.20, -4.70, 26.20, 0.66 },
}

GnashrootPath.EYE_COUNT = #EYE_SEATS

-- One eye's body-local seat (AUTHORED, unscaled) and its radius. The client
-- folds in `bodyCFrame` and SCALE, exactly as it does for every other piece,
-- so an eye cannot be left behind by a lean or a rise.
function GnashrootPath.eyeSeat(index: number): (Vector3, number)
	local seat = EYE_SEATS[index]
	if not seat then
		return Vector3.zero, 0
	end
	return authored(seat[1], seat[2], seat[3]), seat[4]
end

-- How lit eye `index` is, 0..1, off the client-only `Eyes` fraction.
--
-- A FRACTION OF THE ROW, NOT A COUNT, and the one crossing the boundary gets
-- the remainder rather than snapping: ten eyes on a 0..1 track would
-- otherwise pop in ten discrete steps, which reads as a bug in the
-- tween. nil is 1 - a fight that never writes the channel has every eye open,
-- which is exactly today's behaviour.
function GnashrootPath.eyeLit(state, index: number): number
	local fraction = state.eyes
	if fraction == nil then
		fraction = 1
	end
	return clamp01(clamp01(fraction) * #EYE_SEATS - (index - 1))
end

-- ---------------------------------------------------------------- the body

-- How far the swell of the mass carries it, AUTHORED studs (x1.5 = 0.60
-- world). ~11 seconds a cycle: slow enough to read as something alive rather
-- than a bobbing prop, big enough to see at 27 studs of crown.
GnashrootPath.BREATH_RISE = 0.4

-- The slow swell of the mass. IT ONLY EVER LIFTS, and that is the whole of
-- this function's design.
--
-- Every wrist z in POSE is tuned to put a planted fist within 0.1 to 0.4 world
-- studs of the mud (the ground rule above), so a breath that swings both ways
-- drives both fists straight through the floor twice a minute. The old one was
-- `sin * 0.9` applied on the far side of the `* SCALE` boundary - so +/-0.9
-- WORLD studs against a hammerfall fist sitting at +0.18, 4.9 times the
-- clearance it had, and every ground pose in the table annihilated. Half the
-- travel, one direction, and authored units like everything else: the animal
-- settles onto its fists and swells up off them, and nothing it does can push
-- a hand under the floor. Zero while it is still buried, so the rise reads as
-- the rise and not as a rise with a wobble in it.
function GnashrootPath.breath(state): number
	local swell = 0.5 - 0.5 * math.cos((state.time or 0) * 0.57)
	return GnashrootPath.BREATH_RISE * swell * clamp01(state.rise)
end

-- How far the whole animal is lifted this frame, breath included, in AUTHORED
-- studs - `bodyCFrame` is the single place this becomes world. Shared by the
-- body and (through `bodyCFrame`) by both arms, so a rising Gnashroot brings
-- its arms up with it instead of leaving two fists in the peat.
function GnashrootPath.lift(state): number
	return GnashrootPath.RISE_DEPTH * (clamp01(state.rise) - 1) + GnashrootPath.breath(state)
end

-- Which way the body points this frame - the latch, made visible. See THE
-- CONTRACT: the idle watch is free, the attack's angle is not, and the blend
-- between them is the attack's own so nothing snaps at either end.
--
-- BLENDED AS A VECTOR, NOT AS AN ANGLE. `face + wrapAngle(aim - face) * blend`
-- is the obvious form and it has a seam in it: `wrapAngle` flips sign as the
-- free-running face sweeps past the ANTIPODE of the latched aim, which moves
-- the output by 2*pi*blend - invisible at blend 0 and 1, and a clean 180
-- degrees at blend 0.5, which is 53 studs of fist travel in one frame. It is
-- the blend that amplifies the wrap, so the fix is to stop interpolating the
-- wrapped number: lerp the two unit vectors and read the angle back. Measured
-- against a 5-degree face step sweeping the antipode, worst-case single-frame
-- yaw jump falls from 147/165/177 degrees (blend 0.40/0.45/0.50) to 15/27/177.
--
-- That last one is not a typo and cannot be removed: at EXACTLY antipodal and
-- EXACTLY half weight there is no continuous answer - the body is being asked
-- to be equally two opposite ways round - and the degeneracy is a single point
-- rather than the whole antipode line. Either side of it the jump is bounded
-- and small, which is what "the blend cannot amplify a wrap" buys.
function GnashrootPath.bearing(state): number
	local face = state.faceAngle or 0
	local aim = state.aimAngle or face
	local w = clamp01(state.blend)
	local x = math.cos(face) * (1 - w) + math.cos(aim) * w
	local z = math.sin(face) * (1 - w) + math.sin(aim) * w
	if x * x + z * z < 1e-12 then
		return if w >= 0.5 then aim else face
	end
	return math.atan2(z, x)
end

-- THE MUD IS A FLOOR. The pitch hinges at the mud line, so a fist standing x
-- studs in front of the hinge at height z goes UNDER the surface the moment
-- the body leans past atan(z / x) - the pose table's rule, read backwards.
--
-- Every ground-contact pose is authored right at its own lean, so none of them
-- has headroom. Re-measured for the 2026-09-12 arms (limit at the fist's
-- furthest reach, against the pose's own lean): gnash 15.3 / 17, wallow 13.1 /
-- 14, heavePlant 9.4 / 10, heaveBrace 9.0 / 10, mire 17.7 / 19, hammerLanded
-- 21.7 / 23 - every one of them already at or past its ground, which is what
-- `math.max(pitch, ...)` below exists to protect. REST - which never leans,
-- and which is where the punish window is actually spent, the blend easing
-- home at 14/s against `exposed`'s 6/s - is 4.2 degrees once the grip shift's
-- extra reach is allowed for. That is LESS headroom than the old 8.4, and for
-- a reason worth stating rather than tuning away: the rest fists now stand 20
-- authored studs out instead of 10.5 (they have to reach the bank from a body
-- that cannot walk to it), and a long arm at a low wrist is a shallow angle.
-- The window's tell was never this pitch anyway - see `exposed` in LEAN.
--
-- That is also why `exposed` cannot simply be ADDED to the lean: +21 on top of
-- any of them puts both fists metres underground for the whole window.
--
-- Taken off the wrist the pose is ACTUALLY at, not off a table of limits, so
-- re-tuning a wrist z moves the cap with it and the two cannot drift.
local function activeWrist(state, side: number): (number, number)
	local blend, strike = clamp01(state.blend), clamp01(state.strike)
	local attack = state.attack
	local rest = POSE.rest.wrist
	local x, z = rest[1], rest[3]
	if attack == "gnash" then
		x, z = POSE.gnash.wrist[1], POSE.gnash.wrist[3]
	elseif attack == "wallow" then
		x, z = POSE.wallow.wrist[1], POSE.wallow.wrist[3]
	elseif attack == "disgorge" then
		x, z = POSE.disgorge.wrist[1], POSE.disgorge.wrist[3]
	elseif attack == "heave" then
		-- Off the LATCHED side, exactly as `heaveShape` picks it: the planting
		-- arm reaches 15.5 and the bracing one 5.0, and it is the planting one
		-- that runs out of ground first.
		local wrist = if (state.aimSide or 1) == side then POSE.heavePlant.wrist else POSE.heaveBrace.wrist
		x, z = wrist[1], wrist[3]
	elseif attack == "mire" then
		x, z = POSE.mire.wrist[1], POSE.mire.wrist[3]
	elseif attack == "hammerfall" then
		-- `hammerShape`'s own lerp, at t = 1 where the curve IS the wrist.
		local raised, landed = POSE.hammerRaised.wrist, POSE.hammerLanded.wrist
		local fall = strike * strike
		x = raised[1] + (landed[1] - raised[1]) * fall
		z = raised[3] + (landed[3] - raised[3]) * fall
	end
	-- The blend home to rest, which is a plain lerp of the endpoints
	-- (ChainPose.blend) and so exact at the fist.
	return rest[1] + (x - rest[1]) * blend, rest[3] + (z - rest[3]) * blend
end

-- How far one arm's fist lets the body pitch before it goes under the mud.
local function wristLean(state, side: number): number
	local x, z = activeWrist(state, side)
	-- Against the fist's FURTHEST reach, not the pose's: the grip shift is
	-- always on, and a cap that breathed with it would rock the whole body at
	-- the grip's own rhythm.
	x += GRIP_REACH
	if x <= 0 then
		-- Nothing out in front of the hinge: a pose that rakes BEHIND (wallow)
		-- is LIFTED by a nose-down lean, so the ground has no opinion.
		return math.huge
	end
	return math.atan(z / x)
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
	local pitch = lean * blend
	-- THE PUNISH PITCH IS CAPPED, NOT STACKED. The attack's own lean always
	-- stands - its wrists were authored against it - and `exposed` may pitch
	-- the chest further only as far as the fists have ground for. With the
	-- window shut this is exactly `pitch`, so no attack's lean changed.
	local limit = math.max(pitch, math.min(wristLean(state, 1), wristLean(state, -1)))
	return math.min(pitch + LEAN.exposed * clamp01(state.exposed), limit)
end

-- LAST FRAME'S ANSWER, and the inputs it was computed from. A memo, not
-- state: every field of the key is read by the frame below, so a state that
-- has moved at all misses, and two callers holding two different states cannot
-- see each other's answer. (ChainPose keeps its samples the same way.)
local memo = {
	state = nil :: any,
	center = nil :: Vector3?,
	time = nil :: number?,
	rise = nil :: number?,
	faceAngle = nil :: number?,
	aimAngle = nil :: number?,
	aimSide = nil :: number?,
	attack = nil :: string?,
	blend = nil :: number?,
	strike = nil :: number?,
	exposed = nil :: number?,
	frame = CFrame.identity,
}

-- The ONE CFrame the whole body cluster is placed with (Mass, Roots, Head,
-- the eye row, Core, Stones, Drips - and the jaw group, off its hinge). Scale is
-- applied at this boundary and nowhere else, so every constant in this file
-- stays the authored number - `lift` included, which is why it is multiplied
-- here rather than carried in world units.
--
-- MEMOISED, because it is invariant in `t` and the arms ask for it once per
-- SAMPLE: two chains at 40 samples is 82 calls a frame, every one of them
-- identical, each otherwise three CFrame constructions, two multiplies and the
-- whole of `bearing`, `lean` and `lift` (five trig calls between them). The
-- clock alone guarantees the first call of a new frame misses.
function GnashrootPath.bodyCFrame(state): CFrame
	local c = state.center or Vector3.zero
	if
		memo.state == state
		and memo.center == c
		and memo.time == state.time
		and memo.rise == state.rise
		and memo.faceAngle == state.faceAngle
		and memo.aimAngle == state.aimAngle
		and memo.aimSide == state.aimSide
		and memo.attack == state.attack
		and memo.blend == state.blend
		and memo.strike == state.strike
		and memo.exposed == state.exposed
	then
		return memo.frame
	end
	local at = Vector3.new(c.X, c.Y + GnashrootPath.lift(state) * GnashrootPath.SCALE, c.Z)
	local frame = CFrame.new(at)
		* CFrame.Angles(0, -GnashrootPath.bearing(state), 0)
		* CFrame.Angles(0, 0, -GnashrootPath.lean(state))
	memo.state = state
	memo.center = c
	memo.time = state.time
	memo.rise = state.rise
	memo.faceAngle = state.faceAngle
	memo.aimAngle = state.aimAngle
	memo.aimSide = state.aimSide
	memo.attack = state.attack
	memo.blend = state.blend
	memo.strike = state.strike
	memo.exposed = state.exposed
	memo.frame = frame
	return frame
end

-- Body-local (authored, unscaled) to world.
local function toWorld(state, point: Vector3): Vector3
	return GnashrootPath.bodyCFrame(state) * (point * GnashrootPath.SCALE)
end

-- THE RECOVERY IS NOT THE WINDUP RUN BACKWARDS, and both numbers below exist
-- because the naive forms assumed it was. GnashrootBodyController eases
-- `strike` home at 22/s and `blend` at 14/s (its EASE table), so after a blow
-- lands the strike collapses while the arms are still coming back: through the
-- whole recovery `strike` is SMALLER than `blend`, and any gape that reads
-- "not struck yet" off a small strike re-opens the mouth behind the bite.

-- How much of `strike` shuts the jaw. The bite is the mouth CLOSING, so it has
-- to be shut before the blow and must not come back open behind it: at three
-- times the strike the jaw is closed a third of the way into the swing, and
-- the recovery's rebound peaks at 0.024 (0.9 degrees) 194ms out, with the arms
-- already home. `blend * (1 - strike)` re-opened to 0.335 - 12.7 degrees of
-- jaw, 43ms after the bite - which is a second, false tell on the one attack
-- whose whole read is the mouth. The windup, where strike is 0, is untouched.
local GNASH_SHUT = 3

-- How much `strike` still counts as "the blow has landed" - the hammerfall
-- bellow's GATE, deliberately low, and a gate rather than an amplitude.
-- Multiplying the bell by `strike` directly collapsed it into a 0.46 twitch
-- that peaked 26ms after impact and never reached half gape, because it was
-- decaying at 22/s over a bell that runs at the blend's 14/s. Gated, the same
-- bell reaches full gape 50ms out and holds above half for 88ms.
local STRUCK = 0.15

-- How wide the jaw is open, 0..1. DERIVED, not published: the mouth and the
-- blow come off the same two numbers, so they cannot disagree.
function GnashrootPath.gape(state): number
	local blend, strike = clamp01(state.blend), clamp01(state.strike)
	local attack = state.attack
	if attack == "gnash" then
		-- The bite IS the jaw closing, so the gape leads the blow and is shut
		-- well before the strike lands - and stays shut through the recovery.
		return clamp01(blend - GNASH_SHUT * strike)
	elseif attack == "disgorge" then
		-- Open through the windup and widest as the gobs leave.
		return blend * (0.6 + 0.4 * strike)
	elseif attack == "hammerfall" then
		-- The bellow after the blow: a bell over the RECOVERY (strike done,
		-- blend on its way home), peaking mid-way and shut again by the time
		-- the arms are back - so the gape never hangs open into the window and
		-- becomes a second, false tell. `strike` only says WHETHER it landed.
		return math.min(strike / STRUCK, 1) * math.sin(math.pi * (1 - blend))
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

-- NOTE ON GROUND HEIGHT: the poses that plant carry wrists at z = 2.46 to
-- 9.75 authored, which is NOT "just proud of the mud line" - it is whatever
-- x * tan(that pose's lean) comes to, so the fist lands ON the surface once
-- the pose is fully reached. Every planted row in POSE above is authored to
-- that identity exactly (gnash 13.0 x tan 17, wallow 21.5 x tan 14,
-- heavePlant 24.0 and heaveBrace 14.0 x tan 10, mire 20.5 x tan 19,
-- hammerLanded 23.0 x tan 23), so all of them land within a centimetre of
-- zero; `rest` is the one pose that really does sit proud, because it never
-- leans, and its 2.00 authored is 3.00 world of clearance. The breath adds 0
-- to +0.60 on top of every one of them and never subtracts, so nothing is
-- ever more than a centimetre under.
-- `disgorge` (+26.40) and `hammerRaised` (+51.47) are airborne by design.
--
-- AND THE FISTS NOW LAND ON THE BANK, which is the whole point of a boss that
-- cannot walk. Radial reach at full blend, world studs from the body's axis:
-- rest 31.0, gnash 29.2, heaveBrace 29.7, mire 36.4, hammerLanded 37.9,
-- wallow 38.9, heavePlant 39.3, disgorge 42.5 - and fingertips run ~4.9
-- further. The Rootmere is r 27 and its walkable bank r 29-70
-- (assets/arena_gen.py's HANDOFF), so every planted pose reaches peat a
-- player can stand on. `old_gnashroot.attacks.hammerfall.radius` is sized off
-- that 44 and not off the body.
--
-- The whole body is placed off the server's pivot, so those clearances are the
-- mere's surface wherever the boss is standing, and there is no terrain
-- sampling here at all - deliberately, because the Rootmere is one flat pool
-- (assets/island_gen.py, the swamp mere step) and a height profile that has
-- to be re-keyed after every marsh relayout is a bug waiting on a relayout.
-- If the mere ever gains a bed profile, it belongs here, the way
-- BrinejawPath.sandY does.

return GnashrootPath
