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
-- One standing rule from the user (2026-08-22) survives: splat.wav is never
-- used, anywhere, for anything.
--
-- The OTHER standing rule from that day - "a creature on the water makes no
-- sound" - was REVERSED on 2026-09-09: the user asked for splashing and
-- flopping, so `fishSurface` and `flopWater` exist and CreatureVfxController
-- fires them. The rule that stood behind it is still worth knowing, because
-- it is why those two cues are quiet and short rather than the splat that got
-- them banned in the first place.
--
-- THE PACK. Everything in CATALOGUE below is a placeholder voiced out of four
-- Roblox built-ins. The real audio is generated (assets/audio_gen, contract in
-- assets/audio_gen/CONTRACT.md) and imported by hand as one Folder,
-- ReplicatedStorage/Assets/SoundPack. It is a HANDFUL OF BUNDLES rather than
-- 350 files because Roblox caps audio uploads per month at about a hundred and
-- a human has to click import once per file: a bundle is one long Sound with
-- many cues laid end to end (SFX categories are packed in turn into a couple of
-- `audio_sfx_N` bundles), and src/Shared/Config/SoundSprites.luau (GENERATED)
-- says which bundle a cue lives in - `cue.file` - plus where it starts and how
-- long it runs. `SoundSprites.files` is the exact set of Sound names the pack
-- must contain; anything missing from it simply has no sprite.
--
-- The pack is OPTIONAL AT EVERY POINT. SoundSprites ships empty until the
-- generator has run, the Folder may simply not be in the place, and in both
-- cases every path below falls through to the rbxasset `id` and the game is
-- exactly as audible as it was yesterday. A cue with no `id` at all is
-- SPRITE-ONLY: silent without the pack, deliberately.

local ContentProvider = game:GetService("ContentProvider")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SoundSprites = require(Shared.Config.SoundSprites)

-- The four built-ins proven to load in this client, aliased so the new blocks
-- at the bottom of the catalogue fit one entry per line. The rows above spell
-- the same four strings out longhand; nothing here is a new id.
local SWIM = "rbxasset://sounds/action_swim.mp3"
local LAND = "rbxasset://sounds/action_jump_land.mp3"
local WATER = "rbxasset://sounds/impact_water.mp3"
local CLICK = "rbxasset://sounds/button.wav"

-- Per-call overrides. Both numbers MULTIPLY the catalogue's values rather than
-- replacing them, so a caller scaling a creature's voice by its body size, or
-- a loop riding a throttle, keeps whatever mix balance the catalogue set.
-- `voice` picks a `<name>__<voice>` variant for this one call.
export type PlayOpts = { pitch: number?, volume: number?, voice: string? }

local Sfx = {}

