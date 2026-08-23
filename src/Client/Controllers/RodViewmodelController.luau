--!nonstrict
-- RodViewmodelController.luau
-- Draws the rod in first person.
--
-- In first person Roblox hides the local character entirely - including the
-- rod RodService welds to its hand - so the held rod has to be drawn another
-- way: a client-only copy of the rod plus the player's own forearm and hand,
-- pinned to the camera every frame through the shared Viewmodel rig (which
-- owns the sway, bob and breathing so the fists move the same way). Nobody
-- else sees it; they see the welded world rod in third person.
--
-- The rod is built fresh from its data row (the server stamps the equipped
-- rod's id on the welded model) rather than cloned from the welded copy:
-- the welded copy is already rotated into the hanging-hand pose, and undoing
-- that is more fragile than starting from the upright template. It shows
-- for exactly as long as the welded `EquippedRod` exists in the character -
-- the server removes that when fists are equipped, so nothing here needs to
-- know about the loadout.
--
-- Also tracks the rod tip's live world position (grip + the rod's authored
-- length along its own +Y) and exposes it via getTipPosition(), so
-- FishingController can pin the fishing line to it without duplicating any
-- of this pose math.
--
-- Also plays the cast animation: a Blender-authored clip
-- (assets/rod_cast_anim.py -> Shared/Data/RodCastAnim.luau) of camera-space
-- transforms that swing the whole viewmodel - rod, hand and forearm - about
-- the elbow. FishingController calls playCast() on the click; the clip's
-- last frame is then held (rod lowered, line out) until releaseCast() eases
-- it back to idle.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rods = require(Shared.Data.Rods)
local RodCastAnim = require(Shared.Data.RodCastAnim)
local RodModel = require(Shared.Modules.RodModel)

local Viewmodel = require(script.Parent.Parent.Modules.Viewmodel)

local player = Players.LocalPlayer

local RodViewmodelController = {}

-- Must match RodService.EQUIPPED_NAME; not required across the boundary
-- because server modules aren't replicated.
local EQUIPPED_NAME = "EquippedRod"

-- Everything in this rig swings together under the cast clip.
local GROUP = "arm"

-- ---------------------------------------------------------------- pose
-- All relative to the camera: +X right, +Y up, -Z forward. These are the
-- knobs to turn when the rod doesn't sit right on screen.

-- Where the grip centre sits in view: right of centre, below eye level, far
-- enough forward that the grip doesn't fill the corner of the screen.
local GRIP_POSITION = Vector3.new(1.45, -1.6, -2.6)

-- Rod direction. Pitch is elevation above the horizon (90 = straight up);
-- yaw swings the tip in toward the centre of the screen. 58 keeps the tip
-- just inside the top of a 70-degree field of view so the whole rod reads.
-- Yaw is kept small so the tip sits to the right along with the grip
-- instead of leaning back over the middle of the view.
local ROD_PITCH = math.rad(58)
local ROD_YAW = math.rad(3)

-- Which way the forearm runs, elbow to fist. Comes in from the bottom-right
-- corner of the screen and rises to the grip; flatter than the rod so the
-- two read as a fist holding a stick rather than one straight line.
local FOREARM_DIRECTION = Vector3.new(-0.25, 0.55, -0.8).Unit

-- Cast animation. The clip itself lives in RodCastAnim (generated from
-- Blender); this is how long the rod takes to ease back to idle once the
-- cast ends, since the clip holds its final pose rather than returning.
local CAST_RELEASE_BLEND = 0.3

-- ---------------------------------------------------------------- state

local rig = nil -- Viewmodel rig while a rod is equipped

-- The rod tip, in the same camera-space/world-space split as the rig's
-- parts: tipOffset is fixed at build time, tipWorld is refreshed every
-- render step alongside the rest of the rig. FishingController reads
-- tipWorld through getTipPosition() to anchor the fishing line.
local tipOffset: CFrame? = nil
local tipWorld: CFrame? = nil

