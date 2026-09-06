--!nonstrict
-- BrinejawBodyController.luau
-- Draws Brinejaw: ~100 parts laid along the curve its pose describes.
--
-- The server keeps only authority - a hidden model at the head for hits and
-- the HUD - and publishes the pose as TEN attributes (Coil, Unwind,
-- SweepAngle, SweepHeight, Slump, FaceAngle, AttackKind, AttackU, AimX,
-- AimZ). This controller turns those into a serpent: BrinejawPath says what
-- shape the body is in, ChainPose walks that shape by arc length, and every
-- frame each vertebra gets one CFrame. Both sides read the same math, so the
-- tail you dodge and the tail you see are the same tail.
--
-- The last four attributes are the ATTACK CHANNEL, and they also drive three
-- ground telegraphs from this file (the lunge's countdown, the undertow's
-- bulge, the spiral's closing edge) - drawn from the same twins the server
-- hit-tests with, so no marker here can promise ground the damage disagrees
-- with. The five attacks whose geometry is not a pose come through
-- `fireEvent` instead and are drawn by CreatureEventController.
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
local MeshColors = require(Shared.Config.MeshColors)
local ChainPose = require(Shared.Modules.ChainPose)
local Vfx = require(script.Parent.Parent.Modules.Vfx)

local BrinejawBodyController = {}

local CREATURES_FOLDER = "Creatures"
local PACK_NAME = "BrinejawPack"
local FOLDER_NAME = "BrinejawBody"

-- Studs between vertebra centres at full scale, from the pack's HANDOFF.
-- One vertebra per 1% of the body, however long the body currently is.
local BODY_LINKS = 100
-- Each link runs a little longer than its share of the curve so neighbours
-- interpenetrate at the joints instead of gapping on the outside of a bend.
local OVERLAP = 1.35
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
-- sweepAngle EARNS its outlier. The lag of a first-order filter chasing a
-- RAMP is speed/rate, and that is framerate-independent: at 14 the drawn arm
-- trailed the damaging one by 130.8/14 = 9.3 degrees, which at the 66-stud
-- tip is 10.8 studs against a lane only 6.8 wide - the arm you SAW was
-- entirely outside the arm that KILLED you past r=41. At 55 the lag is 2.4
-- degrees / 2.7 studs, inside the lane at every radius. The others chase
-- steps rather than ramps, so their rates are about how soft a move looks.
local EASE = { unwind = 6.0, sweepAngle = 55.0, sweepHeight = 7.0, slump = 5.0, faceAngle = 5.0, coil = 1.6 }

local HEAD_PIECES = { "Head", "HeadBone", "Eyes", "Frill", "Jaw", "JawBone" }
-- The two pieces that hinge, and where. boss_gen prints the pivot in its
-- HANDOFF as Blender (-5.6, 0, -1.4); the pack's Y-up export maps that to
-- Roblox (x, z, -y). Authoring a hinge and then never using it is how a boss
-- ends up with a beautifully toothed mouth welded permanently shut.
local JAW_PIECES = { Jaw = true, JawBone = true }
local JAW_HINGE = Vector3.new(-5.6, -1.4, 0)
local JAW_MAX = math.rad(34)

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
	local partName = "Brinejaw_" .. name
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
	-- REPAINT the imported piece. Studio's glTF importer does not carry colour
	-- across - a cloned pack part arrives at Roblox's default grey - so before
	-- this the serpent imported as a grey worm while the FALLBACK blocks it
	-- replaced were correctly coloured. That is the worst way round: importing
	-- the real mesh made the boss look worse, which reads as the import having
	-- failed rather than as a missing repaint.
	--
	-- `MeshColors` is generated from boss_gen itself, so a piece added by a
	-- re-export cannot be quietly left grey - it means re-running the tool.
	local color = MeshColors.get(partName)
	if color then
		part.Color = color
		-- A textured PBR surface would override Color outright; the pack is one
		-- flat material per object and never authors one.
		local appearance = part:FindFirstChildWhichIsA("SurfaceAppearance")
		if appearance then
			appearance:Destroy()
		end
	end
	-- The pack's glTF round trip drops materials, and the boss path clones
	-- pack parts with no Neon-by-name rule (boss_gen's own HANDOFF warns
	-- about it), so the amber eyes arrive matte and unlit. Two sibling
	-- controllers already assert this for the same reason.
	-- BY NAME, not by a list of names. This matched the literal "Eyes", which
	-- is correct for the pack as it stands and silently wrong for the pack as
	-- it changes: an emissive piece added by a re-export arrives matte, and
	-- nothing says so. `BossArenaService` already settled the general form for
	-- arena meshes - an object whose NAME contains `Glow` is Neon, marker on
	-- the object rather than the material - and this is that rule for boss
	-- packs, so both halves of an import obey one convention.
	--
	-- `Eyes` is grandfathered because boss_gen authored it before the marker
	-- existed. When that object is renamed on its next export, this line
	-- becomes the substring test alone.
	if string.find(name, "Glow", 1, true) or name == "Eyes" then
		part.Material = Enum.Material.Neon
	end
	part.Name = partName
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
	-- The attack channel. THESE FOUR ARE COPIED, NOT EASED, and each for its
	-- own reason - see `drawBody`.
	target.attackKind = model:GetAttribute("AttackKind") or ""
	target.attackU = model:GetAttribute("AttackU") or 0
	target.aimX = model:GetAttribute("AimX") or 0
	target.aimZ = model:GetAttribute("AimZ") or 0
	return target
end

-- EXPONENTIAL, not `rate * dt`. The linear form closes a fixed FRACTION of
-- the gap per second only while dt is small; on a hitch it races toward 1 and
-- the body SNAPS - precisely when a snap is most visible. `1 - e^-rt` is the
-- same curve sampled correctly at any step, and it cannot overshoot.
local function approach(current: number, goal: number, rate: number, dt: number): number
	return current + (goal - current) * (1 - math.exp(-rate * dt))
end

-- Angles have to take the short way round, or a sweep crossing north
-- unwinds the whole body backwards through the arena.
local function approachAngle(current: number, goal: number, rate: number, dt: number): number
	local delta = (goal - current + math.pi) % (math.pi * 2) - math.pi
	return current + delta * (1 - math.exp(-rate * dt))
end

-- ---------------------------------------------------------------- telegraphs
--
-- Three of the six attack kinds have to say what they are doing from ground
-- level, and none of them can do it through an event: their geometry is a
-- function of the pose channel every frame (where Aim is, how far along the
-- bulge has got, how far the closing arm still reaches). So they are drawn
-- HERE, out of `state`, by the same twins the server hit-tests with.
--
-- THE COUNTDOWN ENDS AT THE DAMAGE. This is the codebase's most-repeated
-- defect - a tell that finishes at the end of the windup, so the ring closes,
-- players read "it's over" and walk back in, and the blow lands a quarter of a
-- second later on top of them. Brinejaw's lunge strikes at LUNGE_IMPACT_U =
-- 0.50, NOT at LUNGE_COCK_U = 0.35 where the windup ends, so the closing disc
-- below is driven by u / LUNGE_IMPACT_U and reaches zero on the frame the
-- skull lands. The footprint then STAYS through the punish window (0.50..0.72,
-- the skull planted on the sand) because the ground under a resting head is
-- still where the head is.
local TELL = {
	-- The lunge borrows the slam's orange: this fight has already taught that
	-- orange on the sand means "something is coming down here".
	lunge = Color3.fromRGB(255, 122, 60),
	count = Color3.fromRGB(255, 214, 110), -- the countdown, in the payoff gold
	-- The closing spiral borrows the HIGH sweep's cyan, because it is the same
	-- arm: the marker says how far out that arm still reaches.
	spiral = Color3.fromRGB(120, 236, 255),
	sand = Color3.fromRGB(228, 208, 160), -- Vfx.Color.sand, for the bulge
}

local TELL_PARKED = CFrame.new(0, -5000, 0)
-- The closing ring is 24 segments. At the sweep's full 66-stud reach a
-- 24-gon's sagitta is 66 * (1 - cos(pi/24)) = 0.56 studs, well inside the
-- arm's 3.4 girth, so the polygon never promises ground the curve does not.
local SPIRAL_SEGS = 24
local SPIRAL_SEG_THICK = 0.9
local UNDERTOW_DUST_INTERVAL = 0.06 -- sand thrown up by the crest, per plume

local function makeTell(body, key: string, color: Color3, shape: Enum.PartType): Part
	local part = body.tells[key]
	if part then
		return part
	end
	part = Instance.new("Part")
	part.Name = "BrinejawTell_" .. key
	part.Shape = shape
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = 1
	part.Size = Vector3.new(1, 1, 1)
	part.CFrame = TELL_PARKED
	part.Parent = body.folder
	body.tells[key] = part
	return part
end

-- A flat disc lying on the ground: a cylinder stood on its end, which is the
-- idiom Vfx.shockwave and the stagger window already use.
local function layDisc(part: Part, at: Vector3, radius: number, alpha: number)
	part.Size = Vector3.new(0.12, radius * 2, radius * 2)
	part.CFrame = CFrame.new(at) * CFrame.Angles(0, 0, math.rad(90))
	part.Transparency = alpha
end

local function parkTells(body)
	for _, part in body.tells do
		part.Transparency = 1
		part.CFrame = TELL_PARKED
	end
end

-- One frame of whatever the current kind is telling the arena. Everything
-- here is created lazily - a fight that never lunges never builds a lunge
-- ring - and everything is parked before it is drawn, so a kind that ends
-- (or a boss that dies mid-attack) leaves nothing behind.
local function drawTells(body, state, now: number)
	parkTells(body)
	local kind = state.attackKind or ""
	local u = math.clamp(state.attackU or 0, 0, 1)
	local pulse = 0.5 + 0.5 * math.sin(now * 11)

	if kind == "lunge" then
		local at = BrinejawPath.lungeImpactPoint(state) + Vector3.new(0, 0.12, 0)
		local radius = BrinejawPath.LUNGE_RADIUS
		-- The footprint: solid from the first frame, and it does not move after
		-- the server freezes Aim at LUNGE_COCK_U. It outlives the blow by the
		-- punish window's own length and fades out over the recovery ramp.
		local fade = math.clamp((u - 0.72) / (1 - 0.72), 0, 1)
		layDisc(makeTell(body, "lungeRing", TELL.lunge, Enum.PartType.Cylinder), at, radius, 0.44 + 0.56 * fade)
		if u < BrinejawPath.LUNGE_IMPACT_U then
			-- ...and the clock, closing to nothing AT the blow.
			local left = 1 - u / BrinejawPath.LUNGE_IMPACT_U
			layDisc(
				makeTell(body, "lungeCount", TELL.count, Enum.PartType.Cylinder),
				at + Vector3.new(0, 0.08, 0),
				math.max(radius * left, 0.05),
				0.30 + 0.18 * pulse
			)
		end
	elseif kind == "undertow" then
		local at = BrinejawPath.undertowPoint(state)
		local radius = BrinejawPath.UNDERTOW_RADIUS
		-- The disc the server's damage circle is, riding the SAME point the
		-- body's buried crest is drawn from - one call, one place.
		layDisc(
			makeTell(body, "underRing", TELL.sand, Enum.PartType.Cylinder),
			at + Vector3.new(0, 0.12, 0),
			radius,
			0.40 + 0.16 * pulse
		)
		-- ...and the sand it is shoving. A bulge under a beach is only legible
		-- because the ground reacts, so this throws a plume at the crest every
		-- UNDERTOW_DUST_INTERVAL rather than sitting still and glowing.
		if now >= (body.nextDustAt or 0) then
			body.nextDustAt = now + UNDERTOW_DUST_INTERVAL
			Vfx.puff(at + Vector3.new(0, 1.2, 0), TELL.sand, 1.5)
		end
	elseif kind == "spiral" then
		-- THE LANE'S OUTER EDGE, live. `sweepReach` is the same function the
		-- body's tip is drawn at and `sweepHits` rejects a player outside, so
		-- this ring is literally the boundary of the attack: it starts at the
		-- full 66-stud reach and closes to SWEEP_INNER + SPIRAL_CLOSE, and the
		-- ground it leaves behind it is ground the arm can no longer touch.
		local reach = BrinejawPath.sweepReach(state)
		local center = state.center or Vector3.zero
		local span = (math.pi * 2 * reach) / SPIRAL_SEGS
		for i = 1, SPIRAL_SEGS do
			local theta = (i - 0.5) / SPIRAL_SEGS * math.pi * 2
			local part = makeTell(body, "spiral" .. i, TELL.spiral, Enum.PartType.Block)
			local ground = center.Y + BrinejawPath.sandY(reach)
			part.Size = Vector3.new(SPIRAL_SEG_THICK, 0.5, span * 1.08)
			part.CFrame = CFrame.new(
				center.X + math.cos(theta) * reach,
				ground + 0.14,
				center.Z + math.sin(theta) * reach
			) * CFrame.Angles(0, -theta, 0)
			part.Transparency = 0.34 + 0.2 * pulse
		end
	end
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
		-- The attribute-driven telegraphs' pooled parts, built on first use.
		tells = {},
		nextDustAt = 0,
		-- The last EASED sweep bearing, for the whip's drag term: `sweepRate` is
		-- the derivative of a value that is replicated, so it is differentiated
		-- rather than sent (BrinejawPath's contract header).
		lastSweepAngle = state.sweepAngle,
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

	-- THE ATTACK CHANNEL IS COPIED RAW, and that is a decision, not an
	-- oversight on the four values that got no EASE row.
	--
	-- AttackU IS PHASE, NOT POSITION. Every kind's meaning is pinned to an
	-- exact value of it - the skull lands at 0.50, the bell is struck at 0.55 -
	-- and those are the same instants the server deals damage on. A filter
	-- delays phase: even at the sweep's aggressive rate 55, a lunge's strike
	-- ramp (0.15 of U in ~0.35 s, so 0.43 U/s) lags by 0.43/55 = 0.008 U,
	-- which is 18 ms of skull arriving after the damage. Worse, an exponential
	-- filter never ARRIVES: `attackEnvelope` fades an attack out on (1 - u) /
	-- exit, so an eased U that stalls at 0.995 leaves the body 2% short of rest
	-- at the instant the server clears the kind, and the pose SNAPS - the exact
	-- failure the path's header warns about. The attribute steps at the
	-- server's own rate, so raw U is at worst one frame of stair; a stair in
	-- phase is honest and a lie about phase is not.
	--
	-- Aim is raw for the drawn==lethal rule: `lungeImpactPoint` is computed
	-- from these two numbers on BOTH sides, so an eased aim would put the
	-- client's countdown ring metres from the server's damage disc for the
	-- whole tracking window (U 0..0.35). The server freezes Aim at
	-- LUNGE_COCK_U, which is what makes the tracking read smooth without any
	-- help from here.
	state.attackKind = target.attackKind
	state.attackU = target.attackU
	state.aimX = target.aimX
	state.aimZ = target.aimZ

	-- The whip's drag, EXACTLY as the header prescribes: differentiate the
	-- EASED angle (not the target - the drawn arm is what has to curve) and
	-- push it through the one shared WHIP_TAU filter, so the client's rate and
	-- the server's cannot diverge by more than 0.876 studs at the 66-stud tip.
	if dt > 0 then
		local raw = BrinejawPath.wrapAngle(state.sweepAngle - body.lastSweepAngle) / dt
		BrinejawPath.stepSweepRate(state, raw, dt)
	end
	body.lastSweepAngle = state.sweepAngle

	drawTells(body, state, now)

	local chain = body.chain
	chain:update(state)

	-- Body: one CFrame per vertebra, tapering toward the tail.
	-- A FIXED LINK COUNT, not a fixed spacing. Dividing the curve by SPACING
	-- meant the part count changed with the curve's length every frame, and
	-- three separate artifacts fell out of that: the tip flickered a
	-- 3.4-stud hole on and off around 16 Hz as the count quantized, two
	-- dozen vertebrae resampled their taper and visibly shrank by up to a
	-- third mid-sweep, and the spares had to be parked under the map. A
	-- constant count gives every vertebra a stable identity and a stable
	-- girth for the whole fight; only its LENGTH breathes, which is what a
	-- real spine does anyway.
	chain:eachN(BODY_LINKS, function(index, cframe, u, spacing)
		local segment = body.segments[index]
		if not segment then
			segment = makePiece(if index % FIN_EVERY == 2 then "SegFin" else "Seg", body.folder)
			body.segments[index] = segment
		end
		local base = segment:GetAttribute("BaseSize")
		if not base then
			base = segment.Size
			segment:SetAttribute("BaseSize", base)
		end
		-- Taper touches GIRTH only. Scaling length by it as well is what
		-- turned the back half into a dotted line: 1.75-stud beads with
		-- 1.65-stud gaps between them. Length covers this link's share of
		-- the curve with enough overlap that the joints never open.
		local girth = 1 - TAPER * u ^ 1.3
		segment.CFrame = cframe
		segment.Size = Vector3.new(math.max(spacing * OVERLAP, 0.2), base.Y * girth, base.Z * girth)
	end)
	-- No parking loop any more: the count is constant, so there is never a
	-- spare to hide.

	-- Head cluster: every piece shares the neck joint's frame, ahead of the
	-- chain's start so the skull reaches out past it.
	local headFrame = chain:cframeAt(0) * CFrame.new(HEAD_LEAD, 0, 0)

	-- How wide the mouth is, entirely from state the client already has: a
	-- slow idle working of the jaw, opening as the tail comes off the tower
	-- (it is winding up to something), and wide when the head is down - the
	-- roar of a serpent that has just lost its grip.
	-- Never allowed to saturate. The first version peaked at 1.06 whenever
	-- unwind and slump were both pinned - which is the whole punish window -
	-- so `clamp` ate the only varying term and the jaw hung welded OPEN at
	-- max for 45% of it: the mirror image of the welded-shut bug it replaced.
	-- The working now GROWS when the head is down instead of being replaced
	-- by a constant, and the total stays under 1.
	local slump = state.slump or 0
	local gape = math.clamp(
		0.05 + 0.20 * (1 + slump) * (math.sin(state.time * 2.2) * 0.5 + 0.5) + 0.20 * (state.unwind or 0) + 0.34 * slump,
		0,
		1
	)
	-- The hinge lives in the mesh's own frame, so it scales with the head.
	local hinge = JAW_HINGE * HEAD_SCALE
	local swing = CFrame.new(hinge) * CFrame.Angles(0, 0, -gape * JAW_MAX) * CFrame.new(-hinge)

	-- The frill is ten raked blades per side, authored to flare. Riding the
	-- skull's frame rigidly made it a fixed collar - same defect as the jaw
	-- hinge, one piece over. It opens with whatever the body is doing.
	local flare = math.max(state.unwind or 0, slump)
	local frillFrame = headFrame * CFrame.Angles(0, 0, flare * math.rad(22))
	for _, name in HEAD_PIECES do
		local frame = headFrame
		if JAW_PIECES[name] then
			frame = headFrame * swing
		elseif name == "Frill" then
			frame = frillFrame
		end
		applyPiece(body.head[name], frame, HEAD_SCALE)
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
	local warned = false
	RunService.RenderStepped:Connect(function(dt)
		-- Server time, not os.clock(): the ambient breath is computed from
		-- this on BOTH sides, and two machines' clocks share no epoch. On a
		-- local epoch the drawn body breathes on an unrelated phase from the
		-- head the server is aiming with - which quietly falsifies the one
		-- promise this whole design rests on, that what you dodge and what
		-- you see cannot drift apart.
		local now = Workspace:GetServerTimeNow()
		for model, body in bodies do
			if model.Parent then
				-- Guarded: an error here aborts the whole RenderStepped
				-- callback, so one bad frame in one body would stop every
				-- other body drawing - and the serpent would simply freeze
				-- on screen with no clue why. Warn once, keep rendering.
				local ok, err = pcall(drawBody, model, body, dt, now)
				if not ok and not warned then
					warned = true
					warn("[BrinejawBody] draw failed: " .. tostring(err))
				end
			else
				destroyBody(model)
			end
		end
	end)
end

return BrinejawBodyController