-- name -> { id, volume, pitch, pitchVar, range, maxDuration, spriteVolume }
--   pitch       - base PlaybackSpeed, APPLIED TO THE rbxasset FALLBACK ONLY;
--                 a sprite off the pack plays at 1 (see makeSound)
--   pitchVar    - +/- random variation on top of it
--   range       - RollOffMaxDistance for 3D plays (ignored for 2D)
--   maxDuration - optional; fade out and stop after this many seconds, for
--                 using just the front of a longer built-in clip
--   spriteVolume- optional; the mix level to use when the cue comes off the
--                 pack, for a row whose `volume` was chosen to prop up a thin
--                 built-in rather than as this cue's place in the mix
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
	-- Ranged (RangedController / RangedFxController). Same dry-layer rule as
	-- the punches: a gunshot is the jump-land body thud pitched into a crack,
	-- a bow is the cast's swoosh with more snap. 2D for the shooter's own
	-- trigger; the tracer's impact reuses the existing hit cues.
	gunFire = { id = "rbxasset://sounds/action_jump_land.mp3", volume = 0.5, pitch = 1.9, pitchVar = 0.06 },
	bowFire = { id = "rbxasset://sounds/swoosh.wav", volume = 0.5, pitch = 1.3, pitchVar = 0.08 },
	gunReload = { id = "rbxasset://sounds/button.wav", volume = 0.4, pitch = 0.8, pitchVar = 0.05 },
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

	-- Brinejaw, the coil on the spire (CreatureEventController). Same dry
	-- rule as every other boss - no splat, nothing wet except the fall into
	-- the shallows at the end, which is the blessed exception the rise and
	-- fall already use. The fight is fought across a ~140-stud arena and the
	-- head perches ~60 studs up, so every one of these carries further than
	-- the ground-level cues: a sweep you can't hear coming is a sweep you
	-- can't read, and reading it is the whole dodge.
	--
	-- The two sweeps are ONE arm at two heights and have to be told apart by
	-- ear alone (low is jumped, high is stood under), so they're deliberately
	-- far apart in pitch rather than two shades of the same rush: the low one
	-- is dragged along the sand, the high one passes over your head.
	serpentSweepLow = {
		id = "rbxasset://sounds/action_swim.mp3",
		volume = 0.85,
		pitch = 0.45,
		pitchVar = 0.06,
		range = 170,
		maxDuration = 0.55,
	},
	serpentSweepHigh = {
		id = "rbxasset://sounds/action_swim.mp3",
		volume = 0.6,
		pitch = 1.05,
		pitchVar = 0.08,
		range = 170,
		maxDuration = 0.45,
	},
	-- The tail coming down. bossSlam is the whole body; this is the arm, so
	-- it's a shade tighter and higher than that one.
	serpentSlam = {
		id = "rbxasset://sounds/action_jump_land.mp3",
		volume = 1.0,
		pitch = 0.34,
		pitchVar = 0.04,
		range = 220,
	},
	-- The payoff: it loses its grip and sixty studs of head come down on the
	-- sand. The heaviest thing in the fight short of the death - deeper than
	-- the slam and it carries past the arena's edge, because everyone in the
	-- lair needs to know the window is open.
	bossStagger = {
		id = "rbxasset://sounds/action_jump_land.mp3",
		volume = 1.0,
		pitch = 0.26,
		pitchVar = 0.03,
		range = 260,
	},
	-- A stance change: the whole coil stack grinding one turn down the tower.
	-- Stone on stone, so it's the long low end of the swim stroke (the same
	-- body shellCreak strains on) rather than an impact - a grind has no
	-- transient, it just takes its time.
	bossStance = {
		id = "rbxasset://sounds/action_swim.mp3",
		volume = 0.75,
		pitch = 0.32,
		pitchVar = 0.05,
		range = 200,
		maxDuration = 0.9,
	},
	-- A reef stone spent: a dry crack, shellSnap's voice with the arena's
	-- reach behind it.
	reefShatter = {
		id = "rbxasset://sounds/action_jump_land.mp3",
		volume = 0.85,
		pitch = 1.65,
		pitchVar = 0.1,
		range = 170,
	},
	-- The death: it slides off the tower into the shallows. bossDown's body
	-- pitched lower still and left to ring out whole - the last sound of the
	-- island, and the one water cue the standing rule keeps.
	bossCollapse = {
		id = "rbxasset://sounds/impact_water.mp3",
		volume = 1.0,
		pitch = 0.28,
		pitchVar = 0.03,
		range = 300,
	},

	-- Noctyss and her Lantern Choir, the Gloomtrench fight (NoctyssBodyController
	-- / CreatureEventController). The arena is pitch black and seven angler
	-- lanterns are the only light in it, so this is the one fight fought by
	-- EAR - and that makes it the quietest block in the catalogue on purpose.
	-- Every other boss shouts; this one must not, because a player who can
	-- hear the choir comfortably from anywhere stops leaning in to find the
	-- true lure, and leaning in is the whole fight. Only the maw is allowed
	-- to be loud, and it earns that by being the punish window.
	--
	-- Same built-ins as everything above (swim / jump-land / impact_water /
	-- button are the four proven to load in this client) - these are voices
	-- of those, not new uploads. The two water cues are the blessed exception
	-- the boss rise and fall already use, not creature-on-water sounds.

	-- THE BREATH. One play per pulse cycle at a stalk's foot rather than a
	-- managed loop: the rhythm is already decided by NoctyssPath.pulse on
	-- both sides, so the caller owning the beat keeps sound and light in
	-- step for free, and a carrier per breath is cheaper than a loop that
	-- has to be started, tracked and killed when a lantern breaks.
	--
	-- Short range and almost no pitchVar, both load-bearing: a lantern
	-- audible from anywhere locates nothing, and six stalks breathing in
	-- unison have to sound like ONE tone - a sampler wobble would smear the
	-- very rhythm the player is trying to read.
	choirPulse = {
		id = "rbxasset://sounds/action_swim.mp3",
		volume = 0.12,
		pitch = 0.34,
		pitchVar = 0.015,
		range = 85,
		maxDuration = 0.9,
	},
	-- The true lure, findable by ear alone in full darkness: the same wet
	-- throat pitched well under the choir's and held longer, so it reads as
	-- a different thing breathing rather than the same thing standing
	-- nearer. Its half-cycle offset (NoctyssPath.TRUE_LURE_OFFSET) already
	-- puts it against the beat; this puts it in another register too, which
	-- is what makes the tell survive a strobewave or a room full of decoys.
	choirPulseTrue = {
		id = "rbxasset://sounds/action_swim.mp3",
		volume = 0.16,
		pitch = 0.25,
		pitchVar = 0.015,
		range = 95,
		maxDuration = 1.1,
	},
	-- LIGHTSWEEP (`choirBeam`): a stalk leans and drags its light across the
	-- shelf. This one breaks the quiet rule as far as REACH goes - it carries
	-- the length of the shelf while staying low in volume - because the beam
	-- comes from a lantern 35 studs up in a black room, and a sweep you only
	-- learn about by being lit is not a dodge. bossSweep's body pitched
	-- further down and stretched: this arm is enormous and slow, not a swing.
	-- Only the front of the stretch plays; the light itself is the rest.
	choirBeam = {
		id = "rbxasset://sounds/action_swim.mp3",
		volume = 0.4,
		pitch = 0.42,
		pitchVar = 0.04,
		range = 170,
		maxDuration = 1.3,
	},
	-- A lantern going out the hard way. The one sharp, dry transient in the
	-- fight, and the only sound the player CAUSES - it has to cut cleanly
	-- through all this low wet breathing or a good shot feels like nothing.
	-- reefShatter's crack, pitched up for glass and thrown from height.
	lanternBreak = {
		id = "rbxasset://sounds/action_jump_land.mp3",
		volume = 0.5,
		pitch = 2.2,
		pitchVar = 0.12,
		range = 150,
	},
	-- A FALSE lure breaking (`lureFlare`): it flares white and the trench
	-- answers. Deliberately the wrong note - the thin bright click of
	-- `crackle` where the fight has trained the ear to expect a low breath -
	-- so the mistake registers before the blast that follows it does. The
	-- damage is the moment's own `inkBlast` / `slam`; this is just the flash.
	lureFlare = { id = "rbxasset://sounds/button.wav", volume = 0.35, pitch = 2.6, pitchVar = 0.2, range = 150 },
	-- EVERY LANTERN AT ONCE (`choirDouse`). Nothing is visible for the next
	-- second and a half, so for that beat this sound IS the fight: the low
	-- swallow of the whole choir being taken away, arena-wide, left to ring
	-- out under the darkness instead of being cut short. impact_water at the
	-- bottom of its range - deeper than bossCollapse, and the only cue here
	-- with no competition, which is why it can be this quiet and still land.
	-- Its tail ends at MAX_LIFETIME, comfortably past `dousehunt`'s dark.
	choirDouse = {
		id = "rbxasset://sounds/impact_water.mp3",
		volume = 0.55,
		pitch = 0.2,
		pitchVar = 0.02,
		range = 320,
	},
	-- The maw coming up through the pit: the wet layer, meant to sit UNDER
	-- the `bossStagger` the open already plays, the way killCrack/killThump
	-- are one event in two voices. Trench water displaced by something the
	-- size of the arena floor - slower and deeper than bossRise, and heard
	-- everywhere, because the window opening is the news the party waits for.
	mawRise = {
		id = "rbxasset://sounds/impact_water.mp3",
		volume = 0.75,
		pitch = 0.3,
		pitchVar = 0.03,
		range = 320,
	},
	-- The jaw shutting. The dry impact is already there - the close fires the
	-- ordinary `slam` moment, which is bossSlam - so this is the other half:
	-- the wet, closing gulp over it. Layered that way the bite is a mouth
	-- rather than a rock landing, and if nothing ever wires this the bite is
	-- still audible, which is the safe way round for the fight's last beat.
	mawBite = {
		id = "rbxasset://sounds/action_swim.mp3",
		volume = 0.7,
		pitch = 0.3,
		pitchVar = 0.03,
		range = 260,
		maxDuration = 0.5,
	},

	-- THE THREE TENTACLE ATTACKS (NoctyssBodyController, off the ChoirAttack
	-- descriptor). The arena is pitch black and the camera is first person, so
	-- these are not decoration over a telegraph the player can already see -
	-- for a limb swinging in from behind, THE SOUND IS THE TELEGRAPH, and it
	-- has to say three things: which of the three moves this is, where it is
	-- coming from, and which beat of it you are on. So one voice per phase,
	-- each in a different register from the choir's low wet breathing, and all
	-- of them positional at the thing that is actually making the noise.
	--
	-- Same four built-ins as everything above - no new uploads, no new ids to
	-- fail to load in a room where a missing sound is a missing warning.
	--
	-- THE SLAM. Its tell is that the lantern goes OUT (NoctyssPath.SLAM), so
	-- the windup voice is the light dying: impact_water pitched up out of its
	-- splash into a sizzle, quiet and close, cut short so it FADES rather than
	-- ends. Heard once, it teaches "that stalk just went dark and is above me".
	slamSnuff = {
		id = "rbxasset://sounds/impact_water.mp3",
		volume = 0.3,
		pitch = 1.9,
		pitchVar = 0.06,
		range = 150,
		maxDuration = 0.6,
	},
	-- The limb landing across the stone. Wet and heavy rather than dry - a
	-- tentacle the size of a mast is tonnage with water in it, not a rock -
	-- and the loudest thing in this block by a distance, because it is the one
	-- moment that has already hurt you. Carries the whole shelf.
	slamImpact = {
		id = "rbxasset://sounds/impact_water.mp3",
		volume = 0.85,
		pitch = 0.42,
		pitchVar = 0.03,
		range = 300,
	},
	-- Peeling back up. Low, long and unhurried: the recover is the window the
	-- party moves in, so it wants a sound that says the beat is OVER and keeps
	-- saying it, not a transient that leaves silence to be read as safety.
	slamPeel = {
		id = "rbxasset://sounds/action_swim.mp3",
		volume = 0.4,
		pitch = 0.22,
		pitchVar = 0.02,
		range = 220,
		maxDuration = 1.2,
	},
	-- THE SCYTHE bowing down. jump_land dropped into a groan - the creak of
	-- something enormous taking a set before it moves. It is the only warning
	-- that arrives BEFORE the arc lights up, which is why it reaches further
	-- than its volume suggests.
	scytheCreak = {
		id = "rbxasset://sounds/action_jump_land.mp3",
		volume = 0.45,
		pitch = 0.45,
		pitchVar = 0.04,
		range = 200,
		maxDuration = 0.9,
	},
	-- The sweep itself, and the only LOOP in the fight (Sfx.loop): the eye
	-- drags along the stone for a second and a half and the sound has to be
	-- WHERE IT IS, continuously, or a player standing in the dark cannot tell
	-- an arc coming toward them from one going away. Held mid-register between
	-- the choir's breath and the break's crack so it never hides either.
	-- The caller owns it and must stop it - see Sfx.loop's note.
	scytheDrag = {
		id = "rbxasset://sounds/action_swim.mp3",
		volume = 0.45,
		pitch = 0.55,
		pitchVar = 0.03,
		range = 200,
	},
	-- THE JAB coiling. Short, thin and up top - a quick intake against the
	-- fight's low breathing, which is what makes a third of a second's warning
	-- enough to be worth having.
	jabCoil = {
		id = "rbxasset://sounds/action_swim.mp3",
		volume = 0.3,
		pitch = 1.5,
		pitchVar = 0.05,
		range = 140,
		maxDuration = 0.35,
	},
	-- The thrust. A whip-crack: the same dry transient `lanternBreak` uses,
	-- pitched apart from it so a spear arriving and a lantern breaking can
	-- never be confused - one is the boss hitting you, the other is you
	-- hitting the boss, and they must not share a sound.
	jabCrack = {
		id = "rbxasset://sounds/action_jump_land.mp3",
		volume = 0.55,
		pitch = 2.6,
		pitchVar = 0.1,
		range = 200,
	},

	-- Rimefang, the Floe-Breaker (CreatureEventController). A killer whale the
	-- size of a ship, fought on a floating floe, and the only boss so far that
	-- spends most of the fight WHERE YOU CANNOT SEE IT - under the sheet. That
	-- makes this block do more work than the others: for long stretches the
	-- sound is the only thing that says where the animal is and what it is
	-- about to do, so every cue below carries the full width of the floe.
	--
	-- Same four proven built-ins as everything above (swim / jump-land /
	-- impact_water / button), pitched and stretched into voices - no uploads.
	--
	-- THE WET EXCEPTION, carefully. The standing rule is that creatures on the
	-- water are silent and water cues are the bobber, the tug, and a boss's
	-- rise and fall. Rimefang is a whale: the spout and the breach ARE its rise
	-- and fall, so they keep impact_water - but they are pitched to the bottom
	-- of it, where the clip reads as displaced tonnage rather than a splash.
	-- Nothing here is a splat and nothing here is bright; the register of this
	-- whole fight is LOW, which is also why the ice cracks read at all.

	-- THE SPOUT. It surfaces somewhere on the ring and breathes out. A wet
	-- exhale, not a jet: the swim stroke's body opened up, one register above
	-- the fight's floor so it cuts through without ever being loud. This is
	-- the fight's locator - most players will hear it before they turn - so it
	-- carries far and wobbles a little, because a spout is a breath and two of
	-- them in a row should not sound identical.
	rimeSpout = {
		id = "rbxasset://sounds/action_swim.mp3",
		volume = 0.6,
		pitch = 0.95,
		pitchVar = 0.14,
		range = 260,
		maxDuration = 0.45,
	},
	-- THE WAVE WASH, the signature. An orca shoulders a wall of water across
	-- the floe and the seal is not bitten, it is washed off - so this is a
	-- LONG low rush with no transient at all, the same trick choirBeam uses
	-- and stretched further: water shouldering across ice takes its time and
	-- announces itself the whole way. The answer to the wash is cover, which
	-- means the read has to start during the windup and finish before it
	-- lands, so this is deliberately the longest cue in the catalogue and
	-- reaches past the arena's edge. Fire it on the windup, not the hit.
	rimeWash = {
		id = "rbxasset://sounds/action_swim.mp3",
		volume = 0.9,
		pitch = 0.26,
		pitchVar = 0.03,
		range = 300,
		maxDuration = 1.8,
	},
	-- THE BREACH, part one: it leaves the water. The blessed rise cue, deeper
	-- and heavier than bossRise because this is a ship-sized body clearing the
	-- sheet rather than a head coming up - the sound of the sea letting go of
	-- something. Everyone hears it, because what follows is the biggest hit in
	-- the fight and the whole floe should have a beat to get out from under it.
	rimeBreachLaunch = {
		id = "rbxasset://sounds/impact_water.mp3",
		volume = 1.0,
		pitch = 0.32,
		pitchVar = 0.03,
		range = 320,
	},
	-- THE BREACH, part two: it lands FLAT on the floe. The biggest sound in
	-- the fight and the lowest thing in this file after choirDouse - under
	-- bossSlam, under bossStagger, left to ring out whole. It is the punish
	-- window opening, so it is arena-wide by design: nobody should have to be
	-- looking at the boss to know the four seconds have started.
	rimeBreachCrash = {
		id = "rbxasset://sounds/action_jump_land.mp3",
		volume = 1.0,
		pitch = 0.2,
		pitchVar = 0.02,
		range = 340,
	},
	-- The crash's top layer, staggered just ahead of it the way killCrack sits
	-- ahead of killThump: the sheet splitting under the landing. reefShatter's
	-- dry crack pitched up for ice and thrown the width of the floe, so the
	-- breach reads as CRACK -> BOOM - something breaking, then something
	-- enormous arriving - instead of one flat wall of low end. Optional: the
	-- crash alone is complete without it.
	rimeFloeCrack = {
		id = "rbxasset://sounds/action_jump_land.mp3",
		volume = 0.7,
		pitch = 2.0,
		pitchVar = 0.14,
		range = 260,
	},
	-- BEACHED. Four seconds of a ship-sized animal wallowing on ice, working
	-- itself back to water. Not a managed loop - one play per beat at the
	-- body, the way choirPulse lets the caller own the rhythm - so fire it
	-- three or four times across the window and let the wobble do the rest.
	-- The heaviest pitchVar in the catalogue, on purpose: a thrash that
	-- repeats identically is a sampler, and this one has to sound like
	-- something struggling. Mid-range only - the window is a place you have to
	-- BE, so it should get louder by walking to it.
	rimeThrash = {
		id = "rbxasset://sounds/action_swim.mp3",
		volume = 0.6,
		pitch = 0.4,
		pitchVar = 0.22,
		range = 180,
		maxDuration = 0.8,
	},
	-- FLUKE SLAM: the tail comes up through a hole beside you and hammers
	-- down. Heavy and percussive, but a limb rather than the whole animal -
	-- so it sits between serpentSlam and the breach crash, tighter and a shade
	-- brighter than either, which is what keeps it from being mistaken for the
	-- breach when both are behind you.
	rimeFlukeSlam = {
		id = "rbxasset://sounds/action_jump_land.mp3",
		volume = 1.0,
		pitch = 0.44,
		pitchVar = 0.04,
		range = 240,
	},
	-- SPY-HOP: it stands up out of the water and picks someone. The one beat
	-- in the fight where nothing is coming, so it is the one cue here allowed
	-- to be bright and short - water shedding off a flank, high against a
	-- fight pitched to the floor. A one-shot cannot literally sweep upward, so
	-- the rise is carried by register: after a minute of sub-bass, anything
	-- this far up reads as something standing. Wide reach because the mark is
	-- party information - everyone needs to look.
	rimeSpyHop = {
		id = "rbxasset://sounds/action_swim.mp3",
		volume = 0.5,
		pitch = 1.45,
		pitchVar = 0.1,
		range = 240,
		maxDuration = 0.35,
	},
	-- WHITEOUT, phase three: the storm closes. A wind bed, not an event -
	-- quiet, wide, and long, meant to be re-fired for as long as the storm
	-- stands rather than played once. The swim stroke stretched into a hiss
	-- with the transient buried; it has to sit UNDER the barrage's strikes
	-- without competing, because the strikes are the thing you dodge and the
	-- wind is only the reason you can't see them coming.
	rimeWhiteout = {
		id = "rbxasset://sounds/action_swim.mp3",
		volume = 0.3,
		pitch = 0.72,
		pitchVar = 0.06,
		range = 380,
		maxDuration = 2.2,
	},
	-- ------------------------------------------------------ the new kit
	--
	-- Seven cues for the three attacks that land ON THE PLAYER'S GROUND: the
	-- eruption up through the ice, the body-slam down out of the sky, and the
	-- lane that heaves. They are pitched into the same LOW register as
	-- everything above - this fight has one voice and it is the bottom of the
	-- catalogue - and they lean harder than usual on sound doing the warning,
	-- because for the whole windup of two of them the animal is somewhere the
	-- player cannot look: eighteen studs under the sheet, or seventy above it.
	--
	-- Placeholders on the same four built-ins as the rest of the block. The
	-- names are the contract with the audio pass: they will not move.

	-- THE CRACK WEB. Continuous, while it travels under the ice toward you -
	-- fired on a beat rather than looped, the way rimeThrash is, so the
	-- caller owns the rhythm. Sea ice under strain GROANS before it splits,
	-- and this is that: the jump-land transient pitched down until the attack
	-- is gone and only the body of it is left. Mid-range on purpose - it is
	-- the sound of something UNDER you, and it should get worse as it closes.
	rimeCrackWeb = {
		id = "rbxasset://sounds/action_jump_land.mp3",
		volume = 0.45,
		pitch = 0.55,
		pitchVar = 0.18,
		range = 180,
		maxDuration = 0.7,
	},
	-- THE LOCK. The instant the target stops tracking and the ground is
	-- chosen: one dry snap of ice giving up, bright against the groan it
	-- interrupts, and short. This is the "MOVE" beat for both of the new
	-- attacks, so it is deliberately the most transient thing in the block -
	-- nothing else here has an attack this fast, which is what makes it
	-- impossible to mistake for the weather.
	rimeCrackLock = {
		id = "rbxasset://sounds/action_jump_land.mp3",
		volume = 0.75,
		pitch = 2.4,
		pitchVar = 0.08,
		range = 240,
		maxDuration = 0.3,
	},
	-- THE ERUPTION. It comes UP through the sheet. Not a landing and not a
	-- splash: the sound of ice being opened from underneath by something that
	-- weighs more than the ice does, so it is impact_water at the bottom of
	-- its range with the whole tail left on. Arena-wide, because it can go off
	-- anywhere on the floe and everyone needs the beat.
	rimeIceBurst = {
		id = "rbxasset://sounds/impact_water.mp3",
		volume = 1.0,
		pitch = 0.3,
		pitchVar = 0.03,
		range = 320,
	},
	-- SKYFALL, part one: seventy studs of launch. The sea letting go of
	-- something, pitched just above the eruption so the two are never the same
	-- event, and thrown further than anything else in the fight - this is the
	-- cue that makes players LOOK UP, and a player who does not look up does
	-- not see the shadow.
	rimeSkyLaunch = {
		id = "rbxasset://sounds/impact_water.mp3",
		volume = 1.0,
		pitch = 0.38,
		pitchVar = 0.03,
		range = 360,
	},
	-- SKYFALL, part two: it arrives. The biggest sound in the fight and the
	-- lowest thing in this file after choirDouse - under bossSlam, under
	-- bossStagger, left to ring out whole. It is also the long punish window
	-- opening, so it is arena-wide by design: nobody should have to be looking
	-- at the boss to know the three and a half seconds have started.
	rimeSkyImpact = {
		id = "rbxasset://sounds/action_jump_land.mp3",
		volume = 1.0,
		pitch = 0.18,
		pitchVar = 0.02,
		range = 360,
	},
	-- THE SHOCKWAVE off the slam. A rush leaving the impact - no transient of
	-- its own (the impact already spent it) and rising slightly in the mix as
	-- it goes, which is the only way a one-shot can say "this is still
	-- coming". Fired WITH the ring, not with the damage: the whole answer is
	-- to outrun it, and a cue that arrives when it hits you is not a warning.
	rimeShock = {
		id = "rbxasset://sounds/action_swim.mp3",
		volume = 0.7,
		pitch = 0.34,
		pitchVar = 0.04,
		range = 300,
		maxDuration = 1.0,
	},
	-- THE FLOEQUAKE. Sixty studs of sheet heaving at once - the widest single
	-- piece of ground the fight ever moves, and the cue is broad and blunt to
	-- match: the crack pitched into the floor and stretched, more rumble than
	-- report. It never has to compete with anything (the lane is the only
	-- thing happening) so it can afford to be slow.
	rimeQuake = {
		id = "rbxasset://sounds/action_jump_land.mp3",
		volume = 0.85,
		pitch = 0.26,
		pitchVar = 0.05,
		range = 300,
		maxDuration = 1.2,
	},

	-- THE DEATH: it goes back down through its own broken sheet for the last
	-- time. bossCollapse's body pitched lower still and left to ring out whole
	-- - the fall the standing rule keeps, and the last sound on the ice.
	rimeDeath = {
		id = "rbxasset://sounds/impact_water.mp3",
		volume = 1.0,
		pitch = 0.24,
		pitchVar = 0.02,
		range = 340,
	},

	-- PHASE TWO OPENS with the floe failing under it: one long structural
	-- crack and the collapse behind it, reaching further than anything else on
	-- the ice because the whole arena is what broke.
	rimeShatter = {
		id = "rbxasset://sounds/action_jump_land.mp3",
		volume = 1.0,
		pitch = 0.3,
		pitchVar = 0.03,
		range = 320,
	},

	-- The roar at half health. Same body as the quake, held rather than
	-- clipped: an enrage is the animal, not the ice.
	rimeEnrage = {
		id = "rbxasset://sounds/action_jump_land.mp3",
		volume = 1.0,
		pitch = 0.3,
		pitchVar = 0.04,
		range = 300,
	},

	-- An open rift in the ice, heard from beside it. A LOOP, and quiet and
	-- close on purpose: it marks a hole you can fall into, so it has to be
	-- audible at its edge and inaudible from across the floe.
	rimeRiftAmbient = {
		id = "rbxasset://sounds/action_swim.mp3",
		volume = 0.3,
		pitch = 0.45,
		pitchVar = 0.03,
		range = 90,
		maxDuration = 0.8,
	},
}

