--!nonstrict
-- FistsViewmodelController.luau
-- Draws the player's fists in first person while fists are equipped, and
-- plays the punches.
--
-- Same approach as the rod: client-only block arms in the player's skin
-- colour (Viewmodel.buildArm - the classic box lower arm + hand, by user
-- decision, not the avatar's sculpted parts), pinned to the camera each
-- frame through the shared Viewmodel rig so they sway, bob and breathe
-- exactly like the rod does. Both fists are built as their own rig groups
-- ("left" / "right"), each pivoting at its own elbow.
--
-- Punches are Blender-authored clips (assets/fist_punch_anim.py ->
-- Shared/Data/FistPunchAnim.luau) with a track per fist - the leading fist
-- punches while the other tightens the guard. Only a track's TRANSLATION
-- is used: it moves that fist, and the forearm is re-stretched every frame
-- from the fixed elbow to wherever the fist now is (Viewmodel.placeArm), so
-- a punch extends the arm toward the screen centre instead of sliding a
-- rigid block forward and dragging its cut-off elbow end into view (the
-- "back of the hand" the user kept seeing). punch() cycles through the clip
-- sequence (jab, cross, ...). A punch thrown before the last one finished
-- blends from wherever the fists currently are into the new clip, so
-- mashing reads as a combo rather than a series of snaps. Purely visual for
-- now: no hit check, no damage - that's the combat slice. HIT_TIME on each
-- clip is where it'll go.
--
-- Shown whenever the Player's replicated `Equipped` attribute (set by
-- InventoryService) reads "weapon" AND the equipped weapon is the fists
-- (the `EquippedWeaponId` attribute); hidden otherwise - a crafted weapon
-- is WeaponViewmodelController's. The server removes the welded rod at the
-- same moment, which is what makes RodViewmodelController drop its own rig -
-- none of the three controllers needs to know about the others.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Equipment = require(Shared.Config.Equipment)
local FistPunchAnim = require(Shared.Data.FistPunchAnim)
local Weapons = require(Shared.Data.Weapons)

local Viewmodel = require(script.Parent.Parent.Modules.Viewmodel)

local player = Players.LocalPlayer

local FistsViewmodelController = {}

-- ---------------------------------------------------------------- pose
-- The right fist, in camera space (+X right, +Y up, -Z forward); the left is
-- its mirror. A loose guard: fists in front and a little below eye level,
-- forearms coming up from the bottom corners of the screen. These are the
-- knobs to turn when the hands don't sit right. fist_punch_anim.py mirrors
-- them for its preview scene - keep the two in step.

local FIST_POSITION = Vector3.new(0.8, -1.1, -2.4)

-- Elbow -> fist direction. Rises and comes inward from the bottom-right.
local FOREARM_DIRECTION = Vector3.new(-0.3, 0.62, -0.72).Unit

-- Turn of the hand about its own arm axis, knuckles in (+) or out (-).
local HAND_ROLL = math.rad(0)

local MIRROR = Vector3.new(-1, 1, 1)

local GROUPS = { "left", "right" }

-- ---------------------------------------------------------------- punches

-- How long a punch interrupted by the next one takes to blend into it.
local PUNCH_BLEND = 0.08

-- A new punch may start once this fraction of the current one has played:
-- early enough that mashing chains into a combo, late enough that the
-- first punch actually reads as one. Tuning.Combat.PUNCH_COOLDOWN (checked
-- by CombatController) is the other gate; whichever is longer wins.
local COMBO_WINDOW = 0.5

-- Each clip's tracks as CFrames, built once.
local CLIPS = {}
for name, clip in FistPunchAnim.CLIPS do
	CLIPS[name] = {
		left = Viewmodel.loadClip(clip.TRACKS.left),
		right = Viewmodel.loadClip(clip.TRACKS.right),
	}
end

-- ---------------------------------------------------------------- swing trail
-- A short ribbon off the knuckles of the punching fist, on only while its
-- clip plays, so a punch reads as a streak rather than a block sliding.

local TRAIL_LIFETIME = 0.1
local TRAIL_COLOR = Color3.fromRGB(255, 255, 255)
local TRAIL_TRANSPARENCY = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.35),
	NumberSequenceKeypoint.new(1, 1),
})
local TRAIL_WIDTH = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(1, 0.3),
})

-- The hand block's local +Y runs up the arm, so -Y is the knuckle end; the
-- ribbon spans the hand's width along X at that end.
local function makeTrail(hand: BasePart): Trail
	local halfWidth = Viewmodel.HAND_SIZE.X / 2
	local knuckleY = -Viewmodel.HAND_SIZE.Y / 2

	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(-halfWidth, knuckleY, 0)
	a0.Parent = hand
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(halfWidth, knuckleY, 0)
	a1.Parent = hand

	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Lifetime = TRAIL_LIFETIME
	trail.MinLength = 0.05
	trail.Color = ColorSequence.new(TRAIL_COLOR)
	trail.Transparency = TRAIL_TRANSPARENCY
	trail.WidthScale = TRAIL_WIDTH
	trail.LightEmission = 0.6
	trail.FaceCamera = false
	trail.Enabled = false
	trail.Parent = hand
	return trail
end

-- ---------------------------------------------------------------- state

local rig = nil -- Viewmodel rig while fists are equipped

-- Per-group swing trails, rebuilt with the rig.
local trails: { [string]: Trail } = {}

-- The two arms, per group, from Viewmodel.buildArm. Their parts are placed
-- directly each frame (placeArm), not through Rig:pin.
local arms: { [string]: Viewmodel.Arm } = {}

-- The punch in flight: { name, startedAt, from = { left = CFrame, right = CFrame } }
-- where `from` is the raw (un-pivoted) pose each fist was in when this
-- punch started, for the blend.
local punch = nil
local nextInSequence = 1

