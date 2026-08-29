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

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Islands = require(Shared.Config.Islands)

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

-- Which mode this place wants, from where the character is standing.
local function updateMode()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local wanted = false
	if root then
		local islandId = Islands.islandAt((root :: BasePart).Position)
		wanted = islandId ~= nil and THIRD_PERSON_ISLANDS[islandId] == true
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
