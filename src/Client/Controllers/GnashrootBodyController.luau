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
--
-- ------------------------------------------------ WHERE A PIECE ACTUALLY GOES
--
-- ALL THIRTEEN OBJECTS ARE AUTHORED IN ONE SHARED SPACE at their final
-- offsets - boss_gen's `_place_gnashroot` places the whole cluster at
-- Vector((0, 0, 0)) precisely because every piece already carries its own
-- position - so a piece placed on the body CFrame ALONE lands on the body
-- origin, not on the body. Measured off assets/boss_gnashroot.glb: the skull
-- spans x 8.8..18.0, the mass y 4.3..26.7, the core sits at (3.4, 18.2, -0.6).
-- Drop those offsets and the ten body pieces stack into a single ~40-stud
-- ball of mud, with no error and no nil to notice it by.
--
-- So this file does what WrackBodyController does for an identically-authored
-- pack: it measures each piece's offset ONCE, at adopt, from the pack itself
-- (`packAnchor` / `seatOf`), and thereafter moves the whole animal with one
-- CFrame. The `AUTHORED` table below is the same measurement taken off the
-- glb by hand, and it does two jobs: it places the stand-ins when the pack is
-- missing, and it is what keeps the stand-in and the clone in the same spot.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChainPose = require(Shared.Modules.ChainPose)
local GnashrootPath = require(Shared.Modules.GnashrootPath)
local MeshColors = require(Shared.Config.MeshColors)

local GnashrootBodyController = {}

local CREATURES_FOLDER = "Creatures"
local PACK_NAME = "GnashrootPack"
local PREFIX = "Gnashroot_"
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

-- Placed with the SINGLE body CFrame plus the piece's own authored offset.
-- Only the jaw group moves inside it.
-- Teeth is the PALATE row, split out of Fangs (2026-09-01) precisely so it
-- rides the skull: in the old one-object Fangs, the upper teeth rotated
-- with the jaw and tore 4 studs off the roof of the mouth on every gape.
local BODY_PIECES = { "Mass", "Legs", "Head", "Eyes", "Core", "Stones", "Teeth" }
local JAW_PIECES = { "Jaw", "Fangs", "Maw" }

-- How fast the drawn pose chases the replicated one. `blend` and `strike` are
-- PROGRESS through an attack rather than targets, so they track nearly
-- rigidly - easing them would put the fist behind its own blow, which is the
-- one lag a player can see and cannot forgive. The rest is free to be slow.
local EASE = { rise = 2.4, face = 4.5, blend = 14.0, strike = 22.0, exposed = 6.0 }

