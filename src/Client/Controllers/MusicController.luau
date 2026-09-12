--!nonstrict
-- MusicController.luau
-- The score. Two layers that are always running and one that takes them over:
--
--   THE BED (`amb_<mode>`) - the room tone of wherever you are standing. It
--   follows the SAME mode WeatherController resolves for the fog, because the
--   sound and the sight of a place have to agree: a whiteout you can see but
--   not hear is a bug report, and the two systems drifting apart at an island
--   edge is worse than either being wrong on its own.
--
--   THE THEME (`island_<id>`) - the island's music, sitting over the bed.
--   Open sea has none: the sea is the one place in the game that is supposed
--   to feel empty, and silence is how you say that. Islets have none of their
--   own either (CONTRACT.md 4) - they play the nearest MAIN island's theme
--   quieter, so a rock two thousand studs off the fen still sounds like the
--   fen's water rather than like a seventh island nobody wrote music for.
--
--   THE BOSS (`boss_<id>_low` + `_high`) - while a fight is up it replaces
--   the theme entirely. See setBoss.
--
-- WHY THE RESOLVER IS DUPLICATED HERE. WeatherController owns the same probe
-- and will not export it. Copying ~30 lines of pure math is the cheaper
-- mistake than either editing that file or asking it for a signal it does not
-- have: the probe is a loop over a table of sixteen, it runs once a second,
-- and both copies read the same Islands/BossArenas config, so they cannot
-- disagree about geometry - only about code, and this file says out loud
-- where it deviates (islets, below). If WeatherController's precedence ever
-- changes, the two STANDING_MODES / ARENA_MODES tables below are the diff.
--
-- EVERY TRACK IS A REGION OF A BUNDLE. The pack is eleven long OGGs, not fifty
-- short ones (CONTRACT.md 1), so `SoundSprites.music.island_ice` is not a Sound
-- name any more - it is `{ file, start, length, loop }`, a slice of
-- `audio_music_N`. Nothing can use `Sound.Looped`: it would loop the whole
-- bundle. So a looping track is two clones of its bundle taking turns, seeked to
-- `start` and crossfaded over the seek on a clock-driven schedule - see THE SEAM
-- and stepLoops. The musical consequence is nil (the renders are loop_wrapped
-- exactly as before); the import consequence is eleven clicks instead of fifty.
--
-- THE PACK MAY NOT EXIST. `ReplicatedStorage/Assets/SoundPack` is imported by
-- hand (CONTRACT.md 2) and `SoundSprites.music`/`.ambience` are EMPTY until
-- the generator has been run. That is the normal state of a fresh checkout,
-- not an error state: every lookup below returns nil and every layer simply
-- stays silent. Nothing in here may warn, error, or spin on a missing track -
-- a controller that shouts about audio nobody has built yet is noise in every
-- session's console for weeks.
--
-- TWO CUES THAT BELONG TO THE WEATHER LIVE HERE (thunder, lampOn/lampOff).
-- They are the weather's sounds, but WeatherController is locked to another
-- author, and this file already resolves the same mode once a second - so it
-- can fire them off its own edges without that file knowing. See THUNDER and
-- THE LAMP below.

local ContentProvider = game:GetService("ContentProvider")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Islands = require(Shared.Config.Islands)
local BossArenas = require(Shared.Config.BossArenas)
local World = require(Shared.Config.World)
local SoundSprites = require(Shared.Config.SoundSprites)
local Remotes = require(Shared.Net.Remotes)

local Sfx = require(script.Parent.Parent.Modules.Sfx)

local player = Players.LocalPlayer

local MusicController = {}

-- Same cadence as WeatherController's probe, and for the same reason: this is
-- pure math over a table of sixteen, and nothing about a two-and-a-half second
-- crossfade needs to be decided at frame rate.
local PROBE_INTERVAL = 1.0

-- Every fade in this file. One number on purpose: music that changes at
-- different speeds depending on WHY it changed reads as the system glitching
-- rather than as the world moving.
local CROSSFADE = 2.5

