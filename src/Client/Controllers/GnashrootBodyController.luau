--!nonstrict
-- GnashrootBodyController.luau
-- Draws Old Gnashroot: one mud colossus stood in the Rootmere, with an arm
-- hung off each shoulder.
--
-- Same split as KrakenBodyController, and deliberately so. The server keeps
-- authority only - a hidden model for hits and the HUD, plus the replicated
-- pose numbers listed in GnashrootPath's header - and everything you can see
-- is built here off GnashrootPath. No timers, no local guesses about what the
-- boss is doing.
--
-- WHAT IS DIFFERENT FROM THE KRAKEN, and why:
--   * TWO arms, not eight, and they hold nothing. The Kraken's arms reach for
--     tentacle creatures that replicate on their own; Gnashroot's arms are
--     pure pose, so every stud of them comes out of the attack state.
--   * A FIXED number of vertebrae. The Kraken grows its arm segments lazily
--     because an arm's length chases whatever it is holding; this limb is
--     five vertebrae and a fist, always, and it STRETCHES its overlap rather
--     than gaining a joint. A colossus that grows an elbow mid-slam is a
--     colossus with a bug, and the pool is allocated once at adopt.
--   * The body pitches. Everything in the cluster - and both shoulders with
--     it - rides GnashrootPath.bodyCFrame, so a lean cannot tear the arms off
--     the animal.
--
-- THE ONE THING THIS FILE OWNS is a look, not a rule: the core's glow. The
-- rule (when the window is open) is the server's Exposed attribute; how hard
-- the ember burns while it is is decided here, because it is the only part of
-- the fight the player is being taught to shoot.
--
-- Pieces come from ReplicatedStorage/Assets/GnashrootPack (assets/boss_gen.py)
-- and fall back to tinted blocks until that import lands, so the fight is
-- never invisible.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChainPose = require(Shared.Modules.ChainPose)
local GnashrootPath = require(Shared.Modules.GnashrootPath)

local GnashrootBodyController = {}

local CREATURES_FOLDER = "Creatures"
local PACK_NAME = "GnashrootPack"
local FOLDER_NAME = "GnashrootBody"
local POSE_KEY = "gnashroot"

local SCALE = GnashrootPath.SCALE
local SEGMENTS = GnashrootPath.ARM_SEGMENTS
local KNOT_EVERY = GnashrootPath.KNOT_EVERY

-- A quadratic through three points needs nowhere near ChainPose's default
-- 160 samples, and this one is walked twice a frame for a six-piece limb.
local ARM_SAMPLES = 40
-- The limb thins toward the fist but barely shortens: tapering the length as
-- hard as the girth is what opens gaps between vertebrae (the Kraken's arms
-- learned this). The fist is a knuckle, not a point, so the taper stops well
-- short of nothing.
local TIP_GIRTH = 0.42
local TIP_LENGTH = 0.14
-- How far the vertebrae may stretch when a pose reaches further than rest.
-- Past this the overlap is gone and the limb reads as rubber, so it is better
-- to let a gap open at the wrist than to pull the whole arm thin.
local STRETCH_MIN, STRETCH_MAX = 0.85, 1.30

-- Placed with the SINGLE body CFrame (the pack authors every offset into the
-- mesh). Only the jaw group moves inside it.
local BODY_PIECES = { "Mass", "Legs", "Head", "Eyes", "Core", "Stones" }
local JAW_PIECES = { "Jaw", "Fangs", "Maw" }

-- How fast the drawn pose chases the replicated one. `blend` and `strike` are
-- PROGRESS through an attack rather than targets, so they track nearly
-- rigidly - easing them would put the fist behind its own blow, which is the
-- one lag a player can see and cannot forgive. The rest is free to be slow.
local EASE = { rise = 2.4, face = 4.5, blend = 14.0, strike = 22.0, exposed = 6.0 }

-- The stand-in palette is the creature row's (Creatures.old_gnashroot): wet
-- peat-mud, bog stone, and the neon gnashroot in its chest.
local MUD = Color3.fromRGB(107, 71, 43)
local BARK = Color3.fromRGB(88, 76, 52)
local CORE_LIT = Color3.fromRGB(150, 235, 200)
-- What the core looks like between windows: banked, not dark. A core that
-- goes out entirely leaves the player nothing to learn the target from.
local CORE_BANKED = Color3.fromRGB(58, 104, 88)

