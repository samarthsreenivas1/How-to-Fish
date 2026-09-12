-- The six Brinejaw `Entry` gates, plus the anchor-is-computed assert.
-- Assembled and run by tools/check_brinejaw_entry.py: the stub, then
-- BrinejawPath.luau wrapped in a function, then this file. `CONTROL` is set
-- by the driver for the positive control.
local P = BrinejawPath
local REST_SAMPLES = 160 -- ChainPose's own sample count: the drawn length
local results = {}

local function report(name, ok, detail)
	table.insert(results, { name = name, ok = ok, detail = detail })
	print(string.format("GATE\t%s\t%s\t%s", name, if ok then "PASS" else "FAIL", detail))
end

local function stateAt(entry)
	local state = P.newState(Vector3.new(0, 0, 0))
	state.time = 0
	state.entry = entry
	return state
end

-- The drawn length: what ChainPose measures, at its own sample count.
local function chainLength(entry)
	local state = stateAt(entry)
	local total = 0
	local previous = P.pointAt(state, 0)
	for i = 1, REST_SAMPLES do
		local point = P.pointAt(state, i / REST_SAMPLES)
		total += (point - previous).Magnitude
		previous = point
	end
	return total
end

if CONTROL then
	-- POSITIVE CONTROL: move the APEX knot's height from 72 down to 40, which
	-- is below the broken lantern (64.6). Applied BEFORE the first read, so
	-- the lazy arc-length table is built from the perturbed knots exactly as
	-- a bad edit would leave them. At least one gate below must fail; a run
	-- where all six still pass means this file is measuring nothing.
	P.ENTRY_KNOTS[4][3] = 40.0
	print("CONTROL\tENTRY_KNOTS[4].y = 40 (was 72)")
end

-- ---------------------------------------------------------------- anchors
--
-- GATE 0 (the one the redesign doc does not list and the codebase needs
-- most): knots 1 and 2 must be COMPUTED from `restPoint` at run time. A
-- pasted pair of numbers is this project's most expensive defect class - a
-- value right in one file and stale in another - and here it would silently
-- unstitch the join the moment anyone retunes REST.
local knots = P.entryKnots()
local state = stateAt(nil)
local function cyl(point)
	return math.atan2(point.Z, point.X), math.sqrt(point.X * point.X + point.Z * point.Z), point.Y
end
local _, ghostR, ghostY = cyl(P.pointAt(state, 0.90))
local _, joinR, joinY = cyl(P.pointAt(state, 1.00))
-- pointAt carries the ambient breath and the rattle's flick; restPoint does
-- not, and the knots are built off restPoint. So the anchors are compared on
-- RADIUS and on the bearing (untouched by either ambient term) to 1e-9, and
-- the height to the ambient's own amplitude - the point of this gate is that
-- the numbers TRACK the rest pose, not that they match to the ulp.
local anchorOk = math.abs(knots[1][2] - ghostR) < 0.05
	and math.abs(knots[2][2] - joinR) < 0.05
	and math.abs(knots[1][3] - ghostY) < 2.0
	and math.abs(knots[2][3] - joinY) < 2.0
-- ...and the load-bearing half: PERTURB the rest pose and watch the anchor
-- move. A literal cannot do this.
local tailOut = P.REST.TAIL_OUT
P.REST.TAIL_OUT = tailOut + 7.0
local moved = P.entryKnots()[2][2] - knots[2][2]
P.REST.TAIL_OUT = tailOut
local tracks = math.abs(moved - 7.0) < 0.5
report(
	"anchors-computed",
	anchorOk and tracks,
	string.format(
		"join r %.3f (restPoint %.3f), ghost r %.3f (restPoint %.3f); TAIL_OUT +7 moved the join %.3f",
		knots[2][2],
		joinR,
		knots[1][2],
		ghostR,
		moved
	)
)

-- --------------------------------------------------------------- the six
local data = P.entryData()
print(
	string.format(
		"INFO\tL_rest(%d) = %.2f  spline = %.1f studs = %.3f body-lengths  breach sigma = %.4f  A = %.4f",
		P.ENTRY_REST_SAMPLES,
		data.restLength,
		data.total,
		data.sigmaMax,
		data.breach,
		data.a
	)
)

-- 1. BODY LENGTH CONSTANT to within +-5% of the rest pose's drawn length.
local restLength = chainLength(nil)
local worstEntry, worstPct = 0, 0
for i = 0, 100 do
	local entry = i / 100
	local pct = (chainLength(entry) / restLength - 1) * 100
	if math.abs(pct) > math.abs(worstPct) then
		worstPct, worstEntry = pct, entry
	end
end
report(
	"body-length",
	math.abs(worstPct) <= 5.0,
	string.format("rest %.2f studs; worst %+.2f%% at Entry %.2f", restLength, worstPct, worstEntry)
)

-- 2. THE HANDOFF IS EXACT. Entry = 1 must be the rest pose by the same code
-- path, not a curve that converges on it.
local one, plain = stateAt(1.0), stateAt(nil)
local worstDelta = 0
for i = 0, 2000 do
	local t = i / 2000
	local delta = (P.pointAt(one, t) - P.pointAt(plain, t)).Magnitude
	worstDelta = math.max(worstDelta, delta)
