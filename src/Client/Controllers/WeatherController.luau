--!nonstrict
-- WeatherController.luau
-- Island ambience, entirely client-side. Two jobs:
--
--   Blizzard (ice island) - the server opens windows on the WorldEvent
--   remote (WeatherService); while one is open AND the local player is
--   standing on that island, the screen whites out: fog closes in, snow
--   streams past the camera. Someone fishing the tropics sees nothing.
--
--   Perpetual dark (gloom island) - no remote at all: standing on the gloom
--   island IS the event. Midnight, black fog closed to a lantern's reach,
--   and a personal lamp on the character. Holding one of the trench's own
--   lantern rods (Lanternline / Gloomheart) doubles what you can see - the
--   island's light-management mechanic in its simplest playable form.
--
-- Lighting is GLOBAL state, so this controller is the only thing in the
-- client that writes it: it snapshots the defaults at init and every frame
-- of ambience is a tween back toward either the snapshot or the preset.
-- Anything else that wants to touch Lighting should go through here.
--
-- FOG IS THE ATMOSPHERE, NOT Lighting.Fog* (review finding, 2026-08-25):
-- WorldService.buildLighting parents an Atmosphere to Lighting, and Roblox
-- IGNORES the legacy FogEnd/FogStart/FogColor properties whenever an
-- Atmosphere instance exists - tweening them renders nothing. So every
-- mode drives Atmosphere.Density/Color/Decay/Haze instead (snapshotted at
-- init the moment the replicated Atmosphere appears), and the legacy fog
-- properties are kept only as the fallback for a place with no Atmosphere.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Islands = require(Shared.Config.Islands)
local Equipment = require(Shared.Config.Equipment)
local World = require(Shared.Config.World)
local Remotes = require(Shared.Net.Remotes)

local player = Players.LocalPlayer

local WeatherController = {}

-- How often the "which island am I on" probe runs. Cheap (pure math), but
-- nothing about ambience needs frame precision.
local PROBE_INTERVAL = 1.0
local TWEEN_TIME = 1.6

-- The gloom island's personal lamp, and how thick the dark presses in.
-- Atmosphere.Density is the real fog knob (see the header): ~0.28 is the
-- world default, ~0.55 a heavy whiteout, past ~0.7 a wall. The legacy
-- FogEnd numbers below only matter in the no-Atmosphere fallback.
local GLOOM_DENSITY = 0.72
local GLOOM_DENSITY_LANTERN = 0.58
local GLOOM_FOG_END = 160
local GLOOM_FOG_END_LANTERN = 320
local LAMP_RANGE = 18
local LAMP_RANGE_LANTERN = 34
-- Rods whose light the trench respects (brighter lamp, further fog).
local LANTERN_RODS: { [string]: boolean } = {
	lanternline_rod = true,
	gloomheart_rod = true,
}

-- The fen's standing mist (swamp restart, 2026-08-28): client-only like the
-- gloom dark - being on the island IS the weather. Lighter than a blizzard,
-- greener than anything else: humid air under the canopy roof.
local MIST_DENSITY = 0.42
local MIST_FOG_END = 340

local BLIZZARD_DENSITY = 0.55
local BLIZZARD_FOG_END = 190

local defaults = nil -- Lighting snapshot, taken at init
local atmosphere: Atmosphere? = nil -- Lighting's Atmosphere (replicated from the server)
local atmosphereDefaults = nil -- its snapshot, taken when it appears
local blizzards: { [string]: boolean } = {} -- islandId -> a window is open
local currentMode = "clear" -- "clear" | "blizzard" | "gloom"
local lamp: PointLight? = nil
local snow: ParticleEmitter? = nil
local lastProbe = 0

-- ============================================================ helpers

-- The island the character is standing on (nearest centre within 1.5x its
-- footprint), or nil on the open sea. IslandsController keeps its own copy
-- of this; both are three lines over Islands.items.
local function currentIslandId(): string?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return nil
	end
	local here: string? = nil
	local bestDist = math.huge
	for id, entry in Islands.items do
		local p = entry.worldPosition
		local dist = (Vector2.new(root.Position.X, root.Position.Z) - Vector2.new(p.X, p.Z)).Magnitude
		if dist < (entry.radius or World.ISLAND_RADIUS) * 1.5 and dist < bestDist then
			bestDist = dist
			here = id
		end
	end
	return here
end

local function holdingLanternRod(): boolean
	local rodId = player:GetAttribute(Equipment.ROD_ATTRIBUTE)
	return rodId ~= nil and LANTERN_RODS[rodId] == true