local FALLBACK_COLOR = {
	Mass = MUD,
	Legs = Color3.fromRGB(92, 60, 36),
	Head = MUD,
	Jaw = Color3.fromRGB(96, 64, 39),
	Maw = Color3.fromRGB(58, 38, 24),
	Fangs = Color3.fromRGB(211, 205, 178),
	Eyes = Color3.fromRGB(24, 26, 20),
	Core = CORE_BANKED,
	Stones = Color3.fromRGB(94, 92, 85),
	Drips = Color3.fromRGB(74, 56, 34),
	Arm = BARK,
	ArmKnot = BARK,
	Hand = BARK,
}
-- Rough bulk of each authored piece, at scale 1.
local FALLBACK_SIZE = {
	Mass = Vector3.new(28, 16, 22),
	Legs = Vector3.new(20, 12, 24),
	Head = Vector3.new(18, 14, 12),
	Jaw = Vector3.new(16, 5, 10),
	Maw = Vector3.new(9, 8, 8),
	Fangs = Vector3.new(14, 4, 9),
	Eyes = Vector3.new(3, 2, 12),
	Core = Vector3.new(5, 5, 5),
	Stones = Vector3.new(16, 8, 16),
	Drips = Vector3.new(22, 10, 20),
	Arm = Vector3.new(5.4, 7.0, 7.0),
	ArmKnot = Vector3.new(5.4, 8.4, 8.4),
	Hand = Vector3.new(7.6, 8.6, 8.6),
}
-- A stand-in carries no mesh, so it carries no authored offset either.
-- WITHOUT THIS every fallback piece stacks on the model origin and a
-- 27-stud colossus reads as one box - which is exactly how you fail to notice
-- that the arms are on backwards. Roblox-local (+X forward, +Y up), and
-- ignored the moment the pack lands.
local FALLBACK_AT = {
	Mass = Vector3.new(-3.0, 13.0, 0),
	Legs = Vector3.new(-2.0, 5.0, 0),
	Head = Vector3.new(6.0, 18.5, 0),
	Jaw = Vector3.new(11.0, 8.0, 0),
	Maw = Vector3.new(5.0, 12.0, 0),
	Fangs = Vector3.new(11.5, 11.0, 0),
	Eyes = Vector3.new(10.0, 22.0, 0),
	Core = GnashrootPath.CORE,
	Stones = Vector3.new(-6.0, 20.0, 0),
	Drips = Vector3.new(0, 6.0, 0),
}
-- The pieces that read better round than as a brick.
local FALLBACK_SHAPE = {
	Mass = Enum.PartType.Ball,
	Core = Enum.PartType.Ball,
	Arm = Enum.PartType.Cylinder, -- a Roblox cylinder's axis IS +X: the pack convention
	ArmKnot = Enum.PartType.Cylinder,
	Hand = Enum.PartType.Ball,
}

-- model -> the live body { folder, state, target, arms, body, jaw, drips }
local bodies = {}
local warnedMissingPack = false

-- ---------------------------------------------------------------- pieces

local function packPiece(name: string): BasePart?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local pack = assets and assets:FindFirstChild(PACK_NAME)
	local piece = pack and pack:FindFirstChild("Gnashroot_" .. name, true)
	return if piece and piece:IsA("BasePart") then piece else nil
end

local function makePiece(name: string, parent: Instance): BasePart
	local template = packPiece(name)
	local part
	if template then
		part = template:Clone()
	else
		if not warnedMissingPack then
			warnedMissingPack = true
			warn("[GnashrootBody] " .. PACK_NAME .. " not imported - drawing stand-ins")
		end
		part = Instance.new("Part")
		part.Size = FALLBACK_SIZE[name] or Vector3.new(4, 4, 4)
		part.Color = FALLBACK_COLOR[name] or MUD
		part.Material = Enum.Material.SmoothPlastic
		local shape = FALLBACK_SHAPE[name]
		if shape then
			part.Shape = shape
		end
		local at = FALLBACK_AT[name]
		if at then
			part:SetAttribute("FallbackAt", at)
		end
	end
	if name == "Core" then
		-- ONLY the core glows, whichever branch built it: the eyes are dark
		-- and glossy by design (assets/boss_gen.py), and a second neon piece
		-- on the same silhouette makes the punish target ambiguous. Asserted
		-- here rather than trusted to survive the glTF round trip, because
		-- this one is a fight rule wearing a material.
		part.Material = Enum.Material.Neon
	elseif name == "Eyes" then
		part.Reflectance = 0.35
	end
	part.Name = "Gnashroot_" .. name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.Parent = parent
	return part
end

-- Place one piece. Length and girth scale separately so a limb can thin
-- toward the fist without its vertebrae pulling apart (see TIP_LENGTH).
local function applyPiece(part: BasePart, cframe: CFrame, lengthScale: number, girthScale: number)
	local base = part:GetAttribute("BaseSize")
	if not base then
		base = part.Size
		part:SetAttribute("BaseSize", base)
	end
	local at = part:GetAttribute("FallbackAt")
	if at then
		cframe = cframe * CFrame.new(at * girthScale)
	end
	part.CFrame = cframe
	part.Size = Vector3.new(base.X * lengthScale, base.Y * girthScale, base.Z * girthScale)
