--!nonstrict
-- CharacterSoundController.luau
-- Every sound a CHARACTER makes - footsteps, jump, land, swimming, being
-- hurt, dying, coming back - driven from the Humanoid itself and played
-- through our own pack (Sfx / the `sfx_character` sheet in the audio
-- contract). Nothing here is a remote: a Humanoid's floor material, move
-- direction and state are all replicated, so every client can hear every
-- character from the same three properties without the server saying a word.
--
-- WHY THIS EXISTS AT ALL: Roblox ships RbxCharacterSounds, a LocalScript
-- that parents its own Running/Jumping/Landing/Swimming/Died Sounds into the
-- character's Head and drives them off the same signals we do. Left alone it
-- plays the stock library footstep UNDER ours, one frame off, and the game
-- sounds like two games. So the first thing this controller does to any
-- character is take those away (see `evictStockSounds`) - our pack REPLACES
-- them, it does not layer on them.
--
-- REMOTE CHARACTERS GET THE SAME TREATMENT. Footsteps are how you notice
-- someone walking up behind you on a dock, so the driver runs for every
-- player's character, not just the local one, and every step is a 3D play at
-- the FOOT position. The cost of that is bounded by a distance cull: a
-- character further than STEP_HEAR_RANGE from the camera is skipped whole
-- (see `update`), which is one squared-magnitude compare per player per
-- frame and no allocation.
--
-- The 2D "this happened TO ME" cues - hurt, the low-health heartbeat, death,
-- respawn - are LOCAL PLAYER ONLY, on purpose: they're feedback, not world
-- sound, and hearing a stranger's heartbeat would be noise.
--
-- SAFE WITH THE PACK ABSENT. Sfx warns once per unknown name and does
-- nothing, so before the SoundPack is imported this controller is silent
-- rather than broken. Everything else here is written for the other absence
-- that actually bites: a character that has no Humanoid yet, a player who
-- leaves mid-connection, a HumanoidRootPart that vanishes under a running
-- loop.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Sfx = require(script.Parent.Parent.Modules.Sfx)

local CharacterSoundController = {}

local localPlayer = Players.LocalPlayer

-- ============================================================ tuning

-- The stock character-sound script and the Sounds it makes. RbxCharacterSounds
-- lives under the local player's PlayerScripts (not the character, and not
-- directly under the Player), while the Sounds it makes are parented to the
-- character's HumanoidRootPart - so the two halves are swept in two places.
local STOCK_SCRIPT = "RbxCharacterSounds"
local STOCK_SOUNDS = {
	Running = true,
	Jumping = true,
	Landing = true,
	Splash = true,
	Swimming = true,
	Climbing = true,
	FreeFalling = true,
	GettingUp = true,
	Died = true,
}
-- It can arrive AFTER the character does (the engine parents it on its own
-- schedule), so the sweep repeats for a moment instead of trusting one pass.
local STOCK_SWEEP_TIME = 3
local STOCK_SWEEP_STEP = 0.25

-- Footsteps. The pack bakes four variants of each footstep in a row
-- (`stepSand1..4`, contract §3 sfx_character: "the registry expands these;
-- the client picks at random"), so the cue we ask for is the base name with a
-- 1..4 suffix - the base name on its own is NOT a key.
local STEP_VARIANTS = 4

-- One stride is about this many studs of ground covered. Cadence comes from
-- the Humanoid's INTENT - MoveDirection.Magnitude (0 when standing, 1 when
-- driving in a direction) scaled by WalkSpeed - rather than from the root
-- part's velocity, so being pushed, carried by a boat or falling doesn't
-- print footsteps, and a sprinter's feet keep up with the sprint.
local STRIDE_STUDS = 4.4
local STEP_MIN_INTERVAL = 0.18
local STEP_MAX_INTERVAL = 0.75
-- Below this much intent the character is drifting into a wall or nudging a
-- stick, not walking.
local MOVE_EPSILON = 0.12

-- The cull. Beyond this the character's footsteps would be inaudible anyway
-- (the 3D cues roll off well inside it), so we don't even ask the Humanoid
-- for its material. Squared so the per-frame check has no square root.
local STEP_HEAR_RANGE = 110
local STEP_HEAR_RANGE_SQ = STEP_HEAR_RANGE * STEP_HEAR_RANGE

