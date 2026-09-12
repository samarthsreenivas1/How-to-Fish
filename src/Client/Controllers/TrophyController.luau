--!nonstrict
-- TrophyController.luau
-- The Trophy Hall: H (or the bottom-left HALL button) opens a centred window
-- with one card per island boss in saga order - the boss's heart as a lit,
-- coloured tile once it's been claimed, a dimmed silhouette until then. A
-- heart is the permanent `Heart_<bossId>` Player attribute BossService sets
-- on the kill (persisted by DataService), so this menu is purely a reader:
-- no remotes, it re-renders whenever a Heart_* attribute changes.
--
-- The subtitle counts progress, and the status line under the list spells
-- out the meta: every island heart is needed (owned, never spent) before
-- Kraken's Call can be crafted. The Kraken's own heart is the final trophy
-- and sits at the end of the list once its Bosses entry exists - the card
-- list is derived from Islands.order plus any remaining Bosses rows (the
-- Maelstrom is a site outside the order), so new bosses appear here with no
-- edit to this file.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Islands = require(Shared.Config.Islands)
local Bosses = require(Shared.Data.Bosses)

local Theme = require(script.Parent.Parent.UI.Theme)
local Kit = require(script.Parent.Parent.UI.Kit)
local CameraController = require(script.Parent.CameraController)
local Sfx = require(script.Parent.Parent.Modules.Sfx)

local player = Players.LocalPlayer

local TrophyController = {}

local C = Theme.Color
local F = Theme.Font

local CARD_HEIGHT = 96
local TOGGLE_ACTION = "TrophyMenuToggle"
local HEART_ATTRIBUTE_PREFIX = "Heart_"

-- Each heart's colour when lit. Anything unlisted gets the violet default,
-- so a new boss never renders invisible-grey.
local HEART_COLORS: { [string]: Color3 } = {
	brinejaw = Color3.fromRGB(64, 190, 200), -- drowned teal
	old_gnashroot = Color3.fromRGB(150, 235, 200), -- the gnashroot core
	rimefang = Color3.fromRGB(120, 190, 255), -- glacier blue
	pyrelisk = Color3.fromRGB(255, 128, 48), -- caldera ember
	noctyss = Color3.fromRGB(150, 110, 235), -- abyssal violet
	admiral_wrack = Color3.fromRGB(140, 205, 160), -- ghost-fleet green
	kraken = Color3.fromRGB(90, 130, 255), -- storm blue
}
local HEART_DEFAULT = Color3.fromRGB(150, 110, 235)

local modal
local list: ScrollingFrame
local cards: { [string]: { tile: Frame, pill: TextLabel, name: TextLabel } } = {}

-- ============================================================ helpers

-- Saga order: every island's boss in travel order, then any boss whose
-- island isn't in the order (the Maelstrom site's Kraken), by gate level.
local function bossOrder(): { string }
	local ordered = {}
	local seen = {}
	for _, islandId in Islands.order do
		local entry = Islands.items[islandId]
		local bossId = entry and entry.boss
		if bossId and Bosses.items[bossId] and not seen[bossId] then
			seen[bossId] = true
			table.insert(ordered, bossId)
		end
	end
	local rest = {}
	for bossId in Bosses.items do
		if not seen[bossId] then
			table.insert(rest, bossId)
		end
	end
	table.sort(rest, function(a, b)
		local ga = Bosses.items[a].gate and Bosses.items[a].gate.level or 0
		local gb = Bosses.items[b].gate and Bosses.items[b].gate.level or 0
		if ga ~= gb then
			return ga < gb
		end
		return a < b
	end)
	for _, bossId in rest do
		table.insert(ordered, bossId)
	end
	return ordered
end

local function hasHeart(bossId: string): boolean
	return player:GetAttribute(HEART_ATTRIBUTE_PREFIX .. bossId) == true
end

-- ============================================================ render

local function render()
	local owned = 0
	local total = 0
	for bossId, refs in cards do
		total += 1
		local lit = hasHeart(bossId)
		if lit then
			owned += 1
		end
		local color = HEART_COLORS[bossId] or HEART_DEFAULT
		refs.tile.BackgroundColor3 = if lit then color else C.panelLight
		local gradient = refs.tile:FindFirstChildOfClass("UIGradient")
		if gradient then
			gradient.Color = if lit
				then ColorSequence.new(color, color:Lerp(C.background, 0.55))
				else ColorSequence.new(C.panelLight, C.background)
		end
		local token = refs.tile:FindFirstChild("Token")
		if token and token:IsA("TextLabel") then
			token.TextTransparency = if lit then 0 else 0.55
		end
		refs.pill.Text = if lit then "HEART CLAIMED" else "UNDEFEATED"
		refs.pill.TextColor3 = if lit then color else C.textDim
		refs.name.TextColor3 = if lit then C.text else C.textDim
	end
	if modal then
		modal.subtitle.Text = string.format("%d of %d hearts claimed", owned, total)
	end
