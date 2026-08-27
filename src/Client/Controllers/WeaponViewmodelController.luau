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
local GunReloadAnim = require(Shared.Data.GunReloadAnim)
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

-- ---------------------------------------------------------------- reloads
-- Multi-track reload clips (assets/gun_reload_anim.py), one per gun variant
-- plus the Generic fallback. Track semantics: `weapon` moves the whole rig
-- about the elbow (the swing contract); `mag` / `action` move that part
-- LOCAL about its own home (rotation spins it in place, translation is
-- camera axes); `hand` moves the parked LEFT arm the same way. Playback is
-- time-scaled so the clip fills the row's server reloadTime exactly - the
-- visual always fits the window CombatService enforces, never extends it.

local RELOAD_CLIPS = {}
for name, clip in GunReloadAnim.CLIPS do
	local tracks = {}
	for trackName, frames in clip.TRACKS do
		tracks[trackName] = Viewmodel.loadClip(frames)
	end
	RELOAD_CLIPS[name] = { duration = clip.DURATION, tracks = tracks }
end

-- The parked left arm: rests off the bottom of the screen between reloads,
-- rises to handle the mag when a clip keys it up. Rest pose sits at the
-- gun's fore-end, mirrored forearm.
local LEFT_HAND_REST = Vector3.new(0.75, -1.35, -3.1)
local LEFT_FOREARM_DIRECTION = Vector3.new(0.45, 0.5, -0.74).Unit
local LEFT_HAND_PARK = CFrame.new(-0.3, -2.6, 0.6) -- applied while idle

local MAG_GROUP = "mag"
local ACTION_GROUP = "action"
local LEFT_GROUP = "reloadHand"

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

-- ---------------------------------------------------------------- recoil
-- A gun's kick is procedural rather than a Blender clip: each shot adds to a
-- spring that pitches the whole rig group back about the elbow and shoves it
-- toward the shoulder, then decays. Code-driven so the guns needed no new
-- animation data file - the same reasoning as the cast clip being data, not
-- a Roblox Animation.

local RECOIL_MAX = 1.6 -- the spring never winds past this, however fast the trigger
local RECOIL_PITCH = math.rad(5.5) -- pitch back per unit of recoil
local RECOIL_BACK = 0.16 -- studs toward the shoulder per unit
local RECOIL_DECAY = 10 -- per second, exponential

local recoil = 0

-- ---------------------------------------------------------------- state

local rig = nil -- Viewmodel rig while a modelled weapon is equipped
local trail: Trail? = nil
local gripPart: BasePart? = nil -- the built weapon's grip, for the muzzle
local gripLength = 0 -- grip -> tip distance of the current weapon, studs
local muzzlePart: BasePart? = nil -- the Weapon_Muzzle marker, when the mesh carries one

-- The swing clip is applied about swingPivot (the elbow, in camera space -
-- set at build). `swing` is the one in flight:
-- { name, startedAt, from = CFrame? } where `from` is the raw clip transform
-- the weapon was at when this swing interrupted the last, for the blend.
local swingPivot: CFrame = CFrame.new(GRIP_POSITION)
local swing = nil

-- The reload in flight: { clip, startedAt, scale } (scale stretches the
-- authored DURATION onto the row's real reloadTime), plus the camera-space
-- home positions the mag/action/hand tracks pivot about. All torn down with
-- the rig - a weapon swap mid-reload just leaves the countdown to the
-- server, exactly as before this system existed.
local reload = nil
local magHome: Vector3? = nil
local actionHome: Vector3? = nil
local leftHome: Vector3? = nil
local hasLeftArm = false

local function clearRig()
	if rig then
		rig:destroy()
		rig = nil
	end
	trail = nil -- a child of the destroyed rig
	gripPart = nil
	muzzlePart = nil
	swing = nil
	recoil = 0
end

-- ---------------------------------------------------------------- build

-- A GUN's hold (rows with `ranged`): the authored +Y is the BORE (gun-mesh
-- contract, 2026-08-27), so it points camera-forward with a touch of muzzle
-- rise, carried lower and nearer centre than a blade. GUN_ROLL turns the
-- sights side (the blade-edge side of the authoring frame) up - it is the
-- one knob to flip if a pack lands the guns rolled sideways.
local GUN_GRIP_POSITION = Vector3.new(0.95, -1.2, -1.7)
local GUN_PITCH = math.rad(4) -- muzzle rise off dead-level
local GUN_YAW = math.rad(-2)
-- +90, NOT -90: the glb import mirrors the authored X axis (Blender +X
-- lands at Roblox -X - the same handedness gotcha the creature pack
-- documents), so the sights side arrives on LOCAL -X and needs the
-- opposite roll to face screen-up. Confirmed in hand 2026-08-27 (the
-- -90 first guess held every rifle upside down).
local GUN_ROLL = math.rad(90)

