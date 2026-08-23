--!nonstrict
-- Minigames/snap.luau
-- Tap-targets (whack-a-mole): one target button appears at a random spot on
-- screen at a time and vanishes after `lifetime` seconds; tap/click it before
-- it's gone. `count` targets in a row; miss the ones you're too slow on. A
-- mobile-first input (tapping), and the cursor is freed on desktop so clicks
-- work too.
--
-- Shared/authority half plus the pure position helper the client reuses. The
-- server scores by whether the client reports it caught the target in time
-- (`extra` = 1 hit / 0 miss); with one target per round there is no wrong
-- button to pick, so hit/miss is the client's honest call, bounded to real
-- time by the generic onSubmit - the same PvE trust level as the rest (a
-- seed-replaying bot could beat any of these; accepted).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rng = require(Shared.Modules.Rng)
local Grades = require(Shared.Modules.Grades)
local Tuning = require(Shared.Config.Tuning)

local Snap = {}

Snap.HIT = 1
Snap.MISS = 0

-- Where the target for `round` appears, in scale coords (0..1). Pure and
-- deterministic; client-only (the server only needs the hit/miss). Kept clear
-- of the top HUD strip and the screen edges so a big button fits on screen.
function Snap.positionFor(seed: number, round: number): { x: number, y: number }
	local stream = Rng.stream(Rng.derive(seed, round * 7919))
	return {
		x = 0.15 + stream:NextNumber() * 0.70, -- [0.15, 0.85]
		y = 0.26 + stream:NextNumber() * 0.58, -- [0.26, 0.84]
	}
end

function Snap.configFor(_rodData)
	local S = Tuning.Minigames.Snap
	return {
		count = S.COUNT,
		lifetime = S.LIFETIME,
	}
end

function Snap.begin(_cast)
	return { round = 1, hits = 0 }
end

-- One target answered: `caught` is 1 if the client tapped it in time, 0 if it
-- timed out.
function Snap.onEvent(cast, round, _elapsed, caught)
	local mg = cast.mg
	if round ~= mg.round then
		return nil, false
	end

	if caught == Snap.HIT then
		mg.hits += 1
	end
	mg.round = round + 1

	local done = mg.round > cast.config.count
	return nil, done
end

function Snap.perf(cast): number
	return cast.mg.hits / math.max(1, cast.config.count)
end

function Snap.luckFor(cast): number
	return Grades.luckFor(Snap.perf(cast))
end

return Snap
