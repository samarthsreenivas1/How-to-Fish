--!nonstrict
-- FloeController.luau
-- THE BREAKING FLOE, AS THE PLAYER SEES IT. The client half of FloeService:
-- one remote (`FloeEvent`), no decisions.
--
-- WHAT THIS FILE OWNS, and what it deliberately does not. The shard PARTS are
-- the server's: their CFrame (the sink, the Undertow drift), their CanCollide
-- and their Transparency all replicate, so nothing here animates a shard's
-- body. What it owns is everything that is not a property of a part:
--
--   * the crack tint + `rimeCrackWeb` on a shard that is about to let go,
--   * the splash and `rimeIceBurst` when it does,
--   * the frost creeping back in over the three seconds it refreezes,
--   * the shimmer on ice she has refrozen SLICK, and the friction that makes
--     it slick - which has to be a LOCAL property write, because a player's
--     character is simulated on their own machine,
--   * the Frozen meter and its frost vignette,
--   * the Refreeze heal's glow over each misted shard (`rimeRiftAmbient`),
--   * the rod moments: the banner, the target ring on the blowhole or the
--     shoal, and the `rodDraw` cue that says the rod is the answer NOW.
--
-- AND IT IS THE ROD WINDOW'S ONLY READER. `FloeController.rodWindow()` is what
-- FishingController asks before it refuses a cast in a boss fight: a pure read
-- of a local, nil outside a window, so it is safe to call from a controller
-- that inits earlier (the same one-way exception BossHudController.isEngaged
-- already is).
--
-- NO THUNDER, no weather, no camera shake: this fight's sky belongs to
-- WeatherController and its kicks to CombatVfxController.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BossArenas = require(Shared.Config.BossArenas)
local RimefangFloe = require(Shared.Config.RimefangFloe)
local Remotes = require(Shared.Net.Remotes)

local Theme = require(script.Parent.Parent.UI.Theme)
local Kit = require(script.Parent.Parent.UI.Kit)
local Sfx = require(script.Parent.Parent.Modules.Sfx)
local Vfx = require(script.Parent.Parent.Modules.Vfx)

local player = Players.LocalPlayer

local FloeController = {}

local ISLAND = "ice"

-- The tint a cracking shard takes, and the frost a refreezing one wears. Both
-- are written onto the part's own Color LOCALLY and restored from the colour it
-- was found with - the server never writes a shard's colour, so there is one
-- writer and no fight over the property.
local CRACK_TINT = Color3.fromRGB(120, 150, 180)
local FROST_TINT = Color3.fromRGB(235, 248, 255)
-- Slick ice: near-frictionless and faintly wet-looking.
local SLICK_FRICTION = 0.05
local SLICK_REFLECTANCE = 0.35
-- The banner colours: the ice blue for a rod moment, the lure teal for the
-- shoal, and the heal's cold white for "break the ice".
local ROD_COLOR = Color3.fromRGB(150, 220, 255)
local SHOAL_COLOR = Color3.fromRGB(120, 255, 214)
local MIST_COLOR = Color3.fromRGB(215, 240, 255)

-- The text each moment puts on screen. Stated once: the server sends the
-- window's KIND, never its words.
local BANNER = {
	blowhole = "CAST AT THE BLOWHOLE",
	shoal = "HOOK THE SHOAL",
}

local gui: ScreenGui
local banner: TextLabel
local meterFill: Frame
local meterFrame: Frame
local vignette: Frame
local frostGradient: UIGradient

-- id -> { part, color, reflectance, properties } as found, so every local
-- write can be undone exactly.
local shards: { [number]: any } = {}
local bound = false

-- The live target ring (a window) and the mist glows, by shard id.
local ring: BasePart? = nil
local glows: { [number]: BasePart } = {}
local mistLoop: BasePart? = nil

-- The window the server says is open, and the meter it says this player is at.
local window: string? = nil
local windowAt: Vector3? = nil
local frozen = 0
local frozenHeld = false

-- ------------------------------------------------------------------ binding

