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
--   Every standing mood also reaches its island's BOSS LAIR (BossArenas):
--   the lairs sit ~8k studs out in open ocean, outside every island
--   footprint, so the island probe alone left the Gloomtrench fight - whose
--   entire design is "the arena is pitch black, the boss's lanterns are the
--   only light, being lit is being hit" - being fought in broad daylight.
--   The mood lands ON ARRIVAL, not on the next probe: BossService signals
--   each player it teleports (WorldEvent, kind "arrival") and the dark is
--   already there when the camera opens (snapToArenaMood).
--
--   Arena storms (2026-08-30) - a BOSS can open a timed weather window over
--   its own lair, on the same WorldEvent remote under a different kind
--   ("arenastorm", { kind, islandId, active, duration?, mode? }). While one
--   runs, anyone standing in that arena wears the named mood; when it lapses
--   the lair goes back to its island's standing mood. Rimefang's phase-three
--   WHITEOUT is the first: the storm closes in over the windup and the
--   icicles come down out of it. A separate kind from "blizzard" on purpose,
--   because the two are opposite places - an island window must not fog a
--   lair 8k studs away, and a lair window must not fog the island (an arena
--   is deliberately not an island; BossArenas' header). Every window carries
--   its own DEADLINE, stamped here on arrival rather than trusted from a
--   close that may never come: a boss that dies mid-attack, a service that
--   errors, a player who walks out all end the storm anyway. A permanent
--   whiteout is worse than none.
--
--   Arena-only moods (2026-08-31) - a lair whose weather is not its island's
--   at all. The Ashfall Throne is a volcano SUMMIT 292 studs up, standing
--   above its own cloud deck, where the volcano island's ash is the caldera
--   at sea level. ARENA_MODES maps an owner island to the mood its LAIR
--   wears, is consulted ahead of STANDING_MODES at both sites that resolve
--   an owner, and changes nothing about the island itself.
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
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Islands = require(Shared.Config.Islands)
local BossArenas = require(Shared.Config.BossArenas)
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
	-- The Lampwright's Debt (hermit saga, 2026-08-29): the moth's unburnt
	-- wick, re-hung at the tip. It was a lamp before it was a rod.
	lampwrights_line_rod = true,
}

-- The fen's standing mist (swamp restart, 2026-08-28): client-only like the
-- gloom dark - being on the island IS the weather. Lighter than a blizzard,
-- greener than anything else: humid air under the canopy roof.
local MIST_DENSITY = 0.42
local MIST_FOG_END = 340

local BLIZZARD_DENSITY = 0.55
local BLIZZARD_FOG_END = 190

-- THE PHASE-TWO GRADE. Rimefang's enrage opener SHATTERS the floe and the
-- blizzard stops being a four-second attack and becomes the rest of the
-- fight (CreatureService re-signals every 12s while phase >= 2). A storm the
-- player is going to live in wants to say WHICH storm it is without a text
-- card, so it comes in one step denser and one step colder than the
-- whiteout's - near fog closed from 190 to 150, the pale grey-white pushed
-- toward blue, and the ambient dropped so the ice reads lit by the storm
-- rather than by the sun.
--
-- IT IS ITS OWN MODE ("blizzardRage"), not a flag read inside applyBlizzard,
-- and that is what makes the grade land at all: `refresh` only calls an APPLY
-- when the mode NAME changes, so a graded blizzard that kept the name
-- "blizzard" would be computed every probe and applied never.
local RAGE_DENSITY = 0.66
local RAGE_FOG_END = 150

