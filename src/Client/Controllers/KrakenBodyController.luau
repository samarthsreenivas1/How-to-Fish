--!nonstrict
-- KrakenBodyController.luau
-- Draws the Kraken: one huge domed head filling the middle of the whirlpool,
-- and eight arms reaching out of its crown to the rocks.
--
-- Same split as BrinejawBodyController. The server keeps authority only - a
-- hidden model for hits and the HUD, plus three replicated numbers (Rise,
-- FaceAngle, Stance) - and everything you can see is built here from
-- KrakenPath. No timers, no local guesses about what the boss is doing.
--
-- THE ONE IDEA WORTH KNOWING: the fight spawns eight `kraken_tentacle`
-- creatures on a ring, and those are the things you hit. This controller
-- hides their own models and draws an ARM to each one instead, welded into a
-- socket on the head's crown. So there is no "boss plus some tentacles" -
-- there is one octopus, and the eight things you are hitting are its arms.
-- An arm whose tentacle is dead does not vanish; it drapes back into the
-- water and waits for the ring to regrow.
--
-- Pieces come from ReplicatedStorage/Assets/KrakenPack (assets/boss_gen.py)
-- and fall back to tinted cylinders until that import lands, so the fight is
-- never invisible.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChainPose = require(Shared.Modules.ChainPose)
local MeshColors = require(Shared.Config.MeshColors)
local KrakenPath = require(Shared.Modules.KrakenPath)

local KrakenBodyController = {}

local CREATURES_FOLDER = "Creatures"
local PACK_NAME = "KrakenPack"
local FOLDER_NAME = "KrakenBody"
local TENTACLE_ID = "kraken_tentacle"

local SCALE = KrakenPath.SCALE
-- Studs between segment centres. The pieces are authored 5.4 long and meant
-- to be planted every 3.0, so they overlap by nearly half - which is the
-- whole reason an arm reads as one limb instead of a string of beads. Both
-- numbers scale together; never raise this one alone.
local SPACING = KrakenPath.SEG_SPACING * SCALE
-- Taper: the arm thins a LOT toward the tip but barely shortens, so the
-- overlap above survives all the way to the end. Tapering the length as hard
-- as the girth is what opens gaps between the last few segments.
local TIP_GIRTH = 0.52
local TIP_LENGTH = 0.16
-- A sucker row down the underside, on every Nth segment, stopping before the
-- tip goes thin. ONE row of big ones, matching the pack: two rows of small
-- ones is what made them vanish into the hide in the first place.
local SUCKER_EVERY = 1
local SUCKER_UNTIL = 0.93
-- How far off the arm's axis a sucker seats, as a fraction of the segment's
-- authored girth. Less than half, so the rim sits IN the hide with the pad
-- proud of it rather than floating alongside.
local SUCKER_SEAT = 0.43
-- Turns the disc from pointing along the arm to pointing out of its underside.
local SUCKER_TURN = CFrame.Angles(0, 0, -math.pi / 2)

local HEAD_PIECES = { "Head", "Crown", "Crust", "Eyes", "Pupil", "Beak" }

-- How an arm sits when it has a tentacle to hold, and when it does not.
-- `hump` is doing the heavy lifting: the arch is most of an arm's visible
-- length, and it is what makes the thing crest out of the water and come
-- DOWN on the rock rather than poke at it.
-- `hump` is measured AGAINST THE RADIAL SPAN, not chosen for drama. A bound
-- arm crosses 20.5 studs (socket 25.5 -> ring 46), and the authored render
-- arches 0.63 of its span - so 13, not the 26 that was here. At 26 the arm
-- climbed further than it travelled and read as a fountain, not a limb; it
-- also spent 76% of its length past 64 degrees of pitch, where ChainPose's
-- frame goes degenerate. Raise `parts.ring` and these rise with it.
local BOUND = { hump = 13.0, wave = 0.22, breathe = 1.8 }
local RESTING = { hump = 7.0, wave = 0.12, breathe = 1.2, reach = 36.0, tipY = -16.0 }
-- How fast an arm chases its tentacle. TIGHT on the tip, because the tentacle
-- is not decoration - it rears 13 studs and slams, and an arm that lags that
-- by half a second is an arm hitting you somewhere it visibly is not. Loose
-- on `shape`, so the arch and sway still ease and a regrown ring sweeps back
-- out instead of popping into place.
local EASE = { reach = 12.0, tip = 12.0, rise = 2.2, face = 4.0, shape = 2.5 }