-- The grip CFrame in camera space: the authored +Y axis pitched and yawed
-- to where we want the weapon to point (same construction as the rod's),
-- then rolled about that axis so the blade's edge leads - or, for a gun,
-- so the bore runs forward and the sights sit up.
local function gripInCameraSpace(isRanged: boolean?): CFrame
	if isRanged then
		local direction = CFrame.Angles(0, GUN_YAW, 0)
			* CFrame.Angles(GUN_PITCH - math.rad(90), 0, 0)
			* CFrame.Angles(0, GUN_ROLL, 0)
		return CFrame.new(GUN_GRIP_POSITION) * direction
	end
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

	local gripCamera = gripInCameraSpace(weaponData.ranged ~= nil)
	local gripLocal = grip.CFrame
	weapon.Parent = newRig.model
	reload = nil
	magHome, actionHome, leftHome = nil, nil, nil
	hasLeftArm = false
	for _, part in weapon:GetDescendants() do
		if part:IsA("BasePart") then
			Viewmodel.stripPart(part)
			local offset = gripCamera * gripLocal:ToObjectSpace(part.CFrame)
			-- Mag and action live in their own rig groups so the reload
			-- clips can pull the magazine out of the gun and cycle the bolt;
			-- idle (identity extras) they sit exactly where GROUP would put
			-- them.
			local group = GROUP
			if part.Name == "Weapon_Mag" then
				group = MAG_GROUP
				magHome = offset.Position
			elseif part.Name == "Weapon_Action" then
				group = ACTION_GROUP
				actionHome = offset.Position
			end
			newRig:add(part, offset, group)
			-- The gun-mesh contract's muzzle marker: the flash / tracer origin.
			if part.Name == "Weapon_Muzzle" then
				muzzlePart = part
			end
		end
	end

	-- Guns get the parked LEFT arm the reload clips raise into frame; it
	-- idles below the screen edge (LEFT_HAND_PARK every frame).
	if weaponData.ranged then
		local leftArm =
			Viewmodel.buildArm(newRig, character, "Left", LEFT_GROUP, LEFT_HAND_REST, LEFT_FOREARM_DIRECTION)
		leftHome = leftArm.handCFrame.Position
		hasLeftArm = true
	end

	-- Arm: a block hand + forearm in the player's skin colour, hand closed
	-- on the grip, arm running back along FOREARM_DIRECTION.
	local arm = Viewmodel.buildArm(newRig, character, "Right", GROUP, GRIP_POSITION, FOREARM_DIRECTION)

	-- Swing pivot: the elbow, so a swing moves the arm and the weapon together.
	swingPivot = CFrame.new(arm.elbow)

	trail = makeTrail(grip, weaponData)
	gripPart = grip
	gripLength = weaponData.model.length - weaponData.model.grip

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

-- This frame's recoil transform, about the same elbow pivot as the swings,
-- so a shot kicks the whole arm-and-gun group back and up together.
local function recoilOffset(): CFrame
	if recoil < 0.005 then
		return CFrame.identity
	end
	local raw = CFrame.Angles(RECOIL_PITCH * recoil, 0, 0) * CFrame.new(0, 0, RECOIL_BACK * recoil)
	return swingPivot * raw * swingPivot:Inverse()
end

-- One shot's kick. `strength` scales it (1 = a rifle round; a scattergun
-- passes more, an SMG less), clamped so full-auto can't wind the spring up
-- past readable.
function WeaponViewmodelController.kick(strength: number?)
	recoil = math.min(recoil + (strength or 1) * 0.55, RECOIL_MAX)
