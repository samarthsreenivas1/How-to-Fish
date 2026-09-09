--!nonstrict
-- ToolHoldController.luau
-- Makes a character in third person look like it is HOLDING the thing in its
-- hand rather than having it glued to a swinging arm.
--
-- The defect this fixes: RodService/WeaponService weld the equipped model to
-- the RIGHT HAND part (server-side, so it replicates - see the header of
-- either service). That weld is rigid, so whatever the hand does, the tool
-- does. With the default Animate script running, the hand swings through the
-- whole walk cycle, and the gun/rod swings and rotates with it. That reads as
-- "attached to the arm", which is exactly the complaint. The hold offsets in
-- RodModel.HOLD_OFFSET / WeaponModel.HOLD_OFFSET_RANGED were authored for a
-- HANGING hand ("a hanging hand's forward is -Z"), so they are only correct
-- at one instant of the swing and wrong for the rest of it.
--
-- The fix, in one sentence: hold the RIGHT HAND'S ORIENTATION fixed relative
-- to the torso, and get there by posing the arm joints - never by touching
-- the legs, the root or the waist, which keep the stock walk.
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
-- look exactly as they did - and because the waist still moves, the tool
-- keeps a subtle torso bob instead of being dead in space.
--
-- THE WRIST SOLVE
--
-- If you simply rotate the shoulder and elbow into a nice carry, the hand -
-- and therefore the welded tool - inherits the whole rotation, and the gun
-- points at the sky. So the LAST joint of the right chain is not posed, it is
-- SOLVED: given the poses on the joints above it, it is set to whatever makes
-- the hand's rotation relative to the torso come out at the pose's `hand`
-- target. `hand = identity` reproduces the rest-pose hand the hold offsets
-- were authored against, so the tool sits exactly the way its offset says,
-- every frame, while the arm above it is in a carry.
--
-- The solve reads the joints' real C0/C1 rather than assuming the standard
-- rig's identity attachments, which is also what makes R6 fall out for free:
-- an R6 arm has ONE joint (Right Shoulder) and no wrist, so that one joint is
-- the solved one and the arm ends up frozen at the hanging rest pose with the
-- tool level. Not a carry, but the swing - the actual defect - is gone.
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

-- ============================================================ the poses

local function angles(x: number, y: number, z: number): CFrame
	return CFrame.Angles(math.rad(x), math.rad(y), math.rad(z))
end

-- R15 joint axes, at the rest pose, are the torso's: an arm hangs along -Y,
-- the character faces -Z. So on a shoulder, +X pitches the arm FORWARD and
-- -X swings it back; on the right side -Z lifts the elbow out from the ribs.
-- On an elbow, +X bends the forearm forward. Those are the only three knobs
-- used below.
--
-- `right` poses the joints ABOVE the solved one, in order from the torso
-- out: on R15 that is { shoulder, elbow } and the wrist is solved; on R6 the
-- shoulder is the solved one and nothing here is read. Extra entries are
-- ignored, so one table serves both rigs.
--
-- `hand` is the hand's target rotation relative to the torso. Identity =
-- exactly the hanging-hand rotation that RodModel.HOLD_OFFSET and
-- WeaponModel.holdOffsetFor were authored against, which is what keeps the
-- bore level and the blade up. Change it only if you also want the tool
-- itself tilted, and expect the wrist to pay for it.
--
-- `left` poses the support arm outright (no solve - it holds nothing). Omit
-- it and the left arm keeps the ordinary walk swing.
--
-- The angles are eyeballed, not measured off a rig. They are the intended
-- tuning surface: nudge these, nothing else.
local POSES = {
	-- A gun rides a relaxed low-ready: upper arm back off the ribs, elbow
	-- bent so the grip sits forward of the hip, bore level and forward. The
	-- left hand comes across and down to where a fore-end would be.
	gun = {
		hand = angles(0, 0, 0),
		right = { angles(-22, 0, -10), angles(50, 0, 0) },
		left = { angles(30, 6, 22), angles(55, 0, 0), angles(-12, 0, 0) },
	},

	-- A rod carries a little higher and looser than a gun - the authored
	-- offset already points it forward and up, so the arm only has to get
	-- the butt in front of the hip. Left hand near where the reel sits.
	rod = {
		hand = angles(0, 0, 0),
		right = { angles(-15, 0, -8), angles(45, 0, 0) },
		left = { angles(22, 6, 18), angles(50, 0, 0), angles(-10, 0, 0) },
	},

	-- Melee is one-handed: blade-up carry at the side, and NO `left`, so the
	-- off hand keeps swinging with the walk the way a real free arm does.
	-- Posing it would only make the character look like it is carrying an
	-- invisible second weapon.
	melee = {
		hand = angles(0, 0, 0),
		right = { angles(-12, 0, -12), angles(38, 0, 0) },
	},
}

