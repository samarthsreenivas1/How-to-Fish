--!nonstrict
-- CameraController.luau
-- The game is first-person. This locks the camera there, hides the cursor
-- that Roblox otherwise parks in the middle of the screen, and gives menus
-- a single switch to borrow the mouse back while they're open.
--
-- Roblox's own camera scripts re-assert LockCenter every frame while in
-- first person, so a one-off assignment isn't enough - the override runs
-- just after the camera step each frame for as long as a menu holds it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Islands = require(Shared.Config.Islands)
local BossArenas = require(Shared.Config.BossArenas)
local World = require(Shared.Config.World)

local Viewmodel = require(script.Parent.Parent.Modules.Viewmodel)

local player = Players.LocalPlayer

local CameraController = {}

local cursorFree = false

-- THE CINEMATIC OVERRIDE (BossCutsceneController). A boss intro flies a camera
-- of its own for twenty seconds and then hands control back, and the honest
-- place for that is HERE rather than in a second BindToRenderStep that fights
-- this one: whatever is set runs AFTER the whole pipeline below has written
-- `camera.CFrame`, is handed that frame, and returns the one to actually use -
-- so a cutscene that wants to blend back to "wherever the player would be
-- looking" is handed exactly that, every frame, without re-deriving it.
--
-- Nothing else about the rig is disturbed: `orbitPitch` is still written back
-- by the birdseye and throne frames (they run first and are what compute the
-- normal frame), the mode is still asserted every frame with nothing cached
-- across the override (so a cutscene ending on the Kraken's ship hands back to
-- that arena's far third-person distance by the same per-frame decision that
-- chose it), and clearing the override leaves the camera exactly where the
-- pipeline already had it.
local override: ((CFrame, number) -> CFrame)? = nil