-- Swimming strokes are slower and more even than footsteps, and they keep a
-- floor cadence even when the swimmer is treading rather than driving.
local SWIM_INTERVAL = 0.85
local SWIM_IDLE_INTERVAL = 1.8

-- Damage. A hurt above this FRACTION OF MAXHEALTH is the heavy grunt. 18% is
-- chosen against the game's own numbers: ordinary creature contact sits near
-- 8-12% of a full bar, while a boss's telegraphed hit is 20% and up - so the
-- threshold falls in the gap between "chipped" and "that one was aimed at
-- you", and it is a fraction rather than a flat number so it survives every
-- MaxHealth change (upgrades, boss arenas) without retuning.
local HURT_HEAVY_FRACTION = 0.18
-- Anything smaller than this is regen ticks and rounding, not a hit.
local HURT_MIN_FRACTION = 0.01

-- The heartbeat starts below the first fraction and stops above the second.
-- The GAP IS DELIBERATE: with one threshold a character sitting exactly on it
-- while regenerating starts and stops the loop every few frames, which both
-- sounds broken and is the shape of a leaked loop handle.
local LOW_HEALTH_ON = 0.25
local LOW_HEALTH_OFF = 0.32

-- ============================================================ materials

-- Enum.Material -> base cue. Terrain and part materials both land here
-- because FloorMaterial reports either. Anything unlisted falls back to
-- stone: a wrong-but-plausible footstep reads far better than silence.
local MATERIAL_CUE = {
	[Enum.Material.Sand] = "stepSand",
	[Enum.Material.Salt] = "stepSand",
	[Enum.Material.Sandstone] = "stepSand",

	[Enum.Material.Grass] = "stepGrass",
	[Enum.Material.LeafyGrass] = "stepGrass",
	[Enum.Material.Ground] = "stepGrass",

	[Enum.Material.Mud] = "stepMud",

	[Enum.Material.Wood] = "stepWood",
	[Enum.Material.WoodPlanks] = "stepWood",

	[Enum.Material.Snow] = "stepSnow",
	[Enum.Material.Glacier] = "stepSnow",
	[Enum.Material.Ice] = "stepSnow",

	[Enum.Material.Metal] = "stepMetal",
	[Enum.Material.CorrodedMetal] = "stepMetal",
	[Enum.Material.DiamondPlate] = "stepMetal",
	[Enum.Material.Foil] = "stepMetal",

	-- Standing IN terrain water without swimming is wading, which is what
	-- stepShallow is for - the whole shoreline of every island is this.
	[Enum.Material.Water] = "stepShallow",

	[Enum.Material.Rock] = "stepStone",
	[Enum.Material.Basalt] = "stepStone",
	[Enum.Material.Limestone] = "stepStone",
	[Enum.Material.Slate] = "stepStone",
	[Enum.Material.Concrete] = "stepStone",
	[Enum.Material.Brick] = "stepStone",
	[Enum.Material.Cobblestone] = "stepStone",
	[Enum.Material.Pebble] = "stepStone",
	[Enum.Material.Granite] = "stepStone",
	[Enum.Material.Marble] = "stepStone",
	[Enum.Material.Asphalt] = "stepStone",
	[Enum.Material.Pavement] = "stepStone",
	[Enum.Material.CrackedLava] = "stepStone",
}
local MATERIAL_CUE_DEFAULT = "stepStone"

-- ============================================================ state

-- player -> {
--   character, humanoid, root,
--   conns        : Humanoid connections, all dropped on CharacterRemoving
--   stepClock    : seconds until the next footstep
--   swimClock    : seconds until the next stroke
--   swimming     : last known "is in the water" so we can catch the edges
--   lastHealth   : local player only, for the damage delta
--   lowLoop      : local player only, the heartbeat handle we OWN
-- }
local states: { [Player]: any } = {}

-- A player who died at least once; the next character they get is a RESPAWN
-- rather than a first spawn, which is the only way to tell those apart from
-- CharacterAdded alone.
local hasDied = false

local conns: { RBXScriptConnection } = {}

-- ============================================================ stock sounds

