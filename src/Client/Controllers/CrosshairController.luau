--!nonstrict
-- CrosshairController.luau
-- The aiming mark, and ONLY in third person. THE MARK IS THE CURSOR (user,
-- 2026-09-08, rejecting the first build's free arrow plus a separate centred
-- mark: "the crosshair still doesnt work. you need to make it so that the
-- cursor is the crosshair and the user shoots wherever their crosshair is").
--
-- So there is exactly ONE pointer on screen in third person. The system arrow
-- is switched off (CameraController's render step owns MouseIconEnabled) and
-- this mark is drawn at the pointer's live pixel every frame instead - it
-- moves with the mouse, reaches menu buttons like any cursor, and is the thing
-- the shot goes through.
--
-- WHY FIRST PERSON HAS NONE. There the cursor is locked dead centre with the
-- icon hidden and the viewmodel is on screen: the middle of the frame is where
-- you are looking, the weapon is drawn pointing at it, and there is nothing
-- for a mark to tell you that the gun in your hands does not.
--
-- WHERE IT SITS, AND WHY THAT IS THE TRUE AIM POINT. Every ranged shot is
-- resolved by RangedController.shotRay, whose aim ray in third person is
-- `camera:ViewportPointToRay` at UserInputService:GetMouseLocation() - the
-- pointer's pixel. This mark is positioned from the SAME call in the same
-- frame, so the two cannot disagree about where the player is aiming.
--
-- ONE COORDINATE SPACE, NOTHING ADDED TO IT. GetMouseLocation answers in
-- viewport space (top-left of the 3D viewport is (0, 0); the 36-pixel top bar
-- is not subtracted), ViewportPointToRay consumes that same space, and an
-- IgnoreGuiInset ScreenGui - which is what this one is - lays out in it too.
-- Hence Position is the raw offset with no correction term anywhere. Turn the
-- inset back on and this frame would draw 36 pixels below the pixel it is
-- aiming, which at 200 studs is a whole boss-sized miss; the matching trap on
-- the ray side is reaching for ScreenPointToRay, which is the inset-offset
-- twin of the call used here.
--
-- ONE THING IT DELIBERATELY DOES NOT DO: eat the click. Everything here is a
-- Frame with Active left false, so the shot that the mark is aiming lands in
-- RangedController's ContextActionService bind instead of in the UI - a
-- clickable widget parked over the middle of the screen would swallow every
-- trigger pull in the game.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local UserInputService = game:GetService("UserInputService")

local CameraController = require(script.Parent.CameraController)
local Theme = require(script.Parent.Parent.UI.Theme)

local player = Players.LocalPlayer

local CrosshairController = {}

-- The mark: four ticks around a gap, plus a centre dot. The GAP is the part
-- that matters - a solid cross hides the thing you are shooting at, and at
-- these ranges a boss's weak point can be smaller on screen than the mark
-- itself. 22 pixels across, which is small enough to ignore while dodging and
-- big enough to find in the Gloomtrench's near-black.
local SPAN = 22 -- overall square the mark occupies
local TICK_LONG = 6 -- length of one arm
local TICK_THICK = 2
local GAP = 4 -- from the centre to the inner end of an arm
local DOT = 2

-- Ink outline, same as every other sticker-styled element in the kit: the
-- mark has to read against the Careenage's white sand AND the Choirfloor's
-- black stone, and a white-on-white crosshair is no crosshair.
local OUTLINE = 1

local root: Frame? = nil
local shown = false

local function tick(parent: Frame, name: string, position: UDim2, size: UDim2)
	local arm = Instance.new("Frame")
	arm.Name = name
	arm.AnchorPoint = Vector2.new(0.5, 0.5)
	arm.Position = position
	arm.Size = size
	arm.BackgroundColor3 = Theme.Color.text
	arm.BorderSizePixel = 0
	arm.Active = false -- never sink the trigger; see the header
	arm.Parent = parent

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = OUTLINE
	stroke.Color = Theme.Color.ink
	stroke.Transparency = 0.25
	stroke.Parent = arm
end

local function ensureGui(): Frame
	if root then
		return root :: Frame
	end
	local screen = Instance.new("ScreenGui")
	screen.Name = "Crosshair"
	screen.ResetOnSpawn = false
	-- The two properties the aim depends on: no inset (so this GUI lays out in
	-- the same viewport pixels the pointer is reported in and the ray is cast
	-- through - see the header) and nothing between the click and the game.
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 4 -- under the ammo readout (5) and every menu

	local frame = Instance.new("Frame")
	frame.Name = "Mark"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromOffset(SPAN, SPAN)
	frame.BackgroundTransparency = 1
	frame.Active = false
	frame.Visible = false
	frame.Parent = screen

	local half = GAP + TICK_LONG / 2
	tick(frame, "Up", UDim2.new(0.5, 0, 0.5, -half), UDim2.fromOffset(TICK_THICK, TICK_LONG))
	tick(frame, "Down", UDim2.new(0.5, 0, 0.5, half), UDim2.fromOffset(TICK_THICK, TICK_LONG))
	tick(frame, "Left", UDim2.new(0.5, -half, 0.5, 0), UDim2.fromOffset(TICK_LONG, TICK_THICK))
	tick(frame, "Right", UDim2.new(0.5, half, 0.5, 0), UDim2.fromOffset(TICK_LONG, TICK_THICK))
	tick(frame, "Dot", UDim2.fromScale(0.5, 0.5), UDim2.fromOffset(DOT, DOT))

	screen.Parent = player:WaitForChild("PlayerGui")
	root = frame
	return frame
end

-- Visible exactly when two things hold: a third-person camera is up (any of
-- the arena rigs - they are all third-person variants and all answer
-- isThirdPerson), and no menu has borrowed the cursor. The menu test is the
-- same one the camera uses, so the mark cannot be left floating over an open
-- inventory - there the system arrow comes back and is the pointer again.
--
-- THE "GUN IS OUT" GATE IS GONE, deliberately. It made sense while this was a
-- separate mark laid over a real cursor; now that the mark IS the cursor, the
-- gate would leave third person with no pointer at all every time the player
-- put the rod away. The pointer has to be SOMETHING at all times, and a
-- crosshair with a rod in hand costs nothing (RangedController still gates the
-- trigger on the loadout, so an empty-handed click fires nothing).
--
-- Polled on the render step rather than driven by events, because the camera
-- mode itself is: CameraController decides it every frame from where the
-- character is standing, and there is no signal to listen to.
local function refresh()
	local want = CameraController.isThirdPerson() and not CameraController.isCursorFree()
	local mark = ensureGui()
	if want ~= shown then
		shown = want
		mark.Visible = want
	end
	if not want then
		return
	end
	-- The pointer's live pixel, in the one space this file and shotRay share
	-- (see the header). Positioned every frame, from the same call the shot
	-- resolves through, so the mark and the ray cannot drift apart.
	--
	-- WHILE A RIGHT-DRAG IS ORBITING the camera, MouseBehavior is
	-- LockCurrentPosition: the pointer is pinned where the drag caught it, this
	-- call keeps answering that pixel, the mark holds still there, and a left
	-- click mid-orbit fires through it. Nothing here has to know about the
	-- orbit - the pin does all of it.
	--
	-- NO MOUSE, NO MOVING MARK. On touch there is no pointer to be - the last
	-- touch is where a finger left the glass, not where the player is aiming -
	-- so the mark stays centred and RangedController's aimRay keeps firing down
	-- the optical axis for exactly the same reason. That pair is mobile's
	-- shipped behaviour, unchanged by any of this.
	if not UserInputService.MouseEnabled then
		mark.Position = UDim2.fromScale(0.5, 0.5)
		return
	end
	local at = UserInputService:GetMouseLocation()
	mark.Position = UDim2.fromOffset(at.X, at.Y)
end

function CrosshairController.init()
	ensureGui()
end

function CrosshairController.start()
	RunService.RenderStepped:Connect(refresh)
	refresh()
end

return CrosshairController
