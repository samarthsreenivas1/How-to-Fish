--!nonstrict
-- RimefangBodyController.luau
-- Draws Rimefang: a killer whale assembled from ~16 vertebrae plus a head
-- cluster, laid along the curve its pose describes.
--
-- Same contract as BrinejawBodyController, and deliberately so: the server
-- keeps authority (a hidden model at the head for hits and the HUD) and
-- publishes the pose as attributes; RimefangPath says what shape the body is
-- in, ChainPose walks that shape by arc length, and every frame each piece
-- gets one CFrame. Both sides read the same math, so what you dodge and what
-- you see cannot drift apart.
--
-- WHAT IS DIFFERENT FROM THE SERPENT, and why:
--   * SIXTEEN vertebrae, not a hundred. A whale is a rigid forebody with a
--     flexing tail; the shape lives in the head piece and the girth curve.
--   * The taper is RimefangPath.girth, NOT linear. A whale holds full girth
--     past mid-body and then pinches hard at the peduncle - a cone reads as
--     a shark.
--   * _Belly rides EVERY vertebra alongside _Body. That is how the white
--     underside runs the length of the animal without a second material on
--     the body mesh, and it is authored three times longer than the vertebra
--     pitch so consecutive panels merge instead of stair-stepping.
--   * ROLL is post-applied per link. ChainPose derives orientation from the
--     tangent with world up, so a bank cannot live in the centreline.
--   * The far-side flipper is a HALF TURN about the body axis, never a
--     mirrored scale - negative scale flips normals and renders inside-out.
--
-- Pieces come from ReplicatedStorage/Assets/RimefangPack (assets/boss_gen.py)
-- and fall back to plain tinted blocks until that import lands, so the fight
-- is never invisible. The pack is still a PENDING Studio import, so the
-- fallback is what ships TODAY and is held to the same standard as the meshes:
-- see FALLBACK_SIZE / FALLBACK_OFFSET, both measured out of the GLB.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChainPose = require(Shared.Modules.ChainPose)
local RimefangPath = require(Shared.Modules.RimefangPath)

local RimefangBodyController = {}

local CREATURES_FOLDER = "Creatures"
local PACK_NAME = "RimefangPack"
local FOLDER_NAME = "RimefangBody"
local POSE_KEY = "rimefang"

-- A whale is FIXED ANATOMY: sixteen vertebrae, a dorsal at a fixed station, a
-- fluke on the end. ChainPose:each is length-driven and gains and loses links
-- as the curve stretches - during a breach that cost five vertebrae and
-- re-mapped the girth curve onto the survivors. eachN keeps the anatomy.
--
-- RimefangPath now integrates unit directions, so its arc length is exactly
-- BODY_LENGTH in every pose and every blend between poses. The vertebra pitch
-- is therefore a CONSTANT 56 / 16 = 3.5 studs - the stretch eachN was chosen
-- to survive can no longer happen. eachN stays anyway: it is what keeps the
-- girth curve, the dorsal and the flippers pinned to the same stations, and
-- it costs nothing to be right for two reasons instead of one.
local BODY_LINKS = math.max(1, math.floor(RimefangPath.BODY_LENGTH / RimefangPath.SEG_SPACING + 0.5))
-- How much longer than its share of the curve each vertebra is drawn, so the
-- joints never open.
local SEG_OVERLAP = 1.5
-- HOW FAR AHEAD OF THE CHAIN'S START THE SKULL'S ORIGIN SITS, and the one
-- number in this file that is a shared convention rather than a local choice.
--
-- THE HEADER OF boss_gen.py IS WRONG ABOUT THIS, so do not trust it: it says
-- every piece is "centred on its own attach point... one CFrame and no
-- offsets", and the HANDOFF line says "neck joint at the origin". Neither is
-- true of the skull. RF_SKULL's rearmost ring - the one carrying the body's
-- full girth, i.e. the actual neck joint - is at x = -6.5 (its first row,
-- commented "neck joint"), so the piece origin sits 6.5 studs FORWARD of the
-- joint, inside the melon.
--
-- The real contract is that both sides push the head forward by the same
-- literal 5.2 and neither derives it: `_place_rimefang` does
-- `head_at = at_length(0) + tangent_at(0) * 5.2` and this does the same
-- through RimefangPath.HEAD_OFFSET. 5.2 - 6.5 puts the neck ring 1.3 studs
-- BEHIND the curve's start, which is what closes the joint: eachN centres
-- vertebra 1 at 1.75 studs down the curve (half of the constant 3.5-stud
-- pitch) with 5.25 studs of length, so the skull's collar overlaps it by 2.2
-- instead of leaving a gap - and does so in every pose, now that the arc
-- length no longer varies. Change 5.2 on one side only and the whale grows a
-- hole in its neck.
local HEAD_LEAD = RimefangPath.HEAD_OFFSET
local HEAD_SCALE = 1.0
local FLUKE_SCALE = 0.95
-- The dorsal and the flippers are placed at full size and moved by girth, not
-- scaled by it - see the fittings block in drawBody, and `_place_rimefang`'s
-- `place(..., 1.0, lift = ... * _rf_girth(...))`.
local FITTING_SCALE = 1.0

