--!nonstrict
-- Sfx.luau
-- Small client-only sound library, the audio twin of Vfx.luau. One named
-- catalogue of sounds (CATALOGUE below) and one call to play them, either
-- in 3D at a world position or flat "in the player's ears" for things that
-- are about the player (the cast swing, reel clicks, the catch jingle).
--
-- Every entry uses a Roblox built-in rbxasset sound - the same files the
-- default character scripts and the classic tools ship with - so nothing has
-- to be uploaded and the whole thing lives in the repo. They're placeholders
-- in spirit (per the plan, audio is meant to stay rough until the loop is
-- proven); swapping one for a real recording is changing its `id` to an
-- rbxassetid:// and nothing else.
--
-- Each play gets a little random pitch wobble (`pitchVar`) so a flop that
-- repeats every second doesn't sound like a sampler.
--
-- Two standing rules from the user (2026-08-22): splat.wav is never used,
-- and a creature on the water makes no sound (no breach / landing / flop
-- cue there - splash VFX only).

local Debris = game:GetService("Debris")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Sfx = {}

-- name -> { id, volume, pitch, pitchVar, range, maxDuration }
--   pitch       - base PlaybackSpeed
--   pitchVar    - +/- random variation on top of it
--   range       - RollOffMaxDistance for 3D plays (ignored for 2D)
--   maxDuration - optional; fade out and stop after this many seconds, for
--                 using just the front of a longer built-in clip
local CATALOGUE = {
	-- Rod / fishing
	castSwing = { id = "rbxasset://sounds/swoosh.wav", volume = 0.55, pitch = 1.1, pitchVar = 0.08, range = 40 },
	bobberPlop = { id = "rbxasset://sounds/impact_water.mp3", volume = 0.45, pitch = 1.35, pitchVar = 0.1, range = 60 },
	tug = { id = "rbxasset://sounds/impact_water.mp3", volume = 0.3, pitch = 1.6, pitchVar = 0.15, range = 50 },
	-- Reel hits have no sound of their own (the ping was tried and cut) -
	-- the `tug` splash at the bobber is the hit feedback. Misses do thunk.
	reelMiss = { id = "rbxasset://sounds/button.wav", volume = 0.35, pitch = 0.65, pitchVar = 0.05 },

	-- Creatures. A creature ON THE WATER makes no sound at all - no breach,
	-- no landing plop, no flop (user, 2026-08-22: "you don't need sfx for
	-- the fish on the water"; the splat it had "doesn't sound good"). Only
	-- the ground-side cues remain. splat.wav is used NOWHERE in this file now.
	landGround = {
		id = "rbxasset://sounds/action_jump_land.mp3",
		volume = 0.6,
		pitch = 0.85,
		pitchVar = 0.08,
		range = 70,
	},
	-- On land: the front of the character's swimming stroke, a soft wet
	-- flick rather than a splat (user, 2026-08-22: subtle). Only the first
	-- ~0.3 s is used - the rest of the clip is the stroke's tail.
	flopGround = {
		id = "rbxasset://sounds/action_swim.mp3",
		volume = 0.45,
		pitch = 1.3,
		pitchVar = 0.2,
		range = 60,
		maxDuration = 0.3,
	},

	-- Combat (CombatController / CombatVfxController). NO splat anywhere here
	-- (user, 2026-08-22: "remove the splat ... it should feel like i'm
	-- punching the fish"). A landed punch is TWO dry layers played together -
	-- a sharp crack for the contact and a deep thump for the body weight
	-- behind it - so it lands with impact instead of one thin tap. Both built
	-- on action_jump_land (the character-landing body thud), which is
	-- confirmed to load in this client - swoosh did not, which is why the
	-- swing was silent before.
	--
	-- The swing is 2D (the player's own arm); the hit layers are 3D at the
	-- contact point so everyone hears where it landed.
	punchSwing = { id = "rbxasset://sounds/action_jump_land.mp3", volume = 0.3, pitch = 2.1, pitchVar = 0.12 },
	-- A crafted weapon's swing (WeaponViewmodelController): same body, lower and heavier than a fist.
	weaponSwing = { id = "rbxasset://sounds/action_jump_land.mp3", volume = 0.35, pitch = 1.5, pitchVar = 0.1 },
	hitCrack = {
		id = "rbxasset://sounds/action_jump_land.mp3",
		volume = 0.6,
		pitch = 1.55,
		pitchVar = 0.1,
		range = 80,
	},
	hitThump = {
		id = "rbxasset://sounds/action_jump_land.mp3",
		volume = 0.65,
		pitch = 0.62,
		pitchVar = 0.06,
		range = 80,
	},
	killCrack = {
		id = "rbxasset://sounds/action_jump_land.mp3",
		volume = 0.7,
		pitch = 1.2,
		pitchVar = 0.08,
		range = 95,
	},
	-- The kill's low tail: a deep sub-boom, pitched right down and carrying
	-- far, staggered just behind killCrack (CombatVfxController) so a kill is
	-- CRACK -> BOOM - the finisher shape - not one flat stack.
	killThump = {
		id = "rbxasset://sounds/action_jump_land.mp3",
		volume = 0.95,
		pitch = 0.38,
		pitchVar = 0.04,
		range = 120,
	},

	-- Enemies (CreatureEventController). Built on the same handful of
	-- built-ins already proven to load in this client (swoosh.wav did not);
	-- each is a pitch/length of one of those. Replace with real recordings
	-- by swapping ids.
	dashWhoosh = {
		id = "rbxasset://sounds/action_swim.mp3",
		volume = 0.5,
		pitch = 1.7,
		pitchVar = 0.15,
		range = 60,
		maxDuration = 0.3,
	},
	dazed = { id = "rbxasset://sounds/button.wav", volume = 0.35, pitch = 0.55, pitchVar = 0.05, range = 50 },
	-- The cod's spit: a short wet heave on the way out (the front of the
	-- swim stroke, the same body as `burrow`), a plop in water, a dull thud
	-- on the ground. Used to be splat.wav both ends; the user cut that sound
	-- from the game (2026-08-22).
	spitLaunch = {
		id = "rbxasset://sounds/action_swim.mp3",
		volume = 0.45,
		pitch = 1.4,
		pitchVar = 0.15,
		range = 70,
		maxDuration = 0.25,
	},
	spitSplashWater = {
		id = "rbxasset://sounds/impact_water.mp3",
		volume = 0.5,
		pitch = 1.3,
		pitchVar = 0.1,
		range = 70,
	},
	spitSplashGround = {
		id = "rbxasset://sounds/action_jump_land.mp3",
		volume = 0.55,
		pitch = 0.9,
		pitchVar = 0.12,
		range = 70,
	},
	explodeCrack = {
		id = "rbxasset://sounds/action_jump_land.mp3",
		volume = 0.9,
		pitch = 1.3,
		pitchVar = 0.08,
		range = 140,
	},
	explodeBoom = {
		id = "rbxasset://sounds/action_jump_land.mp3",
		volume = 1.0,
		pitch = 0.3,
		pitchVar = 0.04,
		range = 180,
	},
	burrow = {
		id = "rbxasset://sounds/action_swim.mp3",
		volume = 0.45,
		pitch = 0.8,
		pitchVar = 0.1,
		range = 60,
		maxDuration = 0.35,
	},
	sandShift = {
		id = "rbxasset://sounds/action_swim.mp3",
		volume = 0.25,
		pitch = 0.6,
		pitchVar = 0.15,
		range = 45,
		maxDuration = 0.3,
	},
	emerge = { id = "rbxasset://sounds/action_jump_land.mp3", volume = 0.8, pitch = 0.7, pitchVar = 0.08, range = 100 },
	shellCreak = {
		id = "rbxasset://sounds/action_swim.mp3",
		volume = 0.4,
		pitch = 0.5,
		pitchVar = 0.1,
		range = 50,
		maxDuration = 0.4,
	},
	shellSnap = {
		id = "rbxasset://sounds/action_jump_land.mp3",
		volume = 0.8,
		pitch = 1.8,
		pitchVar = 0.08,
		range = 90,
	},
	coinSteal = { id = "rbxasset://sounds/button.wav", volume = 0.5, pitch = 1.5, pitchVar = 0.12, range = 60 },
	crackle = { id = "rbxasset://sounds/button.wav", volume = 0.2, pitch = 2.4, pitchVar = 0.35, range = 50 },
	pulseZap = { id = "rbxasset://sounds/action_jump_land.mp3", volume = 0.8, pitch = 2.4, pitchVar = 0.1, range = 110 },
	pulseThump = {
		id = "rbxasset://sounds/action_jump_land.mp3",
		volume = 0.8,
		pitch = 0.45,
		pitchVar = 0.05,
		range = 140,
	},

	-- Island bosses (BossHudController / CreatureEventController). The
	-- attacks are all dry, heavy layers of the proven built-ins - no splat
	-- anywhere (user, 2026-08-22: "find a new sound effect for the boss's
	-- attacks"). Each attack has its own voice so they read by ear:
	--   volley  bossSpit  - a deep wet heave per glob (swim stroke, pitched down)
	--   spines  bossSpine - a sharp dry "thk" per spine (jump-land, pitched up), bossSpineHit where it sticks
	--   globs landing on ground: bossGlobThud (a dull body thud); on water the plop (spitSplashWater)
	bossSpit = {
		id = "rbxasset://sounds/action_swim.mp3",
		volume = 0.7,
		pitch = 0.55,
		pitchVar = 0.1,
		range = 160,
		maxDuration = 0.4,
	},
	bossSpine = {
		id = "rbxasset://sounds/action_jump_land.mp3",
		volume = 0.5,
		pitch = 2.8,
		pitchVar = 0.15,
		range = 140,
	},
	bossSpineHit = {
		id = "rbxasset://sounds/action_jump_land.mp3",
		volume = 0.6,
		pitch = 1.9,
		pitchVar = 0.12,
		range = 120,
	},
	bossGlobThud = {
		id = "rbxasset://sounds/action_jump_land.mp3",
		volume = 0.7,
		pitch = 0.7,
		pitchVar = 0.1,
		range = 140,
	},
	bossRise = { id = "rbxasset://sounds/impact_water.mp3", volume = 1.0, pitch = 0.45, pitchVar = 0.03, range = 300 },
	bossRoar = {
		id = "rbxasset://sounds/action_jump_land.mp3",
		volume = 1.0,
		pitch = 0.22,
		pitchVar = 0.03,
		range = 300,
	},
	bossTell = { id = "rbxasset://sounds/button.wav", volume = 0.5, pitch = 0.5, pitchVar = 0.05, range = 160 },
	bossSnap = {
		id = "rbxasset://sounds/action_jump_land.mp3",
		volume = 0.9,
		pitch = 1.0,
		pitchVar = 0.06,
		range = 160,
	},
	bossSweep = {
		id = "rbxasset://sounds/action_swim.mp3",
		volume = 0.8,
		pitch = 0.6,
		pitchVar = 0.08,
		range = 160,
		maxDuration = 0.5,
	},
	bossSlam = {
		id = "rbxasset://sounds/action_jump_land.mp3",
		volume = 1.0,
		pitch = 0.3,
		pitchVar = 0.04,
		range = 240,
	},
	bossDown = { id = "rbxasset://sounds/impact_water.mp3", volume = 1.0, pitch = 0.35, pitchVar = 0.03, range = 300 },
}

-- Hard cap on how long a one-shot's carrier lives, in case TimeLength never
-- resolves (asset missing, still streaming).
local MAX_LIFETIME = 4

-- Fade length when a `maxDuration` cuts a clip short.
local FADE_OUT = 0.08

local folder: Folder? = nil

local function container(): Folder
	if not folder or not folder.Parent then
		local f = Instance.new("Folder")
		f.Name = "ClientSfx"
		f.Parent = Workspace
		folder = f
	end
	return folder :: Folder
end

local function makeSound(def, parent: Instance): Sound
	local sound = Instance.new("Sound")
	sound.SoundId = def.id
	sound.Volume = def.volume
	sound.PlaybackSpeed = def.pitch + (math.random() * 2 - 1) * (def.pitchVar or 0)
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = 6
	sound.RollOffMaxDistance = def.range or 60
	sound.Parent = parent
	return sound
end

-- Plays `name` once. With a `position` it's a 3D sound at that point;
-- without one it plays flat in the player's ears. Unknown names warn once
-- and do nothing, so a typo never breaks the thing that called it.
local warned = {}

function Sfx.play(name: string, position: Vector3?)
	local def = CATALOGUE[name]
	if not def then
		if not warned[name] then
			warned[name] = true
			warn(string.format("[Sfx] no sound named %q", name))
		end
		return
	end

	local carrier: Instance
	if position then
		local part = Instance.new("Part")
		part.Name = "Sfx_" .. name
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Transparency = 1
		part.Size = Vector3.new(0.2, 0.2, 0.2)
		part.CFrame = CFrame.new(position)
		part.Parent = container()
		carrier = part
	else
		-- A Sound parented to SoundService plays non-spatially.
		carrier = Instance.new("Folder")
		carrier.Name = "Sfx_" .. name
		carrier.Parent = SoundService
	end

	local sound = makeSound(def, carrier)
	sound:Play()

	-- Clean up after the clip; fall back to a cap if its length isn't known.
	local lifetime = MAX_LIFETIME
	if sound.IsLoaded and sound.TimeLength > 0 then
		lifetime = math.min(MAX_LIFETIME, sound.TimeLength / sound.PlaybackSpeed + 0.1)
	end

	-- Early cut: a quick fade so the stop doesn't click.
	if def.maxDuration and def.maxDuration < lifetime then
		lifetime = def.maxDuration + FADE_OUT + 0.1
		task.delay(def.maxDuration, function()
			if sound.Parent then
				TweenService:Create(sound, TweenInfo.new(FADE_OUT, Enum.EasingStyle.Linear), { Volume = 0 }):Play()
			end
		end)
	end

	Debris:AddItem(carrier, lifetime)
end

return Sfx