-- ========================================================== THE PACK KIT
--
-- Every cue the audio contract names (assets/audio_gen/CONTRACT.md §3) that
-- the placeholder catalogue above did not already carry. Appended as its own
-- table and merged below, never edited into the rows above.
--
-- An entry with NO `id` is SPRITE-ONLY: silent until the pack is imported.
-- That is used where no built-in is a defensible stand-in - the music
-- stingers, the sixty family voices, the low-health heartbeat - on the
-- principle that a wrong sound teaches the player a wrong thing and silence
-- teaches nothing, and while the renders are being made the second is safer.
local PACK_CATALOGUE = {
	-- ------------------------------------------------------------ fishing
	lineWhizz = { id = SWIM, volume = 0.35, pitch = 2.2, pitchVar = 0.1, maxDuration = 0.3 },
	bobberBob = { id = WATER, volume = 0.18, pitch = 0.9, pitchVar = 0.05, range = 45 },
	reelOpen = { id = CLICK, volume = 0.4, pitch = 1.4, pitchVar = 0.06 },
	reelTension = { id = CLICK, volume = 0.22, pitch = 0.9, pitchVar = 0.03 },
	reelZoneShrink = { id = CLICK, volume = 0.3, pitch = 1.9, pitchVar = 0.05 },
	burstOpen = { id = CLICK, volume = 0.4, pitch = 1.2, pitchVar = 0.04 },
	burstTap = { id = CLICK, volume = 0.35, pitch = 1.7, pitchVar = 0.12 },
	burstFill = { id = CLICK, volume = 0.45, pitch = 2.2, pitchVar = 0.05 },
	burstFail = { id = CLICK, volume = 0.4, pitch = 0.6, pitchVar = 0.04 },
	snapAppear = { id = CLICK, volume = 0.35, pitch = 2.0, pitchVar = 0.05 },
	snapHit = { id = LAND, volume = 0.45, pitch = 1.8, pitchVar = 0.08 },
	snapMiss = { id = CLICK, volume = 0.35, pitch = 0.55, pitchVar = 0.04 },
	-- The reveal ladder. The placeholders can only climb in PITCH, which is
	-- the one axis a single click has - the pack turns this into a two-note
	-- plink at the bottom and a two-second fanfare at the top.
	catchCommon = { id = CLICK, volume = 0.4, pitch = 1.6, pitchVar = 0.03 },
	catchUncommon = { id = CLICK, volume = 0.45, pitch = 1.8, pitchVar = 0.03 },
	catchRare = { id = CLICK, volume = 0.5, pitch = 2.0, pitchVar = 0.03 },
	catchEpic = { id = CLICK, volume = 0.55, pitch = 2.3, pitchVar = 0.03 },
	catchLegendary = { id = CLICK, volume = 0.6, pitch = 2.6, pitchVar = 0.02 },
	catchBoss = { id = WATER, volume = 0.9, pitch = 0.35, pitchVar = 0.03, range = 200 },
	salvageHaul = { id = LAND, volume = 0.6, pitch = 0.75, pitchVar = 0.08 },
	castRefused = { id = CLICK, volume = 0.3, pitch = 0.5, pitchVar = 0.03 },
	castCancel = { id = SWIM, volume = 0.35, pitch = 1.8, pitchVar = 0.1, maxDuration = 0.35 },
	-- The reversal of the 2026-08-22 water rule. Kept quiet and short: the
	-- rule existed because the old splat was neither.
	fishSurface = { id = WATER, volume = 0.5, pitch = 1.1, pitchVar = 0.12, range = 90 },
	flopWater = { id = WATER, volume = 0.35, pitch = 1.5, pitchVar = 0.2, range = 70 },

	-- --------------------------------------------------------------- boat
	boatSummon = { id = WATER, volume = 0.5, pitch = 0.8, pitchVar = 0.05 },
	boatArrive = { id = WATER, volume = 0.6, pitch = 0.6, pitchVar = 0.05, range = 120 },
	boatBoard = { id = LAND, volume = 0.45, pitch = 1.0, pitchVar = 0.08 },
	boatLeave = { id = LAND, volume = 0.4, pitch = 1.15, pitchVar = 0.08 },
	-- The two driving loops. Almost no pitchVar on either: they are ridden by
	-- setLoopPitch / setLoopVolume from the throttle and the speed, and a
	-- random wobble underneath that would read as the engine misfiring.
	boatEngine = { id = SWIM, volume = 0.3, pitch = 0.7, pitchVar = 0.02, range = 120 },
	boatWash = { id = WATER, volume = 0.25, pitch = 0.7, pitchVar = 0.02, range = 140 },
	boatCreak = { id = SWIM, volume = 0.35, pitch = 0.45, pitchVar = 0.08, range = 90, maxDuration = 0.6 },
	boatHit = { id = LAND, volume = 0.7, pitch = 0.55, pitchVar = 0.06, range = 140 },
	boatWarn = { id = CLICK, volume = 0.5, pitch = 1.1, pitchVar = 0.02 },
	boatSink = { id = WATER, volume = 0.8, pitch = 0.3, pitchVar = 0.03 },
	boatUpgrade = { id = LAND, volume = 0.5, pitch = 1.6, pitchVar = 0.1 },

	-- ---------------------------------------------------------- character
	-- Footsteps are built by the loop below, not listed here.
	jump = { id = SWIM, volume = 0.3, pitch = 1.8, pitchVar = 0.08, range = 50, maxDuration = 0.25 },
	land = { id = LAND, volume = 0.4, pitch = 1.1, pitchVar = 0.08, range = 60 },
	swimStroke = { id = SWIM, volume = 0.3, pitch = 1.0, pitchVar = 0.12, range = 60, maxDuration = 0.5 },
	waterEnter = { id = WATER, volume = 0.55, pitch = 1.0, pitchVar = 0.08, range = 80 },
	waterExit = { id = WATER, volume = 0.4, pitch = 1.3, pitchVar = 0.08, range = 70 },
	hurt = { id = LAND, volume = 0.4, pitch = 1.7, pitchVar = 0.1 },
	hurtHeavy = { id = LAND, volume = 0.6, pitch = 0.9, pitchVar = 0.06 },
	-- SPRITE-ONLY, and the clearest case for it in the file: a heartbeat is a
	-- rhythm, and a built-in body thud held on a loop is a drone. Better to
	-- hear nothing at low health than to hear the wrong thing continuously.
	lowHealth = { volume = 0.35, pitch = 1, pitchVar = 0.02 },
	death = { id = LAND, volume = 0.7, pitch = 0.3, pitchVar = 0.03 },
	respawn = { id = CLICK, volume = 0.4, pitch = 1.5, pitchVar = 0.03 },
	chilled = { id = CLICK, volume = 0.3, pitch = 2.6, pitchVar = 0.25 },
	knockback = { id = LAND, volume = 0.55, pitch = 0.65, pitchVar = 0.08 },

	-- ------------------------------------------------------------- combat
	swingRefused = { id = CLICK, volume = 0.3, pitch = 0.6, pitchVar = 0.04 },
	-- Other players' shots. Positional and reaching much further than the
	-- shooter's own 2D trigger, because on a raid island where the shot came
	-- from is the information.
	gunFireRemote = { id = LAND, volume = 0.6, pitch = 1.9, pitchVar = 0.06, range = 200 },
	bowFireRemote = { id = SWIM, volume = 0.5, pitch = 1.3, pitchVar = 0.08, range = 140, maxDuration = 0.3 },
	gunReady = { id = CLICK, volume = 0.35, pitch = 1.8, pitchVar = 0.04 },
	dryFire = { id = CLICK, volume = 0.35, pitch = 1.2, pitchVar = 0.04 },
	renock = { id = CLICK, volume = 0.3, pitch = 1.6, pitchVar = 0.06 },
	zoomIn = { id = CLICK, volume = 0.22, pitch = 2.2, pitchVar = 0.03 },
	zoomOut = { id = CLICK, volume = 0.22, pitch = 1.8, pitchVar = 0.03 },
	bulletImpact = { id = LAND, volume = 0.45, pitch = 2.0, pitchVar = 0.12, range = 90 },
	bulletWhiz = { id = SWIM, volume = 0.3, pitch = 2.6, pitchVar = 0.15, range = 50, maxDuration = 0.2 },

	-- ----------------------------------------------------------------- ui
	-- All 2D and all quiet. The UI fires more often than anything else in the
	-- game, so the ceiling here is deliberately half what a world cue gets.
	uiClick = { id = CLICK, volume = 0.3, pitch = 1.5, pitchVar = 0.03 },
	uiHover = { id = CLICK, volume = 0.12, pitch = 2.2, pitchVar = 0.03 },
	uiOpen = { id = CLICK, volume = 0.3, pitch = 1.1, pitchVar = 0.02 },
	uiClose = { id = CLICK, volume = 0.28, pitch = 0.9, pitchVar = 0.02 },
	uiTab = { id = CLICK, volume = 0.25, pitch = 1.8, pitchVar = 0.03 },
	uiSelect = { id = CLICK, volume = 0.25, pitch = 2.0, pitchVar = 0.03 },
	uiEquip = { id = CLICK, volume = 0.35, pitch = 1.3, pitchVar = 0.03 },
	uiError = { id = CLICK, volume = 0.35, pitch = 0.5, pitchVar = 0.02 },
	craftSuccess = { id = CLICK, volume = 0.45, pitch = 2.1, pitchVar = 0.03 },
	craftFail = { id = CLICK, volume = 0.35, pitch = 0.55, pitchVar = 0.03 },
	shopBuy = { id = CLICK, volume = 0.4, pitch = 1.9, pitchVar = 0.04 },
	shopFail = { id = CLICK, volume = 0.35, pitch = 0.6, pitchVar = 0.03 },
	baitCycle = { id = CLICK, volume = 0.28, pitch = 1.7, pitchVar = 0.05 },
	cursorFree = { id = CLICK, volume = 0.2, pitch = 1.4, pitchVar = 0.02 },
	cursorLock = { id = CLICK, volume = 0.2, pitch = 1.0, pitchVar = 0.02 },
	notify = { id = CLICK, volume = 0.35, pitch = 1.6, pitchVar = 0.03 },
	dialogOpen = { id = CLICK, volume = 0.3, pitch = 1.2, pitchVar = 0.02 },
	-- One per revealed line of a typewriter, so it is the quietest entry in
	-- the file and carries the most pitchVar: identical blips at speed read as
	-- a buzzer, and a wobble is what turns them back into a voice.
	dialogBlip = { id = CLICK, volume = 0.1, pitch = 2.4, pitchVar = 0.12 },
	dialogChoice = { id = CLICK, volume = 0.25, pitch = 1.9, pitchVar = 0.03 },
	dialogClose = { id = CLICK, volume = 0.25, pitch = 0.95, pitchVar = 0.02 },

	-- -------------------------------------------------------- progression
	coinGain = { id = CLICK, volume = 0.3, pitch = 2.3, pitchVar = 0.08 },
	xpGain = { id = CLICK, volume = 0.22, pitch = 2.6, pitchVar = 0.06 },
	levelUp = { id = CLICK, volume = 0.5, pitch = 1.4, pitchVar = 0.02 },
	materialGain = { id = CLICK, volume = 0.25, pitch = 1.8, pitchVar = 0.08 },
	baitGain = { id = CLICK, volume = 0.25, pitch = 2.0, pitchVar = 0.08 },
	itemDrop = { id = CLICK, volume = 0.4, pitch = 2.5, pitchVar = 0.04 },
	newSpecies = { id = CLICK, volume = 0.45, pitch = 2.2, pitchVar = 0.03 },
	collectionComplete = { id = CLICK, volume = 0.5, pitch = 1.7, pitchVar = 0.02 },
	questTick = { id = CLICK, volume = 0.22, pitch = 2.1, pitchVar = 0.04 },
	questReady = { id = CLICK, volume = 0.35, pitch = 1.9, pitchVar = 0.03 },
	questAccept = { id = CLICK, volume = 0.35, pitch = 1.5, pitchVar = 0.03 },
	questComplete = { id = CLICK, volume = 0.45, pitch = 1.8, pitchVar = 0.02 },
	islandUnlock = { id = CLICK, volume = 0.55, pitch = 1.2, pitchVar = 0.02 },
	heartsAll = { id = CLICK, volume = 0.6, pitch = 1.0, pitchVar = 0.02 },
	travelGo = { id = WATER, volume = 0.4, pitch = 1.2, pitchVar = 0.05 },
	travelArrive = { id = WATER, volume = 0.4, pitch = 0.9, pitchVar = 0.05 },
	travelRefused = { id = CLICK, volume = 0.3, pitch = 0.55, pitchVar = 0.03 },
	raidStart = { id = LAND, volume = 0.6, pitch = 0.6, pitchVar = 0.03 },
	raidWave = { id = LAND, volume = 0.5, pitch = 0.85, pitchVar = 0.04 },
	raidClear = { id = CLICK, volume = 0.5, pitch = 1.9, pitchVar = 0.02 },
	raidFail = { id = LAND, volume = 0.5, pitch = 0.4, pitchVar = 0.03 },
	-- The three music stingers USED to have rows here so a call for one was
	-- silent rather than a warning. They are gone: they are regions of a music
	-- bundle, they are never in SoundSprites.cues, and MusicController
	-- plays them off SoundSprites.music itself - so nothing routes a
	-- stinger through this table any more and a row here could only be dead.

	-- -------------------------------------------------------------- world
	-- WeatherController is locked, so thunder and the lamp are fired from
	-- MusicController's resolver instead - same second, same mode read.
	thunder = { id = LAND, volume = 0.8, pitch = 0.28, pitchVar = 0.12 },
	lampOn = { id = CLICK, volume = 0.25, pitch = 1.3, pitchVar = 0.04 },
	lampOff = { id = CLICK, volume = 0.22, pitch = 1.0, pitchVar = 0.04 },
	lavaBurst = { id = LAND, volume = 0.6, pitch = 0.5, pitchVar = 0.12, range = 120 },
	lavaBubble = { id = SWIM, volume = 0.2, pitch = 0.4, pitchVar = 0.05, range = 70 },
	whirlpool = { id = SWIM, volume = 0.3, pitch = 0.35, pitchVar = 0.02, range = 220 },
	bellToll = { id = CLICK, volume = 0.5, pitch = 0.7, pitchVar = 0.03, range = 200 },
	iceCreak = { id = SWIM, volume = 0.35, pitch = 0.5, pitchVar = 0.1, range = 120, maxDuration = 0.8 },
	gullCry = { id = CLICK, volume = 0.25, pitch = 2.5, pitchVar = 0.2, range = 150 },
	windGust = { id = SWIM, volume = 0.25, pitch = 0.8, pitchVar = 0.1, maxDuration = 1.5 },

	-- -------------------------------------- creature behaviours (generic)
	gasHiss = { id = SWIM, volume = 0.3, pitch = 1.9, pitchVar = 0.05, range = 70 },
	inkBlast = { id = WATER, volume = 0.55, pitch = 0.6, pitchVar = 0.08, range = 110 },
	splashRing = { id = WATER, volume = 0.45, pitch = 0.85, pitchVar = 0.08, range = 120 },
	spineStick = { id = LAND, volume = 0.45, pitch = 2.2, pitchVar = 0.12, range = 80 },
	chillTick = { id = CLICK, volume = 0.2, pitch = 2.8, pitchVar = 0.2, range = 60 },
	rebornRise = { id = WATER, volume = 0.6, pitch = 0.5, pitchVar = 0.05, range = 140 },
	phantomOut = { id = SWIM, volume = 0.35, pitch = 1.6, pitchVar = 0.08, range = 90, maxDuration = 0.4 },
	phantomIn = { id = SWIM, volume = 0.35, pitch = 1.2, pitchVar = 0.08, range = 90, maxDuration = 0.4 },
	snareSnap = { id = LAND, volume = 0.55, pitch = 2.0, pitchVar = 0.1, range = 100 },
	chainRattle = { id = CLICK, volume = 0.3, pitch = 1.6, pitchVar = 0.3, range = 90 },
	decoyPop = { id = CLICK, volume = 0.35, pitch = 2.4, pitchVar = 0.12, range = 90 },
	beamHum = { id = SWIM, volume = 0.25, pitch = 0.9, pitchVar = 0.02, range = 140 },
	poolSpawn = { id = WATER, volume = 0.4, pitch = 0.7, pitchVar = 0.08, range = 110 },

	-- ------------------------------------------- Brinejaw, the rest of it
	serpentWave = { id = WATER, volume = 0.8, pitch = 0.4, pitchVar = 0.04, range = 260, maxDuration = 1.2 },
	serpentRain = { id = WATER, volume = 0.5, pitch = 1.2, pitchVar = 0.15, range = 200 },
	serpentRings = { id = WATER, volume = 0.6, pitch = 0.7, pitchVar = 0.06, range = 240 },
	serpentSurge = { id = SWIM, volume = 0.75, pitch = 0.38, pitchVar = 0.04, range = 260, maxDuration = 1.0 },
	serpentPolyps = { id = SWIM, volume = 0.45, pitch = 0.9, pitchVar = 0.1, range = 160, maxDuration = 0.6 },
	polypBurst = { id = LAND, volume = 0.6, pitch = 1.7, pitchVar = 0.12, range = 140 },
	polypHeal = { id = CLICK, volume = 0.35, pitch = 2.2, pitchVar = 0.06, range = 140 },
	serpentGeysers = { id = WATER, volume = 0.7, pitch = 0.55, pitchVar = 0.08, range = 240 },
	serpentSpines = { id = LAND, volume = 0.5, pitch = 2.7, pitchVar = 0.14, range = 180 },
	serpentCoilslam = { id = LAND, volume = 1.0, pitch = 0.32, pitchVar = 0.04, range = 240 },
	serpentBite = { id = LAND, volume = 0.85, pitch = 0.95, pitchVar = 0.06, range = 200 },
	belltoll = { id = CLICK, volume = 0.55, pitch = 0.6, pitchVar = 0.02, range = 260 },
	lungeRoar = { id = LAND, volume = 0.95, pitch = 0.24, pitchVar = 0.03, range = 280 },
	undertowPull = { id = SWIM, volume = 0.6, pitch = 0.3, pitchVar = 0.03, range = 240, maxDuration = 1.4 },
	spiralWind = { id = SWIM, volume = 0.45, pitch = 0.6, pitchVar = 0.06, range = 260, maxDuration = 1.6 },
	comboWarn = { id = CLICK, volume = 0.5, pitch = 0.55, pitchVar = 0.03, range = 200 },

	-- ------------------------------------------------ Pyrelisk, Ashfall
	pyreHandfall = { id = LAND, volume = 1.0, pitch = 0.3, pitchVar = 0.04, range = 260 },
	pyreRimsweep = { id = SWIM, volume = 0.8, pitch = 0.5, pitchVar = 0.06, range = 240, maxDuration = 0.9 },
	pyreVentbreath = { id = SWIM, volume = 0.3, pitch = 0.45, pitchVar = 0.03, range = 180 },
	pyreAshfall = { id = SWIM, volume = 0.35, pitch = 1.4, pitchVar = 0.12, range = 200, maxDuration = 1.2 },
	pyreShardhurl = { id = SWIM, volume = 0.55, pitch = 1.5, pitchVar = 0.1, range = 200, maxDuration = 0.4 },
	pyreShardHit = { id = LAND, volume = 0.65, pitch = 1.9, pitchVar = 0.12, range = 160 },
	pyreStep = { id = LAND, volume = 0.9, pitch = 0.36, pitchVar = 0.04, range = 240 },
	pyreRoar = { id = LAND, volume = 1.0, pitch = 0.2, pitchVar = 0.03, range = 300 },
	pyreCrustCrack = { id = LAND, volume = 0.7, pitch = 1.8, pitchVar = 0.12, range = 200 },
	pyreDeath = { id = LAND, volume = 1.0, pitch = 0.22, pitchVar = 0.02, range = 320 },

	-- ------------------------------------------- Old Gnashroot, the Fen
	gnashBite = { id = LAND, volume = 0.85, pitch = 0.85, pitchVar = 0.06, range = 200 },
	gnashWallow = { id = SWIM, volume = 0.6, pitch = 0.42, pitchVar = 0.15, range = 200, maxDuration = 1.0 },
	gnashDisgorge = { id = SWIM, volume = 0.7, pitch = 0.5, pitchVar = 0.1, range = 200, maxDuration = 0.7 },
	gnashHeave = { id = SWIM, volume = 0.75, pitch = 0.35, pitchVar = 0.06, range = 220, maxDuration = 1.1 },
	gnashMire = { id = SWIM, volume = 0.4, pitch = 0.7, pitchVar = 0.12, range = 180, maxDuration = 0.9 },
	gnashHammerfall = { id = LAND, volume = 1.0, pitch = 0.3, pitchVar = 0.04, range = 260 },
	gnashRootCreak = { id = SWIM, volume = 0.45, pitch = 0.4, pitchVar = 0.06, range = 180, maxDuration = 1.0 },
	gnashGurgle = { id = SWIM, volume = 0.35, pitch = 0.6, pitchVar = 0.14, range = 150, maxDuration = 0.8 },
	gnashDeath = { id = WATER, volume = 1.0, pitch = 0.26, pitchVar = 0.02, range = 320 },

	-- --------------------------------------- Admiral Wrack, the Careenage
	wrackGrapeshot = { id = LAND, volume = 0.6, pitch = 2.2, pitchVar = 0.18, range = 200 },
	wrackBroadside = { id = LAND, volume = 1.0, pitch = 0.42, pitchVar = 0.06, range = 300 },
	wrackAnchorsweep = { id = SWIM, volume = 0.8, pitch = 0.4, pitchVar = 0.05, range = 240, maxDuration = 1.0 },
	wrackWisps = { id = CLICK, volume = 0.25, pitch = 2.6, pitchVar = 0.25, range = 160 },
	wrackPowderrun = { id = CLICK, volume = 0.3, pitch = 2.0, pitchVar = 0.2, range = 140 },
	wrackKegFuse = { id = CLICK, volume = 0.25, pitch = 2.8, pitchVar = 0.1, range = 120 },
	wrackKegBlast = { id = LAND, volume = 1.0, pitch = 0.34, pitchVar = 0.05, range = 260 },
	wrackBrazier = { id = SWIM, volume = 0.35, pitch = 1.2, pitchVar = 0.12, range = 150, maxDuration = 0.7 },
	wrackCannonoverload = { id = LAND, volume = 1.0, pitch = 0.28, pitchVar = 0.03, range = 300 },
	wrackAnchorline = { id = CLICK, volume = 0.4, pitch = 1.3, pitchVar = 0.25, range = 180 },
	wrackLongboat = { id = WATER, volume = 0.5, pitch = 0.65, pitchVar = 0.08, range = 220 },
	wrackLadybelow = { id = LAND, volume = 0.9, pitch = 0.25, pitchVar = 0.03, range = 300 },
	wrackBoomsweep = { id = SWIM, volume = 0.75, pitch = 0.55, pitchVar = 0.06, range = 230, maxDuration = 0.9 },
	wrackBilgeblow = { id = WATER, volume = 0.7, pitch = 0.45, pitchVar = 0.08, range = 240 },
	wrackShots = { id = LAND, volume = 0.55, pitch = 1.9, pitchVar = 0.1, range = 200 },
	wrackBulletWhiz = { id = SWIM, volume = 0.3, pitch = 2.6, pitchVar = 0.18, range = 60, maxDuration = 0.2 },
	wrackBell = { id = CLICK, volume = 0.55, pitch = 0.75, pitchVar = 0.02, range = 260 },
	wrackHullGroan = { id = SWIM, volume = 0.5, pitch = 0.3, pitchVar = 0.04, range = 240, maxDuration = 1.4 },
	wrackDeath = { id = WATER, volume = 1.0, pitch = 0.24, pitchVar = 0.02, range = 340 },

	-- ------------------------------------------ the Kraken, the Maelstrom
	krakenRingwave = { id = WATER, volume = 0.8, pitch = 0.45, pitchVar = 0.05, range = 300 },
	krakenClosingfist = { id = SWIM, volume = 0.8, pitch = 0.34, pitchVar = 0.04, range = 280, maxDuration = 1.2 },
	krakenInkspit = { id = SWIM, volume = 0.6, pitch = 0.6, pitchVar = 0.1, range = 220, maxDuration = 0.5 },
	krakenTentaclelash = { id = SWIM, volume = 0.85, pitch = 0.5, pitchVar = 0.06, range = 260, maxDuration = 0.8 },
	krakenWreckhurl = { id = LAND, volume = 0.95, pitch = 0.4, pitchVar = 0.06, range = 280 },
	krakenStormcall = { id = LAND, volume = 0.9, pitch = 0.26, pitchVar = 0.04, range = 320 },
	krakenInknova = { id = WATER, volume = 0.9, pitch = 0.3, pitchVar = 0.03, range = 320 },
	krakenUndertow = { id = SWIM, volume = 0.65, pitch = 0.28, pitchVar = 0.03, range = 300, maxDuration = 1.6 },
	krakenRoar = { id = LAND, volume = 1.0, pitch = 0.18, pitchVar = 0.02, range = 340 },
	krakenTentacleRise = { id = WATER, volume = 0.75, pitch = 0.4, pitchVar = 0.05, range = 280 },
	krakenDeath = { id = WATER, volume = 1.0, pitch = 0.2, pitchVar = 0.02, range = 360 },
}