-- Where the fittings hang off the spine, as a fraction along the body and an
-- offset in the link's own frame (+X up-body, +Y up, +Z lateral). Mirrored
-- from the Blender preview placer in assets/boss_gen.py so the render and
-- the game agree.
local FIN_AT = 0.42
local FIN_LIFT = 6.6
local PEC_AT = 0.20
local PEC_LIFT = -3.6
-- NEGATIVE, and this was verified from the exported GLB rather than reasoned:
-- build_rf_pec authors the blade toward Blender +Y, which exports as Roblox
-- -Z, and the Pec's bbox centre in the pack sits at Z -5.1. Offsetting it +Z
-- rooted the flipper on one flank with its tip 5.8 studs out the OTHER side -
-- inside a hull only 6.8 half-wide, so NEITHER flipper ever left the body.
-- The Blender placer offsets along its own transformed +Y, so the preview
-- render looked correct and only the game was wrong.
local PEC_SIDE = -5.2

-- The jaw's hinge, from the pack's HANDOFF line: Blender (-5.4, 0, -3.2)
-- arrives as Roblox (-5.4, -3.2, 0) because Blender +Z is Roblox +Y.
local JAW_HINGE = Vector3.new(-5.4, -3.2, 0)
local JAW_MAX = math.rad(48) -- 52 put the rearmost lower tooth through the palate
-- How far the skull throws forward on a bite. The server publishes `Lunge`
-- and something has to read it: a contract field with no consumer is the
-- exact failure this project already shipped once, in the bait effects that
-- advertised behaviour nothing ran.
local LUNGE_REACH = 3.6

-- How fast the drawn pose chases the replicated one. `arch` is leap PROGRESS
-- rather than a target, so it tracks nearly rigidly - easing it would make
-- the body lag its own trajectory through the air.
local EASE = {
	swim = 4.0,
	submerge = 3.2,
	rise = 4.5,
	roll = 5.0,
	arch = 18.0,
	beached = 4.0,
	-- IN THE LUNGE BAND, not the drift band, because `flukeUp` stopped being a
	-- lift and became a SWING: RimefangPath reads it as progress through the
	-- whole lobtail (reared at 1, crossing the rest line at 0.45, hammered
	-- deepest near 0.2), and the strike drives it 1 -> 0 in 0.15 s. At 6.0
	-- this closed 1 - exp(-0.9) = 59% of that in the time the blow takes, so
	-- the hammer smeared into a wallow and landed after the damage had already
	-- gone out. At 15 it closes 89%, which reads as a slam. It stays an ease
	-- rather than a snap because the WINDUP travels the same channel, and the
	-- rear is the anticipation the blow needs.
	flukeUp = 15.0,
	faceAngle = 5.0,
	gape = 12.0,
	lunge = 14.0,
}

-- ---------------------------------------------------------------- secondary motion
--
-- Everything below is DERIVED on the client from the eased pose and its
-- velocity - no new server channel, nothing the authority model needs to know.
-- It is the difference between a posed chain and an animal: the body follows
-- the head a beat late, the fin and flukes trail the turn and ring after a
-- slam, the flippers scull, the jaw settles, and nothing is ever dead still.
-- Every ease down here is the SAME exponential `1 - exp(-rate*dt)` the pose
-- channels use, for the same reason (see `approach`): a linear filter snaps on
-- a frame hitch, and a snap is what this whole layer exists to abolish.

-- WHIP / OVERLAP LAG. Each vertebra low-passes its own rigid target position,
-- with a rate that FALLS toward the tail, so the head leads and the body
-- follows a beat later - the single biggest thing that reads as flesh rather
-- than a train. First-order, so it can never overshoot or oscillate: it only
-- eases toward the truth and settles. The lag is projected OFF the body axis
-- (kept perpendicular) and capped, so it bends the body without ever changing
-- a vertebra's share of the arc length - the eachN spacing, the girth curve
-- and the joint overlap are all untouched. The head is deliberately the
-- fastest-tracking end (rate is read at u): the drawn skull sits on the
-- authority skull, which is where the bite reads.
local LAG_RATE_HEAD = 26.0
local LAG_RATE_TAIL = 7.0
-- Comfortably under the joint overlap (0.875 stud each side). Neighbours lag
-- almost identically - the target motion and the rate profile are both smooth
-- in u - so the differential that could open a seam is a fraction of this cap.
local LAG_MAX = 1.8

-- BANK ON TURN. A lean into heading changes, derived from the turn RATE (the
-- differentiated, eased faceAngle) and laid on top of RimefangPath.rollAt so a
-- fast curve carries its speed. Smoothed and capped: the smoothing is what
-- keeps a stepped faceAngle from cracking the bank. The lean eases out toward
-- the tail on the same profile rollAt uses - a whale banks its shoulders, not
-- its flukes.
local TURN_SMOOTH = 6.0
local BANK_PER_TURN = 0.55
local BANK_MAX = math.rad(24)

-- BREATHING / IDLE LIFE. A constant low-amplitude overlay, orthogonal to the
-- path's own ambient (which lives in yaw/pitch): a slow roll and a slow
-- vertical swell of the whole body, so it is never perfectly still even at
-- rest.
local BREATH_ROLL_AMP = math.rad(1.6)
local BREATH_ROLL_RATE = 0.55
local BREATH_BOB_AMP = 0.35
local BREATH_BOB_RATE = 0.8

