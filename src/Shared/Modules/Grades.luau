--!nonstrict
-- Grades.luau
-- Turns any minigame's normalised performance (perf in [0, 1]) into the reel
-- grade and the rarity-roll luck multiplier, so every fishing minigame feeds
-- the same downstream (CreatureService grade, rollCreature luck) without each
-- one re-deriving the thresholds.
--
-- The thresholds are read from Tuning.Reel (not copied) so the reel's own
-- numbers stay the single source. For the reel, perf = score / maxScore, and
-- Grades.gradeFor(perf) is identical to ReelMath.gradeFor(score, config) - the
-- reel keeps using ReelMath.luckFor(score) directly so Slice 1 is exactly
-- unchanged; the other minigames use Grades.luckFor(perf).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Tuning = require(Shared.Config.Tuning)

local Grades = {}

local R = Tuning.Reel

function Grades.gradeFor(perf: number): string
	if perf >= R.HOOKED_THRESHOLD then
		return "Hooked"
	elseif perf <= R.ENRAGED_THRESHOLD then
		return "Enraged"
	end
	return "Neutral"
end

-- Tuned so a perfect run (perf = 1) lands near the reel's own best luck of
-- 1 + POINTS_RED*clicksRequired*LUCK_PER_POINT = 1 + 3*3*0.18 = 2.62, keeping
-- new minigames roughly on par with a perfect reel for the rarity roll.
local LUCK_PER_PERF = 1.62

function Grades.luckFor(perf: number): number
	return 1 + math.clamp(perf, 0, 1) * LUCK_PER_PERF
end

return Grades