end

local function tweenLighting(props: { [string]: any })
	TweenService:Create(Lighting, TweenInfo.new(TWEEN_TIME, Enum.EasingStyle.Sine), props):Play()
end

-- The fog, wherever it actually lives: with an Atmosphere present the
-- Atmosphere is tweened and the legacy properties are left alone (they are
-- ignored anyway); without one, the legacy fog still works.
local function tweenFog(atmosphereProps: { [string]: any }, legacyProps: { [string]: any })
	if atmosphere then
		TweenService:Create(atmosphere, TweenInfo.new(TWEEN_TIME, Enum.EasingStyle.Sine), atmosphereProps):Play()
	else
		tweenLighting(legacyProps)
	end
end

-- ============================================================ the lamp

local function setLamp(on: boolean, range: number)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not on then
		if lamp then
			lamp:Destroy()
			lamp = nil
		end
		return
	end
	if not (root and root:IsA("BasePart")) then
		return
	end
	if not lamp or lamp.Parent ~= root then
		if lamp then
			lamp:Destroy()
		end
		lamp = Instance.new("PointLight")
		lamp.Name = "GloomLamp"
		lamp.Color = Color3.fromRGB(255, 226, 160)
		lamp.Shadows = false
		lamp.Parent = root
	end
	lamp.Range = range
	lamp.Brightness = 1.4
end

-- ============================================================ the snow

local function setSnow(on: boolean)
	local camera = workspace.CurrentCamera
	if not on then
		if snow then
			snow.Enabled = false
		end
		return
	end
	if not camera then
		return
	end
	if not snow or not snow.Parent then
		local holder = camera:FindFirstChild("SnowHolder")
		if not holder then
			holder = Instance.new("Part")
			holder.Name = "SnowHolder"
			holder.Size = Vector3.new(1, 1, 1)
			holder.Transparency = 1
			holder.CanCollide = false
			holder.CanQuery = false
			holder.CanTouch = false
			holder.Anchored = true
			holder.Parent = camera
		end
		snow = Instance.new("ParticleEmitter")
		snow.Name = "Snow"
		snow.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		snow.Color = ColorSequence.new(Color3.fromRGB(240, 248, 255))
		snow.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.12),
			NumberSequenceKeypoint.new(1, 0.05),
		})
		snow.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.25),
			NumberSequenceKeypoint.new(1, 1),
		})
		snow.Rate = 160
		snow.Lifetime = NumberRange.new(1.2, 2.0)
		snow.Speed = NumberRange.new(16, 26)
		snow.SpreadAngle = Vector2.new(35, 35)
		snow.EmissionDirection = Enum.NormalId.Bottom
		snow.LockedToPart = true
		snow.Parent = camera.SnowHolder
	end
	snow.Enabled = true
	-- Ride ~14 studs above the camera so flakes stream down past the view.
	local holder = camera:FindFirstChild("SnowHolder")
	if holder then
		holder.CFrame = camera.CFrame * CFrame.new(0, 14, 0)
	end
end

-- ============================================================ modes

local function applyClear()
	tweenLighting({
		Ambient = defaults.Ambient,
		OutdoorAmbient = defaults.OutdoorAmbient,
		ClockTime = defaults.ClockTime,
		Brightness = defaults.Brightness,
	})
	tweenFog(
		atmosphereDefaults or {},
		{ FogEnd = defaults.FogEnd, FogStart = defaults.FogStart, FogColor = defaults.FogColor }
	)
	setLamp(false, 0)
	setSnow(false)
end

local function applyBlizzard()
	tweenLighting({
		OutdoorAmbient = Color3.fromRGB(190, 200, 212),
		Brightness = defaults.Brightness,
		ClockTime = defaults.ClockTime,
		Ambient = defaults.Ambient,
	})
	-- The whiteout: thick, bright atmosphere with no sun glare through it.
	tweenFog({
		Density = BLIZZARD_DENSITY,
		Color = Color3.fromRGB(230, 240, 248),
		Decay = Color3.fromRGB(200, 212, 224),
		Haze = 2.8,
		Glare = 0,
	}, {
		FogEnd = BLIZZARD_FOG_END,
		FogStart = 12,
		FogColor = Color3.fromRGB(226, 236, 244),
	})
	setLamp(false, 0)
	setSnow(true)
end