-- Layer gains, before the master buses below. The bed sits under everything
-- (the beds are already mastered ~8 LU quieter than the music, CONTRACT.md 5;
-- this is the mix on top of that), and an islet borrows its neighbour's theme
-- at ISLET_GAIN so it reads as music carrying across water rather than as
-- music that belongs to the rock you are standing on.
local BED_VOLUME = 0.6
-- Island themes sit ~4 dB under the boss stems on purpose: the packer masters
-- every track to the same loudness, and a theme that plays under an hour of
-- fishing has to be the calm one. 0.55 -> 0.42 with the 2026-09-12 re-render.
local THEME_VOLUME = 0.42
local ISLET_GAIN = 0.6
local BOSS_VOLUME = 0.7

-- THE SEAM. Every track is a REGION of a bundle (SoundSprites.music/.ambience
-- carry `file`, `start`, `length`), so `Sound.Looped` is no use - it would loop
-- the whole six-minute bundle. A loop is two clones of the bundle taking turns:
-- the one in front plays its region, and REGION_CROSSFADE before the region
-- ends the other is started at `start` underneath it and the two are crossfaded
-- equal-power. The renders are loop_wrapped (CONTRACT.md 4), so the join is
-- already continuous material; the crossfade is only there to hide the seek,
-- which is why it is 120 ms and not a bar.
local REGION_CROSSFADE = 0.12

-- The fade on a stinger's tail, so the cut at `start + length` is not a click
-- into whatever the generator packed next in the bundle.
local STINGER_FADE = 0.05

-- The victory duck (see `stinger`). Down fast, back up at the house crossfade:
-- a duck that eases out over 2.5 s lets the stinger's first second fight the
-- bed it is supposed to be clearing room in.
local DUCK_SECONDS = 6
local DUCK_LEVEL = 0.3
local DUCK_IN = 0.4

-- THUNDER. WeatherController draws the storm but has no cue for it, so the
-- roll is fired here on a random timer for as long as the resolved mode is
-- "storm". Random rather than periodic because a storm that thunders on a
-- metronome stops being weather within about four rolls.
local THUNDER_MIN = 8
local THUNDER_MAX = 20

-- ======================================================= the resolver
--
-- A copy of WeatherController's two probes and its mode precedence. Kept
-- deliberately dumb and side-effect free: it answers "where am I and what is
-- the weather", nothing else decides anything here.

local STANDING_MODES: { [string]: string } = {
	gloom = "gloom",
	swamp = "mist",
	volcano = "ash",
	wreck = "ghost",
	maelstrom = "storm",
}

local ARENA_MODES: { [string]: string } = {
	volcano = "summit",
	-- The Pyrelisk heart chamber: its own BossArenas row (`pyrelisk_heart`,
	-- an arena with no island), its own mood in WeatherController, so its
	-- own bed - `amb_heartchamber`.
	pyrelisk_heart = "heartchamber",
}

local ARENA_MOOD_RADIUS = 140
local ARENA_MOOD_BOUNDS: { [string]: { radius: number, minY: number } } = {
	volcano = { radius = 340, minY = 100 },
	pyrelisk_heart = { radius = 150, minY = 520 },
}

-- An arena whose key is not an island has no `island_<key>` theme of its own;
-- it borrows the theme of the island whose fight it belongs to. Only matters
-- between fights (a live boss owns the theme slot).
local ARENA_THEME_OWNER: { [string]: string } = {
	pyrelisk_heart = "volcano",
}

-- Server-opened windows, mirrored off the same WorldEvent remote the weather
-- reads. We only listen; nothing here ever fires on that channel. An arena
-- storm carries its own deadline for the same reason it does over there - a
-- close that never arrives must not leave the wrong bed playing all session.
local blizzards: { [string]: boolean } = {}
local arenaStorms: { [string]: { deadline: number, mode: string } } = {}
local ARENA_STORM_DEFAULT = 4.5
local ARENA_STORM_MAX = 20

local function rootPart(): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

-- The island the character is standing on (nearest centre within 1.5x its
-- footprint), or nil on the open sea. Mirror of WeatherController's.
local function currentIslandId(): string?
	local root = rootPart()
	if not root then
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
-- OWNS it, or nil. Mirror of WeatherController's, bounds table and all.
local function currentArenaIslandId(): string?
	local root = rootPart()
	if not root then
		return nil
	end
	local here: string? = nil
	local bestDist = math.huge
	for _, arena in BossArenas.items do
		local c = arena.center
		local bounds = ARENA_MOOD_BOUNDS[arena.islandId]
		local radius = if bounds then bounds.radius else ARENA_MOOD_RADIUS
		local dist = (Vector2.new(root.Position.X, root.Position.Z) - Vector2.new(c.X, c.Z)).Magnitude
		if dist < radius and dist < bestDist and (not bounds or root.Position.Y - World.WATER_Y >= bounds.minY) then
			bestDist = dist
			here = arena.islandId
		end
	end
	return here
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