-- THIRD PERSON IN THE BOSS ARENA (user, 2026-08-29: "the arena should go
-- third person making the user dodge in third"). The Kraken's arms sweep the
-- whole whirlpool and its head fills the middle - you cannot read an attack
-- coming from behind you down a first-person barrel. Keyed to WHERE you are,
-- not to whether the boss is up, so the camera doesn't swap mid-fight.
local THIRD_PERSON_ISLANDS = { maelstrom = true }
local THIRD_PERSON_DISTANCE = 26

local thirdPerson = false

-- THIRD PERSON ON THE KRAKEN'S SHIP, and it is the ordinary rig at a DIFFERENT
-- DISTANCE rather than a fourth rig. The Careenage needed height and the
-- Throne needed a split boom; this fight needs neither - the floor is a 90-stud
-- waist you fight along, and over-the-shoulder is the right shape for it. What
-- it does not survive is 26 studs.
--
-- THE ARITHMETIC, because "it felt too close" is not a reason a number should
-- move. At 26 studs and 70 FOV the frame is 36 studs tall and ~65 wide where
-- the character stands. The things this fight asks you to read are:
--   * a LIMB 48 studs of girth - wider than the whole frame at 26, so a
--     tentacle arrives as a wall with no readable edge and no visible ground
--     beside it to step onto;
--   * the SWEEP, whose whole mechanic is that its underside is 3 studs over
--     the deck and the CRATES are what clear it (arena_gen measured every one
--     against that plane) - which means the cover and the limb have to be in
--     frame together or the answer is invisible;
--   * a 34-stud beam, so both rails want to be on screen while you pick a side.
-- At 60 studs the frame is 84 tall by ~150 wide: a whole limb across it with
-- the deck under it, both rails, and a crate stack either side. Past ~75 the
-- character is a speck against a 480-stud head; under ~45 the limb is a wall
-- again. 60 is the middle of that band and is the only number here that is a
-- choice rather than a measurement.
local KRAKEN_DISTANCE = 60

-- Keyed to the ARENA's centre (BossArenas) for the Careenage's reason: the
-- ship is a lair arena far out in open water, where Islands.islandAt is nil
-- and the island test above can never fire for it. Reach is the ship's own
-- half-length (85) plus the head's standoff (370) and its half-width (282),
-- rounded up - so the mode holds anywhere a player can be put, including
-- overboard onto the walkable sea the arena's own HANDOFF warns about.
local KRAKEN_ARENAS = { kraken = true }
local KRAKEN_REACH = 800

-- ...and the GULLET is deliberately a separate row at the STANDARD distance.
-- Phase 3 is a 200-stud room with an 80-stud ceiling: the reason for 60 studs
-- was a limb the size of a building, and there are no limbs in there. Indoors
-- the same 60 would put the eye through a wall on every turn and hand the
-- occlusion pull a job it should never have.
local KRAKEN_GULLET_ARENAS = { kraken_gullet = true }
local KRAKEN_GULLET_REACH = 260

-- ...and the ASHFALL HEART is the gullet's case exactly, one fight over: act
-- four of the Pyrelisk is fought in a sealed room 216 studs across with a
-- 72-stud ceiling, so it takes the STANDARD distance for the gullet's reason
-- and not the Throne's. The colossus was the thing that wanted 60 studs of
-- pull-back, and by act four the colossus is gone - what is left is a heart on
-- a dais at 74 studs and eight pillars to put between you and the wall vents,
-- all of which reads at the normal boom. Indoors the pushed-back rig would put
-- the eye through the dome on every turn, and hand the occlusion pull a job it
-- should never have.
--
-- Keyed to the ARENA's centre for the gullet's reason too: `pyrelisk_heart` is
-- a BossArenas key that is NOT an island, 40,000 studs from anything, so
-- `Islands.islandAt` is nil out there and the island test can never fire for
-- it. Reach 220 is twice the floor's own radius (108) - clear of the dome's
-- outer shell at ~117 and of the barrier belt, and the nearest neighbour of
-- any kind is 13,600 studs away, so erring wide costs nothing.
local PYRELISK_HEART_ARENAS = { pyrelisk_heart = true }
local PYRELISK_HEART_REACH = 220

local kraken = false -- on the ship: the pushed-back distance
local krakenGullet = false -- inside the beast: the standard one
local pyreliskHeart = false -- inside the volcano: the standard one again

local function inArenaSet(position: Vector3, set, reach: number): boolean
	for arenaId in set do
		local arena = BossArenas.items[arenaId]
		local center = arena and arena.center
		if center then
			local d = Vector3.new(position.X - center.X, 0, position.Z - center.Z).Magnitude
			if d <= reach then
				return true
			end
		end
	end
	return false
end

-- How far back third person holds, HERE. One function so the pinned zoom and
-- the orbit's own boom can never disagree about it - they are the two halves
-- of one answer, and a mode whose zoom says 26 while its eye sits at 60 spends
-- every frame fighting Roblox's camera scripts for the difference.
local function thirdPersonDistance(): number
	return if kraken then KRAKEN_DISTANCE else THIRD_PERSON_DISTANCE
end

-- ============================================================ THE ORBIT
-- RIGHT-CLICK-DRAG LOOK (user, 2026-09-08, first hands-on contact with the
-- arena camera: "the third person needs to be revamped. you should be able to
-- hold right click and then move the camera around. also you should implement
-- a crosshair and allow the user to shoot in third person when you're in a
-- boss").
--
-- THE CURSOR MODEL, written out once here because every mode below obeys it
-- and every symptom in that report is a consequence of it:
--
--   first person - the cursor is LOCKED to the centre and hidden, and Roblox's
--                  own camera scripts steer with every mouse move. UNCHANGED
--                  by any of this.
--   third person - the cursor is FREE, and it IS the crosshair: the system
--                  icon is off and CrosshairController draws its mark on the
--                  pointer's pixel every frame (user, 2026-09-08: "the cursor
--                  is the crosshair and the user shoots wherever their
--                  crosshair is"). Moving the mouse does NOT steer the camera.
--   RMB held     - the cursor locks where it stands - the crosshair holds that
--                  pixel and still aims it - and the mouse delta turns the
--                  orbit. Releasing restores the free cursor.
--   LMB          - fires through the CURSOR's pixel (RangedController.aimRay,
--                  ViewportPointToRay at GetMouseLocation), orbiting or not.
--                  RangedController owns the trigger and binds it through
--                  ContextActionService, so left click and right drag never
--                  contend.
--   a menu open  - setCursorFree(true) wins over all of it.
--
-- WHY THE ORBIT IS THIS FILE'S AND NOT ROBLOX'S. The stock Classic camera does
-- turn on a held right button - but only if it sees the button, and two
-- High-priority ContextActionService binds already sink MouseButton2 for the
-- whole session (FishingController's "CastRod", RangedController's scoped
-- zoom). What the default camera makes of it is not something this file can
-- depend on. The old behaviour was worse than merely unreliable: NOTHING ever
-- put MouseBehavior back to Default on the way out of first person, so the
-- LockCenter that first person sets survived into the arena, the mouse steered
-- the camera every time it moved, and there was no cursor to show for it.
--
-- So yaw and pitch below are this client's own state, moved by nothing but a
-- held right button - and they are what every rig in this file reads. The rigs
-- themselves are untouched: applyOrbit writes the orbit into the camera BEFORE
-- they run, and each of them goes on recovering yaw and pitch off the frame it
-- is handed (`base.LookVector`) exactly as it always has. They are simply fed
-- a frame this file authored instead of one Roblox's camera scripts authored.
local orbitYaw = 0
local orbitPitch = 0
local orbiting = false -- the right button is down and the drag owns the mouse

-- Radians per pixel of mouse travel, with the stock camera's own 0.77 vertical
-- trim: a full turn is about 720 pixels, which is what the rest of the game
-- already feels like under the hand.
local ORBIT_SPEED = math.rad(0.5)
local ORBIT_PITCH_TRIM = 0.77

-- Guard rails on the orbit's pitch - NOT any fight's band. Every arena rig
-- clamps further (BIRDSEYE_PITCH_CEIL and the rest) and hands what it allowed
-- back to `orbitPitch`, so a drag stops exactly where the mode stops rather
-- than banking travel the player cannot see and has to unwind before the view
-- moves again. Stay wide here and let each rig speak for its own fight.
local ORBIT_PITCH_CEIL = math.rad(80)
local ORBIT_PITCH_FLOOR = -math.rad(80)

-- The plain over-the-shoulder orbit's own geometry, for the arenas that have
-- no rig of their own (the Maelstrom). Focus at the shoulder, and the same
-- occlusion pull-in every raised rig uses - a blocked frame in a boss fight is
-- a death wherever the camera is standing.
local ORBIT_FOCUS_LIFT = 2.5
local ORBIT_CLEARANCE = 1.6
local ORBIT_MIN_DISTANCE = 4

-- BIRDSEYE IN THE CAREENAGE (Wrack's bullet-hell pass, 2026-08-29). Wrack is
-- a static gun platform: the fight is not the boss, it is the pattern on the
-- ground between you and it, and over-the-shoulder third person hides the
-- half of that field you are not facing. This is the SAME machinery one step
-- further - Classic camera, zoom pinned so the mode is what the game says it
-- is - with the camera lifted and pitched down so a rank of broadside fire is
-- on screen while there is still time to walk out of it.
--
-- Keyed to the ARENA's centre (BossArenas), not to an island: the Careenage
-- is a lair arena 24k studs out in open water, so Islands.islandAt is nil
-- there and the island test above can never fire for it.
local BIRDSEYE_ARENAS = { wreck = true }

-- How far from the arena centre the mode holds. THE CAREENAGE AS REBUILT
-- (arena_gen.py, the WK_ profile): walkable sand to r 132, then an awash flat
-- carrying the palisade of grounded hulls out to r 160, a foam ring to 167.5,
-- and the shoal's own rim at 172. The fight agrees with the floor - Wrack
-- opens on anyone inside `aggro` 165 and his broadsides retire at `bound` 140
-- (Bosses admiral_wrack) - so every place the fight can put a player, standing
-- or swimming, is inside 172.
--
-- 200 puts the mode's edge 28 studs past that rim, in open water with no floor
-- under it and no fight left to read. THAT MARGIN IS THE WHOLE REQUIREMENT,
-- because this test has no hysteresis - a bare `d <= BIRDSEYE_REACH`
-- re-evaluated every frame - so an edge falling anywhere the player fights
-- would flip the camera mid-dodge. 130 did exactly that: it was sized for the
-- old 78-stud shoal and outlived it, cutting the mode two studs INSIDE the
-- sand's own edge in a fight whose entire answer is walking. Erring wide is
-- free out here - the nearest other content is thousands of studs away
-- (Wreckwater itself is 8.3k) - so this only has to be bigger than the arena,
-- and never has to be precise.
local BIRDSEYE_REACH = 200

-- The orbit. At 58 studs and the default 70 FOV roughly one arena width of
-- ground crosses the frame, so a rank entering from the far side is visible
-- while it is still a shape rather than a wall. Much closer and a full-width
-- rank runs off the screen edges; much further and the character (5 studs)
-- falls under ~5% of screen height, which is where you stop being able to
-- judge your own body against a gap.
local BIRDSEYE_DISTANCE = 58

-- ...pitched down 34 degrees from wherever the player is looking. That is the
-- angle where the flat opens into a readable field while the hull and its gun
-- decks still sit in the top third of the frame - a horizon to aim at, which
-- a true top-down camera throws away. At rest the camera floats
-- 58*sin(34) = 32 studs up and 48 studs back.
local BIRDSEYE_PITCH = math.rad(34)

-- The player keeps pitch authority inside a band: up to 14 degrees above the
-- horizon to put the crosshair on a gun-deck battery, or 62 below for a
-- near-plan read of the pattern - never to true top-down, which would take the
-- boss off the screen entirely.
--
-- THE CEILING AND THE BOOM BELOW ARE ONE DECISION, and it is the Throne's
-- (2026-09-06). This rig used to place the eye along the same pitch it LOOKS
-- along, and its ceiling carried the note that "the camera is already 32 studs
-- up, so from there it looks DOWN onto a high deck". That was written when the
-- batteries stood on a flat ground ring. They do not: `at = "mounts"` (Bosses
-- admiral_wrack) put them at 10.6, 27.7, 29.1 and 35.7 studs up, and nobody
-- re-derived the band. In a coupled orbit, looking up swings the eye DOWN by
-- the same angle - at the old 16-degree ceiling the eye sat 58*sin(16) = 16
-- studs BELOW the aim point, under a beach that runs +0.45..+4.85 - so the
-- occlusion cast below hit sand and hauled the orbit to its 6-stud floor in
-- the middle of the fight. Solving that rig from the drop ring (r 88) for the
-- centroid of each battery: Deck 23.2 degrees, Stern 23.1, Top 22.9, Keel 2.9.
-- THREE OF THE FOUR TARGETS THE WHOLE FIGHT IS ABOUT SHOOTING WERE OUTSIDE THE
-- BAND, and reaching for them broke the camera.
--
-- Splitting the two pitches is the fix, and it moves the ceiling's job. With
-- the eye held at the boom's 27.3 studs over the sand the same solve reads
-- Deck 4.0, Stern 1.0, Top 0.2, Keel -8.3 from the drop ring (2.9, 0.7, 0.2,
-- -6.0 from the sand's outer edge at r 132), and 7.1 for the Deck battery
-- standing against the hull itself - the closest any of them can be got to.
-- So 14 is not "what it takes to reach a battery" any more, it is that worst
-- case plus seven degrees, and it is bounded from above by the FRAME: the
-- character rides (aim - boom) below the optical axis, and at a 70-degree FOV
-- it leaves the screen past 35. 14 over a 20-degree boom puts the body at 34
-- at the very top of the band and at 24 while a battery is actually on the
-- crosshair - low in frame, which is the trade, but never off it. In a bullet
-- hell, losing your own body is losing the dodge.
local BIRDSEYE_PITCH_CEIL = math.rad(14)
local BIRDSEYE_PITCH_FLOOR = -math.rad(62)

-- THE BOOM: where the EYE hangs, as a pitch below the aim point, never the
-- direction the camera looks. It simply FOLLOWS the aim down - so the whole
-- lower half of the band, the rest pose at 34 and the near-plan dodge read at
-- the 62 floor, is bit-for-bit the orbit this mode always had, character
-- centred and all - and stops following at 20 on the way up. That pin is what
-- the batteries cost: past it the eye would start sinking towards the sand
-- again for no aiming benefit, since from 58 studs at 20 degrees it already
-- floats 19.8 above the aim point (27.3 over the beach, 54.5 back) and every
-- battery on the ship is below it. The eye's lowest point anywhere in the band
-- is that 27.3 - a good 22 studs clear of the highest sand behind the player -
-- so the occlusion cast can no longer be tripped by the beach at all, and only
-- the palisade hulls it was written for can pull the orbit in.
local BIRDSEYE_BOOM_CEIL = -math.rad(20)

-- The aim point rides above the character so they sit low in frame and the
-- ground ahead of them gets the rest of it.
local BIRDSEYE_FOCUS_LIFT = 4.5

-- Both transitions ease on an exponential approach rather than a tween: the
-- mode can flip while the player is running, and an approach is frame-rate
-- independent and can reverse mid-flight without a jump. tau 0.28 settles in
-- about eight tenths of a second.
local BIRDSEYE_EASE_TAU = 0.28
local BIRDSEYE_SETTLED = 0.002

-- If world geometry (a mast, one of the palisade hulls when you fight at the
-- rim) comes between the camera and the player, the camera comes in front of
-- it. A blocked frame in a bullet hell is a death.
local BIRDSEYE_CLEARANCE = 1.6

local birdseye = false
local birdseyeBlend = 0 -- 0 = the camera as it is everywhere else, 1 = the raised orbit
local birdseyeAt = 0 -- os.clock of the last frame, for the ease
local birdseyeHiding = false -- holding the viewmodel hidden through the ease OUT

-- Is `position` inside a birdseye arena's bowl?
local function inBirdseyeArena(position: Vector3): boolean
	for islandId in BIRDSEYE_ARENAS do
		local arena = BossArenas.items[islandId]
		local center = arena and arena.center
		if center then
			local d = Vector3.new(position.X - center.X, 0, position.Z - center.Z).Magnitude
			if d <= BIRDSEYE_REACH then
				return true
			end
		end
	end
	return false
end

-- THIRD PERSON ON THE ASHFALL THRONE (Pyrelisk, 2026-08-31). The same
-- machinery a THIRD time, and a third answer: the Careenage lifts the camera
-- to read a floor, this one pushes it back to read a BODY. Pyrelisk is a
-- 270-stud colossus rooted at the arena's centre (PyreliskPath: shoulders at
-- 186, the chest seam at 156, a 228-stud arm), fought from a rim path at
-- radius 120..232 across a moat that makes the fight ranged-only. Two things
-- about the ordinary third-person rig do not survive that:
--
--   * SCALE. At THIRD_PERSON_DISTANCE (26) and 70 FOV the frame is 36 studs
--     tall and 65 wide where the character stands. One FIST is 50 across, so
--     a hand-slam does not fit in the frame at all - it arrives as a wall,
--     with no readable edge and no ground beside it to step onto.
--   * PITCH. This fight is fought looking UP: from the rim path the chest
--     seam sits ~30-37 degrees above the camera's horizon and the crown
--     ~44-51, and the crosshair is the middle of the screen, so a player
--     shooting the body holds the camera well above level. In any orbit where
--     the EYE is placed along the same pitch the camera LOOKS along - the
--     birdseye rig, and Roblox's own Classic camera - looking up swings the
--     eye down through the rim floor, the occlusion pull hauls it in, and the
--     distance collapses to nothing exactly while the boss is winding up.
--
-- So this variant separates the orbit's two halves. The eye hangs off a boom
-- pitch of its own, held to a shallow band so it keeps its height and its
-- distance; the camera looks along the player's own pitch, free to travel all
-- the way up the body. The consequence is deliberate and is the whole point:
-- the character is NO LONGER CENTRED. It rides low in frame while you read
-- the colossus and rises as you look down at the ground you are dodging on.
-- That is the trade this fight forces - what is about to hit you is 180 studs
-- in the air and where it lands is at your feet, and no 70-degree frame holds
-- both, so the player picks which one with the same mouse they aim with.
--
-- Keyed to the ARENA's centre (BossArenas) for the Careenage's reason: the
-- Throne is a lair 24k studs out in open water, where Islands.islandAt is nil
-- and the island test above can never fire.
local THRONE_ARENAS = { volcano = true }

-- How far from the arena centre the mode holds, horizontally. The rim path
-- ends at 232 and the lip overhangs its outer 32, so 300 covers the path, the
-- lip and the lava moat inside it. Erring wide is free out here for
-- BIRDSEYE_REACH's reason - the nearest other content is thousands of studs
-- away and there is nothing inside the circle but the arena.
local THRONE_REACH = 300

-- ...and a HEIGHT gate, which the Careenage does not need and this does. The
-- Throne is a volcano summit: its walkable rim is 292 studs up (BossArenas
-- volcano, meshBottom), so the same XZ circle at sea level is open ocean
-- underneath the mountain, and nothing playable sits between the two. Anyone
-- down there - thrown off the rim, or dropped by a spawn that has not probed
-- the arena floor - is out of the fight and gets the game's first person
-- back rather than a boss camera pointed at open water.
local THRONE_MIN_HEIGHT = 100

-- The orbit. At 64 studs, 70 FOV and 16:9 the frame is ~90 studs tall and
-- ~159 wide at the character: one full width of the 112-stud rim path, with
-- most of a fist's width of margin each side. That is the number that
-- matters - a 50-stud fist and the ground it is coming down on are on screen
-- together, so the slam has an edge you can walk off. It is also about as far
-- back as the arena affords: past ~80 the eye sits behind the rim's lip
-- whenever you face the boss from the outer path, and the occlusion pull
-- would flap the distance every step instead of holding it.
local THRONE_DISTANCE = 64

-- THE BOOM: where the EYE goes, as a pitch below the aim point. Never the
-- direction the camera looks. Pinned at 12 degrees whenever the player is
-- level or looking up, which parks the eye 13 studs above and 63 studs behind
-- the character and keeps it there while they crane at the crown; allowed to
-- follow the aim down to 50 so that looking at the ground still lifts the
-- camera over it, the way the birdseye orbit does.
local THRONE_BOOM_CEIL = -math.rad(12)
local THRONE_BOOM_FLOOR = -math.rad(50)

-- What the camera may LOOK along. This is the player's own pitch and these
-- are guard rails, not a band the mode drives: the ceiling has to clear the
-- crown (~51 degrees from the inner rim) or the crosshair cannot be put on
-- the upper body at all, and this is the one boss with no melee answer.
local THRONE_PITCH_CEIL = math.rad(70)
local THRONE_PITCH_FLOOR = -math.rad(72)

-- The aim point rides at about chest height on the character.
local THRONE_FOCUS_LIFT = 5

-- Same exponential approach as the birdseye ease, for the same reasons: the
-- mode can flip while the player is running, and an approach is frame-rate
-- independent and can reverse mid-flight without a jump.
local THRONE_EASE_TAU = 0.28
local THRONE_SETTLED = 0.002

-- Something between the camera and the player is the COMMON case here: the
-- nine monoliths are cover first and furniture second, and standing behind
-- one is the point. Same pull-in, with a floor far enough out that the frame
-- is still a frame and not the inside of the character's shoulders.
local THRONE_CLEARANCE = 1.6
local THRONE_MIN_DISTANCE = 8

local throne = false
local throneBlend = 0 -- 0 = the camera as it is everywhere else, 1 = the pushed-back orbit
local throneAt = 0 -- os.clock of the last frame, for the ease
local throneHiding = false -- holding the viewmodel hidden through the ease OUT

-- Is `position` on the Throne's summit? Horizontal reach AND height, for the
-- reason THRONE_MIN_HEIGHT gives.
local function inThroneArena(position: Vector3): boolean
	if position.Y - World.WATER_Y < THRONE_MIN_HEIGHT then
		return false
	end
	for islandId in THRONE_ARENAS do
		local arena = BossArenas.items[islandId]
		local center = arena and arena.center
		if center then
			local d = Vector3.new(position.X - center.X, 0, position.Z - center.Z).Magnitude
			if d <= THRONE_REACH then
				return true
			end
		end
	end
	return false
end

-- NO ARENA CAMERA IN THE GLOOMTRENCH, AND THAT IS A DECISION (user order,
-- 2026-09-08). Noctyss and the Lantern Choir run in the game's default LOCKED
-- FIRST PERSON, falling through exactly like any island not listed above.
--
-- There WAS a raised third-person orbit here - GLOOM_ARENAS, GLOOM_LIFT,
-- GLOOM_SETBACK, GLOOM_REACH and a boom of its own, built on the Throne's
-- split boom/aim pattern - to hold seven lanterns and the swept floor in one
-- frame. It is RETIRED, not broken: the fight's two reads were made
-- first-person-viable instead, the choir's tell becoming a SEQUENTIAL lantern
-- rhythm rather than a simultaneous seven-way phase comparison, and the sweep
-- being telegraphed by positional audio. Neither read needs an eye above the
-- lantern plane any more, so nothing is keyed to `gloom` in this file.
--
-- Do not re-add a gloom rig without first revisiting those two reads.

-- Menus call this with true when they open and false when they close. The
-- cursor appears and unlocks so buttons are clickable; the camera stops
-- turning with the mouse for the same reason.
function CameraController.setCursorFree(free: boolean)
	cursorFree = free
	UserInputService.MouseIconEnabled = free
	if free then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
end

function CameraController.isCursorFree(): boolean
	return cursorFree
end

function CameraController.isThirdPerson(): boolean
	return thirdPerson
end

-- True in a bullet-hell arena's raised orbit (a third-person variant, so
-- isThirdPerson is true there as well). For anything that has to lay out
-- differently when the camera is looking down at the field.
function CameraController.isBirdseye(): boolean
	return birdseye
end

-- True on the Ashfall Throne's pushed-back orbit (another third-person
-- variant, so isThirdPerson is true there as well). For anything that has to
-- lay out differently when the character is not the middle of the screen.
function CameraController.isThrone(): boolean
	return throne