-- Rough bulk of each authored piece, at scale 1.
local FALLBACK_SIZE = {
	Head = Vector3.new(40, 46, 40),
	Crown = Vector3.new(39, 8, 39),
	Crust = Vector3.new(34, 6, 34),
	Eyes = Vector3.new(11, 6, 32),
	Pupil = Vector3.new(7, 2, 30),
	Beak = Vector3.new(9, 7, 9),
	ArmSeg = Vector3.new(5.4, 8.6, 8.6),
	ArmTip = Vector3.new(11.8, 7.8, 7.8),
	Sucker = Vector3.new(1.3, 4.6, 4.6),
}
-- WHICH PIECES GLOW, asserted here rather than left to the import. An import
-- step is the only failure mode with nowhere in the system to check it: a
-- missing row, anchor or call site can all be looked for, but "someone set
-- this dropdown" lives in a person's memory. It also does not survive a
-- re-export that drops materials, and CreaturePack is already owed one.
--
-- A LITERAL list, deliberately, not a `Glow` substring rule like the packs
-- with long or growing part lists use. The Kraken's list is short and closed,
-- and it has an exclusion that a broad rule would eventually swallow:
-- `Kraken_Pupil` must stay matte, or the slit stops reading as a pupil and
-- the eye goes back to being a lamp. Naming the two that glow states that.
local NEON_PIECES = { Eyes = true, Sucker = true }

-- The pieces that read better as a round fallback than a brick.
local FALLBACK_SHAPE = {
	ArmSeg = Enum.PartType.Cylinder, -- a Roblox cylinder's axis IS +X: the pack convention
	ArmTip = Enum.PartType.Cylinder,
	Sucker = Enum.PartType.Ball,
	Head = Enum.PartType.Ball,
}

-- model -> the live body { folder, state, arms, head }
local bodies = {}

-- ---------------------------------------------------------------- pieces

local function packPiece(name: string): BasePart?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local pack = assets and assets:FindFirstChild(PACK_NAME)
	local piece = pack and pack:FindFirstChild("Kraken_" .. name, true)
	return if piece and piece:IsA("BasePart") then piece else nil
end

local function makePiece(name: string, parent: Instance): BasePart
	local template = packPiece(name)
	local part
	if template then
		part = template:Clone()
	else
		part = Instance.new("Part")
		part.Size = FALLBACK_SIZE[name] or Vector3.new(4, 4, 4)
		part.Material = Enum.Material.SmoothPlastic
		local shape = FALLBACK_SHAPE[name]
		if shape then
			part.Shape = shape
		end
	end
	-- COLOUR AND MATERIAL, asserted for BOTH branches. Studio's glTF importer
	-- carries no colour at all - every imported part arrives Roblox-default
	-- grey - so without this the octopus imports as a grey octopus, and the
	-- pack landing would make the fight look WORSE than the fallback blocks
	-- it replaced. MeshColors is generated from boss_gen.py by
	-- tools/gen_mesh_colors.py, so it cannot drift from the builder the way
	-- the hand-written table it replaces already had (its crust was still the
	-- brown from before the barnacles went pale).
	--
	-- Keyed off the name we are ABOUT to assign, never off `part.Name`: on
	-- the fallback path that is still "Part" at this point, so every
	-- stand-in would silently miss its colour.
	local partName = "Kraken_" .. name
	local colour = MeshColors.get(partName)
	if colour then
		part.Color = colour
	end
	-- After the branch for the same reason: the SmoothPlastic write lives in
	-- the fallback arm, so asserting in there would light the stand-in and
	-- leave the real imported piece flat - the exact inverse of the intent.
	if NEON_PIECES[name] then
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

-- Place one piece. Length and girth scale separately so the arm can thin
-- toward the tip without the segments pulling apart (see TIP_LENGTH).
local function applyPiece(part: BasePart, cframe: CFrame, lengthScale: number, girthScale: number)
	local base = part:GetAttribute("BaseSize")
	if not base then
		base = part.Size
		part:SetAttribute("BaseSize", base)
	end
	part.CFrame = cframe
	part.Size = Vector3.new(base.X * lengthScale, base.Y * girthScale, base.Z * girthScale)
end

local function park(part: BasePart)
	part.CFrame = CFrame.new(0, -5000, 0)
end

-- ---------------------------------------------------------------- tentacles

