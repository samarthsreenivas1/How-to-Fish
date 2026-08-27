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
local UserInputService = game:GetService("UserInputService")
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

-- Per-WEAPON mirrors of the server's persistent gun state (CombatService
-- keeps its magazine / reload clock / bucket per (player, weaponId) across
-- swaps, so swapping guns and back must show the old partial magazine, not
-- a fresh one - the server would silently refuse the shots the fresh-looking
-- HUD promised). Same lifetime as the server's: reset only on a new session.
local mirrors: { [string]: { shotsInMag: number, reloadUntil: number, lastShotAt: number } } = {}

local function mirrorFor(weapon)
	local mirror = mirrors[weapon.id]
	if not mirror then
		mirror = { shotsInMag = weapon.ranged.magazine, reloadUntil = 0, lastShotAt = 0 }
		mirrors[weapon.id] = mirror
	end
	return mirror
end

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

local function updateHud(weapon)
	local label = ensureHud()
	if not weapon then
		label.Text = ""
		return
	end
	local mirror = mirrorFor(weapon)
	if os.clock() < mirror.reloadUntil then
		label.TextColor3 = Theme.Color.gold or Color3.fromRGB(240, 196, 84)
		label.Text = "RELOADING..."
	else
		label.TextColor3 = Theme.Color.text
		label.Text = string.format("%d / %d", mirror.shotsInMag, weapon.ranged.magazine)
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
	local mirror = mirrorFor(weapon)

	if now < mirror.reloadUntil then
		return
	end
	if mirror.shotsInMag <= 0 then
		mirror.shotsInMag = ranged.magazine -- reload finished on the server too
	end
	if now - mirror.lastShotAt < weapon.cooldown then
		return
	end
	mirror.lastShotAt = now

	mirror.shotsInMag -= 1
	if mirror.shotsInMag <= 0 and ranged.reloadTime > 0 then
		mirror.reloadUntil = now + ranged.reloadTime
		Sfx.play("gunReload")
		-- The reload choreography (mag out by hand, cylinder work...) fills
		-- the server's reload window exactly.
		WeaponViewmodelController.reloadAnim(weapon.model and weapon.model.variant, ranged.reloadTime)
	elseif ranged.reloadTime <= 0 then
		-- Per-shot loaders (bow, crossbow, flintlock, harpooner): the
		-- cooldown IS the reload, so the re-nock / re-ram plays after every
		-- shot inside it, leaving a beat of aim time at the end.
		WeaponViewmodelController.reloadAnim(weapon.model and weapon.model.variant, weapon.cooldown * 0.85)
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
	updateHud(weapon)
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
		bindFire()
		updateHud(weapon)
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

	-- A respawn tears down the zoom and the trigger state (the camera is
	-- fresh, the button state stale); the mirrors deliberately survive - the
	-- server's per-weapon magazines do too.
	player.CharacterAdded:Connect(function()
		firing = false
		setZoom(false, nil)
		refresh()
	end)

	-- The auto loop and the reload countdown: while the trigger is held on an
	-- auto weapon, keep firing at its cooldown; and tick the HUD through a
	-- reload so the amber line flips back to numbers on time.
	RunService.Heartbeat:Connect(function()
		local weapon = currentRangedWeapon()
		if not weapon then
			return
		end
		-- A release that lands on a GUI (a menu opened mid-burst) is
		-- game-processed and never reaches the action handler, which would
		-- leave `firing` latched and the gun emptying itself into a menu. On
		-- desktop the physical button is the truth; touch keeps the latch
		-- (there's no equivalent poll).
		if
			firing
			and UserInputService.MouseEnabled
			and not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
		then
			firing = false
		end
		if firing and weapon.ranged.fireMode == "auto" then
			tryFire()
		end
		local mirror = mirrorFor(weapon)
		if mirror.reloadUntil > 0 and os.clock() >= mirror.reloadUntil then
			mirror.reloadUntil = 0
			mirror.shotsInMag = weapon.ranged.magazine
			updateHud(weapon)
		end
	end)
end

return RangedController