end

-- Take the camera for a cinematic, or give it back with nil. `fn` is called
-- once per render step with the frame the normal pipeline just computed and
-- this frame's dt, and returns the frame to use. See the block at the top.
function CameraController.setOverride(fn: ((normal: CFrame, dt: number) -> CFrame)?)
	override = fn
end

function CameraController.hasOverride(): boolean
	return override ~= nil
end

-- Forces the camera into first person. Called at boot, on every respawn,
-- and re-checked each frame: the place file also sets these on
-- StarterPlayer (default.project.json), but a one-off assignment proved
-- fragile - a fresh place without those settings came up in third person
-- - so the controller never trusts that it's still set.
local function lockFirstPerson()
	if player.CameraMode ~= Enum.CameraMode.LockFirstPerson then
		player.CameraMode = Enum.CameraMode.LockFirstPerson
	end
	-- Belt and braces: with the zoom range pinned, Classic mode can't back
	-- the camera out either.
	if player.CameraMaxZoomDistance ~= 0.5 then
		player.CameraMinZoomDistance = 0.5
		player.CameraMaxZoomDistance = 0.5
	end
end

-- Third person: the zoom range is PINNED at one distance rather than opened
-- up, for the same reason first person pins it - so the mode is what the
-- game says it is and not whatever the player last scrolled to.
local function lockThirdPerson()
	if player.CameraMode ~= Enum.CameraMode.Classic then
		player.CameraMode = Enum.CameraMode.Classic
	end
	local pinned = thirdPersonDistance()
	if player.CameraMaxZoomDistance ~= pinned then
		player.CameraMinZoomDistance = pinned
		player.CameraMaxZoomDistance = pinned
	end
