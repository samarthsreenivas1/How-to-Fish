--!nonstrict
-- Rng.luau
-- Deterministic, seed-addressable randomness.
--
-- The reel minigame depends on client and server generating byte-identical bar
-- layouts from the same seed: the client simulates locally for zero input latency,
-- and the server replays the same layout to validate the clicks it is sent. So the
-- generator below must stay platform-stable and must not use math.random's shared
-- global state.
--
-- Lifted verbatim from the pre-reset backup per the plan's explicit instruction -
-- this module has no reason to be re-derived.

local Rng = {}

-- 32-bit xorshift. Same integer ops on every Luau VM, so client and server agree.
local function nextState(state: number): number
	state = bit32.bxor(state, bit32.lshift(state, 13))
	state = bit32.bxor(state, bit32.rshift(state, 17))
	state = bit32.bxor(state, bit32.lshift(state, 5))
	return state
end

local Stream = {}
Stream.__index = Stream

function Rng.stream(seed: number)
	-- Zero is a fixed point for xorshift; nudge it off.
	local s = bit32.band(math.floor(seed), 0xFFFFFFFF)
	if s == 0 then
		s = 0x9E3779B9
	end
	return setmetatable({ _s = s }, Stream)
end

-- Uniform in [0, 1).
function Stream:NextNumber(): number
	self._s = nextState(self._s)
	return self._s / 0x100000000
end

function Stream:NextRange(min: number, max: number): number
	return min + (max - min) * self:NextNumber()
end

function Stream:NextInteger(min: number, max: number): number
	return min + math.floor(self:NextNumber() * (max - min + 1))
end

-- Derive an independent sub-stream. Used to give each reel round its own layout
-- from one cast seed without the rounds correlating.
function Rng.derive(seed: number, salt: number): number
	local s = bit32.band(seed + salt * 0x9E3779B9, 0xFFFFFFFF)
	return nextState(nextState(s))
end

-- Weighted pick over a {key -> weight} map. `roll` is 0..1 so callers can supply a
-- deterministic value; omit it to draw from the stream.
function Rng.weightedPick(weights: { [string]: number }, roll: number?): string?
	local total = 0
	for _, w in weights do
		total += w
	end
	if total <= 0 then
		return nil
	end

	local target = (roll or math.random()) * total
	local acc = 0
	local last: string? = nil

	-- Iteration order over a hash map is not stable, so sort keys first. Callers
	-- rely on the same roll producing the same pick.
	local keys = {}
	for k in weights do
		table.insert(keys, k)
	end
	table.sort(keys)

	for _, k in keys do
		acc += weights[k]
		last = k
		if target <= acc then
			return k
		end
	end

	return last
end

-- Weighted pick over an array of entries carrying a `weight` field.
function Rng.weightedPickArray<T>(entries: { T }, roll: number?): T?
	local total = 0
	for _, e in entries do
		total += (e :: any).weight
	end
	if total <= 0 then
		return nil
	end

	local target = (roll or math.random()) * total
	local acc = 0

	for _, e in entries do
		acc += (e :: any).weight
		if target <= acc then
			return e
		end
	end

	return entries[#entries]
end

return Rng
