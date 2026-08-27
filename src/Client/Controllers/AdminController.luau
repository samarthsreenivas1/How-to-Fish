--!nonstrict
-- AdminController.luau
-- The admin cheat panel. P toggles a floating panel on the left: grant
-- buttons (coins / XP / materials / all items / unlock world / everything -
-- repeatable), "Spawn Creature" (a rarity-coloured scrolling list of every
-- creature; a click asks AdminService to spawn it in front of you), "Travel
-- To Island" (every island; AdminTeleport, skipping the normal travel gates)
-- and "Flight" (F) - a client-side camera-steered flythrough for surveying
-- the voyage-arc map (see the flight section).
--
-- Only ever built for admins: the server sets the Player's `IsAdmin`
-- attribute, and this does nothing unless it's true. The grant / spawn /
-- teleport are gated server-side too. Borrows the cursor while open the
-- same way the menus do. Rebuilt on the shared UI kit in the 2026-08-23
-- overhaul; setOpen / isOpen / isAdmin and the P hotkey are unchanged.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Creatures = require(Shared.Data.Creatures)
local Islands = require(Shared.Config.Islands)
local Rarity = require(Shared.Modules.Rarity)
local Remotes = require(Shared.Net.Remotes)

local Theme = require(script.Parent.Parent.UI.Theme)
local Kit = require(script.Parent.Parent.UI.Kit)
local CameraController = require(script.Parent.CameraController)

local player = Players.LocalPlayer

local AdminController = {}

local C = Theme.Color
local F = Theme.Font

local ADMIN_ATTRIBUTE = "IsAdmin"
local TOGGLE_ACTION = "AdminPanelToggle"

-- action -> button. Order controls the on-screen order.
local BUTTONS = {
	{ action = "coins", label = "+100k Coins", token = "$", style = "gold" },
	{ action = "xp", label = "+100k XP", token = "XP", style = "primary" },
	{ action = "materials", label = "Max Materials", token = "MAT", style = "secondary" },
	{ action = "items", label = "All Items", token = "INV", style = "secondary" },
	{ action = "unlock", label = "Unlock World", token = "KEY", style = "gold" },
	{ action = "all", label = "Give Everything", token = "ALL", style = "success" },
}

-- Flight (map flythrough): base and Shift-boosted speeds, studs/s. The map's
-- voyage legs run 4,000-8,700 studs, so the boost is sized to cross the whole
-- world in under a minute.
local FLY_SPEED = 150
local FLY_SPEED_BOOST = 600
local FLY_KEY = Enum.KeyCode.F
local FLY_ACTION = "AdminFlyToggle"

local PANEL_WIDTH = 240
local PICKER_WIDTH = 270
local ROW_HEIGHT = 40
local MARGIN = 24

local gui: ScreenGui?
local spawnList: Frame?
local travelList: Frame?
local flightButton: TextButton?
local open = false

-- ============================================================ flight

