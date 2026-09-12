--!nonstrict
-- BossCutsceneController.luau
-- Owns one boss intro cinematic at a time: the run, the frozen character, the
-- hidden HUD, the letterbox and the skip prompt. The cinematic ITSELF is not
-- here - a per-boss module under Client/Cutscenes/ registers everything against
-- a CutsceneKit (src/Client/Modules/CutsceneKit.luau) and this steps that kit.
--
-- THE HANDSHAKE. The server fires `BossIntro { kind = "start" }` to every party
-- member at the summon and holds the real rise back until `duration - riseTime`
-- (BossService), then fires `{ kind = "raise" }` when the boss actually
-- surfaces. So the genuine rise - the same one CreatureService has always
-- played - IS the cinematic's last beat, and the blend back to the player's own
-- camera happens over the final 0.8 s while the boss is still climbing out of
-- the sea. A boss with no BossCutscenes row never fires either remote and every
-- one of these paths stays cold.
--
-- WHAT THIS FILE REFUSES TO DO IS FAIL LOUDLY. A missing script module, a
-- script that errors on registration, a boss id that is not in Bosses - each of
-- those warns and leaves the player in an ordinary fight. A cinematic is
-- garnish; it must never be the reason someone cannot play.
--
-- ORDER (init.client.luau): after CombatVfxController (the shake is routed
-- through its kick), after BossHudController (whose rise card this suppresses),
-- and after WeatherController (the arrival ambience lands under the cinematic).

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local Bosses = require(Shared.Data.Bosses)
local BossCutscenes = require(Shared.Data.BossCutscenes)

local Theme = require(script.Parent.Parent.UI.Theme)
local CutsceneKit = require(script.Parent.Parent.Modules.CutsceneKit)
local CameraController = require(script.Parent.CameraController)

local BossCutsceneController = {}

local player = Players.LocalPlayer

-- The attribute BossHudController reads to stand its "rises from the deep"
-- card down: the cinematic shows its own title card on the same beat, and two
-- cards on one roar is the bug this replaces.
local ATTR_ACTIVE = "BossCutscene"

local GUI_NAME = "BossCutsceneGui"
local LETTERBOX_SCALE = 0.11 -- bar height, fraction of the screen, each end
local LETTERBOX_TIME = 0.5
local BLEND_OUT = 0.8 -- seconds of camera blend back to the player's own frame
local SKIP_PROMPT_AT = 2.0 -- seconds before the prompt appears
local SKIP_HOLD = 1.0 -- seconds of hold that actually skips
local SKIP_ACTION = "BossCutsceneSkip"

-- How far from the arena centre counts as "left the cinematic". The party is
-- dropped inside `arena.radius + 8` and a cutscene camera is nowhere near the
-- character, so this is deliberately generous - it exists to catch a player
-- teleported somewhere else entirely (an admin, a travel menu), not to police
-- walking.
local LEAVE_RADIUS = 2000
-- Seconds the deferred drop-in may take before a player still on their island
-- is treated as never coming (a teleport that failed, or a spectator on the
-- Maelstrom who wandered off).
local ARRIVE_GRACE = 6

-- The boss model never appearing this long after the expected raise means the
-- server's raise failed (an unknown creature row - BossService warns and clears
-- the fight). End cleanly rather than hold the camera on an empty sea forever.
local NO_BOSS_GRACE = 8

local run: any = nil
local gui: ScreenGui? = nil
local topBar: Frame? = nil
local bottomBar: Frame? = nil
local skipLabel: TextLabel? = nil
local skipFill: Frame? = nil
local warnedOverride = false

-- ============================================================ the letterbox

