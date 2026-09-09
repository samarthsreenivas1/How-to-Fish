--!nonstrict
-- ToolHoldController.luau
-- Makes a character in third person look like it is HOLDING the thing in its
-- hand rather than having it glued to a swinging arm.
--
-- The defect this fixes: RodService/WeaponService weld the equipped model to
-- the RIGHT HAND part (server-side, so it replicates - see the header of
-- either service). That weld is rigid, so whatever the hand does, the tool
-- does. With the default Animate script running, the hand swings through the
-- whole walk cycle, and the gun/rod swings and rotates with it.
--
-- ROUND ONE fixed the ROTATION half of that and shipped: the arm was posed
-- with fixed joint angles and the wrist was SOLVED so the hand's rotation
-- relative to the torso stayed at the rest pose the hold offsets were
-- authored against. The player played it and still said it did not feel held,
-- which was correct, and the reason is that fixed joint angles say nothing
-- about WHERE the hand ends up:
--
--   * the round-one gun pose (shoulder back 22 degrees, elbow bent 50) leaves
--     the hand hanging at hip height on a nearly straight arm, so the gun rode
--     the hip pointing forward - a one-handed hip carry, not a hold, and low
--     enough to graze the leg at walk amplitude;
--   * the LEFT arm was posed with fixed angles too, so where it ended up had
--     nothing to do with where the gun was. It waved in the air a few studs
--     off the fore-end. Nothing reads as "not holding it" faster than a
--     support hand that is not touching the weapon.
--
-- Neither is fixable by nudging angles, because the angles cannot know the
-- rig's limb lengths or where the other hand is. So ROUND TWO inverts the
-- problem: this file now states WHERE THE HANDS GO in torso space and solves
-- the joints for it.
--
-- WHAT IS SOLVED, PER ARM
--
--   1. a two-bone IK puts the HAND'S ORIGIN on a target point. The hand's
--      origin is exactly where the grip is welded (WeaponService puts the
--      grip at `hand.CFrame * holdOffset`, so grip origin == hand origin), so
--      targeting the hand IS targeting the grip;
--   2. the WRIST is then solved for rotation, exactly as round one did, so
--      the hand's rotation relative to the torso comes out at the pose's
--      `handRot` no matter what the two joints above it had to do to reach.
--      `handRot` therefore aims the tool directly: the hold offsets map the
--      weapon's authored +Y onto the hand's -Z, so a gun's BORE is
--      `handRot * -Z` and that is what the support-hand target is measured
--      along.
--
-- With both hands solved, the support hand can be placed a fore-end's length
-- down the bore from the grip - so it is ON the gun, by construction, for any
-- rig scale and any weapon length.
--
-- WHY IT IS SHAPED THIS WAY
--
-- We cannot upload animation assets from here, so this is procedural Motor6D
-- posing: write `Motor6D.Transform` on the arm joints on a render step bound
-- AFTER `RenderPriority.Character`, which is when the Animator has just
-- written the walk pose into those same Transforms. Writing after it wins for
-- that frame; the Animator writes fresh values again next frame, so nothing
-- is permanently clobbered and letting go is just "stop writing".
--
-- Only the arm chain is written. The Animator still drives the legs, the
-- root, the waist and the neck, so walking, running, jumping and swimming all
-- look exactly as they did. And because every target is stated in UPPER TORSO
-- space, the walk's own chest bob and lean carry the weapon with them for
-- free - the gun breathes with the body instead of being pinned in the world.
--
-- NO RIG CONSTANTS. Every length and axis the solve needs is read off the
-- joints' real C0/C1 (bone lengths, the shoulder pivot, the elbow's hinge
-- axis), and the targets are expressed as fractions of the arm's own reach.
-- A scaled avatar, or a rig whose attachments are not the stock ones, still
-- comes out with its hands in the right place relative to its own chest.
--
-- R6 has no elbow and no wrist - one joint for the whole arm - so there is
-- nothing to solve a position with. It keeps round one's behaviour: that one
-- joint is solved for ROTATION, which freezes the arm at the hanging rest
-- pose with the tool level. Not a carry, but the swing - the original defect
-- - is gone.
--
-- REPLICATION
--
-- `Motor6D.Transform` written on a client does NOT replicate; there is no
-- remote here and none is needed. Every client runs this controller over
-- EVERY player's character, not just its own, and the input it keys off is
-- already replicated state (the welded EquippedRod/EquippedWeapon model and
-- its WeaponId attribute). So the pose is recomputed identically on each
-- machine and everyone sees everyone holding their tool properly. The gap:
-- anything that is not a player running this code - a server-side check, a
-- future NPC rig - sees the un-posed swing.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Weapons = require(Shared.Data.Weapons)

