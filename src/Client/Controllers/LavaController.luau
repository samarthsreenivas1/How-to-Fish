--!nonstrict
-- LavaController.luau
-- Makes the volcano's lava feel ALIVE, entirely client-side (the same idea as
-- OceanController scrolling the sea):
--   * the stylised "yellow lava" texture on a flat disc over the lake, scrolled
--     with a clean steady drift so the crust flows;
--   * big 3D molten bubbles that swell up out of the surface at random points,
--     then burst - releasing a steam puff and a splash of glowing droplets;
--   * a slow emissive shimmer over the glowing mesh (the rim + outflows).
--
-- It finds every "*Lava" part under Workspace/World and dresses it. No server,
-- no remotes, no imported assets - pure local decoration, so it's free to the
-- rest of the game and needs no re-import (works on whatever lava is already
-- in the world). Islands without lava (the starter) simply have none to find.

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local World = require(Shared.Config.World)
local Lava = require(Shared.Config.Lava)

local LavaController = {}

local HOT = Color3.fromRGB(255, 105, 18) -- base molten orange
local BRIGHT = Color3.fromRGB(255, 185, 70) -- shimmer / particle peak
local PARTICLE = "rbxasset://textures/particles/fire_main.dds"

local MAX_VENTS = 40 -- candidate bubble spots on the lava surface; capped for performance
local GRID_STEP = 38 -- studs between candidate vent points

local lavaParts: { BasePart } = {}
local vents: { Vector3 } = {} -- world points on the real lava surface where bubbles rise
local dressed: { [BasePart]: boolean } = {}
-- Scrolling texture layers on the lava surface; animated (drift + churn) so the
-- molten crust flows instead of sitting still. { tex, vx, vy, phase }.
local flowLayers: { { tex: Texture, vx: number, vy: number, phase: number } } = {}

-- ============================================================ 3D bubbles

-- Where transient effect emitters (steam, splash) hang; Terrain always exists
-- and takes world-positioned attachments.
local function effectHost(): Instance
	return lavaParts[1] or Workspace.Terrain
end

-- A puff of steam released when a bubble pops: pale smoke that rises and fades.
local function steamPuff(pos: Vector3, scale: number)
	local a = Instance.new("Attachment")
	a.WorldPosition = pos
	a.Parent = effectHost()

	local e = Instance.new("ParticleEmitter")
	e.Texture = "rbxasset://textures/particles/smoke_main.dds"
	e.Color = ColorSequence.new(Color3.fromRGB(224, 224, 230), Color3.fromRGB(150, 150, 158))
	e.LightEmission = 0.25
	e.Lifetime = NumberRange.new(1.3, 2.4)
	e.Speed = NumberRange.new(5, 10)
	e.Acceleration = Vector3.new(0, 10, 0)
	e.SpreadAngle = Vector2.new(28, 28)
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-45, 45)
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, scale * 0.6),
		NumberSequenceKeypoint.new(1, scale * 2.1),
	})
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(0.2, 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.EmissionDirection = Enum.NormalId.Top
	e.Parent = a
	e:Emit(math.random(14, 20))
	task.delay(3, function()
		a:Destroy()
	end)
end

-- A few glowing molten droplets flung up as the bubble bursts.
local function splash(pos: Vector3, scale: number)
	local a = Instance.new("Attachment")
	a.WorldPosition = pos
	a.Parent = effectHost()

	local e = Instance.new("ParticleEmitter")
	e.Texture = PARTICLE
	e.Color = ColorSequence.new(BRIGHT, HOT)
	e.LightEmission = 1
	e.LightInfluence = 0
	e.Lifetime = NumberRange.new(0.5, 0.9)
	e.Speed = NumberRange.new(9, 17)
	e.Acceleration = Vector3.new(0, -50, 0) -- fling up, fall back
	e.SpreadAngle = Vector2.new(45, 45)
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, scale * 0.5),
		NumberSequenceKeypoint.new(1, 0.2),
	})
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.EmissionDirection = Enum.NormalId.Top
	e.Parent = a
	e:Emit(math.random(6, 10))
	task.delay(1.2, function()
		a:Destroy()
	end)
end

