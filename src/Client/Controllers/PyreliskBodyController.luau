--!nonstrict
-- PyreliskBodyController.luau
-- Draws Pyrelisk, the Ashfall Colossus, on the client: the server publishes a
-- handful of numbers, this file turns them into ~30 parts, every frame.
--
-- Its siblings are BrinejawBodyController and GnashrootBodyController and it
-- works the same way, because a POSED boss (`pose = "pyrelisk"` on the Bosses
-- row) is hidden server-side - CreatureService's hideColossusModel sets every
-- BasePart to Transparency 1 - and the visible creature is entirely ours.
--
-- What is NOT ours: the footing. A player has to STAND on this thing during
-- the mount phase, and nothing drawn here can carry them - these parts are
-- CanCollide = false by necessity, and a client-only part is not something
-- the server would ever agree someone was standing on.
--
-- So the climb route is server geometry: anchored slabs the fight spawns and
-- places from PyreliskPath.rampCFrame / .deckCFrames, the same joints this
-- file draws from, which is the only reason the rock you see and the rock you
-- stand on agree.
--
-- Note it is NOT the hidden server model's own parts, which was my first
-- reading of hideColossusModel (it sets Transparency and never CanCollide, so
-- the model does stay solid). It cannot be: the row still spawns the small
-- CreaturePack proxy, so those parts are a ~23-stud lump at this body's feet,
-- nothing like the 270-stud golem drawn over them. The proxy stays what it
-- has always been - a pivot and a hit target - and the footing is its own.
--
-- Pieces come from ReplicatedStorage/Assets/PyreliskPack (assets/boss_gen.py,
-- build_pyrelisk). Until that import lands this draws correctly-posed
-- stand-ins rather than nothing, so the fight is always debuggable.
--
-- Two of the SEVENTEEN pieces are MODULES, instanced many times from one
-- mesh:
--   Seam     the shootable weak point - seven on the shell, one in the maw,
--            one in each vent throat
--   Vent     the three breakables reachable from the back deck
-- Their positions come from PyreliskPath.SEAMS / .VENTS, the same tables the
-- server tests hits against, so what you shoot is what you see.
--
-- `ArmRock` WAS THE THIRD MODULE AND `NeckCore` THE SEVENTEENTH OBJECT, and
-- both are DORMANT as of 2026-09-12 - see THE CLIMB ACT IS GONE below. They
-- are still exported (the pack is closed at seventeen), still carry their LOOK
-- and AUTHORED_BOX rows so the stand-in arithmetic stays total, and are never
-- instanced, drawn or given a collision slab by this file again.
--
-- ------------------------------------------------------- ACT 2, AND THE FALL
--
-- `PyreliskAct` (a LEVEL, 1..3, nil means 1) is the one new attribute this
-- file reads, and everything it changes is in the POSE rather than here:
-- PyreliskPath takes the act and returns the fallen body, the fallen arms and
-- the frozen bearing. This file copies the level in, eases its own
-- `state.fallen` toward it (FALL_RATE) and draws whatever comes back.
--
-- THE CHEST SEAM NEEDS NO BRANCH HERE, and that is worth stating because the
-- design asserts it and an assertion is not a check. Verified by reading the
-- seam loop below: it walks every index of PyreliskPath.SEAMS and resolves
-- each one through BROKEN > OPEN > CLOSED off the two masks, with no index
-- special-cased anywhere. Seam 1's only difference is `SEAM_FLANK[1] == 0`,
-- which costs it the meter push and nothing else. So act 3 setting bit 0 in
-- `SeamsOpen` lights the chest through the ordinary OPEN branch, and setting
-- it in `SeamsBroken` when the neck core dies scars it through the ordinary
-- BROKEN one. The three-state vocabulary already covers it.
--
-- --------------------------------------------------- THE CLIMB ACT IS GONE
--
-- REMOVED 2026-09-12, on the directive: "okay now the fallen rocks on its arm
-- stuff maybe we can remove that entire idea. maybe after the first phase it
-- just goes straight into the volcano and we move into that."
--
-- What this file used to draw and no longer does: six orange `ArmRock`s up the
-- planted arm, the `NeckCore` at the collar, and the two attributes behind
-- them (`PyreliskRocks`, `PyreliskCore`) - all of it the climb act. There is
-- no climb, no seventh target, and nothing is ever planted on an arm again.
--
-- WHAT REPLACED IT, and it is the whole of this file's share of the new shape:
-- when the second arm dies the prostrate body KEEPS SINKING, down through the
-- caldera that opens under it, and act 3 happens in the heart room on a
-- different model. The sink is the POSE's rather than this file's - see
-- `PyreliskPath.SINK_COLLAPSE` and `collapsePhase` - and this file's share of
-- it is to feed the state the two numbers that drive it (`attack` and `blend`,
-- which `readTarget` already copies) and to stop drawing the exterior rig at
-- act 3.
--
-- The lava pool a broken rock left behind was SERVER side and goes with the
-- rest of it (the parallel CreatureService removal).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PyreliskPath = require(Shared.Modules.PyreliskPath)

local PyreliskBodyController = {}

local CREATURES_FOLDER = "Creatures"
local PACK_NAME = "PyreliskPack"
local POSE_NAME = "pyrelisk"
local PREFIX = "Pyrelisk_"