-- FOOTSTEPS, built rather than listed. The pack bakes four variants of each
-- surface (`stepSand1`..`stepSand4`) so a sprint does not machine-gun one
-- sample, and CharacterSoundController picks one at random - so the catalogue
-- has to answer to all five names per surface, base included. The fallback
-- does the same trick one rung down: one built-in per surface at four pitches.
--
-- Every one of these is quiet and cut short. A footstep is heard four times a
-- second for the length of the session; it is the one cue in the game where
-- being slightly too loud is not a mix note, it is the reason someone turns
-- the sound off.
local STEP_SURFACES = {
	stepSand = { id = SWIM, volume = 0.16, pitch = 1.5, cut = 0.18 },
	stepStone = { id = LAND, volume = 0.16, pitch = 1.9, cut = 0.16 },
	stepWood = { id = LAND, volume = 0.18, pitch = 1.5, cut = 0.18 },
	stepGrass = { id = SWIM, volume = 0.14, pitch = 1.8, cut = 0.16 },
	stepSnow = { id = SWIM, volume = 0.15, pitch = 1.2, cut = 0.2 },
	stepMetal = { id = LAND, volume = 0.16, pitch = 2.4, cut = 0.14 },
	stepMud = { id = SWIM, volume = 0.18, pitch = 0.9, cut = 0.22 },
	stepShallow = { id = WATER, volume = 0.2, pitch = 1.6, cut = 0.2 },
}
for base, s in STEP_SURFACES do
	PACK_CATALOGUE[base] = {
		id = s.id,
		volume = s.volume,
		pitch = s.pitch,
		pitchVar = 0.12,
		range = 45,
		maxDuration = s.cut,
	}
	for i = 1, 4 do
		PACK_CATALOGUE[base .. i] = {
			id = s.id,
			volume = s.volume,
			pitch = s.pitch * (0.94 + 0.04 * i),
			pitchVar = 0.06,
			range = 45,
			maxDuration = s.cut,
		}
	end