-- One 3D bubble: a molten DOME (a flattened ellipsoid, not a full sphere) that
-- swells up ON the lava surface, then bursts - a quick over-expand + fade -
-- releasing a puff of steam (and a few molten droplets). Its base is kept at the
-- surface so only the dome shows, never a whole sphere floating over the lava.
local function spawnBubble(pos: Vector3)
	local maxD = 5 + math.random() * 6 -- 5..11 studs wide, big enough to read from the rim
	local height = maxD * 0.5 -- flattened -> a dome sitting on the surface
	local centerRise = height * 0.3 -- lifts the dome so its base rests ~on the surface

	local bubble = Instance.new("Part")
	bubble.Name = "LavaBubble"
	bubble.Shape = Enum.PartType.Ball -- non-uniform Size makes it an ellipsoid dome
	bubble.Material = Enum.Material.Neon
	bubble.Color = HOT:Lerp(BRIGHT, math.random())
	bubble.Anchored = true
	bubble.CanCollide = false
	bubble.CanQuery = false
	bubble.CanTouch = false
	bubble.Size = Vector3.new(1, 0.5, 1)
	bubble.CFrame = CFrame.new(pos + Vector3.new(0, 0.2, 0)) -- a small dome at the surface
	bubble.Parent = effectHost()

	local center = pos + Vector3.new(0, centerRise, 0)
	local swell = TweenService:Create(
		bubble,
		TweenInfo.new(0.5 + math.random() * 0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(maxD, height, maxD), CFrame = CFrame.new(center) }
	)
	swell:Play()
	swell.Completed:Connect(function()
		local top = pos + Vector3.new(0, height * 0.8, 0) -- the dome's crown, where it vents
		steamPuff(top, maxD)
		splash(top, maxD * 0.6)
		local pop = TweenService:Create(
			bubble,
			TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = Vector3.new(maxD * 1.2, height * 1.3, maxD * 1.2), Transparency = 1 }
		)
		pop:Play()
		pop.Completed:Connect(function()
			bubble:Destroy()
		end)
	end)
end

-- ============================================================ setup

-- Scatter vents across a lava part's REAL surface: a grid over its footprint,
-- each point raycast straight down onto ONLY that part. Keeping just the hits
-- lands vents on the crater lake and the outflow channels, never on the
-- surrounding rock (the part's bounding box is much larger than the lava).
local function ventsFor(part: BasePart)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { part }
	params.IgnoreWater = true

	local size = part.Size
	local nx = math.clamp(math.floor(size.X / GRID_STEP), 1, 14)
	local nz = math.clamp(math.floor(size.Z / GRID_STEP), 1, 14)
	local topY = part.Position.Y + size.Y + 20
	local reach = size.Y + 60

	for ix = 0, nx do
		for iz = 0, nz do
			if #vents >= MAX_VENTS then
				return
			end
			local lx = (ix / nx - 0.5) * size.X
			local lz = (iz / nz - 0.5) * size.Z
			local spot = part.CFrame * CFrame.new(lx, 0, lz)
			local from = Vector3.new(spot.X, topY, spot.Z)
			local hit = Workspace:Raycast(from, Vector3.new(0, -reach, 0), params)
			if hit then
				table.insert(vents, hit.Position + Vector3.new(0, 0.1, 0))
			end
		end
	end
end

-- Detect the flat crater-lake surface on a lava part: grid-raycast onto it and
-- keep the highest cluster of hits (the flat lake, above the sloping outflow
-- channels), then take their centroid + spread as the lake's centre and radius.
local function lakeInfo(part: BasePart)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { part }
	params.IgnoreWater = true

	local size = part.Size
	local topY = part.Position.Y + size.Y + 20
	local reach = size.Y + 60
	local nx = math.clamp(math.floor(size.X / 24), 2, 26)
	local nz = math.clamp(math.floor(size.Z / 24), 2, 26)

	local hits = {}
	local maxY = -math.huge
	for ix = 0, nx do
		for iz = 0, nz do
			local lx = (ix / nx - 0.5) * size.X
			local lz = (iz / nz - 0.5) * size.Z
			local spot = part.CFrame * CFrame.new(lx, 0, lz)
			local hit = Workspace:Raycast(Vector3.new(spot.X, topY, spot.Z), Vector3.new(0, -reach, 0), params)
			if hit then
				table.insert(hits, hit.Position)
				maxY = math.max(maxY, hit.Position.Y)
			end
		end
	end
	if #hits == 0 then
		return nil
	end

	local sx, sz, n = 0, 0, 0
	local disc = {}
	for _, p in hits do
		if p.Y >= maxY - 4 then -- the flat lake, not the lower outflow channels
			table.insert(disc, p)
			sx, sz, n = sx + p.X, sz + p.Z, n + 1
		end
	end
	if n == 0 then
		return nil
	end
	local cx, cz = sx / n, sz / n
	local r = 0
	for _, p in disc do
		r = math.max(r, math.sqrt((p.X - cx) ^ 2 + (p.Z - cz) ^ 2))
	end
	return { center = Vector3.new(cx, maxY, cz), radius = r }
end

-- A flat textured disc laid on the lake surface - the "yellow lava" plates. A
-- Texture on a Part's face tiles by studs with NO UVs (the same way the ocean
-- is textured), which renders reliably where a runtime MaterialVariant did not.
-- It goes on both circular caps so whichever ends up facing up is covered.
local function buildOverlay(part: BasePart, info)
	if Lava.TEXTURE_ID == 0 then
		return
	end
	local surface = Instance.new("Part")
	surface.Name = "LavaSurface"
	surface.Shape = Enum.PartType.Cylinder
	surface.Anchored = true
	surface.CanCollide = false
	surface.CanQuery = false
	surface.CanTouch = false
	surface.Material = Enum.Material.SmoothPlastic
	surface.Color = Lava.TINT -- show the texture as authored
	surface.Size = Vector3.new(0.3, info.radius * 2, info.radius * 2)
	surface.CFrame = CFrame.new(info.center.X, info.center.Y + 0.15, info.center.Z) * CFrame.Angles(0, 0, math.rad(90))
	surface.Parent = part

	-- One clean layer per up-facing cap, drifting steadily - the crust flows in
	-- one direction without the busy churn of overlapping layers. Both caps are
	-- covered since only one faces up.
	local function addLayer(face: Enum.NormalId)
		local tex = Instance.new("Texture")
		tex.Face = face
		tex.Texture = "rbxassetid://" .. tostring(Lava.TEXTURE_ID)
		tex.StudsPerTileU = Lava.STUDS_PER_TILE
		tex.StudsPerTileV = Lava.STUDS_PER_TILE
		tex.Parent = surface
		table.insert(flowLayers, { tex = tex, vx = 1.8, vy = 1.0, phase = 0 })
	end
	addLayer(Enum.NormalId.Right)
	addLayer(Enum.NormalId.Left)
