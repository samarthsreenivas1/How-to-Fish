--!nonstrict
-- WeaponViewmodelController.luau
-- Draws a crafted melee weapon in first person, and plays its swings.
--
-- The rod's approach, not the fists': the weapon is built fresh from its
-- Weapons row (WeaponModel - plain parts, no mesh import) plus the player's
-- right block arm closed on the grip, all in one rig group that the swing
-- clip transforms about the elbow through Rig:pin - exactly how the cast
-- clip moves the rod. Swings are Blender-authored clips
-- (assets/weapon_swing_anim.py -> Shared/Data/WeaponSwingAnim.luau), one per
-- `swing` name on a weapon row; both ends of a clip are the idle hold, so a
-- finished swing needs no blend back and a swing thrown before the last one
-- finished blends from wherever the weapon currently is (SWING_BLEND). A
-- Trail along the weapon's length streaks while a clip plays.
--
-- Shown whenever the Player's replicated `Equipped` attribute reads
-- "weapon" AND the equipped weapon (`EquippedWeaponId`) is a row with a
-- `model`; the fists are FistsViewmodelController's. Purely visual: the hit
-- itself is CombatController asking the server at the clip's HIT_TIME.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Equipment = require(Shared.Config.Equipment)
local Weapons = require(Shared.Data.Weapons)
local WeaponSwingAnim = require(Shared.Data.WeaponSwingAnim)
local WeaponModel = require(Shared.Modules.WeaponModel)

local Viewmodel = require(script.Parent.Parent.Modules.Viewmodel)

local player = Players.LocalPlayer

local WeaponViewmodelController = {}

-- Everything in this rig swings together under the clip.
local GROUP = "arm"

-- ---------------------------------------------------------------- pose
-- All relative to the camera: +X right, +Y up, -Z forward. These are the
-- knobs to turn when the weapon doesn't sit right on screen.
-- weapon_swing_anim.py mirrors them for its preview scene - keep in step.

-- Where the grip centre sits in view: off to the right like the rod, below
-- eye level, a touch closer than the rod so a short weapon still fills some
-- screen.
local GRIP_POSITION = Vector3.new(1.55, -1.65, -2.55)

-- Weapon direction: elevation above the horizon, and yaw in toward the
-- centre of the screen. Held more upright than the rod - a blade at rest
-- stands up-and-down beside the view, not across it.
local WEAPON_PITCH = math.rad(70)
local WEAPON_YAW = math.rad(6)

-- Roll about the weapon's own axis. The blades are authored thin along the
-- axis that lands on camera Z after import, so with no roll you look at
-- the FLAT of the blade - the "held horizontally" look (user, 2026-08-22).
-- -90 turns the flats to the sides and the cutting edge forward. If the
-- edge ends up facing you instead (the importer's axis flip isn't pinned
-- down - see context.md), flip the sign. WeaponModel.HOLD_OFFSET carries
-- the same roll for the welded world copy.
local WEAPON_ROLL = math.rad(-90)

-- Which way the forearm runs, elbow to fist. Same as the rod's so swapping
-- between the two reads as the same arm.
local FOREARM_DIRECTION = Vector3.new(-0.25, 0.55, -0.8).Unit

-- ---------------------------------------------------------------- swings

-- How long a swing interrupted by the next one takes to blend into it.
local SWING_BLEND = 0.06

-- A new swing may start once this fraction of the current one has played.
-- The weapon row's cooldown (checked by CombatController) is the other
-- gate; whichever is longer wins.
local COMBO_WINDOW = 0.45

-- Each clip's frames as CFrames, built once.
local CLIPS = {}
for name, clip in WeaponSwingAnim.CLIPS do
	CLIPS[name] = Viewmodel.loadClip(clip.FRAMES)
end

-- ---------------------------------------------------------------- swing trail

local TRAIL_LIFETIME = 0.12
local TRAIL_COLOR = Color3.fromRGB(255, 255, 255)
local TRAIL_TRANSPARENCY = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.4),
	NumberSequenceKeypoint.new(1, 1),
})
local TRAIL_WIDTH = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(1, 0.4),
})

-- The ribbon spans from just above the hand to the tip. The grip part's
-- local frame is the weapon's authored frame (butt at -grip, tip at
-- length - grip along +Y), so both attachments can live on it.
local function makeTrail(grip: BasePart, weaponData): Trail
	local m = weaponData.model

	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(0, 0.8, 0)
	a0.Parent = grip
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, m.length - m.grip, 0)
	a1.Parent = grip

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
	trail.Parent = grip
	return trail
end

-- ---------------------------------------------------------------- state

local rig = nil -- Viewmodel rig while a modelled weapon is equipped
local trail: Trail? = nil

-- The swing clip is applied about swingPivot (the elbow, in camera space -
-- set at build). `swing` is the one in flight:
-- { name, startedAt, from = CFrame? } where `from` is the raw clip transform
-- the weapon was at when this swing interrupted the last, for the blend.
local swingPivot: CFrame = CFrame.new(GRIP_POSITION)
local swing = nil

local function clearRig()
	if rig then
		rig:destroy()
		rig = nil
	end
	trail = nil -- a child of the destroyed rig
	swing = nil
end

-- ---------------------------------------------------------------- build

