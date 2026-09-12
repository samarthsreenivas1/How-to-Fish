--!nonstrict
-- CombatVfxController.luau
-- The impact when a punch actually connects with a fish. Driven by the
-- CreatureHit remote (CombatService fires it to every client with the
-- contact point), so all players see the same burst in the same place.
--
-- Low-poly on purpose, to match the flat-shaded world: no particle sprites.
-- Every effect is a handful of plain neon Parts from fixed pools (the plan's
-- "don't build during combat" rule), moved by hand each Heartbeat:
--
--   flash  - a bright sphere that pops and collapses at the contact point.
--   ring   - a flat disc facing the puncher, expanding and fading - the
--            "shockwave" that sells the hit from the side.
--   shards - chunky cubes flung back out of the fish toward the puncher,
--            shrinking as they fly.
--
-- The puncher's own camera also gets a short kick. A killing blow gets the
-- same effects, bigger. The health bar / flash / damage number stay in
-- CombatFeedbackController, keyed off Health - this is only the splash.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local CreatureFamilies = require(Shared.Data.CreatureFamilies)

local Sfx = require(script.Parent.Parent.Modules.Sfx)

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

local CombatVfxController = {}

-- ---------------------------------------------------------------- config

local SHARD_POOL = 48
local RING_POOL = 6
local FLASH_POOL = 6

-- Palette: hot white core, warm edges - reads as impact, not magic.
local FLASH_COLOR = Color3.fromRGB(255, 255, 240)
local RING_COLOR = Color3.fromRGB(255, 245, 200)
local SHARD_COLORS = {
	Color3.fromRGB(255, 255, 255),
	Color3.fromRGB(255, 232, 120),
	Color3.fromRGB(255, 176, 80),
}

local FLASH_SIZE = 1.7 -- studs, at the pop
local FLASH_DURATION = 0.12

local RING_START = 0.8 -- diameter, studs
local RING_END = 4.6
local RING_THICKNESS = 0.14
local RING_DURATION = 0.22

local SHARD_COUNT = 9
local SHARD_SIZE = 0.38 -- studs, at spawn; shrinks to nothing
local SHARD_SPEED_MIN = 13 -- studs/second at spawn
local SHARD_SPEED_MAX = 22
local SHARD_DRAG = 7 -- velocity decays by this factor per second
local SHARD_GRAVITY = 26 -- studs/second^2; a touch of fall so they arc
local SHARD_DURATION = 0.38
local SHARD_SPREAD = 0.75 -- 0 = straight back at the puncher, 1 = any direction

-- A kill scales the whole thing up.
local KILL_SCALE = 1.7
local KILL_SHARD_COUNT = 18

-- Camera kick for the puncher. Two parts: a directional PUNCH - the view
-- snaps down/forward as the fist connects, then springs back, so the hit
-- registers in your own hands - plus a little random tilt for texture.
local SHAKE_ANGLE = math.rad(0.9)
local SHAKE_DURATION = 0.16
local PUNCH_PITCH = math.rad(2.6) -- downward view snap on a hit
local KILL_THUMP_DELAY = 0.07 -- seconds the kill's deep boom trails its crack
local SHAKE_KILL_ANGLE = math.rad(2.2)
local SHAKE_KILL_DURATION = 0.28

-- ---------------------------------------------------------------- pools

local folder: Folder? = nil

local flashes = {} -- { part, active, start, scale }
local rings = {} -- { part, active, start, scale, cframe }
local shards = {} -- { part, active, start, position, velocity, size }
local cursors = { flash = 1, ring = 1, shard = 1 }

