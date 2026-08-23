--!nonstrict
-- IslandsController.luau
-- The Islands travel menu: T (or the bottom-left MAP button) opens a centred
-- window listing every island in Shared/Config/Islands as a card - an art
-- tile in the island's own colours, its name and blurb, a level chip, and
-- the boss that guards the way there - with a Travel button. Clicking asks
-- the server (WorldService) to teleport the character; the server re-checks
-- placement, the level unlock and the boss gate and replies on
-- TeleportResult - the menu closes on success or shows why it was refused.
--
-- The Travel button is ALWAYS there except on the island you're standing on
-- (user bug, 2026-08-22: a card with a tag and nothing to press read as
-- "nothing happens"). The SERVER is the authority on whether a trip is
-- allowed; its reason shows on the status line under the list. Rebuilt on
-- the shared UI kit in the 2026-08-23 overhaul; setOpen / isOpen / init /
-- start and the T hotkey are unchanged.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Islands = require(Shared.Config.Islands)
local World = require(Shared.Config.World)
local Bosses = require(Shared.Data.Bosses)
local Progression = require(Shared.Modules.Progression)
local Remotes = require(Shared.Net.Remotes)

local Theme = require(script.Parent.Parent.UI.Theme)
local Kit = require(script.Parent.Parent.UI.Kit)
local CameraController = require(script.Parent.CameraController)

local player = Players.LocalPlayer

local IslandsController = {}

local C = Theme.Color
local F = Theme.Font

local CARD_HEIGHT = 118
local TOGGLE_ACTION = "IslandsMenuToggle"

-- Each island's art: a two-colour gradient tile and a short token. Keyed by
-- island id; anything unlisted gets the sea.
local ART = {
	tropical = { top = Color3.fromRGB(92, 214, 226), bottom = Color3.fromRGB(236, 217, 166), token = "COVE" },
	volcano = { top = Color3.fromRGB(255, 140, 60), bottom = Color3.fromRGB(48, 30, 36), token = "ASH" },
}
local ART_DEFAULT = { top = C.accent, bottom = C.accentDark, token = "ISLE" }

local modal
local list: ScrollingFrame
local status: TextLabel
local cards: { [string]: { travel: TextButton, here: TextLabel, level: Frame } } = {}

-- ============================================================ helpers

-- The island the character is standing on (nearest centre within its own
-- footprint), or nil.
local function currentIslandId(): string?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return nil
	end
	local here: string? = nil
	local bestDist = math.huge
	for _, id in Islands.order do
		local entry = Islands.items[id]
		local p = entry.worldPosition
		local dist = (Vector2.new(root.Position.X, root.Position.Z) - Vector2.new(p.X, p.Z)).Magnitude
		if dist < (entry.radius or World.ISLAND_RADIUS) * 1.5 and dist < bestDist then
			bestDist = dist
			here = id
		end
	end
	return here
end

local function level(): number
	return player:GetAttribute(Progression.ATTR.level) or Progression.START_LEVEL
end

-- The boss that guards the way TO this island: the previous island's.
local function guardFor(id: string)
	local index = table.find(Islands.order, id)
	if not index or index <= 1 then
		return nil
	end
	local prevId = Islands.order[index - 1]
	local prev = Islands.items[prevId]
	local boss = prev and prev.boss and Bosses.items[prev.boss]
	if not boss then
		return nil
	end
	return boss, prevId
end

-- ============================================================ render

local function render()
	local here = currentIslandId()
	for id, refs in cards do
		local onIt = id == here
		refs.travel.Visible = not onIt
		refs.here.Visible = onIt
		local entry = Islands.items[id]
		local ok = level() >= (entry.unlockLevel or 0)
		local label = refs.level:FindFirstChild("Label")
		if label then
			label.TextColor3 = if ok then C.green else C.red
		end
	end
end

-- ============================================================ build

