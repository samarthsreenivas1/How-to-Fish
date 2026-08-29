--!nonstrict
-- BrinejawBodyController.luau
-- Draws Brinejaw: ~100 parts laid along the curve its pose describes.
--
-- The server keeps only authority - a hidden model at the head for hits and
-- the HUD - and publishes the pose as six attributes (Coil, Unwind,
-- SweepAngle, SweepHeight, Slump, FaceAngle). This controller turns those
-- into a serpent: BrinejawPath says what shape the body is in, ChainPose
-- walks that shape by arc length, and every frame each vertebra gets one
-- CFrame. Both sides read the same math, so the tail you dodge and the tail
-- you see are the same tail.
--
-- Nothing here is a decision: no timers, no local guesses about what the
-- boss is doing. The attributes step, this eases toward them, and that is
-- the whole contract. Which is why the tail can lash across the arena
-- without anything spawning - the coils and the sweep are one chain, and an
-- attack only changes the curve.
--
-- Pieces come from ReplicatedStorage/Assets/BrinejawPack (assets/boss_gen.py)
-- and fall back to plain tinted blocks until that import lands, so the fight
-- is never invisible.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BrinejawPath = require(Shared.Modules.BrinejawPath)
local ChainPose = require(Shared.Modules.ChainPose)

local BrinejawBodyController = {}

local CREATURES_FOLDER = "Creatures"
local PACK_NAME = "BrinejawPack"
local FOLDER_NAME = "BrinejawBody"

-- Studs between vertebra centres at full scale, from the pack's HANDOFF.
local SPACING = 3.4
-- Every Nth vertebra is the finned variant, for silhouette.
local FIN_EVERY = 4
-- The head sits this far up-body of the chain's start (the mesh is centred
-- on its neck joint and reaches forward from there).
local HEAD_LEAD = 8.9
local HEAD_SCALE = 1.35
local TAIL_SCALE = 0.55
local TAPER = 0.62

-- How fast the drawn pose chases the replicated one. The server steps these
-- values; easing is what makes a step look like a serpent moving.
local EASE = { unwind = 6.0, sweepAngle = 14.0, sweepHeight = 7.0, slump = 5.0, faceAngle = 5.0, coil = 1.6 }

local HEAD_PIECES = { "Head", "HeadBone", "Eyes", "Frill", "Jaw", "JawBone" }

local FALLBACK_COLOR = {
	Head = Color3.fromRGB(33, 66, 77),
	HeadBone = Color3.fromRGB(222, 217, 191),
	Eyes = Color3.fromRGB(255, 179, 46),
	Frill = Color3.fromRGB(43, 102, 107),
	Jaw = Color3.fromRGB(33, 66, 77),
	JawBone = Color3.fromRGB(222, 217, 191),
	Seg = Color3.fromRGB(33, 66, 77),
	SegFin = Color3.fromRGB(33, 66, 77),
	Rattle = Color3.fromRGB(194, 184, 153),
}
local FALLBACK_SIZE = {
	Head = Vector3.new(15, 5, 8),
	HeadBone = Vector3.new(14, 4, 7),
	Eyes = Vector3.new(2, 2, 6),
	Frill = Vector3.new(6, 6, 11),
	Jaw = Vector3.new(13, 3, 6),
	JawBone = Vector3.new(11, 2, 6),
	Seg = Vector3.new(4.6, 5, 5),
	SegFin = Vector3.new(4.6, 8, 9),
	Rattle = Vector3.new(11, 5, 5),
}

-- model -> the live body { folder, chain, state, target, segments, head, rattle }
local bodies = {}

-- ---------------------------------------------------------------- pieces

local function packPiece(name: string): BasePart?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local pack = assets and assets:FindFirstChild(PACK_NAME)
	local piece = pack and pack:FindFirstChild("Brinejaw_" .. name, true)
	return if piece and piece:IsA("BasePart") then piece else nil
end

-- One drawable piece: the authored mesh if it is imported, else a block of
-- roughly its bulk so the serpent still reads.
local function makePiece(name: string, parent: Instance): BasePart
	local template = packPiece(name)
	local part
	if template then
		part = template:Clone()
	else
		part = Instance.new("Part")
		part.Size = FALLBACK_SIZE[name] or Vector3.new(4, 4, 4)
		part.Color = FALLBACK_COLOR[name] or Color3.fromRGB(33, 66, 77)
		part.Material = Enum.Material.SmoothPlastic
	end
	part.Name = "Brinejaw_" .. name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.Parent = parent
	return part
end

-- Place one piece, scaling from the size it was authored at.
local function applyPiece(part: BasePart, cframe: CFrame, scale: number)
	local base = part:GetAttribute("BaseSize")
	if not base then
		base = part.Size
		part:SetAttribute("BaseSize", base)
	end
	part.CFrame = cframe
	part.Size = base * scale
end

-- ---------------------------------------------------------------- pose