-- IMPACT SETTLE. One damped harmonic oscillator per body, kicked whenever a
-- fast motion STOPS (a breach re-entry, a lobtail slam), so the body rings
-- down instead of halting dead. It feeds the fin and fluke flutter, the jaw
-- chatter and a small body swell. Underdamped so it rings a few times; damping
-- is strictly positive so it always dies out. Its integrator step is CLAMPED
-- (SETTLE_MAX_DT), so a frame hitch can never make the spring explode - the
-- one place in this file a raw semi-implicit step could go unstable.
local SETTLE_FREQ = 2.4 -- Hz
local SETTLE_ZETA = 0.32 -- damping ratio: rings ~3 times, then gone
local SETTLE_K = (2 * math.pi * SETTLE_FREQ) ^ 2
local SETTLE_C = 2 * SETTLE_ZETA * (2 * math.pi * SETTLE_FREQ)
local SETTLE_MAX_DT = 1 / 45
-- How hard a stopping motion kicks the spring, per unit of lost speed.
local SETTLE_KICK_ARCH = 5.0
local SETTLE_KICK_FLUKE = 4.0
-- What the ring drives.
local SETTLE_BOB = 0.9 -- studs of body swell per unit of settle
local SETTLE_FIN = math.rad(9) -- dorsal flutter
local SETTLE_FLUKE = math.rad(11) -- fluke flutter
local SETTLE_JAW = 0.06 -- jaw chatter, as a fraction of a full gape

-- FIN & FLUKE TRAIL. The dorsal and flukes lag the body's angular velocity:
-- they lead into a turn and trail out of it. Derived from the turn rate.
local FIN_TRAIL = 0.9
local FIN_TRAIL_MAX = math.rad(20)
local FLUKE_TRAIL = 0.8
local FLUKE_TRAIL_MAX = math.rad(22)
-- FLUKE FOLLOW-THROUGH after a slam: the tail overshoots the way the swing was
-- going as it hammers down, then the settle spring rings it back. Derived from
-- flukeUp velocity (which the strike drives sharply negative).
local FLUKE_FOLLOW = 0.10
local FLUKE_FOLLOW_MAX = math.rad(16)

-- PECTORAL SCULLING. The flippers never sit rigid: a slow feather cycle plus a
-- steer that angles them with the turn. Subtle - they are stabilisers, not
-- wings - and pivoted at the shoulder so the blade sweeps rather than slides.
local PEC_SCULL_RATE = 1.3
local PEC_SCULL_AMP = math.rad(5)
local PEC_STEER = 0.7
local PEC_STEER_MAX = math.rad(14)

-- JAW LIFE. A breath-slow idle working when the mouth is near shut (so it
-- settles rather than welding closed) on top of the eased gape; the settle
-- spring's chatter rides it too.
local JAW_IDLE = 0.05
local JAW_IDLE_RATE = 1.7

-- The forebody-to-tail bank falloff, matching RimefangPath.rollAt's own ease
-- so a derived roll and the path roll die out together.
local function rollFalloff(u: number): number
	return 1 - 0.7 * math.clamp((u - 0.35) / 0.65, 0, 1)
end

-- The tooth rows are SEPARATE objects in the pack, so the lower row hinges
-- with the jaw and the mouth can open properly. As one object it had to ride
-- the skull and the gape was capped to hide the seam.
local HEAD_PIECES = { "Head", "TeethUpper", "Eyes", "Rime" }
local JAW_PIECES = { "Jaw", "TeethLower" }

local FALLBACK_COLOR = {
	Head = Color3.fromRGB(26, 31, 38),
	Jaw = Color3.fromRGB(26, 31, 38),
	TeethUpper = Color3.fromRGB(219, 212, 184),
	TeethLower = Color3.fromRGB(219, 212, 184),
	Eyes = Color3.fromRGB(184, 224, 255),
	Rime = Color3.fromRGB(230, 237, 242),
	Body = Color3.fromRGB(26, 31, 38),
	Belly = Color3.fromRGB(230, 237, 242),
	Fin = Color3.fromRGB(158, 204, 224),
	Pec = Color3.fromRGB(26, 31, 38),
	Fluke = Color3.fromRGB(26, 31, 38),
}
-- MEASURED, not reasoned: every number below is the per-piece bounding box of
-- assets/boss_rimefang.glb, read straight out of the file's POSITION
-- accessors. Deriving them from boss_gen.py's radii instead is wrong by up to
-- 15% - `ellipsoid` is an icosphere, and an icosphere only touches its
-- nominal radius at the poles, so _Belly's authored 6.0-stud spread arrives
-- as 5.1.
local FALLBACK_SIZE = {
	Head = Vector3.new(15.1, 10.0, 13.8),
	Jaw = Vector3.new(14.0, 4.6, 12.4),
	TeethUpper = Vector3.new(12.7, 3.0, 13.0),
	TeethLower = Vector3.new(12.7, 3.0, 11.7),
	Eyes = Vector3.new(1.1, 1.0, 13.9),
	-- NOT the mesh's bounding box, and the one deliberate departure in this
	-- table. _Rime is two eye patches on opposite flanks plus a throat panel,
	-- so its bbox is the whole head - a block that size simply ENCLOSES the
	-- skull and the stand-in turns into a white boulder. This is the eye
	-- patch itself instead (_rf_patch: 8.6 long, 3.8 high, at x -4.1, z 2.3),
	-- run wide enough through the head to surface as a white slab on each
	-- flank, which is the marking that carries the whole orca read.
	Rime = Vector3.new(8.6, 3.8, 14.0),
	Body = Vector3.new(5.4, 13.7, 13.2),
	Belly = Vector3.new(11.1, 2.2, 5.1),
	Fin = Vector3.new(9.2, 14.1, 1.5),
	Pec = Vector3.new(9.3, 3.7, 13.0),
	Fluke = Vector3.new(8.0, 2.8, 23.0),
}

