--!nonstrict
-- ChainPose.luau
-- Pose a chain of parts along any curve, by arc length.
--
-- The shared half of the colossus bosses: Brinejaw's ~100 vertebrae on their
-- lighthouse, the Kraken's six arms, Wrack's anchor chains. Each of those is
-- the same problem - "given a curve that changes shape every frame, where
-- does link `i` sit?" - so it is solved once, here.
--
-- PURE MATH, deliberately. No Instances, no state of its own beyond the
-- samples it caches, no module-level singleton (every chain is its own
-- object, so six arms coexist happily). That is what lets the SERVER call it
-- for authority - hitboxes, damage positions - and the CLIENT call it for
-- drawing, off the same inputs, with no chance of the thing you dodge and
-- the thing you see disagreeing.
--
-- A SHAPE is just `function(state, t) -> Vector3`, t = 0 at the head/root and
-- 1 at the tip. Anything can be a shape; blending two of them is how an
-- attack happens (see ChainPose.blend), which keeps "every attack is a blend
-- away from the rest pose and back" a first-class idea rather than something
-- each boss reinvents.
--
--   local chain = ChainPose.new(myShape)
--   chain:update(state)                 -- resample after the state moves
--   chain:each(3.4, function(i, cframe, u)
--       parts[i].CFrame = cframe        -- +X runs up-body, the pack convention
--       parts[i].Size = base * (1 - 0.6 * u)
--   end)
--
-- Sampling cost is `samples` shape calls per update plus a binary search per
-- link, so a 100-link chain at 160 samples is a few thousand cheap ops - fine
-- every frame on either side.

local ChainPose = {}
ChainPose.__index = ChainPose

-- A CFrame at `position` whose +X axis runs along `forward` - the mesh packs'
-- forward convention (assets/boss_gen.py, creatures_gen.py). Guarded for the
-- straight-up case, which a reared neck really does hit.
local function alongX(position: Vector3, forward: Vector3): CFrame
	local up = if math.abs(forward.Y) > 0.99 then Vector3.new(0, 0, 1) else Vector3.new(0, 1, 0)
	local right = forward:Cross(up)
	if right.Magnitude < 1e-4 then
		right = Vector3.new(1, 0, 0)
	end
	local realUp = right.Unit:Cross(forward).Unit
	return CFrame.fromMatrix(position, forward, realUp)
end

-- `shape(state, t) -> Vector3`. `opts.samples` trades accuracy for cost.
function ChainPose.new(shape, opts)
	opts = opts or {}
	return setmetatable({
		shape = shape,
		samples = opts.samples or 160,
		points = {},
		cumulative = {},
		length = 0,
	}, ChainPose)
end

-- Two shapes and a blend factor become one shape. `alpha` may be a number or
-- a function(state, t) -> number, so a blend can reach only part of the body
-- (Brinejaw's tail peels off the tower while its neck stays put).
function ChainPose.blend(a, b, alpha)
	return function(state, t)
		local w = if type(alpha) == "function" then alpha(state, t) else alpha
		w = math.clamp(w or 0, 0, 1)
		if w <= 0 then
			return a(state, t)
		elseif w >= 1 then
			return b(state, t)
		end
		return a(state, t):Lerp(b(state, t), w)
	end
end

-- Resample the curve for this frame's state. Tables are reused, so a chain
-- updating every frame does not churn the allocator.
function ChainPose:update(state)
	local shape, count = self.shape, self.samples
	local points, cumulative = self.points, self.cumulative
	for i = 0, count do
		points[i + 1] = shape(state, i / count)
	end
	cumulative[1] = 0
	for i = 1, count do
		cumulative[i + 1] = cumulative[i] + (points[i + 1] - points[i]).Magnitude
	end
	for i = count + 2, #points do
		points[i] = nil
		cumulative[i] = nil
	end
	self.length = cumulative[count + 1]
	return self
end

-- The point `distance` studs along the curve from the head.
function ChainPose:pointAt(distance: number): Vector3
	local cumulative, points = self.cumulative, self.points
	local last = #points
	if last == 0 then
		return Vector3.zero
	end
	distance = math.clamp(distance, 0, self.length)
	local lo, hi = 1, last
	while lo < hi do
		local mid = (lo + hi) // 2
		if cumulative[mid + 1] and cumulative[mid + 1] < distance then
			lo = mid + 1
		else
			hi = mid
		end
	end
	local i = math.clamp(lo, 1, last - 1)
	local span = cumulative[i + 1] - cumulative[i]
	local t = if span < 1e-9 then 0 else (distance - cumulative[i]) / span
	return points[i]:Lerp(points[i + 1], t)
end

-- Unit vector pointing UP-BODY (toward the head) at `distance`.
function ChainPose:tangentAt(distance: number): Vector3
	local step = math.min(1.0, math.max(self.length * 0.01, 0.05))
	local delta = self:pointAt(distance - step) - self:pointAt(distance + step)
	return if delta.Magnitude > 1e-4 then delta.Unit else Vector3.new(1, 0, 0)
end

-- Position and orientation together, +X up-body.
function ChainPose:cframeAt(distance: number): CFrame
	return alongX(self:pointAt(distance), self:tangentAt(distance))
end

-- Walk the chain at `spacing` studs, calling fn(index, cframe, u, distance).
-- `u` is 0..1 along the body, for taper.
function ChainPose:each(spacing: number, fn)
	spacing = math.max(spacing, 0.05)
	local count = math.max(math.floor(self.length / spacing), 1)
	for i = 0, count do
		local distance = i * spacing
		fn(i + 1, self:cframeAt(distance), if self.length > 0 then distance / self.length else 0, distance)
	end
	return count + 1
end

-- How many links `spacing` will produce - for sizing a part pool up front.
function ChainPose:count(spacing: number): number
	return math.max(math.floor(self.length / math.max(spacing, 0.05)), 1) + 1
end

return ChainPose