end

-- What the camera should be blocked by on its way in: solid world geometry
-- only. Everything the fight draws is CanQuery = false, so bullets, markers
-- and the boss's own effects can never pull the camera in; the character
-- itself is filtered because the orbit starts inside it.
local occludeParams: RaycastParams? = nil
local occludeFor: Model? = nil

local function occlusionParams(character: Model): RaycastParams
	if occludeParams and occludeFor == character then
		return occludeParams :: RaycastParams
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.RespectCanCollide = true
	occludeParams, occludeFor = params, character
	return params
end

-- The raised orbit for one frame. Yaw is read back off the frame Roblox's own
-- camera scripts just produced, so the mouse still turns the camera exactly
-- as it does everywhere else in the game and the character still walks
-- camera-relative; only the pitch and the height are the mode's.
--
-- The look direction is the AIM - RangedController resolves every shot off
-- camera.CFrame.LookVector, so the crosshair is the middle of the screen and
-- goes where the player pointed it - and `boom` is the separate pitch the EYE
-- hangs off, for the reason BIRDSEYE_BOOM_CEIL gives. Below the pin the two
-- are the same angle, which is `lookAt(eye, focus)` written the general way:
-- identical orbit, identical framing, no seam at the boundary because a clamp
-- is continuous.
local function birdseyeFrame(root: BasePart, base: CFrame, character: Model): CFrame
	local focus = root.Position + Vector3.new(0, BIRDSEYE_FOCUS_LIFT, 0)
	local look = base.LookVector
	local yaw = math.atan2(-look.X, -look.Z)
	local pitch = math.asin(math.clamp(look.Y, -1, 1))
	local aimed = math.clamp(pitch - BIRDSEYE_PITCH, BIRDSEYE_PITCH_FLOOR, BIRDSEYE_PITCH_CEIL)
	-- What the band allowed, handed back to the drag (see ORBIT_PITCH_CEIL) -
	-- the inverse of the line above, since this mode's aim sits BIRDSEYE_PITCH
	-- below the player's own pitch. Without it a drag past the 14-degree
	-- ceiling would bank travel the player cannot see and would have to unwind
	-- before the view moved again.
	orbitPitch = aimed + BIRDSEYE_PITCH
	-- min, not clamp: `aimed` is already floored at BIRDSEYE_PITCH_FLOOR, so
	-- the boom lands inside the same floor by construction.
	local boom = math.min(aimed, BIRDSEYE_BOOM_CEIL)
	local dir = CFrame.fromEulerAnglesYXZ(aimed, yaw, 0).LookVector
	local back = CFrame.fromEulerAnglesYXZ(boom, yaw, 0).LookVector
	local distance = BIRDSEYE_DISTANCE
	local blocked = Workspace:Raycast(focus, -back * distance, occlusionParams(character))
	if blocked then
		distance = math.max((blocked.Position - focus).Magnitude - BIRDSEYE_CLEARANCE, 6)
	end
	local eye = focus - back * distance
	return CFrame.lookAt(eye, eye + dir)
