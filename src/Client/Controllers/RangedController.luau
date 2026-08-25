--!nonstrict
-- RangedController.luau
-- Ranged input: the trigger for any equipped Weapons row with a `ranged`
-- block (docs/revamp-plan.md Systems §1). CombatController deliberately
-- stands down while a gun is out, so left click / tap is this controller's:
--   single  - one shot per press
--   auto    - fires every `cooldown` while the button is held
--   scoped  - single, plus right-click hold zooms the camera to `zoomFov`
--
-- Client predicts, server owns truth (the standing rule): the cooldown,
-- magazine count and reload clock are mirrored here so the player sees and
-- hears exactly the shots the server will accept - CombatService re-runs the
-- same gates with its token bucket and its own magazine, and a client that
-- lies just wastes remotes. Every shot is a camera ray sent through
-- RequestShoot; the tracer itself comes back on ShotFired (RangedFxController)
-- so every client, the shooter included, draws the server's truth. What IS
-- instant and local: the viewmodel kick, the muzzle sound, the ammo HUD.
--
-- The ammo readout is one small FredokaOne line above the hotbar corner -
-- "12 / 24", amber while reloading - built here rather than in the UI kit
-- because it's a single label, not a menu.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Equipment = require(Shared.Config.Equipment)
local Tuning = require(Shared.Config.Tuning)
local Weapons = require(Shared.Data.Weapons)
local Remotes = require(Shared.Net.Remotes)

local WeaponViewmodelController = require(script.Parent.WeaponViewmodelController)
local Sfx = require(script.Parent.Parent.Modules.Sfx)
local Theme = require(script.Parent.Parent.UI.Theme)

local player = Players.LocalPlayer

local RangedController = {}

local FIRE_ACTION = "RangedFire"
local ZOOM_ACTION = "RangedZoom"

local DEFAULT_FOV = 70
local ZOOM_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- ---------------------------------------------------------------- state

local bound = false
local firing = false -- the button is down (matters for auto)
local zoomed = false
local lastShotAt = 0
local shotsInMag = 0
local reloadUntil = 0
local stateWeaponId: string? = nil -- which weapon the mirror above describes

-- ---------------------------------------------------------------- ammo HUD

local ammoLabel: TextLabel? = nil

local function ensureHud(): TextLabel
	if ammoLabel then
		return ammoLabel
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "RangedHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 5

	local label = Instance.new("TextLabel")
	label.Name = "Ammo"
	label.AnchorPoint = Vector2.new(0.5, 1)
	label.Position = UDim2.new(0.5, 0, 1, -96)
	label.Size = UDim2.fromOffset(220, 26)
	label.BackgroundTransparency = 1
	label.Font = Theme.Font.header
	label.TextSize = 22
	label.TextColor3 = Theme.Color.text
	label.TextStrokeTransparency = 0.6
	label.Text = ""
	label.Parent = gui

	gui.Parent = player:WaitForChild("PlayerGui")
	ammoLabel = label
	return label
end

local function updateHud(ranged)
	local label = ensureHud()
	if not ranged then
		label.Text = ""
		return
	end
	if os.clock() < reloadUntil then
		label.TextColor3 = Theme.Color.gold or Color3.fromRGB(240, 196, 84)
		label.Text = "RELOADING..."
	else
		label.TextColor3 = Theme.Color.text
		label.Text = string.format("%d / %d", shotsInMag, ranged.magazine)
	end
end

-- ---------------------------------------------------------------- loadout

-- The equipped Weapons row when it's a gun; nil for a rod, fists, or melee.
local function currentRangedWeapon()
	if player:GetAttribute(Equipment.ATTRIBUTE) ~= Equipment.WEAPON then
		return nil
	end
	local weaponId = player:GetAttribute(Equipment.WEAPON_ATTRIBUTE)
	local weapon = weaponId and Weapons.items[weaponId]
	if weapon and weapon.ranged then
		return weapon
	end
	return nil
end

-- ---------------------------------------------------------------- zoom

local function setZoom(on: boolean, ranged)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	zoomed = on and ranged ~= nil
	local fov = if zoomed then (ranged.zoomFov or Tuning.Ranged.DEFAULT_ZOOM_FOV) else DEFAULT_FOV
	TweenService:Create(camera, ZOOM_TWEEN, { FieldOfView = fov }):Play()
end

-- ---------------------------------------------------------------- firing

