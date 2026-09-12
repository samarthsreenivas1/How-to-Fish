--!nonstrict
-- BrinejawIntro.luau
-- Brinejaw's summon cinematic: the sea goes glassy, the keeper's light dies,
-- and then 288 studs of serpent comes out of the open water HEAD FIRST, arcs
-- over the arena above the broken lantern, lands on the sand and climbs the
-- Tidebreak Spire in three turns while its tail is still leaving the sea.
-- Registered once against the kit (src/Client/Modules/CutsceneKit.luau) and
-- stepped by BossCutsceneController from server time, so every party member
-- watches the same frame.
--
-- WHAT CHANGED, AND WHY THIS FILE IS NOW SHORT ON EXCUSES. The version this
-- replaces opened with an honest confession: the rig had exactly one topology
-- (a serpent wrapped round the lighthouse) and ten scalars that deform it, the
-- peel at `Unwind = 1` reached only t 0.6, and so "there is therefore no pose
-- in the vocabulary for 'the chain is airborne over the arena'". The eruption
-- was eight Glass columns and the arm flung out of the beach, because that was
-- the best the channel set could express.
--
-- The channel set gained the missing member: `Entry`, a level in 0..1 meaning
-- HOW FAR ALONG ITS ARRIVAL THIS ANIMAL IS (BrinejawPath's "the ENTRY channel"
-- section, docs/boss-cutscenes-redesign.md SS2). It is one position along ONE
-- joined track - an authored cylindrical spline out at sea, joined to the rest
-- path walked TAIL-END FIRST - so the head-first sequential emergence and the
-- coiling are not staged here at all. They are what walking that track by arc
-- length means:
--
--   * every vertebra traces the head's own path, which is what a serpent does;
--   * a link breaks the surface when the head parameter reaches that link's
--     offset, so the body pours out behind the skull in order (link 1 at
--     Entry 0.056, link 100 at 0.580 - measured by tools/check_brinejaw_entry.py);
--   * the last body-length of the track IS the helix on the tower, so
--     "curling around the lighthouse" needed no new geometry;
--   * and at `Entry = 1` the pose is not NEAR the fight's rest pose, it IS it -
--     the same call with the same argument (max difference over 2001 samples:
--     0.000e+00 studs).
--
-- THE STAND-IN IS BORN SUBMERGED AND EARLY, which is the opposite of what this
-- script used to do. At `Entry = 0` the whole body is out at r 178..230 and
-- 20.6 studs UNDER the water plane (the highest point of it measures -20.58),
-- so there is nothing to hide and no flash is needed to cover the frame it
-- appears on. The old file created its actor inside the eruption's flash
-- because a live actor was a visible serpent on the tower; it is not any more.
--
-- EVERY `Entry` WRITE GOES THROUGH `kit.track`, NEVER `kit.during`. A `during`
-- is simply not visited after a skip, which would leave the serpent in
-- mid-air; a track that has passed is applied once at u = 1 and left alone, so
-- however the run got here the body is where the handoff needs it. The
-- schedule is ONE table (`ENTRY_STEPS`) read by both the tracks and the
-- camera, because the shots look at the head and a camera aimed from a second
-- copy of the schedule is a camera aimed at where the serpent used to be.
--
-- THE ONE SEAM, STATED: the entry branch in `pointAt` returns ahead of every
-- blend (it has to - the sweep's latched branch must never see an arriving
-- body), which puts it ahead of the ambient breath and sway as well. So the
-- frame `Entry` collapses to nil, the ambient re-enters as a 1.63-stud step.
-- The schedule puts that frame at t = 16.97, inside the 16.6..17.3 slump ramp,
-- where the skull is already moving 26 studs - and the gate asserts it.
--
-- THE SPLASHES ARE NOT SCHEDULED HERE EITHER. BrinejawBodyController detects
-- each link's own first frame above the water plane and calls the hook
-- installed below with that link's real position - the drawn body is the only
-- thing that knows where link 37 is on this frame, and a schedule computed
-- here would be a remembered value that goes stale the first time a knot or an
-- ease is retuned. A skip fires nothing, twice over: `kit.vfx` is muted for
-- the whole fast-forward, and the controller re-baselines silently on any
-- frame that advances `Entry` by more than its own step guard.
--
-- THE HANDOFF is the last 4.2 s: BossService raises the real boss at
-- `kit.raiseAt` and CreatureService's entrenched branch drives Slump 1 -> 0
-- over riseTime from a FRESH BrinejawPath.newState. So the real rise's first
-- frame is newState's defaults with Slump pinned at 1, and this script parks
-- the stand-in on exactly those ten values - and REMOVES `Entry` - well before
-- the swap. See HANDOFF below, which writes them in plain sight rather than
-- leaving them implied by where the tracks happened to stop.
--
-- Everything geometric is READ rather than copied: the beach profile, the
-- spire's top, the rest bearing, the head's lead and sit height, the breach
-- point, the per-link surfacing order, and the water plane itself (see the
-- WATERLINE check below - the one number in the design that was an assumption
-- until it was traced).
--
-- kit.landmark("Spire") IS DELIBERATELY NOT USED, for the same reason as
-- before: the arena has very often not streamed in at t = 0 of a summon, and a
-- landmark that answers nil there would fall back to a guess.
-- BrinejawPath.SPIRE_TOP is the constant both paths are built from.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BrinejawPath = require(Shared.Modules.BrinejawPath)
local BrinejawBodyController = require(script.Parent.Parent.Controllers.BrinejawBodyController)