-- Admin flythrough: hover-and-glide for surveying the map. Client-side only
-- and deliberately so - Roblox gives the client authority over its own
-- character, so no server half is needed, and it stays honest dev tooling
-- behind the same IsAdmin gate as the panel.
--
-- Mechanically it's the boat's trick applied to the character: a
-- LinearVelocity constraint on the root (huge force = it dictates velocity
-- outright, gravity included) driven every frame from Humanoid.MoveDirection
-- remapped through the FULL camera frame - so W flies where you're looking,
-- pitch included, and no input is a rock-solid hover. The character stays
-- unanchored and physics-simulated, so its position replicates normally
-- (an anchored root would freeze you on everyone else's screen).
-- Collision stays ON - steer around the mountains, no noclip.
local flying = false
local flyMove: LinearVelocity?
local flyStep: RBXScriptConnection?

local function isAdmin(): boolean
	return player:GetAttribute(ADMIN_ATTRIBUTE) == true
end

local function refreshFlightButton()
	if flightButton then
		flightButton.Text = if flying then "Flight: ON  (F)" else "Flight  (F)"
	end
end

local function stopFlying()
	if flyStep then
		flyStep:Disconnect()
		flyStep = nil
	end
	if flyMove then
		flyMove.Parent = nil
		if flyMove.Attachment0 then
			flyMove.Attachment0:Destroy()
		end
		flyMove:Destroy()
		flyMove = nil
	end
	flying = false
	refreshFlightButton()
end

local function flightTick()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local camera = Workspace.CurrentCamera
	if not (root and humanoid and camera and flyMove and flyMove.Parent) then
		stopFlying()
		return
	end

	-- MoveDirection is WASD in world XZ (camera-yaw relative). Split it into
	-- forward/strafe against the camera's FLAT axes, then rebuild along the
	-- camera's TRUE axes - that turns pitch into climb/dive for free.
	local look = camera.CFrame.LookVector
	local right = camera.CFrame.RightVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	local flatRight = Vector3.new(right.X, 0, right.Z)
	local move = (humanoid :: Humanoid).MoveDirection
	local velocity = Vector3.zero
	if move.Magnitude > 0.05 and flatLook.Magnitude > 0.05 then
		local forwardAmount = move:Dot(flatLook.Unit)
		local strafeAmount = move:Dot(flatRight.Unit)
		local direction = look * forwardAmount + right * strafeAmount
		if direction.Magnitude > 0.05 then
			local speed = if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then FLY_SPEED_BOOST else FLY_SPEED
			velocity = direction.Unit * speed
		end
	end
	flyMove.VectorVelocity = velocity
end

local function startFlying()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not (root and root:IsA("BasePart") and humanoid) then
		return
	end
	-- Not from a seat: the seat weld would drag the whole boat along. Stand
	-- up first, then toggle flight.
	if (humanoid :: Humanoid).SeatPart then
		return
	end

	stopFlying()

	local attachment = Instance.new("Attachment")
	attachment.Name = "AdminFly_Attachment"
	attachment.Parent = root

	local move = Instance.new("LinearVelocity")
	move.Name = "AdminFly_Move"
	move.Attachment0 = attachment
	move.RelativeTo = Enum.ActuatorRelativeTo.World
	move.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	move.VectorVelocity = Vector3.zero
	move.ForceLimitsEnabled = false
	move.Parent = root

	flyMove = move
	flyStep = RunService.Heartbeat:Connect(flightTick)
	flying = true
	refreshFlightButton()
end

local function toggleFlight()
	if not isAdmin() then
		return
	end
	if flying then
		stopFlying()
	else
		startFlying()
	end
end

-- ============================================================ build

local function creatureOrder(): { string }
	local ids = {}
	for id in Creatures.items do
		table.insert(ids, id)
	end
	table.sort(ids, function(a, b)
		local ra, rb = Rarity.indexOf(Creatures.items[a].rarity), Rarity.indexOf(Creatures.items[b].rarity)
		if ra ~= rb then
			return ra < rb
		end
		return Creatures.items[a].name < Creatures.items[b].name
	end)
	return ids
end

-- A floating panel with a driftwood title strip.
local function floatingPanel(
	screen: ScreenGui,
	name: string,
	title: string,
	token: string,
	x: number,
	height: number
): (Frame, Frame)
	local panel = Kit.panel(screen, {
		Name = name,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, x, 0.5, 0),
		Size = UDim2.fromOffset(if name == "Panel" then PANEL_WIDTH else PICKER_WIDTH, height),
		BackgroundColor3 = C.background,
	})
	panel.ClipsDescendants = true

	local strip = Kit.frame(panel, {
		Name = "Strip",
		Size = UDim2.new(1, 0, 0, 44),
		BackgroundTransparency = 0,
		BackgroundColor3 = C.wood,
	})
	Kit.gradient(strip, C.wood, C.woodDark, 90)
	Kit.tile(strip, {
		size = 28,
		color = C.accentDark,
		token = token,
		tokenSize = 10,
		position = UDim2.new(0, 10, 0.5, 0),
		anchor = Vector2.new(0, 0.5),
		radius = 9,
	})
	Kit.label(strip, {
		Font = F.header,
		TextSize = 18,
		TextColor3 = C.sand,
		Text = title,
		Position = UDim2.new(0, 46, 0, 0),
		Size = UDim2.new(1, -52, 1, 0),
	})
	local body = Kit.frame(panel, {
		Name = "Body",
		Position = UDim2.new(0, 10, 0, 52),
		Size = UDim2.new(1, -20, 1, -62),
	})
	return panel, body
end

-- A picker row: a rarity / accent tile + the name.
local function pickerRow(
	parent: Instance,
	order: number,
	text: string,
	color: Color3,
	token: string,
	onClick: () -> ()
): TextButton
	local row = Instance.new("TextButton")
	row.Name = "Row_" .. text
	row.AutoButtonColor = false
	row.Text = ""
	row.BorderSizePixel = 0
	row.LayoutOrder = order
	row.Size = UDim2.new(1, -4, 0, ROW_HEIGHT)
	row.BackgroundColor3 = C.panel
	row.Parent = parent
	Kit.corner(row, 10)
	Kit.tile(row, {
		size = 26,
		color = color,
		token = token,
		tokenSize = 9,
		position = UDim2.new(0, 7, 0.5, 0),
		anchor = Vector2.new(0, 0.5),
		radius = 8,
	})
	Kit.label(row, {
		Font = F.bodyBold,
		TextSize = 13,
		TextColor3 = C.text,
		Text = text,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.new(0, 42, 0, 0),
		Size = UDim2.new(1, -48, 1, 0),
	})
	row.MouseEnter:Connect(function()
		row.BackgroundColor3 = C.panelHover
	end)
	row.MouseLeave:Connect(function()
		row.BackgroundColor3 = C.panel
	end)
	row.Activated:Connect(onClick)
	return row
end