-- Arena storm windows (see the header). The fight names the length it wants;
-- these are the guard rails around it. DEFAULT covers Rimefang's whiteout end
-- to end for a window that arrives with no duration at all (windup 1.1 +
-- duration 2.4 + recover 0.8 = 4.3s, Bosses.luau), and MAX is the ceiling no
-- single window can exceed - a longer storm re-fires to extend, so the worst
-- a fight that ends badly can cost is MAX seconds of fog.
local ARENA_STORM_DEFAULT = 4.5
local ARENA_STORM_MAX = 20
-- Faster than the ambient drift: a boss storm is an ATTACK, and the whiteout's
-- 1.1s windup is the whole tell budget - the sky has to have closed by the
-- time the icicles land, and lift promptly once the strikes are done.
local ARENA_STORM_TWEEN = 0.9
-- HOW NEAR ITS OWN END A WINDOW HAS TO BE BEFORE A CLOSE MAY LIFT IT.
--
-- `signalArenaStorm(def, p, false)` fires when the ATTACK that opened a
-- window ends, and in phase two two different things are signalling the same
-- island: the whiteout (a 4.5s attack) and the phase hold (20s, re-signalled
-- every 12s). Without this the whiteout's close ended the HOLD as well - the
-- fog dropped out mid-fight and came back on the next re-signal, which is the
-- exact pop this pass exists to remove. A close now ends only a window that
-- was about to lapse anyway; one still holding real time is a longer grant
-- that this close did not issue and does not get to revoke. It lapses against
-- its own deadline like every other window, so nothing can stick.
local ARENA_STORM_CLOSE_GRACE = 2.0

-- The remaining islands' standing moods (user, 2026-08-28: "when I visit a
-- new island, there should be a new environment" - the fog shifts with the
-- water). Same client-only model as the fen's mist: being there IS the
-- weather. Tuned to sit alongside the per-island water palettes in
-- Islands.luau - ash over the volcano's grey-teal, ghost-green over the
-- wreck's spectral sea, storm slate over the maelstrom.
local ASH_DENSITY = 0.36
local ASH_FOG_END = 420
-- ASH'S COLOURS, hoisted out of `applyAsh` so the SUMMIT can wear them (user,
-- 2026-09-12: the air at a lair is the air of the island it corresponds to).
-- The volcano's lair keeps its own DENSITY, HAZE and DISTANCE - that
-- divergence is load-bearing and documented at SUMMIT_DENSITY below - but
-- there is no reason for it to be a different COLOUR of grey, and with these
-- shared the "same air" claim is true in hue by construction rather than by
-- two hand-typed triples that can drift. One table rather than five locals:
-- this file is one of the two that live near Luau's 200-local-per-chunk
-- ceiling (see MEMORY / `luau-compile -O0`).
local ASH_AIR = {
	ambient = Color3.fromRGB(44, 38, 34),
	outdoor = Color3.fromRGB(128, 112, 100),
	fog = Color3.fromRGB(150, 138, 126),
	decay = Color3.fromRGB(120, 100, 88),
	legacyFog = Color3.fromRGB(142, 130, 118),
}
local GHOST_DENSITY = 0.4
local GHOST_FOG_END = 380
local STORM_DENSITY = 0.48
local STORM_FOG_END = 300

-- The Ashfall Throne (Pyrelisk's lair, 2026-08-31). The volcano's ash
-- travels out to its lair like every other standing mood, but ash is tuned
-- for the ISLAND - 0.36 at 420 studs - and 420 is shorter than this arena is
-- wide. The summit sits 292 studs up: the rim path is 464 across, the
-- colossus' crown stands 250 above it and the cloud deck runs out past 880
-- (arena_gen.py PY_RIM_WORLD_Y / PY_PATH_R / PY_CLOUD_R). Ash's distance
-- would put the far rim, the crown and the entire deck inside the fog.
--
-- The density is NOT the ash curve extrapolated. Fit Density against
-- 1/FogEnd across the standing moods above and you get ~0.158 + 91/FogEnd,
-- which lands ~0.21 at 1800 - and 0.21 is THINNER than the world's own
-- Atmosphere (0.28, WorldService.buildLighting). A summit clearer than the
-- open sea is the exact failure this mood exists to prevent: what it has to
-- lose is the ocean that reappears past the cloud deck's edge (from the rim
-- that band opens up only ~750 studs out, so no reach of DISTANCE hides it),
-- and thinning the air only sharpens it. So the density sits a hair over the
-- world default - the lightest fog in this file, still lighter than ash -
-- and the distance work is done by HAZE, the highest here (storm's 3.0 is
-- next): haze washes what is far toward the sky's colour without
-- extinguishing what is near, which is the read from a peak - crisp rock,
-- dissolving horizon. FOG_END drives only the no-Atmosphere fallback.
local SUMMIT_DENSITY = 0.3
local SUMMIT_FOG_END = 1800