end

-- THE FAMILY VOICES. Four cues for each of the fifteen body families in
-- src/Shared/Data/CreatureFamilies.luau, and every one of them SPRITE-ONLY.
--
-- Silence is the right default here and nowhere else, because these are the
-- only cues in the game that fire CONSTANTLY - an idle timer on every creature
-- within sixty studs of the player, forever. A wrong stand-in would not be a
-- wrong note now and then; it would be the soundtrack.
--
-- The contract authors fourteen sets (leviathan is the seven bosses, which
-- have the whole vocabulary above instead). The fifteenth is registered anyway
-- so that a boss asking for `leviathanHurt` gets the designed silence rather
-- than a warning nobody can act on.
local FAMILIES = {
	"smallFish",
	"bigFish",
	"spiny",
	"crustacean",
	"eel",
	"jelly",
	"blob",
	"wing",
	"burrower",
	"mimic",
	"undead",
	"elemental",
	"mechanical",
	"flora",
	"leviathan",
}
local FAMILY_SHAPE = {
	Idle = { volume = 0.3, range = 65 },
	Attack = { volume = 0.55, range = 90 },
	Hurt = { volume = 0.45, range = 80 },
	Die = { volume = 0.6, range = 100 },
}
for _, family in FAMILIES do
	for suffix, shape in FAMILY_SHAPE do
		PACK_CATALOGUE[family .. suffix] = {
			volume = shape.volume,
			pitch = 1,
			pitchVar = 0.06,
			range = shape.range,
		}
	end