-- The last-resort tint for a piece MeshColors has no row for. Every one of
-- the thirteen has a row, so this only ever covers a re-export that adds a
-- fourteenth before the generator is re-run.
local MUD = Color3.fromRGB(107, 71, 43)
-- The core lit, read from the same generated table as everything else so the
-- ember and the mesh cannot drift (it is GN_WISP, the row's markColor).
local CORE_LIT = MeshColors.get(PREFIX .. "Core") or Color3.fromRGB(150, 235, 200)
-- What the core looks like between windows: banked, not dark. A core that
-- goes out entirely leaves the player nothing to learn the target from. This
-- one IS this file's own - it is a state the builder has no opinion about.
local CORE_BANKED = Color3.fromRGB(58, 104, 88)

-- Every piece's AUTHORED BOUNDING BOX, measured off assets/boss_gnashroot.glb
-- (`at` = the box's centre, `size` = the box), in Roblox body-local studs at
-- scale 1: +X forward, +Y up, origin at the underside of the mud pool.
--
-- `at` is what the stand-in is placed at and what the clone's measured offset
-- is stated against; `size` is what the stand-in is built at. Both come off
-- the glb rather than off a guess, because the previous hand-written table
-- had the skull 7.4 studs behind and 5.9 above the real one at twice its
-- length, and the throat floating 8.5 studs behind the mouth - errors that
-- look like art direction until you stand the two side by side.
--
-- The importer places a MeshPart at its mesh's bounding-box CENTRE (the same
-- convention WrackBodyController's AUTHORED table is stated in), which is why
-- these are centres and not object origins.
local AUTHORED = {
	Mass = { at = Vector3.new(-0.521, 15.504, -0.256), size = Vector3.new(23.04, 22.41, 22.09) },
	Legs = { at = Vector3.new(0.474, 4.633, -0.114), size = Vector3.new(22.67, 10.6, 18.9) },
	Head = { at = Vector3.new(13.378, 13.271, -0.163), size = Vector3.new(9.24, 6.14, 10.47) },
	Jaw = { at = Vector3.new(13.5, 6.9, 0), size = Vector3.new(8.6, 3.4, 9.2) },
	Maw = { at = Vector3.new(13.5, 8.591, -0.208), size = Vector3.new(8.2, 3.1, 7.98) },
	Teeth = { at = Vector3.new(13.4, 9.059, 0), size = Vector3.new(9.08, 2.66, 8.67) },
	Fangs = { at = Vector3.new(13.1, 9.51, 0), size = Vector3.new(8.4, 2.18, 7.6) },
	Eyes = { at = Vector3.new(4.248, 18.317, -0.036), size = Vector3.new(19.21, 14.41, 19.51) },
	-- 0.51 studs off GnashrootPath.CORE, and deliberately: that constant is
	-- the authored knot's CENTRE (what the HUD marker and the server's punish
	-- target point at), while this is the centre of the box the root's seven
	-- tendrils actually fill. The drawn blob is ~6.4 studs across, so the
	-- marker still lands inside it.
	Core = { at = Vector3.new(4.791, 21.598, 0.242), size = Vector3.new(5.24, 7.51, 6.35) },
	Stones = { at = Vector3.new(-2.228, 19.492, -0.099), size = Vector3.new(17.69, 14.31, 16.83) },
	Drips = { at = Vector3.new(2.872, 7.457, -0.482), size = Vector3.new(26.05, 11.9, 16.5) },
	-- The limb pieces are authored about the path they ride, so `at` here is
	-- the offset from the vertebra's own axis to its box centre, applied in
	-- the chain's frame rather than the body's. The Arm is symmetric; the
	-- ArmKnot's box hangs 1.10 below its tube because the sag lump does, and
	-- placing its CENTRE on the path would ride the bone 1.3 studs high at
	-- rest girth - a step at every third vertebra.
	Arm = { at = Vector3.zero, size = Vector3.new(5.2, 7, 7) },
	ArmKnot = { at = Vector3.new(0.444, -1.153, -0.075), size = Vector3.new(6.53, 9.31, 7.64) },
	Hand = { at = Vector3.new(-2.111, 0, -0.771), size = Vector3.new(9.42, 6.63, 10.99) },
}

-- Which piece the pack's offsets are measured FROM. There is no `_Base` in
-- this pack the way there is in Wrack's, so the mass - the one piece that can
-- never be absent from a Gnashroot - stands in for it. Measuring from a piece
-- rather than from the pack's own origin is what makes the import survive
-- somebody dragging the model in Studio.
local ANCHOR_PIECE = "Mass"
local AUTHORED_ANCHOR = AUTHORED[ANCHOR_PIECE].at

-- The pieces that read better round than as a brick.
local FALLBACK_SHAPE = {
	Mass = Enum.PartType.Ball,
	Core = Enum.PartType.Ball,
	Arm = Enum.PartType.Cylinder, -- a Roblox cylinder's axis IS +X: the pack convention
	ArmKnot = Enum.PartType.Cylinder,
	Hand = Enum.PartType.Ball,
}

-- THREE PIECES ARE SCATTERS, not solids: Eyes is 26 lumps spread over the
-- whole animal, Stones is 16 chips, Drips is 23 runnels. Their bounding box
-- is therefore the box the SCATTER fills, and a stand-in built solid at that
-- size is a wall. The Core's box (x -0.03..6.86, y 14.18..22.28,
-- z -3.73..2.58) sits entirely INSIDE the Eyes box and almost entirely inside
-- the Stones box, so opaque stand-ins would bury the punish target - the one
-- thing on this animal a player has to be able to find. Ghosted, the authored
-- bulk still reads and the ember still burns through it.
--
-- Stand-ins only. An imported piece is the real scatter and stays solid.
local SCATTER_STANDIN = { Eyes = true, Stones = true, Drips = true }
local SCATTER_TRANSPARENCY = 0.45

-- WHICH PIECES CAST. 22 parts on a 40-stud animal is 22 shadow casters for
-- one creature, and PyreliskBodyController's answer (only the torso and the
-- head) is the right shape of answer here too: the mass, the legs and the
-- skull ARE the ground-plane silhouette, and every other body piece is inside
-- their footprint. The exception is the FIST, which swings outside it and
-- plants - its shadow on the peat is the tell that the slam is coming down,
-- so those two parts earn theirs. Five casters, seventeen off.
local CASTS_SHADOW = { Mass = true, Legs = true, Head = true, Hand = true }

