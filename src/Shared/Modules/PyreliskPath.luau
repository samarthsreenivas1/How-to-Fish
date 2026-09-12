--!nonstrict
-- PyreliskPath.luau
-- Where every piece of Pyrelisk, the Ashfall Colossus is, right now: ONE
-- boss's shapes. GnashrootPath and BrinejawPath are this file's siblings.
--
-- Pyrelisk is a ROCK GOLEM rooted in the caldera lake of its own arena
-- (arena_gen.py, the Ashfall Throne). It never walks. The players circle it
-- on the rim path, out past a moat of lava, and everything that reaches them
-- is an arm. So this file is two things:
--
--   THE BODY - Core, Torso, Head, Jaw, Crown, Eyes, WalkDeck, authored in ONE
--   shared space (assets/boss_gen.py, build_pyrelisk) and placed with a
--   SINGLE CFrame, the Gnashroot/Kraken convention. `bodyCFrame` IS that
--   CFrame. Nothing inside it moves except the jaw, about its hinge.
--
--   THE ARMS - two of them, and unlike its siblings' arms these are NOT
--   chains. Pyrelisk's limbs are three rigid authored pieces (Shoulder,
--   UpperArm, Forearm, Hand) on real joints, so this file hands out JOINTS,
--   not a spline: shoulder -> elbow -> wrist -> fist, four points the client
--   turns into four CFrames and the server reads for hit geometry.
--
-- WHY DIRECTIONS AND NOT POSITIONS. A pose here is a pair of unit vectors -
-- where the upper arm points, where the forearm points - and the joints fall
-- out of those plus the authored bone lengths. Authoring joint POSITIONS
-- instead (Gnashroot's shape, correct for a chain that walks by arc length)
-- would let a hand-tuned pose imply a bone longer or shorter than the mesh,
-- and rigid pieces cannot stretch: the elbow would gap or the forearm would
-- telescope into the upper arm. Directions cannot express that mistake.
--
-- Server and client both require this file, and that is the point:
--   * the server needs the FIST (a slam's impact centre), the SEAMS (what a
--     player shoots to earn a stagger), and the DECKS (the collidable slabs
--     the climb happens on) - all as function calls with no geometry;
--   * the client walks the same joints every frame to draw the body.
-- Sharing the math means the fist you dodge and the fist you see cannot drift
-- apart.
--
-- PURE MATH: no Instances, no state of its own, nothing read off the
-- DataModel. The server may call anything here.
--
-- Coordinates are Roblox's (Y up), body-local until `bodyCFrame` places them.
--
-- ---------------------------------------------------- THE JOINTED REBUILD
-- (2026-09-09) THE ARM IS ANIMATED ON KEYFRAMES NOW, NOT LERPED AS A UNIT.
--
-- What was here: two shapes per attack - a windup pose and `rest` - and a
-- strike that lerped 85% of the way back through rest. Both bones moved on
-- the same number, so the elbow angle was whatever fell out of two endpoint
-- directions being blended in lockstep: a slam swung as ONE RIGID PIECE from
-- the shoulder. Nothing about it read as a limb with a joint in it.
--
-- What is here now: every attack is a TRACK - an ordered list of keyframes
-- over one parameter, `phase`, with its own easing per segment and its own
-- BODY COMMITMENT (pitch and tilt) keyed alongside the arm. The elbow angle
-- is authored per keyframe, so `handfall` cocks to 94 degrees of flex, holds
-- the fold over the top of the arc, and EXPLODES open to 36 degrees in the
-- last fifth of the strike. That snap is the blow.
--
-- PHASE IS A PURE FUNCTION OF THE TWO NUMBERS ALREADY ON THE WIRE:
--
--     phase = blend * (0.5 + 0.5 * strike)
--
-- so the windup walks phase 0 -> 0.5 (blend rising, strike still 0), the
-- strike walks 0.5 -> 1, and the recovery - which unwinds BOTH numbers
-- together - walks it monotonically back to 0. Nothing was added to the
-- attribute contract to get articulation: `Attack`, `AttackBlend` and
-- `Strike` are the same three attributes CreatureService always published,
-- spelled the same way, and a keyframe book is not something the wire needs
-- to know about.
--
-- ---------------------------------------------------- THE BODY COMMITMENT
--
-- A colossus that swings 150 studs of arm without moving its mass is a
-- puppet, and it is also SHORT: the new skeleton's shoulder is 126 studs up
-- and only 84 off the axis, and 58 + 64 + 28 = 150 studs of arm below it
-- reaches a standing fist to r 165.4 - eleven studs short of the middle of
-- the monolith ring and fifty short of its far edge. So the lean is not
-- decoration, it is REACH, and it is two rotations rather than one:
--
--   PITCH, about the body's lateral axis, nose down into the blow. Up to 16
--   degrees on `handfall`, which is the "commit the whole silhouette" the
--   brief asks for and is worth about nine studs of radius on its own.
--   TILT, about the body's own facing axis, rolling ONTO the working arm.
--   Only six degrees, and it is worth twenty-three studs, because it trades
--   shoulder HEIGHT (which the arm was spending on the drop) for shoulder
--   OFFSET (which the arm gets to spend on radius). See THE REACH BUDGET.
--
-- Both are keyed per keyframe, both go through `commit`, and `fistOffset`
-- applies exactly the same rotation the draw does - which it has to, because
-- the server places a shockwave at the radius `fistOffset` reports and the
-- client draws a fist at the radius `armJoints` produces. They were allowed
-- to disagree before (fistOffset ignored the old `lean` entirely); they are
-- one calculation now.
--
-- ---------------------------------------------------------- THE CONTRACT
--
-- AIM IS LATCHED ONCE, AT WINDUP, AND HELD FOR THE WHOLE ATTACK.
--
-- Every shape in this file reads `state.aimAngle` / `state.aimSide` and NEVER
-- looks for a player. Whoever drives the state calls `latch()` once as the
-- windup starts and does not call it again until the attack is over. The
-- reasons are the fleet's, learned the hard way on the Kraken's arms and
-- Wrack's batteries, and they bite harder here than anywhere:
--
--   * an arm is 150 studs of reach on a body that turns at 28 deg/s.
--     Re-picking "nearest player" between frames swings the fist across most
--     of the rim path in one frame, so the hand teleports - and a slam's
--     shockwave is centred on that hand, so the hazard teleports with it;
--   * this fight's whole contract is that you can READ what is coming. A
--     telegraph that moves while you are reading it is a death the player
--     cannot own, and it would undo the seams, the windups and the dial rings
--     painted on the arena floor all at once.
--
-- The corollary that keeps it from looking stiff: `faceAngle` - the idle
-- watch - may chase whoever it likes every frame. `bearing()` folds it into
-- the latched angle by the attack's own blend, so the body finishes turning
-- into a committed swing instead of snapping to it.
--
-- THE ONE SANCTIONED EXCEPTION: RIMSWEEP.
--
-- The rake's handler writes `state.aimAngle` every frame of its strike, and
-- that is deliberate, bounded, and the only place in the fight it happens.
-- What makes it legal is WHAT was latched. At windup the sweep commits its
-- whole path - the start bearing, the arc and the direction - and never
-- touches them again; the damaging bearing after that is a pure function of
-- the clock. So the per-frame write is not re-aiming at anybody: it is the
-- server ANIMATING a path it already committed to, turning the body so the
-- drawn fist stays on the bearing that is actually dealing the damage
-- instead of hanging seventy degrees behind it. The telegraph - the entry
-- mark on the band, drawn at windup - stays exactly where it was drawn, no
-- player position is read, and nothing about the hazard changes when someone
-- moves. Every other move latches once and holds. Adding a second exception
-- needs the same three properties: the path is fixed before the first frame
-- of it, no player is consulted, and the telegraph does not move.

local PyreliskPath = {}

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
-- head - the one mistake that would put the arms on the wrong flanks and stay
-- invisible until someone watched a slam from behind.
--
-- THE HANDOFF PRINTS BOTH READINGS. Its "ROBLOX rel (...)" half is already
-- negated; the numbers pasted into this file are the AUTHORED half, because
-- that is what `authored` expects. Pasting the pre-negated triple in here
-- mirrors it a second time, which is exactly how all nine arena monoliths
-- ended up on the wrong side of their own crater once.
local function authored(x: number, y: number, z: number): Vector3
	return Vector3.new(x, z, -y)
end

-- The same, mirrored onto one flank. `side` = +1 is the arm on the authored
-- +Y side, which after the mirror is the golem's LEFT: it faces +X with +Y
-- up, so its right hand is toward +Z.
local function flank(side: number, x: number, y: number, z: number): Vector3
	return authored(x, y * side, z)
end

-- ---------------------------------------------------------------- the mesh
--
-- Every number here is MEASURED off the authored model (assets/boss_gen.py,
-- build_pyrelisk) at scale 1 - the builder prints each of them on its own
-- HANDOFF line - and the model is authored at TRUE SIZE, unlike the older
-- packs which were cut small and scaled up by their creature row. Its base
-- sits on z = 0 because z = 0 is the caldera lake's surface, and the arena's
-- rim path is at that same height: boss space and arena space share a height,
-- so the body drops into the lake with no offset anywhere.
--
-- ALL OF IT WAS RE-KEYED ON 2026-09-09 against the remodelled body (region /
-- shell / boulder cladding). The colossus is SHORTER and NARROWER at the
-- shoulder than the pack this file was written for - crown 277 -> 206.9,
-- shoulder z 186 -> 126, reach 228 -> 150 - and every constant below moved
-- with it. Repo law: measure, don't derive. If a figure here disagrees with
-- a HANDOFF line, the HANDOFF line is right.
PyreliskPath.SCALE = 1.0
-- Top of the crown shards, for anything drawn over it - and for the SHOT
-- CAPSULE (CreatureService.raycastNearest), which is why it matters that it
-- is measured: everything between a guessed number and the real one is head,
-- and the head is what the fight asks you to shoot. "MEASURED crown top z
-- 206.9".
PyreliskPath.CROWN = 206.9
PyreliskPath.NECK = authored(8.0, 0.0, 152.0) -- Head + Jaw + Crown + Eyes hang here
PyreliskPath.JAW_HINGE = authored(-6.0, 0.0, 16.0) -- local to the head, not the body
-- The chest seam: phase 3's target. It IS `SEAMS[1]` - the same point, not a
-- number that resembles it - because the chest is one site on the shell and
-- the builder derives both from the same ring (boss_gen.py's PY_SEAM_SITES,
-- ring 1 at bearing 0). Kept as its own name because the two are asked
-- different questions (`corePoint` is what the collapse falls away from),
-- but if one moves the other has to move with it.
PyreliskPath.CORE = authored(47.0, 0.0, 99.5)

-- The arm, joint by joint. These ARE the builder's PY_RIG numbers.
-- AUTHORED SPACE, and the name says so: every other constant on this page
-- (NECK, CORE, JAW_HINGE, SEAMS, VENTS, DECK) has already been through
-- `authored()` and is body-local, but this one is a triple that only ever
-- goes through `flank`, which does the conversion itself. Handing it to
-- `toWorld` would put the shoulder on the wrong flank and look like a rig
-- bug rather than a units bug.
PyreliskPath.SHOULDER_AUTHORED = { -2.0, 84.0, 126.0 }
PyreliskPath.UPPER_ARM = 58.0
PyreliskPath.FOREARM = 64.0
PyreliskPath.HAND = 28.0
PyreliskPath.REACH = 150.0 -- the three above; the staged render asserts against it

-- HOW FAR OUT A RAKE ACTUALLY CROSSES THE PATH, measured from the BODY's
-- axis rather than from the shoulder - and it is a different number from
-- REACH, which is what made it worth naming.
--
-- They used to be the same by accident: the old arm was 228 long off a
-- shoulder 118 studs off-axis, so "the arm's length" and "the outermost stud
-- of path the fist crosses" were both about 228 and `rimsweep` clamped its
-- outer band with REACH. On this skeleton REACH is 150 and the rake's fist
-- reaches r 196 at the end of its travel, so the old clamp would have pulled
-- the damaged band in to 150 - INSIDE the row's own `inner` of 160 - and the
-- rake would have damaged an empty annulus, silently, forever. Exactly the
-- shape of bug the checklist calls a silent absence.
--
-- 200 is PY_CLEAR_R, the outer edge of open sky, and the rake's own travel
-- (r 150 at the draw to r 196 through the follow-through) sits inside it.
PyreliskPath.RAKE_OUT = 200.0

-- How deep it waits before it rises - the row's `riseDepth`, so the drawn
-- body comes up out of the lava exactly as long as the server says it does.
PyreliskPath.RISE_DEPTH = 40.0

-- Full gape. Modest, because this jaw is a blunt rock underjaw, and the head
-- it hangs off is a boulder rather than a muzzle: measured off the remodelled
-- pack the head is 56 studs tall and 53 across, with the snout tip at
-- head-local x = +31.1. Swing a jaw that blunt like a serpent's and it reads
-- as the face falling off.
PyreliskPath.JAW_MAX = math.rad(26)

-- WHERE THE SEAMS ARE. Each is a point on the shell with an outward normal,
-- and the pair is the whole contract between the art, the shot that hits it
-- and the telegraph that warns you: the client draws a Seam module here, the
-- server tests hits here, and `boss_gen.py`'s PY_SEAM_SITES authored the rock
-- around it. One table, three readers, so they cannot drift.
--
-- Index 1 is the CHEST: sealed for two phases, and the phase-3 target.
PyreliskPath.SEAMS = {
	{ at = authored(47.0, 0.0, 99.5), out = authored(0.996, 0.0, -0.088) },
	{ at = authored(35.6, 38.6, 84.1), out = authored(0.826, 0.434, -0.359) },
	{ at = authored(35.6, -38.6, 84.1), out = authored(0.826, -0.434, -0.359) },
	{ at = authored(4.5, 55.8, 58.0), out = authored(0.137, 0.915, -0.379) },
	{ at = authored(4.5, -55.8, 58.0), out = authored(0.137, -0.915, -0.379) },
	{ at = authored(18.5, 43.1, 23.6), out = authored(0.577, 0.813, -0.074) },
	{ at = authored(18.5, -43.1, 23.6), out = authored(0.577, -0.813, -0.074) },
}

-- The vent shafts on its back and shoulders: the breakables you smash while
-- standing on it. Same shape as SEAMS, different job - and each one stands on
-- a deck, so these follow DECK rather than the shell.
-- VENT 3 MOVED TO 140.1 ON 2026-09-12, and it moved because the rock under
-- it did: the surface weld (`_py_weld`, boss_gen) pulled torso boulders under
-- the right shoulder pad's footprint into contact with the mass, the pad
-- re-seated off the newly measured rock, and a vent standing on that pad's
-- face goes with it. The builder now ASSERTS these three rows against what it
-- measured (`_py_assert_path_agrees`) and fails the export on a mismatch, so
-- this cannot drift again in silence.
PyreliskPath.VENTS = {
	{ at = authored(-34.0, 0.0, 151.9), out = authored(-0.15, 0.0, 0.99) },
	{ at = authored(-4.0, 58.0, 142.9), out = authored(-0.12, 0.3, 0.95) },
	{ at = authored(-4.0, -58.0, 141.7), out = authored(-0.12, -0.3, 0.95) },
}

-- THE CLIMB ROUTE, and the only part of this body that is ever solid.
--
-- A posed boss is drawn entirely by the client, but `hideColossusModel` only
-- sets Transparency - it never touches CanCollide - so the real server model
-- is still standing there, invisible and solid, exactly where the pose says.
-- These are the slabs the server keeps collidable on it: the decks across its
-- back, and the forearm ramp that appears when an arm plants. Everything else
-- is drawn rock the server never asks anyone to stand on.
--
-- They are only collidable during a stagger window, which is the one time the
-- body is deliberately still - a player standing on an anchored part that
-- moves does not move with it, so the fight only offers footing it is not
-- about to take away.
--
-- THREE of them, and the shape is set by where the HEAD is: its cranium hangs
-- back over the spine, so a single bar across the shoulders puts a mounted
-- player under the jaw with no headroom. The route is instead a plateau up
-- the spine AFT of the skull and a pad on each shoulder, with one vent
-- standing on each - which is why VENTS above is placed against these decks
-- rather than against the shell. Every figure is the builder's, and the
-- builder SEATS them against the rock it actually built (`_py_seat_decks`)
-- rather than deriving them, so each has 0.6 studs of measured clearance over
-- the boulders underneath. Nothing indexes this table by position; everything
-- walks it.
PyreliskPath.DECK = {
	{ at = authored(-34.0, 0.0, 149.9), size = Vector3.new(24.0, 4.0, 80.0) }, -- the spine plateau
	{ at = authored(-4.0, 58.0, 140.9), size = Vector3.new(44.0, 4.0, 34.0) }, -- left shoulder pad
	{ at = authored(-4.0, -58.0, 139.7), size = Vector3.new(44.0, 4.0, 34.0) }, -- right shoulder pad
}
PyreliskPath.WALK_ARM_LIFT = 18.3 -- studs above the forearm's axis, MEASURED by the builder
PyreliskPath.WALK_ARM_SIZE = Vector3.new(48.0, 4.0, 18.0)

-- HOW HIGH EACH BONE'S PLATE RIDES, and it is NOT one number. Every limb
-- piece is a different thickness, and the plate is the top of the rock the
-- client is drawing: the builder's own boxes (the controller's AUTHORED_BOX,
-- pasted from boss_gen) put the UpperArm's crown at limb z = +27.5, the
-- Forearm's at +17.1 and the Hand's at +15.5, so one shared number lays at
-- least one of the three walking surfaces INSIDE the rock it is supposed to
-- be the top of.
--
-- ALL THREE CROWNS DROPPED ON 2026-09-11, when the rock was re-laid to make
-- the body one connected mass: the size roll was narrowed from 0.76..1.34 to
-- 0.90..1.20 and the tip off the surface normal more than halved, so the
-- chunks no longer stand as far proud of their bones. The UpperArm's crown
-- came down 3.6 studs and the Forearm's 2.0, and these two lifts came down
-- with them - a plate left at its old height is a walking surface hanging in
-- the air over the rock it is meant to be the top of.
--
-- The Forearm's is the builder's own measured figure (WALK_ARM_LIFT 19.5:
-- crown 17.1, plus 0.4 of clearance, plus half the slab). The UpperArm's is
-- NOT that convention - it is solved so the two plates meet FLUSH at the
-- elbow. A plate's top is `lift + thick/2` along its own bone's up, and that
-- offset foreshortens by the cosine of the bone's inclination, so two bones
-- at 66 and 53 degrees carrying the same lift arrive at the shared joint 14
-- studs apart. The solved ratio is the one the old pair encoded - upper-arm
-- up over forearm up = (21.5 + 2) / (33.5 + 2) = 0.66197 - so the new
-- forearm lift of 19.5 puts the upper arm's at (19.5 + 2) / 0.66197 - 2 =
-- 30.48. 30.5 holds the two walking faces within 0.02 studs of each other at
-- the elbow (the old pair managed 0.06), and leaves the plate's underside
-- 1.0 clear of the 27.5 crown - MORE than the 0.4 the builder gives the
-- ramp, which is the right side of that constraint to be on.
--
-- The two steps this moves, and both move the safe way: the Hand-to-Forearm
-- step SHRINKS (the forearm's face at the wrist drops 1.2 studs while the
-- hand plate stays at 11.0, so the old 3.1 becomes about 1.9), and the
-- shoulder bridge starts 3 studs lower onto an unchanged landing, so it is a
-- shallower ramp than it was. Nothing on the route got taller.
--
-- THE HAND IS DELIBERATELY LOWER THAN ITS MESH. Its own figure would be 17.9,
-- which puts the outer end of the step-on plate 9.2 studs above the rim path
-- - a step nothing can board, against a default jump of 6.4-7.2, and the
-- first step of the only route to the punish window. At 11.0 the plate's top
-- comes out at y 2.9 at the tip and 5.2 at the fist: you walk on, and the
-- drawn knuckles stand proud of the walking surface on either side, which is
-- what a fist driven into rock should look like anyway.
--
-- RE-MEASURED 2026-09-12 for the PLATED body (boss_gen's remodel: the boulder
-- cladding became flush armour plates over a molten underbody). The crowns
-- came down again, and unevenly: hand 15.5 -> 15.1, forearm 17.1 -> 15.9,
-- upper arm 27.5 -> 24.1. So the forearm's lift follows its own crown down to
-- 18.3 (= the builder's WALK_ARM_LIFT, measured) and the UPPER ARM'S IS
-- RE-SOLVED ON THE SAME RATIO the paragraph above derives - 0.66197, the one
-- that puts the two walking faces flush at the elbow: (18.3 + 2) / 0.66197 - 2
-- = 28.7. The hand's 11.0 is unchanged and is still deliberately below its own
-- mesh, for the boarding-step reason below.
PyreliskPath.BONE_LIFT = {
	Hand = 11.0,
	Forearm = 18.3, -- = WALK_ARM_LIFT: the client draws this one (rampCFrame)
	UpperArm = 28.7,
}

-- ---------------------------------------------------------------- the poses
--
-- A KEYFRAME is where the two bones POINT plus where the fist points, in
-- authored space, mirrored onto the working flank - and the body's own PITCH
-- and TILT at that instant, in degrees. `hand` is the fist's own bearing off
-- the wrist, which is what makes a planted hand lie flat on the rim path
-- instead of driving its knuckles into it.
--
-- `at` is the PHASE the keyframe lands on (see THE JOINTED REBUILD): 0.5 is
-- the end of the windup, 1.0 the end of the strike, and phase 0 is `REST`,
-- which every track starts from implicitly. `ease` is how the segment ENDING
-- at this keyframe is timed.
--
-- Solved rather than eyeballed: every keyframe below was produced by walking
-- the same math this file runs (shoulder + 58*upper + 64*fore + 28*hand,
-- through the keyed pitch and tilt) until the fist landed on a wanted point
-- with a wanted elbow angle. The elbow figures quoted in each comment are
-- the angle between `upper` and `fore` - 0 is a locked-straight arm.
local REST = {
	-- REST: hanging forward and out, knuckles IN THE LAVA. These are the
	-- builder's PY_HANG numbers verbatim, so the silhouette the party walks
	-- in on is the silhouette that was reviewed: fist at r 114.4, y -17.2,
	-- which is inside the lake's own r 120 - this thing stands in molten rock
	-- with its hands in it, and the pack's HANDOFF says so in as many words.
	-- Every attack is read against this shape.
	upper = { 0.16, 0.30, -0.94 },
	fore = { 0.22, 0.12, -0.97 },
	hand = { 0.30, 0.05, -0.95 },
}

-- ------------------------------------------------------------ THE REACH BUDGET
--
-- The arithmetic that decides whether this fight works at all, kept here
-- because it is the reason `handfall`'s last two keyframes carry 16 degrees
-- of pitch and 6 of tilt rather than a taste-driven number.
--
-- The bait targets are the arena's nine monoliths (BossArenas.volcano.stones)
-- and they ring the path at radii 158.9, 170.3, 188.5, 191.1, 196.9, 199.3,
-- 208.1, 213.3 and 217.0. A slam spends the nearest stone within
-- `stoneReach` = 30 of where the fist lands, so ONE landing radius R has to
-- satisfy R - 30 <= 158.9 and R + 30 >= 217.0, i.e. R must be in [187.0,
-- 188.9]. Outside that window some monoliths become permanently un-baitable,
-- silently: the stone still stands, the player still runs to it, the fist
-- still lands, and nothing happens.
--
-- What the arm can do unaided: the shoulder sits 84.0 studs off the axis and
-- 126.0 up, and 150 studs of arm brings a fist to the ground at
--     84.0 + sqrt(150^2 - 126.0^2) = 165.4
-- which the builder prints as its own HANDOFF line. That is 21.6 studs short
-- of the target window and 51.6 short of the outermost stone.
--
-- Where the missing 23 studs come from, and why tilt does the heavy lifting:
--   pitch 16 deg alone   shoulder (r 90.2, y 121.7)  ->  ground reach 178.5
--   pitch 16 + tilt 6    shoulder (r 101.7, y 112.2) ->  ground reach 191.1
-- Pitching swings the shoulder FORWARD, which is 90 degrees away from the
-- flank the arm works on, so it buys little. Tilting rolls the body onto the
-- working arm, which moves the shoulder OUTBOARD (84 -> 96.3 on the flank
-- axis) and DOWN (126 -> 112.2) at the same time - it adds radius and cancels
-- drop in one rotation. Six degrees is worth twice what sixteen of pitch is.
--
-- The result: the impact keyframe lands the fist at r 188.00, dead centre of
-- the [187.0, 188.9] window, with 3.6 studs of reach still in hand (the arm
-- is 96% extended, 36 degrees of elbow left, not locked out). Every monolith
-- is inside `stoneReach`: the nearest by 29.1, the farthest by 29.0. NO
-- SHORTFALL, and no arena or mesh change was needed to get there.
--
-- If the mesh's arm lengths or the shoulder height ever move again, this
-- window is what to re-solve against - and if a future skeleton cannot reach
-- 187 inside a sane lean, the answer is a decision about the arena's stone
-- ring or the arm's length, NOT a pose stretched into a shape a rock golem
-- could not hold.
local PLANT_PITCH, PLANT_TILT = 16.0, 6.0

-- THE PUNISH WINDOW'S POSE, and the only shape in this file that is MEASURED
-- rather than staged. It is the climb, so it is judged by where the joints
-- land and not by how it reads: the fist has to rest ON the rim path, inside
-- r 200 (past that the lip overhangs), and every joint above it has to be
-- reachable from the one below.
--
-- AND IT PLANTS WHERE THE FIST HIT. Its fist is at bearing -71.18, r 188.00 -
-- the same bearing to a hundredth of a degree and the same radius as
-- `handfall`'s impact keyframe - so the ramp appears exactly where the blow
-- everyone just watched landed, rather than sixty studs of arc round the ring
-- from it.
--
-- THE COMMITMENT IS FROZEN, NOT DROPPED. The old rule was that the body holds
-- perfectly upright while an arm is planted, because the server anchors real
-- collidable slabs along it and an anchored part does not carry the player
-- standing on it. That rule is about the body not MOVING, not about it
-- standing straight - and dropping the lean here would drop 23 studs of reach
-- with it, pulling the ramp's fist back to r 165 while the blow that earned
-- it landed at 188. So `commit` returns PLANT_PITCH / PLANT_TILT as
-- CONSTANTS while anything is planted: a mountain leaning its weight on the
-- arm it just drove into the ground, and not moving a stud for twenty
-- seconds.
local PLANT = {
	upper = { 0.3649, 0.4752, -0.8007 },
	fore = { 0.3895, 0.6542, -0.6483 },
	hand = { 0.3831, 0.8632, -0.3290 },
}

-- --------------------------------------------------------- THE FALLEN POSE
--
-- ACT 2, AND THEN THE COLLAPSE (re-keyed 2026-09-12). The colossus gives way:
-- it sinks into its own lake and pitches forward onto its arms, both of which
-- are creatures the party shoots off it from the rim path. It HOLDS this shape
-- for the whole of act 2, and when the second arm dies the same prostrate body
-- keeps going down through the opening caldera - see THE COLLAPSE SINK. What
-- this block no longer is: a route. The arm was once the only way to a neck
-- core and that entire idea is retired (the directive is quoted at THE ROCKS
-- AND THE CORE: RETIRED), so everything below about plates, slopes and
-- landings is the RECORD of what was measured off the built pack rather than
-- a description of anything the fight still walks on.
--
-- Everything in this block is MEASURED, and it was measured
-- against a solver that runs this file's own arithmetic (authored/flank,
-- bodyCFrame, boneUp, plateOn) rather than against the geometry the design
-- doc derived - because the doc's derivation was wrong twice, in ways that
-- only a walked route shows up:
--
--   1. IT MEASURED THE SLOPE OFF THE BONE, NOT OFF THE WALKING SURFACE. The
--      plate a player stands on rides BONE_LIFT above its bone's axis, and
--      those lifts are 13, 21.5 and 32.5 (they are the rock's own crowns,
--      which differ by twelve studs between the hand and the upper arm). So
--      the surface at the top of the arm is thirty-two studs above the
--      shoulder JOINT, and a route solved joint-to-fist is ten degrees
--      steeper than it claims to be.
--   2. THERE IS NOT ENOUGH RADIAL RUN. A shoulder at r 84 and a fist at
--      r 195 leave 111 studs of horizontal run for a surface that has to
--      climb about fifty - 24 degrees, before any lift disparity. The arm is
--      150 long, so the run it can actually offer is ~148, and the only way
--      to spend it is to lay the arm ROUND the rim rather than straight out
--      along the radius. It reaches forward across its own front instead.
--
-- What fell out of fixing both, and every figure is the solver's:
--
--   shoulder JOINT       r  88.7  y  17.5      (the doc's y 40 was the joint)
--   elbow                r 119.2  y  11.0
--   wrist                r 167.4  y  -9.9
--   fist                 r 192.0  y -11.8      (knuckles stand 3.7 proud of
--                                               the path; the rest is buried,
--                                               which is what a fist driven
--                                               into rock looks like)
--   the plate's tip      r 196.8  y   1.7      <- the step off the rim path
--   the shoulder pad     r  47.3  y  38.4      (where the route leaves the arm)
--   the neck collar      r  42.4  y  49.6      (the neck core stands here)
--
--   Hand plate      18.41 deg      UpperArm plate  16.91 deg
--   Forearm plate   19.00 deg      Shoulder bridge 14.77 deg
--   Neck plate      13.93 deg
--
-- Every junction is a ZERO step, because the route is laid as a chain of
-- FACE-TO-FACE bridges rather than as parallel plates: each slab's top passes
-- through the end of the one before it (`plateOn(a, b, -thick/2)`, the same
-- construction the shoulder bridge has always used). That is the whole reason
-- twelve studs of lift disparity costs nothing at the wrist and the elbow -
-- laid as parallel plates those two joints are an 8.5- and a 10.6-stud wall,
-- and closing them with per-bone lifts forces the bones to 46 and 58 degrees,
-- which is exactly how today's plant route ended up at 53 and 66.
--
-- THE TILT IS ZERO, ON PURPOSE, AND IT IS NOT A TASTE DECISION. Act 2 poses
-- both arms (planted = 0) and act 3 poses the same pair with one of them
-- carrying the climb (planted = +/-1). A tilt would have to be signed by a
-- flank, so it would differ between the two acts - and the act boundary would
-- then MOVE THE BODY, under a party standing on an arm, with the two arm
-- creatures already resolved once against `yaw0` (the design's SS3.2). Zero
-- tilt is what makes the boundary a no-op: nothing about the drawn body or
-- the collidable route changes when `planted` is set.
local FALLEN_PITCH, FALLEN_TILT, FALLEN_SINK = 14.0, 0.0, 105.2

-- THE FALLEN ROUTE'S OWN CONSTANTS ARE GONE (2026-09-12). `FALLEN_BOARD_LIFT`
-- (the boarding plate's lift at the fist), `FALLEN_PAD` / `FALLEN_COLLAR`
-- (where the route left the arm and where it arrived) and `FALLEN_CORE_AT`
-- (where the neck core stood) were measurements of a CLIMB, and the climb act
-- is retired - see THE ROCKS AND THE CORE: RETIRED at the foot of this file
-- for the directive and the date.
--
-- The POSE above survives whole and none of it was solved for the climb: it is
-- act 2's held shape, and with `SINK_COLLAPSE` on top of it, it is the
-- collapse's shape too. The measured joint table above stays as the record of
-- what was measured off the built pack, which is still what the pose is
-- judged by.

-- Segment timing. `ease` names how a segment ENDING at a keyframe is spent,
-- and it is the difference between a limb and a slideshow: a hammer is slow
-- into the cock, holds, then accelerates all the way to the ground.
local EASE = {
	linear = function(t: number): number
		return t
	end,
	-- accelerating: the mass getting away from it
	["in"] = function(t: number): number
		return t * t
	end,
	-- HARDER. Reserved for the last segment before an impact: a cube puts the
	-- peak speed at three times the segment's average, and it puts it AT the
	-- keyframe rather than before it, which is what makes the moment the fist
	-- lands the fastest instant of the whole swing rather than merely a fast
	-- one. With a square the mid-arc segment - which covers more ground - was
	-- quicker than the blow, and a slam whose descent is slower than its
	-- wind-over does not read as a slam.
	in3 = function(t: number): number
		return t * t * t
	end,
	-- decelerating: settling into a held shape, or the hard stop after a blow
	out = function(t: number): number
		return 1 - (1 - t) * (1 - t)
	end,
	inOut = function(t: number): number
		return t * t * (3 - 2 * t)
	end,
}

-- THE BOOK. One track per attack; the names are the ones CreatureService
-- publishes as `Attack`, and nothing here may be renamed without renaming it
-- there (`poseFor` looks the string up directly, and a miss draws `rest` -
-- an unfed rig that looks like a rig at ease).
local TRACK = {
	-- HANDFALL: the signature slam, and the only route to the long punish
	-- window. Five keyframes, and the elbow is the whole point of them:
	--
	--   0.500  COCK      elbow  94 deg   fist r 120, y 210, bearing -140
	--   0.720  OVER      elbow  87 deg   fist r 134, y 220, bearing -119
	--   0.880  DRIVE     elbow  96 deg   fist r 175, y  55, bearing  -80
	--   0.975  IMPACT    elbow  36 deg   fist r 188, y  -3, bearing  -71
	--   1.000  SETTLE    elbow  38 deg   fist r 187, y  -5
	--
	-- The fold does NOT open steadily. It holds at about ninety degrees for
	-- the whole raise and most of the descent - the forearm trailing the
	-- upper arm the way a hammer head trails the haft - and then opens sixty
	-- degrees in the last 0.095 of phase, which is the last 19% of the
	-- strike. That is where the speed is and it is why the blow reads as a
	-- blow rather than a bar swinging down.
	--
	-- THE TORSO GOES WITH IT. Pitch runs -7 (rocked back, loading) through
	-- -2.2 and +6.5 to +16 at the moment of impact: twenty-three degrees of
	-- mountain rotating into its own punch. Tilt runs -3 to +6 over the same
	-- span, rolling off the working arm and then onto it.
	--
	-- IMPACT IS AT PHASE 0.975 BECAUSE THE BLOW IS AT STRIKE 0.95
	-- (CreatureService's K.HANDFALL_IMPACT), and phase = 0.5 + 0.5 * strike
	-- during a strike. The ground telegraph is drawn at `fistOffset`'s answer
	-- for exactly that fraction and the shockwave fires there, so moving this
	-- keyframe moves the mark, the damage and the drawn fist together - and
	-- moving K.HANDFALL_IMPACT without moving this one separates them.
	handfall = {
		{
			at = 0.500,
			ease = "out",
			pitch = -7.0,
			tilt = -3.0,
			upper = { 0.1500, 0.5500, 0.8200 },
			fore = { -0.9000, -0.3200, 0.3000 },
			hand = { -0.5500, -0.2500, 0.8000 },
		},
		{
			at = 0.720,
			ease = "in",
			pitch = -2.2,
			tilt = -1.1,
			upper = { 0.2000, 0.7200, 0.6600 },
			fore = { -0.8800, -0.1000, 0.4600 },
			hand = { -0.3500, 0.0500, 0.9400 },
		},
		{
			at = 0.880,
			ease = "linear",
			pitch = 6.5,
			tilt = 2.3,
			upper = { 0.1607, 0.9149, 0.3704 },
			fore = { 0.1545, 0.2475, -0.9565 },
			hand = { 0.2134, 0.6106, -0.7626 },
		},
		{
			at = 0.975,
			ease = "in3",
			pitch = 16.0,
			tilt = 6.0,
			upper = { 0.3886, 0.8333, -0.3932 },
			fore = { 0.3516, 0.4071, -0.8430 },
			hand = { 0.3911, 0.6750, -0.6256 },
		},
		{
			at = 1.000,
			ease = "out",
			pitch = 16.5,
			tilt = 6.5,
			upper = { 0.3953, 0.8341, -0.3848 },
			fore = { 0.3536, 0.3845, -0.8527 },
			hand = { 0.3988, 0.6799, -0.6154 },
		},
	},

	-- RIMSWEEP: the arm draws back with a bent elbow and RAKES, opening as it
	-- travels, so the leading edge of the hazard is the forearm rather than a
	-- straight bar pivoting at the shoulder.
	--
	--   0.500  DRAW      elbow 53 deg   fist r 150, y 32
	--   0.700  LEAD      elbow 54 deg   fist r 168, y 18
	--   0.880  THROUGH   elbow 43 deg   fist r 188, y  5
	--   1.000  FOLLOW    elbow 20 deg   fist r 196, y  1
	--
	-- MEASURED ACROSS THE WHOLE RAKE, because this is the one pose whose
	-- every frame is the hazard rather than one instant of it: the fist stays
	-- at path height (y 32 down to 1) for the whole travel and inside the
	-- row's own band (inner 160, outer clamped to RAKE_OUT = 200) from the
	-- lead keyframe on. The body-local bearing only moves 14 degrees across
	-- the rake, which is deliberate - the SERVER turns the body to drive the
	-- sweep (the sanctioned exception in THE CONTRACT) and it corrects by
	-- this offset every frame, so a pose that also swung the fist round the
	-- body would make the colossus counter-rotate to stand still.
	rimsweep = {
		{
			at = 0.500,
			ease = "out",
			pitch = -4.0,
			tilt = -5.0,
			upper = { 0.2953, 0.8945, -0.3357 },
			fore = { 0.0631, 0.2927, -0.9541 },
			hand = { -0.0788, -0.1147, -0.9903 },
		},
		{
			at = 0.700,
			ease = "in",
			pitch = 3.0,
			tilt = 3.0,
			upper = { 0.3112, 0.9284, -0.2031 },
			fore = { 0.1581, 0.3848, -0.9094 },
			hand = { 0.0562, 0.0644, -0.9963 },
		},
		{
			at = 0.880,
			ease = "linear",
			pitch = 8.0,
			tilt = 8.0,
			upper = { 0.4137, 0.8871, -0.2047 },
			fore = { 0.2901, 0.5078, -0.8112 },
			hand = { 0.2344, 0.3683, -0.8997 },
		},
		{
			at = 1.000,
			ease = "out",
			pitch = 9.0,
			tilt = 8.0,
			upper = { 0.4831, 0.7755, -0.4065 },
			fore = { 0.4021, 0.5998, -0.6918 },
			hand = { 0.3676, 0.5315, -0.7632 },
		},
	},

	-- GRASP: low and open, palm up, dragging along the path. No row in
	-- Bosses.luau drives it today; it is kept because it is the one shape in
	-- the book that is a GRAB rather than a strike, and it is cheaper to keep
	-- it correct than to re-solve it later.
	grasp = {
		{
			at = 0.500,
			ease = "out",
			pitch = 6.0,
			tilt = 4.0,
			upper = { 0.1425, 0.0955, -0.9852 },
			fore = { 0.8094, 0.5453, -0.2181 },
			hand = { 0.6572, 0.4426, -0.6101 },
		},
		{
			at = 1.000,
			ease = "inOut",
			pitch = 10.0,
			tilt = 6.0,
			upper = { 0.1962, 0.1777, -0.9643 },
			fore = { 0.3520, 0.8903, -0.2890 },
			hand = { 0.3153, 0.6129, -0.7245 },
		},
	},

	-- VENTBREATH: the arms come up and out of the way of its own jaw, which
	-- is the only pose where they are not the point - so they BRACE rather
	-- than flail. Elbows hold 55 degrees of flex and close to 47 as the head
	-- rears, and the body pitches BACK (-6 to -12) instead of into anything:
	-- a furnace drawing breath, and the one silhouette in the book that
	-- leans away from the player.
	ventbreath = {
		{
			at = 0.500,
			ease = "out",
			pitch = -6.0,
			tilt = 0.0,
			upper = { 0.0500, 0.6200, 0.7800 },
			fore = { -0.7500, 0.2000, 0.6300 },
			hand = { -0.8000, 0.0500, 0.6000 },
		},
		{
			at = 1.000,
			ease = "inOut",
			pitch = -12.0,
			tilt = 0.0,
			upper = { 0.0000, 0.7200, 0.6900 },
			fore = { -0.7200, 0.4000, 0.5700 },
			hand = { -0.8200, 0.2200, 0.5200 },
		},
	},

	-- ASHFALL: BOTH arms up and wide, wrists out past the shoulder rubble.
	-- This is the one attack with no direction in it - the marks land under
	-- everybody at once - so the SILHOUETTE is the whole warning, and it has
	-- to read the same from every seat on the rim. Hence up and out rather
	-- than up and forward, which from behind is indistinguishable from a
	-- handfall windup. It is in BOTH_ARMS below for the same reason: one arm
	-- raised and one hanging is a directional shape, and this move has no
	-- direction to give.
	--
	-- The elbows LOAD at 47 degrees and fling open to 12 as the summit sheds,
	-- with the body heaving forward (+6) then throwing back (-14).
	ashfall = {
		{
			at = 0.500,
			ease = "in",
			pitch = 6.0,
			tilt = 0.0,
			upper = { 0.2000, 0.5500, 0.8100 },
			fore = { -0.5500, 0.3000, 0.7800 },
			hand = { -0.6200, 0.1800, 0.7600 },
		},
		{
			at = 1.000,
			ease = "out",
			pitch = -14.0,
			tilt = 0.0,
			upper = { 0.0500, 0.7200, 0.6900 },
			fore = { -0.1000, 0.6000, 0.7900 },
			hand = { -0.1500, 0.5200, 0.8400 },
		},
	},

	-- SHARDHURL: it tears a slab off its own shoulder and throws it. The
	-- windup folds the arm right up - 101 degrees at the elbow and 55 at the
	-- wrist, the hand up beside its own head where the rock comes from - and
	-- the throw is the elbow opening to 60 and then 42 as the arm comes over
	-- and out. One motion, and the release is the server's own strike
	-- fraction rather than a second animation that could disagree with it.
	shardhurl = {
		{
			at = 0.500,
			ease = "out",
			pitch = -5.0,
			tilt = -4.0,
			upper = { 0.1589, 0.0420, 0.9864 },
			fore = { 0.8748, -0.3609, -0.3232 },
			hand = { 0.2266, -0.1833, -0.9566 },
		},
		{
			at = 0.860,
			ease = "in",
			pitch = 10.0,
			tilt = 4.0,
			upper = { 0.4287, 0.8806, 0.2020 },
			fore = { 0.3876, 0.5477, -0.7415 },
			hand = { 0.3041, 0.3477, -0.8869 },
		},
		{
			at = 1.000,
			ease = "out",
			pitch = 12.0,
			tilt = 5.0,
			upper = { 0.3210, 0.9407, -0.1098 },
			fore = { 0.3258, 0.5969, -0.7332 },
			hand = { 0.3005, 0.4586, -0.8363 },
		},
	},

	-- FALLEN: act 2 and the collapse, and the only track in the book that is
	-- not an attack. See THE FALLEN POSE above for the arithmetic and for why
	-- it is not driven by `Attack`: act 2 still CASTS `ashfall` and
	-- `ventbreath` off the head and the summit, and drawing either of those on
	-- the arms would swing two arm creatures the party is shooting at through
	-- the shape of a windup. So this track is walked by `fallenPhase` (the act,
	-- or the client's own ease of it) and it OVERRIDES the attack book for both
	-- arms while it is engaged - INCLUDING the `collapse` track, which is why
	-- the death is this pose sinking rather than a second shape (the collapse
	-- contributes DEPTH through `SINK_COLLAPSE` and nothing else).
	--
	--   0.550  GIVING WAY   sink 57.9  pitch  7.7   arms reaching out ahead
	--   1.000  PROSTRATE    sink 105.2 pitch 14.0   the measured route
	--
	-- THE MIDDLE KEYFRAME IS AN INTERPOLATION WAYPOINT, NOT A MEASUREMENT,
	-- and the distinction is safe here in a way it would not be on an attack:
	-- its bone directions are `rest` blended 0.55 of the way to the settled
	-- pose, and its sink and pitch are the same fraction of theirs. NOTHING
	-- EVER STANDS ON IT, and since 2026-09-12 nothing stands on the settled
	-- keyframe either: `climbSlabs` hands back an empty route for the whole of
	-- the fallen pose (the climb act is retired), so this waypoint is a
	-- drawing and only a drawing.
	-- It exists so a client that eases into the pose eases through a shape
	-- that reads as a colossus going down on one knee rather than sliding
	-- into the lake in a straight line.
	--
	-- `sink` IS A NEW KEYFRAME FIELD and it is the one degree of freedom the
	-- old book had no way to express. Pitch and tilt rotate the body about its
	-- own origin, which is the lake surface, so no combination of them can
	-- LOWER a shoulder: pitching hard enough to bring the shoulder to y 40
	-- swings it out to r 146 and puts the neck BELOW it, which is the pose
	-- inverted. A colossus that kneels drops its origin, and `lift` is where
	-- that happens.
	fallen = {
		{
			at = 0.550,
			ease = "in",
			pitch = 7.7,
			tilt = 0.0,
			sink = 57.9,
			upper = { 0.8569, 0.1665, -0.4878 },
			fore = { 0.7994, 0.0489, -0.5988 },
			hand = { 0.8976, 0.0097, -0.4406 },
		},
		{
			at = 1.000,
			ease = "out",
			pitch = FALLEN_PITCH,
			tilt = FALLEN_TILT,
			sink = FALLEN_SINK,
			-- SOLVED, and the solver round-trips: fed back through `flank` and
			-- `armJoints` these three land the shoulder, elbow, wrist and fist
			-- on the measured points above to within 1e-6 of a stud.
			upper = { 0.9911, -0.0275, 0.1304 },
			fore = { 0.9958, -0.0262, -0.0872 },
			hand = { 0.9844, -0.0276, 0.1736 },
		},
	},

	-- COLLAPSE: it lets go. BOTH arms fall slack into the lake as the body
	-- goes down, which is the death `beginBossCollapse` runs. Near-straight
	-- on purpose - a slack arm has no muscle holding a joint - and the pitch
	-- runs forward as the mass gives way, on top of whatever `slump` adds.
	collapse = {
		{
			at = 0.500,
			ease = "inOut",
			pitch = 4.0,
			tilt = 0.0,
			upper = { 0.1200, 0.2600, -0.9600 },
			fore = { 0.0800, 0.1500, -0.9900 },
			hand = { 0.1200, 0.0700, -0.9900 },
		},
		{
			at = 1.000,
			ease = "inOut",
			pitch = 10.0,
			tilt = 0.0,
			upper = { 0.1000, 0.2400, -0.9700 },
			fore = { 0.0600, 0.1400, -0.9900 },
			hand = { 0.1000, 0.0600, -0.9900 },
		},
	},
}

-- THE ATTACKS THAT POSE BOTH ARMS. Every other shape in this file is one
-- arm's - `aimSide` works, the other hangs - but these two are the whole body
-- doing one thing, and drawing them one-armed reads as a bug: a colossus
-- dying with one arm sliding into the lake and the other still hanging
-- politely at its side, or a summit-shedding heave performed by half a
-- golem.
-- `fallen` is here too, and for a third reason on top of those two: a
-- prostrate colossus with one arm thrown out and the other hanging in its
-- rest curve is a figure that fell over while holding a pose, and in act 2
-- BOTH arms are creatures the party is shooting off the rim path. (It is
-- belt-and-braces - `poseFor` takes the fallen branch before it reads this
-- table - but a reader who finds `fallen` missing here will conclude the
-- one-armed draw was intended.)
local BOTH_ARMS = { collapse = true, ashfall = true, fallen = true }

PyreliskPath.TRACKS = TRACK
-- The final keyframe of each track, by name, for anything that wants "the
-- pose" as one shape - plus `plant`, which has no track because it is held
-- rather than played.
PyreliskPath.POSES = { plant = PLANT, rest = REST }
for name, track in TRACK do
	PyreliskPath.POSES[name] = track[#track]
end

local function dirOf(triple, side: number): Vector3
	local v = flank(side, triple[1], triple[2], triple[3])
	return if v.Magnitude > 1e-4 then v.Unit else Vector3.new(0, -1, 0)
end

-- Blend two poses' bones. Directions are lerped and re-normalised rather than
-- slerped: at the rates this fight uses the difference is invisible, and a
-- lerp cannot produce the NaN a slerp does when two directions are opposed -
-- which `handfall`'s cock and its impact very nearly are.
local function blendDir(a: Vector3, b: Vector3, t: number): Vector3
	local v = a:Lerp(b, clamp01(t))
	return if v.Magnitude > 1e-4 then v.Unit else a
end

-- WHERE IN A TRACK A GIVEN PHASE FALLS: the keyframe before it, the keyframe
-- after it, and the eased fraction between them. Phase 0 is REST with no
-- commitment, which is why `prev` starts as a literal rather than as
-- `track[1]`.
local REST_KEY =
	{ at = 0.0, pitch = 0.0, tilt = 0.0, sink = 0.0, upper = REST.upper, fore = REST.fore, hand = REST.hand }

local function segmentAt(name: string, phase: number)
	local track = TRACK[name]
	if not track then
		return REST_KEY, REST_KEY, 0
	end
	phase = clamp01(phase)
	local prev = REST_KEY
	for _, key in track do
		if phase <= key.at then
			local span = key.at - prev.at
			local t = if span > 1e-6 then (phase - prev.at) / span else 1
			local ease = EASE[key.ease or "linear"] or EASE.linear
			return prev, key, ease(clamp01(t))
		end
		prev = key
	end
	return prev, prev, 1
end

-- The three bone directions a track holds at `phase`, on one flank.
local function samplePose(name: string, phase: number, side: number): (Vector3, Vector3, Vector3)
	local from, to, t = segmentAt(name, phase)
	return blendDir(dirOf(from.upper, side), dirOf(to.upper, side), t),
		blendDir(dirOf(from.fore, side), dirOf(to.fore, side), t),
		blendDir(dirOf(from.hand, side), dirOf(to.hand, side), t)
end

-- ...and the body commitment the same track holds there, in RADIANS and
-- unsigned. Split from `samplePose` because `bodyCFrame` asks for it several
-- times a frame and has no use for the arm.
local function sampleCommit(name: string, phase: number): (number, number)
	local from, to, t = segmentAt(name, phase)
	return math.rad(from.pitch + (to.pitch - from.pitch) * t), math.rad(from.tilt + (to.tilt - from.tilt) * t)
end

-- ---------------------------------------------------------------- the state

function PyreliskPath.newState(center: Vector3)
	return {
		center = center,
		time = 0,
		rise = 0, -- 0 = under the lava, 1 = fully up
		faceAngle = 0, -- who it is watching; may move every frame
		aimAngle = 0, -- LATCHED - see THE CONTRACT
		aimSide = 1, -- LATCHED - which arm is working
		attack = "", -- the running attack's id; indexes TRACK
		blend = 0, -- 0 = the rest silhouette, 1 = fully into that attack's pose
		strike = 0, -- 0 = wound up, 1 = the blow has landed
		exposed = 0, -- the punish window: it is down and open
		slump = 0, -- how far the body has sagged into that window
		planted = 0, -- which side is planted during a stagger, 0 = neither
		stance = 1, -- counts DOWN as it loses ground (ATTR_STANCE)
		-- WHICH ACT OF THE FIGHT THIS IS: `PyreliskAct`, 1..3 since 2026-09-12,
		-- and NIL MEANS 1. 1 = the shell and its seams, 2 = the two downed arms,
		-- 3 = the heart room (published on the HEART's model, not this one). It
		-- is here rather than only on the client because the fallen pose and the
		-- body freeze are both functions of it, and the server reads both: a
		-- server whose copy of the state did not carry the act would pose and
		-- measure a STANDING body while its own attributes said the colossus was
		-- face down - a hundred and five studs of disagreement, silently.
		act = 1,
		-- `fallen` IS DELIBERATELY ABSENT. See `fallenPhase`: a state without
		-- it takes the pose straight off the act, which is what the server
		-- needs (one settled pose, no ease to keep in step). A client that wants
		-- the fall animated sets it and eases it itself. Writing a 0 here would
		-- make the server's own pose permanently standing while its attributes
		-- said act 2 - every hit, hazard and seam resolved against a body
		-- nobody is drawing.
		-- `collapse` IS ABSENT FOR THE SAME REASON: see `collapsePhase`, which
		-- falls back to the published `blend` of the `collapse` attack.
	}
end

-- WHICH ACT, AND HOW FAR INTO THE FALL, 0..1.
--
-- Two answers in one function, and the fallback is the load-bearing half: an
-- eased `state.fallen` if the caller keeps one, otherwise the level the act
-- implies. ACT 2 IS PROSTRATE AND SO IS THE COLLAPSE THAT FOLLOWS IT; act 1 is
-- standing. The test is still `>= 2` rather than `== 2` and that is deliberate
-- - act 3 is a different model in a different arena (the heart) and never asks
-- this file anything, so a body that somehow reads act 3 is a body that has
-- already fallen, not one that stands back up.
function PyreliskPath.fallenPhase(state): number
	local eased = state.fallen
	if eased ~= nil then
		return clamp01(eased)
	end
	return if (state.act or 1) >= 2 then 1 else 0
end

-- Is the colossus in the fallen pose at all? Everything that draws or walks
-- on the body asks this before it asks anything else.
function PyreliskPath.fallenEngaged(state): boolean
	return PyreliskPath.fallenPhase(state) > 0
end

-- ------------------------------------------------------------- F-14, PINNED
--
-- THE BODY DOES NOT MOVE ONCE IT IS DOWN, and this is the condition that says
-- so. It is a STRUCTURAL fix and not a playtest, because the thing it prevents
-- is invisible from outside the fight:
--
--   * the two arm creatures are placed ONCE, against the body's heading, and
--     a body that turns afterwards leaves them behind (the design's SS3.2) -
--     the party would be shooting at where an arm used to be;
--   * the seam sites, the vents and every hazard the fallen body owns are
--     resolved off the same pose, so a turning body moves all of them at once.
--
-- The shipped guarantee covered NONE of act 2. `breath` dropped out and
-- `commit` froze only while `planted ~= 0`, and act 2 has `planted == 0` for
-- all of it: both arms are down and nothing is planted. So the test is the OR,
-- and `act` is why it is in the state. The `planted ~= 0` half is kept as
-- act 1's own guarantee (its plant window is the last thing that sets it);
-- with the climb act retired it no longer occurs in acts 2+ at all.
--
-- WHAT THE SERVER STILL OWES, stated out loud because it is the other half
-- and it lands in slice 3: nothing here can stop `faceAngle` being rewritten
-- every frame, so the server must stop publishing it once the arms are down
-- (`Fn.openPyreliskMount` already does exactly that for the act-1 plant
-- window). What this file guarantees on its own is that no ATTACK can turn
-- the body - `bearing` stops folding the latched aim in, so a `ventbreath`
-- cast over a pair of downed arms leans nothing and swings nothing.
function PyreliskPath.frozen(state): boolean
	return (state.planted or 0) ~= 0 or (state.act or 1) >= 2
end

-- Which arm should work, for a target on `angle`: its own flank, so it
-- reaches across itself only when it has to.
function PyreliskPath.plantSide(state, angle: number): number
	local bearing = wrapAngle(angle - (state.faceAngle or 0))
	return if math.sin(bearing) < 0 then 1 else -1
end

-- COMMIT TO A TARGET. The only supported way to set the aim: called once, as
-- the windup starts, and not again until the attack has finished. Everything
-- in THE CONTRACT above is about this function being called exactly once.
function PyreliskPath.latch(state, angle: number, side: number?)
	state.aimAngle = angle
	state.aimSide = if side then (if side < 0 then -1 else 1) else PyreliskPath.plantSide(state, angle)
end

-- HOW FAR THROUGH ITS OWN ANIMATION THE BODY IS, 0..1, out of the only two
-- numbers on the wire. See THE JOINTED REBUILD: windup 0 -> 0.5, strike
-- 0.5 -> 1, and a recovery (which unwinds blend and strike together) walks it
-- monotonically back down.
function PyreliskPath.phase(state): number
	return clamp01(state.blend) * (0.5 + 0.5 * clamp01(state.strike))
end

-- ---------------------------------------------------------------- the body

-- The slow heave of a mountain breathing. Deliberately slower and smaller in
-- proportion than its siblings': at 207 studs of crown a lively bob reads as
-- the whole arena wobbling.
--
-- IT HOLDS ITS BREATH WHILE SOMEONE IS STANDING ON IT. A planted arm is
-- furniture: the server anchors real collidable slabs along it (the climb),
-- and an anchored part does not carry the player standing on it, so any body
-- motion at all during that window is the drawn rock sliding out from under
-- the invisible plate they are walking on. 1.6 studs of bob is nothing on a
-- 207-stud body and everything to someone on a 4-stud-thick ledge over lava.
-- Switched off HERE rather than server-side on purpose: both sides compute
-- the breath independently from the same clock, so the only way they can
-- agree that it stopped is for the rule to live in the shared file.
function PyreliskPath.breath(state): number
	if PyreliskPath.frozen(state) then
		return 0
	end
	return math.sin((state.time or 0) * 0.42) * 1.6
end

-- ...and the three keyed body numbers the `fallen` track holds at this
-- phase: pitch and tilt in RADIANS, and the sink in STUDS.
local function fallenCommit(state): (number, number, number)
	local from, to, t = segmentAt("fallen", PyreliskPath.fallenPhase(state))
	return math.rad(from.pitch + (to.pitch - from.pitch) * t),
		math.rad(from.tilt + (to.tilt - from.tilt) * t),
		(from.sink or 0) + ((to.sink or 0) - (from.sink or 0)) * t
end

-- ------------------------------------------- THE COLLAPSE SINK (2026-09-12)
--
-- WHAT REPLACED THE CLIMB. On the directive "maybe after the first phase it
-- just goes straight into the volcano and we move into that", act 2 ends with
-- both arms dead and then the colossus KEEPS GOING DOWN: the caldera opens
-- 2.5s into the 4.0s collapse (CreatureService's `K.PY_CALDERA_AT`) and the
-- prostrate body sinks through the hole it just opened, which is the transition
-- into act 3's heart room. The fallen pose is the pose for all of it - act 2's
-- held shape AND the collapse's - so the only thing the collapse adds is
-- DEPTH, and this is where it is added.
--
-- HOW FAR INTO THE COLLAPSE THE BODY IS, 0..1. Same shape as `fallenPhase`,
-- and for the same reason: an explicit `state.collapse` if a caller keeps one,
-- otherwise the number the server already publishes for the fall. There is no
-- collapse attribute and this file may not invent one -
-- `Fn.updateBossCollapse` drives the death through `Attack = "collapse"` with
-- `AttackBlend` running from wherever it was up to 1 on its own smoothstep -
-- so `blend` IS the progress, read ONLY while that attack is the one running.
-- A pyrelisk that dies in act 1 therefore gets none of this: `sink` returns
-- early below, exactly as it always did.
function PyreliskPath.collapsePhase(state): number
	local eased = state.collapse
	if eased ~= nil then
		return clamp01(eased)
	end
	if (state.attack or "") ~= "collapse" then
		return 0
	end
	return clamp01(state.blend)
end

-- HOW DEEP THE COLLAPSE TAKES IT, studs, on top of the fallen pose's own
-- 105.2. DERIVED, and the arithmetic is the whole reason this is a named
-- constant rather than a number inside a lerp:
--
--   the crown's top is authored z 206.9 (`CROWN`, MEASURED off the built
--   pack) and the head hangs at authored x 8.0 (`NECK`), so body-local the
--   crown top is (x 8.0, y 206.9). The fallen pose pitches the body 14.0
--   degrees (`FALLEN_PITCH`) with ZERO tilt, and `bodyCFrame` applies that as
--   Rz(-pitch), which sends y -> x * sin(-14) + y * cos(-14):
--
--     8.0 * -0.241922 + 206.9 * 0.970296 = -1.94 + 200.76 = 198.82
--
--   ...and the fallen track's keyed sink drops the body's origin 105.2. So at
--   the act-2 rest the crown stands 198.82 - 105.20 = 93.62 studs OVER the
--   lake surface - which is y = 0 in boss space by construction (see the mesh
--   notes: the base sits on z = 0 because z = 0 IS the lake).
--
--   93.62 is therefore the break-even, and full submergence of the highest
--   rock on the body needs strictly more than it. 98.0 puts the crown 4.4
--   studs UNDER the surface on the pose alone, and the server's collapse also
--   decays `rise` to 0.55 (`updateBossCollapse`: rise * (1 - 0.45)), which
--   `lift` spends as another -18.0 - so the delivered clearance at collapse
--   end is 22.4 studs. The margin is deliberately SMALL rather than generous:
--   the shaft the body is sinking into is 120 studs deep, and every stud past
--   the crown is a stud of colossus below the shaft floor.
--
-- DERIVED THEN VERIFIED ON THE NUMBERS, NOT ON A RENDER. There was no
-- boss_gen window in this pass (another lane holds that file), so this is
-- checked by arithmetic off the measured constants above and by nothing else.
-- The next boss_gen window's staged collapse frames are what confirm it, and
-- what they have to show is two things: the crown shards fully under the lake
-- plane at u = 1, and the crown still INSIDE the 120-stud shaft rather than
-- through its floor.
PyreliskPath.SINK_COLLAPSE = 98.0

-- The continuation on its own, studs, 0 until the fall starts. Named because
-- `sink` reads as the sum it is, and because a VFX lane aiming ash or steam at
-- the shaft wants the collapse's depth without the pose's.
function PyreliskPath.sinkPhase(state): number
	return PyreliskPath.SINK_COLLAPSE * PyreliskPath.collapsePhase(state)
end

-- HOW FAR THE BODY HAS DROPPED INTO ITS OWN LAKE, studs, 0 while it stands.
-- Split out so `lift` can pay nothing for it in act 1, which is every frame
-- of the fight the shipped code has ever drawn.
--
-- TWO TERMS SINCE 2026-09-12, and they are ADDED rather than blended because
-- they are two different motions: the fall onto the lake (the fallen track's
-- keyed sink, held for the whole of act 2) and then the sink through the hole
-- that opens underneath it. The second begins from wherever the first
-- settled, which is what makes the collapse read as a continuation of the
-- fall instead of a second, separate drop.
function PyreliskPath.sink(state): number
	if not PyreliskPath.fallenEngaged(state) then
		return 0
	end
	local _, _, sink = fallenCommit(state)
	return sink + PyreliskPath.sinkPhase(state)
end

-- How far up out of the lake it has come. The rise is the client's to draw
-- (the server publishes a number), so this is the only place it is a height.
-- THE SINK IS SUBTRACTED HERE, and this is the only place in the file the
-- body's origin moves for a reason that is not the rise. It has to be here:
-- `bodyCFrame` is the single transform everything else goes through, so a
-- pose that drops the whole colossus has exactly one honest place to say so,
-- and every seam, deck, joint and slab comes down with it for free.
function PyreliskPath.lift(state): number
	local rise = clamp01(state.rise)
	return -PyreliskPath.RISE_DEPTH * (1 - rise) + PyreliskPath.breath(state) * rise - PyreliskPath.sink(state)
end

-- The bearing the body is actually on: the idle watch, folded into the
-- latched angle by the running attack's blend. A committed swing finishes
-- turning into its target instead of snapping to it.
function PyreliskPath.bearing(state): number
	local face = state.faceAngle or 0
	-- PINNED. See F-14: while anything is planted or the arms are down, the
	-- heading is whatever the server last published and an attack may not fold
	-- its latched aim into it. Without this a `ventbreath` cast over the downed
	-- arms turns a hundred and fifty studs of arm - each one a creature the
	-- party is shooting at - by the difference between the body's watch and
	-- the move's target.
	if PyreliskPath.frozen(state) then
		return face
	end
	local aim = state.aimAngle or face
	return face + wrapAngle(aim - face) * clamp01(state.blend)
end

-- HOW THE MASS COMMITS: pitch (nose down into the blow) and tilt (rolling
-- onto the working arm), both in radians. Tilt comes back ALREADY SIGNED for
-- the flank it is leaning onto - the caller must not multiply it again.
--
-- Replaces the old `lean`, which was one small roll off `blend` and `strike`
-- and which `fistOffset` did not apply at all. Both of those were problems:
-- see THE BODY COMMITMENT and THE REACH BUDGET.
--
-- WHILE PLANTED IT IS A PAIR OF CONSTANTS. Not zero - see PLANT's note - but
-- constant, which is the property the anchored climb slabs actually need. The
-- window still reads as the thing collapsing: `headCFrame` dips the head off
-- `slump` and the jaw hangs open with it.
function PyreliskPath.commit(state): (number, number)
	-- THE FALLEN POSE OWNS THE COMMITMENT OUTRIGHT, and it takes precedence
	-- over both branches below. Not composed with them: `slump` is the act-1
	-- punish window sagging a body that is still standing, and adding eleven
	-- degrees of it to a colossus already face down would pitch the arm the
	-- party is climbing. The fallen pose IS the slump, and it is a level.
	if PyreliskPath.fallenEngaged(state) then
		local pitch, tilt = fallenCommit(state)
		-- Already signed, and it is zero by design - see THE FALLEN POSE on
		-- why a flank-signed tilt would move the body at the act boundary.
		return pitch, tilt
	end
	local planted = state.planted or 0
	if planted ~= 0 then
		return math.rad(PLANT_PITCH), -math.rad(PLANT_TILT) * (if planted < 0 then -1 else 1)
	end
	local side = if (state.aimSide or 1) < 0 then -1 else 1
	local pitch, tilt = sampleCommit(state.attack or "", PyreliskPath.phase(state))
	-- The punish window's own sag, on top of whatever the attack was doing.
	return pitch + math.rad(11) * clamp01(state.slump), -tilt * side
end

-- THE one CFrame the whole body is placed with.
--
-- THE YAW IS NEGATED, and it is not a taste question. Everything that writes
-- `faceAngle` / `aimAngle` writes atan2(z, x) - placeColossus's watch and
-- every handler's latch - while Roblox's R_y(t) sends local +X to
-- (cos t, 0, -sin t). Passing the bearing straight through therefore aimed
-- the body at the REFLECTION of its target about the world X axis, and it
-- was silent: the body, head, all seven seams, the vents, both decks and both
-- fists moved together, so the golem looked correct and simply faced the
-- wrong way. What it broke was the pair - a fist's impact point is computed
-- from the latched angle directly, so the drawn fist and the damaging fist
-- sat 2*bearing apart and agreed only on the +/-X axis. GnashrootPath and
-- KrakenPath negate here for exactly this reason; so does the Kraken's
-- yaw0 in CreatureService (`the two conventions meeting`).
--
-- THE COMMITMENT IS THE LAST FACTOR, applied in the body's own frame after
-- the yaw: CFrame.Angles(tilt, 0, -pitch) is Rx(tilt) * Rz(-pitch), a roll
-- about the facing axis and a pitch about the lateral one. `fistOffset`
-- applies the identical product to its own body-local fist, which is the only
-- reason the drawn fist and the damaging fist share a radius.
function PyreliskPath.bodyCFrame(state): CFrame
	local center = state.center or Vector3.zero
	local pitch, tilt = PyreliskPath.commit(state)
	return CFrame.new(center + Vector3.new(0, PyreliskPath.lift(state), 0))
		* CFrame.Angles(0, -PyreliskPath.bearing(state), 0)
		* CFrame.Angles(tilt, 0, -pitch)
end

local function toWorld(state, point: Vector3): Vector3
	return (PyreliskPath.bodyCFrame(state) * CFrame.new(point)).Position
end

PyreliskPath.toWorld = toWorld

-- ---------------------------------------------------------------- the arms

-- The bones a given side is holding, and how far its track has run. A planted
-- arm holds `plant` for the whole window rather than blending out of it,
-- because it is furniture at that point - the player is standing on it.
--
-- AND IT SNAPS INTO IT, in one frame, when the window opens. Known, and
-- left: the server places the climb's collidable slabs ONCE, from this pose,
-- at the instant `planted` is set (openPyreliskMount), so a blend into it
-- would put real footing where no rock is drawn yet for the whole length of
-- the blend - a player stepping onto thin air that holds them. The snap is
-- SMALL now, which it was not before: `plant` and `handfall`'s impact
-- keyframe land the same fist at the same bearing and radius, and `commit`
-- carries the same pitch and tilt across the boundary, so what changes in
-- that one frame is the elbow relaxing from 36 degrees of flex to 14 as the
-- arm takes the body's weight. If it is ever eased, the slabs have to be
-- placed from the SAME eased pose every frame of the ease, and that is a
-- bigger change than it looks.
local function poseFor(state, side: number): (Vector3, Vector3, Vector3)
	-- FIRST, AND FOR BOTH ARMS. The fallen track overrides the attack book
	-- and it overrides `plant`, which is the point: act 2 still casts
	-- `ashfall` and `ventbreath` off the head and the summit, and either of
	-- those drawn on the arms would swing the two arm creatures the party is
	-- shooting at through the shape of a windup. It overrides `collapse` too,
	-- and that is how the death is drawn: the same prostrate shape sinking
	-- (see THE COLLAPSE SINK). `PLANT` is skipped for the same reason from the
	-- other direction - act 1's plant window is the only thing that sets
	-- `planted`, and a fallen body is past it.
	if PyreliskPath.fallenEngaged(state) then
		return samplePose("fallen", PyreliskPath.fallenPhase(state), side)
	end
	if state.planted == side then
		return dirOf(PLANT.upper, side), dirOf(PLANT.fore, side), dirOf(PLANT.hand, side)
	end
	local attack = state.attack or ""
	if BOTH_ARMS[attack] or (side == state.aimSide and TRACK[attack]) then
		return samplePose(attack, PyreliskPath.phase(state), side)
	end
	return dirOf(REST.upper, side), dirOf(REST.fore, side), dirOf(REST.hand, side)
end

-- WHERE THIS ARM CAN ACTUALLY PUT A FIST, in body-local terms.
--
-- The shoulders are 84 studs off the body's own axis and the arm is 150 long,
-- so a fist NEVER lands in front of the colossus - it lands out on its own
-- flank, 70 degrees round. That is not a pose bug to tune away: with 126
-- studs of shoulder height to spend, an arm that reached straight ahead would
-- have to come down inside its own lava.
--
-- The consequence is the thing this function exists to prevent. If an attack
-- latches the body at the target's bearing and then damages at that same
-- bearing, the SHOCKWAVE lands where the player is and the VISIBLE FIST lands
-- 70 degrees away round the ring - roughly 230 studs of arc apart. A caller
-- aims by turning the body that much FURTHER, so the arm swings onto the
-- target instead of past it.
--
-- Returned in the same convention the world uses (atan2(z, x)) and derived
-- from the keyframe book rather than written down, so a re-tuned track moves
-- the aim with it instead of silently desynchronising the two.
--
-- `strike` is where in the swing to measure - the same fraction the handler
-- damages on. It becomes a PHASE the same way the draw does (0.5 + 0.5 *
-- strike, i.e. blend is assumed 1, which it is by the time anything strikes),
-- so `fistOffset("handfall", side, K.HANDFALL_IMPACT)` and the drawn fist at
-- the moment the shockwave fires are the same point by construction.
--
-- IT APPLIES THE BODY COMMITMENT. It has to: the fist's radius is 23 studs
-- larger at `handfall`'s impact than an unpitched, untilted arm could reach,
-- and that difference is the whole reach budget. The old version ignored the
-- lean entirely and the two sides were quietly a few studs apart.
function PyreliskPath.fistOffset(poseName: string, side: number, strike: number?): (number, number, number)
	side = if side < 0 then -1 else 1
	-- `fallen` is a HELD pose, not a swing, so there is no strike fraction to
	-- read it at: it is asked for at its settled keyframe or not at all.
	local phase = if poseName == "fallen" then 1 else 0.5 + 0.5 * clamp01(strike)
	local upper, fore, hand
	local pitch, tilt
	if poseName == "plant" then
		upper, fore, hand = dirOf(PLANT.upper, side), dirOf(PLANT.fore, side), dirOf(PLANT.hand, side)
		pitch, tilt = math.rad(PLANT_PITCH), math.rad(PLANT_TILT)
	else
		upper, fore, hand = samplePose(poseName, phase, side)
		pitch, tilt = sampleCommit(poseName, phase)
	end
	local s = PyreliskPath.SHOULDER_AUTHORED
	local shoulder = flank(side, s[1], s[2], s[3])
	local fist = shoulder + upper * PyreliskPath.UPPER_ARM + fore * PyreliskPath.FOREARM + hand * PyreliskPath.HAND
	fist = CFrame.Angles(-tilt * side, 0, -pitch) * fist
	-- THE FALLEN POSE'S SINK IS THE ONE THING THIS FUNCTION HAS TO APPLY THAT
	-- IT DOES NOT APPLY FOR AN ATTACK. Every other pose leaves `lift` to the
	-- caller (it is the rise, and the caller is placing the body anyway), but
	-- the sink is a hundred and five studs and it is a property of the POSE,
	-- not of how far out of the lake the boss has come. A caller that asked
	-- where a fallen fist is and got an answer a hundred studs up would place
	-- a hazard in mid-air - and nothing about the number would look wrong.
	-- (`fallen` is not an attack and nothing drives it through here today;
	-- this is the guard for the day something does.)
	local drop = if poseName == "fallen" then FALLEN_SINK else 0
	return math.atan2(fist.Z, fist.X), math.sqrt(fist.X * fist.X + fist.Z * fist.Z), fist.Y - drop
end

function PyreliskPath.armJoints(state, side: number)
	side = if side < 0 then -1 else 1
	local upper, fore, hand = poseFor(state, side)

	local body = PyreliskPath.bodyCFrame(state)
	local s = PyreliskPath.SHOULDER_AUTHORED
	local shoulder = (body * CFrame.new(flank(side, s[1], s[2], s[3]))).Position
	-- Directions are body-local, so they turn with the body too.
	local rot = body - body.Position
	local elbow = shoulder + (rot * upper) * PyreliskPath.UPPER_ARM
	local wrist = elbow + (rot * fore) * PyreliskPath.FOREARM
	local fist = wrist + (rot * hand) * PyreliskPath.HAND
	return {
		shoulder = shoulder,
		elbow = elbow,
		wrist = wrist,
		fist = fist,
		upper = rot * upper,
		fore = rot * fore,
		hand = rot * hand,
	}
end

-- Where the fist is: a slam's impact centre, and the point a sweep's band is
-- drawn from. The server never computes this itself.
function PyreliskPath.fistPoint(state, side: number): Vector3
	return PyreliskPath.armJoints(state, side).fist
end

-- A PLATE LYING ON A BONE, in the pack's own convention: length on +X, the
-- lift along the LIMB's up rather than the world's. Both halves of that are
-- corrections, and both were wrong in ways that only show up once someone
-- has to stand on the result:
--
--   * CFrame.lookAt puts forward on -Z, but every piece in this pack is
--     authored with its length on +X (see the controller's `alongBone`,
--     which yaws by pi/2 for exactly this reason). Without the same yaw here,
--     a slab built to WALK_ARM_SIZE - 48 long on X - lies CROSSWISE across
--     the arm.
--   * the lift is the limb's OWN up (it is how far the walk plate sits above
--     the bone's axis), not the world's - WALK_ARM_LIFT is 21.5, the
--     forearm's own measured figure, and the other two bones have their own
--     (see BONE_LIFT). Applied in world Y it is only correct for a horizontal
--     bone, and the plant pose's forearm is 53 degrees off horizontal - so
--     the plate slid sideways off the rock it is supposed to be the top of.
--
-- The frame's own up, which is what `lift` travels along. Exposed as its own
-- function because the climb has to place things ON a plate's top face - the
-- bridge starts where the upper arm's plate ends - and guessing world Y for
-- that is the very mistake the second bullet above describes.
local function boneUp(from: Vector3, to: Vector3): Vector3?
	local along = to - from
	if along.Magnitude < 1e-3 then
		return nil
	end
	local dir = along.Unit
	local up = if math.abs(dir.Y) > 0.999 then Vector3.xAxis else Vector3.yAxis
	-- The same frame CFrame.lookAt builds below; the yaw that follows it is
	-- about this axis, so it leaves the up alone.
	local back = -dir
	local right = up:Cross(back).Unit
	return back:Cross(right)
end

-- STILL EXPORTED, though its original reason is gone (2026-09-12). It was
-- exported for the arm rocks - a module seated against a climb plate needs
-- that plate's own up, and rebuilding the perpendicular on the client would
-- have been a fork of the one construction the route is laid out with. The
-- rocks are retired (see THE ROCKS AND THE CORE: RETIRED), so the export now
-- serves any client that needs a bone's own up without re-deriving it, and it
-- stays public because that is the only honest source of it.
PyreliskPath.boneUp = boneUp

local function plateOn(from: Vector3, to: Vector3, lift: number): CFrame?
	local along = to - from
	if along.Magnitude < 1e-3 then
		return nil
	end
	local dir = along.Unit
	-- lookAt cannot use world up as its reference when the bone IS world up,
	-- and this arm passes through vertical on the way down.
	local up = if math.abs(dir.Y) > 0.999 then Vector3.xAxis else Vector3.yAxis
	local frame = CFrame.lookAt(from:Lerp(to, 0.5), from:Lerp(to, 0.5) + dir, up) * CFrame.Angles(0, math.pi * 0.5, 0)
	return frame * CFrame.new(0, lift, 0)
end

-- The ramp, while an arm is planted: the forearm's midpoint and the CFrame a
-- collidable slab takes to lie along it. nil when nothing is planted, which
-- is the server's cue that there is no footing to offer. This is the ONE
-- climb slab the client also draws (the WalkArm mesh), so it stays a
-- single-CFrame call; the rest of the route is `climbSlabs` below.
--
-- AND IT IS ACT 1's ALONE NOW (2026-09-12, the climb-act removal directive).
-- Its act-3 use - the plank up the prostrate arm to the neck collar - retires
-- with the rest of the fallen route, so a FALLEN body answers nil here exactly
-- as an unplanted one does: in acts 2 and 3 there is no plank to draw and no
-- slab to anchor, because there is no route.
function PyreliskPath.rampCFrame(state): CFrame?
	local side = state.planted or 0
	if side == 0 or PyreliskPath.fallenEngaged(state) then
		return nil
	end
	local joints = PyreliskPath.armJoints(state, side)
	return plateOn(joints.elbow, joints.wrist, PyreliskPath.WALK_ARM_LIFT)
end

-- THE BACK, which act 1's route ends on: the ramp off the working shoulder pad
-- up onto the spine plateau, and the three decks themselves.
--
-- Pulled out of `climbSlabs` when the fallen route arrived, because it was the
-- ONE stretch the two routes shared. The fallen route is retired (2026-09-12,
-- the climb-act removal directive) and there is now exactly one caller, but it
-- stays a function rather than being folded back in: it is also what the
-- BUILDER's own deck measurements are compared against, and one statement of
-- the back is what keeps the vents reachable from the mounted window.
--
-- A NOTE ON THE VENTS, since the doc's SS4.4 said otherwise: the three back
-- vents are reached from the act-1 mount window and from nowhere else now.
-- There is no act-2 climb to cross the back on.
--
-- THE RAMP, and it is NEW as of the deck re-seating. The spine plateau's
-- walking face is authored z 147.8 and the shoulder pads' is 142.0 - a
-- 5.8-stud wall at the boundary before the body is tipped at all, and the
-- body's pitch lifts the plateau (authored x -34) relative to the pads
-- (x -4) by another fourteen. Without this the climb ends on the pad: the
-- player reaches the working shoulder, breaks the one vent standing on it,
-- and the other two vents and the whole spine are behind an unjumpable step
-- that nothing in the fight says is there.
--
-- The two decks share a corner - the pad spans authored x -26..18, y 41..75
-- and the plateau x -46..-22, y -40..40 - so the ramp is short (18 studs) and
-- steep: 34 degrees at the plant pose's 16 of pitch (the 28.04 degrees
-- measured at the fallen pose's 14 is now history - nothing walks the body
-- while it is down). It is the steepest thing on the route and it is not one
-- of the two the brief's 20 degrees is about; it is the same eighteen studs of
-- rock it always was.
function PyreliskPath.spineAndDecks(out, body: CFrame, side: number, thick: number)
	local padTop = (body * CFrame.new(flank(side, -24.0, 44.0, 141.8))).Position
	local spineTop = (body * CFrame.new(flank(side, -34.0, 30.0, 148.2))).Position
	local spine = plateOn(padTop, spineTop, -thick * 0.5)
	if spine then
		table.insert(out, {
			cframe = spine,
			size = Vector3.new((spineTop - padTop).Magnitude + 8.0, thick, 24.0),
			name = "Spine",
		})
	end
	for index, deck in PyreliskPath.DECK do
		table.insert(out, {
			cframe = body * CFrame.new(deck.at),
			size = deck.size,
			name = "Deck" .. index,
		})
	end
end

-- THE WHOLE CLIMB, as { cframe, size } slabs the server can spawn in a loop:
-- path -> hand -> forearm -> upper arm -> shoulder -> pad -> spine -> decks.
-- Returned as one list because the route is only a route if every step of it
-- exists - a missing segment is not a shorter climb, it is a wall halfway up,
-- and the fight's entire punish window is on the far side of it.
--
-- The four bone plates are invisible collision laid on rock the client is
-- already drawing (Hand, Forearm, UpperArm, WalkDeck), which is the same
-- bargain the maw floor strikes in CreatureService: what you see is a mesh,
-- what you stand on is a part. Nothing here is drawn twice.
function PyreliskPath.climbSlabs(state): { { cframe: CFrame, size: Vector3, name: string } }
	local out = {}
	local body = PyreliskPath.bodyCFrame(state)
	local side = state.planted or 0
	-- NO PLANT, NO ROUTE, AND NO DECKS EITHER. The decks used to be appended
	-- outside this test, so an unplanted call handed back three collidable
	-- slabs a hundred and fifty studs over the lake with nothing leading to
	-- them - and it made openPyreliskMount's `#slabs == 0` guard dead code,
	-- which is the guard that exists to say "there is no footing to offer
	-- here". The back is only footing while the arm that reaches it is down.
	if side == 0 then
		return out
	end
	-- ...AND THE FALLEN POSE OFFERS NO FOOTING EITHER (2026-09-12, the
	-- climb-act removal directive). Acts 2 and 3 have no climb: the arms are
	-- shot off from the rim path and the body sinks through the caldera it
	-- opens. An empty route is exactly how that is said out loud - it is
	-- `openPyreliskMount`'s own "there is nothing to stand on here"
	-- (`#slabs == 0`) - and the ONE route left below is act 1's plant window,
	-- untouched. `planted` is never set in acts 2+ any more, so this is
	-- belt-and-braces: it is what stops the act-1 route being cut from a
	-- prostrate body if anything ever sets it again.
	if PyreliskPath.fallenEngaged(state) then
		return out
	end
	local joints = PyreliskPath.armJoints(state, side)
	local width, thick = PyreliskPath.WALK_ARM_SIZE.Z, PyreliskPath.WALK_ARM_SIZE.Y
	-- Each plate overruns its bone by a plate-width so the joints have no
	-- gap to fall through: two slabs that merely meet at a point leave a hole
	-- exactly where the player's weight lands as they step from one to the
	-- next.
	local function bone(name: string, from: Vector3, to: Vector3, lift: number)
		local cf = plateOn(from, to, lift)
		if cf then
			local span = (to - from).Magnitude + width * 0.5
			table.insert(out, { cframe = cf, size = Vector3.new(span, thick, width), name = name })
		end
	end
	-- THE ROUTE, RISE BY RISE, off the measured `plant` pose (joints at
	-- shoulder y 112.2, elbow 59.1, wrist 8.3, fist -6.0, all inside the
	-- frozen 16-degree pitch and 6-degree tilt) and the per-bone lifts in
	-- BONE_LIFT. Every figure below is the WALKING SURFACE - the plate's top
	-- face - not the bone, because the bone is not what anyone stands on:
	--
	--   rim path (y 0)   -> Hand plate's outer tip   y   2.9   step  2.9
	--   Hand tip         -> at the fist              y   5.2   ramp 31 deg
	--   Hand at the wrist                            y  19.5   ramp 31 deg
	--   Forearm at the wrist                         y  21.3   step  1.8
	--   Forearm at the elbow                         y  72.2   ramp 53 deg
	--   UpperArm at the elbow                        y  72.3   step  0.1
	--   UpperArm at the shoulder                     y 125.3   ramp 66 deg
	--   Shoulder bridge (starts ON that top face)    y 125.3   step  0.0
	--   the working shoulder pad                     y 134.5   ramp  7 deg
	--   Spine ramp up to the plateau                 y 147.5   ramp 34 deg
	--
	-- THOSE FIGURES ARE RECOMPUTED, NOT RE-MEASURED (2026-09-11). The arm rows
	-- are the old measured ones carried down by the two lift changes through
	-- each bone's own up (the forearm's face drops 2.0 x cos 53 = 1.2, the
	-- upper arm's 3.0 x cos 66 = 1.2), and the last two rows by the decks'
	-- re-seating. Every step either shrank or held; nothing on the route got
	-- taller, which is the property that matters. Re-measure them the next
	-- time the pose is instrumented in-engine and replace this note.
	--
	-- No step over 2.9 studs anywhere on it, against a default jump of
	-- 6.4-7.2, and every rise is climbable in BOTH directions - which matters
	-- because the way off this body is the way back down it. The two long
	-- ramps are steep (53 and 66 degrees) and that is forced geometry, not a
	-- choice: a shoulder 112 studs up whose fist has to reach r 188 has 86
	-- studs of horizontal run to spend on 118 studs of drop, so the mean
	-- slope of the whole arm is 53 degrees before anything is posed.
	--
	-- ALL OF THE ABOVE IS THE `plant` ROUTE - act 1's twenty-second punish
	-- window, unchanged, and since 2026-09-12 it is the ONLY route: the fallen
	-- route that used to follow this block is retired with the climb act.
	--
	-- A PLATE LAID FACE TO FACE rather than along a bone: its TOP passes
	-- through both points (lift -thick/2), so two of them sharing an end
	-- share a walking height and the step between them is zero by
	-- construction. That is how the shoulder bridge below has always been
	-- built, and it is the construction the retired fallen route used
	-- throughout - kept described here because `ramp` is still built on it.
	--
	-- `heel` PUSHES THE WHOLE OVERRUN TO THE FAR END, and it is a FIX rather
	-- than a feature - it closes a lip this route has always had. A plate
	-- centred on the span it bridges overruns a plate-width at BOTH ends, so
	-- where two plates meet at different slopes the later one's backward
	-- overrun stands proud of the earlier one's walking face. At the shoulder
	-- that is the worst of them: the bridge leaves the arm at 14.8 degrees
	-- while the upper arm's plate arrives at 16.9, and the bridge's backward
	-- 4.5 studs therefore stand 4.85 above the rock the player is walking up
	-- (6.57 here, where the two slopes are 7.7 and 66.2). It is
	-- a wall you hit facing UP the climb, which is the direction that matters.
	-- The joint still cannot open, because the upper arm's plate overruns
	-- forward across it from the other side.
	local function ramp(name: string, from: Vector3, to: Vector3, wide: number, heel: number?)
		local cf = plateOn(from, to, -thick * 0.5)
		if cf then
			local over = heel or width * 0.5
			if heel then
				cf += (to - from).Unit * (heel * 0.5)
			end
			table.insert(out, {
				cframe = cf,
				size = Vector3.new((to - from).Magnitude + over, thick, wide),
				name = name,
			})
		end
	end

	bone("Hand", joints.wrist, joints.fist, PyreliskPath.BONE_LIFT.Hand)
	bone("Forearm", joints.elbow, joints.wrist, PyreliskPath.BONE_LIFT.Forearm)
	bone("UpperArm", joints.shoulder, joints.elbow, PyreliskPath.BONE_LIFT.UpperArm)
	-- THE STEP NO BONE COVERS: the shoulder joint sits inboard of and below
	-- the shoulder pad it has to arrive on, so it is laid as a ramp rather
	-- than left as a gap.
	--
	-- IT LANDS ON THE WORKING SIDE'S PAD, not on the spine plateau, and the
	-- landing is a point ON that pad's own top face: DECK[2]/[3] are centred
	-- at authored (-4, +/-58, 140.0/138.7) and are 4 thick, so the face is
	-- z 142.0 and the pad spans authored x -26..18, y 41..75. Authored
	-- (-12, 44, 142.0) is inside both spans with room either side.
	--
	-- AND THE LANDING HEIGHT IS COMPUTED, NOT ASSUMED. The pad's walking face
	-- is a TILTED PLANE once the body is pitched 16 degrees and rolled 6, so
	-- "the deck's centre plus half its thickness" is only right at the
	-- centre; taking the authored top-face point through `body` gives the
	-- height at the point the bridge actually meets.
	--
	-- IT STARTS ON THE UPPER ARM'S PLATE, NOT AT THE SHOULDER JOINT, and it
	-- carries its own top face rather than its centre. Built from the joint
	-- with lift 0 it began below the plate it is supposed to continue and
	-- then ran up INSIDE the shoulder rubble. So: start at the top of the
	-- upper arm's plate, finish at the pad's own walking height, lift by
	-- -thick/2 so the slab's TOP passes through both, and overrun by 8. What
	-- is still true and is the art's to fix: the drawn shoulder rubble tops
	-- out above the pad, so this ramp passes through drawn rock - which
	-- nobody stands on, because nothing on this body is collidable except
	-- these slabs.
	local up = boneUp(joints.shoulder, joints.elbow) or Vector3.yAxis
	local start = joints.shoulder + up * (PyreliskPath.BONE_LIFT.UpperArm + thick * 0.5)
	local landing = (body * CFrame.new(flank(side, -12.0, 44.0, 142.0))).Position
	--
	-- AND IT IS HEELED NOW (see `ramp`): its eight studs of overrun all sit
	-- past the LANDING rather than half of them lying back over the upper
	-- arm's plate. At 7.7 degrees against the upper arm's 66.2 those four
	-- studs stood 6.57 proud of the surface the player is climbing - a wall
	-- across the route, facing up it, on the shipped fight.
	ramp("Shoulder", start, landing, 54.0, 8.0)
	-- ...AND THE STEP AFTER THAT, which is NEW and which the route has needed
	-- since the decks were re-seated. The spine plateau's walking face is
	-- authored z 147.8 and the shoulder pads' is 142.0 - a 5.8-stud wall at
	-- the boundary before the body is tipped at all, and the 16-degree pitch
	-- lifts the plateau (authored x -34) relative to the pads (x -4) by
	-- another fourteen. Without this the climb ends on the pad: the player
	-- reaches the working shoulder, breaks the one vent standing on it, and
	-- the other two vents and the whole spine are behind an unjumpable step
	-- that nothing in the fight says is there.
	--
	-- The two decks share a corner - the pad spans authored x -26..18,
	-- y 41..75 and the plateau x -46..-22, y -40..40 - so the ramp is short
	-- (18 studs) and steep (34 degrees), laid from a point on the pad's face
	-- to a point on the plateau's, both taken through `body` for the same
	-- tilted-plane reason as the bridge above.
	PyreliskPath.spineAndDecks(out, body, side, thick)
	return out
end

-- The decks across its back, as world CFrames - the footing the mounted phase
-- happens on. Same list the builder cut the slabs for.
function PyreliskPath.deckCFrames(state): { CFrame }
	local body = PyreliskPath.bodyCFrame(state)
	local out = {}
	for _, deck in PyreliskPath.DECK do
		table.insert(out, body * CFrame.new(deck.at))
	end
	return out
end

-- ------------------------------------------- THE ROCKS AND THE CORE: RETIRED
--
-- REMOVED 2026-09-12, on the directive "okay now the fallen rocks on its arm
-- stuff maybe we can remove that entire idea. maybe after the first phase it
-- just goes straight into the volcano and we move into that." The climb act is
-- gone. The fight is act 1 (the shell seams), act 2 (stun, then kill both
-- arms), the colossus sinking straight through the opening caldera, and act 3
-- (the heart room) - so nothing is ever planted on an arm again.
--
-- `PyreliskPath.armRocks` and `PyreliskPath.neckCorePoint` are DELETED rather
-- than stubbed, and that is the deliberate half: their only callers are
-- CreatureService's `Fn.pyreliskRockPoints` / `Fn.pyreliskCorePoint`, both of
-- which test for the function and warn loudly when it is absent (their own
-- "NO FALLBACK, DELIBERATELY" note), and that lane is removing them in
-- parallel. A stub handing back an empty list would have been the worse half
-- of the same transition - it plants nothing AND says nothing.
--
-- Gone with them: `ROCK_TS` / `ROCK_OFFSET` / `ROCK_LIFT`, `FALLEN_CORE_AT`,
-- and the `PyreliskRocks` / `PyreliskCore` attributes, which are never
-- published again. The pack stays at SEVENTEEN objects (design 8.3): its
-- `ArmRock`, `NeckCore` and `WalkNeck` objects survive as DORMANT exports -
-- exported, never drawn, never given a collision slab.

-- ---------------------------------------------------------------- the head

-- The jaw's swing. Open on the vent-breath, and open on the punish window
-- too: a colossus with its face in the dirt should look like it.
function PyreliskPath.jawAngle(state): number
	local breath = if state.attack == "ventbreath" then clamp01(state.blend) else 0
	local gasp = clamp01(state.slump) * 0.55
	return -PyreliskPath.JAW_MAX * math.max(breath, gasp)
end

-- The head's own CFrame, body-relative: it dips as the body slumps into a
-- window and rears for the breath.
--
-- BOTH SIGNS ARE THE WAY THEY ARE ON PURPOSE, and they were both backwards
-- until now. A rotation about the body's local Z carries +X (its facing)
-- toward +Y, so POSITIVE is nose UP and negative is nose down - which is why
-- the commitment's pitch is applied as -pitch and `jawAngle` returns a
-- negative to open. A rear is up (+) and a dip is down (-). Written the other
-- way round, the colossus lifted its head as it slumped into the punish
-- window and buried its face in its own chest to breathe fire - both exactly
-- inverted, and both invisible in a still frame.
function PyreliskPath.headCFrame(state): CFrame
	local rear = if state.attack == "ventbreath" then clamp01(state.blend) * math.rad(16) else 0
	local dip = clamp01(state.slump) * math.rad(-24)
	return PyreliskPath.bodyCFrame(state) * CFrame.new(PyreliskPath.NECK) * CFrame.Angles(0, 0, rear + dip)
end

-- ---------------------------------------------------------------- the shell

-- A seam's world position and outward normal. `index` 1 is the chest.
function PyreliskPath.seamPoint(state, index: number): (Vector3, Vector3)
	local seam = PyreliskPath.SEAMS[index] or PyreliskPath.SEAMS[1]
	local body = PyreliskPath.bodyCFrame(state)
	return (body * CFrame.new(seam.at)).Position, ((body - body.Position) * seam.out).Unit
end

-- The same for a vent shaft: the breakables reached from the deck.
function PyreliskPath.ventPoint(state, index: number): (Vector3, Vector3)
	local vent = PyreliskPath.VENTS[index] or PyreliskPath.VENTS[1]
	local body = PyreliskPath.bodyCFrame(state)
	return (body * CFrame.new(vent.at)).Position, ((body - body.Position) * vent.out).Unit
end

-- The chest core: the phase-3 target, and what the collapse falls away from.
function PyreliskPath.corePoint(state): Vector3
	return toWorld(state, PyreliskPath.CORE)
end

return PyreliskPath
