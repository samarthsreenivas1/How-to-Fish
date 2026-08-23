--!nonstrict
-- PlayerHudController.luau
-- The player's own health, top-right: a heart tile and a rounded bar that
-- shrinks when hit, plus a red screen flash on damage. Reads the
-- character's Humanoid directly (PlayerService owns the Humanoid's health
-- server-side), so there's no remote: the bar follows Humanoid.Health /
-- MaxHealth and re-hooks on every respawn.
--
-- No numbers on purpose (user, 2026-08-22: "minimal"; 2026-08-23: "less
-- text and numbers"). The engine's default health display is turned off so
-- there's one bar. Top-left is free, top-centre holds the banners.

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Parent.UI.Theme)
local Kit = require(script.Parent.Parent.UI.Kit)

local player = Players.LocalPlayer

local PlayerHudController = {}

local C = Theme.Color

local BAR_WIDTH = 210
local BAR_HEIGHT = 14
local MARGIN = 16
local TILE = 30

local FILL_TIME = 0.25
local FLASH_PEAK = 0.62
local FLASH_FADE = 0.4

local gui: ScreenGui
local fill: Frame
local flash: Frame
local heart: Frame

local humanoid: Humanoid? = nil
local conns: { RBXScriptConnection } = {}
local lastHealth: number? = nil

-- ============================================================ build

local function buildHud()
	gui = Instance.new("ScreenGui")
	gui.Name = "PlayerHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	flash = Kit.frame(gui, {
		Name = "DamageFlash",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(180, 30, 30),
		BackgroundTransparency = 1,
		ZIndex = 0,
	})

	local holder = Kit.frame(gui, {
		Name = "Health",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -MARGIN, 0, MARGIN),
		Size = UDim2.fromOffset(BAR_WIDTH + TILE + 8, TILE),
		ZIndex = 1,
	})

	heart = Kit.tile(holder, {
		name = "Heart",
		size = TILE,
		color = C.red,
		token = "HP",
		tokenSize = 11,
		radius = 10,
		anchor = Vector2.new(0, 0.5),
		position = UDim2.new(0, 0, 0.5, 0),
	})

	local track = Kit.frame(holder, {
		Name = "Track",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(BAR_WIDTH, BAR_HEIGHT),
		BackgroundTransparency = 0.25,
		BackgroundColor3 = C.background,
	})
	Kit.corner(track, BAR_HEIGHT)
	Kit.stroke(track, Color3.new(1, 1, 1), 1, 0.85)
	Kit.padding(track, 2, 2, 2, 2)

	fill = Kit.frame(track, {
		Name = "Fill",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 0,
		BackgroundColor3 = C.green,
	})
	Kit.corner(fill, BAR_HEIGHT)
	Kit.gradient(fill, Color3.new(1, 1, 1), Color3.fromRGB(180, 180, 180), 90)

	gui.Parent = player:WaitForChild("PlayerGui")
end

-- ============================================================ update

local function playFlash()
	flash.BackgroundTransparency = FLASH_PEAK
	TweenService:Create(flash, TweenInfo.new(FLASH_FADE, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = 1,
	}):Play()
	-- The heart jolts.
	heart.Size = UDim2.fromOffset(TILE + 6, TILE + 6)
	TweenService:Create(heart, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Size = UDim2.fromOffset(TILE, TILE),
	}):Play()
end

local function refresh()
	if not humanoid then
		return
	end
	local health = humanoid.Health
	local maxHealth = math.max(1, humanoid.MaxHealth)
	local fraction = math.clamp(health / maxHealth, 0, 1)

	TweenService:Create(fill, TweenInfo.new(FILL_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.fromScale(fraction, 1),
		BackgroundColor3 = if fraction > 0.5 then C.green elseif fraction > 0.25 then C.gold else C.red,
	}):Play()

	if lastHealth and health < lastHealth - 0.001 then
		playFlash()
	end
	lastHealth = health
end

-- ============================================================ character

local function disableCoreHealth()
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
	end)
end

local function hookCharacter(character: Model)
	disableCoreHealth()
	for _, conn in conns do
		conn:Disconnect()
	end
	table.clear(conns)

	local hum = character:WaitForChild("Humanoid", 10)
	if not hum or not hum:IsA("Humanoid") then
		return
	end
	humanoid = hum
	lastHealth = nil

	table.insert(conns, hum.HealthChanged:Connect(refresh))
	table.insert(conns, hum:GetPropertyChangedSignal("MaxHealth"):Connect(refresh))
	refresh()
end

-- ============================================================ lifecycle

function PlayerHudController.init()
	disableCoreHealth()
	buildHud()
end

function PlayerHudController.start()
	player.CharacterAdded:Connect(hookCharacter)
	if player.Character then
		hookCharacter(player.Character)
	end
end

return PlayerHudController