local function readTarget(model: Model, target)
	target.coil = model:GetAttribute("Coil") or BrinejawPath.MAX_COIL
	target.unwind = model:GetAttribute("Unwind") or 0
	target.sweepAngle = model:GetAttribute("SweepAngle") or 0
	target.sweepHeight = model:GetAttribute("SweepHeight") or BrinejawPath.SWEEP_LOW
	target.slump = model:GetAttribute("Slump") or 0
	target.faceAngle = model:GetAttribute("FaceAngle") or 0
	return target
end

local function approach(current: number, goal: number, rate: number, dt: number): number
	return current + (goal - current) * math.clamp(rate * dt, 0, 1)
end

-- Angles have to take the short way round, or a sweep crossing north
-- unwinds the whole body backwards through the arena.
local function approachAngle(current: number, goal: number, rate: number, dt: number): number
	local delta = (goal - current + math.pi) % (math.pi * 2) - math.pi
	return current + delta * math.clamp(rate * dt, 0, 1)
end

-- ---------------------------------------------------------------- lifecycle

local function destroyBody(model: Model)
	local body = bodies[model]
	if not body then
		return
	end
	bodies[model] = nil
	if body.folder then
		body.folder:Destroy()
	end
end

local function adoptBoss(model: Model)
	if bodies[model] or model:GetAttribute("Pose") ~= "brinejaw" then
		return
	end

	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = Workspace

	-- The arena centre is the TOWER'S FOOT, not wherever the head is right
	-- now, so it comes from the server rather than from the model's pivot.
	local state = BrinejawPath.newState(model:GetAttribute("PoseCenter") or model:GetPivot().Position)
	readTarget(model, state)

	local body = {
		folder = folder,
		state = state,
		target = readTarget(model, {}),
		chain = ChainPose.new(function(s, t)
			return BrinejawPath.pointAt(s, t)
		end),
		segments = {},
		head = {},
	}

	for _, name in HEAD_PIECES do
		body.head[name] = makePiece(name, folder)
	end
	body.rattle = makePiece("Rattle", folder)

	bodies[model] = body
	model.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			destroyBody(model)
		end
	end)
end

-- ---------------------------------------------------------------- per frame

local function drawBody(model: Model, body, dt: number, now: number)
	local state, target = body.state, readTarget(model, body.target)
	state.coil = approach(state.coil, target.coil, EASE.coil, dt)
	state.unwind = approach(state.unwind, target.unwind, EASE.unwind, dt)
	state.sweepAngle = approachAngle(state.sweepAngle, target.sweepAngle, EASE.sweepAngle, dt)
	state.sweepHeight = approach(state.sweepHeight, target.sweepHeight, EASE.sweepHeight, dt)
	state.slump = approach(state.slump, target.slump, EASE.slump, dt)
	state.faceAngle = approachAngle(state.faceAngle, target.faceAngle, EASE.faceAngle, dt)
	state.time = now

	local chain = body.chain
	chain:update(state)

	-- Body: one CFrame per vertebra, tapering toward the tail.
	local used = 0
	chain:each(SPACING, function(index, cframe, u)
		used = index
		local segment = body.segments[index]
		if not segment then
			segment = makePiece(if index % FIN_EVERY == 2 then "SegFin" else "Seg", body.folder)
			body.segments[index] = segment
		end
		applyPiece(segment, cframe, 1 - TAPER * u ^ 1.3)
	end)
	-- The chain shortens as the tail winds back onto the tower; park the
	-- spares rather than churning parts every frame.
	for index = used + 1, #body.segments do
		body.segments[index].CFrame = CFrame.new(0, -5000, 0)
	end

	-- Head cluster: every piece shares the neck joint's frame, ahead of the
	-- chain's start so the skull reaches out past it.
	local headFrame = chain:cframeAt(0) * CFrame.new(HEAD_LEAD, 0, 0)
	for _, name in HEAD_PIECES do
		applyPiece(body.head[name], headFrame, HEAD_SCALE)
	end

	-- Rattle: on the tail's tip, trailing off the end of the chain.
	applyPiece(body.rattle, chain:cframeAt(chain.length) * CFrame.new(-1.4, 0, 0), TAIL_SCALE)
end

-- Adopt now if the model already says what it is, and again if it says so
-- later: the model replicates before its first server frame sets `Pose`, so
-- one or the other of these is always the one that fires.
local function watch(child: Instance)
	if not child:IsA("Model") then
		return
	end
	adoptBoss(child)
	child:GetAttributeChangedSignal("Pose"):Connect(function()
		adoptBoss(child)
	end)
end

function BrinejawBodyController.init()
	task.spawn(function()
		local folder = Workspace:WaitForChild(CREATURES_FOLDER, 30)
		if not folder then
			return
		end
		for _, child in folder:GetChildren() do
			watch(child)
		end
		folder.ChildAdded:Connect(watch)
	end)
end

function BrinejawBodyController.start()
	RunService.RenderStepped:Connect(function(dt)
		local now = os.clock()
		for model, body in bodies do
			if model.Parent then
				drawBody(model, body, dt, now)
			else
				destroyBody(model)
			end
		end
	end)
end

return BrinejawBodyController