-- Where we are, in the terms the layers need: the weather mode, the MAIN
-- island whose music owns this spot (nil on the open sea), and whether we got
-- there via an islet.
--
-- THE ONE DELIBERATE DEVIATION from WeatherController: an islet has no row in
-- STANDING_MODES, so over there standing on one resolves to "clear". Here the
-- mode is taken from the nearest MAIN island instead, because CONTRACT.md 4
-- says an islet plays its neighbour's bed - a rock inside the fen's water
-- should sound like the fen, not like the cove. The fog stays whatever
-- WeatherController decided; only the audio borrows.
local function resolve(): (string, string?, boolean)
	local here = currentIslandId()
	if here then
		local entry = Islands.items[here]
		local islet = entry ~= nil and entry.islet == true
		local owner = here
		if islet then
			local root = rootPart()
			owner = (root and Islands.nearestIsland(root.Position, false)) or here
		end
		local mode = STANDING_MODES[owner] or (if blizzards[owner] then "blizzard" else "clear")
		return mode, owner, islet
	end

	-- Nothing on the map claims you: you may be out at a lair, wearing the
	-- owning island's mood (or the lair's own, or a storm the fight opened).
	local owner = currentArenaIslandId()
	if owner then
		local mode = arenaStormMode(owner) or ARENA_MODES[owner] or STANDING_MODES[owner] or "clear"
		return mode, owner, false
	end

	-- Open sea. The bed is `amb_sea` and there is no theme at all.
	return "clear", nil, false
end

-- ======================================================= the pack

local musicGroup: SoundGroup? = nil
local ambienceGroup: SoundGroup? = nil
local holder: Folder? = nil

-- The imported pack, or nil on a checkout where nobody has run the import
-- yet. Looked up lazily and never waited on: WaitForChild here would hang the
-- controller forever in exactly the state we are trying to survive.
local function pack(): Instance?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	return assets and assets:FindFirstChild("SoundPack")
end

-- A row out of SoundSprites: where a track lives inside its bundle.
type Region = {
	file: string,
	start: number,
	length: number,
	loop: boolean,
}

-- One clone pair playing one region. `front` is the clone you are hearing;
-- `back` is the one that takes over at the next seam. `level` is the voice's
-- own gain (the layer's mix), tweened here rather than by TweenService because
-- the scheduler writes Volume every frame during a splice and two owners of one
-- property is how a crossfade ends up stuck at half.
type Voice = {
	tag: string,
	region: Region,
	front: Sound,
	back: Sound,
	from: number,
	to: number,
	fadeStart: number,
	fadeDur: number,
}

-- One or more voices that loop TOGETHER. A theme or a bed has one; a boss has
-- two (its `low` and `high` stem), and they share this one `nextSwap` - which
-- is the whole mechanism of the phase lock: both stems seek in the same frame
-- off the same clock, so nothing can accumulate between them.
type Loop = {
	voices: { Voice },
	period: number,
	nextSwap: number,
	crossStart: number?,
	dead: boolean,
}

local loops: { Loop } = {}

-- One clone of a bundle Sound, or nil - silently, every time - when the
-- generator has not written that bundle into SoundSprites or the pack has not
-- been imported. Never Looped: Looped would loop the whole bundle. Volume
-- starts at 0; every caller fades in.
local function makeClone(file: string?, group: SoundGroup?): Sound?
	if not file then
		return nil
	end
	local folder = pack()
	local source = folder and folder:FindFirstChild(file)
	if not (source and source:IsA("Sound")) then
		return nil
	end
	local sound = source:Clone()
	sound.Name = file
	sound.Looped = false
	sound.Volume = 0
	sound.SoundGroup = group
	-- Parented under SoundService, so it plays flat in the player's ears
	-- rather than from a point in the world. Music has no position.
	sound.Parent = holder or SoundService
	-- Preloading a Sound that is already about to play is not wasted: it is
	-- what stops the first bar of a theme being swallowed while the file
	-- streams in. Spawned because PreloadAsync yields.
	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync({ sound })
		end)
	end)
	return sound
end