-- Which socket a tentacle belongs to, from its bearing around the centre.
-- The server plants tentacle `i` at exactly `(i / count) * 2pi`
-- (CreatureService.spawnBossParts), so this recovers `i` rather than
-- guessing at it.
local function socketFor(centre: Vector3, at: Vector3, count: number): number
	local bearing = math.atan2(at.Z - centre.Z, at.X - centre.X)
	local index = math.floor(bearing / (math.pi * 2) * count + 0.5)
	return ((index - 1) % count) + 1
end

-- The tentacle's own model is authority, not art: hide it and let the arm
-- drawn to it BE the thing on screen. Its health bar is a BillboardGui, not
-- a BasePart, so it survives this and stays targetable.
local function hideTentacle(model: Model)
	if model:GetAttribute("KrakenArmDrawn") then
		return
	end
	model:SetAttribute("KrakenArmDrawn", true)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Transparency = 1
			descendant.CastShadow = false
		elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
			descendant.Transparency = 1
		end
	end
end

-- socket index -> the live tentacle standing there, if any.
local function claimTentacles(centre: Vector3, count: number)
	local folder = Workspace:FindFirstChild(CREATURES_FOLDER)
	if not folder then
		return nil
	end
	local claimed = nil
	for _, child in folder:GetChildren() do
		if child:IsA("Model") and child:GetAttribute("CreatureId") == TENTACLE_ID then
			local at = child:GetPivot().Position
			if (Vector3.new(at.X - centre.X, 0, at.Z - centre.Z)).Magnitude < 200 then
				hideTentacle(child)
				claimed = claimed or {}
				local socket = socketFor(centre, at, count)
				-- Two tentacles on one bearing should not happen, but if the
				-- ring is ever spawned off-pattern the second takes the next
				-- free socket rather than stealing the first one's arm.
				for step = 0, count - 1 do
					local slot = ((socket - 1 + step) % count) + 1
					if not claimed[slot] then
						claimed[slot] = at
						break
					end
				end
			end
		end
	end
	return claimed
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
	if bodies[model] or model:GetAttribute("Pose") ~= "kraken" then
		return
	end

	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = Workspace

	local centre = model:GetAttribute("PoseCenter") or model:GetPivot().Position
	local state = KrakenPath.newState(centre)
	state.rise = model:GetAttribute("Rise") or 0

	local count = KrakenPath.ARM_COUNT
	local arms = {}
	for index = 1, count do
		local arm = KrakenPath.newArm(state, index, count)
		arm.reach = RESTING.reach
		arm.tipY = RESTING.tipY
		arm.hump = RESTING.hump
		arm.wave = RESTING.wave
		arm.breathe = RESTING.breathe
		arms[index] = {
			arm = arm,
			chain = ChainPose.new(function(s, t)
				return KrakenPath.armPoint(s, t)
			end),
			segments = {},
			suckers = {},
			tip = makePiece("ArmTip", folder),
		}
	end

	local head = {}
	for _, name in HEAD_PIECES do
		head[name] = makePiece(name, folder)
	end

	bodies[model] = { folder = folder, state = state, arms = arms, head = head, count = count }
	model.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			destroyBody(model)
		end
	end)
end

-- ---------------------------------------------------------------- per frame

local function approach(current: number, goal: number, rate: number, dt: number): number
	return current + (goal - current) * math.clamp(rate * dt, 0, 1)
end

local function approachAngle(current: number, goal: number, rate: number, dt: number): number
	local delta = (goal - current + math.pi) % (math.pi * 2) - math.pi
	return current + delta * math.clamp(rate * dt, 0, 1)
end

