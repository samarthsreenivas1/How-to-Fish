--!nonstrict
-- MenuButtonsController.luau
-- The bottom-left menu buttons: Bag (inventory), Map (islands), Quests, Log,
-- Hall and - for admins only - Admin. Each is a tile with a token and the key that
-- also opens it; the lit one follows the menus' real state (isOpen()), so
-- opening with a hotkey lights it too. Also what lets touch open the menus
-- at all.
--
-- Each button toggles its own menu through that controller's exported
-- setOpen() and closes the others first, so two modal backdrops never
-- stack.
--
-- Desktop caveat: first person locks the mouse to the centre of the screen
-- (CameraController), so a button can't be clicked while nothing is open.
-- Holding ALT frees the cursor (a key cap beside the row says so); the menus
-- free it while they're open, so switching menus by button works without
-- ALT. The buttons' ScreenGui sits above the menus' backdrops so they stay
-- clickable while one is open. Restyled in the 2026-08-23 overhaul; the
-- behaviour is unchanged.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Theme = require(script.Parent.Parent.UI.Theme)
local Kit = require(script.Parent.Parent.UI.Kit)
local Sfx = require(script.Parent.Parent.Modules.Sfx)
local AdminController = require(script.Parent.AdminController)
local CameraController = require(script.Parent.CameraController)
local InventoryController = require(script.Parent.InventoryController)
local IslandsController = require(script.Parent.IslandsController)
local TrophyController = require(script.Parent.TrophyController)
local QuestController = require(script.Parent.QuestController)
local CollectionsController = require(script.Parent.CollectionsController)

local player = Players.LocalPlayer

local MenuButtonsController = {}

local C = Theme.Color
local F = Theme.Font

local MARGIN = Vector2.new(22, 20)
local BUTTON_SIZE = Theme.MIN_TAP
local BUTTON_GAP = 10

local ADMIN_ATTRIBUTE = "IsAdmin"
local FREE_CURSOR_ACTION = "MenuButtonsFreeCursor"

local BUTTONS = {
	{
		id = "inventory",
		label = "Bag",
		token = "BAG",
		hint = "I",
		color = C.accentDark,
		controller = InventoryController,
	},
	{
		id = "islands",
		label = "Map",
		token = "MAP",
		hint = "T",
		color = Color3.fromRGB(40, 120, 110),
		controller = IslandsController,
	},
	{
		id = "quests",
		label = "Quests",
		token = "QUEST",
		hint = "J",
		color = Color3.fromRGB(178, 132, 38),
		controller = QuestController,
	},
	{
		id = "collections",
		label = "Log",
		token = "FISH",
		hint = "N",
		color = Color3.fromRGB(38, 132, 158),
		controller = CollectionsController,
	},
	{
		id = "trophies",
		label = "Hall",
		token = "HALL",
		hint = "H",
		color = C.violet,
		controller = TrophyController,
	},
	{
		id = "admin",
		label = "Admin",
		token = "P",
		hint = "P",
		color = C.red,
		controller = AdminController,
		adminOnly = true,
	},
}

local gui: ScreenGui
local buttons: { [string]: TextButton } = {}
local altHeld = false
local freeBeforeAlt = false

-- ============================================================ helpers

local function anyMenuOpen(): boolean
	for _, spec in BUTTONS do
		if spec.controller.isOpen() then
			return true
		end
	end
	return false
end

local function isAdmin(): boolean
	return player:GetAttribute(ADMIN_ATTRIBUTE) == true
end

local function toggle(spec)
	local wasOpen = spec.controller.isOpen()
	for _, other in BUTTONS do
		if other ~= spec and other.controller.isOpen() then
			other.controller.setOpen(false)
		end
	end
	spec.controller.setOpen(not wasOpen)
end

-- ============================================================ build

local function buildButton(spec, index: number): TextButton
	local button = Instance.new("TextButton")
	button.Name = spec.id
	button.AutoButtonColor = false
	button.Text = ""
	button.BorderSizePixel = 0
	button.LayoutOrder = index
	button.Size = UDim2.fromOffset(BUTTON_SIZE, BUTTON_SIZE + 18)
	button.BackgroundTransparency = 1
	Kit.corner(button, 16)

	-- The tile is the button's face; the label sits under it.
	local tile = Kit.tile(button, {
		name = "Tile",
		size = BUTTON_SIZE,
		color = spec.color,
		token = spec.token,
		tokenSize = 13,
		radius = 16,
	})
	tile.BackgroundTransparency = 0.1
	local stroke = tile:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Name = "Stroke"
	end

	Kit.keyCap(tile, spec.hint, {
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -4, 1, -4),
		Size = UDim2.fromOffset(18, 16),
		TextSize = 10,
	})

	Kit.label(button, {
		Name = "Label",
		Font = F.header,
		TextSize = 13,
		TextColor3 = C.text,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextStrokeColor3 = C.background,
		TextStrokeTransparency = 0.5,
		Text = spec.label,
		Position = UDim2.new(0, 0, 0, BUTTON_SIZE + 2),
		Size = UDim2.new(1, 0, 0, 16),
	})

	button.MouseEnter:Connect(function()
		Sfx.play("uiHover")
		TweenService:Create(tile, TweenInfo.new(0.08), { Size = UDim2.fromOffset(BUTTON_SIZE + 4, BUTTON_SIZE + 4) })
			:Play()
	end)
	button.MouseLeave:Connect(function()
		TweenService:Create(tile, TweenInfo.new(0.08), { Size = UDim2.fromOffset(BUTTON_SIZE, BUTTON_SIZE) }):Play()
	end)
	button.Activated:Connect(function()
		-- No uiClick: `toggle` opens or closes a panel, and each of those plays
		-- uiOpen / uiClose a frame later. A click stacked in front of them was
		-- two sounds for one press, and the second is the one that carries the
		-- information. uiHover on the way in stays - it is the only feedback
		-- these tiles have before the press.
		toggle(spec)
	end)

	return button
