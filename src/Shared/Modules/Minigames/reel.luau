--!nonstrict
-- Minigames/reel.luau
-- The original reel bar, as a minigame module: the shared/authority half.
-- Wraps ReelMath so the reel keeps behaving exactly as before while fitting
-- the common minigame contract every fishing minigame implements:
--
--   configFor(rodData) -> config     -- server: per-rod layout (caller sets .kind)
--   begin(cast) -> mgState           -- server: fresh per-cast scoring state (cast.mg)
--   onEvent(cast, round, elapsed) -> (echo, done)  -- server: authoritative scoring of one input
--   perf(cast) -> number             -- normalised [0,1] for Grades
--   luckFor(cast) -> number          -- rarity-roll luck
--
-- The client half (input, prediction, the bar view) is Client/Minigames/reel.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ReelMath = require(Shared.Modules.ReelMath)

local Reel = {}

-- Scales a rod's base reel layout by its own stats: power speeds the marker
-- up, control widens both zones. (Was FishingService.reelConfigFor.)
function Reel.configFor(rodData)
	local base = rodData.reel
	local stats = rodData.stats
	local perk = rodData.perk

	-- Forgiveness perks ride in the config so BOTH sides compute the same
	-- shrink: the client predicts its own zones from this, the server regrades
	-- from it, and a mismatch would desync the layout mid-cast.
	return {
		clicksRequired = base.clicksRequired,
		barSpeed = base.barSpeed * stats.power,
		redWidth = base.redWidth * stats.control,
		greenWidth = base.greenWidth * stats.control,
		freeMisses = perk and perk.freeMisses or 0,
		noShrink = perk and perk.noShrink or false,
	}
end

-- How far this cast's zones have shrunk after `misses` grey clicks, honouring
-- the rod's forgiveness perk. Shared so client prediction and server authority
-- can never disagree (Reefmaw never shrinks; Bamboo eats the first miss).
function Reel.shrinkFor(config, misses: number): number
	if config.noShrink then
		return 1
	end
	return ReelMath.shrinkFor(math.max(0, misses - (config.freeMisses or 0)))
end

-- Per-cast server scoring state, stored on cast.mg.
function Reel.begin(_cast)
	return { round = 1, score = 0, misses = 0 }
end

-- Authoritative scoring of one click. `elapsed` has already been bounded
-- against the server clock by the generic onSubmit wrapper. Rounds must arrive
-- in order (a repeat or out-of-order round is the signature of a replayed
-- packet); an off-round click is ignored with no echo. Returns the echo for
-- ReelRoundResult and whether the cast is finished.
function Reel.onEvent(cast, round, elapsed)
	local mg = cast.mg
	if round ~= mg.round then
		return nil, false
	end

	local shrink = Reel.shrinkFor(cast.config, mg.misses)
	local zones = ReelMath.buildZones(cast.seed, round, cast.config, shrink)
	local marker = ReelMath.markerAt(elapsed, cast.config.barSpeed)
	local kind = ReelMath.classify(zones, marker)

	mg.score += ReelMath.pointsFor(kind)
	if kind == "grey" then
		mg.misses += 1
	end
	mg.round = round + 1

	local done = mg.round > cast.config.clicksRequired
	return { kind = kind, score = mg.score }, done
end

function Reel.perf(cast): number
	return cast.mg.score / ReelMath.maxScore(cast.config)
end

-- The reel keeps its own raw-score luck (unchanged from before) rather than
-- Grades.luckFor(perf), so Slice 1 is byte-identical.
function Reel.luckFor(cast): number
	return ReelMath.luckFor(cast.mg.score)
end

return Reel
