--!nonstrict
-- KrakenBodyController.luau
-- Draws the Kraken: one huge domed head filling the middle of the whirlpool,
-- and eight arms reaching out of its crown to the rocks.
--
-- Same split as BrinejawBodyController. The server keeps authority only - a
-- hidden model for hits and the HUD, plus the replicated numbers (Rise and
-- FaceAngle) - and everything you can see is built here from
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
-- `hump` IS MEASURED AGAINST THE ARM'S OWN THICKNESS, which is the rule that
-- replaced the span-ratio one that used to sit here. The old note set hump to
-- 0.63 of the radial span "because the authored render arches 0.63 of its
-- span", and that ratio does not transfer: the render's arm crosses 64 studs
-- of radial room, the in-game arm crosses 20.5, so the span shrank by better
-- than 3x - and the SEGMENTS DID NOT. They are the same 8.6-stud capsules at
-- the same SCALE. An arch that is a gentle curve across 64 studs is a fold
-- across 20.5, drawn with a limb of exactly the same girth.
--
-- The real bound is local: at every u the centreline's radius of curvature
-- must beat (8.6 / 2) * SCALE * (1 - TIP_GIRTH * u), the drawn half-
-- thickness there, with 10% margin.
--
-- THE CEILING SCALES AS THE SQUARE OF THE RADIAL SPAN, which is why
-- `parts.ring` is 50 and not 46. Measured, with the whole envelope tuned for
-- it: span 20.5 (ring 46) admits hump 2.85, span 24.5 (ring 50) admits 3.93,
-- span 28.5 (ring 54) admits 5.21. Admitting hump 8 would take a ring near
-- 60 - past the 38-52 platform band, out where the tentacles are no longer
-- in the fight. So the ring bought a 38% gain and the gap is still wide.
--
-- (An earlier note here claimed a ceiling of 6.35. That number came from
-- measuring the arch ALONE with the skirt deleted AND the shoulder crease
-- excluded from the sweep - a bound on one term, not on any arm that can
-- actually be drawn. Quoted as if it were the real ceiling it says the ring
-- change should have closed this, and it does not. The figures above are
-- from the shipped curve, corner and skirt included.)
--
-- SO 9.0 IS A COMPROMISE AND IS DOCUMENTED AS ONE. 13 was 0.016 of the bound
-- and 9 is 0.406 - twenty-five times better, worst radius 0.097 -> 1.699
-- studs, peak pitch 81.6 -> 65.3 degrees - but the arm is 7.6 studs thick
-- where it bends hardest and it wants 4.2 studs of radius there. Going lower
-- is what the curvature asks for; 8 is the floor the silhouette asks for,
-- and below it the Kraken stops arching over the rocks and starts reaching
-- along the water. The two do not meet. What would actually close it is a
-- thinner mid-arm - TIP_GIRTH shaping, or slimmer authored segments in the
-- pack - and until that lands this arm self-intersects at its crest by
-- design, visibly least at hump 9.
local BOUND = { hump = 9.0, wave = 0.22, breathe = 1.8 }
-- RESTING is the unclaimed-arm drape, and its look is negotiable where
-- BOUND's is not - nothing is staged against it, so it was tuned for the
-- curvature bound until it PASSED, which it does: 1.002 of the bound, worst
-- radius 4.25 studs against 3.85 of girth, peak pitch 84.6 -> 52.4 degrees.
-- The old 36 / -16 asked the arm to fall 13 studs across only 10.5 studs of
-- radial run, a hairpin no envelope can help.
--
-- 3.50 IS THE MOST ARCH THIS POSE CAN HOLD, not a look that was chosen: at
-- reach 48 and tipY -14 the bound admits 3.52, so this is the ceiling with
-- the rounding taken off. It is a visibly flatter arm than a bound one, and
-- that is correct - a dead arm draping back into the water should not be
-- arching like one that is holding a tentacle. Raise `reach` (48 is the
-- practical limit before an idle arm rests past the platforms) before
-- raising `hump`, since span buys curvature quadratically and hump spends it
-- linearly.
local RESTING = { hump = 3.50, wave = 0.12, breathe = 1.2, reach = 48.0, tipY = -14.0 }
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
	-- The rebuilt beak: two parted mandibles, bbox x 11.6..25.3, y +/-4.7,
	-- z -14.5..1.5, so 14 long x 9 across x 16 deep. It used to be 9 x 7 x 9,
	-- which was the old single hooked beak and understates the new piece by
	-- most of its drop.
	Beak = Vector3.new(14, 9, 16),
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

