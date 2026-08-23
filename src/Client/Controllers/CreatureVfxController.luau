--!nonstrict
-- CreatureVfxController.luau
-- Effects - visual and sound - on creatures, driven entirely by what the
-- server already replicates: the Model appearing under Workspace.Creatures
-- (it bursts out of the water at the bobber) and three attributes
-- CreatureService sets on it - `Thrown` (in the air: water drips off it),
-- `Landed` (a splash or a sand puff wherever it came down) and `Flops` (a
-- counter; each tick is a flop, so a small splash or puff). No remote, no
-- per-creature script, and every client sees and hears the same thing.
--
-- Water vs ground is decided by what's under the fish (a raycast that
-- recognises the ocean part by name), not by height - the beach is only a
-- stud or so above the waterline.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local World = require(Shared.Config.World)

local Vfx = require(script.Parent.Parent.Modules.Vfx)
local Sfx = require(script.Parent.Parent.Modules.Sfx)

local CreatureVfxController = {}

-- Must match CreatureService; server modules aren't requireable here.
local CREATURES_FOLDER = "Creatures"
local ATTR_THROWN = "Thrown"
local ATTR_LANDED = "Landed"
local ATTR_FLOPS = "Flops"

local SURFACE_SPLASH = 1.5 -- breaching out of the water at the bobber
local LANDING_SCALE = 1.0
local FLOP_SCALE = 0.7 -- was 0.4; "more noticeable" (user, 2026-08-22)
local FLOP_LAND_DELAY = 0.45 -- seconds after the hop starts that it lands (mirrors Tuning.Creature.FLOP_HOP_*)

-- ============================================================ helpers

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

-- The surface under `position` and whether it's the sea.
local function surfaceUnder(position: Vector3): (Vector3, boolean)
	local hit = Workspace:Raycast(position + Vector3.new(0, 1.5, 0), Vector3.new(0, -8, 0), raycastParams())
	if hit then
		return hit.Position, hit.Instance.Name == World.OCEAN_NAME
	end
	return Vector3.new(position.X, World.WATER_Y, position.Z), true
end

-- `groundSound` names the Sfx catalogue entry for a landing / flop on sand
-- or dock. On the water it's the splash only - no sound (user, 2026-08-22:
-- the splat "doesn't sound good… you don't need sfx for the fish on the
-- water").
local function impact(model: Model, scale: number, groundSound: string)
	local pivot = model:GetPivot().Position
	local point, water = surfaceUnder(pivot)
	if water then
		local at = Vector3.new(point.X, point.Y + 0.2, point.Z)
		Vfx.splash(at, scale)
	else
		local at = point + Vector3.new(0, 0.1, 0)
		Vfx.puff(at, Vfx.Color.sand, scale)
		Sfx.play(groundSound, at)
	end
end

-- ============================================================ per creature

local function watch(model: Instance)
	if not model:IsA("Model") then
		return
	end

	-- Surfacing: it has just appeared at the bobber, out of the water. Splash
	-- only - creatures on the water are silent.
	task.defer(function()
		if model.Parent then
			-- At whatever surface it came out of (the sea, or the lava lake up
			-- in the volcano) - the pivot is THROW_START_HEIGHT above it.
			local pivot = model:GetPivot().Position
			local point = surfaceUnder(pivot)
			Vfx.splash(Vector3.new(pivot.X, point.Y + 0.2, pivot.Z), SURFACE_SPLASH)
		end
	end)

	-- Drips while it's in the air. The body part carries the emitter so the
	-- droplets come off the fish itself as it tumbles.
	task.spawn(function()
		local body = model:WaitForChild("Fish_Body", 5)
		if not body or not body:IsA("BasePart") or not model.Parent then
			return
		end
		local drip = Vfx.drip(body)
		local function refresh()
			drip.Enabled = model:GetAttribute(ATTR_THROWN) == true
		end
		model:GetAttributeChangedSignal(ATTR_THROWN):Connect(refresh)
		refresh()
	end)

	model:GetAttributeChangedSignal(ATTR_LANDED):Connect(function()
		if model:GetAttribute(ATTR_LANDED) then
			impact(model, LANDING_SCALE, "landGround")
		end
	end)

	-- The server ticks Flops at the start of a hop, so this is the push-off;
	-- a second one lands roughly when the hop does (the server's hop length
	-- is FLOP_HOP_MIN..MAX, ~0.45 s) so each flop reads as two beats. On
	-- land each is a soft wet flick; on water just the splash.
	model:GetAttributeChangedSignal(ATTR_FLOPS):Connect(function()
		impact(model, FLOP_SCALE, "flopGround")
		task.delay(FLOP_LAND_DELAY, function()
			if model.Parent then
				impact(model, FLOP_SCALE, "flopGround")
			end
		end)
	end)
end

-- ============================================================ lifecycle

function CreatureVfxController.init() end

function CreatureVfxController.start()
	task.spawn(function()
		local creatures = Workspace:WaitForChild(CREATURES_FOLDER, 30)
		if not creatures then
			warn("[CreatureVfx] no Workspace." .. CREATURES_FOLDER .. " folder; creature effects off")
			return
		end
		creatures.ChildAdded:Connect(watch)
		for _, existing in creatures:GetChildren() do
			watch(existing)
		end
	end)
end

return CreatureVfxController