-- The grip CFrame in camera space: the authored +Y axis pitched and yawed
-- to where we want the weapon to point (same construction as the rod's),
-- then rolled about that axis so the blade's edge leads.
local function gripInCameraSpace(): CFrame
	local direction = CFrame.Angles(0, WEAPON_YAW, 0)
		* CFrame.Angles(WEAPON_PITCH - math.rad(90), 0, 0)
		* CFrame.Angles(0, WEAPON_ROLL, 0)
	return CFrame.new(GRIP_POSITION) * direction
end

local function buildRig(character: Model, weaponData)
	clearRig()

	local weapon = WeaponModel.build(weaponData)
	local grip = weapon and WeaponModel.findGrip(weapon)
	if not weapon or not grip then
		warn(string.format("[WeaponViewmodel] weapon %q built nothing to hold", weaponData.id))
		if weapon then
			weapon:Destroy()
		end
		return
	end

	local newRig = Viewmodel.newRig("WeaponViewmodel")

	local gripCamera = gripInCameraSpace()
	local gripLocal = grip.CFrame
	weapon.Parent = newRig.model
	for _, part in weapon:GetDescendants() do
		if part:IsA("BasePart") then
			Viewmodel.stripPart(part)
			newRig:add(part, gripCamera * gripLocal:ToObjectSpace(part.CFrame), GROUP)
		end
	end

	-- Arm: a block hand + forearm in the player's skin colour, hand closed
	-- on the grip, arm running back along FOREARM_DIRECTION.
	local arm = Viewmodel.buildArm(newRig, character, "Right", GROUP, GRIP_POSITION, FOREARM_DIRECTION)

	-- Swing pivot: the elbow, so a swing moves the arm and the weapon together.
	swingPivot = CFrame.new(arm.elbow)

	trail = makeTrail(grip, weaponData)

	rig = newRig
	newRig:setVisible(true)
end

-- The Weapons row to draw, or nil (rod out, fists out, unknown id).
local function equippedWeaponData()
	if player:GetAttribute(Equipment.ATTRIBUTE) ~= Equipment.WEAPON then
		return nil
	end
	local weaponId = player:GetAttribute(Equipment.WEAPON_ATTRIBUTE)
	local weaponData = weaponId and Weapons.items[weaponId]
	if weaponData and weaponData.model then
		return weaponData
	end
	return nil
end

-- Whether the character's arms are ready to build - the avatar's own skin
-- colour only exists once its appearance has loaded (see
-- Viewmodel.watchArms).
local armsReady = false
local armsWatch: RBXScriptConnection? = nil

-- Builds or clears the rig to match the current loadout and character.
local function refresh()
	local character = player.Character
	local weaponData = equippedWeaponData()
	if not character or not armsReady or not weaponData then
		clearRig()
		return
	end
	buildRig(character, weaponData)
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

-- ---------------------------------------------------------------- swing playback

-- The raw clip transform right now (identity when idle), with the blend
-- from an interrupted swing folded in. Also retires a finished swing.
local function rawSwing(now: number): CFrame
	if not swing then
		return CFrame.identity
	end

	local clip = WeaponSwingAnim.CLIPS[swing.name]
	local t = now - swing.startedAt
	if t >= clip.DURATION then
		swing = nil
		return CFrame.identity
	end

	local sampled = Viewmodel.sampleClip(CLIPS[swing.name], WeaponSwingAnim.FPS, t)
	if swing.from and t < SWING_BLEND then
		sampled = swing.from:Lerp(sampled, t / SWING_BLEND)
	end
	return sampled
end

-- This frame's swing transform in camera space, applied about the elbow so
-- the hand swings with the weapon instead of the weapon turning in a fixed
-- fist.
local function swingOffset(now: number): CFrame
	local anim = rawSwing(now)
	if anim == CFrame.identity then
		return CFrame.identity
	end
	return swingPivot * anim * swingPivot:Inverse()
end

-- Start the named swing clip. Returns the clip's HIT_TIME (seconds from now
-- until the weapon is at the bottom of its arc - when CombatController asks
-- the server to land it), or nil if no weapon is out, the clip doesn't
-- exist, or the current swing hasn't played far enough to chain into another.
function WeaponViewmodelController.swing(name: string): number?
	local clip = WeaponSwingAnim.CLIPS[name]
	if not rig or not clip then
		return nil
	end

	local now = os.clock()
	local from = nil
	if swing then
		local current = WeaponSwingAnim.CLIPS[swing.name]
		if now - swing.startedAt < current.DURATION * COMBO_WINDOW then
			return nil
		end
		from = rawSwing(now)
	end

	swing = { name = name, startedAt = now, from = from }
	return clip.HIT_TIME
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

	rig:pin(pin, { [GROUP] = swingOffset(os.clock()) })

	-- swingOffset has already retired a finished clip, so this also switches
	-- the trail off on time.
	if trail then
		trail.Enabled = swing ~= nil
	end
end

-- ---------------------------------------------------------------- lifecycle

function WeaponViewmodelController.init()
	player:GetAttributeChangedSignal(Equipment.ATTRIBUTE):Connect(refresh)
	player:GetAttributeChangedSignal(Equipment.WEAPON_ATTRIBUTE):Connect(refresh)
	player.CharacterAdded:Connect(watchCharacter)
	player.CharacterRemoving:Connect(clearRig)
	if player.Character then
		watchCharacter(player.Character)
	end
end

function WeaponViewmodelController.start()
	RunService:BindToRenderStep("WeaponViewmodel", Enum.RenderPriority.Camera.Value + 2, onRenderStep)
end

return WeaponViewmodelController
