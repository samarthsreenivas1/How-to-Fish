--!nonstrict
-- BoatController.luau
-- The client half of the boat (docs/revamp-plan.md Session 3): summons it
-- with R (a touch button stands in on tablets/phones), and DRIVES it while
-- the local player sits at their own helm.
--
-- Driving is deliberately client-simulated: BoatService hands the hull's
-- network ownership to the seated owner, and this controller steers the two
-- constraints BoatModel builds into the collider - Boat_Move (a world-space
-- LinearVelocity: heading times speed, plus a vertical component holding the
-- hull to the waterline) and Boat_Align (upright, current yaw). The waterline
-- is World.WATER_Y plus the hull's rest height PLUS a small bob - keyed to
-- the CONSTANT, never the tide-animated visual ocean plane (OceanController
-- moves that client-side; a boat riding it would fight its own physics).
-- Throttle/steer come from the VehicleSeat, which Roblox feeds from W/S/A/D
-- (and thumbstick) for whoever sits in it - so mobile drives for free.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local World = require(Shared.Config.World)
local Tuning = require(Shared.Config.Tuning)
local Islands = require(Shared.Config.Islands)
local Boats = require(Shared.Data.Boats)
local Remotes = require(Shared.Net.Remotes)

local Theme = require(script.Parent.Parent.UI.Theme)

local player = Players.LocalPlayer

local BoatController = {}

local SUMMON_ACTION = "SummonBoat"
local SUMMON_KEY = Enum.KeyCode.R

-- Below the fishing (40), level (84) and drop (122) banners.
local BANNER_Y = 160
local BANNER_HOLD = 3.0

-- The sailing compass (map redesign, 2026-08-27): islands are now thousands
-- of studs apart across open sea, so the helm needs a way to FIND land. While
-- driving, a slim strip along the top of the screen shows a marker for every
-- placed island within COMPASS_HALF_ANGLE of the bow - name above a tick,
-- shoreline distance below - sliding as the boat turns, exactly like a
-- first-person shooter compass. Hidden the moment you leave the seat, so the
-- no-prompts HUD stays quiet on foot.
local COMPASS_WIDTH = 640
local COMPASS_Y = 14
local COMPASS_HALF_ANGLE = math.rad(110) -- bearings past this slide off the strip's edge

-- One accent per destination so a distant marker reads at a glance.
local COMPASS_COLOR: { [string]: Color3 } = {
	tropical = Color3.fromRGB(255, 226, 160), -- sand
	swamp = Color3.fromRGB(140, 200, 90), -- fen green
	ice = Color3.fromRGB(170, 226, 250), -- glacier blue
	volcano = Color3.fromRGB(255, 140, 60), -- ember
	gloom = Color3.fromRGB(190, 120, 240), -- violet
	wreck = Color3.fromRGB(206, 160, 92), -- brass
	maelstrom = Color3.fromRGB(255, 196, 64), -- gold
}

local gui: ScreenGui
local banner: TextLabel
local compass: Frame
local compassMarkers: { [string]: { frame: Frame, distance: TextLabel } } = {}

-- Live drive state (nil while not at the helm).
local drive: {
	row: any,
	collider: BasePart,
	move: LinearVelocity,
	align: AlignOrientation,
	yaw: number,
	speed: number,
	connection: RBXScriptConnection,
}? =
	nil

-- ============================================================ banner

