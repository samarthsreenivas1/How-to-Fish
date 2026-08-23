--!nonstrict
-- ReelMath.luau
-- The reel minigame's geometry, shared verbatim by client and server.
--
-- This module is the reason the fishing minigame can feel instant without being
-- exploitable. The server picks a seed; the client simulates the bar locally so
-- clicks register with zero round-trip; the server replays the identical layout
-- from the same seed to check what the client claims it hit. Neither side can
-- drift, because both call the functions below and nothing here reads wall time,
-- math.random, or any mutable state.
--
-- The marker/RNG/scoring core is lifted from the pre-reset backup per the
-- plan's explicit instruction; buildZones was reshaped afterward (concentric
-- red-inside-green instead of two independent strips - see its comment).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rng = require(Shared.Modules.Rng)
local Tuning = require(Shared.Config.Tuning)

local ReelMath = {}

local REEL = Tuning.Reel

-- Marker position at time `t`, as a 0..1 coordinate along the bar.
-- The marker ping-pongs: a triangle wave of period 2 / barSpeed.
function ReelMath.markerAt(t: number, barSpeed: number): number
	local phase = (t * barSpeed) % 2
	if phase > 1 then
		phase = 2 - phase
	end
	return phase
end

-- Build the zone layout for one round of a cast. Pure function of (seed, round),
-- so client and server independently produce identical zones.
--
-- One target per round, not two independent strips: green surrounds red like
-- a bullseye, sharing a centre. That makes the whole scorable width just the
-- green zone's width (red is inside it, not extra), rather than red-plus-green -
-- two separate zones made landing *something* too easy.
--
-- `shrink` is the accumulated miss penalty (1.0 = no misses yet).
function ReelMath.buildZones(seed: number, round: number, config, shrink: number)
	local stream = Rng.stream(Rng.derive(seed, round * 7919))

	local redWidth = math.max(REEL.MIN_ZONE_WIDTH, config.redWidth * shrink)
	-- Always strictly wider than red, even after heavy shrink, so there's
	-- always a visible green ring around the red centre.
	local greenWidth = math.max(redWidth + REEL.MIN_ZONE_WIDTH, config.greenWidth * shrink)

	local half = greenWidth / 2
	local center = stream:NextRange(0.02 + half, 0.98 - half)

	-- Red is listed after green but drawn on top (ReelBar gives it the
	-- higher ZIndex) and classify() checks it first regardless of order, so
	-- the overlap is intentional, not a bug the old non-overlap search
	-- existed to prevent.
	return {
		{ min = center - greenWidth / 2, max = center + greenWidth / 2, kind = "green" },
		{ min = center - redWidth / 2, max = center + redWidth / 2, kind = "red" },
	}
end

-- Which zone kind sits under `pos`. Red wins ties, though buildZones prevents overlap.
function ReelMath.classify(zones, pos: number): string
	local result = "grey"
	for _, zone in zones do
		if pos >= zone.min and pos <= zone.max then
			if zone.kind == "red" then
				return "red"
			end
			result = "green"
		end
	end
	return result
end

function ReelMath.pointsFor(kind: string): number
	if kind == "red" then
		return REEL.POINTS_RED
	elseif kind == "green" then
		return REEL.POINTS_GREEN
	end
	return REEL.POINTS_GREY
end

-- Best achievable score for a config, used to normalise the grade thresholds.
-- Every round has a red centre, so the best case per click is always
-- POINTS_RED.
function ReelMath.maxScore(config): number
	return math.max(1, REEL.POINTS_RED * config.clicksRequired)
end

function ReelMath.gradeFor(score: number, config): string
	local ratio = score / ReelMath.maxScore(config)
	if ratio >= REEL.HOOKED_THRESHOLD then
		return "Hooked"
	elseif ratio <= REEL.ENRAGED_THRESHOLD then
		return "Enraged"
	end
	return "Neutral"
end

-- Luck multiplier earned by the reel, applied on top of the rod's own luck stat.
-- Unused until Slice 4 (rarity roll), but pure and cheap to keep in step.
function ReelMath.luckFor(score: number): number
	return 1 + score * REEL.LUCK_PER_POINT
end

-- Shrink factor after `misses` grey clicks.
function ReelMath.shrinkFor(misses: number): number
	return REEL.MISS_ZONE_SHRINK ^ misses
end

return ReelMath