local function drawArm(entry, body, dt: number, now: number, target: Vector3?)
	local arm = entry.arm
	arm.time = now
	arm.center = body.state.center
	arm.lift = KrakenPath.lift(body.state)

	-- Chase whatever this arm is holding. Reach and tip height are eased
	-- rather than assigned so a regrown ring sweeps back out.
	local wantReach, wantTip, shape
	if target then
		local flat = Vector3.new(target.X - arm.center.X, 0, target.Z - arm.center.Z)
		wantReach = flat.Magnitude
		wantTip = target.Y - (arm.center.Y + arm.lift)
		shape = BOUND
		-- The socket's bearing follows its tentacle, so an arm always points
		-- at the thing it is holding even if the ring spawns off-pattern.
		arm.angle = approachAngle(arm.angle, math.atan2(flat.Z, flat.X), EASE.reach, dt)
	else
		wantReach, wantTip, shape = RESTING.reach, RESTING.tipY, RESTING
	end
	arm.reach = approach(arm.reach, wantReach, EASE.reach, dt)
	arm.tipY = approach(arm.tipY, wantTip, EASE.tip, dt)
	arm.hump = approach(arm.hump, shape.hump, EASE.shape, dt)
	arm.wave = approach(arm.wave, shape.wave, EASE.shape, dt)
	arm.breathe = approach(arm.breathe, shape.breathe, EASE.shape, dt)

	local chain = entry.chain
	chain:update(arm)

	local used = 0
	chain:each(SPACING, function(index, cframe, u)
		used = index
		local segment = entry.segments[index]
		if not segment then
			segment = makePiece("ArmSeg", body.folder)
			entry.segments[index] = segment
		end
		local girth = SCALE * (1 - TIP_GIRTH * u)
		applyPiece(segment, cframe, SCALE * (1 - TIP_LENGTH * u), girth)

		if index % SUCKER_EVERY == 0 and u <= SUCKER_UNTIL then
			local sucker = entry.suckers[index]
			if not sucker then
				sucker = makePiece("Sucker", body.folder)
				entry.suckers[index] = sucker
			end
			-- On the underside, sitting proud of the hide. The drop comes off
			-- the SEGMENT's authored girth, so suckers stay on the skin as
			-- the arm tapers instead of sinking into it. The quarter turn
			-- matters as much as the drop: a sucker is authored as a disc on
			-- +X like everything else in the pack, so without it each one
			-- lies flat ALONG the arm, edge-on and invisible - the same bug
			-- that hid them in the generator.
			local segBase = segment:GetAttribute("BaseSize") or FALLBACK_SIZE.ArmSeg
			local seat = cframe * CFrame.new(0, -segBase.Y * SUCKER_SEAT * girth, 0) * SUCKER_TURN
			applyPiece(sucker, seat, girth, girth)
		end
	end)
	for index = used + 1, #entry.segments do
		park(entry.segments[index])
		if entry.suckers[index] then
			park(entry.suckers[index])
		end
	end

	local tipGirth = SCALE * (1 - TIP_GIRTH)
	applyPiece(entry.tip, chain:cframeAt(chain.length), SCALE * (1 - TIP_LENGTH), tipGirth)
end

local function drawBody(model: Model, body, dt: number, now: number)
	local state = body.state
	state.time = now
	state.rise = approach(state.rise, model:GetAttribute("Rise") or 1, EASE.rise, dt)
	state.faceAngle = approachAngle(state.faceAngle, model:GetAttribute("FaceAngle") or 0, EASE.face, dt)
	state.stance = model:GetAttribute("Stance") or state.stance
	local centre = model:GetAttribute("PoseCenter")
	if centre then
		state.center = centre
	end

	local headFrame = KrakenPath.headCFrame(state)
	for _, name in HEAD_PIECES do
		applyPiece(body.head[name], headFrame, SCALE, SCALE)
	end

	local claimed = claimTentacles(state.center, body.count)
	for index, entry in body.arms do
		drawArm(entry, body, dt, now, claimed and claimed[index])
	end
end

local function watch(child: Instance)
	if not child:IsA("Model") then
		return
	end
	adoptBoss(child)
	child:GetAttributeChangedSignal("Pose"):Connect(function()
		adoptBoss(child)
	end)
end

function KrakenBodyController.init()
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

function KrakenBodyController.start()
	local warned = false
	RunService.RenderStepped:Connect(function(dt)
		-- Server time, not os.clock(): every ambient term here - the mantle's
		-- swell, each arm's breathe and sway - is a phase two machines have to
		-- agree on, and os.clock() is time since THIS process started, so no
		-- two clients share an epoch. On a local one the arms you are dodging
		-- sway on a different phase for every player in the party, and the
		-- moment anything server-side reads these curves for a hitbox it is
		-- reading a different arm from the one you can see. Same reasoning as
		-- BrinejawBodyController.
		local now = Workspace:GetServerTimeNow()
		for model, body in bodies do
			if model.Parent then
				-- Guarded for the same reason the serpent is: an error here
				-- aborts the whole RenderStepped callback, so one bad frame
				-- in one body would stop every other body drawing, and the
				-- Kraken would freeze mid-fight with no error anyone sees.
				local ok, err = pcall(drawBody, model, body, dt, now)
				if not ok and not warned then
					warned = true
					warn("[KrakenBody] draw failed: " .. tostring(err))
				end
			else
				destroyBody(model)
			end
		end
	end)
end

return KrakenBodyController