-- The voice's gain right now. Sine-eased over `fadeDur`, which is the shape
-- TweenService gives every other fade in this file.
local function voiceLevel(voice: Voice, now: number): number
	if voice.fadeDur <= 0 then
		return voice.to
	end
	local p = math.clamp((now - voice.fadeStart) / voice.fadeDur, 0, 1)
	local eased = 0.5 - 0.5 * math.cos(p * math.pi)
	return voice.from + (voice.to - voice.from) * eased
end

local function voiceFade(voice: Voice, target: number, seconds: number, now: number)
	voice.from = voiceLevel(voice, now)
	voice.to = target
	voice.fadeStart = now
	voice.fadeDur = math.max(seconds, 0)
end

-- EQUAL POWER, not linear. The two clones are playing the same material a
-- region-length apart, so a linear crossfade would dip ~3 dB in the middle of
-- every lap - audible as a pulse once a loop, which is exactly the thing a
-- seamless loop is supposed to not have.
local function applyVoice(voice: Voice, level: number, cross: number?)
	if cross then
		voice.front.Volume = level * math.cos(cross * math.pi * 0.5)
		voice.back.Volume = level * math.sin(cross * math.pi * 0.5)
	else
		voice.front.Volume = level
		voice.back.Volume = 0
	end
end

-- Builds and starts a region loop. `defs` is one entry per voice
-- ({ tag, region, gain, fade }); a voice whose bundle is not in the pack is
-- dropped, and a loop with no voices left at all is nil - the pack-absent path,
-- silent and without a warning.
--
-- EVERY VOICE IS STARTED IN THIS ONE FRAME, at its own `start`. Two stems are
-- the same arrangement at the same tempo, so starting them a yield apart is
-- half a bar of flam on the first downbeat.
local function startLoop(defs, group: SoundGroup?, now: number): Loop?
	local voices: { Voice } = {}
	local period = math.huge
	for _, def in defs do
		local region: Region = def.region
		local front = makeClone(region.file, group)
		local back = makeClone(region.file, group)
		if front and back then
			local voice: Voice = {
				tag = def.tag,
				region = region,
				front = front,
				back = back,
				from = 0,
				to = def.gain,
				fadeStart = now,
				fadeDur = math.max(def.fade or CROSSFADE, 0),
			}
			table.insert(voices, voice)
			period = math.min(period, region.length)
		else
			if front then
				front:Destroy()
			end
			if back then
				back:Destroy()
			end
		end
	end
	if #voices == 0 then
		return nil
	end
	for _, voice in voices do
		voice.front.Volume = 0
		voice.front:Play()
		voice.front.TimePosition = voice.region.start
	end
	local loop: Loop = {
		voices = voices,
		period = period,
		-- The first seam is a crossfade BEFORE the region runs out, so the
		-- incoming clone has somewhere to come up from.
		nextSwap = now + math.max(period - REGION_CROSSFADE, REGION_CROSSFADE),
		crossStart = nil,
		dead = false,
	}
	table.insert(loops, loop)
	return loop
end

local function voiceTagged(loop: Loop?, tag: string): Voice?
	if not loop then
		return nil
	end
	for _, voice in loop.voices do
		if voice.tag == tag then
			return voice
		end
	end
	return nil
end

-- Takes the loop out of the scheduler and hands its clones to TweenService for
-- the way out. `dead` is checked before anything writes Volume, so the tween
-- owns the fade from this frame on and there is no tug of war.
local function stopLoop(loop: Loop?, seconds: number?)
	if not loop or loop.dead then
		return
	end
	loop.dead = true
	local fade = seconds or CROSSFADE
	local info = TweenInfo.new(fade, Enum.EasingStyle.Sine)
	for _, voice in loop.voices do
		TweenService:Create(voice.front, info, { Volume = 0 }):Play()
		TweenService:Create(voice.back, info, { Volume = 0 }):Play()
	end
	task.delay(fade + 0.1, function()
		for _, voice in loop.voices do
			voice.front:Destroy()
			voice.back:Destroy()
		end
	end)
end