-- Takes the engine's own character sounds away. Two halves, because the stock
-- system is two things: the LocalScript under the Player that drives them and
-- the Sounds it has already parented into the Head. Killing only the script
-- leaves whatever it started still playing; killing only the Sounds lets it
-- make new ones on the next state change.
local function evictStockSounds(player: Player, character: Model)
	-- THE SCRIPT LIVES UNDER PlayerScripts, not under the Player. FindFirstChild
	-- on the Player is not recursive, so the old lookup found nothing and the
	-- stock system was never actually stopped - only its Sounds were deleted, a
	-- frame before it made them again. And PlayerScripts exists on the client
	-- only for the LOCAL player, so this half is the local player's alone; the
	-- Sound sweep below still runs for everyone.
	if player == localPlayer then
		local scripts = player:FindFirstChild("PlayerScripts")
		local script_ = scripts and scripts:FindFirstChild(STOCK_SCRIPT)
		if script_ then
			-- Destroy rather than Disabled = true: a LocalScript that has already
			-- started keeps running when disabled, and this one usually has.
			script_:Destroy()
		end
	end

	-- BOTH PARENTS. Current Roblox parents the stock Sounds to the
	-- HumanoidRootPart; older versions used the Head, and a character built
	-- from an older rig still has them there. Sweeping only the Head left every
	-- one of them playing.
	for _, partName in { "HumanoidRootPart", "Head" } do
		local part = character:FindFirstChild(partName)
		if part then
			for _, child in part:GetChildren() do
				if child:IsA("Sound") and STOCK_SOUNDS[child.Name] then
					child:Destroy()
				end
			end
		end
	end
end

-- One sweep now, and then a WATCH rather than a poll. The engine parents the
-- script and the Sounds on its own schedule - routinely a frame or three after
-- the character arrives, and the stock script re-creates a Sound it finds
-- missing - so the old fix was a re-sweep every 250 ms for three seconds, which
-- both let a stock sound be audible for up to a quarter second and gave up
-- after three. DescendantAdded kills each one in the frame it appears and keeps
-- doing so for as long as the character exists; the connection dies with it.
local function evictStockSoundsPersistently(player: Player, character: Model)
	evictStockSounds(player, character)
	character.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("Sound") and STOCK_SOUNDS[descendant.Name] then
			descendant:Destroy()
		end
	end)
	-- The script itself is not a descendant of the character, so it still needs
	-- a moment's watching: it is parented into PlayerScripts asynchronously and
	-- may not be there yet on the frame the character arrives.
	if player == localPlayer then
		task.spawn(function()
			local elapsed = 0
			while elapsed < STOCK_SWEEP_TIME do
				if player.Parent == nil then
					return
				end
				evictStockSounds(player, character)
				task.wait(STOCK_SWEEP_STEP)
				elapsed += STOCK_SWEEP_STEP
			end
		end)
	end
end

-- ============================================================ helpers

-- Where a footstep actually happens: the ground under the root part, not the
-- middle of the torso. HipHeight plus half the root is exactly the gap the
-- Humanoid holds itself above the floor, so this lands on the floor for R6
-- and R15 alike without hunting for foot parts that only one rig has.
local function footPosition(humanoid: Humanoid, root: BasePart): Vector3
	return root.Position - Vector3.new(0, humanoid.HipHeight + root.Size.Y * 0.5, 0)
end

local function stepCue(material: Enum.Material): string
	local base = MATERIAL_CUE[material] or MATERIAL_CUE_DEFAULT
	-- The variant suffix is the client's job (contract §3): four takes of the
	-- same footstep in the sheet, one picked per step so a corridor of them
	-- doesn't sound like a sampler stuck on one key.
	return base .. tostring(math.random(1, STEP_VARIANTS))
end

-- The heartbeat is a 2D cue in the contract, but Sfx.loop is positional-only;
-- parking it on the local character's own head is the same thing in practice
-- (it moves with the listener) and costs nothing to keep there.
local function localHeadPosition(): Vector3?
	local state = states[localPlayer]
	if state and state.root and state.root.Parent then
		return state.root.Position
	end
	return nil
end

local function stopLowHealth(state)
	if state.lowLoop then
		Sfx.stopLoop(state.lowLoop)
		state.lowLoop = nil
	end
end

-- ============================================================ per-character