local CameraController = require(script.Parent.CameraController)

local ToolHoldController = {}

local localPlayer = Players.LocalPlayer

-- The names RodService/WeaponService give the welded models. Hardcoded for
-- the same reason RodViewmodelController and FishingController hardcode the
-- rod's: the services live in ServerScriptService and cannot be required
-- from here. Keep the three in step.
local ROD_NAME = "EquippedRod"
local WEAPON_NAME = "EquippedWeapon"

-- How fast the hold fades in when a tool appears and out when it goes away,
-- as an exponential rate per second. Fading rather than snapping matters on
-- the swap: at half weight the arm is halfway between the walk swing and the
-- carry, so equipping reads as raising the tool instead of teleporting it.
local BLEND_IN = 9
local BLEND_OUT = 12

-- Below this the blend is over; stop writing entirely and hand the arm back
-- to the Animator cleanly rather than leaving it a hair off.
local WEIGHT_EPSILON = 0.004

local function angles(x: number, y: number, z: number): CFrame
	return CFrame.Angles(math.rad(x), math.rad(y), math.rad(z))
end

-- ============================================================ the poses
--
-- Upper-torso space, R15 convention: +X is the character's RIGHT, +Y up, -Z
-- the way it faces. `at` is the hand target as a fraction of that arm's own
-- reach (shoulder->elbow + elbow->wrist), measured FROM THE SHOULDER PIVOT,
-- so it scales with the avatar. `rot` is the hand's rotation relative to the
-- torso, which is what aims the tool.
--
-- These numbers, and only these numbers, are the tuning surface.
local POSES = {
	-- A two-hand rifle carry at low ready. The trigger hand sits just in
	-- front of the right pec at mid-chest height - high enough that the
	-- weapon cannot reach the legs at any walk amplitude, which is what
	-- killed the round-one hip carry - and the weapon lies ACROSS the body:
	-- yawed 14 degrees to the left and muzzled 9 degrees down, the angle that
	-- both reads as "ready, not aiming" and brings the fore-end within the
	-- support arm's reach.
	gun = {
		rot = angles(0, 14, 0) * angles(-9, 0, 0),
		at = Vector3.new(-0.24, -0.26, -0.32),
		-- The support hand rides the bore this far past the grip - see
		-- `foreReach` below, which takes it from the weapon's own length -
		-- and a touch under it, where a fore-end is.
		support = true,
		supportDrop = 0.06,
	},

	-- A rod is carried one-handed, the way an angler actually walks with one:
	-- the butt forward of the hip, the blank pointing forward and up (the
	-- authored HOLD_OFFSET already does the pointing). No support hand, so
	-- the off arm keeps the ordinary walk swing.
	rod = {
		rot = angles(0, 0, 0),
		at = Vector3.new(0.06, -0.40, -0.30),
	},

	-- Melee is one-handed too: blade-up carry out at the side, clear of the
	-- thigh, and no support hand for the same reason - posing it would only
	-- make the character look like it is carrying an invisible second weapon.
	melee = {
		rot = angles(0, 0, 0),
		at = Vector3.new(0.14, -0.52, -0.22),
	},
}

-- Where the elbow is pushed while the IK swings the arm: down, a little back
-- and a little out from the ribs. Any direction off the shoulder->hand line
-- would reach the target; this is the one that looks like an arm.
local RIGHT_POLE = Vector3.new(0.45, -1, 0.35).Unit
local LEFT_POLE = Vector3.new(-0.45, -1, 0.35).Unit

-- How far down the bore the support hand sits, from the weapon row's own
-- geometry: `length - grip` is grip-to-muzzle (the same span
-- WeaponViewmodelController calls gripLength), and a fore-end grip is around
-- half of it. Clamped so a stubby pistol does not put both hands in the same
-- place and a boat-anchor rifle does not tear the arm off.
local function foreReach(weaponData): number
	local m = weaponData and weaponData.model
	local span = if m and m.length and m.grip then m.length - m.grip else 1.4
	return math.clamp(span * 0.5, 0.45, 1.35)
