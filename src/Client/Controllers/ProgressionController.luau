--!nonstrict
-- ProgressionController.luau
-- The coins / level / XP readout, bottom-right. Reads the replicated
-- attributes ProgressionService sets on the Player (so it's right from the
-- first frame, including for late joiners) and listens to RewardGranted for
-- the "+coins" / "+XP" pops that a bare attribute change can't express. A
-- level-up is spotted from the Level attribute going up and gets a banner.
--
-- The same pop stack also shows every crafting material you pick up
-- (MaterialGranted - the basic mats a cast drags in, the rare ones a kill
-- drops): one short rising line per thing gained, in that thing's colour -
-- coins gold, XP blue, each material its own swatch colour - stacked one
-- above the other when several land at once (user, 2026-08-22: "a short
-- little pop up for each item ... exactly like the coin popup").
--
-- Deliberately no panel box: a right-aligned stack of text with a thin
-- bar, text-stroked so it reads over bright water, sitting quietly in the
-- corner (user: "cleaner and sleeker").
--
-- No sound on purpose: the one fanfare tried earlier was cut by the user.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Bait = require(Shared.Data.Bait)
local Materials = require(Shared.Data.Materials)
local Progression = require(Shared.Modules.Progression)
local Remotes = require(Shared.Net.Remotes)

local Theme = require(script.Parent.Parent.UI.Theme)

local player = Players.LocalPlayer

local ProgressionController = {}

local ATTR = Progression.ATTR

-- ---------------------------------------------------------------- layout
-- Everything hangs off the bottom-right corner; the stack grows upward.

local MARGIN = Vector2.new(22, 20) -- from the screen's bottom-right
local STACK_WIDTH = 200

local COIN_TEXT_SIZE = 22
local COIN_DOT = 12 -- diameter of the coin mark left of the number
local COIN_COLOR = Color3.fromRGB(255, 204, 92)
local COIN_RIM = Color3.fromRGB(196, 142, 40)
local XP_COLOR = Theme.Color.accent -- same blue as the XP bar

local BAR_HEIGHT = 4
local BAR_GAP_BELOW_COINS = 10 -- coins row -> the LV / XP caption line
local CAPTION_TEXT_SIZE = 11
local CAPTION_GAP = 4 -- caption line -> bar

local TEXT_STROKE = 0.65 -- stroke transparency; lower = heavier outline
local XP_FILL_TIME = 0.35
local LEVEL_FLASH_TIME = 0.5

-- Reward pops: each rises from just above the stack and fades. Pops that
-- overlap in time stack upward, one line each (coins, XP, then a line per
-- material), so a kill reads as a little column of gains.
local POP_RISE = 26
local POP_DURATION = 2.2 -- user (2026-08-22): long enough to actually read a column of materials
local POP_HOLD = 0.6 -- fully visible for this long before the fade begins
local POP_HEIGHT = 20
local POP_STAGGER = 22 -- pixels between pops that overlap in time (>= POP_HEIGHT so lines never touch)

-- Level-up banner, top centre (under the fishing grade banner at y=40).
local LEVEL_BANNER_Y = 84
local LEVEL_BANNER_DURATION = 2.2

-- ---------------------------------------------------------------- state

local gui: ScreenGui
local stack: Frame -- the bottom-right anchor everything sits in
local coinsText: TextLabel
local levelText: TextLabel
local xpText: TextLabel
local xpFill: Frame
local levelBanner: TextLabel

local lastLevel: number? = nil
local activePops = 0

-- ---------------------------------------------------------------- helpers

local function label(parent: GuiObject, props: { [string]: any }): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = Theme.Font.body
	l.TextColor3 = Theme.Color.text
	l.TextXAlignment = Enum.TextXAlignment.Right
	l.TextYAlignment = Enum.TextYAlignment.Center
	l.TextStrokeColor3 = Color3.fromRGB(10, 14, 20)
	l.TextStrokeTransparency = TEXT_STROKE
	for key, value in props do
		l[key] = value
	end
	l.Parent = parent
	return l
end

local function corner(parent: GuiObject, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
end

local function formatNumber(n: number): string
	-- 12345 -> "12,345"
	local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

-- ---------------------------------------------------------------- build

local function buildHud()
	gui = Instance.new("ScreenGui")
	gui.Name = "ProgressionGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	-- Heights, bottom-up: bar, caption line, coins row.
	local captionHeight = CAPTION_TEXT_SIZE + 4
	local coinsHeight = COIN_TEXT_SIZE + 6
	local stackHeight = BAR_HEIGHT + CAPTION_GAP + captionHeight + BAR_GAP_BELOW_COINS + coinsHeight

	stack = Instance.new("Frame")
	stack.Name = "Stack"
	stack.AnchorPoint = Vector2.new(1, 1)
	stack.Position = UDim2.new(1, -MARGIN.X, 1, -MARGIN.Y)
	stack.Size = UDim2.fromOffset(STACK_WIDTH, stackHeight)
	stack.BackgroundTransparency = 1
	stack.Parent = gui

	-- Bottom: the XP bar.
	local bar = Instance.new("Frame")
	bar.Name = "XpBar"
	bar.AnchorPoint = Vector2.new(1, 1)
	bar.Position = UDim2.new(1, 0, 1, 0)
	bar.Size = UDim2.new(1, 0, 0, BAR_HEIGHT)
	bar.BackgroundColor3 = Theme.Color.text
	bar.BackgroundTransparency = 0.82
	bar.BorderSizePixel = 0
	bar.Parent = stack
	corner(bar, BAR_HEIGHT)

	xpFill = Instance.new("Frame")
	xpFill.Name = "Fill"
	xpFill.Size = UDim2.fromScale(0, 1)
	xpFill.BackgroundColor3 = Theme.Color.accent
	xpFill.BorderSizePixel = 0
	xpFill.Parent = bar
	corner(xpFill, BAR_HEIGHT)

	-- Above the bar: "LV 4" left, "120 / 530 XP" right, small dim caps.
	local captionY = -(BAR_HEIGHT + CAPTION_GAP)
	levelText = label(stack, {
		Name = "Level",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, captionY),
		Size = UDim2.new(0.4, 0, 0, captionHeight),
		Font = Theme.Font.header,
		TextSize = CAPTION_TEXT_SIZE,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Theme.Color.text,
		Text = "LV 1",
	})
	xpText = label(stack, {
		Name = "XpText",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, 0, 1, captionY),
		Size = UDim2.new(0.6, 0, 0, captionHeight),
		TextSize = CAPTION_TEXT_SIZE,
		TextColor3 = Theme.Color.textDim,
		Text = "",
	})

	-- Top: coin mark + amount, right-aligned.
	local coinsY = captionY - captionHeight - BAR_GAP_BELOW_COINS
	coinsText = label(stack, {
		Name = "Coins",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, 0, 1, coinsY),
		Size = UDim2.new(1, -(COIN_DOT + 8), 0, coinsHeight),
		Font = Theme.Font.header,
		TextSize = COIN_TEXT_SIZE,
		TextColor3 = COIN_COLOR,
		Text = "0",
	})

	-- The coin mark sits just left of the number and follows its width.
	local coin = Instance.new("Frame")
	coin.Name = "CoinMark"
	coin.AnchorPoint = Vector2.new(1, 0.5)
	coin.Size = UDim2.fromOffset(COIN_DOT, COIN_DOT)
	coin.BackgroundColor3 = COIN_COLOR
	coin.BorderSizePixel = 0
	coin.Parent = stack
	corner(coin, COIN_DOT)
	local rim = Instance.new("UIStroke")
	rim.Color = COIN_RIM
	rim.Thickness = 2
	rim.Parent = coin

	local function placeCoin()
		local textWidth = coinsText.TextBounds.X
		coin.Position = UDim2.new(1, -(textWidth + 8), 1, coinsY - coinsHeight / 2)
	end
	coinsText:GetPropertyChangedSignal("TextBounds"):Connect(placeCoin)
	placeCoin()

	-- Level-up banner, top centre.
	levelBanner = label(gui, {
		Name = "LevelBanner",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, LEVEL_BANNER_Y),
		Size = UDim2.fromOffset(420, 36),
		Font = Theme.Font.header,
		TextSize = 26,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = Theme.Color.accent,
		TextStrokeTransparency = 0.5,
		Text = "",
		Visible = false,
	})

	gui.Parent = player:WaitForChild("PlayerGui")