-- THE SCHEDULER, off os.clock() and NOT off TimePosition. TimePosition is
-- quantised to the audio callback (tens of milliseconds, and it does not move
-- at all on a frame where the mixer did not run), so polling it for "am I near
-- the end of my region" both jitters the seam and cannot keep two stems
-- together. A seam the wall clock schedules is the same seam for every voice in
-- the loop, which is what the stems need.
local function stepLoops(now: number)
	for i = #loops, 1, -1 do
		local loop = loops[i]
		if loop.dead then
			table.remove(loops, i)
			continue
		end
		local cross: number? = nil
		local crossStart = loop.crossStart
		if crossStart then
			local p = (now - crossStart) / REGION_CROSSFADE
			if p >= 1 then
				-- The splice is over: the clone that came up is the loop now,
				-- and the one that was playing goes back to being the spare.
				for _, voice in loop.voices do
					voice.front:Stop()
					voice.front, voice.back = voice.back, voice.front
				end
				loop.crossStart = nil
			else
				cross = p
			end
		elseif now >= loop.nextSwap then
			for _, voice in loop.voices do
				voice.back.Volume = 0
				voice.back:Play()
				voice.back.TimePosition = voice.region.start
			end
			loop.crossStart = now
			-- Measured from the frame the seek ACTUALLY happened on, not from
			-- the time it was due: the audio is where we just put it, and a
			-- schedule that ignores that drifts away from what is audible.
			loop.nextSwap = now + math.max(loop.period - REGION_CROSSFADE, REGION_CROSSFADE)
			cross = 0
		end
		for _, voice in loop.voices do
			applyVoice(voice, voiceLevel(voice, now), cross)
		end
	end
end

-- ======================================================= the layers
--
-- A layer is one slot that holds at most one playing track. Setting it to the
-- key it already holds is free (only the gain is re-tweened, which is how an
-- islet's 0.6 arrives without restarting the theme); setting it to anything
-- else crossfades: the old one fades out and is destroyed on its own timer
-- while the new one fades in, so the two genuinely overlap instead of the
-- second waiting for the first.
type Layer = {
	key: string?,
	gain: number,
	loop: Loop?,
	group: SoundGroup?,
}

local function newLayer(): Layer
	return { key = nil, gain = 0, loop = nil, group = nil }
end

local bed: Layer = newLayer()
local theme: Layer = newLayer()

local function setLayer(layer: Layer, key: string?, region: Region?, gain: number)
	if layer.key == key then
		if layer.loop and math.abs(layer.gain - gain) > 0.001 then
			layer.gain = gain
			local voice = layer.loop.voices[1]
			if voice then
				voiceFade(voice, gain, CROSSFADE, os.clock())
			end
		end
		return
	end
	layer.key = key
	layer.gain = gain
	stopLoop(layer.loop)
	layer.loop = nil
	if not key or not region then
		-- The pack-absent path. The key is still recorded above so we do not
		-- retry the lookup once a second for the rest of the session.
		return
	end
	layer.loop =
		startLoop({ { tag = "track", region = region, gain = gain, fade = CROSSFADE } }, layer.group, os.clock())
end

-- ======================================================= the boss

local bossId: string? = nil
local bossPhase = 1
-- ONE loop with two voices, tagged "low" and "high" - not two loops. They share
-- its seam, and that is the phase lock.
local bossLoop: Loop? = nil

local function stopBoss()
	stopLoop(bossLoop)
	bossLoop = nil
end

-- The `high` stem's target for a phase: phase 1 is the fight being taught and
-- wants the restrained read, phases 2-3 add the drive (CONTRACT.md 4). The
-- `low` stem never ducks - the two are the SAME arrangement, so muting high
-- leaves a complete piece of music rather than a hole.
local function highTarget(): number
	return if bossPhase >= 2 then BOSS_VOLUME else 0
end

-- THE SYNC, and it is now a lock rather than a watchdog. The two stems are two
-- voices of ONE region loop: they are started in the same frame at the same
-- region-relative offset (their own `start`, which is the head of the same bar
-- of the same arrangement), and at every seam they are re-seeked in the same
-- frame off the same `os.clock()` reading. There is nowhere for a difference to
-- accumulate, so the old drift watchdog is gone with the thing it was guarding.
--
-- The generator keeps a boss's `low` and `high` in the SAME bundle (build.py
-- packs the pair as one unit), so this is also one preload and one stream.
local function startBoss(id: string)
	stopBoss()
	local low = SoundSprites.music["boss_" .. id .. "_low"]
	local high = SoundSprites.music["boss_" .. id .. "_high"]
	local defs = {}
	if low then
		table.insert(defs, { tag = "low", region = low, gain = BOSS_VOLUME, fade = CROSSFADE })
	end
	if high then
		table.insert(defs, { tag = "high", region = high, gain = highTarget(), fade = 2 })
	end
	if #defs == 0 then
		return
	end
	bossLoop = startLoop(defs, musicGroup, os.clock())
