--!nonstrict
-- RaidHudController.luau
-- The raid's presence on screen (BossHudController's shape, filtered to the
-- island the LOCAL player is standing on): an "A RAID APPROACHES" card with
-- the countdown while one is announced, a compact status line during the
-- waves (wave k/N, enemies remaining), and the cleared/failed card at the
-- end. Everything rides the one RaidState remote RaidService broadcasts
-- every second - late joiners and island-hoppers self-heal on the next tick,
-- and a tick for someone ELSE'S island just clears ours.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Islands = require(Shared.Config.Islands)
local Remotes = require(Shared.Net.Remotes)

local Theme = require(script.Parent.Parent.UI.Theme)

local player = Players.LocalPlayer

local RaidHudController = {}

-- ---------------------------------------------------------------- layout

local LINE_Y = 154 -- below the boss bar's band (124): both can show in a boss raid
local LINE_SIZE = 18

local RAID_COLOR = Color3.fromRGB(255, 170, 70)
local FAIL_COLOR = Color3.fromRGB(255, 96, 80)

local CARD_Y = 0.3
local CARD_TITLE_SIZE = 38
local CARD_SUB_SIZE = 18
local CARD_IN = 0.45
local CARD_HOLD = 2.6
local CARD_OUT = 0.6

-- How far past an island's shoreline still counts as "on it" (the dock).
local ISLAND_MARGIN = 160

-- ---------------------------------------------------------------- state

local gui: ScreenGui
local line: TextLabel
local cardTitle: TextLabel
local cardSub: TextLabel

local cardToken = 0
local shownIsland: string? = nil -- the island whose raid the line is showing
local lastPhase: { [string]: string } = {} -- islandId -> phase, for edge-triggered cards

-- ---------------------------------------------------------------- build

local function label(parent: Instance, props: { [string]: any }): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = Theme.Font.header
	l.TextColor3 = Theme.Color.text
	l.TextStrokeColor3 = Color3.fromRGB(8, 12, 18)
	l.TextStrokeTransparency = 0.4
	l.TextXAlignment = Enum.TextXAlignment.Center
	for key, value in props do
		l[key] = value
	end
	l.Parent = parent
	return l
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "RaidHudGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 5

	line = label(gui, {
		Name = "RaidLine",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, LINE_Y),
		Size = UDim2.new(1, 0, 0, LINE_SIZE + 4),
		TextSize = LINE_SIZE,
		TextColor3 = RAID_COLOR,
		Text = "",
		Visible = false,
	})

	cardTitle = label(gui, {
		Name = "CardTitle",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, CARD_Y),
		Size = UDim2.new(1, 0, 0, CARD_TITLE_SIZE + 6),
		TextSize = CARD_TITLE_SIZE,
		Text = "",
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	})
	cardSub = label(gui, {
		Name = "CardSub",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, CARD_Y, CARD_TITLE_SIZE / 2 + 8),
		Size = UDim2.new(1, 0, 0, CARD_SUB_SIZE + 4),
		Font = Theme.Font.body,
		TextSize = CARD_SUB_SIZE,
		TextColor3 = Theme.Color.textDim,
		Text = "",
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	})

	gui.Parent = player:WaitForChild("PlayerGui")
end

local function showCard(title: string, sub: string?, color: Color3)
	cardToken += 1
	local token = cardToken
	cardTitle.Text = title
	cardTitle.TextColor3 = color
	cardSub.Text = sub or ""
	local tweenIn = TweenInfo.new(CARD_IN, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(cardTitle, tweenIn, { TextTransparency = 0, TextStrokeTransparency = 0.4 }):Play()
	TweenService:Create(cardSub, tweenIn, { TextTransparency = 0, TextStrokeTransparency = 0.5 }):Play()
	task.delay(CARD_IN + CARD_HOLD, function()
		if token ~= cardToken then
			return
		end
		local tweenOut = TweenInfo.new(CARD_OUT, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(cardTitle, tweenOut, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		TweenService:Create(cardSub, tweenOut, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	end)
end

-- ---------------------------------------------------------------- filtering

-- The island the local player is standing on - the same shared footprint
-- rule the server's gates and spawner use, so the filter costs no traffic.
local function localIsland(): string?
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil
	end
	return Islands.islandAt((root :: BasePart).Position, ISLAND_MARGIN)
end

local function onRaidState(payload)
	if type(payload) ~= "table" or type(payload.islandId) ~= "string" then
		return
	end
	local islandId = payload.islandId
	local here = localIsland()

	-- Someone else's raid: the only thing it can do to OUR screen is clear a
	-- line we left behind by island-hopping mid-raid.
	if islandId ~= here then
		if shownIsland == islandId then
			shownIsland = nil
			line.Visible = false
		end
		return
	end

	local phase = tostring(payload.phase)
	local previous = lastPhase[islandId]
	lastPhase[islandId] = phase

	if phase == "announced" then
		line.Text = string.format("RAID INCOMING  -  %d", tonumber(payload.seconds) or 0)
		line.TextColor3 = RAID_COLOR
		line.Visible = true
		shownIsland = islandId
		if previous ~= "announced" then
			showCard("A RAID APPROACHES", "hold the beach", RAID_COLOR)
		end
	elseif phase == "wave" or phase == "breather" then
		line.Text = string.format(
			"RAID  -  WAVE %d/%d  -  %d LEFT",
			tonumber(payload.wave) or 0,
			tonumber(payload.waves) or 0,
			tonumber(payload.remaining) or 0
		)
		line.TextColor3 = RAID_COLOR
		line.Visible = true
		shownIsland = islandId
	elseif phase == "cleared" then
		line.Visible = false
		shownIsland = nil
		showCard("RAID CLEARED", "the island holds", Theme.Color.green)
	elseif phase == "failed" then
		line.Visible = false
		shownIsland = nil
		if previous == "wave" or previous == "breather" then
			showCard("RAID FAILED", "they got what they came for", FAIL_COLOR)
		end
	else -- idle, or anything unknown: stand down
		line.Visible = false
		shownIsland = nil
	end
end

-- ---------------------------------------------------------------- lifecycle

function RaidHudController.init()
	build()
end

function RaidHudController.start()
	Remotes.RaidState.OnClientEvent:Connect(onRaidState)
end

return RaidHudController
