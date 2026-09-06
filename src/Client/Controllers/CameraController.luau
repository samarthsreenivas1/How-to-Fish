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

-- THIRD PERSON IN THE BOSS ARENA (user, 2026-08-29: "the arena should go
-- third person making the user dodge in third"). The Kraken's arms sweep the
-- whole whirlpool and its head fills the middle - you cannot read an attack
-- coming from behind you down a first-person barrel. Keyed to WHERE you are,
-- not to whether the boss is up, so the camera doesn't swap mid-fight.
local THIRD_PERSON_ISLANDS = { maelstrom = true }
local THIRD_PERSON_DISTANCE = 26

local thirdPerson = false

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

-- THIRD PERSON IN THE GLOOMTRENCH (Noctyss and the Lantern Choir,
-- 2026-09-01). The same machinery a FOURTH time, and a fourth answer, because
-- this fight asks for two reads at once that first person cannot hold
-- together:
--
--   * THE CHOIR. Seven lanterns hang ~30 studs up on a ring of radius ~23
--     (NoctyssPath: sockets at r 34, and each stalk's crook carries its bulb
--     ~11 studs inward over the pit), and the fight's central puzzle is
--     spotting which one breathes half a cycle out of step with the other six
--     (PULSE_PERIOD, TRUE_LURE_OFFSET). That is a SIMULTANEOUS comparison
--     across seven lights: the tell is a phase relationship, so it cannot be
--     read by looking at them one at a time, only by holding all seven at
--     once.
--   * THE FLOOR. The signature attack is a 9-degree wedge of light swept
--     across the stone out to r 74 (BEAM_HALF_ANGLE, BEAM_REACH), dodged by
--     reading where it is GOING, which means looking down and ahead.
--
-- From a first-person stance at r 50 the near lantern is ~36 degrees up and
-- the far one ~24, so holding the choir means looking up ~30 degrees - while
-- the ground the wedge crosses is 20-40 degrees down. That is 55-75 degrees
-- apart in a 70-degree frame: the two reads are mutually exclusive, and a
-- wedge arriving from behind is unreadable by construction.
--
-- THE FIX IS NOT MORE FRAME, IT IS A DIFFERENT EYE HEIGHT. Put the camera
-- ABOVE the lantern plane and the conflict collapses - the choir stops being
-- overhead and becomes a near-level band, so BOTH reads are downward and one
-- ordinary frame holds them. It is also the only lever available: flattening
-- the choir from head height instead would need the eye 100+ studs out, and
-- this is a NEAR-BLACK arena lit only by the lanterns themselves, where that
-- far back there is nothing to see and no way to find your own body.
--
-- Keyed to the ARENA's centre (BossArenas) for the Careenage's and the
-- Throne's reason: the Choirfloor is a lair 24k studs out in open water,
-- where Islands.islandAt is nil and the island test above can never fire.
local GLOOM_ARENAS = { gloom = true }

-- How far from the arena centre the mode holds. The Choirfloor is walkable
-- stone to r 68, with boundary teeth at r 69-75 and a foam ring out to 91
-- (arena_gen.py GL_PROFILE), so 140 covers the shelf, its edge, and the water
-- you get knocked into. Erring wide is free out here for BIRDSEYE_REACH's
-- reason - the nearest other content is thousands of studs away.
--
-- NO height gate, unlike the Throne, and deliberately so: this arena sits at
-- the waterline, and the lowest place a player can legitimately stand is the
-- PIT itself (bed at -7.5, water at -5, NoctyssPath PIT_R). That is inside
-- the fight - it is where the maw comes up - so it must keep the camera.
local GLOOM_REACH = 140

-- THE EYE, given in the units the reasoning is in rather than as a pitch and
-- a distance: how far it floats ABOVE the aim point, and how far BEHIND it.
--
-- LIFT 25, over a focus riding 3.5 studs above the root (so arena-local y ~8
-- on the shelf at 1.5), puts the eye at y ~33 - about three studs clear of
-- the lanterns' own y ~30. THAT CLEARANCE IS THE WHOLE TREATMENT. From there,
-- with the player at r 44 facing in, the near lantern sits 2.9 degrees BELOW
-- the horizon and the far one 1.6, and the flanking pair 2.0 degrees below
-- and ~16 off axis: all seven inside a band a degree and a half deep, near
-- the middle of the screen, side by side. Seven lights in one glance is
-- exactly the comparison the fight is asking for, and it is stable - the
-- band's depth barely moves as the player walks the shelf, because it is set
-- by the eye's height over the bulbs and not by where either of them stands.
--
-- SETBACK 38 buys the other read. It puts the player's own feet 40 degrees
-- below the eye's horizon and the stone 20 studs ahead of them at 28, so the
-- choir and the ground the wedge is crossing end up ~38 degrees apart against
-- 55-75 in first person - and 38 fits inside a 70-degree frame with the
-- character sitting between the two.
--
-- It is also about as short as it can be, and about as long. Shorter steepens
-- the look onto the player and pushes the choir up out of frame; longer walks
-- the eye further into the dark. At the 45.5 studs these two make, the
-- character is ~8% of screen height - the birdseye orbit's note on ~5% is
-- where you stop being able to judge your own body against a gap - and the
-- lit choir is still the brightest thing on screen, which in an arena with no
-- other light is the constraint that decides this number.
local GLOOM_LIFT = 25
local GLOOM_SETBACK = 38
local GLOOM_FOCUS_LIFT = 3.5
local GLOOM_DISTANCE = math.sqrt(GLOOM_LIFT * GLOOM_LIFT + GLOOM_SETBACK * GLOOM_SETBACK)

-- THE BOOM, as the Throne does it: where the EYE hangs, never the direction
-- the camera looks. Pinned at the 33.3 degrees LIFT and SETBACK describe
-- whenever the player is level or looking up - which is what holds the eye
-- above the lantern plane while they put the crosshair on a bulb - and
-- allowed to follow the aim down to 60 so that a hard look at the floor still
-- lifts the camera over it, the way the birdseye orbit does.
--
-- The pin is load-bearing here in a way it is not even on the Throne. If the
-- eye followed the aim (the birdseye rig, and Roblox's own Classic camera),
-- then looking down to read the sweep would drop the eye BELOW the lanterns
-- and swing the choir back overhead - exactly the first-person problem this
-- mode exists to remove, re-created the moment the mode is used.
local GLOOM_BOOM_CEIL = -math.atan2(GLOOM_LIFT, GLOOM_SETBACK)
local GLOOM_BOOM_FLOOR = -math.rad(60)

-- What the camera may LOOK along. This is the player's own pitch and these
-- are guard rails, not a band the mode drives - RangedController resolves
-- every shot off camera.CFrame.LookVector, so the look direction is the AIM
-- and this mode must not take it. The ceiling clears the maw's brow, which
-- rears ~44 studs up through the middle (NoctyssPath MAW.Y_UP 30.7 plus the
-- skull) - only ~10 degrees above THIS eye from the pit's edge, but a stalk
-- leaning overhead wants more. The floor reaches into the pit and into the
-- mouth during the punish window, where the party stands on the lower jaw.
local GLOOM_PITCH_CEIL = math.rad(45)
local GLOOM_PITCH_FLOOR = -math.rad(70)

-- Same exponential approach as the other two eases, for the same reasons: the
-- mode can flip while the player is running, and an approach is frame-rate
-- independent and can reverse mid-flight without a jump.
local GLOOM_EASE_TAU = 0.28
local GLOOM_SETTLED = 0.002

-- The six shadow fins stand 13-19 studs tall (arena_gen.py build_gl_fins), so
-- at y 33 the eye simply clears them and they never pull the camera in - see
-- the note on isGloom for what that costs and who owns it. What DOES block is
-- the boundary teeth at r 69-75, once the fight drifts to the rim and the eye
-- hangs out past the shelf's edge. Same pull-in as the other two modes. The
-- distance floor is higher than the Throne's because coming in lowers the eye
-- along the boom, back toward the lantern plane: the mode is degrading
-- whenever this fires, and 12 keeps it a frame rather than the inside of the
-- character's shoulders while the player steps back off the edge.
local GLOOM_CLEARANCE = 1.6
local GLOOM_MIN_DISTANCE = 12

local gloom = false
local gloomBlend = 0 -- 0 = the camera as it is everywhere else, 1 = the raised orbit
local gloomAt = 0 -- os.clock of the last frame, for the ease
local gloomHiding = false -- holding the viewmodel hidden through the ease OUT

-- Is `position` on the Choirfloor? Horizontal reach only, for the reason
-- GLOOM_REACH gives.
local function inGloomArena(position: Vector3): boolean
	for islandId in GLOOM_ARENAS do
		local arena = BossArenas.items[islandId]
		local center = arena and arena.center
		if center then
			local d = Vector3.new(position.X - center.X, 0, position.Z - center.Z).Magnitude
			if d <= GLOOM_REACH then
				return true
			end
		end
	end
	return false
end

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

-- True on the Choirfloor's raised orbit (another third-person variant, so
-- isThirdPerson is true there as well). For anything that has to lay out
-- differently when the camera is above the lantern plane looking down.
--
-- ONE KNOWN CONSEQUENCE, recorded here because it is not this file's to fix:
-- the arena's stated trade - stand behind a shadow fin and lose your view of
-- the arena - was a FIRST-PERSON property. A fin is 13-19 studs tall and the
-- lanterns hang at 30, so from a head-height eye a fin does occlude the light
-- it is sheltering you from; from an eye at 33 it cannot occlude anything up
-- there, and shelter no longer costs the choir read. What it still costs is
-- the floor read - a fin standing between the player and the pit fills the
-- near ground in the frame, which is where a sweeping wedge arrives from - so
-- the trade survives with its terms swapped. If the fight wants the original
-- cost back, that belongs to the fins or to NoctyssPath's shadow test, not
-- here: no camera that can hold seven lanterns at once can also be hidden by
-- something half their height.
function CameraController.isGloom(): boolean
	return gloom
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
	if player.CameraMaxZoomDistance ~= THIRD_PERSON_DISTANCE then
		player.CameraMinZoomDistance = THIRD_PERSON_DISTANCE
		player.CameraMaxZoomDistance = THIRD_PERSON_DISTANCE
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

-- The Choirfloor's orbit for one frame. Structurally the Throne's - yaw AND
-- pitch read back off the frame Roblox's own camera scripts just produced, so
-- the mouse turns and aims as it does everywhere else, the character walks
-- camera-relative, and the crosshair is still the middle of the screen and
-- still goes where the player pointed it - with the two halves separated for
-- this fight's own reason: the boom holds the eye ABOVE the lanterns while
-- the aim travels from a bulb on the near-horizon down to the stone the wedge
-- is crossing. Both are in the same frame, so the aim is free to move between
-- them without the mode chasing it.
local function gloomFrame(root: BasePart, base: CFrame, character: Model): CFrame
	local focus = root.Position + Vector3.new(0, GLOOM_FOCUS_LIFT, 0)
	local look = base.LookVector
	local yaw = math.atan2(-look.X, -look.Z)
	local pitch = math.asin(math.clamp(look.Y, -1, 1))
	local aimed = math.clamp(pitch, GLOOM_PITCH_FLOOR, GLOOM_PITCH_CEIL)
	local boom = math.clamp(aimed, GLOOM_BOOM_FLOOR, GLOOM_BOOM_CEIL)
	local dir = CFrame.fromEulerAnglesYXZ(aimed, yaw, 0).LookVector
	local back = CFrame.fromEulerAnglesYXZ(boom, yaw, 0).LookVector
	local distance = GLOOM_DISTANCE
	local blocked = Workspace:Raycast(focus, -back * distance, occlusionParams(character))
	if blocked then
		distance = math.max((blocked.Position - focus).Magnitude - GLOOM_CLEARANCE, GLOOM_MIN_DISTANCE)
	end
	local eye = focus - back * distance
	return CFrame.lookAt(eye, eye + dir)
end

-- Ease the Choirfloor's orbit in and out. Line for line the Throne's ease,
-- and its own state for the same reason that one is not the birdseye's: the
-- three arenas are tens of thousands of studs apart, only one can ever be
-- easing, and a shared blend would make each mode's bugs the others'.
--
-- The ease OUT holds the third-person rig up while it runs, and everything
-- that restores FIRST PERSON hangs off `gloomBlend` reaching 0 - updateMode
-- drops `gloom` the instant the player leaves the reach (walking out, dying,
-- being teleported home), the blend runs down, and until it does this
-- function is the only thing pinning Classic. Once it is 0 the function
-- returns before touching the camera and lockFirstPerson, which runs every
-- frame regardless, has the last word.
local function applyGloom()
	local now = os.clock()
	local dt = math.clamp(now - gloomAt, 0, 0.25)
	gloomAt = now

	local target = if gloom then 1 else 0
	gloomBlend += (target - gloomBlend) * (1 - math.exp(-dt / GLOOM_EASE_TAU))
	if math.abs(target - gloomBlend) < GLOOM_SETTLED then
		gloomBlend = target
	end

	if gloomBlend <= 0 then
		if gloomHiding then
			gloomHiding = false
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

	-- The zoom pin travels with the blend, same as the other two orbits:
	-- arriving dollies out from wherever the camera was, leaving reels it back
	-- in, and the mode is what the game says it is rather than what was last
	-- scrolled to.
	if player.CameraMode ~= Enum.CameraMode.Classic then
		player.CameraMode = Enum.CameraMode.Classic
	end
	local pinned = 0.5 + (GLOOM_DISTANCE - 0.5) * gloomBlend
	if player.CameraMaxZoomDistance ~= pinned then
		player.CameraMinZoomDistance = pinned
		player.CameraMaxZoomDistance = pinned
	end
	gloomHiding = true
	Viewmodel.setHidden(true)

	camera.CFrame = camera.CFrame:Lerp(gloomFrame(root, camera.CFrame, character :: Model), gloomBlend)
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
	-- The Choirfloor is third person too - the Throne's rig, raised over the
	-- choir instead of pushed back from a colossus - so it answers the same
	-- question the same way, and the pinned rig and the hidden viewmodels hold
	-- for it unchanged.
	gloom = root ~= nil and inGloomArena((root :: BasePart).Position)
	if gloom then
		wanted = true
	end
	if wanted ~= thirdPerson then
		thirdPerson = wanted
		-- The viewmodels are parented to the camera, so they have to go: in
		-- third person you see your real character instead.
		Viewmodel.setHidden(wanted)
	end
end

local function onRenderStep()
	updateMode()
	if thirdPerson then
		lockThirdPerson()
	else
		lockFirstPerson()
	end
	-- ...and last, because it overrides both while it is easing.
	applyBirdseye()
	-- ...and the Throne after it. Only one of the two can ever be non-zero
	-- (their arenas are 30k studs apart), so the order between them is free -
	-- what matters is that both run AFTER the two locks above.
	applyThrone()
	-- ...and the Choirfloor last, on the same terms: the three arenas are tens
	-- of thousands of studs apart, so at most one blend is ever non-zero and
	-- the order among them is free.
	applyGloom()
	if cursorFree then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
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
	RunService:BindToRenderStep("CameraController", Enum.RenderPriority.Camera.Value + 1, onRenderStep)
end

return CameraController
