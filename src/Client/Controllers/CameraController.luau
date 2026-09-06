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