-- The fen: a green-grey haze hanging between the trunks, the light dimmed
-- and warmed a step - humid, hushed, never as blinding as a blizzard nor as
-- black as the trench.
local function applyMist()
	tweenLighting({
		Ambient = Color3.fromRGB(36, 42, 32),
		OutdoorAmbient = Color3.fromRGB(96, 106, 86),
		ClockTime = defaults.ClockTime,
		Brightness = defaults.Brightness * 0.8,
	})
	tweenFog({
		Density = MIST_DENSITY,
		Color = Color3.fromRGB(142, 152, 128),
		Decay = Color3.fromRGB(104, 116, 96),
		Haze = 2.4,
		Glare = 0,
	}, {
		FogEnd = MIST_FOG_END,
		FogStart = 18,
		FogColor = Color3.fromRGB(134, 144, 120),
	})
	setLamp(false, 0)
	setSnow(false)
end

local function applyGloom(lanternHeld: boolean)
	tweenLighting({
		Ambient = Color3.fromRGB(14, 12, 22),
		OutdoorAmbient = Color3.fromRGB(22, 20, 34),
		ClockTime = 0,
		Brightness = 0.6,
	})
	-- The dark presses in; a lantern rod pushes it back a real, visible step.
	tweenFog({
		Density = if lanternHeld then GLOOM_DENSITY_LANTERN else GLOOM_DENSITY,
		Color = Color3.fromRGB(10, 12, 20),
		Decay = Color3.fromRGB(6, 8, 14),
		Haze = 2.2,
		Glare = 0,
	}, {
		FogEnd = if lanternHeld then GLOOM_FOG_END_LANTERN else GLOOM_FOG_END,
		FogStart = 6,
		FogColor = Color3.fromRGB(8, 8, 14),
	})
	setLamp(true, if lanternHeld then LAMP_RANGE_LANTERN else LAMP_RANGE)
	setSnow(false)
end

local function refresh()
	local here = currentIslandId()
	local mode = "clear"
	if here == "gloom" then
		mode = "gloom"
	elseif here == "swamp" then
		mode = "mist"
	elseif here and blizzards[here] then
		mode = "blizzard"
	end
	-- Gloom re-applies even in-mode: the lantern rod can change in hand.
	if mode == "gloom" then
		applyGloom(holdingLanternRod())
	elseif mode ~= currentMode then
		if mode == "blizzard" then
			applyBlizzard()
		elseif mode == "mist" then
			applyMist()
		else
			applyClear()
		end
	end
	currentMode = mode
end

-- ============================================================ lifecycle

function WeatherController.init()
	defaults = {
		FogEnd = Lighting.FogEnd,
		FogStart = Lighting.FogStart,
		FogColor = Lighting.FogColor,
		Ambient = Lighting.Ambient,
		OutdoorAmbient = Lighting.OutdoorAmbient,
		ClockTime = Lighting.ClockTime,
		Brightness = Lighting.Brightness,
	}

	-- The server's Atmosphere (WorldService.buildLighting) may not have
	-- replicated yet when the client boots; adopt it whenever it appears and
	-- snapshot the numbers every mode returns to.
	local function adoptAtmosphere(instance: Instance)
		if not instance:IsA("Atmosphere") or atmosphere ~= nil then
			return
		end
		atmosphere = instance
		atmosphereDefaults = {
			Density = instance.Density,
			Color = instance.Color,
			Decay = instance.Decay,
			Haze = instance.Haze,
			Glare = instance.Glare,
		}
		-- Adopted mid-mode (it replicated after we fogged via the legacy
		-- fallback): re-apply so the real fog takes over.
		if currentMode ~= "clear" then
			local mode = currentMode
			currentMode = "clear"
			if mode == "gloom" then
				applyGloom(holdingLanternRod())
				currentMode = mode
			elseif mode == "blizzard" then
				applyBlizzard()
				currentMode = mode
			end
		end
	end
	local existing = Lighting:FindFirstChildOfClass("Atmosphere")
	if existing then
		adoptAtmosphere(existing)
	end
	Lighting.ChildAdded:Connect(adoptAtmosphere)

	Remotes.WorldEvent.OnClientEvent:Connect(function(event)
		if type(event) ~= "table" or event.kind ~= "blizzard" then
			return
		end
		blizzards[event.islandId] = if event.active then true else nil
		refresh()
	end)
end

function WeatherController.start()
	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if now - lastProbe < PROBE_INTERVAL then
			-- Keep the snow holder glued to the camera between probes.
			if currentMode == "blizzard" then
				setSnow(true)
			end
			return
		end
		lastProbe = now
		refresh()
	end)
end

return WeatherController