end

local function dress(part: BasePart)
	if dressed[part] then
		return
	end
	dressed[part] = true
	-- The mesh lava is a bright molten glow (Neon); the textured disc sits on the
	-- flat lake over it, and the glow shows at the jagged rim and outflows.
	part.Material = Enum.Material.Neon
	part.Color = Lava.FALLBACK_COLOR
	table.insert(lavaParts, part)
	ventsFor(part)
	local info = lakeInfo(part)
	if info then
		buildOverlay(part, info)
	end
end

local function scan(root: Instance)
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") and string.find(d.Name, "Lava", 1, true) then
			dress(d)
		end
	end
end

-- ============================================================ loops

-- Randomly raise 3D bubbles at surface points, spaced out in time so a few
-- swell and pop across the lake at any moment rather than all at once.
local function bubbleLoop()
	while true do
		task.wait(0.5 + math.random() * 1.3)
		if #vents > 0 then
			spawnBubble(vents[math.random(#vents)])
		end
	end
end

-- Slow molten shimmer across the whole pool - pulses the glowing mesh lava
-- (the base + the rim/outflows the textured disc doesn't cover).
local function shimmer()
	local k = (math.sin(os.clock() * 1.4) + 1) * 0.5
	local c = Lava.FALLBACK_COLOR:Lerp(BRIGHT, k * 0.4)
	for _, p in lavaParts do
		if p.Parent then
			p.Color = c
		end
	end
end

-- Scroll the texture with a steady, clean drift so the crust flows in one
-- direction - no churn, no wobble.
local function flow()
	local t = os.clock()
	for _, layer in flowLayers do
		if layer.tex.Parent then
			layer.tex.OffsetStudsU = layer.vx * t
			layer.tex.OffsetStudsV = layer.vy * t
		end
	end
end

-- ============================================================ lifecycle

function LavaController.init() end

function LavaController.start()
	-- Everything here is decorative; pcall the synchronous work so a lava error
	-- can never throw out of start() and halt the boot loop (which would take
	-- every controller after this one down with it).
	local world = Workspace:FindFirstChild(World.FOLDER_NAME)
	if world then
		pcall(scan, world)
		-- Catch a lava part that streams / is placed after we start.
		world.DescendantAdded:Connect(function(d)
			if d:IsA("BasePart") and string.find(d.Name, "Lava", 1, true) then
				pcall(dress, d)
			end
		end)
	end

	task.spawn(bubbleLoop) -- its own thread; errors there can't halt the boot
	RunService.Heartbeat:Connect(shimmer) -- runs in its own thread too
	RunService.RenderStepped:Connect(flow) -- smooth per-frame texture scroll
end

return LavaController