end

local function buildUi()
	gui = Instance.new("ScreenGui")
	gui.Name = "MenuButtonsGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 40
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local row = Kit.frame(gui, {
		Name = "Row",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, MARGIN.X, 1, -MARGIN.Y),
		Size = UDim2.new(0, (BUTTON_SIZE + BUTTON_GAP) * #BUTTONS + 80, 0, BUTTON_SIZE + 18),
	})
	Kit.listLayout(row, BUTTON_GAP, true)

	for i, spec in BUTTONS do
		local button = buildButton(spec, i)
		button.Parent = row
		buttons[spec.id] = button
	end

	-- Desktop-only hint at the row's end: "ALT  free cursor".
	if UserInputService.KeyboardEnabled and not UserInputService.TouchEnabled then
		local hint =
			Kit.frame(row, { Name = "Hint", Size = UDim2.fromOffset(84, BUTTON_SIZE), LayoutOrder = #BUTTONS + 1 })
		Kit.keyCap(hint, "ALT", { Position = UDim2.new(0, 0, 0.5, -9) })
		Kit.label(hint, {
			Font = F.body,
			TextSize = 11,
			TextColor3 = C.textDim,
			TextStrokeColor3 = C.background,
			TextStrokeTransparency = 0.5,
			Text = "free cursor",
			Position = UDim2.new(0, 38, 0.5, -9),
			Size = UDim2.new(1, -38, 0, 18),
		})
	end

	gui.Parent = player:WaitForChild("PlayerGui")
end

-- ============================================================ refresh

local function refresh()
	for _, spec in BUTTONS do
		local button = buttons[spec.id]
		local visible = not spec.adminOnly or isAdmin()
		button.Visible = visible
		local open = visible and spec.controller.isOpen()
		local tile = button:FindFirstChild("Tile")
		local stroke = tile and tile:FindFirstChild("Stroke")
		if stroke then
			stroke.Color = if open then C.accent else Color3.new(1, 1, 1)
			stroke.Thickness = if open then 3 else 1
			stroke.Transparency = if open then 0 else 0.82
		end
		local label = button:FindFirstChild("Label")
		if label then
			label.TextColor3 = if open then C.accent else C.text
		end
	end
end

-- ============================================================ ALT to free the cursor

local function onFreeCursor(_, state: Enum.UserInputState)
	if state == Enum.UserInputState.Begin then
		if not altHeld then
			freeBeforeAlt = CameraController.isCursorFree()
		end
		altHeld = true
		CameraController.setCursorFree(true)
		-- Only the cursor actually LEAVING the crosshair is worth a cue. If it
		-- was already free (a menu is open, or the player is in third person)
		-- ALT changes nothing, and a click there would be a phantom.
		if not freeBeforeAlt then
			Sfx.play("cursorFree")
		end
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		altHeld = false
		-- Releasing ALT only re-locks when nothing else wants the cursor free;
		-- otherwise the cursor stays out and there is nothing to hear, so the
		-- cue follows where the cursor ENDED UP rather than the key going up.
		local stillFree = freeBeforeAlt or anyMenuOpen()
		CameraController.setCursorFree(stillFree)
		if not stillFree then
			Sfx.play("cursorLock")
		end
	end
	return Enum.ContextActionResult.Sink
end

-- ============================================================ lifecycle

function MenuButtonsController.init()
	buildUi()
	player:GetAttributeChangedSignal(ADMIN_ATTRIBUTE):Connect(refresh)
end

function MenuButtonsController.start()
	refresh()
	RunService.RenderStepped:Connect(refresh)
	ContextActionService:BindActionAtPriority(
		FREE_CURSOR_ACTION,
		onFreeCursor,
		false,
		Enum.ContextActionPriority.High.Value,
		Enum.KeyCode.LeftAlt,
		Enum.KeyCode.RightAlt
	)
end

function MenuButtonsController.isCursorHeldFree(): boolean
	return altHeld
end

return MenuButtonsController
