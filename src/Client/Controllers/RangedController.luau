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

local CameraController = require(script.Parent.CameraController)
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

-- ---------------------------------------------------------------- aim
-- WHERE A SHOT COMES FROM (2026-08-30). This used to send the CAMERA's
-- position as the shot's origin, which the server refuses: CombatService runs
-- ShotAim.originOk, and an origin further than Tuning.Ranged.ORIGIN_SLACK (6
-- studs) from the character's root is dropped without a word. That check is
-- the thing stopping a hacked client shooting from across the map, so it is
-- not the part that gives - the client is.
--
-- In first person the camera sits at the head and the claim passed by luck.
-- In third person it does not: the boss arenas pin the camera 26 studs back
-- (58 in the Careenage's raised orbit), so EVERY ranged shot in a boss arena
-- was being discarded server-side. That is fatal where guns are the only
-- answer - the Kraken's head and the gloom lantern are `rangedOnly`, melee is
-- routed past them on purpose, so a boss with no reachable weapon simply
-- never loses health.
--
-- The fix is parallax, not slack. Resolve the point the crosshair is actually
-- over down the camera ray, then shoot from the CHARACTER toward that point:
-- the origin is one the server will accept, and the shot still goes where the
-- player is looking. First person is unchanged in practice (the origin lands
-- within a stud of the lens), and an arc weapon gains as well - its flight
-- time is measured from the origin, so a bow that used to lob from the
-- camera's nose now measures the distance the arrow really travels.
--
-- THE AIM POINT IS RESOLVED PAST THE SHOOTER, NOT PAST THE CAMERA (regression
-- fix, 2026-08-30). That first pass bounded the depth search by the weapon's
-- `range`, measured from the CAMERA - two different quantities wearing one
-- name. `range` is the reach of the GUN: the server measures it from the shot
-- origin (ShotAim.terrainLimit(rayOrigin, ...)), so it says nothing about how
-- far down the camera ray the crosshair's target lies.
--
-- Where the camera stands well back, the shooter is already most of that
-- number down the ray - 57 to 61 studs of it in the Careenage's raised orbit
-- (BIRDSEYE_DISTANCE 58) - so any gun with a shorter reach resolved its aim
-- point BEHIND the shooter and fired at the camera. The Grave Blunderbuss
-- (range 55) did it at every pitch in the band, and the server took the shots:
-- the origin is honest, only the direction was reversed. Anything at all
-- between the camera and the shooter did the same to every gun.
--
-- So the search runs from the shooter OUT to their reach, and the answer is
-- floored a little in front of them: nearer than that is behind their back,
-- which is not a thing anyone can shoot at.
local ORIGIN_LIFT = 1.5 -- chest height above the root: the shot leaves the shooter, not the lens
-- How far in front of the shooter the aim point must land. The floor is the
-- larger of a flat two studs and three times `side` - how far the shooter
-- stands OFF the camera ray (3 studs of it in the raised orbit: the camera
-- focuses BIRDSEYE_FOCUS_LIFT up, the shot leaves at ORIGIN_LIFT). The ratio
-- is what actually matters: it holds the shot within atan(1/3) = 18 degrees
-- of the camera ray however far off it the rig puts the body, so the worst
-- direction this can ever return is still 0.95 forward.
local MIN_AIM_LEAD = 2
local AIM_LEAD_RATIO = 3
local CREATURES_FOLDER = "Creatures"

-- Cached per model, dropped with it (the model is the weak key).
local aimRadius: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any

-- How far down the AIM ray the thing being aimed at is, searched over the
-- stretch of that ray between `near` and `far` and answering `far` when it is
-- clear. The ray is handed in (origin, dir) rather than read off the camera,
-- because in third person it is no longer the camera's optical axis: it is the
-- ray through the CURSOR, which is the crosshair (see aimRay below). Solid
-- world first, then creatures - creature parts are CanQuery =
-- false (targeting has always been proximity, not raycast: ShotAim's header),
-- so they cannot be raycast and are swept the same generous way
-- CreatureService.raycastNearest sweeps them server-side. Resolving the DEPTH
-- is the whole point: aiming at open range while the target is close is
-- exactly where parallax misses.
--
-- The window is half the point too. Everything nearer than `near` is behind
-- the shooter's back - a hull the raised camera is looking over, a creature
-- standing between the lens and the body - and picking one of those as the
-- thing being aimed at is how a shot ends up pointing at the camera.
local function aimDistance(origin: Vector3, dir: Vector3, near: number, far: number): number
	local best = far
	local ignore = {}
	local character = player.Character
	if character then
		table.insert(ignore, character)
	end
	for _, name in { "ClientVfx", "CreatureFx", "WrackShot", "RangedFx" } do
		local other = Workspace:FindFirstChild(name)
		if other then
			table.insert(ignore, other)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.RespectCanCollide = true

	local hit = Workspace:Raycast(origin, dir * far, params)
	if hit then
		local depth = (hit.Position - origin).Magnitude
		if depth > near then
			best = depth
		end
	end

	local creatures = Workspace:FindFirstChild(CREATURES_FOLDER)
	if creatures then
		for _, model in creatures:GetChildren() do
			if model:IsA("Model") then
				local to = model:GetPivot().Position - origin
				local along = to:Dot(dir)
				if along > near and along < best then
					local radius = aimRadius[model]
					if not radius then
						-- THE SERVER'S OWN NUMBER FIRST. `ShotRadius` is
						-- published by CreatureService.spawn for any row that
						-- carries one, and it is the SAME value that server's
						-- `raycastNearest` will capture this creature with.
						--
						-- Without it this line re-derived the capture from the
						-- model's bounding box - the identical formula, run
						-- independently, which is exactly the failure the
						-- attribute exists to close (user, 2026-09-08, live:
						-- shots passing through Wrack's powder runner). For a
						-- small target standing on open sand the sweep misses,
						-- the depth falls through to the SAND BEHIND it, and
						-- since the shot is fired from the shooter's root and
						-- not the camera, that wrong depth bends the direction
						-- by the whole rig parallax - so the server is then
						-- handed a ray that really does miss. The client's
						-- estimate decides the server's input, which makes
						-- "both are individually reasonable" no defence.
						local _, size = model:GetBoundingBox()
						radius = math.max(1.4, size.Magnitude * 0.3)
						aimRadius[model] = radius
					end
					-- READ EVERY PASS, not cached with the derived value above:
					-- the cache is keyed on first sight, and a model that
					-- arrives before its attributes have replicated would
					-- otherwise be stuck with the derived number for its whole
					-- life - the bug's own conditions, restored by the
					-- optimisation meant to avoid it. GetAttribute is a hash
					-- lookup; the sweep already calls GetPivot on every model.
					local authored = model:GetAttribute("ShotRadius")
					if type(authored) == "number" then
						radius = authored
					end
					if (to - dir * along).Magnitude <= radius then
						best = along
					end
				end
			end
		end
	end
	return best
end

-- THE CURSOR IS THE AIM (user, 2026-09-08, on the first cursor-plus-centred-
-- mark build: "you need to make it so that the cursor is the crosshair and the
-- user shoots wherever their crosshair is"). So the ray the shot is resolved
-- along is the ray through the cursor's pixel, not the camera's optical axis.
--
-- COORDINATE SPACE, which is the only thing that can go wrong here.
-- UserInputService:GetMouseLocation() answers in VIEWPORT space - the top-left
-- of the 3D viewport is (0, 0), the 36-pixel top bar is NOT subtracted - and
-- Camera:ViewportPointToRay takes that same space (its ScreenPointToRay twin
-- is the inset-offset one). The two are therefore paired with no arithmetic
-- between them, and CrosshairController's ScreenGui carries IgnoreGuiInset =
-- true so that the drawn mark lands on that same pixel. One space, three
-- users, nothing added or subtracted anywhere: that is the whole convention,
-- and any correction term added later to one of the three would be the bug.
--
-- FIRST PERSON IS UNTOUCHED BY CONSTRUCTION. It does not take this path at
-- all - the early return hands back exactly the camera position and
-- LookVector this function has always used - so the centre-locked, icon-
-- hidden, viewmodel-scoped mode fires down its optical axis to the bit, with
-- no dependence on where a locked cursor reports itself to be.
local function aimRay(camera: Camera): (Vector3, Vector3)
	local camCf = camera.CFrame
	-- Two ways out, both to the optical axis this function has always used:
	-- first person (above), and touch - where there is no pointer to aim, the
	-- last touch being where a finger left the glass rather than where the
	-- player is looking. CrosshairController parks its mark at the centre under
	-- the same test, so the two agree there too.
	if not CameraController.isThirdPerson() or not UserInputService.MouseEnabled then
		return camCf.Position, camCf.LookVector
	end
	local view = camera.ViewportSize
	local at = UserInputService:GetMouseLocation()
	-- Clamped because the pointer can report a pixel outside the viewport (a
	-- window edge, a drag leaving the client area) and a ray out of frame is a
	-- shot the player never aimed.
	local ray = camera:ViewportPointToRay(math.clamp(at.X, 0, view.X), math.clamp(at.Y, 0, view.Y))
	-- Origin stays the CAMERA's position, not the ray's: ViewportPointToRay
	-- starts on the near plane, and every distance below (`ahead`, `side`, the
	-- search window) is measured from the lens. Only the DIRECTION is the
	-- cursor's.
	return camCf.Position, ray.Direction.Unit
end

-- The ray the server is asked to resolve: an origin it will accept, aimed at
-- what the crosshair is over.
local function shotRay(camera: Camera, ranged): (Vector3, Vector3)
	local camCf = camera.CFrame
	local camPos, dir = aimRay(camera)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return camPos, dir -- no body to shoot from; fire straight down the aim ray
	end
	local origin = (root :: BasePart).Position + Vector3.new(0, ORIGIN_LIFT, 0)

	-- Where the shooter stands on the aim ray: `ahead` studs down it, and
	-- `side` studs off the CAMERA's axis. In first person both are fractions of
	-- a stud; the further back the rig puts the camera, the more of the ray is
	-- spent just getting to the body, and that stretch is not the weapon's to
	-- spend.
	--
	-- WHY `side` IS MEASURED OFF THE CAMERA AXIS AND NOT OFF `dir`. It exists to
	-- size the guard below against the RIG's parallax - how far off its own
	-- sightline the camera stands from the body - which is a property of the
	-- mode and is a few studs in all four of them. Measured off the cursor ray
	-- instead it would grow with the player's own aim: park the crosshair in a
	-- corner of the birdseye Careenage and `side` becomes tens of studs, the
	-- guard pushes the search window past the target, and the shot sails over
	-- the very thing the crosshair is sitting on. The cursor decides WHERE to
	-- look; the rig decides how much lead the look needs.
	local toShooter = origin - camPos
	local ahead = math.max(toShooter:Dot(dir), 0)
	local rigAhead = math.max(toShooter:Dot(camCf.LookVector), 0)
	local side = (toShooter - camCf.LookVector * rigAhead).Magnitude

	-- So: search the ray from just in front of the shooter out to the end of
	-- the weapon's reach, and hold the answer to that near edge. `to` can no
	-- longer be short enough to give an unstable direction (it is at least
	-- MIN_AIM_LEAD long by construction), so there is nothing left for the old
	-- magnitude guard to catch.
	local nearest = ahead + math.max(MIN_AIM_LEAD, side * AIM_LEAD_RATIO)
	local depth = math.max(aimDistance(camPos, dir, nearest, ahead + (ranged.range or 100)), nearest)
	local aimAt = camPos + dir * depth
	return origin, (aimAt - origin).Unit
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
	-- Anchored to the character (the server checks it against the root) and
	-- aimed where the player is looking. See the aim section above.
	local origin, look = shotRay(camera, ranged)

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
	-- RIGHT CLICK IS THE CAMERA'S IN THIRD PERSON (2026-09-08). The boss arenas
	-- orbit on a held right button - that is the whole of the arena camera's
	-- look control (CameraController's cursor model) - and a scope that zoomed
	-- on the same button would fight the drag it is being dragged with: the FOV
	-- would snap to 40 the moment the player reached for the camera, and back
	-- out when they let go. So the scope stands down where the camera needs the
	-- button, exactly as CombatController stands down where a gun is out, and
	-- returns Pass so nothing else bound to the button is starved either.
	--
	-- First person keeps the scope byte-for-byte as it was. The state is torn
	-- down on the way in rather than left hanging: walking into an arena while
	-- zoomed must not strand the FOV.
	if CameraController.isThirdPerson() then
		if zoomed then
			setZoom(false, nil)
		end
		return Enum.ContextActionResult.Pass
	end
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
		-- The scope, same idea from the other side: the camera mode can change
		-- with no input arriving at all (it follows where the character is
		-- standing), so a player who walks into a boss arena while zoomed would
		-- otherwise keep the narrowed FOV over a camera that has taken the
		-- button back. See onZoomAction.
		if zoomed and CameraController.isThirdPerson() then
			setZoom(false, nil)
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