end

-- ==================================================== THE DRAW/STOW CUES
--
-- What the hands sound like changing. Five cues, ALL 2D - played with no
-- position, so they arrive in the player's own ears at a fixed volume and
-- nobody else hears them. That is why these rows carry no `range`: range
-- only shapes a positioned carrier, and these never get one.
--
-- FishingController's `Equipped` hook is the ONE place that picks between
-- them (it is the only equip echo in the game - CombatController and
-- RangedController watch the same attribute and stay deliberately silent),
-- and it plays at most one draw per change.
--
-- SPRITE-ONLY, on the same principle as the family voices above: no built-in
-- is a defensible stand-in for a rod leaving its holster or a gun coming up,
-- and a wrong one would teach the player the wrong thing about what is in
-- their hands. Silent until the pack is imported.
local HAND_CUES = {
	"rodDraw", -- rod equipped, ~0.6 s
	"rodStow", -- rod put away, ~0.5 s
	"weaponDraw", -- melee or ranged weapon equipped, ~0.55 s
	"weaponStow", -- weapon put away, ~0.45 s
	"fistReady", -- switched to bare fists, ~0.4 s
}
for _, name in HAND_CUES do
	PACK_CATALOGUE[name] = {
		volume = 0.7,
		pitch = 1,
		pitchVar = 0.04,
	}
end

-- Merged rather than assigned: an existing row always wins, so if the session
-- editing CATALOGUE above lands one of these names first, its hand-tuned
-- values stand and this generated one is dropped on the floor. That is the
-- safe direction for a merge nobody is watching.
for name, def in PACK_CATALOGUE do
	if CATALOGUE[name] == nil then
		CATALOGUE[name] = def
	end
end

-- The contract still lists Rimefang's newest attacks under the PROVISIONAL
-- lane-81 names while this catalogue already carries them as `rime*`.
-- Register both spellings at the same defs until the generator settles it: an
-- alias costs nothing, and in that fight a missing cue costs a dodge.
local RIME_ALIASES = {
	iceCrackWeb = "rimeCrackWeb",
	iceLock = "rimeCrackLock",
	iceBurst = "rimeIceBurst",
	skyLaunch = "rimeSkyLaunch",
	skyImpact = "rimeSkyImpact",
	shockwave = "rimeShock",
	floeQuake = "rimeQuake",
}
for alias, target in RIME_ALIASES do
	if CATALOGUE[alias] == nil and CATALOGUE[target] ~= nil then
		CATALOGUE[alias] = CATALOGUE[target]
	end
end

-- ------------------------------------------------------------- the pack
--
-- Resolved once at require time and again if the Folder appears later (it is
-- dragged in by hand in Studio, so it can land after the client has booted).
local pack: Folder? = nil
-- Every bundle Sound the pack turned out to have, keyed by its Name (which is
-- `cue.file`). A bundle that did not come in is simply absent here, and that is
-- what makes a half-imported pack survivable.
local bundleSound: { [string]: Sound } = {}
local packWarned = false

-- The active boss voice, set by BossHudController for as long as a boss bar is
-- up. It is what turns the shared `bossSlam` into `bossSlam__pyrelisk` for the
-- length of that fight and back again afterwards. Nil is the ordinary state.
local voice: string? = nil