end

-- Ease the orbit in and out. Like every other setting in this file it is
-- re-asserted every frame rather than assigned once - Roblox's camera scripts
-- rebuild the CFrame at RenderPriority.Camera and this runs one priority
-- later, so the last word each frame is this one.
--
-- The ease OUT also holds the third-person rig up while it runs: updateMode
-- hands the frame back to first person the instant the player crosses the
-- arena's edge, and without this hold the camera would cut to the character's
-- eyes while it was still thirty studs in the air.
local function applyBirdseye()
	local now = os.clock()
	local dt = math.clamp(now - birdseyeAt, 0, 0.25)
	birdseyeAt = now

	local target = if birdseye then 1 else 0
	birdseyeBlend += (target - birdseyeBlend) * (1 - math.exp(-dt / BIRDSEYE_EASE_TAU))
	if math.abs(target - birdseyeBlend) < BIRDSEYE_SETTLED then
		birdseyeBlend = target
	end

	if birdseyeBlend <= 0 then
		if birdseyeHiding then
			birdseyeHiding = false
			Viewmodel.setHidden(thirdPerson)
		end
		return
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local camera = Workspace.CurrentCamera
	if not root or not root:IsA("BasePart") or not camera then
		return
	end

	-- The zoom pin travels with the blend, so arriving dollies out from
	-- wherever the camera was instead of cutting to a fixed distance, and
	-- leaving reels it back in. Same pinned-range trick as lockThirdPerson:
	-- the mode is what the game says it is, not what was last scrolled to.
	if player.CameraMode ~= Enum.CameraMode.Classic then
		player.CameraMode = Enum.CameraMode.Classic
	end
	local pinned = 0.5 + (BIRDSEYE_DISTANCE - 0.5) * birdseyeBlend
	if player.CameraMaxZoomDistance ~= pinned then
		player.CameraMinZoomDistance = pinned
		player.CameraMaxZoomDistance = pinned
	end
	birdseyeHiding = true
	Viewmodel.setHidden(true)

	camera.CFrame = camera.CFrame:Lerp(birdseyeFrame(root, camera.CFrame, character :: Model), birdseyeBlend)