-- ------------------------------------------------------------------ the limb
--
-- The vertebra's own TUBE - the GN_ARM loft, x -2.6..2.6 - is 5.2 studs for
-- the plain vertebra AND for the knot. The knot's 7.0-stud box is its sag
-- lump bulging sideways, not a longer bone, so the length that has to cover a
-- pitch is measured against this and not against `Size.X`.
local ARM_TUBE = 5.2
-- The overlap the builder places at: `_place_gnashroot` walks the limb with
-- `step = GN_ARM_SPACING * 0.86`, i.e. every piece covers 1/0.86 of its own
-- step. The pack is cut for it - a 5.2-stud vertebra on the authored 4.6
-- pitch is exactly that - and it is what stops a joint showing.
local OVERLAP = 0.86
-- The rest pitch the pack was cut for, in world studs.
local REST_PITCH = GnashrootPath.ARM_PITCH * SCALE
-- The LAST vertebra's u. The taper is normalised on this one, so the wrist -
-- the tightest joint on the limb, and the only one that ever actually opened
-- - carries the full overlap and everything behind it carries more. Sized off
-- the shoulder instead, the taper ate the whole margin: at rest the five
-- vertebrae ran 7.72/7.50/7.29/7.07/6.85 against a 6.93 pitch, so the wrist
-- pair overlapped 0.03 studs and one frame of noise opened it.
local TIP_U = (SEGMENTS - 0.5) / SEGMENTS

-- THE FIST IS SEATED INTO THE LAST VERTEBRA, not hung off the path's end.
-- boss_gen's placer says why in as many words - "the hand's attach is at +X,
-- so placing it on the path's end alone leaves it hanging past the wrist" -
-- and pulls the mesh 1.6 authored studs back up-limb before placing it.
local HAND_SEAT = 1.6
-- ...and it scales the fist UNIFORMLY. Drawn at the arm's length scale
-- against the arm's girth scale it comes out 1.72x longer than it is wide: a
-- claw, not a fist. The girth is the one to keep, so the fist is continuous
-- with the vertebra it grows out of.
local HAND_SCALE = SCALE * (1 - TIP_GIRTH)
-- Where the fist's BOX centre goes, in the wrist frame (+X runs up-limb). The
-- seat and the box's own offset from the mesh origin fold into one vector:
-- (1.6 - 2.111, 0, -0.771) * 0.87. Net, the box centre sits 0.44 studs past
-- the wrist, the attach cap 3.65 studs inside the last vertebra, and the
-- fingertips 4.54 studs beyond - against 7.06 studs of overhang before.
local HAND_OFFSET = (Vector3.new(HAND_SEAT, 0, 0) + AUTHORED.Hand.at) * HAND_SCALE

-- How many DISTINCT draw failures one body reports before it goes quiet. A
-- single flag silenced every later bug for the session; keying on the message
-- means the second bug of a session is still heard, and the cap means an
-- error that carries a changing number in its text cannot turn RenderStepped
-- into a log flood.
local MAX_DRAW_WARNINGS = 4

-- model -> the live body { folder, state, target, arms, pieces, jaw, drips }
local bodies = {}
local warnedMissingPack = false

-- ---------------------------------------------------------------- pieces

local function packPiece(name: string): BasePart?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local pack = assets and assets:FindFirstChild(PACK_NAME)
	local piece = pack and pack:FindFirstChild(PREFIX .. name, true)
	return if piece and piece:IsA("BasePart") then piece else nil
end