end
report(
	"handoff-exact",
	worstDelta < 1e-9,
	string.format("max |Entry=1 - rest| = %.3e studs over 2001 samples", worstDelta)
)

-- 3. FULLY HIDDEN AT Entry = 0: the highest point of the body is under the
-- water plane, so the stand-in can be born with no flash to cover it.
local zero = stateAt(0.0)
local highest = -1e9
for i = 0, 400 do
	highest = math.max(highest, P.pointAt(zero, i / 400).Y)
end
report(
	"hidden-at-zero",
	highest < P.ENTRY_WATER_Y,
	string.format("highest body y = %.2f, plane at %.2f", highest, P.ENTRY_WATER_Y)
)

-- 4. THE TRACK NEVER CLIPS THE TOWER, measured over the entry spline (the
-- rest path's own clearances are pre-existing and untouched - the coils sit
-- at REST.CLEARANCE by construction).
local minClear, minAt = 1e9, 0
for i = 0, 2000 do
	local sigma = data.sigmaMax * i / 2000
	local point = P.entrySpline(sigma)
	local r = math.sqrt(point.X * point.X + point.Z * point.Z)
	local clear = r - P.spireRadius(point.Y)
	if clear < minClear then
		minClear, minAt = clear, sigma
	end
end
report("spire-clearance", minClear >= 15.0, string.format("min clearance %.2f studs at sigma %.3f", minClear, minAt))

-- 5. IT READS AS A LEAP: the arc's apex clears the broken lantern room
-- (arena_gen hangs the old light cage at SPIRE_TOP + 4.6, and its posts reach
-- y ~64.6 - BrinejawIntro's camera-clearance note).
local lantern = P.SPIRE_TOP + 10.6
local apex, apexAt = -1e9, 0
for i = 0, 2000 do
	local sigma = data.sigmaMax * i / 2000
	local y = P.entrySpline(sigma).Y
	if y > apex then
		apex, apexAt = y, sigma
	end
end
report(
	"apex-over-lantern",
	apex >= lantern,
	string.format("apex y = %.2f at sigma %.3f, lantern %.2f", apex, apexAt, lantern)
)

-- 6. SEQUENTIAL SURFACING, head-first and monotonic in link index. This is
-- the user's beat stated as an inequality.
local previous, monotonic, breached = -1, true, 0
local firstEntry, lastEntry = nil, nil
for i = 1, 100 do
	local entry = P.entryOfBreach((i - 0.5) / 100)
	if entry then
		breached += 1
		if entry <= previous then
			monotonic = false
		end
		previous = entry
		firstEntry = firstEntry or entry
		lastEntry = entry
	end
end
report(
	"surfacing-order",
	monotonic and breached >= 90,
	string.format(
		"%d of 100 links breach inside 0..1; link 1 at Entry %.3f, link 100 at %.3f, monotonic %s",
		breached,
		firstEntry or -1,
		lastEntry or -1,
		tostring(monotonic)
	)
)

-- ------------------------------------------------------------ the staging
--
-- Not a gate: the table the script's camera is aimed from. Printed so a knot
-- edit shows its consequences in the same run that gates them.
print("STAGING\tEntry\theadR\theadY\theadBearing\ttailR\ttailY")
for _, entry in { 0.0, 0.15, 0.30, 0.45, 0.55, 0.65, 0.75, 0.85, 0.95, 1.0 } do
	local s = stateAt(if entry >= 1 then nil else entry)
	local head = P.pointAt(s, 0)
	local tail = P.pointAt(s, 1)
	print(
		string.format(
			"STAGING\t%.2f\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f",
			entry,
			math.sqrt(head.X * head.X + head.Z * head.Z),
			head.Y,
			math.deg(math.atan2(head.Z, head.X)) % 360,
			math.sqrt(tail.X * tail.X + tail.Z * tail.Z),
			tail.Y
		)
	)
end

-- THE ONE RESIDUAL, MEASURED AND REPORTED RATHER THAN GATED. The entry branch
-- returns before `pointAt`'s ambient terms (the travelling breath, the head's
-- sway, the rattle's flick), because the guard has to sit ahead of every blend
-- - so the frame the controller collapses `Entry` to nil, the ambient appears
-- at once. This is how big that step is at three thresholds; the controller's
-- own ENTRY.HOME is 0.998, and BrinejawIntro hides what is left of it inside
-- the settle (the skull is already coming down on the sand).
for _, threshold in { 0.995, 0.998, 0.9999 } do
	local near = stateAt(threshold)
	local step = 0
	for i = 0, 400 do
		local t = i / 400
		step = math.max(step, (P.pointAt(near, t) - P.pointAt(plain, t)).Magnitude)
	end
	print(string.format("INFO\thandoff step at Entry %.4f -> nil: %.3f studs", threshold, step))
end

local failed = 0
for _, row in results do
	if not row.ok then
		failed += 1
	end
end
print(string.format("SUMMARY\t%d gates, %d failed", #results, failed))