end

-- ============================================================ the chains

-- Each entry is { part name, Motor6D name }, ordered from the torso outward.
local R15_RIGHT = {
	{ "RightUpperArm", "RightShoulder" },
	{ "RightLowerArm", "RightElbow" },
	{ "RightHand", "RightWrist" },
}
local R15_LEFT = {
	{ "LeftUpperArm", "LeftShoulder" },
	{ "LeftLowerArm", "LeftElbow" },
	{ "LeftHand", "LeftWrist" },
}
-- R6 has no elbow and no wrist: the shoulder is the whole arm.
local R6_RIGHT = { { "Torso", "Right Shoulder" } }
local R6_LEFT = { { "Torso", "Left Shoulder" } }

local function findChain(character: Model, spec): { Motor6D }?
	local joints = {}
	for _, entry in spec do
		local part = character:FindFirstChild(entry[1])
		local joint = part and part:FindFirstChild(entry[2])
		if not joint or not joint:IsA("Motor6D") then
			return nil
		end
		table.insert(joints, joint)
	end
	return joints
end

local function chainAlive(joints: { Motor6D }): boolean
	for _, joint in joints do
		if joint.Parent == nil then
			return false
		end
	end
	return true
end

-- ============================================================ the solve
--
-- Motor6D geometry, once, because everything below is an application of it:
--
--     Part1frame = Part0frame * C0 * Transform * C1:Inverse()
--
-- With a rotation-only Transform the point `Part0frame * C0.Position` does
-- not move, so that IS the joint's pivot, and the bone's length - the pivot
-- of the joint below, measured in the same part's space - is fixed no matter
-- what we write. That is what lets every length here be read rather than
-- assumed.

-- A rotation whose columns are the given (already orthogonal, unit) axes.
local function basis(f1: Vector3, f2: Vector3): CFrame?
	local along = f1.Magnitude
	if along < 1e-5 then
		return nil
	end
	local x = f1 / along
	local perp = f2 - x * f2:Dot(x)
	if perp.Magnitude < 1e-5 then
		return nil
	end
	local y = perp.Unit
	return CFrame.fromMatrix(Vector3.zero, x, y, x:Cross(y))
end

-- Rotation-only part of a CFrame applied to a vector.
local function rot(cf: CFrame, v: Vector3): Vector3
	return cf.Rotation * v
end