-- The row's palette (Creatures.items.pyrelisk), asserted here rather than
-- trusted to survive the glTF round trip.
local OBSIDIAN = Color3.fromRGB(38, 32, 40)
local BASALT = Color3.fromRGB(80, 44, 34)
local MOLTEN = Color3.fromRGB(255, 96, 16)
local EMBER = Color3.fromRGB(255, 158, 60)
-- The climb route (boss_gen's PY_SLAG): a shade off the shell, because the
-- footing has to read as part of the rock and still be findable from the rim.
local SLAG = OBSIDIAN:Lerp(BASALT, 0.30)

-- The maw seam, straight off the builder's own placement of it:
-- `head @ _py_module((14, 0, 12), (1, 0, -0.3))`, through the y-up mirror
-- (authored (x, y, z) arrives here as (x, z, -y)). Head-local, not body.
--
-- RE-KEYED 2026-09-09, and it had drifted: this said (18, 0, -10), which was
-- a builder two remodels ago. The head is now 56 studs tall against the old
-- one's 88, so the stale point put the throat glow ten studs BELOW the jaw
-- line - outside the skull, hanging under the chin - and nothing anywhere
-- compares the two, which is why it survived.
local MAW_AT = Vector3.new(14, 12, 0)
local MAW_OUT = Vector3.new(1, -0.3, 0)

-- How fast the drawn body chases the replicated numbers. Attributes arrive at
-- roughly 20 Hz; these rates are what turn that into motion instead of steps.
-- Deliberately slower than the serpents': 250 studs of colossus that snaps
-- between poses reads as a cut, not a swing.
local BLEND_RATE = 9
local FACE_RATE = 3.2
local RISE_RATE = 1.6
-- HOW FAST THE COLOSSUS GOES DOWN when the arms come off it, as a fraction of
-- the fallen track per second. Slow on purpose: a hundred and five studs of
-- sink is the biggest single motion in the fight and it is the act break, so
-- it wants to read as a mountain giving way rather than as a teleport.
--
-- IT IS THE CLIENT'S EASE ALONE, and the server does not have one - see
-- `PyreliskPath.fallenPhase`. The server takes the settled pose the instant
-- the act says so. The two are allowed to disagree for this second and a half
-- precisely because NOTHING EVER STANDS ON THIS BODY once it is down: since
-- 2026-09-12 `climbSlabs` hands back an empty route for the whole of the
-- fallen pose, so an eased client body and a settled server body cannot put a
-- player anywhere.
local FALL_RATE = 0.7

local warnedMissingPack = false

-- ------------------------------------------------------------- THE SEAMS
--
-- The seams are the fight's other route into a stagger, and this is the
-- CLIENT half of it. The design: during an attack's windup and strike the
-- seams on the committing flank OPEN - brighter, hotter, visibly shootable.
-- Shooting an open seam damages the boss and fills that flank's stagger
-- meter; a full meter DROPS THAT ARM. (It used to drop it as a climbable
-- ramp; since 2026-09-12 a dropped arm is a creature to kill and nothing
-- more - see THE CLIMB ACT IS GONE.) A flank whose meter fills has its seams
-- BREAK - permanent scars, DEAD rather than lit, so "by the last act it is
-- visibly coming apart".
--
-- ============================ THE ATTRIBUTE CONTRACT =====================
-- REWRITTEN 2026-09-12 for the new act set, on the directive quoted at THE
-- CLIMB ACT IS GONE. The whole contract is stated here rather than half here
-- and half in a design doc, because two of its rows were REMOVED on that date
-- and a contract that still lists them is worse than no contract at all.
--
-- THE FIGHT: act 1 the shell and its seams, act 2 stun then kill both arms,
-- then the colossus sinks straight through the opening caldera, then act 3 in
-- the heart room (a different model entirely). `PyreliskAct` is MONOTONIC
-- across that handoff and 3 is published on the HEART.
--
-- WHAT THIS FILE READS, in full, and all three of PyreliskPath, this file and
-- BossHudController spell every name byte for byte:
--
--   PyreliskAct  (number, LEVEL 1..3, nil means 1) - which act. The exterior
--                rig drawn here belongs to acts 1 and 2; at 3 the folder is
--                unparented (the body is gone and the heart is elsewhere).
--   Attack + AttackBlend - the pose book, as ever, AND the collapse: the
--                death publishes `Attack = "collapse"` with the blend running
--                up, and `PyreliskPath.collapsePhase` reads exactly those two
--                to sink the body through the caldera. No third number.
--   Planted      (number, -1/0/+1) - act 1's plant window and nothing else
--                now. It is never set once the body is down.
--   ...plus the four seam attributes below, unchanged.
--
-- REMOVED ON 2026-09-12, AND NEVER PUBLISHED AGAIN: `PyreliskRocks` (the
-- six-bit survivor mask of arm rocks) and `PyreliskCore` (the neck core's
-- health). They were the climb act's targets. Nothing reads them here, nothing
-- reads them in the HUD, and the parallel CreatureService pass is what stops
-- writing them. `PyreliskArmL` / `PyreliskArmR`, `SeamsOpen` / `SeamsBroken` /
-- `SeamMeterL` / `SeamMeterR`, `Planted`, and the arena's `PyreliskCaldera` /
-- `PyreliskShaftFloor` / `PyreliskPillars` are all UNCHANGED by that pass.
--
-- THE SEAM HALF landed on 2026-09-06 (CreatureService's ATTR.SEAMS_OPEN and
-- the three beside it). It publishes exactly these four attributes on the boss
-- model, and this file reads exactly these:
--
--   SeamsOpen   (number, integer BITMASK) - bit (i-1) set means
--               PyreliskPath.SEAMS[i] is currently OPEN. The server sets it
--               on windup, keeps it through the strike, and CLEARS it on
--               recover. Absent or 0 = nothing open.
--   SeamsBroken (number, integer BITMASK) - the same bit layout, for the
--               permanent scars. MONOTONIC: bits are only ever set, never
--               cleared, for the life of the fight.
--   SeamMeterL  (number, 0..1) - the stagger meter for the side +1 flank:
--               seams 2, 4, 6 (the authored +y side, PyreliskPath's `flank`
--               with side = +1, which is the golem's LEFT).
--   SeamMeterR  (number, 0..1) - the same for side -1: seams 3, 5, 7.
--
-- Seam 1 is the CHEST. It belongs to NEITHER meter and stays closed until the
-- fight asks for it - the server simply never sets bit 0 before then; nothing
-- here special-cases it beyond giving it no flank.
--
-- SAFE DEFAULTS, and they are load-bearing whenever the server half is out
-- of step: absent or malformed attributes give openMask = 0, brokenMask = 0
-- and both meters 0, which sends every seam down the CLOSED branch. Nothing
-- errors, nothing goes dark, and no seam ever advertises itself as
-- shootable because a number failed to arrive.
--
-- WHAT THIS BLOCK USED TO PROMISE, AND NO LONGER DOES (2026-09-09). It said
-- the CLOSED branch was "today's look, byte for byte" - the pre-seam draw
-- unchanged - and that was the right guarantee while the server half was
-- unlanded and the only job here was to not regress. The server half has
-- been in since 2026-09-06, and the guarantee is now the thing standing in
-- the way: a closed seam drawn at the same MOLTEN-to-EMBER heat as the core
-- and the maw is as bright as an open one, so "the shell is split, shoot
-- HERE, NOW" had nothing left to say. The three states are deliberately far
-- apart now - see THE THREE STATES below - and a closed seam is dimmer than
-- it used to be on purpose. The core, the maw and the vent throats keep the
-- old ramp exactly; they are anatomy, not targets.
-- =========================================================================
--
-- NOT part of this system, on purpose: the MAW seam and the three VENT
-- THROAT glows. They are anatomy - a lit mouth and three lit shafts - not
-- targets, they have no seam index and no bit, and they keep exactly the
-- stance-driven behaviour they have always had.

-- Bit (i-1) as a mask, per the contract. Precomputed so the draw loop never
-- shifts.
local SEAM_BIT = table.create(#PyreliskPath.SEAMS, 0)
local ALL_SEAM_BITS = 0
for index = 1, #PyreliskPath.SEAMS do
	SEAM_BIT[index] = bit32.lshift(1, index - 1)
	ALL_SEAM_BITS += SEAM_BIT[index]
end

-- Which meter a seam answers to: +1 = SeamMeterL, -1 = SeamMeterR, 0 = the
-- chest, which answers to neither.
--
-- DERIVED off PyreliskPath.SEAMS rather than written out, so it cannot drift
-- from the table it describes. `authored(x, y, z)` lands at (x, z, -y), so an
-- authored +y seam arrives with a NEGATIVE body-local Z - and side +1 is the
-- authored +y flank (PyreliskPath's `flank`). Hence -sign(at.Z).
local SEAM_FLANK = table.create(#PyreliskPath.SEAMS, 0)
for index, seam in PyreliskPath.SEAMS do
	SEAM_FLANK[index] = if math.abs(seam.at.Z) < 1e-3 then 0 elseif seam.at.Z < 0 then 1 else -1
end

-- ============================== THE THREE STATES =========================
--
-- The fissure is the fight's answer to "how do I kill this". It is a real
-- crack in the shell (boss_gen's PY_SEAM_LINE: thirty studs of jagged split
-- torn between two courses of cladding, recessed between the boulders), and
-- these three looks are the rock's own language for what it is doing. NO
-- beacons, no outlines, no floating markers - the brief was explicit and it
-- is right: a highlight wall on a 207-stud lava golem is a UI element
-- pretending to be art.
--
--   CLOSED   a cooling ember. Deep red-orange, well down the ramp, no pulse.
--            You can see the thing has molten cracks in it - that IS the
--            silhouette - but nothing is asking to be shot.
--   OPEN     the armour gapes. The crack runs white-hot and pulses, the
--            fissure scales up so the gap is visibly wider, embers pour out
--            of it, and the whole molten core flares behind the shell.
--   BROKEN   a dead scar. The fire is gone: cold slag, permanently a little
--            wider than it was, and NOT pulsing.
--
-- THE INTENSITY SCALE, extended in both directions so all three fit on one
-- number that composes with stance heat instead of fighting it:
--
--   -1 .. 0   DEAD -> MOLTEN   (the cooling half; new)
--    0 .. 1   MOLTEN -> EMBER  (the original ramp, unchanged)
--    1 .. 2   EMBER -> WHITE_HOT
--
-- so CLOSED sits at about -0.45, OPEN at +1.30 and up, and BROKEN at -0.92.
-- That is nearly two full units of the ramp between closed and open, which
-- is the "unmissable at 200 studs at night" the brief asks for: one is a
-- dull red line in black rock, the other is a white-hot split throwing
-- sparks.

-- White-hot: the top of the scale, and the colour an open seam runs toward.
local WHITE_HOT = Color3.fromRGB(255, 240, 214)
-- ...and the bottom of it: cold slag, the colour a broken seam is left at.
-- Not black - a scar has to stay READABLE as a scar, or a phase-three body
-- covered in them just looks like a body.
local DEAD = Color3.fromRGB(26, 18, 20)

-- RE-PITCHED FOR THE PLATED BODY (2026-09-12), and the whole ladder moved
-- with it. The shell used to be BLACK with seven lit cracks in it, so a closed
-- seam could be the dimmest lit thing on the boss and still be the only thing
-- to look at. The shell is now a molten body wearing armour plates: there is a
-- lit crack round EVERY plate, the core's own glow is what lights them, and
-- the three states have to sit against that floor rather than against black.
--
--   ambient crack network   0.06 .. 0.80 (the core; see `glow` in drawBody)
--   CLOSED seam             0.18 .. ~0.98, i.e. AT the network and a shade
--                           over it - "just another crack", which is what the
--                           brief asks a sealed seam to read as. It is
--                           findable by GEOMETRY instead: the builder clears
--                           the plating away from each site and lays one big
--                           slab pair split by a 12-stud fissure, against an
--                           ambient crack of two to three studs.
--   OPEN seam               1.45 .. 1.75, EMBER to WHITE_HOT and pulsing, and
--                           since 2026-09-12 it is the hottest thing on the
--                           body again - the act-3 rocks that used to sit
--                           above it at 1.62..1.92 are gone with the climb.
--
-- WHY CLOSED CAME UP RATHER THAN THE NETWORK GOING DOWN: a closed seam DIMMER
-- than the cracks beside it reads as a healed scar - it looks like the broken
-- state, which is the one thing it must not look like.
local CLOSED_GLOW = 0.18
-- ...and how much of that a damaged shell burns back off. At full stance
-- damage a closed seam runs to about EMBER: by phase three the thing IS
-- visibly coming apart even between attacks.
local CLOSED_HEAT = 0.55

-- OPEN: the "shoot me" tell, and it has to read instantly at 200 studs (the
-- row's maxReach) across a dark arena. Well past the closed ceiling,
-- pulsing in both colour and size so it is legible even to a player who has
-- lost the colour to the fog.
local OPEN_GLOW = 1.45
local OPEN_PULSE = 0.30 -- added by the pulse, so 1.45..1.75
local OPEN_METER = 0.40 -- added by that flank's meter: "almost there", on the body
-- THE GAPE, and it is much smaller than it was because the geometry got much
-- bigger. The old seam was a 12-stud blob and 1.24-1.36x of it was still a
-- blob sitting on a 34-stud backing plate. The fissure is 30 studs long, so
-- the same multiplier would run its ends 8 studs off the end of the rock it
-- is cracking and leave a glowing line floating in mid air. 1.10-1.16 takes
-- it to 34.8 at the peak, which is the plate, and the widening is legible
-- because it is a CRACK getting wider rather than a lamp getting bigger.
local OPEN_SWELL = 1.10
local OPEN_SWELL_PULSE = 0.06
local OPEN_PULSE_RATE = 7.0 -- rad/s on the shared state.time, so all open seams beat together
-- How hard the molten core flares while ANY seam is open. This is the second
-- half of first-encounter clarity and it costs one lerp: the body itself
-- brightens from the inside when there is a way in, so a player who has not
-- yet worked out what a seam is still reads "it is doing something and it is
-- doing it NOW".
--
-- A THIRD OF WHAT IT WAS (0.42 -> 0.14), because the core is not a lamp behind
-- a black shell any more - it is the lit network over the whole body, and at
-- the old flare the WHOLE BOSS went brighter than the seam that was asking to
-- be shot. The flare still reads: it is a hundred crack lines brightening at
-- once, which is a larger area than the old core showed through its gaps.
local OPEN_CORE = 0.14
local OPEN_CORE_PULSE = 0.08

-- BROKEN: a scar, not an invitation, and DEAD rather than bright. It used to
-- be the brightest thing on the body (1.12, above the closed ceiling), which
-- had it exactly backwards: a flank that is already spent was advertising
-- itself harder than one that is currently open. It is also not composed
-- with stance heat any more - a `max` against `glow` would relight every
-- scar as the boss burned through its own shell, and a hole that has been
-- put out does not come back.
local BROKEN_GLOW = -0.92
local BROKEN_SWELL = 1.06

-- THE EMBERS. One emitter per shell seam, live only while that seam is open:
-- sparks coming out of a split in the rock, which is the same information
-- the colour is carrying, told a second way for a player who is behind the
-- boss or has lost the hue to the arena's fog. Deliberately small - a rate
-- of 26 on seven seams is at most 182 particles, and only three are ever
-- open at once (one flank's).
local EMBER_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local EMBER_RATE = 26

-- THE ROCKS' AND THE CORE'S OWN LOOKS ARE GONE (2026-09-12, the climb-act
-- removal directive): `ROCK_GLOW` / `ROCK_DEAD` / `CORE_GLOW` and the six-bit
-- `ROCK_COUNT` described a target set this file no longer draws. The seams'
-- three states above are the only look vocabulary on the body now, and the
-- hottest thing on it is an OPEN seam again.

-- WHAT EACH PIECE IS MADE OF - colour and material, for BOTH paths.
--
-- This used to be the fallback's table alone, which meant importing the pack
-- made the boss LOOK WORSE: a cloned mesh keeps the glTF base colour under
-- the default Plastic, so the imported colossus was a 270-stud plastic
-- mountain while the stand-in blocks it replaced were correctly coloured
-- rock. That is the worst way round - importing the real art reads as the
-- import having failed.
--
-- It is asserted here, on the clone too, because the palette is a fight rule
-- wearing a material and not art that can be quietly re-exported away: the
-- shell has to be black for every lit gap to read as the core showing
-- through it, and the seams have to be the brightest thing on the body
-- because they are what a player shoots.
--
-- Colours are the row's (Creatures.items.pyrelisk.body): OBSIDIAN = color,
-- BASALT = finColor, MOLTEN = markColor.
local DEFAULT_LOOK = { OBSIDIAN, Enum.Material.Rock }
local LOOK = {
	-- the shell: broken volcanic glass, so Rock rather than a flat plate
	Torso = { OBSIDIAN, Enum.Material.Rock },
	Head = { OBSIDIAN, Enum.Material.Rock },
	Jaw = { OBSIDIAN, Enum.Material.Rock },
	Shoulder = { OBSIDIAN, Enum.Material.Rock },
	UpperArm = { OBSIDIAN, Enum.Material.Rock },
	Forearm = { OBSIDIAN, Enum.Material.Rock },
	Vent = { OBSIDIAN, Enum.Material.Rock },
	-- basalt: the crown columns and the fist's claws
	Crown = { BASALT, Enum.Material.Slate },
	Hand = { BASALT, Enum.Material.Slate },
	-- the climb route, flat cut rock so footing reads as footing
	WalkArm = { SLAG, Enum.Material.Slate },
	WalkDeck = { SLAG, Enum.Material.Slate },
	WalkNeck = { SLAG, Enum.Material.Slate },
	-- THE GLOW IS THE DESIGN. Undamaged this thing is a black mountain; every
	-- lit gap is the core showing through a break in the shell.
	Core = { MOLTEN, Enum.Material.Neon },
	Seam = { MOLTEN, Enum.Material.Neon },
	Eyes = { EMBER, Enum.Material.Neon },
	-- DORMANT (2026-09-12, the climb-act removal directive), and the two rows
	-- STAY. `makePiece` and `standIn` are table lookups over the pack's own
	-- names, the pack still exports both objects, and a look row removed while
	-- the object still exists is the hole that reads as an import failure the
	-- day somebody instances one again. Nothing in this file asks for either
	-- name any more, so nothing reads these two lines; they are the pack's
	-- palette staying total.
	ArmRock = { MOLTEN, Enum.Material.Neon },
	NeckCore = { MOLTEN, Enum.Material.Neon },
}

-- ---------------------------------------------------- THE ARMS' OWN LAVA
--
-- `Pyrelisk_Core` is the whole body's molten underbody after the 2026-09-12
-- plating - the trunk, the yoke, a ball at each shoulder joint and one in the
-- skull - and it is drawn ONCE with the body's own frame. It cannot follow a
-- swinging bone, the pack is closed at seventeen objects (design section 8.3),
-- and a part carries one material, so there is nothing in the pack to be the
-- upper arm's lava and no way to make half a limb Neon.
--
-- So each bone is drawn TWICE. The second copy is the same mesh, scaled in
-- 7.5% about its own centre and lit as lava: its plates sit a couple of studs
-- below the outer shell's, so what shows through the outer shell's cracks is
-- molten rock and what shows anywhere else is nothing. A scale strictly under
-- 1 about a point inside a shell can only move surface INWARD, which is why
-- this cannot poke out through the silhouette.
--
-- THE ROLL IS NOT OPTIONAL, and it is the half of this that is easy to miss:
-- scaled alone, the twin's plates sit under the outer's PLATES and its cracks
-- under the outer's CRACKS, so every groove you look down shows the twin's own
-- groove and the arm renders exactly as dark as it did without a twin.
-- Measured in the builder's own render: 0.1% of the arm frame lit before the
-- roll, 24% after. Half a cell (pi/cols, and the bones carry 7 columns) puts
-- the twin's plates under the outer's cracks.
--
-- boss_gen's `PY_TWIN` is the same table for the staged renders, and the two
-- have to agree or the frames the art was signed off on are not the frames the
-- fight draws.
local TWIN = {
	UpperArm = { scale = Vector3.new(1, 0.925, 0.925), roll = math.pi / 7 },
	Forearm = { scale = Vector3.new(1, 0.925, 0.925), roll = math.pi / 7 },
	-- the fist is a golden-angle lattice rather than rings, so any roll
	-- decorrelates it; a quarter turn is as good as any. It scales on all three
	-- axes because it is a blob rather than a bone - a bone must keep its
	-- LENGTH or its cap ring ends up with nothing behind it.
	Hand = { scale = Vector3.new(0.925, 0.925, 0.925), roll = math.pi / 2 },
}

-- ------------------------------------------------------------- the stand-ins
--
-- Drawn only until the pack is imported, and they have to be DEBUGGABLE: an
-- un-imported fight should put the right shapes in the right places, or the
-- stand-ins hide the very placement bugs they exist to expose.
--
-- Which takes more than a size table, because a Part's Size is centred on its
-- CFrame and the authored pieces do NOT straddle their origins. A limb runs
-- 0..+L along +X from its JOINT, the shell pieces are measured off the body
-- origin at the lake's surface, and a module runs OUT along its normal. Sized
-- but not offset, the arms sank half their length back through the shoulder,
-- the torso hung 120 studs under the lava and all four head pieces were
-- concentric boxes inside the head.
--
-- So each row is the piece's authored BOUNDING BOX, and both the size and the
-- offset from its origin fall out of it. The rows are the builder's own
-- export lines, pasted verbatim:
--
--   blender --background --python assets/boss_gen.py -- /tmp/py.glb pyrelisk
--
-- BLENDER axes, `lo` and `hi` in the printed order, so re-pasting after an
-- art change is mechanical and converts nothing by hand.
--
-- `spin` is the quarter turn the builder gives a MODULE about Blender Y to
-- put its outward normal on +Z (`obj.rotation_euler`, which both Seam and
-- Vent set to -90) - the printed bbox is taken BEFORE it, so it is applied
-- here. Blender's Ry(-90) sends (x, y, z) to (-z, y, x), which is `spin` =
-- -1 in the arithmetic below.
--
-- SEAM CARRIED +1 AND WAS WRONG (fixed 2026-09-09). +1 is Ry(+90), the other
-- way, which puts the module's outward axis INTO the rock: the stand-in seam
-- sat on the far side of the shell from the one the imported pack draws. It
-- never showed because the old seam was a 12-stud hexagonal wedge that looks
-- the same from either side; the fissure that replaced it is 30 studs long
-- and does not.
--
-- Re-pasted whole on 2026-09-09 for the remodelled body, AGAIN on 2026-09-12
-- for the connectivity/uniformity pass (knit pulls, vent re-loft, limb cap
-- rings, crown re-seat), and AGAIN the same day for THE PLATING - every row
-- here is from the builder's own export line.
--
-- What the plating did to these numbers, because it is the reason to trust
-- that they were re-pasted rather than patched: `_Core` grew in every
-- direction (it is the whole body's molten underbody now, with a ball at each
-- shoulder joint and one in the skull, so its y half-extent went from 67 to
-- 112), the arm bones SHRANK a little (flush plates stand less proud than
-- boulders: the upper arm's z half-extent 27.5 -> 24.1), `_Seam` got wider
-- and shallower (the fissure is half again as wide and its offshoots are
-- sunk), `_Vent` lost four studs off its spikes and gained them below its
-- foot, and `_WalkArm` / `_WalkDeck` / `_WalkNeck` moved with the rock they
-- are seated on.
local AUTHORED_BOX = {
	Torso = { lo = { -50.7, -82.8, -59.4 }, hi = { 50.0, 86.0, 155.8 } },
	Core = { lo = { -46.5, -112.3, -66.0 }, hi = { 42.2, 112.3, 198.3 } },
	Head = { lo = { -28.8, -27.1, -2.9 }, hi = { 32.2, 27.3, 49.6 } },
	Jaw = { lo = { -6.4, -14.9, 2.4 }, hi = { 29.3, 15.0, 17.4 } },
	Crown = { lo = { -16.7, -21.2, 36.0 }, hi = { 23.2, 19.9, 53.6 } },
	Eyes = { lo = { 23.3, -12.7, 14.3 }, hi = { 27.2, 12.9, 17.7 } },
	Shoulder = { lo = { -23.1, -25.8, -20.4 }, hi = { 33.4, 25.7, 30.2 } },
	UpperArm = { lo = { -4.8, -24.0, -24.5 }, hi = { 64.5, 23.6, 24.0 } },
	-- FLATTENED (`_py_limb_clad(..., flat=0.74)`): it is the ramp, so its z
	-- half-extent is what a slab can sit on. See `alongBone`.
	Forearm = { lo = { -8.3, -20.9, -19.3 }, hi = { 68.9, 20.3, 16.2 } },
	Hand = { lo = { -5.9, -18.4, -15.6 }, hi = { 28.3, 16.9, 16.0 } },
	-- THE FISSURE: 30 studs long on Blender Y (which is the part's own
	-- vertical tangent once the spin is applied), about 27 across including
	-- the hairline offshoots, and only 7 deep - it is a crack, not a lamp.
	Seam = { lo = { -5.8, -15.0, -11.3 }, hi = { 2.3, 15.0, 11.2 }, spin = -1 },
	-- THE VENT GREW A FOOT (2026-09-12), which is why `lo` on its own axis is
	-- negative now: the shaft reaches PY_VENT_DROP studs BELOW its site,
	-- through the deck slab standing over the rock, so the chimney is seated in
	-- the boss rather than resting on the plate. The mouth, the spikes and the
	-- authored site are all exactly where they were.
	Vent = { lo = { -10.2, -9.9, -10.7 }, hi = { 28.4, 11.0, 10.7 }, spin = -1 },
	WalkArm = { lo = { 8.0, -9.0, 16.3 }, hi = { 56.0, 9.0, 20.3 } },
	-- All THREE decks, as one box: the builder exports the spine plateau and
	-- both shoulder pads as a single Pyrelisk_WalkDeck object, so the stand-in
	-- is one block spanning them. `checkStandIns` compares it against the
	-- union of PyreliskPath.DECK, which is the same span.
	WalkDeck = { lo = { -46.0, -75.0, 137.7 }, hi = { 18.0, 75.0, 151.9 } },
	-- DORMANT (2026-09-12): the plate from the working shoulder pad up to the
	-- neck collar, which was act 3's last stretch. `PyreliskPath.climbSlabs` no
	-- longer cuts a Neck slab at all, so this plate is never real and never
	-- raised; the row stays for the same reason the two above it do.
	-- Unlike every other slab in this pack
	-- it is TILTED in body space (the pad's face is authored z 142 and the neck
	-- band's measured rock top is 155.2, so a flat box spanning them is either
	-- buried at one end or hanging at the other), which means this row is the
	-- AXIS-ALIGNED BOX AROUND A TILTED PLATE and is deliberately fatter than
	-- the plate itself. The stand-in is therefore approximate here in a way it
	-- is not for _WalkArm or _WalkDeck - it puts a block in the right place
	-- rather than the right plate - and `checkStandIns` does not compare it for
	-- that reason. The real surface is PyreliskPath's `Neck` slab.
	WalkNeck = { lo = { -31.1, -1.3, 138.3 }, hi = { 15.1, 51.5, 163.4 } },
	-- DORMANT (2026-09-12): act 3's orange rock, drawn by nothing now - see THE
	-- CLIMB ACT IS GONE. The row stays because `standIn` has to remain TOTAL
	-- over the pack's seventeen objects - it is where the recentring offset
	-- (`pieceOffset`) comes from, and a missing row silently hands back a
	-- 20-stud cube at the origin instead of failing.
	-- It is the pack's THIRD MODULE - so it carries
	-- `spin` like Seam and Vent do, with the SAME SIGN (-1 = the builder's
	-- Ry(-90), which puts the authored +X onto +Z). +1 would put the boil
	-- INTO the arm, and on a shape this close to rotationally symmetric about
	-- its own axis that ships INVISIBLY: the silhouette is identical either
	-- way and the only symptom is that the lit part is buried. That is the
	-- mistake the Seam row carried for three days.
	ArmRock = { lo = { -1.9, -4.8, -5.5 }, hi = { 5.6, 5.0, 4.8 }, spin = -1 },
	-- ...and the neck core, DORMANT on the same terms: one object, NOT a
	-- module, authored with +Z as the BODY's up. NO `spin` field, deliberately -
	-- the builder gives it no `rotation_euler`, and the draw that used to give
	-- it the body's own rotation rather than a surface frame is retired with
	-- the rest of the climb act.
	NeckCore = { lo = { -12.1, -13.0, -4.5 }, hi = { 12.2, 12.6, 5.7 } },
}

-- One authored bbox -> the stand-in's Roblox size, and the offset from the
-- piece's ORIGIN to its centre. The pack is exported y-up (boss_gen.py,
-- export_yup), so authored (x, y, z) arrives as (x, z, -y) - the same mirror
-- PyreliskPath's `authored` puts every number it lifts through.
local function standIn(name: string): (Vector3, CFrame)
	local box = AUTHORED_BOX[name]
	if not box then
		return Vector3.new(20, 20, 20), CFrame.identity
	end
	local lo, hi = box.lo, box.hi
	local cx, cy, cz = (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2, (lo[3] + hi[3]) / 2
	local sx, sy, sz = hi[1] - lo[1], hi[2] - lo[2], hi[3] - lo[3]
	if box.spin then
		-- A quarter turn about Blender Y: +90 sends +X to -Z, -90 to +Z.
		cx, cz = box.spin * cz, -box.spin * cx
		sx, sz = sz, sx
	end
	return Vector3.new(sx, sz, sy), CFrame.new(cx, cz, -cy)
end

-- The two pieces PyreliskPath measures INDEPENDENTLY, because the server
-- spawns the collidable slabs off them. If a re-export moves the ramp or the
-- deck and the table above is not repasted, the rock you see and the rock you
-- stand on part company - so say so at load, rather than at the moment
-- somebody walks off the side of it.
local function checkStandIns()
	local armSize, armAt = standIn("WalkArm")
	local deckSize, deckAt = standIn("WalkDeck")
	local lo, hi
	for _, deck in PyreliskPath.DECK do
		local half = deck.size / 2
		lo = if lo then lo:Min(deck.at - half) else deck.at - half
		hi = if hi then hi:Max(deck.at + half) else deck.at + half
	end
	local rows = {
		{ "WalkArm size", armSize, PyreliskPath.WALK_ARM_SIZE },
		{ "WalkArm origin", armAt.Position, Vector3.new(PyreliskPath.FOREARM / 2, PyreliskPath.WALK_ARM_LIFT, 0) },
		{ "WalkDeck size", deckSize, hi - lo },
		{ "WalkDeck origin", deckAt.Position, (lo + hi) / 2 },
	}
	for _, row in rows do
		if (row[2] - row[3]).Magnitude > 0.5 then
			warn(
				string.format(
					"[PyreliskBody] %s is %s off the builder but %s in PyreliskPath - re-paste AUTHORED_BOX from boss_gen",
					row[1],
					tostring(row[2]),
					tostring(row[3])
				)
			)
		end
	end

	-- THE SIX-ROCKS-SIX-BITS ASSERT IS GONE with the rocks it counted
	-- (2026-09-12, the climb-act removal directive). It asked
	-- `PyreliskPath.armRocks` for its length at load and compared that against
	-- the mask's width; there is no such function and no such mask now. The
	-- two rows above are what remain, and they are the ones that matter for
	-- the reason they always did: the server cuts collidable slabs off
	-- `WalkArm` and `WalkDeck`, so those two measurements have to agree with
	-- the builder or the rock you see and the rock you stand on part company.
end

-- ---------------------------------------------------------------- pieces

-- Per-part bookkeeping, weak so it empties itself when a body is destroyed.
--
-- `pieceOffset` is the origin convention, and it applies to BOTH PATHS - which
-- it did not until 2026-09-12, and that was a real defect rather than a
-- tidy-up. What this block used to say was that "an imported mesh carries that
-- origin in the mesh and gets none", and Roblox does not work that way:
-- importing a glTF RE-CENTRES each MeshPart's geometry on the part, so the
-- authored offset survives only as the part's position inside the imported
-- model and as `PivotOffset`, neither of which a `CFrame =` write consults. A
-- clone re-CFramed at a joint therefore draws its mesh centred on that joint -
-- the torso hanging 48 studs under the lake, both arms sunk half their length
-- back through the shoulder, the four head pieces concentric.
--
-- It never showed because nothing has imported this pack yet: every frame this
-- fight has ever been seen in is the stand-in path, which was correct. The
-- lane that hit it live is Rimefang's (its MESH_OFFSET table and the
-- "jumbled whale" of the same day); this is that fix, and it needs no second
-- table because `standIn`'s offset IS the authored bbox centre - the one
-- number both paths need.
--
-- `pieceBase` is the authored size, kept because damage grows the seams.
local pieceOffset = setmetatable({}, { __mode = "k" })
local pieceBase = setmetatable({}, { __mode = "k" })

local function place(part: BasePart, cframe: CFrame)
	local offset = pieceOffset[part]
	part.CFrame = if offset then cframe * offset else cframe
end

-- ONE PLACE EVERY GLOW WRITE GOES THROUGH. Stance damage, the punish-window
-- flare, an open seam's pulse and a broken seam's scar all reduce to two
-- numbers per part - an intensity and a scale - and they compose as numbers
-- HERE rather than as property writes that overwrite each other every frame.
-- Before the seams existed the stance code wrote Color and Size to every lit
-- part behind one shared change gate; a second effect writing the same two
-- properties beside it would have meant last-writer-wins at 60 Hz.
--
-- `intensity` runs the three-segment ramp described in THE THREE STATES:
-- -1..0 is DEAD -> MOLTEN (the cooling half), 0..1 is the original
-- MOLTEN -> EMBER, and 1..2 continues on to WHITE_HOT. The middle segment is
-- bit for bit what it always was, so everything that is ANATOMY rather than
-- a target - the core, the maw, the three vent throats - lands on precisely
-- the colour it landed on before.
--
-- The change gate is per PART now rather than one gate for all twenty, since
-- seams no longer move together - and it is what keeps this loop free of
-- allocation: Color3.Lerp and the Size multiply are the only things here
-- that allocate, and neither runs on a frame where nothing moved. The gate's
-- sentinel is -9 rather than -1, because -1 is now a REAL intensity (a fully
-- dead scar) and a part whose first frame asked for exactly -1 would have
-- been skipped and left at whatever colour `makePiece` gave it.
local lookHeat = setmetatable({}, { __mode = "k" })
local lookScale = setmetatable({}, { __mode = "k" })

local function applyLook(part: BasePart, intensity: number, scale: number?)
	if math.abs((lookHeat[part] or -9) - intensity) > 0.004 then
		lookHeat[part] = intensity
		if intensity < 0 then
			part.Color = DEAD:Lerp(MOLTEN, math.max(intensity + 1, 0))
		elseif intensity <= 1 then
			part.Color = MOLTEN:Lerp(EMBER, intensity)
		else
			part.Color = EMBER:Lerp(WHITE_HOT, math.min(intensity - 1, 1))
		end
	end
	if scale and math.abs((lookScale[part] or -9) - scale) > 0.004 then
		lookScale[part] = scale
		part.Size = pieceBase[part] * scale
	end
end

-- SPARKS OUT OF A SPLIT ROCK. Attached once per shell seam and switched by
-- `Enabled`, never rebuilt: a ParticleEmitter that is turned off keeps its
-- existing particles alive to the end of their own lifetimes, which is
-- exactly the fade a closing seam wants, and destroying one instead would
-- cut the last half second of embers off mid-air.
--
-- The emission direction is Top, which on a module is its OUTWARD NORMAL:
-- every piece in this pack is authored with +Z out of the surface and the
-- y-up export lands that on the part's own +Y (see `onSurface`). Getting it
-- wrong is not a crash, it is embers pouring sideways INTO the shell.
local function makeEmbers(part: BasePart): ParticleEmitter
	local embers = Instance.new("ParticleEmitter")
	embers.Texture = EMBER_TEXTURE
	embers.Color = ColorSequence.new(WHITE_HOT, MOLTEN)
	embers.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(0.6, 0.45),
		NumberSequenceKeypoint.new(1, 1),
	})
	embers.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 4.5),
		NumberSequenceKeypoint.new(1, 0.4),
	})
	embers.LightEmission = 1
	embers.LightInfluence = 0
	embers.Lifetime = NumberRange.new(0.8, 1.6)
	embers.Rate = EMBER_RATE
	embers.Speed = NumberRange.new(7, 18)
	embers.SpreadAngle = Vector2.new(26, 26)
	-- Embers RISE once they are clear of the shell, which is what says "this
	-- is heat" rather than "this is a sparkler". Applied as world
	-- acceleration on purpose: the body pitches up to 16 degrees during a
	-- slam, and sparks that pitched with it would read as attached to the
	-- rock.
	embers.Acceleration = Vector3.new(0, 26, 0)
	embers.Drag = 1.2
	embers.EmissionDirection = Enum.NormalId.Top
	embers.Enabled = false
	embers.Parent = part
	return embers
end

local function packPiece(name: string): BasePart?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local pack = assets and assets:FindFirstChild(PACK_NAME)
	local piece = pack and pack:FindFirstChild(PREFIX .. name, true)
	return if piece and piece:IsA("BasePart") then piece else nil
end

local function makePiece(name: string, parent: Instance): BasePart
	local template = packPiece(name)
	local size, offset = standIn(name)
	local part
	if template then
		part = template:Clone()
		-- The import re-centred the mesh; put the authored origin back (see
		-- `pieceOffset`). PivotOffset is cleared so nothing downstream can
		-- apply the same displacement a second time through PivotTo.
		part.PivotOffset = CFrame.identity
		pieceOffset[part] = offset
	else
		if not warnedMissingPack then
			warnedMissingPack = true
			warn("[PyreliskBody] " .. PACK_NAME .. " not imported - drawing stand-ins")
		end
		part = Instance.new("Part")
		part.Size = size
		pieceOffset[part] = offset
	end
	-- The colour and the material, on BOTH paths - see LOOK. An imported
	-- clone arrives at the glTF base colour under the default Plastic, and
	-- neither is what this fight needs to be legible.
	local look = LOOK[name] or DEFAULT_LOOK
	part.Color = look[1]
	part.Material = look[2]
	-- A textured PBR surface would override Color outright. The pack authors
	-- one flat material per object and never a SurfaceAppearance, so anything
	-- that arrives with one arrived by accident (BrinejawBodyController
	-- settled this for the same round trip).
	local appearance = part:FindFirstChildWhichIsA("SurfaceAppearance")
	if appearance then
		appearance:Destroy()
	end
	pieceBase[part] = part.Size
	part.Name = PREFIX .. name
	part.Anchored = true
	part.CanCollide = false -- the footing is the SERVER's model, never ours
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = name == "Torso" or name == "Head"
	part.Parent = parent
	return part
end

-- One bone's molten twin: the same piece, lava-coloured, scaled in. See TWIN.
--
-- Built through `makePiece` so it gets the same clone-or-stand-in treatment,
-- the same offset and the same bookkeeping, and only then overridden - which
-- also means a twin of a STAND-IN is a slightly smaller block inside a block,
-- i.e. invisible and harmless, rather than a special case to carry.
local function makeTwin(name: string, parent: Instance): BasePart
	local part = makePiece(name, parent)
	part.Name = PREFIX .. name .. "Molten"
	part.Color = MOLTEN
	part.Material = Enum.Material.Neon
	part.CastShadow = false
	part.Size = pieceBase[part] * TWIN[name].scale
	-- `pieceBase` is what `applyLook` multiplies, and this part's base IS its
	-- scaled size: nothing else may re-derive it from the outer piece.
	pieceBase[part] = part.Size
	return part
end

-- A limb piece is authored along +X FROM ITS JOINT (assets/boss_gen.py), so
-- aligning it is: look down the bone, then turn the frame a quarter so the
-- part's +X is the bone rather than its -Z.
--
-- `up` is NOT world Y, and that is the whole point. CFrame.lookAt defaults to
-- the world's up, which goes degenerate exactly when a bone points straight
-- up or down - and this golem's arms hang at Y = -0.95 at rest and rear to
-- +0.86 on a handfall, so they live in that band rather than visiting it. A
-- degenerate frame makes the roll undefined, which shows up as a forearm
-- snapping a quarter turn between frames for no reason a player can see.
--
-- So the reference is the BODY's own axes, and it blends between them with a
-- smoothstep instead of switching at a threshold: a hard switch has the same
-- failure it was meant to prevent, just at a different angle. (ChainPose's
-- alongX hit this exactly - Brinejaw's idle bob alone tripped its 0.99 switch
-- three times per ten seconds; 80's fix blends 0.90..0.99, and this is the
-- same shape of fix for a rig that does not share that module.)
--
-- AND THE ROLL IS LOAD-BEARING NOW, which it was not when that blend was
-- written. Since the 2026-09-01 rebuild the FOREARM IS THE RAMP - it is
-- authored flattened (`_py_limb(..., flat=0.72)`) with a top to walk on, and
-- the WalkArm slab is a flat plate lying on that top. The builder aims both
-- with `_py_aim_up`: +X down the bone and the piece's local up as near
-- AUTHORED UP as a perpendicular can get. This function has to build the same
-- basis or the flat face is drawn banked.
--
-- What the old 0.90..0.99 band did to it: the plant pose's forearm is 0.950
-- off the body's up, which is 56% of the way through that band - 0.588 after
-- the smoothstep - so the reference was mostly LookVector, and the frame came
-- out rolled 38.5 degrees. The ramp you climb was standing on its edge, and
-- the server's own slab (PyreliskPath.plateOn, which references world up) was
-- not on the same roll as the rock the player could see.
local function alongBone(at: Vector3, dir: Vector3, body: CFrame): CFrame
	if dir.Magnitude < 1e-4 then
		return CFrame.new(at)
	end
	local forward = dir.Unit
	-- THE UP REFERENCE IS THE BODY'S OWN UP, and it has to stay that for as
	-- long as it possibly can - see the roll note above. The blend to the
	-- fallback is a DEGENERACY GUARD, not a behaviour: it may not start until
	-- the bone is within about six degrees of vertical, which the pose book
	-- never reaches (its most vertical bone is `collapse`'s forearm at 0.996,
	-- and every bone the climb is laid on sits at 0.95-0.97).
	--
	-- The fallback is the body's RIGHT and not its LOOK, because the builder's
	-- is authored +X (`_py_aim_up`: `up = (1, 0, 0)` when the bone is up), and
	-- authored +X arrives here as body-local +X. Blending toward LookVector -
	-- authored +Y, the lateral axis - rolled the piece toward a reference 90
	-- degrees from the one the mesh was cut against.
	local vertical = math.abs(forward:Dot(body.UpVector))
	local t = math.clamp((vertical - 0.995) / 0.0045, 0, 1)
	t = t * t * (3 - 2 * t) -- smoothstep: no discontinuity at either end
	local up = body.UpVector:Lerp(body.RightVector, t)
	if math.abs(forward:Dot(up.Unit)) > 0.999 then
		up = body.LookVector -- the last resort; cannot be parallel to both
	end
	return CFrame.lookAt(at, at + forward, up.Unit) * CFrame.Angles(0, math.pi / 2, 0)
end

-- A module is authored with its OUTWARD NORMAL up (+Z in Blender, which the
-- y-up export lands on +Y here), so seating one on the shell is: look along
-- the normal, then tip the frame so the part's +Y is that normal.
local function onSurface(at: Vector3, normal: Vector3): CFrame
	if normal.Magnitude < 1e-4 then
		return CFrame.new(at)
	end
	local out = normal.Unit
	-- CFrame.lookAt defaults to the world's up, and the back vent's normal IS
	-- the world's up: `VENTS[1].out` is straight up in body space, so at rest
	-- - the one time the body has no lean to tip it off vertical - the cross
	-- product is zero and the frame comes back NaN. One vent drawn nowhere,
	-- every frame, with nothing in the log. Same failure alongBone documents
	-- at length; the modules need their own answer because their normals are
	-- fixed to the shell rather than swinging through a band.
	local up = if math.abs(out.Y) > 0.999 then Vector3.xAxis else Vector3.yAxis
	return CFrame.lookAt(at, at + out, up) * CFrame.Angles(-math.pi / 2, 0, 0)
end

-- ---------------------------------------------------------------- lifecycle

local bodies: { [Model]: any } = {}

local function destroyBody(model: Model)
	local entry = bodies[model]
	if not entry then
		return
	end
	bodies[model] = nil
	if entry.folder then
		entry.folder:Destroy()
	end
end

local function adoptBoss(model: Model)
	if bodies[model] or model:GetAttribute("Pose") ~= POSE_NAME then
		return
	end
	local center = model:GetAttribute("PoseCenter")
	if typeof(center) ~= "Vector3" then
		center = model:GetPivot().Position
	end

	local folder = Instance.new("Folder")
	folder.Name = "PyreliskBody"
	folder.Parent = Workspace

	local pieces = {
		Torso = makePiece("Torso", folder),
		Core = makePiece("Core", folder),
		Head = makePiece("Head", folder),
		Jaw = makePiece("Jaw", folder),
		Crown = makePiece("Crown", folder),
		Eyes = makePiece("Eyes", folder),
		WalkDeck = makePiece("WalkDeck", folder),
		WalkNeck = makePiece("WalkNeck", folder),
	}
	-- The arms: one set of four per side.
	local arms = {}
	for _, side in { -1, 1 } do
		arms[side] = {
			Shoulder = makePiece("Shoulder", folder),
			UpperArm = makePiece("UpperArm", folder),
			Forearm = makePiece("Forearm", folder),
			Hand = makePiece("Hand", folder),
			WalkArm = makePiece("WalkArm", folder),
			-- the three bones' lava (see TWIN). The pauldron needs none: it does
			-- not move relative to the body, so `Pyrelisk_Core` carries a molten
			-- ball at the joint for it.
			UpperArmMolten = makeTwin("UpperArm", folder),
			ForearmMolten = makeTwin("Forearm", folder),
			HandMolten = makeTwin("Hand", folder),
		}
	end
	-- The modules. One Seam per shell site, plus the maw; one Vent per shaft
	-- with a Seam seated in its throat.
	local seams, embers = {}, {}
	for index = 1, #PyreliskPath.SEAMS do
		seams[index] = makePiece("Seam", folder)
		-- Only the SEVEN SHELL SEAMS get embers. The maw and the three vent
		-- throats are the same module and are deliberately left without: they
		-- are anatomy, and a lit mouth that also throws sparks is a second
		-- thing telling the player to shoot at it.
		embers[index] = makeEmbers(seams[index])
	end
	local maw = makePiece("Seam", folder)
	local vents, ventGlow = {}, {}
	for index = 1, #PyreliskPath.VENTS do
		vents[index] = makePiece("Vent", folder)
		ventGlow[index] = makePiece("Seam", folder)
	end
	-- ACT 3's SEVEN ARE NOT BUILT ANY MORE (2026-09-12, the climb-act removal
	-- directive): six `ArmRock` clones and one `NeckCore` used to be made here
	-- and held at Transparency 1 until the attributes raised them. Both pack
	-- objects still exist and are simply never instanced - which is also seven
	-- fewer parts per colossus on the frame the body is adopted.

	bodies[model] = {
		folder = folder,
		pieces = pieces,
		arms = arms,
		seams = seams,
		embers = embers,
		maw = maw,
		vents = vents,
		ventGlow = ventGlow,
		state = PyreliskPath.newState(center),
		target = {},
	}
end

-- ---------------------------------------------------------------- the draw

local function approach(current: number, goal: number, rate: number, dt: number): number
	return current + (goal - current) * math.clamp(rate * dt, 0, 1)
end

local function approachAngle(current: number, goal: number, rate: number, dt: number): number
	local delta = (goal - current + math.pi) % (math.pi * 2) - math.pi
	return current + delta * math.clamp(rate * dt, 0, 1)
end

-- A published bitmask, made safe to do arithmetic on: anything that is not a
-- finite number becomes 0 (the "nothing open" default), and bits above the
-- seam count are dropped rather than trusted, so a server writing a wider
-- mask than this rig has seams cannot index past the end of the table.
local function maskOf(value: any): number
	if type(value) ~= "number" or value ~= value or value < 1 then
		return 0
	end
	return bit32.band(math.floor(value), ALL_SEAM_BITS)
end

-- A published 0..1 meter, same rule: absent, wrong type or NaN reads as 0,
-- which is the no-meter-yet look.
local function unitOf(value: any): number
	if type(value) ~= "number" or value ~= value then
		return 0
	end
	return math.clamp(value, 0, 1)
end

-- Everything the server publishes. Names match the attributes CreatureService
-- writes for a posed boss, plus this fight's own three.
local function readTarget(model: Model, target)
	target.rise = model:GetAttribute("Rise") or 1
	target.faceAngle = model:GetAttribute("FaceAngle") or 0
	target.aimAngle = model:GetAttribute("AimAngle") or target.faceAngle
	target.aimSide = model:GetAttribute("AimSide") or 1
	target.attack = model:GetAttribute("Attack") or ""
	target.blend = model:GetAttribute("AttackBlend") or 0
	target.strike = model:GetAttribute("Strike") or 0
	target.slump = model:GetAttribute("Slump") or 0
	target.planted = model:GetAttribute("Planted") or 0
	target.stance = model:GetAttribute("Stance") or 1
	-- WHICH ACT, per the attribute contract: a LEVEL, 1..3, and NIL MEANS ACT
	-- 1. That default is the whole reason a client can adopt this fight at any
	-- instant - a server that has not published it yet, or a pyrelisk in the
	-- shipped act-1 fight that never will, both draw a standing colossus
	-- rather than a collapsed one. `unitOf` is the wrong guard here (it clamps
	-- to 0..1), so the act gets its own: anything that is not a finite number
	-- reads as 1.
	--
	-- THE CEILING MOVED 4 -> 3 ON 2026-09-12 with the act set itself (the
	-- climb act is gone, so the heart is act 3). It is a CLAMP rather than a
	-- rejection, which is what makes a mid-deploy server still publishing the
	-- old 4 read as the act 4 became: the heart, and this rig unparented.
	local act = model:GetAttribute("PyreliskAct")
	target.act = if type(act) == "number" and act == act then math.clamp(math.floor(act), 1, 3) else 1
	-- The MAXIMUM, published once by CreatureService's rigged-pose branch. 0
	-- when a server has not published it, which is the cue to fall back to the
	-- high-water mark below.
	target.stances = model:GetAttribute("Stances") or 0
	target.exposed = if model:GetAttribute("Exposed") then 1 else 0
	-- THE SEAM CONTRACT, read side. See the block at the top of the file for
	-- what the server owes. Every default here is chosen so that a server
	-- which has not landed its half yet draws the seams EXACTLY as they were
	-- drawn before this existed: no bits set, no meter, nothing open.
	target.seamsOpen = maskOf(model:GetAttribute("SeamsOpen"))
	target.seamsBroken = maskOf(model:GetAttribute("SeamsBroken"))
	target.seamMeterL = unitOf(model:GetAttribute("SeamMeterL"))
	target.seamMeterR = unitOf(model:GetAttribute("SeamMeterR"))
	-- ACT 3's TWO ARE NOT READ ANY MORE. `PyreliskRocks` and `PyreliskCore`
	-- were the climb act's targets and both are removed (2026-09-12 - see THE
	-- CLIMB ACT IS GONE); the server never publishes either again, so reading
	-- them would be two attribute lookups a frame for a pair of nils. Their
	-- careful nil-versus-zero handling went with them.
	--
	-- THE COLLAPSE NEEDS NO FIELD OF ITS OWN EITHER, and that is worth stating
	-- because the sink through the caldera is new behaviour with no new
	-- attribute behind it: `PyreliskPath.collapsePhase` reads `attack` and
	-- `blend`, two fields this file has always copied, so the death's depth
	-- arrives on the wire the fight already had.
	return target