end

-- ---------------------------------------------------------------- refresh

local function flashLevelUp(level: number)
	-- Bar pops white then settles back to the accent; banner top centre.
	xpFill.BackgroundColor3 = Theme.Color.text
	TweenService:Create(xpFill, TweenInfo.new(LEVEL_FLASH_TIME), { BackgroundColor3 = Theme.Color.accent }):Play()

	local text = string.format("LEVEL %d!", level)
	levelBanner.Text = text
	levelBanner.Visible = true
	levelBanner.TextTransparency = 0
	levelBanner.TextStrokeTransparency = 0.5
	task.delay(LEVEL_BANNER_DURATION, function()
		if levelBanner.Text ~= text then
			return
		end
		TweenService:Create(levelBanner, TweenInfo.new(0.4), { TextTransparency = 1, TextStrokeTransparency = 1 })
			:Play()
		task.delay(0.4, function()
			if levelBanner.Text == text then
				levelBanner.Visible = false
			end
		end)
	end)
end

local function refresh()
	local level = player:GetAttribute(ATTR.level) or Progression.START_LEVEL
	local xp = player:GetAttribute(ATTR.xp) or 0
	local toNext = player:GetAttribute(ATTR.xpToNext) or Progression.xpToNext(level)
	local coins = player:GetAttribute(ATTR.coins) or 0

	levelText.Text = "LV " .. tostring(level)
	xpText.Text = if level >= Progression.MAX_LEVEL
		then "MAX"
		else string.format("%s / %s XP", formatNumber(xp), formatNumber(toNext))
	coinsText.Text = formatNumber(coins)

	local fraction = if toNext > 0 then math.clamp(xp / toNext, 0, 1) else 1
	TweenService:Create(xpFill, TweenInfo.new(XP_FILL_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.fromScale(fraction, 1),
	}):Play()

	-- Level-up on an actual increase (not the first read).
	if lastLevel and level > lastLevel then
		flashLevelUp(level)
	end
	lastLevel = level
