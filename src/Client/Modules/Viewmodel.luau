--!nonstrict
-- Viewmodel.luau
-- The shared machinery behind every first-person "thing in your hands".
--
-- In first person Roblox hides the local character, so whatever the player
-- holds is drawn as a client-only rig parented to the Camera and re-pinned
-- to it every frame. Two controllers do that today - the rod
-- (RodViewmodelController) and bare fists (FistsViewmodelController) - and
-- they have to move identically: the same sway when the camera turns, the
-- same walking bob, the same idle breathing. So all of that lives here,
-- once, with module-level state. Only one viewmodel is visible at a time,
-- and sharing the state means swapping between them mid-step doesn't reset
-- the bob.
--
-- A rig is a Model of parts, each with a fixed camera-space offset and a
-- group name. Per frame a controller asks for the camera pin and hands over
-- per-group "extra" transforms - the rod's cast clip about the elbow, later
-- each fist's punch clip - which are applied between the pin and the part's
-- offset: part.CFrame = pin * extra[group] * offset.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local camera = Workspace.CurrentCamera

local Viewmodel = {}

-- ---------------------------------------------------------------- motion
-- Knobs shared by every viewmodel. Camera space: +X right, +Y up, -Z forward.

-- How far the rig lags behind the camera when it turns, for a little
-- weight. 0 = rigid.
local SWAY = 0.08

-- Walking bob: a figure-eight in the camera plane that ramps in with the
-- character's movement. Frequency is in cycles per second at full speed.
local BOB_FREQUENCY = 1.9
local BOB_SIDE = 0.07 -- studs, left-right
local BOB_UP = 0.05 -- studs, up-down (runs at twice the rate: one dip per step)
local BOB_ROLL = math.rad(1.2) -- slight rotation with the sideways swing
local BOB_RAMP = 6 -- how quickly bob weight follows movement (per second)

-- Idle breathing so nothing is ever perfectly still.
local IDLE_FREQUENCY = 0.35
local IDLE_UP = 0.02

-- A viewmodel only shows when the camera is actually at the head. Lets the
-- world model take over cleanly if the camera mode ever changes.
local FIRST_PERSON_DISTANCE = 1.5

local lastRotation: CFrame? = nil
local bobPhase = 0
local bobWeight = 0
local idleTime = 0

-- The pin is computed at most once per frame no matter how many rigs ask
-- for it, so two rigs alive during a swap don't advance the bob twice.
local frameId = 0
local pinnedFrame = -1
local pinnedValue: CFrame? = nil
RunService.RenderStepped:Connect(function()
	frameId += 1
end)

function Viewmodel.isFirstPerson(character: Model): boolean
	-- When the game's first-person lock is on (CameraController sets it), the
	-- camera IS first person by definition - trust that. The distance check
	-- below is only a fallback for a camera mode that can zoom: during a jump
	-- the head moves under physics while the camera lerps to catch up, so
	-- camera-to-head briefly spikes past the threshold and would blink the
	-- viewmodel out for a few frames on the way down.
	if Players.LocalPlayer.CameraMode == Enum.CameraMode.LockFirstPerson then
		return true
	end

	local head = character:FindFirstChild("Head")
	if not head then
		return false
	end
	return (camera.CFrame.Position - head.Position).Magnitude < FIRST_PERSON_DISTANCE
end

-- How much the character is moving, 0..1, from the humanoid's intent rather
-- than its velocity so the bob doesn't trigger when pushed or falling.
local function movementAmount(character: Model): number
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return 0
	end
	if humanoid.FloorMaterial == Enum.Material.Air then
		return 0
	end
	return math.min(humanoid.MoveDirection.Magnitude, 1)
end

