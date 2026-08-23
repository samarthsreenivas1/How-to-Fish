--!nonstrict
-- SnapTargets.luau
-- Pure rendering for the whack-a-mole tap-targets minigame: a prompt across
-- the top and one target that jumps to a new spot each round. The target is a
-- fixed-size black outer ring (so it stays easy to click) with a blue inner
-- disc that SHRINKS as the round's time runs out (the countdown). A separate
-- pop marks hit/miss, kept off the target so it can move on immediately.
--
-- The driver (Client/Minigames/snap) owns timing/input; this only draws what
-- it's told and reports taps through the callback set by :bindTap.

local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Theme)

local SnapTargets = {}
SnapTargets.__index = SnapTargets

local SIZE = 120 -- outer ring diameter; fixed, big, always clickable
local INNER = 0.8 -- inner disc diameter as a fraction of the outer, at full time
local OUTER_COLOR = Color3.fromRGB(18, 20, 26) -- near-black
local INNER_COLOR = Color3.fromRGB(80, 170, 240) -- blue

function SnapTargets.new(parent: ScreenGui)
	local self = setmetatable({}, SnapTargets)
	self.onTap = nil
	self.pos = { x = 0.5, y = 0.5 }

	local container = Instance.new("Frame")
	container.Name = "SnapTargets"
	container.Size = UDim2.fromScale(1, 1)
	container.BackgroundTransparency = 1
	container.Visible = false
	container.Parent = parent

	local prompt = Instance.new("TextLabel")
	prompt.Name = "Prompt"
	prompt.AnchorPoint = Vector2.new(0.5, 0)
	prompt.Position = UDim2.new(0.5, 0, 0, 70)
	prompt.Size = UDim2.fromOffset(520, 40)
	prompt.BackgroundTransparency = 1
	prompt.Font = Theme.Font.header
	prompt.TextSize = 30
	prompt.TextColor3 = Theme.Color.text
	prompt.TextStrokeColor3 = Color3.new(0, 0, 0)
	prompt.TextStrokeTransparency = 0.5
	prompt.Text = ""
	prompt.Parent = container

	-- The target: a fixed-size black outer button.
	local target = Instance.new("TextButton")
	target.Name = "Target"
	target.AnchorPoint = Vector2.new(0.5, 0.5)
	target.Size = UDim2.fromOffset(SIZE, SIZE)
	target.BackgroundColor3 = OUTER_COLOR
	target.AutoButtonColor = false
	target.Text = ""
	target.Visible = false
	target.Parent = container
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = target
	local stroke = Instance.new("UIStroke")
	stroke.Color = Theme.Color.text
	stroke.Thickness = 2
	stroke.Parent = target

	-- The blue inner disc that shrinks with the remaining time. A child of the
	-- button, so clicking anywhere on the target still fires the button.
	local inner = Instance.new("Frame")
	inner.Name = "Inner"
	inner.AnchorPoint = Vector2.new(0.5, 0.5)
	inner.Position = UDim2.fromScale(0.5, 0.5)
	inner.Size = UDim2.fromScale(INNER, INNER)
	inner.BackgroundColor3 = INNER_COLOR
	inner.BorderSizePixel = 0
	inner.Parent = target
	local innerCorner = Instance.new("UICorner")
	innerCorner.CornerRadius = UDim.new(1, 0)
	innerCorner.Parent = inner

	target.Activated:Connect(function()
		if self.onTap then
			self.onTap()
		end
	end)

	-- Separate hit/miss pop, so the target can move on immediately.
	local pop = Instance.new("Frame")
	pop.Name = "Pop"
	pop.AnchorPoint = Vector2.new(0.5, 0.5)
	pop.Size = UDim2.fromOffset(SIZE, SIZE)
	pop.BackgroundTransparency = 1
	pop.BorderSizePixel = 0
	pop.Visible = false
	pop.Parent = container
	local popCorner = Instance.new("UICorner")
	popCorner.CornerRadius = UDim.new(1, 0)
	popCorner.Parent = pop

	self.root = container
	self.prompt = prompt
	self.target = target
	self.inner = inner
	-- NOT self.pop: an instance field named `pop` would shadow the :pop()
	-- method below (Lua only consults the metatable's __index when the key is
	-- missing on the table itself), turning view:pop(...) into an attempt to
	-- call a Frame - which errored mid-click and froze the whole minigame
	-- (the round's `answered` flag was already set, so no further input or
	-- timer ticks were accepted). Field and method names must never collide.
	self.popFx = pop

	return self
end

function SnapTargets:bindTap(fn)
	self.onTap = fn
end

function SnapTargets:setPrompt(text: string)
	self.prompt.Text = text
end

-- Place the target at `pos` (scale coords), inner disc full, and show it.
function SnapTargets:setTarget(pos)
	self.pos = pos
	self.target.Position = UDim2.fromScale(pos.x, pos.y)
	self.inner.Size = UDim2.fromScale(INNER, INNER)
	self.target.Visible = true
end

-- Shrink the blue inner disc with the remaining time (1 = full, 0 = out). The
-- black outer ring stays a fixed, clickable size.
function SnapTargets:setTime(fraction: number)
	local s = INNER * math.clamp(fraction, 0, 1)
	self.inner.Size = UDim2.fromScale(s, s)
end

function SnapTargets:hideTarget()
	self.target.Visible = false
end

-- A green (hit) / red (miss) ring popping out where the target was.
function SnapTargets:pop(hit: boolean)
	self.popFx.Position = UDim2.fromScale(self.pos.x, self.pos.y)
	self.popFx.Size = UDim2.fromOffset(SIZE * 0.6, SIZE * 0.6)
	self.popFx.BackgroundColor3 = hit and Theme.Color.green or Theme.Color.red
	self.popFx.BackgroundTransparency = 0.25
	self.popFx.Visible = true
	TweenService:Create(self.popFx, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.fromOffset(SIZE * 1.4, SIZE * 1.4),
		BackgroundTransparency = 1,
	}):Play()
end

function SnapTargets:show()
	self.root.Visible = true
end

function SnapTargets:hide()
	self.root.Visible = false
	self.target.Visible = false
end

return SnapTargets
