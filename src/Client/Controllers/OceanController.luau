--!nonstrict
-- OceanController.luau
-- Everything that makes the water look alive, client-side:
--
--   * the caustics texture layer(s) sliding across the surface, and
--   * the TIDE - waves running up the beach and back out again.
--
-- The tide needs no new geometry and no texture work. The beach is a gentle
-- slope (roughly 0.8 studs of height over 11 studs of width near the
-- shoreline), so raising the flat water plane by a few tenths of a stud
-- sweeps its edge several studs inland - over the darker wet sand and onto
-- the pale dry sand - and lowering it draws the water back out. The foam rim
-- is a separate MeshPart in the island mesh, so it rides along: lifted by the
-- same amount and scaled slightly inward, which keeps the white line on the
-- water's edge instead of stranding it at its baked radius.
--
-- All of it is visual and client-only, deliberately:
--   * replicating a 3000-stud part's CFrame every frame would be pure waste,
--     and the server never moves it, so a local CFrame set is not fought by
--     replication;
--   * gameplay keeps using World.WATER_Y as THE waterline (cast landings,
--     creature grounding, splash heights). The tide is small enough
--     (TIDE.HEIGHT) that the visual surface and that fixed line never
--     disagree enough to see.
--
-- Every number comes from Shared/Config/Ocean.luau - tune there.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Ocean = require(Shared.Config.Ocean)
local World = require(Shared.Config.World)

local OceanController = {}

local TAU = math.pi * 2
local TIDE = Ocean.TIDE