local function bobOffset(dt: number, character: Model): CFrame
	-- Weight eases toward the movement amount so starting and stopping
	-- don't snap the rig.
	local target = movementAmount(character)
	bobWeight += (target - bobWeight) * math.min(dt * BOB_RAMP, 1)

	-- Phase only advances while moving, so the rig settles rather than
	-- continuing to cycle when you stop.
	bobPhase += dt * BOB_FREQUENCY * (2 * math.pi) * bobWeight
	idleTime += dt

	local side = math.sin(bobPhase) * BOB_SIDE * bobWeight
	local up = -math.abs(math.sin(bobPhase)) * BOB_UP * bobWeight
	local roll = math.sin(bobPhase) * BOB_ROLL * bobWeight
	local idle = math.sin(idleTime * IDLE_FREQUENCY * (2 * math.pi)) * IDLE_UP

	return CFrame.new(side, up + idle, 0) * CFrame.Angles(0, 0, roll)
end

-- The camera-space origin for this frame: the camera's position, its
-- rotation with sway applied, and the bob. nil when the camera isn't in
-- first person - callers hide their rig then.
function Viewmodel.pinFrame(dt: number, character: Model): CFrame?
	if pinnedFrame == frameId then
		return pinnedValue
	end
	pinnedFrame = frameId

	if not Viewmodel.isFirstPerson(character) then
		pinnedValue = nil
		return nil
	end

	-- Light sway: blend this frame's rotation toward last frame's so the rig
	-- trails the turn slightly instead of snapping with it.
	local target = camera.CFrame
	local rotation = target.Rotation
	if lastRotation and SWAY > 0 then
		rotation = lastRotation:Lerp(rotation, 1 - SWAY)
	end
	lastRotation = rotation

	pinnedValue = CFrame.new(target.Position) * rotation * bobOffset(dt, character)
	return pinnedValue
end

-- ---------------------------------------------------------------- parts