end

-- The Throne's orbit for one frame. Yaw AND pitch are read back off the frame
-- Roblox's own camera scripts just produced, so the mouse turns and aims
-- exactly as it does everywhere else in the game, the character still walks
-- camera-relative, and - because RangedController resolves every shot off
-- camera.CFrame.LookVector - the crosshair is still the middle of the screen
-- and still goes where the player pointed it. The look direction is the AIM
-- and this mode must not take it.
--
-- What the mode owns is where the EYE hangs: off `boom`, a pitch of its own,
-- so the camera holds its height and its distance while the player looks 50
-- degrees up a colossus instead of being dragged under the rim floor by the
-- aim. That is also why the camera is not aimed at `focus` the way the
-- birdseye orbit is - the character sits wherever the two pitches leave it.
local function throneFrame(root: BasePart, base: CFrame, character: Model): CFrame
	local focus = root.Position + Vector3.new(0, THRONE_FOCUS_LIFT, 0)
	local look = base.LookVector
	local yaw = math.atan2(-look.X, -look.Z)
	local pitch = math.asin(math.clamp(look.Y, -1, 1))
	local aimed = math.clamp(pitch, THRONE_PITCH_FLOOR, THRONE_PITCH_CEIL)
	-- What the guard rails allowed, handed back to the drag: see the same line
	-- in birdseyeFrame and ORBIT_PITCH_CEIL. A no-op anywhere inside the band.
	orbitPitch = aimed
	local boom = math.clamp(aimed, THRONE_BOOM_FLOOR, THRONE_BOOM_CEIL)
	local dir = CFrame.fromEulerAnglesYXZ(aimed, yaw, 0).LookVector
	local back = CFrame.fromEulerAnglesYXZ(boom, yaw, 0).LookVector
	local distance = THRONE_DISTANCE
	local blocked = Workspace:Raycast(focus, -back * distance, occlusionParams(character))
	if blocked then
		distance = math.max((blocked.Position - focus).Magnitude - THRONE_CLEARANCE, THRONE_MIN_DISTANCE)
	end
	local eye = focus - back * distance
	return CFrame.lookAt(eye, eye + dir)
end

-- Ease the Throne's orbit in and out. Line for line the birdseye ease, and
-- deliberately its own state rather than a shared blend: the two arenas are
-- 30k studs apart, only one can ever be easing, and a shared blend would make
-- either mode's bugs the other's.
--
-- The ease OUT holds the third-person rig up while it runs, and everything
-- that restores FIRST PERSON hangs off `throneBlend` reaching 0: updateMode
-- drops `throne` the instant the player leaves the summit (crossing the reach,
-- falling below it, dying, or being teleported home), the blend runs down,
-- and until it does this function is the only thing pinning Classic. Once it
-- is 0 the function returns before touching the camera at all and
-- lockFirstPerson - which runs every frame regardless - has the last word. A
-- character that vanishes mid-ease (death) stops at the root check below,
-- which is earlier still, so the pin is released immediately.
local function applyThrone()
	local now = os.clock()
	local dt = math.clamp(now - throneAt, 0, 0.25)
	throneAt = now

	local target = if throne then 1 else 0
	throneBlend += (target - throneBlend) * (1 - math.exp(-dt / THRONE_EASE_TAU))
	if math.abs(target - throneBlend) < THRONE_SETTLED then
		throneBlend = target
	end

	if throneBlend <= 0 then
		if throneHiding then
			throneHiding = false
			Viewmodel.setHidden(thirdPerson)
		end
		return
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local camera = Workspace.CurrentCamera
	if not root or not root:IsA("BasePart") or not camera then
		return
	end

	-- The zoom pin travels with the blend, same as the birdseye orbit: arriving
	-- dollies out from wherever the camera was, leaving reels it back in, and
	-- the mode is what the game says it is rather than what was last scrolled.
	if player.CameraMode ~= Enum.CameraMode.Classic then
		player.CameraMode = Enum.CameraMode.Classic
	end
	local pinned = 0.5 + (THRONE_DISTANCE - 0.5) * throneBlend
	if player.CameraMaxZoomDistance ~= pinned then
		player.CameraMinZoomDistance = pinned
		player.CameraMaxZoomDistance = pinned
	end
	throneHiding = true
	Viewmodel.setHidden(true)

	camera.CFrame = camera.CFrame:Lerp(throneFrame(root, camera.CFrame, character :: Model), throneBlend)
end

-- Is the right button down and allowed to steer? POLLED each frame rather
-- than latched on an InputBegan/InputEnded pair, for the reason
-- RangedController's trigger carries the same poll: a release that lands on a
-- GUI is game-processed and never comes back to a handler, and a drag latched
-- on by a press that IS delivered would then hold the mouse hostage - locked,
-- iconless, and steering - inside an open menu. A poll cannot latch.
--
-- The menu test is first: setCursorFree wins over the drag, so opening the
-- inventory mid-orbit hands the cursor over on the same frame.
local function updateOrbitInput()
	orbiting = not cursorFree
		and thirdPerson
		and UserInputService.MouseEnabled
		and UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
end

-- THE ORBIT, WRITTEN INTO THE CAMERA. Runs first among the per-frame camera
-- work, so every raised rig recovers this frame's yaw and pitch off it the
-- same way it used to recover Roblox's.
--
-- In the plain 26-stud third person (the Maelstrom, which has no rig of its
-- own) this IS the whole camera: the eye hangs along the same pitch the camera
-- looks along - the ordinary coupled orbit - with the shoulder focus and the
-- occlusion pull-in above. In an arena that has a rig, that rig lerps away
-- from this frame onto its own geometry and the only part of this that
-- survives is the yaw and the pitch. Which is the point: one drag, one piece
-- of state, four modes.
local function applyOrbit()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	if not thirdPerson then
		-- First person owns the look. Track it, so that walking into an arena
		-- starts the orbit exactly where the player was already looking and the
		-- ease in has nothing to snap over.
		local look = camera.CFrame.LookVector
		orbitYaw = math.atan2(-look.X, -look.Z)
		orbitPitch = math.asin(math.clamp(look.Y, -1, 1))
		return
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end
	orbitPitch = math.clamp(orbitPitch, ORBIT_PITCH_FLOOR, ORBIT_PITCH_CEIL)
	local focus = (root :: BasePart).Position + Vector3.new(0, ORBIT_FOCUS_LIFT, 0)
	local dir = CFrame.fromEulerAnglesYXZ(orbitPitch, orbitYaw, 0).LookVector
	local distance = thirdPersonDistance()
	local blocked = Workspace:Raycast(focus, -dir * distance, occlusionParams(character :: Model))
	if blocked then
		distance = math.max((blocked.Position - focus).Magnitude - ORBIT_CLEARANCE, ORBIT_MIN_DISTANCE)
	end
	local eye = focus - dir * distance
	camera.CFrame = CFrame.lookAt(eye, eye + dir)
