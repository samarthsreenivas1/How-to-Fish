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
-- stud or so above the waterline. BOTH sides make sound now: the old
-- "creatures on the water are silent" rule was lifted by the user on
-- 2026-09-09 in favour of purpose-made splash and flop cues.
--
-- It also gives each creature a VOICE: an idle call every 6-14 seconds, one
-- cue set per body family, pitched by the animal's size.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local World = require(Shared.Config.World)
local CreatureFamilies = require(Shared.Data.CreatureFamilies)

local Vfx = require(script.Parent.Parent.Modules.Vfx)
local Sfx = require(script.Parent.Parent.Modules.Sfx)

local CreatureVfxController = {}

-- Must match CreatureService; server modules aren't requireable here.
local CREATURES_FOLDER = "Creatures"
local ATTR_THROWN = "Thrown"
local ATTR_LANDED = "Landed"
local ATTR_FLOPS = "Flops"
local ATTR_CREATURE_ID = "CreatureId" -- CreatureService's ATTR.ID; the row id, our key into CreatureFamilies

local IDLE_MIN = 6 -- seconds between a creature's idle calls...
local IDLE_MAX = 14 -- ...and the top of that range; random per call, never a metronome
local IDLE_EARSHOT = 60 -- studs; past this the creature keeps its timer but stays quiet

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

-- `groundSound` and `waterSound` name the Sfx catalogue entries for a landing
-- or flop on sand/dock and on the sea respectively.
--
-- THE WATER IS NO LONGER SILENT. The old rule here (user, 2026-08-22: the
-- splat "doesn't sound good… you don't need sfx for the fish on the water")
-- was splash-VFX-only on water, and it stood because the cue it had was the
-- wrong sound, not because the moment wanted no sound. The user reversed it on
-- 2026-09-09 and asked for splashing and flopping - so the water branch now
-- plays purpose-made cues (`fishSurface` for a body breaking the surface,
-- `flopWater` for one slapping it) rather than the retired splat. splat.wav is
-- still used nowhere.
local function impact(model: Model, scale: number, groundSound: string, waterSound: string)
	local pivot = model:GetPivot().Position
	local point, water = surfaceUnder(pivot)
	if water then
		local at = Vector3.new(point.X, point.Y + 0.2, point.Z)
		Vfx.splash(at, scale)
		Sfx.play(waterSound, at)
	else
		local at = point + Vector3.new(0, 0.1, 0)
		Vfx.puff(at, Vfx.Color.sand, scale)
		Sfx.play(groundSound, at)
	end
end

-- ============================================================ family voices

-- An occasional call from each creature standing near the player, so a beach
-- with fish flopping on it has a voice rather than only impacts. One cue set
-- per body family (CreatureFamilies) instead of per creature, pitched by the
-- animal's size, is what makes 122 creatures affordable to author - see
-- assets/audio_gen/CONTRACT.md §3 sfx_families.
--
-- The timer is per creature and lives on its own thread; it ends itself when
-- the model leaves the world (the server despawns it, or the player walks out
-- of streaming range), so there is nothing to clean up from the outside and
-- nothing to leak. Sfx.play is one-shot - unlike Sfx.loop there is no handle
-- to strand - so a late call after the model goes is at worst one sound.
--
-- The 60-stud cull is a check at FIRING time, not a subscription: the creature
-- keeps its timer while it is far away and simply stays quiet, which costs one
-- distance comparison every ~10 seconds and means it speaks the moment the
-- player walks up without needing to be re-armed.
local function idleVoice(model: Model)
	local family = CreatureFamilies.get(model:GetAttribute(ATTR_CREATURE_ID))
	if not family then
		return -- unknown id, or a creature with no family: it stays silent
	end
	local cue = family .. "Idle"
	local pitch = CreatureFamilies.voicePitch(model:GetAttribute(ATTR_CREATURE_ID))

	task.spawn(function()
		-- A random first wait as well as a random interval: a shoal that
		-- surfaces together would otherwise call in perfect unison forever.
		while model.Parent do
			task.wait(IDLE_MIN + math.random() * (IDLE_MAX - IDLE_MIN))
			if not model.Parent then
				return
			end
			local character = Players.LocalPlayer and Players.LocalPlayer.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				local at = model:GetPivot().Position
				if (at - root.Position).Magnitude <= IDLE_EARSHOT then
					Sfx.play(cue, at, { pitch = pitch })
				end
			end
		end
	end)
end

-- ============================================================ per creature

local function watch(model: Instance)
	if not model:IsA("Model") then
		return
	end

	-- Surfacing: it has just appeared at the bobber, out of the water. Splash
	-- AND sound - the "creatures on the water are silent" rule this block used
	-- to carry was reversed by the user on 2026-09-09 (see `impact` above).
	task.defer(function()
		if model.Parent then
			-- At whatever surface it came out of (the sea, or the lava lake up
			-- in the volcano) - the pivot is THROW_START_HEIGHT above it.
			local pivot = model:GetPivot().Position
			local point = surfaceUnder(pivot)
			local at = Vector3.new(pivot.X, point.Y + 0.2, pivot.Z)
			Vfx.splash(at, SURFACE_SPLASH)
			Sfx.play("fishSurface", at)
		end
	end)

	-- Its voice. Independent of the splash beats above: a slow idle call on
	-- its own timer for as long as it is around and near enough to hear.
	idleVoice(model)

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
			-- Coming down in the sea is a body breaking the surface, so it
			-- takes fishSurface rather than the lighter flop slap.
			impact(model, LANDING_SCALE, "landGround", "fishSurface")
		end
	end)

	-- The server ticks Flops at the start of a hop, so this is the push-off;
	-- a second one lands roughly when the hop does (the server's hop length
	-- is FLOP_HOP_MIN..MAX, ~0.45 s) so each flop reads as two beats. On
	-- land each is a soft wet flick; on water just the splash.
	model:GetAttributeChangedSignal(ATTR_FLOPS):Connect(function()
		impact(model, FLOP_SCALE, "flopGround", "flopWater")
		task.delay(FLOP_LAND_DELAY, function()
			if model.Parent then
				impact(model, FLOP_SCALE, "flopGround", "flopWater")
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
