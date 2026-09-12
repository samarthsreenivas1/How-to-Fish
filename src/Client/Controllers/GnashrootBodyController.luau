--!nonstrict
-- GnashrootBodyController.luau
-- Draws Old Gnashroot: one mud colossus ROOTED in the Rootmere, sunk to the
-- waist, with a long root-and-mud arm hung off each FRONT shoulder.
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
-- EVERY CLUSTER OBJECT IS AUTHORED IN ONE SHARED SPACE at its final offset -
-- boss_gen's `_place_gnashroot` places the whole cluster at Vector((0, 0, 0))
-- precisely because every piece already carries its own position - so a piece
-- placed on the body CFrame ALONE lands on the body origin, not on the body.
-- Measured off assets/boss_gnashroot.glb: the skull spans x 9.2..18.4, the
-- mass y 0.0..26.9, the core sits at (8.83, 18.66, 0.12). Drop those offsets
-- and the body pieces stack into a single ~40-stud ball of mud, with no error
-- and no nil to notice it by.
--
-- THE TWO MODULES ARE THE EXCEPTION and are authored at the ORIGIN, because
-- they are placed many times: `Arm`/`ArmKnot`/`Hand` ride the two chains, and
-- `Eye` is instanced once per GnashrootPath.EYE_SEATS entry.
--
-- So this file does what WrackBodyController does for an identically-authored
-- pack: it measures each piece's offset ONCE, at adopt, from the pack itself
-- (`packAnchor` / `seatOf`), and thereafter moves the whole animal with one
-- CFrame. The `AUTHORED` table below is the same measurement taken off the
-- glb, and it does two jobs: it places the stand-ins when the pack is missing,
-- and it is what keeps the stand-in and the clone in the same spot. It is not
-- taken by hand any more: every row is printed straight off the .glb's node
-- bounding boxes and asserted against this file, which is what caught the
-- 2026-09-12 rebuild placing five pieces at the OLD pack's offsets.

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
local TIP_GIRTH = 0.50
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
local BODY_PIECES = { "Mass", "Roots", "Head", "Core", "Stones", "Teeth" }
local JAW_PIECES = { "Jaw", "Fangs", "Maw" }
-- Everything the pack can hold and this file has a placement for. The adopt
-- audit below compares the imported pack against this set and NAMES whatever
-- it has no home for - which is how the user's fifth complaint ("make sure
-- all parts are aligned during its animations so we don't have static parts")
-- actually happens: a leftover object from a previous pack imports, is never
-- placed, and stands at the pack's own origin inside the animal forever.
local PLACED_PIECES = {
	Mass = true,
	Roots = true,
	Head = true,
	Core = true,
	Stones = true,
	Teeth = true,
	Jaw = true,
	Fangs = true,
	Maw = true,
	Drips = true,
	Eye = true,
	Arm = true,
	ArmKnot = true,
	Hand = true,
}

-- How fast the drawn pose chases the replicated one. `blend` and `strike` are
-- PROGRESS through an attack rather than targets, so they track nearly
-- rigidly - easing them would put the fist behind its own blow, which is the
-- one lag a player can see and cannot forgive. The rest is free to be slow.
-- `approach` is a LINEAR lerp toward the goal at `rate` per second, so these
-- are fractions and not exponential time constants. At 60 fps a rate r
-- reaches 99% of a step in -ln(0.01) / (60 * -ln(1 - r/60)) seconds, and the
-- numbers below are chosen off that identity rather than by feel:
--
--   rise 3.7    -> 1.20 s   the whole emergence, and the one slow channel
--   face 8.5    -> 0.50 s   the idle watch turning to look at you
--   blend 8.5   -> 0.50 s   how far the body is into an attack's pose
--   jaw 8.5     -> 0.50 s   the gape, on its own channel (see below)
--   strike 12.0 -> 0.35 s   the blow itself
--   exposed 6.0 -> 0.74 s   the punish window's extra pitch
--
-- SLOWER THAN THEY WERE, deliberately: the morning build ran blend at 14 and
-- strike at 22 (0.29 s and 0.19 s), which on a rig whose limb was five long
-- bones read as the arms SNAPPING between poses - half of the user's
-- "choppy". `strike` is still the fastest of the fast channels and always
-- must be: it is the moment of impact, and easing it back to the rest of the
-- group would put the fist behind its own blow, which is the one lag a
-- player can see and cannot forgive.
local EASE = { rise = 3.7, face = 8.5, blend = 8.5, jaw = 8.5, strike = 12.0, exposed = 6.0 }