end

-- One "+N thing" line rising up out of the stack in `color`. Each call takes
-- the next slot above any pops still in flight, so a burst of gains stacks
-- into a column instead of piling onto one line.
local function pushPop(text: string, color: Color3)
	local startY = -(stack.AbsoluteSize.Y + 6 + activePops * POP_STAGGER)
	activePops += 1

	local pop = label(gui, {
		Name = "RewardPop",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -MARGIN.X, 1, -MARGIN.Y + startY),
		Size = UDim2.fromOffset(STACK_WIDTH, POP_HEIGHT),
		Font = Theme.Font.header,
		TextSize = 14,
		TextColor3 = color,
		Text = text,
	})

	-- Rise for the whole life; hold at full opacity first, then fade out -
	-- a fade that starts at once made the text unreadable by the time a
	-- second line had landed.
	local rise = TweenInfo.new(POP_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(pop, rise, {
		Position = pop.Position - UDim2.fromOffset(0, POP_RISE),
	}):Play()
	local fade =
		TweenInfo.new(POP_DURATION - POP_HOLD, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, POP_HOLD)
	TweenService:Create(pop, fade, {
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	}):Play()

	task.delay(POP_DURATION, function()
		pop:Destroy()
		activePops = math.max(0, activePops - 1)
	end)
end

-- A kill's payout: "+12 coins" (gold) with "+35 XP" (blue) stacked above it.
local function showReward(reward)
	if type(reward) ~= "table" then
		return
	end
	if reward.coins and reward.coins > 0 then
		pushPop(string.format("+%s coins", formatNumber(reward.coins)), COIN_COLOR)
	end
	if reward.xp and reward.xp > 0 then
		pushPop(string.format("+%s XP", formatNumber(reward.xp)), XP_COLOR)
	end
end

-- Materials gained (a cast's debris, a kill's drops): one line per material
-- in its own colour, in Materials.order so the column reads the same every
-- time.
local function showMaterials(gained)
	if type(gained) ~= "table" then
		return
	end
	for _, matId in Materials.order do
		local amount = gained[matId]
		if type(amount) == "number" and amount > 0 then
			local mat = Materials.items[matId]
			pushPop(string.format("+%s %s", formatNumber(amount), mat.name), mat.color)
		end
	end
end

-- Bait crafted: "+N <bait>" in the bait's colour, in Bait.order so a batch
-- reads consistently. Mirrors showMaterials.
local function showBait(gained)
	if type(gained) ~= "table" then
		return
	end
	for _, baitId in Bait.order do
		local amount = gained[baitId]
		if type(amount) == "number" and amount > 0 then
			local bait = Bait.items[baitId]
			pushPop(string.format("+%s %s", formatNumber(amount), bait.name), bait.color)
		end
	end
end

-- One line in the same bottom-right pop stack, for other controllers' gains
-- and losses (a pickpocketed "-N coins" from CreatureEventController).
function ProgressionController.pop(text: string, color: Color3)
	pushPop(text, color)
end

-- ---------------------------------------------------------------- lifecycle

function ProgressionController.init()
	buildHud()

	for _, name in ATTR do
		player:GetAttributeChangedSignal(name):Connect(refresh)
	end
	Remotes.RewardGranted.OnClientEvent:Connect(showReward)
	Remotes.MaterialGranted.OnClientEvent:Connect(showMaterials)
	Remotes.BaitGranted.OnClientEvent:Connect(showBait)
end

function ProgressionController.start()
	refresh()
end

return ProgressionController
