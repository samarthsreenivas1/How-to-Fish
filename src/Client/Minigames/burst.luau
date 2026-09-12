--!nonstrict
-- Client/Minigames/burst.luau
-- Rapid-tap burst: the client half (view, input, local fill prediction). The
-- window opens on the first tap and lasts `config.duration`; when it ends the
-- client sends the FINISH sentinel (round 0) and the server resolves. Taps
-- carry no echo, so the fill bar shown here is a local prediction - the
-- authoritative tap count lives server-side (Shared/Modules/Minigames/burst)
-- and only decides the grade at resolve.
--
-- Implements the common client contract: onAccepted / update / onResult / endCast.

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BurstMath = require(Shared.Modules.Minigames.burst)
local Tuning = require(Shared.Config.Tuning)

local TapMeter = require(script.Parent.Parent.UI.TapMeter)
local Sfx = require(script.Parent.Parent.Modules.Sfx)

local Burst = {}

local ACTION = "FishingBurstTap"

local view

-- The cast this module is currently running, so a stray scheduled/held input
-- from a finished cast is ignored.
local currentCast = nil

local function ensureView(gui)
	if not view then
		view = TapMeter.new(gui)
	end
	return view
end

local function finish(ctx)
	local cast = ctx.cast
	if not cast or not cast.mg or cast.mg.finished then
		return
	end
	cast.mg.finished = true
	cast.finished = true -- stop update/input; CastResolved will call endCast
	-- Resolve on the server; the normal cast timeout is the backstop if lost.
	ctx.submit(BurstMath.FINISH, os.clock() - cast.startedAt)
end

local function registerTap(ctx)
	local cast = ctx.cast
	if not cast or cast.finished or currentCast ~= cast or not cast.mg or cast.mg.finished then
		return
	end

	local now = os.clock()
	if cast.mg.firstTapAt == nil then
		cast.mg.firstTapAt = now
		cast.mg.lastCountedAt = -math.huge
	end

	-- Predict the fill locally, mirroring the server exactly: a tap counts only
	-- inside the window AND no faster than MAX_TAPS_PER_SEC, so the bar filling
	-- up here lines up with the server's authoritative count.
	local minInterval = 1 / Tuning.Minigames.Burst.MAX_TAPS_PER_SEC
	if now - cast.mg.firstTapAt <= cast.config.duration and (now - cast.mg.lastCountedAt) >= minInterval then
		cast.mg.taps += 1
		cast.mg.lastCountedAt = now
		view:setFill(cast.mg.taps / cast.config.target)
		-- Only a COUNTED tap gets a sound. Mashing past MAX_TAPS_PER_SEC still
		-- pulses the meter, but those taps buy nothing server-side, and letting
		-- them click anyway would teach the player that faster is always better.
		Sfx.play("burstTap")
	end
	view:pulse()

	cast.mg.ordinal += 1
	ctx.submit(cast.mg.ordinal, now - cast.startedAt)

	-- Filled the bar: finish now rather than making them mash out the timer.
	-- (The tap submit above is sent before FINISH, so the server counts it.)
	if cast.mg.taps >= cast.config.target then
		Sfx.play("burstFill")
		finish(ctx)
	end
end

function Burst.onAccepted(ctx)
	local cast = ctx.cast
	cast.mg = { taps = 0, ordinal = 0, firstTapAt = nil, finished = false, openedAt = os.clock() }
	currentCast = cast

	ensureView(ctx.gui)
	view:reset()
	view:show()
	Sfx.play("burstOpen")

	ContextActionService:BindActionAtPriority(
		ACTION,
		function(_, state)
			if state == Enum.UserInputState.Begin then
				registerTap(ctx)
			end
			return Enum.ContextActionResult.Sink
		end,
		false,
		Enum.ContextActionPriority.High.Value,
		Enum.KeyCode.Space,
		Enum.UserInputType.MouseButton1,
		Enum.UserInputType.Touch
	)
end

function Burst.update(ctx)
	local cast = ctx.cast
	if not view or not cast or cast.finished or not cast.mg or cast.mg.finished then
		return
	end

	local now = os.clock()
	if cast.mg.firstTapAt then
		local left = cast.config.duration - (now - cast.mg.firstTapAt)
		view:setTime(left / cast.config.duration)
		if left <= 0 then
			-- The window closed short of target - the fill path always finishes
			-- the instant the bar is full, so reaching the timer at all means it
			-- wasn't filled.
			Sfx.play("burstFail")
			finish(ctx)
		end
	else
		-- No tap yet: hold a full timer, but don't wait forever if they never mash.
		view:setTime(1)
		if now - cast.mg.openedAt > Tuning.Minigames.Burst.OPEN_TIMEOUT then
			-- Never tapped once: the same failure, and the one that would
			-- otherwise resolve in complete silence.
			Sfx.play("burstFail")
			finish(ctx)
		end
	end
end

-- Burst taps carry no server echo, so there's nothing to reconcile.
function Burst.onResult(_ctx, _round, _kind) end

function Burst.endCast(_ctx)
	if view then
		view:hide()
	end
	ContextActionService:UnbindAction(ACTION)
	currentCast = nil
end

return Burst