local function bind(): boolean
	if bound then
		return true
	end
	local folder = Workspace:FindFirstChild("BossArenas")
	local arena = BossArenas.items[ISLAND]
	local model = folder and arena and folder:FindFirstChild(arena.model)
	if not model then
		return false
	end
	for id = 1, RimefangFloe.count do
		local part = model:FindFirstChild(RimefangFloe.objectName(id), true)
		if part and part:IsA("BasePart") then
			shards[id] = {
				part = part,
				color = part.Color,
				reflectance = part.Reflectance,
				properties = part.CustomPhysicalProperties,
			}
		end
	end
	bound = next(shards) ~= nil
	return bound
end

-- Where a shard is RIGHT NOW (it may be sunk, or mid-drift), for a cue or a
-- splash that has to land on it.
local function shardPosition(id: number): Vector3?
	local entry = shards[id]
	if not entry then
		return nil
	end
	local part = entry.part
	return part.Position + Vector3.new(0, part.Size.Y * 0.5, 0)
end

-- ----------------------------------------------------------------- the HUD

local function showBanner(text: string, color: Color3, seconds: number?)
	banner.Text = text
	banner.TextColor3 = color
	banner.Visible = true
	if seconds then
		task.delay(seconds, function()
			if banner.Text == text then
				banner.Visible = false
			end
		end)
	end
end

local function hideBanner(text: string?)
	if text == nil or banner.Text == text then
		banner.Visible = false
	end
end

local function buildGui()
	gui = Instance.new("ScreenGui")
	gui.Name = "FloeHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	-- THE FROST CLOSING IN, and it is built out of a gradient rather than an
	-- image on purpose: an uploaded vignette asset is one more thing that can
	-- fail to load, and what this needs is only "the edges of the screen go
	-- white". One full-screen frame, a vertical gradient that is opaque at the
	-- top and bottom and clear through the middle, and the whole thing faded by
	-- the meter. `frostGradient` is what the meter actually drives.
	vignette = Kit.frame(gui, {
		Name = "Frost",
		BackgroundColor3 = FROST_TINT,
		BackgroundTransparency = 0.4,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 1,
		Visible = false,
	})
	frostGradient = Instance.new("UIGradient")
	frostGradient.Rotation = 90
	frostGradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.42, 1),
		NumberSequenceKeypoint.new(0.58, 1),
		NumberSequenceKeypoint.new(1, 0),
	})
	frostGradient.Parent = vignette

	banner = Kit.label(gui, {
		Name = "FloeBanner",
		Text = "",
		TextSize = 34,
		Font = Theme.Font.header,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextStrokeTransparency = 0.2,
		TextStrokeColor3 = Theme.Color.ink,
		TextColor3 = ROD_COLOR,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.18, 0),
		Size = UDim2.new(0.7, 0, 0, 44),
		ZIndex = 4,
		Visible = false,
	})

	meterFrame = Kit.frame(gui, {
		Name = "FrozenMeter",
		BackgroundColor3 = Theme.Color.border,
		BackgroundTransparency = 0.15,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 0.9, 0),
		Size = UDim2.new(0, 220, 0, 14),
		ZIndex = 4,
		Visible = false,
	})
	Kit.corner(meterFrame, 7)
	Kit.stroke(meterFrame, Theme.Color.ink, 2)
	meterFill = Kit.frame(meterFrame, {
		Name = "Fill",
		BackgroundColor3 = ROD_COLOR,
		BackgroundTransparency = 0,
		Size = UDim2.fromScale(0, 1),
	})
	Kit.corner(meterFill, 7)
end

-- ------------------------------------------------------------- shard visuals

local function tint(id: number, color: Color3, seconds: number?)
	local entry = shards[id]
	if not entry then
		return
	end
	if seconds and seconds > 0 then
		TweenService:Create(entry.part, TweenInfo.new(seconds), { Color = color }):Play()
	else
		entry.part.Color = color
	end
end

local function restore(id: number, seconds: number?)
	local entry = shards[id]
	if not entry then
		return
	end
	entry.part.Reflectance = entry.reflectance
	entry.part.CustomPhysicalProperties = entry.properties
	tint(id, entry.color, seconds)
end