-- Whether the rod's baked-in idle line + bobber are showing. Remembered
-- here (not just applied) so a viewmodel rebuilt mid-cast comes back in the
-- right state.
local tackleVisible = true

-- Cast animation playback. The clip is applied about castPivot (the elbow,
-- in camera space - set properly at build). castStartedAt is set while the
-- clip is playing or holding its last frame; castRelease while it eases
-- back to idle afterwards.
local castPivot: CFrame = CFrame.new(GRIP_POSITION)
local castStartedAt: number? = nil
local castRelease: { from: CFrame, startedAt: number }? = nil

local CAST_FRAMES = Viewmodel.loadClip(RodCastAnim.FRAMES)

local function clearViewmodel()
	if rig then
		rig:destroy()
		rig = nil
	end
	tipOffset = nil
	tipWorld = nil
end

-- ---------------------------------------------------------------- build

-- The grip CFrame in camera space. Authored rod axis is +Y, so we build a
-- frame whose Y points where we want the rod to point: start upright, lean
-- it forward by (90 - pitch), then yaw it in.
local function gripInCameraSpace(): CFrame
	local direction = CFrame.Angles(0, ROD_YAW, 0) * CFrame.Angles(ROD_PITCH - math.rad(90), 0, 0)
	return CFrame.new(GRIP_POSITION) * direction
end

local function buildViewmodel(character: Model, rodData)
	clearViewmodel()

	local newRig = Viewmodel.newRig("RodViewmodel")

	-- Rod: fresh from the template, every part placed relative to the grip's
	-- full CFrame so the authored +Y axis is what gets pitched and yawed.
	local rod = RodModel.build(rodData)
	local grip = RodModel.findGrip(rod)
	if not grip then
		warn("[RodViewmodel] rod has no Rod_Grip part")
		rod:Destroy()
		newRig:destroy()
		return
	end

	local gripCamera = gripInCameraSpace()
	local gripLocal = grip.CFrame
	rod.Parent = newRig.model
	for _, part in rod:GetDescendants() do
		if part:IsA("BasePart") then
			Viewmodel.stripPart(part)
			newRig:add(part, gripCamera * gripLocal:ToObjectSpace(part.CFrame), GROUP)
		end
	end
	RodModel.setTackleVisible(rod, tackleVisible)

	-- Tip: the same authored +Y axis as the grip, walked forward from the
	-- grip to the butt-to-tip length. Both numbers are on the data row so
	-- this stays correct if a future rod's proportions differ from the twig.
	tipOffset = gripCamera * CFrame.new(0, rodData.model.length - rodData.model.grip, 0)

	-- Arm: a block hand + forearm in the player's skin colour, hand closed
	-- on the grip, arm running back along FOREARM_DIRECTION.
	local arm = Viewmodel.buildArm(newRig, character, "Right", GROUP, GRIP_POSITION, FOREARM_DIRECTION)

	-- Cast pivot: the elbow, so a cast swings the arm and the rod together.
	castPivot = CFrame.new(arm.elbow)

	rig = newRig
	newRig:setVisible(true)
end

-- ---------------------------------------------------------------- cast animation

-- The clip at `t` seconds in. Holds the last frame past the end - that's
-- the fishing pose while the line is out.
local function sampleCast(t: number): CFrame
	return Viewmodel.sampleClip(CAST_FRAMES, RodCastAnim.FPS, t)
end

-- This frame's cast transform in camera space: identity when idle, the clip
-- while casting or holding, and an ease back to identity after release.
-- Applied about the elbow so the hand swings with the rod instead of the
-- rod turning inside a fixed fist.
local function castOffset(now: number): CFrame
	local anim
	if castStartedAt then
		anim = sampleCast(now - castStartedAt)
	elseif castRelease then
		local alpha = math.clamp((now - castRelease.startedAt) / CAST_RELEASE_BLEND, 0, 1)
		alpha = 1 - (1 - alpha) ^ 2 -- ease out
		anim = castRelease.from:Lerp(CFrame.identity, alpha)
		if alpha >= 1 then
			castRelease = nil
		end
	else
		return CFrame.identity
	end
	return castPivot * anim * castPivot:Inverse()
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
		tipWorld = nil
		return
	end
	rig:setVisible(true)

	local cast = castOffset(os.clock())
	rig:pin(pin, { [GROUP] = cast })

	if tipOffset then
		tipWorld = pin * cast * tipOffset
	end
