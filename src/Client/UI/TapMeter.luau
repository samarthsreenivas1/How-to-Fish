--!nonstrict
-- TapMeter.luau
-- Pure rendering for the rapid-tap burst minigame: a big "MASH!" tap target, a
-- fill bar that climbs as you tap, and a thin timer bar draining above it. The
-- driver (Client/Minigames/burst) owns timing/input; this only draws what it's
-- told. Tap-anywhere is the input, but the target doubles as a ≥64px touch
-- affordance.

local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Theme)

local TapMeter = {}
TapMeter.__index = TapMeter

local WIDTH = 260
local TARGET_SIZE = 120 -- the round tap zone; well over the 64px touch minimum
local FILL_HEIGHT = 20
local TIMER_HEIGHT = 8

local function addCorner(parent: GuiObject, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
end

function TapMeter.new(parent: ScreenGui)
	local self = setmetatable({}, TapMeter)

	local container = Instance.new("Frame")
	container.Name = "TapMeter"
	container.AnchorPoint = Vector2.new(0.5, 1)
	container.Position = UDim2.new(0.5, 0, 1, -48)
	container.Size = UDim2.fromOffset(WIDTH, TARGET_SIZE + FILL_HEIGHT + TIMER_HEIGHT + 24)
	container.BackgroundTransparency = 1
	container.Visible = false
	container.Parent = parent

	-- Timer bar (drains left as time runs out).
	local timerTrack = Instance.new("Frame")
	timerTrack.Name = "TimerTrack"
	timerTrack.AnchorPoint = Vector2.new(0.5, 0)
	timerTrack.Position = UDim2.new(0.5, 0, 0, 0)
	timerTrack.Size = UDim2.fromOffset(WIDTH, TIMER_HEIGHT)
	timerTrack.BackgroundColor3 = Theme.Color.background
	timerTrack.BorderSizePixel = 0
	timerTrack.Parent = container
	addCorner(timerTrack, TIMER_HEIGHT / 2)

	local timerFill = Instance.new("Frame")
	timerFill.Name = "Fill"
	timerFill.Size = UDim2.fromScale(1, 1)
	timerFill.BackgroundColor3 = Theme.Color.accent
	timerFill.BorderSizePixel = 0
	timerFill.Parent = timerTrack
	addCorner(timerFill, TIMER_HEIGHT / 2)

	-- The tap target.
	local target = Instance.new("TextLabel")
	target.Name = "Target"
	target.AnchorPoint = Vector2.new(0.5, 0.5)
	target.Position = UDim2.new(0.5, 0, 0, TIMER_HEIGHT + 12 + TARGET_SIZE / 2)
	target.Size = UDim2.fromOffset(TARGET_SIZE, TARGET_SIZE)
	target.BackgroundColor3 = Theme.Color.panelLight
	target.BorderSizePixel = 0
	target.Font = Theme.Font.header
	target.TextSize = 26
	target.TextColor3 = Theme.Color.text
	target.Text = "MASH!"
	target.Parent = container
	addCorner(target, TARGET_SIZE / 2)
	local targetStroke = Instance.new("UIStroke")
	targetStroke.Color = Theme.Color.accent
	targetStroke.Thickness = 2
	targetStroke.Parent = target

	-- Fill bar (climbs as taps accumulate).
	local fillTrack = Instance.new("Frame")
	fillTrack.Name = "FillTrack"
	fillTrack.AnchorPoint = Vector2.new(0.5, 1)
	fillTrack.Position = UDim2.new(0.5, 0, 1, 0)
	fillTrack.Size = UDim2.fromOffset(WIDTH, FILL_HEIGHT)
	fillTrack.BackgroundColor3 = Theme.Color.background
	fillTrack.BorderSizePixel = 0
	fillTrack.Parent = container
	addCorner(fillTrack, FILL_HEIGHT / 2)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.AnchorPoint = Vector2.new(0, 0.5)
	fill.Position = UDim2.fromScale(0, 0.5)
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = Theme.Color.green
	fill.BorderSizePixel = 0
	fill.Parent = fillTrack
	addCorner(fill, FILL_HEIGHT / 2)

	self.root = container
	self.timerFill = timerFill
	self.target = target
	self.fill = fill

	return self
end

-- Fraction of the target reached, 0..1. Turns brighter/greener as it fills.
function TapMeter:setFill(fraction: number)
	fraction = math.clamp(fraction, 0, 1)
	self.fill.Size = UDim2.fromScale(fraction, 1)
	self.fill.BackgroundColor3 = Theme.Color.red:Lerp(Theme.Color.green, fraction)
end

-- Fraction of time remaining, 0..1.
function TapMeter:setTime(fraction: number)
	fraction = math.clamp(fraction, 0, 1)
	self.timerFill.Size = UDim2.fromScale(fraction, 1)
	self.timerFill.BackgroundColor3 = fraction < 0.3 and Theme.Color.red or Theme.Color.accent
end

-- A quick pop of the tap target on each tap.
function TapMeter:pulse()
	self.target.Size = UDim2.fromOffset(TARGET_SIZE + 12, TARGET_SIZE + 12)
	TweenService:Create(self.target, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.fromOffset(TARGET_SIZE, TARGET_SIZE),
	}):Play()
end

function TapMeter:reset()
	self:setFill(0)
	self:setTime(1)
end

function TapMeter:show()
	self.root.Visible = true
end

function TapMeter:hide()
	self.root.Visible = false
end

return TapMeter