-- FALLBACK ONLY, and that is the whole point of it being a separate table.
--
-- boss_gen.py's pieces are NOT centred on their attach points: _Belly is
-- authored 6.3 studs under the spine, _Jaw hangs 4.9 below the head's origin,
-- the dorsal rises 5.6 above its mount, the flipper's blade runs 5.1 out its
-- own flank. An imported piece therefore arrives with the offset already in
-- its vertices and needs nothing from us. A fallback BLOCK carries no
-- geometry at all, so drawn on the bare attach point it stacks every piece
-- through the middle of the animal: the white belly panel sawed through the
-- waist, the jaw sat inside the skull so no gape was visible, and both
-- flippers straddled their flank half-in half-out.
--
-- So this is applied in applyPiece/applyTapered from an attribute that ONLY
-- the fallback branch of makePiece ever sets. Adding it to an imported clone
-- would double the offset.
--
-- Same source as FALLBACK_SIZE: bbox CENTRE per piece out of the GLB.
local FALLBACK_OFFSET = {
	Head = Vector3.new(1.05, 2.8, 0),
	Jaw = Vector3.new(1.0, -4.9, 0),
	TeethUpper = Vector3.new(1.21, -3.31, 0),
	TeethLower = Vector3.new(1.21, -1.49, 0),
	Eyes = Vector3.new(-2.6, -1.5, 0),
	Rime = Vector3.new(-4.1, 2.3, 0),
	-- Body is the one piece genuinely centred on its joint (RF_SEG runs
	-- -2.7..+2.7 about zero), so it has no entry.
	Belly = Vector3.new(0, -6.3, 0),
	Fin = Vector3.new(0, 5.56, 0),
	-- The blade runs OUT from the shoulder it is mounted on, so this stacks
	-- on top of PEC_SIDE rather than replacing it - exactly as the mesh does.
	-- Applied inside applyPiece, after the far-side half turn, so the mirrored
	-- flipper reaches out its own flank instead of back across the body.
	Pec = Vector3.new(-1.77, -0.61, -5.14),
	Fluke = Vector3.new(-0.93, 0, 0),
}

-- model -> the live body
local bodies = {}

-- ---------------------------------------------------------------- pieces

-- Materials a glTF import cannot carry. Every part lands SmoothPlastic
-- unless someone sets it by hand in Studio, and unlike ARENA meshes - where
-- BossArenaService drives material off the object name - a boss pack has no
-- name-driven pass at all: the body controller is the only thing that ever
-- touches these parts. So the rig states them here rather than depending on
-- an import step nobody will remember. Ice on the dorsal matches the four
-- big glacial forms on Frostmaw itself.
local PIECE_MATERIAL = {
	Eyes = Enum.Material.Neon,
	Fin = Enum.Material.Ice,
}

local function packPiece(name: string): BasePart?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local pack = assets and assets:FindFirstChild(PACK_NAME)
	local piece = pack and pack:FindFirstChild("Rimefang_" .. name, true)
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
		part.Color = FALLBACK_COLOR[name] or Color3.fromRGB(26, 31, 38)
		part.Material = Enum.Material.SmoothPlastic
		-- The stand-in's share of the geometry the real mesh carries in its
		-- vertices. Set HERE and nowhere else: an imported clone must never
		-- pick this up or its offset lands twice.
		local offset = FALLBACK_OFFSET[name]
		if offset then
			part:SetAttribute("PieceOffset", offset)
		end
	end
	-- Applied to the imported clone AND the fallback block, so the whale looks
	-- the same either side of the import.
	if PIECE_MATERIAL[name] then
		part.Material = PIECE_MATERIAL[name]
	end
	part.Name = "Rimefang_" .. name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.Parent = parent
	return part
end

-- A vertebra: girth on the two cross-section axes, length off its share of
-- the curve so consecutive links always overlap.
local function applyTapered(part: BasePart, cframe: CFrame, spacing: number, girth: number)
	local base = part:GetAttribute("BaseSize")
	if not base then
		base = part.Size
		part:SetAttribute("BaseSize", base)
	end
	-- Nil for every imported piece; a fallback block's authored seat otherwise.
	-- It rides the CROSS-SECTION axes only, like the size does: the peduncle's
	-- belly panel has to close in toward the spine as the body pinches, or the
	-- white runs on into thin air behind the tail.
	local offset = part:GetAttribute("PieceOffset")
	part.CFrame = if offset then cframe * CFrame.new(offset.X, offset.Y * girth, offset.Z * girth) else cframe
	part.Size = Vector3.new(math.max(spacing * SEG_OVERLAP, 0.2), base.Y * girth, base.Z * girth)
end

local function applyPiece(part: BasePart, cframe: CFrame, scale: number)
	local base = part:GetAttribute("BaseSize")
	if not base then
		base = part.Size
		part:SetAttribute("BaseSize", base)
	end
	-- See FALLBACK_OFFSET: nil unless this part is a stand-in block. It scales
	-- with the piece, because scaling a mesh scales it about its own origin
	-- and carries the geometry's offset along with it.
	local offset = part:GetAttribute("PieceOffset")
	part.CFrame = if offset then cframe * CFrame.new(offset * scale) else cframe
	part.Size = base * scale
end

-- ---------------------------------------------------------------- pose