-- One predicted shot: gate on the mirrored cooldown/magazine, kick, sound,
-- and ask the server. The server re-validates everything.
local function tryFire()
	local weapon = currentRangedWeapon()
	if not weapon then
		return
	end
	local ranged = weapon.ranged
	local now = os.clock()

	if stateWeaponId ~= weapon.id then
		-- Fresh gun in hand: full magazine, no reload (mirrors the server).
		stateWeaponId = weapon.id
		shotsInMag = ranged.magazine
		reloadUntil = 0
	end

	if now < reloadUntil then
		return
	end
	if shotsInMag <= 0 then
		shotsInMag = ranged.magazine -- reload finished on the server too
	end
	if now - lastShotAt < weapon.cooldown then
		return
	end
	lastShotAt = now

	shotsInMag -= 1
	if shotsInMag <= 0 and ranged.reloadTime > 0 then
		reloadUntil = now + ranged.reloadTime
		Sfx.play("gunReload")
	end

	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local origin = camera.CFrame.Position
	local look = camera.CFrame.LookVector

	-- Instant local feel; the tracer itself arrives on ShotFired.
	WeaponViewmodelController.kick(if ranged.pellets then 1.6 elseif ranged.fireMode == "auto" then 0.55 else 1)
	Sfx.play(if ranged.arc then "bowFire" else "gunFire")
	Remotes.RequestShoot:FireServer(origin, look)
	updateHud(ranged)
end

-- ---------------------------------------------------------------- binding

local function onFireAction(_, state: Enum.UserInputState)
	if state == Enum.UserInputState.Begin then
		firing = true
		tryFire()
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		firing = false
	end
	return Enum.ContextActionResult.Sink
end

local function onZoomAction(_, state: Enum.UserInputState)
	local weapon = currentRangedWeapon()
	local ranged = weapon and weapon.ranged
	if not ranged or ranged.fireMode ~= "scoped" then
		return Enum.ContextActionResult.Pass
	end
	if state == Enum.UserInputState.Begin then
		setZoom(true, ranged)
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		setZoom(false, ranged)
	end
	return Enum.ContextActionResult.Sink
end

local function bindFire()
	if bound then
		return
	end
	bound = true
	ContextActionService:BindActionAtPriority(
		FIRE_ACTION,
		onFireAction,
		false,
		Enum.ContextActionPriority.High.Value,
		Enum.UserInputType.MouseButton1,
		Enum.UserInputType.Touch
	)
	-- Right-click zoom only matters for scoped rows, but binding it always
	-- while a gun is out keeps the handler the one place that decides.
	ContextActionService:BindActionAtPriority(
		ZOOM_ACTION,
		onZoomAction,
		false,
		Enum.ContextActionPriority.High.Value,
		Enum.UserInputType.MouseButton2
	)
end

local function unbindFire()
	if not bound then
		return
	end
	bound = false
	firing = false
	ContextActionService:UnbindAction(FIRE_ACTION)
	ContextActionService:UnbindAction(ZOOM_ACTION)
	setZoom(false, nil)
end

local function refresh()
	local weapon = currentRangedWeapon()
	if weapon then
		if stateWeaponId ~= weapon.id then
			stateWeaponId = weapon.id
			shotsInMag = weapon.ranged.magazine
			reloadUntil = 0
		end
		bindFire()
		updateHud(weapon.ranged)
	else
		unbindFire()
		updateHud(nil)
	end
end

-- ---------------------------------------------------------------- lifecycle

function RangedController.init()
	ensureHud()
end

function RangedController.start()
	player:GetAttributeChangedSignal(Equipment.ATTRIBUTE):Connect(refresh)
	player:GetAttributeChangedSignal(Equipment.WEAPON_ATTRIBUTE):Connect(refresh)
	refresh()

	-- The auto loop and the reload countdown: while the trigger is held on an
	-- auto weapon, keep firing at its cooldown; and tick the HUD through a
	-- reload so the amber line flips back to numbers on time.
	RunService.Heartbeat:Connect(function()
		local weapon = currentRangedWeapon()
		if not weapon then
			return
		end
		if firing and weapon.ranged.fireMode == "auto" then
			tryFire()
		end
		if reloadUntil > 0 and os.clock() >= reloadUntil then
			reloadUntil = 0
			shotsInMag = weapon.ranged.magazine
			updateHud(weapon.ranged)
		end
	end)
end

return RangedController
