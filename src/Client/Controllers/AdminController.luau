--!nonstrict
-- AdminController.luau
-- The admin cheat panel. P toggles a floating panel on the left: grant
-- buttons (coins / XP / materials / everything - repeatable), "Spawn
-- Creature" (a rarity-coloured scrolling list of every creature; a click
-- asks AdminService to spawn it in front of you) and "Travel To Island"
-- (every island; AdminTeleport, skipping the normal travel gates).
--
-- Only ever built for admins: the server sets the Player's `IsAdmin`
-- attribute, and this does nothing unless it's true. The grant / spawn /
-- teleport are gated server-side too. Borrows the cursor while open the
-- same way the menus do. Rebuilt on the shared UI kit in the 2026-08-23
-- overhaul; setOpen / isOpen / isAdmin and the P hotkey are unchanged.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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
	{ action = "all", label = "Give Everything", token = "ALL", style = "success" },
}

local PANEL_WIDTH = 240
local PICKER_WIDTH = 270
local ROW_HEIGHT = 40
local MARGIN = 24

local gui: ScreenGui?
local spawnList: Frame?
local travelList: Frame?
local open = false

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
	for i, id in Islands.order do
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

	local rows = #BUTTONS + 2
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

local function isAdmin(): boolean
	return player:GetAttribute(ADMIN_ATTRIBUTE) == true
end

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
	if not isAdmin() and open then
		setOpen(false)
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
end

function AdminController.start()
	ContextActionService:BindActionAtPriority(TOGGLE_ACTION, function(_, inputState)
		if inputState == Enum.UserInputState.Begin and isAdmin() then
			setOpen(not open)
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.P)
end

return AdminController
