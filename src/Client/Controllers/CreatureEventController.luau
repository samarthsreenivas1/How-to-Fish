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
	frost = Color3.fromRGB(160, 225, 255), -- Rimefang
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
	if inRange then
		beginPull(position, radius, -push, duration)
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
local SWEEP_WIDTH = 6.8 -- the arm's drawn thickness, across the bearing
local SWEEP_LOW_TOP = 3.2 -- a low wall stands this far above the arm's line
local SWEEP_HIGH_RAIL = 1.4 -- a high rail is this thin, and that is the point
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

	for i = 1, SWEEP_RUNGS do
		local r = s.inner + span * (i - 0.5)
		local ground = s.center.Y + BrinejawPath.sandY(r)
		local x, z = s.center.X + cos * r, s.center.Z + sin * r
		local rung = pool.rungs[i]
		if s.high then
			-- A rail at the arm's own height, and clear air all the way down.
			rung.Size = Vector3.new(length, SWEEP_HIGH_RAIL, SWEEP_WIDTH)
			rung.CFrame = CFrame.new(x, ground + s.height, z) * facing
			local shade = pool.shadows[i]
			shade.Size = Vector3.new(length, SWEEP_SHADOW_THICK, SWEEP_WIDTH * 0.9)
			shade.CFrame = CFrame.new(x, ground + 0.06, z) * facing
			shade.Transparency = 0.42 + 0.58 * fade
		else
			-- A wall planted ON the sand: bottom flush with the ground, top
			-- just under a jump. Nothing to read here but "get above it".
			rung.Size = Vector3.new(length, tall, SWEEP_WIDTH)
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
	local angle = tonumber(extra.angle) or 0
	local s = {
		center = position,
		angle = angle,
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
	staggerRing = makeMarker("StaggerWindow", BRINE.window, true)
	staggerRing.Shape = Enum.PartType.Cylinder

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
		stepStagger(now)
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
