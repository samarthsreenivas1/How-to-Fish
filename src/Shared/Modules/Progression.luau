--!nonstrict
-- Progression.luau
-- The level curve and the names of the replicated player stats, shared so
-- the server (ProgressionService, which owns the numbers) and the client
-- (ProgressionController, which draws them) never disagree about either.
--
-- Levels are simple: each level needs XP_BASE * level ^ XP_EXPONENT to
-- clear, XP resets to the remainder on a level-up, and MAX_LEVEL caps it.
-- No prestige, no per-level unlocks yet - a level is a number that goes up
-- when you kill things. What it gates comes with later slices.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Tuning = require(Shared.Config.Tuning)

local Progression = {}

local P = Tuning.Progression

-- Attribute names on the Player instance. Set by the server, replicated to
-- everyone, read by the HUD (and by anything else that wants them - a
-- nametag, a leaderboard - without a remote).
Progression.ATTR = {
	coins = "Coins",
	xp = "XP",
	level = "Level",
	xpToNext = "XPToNext",
}

Progression.MAX_LEVEL = P.MAX_LEVEL
Progression.START_LEVEL = P.START_LEVEL

-- XP needed to go from `level` to `level + 1`.
function Progression.xpToNext(level: number): number
	return math.floor(P.XP_BASE * level ^ P.XP_EXPONENT + 0.5)
end

return Progression
