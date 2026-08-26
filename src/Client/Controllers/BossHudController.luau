--!nonstrict
-- BossHudController.luau
-- The island boss's presence on screen: a big named health bar across the
-- top while one is up, a title card when it rises, and the "ISLAND CLEARED"
-- card when it falls.
--
-- Everything it needs is already replicated: a boss is any creature Model in
-- Workspace.Creatures carrying the BossName attribute (CreatureService sets
-- it as the boss rises), and its Health / MaxHealth attributes drive the
-- bar; Enraged turns the bar red. The rise and fall cards come off the
-- CreatureEvent remote (bossRise / bossDown, with the boss's name and what
-- the win unlocked) - the same remote CreatureEventController draws from.
--
-- Sits below the fishing grade banner (y=40) and the level-up banner (y=84)
-- so the three never overlap.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)

local Theme = require(script.Parent.Parent.UI.Theme)

local player = Players.LocalPlayer

local BossHudController = {}

-- Must match CreatureService; server modules aren't requireable here.
local CREATURES_FOLDER = "Creatures"
local ATTR_BOSS_NAME = "BossName"
local ATTR_HEALTH = "Health"
local ATTR_MAX_HEALTH = "MaxHealth"
local ATTR_ENRAGED = "Enraged"

-- ---------------------------------------------------------------- layout

local BAR_Y = 124 -- below the grade (40) and level-up (84) banners
local BAR_WIDTH = 0.46 -- of the screen
local BAR_HEIGHT = 16
local NAME_SIZE = 20
local NAME_GAP = 6

local BAR_COLOR = Color3.fromRGB(120, 255, 214) -- the lure's glow
local BAR_RAGE_COLOR = Color3.fromRGB(255, 80, 60)
local BAR_BACK = Color3.fromRGB(14, 18, 24)
local BAR_FILL_TIME = 0.18

local CARD_Y = 0.3 -- of the screen, for the rise / cleared cards
local CARD_TITLE_SIZE = 38
local CARD_SUB_SIZE = 18
local CARD_IN = 0.45
local CARD_HOLD = 2.6
local CARD_OUT = 0.6

-- ---------------------------------------------------------------- state

local gui: ScreenGui
local barFrame: Frame
local barFill: Frame
local nameLabel: TextLabel
local cardTitle: TextLabel
local cardSub: TextLabel

local current: Model? = nil
local connections: { RBXScriptConnection } = {}
local cardToken = 0

-- ---------------------------------------------------------------- build

local function label(parent: GuiObject, props: { [string]: any }): TextLabel
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
	gui.Name = "BossHudGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 5

	-- The bar: a name above a thin wide bar, centred near the top.
	barFrame = Instance.new("Frame")
	barFrame.Name = "BossBar"
	barFrame.AnchorPoint = Vector2.new(0.5, 0)
	barFrame.Position = UDim2.new(0.5, 0, 0, BAR_Y)
	barFrame.Size = UDim2.new(BAR_WIDTH, 0, 0, NAME_SIZE + NAME_GAP + BAR_HEIGHT)
	barFrame.BackgroundTransparency = 1
	barFrame.Visible = false
	barFrame.Parent = gui

	nameLabel = label(barFrame, {
		Name = "Name",
		Size = UDim2.new(1, 0, 0, NAME_SIZE),
		TextSize = NAME_SIZE,
		Text = "",
	})

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0.5, 1)
	track.Position = UDim2.new(0.5, 0, 1, 0)
	track.Size = UDim2.new(1, 0, 0, BAR_HEIGHT)
	track.BackgroundColor3 = BAR_BACK
	track.BackgroundTransparency = 0.25
	track.BorderSizePixel = 0
	track.Parent = barFrame
	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(0, 4)
	trackCorner.Parent = track
	local stroke = Instance.new("UIStroke")
	stroke.Color = Theme.Color.border
	stroke.Thickness = 1.5
	stroke.Parent = track

	barFill = Instance.new("Frame")
	barFill.Name = "Fill"
	barFill.Size = UDim2.fromScale(1, 1)
	barFill.BackgroundColor3 = BAR_COLOR
	barFill.BorderSizePixel = 0
	barFill.Parent = track
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 4)
	fillCorner.Parent = barFill

	-- The rise / cleared cards.
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

-- ---------------------------------------------------------------- the bar

local function refresh()
	local model = current
	if not model then
		return
	end
	local health = tonumber(model:GetAttribute(ATTR_HEALTH)) or 0
	local maxHealth = math.max(1, tonumber(model:GetAttribute(ATTR_MAX_HEALTH)) or 1)
	TweenService:Create(barFill, TweenInfo.new(BAR_FILL_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.fromScale(math.clamp(health / maxHealth, 0, 1), 1),
	}):Play()
	local enraged = model:GetAttribute(ATTR_ENRAGED) == true
	barFill.BackgroundColor3 = if enraged then BAR_RAGE_COLOR else BAR_COLOR
	nameLabel.TextColor3 = if enraged then BAR_RAGE_COLOR else Theme.Color.text