local function makePiece(name: string, parent: Instance): BasePart
	local template = packPiece(name)
	local authored = AUTHORED[name]
	local part
	if template then
		part = template:Clone()
	else
		if not warnedMissingPack then
			warnedMissingPack = true
			warn("[GnashrootBody] " .. PACK_NAME .. " not imported - drawing stand-ins")
		end
		part = Instance.new("Part")
		part.Size = if authored then authored.size else Vector3.new(4, 4, 4)
		part.Color = MUD
		part.Material = Enum.Material.SmoothPlastic
		local shape = FALLBACK_SHAPE[name]
		if shape then
			part.Shape = shape
		end
		if SCATTER_STANDIN[name] then
			part.Transparency = SCATTER_TRANSPARENCY
		end
	end
	-- COLOUR, asserted for BOTH branches. Studio's glTF importer carries no
	-- colour at all - every imported part arrives Roblox-default grey - so
	-- without this the pack landing would make the colossus look WORSE than
	-- the stand-ins it replaced. MeshColors is generated from boss_gen.py by
	-- tools/gen_mesh_colors.py, so reading it for the stand-in TOO is what
	-- stops the two palettes drifting the way the hand-written table this
	-- replaces already had: its fangs were 33% brighter than GN_FANG, its
	-- arms were bark where the builder paints them mud, and its eyes had the
	-- green channel above the red where GN_EYE has it below.
	--
	-- Keyed off the name we are ABOUT to assign, never off `part.Name`: on the
	-- stand-in path that is still "Part" here, so every stand-in would
	-- silently miss its colour (MeshColors' own header warns about this).
	local partName = PREFIX .. name
	local colour = MeshColors.get(partName)
	if colour then
		part.Color = colour
		-- A textured PBR surface overrides Color outright. boss_gen authors one
		-- flat material per object and never a texture, so anything the
		-- importer attached here is noise.
		local appearance = part:FindFirstChildWhichIsA("SurfaceAppearance")
		if appearance then
			appearance:Destroy()
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
	part.CastShadow = CASTS_SHADOW[name] == true
	part.Name = partName
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
--
-- `cframe` is where the part's CENTRE goes, and it is the CALLER that folds
-- in the piece's authored offset - the body cluster off `seatOf`, the limb
-- off the chain frame. There is no offset attribute read in here any more:
-- the version that had one applied it only when the stand-in path had set it,
-- so the moment the pack imported, all ten body pieces landed on the body
-- origin at once and the colossus collapsed into a ball.
local function applyPiece(part: BasePart, cframe: CFrame, lengthScale: number, girthScale: number)
	local base = part:GetAttribute("BaseSize")
	if not base then
		base = part.Size
		part:SetAttribute("BaseSize", base)
	end
	part.CFrame = cframe
	part.Size = Vector3.new(base.X * lengthScale, base.Y * girthScale, base.Z * girthScale)
end

-- Where the assembly's own origin sits inside the pack, so a piece's offset
-- can be measured from it. Falls back to the authored constant when the pack
-- is missing, which is what keeps the stand-in path and the clone path
-- placing the animal in the same spot.
local function packAnchor(): CFrame
	local anchor = packPiece(ANCHOR_PIECE)
	return CFrame.new(if anchor then anchor.Position else AUTHORED_ANCHOR)
end

-- One body piece's authored placement, body-local and ALREADY SCALED, so the
-- draw is one CFrame multiply per piece per frame.
--
-- The clone path MEASURES it from the pack, so a re-export that shifts the
-- animal cannot desync the imported body; the stand-in path reads the same
-- number off AUTHORED, so the two agree.
local function seatOf(name: string, part: BasePart, anchor: CFrame): CFrame
	if packPiece(name) then
		local relative = anchor:Inverse() * part.CFrame
		return CFrame.new((AUTHORED_ANCHOR + relative.Position) * SCALE) * relative.Rotation
	end
	local authored = AUTHORED[name]
	return CFrame.new((if authored then authored.at else Vector3.zero) * SCALE)
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
		local name = if index % KNOT_EVERY == 0 then "ArmKnot" else "Arm"
		-- `seat` rides the CHAIN's frame, not the body's, so it is kept
		-- unscaled: each vertebra applies it at its own tapered girth.
		segments[index] = { part = makePiece(name, folder), seat = AUTHORED[name].at }
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
		warnedUnfed = false,
		-- Per BODY, not per session: a second Gnashroot used to inherit the
		-- first one's silence and report nothing at all.
		drawWarnings = {},
		drawWarningCount = 0,
		target = readTarget(model, {}),
		-- The creature's LEFT arm first (GnashrootPath's +1 flank).
		arms = { newArm(folder, 1), newArm(folder, -1) },
		pieces = {},
		jaw = {},
	}
	-- ONE measurement of the authored layout, taken from the pack itself, so
	-- the ten body pieces keep the exact relationship they were built with.
	-- The whole cluster then moves as one CFrame forever after.
	local anchor = packAnchor()
	local function seated(name: string)
		local part = makePiece(name, folder)
		return { part = part, offset = seatOf(name, part, anchor) }
	end
	for _, name in BODY_PIECES do
		body.pieces[name] = seated(name)
	end
	for _, name in JAW_PIECES do
		body.jaw[name] = seated(name)
	end
	-- The drips hang off the mass and swing on their own, so they are the one
	-- cluster piece that does not take the body frame unmodified.
	body.drips = seated("Drips")

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
	local stretch = math.clamp(pitch / REST_PITCH, STRETCH_MIN, STRETCH_MAX)
	-- The TUBE this pose's pitch needs, with the builder's overlap on it and
	-- the taper normalised on the wrist. At rest that is 9.09/8.83/8.57/
	-- 8.32/8.06 studs of bone over a 6.93 pitch: 1.26 studs of overlap at the
	-- tightest joint instead of 0.03.
	local tube = REST_PITCH * stretch / (OVERLAP * (1 - TIP_LENGTH * TIP_U))
	for index = 1, SEGMENTS do
		-- Centres, not ends: a vertebra covers half a pitch either side of its
		-- point, so this seats the first one IN the shoulder socket instead of
		-- on top of it.
		local u = (index - 0.5) / SEGMENTS
		local segment = entry.segments[index]
		local girth = SCALE * (1 - TIP_GIRTH * u)
		applyPiece(
			segment.part,
			chain:cframeAt(u * chain.length) * CFrame.new(segment.seat * girth),
			tube * (1 - TIP_LENGTH * u) / ARM_TUBE,
			girth
		)
	end
	applyPiece(entry.hand, chain:cframeAt(chain.length) * CFrame.new(HAND_OFFSET), HAND_SCALE, HAND_SCALE)
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
	-- STRIKE IS HELD, NOT EASED HOME. hammerShape carries the fists between
	-- raised and landed on strike^2, so a strike decaying at 22/s runs the
	-- SLAM BACKWARDS on release: measured, the fists sweep back up to +23.1
	-- world studs 50ms after the blow and +12.2 at 100ms before settling. The
	-- pose cannot tell recovery from windup statelessly - in both, strike is
	-- below blend - so the fix is here, where the attack's identity is known:
	-- hold it at its peak for as long as the attack is held, and let it fall
	-- only once the attack itself has been released (the same rule, and the
	-- same reason, as the attack name being held until blend decays).
	if target.attack ~= "" then
		state.strike = math.max(state.strike, approach(state.strike, target.strike, EASE.strike, dt))
	else
		state.strike = approach(state.strike, 0, EASE.strike, dt)
	end
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
		local piece = body.pieces[name]
		applyPiece(piece.part, frame * piece.offset, SCALE, SCALE)
	end

	-- The core: banked between windows, burning while one is open, and always
	-- breathing a little so the eye can find it on a mud-coloured animal.
	local pulse = 0.5 + 0.5 * math.sin(now * 2.2)
	local glow = math.clamp(0.18 + 0.12 * pulse + 0.7 * state.exposed, 0, 1)
	body.pieces.Core.part.Color = CORE_BANKED:Lerp(CORE_LIT, glow)

	-- Jaw group: it SWINGS about its hinge rather than sliding, so rotate
	-- around the pivot point and not the pieces' own origin.
	local hinge = GnashrootPath.JAW_HINGE * SCALE
	local jawFrame = frame
		* CFrame.new(hinge)
		* CFrame.Angles(0, 0, -GnashrootPath.jawAngle(state))
		* CFrame.new(-hinge)
	for _, name in JAW_PIECES do
		local piece = body.jaw[name]
		applyPiece(piece.part, jawFrame * piece.offset, SCALE, SCALE)
	end

	-- The drips swing under the mass on their own slow phase - a roll about
	-- the body's forward axis, so they swing sideways off it rather than
	-- pumping back and forth like a piston.
	local sway = frame * CFrame.Angles(math.sin(now * 0.9) * math.rad(2.5), 0, 0)
	applyPiece(body.drips.part, sway * body.drips.offset, SCALE, SCALE)

	for _, entry in body.arms do
		drawArm(entry, state)
	end