local function buildCard(id: string, index: number): Frame
	local entry = Islands.items[id]
	local art = ART[id] or ART_DEFAULT

	local card = Kit.panel(list, {
		Name = "Island_" .. id,
		LayoutOrder = index,
		Size = UDim2.new(1, 0, 0, CARD_HEIGHT),
		BackgroundColor3 = C.panelLight,
	})

	-- The art tile: the island's colours, its token.
	local tile = Kit.tile(card, {
		name = "Art",
		size = CARD_HEIGHT - 24,
		color = art.top,
		token = art.token,
		tokenSize = 16,
		position = UDim2.new(0, 12, 0.5, 0),
		anchor = Vector2.new(0, 0.5),
		radius = 14,
	})
	local gradient = tile:FindFirstChildOfClass("UIGradient")
	if gradient then
		gradient.Color = ColorSequence.new(art.top, art.bottom)
		gradient.Rotation = 60
	end

	local textX = CARD_HEIGHT + 4
	Kit.label(card, {
		Name = "Name",
		Font = F.header,
		TextSize = 20,
		TextColor3 = C.text,
		Text = entry.name,
		Position = UDim2.new(0, textX, 0, 14),
		Size = UDim2.new(1, -(textX + 150), 0, 24),
	})
	Kit.label(card, {
		Name = "Blurb",
		Font = F.body,
		TextSize = 13,
		TextColor3 = C.textDim,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = entry.blurb,
		Position = UDim2.new(0, textX, 0, 40),
		Size = UDim2.new(1, -(textX + 150), 0, 34),
	})

	-- Chips along the bottom: the level it needs, and who guards the way.
	local chips = Kit.frame(card, {
		Name = "Chips",
		Position = UDim2.new(0, textX, 1, -34),
		Size = UDim2.new(1, -(textX + 150), 0, 24),
	})
	Kit.listLayout(chips, 6, true)

	local function chip(name: string, token: string, text: string, color: Color3, order: number): Frame
		local holder = Kit.frame(chips, {
			Name = name,
			Size = UDim2.fromOffset(0, 24),
			AutomaticSize = Enum.AutomaticSize.X,
			LayoutOrder = order,
			BackgroundTransparency = 0.35,
			BackgroundColor3 = C.background,
		})
		Kit.corner(holder, 12)
		Kit.padding(holder, 4, 0, 10, 0)
		Kit.tile(holder, {
			name = "Tile",
			size = 18,
			color = color,
			token = token,
			tokenSize = 8,
			position = UDim2.new(0, 0, 0.5, 0),
			anchor = Vector2.new(0, 0.5),
			radius = 6,
		})
		Kit.label(holder, {
			Name = "Label",
			Font = F.bodyBold,
			TextSize = 12,
			TextColor3 = C.text,
			Text = text,
			AutomaticSize = Enum.AutomaticSize.X,
			Position = UDim2.new(0, 24, 0, 0),
			Size = UDim2.new(0, 0, 1, 0),
		})
		return holder
	end

	local levelChip = chip(
		"Level",
		"LV",
		if (entry.unlockLevel or 0) > 0 then "Level " .. entry.unlockLevel else "Open to all",
		C.accentDark,
		1
	)
	local guard = guardFor(id)
	if guard then
		chip("Guard", "BOSS", "Beat " .. guard.shortName .. " first", Color3.fromRGB(255, 90, 70), 2)
	end
	if entry.boss and Bosses.items[entry.boss] then
		chip("Boss", "!", "Home of " .. Bosses.items[entry.boss].shortName, C.violet, 3)
	end

	-- Travel, or "You are here".
	local travel = Kit.button(card, {
		name = "Travel",
		text = "Travel",
		style = "primary",
		size = UDim2.fromOffset(124, 44),
		anchor = Vector2.new(1, 0.5),
		position = UDim2.new(1, -14, 0.5, 0),
	})
	travel.Activated:Connect(function()
		status.Text = string.format("Setting sail for %s...", entry.name)
		status.TextColor3 = C.textDim
		Remotes.RequestTeleport:FireServer(id)
	end)

	local here = Kit.label(card, {
		Name = "Here",
		Font = F.header,
		TextSize = 14,
		TextColor3 = C.accent,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "YOU ARE HERE",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.fromOffset(124, 44),
		BackgroundTransparency = 0.4,
		BackgroundColor3 = C.background,
		Visible = false,
	})
	Kit.corner(here, 12)
	Kit.stroke(here, C.accent, 1, 0.5)

	cards[id] = { travel = travel, here = here, level = levelChip }
	return card
end

local function buildUi()
	modal = Kit.modal({
		name = "IslandsGui",
		title = "Set Sail",
		subtitle = "Pick an island to travel to",
		token = "MAP",
		size = UDim2.fromOffset(560, 500),
		minSize = Vector2.new(520, 380),
		maxSize = Vector2.new(640, 620),
	})
	local body = modal.body

	list = Kit.scroll(body, {
		name = "List",
		position = UDim2.new(0, 16, 0, 16),
		size = UDim2.new(1, -32, 1, -(16 + 40 + 12)),
		gap = 10,
		padding = 2,
	})
	for i, id in Islands.order do
		if Islands.items[id] then
			buildCard(id, i)
		end
	end

	status = Kit.label(body, {
		Name = "Status",
		Font = F.bodyBold,
		TextSize = 13,
		TextColor3 = C.textDim,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -14),
		Size = UDim2.new(1, -32, 0, 28),
	})

	modal.close.Activated:Connect(function()
		IslandsController.setOpen(false)
	end)
	modal.backdrop.Activated:Connect(function()
		IslandsController.setOpen(false)
	end)

	modal.gui.Parent = player:WaitForChild("PlayerGui")
end

-- ============================================================ open / close

function IslandsController.setOpen(open: boolean)
	if not modal then
		return
	end
	modal.backdrop.Visible = open
	CameraController.setCursorFree(open)
	if open then
		status.Text = ""
		render()
	end
end

function IslandsController.isOpen(): boolean
	return modal ~= nil and modal.backdrop.Visible
end

-- ============================================================ lifecycle

function IslandsController.init()
	buildUi()

	Remotes.TeleportResult.OnClientEvent:Connect(function(result)
		if type(result) ~= "table" then
			return
		end
		if result.ok then
			IslandsController.setOpen(false)
		elseif modal.backdrop.Visible then
			status.Text = tostring(result.reason or "Can't travel there")
			status.TextColor3 = C.red
		end
	end)
	player:GetAttributeChangedSignal(Progression.ATTR.level):Connect(function()
		if modal.backdrop.Visible then
			render()
		end
	end)
end

function IslandsController.start()
	ContextActionService:BindActionAtPriority(TOGGLE_ACTION, function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			IslandsController.setOpen(not IslandsController.isOpen())
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.T)
end

return IslandsController