-- Any mesh part whose name contains this rides the tide as the water's edge.
-- Matches the tropical island's `Island_Foam` and any future island's
-- prefixed `<Id>_Foam` (see assets/island_gen.py's naming rule).
local FOAM_MATCH = "Foam"

-- { texture = Texture, config = Ocean.LAYERS[i], part = BasePart }
local layers = {}

-- How far from the camera (studs, XZ) water still animates. The sea is a GRID
-- of ~2040-stud tiles (WorldService.buildOcean - the engine caps one part at
-- 2048 studs, so a single plane was never possible); animating a thousand
-- tiles' CFrames and texture offsets every frame is pure waste when a 0.35
-- stud tide and a 0.35 stud/s drift are invisible past the fog. Tiles beyond
-- this radius hold their resting pose and pattern - the caustics tile repeats
-- every 40 studs and OCEAN_TILE is a multiple of it, so still and moving
-- tiles always line up at the seam.
local ANIMATE_RADIUS = 4500

-- The island's white foam rims, which ride the water up and down.
-- { part, rest = CFrame }
local bands = {}

-- Every part that rides the tide and drifts its caustics: the sea's grid
-- tiles (each named World.OCEAN_NAME) and the interior island waters
-- (Ocean.INTERIOR_WATER_NAMES - the fen pools, ice holes, gloom lake, wreck
-- bay; each dressed by the server exactly like the sea). One list because
-- they move identically. { part, rest = CFrame, lifted = boolean? }
local waters = {}

local elapsed = 0

-- ---------------------------------------------------------------- tide

-- Where the tide is right now, -1 (fully out) .. 1 (fully in). One slow swell
-- plus a smaller faster one at an incommensurate period, so the water never
-- settles into an obvious beat.
local function tideAt(t: number): number
	local swell = math.sin(t * TAU / TIDE.PERIOD)
	local chop = math.sin(t * TAU / TIDE.CHOP_PERIOD)
	return swell * (1 - TIDE.CHOP) + chop * TIDE.CHOP
end

local function trackFoam(part: BasePart)
	for _, entry in bands do
		if entry.part == part then
			return
		end
	end
	table.insert(bands, { part = part, rest = part.CFrame })
end

-- Adopt one interior water part: remember its resting pose for the tide and
-- pick up its caustics layers for the drift. The server creates the layers
-- with the part, so they normally replicate together; the deferred rescan
-- catches a Texture that arrives a beat later.
local function trackWater(part: BasePart)
	for _, entry in waters do
		if entry.part == part then
			return
		end
	end
	table.insert(waters, { part = part, rest = part.CFrame })

	local function adoptLayers()
		for _, config in Ocean.LAYERS do
			local texture = part:FindFirstChild(config.name)
			if texture and texture:IsA("Texture") then
				local known = false
				for _, layer in layers do
					if layer.texture == texture then
						known = true
						break
					end
				end
				if not known then
					table.insert(layers, { texture = texture, config = config, part = part })
				end
			end
		end
	end
	adoptLayers()
	task.delay(3, adoptLayers)
end

local function scanWorld(world: Instance)
	for _, descendant in world:GetDescendants() do
		if descendant:IsA("BasePart") then
			if string.find(descendant.Name, FOAM_MATCH, 1, true) then
				trackFoam(descendant)
			elseif Ocean.INTERIOR_WATER_NAMES[descendant.Name] or descendant.Name == World.OCEAN_NAME then
				trackWater(descendant)
			end
		end
	end
end

-- ---------------------------------------------------------------- per frame

local function step(dt: number)
	elapsed += dt

	local camera = Workspace.CurrentCamera
	local camPos = camera and camera.CFrame.Position
	local function isNear(part: BasePart): boolean
		if not camPos then
			return true
		end
		local dx = part.Position.X - camPos.X
		local dz = part.Position.Z - camPos.Z
		return dx * dx + dz * dz < ANIMATE_RADIUS * ANIMATE_RADIUS
	end

	-- Texture drift (near layers only - see ANIMATE_RADIUS).
	local wobble = math.sin(elapsed * TAU / Ocean.WOBBLE_PERIOD)
	for index, layer in layers do
		if layer.part and (not layer.part.Parent or not isNear(layer.part)) then
			continue
		end
		local config = layer.config
		-- Alternate layers wobble opposite ways so, if there is ever more
		-- than one, they shear against each other instead of sliding in
		-- step. Offsets are kept modulo the tile size so they never grow
		-- large enough to lose float precision after a long session; the
		-- tile repeats, so the wrap is invisible.
		local sign = if index % 2 == 0 then -1 else 1
		local u = elapsed * config.drift.X + wobble * config.wobble * sign
		local v = elapsed * config.drift.Y - wobble * config.wobble * 0.6
		layer.texture.OffsetStudsU = u % config.tileStuds
		layer.texture.OffsetStudsV = v % config.tileStuds
	end

	-- Tide.
	local tide = tideAt(elapsed)
	local lift = tide * TIDE.HEIGHT

	-- The shoreline rim rides the water up and down. Vertical ONLY, on
	-- purpose: an earlier version also scaled the mesh inward to chase the
	-- water's edge across the sand, but setting a MeshPart's Size scales it
	-- about its own bounding-box centre, and the foam mesh's box is dragged
	-- off-island by the dock-post collars baked into it. So scaling slid the
	-- whole ring off the coastline and left the collars floating on open
	-- water as white blobs (user, 2026-08-22: "the foam and sand doesn't line
	-- up"). Lifting keeps every part of the rim exactly where it was authored
	-- relative to the island - alignment can't drift - and the rim still
	-- reads as riding the swell.
	for _, entry in bands do
		if entry.part.Parent then
			entry.part.CFrame = entry.rest + Vector3.new(0, lift, 0)
		end
	end

	-- The sea tiles and interior waters breathe with the same swell.
	-- Visual-only: gameplay keeps using the surface Y the server probed, and
	-- the lift is too small to disagree visibly. Far tiles hold their resting
	-- pose (reset once on the way out so none freezes mid-lift).
	for _, entry in waters do
		if entry.part.Parent then
			if isNear(entry.part) then
				entry.part.CFrame = entry.rest + Vector3.new(0, lift, 0)
				entry.lifted = true
			elseif entry.lifted then
				entry.part.CFrame = entry.rest
				entry.lifted = nil
			end
		end
	end
end

-- ---------------------------------------------------------------- lifecycle

function OceanController.init()
	-- WorldService builds the ocean in its own init(), before any client can
	-- join, so these are short waits in practice; the timeouts just stop a
	-- broken server boot from hanging the client silently.
	local world = Workspace:WaitForChild("World", 10)
	local water = world and world:WaitForChild(World.OCEAN_NAME, 10)
	if not water then
		warn("[OceanController] Workspace.World." .. World.OCEAN_NAME .. " not found; water will not animate")
		return
	end

	-- The sea is a grid of tiles all sharing OCEAN_NAME; the WaitForChild
	-- above is only the sync point ("the server has built the ocean"). The
	-- scan below adopts every tile - trackWater picks up each one's caustics
	-- layers too, and missing layers are expected until the texture is
	-- uploaded (the server already warned with the steps, so stay quiet here).
	-- The islands (and so the foam rims and interior waters) may also still be
	-- replicating, so take what is there now and pick up the rest as it
	-- arrives.
	scanWorld(world)

	-- If the rim never turns up, the water still moves but the shoreline
	-- lines sit still - which looks like a bug and is easy to misread as the
	-- tide being broken. Say so, once, rather than failing silently.
	task.delay(10, function()
		if #bands == 0 then
			warn(
				string.format(
					"[OceanController] No shoreline rim found under Workspace.World "
						.. "(looking for a BasePart whose name contains %q). The water will "
						.. "rise and fall but the foam and wet-sand lines won't follow it. "
						.. "Check that the island model in ReplicatedStorage/Assets still "
						.. "has its Island_Foam part.",
					FOAM_MATCH
				)
			)
		end
	end)

	world.DescendantAdded:Connect(function(descendant)
		if not descendant:IsA("BasePart") then
			return
		end
		local isFoam = string.find(descendant.Name, FOAM_MATCH, 1, true) ~= nil
		local isWater = Ocean.INTERIOR_WATER_NAMES[descendant.Name] == true or descendant.Name == World.OCEAN_NAME
		if isFoam or isWater then
			-- Defer a frame: a part's Size/CFrame can still be settling on the
			-- frame it appears, and those are captured as its resting pose.
			task.defer(function()
				if descendant.Parent then
					if isFoam then
						trackFoam(descendant)
					else
						trackWater(descendant)
					end
				end
			end)
		end
	end)
end

function OceanController.start()
	RunService.Heartbeat:Connect(step)
end

return OceanController