-- Solves a three-joint arm so the HAND'S ORIGIN lands on `targetPos` and the
-- hand's rotation comes out at `targetRot`, both in the chain root's space
-- (UpperTorso for either R15 arm). `pole` is the direction the elbow is
-- pushed toward. Returns the three Transforms, or nil if the rig is degenerate
-- - the caller then leaves that arm to the Animator rather than writing
-- garbage into it.
local function solveArm(joints: { Motor6D }, targetPos: Vector3, targetRot: CFrame, pole: Vector3)
	local shoulder, elbow, wrist = joints[1], joints[2], joints[3]

	-- Bones, from the joints themselves.
	local upperVec = elbow.C0.Position - shoulder.C1.Position -- in upper-arm space
	local lowerVec = wrist.C0.Position - elbow.C1.Position -- in lower-arm space
	local l1, l2 = upperVec.Magnitude, lowerVec.Magnitude
	if l1 < 1e-3 or l2 < 1e-3 then
		return nil
	end

	-- The shoulder pivot, and the wrist pivot the hand target implies. The
	-- hand's origin is `wristPivot - handRotation * wrist.C1.Position`, so
	-- read backwards: the pivot the hand must hang off to put its origin on
	-- the target.
	local s = shoulder.C0.Position
	local w = targetPos + rot(targetRot, wrist.C1.Position)

	local reach = w - s
	local span = reach.Magnitude
	if span < 1e-4 then
		return nil
	end
	local forward = reach / span
	-- Never fully straight (the IK degenerates and the elbow pops) and never
	-- folded past what the two bones can do.
	span = math.clamp(span, math.abs(l1 - l2) + 1e-3, (l1 + l2) * 0.995)
	w = s + forward * span

	-- The arm's plane: `forward` and the pole, with the elbow swinging toward
	-- the pole side.
	local sideRaw = pole - forward * pole:Dot(forward)
	if sideRaw.Magnitude < 1e-4 then
		-- Reaching straight along the pole. Any perpendicular will do.
		sideRaw = forward:Cross(Vector3.yAxis)
		if sideRaw.Magnitude < 1e-4 then
			sideRaw = forward:Cross(Vector3.xAxis)
		end
	end
	local side = sideRaw.Unit
	local hinge = forward:Cross(side)

	-- Law of cosines: how far off the shoulder->wrist line the upper arm sits.
	local cosA = math.clamp((l1 * l1 + span * span - l2 * l2) / (2 * l1 * span), -1, 1)
	local a = math.acos(cosA)
	local upperDir = forward * math.cos(a) + side * math.sin(a)
	local elbowAt = s + upperDir * l1

	-- The upper arm's rotation is pinned by two of its own axes: the bone
	-- must lie along `upperDir`, and the elbow's hinge must lie along
	-- `hinge`, which is what keeps the forearm in the plane we just built.
	local boneAxis = rot(shoulder.C1, upperVec.Unit)
	local hingeAxis = rot(elbow.C0, Vector3.xAxis)
	local from = basis(boneAxis, hingeAxis)
	local to = basis(upperDir, hinge)
	if not from or not to then
		return nil
	end
	local upperCF = (to :: CFrame) * (from :: CFrame):Inverse()
	local t1 = shoulder.C0.Rotation:Inverse() * upperCF * shoulder.C1.Rotation

	-- The elbow is a hinge, so its angle is not guessed either: measure the
	-- signed turn about the real hinge axis from where the forearm would
	-- point unbent to where it has to point. Sign falls out of the atan2, so
	-- no rig-handedness assumption is made anywhere.
	local axis = rot(upperCF, hingeAxis)
	local rest = upperCF * elbow.C0.Rotation * elbow.C1.Rotation:Inverse()
	local unbent = rot(rest, lowerVec.Unit)
	local wanted = (w - elbowAt)
	if wanted.Magnitude < 1e-4 then
		return nil
	end
	wanted = wanted.Unit
	local theta = math.atan2(unbent:Cross(wanted):Dot(axis), unbent:Dot(wanted))
	local t2 = CFrame.Angles(theta, 0, 0)

	-- ...and the wrist takes whatever is left, so the tool comes out aimed.
	local lowerCF = upperCF * elbow.C0.Rotation * t2 * elbow.C1.Rotation:Inverse()
	local t3 = (lowerCF * wrist.C0.Rotation):Inverse() * targetRot * wrist.C1.Rotation

	return t1, t2, t3
end

-- The R6 fallback, and the R15 path's own last step in spirit: with one joint
-- there is no position to solve, so the joint is set to whatever holds the
-- hand's rotation at `targetRot` and the arm hangs at rest with the tool
-- level.
local function solveRotationOnly(joint: Motor6D, targetRot: CFrame): CFrame
	return joint.C0.Rotation:Inverse() * targetRot * joint.C1.Rotation
end

-- Blends the solved transforms in over `weight`, lerping from whatever the
-- Animator just wrote, so a partial weight is a real blend between the walk
-- swing and the hold rather than a jump.
local function writeChain(joints: { Motor6D }, t1: CFrame, t2: CFrame?, t3: CFrame?, weight: number)
	joints[1].Transform = joints[1].Transform:Lerp(t1, weight)
	if t2 and joints[2] then
		joints[2].Transform = joints[2].Transform:Lerp(t2, weight)
	end
	if t3 and joints[3] then
		joints[3].Transform = joints[3].Transform:Lerp(t3, weight)
	end
end

-- ============================================================ state

-- One entry per player whose arms we are currently blending. Cheap: the
-- joints are cached, so a frame is a handful of CFrame multiplies per player.
local states: { [Player]: any } = {}

-- Which pose a character's hands call for, plus the weapon row behind it (the
-- support hand needs the weapon's length). Keyed off the welded model the
-- SERVER put there, so it is the same answer on every client - which is the
-- whole replication story.
local function heldClass(character: Model): (string?, any)
	if character:FindFirstChild(ROD_NAME) then
		return "rod", nil
	end
	local weapon = character:FindFirstChild(WEAPON_NAME)
	if not weapon then
		-- Bare fists weld nothing, so there is no model here and no hold -
		-- the arms swing normally, which is right for fists.
		return nil, nil
	end
	local weaponId = weapon:GetAttribute("WeaponId")
	local row = weaponId and Weapons.items[weaponId]
	if row and row.ranged then
		return "gun", row
	end
	return "melee", row