-- WHERE EACH STAND-IN HEAD PIECE SITS, in the head's own frame at scale 1
-- (+X is the facing, +Y is up, +Z is across), applied ONLY to parts that came
-- out of makePiece's fallback branch.
--
-- The six head pieces all ride ONE `headFrame`, which is correct for the
-- imported pack - the authored mesh carries its own geometry, every piece is
-- modelled in place around the crown, and offsetting them would take the
-- octopus apart. It is wrong for the stand-ins, which are six centred bricks:
-- with no offsets they all sat on the same point, so the fallback head was a
-- single featureless ball with the eyes, the pupil and the beak buried
-- somewhere inside it - and that ball was centred on the CROWN, the authored
-- origin, which is the BOTTOM of the animal. The whole 46 studs of mantle
-- hung above a mass that read as sitting 32 studs too low.
--
-- Every number is measured off assets/boss_gen.py at scale 1, the same way
-- FALLBACK_SIZE's are, so the stand-in is the authored head's silhouette in
-- six boxes rather than a guess at one:
--   Head   the dome, lifted to mid-mantle: KR head runs z 0 -> 46.2, so its
--          centre is HEAD_HEIGHT/2 and the ball then stands on the crown
--          instead of straddling it.
--   Crown  the origin, untouched - it IS z = 0, and everything else is
--          measured from it.
--   Crust  ONE flank, off the face, matching build_kr_crust's own clustering
--          (bearing 1.5..3.5 rad, z 1.5..13.5; centre of that is bearing
--          2.5 at r 18.2, z 7.5). Sprinkled evenly it read as rubble.
--   Eyes   the authored eye seat: KR_EYE_BEARING 27 deg off +X at
--          KR_EYE_SEAT 18.4, KR_EYE_Z 15.0 - so 16.4 forward and 15 up. Left
--          on the centreline, because FALLBACK_SIZE.Eyes is already a
--          32-stud span: one band reaching BOTH seats, since one name gets
--          one part and two balls would need two.
--   Pupil  the same seat plus build_kr_pupil's 3.4, so the slit stands proud
--          of the lens rather than z-fighting inside it.
--   Beak   under the crown's +X rim, which is where the rebuilt piece now
--          hangs (bbox x 11.6..25.3, dropping to z -14.5). There is no hinge
--          to measure from any more: the beak is fixed and decorative, since
--          the head is ranged-only and never bites, and boss_gen.py's
--          KR_BEAK_HINGE went with the two mandibles it used to swing.
-- CFrames rather than Vector3s so a piece can be turned as well as moved;
-- the position is scaled by SCALE at use, the rotation is not.
local FALLBACK_AT = {
	Head = CFrame.new(0, KrakenPath.HEAD_HEIGHT / 2, 0),
	Crown = CFrame.new(0, 0, 0),
	Crust = CFrame.new(math.cos(2.5) * 18.2, 7.5, math.sin(2.5) * 18.2),
	Eyes = CFrame.new(math.cos(math.rad(27)) * 18.4, 15.0, 0),
	Pupil = CFrame.new(math.cos(math.rad(27)) * (18.4 + 3.4), 15.0, 0),
	Beak = CFrame.new(16.0, -6.0, 0),
}
-- Set by makePiece on the fallback branch only, and read when the head is
-- placed. It has to be an attribute on the PART rather than a flag beside the
-- table, because the pack can land piece by piece: `packPiece` is asked per
-- name, so a half-imported KrakenPack gives real geometry for some of the six
-- and stand-ins for the others, and only the stand-ins may be offset.
local FALLBACK_TAG = "KrakenStandIn"

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
		-- Tagged so the head can lay these six out (FALLBACK_AT). An imported
		-- piece must NEVER be offset - it is modelled in place - so the flag
		-- goes on here, in the branch that actually built a stand-in, rather
		-- than being inferred later from anything about the part.
		part:SetAttribute(FALLBACK_TAG, true)
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