local function buildGui()
	if gui and gui.Parent then
		return
	end
	local g = Instance.new("ScreenGui")
	g.Name = GUI_NAME
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true
	g.DisplayOrder = 100 -- over the kit's own gui (90), which is over the HUD
	g.Parent = player:WaitForChild("PlayerGui")

	local top = Instance.new("Frame")
	top.Name = "TopBar"
	top.BackgroundColor3 = Color3.new(0, 0, 0)
	top.BorderSizePixel = 0
	top.Size = UDim2.fromScale(1, 0)
	top.Parent = g

	local bottom = top:Clone()
	bottom.Name = "BottomBar"
	bottom.AnchorPoint = Vector2.new(0, 1)
	bottom.Position = UDim2.fromScale(0, 1)
	bottom.Parent = g

	-- Bottom right, inside the bar so it reads as part of the frame rather than
	-- as HUD (which is all hidden by now anyway).
	local label = Instance.new("TextLabel")
	label.Name = "SkipPrompt"
	label.AnchorPoint = Vector2.new(1, 1)
	label.Position = UDim2.new(1, -24, 1, -20)
	label.Size = UDim2.fromOffset(230, 26)
	label.BackgroundTransparency = 1
	label.Font = Theme.Font.body
	label.TextSize = Theme.Size.body
	label.TextXAlignment = Enum.TextXAlignment.Right
	label.TextColor3 = Theme.Color.text
	label.TextStrokeColor3 = Theme.Color.ink
	label.TextStrokeTransparency = 0.2
	label.TextTransparency = 1
	label.Text = "Hold SPACE to skip"
	label.Parent = g

	-- The hold's own progress, so a 1-second hold is a thing you can watch fill
	-- rather than a second of nothing happening.
	local track = Instance.new("Frame")
	track.Name = "SkipTrack"
	track.AnchorPoint = Vector2.new(1, 1)
	track.Position = UDim2.new(1, -24, 1, -14)
	track.Size = UDim2.fromOffset(230, 3)
	track.BackgroundColor3 = Theme.Color.ink
	track.BackgroundTransparency = 0.5
	track.BorderSizePixel = 0
	track.Visible = false
	track.Parent = g

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.AnchorPoint = Vector2.new(1, 0)
	fill.Position = UDim2.fromScale(1, 0)
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = Theme.Color.gold
	fill.BorderSizePixel = 0
	fill.Parent = track

	gui, topBar, bottomBar, skipLabel, skipFill = g, top, bottom, label, fill
end