-- ============================================================ the chains

-- Each entry is { part name, Motor6D name }, ordered from the torso outward.
-- The LAST joint of a right-hand chain is the solved one.
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

-- ============================================================ posing

-- Writes one arm chain at `weight`, lerping from whatever the Animator just
-- put in Transform toward the pose, so a partial weight is a real blend
-- between the walk swing and the hold rather than a jump.
--
-- With `target`, the last joint is solved instead of posed (see the header):
-- the hand's rotation relative to the chain's root part comes out at
-- `target` regardless of what the joints above it were set to.
local function applyChain(joints: { Motor6D }, poses, target: CFrame?, weight: number)
	local count = #joints
	local accumulated = CFrame.identity

	for index, joint in joints do
		local desired
		if target and index == count then
			-- Motor6D: Part1 = Part0 * C0 * Transform * C1:Inverse(). Walk
			-- the product down the chain, then invert what is left so the
			-- composed rotation lands on `target`.
			local reached = (accumulated * joint.C0).Rotation
			desired = reached:Inverse() * target * joint.C1.Rotation
		else
			desired = (poses and poses[index]) or CFrame.identity
			if target then
				accumulated = accumulated * joint.C0 * desired * joint.C1:Inverse()
			end
		end
		joint.Transform = joint.Transform:Lerp(desired, weight)
	end
end

-- ============================================================ state

-- One entry per player whose arms we are currently blending. Cheap: the
-- joints are cached, so a frame is a handful of CFrame multiplies per player.
local states: { [Player]: any } = {}

-- Which pose a character's hands call for, or nil for empty hands. Keyed off
-- the welded model the SERVER put there, so it is the same answer on every
-- client - which is the whole replication story.
local function heldClass(character: Model): string?
	if character:FindFirstChild(ROD_NAME) then
		return "rod"
	end
	local weapon = character:FindFirstChild(WEAPON_NAME)
	if not weapon then
		-- Bare fists weld nothing, so there is no model here and no hold -
		-- the arms swing normally, which is right for fists.
		return nil
	end
	local weaponId = weapon:GetAttribute("WeaponId")
	local row = weaponId and Weapons.items[weaponId]
	if row and row.ranged then
		return "gun"
	end
	return "melee"
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
	local right = findChain(character, R15_RIGHT) or findChain(character, R6_RIGHT)
	if not right then
		-- Rig still streaming in. Cache nothing; try again next frame.
		return nil
	end

	state = {
		character = character,
		right = right,
		left = findChain(character, R15_LEFT) or findChain(character, R6_LEFT),
		weight = 0,
		pose = nil,
	}
	states[player] = state
	return state
end

local function step(deltaTime: number)
	for _, player in Players:GetPlayers() do
		local state = stateFor(player)
		if state then
			local class = heldClass(state.character)

			-- Our own character: only while the camera is actually out. In
			-- first person Roblox hides it from us and the viewmodel
			-- controllers draw the camera-pinned copy instead, so there is
			-- nothing here to pose. Other players are always third person
			-- from where we are sitting, so they are always posed - and
			-- their own client is posing them the same way.
			if class and player == localPlayer and not CameraController.isThirdPerson() then
				class = nil
			end

			if class then
				state.pose = POSES[class]
			end

			local goal = if class then 1 else 0
			local rate = if class then BLEND_IN else BLEND_OUT
			state.weight += (goal - state.weight) * (1 - math.exp(-rate * deltaTime))
			if state.weight < WEIGHT_EPSILON then
				state.weight = 0
			end

			if state.weight > 0 and state.pose then
				applyChain(state.right, state.pose.right, state.pose.hand, state.weight)
				if state.left and state.pose.left then
					applyChain(state.left, state.pose.left, nil, state.weight)
				end
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
