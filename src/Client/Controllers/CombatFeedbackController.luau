--!nonstrict
-- CombatFeedbackController.luau
-- The three "the fish got hit" effects, all client-side and all driven off
-- one signal: the creature's replicated Health attribute (set by
-- CreatureService.damage). Because nothing here is wired to a specific
-- damage source, it lights up for whatever eventually deals damage - the
-- fists punch today, real weapons later - with zero extra wiring.
--
--   1. Health bar  - a small BillboardGui above each fish, hidden until the
--                    first hit, draining green -> red as health drops.
--   2. Hit flash   - the fish's parts tint toward red for a blink on each hit.
--   3. Damage number - the amount of that hit floats up from the fish and
--                    fades. Numbers come from a fixed pool of world anchors
--                    (the plan's "don't build during combat" rule); the
--                    amount is the drop in Health since the last change.
--
-- Every client runs this and builds its own copies, so all players see the
-- feedback. Colours are only ever set here on the client - the server sets a
-- creature's colour once at spawn and never again, so nothing fights the flash.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Theme = require(script.Parent.Parent.UI.Theme)

local CombatFeedbackController = {}

-- ---------------------------------------------------------------- config

local ATTR_HEALTH = "Health"
local ATTR_MAX_HEALTH = "MaxHealth"

local FLASH_COLOR = Color3.fromRGB(255, 70, 60)
local FLASH_PEAK = 0.7 -- how far toward red at the peak (0..1)
local FLASH_DURATION = 0.2 -- seconds

local BAR_SIZE = UDim2.fromOffset(56, 7)
local BAR_LIFT = 1.7 -- studs above the fish centre
local BAR_MAX_DISTANCE = 140

local NUMBER_POOL = 12
local NUMBER_RISE = 2.8 -- studs the number floats up over its life
local NUMBER_DURATION = 0.85 -- seconds
local NUMBER_SPREAD = 0.9 -- horizontal jitter so stacked hits don't overlap
local NUMBER_LIFT = 1.0 -- studs above the fish it starts

-- ---------------------------------------------------------------- state

-- model -> { body, parts = {part=baseColor}, maxHealth, health, fill, bar,
--            flashStart }
local tracked: { [Model]: any } = {}
local folder: Folder? = nil

-- Fixed pool of floating-number anchors; see spawnNumber.
local numbers = {}
local numberCursor = 1

-- ---------------------------------------------------------------- numbers

local function buildNumberPool(parent: Instance)
	for i = 1, NUMBER_POOL do
		local part = Instance.new("Part")
		part.Name = "DamageNumber"
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Transparency = 1
		part.Size = Vector3.new(0.2, 0.2, 0.2)
		part.Parent = parent

		local bb = Instance.new("BillboardGui")
		bb.Name = "Gui"
		bb.Size = UDim2.fromOffset(100, 40)
		bb.AlwaysOnTop = true
		bb.LightInfluence = 0
		bb.MaxDistance = BAR_MAX_DISTANCE
		bb.Adornee = part
		bb.Enabled = false
		bb.Parent = part

		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Font = Theme.Font.header
		label.TextSize = 26
		label.TextColor3 = Theme.Color.text
		label.TextStrokeColor3 = Color3.new(0, 0, 0)
		label.TextStrokeTransparency = 0.4
		label.Text = ""
		label.Parent = bb

		numbers[i] = { part = part, bb = bb, label = label, active = false, start = 0, basePos = Vector3.zero }
	end
end

local function spawnNumber(position: Vector3, amount: number)
	local entry = numbers[numberCursor]
	numberCursor = numberCursor % NUMBER_POOL + 1

	local jitter =
		Vector3.new((math.random() - 0.5) * 2 * NUMBER_SPREAD, NUMBER_LIFT, (math.random() - 0.5) * 2 * NUMBER_SPREAD)
	entry.basePos = position + jitter
	entry.start = os.clock()
	entry.active = true
	entry.label.Text = tostring(amount)
	entry.label.TextTransparency = 0
	entry.label.TextStrokeTransparency = 0.4
	entry.part.Position = entry.basePos
	entry.bb.Enabled = true
end

local function updateNumbers(now: number)
	for _, entry in numbers do
		if entry.active then
			local t = (now - entry.start) / NUMBER_DURATION
			if t >= 1 then
				entry.active = false
				entry.bb.Enabled = false
			else
				entry.part.Position = entry.basePos + Vector3.new(0, NUMBER_RISE * t, 0)
				-- Hold full opacity for the first half, fade over the second.
				local fade = math.clamp((t - 0.5) / 0.5, 0, 1)
				entry.label.TextTransparency = fade
				entry.label.TextStrokeTransparency = 0.4 + 0.6 * fade
			end
		end
	end
end

-- ---------------------------------------------------------------- health bar

local function buildHealthBar(body: BasePart): (BillboardGui, Frame)
	local bb = Instance.new("BillboardGui")
	bb.Name = "HealthBar"
	bb.Size = BAR_SIZE
	bb.StudsOffsetWorldSpace = Vector3.new(0, BAR_LIFT, 0)
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = BAR_MAX_DISTANCE
	bb.Adornee = body
	bb.Enabled = false -- shown on the first hit
	bb.Parent = body

	local back = Instance.new("Frame")
	back.Size = UDim2.fromScale(1, 1)
	back.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
	back.BackgroundTransparency = 0.25
	back.BorderSizePixel = 0
	back.Parent = bb

	local backCorner = Instance.new("UICorner")
	backCorner.CornerRadius = UDim.new(0, 3)
	backCorner.Parent = back

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.AnchorPoint = Vector2.new(0, 0.5)
	fill.Position = UDim2.new(0, 1, 0.5, 0)
	fill.Size = UDim2.new(1, -2, 1, -2)
	fill.BackgroundColor3 = Theme.Color.green
	fill.BorderSizePixel = 0
	fill.Parent = back

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 2)
	fillCorner.Parent = fill

	return bb, fill