end

-- ---------------------------------------------------------------- pose

-- Every read below defaults, which is right for a frame that arrives before
-- the server's first publish - but it means an UNFED rig is indistinguishable
-- from a rig at rest: no error, no nil, just the authored rest pose held
-- forever. That reads as "the animation is not working yet" when the truth is
-- "nothing is connected". `fed` exists so the difference can be reported.
local function isFed(model: Model): boolean
	return model:GetAttribute("Attack") ~= nil
end

local function readTarget(model: Model, target)
	target.rise = model:GetAttribute("Rise") or 1
	target.faceAngle = model:GetAttribute("FaceAngle") or 0
	target.attack = model:GetAttribute("Attack") or ""
	target.blend = model:GetAttribute("AttackBlend") or 0
	target.strike = model:GetAttribute("Strike") or 0
	target.aimAngle = model:GetAttribute("AimAngle") or target.faceAngle
	target.aimSide = model:GetAttribute("AimSide") or 1
	target.exposed = if model:GetAttribute("Exposed") then 1 else 0
	return target
end

local function approach(current: number, goal: number, rate: number, dt: number): number
	return current + (goal - current) * math.clamp(rate * dt, 0, 1)
end

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

local function newArm(folder: Instance, side: number)
	local segments = {}
	for index = 1, SEGMENTS do
		-- A knuckle every third vertebra, the pack's own pattern. The whole
		-- pool is built here rather than on demand: the limb's anatomy is
		-- fixed, so there is never a frame where a piece is missing.
		segments[index] = makePiece(if index % KNOT_EVERY == 0 then "ArmKnot" else "Arm", folder)
	end
	return {
		side = side,
		chain = ChainPose.new(GnashrootPath.armShape(side), { samples = ARM_SAMPLES }),
		segments = segments,
		hand = makePiece("Hand", folder),
	}
end

local function adoptBoss(model: Model)
	if bodies[model] or model:GetAttribute("Pose") ~= POSE_KEY then
		return
	end

	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = Workspace

	local state = GnashrootPath.newState(model:GetAttribute("PoseCenter") or model:GetPivot().Position)
	readTarget(model, state)

	local body = {
		folder = folder,
		state = state,
		adoptedAt = Workspace:GetServerTimeNow(),
		fed = isFed(model),
		target = readTarget(model, {}),
		-- The creature's LEFT arm first (GnashrootPath's +1 flank).
		arms = { newArm(folder, 1), newArm(folder, -1) },
		pieces = {},
		jaw = {},
	}
	for _, name in BODY_PIECES do
		body.pieces[name] = makePiece(name, folder)
	end
	for _, name in JAW_PIECES do
		body.jaw[name] = makePiece(name, folder)
	end
	-- The drips hang off the mass and swing on their own, so they are the one
	-- cluster piece that does not take the body frame unmodified.
	body.drips = makePiece("Drips", folder)

	bodies[model] = body
	model.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			destroyBody(model)
		end
	end)
end

-- ---------------------------------------------------------------- per frame

local function drawArm(entry, state)
	local chain = entry.chain
	chain:update(state)

	-- FIXED COUNT, stretched pitch. Walking by spacing (ChainPose:each) would
	-- add and drop vertebrae as the arm reaches, which on a five-piece limb is
	-- a joint appearing mid-swing. Instead each vertebra keeps its share of
	-- the curve and the pieces stretch to cover it, so their overlap survives
	-- a reach and the knuckle stays the same knuckle.
	local pitch = chain.length / SEGMENTS
	local stretch = math.clamp(pitch / (GnashrootPath.ARM_PITCH * SCALE), STRETCH_MIN, STRETCH_MAX)
	for index = 1, SEGMENTS do
		-- Centres, not ends: a vertebra covers half a pitch either side of its
		-- point, so this seats the first one IN the shoulder socket instead of
		-- on top of it.
		local u = (index - 0.5) / SEGMENTS
		applyPiece(
			entry.segments[index],
			chain:cframeAt(u * chain.length),
			SCALE * stretch * (1 - TIP_LENGTH * u),
			SCALE * (1 - TIP_GIRTH * u)
		)
	end
	applyPiece(entry.hand, chain:cframeAt(chain.length), SCALE, SCALE * (1 - TIP_GIRTH))
end

