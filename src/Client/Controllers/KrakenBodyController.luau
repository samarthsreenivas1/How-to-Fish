--!nonstrict
-- KrakenBodyController.luau
-- Draws the Kraken: one 480-stud head standing out of the sea off a galleon's
-- port rail, TWO building-sized limbs reaching across the ship that is the
-- arena floor, and two more that only ever drape.
--
-- TWO FIGHT LIMBS, and it is a design ruling, not a budget: the phase machine
-- turns on breaking BOTH inside one cycle to open the siphon window, so
-- exactly two creature models carry ArmPhase and those two are the things you
-- hit. The other two limbs are DECORATION - client-only, attribute-less,
-- seated outboard, drawn from an idle curve, never crossing a rail. They are
-- here because an animal this size with two arms reads as amputated, and
-- nothing may ever hang a mechanic on them.
--
-- Same split as every other colossus. The server keeps AUTHORITY only - a
-- hidden model for hits and the HUD, plus the replicated numbers - and
-- everything you can see is built here from KrakenPath. No timers, no local
-- guesses about what the boss is doing.
--
-- WHAT THE SERVER PUBLISHES, and it is the whole of the contract this file
-- consumes:
--   on the BOSS model:   Rise (0..1), SiphonOpen (bool), PhaseIndex (1..3),
--                        PoseCenter (Vector3), Pose ("kraken")
--   on each ARM model:   ArmPhase in {Rest, Rear, Slam, SweepCock, Sweep,
--                        Wrapped, Down, Withdrawn}, ArmPhaseAt (the phase
--                        transition's timestamp), ArmT (0..1 within that
--                        phase), WrapIndex (1..4), TargetX / TargetZ (world),
--                        WeakpointHot (bool), WeakpointPos (Vector3),
--                        Weakpoint
-- Arms are ANCHORED CREATURES: each one is a thing you hit, its own model is
-- hidden, and a limb is drawn to it instead.
--
-- ...AND THE SAME ATTRIBUTES DRAW THE DECK HIGHLIGHT. While an arm is in a
-- WINDUP phase this file paints a glowing mark on the planking at what the blow
-- is aimed at - a disc for a pile slam, a strip down the lane for a scythe, a
-- ring on the bulwark for a wrench - which brightens and tightens as ArmT runs
-- out and is destroyed the moment the phase stops being a windup. It is built
-- from the replicated attributes and nothing else, it is ADDITIVE to the
-- telegraph pulses CreatureEventController already draws off the server's
-- events, and it is the answer to "you cannot tell what it is about to do".
-- See MARK.
--
-- PoseCenter IS THE SHIP, not the head. CreatureService seeds the pose from
-- the creature's anchor - the BossArenas row's centre, which arena_gen puts
-- the hull on - so the head is derived from it by KrakenPath.HEAD_OFFSET and
-- nothing here reads PoseCenter as a head position. It is also RE-PUBLISHED
-- mid-fight (the swallow moves it), so it is read every frame and never
-- cached.
--
-- ============================================================ THE CUTSCENE
-- CONTRACT (shared surface - the same names on all seven bosses; other lanes
-- build against these, so nothing here may be renamed):
--
--   KrakenBodyController.setCutscene(fn: ((frame) -> ())?)
--       While set, the per-frame update still reads every attribute and
--       computes the NORMAL pose into a mutable `frame`, calls fn(frame),
--       and then writes the rig from whatever `frame` contains. nil restores
--       normal. Safe to call before the boss model exists and safe across a
--       rig rebuild mid-cutscene: the hook is module state, not rig state.
--
--   frame.t            seconds since setCutscene, on the shared server clock
--   frame.visible      bool, the whole rig
--   frame.head         { position, yaw, rise, gape, roar }
--   frame.tentacles[i] { bearing, radius, rise, curl, tip }
--   frame.ink          0..1
--
--   KrakenBodyController.landmark(name) -> Vector3?
--       "head", "eye", "centre", "siphon", "maw" (alias of siphon),
--       "tentacle1".."tentacleN". nil until the rig exists.
--
--   KrakenBodyController.splash(position, size)
--       Delegates to Vfx.splash - the existing surface burst.
--
-- HOW THE MAPPING WORKS on an animal with NO MOUTH (boss_gen deleted the
-- beak and the maw; the SIPHON is the door now):
--   gape  - the SIPHON. Drives Kraken_SiphonCore's Neon intensity (colour
--           lerped toward white, plus its PointLight) AND flares the funnel:
--           Kraken_Siphon is pushed up to SIPHON_FLARE_PUSH authored units
--           along the head's facing and widened by SIPHON_FLARE_GIRTH. In the
--           fight, gape's default value IS the eased SiphonOpen bool, so the
--           cutscene and the fight drive one channel.
--   roar  - the full face surge: BOTH amber eyes hard-bright, the siphon core
--           spiked with them, and Kraken_Lashes / Kraken_Eyespots lifted as
--           accent (cheap - a colour write on two parts already placed).
--   ink   - the baseline of that same eye/siphon glow channel; 1.0 is the
--           fight's normal ambient pulse and 0 puts the animal's lights out.
--   NEVER the star pupils. Kraken_Pupil is matte cream on Neon amber and the
--   star staying steady is what reads as a pupil - the no-pulse law holds in
--   cutscenes exactly as it holds in the fight, and it is enforced by NEON
--   being a closed literal list rather than by anyone remembering.
--
-- WHY THE HANDOFF AT rise = 1 IS EXACT: there is ONE code path. The frame is
-- built and consumed every frame whether or not a cutscene is set - the hook
-- is a single `if cutscene then cutscene(frame) end` between building it and
-- writing it, with no second branch that computes the pose a different way.
-- The head is written through KrakenPath.headFrameAt(position, rise, yaw),
-- the same call on the same three numbers the fight puts there; a limb whose
-- polar fields come back BIT-UNCHANGED (compared against the exact values
-- written, not against a tolerance) keeps its computed curve untouched, and
-- only a mutated limb pays for a polar round-trip. So an unmutated frame is
-- not "close to" the live fight - it is the same arithmetic.
--
-- Pieces come from ReplicatedStorage/Assets/KrakenPack (assets/boss_gen.py)
-- and fall back to tinted primitives measured off the authored bboxes, so the
-- fight is never invisible and never unreadable before the import lands.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChainPose = require(Shared.Modules.ChainPose)
local MeshColors = require(Shared.Config.MeshColors)
local BossArenas = require(Shared.Config.BossArenas)
local KrakenPath = require(Shared.Modules.KrakenPath)
local Vfx = require(script.Parent.Parent.Modules.Vfx)

local KrakenBodyController = {}

local CREATURES_FOLDER = "Creatures"
-- THE ADOPTION SIGNAL, named once. Every body in this file exists because the
-- server wrote this exact string into the boss model's `Pose` attribute, so the
-- literal is worth a name: the guard that reads it and the warn that reports it
-- missing can then never disagree about what was being looked for.
local POSE_NAME = "kraken"
local PACK_NAME = "KrakenPack"
-- WHAT THE PACK IS ACTUALLY CALLED IN A PLACE FILE. The canonical name is
-- `KrakenPack`, but Studio's glTF importer names the container after the FILE -
-- `boss_kraken` - and that one mismatch is INDISTINGUISHABLE from "the pack was
-- never imported": both give a silent nil out of packPiece and the whole animal
-- falls back to primitives. Both obvious aliases are accepted and the owner is
-- told the canonical name once, so the fight is never silently wrong about what
-- it is drawing.
local PACK_ALIASES = { PACK_NAME, "boss_kraken", "Kraken" }
local FOLDER_NAME = "KrakenBody"
-- The BossArenas row the ship is placed on. "maelstrom", NOT "kraken":
-- BossArenas keys rows by ISLAND id everywhere (tropical/swamp/ice/...), and
-- the server slice followed that convention. This string was the third seam
-- bug between the two halves of the fight - the client looked up a row that
-- would never exist and the arena-aware camera silently stayed off.
local ARENA_ID = "maelstrom"
-- WHICH CREATURE IS AN ARM. `kraken_arm` is the landed row; `kraken_tentacle`
-- is the retired eight-arm fight's id, kept only so a stale place file draws
-- something rather than nothing. Harmless: the server never plants one.
local ARM_IDS = { kraken_arm = true, kraken_tentacle = true }
-- ...and the gullet's destructible growths, which are not limbs at all -
-- they are six nodes on stalks in a different arena, and all this controller
-- owes them is the Neon their weakpoint asks for.
local POLYP_ID = "kraken_polyp"

local SCALE = KrakenPath.SCALE
local SPACING = KrakenPath.SPACING

-- The taper. Girth thins hard toward the tip; LENGTH barely does, and that
-- asymmetry is the weld law: a segment shortened as hard as it is thinned
-- loses its parallel section and the chain turns into beads. At TIP_LENGTH
-- 0.14 the shortest parallel run is 9.6 * 0.86 = 8.26 authored units against
-- a 6.0 pitch - 13.5 studs of slack, asserted at adopt by KrakenPath.weldSlack.
local TIP_GIRTH = KrakenPath.TIP_GIRTH
local TIP_LENGTH = 0.14

-- THE SUCKER ROWS, and they are not decoration: boss_gen's HANDOFF says in as
-- many words that "the rows are the silhouette read, so a limb that loses
-- them stops being a tentacle". TWO rows, one pair per segment, at 24 degrees
-- either side of straight down, exactly as the pack was authored.
local SUCKER_ANGLE = math.rad(24)
local SUCKER_EVERY = 1
local SUCKER_UNTIL = 0.93 -- stop before the tip goes thin
local SUCKER_SEAT = 0.46 -- as a fraction of the segment's girth: rim IN the hide
-- Turns the authored +X disc so it faces out of the limb's underside instead
-- of lying flat along it - the bug that hid the rows in the generator.
local SUCKER_TURN = CFrame.Angles(0, 0, -math.pi / 2)