-- The last-resort tint for a piece MeshColors has no row for. All fourteen
-- objects have one, so this only ever covers a re-export that adds a
-- fifteenth before the generator is re-run.
local MUD = Color3.fromRGB(107, 71, 43)
-- The core lit, read from the same generated table as everything else so the
-- ember and the mesh cannot drift (it is GN_WISP, the row's markColor).
local CORE_LIT = MeshColors.get(PREFIX .. "Core") or Color3.fromRGB(150, 235, 200)
-- What the core looks like between windows: banked, not dark. A core that
-- goes out entirely leaves the player nothing to learn the target from. This
-- one IS this file's own - it is a state the builder has no opinion about.
local CORE_BANKED = Color3.fromRGB(58, 104, 88)
-- THE EYE ROW'S TWO STATES. Shut is GN_EYE off the generated table (wet, dark,
-- set into the mud); lit is the core's own wisp, because the light in this
-- animal has ONE colour and a second hue would read as a second mechanic.
-- `Eyes` (GnashrootPath.eyeLit) crossfades between them per instance.
local EYE_SHUT = MeshColors.get(PREFIX .. "Eye") or Color3.fromRGB(26, 23, 20)
local EYE_LIT = CORE_LIT
-- How many eyes there are is the PATH's business, not this file's: the seats
-- and their order are the choreography (see EYE_SEATS there).
local EYE_COUNT = GnashrootPath.EYE_COUNT

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
	Mass = { at = Vector3.new(-0.378, 13.400, 0.000), size = Vector3.new(19.94, 26.80, 23.45) },
	Roots = { at = Vector3.new(0.074, 5.432, 0.499), size = Vector3.new(47.08, 10.86, 40.20) },
	-- THE SKULL IS ON TOP NOW (y 24.6..32.3 authored). It was y 10.2..14.8 on
	-- a body whose crown was 27 - a mouth in the middle of a mound, which is
	-- the read the user rejected ("the jaw should maybe be at the top of the
	-- body not in the middle").
	Head = { at = Vector3.new(6.850, 28.424, 0.000), size = Vector3.new(16.50, 7.65, 13.07) },
	Jaw = { at = Vector3.new(8.470, 21.656, 0.000), size = Vector3.new(15.06, 5.49, 10.37) },
	Maw = { at = Vector3.new(8.350, 23.200, 0.000), size = Vector3.new(12.70, 2.60, 8.60) },
	Teeth = { at = Vector3.new(8.150, 23.616, 0.000), size = Vector3.new(10.18, 2.44, 5.98) },
	Fangs = { at = Vector3.new(9.050, 22.580, 0.000), size = Vector3.new(10.11, 2.21, 5.15) },
	-- Dead on GnashrootPath.CORE in x and y, because the knot is a single
	-- smooth ellipsoid now with six short shards inside its own silhouette -
	-- where the morning build's eight ragged spines pulled the box 0.51 studs
	-- off the constant the HUD marker and the server's punish target use.
	Core = { at = Vector3.new(8.200, 16.200, 0.000), size = Vector3.new(4.37, 4.60, 5.00) },
	Stones = { at = Vector3.new(-5.280, 16.950, 0.364), size = Vector3.new(8.16, 13.70, 15.06) },
	Drips = { at = Vector3.new(3.833, 18.326, -0.012), size = Vector3.new(5.01, 19.70, 19.16) },
	-- THE MODULES, authored at the origin and placed many times. `at` is the
	-- offset from the instance's own axis to its box centre, applied in the
	-- chain's (or the eye seat's) frame rather than the body's. The Arm and
	-- the Eye are symmetric; the ArmKnot's box hangs 0.335 below its tube
	-- because its swell does, and placing its CENTRE on the path would ride
	-- the bone high at rest - a step at every fourth vertebra.
	Arm = { at = Vector3.new(0.000, 0.000, 0.000), size = Vector3.new(3.80, 6.76, 6.76) },
	ArmKnot = { at = Vector3.new(0.000, -0.335, 0.000), size = Vector3.new(4.57, 7.43, 7.80) },
	Hand = { at = Vector3.new(-1.796, -0.236, -0.828), size = Vector3.new(8.79, 7.27, 10.93) },
	-- Radius 1 at the origin: `newEyes` scales each instance by its seat's own
	-- radius, so this row's size is the UNIT eye and not any eye on the animal.
	Eye = { at = Vector3.new(0.000, 0.000, 0.000), size = Vector3.new(1.90, 1.84, 2.00) },
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
	Eye = Enum.PartType.Ball,
	Arm = Enum.PartType.Cylinder, -- a Roblox cylinder's axis IS +X: the pack convention
	ArmKnot = Enum.PartType.Cylinder,
	Hand = Enum.PartType.Ball,
}