-- The Ashfall Heart (act four of the Pyrelisk fight, 2026-09-12) - the
-- chamber UNDER the caldera, and the first mood in this file for a room with
-- NO SKY AND NO SUN. It is the summit's opposite in every direction: the
-- summit is the thinnest air here because what it must not lose is a horizon,
-- and this is a sealed obsidian dome 216 studs across whose only light is
-- molten rock.
--
-- THE DENSITY IS BOUNDED FROM BOTH SIDES, which is why it is not simply the
-- densest number in the file. The floor wants dense: the design asks for dark,
-- red-lit and oppressive, and the gloom's 0.72 at 160 is what that reads like.
-- The CEILING is the mechanic - SIX WALL VENTS at r 82-92 are what shoots at
-- you, and a player on the far side of the room is 190 studs from the vent
-- that is about to fire. Fog that eats a vent at 190 studs deletes the only
-- telegraph this fight has, and it deletes it silently: the room still looks
-- right, the globs simply arrive from nowhere.
--
-- So it sits ON the file's own curve (Density ~= 0.158 + 91/FogEnd, fitted
-- across the standing moods) at a distance chosen to clear that 190: 0.158 +
-- 91/230 = 0.554. Denser than storm, thinner than blizzard, and a long way
-- from the summit's 0.30 - which is the right relationship, because one of
-- these two places is a mountaintop and the other is the inside of it.
local HEARTCHAMBER_DENSITY = 0.55
local HEARTCHAMBER_FOG_END = 230

local defaults = nil -- Lighting snapshot, taken at init
local atmosphere: Atmosphere? = nil -- Lighting's Atmosphere (replicated from the server)
local atmosphereDefaults = nil -- its snapshot, taken when it appears
local blizzards: { [string]: boolean } = {} -- islandId -> a window is open
-- islandId -> the storm running over THAT island's lair, and the moment it
-- lapses. Deliberately not merged with `blizzards` above: same remote, and
-- the exact opposite place (header).
local arenaStorms: { [string]: { deadline: number, mode: string } } = {}
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

-- The boss lair the character is standing in, returned as the island that
-- OWNS it, or nil. A lair is its island's water even though it sits nowhere
-- near the footprint, so the moods have to travel out to it.
--
-- THE LOOP AND THE BOUNDS NOW LIVE IN `BossArenas` (MOOD_RADIUS /
-- MOOD_BOUNDS / ownerIslandAt), moved there verbatim on 2026-09-12 when the
-- SEA became the second consumer of the same answer: OceanController blends
-- the arena's water to the owning island's palette off this very probe, so
-- the lair's air and the lair's water are the same island by construction
-- instead of by two copies of the radii. The height gate stays ON here (no
-- `ignoreHeightGate`): open ocean under the Ashfall Throne must not wear a
-- mountaintop's sky.
local function currentArenaIslandId(): string?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return nil
	end
	local owner = BossArenas.ownerIslandAt(root.Position)
	return owner
end

local function holdingLanternRod(): boolean
	local rodId = player:GetAttribute(Equipment.ROD_ATTRIBUTE)
	return rodId ~= nil and LANTERN_RODS[rodId] == true
end

-- How long the CURRENT apply takes. Normally TWEEN_TIME - ambience should
-- drift, not snap. Dropped to 0 for the single apply that lands a lair's mood
-- on arrival (snapToArenaMood), where a cross-fade is the bug.
local tweenTime = TWEEN_TIME

local function tweenLighting(props: { [string]: any })
	TweenService:Create(Lighting, TweenInfo.new(tweenTime, Enum.EasingStyle.Sine), props):Play()
end

-- The fog, wherever it actually lives: with an Atmosphere present the
-- Atmosphere is tweened and the legacy properties are left alone (they are
-- ignored anyway); without one, the legacy fog still works.
local function tweenFog(atmosphereProps: { [string]: any }, legacyProps: { [string]: any })
	if atmosphere then
		TweenService:Create(atmosphere, TweenInfo.new(tweenTime, Enum.EasingStyle.Sine), atmosphereProps):Play()
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