-- The sprite for `name` under the voice in force, or nil to fall through to
-- the rbxasset row. Resolution order is `name__voice` then `name`, and a
-- per-call voice (a creature family) beats the standing boss voice because it
-- is the more specific claim. A cue whose BUNDLE is not in the pack counts as
-- no sprite at all, which is what makes a half-imported pack survivable.
local function spriteFor(name: string, callVoice: string?)
	local v = callVoice or voice
	if v then
		local variant = SoundSprites.cues[name .. "__" .. v]
		if variant and bundleSound[variant.file] then
			return variant
		end
	end
	-- VARIANT FAN-OUT, checked BEFORE the bare name. The generator expands a
	-- cue declared with `variants` into `name1..nameN` (thunder1..3,
	-- punchSwing1..3, stepSand1..4); some of those also keep a bare `name`
	-- render as the fallback. A caller asking for `punchSwing` gets one of
	-- the numbered takes at random - a punch that repeats identically is a
	-- sampler - and only a cue with no numbered takes plays its bare render.
	local count = 0
	while true do
		local v = SoundSprites.cues[name .. tostring(count + 1)]
		if v and bundleSound[v.file] then
			count += 1
		else
			break
		end
	end
	if count > 0 then
		return SoundSprites.cues[name .. tostring(math.random(count))]
	end
	local cue = SoundSprites.cues[name]
	if cue and bundleSound[cue.file] then
		return cue
	end
	return nil
end

-- Hard cap on how long a one-shot's carrier lives, in case TimeLength never
-- resolves (asset missing, still streaming).
local MAX_LIFETIME = 4

-- Fade length when a `maxDuration` cuts a clip short.
local FADE_OUT = 0.08

local folder: Folder? = nil

-- The SFX bus, found or made in `init`. Named, not tagged, and a sibling of
-- MusicController's "Music" and "Ambience" groups so the three read as one set
-- under SoundService. NOT DUCKED, ever: the victory duck exists to clear room
-- for the music, and a hit that goes quiet because a fanfare is playing is a
-- fight you cannot hear.
local sfxGroup: SoundGroup? = nil

local function container(): Folder
	if not folder or not folder.Parent then
		local f = Instance.new("Folder")
		f.Name = "ClientSfx"
		f.Parent = Workspace
		folder = f
	end
	return folder :: Folder
end

-- Builds the carrier's Sound. With a `cue` it is a CLONE of the bundle Sound
-- that cue lives in - the clone matters, because the bundle in the pack is the
-- shared original and two cues off one bundle must be able to play at once.
-- Without a cue it is an ordinary rbxasset Sound. Returns nil when it is
-- neither, which is a sprite-only cue playing without the pack: the designed
-- silence, and the caller cleans up rather than warning.
local function makeSound(def, parent: Instance, cue, opts: PlayOpts?): Sound?
	local sound: Sound
	if cue then
		sound = bundleSound[cue.file]:Clone()
		-- Never Looped: it would loop the whole bundle. Sfx.loop makes
		-- the seam itself out of two clones.
		sound.Looped = false
	elseif def and def.id then
		sound = Instance.new("Sound")
		sound.SoundId = def.id
	else
		return nil
	end

	-- THE VOICING SPLIT. A catalogue row's `pitch` is a PLACEHOLDER VOICING:
	-- it is how a single rbxasset click is bent into a legendary chime (2.6) or
	-- a boss swell (0.35), and applying it to a real recording would play that
	-- recording at two and a half times speed. So a sprite starts from pitch 1
	-- and keeps only the `pitchVar` wobble and the caller's `opts`.
	--
	-- VOLUME IS NOT THE SAME CASE. Per-cue gain balance lives in this catalogue
	-- (CONTRACT.md 5), so the row's `volume` IS the sprite's mix level and is
	-- kept - unless the row says otherwise with `spriteVolume`, which is the
	-- escape hatch for a row whose volume was chosen to prop up a thin built-in.
	local rowVolume = if def then (if cue then def.spriteVolume or def.volume else def.volume) else nil
	local baseVolume = rowVolume or 0.6
	local basePitch = if cue then 1 elseif def and def.pitch then def.pitch else 1
	local wobble = (math.random() * 2 - 1) * (if def then def.pitchVar or 0 else 0)

	sound.Volume = baseVolume * (if opts and opts.volume then opts.volume else 1)
	sound.PlaybackSpeed = math.max(0.05, (basePitch + wobble) * (if opts and opts.pitch then opts.pitch else 1))
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = 6
	sound.RollOffMaxDistance = (if def then def.range or 60 else 60)
	-- THE SFX BUS. Every one-shot and every loop rides it, so a settings slider
	-- has one handle on the whole category. Nil until init has run, which is
	-- harmless: SoundGroup = nil is the default state anyway.
	sound.SoundGroup = sfxGroup
	sound.Parent = parent
	return sound
end

-- Plays `name` once. With a `position` it's a 3D sound at that point;
-- without one it plays flat in the player's ears. `opts` scales the
-- catalogue's pitch and volume and can name a voice variant for this one call.
-- Unknown names warn once and do nothing, so a typo never breaks the thing
-- that called it - and a name the PACK has but the catalogue doesn't is not
-- unknown, which is what lets the generator add cues ahead of this file.
local warned = {}

local function fadeOutSoon(sound: Sound, after: number)
	task.delay(after, function()
		if sound.Parent then
			TweenService:Create(sound, TweenInfo.new(FADE_OUT, Enum.EasingStyle.Linear), { Volume = 0 }):Play()
		end
	end)
end

function Sfx.play(name: string, position: Vector3?, opts: PlayOpts?)
	local def = CATALOGUE[name]
	local cue = spriteFor(name, opts and opts.voice)
	if not def and not cue then
		if not warned[name] then
			warned[name] = true
			warn(string.format("[Sfx] no sound named %q", name))
		end
		return
	end
	-- SPRITE-ONLY CUE, PACK ABSENT: the designed silence. Answered HERE, before
	-- a carrier exists, because these are the cues fired most often per second
	-- (dialogBlip, xpGain, the family voices) and building a Part and a Folder
	-- for each one only to destroy it again is churn nobody hears.
	if not cue and not (def and def.id) then
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

	local sound = makeSound(def, carrier, cue, opts)
	if not sound then
		-- Sprite-only cue, pack absent. Not a mistake and not worth a warning:
		-- take the empty carrier back and be silent.
		carrier:Destroy()
		return
	end
	sound:Play()
	if cue then
		-- Seek AFTER Play(). A TimePosition written to a stopped Sound is not
		-- reliably kept, and a sprite that starts at zero is the wrong cue.
		sound.TimePosition = cue.start
	end

	-- Clean up after the clip; fall back to a cap if its length isn't known.
	local lifetime = MAX_LIFETIME
	if cue then
		-- The sprite knows exactly how long it is. Pitch stretches that in wall
		-- time, so the cut has to be divided by PlaybackSpeed - `maxDuration`
		-- never applies here, because the slice IS the duration.
		-- NOT clamped to MAX_LIFETIME. The bundle knows this slice exactly, so
		-- there is nothing to guess and nothing to cap: MAX_LIFETIME is the
		-- fallback for a clip whose length never resolved, and applying it here
		-- cut catchBoss (3.4 s of swell) off at four seconds - or would cut
		-- levelUp's fanfare the moment a slow pitch stretched it past the cap.
		local window = cue.length / sound.PlaybackSpeed
		lifetime = window + FADE_OUT + 0.1
		fadeOutSoon(sound, window)
	else
		if sound.IsLoaded and sound.TimeLength > 0 then
			lifetime = math.min(MAX_LIFETIME, sound.TimeLength / sound.PlaybackSpeed + 0.1)
		end
		-- Early cut: a quick fade so the stop doesn't click.
		if def and def.maxDuration and def.maxDuration < lifetime then
			lifetime = def.maxDuration + FADE_OUT + 0.1
			fadeOutSoon(sound, def.maxDuration)
		end
	end

	Debris:AddItem(carrier, lifetime)
end

-- ---------------------------------------------------------------- loops
--
-- A SUSTAINED, MOVING SOUND, which `play` cannot be: its carrier is fire-and-
-- forget and its lifetime is decided the instant it starts. A sweep that lasts
-- as long as the limb takes, and is at the limb's position on every frame of
-- it, needs a handle - so these three (start / move / stop) are the whole API,
-- and the CALLER OWNS THE HANDLE.
--
-- LEAKED LOOPS ARE THE KNOWN FAILURE HERE, and everything below is shaped
-- against one: `stop` is idempotent and takes a nil handle without complaint,
-- so a teardown path may call it blindly and a double-stop is free; there is
-- no registry to fall out of sync with the world; and every loop carrier is an
-- ordinary part in the same ClientSfx folder, so nothing survives that folder
-- being cleared. What is NOT defended against is a caller that drops its
-- handle without stopping - a loop is audible forever if you forget it, which
-- is why `stop` belongs on the same lifecycle path that destroys the body.
-- The splice at a sprite loop's seam. 60 ms is long enough that the join is
-- inaudible and short enough that nobody hears the material doubled.
local LOOP_CROSSFADE = 0.06