end

-- `body` is passed in rather than fetched again. `bodyCFrame` builds three
-- CFrames, multiplies them and takes a math.sin every time it is called, and
-- it is the same answer for every piece in a frame - so it is computed once
-- in `drawBody` and threaded down. (PyreliskPath still rebuilds it three
-- times inside `armJoints` alone; closing that needs a signature change in a
-- file this one does not own.)
local function drawArm(entry, state, side: number, body: CFrame)
	local set = entry.arms[side]
	local joints = PyreliskPath.armJoints(state, side)

	-- THE PAULDRON IS NOT ON THE BONE. The builder aims it along the authored
	-- +/-Y - laterally OUTBOARD from the joint, `_py_arm`'s
	-- `_py_aim(shoulder, (0, side, 0))` - and its spike runs out along that
	-- axis, (-8, 0, 14) to (-20, 0, 40). Given the upper arm's frame instead
	-- it swung through most of a half turn between rest and a handfall, so
	-- the shoulder rock read as spinning with the limb rather than being
	-- welded to the body. Authored (0, side, 0) is body-local (0, 0, -side)
	-- after the y-up mirror.
	local outboard = body:VectorToWorldSpace(Vector3.new(0, 0, -side))
	place(set.Shoulder, alongBone(joints.shoulder, outboard, body))
	place(set.UpperArm, alongBone(joints.shoulder, joints.upper, body))
	place(set.Forearm, alongBone(joints.elbow, joints.fore, body))
	place(set.Hand, alongBone(joints.wrist, joints.hand, body))

	-- THE LAVA UNDER EACH BONE, on the bone's own frame plus its roll. The roll
	-- is applied AFTER `place` and therefore about the twin's OWN centre, which
	-- for a bone is a point on its axis - so it is a roll about the bone rather
	-- than a swing off it. (See TWIN for why there is a roll at all.)
	local molten = {
		{ set.UpperArmMolten, TWIN.UpperArm.roll, joints.shoulder, joints.upper },
		{ set.ForearmMolten, TWIN.Forearm.roll, joints.elbow, joints.fore },
		{ set.HandMolten, TWIN.Hand.roll, joints.wrist, joints.hand },
	}
	for _, row in molten do
		place(row[1], alongBone(row[3], row[4], body))
		row[1].CFrame = row[1].CFrame * CFrame.Angles(row[2], 0, 0)
	end

	-- The ramp RIDES THE FOREARM, because that is what it is: the builder
	-- copies WalkArm with the forearm's own transform (`_py_arm`, walk=True),
	-- one slab lying on the arm's upper surface, already lifted +11 in the
	-- mesh. It is a LIMB piece and it is placed like every other one.
	--
	-- Not from `rampCFrame`, which answers the SERVER's different question -
	-- where to anchor a collidable SLAB, centred on the forearm's midpoint and
	-- already carrying the authored lift. Drawn from that the plank sat a
	-- second lift above the mesh's own; it also once lay crosswise to the arm,
	-- ~51 studs off to the side, before `plateOn` grew the same quarter turn
	-- this function makes. The two now agree on the bone and on the ROLL
	-- (`plateOn` references world up; `alongBone` the body's, and a planted
	-- body has no lean, so they are the same vector while a slab exists).
	place(set.WalkArm, alongBone(joints.elbow, joints.fore, body))
	-- Shown ONLY while this arm is planted, because that is the only time it
	-- is real: the server makes its own slab collidable for the same window.
	-- Showing it otherwise would promise footing that isn't there, which is a
	-- worse lie than drawing nothing.
	set.WalkArm.Transparency = if state.planted == side then 0 else 1