local function makeEffectPart(name: string, shape: Enum.PartType, color: Color3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = shape
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = 1
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.Parent = folder
	return part
end

local function buildPools()
	for i = 1, FLASH_POOL do
		flashes[i] = { part = makeEffectPart("HitFlash", Enum.PartType.Ball, FLASH_COLOR), active = false }
	end
	for i = 1, RING_POOL do
		rings[i] = { part = makeEffectPart("HitRing", Enum.PartType.Cylinder, RING_COLOR), active = false }
	end
	for i = 1, SHARD_POOL do
		local color = SHARD_COLORS[(i - 1) % #SHARD_COLORS + 1]
		shards[i] = { part = makeEffectPart("HitShard", Enum.PartType.Block, color), active = false }
	end
end

-- Round-robin: the oldest entry is recycled when the pool is exhausted,
-- which for these lifetimes is never noticeable.
local function take(pool, key: string)
	local entry = pool[cursors[key]]
	cursors[key] = cursors[key] % #pool + 1
	return entry
end

local function retire(entry)
	entry.active = false
	entry.part.Transparency = 1
end

-- ---------------------------------------------------------------- spawn

local function randomUnit(): Vector3
	local v = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5)
	return if v.Magnitude > 0.01 then v.Unit else Vector3.yAxis
end

local function burst(hitPoint: Vector3, direction: Vector3, killed: boolean)
	local now = os.clock()
	local scale = if killed then KILL_SCALE else 1

	local flash = take(flashes, "flash")
	flash.active = true
	flash.start = now
	flash.scale = scale
	flash.part.Position = hitPoint
	flash.part.Transparency = 0

	-- A cylinder's flat faces are on its X axis; aim that back along the
	-- punch so the disc faces the puncher.
	local ring = take(rings, "ring")
	ring.active = true
	ring.start = now
	ring.scale = scale
	ring.cframe = CFrame.lookAt(hitPoint, hitPoint - direction) * CFrame.Angles(0, math.rad(90), 0)
	ring.part.Transparency = 0.2

	-- Shards fly back out of the fish toward the puncher, fanned by SPREAD.
	local back = -direction
	local count = if killed then KILL_SHARD_COUNT else SHARD_COUNT
	for _ = 1, count do
		local shard = take(shards, "shard")
		shard.active = true
		shard.start = now
		shard.size = SHARD_SIZE * scale
		shard.position = hitPoint
		local dir = (back * (1 - SHARD_SPREAD) + randomUnit() * SHARD_SPREAD).Unit
		local speed = SHARD_SPEED_MIN + (SHARD_SPEED_MAX - SHARD_SPEED_MIN) * math.random()
		shard.velocity = dir * speed * scale
		shard.part.CFrame = CFrame.new(hitPoint) * CFrame.Angles(math.random() * 6.28, math.random() * 6.28, 0)
		shard.part.Transparency = 0
	end
end

-- ---------------------------------------------------------------- camera kick

local shake = nil -- { start, angle, pitch, duration }

-- The rotation applied to the camera this frame, so it can be taken back
-- off before the camera scripts run again. Roblox's default camera derives
-- each frame's look direction from the camera's CURRENT CFrame, so an
-- offset left on it is absorbed into the look and the next frame's offset
-- stacks on top - the nod's down-biased curve then walked the view
-- downward a little on every hit (bug, 2026-08-22: "hitting an enemy makes
-- my camera go down"). Undoing it at Camera - 1 keeps the kick purely
-- visual.
local appliedOffset: CFrame? = nil

local function kick(angle: number, pitch: number, duration: number)
	shake = { start = os.clock(), angle = angle, pitch = pitch, duration = duration }
end

-- The same kick for other controllers (an explosion or shockwave nearby -
-- CreatureEventController). Routed through here rather than each applying
-- its own camera offset, so there's one restore/apply bracket around the
-- camera scripts and offsets can never stack or leak into the look.
function CombatVfxController.kick(angle: number, pitch: number, duration: number)
	kick(angle, pitch, duration)
end

-- Runs just BEFORE the camera scripts: hand them back the clean camera.
local function restoreCamera()
	if appliedOffset then
		camera.CFrame = camera.CFrame * appliedOffset:Inverse()
		appliedOffset = nil
	end
end

-- Runs just AFTER the camera scripts: lay this frame's kick on top.
local function applyShake()
	if not shake then
		return
	end
	local t = (os.clock() - shake.start) / shake.duration
	if t >= 1 then
		shake = nil
		return
	end
	-- Directional punch: pitch down hard as it connects, spring back past
	-- level and settle. sin over one period gives the down-then-up snap.
	local nod = -shake.pitch * math.sin(t * math.pi * 2) * (1 - t)
	-- Random tilt on top, decaying, for a bit of chaos.
	local amount = shake.angle * (1 - t) * (1 - t)
	local offset = CFrame.Angles(nod + (math.random() - 0.5) * 2 * amount, (math.random() - 0.5) * 2 * amount, 0)
	camera.CFrame = camera.CFrame * offset
	appliedOffset = offset
end

-- ---------------------------------------------------------------- per frame

local function step(dt: number)
	local now = os.clock()

	for _, flash in flashes do
		if flash.active then
			local t = (now - flash.start) / FLASH_DURATION
			if t >= 1 then
				retire(flash)
			else
				-- Pops to full size instantly, then collapses.
				local size = FLASH_SIZE * flash.scale * (1 - t)
				flash.part.Size = Vector3.new(size, size, size)
				flash.part.Transparency = t * 0.6
			end
		end
	end

	for _, ring in rings do
		if ring.active then
			local t = (now - ring.start) / RING_DURATION
			if t >= 1 then
				retire(ring)
			else
				local eased = 1 - (1 - t) * (1 - t)
				local diameter = (RING_START + (RING_END - RING_START) * eased) * ring.scale
				ring.part.Size = Vector3.new(RING_THICKNESS, diameter, diameter)
				ring.part.CFrame = ring.cframe
				ring.part.Transparency = 0.2 + 0.8 * t
			end
		end
	end

	for _, shard in shards do
		if shard.active then
			local t = (now - shard.start) / SHARD_DURATION
			if t >= 1 then
				retire(shard)
			else
				shard.velocity = shard.velocity * math.max(0, 1 - SHARD_DRAG * dt)
					- Vector3.new(0, SHARD_GRAVITY * dt, 0)
				shard.position += shard.velocity * dt
				local size = shard.size * (1 - t)
				shard.part.Size = Vector3.new(size, size, size)
				shard.part.CFrame = CFrame.new(shard.position) * shard.part.CFrame.Rotation
				shard.part.Transparency = math.max(0, t - 0.6) / 0.4
			end
		end
	end
end

-- ---------------------------------------------------------------- voice

-- WHICH creature was hit. The CreatureHit remote carries only the contact
-- point (hitPoint, direction, killed, attackerUserId - see Remotes.luau), so
-- the animal has to be recovered from the world: the nearest model under
-- Workspace.Creatures to the point the punch landed.
--
-- That is sound because the point IS on a creature's body - the server only
-- fires this from a hit it resolved - so the nearest model is the one that was
-- struck, and VOICE_SEARCH is a sanity radius rather than a real search: it
-- only has to be wider than half the biggest body (a boss) and narrower than
-- the gap to some unrelated fish. Nothing found means no family voice and the
-- existing crack/thump layers play alone, which is the pre-audio behaviour.
local VOICE_SEARCH = 30 -- studs from the contact point to the model's pivot

local function creatureAt(hitPoint: Vector3): string?
	local folder = Workspace:FindFirstChild("Creatures")
	if not folder then
		return nil
	end
	local bestId, bestD = nil, VOICE_SEARCH
	for _, model in folder:GetChildren() do
		if model:IsA("Model") then
			local id = model:GetAttribute("CreatureId") -- CreatureService's ATTR.ID
			if id then
				local d = (model:GetPivot().Position - hitPoint).Magnitude
				if d < bestD then
					bestId, bestD = id, d
				end
			end
		end
	end
	return bestId
end

-- ---------------------------------------------------------------- lifecycle

local function onCreatureHit(hitPoint: Vector3, direction: Vector3, killed: boolean, attackerUserId: number)
	if typeof(hitPoint) ~= "Vector3" or typeof(direction) ~= "Vector3" then
		return
	end
	burst(hitPoint, direction, killed == true)

	-- The animal's own voice, LAYERED OVER the crack/thump below rather than
	-- replacing it: those two are the punch (dry, impact, the same every time)
	-- and this is what was punched. One cue set per body family, pitched by
	-- size - see assets/audio_gen/CONTRACT.md §3 sfx_families.
	local creatureId = creatureAt(hitPoint)
	local family = CreatureFamilies.get(creatureId)
	if family then
		local pitch = CreatureFamilies.voicePitch(creatureId)
		Sfx.play(family .. (if killed then "Die" else "Hurt"), hitPoint, { pitch = pitch })
	end

	-- Two dry layers - crack + body thump - at the fish, so the punch lands
	-- with weight. Heard by everyone, so a hit across the dock sounds like it
	-- came from over there.
	if killed then
		-- Crack lands now; the deep boom follows a beat later so the kill
		-- reads as a two-part finisher.
		Sfx.play("killCrack", hitPoint)
		task.delay(KILL_THUMP_DELAY, function()
			Sfx.play("killThump", hitPoint)
		end)
	else
		Sfx.play("hitCrack", hitPoint)
		Sfx.play("hitThump", hitPoint)
	end

	if attackerUserId == player.UserId then
		if killed then
			kick(SHAKE_KILL_ANGLE, PUNCH_PITCH * 1.5, SHAKE_KILL_DURATION)
		else
			kick(SHAKE_ANGLE, PUNCH_PITCH, SHAKE_DURATION)
		end
	end
end

function CombatVfxController.init()
	local container = Instance.new("Folder")
	container.Name = "CombatVfx"
	container.Parent = Workspace
	folder = container
	buildPools()
end

function CombatVfxController.start()
	Remotes.CreatureHit.OnClientEvent:Connect(onCreatureHit)
	RunService.Heartbeat:Connect(step)
	-- Bracket the camera scripts: take last frame's kick off just before they
	-- run (so it never leaks into the look direction), put this frame's on
	-- just after, before the viewmodels pin to the camera (Camera + 2) so
	-- the hands shake with the view.
	RunService:BindToRenderStep("CombatVfxShakeRestore", Enum.RenderPriority.Camera.Value - 1, restoreCamera)
	RunService:BindToRenderStep("CombatVfxShake", Enum.RenderPriority.Camera.Value + 1, applyShake)
end

return CombatVfxController