local function showBanner(text: string)
	banner.Text = text
	banner.Visible = true
	banner.TextTransparency = 0
	banner.TextStrokeTransparency = 0.4
	banner.Position = UDim2.new(0.5, 0, 0, BANNER_Y + 14)
	TweenService:Create(banner, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = UDim2.new(0.5, 0, 0, BANNER_Y),
	}):Play()
	task.delay(BANNER_HOLD, function()
		if banner.Text ~= text then
			return
		end
		TweenService:Create(banner, TweenInfo.new(0.5), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		task.delay(0.5, function()
			if banner.Text == text then
				banner.Visible = false
			end
		end)
	end)
end

-- ============================================================ compass

-- An island shows on the compass only when it exists in the world: its mesh
-- is placed under Workspace/World (a missing import stays off the strip), and
-- the Maelstrom - which has no mesh - only once every island heart is in hand,
-- mirroring the travel menu's veil so the compass can't leak the finale early.
local function compassDestinations(): { [string]: any }
	local out = {}
	local worldFolder = Workspace:FindFirstChild(World.FOLDER_NAME)
	if not worldFolder then
		return out
	end
	for id, entry in Islands.items do
		if entry.site then
			local revealed = worldFolder:FindFirstChild("Maelstrom") ~= nil
			for _, orderedId in Islands.order do
				local ordered = Islands.items[orderedId]
				if ordered.boss and player:GetAttribute("Heart_" .. ordered.boss) ~= true then
					revealed = false
					break
				end
			end
			if revealed then
				out[id] = entry
			end
		elseif worldFolder:FindFirstChild(entry.model) then
			out[id] = entry
		end
	end
	return out
end

local function buildCompassMarker(id: string, entry): { frame: Frame, distance: TextLabel }
	local color = COMPASS_COLOR[id] or Theme.Color.text

	local marker = Instance.new("Frame")
	marker.Name = "Marker_" .. id
	marker.AnchorPoint = Vector2.new(0.5, 0)
	marker.Size = UDim2.fromOffset(120, 44)
	marker.BackgroundTransparency = 1
	marker.Visible = false
	marker.Parent = compass

	local name = Instance.new("TextLabel")
	name.Name = "IslandName"
	name.AnchorPoint = Vector2.new(0.5, 0)
	name.Position = UDim2.new(0.5, 0, 0, 0)
	name.Size = UDim2.new(1, 0, 0, 14)
	name.BackgroundTransparency = 1
	name.Font = Theme.Font.header
	name.TextSize = 13
	name.TextColor3 = color
	name.TextStrokeColor3 = Color3.fromRGB(10, 14, 20)
	name.TextStrokeTransparency = 0.35
	name.Text = entry.name
	name.Parent = marker

	local tick = Instance.new("Frame")
	tick.Name = "Tick"
	tick.AnchorPoint = Vector2.new(0.5, 0)
	tick.Position = UDim2.new(0.5, 0, 0, 17)
	tick.Size = UDim2.fromOffset(4, 9)
	tick.BackgroundColor3 = color
	tick.BorderSizePixel = 0
	tick.Parent = marker
	local tickCorner = Instance.new("UICorner")
	tickCorner.CornerRadius = UDim.new(0, 2)
	tickCorner.Parent = tick

	local distance = Instance.new("TextLabel")
	distance.Name = "Distance"
	distance.AnchorPoint = Vector2.new(0.5, 0)
	distance.Position = UDim2.new(0.5, 0, 0, 28)
	distance.Size = UDim2.new(1, 0, 0, 12)
	distance.BackgroundTransparency = 1
	distance.Font = Theme.Font.bodyBold
	distance.TextSize = 11
	distance.TextColor3 = Theme.Color.text
	distance.TextStrokeColor3 = Color3.fromRGB(10, 14, 20)
	distance.TextStrokeTransparency = 0.5
	distance.Text = ""
	distance.Parent = marker

	return { frame = marker, distance = distance }
end

-- Refresh which islands have markers (placed set / hearts can change between
-- voyages) and show the strip. Called every time the player takes the helm.
local function showCompass()
	local destinations = compassDestinations()
	for id, marker in compassMarkers do
		if not destinations[id] then
			marker.frame:Destroy()
			compassMarkers[id] = nil
		end
	end
	for id, entry in destinations do
		if not compassMarkers[id] then
			compassMarkers[id] = buildCompassMarker(id, entry)
		end
	end
	compass.Visible = true
end

local function hideCompass()
	compass.Visible = false
end

-- Slide the markers to their relative bearings. `yaw` is the drive loop's
-- heading (forward = (-sin yaw, 0, -cos yaw)); a marker dead ahead sits at
-- the strip's centre, one past COMPASS_HALF_ANGLE to either side hides.
local function updateCompass(position: Vector3, yaw: number)
	for id, marker in compassMarkers do
		local entry = Islands.items[id]
		local dx = entry.worldPosition.X - position.X
		local dz = entry.worldPosition.Z - position.Z
		local bearing = math.atan2(-dx, -dz)
		local rel = math.atan2(math.sin(bearing - yaw), math.cos(bearing - yaw))
		if math.abs(rel) > COMPASS_HALF_ANGLE then
			marker.frame.Visible = false
		else
			marker.frame.Visible = true
			marker.frame.Position = UDim2.new(0.5 - rel / (2 * COMPASS_HALF_ANGLE), 0, 0, 0)
			local shore = math.max(0, math.sqrt(dx * dx + dz * dz) - (entry.radius or 0))
			marker.distance.Text = if shore >= 1000
				then string.format("%.1fk", shore / 1000)
				else string.format("%d", math.floor(shore))
		end
	end
end

-- ============================================================ driving

local function stopDriving()
	if not drive then
		return
	end
	drive.connection:Disconnect()
	-- We still own the assembly for a beat; leave it dead in the water for
	-- the server's park snap rather than coasting away driverless.
	if drive.collider.Parent then
		drive.move.VectorVelocity = Vector3.zero
	end
	drive = nil
	hideCompass()
end

local function step(dt: number)
	if not drive then
		return
	end
	local collider = drive.collider
	if not collider.Parent then
		stopDriving()
		return
	end
	local seat = collider.Parent and collider.Parent:FindFirstChild("Boat_Seat")
	if not (seat and seat:IsA("VehicleSeat")) then
		stopDriving()
		return
	end

	local row = drive.row
	local B = Tuning.Boat

	-- Throttle -> speed, eased so the hull has weight.
	local target = if seat.Throttle >= 0
		then seat.Throttle * row.speed
		else seat.Throttle * row.speed * B.REVERSE_FACTOR
	local delta = math.clamp(target - drive.speed, -B.ACCELERATION * dt, B.ACCELERATION * dt)
	drive.speed += delta

	-- Steer -> yaw. A boat barely answers the rudder with no way on, so the
	-- turn rate scales up with speed (never to zero - shuffling at the dock
	-- must stay possible).
	local wayOn = 0.35 + 0.65 * math.min(1, math.abs(drive.speed) / row.speed)
	drive.yaw -= seat.Steer * math.rad(row.turnRate) * wayOn * dt

	-- Hold the waterline: World.WATER_Y (the gameplay constant), rest height,
	-- and a soft bob. P-control through velocity so physics stays in charge.
	local restY = World.WATER_Y + (row.model.deckHeight - row.model.draft) / 2
	local bob = B.BOB_HEIGHT * math.sin(os.clock() * 2 * math.pi / B.BOB_PERIOD)
	local vy = math.clamp((restY + bob - collider.Position.Y) * B.Y_GAIN, -12, 12)

	local forward = Vector3.new(-math.sin(drive.yaw), 0, -math.cos(drive.yaw))
	drive.move.VectorVelocity = forward * drive.speed + Vector3.new(0, vy, 0)
	drive.align.CFrame = CFrame.Angles(0, drive.yaw, 0)

	updateCompass(collider.Position, drive.yaw)
end

local function startDriving(seat: VehicleSeat)
	local model = seat.Parent
	if not (model and model:IsA("Model")) then
		return
	end
	if model:GetAttribute("OwnerUserId") ~= player.UserId then
		return
	end
	local row = Boats.items[model:GetAttribute("BoatId") or ""]
	local collider = model:FindFirstChild("Boat_Collider")
	local move = collider and collider:FindFirstChild("Boat_Move")
	local align = collider and collider:FindFirstChild("Boat_Align")
	if not (row and collider and move and align) then
		return
	end

	stopDriving()
	local _, yaw = collider.CFrame:ToEulerAnglesYXZ()
	drive = {
		row = row,
		collider = collider,
		move = move,
		align = align,
		yaw = yaw,
		speed = 0,
		connection = RunService.Heartbeat:Connect(step),
	}
	showCompass()
end

local function watchCharacter(character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if not humanoid then
		return
	end
	humanoid.Seated:Connect(function(active, seatPart)
		if active and seatPart and seatPart.Name == "Boat_Seat" and seatPart:IsA("VehicleSeat") then
			startDriving(seatPart)
		else
			stopDriving()
		end
	end)
end

-- ============================================================ summoning

local function requestSummon()
	Remotes.RequestBoat:FireServer("summon")
end

local function onSummonAction(_, state)
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	requestSummon()
	return Enum.ContextActionResult.Sink
end

-- Touch has no R key: a small BOAT button joins the corner. (Keyboard players
-- get the keybind only - the HUD stays quiet, per the no-prompts rule.)
local function buildTouchButton()
	if not (UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled) then
		return
	end
	local button = Instance.new("TextButton")
	button.Name = "BoatButton"
	button.AnchorPoint = Vector2.new(1, 1)
	button.Position = UDim2.new(1, -18, 1, -110)
	button.Size = UDim2.fromOffset(64, 44)
	button.BackgroundColor3 = Theme.Color.panel
	button.BackgroundTransparency = 0.25
	button.Font = Theme.Font.header
	button.TextSize = 16
	button.TextColor3 = Theme.Color.text
	button.Text = "BOAT"
	button.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = button
	button.Activated:Connect(requestSummon)
end

-- ============================================================ lifecycle

function BoatController.init()
	gui = Instance.new("ScreenGui")
	gui.Name = "BoatGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	banner = Instance.new("TextLabel")
	banner.Name = "Banner"
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Position = UDim2.new(0.5, 0, 0, BANNER_Y)
	banner.Size = UDim2.fromOffset(560, 36)
	banner.BackgroundTransparency = 1
	banner.Font = Theme.Font.header
	banner.TextSize = 24
	banner.TextColor3 = Theme.Color.text
	banner.TextStrokeColor3 = Color3.fromRGB(10, 14, 20)
	banner.TextStrokeTransparency = 0.4
	banner.Text = ""
	banner.Visible = false
	banner.Parent = gui

	-- The compass strip: a bare clipping frame the markers slide across, plus
	-- a centre tick marking dead ahead. No panel box - sleek-HUD rule.
	compass = Instance.new("Frame")
	compass.Name = "Compass"
	compass.AnchorPoint = Vector2.new(0.5, 0)
	compass.Position = UDim2.new(0.5, 0, 0, COMPASS_Y)
	compass.Size = UDim2.fromOffset(COMPASS_WIDTH, 44)
	compass.BackgroundTransparency = 1
	compass.ClipsDescendants = true
	compass.Visible = false
	compass.Parent = gui

	local ahead = Instance.new("Frame")
	ahead.Name = "Ahead"
	ahead.AnchorPoint = Vector2.new(0.5, 0)
	ahead.Position = UDim2.new(0.5, 0, 0, 15)
	ahead.Size = UDim2.fromOffset(2, 13)
	ahead.BackgroundColor3 = Theme.Color.text
	ahead.BackgroundTransparency = 0.45
	ahead.BorderSizePixel = 0
	ahead.Parent = compass

	buildTouchButton()

	Remotes.BoatMessage.OnClientEvent:Connect(function(text)
		if type(text) == "string" then
			showBanner(text)
		end
	end)

	ContextActionService:BindActionAtPriority(
		SUMMON_ACTION,
		onSummonAction,
		false,
		Enum.ContextActionPriority.High.Value,
		SUMMON_KEY
	)

	if player.Character then
		-- Off the boot thread: watchCharacter's WaitForChild could otherwise
		-- stall EVERY later controller for up to 10s on a Humanoid-less
		-- character (87's sweep, nit 3; CharacterAdded callbacks already run
		-- in their own threads).
		task.spawn(watchCharacter, player.Character)
	end
	player.CharacterAdded:Connect(watchCharacter)

	gui.Parent = player:WaitForChild("PlayerGui")
end

function BoatController.start() end

return BoatController
