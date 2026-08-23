--!nonstrict
-- Minigames/burst.luau
-- Rapid-tap burst: "it's diving!" - mash to fill the bar before the timer
-- runs out. A genuinely different input from the reel (no sweeping marker, no
-- timing window per press - just raw taps per second).
--
-- Server authority is cheap: it counts taps. A tap counts only inside the
-- window (which opens on the FIRST tap and lasts DURATION) and no faster than
-- MAX_TAPS_PER_SEC (the human-rate cap that stops an auto-clicker). Each tap's
-- reported time is already bounded to real time by the generic onSubmit, so a
-- client can't backdate a flurry. The cast resolves when the client sends the
-- FINISH sentinel (round 0) at the end of its countdown; the normal cast
-- timeout is the backstop if that packet is lost.
--
-- Taps carry no per-event echo (no ReelRoundResult per tap - that would be one
-- downstream packet per mash); the client predicts its own fill bar and the
-- authoritative tap count only matters at resolve. So this module never
-- returns an echo; only FINISH returns done = true.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Grades = require(Shared.Modules.Grades)
local Tuning = require(Shared.Config.Tuning)

local Burst = {}

-- Round 0 from the client means "the window's over, resolve now".
Burst.FINISH = 0

-- No per-rod layout to speak of; the burst is the same mash for every rod.
-- (Rod stats could scale TARGET later; kept flat for the first pass so the
-- feel is easy to judge.)
function Burst.configFor(_rodData)
	local B = Tuning.Minigames.Burst
	return {
		duration = B.DURATION,
		target = B.TARGET_TAPS,
	}
end

function Burst.begin(_cast)
	return { taps = 0, windowStart = nil, lastTap = -math.huge }
end

function Burst.onEvent(cast, round, elapsed)
	local mg = cast.mg
	local B = Tuning.Minigames.Burst

	if round == Burst.FINISH then
		return nil, true -- client's countdown ended; resolve
	end

	-- A tap. The window opens on the first one and lasts `duration`.
	if mg.windowStart == nil then
		mg.windowStart = elapsed
	end

	local inWindow = elapsed <= mg.windowStart + cast.config.duration
	local rateOk = (elapsed - mg.lastTap) >= (1 / B.MAX_TAPS_PER_SEC)
	-- Cap counting a bit above target so a fast masher hits perf 1 but a flood
	-- can't run the number up.
	if inWindow and rateOk and mg.taps < cast.config.target * 2 then
		mg.taps += 1
		mg.lastTap = elapsed
	end

	return nil, false -- no per-tap echo
end

function Burst.perf(cast): number
	return math.clamp(cast.mg.taps / math.max(1, cast.config.target), 0, 1)
end

function Burst.luckFor(cast): number
	return Grades.luckFor(Burst.perf(cast))
end

return Burst