end

-- Warn once per DISTINCT failure per body, up to a cap. One flag for the
-- whole session meant the second bug of a session was invisible; no flag at
-- all means a bad frame warns sixty times a second.
local function reportDrawFailure(body, err)
	local text = tostring(err)
	if body.drawWarnings[text] or body.drawWarningCount >= MAX_DRAW_WARNINGS then
		return
	end
	body.drawWarnings[text] = true
	body.drawWarningCount += 1
	warn("[GnashrootBody] draw failed: " .. text)
	if body.drawWarningCount == MAX_DRAW_WARNINGS then
		warn("[GnashrootBody] " .. MAX_DRAW_WARNINGS .. " distinct draw failures on this body - staying quiet now")
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
				-- error anyone sees. Warn, keep rendering.
				local ok, err = pcall(drawBody, model, body, dt, now)
				if not ok then
					reportDrawFailure(body, err)
				end
				-- The silent failure this rig is most likely to ship with: it
				-- adopts, draws, breathes, and never animates, because nobody
				-- publishes the pose vocabulary. Say so out loud rather than
				-- letting it look like a rest pose that will not move on.
				body.fed = body.fed or isFed(model)
				if not body.fed and not body.warnedUnfed and now - body.adoptedAt > 8 then
					body.warnedUnfed = true
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