local function letterbox(inward: boolean)
	if not topBar or not bottomBar then
		return
	end
	local height = if inward then LETTERBOX_SCALE else 0
	local info = TweenInfo.new(LETTERBOX_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(topBar, info, { Size = UDim2.fromScale(1, height) }):Play()
	TweenService:Create(bottomBar, info, { Size = UDim2.fromScale(1, height) }):Play()
end

-- ============================================================ HUD + freeze

-- Every ScreenGui the player owns goes dark for the run except CreatureFxGui
-- (which is where the fight's own world-space markers live - hiding it would
-- hide the boss's telegraphs the instant the fight starts) and the two guis
-- this cinematic draws itself. The PREVIOUS value is what gets restored, not
-- `true`: several of these are already false and turning them on afterwards
-- would open menus nobody opened.
local function hideHud(): { [ScreenGui]: boolean }
	local previous: { [ScreenGui]: boolean } = {}
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return previous
	end
	for _, child in playerGui:GetChildren() do
		if
			child:IsA("ScreenGui")
			and child.Name ~= "CreatureFxGui"
			and child.Name ~= GUI_NAME
			and child.Name ~= CutsceneKit.GUI_NAME
		then
			previous[child] = child.Enabled
			child.Enabled = false
		end
	end
	return previous
end

local function restoreHud(previous)
	for screen, enabled in previous or {} do
		if screen.Parent then
			screen.Enabled = enabled
		end
	end
end

-- Freeze by speed, never by Anchored: an anchored character does not fall when
-- the fight starts under it, does not seat, and cannot be un-anchored safely if
-- the humanoid died in between.
local function freeze(): any
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end
	local saved = {
		humanoid = humanoid,
		walkSpeed = humanoid.WalkSpeed,
		jumpPower = humanoid.JumpPower,
		jumpHeight = humanoid.JumpHeight,
	}
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid.JumpHeight = 0
	return saved
end

local function unfreeze(saved)
	if not saved or not saved.humanoid or not saved.humanoid.Parent then
		return
	end
	saved.humanoid.WalkSpeed = saved.walkSpeed
	saved.humanoid.JumpPower = saved.jumpPower
	saved.humanoid.JumpHeight = saved.jumpHeight
end

-- ============================================================ teardown

local function stop()
	local current = run
	if not current then
		return
	end
	run = nil

	if CameraController.setOverride then
		CameraController.setOverride(nil)
	end
	ContextActionService:UnbindAction(SKIP_ACTION)
	for _, conn in current.conns do
		conn:Disconnect()
	end
	if current.kit then
		pcall(function()
			current.kit:finish()
		end)
	end
	unfreeze(current.frozen)
	restoreHud(current.hidden)
	player:SetAttribute(ATTR_ACTIVE, nil)
	letterbox(false)
	if skipLabel then
		skipLabel.TextTransparency = 1
	end
	if skipFill then
		skipFill.Size = UDim2.fromScale(0, 1)
		local track = skipFill.Parent
		if track then
			(track :: Frame).Visible = false
		end
	end
end

-- ============================================================ the frame

-- Runs on RenderStepped, i.e. BEFORE CameraController's own bind (Camera + 1),
-- so the frame this computes is already waiting when the override is asked for
-- it. Splitting them that way also means a missing `setOverride` costs the
-- cinematic its camera and nothing else - the actors, sound and title card all
-- still play.
local function onRenderStep(dt: number)
	local current = run
	if not current then
		return
	end
	local now = Workspace:GetServerTimeNow()
	-- TIMELINE time, not wall time: a skip jumps the run forward by adding to
	-- `offset`, and every deadline below (the prompt, the handoff, the end) is
	-- written in the same coordinates the script's own `t` is.
	local t = (now - current.startsAt) + current.offset

	-- Cancel paths, cheapest first.
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		stop()
		return
	end
	-- ...but only once the player has ARRIVED. BossService fires "start" in
	-- the same frame it defers the party's teleport, so the first render steps
	-- run with the character still on their island, thousands of studs from
	-- the lair: the far-away test would cancel every intro on its first frame.
	-- The rule is therefore "was inside once, then left", with a grace for a
	-- teleport that never comes.
	local root = character:FindFirstChild("HumanoidRootPart")
	if root then
		local far = (root.Position - current.center).Magnitude > LEAVE_RADIUS
		if not far then
			current.arrived = true
		elseif current.arrived or t > ARRIVE_GRACE then
			stop()
			return
		end
	end
	-- The raise failed server-side (BossService warns on an unknown creature
	-- row) - there is no boss coming, so stop looking at where it isn't.
	if not current.sawBoss and t > current.raiseAt + NO_BOSS_GRACE then
		stop()
		return
	end

	local ok, frame = pcall(function()
		return current.kit:step(now, dt)
	end)
	if not ok then
		warn("[BossCutscene] step failed: " .. tostring(frame))
		stop()
		return
	end
	current.frame = frame

	-- The skip prompt, and the hold that spends it.
	if skipLabel then
		local wanted = if t >= SKIP_PROMPT_AT and not current.skipped then 0 else 1
		skipLabel.TextTransparency = skipLabel.TextTransparency + (wanted - skipLabel.TextTransparency) * 0.15
	end
	if current.holdFrom then
		local held = math.clamp((os.clock() - current.holdFrom) / SKIP_HOLD, 0, 1)
		if skipFill then
			skipFill.Size = UDim2.fromScale(held, 1)
			local track = skipFill.Parent
			if track then
				(track :: Frame).Visible = true
			end
		end
		if held >= 1 then
			current.holdFrom = nil
			BossCutsceneController.skip()
		end
	end

	if t >= current.endsAt then
		stop()
	end
end

-- The override CameraController calls with the frame its own pipeline just
-- computed. Returning `normal` unchanged is always safe, which is what every
-- guard here does.
local function cameraOverride(normal: CFrame, _dt: number): CFrame
	local current = run
	if not current or typeof(current.frame) ~= "CFrame" then
		return normal
	end
	local t = (Workspace:GetServerTimeNow() - current.startsAt) + current.offset
	local blendStart = current.endsAt - BLEND_OUT
	if t <= blendStart then
		return current.frame
	end
	-- The handoff: ease from the last cinematic frame to the player's own over
	-- BLEND_OUT, so the fight opens on the camera the player will be flying.
	local u = math.clamp((t - blendStart) / BLEND_OUT, 0, 1)
	return (current.frame :: CFrame):Lerp(normal, u * u * (3 - 2 * u))
end

-- ============================================================ skip

function BossCutsceneController.skip()
	local current = run
	if not current or current.skipped then
		return
	end
	current.skipped = true
	-- Tell the server first: when EVERY participant still in the game has
	-- skipped, it raises the boss now instead of at the scheduled moment, and
	-- the "raise" payload that follows re-anchors this timeline again.
	Remotes.BossIntroSkip:FireServer()
	-- The jump target is the handoff the SCRIPT registered against
	-- (`duration - riseTime`), not wherever the raise ends up landing: its
	-- `kit.at` calls are pinned to that number, and fast-forwarding to anything
	-- else would step over them. The controller's own clock jumps with the
	-- kit's, or the two would disagree about when this run ends.
	local target = current.raiseAt
	local t = (Workspace:GetServerTimeNow() - current.startsAt) + current.offset
	if target > t then
		current.offset += target - t
	end
	pcall(function()
		current.kit:fastForward(target)
	end)
	if skipLabel then
		skipLabel.TextTransparency = 1
	end
end

local function onSkipAction(_name: string, state: Enum.UserInputState)
	local current = run
	if not current then
		return Enum.ContextActionResult.Pass
	end
	if state == Enum.UserInputState.Begin then
		current.holdFrom = os.clock()
	else
		current.holdFrom = nil
		if skipFill then
			skipFill.Size = UDim2.fromScale(0, 1)
		end
	end
	return Enum.ContextActionResult.Sink
end

-- ============================================================ starting a run

local function beginRun(payload)
	local boss = Bosses.items[payload.bossId]
	local cutscene = BossCutscenes.items[payload.bossId]
	if not boss or not cutscene then
		return
	end
	local module = script.Parent.Parent:FindFirstChild("Cutscenes")
	module = module and module:FindFirstChild(cutscene.script)
	if not module then
		warn(
			string.format(
				"[BossCutscene] %s names cutscene script %q, which is not in Client/Cutscenes - no intro.",
				payload.bossId,
				cutscene.script
			)
		)
		return
	end
	local okRequire, scriptFn = pcall(require, module)
	if not okRequire or type(scriptFn) ~= "function" then
		warn(string.format("[BossCutscene] %s failed to load: %s", cutscene.script, tostring(scriptFn)))
		return
	end

	local center = if typeof(payload.center) == "Vector3" then payload.center else Vector3.zero
	local duration = payload.duration or cutscene.duration
	local riseTime = boss.riseTime or 4
	local kit = CutsceneKit.new({
		bossId = payload.bossId,
		boss = boss,
		islandId = payload.islandId,
		center = center,
		duration = duration,
		riseTime = riseTime,
		startsAt = payload.startsAt,
	})

	local current = {
		bossId = payload.bossId,
		kit = kit,
		startsAt = payload.startsAt,
		duration = duration,
		riseTime = riseTime,
		raiseAt = math.max(0, duration - riseTime),
		endsAt = duration,
		offset = 0,
		center = center,
		conns = {},
		frozen = freeze(),
		hidden = hideHud(),
		sawBoss = false,
		arrived = false,
		skipped = false,
		frame = nil,
		holdFrom = nil,
	}
	run = current

	kit.onRealBoss(function()
		current.sawBoss = true
	end)

	buildGui()
	letterbox(true)
	player:SetAttribute(ATTR_ACTIVE, true)

	-- A respawn mid-cinematic ends it: the character this froze is gone, so the
	-- freeze is already undone and there is nobody left to hold still.
	table.insert(
		current.conns,
		player.CharacterAdded:Connect(function()
			stop()
		end)
	)

	if CameraController.setOverride then
		CameraController.setOverride(cameraOverride)
	elseif not warnedOverride then
		warnedOverride = true
		warn("[BossCutscene] CameraController.setOverride is missing - the intro plays without its camera.")
	end

	ContextActionService:BindActionAtPriority(
		SKIP_ACTION,
		onSkipAction,
		true, -- a touch button, for the players who have no space bar
		Enum.ContextActionPriority.High.Value,
		Enum.KeyCode.Space,
		Enum.KeyCode.ButtonA
	)

	-- The script registers and returns; everything after this is `step`. An
	-- error in registration leaves a half-built run, so tear it down rather than
	-- fly a camera at nothing.
	local okScript, err = pcall(scriptFn, kit)
	if not okScript then
		warn(string.format("[BossCutscene] %s errored: %s", cutscene.script, tostring(err)))
		stop()
	end
end

local function onBossIntro(payload)
	if type(payload) ~= "table" then
		return
	end
	if payload.kind == "start" then
		-- A second summon for another boss supersedes this one; the same boss
		-- twice is a duplicate and the running one wins.
		if run then
			if run.bossId == payload.bossId then
				return
			end
			stop()
		end
		beginRun(payload)
	elseif payload.kind == "raise" then
		local current = run
		if not current or current.bossId ~= payload.bossId then
			return
		end
		-- Re-anchor the final segment to the raise that ACTUALLY happened. It is
		-- read as "the rise starts NOW" rather than as a number computed from
		-- the payload's own clock, because a skip has already moved this
		-- timeline forward and the two coordinate systems would disagree by
		-- exactly the skip. `endsAt` moves with it, so the blend-out still lands
		-- on the last second of the real rise however early the boss came.
		local t = (Workspace:GetServerTimeNow() - current.startsAt) + current.offset
		current.raiseAt = t
		current.endsAt = t + (payload.riseTime or current.riseTime)
		pcall(function()
			current.kit:setRaiseAt(t)
		end)
	end
end

-- ============================================================ lifecycle

function BossCutsceneController.init()
	Remotes.BossIntro.OnClientEvent:Connect(onBossIntro)
end

function BossCutsceneController.start()
	RunService.RenderStepped:Connect(onRenderStep)
end

return BossCutsceneController
