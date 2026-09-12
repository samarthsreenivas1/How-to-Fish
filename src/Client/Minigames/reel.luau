--!nonstrict
-- Client/Minigames/reel.luau
-- The original reel bar, as a minigame module: the client half (view, input,
-- local prediction). The shared/authority half is Shared/Modules/Minigames/reel.
--
-- Implements the common client minigame contract FishingController drives:
--   onAccepted(ctx)          -- show the view, bind input, first render
--   update(ctx)              -- per-frame: move the marker
--   onResult(ctx, round, kind) -- reconcile the server's regrade
--   endCast(ctx)             -- hide the view, unbind input
--
-- ctx (from FishingController) carries what every minigame needs without
-- knowing the cast internals:
--   ctx.cast            -- the shared cast table (id, seed, config, startedAt, finished, mg)
--   ctx.gui             -- the fishing ScreenGui to build the view under
--   ctx.submit(round, elapsed, extra?)  -- fire SubmitReelClick for this cast
--   ctx.bobberPosition()                -- current bobber world position, or nil
--
-- Client state lives on cast.mg = { round, misses, predicted, zones }, mirroring
-- the server's own cast.mg; the two stay in step through the shared ReelMath and
-- onResult's reconciliation.

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ReelMath = require(Shared.Modules.ReelMath)
local ReelMath_Minigame = require(Shared.Modules.Minigames.reel) -- shared shrink (rod perks)
local World = require(Shared.Config.World)

local ReelBar = require(script.Parent.Parent.UI.ReelBar)
local Vfx = require(script.Parent.Parent.Modules.Vfx)
local Sfx = require(script.Parent.Parent.Modules.Sfx)

local Reel = {}

local ACTION = "FishingReelClick"

-- A hit on the bar tugs the bobber: a little water kicks up.
local TUG_SPLASH = { red = 0.7, green = 0.4 }

-- The bar view, built once on first use and reused every cast.
local bar

-- The creaking-ratchet loop that runs for as long as the bar is up. Module
-- state, not cast state: endCast is the single teardown every exit path
-- (caught, missed out, cancelled, character lost) funnels through, and stopping
-- it there is what keeps a leaked loop - the known failure of this API - out of
-- the session. Stop is idempotent, so the blind call costs nothing.
local tensionLoop: BasePart? = nil

-- Pitch by tension. The marker's sweep IS the tension: it ping-pongs 0..1, so
-- one end of the bar is slack line and the other is the line at full strain,
-- and the ratchet rises and falls with it instead of droning. The range is
-- narrow on purpose - wide enough to hear the sweep, not so wide the loop reads
-- as a different sound at each end.
local TENSION_PITCH_MIN = 0.85
local TENSION_PITCH_MAX = 1.35

local function ensureBar(gui)
	if not bar then
		bar = ReelBar.new(gui)
	end
	return bar
end

local function renderRound(cast)
	-- Same shrink the server will score against (rod forgiveness perks live in
	-- the config), so the zones drawn here are the zones being graded.
	local shrink = ReelMath_Minigame.shrinkFor(cast.config, cast.mg.misses)
	cast.mg.zones = ReelMath.buildZones(cast.seed, cast.mg.round, cast.config, shrink)
	bar:renderZones(cast.mg.zones)
end