-- THREE PIECES ARE SCATTERS, not solids: Stones is 4 boulders, Drips is 10
-- runnels, Roots is 6 buttresses and a 43-stud mud apron. Their bounding box
-- is therefore the box the SCATTER fills, and a stand-in built solid at that
-- size is a wall - a solid `Roots` would be a 36-stud cube of mud swallowing
-- the whole lower half of the animal. The Core's box sits inside the Stones
-- box, so an opaque stand-in would bury the punish target - the one thing on
-- this animal a player has to be able to find. Ghosted, the authored bulk
-- still reads and the ember still burns through it.
--
-- (`Eyes` used to be on this list and is gone with the object: the eye row is
-- ten instances of `Eye` now - two of them 1.70 authored and the rest under a
-- stud - each one its own solid.)
--
-- Stand-ins only. An imported piece is the real scatter and stays solid.
local SCATTER_STANDIN = { Roots = true, Stones = true, Drips = true }
local SCATTER_TRANSPARENCY = 0.45

-- WHICH PIECES CAST. This rig is now 9 cluster pieces + 10 eyes + 18 limb
-- parts = 37 shadow casters for one creature if every one of them is left on,
-- and PyreliskBodyController's answer (only the torso and the head) is the
-- right shape of answer here too: the mass, the roots and the skull ARE the
-- ground-plane silhouette, and every other body piece is inside their
-- footprint. The exception is the FIST, which swings up to 39 studs outside
-- it and plants on the bank - its shadow on the peat is the tell that the
-- slam is coming down, and on a boss that cannot walk it is the only thing
-- that moves across the ground at all. Five casters, thirty-two off.
local CASTS_SHADOW = { Mass = true, Roots = true, Head = true, Hand = true }

-- ------------------------------------------------------------------ the limb
--
-- The vertebra's own TUBE - the GN_ARM loft, x -1.9..1.9 - is 3.8 studs for
-- the plain vertebra AND for the knot. The knot's wider box is its swell
-- bulging sideways, not a longer bone, so the length that has to cover a
-- pitch is measured against this and not against `Size.X`.
local ARM_TUBE = 3.8
-- The overlap the builder places at: every piece covers 1/0.86 of its own
-- step. The pack is cut for it - a 3.8-stud vertebra on the authored 3.20
-- pitch is 16% of spare on top of that - and it is what stops a joint
-- showing. It matters more now than it did: EIGHT vertebrae draw a joint
-- every 3.2 authored studs instead of every 5.2, so a visible step would be
-- visible eight times per arm.
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
-- and pulls the mesh 1.2 authored studs back up-limb before placing it
-- (1.6 on the old 5.2-stud bone; the seat scales with the vertebra).
local HAND_SEAT = 1.2
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
	elseif name == "Eye" then
		-- Dark and glossy is the SHUT state, and it is the default: `drawEyes`
		-- decides per instance, per frame, which of the ten are lit. An
		-- eye set flush and matte is an eye you never see.
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
	-- CLIENT-ONLY, and nil means 1. The fight never writes this - only
	-- GnashrootIntro does - so an `or 1` here is what keeps the row fully open
	-- for every frame of every fight, rather than a colossus that goes blind
	-- the moment the cutscene is not running.
	target.eyes = model:GetAttribute("Eyes") or 1
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