local function onCrack(ids, seconds: number)
	for _, id in ids do
		local at = shardPosition(id)
		if at then
			tint(id, CRACK_TINT, math.min(seconds * 0.5, 1.2))
			Sfx.play("rimeCrackWeb", at)
			-- The seam: a flat ring drawn on the shard, sized to the shard's own
			-- plate, running for the whole telegraph so the countdown is visible
			-- rather than remembered.
			Vfx.ring(at, 2, math.sqrt((RimefangFloe.shards[id] or { area = 600 }).area / math.pi), seconds, CRACK_TINT)
		end
	end
end

local function onOpen(ids)
	for _, id in ids do
		local at = shardPosition(id)
		if at then
			Vfx.splash(at, 1.4)
			Sfx.play("rimeIceBurst", at)
			Sfx.play("splashRing", at)
		end
	end
end

local function onRefreeze(ids, seconds: number)
	for _, id in ids do
		local at = shardPosition(id)
		if at then
			-- The frost CREEPS: the shard goes white over the window and then
			-- eases back to its authored ice in `onSolid`.
			tint(id, FROST_TINT, seconds)
			Sfx.play("chillTick", at)
			Vfx.ring(at, math.sqrt((RimefangFloe.shards[id] or { area = 600 }).area / math.pi), 2, seconds, FROST_TINT)
		end
	end
end

local function onSolid(ids)
	for _, id in ids do
		restore(id, 0.8)
	end
end

local function onSlick(ids, seconds: number)
	for _, id in ids do
		local entry = shards[id]
		if entry then
			entry.part.Reflectance = SLICK_REFLECTANCE
			entry.part.CustomPhysicalProperties = PhysicalProperties.new(0.7, SLICK_FRICTION, 0.5, 100, 1)
			local at = shardPosition(id)
			if at then
				Sfx.play("rimeCrackLock", at)
			end
			task.delay(seconds, function()
				-- Only if nothing has happened to the shard since: a shard that
				-- cracked again inside its own slick window belongs to whatever
				-- cracked it.
				if shards[id] == entry then
					entry.part.Reflectance = entry.reflectance
					entry.part.CustomPhysicalProperties = entry.properties
				end
			end)
		end
	end
end

-- ------------------------------------------------------------- the moments

local function clearRing()
	if ring then
		ring:Destroy()
		ring = nil
	end
end

-- The glowing target over the thing the rod is aimed at. A ring, not a disc:
-- the blowhole is a hole, and filling it in would hide the water she comes up
-- through.
local function showRing(at: Vector3, radius: number, color: Color3)
	clearRing()
	local part = Instance.new("Part")
	part.Name = "FloeTarget"
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(0.4, radius * 2, radius * 2)
	part.CFrame = CFrame.new(at + Vector3.new(0, 0.6, 0)) * CFrame.Angles(0, 0, math.rad(90))
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = 0.45
	part.Parent = Workspace
	ring = part
end

local function onWindow(kind: string?, at, radius: number?, seconds: number?)
	window = kind
	windowAt = if typeof(at) == "Vector3" then at else nil
	if not kind then
		clearRing()
		hideBanner()
		return
	end
	if windowAt then
		showRing(windowAt, radius or 10, if kind == "shoal" then SHOAL_COLOR else ROD_COLOR)
	end
	showBanner(BANNER[kind] or "CAST", if kind == "shoal" then SHOAL_COLOR else ROD_COLOR, seconds)
	-- THE ROD GOES UP. The one cue that says "this is a rod moment" - the same
	-- draw the viewmodel plays when the rod comes into hand, used here as a
	-- prompt rather than as a loadout change.
	Sfx.play("rodDraw")
	if seconds then
		task.delay(seconds, function()
			if window == kind then
				window = nil
				clearRing()
				hideBanner(BANNER[kind])
			end
		end)
	end
end

local function onMist(ids, seconds: number)
	for _, id in ids do
		local at = shardPosition(id)
		if at and not glows[id] then
			local glow = Instance.new("Part")
			glow.Name = "FloeMist"
			glow.Shape = Enum.PartType.Ball
			glow.Size = Vector3.new(6, 6, 6)
			glow.Position = at + Vector3.new(0, 3, 0)
			glow.Anchored = true
			glow.CanCollide = false
			glow.CanQuery = false
			glow.CastShadow = false
			glow.Material = Enum.Material.Neon
			glow.Color = MIST_COLOR
			glow.Transparency = 0.35
			glow.Parent = Workspace
			glows[id] = glow
		end
	end
	if not mistLoop then
		local at = shardPosition(ids[1] or 0)
		if at then
			mistLoop = Sfx.loop("rimeRiftAmbient", at)
		end
	end
	showBanner("BREAK THE ICE", MIST_COLOR, seconds)