-- Which socket a tentacle belongs to, WHEN ALL WE HAVE IS ITS POSITION.
--
-- This is the fallback, not the answer - see socketOf. It rounds the
-- tentacle's bearing onto an even ring, which was right while the server
-- planted tentacle `i` at exactly `(i / count) * 2pi` and is wrong now that
-- the ring is a 206-degree arc: on the arc the eight bearings are 26 degrees
-- apart over one half of the circle, so rounding them onto 45-degree spokes
-- collapses several tentacles onto the same spoke and leaves others empty.
-- Kept only so a model with no SocketIndex attribute lands on SOME socket
-- and gets an arm at all.
local function socketByBearing(centre: Vector3, at: Vector3, count: number): number
	local bearing = math.atan2(at.Z - centre.Z, at.X - centre.X)
	local index = math.floor(bearing / (math.pi * 2) * count + 0.5)
	return ((index - 1) % count) + 1
end

-- Which socket a tentacle belongs to. AUTHORITATIVE: the server stamps
-- `SocketIndex` (1..count) on every part it plants, in
-- CreatureService.spawnBossParts, at the moment it decides where the thing
-- stands - so this is the server's own answer read back, not a reconstruction
-- of it. Nothing about the ring's shape can break it: move the tentacles onto
-- an arc, onto authored sockets, onto nothing recognisable at all, and arm
-- `i` still holds tentacle `i`.
local function socketOf(model: Model, centre: Vector3, at: Vector3, count: number): number
	local published = model:GetAttribute("SocketIndex")
	if type(published) == "number" and published >= 1 and published <= count then
		return published
	end
	return socketByBearing(centre, at, count)
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
				local socket = socketOf(child, centre, at, count)
				-- Two tentacles on one socket should not happen - the server
				-- stamps each index exactly once - but a ring spawned with no
				-- attributes at all falls through to the bearing rounding,
				-- which collides freely on an arc. The second one takes the
				-- next free socket rather than stealing the first one's arm.
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

		-- A SUCKER CAN FAIL TO BE PLACED AT AN INDEX THAT IS STILL IN USE, and
		-- that is why it needs parking here rather than in the loop below.
		-- The cleanup after this `each` only parks indices past `used`, which
		-- is right for anything drawn once per segment - but a sucker is
		-- ALSO gated on `u <= SUCKER_UNTIL`, and the last segment's `u` walks
		-- back and forth across that cutoff every frame as the ambient
		-- breathe changes the curve's arc length. So the last sucker would
		-- fall in a gap between the two rules: not placed this frame, and not
		-- parked either, because its index is <= used. It stayed exactly
		-- where the previous frame left it - a glowing Neon disc hanging in
		-- open water beside a tapering arm tip, on all eight arms, on better
		-- than a third of frames.
		--
		-- THE SEGMENTS DO NOT NEED THIS, and only by luck: their sole
		-- condition IS being visited, so `used` describes them exactly. The
		-- ArmTip covers the far end because it is a single part re-placed
		-- every frame, never an indexed set. Any new indexed set with a
		-- condition of its own belongs here too, not in the loop below.
		local placed = index % SUCKER_EVERY == 0 and u <= SUCKER_UNTIL
		if not placed then
			local stale = entry.suckers[index]
			if stale then
				park(stale)
			end
		end
		if placed then
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
	local centre = model:GetAttribute("PoseCenter")
	if centre then
		state.center = centre
	end

	local headFrame = KrakenPath.headCFrame(state)
	for _, name in HEAD_PIECES do
		local piece = body.head[name]
		local at = headFrame
		local offset = FALLBACK_AT[name]
		if offset and piece:GetAttribute(FALLBACK_TAG) then
			-- Position scaled with the head, rotation left alone: the offsets
			-- are authored studs, so they have to grow with SCALE the same way
			-- the pieces themselves do or the stand-in head comes apart the
			-- moment SCALE moves.
			at = headFrame * CFrame.new(offset.Position * SCALE) * offset.Rotation
		end
		applyPiece(piece, at, SCALE, SCALE)
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