-- Every pose attribute `rimefangDrive` publishes, checked against it: Swim,
-- Submerge, Rise, Roll, Arch, Beached, FlukeUp, FaceAngle, Gape, Lunge - plus
-- Pose and PoseCenter, read at adopt time, and OpenUntil, which is the punish
-- window's deadline for BossHudController and means nothing to the body. A
-- field with no consumer is the failure this project already shipped once, so
-- if a new one appears there it belongs here too.
local function readTarget(model: Model, target)
	target.swim = model:GetAttribute("Swim") or 1
	target.submerge = model:GetAttribute("Submerge") or 0
	target.rise = model:GetAttribute("Rise") or 0
	target.roll = model:GetAttribute("Roll") or 0
	target.arch = model:GetAttribute("Arch") or 0
	target.beached = model:GetAttribute("Beached") or 0
	target.flukeUp = model:GetAttribute("FlukeUp") or 0
	target.faceAngle = model:GetAttribute("FaceAngle") or 0
	target.gape = model:GetAttribute("Gape") or 0
	target.lunge = model:GetAttribute("Lunge") or 0
	return target
end

-- EXPONENTIAL, not `rate * dt`. The linear form closes a fixed FRACTION of
-- the gap per second only while dt is small; on a hitch it races toward 1 and
-- the body SNAPS - precisely when a snap is most visible. At EASE.arch = 18 a
-- single 55ms frame is enough to saturate the clamp and teleport the whale.
local function approach(current: number, goal: number, rate: number, dt: number): number
	return current + (goal - current) * (1 - math.exp(-rate * dt))
end

local function approachAngle(current: number, goal: number, rate: number, dt: number): number
	local delta = (goal - current + math.pi) % (math.pi * 2) - math.pi
	return current + delta * (1 - math.exp(-rate * dt))
end

-- Shortest signed angle, for differentiating a wrapped heading: a turn across
-- north must read as a small step, not a lap of the circle.
local function wrapAngle(a: number): number
	return (a + math.pi) % (math.pi * 2) - math.pi
end

-- ---------------------------------------------------------------- lifecycle

-- One entry per model this controller has ever seen in the Creatures folder,
-- weak-keyed so it never keeps a dead creature alive. Its job is to make both
-- of this file's connections COUNTABLE: at most one Pose listener and at most
-- one AncestryChanged listener per model, and the Pose listener released once
-- the answer can no longer change.
local watched = setmetatable({}, { __mode = "k" }) :: any

local function destroyBody(model: Model)
	local body = bodies[model]
	if not body then
		return
	end
	bodies[model] = nil
	local entry = watched[model]
	if entry and entry.ancestry then
		entry.ancestry:Disconnect()
		entry.ancestry = nil
	end
	if body.folder then
		body.folder:Destroy()
	end
end

local function adoptBoss(model: Model)
	if bodies[model] or model:GetAttribute("Pose") ~= POSE_KEY then
		return
	end

	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = Workspace

	local state = RimefangPath.newState(model:GetAttribute("PoseCenter") or model:GetPivot().Position)
	readTarget(model, state)

	local body = {
		folder = folder,
		state = state,
		target = readTarget(model, {}),
		-- Cost scales with SAMPLES, not links: 160 is the serpent's budget for
		-- a hundred vertebrae. 96 is 0.65 studs per sample on the longest
		-- pose this body reaches.
		chain = ChainPose.new(function(s, t)
			return RimefangPath.pointAt(s, t)
		end, { samples = 96 }),
		segments = {},
		bellies = {},
		head = {},
		jaw = {},
		-- Secondary-motion memory. Each whip filter's lagged position is stored
		-- per link (nil until its first frame, then seeded to the target so it
		-- never pops in). The velocities and the settle spring start from the
		-- adopted pose at rest, so nothing kicks on spawn.
		lagPos = {},
		flukeLagPos = nil,
		turnRate = 0,
		lastFace = state.faceAngle,
		lastArch = state.arch,
		archVel = 0,
		lastFluke = state.flukeUp,
		flukeVel = 0,
		settle = 0,
		settleVel = 0,
	}

	for _, name in HEAD_PIECES do
		body.head[name] = makePiece(name, folder)
	end
	for _, name in JAW_PIECES do
		body.jaw[name] = makePiece(name, folder)
	end
	body.fin = makePiece("Fin", folder)
	body.pecLeft = makePiece("Pec", folder)
	body.pecRight = makePiece("Pec", folder)
	body.fluke = makePiece("Fluke", folder)

	bodies[model] = body
	-- ONE per model, not one per adopt. `adoptBoss` runs again on every Pose
	-- change, and this used to add a fresh handler each time - so a boss that
	-- rewrote its pose kind n times died n times over, and every one of those
	-- closures outlived the body it was created for.
	local entry = watched[model]
	if not entry then
		entry = {}
		watched[model] = entry
	end
	if not entry.ancestry then
		entry.ancestry = model.AncestryChanged:Connect(function(_, parent)
			if parent == nil then
				destroyBody(model)
			end
		end)
	end
end

-- ---------------------------------------------------------------- per frame