-- ...and the same storm after the floe has gone (see RAGE_DENSITY). Written
-- out in full rather than layered on applyBlizzard: every mode in this file
-- states its whole Lighting/Atmosphere target, because a tween that omits a
-- property leaves whatever the LAST mode set, and a mood assembled from two
-- half-states is the one shape of bug this file cannot debug from a
-- screenshot.
local function applyBlizzardRage()
	tweenLighting({
		-- A step down and a step colder than the whiteout's 190,200,212: the
		-- sun is gone, the light on the ice is the storm's own.
		OutdoorAmbient = Color3.fromRGB(150, 166, 186),
		Brightness = defaults.Brightness,
		ClockTime = defaults.ClockTime,
		Ambient = defaults.Ambient,
	})
	tweenFog({
		Density = RAGE_DENSITY,
		-- Blue where the whiteout is paper-white. Both still light enough for
		-- the fight's DARK markers (SKIN.frost) to hold their contrast - the
		-- markers are the language of this fight and the fog must not eat them.
		Color = Color3.fromRGB(206, 220, 238),
		Decay = Color3.fromRGB(160, 178, 202),
		Haze = 3.2,
		Glare = 0,
	}, {
		FogEnd = RAGE_FOG_END,
		FogStart = 8,
		FogColor = Color3.fromRGB(202, 216, 234),
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

-- The caldera: warm grey ash hanging in the air, the sun an ember behind it.
local function applyAsh()
	tweenLighting({
		Ambient = ASH_AIR.ambient,
		OutdoorAmbient = ASH_AIR.outdoor,
		ClockTime = defaults.ClockTime,
		Brightness = defaults.Brightness * 0.85,
	})
	tweenFog({
		Density = ASH_DENSITY,
		Color = ASH_AIR.fog,
		Decay = ASH_AIR.decay,
		Haze = 2.6,
		Glare = 0.3,
	}, {
		FogEnd = ASH_FOG_END,
		FogStart = 24,
		FogColor = ASH_AIR.legacyFog,
	})
	setLamp(false, 0)
	setSnow(false)
end

-- Above the ash rather than in it: the Ashfall Throne stands on its own
-- cloud deck in open sun, so this is applyAsh's warm grey opened out and lit
-- UP - brighter than the caldera it looks down on, with a hard glare off the
-- deck. The one mood that belongs to a lair and not to an island
-- (ARENA_MODES).
local function applySummit()
	tweenLighting({
		Ambient = ASH_AIR.ambient,
		OutdoorAmbient = ASH_AIR.outdoor,
		ClockTime = defaults.ClockTime,
		Brightness = defaults.Brightness,
	})
	tweenFog({
		Density = SUMMIT_DENSITY,
		Color = ASH_AIR.fog,
		Decay = ASH_AIR.decay,
		Haze = 3.6,
		Glare = 0.5,
	}, {
		FogEnd = SUMMIT_FOG_END,
		FogStart = 60,
		FogColor = ASH_AIR.legacyFog,
	})
	setLamp(false, 0)
	setSnow(false)
end

-- Under the summit rather than on it: the Ashfall Heart is a sealed chamber
-- with no sky and no sun, so this is `applyGloom`'s shape - ClockTime 0, the
-- Brightness down to a floor, the dark pressing in - rewritten in the
-- Pyrelisk's own colours. Everything that is not rock in here is molten, and
-- the mood's whole job is to make sure the rock never reads as lit.
--
-- NO LAMP, and that is deliberate rather than an omission. The Gloomtrench
-- turns the player's own lamp on because its dark has nothing in it; this room
-- is lit by what it contains - the heart on its dais, the six vent mouths, the
-- veins in the floor, all Neon by the arena's Glow rule - and a lamp riding
-- the camera would flatten every one of them into the grey they are painted.
local function applyHeartChamber()
	tweenLighting({
		Ambient = Color3.fromRGB(20, 10, 8),
		OutdoorAmbient = Color3.fromRGB(30, 14, 10),
		ClockTime = 0,
		Brightness = 0.5,
	})
	tweenFog({
		Density = HEARTCHAMBER_DENSITY,
		Color = Color3.fromRGB(36, 14, 10),
		Decay = Color3.fromRGB(18, 7, 5),
		Haze = 1.4,
		Glare = 0,
	}, {
		FogEnd = HEARTCHAMBER_FOG_END,
		FogStart = 10,
		FogColor = Color3.fromRGB(30, 12, 9),
	})
	setLamp(false, 0)
	setSnow(false)
end

-- The ghost fleet: a cold green-grey sea mist, the light gone spectral -
-- matches the wreck's grey-green water and the hulks' pale glow.
local function applyGhost()
	tweenLighting({
		Ambient = Color3.fromRGB(30, 38, 36),
		OutdoorAmbient = Color3.fromRGB(120, 134, 126),
		ClockTime = defaults.ClockTime,
		Brightness = defaults.Brightness * 0.85,
	})
	tweenFog({
		Density = GHOST_DENSITY,
		Color = Color3.fromRGB(140, 158, 150),
		Decay = Color3.fromRGB(96, 120, 110),
		Haze = 2.2,
		Glare = 0,
	}, {
		FogEnd = GHOST_FOG_END,
		FogStart = 20,
		FogColor = Color3.fromRGB(132, 148, 140),
	})
	setLamp(false, 0)
	setSnow(false)
end

-- The maelstrom: slate stormlight, dense haze, a hard glare where the sun
-- fights through - the finale's sea is already storm-dark under it.
local function applyStorm()
	tweenLighting({
		Ambient = Color3.fromRGB(26, 30, 36),
		OutdoorAmbient = Color3.fromRGB(84, 94, 108),
		ClockTime = defaults.ClockTime,
		Brightness = defaults.Brightness * 0.7,
	})
	tweenFog({
		Density = STORM_DENSITY,
		Color = Color3.fromRGB(96, 110, 124),
		Decay = Color3.fromRGB(70, 82, 96),
		Haze = 3.0,
		Glare = 0.5,
	}, {
		FogEnd = STORM_FOG_END,
		FogStart = 14,
		FogColor = Color3.fromRGB(90, 102, 116),
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

-- Every standing island mood, keyed by where you are. Blizzards stay
-- separate: they are server-windowed events layered over the ice island,
-- not a standing mood.
local STANDING_MODES: { [string]: string } = {
	gloom = "gloom",
	swamp = "mist",
	volcano = "ash",
	wreck = "ghost",
	maelstrom = "storm",
}

-- The moods that belong to a LAIR rather than to the island that owns it,
-- and outrank that island's standing mood out there. The Ashfall Throne is
-- the first: the volcano ISLAND keeps its ash - a caldera at sea level -
-- while its lair, a summit 292 studs above a cloud deck, wears the thinner,
-- further "summit" instead. Consulted ahead of STANDING_MODES at BOTH sites
-- that turn an owner island into a mood (refresh, snapToArenaMood); a lair
-- with no row here still wears its island's standing mood, unchanged.
local ARENA_MODES: { [string]: string } = {
	volcano = "summit",
	-- The second, and the first whose key is not an island at all: the heart
	-- chamber's BossArenas row is keyed `pyrelisk_heart`, an island that does
	-- not exist (the `maelstrom_gullet` convention), and both sites that turn
	-- an owner island into a mood read THIS table before STANDING_MODES. With
	-- no row here the room would fall through to its owner's mood - and with
	-- no owner island either it would fall through to `clear`, so a sealed
	-- chamber 600 studs up would wear open daylight.
	pyrelisk_heart = "heartchamber",
	-- The Kraken's gullet, the third room keyed as an island that is not one -
	-- and until 2026-09-12 the one lair in the game with NO row in either
	-- table, which meant it fell through to `clear`: open daylight inside the
	-- animal's stomach. The user's rule settles it the literal way - "the air
	-- is the same as the island that it corresponds to" - so the Maelstrom's
	-- storm reaches the room the same way its water does.
	--
	-- IF IT READS WRONG IN PLAYTEST, the alternative is the heartchamber
	-- precedent one row up: a `gullet` mood on applyHeartChamber's shape
	-- (ClockTime 0, a Brightness floor, no sky) in the room's own MeshColors
	-- reds (KrakenGullet_Walls (55,22,28), _Base (74,33,38), _HeartGlow
	-- (230,74,73)), density on this file's own curve (0.158 + 91/FogEnd) at a
	-- distance that clears the room's widest telegraph. That is ~25 lines in
	-- these same two tables and nothing else - storm here is deliberately the
	-- zero-new-code answer, not a claim that a stomach is stormlit.
	maelstrom_gullet = "storm",
}

local APPLY: { [string]: () -> () } = {
	blizzard = applyBlizzard,
	-- Reachable only from the arena-storm handler, which upgrades the mode
	-- name locally: no server ever sends this string, and the handler's
	-- `APPLY[event.mode]` guard would reject it if one did.
	blizzardRage = applyBlizzardRage,
	mist = applyMist,
	ash = applyAsh,
	summit = applySummit,
	heartchamber = applyHeartChamber,
	ghost = applyGhost,
	storm = applyStorm,
	clear = applyClear,
}

-- The mood a lair storm is imposing on this island's arena right now, or nil.
-- Self-cancelling: the window expires against its own deadline here, so one
-- whose `active = false` never arrives lifts on the next probe (<= 1s) rather
-- than sticking for the session.
-- IS THE BOSS OF THIS ARENA ENRAGED? Generic on purpose - it asks the
-- creature standing in the arena, not "is this Rimefang" - so the next boss
-- whose second phase brings weather with it gets the graded storm for free.
-- Every read is nil-checked: no Creatures folder, no boss in it, or an
-- attribute the server has not published all answer `false`, and a false
-- answer is simply the ungraded storm.
local function arenaBossEnraged(islandId: string): boolean
	local arena = BossArenas.items[islandId]
	local center = arena and arena.center
	if not center then
		return false
	end
	local creatures = Workspace:FindFirstChild("Creatures")
	if not creatures then
		return false
	end
	-- The floe plus a margin: an arena's own boss and nothing on any island,
	-- which is 8k studs away.
	local reach = (arena.floorRadius or 120) + 60
	for _, model in creatures:GetChildren() do
		if model:IsA("Model") and model:GetAttribute("Enraged") == true then
			local ok, pivot = pcall(model.GetPivot, model)
			if ok and (pivot.Position - center).Magnitude <= reach then
				return true
			end
		end
	end
	return false
end

local function arenaStormMode(islandId: string): string?
	local window = arenaStorms[islandId]
	if not window then
		return nil
	end
	if os.clock() >= window.deadline then
		arenaStorms[islandId] = nil
		return nil
	end
	return window.mode
end

local function refresh()
	local here = currentIslandId()
	local mode = "clear"
	if here and STANDING_MODES[here] then
		mode = STANDING_MODES[here]
	elseif here and blizzards[here] then
		mode = "blizzard"
	else
		-- Nothing on the map claims you: you may be out at a lair, wearing the
		-- owning island's standing mood. Only the STANDING moods travel - a
		-- blizzard is a server-opened window over the ice ISLAND, and says
		-- nothing about the weather 8k studs away. A LAIR window (kind
		-- "arenastorm") is the mirror image: it belongs to the fight being
		-- fought right here, so it outranks the standing mood while it runs.
		local owner = currentArenaIslandId()
		mode = (owner and (arenaStormMode(owner) or ARENA_MODES[owner] or STANDING_MODES[owner])) or "clear"
	end
	-- Gloom re-applies even in-mode: the lantern rod can change in hand.
	if mode == "gloom" then
		applyGloom(holdingLanternRod())
	elseif mode ~= currentMode then
		APPLY[mode]()
	end
	currentMode = mode
end

-- The lair's mood, the instant the party lands in it. BossService fires this
-- at everyone it teleports (WorldEvent, kind "arrival") because the probe
-- alone is too slow to be a first impression: it runs on PROBE_INTERVAL and
-- then cross-fades, so the Gloomtrench - whose entire fight is "the arena is
-- pitch black and the boss's lanterns are the only light" - could open on up
-- to ~2.6 seconds of daylight for anyone who summoned from outside the
-- island's mood footprint (a boat off the dock is still well inside
-- BossService's summon margin). The server NAMES the island rather than
-- letting us re-probe: the character's new position may not have replicated
-- to its own client yet when this arrives, and probing a stale position would
-- put us back in daylight.
--
-- Only standing moods land this way. An arena whose island has none is
-- ordinary daylight, and snapping a blizzard's whiteout off mid-teleport
-- reads as a glitch where the probe's fade reads as weather. An arena-only
-- mood (ARENA_MODES) lands the same way and takes precedence, since it is
-- the same standing-mood machinery keyed to the lair instead of the island.
function WeatherController.snapToArenaMood(islandId: string?)
	local mode = islandId and (ARENA_MODES[islandId] or STANDING_MODES[islandId])
	if not mode then
		return
	end
	tweenTime = 0
	if mode == "gloom" then
		applyGloom(holdingLanternRod())
	else
		APPLY[mode]()
	end
	tweenTime = TWEEN_TIME
	currentMode = mode
	-- Hold off the next probe for a full interval, for the same replication
	-- lag: a probe on a position that hasn't caught up would fade the mood
	-- straight back out.
	lastProbe = os.clock()
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
		-- fallback): re-apply so the real fog takes over. Covers every
		-- mode, not just gloom/blizzard (2026-08-28 - mist and the three
		-- new island moods re-apply the same way).
		if currentMode ~= "clear" then
			local mode = currentMode
			if mode == "gloom" then
				applyGloom(holdingLanternRod())
			elseif APPLY[mode] then
				APPLY[mode]()
			end
			currentMode = mode
		end
	end
	local existing = Lighting:FindFirstChildOfClass("Atmosphere")
	if existing then
		adoptAtmosphere(existing)
	end
	Lighting.ChildAdded:Connect(adoptAtmosphere)

	Remotes.WorldEvent.OnClientEvent:Connect(function(event)
		if type(event) ~= "table" then
			return
		end
		if event.kind == "blizzard" then
			blizzards[event.islandId] = if event.active then true else nil
			refresh()
		elseif event.kind == "arrival" then
			WeatherController.snapToArenaMood(event.islandId)
		end
	end)

	-- Lair storms: the same remote, the other place (header). A fight opens a
	-- timed window over ITS arena and the CLIENT owns the ending - the
	-- deadline is stamped here, so the storm lifts on its own even if the
	-- close never arrives. Unknown islands and unknown modes are dropped
	-- rather than guessed at; a window for an island with no arena row can
	-- never be stood in, so it would only be a way to get the fog stuck.
	Remotes.WorldEvent.OnClientEvent:Connect(function(event)
		if type(event) ~= "table" or event.kind ~= "arenastorm" then
			return
		end
		local islandId = event.islandId
		if type(islandId) ~= "string" or BossArenas.items[islandId] == nil then
			return
		end
		local window = arenaStorms[islandId]
		if event.active then
			local mode = "blizzard"
			if type(event.mode) == "string" and APPLY[event.mode] then
				mode = event.mode
			end
			-- THE PHASE-TWO GRADE, decided here and nowhere else: the server
			-- says "blizzard" in both phases (the mode is a data field on the
			-- attack row), and which blizzard it is depends on the boss, which
			-- only the client is looking at. See RAGE_DENSITY.
			if mode == "blizzard" and arenaBossEnraged(islandId) then
				mode = "blizzardRage"
			end
			local seconds = tonumber(event.duration) or ARENA_STORM_DEFAULT
			local deadline = os.clock() + math.clamp(seconds, 0, ARENA_STORM_MAX)
			-- EXTEND, NEVER SHORTEN. A hold is kept alive by re-signalling
			-- (Rimefang's phase two: 20s every 12s), and the plain assignment
			-- this replaces meant any OTHER window over the same arena - the
			-- whiteout, at 4.5s - cut the hold down to its own length on
			-- arrival and the fog lifted eight seconds early. Taking the later
			-- of the two deadlines is also what makes a re-signal seamless:
			-- the mode name does not change, so `refresh` applies nothing and
			-- there is no tween to see. Still capped, because both sides of
			-- the max are at most now + ARENA_STORM_MAX.
			if window and window.deadline > deadline then
				deadline = window.deadline
			end
			-- ...but a GRADE change is a real change and must land: it is the
			-- one thing a re-signal is allowed to move.
			arenaStorms[islandId] = { deadline = deadline, mode = mode }
		elseif window and window.deadline <= os.clock() + ARENA_STORM_CLOSE_GRACE then
			-- See ARENA_STORM_CLOSE_GRACE: a close ends the window it opened
			-- and never a longer grant still holding real time.
			arenaStorms[islandId] = nil
		end
		-- Snap rather than drift, in and out: see ARENA_STORM_TWEEN.
		local previous = tweenTime
		tweenTime = ARENA_STORM_TWEEN
		refresh()
		tweenTime = previous
	end)
end

function WeatherController.start()
	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if now - lastProbe < PROBE_INTERVAL then
			-- Keep the snow holder glued to the camera between probes.
			if currentMode == "blizzard" or currentMode == "blizzardRage" then
				setSnow(true)
			end
			return
		end
		lastProbe = now
		refresh()
	end)
end

return WeatherController