local function unhook(player: Player)
	local state = states[player]
	if not state then
		return
	end
	for _, conn in state.conns do
		conn:Disconnect()
	end
	table.clear(state.conns)
	-- The loop handle dies with the character it belonged to. This is the one
	-- teardown that MUST happen on every path - a leaked Sfx.loop is audible
	-- forever - which is why it is here, in the single function every path
	-- (respawn, death, leaving, controller teardown) goes through.
	stopLowHealth(state)
	states[player] = nil
end

local function onStateChanged(player: Player, _old: Enum.HumanoidStateType, new: Enum.HumanoidStateType)
	local state = states[player]
	if not state or not state.root or not state.root.Parent then
		return
	end
	local position = state.root.Position

	if new == Enum.HumanoidStateType.Jumping then
		Sfx.play("jump", position)
	elseif new == Enum.HumanoidStateType.Landed then
		Sfx.play("land", position)
	elseif new == Enum.HumanoidStateType.Swimming then
		if not state.swimming then
			state.swimming = true
			state.swimClock = SWIM_INTERVAL
			Sfx.play("waterEnter", position)
		end
	elseif state.swimming then
		-- Any state that is not Swimming ends the swim, including the ones
		-- that mean "the water let go of you" without being a jump: Freefall
		-- off a wave, Landed on the shelf, Running up the beach.
		state.swimming = false
		Sfx.play("waterExit", position)
	end
end

-- Local-player-only feedback. Everything in here is 2D and about YOU.
local function onHealthChanged(state, health: number)
	local humanoid = state.humanoid
	if not humanoid then
		return
	end
	local maxHealth = math.max(1, humanoid.MaxHealth)
	local previous = state.lastHealth or health
	state.lastHealth = health

	local lost = (previous - health) / maxHealth
	if lost > HURT_MIN_FRACTION and health > 0 then
		-- Death has its own cue; a killing blow should not also grunt.
		Sfx.play(if lost >= HURT_HEAVY_FRACTION then "hurtHeavy" else "hurt")
	end

	local fraction = health / maxHealth
	if health <= 0 or fraction > LOW_HEALTH_OFF then
		stopLowHealth(state)
	elseif fraction < LOW_HEALTH_ON and not state.lowLoop and not state.lowRefused then
		local at = localHeadPosition()
		if at then
			state.lowLoop = Sfx.loop("lowHealth", at)
			if not state.lowLoop then
				-- lowHealth is SPRITE-ONLY (Sfx.luau: a built-in body thud held
				-- on a loop is a drone, not a heartbeat), so with no pack this
				-- returns nil - every time, for the whole session. HealthChanged
				-- fires on every regen tick, so retrying it was a Part built and
				-- destroyed several times a second for as long as you were hurt.
				-- Remembered until the character changes; a pack imported
				-- mid-session is picked up on the next respawn.
				state.lowRefused = true
			end
		end
	end
end

local function hookCharacter(player: Player, character: Model)
	-- A respawn arrives as a new character while the old one's connections may
	-- still be live; unhook first so nothing is ever hooked twice and the old
	-- heartbeat loop cannot outlive the body it belonged to.
	unhook(player)

	evictStockSoundsPersistently(player, character)

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		-- WaitForChild rather than giving up: the Humanoid is replicated
		-- separately from the model and is routinely a frame behind it.
		local found = character:WaitForChild("Humanoid", 10)
		if not found or not found:IsA("Humanoid") then
			return
		end
		humanoid = found
	end
	-- The player may have left, or respawned again, during that wait.
	if player.Parent == nil or player.Character ~= character then
		return
	end

	local state = {
		character = character,
		humanoid = humanoid,
		root = humanoid.RootPart or character:FindFirstChild("HumanoidRootPart"),
		conns = {},
		stepClock = 0,
		swimClock = SWIM_INTERVAL,
		swimming = humanoid:GetState() == Enum.HumanoidStateType.Swimming,
		lastHealth = humanoid.Health,
		lowLoop = nil,
		-- Set once if Sfx.loop("lowHealth") comes back nil; see onHealthChanged.
		lowRefused = false,
	}
	states[player] = state

	table.insert(
		state.conns,
		humanoid:GetPropertyChangedSignal("RootPart"):Connect(function()
			state.root = humanoid.RootPart
		end)
	)
	table.insert(
		state.conns,
		humanoid.StateChanged:Connect(function(old, new)
			onStateChanged(player, old, new)
		end)
	)

	if player == localPlayer then
		if hasDied then
			-- A new character after a death: the only place respawn belongs.
			-- A first spawn is not a respawn, hence the flag.
			Sfx.play("respawn")
		end
		table.insert(
			state.conns,
			humanoid.HealthChanged:Connect(function(health)
				onHealthChanged(state, health)
			end)
		)
		table.insert(
			state.conns,
			humanoid.Died:Connect(function()
				hasDied = true
				stopLowHealth(state)
				Sfx.play("death")
			end)
		)
	end