end

-- ==================================================== THE WELDED TOOLS
-- WHOSE JOB IT IS TO SHOW YOU YOUR OWN ROD AND YOUR OWN GUN (2026-09-08, the
-- Maelstrom playtest: neither one was in the character's hands).
--
-- In first person the answer had always been "nobody's". Roblox's own
-- transparency controller hides every part of your character while the camera
-- is at your head, and the viewmodel controllers draw a camera-pinned copy in
-- front of it instead, so RodService and WeaponService weld a model into the
-- hand purely for OTHER players to look at - WeaponService's header still says
-- in as many words that "the owner never sees this copy", and nothing on the
-- client had ever written a transparency for it.
--
-- Third person turns that on its head: the viewmodels are gone and the welded
-- models are the only rod and the only weapon there are. RodViewmodelController
-- learned that much when the arena camera first landed and traded its own rod
-- back, noting that an override was needed to cover "the frames before the
-- camera settles". The weapon never got the same treatment, and both were left
-- resting on a stock controller that decides what your body looks like from
-- `(camera.Focus - camera.CFrame).Magnitude` - a pair this file now owns half
-- of, since applyOrbit writes the CFrame a priority AFTER the module that
-- writes both. Your own hands' contents are not something to leave to a race
-- between two files.
--
-- So the trade is stated here, where the mode is, and it is one statement for
-- both tools rather than one per controller. Whichever copy is not drawing, the
-- other is: viewmodels hidden means the welded models show. It reads
-- Viewmodel.isHidden() rather than `thirdPerson` on purpose - that flag is the
-- viewmodels' actual state, so the trade also holds through the eases OUT,
-- where a raised orbit keeps the rig up after the mode itself has gone.
local WELDED_TOOLS = { EquippedRod = true, EquippedWeapon = true }

local function applyWeldedTools()
	local character = player.Character
	if not character then
		return
	end
	if Viewmodel.isHidden() then
		-- The camera is out. Everything the player is wearing and holding
		-- draws, welded tools included - and the whole body with them, so that
		-- no future change to who authors the camera frame can strand the
		-- player in an arena looking at an empty patch of ground. Re-asserted
		-- every frame for the reason everything else in this file is: this runs
		-- last, so this is the last word.
		for _, part in character:GetDescendants() do
			if part:IsA("BasePart") then
				part.LocalTransparencyModifier = 0
			end
		end
		return
	end
	-- First person. The viewmodels ARE the rod and the weapon, so the welded
	-- copies must not draw for their owner; the rest of the body is Roblox's to
	-- fade and is deliberately left alone.
	for _, child in character:GetChildren() do
		if WELDED_TOOLS[child.Name] then
			for _, part in child:GetDescendants() do
				if part:IsA("BasePart") then
					part.LocalTransparencyModifier = 1
				end
			end
		end
	end
end

-- ============================================================ THE LIST
-- THE SHIP ROLLS AND THE GEOMETRY DOES NOT (the `shipList` event, and this is
-- SUBSTITUTION A: the hull is a 170-stud authored mesh with the fight staged
-- on measured deck heights, so heeling the MODEL would move every sweep plane,
-- every cover top and every wrap point out from under the numbers the fight is
-- built on - and the player would still be standing bolt upright on it). So
-- the ship stays where it is and the CAMERA rolls instead. The deck appears to
-- tilt, the horizon swings, debris tumbles the way it is rolling, and not one
-- collision surface has moved.
--
-- Applied LAST, after every rig, as a post-multiply on whatever frame that rig
-- produced. That is what makes it mode-agnostic: it composes with the plain
-- orbit, with the birdseye, with the Throne, and with any rig added later,
-- because it only ever rotates the finished camera about its own look axis and
-- never touches an eye position or a distance.
--
-- Eased in and out on a raised sine (0 -> peak -> 0 across the whole
-- duration), so there is no frame where the roll appears or vanishes; a second
-- list arriving mid-roll replaces the first rather than adding to it, since
-- two lists at once is a spin and the fight never means that.
local LIST_ANGLE = math.rad(7) -- the peak. Read as a heavy heel; past ~10 it reads as a barrel roll.
local listUntil = 0
local listFrom = 0
local listSide = 1

-- side > 0 rolls the horizon one way, < 0 the other. Called by whoever hears
-- the event (CreatureEventController), so this file owns the camera and that
-- one owns the audio and the debris.
function CameraController.rollCamera(seconds: number, side: number?)
	local duration = math.clamp(tonumber(seconds) or 0, 0, 12)
	if duration <= 0 then
		return
	end
	listFrom = os.clock()
	listUntil = listFrom + duration
	listSide = if (tonumber(side) or 1) < 0 then -1 else 1
end

local function applyRoll()
	local now = os.clock()
	if now >= listUntil then
		return
	end
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local span = listUntil - listFrom
	local u = if span > 1e-4 then math.clamp((now - listFrom) / span, 0, 1) else 1
	-- sin(pi * u): zero at both ends, one in the middle, and its DERIVATIVE is
	-- finite at both ends rather than zero - a list that eases out of nothing
	-- too gently does not read as a wave hitting a hull.
	local roll = math.sin(u * math.pi) * LIST_ANGLE * listSide
	camera.CFrame = camera.CFrame * CFrame.Angles(0, 0, roll)
end

-- Which mode this place wants, from where the character is standing.
local function updateMode()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local wanted = false
	if root then
		local islandId = Islands.islandAt((root :: BasePart).Position)
		wanted = islandId ~= nil and THIRD_PERSON_ISLANDS[islandId] == true
	end
	-- The birdseye arenas are third person too - a raised variant of it - so
	-- they answer the same question, and everything third person already does
	-- (the pinned rig, hiding the viewmodels) holds for them unchanged.
	birdseye = root ~= nil and inBirdseyeArena((root :: BasePart).Position)
	if birdseye then
		wanted = true
	end
	-- The Ashfall Throne is third person too - the same rig pushed back and
	-- given a boom of its own - so it answers the same question the same way,
	-- and the pinned rig and the hidden viewmodels hold for it unchanged.
	throne = root ~= nil and inThroneArena((root :: BasePart).Position)
	if throne then
		wanted = true
	end
	-- The Kraken's ship and its gullet are third person too - the SAME rig,
	-- one of them simply held further back (see KRAKEN_DISTANCE). They are
	-- listed separately rather than as one set because the distance is the
	-- only thing that differs and it differs by a factor of more than two.
	kraken = root ~= nil and inArenaSet((root :: BasePart).Position, KRAKEN_ARENAS, KRAKEN_REACH)
	krakenGullet = root ~= nil and inArenaSet((root :: BasePart).Position, KRAKEN_GULLET_ARENAS, KRAKEN_GULLET_REACH)
	if kraken or krakenGullet then
		wanted = true
	end
	-- The Ashfall Heart, act four of the Pyrelisk: a sealed interior, so the
	-- standard rig at the standard distance - the gullet's row, one fight over.
	-- It is a SEPARATE row from the Throne's (`throne`, above) on purpose: the
	-- summit and this room are two different places with two different rigs,
	-- and by act four a player is only ever in one of them.
	pyreliskHeart = root ~= nil and inArenaSet((root :: BasePart).Position, PYRELISK_HEART_ARENAS, PYRELISK_HEART_REACH)
	if pyreliskHeart then
		wanted = true
	end
	-- The Choirfloor is deliberately NOT listed here and has no rig of its own:
	-- the Gloomtrench fight runs in first person as of 2026-09-08. See the note
	-- where the gloom constants were, above.
	if wanted ~= thirdPerson then
		thirdPerson = wanted
		-- The viewmodels are parented to the camera, so they have to go: in
		-- third person you see your real character instead.
		Viewmodel.setHidden(wanted)
	end
end

local function onRenderStep(dt: number)
	updateMode()
	-- A cinematic camera is 200 studs from the character looking at something
	-- else entirely, and Roblox's first-person lock would spend every frame
	-- dragging it back onto the head - so an override is treated as third
	-- person for the mode's purposes, whatever the island says.
	if thirdPerson or override then
		lockThirdPerson()
	else
		lockFirstPerson()
	end
	-- The orbit's own frame goes in BEFORE every rig below, because every one
	-- of them reads yaw and pitch back off the frame it is handed.
	--
	-- ...but not the INPUT while a cinematic owns the camera: a right-drag
	-- during the intro would swing a camera the player cannot see the effect of
	-- and then hand the fight back on a bearing they never chose. `applyOrbit`
	-- still runs, because its output is the "normal" frame the override is
	-- handed and blends back to.
	if not override then
		updateOrbitInput()
	end
	applyOrbit()
	-- ...and last, because it overrides both while it is easing.
	applyBirdseye()
	-- ...and the Throne after it. Only one of the two can ever be non-zero
	-- (their arenas are 30k studs apart), so the order between them is free -
	-- what matters is that both run AFTER the two locks above.
	applyThrone()
	-- ...and the ship's list after every rig, because it rolls whatever frame
	-- they produced rather than producing one of its own.
	applyRoll()
	-- ...and the welded rod and weapon last of all, because the eases above are
	-- the last things that can still change what the viewmodels are doing this
	-- frame, and the trade is the answer to that question.
	applyWeldedTools()
	-- ...and the cinematic last of all, on top of the finished frame (so the
	-- welded tools stay force-visible and the viewmodels stay hidden through
	-- the third-person treatment above, by construction). The cursor is
	-- deliberately not touched on this path: the cutscene controller owns the
	-- pointer for as long as it owns the camera, and asserting MouseBehavior
	-- underneath it would fight whatever it set.
	if override then
		-- Fetched here rather than kept at file scope for the reason every rig
		-- above fetches it the same way: CurrentCamera is replaced on some
		-- respawns, and a cached one silently stops being the camera.
		local camera = Workspace.CurrentCamera
		local ok, frame = pcall(override :: any, camera.CFrame, dt)
		if ok and typeof(frame) == "CFrame" then
			camera.CFrame = frame
		elseif not ok then
			warn("[CameraController] override failed: " .. tostring(frame))
		end
		return
	end
	if cursorFree then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
	elseif thirdPerson then
		-- Third person, per the cursor model at the top of this file: the pointer
		-- moves FREELY (so a menu button is still reachable with it) and is
		-- pinned where it stands for as long as a right drag owns it. The system
		-- ICON stays off in both cases, because the pointer is drawn as a
		-- crosshair instead - CrosshairController puts its mark on the pointer's
		-- pixel every frame, and two pointers is what the player rejected.
		-- Asserted EVERY frame for the reason everything else in this function
		-- is - Roblox's camera scripts write these same two properties,
		-- including on the way out of first person.
		UserInputService.MouseBehavior = if orbiting
			then Enum.MouseBehavior.LockCurrentPosition
			else Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = false
	else
		UserInputService.MouseIconEnabled = false
	end
end

function CameraController.init()
	lockFirstPerson()
	UserInputService.MouseIconEnabled = false
	player.CharacterAdded:Connect(lockFirstPerson)
end

function CameraController.start()
	-- The drag's other half: the delta. `gameProcessed` is deliberately not
	-- consulted - the button that opens the drag is sunk session-wide by two
	-- other High-priority binds (see THE ORBIT above), so a drag that stopped
	-- whenever another action claimed the button is the bug being fixed, not a
	-- safety rail. `orbiting` is the only gate, and it already answers for the
	-- cursor, the camera mode and any open menu.
	--
	-- Mouse movement only reports a Delta while the cursor is locked, which is
	-- exactly and only while a drag is running - so this reads zero the rest of
	-- the time even before the gate.
	UserInputService.InputChanged:Connect(function(input: InputObject)
		if not orbiting or input.UserInputType ~= Enum.UserInputType.MouseMovement then
			return
		end
		-- Right on the screen is clockwise from above, which is DECREASING yaw
		-- in the fromEulerAnglesYXZ frame every rig here is built on; mouse
		-- down looks down. Pitch is clamped on the way in as well as in
		-- applyOrbit, so a drag against a rail can never run the number away.
		orbitYaw -= input.Delta.X * ORBIT_SPEED
		orbitPitch =
			math.clamp(orbitPitch - input.Delta.Y * ORBIT_SPEED * ORBIT_PITCH_TRIM, ORBIT_PITCH_FLOOR, ORBIT_PITCH_CEIL)
	end)

	RunService:BindToRenderStep("CameraController", Enum.RenderPriority.Camera.Value + 1, onRenderStep)
end

return CameraController
