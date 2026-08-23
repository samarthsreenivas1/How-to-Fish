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
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

local CameraController = {}

local cursorFree = false

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

local function onRenderStep()
	lockFirstPerson()
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