-- Every authored number in one table, so a retune is one edit and the report
-- can quote it. Bearings are the kit's convention (0 = +X, rising toward +Z),
-- which is also BrinejawPath's own `theta`.
local N = {
	-- Where it comes in from, kept from the version this replaces and for that
	-- version's reason: the party ring puts a challenger at bearing 0
	-- (BossArenaService.ringPositions), so an arrival on 236..270 sweeps ACROSS
	-- the camera rather than at it, and it lands short of the 342 the head
	-- rests over. These are the bearings BrinejawPath.ENTRY_KNOTS is authored
	-- on; they are here for the CAMERA, and the two agree because the shots
	-- below aim at the head's own position rather than at a bearing.
	party = 0,
	seaLow = math.rad(236),
	seaHigh = math.rad(270),
	-- The ruined lantern room. arena_gen's build_bj_spire_detail hangs the old
	-- light cage at BJ_SPIRE_TOP_Z + 4.6; its posts reach y ~64.6, which is the
	-- height the arc's apex has to beat (it measures 72.58).
	lampAbove = 4.6,
	glass = Color3.fromRGB(206, 238, 255),
	lampWarm = Color3.fromRGB(255, 214, 138),
	lampRed = Color3.fromRGB(255, 62, 44),
	sandDust = Color3.fromRGB(228, 208, 160),
	-- One splash per this many links. 100 links over 0.52 of `Entry` is a
	-- splash every 0.05 s at the pour's fastest, which stacks; every fourth is
	-- 25 of them, which is the sequence you can actually read.
	splashEvery = 4,
}

-- The timeline, absolute seconds. Written out rather than derived from
-- `duration` because these are beats, not fractions. The BossCutscenes row is
-- 22 and the handoff is at raiseAt = 17.8.
local T = {
	glassy0 = 0.0,
	glassy1 = 3.6,
	gutter0 = 2.4,
	gutter1 = 3.3,
	tower0 = 3.6,
	tower1 = 5.4,
	born = 5.4,
	wake0 = 5.4,
	wake1 = 7.4,
	breach0 = 7.4,
	breach1 = 8.6,
	arc0 = 8.6,
	arc1 = 11.4,
	beach = 11.4,
	coil0 = 11.4,
	coil1 = 15.6,
	settle0 = 15.6,
	-- WHERE `Entry` REACHES 1, and it is 0.8 s earlier than the beat table in
	-- the redesign doc, for a measured reason. The controller chases this
	-- channel with a first-order filter at 3.0/s, and the lag of such a filter
	-- chasing a RAMP is slope/rate - so the drawn body arrives at the rest pose
	-- only after the attribute has STOPPED ramping. The last row of
	-- ENTRY_STEPS therefore lands here, with a zero-terminal-slope shape, and
	-- the 0.2 s of flat attribute that follows is what lets the ease actually
	-- close: the drawn `Entry` crosses the controller's ENTRY.HOME (0.998) at
	-- t = 16.97, which is INSIDE the slump ramp below. See "THE COLLAPSE" in
	-- HANDOFF; tools/check_brinejaw_entry.py asserts the ordering.
	entryHome = 16.4,
	-- The skull comes down across the collapse, deliberately: it moves 26
	-- studs over these 0.7 s, so the 1.6-stud ambient step the collapse makes
	-- lands on a frame where the head is already moving twenty times that.
	slump0 = 16.6,
	slump1 = 17.3,
	settle1 = 17.3,
	handoff = 17.3,
}

local function clamp01(x: number): number
	return math.clamp(x, 0, 1)
end

local function smooth(x: number): number
	x = clamp01(x)
	return x * x * (3 - 2 * x)
end

local function easeOut(x: number): number
	x = clamp01(x)
	return 1 - (1 - x) * (1 - x)
end

local function linear(x: number): number
	return clamp01(x)
end

