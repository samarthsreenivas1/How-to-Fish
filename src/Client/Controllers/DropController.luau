--!nonstrict
-- DropController.luau
-- The "You found: X!" banner when a killed creature drops a rare finished
-- item. DropService fires ItemDropped with the id; the item itself has already
-- landed in the inventory (grantItem pushes InventoryUpdated). This is just the
-- fanfare - centre-screen and standalone so a jackpot reads big, separate from
-- the bottom-right reward pops.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rods = require(Shared.Data.Rods)
local Weapons = require(Shared.Data.Weapons)
local Remotes = require(Shared.Net.Remotes)

local Theme = require(script.Parent.Parent.UI.Theme)

local player = Players.LocalPlayer

local DropController = {}

-- Below the fishing grade banner (y=40) and level banner (y=84).
local BANNER_Y = 122
local HOLD = 3.0

local gui: ScreenGui
local label: TextLabel

local function nameFor(itemId: string): string
	local item = Rods.items[itemId] or Weapons.items[itemId]
	return (item and item.name) or itemId
end

local function show(itemId)
	if type(itemId) ~= "string" then
		return
	end
	local text = string.format("You found: %s!", nameFor(itemId))
	label.Text = text
	label.Visible = true
	label.TextTransparency = 0
	label.TextStrokeTransparency = 0.4

	-- Pop up into place, hold, then fade.
	label.Position = UDim2.new(0.5, 0, 0, BANNER_Y + 14)
	TweenService:Create(label, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = UDim2.new(0.5, 0, 0, BANNER_Y),
	}):Play()

	task.delay(HOLD, function()
		if label.Text ~= text then
			return
		end
		TweenService:Create(label, TweenInfo.new(0.5), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		task.delay(0.5, function()
			if label.Text == text then
				label.Visible = false
			end
		end)
	end)
end

function DropController.init()
	gui = Instance.new("ScreenGui")
	gui.Name = "DropGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	label = Instance.new("TextLabel")
	label.Name = "Banner"
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Position = UDim2.new(0.5, 0, 0, BANNER_Y)
	label.Size = UDim2.fromOffset(560, 40)
	label.BackgroundTransparency = 1
	label.Font = Theme.Font.header
	label.TextSize = 28
	label.TextColor3 = Theme.Color.accent
	label.TextStrokeColor3 = Color3.fromRGB(10, 14, 20)
	label.TextStrokeTransparency = 0.4
	label.Text = ""
	label.Visible = false
	label.Parent = gui

	Remotes.ItemDropped.OnClientEvent:Connect(show)
	gui.Parent = player:WaitForChild("PlayerGui")
end

function DropController.start() end

return DropController
