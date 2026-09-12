--!nonstrict
-- CreatureEventController.luau
-- What the enemies look and sound like doing their thing. Two inputs, both
-- already replicated by the server, so every client sees the same show:
--
--   - STATES are attributes on the creature Model (set by the archetype that
--     owns them in CreatureService): Dashing / Exposed (the charger), Buried
--     (the lurker), Open (the mimic), Charging (the Voltray). Watched the
--     way CreatureVfxController watches Thrown / Landed / Flops.
--   - MOMENTS come through the CreatureEvent remote (kind, position, extra):
--     a spat glob and its splash, an explosion, a burrower bursting up, a
--     mimic's snap, a pickpocket, a shockwave. The server never waits on any
--     of it - damage is decided there; this only draws.
--   - The island BOSS (Bosses.luau / CreatureService's boss archetype) adds
--     the Enraged attribute and its own moments: bossRise, telegraph (the
--     tell before every attack, keyed by attack name), bossSnap, sweep, slam,
--     pull (the one moment that does more than draw: the lure drags the
--     LOCAL character toward the maw with a VectorForce for its duration -
--     walk away to fight it), spine / spineHit, summon, bossDive, enrage,
--     bossDown. The health bar and banners are BossHudController's.
--   - The BOSS ARSENAL (per-island movesets, 2026-08-27) adds moments that
--     carry a `skin` (the SKIN palette): poolSpawn (lingering hazards),
--     strikeHit / inkBlast (telegraphed impacts), chill / snare / chain
--     (the pull's pattern: each client applies the movement effect to its
--     OWN character if it's inside), decoy / decoyMove / decoyPop, beam,
--     phantomOut / phantomIn, and telegraph kinds mark / ringTell.
--
-- Rules this file keeps: it never writes a creature part's Color
-- (CombatFeedbackController caches colours and restores them after every
-- hit flash, so a tint would be snapped back) - glow is Material.Neon, hiding
-- is LocalTransparencyModifier; pooled parts are built in init and moved in
-- Heartbeat (the CombatVfxController pattern); the camera kick goes through
-- CombatVfxController.kick so offsets never stack.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local World = require(Shared.Config.World)
-- The arena layout every side of the game agrees on. Read here for exactly
-- one number: the centre of Rimefang's floe. BossService.arenaPosition
-- spawns a lair boss at BossArenas.centerFor(islandId), updateBoss keeps that
-- point as `creature.anchor`, and the whiteout's storm is centred on the
-- anchor - so this table is the same authority the arena-wide moments use,
-- rather than the boss's pivot the stock telegraph is fired from.
local BossArenas = require(Shared.Config.BossArenas)
-- Brinejaw's geometry. Its sweep markers are drawn off the SAME sand profile
-- the server's hit test measures against (BrinejawPath.sandY), so the band you
-- see on the ground is the band that hits you - the arm itself is drawn from
-- this file too, by BrinejawBodyController.
local BrinejawPath = require(Shared.Modules.BrinejawPath)

local Vfx = require(script.Parent.Parent.Modules.Vfx)
local Sfx = require(script.Parent.Parent.Modules.Sfx)
local Theme = require(script.Parent.Parent.UI.Theme)
local CombatVfxController = require(script.Parent.CombatVfxController)
local ProgressionController = require(script.Parent.ProgressionController)

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

local CreatureEventController = {}

-- Chunk-scope local budget: Luau allows 200 live locals per scope and this
-- module blew past it. Constants live as fields of K instead of chunk
-- locals. DO NOT add new top-level `local` constants - add a field here.
local K = {}

-- Must match CreatureService; server modules aren't requireable here.
K.CREATURES_FOLDER = "Creatures"
K.ATTR_DASHING = "Dashing"
K.ATTR_EXPOSED = "Exposed"
K.ATTR_BURIED = "Buried"
K.ATTR_OPEN = "Open"
K.ATTR_CHARGING = "Charging"
K.ATTR_ENRAGED = "Enraged" -- a boss below its enrage threshold
-- CreatureService's ATTR_ID; our key into CreatureFamilies. Hoisted here from
-- its other assignment further down the file (the Rimefang section) so the
-- helpers below do not depend on where that one sits - it is the same string,
-- so the later line is a harmless no-op rewrite of the same field.
K.ATTR_CREATURE_ID = "CreatureId"

-- ------------------------------------------------------------ family voice

-- The creature's OWN sound when it commits to an attack, layered over the
-- mechanical cue of the move itself (dashWhoosh, crackle, spitLaunch): those
-- say what happened, this says what did it. One cue set per body family
-- rather than per creature is what makes 122 animals affordable to author,
-- and opts.pitch off the body scale is what keeps a sardine and a marlin
-- from sharing a voice - see assets/audio_gen/CONTRACT.md sfx_families.
--
-- NOTE these are FIELDS OF K, deliberately. This chunk is at Luau's 200-local
-- ceiling; a `local` here would break the file at compile time. Same for the
-- require below: it is K.Families, not a new top-level local.
K.Families = require(Shared.Data.CreatureFamilies)

-- The attack voice for a model that is in hand.
K.attackVoice = function(model: Instance?)
	if not (model and model:IsA("Model") and model.Parent) then
		return
	end
	local id = model:GetAttribute(K.ATTR_CREATURE_ID)
	local family = K.Families.get(id)
	if not family then
		return -- unknown id or no family: it stays silent rather than guessing a cue
	end
	Sfx.play(family .. "Attack", model:GetPivot().Position, { pitch = K.Families.voicePitch(id) })
end

-- The attack voice at a POINT, for the moments the effect knows only where it
-- happened. The mouth a glob leaves is on the creature that spat it, so the
-- nearest creature model to that point is the one that did it; the radius is
-- a sanity check (wider than half a boss, narrower than the gap to some
-- unrelated fish), not a real search. Nothing near means no voice, and the
-- launch cue plays alone exactly as it did before.
K.VOICE_SEARCH = 40 -- studs

K.attackVoiceAt = function(position: Vector3)
	local folder = Workspace:FindFirstChild(K.CREATURES_FOLDER)
	if not folder then
		return
	end
	local best, bestD = nil, K.VOICE_SEARCH
	for _, model in folder:GetChildren() do
		if model:IsA("Model") and model:GetAttribute(K.ATTR_CREATURE_ID) then
			local d = (model:GetPivot().Position - position).Magnitude
			if d < bestD then
				best, bestD = model, d
			end
		end
	end
	K.attackVoice(best)
end

-- ---------------------------------------------------------------- knobs

-- The enemies' accent colours. Kept here rather than in Vfx.Color, which is
-- the water's palette.
K.COLOR = {
	acid = Color3.fromRGB(168, 240, 96), -- the cod's spit
	ember = Color3.fromRGB(255, 150, 60), -- the urchin's blast
	spark = Color3.fromRGB(120, 240, 255), -- the Voltray's charge
	coin = Color3.fromRGB(255, 204, 92), -- stolen coins (the HUD's coin gold)
	pearl = Color3.fromRGB(246, 240, 248),
	smoke = Color3.fromRGB(70, 64, 60),
	brine = Color3.fromRGB(120, 255, 214), -- the boss's lure glow + its brine
	bone = Color3.fromRGB(226, 222, 206), -- the boss's spines
	rage = Color3.fromRGB(255, 80, 60),
}

-- Per-island boss effect palettes: the server stamps boss-arsenal events
-- with `skin` (Bosses.luau attack rows) and every drawn effect keys off it,
-- so Pyrelisk's world burns orange while Rimefang's freezes blue.
K.SKIN = {
	peat = Color3.fromRGB(116, 118, 52), -- Gnashroot's churned bog sludge
	root = Color3.fromRGB(122, 220, 96), -- his snare-roots (glow moss)
	-- DARK, deliberately. This palette paints every telegraph, pool ring, chill
	-- puff and strike marker of a fight staged on white sea ice, and the pale
	-- value it used to carry measured 1.49:1 against the authored floe and
	-- 1.05:1 against the procedural one - against a 3:1 minimum for a graphic
	-- that carries meaning. The markers ARE the language of a position fight;
	-- they were being spoken in the colour the ground already wears. This
	-- reads 5.5:1 and 8.6:1, and a dark marker is the only kind that survives
	-- the whiteout's own white fog. (arena_gen.py's header learned the same
	-- lesson for the terrain: "white on white is what killed the first render".)
	frost = Color3.fromRGB(18, 58, 96), -- Rimefang
	lava = Color3.fromRGB(255, 122, 40), -- Pyrelisk
	-- ONE TELEGRAPH LANGUAGE, THREE COLOURS (the Noctyss legibility plan,
	-- 3.1). These two ARE NoctyssPath.TELL.LIMB and NoctyssPath.TELL.LIGHT,
	-- written out rather than read from it because K.SKIN is built before the
	-- module is required and a palette that reached across files for two of
	-- its rows would be the fourth place this fight declares a tell colour.
	-- If either moves, it moves in NoctyssPath first.
	--
	-- The old pair were 158,112,228 and 255,214,120, and the second of those
	-- was one hue step from the LANTERNS themselves (255,226,130) - so "a
	-- light attack is coming" and "that is scenery you can shoot" were drawn
	-- in the same gold. Violet is pushed off the ink-blue it was drifting
	-- toward so it holds 3:1 against both the black floor and the gold.
	ink = Color3.fromRGB(176, 96, 255), -- TELL.LIMB: a limb is coming
	lure = Color3.fromRGB(255, 206, 92), -- TELL.LIGHT: her light is coming
	ember = Color3.fromRGB(255, 150, 60), -- Wrack's powder and shot
	wreck = Color3.fromRGB(120, 220, 180), -- his verdigris ghost-glow
	storm = Color3.fromRGB(130, 210, 255), -- the Kraken's lightning
	-- PHASE THREE, INSIDE THE ANIMAL. Taken from MeshColors' own gullet rows
	-- (KrakenGullet_Heart 122,29,38 and _HeartGlow 230,74,73) rather than
	-- picked, so a telegraph drawn on that flesh is the same red family the
	-- flesh is - the heartbeat ring, the peristalsis and the acid all ride the
	-- stock telegraph shapes with this skin and nothing else changes.
	--
	-- BRIGHT, and for the frost row's reason inverted: the gullet has NO SKY
	-- AND NO SUN (arena_gen says so in as many words - the room is lit only by
	-- its Neon veins), so a dark marker there is a marker nobody can see. This
	-- reads against the 74,33,38 floor at better than 4:1.
	gullet = Color3.fromRGB(255, 138, 122),
	-- ...and the ship's own weather deck, for the exterior phases.
	kraken = Color3.fromRGB(120, 235, 210),
}

local function skinColor(extra, fallback: Color3?): Color3
	return K.SKIN[extra.skin] or fallback or K.COLOR.brine
end

K.GLOB_POOL = 14 -- enough for a boss volley (5) on top of a spine barrage (8)
K.GLOB_SIZE = 0.7
K.SPINE_SIZE = Vector3.new(0.35, 2.2, 0.35)

-- The boss's lure pull: a force on the local root toward it, as
-- acceleration in studs/s^2 (the server's `strength`), for `duration`.
K.PULL_RAMP = 0.25 -- seconds to reach full strength

-- Boss telegraphs / blasts.
K.SHAKE_SLAM = math.rad(5)
K.SHAKE_RISE = math.rad(4)
K.SHAKE_EMERGE_BIG = math.rad(4)
K.ENRAGE_FLICKER_INTERVAL = 0.18
K.GLOB_RING_INTERVAL = 0.25 -- landing-marker ripple cadence while a glob flies

K.DASH_PUFF_INTERVAL = 0.08
K.DASH_TRAIL_LIFETIME = 0.25
K.EXPOSED_SPARK_INTERVAL = 0.3
K.BURIED_PUFF_INTERVAL = 0.12
K.BURIED_SOUND_INTERVAL = 0.5
K.CRACKLE_INTERVAL = { 0.08, 0.22 }

-- Camera kick (via CombatVfxController) for a blast near the local player,
-- and the full-screen flash for one they're standing inside.
K.SHAKE_EXPLODE = math.rad(3)
K.SHAKE_PULSE = math.rad(2)
K.SHAKE_REACH = 1.6 -- x radius: how far out the kick is still felt
K.FLASH_PEAK = 0.55
K.FLASH_FADE = 0.35

-- ---------------------------------------------------------------- state

local folder: Folder
local globs = {} -- { part, active, from, to, apex, start, flight, nextRing }
local globCursor = 1

-- Per creature Model: { model, timers..., trail }
local tracked: { [Model]: any } = {}

local flashFrame: Frame
-- The gloom fight's blackout owns its own surface: `flashFrame` is written by
-- every blast in the game, and the dousehunt's whole point is that the dark
-- HOLDS while you are being hit.
local darkFrame: Frame
local darkTween: Tween? = nil

-- The lure pull in progress on the local character, if any.
local pull: {
	force: VectorForce,
	attachment: Attachment,
	center: Vector3,
	radius: number,
	strength: number,
	until_: number,
	start: number,
}? =
	nil

-- Rimefang's three hooks into the shared moments below: the wave wash's
-- crest, everything whale-sized that lands on the sheet, and its
-- whale-shaped tells. Forward-declared because the handlers that hand off to
-- them are written above the section that defines them (see "Rimefang (the
-- floe boss)").
local startWash, rimeSlam, rimeTelegraph

-- ---------------------------------------------------------------- helpers

local function raycastParams(): RaycastParams
	local ignore = {}
	local creatures = Workspace:FindFirstChild(K.CREATURES_FOLDER)
	if creatures then
		table.insert(ignore, creatures)
	end
	for _, other in Players:GetPlayers() do
		if other.Character then
			table.insert(ignore, other.Character)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	return params
end

-- The surface under `position` and whether it's the sea (same test as
-- CreatureVfxController: by the ocean part's name, not by height).
local function surfaceUnder(position: Vector3): (Vector3, boolean)
	local hit = Workspace:Raycast(position + Vector3.new(0, 1.5, 0), Vector3.new(0, -8, 0), raycastParams())
	if hit then
		return hit.Position, hit.Instance.Name == World.OCEAN_NAME
	end
	return Vector3.new(position.X, World.WATER_Y, position.Z), true
end

local function localRoot(): BasePart?
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end

-- Horizontal distance from the local player to `position`, or huge.
local function localDistance(position: Vector3): number
	local root = localRoot()
	if not root then
		return math.huge
	end
	return (Vector3.new(root.Position.X, 0, root.Position.Z) - Vector3.new(position.X, 0, position.Z)).Magnitude
end

-- Is `position` worth drawing at all? The same measure feelBlast already uses
-- to decide whether a blast is felt - the camera, not the character, so a
-- player watching from the boat or waiting to respawn still sees the fight.
-- Brinejaw's arena is 130 studs across and its markers fire constantly, so
-- every one of them starts with this.
local function nearCamera(position: Vector3, range: number): boolean
	return (camera.CFrame.Position - position).Magnitude <= range
end

-- A blast at `position`: kick the camera if it's near, flash the screen if
-- the player is inside it.
local function feelBlast(position: Vector3, radius: number, angle: number, duration: number, flashColor: Color3)
	local d = (camera.CFrame.Position - position).Magnitude
	local reach = radius * K.SHAKE_REACH
	if d < reach then
		CombatVfxController.kick(angle * (1 - d / reach), 0, duration)
	end
	if localDistance(position) <= radius then
		flashFrame.BackgroundColor3 = flashColor
		flashFrame.BackgroundTransparency = 1 - K.FLASH_PEAK
		TweenService:Create(flashFrame, TweenInfo.new(K.FLASH_FADE, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			BackgroundTransparency = 1,
		}):Play()
	end
end

local function partsOf(model: Model): { BasePart }
	local parts = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

local function randomBetween(lo: number, hi: number): number
	return lo + math.random() * (hi - lo)
end

-- ---------------------------------------------------------------- glob pool (the cod's spit)

local function makeGlob(): Part
	local part = Instance.new("Part")
	part.Name = "SpitGlob"
	part.Shape = Enum.PartType.Ball
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = K.COLOR.acid
	part.Transparency = 1
	part.Size = Vector3.new(K.GLOB_SIZE, K.GLOB_SIZE, K.GLOB_SIZE)
	part.Parent = folder
	return part
end

-- `spine` makes it the boss's bone spine (a tall sliver, bone-coloured, that
-- stands up where it lands) instead of a glob. The pooled parts are this
-- controller's own, so recolouring them is fine.
-- `boss` picks the boss's sound set (bossSpit / bossSpine / bossGlobThud)
-- over the cod's.
local function launchGlob(from: Vector3, to: Vector3, flight: number, apex: number, spine: boolean?, boss: boolean?)
	local glob = globs[globCursor]
	globCursor = globCursor % K.GLOB_POOL + 1
	glob.active = true
	glob.spine = spine == true
	glob.boss = boss == true
	glob.from = from
	glob.to = to
	glob.apex = apex
	glob.start = os.clock()
	glob.flight = math.max(flight, 0.1)
	glob.nextRing = 0
	glob.part.Shape = if glob.spine then Enum.PartType.Block else Enum.PartType.Ball
	glob.part.Size = if glob.spine then K.SPINE_SIZE else Vector3.new(K.GLOB_SIZE, K.GLOB_SIZE, K.GLOB_SIZE)
	glob.part.Color = if glob.spine then K.COLOR.bone else K.COLOR.acid
	glob.part.Material = if glob.spine then Enum.Material.SmoothPlastic else Enum.Material.Neon
	glob.part.CFrame = CFrame.new(from)
	glob.part.Transparency = 0
	if glob.spine then
		Sfx.play("bossSpine", from)
	elseif glob.boss then
		Sfx.play("bossSpit", from)
	else
		Sfx.play("spitLaunch", from)
	end
	-- The mouth it came out of. `from` is on that creature's body, so the
	-- nearest model to it is the one that spat.
	K.attackVoiceAt(from)
end

local function landGlob(glob)
	glob.active = false
	local point, water = surfaceUnder(glob.to)
	if glob.spine then
		-- Stays stuck in the ground for a moment, then sinks away.
		local part = glob.part
		part.CFrame = CFrame.new(point + Vector3.new(0, K.SPINE_SIZE.Y * 0.35, 0))
			* CFrame.Angles(math.rad(randomBetween(-15, 15)), 0, math.rad(randomBetween(-15, 15)))
		Vfx.puff(point + Vector3.new(0, 0.1, 0), if water then Vfx.Color.foam else Vfx.Color.sand, 0.9)
		Sfx.play(if water then "spitSplashWater" else "bossSpineHit", point)
		task.delay(0.9, function()
			if not glob.active then
				TweenService:Create(part, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
					Transparency = 1,
				}):Play()
			end
		end)
		return
	end
	glob.part.Transparency = 1
	if water then
		local at = Vector3.new(point.X, point.Y + 0.2, point.Z)
		Vfx.splash(at, 0.8)
		Sfx.play("spitSplashWater", at)
	else
		local at = point + Vector3.new(0, 0.1, 0)
		Vfx.puff(at, K.COLOR.acid, 1.0)
		Vfx.ring(at, 0.3, 2.5, 0.4, K.COLOR.acid)
		Sfx.play(if glob.boss then "bossGlobThud" else "spitSplashGround", at)
	end
end

local function stepGlobs(now: number)
	for _, glob in globs do
		if glob.active then
			local u = (now - glob.start) / glob.flight
			if u >= 1 then
				landGlob(glob)
			else
				local at = Vfx.arcPoint(glob.from, glob.to, glob.apex, u)
				if glob.spine then
					-- Points along its flight.
					local ahead = Vfx.arcPoint(glob.from, glob.to, glob.apex, math.min(u + 0.02, 1))
					local dir = ahead - at
					if dir.Magnitude > 1e-3 then
						glob.part.CFrame = CFrame.lookAt(at, ahead) * CFrame.Angles(math.rad(90), 0, 0)
					else
						glob.part.Position = at
					end
				else
					glob.part.Position = at
				end
				-- A pulsing ripple where it's going to land: the dodge tell.
				if now >= glob.nextRing then
					glob.nextRing = now + K.GLOB_RING_INTERVAL
					local point = surfaceUnder(glob.to)
					local color = if glob.spine then K.COLOR.bone else K.COLOR.acid
					Vfx.ring(point + Vector3.new(0, 0.15, 0), 0.4, 2.0, K.GLOB_RING_INTERVAL * 1.6, color)
				end
			end
		end
	end
end

-- ---------------------------------------------------------------- the lure pull

local function endPull()
	if pull then
		pull.force:Destroy()
		pull.attachment:Destroy()
		pull = nil
	end
end

-- COVER STOPS THE PULL, and it has to be checked EVERY FRAME rather than once
-- when the pull lands: the whole answer to a Kraken pull is to get behind a
-- crate, and a client that decided at t=0 that you were in the open would drag
-- you out of the cover you reached at t=0.3. The server sends the boxes it is
-- adjudicating with (`braced` on the pull payload), so the client's
-- displacement and the server's damage agree about what shelter is.
--
-- Tolerant about the box's shape because the server lane has more than one
-- reasonable way to write one down, and guessing wrong here silently deletes
-- the mechanic rather than erroring: an entry may carry `cframe`+`size`, or
-- `min`+`max`, or `position`+`size`.
K.krakenBraced = function(boxes, at: Vector3): boolean
	if type(boxes) ~= "table" then
		return false
	end
	for _, box in boxes do
		if typeof(box) == "table" then
			local size = if typeof(box.size) == "Vector3" then box.size else nil
			local cf = if typeof(box.cframe) == "CFrame" then box.cframe else nil
			if not cf and typeof(box.position) == "Vector3" then
				cf = CFrame.new(box.position)
			end
			if cf and size then
				local local_ = cf:PointToObjectSpace(at)
				if
					math.abs(local_.X) <= size.X * 0.5
					and math.abs(local_.Y) <= size.Y * 0.5
					and math.abs(local_.Z) <= size.Z * 0.5
				then
					return true
				end
			elseif typeof(box.min) == "Vector3" and typeof(box.max) == "Vector3" then
				if
					at.X >= box.min.X
					and at.X <= box.max.X
					and at.Z >= box.min.Z
					and at.Z <= box.max.Z
					and at.Y >= box.min.Y - 4
					and at.Y <= box.max.Y + 6
				then
					return true
				end
			end
		end
	end
	return false
end

local function beginPull(center: Vector3, radius: number, strength: number, duration: number, braced)
	endPull()
	local root = localRoot()
	if not root then
		return
	end
	local attachment = Instance.new("Attachment")
	attachment.Name = "LurePullAttachment"
	attachment.Parent = root
	local force = Instance.new("VectorForce")
	force.Name = "LurePull"
	force.Attachment0 = attachment
	force.RelativeTo = Enum.ActuatorRelativeTo.World
	force.ApplyAtCenterOfMass = true
	force.Force = Vector3.zero
	force.Parent = root
	local now = os.clock()
	pull = {
		force = force,
		attachment = attachment,
		center = center,
		radius = radius,
		strength = strength,
		until_ = now + duration,
		start = now,
		braced = braced,
	}
end

local function stepPull(now: number)
	if not pull then
		return
	end
	local root = localRoot()
	if not root or now >= pull.until_ or pull.force.Parent ~= root then
		endPull()
		return
	end
	local to = Vector3.new(pull.center.X - root.Position.X, 0, pull.center.Z - root.Position.Z)
	local d = to.Magnitude
	-- Only inside the radius - and, for a PULL, never past the maw itself.
	-- A negative strength is a gust (the kit engine's push): the close zone
	-- must keep working there, because being shoved off a creature you're
	-- standing on is the whole move.
	if d > pull.radius or (d < 4 and pull.strength > 0) then
		pull.force.Force = Vector3.zero
		return
	end
	-- Braced behind cover: the force goes to zero and STAYS applied (rather
	-- than the pull being ended), so stepping back out into the open picks it
	-- up again for whatever is left of the window.
	if pull.braced and K.krakenBraced(pull.braced, root.Position) then
		pull.force.Force = Vector3.zero
		return
	end
	local dir = if d > 0.05 then to.Unit else Vector3.zAxis
	local ramp = math.clamp((now - pull.start) / K.PULL_RAMP, 0, 1)
	pull.force.Force = dir * pull.strength * ramp * root.AssemblyMass
end

-- ------------------------------------------- movement effects (boss arsenal)
-- The chill/snare/chain family works like the pull: the server broadcasts
-- the moment with a radius, each client applies it to its OWN character if
-- it's inside. One walkspeed effect at a time; while effects overlap, the
-- harshest multiplier holds until every one has expired, then the captured
-- base speed is restored exactly.

local moveEffect: { humanoid: Humanoid, baseWalk: number, mult: number, until_: number }? = nil

-- The anchor chain: the local character is leashed to a point for a while.
local chainState: { center: Vector3, leash: number, until_: number, nextRingAt: number }? = nil

local function endMoveEffect()
	if moveEffect then
		local humanoid = moveEffect.humanoid
		if humanoid and humanoid.Parent then
			humanoid.WalkSpeed = moveEffect.baseWalk
		end
		moveEffect = nil
	end
end

local function applyMoveEffect(mult: number, duration: number)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	local now = os.clock()
	if moveEffect and moveEffect.humanoid == humanoid then
		moveEffect.mult = math.min(moveEffect.mult, mult)
		moveEffect.until_ = math.max(moveEffect.until_, now + duration)
	else
		endMoveEffect()
		moveEffect = { humanoid = humanoid, baseWalk = humanoid.WalkSpeed, mult = mult, until_ = now + duration }
	end
	humanoid.WalkSpeed = moveEffect.baseWalk * moveEffect.mult
end

local function endChain()
	chainState = nil
end

local function stepEffects(now: number)
	if moveEffect then
		local humanoid = moveEffect.humanoid
		if not humanoid.Parent or humanoid.Health <= 0 then
			moveEffect = nil -- the character is gone; nothing to restore onto
		elseif now >= moveEffect.until_ then
			endMoveEffect()
		end
	end
	if chainState then
		local root = localRoot()
		if not root or now >= chainState.until_ then
			endChain()
			return
		end
		local off = Vector3.new(root.Position.X - chainState.center.X, 0, root.Position.Z - chainState.center.Z)
		if off.Magnitude > chainState.leash then
			-- Yanked back to the leash's end; velocity survives, position
			-- doesn't - it reads as the chain snapping taut.
			local at = chainState.center + off.Unit * chainState.leash
			root.CFrame = root.CFrame.Rotation + Vector3.new(at.X, root.Position.Y, at.Z)
		end
		if now >= chainState.nextRingAt then
			chainState.nextRingAt = now + 0.4
			local point = surfaceUnder(chainState.center)
			Vfx.ring(point + Vector3.new(0, 0.15, 0), 1.5, chainState.leash, 0.35, K.SKIN.wreck)
		end
	end
end

-- ---------------------------------------------------------------- per creature states

local function setHidden(model: Model, hidden: boolean)
	for _, part in partsOf(model) do
		part.LocalTransparencyModifier = if hidden then 1 else 0
	end
end

local function setMarksGlow(model: Model, glow: boolean)
	for _, part in partsOf(model) do
		if part.Name == "Fish_Marks" then
			part.Material = if glow then Enum.Material.Neon else Enum.Material.SmoothPlastic
		end
	end
end

local function groundPoint(model: Model): Vector3
	local point = surfaceUnder(model:GetPivot().Position)
	return point + Vector3.new(0, 0.1, 0)
end

local function watch(model: Instance)
	if not model:IsA("Model") or tracked[model] then
		return
	end
	local entry = { model = model, nextPuffAt = 0, nextSoundAt = 0, nextSparkAt = 0, nextCrackleAt = 0 }
	tracked[model] = entry

	-- Dashing (charger): a streak off the body + sand kicked up.
	model:GetAttributeChangedSignal(K.ATTR_DASHING):Connect(function()
		local dashing = model:GetAttribute(K.ATTR_DASHING) == true
		if dashing and not entry.trail then
			local body = model.PrimaryPart or model:FindFirstChild("Fish_Body")
			if body and body:IsA("BasePart") then
				entry.trail = Vfx.trail(body, body.Size.Y / 2, Vfx.Color.foam, K.DASH_TRAIL_LIFETIME)
			end
		end
		if entry.trail then
			entry.trail.Enabled = dashing
		end
		if dashing then
			Sfx.play("dashWhoosh", model:GetPivot().Position)
			K.attackVoice(model) -- the animal behind the whoosh
		end
	end)

	-- Exposed (charger turning): a dazed tell.
	model:GetAttributeChangedSignal(K.ATTR_EXPOSED):Connect(function()
		if model:GetAttribute(K.ATTR_EXPOSED) == true then
			local at = model:GetPivot().Position
			for i = 0, 2 do
				task.delay(i * 0.18, function()
					if model.Parent then
						Sfx.play("dazed", at)
					end
				end)
			end
		end
	end)

	-- Buried (lurker): hide it; a sand trail follows wherever it tunnels.
	model:GetAttributeChangedSignal(K.ATTR_BURIED):Connect(function()
		local buried = model:GetAttribute(K.ATTR_BURIED) == true
		setHidden(model, buried)
		local at = groundPoint(model)
		if buried then
			Vfx.puff(at, Vfx.Color.sand, 1.5)
			Sfx.play("burrow", at)
		end
	end)
	if model:GetAttribute(K.ATTR_BURIED) == true then
		setHidden(model, true)
	end

	-- Open (mimic): the pearl glows while it gapes; creak on opening.
	model:GetAttributeChangedSignal(K.ATTR_OPEN):Connect(function()
		local open = model:GetAttribute(K.ATTR_OPEN) == true
		setMarksGlow(model, open)
		if open then
			Sfx.play("shellCreak", model:GetPivot().Position)
		end
	end)

	-- Charging (Voltray): the electric organs light up and crackle.
	model:GetAttributeChangedSignal(K.ATTR_CHARGING):Connect(function()
		local charging = model:GetAttribute(K.ATTR_CHARGING) == true
		setMarksGlow(model, charging)
		if charging then
			-- Once, on the rising edge. The crackle in the heartbeat loop below
			-- repeats for as long as the charge is held; a voice on that would
			-- stutter, so the wind-up gets exactly one.
			K.attackVoice(model)
		end
	end)
	if model:GetAttribute(K.ATTR_CHARGING) == true then
		setMarksGlow(model, true)
	end

	-- Enraged (a boss): its marks (lure, gills) burn and it flickers with
	-- sparks from then on.
	model:GetAttributeChangedSignal(K.ATTR_ENRAGED):Connect(function()
		setMarksGlow(model, model:GetAttribute(K.ATTR_ENRAGED) == true)
	end)
	if model:GetAttribute(K.ATTR_ENRAGED) == true then
		setMarksGlow(model, true)
	end

	-- Cracked (crust): the exposed core glows until the crust reseals.
	-- Server has written this attribute since S4; first client wiring.
	model:GetAttributeChangedSignal("Cracked"):Connect(function()
		setMarksGlow(model, model:GetAttribute("Cracked") == true)
	end)

	-- Downed (reborn): the not-quite-corpse smoulders while it waits to rise.
	model:GetAttributeChangedSignal("Downed"):Connect(function()
		if model:GetAttribute("Downed") == true then
			Vfx.puff(model:GetPivot().Position + Vector3.new(0, 1, 0), Color3.fromRGB(120, 110, 105), 2.5)
			setMarksGlow(model, false)
		end
	end)
end

local function unwatch(model: Instance)
	local entry = tracked[model]
	if entry then
		tracked[model] = nil
	end
end

-- Continuous parts of the states: sand puffs while dashing / tunnelling,
-- sparks while exposed / charging.
local function stepStates(now: number)
	for model, entry in tracked do
		if not model.Parent then
			tracked[model] = nil
		else
			local pivot = model:GetPivot().Position
			if model:GetAttribute(K.ATTR_DASHING) == true and now >= entry.nextPuffAt then
				entry.nextPuffAt = now + K.DASH_PUFF_INTERVAL
				Vfx.puff(groundPoint(model), Vfx.Color.sand, 0.5)
			end
			if model:GetAttribute(K.ATTR_EXPOSED) == true and now >= entry.nextSparkAt then
				entry.nextSparkAt = now + K.EXPOSED_SPARK_INTERVAL
				Vfx.burst(pivot + Vector3.new(0, 1.2, 0), K.COLOR.coin, 6)
			end
			if model:GetAttribute(K.ATTR_BURIED) == true then
				local moved = entry.lastPos == nil or (pivot - entry.lastPos).Magnitude > 0.05
				if moved and now >= entry.nextPuffAt then
					entry.nextPuffAt = now + K.BURIED_PUFF_INTERVAL
					-- Sand on the beach; a wake of foam when it's the boss under the water.
					local point, water = surfaceUnder(pivot)
					Vfx.puff(
						point + Vector3.new(0, 0.1, 0),
						if water then Vfx.Color.foam else Vfx.Color.sand,
						if water then 1.4 else 0.7
					)
				end
				if moved and now >= entry.nextSoundAt then
					entry.nextSoundAt = now + K.BURIED_SOUND_INTERVAL
					Sfx.play("sandShift", groundPoint(model))
				end
			end
			if model:GetAttribute(K.ATTR_CHARGING) == true and now >= entry.nextCrackleAt then
				entry.nextCrackleAt = now + randomBetween(K.CRACKLE_INTERVAL[1], K.CRACKLE_INTERVAL[2])
				local jitter = Vector3.new(math.random() - 0.5, 0.3 + math.random() * 0.5, math.random() - 0.5)
				Vfx.burst(pivot + jitter, K.COLOR.spark, 4)
				Sfx.play("crackle", pivot)
			end
			if model:GetAttribute(K.ATTR_ENRAGED) == true and now >= entry.nextCrackleAt then
				entry.nextCrackleAt = now + K.ENRAGE_FLICKER_INTERVAL
				local _, size = model:GetBoundingBox()
				local jitter = Vector3.new(
					(math.random() - 0.5) * size.X,
					math.random() * size.Y * 0.6,
					(math.random() - 0.5) * size.Z
				)
				Vfx.burst(pivot + jitter, K.COLOR.rage, 5)
			end
			entry.lastPos = pivot
		end
	end
end

-- ---------------------------------------------------------------- moments

K.EVENTS = {}

-- The cod's glob leaves its mouth: fly it to `to` over `flight` seconds.
K.EVENTS.spit = function(position: Vector3, extra)
	if typeof(extra.to) ~= "Vector3" then
		return
	end
	launchGlob(position, extra.to, tonumber(extra.flight) or 0.9, tonumber(extra.arc) or 6, false, extra.boss == true)
end

-- The glob's splash (the server's hit moment; the glob itself lands on the
-- client's own clock, so this is just a wider ring where it counted).
K.EVENTS.splash = function(position: Vector3, extra)
	local radius = tonumber(extra.radius) or 5
	Vfx.ring(position + Vector3.new(0, 0.15, 0), 1, radius, 0.5, K.COLOR.acid)
end

-- The urchin goes off.
K.EVENTS.explode = function(position: Vector3, extra)
	local radius = tonumber(extra.radius) or 10
	Vfx.flash(position, K.COLOR.ember, 4, 0.15)
	Vfx.shockwave(position, 1, radius, 0.45, K.COLOR.ember, 0.25)
	Vfx.burst(position, K.COLOR.ember, 40)
	Vfx.puff(position, K.COLOR.smoke, 2.5)
	local point, water = surfaceUnder(position)
	if water then
		Vfx.ring(point + Vector3.new(0, 0.2, 0), 1, radius, 0.6)
	end
	Sfx.play("explodeCrack", position)
	task.delay(0.06, function()
		Sfx.play("explodeBoom", position)
	end)
	feelBlast(position, radius, K.SHAKE_EXPLODE, 0.35, Color3.fromRGB(255, 220, 180))
end

-- The lurker bursts up out of the sand.
K.EVENTS.emerge = function(position: Vector3, extra)
	local radius = tonumber(extra.radius) or 6
	local at = position + Vector3.new(0, 0.1, 0)
	Vfx.puff(at, Vfx.Color.sand, 2.5)
	Vfx.burst(at, Vfx.Color.sand, 20)
	Vfx.ring(at, 0.5, radius, 0.5, Vfx.Color.sand)
	Sfx.play("emerge", at)
	-- The boss's dive ambush surfaces the same way, only huge.
	if extra.big == true then
		Vfx.splash(at, 4)
		Vfx.burst(at, Vfx.Color.foam, 40)
		Vfx.shockwave(at + Vector3.new(0, 0.4, 0), 1, radius, 0.4, Vfx.Color.foam, 0.5)
		Sfx.play("bossSlam", at)
		feelBlast(at, radius, K.SHAKE_EMERGE_BIG, 0.4, Color3.fromRGB(220, 240, 255))
	end
end

-- The mimic's bite.
K.EVENTS.snap = function(position: Vector3)
	Vfx.flash(position, Vfx.Color.foam, 1.5, 0.1)
	Vfx.puff(position, K.COLOR.pearl, 1.2)
	Sfx.play("shellSnap", position)
	task.delay(0.04, function()
		Sfx.play("hitThump", position)
	end)
end

-- The hermit pickpockets someone; the victim gets a "-N coins" pop.
K.EVENTS.steal = function(position: Vector3, extra)
	Vfx.burst(position + Vector3.new(0, 0.8, 0), K.COLOR.coin, 18)
	Sfx.play("coinSteal", position)
	task.delay(0.09, function()
		Sfx.play("coinSteal", position)
	end)
	local coins = tonumber(extra.coins) or 0
	if extra.victim == player.UserId and coins > 0 then
		ProgressionController.pop(string.format("-%d coins", coins), Theme.Color.red)
	end
end

-- The Voltray discharges.
K.EVENTS.pulse = function(position: Vector3, extra)
	local radius = tonumber(extra.radius) or 12
	Vfx.flash(position, K.COLOR.spark, 3, 0.12)
	Vfx.shockwave(position, 0.8, radius, 0.35, K.COLOR.spark, 0.2)
	Vfx.burst(position, K.COLOR.spark, 30)
	local point, water = surfaceUnder(position)
	if water then
		Vfx.ring(point + Vector3.new(0, 0.2, 0), 1, radius, 0.5)
	end
	Sfx.play("pulseZap", position)
	task.delay(0.05, function()
		Sfx.play("pulseThump", position)
	end)
	feelBlast(position, radius, K.SHAKE_PULSE, 0.25, Color3.fromRGB(200, 245, 255))
end

-- ---------------------------------------------------------------- boss moments

-- The boss rises out of the deep: a huge upwelling, the water heaving.
K.EVENTS.bossRise = function(position: Vector3, extra)
	local duration = tonumber(extra.duration) or 3
	local at = Vector3.new(position.X, World.WATER_Y + 0.2, position.Z)
	Sfx.play("bossRise", at)
	local steps = math.max(3, math.floor(duration / 0.35))
	for i = 0, steps do
		task.delay(i * 0.35, function()
			local u = i / steps
			Vfx.ring(at, 2 + u * 6, 10 + u * 18, 0.9)
			Vfx.splash(at + Vector3.new((math.random() - 0.5) * 10, 0, (math.random() - 0.5) * 10), 1.5 + u * 2)
			Vfx.burst(at, Vfx.Color.foam, 12)
		end)
	end
	task.delay(duration * 0.85, function()
		Sfx.play("bossRoar", at)
		feelBlast(at, 60, K.SHAKE_RISE, 0.6, Color3.fromRGB(180, 230, 220))
	end)
end

-- The tell before an attack: a coloured flash at the boss and, for the
-- ringed ones, the ring on the ground it's about to hit.
K.EVENTS.telegraph = function(position: Vector3, extra)
	local kind = tostring(extra.kind)
	local duration = tonumber(extra.duration) or 0.8
	local radius = tonumber(extra.radius)
	-- Rimefang borrows six of the kinds below, and the stock draws are right
	-- for the bosses they were built for. A whale-shaped version of each is
	-- drawn instead when the payload is one of its (see RIME_TELL); anything
	-- it does not recognise falls through here untouched.
	if rimeTelegraph(kind, position, extra) then
		return
	end
	Sfx.play("bossTell", position)
	-- ...and Noctyss borrows two of them (`mark`, `ringTell`) for the only
	-- two shapes in her book the shared handlers draw. Hers are drawn as
	-- edge+fill off ONE brightness ramp instead - see K.choirTell, down in
	-- the choir section. Keyed on her light's skin and nothing else, so every
	-- other boss on both kinds falls straight through to the stock draw.
	if K.choirTell(kind, position, extra, duration) then
		return
	end
	if kind == "slam" and radius then
		local point = surfaceUnder(position)
		local pulses = math.max(1, math.floor(duration / 0.3))
		for i = 0, pulses - 1 do
			task.delay(i * 0.3, function()
				Vfx.ring(point + Vector3.new(0, 0.15, 0), radius * 0.9, radius, 0.3, K.COLOR.ember)
			end)
		end
		Vfx.flash(position + Vector3.new(0, 2, 0), K.COLOR.ember, 4, duration)
	elseif kind == "tail" and radius then
		-- The lash's reach, pulsing: get outside it.
		local point = surfaceUnder(position)
		local pulses = math.max(1, math.floor(duration / 0.3))
		for i = 0, pulses - 1 do
			task.delay(i * 0.3, function()
				Vfx.ring(point + Vector3.new(0, 0.15, 0), radius * 0.85, radius, 0.3, K.COLOR.ember)
			end)
		end
		Vfx.flash(position, K.COLOR.ember, 3, duration)
	elseif kind == "burst" and radius then
		-- The dive has locked under someone's feet: a fast-pulsing ring on
		-- the surface there for the lock window, then it bursts.
		local point = surfaceUnder(position)
		local pulses = math.max(1, math.floor(duration / 0.18))
		for i = 0, pulses - 1 do
			task.delay(i * 0.18, function()
				Vfx.ring(point + Vector3.new(0, 0.15, 0), radius * 0.3, radius, 0.2, K.COLOR.brine)
				Vfx.puff(point + Vector3.new(0, 0.1, 0), Vfx.Color.foam, 1.2)
			end)
		end
		Sfx.play("bossTell", position)
	elseif kind == "pull" then
		Vfx.flash(position + Vector3.new(0, 4, 0), skinColor(extra), 5, duration)
	elseif kind == "dive" then
		Vfx.flash(position, Vfx.Color.foam, 3, duration)
	elseif kind == "snap" then
		Vfx.flash(position + Vector3.new(0, 1, 0), Vfx.Color.foam, 3, duration)
	elseif kind == "mark" and radius then
		-- A boss-arsenal strike's landing marker: a pulsing ring at the
		-- point for the whole arm window - be somewhere else when it closes.
		local point = surfaceUnder(position)
		local color = skinColor(extra)
		local pulses = math.max(1, math.floor(duration / 0.22))
		for i = 0, pulses - 1 do
			task.delay(i * 0.22, function()
				Vfx.ring(point + Vector3.new(0, 0.15, 0), radius * 0.35, radius, 0.24, color)
			end)
		end
	elseif kind == "ringTell" and radius then
		-- An expanding-nova band: the danger is the annulus between `inner`
		-- and `radius` - safe inside it AND outside it.
		local point = surfaceUnder(position)
		local color = skinColor(extra)
		local inner = tonumber(extra.inner) or radius * 0.7
		-- THE SAFE GAP. A nova with a hole in it is a different attack from a
		-- nova without one, and a ring drawn all the way round says the wrong
		-- one: the answer is not "be inside or outside", it is "be in the
		-- gap". `gapFrom` / `gapTo` are bearings in radians; when they are
		-- present the band is drawn as ARC SEGMENTS that stop at the gap's
		-- edges, so the opening is a hole you can see rather than a fact you
		-- have to be told.
		local gapFrom = tonumber(extra.gapFrom)
		local gapTo = tonumber(extra.gapTo)
		local pulses = math.max(1, math.floor(duration / 0.25))
		for i = 0, pulses - 1 do
			task.delay(i * 0.25, function()
				if gapFrom and gapTo then
					-- The dangerous arc is everything OUTSIDE [gapFrom, gapTo],
					-- walked as small rings on the band's midline. 24 steps is
					-- one every 15 degrees at the coarsest, which reads as a
					-- continuous wall at the radii this fight uses.
					local mid = (inner + radius) * 0.5
					local thick = math.max((radius - inner) * 0.5, 1.5)
					local span = (gapTo - gapFrom) % (math.pi * 2)
					for step = 0, 23 do
						local theta = gapTo + ((step + 0.5) / 24) * (math.pi * 2 - span)
						Vfx.ring(
							point + Vector3.new(math.cos(theta) * mid, 0.15, math.sin(theta) * mid),
							thick * 0.4,
							thick,
							0.28,
							color
						)
					end
				else
					Vfx.ring(point + Vector3.new(0, 0.15, 0), inner, radius, 0.28, color)
				end
			end)
		end
	elseif kind == "coneTell" and radius then
		-- A directional wedge (cone breath, an aimed grab): flashes marching
		-- out along the facing for the whole windup - step OUT of the line.
		local facing = if typeof(extra.facing) == "Vector3" then extra.facing else Vector3.zAxis
		local point = surfaceUnder(position)
		local color = skinColor(extra)
		local pulses = math.max(1, math.floor(duration / 0.22))
		for i = 0, pulses - 1 do
			task.delay(i * 0.22, function()
				for step = 1, 3 do
					local at = point + facing * (radius * step / 3)
					Vfx.ring(at + Vector3.new(0, 0.15, 0), 1, 2 + step, 0.2, color)
				end
			end)
		end
	elseif kind == "gustTell" and radius then
		-- Wind gathering: an in-rushing ring + rising puffs, then the shove.
		local point = surfaceUnder(position)
		local color = skinColor(extra)
		Vfx.shockwave(position + Vector3.new(0, 2, 0), radius, 3, duration, color, 0.5)
		local pulses = math.max(1, math.floor(duration / 0.25))
		for i = 0, pulses - 1 do
			task.delay(i * 0.25, function()
				Vfx.puff(point + Vector3.new(0, 0.4, 0), color, 1.4)
			end)
		end
	else
		Vfx.flash(position + Vector3.new(0, 2, 0), skinColor(extra), 3, duration)
	end
end

-- The jaw snap: same as the mimic's bite but bigger.
K.EVENTS.bossSnap = function(position: Vector3)
	Vfx.flash(position, Vfx.Color.foam, 4, 0.12)
	Vfx.puff(position, Vfx.Color.foam, 3)
	Vfx.burst(position, K.COLOR.brine, 20)
	Sfx.play("bossSnap", position)
end

-- The tail lash: a ring that sweeps out round the boss.
K.EVENTS.sweep = function(position: Vector3, extra)
	local radius = tonumber(extra.radius) or 16
	local point = surfaceUnder(position)
	Vfx.shockwave(point + Vector3.new(0, 0.5, 0), 3, radius, 0.4, Vfx.Color.foam, 0.6)
	Vfx.ring(point + Vector3.new(0, 0.2, 0), 3, radius, 0.5)
	Vfx.burst(position, Vfx.Color.foam, 30)
	Sfx.play("bossSweep", position)
	feelBlast(position, radius, K.SHAKE_PULSE, 0.25, Color3.fromRGB(220, 240, 255))
end

-- The tidal slam: the big one.
K.EVENTS.slam = function(position: Vector3, extra)
	-- A whale landing flat on sea ice is not a tidal slam: it BREAKS THE
	-- SHEET, and the cracks stay for the window it opens.
	if rimeSlam(position, extra) then
		return
	end
	local radius = tonumber(extra.radius) or 20
	local point = surfaceUnder(position)
	Vfx.flash(position, K.COLOR.ember, 6, 0.15)
	Vfx.shockwave(point + Vector3.new(0, 0.4, 0), 2, radius, 0.55, Vfx.Color.foam, 0.8)
	Vfx.ring(point + Vector3.new(0, 0.2, 0), 2, radius * 1.2, 0.8)
	Vfx.burst(position, Vfx.Color.foam, 50)
	for i = 1, 6 do
		local a = (i / 6) * math.pi * 2
		Vfx.splash(point + Vector3.new(math.cos(a) * radius * 0.45, 0.2, math.sin(a) * radius * 0.45), 2)
	end
	Sfx.play("bossSlam", position)
	task.delay(0.08, function()
		Sfx.play("explodeBoom", position)
	end)
	feelBlast(position, radius, K.SHAKE_SLAM, 0.5, Color3.fromRGB(220, 235, 255))
end

-- THE SKYFALL'S SHOCKWAVE: a ring of broken sheet running out from where the
-- whale landed, to `radius` over `duration`. Its own kind rather than a flag
-- on `slam`, because it is a SECOND hit arriving on a second clock - light,
-- late, and outrunnable - and drawing it off the slam's payload would mean
-- guessing when it started. Dead until the server lane lands it; that is
-- expected. See K.startRimeShock, in the Rimefang section.
K.EVENTS.rimeShock = function(position: Vector3, extra)
	K.startRimeShock(position, extra)
end

-- THE FLOE GOES. Rimefang's phase-two opener, fired ONCE from the arena
-- CENTRE with the whole sheet's radius and the four thin-ice hubs: the splits
-- run out to the rim and the four patches break open into water that stays
-- open for the rest of the fight. Its own kind, and not a flag on the slam
-- that causes it, because a slam is a place with a radius somebody has to
-- leave and this is the ARENA being rewritten - nothing here damages anyone.
-- See K.startRimeShatter, in the Rimefang section.
K.EVENTS.rimeShatter = function(position: Vector3, extra)
	K.startRimeShatter(position, extra)
end

-- The lure pull: drag the local character toward the maw for `duration`.
K.EVENTS.pull = function(position: Vector3, extra)
	local radius = tonumber(extra.radius) or 40
	local strength = tonumber(extra.strength) or 25
	local duration = tonumber(extra.duration) or 2
	if localDistance(position) <= radius then
		beginPull(position, radius, strength, duration, extra.braced)
	end
	-- ON THE FLOOR, NOT AT THE PIVOT. `lurepull` is the only move in Noctyss's
	-- book with no damage, no dodge and no counterplay, so the in-rushing wave
	-- is its entire explanation - and it was being drawn at the boss model's
	-- pivot, which `placeColossus` parks at the submerged maw ~20 studs INSIDE
	-- the shelf. Twenty studs of rock between the player and the only thing
	-- that says why they are sliding.
	--
	-- Her rim mark (the `mark` telegraph K.choirTell just drew, radius
	-- PIT_R + 3) already probed the rim this attack pulls toward, so the wave
	-- is drawn THERE when it is fresh; anything else - every other boss's
	-- pull, and hers if the mark was culled by distance - falls back to a
	-- cast under the payload. The drag itself is untouched: stepPull's force
	-- is flat over the radius, so this is a visual correction only.
	--
	-- FRESH IS NOT ENOUGH: the cache outlives the arena it was drawn in, so a
	-- rim probed in one Choirfloor could place a pull's wave in another. The
	-- rim mark is centred on the pit, which is the arena's centre, and this
	-- arena's stone ends at r68 - so a cached rim further than CHOIR_RIM_NEAR
	-- from the payload belongs to somewhere else and is ignored.
	local at = if K.choirRim
			and os.clock() - K.choirRim.at_ <= 4
			and (K.choirRim.at - position).Magnitude <= K.CHOIR_RIM_NEAR
		then K.choirRim.at
		else surfaceUnder(position)
	Vfx.shockwave(at + Vector3.new(0, 3, 0), radius, 2, duration, K.COLOR.brine, 0.35)
	Sfx.play("pulseZap", position)
end

-- A spine leaves the boss: fly it (a bone sliver) to `to`.
K.EVENTS.spine = function(position: Vector3, extra)
	if typeof(extra.to) ~= "Vector3" then
		return
	end
	launchGlob(position, extra.to, tonumber(extra.flight) or 0.8, tonumber(extra.arc) or 10, true, true)
end

-- Where a spine counted (the glob itself lands on the client's clock).
K.EVENTS.spineHit = function(position: Vector3, extra)
	local radius = tonumber(extra.radius) or 4
	Vfx.ring(position + Vector3.new(0, 0.15, 0), 1, radius, 0.4, K.COLOR.bone)
end

-- It coughs up brood.
K.EVENTS.summon = function(position: Vector3)
	Vfx.puff(position, K.COLOR.brine, 2.5)
	Vfx.burst(position, K.COLOR.brine, 24)
	Vfx.splash(position, 1.5)
	Sfx.play("emerge", position)
end

-- It goes under for the ambush.
K.EVENTS.bossDive = function(position: Vector3)
	local at = Vector3.new(position.X, World.WATER_Y + 0.2, position.Z)
	Vfx.splash(at, 4)
	Vfx.ring(at, 3, 14, 0.8)
	Sfx.play("burrow", at)
end

-- Below its enrage threshold.
K.EVENTS.enrage = function(position: Vector3)
	Vfx.flash(position + Vector3.new(0, 2, 0), K.COLOR.rage, 8, 0.4)
	Vfx.burst(position + Vector3.new(0, 2, 0), K.COLOR.rage, 60)
	Sfx.play("bossRoar", position)
	feelBlast(position, 60, K.SHAKE_RISE, 0.5, Color3.fromRGB(255, 120, 100))
end

-- Dead. (BossHudController shows the banner.)
K.EVENTS.bossDown = function(position: Vector3)
	local at = Vector3.new(position.X, World.WATER_Y + 0.2, position.Z)
	Vfx.flash(at + Vector3.new(0, 3, 0), K.COLOR.brine, 10, 0.5)
	Vfx.burst(at + Vector3.new(0, 2, 0), K.COLOR.brine, 80)
	Vfx.ring(at, 4, 30, 1.2)
	for i = 1, 5 do
		task.delay(i * 0.12, function()
			Vfx.splash(at + Vector3.new((math.random() - 0.5) * 12, 0, (math.random() - 0.5) * 12), 3)
		end)
	end
	Sfx.play("bossDown", at)
	feelBlast(at, 80, K.SHAKE_SLAM, 0.7, Color3.fromRGB(200, 255, 235))
end

-- The Kraken's exposure window opens: the last tentacle is down and the
-- head can be hurt (BossHudController shows the card).
K.EVENTS.exposed = function(position: Vector3)
	local at = position + Vector3.new(0, 3, 0)
	Vfx.flash(at, Color3.fromRGB(255, 210, 110), 9, 0.5)
	Vfx.burst(at, Color3.fromRGB(255, 210, 110), 50)
	Sfx.play("bossRoar", position)
end

-- A displacement shove (the kit engine's gustpush): the pull machinery run
-- in reverse - the local character is blown OUT of the radius. `cone` gusts
-- only move you when you stand inside the wedge.
K.EVENTS.gust = function(position: Vector3, extra)
	local radius = tonumber(extra.radius) or 14
	local push = tonumber(extra.push) or 42
	local duration = tonumber(extra.duration) or 0.4
	local inRange = localDistance(position) <= radius
	if inRange and typeof(extra.facing) == "Vector3" and tonumber(extra.cone) then
		local root = localRoot()
		if root then
			local to = Vector3.new(root.Position.X - position.X, 0, root.Position.Z - position.Z)
			if
				to.Magnitude > 0.01
				and math.acos(math.clamp(to.Unit:Dot(extra.facing), -1, 1)) > tonumber(extra.cone)
			then
				inRange = false
			end
		end
	end
	-- VESTIGIAL, AND DELIBERATELY LEFT STANDING. This exempted players whose
	-- cover held from the wash's shove, back when Rimefang's floe had bergs
	-- and a frozen whaler on it to hide behind. The arena has no furniture any
	-- more and the wash's answer is sidestepping, so no server that has taken
	-- the new kit will ever name anyone here - but a server that has NOT taken
	-- it yet still shelters players, and dropping this would shove someone the
	-- server did not. It costs one type test against a field nobody sends.
	if inRange and type(extra.sheltered) == "table" then
		for _, userId in extra.sheltered do
			if userId == player.UserId then
				inRange = false
				break
			end
		end
	end
	if inRange then
		beginPull(position, radius, -push, duration)
	end
	-- Rimefang's wash is a WALL, not a ring: it draws its own advancing crest
	-- and takes the moment, because a radial shockwave over the top of it
	-- would teach the wrong answer (leave the circle, rather than get behind
	-- something). Every other gust falls straight through, unchanged.
	if startWash(position, extra) then
		return
	end
	local color = skinColor(extra)
	Vfx.shockwave(position + Vector3.new(0, 2, 0), 2, radius, duration, color, 0.35)
	Vfx.puff(position + Vector3.new(0, 1, 0), color, 2.2)
	Sfx.play("pulseZap", position)
end

-- A gas cloud's lingering puff (fired by the gascloud archetype since S4;
-- rendered for the first time with the kit engine pass).
K.EVENTS.gasPuff = function(position: Vector3, extra)
	local radius = tonumber(extra.radius) or 6
	local lifetime = tonumber(extra.lifetime) or 4
	local point = surfaceUnder(position)
	local color = Color3.fromRGB(150, 168, 120)
	local pulses = math.max(2, math.floor(lifetime / 0.6))
	for i = 0, pulses - 1 do
		task.delay(i * 0.6, function()
			Vfx.puff(point + Vector3.new(0, 0.6, 0), color, radius * 0.35)
		end)
	end
	Vfx.ring(point + Vector3.new(0, 0.15, 0), radius * 0.5, radius, 0.5, color)
end

-- The Slagheart's crust breaking: shards off the shell, the core exposed
-- (the Cracked attribute drives the glow; this is the moment).
K.EVENTS.crustCrack = function(position: Vector3)
	Vfx.burst(position + Vector3.new(0, 2, 0), Color3.fromRGB(60, 62, 74), 40)
	Vfx.flash(position + Vector3.new(0, 2, 0), Color3.fromRGB(255, 120, 40), 5, 0.3)
	Sfx.play("hitCrack", position)
end

-- The Phoenix (and any reborn) getting back up: an ember pillar.
K.EVENTS.rebornRise = function(position: Vector3)
	for i = 0, 3 do
		task.delay(i * 0.12, function()
			Vfx.flash(position + Vector3.new(0, 2 + i * 2.5, 0), Color3.fromRGB(255, 140, 60), 4, 0.3)
		end)
	end
	Vfx.burst(position + Vector3.new(0, 2, 0), Color3.fromRGB(255, 140, 60), 60)
	Sfx.play("bossRise", position)
end

-- ---------------------------------------------------- boss arsenal moments
-- (the per-island movesets, 2026-08-27; every one carries `skin`)

-- The decoy lures / powder kegs currently afloat, oldest first.
local decoyParts: { Part } = {}

local function nearestDecoy(position: Vector3, within: number): (number?, Part?)
	local bestIdx, bestDist = nil, within
	for i, part in decoyParts do
		local d = (part.Position - position).Magnitude
		if d <= bestDist then
			bestIdx, bestDist = i, d
		end
	end
	return bestIdx, bestIdx and decoyParts[bestIdx]
end

-- A lingering ground hazard: bubbling rings for its whole lifetime.
K.EVENTS.poolSpawn = function(position: Vector3, extra)
	local radius = tonumber(extra.radius) or 6
	local duration = math.min(tonumber(extra.duration) or 5, 20)
	local color = skinColor(extra)
	local point = surfaceUnder(position)
	Vfx.puff(point + Vector3.new(0, 0.2, 0), color, 1.6)
	Sfx.play("spitSplashGround", point)
	task.spawn(function()
		local t0 = os.clock()
		while os.clock() - t0 < duration do
			Vfx.ring(point + Vector3.new(0, 0.15, 0), radius * 0.45, radius, 0.6, color)
			Vfx.puff(
				point + Vector3.new((math.random() - 0.5) * radius, 0.2, (math.random() - 0.5) * radius),
				color,
				0.9
			)
			task.wait(0.5)
		end
	end)
end

-- A boss-arsenal strike lands (root spear, berg, cannonball, lightning...).
K.EVENTS.strikeHit = function(position: Vector3, extra)
	local radius = tonumber(extra.radius) or 6
	local color = skinColor(extra)
	Vfx.flash(position + Vector3.new(0, 1, 0), color, 4, 0.14)
	Vfx.ring(position + Vector3.new(0, 0.2, 0), 1, radius, 0.4, color)
	Vfx.burst(position + Vector3.new(0, 0.5, 0), color, 22)
	Sfx.play("bossGlobThud", position)
	feelBlast(position, radius, K.SHAKE_PULSE, 0.25, color)
end

-- Noctyss's ink shell: the strike, plus a blot of dark across the screen of
-- anyone caught inside it.
K.EVENTS.inkBlast = function(position: Vector3, extra)
	local radius = tonumber(extra.radius) or 8
	K.EVENTS.strikeHit(position, extra)
	if localDistance(position) <= radius then
		flashFrame.BackgroundColor3 = Color3.fromRGB(16, 8, 26)
		flashFrame.BackgroundTransparency = 0.12
		TweenService:Create(flashFrame, TweenInfo.new(2.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			BackgroundTransparency = 1,
		}):Play()
	end
end

-- A chilling wash (Rimefang's breath / a frost slick / clinging sludge):
-- slow yourself if you're inside it.
K.EVENTS.chill = function(position: Vector3, extra)
	local radius = tonumber(extra.radius) or 5
	if localDistance(position) <= radius then
		applyMoveEffect(math.clamp(tonumber(extra.mult) or 0.55, 0.05, 1), tonumber(extra.duration) or 1.2)
		local root = localRoot()
		if root then
			Vfx.puff(root.Position - Vector3.new(0, 2.2, 0), skinColor(extra), 0.8)
		end
	end
end

-- Gnashroot's snare closes: whoever is still inside is rooted to the spot.
K.EVENTS.snare = function(position: Vector3, extra)
	local radius = tonumber(extra.radius) or 6
	local duration = tonumber(extra.duration) or 1.5
	local color = skinColor(extra)
	Vfx.burst(position + Vector3.new(0, 0.4, 0), color, 26)
	Vfx.ring(position + Vector3.new(0, 0.2, 0), radius * 0.5, radius, 0.5, color)
	Sfx.play("bossSpineHit", position)
	if localDistance(position) <= radius then
		applyMoveEffect(0, duration)
		local root = localRoot()
		if root then
			Vfx.burst(root.Position - Vector3.new(0, 2, 0), color, 18)
		end
		feelBlast(position, radius, K.SHAKE_PULSE, 0.2, color)
	end
end

-- Wrack's anchor chain: leash yourself to the anchor if it caught you.
K.EVENTS.chain = function(position: Vector3, extra)
	local radius = tonumber(extra.radius) or 10
	local leash = tonumber(extra.leash) or 13
	local duration = tonumber(extra.duration) or 3.5
	local point = surfaceUnder(position)
	Vfx.burst(point + Vector3.new(0, 0.5, 0), K.SKIN.wreck, 30)
	Vfx.ring(point + Vector3.new(0, 0.2, 0), 1.5, leash, 0.6, K.SKIN.wreck)
	Sfx.play("bossGlobThud", position)
	if localDistance(position) <= radius then
		chainState = {
			center = position,
			leash = leash,
			until_ = os.clock() + duration,
			nextRingAt = 0,
		}
		feelBlast(position, radius, K.SHAKE_PULSE, 0.3, K.SKIN.wreck)
	end
end

-- A decoy lure / powder keg surfaces.
K.EVENTS.decoy = function(position: Vector3, extra)
	local color = skinColor(extra, K.SKIN.lure)
	local part = Instance.new("Part")
	part.Name = "BossDecoy"
	part.Shape = Enum.PartType.Ball
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Size = Vector3.new(1.6, 1.6, 1.6)
	part.CFrame = CFrame.new(position)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = 4
	light.Range = 16
	light.Parent = part
	part.Parent = folder
	table.insert(decoyParts, part)
	Vfx.splash(Vector3.new(position.X, World.WATER_Y + 0.2, position.Z), 1.5)
	Sfx.play("bossTell", position)
	-- Backstop: if its pop never arrives (stream-out), fade it on its own.
	task.delay((tonumber(extra.lifetime) or 12) + 3, function()
		local idx = table.find(decoyParts, part)
		if idx then
			table.remove(decoyParts, idx)
			part:Destroy()
		end
	end)
end

-- A drifting keg moved (low-cadence mirror of the server's drift).
K.EVENTS.decoyMove = function(position: Vector3)
	local _, part = nearestDecoy(position, 7)
	if part then
		TweenService:Create(part, TweenInfo.new(0.32, Enum.EasingStyle.Linear), {
			CFrame = CFrame.new(position),
		}):Play()
	end
end

-- ...and detonates (or fizzles out at the end of its fuse).
K.EVENTS.decoyPop = function(position: Vector3, extra)
	local idx, part = nearestDecoy(position, 9)
	if idx and part then
		table.remove(decoyParts, idx)
		part:Destroy()
	end
	local color = skinColor(extra, K.SKIN.lure)
	if extra.fizzle then
		Vfx.puff(position, color, 1.4)
		return
	end
	local radius = tonumber(extra.radius) or 10
	Vfx.flash(position, color, 6, 0.15)
	Vfx.shockwave(position, 1.5, radius, 0.45, color, 0.6)
	Vfx.burst(position, color, 36)
	Sfx.play("explodeBoom", position)
	feelBlast(position, radius, K.SHAKE_EXPLODE, 0.35, color)
end

-- One tick of a swept jet (magma / frost breath): the burning line itself.
K.EVENTS.beam = function(position: Vector3, extra)
	if typeof(extra.to) ~= "Vector3" then
		return
	end
	local color = skinColor(extra)
	local to = extra.to
	local span = to - position
	local length = span.Magnitude
	if length < 1 then
		return
	end
	local dir = span / length
	Vfx.flash(position, color, 3, 0.12)
	for d = 4, length, 5 do
		local at = position + dir * d
		Vfx.puff(at, color, 1.0)
	end
	Vfx.ring(surfaceUnder(to) + Vector3.new(0, 0.15, 0), 1, 4, 0.25, color)
	Sfx.play("pulseZap", position)
end

-- Noctyss douses every light in the water and vanishes...
K.EVENTS.phantomOut = function(position: Vector3, extra)
	Vfx.splash(Vector3.new(position.X, World.WATER_Y + 0.2, position.Z), 2.5)
	Sfx.play("burrow", position)
	if localDistance(position) <= (tonumber(extra.radius) or 60) then
		flashFrame.BackgroundColor3 = Color3.fromRGB(4, 3, 8)
		flashFrame.BackgroundTransparency = 0.2
		TweenService:Create(flashFrame, TweenInfo.new(1.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			BackgroundTransparency = 1,
		}):Play()
	end
end

-- ...and surfaces at somebody's flank, jaws first.
K.EVENTS.phantomIn = function(position: Vector3, extra)
	local radius = tonumber(extra.radius) or 15
	local at = Vector3.new(position.X, World.WATER_Y + 0.2, position.Z)
	Vfx.splash(at, 3)
	Vfx.ring(at, 2, radius * 0.7, 0.5)
	Vfx.burst(position + Vector3.new(0, 1, 0), skinColor(extra), 30)
	Sfx.play("emerge", position)
	feelBlast(position, radius, K.SHAKE_EMERGE_BIG, 0.3, Color3.fromRGB(120, 80, 180))
end

-- ...and closes: the tentacle ring re-plants around the arena.
K.EVENTS.regrow = function(position: Vector3, extra)
	-- AN ARM WITHDRAWING IS NOT A THING REGROWING, and drawing it as one is
	-- the difference between "the Kraken pulled its arm back into the sea" and
	-- "a new arm popped into existence where the old one died". The limb
	-- itself is already sliding home - the body controller eases it into the
	-- Withdrawn pose off ArmPhase - so all this owes it is the water closing
	-- over it, once, at the point it left from, and none of the ring of
	-- surfacing splashes below.
	if extra.withdraw == true then
		Vfx.splash(position, 5)
		Vfx.ring(surfaceUnder(position) + Vector3.new(0, 0.15, 0), 3, 22, 0.9, K.SKIN.kraken)
		Vfx.puff(position, Vfx.Color.foam, 2.2)
		Sfx.play("bossDown", position)
		return
	end
	local count = tonumber(extra.count) or 6
	for i = 1, count do
		local angle = (i / count) * math.pi * 2
		local at = position + Vector3.new(math.cos(angle) * 26, 0, math.sin(angle) * 26)
		task.delay(i * 0.08, function()
			Vfx.splash(at, 4)
			Vfx.ring(at, 2, 8, 0.5)
		end)
	end
	Sfx.play("bossRise", position)
end

-- ------------------------------------------------- Brinejaw (the cove boss)
--
-- The serpent coiled round the Tidebreak Spire fights by RE-POSING itself:
-- the coils and the sweeping tail are one chain (BrinejawBodyController draws
-- it from BrinejawPath), so nothing ever spawns and none of these moments is
-- a projectile - every one is a MARKER, and its only job is to say what the
-- answer is, from ground level, in time to move.
--
--   serpentSweep  the tail scythes round the arena - JUMP it, or STAND under
--                 it, and which one is the whole fight (see the read below)
--   serpentSlam   the rattle comes down on a point - be elsewhere, unless you
--                 baited it onto a reef stone, which is how the fight is won
--   bossStagger   it lost its grip and the head is on the sand: the window
--   bossStance    the whole stack slid a turn down the tower
--   reefShatter   a stone spent
--   bossCollapse  the death slide
--
-- THE LOW/HIGH READ. Both sweeps are the same arm on the same bearing, so
-- colour alone would not survive a glance across 60 studs of sand. They are
-- drawn as different SHAPES IN SPACE instead, each one the answer it wants:
--   LOW  - a solid wall standing on the sand, hot orange. There is no way
--          through it at ground level, so the only read is "get over this".
--   HIGH - a slim cyan rail up at the arm's own height with nothing at all
--          underneath it but its shadow on the sand. The empty air IS the
--          message, and the shadow is what proves the rail is up there
--          (depth reads badly from ground level; a cast shadow does not).
-- A low arm also ploughs the sand it drags through; a high one leaves the
-- ground untouched. Getting this backwards kills you, so nothing here is
-- subtle on purpose.

K.BRINE = {
	low = Color3.fromRGB(255, 96, 62), -- a wall on the sand: JUMP IT
	high = Color3.fromRGB(120, 236, 255), -- a rail overhead: STAND STILL
	shadow = Color3.fromRGB(26, 32, 40), -- what a high arm casts on the sand
	bait = Color3.fromRGB(255, 214, 110), -- a slam baited onto a stone: YES
	slam = Color3.fromRGB(255, 122, 60), -- ...and one about to waste itself
	window = Color3.fromRGB(255, 214, 110), -- the stagger: hit it, now
	stone = Color3.fromRGB(150, 146, 136), -- reef rock and tower masonry
}

-- THE SLAM'S TWO ANSWERS, and they have to be readable as two. `BRINE.bait` is
-- the gold every "you got it right" in the game wears; this is the other one,
-- and it is a RED rather than BRINE.slam's orange, because BRINE.slam also
-- paints the masonry markers and next to gold an orange reads as a dimmer gold
-- rather than as a refusal. (BRINE.slam is left exactly as it is: the rain pool
-- is built from it in init and another lane's uncommitted work indexes it.)
K.SLAM_SAND = Color3.fromRGB(255, 78, 58)
-- The reef stones lit through a slam's windup: hot, and NOT the gold of the
-- marker itself - the stones are the thing to aim at, the marker is the answer.
K.STONE_GLOW = Color3.fromRGB(255, 176, 72)
K.STONE_MAX = 12 -- the brine arena lists 8 cover pieces; 12 is that plus slack
K.STONE_PULSE = 8.5 -- rad/s of the bait glow's throb

-- Draw ranges. The arena is huge and these fire every few seconds, so each
-- handler is skipped outright past its own reach plus a margin.
K.BRINE_MARGIN = 90 -- how far outside an effect's own footprint it still draws
K.BRINE_CULL = 240 -- the flat range for the whole-arena moments

-- The swept marker: rungs laid along the band from `inner` to `reach`, the
-- whole ladder swinging round the tower like the hand it is.
K.SWEEP_SLOTS = 2 -- constrict chases a slow high sweep with a fast low one
K.SWEEP_RUNGS = 16
K.SWEEP_LEAD = 0.5 -- seconds the marker runs AHEAD of the arm
K.SWEEP_GIRTH = 3.4 -- fallback half-thickness if a row sends none
K.SWEEP_LOW_TOP = 3.2 -- a low wall stands this far above the arm's line
-- A HIGH RAIL IS DRAWN AT ITS TRUE THICKNESS. It used to be 1.4 studs -
-- deliberately slim, so the shape alone said "this one passes overhead" - but
-- the band that actually hurts you is `girth * 2`, which is 7.2. That is 2.9
-- studs of invisible hazard above the rail and 2.9 below it, and at the top of
-- a jump a player's root sits exactly in that margin: you watch yourself clear
-- the rail by a hair and take the hit anyway. The read survives the honest
-- thickness, because what sells "stand still" is the clear air underneath it
-- rather than how thin the rail is.
K.SWEEP_SHADOW_THICK = 0.1
K.SWEEP_FADE = 0.3 -- how long the marker takes to leave once the arm is done
K.SWEEP_DUST_INTERVAL = 0.07 -- sand thrown by a low arm ploughing through it
K.SWEEP_PULSE = 11 -- rad/s of the marker's urgency throb

-- The punish window: a disc of the payoff colour under the slumped head that
-- closes as the window does, so the time left is readable without any HUD.
K.STAGGER_RADIUS = 13
K.STAGGER_BLOOM_INTERVAL = 0.55

-- Pooled marker parts live down here when idle - the glob pool's pattern:
-- built in init, moved in Heartbeat, never churned.
K.PARKED = CFrame.new(0, -5000, 0)

-- One sweep in flight: everything the payload said, plus when it started.
local sweeps: { any } = {}
local sweepPool: { any } = {}

-- The open stagger window, if one is.
local stagger: any = nil
local staggerRing: Part

local function makeMarker(name: string, color: Color3, neon: boolean): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = if neon then Enum.Material.Neon else Enum.Material.SmoothPlastic
	part.Color = color
	part.Transparency = 1
	part.Size = Vector3.new(1, 1, 1)
	part.CFrame = K.PARKED
	part.Parent = folder
	return part
end

local function parkParts(parts: { Part })
	for _, part in parts do
		part.Transparency = 1
		part.CFrame = K.PARKED
	end
end

-- ------------------------------------------------------- the attack-fx pack
--
-- User, 2026-09-08: "get rid of these blue walls and instead make it more
-- immersive by creating blender models and animations for the attacks
-- themselves." Brinejaw's storm has always drawn itself out of axis-aligned
-- boxes: a slab for the ring wave's wall, a column of Neon water for each
-- ground eruption, a white box for a spine. `assets/brinejaw_fx_gen.py` now
-- authors the meshes those boxes stood in for, and everything below clones
-- them - a stone spike for the eruption, a curling crest shell for the wall,
-- a barbed blade for a spine, broken masonry for the rain.
--
-- IT IS NOT IMPORTED YET, AND THAT IS THE WHOLE DESIGN OF THIS HELPER. Until
-- someone drags the glb into ReplicatedStorage/Assets/BrinejawFxPack, every
-- call below returns the EXACT part this file built before the pack existed -
-- same name, same colour, same Neon flag - so the fight looks precisely as it
-- does today rather than half-swapped. This is BrinejawBodyController's
-- `makePiece` pattern (clone-or-fallback, repaint from MeshColors, drop any
-- SurfaceAppearance), and it is the pattern rather than a call into it
-- because that one is private to the body and keyed on the boss's prefix.
K.FX_PACK = "BrinejawFxPack"
K.FX_PREFIX = "BrinejawFx_"
-- Generated from brinejaw_fx_gen.py by tools/gen_mesh_colors.py. Studio's
-- glTF importer drops colour outright, so without this every cloned piece is
-- Roblox grey - which reads as the import having failed rather than as a
-- missing repaint.
K.MeshColors = require(Shared.Config.MeshColors)
-- Set once in `init`. Two of the handlers below do not merely swap a part for
-- a nicer part, they draw a DIFFERENT ANIMATION when the pack is there (the
-- eruption is the named one), and a per-frame `FindFirstChild` walk to decide
-- that would be a tree query in a Heartbeat step for an answer that cannot
-- change while the game is running.
K.fxHas = false

K.fxPiece = function(name: string): BasePart?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local pack = assets and assets:FindFirstChild(K.FX_PACK)
	local piece = pack and pack:FindFirstChild(K.FX_PREFIX .. name, true)
	return if piece and piece:IsA("BasePart") then piece else nil
end

-- One pooled piece: the authored mesh if the pack is imported, else exactly
-- the marker this file drew before it existed.
--
-- TWO NEON FLAGS, NOT ONE, and the reason is the point of the whole pack. The
-- crest is Neon today because a flat green slab needs to glow to read as
-- water at all; the mesh does not, and painting the authored sea-green
-- (34, 104, 96) onto a Neon part would produce a dark glowing wall - which is
-- the "blue wall" complaint again in a different colour. So the fallback
-- keeps the flag it has always had and the clone gets its own. Where the two
-- agree (the gap-lane markers, which are a SAFETY read and glow in both
-- worlds) they are simply passed the same value.
K.fxMarker = function(fxName: string, markerName: string, color: Color3, neon: boolean, meshNeon: boolean): Part
	local template = K.fxPiece(fxName)
	if not template then
		return makeMarker(markerName, color, neon)
	end
	local part = template:Clone()
	part.Name = markerName
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = if meshNeon then Enum.Material.Neon else Enum.Material.SmoothPlastic
	-- BY THE PACK NAME, not `part.Name`: the rename above has already happened
	-- by the time anything could look the colour up the other way, and a
	-- `part.Name` lookup would return nil here while appearing to work. That
	-- is MeshColors' own header warning, in the one file that could hit it.
	part.Color = K.MeshColors.get(K.FX_PREFIX .. fxName) or color
	local appearance = part:FindFirstChildWhichIsA("SurfaceAppearance")
	if appearance then
		appearance:Destroy()
	end
	part.Transparency = 1
	part.CFrame = K.PARKED
	part.Parent = folder
	return part :: any
end

-- Brinejaw's arena is anchored on the TOWER'S FOOT, not on wherever the head
-- has got to: the sweep carries it in every payload, and every colossus
-- publishes it as PoseCenter (the same attribute BrinejawBodyController reads
-- to know where to stand the body). Falls back to straight down from the boss.
local function towerFoot(position: Vector3): Vector3
	local creatures = Workspace:FindFirstChild(K.CREATURES_FOLDER)
	if creatures then
		local best, bestDist = nil, 140
		for _, model in creatures:GetChildren() do
			local center = model:GetAttribute("PoseCenter")
			if typeof(center) == "Vector3" then
				local d = (model:GetPivot().Position - position).Magnitude
				if d < bestDist then
					best, bestDist = center, d
				end
			end
		end
		if best then
			return best
		end
	end
	return Vector3.new(position.X, surfaceUnder(position).Y, position.Z)
end

-- ------------------------------------------------------------ the orbit sweep

-- One frame of one swept marker. The ladder is drawn at the bearing the arm
-- will be on SWEEP_LEAD seconds from now, so it arrives somewhere before the
-- tail does and there is time to answer it.
local function drawSweep(s, pool, now: number): boolean
	local elapsed = now - s.start
	-- The arm HOLDS on the start bearing for `windup` and only travels the
	-- arc during `travel`. Spreading the arc over the sum instead would run
	-- the marker most of a sweep ahead of the tail, so players would dodge
	-- the warning and get hit by the thing it warned about.
	local total = s.windup + s.travel
	if elapsed > total + K.SWEEP_FADE then
		return false
	end
	local fade = math.clamp((elapsed - total) / K.SWEEP_FADE, 0, 1)
	local u = math.clamp((elapsed - s.windup + K.SWEEP_LEAD) / s.travel, 0, 1)
	local theta = s.angle + s.arc * u
	local cos, sin = math.cos(theta), math.sin(theta)
	-- The rungs point along the bearing: +X of a CFrame turned -theta about Y
	-- is (cos, 0, sin), which is the convention the server's hit test uses.
	local facing = CFrame.Angles(0, -theta, 0)
	local span = (s.reach - s.inner) / K.SWEEP_RUNGS
	local length = span * 0.84
	local pulse = 0.5 + 0.5 * math.sin(now * K.SWEEP_PULSE)
	local base = (if s.high then 0.1 else 0.2) + 0.16 * pulse
	local alpha = base + (1 - base) * fade
	local tall = s.height + K.SWEEP_LOW_TOP
	local band = s.girth * 2

	for i = 1, K.SWEEP_RUNGS do
		local r = s.inner + span * (i - 0.5)
		local ground = s.center.Y + BrinejawPath.sandY(r)
		local x, z = s.center.X + cos * r, s.center.Z + sin * r
		local rung = pool.rungs[i]
		if s.high then
			-- A rail at the arm's own height, and clear air all the way down.
			rung.Size = Vector3.new(length, band, band)
			rung.CFrame = CFrame.new(x, ground + s.height, z) * facing
			local shade = pool.shadows[i]
			shade.Size = Vector3.new(length, K.SWEEP_SHADOW_THICK, band * 0.9)
			shade.CFrame = CFrame.new(x, ground + 0.06, z) * facing
			shade.Transparency = 0.42 + 0.58 * fade
		else
			-- A wall planted ON the sand: bottom flush with the ground, top
			-- just under a jump. Nothing to read here but "get above it".
			rung.Size = Vector3.new(length, tall, band)
			rung.CFrame = CFrame.new(x, ground + tall * 0.5, z) * facing
		end
		rung.Transparency = alpha
	end

	-- ...and a low arm drags the sand it passes through, which is the other
	-- half of the read: the ground itself reacts, or it does not.
	if not s.high and fade <= 0 and now >= s.nextDustAt then
		s.nextDustAt = now + K.SWEEP_DUST_INTERVAL
		for _ = 1, 2 do
			local r = randomBetween(s.inner, s.reach)
			local at = Vector3.new(s.center.X + cos * r, s.center.Y + BrinejawPath.sandY(r) + 0.2, s.center.Z + sin * r)
			Vfx.puff(at, Vfx.Color.sand, 1.1)
		end
	end
	return true
end

-- ---------------------------------------------------------- the choir's beam
--
-- A lantern 35 studs up on a crooked stalk scythes its light across the
-- shelf, and in this fight BEING LIT IS BEING HIT (NoctyssPath.beamHits). So
-- this marker is not decoration - it is the hitbox drawn, and it has to hinge
-- on the same apex the server measures from (the BULB, not the socket in the
-- floor) or the arena teaches players the wrong shape of dark.
K.BEAM_SLOTS = 2
K.BEAM_RUNGS = 12
-- 0.08s, NOT the 0.4 a swept tail wants. Brinejaw's marker leads its arm
-- because the marker is a warning about a solid thing arriving later. Here the
-- light IS the damage, and 0.4s of a 155-degree arc over 2.6s is ~24 degrees
-- of lead against an 18-degree wedge - the drawn beam and the damaging one
-- would never have overlapped at all. A hair of lead is anticipation; more
-- than the wedge's own width is a lie.
K.BEAM_LEAD = 0.08
K.BEAM_FADE = 0.35
K.BEAM_INNER = 5.0 -- NoctyssPath.BEAM_INNER: the pocket under the crook
-- Where to start looking for the floor: just above the Choirfloor's shelf
-- (authored +1.5), so the 8-stud probe lands on stone rather than expiring in
-- the air below a lantern.
K.BEAM_PROBE_Y = 3.0
K.LURE_LIGHT = Color3.fromRGB(255, 226, 130)
-- HER GEOMETRY AND HER TELEGRAPH LANGUAGE, shared with NoctyssBodyController
-- so the two client files that draw this fight speak one dialect: TELL (the
-- three colours and the ramp constants), tellRamp (the one brightness
-- function) and markFloor (the ground probe). A K field, not a top-level
-- local - this file is near Luau's 200-register ceiling and a new local here
-- is a compile error somewhere else.
K.NoctyssPath = require(Shared.Modules.NoctyssPath)
-- THE NEON CEILING, and it is TELL.LIVE_T by construction. Roblox Neon
-- saturates toward white as Transparency falls, so below about 0.25 every
-- colour in this fight renders as the same blown-out paddle - and the near
-- rungs of a wedge are exactly where the ladder used to peak. Nothing in the
-- wedge goes under this but the one opening flash.
K.BEAM_PEAK_T = 0.30

-- THE BEAM CARRIES LIGHT. Noctyss is fought in locked first person in a black
-- arena, so the drawn ladder above is only a warning to a player who happens to
-- be LOOKING at it - and the sweep that kills you comes from behind at least
-- half the time. A lantern's light does not respect a camera frustum: it lands
-- on you before the bulb is in frame. So each live beam drags real PointLights
-- along its own bearing, and the read in the dark is "the room is getting
-- brighter around me" -> move, with no HUD and no need to turn around.
--
-- THREE LAMPS, NOT ONE. Roblox caps PointLight.Range at 60 and the wedge is 74
-- studs long from the apex; a single lamp at the apex would leave the outer
-- third - where the wedge is WIDEST and hardest to cross - completely unlit,
-- which is the one place the tell matters most. Three spread down the length
-- overlap into a continuous wash.
K.BEAM_LAMPS = 3
-- Fractions of (reach - inner) each lamp sits at: near the pocket, mid, and out
-- by the tip. Chosen so consecutive ranges overlap rather than pearl.
K.BEAM_LAMP_AT = { 0.18, 0.50, 0.84 }
-- Off the floor, so the wash climbs a standing player rather than only pooling
-- at their feet (first person sees very little floor).
K.BEAM_LAMP_Y = 3.2
K.BEAM_LAMP_BRIGHT = 3.4
-- Range breathes between these as the wedge widens: `base + width * gain`,
-- where width is the wedge's own half-angle solved at that lamp's radius. The
-- light literally tracks the hitbox getting fatter with distance.
K.BEAM_LAMP_RANGE_MIN = 18
K.BEAM_LAMP_RANGE_MAX = 52
K.BEAM_LAMP_RANGE_GAIN = 1.1
-- THE LEAD IS THE WHOLE POINT, and it is bigger than K.BEAM_LEAD above on
-- purpose. That constant is small because the drawn ladder is the hitbox and a
-- ladder drawn ahead of the damage is a LIE about where the edge is. A glow has
-- no edge to lie with: it is a soft gradient, so running it a quarter-second
-- ahead of the wedge reads as "it is coming" and cannot be mistaken for a
-- safety line. Damage still lands exactly where the rungs are drawn.
K.BEAM_GLOW_LEAD = 0.24
-- ...and it swells in over the cast's first third of a second rather than
-- snapping on, so what a player feels is a RISE. A step change in a black room
-- reads as a flash somewhere else; a rise reads as something approaching.
K.BEAM_GLOW_RISE = 0.34

-- Kills a slot's lamps. EVERY path that stops drawing a beam calls this - the
-- natural expiry in `stepBeams`, and the slot-steal in `choirBeam` when a third
-- stalk fires while two are already sweeping. There is no third path: nothing
-- else in this file clears `beams`, and `stepBeams` runs from the unconditional
-- Heartbeat, so a boss that dies mid-sweep still expires its beam through the
-- same release below rather than leaving a lamp burning in an empty arena.
K.beamLampsOff = function(pool)
	if not pool or not pool.lights then
		return
	end
	for i = 1, K.BEAM_LAMPS do
		local light = pool.lights[i]
		if light then
			light.Enabled = false
			light.Brightness = 0
		end
	end
	parkParts(pool.lamps)
end

local beams: { any } = {}
local beamPool: { any } = {}

local function drawBeam(s, pool, now: number): boolean
	local elapsed = now - s.start
	if elapsed > s.duration + K.BEAM_FADE then
		return false
	end
	local fade = math.clamp((elapsed - s.duration) / K.BEAM_FADE, 0, 1)
	local u = math.clamp((elapsed + K.BEAM_LEAD) / s.duration, 0, 1)
	local theta = s.angle + s.arc * s.dir * u
	local cos, sin = math.cos(theta), math.sin(theta)
	local facing = CFrame.Angles(0, -theta, 0)
	local span = (s.reach - K.BEAM_INNER) / K.BEAM_RUNGS
	local pulse = 0.55 + 0.45 * math.sin(now * 9)
	-- THE ONE RAMP (plan 3.3), not a curve of its own. The wedge has no
	-- lead-in - the light IS the damage - so it opens on the flash frame,
	-- holds TELL.LIVE_T for the whole sweep and fades in TELL.FADE rather
	-- than trailing 0.70 of transparency over BEAM_FADE. The throb rides on
	-- top and only ever UPWARD (1 - pulse is never negative), so the ladder
	-- still breathes with the lamps and still never goes under NEON_MIN.
	local live = elapsed <= s.duration
	local ramp = K.NoctyssPath.tellRamp(1, live, if live then elapsed else elapsed - s.duration, nil)
	local alpha = if live and elapsed < K.NoctyssPath.TELL.FLASH
		then ramp
		else math.clamp(ramp + 0.13 * (1 - pulse), K.BEAM_PEAK_T, 1)

	for i = 1, K.BEAM_RUNGS do
		local r = K.BEAM_INNER + span * (i - 0.5)
		local x, z = s.apex.X + cos * r, s.apex.Z + sin * r
		-- PROBE FROM GROUND HEIGHT, not from the lantern. `surfaceUnder`
		-- casts 8 studs down from 1.5 above whatever it is given, and the
		-- apex is the bulb ~30 studs up - so the ray died in mid-air, fell
		-- through to the waterline default, and every rung was drawn ~1.5
		-- studs INSIDE the shelf. In a black arena this marker is the only
		-- warning a lightsweep gives, and it was invisible.
		local ground = surfaceUnder(Vector3.new(x, K.BEAM_PROBE_Y, z))
		local rung = pool.rungs[i]
		-- The lit patch WIDENS with distance, because a beam is an angle and
		-- not a lane: drawing a constant width would promise safety at the far
		-- edge that the hit test does not honour.
		rung.Size = Vector3.new(span * 0.9, 0.08, math.max(2 * r * math.tan(s.half), 1.4))
		rung.CFrame = CFrame.new(x, ground.Y + 0.09, z) * facing
		rung.Transparency = alpha
	end

	-- The shaft, so the light visibly comes FROM a stalk you could have shot,
	-- rather than appearing on the floor from nowhere.
	local mid = K.BEAM_INNER + (s.reach - K.BEAM_INNER) * 0.42
	local at = Vector3.new(s.apex.X + cos * mid, 0, s.apex.Z + sin * mid)
	local target = Vector3.new(at.X, surfaceUnder(Vector3.new(at.X, K.BEAM_PROBE_Y, at.Z)).Y, at.Z)
	local reach = target - s.apex
	if reach.Magnitude > 1 then
		pool.shaft.Size = Vector3.new(2.2, 2.2, reach.Magnitude)
		pool.shaft.CFrame = CFrame.lookAt(s.apex + reach * 0.5, target)
		pool.shaft.Transparency = 0.74 + 0.26 * fade
	end

	-- THE LAMPS. Same apex, same bearing, same colour as everything above - one
	-- beam, not a light show bolted next to a marker. They ride slightly AHEAD
	-- of the rungs (K.BEAM_GLOW_LEAD) and swell in over K.BEAM_GLOW_RISE, so the
	-- ambient level around a player rises before the wedge reaches them whether
	-- or not the stalk is on screen. Proximity scaling is the light's own
	-- falloff: nothing to compute, and it is honest by construction.
	local rise = math.clamp(elapsed / K.BEAM_GLOW_RISE, 0, 1)
	local swell = rise * rise * (3 - 2 * rise) * (1 - fade)
	local lead = math.clamp((elapsed + K.BEAM_GLOW_LEAD) / s.duration, 0, 1)
	local ltheta = s.angle + s.arc * s.dir * lead
	local lcos, lsin = math.cos(ltheta), math.sin(ltheta)
	for i = 1, K.BEAM_LAMPS do
		local lamp, light = pool.lamps[i], pool.lights[i]
		local r = K.BEAM_INNER + (s.reach - K.BEAM_INNER) * K.BEAM_LAMP_AT[i]
		local x, z = s.apex.X + lcos * r, s.apex.Z + lsin * r
		-- Ground-probed like the rungs, and for the same reason: the apex is the
		-- bulb ~30 studs up, so anything measured from it lands in mid-air.
		local floor = surfaceUnder(Vector3.new(x, K.BEAM_PROBE_Y, z))
		lamp.CFrame = CFrame.new(x, floor.Y + K.BEAM_LAMP_Y, z)
		-- Tracks the wedge as it widens: the lit radius is the wedge's own
		-- half-width solved at this lamp's distance from the apex.
		local width = 2 * r * math.tan(s.half)
		light.Range = math.clamp(
			K.BEAM_LAMP_RANGE_MIN + width * K.BEAM_LAMP_RANGE_GAIN,
			K.BEAM_LAMP_RANGE_MIN,
			K.BEAM_LAMP_RANGE_MAX
		)
		-- Shares the rungs' throb so the two read as one object pulsing.
		light.Brightness = K.BEAM_LAMP_BRIGHT * swell * (0.82 + 0.18 * pulse)
		light.Enabled = swell > 0.02
	end
	return true
end

local function stepBeams(now: number)
	for slot = 1, K.BEAM_SLOTS do
		local s = beams[slot]
		if s and not drawBeam(s, beamPool[slot], now) then
			beams[slot] = nil
			parkParts(beamPool[slot].rungs)
			K.beamLampsOff(beamPool[slot])
			beamPool[slot].shaft.Transparency = 1
			beamPool[slot].shaft.CFrame = K.PARKED
		end
	end
end

-- THE SIGNATURE OF THE GLOOM FIGHT. One stalk leans onto a bearing and
-- scythes its lantern across the shelf; this is the only warning, and in a
-- black arena it is also most of the light.
K.EVENTS.choirBeam = function(position: Vector3, extra)
	local duration = math.clamp(tonumber(extra.duration) or 2.6, 0.2, 12)
	local reach = math.max(tonumber(extra.reach) or 74, K.BEAM_INNER + 6)
	if not nearCamera(position, reach + 40) then
		return
	end
	local s = {
		apex = position, -- the bulb: the same apex the damage wedge hinges on
		angle = tonumber(extra.angle) or 0,
		arc = tonumber(extra.arc) or 0,
		dir = tonumber(extra.dir) or 1,
		half = math.clamp(tonumber(extra.half) or math.rad(9), math.rad(2), math.rad(45)),
		reach = reach,
		duration = duration,
		start = os.clock(),
	}
	-- Take a free slot or the oldest: two stalks sweeping at once is a real
	-- state late in the fight, and dropping either marker is a death.
	local slot, oldest = 1, math.huge
	for i = 1, K.BEAM_SLOTS do
		if not beams[i] then
			slot = i
			oldest = -1
			break
		end
		if beams[i].start < oldest then
			slot, oldest = i, beams[i].start
		end
	end
	if oldest >= 0 then
		parkParts(beamPool[slot].rungs)
		-- The stolen slot's lamps go dark WITH its rungs. Miss this and the old
		-- sweep's light stays parked at the last bearing it held, lighting a
		-- lane nothing is sweeping - which in this arena is worse than no tell.
		K.beamLampsOff(beamPool[slot])
	end
	beams[slot] = s
	Vfx.flash(position, K.LURE_LIGHT, 4, 0.18)
	Sfx.play("choirBeam", position)
end

-- A FALSE lure has been shot out. It flares white - the wrong note, and the
-- opposite of the ink this used to borrow: her real answer to being fooled is
-- to take your night vision, not to hide.
K.EVENTS.lureFlare = function(position: Vector3, extra)
	local radius = tonumber(extra.radius) or 15
	Vfx.flash(position, Color3.new(1, 1, 1), 7, 0.3)
	-- The blast's footprint in the telegraph language, on probed ground: the
	-- white and the screen wash are the PUNISH (you shot the wrong lantern and
	-- lost your night vision), the ring is the r-`radius` it paid out over,
	-- and that is a light attack whatever else it is.
	Vfx.ring(surfaceUnder(position) + Vector3.new(0, 0.15, 0), 2, radius, 0.45, K.NoctyssPath.TELL.LIGHT)
	Sfx.play("lureFlare", position)
	if localDistance(position) <= radius * 1.6 then
		flashFrame.BackgroundColor3 = Color3.fromRGB(255, 250, 236)
		flashFrame.BackgroundTransparency = 0.08
		TweenService:Create(flashFrame, TweenInfo.new(1.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			BackgroundTransparency = 1,
		}):Play()
	end
end

-- --------------------------------------------------- the choir's floor bands
--
-- ONE TELEGRAPH LANGUAGE, DRAWN (the Noctyss legibility plan, 3.2 and 3.3).
-- Everything Noctyss puts on this floor is TWO PARTS: a crisp EDGE exactly on
-- the boundary the server tests, narrow enough (TELL.EDGE_W) that a player can
-- place a foot against it, and a dim FILL behind it so the footprint reads as
-- a shape rather than an outline. Its alpha comes from NoctyssPath.tellRamp
-- and from nothing else, in this file and in NoctyssBodyController both.
--
-- WHY NOT THE STOCK DRAWS ABOVE, which are perfectly good for the bosses they
-- were built for. `mark` and `ringTell` are pulsed Vfx.ring calls: transient,
-- so there is no ramp to read a countdown off - a mark that is merely ON says
-- "something is happening", which in a black room holding four other lit
-- shapes is the same as saying nothing. And an annulus drawn as ONE expanding
-- ring HAS NO INNER EDGE. That is the exact lie `strobewave` told: its core is
-- genuinely safe, the answer is "cross the band before it closes", and the
-- drawing said "get away from the middle". Both edges are drawn here, and the
-- fill between them, because the fix for an undrawn safe core is to DRAW it.
--
-- KEYED ON `skin == "lure"`, which is Noctyss's light and nobody else's in the
-- book (lightsweep, strobewave, lurepull, the false-lure flare). `ink` is NOT
-- a discriminator - the Kraken wears it on every arm it throws - so her
-- ink-skinned rows keep the shared draw on purpose and no other boss's
-- telegraph moves by a pixel.
K.CHOIR_BAND_SLOTS = 3
-- 24 bearings. The outermost strobe band sits at r 61, where 24 segments leave
-- a sagitta of half a stud against an edge 0.9 wide - a circle, not a polygon.
-- 16 would leave 1.2 and the ring would visibly have corners.
K.CHOIR_BAND_SEGS = 24
K.choirBands = {}
K.choirBandPool = {}
-- The last RIM-WIDE disc `mark` she drew, probed: `lurepull`'s rim.
-- K.EVENTS.pull reads it so the drag's shockwave has a floor to land on. See
-- the note there, and the size gate down in K.choirTell.
K.choirRim = nil
-- How far from a pull's payload a cached rim may sit and still be this
-- arena's. The Choirfloor's stone ends at r68 and the next arena is a world
-- away, so this separates arenas without ever rejecting a live rim.
K.CHOIR_RIM_NEAR = 120

K.choirBandRelease = function(pool)
	parkParts(pool.inner)
	parkParts(pool.outer)
	parkParts(pool.fill)
	pool.disc.Transparency = 1
	pool.disc.CFrame = K.PARKED
end

-- One frame of one band. Returns false when it is done and the slot is free.
--
-- THE FLASH IS THE HITBOX GOING LIVE, not a phase name. A queued strike's
-- annulus lands on a single frame, so `live` is true for exactly TELL.FLASH
-- and then the fade starts - TELL.FADE and never longer, because a footprint
-- that outlives its own hitbox teaches the player to dodge a shape that
-- cannot hurt them.
K.drawChoirBand = function(b, pool, now: number): boolean
	local tell = K.NoctyssPath.TELL
	local elapsed = now - b.start
	local u, live, since = 1, false, -1
	if elapsed < b.lead then
		u = elapsed / b.lead
	else
		local t = elapsed - b.lead
		if t < tell.FLASH then
			live, since = true, t
		else
			since = t - tell.FLASH
			if since >= tell.FADE then
				return false
			end
		end
	end
	local edgeT, color, fillT = K.NoctyssPath.tellRamp(u, live, since, b.color)
	for i = 1, K.CHOIR_BAND_SEGS do
		local edge = pool.outer[i]
		edge.Transparency = edgeT
		edge.Color = color
		if b.annulus then
			local ring = pool.inner[i]
			ring.Transparency = edgeT
			ring.Color = color
			local fill = pool.fill[i]
			fill.Transparency = fillT
			fill.Color = color
		end
	end
	if not b.annulus then
		pool.disc.Transparency = fillT
		pool.disc.Color = color
	end
	return true
end

K.stepChoirBands = function(now: number)
	for slot = 1, K.CHOIR_BAND_SLOTS do
		local b = K.choirBands[slot]
		if b and not K.drawChoirBand(b, K.choirBandPool[slot], now) then
			K.choirBands[slot] = nil
			K.choirBandRelease(K.choirBandPool[slot])
		end
	end
end

-- Claim a stock telegraph for the choir, or hand it back. Called from
-- K.EVENTS.telegraph after the tell cue and before every stock branch;
-- returning true means this band owns the draw.
K.choirTell = function(kind: string, position: Vector3, extra, duration: number): boolean
	if extra.skin ~= "lure" or (kind ~= "mark" and kind ~= "ringTell") then
		return false
	end
	local outer = tonumber(extra.radius)
	if not outer then
		return false
	end
	-- Claimed either way past here: out of sight is a reason not to draw, not
	-- a reason to fall through to the language this exists to replace.
	if not nearCamera(position, outer + 150) then
		return true
	end
	local tell = K.NoctyssPath.TELL
	local inner = if kind == "ringTell" then math.max(tonumber(extra.inner) or outer * 0.7, 0) else 0
	local slot, oldest = 1, math.huge
	for i = 1, K.CHOIR_BAND_SLOTS do
		if not K.choirBands[i] then
			slot, oldest = i, -1
			break
		end
		if K.choirBands[i].start < oldest then
			slot, oldest = i, K.choirBands[i].start
		end
	end
	local pool = K.choirBandPool[slot]
	K.choirBandRelease(pool)
	local b = {
		center = position,
		inner = inner,
		outer = outer,
		annulus = inner > 0.5,
		-- The payload's `duration` IS the arm window (queueStrike sends
		-- hitAt - now), so it is the lead-in and u runs 0..1 across it.
		lead = math.max(duration, 0.05),
		color = tell.LIGHT,
		start = os.clock(),
	}
	local segs = K.CHOIR_BAND_SEGS
	local mid = (inner + outer) * 0.5
	local width = math.max(outer - inner - tell.EDGE_W, 0.25)
	local state = { center = position }
	for i = 1, segs do
		local theta = ((i - 0.5) / segs) * math.pi * 2
		local cos, sin = math.cos(theta), math.sin(theta)
		-- ONE PROBE PER BEARING, at the band's midline, shared by the three
		-- parts standing on it. The Choirfloor is not a plane - the socket
		-- collars sit on raised mounds - which is why a mark laid on a flat
		-- SHELF_Y spends part of its length inside the rock; but it IS flat
		-- across the handful of studs one band spans, and MARK_LIFT already
		-- clears the z-fight. Probed once HERE and never again: the geometry
		-- does not move, so the Heartbeat step writes alpha and nothing else.
		local y = K.NoctyssPath.markFloor(state, position.X + cos * mid, position.Z + sin * mid).Y
		local facing = CFrame.Angles(0, -theta, 0)
		-- X is radial and Z is tangential, the same convention the beam's
		-- rungs use, so the edge is EDGE_W across the boundary and one
		-- segment's chord along it.
		local edge = pool.outer[i]
		edge.Size = Vector3.new(tell.EDGE_W, 0.09, (2 * math.pi * outer / segs) * 1.04)
		edge.CFrame = CFrame.new(position.X + cos * outer, y + 0.02, position.Z + sin * outer) * facing
		if b.annulus then
			local ring = pool.inner[i]
			ring.Size = Vector3.new(tell.EDGE_W, 0.09, (2 * math.pi * inner / segs) * 1.04)
			ring.CFrame = CFrame.new(position.X + cos * inner, y + 0.02, position.Z + sin * inner) * facing
			local fill = pool.fill[i]
			fill.Size = Vector3.new(width, 0.08, (2 * math.pi * mid / segs) * 1.04)
			fill.CFrame = CFrame.new(position.X + cos * mid, y, position.Z + sin * mid) * facing
		end
	end
	if not b.annulus then
		local y = K.NoctyssPath.markFloor(state, position.X, position.Z).Y
		pool.disc.Size = Vector3.new(0.1, outer * 2, outer * 2)
		pool.disc.CFrame = CFrame.new(position.X, y, position.Z) * CFrame.Angles(0, 0, math.pi * 0.5)
		-- THE PIT RIM, REMEMBERED - and ONLY the pit rim. `lurepull`'s mark is
		-- drawn at PIT_R + 3 and it is the one piece of ground that move's
		-- force effect wants (see K.EVENTS.pull, which is otherwise handed a
		-- pivot buried under the shelf). It is no longer the only disc in this
		-- skin: dousehunt draws a per-player 9-stud disc in the same `lure`
		-- skin, and one of those landing in here would hand the pull's
		-- shockwave a player's feet instead of the rim. The size IS the
		-- identity - nothing else she draws is rim-wide - so gate on it.
		if outer >= K.NoctyssPath.PIT_R then
			K.choirRim = { at = Vector3.new(position.X, y, position.Z), radius = outer, at_ = b.start }
		end
	end
	K.choirBands[slot] = b
	return true
end

-- The blackout's two numbers. See K.EVENTS.choirDouse.
K.DOUSE_LIFT = 0.35
K.DOUSE_LIFT_T = 0.45
K.douseSeq = 0

-- EVERY LANTERN AT ONCE. The arena's only light goes out, and the strike
-- lands where you were standing when it did. The dark is the attack, so this
-- holds full black for the whole window rather than fading prettily through
-- it - the sound is what you get to navigate by (Sfx choirDouse).
K.EVENTS.choirDouse = function(position: Vector3, extra)
	local duration = math.clamp(tonumber(extra.duration) or 1.6, 0.2, 6)
	Sfx.play("choirDouse", position)
	if not nearCamera(position, 220) then
		return
	end
	-- ITS OWN SURFACE, not the shared flash frame. The strike this attack
	-- fires under cover of the dark lands DURING the dark (pattern
	-- "everyone", arm 0.55), and every blast handler tweens the shared frame
	-- back to transparent - so the blackout was being wiped by the very hit
	-- it exists to hide, intermittently, depending on who got clipped. A
	-- separate frame cannot be stolen, and it is drawn over the top.
	darkTween = if darkTween then darkTween:Cancel() else nil
	darkFrame.BackgroundTransparency = 0.04
	-- IT WAS HIDING ITS OWN TELEGRAPH. `dousehunt` fires its strike marks at
	-- `now` (pattern "everyone"), so the entire 0.65s arm window burned behind
	-- an opaque frame: a 44-60 hit with a drawn, invisible tell. The book
	-- prices the escape at 13.8 studs/s against a walk of 16, and that
	-- arithmetic assumes the player knows WHICH WAY to run.
	--
	-- So the scare keeps its full `duration - lift` of true black - 1.25s at
	-- the row's 1.6 - and then the frame lifts to DOUSE_LIFT_T for the last
	-- `lift` seconds. Still night, still nothing to aim by; just enough that
	-- the disc under your feet reads one arm-window before it closes.
	-- `extra.lift` is the server's override if a row ever wants to pay for
	-- more or less of it.
	local lift = math.clamp(tonumber(extra.lift) or K.DOUSE_LIFT, 0, duration)
	-- A SECOND DOUSE MUST NOT BE LIFTED BY THE FIRST ONE'S TIMER. Two are in
	-- stance three and their cooldown can land inside this window; without the
	-- token, the older cast's delayed lift would open the newer cast's black.
	K.douseSeq += 1
	local seq = K.douseSeq
	task.delay(duration - lift, function()
		if K.douseSeq ~= seq then
			return
		end
		darkTween = if darkTween then darkTween:Cancel() else nil
		darkTween = TweenService:Create(
			darkFrame,
			TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = K.DOUSE_LIFT_T }
		)
		darkTween:Play()
	end)
	task.delay(duration, function()
		if K.douseSeq ~= seq then
			return
		end
		darkTween = if darkTween then darkTween:Cancel() else nil
		darkTween = TweenService:Create(
			darkFrame,
			TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = 1 }
		)
		darkTween:Play()
	end)
end

local function stepSweeps(now: number)
	for slot = 1, K.SWEEP_SLOTS do
		local s = sweeps[slot]
		if s and not drawSweep(s, sweepPool[slot], now) then
			sweeps[slot] = nil
			parkParts(sweepPool[slot].rungs)
			parkParts(sweepPool[slot].shadows)
		end
	end
end

-- Drop every swept marker NOW, wherever it had got to. The one caller is the
-- death slide: a sweep's clock runs to `windup + travel` on its own and
-- stepSweeps parks it there, so nothing is ever stranded by the event simply
-- not coming again - but a boss that dies mid-arc leaves a rung ladder
-- swinging over a corpse for up to twelve seconds, which is the only way this
-- pool can outlive the thing it describes.
K.clearSweeps = function()
	for slot = 1, K.SWEEP_SLOTS do
		if sweeps[slot] then
			sweeps[slot] = nil
			parkParts(sweepPool[slot].rungs)
			parkParts(sweepPool[slot].shadows)
		end
	end
end

-- THE ORANGE LADDER, AND WHO STILL FIRES IT: NOBODY IN THIS FIGHT.
--
-- Brinejaw's whip family (whip, doublewhip, whipback, spiral) used to mark
-- every arc with this, so an orange rung ladder sat in front of the tail from
-- the moment the fight started to the moment it ended and never meant anything
-- in particular. The WHIP ITSELF is the telegraph - it is a forty-stud arm
-- drawn by BrinejawBodyController, visible from anywhere on the sand - so the
-- server no longer fires `serpentSweep` for those rows (contract REVISION 2
-- §6) and this handler is expected to go quiet for the whole fight.
--
-- THE CODE STAYS. Other bosses' lanes reference this pattern (the choir's beam
-- below is drawSweep with a widening rung), and `serpentSlam`'s marker is
-- untouched. What was removed is every Brinejaw-shaped ASSUMPTION: nothing
-- else in this file reads `sweeps`, no other handler waits on a sweep having
-- marked the ground first, and the arena's centre comes from the PoseCenter
-- attribute (towerFoot) rather than from a sweep payload that may never
-- arrive. A sweep that is mid-display when the events stop still fades out on
-- its own clock through SWEEP_FADE and parks its rungs; a sweep that never
-- comes costs a parked pool and nothing else.
--
-- What it still draws, for the lanes that do fire it: the arm unwinds off the
-- tower and scythes round the arena like a clock hand, and this is where it is
-- about to be, all the way across the band, in the shape of the answer it
-- wants.
K.EVENTS.serpentSweep = function(position: Vector3, extra)
	-- Two clocks, not one: `windup` is the hold on the start bearing, and
	-- `travel` is the arc itself. Only the second is when the arm moves.
	local windup = math.clamp(tonumber(extra.windup) or 0, 0, 12)
	local travel = math.clamp(tonumber(extra.duration) or 2.4, 0.2, 12)
	local inner = math.max(tonumber(extra.inner) or BrinejawPath.SWEEP_INNER, 0)
	local reach = math.max(tonumber(extra.reach) or BrinejawPath.SWEEP_REACH, inner + 4)
	if not nearCamera(position, reach + K.BRINE_MARGIN) then
		return
	end
	local high = extra.high == true
	local girth = math.clamp(tonumber(extra.girth) or K.SWEEP_GIRTH, 0.5, 12)
	local angle = tonumber(extra.angle) or 0
	local s = {
		center = position,
		angle = angle,
		girth = girth,
		arc = tonumber(extra.arc) or 0,
		inner = inner,
		reach = reach,
		high = high,
		height = tonumber(extra.height) or (if high then BrinejawPath.SWEEP_HIGH else BrinejawPath.SWEEP_LOW),
		windup = windup,
		travel = travel,
		start = os.clock(),
		nextDustAt = 0,
	}

	-- Take a free slot, or the oldest sweep's - the third coil chases a slow
	-- high sweep with a fast low one, and dropping either marker is a death.
	local slot, oldest = 1, math.huge
	for i = 1, K.SWEEP_SLOTS do
		if not sweeps[i] then
			slot = i
			break
		end
		if sweeps[i].start < oldest then
			slot, oldest = i, sweeps[i].start
		end
	end
	local pool = sweepPool[slot]
	for _, rung in pool.rungs do
		rung.Color = if high then K.BRINE.high else K.BRINE.low
	end
	if not high then
		parkParts(pool.shadows) -- a low arm is ON the sand; it casts nothing
	end
	sweeps[slot] = s

	-- The cue comes from where the arm STARTS, out on the band, so the ear
	-- says which side of the tower it is coming round from.
	local mid = (inner + reach) * 0.5
	Sfx.play(
		if high then "serpentSweepHigh" else "serpentSweepLow",
		Vector3.new(
			position.X + math.cos(angle) * mid,
			position.Y + BrinejawPath.sandY(mid) + s.height,
			position.Z + math.sin(angle) * mid
		)
	)
end

-- ------------------------------------------------------------ the tail slam

-- The rattle is coming down here. Rings contract onto the point on a cadence
-- that tightens as the clock runs out, so the last one closes exactly as the
-- tail lands (the impact itself is the ordinary `slam` moment). Baiting this
-- onto a reef stone is the entire fight, so a baited one is a different
-- colour and wears a beacon: the party has to be able to see it was right
-- BEFORE it lands, or the decision never gets learned.
-- THE STONES, LIT. The whole fight is "bait the tail onto a reef stone", and a
-- playtest found nobody could see that it was a mechanic at all: the stones
-- look like scenery because they ARE scenery, and the only difference between
-- a winning slam and a wasted one was a marker two shades apart. So for the
-- length of every windup, each stone the server listed burns.
--
-- AN OVERLAY PART, never a material change to the arena's own rocks: the reef
-- is BossArenaService's authored model, CombatFeedbackController's colour cache
-- has no claim on it and neither have we - a Material we set on someone else's
-- build is a change nothing puts back. A ball parked over each stone is ours
-- and parks itself. Size is the arena row's own stone (BossArenas brine cover:
-- radius 3.4, rise 5.5), plus a stud of halo so the glow reads as light coming
-- off the rock rather than as a bubble sitting on it.
K.STONE_R = 4.4
K.STONE_LIFT = 2.6 -- half the authored rise: the ball sits ON the stone
K.stones = nil
K.stonePool = {}

K.stepStones = function(now: number)
	local s = K.stones
	if not s then
		return
	end
	if now > s.until_ then
		K.stones = nil
		parkParts(K.stonePool)
		return
	end
	-- It throbs FASTER as the tail comes down, so the glow is a clock too: at
	-- the top of the windup that is STONE_PULSE, and by the landing frame it is
	-- twice that. `left` is measured off the windup the payload sent, so a
	-- player who adopts a slam halfway through sees it already hurrying.
	local left = math.clamp((s.until_ - now) / math.max(s.windup, 1e-3), 0, 1)
	local pulse = 0.5 + 0.5 * math.sin(now * K.STONE_PULSE * (2 - left))
	for i = 1, K.STONE_MAX do
		local at = s.list[i]
		local part = K.stonePool[i]
		if not at then
			part.Transparency = 1
			part.CFrame = K.PARKED
		else
			part.Size = Vector3.new(K.STONE_R * 2, K.STONE_R * 2, K.STONE_R * 2)
			part.CFrame = CFrame.new(at.X, at.Y + K.STONE_LIFT, at.Z)
			-- Never opaque: the rock underneath is the thing being pointed at.
			part.Transparency = math.clamp(0.80 - 0.30 * pulse - 0.14 * (1 - left), 0.2, 1)
		end
	end
end

-- ---------------------------------------------------------------- shatter
--
-- THE ROCK COMING APART. A slam baited onto a reef stone is the whole fight
-- being won, and until now the entire visual for it was particles: a flash, a
-- burst, three gold rings. Particles say "an event happened here"; lumps of
-- the rock arcing out and landing say WHAT happened. So the landing throws
-- pack chunks, and this is the only new pool the pack adds that has no
-- fallback shape - without the meshes it draws nothing, because a shower of
-- flying grey CUBES would be worse than the particles it replaced, not better.
--
-- POOL ARITHMETIC. One baited slam throws SHARD_THROW = 8 chunks and they live
-- SHARD_LIFE = 1.5 s. A second baited slam inside that window is possible in a
-- two-boss arena but not in one (the stagger it opens is ten seconds long), so
-- the pool is one throw plus slack: 10, claimed round-robin. Overflowing it
-- recycles the oldest chunk, which here costs a fragment mid-flight and never
-- a warning - nothing in this pool is a marker.
K.SHARD_POOL = 10
K.SHARD_THROW = 8
K.SHARD_LIFE = 1.5
K.SHARD_GRAV = 96.0 -- studs/s^2; heavier than Roblox's 196 looks, lighter than rock
K.shardPool = {}
K.shardSize = {}
K.shards = {}
K.shardCursor = 1

K.throwShards = function(at: Vector3, now: number)
	if not K.fxHas then
		return -- no pack, no debris: see the note above
	end
	for _ = 1, K.SHARD_THROW do
		local index = K.shardCursor
		K.shardCursor = K.shardCursor % K.SHARD_POOL + 1
		local theta = math.random() * math.pi * 2
		local out = 11 + math.random() * 15
		K.shards[index] = {
			from = at,
			vel = Vector3.new(math.cos(theta) * out, 15 + math.random() * 15, math.sin(theta) * out),
			spin = Vector3.new(math.random() * 9 - 4.5, math.random() * 9 - 4.5, math.random() * 9 - 4.5),
			scale = 0.7 + math.random() * 0.8,
			born = now,
		}
	end
end

K.stepShards = function(now: number)
	for i = 1, K.SHARD_POOL do
		local s = K.shards[i]
		local part = K.shardPool[i]
		if not s or not part then
			continue
		end
		local t = now - s.born
		if t > K.SHARD_LIFE or t < 0 then
			K.shards[i] = nil
			part.Transparency = 1
			part.CFrame = K.PARKED
		else
			-- A plain ballistic arc off the shatter point, and it RESTS rather
			-- than sinking: the floor is the point it was thrown from, which is
			-- the sand beside the stone, so a chunk that has landed lies on the
			-- beach for what is left of its life and fades there. Cosmetic, and
			-- it has to look it - the rain's rubble makes the same promise in
			-- the same arena and for the same reason (nothing an attack drops
			-- is ever cover).
			-- When it lands: the far root of `0.5*g*t^2 - vy*t + rest = 0`. It is
			-- solved rather than clamped per axis because the chunk has to STOP
			-- travelling sideways at the same instant it stops falling; a
			-- clamped Y with a free XZ is a rock skating along the beach.
			local rest = 0.4 * s.scale
			local disc = math.max(s.vel.Y * s.vel.Y - 2 * K.SHARD_GRAV * rest, 0)
			local land = (s.vel.Y + math.sqrt(disc)) / K.SHARD_GRAV
			local tf = math.min(t, land)
			local at = s.from
				+ Vector3.new(s.vel.X * tf, math.max(s.vel.Y * tf - 0.5 * K.SHARD_GRAV * tf * tf, rest), s.vel.Z * tf)
			part.Size = K.shardSize[i] * s.scale
			part.CFrame = CFrame.new(at) * CFrame.Angles(s.spin.X * t, s.spin.Y * t, s.spin.Z * t)
			part.Transparency = 0.05 + 0.95 * math.clamp((t - K.SHARD_LIFE * 0.62) / (K.SHARD_LIFE * 0.38), 0, 1)
		end
	end
end

-- The rattle is coming down here. Rings contract onto the point on a cadence
-- that tightens as the clock runs out, so the last one closes exactly as the
-- tail lands (the impact itself is the ordinary `slam` moment). Baiting this
-- onto a reef stone is the entire fight, so a baited one is GOLD and a wasted
-- one is RED - not two oranges - it wears a beacon, every candidate stone
-- burns for the length of the windup, and the landing itself is a different
-- event depending on which of the two it was.
K.EVENTS.serpentSlam = function(position: Vector3, extra)
	local radius = tonumber(extra.radius) or 13
	if not nearCamera(position, radius + K.BRINE_MARGIN) then
		return
	end
	local duration = math.clamp(tonumber(extra.duration) or 1.9, 0.2, 8)
	local baited = extra.stoneNear == true
	local color = if baited then K.BRINE.bait else K.SLAM_SAND
	local point = surfaceUnder(position) + Vector3.new(0, 0.15, 0)

	-- SERVER CLOCK, so the stone glow and the ring cadence agree with the arm
	-- BrinejawBodyController is drawing. `impactAt` is the landing frame; a
	-- payload without one is the old shape and the windup starts on arrival.
	local landAt = tonumber(extra.impactAt) or (Workspace:GetServerTimeNow() + duration)
	if type(extra.stones) == "table" then
		local list = {}
		for _, at in extra.stones do
			if typeof(at) == "Vector3" and #list < K.STONE_MAX then
				-- GROUNDED ONCE, HERE. The server builds these as
				-- (center.X + offset.X, center.Y, center.Z + offset.Z) - the
				-- arena's centre height, which is the waterline and not the
				-- beach the rock stands on. Probing at fire time costs eight
				-- rays for a whole slam; probing in the step would cost eight
				-- a frame for nothing, since a reef stone does not move.
				table.insert(list, surfaceUnder(at))
			end
		end
		K.stones = { list = list, until_ = landAt, windup = math.max(landAt - Workspace:GetServerTimeNow(), 0.1) }
	end

	Sfx.play("serpentSlam", position)
	-- The footprint, marked for the whole windup: one disc, barely moving.
	Vfx.shockwave(point, radius * 0.88, radius, duration, color, 0.1)
	if baited then
		Vfx.flash(point + Vector3.new(0, 3, 0), color, 5, math.min(duration, 1.1))
		Vfx.burst(point + Vector3.new(0, 0.6, 0), color, 22)
	end

	local at, gap = 0, math.min(0.36, duration * 0.3)
	while at < duration - 0.04 do
		local when, span, left = at, math.min(gap, duration - at), 1 - at / duration
		task.delay(when, function()
			Vfx.ring(point, radius * left, radius * left * 0.3, span, color)
		end)
		at += gap
		gap = math.max(gap * 0.74, 0.11)
	end

	-- THE LANDING, and the two of them do not sound or look alike. A slam on
	-- sand is a thud the ordinary `slam` moment already draws; a slam on a
	-- STONE is the fight being won, so it gets the rock coming apart (the
	-- shatter this arena already speaks - reefShatter, doubled and pitched
	-- against itself) and a window cue that is louder and runs a beat longer
	-- than the sand landing's, because what follows it is ten seconds of
	-- stagger instead of three.
	task.delay(math.max(landAt - Workspace:GetServerTimeNow(), 0), function()
		if not baited then
			return
		end
		Vfx.flash(point + Vector3.new(0, 2.2, 0), K.BRINE.stone, 12, 0.4)
		Vfx.burst(point + Vector3.new(0, 1.2, 0), K.BRINE.stone, 60)
		Vfx.puff(point + Vector3.new(0, 0.8, 0), K.BRINE.stone, 3.4)
		Vfx.shockwave(point + Vector3.new(0, 0.3, 0), 2, radius * 1.6, 0.45, K.BRINE.stone, 0.5)
		Sfx.play("reefShatter", point)
		Sfx.play("bossStagger", point)
		feelBlast(point, radius * 1.4, K.SHAKE_SLAM, 0.5, Color3.fromRGB(255, 232, 190))
		-- ...and the rock itself, in pieces. Thrown on the SERVER clock like
		-- everything else in this fight, because the step that flies them
		-- reads that clock and a chunk born on os.clock() would be either
		-- already expired or hours in the future.
		K.throwShards(point + Vector3.new(0, 0.8, 0), Workspace:GetServerTimeNow())
		-- ...and the gold goes up over the wreck of it and STAYS up, three
		-- rings walking out over most of a second - the sand landing gets one
		-- ring at 0.35. Same language, longer sentence.
		for i = 0, 2 do
			task.delay(i * 0.16, function()
				Vfx.ring(point, radius * 0.4, radius * (1.6 + i * 0.5), 0.9, K.BRINE.bait)
			end)
		end
		task.delay(0.12, function()
			Sfx.play("reefShatter", point)
		end)
	end)
end

-- ------------------------------------------------------------ the window

local function closeStagger()
	staggerRing.Transparency = 1
	staggerRing.CFrame = K.PARKED
	stagger = nil
end

local function stepStagger(now: number)
	if not stagger then
		return
	end
	local left = stagger.until_ - now
	if left <= 0 then
		closeStagger()
		return
	end
	-- The disc closes as the window does: its size IS the clock, and it
	-- strobes faster the less of it there is left.
	local u = left / stagger.duration
	local r = K.STAGGER_RADIUS * (0.16 + 0.84 * u)
	staggerRing.Size = Vector3.new(0.14, r * 2, r * 2)
	staggerRing.CFrame = stagger.frame
	local rate = 2.4 + 7 * (1 - u)
	staggerRing.Transparency = 0.5 + 0.28 * (0.5 + 0.5 * math.sin(now * rate * math.pi * 2))
	if now >= stagger.nextBloomAt then
		stagger.nextBloomAt = now + K.STAGGER_BLOOM_INTERVAL
		Vfx.burst(stagger.head, K.BRINE.window, 14)
	end
end

-- THE payoff. The serpent has lost its grip: the head comes off the tower
-- onto the sand and can be hurt for `duration`. Weight first - the camera
-- takes it, the sand goes up - then the window's own clock stays lit under
-- the head until it shuts.
K.EVENTS.bossStagger = function(position: Vector3, extra)
	if not nearCamera(position, K.BRINE_CULL) then
		return
	end
	local duration = math.clamp(tonumber(extra.duration) or 6, 0.5, 40)
	local point = surfaceUnder(position) + Vector3.new(0, 0.12, 0)

	Sfx.play("bossStagger", position)
	task.delay(0.09, function()
		Sfx.play("bossRoar", position)
	end)

	-- It comes down: sand out from under the skull, a shove on the camera.
	Vfx.puff(point, Vfx.Color.sand, 5)
	Vfx.burst(point, Vfx.Color.sand, 60)
	Vfx.shockwave(point + Vector3.new(0, 0.3, 0), 2, 24, 0.6, Vfx.Color.sand, 0.7)
	Vfx.ring(point, 3, 28, 0.75, Vfx.Color.sand)
	Vfx.flash(position + Vector3.new(0, 2, 0), K.BRINE.window, 7, 0.45)
	feelBlast(position, 28, K.SHAKE_SLAM, 0.6, Color3.fromRGB(255, 226, 170))

	local now = os.clock()
	stagger = {
		frame = CFrame.new(point) * CFrame.Angles(0, 0, math.rad(90)),
		head = position + Vector3.new(0, 2, 0),
		duration = duration,
		until_ = now + duration,
		nextBloomAt = now + K.STAGGER_BLOOM_INTERVAL,
	}
end

-- ------------------------------------------------------------ the tower

-- The stack has slid one turn down the spire. Nothing about the boss says so
-- from a distance, so the TOWER says it: masonry dust walking down the drums,
-- grit landing at the foot, and the ground moving under everyone.
K.EVENTS.bossStance = function(position: Vector3, extra)
	if not nearCamera(position, K.BRINE_CULL) then
		return
	end
	local stance = tonumber(extra.stance) or BrinejawPath.MAX_COIL
	-- Each coil it has already lost grinds the next one harder.
	local weight = 1 + 0.35 * math.max(BrinejawPath.MAX_COIL - stance, 0)
	local foot = towerFoot(position)

	Sfx.play("bossStance", foot)
	feelBlast(foot, 46, K.SHAKE_RISE * weight, 0.9, Color3.fromRGB(214, 204, 188))

	-- Dust walking DOWN the tower: two chunks a step, on opposite faces, so
	-- it reads as the whole coil grinding rather than one rock falling.
	local steps = 8
	for i = 0, steps do
		task.delay(i * 0.11, function()
			local y = 46 - i * 5.4
			local spin = math.random() * math.pi * 2
			local r = BrinejawPath.spireRadius(y) + 2.5
			for k = 0, 1 do
				local theta = spin + k * math.pi
				local at = foot + Vector3.new(math.cos(theta) * r, y, math.sin(theta) * r)
				Vfx.puff(at, K.BRINE.stone, 1.8 * weight)
				Vfx.burst(at, K.BRINE.stone, 10)
			end
		end)
	end

	-- ...and it all lands.
	task.delay(steps * 0.11 + 0.1, function()
		local base = foot + Vector3.new(0, BrinejawPath.sandY(0) + 0.15, 0)
		Vfx.puff(base, K.BRINE.stone, 4 * weight)
		Vfx.ring(base, 5, 22 * weight, 0.75, K.BRINE.stone)
		Sfx.play("bossSlam", foot)
		feelBlast(foot, 44, K.SHAKE_SLAM * weight, 0.65, Color3.fromRGB(214, 204, 188))
	end)
end

-- A reef stone cracked open by the tail. `extra.index` says which of the
-- three it was; nothing about the burst depends on that, only on the fact
-- that one of the party's three answers has just been spent.
K.EVENTS.reefShatter = function(position: Vector3)
	if not nearCamera(position, K.BRINE_CULL) then
		return
	end
	local point = surfaceUnder(position) + Vector3.new(0, 0.15, 0)
	Vfx.burst(point + Vector3.new(0, 1.5, 0), K.BRINE.stone, 46)
	Vfx.puff(point + Vector3.new(0, 0.8, 0), K.BRINE.stone, 3)
	Vfx.shockwave(point + Vector3.new(0, 0.3, 0), 1, 10, 0.35, K.BRINE.stone, 0.35)
	Vfx.ring(point, 1.5, 13, 0.5, K.BRINE.stone)
	Sfx.play("reefShatter", position)
	task.delay(0.05, function()
		Sfx.play("hitCrack", position)
	end)
	feelBlast(position, 15, K.SHAKE_EXPLODE, 0.3, Color3.fromRGB(232, 226, 212))
	-- The stump goes under, and the sand closes over it.
	task.delay(0.35, function()
		Vfx.puff(point, Vfx.Color.sand, 2.4)
	end)
end

-- The death slide: it lets go of the spire for the last time and comes down
-- the whole height of it. (Defensive - the server may or may not send this;
-- a handler that never fires costs nothing, a silent death costs the fight.)
K.EVENTS.bossCollapse = function(position: Vector3, extra)
	if not nearCamera(position, K.BRINE_CULL) then
		return
	end
	local duration = math.clamp(tonumber(extra.duration) or 4, 0.5, 20)
	local foot = towerFoot(position)
	local ground = foot + Vector3.new(0, BrinejawPath.sandY(0) + 0.15, 0)
	closeStagger() -- whatever window was open, it is over
	K.clearSweeps() -- ...and whatever arc was still promised is not coming

	Sfx.play("bossCollapse", position)
	Sfx.play("bossRoar", position)

	-- The body unspooling off the drums, top to bottom, over the whole slide.
	local steps = math.max(6, math.floor(duration / 0.22))
	for i = 0, steps do
		task.delay(i * (duration / steps), function()
			local y = 54 * (1 - i / steps)
			local theta = math.random() * math.pi * 2
			local r = BrinejawPath.spireRadius(y) + 3.4
			local at = foot + Vector3.new(math.cos(theta) * r, y, math.sin(theta) * r)
			Vfx.puff(at, K.BRINE.stone, 2.6)
			Vfx.burst(at, K.COLOR.brine, 16)
			if i % 3 == 0 then
				Sfx.play("bossSpineHit", at)
			end
		end)
	end

	-- ...and it hits the sand.
	task.delay(duration, function()
		Vfx.flash(ground + Vector3.new(0, 3, 0), K.COLOR.brine, 10, 0.5)
		Vfx.puff(ground, Vfx.Color.sand, 7)
		Vfx.burst(ground, Vfx.Color.sand, 80)
		Vfx.shockwave(ground + Vector3.new(0, 0.4, 0), 3, 40, 0.9, Vfx.Color.sand, 0.9)
		Vfx.ring(ground, 4, 46, 1.2, K.BRINE.stone)
		Sfx.play("bossSlam", ground)
		feelBlast(ground, 60, K.SHAKE_SLAM, 0.8, Color3.fromRGB(240, 226, 200))
	end)
end

-- ------------------------------------ Brinejaw's five broadcast attacks
--
-- The six attacks above (and the death) are POSES: they ride the ten
-- attributes on the model and BrinejawBodyController draws them, telegraphs
-- and all. These five cannot be - a wave crossing the whole arena, a seeded
-- bombardment, the bell's rings, the flood, the polyps - so they come through
-- `fireEvent` with a payload.
--
-- TWO RULES, AND THEY ARE THE SAME TWO THE POSE HALF KEEPS.
--
--   1. EVERY SHAPE HERE IS COMPUTED BY A SHARED HELPER IN BrinejawPath, never
--      by math written down twice. `waveFront` says where the wall is,
--      `waveSheltered` says which ground is safe AND is the rectangle the lee
--      is drawn as, `rainChunks` places every falling stone, `ringRadius`
--      sizes every ring, `surgeRain` builds the surge's bombardment payload.
--      The server calls the same five for its damage. Nothing below owns a
--      radius or a bearing of its own.
--
--   2. EVERY CLOCK IS THE SERVER'S. `start`, `deadline` and the `impactAt`
--      the helpers derive are `Workspace:GetServerTimeNow()` values, and the
--      steps below ask that clock rather than counting from when the packet
--      arrived - so a player who joins mid-wave sees the wall where it
--      actually is instead of starting it again from the far edge. This is
--      why these steps do NOT use the `now` the Heartbeat hands the older
--      handlers, which is `os.clock()`.
--
-- Palette: the wall and the flood are the arena's own water (Vfx.Color.water
-- shaded toward the reef's green), masonry is BRINE.stone because it IS the
-- tower, and anything that glows is Neon.

K.STORM = {
	wave = Color3.fromRGB(64, 196, 180), -- the wall: brine green, and it glows
	foam = Color3.fromRGB(226, 250, 250), -- its crest, and the flood's edge
	-- The safe wedge behind cover. The same near-black the high sweep's shadow
	-- uses: a shadow is what this is, and a dark patch on bright sand is the
	-- one marker that cannot be mistaken for something being ON the ground.
	lee = Color3.fromRGB(26, 32, 40),
	-- The open water in a gap arc. It is NOT the lee's near-black: a mouth in
	-- the wave is somewhere to RUN, and a dark patch reads as a shadow to hide
	-- in. Pale, flat and barely there - the point of it is that nothing is
	-- standing up out of it.
	calm = Color3.fromRGB(180, 226, 236),
	toll = Color3.fromRGB(232, 196, 108), -- the bell's rings: brass
	flood = Color3.fromRGB(58, 150, 148), -- risen water, translucent
	polyp = Color3.fromRGB(120, 255, 214), -- COLOR.brine: it is the boss's own
}

-- THE RIPTIDE IS A RING, AND IT HAS TO LOOK LIKE WATER.
--
-- It used to be a wall of blue slabs marching across the arena on one bearing,
-- and the playtest verdict was exactly right: "you use those blue walls but
-- that's stupid". Two things were wrong with it. The shape was a lie about the
-- fiction (the coils heave the sea OUTWARD from the tower - there is no edge
-- of the arena for a wall to start at), and the answer it asked for was
-- "stand behind a rock", which from ground level is a thing you either
-- already knew or died to. Contract REVISION 2 §1 replaces both: the sea rises
-- in an expanding RING, and there are TWO GAP ARCS you run to. A hole in the
-- wave is a thing a player can see from anywhere on the beach and sprint for.
--
-- SO THE DRAWING RULE IS THE MECHANIC'S RULE: `waveSafe` decides, per slot,
-- whether there is a wall here at all. Where it says safe there is calm open
-- water and no crest - the hole IS the boolean the server tests, not a picture
-- of it - and where it says hazard there is a crest slab, a foam cap and the
-- spray coming off it.
--
-- HOW MANY SLOTS. 56 around the ring is 6.43 degrees each. The gaps are
-- gapHalf ~ 16 degrees, so 32 degrees of hole is 5.0 slots wide: the worst
-- case rounds the drawn mouth to 4 slots (25.7 deg) or 6 (38.6), i.e. the
-- edge of the hole is within 3.2 degrees of the true one - at the outer radius
-- 76 that is 4.3 studs, about half a body, and it errs on both sides equally
-- so it cannot systematically promise ground the server will hit. 28 slots
-- (12.9 deg) would put that error at a body and a half; 112 doubles the part
-- count to buy 2 studs nobody can stand in.
K.WAVE_SEGS = 56
K.WAVE_SPRAY = 28 -- every other slot: mist is diffuse, it does not draw edges
-- The calm/lee tiles are claimed from a flat pool in ascending slot order, and
-- only safe slots claim one. A frame's safe set is the two gap mouths (about
-- 10 slots) plus whatever cover shadows waveSafe finds along the ring - the
-- crest only ever touches two or three of the eight rocks at once, so 20 is
-- the gaps plus ten shadow slots. Past that the extra safe slots simply go
-- untiled, which loses a shading, never a warning: the crest above them is
-- already absent, and absence is what safe means here.
K.WAVE_CALM = 20
K.WAVE_GAPMARK = 8 -- foam segments per gap, walked from the launch radius out
K.WAVE_HEIGHT = 11.0 -- TALL: jumping is not an answer, and it must look it
K.WAVE_THICK = 2.2
K.WAVE_INNER = 10.0 -- payload default: the launch radius, the tower's foot
K.WAVE_OUTER = 76.0
K.WAVE_GAP_HALF = math.rad(16)
K.WAVE_TILT = math.rad(15) -- how far the crest leans out where it is steepest
K.WAVE_SPRAY_LAG = 3.6 -- how far behind the crest the mist trails
K.WAVE_SPRAY_INTERVAL = 0.085 -- thrown foam, on top of the pooled mist
K.WAVE_SWELL = 0.22 -- +-22% height around the ring: a crest, not a fence
K.WAVE_GROW = 9.0 -- studs of travel the wall takes to stand fully up

-- An empty cover list, so `waveSafe` can be asked the GAP HALF of its own
-- question ("is this bearing in a mouth?") without a second copy of the
-- bearing math living here. Two calls, one authority.
K.NO_COVER = {}

-- ------------------------------------------------- PHASE A SEAM, NOW CLOSED
-- `waveRing` and `waveSafe` were being written in BrinejawPath by the pose
-- lane while this half was being drawn, so both went through a wrapper with
-- the contract's own formula behind it - the only geometry this file has ever
-- owned. Both helpers have landed, so the wrappers and their fallbacks are
-- gone and the calls below go straight to the module. Rule 1 of this section
-- again holds without an asterisk: nothing here owns a radius or a bearing.

-- One flat pool of falling-stone slots, claimed round-robin as a chunk enters
-- its window and released when its debris has faded - the glob pool's idiom.
-- SIZED FOR BOTH RUNS AT ONCE, because they can be. A bombardment's chunks
-- (14, one every 0.22 s, each drawn for `fall` + 4 s of debris) put
-- (fall + 4) / 0.22 on screen together, capped by the run's own count of 14:
-- at the book's new fall of 0.75 (REVISION 2 §5, down from 1.1) that is 21.6,
-- so all 14 of a run can be live at once either way and the number that moved
-- is the surge's derived rain (stagger 0.45, fall 1.0), which still adds 11.
-- 36 covers the pair with slack at both fall times. Undersized, the
-- round-robin would recycle a slot that was still holding a PRE-IMPACT marker
-- - a warning quietly deleted, which is the one thing a pool is never allowed
-- to do.
K.RAIN_POOL = 36
K.RAIN_DROP_H = 46.0 -- how far up a chunk starts: off the tower's gallery
K.RAIN_DEBRIS_LIFE = 4.0 -- how long the rubble lies there before fading
K.RAIN_SLOTS = 2 -- serpentRain and the surge's derived rain, at most

-- Rings: three at once, 20 segments each. A 20-gon at the outer limit (78)
-- sags 78 * (1 - cos(pi/20)) = 0.96 studs off the true circle, inside the
-- 1.3-stud half-band, so no segment ever sits outside the ring that hits.
K.RING_SLOTS = 4
K.RING_SEGS = 20
K.RING_HEIGHT = 0.7

-- The flood: an annulus drawn as sectors, plus the foam line at its inner
-- edge - which is the only number that matters, because it is the boundary
-- the server floods outside of.
K.FLOOD_SEGS = 20
K.FLOOD_OUTER = 78.0
K.FLOOD_DEPTH = 3.4 -- how far the risen water stands over the beach
K.FLOOD_RISE = 1.2 -- seconds it takes to come up
K.FLOOD_FADE = 1.0

K.POLYP_MAX = 6
K.POLYP_BEAM_THICK = 0.55

local wave: any = nil
local rings: any = nil
local surge: any = nil
local polyps: any = nil
local rainRuns: { any } = {}

local wavePool: any = nil
local rainPool: { any } = {}
local rainCursor = 1
local ringPool: { any } = {}
local floodPool: any = nil
local polypPool: any = nil

-- The cover the wave breaks on. `BossArenas.items[islandId].cover` is the
-- authority (measured off the build), and the SPIRE is appended because the
-- lighthouse is cover too and no table lists it - it is the arena, not
-- furniture in it. The list goes to `waveSheltered` and to nothing else, so
-- the drawn lee and the server's shelter test read the same eight rocks.
K.SPIRE_COVER = { offset = Vector3.zero, radius = 9 }

local function arenaCover(center: Vector3, islandId: any)
	local list = {}
	local row = if type(islandId) == "string" then BossArenas.items[islandId] else nil
	if not row then
		-- No islandId in the payload: match the arena by its centre, which is
		-- the point this event was fired from. Flat distance, because the
		-- table's centres sit at the waterline and the tower's foot does not.
		for _, candidate in BossArenas.items do
			local at = candidate.center
			if candidate.cover and typeof(at) == "Vector3" then
				local flat = Vector3.new(at.X - center.X, 0, at.Z - center.Z)
				if flat.Magnitude <= 200 then
					row = candidate
					break
				end
			end
		end
	end
	if row and row.cover then
		for _, piece in row.cover do
			table.insert(list, piece)
		end
	end
	table.insert(list, K.SPIRE_COVER)
	return list
end

-- ------------------------------------------------------------- the riptide

-- Park every part the ring owns. Five pools, and forgetting one of them leaves
-- a crest slab standing on the sand after the sea has gone.
K.parkWave = function()
	parkParts(wavePool.crest)
	parkParts(wavePool.foam)
	parkParts(wavePool.spray)
	parkParts(wavePool.calm)
	parkParts(wavePool.gaps)
end

-- The two mouths, drawn as CORRIDORS on the sand from the launch radius to the
-- outer edge, and drawn from the instant the event lands - before the sea has
-- moved at all. That is the whole point of them: the read has to start during
-- the windup, because a gap you only notice once the wall is up is a gap you
-- cannot reach. Each segment is as wide as the mouth is AT ITS OWN RADIUS
-- (the gap is an angle, so the corridor is a wedge), which also teaches the
-- thing that gets people killed: the mouth is narrow near the tower.
K.drawWaveGaps = function(w, now: number, launched: boolean)
	local pulse = 0.5 + 0.5 * math.sin(now * 6)
	local run = (w.outer - w.inner) / K.WAVE_GAPMARK
	for g = 0, 1 do
		local bearing = if g == 0 then w.gapA else w.gapB
		local cos, sin = math.cos(bearing), math.sin(bearing)
		local facing = CFrame.Angles(0, -bearing, 0)
		for j = 1, K.WAVE_GAPMARK do
			local rj = w.inner + run * (j - 0.5)
			local ground = w.center.Y + BrinejawPath.sandY(rj)
			local slab = wavePool.gaps[g * K.WAVE_GAPMARK + j]
			-- The chord across the mouth at this radius: sin, not tan, because
			-- what is being marked is the straight run of sand between the two
			-- edges rather than a projection onto anything.
			slab.Size = Vector3.new(run * 0.86, 0.14, math.max(2 * rj * math.sin(w.gapHalf), 1.2))
			slab.CFrame = CFrame.new(w.center.X + cos * rj, ground + 0.08, w.center.Z + sin * rj) * facing
			-- Brightest BEFORE the launch, when it is the only thing to look
			-- at; once the wall is up the crest either side of the mouth is
			-- doing the talking and this only has to keep the lane legible.
			slab.Transparency = if launched then 0.62 else 0.30 + 0.16 * pulse
		end
	end
end

-- THE RIPTIDE. The coils heave the sea outward from the tower in a ring, and
-- the ring has two holes in it.
--
-- Every question this asks is `waveSafe`'s, twice per slot:
--   with NO_COVER   - is this bearing inside one of the two mouths? Answer
--                     yes and the crest is simply not built here: open water,
--                     a pale calm tile, and the corridor markings running
--                     through it.
--   with the cover  - is it a rock's shadow instead? Same absence of wall, but
--                     tiled in the lee's near-black, because that safety is
--                     the secondary kind that moves with the rock rather than
--                     a lane you can run down.
-- The drawn hole and the tested hole are therefore one thing. Nothing here
-- owns a bearing, a radius or a shelter rectangle of its own.
local function stepWave(now: number)
	if not wave then
		return
	end
	local r = BrinejawPath.waveRing(wave.start, wave.speed, wave.inner, wave.outer, now)
	-- Two ways to be over, and the second one matters: a helper that keeps
	-- returning a radius past the arena would strand the whole ring on screen,
	-- so the payload's own arithmetic gets the last word.
	if (not r and now >= wave.start) or now > wave.until_ then
		wave = nil
		K.parkWave()
		return
	end
	local launched = r ~= nil and r > wave.inner
	K.drawWaveGaps(wave, now, launched)
	if not launched or not r then
		-- The windup: the mouths are marked, the sea has not moved.
		parkParts(wavePool.crest)
		parkParts(wavePool.foam)
		parkParts(wavePool.spray)
		parkParts(wavePool.calm)
		return
	end

	local span = (math.pi * 2 * r) / K.WAVE_SEGS
	local ground = wave.center.Y + BrinejawPath.sandY(r)
	-- It stands UP over the first nine studs of travel rather than existing at
	-- full height on frame one: a wall that appears is a cut, a wall that rises
	-- is water. Past that it is at height for the whole crossing, because the
	-- server's hit does not weaken with distance and neither may the drawing.
	local grow = math.clamp((r - wave.inner) / K.WAVE_GROW, 0.22, 1)
	local tilt = K.WAVE_TILT * grow
	local lean = math.sin(tilt)
	local pulse = 0.5 + 0.5 * math.sin(now * 7)
	local calmUsed = 0

	for i = 1, K.WAVE_SEGS do
		local theta = (i - 0.5) / K.WAVE_SEGS * math.pi * 2
		local cos, sin = math.cos(theta), math.sin(theta)
		local x, z = wave.center.X + cos * r, wave.center.Z + sin * r
		local at = Vector3.new(x, ground, z)
		local facing = CFrame.Angles(0, -theta, 0)
		local crest, foam = wavePool.crest[i], wavePool.foam[i]
		local spray = if i % 2 == 0 then wavePool.spray[i // 2] else nil
		-- The mouth question first: it is the cheap one (no cover list to walk)
		-- and it answers most of the safe slots on its own.
		local inMouth = BrinejawPath.waveSafe(wave.gapA, wave.gapB, wave.gapHalf, K.NO_COVER, wave.center, at)
		local safe = inMouth or BrinejawPath.waveSafe(wave.gapA, wave.gapB, wave.gapHalf, wave.cover, wave.center, at)

		if safe then
			crest.Transparency = 1
			crest.CFrame = K.PARKED
			foam.Transparency = 1
			foam.CFrame = K.PARKED
			if spray then
				spray.Transparency = 1
				spray.CFrame = K.PARKED
			end
			if calmUsed < K.WAVE_CALM then
				calmUsed += 1
				local tile = wavePool.calm[calmUsed]
				tile.Color = if inMouth then K.STORM.calm else K.STORM.lee
				tile.Size = Vector3.new(K.WAVE_THICK * 3.2, 0.16, span * 1.04)
				tile.CFrame = CFrame.new(x, ground + 0.11, z) * facing
				-- The mouth's water is a glimmer; a rock's shadow is a shadow.
				tile.Transparency = if inMouth then 0.52 + 0.12 * pulse else 0.34
			end
		else
			-- A CREST, NOT A FENCE. The height runs +-22% on three lobes round
			-- the ring (phase seeded off the server's `start`, so every client
			-- draws the same water), and the lip leans outward as it steepens.
			local swell = 1 + K.WAVE_SWELL * math.sin(theta * 3 + wave.phase)
			local h = K.WAVE_HEIGHT * swell * grow
			crest.Size = Vector3.new(K.WAVE_THICK, h, span * 1.06)
			crest.CFrame = CFrame.new(x, ground + h * 0.5, z) * facing * CFrame.Angles(0, 0, -tilt)
			crest.Transparency = 0.18 + 0.10 * pulse
			-- The foam cap rides the lip, which the lean has carried h*sin(tilt)
			-- further out than the slab's own centre line.
			local capOut = h * lean
			foam.Size = Vector3.new(K.WAVE_THICK * 1.6, 0.85 + 0.4 * swell, span * 1.02)
			foam.CFrame = CFrame.new(x + cos * capOut, ground + h * 0.94, z + sin * capOut) * facing
			foam.Transparency = 0.04 + 0.18 * (1 - grow)
			-- ...and the mist it drags behind itself, on the tower side, where
			-- the water has already passed. Half the slots carry it: mist has
			-- no edges to draw, so it does not need the crest's resolution.
			if spray then
				local rs = math.max(r - K.WAVE_SPRAY_LAG, wave.inner * 0.5)
				spray.Size = Vector3.new(K.WAVE_SPRAY_LAG * 1.4, h * 0.55, span * 2.0)
				spray.CFrame = CFrame.new(wave.center.X + cos * rs, ground + h * 0.34, wave.center.Z + sin * rs)
					* facing
				spray.Transparency = 0.74 + 0.12 * pulse
			end
		end
	end

	-- WHATEVER THE SAFE SET SHRANK BY. The tiles are claimed in ascending slot
	-- order every frame, so a frame with fewer safe slots than the last one
	-- would leave the tail of the pool sitting where it was - a patch of calm
	-- water shading ground the wall has just closed over. Park the remainder.
	for i = calmUsed + 1, K.WAVE_CALM do
		wavePool.calm[i].Transparency = 1
		wavePool.calm[i].CFrame = K.PARKED
	end

	-- Thrown foam on top of the pooled mist: two puffs a frame-and-a-bit off
	-- the crest itself, and only where there IS a crest - a puff hanging in a
	-- mouth would be the one thing in this drawing that lies.
	if now >= wave.nextSprayAt then
		wave.nextSprayAt = now + K.WAVE_SPRAY_INTERVAL
		for _ = 1, 2 do
			local theta = math.random() * math.pi * 2
			local at = Vector3.new(
				wave.center.X + math.cos(theta) * r,
				ground + K.WAVE_HEIGHT * grow * 0.9,
				wave.center.Z + math.sin(theta) * r
			)
			if not BrinejawPath.waveSafe(wave.gapA, wave.gapB, wave.gapHalf, wave.cover, wave.center, at) then
				Vfx.puff(at, K.STORM.foam, 1.9)
			end
		end
	end

	-- IT WENT PAST YOU. Once, at the frame the ring crosses the camera's own
	-- radius: the arena is 130 studs across and a wave that passes in silence
	-- at the edge of the screen is a wave nobody believes in.
	if not wave.felt then
		local flat = Vector3.new(camera.CFrame.Position.X - wave.center.X, 0, camera.CFrame.Position.Z - wave.center.Z)
		if r >= flat.Magnitude then
			wave.felt = true
			local bearing = math.atan2(flat.Z, flat.X)
			local at =
				Vector3.new(wave.center.X + math.cos(bearing) * r, ground + 1, wave.center.Z + math.sin(bearing) * r)
			feelBlast(at, 9, K.SHAKE_RISE, 0.45, Color3.fromRGB(206, 240, 240))
		end
	end
end

-- RIPTIDE. The sea rises in a ring around the tower and runs outward over the
-- whole beach. It is too tall to jump; the answer is one of the two MOUTHS in
-- it, and cover is the fallback (contract REVISION 2 §1).
K.EVENTS.serpentWave = function(position: Vector3, extra)
	local center = towerFoot(position)
	local outer = math.clamp(tonumber(extra.outer) or K.WAVE_OUTER, 12, 200)
	if not nearCamera(center, outer + K.BRINE_MARGIN) then
		return
	end
	local inner = math.clamp(tonumber(extra.inner) or K.WAVE_INNER, 2, outer - 4)
	local speed = math.clamp(tonumber(extra.speed) or 24, 1, 200)
	-- SERVER CLOCK. A wave adopted mid-crossing draws itself at the radius it
	-- has actually reached, and one adopted during the windup draws its mouths.
	local start = tonumber(extra.start) or Workspace:GetServerTimeNow()
	wave = {
		center = center,
		inner = inner,
		outer = outer,
		speed = speed,
		start = start,
		gapA = tonumber(extra.gapA) or 0,
		gapB = tonumber(extra.gapB) or math.pi,
		gapHalf = math.clamp(tonumber(extra.gapHalf) or K.WAVE_GAP_HALF, math.rad(3), math.rad(80)),
		cover = arenaCover(center, extra.islandId),
		-- The swell's phase, off the server's own clock so the crest is the
		-- same shape of water on every screen.
		phase = start % (math.pi * 2),
		until_ = start + (outer - inner) / speed + 0.4,
		felt = false,
		nextSprayAt = 0,
	}
	K.parkWave()

	-- The cue is the sea DRAWING BACK first, at the tower, and the launch is
	-- its own moment on the server's clock rather than on arrival - the event
	-- lands during the windup, and a roar on arrival would fire early.
	Sfx.play("serpentSweepLow", center + Vector3.new(0, 2, 0))
	task.delay(math.max(start - Workspace:GetServerTimeNow(), 0), function()
		Sfx.play("bossRise", center)
		Vfx.ring(center + Vector3.new(0, BrinejawPath.sandY(inner) + 0.2, 0), inner, inner + 8, 0.5, K.STORM.foam)
		feelBlast(center, 26, K.SHAKE_RISE, 0.7, Color3.fromRGB(206, 240, 240))
	end)
end

-- ---------------------------------------------------------- masonry rain

-- One bombardment, placed once by the shared helper and then only READ. The
-- chunk list is derived from the payload's seed, so this client's stones land
-- exactly where the server's damage circles will, and nothing about the
-- placement travels over the wire.
local function releaseChunk(chunk)
	if chunk.slot then
		local slot = rainPool[chunk.slot]
		slot.holder = nil
		parkParts({ slot.marker, slot.rock })
		chunk.slot = nil
	end
end

local function claimChunk(chunk)
	if chunk.slot then
		return rainPool[chunk.slot]
	end
	local index = rainCursor
	rainCursor = rainCursor % K.RAIN_POOL + 1
	local slot = rainPool[index]
	if slot.holder then
		slot.holder.slot = nil -- the pool is full; the oldest chunk gives it up
	end
	slot.holder = chunk
	chunk.slot = index
	return slot
end

local function startRain(payload, center: Vector3)
	local chunks = BrinejawPath.rainChunks(payload)
	local run = { center = center, radius = payload.radius or 7, fall = payload.fall or 1.1, chunks = {} }
	for i, chunk in chunks do
		local r = math.sqrt(chunk.pos.X * chunk.pos.X + chunk.pos.Z * chunk.pos.Z)
		run.chunks[i] = {
			at = center + Vector3.new(chunk.pos.X, BrinejawPath.sandY(r), chunk.pos.Z),
			impactAt = chunk.impactAt,
			slot = nil,
			hit = false,
			-- HOW THIS ONE TUMBLES. Off the chunk's own placement, which
			-- `rainChunks` derived from the payload's seed on both sides, so
			-- every client's fourteen stones fall the same way as each other
			-- and differently from one another. A shared rate was fine for
			-- boxes (a spinning cube is a spinning cube); with the pack it is
			-- fourteen identical rocks turning in lockstep, which reads as one
			-- object copied rather than as a tower coming apart.
			spin = Vector3.new(
				3.0 + (chunk.pos.X % 7) * 0.9,
				2.0 + (chunk.pos.Z % 5) * 1.1,
				(chunk.pos.X + chunk.pos.Z) % 3 * 1.3
			),
		}
	end
	table.insert(rainRuns, run)
	while #rainRuns > K.RAIN_SLOTS do
		local old = table.remove(rainRuns, 1)
		for _, chunk in old.chunks do
			releaseChunk(chunk)
		end
	end
	return run
end

local function stepRain(now: number)
	for runIndex = #rainRuns, 1, -1 do
		local run = rainRuns[runIndex]
		local live = false
		for _, chunk in run.chunks do
			local from = chunk.impactAt - run.fall
			local until_ = chunk.impactAt + K.RAIN_DEBRIS_LIFE
			if now < from or now > until_ then
				releaseChunk(chunk)
				if now <= until_ then
					live = true
				end
			else
				live = true
				local slot = claimChunk(chunk)
				if now < chunk.impactAt then
					-- THE MARKER IS THE DAMAGE CIRCLE, at its true radius, and the
					-- STONE ITSELF is the countdown: it touches the sand on the
					-- frame the server opens that circle, not a beat before it.
					--
					-- THE FALL TIME CHANGED (1.1 -> 0.75, REVISION 2 §5) AND THIS
					-- INVARIANT SURVIVED IT UNTOUCHED, which is the whole reason it
					-- is written as `k`. Every term below is in k, not in seconds:
					-- at k = 1 the rock's centre is at `at.Y + 1.4`, and its size is
					-- 2.6, so its underside is at at.Y + 0.1 - on the sand, on the
					-- impact frame, at any fall time the payload sends. What 0.75
					-- actually changes is the SPEED: 46 studs of drop in 0.75 s is
					-- 61 studs/s instead of 42, which is the point of the retune.
					local k = (now - from) / math.max(run.fall, 1e-3)
					local marker = slot.marker
					marker.Size = Vector3.new(0.12, run.radius * 2, run.radius * 2)
					marker.CFrame = CFrame.new(chunk.at + Vector3.new(0, 0.12, 0)) * CFrame.Angles(0, 0, math.rad(90))
					marker.Transparency = 0.62 - 0.34 * k
					local rock = slot.rock
					rock.Size = Vector3.new(2.6, 2.6, 2.6)
					rock.CFrame = CFrame.new(chunk.at + Vector3.new(0, K.RAIN_DROP_H * (1 - k) + 1.4, 0))
						* CFrame.Angles(k * chunk.spin.X, k * chunk.spin.Y, k * chunk.spin.Z)
					rock.Transparency = 0
				else
					if not chunk.hit then
						chunk.hit = true
						local point = chunk.at + Vector3.new(0, 0.15, 0)
						Vfx.burst(point, K.BRINE.stone, 26)
						Vfx.puff(point, Vfx.Color.sand, 2.2)
						Vfx.shockwave(point, 1, run.radius, 0.35, K.BRINE.stone, 0.3)
						Sfx.play("reefShatter", chunk.at)
						feelBlast(chunk.at, run.radius, K.SHAKE_EXPLODE, 0.25, Color3.fromRGB(232, 226, 212))
					end
					-- COSMETIC ONLY, and it has to LOOK it. The rubble lies flat,
					-- knee-low and fading: the cover table is fixed arena data and
					-- nothing dropped by an attack ever joins it, so a chunk that
					-- read as something to hide behind would be teaching a lie
					-- about the one mechanic (Riptide) that cover answers.
					local fade = (now - chunk.impactAt) / K.RAIN_DEBRIS_LIFE
					slot.marker.Transparency = 1
					slot.marker.CFrame = K.PARKED
					local rock = slot.rock
					rock.Size = Vector3.new(3.4, 0.5, 3.0)
					rock.CFrame = CFrame.new(chunk.at + Vector3.new(0, 0.25, 0))
					rock.Transparency = 0.25 + 0.75 * math.clamp(fade, 0, 1)
				end
			end
		end
		if not live then
			table.remove(rainRuns, runIndex)
		end
	end
end

-- MASONRY RAIN. The tower sheds a sector of itself over the arena; the answer
-- is to leave that sector, and failing that to read the markers.
K.EVENTS.serpentRain = function(position: Vector3, extra)
	local outer = math.clamp(tonumber(extra.outer) or 64, 4, 200)
	local center = towerFoot(position)
	if not nearCamera(center, outer + K.BRINE_MARGIN) then
		return
	end
	startRain({
		seed = tonumber(extra.seed) or 0,
		sector = tonumber(extra.sector) or 0,
		width = tonumber(extra.width) or 2.1,
		inner = math.clamp(tonumber(extra.inner) or 12, 0, outer - 1),
		outer = outer,
		count = math.clamp(math.floor(tonumber(extra.count) or 14), 0, K.RAIN_POOL),
		start = tonumber(extra.start) or Workspace:GetServerTimeNow(),
		stagger = math.max(tonumber(extra.stagger) or 0.22, 0.02),
		fall = math.clamp(tonumber(extra.fall) or 1.1, 0.2, 6),
		radius = math.clamp(tonumber(extra.radius) or 7, 1, 30),
	}, center)
	Sfx.play("bossStance", center)
end

-- ------------------------------------------------------------- bell toll

-- Rings on the sand, one per toll, each one jumped. They are drawn AT GROUND
-- HEIGHT and at the payload's own `band`, because the server's rule is
-- |playerR - r| < band/2 with a height test that a jump clears: a ring drawn
-- thinner than the band would be a ring players clip the edge of and never
-- understand why.
local function stepRings(now: number)
	if not rings then
		return
	end
	local alive = false
	local pulse = 0.5 + 0.5 * math.sin(now * 12)
	for k = 1, K.RING_SLOTS do
		local pool = ringPool[k]
		local r = if k <= rings.count then BrinejawPath.ringRadius(rings.start, rings.speed, rings.gap, k, now) else nil
		if not r then
			parkParts(pool)
		else
			alive = true
			local ground = rings.center.Y + BrinejawPath.sandY(r)
			local span = (math.pi * 2 * r) / K.RING_SEGS
			for i = 1, K.RING_SEGS do
				local theta = (i - 0.5) / K.RING_SEGS * math.pi * 2
				local slab = pool[i]
				slab.Size = Vector3.new(rings.band, K.RING_HEIGHT, span * 1.08)
				slab.CFrame = CFrame.new(
					rings.center.X + math.cos(theta) * r,
					ground + K.RING_HEIGHT * 0.5,
					rings.center.Z + math.sin(theta) * r
				) * CFrame.Angles(0, -theta, 0)
				-- Brightest close in, because that is where it is fastest to
				-- react to, and it dims as it runs out of energy.
				slab.Transparency = math.clamp(0.18 + 0.5 * (r / 78) - 0.12 * pulse, 0, 1)
			end
		end
	end
	if not alive and now > rings.until_ then
		rings = nil
	end
end

-- BELL TOLL. The head strikes the keeper's bell (the strike itself is the
-- pose channel's, kind "belltoll") and rings walk out from the tower.
K.EVENTS.serpentRings = function(position: Vector3, extra)
	local center = towerFoot(position)
	if not nearCamera(center, K.BRINE_CULL) then
		return
	end
	local start = tonumber(extra.start) or Workspace:GetServerTimeNow()
	local count = math.clamp(math.floor(tonumber(extra.count) or 3), 1, K.RING_SLOTS)
	local speed = math.clamp(tonumber(extra.speed) or 26, 1, 200)
	local gap = math.clamp(tonumber(extra.gap) or 1.05, 0.05, 6)
	rings = {
		center = center,
		start = start,
		count = count,
		speed = speed,
		gap = gap,
		band = math.clamp(tonumber(extra.band) or 2.6, 0.5, 12),
		-- When the last ring can no longer be anywhere: `ringRadius` nils out
		-- past 78, so this is when it gets there.
		until_ = start + (count - 1) * gap + 78 / speed,
	}
	for k = 1, K.RING_SLOTS do
		parkParts(ringPool[k])
	end
	-- THE BELL RINGS WHEN THE FIRST RING LEAVES, not when the packet arrived.
	-- REST.BELL is arena-local and hangs off the gallery, so this is the same
	-- point the head is posed to strike.
	local bell = center + BrinejawPath.REST.BELL
	task.delay(math.max(start - Workspace:GetServerTimeNow(), 0), function()
		Vfx.flash(bell, K.STORM.toll, 8, 0.5)
		Vfx.burst(bell, K.STORM.toll, 30)
		Sfx.play("bossSlam", bell)
		feelBlast(center, 40, K.SHAKE_RISE, 0.5, Color3.fromRGB(255, 236, 190))
	end)
end

-- ------------------------------------------------------------ tidal surge

-- THE FLOOD. Everything outside `floodR` is under risen water for the
-- set-piece's duration; the band inside it is the only ground left, and it is
-- being shelled (the same `rainChunks` the bombardment uses, off the payload
-- the shared `surgeRain` builds). The foam line at floodR is the whole read,
-- so it is the brightest thing drawn here.
local function stepSurge(now: number)
	if not surge then
		return
	end
	local ends = surge.start + surge.duration
	if now > ends + K.FLOOD_FADE then
		surge = nil
		parkParts(floodPool.water)
		parkParts(floodPool.edge)
		return
	end
	local rise = math.clamp((now - surge.start) / K.FLOOD_RISE, 0, 1)
	local fade = math.clamp((now - ends) / K.FLOOD_FADE, 0, 1)
	local depth = K.FLOOD_DEPTH * rise * (1 - fade)
	local inner = surge.floodR
	local outer = math.max(K.FLOOD_OUTER, inner + 6)
	local mid = (inner + outer) * 0.5
	local run = outer - inner
	local pulse = 0.5 + 0.5 * math.sin(now * 6)

	for i = 1, K.FLOOD_SEGS do
		local theta = (i - 0.5) / K.FLOOD_SEGS * math.pi * 2
		local cos, sin = math.cos(theta), math.sin(theta)
		local facing = CFrame.Angles(0, -theta, 0)
		-- The water: one sector slab per segment, its top surface standing
		-- FLOOD_DEPTH over the beach it drowned. Translucent, so the sand and
		-- the rubble under it still read - a wall of opaque water would hide
		-- the thing the player is trying to walk back out of.
		local waterY = surge.center.Y + BrinejawPath.sandY(mid)
		local slab = floodPool.water[i]
		slab.Size = Vector3.new(run, math.max(depth, 0.1), (math.pi * 2 * mid) / K.FLOOD_SEGS * 1.08)
		slab.CFrame = CFrame.new(surge.center.X + cos * mid, waterY + depth * 0.5, surge.center.Z + sin * mid) * facing
		slab.Transparency = math.clamp(0.55 + 0.45 * fade, 0, 1)

		-- ...and the line you have to stay inside of.
		local edgeY = surge.center.Y + BrinejawPath.sandY(inner)
		local edge = floodPool.edge[i]
		edge.Size = Vector3.new(1.4, 0.9 + 0.5 * rise, (math.pi * 2 * inner) / K.FLOOD_SEGS * 1.1)
		edge.CFrame = CFrame.new(surge.center.X + cos * inner, edgeY + 0.5, surge.center.Z + sin * inner) * facing
		edge.Transparency = math.clamp(0.18 + 0.16 * pulse + 0.66 * fade, 0, 1)
	end
end

K.EVENTS.serpentSurge = function(position: Vector3, extra)
	local center = towerFoot(position)
	if not nearCamera(center, K.BRINE_CULL) then
		return
	end
	local payload = {
		start = tonumber(extra.start) or Workspace:GetServerTimeNow(),
		duration = math.clamp(tonumber(extra.duration) or 10, 1, 60),
		floodR = math.clamp(tonumber(extra.floodR) or 46, 8, K.FLOOD_OUTER - 6),
		seed = tonumber(extra.seed) or 0,
	}
	surge = {
		center = center,
		start = payload.start,
		duration = payload.duration,
		floodR = payload.floodR,
	}
	-- THE SURGE'S MASONRY IS NOT A SECOND ATTACK. Both sides build the derived
	-- rain payload with `surgeRain` and hand it to the same `rainChunks`, so
	-- there is exactly one table of numbers for it and neither side typed it.
	startRain(BrinejawPath.surgeRain(payload), center)
	Sfx.play("bossRise", center)
	Sfx.play("bossRoar", center)
	feelBlast(center, 70, K.SHAKE_RISE, 1.2, Color3.fromRGB(190, 240, 236))
end

-- --------------------------------------------------------------- polyps

-- The heal mechanic's visuals. The polyps are ordinary spawned creatures -
-- killable, small - and everything about their damage is the server's; this
-- draws the thing that makes them urgent: a feed-beam from each one to the
-- serpent and a clock that runs out. If the clock wins, the boss heals.
local function brinejawHead(): Vector3?
	local creatures = Workspace:FindFirstChild(K.CREATURES_FOLDER)
	if not creatures then
		return nil
	end
	for _, model in creatures:GetChildren() do
		if model:IsA("Model") and model:GetAttribute("Pose") == "brinejaw" then
			return model:GetPivot().Position
		end
	end
	return nil
end

local function stepPolyps(now: number)
	if not polyps then
		return
	end
	if now > polyps.deadline + 0.6 then
		polyps = nil
		parkParts(polypPool.beams)
		parkParts(polypPool.clocks)
		return
	end
	local head = brinejawHead() or polyps.head
	polyps.head = head
	local left = math.clamp((polyps.deadline - now) / math.max(polyps.duration, 1e-3), 0, 1)
	local rate = 2.4 + 7 * (1 - left) -- it strobes faster as the clock runs out
	local alpha = 0.30 + 0.28 * (0.5 + 0.5 * math.sin(now * rate * math.pi * 2))

	for i = 1, K.POLYP_MAX do
		local at = polyps.positions[i]
		local beam, clock = polypPool.beams[i], polypPool.clocks[i]
		if not at or not head then
			beam.Transparency = 1
			beam.CFrame = K.PARKED
			clock.Transparency = 1
			clock.CFrame = K.PARKED
		else
			local from = at + Vector3.new(0, 1.6, 0)
			local reach = head - from
			if reach.Magnitude > 1 then
				beam.Size = Vector3.new(K.POLYP_BEAM_THICK, K.POLYP_BEAM_THICK, reach.Magnitude)
				beam.CFrame = CFrame.lookAt(from + reach * 0.5, head)
				beam.Transparency = alpha
			end
			-- The clock is a disc that closes on the polyp: its size IS the time
			-- left, the same language the stagger window speaks.
			local r = 4.6 * (0.18 + 0.82 * left)
			clock.Size = Vector3.new(0.14, r * 2, r * 2)
			clock.CFrame = CFrame.new(surfaceUnder(at) + Vector3.new(0, 0.14, 0)) * CFrame.Angles(0, 0, math.rad(90))
			clock.Transparency = alpha
		end
	end
end

K.EVENTS.serpentPolyps = function(position: Vector3, extra)
	if not nearCamera(position, K.BRINE_CULL) then
		return
	end
	local deadline = tonumber(extra.deadline) or (Workspace:GetServerTimeNow() + 12)
	local positions = {}
	if type(extra.positions) == "table" then
		for _, at in extra.positions do
			if typeof(at) == "Vector3" and #positions < K.POLYP_MAX then
				table.insert(positions, at)
			end
		end
	end
	polyps = {
		positions = positions,
		deadline = deadline,
		-- The bar's full length, measured from now, so the disc reads the same
		-- for a player who was here when they spawned and one who was not.
		duration = math.max(deadline - Workspace:GetServerTimeNow(), 0.5),
		head = nil,
	}
	for _, at in positions do
		Vfx.burst(at + Vector3.new(0, 1, 0), K.STORM.polyp, 18)
		Vfx.ring(surfaceUnder(at) + Vector3.new(0, 0.15, 0), 1, 5, 0.5, K.STORM.polyp)
	end
	Sfx.play("bossRise", position)
end

-- One polyp resolved. `healed = false` is the party's win on that one - it
-- was broken in time, so it pops and the beam it was feeding goes out.
-- `healed = true` is the miss: it detonates, and the heal visibly runs up the
-- beam into the serpent, so the cost of ignoring one is watched rather than
-- read off a health bar.
K.EVENTS.polypBurst = function(position: Vector3, extra)
	if not nearCamera(position, K.BRINE_CULL) then
		return
	end
	local healed = extra.healed == true
	local point = surfaceUnder(position) + Vector3.new(0, 0.15, 0)
	if polyps then
		for i, at in polyps.positions do
			if (at - position).Magnitude <= 8 then
				table.remove(polyps.positions, i)
				break
			end
		end
	end
	if not healed then
		Vfx.burst(point + Vector3.new(0, 1, 0), K.STORM.polyp, 22)
		Vfx.ring(point, 1, 7, 0.4, K.STORM.polyp)
		Sfx.play("hitCrack", position)
		return
	end
	local radius = math.clamp(tonumber(extra.radius) or 12, 2, 40)
	Vfx.flash(point + Vector3.new(0, 2, 0), K.STORM.polyp, 9, 0.45)
	Vfx.burst(point + Vector3.new(0, 1, 0), K.STORM.polyp, 50)
	Vfx.shockwave(point, 2, radius, 0.5, K.STORM.polyp, 0.5)
	Sfx.play("bossSlam", position)
	feelBlast(position, radius, K.SHAKE_SLAM, 0.5, Color3.fromRGB(180, 255, 232))
	-- The heal running up the beam: five beads, so where it went is not a
	-- guess.
	local head = brinejawHead()
	if head then
		for i = 1, 5 do
			task.delay(i * 0.06, function()
				Vfx.flash(point:Lerp(head, i / 5), K.STORM.polyp, 2.4, 0.22)
			end)
		end
		task.delay(0.4, function()
			Vfx.burst(head, K.STORM.polyp, 26)
		end)
	end
end

-- ------------------------------------------------------------- the geysers
--
-- Stance-1 pressure filler (REVISION 2 §2): eight bursts of pressurised water
-- come up through the sand around wherever the party is standing, one every
-- 0.7 s. Because the positions are scattered around PLAYERS - which is a fact
-- only the server has - they cannot be derived from a seed on both sides, so
-- the payload carries them outright: `bursts = { { pos, at }, ... }`, each
-- `at` on the server clock.
--
-- EACH BURST LEADS ITSELF. The marker opens 0.9 s before that burst's own `at`
-- rather than the volley's start, so the eighth one is warned as clearly as
-- the first, and a player adopting the volley halfway through sees exactly the
-- markers that are live.
K.GEY_MAX = 12 -- the row fires ~8; 12 is that plus a re-fire overlapping itself
K.GEY_LEAD = 0.9 -- REVISION 2 §2: how far the marker runs ahead of the water
K.GEY_JET_H = 17.0 -- how high the column goes, well over head height
K.GEY_JET_LIFE = 0.55 -- up and back down
--
-- ...AND WITH THE FX PACK IMPORTED IT IS NOT WATER AT ALL. The user asked for
-- the eruption specifically: a STONE SPIKE tears up out of the sand where the
-- jet used to be. That is a truthful change and not only a prettier one,
-- because of what the attack actually is. `CreatureService.armGeysers` picks
-- every burst position ONCE, at fire time, off the players' positions in that
-- frame, and never re-aims - its own comment says "AND THE LIST IS
-- DELIBERATELY STALE... the later bursts land where you WERE". A jet of water
-- is a thing that is happening; a slab of reef standing in the sand is a thing
-- that HAPPENED at a spot decided a second ago and cannot follow you. Nothing
-- about the placement changes here and nothing needed to: the spike stands at
-- the payload's own point, exactly as the column did.
--
-- THE ANIMATION, IN SECONDS, and it is longer than the jet's 0.55. The spike
-- slides up out of the sand, stands, and sinks back; a rise that took 0.55 s
-- for the whole cycle would be a rock POPPING, which reads as a spawn rather
-- than as an eruption. It is still not left standing on safe ground - the sink
-- is part of the budget - and 1.0 s against the jet's 0.55 is 0.45 s more of
-- cosmetic rock over ground whose damage fired on the frame `at` arrived.
K.GEY_SPIKE_RISE = 0.25 -- out of the sand
K.GEY_SPIKE_HOLD = 0.50 -- standing
K.GEY_SPIKE_SINK = 0.25 -- and back down
K.GEY_SPIKE_LIFE = 1.00 -- = RISE + HOLD + SINK; the pack's window
K.GEY_SPIKE_VARIANTS = 3 -- BrinejawFx_Spike1/2/3
K.geysers = nil
K.geyPool = nil

-- How long a burst is drawn for, which is not the same number in both worlds
-- and is asked in two places (the step's expiry and the payload's `until_`).
-- One function so they cannot drift apart, which is exactly how a pooled
-- marker gets recycled out from under a live burst.
K.geyLife = function(): number
	return if K.fxHas then K.GEY_SPIKE_LIFE else K.GEY_JET_LIFE
end

-- A STABLE NUMBER PER BURST, off the payload's own point.
--
-- Which spike a burst uses, how far it is spun and how big it is have to be
-- the same on every screen, because two players standing next to the same
-- eruption comparing notes is the cheapest way for a fight to stop feeling
-- solid. The position is the only thing every client has and the server never
-- re-aims it, so hashing it gives a per-burst constant with nothing to send.
-- Quantised to sixteenths of a stud first: the payload is a replicated
-- Vector3 and float equality across the wire is not something to bet a visual
-- on.
K.geyHash = function(at: Vector3): number
	local x = math.floor(at.X * 16) % 4096
	local z = math.floor(at.Z * 16) % 4096
	return (x * 73856093 + z * 19349663) % 1048576
end

-- Park a slot's whole variant triple.
K.parkGeySpikes = function(base: number)
	for v = 1, K.GEY_SPIKE_VARIANTS do
		local part = K.geyPool.spike[base + v]
		part.Transparency = 1
		part.CFrame = K.PARKED
	end
end

-- THE ERUPTION, as an animation rather than as a shape.
--
-- The spikes are authored TIP-UP with their base at y = 0 and nothing below
-- it (brinejaw_fx_gen's HANDOFF), which is what makes the whole move one
-- line: a piece pushed `h * (1 - k)` down is buried to exactly its own height
-- and one at k = 1 is standing on the sand. `h` is the PART'S OWN Size.Y, not
-- the authored number, so the per-burst scale jitter below cannot un-bury it.
--
-- STATIONARY, at `b.at_`, which is the payload's own point and never
-- re-derived. The server placed it once at fire time and its damage sphere
-- sits there; the only freedom taken here is yaw, which the HANDOFF permits
-- (the lean lives in the spike's top half, so a spun spike still meets the
-- beach flat) and TILT, which it forbids for the same reason.
K.drawGeySpike = function(b, base: number, collar: Part, radius: number, now: number)
	local hash = b.hash
	local variant = hash % K.GEY_SPIKE_VARIANTS + 1
	for v = 1, K.GEY_SPIKE_VARIANTS do
		if v ~= variant then
			local other = K.geyPool.spike[base + v]
			other.Transparency = 1
			other.CFrame = K.PARKED
		end
	end
	local spike = K.geyPool.spike[base + variant]
	local yaw = (hash // K.GEY_SPIKE_VARIANTS % 360) * (math.pi / 180)
	local scale = 0.82 + (hash // 4096 % 45) * 0.01 -- 0.82 .. 1.26

	-- RISE, HOLD, SINK, in seconds off the burst's own `at` - not normalised
	-- over the life, because the three phases have to keep their own durations
	-- if any of them is ever retuned.
	local t = now - b.at
	local k
	if t < K.GEY_SPIKE_RISE then
		-- Fast out of the ground and easing as it arrives: rock driven up by
		-- something under it does not accelerate on the way out.
		local u = t / K.GEY_SPIKE_RISE
		k = 1 - (1 - u) * (1 - u)
	elseif t < K.GEY_SPIKE_RISE + K.GEY_SPIKE_HOLD then
		k = 1
	else
		k = 1 - (t - K.GEY_SPIKE_RISE - K.GEY_SPIKE_HOLD) / K.GEY_SPIKE_SINK
	end
	k = math.clamp(k, 0, 1)

	spike.Size = K.geyPool.spikeSize[base + variant] * scale
	local h = spike.Size.Y
	spike.CFrame = CFrame.new(b.at_ + Vector3.new(0, h * (k - 0.5), 0)) * CFrame.Angles(0, yaw, 0)
	spike.Transparency = 0

	-- The collar of broken sand at its foot. It does NOT ride the spike - the
	-- ground it is made of never moved - so it sits on the beach and only
	-- opens up as the rock comes through it, then fades with the sink.
	collar.Size = K.geyPool.collarSize * Vector3.new(1, 0.55 + 0.45 * k, 1)
	collar.CFrame = CFrame.new(b.at_ + Vector3.new(0, collar.Size.Y * 0.5 - 0.1, 0)) * CFrame.Angles(0, -yaw, 0)
	collar.Transparency = 0.10 + 0.85 * (1 - k)
	-- Grit shaken loose while it is still climbing, and only then: a puff off
	-- a rock that has finished moving is a puff with nothing making it.
	if k < 1 and t < K.GEY_SPIKE_RISE and now >= (b.nextPuff or 0) then
		b.nextPuff = now + 0.08
		Vfx.puff(b.at_ + Vector3.new(0, 0.4, 0), Vfx.Color.sand, radius * 0.34)
	end
end

K.stepGeysers = function(now: number)
	local g = K.geysers
	if not g then
		return
	end
	if now > g.until_ then
		K.geysers = nil
		parkParts(K.geyPool.mark)
		parkParts(K.geyPool.clock)
		parkParts(K.geyPool.jet)
		parkParts(K.geyPool.spike)
		parkParts(K.geyPool.collar)
		return
	end
	for i = 1, K.GEY_MAX do
		local b = g.bursts[i]
		local mark, clock, jet = K.geyPool.mark[i], K.geyPool.clock[i], K.geyPool.jet[i]
		local collar = K.geyPool.collar[i]
		-- The slot's three spike variants. Only one is ever shown; the other
		-- two are parked, every frame, by `K.parkGeySpikes` - a variant that
		-- kept the CFrame it had last time this slot fired would be a second
		-- rock standing in a place the payload never named.
		local base = (i - 1) * K.GEY_SPIKE_VARIANTS
		if not b or now < b.at - g.lead or now > b.at + K.geyLife() then
			mark.Transparency = 1
			mark.CFrame = K.PARKED
			clock.Transparency = 1
			clock.CFrame = K.PARKED
			jet.Transparency = 1
			jet.CFrame = K.PARKED
			collar.Transparency = 1
			collar.CFrame = K.PARKED
			K.parkGeySpikes(base)
		elseif now < b.at then
			jet.Transparency = 1
			jet.CFrame = K.PARKED
			collar.Transparency = 1
			collar.CFrame = K.PARKED
			K.parkGeySpikes(base)
			-- The footprint at its true radius, and a disc closing inside it.
			-- THE COUNTDOWN ENDS AT THE WATER, not a beat before: `left` is 1 at
			-- the marker's birth and exactly 0 on the frame `at` arrives, so the
			-- inner disc has just vanished as the column comes through it.
			local left = math.clamp((b.at - now) / g.lead, 0, 1)
			mark.Size = Vector3.new(0.12, g.radius * 2, g.radius * 2)
			mark.CFrame = CFrame.new(b.at_ + Vector3.new(0, 0.12, 0)) * CFrame.Angles(0, 0, math.rad(90))
			mark.Transparency = 0.70 - 0.32 * (1 - left)
			local cr = g.radius * left
			clock.Size = Vector3.new(0.14, math.max(cr * 2, 0.1), math.max(cr * 2, 0.1))
			clock.CFrame = CFrame.new(b.at_ + Vector3.new(0, 0.16, 0)) * CFrame.Angles(0, 0, math.rad(90))
			clock.Transparency = 0.34
		else
			mark.Transparency = 1
			mark.CFrame = K.PARKED
			clock.Transparency = 1
			clock.CFrame = K.PARKED
			if not b.fired then
				b.fired = true
				if K.fxHas then
					-- IT IS ROCK COMING UP, so it throws sand and grit, not
					-- spray, and it does not sound like water. `reefShatter` is
					-- the shatter this arena already speaks (the masonry rain
					-- and the baited slam both use it), so the eruption joins a
					-- vocabulary instead of inventing one.
					Vfx.puff(b.at_ + Vector3.new(0, 0.6, 0), Vfx.Color.sand, 3.0)
					Vfx.burst(b.at_ + Vector3.new(0, 0.8, 0), K.BRINE.stone, 34)
					Vfx.shockwave(b.at_ + Vector3.new(0, 0.2, 0), 1, g.radius, 0.30, Vfx.Color.sand, 0.35)
					Sfx.play("reefShatter", b.at_)
					feelBlast(b.at_, g.radius, K.SHAKE_EXPLODE, 0.25, Color3.fromRGB(232, 226, 212))
				else
					Vfx.splash(b.at_, 2.2)
					Vfx.burst(b.at_ + Vector3.new(0, 1.5, 0), K.STORM.foam, 30)
					Sfx.play("spitSplashWater", b.at_)
					feelBlast(b.at_, g.radius, K.SHAKE_EXPLODE, 0.25, Color3.fromRGB(206, 240, 240))
				end
			end
			if K.fxHas then
				jet.Transparency = 1
				jet.CFrame = K.PARKED
				K.drawGeySpike(b, base, collar, g.radius, now)
			else
				collar.Transparency = 1
				collar.CFrame = K.PARKED
				K.parkGeySpikes(base)
				-- The column: up and back down inside JET_LIFE, so nothing is left
				-- standing on ground that is safe again.
				local u = (now - b.at) / K.GEY_JET_LIFE
				local h = K.GEY_JET_H * (1 - (2 * u - 1) ^ 2)
				jet.Size = Vector3.new(g.radius * 0.55, math.max(h, 0.2), g.radius * 0.55)
				jet.CFrame = CFrame.new(b.at_ + Vector3.new(0, h * 0.5, 0))
				jet.Transparency = 0.22 + 0.6 * u
			end
		end
	end
end

K.EVENTS.serpentGeysers = function(position: Vector3, extra)
	if type(extra.bursts) ~= "table" then
		return -- nothing derivable: the positions ARE the payload
	end
	if not nearCamera(towerFoot(position), K.BRINE_CULL) then
		return
	end
	local radius = math.clamp(tonumber(extra.radius) or 6, 1, 30)
	local bursts, last = {}, 0
	for _, row in extra.bursts do
		if type(row) == "table" and typeof(row.pos) == "Vector3" and #bursts < K.GEY_MAX then
			local at = tonumber(row.at) or Workspace:GetServerTimeNow()
			table.insert(bursts, {
				-- THE PAYLOAD'S OWN POINT, untouched. The server already
				-- grounds each burst on the beach profile
				-- (center.Y + sandY(r)) because its damage is a sphere test
				-- there; re-probing it here could slide the drawn marker onto
				-- a rock the sphere is not centred on.
				at_ = row.pos,
				at = at,
				fired = at <= Workspace:GetServerTimeNow(), -- adopted late: no late bang
				-- Which spike, spun how far, at what size - hashed off the
				-- point so every client's arena grows the same rocks.
				hash = K.geyHash(row.pos),
				nextPuff = 0,
			})
			last = math.max(last, at)
		end
	end
	if #bursts == 0 then
		return
	end
	K.geysers = {
		bursts = bursts,
		radius = radius,
		-- SENT, not assumed: the server ships `lead` beside the bursts so a
		-- retune of the row moves the drawn warning with the damage.
		lead = math.clamp(tonumber(extra.lead) or K.GEY_LEAD, 0.1, 5),
		-- ...and the window is as long as whatever is actually being drawn -
		-- the spike's full rise-hold-sink with the pack, the column's 0.55
		-- without it. One authority, because `until_` and the step's own
		-- expiry disagreeing is a marker deleted mid-eruption.
		until_ = last + K.geyLife(),
	}
	Sfx.play("bossStance", position)
end

-- -------------------------------------------------------------- the spines
--
-- A radial volley with SAFE LANES BETWEEN THE SPINES (REVISION 2 §3). Lane k's
-- centre is `bearing0 + k * 2pi/lanes` on both sides of the wire, and a spine
-- hits you when its radius crosses yours and you are within `laneHalf` of a
-- centre - grounded or airborne, so there is nothing to jump and the only
-- answer is to be between two of them.
--
-- WHAT IS DRAWN IS THEREFORE THE LANE, NOT JUST THE SPINE. A flying blade
-- alone is a dodge you have to eyeball at 55 studs/s; the ground strip ahead
-- of it says which slice of sand it will have crossed, and the bare sand
-- either side of that strip is the answer. The gaps stay completely undrawn -
-- calm - because in a fight this busy an empty lane is the loudest thing that
-- can be said about it.
K.VOLLEY_LANES = 12 -- the row fires ~10
K.VOLLEY_SWATH = 3 -- ground strips ahead of each spine
K.VOLLEY_INNER = 8.0 -- where a spine leaves the coils
K.VOLLEY_STEP = 7.0 -- studs between one ground strip and the next
K.VOLLEY_BOLT = Vector3.new(5.0, 2.6, 0.7) -- long, and TALL: jumping is not it
K.volley = nil
K.volleyPool = nil

-- PHASE A SEAM, CLOSED - AND IT HAD GONE BAD. This waited on
-- `BrinejawPath.spineLane` and called it as `spineLane(bearing0, lanes, k)`.
-- The helper has since landed with a completely different shape:
-- `spineLane(payload, center, worldPos)`, the INVERSE question - given a
-- point, which lane is it in - because that is what both hit tests need. So
-- the moment the pose lane shipped it, this seam went from a harmless
-- fallback to a call that indexes a number and throws inside the Heartbeat,
-- taking every step after it down with the frame. The lesson is the seam's
-- own: a wrapper that waits on a name is waiting on a NAME, and a name is not
-- a signature.
--
-- There is no forward map (lane index -> bearing) in BrinejawPath to call, so
-- the contract's one line lives inline at its single call site below, where
-- it can be read next to the swath it places.
K.stepVolley = function(now: number)
	local v = K.volley
	if not v then
		return
	end
	-- THE SERVER'S OWN RADIUS: `speed * (now - start)` from zero, which is what
	-- `spineHits` measures and what its expiry (start + reach/speed) counts.
	-- Starting this at VOLLEY_INNER instead would run the drawn spine 8/55 =
	-- 0.15 s ahead of the one that hits - a marker that has visibly passed you
	-- while the damage has not, which is the wrong direction to be wrong in.
	-- The blade is simply not drawn until it is clear of the coils.
	local r = v.speed * (now - v.start)
	if r > v.reach + K.VOLLEY_STEP then
		K.volley = nil
		parkParts(K.volleyPool.bolts)
		parkParts(K.volleyPool.swath)
		return
	end
	-- Before the volley leaves (it is armed on the first windup frame to fly
	-- when the windup ends) the lanes are drawn along their WHOLE length: that
	-- windup is the read, and the answer to it is to be standing between two
	-- bearings before anything moves.
	local launched = r >= v.inner
	local pulse = 0.5 + 0.5 * math.sin(now * 10)
	for k = 1, K.VOLLEY_LANES do
		local bolt = K.volleyPool.bolts[k]
		if k > v.lanes then
			bolt.Transparency = 1
			bolt.CFrame = K.PARKED
			for j = 1, K.VOLLEY_SWATH do
				local strip = K.volleyPool.swath[(k - 1) * K.VOLLEY_SWATH + j]
				strip.Transparency = 1
				strip.CFrame = K.PARKED
			end
		else
			-- Lane k's centre, the contract's formula and the one line of
			-- geometry this attack has. `spineLane` is the inverse of it and
			-- cannot serve here; see the note above.
			local theta = v.bearing0 + (k - 1) * (math.pi * 2 / v.lanes)
			local cos, sin = math.cos(theta), math.sin(theta)
			local facing = CFrame.Angles(0, -theta, 0)
			if launched and r <= v.reach then
				local ground = v.center.Y + BrinejawPath.sandY(r)
				bolt.Size = K.VOLLEY_BOLT
				bolt.CFrame = CFrame.new(
					v.center.X + cos * r,
					ground + K.VOLLEY_BOLT.Y * 0.5 + 0.2,
					v.center.Z + sin * r
				) * facing
				bolt.Transparency = 0.05
			else
				bolt.Transparency = 1
				bolt.CFrame = K.PARKED
			end
			-- The ground it is ABOUT to cross. The strip is as wide as the lane
			-- is at its own radius (the lane is an angle, so it fans), which is
			-- the same widening the server's `laneHalf` test does - drawing a
			-- constant width would promise safety at the far edge that the hit
			-- does not honour.
			for j = 1, K.VOLLEY_SWATH do
				-- In flight the strips run AHEAD of the blade (the ground it is
				-- about to cross); during the windup they are spread over the
				-- whole lane instead, which is the same three parts saying the
				-- larger thing: this bearing, all the way out.
				local rj = if launched
					then r + j * K.VOLLEY_STEP
					else v.inner + (v.reach - v.inner) * ((j - 0.5) / K.VOLLEY_SWATH)
				local strip = K.volleyPool.swath[(k - 1) * K.VOLLEY_SWATH + j]
				if rj > v.reach then
					strip.Transparency = 1
					strip.CFrame = K.PARKED
				else
					local ground = v.center.Y + BrinejawPath.sandY(rj)
					strip.Size = Vector3.new(K.VOLLEY_STEP * 0.86, 0.14, math.max(2 * rj * math.sin(v.laneHalf), 1.2))
					strip.CFrame = CFrame.new(v.center.X + cos * rj, ground + 0.09, v.center.Z + sin * rj) * facing
					-- Nearest strip brightest: it is the one about to be true.
					strip.Transparency = math.clamp(0.34 + 0.16 * (j - 1) - 0.12 * pulse, 0, 1)
				end
			end
		end
	end
end

K.EVENTS.serpentSpines = function(position: Vector3, extra)
	local center = towerFoot(position)
	local reach = math.clamp(tonumber(extra.reach) or 70, 12, 200)
	if not nearCamera(center, reach + K.BRINE_MARGIN) then
		return
	end
	K.volley = {
		center = center,
		start = tonumber(extra.start) or Workspace:GetServerTimeNow(),
		bearing0 = tonumber(extra.bearing0) or 0,
		lanes = math.clamp(math.floor(tonumber(extra.lanes) or 10), 1, K.VOLLEY_LANES),
		laneHalf = math.clamp(tonumber(extra.laneHalf) or math.rad(7), math.rad(1), math.rad(30)),
		speed = math.clamp(tonumber(extra.speed) or 55, 1, 300),
		reach = reach,
		inner = K.VOLLEY_INNER,
	}
	parkParts(K.volleyPool.bolts)
	parkParts(K.volleyPool.swath)
	Sfx.play("bossSpine", center)
end

-- ------------------------------------------------------------ the coilslam
--
-- A mid-body loop rises off the tower and crashes along the LINE through it at
-- `bearing` (REVISION 2 §4). Two things have to be drawn and they are opposite
-- in meaning:
--
--   BEFORE  the line is a hazard band and the countdown is a bar sliding down
--           it from the far end, reaching the tower on the impact frame. NOT
--           before it: this is the project's most repeated bug and the
--           arithmetic is written in u below.
--   AFTER   the same band is a MELEE WINDOW. The loop lies on the sand across
--           the arena from U 0.5 to 0.85 and the server makes the creature
--           damageable at full rate, so the band turns gold - the one colour
--           this game uses for "hit it NOW" - and shimmers along its length.
--
-- IT IS ONE-SIDED, AND IT USED NOT TO BE. This drew rungs BOTH ways out of the
-- tower, on the reading that a loop crashing "along the line at `bearing`"
-- lands on both halves of that line. It does not: the loop is a HAIRPIN, and
-- `BrinejawPath.coilslamHits` tests distance along the aim RAY - r
-- SLAM_INNER..SLAM_OUTER out of the tower, one direction only. So half of what
-- was drawn was a hazard band painted over ground that never gets hit. That is
-- the worse direction for a marker to be wrong in than the obvious one: a
-- warning that under-promises costs a player health once, and a warning that
-- over-promises costs them the ten-second melee window it is standing on,
-- every single cast, while looking exactly like a working marker.
--
-- THE BAND'S ENDS ARE THE TWIN'S. Read off BrinejawPath rather than typed, so
-- a retune of the hit test cannot leave the drawing behind - the outer end was
-- 64 here against the server's 62 for exactly that reason.
--
-- THE WINDOW'S CLOCK COMES OUT OF THE PAYLOAD'S TWO CLOCKS AND NOTHING ELSE.
-- The crash is U 0.5, so the pose's whole length is 2 * (impactAt - start),
-- and the window closes at U 0.85 = impactAt + 0.7 * (impactAt - start).
K.COIL_RUNGS = 10 -- rungs down the one arm the loop actually lands on
K.COIL_INNER = BrinejawPath.SLAM_INNER or 14.0 -- coilslamHits' band, r 14..62
K.COIL_OUTER = BrinejawPath.SLAM_OUTER or 62.0
K.COIL_HALF = 5.0 -- fallback half-width; the payload and BrinejawPath win
K.COIL_WINDOW_U0 = 0.5 -- the crash
K.COIL_WINDOW_U1 = 0.85 -- the loop is lifted again
K.coil = nil
K.coilPool = nil

K.stepCoil = function(now: number)
	local c = K.coil
	if not c then
		return
	end
	if now > c.windowEnds + 0.3 then
		K.coil = nil
		parkParts(K.coilPool.rungs)
		parkParts(K.coilPool.caps)
		return
	end
	local span = (K.COIL_OUTER - K.COIL_INNER) / K.COIL_RUNGS
	local before = now < c.impactAt
	if before then
		local u = math.clamp((now - c.start) / math.max(c.impactAt - c.start, 1e-3), 0, 1)
		local pulse = 0.5 + 0.5 * math.sin(now * (7 + 9 * u))
		local dir = c.bearing
		local cos, sin = math.cos(dir), math.sin(dir)
		-- The closing bar: from the far end of the band to its near end,
		-- reaching COIL_INNER exactly at u = 1, which is impactAt.
		local capR = K.COIL_OUTER + (K.COIL_INNER - K.COIL_OUTER) * u
		local ground = c.center.Y + BrinejawPath.sandY(capR)
		local cap = K.coilPool.caps[1]
		cap.Color = K.SLAM_SAND
		cap.Size = Vector3.new(1.4, 1.5, c.half * 2.4)
		cap.CFrame = CFrame.new(c.center.X + cos * capR, ground + 0.8, c.center.Z + sin * capR)
			* CFrame.Angles(0, -dir, 0)
		cap.Transparency = 0.1
		for i = 1, K.COIL_RUNGS do
			local rr = K.COIL_INNER + span * (i - 0.5)
			local rung = K.coilPool.rungs[i]
			local gy = c.center.Y + BrinejawPath.sandY(rr)
			rung.Color = K.SLAM_SAND
			rung.Size = Vector3.new(span * 0.92, 0.3, c.half * 2)
			rung.CFrame = CFrame.new(c.center.X + cos * rr, gy + 0.15, c.center.Z + sin * rr)
				* CFrame.Angles(0, -dir, 0)
			rung.Transparency = 0.42 - 0.2 * pulse
		end
		return
	end

	if not c.crashed then
		c.crashed = true
		-- The sand it throws up, along the ONE arm it landed on. Six points
		-- rather than the four per arm this used, so the crash is as loud down
		-- its own line as the pair of them was down two.
		for i = 1, 6 do
			local rr = K.COIL_INNER + (K.COIL_OUTER - K.COIL_INNER) * ((i - 0.5) / 6)
			local at = Vector3.new(
				c.center.X + math.cos(c.bearing) * rr,
				c.center.Y + BrinejawPath.sandY(rr) + 0.4,
				c.center.Z + math.sin(c.bearing) * rr
			)
			Vfx.puff(at, Vfx.Color.sand, 3.2)
			Vfx.burst(at, Vfx.Color.sand, 26)
		end
		Sfx.play("bossSlam", c.center)
		Sfx.play("serpentSlam", c.center)
		feelBlast(c.center, K.COIL_OUTER * 0.6, K.SHAKE_SLAM, 0.6, Color3.fromRGB(240, 226, 200))
	end

	-- THE WINDOW. The band is gold and a glint runs along the fallen loop -
	-- subtle on purpose: it is an invitation, not a warning, and the arena is
	-- already carrying whatever else is in flight.
	parkParts(K.coilPool.caps)
	local left = math.clamp((c.windowEnds - now) / math.max(c.windowEnds - c.impactAt, 1e-3), 0, 1)
	local dir = c.bearing
	local cos, sin = math.cos(dir), math.sin(dir)
	for i = 1, K.COIL_RUNGS do
		local rr = K.COIL_INNER + span * (i - 0.5)
		local rung = K.coilPool.rungs[i]
		local gy = c.center.Y + BrinejawPath.sandY(rr)
		-- The glint travels outward along the loop at about a rung every
		-- tenth of a second, so the shimmer reads as one body lying there
		-- rather than ten parts blinking together.
		local glint = 0.5 + 0.5 * math.sin(now * 6 - i * 0.5)
		rung.Color = K.BRINE.window
		rung.Size = Vector3.new(span * 0.92, 0.5, c.half * 2)
		rung.CFrame = CFrame.new(c.center.X + cos * rr, gy + 0.25, c.center.Z + sin * rr) * CFrame.Angles(0, -dir, 0)
		rung.Transparency = math.clamp(0.62 - 0.26 * glint + 0.3 * (1 - left), 0, 1)
	end
end

K.EVENTS.serpentCoilslam = function(position: Vector3, extra)
	local center = towerFoot(position)
	if not nearCamera(center, K.COIL_OUTER + K.BRINE_MARGIN) then
		return
	end
	local now = Workspace:GetServerTimeNow()
	local start = tonumber(extra.start) or now
	local impactAt = tonumber(extra.impactAt) or (start + 1.0)
	K.coil = {
		center = center,
		bearing = tonumber(extra.bearing) or 0,
		start = start,
		impactAt = impactAt,
		-- The band the server measures with, from the payload first and from
		-- BrinejawPath second. 5 is the contract's number and the last resort:
		-- if the pose lane exported a constant under either of these names this
		-- picks it up, and if it did not, the REPORT says so.
		half = math.clamp(
			tonumber(extra.half) or BrinejawPath.COILSLAM_BAND or BrinejawPath.COILSLAM_HALF or K.COIL_HALF,
			1,
			20
		),
		windowEnds = impactAt + (K.COIL_WINDOW_U1 - K.COIL_WINDOW_U0) / K.COIL_WINDOW_U0 * (impactAt - start),
		crashed = now >= impactAt, -- adopted after the crash: no late boom
	}
	parkParts(K.coilPool.rungs)
	parkParts(K.coilPool.caps)
	Sfx.play("serpentSweepHigh", center)
end

-- ---------------------------------------------------------------- the bite
--
-- The reactive snap: it fires when someone stands inside 14 studs of the tower
-- for two seconds, and the whole move is over in under half a second. So this
-- is the one Brinejaw marker with NO pool and NO step - a ring closing onto
-- the aim, arriving exactly at `impactAt`, and a flash. A marker that outlived
-- this attack would be worse than none: it would say "danger" over ground that
-- was already safe again, in the one spot of the arena players have to keep
-- coming back to.
K.BITE_RING = 9.0

K.EVENTS.serpentBite = function(position: Vector3, extra)
	-- `aim` IS ARENA-LOCAL, and the Y in it is meaningless. It is the same
	-- (aimX, 0, aimZ) pair the pose channel publishes as its Aim attribute, so
	-- that the marker and the body cannot drift apart - which means it has to
	-- be added to the tower's foot to become a point on the beach. Read as a
	-- world position it would draw the snap at the map origin, silently, for
	-- the one attack that punishes standing next to the boss.
	local center = towerFoot(position)
	local aim = center
	if typeof(extra.aim) == "Vector3" then
		aim = center + Vector3.new(extra.aim.X, 0, extra.aim.Z)
	end
	if not nearCamera(aim, K.BITE_RING + K.BRINE_MARGIN) then
		return
	end
	local now = Workspace:GetServerTimeNow()
	-- However much of the snap is left. Clamped tight: this is a 0.45 s move
	-- and a payload that says otherwise does not get to leave a mark behind.
	local lead = math.clamp((tonumber(extra.impactAt) or (now + 0.2)) - now, 0.05, 0.8)
	local radius = math.clamp(tonumber(extra.radius) or K.BITE_RING, 2, 24)
	local point = surfaceUnder(aim) + Vector3.new(0, 0.15, 0)

	-- The cone, drawn as a ring collapsing onto the point it will close on:
	-- it reaches the jaws' own width exactly as they shut.
	Vfx.shockwave(point, radius, radius * 0.25, lead, K.SLAM_SAND, 0.25)
	Sfx.play("bossSnap", point)
	task.delay(lead, function()
		Vfx.flash(point + Vector3.new(0, 1.2, 0), K.SLAM_SAND, 6, 0.18)
		Vfx.burst(point + Vector3.new(0, 0.4, 0), Vfx.Color.sand, 26)
		Vfx.ring(point, radius * 0.3, radius, 0.22, K.BRINE.stone)
		Sfx.play("mawBite", point)
		feelBlast(point, radius, K.SHAKE_SLAM, 0.22, Color3.fromRGB(240, 226, 200))
	end)
end

-- Every Brinejaw broadcast attack, on the SERVER's clock rather than the
-- Heartbeat's `os.clock()` - see the section header. One call so the
-- Heartbeat below reads the same as it did.
local function stepBrinejawStorm()
	local now = Workspace:GetServerTimeNow()
	stepWave(now)
	stepRain(now)
	K.stepShards(now)
	stepRings(now)
	stepSurge(now)
	stepPolyps(now)
	K.stepStones(now) -- the bait glow: it rides the slam's windup
	K.stepGeysers(now)
	K.stepVolley(now)
	K.stepCoil(now)
end

-- ------------------------------------------------- Rimefang (the floe boss)
--
-- The killer whale under the pack ice. Like the serpent, nothing it throws is
-- a projectile - this is a POSITION fight, so every effect below answers one
-- of three questions and nothing else:
--
--   WHERE IS IT    while it is under the sheet you never see it and always
--                  know where it is: a dorsal wake, a cold glow tracking
--                  beneath the ice, and a spout when it comes up (the wake)
--   WHICH WAY      the wash is a WALL of slush shouldered across the floe
--                  along ONE bearing. A ring would be a lie: a ring says
--                  "leave the circle", and the answer to this is "put a berg
--                  between it and you", which only a travelling wall says
--   IS IT OPEN     the breach puts it ON the ice, beached for four seconds.
--                  That is the punish window and the whole party has to see
--                  it, so the ground under the animal carries the clock
--
-- THE TELL KINDS ARE BORROWED, and that is the awkward part. Rimefang's book
-- fires stock telegraph kinds (mark / burst / ringTell / gustTell / snap), so
-- the only thing in a payload that says WHICH whale-sized move is coming is
-- its RADIUS - the attack rows' own numbers. RIME_TELL mirrors them and
-- matches with a tight tolerance; a retuned row falls back to the stock frost
-- draw rather than breaking, and the ice island's frost-skinned hostiles
-- (brinecoil marks at r6) match nothing here.
--
-- ALL OF IT IS ABSENCE-SAFE. The mesh pack is a pending import and the pose
-- attributes may not be published yet: every read is nil-checked and the
-- worst case is an effect that does not draw.

-- Its own parts, so colouring them is fine - the no-Color rule is about
-- CREATURE parts, whose colours CombatFeedbackController owns.
K.RIME = {
	crest = Color3.fromRGB(206, 240, 255), -- the wall's lit spray
	slush = Color3.fromRGB(158, 194, 216), -- the churned ice it drags behind
	wake = Color3.fromRGB(150, 216, 250), -- the dorsal line on the sheet
	glow = Color3.fromRGB(92, 168, 220), -- the cold light under it
	crack = Color3.fromRGB(232, 248, 255), -- split sheet
	-- "IT HAS PICKED YOU", and deliberately NOT BRINE.window. That gold is
	-- the game's one universal "hit it NOW" signal - the serpent's stagger
	-- disc, and forty studs away in this very fight the beached window's
	-- clock - and the spy-hop's mark means the opposite: it is the animal
	-- naming its next victim. Two golds with opposite meanings inside one
	-- arena is worse than no colour at all. Dark for the same reason
	-- SKIN.frost is: 4.6:1 against the authored floe, 7.2:1 against the
	-- procedural one, where the old gold measured 1.4:1 and 2.2:1.
	mark = Color3.fromRGB(122, 30, 96),
	-- PHASE TWO, and it is the one warm colour this arena is ever allowed. It
	-- is never a mark on its own - only ever a thin rim on a mark that is
	-- already dark - so it cannot be confused with BRINE.window's "hit it now"
	-- gold, which is a filled disc under the animal. 3.96:1 against pure white,
	-- 2.95:1 against the frost it edges. See the note on the accent.
	hot = Color3.fromRGB(230, 72, 20),
	-- ...and the sea under the floe, once the floe is not there any more. Very
	-- nearly black: this is a HOLE, and the only thing a hole has to do is not
	-- look like ice.
	open = Color3.fromRGB(8, 20, 34),
}
-- The punish window is BRINE.window on purpose: one colour means "hit it now"
-- across every boss in the game, and a player only learns that once.

K.RIME_ID = "rimefang" -- Bosses.luau rimefang.creature, the row id on the model
K.ATTR_CREATURE_ID = "CreatureId" -- CreatureService's ATTR_ID
K.ATTR_SUBMERGE = "Submerge" -- 0..1 under the sheet (RimefangBodyController's pose)
K.RIME_CULL = 240 -- flat draw range for the arena-wide moments
K.RIME_MARGIN = 70 -- how far outside its own footprint an effect still draws

-- Which move a borrowed tell belongs to, by its radius (Bosses.luau,
-- rimefang.attacks). The tolerance is deliberately tighter than the gap to
-- the nearest neighbour on the list AND to the ice hostiles' r6 marks.
-- ...AND IT IS NOW THE FALLBACK, NOT THE DISPATCH. Every telegraph the whale
-- fires carries `move` (the attack's own name) from this kit onward, so the
-- branch is chosen by NAME and this table only answers a payload that predates
-- that field. Kept because a radius is still evidence when a name is missing,
-- and deleting it would make an old server draw nothing at all.
K.RIME_TELL = {
	bite = 17, -- "snap": the jaws, and the only move that is always coming
	spyhop = 7, -- "mark": it stands up and picks someone
	whiteout = 9, -- "mark": the storm closes
	icebreach = 14, -- "mark": it is under you and it is coming UP through the ice
	skyfall = 18, -- "mark": it is above you and it is coming DOWN
	flukeslam = 24, -- "burst": the tail comes up through a hole and hammers
	wash = 34, -- "gustTell": the wall of slush
}
-- TIGHTENED FROM 0.75, and it had to be: `icebreach` (14) sits one stud off
-- nothing, but `skyfall` (18) sits ONE stud off the bite (17), and at 0.75 the
-- two windows overlapped across [17.25, 17.75] - a radius in there matched
-- both, and which one won was table iteration order. Half the smallest gap on
-- the list, so every window is disjoint by construction; the ice island's r6
-- brinecoil marks still clear the spy-hop's 7 by 0.6.
K.RIME_TELL_TOL = 0.4

-- WHOSE MOMENT IS THIS. A radius is not evidence: Old Ribbonjaw prowls the
-- same island frost-skinned, and both `ribbonlash` and `vanish` carry r7 -
-- the spy-hop's number, inside the tolerance above. Matching on skin and a
-- number therefore stole a thief's tells and drew a whale's. The ANIMAL is
-- the evidence, so every whale-shaped draw asks rimeOwns() first, and an ice
-- hostile falls straight back through to the stock telegraph it always had.
-- The range is its own aggro (90) with room to spare, and eight THOUSAND
-- studs short of the ice island the hostiles live on (BossArenas.items.ice).
K.RIME_ARENA = 200
K.RIME_ISLAND = "ice" -- Bosses.luau rimefang.islandId
-- How far the shared arena row may sit from a payload before the client stops
-- believing it describes this fight (the roam disc, 28, with margin).
K.RIME_ANCHOR_TRUST = 120

-- The live pose the whale is actually in, published every frame by
-- CreatureService's rimefangDrive.
K.RF_ATTR_FACE = "FaceAngle" -- = creature.yaw0, which bossFacing() reads

-- THE BITE, from Bosses.luau rimefang.attacks.bite - and none of it except
-- `radius` is in the telegraph payload, because the stock tell sends only
-- kind/duration/radius/facing/skin. See the REPORT.
--   radius 17, cone rad(65)   a 130-degree mouth
--   lunge 14 over a 0.35s strike, and ATTACK_HANDLERS.snap fires at u >= 0.4
-- So the jaws close 0.14s AFTER the tell's own clock has run out, from a
-- point 5.6 studs further forward than the tell began at: the ground that
-- will be bitten reaches 22.6 studs from where the boss stands at the start
-- of the windup, closing to the bare 17 at the moment of the bite.
K.BITE_CONE = math.rad(65)
K.BITE_RADIUS = 17
K.BITE_LUNGE = 14
K.BITE_STRIKE = 0.35
K.BITE_LEAD = K.BITE_STRIKE * 0.4 -- strike time before the jaws close

-- ONE MARKER FOR THE TWO CONES: the bite's mouth and the wash's gathering
-- wall. Both make the same claim - "this ground, out to here, inside this
-- angle, is about to be hit" - and both are drawn from the boss's LIVE
-- bearing rather than the one latched into the payload, because updateBoss
-- keeps turning the animal through the whole windup (turnRate * 1.5, up to
-- 84 degrees across the bite's 0.7s) and its cone tests read the live one.
-- ...and one shape that is not a cone at all but wants every other line of
-- this machinery: the floequake's LANE. Sixty studs of sheet from the animal
-- out through whoever it picked, ten wide, heaved all at once - so what the
-- marker has to be is the strip, and the strip's EDGE is the whole answer.
K.WEDGE_BITE = 1
K.WEDGE_WASH = 2
K.WEDGE_LANE = 3
K.WEDGE_SLOTS = 3
K.WEDGE_SLABS = 9 -- the fan; nine boxes close the 130-degree arc exactly
K.WEDGE_RIM_THICK = 1.1 -- the boundary arc: the line to be standing outside
K.WEDGE_FADE = 0.18

-- THE LANE, from rimefang.floequake: 60 studs of heaved sheet, 10 wide. The
-- payload carries both (`length`, `width`); these stand in when it does not.
-- `width` is a FULL width in the contract and a HALF width in the corridor
-- draw (every slab is `w.width` to either side of the line), so the branch
-- halves it exactly once, on the way in.
K.QUAKE_LENGTH = 60
K.QUAKE_WIDTH = 10
K.QUAKE_HEAVE = 0.45 -- how long the sheet is still throwing itself about after

-- The punish windows, from the attack rows. The eruption's flop is short
-- (it is half in the water already); the skyfall's is the long one, because
-- a whale that has fallen seventy studs onto ice is going nowhere.
K.BEACHED_WINDOW = 4.0
K.BEACHED_RADIUS = 15
K.BEACHED_THRASH_GAP = 1.05 -- ~4 thrashes across the window, not a loop

-- The wall. Slabs laid along the wedge the server's own hit test uses
-- (inside `radius`, inside `cone` of `facing`), marching out from the boss:
-- what you see arrive is what counted.
K.WASH_SLABS = 16
K.WASH_INNER = 7 -- born at the whale's shoulder, not at its pivot
K.WASH_HEIGHT = 6.2 -- OVER eye height: a wall you cannot see past is the read
K.WASH_THICK = 2.4
K.WASH_APRON_LAG = 5.5 -- the churned slush trailing the crest
K.WASH_CONE = math.rad(70) -- rimefang.wash.cone, if a payload ever omits it
K.WASH_FADE = 0.3
-- HOW LONG THE CREST TAKES TO CROSS THE WHOLE WEDGE, and deliberately NOT the
-- payload's `duration`. ATTACK_HANDLERS.wash damages and shoves everyone
-- inside the cone in ONE frame, at the end of the windup - there is no
-- travelling hit to draw, and driving the crest off `duration` (0.9s) meant a
-- player at 30 studs watched their health drop 0.77 SECONDS before the wall
-- that took it reached them. The wall cannot arrive before it is drawn, so
-- the honest client-side floor on the lie is "as fast as still reads as a
-- wall": 34 studs in 0.22s puts the worst case at 0.19s, inside the frame
-- budget a player can attribute. `duration` still owns the slush's lifetime,
-- which is aftermath and is allowed to take its time. The REAL fix is
-- server-side (stagger the damage along the wedge) - see the REPORT.
K.WASH_SWEEP = 0.22
K.WASH_SPRAY_GAP = 0.07

-- The sheet it breaks: cracks radiating from a crash, which stay put for the
-- punish window because broken ice does not heal in four seconds.
K.CRACK_SLABS = 16
K.CRACK_HOLD = 3.2
K.CRACK_FADE = 1.4

-- The wake: a knuckle over the head and two arms splaying back off it.
K.WAKE_ARMS = 6 -- per side
K.WAKE_SPLAY = math.rad(27)
K.WAKE_STEP = 3.4 -- distance between one arm slab and the next
K.WAKE_SPRAY_GAP = 0.4
K.WAKE_SPOUT_AT = 0.35 -- Submerge below this and it is breaking the surface

-- ------------------------------------------------------ the new kit
--
-- THE COMPLAINT THIS ANSWERS: "the attacks don't really hit the player; it's
-- mainly the whale rushing." Every move below lands ON A MARKED POINT under
-- somebody's feet, and the animal's body is the SPECTACLE that gets it there -
-- so the client's whole job is to make the point legible early and the body
-- legible as the thing converging on it. Two of them use the arena itself:
-- one goes UNDER the sheet and comes up through it, one leaves the sheet
-- entirely and comes back down through it.
--
-- THE CONTINUOUS HALF IS ATTRIBUTES, NOT EVENTS. A tell fires once and is
-- gone; "there is something under the ice and it is coming this way" is a
-- state, and a state wants a value read every frame. The server publishes
-- five (see the REPORT): "Move" (the attack running, "" for none),
-- "PoseCenter" (where its body is, which under the sheet is nowhere the model
-- pivot can be trusted to be), and "Submerge"/"Burst"/"Skyfall" as 0..1
-- phases. All five are optional at every read: a server that publishes none
-- of them loses the crack web and the shadow and keeps every tell.
K.RIME_ATTR_MOVE = "Move"
K.RIME_ATTR_POSE = "PoseCenter"
K.RIME_ATTR_BURST = "Burst" -- 0..1, the sheet doming before the eruption
K.RIME_ATTR_SKY = "Skyfall" -- 0..1, height above the floe: 0 ground, 1 apex

-- The two new footprints, from the attack rows. Only used when a payload
-- omits its own `radius`; the payload's number always wins, because the
-- server's hit test is the one that counts.
K.ICEBREACH_RADIUS = 14
K.SKYFALL_RADIUS = 18

-- THE CRACK WEB. While it is under the ice on its way to you, a spreading
-- web of dark splits on the surface over its back - the tell BEFORE the lock
-- ring, and the one that says which way it is travelling. Drawn dark
-- (SKIN.frost, 4.6:1 on the authored floe) because a white crack on white
-- ice is not a crack.
K.WEB_ARMS = 16
K.WEB_REACH = 13 -- how far off the animal's back the splits run
K.WEB_SPROUT = 0.9 -- seconds for a freshly-opened web to reach full length
K.WEB_GAP = 0.42 -- seconds between one groan of splitting ice and the next
K.WEB_SUBMERGED = 0.45 -- Submerge above this and the sheet is over it

-- THE LOCK. Both eruption and slam pick a point and commit to it, and the
-- disc is that point at its REAL radius for the whole window - a footprint
-- that grows into honesty is dishonest until it gets there. The ring outside
-- it is the clock, closing onto the disc as the time runs out.
K.LOCK_ARC = 14 -- slabs in the closing ring
K.LOCK_OPEN = 2.3 -- the ring starts this many times the radius out
K.LOCK_FADE = 0.25

-- THE DESCENDING SHADOW. Seventy studs up, pitched over, and falling: the
-- only honest warning is the dark it is about to put you in. Converges on the
-- locked mark, and DARKENS on the way down rather than lightening, because
-- the read is "it is nearly here", not "it is far away".
K.SHADOW_HIGH = 30 -- its width at the apex: wide, weak, unmistakable
K.SHADOW_FADE = 0.28

-- THE SHOCKWAVE the slam throws off. Forty studs in 0.7s is a wave you can
-- outrun from about halfway, and the ring is drawn as a ring for exactly that
-- reason: what matters is the LINE, and which side of it you are on.
K.SHOCK_ARC = 24
K.SHOCK_RADIUS = 40
K.SHOCK_TIME = 0.7
K.SHOCK_THICK = 1.6

-- ------------------------------------------------------ phase two: SHATTER
--
-- At half health the server flips `Enraged` and the whale's very next attack
-- is the opener that changes the arena: it rears, roars, and comes down flat
-- on the sheet. The floe splits from the centre to the rim, the four patches
-- of young ice out by the edge break open into water that STAYS OPEN for the
-- rest of the fight, and the blizzard closes and does not lift.
--
-- THREE PAYLOADS, THREE DIFFERENT JOBS, and it matters that they are separate:
--   telegraph{kind="burst", move="shatter", r26}  the windup, at the BOSS
--   slam{move="shatter", r26}                     the impact
--   rimeShatter{position=centre, radius=120, sites}  the ARENA changing
-- The first two are somewhere to not be standing and are drawn at the whale's
-- own scale. The third is not an attack at all - it damages nobody, it is the
-- floor being rewritten - and it is fired ONCE, from the arena centre, which
-- is why it cannot ride the slam: a slam is a place, and this is the room.
--
-- THE WINDUP READS "GET AWAY FROM IT" AND ALSO "ALL OF THIS IS ABOUT TO GO".
-- The lock machinery already says the first thing perfectly (a dark disc at
-- the real radius, a ring closing onto it), so the opener borrows it whole and
-- adds the one thing no other tell in the fight has: a ring rushing IN from
-- the rim of the floe. Every other marker in this arena grows or contracts
-- inside its own footprint; this one starts 120 studs away, at the edge of the
-- world the player is standing on, and there is nothing else it could mean.
K.SHATTER_RADIUS = 26 -- the attack row's own footprint, if a payload omits it
K.RIME_FLOOR = 120 -- BossArenas.items.ice.floorRadius, if the row is missing
-- The cracks, centre to rim. 26 arms is one every 13.8 degrees, which at the
-- rim is a 32-stud gap - enough that the sheet reads as SPLIT rather than as a
-- dartboard, and few enough that the whole draw is 26 moved parts a frame.
K.SHATTER_ARMS = 26
K.SHATTER_GROW = 0.55 -- the splits running out to the rim
K.SHATTER_FADE = 4.0 -- ...and settling into the ice behind them
K.SHATTER_INNER = 0.5 -- x SHATTER_RADIUS: where an arm starts, off the impact
K.SHATTER_WIDE = { 0.7, 2.1 } -- a crack's width, jittered per arm

-- THE OPEN WATER. Four discs of it, at the thin-ice hubs, and PERSISTENT: the
-- floe does not re-freeze inside one fight. They are drawn as one thing with
-- the chill pools the server spawns on top of them (EVENTS.poolSpawn, which
-- already ripples a ring between 0.45r and r) - the water sits INSET from the
-- pool's outer ring and the slush collar lands exactly on it, so the pool's
-- pulse reads as the swell lapping the edge of the hole rather than as a
-- second marker stacked on the first.
-- FOUR, from BossArenas.items.ice.thinIce, and the pool's own ceiling: a
-- payload listing more sites than this draws the first four and drops the
-- rest, rather than indexing a hole that was never built.
K.RIFT_SITES = 4
K.RIFT_RIM = 14 -- slush slabs round one hole
K.RIFT_RADIUS = 13 -- BossArenas.items.ice.thinIceRadius, if the row is missing
K.RIFT_INSET = 0.94 -- x radius: the water's own edge, inside the collar
-- How far a payload's site may sit from the arena row's own hub before the
-- client stops believing the two describe the same patch of ice. A quarter of
-- a hub's radius: the mesh was measured to the stud (BossArenas' note) and a
-- server working off the same row cannot be further out than rounding.
K.RIFT_TRUST = 4
-- HOW OFTEN A HOLE SWELLS, and the reason it has to do it itself.
--
-- The server spawns a real chill pool on each hub through the ordinary pool
-- path, at duration 3600 - the rest of the fight - and EVENTS.poolSpawn draws
-- a ring on it every half-second. But poolSpawn caps its own lifetime at 20
-- seconds (a guard against exactly the runaway task loop an hour-long pool
-- would be), so the ripple stops after twenty seconds while the hazard runs on
-- for the whole fight: water that has visibly gone still, and is still cold.
--
-- That cap is not this lane's to raise - it belongs to every pool in the game,
-- and a boss's hazard is not a reason to let some fish's spit ripple for an
-- hour - so the hole carries its own swell instead. One site per tick,
-- round-robin, off the step that is already running: no loop to leak, no task
-- to cancel, and it stops the frame the water closes.
K.RIFT_SWELL = 0.55 -- seconds between one hole's swell and the next hole's
-- ...AND HOW LONG THE WATER OUTLIVES THE ANIMAL. The holes are the only thing
-- this file draws that has no clock of its own, so their clock is the boss:
-- the model leaves the world on `bossDown` (and on a wipe, and on a despawn),
-- and this is the grace before the client believes it. Longer than `rimefang`'s
-- own 0.5s rescan, so a cache miss between scans can never close the floe.
K.RIFT_GRACE = 2.0

-- THE BIGGEST KICK IN THE FIGHT, and bigger than SHAKE_SLAM (rad 5) on
-- purpose: every other slam in this arena breaks a hole in the sheet, and this
-- one breaks the sheet.
K.RIME_SHAKE = math.rad(7)

-- THE PHASE-TWO ACCENT. From the shatter on, every rime telegraph wears a thin
-- red-orange RIM - the wedge boundaries, the lock's closing ring - while its
-- DARK base (the fan, the disc, the shadow) is untouched. The read is "the
-- same tells, hotter", learnable without a text card, and the contrast the
-- palette pass measured is preserved exactly because the parts that carry it
-- do not change: SKIN.frost still fills every footprint at 4.6:1 on the
-- authored floe and 7.2:1 on the procedural one.
--
-- The accent itself is measured too, because a rim IS a graphic that carries
-- meaning: RIME.hot is 3.96:1 against pure white and 2.95:1 against the frost
-- it edges, so it separates from the mark it sits on AND holds its own against
-- the ice and the whiteout's fog. A brighter orange would have measured 3.0:1
-- against white - inside the rounding of the minimum - and this fight is
-- fought in a blizzard. (The attribute it keys off is K.ATTR_ENRAGED, which
-- this file already reads for every boss's flicker.)

local wash: any = nil
local washPool = { crest = {}, apron = {} }
local wedges: { any } = {}
local wedgePool: { any } = {}
local crackPool: { Part } = {}
local wakePool: any = nil
local wake: any = nil
local beached: any = nil
local beachedRing: Part
-- The new kit's own state lives on K (K.rimeLock, K.rimeWeb, K.rimeShadow,
-- K.rimeShock) and not here: this chunk is close to Luau's 200-local ceiling
-- and took the game down over it once already.

-- ---------------------------------------------------------------- the floe

local rimeParams: RaycastParams? = nil
local rimeFilterAt = 0

-- The sheet's surface at (x, z). NOT surfaceUnder: that casts 8 studs from
-- just above the point it is given, and this has to work when the whale it is
-- drawing for is eighteen studs UNDER the ice. Everything drawn - the client
-- body, this controller's markers, the Vfx parts - is excluded, or the "floe"
-- found would be the whale's own back.
local function sheetY(x: number, z: number, guessY: number): number
	local params = rimeParams
	if not params then
		params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		rimeParams = params
	end
	local now = os.clock()
	if now >= rimeFilterAt then
		rimeFilterAt = now + 1
		local ignore: { Instance } = { folder }
		for _, name in { K.CREATURES_FOLDER, "RimefangBody", "ClientVfx" } do
			local found = Workspace:FindFirstChild(name)
			if found then
				table.insert(ignore, found)
			end
		end
		for _, other in Players:GetPlayers() do
			if other.Character then
				table.insert(ignore, other.Character)
			end
		end
		params.FilterDescendantsInstances = ignore
	end
	local hit = Workspace:Raycast(Vector3.new(x, guessY + 30, z), Vector3.new(0, -70, 0), params)
	return if hit then hit.Position.Y else World.WATER_Y
end

local rimeModel: Model? = nil
local rimeScanAt = 0

-- The boss itself, out of the same `tracked` set every other state effect
-- watches. Re-scanned twice a second rather than per frame: there is at most
-- one of these in the world.
local function rimefang(now: number): Model?
	local model = rimeModel
	if model and model.Parent then
		return model
	end
	rimeModel = nil
	if now < rimeScanAt then
		return nil
	end
	rimeScanAt = now + 0.5
	for candidate in tracked do
		if candidate.Parent and candidate:GetAttribute(K.ATTR_CREATURE_ID) == K.RIME_ID then
			rimeModel = candidate
			return candidate
		end
	end
	return nil
end

-- Is the whale itself standing at `position`? For the moments it fires
-- through a SHARED handler that stamps no skin (the stock `slam` its fluke
-- rides): the boss's own body is then the only thing in the payload's
-- neighbourhood that can confirm whose moment this is. Nil-safe - if the boss
-- is not tracked, the caller falls back to the generic drawing.
local function rimeNear(position: Vector3, range: number): boolean
	local model = rimefang(os.clock())
	return model ~= nil and (model:GetPivot().Position - position).Magnitude <= range
end

-- WHICH MOVE A PAYLOAD IS. `move` is the answer whenever the server sent one
-- - it is the attack's own name, and no amount of radius arithmetic beats
-- being told - and RIME_TELL's radius match is the fallback for a payload
-- from before that field existed. A name is taken AS GIVEN and not checked
-- against this table: a new attack the client has no branch for must fall
-- through to the stock draw, not be silently renamed to whichever old move
-- happens to share its radius.
local function rimeMove(radius: number?, move: any): string?
	if type(move) == "string" and move ~= "" then
		return move
	end
	if not radius then
		return nil
	end
	for name, r in K.RIME_TELL do
		if math.abs(radius - r) <= K.RIME_TELL_TOL then
			return name
		end
	end
	return nil
end

-- Is this Rimefang's moment at all? The identity gate every whale-shaped
-- draw starts with (see RIME_ARENA): the boss has to be tracked in the world
-- AND the payload has to have come from inside its arena.
local function rimeOwns(position: Vector3): boolean
	return rimeNear(position, K.RIME_ARENA)
end

-- WHERE IT IS AND WHICH WAY ITS HIT TESTS POINT, THIS FRAME. The model's
-- pivot IS `creature.pos` (every attack phase pivots through poseCFrame) and
-- FaceAngle IS `yaw0`, so this reproduces the server's own bossFacing()
-- exactly - unlike the bearing latched into a telegraph payload at the START
-- of a windup the boss then spends turning. Returns nils when the boss is not
-- tracked or the pose is not published yet, and the caller falls back to the
-- payload: absence draws something, never nothing.
local function rimeAim(): (Vector3?, number?)
	local model = rimefang(os.clock())
	if not model then
		return nil, nil
	end
	local at = model:GetPivot().Position
	local yaw = tonumber(model:GetAttribute(K.RF_ATTR_FACE))
	if not yaw then
		return at, nil
	end
	-- bossFacing = (cos yaw, 0, -sin yaw), in the (X, Z) bearing convention
	-- the wash's own angle already uses.
	return at, math.atan2(-math.sin(yaw), math.cos(yaw))
end

-- A payload's bearing as an (X, Z) angle, or nil if it carries none.
local function flatAngle(facing: any): number?
	if typeof(facing) ~= "Vector3" then
		return nil
	end
	local flat = Vector3.new(facing.X, 0, facing.Z)
	if flat.Magnitude < 1e-3 then
		return nil
	end
	return math.atan2(flat.Z, flat.X)
end

-- WHERE THE ARENA ACTUALLY IS. The whiteout is weather over the whole floe
-- and it is centred on `creature.anchor`, which updateBoss sets to the point
-- the boss rose at - and for a lair island that is BossArenas.centerFor(islandId)
-- exactly (BossService.arenaPosition). The stock tell is fired from the
-- boss's PIVOT instead, and the two are up to a roam disc apart (28 studs).
-- Sanity-checked rather than trusted: if the shared row and the payload
-- disagree by more than the disc plus margin, the row is not describing this
-- fight and the payload wins.
local function rimeArenaCenter(position: Vector3): Vector3
	local center = BossArenas.centerFor(K.RIME_ISLAND)
	if
		center
		and (Vector3.new(center.X, 0, center.Z) - Vector3.new(position.X, 0, position.Z)).Magnitude
			<= K.RIME_ANCHOR_TRUST
	then
		return Vector3.new(center.X, position.Y, center.Z)
	end
	return position
end

-- ---------------------------------------------------------------- the wedges
--
-- A cone of ground, drawn as the ground it is. `reach` is the distance the
-- attack will actually cover from the boss's CURRENT position, `cone` its
-- half-angle, and the fan below fills that footprint out to a boundary arc:
-- the whole read is "be outside this line, or behind something". The clock is
-- the strobe rate, the idiom the beached window's disc already establishes.
local function stepWedges(now: number)
	for slot = 1, K.WEDGE_SLOTS do
		local w = wedges[slot]
		local pool = wedgePool[slot]
		if w and pool then
			local elapsed = now - w.start
			if elapsed > w.life + K.WEDGE_FADE then
				wedges[slot] = nil
				parkParts(pool.fan)
				parkParts(pool.rim)
			else
				-- The cones READ THE ANIMAL every frame, because the server
				-- keeps turning it and tests the live bearing. The corridor
				-- does the opposite on purpose: `charge` latches `a.dir` on
				-- its first windup frame and never re-aims, so the lane is
				-- fixed from the moment it is drawn - and it must not follow
				-- the whale, which is about to travel down it.
				local at, angle = nil, nil
				if w.live then
					at, angle = rimeAim()
				end
				local center = at or w.center
				angle = angle or w.angle
				-- The bite's footprint closes as the animal lunges through
				-- it: what is left to be bitten, measured from where the boss
				-- is standing right now.
				local reach = w.reach
				if w.kind == "bite" then
					local into = math.clamp(elapsed - w.windup, 0, K.BITE_LEAD)
					reach += K.BITE_LUNGE * (K.BITE_LEAD - into) / K.BITE_STRIKE
				end
				local u = math.clamp(elapsed / math.max(w.windup, 1e-3), 0, 1)
				local fade = math.clamp((elapsed - w.life) / K.WEDGE_FADE, 0, 1)
				local strobe = 0.5 + 0.5 * math.sin(now * (2.4 + 7 * u) * math.pi * 2)
				local fanAlpha = math.min((0.62 - 0.22 * u) + 0.08 * strobe + fade, 1)
				local rimAlpha = math.min((0.34 - 0.2 * u) + 0.08 * strobe + fade, 1)
				local ground = sheetY(center.X, center.Z, center.Y) + 0.1
				local ct, st = math.cos(angle), math.sin(angle)
				local facing = CFrame.Angles(0, -angle, 0)

				if w.kind == "corridor" then
					-- The lane, tiled end to end: `reach` long, `w.width` to
					-- either side of the line, which is exactly what
					-- bodyContact tests against every node that goes down it.
					local step = reach / K.WEDGE_SLABS
					for i = 1, K.WEDGE_SLABS do
						local d = (i - 0.5) * step
						local slab = pool.fan[i]
						slab.Size = Vector3.new(step, 0.12, w.width * 2)
						slab.CFrame = CFrame.new(center.X + ct * d, ground, center.Z + st * d) * facing
						slab.Transparency = fanAlpha
					end
					-- ...and its two rails, because the lane's EDGE is the
					-- whole read: four segments a side, and a bar across the
					-- far end where the animal comes down.
					local railStep = reach / 4
					for i = 1, 8 do
						local side = if i <= 4 then 1 else -1
						local k = if i <= 4 then i else i - 4
						local d = (k - 0.5) * railStep
						local rim = pool.rim[i]
						rim.Size = Vector3.new(railStep * 0.86, 0.18, K.WEDGE_RIM_THICK)
						rim.CFrame = CFrame.new(center.X + ct * d, ground + 0.05, center.Z + st * d)
							* facing
							* CFrame.new(0, 0, side * w.width)
						rim.Transparency = rimAlpha
					end
					local cap = pool.rim[9]
					cap.Size = Vector3.new(K.WEDGE_RIM_THICK, 0.18, w.width * 2)
					cap.CFrame = CFrame.new(
						center.X + ct * (reach - K.WEDGE_RIM_THICK * 0.5),
						ground + 0.05,
						center.Z + st * (reach - K.WEDGE_RIM_THICK * 0.5)
					) * facing
					cap.Transparency = rimAlpha
				else
					local span = (2 * w.cone * reach) / K.WEDGE_SLABS
					for i = 1, K.WEDGE_SLABS do
						local t = (i - 0.5) / K.WEDGE_SLABS * 2 - 1 -- -1..1 across the mouth
						local theta = angle + w.cone * t
						local ctt, stt = math.cos(theta), math.sin(theta)
						local spoke = CFrame.Angles(0, -theta, 0)
						-- Local X is radial and local Z tangential, the same
						-- frame the wash's crest slabs are laid in.
						local slab = pool.fan[i]
						slab.Size = Vector3.new(reach, 0.12, span)
						slab.CFrame = CFrame.new(center.X + ctt * reach * 0.5, ground, center.Z + stt * reach * 0.5)
							* spoke
						slab.Transparency = fanAlpha

						local edge = reach - K.WEDGE_RIM_THICK * 0.5
						local rim = pool.rim[i]
						rim.Size = Vector3.new(K.WEDGE_RIM_THICK, 0.18, span * 1.06)
						rim.CFrame = CFrame.new(center.X + ctt * edge, ground + 0.05, center.Z + stt * edge) * spoke
						rim.Transparency = rimAlpha
					end
				end
			end
		end
	end
end

-- ---------------------------------------------------------------- the wash

-- THE SIGNATURE. Taken out of EVENTS.gust: the shove is the kit engine's and
-- stays exactly as it is (cover already stops it), but the PICTURE cannot be
-- a radial shockwave. An orca shoulders a wall of water over the ice and the
-- seal is washed off; the wall arrives from one bearing, and getting behind
-- something is the answer. Returns true when it has taken the moment, so the
-- generic ring never draws over the top of it.
startWash = function(position: Vector3, extra): boolean
	local radius = tonumber(extra.radius) or 34
	local cone = tonumber(extra.cone)
	-- A wall, not a puff of wind: frost-skinned, aimed, and arena-sized. The
	-- ice island's own frost hostiles have no gust in their book at all, so
	-- this cannot be stolen off a lesser creature.
	if extra.skin ~= "frost" or typeof(extra.facing) ~= "Vector3" or not cone or radius < 20 then
		return false
	end
	local facing = extra.facing :: Vector3
	local flat = Vector3.new(facing.X, 0, facing.Z)
	if flat.Magnitude < 1e-3 then
		return false
	end
	if not nearCamera(position, radius + K.RIME_MARGIN) then
		return true -- its moment, simply not ours to watch
	end
	flat = flat.Unit
	wash = {
		center = position,
		angle = math.atan2(flat.Z, flat.X),
		cone = math.clamp(cone, math.rad(12), math.rad(165)),
		radius = radius,
		duration = math.clamp(tonumber(extra.duration) or 0.9, 0.25, 6),
		start = os.clock(),
		nextSprayAt = 0,
		passed = false,
	}
	return true
end

-- The crest passing the local player: the frame the wall breaks over you.
--
-- THE COVER MECHANIC IS GONE, and so is everything that drew it. The arena
-- has no furniture in it any more - no bergs, no frozen whaler, nothing to
-- put between yourself and a wall of slush - so the notch this used to cut in
-- the crest where a berg stood, the ray that found the berg, and the
-- `sheltered` roster the server sent to say whose cover held all described a
-- floe that no longer exists. The answer to the wash is now SIDESTEPPING: be
-- outside the wedge, which the gathering wedge marker has always drawn at
-- full size for the whole windup. A crest with a hole in it where nothing is
-- standing would teach the old answer to a fight that no longer accepts it.
local function washPass()
	local root = localRoot()
	if not root then
		return
	end
	local at = root.Position
	Vfx.puff(at, K.RIME.slush, 2.4)
	Vfx.burst(at + Vector3.new(0, 1, 0), K.RIME.crest, 22)
	CombatVfxController.kick(math.rad(2.5), 0, 0.28)
end

local function stepWash(now: number)
	if not wash then
		return
	end
	-- THE HIT LANDED WHEN THE EVENT DID. The server damages and shoves the
	-- whole cone in the frame this payload was sent from, so the local
	-- player's answer - "it broke over you" or "your cover held" - is owed on
	-- the FIRST frame, not whenever a slab happens to reach them. This used to
	-- wait for the crest, which at 30 studs was 0.77s of standing there
	-- already hurt with nothing on screen to say why.
	if not wash.passed then
		wash.passed = true
		local root = localRoot()
		local to = if root
			then Vector3.new(root.Position.X - wash.center.X, 0, root.Position.Z - wash.center.Z)
			else Vector3.zero
		-- The server's own test, to the stud: inside `radius`, inside `cone`
		-- of the bearing. A player standing behind the boss is never told a
		-- wall went over them.
		if to.Magnitude > 0.05 and to.Magnitude <= wash.radius then
			local bearing = math.atan2(to.Z, to.X) - wash.angle
			bearing = math.abs((bearing + math.pi) % (math.pi * 2) - math.pi)
			if bearing <= wash.cone then
				washPass()
			end
		end
	end
	local elapsed = now - wash.start
	-- The crest is over once it has crossed; the slush it dumped stays for
	-- the payload's duration, which is what that number is actually for.
	local life = math.max(K.WASH_SWEEP + K.WASH_FADE, wash.duration)
	if elapsed > life + K.WASH_FADE then
		wash = nil
		parkParts(washPool.crest)
		parkParts(washPool.apron)
		return
	end
	local u = math.clamp(elapsed / K.WASH_SWEEP, 0, 1)
	local fade = math.clamp((elapsed - K.WASH_SWEEP) / K.WASH_FADE, 0, 1)
	local slushFade = math.clamp((elapsed - wash.duration) / K.WASH_FADE, 0, 1)
	local r = K.WASH_INNER + (wash.radius - K.WASH_INNER) * u
	local cos, sin = math.cos(wash.angle), math.sin(wash.angle)
	-- One sample, on the crest's centre line: a floe is flat, and sixteen
	-- rays a frame to prove it would be sixteen rays a frame wasted.
	local ground = sheetY(wash.center.X + cos * r, wash.center.Z + sin * r, wash.center.Y)
	local pulse = 0.5 + 0.5 * math.sin(now * 14)
	local alpha = math.min((0.2 + 0.1 * pulse) + 0.8 * fade, 1)
	local slush = math.min((0.52 + 0.08 * pulse) + 0.48 * slushFade, 1)
	local span = (2 * wash.cone * r) / K.WASH_SLABS
	-- The slush covers the ground the wall has ALREADY been over - which, the
	-- moment the crest is out at `radius`, is the whole damaged footprint. It
	-- used to be a lagging band 5.5 studs deep, so the wedge the server hit
	-- was left unmarked behind the crest as well as in front of it.
	local back = 0.5 * (K.WASH_INNER + math.max(r - K.WASH_APRON_LAG * (1 - u), K.WASH_INNER + 0.5))
	local depth = math.max(r - K.WASH_APRON_LAG * (1 - u) - K.WASH_INNER, 1)

	for i = 1, K.WASH_SLABS do
		local t = (i - 0.5) / K.WASH_SLABS * 2 - 1 -- -1..1 across the wedge
		local theta = wash.angle + wash.cone * t
		local ct, st = math.cos(theta), math.sin(theta)
		-- Tallest on the bearing it was aimed down and lower at the shoulders,
		-- so a wall crossing 140 degrees of arena still reads as ONE thing
		-- coming from somewhere rather than as weather.
		local height = K.WASH_HEIGHT * (1 - 0.28 * u) * (0.62 + 0.38 * math.cos(t * math.pi * 0.5))
		-- UNBROKEN, all the way across. Nothing on this floe breaks a wall any
		-- more (see washPass), so every slab is the same wall and the only
		-- gap in it is the one at the edge of the wedge, where the arc ends.
		local slab = washPool.crest[i]
		slab.Size = Vector3.new(K.WASH_THICK, height, span * 1.12)
		slab.CFrame = CFrame.new(wash.center.X + ct * r, ground + height * 0.5, wash.center.Z + st * r)
			* CFrame.Angles(0, -theta, 0)
		slab.Transparency = alpha

		-- ...and the slush it has dumped on the ice behind the crest: the wall
		-- passing is a moment, the mess it leaves is how you know which way it
		-- went after it has gone - and how you know how much of the floe it
		-- just had.
		local apron = washPool.apron[i]
		apron.Size = Vector3.new(depth, 0.35, (2 * wash.cone * back) / K.WASH_SLABS * 1.3)
		apron.CFrame = CFrame.new(wash.center.X + ct * back, ground + 0.18, wash.center.Z + st * back)
			* CFrame.Angles(0, -theta, 0)
		apron.Transparency = slush
	end

	if fade <= 0 and now >= wash.nextSprayAt then
		wash.nextSprayAt = now + K.WASH_SPRAY_GAP
		for _ = 1, 2 do
			local theta = wash.angle + wash.cone * (math.random() * 2 - 1)
			local at = Vector3.new(
				wash.center.X + math.cos(theta) * r,
				ground + randomBetween(1.5, K.WASH_HEIGHT),
				wash.center.Z + math.sin(theta) * r
			)
			Vfx.puff(at, K.RIME.crest, 1.5)
		end
	end
end

-- ------------------------------------------------------------- broken sheet

-- Cracks thrown out from something enormous landing on the ice. They GROW
-- (the split running outward is the whole read) and then stay, because the
-- sheet does not heal inside the punish window they open.
local function drawFloeCracks(position: Vector3, radius: number)
	local y = sheetY(position.X, position.Z, position.Y) + 0.09
	for i = 1, K.CRACK_SLABS do
		local slab = crackPool[i]
		local theta = (i / K.CRACK_SLABS) * math.pi * 2 + randomBetween(-0.14, 0.14)
		local length = radius * randomBetween(0.65, 1.35)
		local width = randomBetween(0.35, 0.9)
		local ct, st = math.cos(theta), math.sin(theta)
		local facing = CFrame.Angles(0, -theta, 0)
		slab.Size = Vector3.new(2, 0.16, width)
		slab.CFrame = CFrame.new(position.X + ct * 1, y, position.Z + st * 1) * facing
		slab.Transparency = 0.08
		TweenService:Create(slab, TweenInfo.new(0.24, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
			Size = Vector3.new(length, 0.16, width),
			CFrame = CFrame.new(position.X + ct * length * 0.5, y, position.Z + st * length * 0.5) * facing,
		}):Play()
		TweenService:Create(
			slab,
			TweenInfo.new(K.CRACK_FADE, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, K.CRACK_HOLD),
			{ Transparency = 1 }
		):Play()
	end
end

-- ------------------------------------------------------------ the impacts

-- ICE AND SLUSH OFF THE POINT, thrown as a fountain rather than a puff. Both
-- of the new hits break the sheet from the inside - one coming up through it,
-- one coming down onto it - and what a broken floe throws is BLOCKS, so the
-- shards go up in a staggered column and out on a ring rather than blooming
-- once. Vfx's own pooled particle machinery, on an event clock: nothing here
-- runs per frame and nothing here creates a part.
K.rimeShards = function(at: Vector3, radius: number, up: number, weight: number)
	for i = 0, 3 do
		task.delay(i * 0.06, function()
			Vfx.burst(at + Vector3.new(0, 1 + i * up, 0), K.RIME.crack, math.floor(30 * weight))
			Vfx.puff(at + Vector3.new(0, 0.6 + i * up * 0.8, 0), K.RIME.slush, 2.6 * weight - i * 0.3)
		end)
	end
	-- ...and the slabs of it that come down again, out on the rim.
	for i = 1, 6 do
		local a = (i / 6) * math.pi * 2 + randomBetween(-0.3, 0.3)
		local d = radius * randomBetween(0.4, 0.85)
		task.delay(randomBetween(0.05, 0.3), function()
			Vfx.burst(at + Vector3.new(math.cos(a) * d, 1.4, math.sin(a) * d), K.RIME.crack, 10)
			Vfx.splash(at + Vector3.new(math.cos(a) * d, 0.2, math.sin(a) * d), 2)
		end)
	end
end

-- THE ERUPTION. It has spent 2.2 seconds under the sheet and it comes up
-- THROUGH it, vertically, at the point that locked 0.6s ago: so the sheet
-- goes first (a ring cracked clean into the ice at exactly the damage radius,
-- which is the footprint the player was asked to leave), then the column.
K.rimeErupt = function(at: Vector3, radius: number)
	Sfx.play("rimeFloeCrack", at)
	task.delay(0.04, function()
		Sfx.play("rimeIceBurst", at)
	end)
	-- The RING is the damage radius to the stud, and it stays: the hole a
	-- whale came out of does not close inside a punish window.
	drawFloeCracks(at, radius)
	Vfx.ring(at + Vector3.new(0, 0.2, 0), radius * 0.3, radius, 0.35, K.SKIN.frost)
	Vfx.flash(at + Vector3.new(0, 6, 0), K.RIME.crack, 9, 0.22)
	Vfx.shockwave(at + Vector3.new(0, 0.4, 0), 2, radius, 0.4, K.RIME.crest, 0.6)
	Vfx.splash(at, 5)
	-- UP, not out. This is the one hit in the fight whose direction is
	-- vertical, and the column has to say so before the body is on screen.
	K.rimeShards(at, radius, 4.5, 1.4)
	feelBlast(at, radius + 10, K.SHAKE_RISE, 0.45, Color3.fromRGB(214, 240, 255))
end

-- THE SLAM. Seventy studs up, pitched over, and the whole animal arrives flat
-- on the point the shadow has been converging on for two seconds. The
-- heaviest single moment in the fight, and the shockwave it throws is a
-- SEPARATE event on its own clock (EVENTS.rimeShock) because it is a second
-- hit with a second answer.
-- THE SHATTER'S IMPACT: the biggest crash in the fight, and it has to be, or
-- the moment the arena changes is quieter than the skyfall that preceded it.
-- Everything the other two do, weighted up and layered - the crack, the boom,
-- the roar over the top of both - plus a second shockwave chasing the first
-- out, which is the sheet failing after the blow rather than under it.
--
-- The ARENA-wide half of this beat is not here: the splits to the rim and the
-- four holes arrive on their own event (EVENTS.rimeShatter), on their own
-- clock, from the arena centre. This is only what happens where it landed.
K.rimeShatterCrash = function(at: Vector3, radius: number)
	-- THE FLOOR FAILING, and it is now ONE cue with one thing under it. This
	-- beat used to be four stand-ins stacked (crack, impact, burst, roar)
	-- because there was no sound for "the arena breaks" - and four impact cues
	-- inside a sixth of a second is a louder HIT, which is the opposite read.
	-- `rimeShatter` is that sound, at 320 studs of range because the whole
	-- floe is what broke; `rimeSkyImpact` stays under it as the body weight
	-- landing, so the picture is a floor giving way UNDER something.
	--
	-- The roar is gone from here on purpose - not lost, moved. It belongs to
	-- the animal, and the animal now has two places to make it: `rimeEnrage`
	-- on the half-health crossing and the windup's own `rimeThrash` as it
	-- rears. A third at the impact would only be the same voice three times in
	-- two seconds.
	Sfx.play("rimeShatter", at)
	task.delay(0.04, function()
		Sfx.play("rimeSkyImpact", at)
	end)
	drawFloeCracks(at, radius)
	Vfx.flash(at + Vector3.new(0, 3, 0), K.RIME.crack, 14, 0.3)
	Vfx.shockwave(at + Vector3.new(0, 0.4, 0), 2, radius, 0.4, K.RIME.crest, 0.9)
	Vfx.ring(at, 2, radius * 1.5, 1.0, K.RIME.slush)
	-- ...and the second front, late and wide: the sheet letting go behind the
	-- blow. Deliberately NOT the skyfall's `rimeShock` - that one is a damaging
	-- ring the server fires and the player outruns, and this is aftermath.
	task.delay(0.18, function()
		if nearCamera(at, radius + K.RIME_MARGIN) then
			Vfx.shockwave(at + Vector3.new(0, 0.3, 0), radius * 0.5, radius * 2.2, 0.75, K.RIME.slush, 0.55)
		end
	end)
	K.rimeShards(at, radius, 5.4, 2.4)
	for i = 1, 10 do
		local a = (i / 10) * math.pi * 2
		Vfx.splash(at + Vector3.new(math.cos(a) * radius * 0.55, 0.2, math.sin(a) * radius * 0.55), 2.6)
	end
	feelBlast(at, radius, K.RIME_SHAKE, 0.85, Color3.fromRGB(226, 244, 255))
end

K.rimeCrash = function(at: Vector3, radius: number)
	Sfx.play("rimeFloeCrack", at)
	task.delay(0.05, function()
		Sfx.play("rimeSkyImpact", at)
	end)
	drawFloeCracks(at, radius * 1.6)
	Vfx.flash(at + Vector3.new(0, 2, 0), K.RIME.crack, 11, 0.24)
	Vfx.shockwave(at + Vector3.new(0, 0.4, 0), 2, radius, 0.45, K.RIME.crest, 0.8)
	Vfx.ring(at, 2, radius * 1.3, 0.8, K.RIME.slush)
	K.rimeShards(at, radius, 2.6, 1.8)
	feelBlast(at, radius, K.SHAKE_SLAM, 0.55, Color3.fromRGB(220, 242, 255))
end

-- Something whale-sized landing on the sheet. Three of them now: the
-- eruption coming UP through it (r14), the skyfall coming DOWN onto it (r18),
-- and the fluke through a hole (r24). All three break the ice, which is why
-- they share a drawing; weight, direction and sound tell them apart.
rimeSlam = function(position: Vector3, extra): boolean
	local radius = tonumber(extra.radius) or 15
	local move = rimeMove(radius, extra.move)
	if move ~= "icebreach" and move ~= "skyfall" and move ~= "flukeslam" and move ~= "shatter" then
		return false
	end
	-- The stock `slam` stamps no skin, so a payload that carries neither
	-- `skin` nor a name is confirmed against the animal standing there.
	if extra.skin ~= "frost" and not rimeNear(position, 40) then
		return false
	end
	if not nearCamera(position, radius + K.RIME_MARGIN) then
		return true
	end
	local at = Vector3.new(position.X, sheetY(position.X, position.Z, position.Y) + 0.15, position.Z)
	-- The lock is spent the moment its hit lands: the ring must not still be
	-- closing on ground that has already been hit.
	K.rimeLock = nil

	if move == "icebreach" then
		K.rimeErupt(at, radius)
		return true
	elseif move == "skyfall" then
		K.rimeCrash(at, radius)
		return true
	elseif move == "shatter" then
		K.rimeShatterCrash(at, radius)
		return true
	end

	-- THE FLUKE, unchanged: a limb rather than the whole animal. CRACK then
	-- BOOM, the way killCrack sits ahead of killThump.
	Sfx.play("rimeFloeCrack", at)
	task.delay(0.05, function()
		Sfx.play("rimeFlukeSlam", at)
	end)
	drawFloeCracks(at, radius)
	Vfx.flash(at + Vector3.new(0, 2, 0), K.RIME.crack, 6, 0.22)
	Vfx.shockwave(at + Vector3.new(0, 0.4, 0), 2, radius, 0.5, K.RIME.crest, 0.7)
	Vfx.ring(at, 2, radius * 1.3, 0.8, K.RIME.slush)
	Vfx.puff(at, K.RIME.slush, 3.4)
	Vfx.burst(at, K.RIME.crest, 40)
	for i = 1, 6 do
		local a = (i / 6) * math.pi * 2
		Vfx.splash(at + Vector3.new(math.cos(a) * radius * 0.5, 0.2, math.sin(a) * radius * 0.5), 2)
	end
	feelBlast(at, radius, K.SHAKE_PULSE, 0.5, Color3.fromRGB(220, 242, 255))
	return true
end

-- ------------------------------------------------------- the punish window

local function closeBeached()
	if not beached then
		return
	end
	local at = beached.at
	beachedRing.Transparency = 1
	beachedRing.CFrame = K.PARKED
	beached = nil
	-- It works itself over the edge and is gone.
	Sfx.play("rimeThrash", at)
	Vfx.splash(at, 3)
	Vfx.puff(at, K.RIME.slush, 4)
end

-- FOUR SECONDS. It is on the ice, it cannot answer, and it is the only
-- window in the fight wide enough to kill it in - so the ground under the
-- animal carries the clock in the same gold the serpent's stagger uses, and
-- the detail (slush off its flanks, the thrash) lives at the body, where the
-- audio pass put it too: the window should pay for walking to it.
local function stepBeached(now: number)
	local model = rimefang(now)
	-- Gated on the window's own DEADLINE, never on ATTR_EXPOSED: that
	-- attribute has no expiry for a plain boss archetype, so it latches true
	-- after the first breach. This cue used to strobe for the rest of the
	-- fight and no later breach could reopen it.
	local openUntil = model and tonumber(model:GetAttribute("OpenUntil")) or 0
	if not model or openUntil <= Workspace:GetServerTimeNow() then
		closeBeached()
		return
	end
	local at = model:GetPivot().Position
	if not nearCamera(at, K.RIME_CULL) then
		return
	end
	if not beached then
		beached = {
			at = at,
			until_ = now + K.BEACHED_WINDOW,
			duration = K.BEACHED_WINDOW,
			nextThrashAt = now,
			nextPuffAt = 0,
		}
		Vfx.flash(at + Vector3.new(0, 4, 0), K.BRINE.window, 8, 0.5)
		Vfx.burst(at + Vector3.new(0, 2, 0), K.BRINE.window, 45)
	end
	beached.at = at

	-- The disc IS the clock: it closes as the window does and strobes faster
	-- the less of it there is left. Readable from anywhere on the floe with
	-- no HUD and no text.
	local left = math.max(beached.until_ - now, 0)
	local u = math.clamp(left / beached.duration, 0, 1)
	local r = K.BEACHED_RADIUS * (0.2 + 0.8 * u)
	beachedRing.Size = Vector3.new(0.16, r * 2, r * 2)
	beachedRing.CFrame = CFrame.new(at.X, sheetY(at.X, at.Z, at.Y) + 0.16, at.Z) * CFrame.Angles(0, 0, math.rad(90))
	local rate = 2.2 + 6 * (1 - u)
	beachedRing.Transparency = 0.5 + 0.28 * (0.5 + 0.5 * math.sin(now * rate * math.pi * 2))

	if now >= beached.nextThrashAt then
		beached.nextThrashAt = now + K.BEACHED_THRASH_GAP
		Sfx.play("rimeThrash", at)
		Vfx.burst(at + Vector3.new(0, 1.5, 0), K.BRINE.window, 16)
	end
	if now >= beached.nextPuffAt then
		beached.nextPuffAt = now + 0.28
		-- Slush thrown off it as it works itself back toward the water.
		local jitter = Vector3.new(randomBetween(-7, 7), randomBetween(0, 3), randomBetween(-7, 7))
		Vfx.puff(at + jitter, K.RIME.slush, 1.6)
	end
end

-- ---------------------------------------------------------------- the wake

-- ITS IDENTITY. Under the sheet it is never visible and never lost: a knuckle
-- of raised ice over the head, two arms splaying back off it, and a cold
-- light travelling under the floe. Everything reads off `Submerge` (0..1) and
-- the model's own position, so the moment the server stops publishing the
-- pose this simply stops drawing.
-- THE SPOUT. It comes up somewhere on the ring and breathes out: this fight's
-- locator, and most players will hear it before they turn - so the sound goes
-- out whether or not the breath is on screen.
local function spoutAt(head: Vector3)
	Sfx.play("rimeSpout", head)
	if not nearCamera(head, K.RIME_CULL) then
		return
	end
	local y = sheetY(head.X, head.Z, head.Y)
	Vfx.splash(Vector3.new(head.X, y + 0.2, head.Z), 2.5)
	for i = 0, 3 do
		task.delay(i * 0.05, function()
			Vfx.puff(Vector3.new(head.X, y + 1.5 + i * 2.6, head.Z), K.RIME.crest, 1.6 - i * 0.2)
		end)
	end
end

local function stepWake(now: number)
	local model = rimefang(now)
	local depth = if model then tonumber(model:GetAttribute(K.ATTR_SUBMERGE)) else nil
	-- Checked BEFORE the wake is parked, and off the raw attribute: a server
	-- that snaps Submerge straight to 0 would otherwise surface the animal in
	-- silence, and the breath is the one cue that says "it is up, and there".
	if model and wake and depth and depth <= K.WAKE_SPOUT_AT and not wake.spouted then
		wake.spouted = true
		spoutAt(model:GetPivot().Position)
	end
	if not model or not depth or depth <= 0.05 or not nearCamera(model:GetPivot().Position, K.RIME_CULL) then
		if wake then
			wake = nil
			parkParts(wakePool.arms)
			wakePool.knuckle.Transparency = 1
			wakePool.knuckle.CFrame = K.PARKED
			wakePool.glow.Transparency = 1
			wakePool.glow.CFrame = K.PARKED
			wakePool.light.Enabled = false
		end
		return
	end
	depth = math.clamp(depth, 0, 1)

	local head = model:GetPivot().Position
	if not wake then
		wake = { dir = Vector3.zAxis, lastPos = head, nextSprayAt = 0, spouted = false }
	end
	local moved = Vector3.new(head.X - wake.lastPos.X, 0, head.Z - wake.lastPos.Z)
	wake.lastPos = head
	if moved.Magnitude > 0.04 then
		-- Eased, not snapped: a wake is water and water does not turn on a
		-- frame, and a jittering V would read as a bug rather than an animal.
		local blended = wake.dir + (moved.Unit - wake.dir) * 0.2
		if blended.Magnitude > 1e-3 then
			wake.dir = blended.Unit
		end
	end

	local y = sheetY(head.X, head.Z, head.Y)
	local frame = CFrame.lookAt(Vector3.new(head.X, y + 0.14, head.Z), Vector3.new(head.X, y + 0.14, head.Z) + wake.dir)
	local swell = 0.5 + 0.5 * math.sin(now * 3.1)
	-- Deeper is fainter and wider: how hard the wake is to see IS the depth.
	local faint = 0.18 + 0.5 * depth

	local knuckle = wakePool.knuckle
	knuckle.Size = Vector3.new(3.4, 0.5 + 0.25 * swell, 5.2 + 1.2 * (1 - depth))
	knuckle.CFrame = frame
	knuckle.Transparency = math.clamp(faint, 0, 0.95)

	for side = 0, 1 do
		local sign = if side == 0 then 1 else -1
		for k = 1, K.WAKE_ARMS do
			local slab = wakePool.arms[side * K.WAKE_ARMS + k]
			slab.Size = Vector3.new(0.5 + 0.09 * k, 0.3, K.WAKE_STEP * 1.08)
			slab.CFrame = frame * CFrame.Angles(0, sign * K.WAKE_SPLAY, 0) * CFrame.new(0, 0, k * K.WAKE_STEP)
			slab.Transparency = math.clamp(faint + 0.05 * k, 0, 1)
		end
	end

	-- The cold light beneath the ice. Wide, weak and never sharp: you are
	-- meant to be sure where it is and never sure what you are looking at.
	local glowR = 7 + 11 * depth
	local glow = wakePool.glow
	glow.Size = Vector3.new(0.12, glowR * 2, glowR * 2)
	glow.CFrame = CFrame.new(head.X, y + 0.05, head.Z) * CFrame.Angles(0, 0, math.rad(90))
	glow.Transparency = math.clamp(0.82 + 0.06 * swell, 0, 1)
	wakePool.light.Enabled = true
	wakePool.light.Brightness = 1.4 + 1.6 * (1 - depth)
	wakePool.light.Range = glowR * 2

	if now >= wake.nextSprayAt and moved.Magnitude > 0.04 then
		wake.nextSprayAt = now + K.WAKE_SPRAY_GAP
		Vfx.puff(Vector3.new(head.X, y + 0.3, head.Z), K.RIME.wake, 1.0 * (1 - depth * 0.5))
		Vfx.ring(Vector3.new(head.X, y + 0.16, head.Z), 1.5, 6, 0.5, K.RIME.wake)
	end

	-- Back down under the sheet: the next time it comes up, it breathes again.
	if depth > 0.6 then
		wake.spouted = false
	end
end

-- --------------------------------------------------------- the new kit
--
-- FOUR DRAWS, ALL OF THEM POOLED AND ALL OF THEM ON K. This chunk sits close
-- to Luau's 200-local ceiling (which took the game down on 2026-09-06), so
-- every piece of state and every step function below is a field on K rather
-- than a chunk-scope local. They cost nothing extra at runtime and they
-- cannot push the register count over.
--
-- The crack web and the shadow are CONTINUOUS: they read model attributes
-- every frame and draw a state, not an event. The lock and the shockwave are
-- started by an event and then run themselves. All four disappear silently if
-- the boss model, the mesh pack or the attributes are missing.
K.rimeWeb = nil :: any
K.rimeLock = nil :: any
K.rimeShadow = nil :: any
K.rimeShock = nil :: any
K.lockShown = false -- is the lock's disc currently on the floe? See stepRimeLock.
-- Phase two. `rimeShatter` is the splits fading out over four seconds and dies
-- on its own clock; `rimeRift` is the four holes and has NO clock - it lives
-- until the animal does not (see K.stepRimeShatter). `rimeHot` is which colour
-- the telegraph rims are currently painted, so the repaint happens on the
-- crossing rather than every frame.
K.rimeShatter = nil :: any
K.rimeRift = nil :: any
K.rimeHot = false
K.riftWarned = false -- said once: a payload site that disagrees with the mesh

-- What the animal is doing and where its body actually is, this frame.
-- PoseCenter matters because for most of two of these moves the model pivot
-- is NOT where the spectacle is - under eighteen studs of ice, or seventy
-- studs above it - and every read falls back rather than failing.
K.rimeReadPose = function(model: Model?): (string, Vector3)
	if not model then
		return "", Vector3.zero
	end
	local move = model:GetAttribute(K.RIME_ATTR_MOVE)
	local pose = model:GetAttribute(K.RIME_ATTR_POSE)
	return (if type(move) == "string" then move else ""),
		(if typeof(pose) == "Vector3" then pose else model:GetPivot().Position)
end

-- THE CRACK WEB. The tell BEFORE the tell: while it is under the sheet on its
-- way to whoever it picked, the ice over its back splits, and the splits
-- travel with it. This is the whole reason the eruption is not a cheap shot -
-- a player who has learned this fight starts moving when the web appears,
-- half a second before any ring exists to tell them where.
--
-- IT LEANS THE WAY THE ANIMAL IS GOING. The arms ahead of the travel bearing
-- run up to 60% longer than the ones behind, which is what turns a spreading
-- blot into an ARROW - and the arrow is the part that says "toward you".
K.stepRimeWeb = function(now: number, move: string, pose: Vector3, submerge: number?, burst: number)
	local live = move == "icebreach" and submerge ~= nil and submerge >= K.WEB_SUBMERGED
	if live and not nearCamera(pose, K.RIME_CULL) then
		live = false -- its moment, simply not ours to watch
	end
	if not live then
		if K.rimeWeb then
			K.rimeWeb = nil
			parkParts(K.webPool)
		end
		return
	end
	local web = K.rimeWeb
	if not web then
		-- The arms are drawn ONCE, at the shape the web will keep: a web that
		-- re-randomised every frame would be a shimmer, not a crack.
		web = { arms = {}, start = now, dir = Vector3.zAxis, lastPos = pose, nextGroanAt = 0 }
		for i = 1, K.WEB_ARMS do
			web.arms[i] = {
				angle = (i / K.WEB_ARMS) * math.pi * 2 + randomBetween(-0.16, 0.16),
				reach = K.WEB_REACH * randomBetween(0.45, 1),
				width = randomBetween(0.3, 0.85),
			}
		end
		K.rimeWeb = web
	end

	-- Which way it is travelling, eased the way the wake's bearing is: ice
	-- splits do not swing round on a frame either.
	local moved = Vector3.new(pose.X - web.lastPos.X, 0, pose.Z - web.lastPos.Z)
	web.lastPos = pose
	if moved.Magnitude > 0.04 then
		local blended = web.dir + (moved.Unit - web.dir) * 0.18
		if blended.Magnitude > 1e-3 then
			web.dir = blended.Unit
		end
	end

	local grow = math.clamp((now - web.start) / K.WEB_SPROUT, 0.25, 1)
	local y = sheetY(pose.X, pose.Z, pose.Y)
	-- The sheet DOMES before it goes: `Burst` lifts the whole web off the
	-- flat and thins it, which is the last half-second of warning there is.
	local lift = 0.1 + 1.3 * burst
	local alpha = math.clamp(0.1 + 0.35 * burst, 0, 0.9)
	for i = 1, K.WEB_ARMS do
		local arm = web.arms[i]
		local ct, st = math.cos(arm.angle), math.sin(arm.angle)
		-- Ahead of the bearing is longer. dot() of the arm against the travel
		-- direction, clamped to the forward half.
		local lean = math.max(ct * web.dir.X + st * web.dir.Z, 0)
		local length = arm.reach * grow * (1 + 0.6 * lean)
		local slab = K.webPool[i]
		slab.Size = Vector3.new(length, 0.16, arm.width)
		slab.CFrame = CFrame.new(pose.X + ct * length * 0.5, y + lift, pose.Z + st * length * 0.5)
			* CFrame.Angles(0, -arm.angle, 0)
		slab.Transparency = alpha
	end

	if now >= web.nextGroanAt then
		web.nextGroanAt = now + K.WEB_GAP
		Sfx.play("rimeCrackWeb", Vector3.new(pose.X, y, pose.Z))
		Vfx.puff(Vector3.new(pose.X, y + 0.4, pose.Z), K.RIME.slush, 1.4 + burst * 2)
	end
end

-- THE DESCENDING SHADOW. There is no honest way to draw a whale seventy studs
-- overhead onto the ground except as the dark it is about to put you in - and
-- a shadow is the one marker in the game that a player already knows how to
-- read without being taught. It CONVERGES: wide and weak at the apex, and by
-- the time it lands it is exactly the impact footprint, on the locked mark.
K.stepRimeShadow = function(move: string, pose: Vector3, sky: number?)
	local live = move == "skyfall" and sky ~= nil and sky > 0.02
	if live and not nearCamera(pose, K.RIME_CULL) then
		live = false
	end
	if not live then
		if K.rimeShadow then
			K.rimeShadow = nil
			K.shadowDisc.Transparency = 1
			K.shadowDisc.CFrame = K.PARKED
		end
		return
	end
	if not K.rimeShadow then
		K.rimeShadow = true
		-- The launch: the sea letting go of something ship-sized. Fired here
		-- rather than off an event because the attribute IS the launch - the
		-- frame Skyfall leaves zero is the frame it left the ice.
		Sfx.play("rimeSkyLaunch", pose)
	end
	local height = math.clamp(sky :: number, 0, 1)
	-- Converging on the footprint the lock ring is already drawing, if there
	-- is one - so the two markers agree to the stud instead of nearly.
	local floor = if K.rimeLock then K.rimeLock.radius else K.SKYFALL_RADIUS
	local r = floor + (K.SHADOW_HIGH - floor) * height
	local y = sheetY(pose.X, pose.Z, pose.Y)
	local disc = K.shadowDisc
	disc.Size = Vector3.new(0.14, r * 2, r * 2)
	disc.CFrame = CFrame.new(pose.X, y + 0.12, pose.Z) * CFrame.Angles(0, 0, math.rad(90))
	-- DARKER ON THE WAY DOWN, which is the opposite of what a real shadow
	-- does and the right way round for a warning: the read is "it is nearly
	-- here", never "it is a long way off".
	disc.Transparency = math.clamp(0.34 + 0.52 * height, 0, 1)
end

-- THE LOCK. Both new moves pick a point and commit to it, and this is that
-- point: a disc at the REAL damage radius, held at full size for the whole
-- window (a footprint that grows into honesty is dishonest until it gets
-- there), with a ring closing onto it as the clock runs out. The disc says
-- WHERE and the ring says WHEN, and neither is a job the other can do.
K.startRimeLock = function(at: Vector3, radius: number, life: number, move: string)
	K.rimeLock = {
		at = Vector3.new(at.X, sheetY(at.X, at.Z, at.Y), at.Z),
		radius = radius,
		life = life,
		start = os.clock(),
		move = move,
	}
	Sfx.play("rimeCrackLock", at)
end

K.stepRimeLock = function(now: number)
	local lock = K.rimeLock
	-- PARKED FROM THE SHOWN FLAG, NOT FROM THE CLOCK. The lock is also
	-- cleared from OUTSIDE this step - rimeSlam drops it the instant the hit
	-- it was warning about lands, because a ring still closing on ground that
	-- has already been hit is a lie - and an early-out on `not lock` alone
	-- left the disc and its ring lit on the floe for the rest of the fight.
	if not lock then
		if K.lockShown then
			K.lockShown = false
			K.lockDisc.Transparency = 1
			K.lockDisc.CFrame = K.PARKED
			parkParts(K.lockArc)
		end
		return
	end
	K.lockShown = true
	local elapsed = now - lock.start
	if elapsed > lock.life + K.LOCK_FADE or not nearCamera(lock.at, K.RIME_CULL) then
		K.rimeLock = nil
		return
	end
	local u = math.clamp(elapsed / math.max(lock.life, 1e-3), 0, 1)
	local fade = math.clamp((elapsed - lock.life) / K.LOCK_FADE, 0, 1)
	local strobe = 0.5 + 0.5 * math.sin(now * (2.6 + 8 * u) * math.pi * 2)
	local y = lock.at.Y + 0.14

	local disc = K.lockDisc
	disc.Size = Vector3.new(0.14, lock.radius * 2, lock.radius * 2)
	disc.CFrame = CFrame.new(lock.at.X, y, lock.at.Z) * CFrame.Angles(0, 0, math.rad(90))
	disc.Transparency = math.min(0.56 - 0.14 * u + 0.08 * strobe + fade, 1)

	-- The ring, closing. It starts wide enough to be outside a player's own
	-- feet and arrives exactly on the disc's rim at the moment of the hit.
	local rr = lock.radius * (K.LOCK_OPEN - (K.LOCK_OPEN - 1) * u)
	local span = (2 * math.pi * rr) / K.LOCK_ARC * 1.08
	for i = 1, K.LOCK_ARC do
		local theta = (i / K.LOCK_ARC) * math.pi * 2
		local ct, st = math.cos(theta), math.sin(theta)
		local slab = K.lockArc[i]
		slab.Size = Vector3.new(K.WEDGE_RIM_THICK, 0.2, span)
		slab.CFrame = CFrame.new(lock.at.X + ct * rr, y + 0.05, lock.at.Z + st * rr) * CFrame.Angles(0, -theta, 0)
		slab.Transparency = math.min(0.22 + 0.1 * strobe + fade, 1)
	end
end

-- THE SHOCKWAVE. The second half of the skyfall: a ring of split sheet
-- running out to forty studs in seven-tenths of a second, light damage, and
-- the answer is your legs. Drawn as a LINE rather than a filled disc for
-- exactly that reason - what a player has to judge is which side of the front
-- they are on and whether they can stay ahead of it.
K.startRimeShock = function(position: Vector3, extra)
	local radius = tonumber(extra.radius) or K.SHOCK_RADIUS
	local duration = math.clamp(tonumber(extra.duration) or K.SHOCK_TIME, 0.15, 4)
	local at = Vector3.new(position.X, sheetY(position.X, position.Z, position.Y) + 0.18, position.Z)
	K.rimeShock = { at = at, radius = radius, duration = duration, start = os.clock(), passed = false }
	Sfx.play("rimeShock", at)
	if nearCamera(at, radius + K.RIME_MARGIN) then
		Vfx.shockwave(at + Vector3.new(0, 0.4, 0), 3, radius, duration, K.RIME.crest, 0.6)
	end
end

K.stepRimeShock = function(now: number)
	local shock = K.rimeShock
	if not shock then
		return
	end
	local elapsed = now - shock.start
	if elapsed > shock.duration + K.LOCK_FADE or not nearCamera(shock.at, shock.radius + K.RIME_MARGIN) then
		K.rimeShock = nil
		parkParts(K.shockArc)
		return
	end
	local u = math.clamp(elapsed / shock.duration, 0, 1)
	local fade = math.clamp((elapsed - shock.duration) / K.LOCK_FADE, 0, 1)
	local r = math.max(3 + (shock.radius - 3) * u, 1)
	local span = (2 * math.pi * r) / K.SHOCK_ARC * 1.1
	for i = 1, K.SHOCK_ARC do
		local theta = (i / K.SHOCK_ARC) * math.pi * 2
		local ct, st = math.cos(theta), math.sin(theta)
		local slab = K.shockArc[i]
		slab.Size = Vector3.new(K.SHOCK_THICK, 0.7 * (1 - u * 0.5), span)
		slab.CFrame = CFrame.new(shock.at.X + ct * r, shock.at.Y + 0.3, shock.at.Z + st * r)
			* CFrame.Angles(0, -theta, 0)
		slab.Transparency = math.min(0.2 + 0.45 * u + fade, 1)
	end

	-- The frame the front goes past you. The server's damage is its own, but
	-- the ring must not cross a player in silence - a light hit with nothing
	-- on screen at the moment it lands is the complaint this whole kit exists
	-- to answer.
	if not shock.passed then
		local root = localRoot()
		if root then
			local here = root.Position
			local d = Vector3.new(here.X - shock.at.X, 0, here.Z - shock.at.Z).Magnitude
			if r >= d then
				shock.passed = true
				Vfx.puff(here, K.RIME.slush, 2)
				Vfx.burst(here + Vector3.new(0, 1, 0), K.RIME.crest, 14)
				CombatVfxController.kick(math.rad(1.8), 0, 0.24)
			end
		end
	end
end

-- --------------------------------------------------------- phase two: SHATTER

-- WHERE THE FOUR HOLES ARE. The payload's `sites` are the server's answer and
-- they win, but they are CHECKED against the arena row the mesh was measured
-- into (BossArenas.items.ice.thinIce) before they are believed - the holes are
-- the only thing this file draws that stays on screen for the rest of the
-- fight, and a hole drawn on solid ice is a lie the player cannot walk off.
--
-- Two shapes are accepted, because a server may reasonably send either: WORLD
-- points, and points RELATIVE to the arena centre (which is the shape the
-- config itself is written in). They are told apart by geometry rather than by
-- a flag - a point that is nowhere near the arena but IS near the origin can
-- only be an offset - so neither side has to know what the other chose.
--
-- Absence-safe both ways: a payload with no usable sites falls back to the
-- row, and a row that is missing or malformed falls back to the payload.
K.rimeSites = function(center: Vector3, extra): { Vector3 }
	local arena = BossArenas.items[K.RIME_ISLAND]
	local reach = (arena and tonumber(arena.floorRadius) or K.RIME_FLOOR) * 1.6
	local flat = Vector3.new(center.X, 0, center.Z)
	local expected: { Vector3 } = {}
	if arena and type(arena.thinIce) == "table" then
		for _, offset in arena.thinIce do
			if typeof(offset) == "Vector3" then
				table.insert(expected, Vector3.new(center.X + offset.X, center.Y, center.Z + offset.Z))
			end
		end
	end

	local sites: { Vector3 } = {}
	if type(extra.sites) == "table" then
		for _, site in extra.sites do
			if typeof(site) == "Vector3" then
				local here = Vector3.new(site.X, 0, site.Z)
				-- An offset, not a point: far from the arena and near nothing.
				if (here - flat).Magnitude > reach and here.Magnitude <= reach then
					here = flat + here
				end
				local at = Vector3.new(here.X, center.Y, here.Z)
				-- THE CROSS-CHECK. Said once and never again: a payload that
				-- disagrees with the mesh is still drawn (the server owns where
				-- the water is, and a silently-missing hole is worse than a
				-- misplaced one), but the disagreement is worth a line in the
				-- log because it means the mesh moved and BossArenas' own note
				-- - "if the mesh is regenerated, re-measure these" - was missed.
				if #expected > 0 and not K.riftWarned then
					local best = math.huge
					for _, hub in expected do
						best = math.min(best, (Vector3.new(hub.X, 0, hub.Z) - Vector3.new(at.X, 0, at.Z)).Magnitude)
					end
					if best > K.RIFT_TRUST then
						K.riftWarned = true
						warn(
							string.format(
								"[CreatureEvent] rimeShatter site %.1f studs off the nearest BossArenas thinIce hub"
									.. " - drawing the payload; re-measure the row against the mesh",
								best
							)
						)
					end
				end
				table.insert(sites, at)
			end
		end
	end
	if #sites == 0 then
		return expected
	end
	return sites
end

-- THE HOLES, OPENED. Static from here: every part is placed once and then
-- left, because open water does not animate and a Heartbeat that re-wrote 60
-- unchanging CFrames for the rest of the fight would be paying for nothing.
-- What DOES move over them is the server's chill pool, through the poolSpawn
-- handler this file has always had - which is the whole reason the collar
-- lands on the pool ring's own outer radius. One hazard, one picture.
K.rimeOpenWater = function(sites: { Vector3 }, radius: number)
	local rims = K.riftPool.rim
	local discs = K.riftPool.water
	local shown = 0
	-- One running loop per hole, collected here and owned by the rift state
	-- that is built at the end of this function - so the handles and the parts
	-- they belong to are created together and torn down together, and there is
	-- no window in which a loop exists that `clearRimeRift` cannot reach.
	local loops = {}
	for index, at in sites do
		local disc = discs[index]
		if not disc then
			break -- more sites than holes: the arena has four, and so has the pool
		end
		shown = index
		local y = sheetY(at.X, at.Z, at.Y)
		disc.Size = Vector3.new(0.3, radius * 2 * K.RIFT_INSET, radius * 2 * K.RIFT_INSET)
		-- Set a hair BELOW the sheet, not on it: the water is what is under the
		-- ice, and a disc floating a tenth of a stud proud of the floe reads as
		-- a painted circle. Everything else this file draws goes the other way.
		disc.CFrame = CFrame.new(at.X, y - 0.12, at.Z) * CFrame.Angles(0, 0, math.rad(90))
		disc.Transparency = 0.06

		-- The collar of broken ice round it, at the FULL radius - which is the
		-- chill pool's outer ring to the stud.
		local span = (2 * math.pi * radius) / K.RIFT_RIM * 1.1
		for i = 1, K.RIFT_RIM do
			local theta = (i / K.RIFT_RIM) * math.pi * 2
			local ct, st = math.cos(theta), math.sin(theta)
			local slab = rims[(index - 1) * K.RIFT_RIM + i]
			slab.Size = Vector3.new(radius * (1 - K.RIFT_INSET) * 2.4, 0.22, span)
			slab.CFrame = CFrame.new(at.X + ct * radius * 0.97, y + 0.06, at.Z + st * radius * 0.97)
				* CFrame.Angles(0, -theta, 0)
			slab.Transparency = 0.3
		end

		-- THE HOLE'S OWN VOICE, from the moment it opens and for as long as it
		-- is open. Started here and NOT gated on the camera, unlike everything
		-- else in this loop: a one-shot the player was too far away to hear is
		-- simply not heard, but a loop skipped at open time would leave that
		-- hole silent for the whole rest of the fight - including when the
		-- player walks up to its edge, which is the one moment it exists for.
		-- The row's own range (90) does the distance work, so nothing here has
		-- to ride the gain per frame.
		loops[index] = Sfx.loop("rimeRiftAmbient", Vector3.new(at.X, y, at.Z))

		-- ...and the moment it goes, staggered round the floe so four holes
		-- opening at once read as a sheet failing rather than as one event.
		task.delay(index * 0.09, function()
			if not nearCamera(at, K.RIME_CULL) then
				return
			end
			Sfx.play("rimeIceBurst", at)
			Vfx.burst(Vector3.new(at.X, y + 1, at.Z), K.RIME.crack, 30)
			Vfx.puff(Vector3.new(at.X, y + 0.6, at.Z), K.RIME.slush, 3.2)
			Vfx.splash(Vector3.new(at.X, y, at.Z), 3)
			Vfx.ring(Vector3.new(at.X, y + 0.2, at.Z), 2, radius, 0.6, K.RIME.slush)
		end)
	end
	-- The sites are kept because the water has to go on MOVING, and the pool
	-- that was supposed to move it stops. See K.RIFT_SWELL.
	K.rimeRift = {
		count = shown,
		sites = sites,
		radius = radius,
		loops = loops,
		missingAt = nil,
		nextSwellAt = 0,
		swellAt = 0,
	}
end

-- The water closes. Called from ONE place - the lifetime check in the step
-- below - so there is exactly one answer to "when do the holes go away", and
-- it is "when the animal that made them is gone".
K.clearRimeRift = function()
	if not K.rimeRift then
		return
	end
	local rift = K.rimeRift
	K.rimeRift = nil
	-- The loops FIRST and off the state we are about to drop, so a hole's
	-- sound can never outlive the hole. `stopLoop` is nil-safe and guards its
	-- own Parent, so a handle that never opened (a sprite-only cue with no
	-- pack imported returns nil) and one already collected both cost nothing.
	-- This is also what makes a repeat `rimeShatter` safe: startRimeShatter
	-- clears before it opens, so the four loops of the previous rift are
	-- stopped before the four of the new one are started and no hole is ever
	-- voiced twice.
	if rift and rift.loops then
		for _, handle in rift.loops do
			Sfx.stopLoop(handle)
		end
	end
	parkParts(K.riftPool.water)
	parkParts(K.riftPool.rim)
end

-- THE SHEET SPLITTING, centre to rim. Its own draw rather than drawFloeCracks
-- at a bigger radius: those cracks are a landing's damage, sixteen arms inside
-- a 24-stud hole, and they are tweened. This one is 120 studs long, has to be
-- interruptible (the boss can die while it is still fading) and is therefore
-- driven off the step below like every other continuous draw in this file.
K.startRimeShatter = function(position: Vector3, extra)
	local center = rimeArenaCenter(position)
	local arena = BossArenas.items[K.RIME_ISLAND]
	local radius =
		math.clamp(tonumber(extra.radius) or (arena and tonumber(arena.floorRadius)) or K.RIME_FLOOR, 30, 400)
	local siteRadius =
		math.clamp(tonumber(extra.siteRadius) or (arena and tonumber(arena.thinIceRadius)) or K.RIFT_RADIUS, 2, 60)

	-- A SECOND SHATTER IS A SECOND FIGHT. Clearing first means the pool can
	-- never be half-owned by two openers, and it is what stops the holes
	-- leaking across a wipe-and-retry inside one session.
	K.clearRimeRift()

	Sfx.play("rimeFloeCrack", center)
	task.delay(0.06, function()
		Sfx.play("rimeQuake", center)
	end)
	task.delay(0.22, function()
		Sfx.play("rimeWhiteout", center)
	end)

	K.rimeOpenWater(K.rimeSites(center, extra), siteRadius)

	-- The splits themselves. Each arm's bearing, reach and width are drawn
	-- ONCE, here, and the step only interpolates them - so no frame of the
	-- fade allocates and no crack changes shape while it is settling.
	local arms = table.create(K.SHATTER_ARMS)
	local y = sheetY(center.X, center.Z, center.Y) + 0.1
	for i = 1, K.SHATTER_ARMS do
		arms[i] = {
			theta = (i / K.SHATTER_ARMS) * math.pi * 2 + randomBetween(-0.09, 0.09),
			inner = K.SHATTER_RADIUS * K.SHATTER_INNER * randomBetween(0.7, 1.3),
			reach = radius * randomBetween(0.74, 1.0),
			width = randomBetween(K.SHATTER_WIDE[1], K.SHATTER_WIDE[2]),
		}
	end
	K.rimeShatter = { center = Vector3.new(center.X, y, center.Z), arms = arms, start = os.clock() }
	feelBlast(center, radius * 0.6, K.RIME_SHAKE, 0.9, Color3.fromRGB(214, 236, 255))
end

-- Both of phase two's persistent draws, and the ONE place either of them ends.
-- `model` is the tracked whale, already read by the caller: the holes' whole
-- lifetime is "while there is a boss", and the grace is what makes that safe
-- against `rimefang`'s half-second rescan (see RIFT_GRACE).
K.stepRimeShatter = function(now: number, model: Model?)
	local rift = K.rimeRift
	if rift then
		if model then
			rift.missingAt = nil
		else
			rift.missingAt = rift.missingAt or now
			if now - rift.missingAt >= K.RIFT_GRACE then
				K.clearRimeRift()
				rift = nil
			end
		end
	end
	-- The water working, one hole at a time (see K.RIFT_SWELL). Deliberately
	-- the SAME colour and the same 0.45r-to-r band the chill pool's own ring
	-- uses, so when the two overlap for the first twenty seconds they are
	-- indistinguishable and afterwards nothing about the hole has changed.
	if rift and now >= rift.nextSwellAt then
		rift.nextSwellAt = now + K.RIFT_SWELL
		local index = rift.swellAt % math.max(rift.count, 1) + 1
		rift.swellAt = index
		local at = rift.sites[index]
		if at and nearCamera(at, K.RIME_CULL) then
			local y = sheetY(at.X, at.Z, at.Y)
			Vfx.ring(Vector3.new(at.X, y + 0.05, at.Z), rift.radius * 0.45, rift.radius, 0.7, K.SKIN.frost)
			Vfx.puff(
				Vector3.new(
					at.X + randomBetween(-rift.radius, rift.radius),
					y + 0.2,
					at.Z + randomBetween(-rift.radius, rift.radius)
				),
				K.RIME.slush,
				0.9
			)
		end
	end

	local s = K.rimeShatter
	if not s then
		return
	end
	local elapsed = now - s.start
	if elapsed > K.SHATTER_GROW + K.SHATTER_FADE then
		K.rimeShatter = nil
		parkParts(K.shatterPool)
		return
	end
	if not nearCamera(s.center, K.RIME_CULL + K.RIME_FLOOR) then
		-- Its moment, simply not ours to watch - but it is still running, so
		-- the state stays and the clock keeps going. Parking rather than
		-- returning means nothing is left lit if the camera walks away mid-fade.
		parkParts(K.shatterPool)
		return
	end
	local grow = math.clamp(elapsed / K.SHATTER_GROW, 0, 1)
	-- Out fast, then settling: the split runs faster than the eye, which is
	-- the only honest way to draw a sheet failing.
	local u = 1 - (1 - grow) ^ 3
	local fade = math.clamp((elapsed - K.SHATTER_GROW) / K.SHATTER_FADE, 0, 1)
	for i = 1, K.SHATTER_ARMS do
		local arm = s.arms[i]
		local slab = K.shatterPool[i]
		local reach = arm.inner + (arm.reach - arm.inner) * u
		local ct, st = math.cos(arm.theta), math.sin(arm.theta)
		local mid = (arm.inner + reach) * 0.5
		slab.Size = Vector3.new(math.max(reach - arm.inner, 0.2), 0.16, arm.width)
		slab.CFrame = CFrame.new(s.center.X + ct * mid, s.center.Y, s.center.Z + st * mid)
			* CFrame.Angles(0, -arm.theta, 0)
		slab.Transparency = math.min(0.1 + 0.9 * fade, 1)
	end
end

-- THE ACCENT, applied to the RIMS and nothing else (see the note on RIME.hot).
-- Repainted on the CROSSING only - twice a fight, not sixty times a second -
-- and self-restoring, because `hot` goes false the moment the boss is no
-- longer tracked and the pools are shared with the next fight in this session.
--
-- These are OUR parts, built by makeMarker in init, so painting them is ours
-- to do: the no-Color rule is about CREATURE parts, whose colours
-- CombatFeedbackController caches to flash a hit.
-- The same accent for a tell drawn out of PARTICLES rather than out of pooled
-- rims. The fluke's contracting annulus is a rim by construction - a thin band
-- closing onto the point - so it grades with the rest; the spy-hop's chosen
-- mark and the whiteout's bed deliberately do NOT, because neither is a
-- footprint with an edge (one rides a person, one is weather) and RIME.mark
-- carries a meaning of its own that a repaint would blur.
K.rimeAccent = function(base: Color3): Color3
	return if K.rimeHot then K.RIME.hot else base
end

K.rimeGrade = function(model: Model?)
	local hot = model ~= nil and model:GetAttribute(K.ATTR_ENRAGED) == true
	if hot == K.rimeHot then
		return
	end
	K.rimeHot = hot
	-- THE ROAR AT HALF HEALTH, and this is the only place in the client that
	-- knows the moment: `Enraged` is an attribute, not an event, so nothing is
	-- fired at the frame it turns over except this comparison. Once per
	-- crossing by construction (the early-out above returns on every frame the
	-- answer has not changed), and only on the way UP - the way down is a boss
	-- leaving the world or a fresh fight, and neither is a roar.
	if hot and model then
		Sfx.play("rimeEnrage", model:GetPivot().Position)
	end
	for i = 1, K.LOCK_ARC do
		K.lockArc[i].Color = if hot then K.RIME.hot else K.RIME.mark
	end
	for slot = 1, K.WEDGE_SLOTS do
		local pool = wedgePool[slot]
		for i = 1, K.WEDGE_SLABS do
			-- The FAN is untouched: it is the dark that carries the footprint's
			-- contrast against the ice, and it is the half of this drawing the
			-- player actually stands in.
			pool.rim[i].Color = if hot then K.RIME.hot else K.SKIN.frost
		end
	end
end

-- The floequake's heave, on the client's own clock. The lane is LATCHED (the
-- server picked its bearing when it armed the tell and does not re-aim), and
-- the arm time is in the payload, so the moment the sheet goes is known
-- exactly at the instant the tell arrives - which is what lets the ice throw
-- itself about ON the beat instead of a round trip later.
K.rimeQuakeHeave = function(at: Vector3, angle: number, length: number, half: number)
	if not nearCamera(at, length + K.RIME_MARGIN) then
		return
	end
	local ct, st = math.cos(angle), math.sin(angle)
	Sfx.play("rimeQuake", at)
	for i = 1, 5 do
		local d = (i - 0.5) * (length / 5)
		local across = randomBetween(-half, half)
		local point = Vector3.new(at.X + ct * d - st * across, 0, at.Z + st * d + ct * across)
		point = Vector3.new(point.X, sheetY(point.X, point.Z, at.Y) + 0.2, point.Z)
		task.delay((i - 1) * 0.05, function()
			Vfx.burst(point + Vector3.new(0, 1.5, 0), K.RIME.crack, 24)
			Vfx.puff(point + Vector3.new(0, 1, 0), K.RIME.slush, 2.4)
			Vfx.ring(point, 1, half * 1.6, 0.4, K.SKIN.frost)
		end)
	end
	feelBlast(at, length * 0.5, K.SHAKE_PULSE, 0.4, Color3.fromRGB(214, 240, 255))
end

-- One read of the animal per frame, feeding both continuous draws. Split out
-- so the Heartbeat below stays a list of names and so a missing boss costs
-- one nil test rather than three.
K.stepRimeKit = function(now: number)
	local model = rimefang(now)
	local move, pose = K.rimeReadPose(model)
	local submerge = if model then tonumber(model:GetAttribute(K.ATTR_SUBMERGE)) else nil
	local sky = if model then tonumber(model:GetAttribute(K.RIME_ATTR_SKY)) else nil
	local burst = if model then tonumber(model:GetAttribute(K.RIME_ATTR_BURST)) or 0 else 0
	K.stepRimeWeb(now, move, pose, submerge, math.clamp(burst, 0, 1))
	K.stepRimeShadow(move, pose, sky)
	K.stepRimeLock(now)
	K.stepRimeShock(now)
	-- Phase two. Both take the model this frame already read: the holes' whole
	-- lifetime and the accent's whole state are "is there a boss, and is it
	-- enraged", and asking twice would be two answers to one question.
	K.stepRimeShatter(now, model)
	K.rimeGrade(model)
end

-- ------------------------------------------------------------- the tells
--
-- Rimefang borrows the stock telegraph kinds. The stock draws are right for
-- the bosses they were built for and wrong for a whale, so each one gets a
-- whale-shaped version here and everything unrecognised falls straight back
-- through to the generic frost draw.
--
-- TWO THINGS HAVE TO BE TRUE BEFORE ANY OF THEM DRAWS, in this order:
--   1. rimeBranch names a draw for this (kind, move, aimed). Resolved FIRST,
--      before any range test - see the note on rimeBranch.
--   2. rimeOwns says the payload came from the whale, not from something else
--      wearing frost at a radius that happens to collide - see RIME_ARENA.

-- The look. It stands vertically out of the water, half its body clear, and
-- picks somebody - the one beat in the fight where nothing is coming. The
-- audio pass already gives this the only bright cue in the whole fight, so
-- this stays clean and VERTICAL rather than loud: everything else in the
-- fight travels sideways.
local function spyhopRise(position: Vector3, duration: number)
	-- The low tell for the standing-up; the fight's one BRIGHT cue is saved
	-- for the mark a beat later, because the mark is the party information.
	Sfx.play("bossTell", position)
	local point = surfaceUnder(position)
	Vfx.splash(Vector3.new(position.X, point.Y + 0.2, position.Z), 3)
	for i = 0, 4 do
		task.delay(i * 0.07, function()
			Vfx.flash(position + Vector3.new(0, 1 + i * 2.6, 0), K.RIME.crest, 3.4 - i * 0.35, 0.3)
		end)
	end
	Vfx.ring(Vector3.new(position.X, point.Y + 0.18, position.Z), 3, 16, math.min(duration, 1.1), K.RIME.wake)
end

-- ...and this is who it picked. It rides the player rather than the ground it
-- fired at: a mark on the FLOOR is a place, and this one is a person.
local function chosenMark(position: Vector3, duration: number)
	local best, bestDist = nil, 8
	for _, other in Players:GetPlayers() do
		local character = other.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			local d = (root.Position - position).Magnitude
			if d < bestDist then
				best, bestDist = root, d
			end
		end
	end
	local mine = best ~= nil and best == localRoot()
	Sfx.play("rimeSpyHop", position)
	if mine then
		-- A chill down the back of the neck, and nothing that could be
		-- mistaken for taking a hit.
		CombatVfxController.kick(math.rad(1.6), 0, 0.5)
	end
	local pulses = math.max(2, math.floor(duration / 0.24))
	for i = 0, pulses - 1 do
		task.delay(i * 0.24, function()
			local at = if best and best.Parent then best.Position else position
			-- Rings CLOSING on them, not spreading off them: the attention is
			-- travelling inward, toward one person.
			-- RIME.mark, never BRINE.window: this fight already spends that
			-- gold on the beached window, forty studs away and often on
			-- screen at the same time, and gold means "hit it now" in every
			-- other arena in the game. Being chosen is the opposite news.
			Vfx.ring(at - Vector3.new(0, 2.6, 0), 7 - i * 0.9, 1.6, 0.3, K.RIME.mark)
			Vfx.burst(at + Vector3.new(0, 2.4, 0), K.RIME.mark, if mine then 14 else 8)
			Vfx.flash(at + Vector3.new(0, 4.5, 0), K.RIME.mark, 1.6, 0.24)
		end)
	end
end

-- WHICH WHALE-SHAPED DRAW A PAYLOAD IS, or nil when this file has nothing
-- better than the stock one for it.
--
-- RESOLVED BEFORE ANY RANGE TEST, and that ordering is the whole point. The
-- old code asked "is it near enough to watch?" first and answered `true`
-- ("handled, drew nothing") when it was not - so a frost payload whose radius
-- matched a RIME_TELL number but whose KIND had no branch here drew its stock
-- telegraph when you were close and nothing whatsoever when you were far: no
-- ring, no `bossTell`. A tell that only exists inside its own radius is not a
-- tell. Now an unrecognised payload is handed back to the stock draw at every
-- distance, and only a branch that will really draw claims the moment.
local function rimeBranch(kind: string, move: string?, aimed: boolean): string?
	if move == "bite" then
		-- A cone with no bearing is not a cone. Both wedges below REQUIRE the
		-- payload's `facing` (every stock tell carries one) and hand the
		-- moment back if it is ever missing, rather than drawing a mouth
		-- pointing down the X axis.
		return if kind == "snap" and aimed then "bite" else nil
	elseif move == "spyhop" and kind == "mark" then
		-- Two marks come out of the spy-hop and only `facing` tells them
		-- apart: the stock windup tell at the boss (every stock tell carries a
		-- bearing) and ATTACK_HANDLERS.spyhop's own, fired at the player it
		-- picked, which carries none.
		return if aimed then "rise" else "chosen"
	elseif move == "whiteout" and kind == "mark" then
		-- ...and the same test, for the opposite reason: the AIMED one is the
		-- windup tell at the boss, where no icicle ever lands. The unaimed
		-- ones are queueStrike's real per-player landing marks, and they are
		-- deliberately left to the stock draw, which is exactly right for
		-- them.
		return if aimed then "whiteout" else nil
	elseif move == "icebreach" and kind == "mark" then
		-- IT IS UNDER YOU. The point it will come up through, marked the
		-- moment the target stops tracking - `duration` is the time left
		-- until the sheet opens, and it is short on purpose.
		return "lock"
	elseif move == "skyfall" and kind == "mark" then
		-- ...and the same marker for the opposite direction. One shape for
		-- "this ground, this radius, at this time" across both, because the
		-- answer to both is the same answer and a player should only have to
		-- learn it once. What tells them apart is the BODY: one is a web of
		-- cracks coming at you, one is a shadow coming down.
		return "lock"
	elseif move == "floequake" and kind == "lane" then
		return "quake"
	elseif move == "flukeslam" and kind == "burst" then
		return "fluke"
	elseif move == "shatter" and kind == "burst" then
		-- THE PHASE-TWO OPENER, and it borrows `burst` from the fluke because
		-- the answer really is the same answer - be somewhere else - at nearly
		-- twice the radius. What makes it unmistakable is not the kind but the
		-- ring coming IN from the rim; see the branch.
		return "shatter"
	elseif move == "wash" and kind == "gustTell" and aimed then
		return "wash"
	end
	return nil
end

rimeTelegraph = function(kind: string, position: Vector3, extra): boolean
	if extra.skin ~= "frost" then
		return false
	end
	local radius = tonumber(extra.radius)
	local aimed = typeof(extra.facing) == "Vector3"
	local branch = rimeBranch(kind, rimeMove(radius, extra.move), aimed)
	if not branch then
		return false
	end
	-- THE ANIMAL, NOT THE SKIN AND THE NUMBER. Old Ribbonjaw prowls the same
	-- island frost-skinned with `ribbonlash` and `vanish` both at r7 - the
	-- spy-hop's radius, inside RIME_TELL_TOL - so `snap` and `phantom` tells
	-- that belong to a thief were being answered by a whale's book (and, past
	-- the old early-out, swallowed entirely). A radius is a coincidence; the
	-- boss standing in the arena is evidence.
	if not rimeOwns(position) then
		return false
	end
	local duration = math.clamp(tonumber(extra.duration) or 1, 0.15, 8)
	-- THE ONE TELL THAT IS NOT ITS OWN SIZE. The shatter's footprint is 26
	-- studs and its READ is the whole floe - the ring it draws starts at the
	-- rim, 120 studs from the boss - so culling it on its radius would have
	-- hidden the one warning that reaches the far side of the arena from
	-- everybody standing there, which is exactly who it is for.
	local cull = if branch == "shatter" then K.RIME_CULL + K.RIME_FLOOR else (radius or 20) + K.RIME_MARGIN
	if not nearCamera(position, cull) then
		return true -- its moment, simply not ours to watch
	end

	if branch == "bite" then
		-- THE MOUTH, DRAWN AS GROUND. This is the most frequent attack in the
		-- book (cooldown 1.8) and the stock `snap` draw is a 3-stud near-white
		-- flash at the pivot - no claim on any ground at all, in the one
		-- palette the floe already wears. Worse, the bite's real reach (22.6
		-- studs, jaws plus lunge) is longer than melee range, so a player
		-- hitting the animal is inside the cone BY CONSTRUCTION and the only
		-- honest thing to draw is the way out of it.
		Sfx.play("bossTell", position)
		wedges[K.WEDGE_BITE] = {
			kind = "bite",
			live = true, -- the jaws follow the animal; it is still turning
			center = position,
			angle = flatAngle(extra.facing) or 0,
			cone = K.BITE_CONE,
			reach = radius or K.BITE_RADIUS,
			start = os.clock(),
			windup = duration,
			-- ...and it stays up through the 0.14s of strike before the jaws
			-- actually close, shrinking as the boss lunges through it.
			life = duration + K.BITE_LEAD,
		}
		return true
	elseif branch == "rise" then
		spyhopRise(position, duration)
		return true
	elseif branch == "chosen" then
		chosenMark(position, duration)
		return true
	elseif branch == "whiteout" then
		-- The storm closing. A bed under the barrage, not an event: the
		-- strikes are what you dodge, the wind is only why you cannot see them
		-- coming. It draws NO landing marker, because nothing lands here - the
		-- stock 9-stud `mark` this used to fall through to was painted at the
		-- boss's pivot in the same visual language as the real per-player
		-- icicle marks, which is a marker for ground that is never hit.
		local center = rimeArenaCenter(position)
		Sfx.play("rimeWhiteout", position)
		for i = 0, 3 do
			task.delay(i * (duration / 4), function()
				Vfx.puff(
					center + Vector3.new(randomBetween(-26, 26), randomBetween(1, 9), randomBetween(-26, 26)),
					K.RIME.crest,
					3.2
				)
			end)
		end
		return true
	elseif branch == "lock" then
		-- THE POINT IT HAS COMMITTED TO, for both of the new moves. The
		-- server tracks the player through the windup and then STOPS: this
		-- payload is the instant it stopped, `radius` is the footprint that
		-- will be damaged, and `duration` is how long the player has to leave
		-- it. Everything else about these two attacks - the crack web running
		-- at you under the ice, the shadow coming down - is drawn off the
		-- pose attributes and has been on screen for a second or more already.
		-- This is the part that says WHERE and WHEN, exactly.
		local move = rimeMove(radius, extra.move)
		local point = surfaceUnder(position)
		K.startRimeLock(
			Vector3.new(position.X, point.Y, position.Z),
			radius or (if move == "skyfall" then K.SKYFALL_RADIUS else K.ICEBREACH_RADIUS),
			duration,
			move or "icebreach"
		)
		return true
	elseif branch == "quake" then
		-- THE LANE. Sixty studs of sheet from the animal out through whoever
		-- it picked, ten wide, heaved all at once - so the marker is the
		-- strip, and the answer is to be off it SIDEWAYS. Latched, not live:
		-- the server picked this bearing when it armed the tell and does not
		-- re-aim, and a lane that swung with the animal would send players
		-- the wrong way.
		local angle = flatAngle(extra.facing)
		if not angle then
			-- A lane down an unknown line is worse than no lane; the stock
			-- draw is at least honest about not knowing.
			return false
		end
		local length = tonumber(extra.length) or K.QUAKE_LENGTH
		-- `width` is the FULL width in the contract and a half-width in the
		-- corridor draw, and this is the one place it gets halved.
		local half = (tonumber(extra.width) or K.QUAKE_WIDTH) * 0.5
		Sfx.play("bossTell", position)
		wedges[K.WEDGE_LANE] = {
			kind = "corridor",
			live = false,
			center = position,
			angle = angle,
			cone = 0,
			width = half,
			reach = length,
			start = os.clock(),
			windup = duration,
			-- Held through the heave itself: the sheet is still throwing
			-- itself about after the tell's clock runs out, and a marker that
			-- vanished on the beat would clear the floe of warnings exactly
			-- while the ground was moving.
			life = duration + K.QUAKE_HEAVE,
		}
		-- The sheet working itself loose along the strip through the windup.
		local pulses = math.max(2, math.floor(duration / 0.24))
		for i = 0, pulses - 1 do
			task.delay(i * 0.24, function()
				local d = length * ((i + 1) / pulses)
				local at = Vector3.new(position.X + math.cos(angle) * d, position.Y, position.Z + math.sin(angle) * d)
				Vfx.puff(Vector3.new(at.X, sheetY(at.X, at.Z, at.Y) + 0.5, at.Z), K.RIME.slush, 1.6)
			end)
		end
		-- ...and the heave, on the beat the arm window ends.
		task.delay(duration, function()
			K.rimeQuakeHeave(position, angle, length, half)
		end)
		return true
	elseif branch == "fluke" then
		-- A hole opens beside you and the tail comes out of it. The ring
		-- CONTRACTS onto the point: this one is not somewhere to run from,
		-- it is somewhere to not be standing. ATTACK_HANDLERS.flukeslam now
		-- fires this from the fluke's own landing point rather than the nose,
		-- so `position` is finally the ground that gets hit.
		local point = surfaceUnder(position)
		Sfx.play("bossTell", position)
		local pulses = math.max(2, math.floor(duration / 0.22))
		for i = 0, pulses - 1 do
			task.delay(i * 0.22, function()
				Vfx.ring(
					point + Vector3.new(0, 0.16, 0),
					(radius or 24),
					(radius or 24) * 0.25,
					0.26,
					K.rimeAccent(K.RIME.crest)
				)
				Vfx.puff(point + Vector3.new(0, 0.3, 0), K.RIME.slush, 1.8)
			end)
		end
		return true
	elseif branch == "shatter" then
		-- IT REARS. The read has two halves and they say different things.
		--
		-- HALF ONE, "GET AWAY FROM IT": the lock, unchanged and borrowed
		-- whole - a dark disc at the real 26-stud footprint, held at full size
		-- for the windup, with the closing ring as its clock. The player
		-- already learned this shape from the icebreach and the skyfall, and
		-- the opener is not the moment to teach a new one.
		--
		-- HALF TWO, "AND THE WHOLE FLOE IS GOING": a ring rushing IN from the
		-- rim of the arena onto the animal, over the whole windup. Nothing
		-- else in this fight travels inward from outside its own footprint -
		-- every marker here grows or contracts inside the ground it claims -
		-- so a front arriving from the edge of the world can only be about the
		-- world. It is drawn from the ARENA CENTRE, not the boss, because the
		-- rim is concentric with the floe and not with the whale.
		local point = surfaceUnder(position)
		local center = rimeArenaCenter(position)
		local arena = BossArenas.items[K.RIME_ISLAND]
		local floor = (arena and tonumber(arena.floorRadius)) or K.RIME_FLOOR
		local reach = radius or K.SHATTER_RADIUS
		Sfx.play("rimeCrackLock", position)
		task.delay(duration * 0.45, function()
			-- The roar, mid-windup: the rear is the tell, the roar is the
			-- commitment, and the slam is the answer to both.
			Sfx.play("rimeThrash", position)
		end)
		K.startRimeLock(Vector3.new(position.X, point.Y, position.Z), reach, duration, "shatter")
		Vfx.shockwave(
			Vector3.new(center.X, sheetY(center.X, center.Z, center.Y) + 1.2, center.Z),
			floor,
			reach,
			duration,
			K.RIME.crack,
			0.55
		)
		-- ...and the sheet working itself loose ahead of it, marching OUT from
		-- the boss along eight bearings while the ring comes in. The two cross,
		-- which is the picture: the floe failing from both ends at once.
		local pulses = math.max(2, math.floor(duration / 0.2))
		for i = 0, pulses - 1 do
			task.delay(i * 0.2, function()
				local d = reach * 0.4 + (floor - reach * 0.4) * ((i + 1) / pulses)
				for k = 1, 8 do
					local theta = (k / 8) * math.pi * 2 + i * 0.19
					local at =
						Vector3.new(position.X + math.cos(theta) * d, position.Y, position.Z + math.sin(theta) * d)
					Vfx.puff(Vector3.new(at.X, sheetY(at.X, at.Z, at.Y) + 0.5, at.Z), K.RIME.slush, 1.5)
				end
			end)
		end
		return true
	elseif branch == "wash" then
		-- THE WALL, GATHERING - AND ALL OF IT. The answer to the wash is
		-- cover, so the read has to start on the windup and be complete before
		-- the crest exists. The old tell was spray alone and it reached 23
		-- studs against a 34-stud attack: 54% of the footprint BY AREA carried
		-- no warning at all, which is most of the floe the wall was about to
		-- take. The wedge below is the server's own hit test drawn on the
		-- ground - inside `radius`, inside `cone` of the bearing - at full
		-- size for the whole windup, because a footprint that grows into
		-- honesty is dishonest until it gets there.
		Sfx.play("rimeWash", position)
		local reach = radius or 34
		wedges[K.WEDGE_WASH] = {
			kind = "wash",
			live = true, -- ...and so does the wall, right up to `a.dir`
			center = position,
			angle = flatAngle(extra.facing) or 0,
			-- The payload carries no cone (the stock tell sends none), so the
			-- row's own number stands in. See the REPORT.
			cone = tonumber(extra.cone) or K.WASH_CONE,
			reach = reach,
			start = os.clock(),
			windup = duration,
			life = duration,
		}
		-- ...and the spray coming up along the front it is about to shoulder
		-- across, which was the only part of the old tell that was not a lie.
		local base = flatAngle(extra.facing) or 0
		local ground = sheetY(position.X, position.Z, position.Y)
		local pulses = math.max(2, math.floor(duration / 0.24))
		for i = 0, pulses - 1 do
			task.delay(i * 0.24, function()
				local r = K.WASH_INNER + (reach - K.WASH_INNER) * ((i + 1) / pulses)
				for k = 1, 7 do
					local theta = base + K.WASH_CONE * ((k - 0.5) / 7 * 2 - 1)
					Vfx.puff(
						Vector3.new(
							position.X + math.cos(theta) * r,
							ground + 0.6 + i * 0.5,
							position.Z + math.sin(theta) * r
						),
						K.RIME.crest,
						1.5
					)
				end
			end)
		end
		return true
	end
	return false
end

-- ================================================================ THE KRAKEN
-- The final fight's own events. Everything here draws with the existing Vfx /
-- Sfx vocabulary and the existing marker pool - there is no new effect
-- machinery, only new arrangements of it - and every constant is a K field
-- because this module sits ON Luau's 200-live-locals-per-scope ceiling and a
-- new chunk local here fails to compile the whole file.

K.KRAKEN = {
	-- The sweep's burning lane strip. Studs between the ticks that draw it and
	-- how often the whole strip re-pulses: fast enough to read as a warning
	-- rather than as scenery, slow enough not to strobe.
	LANE_STEP = 9,
	LANE_PULSE = 0.22,
	LANE_WIDTH = 12,
	-- The list's tumbling debris.
	LIST_PUFFS = 9,
	LIST_SPREAD = 26,
	-- The mast bell's dust.
	BELL_DUST = 5,
	-- The eye lock's ground mark.
	LOCK_RADIUS = 7.5,
	LOCK_PULSE = 0.3,
	-- The swallow's darkness, and the collapse's release. 1.5s each way.
	SWALLOW_DARK = 1.5,
	SWALLOW_RUSH = 22, -- streaks drawn past the camera while it closes
	-- The red edge that says the eye is on YOU. Not a full-screen wash: the
	-- middle of the screen is where the crosshair and the thing about to hit
	-- you both are, and a wash over it is the fight telling you something by
	-- taking away your ability to see it.
	VIGNETTE_THICK = 0.16,
	VIGNETTE_ALPHA = 0.42,
	VIGNETTE_FADE = 0.35,
	-- ------------------------------------ the new-attacks pass (2026-09-12)
	--
	-- THE GRATING SPEAR'S STICK. How big a ring the tip punches in the planking
	-- and how many splinters come out of it. The DISCS of the three marks are the
	-- server's own telegraphs and the walking mark is the arm's own (see
	-- KrakenBodyController's MARK table) - all this draws is the moment the deck
	-- loses, which is the moment the four-second window opens.
	SPEAR_HOLE = 9,
	SPEAR_SPLINTERS = 14,
	-- THE SUCKER VOLLEY. How many puffs mark each sucker's flight. Not a
	-- projectile: the server owns where the things land (Fn.queueStrike draws the
	-- disc and resolves the hit), so what this adds is only the THROW - a trail of
	-- ink from the arm toward each mark, arriving with the disc.
	VOLLEY_STEPS = 5,
	-- THE MAELSTROM COIL. How often the wake churns while the limb circles, and
	-- how wide. The moving GLOW is the arm's own deck mark drawn off TargetX /
	-- TargetZ (so it cannot drift off the attack); this is the water breaking over
	-- it, drawn around the LOCAL player because being followed is something that
	-- happens to wherever you are.
	WAKE_PULSE = 0.28,
	WAKE_R = 14,
	-- THE ERUPTION. The column's own ring and how high the spray goes.
	ERUPT_SPRAY = 11,
	-- THE OVERCHARGE'S MISFIRE. A deluge going off inside the funnel: one big ink
	-- puff at the siphon and a ring of it rolling out over the water, no damage
	-- anywhere, which is the whole read - the attack happened to the animal.
	MISFIRE_PUFFS = 16,
	MISFIRE_R = 70,
	-- THE EYE'S GLINT. The window the lance leaves behind, drawn as the orbs
	-- holding their flare (KrakenBodyController.flareEyes) plus a slow ring at the
	-- eye so the opening is VISIBLE from the deck rather than only true.
	GLINT_R = 26,
}

-- Live kraken state. One table, so the Heartbeat step has one thing to look at.
K.kraken = { lockAt = nil, lockUntil = 0, lockMine = false, vignette = 0, nextLockPulse = 0 }

-- Two modules this fight needs to reach, held as K FIELDS rather than chunk
-- locals for the register-budget reason above. Resolved in init, so a require
-- cycle cannot form at load time.
--   CameraController - the ship's list is a CAMERA roll (nothing moves), so
--                      the roll lives there and the audio and debris here.
--   KrakenPath       - the lane mailbox: the sweep event carries the lane
--                      exactly and the limb would otherwise reconstruct it by
--                      mirroring, which can disagree with the strip a player
--                      is standing on.
K.krakenWire = function()
	K.CameraController = require(script.Parent.CameraController)
	K.KrakenBody = require(script.Parent.KrakenBodyController)
	K.KrakenPath = require(Shared.Modules.KrakenPath)
end

-- A lane end, tolerantly: the payload may carry world points or bare X
-- stations, and a client that guesses wrong draws the strip somewhere the limb
-- is not.
K.krakenLaneEnd = function(value, fallback: Vector3): Vector3
	if typeof(value) == "Vector3" then
		return value
	end
	local x = tonumber(value)
	return if x then Vector3.new(x, fallback.Y, fallback.Z) else fallback
end

-- THE SWEEP'S LANE: a burning strip laid down the deck between the two ends,
-- re-pulsing for the whole windup. The strip IS the answer to the attack -
-- arena_gen measured the crates against the sweep plane precisely so that
-- there is somewhere to be - so it is drawn wide enough to show which side of
-- it you are on rather than as a hairline.
K.EVENTS.sweepLane = function(position: Vector3, extra)
	local from = K.krakenLaneEnd(extra.from, position)
	local to = K.krakenLaneEnd(extra.to, position)
	local duration = tonumber(extra.duration) or 1.2
	local width = tonumber(extra.width) or K.KRAKEN.LANE_WIDTH
	local colour = skinColor(extra, K.SKIN.kraken)
	-- Hand the exact lane to the limb, so the drawn tentacle sweeps the strip
	-- the player is reading rather than a mirrored guess at it.
	if K.KrakenPath then
		K.KrakenPath.noteLane(from.X, to.X, from.Z, Workspace:GetServerTimeNow())
	end
	Sfx.play("bossTell", position)
	local span = (to - from).Magnitude
	local ticks = math.clamp(math.floor(span / K.KRAKEN.LANE_STEP), 2, 24)
	local pulses = math.max(1, math.floor(duration / K.KRAKEN.LANE_PULSE))
	for i = 0, pulses - 1 do
		task.delay(i * K.KRAKEN.LANE_PULSE, function()
			for k = 0, ticks do
				local at = from:Lerp(to, k / ticks)
				local point = surfaceUnder(at)
				Vfx.ring(point + Vector3.new(0, 0.15, 0), width * 0.34, width * 0.5, 0.24, colour)
			end
		end)
	end
end

-- THE LIST. SUBSTITUTION A, and the reason is worth stating where the effect
-- is: the hull is an authored 170-stud mesh and the fight is staged on
-- MEASURED deck heights - the sweep plane, the cover tops, the four wrap
-- points. Heel the model and every one of those numbers is wrong, while the
-- player still stands bolt upright on the tilted planking. So NO GEOMETRY
-- MOVES: the camera rolls, the horizon swings, the loose gear tumbles, and
-- every collision surface is exactly where the fight thinks it is.
K.EVENTS.shipList = function(position: Vector3, extra)
	local duration = tonumber(extra.duration) or 2.5
	local side = tonumber(extra.side) or 1
	if extra.active == false then
		return
	end
	if K.CameraController then
		K.CameraController.rollCamera(duration, side)
	end
	Sfx.play("shellCreak", position)
	-- The debris: loose gear sliding the way the deck is going. Drawn around
	-- the LOCAL player rather than at the event's point, because the list is
	-- something that happens to the ship and therefore to wherever you are.
	local root = localRoot()
	local at = if root then root.Position else position
	local pulses = math.max(2, math.floor(duration / 0.3))
	for i = 0, pulses - 1 do
		task.delay(i * 0.3, function()
			for k = 1, K.KRAKEN.LIST_PUFFS do
				local a = (k / K.KRAKEN.LIST_PUFFS) * math.pi * 2
				local r = K.KRAKEN.LIST_SPREAD * (0.4 + 0.6 * (k % 3) / 3)
				Vfx.puff(
					at + Vector3.new(math.cos(a) * r + side * 6, 0.6 + (i % 3), math.sin(a) * r),
					K.COLOR.smoke,
					1.1
				)
			end
		end)
	end
end

-- THE MAST BELL. The swinging spar itself is SERVER-ANIMATED - it is a hazard
-- with a hitbox and it is not this file's to invent - so all that is drawn is
-- what the ship does around it: the creak of a mast taking the load, and dust
-- shaken out of the rigging on every pass.
K.EVENTS.mastBell = function(position: Vector3, extra)
	local passes = math.clamp(tonumber(extra.passes) or 2, 1, 8)
	local duration = tonumber(extra.duration) or 2.0
	local lead = tonumber(extra.lead) or 0
	local radius = tonumber(extra.radius) or 10
	local gap = if passes > 1 then duration / passes else duration
	Sfx.play("bossTell", position)
	for i = 0, passes - 1 do
		task.delay(lead + i * gap, function()
			Sfx.play("shellCreak", position)
			for k = 1, K.KRAKEN.BELL_DUST do
				local a = (k / K.KRAKEN.BELL_DUST) * math.pi * 2
				Vfx.puff(
					position + Vector3.new(math.cos(a) * radius * 0.5, 2 + k * 0.6, math.sin(a) * radius * 0.5),
					K.COLOR.smoke,
					1.3
				)
			end
			Vfx.ring(surfaceUnder(position) + Vector3.new(0, 0.15, 0), radius * 0.4, radius, 0.3, K.SKIN.kraken)
		end)
	end
end

-- THE EYE LOCK. A mark that FOLLOWS - the whole point of the attack is that
-- standing still is not an answer - plus the eye itself flaring, and, only if
-- the eye is on YOU, a red edge. Everyone sees where the lance is going;
-- only its target is told to move.
K.EVENTS.eyeLock = function(position: Vector3, extra)
	local duration = tonumber(extra.duration) or 2.0
	local mine = tonumber(extra.userId) == player.UserId
	K.kraken.lockUntil = os.clock() + duration
	K.kraken.lockMine = mine
	K.kraken.lockAt = position
	if K.KrakenBody then
		K.KrakenBody.flareEyes(duration)
	end
	Sfx.play("bossTell", position)
	if mine then
		K.kraken.vignette = K.KRAKEN.VIGNETTE_ALPHA
	end
end

-- THE LANCE STOPPED SOMEWHERE. Sparks where it hit, which is the read that
-- teaches cover: the beam ends AT the thing you put between you and it.
K.EVENTS.eyeLanceBlocked = function(position: Vector3, extra)
	local at = if typeof(extra.to) == "Vector3" then extra.to else position
	Vfx.burst(at, K.SKIN.lure, 26)
	Vfx.flash(at, K.SKIN.lure, 3, 0.18)
	Vfx.puff(at, K.COLOR.smoke, 1.4)
	Sfx.play("explodeCrack", at)
end

-- THE SPEAR IS THROUGH THE DECK, and this is the ONE new event of the pass that
-- draws something the fight has no other word for: a hole in the planking. Ink
-- where the tip went in, splinters thrown up around it, and a ring that says "the
-- limb cannot leave" - because for the next four seconds it cannot, and that is
-- the move's whole reward.
--
-- The WINDOW itself is not drawn here. It is the arm's own lit knuckle
-- (WeakpointHot / WeakpointPos, the body controller's run of hot suckers), which
-- is the language every punish in this fight already speaks - a second, louder
-- tell on top of it would make the cheapest window in the book look like the
-- biggest.
K.EVENTS.krakenSpearStuck = function(position: Vector3, extra)
	local duration = tonumber(extra.duration) or 4.0
	local colour = skinColor(extra, K.SKIN.kraken)
	local ground = surfaceUnder(position)
	Sfx.play("explodeCrack", position)
	Sfx.play("bossSlam", position)
	Vfx.flash(position, colour, K.KRAKEN.SPEAR_HOLE * 0.5, 0.22)
	Vfx.ring(ground + Vector3.new(0, 0.15, 0), 1, K.KRAKEN.SPEAR_HOLE, 0.45, colour)
	for i = 1, K.KRAKEN.SPEAR_SPLINTERS do
		local a = (i / K.KRAKEN.SPEAR_SPLINTERS) * math.pi * 2
		local r = K.KRAKEN.SPEAR_HOLE * (0.35 + 0.65 * ((i % 3) / 3))
		Vfx.puff(ground + Vector3.new(math.cos(a) * r, 1.2 + (i % 4) * 0.7, math.sin(a) * r), K.COLOR.smoke, 0.9)
	end
	-- ...and a slow second ring at the far end of the window, so a player who
	-- turned away knows how long is left without reading a health bar.
	task.delay(math.max(duration - 0.6, 0.1), function()
		Vfx.ring(ground + Vector3.new(0, 0.15, 0), K.KRAKEN.SPEAR_HOLE, 1, 0.55, colour)
	end)
end

-- THE VOLLEY'S THROW. The server owns where the six suckers land - each one is an
-- ordinary queued strike, so the disc and the damage are already drawn and
-- resolved - and this is only the flight between the arm and the marks, which is
-- the half a player needs in order to understand that the limb threw them.
--
-- DRAWN AS PUFFS ALONG A LINE rather than as parts, because they are not
-- projectiles and must never look like something that can be intercepted: there is
-- no part in flight to shoot, and a solid-looking glob that cannot be stopped is a
-- worse lie than a streak of ink that obviously cannot.
K.EVENTS.krakenVolley = function(position: Vector3, extra)
	local from = if typeof(extra.from) == "Vector3" then extra.from else position
	local flight = tonumber(extra.flight) or 1.1
	local stagger = tonumber(extra.stagger) or 0.14
	local colour = skinColor(extra, K.SKIN.ink)
	Sfx.play("bossSpit", from)
	Vfx.burst(from, colour, 22)
	local marks = if type(extra.marks) == "table" then extra.marks else {}
	for i, mark in marks do
		if typeof(mark) == "Vector3" then
			for step = 1, K.KRAKEN.VOLLEY_STEPS do
				local u = step / K.KRAKEN.VOLLEY_STEPS
				task.delay((i - 1) * stagger + u * flight * 0.9, function()
					-- Over an arc, not along a chord: Vfx.arcPoint is the same
					-- helper the anchor toss and the ink mortar's globs fly on, so
					-- six suckers lobbed onto a deck read like everything else this
					-- animal throws.
					local at = Vfx.arcPoint(from, mark, 26, u)
					Vfx.puff(at, colour, 1.0)
				end)
			end
		end
	end
end

-- THE COIL'S WAKE. Water breaking over something circling underneath it, for the
-- whole three seconds of the track.
--
-- THE MOVING MARK IS NOT HERE, deliberately, and this is the one division of
-- labour in the pass worth stating: the glow that FOLLOWS you is drawn by
-- KrakenBodyController off the arm's replicated TargetX / TargetZ, which is the
-- same pair the drawn limb reads, so it cannot drift off the attack or outlive it.
-- An event-driven chase would have to guess the target's path between packets,
-- and a mark that guesses wrong about a tracking attack is worse than no mark.
--
-- So what this adds is the CHURN, and it is drawn around the local player rather
-- than at the event's point for the reason the ship's list is: being hunted is
-- something that happens to wherever you are standing.
K.EVENTS.krakenCoil = function(position: Vector3, extra)
	local duration = tonumber(extra.duration) or 3.0
	local colour = skinColor(extra, K.SKIN.storm)
	Sfx.play("bossTell", position)
	Sfx.play("burrow", position)
	local pulses = math.max(2, math.floor(duration / K.KRAKEN.WAKE_PULSE))
	for i = 0, pulses - 1 do
		task.delay(i * K.KRAKEN.WAKE_PULSE, function()
			local root = localRoot()
			local at = surfaceUnder(if root then root.Position else position)
			-- TIGHTENING, not constant: the wake closes in over the three seconds,
			-- which is the only information the attack gives about its own clock.
			local u = i / math.max(pulses - 1, 1)
			local r = K.KRAKEN.WAKE_R * (1 - 0.45 * u)
			Vfx.ring(at + Vector3.new(0, 0.15, 0), r * 0.4, r, K.KRAKEN.WAKE_PULSE * 1.4, colour)
			Vfx.puff(at + Vector3.new(0, 0.8, 0), K.COLOR.smoke, 0.8 + u)
		end)
	end
end

-- THE COLUMN. A tentacle coming vertically out of the sea, and whether it caught
-- anybody - because the two outcomes are different MOVES to a player: one is damage
-- and one is a three-second window on a limb lying across the deck.
K.EVENTS.krakenErupt = function(position: Vector3, extra)
	local radius = tonumber(extra.radius) or 18
	local colour = skinColor(extra, K.SKIN.storm)
	local ground = surfaceUnder(position)
	if extra.whiff then
		-- THE FLOP, fired from the server's `finish` rather than its `fire`: the
		-- limb has just come down across the planking with nothing holding it up.
		-- Heavier and lower than the eruption itself, and it borrows the `exposed`
		-- language rather than inventing one - a player who has seen any boss go
		-- down knows what the sparks mean.
		Sfx.play("bossDown", position)
		Vfx.ring(ground + Vector3.new(0, 0.15, 0), radius * 0.5, radius * 1.6, 0.8, colour)
		Vfx.puff(ground + Vector3.new(0, 1.4, 0), K.COLOR.smoke, 2.2)
		return
	end
	Sfx.play("bossSlam", position)
	Vfx.shockwave(ground, radius * 0.3, radius * 1.3, 0.5, colour, 0.45)
	Vfx.ring(ground + Vector3.new(0, 0.15, 0), radius * 0.35, radius, 0.4, colour)
	for i = 1, K.KRAKEN.ERUPT_SPRAY do
		local a = (i / K.KRAKEN.ERUPT_SPRAY) * math.pi * 2
		Vfx.puff(
			ground + Vector3.new(math.cos(a) * radius * 0.55, 2 + i * 1.1, math.sin(a) * radius * 0.55),
			colour,
			1.2
		)
	end
	if extra.hit == false then
		return
	end
	Vfx.flash(position, colour, 7, 0.2)
end

-- THE MISFIRE. The biggest thing the party can make happen to this animal, and it
-- is drawn as an ANTICLIMAX on purpose: the deluge goes off inside the funnel, so
-- there is a great deal of light and noise at the siphon, a ring of ink rolling out
-- over the water - and nothing lands anywhere. That absence IS the reward's first
-- half; the second half is two arms on the deck, which the arms draw themselves.
K.EVENTS.krakenMisfire = function(position: Vector3, extra)
	local duration = tonumber(extra.duration) or 1.2
	local colour = skinColor(extra, K.SKIN.ink)
	if K.KrakenBody then
		-- The core DIES rather than flaring: a short, weak flare replacing the
		-- five-second charge is what "it went out" looks like on a channel that only
		-- knows how to glow.
		K.KrakenBody.flareSiphon(duration * 0.5, 0.25)
	end
	Sfx.play("explodeBoom", position)
	Sfx.play("bossStagger", position)
	Vfx.flash(position, colour, 16, duration)
	Vfx.shockwave(position, 8, K.KRAKEN.MISFIRE_R, duration, colour, 0.6)
	for i = 1, K.KRAKEN.MISFIRE_PUFFS do
		local a = (i / K.KRAKEN.MISFIRE_PUFFS) * math.pi * 2
		local r = K.KRAKEN.MISFIRE_R * 0.35 * (0.5 + 0.5 * ((i % 4) / 4))
		task.delay((i % 5) * 0.08, function()
			Vfx.puff(position + Vector3.new(math.cos(a) * r, (i % 6) * 3, math.sin(a) * r), colour, 2.0)
		end)
	end
end

-- THE GLINT. The eye holds its flare after the lance is away and the head takes
-- 1.5x for the window, so the window has to be VISIBLE from 350 studs of open
-- water - an opening nobody can see is not an opening, it is a statistic.
--
-- The orbs are the tell and they are already built: flareEyes is what the LOCK
-- uses, so the same stare that warned you the lance was coming is what tells you
-- the animal is open. The ring at the eye is the second half, because from the
-- deck the orbs are 276 studs up and small.
K.EVENTS.krakenGlint = function(position: Vector3, extra)
	local duration = tonumber(extra.duration) or 2.5
	local colour = skinColor(extra, K.SKIN.storm)
	if K.KrakenBody then
		K.KrakenBody.flareEyes(duration)
	end
	Sfx.play("bossStance", position)
	Vfx.flash(position, colour, 9, duration * 0.5)
	local pulses = math.max(2, math.floor(duration / 0.5))
	for i = 0, pulses - 1 do
		task.delay(i * 0.5, function()
			Vfx.ring(position, K.KRAKEN.GLINT_R * 0.4, K.KRAKEN.GLINT_R, 0.45, colour)
		end)
	end
end

-- THE SIPHON FLARES. The funnel is the animal's door and its core is the only
-- other Neon it owns, so this is a light coming on inside a thing the size of
-- a building rather than an explosion in front of it.
K.EVENTS.inkFlare = function(position: Vector3, extra)
	local duration = tonumber(extra.duration) or 1.0
	local charge = tonumber(extra.charge) or 1
	if K.KrakenBody then
		K.KrakenBody.flareSiphon(duration, charge)
	end
	Vfx.flash(position, K.SKIN.ink, 8 * charge, duration)
	Vfx.shockwave(position, 4, 40 * charge, duration, K.SKIN.ink, 0.5)
	Sfx.play("lureFlare", position)
end

-- SWALLOWED. 1.5 seconds of the light going out with the world rushing past,
-- for the players it actually happens to. Not a cutscene and not a fade to
-- black on everyone: someone still on the deck watching a friend go in should
-- see the deck.
K.EVENTS.krakenSwallow = function(position: Vector3, extra)
	local duration = tonumber(extra.duration) or K.KRAKEN.SWALLOW_DARK
	local to = if typeof(extra.to) == "Vector3" then extra.to else position
	local mine = extra.name == nil or tostring(extra.name) == player.Name
	Sfx.play("bossRise", position)
	if not mine then
		return
	end
	-- The same surface the trench's blackout owns, driven the same way: cancel
	-- whatever is on it, take it to opaque, and let the collapse tween it back.
	darkTween = if darkTween then darkTween:Cancel() else nil
	darkFrame.BackgroundTransparency = 1
	darkTween = TweenService:Create(
		darkFrame,
		TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ BackgroundTransparency = 0.04 }
	)
	darkTween:Play()
	-- The rush: streaks drawn between where you were and where you are going,
	-- so the darkness has a direction and reads as being TAKEN somewhere.
	local root = localRoot()
	local at = if root then root.Position else position
	for i = 1, K.KRAKEN.SWALLOW_RUSH do
		task.delay((i / K.KRAKEN.SWALLOW_RUSH) * duration * 0.8, function()
			local u = i / K.KRAKEN.SWALLOW_RUSH
			Vfx.puff(at:Lerp(to, u) + Vector3.new((i % 5 - 2) * 2.5, (i % 3) * 2, (i % 4 - 2) * 2.5), K.SKIN.ink, 1.6)
		end)
	end
end

-- ...AND BACK OUT. The inverse: the dark lifts instead of falling.
K.EVENTS.krakenCollapse = function(position: Vector3, extra)
	local duration = tonumber(extra.duration) or K.KRAKEN.SWALLOW_DARK
	darkTween = if darkTween then darkTween:Cancel() else nil
	darkFrame.BackgroundTransparency = 0.04
	darkTween = TweenService:Create(
		darkFrame,
		TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 1 }
	)
	darkTween:Play()
	Vfx.burst(position, K.SKIN.gullet, 40)
	Sfx.play("bossCollapse", position)
end

-- The per-frame half of the two effects that have to FOLLOW something: the
-- lock mark under a moving player, and the red edge fading off.
K.stepKraken = function(now: number)
	local live = K.kraken
	if live.lockUntil > now then
		local root = localRoot()
		local at = if root then root.Position else live.lockAt
		if at and now >= live.nextLockPulse then
			live.nextLockPulse = now + K.KRAKEN.LOCK_PULSE
			local point = surfaceUnder(at)
			Vfx.ring(
				point + Vector3.new(0, 0.15, 0),
				K.KRAKEN.LOCK_RADIUS * 0.35,
				K.KRAKEN.LOCK_RADIUS,
				K.KRAKEN.LOCK_PULSE,
				K.SKIN.lure
			)
		end
	end
	if live.vignette > 0 then
		live.vignette = if live.lockUntil > now
			then K.KRAKEN.VIGNETTE_ALPHA
			else math.max(0, live.vignette - K.KRAKEN.VIGNETTE_ALPHA * 0.02)
		for _, edge in K.vignette do
			edge.BackgroundTransparency = 1 - live.vignette
		end
	end
end

local warnedKinds = {}

local function onCreatureEvent(kind, position, extra)
	if typeof(position) ~= "Vector3" then
		return
	end
	local handler = type(kind) == "string" and K.EVENTS[kind]
	if not handler then
		if not warnedKinds[kind] then
			warnedKinds[kind] = true
			warn(string.format("[CreatureEvent] no handler for kind %s", tostring(kind)))
		end
		return
	end
	handler(position, if type(extra) == "table" then extra else {})
end

-- ---------------------------------------------------------------- lifecycle

function CreatureEventController.init()
	folder = Instance.new("Folder")
	folder.Name = "CreatureFx"
	folder.Parent = Workspace
	-- ASKED ONCE, HERE. Whether the attack-fx pack is imported decides which
	-- of two animations the eruption runs, and the pools below are built from
	-- it too - so it is settled before a single part exists rather than
	-- re-walked in a Heartbeat step for an answer that cannot change.
	K.fxHas = K.fxPiece("Spike1") ~= nil
	for i = 1, K.GLOB_POOL do
		globs[i] = { part = makeGlob(), active = false }
	end

	-- Brinejaw's markers: one ladder of rungs (and the shadows a high arm
	-- casts) per concurrent sweep, plus the stagger window's closing disc.
	for slot = 1, K.SWEEP_SLOTS do
		local pool = { rungs = {}, shadows = {} }
		for i = 1, K.SWEEP_RUNGS do
			pool.rungs[i] = makeMarker("SweepRung", K.BRINE.low, true)
			pool.shadows[i] = makeMarker("SweepShadow", K.BRINE.shadow, false)
		end
		sweepPool[slot] = pool
	end
	-- The choir's beam: a widening ladder of lit ground per concurrent sweep,
	-- plus the shaft that ties it back to the lantern casting it.
	for slot = 1, K.BEAM_SLOTS do
		local pool = { rungs = {} }
		for i = 1, K.BEAM_RUNGS do
			-- TELL.LIGHT, not LURE_LIGHT. The rungs are the HITBOX DRAWN and
			-- the shaft and the lamps are the lantern; painting the first in
			-- the scenery's own gold is what made "the light is coming" and
			-- "that is a lantern you can shoot" the same read. The lamps keep
			-- LURE_LIGHT on purpose - they are light, not a mark.
			pool.rungs[i] = makeMarker("BeamRung", K.NoctyssPath.TELL.LIGHT, true)
		end
		pool.shaft = makeMarker("BeamShaft", K.LURE_LIGHT, true)
		-- ...and the lamps that make the beam actually LIGHT the room. Invisible
		-- anchors (Transparency 1 out of makeMarker, and never touched after) -
		-- they exist only to carry a PointLight down the wedge. Built once here
		-- with the rest of the pool, moved in the Heartbeat step, never churned:
		-- a cast creates nothing and releases nothing to the collector.
		--
		-- The light handles are cached alongside the parts rather than found by
		-- name each frame - this runs 6 times a Heartbeat at two beams.
		pool.lamps, pool.lights = {}, {}
		for i = 1, K.BEAM_LAMPS do
			local lamp = makeMarker("BeamLamp", K.LURE_LIGHT, false)
			local light = Instance.new("PointLight")
			light.Color = K.LURE_LIGHT
			light.Brightness = 0
			light.Range = K.BEAM_LAMP_RANGE_MIN
			-- NO SHADOWS. The server already answers occlusion for real
			-- (NoctyssPath.beamBlocked); shadow-casting here would buy a second,
			-- slower, differently-wrong answer to the same question.
			light.Shadows = false
			light.Enabled = false
			light.Parent = lamp
			pool.lamps[i] = lamp
			pool.lights[i] = light
		end
		beamPool[slot] = pool
	end

	-- Noctyss's floor bands (K.choirTell): three concurrent edge+fill marks.
	-- Three is the measured peak - strobewave's rings arm 0.5s apart and each
	-- lives its arm plus TELL.FLASH plus TELL.FADE, so two are counting down
	-- while a third fades - and every one of them is an inner edge, an outer
	-- edge and the dim interior between them, plus one cylinder for the solid
	-- disc a `mark` draws instead of an annulus. Built once here, placed once
	-- per band, and only ever written for Transparency and Color after that.
	for slot = 1, K.CHOIR_BAND_SLOTS do
		local pool = { inner = {}, outer = {}, fill = {} }
		for i = 1, K.CHOIR_BAND_SEGS do
			pool.inner[i] = makeMarker("ChoirBandInnerEdge", K.NoctyssPath.TELL.LIGHT, true)
			pool.outer[i] = makeMarker("ChoirBandEdge", K.NoctyssPath.TELL.LIGHT, true)
			pool.fill[i] = makeMarker("ChoirBandFill", K.NoctyssPath.TELL.LIGHT, true)
		end
		pool.disc = makeMarker("ChoirMarkFill", K.NoctyssPath.TELL.LIGHT, true)
		pool.disc.Shape = Enum.PartType.Cylinder
		K.choirBandPool[slot] = pool
	end

	staggerRing = makeMarker("StaggerWindow", K.BRINE.window, true)
	staggerRing.Shape = Enum.PartType.Cylinder

	-- Brinejaw's five broadcast attacks: the riptide's wall and the lee it
	-- leaves behind every rock, one flat pool of falling masonry shared by the
	-- bombardment and the surge, the bell's rings, the flood's annulus and its
	-- foam boundary, and the polyps' feed-beams and clocks.
	-- THE RIPTIDE'S RING, and it is the biggest single pool in the file
	-- because it is the fight's centrepiece: 56 crest slabs and their 56 foam
	-- caps, 28 mist banks behind every other one of them, 20 tiles for the
	-- calm water in the mouths and the shadows behind the rocks, and 16 foam
	-- segments marking the two escape corridors from before the sea moves.
	-- 176 parts, all anchored, all query-less, all built once here.
	--
	-- THE CREST IS A SHELL NOW, when the pack is there. Crest1 and Crest2
	-- alternate around the ring (`i % 2`), which is the HANDOFF's own
	-- instruction: they differ in lip curl and belly, and 56 copies of one of
	-- them is the picket fence the ring is trying not to be. Their AUTHORED
	-- height profile comes back to the same value at both ends, so tiling them
	-- leaves no step at any of the 56 seams. Nothing about the sizes, the
	-- bearings or the SAFETY logic in `stepWave` changes - the gap tiles, the
	-- lee tiles and the waveSafe-driven absence of a crest are the mechanic and
	-- are restyled, never re-derived.
	wavePool = { crest = {}, foam = {}, spray = {}, calm = {}, gaps = {} }
	for i = 1, K.WAVE_SEGS do
		wavePool.crest[i] =
			K.fxMarker(if i % 2 == 0 then "Crest1" else "Crest2", "SerpentWaveCrest", K.STORM.wave, true, false)
		-- The foam is NOT Neon: a glowing white cap next to a glowing green
		-- crest is one bright smear at 60 studs, and the cap has to read as
		-- the thing sitting on top of the other thing.
		wavePool.foam[i] = K.fxMarker("Foam", "SerpentWaveFoam", K.STORM.foam, false, false)
	end
	for i = 1, K.WAVE_SPRAY do
		-- Mist stays a box. It has no edges to draw and no silhouette to read;
		-- a mesh here would be geometry spent on the one thing in this drawing
		-- that is deliberately shapeless.
		wavePool.spray[i] = makeMarker("SerpentWaveSpray", K.STORM.foam, false)
	end
	for i = 1, K.WAVE_CALM do
		-- Recoloured per frame between the mouth's pale water and the lee's
		-- near-black - our own part, so colouring it is ours to do. It stays a
		-- part for that reason: a repaint would fight the pack's own colour.
		wavePool.calm[i] = makeMarker("SerpentWaveCalm", K.STORM.calm, false)
	end
	for i = 1, K.WAVE_GAPMARK * 2 do
		-- The gap lanes get the foam roller AND KEEP THEIR GLOW - Neon in both
		-- worlds, unlike the crest. These are the primary safety read of the
		-- whole attack (the two mouths, marked before the sea moves), and
		-- trading their legibility for a nicer material would be paying for
		-- immersion with the thing the player survives by.
		wavePool.gaps[i] = K.fxMarker("Foam", "SerpentWaveGap", K.STORM.foam, true, true)
	end
	for i = 1, K.RAIN_POOL do
		rainPool[i] = {
			marker = makeMarker("SerpentRainMark", K.BRINE.slam, true),
			-- Broken masonry, two chunks alternating by slot. A bombardment
			-- puts up to 14 of these on screen at once and 14 identical
			-- silhouettes is the thing the pack exists to stop.
			rock = K.fxMarker(if i % 2 == 0 then "Rock1" else "Rock2", "SerpentRainChunk", K.BRINE.stone, false, false),
			holder = nil,
		}
		rainPool[i].marker.Shape = Enum.PartType.Cylinder
	end
	for k = 1, K.RING_SLOTS do
		local pool = {}
		for i = 1, K.RING_SEGS do
			pool[i] = makeMarker("SerpentRing", K.STORM.toll, true)
		end
		ringPool[k] = pool
	end
	floodPool = { water = {}, edge = {} }
	for i = 1, K.FLOOD_SEGS do
		-- The risen water is NOT Neon: it is water, and a glowing sea would
		-- outshine the foam line that is the only part of it players must read.
		floodPool.water[i] = makeMarker("SerpentFlood", K.STORM.flood, false)
		floodPool.edge[i] = makeMarker("SerpentFloodEdge", K.STORM.foam, true)
	end
	polypPool = { beams = {}, clocks = {} }
	for i = 1, K.POLYP_MAX do
		polypPool.beams[i] = makeMarker("PolypBeam", K.STORM.polyp, true)
		polypPool.clocks[i] = makeMarker("PolypClock", K.STORM.polyp, true)
		polypPool.clocks[i].Shape = Enum.PartType.Cylinder
	end

	-- The bait glow: one ball per reef stone the slam payload lists, hovering
	-- over the rock rather than recolouring it.
	for i = 1, K.STONE_MAX do
		K.stonePool[i] = makeMarker("SerpentBaitStone", K.STONE_GLOW, true)
		K.stonePool[i].Shape = Enum.PartType.Ball
	end
	-- The shatter's debris. Built ONLY when the pack is imported: see the
	-- section's note - flying cubes would be a downgrade on the particles they
	-- would be joining, and `throwShards` returns early without them anyway,
	-- so ten parked parts would be ten parts that can never move.
	if K.fxHas then
		for i = 1, K.SHARD_POOL do
			local shard =
				K.fxMarker(if i % 2 == 0 then "Rock1" else "Rock2", "SerpentShatterChunk", K.BRINE.stone, false, false)
			K.shardPool[i] = shard
			K.shardSize[i] = shard.Size
		end
	end
	-- THE GEYSERS. A footprint disc and the countdown closing inside it (12 of
	-- each, one set per burst - direct-indexed rather than round-robin,
	-- because the payload's own list is already capped at 12 and a burst's
	-- marker must never be recycled out from under it), plus what comes UP.
	--
	-- POOL ARITHMETIC. The column of water stays, at 12, because without the
	-- pack it is still the whole attack. On top of it:
	--   spikes  12 bursts x 3 variants = 36. Three per SLOT and not three
	--           shared, because the variant is chosen by hashing the burst's
	--           position and two live bursts may hash to the same spike; a
	--           shared triple would have them fight over one part and one of
	--           the two eruptions would silently not draw.
	--   collars 12, one per burst - every spike gets one and no spike gets two.
	-- 12 + 12 + 12 + 36 + 12 = 84 parts, up from 36. Only 12 spikes and 12
	-- collars are ever visible at once (the other 24 variants are parked every
	-- frame by `parkGeySpikes`), so the frame cost is 24 moved parts, not 48.
	--
	-- THEY ARE BUILT IN BOTH WORLDS, pack or no pack, and that is deliberate
	-- waste: 48 invisible fallback blocks against a wave pool of 176 is noise,
	-- while a pool that exists only sometimes puts a `nil` on a path the
	-- Heartbeat walks every frame. This file has already taken the game down
	-- once with a compile error; it is not going to take it down with an index
	-- of nil on the branch nobody plays.
	--
	-- The AUTHORED sizes are cached here because the draw scales each spike by
	-- a per-burst jitter and reads its Size.Y back to bury it. Measuring a part
	-- whose Size the last frame already scaled compounds: the same rock would
	-- shrink or grow every time it erupted.
	K.geyPool = { mark = {}, clock = {}, jet = {}, spike = {}, collar = {}, spikeSize = {} }
	for i = 1, K.GEY_MAX do
		K.geyPool.mark[i] = makeMarker("SerpentGeyserMark", K.SLAM_SAND, true)
		K.geyPool.mark[i].Shape = Enum.PartType.Cylinder
		K.geyPool.clock[i] = makeMarker("SerpentGeyserClock", K.STORM.foam, true)
		K.geyPool.clock[i].Shape = Enum.PartType.Cylinder
		K.geyPool.jet[i] = makeMarker("SerpentGeyserJet", K.STORM.wave, true)
		for v = 1, K.GEY_SPIKE_VARIANTS do
			local index = (i - 1) * K.GEY_SPIKE_VARIANTS + v
			local spike = K.fxMarker("Spike" .. v, "SerpentGeyserSpike", K.BRINE.stone, false, false)
			K.geyPool.spike[index] = spike
			K.geyPool.spikeSize[index] = spike.Size
		end
		K.geyPool.collar[i] = K.fxMarker("SpoutBase", "SerpentGeyserSpout", K.BRINE.stone, false, false)
	end
	K.geyPool.collarSize = K.geyPool.collar[1].Size
	-- The spine volley: one blade per lane and three ground strips ahead of
	-- each, so a full 12-lane volley is 12 + 36 parts and no lane can be
	-- starved of its warning by another lane's. The blade is the pack's barbed
	-- fin when it is there - authored along +X at the bolt's own proportions,
	-- so the lane math below it is untouched.
	K.volleyPool = { bolts = {}, swath = {} }
	for k = 1, K.VOLLEY_LANES do
		K.volleyPool.bolts[k] = K.fxMarker("Spine", "SerpentSpineBolt", K.COLOR.bone, false, false)
		for j = 1, K.VOLLEY_SWATH do
			K.volleyPool.swath[(k - 1) * K.VOLLEY_SWATH + j] = makeMarker("SerpentSpineLane", K.SLAM_SAND, true)
		end
	end
	-- THE COILSLAM'S LINE, and it is ONE-SIDED. The loop is a hairpin down the
	-- aim bearing - `coilslamHits` tests distance along the aim RAY, r 14..62 -
	-- so there is no body on the far side of the tower and never was. The pool
	-- was built for two arms, which is 10 rungs and 1 sliding bar of marker
	-- painted over ground that is safe: a marker over-promising danger, which
	-- costs a player the melee window they were owed.
	--
	-- POOL ARITHMETIC: COIL_RUNGS rungs (10, one per span of the 48-stud band)
	-- and ONE cap, down from 2 * COIL_RUNGS + 2 = 22 parts to 11.
	K.coilPool = { rungs = {}, caps = {} }
	for i = 1, K.COIL_RUNGS do
		K.coilPool.rungs[i] = makeMarker("SerpentCoilLine", K.SLAM_SAND, true)
	end
	K.coilPool.caps[1] = makeMarker("SerpentCoilCap", K.SLAM_SAND, true)

	-- Rimefang's markers. The wash's wall (a crest of slabs on the wedge the
	-- server's own hit test measures, plus the slush apron trailing it), the
	-- cracks a landing leaves in the sheet, the wake that tracks it under the
	-- ice, and the punish window's closing disc.
	for i = 1, K.WASH_SLABS do
		washPool.crest[i] = makeMarker("WashCrest", K.RIME.crest, true)
		washPool.apron[i] = makeMarker("WashSlush", K.RIME.slush, false)
	end
	for i = 1, K.CRACK_SLABS do
		crackPool[i] = makeMarker("FloeCrack", K.RIME.crack, true)
	end
	-- The bite's mouth, the wash's gathering wall and the floequake's lane: a
	-- fan (or a run) of ground slabs each, plus the boundary the player has
	-- to be standing outside of. SKIN.frost for the same reason everything
	-- else in this fight is - a marker on sea ice has to be DARK or it is not
	-- a marker.
	for slot = 1, K.WEDGE_SLOTS do
		local pool = { fan = {}, rim = {} }
		for i = 1, K.WEDGE_SLABS do
			pool.fan[i] = makeMarker("RimeWedge", K.SKIN.frost, true)
			pool.rim[i] = makeMarker("RimeWedgeEdge", K.SKIN.frost, true)
		end
		wedgePool[slot] = pool
	end

	-- THE NEW KIT'S FOUR POOLS: 16 crack-web arms, the lock's disc and its 14
	-- closing ring segments, the falling whale's shadow, and 24 segments of
	-- shockwave front. 56 parts, all anchored, all query-less, all built once
	-- here and only ever moved.
	--
	-- ALL DARK. This fight is fought on white ice and every one of these is a
	-- warning, so they wear the two colours the palette pass already measured
	-- for it: SKIN.frost for ground the player is being asked to leave (4.6:1
	-- against the authored floe, 7.2:1 against the procedural one) and
	-- RIME.mark for "it has picked THIS ground". Never BRINE.window - that
	-- gold means "hit it NOW" in every arena in the game, and is spent forty
	-- studs away in this one on the punish window.
	K.webPool = {}
	for i = 1, K.WEB_ARMS do
		K.webPool[i] = makeMarker("RimeCrackWeb", K.SKIN.frost, false)
	end
	K.lockDisc = makeMarker("RimeLock", K.SKIN.frost, false)
	K.lockDisc.Shape = Enum.PartType.Cylinder
	K.lockArc = {}
	for i = 1, K.LOCK_ARC do
		K.lockArc[i] = makeMarker("RimeLockRing", K.RIME.mark, true)
	end
	-- NOT NEON, and it is the only marker in the fight that must not be: a
	-- glowing shadow is a contradiction, and the whole point of this one is
	-- that a player reads it without being taught.
	K.shadowDisc = makeMarker("RimeShadow", K.SKIN.frost, false)
	K.shadowDisc.Shape = Enum.PartType.Cylinder
	K.shockArc = {}
	for i = 1, K.SHOCK_ARC do
		K.shockArc[i] = makeMarker("RimeShockFront", K.SKIN.frost, true)
	end

	-- PHASE TWO'S TWO POOLS. 26 splits from the arena centre to the rim, and
	-- the four holes the thin ice becomes: a disc of water each and a collar
	-- of broken sheet round it. 26 + 4 + 56 = 86 parts, all anchored, all
	-- query-less, all built once here.
	--
	-- BUILT UNCONDITIONALLY, like every other pool in this file: the holes only
	-- ever appear in the second half of one fight, but a pool that exists only
	-- sometimes puts a nil on a path the Heartbeat walks, and this file has
	-- taken the game down once already for exactly that class of mistake.
	K.shatterPool = {}
	for i = 1, K.SHATTER_ARMS do
		K.shatterPool[i] = makeMarker("RimeShatterCrack", K.SKIN.frost, true)
	end
	K.riftPool = { water = {}, rim = {} }
	for i = 1, K.RIFT_SITES do
		-- NOT NEON, and for the shadow disc's reason: this is a HOLE. The one
		-- thing that must never happen to open water on a white floe is for it
		-- to glow.
		local disc = makeMarker("RimeOpenWater", K.RIME.open, false)
		disc.Shape = Enum.PartType.Cylinder
		K.riftPool.water[i] = disc
		for k = 1, K.RIFT_RIM do
			K.riftPool.rim[(i - 1) * K.RIFT_RIM + k] = makeMarker("RimeRiftCollar", K.RIME.slush, false)
		end
	end
	wakePool = { arms = {}, knuckle = makeMarker("WakeKnuckle", K.RIME.wake, true) }
	for i = 1, K.WAKE_ARMS * 2 do
		wakePool.arms[i] = makeMarker("WakeArm", K.RIME.wake, true)
	end
	wakePool.glow = makeMarker("WakeGlow", K.RIME.glow, true)
	wakePool.glow.Shape = Enum.PartType.Cylinder
	local wakeLight = Instance.new("PointLight")
	wakeLight.Color = K.RIME.glow
	wakeLight.Brightness = 0
	wakeLight.Range = 20
	wakeLight.Enabled = false
	wakeLight.Parent = wakePool.glow
	wakePool.light = wakeLight

	beachedRing = makeMarker("RimeBeachedWindow", K.BRINE.window, true)
	beachedRing.Shape = Enum.PartType.Cylinder

	-- The in-the-blast screen flash.
	local gui = Instance.new("ScreenGui")
	gui.Name = "CreatureFxGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	flashFrame = Instance.new("Frame")
	flashFrame.Name = "Flash"
	flashFrame.Size = UDim2.fromScale(1, 1)
	flashFrame.BackgroundColor3 = Color3.new(1, 1, 1)
	flashFrame.BackgroundTransparency = 1
	flashFrame.BorderSizePixel = 0
	flashFrame.ZIndex = 0
	flashFrame.Parent = gui
	darkFrame = Instance.new("Frame")
	darkFrame.Name = "Dark"
	darkFrame.Size = UDim2.fromScale(1, 1)
	darkFrame.BackgroundColor3 = Color3.fromRGB(2, 2, 4)
	darkFrame.BackgroundTransparency = 1
	darkFrame.BorderSizePixel = 0
	-- Over the flash: when the trench puts the lights out, that is the last
	-- word on what the player can see.
	darkFrame.ZIndex = 2
	darkFrame.Parent = darkFrame.Parent or gui
	-- THE EYE-LOCK VIGNETTE: four edge bars rather than a full-screen wash.
	-- The middle of the screen is where the crosshair and the thing about to
	-- hit you both live, and washing it is the fight telling you to move by
	-- taking away your ability to see where. Built as plain frames because a
	-- radial gradient is not something UIGradient can do and an image asset is
	-- one more import step with nowhere to check it.
	K.vignette = {}
	for i, spec in
		{
			{ UDim2.fromScale(1, K.KRAKEN.VIGNETTE_THICK), UDim2.fromScale(0, 0) },
			{ UDim2.fromScale(1, K.KRAKEN.VIGNETTE_THICK), UDim2.fromScale(0, 1 - K.KRAKEN.VIGNETTE_THICK) },
			{ UDim2.fromScale(K.KRAKEN.VIGNETTE_THICK, 1), UDim2.fromScale(0, 0) },
			{ UDim2.fromScale(K.KRAKEN.VIGNETTE_THICK, 1), UDim2.fromScale(1 - K.KRAKEN.VIGNETTE_THICK, 0) },
		}
	do
		local edge = Instance.new("Frame")
		edge.Name = "KrakenLockEdge" .. i
		edge.Size = spec[1]
		edge.Position = spec[2]
		edge.BackgroundColor3 = K.COLOR.rage
		edge.BackgroundTransparency = 1
		edge.BorderSizePixel = 0
		edge.ZIndex = 3
		edge.Parent = gui
		K.vignette[i] = edge
	end
	K.krakenWire()
	gui.Parent = player:WaitForChild("PlayerGui")
end

function CreatureEventController.start()
	Remotes.CreatureEvent.OnClientEvent:Connect(onCreatureEvent)

	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		stepGlobs(now)
		stepStates(now)
		stepPull(now)
		stepEffects(now)
		K.stepKraken(now)
		stepSweeps(now)
		stepBeams(now)
		K.stepChoirBands(now) -- Noctyss's edge+fill marks, off the one ramp
		stepStagger(now)
		stepBrinejawStorm() -- its own clock: GetServerTimeNow, not os.clock
		stepWash(now)
		stepWedges(now)
		stepWake(now)
		stepBeached(now)
		K.stepRimeKit(now) -- the crack web, the shadow, the lock and the shockwave
	end)

	-- A respawn drops any pull/chill/snare/chain with the old character.
	player.CharacterAdded:Connect(function()
		endPull()
		endChain()
		moveEffect = nil -- the old humanoid is gone; the new one spawns clean
	end)

	task.spawn(function()
		local creatures = Workspace:WaitForChild(K.CREATURES_FOLDER, 30)
		if not creatures then
			warn("[CreatureEvent] no Workspace." .. K.CREATURES_FOLDER .. " folder; enemy effects off")
			return
		end
		creatures.ChildAdded:Connect(watch)
		creatures.ChildRemoved:Connect(unwatch)
		for _, existing in creatures:GetChildren() do
			watch(existing)
		end
	end)
end

return CreatureEventController