local function registerClick(ctx)
	local cast = ctx.cast
	if not cast or cast.finished or not cast.mg then
		return
	end

	local elapsed = os.clock() - cast.startedAt
	local marker = ReelMath.markerAt(elapsed, cast.config.barSpeed)

	-- Grade locally for instant feedback; the server regrades authoritatively.
	local kind = ReelMath.classify(cast.mg.zones, marker)
	bar:flashResult(kind)

	local tug = TUG_SPLASH[kind]
	local pos = ctx.bobberPosition()
	if tug and pos then
		local at = Vector3.new(pos.X, World.WATER_Y + 0.2, pos.Z)
		Vfx.splash(at, tug)
		Sfx.play("tug", at)
	end
	if kind == "grey" then
		Sfx.play("reelMiss")
	end

	ctx.submit(cast.mg.round, elapsed)

	cast.mg.predicted[cast.mg.round] = kind
	if kind == "grey" then
		cast.mg.misses += 1
	end
	cast.mg.round += 1

	if cast.mg.round > cast.config.clicksRequired then
		cast.finished = true
	else
		-- The tick belongs to the zones actually getting tighter, not to every
		-- new round: shrink is a function of the miss count alone, so it only
		-- moves on a miss, and not even then while a rod's freeMisses are being
		-- spent or under noShrink. Comparing the two shrinks is the only way to
		-- tell - a tick on a round that drew the same zones would be a lie about
		-- the difficulty. (renderRound is also called from onResult on a
		-- regrade; that's a resync, not a moment, and stays silent.)
		if
			kind == "grey"
			and ReelMath_Minigame.shrinkFor(cast.config, cast.mg.misses)
				< ReelMath_Minigame.shrinkFor(cast.config, cast.mg.misses - 1)
		then
			Sfx.play("reelZoneShrink")
		end
		renderRound(cast)
	end
end

function Reel.onAccepted(ctx)
	local cast = ctx.cast
	cast.mg = { round = 1, misses = 0, predicted = {}, zones = nil }
	ensureBar(ctx.gui)

	-- Space, a left click, or a tap anywhere all register a click - no
	-- dedicated button, so the mouse stays locked to screen centre.
	ContextActionService:BindActionAtPriority(
		ACTION,
		function(_, state)
			if state == Enum.UserInputState.Begin then
				registerClick(ctx)
			end
			return Enum.ContextActionResult.Sink
		end,
		false,
		Enum.ContextActionPriority.High.Value,
		Enum.KeyCode.Space,
		Enum.UserInputType.MouseButton1,
		Enum.UserInputType.Touch
	)

	bar:show()
	-- The bar's own opening cue, fired HERE rather than by FishingController,
	-- which cannot know which minigame it just handed the cast to: burst and
	-- snap open with theirs, this one opens with the reel's ratchet click.
	Sfx.play("reelOpen")
	renderRound(cast)
end

function Reel.update(ctx)
	local cast = ctx.cast
	if bar and cast and not cast.finished and cast.mg then
		local marker = ReelMath.markerAt(os.clock() - cast.startedAt, cast.config.barSpeed)
		bar:setMarker(marker)

		-- reelTension is a 2D cue but Sfx.loop only builds 3D carriers, so the
		-- carrier is pinned to the camera every frame: at zero distance it plays
		-- flat in your ears, and following the camera keeps it that way when you
		-- look around mid-reel.
		local head = Workspace.CurrentCamera and Workspace.CurrentCamera.CFrame.Position
		if head then
			if not tensionLoop then
				tensionLoop = Sfx.loop("reelTension", head)
			end
			Sfx.moveLoop(tensionLoop, head)
			Sfx.setLoopPitch(tensionLoop, TENSION_PITCH_MIN + (TENSION_PITCH_MAX - TENSION_PITCH_MIN) * marker)
		end
	end
end

function Reel.onResult(ctx, round, kind)
	local cast = ctx.cast
	if not cast or not cast.mg then
		return
	end

	local predicted = cast.mg.predicted[round]
	if predicted == nil or predicted == kind then
		return -- the normal path: local grade matched the server's
	end

	-- Disagreement: the server regraded from its own clock after a delayed
	-- packet. Miss count drives the zone shrink for every remaining round, so
	-- resync it or the two sides would draw/score different future layouts.
	cast.mg.predicted[round] = kind
	local serverMissed = kind == "grey"
	cast.mg.misses = math.max(0, cast.mg.misses + (serverMissed and 1 or -1))

	if not cast.finished then
		renderRound(cast)
	end
end

function Reel.endCast(_ctx)
	-- Every way out of the bar comes through here, so this is where the tension
	-- loop dies - before the view, because a hidden bar still creaking is the
	-- shape the leak would take.
	Sfx.stopLoop(tensionLoop)
	tensionLoop = nil
	if bar then
		bar:hide()
	end
	ContextActionService:UnbindAction(ACTION)
end

return Reel