-- THE EYE ROW, one instance of `Gnashroot_Eye` per authored seat.
--
-- INSTANCED, NOT BAKED, and that is the whole reason the pack changed shape:
-- `Gnashroot_Eyes` was a single mesh carrying 26 lumps, and a single mesh has
-- one Material and one Transparency - so "the eyes open one at a time", which
-- is a beat GnashrootIntro is built on, could not be expressed on it at all.
-- Fourteen sub-stud parts is the price.
local function newEyes(folder: Instance)
	local eyes = {}
	for index = 1, EYE_COUNT do
		local seat, radius = GnashrootPath.eyeSeat(index)
		eyes[index] = {
			part = makePiece("Eye", folder),
			-- ALREADY SCALED, like every other cluster offset here, so the draw
			-- is one CFrame multiply per eye per frame.
			offset = CFrame.new(seat * SCALE),
			radius = radius,
		}
	end
	return eyes
end

-- One frame of the eye row. `Eyes` is a FRACTION of the row (see
-- GnashrootPath.eyeLit), so this is a crossfade per instance and not a
-- ten-way branch.
local function drawEyes(body, frame: CFrame, state, pulse: number)
	for index, eye in body.eyes do
		local lit = GnashrootPath.eyeLit(state, index)
		applyPiece(eye.part, frame * eye.offset, eye.radius * SCALE, eye.radius * SCALE)
		if lit <= 0 then
			-- Shut: the authored dark, plastic, no glow. Asserted every frame
			-- rather than latched on the transition, because a body adopted
			-- mid-fight has no transition to have seen.
			eye.part.Color = EYE_SHUT
			eye.part.Material = Enum.Material.SmoothPlastic
		else
			-- Open: Neon, and breathing on the CORE's own pulse so the whole
			-- animal blinks as one thing rather than as fifteen.
			eye.part.Color = EYE_SHUT:Lerp(EYE_LIT, lit * (0.72 + 0.28 * pulse))
			eye.part.Material = Enum.Material.Neon
		end
	end
end