-- Keeps a sprite loop seamless. A sprite is a slice out of the MIDDLE of a
-- long bundle, so `Looped` is no use - it would loop the bundle - and seeking
-- one Sound back to `start` clicks. So there are two clones: this waits until
-- the running one is a crossfade away from the end of its slice, brings the
-- other up from `start` underneath it, and swaps.
--
-- It re-reads the target volume and pitch off the carrier's attributes every
-- lap, which is how a caller riding setLoopVolume / setLoopPitch (the boat's
-- wash and engine, the reel's tension) is followed without this knowing they
-- exist.
--
-- THE CARRIER LEAVING THE WORLD IS THE ONLY EXIT, and stopLoop destroys it, so
-- a stopped loop's driver ends within a lap and there is no registry to fall
-- out of sync with. Every wait is followed by a re-check for exactly that.
local function driveSpriteLoop(part: BasePart, a: Sound, b: Sound, cue)
	local cur, nxt = a, b
	while part.Parent do
		local speed = math.max(tonumber(part:GetAttribute("SfxPitch")) or 1, 0.05)
		local volume = tonumber(part:GetAttribute("SfxVolume")) or cur.Volume
		cur.PlaybackSpeed = speed
		local hold = (cue.start + cue.length - cur.TimePosition) / speed - LOOP_CROSSFADE
		if hold > 0 then
			task.wait(hold)
		end
		if not part.Parent then
			break
		end
		nxt.PlaybackSpeed = speed
		nxt.Volume = 0
		nxt:Play()
		nxt.TimePosition = cue.start
		local fade = TweenInfo.new(LOOP_CROSSFADE, Enum.EasingStyle.Linear)
		-- Flagged for the length of the splice so setLoopVolume keeps its hands
		-- off the two Sounds while they are crossing.
		part:SetAttribute("SfxSeam", true)
		TweenService:Create(nxt, fade, { Volume = volume }):Play()
		TweenService:Create(cur, fade, { Volume = 0 }):Play()
		task.wait(LOOP_CROSSFADE)
		if not part.Parent then
			break
		end
		part:SetAttribute("SfxSeam", false)
		cur:Stop()
		cur, nxt = nxt, cur
	end
end

function Sfx.loop(name: string, position: Vector3, opts: PlayOpts?): BasePart?
	local def = CATALOGUE[name]
	local cue = spriteFor(name, opts and opts.voice)
	if not def and not cue then
		if not warned[name] then
			warned[name] = true
			warn(string.format("[Sfx] no sound named %q", name))
		end
		return nil
	end
	-- Same early-out as `play`: a sprite-only loop with no pack has nothing to
	-- sustain, and answering it before the carrier exists is what stops a
	-- caller that retries (a heartbeat re-armed on every HealthChanged) from
	-- building and destroying a Part several times a second.
	if not cue and not (def and def.id) then
		return nil
	end

	local part = Instance.new("Part")
	part.Name = "SfxLoop_" .. name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.CFrame = CFrame.new(position)
	part.Parent = container()

	if cue then
		local a = makeSound(def, part, cue, opts)
		local b = makeSound(def, part, cue, opts)
		if not a or not b then
			part:Destroy()
			return nil
		end
		-- The live target, so setLoopVolume / setLoopPitch have somewhere to
		-- write that the driver reads back at the next seam.
		part:SetAttribute("SfxVolume", a.Volume)
		part:SetAttribute("SfxPitch", a.PlaybackSpeed)
		-- The loop's own level and note, remembered so setLoopGain and
		-- setLoopPitchMul can scale THEM rather than whatever the last frame
		-- left behind. The pitch base includes the wobble drawn at start, which
		-- is the point: the throttle should ride this engine, not a nominal one.
		part:SetAttribute("SfxBaseVolume", a.Volume)
		part:SetAttribute("SfxBasePitch", a.PlaybackSpeed)
		part:SetAttribute("SfxSeam", false)
		b.Volume = 0
		a:Play()
		a.TimePosition = cue.start
		task.spawn(driveSpriteLoop, part, a, b, cue)
		return part
	end

	local sound = makeSound(def, part, nil, opts)
	if not sound then
		-- Sprite-only loop with no pack: nothing to sustain. Returning nil
		-- rather than a live handle is deliberate - stopLoop takes nil happily,
		-- so every caller's teardown path still works untouched.
		part:Destroy()
		return nil
	end
	part:SetAttribute("SfxVolume", sound.Volume)
	part:SetAttribute("SfxPitch", sound.PlaybackSpeed)
	part:SetAttribute("SfxBaseVolume", sound.Volume)
	part:SetAttribute("SfxBasePitch", sound.PlaybackSpeed)
	sound.Looped = true
	sound:Play()

	-- `maxDuration` ON A LOOP. The row says "only the front of this built-in is
	-- usable" - the rest is a stroke's tail, a body's ring-out - and Looped on
	-- the whole clip plays exactly the part the row disowned, forever. So the
	-- clip is re-seated to its head every maxDuration seconds with the same
	-- short fade a one-shot's early cut gets, and the tail is never reached.
	-- Once the pack is present this branch is not taken at all: a sprite loop
	-- IS its slice, and the seam belongs to driveSpriteLoop.
	if def and def.maxDuration and def.maxDuration > FADE_OUT * 2 then
		local period = def.maxDuration
		task.spawn(function()
			while part.Parent do
				task.wait(math.max(0.02, period - FADE_OUT))
				if not part.Parent then
					return
				end
				local target = tonumber(part:GetAttribute("SfxVolume")) or sound.Volume
				local fade = TweenInfo.new(FADE_OUT / 2, Enum.EasingStyle.Linear)
				TweenService:Create(sound, fade, { Volume = 0 }):Play()
				task.wait(FADE_OUT / 2)
				if not part.Parent then
					return
				end
				sound.TimePosition = 0
				TweenService:Create(sound, fade, { Volume = target }):Play()
				task.wait(FADE_OUT / 2)
			end
		end)
	end
	return part
end

-- Moves a running loop. Silently ignores a handle that has already been
-- stopped, so a caller may keep updating one for the frame it takes to notice.
function Sfx.moveLoop(handle: BasePart?, position: Vector3)
	if handle and handle.Parent then
		handle.CFrame = CFrame.new(position)
	end
end

-- Ends one. Fades over FADE_OUT rather than cutting, or a drag stopping dead
-- clicks louder than the drag was, then takes the carrier - and with it the
-- Sound - away for good.
function Sfx.stopLoop(handle: BasePart?)
	if not handle or not handle.Parent then
		return
	end
	for _, child in handle:GetChildren() do
		if child:IsA("Sound") then
			TweenService:Create(child, TweenInfo.new(FADE_OUT, Enum.EasingStyle.Linear), { Volume = 0 }):Play()
		end
	end
	Debris:AddItem(handle, FADE_OUT + 0.05)
end

-- Rides a running loop's pitch: the boat's throttle, the reel's line tension.
-- The attribute is the source of truth (a sprite loop's driver reads it back
-- at every seam) and the live Sounds are set too, so the change is heard now
-- rather than a lap from now.
function Sfx.setLoopPitch(handle: BasePart?, pitch: number)
	if not handle or not handle.Parent then
		return
	end
	local p = math.max(0.05, pitch)
	handle:SetAttribute("SfxPitch", p)
	for _, child in handle:GetChildren() do
		if child:IsA("Sound") then
			child.PlaybackSpeed = p
		end
	end
end

-- The same for volume: the bow wash rising with speed. Skipped mid-splice,
-- because during those 60 ms one of the two clones is deliberately on its way
-- to zero and pushing it back up is an audible stutter at every seam.
function Sfx.setLoopVolume(handle: BasePart?, volume: number)
	if not handle or not handle.Parent then
		return
	end
	local v = math.max(0, volume)
	handle:SetAttribute("SfxVolume", v)
	if handle:GetAttribute("SfxSeam") then
		return
	end
	for _, child in handle:GetChildren() do
		if child:IsA("Sound") and child.IsPlaying then
			child.Volume = v
		end
	end
end

-- THE SAME TWO, IN FRACTIONS OF THE LOOP'S OWN LEVEL.
--
-- setLoopVolume and setLoopPitch above are ABSOLUTE - they set the number the
-- Sound gets - and every caller that has one so far actually wanted a
-- MULTIPLIER: the bow wash at "speed / topSpeed" of its mix level, the engine
-- at 0.8..1.3 of its note. Passing a 0..1 fraction to the absolute setter
-- threw the catalogue's balance away and made a wash at full speed as loud as
-- a boss, which is what these two exist to stop. The base is what the loop
-- started with (pitch base includes its wobble), stored on the carrier.
function Sfx.setLoopGain(handle: BasePart?, multiplier: number)
	if not handle or not handle.Parent then
		return
	end
	local base = tonumber(handle:GetAttribute("SfxBaseVolume")) or 0
	Sfx.setLoopVolume(handle, base * math.max(0, multiplier))
end

function Sfx.setLoopPitchMul(handle: BasePart?, multiplier: number)
	if not handle or not handle.Parent then
		return
	end
	local base = tonumber(handle:GetAttribute("SfxBasePitch")) or 1
	Sfx.setLoopPitch(handle, base * math.max(0.01, multiplier))
end

-- THE ACTIVE BOSS VOICE. BossHudController sets it to the engaged boss's id
-- while its bar is up and clears it on untrack. Everything else is unchanged:
-- a cue with a `__<id>` variant in the pack gets that recording for the length
-- of the fight, a cue without one keeps the shared vocabulary, and with no
-- pack at all this changes nothing at all.
function Sfx.setVoice(id: string?)
	voice = id
end

-- Finds the imported pack, maps every bundle name to its Sound, and preloads
-- the lot. Idempotent and safe to call at any time: it is called once at require
-- time and again if the Folder appears later, because the pack is dragged into
-- ReplicatedStorage/Assets by hand (docs/import-checklist.md row 8) and can
-- easily land after this module has been required.
function Sfx.init()
	-- The bus, before anything else: init is also the late-pack re-entry, and a
	-- group that only exists on the second call would leave every sound played
	-- before the pack arrived off the slider.
	if not (sfxGroup and sfxGroup.Parent) then
		local existing = SoundService:FindFirstChild("Sfx")
		if existing and existing:IsA("SoundGroup") then
			sfxGroup = existing
		else
			local group = Instance.new("SoundGroup")
			group.Name = "Sfx"
			group.Parent = SoundService
			sfxGroup = group
		end
	end

	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local found = assets and assets:FindFirstChild("SoundPack")
	pack = if found and found:IsA("Folder") then found :: Folder else nil

	local bundles: { [string]: Sound } = {}
	local preload: { Instance } = {}
	if pack then
		-- ONE LOOP FOR THE WHOLE PACK. `SoundSprites.files` is every bundle the
		-- generator wrote - SFX, music and ambience alike - so the music bundles
		-- are preloaded here even though MusicController owns what is inside
		-- them: the pack is one import, and the first island theme should not
		-- arrive four seconds after the island does.
		for soundName in SoundSprites.files do
			local s = (pack :: Folder):FindFirstChild(soundName)
			if s and s:IsA("Sound") then
				bundles[soundName] = s
				table.insert(preload, s)
			end
		end
	elseif not packWarned then
		packWarned = true
		-- Not an error. The pack is optional by design and everything falls
		-- back to the built-ins without it; this line is only so that "the new
		-- audio isn't playing" has an answer in the output window.
		warn("[Sfx] no ReplicatedStorage/Assets/SoundPack - rbxasset fallbacks only")
	end
	bundleSound = bundles

	if #preload > 0 then
		task.spawn(function()
			pcall(function()
				ContentProvider:PreloadAsync(preload)
			end)
		end)
	end
end

Sfx.init()

-- Watch for a pack that arrives late (imported into a running Studio session,
-- or simply parented after this module was required). Cheap: one connection,
-- and it only ever re-runs init for the one name that matters.
task.spawn(function()
	local assets = ReplicatedStorage:WaitForChild("Assets", 30)
	if not assets then
		return
	end
	assets.ChildAdded:Connect(function(child)
		if child.Name == "SoundPack" then
			Sfx.init()
		end
	end)
end)

return Sfx
