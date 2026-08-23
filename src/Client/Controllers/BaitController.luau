--!nonstrict
-- BaitController.luau
-- The active-bait HUD chip (bottom-right, above the coins / XP readout) and
-- the cycle hotkey. Bait is selected server-side (BaitService publishes the
-- Equipment.BAIT_ATTRIBUTE Player attribute); this shows which bait is on
-- the hook and how many you have, and gives Q as a quick way to cycle
-- through the baits you own (and back to none) without opening a menu. The
-- Inventory / Crafting bait tabs are the other way to select.
--
-- Counts come the material way: GetBait pulls once, BaitUpdated pushes. The
-- selection is read straight off the attribute so it stays live for free.
-- Restyled in the 2026-08-23 overhaul; behaviour unchanged.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Bait = require(Shared.Data.Bait)
local Equipment = require(Shared.Config.Equipment)
local Rarity = require(Shared.Modules.Rarity)
local Remotes = require(Shared.Net.Remotes)

local Theme = require(script.Parent.Parent.UI.Theme)
local Kit = require(script.Parent.Parent.UI.Kit)

local player = Players.LocalPlayer

local BaitController = {}

local C = Theme.Color
local F = Theme.Font

local CYCLE_KEY = Enum.KeyCode.Q

local baitCounts: { [string]: number } = {}
local frame: Frame
local tileHolder: Frame
local nameLabel: TextLabel
local countLabel: TextLabel

local function selectedId(): string
	return player:GetAttribute(Equipment.BAIT_ATTRIBUTE) or ""
end

local function ownedOrder(): { string }
	local list = {}
	for _, id in Bait.order do
		if (baitCounts[id] or 0) > 0 then
			table.insert(list, id)
		end
	end
	return list
end

-- ============================================================ HUD

local function setTile(bait)
	for _, child in tileHolder:GetChildren() do
		child:Destroy()
	end
	Kit.tile(tileHolder, {
		size = 34,
		color = if bait then (bait.color or Rarity.colorOf(bait.rarity)) else C.panelLight,
		image = bait and bait.icon or nil,
		token = if bait then Kit.monogram(bait.name) else "-",
		tokenSize = 12,
		radius = 10,
	})
end

local function render()
	if not frame then
		return
	end

	local id = selectedId()
	local bait = id ~= "" and Bait.items[id] or nil
	local owned = ownedOrder()

	frame.Visible = bait ~= nil or #owned > 0
	if not frame.Visible then
		return
	end

	setTile(bait)
	if bait then
		local count = baitCounts[id] or 0
		nameLabel.Text = bait.name
		nameLabel.TextColor3 = if count > 0 then C.text else C.textDim
		countLabel.Text = "x" .. tostring(count)
		countLabel.Visible = true
	else
		nameLabel.Text = "No bait"
		nameLabel.TextColor3 = C.textDim
		countLabel.Visible = false
	end
end

local function buildUi()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "BaitHud"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	frame = Kit.panel(screenGui, {
		Name = "Bait",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -18, 1, -96),
		Size = UDim2.fromOffset(196, 48),
		BackgroundColor3 = C.panel,
		BackgroundTransparency = 0.15,
		Visible = false,
	})

	tileHolder = Kit.frame(frame, {
		Name = "TileHolder",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 7, 0.5, 0),
		Size = UDim2.fromOffset(34, 34),
	})

	Kit.label(frame, {
		Name = "Tag",
		Font = F.header,
		TextSize = 10,
		TextColor3 = C.accent,
		Text = "ON THE HOOK",
		Position = UDim2.new(0, 50, 0, 6),
		Size = UDim2.new(1, -86, 0, 12),
	})
	nameLabel = Kit.label(frame, {
		Name = "Name",
		Font = F.bodyBold,
		TextSize = 13,
		TextColor3 = C.text,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = "No bait",
		Position = UDim2.new(0, 50, 0, 20),
		Size = UDim2.new(1, -96, 0, 20),
	})
	countLabel = Kit.label(frame, {
		Name = "Count",
		Font = F.header,
		TextSize = 12,
		TextColor3 = C.text,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -30, 0.5, 0),
		Size = UDim2.fromOffset(34, 20),
		BackgroundTransparency = 0.3,
		BackgroundColor3 = C.background,
		Visible = false,
	})
	Kit.corner(countLabel, 10)
	Kit.keyCap(frame, "Q", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -6, 0.5, 0),
	})

	screenGui.Parent = player:WaitForChild("PlayerGui")
end

-- ============================================================ cycle hotkey

local function cycle()
	local owned = ownedOrder()
	if #owned == 0 then
		if selectedId() ~= "" then
			Remotes.RequestSelectBait:FireServer("")
		end
		return
	end
	local seq = table.clone(owned)
	table.insert(seq, "")
	local current = selectedId()
	local index = 0
	for i, id in seq do
		if id == current then
			index = i
			break
		end
	end
	Remotes.RequestSelectBait:FireServer(seq[(index % #seq) + 1])
end

-- ============================================================ lifecycle

function BaitController.init()
	buildUi()

	Remotes.BaitUpdated.OnClientEvent:Connect(function(all)
		if type(all) == "table" then
			baitCounts = all
			render()
		end
	end)
	player:GetAttributeChangedSignal(Equipment.BAIT_ATTRIBUTE):Connect(render)

	ContextActionService:BindAction("CycleBait", function(_, state)
		if state == Enum.UserInputState.Begin then
			cycle()
		end
		return Enum.ContextActionResult.Pass
	end, false, CYCLE_KEY)
end

function BaitController.start()
	local ok, result = pcall(function()
		return Remotes.GetBait:InvokeServer()
	end)
	if ok and type(result) == "table" then
		baitCounts = result
	end
	render()
end

return BaitController