local function buildSpawnList(screen: ScreenGui)
	local panel, body = floatingPanel(screen, "SpawnList", "Spawn Creature", "SPAWN", MARGIN + PANEL_WIDTH + 12, 460)
	panel.Visible = false
	local scroll = Kit.scroll(body, { name = "List", gap = 4, padding = 2 })
	for i, id in creatureOrder() do
		local row = Creatures.items[id]
		pickerRow(scroll, i, row.name, Rarity.colorOf(row.rarity), Kit.monogram(row.name), function()
			Remotes.AdminSpawn:FireServer(id)
		end)
	end
	spawnList = panel
end

local function buildTravelList(screen: ScreenGui)
	local panel, body = floatingPanel(screen, "TravelList", "Travel To Island", "MAP", MARGIN + PANEL_WIDTH + 12, 300)
	panel.Visible = false
	local scroll = Kit.scroll(body, { name = "List", gap = 4, padding = 2 })
	-- The saga order, plus every site entry (the Maelstrom) that stays out of
	-- Islands.order - admin travel should reach ALL of the map.
	local ids = table.clone(Islands.order)
	for id, entry in Islands.items do
		if entry.site then
			table.insert(ids, id)
		end
	end
	for i, id in ids do
		local entry = Islands.items[id]
		pickerRow(scroll, i, entry.name, C.accentDark, Kit.monogram(entry.name), function()
			Remotes.AdminTeleport:FireServer(id)
			AdminController.setOpen(false) -- close so the new island is in view
		end)
	end
	travelList = panel
end

local function buildPanel()
	if gui then
		return
	end

	local screen = Instance.new("ScreenGui")
	screen.Name = "AdminGui"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 50
	screen.Enabled = false
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local rows = #BUTTONS + 3 -- + spawn / travel / flight
	local _, body = floatingPanel(screen, "Panel", "Admin", "P", MARGIN, 52 + rows * 50 + 12)
	Kit.listLayout(body, 6)

	for i, spec in BUTTONS do
		local button = Kit.button(body, {
			name = spec.action,
			order = i,
			text = spec.label,
			style = spec.style,
			textSize = 15,
			size = UDim2.new(1, 0, 0, 44),
		})
		button.Activated:Connect(function()
			Remotes.AdminGrant:FireServer(spec.action)
		end)
	end

	local spawnButton = Kit.button(body, {
		name = "SpawnToggle",
		order = #BUTTONS + 1,
		text = "Spawn Creature",
		style = "secondary",
		textSize = 15,
		size = UDim2.new(1, 0, 0, 44),
	})
	local travelButton = Kit.button(body, {
		name = "TravelToggle",
		order = #BUTTONS + 2,
		text = "Travel To Island",
		style = "secondary",
		textSize = 15,
		size = UDim2.new(1, 0, 0, 44),
	})
	local fly = Kit.button(body, {
		name = "FlightToggle",
		order = #BUTTONS + 3,
		text = "Flight  (F)",
		style = "primary",
		textSize = 15,
		size = UDim2.new(1, 0, 0, 44),
	})
	fly.Activated:Connect(toggleFlight)
	flightButton = fly

	buildSpawnList(screen)
	buildTravelList(screen)

	-- The two pickers share a slot, so opening one closes the other.
	spawnButton.Activated:Connect(function()
		if travelList then
			travelList.Visible = false
		end
		if spawnList then
			spawnList.Visible = not spawnList.Visible
		end
	end)
	travelButton.Activated:Connect(function()
		if spawnList then
			spawnList.Visible = false
		end
		if travelList then
			travelList.Visible = not travelList.Visible
		end
	end)

	gui = screen
	screen.Parent = player:WaitForChild("PlayerGui")
end

-- ============================================================ toggle

local function setOpen(state: boolean)
	if not isAdmin() then
		state = false
	end
	open = state
	if gui then
		gui.Enabled = state
	end
	if not state then
		if spawnList then
			spawnList.Visible = false
		end
		if travelList then
			travelList.Visible = false
		end
	end
	CameraController.setCursorFree(state)
end

local function refreshAvailability()
	if not isAdmin() then
		if open then
			setOpen(false)
		end
		stopFlying()
	end
end

function AdminController.setOpen(state: boolean)
	setOpen(state)
end

function AdminController.isOpen(): boolean
	return open
end

function AdminController.isAdmin(): boolean
	return isAdmin()
end

-- ============================================================ lifecycle

function AdminController.init()
	buildPanel()
	player:GetAttributeChangedSignal(ADMIN_ATTRIBUTE):Connect(refreshAvailability)
	-- A fresh character has no fly constraint: drop the mode rather than
	-- haunting the respawn with a dead connection.
	player.CharacterAdded:Connect(stopFlying)
end

function AdminController.start()
	ContextActionService:BindActionAtPriority(TOGGLE_ACTION, function(_, inputState)
		if inputState == Enum.UserInputState.Begin and isAdmin() then
			setOpen(not open)
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.P)

	-- F toggles flight for admins; for everyone else the key passes through
	-- untouched so it stays free for future gameplay binds.
	ContextActionService:BindActionAtPriority(FLY_ACTION, function(_, inputState)
		if not isAdmin() then
			return Enum.ContextActionResult.Pass
		end
		if inputState == Enum.UserInputState.Begin then
			toggleFlight()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, FLY_KEY)
end

return AdminController