end

local function stateFor(player: Player)
	local character = player.Character
	if not character or not character.Parent then
		states[player] = nil
		return nil
	end

	local state = states[player]
	if state and state.character == character and chainAlive(state.right) then
		return state
	end

	-- R15 first, R6 as the fallback - the same order RodService and
	-- WeaponService use when they look for a hand to weld to.
	local right = findChain(character, R15_RIGHT)
	local left = findChain(character, R15_LEFT)
	local jointed = right ~= nil
	if not right then
		right = findChain(character, R6_RIGHT)
		left = findChain(character, R6_LEFT)
	end
	if not right then
		-- Rig still streaming in. Cache nothing; try again next frame.
		return nil
	end

	state = {
		character = character,
		right = right,
		left = left,
		jointed = jointed, -- R15: there is an elbow and a wrist to solve with
		weight = 0,
		pose = nil,
		row = nil,
	}
	states[player] = state
	return state
end

-- One character's arms for one frame.
local function applyHold(state, weight: number)
	local pose = state.pose
	if not pose then
		return
	end

	if not state.jointed then
		-- R6: freeze the arm at rest with the tool level (see the header).
		writeChain(state.right, solveRotationOnly(state.right[1], pose.rot), nil, nil, weight)
		return
	end

	local right = state.right
	local shoulder = right[1].C0.Position
	local reach = (right[2].C0.Position - right[1].C1.Position).Magnitude
		+ (right[3].C0.Position - right[2].C1.Position).Magnitude
	local gripAt = shoulder + pose.at * reach

	local r1, r2, r3 = solveArm(right, gripAt, pose.rot, RIGHT_POLE)
	if not r1 then
		return
	end
	writeChain(right, r1, r2, r3, weight)

	-- The support hand, placed ON the weapon: a fore-end's distance down the
	-- bore from the grip. The bore is the hold offset's mapping of the
	-- weapon's authored +Y onto the hand's -Z, so in torso space it is simply
	-- the pose rotation's -Z.
	local left = state.left
	if not (pose.support and left and chainAlive(left)) then
		return
	end
	local bore = rot(pose.rot, -Vector3.zAxis)
	local foreAt = gripAt + bore * foreReach(state.row) - Vector3.new(0, pose.supportDrop or 0, 0)
	local l1, l2, l3 = solveArm(left, foreAt, pose.rot, LEFT_POLE)
	if l1 then
		writeChain(left, l1, l2, l3, weight)
	end
end

local function step(deltaTime: number)
	for _, player in Players:GetPlayers() do
		local state = stateFor(player)
		if state then
			local class, row = heldClass(state.character)

			-- Our own character: only while the camera is actually out. In
			-- first person Roblox hides it from us and the viewmodel
			-- controllers draw the camera-pinned copy instead, so there is
			-- nothing here to pose. `isThirdPerson` is true in the birdseye
			-- arenas and on the Throne as well - both are variants of it, and
			-- CameraController's updateMode sets the flag for all three -
			-- so a boss fight is covered by the same question. Other players
			-- are always third person from where we are sitting, so they are
			-- always posed - and their own client is posing them the same way.
			if class and player == localPlayer and not CameraController.isThirdPerson() then
				class = nil
			end

			if class then
				state.pose = POSES[class]
				state.row = row
			end

			local goal = if class then 1 else 0
			local rate = if class then BLEND_IN else BLEND_OUT
			state.weight += (goal - state.weight) * (1 - math.exp(-rate * deltaTime))
			if state.weight < WEIGHT_EPSILON then
				state.weight = 0
			end

			if state.weight > 0 then
				applyHold(state, state.weight)
			end
		end
	end
end

-- ============================================================ lifecycle

function ToolHoldController.init() end

function ToolHoldController.start()
	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
	end)

	-- After the character step, which is where the Animator writes the walk
	-- into the same Transforms we are about to overwrite. Bound one priority
	-- later so ours is the last word for the frame.
	RunService:BindToRenderStep("ToolHold", Enum.RenderPriority.Character.Value + 1, step)
end

return ToolHoldController