-- THE WEAKPOINT KNUCKLE. `WeakpointHot` brightens a RUN of suckers near the
-- pose's own bend, which is the only place a knuckle can honestly be: on a
-- wrapped limb it is the coil, on a downed one the middle of the span. Three
-- pairs, because one pair is a speck at 60 studs and five is the whole limb.
local WEAK_RUN = 3
local WEAK_AT = {
	Wrapped = 0.82,
	Down = 0.55,
	Slam = 0.88,
	Sweep = 0.86,
	SweepCock = 0.86,
	Rear = 0.80,
	-- THE SIX NEW POSES (the new-attacks pass, 2026-09-12). Every number here is
	-- "where does this pose actually bend", which is the only place a knuckle can
	-- honestly be - and four of these six are the poses the new OPENINGS happen
	-- in, so this table is load-bearing for them in a way it is not for a windup.
	--
	--   Stuck 0.92 - the tip is IN the planking, so the joint a player can reach
	--     is the last thing above it. The highest value in the table on purpose.
	--   Spear 0.90 - the jab's own bend, same place, one notch back.
	--   Drape 0.58 - THE FOREARM OVER THE BULWARK, which is the whole reward of
	--     the volley's and the scythe's new openings: not the tip hanging in the
	--     sea outboard (that is past 0.8 and unreachable from the deck) but the
	--     crest lying on the rail, which is at about 0.6 of the drawn limb.
	--   Coil 0.50 - fully submerged; nothing can hit it, and this is only ever a
	--     fallback for a server that lit it anyway.
	--   Erupt 0.78 - the column's shoulder, below the crest.
	--
	-- `WeakpointPos` still wins wherever the server publishes it (see drawBody);
	-- these are the per-pose guess at the same thing.
	Stuck = 0.92,
	Spear = 0.90,
	Drape = 0.58,
	Coil = 0.50,
	Erupt = 0.78,
}
local WEAK_AT_DEFAULT = 0.72
local WEAK_COLOR = Color3.fromRGB(255, 196, 96)