local function drawBody(model: Model, body, dt: number, now: number)
	local state, target = body.state, readTarget(model, body.target)
	state.time = now
	-- Gnashroot WALKS its mere - the row has speed, aggro and a standoff, so
	-- it is not one of the entrenched colossi - and PoseCenter is published
	-- once, at the anchor. The authority model's pivot IS its hit position, so
	-- following that every frame is what keeps the mass you dodge and the mass
	-- you see the same object.
	state.center = model:GetPivot().Position
	state.rise = approach(state.rise, target.rise, EASE.rise, dt)
	state.faceAngle = approachAngle(state.faceAngle, target.faceAngle, EASE.face, dt)
	state.blend = approach(state.blend, if target.attack == "" then 0 else target.blend, EASE.blend, dt)
	state.strike = approach(state.strike, target.strike, EASE.strike, dt)
	state.exposed = approach(state.exposed, target.exposed, EASE.exposed, dt)
	-- LATCHED VALUES ARE COPIED, NEVER EASED (GnashrootPath's contract). An
	-- eased bearing would drag a committed swing toward wherever the boss has
	-- since turned, which is the same lie as re-aiming per frame.
	state.aimAngle = target.aimAngle
	state.aimSide = target.aimSide
	-- The attack's NAME outlives its attribute by however long the blend takes
	-- to ease home. Dropping it the instant the server clears it would snap
	-- both arms out of a full slam and back to rest inside one frame.
	if target.attack ~= "" then
		state.attack = target.attack
	elseif state.blend <= 0.02 then
		state.attack = ""
	end

	local frame = GnashrootPath.bodyCFrame(state)
	for _, name in BODY_PIECES do
		applyPiece(body.pieces[name], frame, SCALE, SCALE)
	end

	-- The core: banked between windows, burning while one is open, and always
	-- breathing a little so the eye can find it on a mud-coloured animal.
	local pulse = 0.5 + 0.5 * math.sin(now * 2.2)
	local glow = math.clamp(0.18 + 0.12 * pulse + 0.7 * state.exposed, 0, 1)
	body.pieces.Core.Color = CORE_BANKED:Lerp(CORE_LIT, glow)

	-- Jaw group: it SWINGS about its hinge rather than sliding, so rotate
	-- around the pivot point and not the pieces' own origin.
	local hinge = GnashrootPath.JAW_HINGE * SCALE
	local jawFrame = frame
		* CFrame.new(hinge)
		* CFrame.Angles(0, 0, -GnashrootPath.jawAngle(state))
		* CFrame.new(-hinge)
	for _, name in JAW_PIECES do
		applyPiece(body.jaw[name], jawFrame, SCALE, SCALE)
	end

	-- The drips swing under the mass on their own slow phase - a roll about
	-- the body's forward axis, so they swing sideways off it rather than
	-- pumping back and forth like a piston.
	applyPiece(body.drips, frame * CFrame.Angles(math.sin(now * 0.9) * math.rad(2.5), 0, 0), SCALE, SCALE)

	for _, entry in body.arms do
		drawArm(entry, state)
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

function GnashrootBodyController.init()
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

function GnashrootBodyController.start()
	local warned = false
	local warnedUnfed = false
	RunService.RenderStepped:Connect(function(dt)
		-- Server time, not os.clock(): the breath, the drip sway and every
		-- arm's idle drift are phases two machines have to agree on, and
		-- os.clock() is time since THIS process started - so no two clients
		-- share an epoch, and the moment anything server-side reads these
		-- curves for a hit it is reading a different animal from the one on
		-- your screen. Same reasoning as the other body controllers.
		local now = Workspace:GetServerTimeNow()
		for model, body in bodies do
			if model.Parent then
				-- Guarded like its siblings: an error here aborts the whole
				-- RenderStepped callback, so one bad frame in one body would
				-- stop every other body drawing and freeze the fight with no
				-- error anyone sees. Warn once, keep rendering.
				local ok, err = pcall(drawBody, model, body, dt, now)
				if not ok and not warned then
					warned = true
					warn("[GnashrootBody] draw failed: " .. tostring(err))
				end
				-- The silent failure this rig is most likely to ship with: it
				-- adopts, draws, breathes, and never animates, because nobody
				-- publishes the pose vocabulary. Say so out loud rather than
				-- letting it look like a rest pose that will not move on.
				body.fed = body.fed or isFed(model)
				if not body.fed and not warnedUnfed and now - body.adoptedAt > 8 then
					warnedUnfed = true
					warn(
						"[GnashrootBody] drawing but never fed: no Attack/AttackBlend/Strike/"
							.. "AimAngle/AimSide attributes in 8s. The rig is connected and the "
							.. "server's publishPose has no gnashroot branch, so it will hold its "
							.. "rest pose forever."
					)
				end
			else
				destroyBody(model)
			end
		end
	end)
end

return GnashrootBodyController