-- Makes a part safe to pin every frame: no physics, no joints, no shadows.
function Viewmodel.stripPart(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = false
	part.LocalTransparencyModifier = 0
	for _, child in part:GetChildren() do
		-- Only joints go: Motor6Ds and welds would fight the per-frame
		-- pinning. Everything else stays - in particular SurfaceAppearance,
		-- which is where a bundle avatar's actual skin texture lives, and the
		-- mesh children. Stripping those is how the hands came out as grey
		-- placeholder blocks instead of the player's skin.
		if child:IsA("JointInstance") or child:IsA("Constraint") then
			child:Destroy()
		end
	end
end

-- ---------------------------------------------------------------- arm readiness

-- How long to wait for the avatar's appearance before building with
-- whatever the character has. Studio without a signed-in account never
-- reports it loaded, so this is the path the default grey rig takes.
local APPEARANCE_TIMEOUT = 10

local function isArmPart(name: string): boolean
	return name:match("Hand$") ~= nil or name:match("LowerArm$") ~= nil
end

-- ---------------------------------------------------------------- clips

-- Generated animation data (assets/*_anim.py) is a list of frames at a fixed
-- FPS, each a { x, y, z, qx, qy, qz, qw } CFrame argument list. Built into
-- CFrames once, here.
function Viewmodel.loadClip(frames): { CFrame }
	local clip = {}
	for i, f in frames do
		clip[i] = CFrame.new(f[1], f[2], f[3], f[4], f[5], f[6], f[7])
	end
	return clip
end

-- The clip at `t` seconds in, blended between its two nearest frames
-- (CFrame:Lerp slerps the rotation). Holds the last frame past the end.
function Viewmodel.sampleClip(clip: { CFrame }, fps: number, t: number): CFrame
	local count = #clip
	local position = math.max(t, 0) * fps
	local index = math.floor(position)
	if index >= count - 1 then
		return clip[count]
	end
	return clip[index + 1]:Lerp(clip[index + 2], position - index)
end

-- Calls `onReady` once the character's arm parts exist AND the avatar's
-- appearance has finished loading, and again whenever an arm part is
-- replaced afterwards. Both matter for "the player's own hands": body
-- colours and skin textures are applied a moment after the character
-- spawns, and a bundle avatar swaps the hand MeshPart instance outright -
-- a clone taken at CharacterAdded is the default grey block, permanently.
--
-- `onReady` is responsible for checking its own situation still applies
-- (same character, still equipped) - it may run several times. Returns the
-- connection to disconnect when the character goes away.
function Viewmodel.watchArms(character: Model, onReady: () -> ()): RBXScriptConnection
	local player = Players.LocalPlayer
	local pending = false

	-- Coalesce a burst of part swaps (a bundle applies several at once)
	-- into one rebuild.
	local function schedule()
		if pending then
			return
		end
		pending = true
		task.defer(function()
			pending = false
			if character.Parent then
				onReady()
			end
		end)
	end

	local connection = character.ChildAdded:Connect(function(child)
		-- Swaps during the initial load are covered by the wait below;
		-- only react to ones that happen after the appearance is in.
		if (isArmPart(child.Name) or child:IsA("BodyColors")) and player:HasAppearanceLoaded() then
			schedule()
		end
	end)

	task.spawn(function()
		character:WaitForChild("RightHand", 5)
		local deadline = os.clock() + APPEARANCE_TIMEOUT
		while not player:HasAppearanceLoaded() and os.clock() < deadline and character.Parent do
			task.wait(0.1)
		end
		schedule()
	end)

	return connection
end

-- ---------------------------------------------------------------- rig

local Rig = {}
Rig.__index = Rig

function Viewmodel.newRig(name: string)
	local model = Instance.new("Model")
	model.Name = name
	return setmetatable({ model = model, parts = {} }, Rig)
end

-- `offset` is the part's CFrame relative to the camera; `group` names which
-- extra transform it follows in Rig:pin. Parts already inside the rig's
-- model (a whole held Model parented in first) stay where they are.
function Rig:add(part: BasePart, offset: CFrame, group: string)
	self.parts[part] = { offset = offset, group = group }
	if not part:IsDescendantOf(self.model) then
		part.Parent = self.model
	end
end

function Rig:setVisible(visible: boolean)
	local parent = if visible then camera else nil
	if self.model.Parent ~= parent then
		self.model.Parent = parent
	end
end

-- Hide EVERY viewmodel at once. A viewmodel rig is parented to the camera,
-- so in third person it would hang in front of the lens with the real
-- character visible behind it. CameraController flips this when the boss
-- arena takes the camera out to third (2026-08-29); the rigs come straight
-- back when it hands the camera back.
local hidden = false

function Viewmodel.setHidden(value: boolean)
	hidden = value
end

function Viewmodel.isHidden(): boolean
	return hidden
end

-- Places every part at pin * extras[group] * offset (identity extra when a
-- group has none).
function Rig:pin(pin: CFrame, extras: { [string]: CFrame }?)
	-- One choke point for the third-person hide: every viewmodel is posed
	-- through here every frame, so this catches the rod, the fists and the
	-- crafted weapons without each controller needing to know.
	if hidden ~= self.hiddenApplied then
		self.hiddenApplied = hidden
		self:setVisible(not hidden)
	end
	if hidden then
		return
	end
	for part, entry in self.parts do
		local extra = extras and extras[entry.group]
		part.CFrame = if extra then pin * extra * entry.offset else pin * entry.offset
	end
end

function Rig:destroy()
	self.model:Destroy()
	table.clear(self.parts)
end

-- ---------------------------------------------------------------- arms

export type Arm = {
	hand: BasePart,
	forearm: BasePart,
	handCFrame: CFrame, -- camera space, at rest
	elbow: Vector3, -- camera space; fixed - placeArm stretches the forearm from here
	direction: Vector3, -- elbow -> hand at rest
	roll: number,
}

-- The frame for a limb part: `position` is the part's centre, `direction`
-- is elbow -> hand. A limb's +Y runs up the arm toward the elbow: lookAt
-- aims the frame's -Z along `direction` (away from the elbow); the
-- Angles(90) about X then puts the frame's +Y on -that, back toward the
-- elbow. `roll` turns the part about that same arm axis.
local function limbFrame(position: Vector3, direction: Vector3, roll: number): CFrame
	return CFrame.lookAt(position, position + direction) * CFrame.Angles(math.rad(90), 0, 0) * CFrame.Angles(0, roll, 0)
end

-- The arms are the classic block Roblox limbs - a box lower arm with a
-- box hand on the end - regardless of what the player's avatar actually
-- uses. User decision (2026-08-22): their bundle's sculpted hands were not
-- the look. Sizes are the R15 block rig's; colour comes from the avatar's
-- BodyColors so it's still the player's own skin.
Viewmodel.HAND_SIZE = Vector3.new(1, 0.3, 1)
Viewmodel.LOWER_ARM_SIZE = Vector3.new(1, 1.2, 1)
local FALLBACK_SKIN = Color3.fromRGB(204, 142, 105)

-- The avatar's arm colour on one side: BodyColors first (the avatar's real
-- skin, once appearance has loaded), the character's own part as a
-- fallback, then a default tone.
local function armColor(character: Model, side: string): Color3
	local bodyColors = character:FindFirstChildOfClass("BodyColors")
	if bodyColors then
		return (bodyColors :: any)[side .. "ArmColor3"]
	end
	local hand = character:FindFirstChild(side .. "Hand")
	if hand and hand:IsA("BasePart") then
		return hand.Color
	end
	return FALLBACK_SKIN
end

local function makeBlock(name: string, size: Vector3, color: Color3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.Plastic -- what a default block limb renders as
	Viewmodel.stripPart(part)
	return part
end

-- Builds a block hand + lower arm for one side (`side` is "Right" or
-- "Left") into the rig, in the player's skin colour. The hand's centre
-- sits at `handPosition` (camera space); `forearmDirection` is the unit
-- vector from the elbow to the hand, so the forearm runs back along it;
-- `roll` turns the hand about the arm's own axis (knuckles in or out).
function Viewmodel.buildArm(
	rig,
	character: Model,
	side: string,
	group: string,
	handPosition: Vector3,
	forearmDirection: Vector3,
	roll: number?
): Arm
	local direction = forearmDirection.Unit
	local handCFrame = limbFrame(handPosition, direction, roll or 0)

	local color = armColor(character, side)
	local handSize = Viewmodel.HAND_SIZE
	local armSize = Viewmodel.LOWER_ARM_SIZE

	local hand = makeBlock(side .. "Hand", handSize, color)
	rig:add(hand, handCFrame, group)

	-- Forearm sits above the hand along the arm's own +Y; the elbow is its
	-- far end.
	local forearm = makeBlock(side .. "LowerArm", armSize, color)
	rig:add(forearm, handCFrame * CFrame.new(0, handSize.Y / 2 + armSize.Y / 2, 0), group)
	local elbow = (handCFrame * CFrame.new(0, handSize.Y / 2 + armSize.Y, 0)).Position

	return {
		hand = hand,
		forearm = forearm,
		handCFrame = handCFrame,
		elbow = elbow,
		direction = direction,
		roll = roll or 0,
	}
end

-- Places an arm for this frame with its fist at `handPosition` (camera
-- space) and its elbow where it was built, re-stretching the forearm
-- between the two. Moving the fist therefore EXTENDS the arm rather than
-- sliding a rigid block - a rigid block carries its cut-off elbow end
-- forward into view, a square face aimed straight at the camera, which is
-- what read as "the back of the hand" in the first punch builds. The
-- elbow sits below the bottom of the screen at rest and never moves, so
-- that end is never seen. Bypasses Rig:pin for these two parts; `pin` is
-- this frame's camera pin.
function Viewmodel.placeArm(arm: Arm, pin: CFrame, handPosition: Vector3)
	local toHand = handPosition - arm.elbow
	local length = toHand.Magnitude
	local direction = if length > 1e-3 then toHand.Unit else arm.direction

	arm.hand.CFrame = pin * limbFrame(handPosition, direction, arm.roll)

	local forearmLength = math.max(length - Viewmodel.HAND_SIZE.Y / 2, 0.1)
	arm.forearm.Size = Vector3.new(Viewmodel.LOWER_ARM_SIZE.X, forearmLength, Viewmodel.LOWER_ARM_SIZE.Z)
	arm.forearm.CFrame = pin * limbFrame(arm.elbow + direction * (forearmLength / 2), direction, arm.roll)
end

return Viewmodel
