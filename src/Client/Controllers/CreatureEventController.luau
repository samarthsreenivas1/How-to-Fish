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
-- one number: where Rimefang's carousel turns. BossService.arenaPosition
-- spawns a lair boss at BossArenas.centerFor(islandId), updateBoss keeps that
-- point as `creature.anchor`, and `undertow` centres its drag and its falling
-- bergs on the anchor - so this table is the same authority the pull uses,
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

-- Must match CreatureService; server modules aren't requireable here.
local CREATURES_FOLDER = "Creatures"
local ATTR_DASHING = "Dashing"
local ATTR_EXPOSED = "Exposed"
local ATTR_BURIED = "Buried"
local ATTR_OPEN = "Open"
local ATTR_CHARGING = "Charging"
local ATTR_ENRAGED = "Enraged" -- a boss below its enrage threshold

-- ---------------------------------------------------------------- knobs

-- The enemies' accent colours. Kept here rather than in Vfx.Color, which is
-- the water's palette.
local COLOR = {
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
local SKIN = {
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
	ink = Color3.fromRGB(158, 112, 228), -- Noctyss's dark (violet so it reads)
	lure = Color3.fromRGB(255, 214, 120), -- her lantern-gold lights
	ember = Color3.fromRGB(255, 150, 60), -- Wrack's powder and shot
	wreck = Color3.fromRGB(120, 220, 180), -- his verdigris ghost-glow
	storm = Color3.fromRGB(130, 210, 255), -- the Kraken's lightning
}

local function skinColor(extra, fallback: Color3?): Color3
	return SKIN[extra.skin] or fallback or COLOR.brine
end

local GLOB_POOL = 14 -- enough for a boss volley (5) on top of a spine barrage (8)
local GLOB_SIZE = 0.7
local SPINE_SIZE = Vector3.new(0.35, 2.2, 0.35)

-- The boss's lure pull: a force on the local root toward it, as
-- acceleration in studs/s^2 (the server's `strength`), for `duration`.
local PULL_RAMP = 0.25 -- seconds to reach full strength

-- Boss telegraphs / blasts.
local SHAKE_SLAM = math.rad(5)
local SHAKE_RISE = math.rad(4)
local SHAKE_EMERGE_BIG = math.rad(4)
local ENRAGE_FLICKER_INTERVAL = 0.18
local GLOB_RING_INTERVAL = 0.25 -- landing-marker ripple cadence while a glob flies

local DASH_PUFF_INTERVAL = 0.08
local DASH_TRAIL_LIFETIME = 0.25
local EXPOSED_SPARK_INTERVAL = 0.3
local BURIED_PUFF_INTERVAL = 0.12
local BURIED_SOUND_INTERVAL = 0.5
local CRACKLE_INTERVAL = { 0.08, 0.22 }

-- Camera kick (via CombatVfxController) for a blast near the local player,
-- and the full-screen flash for one they're standing inside.
local SHAKE_EXPLODE = math.rad(3)
local SHAKE_PULSE = math.rad(2)
local SHAKE_REACH = 1.6 -- x radius: how far out the kick is still felt
local FLASH_PEAK = 0.55
local FLASH_FADE = 0.35

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

-- Rimefang's four hooks into the shared moments below: the wave wash's crest,
-- the breach's launch splash and its crashes, and its whale-shaped tells.
-- Forward-declared because the handlers that hand off to them are written
-- above the section that defines them (see "Rimefang (the floe boss)").
local startWash, startBreachSplash, rimeSlam, rimeTelegraph

-- ---------------------------------------------------------------- helpers

local function raycastParams(): RaycastParams
	local ignore = {}
	local creatures = Workspace:FindFirstChild(CREATURES_FOLDER)
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
	local reach = radius * SHAKE_REACH
	if d < reach then
		CombatVfxController.kick(angle * (1 - d / reach), 0, duration)
	end
	if localDistance(position) <= radius then
		flashFrame.BackgroundColor3 = flashColor
		flashFrame.BackgroundTransparency = 1 - FLASH_PEAK
		TweenService:Create(flashFrame, TweenInfo.new(FLASH_FADE, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
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
	part.Color = COLOR.acid
	part.Transparency = 1
	part.Size = Vector3.new(GLOB_SIZE, GLOB_SIZE, GLOB_SIZE)
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
	globCursor = globCursor % GLOB_POOL + 1
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
	glob.part.Size = if glob.spine then SPINE_SIZE else Vector3.new(GLOB_SIZE, GLOB_SIZE, GLOB_SIZE)
	glob.part.Color = if glob.spine then COLOR.bone else COLOR.acid
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
end

local function landGlob(glob)
	glob.active = false
	local point, water = surfaceUnder(glob.to)
	if glob.spine then
		-- Stays stuck in the ground for a moment, then sinks away.
		local part = glob.part
		part.CFrame = CFrame.new(point + Vector3.new(0, SPINE_SIZE.Y * 0.35, 0))
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
		Vfx.puff(at, COLOR.acid, 1.0)
		Vfx.ring(at, 0.3, 2.5, 0.4, COLOR.acid)
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
					glob.nextRing = now + GLOB_RING_INTERVAL
					local point = surfaceUnder(glob.to)
					local color = if glob.spine then COLOR.bone else COLOR.acid
					Vfx.ring(point + Vector3.new(0, 0.15, 0), 0.4, 2.0, GLOB_RING_INTERVAL * 1.6, color)
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

local function beginPull(center: Vector3, radius: number, strength: number, duration: number)
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
	local dir = if d > 0.05 then to.Unit else Vector3.zAxis
	local ramp = math.clamp((now - pull.start) / PULL_RAMP, 0, 1)
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
			Vfx.ring(point + Vector3.new(0, 0.15, 0), 1.5, chainState.leash, 0.35, SKIN.wreck)
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
	model:GetAttributeChangedSignal(ATTR_DASHING):Connect(function()
		local dashing = model:GetAttribute(ATTR_DASHING) == true
		if dashing and not entry.trail then
			local body = model.PrimaryPart or model:FindFirstChild("Fish_Body")
			if body and body:IsA("BasePart") then
				entry.trail = Vfx.trail(body, body.Size.Y / 2, Vfx.Color.foam, DASH_TRAIL_LIFETIME)
			end
		end
		if entry.trail then
			entry.trail.Enabled = dashing
		end
		if dashing then
			Sfx.play("dashWhoosh", model:GetPivot().Position)
		end
	end)

	-- Exposed (charger turning): a dazed tell.
	model:GetAttributeChangedSignal(ATTR_EXPOSED):Connect(function()
		if model:GetAttribute(ATTR_EXPOSED) == true then
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
	model:GetAttributeChangedSignal(ATTR_BURIED):Connect(function()
		local buried = model:GetAttribute(ATTR_BURIED) == true
		setHidden(model, buried)
		local at = groundPoint(model)
		if buried then
			Vfx.puff(at, Vfx.Color.sand, 1.5)
			Sfx.play("burrow", at)
		end
	end)
	if model:GetAttribute(ATTR_BURIED) == true then
		setHidden(model, true)
	end

	-- Open (mimic): the pearl glows while it gapes; creak on opening.
	model:GetAttributeChangedSignal(ATTR_OPEN):Connect(function()
		local open = model:GetAttribute(ATTR_OPEN) == true
		setMarksGlow(model, open)
		if open then
			Sfx.play("shellCreak", model:GetPivot().Position)
		end
	end)

	-- Charging (Voltray): the electric organs light up and crackle.
	model:GetAttributeChangedSignal(ATTR_CHARGING):Connect(function()
		setMarksGlow(model, model:GetAttribute(ATTR_CHARGING) == true)
	end)
	if model:GetAttribute(ATTR_CHARGING) == true then
		setMarksGlow(model, true)
	end

	-- Enraged (a boss): its marks (lure, gills) burn and it flickers with
	-- sparks from then on.
	model:GetAttributeChangedSignal(ATTR_ENRAGED):Connect(function()
		setMarksGlow(model, model:GetAttribute(ATTR_ENRAGED) == true)
	end)
	if model:GetAttribute(ATTR_ENRAGED) == true then
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
			if model:GetAttribute(ATTR_DASHING) == true and now >= entry.nextPuffAt then
				entry.nextPuffAt = now + DASH_PUFF_INTERVAL
				Vfx.puff(groundPoint(model), Vfx.Color.sand, 0.5)
			end
			if model:GetAttribute(ATTR_EXPOSED) == true and now >= entry.nextSparkAt then
				entry.nextSparkAt = now + EXPOSED_SPARK_INTERVAL
				Vfx.burst(pivot + Vector3.new(0, 1.2, 0), COLOR.coin, 6)
			end
			if model:GetAttribute(ATTR_BURIED) == true then
				local moved = entry.lastPos == nil or (pivot - entry.lastPos).Magnitude > 0.05
				if moved and now >= entry.nextPuffAt then
					entry.nextPuffAt = now + BURIED_PUFF_INTERVAL
					-- Sand on the beach; a wake of foam when it's the boss under the water.
					local point, water = surfaceUnder(pivot)
					Vfx.puff(
						point + Vector3.new(0, 0.1, 0),
						if water then Vfx.Color.foam else Vfx.Color.sand,
						if water then 1.4 else 0.7
					)
				end
				if moved and now >= entry.nextSoundAt then
					entry.nextSoundAt = now + BURIED_SOUND_INTERVAL
					Sfx.play("sandShift", groundPoint(model))
				end
			end
			if model:GetAttribute(ATTR_CHARGING) == true and now >= entry.nextCrackleAt then
				entry.nextCrackleAt = now + randomBetween(CRACKLE_INTERVAL[1], CRACKLE_INTERVAL[2])
				local jitter = Vector3.new(math.random() - 0.5, 0.3 + math.random() * 0.5, math.random() - 0.5)
				Vfx.burst(pivot + jitter, COLOR.spark, 4)
				Sfx.play("crackle", pivot)
			end
			if model:GetAttribute(ATTR_ENRAGED) == true and now >= entry.nextCrackleAt then
				entry.nextCrackleAt = now + ENRAGE_FLICKER_INTERVAL
				local _, size = model:GetBoundingBox()
				local jitter = Vector3.new(
					(math.random() - 0.5) * size.X,
					math.random() * size.Y * 0.6,
					(math.random() - 0.5) * size.Z
				)
				Vfx.burst(pivot + jitter, COLOR.rage, 5)
			end
			entry.lastPos = pivot
		end
	end
end

-- ---------------------------------------------------------------- moments

local EVENTS = {}

-- The cod's glob leaves its mouth: fly it to `to` over `flight` seconds.
EVENTS.spit = function(position: Vector3, extra)
	if typeof(extra.to) ~= "Vector3" then
		return
	end
	launchGlob(position, extra.to, tonumber(extra.flight) or 0.9, tonumber(extra.arc) or 6, false, extra.boss == true)
end

-- The glob's splash (the server's hit moment; the glob itself lands on the
-- client's own clock, so this is just a wider ring where it counted).
EVENTS.splash = function(position: Vector3, extra)
	-- The `charge` handler fires this the instant Rimefang leaves the water,
	-- which is the only frame-accurate launch cue the breach has. Armed by its
	-- telegraph, so nothing else's splash can be mistaken for it.
	if startBreachSplash(position) then
		return
	end
	local radius = tonumber(extra.radius) or 5
	Vfx.ring(position + Vector3.new(0, 0.15, 0), 1, radius, 0.5, COLOR.acid)
end

-- The urchin goes off.
EVENTS.explode = function(position: Vector3, extra)
	local radius = tonumber(extra.radius) or 10
	Vfx.flash(position, COLOR.ember, 4, 0.15)
	Vfx.shockwave(position, 1, radius, 0.45, COLOR.ember, 0.25)
	Vfx.burst(position, COLOR.ember, 40)
	Vfx.puff(position, COLOR.smoke, 2.5)
	local point, water = surfaceUnder(position)
	if water then
		Vfx.ring(point + Vector3.new(0, 0.2, 0), 1, radius, 0.6)
	end
	Sfx.play("explodeCrack", position)
	task.delay(0.06, function()
		Sfx.play("explodeBoom", position)
	end)
	feelBlast(position, radius, SHAKE_EXPLODE, 0.35, Color3.fromRGB(255, 220, 180))
end

-- The lurker bursts up out of the sand.
EVENTS.emerge = function(position: Vector3, extra)
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
		feelBlast(at, radius, SHAKE_EMERGE_BIG, 0.4, Color3.fromRGB(220, 240, 255))
	end
end

-- The mimic's bite.
EVENTS.snap = function(position: Vector3)
	Vfx.flash(position, Vfx.Color.foam, 1.5, 0.1)
	Vfx.puff(position, COLOR.pearl, 1.2)
	Sfx.play("shellSnap", position)
	task.delay(0.04, function()
		Sfx.play("hitThump", position)
	end)
end

-- The hermit pickpockets someone; the victim gets a "-N coins" pop.
EVENTS.steal = function(position: Vector3, extra)
	Vfx.burst(position + Vector3.new(0, 0.8, 0), COLOR.coin, 18)
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
EVENTS.pulse = function(position: Vector3, extra)
	local radius = tonumber(extra.radius) or 12
	Vfx.flash(position, COLOR.spark, 3, 0.12)
	Vfx.shockwave(position, 0.8, radius, 0.35, COLOR.spark, 0.2)
	Vfx.burst(position, COLOR.spark, 30)
	local point, water = surfaceUnder(position)
	if water then
		Vfx.ring(point + Vector3.new(0, 0.2, 0), 1, radius, 0.5)
	end
	Sfx.play("pulseZap", position)
	task.delay(0.05, function()
		Sfx.play("pulseThump", position)
	end)
	feelBlast(position, radius, SHAKE_PULSE, 0.25, Color3.fromRGB(200, 245, 255))
end

-- ---------------------------------------------------------------- boss moments

-- The boss rises out of the deep: a huge upwelling, the water heaving.
EVENTS.bossRise = function(position: Vector3, extra)
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
		feelBlast(at, 60, SHAKE_RISE, 0.6, Color3.fromRGB(180, 230, 220))
	end)
end

-- The tell before an attack: a coloured flash at the boss and, for the
-- ringed ones, the ring on the ground it's about to hit.
EVENTS.telegraph = function(position: Vector3, extra)
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
	if kind == "slam" and radius then
		local point = surfaceUnder(position)
		local pulses = math.max(1, math.floor(duration / 0.3))
		for i = 0, pulses - 1 do
			task.delay(i * 0.3, function()
				Vfx.ring(point + Vector3.new(0, 0.15, 0), radius * 0.9, radius, 0.3, COLOR.ember)
			end)
		end
		Vfx.flash(position + Vector3.new(0, 2, 0), COLOR.ember, 4, duration)
	elseif kind == "tail" and radius then
		-- The lash's reach, pulsing: get outside it.
		local point = surfaceUnder(position)
		local pulses = math.max(1, math.floor(duration / 0.3))
		for i = 0, pulses - 1 do
			task.delay(i * 0.3, function()
				Vfx.ring(point + Vector3.new(0, 0.15, 0), radius * 0.85, radius, 0.3, COLOR.ember)
			end)
		end
		Vfx.flash(position, COLOR.ember, 3, duration)
	elseif kind == "burst" and radius then
		-- The dive has locked under someone's feet: a fast-pulsing ring on
		-- the surface there for the lock window, then it bursts.
		local point = surfaceUnder(position)
		local pulses = math.max(1, math.floor(duration / 0.18))
		for i = 0, pulses - 1 do
			task.delay(i * 0.18, function()
				Vfx.ring(point + Vector3.new(0, 0.15, 0), radius * 0.3, radius, 0.2, COLOR.brine)
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
		local pulses = math.max(1, math.floor(duration / 0.25))
		for i = 0, pulses - 1 do
			task.delay(i * 0.25, function()
				Vfx.ring(point + Vector3.new(0, 0.15, 0), inner, radius, 0.28, color)
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
EVENTS.bossSnap = function(position: Vector3)
	Vfx.flash(position, Vfx.Color.foam, 4, 0.12)
	Vfx.puff(position, Vfx.Color.foam, 3)
	Vfx.burst(position, COLOR.brine, 20)
	Sfx.play("bossSnap", position)
end

-- The tail lash: a ring that sweeps out round the boss.
EVENTS.sweep = function(position: Vector3, extra)
	local radius = tonumber(extra.radius) or 16
	local point = surfaceUnder(position)
	Vfx.shockwave(point + Vector3.new(0, 0.5, 0), 3, radius, 0.4, Vfx.Color.foam, 0.6)
	Vfx.ring(point + Vector3.new(0, 0.2, 0), 3, radius, 0.5)
	Vfx.burst(position, Vfx.Color.foam, 30)
	Sfx.play("bossSweep", position)
	feelBlast(position, radius, SHAKE_PULSE, 0.25, Color3.fromRGB(220, 240, 255))
end

-- The tidal slam: the big one.
EVENTS.slam = function(position: Vector3, extra)
	-- A whale landing flat on sea ice is not a tidal slam: it BREAKS THE
	-- SHEET, and the cracks stay for the window it opens.
	if rimeSlam(position, extra) then
		return
	end
	local radius = tonumber(extra.radius) or 20
	local point = surfaceUnder(position)
	Vfx.flash(position, COLOR.ember, 6, 0.15)
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
	feelBlast(position, radius, SHAKE_SLAM, 0.5, Color3.fromRGB(220, 235, 255))
end

-- The lure pull: drag the local character toward the maw for `duration`.
EVENTS.pull = function(position: Vector3, extra)
	local radius = tonumber(extra.radius) or 40
	local strength = tonumber(extra.strength) or 25
	local duration = tonumber(extra.duration) or 2
	if localDistance(position) <= radius then
		beginPull(position, radius, strength, duration)
	end
	Vfx.shockwave(position + Vector3.new(0, 3, 0), radius, 2, duration, COLOR.brine, 0.35)
	Sfx.play("pulseZap", position)
end

-- A spine leaves the boss: fly it (a bone sliver) to `to`.
EVENTS.spine = function(position: Vector3, extra)
	if typeof(extra.to) ~= "Vector3" then
		return
	end
	launchGlob(position, extra.to, tonumber(extra.flight) or 0.8, tonumber(extra.arc) or 10, true, true)
end

-- Where a spine counted (the glob itself lands on the client's clock).
EVENTS.spineHit = function(position: Vector3, extra)
	local radius = tonumber(extra.radius) or 4
	Vfx.ring(position + Vector3.new(0, 0.15, 0), 1, radius, 0.4, COLOR.bone)
end

-- It coughs up brood.
EVENTS.summon = function(position: Vector3)
	Vfx.puff(position, COLOR.brine, 2.5)
	Vfx.burst(position, COLOR.brine, 24)
	Vfx.splash(position, 1.5)
	Sfx.play("emerge", position)
end

-- It goes under for the ambush.
EVENTS.bossDive = function(position: Vector3)
	local at = Vector3.new(position.X, World.WATER_Y + 0.2, position.Z)
	Vfx.splash(at, 4)
	Vfx.ring(at, 3, 14, 0.8)
	Sfx.play("burrow", at)
end

-- Below its enrage threshold.
EVENTS.enrage = function(position: Vector3)
	Vfx.flash(position + Vector3.new(0, 2, 0), COLOR.rage, 8, 0.4)
	Vfx.burst(position + Vector3.new(0, 2, 0), COLOR.rage, 60)
	Sfx.play("bossRoar", position)
	feelBlast(position, 60, SHAKE_RISE, 0.5, Color3.fromRGB(255, 120, 100))
end

-- Dead. (BossHudController shows the banner.)
EVENTS.bossDown = function(position: Vector3)
	local at = Vector3.new(position.X, World.WATER_Y + 0.2, position.Z)
	Vfx.flash(at + Vector3.new(0, 3, 0), COLOR.brine, 10, 0.5)
	Vfx.burst(at + Vector3.new(0, 2, 0), COLOR.brine, 80)
	Vfx.ring(at, 4, 30, 1.2)
	for i = 1, 5 do
		task.delay(i * 0.12, function()
			Vfx.splash(at + Vector3.new((math.random() - 0.5) * 12, 0, (math.random() - 0.5) * 12), 3)
		end)
	end
	Sfx.play("bossDown", at)
	feelBlast(at, 80, SHAKE_SLAM, 0.7, Color3.fromRGB(200, 255, 235))
end

-- The Kraken's exposure window opens: the last tentacle is down and the
-- head can be hurt (BossHudController shows the card).
EVENTS.exposed = function(position: Vector3)
	local at = position + Vector3.new(0, 3, 0)
	Vfx.flash(at, Color3.fromRGB(255, 210, 110), 9, 0.5)
	Vfx.burst(at, Color3.fromRGB(255, 210, 110), 50)
	Sfx.play("bossRoar", position)
end

-- A displacement shove (the kit engine's gustpush): the pull machinery run
-- in reverse - the local character is blown OUT of the radius. `cone` gusts
-- only move you when you stand inside the wedge.
EVENTS.gust = function(position: Vector3, extra)
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
	-- Rimefang's wash names the players its arena sheltered (the server owns
	-- that call - it raycasts the bergs and the wreck): cover has to stop the
	-- SHOVE, not merely the damage, or the furniture is decoration.
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
EVENTS.gasPuff = function(position: Vector3, extra)
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
EVENTS.crustCrack = function(position: Vector3)
	Vfx.burst(position + Vector3.new(0, 2, 0), Color3.fromRGB(60, 62, 74), 40)
	Vfx.flash(position + Vector3.new(0, 2, 0), Color3.fromRGB(255, 120, 40), 5, 0.3)
	Sfx.play("hitCrack", position)
end

-- The Phoenix (and any reborn) getting back up: an ember pillar.
EVENTS.rebornRise = function(position: Vector3)
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
EVENTS.poolSpawn = function(position: Vector3, extra)
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
EVENTS.strikeHit = function(position: Vector3, extra)
	local radius = tonumber(extra.radius) or 6
	local color = skinColor(extra)
	Vfx.flash(position + Vector3.new(0, 1, 0), color, 4, 0.14)
	Vfx.ring(position + Vector3.new(0, 0.2, 0), 1, radius, 0.4, color)
	Vfx.burst(position + Vector3.new(0, 0.5, 0), color, 22)
	Sfx.play("bossGlobThud", position)
	feelBlast(position, radius, SHAKE_PULSE, 0.25, color)
end

-- Noctyss's ink shell: the strike, plus a blot of dark across the screen of
-- anyone caught inside it.
EVENTS.inkBlast = function(position: Vector3, extra)
	local radius = tonumber(extra.radius) or 8
	EVENTS.strikeHit(position, extra)
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
EVENTS.chill = function(position: Vector3, extra)
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
EVENTS.snare = function(position: Vector3, extra)
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
		feelBlast(position, radius, SHAKE_PULSE, 0.2, color)
	end
end

-- Wrack's anchor chain: leash yourself to the anchor if it caught you.
EVENTS.chain = function(position: Vector3, extra)
	local radius = tonumber(extra.radius) or 10
	local leash = tonumber(extra.leash) or 13
	local duration = tonumber(extra.duration) or 3.5
	local point = surfaceUnder(position)
	Vfx.burst(point + Vector3.new(0, 0.5, 0), SKIN.wreck, 30)
	Vfx.ring(point + Vector3.new(0, 0.2, 0), 1.5, leash, 0.6, SKIN.wreck)
	Sfx.play("bossGlobThud", position)
	if localDistance(position) <= radius then
		chainState = {
			center = position,
			leash = leash,
			until_ = os.clock() + duration,
			nextRingAt = 0,
		}
		feelBlast(position, radius, SHAKE_PULSE, 0.3, SKIN.wreck)
	end
end

-- A decoy lure / powder keg surfaces.
EVENTS.decoy = function(position: Vector3, extra)
	local color = skinColor(extra, SKIN.lure)
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
EVENTS.decoyMove = function(position: Vector3)
	local _, part = nearestDecoy(position, 7)
	if part then
		TweenService:Create(part, TweenInfo.new(0.32, Enum.EasingStyle.Linear), {
			CFrame = CFrame.new(position),
		}):Play()
	end
end

-- ...and detonates (or fizzles out at the end of its fuse).
EVENTS.decoyPop = function(position: Vector3, extra)
	local idx, part = nearestDecoy(position, 9)
	if idx and part then
		table.remove(decoyParts, idx)
		part:Destroy()
	end
	local color = skinColor(extra, SKIN.lure)
	if extra.fizzle then
		Vfx.puff(position, color, 1.4)
		return
	end
	local radius = tonumber(extra.radius) or 10
	Vfx.flash(position, color, 6, 0.15)
	Vfx.shockwave(position, 1.5, radius, 0.45, color, 0.6)
	Vfx.burst(position, color, 36)
	Sfx.play("explodeBoom", position)
	feelBlast(position, radius, SHAKE_EXPLODE, 0.35, color)
end

-- One tick of a swept jet (magma / frost breath): the burning line itself.
EVENTS.beam = function(position: Vector3, extra)
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
EVENTS.phantomOut = function(position: Vector3, extra)
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
EVENTS.phantomIn = function(position: Vector3, extra)
	local radius = tonumber(extra.radius) or 15
	local at = Vector3.new(position.X, World.WATER_Y + 0.2, position.Z)
	Vfx.splash(at, 3)
	Vfx.ring(at, 2, radius * 0.7, 0.5)
	Vfx.burst(position + Vector3.new(0, 1, 0), skinColor(extra), 30)
	Sfx.play("emerge", position)
	feelBlast(position, radius, SHAKE_EMERGE_BIG, 0.3, Color3.fromRGB(120, 80, 180))
end

-- ...and closes: the tentacle ring re-plants around the arena.
EVENTS.regrow = function(position: Vector3, extra)
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

local BRINE = {
	low = Color3.fromRGB(255, 96, 62), -- a wall on the sand: JUMP IT
	high = Color3.fromRGB(120, 236, 255), -- a rail overhead: STAND STILL
	shadow = Color3.fromRGB(26, 32, 40), -- what a high arm casts on the sand
	bait = Color3.fromRGB(255, 214, 110), -- a slam baited onto a stone: YES
	slam = Color3.fromRGB(255, 122, 60), -- ...and one about to waste itself
	window = Color3.fromRGB(255, 214, 110), -- the stagger: hit it, now
	stone = Color3.fromRGB(150, 146, 136), -- reef rock and tower masonry
}

-- Draw ranges. The arena is huge and these fire every few seconds, so each
-- handler is skipped outright past its own reach plus a margin.
local BRINE_MARGIN = 90 -- how far outside an effect's own footprint it still draws
local BRINE_CULL = 240 -- the flat range for the whole-arena moments

-- The swept marker: rungs laid along the band from `inner` to `reach`, the
-- whole ladder swinging round the tower like the hand it is.
local SWEEP_SLOTS = 2 -- constrict chases a slow high sweep with a fast low one
local SWEEP_RUNGS = 16
local SWEEP_LEAD = 0.5 -- seconds the marker runs AHEAD of the arm
local SWEEP_GIRTH = 3.4 -- fallback half-thickness if a row sends none
local SWEEP_LOW_TOP = 3.2 -- a low wall stands this far above the arm's line
-- A HIGH RAIL IS DRAWN AT ITS TRUE THICKNESS. It used to be 1.4 studs -
-- deliberately slim, so the shape alone said "this one passes overhead" - but
-- the band that actually hurts you is `girth * 2`, which is 7.2. That is 2.9
-- studs of invisible hazard above the rail and 2.9 below it, and at the top of
-- a jump a player's root sits exactly in that margin: you watch yourself clear
-- the rail by a hair and take the hit anyway. The read survives the honest
-- thickness, because what sells "stand still" is the clear air underneath it
-- rather than how thin the rail is.
local SWEEP_SHADOW_THICK = 0.1
local SWEEP_FADE = 0.3 -- how long the marker takes to leave once the arm is done
local SWEEP_DUST_INTERVAL = 0.07 -- sand thrown by a low arm ploughing through it
local SWEEP_PULSE = 11 -- rad/s of the marker's urgency throb

-- The punish window: a disc of the payoff colour under the slumped head that
-- closes as the window does, so the time left is readable without any HUD.
local STAGGER_RADIUS = 13
local STAGGER_BLOOM_INTERVAL = 0.55

-- Pooled marker parts live down here when idle - the glob pool's pattern:
-- built in init, moved in Heartbeat, never churned.
local PARKED = CFrame.new(0, -5000, 0)

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
	part.CFrame = PARKED
	part.Parent = folder
	return part
end

local function parkParts(parts: { Part })
	for _, part in parts do
		part.Transparency = 1
		part.CFrame = PARKED
	end
end

-- Brinejaw's arena is anchored on the TOWER'S FOOT, not on wherever the head
-- has got to: the sweep carries it in every payload, and every colossus
-- publishes it as PoseCenter (the same attribute BrinejawBodyController reads
-- to know where to stand the body). Falls back to straight down from the boss.
local function towerFoot(position: Vector3): Vector3
	local creatures = Workspace:FindFirstChild(CREATURES_FOLDER)
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
	if elapsed > total + SWEEP_FADE then
		return false
	end
	local fade = math.clamp((elapsed - total) / SWEEP_FADE, 0, 1)
	local u = math.clamp((elapsed - s.windup + SWEEP_LEAD) / s.travel, 0, 1)
	local theta = s.angle + s.arc * u
	local cos, sin = math.cos(theta), math.sin(theta)
	-- The rungs point along the bearing: +X of a CFrame turned -theta about Y
	-- is (cos, 0, sin), which is the convention the server's hit test uses.
	local facing = CFrame.Angles(0, -theta, 0)
	local span = (s.reach - s.inner) / SWEEP_RUNGS
	local length = span * 0.84
	local pulse = 0.5 + 0.5 * math.sin(now * SWEEP_PULSE)
	local base = (if s.high then 0.1 else 0.2) + 0.16 * pulse
	local alpha = base + (1 - base) * fade
	local tall = s.height + SWEEP_LOW_TOP
	local band = s.girth * 2

	for i = 1, SWEEP_RUNGS do
		local r = s.inner + span * (i - 0.5)
		local ground = s.center.Y + BrinejawPath.sandY(r)
		local x, z = s.center.X + cos * r, s.center.Z + sin * r
		local rung = pool.rungs[i]
		if s.high then
			-- A rail at the arm's own height, and clear air all the way down.
			rung.Size = Vector3.new(length, band, band)
			rung.CFrame = CFrame.new(x, ground + s.height, z) * facing
			local shade = pool.shadows[i]
			shade.Size = Vector3.new(length, SWEEP_SHADOW_THICK, band * 0.9)
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
		s.nextDustAt = now + SWEEP_DUST_INTERVAL
		for _ = 1, 2 do
			local r = randomBetween(s.inner, s.reach)
			local at = Vector3.new(s.center.X + cos * r, s.center.Y + BrinejawPath.sandY(r) + 0.2, s.center.Z + sin * r)
			Vfx.puff(at, Vfx.Color.sand, 1.1)
		end
	end
	return true
end

local function stepSweeps(now: number)
	for slot = 1, SWEEP_SLOTS do
		local s = sweeps[slot]
		if s and not drawSweep(s, sweepPool[slot], now) then
			sweeps[slot] = nil
			parkParts(sweepPool[slot].rungs)
			parkParts(sweepPool[slot].shadows)
		end
	end
end

-- THE tell. The tail unwinds off the tower and scythes round the arena like a
-- clock hand: this draws where it is about to be, all the way across the band,
-- and says which of the two answers it wants.
EVENTS.serpentSweep = function(position: Vector3, extra)
	-- Two clocks, not one: `windup` is the hold on the start bearing, and
	-- `travel` is the arc itself. Only the second is when the arm moves.
	local windup = math.clamp(tonumber(extra.windup) or 0, 0, 12)
	local travel = math.clamp(tonumber(extra.duration) or 2.4, 0.2, 12)
	local inner = math.max(tonumber(extra.inner) or BrinejawPath.SWEEP_INNER, 0)
	local reach = math.max(tonumber(extra.reach) or BrinejawPath.SWEEP_REACH, inner + 4)
	if not nearCamera(position, reach + BRINE_MARGIN) then
		return
	end
	local high = extra.high == true
	local girth = math.clamp(tonumber(extra.girth) or SWEEP_GIRTH, 0.5, 12)
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
	for i = 1, SWEEP_SLOTS do
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
		rung.Color = if high then BRINE.high else BRINE.low
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
EVENTS.serpentSlam = function(position: Vector3, extra)
	local radius = tonumber(extra.radius) or 13
	if not nearCamera(position, radius + BRINE_MARGIN) then
		return
	end
	local duration = math.clamp(tonumber(extra.duration) or 1.9, 0.2, 8)
	local baited = extra.stoneNear == true
	local color = if baited then BRINE.bait else BRINE.slam
	local point = surfaceUnder(position) + Vector3.new(0, 0.15, 0)

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
end

-- ------------------------------------------------------------ the window

local function closeStagger()
	staggerRing.Transparency = 1
	staggerRing.CFrame = PARKED
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
	local r = STAGGER_RADIUS * (0.16 + 0.84 * u)
	staggerRing.Size = Vector3.new(0.14, r * 2, r * 2)
	staggerRing.CFrame = stagger.frame
	local rate = 2.4 + 7 * (1 - u)
	staggerRing.Transparency = 0.5 + 0.28 * (0.5 + 0.5 * math.sin(now * rate * math.pi * 2))
	if now >= stagger.nextBloomAt then
		stagger.nextBloomAt = now + STAGGER_BLOOM_INTERVAL
		Vfx.burst(stagger.head, BRINE.window, 14)
	end
end

-- THE payoff. The serpent has lost its grip: the head comes off the tower
-- onto the sand and can be hurt for `duration`. Weight first - the camera
-- takes it, the sand goes up - then the window's own clock stays lit under
-- the head until it shuts.
EVENTS.bossStagger = function(position: Vector3, extra)
	if not nearCamera(position, BRINE_CULL) then
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
	Vfx.flash(position + Vector3.new(0, 2, 0), BRINE.window, 7, 0.45)
	feelBlast(position, 28, SHAKE_SLAM, 0.6, Color3.fromRGB(255, 226, 170))

	local now = os.clock()
	stagger = {
		frame = CFrame.new(point) * CFrame.Angles(0, 0, math.rad(90)),
		head = position + Vector3.new(0, 2, 0),
		duration = duration,
		until_ = now + duration,
		nextBloomAt = now + STAGGER_BLOOM_INTERVAL,
	}
end

-- ------------------------------------------------------------ the tower

-- The stack has slid one turn down the spire. Nothing about the boss says so
-- from a distance, so the TOWER says it: masonry dust walking down the drums,
-- grit landing at the foot, and the ground moving under everyone.
EVENTS.bossStance = function(position: Vector3, extra)
	if not nearCamera(position, BRINE_CULL) then
		return
	end
	local stance = tonumber(extra.stance) or BrinejawPath.MAX_COIL
	-- Each coil it has already lost grinds the next one harder.
	local weight = 1 + 0.35 * math.max(BrinejawPath.MAX_COIL - stance, 0)
	local foot = towerFoot(position)

	Sfx.play("bossStance", foot)
	feelBlast(foot, 46, SHAKE_RISE * weight, 0.9, Color3.fromRGB(214, 204, 188))

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
				Vfx.puff(at, BRINE.stone, 1.8 * weight)
				Vfx.burst(at, BRINE.stone, 10)
			end
		end)
	end

	-- ...and it all lands.
	task.delay(steps * 0.11 + 0.1, function()
		local base = foot + Vector3.new(0, BrinejawPath.sandY(0) + 0.15, 0)
		Vfx.puff(base, BRINE.stone, 4 * weight)
		Vfx.ring(base, 5, 22 * weight, 0.75, BRINE.stone)
		Sfx.play("bossSlam", foot)
		feelBlast(foot, 44, SHAKE_SLAM * weight, 0.65, Color3.fromRGB(214, 204, 188))
	end)
end

-- A reef stone cracked open by the tail. `extra.index` says which of the
-- three it was; nothing about the burst depends on that, only on the fact
-- that one of the party's three answers has just been spent.
EVENTS.reefShatter = function(position: Vector3)
	if not nearCamera(position, BRINE_CULL) then
		return
	end
	local point = surfaceUnder(position) + Vector3.new(0, 0.15, 0)
	Vfx.burst(point + Vector3.new(0, 1.5, 0), BRINE.stone, 46)
	Vfx.puff(point + Vector3.new(0, 0.8, 0), BRINE.stone, 3)
	Vfx.shockwave(point + Vector3.new(0, 0.3, 0), 1, 10, 0.35, BRINE.stone, 0.35)
	Vfx.ring(point, 1.5, 13, 0.5, BRINE.stone)
	Sfx.play("reefShatter", position)
	task.delay(0.05, function()
		Sfx.play("hitCrack", position)
	end)
	feelBlast(position, 15, SHAKE_EXPLODE, 0.3, Color3.fromRGB(232, 226, 212))
	-- The stump goes under, and the sand closes over it.
	task.delay(0.35, function()
		Vfx.puff(point, Vfx.Color.sand, 2.4)
	end)
end

-- The death slide: it lets go of the spire for the last time and comes down
-- the whole height of it. (Defensive - the server may or may not send this;
-- a handler that never fires costs nothing, a silent death costs the fight.)
EVENTS.bossCollapse = function(position: Vector3, extra)
	if not nearCamera(position, BRINE_CULL) then
		return
	end
	local duration = math.clamp(tonumber(extra.duration) or 4, 0.5, 20)
	local foot = towerFoot(position)
	local ground = foot + Vector3.new(0, BrinejawPath.sandY(0) + 0.15, 0)
	closeStagger() -- whatever window was open, it is over

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
			Vfx.puff(at, BRINE.stone, 2.6)
			Vfx.burst(at, COLOR.brine, 16)
			if i % 3 == 0 then
				Sfx.play("bossSpineHit", at)
			end
		end)
	end

	-- ...and it hits the sand.
	task.delay(duration, function()
		Vfx.flash(ground + Vector3.new(0, 3, 0), COLOR.brine, 10, 0.5)
		Vfx.puff(ground, Vfx.Color.sand, 7)
		Vfx.burst(ground, Vfx.Color.sand, 80)
		Vfx.shockwave(ground + Vector3.new(0, 0.4, 0), 3, 40, 0.9, Vfx.Color.sand, 0.9)
		Vfx.ring(ground, 4, 46, 1.2, BRINE.stone)
		Sfx.play("bossSlam", ground)
		feelBlast(ground, 60, SHAKE_SLAM, 0.8, Color3.fromRGB(240, 226, 200))
	end)
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
local RIME = {
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
}
-- The punish window is BRINE.window on purpose: one colour means "hit it now"
-- across every boss in the game, and a player only learns that once.

local RIME_ID = "rimefang" -- Bosses.luau rimefang.creature, the row id on the model
local ATTR_CREATURE_ID = "CreatureId" -- CreatureService's ATTR_ID
local ATTR_SUBMERGE = "Submerge" -- 0..1 under the sheet (RimefangBodyController's pose)
local BOSS_ARENA_FOLDER = "BossArenas" -- BossArenaService.FOLDER_NAME: the furniture that is cover
local RIME_CULL = 240 -- flat draw range for the arena-wide moments
local RIME_MARGIN = 70 -- how far outside its own footprint an effect still draws

-- Which move a borrowed tell belongs to, by its radius (Bosses.luau,
-- rimefang.attacks). The tolerance is deliberately tighter than the gap to
-- the nearest neighbour on the list AND to the ice hostiles' r6 marks.
local RIME_TELL = {
	bite = 17, -- "snap": the jaws, and the only move that is always coming
	spyhop = 7, -- "mark": it stands up and picks someone
	whiteout = 9, -- "mark": the storm closes
	breach = 15, -- "burst": it is leaving the sheet, to land 46 studs on
	flukeslam = 24, -- "burst": the tail comes up through a hole and hammers
	carousel = 30, -- "ringTell": the current starts to turn
	wash = 34, -- "gustTell": the wall of slush
}
local RIME_TELL_TOL = 0.75

-- WHOSE MOMENT IS THIS. A radius is not evidence: Old Ribbonjaw prowls the
-- same island frost-skinned, and both `ribbonlash` and `vanish` carry r7 -
-- the spy-hop's number, inside the tolerance above. Matching on skin and a
-- number therefore stole a thief's tells and drew a whale's. The ANIMAL is
-- the evidence, so every whale-shaped draw asks rimeOwns() first, and an ice
-- hostile falls straight back through to the stock telegraph it always had.
-- The range is its own aggro (90) with room to spare, and eight THOUSAND
-- studs short of the ice island the hostiles live on (BossArenas.items.ice).
local RIME_ARENA = 200
local RIME_ISLAND = "ice" -- Bosses.luau rimefang.islandId
-- How far the shared arena row may sit from a payload before the client stops
-- believing it describes this fight (the roam disc, 28, with margin).
local RIME_ANCHOR_TRUST = 120

-- The live pose the whale is actually in, published every frame by
-- CreatureService's rimefangDrive.
local RF_ATTR_FACE = "FaceAngle" -- = creature.yaw0, which bossFacing() reads

-- THE BITE, from Bosses.luau rimefang.attacks.bite - and none of it except
-- `radius` is in the telegraph payload, because the stock tell sends only
-- kind/duration/radius/facing/skin. See the REPORT.
--   radius 17, cone rad(65)   a 130-degree mouth
--   lunge 14 over a 0.35s strike, and ATTACK_HANDLERS.snap fires at u >= 0.4
-- So the jaws close 0.14s AFTER the tell's own clock has run out, from a
-- point 5.6 studs further forward than the tell began at: the ground that
-- will be bitten reaches 22.6 studs from where the boss stands at the start
-- of the windup, closing to the bare 17 at the moment of the bite.
local BITE_CONE = math.rad(65)
local BITE_RADIUS = 17
local BITE_LUNGE = 14
local BITE_STRIKE = 0.35
local BITE_LEAD = BITE_STRIKE * 0.4 -- strike time before the jaws close

-- ONE MARKER FOR THE TWO CONES: the bite's mouth and the wash's gathering
-- wall. Both make the same claim - "this ground, out to here, inside this
-- angle, is about to be hit" - and both are drawn from the boss's LIVE
-- bearing rather than the one latched into the payload, because updateBoss
-- keeps turning the animal through the whole windup (turnRate * 1.5, up to
-- 84 degrees across the bite's 0.7s) and its cone tests read the live one.
-- ...and one shape that is not a cone at all but wants every other line of
-- this machinery: the breach's CORRIDOR. `charge` no longer rings the head -
-- `bodyContact` walks all nine spine nodes and each one ploughs the floe
-- within `width` of itself, so what the leap damages is the lane the animal
-- travels, 46 studs of it, and the marker has to be that lane.
local WEDGE_BITE = 1
local WEDGE_WASH = 2
local WEDGE_BREACH = 3
local WEDGE_SLOTS = 3
local WEDGE_SLABS = 9 -- the fan; nine boxes close the 130-degree arc exactly
local WEDGE_RIM_THICK = 1.1 -- the boundary arc: the line to be standing outside
local WEDGE_FADE = 0.18

local BREACH_LENGTH = 46 -- Bosses.luau rimefang.breach.length, for the runway
local BREACH_WIDTH = 11 -- rimefang.breach.width: bodyContact's reach off each node
local BREACH_TRAVEL = 1.0 -- rimefang.breach.duration: how long the lane is being ploughed
local BEACHED_WINDOW = 4.0 -- rimefang.breach.expose: how long the ice holds it
local BEACHED_RADIUS = 15
local BEACHED_THRASH_GAP = 1.05 -- ~4 thrashes across the window, not a loop

-- The wall. Slabs laid along the wedge the server's own hit test uses
-- (inside `radius`, inside `cone` of `facing`), marching out from the boss:
-- what you see arrive is what counted.
local WASH_SLABS = 16
local WASH_INNER = 7 -- born at the whale's shoulder, not at its pivot
local WASH_HEIGHT = 6.2 -- OVER eye height: a wall you cannot see past is the read
local WASH_THICK = 2.4
local WASH_APRON_LAG = 5.5 -- the churned slush trailing the crest
local WASH_CONE = math.rad(70) -- rimefang.wash.cone, if a payload ever omits it
local WASH_FADE = 0.3
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
local WASH_SWEEP = 0.22
local WASH_SPRAY_GAP = 0.07

-- The sheet it breaks: cracks radiating from a crash, which stay put for the
-- punish window because broken ice does not heal in four seconds.
local CRACK_SLABS = 16
local CRACK_HOLD = 3.2
local CRACK_FADE = 1.4

-- The wake: a knuckle over the head and two arms splaying back off it.
local WAKE_ARMS = 6 -- per side
local WAKE_SPLAY = math.rad(27)
local WAKE_STEP = 3.4 -- distance between one arm slab and the next
local WAKE_SPRAY_GAP = 0.4
local WAKE_SPOUT_AT = 0.35 -- Submerge below this and it is breaking the surface

local wash: any = nil
local washPool = { crest = {}, apron = {} }
local wedges: { any } = {}
local wedgePool: { any } = {}
local crackPool: { Part } = {}
local wakePool: any = nil
local wake: any = nil
local beached: any = nil
local beachedRing: Part
-- The breach's launch: armed by its telegraph so the stock `splash` the
-- charge handler fires at that instant can be recognised (see EVENTS.splash).
local breachArm: { at: Vector3, until_: number }? = nil

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
		for _, name in { CREATURES_FOLDER, "RimefangBody", "ClientVfx" } do
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
		if candidate.Parent and candidate:GetAttribute(ATTR_CREATURE_ID) == RIME_ID then
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

-- Which of its moves a borrowed tell is, or nil.
local function rimeMove(radius: number?): string?
	if not radius then
		return nil
	end
	for name, r in RIME_TELL do
		if math.abs(radius - r) <= RIME_TELL_TOL then
			return name
		end
	end
	return nil
end

-- Is this Rimefang's moment at all? The identity gate every whale-shaped
-- draw starts with (see RIME_ARENA): the boss has to be tracked in the world
-- AND the payload has to have come from inside its arena.
local function rimeOwns(position: Vector3): boolean
	return rimeNear(position, RIME_ARENA)
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
	local yaw = tonumber(model:GetAttribute(RF_ATTR_FACE))
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

-- WHERE THE CAROUSEL ACTUALLY TURNS. `undertow` centres both the drag and the
-- bergs it drops on `creature.anchor`, which updateBoss sets to the point the
-- boss rose at - and for a lair island that is BossArenas.centerFor(islandId)
-- exactly (BossService.arenaPosition). The stock tell is fired from the
-- boss's PIVOT instead, and the two are up to a roam disc apart (28 studs).
-- Sanity-checked rather than trusted: if the shared row and the payload
-- disagree by more than the disc plus margin, the row is not describing this
-- fight and the payload wins.
local function rimeArenaCenter(position: Vector3): Vector3
	local center = BossArenas.centerFor(RIME_ISLAND)
	if
		center
		and (Vector3.new(center.X, 0, center.Z) - Vector3.new(position.X, 0, position.Z)).Magnitude
			<= RIME_ANCHOR_TRUST
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
	for slot = 1, WEDGE_SLOTS do
		local w = wedges[slot]
		local pool = wedgePool[slot]
		if w and pool then
			local elapsed = now - w.start
			if elapsed > w.life + WEDGE_FADE then
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
					local into = math.clamp(elapsed - w.windup, 0, BITE_LEAD)
					reach += BITE_LUNGE * (BITE_LEAD - into) / BITE_STRIKE
				end
				local u = math.clamp(elapsed / math.max(w.windup, 1e-3), 0, 1)
				local fade = math.clamp((elapsed - w.life) / WEDGE_FADE, 0, 1)
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
					local step = reach / WEDGE_SLABS
					for i = 1, WEDGE_SLABS do
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
						rim.Size = Vector3.new(railStep * 0.86, 0.18, WEDGE_RIM_THICK)
						rim.CFrame = CFrame.new(center.X + ct * d, ground + 0.05, center.Z + st * d)
							* facing
							* CFrame.new(0, 0, side * w.width)
						rim.Transparency = rimAlpha
					end
					local cap = pool.rim[9]
					cap.Size = Vector3.new(WEDGE_RIM_THICK, 0.18, w.width * 2)
					cap.CFrame = CFrame.new(
						center.X + ct * (reach - WEDGE_RIM_THICK * 0.5),
						ground + 0.05,
						center.Z + st * (reach - WEDGE_RIM_THICK * 0.5)
					) * facing
					cap.Transparency = rimAlpha
				else
					local span = (2 * w.cone * reach) / WEDGE_SLABS
					for i = 1, WEDGE_SLABS do
						local t = (i - 0.5) / WEDGE_SLABS * 2 - 1 -- -1..1 across the mouth
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

						local edge = reach - WEDGE_RIM_THICK * 0.5
						local rim = pool.rim[i]
						rim.Size = Vector3.new(WEDGE_RIM_THICK, 0.18, span * 1.06)
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
	if not nearCamera(position, radius + RIME_MARGIN) then
		return true -- its moment, simply not ours to watch
	end
	local sheltered = false
	if type(extra.sheltered) == "table" then
		for _, userId in extra.sheltered do
			if userId == player.UserId then
				sheltered = true
				break
			end
		end
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
		sheltered = sheltered,
		passed = false,
	}
	return true
end

-- The crest passing the local player: the one frame where the fight tells you
-- whether your cover held. Shoved or sheltered, the wall goes by either way -
-- what differs is whether it breaks over you or over the berg in front.
local function washPass(center: Vector3, sheltered: boolean)
	local root = localRoot()
	if not root then
		return
	end
	local at = root.Position
	if sheltered then
		-- It broke on something. Spray comes over the top of the cover, from
		-- the side the wall did, and nothing touches you.
		local from = Vector3.new(center.X - at.X, 0, center.Z - at.Z)
		local dir = if from.Magnitude > 0.05 then from.Unit else Vector3.zAxis
		Vfx.puff(at + dir * 2.5 + Vector3.new(0, 3.5, 0), RIME.crest, 2.2)
		Vfx.burst(at + dir * 2 + Vector3.new(0, 3, 0), RIME.crest, 16)
	else
		Vfx.puff(at, RIME.slush, 2.4)
		Vfx.burst(at + Vector3.new(0, 1, 0), RIME.crest, 22)
		CombatVfxController.kick(math.rad(2.5), 0, 0.28)
	end
end

-- Is there arena furniture between the boss and this piece of the crest?
-- The SAME test the server runs against a player's root before it decides
-- who the wash sheltered (CreatureService.washSheltered, down to the
-- `_Base`/`_Floor` name check that stops a graze along the domed floe from
-- counting): the bergs and the frozen whaler break the wall where they stand,
-- so the shape of the safe ground is drawn by the wall itself rather than
-- learned by dying behind the wrong rock.
local washParams: RaycastParams? = nil
local washFilterAt = 0

local function washCovered(from: Vector3, to: Vector3): boolean
	local params = washParams
	if not params then
		params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		washParams = params
	end
	local now = os.clock()
	if now >= washFilterAt then
		washFilterAt = now + 1
		local arenas = Workspace:FindFirstChild(BOSS_ARENA_FOLDER)
		params.FilterDescendantsInstances = if arenas then { arenas } else {}
	end
	local origin = from + Vector3.new(0, 2.5, 0)
	local hit = Workspace:Raycast(origin, to - origin, params)
	if not hit then
		return false
	end
	local name = hit.Instance.Name
	return not (string.find(name, "_Base", 1, true) or string.find(name, "Floor", 1, true))
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
				washPass(wash.center, wash.sheltered)
			end
		end
	end
	local elapsed = now - wash.start
	-- The crest is over once it has crossed; the slush it dumped stays for
	-- the payload's duration, which is what that number is actually for.
	local life = math.max(WASH_SWEEP + WASH_FADE, wash.duration)
	if elapsed > life + WASH_FADE then
		wash = nil
		parkParts(washPool.crest)
		parkParts(washPool.apron)
		return
	end
	local u = math.clamp(elapsed / WASH_SWEEP, 0, 1)
	local fade = math.clamp((elapsed - WASH_SWEEP) / WASH_FADE, 0, 1)
	local slushFade = math.clamp((elapsed - wash.duration) / WASH_FADE, 0, 1)
	local r = WASH_INNER + (wash.radius - WASH_INNER) * u
	local cos, sin = math.cos(wash.angle), math.sin(wash.angle)
	-- One sample, on the crest's centre line: a floe is flat, and sixteen
	-- rays a frame to prove it would be sixteen rays a frame wasted.
	local ground = sheetY(wash.center.X + cos * r, wash.center.Z + sin * r, wash.center.Y)
	local pulse = 0.5 + 0.5 * math.sin(now * 14)
	local alpha = math.min((0.2 + 0.1 * pulse) + 0.8 * fade, 1)
	local slush = math.min((0.52 + 0.08 * pulse) + 0.48 * slushFade, 1)
	local span = (2 * wash.cone * r) / WASH_SLABS
	-- The slush covers the ground the wall has ALREADY been over - which, the
	-- moment the crest is out at `radius`, is the whole damaged footprint. It
	-- used to be a lagging band 5.5 studs deep, so the wedge the server hit
	-- was left unmarked behind the crest as well as in front of it.
	local back = 0.5 * (WASH_INNER + math.max(r - WASH_APRON_LAG * (1 - u), WASH_INNER + 0.5))
	local depth = math.max(r - WASH_APRON_LAG * (1 - u) - WASH_INNER, 1)

	for i = 1, WASH_SLABS do
		local t = (i - 0.5) / WASH_SLABS * 2 - 1 -- -1..1 across the wedge
		local theta = wash.angle + wash.cone * t
		local ct, st = math.cos(theta), math.sin(theta)
		-- Tallest on the bearing it was aimed down and lower at the shoulders,
		-- so a wall crossing 140 degrees of arena still reads as ONE thing
		-- coming from somewhere rather than as weather.
		local height = WASH_HEIGHT * (1 - 0.28 * u) * (0.62 + 0.38 * math.cos(t * math.pi * 0.5))
		local at = Vector3.new(wash.center.X + ct * r, ground + 1.6, wash.center.Z + st * r)
		-- A berg or the whaler standing in the way breaks the wall where it
		-- stands: what is left is a NOTCH in the crest, wide enough to stand
		-- in, and standing in it is the whole counterplay.
		local shaded = washCovered(wash.center, at)
		if shaded then
			height *= 0.22
		end
		local slab = washPool.crest[i]
		slab.Size = Vector3.new(WASH_THICK, height, span * 1.12)
		slab.CFrame = CFrame.new(wash.center.X + ct * r, ground + height * 0.5, wash.center.Z + st * r)
			* CFrame.Angles(0, -theta, 0)
		slab.Transparency = if shaded then math.min(alpha + 0.35, 1) else alpha

		-- ...and the slush it has dumped on the ice behind the crest: the wall
		-- passing is a moment, the mess it leaves is how you know which way it
		-- went after it has gone - and how you know how much of the floe it
		-- just had.
		local apron = washPool.apron[i]
		apron.Size = Vector3.new(depth, 0.35, (2 * wash.cone * back) / WASH_SLABS * 1.3)
		apron.CFrame = CFrame.new(wash.center.X + ct * back, ground + 0.18, wash.center.Z + st * back)
			* CFrame.Angles(0, -theta, 0)
		apron.Transparency = slush
	end

	if fade <= 0 and now >= wash.nextSprayAt then
		wash.nextSprayAt = now + WASH_SPRAY_GAP
		for _ = 1, 2 do
			local theta = wash.angle + wash.cone * (math.random() * 2 - 1)
			local at = Vector3.new(
				wash.center.X + math.cos(theta) * r,
				ground + randomBetween(1.5, WASH_HEIGHT),
				wash.center.Z + math.sin(theta) * r
			)
			Vfx.puff(at, RIME.crest, 1.5)
		end
	end
end

-- ------------------------------------------------------------- broken sheet

-- Cracks thrown out from something enormous landing on the ice. They GROW
-- (the split running outward is the whole read) and then stay, because the
-- sheet does not heal inside the punish window they open.
local function drawFloeCracks(position: Vector3, radius: number)
	local y = sheetY(position.X, position.Z, position.Y) + 0.09
	for i = 1, CRACK_SLABS do
		local slab = crackPool[i]
		local theta = (i / CRACK_SLABS) * math.pi * 2 + randomBetween(-0.14, 0.14)
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
			TweenInfo.new(CRACK_FADE, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, CRACK_HOLD),
			{ Transparency = 1 }
		):Play()
	end
end

-- ------------------------------------------------------------- the breach

-- The whole animal leaving the water. The `charge` handler fires the stock
-- `splash` at the instant it goes, which is the only frame-accurate launch
-- cue there is - so the breach's telegraph arms this, and EVENTS.splash hands
-- that moment over here instead of drawing a cod's ring.
startBreachSplash = function(position: Vector3): boolean
	local arm = breachArm
	if not arm or os.clock() > arm.until_ then
		breachArm = nil
		return false
	end
	if (Vector3.new(position.X, 0, position.Z) - Vector3.new(arm.at.X, 0, arm.at.Z)).Magnitude > 25 then
		-- SPENT EITHER WAY. Leaving the arm standing on the reject path meant
		-- the NEXT splash inside 25 studs of the armed point - a cod's spit
		-- landing, a swimmer, anything - was promoted into a full breach
		-- launch (crash, cracks, camera kick) for the rest of the ~2s window.
		-- A missed cue costs the player one beat of anticipation; a fabricated
		-- one tells them a 46-stud leap is coming when nothing is.
		breachArm = nil
		return false
	end
	breachArm = nil
	if not nearCamera(position, RIME_CULL) then
		return true
	end
	local at = Vector3.new(position.X, sheetY(position.X, position.Z, position.Y) + 0.2, position.Z)
	Sfx.play("rimeBreachLaunch", at)
	Vfx.splash(at, 5)
	Vfx.burst(at, RIME.crest, 70)
	Vfx.puff(at + Vector3.new(0, 2, 0), RIME.slush, 4)
	Vfx.shockwave(at + Vector3.new(0, 0.4, 0), 2, 20, 0.5, RIME.crest, 0.5)
	Vfx.ring(at, 3, 22, 0.7, RIME.slush)
	-- The hole it came out of, still throwing water a beat later.
	for i = 1, 3 do
		task.delay(i * 0.11, function()
			Vfx.splash(at + Vector3.new(randomBetween(-5, 5), 0, randomBetween(-5, 5)), 2)
		end)
	end
	drawFloeCracks(at, 13)
	feelBlast(at, 26, SHAKE_RISE, 0.45, Color3.fromRGB(214, 240, 255))
	return true
end

-- Something whale-sized landing on the sheet: the breach's crash (r15) or the
-- fluke coming down through a hole (r24). Both break the ice, which is why
-- they share a drawing; what tells them apart is weight and sound.
rimeSlam = function(position: Vector3, extra): boolean
	local radius = tonumber(extra.radius) or 15
	local move = rimeMove(radius)
	if move ~= "breach" and move ~= "flukeslam" then
		return false
	end
	-- The breach's crash comes out of the `charge` handler, which stamps the
	-- skin. The fluke rides the stock `slam`, which stamps nothing - so that
	-- one is confirmed against the animal standing there instead.
	if extra.skin ~= "frost" and not rimeNear(position, 40) then
		return false
	end
	if not nearCamera(position, radius + RIME_MARGIN) then
		return true
	end
	local crash = move == "breach"
	local at = Vector3.new(position.X, sheetY(position.X, position.Z, position.Y) + 0.15, position.Z)

	-- CRACK then BOOM: the sheet splitting arrives fractionally before the
	-- tonnage does, the way killCrack sits ahead of killThump.
	Sfx.play("rimeFloeCrack", at)
	task.delay(0.05, function()
		Sfx.play(if crash then "rimeBreachCrash" else "rimeFlukeSlam", at)
	end)

	drawFloeCracks(at, radius * (if crash then 1.5 else 1.0))
	Vfx.flash(at + Vector3.new(0, 2, 0), RIME.crack, if crash then 9 else 6, 0.22)
	Vfx.shockwave(at + Vector3.new(0, 0.4, 0), 2, radius, 0.5, RIME.crest, 0.7)
	Vfx.ring(at, 2, radius * 1.3, 0.8, RIME.slush)
	Vfx.puff(at, RIME.slush, if crash then 5 else 3.4)
	Vfx.burst(at, RIME.crest, if crash then 70 else 40)
	for i = 1, 6 do
		local a = (i / 6) * math.pi * 2
		Vfx.splash(at + Vector3.new(math.cos(a) * radius * 0.5, 0.2, math.sin(a) * radius * 0.5), 2)
	end
	feelBlast(at, radius, if crash then SHAKE_SLAM else SHAKE_PULSE, 0.5, Color3.fromRGB(220, 242, 255))
	return true
end

-- ------------------------------------------------------- the punish window

local function closeBeached()
	if not beached then
		return
	end
	local at = beached.at
	beachedRing.Transparency = 1
	beachedRing.CFrame = PARKED
	beached = nil
	-- It works itself over the edge and is gone.
	Sfx.play("rimeThrash", at)
	Vfx.splash(at, 3)
	Vfx.puff(at, RIME.slush, 4)
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
	if not nearCamera(at, RIME_CULL) then
		return
	end
	if not beached then
		beached = {
			at = at,
			until_ = now + BEACHED_WINDOW,
			duration = BEACHED_WINDOW,
			nextThrashAt = now,
			nextPuffAt = 0,
		}
		Vfx.flash(at + Vector3.new(0, 4, 0), BRINE.window, 8, 0.5)
		Vfx.burst(at + Vector3.new(0, 2, 0), BRINE.window, 45)
	end
	beached.at = at

	-- The disc IS the clock: it closes as the window does and strobes faster
	-- the less of it there is left. Readable from anywhere on the floe with
	-- no HUD and no text.
	local left = math.max(beached.until_ - now, 0)
	local u = math.clamp(left / beached.duration, 0, 1)
	local r = BEACHED_RADIUS * (0.2 + 0.8 * u)
	beachedRing.Size = Vector3.new(0.16, r * 2, r * 2)
	beachedRing.CFrame = CFrame.new(at.X, sheetY(at.X, at.Z, at.Y) + 0.16, at.Z) * CFrame.Angles(0, 0, math.rad(90))
	local rate = 2.2 + 6 * (1 - u)
	beachedRing.Transparency = 0.5 + 0.28 * (0.5 + 0.5 * math.sin(now * rate * math.pi * 2))

	if now >= beached.nextThrashAt then
		beached.nextThrashAt = now + BEACHED_THRASH_GAP
		Sfx.play("rimeThrash", at)
		Vfx.burst(at + Vector3.new(0, 1.5, 0), BRINE.window, 16)
	end
	if now >= beached.nextPuffAt then
		beached.nextPuffAt = now + 0.28
		-- Slush thrown off it as it works itself back toward the water.
		local jitter = Vector3.new(randomBetween(-7, 7), randomBetween(0, 3), randomBetween(-7, 7))
		Vfx.puff(at + jitter, RIME.slush, 1.6)
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
	if not nearCamera(head, RIME_CULL) then
		return
	end
	local y = sheetY(head.X, head.Z, head.Y)
	Vfx.splash(Vector3.new(head.X, y + 0.2, head.Z), 2.5)
	for i = 0, 3 do
		task.delay(i * 0.05, function()
			Vfx.puff(Vector3.new(head.X, y + 1.5 + i * 2.6, head.Z), RIME.crest, 1.6 - i * 0.2)
		end)
	end
end

local function stepWake(now: number)
	local model = rimefang(now)
	local depth = if model then tonumber(model:GetAttribute(ATTR_SUBMERGE)) else nil
	-- Checked BEFORE the wake is parked, and off the raw attribute: a server
	-- that snaps Submerge straight to 0 would otherwise surface the animal in
	-- silence, and the breath is the one cue that says "it is up, and there".
	if model and wake and depth and depth <= WAKE_SPOUT_AT and not wake.spouted then
		wake.spouted = true
		spoutAt(model:GetPivot().Position)
	end
	if not model or not depth or depth <= 0.05 or not nearCamera(model:GetPivot().Position, RIME_CULL) then
		if wake then
			wake = nil
			parkParts(wakePool.arms)
			wakePool.knuckle.Transparency = 1
			wakePool.knuckle.CFrame = PARKED
			wakePool.glow.Transparency = 1
			wakePool.glow.CFrame = PARKED
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
		for k = 1, WAKE_ARMS do
			local slab = wakePool.arms[side * WAKE_ARMS + k]
			slab.Size = Vector3.new(0.5 + 0.09 * k, 0.3, WAKE_STEP * 1.08)
			slab.CFrame = frame * CFrame.Angles(0, sign * WAKE_SPLAY, 0) * CFrame.new(0, 0, k * WAKE_STEP)
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
		wake.nextSprayAt = now + WAKE_SPRAY_GAP
		Vfx.puff(Vector3.new(head.X, y + 0.3, head.Z), RIME.wake, 1.0 * (1 - depth * 0.5))
		Vfx.ring(Vector3.new(head.X, y + 0.16, head.Z), 1.5, 6, 0.5, RIME.wake)
	end

	-- Back down under the sheet: the next time it comes up, it breathes again.
	if depth > 0.6 then
		wake.spouted = false
	end
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
			Vfx.flash(position + Vector3.new(0, 1 + i * 2.6, 0), RIME.crest, 3.4 - i * 0.35, 0.3)
		end)
	end
	Vfx.ring(Vector3.new(position.X, point.Y + 0.18, position.Z), 3, 16, math.min(duration, 1.1), RIME.wake)
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
			Vfx.ring(at - Vector3.new(0, 2.6, 0), 7 - i * 0.9, 1.6, 0.3, RIME.mark)
			Vfx.burst(at + Vector3.new(0, 2.4, 0), RIME.mark, if mine then 14 else 8)
			Vfx.flash(at + Vector3.new(0, 4.5, 0), RIME.mark, 1.6, 0.24)
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
	elseif move == "carousel" and kind == "mark" then
		return "carousel"
	elseif move == "breach" and kind == "burst" then
		return "breach"
	elseif move == "flukeslam" and kind == "burst" then
		return "fluke"
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
	local branch = rimeBranch(kind, rimeMove(radius), aimed)
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
	if not nearCamera(position, (radius or 20) + RIME_MARGIN) then
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
		wedges[WEDGE_BITE] = {
			kind = "bite",
			live = true, -- the jaws follow the animal; it is still turning
			center = position,
			angle = flatAngle(extra.facing) or 0,
			cone = BITE_CONE,
			reach = radius or BITE_RADIUS,
			start = os.clock(),
			windup = duration,
			-- ...and it stays up through the 0.14s of strike before the jaws
			-- actually close, shrinking as the boss lunges through it.
			life = duration + BITE_LEAD,
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
					RIME.crest,
					3.2
				)
			end)
		end
		return true
	elseif branch == "carousel" then
		-- THE CURRENT TURNS, AND IT TURNS AROUND THE ARENA. `undertow` centres
		-- both the drag and the bergs it drops on `creature.anchor`, and this
		-- had NO branch at all: RIME_TELL.carousel resolved and then fell
		-- through every arm to the stock draw, which is an EXPANDING ring -
		-- and an expanding ring says "the edge is coming, get inside". The
		-- pull reaches the whole radius and a berg can land anywhere in it, so
		-- there is no safe middle to promise and the only answer is to be
		-- outside. Rings run INWARD off the boundary instead: the water is
		-- being dragged to the middle, and so are you.
		local center = rimeArenaCenter(position)
		local r = radius or 30
		local ground = sheetY(center.X, center.Z, center.Y) + 0.16
		local at = Vector3.new(center.X, ground, center.Z)
		Sfx.play("bossTell", at)
		local pulses = math.max(2, math.floor(duration / 0.24))
		for i = 0, pulses - 1 do
			task.delay(i * 0.24, function()
				-- Redrawn every beat, so the boundary is on screen the whole
				-- windup rather than only at the instant a pulse is born.
				Vfx.ring(at, r, r * 0.22, 0.44, SKIN.frost)
				-- ...and the water going with it.
				for k = 1, 5 do
					local theta = randomBetween(0, math.pi * 2)
					Vfx.puff(
						at + Vector3.new(math.cos(theta) * r * 0.8, 0.6, math.sin(theta) * r * 0.8),
						RIME.slush,
						1.6 + 0.2 * k
					)
				end
			end)
		end
		return true
	elseif branch == "breach" then
		-- It has gone under and it is coming UP. The runway is the read: it
		-- lands flat, forty-six studs along the bearing it is pointed down,
		-- so what matters is not the circle it is in now.
		breachArm = { at = position, until_ = os.clock() + duration + 0.9 }
		Sfx.play("bossTell", position)
		local dir = if aimed then Vector3.new(extra.facing.X, 0, extra.facing.Z) else Vector3.zero
		local point = surfaceUnder(position)
		-- THE LANE, not the circle it is standing in. `charge` latches its
		-- bearing on the first windup frame and never re-aims, so this
		-- `facing` is the line the leap will actually take; and the damage is
		-- no longer a ring at the head but `bodyContact` walking all nine
		-- spine nodes, each ploughing the floe within `width` of itself for
		-- the whole 46-stud travel. The ground that gets hit is therefore a
		-- CORRIDOR, and the stock 15-stud `burst` at the pivot marked neither
		-- its length nor its width. Drawn only when the bearing is known -
		-- a corridor down an unknown line would be worse than none.
		if dir.Magnitude > 1e-3 then
			wedges[WEDGE_BREACH] = {
				kind = "corridor",
				live = false, -- latched, and the whale is about to leave it
				center = position,
				angle = flatAngle(extra.facing) or 0,
				cone = 0,
				width = tonumber(extra.width) or BREACH_WIDTH,
				reach = BREACH_LENGTH,
				start = os.clock(),
				windup = duration,
				-- Held through the leap itself: the lane is being ploughed for
				-- `duration` after the tell's clock runs out, and a marker
				-- that vanished at takeoff would clear the floe of warnings
				-- exactly while the whale was crossing it.
				life = duration + BREACH_TRAVEL,
			}
		end
		local pulses = math.max(2, math.floor(duration / 0.2))
		for i = 0, pulses - 1 do
			task.delay(i * 0.2, function()
				-- The sheet heaving where it is about to come through...
				Vfx.ring(point + Vector3.new(0, 0.16, 0), (radius or 15) * 1.1, 2, 0.22, RIME.crest)
				Vfx.puff(point + Vector3.new(0, 0.4, 0), RIME.slush, 2)
				-- ...and where it is going to come down.
				if dir.Magnitude > 1e-3 then
					local aim = dir.Unit
					for step = 1, 3 do
						local mark = position + aim * (BREACH_LENGTH * step / 3)
						local landing = surfaceUnder(mark)
						Vfx.ring(landing + Vector3.new(0, 0.16, 0), 2, 4 + step * 2, 0.24, RIME.crack)
					end
				end
			end)
		end
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
				Vfx.ring(point + Vector3.new(0, 0.16, 0), (radius or 24), (radius or 24) * 0.25, 0.26, RIME.crest)
				Vfx.puff(point + Vector3.new(0, 0.3, 0), RIME.slush, 1.8)
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
		wedges[WEDGE_WASH] = {
			kind = "wash",
			live = true, -- ...and so does the wall, right up to `a.dir`
			center = position,
			angle = flatAngle(extra.facing) or 0,
			-- The payload carries no cone (the stock tell sends none), so the
			-- row's own number stands in. See the REPORT.
			cone = tonumber(extra.cone) or WASH_CONE,
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
				local r = WASH_INNER + (reach - WASH_INNER) * ((i + 1) / pulses)
				for k = 1, 7 do
					local theta = base + WASH_CONE * ((k - 0.5) / 7 * 2 - 1)
					Vfx.puff(
						Vector3.new(
							position.X + math.cos(theta) * r,
							ground + 0.6 + i * 0.5,
							position.Z + math.sin(theta) * r
						),
						RIME.crest,
						1.5
					)
				end
			end)
		end
		return true
	end
	return false
end

local warnedKinds = {}

local function onCreatureEvent(kind, position, extra)
	if typeof(position) ~= "Vector3" then
		return
	end
	local handler = type(kind) == "string" and EVENTS[kind]
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
	for i = 1, GLOB_POOL do
		globs[i] = { part = makeGlob(), active = false }
	end

	-- Brinejaw's markers: one ladder of rungs (and the shadows a high arm
	-- casts) per concurrent sweep, plus the stagger window's closing disc.
	for slot = 1, SWEEP_SLOTS do
		local pool = { rungs = {}, shadows = {} }
		for i = 1, SWEEP_RUNGS do
			pool.rungs[i] = makeMarker("SweepRung", BRINE.low, true)
			pool.shadows[i] = makeMarker("SweepShadow", BRINE.shadow, false)
		end
		sweepPool[slot] = pool
	end
	-- The choir's beam: a widening ladder of lit ground per concurrent sweep,
	-- plus the shaft that ties it back to the lantern casting it.
	for slot = 1, BEAM_SLOTS do
		local pool = { rungs = {} }
		for i = 1, BEAM_RUNGS do
			pool.rungs[i] = makeMarker("BeamRung", LURE_LIGHT, true)
		end
		pool.shaft = makeMarker("BeamShaft", LURE_LIGHT, true)
		beamPool[slot] = pool
	end

	staggerRing = makeMarker("StaggerWindow", BRINE.window, true)
	staggerRing.Shape = Enum.PartType.Cylinder

	-- Rimefang's markers. The wash's wall (a crest of slabs on the wedge the
	-- server's own hit test measures, plus the slush apron trailing it), the
	-- cracks a landing leaves in the sheet, the wake that tracks it under the
	-- ice, and the punish window's closing disc.
	for i = 1, WASH_SLABS do
		washPool.crest[i] = makeMarker("WashCrest", RIME.crest, true)
		washPool.apron[i] = makeMarker("WashSlush", RIME.slush, false)
	end
	for i = 1, CRACK_SLABS do
		crackPool[i] = makeMarker("FloeCrack", RIME.crack, true)
	end
	-- The bite's mouth, the wash's gathering wall and the breach's lane: a
	-- fan (or a run) of ground slabs each, plus the boundary the player has
	-- to be standing outside of. SKIN.frost for the same reason everything
	-- else in this fight is - a marker on sea ice has to be DARK or it is not
	-- a marker.
	for slot = 1, WEDGE_SLOTS do
		local pool = { fan = {}, rim = {} }
		for i = 1, WEDGE_SLABS do
			pool.fan[i] = makeMarker("RimeWedge", SKIN.frost, true)
			pool.rim[i] = makeMarker("RimeWedgeEdge", SKIN.frost, true)
		end
		wedgePool[slot] = pool
	end
	wakePool = { arms = {}, knuckle = makeMarker("WakeKnuckle", RIME.wake, true) }
	for i = 1, WAKE_ARMS * 2 do
		wakePool.arms[i] = makeMarker("WakeArm", RIME.wake, true)
	end
	wakePool.glow = makeMarker("WakeGlow", RIME.glow, true)
	wakePool.glow.Shape = Enum.PartType.Cylinder
	local wakeLight = Instance.new("PointLight")
	wakeLight.Color = RIME.glow
	wakeLight.Brightness = 0
	wakeLight.Range = 20
	wakeLight.Enabled = false
	wakeLight.Parent = wakePool.glow
	wakePool.light = wakeLight

	beachedRing = makeMarker("RimeBeachedWindow", BRINE.window, true)
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
		stepSweeps(now)
		stepBeams(now)
		stepStagger(now)
		stepWash(now)
		stepWedges(now)
		stepWake(now)
		stepBeached(now)
	end)

	-- A respawn drops any pull/chill/snare/chain with the old character.
	player.CharacterAdded:Connect(function()
		endPull()
		endChain()
		moveEffect = nil -- the old humanoid is gone; the new one spawns clean
	end)

	task.spawn(function()
		local creatures = Workspace:WaitForChild(CREATURES_FOLDER, 30)
		if not creatures then
			warn("[CreatureEvent] no Workspace." .. CREATURES_FOLDER .. " folder; enemy effects off")
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
