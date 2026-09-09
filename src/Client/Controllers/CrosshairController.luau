--!nonstrict
-- CrosshairController.luau
-- The aiming mark, and ONLY in third person (user, 2026-09-08: "you should
-- ... implement a crosshair and allow the user to shoot in third person when
-- you're in a boss").
--
-- WHY THIRD PERSON NEEDS ONE AND FIRST PERSON DOES NOT. In first person the
-- camera sits at the head and the cursor is locked dead centre with the icon
-- hidden - the middle of the screen is where you are looking, so there is
-- nothing to mark. The boss arenas break both halves of that: the camera
-- stands 26 to 64 studs back on a rig of its own, and (CameraController's
-- cursor model) the cursor is FREE there, so the pointer is wherever the
-- player last left it and is emphatically NOT the aim. Without a mark the
-- player has no way at all to know where a shot will go.
--
-- WHERE IT SITS, AND WHY THAT IS THE TRUE AIM POINT. Every ranged shot is
-- resolved by RangedController.shotRay, which searches down
-- `camera.CFrame.LookVector` from the camera's position and then fires from
-- the CHARACTER at whatever it found. That ray is the camera's optical axis,
-- which lands on exactly one pixel: the centre of the viewport. So the mark
-- is centred and nothing about it is ever recomputed - a crosshair that had
-- to be positioned per frame would be a crosshair that could disagree with
-- the shot. IgnoreGuiInset is what makes the two the same point: the 3D
-- viewport is the whole window (Camera.ViewportSize), and only an
-- inset-ignoring ScreenGui shares those coordinates. With the inset on, the
-- GUI's centre would sit 18 pixels below the optical axis - a small error
-- that is a whole boss-sized miss at 200 studs.
--
-- ONE THING IT DELIBERATELY DOES NOT DO: eat the click. Everything here is a
-- Frame with Active left false, so the shot that the mark is aiming lands in
-- RangedController's ContextActionService bind instead of in the UI - a
-- clickable widget parked over the middle of the screen would swallow every
-- trigger pull in the game.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Equipment = require(Shared.Config.Equipment)
local Weapons = require(Shared.Data.Weapons)

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

-- Is a gun (any Weapons row with a `ranged` block) in the player's hands?
-- Read straight off the replicated Equipment attributes, the way every other
-- controller reads the loadout - RangedController gates its own trigger on
-- exactly this pair, so the mark is shown when and only when there is a
-- trigger behind it.
local function rangedEquipped(): boolean
	if player:GetAttribute(Equipment.ATTRIBUTE) ~= Equipment.WEAPON then
		return false
	end
	local weaponId = player:GetAttribute(Equipment.WEAPON_ATTRIBUTE)
	local weapon = weaponId and Weapons.items[weaponId]
	return weapon ~= nil and weapon.ranged ~= nil
end

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
	-- The two properties the aim depends on: no inset (so the GUI's centre is
	-- the camera's optical axis) and nothing between the click and the game.
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

-- Visible exactly when all three hold: a third-person camera is up (any of
-- the arena rigs - they are all third-person variants and all answer
-- isThirdPerson), a gun is out, and no menu has borrowed the cursor. The
-- menu test is the same one the camera uses, so the mark cannot be left
-- floating over an open inventory.
--
-- Polled on the render step rather than driven by events, because the camera
-- mode itself is: CameraController decides it every frame from where the
-- character is standing, and there is no signal to listen to.
local function refresh()
	local want = CameraController.isThirdPerson() and not CameraController.isCursorFree() and rangedEquipped()
	if want == shown then
		return
	end
	shown = want
	local mark = ensureGui()
	mark.Visible = want
end

function CrosshairController.init()
	ensureGui()
end

function CrosshairController.start()
	RunService.RenderStepped:Connect(refresh)
	refresh()
end

return CrosshairController