local function drawBody(model: Model, body, dt: number, now: number)
	local state, target = body.state, readTarget(model, body.target)
	state.swim = approach(state.swim, target.swim, EASE.swim, dt)
	state.submerge = approach(state.submerge, target.submerge, EASE.submerge, dt)
	state.rise = approach(state.rise, target.rise, EASE.rise, dt)
	state.roll = approachAngle(state.roll, target.roll, EASE.roll, dt)
	state.arch = approach(state.arch, target.arch, EASE.arch, dt)
	state.beached = approach(state.beached, target.beached, EASE.beached, dt)
	state.flukeUp = approach(state.flukeUp, target.flukeUp, EASE.flukeUp, dt)
	state.faceAngle = approachAngle(state.faceAngle, target.faceAngle, EASE.faceAngle, dt)
	state.gape = approach(state.gape, target.gape, EASE.gape, dt)
	state.lunge = approach(state.lunge, target.lunge, EASE.lunge, dt)
	state.center = model:GetAttribute("PoseCenter") or state.center
	state.time = now

	local chain = body.chain
	chain:update(state)

	-- ------------------------------------------------ derived secondary motion
	-- Angular and pose velocities, differentiated from the EASED state (the
	-- drawn body is what has to curve and ring, not the stepped target) and
	-- smoothed so a single stepped attribute cannot crack them. dt is 0 on the
	-- very first frame, so the differences are guarded.
	--
	-- The speeds BEFORE this frame's update are captured first: the settle
	-- spring is kicked by the DROP in speed - the instant a fast motion stops,
	-- which is exactly a breach re-entry or the bottom of a lobtail slam.
	local prevArchSpeed = math.abs(body.archVel)
	local prevFlukeSpeed = math.abs(body.flukeVel)
	if dt > 0 then
		body.turnRate = approach(body.turnRate, wrapAngle(state.faceAngle - body.lastFace) / dt, TURN_SMOOTH, dt)
		body.archVel = approach(body.archVel, (state.arch - body.lastArch) / dt, TURN_SMOOTH, dt)
		body.flukeVel = approach(body.flukeVel, (state.flukeUp - body.lastFluke) / dt, TURN_SMOOTH, dt)
	end
	body.lastFace = state.faceAngle
	body.lastArch, body.lastFluke = state.arch, state.flukeUp

	-- IMPACT SETTLE: a damped spring kicked by the lost speed, integrated on a
	-- CLAMPED step. A gentle deceleration feeds it over several frames (the
	-- velocities are themselves eased), so the ring builds smoothly rather than
	-- from one spiked frame; the clamp guarantees the semi-implicit step stays
	-- stable even on a 100 ms hitch (omega*dt = 0.33 << 2 at the clamp).
	local kick = SETTLE_KICK_ARCH * math.max(0, prevArchSpeed - math.abs(body.archVel))
		+ SETTLE_KICK_FLUKE * math.max(0, prevFlukeSpeed - math.abs(body.flukeVel))
	local sdt = math.min(dt, SETTLE_MAX_DT)
	body.settleVel += (-SETTLE_K * body.settle - SETTLE_C * body.settleVel) * sdt + kick
	body.settle += body.settleVel * sdt
	local settle = body.settle

	-- Bank the forebody into the turn, on top of rollAt, with a slow breathing
	-- roll underneath so the body is never dead level. A slow vertical swell
	-- (plus the settle ring) keeps the whole body breathing.
	local bankTurn = math.clamp(body.turnRate * BANK_PER_TURN, -BANK_MAX, BANK_MAX)
	local breathRoll = BREATH_ROLL_AMP * math.sin(now * BREATH_ROLL_RATE)
	local bob = BREATH_BOB_AMP * math.sin(now * BREATH_BOB_RATE) + settle * SETTLE_BOB
	local bobVec = Vector3.new(0, bob, 0)

	-- Body: one CFrame per vertebra, tapered by the girth curve and banked by
	-- the per-link roll. _Belly rides the same frame.
	local used = 0
	chain:eachN(BODY_LINKS, function(index, cframe, u, spacing)
		used = index
		-- WHIP: low-pass this vertebra's rigid position, fast at the head and
		-- slow at the tail, keep only the part ACROSS the body axis, and cap it -
		-- so the body trails without its arc length, spacing or joints changing.
		local targetPos = cframe.Position
		local lagged = body.lagPos[index] or targetPos
		local rate = LAG_RATE_HEAD + (LAG_RATE_TAIL - LAG_RATE_HEAD) * u
		lagged = lagged + (targetPos - lagged) * (1 - math.exp(-rate * dt))
		body.lagPos[index] = lagged
		local off = lagged - targetPos
		local axis = cframe.RightVector
		off = off - axis * off:Dot(axis)
		if off.Magnitude > LAG_MAX then
			off = off.Unit * LAG_MAX
		end
		-- Roll: the path's bank plus the turn lean and breathing roll, both
		-- eased out toward the tail on rollAt's own falloff.
		local roll = RimefangPath.rollAt(state, u) + (bankTurn + breathRoll) * rollFalloff(u)
		local framed = CFrame.new(off + bobVec) * cframe * CFrame.Angles(roll, 0, 0)
		local girth = RimefangPath.girth(u)
		local segment = body.segments[index]
		if not segment then
			segment = makePiece("Body", body.folder)
			body.segments[index] = segment
		end
		-- The taper touches GIRTH ONLY. Scaling length by it as well turned
		-- the peduncle into a dotted line: past u 0.76 the vertebra grew
		-- shorter than its own pitch and the last four floated apart. Length
		-- covers this link's share of the curve, with overlap.
		applyTapered(segment, framed, spacing, girth)

		local belly = body.bellies[index]
		if not belly then
			belly = makePiece("Belly", body.folder)
			body.bellies[index] = belly
		end
		applyTapered(belly, framed, spacing, girth)
	end)
	for index = used + 1, #body.segments do
		body.segments[index].CFrame = CFrame.new(0, -5000, 0)
		if body.bellies[index] then
			body.bellies[index].CFrame = CFrame.new(0, -5000, 0)
		end
	end

	-- Head cluster, ahead of the chain's start by HEAD_LEAD - which is NOT the
	-- skull's neck joint, whatever boss_gen.py's header says. See HEAD_LEAD.
	-- The head takes the full bank and breathing roll (rollFalloff(0) = 1) and
	-- rides the same body swell, so head and first vertebra never seam apart.
	-- It is otherwise UN-LAGGED: the drawn skull sits on the authority skull,
	-- which is what the bite and the lunge telegraph read from.
	local headRoll = RimefangPath.rollAt(state, 0) + bankTurn + breathRoll
	local headFrame = CFrame.new(bobVec)
		* chain:cframeAt(0)
		* CFrame.Angles(headRoll, 0, 0)
		* CFrame.new(HEAD_LEAD + state.lunge * LUNGE_REACH, 0, 0)
	for _, name in HEAD_PIECES do
		applyPiece(body.head[name], headFrame, HEAD_SCALE)
	end
	-- The jaw swings about its hinge rather than sliding: rotate around the
	-- pivot point, not the piece's own origin. The eased gape gets a breath-slow
	-- idle working when the mouth is near shut (so it settles rather than
	-- welding) and the settle spring's chatter; clamped so the teeth can never
	-- drive through the palate.
	local gapeDraw = math.clamp(
		state.gape + JAW_IDLE * (0.5 + 0.5 * math.sin(now * JAW_IDLE_RATE)) * (1 - state.gape) + settle * SETTLE_JAW,
		0,
		1
	)
	local jawFrame = headFrame
		* CFrame.new(JAW_HINGE)
		* CFrame.Angles(0, 0, -gapeDraw * JAW_MAX)
		* CFrame.new(-JAW_HINGE)
	for _, name in JAW_PIECES do
		applyPiece(body.jaw[name], jawFrame, HEAD_SCALE)
	end

	-- Fittings. Offsets are in each link's own frame, so a banked whale keeps
	-- its dorsal on its back and its flippers on its flanks.
	--
	-- GIRTH MOVES THE MOUNT, NOT THE FIN. `_place_rimefang` passes scale 1.0
	-- for both fittings and multiplies only its `lift` and `side` by
	-- `_rf_girth`, which is anatomy: a whale's dorsal does not shrink because
	-- it sits where the body is narrower, it just sits closer to the spine.
	-- This scaled the PART by girth too. It happens to be invisible today -
	-- girth() is exactly 1.0 across 0.16..0.46 and both stations land inside
	-- that plateau - so the render and the game agreed by luck, and moving
	-- FIN_AT one notch past 0.46 would have silently parted them. Now they
	-- agree by construction: girth is read once, into the OFFSET only.
	local finGirth = RimefangPath.girth(FIN_AT)
	local finRoll = RimefangPath.rollAt(state, FIN_AT) + (bankTurn + breathRoll) * rollFalloff(FIN_AT)
	-- The dorsal trails the body's turn - leaning in as the turn starts,
	-- trailing out of it - and flutters fore/aft on the settle ring. Pivoted
	-- at the mount on the back (after the lift), so the blade flexes at its base.
	local finTrail = math.clamp(-body.turnRate * FIN_TRAIL, -FIN_TRAIL_MAX, FIN_TRAIL_MAX)
	local finFrame = CFrame.new(bobVec) * chain:cframeAt(chain.length * FIN_AT) * CFrame.Angles(finRoll, 0, 0)
	applyPiece(
		body.fin,
		finFrame * CFrame.new(0, FIN_LIFT * finGirth, 0) * CFrame.Angles(finTrail, 0, settle * SETTLE_FIN),
		FITTING_SCALE
	)

	local pecGirth = RimefangPath.girth(PEC_AT)
	local pecRoll = RimefangPath.rollAt(state, PEC_AT) + (bankTurn + breathRoll) * rollFalloff(PEC_AT)
	local pecFrame = CFrame.new(bobVec) * chain:cframeAt(chain.length * PEC_AT) * CFrame.Angles(pecRoll, 0, 0)
	-- Sculling: a slow feather cycle both flippers share, plus a steer that
	-- angles them with the turn. Applied AT the shoulder mount (after the side
	-- offset), so the blade sweeps about its root instead of sliding off the
	-- flank.
	local scull = PEC_SCULL_AMP * math.sin(now * PEC_SCULL_RATE)
	local steer = math.clamp(body.turnRate * PEC_STEER, -PEC_STEER_MAX, PEC_STEER_MAX)
	applyPiece(
		body.pecLeft,
		pecFrame * CFrame.new(0, PEC_LIFT * pecGirth, PEC_SIDE * pecGirth) * CFrame.Angles(0, scull + steer, 0),
		FITTING_SCALE
	)
	-- Half turn about the BODY AXIS for the far side. A mirrored scale would
	-- invert the normals and render the flipper inside-out. The scull is applied
	-- AFTER the half turn so it sweeps in the flipped frame too.
	applyPiece(
		body.pecRight,
		pecFrame
			* CFrame.new(0, PEC_LIFT * pecGirth, -PEC_SIDE * pecGirth)
			* CFrame.Angles(math.pi, 0, 0)
			* CFrame.Angles(0, scull - steer, 0),
		FITTING_SCALE
	)

	-- THE FLUKE BANKS WITH ITS PEDUNCLE. It is bolted to the last vertebra, so
	-- it takes that vertebra's roll - `rollAt(1)`, the same call the last
	-- eachN link above makes. Left un-rolled, a wash at -74 degrees banked the
	-- tail 22 degrees and the flukes zero, and the tail visibly sheared at the
	-- joint. Note rollAt already eases the bank OUT along the body (a whale
	-- rolls its shoulders, not its tail): "flat-ish at the flukes" is that
	-- easing's job, expressed once, and not a second rule here.
	--
	-- The -1.2 seat has no counterpart in `_place_rimefang`, which places the
	-- fluke on at_length(total) flat. It is here because eachN centres links
	-- in their share of the curve, so the last vertebra's CENTRE sits half a
	-- pitch - a fixed 1.75 studs - short of chain.length; the seat pulls the
	-- fluke's boss back into the peduncle instead of leaving it hanging off
	-- the end.
	-- The flukes are the tail's tip: they take the most whip and the most flex.
	-- Same perpendicular-projected, capped lag as a vertebra, at the tail rate,
	-- so the tail's own follow-through reads without stretching the peduncle.
	local flukeTargetPos = chain:pointAt(chain.length)
	local flukeLag = body.flukeLagPos or flukeTargetPos
	flukeLag = flukeLag + (flukeTargetPos - flukeLag) * (1 - math.exp(-LAG_RATE_TAIL * dt))
	body.flukeLagPos = flukeLag
	local flukeOff = flukeLag - flukeTargetPos
	local flukeAxis = RimefangPath.tangentAt(state, 1)
	flukeOff = flukeOff - flukeAxis * flukeOff:Dot(flukeAxis)
	if flukeOff.Magnitude > LAG_MAX then
		flukeOff = flukeOff.Unit * LAG_MAX
	end
	local flukeRoll = RimefangPath.rollAt(state, 1) + (bankTurn + breathRoll) * rollFalloff(1)
	-- Trail the turn; follow through after a slam (the strike drives flukeVel
	-- sharply negative, so -flukeVel throws the flukes on past the swing) and
	-- flutter on the settle ring; both about the peduncle joint.
	local flukeTrail = math.clamp(body.turnRate * FLUKE_TRAIL, -FLUKE_TRAIL_MAX, FLUKE_TRAIL_MAX)
	local flukeFollow = math.clamp(-body.flukeVel * FLUKE_FOLLOW, -FLUKE_FOLLOW_MAX, FLUKE_FOLLOW_MAX)
	local flukeFrame = CFrame.new(flukeOff + bobVec) * chain:cframeAt(chain.length) * CFrame.Angles(flukeRoll, 0, 0)
	applyPiece(
		body.fluke,
		flukeFrame * CFrame.Angles(0, flukeTrail, flukeFollow + settle * SETTLE_FLUKE) * CFrame.new(-1.2, 0, 0),
		FLUKE_SCALE
	)