end

-- The rod tip's current world position, or nil when no viewmodel is showing
-- (third person, no rod equipped, character not loaded yet). FishingController
-- treats a nil here as "leave the line where it last was".
function RodViewmodelController.getTipPosition(): Vector3?
	return tipWorld and tipWorld.Position
end

-- Show or hide the idle line + bobber that hang off the rod mesh.
-- FishingController turns them off while a cast is out (it draws the real
-- line to the water) and back on when the cast ends.
function RodViewmodelController.setTackleVisible(visible: boolean)
	tackleVisible = visible
	if rig then
		RodModel.setTackleVisible(rig.model, visible)
	end
end

-- Start the cast clip from the top. Safe to call while one is already
-- playing - it just restarts. The last frame holds until releaseCast().
function RodViewmodelController.playCast()
	castStartedAt = os.clock()
	castRelease = nil
end

-- Ease from wherever the cast pose currently is back to idle. No-op if
-- nothing is playing.
function RodViewmodelController.releaseCast()
	if not castStartedAt then
		return
	end
	local now = os.clock()
	castRelease = { from = sampleCast(now - castStartedAt), startedAt = now }
	castStartedAt = nil
end

-- ---------------------------------------------------------------- lifecycle

-- The server's welded rod must not draw for the owner: in first person
-- Roblox hides it anyway, but a transparency override makes that explicit
-- and covers the frames before the camera settles.
local function hideWorldRod(worldRod: Model)
	for _, part in worldRod:GetDescendants() do
		if part:IsA("BasePart") then
			part.LocalTransparencyModifier = 1
		end
	end
end

-- The rod row currently welded into the character (nil when fists are out),
-- and whether the character's arms are ready to clone - the player's real
-- hands, skin and all, only exist once the avatar has loaded (see
-- Viewmodel.watchArms). The rig is (re)built whenever both are true.
local currentRodData = nil
local armsReady = false
local armsWatch: RBXScriptConnection? = nil

local function watchCharacter(character: Model)
	clearViewmodel()
	currentRodData = nil
	armsReady = false
	if armsWatch then
		armsWatch:Disconnect()
	end

	local function rebuild()
		if currentRodData and armsReady and character:FindFirstChild(EQUIPPED_NAME) then
			buildViewmodel(character, currentRodData)
		end
	end

	armsWatch = Viewmodel.watchArms(character, function()
		if player.Character ~= character then
			return
		end
		armsReady = true
		rebuild()
	end)

	local function onRod(worldRod: Instance)
		if worldRod.Name ~= EQUIPPED_NAME or not worldRod:IsA("Model") then
			return
		end
		hideWorldRod(worldRod)

		local rodId = worldRod:GetAttribute("RodId")
		local rodData = rodId and Rods.items[rodId]
		if not rodData then
			warn(string.format("[RodViewmodel] equipped rod has unknown id %s", tostring(rodId)))
			return
		end

		currentRodData = rodData
		rebuild()
	end

	character.ChildAdded:Connect(onRod)
	character.ChildRemoved:Connect(function(child)
		if child.Name == EQUIPPED_NAME then
			currentRodData = nil
			clearViewmodel()
		end
	end)

	local existing = character:FindFirstChild(EQUIPPED_NAME)
	if existing then
		onRod(existing)
	end
end

function RodViewmodelController.init()
	player.CharacterAdded:Connect(watchCharacter)
	if player.Character then
		watchCharacter(player.Character)
	end
end

function RodViewmodelController.start()
	RunService:BindToRenderStep("RodViewmodel", Enum.RenderPriority.Camera.Value + 2, onRenderStep)
end

return RodViewmodelController