end

-- The public boss switch. `nil` ends the fight and hands the island's theme
-- back; a phase with no id is ignored, so a stray phase update after the boss
-- is down can never restart the music. Called by BossHudController, which owns
-- the bar and therefore knows the phase before anything else does.
function MusicController.setBoss(id: string?, phase: number?)
	if phase then
		bossPhase = math.clamp(phase, 1, 3)
	end
	if id == bossId then
		-- Same fight, new phase: only the `high` stem's GAIN moves, over 2 s, so
		-- the fight escalates rather than cutting - and the stem keeps its place
		-- in the loop, so the two stay locked across the change.
		local voice = voiceTagged(bossLoop, "high")
		if voice then
			voiceFade(voice, highTarget(), 2, os.clock())
		end
		return
	end
	bossId = id
	if id then
		-- The island theme steps aside first: the boss stems and the theme are
		-- in different keys, and two of them overlapping for 2.5 s is the one
		-- crossfade in the game that has to be a handover instead.
		setLayer(theme, nil, nil, 0)
		bossPhase = phase or 1
		startBoss(id)
	else
		stopBoss()
		-- The next probe (<= 1 s) brings the island's own theme back up.
		theme.key = nil
	end
end

-- ======================================================= stingers
--
-- One-shots, 2D, and MUSIC: three regions of a music bundle (CONTRACT.md 2),
-- so they are built here off the music bus rather than through Sfx, which only
-- knows about the SFX bundles and rbxasset fallbacks. They do not loop and they
-- are not a layer, so they own no slot - they are started, and destroyed on
-- their own length. `stinger_victory` ducks the beds for DUCK_SECONDS so the
-- fanfare has the room to itself; the duck rides the master buses, so it
-- catches the bed, the theme and the boss stems in one move.

local duckLevel = 1

-- The SFX bus is Sfx.luau's, made in Sfx.init. Read by name rather than
-- exported, because the only thing this file wants from it is the slider.
local function sfxGroup(): SoundGroup?
	local group = SoundService:FindFirstChild("Sfx")
	return if group and group:IsA("SoundGroup") then group :: SoundGroup else nil
end

local function applyBusVolumes()
	local music = tonumber(player:GetAttribute("MusicVolume")) or 1
	local sfx = tonumber(player:GetAttribute("SfxVolume")) or 1
	if musicGroup then
		musicGroup.Volume = math.clamp(music, 0, 1) * duckLevel
	end
	-- THE BED FOLLOWS THE MUSIC SLIDER, not the SFX one. It used to ride SFX on
	-- the argument that rain is the world making noise - but the SfxVolume
	-- slider now has a real bus of its own (every cue in Sfx.luau), and the bed
	-- is scored material: it is written, mastered and crossfaded alongside the
	-- themes, and a player pulling the music down wants the room tone to go
	-- with it rather than to be left alone under the silence.
	if ambienceGroup then
		ambienceGroup.Volume = math.clamp(music, 0, 1) * duckLevel
	end
	-- The SFX group is NOT ducked and never appears below: a hit that goes
	-- quiet because a fanfare is playing is a fight you cannot hear.
	local group = sfxGroup()
	if group then
		group.Volume = math.clamp(sfx, 0, 1)
	end
end

local duckToken = 0

local function duck()
	duckToken += 1
	local token = duckToken
	duckLevel = DUCK_LEVEL
	-- THE TARGET IS THE SLIDER TIMES THE LEVEL, never the LIVE volume times the
	-- level. Reading the live volume compounds: a second duck inside the window
	-- multiplied an already-ducked bus by 0.3 again, and a boss intro followed
	-- by a victory took the music to 9% and left it there for the restore to
	-- climb out of. Both layers are on the music slider (see applyBusVolumes).
	local music = math.clamp(tonumber(player:GetAttribute("MusicVolume")) or 1, 0, 1)
	local into = TweenInfo.new(DUCK_IN, Enum.EasingStyle.Sine)
	if musicGroup then
		TweenService:Create(musicGroup, into, { Volume = music * DUCK_LEVEL }):Play()
	end
	if ambienceGroup then
		TweenService:Create(ambienceGroup, into, { Volume = music * DUCK_LEVEL }):Play()
	end
	task.delay(DUCK_SECONDS, function()
		-- A second victory inside the window owns the duck; this one just
		-- leaves. Without the token the first restore would lift the second's.
		if token ~= duckToken then
			return
		end
		duckLevel = 1
		local level = math.clamp(tonumber(player:GetAttribute("MusicVolume")) or 1, 0, 1)
		local out = TweenInfo.new(CROSSFADE, Enum.EasingStyle.Sine)
		if musicGroup then
			TweenService:Create(musicGroup, out, { Volume = level }):Play()
		end
		if ambienceGroup then
			TweenService:Create(ambienceGroup, out, { Volume = level }):Play()
		end
	end)