end

-- How long a model gets to declare itself a rimefang before we stop listening.
--
-- CreatureService writes `Pose` from rimefangState, on the boss's FIRST drive
-- frame - the model is parented, then the very next server step stamps
-- PoseCenter and Pose together. So the answer always arrives within a frame or
-- two of the ChildAdded that brought us here, and a model still silent after
-- this window is not a whale and never will be.
--
-- Why bound it at all: `watch` fires for EVERY creature - a bay full of
-- ordinary fish - and each of the seven body controllers was leaving a
-- permanent attribute listener on each one, seven dead closures per fish for
-- the fish's whole life. Adopted bodies keep theirs (one per live boss, which
-- is the point of it); everything else lets go.
local POSE_WINDOW = 20

local function watch(child: Instance)
	-- Once per model. A model re-parented back into the folder fires
	-- ChildAdded again, and without this it collected a second listener each
	-- time round.
	if not child:IsA("Model") or watched[child] then
		return
	end
	local entry = { pose = nil :: RBXScriptConnection?, ancestry = nil :: RBXScriptConnection? }
	watched[child] = entry
	adoptBoss(child)
	entry.pose = child:GetAttributeChangedSignal("Pose"):Connect(function()
		adoptBoss(child)
	end)
	task.delay(POSE_WINDOW, function()
		-- Still not ours, so nothing it says about `Pose` from here on can
		-- matter. A body that DID adopt keeps listening.
		if entry.pose and not bodies[child] then
			entry.pose:Disconnect()
			entry.pose = nil
		end
	end)