-- ------------------------------------------------- THE DECK HIGHLIGHT
--
-- WHAT THE KRAKEN IS ABOUT TO HIT, PAINTED ON THE PLANKING YOU ARE STANDING ON
-- (owner, 2026-09-12). The fight already fires telegraphs - CreatureEventController
-- draws the slam's ring pulse and the scythe's lane pulse off the server's own
-- `telegraph` / `sweepLane` events - and those stay exactly as they are. This is
-- ADDITIVE and it is a different kind of thing: a PERSISTENT glowing mark that
-- is up for the whole windup and tightens as the blow gets closer, where the
-- event pulses are momentary rings that have to be re-fired to stay visible.
-- Between the two you can tell at a glance both THAT something is coming and HOW
-- LONG YOU HAVE.
--
-- BUILT FROM REPLICATED ATTRIBUTES ONLY, which is the constraint that makes it
-- trustworthy: ArmPhase says which windup is running, ArmT says how far through
-- it is, TargetX/TargetZ say where, WrapIndex says which rail. Nothing here
-- listens to an event, keeps a timer, or guesses - so the mark cannot outlive
-- the attack, cannot drift off it, and cannot appear for an attack that was
-- cancelled. The lane is the one exception and it is not a guess either: the
-- sweep's exact lane arrives in KrakenPath's LANE mailbox (written by
-- CreatureEventController off the server's own `sweepLane` payload) and the mark
-- prefers it over the mirror, for the same reason the limb does.
--
-- NOT NEON ON THE ANIMAL. The no-new-always-on-Neon rule (see NEON_PIECES, and
-- Kraken_Pupil's exclusion) is about the BODY: these marks are separate parts
-- parented to the rig folder, created when a windup starts and DESTROYED the
-- frame the phase stops being a windup. Nothing on the Kraken gains a material.
local MARK = {
	-- WHICH PHASES ARE A WINDUP, and what each one paints. This table IS the
	-- lifetime rule: a phase not in it has no mark, so Slam, Sweep, Down, Rest
	-- and Withdrawn clear it by simply not being here.
	--
	-- `Wrapped` is in it with a caveat worth stating, because the contract cannot
	-- resolve it: the wrench uses the SAME ArmPhase for its windup and for its
	-- four-second haul (CreatureService's krakenwrench sets Wrapped in both its
	-- `windup` and its `fire`), and no published attribute distinguishes the two.
	-- So the wrap mark is drawn for both, which is honest - the wrap point is
	-- where the danger is in either half - and WeakpointHot is what actually
	-- says "the haul has started, burn it now".
	--
	-- TWO NEW KINDS FOR THE TWO NEW WINDUPS (the new-attacks pass, 2026-09-12),
	-- and no new mechanism for either - the same one part per arm, rebuilt when
	-- the kind changes and destroyed when the phase stops being a windup.
	--
	--   SpearCock -> "spear". The grating spear re-enters this phase three times,
	--     once per mark, with a FRESH TargetX/TargetZ each time, so the one mark
	--     walks down the deck in three steps - which is exactly the "three discs
	--     lighting up in sequence" the move is supposed to read as. The other two
	--     discs of the sequence are the server's own `telegraph` events, fired up
	--     front with staggered durations, so all three are on screen at once and
	--     this one says WHICH is next. Small, because the stab's radius is small:
	--     a disc sized like a slam's would lie about a move you can side-step.
	--   Coil -> "wake". THE ONE MARK NOT DRAWN ON THE PLANKING. The limb is under
	--     the sea for the whole windup and what is tracking you is under it, so
	--     the mark goes on the WATER at the arm's published station - the only
	--     information the attack gives you, and it has to be where the water is
	--     or it is a mark on a deck with nothing under it.
	--
	-- Drape, Stuck, Spear and Erupt are deliberately ABSENT, which is this table's
	-- lifetime rule doing its job: Spear and Erupt are the blow, and Drape and
	-- Stuck are the OPENING - painting a warning on the deck during the seconds a
	-- player is meant to be shooting the limb would be telling them to run away
	-- from their own reward.
	PHASE = { Rear = "disc", SweepCock = "lane", Wrapped = "wrap", SpearCock = "spear", Coil = "wake" },
	-- Bosses.items.kraken.attacks.pileslam.tellRadius and .deckscythe.lane,
	-- written here rather than required: this controller has no reason to pull in
	-- the whole boss book for two numbers, and a client that disagreed with the
	-- server about a telegraph's size would be worse than one that states its
	-- source. If either row moves, these move with it.
	SLAM_R = 22.0,
	LANE_HALF = 20.0,
	-- The wrench has no radius of its own - its hazard is rolling cargo, not a
	-- disc - so the wrap mark is sized to read as a HANDHOLD on the rail rather
	-- than as a footprint to stand out of.
	WRAP_R = 13.0,
	-- Bosses.items.kraken.attacks.gratingspear.tellRadius, same rule as SLAM_R:
	-- written here rather than required, and it moves if the row moves. A stab is
	-- a 7-stud hit inside an 11-stud tell - the tightest pair in the book, because
	-- the whole counterplay is a side-step rather than a run.
	SPEAR_R = 11.0,
	-- The maelstrom coil's wake ring, on the WATER. Wide, and wider than the
	-- eruption's own radius (18) on purpose: this mark is not saying "you will be
	-- hit here", it is saying "the thing is under you NOW", and it is up for three
	-- seconds while the arm tracks. The squeeze (CONTRACT, below) is what turns it
	-- into the warning at the end.
	WAKE_R = 26.0,
	-- Clear of the planking and no more. Any higher and the mark floats over the
	-- deck it is supposed to be painted on; any lower and it z-fights the authored
	-- hull mesh.
	LIFT = 0.35,
	THICK = 0.5,
	-- The pulse QUICKENS as the blow closes: 0.62s between beats at ArmT 0 down
	-- to 0.24s at ArmT 1. A constant pulse says "something is happening here"; an
	-- accelerating one says "now".
	PERIOD_SLOW = 0.62,
	PERIOD_FAST = 0.24,
	-- Transparency at the pulse's midpoint, at ArmT 0 and at ArmT 1, plus how far
	-- either side of it the beat swings. So the mark BRIGHTENS across the windup
	-- and pulses harder about a brighter centre.
	FADE_OPEN = 0.76,
	FADE_CLOSE = 0.34,
	PULSE = 0.18,
	-- ...and CONTRACTS. 14% off the radius by impact, which is a squeeze you can
	-- see without ever making the mark smaller than the thing it is warning about
	-- (the damage radius is 14 against a 22 tell, so even the closed mark is
	-- outside the actual hit).
	CONTRACT = 0.14,
	-- The animal's own light, off the generated palette rather than picked: the
	-- siphon core's teal is the colour the Kraken already glows, so a mark on the
	-- deck reads as something the Kraken put there. Falls back to the telegraph
	-- language's own kraken skin (CreatureEventController K.SKIN.kraken) if the
	-- MeshColors row ever goes missing.
	COLOR_ROW = "Kraken_SiphonCore",
	COLOR_FALLBACK = Color3.fromRGB(120, 235, 210),
}

-- How far past the head anything is worth drawing. The head is 480 studs
-- tall, so this is generous on purpose - a colossus that pops in as you sail
-- up to it is worse than one drawn a little too long.
local DRAW_RANGE = 9000

-- PHASE 3 IS A DIFFERENT PLACE. The gullet (`KrakenGullet_*`) is its own
-- arena, teleported into, with its own origin and its own floor datum; the
-- head and the limbs do not exist in there. Gated on the published
-- PhaseIndex, with the distance gate above as the backstop for a client that
-- arrives mid-phase before the attribute replicates.
local GULLET_PHASE = 3

-- Eased toward the published attributes. Rise is slow (it is a 480-stud
-- animal standing up); the siphon door is quick, because it opens onto a
-- swallow and a door that lags the mechanic is a door that lies.
local EASE = { rise = 1.6, siphon = 5.0 }

-- The glow channel. A Neon part has no brightness dial, so intensity is a
-- colour lerp toward white plus a PointLight that carries the bloom into the
-- water around it.
local GLOW_TOWARD = Color3.new(1, 1, 1)
local GLOW_LIFT = 0.55 -- how far toward white a full-intensity orb goes
local GLOW_LIGHT_RANGE = 420
local GLOW_LIGHT_BRIGHT = 6

-- The siphon's flare, in authored units and as a girth multiplier.
local SIPHON_FLARE_PUSH = 5.0
local SIPHON_FLARE_GIRTH = 0.16

-- How the cutscene's `rise` maps to a limb tip's height: 0 at the waterline,
-- 1 at the reared apex over the deck.
local TENTACLE_RISE_SPAN = KrakenPath.REAR_LIFT + KrakenPath.SHIP.DECK_Y

-- ---------------------------------------------------------------- the pack
--
-- ELEVEN pieces make the head. The interior kit (RibArch / Polyp / GutStrand)
-- is in the tables below but is NOT drawn here - boss_gen's HANDOFF is
-- explicit that it is "instanced by the arena, not by the body" - so the
-- gullet's own props keep their fallbacks and their colours without this
-- controller ever placing one.
local HEAD_PIECES = {
	"Head",
	"Cap",
	"Scrollwork",
	"Crust",
	"Eyes",
	"Pupil",
	"Lashes",
	"Barnacles",
	"Eyespots",
	"Siphon",
	"SiphonCore",
}

-- WHICH PIECES GLOW, asserted here rather than left to the import - an import
-- step is the only failure mode with nowhere in the system to check it, and
-- boss_gen's HANDOFF warns that "the boss path has no Neon-by-name rule of
-- its own".
--
-- A LITERAL list, deliberately, not a `Glow` substring rule. The Kraken's
-- list is short, closed, and has an EXCLUSION a broad rule would eventually
-- swallow: Kraken_Pupil is a four-point star of matte cream sitting ON the
-- Neon amber orb, and it is the only reason the eye reads as an eye rather
-- than a lamp. Naming the two that glow states that in a form that cannot
-- drift.
local NEON_PIECES = { Eyes = true, SiphonCore = true }

-- Rough bulk of each authored piece, at scale 1, MEASURED off the exported
-- meshes (blender bbox sweep over build_kraken, 2026-09-09) rather than read
-- off the builder's intent. Author axes are (forward, across, up) and the
-- pack convention is (+X forward, +Y up, +Z across), so each row is
-- (author x, author z, author y).
local FALLBACK_SIZE = {
	Head = Vector3.new(97.7, 103.2, 103.0),
	Cap = Vector3.new(100.1, 60.0, 94.9),
	Scrollwork = Vector3.new(53.6, 18.3, 64.1),
	Crust = Vector3.new(59.3, 43.5, 75.3),
	Eyes = Vector3.new(24.9, 25.0, 57.0),
	Pupil = Vector3.new(8.8, 16.8, 58.2),
	Lashes = Vector3.new(16.2, 13.0, 65.9),
	Barnacles = Vector3.new(72.0, 55.8, 100.2),
	Eyespots = Vector3.new(96.9, 74.3, 95.2),
	Siphon = Vector3.new(21.9, 25.2, 26.4),
	SiphonCore = Vector3.new(7.3, 9.7, 10.8),
	TentacleSeg = Vector3.new(12.0, 8.0, 8.0),
	TentacleTip = Vector3.new(36.0, 7.8, 7.8),
	TentacleSucker = Vector3.new(1.4, 6.2, 6.4),
	-- The interior kit: sized for the arena's benefit, not drawn here.
	RibArch = Vector3.new(4.5, 30.8, 39.2),
	Polyp = Vector3.new(6.9, 10.8, 6.8),
	GutStrand = Vector3.new(24.0, 5.2, 2.2),
}

-- WHY THE STAND-IN HEAD NEEDS THIS, and it is the shape the owner actually saw
-- when the pack was missing: A SINGLE FEATURELESS SPHERE.
--
-- FALLBACK_SIZE is the measured BBOX of each authored object, which is the
-- right number for a mesh and the wrong one for a solid primitive standing in
-- for it. The Head's bbox is the whole mantle (97.7 x 103.2 x 103.0), so a Ball
-- at that size has a ~51-unit radius about its own centre (0, 28.4, 0) - and
-- every one of FALLBACK_AT's measured piece centres is INSIDE that radius:
-- Cap 21.6, Eyespots 11.5, Barnacles 21.7, Crust 26.7, Eyes 40.6, Scrollwork
-- 46.2, Siphon 48.4, Pupil 50.4, Lashes 50.3. Only SiphonCore (55.2) clears it,
-- and it is 7 units across. So the offsets above were correct and still not
-- enough: eleven pieces placed exactly where they belong, ten of them sealed
-- inside the eleventh, drawn at SCALE 6.0 as one ~600-stud ball.
--
-- THE SAME FAULT IN A SECOND FORM, for four of the others: their bbox is the
-- SPREAD of a scatter of small instanced details over the mantle, not the bulk
-- of one mass (boss_gen: Barnacles is "%d cobalt clusters", Eyespots "the teal
-- studs AND each cluster's glint", Lashes "%d dark-teal spikes on each upper
-- rim", Scrollwork "%d teal crown curls"). Eyespots' bbox (96.9 x 74.3 x 95.2)
-- is very nearly the head itself - a solid box at that size is a second head
-- drawn over the first.
--
-- So the stand-in keeps the measured CENTRES and shrinks the five pieces whose
-- bbox is not a mass, to the point where the face, the crown and the funnel all
-- stand clear of the mantle. These are SILHOUETTE numbers and the only thing
-- they are claimed to be: an honest eleven-piece read of the animal before the
-- import lands. Applied in makePiece on the FALLBACK branch only, before
-- BaseSize is captured, so a real imported piece is never resized.
local FALLBACK_INSET = {
	Head = 0.58, -- radius ~29.9: inside every piece centre above
	Barnacles = 0.34,
	Eyespots = 0.30,
	Scrollwork = 0.55,
	Lashes = 0.50,
}

-- WHERE EACH STAND-IN HEAD PIECE SITS, in the head's own frame at scale 1,
-- applied ONLY to parts that came out of makePiece's fallback branch.
--
-- The eleven head pieces all ride ONE headFrame, which is correct for the
-- imported pack - every piece is modelled in place around the mantle, and
-- offsetting them would take the animal apart. It is wrong for the stand-ins,
-- which are eleven centred primitives: with no offsets they all sit on one
-- point, and the fallback head is a featureless ball with the face buried
-- inside it, centred on the WATERLINE rather than on the mass.
--
-- Every number is the measured bbox CENTRE from the same sweep as
-- FALLBACK_SIZE, so the stand-in is the authored silhouette in eleven boxes
-- rather than a guess at one. Spot-check against boss_gen's own HANDOFF
-- text: the eyes land at forward 36.6 / up 46.0 against its stated (36.5,
-- +/-16.3, 46.0), and the siphon at 48.4 / 26.3 against a funnel running
-- (43.2, 27.0) to (56.9, 20.3).
local FALLBACK_AT = {
	Head = CFrame.new(0, 28.4, 0),
	Cap = CFrame.new(-0.4, 50.0, 0),
	Scrollwork = CFrame.new(1.2, 74.6, 0),
	Crust = CFrame.new(-15.6, 7.8, 6.9),
	Eyes = CFrame.new(36.6, 46.0, 0),
	Pupil = CFrame.new(47.2, 46.0, 0),
	Lashes = CFrame.new(38.7, 60.5, 0),
	Barnacles = CFrame.new(-3.2, 49.9, -0.2),
	Eyespots = CFrame.new(-0.9, 39.9, -0.8),
	Siphon = CFrame.new(48.4, 26.3, 0),
	SiphonCore = CFrame.new(54.8, 21.4, 0),
}

-- The landmarks other lanes ask for, in the head's own frame at scale 1.
-- "eye" is the orb seat and "siphon" the funnel's MOUTH (56.9, 20.3), not its
-- centre - a camera flying into the door wants the lip.
local LANDMARK_AT = {
	head = Vector3.new(0, 28.4, 0),
	centre = Vector3.new(0, 28.4, 0),
	eye = Vector3.new(36.6, 46.0, 16.3),
	siphon = Vector3.new(56.9, 20.3, 0),
	maw = Vector3.new(56.9, 20.3, 0),
}

-- Set by makePiece on the fallback branch ONLY, and read when the head is
-- placed. An attribute on the PART rather than a flag beside the table,
-- because the pack can land piece by piece: a half-imported KrakenPack gives
-- real geometry for some of the eleven and stand-ins for the others, and only
-- the stand-ins may be offset.
local FALLBACK_TAG = "KrakenStandIn"

-- The pieces that read better as a round primitive than a brick.
local FALLBACK_SHAPE = {
	Head = Enum.PartType.Ball,
	Cap = Enum.PartType.Ball,
	Eyes = Enum.PartType.Ball,
	SiphonCore = Enum.PartType.Ball,
	Polyp = Enum.PartType.Ball,
	-- A Roblox cylinder's axis IS +X: the pack convention, so these need no
	-- turning to lie along the limb.
	TentacleSeg = Enum.PartType.Cylinder,
	TentacleTip = Enum.PartType.Cylinder,
	TentacleSucker = Enum.PartType.Cylinder,
	Siphon = Enum.PartType.Cylinder,
}

-- model -> the live body
local bodies = {}

-- The cutscene hook. MODULE state, not rig state, so it survives a rig that
-- has not been built yet and a rig rebuilt underneath it - both of which the
-- cutscene lane says happen (it is armed on the summon remote, and the boss
-- creature replicates a beat later).
local cutscene: ((any) -> ())? = nil
local cutsceneAt = 0

-- EVENT-DRIVEN FLARES, held here rather than on a body, because the events
-- that raise them (`eyeLock`, `inkFlare`) arrive on the CreatureEvent channel
-- and know nothing about which model is the boss. They decay on their own
-- clock and simply RAISE the ambient glow - never replace it - so a flare that
-- ends leaves the animal breathing rather than dark.
local eyeFlareUntil = 0
local eyeFlareFor = 1
local siphonFlareUntil = 0
local siphonFlareFor = 1
local siphonFlareCharge = 1

-- 0..1, one minus the fraction of the window elapsed, eased so the flare falls
-- off rather than switching off.
local function flareLevel(until_: number, span: number, now: number): number
	if now >= until_ or span <= 1e-3 then
		return 0
	end
	local left = math.clamp((until_ - now) / span, 0, 1)
	return left * left * (3 - 2 * left)
end

-- ---------------------------------------------------------------- pieces

-- EVERY OBJECT THE PACK IS AUTHORED WITH, from boss_gen.py's own closing line:
-- "the full inventory is now exactly: ... (17 objects)". Held here so a partial
-- import can be NAMED rather than left to present as a stand-in nobody knows
-- they are looking at.
local PACK_PIECES = {
	"Head",
	"Cap",
	"Scrollwork",
	"Crust",
	"Eyes",
	"Pupil",
	"Lashes",
	"Barnacles",
	"Eyespots",
	"Siphon",
	"SiphonCore",
	"TentacleSeg",
	"TentacleTip",
	"TentacleSucker",
	"RibArch",
	"Polyp",
	"GutStrand",
}

-- The four objects the PRE-REWORK pack carried and this one deliberately does
-- not (boss_gen: "GONE: Kraken_Beak, Kraken_Maw, Kraken_CrownSpikes,
-- Kraken_TentacleHook"). Finding any of them is PROOF the import is the old pack
-- rather than a current pack that lost pieces - a different instruction to the
-- owner, so it is a different warn.
local RETIRED_PIECES = { "Beak", "Maw", "CrownSpikes", "TentacleHook" }

local pack: Instance? = nil
local packWarned = false
local packAudited = false

-- Find the pack under whatever name it was imported as. Re-resolved until it is
-- found (Assets can stream in after the first body adopts) and re-resolved if
-- the folder it found is reparented out from under it.
local function resolvePack(): Instance?
	if pack and pack.Parent then
		return pack
	end
	pack = nil
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if not assets then
		return nil
	end
	for _, alias in PACK_ALIASES do
		local found = assets:FindFirstChild(alias)
		if found then
			pack = found
			if alias ~= PACK_NAME and not packWarned then
				packWarned = true
				warn(
					string.format(
						"[KrakenBody] found the boss pack as ReplicatedStorage.Assets.%s - drawing from it,"
							.. " but RENAME IT TO %q (Studio's importer names the container after the file,"
							.. " assets/boss_kraken.glb). Every other pack in the game is named this way and"
							.. " the alias is a courtesy, not the contract.",
						alias,
						PACK_NAME
					)
				)
			end
			return pack
		end
	end
	return nil
end

-- ONE WARN PER FAILURE MODE, run once at the first rig build. Without this the
-- three import states - no pack, the old pack, a half-imported pack - are all
-- the same silent nil out of packPiece, and all three present as a stand-in the
-- owner has no way to recognise as a stand-in.
local function auditPack()
	if packAudited then
		return
	end
	packAudited = true
	local found = resolvePack()
	if not found then
		warn(
			string.format(
				"[KrakenBody] no boss pack at ReplicatedStorage.Assets.%s (nor %q / %q)."
					.. " THE WHOLE KRAKEN IS A PRIMITIVE STAND-IN: an eleven-box head and four"
					.. " cylinder limbs, coloured from MeshColors but not the authored animal."
					.. " Import it once: Studio > Home > Import > assets/boss_kraken.glb, move"
					.. " the imported model into ReplicatedStorage/Assets and name it %q.",
				PACK_NAME,
				PACK_ALIASES[2],
				PACK_ALIASES[3],
				PACK_NAME
			)
		)
		return
	end
	local missing = {}
	for _, name in PACK_PIECES do
		local piece = found:FindFirstChild("Kraken_" .. name, true)
		if not (piece and piece:IsA("BasePart")) then
			table.insert(missing, "Kraken_" .. name)
		end
	end
	local retired = {}
	for _, name in RETIRED_PIECES do
		if found:FindFirstChild("Kraken_" .. name, true) then
			table.insert(retired, "Kraken_" .. name)
		end
	end
	if #retired > 0 then
		warn(
			string.format(
				"[KrakenBody] ReplicatedStorage.Assets.%s IS THE OLD PRE-REWORK PACK - it still"
					.. " contains %s, which boss_gen.py deleted. The %d piece(s) this fight needs and"
					.. " cannot find are drawn as primitives: %s. REIMPORT assets/boss_kraken.glb"
					.. " (delete the old container first - a merge leaves both generations in it).",
				found.Name,
				table.concat(retired, ", "),
				#missing,
				if #missing > 0 then table.concat(missing, ", ") else "(none)"
			)
		)
	elseif #missing > 0 then
		warn(
			string.format(
				"[KrakenBody] ReplicatedStorage.Assets.%s is missing %d of the pack's 17 objects,"
					.. " each drawn as a primitive stand-in instead: %s."
					.. " Reimport assets/boss_kraken.glb - a part-by-part import drops objects silently.",
				found.Name,
				#missing,
				table.concat(missing, ", ")
			)
		)
	end
end

local function packPiece(name: string): BasePart?
	local found = resolvePack()
	local piece = found and found:FindFirstChild("Kraken_" .. name, true)
	return if piece and piece:IsA("BasePart") then piece else nil
end

-- Named colours that were looked for and not found. A grey stand-in is the one
-- failure in this file with no shape of its own - it looks exactly like a piece
-- that imported flat - so the miss says its own name rather than leaving someone
-- to guess whether MeshColors or the import is at fault.
local colourWarned = {}

local function makePiece(name: string, parent: Instance): BasePart
	local template = packPiece(name)
	local part
	if template then
		part = template:Clone()
		-- STRIP SurfaceAppearance from the clone. A PBR appearance overrides
		-- part.Color outright and renders importer-default grey, so a pack that
		-- imported WITH one draws exactly like a pack whose MeshColors row is
		-- missing - and the colour assert below cannot see it, because Color is
		-- set and simply ignored. Wrack and Brinejaw both strip it; this was the
		-- one body controller that did not (found by the cutscene lane's audit).
		for _, child in part:GetDescendants() do
			if child:IsA("SurfaceAppearance") then
				child:Destroy()
			end
		end
	else
		part = Instance.new("Part")
		-- The inset is applied HERE, before applyPiece captures BaseSize, and on
		-- this branch only: see FALLBACK_INSET for why a full-bbox primitive is
		-- one featureless ball.
		local size = FALLBACK_SIZE[name] or Vector3.new(4, 4, 4)
		part.Size = size * (FALLBACK_INSET[name] or 1)
		part.Material = Enum.Material.SmoothPlastic
		local shape = FALLBACK_SHAPE[name]
		if shape then
			part.Shape = shape
		end
		part:SetAttribute(FALLBACK_TAG, true)
	end
	-- COLOUR AND MATERIAL, asserted for BOTH branches. Studio's glTF importer
	-- carries no colour at all - every imported part arrives Roblox-default
	-- grey - so without this the animal imports grey and the pack landing
	-- makes the fight look WORSE than the blocks it replaced. MeshColors is
	-- generated from boss_gen.py by tools/gen_mesh_colors.py, so it cannot
	-- drift from the builder.
	--
	-- Keyed off the name we are ABOUT to assign, never off part.Name: on the
	-- fallback path that is still "Part" here, so every stand-in would
	-- silently miss its colour.
	local partName = "Kraken_" .. name
	local colour = MeshColors.get(partName)
	if colour then
		part.Color = colour
		part:SetAttribute("BaseColor", colour)
	elseif not colourWarned[partName] then
		-- SELF-DIAGNOSING, because the symptom has no shape: the piece is drawn
		-- in the importer's default grey and nothing else about it is wrong.
		colourWarned[partName] = true
		warn(
			string.format(
				"[KrakenBody] no MeshColors row for %q - that piece draws in the importer's"
					.. " default grey. MeshColors is generated: re-run tools/gen_mesh_colors.py."
					.. " If the row exists under a %q-style name, the pack object is"
					.. " multi-material and Studio split it on import (see that generator's"
					.. " <Name>N note).",
				partName,
				partName .. "2"
			)
		)
	end
	-- After the branch, for the same reason: the SmoothPlastic write lives in
	-- the fallback arm, so asserting in there would light the stand-in and
	-- leave the real imported piece flat - the exact inverse of the intent.
	if NEON_PIECES[name] then
		part.Material = Enum.Material.Neon
	end
	part.Name = partName
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.Parent = parent
	return part
end

-- Place one piece. Length and girth scale separately so a limb can thin
-- toward the tip without its segments pulling apart (see TIP_LENGTH).
local function applyPiece(part: BasePart, cframe: CFrame, lengthScale: number, girthScale: number)
	local base = part:GetAttribute("BaseSize")
	if not base then
		base = part.Size
		part:SetAttribute("BaseSize", base)
	end
	part.CFrame = cframe
	part.Size = Vector3.new(base.X * lengthScale, base.Y * girthScale, base.Z * girthScale)
end

local function park(part: BasePart)
	part.CFrame = CFrame.new(0, -8000, 0)
end

-- The glow channel, for the two Neon pieces and for the accent writes `roar`
-- makes on the lashes and the eyespots.
local function setGlow(part: BasePart, level: number)
	local base = part:GetAttribute("BaseColor") or part.Color
	part.Color = base:Lerp(GLOW_TOWARD, GLOW_LIFT * math.clamp(level, 0, 1))
end

local function setGlowLight(part: BasePart, level: number)
	local light = part:FindFirstChildOfClass("PointLight")
	if not light then
		light = Instance.new("PointLight")
		light.Color = part:GetAttribute("BaseColor") or part.Color
		light.Parent = part
	end
	light.Range = GLOW_LIGHT_RANGE
	light.Brightness = GLOW_LIGHT_BRIGHT * math.clamp(level, 0, 1)
	light.Enabled = level > 0.02
end

-- ---------------------------------------------------------------- arms

-- The arm's own model is AUTHORITY, not art: hide it and let the limb drawn
-- to it BE the thing on screen. Its health bar is a BillboardGui, not a
-- BasePart, so it survives this and stays targetable.
local function hideArm(model: Model)
	if model:GetAttribute("KrakenArmDrawn") then
		return
	end
	model:SetAttribute("KrakenArmDrawn", true)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Transparency = 1
			descendant.CastShadow = false
		elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
			descendant.Transparency = 1
		end
	end
end

-- WHICH SEAT AN ARM OWNS. AUTHORITATIVE from `SocketIndex`, the attribute
-- CreatureService already stamps on every boss part it plants, at the moment
-- it decides where the thing stands - so this is the server's own answer read
-- back rather than a reconstruction. Falls back to WrapIndex (which the arm
-- contract does carry) and then to claim order, so an arm always gets SOME
-- seat and never floats rootless.
local function seatOf(model: Model, taken, seats: { number }): number?
	local published = model:GetAttribute("SocketIndex") or model:GetAttribute("WrapIndex")
	local wanted = if type(published) == "number" then math.max(math.floor(published), 1) else 1
	local count = #seats
	for step = 0, count - 1 do
		local slot = seats[((wanted - 1 + step) % count) + 1]
		if not taken[slot] then
			return slot
		end
	end
	return nil
end

-- The gullet's polyps. Not posed, not chained - they are the arena's own
-- props, and all that is owed them is the palette and the weakpoint's Neon.
-- Same MeshColors path as every piece in the pack, so a colour never has to
-- be written twice.
local function glowPolyp(model: Model)
	local hot = model:GetAttribute("Weakpoint") == true or model:GetAttribute("WeakpointHot") == true
	local colour = MeshColors.get("Kraken_Polyp")
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			if colour and not part:GetAttribute("BaseColor") then
				part:SetAttribute("BaseColor", colour)
				part.Color = colour
			end
			part.Material = if hot then Enum.Material.Neon else Enum.Material.SmoothPlastic
		end
	end
end

-- Read one arm's published pose into its state, and open a crossfade when the
-- phase has changed. `prevRate` is the outgoing phase's OWN speed, measured
-- rather than assumed, because armPoint extrapolates the outgoing curve at it
-- and a wrong rate is a limb that drifts on after the phase ended.
local function readArm(entry, state, model: Model, now: number, dt: number)
	local arm = entry.arm
	arm.state = state
	arm.time = now

	local phase = model:GetAttribute("ArmPhase")
	phase = if type(phase) == "string" and KrakenPath.POSE[phase] then phase else "Rest"
	local t = tonumber(model:GetAttribute("ArmT")) or 0
	local wrap = tonumber(model:GetAttribute("WrapIndex"))
	local targetX = tonumber(model:GetAttribute("TargetX"))
	local targetZ = tonumber(model:GetAttribute("TargetZ"))

	-- The rate estimator, smoothed: ArmT arrives on replication ticks, not on
	-- render frames, so a raw difference is a sawtooth and a limb driven off
	-- it stutters through every blend.
	if dt > 1e-4 and phase == arm.phase then
		local raw = (t - (arm.t or 0)) / dt
		arm.rate = (arm.rate or 0) + (raw - (arm.rate or 0)) * math.clamp(4 * dt, 0, 1)
	end

	-- THE TRANSITION SIGNAL IS `ArmPhaseAt`, NOT `ArmPhase`. The phase string
	-- can repeat - two slams in a row, a sweep re-cocked - and a limb that
	-- only watches the string sits out the second one entirely, holding a
	-- finished curve while the server runs a fresh attack. The timestamp
	-- changes on every transition, so it catches both.
	--
	-- WHAT IT IS NOT USED FOR: the blend's clock. The server stamps it with
	-- its OWN os.clock, which is time since the SERVER process started and
	-- shares no epoch with this one - subtracting it from anything here is a
	-- number in the thousands of seconds, and the ease would be over before
	-- it was drawn. So it is read as an EDGE and the crossfade is anchored on
	-- this client's Workspace:GetServerTimeNow(), which both machines do
	-- share. The ease is never skipped and never snapped; only its zero comes
	-- from here rather than from the wire.
	local stamp = model:GetAttribute("ArmPhaseAt")
	local changed = if stamp ~= nil then stamp ~= arm.stamp else phase ~= arm.phase
	arm.stamp = stamp
	if changed then
		arm.prevPhase = arm.phase
		arm.prevT = arm.t or 0
		arm.prevRate = arm.rate or 0
		arm.prevTarget = arm.target
		arm.prevWrap = arm.wrap
		arm.prevLaneFrom = arm.laneFrom
		arm.prevLaneTo = arm.laneTo
		arm.prevLaneZ = arm.laneZ
		arm.blendAt = now
		arm.blendFor = KrakenPath.BLEND[phase] or 0.45
		arm.phase = phase
		arm.rate = 0
	end
	arm.t = t
	if wrap then
		arm.wrap = math.clamp(math.floor(wrap), 1, #KrakenPath.WRAPS)
	end
	if targetX and targetZ then
		local ship = KrakenPath.shipCenter(state)
		arm.target = Vector3.new(targetX, ship.Y + KrakenPath.deckY(targetX - ship.X), targetZ)
		-- The sweep lane, ship-local. A DETAIL BEYOND THE CONTRACT: the arm's
		-- attributes give one aim point and a sweep needs two ends, so TargetX
		-- is read as where the sweep FINISHES and KrakenPath.lane mirrors it
		-- about the waist's centre to find where it starts. Documented there.
		arm.laneTo = targetX - ship.X
		arm.laneZ = targetZ - ship.Z
	end
end

-- ---------------------------------------------------------------- lifecycle

-- The boss's own model is AUTHORITY, exactly as each arm's is: hits, the health
-- bar and the cutscene's BossName handoff all read it, and nothing on it may be
-- drawn or the head is there twice. The server hides it too
-- (CreatureService.Fn.hideColossusModel, from the posed rising branch) - this is
-- the belt, and it is here rather than trusted because the server's hide is
-- reached through one `if def.pose then` inside one mode branch, and the one
-- thing the owner CANNOT be asked to diagnose is a second boss standing where
-- the real one is. Transparency only, never CanCollide or the query flags, so
-- every hit test in the fight keeps working on exactly the parts it always used.
local function hideBossModel(model: Model)
	if model:GetAttribute("KrakenBodyDrawn") then
		return
	end
	model:SetAttribute("KrakenBodyDrawn", true)
	local wasVisible = false
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			if descendant.Transparency < 0.99 then
				wasVisible = true
			end
			descendant.Transparency = 1
			descendant.CastShadow = false
		elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
			descendant.Transparency = 1
		end
	end
	if wasVisible then
		warn(
			"[KrakenBody] the server's authority model was still VISIBLE at adopt - hidden here,"
				.. " but the server should have done it: CreatureService.Fn.hideColossusModel is"
				.. " called from the `if def.pose then` arm of the rising branch only, so any path"
				.. " that reaches the fight without passing through `rising` leaves the row's"
				.. " CreaturePack proxy standing inside the drawn animal."
		)
	end
end

-- THE 370-STUD SEAM, RECONCILED ON THIS SIDE BECAUSE THIS IS THE SIDE THAT CAN
-- SEE IT.
--
-- `PoseCenter` is the SHIP (this file's header, and KrakenPath's: the head is
-- derived from it by HEAD_OFFSET, which is (0, 0, -370)). The server publishes
-- it out of `publishPose`, which sends `state.center` - and `state.center` is
-- seeded by Fn.colossusState from `creature.anchor`, which Fn.updateKrakenFight
-- has ALREADY moved onto K.KRAKEN.HEAD_AT = (0, 0, -370) a few lines earlier in
-- the same frame. So the wire carries the HEAD, this file adds the offset a
-- second time, and the whole animal is drawn 370 studs further out to sea than
-- the head it is standing in - with every limb rooted out there reaching back
-- across 740 studs of water for a deck target.
--
-- The BossArenas row is the independent answer (arena_gen puts KrakenArena_Base,
-- the hull, on that centre exactly), so the disagreement is MEASURABLE here. Y
-- is taken from the wire, never from the row: the server snaps the pose to
-- World.WATER_Y and the row's centre Y is 0.
--
-- The gullet is not a disagreement. Fn.krakenSwallow re-publishes PoseCenter
-- 20,000+ studs away into another room, which is why the published value wins
-- past SHIP_SAME_ROOM rather than being corrected into the sea.
local SHIP_TOLERANCE = 8.0 -- the waterline snap and nothing else
local SHIP_SAME_ROOM = 2000.0 -- past this it is the gullet, not a seam bug
local shipWarned = false

local function shipCentreFrom(published: Vector3?): Vector3?
	local arena = BossArenas.items and BossArenas.items[ARENA_ID]
	local row = arena and arena.center
	if not row then
		return published
	end
	if not published then
		return row
	end
	local off = Vector3.new(published.X - row.X, 0, published.Z - row.Z).Magnitude
	if off > SHIP_SAME_ROOM then
		return published
	end
	if off > SHIP_TOLERANCE then
		if not shipWarned then
			shipWarned = true
			warn(
				string.format(
					"[KrakenBody] PoseCenter is %.0f studs from BossArenas.%s.center (%.0f is the"
						.. " head's own offset): the server is publishing the HEAD where the contract"
						.. " says the SHIP. Drawing from the arena row instead, so the animal is in the"
						.. " right place. SERVER FIX: CreatureService's publishPose sends"
						.. ' `state.center` for pose "kraken", which Fn.updateKrakenFight has already'
						.. " moved onto K.KRAKEN.HEAD_AT - it must send `creature.krakenShip`.",
					off,
					ARENA_ID,
					KrakenPath.HEAD_OFFSET.Magnitude
				)
			)
		end
		return Vector3.new(row.X, published.Y, row.Z)
	end
	return published
end

local function destroyBody(model: Model)
	local body = bodies[model]
	if not body then
		return
	end
	bodies[model] = nil
	if body.folder then
		body.folder:Destroy()
	end
end

-- The frame handed to the cutscene hook, allocated ONCE per body and mutated
-- in place: it is written every frame whether or not anyone is looking at it,
-- so allocating one per frame would churn the collector for nothing.
local function newFrame(count: number)
	local tentacles = {}
	for i = 1, count do
		tentacles[i] = { bearing = 0, radius = 0, rise = 0, curl = 0, tip = Vector3.zero, visible = true }
	end
	return {
		t = 0,
		visible = true,
		head = { position = Vector3.zero, yaw = 0, rise = 0, gape = 0, roar = 0 },
		tentacles = tentacles,
		ink = 1,
	}
end

local function adoptBoss(model: Model)
	if bodies[model] or model:GetAttribute("Pose") ~= POSE_NAME then
		return
	end

	-- BEFORE ANYTHING IS BUILT, so the owner reads "your pack is the old one" or
	-- "there is no pack" instead of inferring it from a shape they have never
	-- seen the correct version of.
	auditPack()

	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = Workspace

	-- The PIVOT is the last resort and it is a poor one - placeColossus puts it
	-- at the head plus 0.4 of the mantle, not at the ship - so the arena row is
	-- preferred over it by shipCentreFrom whenever the row exists.
	local centre = shipCentreFrom(model:GetAttribute("PoseCenter")) or model:GetPivot().Position
	local state = KrakenPath.newState(centre)
	state.rise = model:GetAttribute("Rise") or 0
	-- The ship, PREFERRED from the arena row because that is what the hull was
	-- actually placed on. Absent until the wiring slice adds the row, and
	-- KrakenPath.shipCenter then derives it from the head's own PoseCenter.
	local arena = BossArenas.items and BossArenas.items[ARENA_ID]
	state.ship = arena and arena.center or nil

	-- THE WELD LAW, asserted once where it can be seen rather than trusted.
	local slack = KrakenPath.weldSlack(TIP_LENGTH)
	if slack <= 0 then
		warn(string.format("[KrakenBody] weld law broken: %.1f studs of slack at TIP_LENGTH %.2f", slack, TIP_LENGTH))
	end

	local count = KrakenPath.ARM_COUNT
	local ambient = {}
	for _, seat in KrakenPath.AMBIENT_SEAT do
		ambient[seat] = true
	end
	local arms = {}
	for index = 1, count do
		local arm = KrakenPath.newArm(state, index)
		if ambient[index] then
			-- A decoration limb. Pinned to the one pose it will ever hold, so
			-- no attribute read and no blend bookkeeping ever touches it.
			arm.phase = "Adrift"
			arm.prevPhase = "Adrift"
		end
		arms[index] = {
			arm = arm,
			chain = ChainPose.new(function(s, t)
				return KrakenPath.armPoint(s, t)
			end, { samples = 96 }),
			segments = {},
			suckers = {}, -- index -> { left, right }
			tip = makePiece("TentacleTip", folder),
			model = nil,
			ambient = ambient[index] == true,
		}
	end

	local head = {}
	for _, name in HEAD_PIECES do
		head[name] = makePiece(name, folder)
	end

	bodies[model] = {
		folder = folder,
		state = state,
		arms = arms,
		head = head,
		count = count,
		frame = newFrame(count),
		headFrame = CFrame.new(),
	}
	model.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			destroyBody(model)
		end
	end)

	-- LAST, AND THAT ORDER IS THE WHOLE POINT. The rig exists by now, so hiding
	-- the authority model can never be the thing that makes the fight empty - if
	-- any line above this throws, the server's model is still standing and the
	-- adopt warn below says why there is no rig over it.
	hideBossModel(model)
end

-- ---------------------------------------------------------------- per frame

local function approach(current: number, goal: number, rate: number, dt: number): number
	return current + (goal - current) * math.clamp(rate * dt, 0, 1)
end

-- Where along the drawn limb a world point sits, 0..1. Coarse on purpose -
-- the answer feeds a run of three sucker pairs, so a sample every 5% of the
-- limb resolves it far finer than the thing it is choosing between, and a
-- fine sweep here would be paid every frame on every hot limb.
local function nearestU(chain, at: Vector3): number
	local best, bestU = math.huge, WEAK_AT_DEFAULT
	for i = 0, 20 do
		local u = i / 20
		local d = (chain:pointAt(u * chain.length) - at).Magnitude
		if d < best then
			best, bestU = d, u
		end
	end
	return bestU
end

-- Claim the live arm creatures to the four seats.
local function claimArms(body, centre: Vector3)
	local folder = Workspace:FindFirstChild(CREATURES_FOLDER)
	for _, entry in body.arms do
		entry.model = nil
	end
	if not folder then
		return
	end
	local taken = {}
	for _, child in folder:GetChildren() do
		local id = child:GetAttribute("CreatureId")
		if child:IsA("Model") and ARM_IDS[id] then
			local at = child:GetPivot().Position
			if (at - centre).Magnitude < DRAW_RANGE then
				hideArm(child)
				-- ONLY the fight seats can be claimed. An extra creature - a
				-- stale `kraken_tentacle`, a third arm from a server that
				-- changed its mind - is hidden and then ignored rather than
				-- stealing a decoration limb's root and dragging it onto the
				-- deck with no attributes to drive it.
				local seat = seatOf(child, taken, KrakenPath.FIGHT_SEAT)
				if seat then
					taken[seat] = true
					body.arms[seat].model = child
				end
			end
		elseif child:IsA("Model") and id == POLYP_ID then
			-- The gullet's growths: MeshColors drives the colour, the
			-- weakpoint drives the material, and nothing here poses them.
			glowPolyp(child)
		end
	end
end

-- ------------------------------------------------- the deck highlight
--
-- See MARK for what this is and why it is attributes-only. Three small
-- functions: drop the mark, build one, and write one per frame.

-- DESTROYED, not parked. A parked mark is an invisible Neon part sitting at
-- y = -8000 for the rest of the fight, and there are two arms and three kinds of
-- it - the lifetime is short and obvious enough that owning the instance is not
-- worth the leak of clarity. This is also the ONLY place a mark ends, so "the
-- mark cannot outlive the windup" is one line rather than an invariant.
local function clearMark(entry)
	if entry.mark then
		entry.mark:Destroy()
		entry.mark = nil
		entry.markKind = nil
	end
end

local function makeMark(body, kind: string): BasePart
	local part = Instance.new("Part")
	part.Name = "KrakenDeckMark_" .. kind
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	-- A Roblox cylinder's axis is +X, so a disc lying on the deck is one turned a
	-- quarter turn about Z - done where the CFrame is written, not here.
	if kind ~= "lane" then
		part.Shape = Enum.PartType.Cylinder
	end
	local colour = MeshColors.get(MARK.COLOR_ROW) or MARK.COLOR_FALLBACK
	part.Color = colour
	-- setGlow reads BaseColor, so the mark rides the same one-line glow channel
	-- the eyes and the siphon core do rather than having a second one.
	part:SetAttribute("BaseColor", colour)
	part.Parent = body.folder
	return part
end

-- THE LANE A SWEEP MARK IS DRAWN DOWN, and it prefers the mailbox for exactly
-- the reason KrakenPath.lane does: the server's `sweepLane` payload carries the
-- lane EXACTLY, while the arm's own attributes carry one aim point that has to be
-- mirrored to recover two ends. A mark drawn on the mirror when the event said
-- otherwise would be the one thing worse than no mark - a safe-looking strip of
-- deck that is not safe.
--
-- The follow-through OVERRUN is taken back off either way. KrakenPath.lane adds
-- LANE_OVERRUN so the LIMB cocks past the end of the lane and swings through it;
-- the DANGER stops at the lane, and a mark that included the overrun would paint
-- 34 studs of deck at each end that nothing is ever going to touch.
local function markLane(arm, state): (number, number, number)
	local heard = KrakenPath.LANE
	if heard.from and heard.to and (arm.time or 0) - heard.at <= KrakenPath.LANE_FRESH then
		return heard.from, heard.to, heard.z or KrakenPath.shipCenter(state).Z
	end
	local ship = KrakenPath.shipCenter(state)
	local fromX, toX, z = KrakenPath.lane(arm)
	local over = if toX >= fromX then KrakenPath.LANE_OVERRUN else -KrakenPath.LANE_OVERRUN
	return ship.X + fromX + over, ship.X + toX - over, ship.Z + z
end

-- One arm's mark, rebuilt only when the KIND changes and rewritten every frame.
local function drawMark(entry, body, state, now: number)
	local arm = entry.arm
	-- No creature on this seat means no published phase to trust, so no mark -
	-- a decoration limb and a dead arm both fall out here.
	local kind = if entry.model then MARK.PHASE[arm.phase] else nil
	if not kind then
		clearMark(entry)
		return
	end
	if entry.markKind ~= kind then
		clearMark(entry)
		entry.mark = makeMark(body, kind)
		entry.markKind = kind
	end
	local part = entry.mark
	-- Eased on the SAME smootherstep the limb's own poses use, so the mark's
	-- squeeze and the limb's haul are one motion rather than two that agree.
	local grow = KrakenPath.smoother(math.clamp(arm.t or 0, 0, 1))
	local shrink = 1 - MARK.CONTRACT * grow

	if kind == "lane" then
		local fromX, toX, z = markLane(arm, state)
		local ship = KrakenPath.shipCenter(state)
		local midX = (fromX + toX) * 0.5
		-- ONE deck height for the whole strip, and that is correct rather than a
		-- simplification: Fn.krakenArmSweep takes its lane's ends from a SINGLE
		-- deck's x range, so a lane never spans two floors.
		local y = ship.Y + KrakenPath.deckY(midX - ship.X) + MARK.LIFT
		-- No rotation: ship-local axes ARE world axes (BossArenaService places the
		-- hull by translation only), so a lane along X is a box along X.
		part.CFrame = CFrame.new(midX, y, z)
		part.Size = Vector3.new(math.max(math.abs(toX - fromX), 1), MARK.THICK, MARK.LANE_HALF * 2 * shrink)
	else
		local at, radius
		if kind == "wrap" then
			local wrap = KrakenPath.WRAPS[arm.wrap] or KrakenPath.WRAPS[1]
			at = KrakenPath.aboard(state, Vector3.new(wrap.X, KrakenPath.deckY(wrap.X) + MARK.LIFT, wrap.Z))
			radius = MARK.WRAP_R
		elseif kind == "wake" then
			-- ON THE SEA, NOT ON THE SHIP, and it is the one mark in this function
			-- that does not go through KrakenPath.deckY. The coil is a submerged
			-- limb circling the hull: its station is the arm's published
			-- TargetX/TargetZ at the WATERLINE, which in ship-local terms is y = 0
			-- exactly (CreatureService seeds the pose centre at World.WATER_Y, so
			-- shipCenter().Y IS the sea surface - KrakenPath.surfaceY's own note).
			--
			-- So the target's X and Z are taken and its Y is DISCARDED: readArm
			-- snaps every target to a deck height, which is right for the five
			-- marks that are painted on planking and 8 studs wrong for this one.
			local target = arm.target
			if not target then
				clearMark(entry)
				return
			end
			at = Vector3.new(target.X, KrakenPath.surfaceY(state) + MARK.LIFT, target.Z)
			radius = MARK.WAKE_R
		elseif kind == "spear" then
			-- The stab's mark, on the deck under the current one of the three.
			local target = arm.target
			if not target then
				clearMark(entry)
				return
			end
			at = target + Vector3.new(0, MARK.LIFT, 0)
			radius = MARK.SPEAR_R
		else
			-- The slam disc. `arm.target` is already on the right floor for its own
			-- x - readArm builds it through KrakenPath.deckY - so the castles need
			-- no special case here.
			local target = arm.target
			if not target then
				clearMark(entry)
				return
			end
			at = target + Vector3.new(0, MARK.LIFT, 0)
			radius = MARK.SLAM_R
		end
		local span = radius * 2 * shrink
		part.CFrame = CFrame.new(at) * CFrame.Angles(0, 0, math.pi / 2)
		part.Size = Vector3.new(MARK.THICK, span, span)
	end

	-- The beat, quickening; and the midpoint it swings about, brightening.
	local period = MARK.PERIOD_SLOW + (MARK.PERIOD_FAST - MARK.PERIOD_SLOW) * grow
	local beat = 0.5 + 0.5 * math.sin(now * (math.pi * 2 / math.max(period, 0.05)))
	local mid = MARK.FADE_OPEN + (MARK.FADE_CLOSE - MARK.FADE_OPEN) * grow
	part.Transparency = math.clamp(mid - MARK.PULSE * beat, 0.02, 0.96)
	setGlow(part, 0.30 + 0.70 * grow * beat)
end

local function hideBody(body)
	for _, piece in body.head do
		park(piece)
		setGlowLight(piece, 0)
	end
	for _, entry in body.arms do
		park(entry.tip)
		-- The deck mark goes with the body rather than being parked: the gullet is
		-- a different arena and a telegraph left painted on a ship 20,000 studs
		-- away is a telegraph waiting to be seen through a wall.
		clearMark(entry)
		for _, segment in entry.segments do
			park(segment)
		end
		for _, pair in entry.suckers do
			park(pair[1])
			park(pair[2])
		end
	end
end

-- One limb, from its blended curve. `roll` turns the sucker rows to the TOP
-- for a limb that has gone limp - a limb showing its underside is the whole
-- read of the Down pose.
local function drawArm(entry, body, weakAt: number?)
	local arm = entry.arm
	local chain = entry.chain
	chain:update(arm)

	-- DRAPE ROLLS TOO (the new-attacks pass, 2026-09-12), on exactly Down's
	-- argument: a limb showing its underside is a limb that has stopped working,
	-- and Drape is the spent pose the sucker volley and the deck scythe now end
	-- in. It is also the pose whose OPENING a player has to find - the hot forearm
	-- is lying on the bulwark - so turning the sucker rows up is what makes the
	-- thing they are meant to shoot the part that is facing them.
	local roll = if arm.phase == "Down" or arm.phase == "Drape" then math.pi else 0
	local used = 0
	chain:each(SPACING, function(index, cframe, u)
		used = index
		local segment = entry.segments[index]
		if not segment then
			segment = makePiece("TentacleSeg", body.folder)
			entry.segments[index] = segment
		end
		local girth = SCALE * (1 - TIP_GIRTH * u)
		applyPiece(segment, cframe, SCALE * (1 - TIP_LENGTH * u), girth)

		-- A SUCKER PAIR CAN FAIL TO BE PLACED AT AN INDEX THAT IS STILL IN
		-- USE, which is why it is parked HERE rather than in the cleanup
		-- below. That loop only parks indices past `used`, which is right for
		-- anything drawn once per segment - but a sucker is ALSO gated on
		-- `u <= SUCKER_UNTIL`, and the last segment's u walks back and forth
		-- across that cutoff every frame as the ambient drift changes the
		-- curve's arc length. So the last pair would fall in the gap between
		-- the two rules: not placed, and not parked either, because its index
		-- is <= used. It would stay exactly where the previous frame left it -
		-- two pale discs hanging in open air beside a tapering limb tip, on
		-- every arm, on better than a third of frames. (The same bug the old
		-- eight-arm rig shipped and then fixed; it is re-stated because the
		-- rig was rebuilt from scratch and the trap is a property of the two
		-- rules, not of the old code.)
		local placed = index % SUCKER_EVERY == 0 and u <= SUCKER_UNTIL
		local pair = entry.suckers[index]
		if not placed then
			if pair then
				park(pair[1])
				park(pair[2])
			end
			return
		end
		if not pair then
			pair = { makePiece("TentacleSucker", body.folder), makePiece("TentacleSucker", body.folder) }
			entry.suckers[index] = pair
		end
		-- The drop comes off the SEGMENT's own authored girth, so the rows
		-- stay on the skin as the limb tapers instead of sinking into it.
		local segBase = segment:GetAttribute("BaseSize") or FALLBACK_SIZE.TentacleSeg
		local drop = segBase.Y * SUCKER_SEAT * girth
		local hot = weakAt ~= nil and math.abs(u - weakAt) <= (WEAK_RUN * 0.5 * SPACING) / math.max(chain.length, 1)
		for side = 1, 2 do
			local sign = if side == 1 then 1 else -1
			local seat = cframe
				* CFrame.Angles(roll + sign * SUCKER_ANGLE, 0, 0)
				* CFrame.new(0, -drop, 0)
				* SUCKER_TURN
			applyPiece(pair[side], seat, girth, girth)
			-- THE WEAKPOINT, and it never touches the star: this is a run of
			-- suckers on the limb, 400 studs from the face.
			local part = pair[side]
			if hot then
				part.Material = Enum.Material.Neon
				part.Color = WEAK_COLOR
			elseif part.Material == Enum.Material.Neon then
				part.Material = Enum.Material.SmoothPlastic
				part.Color = part:GetAttribute("BaseColor") or part.Color
			end
		end
	end)
	for index = used + 1, #entry.segments do
		park(entry.segments[index])
		local pair = entry.suckers[index]
		if pair then
			park(pair[1])
			park(pair[2])
		end
	end

	local tipGirth = SCALE * (1 - TIP_GIRTH)
	applyPiece(entry.tip, chain:cframeAt(chain.length), SCALE * (1 - TIP_LENGTH), tipGirth)
	return chain:pointAt(chain.length)
end

local function drawBody(model: Model, body, dt: number, now: number)
	local state = body.state
	state.time = now
	state.rise = approach(state.rise, model:GetAttribute("Rise") or 1, EASE.rise, dt)
	state.siphon = approach(state.siphon, if model:GetAttribute("SiphonOpen") then 1 else 0, EASE.siphon, dt)
	state.phase = tonumber(model:GetAttribute("PhaseIndex")) or 1
	-- Re-read and re-reconciled every frame, never cached: the swallow moves
	-- PoseCenter into the gullet mid-fight, and shipCentreFrom is what keeps a
	-- head-for-ship publish from moving the animal with it.
	local centre = shipCentreFrom(model:GetAttribute("PoseCenter"))
	if centre then
		state.center = centre
	end

	claimArms(body, state.center)
	for _, entry in body.arms do
		if entry.model then
			readArm(entry, state, entry.model, now, dt)
		else
			-- No creature on this seat (a dead arm, or a ring still spawning):
			-- the limb keeps whatever pose it last held and keeps drifting, so
			-- it drapes rather than vanishing.
			entry.arm.state = state
			entry.arm.time = now
		end
	end

	-- ------------------------------------------------- build the frame
	local frame = body.frame
	frame.t = if cutscene then now - cutsceneAt else 0
	-- PHASE 3 IS A DIFFERENT ARENA and the animal is not in it. The gate is
	-- `visible`, not an early return, so a cutscene can still stage the head
	-- deliberately if it ever wants to.
	frame.visible = state.phase ~= GULLET_PHASE
	frame.ink = 1
	-- THE HEAD, DERIVED. PoseCenter is the ship; the head is 370 studs off its
	-- port beam by the authored offset, and this is the only place the two are
	-- related. Checked against the server: CreatureService seeds the pose at
	-- `creature.anchor` (the BossArenas centre, at WATER_Y), arena_gen puts
	-- `KrakenArena_Base` on that same centre and the head at arena-local
	-- (0, +370), and author +Y maps to Roblox -Z - so
	--     landmark("head") = PoseCenter + (0, 0, -370) + the head's own
	--                        authored centre (0, 28.4, 0) * SCALE
	-- and at Rise 1 with the ship at the origin that is (0, 170, -370): 370
	-- studs off the beam, 170 studs of mantle centre above the sea, which is
	-- the mid-body of a head running -96 to +480. Read PoseCenter as the head
	-- and every one of those lands 370 studs into open water.
	frame.head.position = KrakenPath.headCenter(state)
	frame.head.yaw = KrakenPath.FACING_YAW
	frame.head.rise = state.rise
	frame.head.gape = state.siphon
	frame.head.roar = 0

	local ship = KrakenPath.shipCenter(state)
	for index, entry in body.arms do
		local slot = frame.tentacles[index]
		local arm = entry.arm
		arm.tipOverride = nil
		arm.coilOverride = nil
		local tip = KrakenPath.armPoint(arm, 1)
		slot.bearing = math.atan2(tip.Z - ship.Z, tip.X - ship.X)
		slot.radius = Vector3.new(tip.X - ship.X, 0, tip.Z - ship.Z).Magnitude
		-- RISE IS SIGNED, -1 .. 1, so a limb can be asked for fully-under-sea
		-- as well as fully-reared: 0 is the waterline, 1 the reared apex over
		-- the deck, -1 one apex-height BELOW the surface. A 0..1 unit could
		-- only ever say "at the water", which is not a pose a cutscene of a
		-- thing that lives underwater can do without.
		--
		-- RADIUS IS NOT CLAMPED, deliberately: the head is 370 studs off the
		-- ship and the mantle is 282 of half-width, so anything short of ~630
		-- studs is a place a limb can honestly be, and a clamp would quietly
		-- refuse the shots that reach past the animal.
		slot.rise = math.clamp((tip.Y - ship.Y) / TENTACLE_RISE_SPAN, -1, 1)
		slot.curl = if arm.phase == "Wrapped" then 1 else 0
		slot.visible = true
		-- Written HERE rather than after the draw, so landmark("tentacleN")
		-- answers on the first frame instead of a frame late.
		slot.tip = tip
		-- Remembered EXACTLY as written, so "did the hook touch this?" is a
		-- comparison against the value we put there and not against a
		-- tolerance. Untouched limbs then keep the curve already computed and
		-- pay nothing for the hook existing.
		entry.wroteBearing, entry.wroteRadius, entry.wroteRise, entry.wroteCurl =
			slot.bearing, slot.radius, slot.rise, slot.curl
	end

	if cutscene then
		cutscene(frame)
	end

	-- ------------------------------------------------- write the rig
	if not frame.visible then
		hideBody(body)
		return
	end

	local headFrame = KrakenPath.headFrameAt(frame.head.position, frame.head.rise, frame.head.yaw)
	body.headFrame = headFrame
	-- The ambient breathe: a scale about the body CFrame's own origin, which
	-- is the waterline, because that is where the mantle is authored about.
	-- Applied to the piece OFFSET and to the piece SIZE together, so the head
	-- swells in place rather than sliding up as it inflates.
	local vertical, horizontal = KrakenPath.breathe(now)
	local glow = KrakenPath.eyePulse(now) * math.clamp(frame.ink, 0, 1)
	local roar = math.clamp(frame.head.roar, 0, 1)
	-- The lock's flare rides the same channel as `roar` and is folded in the
	-- same way - toward 1 by the remaining headroom - so the two compose
	-- instead of one overwriting the other, and neither can ever push the
	-- channel past full.
	local lock = flareLevel(eyeFlareUntil, eyeFlareFor, now)
	local surge = math.max(roar, lock)
	local face = glow + (1 - glow) * surge
	local gape = math.clamp(frame.head.gape, 0, 1)
	local ink = flareLevel(siphonFlareUntil, siphonFlareFor, now) * siphonFlareCharge

	for _, name in HEAD_PIECES do
		local piece = body.head[name]
		local at = headFrame
		local offset = FALLBACK_AT[name]
		local push = 0
		local girth = 1
		if name == "Siphon" then
			push = SIPHON_FLARE_PUSH * gape
			girth = 1 + SIPHON_FLARE_GIRTH * gape
		end
		if offset and piece:GetAttribute(FALLBACK_TAG) then
			-- Position scaled with the head, rotation left alone: the offsets
			-- are authored units, so they have to grow with SCALE the same way
			-- the pieces do, and the breathe has to reach them or the stand-in
			-- head comes apart as it inflates.
			local p = offset.Position + Vector3.new(push, 0, 0)
			at = headFrame
				* CFrame.new(Vector3.new(p.X * horizontal, p.Y * vertical, p.Z * horizontal) * SCALE)
				* offset.Rotation
		elseif push ~= 0 then
			-- An IMPORTED piece is modelled in place around the head's origin
			-- and must never be offset onto FALLBACK_AT - that would take the
			-- animal apart. The flare is the one exception, and it is a push
			-- along the FACING rather than a reposition: the funnel slides out
			-- of the hide and everything else stays where it was authored.
			at = headFrame * CFrame.new(push * SCALE, 0, 0)
		end
		applyPiece(piece, at, SCALE * horizontal * girth, SCALE * vertical * girth)
	end

	-- The two Neon pieces, and only those two. Kraken_Pupil is deliberately
	-- absent: the star is matte and steady, and that is what makes the orb an
	-- eye. The siphon core spikes with `gape` on top of the ambient pulse,
	-- because the door opening IS the tell for the swallow.
	setGlow(body.head.Eyes, face)
	setGlowLight(body.head.Eyes, face)
	local core = math.max(face, math.max(gape, ink))
	setGlow(body.head.SiphonCore, core)
	setGlowLight(body.head.SiphonCore, core)
	-- The accent `roar` buys for two parts that are already placed.
	if roar > 0.01 then
		setGlow(body.head.Lashes, roar * 0.6)
		setGlow(body.head.Eyespots, roar * 0.6)
	elseif body.head.Lashes:GetAttribute("BaseColor") then
		body.head.Lashes.Color = body.head.Lashes:GetAttribute("BaseColor")
		body.head.Eyespots.Color = body.head.Eyespots:GetAttribute("BaseColor")
	end

	for index, entry in body.arms do
		local arm = entry.arm
		local slot = frame.tentacles[index]
		-- ONLY a mutated limb pays for the round trip. Bit comparison against
		-- what we wrote, so an untouched frame reproduces the fight exactly.
		if slot.bearing ~= entry.wroteBearing or slot.radius ~= entry.wroteRadius or slot.rise ~= entry.wroteRise then
			arm.tipOverride = Vector3.new(
				ship.X + math.cos(slot.bearing) * slot.radius,
				ship.Y + slot.rise * TENTACLE_RISE_SPAN,
				ship.Z + math.sin(slot.bearing) * slot.radius
			)
		end
		if slot.curl ~= entry.wroteCurl then
			arm.coilOverride = math.clamp(slot.curl, 0, 1)
		end
		-- A per-limb hide, so a cutscene can bring limbs on one at a time.
		if slot.visible == false then
			park(entry.tip)
			clearMark(entry)
			for _, segment in entry.segments do
				park(segment)
			end
			for _, pair in entry.suckers do
				park(pair[1])
				park(pair[2])
			end
			continue
		end
		-- THE KNUCKLE, and `WeakpointPos` is preferred over the per-pose
		-- table for the reason a published number always beats a guess: it is
		-- where the server is actually taking the hits, so the run of hot
		-- suckers lands on the part of the limb a player is meant to shoot.
		-- The table is the fallback for a server that publishes only the
		-- boolean, and it is a per-pose guess at the same thing.
		local weakAt = nil
		if entry.model and entry.model:GetAttribute("WeakpointHot") then
			local at = entry.model:GetAttribute("WeakpointPos")
			weakAt = if typeof(at) == "Vector3"
				then nearestU(entry.chain, at)
				else (WEAK_AT[arm.phase] or WEAK_AT_DEFAULT)
		end
		-- THE DECK HIGHLIGHT, drawn from the published attributes only and placed
		-- on the planking rather than on the limb - so it is up for the whole
		-- windup, tightens as ArmT closes, and is gone the frame the phase stops
		-- being a windup. See MARK.
		drawMark(entry, body, state, now)
		slot.tip = drawArm(entry, body, weakAt)
	end
end

-- ---------------------------------------------------------------- surface

-- Arm the cutscene hook. Tolerates being called before anything exists: the
-- state is this module's, and every body picks it up on its next frame.
function KrakenBodyController.setCutscene(fn: ((any) -> ())?)
	cutscene = fn
	cutsceneAt = Workspace:GetServerTimeNow()
end

-- Post-pose world positions. nil until a rig exists, which is what the
-- cutscene lane's own header asks for.
function KrakenBodyController.landmark(name: string): Vector3?
	for _, body in bodies do
		local tentacle = string.match(name, "^tentacle(%d+)$")
		if tentacle then
			local slot = body.frame.tentacles[tonumber(tentacle)]
			return slot and slot.tip
		end
		local at = LANDMARK_AT[name]
		if at then
			return (body.headFrame * CFrame.new(at * SCALE)).Position
		end
		return nil
	end
	return nil
end

-- THE EYE LOCK'S FLARE. Raised by CreatureEventController when the server
-- says an eye has picked someone; both orbs go hard-bright for the window.
-- The star pupils do NOT move with them - they are not in NEON_PIECES and
-- nothing here writes their colour - which is the entire point of the lock
-- reading as a STARE rather than as a pair of lamps switching on.
function KrakenBodyController.flareEyes(seconds: number)
	local span = math.clamp(tonumber(seconds) or 1, 0.05, 20)
	eyeFlareFor = span
	eyeFlareUntil = Workspace:GetServerTimeNow() + span
end

-- THE SIPHON'S FLARE, the ink charge lighting the funnel's core from inside.
-- `charge` scales how far past the ambient pulse it goes; 1 is a full flare.
function KrakenBodyController.flareSiphon(seconds: number, charge: number?)
	local span = math.clamp(tonumber(seconds) or 1, 0.05, 20)
	siphonFlareFor = span
	siphonFlareUntil = Workspace:GetServerTimeNow() + span
	siphonFlareCharge = math.clamp(tonumber(charge) or 1, 0, 1)
end

-- The existing surface burst, one line, exactly as asked.
function KrakenBodyController.splash(position: Vector3, size: number?)
	Vfx.splash(position, size)
end

-- ---------------------------------------------------------------- boot

-- GUARDED, AND IT SAYS SO. An error in here used to be the quietest failure in
-- the fight: `adoptBoss` runs inside init's task.spawn and inside an attribute
-- signal, so a throw takes out that one coroutine, leaves `bodies[model]` empty,
-- and the only evidence is a stack trace nobody connects to "there is no boss".
-- Named here, with what the owner is actually looking at, and the hide is the
-- LAST line of adoptBoss so a failed adopt leaves the server's model standing
-- rather than an empty sea.
local adoptWarned = false

local function tryAdopt(child: Instance)
	local ok, err = pcall(adoptBoss, child)
	if not ok and not adoptWarned then
		adoptWarned = true
		warn(
			"[KrakenBody] adopt failed - NOTHING IS DRAWING THE KRAKEN and the server's"
				.. " authority model is all that is left in the arena: "
				.. tostring(err)
		)
	end
end

-- THE ADOPTION THAT NEVER FIRES, and it is the failure this file had no way to
-- report at all. Everything here hangs off `Pose == "kraken"` arriving on the
-- boss model; the server sets it in ONE place (publishPose, reached through
-- Fn.placeColossus, reached through the `if def.pose then` arm of the rising
-- branch), so any path into the fight that does not pass through `rising` - or
-- any rename of the attribute on that side - leaves this controller holding its
-- hands up forever with nothing to say. The boss creature itself is visible to
-- us by its CreatureId, so "the Kraken is in the arena and never published a
-- pose" is a state we can name, and it is named once.
--
-- The grace is the rise (Bosses.kraken.riseTime 5.0) with room for replication
-- and for an admin start that skips straight to the fight.
local BOSS_ID = "kraken"
local POSE_GRACE = 15.0
local poseWarned = false

local function watchPose(child: Instance)
	if child:GetAttribute("CreatureId") ~= BOSS_ID or poseWarned then
		return
	end
	task.delay(POSE_GRACE, function()
		if not child.Parent or bodies[child] or poseWarned then
			return
		end
		poseWarned = true
		warn(
			string.format(
				"[KrakenBody] the boss creature has been in the arena for %.0fs and its Pose"
					.. " attribute is %s, not %q - so nothing here ever adopted it and the only"
					.. " Kraken in the fight is the server's authority model. The server must"
					.. " publish Pose/PoseCenter on the boss model: CreatureService's publishPose,"
					.. " reached from Fn.placeColossus, reached from the `if def.pose then` arm of"
					.. " Fn.updateBoss's rising branch. Check Bosses.items.kraken still carries"
					.. ' `pose = "kraken"`.',
				POSE_GRACE,
				tostring(child:GetAttribute("Pose")),
				POSE_NAME
			)
		)
	end)
end

local function watch(child: Instance)
	if not child:IsA("Model") then
		return
	end
	tryAdopt(child)
	watchPose(child)
	child:GetAttributeChangedSignal("Pose"):Connect(function()
		tryAdopt(child)
	end)
end

function KrakenBodyController.init()
	task.spawn(function()
		local folder = Workspace:WaitForChild(CREATURES_FOLDER, 30)
		if not folder then
			return
		end
		for _, child in folder:GetChildren() do
			watch(child)
		end
		folder.ChildAdded:Connect(watch)
	end)
end

function KrakenBodyController.start()
	local warned = false
	RunService.RenderStepped:Connect(function(dt)
		-- Server time, not os.clock(): every ambient term here - the mantle's
		-- breathe, the Neon pulse, each limb's drift - is a phase two machines
		-- have to agree on, and os.clock() is time since THIS process started,
		-- so no two clients share an epoch. On a local one the limb you are
		-- dodging drifts on a different phase for every player in the party,
		-- and the moment anything server-side reads these curves for a hitbox
		-- it is reading a different limb from the one you can see. Same
		-- reasoning as BrinejawBodyController.
		local now = Workspace:GetServerTimeNow()
		for model, body in bodies do
			if model.Parent then
				-- Guarded for the same reason the serpent is: an error here
				-- aborts the whole RenderStepped callback, so one bad frame in
				-- one body would stop every other body drawing, and the fight
				-- would freeze with no error anyone sees.
				local ok, err = pcall(drawBody, model, body, dt, now)
				if not ok and not warned then
					warned = true
					warn("[KrakenBody] draw failed: " .. tostring(err))
				end
			else
				destroyBody(model)
			end
		end
	end)
end

return KrakenBodyController
