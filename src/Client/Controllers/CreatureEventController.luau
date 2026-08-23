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
	-- Only inside the radius, and never past the maw itself.
	if d > pull.radius or d < 4 then
		pull.force.Force = Vector3.zero
		return
	end
	local ramp = math.clamp((now - pull.start) / PULL_RAMP, 0, 1)
	pull.force.Force = to.Unit * pull.strength * ramp * root.AssemblyMass
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
		Vfx.flash(position + Vector3.new(0, 4, 0), COLOR.brine, 5, duration)
	elseif kind == "dive" then
		Vfx.flash(position, Vfx.Color.foam, 3, duration)
	elseif kind == "snap" then
		Vfx.flash(position + Vector3.new(0, 1, 0), Vfx.Color.foam, 3, duration)
	else
		Vfx.flash(position + Vector3.new(0, 2, 0), COLOR.brine, 3, duration)
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
	end)

	-- A respawn drops any pull with the old root.
	player.CharacterAdded:Connect(endPull)

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