-- WHAT THE PACK BROUGHT THAT NOTHING PLACES.
--
-- The user's fifth complaint - "make sure all parts are aligned during its
-- animations so we don't have static parts that don't move or move weirdly" -
-- has exactly one mechanism behind it, and this is the check for it: an object
-- in the imported pack that no table in this file has a placement for is never
-- given a CFrame, so it sits at the pack's own origin, inside the animal,
-- forever. It does not error and it does not warn; it looks like a modelling
-- mistake. The 2026-09-12 redesign deletes `Gnashroot_Legs` and
-- `Gnashroot_Eyes`, and the half-gator pack's `_Body`/`_Fins`/`_Marks` were
-- already dead - five objects that will still be in a Studio pack that was
-- updated rather than replaced.
--
-- ONCE, AT ADOPT, and it names every offender rather than counting them,
-- because the fix is to delete them by name in Studio (docs/import-checklist.md
-- row 7f).
local function auditPack()
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local pack = assets and assets:FindFirstChild(PACK_NAME)
	if not pack then
		return
	end
	local orphans = {}
	for _, child in pack:GetDescendants() do
		if child:IsA("BasePart") and child.Name:sub(1, #PREFIX) == PREFIX then
			local piece = child.Name:sub(#PREFIX + 1)
			if not PLACED_PIECES[piece] then
				table.insert(orphans, child.Name)
			end
		end
	end
	if #orphans > 0 then
		table.sort(orphans)
		warn(
			"[GnashrootBody] "
				.. PACK_NAME
				.. " holds "
				.. #orphans
				.. " object(s) this rig never places, so they will stand static inside the animal: "
				.. table.concat(orphans, ", ")
				.. ". Delete them in Studio - see docs/import-checklist.md row 7f."
		)
	end
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
		-- THE DRAWN GAPE, on its own eased channel. `GnashrootPath.jawAngle`
		-- is a pure function of the state, so the mouth used to inherit
		-- whatever `blend` and `strike` were doing and nothing else - and the
		-- goal can still step in one frame whenever the attack NAME changes
		-- under it, because gape's shape is per-attack. Easing here filters
		-- the ANGLE rather than its inputs, so the jaw swings instead of
		-- jumping and the bite still lands on the server's frame. It matters
		-- more since the second pass than it did before it: the jaw is 14
		-- studs long and hinged at the back of a skull that is now the top of
		-- the silhouette, so a one-frame step in the gape is the single most
		-- visible thing this rig can do.
		jawAngle = 0,
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
	-- ...and the eye row, which is placed from GnashrootPath's seats rather
	-- than from the pack's own layout: the seats ARE the authored positions
	-- (boss_gen prints this table), and there is only one `Gnashroot_Eye` in
	-- the pack to measure an offset from.
	body.eyes = newEyes(folder)

	-- Once per body, and cheap: a pack with nothing stale in it says nothing.
	auditPack()

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
	-- add and drop vertebrae as the arm reaches, which on an eight-piece limb
	-- is a joint appearing mid-swing. Instead each vertebra keeps its share of
	-- the curve and the pieces stretch to cover it, so their overlap survives
	-- a reach and the knuckle stays the same knuckle.
	local pitch = chain.length / SEGMENTS
	local stretch = math.clamp(pitch / REST_PITCH, STRETCH_MIN, STRETCH_MAX)
	-- The TUBE this pose's pitch needs, with the builder's overlap on it and
	-- the taper normalised on the wrist. At rest that is 5.59 studs of bone at
	-- the shoulder falling to 5.19 at the wrist over a 4.80 world pitch, so
	-- even the tightest joint carries 0.39 studs of overlap - and there are
	-- eight of them, which is why the limb reads as a tube and not as beads.
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
	-- THE PIVOT, EVERY FRAME, AND IT STAYS THAT WAY EVEN THOUGH THE FIGHT NO
	-- LONGER MOVES. The row is `speed = 0` / `standoff = 200` now (the user:
	-- "he must be COMPLETELY STATIONARY"), so in the fight this is the anchor
	-- frame after frame - but the authority model's pivot IS its hit position,
	-- and following it is what keeps the mass you dodge and the mass you see
	-- the same object whatever moves it. GnashrootIntro walks a STAND-IN
	-- model's pivot in across the mere for the emergence, and that beat exists
	-- because this line reads the pivot rather than the once-published
	-- PoseCenter. Do not replace it with `state.center = anchor`.
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
	-- The eye row follows its own channel. NOT eased: the intro tweens `Eyes`
	-- itself, on its own curve, and easing here would be a second filter over
	-- a track that is already choreographed - the eyes would lag their own
	-- beat by a fixed amount nobody could tune out.
	state.eyes = target.eyes
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

	-- The eye row, on the core's own pulse, off the body frame like every
	-- other cluster piece - so a lean or a rise takes all ten with it.
	drawEyes(body, frame, state, pulse)

	-- Jaw group: it SWINGS about its hinge rather than sliding, so rotate
	-- around the pivot point and not the pieces' own origin.
	local hinge = GnashrootPath.JAW_HINGE * SCALE
	body.jawAngle = approach(body.jawAngle, GnashrootPath.jawAngle(state), EASE.jaw, dt)
	local jawFrame = frame * CFrame.new(hinge) * CFrame.Angles(0, 0, -body.jawAngle) * CFrame.new(-hinge)
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