end

local function untrack()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	current = nil
	barFrame.Visible = false
end

local function track(model: Model)
	untrack()
	current = model
	nameLabel.Text = string.upper(tostring(model:GetAttribute(ATTR_BOSS_NAME) or "BOSS"))
	barFill.Size = UDim2.fromScale(1, 1)
	barFrame.Visible = true
	for _, attr in { ATTR_HEALTH, ATTR_MAX_HEALTH, ATTR_ENRAGED } do
		table.insert(connections, model:GetAttributeChangedSignal(attr):Connect(refresh))
	end
	refresh()
end

-- With seven islands, two bosses can be alive at once (each summoned on
-- its own island). The bar belongs to the NEAREST live boss - islands sit
-- 3000 studs apart, so "nearest" is always the one this player is
-- fighting - and every add/remove RE-TARGETS instead of last-writer-wins:
-- a boss dying elsewhere must never hide the bar of the one still trying
-- to eat you (review finding, 2026-08-25).
local creaturesFolder: Instance? = nil

local function nearestBoss(): Model?
	if not creaturesFolder then
		return nil
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local best: Model? = nil
	local bestDist = math.huge
	for _, child in creaturesFolder:GetChildren() do
		if child:IsA("Model") and child:GetAttribute(ATTR_BOSS_NAME) then
			local dist = if root and root:IsA("BasePart")
				then (child:GetPivot().Position - root.Position).Magnitude
				else 0
			if dist < bestDist then
				best = child
				bestDist = dist
			end
		end
	end
	return best
end

local function retarget()
	local best = nearestBoss()
	if best == current then
		return
	end
	if best then
		track(best)
	else
		untrack()
	end
end

-- A creature becomes a boss the moment its BossName lands (set by the
-- server as it rises - a frame or so after the model appears).
local function consider(child: Instance)
	if not child:IsA("Model") then
		return
	end
	if child:GetAttribute(ATTR_BOSS_NAME) then
		retarget()
		return
	end
	local connection
	connection = child:GetAttributeChangedSignal(ATTR_BOSS_NAME):Connect(function()
		if child:GetAttribute(ATTR_BOSS_NAME) and child.Parent then
			connection:Disconnect()
			retarget()
		end
	end)
end

-- ---------------------------------------------------------------- the cards

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

local function onCreatureEvent(kind, _position, extra)
	if type(extra) ~= "table" then
		extra = {}
	end
	if kind == "bossRise" then
		showCard(string.upper(tostring(extra.name or "THE BOSS")), "rises from the deep", BAR_COLOR)
	elseif kind == "exposed" then
		-- The Kraken: the last tentacle is down and the head can be hurt.
		showCard("THE MAW IS EXPOSED", "every arm is down - strike now", Theme.Color.gold)
	elseif kind == "regrow" then
		showCard("THE ARMS REGROW", "bring them down again", Theme.Color.red)
	elseif kind == "bossDown" then
		if extra.finale then
			-- The Kraken. There is no next island; this is the saga's end.
			showCard(
				"THE MAELSTROM FALLS SILENT",
				string.format("%s is slain - the saga is complete", tostring(extra.name)),
				Theme.Color.gold
			)
			return
		end
		local sub = if extra.unlocks
			then string.format("%s defeated - %s is open", tostring(extra.name), tostring(extra.unlocks))
			else string.format("%s defeated", tostring(extra.name))
		showCard("ISLAND CLEARED", sub, Theme.Color.green)
	end
end

-- ---------------------------------------------------------------- lifecycle

function BossHudController.init()
	build()
end

function BossHudController.start()
	Remotes.CreatureEvent.OnClientEvent:Connect(onCreatureEvent)

	task.spawn(function()
		local creatures = Workspace:WaitForChild(CREATURES_FOLDER, 30)
		if not creatures then
			warn("[BossHud] no Workspace." .. CREATURES_FOLDER .. " folder; boss bar off")
			return
		end
		creaturesFolder = creatures
		creatures.ChildAdded:Connect(consider)
		creatures.ChildRemoved:Connect(function(child)
			if child == current then
				-- The tracked boss went down; another may still be live on
				-- this player's island (or anywhere) - hand the bar over
				-- rather than killing it.
				untrack()
				retarget()
			end
		end)
		for _, existing in creatures:GetChildren() do
			consider(existing)
		end
	end)
end

return BossHudController