end

-- `name` is the bare stinger name - "bossIntro", "victory", "finale" - or the
-- full cue key; both are accepted so a caller that has the CONTRACT name in
-- hand does not have to strip it.
-- A STINGER IS A REGION of a music bundle, and it lives in SoundSprites.music -
-- it is never in `.cues`, so routing it through Sfx.play could only ever find
-- the placeholder row (now gone) and the real fanfare never played once the pack
-- was in. So it is built here: one clone of the bundle, seeked to the stinger's
-- `start`, stopped at `start + length` with a short fade, and taken away.
--
-- THE LENGTH COMES FROM THE GENERATOR, not from Sound.TimeLength. TimeLength is
-- the whole six-minute bundle now, so waiting on it would leave the fanfare
-- running into whatever was packed after it and hold the Sound for six minutes.
--
-- No pack, no track: silent, no warning, and NO DUCK - ducking six seconds of
-- music to make room for a stinger that does not exist is the one failure this
-- ordering exists to prevent.
function MusicController.stinger(name: string)
	local key = if string.sub(name, 1, 8) == "stinger_" then name else "stinger_" .. name
	local region: Region? = SoundSprites.music[key]
	if not region then
		return
	end
	local sound = makeClone(region.file, musicGroup)
	if not sound then
		return
	end
	sound.Volume = 1
	sound:Play()
	sound.TimePosition = region.start
	if key == "stinger_victory" then
		duck()
	end
	local length = math.max(region.length, STINGER_FADE)
	task.delay(length - STINGER_FADE, function()
		if sound.Parent then
			TweenService:Create(sound, TweenInfo.new(STINGER_FADE, Enum.EasingStyle.Linear), { Volume = 0 }):Play()
		end
	end)
	Debris:AddItem(sound, length + 0.25)
end

function MusicController.bossIntro()
	MusicController.stinger("bossIntro")
end

function MusicController.victory()
	MusicController.stinger("victory")
end

function MusicController.finale()
	MusicController.stinger("finale")
end

-- ======================================================= the probe

local lastProbe = 0
local currentMode = ""
local nextThunder = 0

-- THE LAMP. WeatherController lights the character's personal lamp inside the
-- gloom mood, but it is a local PointLight with NO event and no exported
-- state, and that file is not ours to edit - so there is no cheap client-side
-- signal to hang the cue on. lampOn/lampOff therefore fire on THIS resolver's
-- gloom edge instead: entering the mood where the lamp is lit, and leaving it.
-- Same probe, same second, so in practice they land with the light; if the
-- lamp ever gains a real signal, that is the line to move.
local function onModeChanged(mode: string, previous: string)
	if mode == "gloom" and previous ~= "gloom" then
		Sfx.play("lampOn")
	elseif previous == "gloom" and mode ~= "gloom" then
		Sfx.play("lampOff")
	end
	if mode == "storm" then
		nextThunder = os.clock() + math.random(THUNDER_MIN, THUNDER_MAX)
	end
end

local function probe()
	local mode, owner, islet = resolve()

	-- The bed. Open sea is the one place with no owning island, and it has its
	-- own bed rather than a mode's.
	local bedKey = if owner then "amb_" .. mode else "amb_sea"
	setLayer(bed, bedKey, SoundSprites.ambience[bedKey], BED_VOLUME)

	-- The theme. A fight owns the slot while it is up, and the open sea is
	-- silent by design - both come out as "no theme", which is one branch.
	if owner and not bossId then
		local key = "island_" .. (ARENA_THEME_OWNER[owner] or owner)
		setLayer(theme, key, SoundSprites.music[key], THEME_VOLUME * (if islet then ISLET_GAIN else 1))
	else
		setLayer(theme, nil, nil, 0)
	end

	if mode ~= currentMode then
		local previous = currentMode
		currentMode = mode
		onModeChanged(mode, previous)
	end