end

local function updateHealthBar(entry, ratio: number)
	ratio = math.clamp(ratio, 0, 1)
	entry.fill.Size = UDim2.new(ratio, -2, 1, -2)
	if entry.friendly then
		entry.fill.BackgroundColor3 = Theme.Color.accent:Lerp(Theme.Color.sand, 1 - ratio)
	else
		entry.fill.BackgroundColor3 = Theme.Color.green:Lerp(Theme.Color.red, 1 - ratio)
	end
end

-- ---------------------------------------------------------------- flash

local function updateFlashes(now: number)
	for _, entry in tracked do
		if entry.flashStart then
			local alpha = 1 - (now - entry.flashStart) / FLASH_DURATION
			if alpha <= 0 then
				entry.flashStart = nil
				for part, base in entry.parts do
					part.Color = base
				end
			else
				local amount = alpha * FLASH_PEAK
				for part, base in entry.parts do
					part.Color = base:Lerp(FLASH_COLOR, amount)
				end
			end
		end
	end
end

-- ---------------------------------------------------------------- tracking

local function onHealthChanged(model: Model)
	local entry = tracked[model]
	if not entry then
		return
	end

	local newHealth = model:GetAttribute(ATTR_HEALTH)
	if type(newHealth) ~= "number" then
		return
	end

	local delta = entry.health - newHealth
	entry.health = newHealth

	updateHealthBar(entry, newHealth / entry.maxHealth)

	if delta > 0 then
		-- A buried creature (the sand lurker) is hidden; its bar mustn't give
		-- it away. (Nothing can hurt it while buried anyway - this guards the
		-- frame a hit and a burrow coincide.)
		entry.bar.Enabled = model:GetAttribute("Buried") ~= true
		entry.flashStart = os.clock()
		spawnNumber(entry.body.Position, math.round(delta))
	end
end

local function track(model: Model)
	if not model:IsA("Model") or tracked[model] then
		return
	end

	task.spawn(function()
		local body = model.PrimaryPart or model:WaitForChild("Fish_Body", 5)
		if not body or not body:IsA("BasePart") then
			return
		end
		-- Attributes are set before the model is parented on the server, so
		-- they replicate with it; still guard in case this races.
		local maxHealth = model:GetAttribute(ATTR_MAX_HEALTH)
		local health = model:GetAttribute(ATTR_HEALTH)
		if type(maxHealth) ~= "number" or type(health) ~= "number" then
			return
		end
		if tracked[model] or model.Parent == nil then
			return
		end

		local parts = {}
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") then
				parts[descendant] = descendant.Color
			end
		end

		local bar, fill = buildHealthBar(body)

		local entry = {
			body = body,
			parts = parts,
			maxHealth = maxHealth,
			health = health,
			bar = bar,
			fill = fill,
			flashStart = nil,
			-- A companion (Split Roe's hatchling; the server sets `Friendly`)
			-- isn't an enemy: its bar reads teal, never the enemy's green-to-red.
			friendly = model:GetAttribute("Friendly") == true,
		}
		tracked[model] = entry

		updateHealthBar(entry, health / maxHealth)
		if health < maxHealth then
			bar.Enabled = true
		end

		entry.conn = model:GetAttributeChangedSignal(ATTR_HEALTH):Connect(function()
			onHealthChanged(model)
		end)

		-- The sand lurker hides under the sand (CreatureService's `Buried`
		-- attribute; CreatureEventController hides the parts): hide the bar
		-- with it, and bring it back once it surfaces if it's been hurt.
		model:GetAttributeChangedSignal("Buried"):Connect(function()
			local buried = model:GetAttribute("Buried") == true
			entry.bar.Enabled = not buried and entry.health < entry.maxHealth
		end)
	end)
end

local function untrack(model: Model)
	local entry = tracked[model]
	if not entry then
		return
	end
	tracked[model] = nil
	if entry.conn then
		entry.conn:Disconnect()
	end
	-- The bar is a child of the (soon-destroyed) model, so it goes with it;
	-- nothing else to clean. Pooled numbers own their own anchors and outlive
	-- the fish, which is what lets a killing blow's number finish floating.
end

-- ---------------------------------------------------------------- lifecycle

function CombatFeedbackController.init()
	local container = Instance.new("Folder")
	container.Name = "CombatFeedback"
	container.Parent = Workspace
	buildNumberPool(container)
end

function CombatFeedbackController.start()
	folder = Workspace:WaitForChild("Creatures")
	folder.ChildAdded:Connect(track)
	folder.ChildRemoved:Connect(untrack)
	for _, child in folder:GetChildren() do
		track(child)
	end

	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		updateNumbers(now)
		updateFlashes(now)
	end)
end

return CombatFeedbackController