end

-- `rockNormal` AND `drawTargets` ARE GONE (2026-09-12, the climb-act removal
-- directive). They were the whole of act 3's draw: the nearest-segment
-- recovery of a climb plate's up, so an `ArmRock` module could be seated
-- against the surface it stood on, and the two-attribute loop that raised, lit
-- and finally cratered the six rocks and the neck core. Nothing replaces them
-- - the new act break is the body SINKING, which is `PyreliskPath.sink` and
-- costs this file no draw at all.

-- HOW FAR IT HAS COME APART, 0..1, off the stance count. `Stance` counts DOWN
-- (CreatureService's ATTR_STANCE: 1 is the last one it has), so the damage is
-- how far it has fallen from the MAXIMUM.
--
-- The maximum is published (`Stances`), and the high-water mark is kept as
-- the fallback for a server that does not: on its own it is wrong for anyone
-- who ARRIVES MID-FIGHT, because the first value they see becomes their
-- maximum and a boss two stances down draws as undamaged.
local function damageOf(entry, stance: number, stances: number): number
	entry.stanceMax = math.max(entry.stanceMax or stance, stance, stances)
	if entry.stanceMax <= 1 then
		return 0
	end
	return math.clamp((entry.stanceMax - stance) / (entry.stanceMax - 1), 0, 1)
end

local function drawBody(model: Model, entry, dt: number)
	local state = entry.state
	local target = readTarget(model, entry.target)

	-- APPENDIX K, ITEM 2: `PoseCenter` IS RE-PUBLISHED, SO IT IS READ EVERY
	-- FRAME. `adoptBoss` seeds the state from it once, and a cached centre was
	-- correct for exactly as long as this fight happened in one place.
	--
	-- Act four does not. The handoff raises the heart in another arena 40,000
	-- studs away and re-publishes the centre on the way, and the whole rig -
	-- every joint, every seam, every module - is authored as an offset from
	-- `state.center`. Cached, the colossus goes on being drawn at the caldera
	-- it died in: a full-size body standing in an empty arena nobody is in any
	-- more, with nothing anywhere to say the attribute moved and the drawing
	-- did not. That is the silent-absence shape exactly, and it costs one
	-- attribute read a frame to close.
	--
	-- A MISSING VALUE KEEPS THE LAST ONE rather than falling back to the
	-- pivot the way `adoptBoss` does: the pivot is the right seed for a body
	-- that has not been posed yet and the wrong thing to chase every frame
	-- once it has, because it would fight the pose for the centre.
	local published = model:GetAttribute("PoseCenter")
	if typeof(published) == "Vector3" then
		state.center = published
	end

	-- APPENDIX K, ITEM 4: THE EXTERIOR RIG DRAWS ONLY IN ACTS 1 AND 2, and the
	-- gate is the ACT rather than the position.
	--
	-- RE-KEYED 4 -> 3 ON 2026-09-12 with the act set (the climb act is gone, so
	-- the heart is act 3). At act three the colossus is gone -
	-- `beginBossCollapse` took it and both arms with it, and the last anyone
	-- saw of it was this body sinking through the caldera - and what the party
	-- is fighting is the heart, in a sealed room, on a standard CreaturePack
	-- body. Nothing of this rig belongs in that room. Gating on where the model
	-- is instead would be the bug the appendix names: `creature.anchor` and
	-- `creature.pos` move together at the handoff, so a position test passes
	-- the instant the centre is re-published and draws a 400-stud colossus
	-- inside a 216-stud chamber for however many frames it takes the rest of
	-- the transition to land.
	--
	-- Hidden by UNPARENTING the folder rather than by transparency: every
	-- piece in it already carries a transparency that means something (the
	-- WalkArm slab is raised only while an arm is planted, the WalkNeck plate
	-- never), so writing 1 across all of them would destroy the state the draw
	-- is keeping and there would be nothing to restore from. The folder
	-- is held by `entry`, so it survives unparented and `destroyBody` still
	-- reaches it.
	if target.act >= 3 then
		state.act = target.act
		if entry.folder.Parent then
			entry.folder.Parent = nil
		end
		return
	end
	if not entry.folder.Parent then
		entry.folder.Parent = Workspace
	end

	state.time = Workspace:GetServerTimeNow()
	state.rise = approach(state.rise, target.rise, RISE_RATE, dt)
	state.faceAngle = approachAngle(state.faceAngle, target.faceAngle, FACE_RATE, dt)
	-- Aim is LATCHED server-side (PyreliskPath's contract) - it is copied, not
	-- chased, or the client would smooth over the very commitment the
	-- telegraph is promising.
	state.aimAngle = target.aimAngle
	state.aimSide = target.aimSide
	-- THE ATTACK IS ALSO THE DEATH, and it is why the collapse needs no
	-- attribute of its own: `PyreliskPath.collapsePhase` reads this string and
	-- the blend two lines down, and turns them into the sink through the
	-- caldera (`SINK_COLLAPSE`). Copied, not chased - it is a name.
	state.attack = target.attack
	state.planted = target.planted
	state.stance = target.stance
	-- ...and THE BLEND IS THE COLLAPSE'S PROGRESS while `attack` is
	-- "collapse", so this one ease drives both the slack-arm pose and the
	-- body's descent into the shaft. Eased here rather than taken raw for the
	-- reason everything else is: the attributes arrive at about 20 Hz.
	state.blend = approach(state.blend, target.blend, BLEND_RATE, dt)
	state.strike = approach(state.strike, target.strike, BLEND_RATE * 1.6, dt)
	state.slump = approach(state.slump, target.slump, BLEND_RATE * 0.7, dt)
	state.exposed = target.exposed
	-- THE FALL, eased locally. `state.act` is copied (it is a level and the
	-- pose math reads it for the freeze), and `state.fallen` is this file's own
	-- ease of it - the only number in the state that the server does not have
	-- an opinion about. See FALL_RATE.
	state.act = target.act
	state.fallen =
		approach(state.fallen or (if target.act >= 2 then 1 else 0), if target.act >= 2 then 1 else 0, FALL_RATE, dt)

	-- ONE body frame for the whole draw. It is the most expensive thing this
	-- file asks for - three CFrames, a multiply and a math.sin apiece - and it
	-- is the same value for every piece in the frame.
	local body = PyreliskPath.bodyCFrame(state)
	place(entry.pieces.Torso, body)
	place(entry.pieces.Core, body)
	place(entry.pieces.WalkDeck, body)
	-- THE NECK PLATE IS DORMANT (2026-09-12) and the condition below can no
	-- longer be true. It is kept rather than replaced with a bare
	-- `Transparency = 1` because it is the RULE that matters and the rule has
	-- not changed: a walking plate is shown only when the server has made a
	-- slab collidable under it, since promising footing that is not there is a
	-- worse lie than drawing nothing. What changed is the ANSWER - `climbSlabs`
	-- cuts no Neck slab in any act now, and `planted` is never set once the
	-- body is down - so the plate is placed every frame and never raised.
	place(entry.pieces.WalkNeck, body)
	entry.pieces.WalkNeck.Transparency = if PyreliskPath.fallenEngaged(state) and (state.planted or 0) ~= 0
		then 0
		else 1

	local head = PyreliskPath.headCFrame(state)
	place(entry.pieces.Head, head)
	place(entry.pieces.Crown, head)
	place(entry.pieces.Eyes, head)
	place(
		entry.pieces.Jaw,
		head
			* CFrame.new(PyreliskPath.JAW_HINGE)
			* CFrame.Angles(0, 0, PyreliskPath.jawAngle(state))
			* CFrame.new(-PyreliskPath.JAW_HINGE)
	)

	for _, side in { -1, 1 } do
		drawArm(entry, state, side, body)
	end

	for index in PyreliskPath.SEAMS do
		local at, normal = PyreliskPath.seamPoint(state, index)
		place(entry.seams[index], onSurface(at, normal))
	end
	-- The maw seam is a MODULE like every other one, so it is seated like
	-- every other one. Placed by POSITION alone it kept the head's axes, and
	-- a module's outward normal is its own +Y - so the throat glow shone
	-- straight up out of the top of the skull instead of forward and down out
	-- of the mouth. MAW_OUT is the builder's own normal for it.
	place(entry.maw, onSurface((head * CFrame.new(MAW_AT)).Position, head:VectorToWorldSpace(MAW_OUT)))

	for index in PyreliskPath.VENTS do
		local at, normal = PyreliskPath.ventPoint(state, index)
		place(entry.vents[index], onSurface(at, normal))
		place(entry.ventGlow[index], onSurface(at + normal * 21, normal))
	end

	-- DAMAGE SHOWS. "By phase three it is visibly coming apart" (boss_gen's own
	-- note on the design; the scars themselves are DEAD now rather than orange -
	-- see THE THREE STATES) - and `Stance` and `Exposed` were being read into the
	-- state and consumed by nothing, which is exactly the trap the checklist
	-- names: an unfed rig looks like a rig at rest.
	--
	-- The lit gaps run hotter and wider as the stance count falls, and the
	-- punish window flares them, so a phase-three colossus is visibly burning
	-- through its own shell and an open window is readable from anywhere on
	-- the rim. That is the WHOLE-BODY layer, and it is unchanged: `heat`,
	-- `flare`, `glow` and `swell` are the same four numbers they always were.
	--
	-- HOW THE PER-SEAM LAYER USES THEM, and it is no longer "on top of, never
	-- instead of". `heat` and `flare` still feed a CLOSED seam - a
	-- phase-three shell burns hotter between attacks, which is the whole
	-- "visibly coming apart" read - but OPEN overrides them outright and
	-- BROKEN overrides them downward, to dead. That is the change this pass
	-- made: composing all three with a `max` against `glow` is what left the
	-- open state with nowhere to go and the broken state brighter than
	-- either. See THE THREE STATES.
	local heat = damageOf(entry, state.stance, target.stances)
	local flare = state.exposed * (0.6 + 0.4 * math.sin(state.time * 5.5))
	-- THE AMBIENT CRACK NETWORK, and its CEILING is the load-bearing part. This
	-- number now lights the lava between every plate on the body rather than a
	-- core glimpsed through gaps, so it is held BELOW EMBER (1.0 on the ramp):
	-- at EMBER and above the network is brighter than an open seam's own floor
	-- and the fight's one "shoot here" tell has nothing left above it. It is
	-- also the AgX trap in the renders - a bright emissive over that much area
	-- washes the whole body to peach (boss_gen's `_py_glow` carries the same
	-- lesson as an emission strength).
	local glow = math.clamp(0.06 + 0.45 * heat + 0.25 * flare, 0, 0.80)
	local swell = 1 + 0.30 * heat + 0.12 * flare

	-- The pulse is one shared phase off state.time, so every open seam beats
	-- together: seven lights blinking out of step read as noise, seven in
	-- unison read as a tell. Hoisted above the core because the core flares
	-- on the same beat.
	local pulse = 0.5 + 0.5 * math.sin(state.time * OPEN_PULSE_RATE)

	-- ANATOMY, not targets: the core, the maw and the three vent throats keep
	-- exactly the stance-driven behaviour they have always had. They have no
	-- seam index and no bit in the mask. (The core takes no size, as before -
	-- it is the body's inside, and swelling it pushes it through the shell.)
	--
	-- WITH ONE ADDITION: THE CORE FLARES WHILE ANYTHING IS OPEN. The whole
	-- body brightens from the inside for as long as there is a way into it,
	-- which is the cheapest possible answer to "how does a player who has
	-- never seen this fight know something just happened". It is diegetic -
	-- the furnace is showing through a crack that just opened - and it costs
	-- one lerp on one part.
	local coreFlare = if target.seamsOpen ~= 0 then OPEN_CORE + OPEN_CORE_PULSE * pulse else 0
	applyLook(entry.pieces.Core, glow + coreFlare)
	-- The bones' lava is the same body: one heat for the whole molten mass, so
	-- an arm never reads as a different creature from the trunk it hangs off.
	-- NO SCALE ARGUMENT - `makeTwin` set each twin's size once and `applyLook`
	-- would otherwise multiply the swell into it every frame.
	for _, side in { -1, 1 } do
		local set = entry.arms[side]
		applyLook(set.UpperArmMolten, glow + coreFlare)
		applyLook(set.ForearmMolten, glow + coreFlare)
		applyLook(set.HandMolten, glow + coreFlare)
	end
	applyLook(entry.maw, glow, swell)
	for _, seam in entry.ventGlow do
		applyLook(seam, glow, swell)
	end

	-- THE SEVEN SHELL SEAMS: closed, open, or broken, per seam, per frame.
	-- Precedence is BROKEN over OPEN over CLOSED - once a flank is down, its
	-- seams are scars and a later windup must not re-advertise them as
	-- something worth shooting. See THE THREE STATES for what each look is
	-- and why the three sit as far apart as they do.
	for index, seam in entry.seams do
		-- CLOSED: a cooling ember, well below the core's own heat, plus
		-- whatever the stance damage has burned back into it. `flare` (the
		-- punish window) rides along, so a downed boss's cracks brighten with
		-- the rest of the lit gaps.
		local intensity = CLOSED_GLOW + CLOSED_HEAT * heat + 0.35 * flare
		local scale = swell
		local open = false
		if bit32.btest(target.seamsBroken, SEAM_BIT[index]) then
			-- A DEAD SCAR. Not composed with the stance heat and deliberately
			-- not: a `max` against the shell's own glow would relight every
			-- scar as the boss burned through itself, and a vent that has
			-- been put out does not come back. Permanently a little wider
			-- than it was - the armour there stays broken open - and NOT
			-- pulsing, because a pulse is what says "shoot here now".
			intensity = BROKEN_GLOW
			scale = swell * BROKEN_SWELL
		elseif bit32.btest(target.seamsOpen, SEAM_BIT[index]) then
			-- The "shoot me" window: the crack splits hot and the armour
			-- visibly gapes. The flank's own meter pushes it further toward
			-- white as it fills, so a party reads "almost there" off the boss
			-- itself and needs no HUD for it. The chest (flank 0) belongs to
			-- neither meter and gets no such push.
			local flankSide = SEAM_FLANK[index]
			local meter = if flankSide > 0 then target.seamMeterL elseif flankSide < 0 then target.seamMeterR else 0
			intensity = OPEN_GLOW + OPEN_PULSE * pulse + OPEN_METER * meter
			scale = swell * (OPEN_SWELL + OPEN_SWELL_PULSE * pulse)
			open = true
		end
		applyLook(seam, intensity, scale)
		-- Gated on the property rather than written every frame: an emitter's
		-- Enabled is replicated state on a client-owned part, and setting it
		-- sixty times a second to the value it already holds is sixty
		-- property writes for nothing.
		local emitter = entry.embers[index]
		if emitter and emitter.Enabled ~= open then
			emitter.Enabled = open
		end
	end

	-- ACT 3's SEVEN USED TO BE DRAWN HERE, last, off `pulse` and `heat`. They
	-- are retired (2026-09-12, the climb-act removal directive) and the seams
	-- above are now the last thing this function draws.
end

-- ---------------------------------------------------------------- watching

-- Connected once per model. `watch` runs on every ChildAdded, and a model
-- re-parented back into the folder fires that again - without this it would
-- collect a second copy of both connections each time.
local watched = setmetatable({}, { __mode = "k" })

local function watch(child: Instance)
	if not child:IsA("Model") or watched[child] then
		return
	end
	watched[child] = true
	adoptBoss(child)
	child:GetAttributeChangedSignal("Pose"):Connect(function()
		-- BOTH directions. Adopting on the way in was here; nothing tore down
		-- on the way OUT, so a model that stopped being a pyrelisk kept its
		-- thirty parts drawn forever off a state nothing feeds - the
		-- checklist's "unfed rig looks like a rig at rest", with the whole
		-- body left behind rather than one attribute.
		if child:GetAttribute("Pose") == POSE_NAME then
			adoptBoss(child)
		else
			destroyBody(child)
		end
	end)
	child.AncestryChanged:Connect(function()
		if not child:IsDescendantOf(Workspace) then
			destroyBody(child)
		end
	end)
end

function PyreliskBodyController.init()
	task.spawn(function()
		checkStandIns()
		local folder = Workspace:WaitForChild(CREATURES_FOLDER, 30)
		if not folder then
			return
		end
		for _, child in folder:GetChildren() do
			watch(child)
		end
		folder.ChildAdded:Connect(watch)
		folder.ChildRemoved:Connect(function(child)
			-- Leaving the FOLDER is not the same as leaving the game. A model
			-- re-parented elsewhere in Workspace is still a live boss being
			-- drawn correctly, and tearing it down here destroyed the body
			-- with nothing left to re-adopt it: `watch` only ever runs on
			-- children of this folder. AncestryChanged, above, is the signal
			-- that actually knows the model has gone.
			if child:IsA("Model") and not child:IsDescendantOf(Workspace) then
				destroyBody(child)
			end
		end)
	end)
end

function PyreliskBodyController.start()
	RunService.RenderStepped:Connect(function(dt)
		for model, entry in bodies do
			if not model.Parent then
				destroyBody(model)
			else
				-- One body's bad frame must not take the connection down with
				-- it. An error thrown out of here kills RenderStepped for
				-- EVERY pyrelisk at once, and the fight goes on running
				-- around a colossus frozen mid-pose with nothing in the log
				-- to say why - so it is caught, said once, and retried.
				local ok, err = pcall(drawBody, model, entry, dt)
				if not ok and not entry.warned then
					entry.warned = true
					warn("[PyreliskBody] draw failed: " .. tostring(err))
				end
			end
		end
	end)
end

return PyreliskBodyController