end

-- ============================================================ build

local function buildCard(bossId: string, index: number): Frame
	local boss = Bosses.items[bossId]
	local island = Islands.items[boss.islandId]

	local card = Kit.panel(list, {
		Name = "Heart_" .. bossId,
		LayoutOrder = index,
		Size = UDim2.new(1, 0, 0, CARD_HEIGHT),
		BackgroundColor3 = C.panelLight,
	})

	local tile = Kit.tile(card, {
		name = "Heart",
		size = CARD_HEIGHT - 24,
		color = C.panelLight,
		token = Kit.monogram(boss.shortName),
		tokenSize = 16,
		position = UDim2.new(0, 12, 0.5, 0),
		anchor = Vector2.new(0, 0.5),
		radius = 14,
	})

	local textX = CARD_HEIGHT + 4
	local name = Kit.label(card, {
		Name = "Name",
		Font = F.header,
		TextSize = 18,
		TextColor3 = C.text,
		Text = boss.name,
		Position = UDim2.new(0, textX, 0, 14),
		Size = UDim2.new(1, -(textX + 150), 0, 22),
	})
	Kit.label(card, {
		Name = "Island",
		Font = F.body,
		TextSize = 13,
		TextColor3 = C.textDim,
		Text = if island then island.name else boss.islandId,
		Position = UDim2.new(0, textX, 0, 38),
		Size = UDim2.new(1, -(textX + 150), 0, 18),
	})
	Kit.label(card, {
		Name = "Gate",
		Font = F.bodyBold,
		TextSize = 12,
		TextColor3 = C.textDim,
		Text = if boss.gate and boss.gate.level then string.format("A level %d hunt", boss.gate.level) else "",
		Position = UDim2.new(0, textX, 1, -30),
		Size = UDim2.new(1, -(textX + 150), 0, 18),
	})

	local pill = Kit.label(card, {
		Name = "Pill",
		Font = F.header,
		TextSize = 13,
		TextColor3 = C.textDim,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "UNDEFEATED",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.fromOffset(136, 40),
		BackgroundTransparency = 0.4,
		BackgroundColor3 = C.background,
	})
	Kit.corner(pill, 12)

	cards[bossId] = { tile = tile, pill = pill, name = name }
	return card
end

local function buildUi()
	modal = Kit.modal({
		name = "TrophyGui",
		title = "Trophy Hall",
		subtitle = "",
		token = "HALL",
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
	for i, bossId in bossOrder() do
		buildCard(bossId, i)
	end

	Kit.label(body, {
		Name = "Status",
		Font = F.bodyBold,
		TextSize = 13,
		TextColor3 = C.textDim,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "Every island's heart is kept, never spent - claim all six to craft Kraken's Call.",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -14),
		Size = UDim2.new(1, -32, 0, 28),
	})

	modal.close.Activated:Connect(function()
		TrophyController.setOpen(false)
	end)
	modal.backdrop.Activated:Connect(function()
		TrophyController.setOpen(false)
	end)

	modal.gui.Parent = player:WaitForChild("PlayerGui")
end

-- ============================================================ open / close

function TrophyController.setOpen(open: boolean)
	if not modal then
		return
	end
	-- Guarded on the CHANGE: the menu row closes every other menu before it
	-- opens one, so setOpen(false) arrives on an already-closed hall all the
	-- time and an unguarded cue would click on every menu switch.
	local changed = modal.backdrop.Visible ~= open
	modal.backdrop.Visible = open
	CameraController.setCursorFree(open)
	if changed then
		Sfx.play(if open then "uiOpen" else "uiClose")
	end
	if open then
		render()
	end
end

function TrophyController.isOpen(): boolean
	return modal ~= nil and modal.backdrop.Visible
end

-- ============================================================ lifecycle

function TrophyController.init()
	buildUi()
	render()

	player.AttributeChanged:Connect(function(attribute: string)
		if string.sub(attribute, 1, #HEART_ATTRIBUTE_PREFIX) == HEART_ATTRIBUTE_PREFIX then
			render()
		end
	end)
end

function TrophyController.start()
	ContextActionService:BindActionAtPriority(TOGGLE_ACTION, function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			TrophyController.setOpen(not TrophyController.isOpen())
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.H)
end

return TrophyController