end

-- ============================================================ driver

-- One Heartbeat for every character in the world. Written to allocate
-- nothing per player per frame: the camera position is read once, the cull is
-- a squared compare, and the only Vector3 built is the foot position of a
-- character that is actually taking a step this frame.
local function update(dt: number)
	local camera = Workspace.CurrentCamera
	local listener = if camera then camera.CFrame.Position else nil

	for player, state in states do
		local humanoid = state.humanoid
		local root = state.root
		if not humanoid or humanoid.Parent == nil or not root or root.Parent == nil then
			continue
		end
		if humanoid.Health <= 0 then
			continue
		end

		-- The cull. The local player is never culled (you always hear your own
		-- feet, even in a camera mode that has flown off somewhere).
		if listener and player ~= localPlayer then
			local offset = root.Position - listener
			if offset:Dot(offset) > STEP_HEAR_RANGE_SQ then
				continue
			end
		end

		local intent = math.min(humanoid.MoveDirection.Magnitude, 1)

		if state.swimming then
			-- Strokes keep going while treading water, just slower, so a
			-- floating player isn't silent.
			state.swimClock -= dt
			if state.swimClock <= 0 then
				state.swimClock = if intent > MOVE_EPSILON then SWIM_INTERVAL else SWIM_IDLE_INTERVAL
				Sfx.play("swimStroke", root.Position)
			end
			continue
		end

		local material = humanoid.FloorMaterial
		if material == Enum.Material.Air or intent <= MOVE_EPSILON then
			-- In the air or standing still: reset so the first step after
			-- landing or after starting to walk lands immediately rather than
			-- part-way through a stale stride.
			state.stepClock = 0
			continue
		end

		state.stepClock -= dt
		if state.stepClock > 0 then
			continue
		end

		local speed = intent * math.max(humanoid.WalkSpeed, 1)
		state.stepClock = math.clamp(STRIDE_STUDS / speed, STEP_MIN_INTERVAL, STEP_MAX_INTERVAL)
		Sfx.play(stepCue(material), footPosition(humanoid, root))
	end

	-- Keep the heartbeat on the ears. Cheap and idempotent; moveLoop ignores a
	-- handle that has already been stopped.
	local localState = states[localPlayer]
	if localState and localState.lowLoop then
		local at = localHeadPosition()
		if at then
			Sfx.moveLoop(localState.lowLoop, at)
		end
	end
end

-- ============================================================ players

local function hookPlayer(player: Player)
	table.insert(
		conns,
		player.CharacterAdded:Connect(function(character)
			hookCharacter(player, character)
		end)
	)
	table.insert(
		conns,
		player.CharacterRemoving:Connect(function()
			unhook(player)
		end)
	)
	if player.Character then
		hookCharacter(player, player.Character)
	end
end

-- ============================================================ lifecycle

function CharacterSoundController.init() end

function CharacterSoundController.start()
	for _, player in Players:GetPlayers() do
		hookPlayer(player)
	end
	table.insert(conns, Players.PlayerAdded:Connect(hookPlayer))
	table.insert(
		conns,
		Players.PlayerRemoving:Connect(function(player)
			unhook(player)
		end)
	)
	table.insert(conns, RunService.Heartbeat:Connect(update))
end

-- Not called in normal play, but the controller owns loop handles and per
-- player connections, so it can hand them all back.
function CharacterSoundController.stop()
	for _, conn in conns do
		conn:Disconnect()
	end
	table.clear(conns)
	for player in states do
		unhook(player)
	end
end

return CharacterSoundController