local function clearRig()
	if rig then
		rig:destroy()
		rig = nil
	end
	table.clear(arms)
	table.clear(trails) -- they were children of the destroyed rig
	punch = nil
end

local function buildRig(character: Model)
	clearRig()

	local newRig = Viewmodel.newRig("FistsViewmodel")
	local right = Viewmodel.buildArm(newRig, character, "Right", "right", FIST_POSITION, FOREARM_DIRECTION, HAND_ROLL)
	local left = Viewmodel.buildArm(
		newRig,
		character,
		"Left",
		"left",
		FIST_POSITION * MIRROR,
		(FOREARM_DIRECTION * MIRROR).Unit,
		-HAND_ROLL
	)

	arms.right = right
	arms.left = left

	trails.right = makeTrail(right.hand)
	trails.left = makeTrail(left.hand)

	rig = newRig
	newRig:setVisible(true)
end

-- Fists are out when the weapon loadout is up and the chosen weapon is the
-- fists. A missing weapon attribute (not published yet) counts as fists,
-- the server's own default.
local function isEquipped(): boolean
	if player:GetAttribute(Equipment.ATTRIBUTE) ~= Equipment.WEAPON then
		return false
	end
	local weaponId = player:GetAttribute(Equipment.WEAPON_ATTRIBUTE) or Weapons.STARTER_WEAPON_ID
	return weaponId == Weapons.STARTER_WEAPON_ID
end

-- Whether the character's arms are ready to build - the avatar's own skin
-- colour only exists once its appearance has loaded (see
-- Viewmodel.watchArms).
local armsReady = false
local armsWatch: RBXScriptConnection? = nil

-- Builds or clears the rig to match the current loadout and character.
local function refresh()
	local character = player.Character
	if not character or not armsReady or not isEquipped() then
		clearRig()
		return
	end
	buildRig(character)
end

local function watchCharacter(character: Model)
	clearRig()
	armsReady = false
	if armsWatch then
		armsWatch:Disconnect()
	end
	armsWatch = Viewmodel.watchArms(character, function()
		if player.Character ~= character then
			return
		end
		armsReady = true
		refresh()
	end)
end

-- ---------------------------------------------------------------- punch playback

-- Each fist's raw clip transform right now (identity at rest); only its
-- translation is used by the caller. Also retires a finished punch.
local function punchPose(now: number): { [string]: CFrame }
	local pose = { left = CFrame.identity, right = CFrame.identity }
	if not punch then
		return pose
	end

	local clip = FistPunchAnim.CLIPS[punch.name]
	local t = now - punch.startedAt
	if t >= clip.DURATION then
		punch = nil
		return pose
	end

	local tracks = CLIPS[punch.name]
	for _, group in GROUPS do
		local sampled = Viewmodel.sampleClip(tracks[group], FistPunchAnim.FPS, t)
		-- Interrupted punch: ease from where that fist was into this clip.
		local from = punch.from and punch.from[group]
		if from and t < PUNCH_BLEND then
			sampled = from:Lerp(sampled, t / PUNCH_BLEND)
		end
		pose[group] = sampled
	end
	return pose
end

-- Throw the next punch in the sequence. Returns the clip's HIT_TIME (seconds
-- from now until full extension - when CombatController asks the server to
-- land it), or nil if fists aren't out or the current punch hasn't played
-- far enough to chain into another.
function FistsViewmodelController.punch(): number?
	if not rig then
		return nil
	end

	local now = os.clock()
	local from = nil
	if punch then
		local clip = FistPunchAnim.CLIPS[punch.name]
		if now - punch.startedAt < clip.DURATION * COMBO_WINDOW then
			return nil
		end
		from = punchPose(now)
	end

	local name = FistPunchAnim.SEQUENCE[nextInSequence]
	punch = {
		name = name,
		startedAt = now,
		from = from,
	}
	nextInSequence = nextInSequence % #FistPunchAnim.SEQUENCE + 1
	return FistPunchAnim.CLIPS[name].HIT_TIME
end

-- ---------------------------------------------------------------- per frame

local function onRenderStep(dt: number)
	if not rig then
		return
	end

	local character = player.Character
	local pin = character and Viewmodel.pinFrame(dt, character)
	if not pin then
		rig:setVisible(false)
		return
	end
	rig:setVisible(true)

	-- Each fist goes where its track's translation says (camera space,
	-- relative to the guard); the forearm stretches from the fixed elbow to
	-- meet it. The track's rotation is ignored - the arm's direction is
	-- whatever elbow -> fist is.
	local pose = punchPose(os.clock())
	for _, group in GROUPS do
		local arm = arms[group]
		if arm then
			Viewmodel.placeArm(arm, pin, arm.handCFrame.Position + pose[group].Position)
		end
	end

	-- Only the fist that's actually punching streaks. punchPose has already
	-- retired a finished clip, so this also switches the trail off on time.
	local lead = punch and FistPunchAnim.CLIPS[punch.name].lead
	for group, trail in trails do
		trail.Enabled = group == lead
	end
end

-- ---------------------------------------------------------------- lifecycle

function FistsViewmodelController.init()
	player:GetAttributeChangedSignal(Equipment.ATTRIBUTE):Connect(refresh)
	player:GetAttributeChangedSignal(Equipment.WEAPON_ATTRIBUTE):Connect(refresh)
	player.CharacterAdded:Connect(watchCharacter)
	player.CharacterRemoving:Connect(clearRig)
	if player.Character then
		watchCharacter(player.Character)
	end
end

function FistsViewmodelController.start()
	RunService:BindToRenderStep("FistsViewmodel", Enum.RenderPriority.Camera.Value + 2, onRenderStep)
end

return FistsViewmodelController
