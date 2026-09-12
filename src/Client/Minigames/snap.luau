--!nonstrict
-- Client/Minigames/snap.luau
-- Whack-a-mole tap-targets: the client half (view, input, target timing). One
-- target appears at a seed-derived spot (SnapMath.positionFor), shrinks over
-- `config.lifetime`, and you tap/click it before it's gone; `config.count`
-- targets in a row. Each answer submits (round, elapsed, hit) — 1 if caught in
-- time, 0 if it timed out — and the server counts hits. The last answer
-- resolves the cast.
--
-- Mobile-first: taps work natively on touch. On desktop the game is
-- first-person mouse-locked, so this frees the cursor for the duration
-- (CameraController.setCursorFree) and re-locks it in endCast.
--
-- Implements the common client contract: onAccepted / update / onResult / endCast.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SnapMath = require(Shared.Modules.Minigames.snap)

local SnapTargets = require(script.Parent.Parent.UI.SnapTargets)
local CameraController = require(script.Parent.Parent.Controllers.CameraController)
local Sfx = require(script.Parent.Parent.Modules.Sfx)

local Snap = {}

local PROMPT = "TAP THE TARGETS!"

-- Fallbacks so a missing/stale config field can never make update or advance
-- error (which would freeze the minigame: no shrink, no new target). They
-- match Tuning.Minigames.Snap and are only used if the config somehow lacks
-- the field.
local DEFAULT_COUNT = 5
local DEFAULT_LIFETIME = 1.5

local view
local currentCast = nil

local function countOf(cast): number
	return cast.config.count or DEFAULT_COUNT
end

local function lifetimeOf(cast): number
	return cast.config.lifetime or DEFAULT_LIFETIME
end

local function ensureView(gui)
	if not view then
		view = SnapTargets.new(gui)
	end
	return view
end

local function advance(ctx)
	local cast = ctx.cast
	cast.mg.round += 1
	cast.mg.answered = false
	cast.mg.openedAt = os.clock()
	if cast.mg.round > countOf(cast) then
		cast.finished = true -- server resolves off the last submit
		view:hideTarget()
	else
		view:setTarget(SnapMath.positionFor(cast.seed, cast.mg.round))
		Sfx.play("snapAppear")
	end
end

local function click(ctx)
	local cast = ctx.cast
	if not cast or cast.finished or currentCast ~= cast or not cast.mg or cast.mg.answered then
		return
	end
	cast.mg.answered = true
	view:pop(true)
	Sfx.play("snapHit")
	ctx.submit(cast.mg.round, os.clock() - cast.startedAt, SnapMath.HIT)
	advance(ctx)
end

function Snap.onAccepted(ctx)
	local cast = ctx.cast
	cast.mg = { round = 1, answered = false, openedAt = os.clock() }
	currentCast = cast

	ensureView(ctx.gui)
	view:setPrompt(PROMPT)
	view:bindTap(function()
		click(ctx)
	end)
	view:setTarget(SnapMath.positionFor(cast.seed, 1))
	view:show()
	-- The first target doesn't come through advance(), so it needs its own
	-- appear tick or target one of five would be the silent one.
	Sfx.play("snapAppear")

	-- Free the cursor so desktop can click the targets (touch taps regardless);
	-- re-locked in endCast.
	CameraController.setCursorFree(true)
end

function Snap.update(ctx)
	local cast = ctx.cast
	if not view or not cast or cast.finished or not cast.mg or cast.mg.answered then
		return
	end
	local lifetime = lifetimeOf(cast)
	local left = lifetime - (os.clock() - cast.mg.openedAt)
	view:setTime(left / lifetime)
	if left <= 0 then
		-- Too slow: the target's gone. A miss, on to the next.
		cast.mg.answered = true
		view:pop(false)
		Sfx.play("snapMiss")
		ctx.submit(cast.mg.round, os.clock() - cast.startedAt, SnapMath.MISS)
		advance(ctx)
	end
end

-- No server echo (client owns the hit/miss call), so nothing to reconcile.
function Snap.onResult(_ctx, _round, _kind) end

function Snap.endCast(_ctx)
	if view then
		view:hide()
	end
	CameraController.setCursorFree(false)
	currentCast = nil
end

return Snap