end

-- Play the gun's reload choreography, stretched to fill `seconds` (the
-- row's server-enforced reloadTime, or - for reloadTime-0 loaders like the
-- bow - the slice of the cooldown the caller gives it). RangedController
-- calls this: at reload start for magazine guns, after each shot for the
-- per-shot loaders. Purely cosmetic - the server's clock is untouched.
function WeaponViewmodelController.reloadAnim(variant: string?, seconds: number)
	if not rig or seconds <= 0 then
		return
	end
	local clip = (variant and RELOAD_CLIPS[variant]) or RELOAD_CLIPS.Generic
	if not clip then
		return
	end
	reload = {
		clip = clip,
		startedAt = os.clock(),
		scale = seconds / clip.duration,
	}
end

-- The muzzle's world position (the built weapon's tip), for the tracer's
-- start. Nil when no modelled weapon is up - the caller falls back to the
-- camera.
function WeaponViewmodelController.getMuzzlePosition(): Vector3?
	if not rig then
		return nil
	end
	-- The mesh contract's Weapon_Muzzle marker is authoritative (it caps the
	-- bore exactly); the grip+length projection is the pre-mesh fallback.
	if muzzlePart then
		return muzzlePart.Position
	end
	if not gripPart then
		return nil
	end
	return gripPart.CFrame:PointToWorldSpace(Vector3.new(0, gripLength, 0))
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

-- A track sample applied LOCAL about a part's home point: the rotation
-- spins the part in place, the translation moves it in camera axes -
-- which is what lets a clip pull a magazine straight down out of its well
-- or roll a revolver cylinder about its own axle.
local function localAbout(home: Vector3, sample: CFrame): CFrame
	local rotation = sample - sample.Position
	return CFrame.new(sample.Position) * CFrame.new(home) * rotation * CFrame.new(-home)
end

-- The reload's per-frame contribution: extras for the mag / action / hand
-- groups plus the whole-weapon track (composed about the elbow like a
-- swing). Retires itself when the scaled clip runs out.
local function reloadOffsets(now: number, extras: { [string]: CFrame }): CFrame
	if not reload then
		return CFrame.identity
	end
	local t = (now - reload.startedAt) / reload.scale
	if t >= reload.clip.duration then
		reload = nil
		return CFrame.identity
	end
	local tracks = reload.clip.tracks
	local fps = GunReloadAnim.FPS
	if tracks.mag and magHome then
		extras[MAG_GROUP] = localAbout(magHome, Viewmodel.sampleClip(tracks.mag, fps, t))
	end
	if tracks.action and actionHome then
		extras[ACTION_GROUP] = localAbout(actionHome, Viewmodel.sampleClip(tracks.action, fps, t))
	end
	if tracks.hand and leftHome then
		extras[LEFT_GROUP] = localAbout(leftHome, Viewmodel.sampleClip(tracks.hand, fps, t))
	end
	if tracks.weapon then
		local raw = Viewmodel.sampleClip(tracks.weapon, fps, t)
		return swingPivot * raw * swingPivot:Inverse()
	end
	return CFrame.identity
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

	-- The recoil spring decays every frame; swings, recoil and the reload's
	-- weapon track all compose about the same elbow pivot. The parked left
	-- arm idles off-screen unless a reload track raises it.
	recoil *= math.exp(-RECOIL_DECAY * dt)
	local extras: { [string]: CFrame } = {}
	if hasLeftArm then
		extras[LEFT_GROUP] = LEFT_HAND_PARK
	end
	local reloadWeapon = reloadOffsets(os.clock(), extras)
	extras[GROUP] = swingOffset(os.clock()) * recoilOffset() * reloadWeapon
	rig:pin(pin, extras)

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