end

local function onMistEnd(ids, healed: boolean)
	for _, id in ids do
		local glow = glows[id]
		if glow then
			glows[id] = nil
			local at = glow.Position
			glow:Destroy()
			Vfx.burst(at, if healed then MIST_COLOR else ROD_COLOR)
			Sfx.play(if healed then "rimeSpout" else "rimeShatter", at)
		end
	end
	if next(glows) == nil then
		Sfx.stopLoop(mistLoop)
		mistLoop = nil
		hideBanner("BREAK THE ICE")
	end
end

-- ------------------------------------------------------------------ events

local function onFloeEvent(payload)
	if type(payload) ~= "table" then
		return
	end
	local kind = payload.kind
	-- The meter is addressed to this player only and needs no parts at all, so
	-- it is answered before the bind: a client that has not found the arena yet
	-- still freezes.
	if kind == "frozen" then
		frozen = tonumber(payload.value) or 0
		frozenHeld = payload.held == true
		return
	end
	if kind == "window" then
		onWindow(payload.window, payload.at, tonumber(payload.radius), tonumber(payload.seconds))
		return
	end
	if not bind() then
		return
	end
	local ids = payload.ids
	local seconds = tonumber(payload.seconds) or 0
	-- The state NAMES are the kinds: FloeService fires the state a set of shards
	-- has just entered, so there is no second vocabulary to keep in step.
	if kind == "cracking" and type(ids) == "table" then
		onCrack(ids, seconds)
	elseif kind == "open" and type(ids) == "table" then
		onOpen(ids)
	elseif kind == "refreezing" and type(ids) == "table" then
		onRefreeze(ids, seconds)
	elseif kind == "solid" and type(ids) == "table" then
		onSolid(ids)
	elseif kind == "slick" and type(ids) == "table" then
		onSlick(ids, if seconds > 0 then seconds else 20)
	elseif kind == "drift" then
		local centre = (BossArenas.items[ISLAND] or {}).center
		if centre then
			Sfx.play("rimeQuake", centre)
		end
	elseif kind == "mist" and type(ids) == "table" then
		onMist(ids, seconds)
	elseif kind == "mistEnd" and type(ids) == "table" then
		onMistEnd(ids, payload.healed == true)
	end
end

-- --------------------------------------------------------------- public read

-- THE ONE THING ANOTHER CONTROLLER ASKS. nil outside a rod moment; the window's
-- kind inside one. A pure read of a local - no yielding, no instances - which
-- is what makes it safe for FishingController to call even though this
-- controller inits after it.
function FloeController.rodWindow(): string?
	return window
end

function FloeController.windowPosition(): Vector3?
	return windowAt
end

function FloeController.frozenFraction(): number
	return frozen
end

-- ------------------------------------------------------------------ lifecycle

function FloeController.init()
	buildGui()
	Remotes.FloeEvent.OnClientEvent:Connect(onFloeEvent)
end

function FloeController.start()
	RunService.RenderStepped:Connect(function(dt)
		-- The meter and the frost, eased so a tick every tenth of a second does
		-- not read as a staircase.
		local shown = math.clamp(frozen, 0, 1)
		meterFrame.Visible = shown > 0.01
		meterFill.Size = UDim2.fromScale(shown, 1)
		meterFill.BackgroundColor3 = if frozenHeld then FROST_TINT else ROD_COLOR
		vignette.Visible = shown > 0.05
		vignette.BackgroundTransparency = 1 - shown * 0.6
		-- The target ring breathes, which is the whole of "it is still open".
		if ring then
			local pulse = 0.35 + 0.12 * math.sin(os.clock() * 4)
			ring.Transparency = pulse
		end
		-- A held player hears the cold.
		if frozenHeld and math.random() < dt * 2 then
			Sfx.play("chillTick")
		end
	end)
end

return FloeController