-- THE ARRIVAL'S SCHEDULE, AND IT HAS EXACTLY ONE HOME. Each row is a window,
-- the `Entry` it runs between, and the shape it runs on. The tracks below
-- apply these rows and the camera's `headAt` reads the same rows, so there is
-- no second copy of the timing to drift: a shot that looks at the head is
-- looking at the head. The shapes are this file's own functions rather than
-- the kit's `ease` names for that reason - the kit applies its easing inside
-- `addTrack`, where a `look` function cannot see it.
--
-- The values are the redesign's staging table (SS2.2): the head breaches at
-- 0.053, is 48 studs airborne by 0.15, tops the arc at 0.30, lands on the sand
-- at 0.45, takes its first turn on the drum at 0.65, the second at 0.75, the
-- third at 0.85, and clears the gallery at 0.95.
local ENTRY_STEPS = {
	{ t0 = T.wake0, t1 = T.wake1, from = 0.000, to = 0.045, shape = smooth },
	{ t0 = T.breach0, t1 = T.breach1, from = 0.045, to = 0.160, shape = easeOut },
	{ t0 = T.arc0, t1 = T.arc1, from = 0.160, to = 0.450, shape = linear },
	{ t0 = T.coil0, t1 = T.coil1, from = 0.450, to = 0.970, shape = smooth },
	-- SMOOTH, NOT `easeIn`, AND THIS ROW'S SHAPE IS LOAD-BEARING. `easeIn` has
	-- its MAXIMUM slope at the end of the window - exactly where the ease has
	-- to arrive - so the drawn `Entry` was still 0.0145 short of home when the
	-- attribute reached 1 (measured by simulating the controller's own filter),
	-- and the nil-collapse's step was 9.64 studs - measured the harness's own
	-- way, the largest displacement over 401 body samples between the eased
	-- state and the rest pose, the method that yields the documented 1.631 at
	-- ENTRY.HOME (6.15 studs of it is the head alone). `smooth` leaves with
	-- zero slope, so the filter's ramp lag falls to nothing as the target
	-- arrives and the collapse happens 0.57 s later at t = 16.97, with 0.002 of
	-- track left: 1.63 studs, inside the slump ramp.
	{ t0 = T.settle0, t1 = T.entryHome, from = 0.970, to = 1.000, shape = smooth },
}

-- The `Entry` the schedule is at, at absolute time `t`. Before the first row
-- the animal is submerged and 0; after the last it is home.
local function entryAtTime(t: number): number
	if t <= ENTRY_STEPS[1].t0 then
		return ENTRY_STEPS[1].from
	end
	for _, row in ENTRY_STEPS do
		if t < row.t1 then
			return row.from + (row.to - row.from) * row.shape((t - row.t0) / (row.t1 - row.t0))
		end
	end
	return ENTRY_STEPS[#ENTRY_STEPS].to
end

return function(kit)
	local rest = BrinejawPath.REST
	local cy = kit.center.Y
	local raiseAt = kit.raiseAt
	local cardAt = raiseAt + 0.85 * kit.riseTime

	-- ------------------------------------------------------------ WATERLINE
	--
	-- THE ONE NUMBER IN THE DESIGN THAT WAS AN ASSUMPTION. Every arena-local y
	-- in BrinejawPath.ENTRY_KNOTS is measured against a water plane at 0.0, on
	-- the reading that this boss's `state.center` IS the waterline -
	-- CreatureService's `colossusState` builds its pose as
	-- `newState(Vector3.new(anchor.X, World.WATER_Y, anchor.Z))`, snapped on
	-- purpose - while the cutscene's own centre comes the other way round,
	-- from `BossArenaService.floorY`, which returns `World.WATER_Y` unchanged
	-- for every sea-level arena. They agree, and the breach sigma, ENTRY_A and
	-- every splash below are computed from that. So it is CHECKED rather than
	-- believed: if the two ever diverge the staging is wrong by exactly the
	-- difference, and this warning is the thing that says so out loud instead
	-- of the arrival quietly happening 30 studs under the sea.
	local waterLocal = kit.waterY - cy
	if math.abs(waterLocal - BrinejawPath.ENTRY_WATER_Y) > 0.01 then
		warn(
			string.format(
				"[BrinejawIntro] the arena-local waterline is %.2f, not BrinejawPath.ENTRY_WATER_Y (%.2f)"
					.. " - re-run tools/check_brinejaw_entry.py with the new plane; the breach and A move with it",
				waterLocal,
				BrinejawPath.ENTRY_WATER_Y
			)
		)
	end

	-- ------------------------------------------------------------ geometry
	--
	-- Arena-local heights, all measured off the shared profile rather than a
	-- raycast: kit.floorY falls back to the waterline when the arena has not
	-- streamed in yet, and at t = 0 of a summon it very often has not.
	local function ground(r: number): number
		return cy + BrinejawPath.sandY(r)
	end

	local lamp = Vector3.new(kit.center.X, cy + BrinejawPath.SPIRE_TOP + N.lampAbove, kit.center.Z)
	local towerMid = Vector3.new(kit.center.X, cy + 32, kit.center.Z)

	-- WHERE THE SEA OPENS, read off the track rather than chosen: the spline
	-- crosses the water plane exactly once, at `entryData().breach`, and that
	-- point is where the head comes through. It measures r 178 on bearing 248,
	-- which is what shots 3 and 4 are built around.
	local entryData = BrinejawPath.entryData()
	local breachLocal = BrinejawPath.entrySpline(entryData.breach)
	local breachAt = Vector3.new(kit.center.X + breachLocal.X, kit.waterY, kit.center.Z + breachLocal.Z)
	local breachBearing = math.atan2(breachLocal.Z, breachLocal.X)

	-- A scratch state, for asking the path where the body WILL be. It is this
	-- file's only state and it is never drawn from - the drawn body is the
	-- controller's, eased, and lags this by design.
	local probe = BrinejawPath.newState(kit.center)
	local function probeAt(t: number)
		local entry = entryAtTime(t)
		-- `nil` at and past 1, the same collapse the controller makes: asking
		-- the path for `Entry = 1` and for the rest pose are the same call, and
		-- spelling it out here keeps this file's prediction and the drawn body
		-- on one code path at the handoff too.
		probe.entry = if entry >= 1 then nil else entry
		probe.time = 0
		return probe
	end
	local function headAt(t: number): Vector3
		return BrinejawPath.pointAt(probeAt(t), 0)
	end

	-- Where the skull lies once Slump is 1, straight out of `slumpPoint`: the
	-- joint sits at reach 26 on `faceAngle` and the drawn skull is HEAD_LEAD
	-- further along a curve the pose deliberately runs level, at `headSitY` of
	-- that radius plus SLUMP_LIFT.
	local restFace = rest.BEARING - 0.8
	local slumpSkullR = 26.0 + BrinejawPath.HEAD_LEAD
	local slumpSkull =
		kit.polar(slumpSkullR, restFace, cy + BrinejawPath.headSitY(slumpSkullR) + BrinejawPath.SLUMP_LIFT)
	-- ...and where the neck is once it is back up.
	local rearThroat = kit.polar(BrinejawPath.spireRadius(rest.HEAD_Y) + rest.CLEARANCE + 2.0, N.party, cy + 50)

	-- ------------------------------------------------------------ the lamp
	--
	-- The keeper's light: burning at the top of the cinematic, guttered out by
	-- the omen, and relit RED on the roar. One light and one neon bulb the
	-- whole way through, because two would be two things to keep in step. This
	-- is the one prop that stays a `kit.part`: BrinejawFxPack has no lamp, and
	-- a glowing bulb is exactly what a two-stud neon ball is for.
	local bulb = kit.part({
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(2.4, 2.4, 2.4),
		CFrame = CFrame.new(lamp),
		Color = N.lampWarm,
		Material = Enum.Material.Neon,
		Transparency = 0.05,
	})
	local lampLight = kit.light(lamp, N.lampWarm, 78, 2.4)

	-- --------------------------------------------------------- the stand-in
	--
	-- Born SUBMERGED at 5.4, in the open water, invisible because the body
	-- genuinely is under the sea at `Entry = 0` - not because something is in
	-- front of it. The other ten channels are newState's own defaults: the
	-- entry branch in `pointAt` returns before the unwind blend, the slump and
	-- every attack mode, so `Coil`, `Unwind` and `SweepAngle` are inert for
	-- the whole arrival and are set here only so the handoff has nothing left
	-- to do.
	local stand = nil

	kit.at(T.born, function()
		stand = kit.actor({
			pose = kit.boss.pose,
			name = "Cutscene_Brinejaw",
			attrs = {
				Entry = 0,
				Coil = BrinejawPath.MAX_COIL,
				Unwind = 0,
				SweepAngle = 0,
				SweepHeight = BrinejawPath.SWEEP_LOW,
				Slump = 0,
				FaceAngle = restFace,
				AttackKind = "",
				AttackU = 0,
				AimX = 0,
				AimZ = 0,
			},
		})

		-- THE SPLASHES, from the drawn body. The controller calls this on each
		-- link's first frame above the plane; `kit.vfx` is a muted proxy during
		-- a fast-forward, so a skip fires none of them. Installed here rather
		-- than at registration because the actor does not exist until now -
		-- and it is safe to call before the adopt lands (the controller parks
		-- the hook until then, deliberately, because `Pose` rides a deferred
		-- signal).
		BrinejawBodyController.setEntrySplash(stand.model, function(index, position)
			if index % N.splashEvery ~= 0 then
				return
			end
			kit.vfx.splash(Vector3.new(position.X, kit.waterY, position.Z), 1.6)
			kit.vfx.ring(Vector3.new(position.X, kit.waterY, position.Z), 1.5, 9, 0.7, N.glass)
		end)
	end)

	kit.onRealBoss(function()
		if stand then
			stand:destroy()
			stand = nil
		end
	end)

	-- THE ARRIVAL ITSELF: one track per row of the schedule, and nothing else
	-- drives the body. Registered at t = 0 so a skip settles every one of them
	-- at u = 1 and the serpent ends on the tower however the run got there.
	for _, row in ENTRY_STEPS do
		kit.track(row.t0, row.t1, nil, function(u)
			if stand then
				stand:set("Entry", row.from + (row.to - row.from) * row.shape(u))
			end
		end)
	end

	-- ------------------------------------------------------------ the omen
	--
	-- The sea goes glassy: rings on the water, fewer and smaller, then none.
	-- Authored positions, not seeded noise - there is no randomness anywhere in
	-- this script, so every client draws the same water.
	kit.at(0.15, function()
		kit.vfx.ring(kit.polar(96, math.rad(30), kit.waterY), 2, 26, 1.6, N.glass)
		kit.vfx.ring(kit.polar(78, math.rad(96), kit.waterY), 2, 20, 1.6, N.glass)
	end)
	kit.at(1.10, function()
		kit.vfx.ring(kit.polar(88, math.rad(190), kit.waterY), 2, 15, 1.5, N.glass)
	end)
	kit.at(2.05, function()
		kit.vfx.ring(kit.polar(92, math.rad(300), kit.waterY), 1.5, 7, 1.4, N.glass)
	end)

	-- The light gutters. A decaying flicker rather than a fade, because a lamp
	-- going out is a fight and a dimmer is not.
	kit.track(T.gutter0, T.gutter1, nil, function(u)
		local fall = 1 - u
		lampLight.Brightness = 2.4 * fall * (0.45 + 0.55 * math.cos(u * 38))
		lampLight.Range = 78 * fall
		bulb.Transparency = 1 - 0.95 * fall
	end)
	kit.at(2.95, function()
		kit.sfx("lanternBreak", lamp)
	end)
	kit.at(4.30, function()
		kit.sfx("bossTell", kit.center)
	end)
	kit.rumble(4.6, 6.2, 0.004)

	-- ------------------------------------------------------------- the wake
	--
	-- The submerged body drives a travelling swell, and the swell is COMPUTED
	-- FROM THE BODY rather than authored: eight body positions, a ring on the
	-- plane above each one that is still under it. The old script had no way to
	-- do this - the rig's world position was a constant - and it is the first
	-- thing `Entry` buys back.
	kit.every(T.wake0 + 0.2, T.wake1, 0.28, function(index)
		local t = T.wake0 + 0.2 + index * 0.28
		local state = probeAt(t)
		for i = 0, 7 do
			local point = BrinejawPath.pointAt(state, i / 7)
			if point.Y < kit.waterY then
				kit.vfx.ring(Vector3.new(point.X, kit.waterY, point.Z), 2, 12, 0.9, N.glass)
			end
		end
	end)
	kit.at(6.90, function()
		kit.sfx("bossTell", breachAt)
	end)

	-- ------------------------------------------------------------ THE BREACH
	--
	-- The head crosses the plane at Entry 0.053, which this schedule reaches
	-- 0.35 s into the window. The spout and the thrown water are the FX pack's
	-- own vocabulary now (BrinejawFxPack: SpoutBase, Foam, Crest1, Crest2) -
	-- the eight Glass columns this replaces were the whole of the user's
	-- "Roblox studio objects" complaint for this boss.
	kit.at(T.breach0, function()
		kit.flash(N.glass, 0.92, 0.55)
		kit.shake(0.055, 1.0, 0.03)
		kit.sfx("bossRise", breachAt)
		kit.sfx("serpentSlam", breachAt)
		kit.vfx.splash(breachAt, 5)
		kit.vfx.ring(breachAt, 4, 54, 1.4, N.glass)

		-- The spout the head comes through: one mesh, grown from nothing at the
		-- breach point and sunk back.
		local spout = kit.mesh("BrinejawFxPack", "SpoutBase", {
			CFrame = CFrame.new(breachAt),
			Scale = 0.15,
			Transparency = 0.15,
		})
		kit.meshTween(
			spout,
			{ Scale = 2.6, CFrame = CFrame.new(breachAt + Vector3.new(0, 9, 0)) },
			T.breach0,
			T.breach0 + 0.5,
			"out"
		)
		kit.meshTween(spout, {
			Scale = 0.4,
			CFrame = CFrame.new(breachAt - Vector3.new(0, 6, 0)),
			Transparency = 1,
		}, T.breach0 + 0.5, T.breach0 + 1.6, "in")

		-- ...and the ring of thrown water round it: eight Foam meshes on their
		-- own ballistic tracks, out and down.
		for i = 1, 8 do
			local bearing = breachBearing + (i / 8) * math.pi * 2
			local foot = Vector3.new(math.cos(bearing) * 9.5, 0, math.sin(bearing) * 9.5)
			local base = breachAt + foot
			local foam = kit.mesh("BrinejawFxPack", "Foam", {
				CFrame = CFrame.new(base),
				Scale = 0.5,
				Transparency = 0.28,
			})
			kit.meshTween(foam, {
				Scale = 1.5,
				CFrame = CFrame.new(base + Vector3.new(foot.X * 0.9, 17.0, foot.Z * 0.9)),
			}, T.breach0, T.breach0 + 0.55, "out")
			kit.meshTween(foam, {
				Scale = 0.35,
				CFrame = CFrame.new(base + Vector3.new(foot.X * 2.2, -3.0, foot.Z * 2.2)),
				Transparency = 1,
			}, T.breach0 + 0.55, T.breach0 + 1.5, "in")
		end
	end)
	kit.at(T.breach0 + 0.14, function()
		kit.sfx("emerge", breachAt)
	end)

	-- ------------------------------------------------------- the dragon arc
	--
	-- Entry 0.16 -> 0.45. The apex measures y 72.58, eight studs over the
	-- broken lantern's posts, and the head comes down on the sand at r 39. The
	-- per-link splashes are marching tail-ward underneath it the whole way.
	kit.rumble(T.arc0, T.arc1, 0.008)
	kit.at(9.60, function()
		kit.sfx("serpentSweepHigh", headAt(9.60))
	end)

	-- ------------------------------------------------- the skull hits the sand
	kit.at(T.beach, function()
		local at = headAt(T.beach)
		kit.shake(0.075, 1.2, 0.05)
		kit.sfx("serpentSlam", at)
		kit.sfx("bossDown", at)
		kit.vfx.puff(at, N.sandDust, 4)
		local r = math.sqrt((at.X - kit.center.X) ^ 2 + (at.Z - kit.center.Z) ^ 2)
		kit.vfx.ring(Vector3.new(at.X, ground(r) + 0.2, at.Z), 5, 34, 1.1, N.sandDust)
		-- The wave the landing throws, as the pack's own crest rather than a
		-- slab: one out to sea behind it, one across the beach.
		for i, name in { "Crest1", "Crest2" } do
			local bearing = breachBearing + (if i == 1 then 0.35 else -0.35)
			local crest = kit.mesh("BrinejawFxPack", name, {
				CFrame = CFrame.new(at) * CFrame.Angles(0, -bearing, 0),
				Scale = 0.4,
				Transparency = 0.3,
			})
			kit.meshTween(crest, {
				Scale = 1.8,
				CFrame = CFrame.new(at + Vector3.new(math.cos(bearing) * 16, 3.0, math.sin(bearing) * 16))
					* CFrame.Angles(0, -bearing, 0),
				Transparency = 1,
			}, T.beach, T.beach + 1.1, "out")
		end
	end)

	-- ---------------------------------------------------------- THE COIL
	--
	-- Entry 0.45 -> 0.97: the head rears and climbs, first turn on the drum at
	-- 0.65, second at 0.75, third at 0.85, neck over the gallery at 0.95. The
	-- tail is still leaving the water until Entry 0.583, so for the first
	-- second of the climb the animal is simultaneously on the tower and in the
	-- sea - which is the shot.
	kit.at(13.00, function()
		kit.sfx("serpentSweepLow", kit.center)
	end)
	kit.at(15.40, function()
		kit.sfx("bossStance", kit.center)
	end)

	-- ------------------------------------------------------------ the settle
	--
	-- Entry 0.97 -> 1 over 16.4..17.3, and the skull comes down on the sand
	-- where the fight's punish window puts it (derived from `slumpPoint`, not
	-- eyeballed). `Slump` is the only other channel this script ever drives,
	-- and it is driven last: the entry branch ignores it, so it can only take
	-- effect once `Entry` is home.
	kit.track(T.slump0, T.slump1, "in", function(u)
		if stand then
			stand:set("Slump", u)
		end
	end)
	kit.at(T.settle1, function()
		kit.vfx.ring(Vector3.new(slumpSkull.X, ground(slumpSkullR) + 0.2, slumpSkull.Z), 4, 26, 1.0, N.sandDust)
	end)

	-- ----------------------------------------------------------- HANDOFF
	--
	-- The ten attributes the real boss's first rising frame publishes, said out
	-- loud - and `Entry` REMOVED, which is the eleventh and the only one that
	-- must not merely be right but must be ABSENT. CreatureService's entrenched
	-- rising branch calls `colossusState` (a fresh BrinejawPath.newState, so
	-- Coil = MAX_COIL, Unwind 0, SweepAngle 0, SweepHeight SWEEP_LOW, FaceAngle
	-- BEARING - 0.8, the attack channel clear) and then writes
	-- `slump = 1 - (1 - (1 - u)^2)`, which is 1 at u = 0. So this IS the rise's
	-- first frame.
	--
	-- 0.5 s early, because the slowest ease in the controller (Coil at 1.6/s)
	-- has to have arrived before the swap.
	--
	-- THE COLLAPSE, AND WHERE IT LANDS. `Entry` does not wait for this write.
	-- The controller treats the attribute's own 0.995 as home and collapses the
	-- EASED value to nil at 0.998, which - with the schedule above, the
	-- zero-terminal-slope last row and EASE.entry at 3.0/s - happens at
	-- t = 16.97: 0.37 s after the slump ramp starts and 0.33 s before it ends,
	-- with the skull a quarter of the way through its 26-stud descent and
	-- accelerating. That is the frame `pointAt`'s ambient breath re-enters (the
	-- entry branch returns ahead of every blend, and so ahead of the ambient
	-- too), and it is a 1.63-stud step - which is why it is put HERE rather
	-- than on a still frame. The ordering is not left to a comment:
	-- tools/check_brinejaw_entry.py parses this schedule, the controller's ease
	-- rate and its two thresholds, simulates the filter and FAILS if the
	-- collapse ever leaves the ramp.
	--
	-- The write below is still the belt: a run that reached here some other way
	-- (a skip, a late adopt - both of which the controller takes as a cut)
	-- leaves the attribute behind, and removing it is what guarantees the
	-- stand-in's last frame is computed by the fight's own code path.
	kit.at(T.handoff, function()
		if not stand then
			return
		end
		stand:set("Entry", nil)
		stand:set("Coil", BrinejawPath.MAX_COIL)
		stand:set("Unwind", 0)
		stand:set("SweepAngle", 0)
		stand:set("SweepHeight", BrinejawPath.SWEEP_LOW)
		stand:set("Slump", 1)
		stand:set("FaceAngle", restFace)
		stand:set("AttackKind", "")
		stand:set("AttackU", 0)
		stand:set("AimX", 0)
		stand:set("AimZ", 0)
	end)

	-- ------------------------------------------------------------- the roar
	--
	-- The card lands on the beat CreatureEventController already fires for a
	-- bossRise (bossRoar plus its own kick at 0.85 * riseTime), so no roar or
	-- rise cue is played from here - it would double that file's.
	kit.rumble(raiseAt, cardAt, 0.010)
	kit.track(cardAt - 0.10, cardAt + 0.50, "out", function(u)
		lampLight.Color = N.lampRed
		lampLight.Range = 40 + 90 * u
		lampLight.Brightness = 5.4 * u
		bulb.Color = N.lampRed
		bulb.Transparency = 1 - 0.95 * u
	end)
	kit.at(cardAt, function()
		local epithet = string.match(kit.boss.name, ",%s*(.+)$") or ""
		kit.card(string.upper(kit.boss.shortName), epithet, 1.4)
		kit.shake(0.09, 1.5, 0.05)
		kit.flash(N.lampRed, 0.3, 0.55)
		kit.vfx.flash(lamp, N.lampRed, 26, 0.55)
	end)

	-- ------------------------------------------------------------- camera
	--
	-- CLEARANCES. The kit does no occlusion, so every position below is checked
	-- by hand against three things: the lighthouse (radius 8.5 at the foot
	-- falling to 5.2 at SPIRE_TOP, BrinejawPath.SPIRE_DRUMS, with the gallery
	-- and the broken lantern posts reaching r ~7.6 and y ~64.6), the eight
	-- cover pieces (BossArenas.tropical.cover: the tallest is CoverStack3/4 at
	-- r 58, top world 9.11), and the beach itself (sandY, underwater past
	-- r ~71.2). No shot goes below the water plane.
	--
	-- AND FOUR OF THE SEVEN LOOK AT `headAt`, not at a point. The serpent is
	-- the subject from 7.4 onward and it crosses 178 studs of arena in 4 s; a
	-- fixed look would lose it in the first second.
	--
	-- 1. OMEN, the glassy sea. Out on open water past the floor's edge
	--    (r 126..104, the sea stacks stop at r 86) drifting in, at y 8..13.
	kit.shot({
		t0 = T.glassy0,
		t1 = T.glassy1,
		pos = kit.line(kit.polar(126, math.rad(38), cy + 8), kit.polar(104, math.rad(26), cy + 13)),
		look = lamp,
		fov = 58,
		blendIn = 0,
	})

	-- 2. THE DARK TOWER. Climbing its seaward face at r 36 -> 31, which is
	--    22..25 studs clear of the masonry at those heights, and y 15 -> 45,
	--    well over the cover field.
	kit.shot({
		t0 = T.tower0,
		t1 = T.tower1,
		pos = kit.line(kit.polar(36, math.rad(24), cy + 15), kit.polar(31, math.rad(8), cy + 45)),
		look = lamp,
		fov = 58,
		blendIn = 0.8,
	})

	-- 3. THE WAKE, out over open water on the arrival's own bearing, r 104 ->
	--    150 at y 16 -> 11. Everything the arena owns is inside r 86, so there
	--    is nothing out here to clip; the look rides the submerged head, which
	--    is 20 studs down and shows only as the swell above it.
	kit.shot({
		t0 = T.wake0,
		t1 = T.wake1,
		pos = kit.line(kit.polar(104, math.rad(250), cy + 16), kit.polar(150, math.rad(248), cy + 11)),
		look = function(_u, t)
			return headAt(t)
		end,
		fov = 62,
		blendIn = 0.9,
	})

	-- 4. THE BREACH, hard cut (blendIn 0) into the flash. Low and close on the
	--    open water 12..14 studs off the breach point, looking UP as the head
	--    comes over: r 190 -> 176 on bearings 236 -> 244, y 6 -> 34. Both ends
	--    are outside everything the arena has.
	kit.shot({
		t0 = T.breach0,
		t1 = T.breach1,
		pos = kit.line(kit.polar(190, N.seaLow, cy + 6), kit.polar(176, math.rad(244), cy + 34)),
		look = function(_u, t)
			return headAt(t)
		end,
		fov = 74,
		blendIn = 0,
	})

	-- 5. THE ARC. An orbit at r 132 / y 54 - outside the whole arena and level
	--    with the lantern room - swinging from the breach's bearing round
	--    toward the party's side as the head comes in and down.
	kit.shot({
		t0 = T.arc0,
		t1 = T.arc1,
		pos = kit.orbit(kit.center, 132, 54, math.rad(250), math.rad(300)),
		look = function(_u, t)
			return headAt(t)
		end,
		fov = 66,
		blendIn = 0.9,
	})

	-- 6. THE COIL. An orbit at r 78 / y 46 - outside the cover field and 30
	--    studs over the lantern posts - tilting UP with the climb, which is the
	--    inverse of the shot this replaces. It ends past the party's bearing so
	--    the settle can cut in from there.
	kit.shot({
		t0 = T.coil0,
		t1 = T.coil1,
		pos = kit.orbit(kit.center, 78, 46, math.rad(300), math.rad(392)),
		look = function(u)
			return Vector3.new(kit.center.X, cy + 20 + 26 * smooth(u), kit.center.Z)
		end,
		fov = 64,
		blendIn = 1.0,
	})

	-- 7. THE SETTLE. Down to the party's own ground: r 70 -> 50 on bearings
	--    20 -> 2, y 30 -> 12. The closest cover on that line is ReefStone1
	--    (r 40 at bearing 345), 16.6 studs away with the camera 5 studs over
	--    its top. Ends framing the skull on the sand.
	kit.shot({
		t0 = T.settle0,
		t1 = raiseAt,
		pos = kit.line(kit.polar(70, math.rad(20), cy + 30), kit.polar(50, math.rad(2), cy + 12)),
		look = function(u)
			return towerMid:Lerp(slumpSkull, smooth(u))
		end,
		fov = 64,
		blendIn = 1.1,
	})

	-- 8. THE RISE, from where the party stands. BossArenaService.ringPositions
	--    puts a challenger at bearing 0 on `arena.radius + 8` = r 36, facing
	--    the tower; this sits 14..18 studs behind that mark at eye height and
	--    barely moves, so the controller's 0.8 s blend into the player's own
	--    third-person frame is almost a no-op. The look rides the head up out
	--    of its slump to the neck below the lantern room.
	kit.shot({
		t0 = raiseAt,
		t1 = kit.duration,
		pos = kit.line(kit.polar(50, math.rad(2), cy + 12), kit.polar(54, N.party, cy + 14)),
		look = function(u)
			return slumpSkull:Lerp(rearThroat, smooth(u))
		end,
		fov = 68,
		blendIn = 1.2,
	})
end