end

function MusicController.init()
	-- Two buses so a settings menu can pull music and world sound apart later
	-- without this file knowing about the menu. Named, not tagged: the menu
	-- will find them by name under SoundService.
	local music = SoundService:FindFirstChild("Music")
	if not (music and music:IsA("SoundGroup")) then
		music = Instance.new("SoundGroup")
		music.Name = "Music"
		music.Parent = SoundService
	end
	musicGroup = music :: SoundGroup

	local ambience = SoundService:FindFirstChild("Ambience")
	if not (ambience and ambience:IsA("SoundGroup")) then
		ambience = Instance.new("SoundGroup")
		ambience.Name = "Ambience"
		ambience.Parent = SoundService
	end
	ambienceGroup = ambience :: SoundGroup

	local folder = Instance.new("Folder")
	folder.Name = "ClientMusic"
	folder.Parent = SoundService
	holder = folder

	bed.group = ambienceGroup
	theme.group = musicGroup

	applyBusVolumes()
	player.AttributeChanged:Connect(function(name)
		if name == "MusicVolume" or name == "SfxVolume" then
			-- Straight to the new level rather than tweened: this is a slider
			-- being dragged, and a 2.5 s lag under the user's own hand reads as
			-- the slider being broken. The duck is folded in so a mid-duck
			-- change does not undo it.
			applyBusVolumes()
		end
	end)

	-- THE PACK MAY LAND LATE. It is dragged into ReplicatedStorage/Assets by
	-- hand, routinely after this controller has booted - and every layer here
	-- RECORDS ITS KEY EVEN WHEN THE LOOKUP FAILED (setLayer, deliberately, so a
	-- missing track is not re-probed once a second forever). That memory is
	-- exactly what would keep the score silent for the rest of the session
	-- after an import, so clearing it is all this needs to do: the next probe,
	-- within a second, sees a key it does not hold and builds the track. Sfx
	-- has the same watcher for its sheets.
	task.spawn(function()
		local assets = ReplicatedStorage:WaitForChild("Assets", 30)
		if not assets then
			return
		end
		assets.ChildAdded:Connect(function(child)
			if child.Name ~= "SoundPack" then
				return
			end
			bed.key = nil
			theme.key = nil
			-- A fight already up: restart its stems from the pack that just
			-- arrived rather than waiting for the next boss.
			if bossId then
				startBoss(bossId)
			end
		end)
	end)

	-- Mirror the two server-driven windows the weather reads, so the bed can
	-- follow a blizzard or an arena storm. Listen only - nothing here fires.
	Remotes.WorldEvent.OnClientEvent:Connect(function(event)
		if type(event) ~= "table" then
			return
		end
		if event.kind == "blizzard" then
			blizzards[event.islandId] = if event.active then true else nil
		elseif event.kind == "arenastorm" then
			local islandId = event.islandId
			if type(islandId) ~= "string" or BossArenas.items[islandId] == nil then
				return
			end
			if event.active then
				local seconds = tonumber(event.duration) or ARENA_STORM_DEFAULT
				arenaStorms[islandId] = {
					deadline = os.clock() + math.clamp(seconds, 0, ARENA_STORM_MAX),
					mode = if type(event.mode) == "string" then event.mode else "blizzard",
				}
			else
				arenaStorms[islandId] = nil
			end
		end
	end)
end

function MusicController.start()
	RunService.Heartbeat:Connect(function()
		local now = os.clock()

		-- THE REGION SCHEDULER, every frame and before anything else. It owns
		-- every seam and every layer gain in this file: the bed's, the theme's,
		-- and both boss stems' at once. It replaces the old stem-drift watchdog,
		-- which corrected a divergence this cannot have - the two stems are two
		-- voices of one loop and are re-seeked in the same frame off this one
		-- `now` (see stepLoops). It is a handful of arithmetic per playing track.
		stepLoops(now)

		if currentMode == "storm" and now >= nextThunder then
			nextThunder = now + math.random(THUNDER_MIN, THUNDER_MAX)
			Sfx.play("thunder")
		end

		if now - lastProbe < PROBE_INTERVAL then
			return
		end
		lastProbe = now
		probe()
	end)
end

return MusicController