end

function RimefangBodyController.init()
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

-- How long a body that is failing to draw stays quiet between reports.
--
-- The flag used to be one per SESSION, which made a persistent fault report
-- itself exactly once and then vanish: after that first line the rig went on
-- burning a full drawBody and a pcall every frame, for every whale, with
-- nothing in the log to say the fight was broken and no way to tell a fixed
-- fault from a still-broken one. Per BODY, and repeated on a slow clock with
-- the count attached, a stuck rig keeps saying so - about six lines a minute,
-- which is a signal rather than a flood.
local WARN_EVERY = 10

function RimefangBodyController.start()
	RunService.RenderStepped:Connect(function(dt)
		-- Server time, not os.clock(): the swim cycle is computed from this on
		-- BOTH sides, and two machines' clocks share no epoch.
		local now = Workspace:GetServerTimeNow()
		for model, body in bodies do
			if model.Parent then
				-- Guarded: an error here would abort the whole RenderStepped
				-- callback and freeze every other body on screen with no clue
				-- why. Say it, keep rendering.
				local ok, err = pcall(drawBody, model, body, dt, now)
				if not ok then
					body.failures = (body.failures or 0) + 1
					if now >= (body.warnAt or 0) then
						body.warnAt = now + WARN_EVERY
						warn(("[RimefangBody] draw failed (%d so far): %s"):format(body.failures, tostring(err)))
					end
				elseif body.failures then
					-- It recovered. Said once, then quiet: a rig that came back
					-- is as worth knowing as one that went away.
					warn(("[RimefangBody] draw recovered after %d failed frames"):format(body.failures))
					body.failures, body.warnAt = nil, nil
				end
			else
				destroyBody(model)
			end
		end
	end)
end

return RimefangBodyController
