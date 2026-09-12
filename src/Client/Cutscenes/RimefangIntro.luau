--!nonstrict
-- RimefangIntro.luau
-- Rimefang's intro cinematic: THE WHALE IS THE ANIMATION.
--
-- REWRITTEN 2026-09-12 against docs/boss-cutscenes-redesign.md section 3.2.
-- The old cut was honest about its own limits and wrong about them: it drew
-- the omen with 45 Roblox primitives and moved the rig through six of its
-- twelve channels, so what the player watched was slabs. Nothing about the
-- rig needed changing to fix that - RimefangBodyController re-reads
-- `PoseCenter` EVERY FRAME (drawBody: `state.center =
-- model:GetAttribute("PoseCenter") or state.center`), which makes this the
-- one boss in the game that already travels, and the under-ice run is a
-- FIGHT MOVE (K.RF_MOVES.icebreach) rather than a cinematic invention. So
-- this file drives the fight's own channels on the fight's own curves, adds
-- the two the intro never touched (`Roll` and `FlukeUp`), and every prop that
-- is left is an imported RimefangArena mesh rather than a tinted block.
--
-- WHAT THE REWRITE ACTUALLY CHANGED, so a reader can diff it against the
-- design doc without replaying the file:
--
--   1. `Roll` is driven off the hunt curve's own turn rate. `RimefangPath`
--      applies `state.roll` in TWO places: `rollAt` (post-applied per link,
--      outside every pose weight) and `directionAt`'s TURN_MAX term (inside
--      the base weight only). Under the ice the base weight is 1, so both
--      land: the body BANKS into its turn and ARCS through it. This is the
--      difference between a whale swimming a curve and a pole swept round one.
--   2. `FlukeUp` is driven once, on the sound before the burst - the tail
--      rears through the sheet and hammers back down. It is played HERE and
--      not on the beached body on purpose; see THE LOBTAIL below.
--   3. The 45 primitives are 44 `kit.mesh` clones of RimefangArena objects
--      (`_ThinIce` for the sheet over its back and the heaved keel, `_Leads`
--      for the splits, `_Bergs`/`_ThinIce` for the thrown sheet) and one
--      light host. The pack is imported (import-checklist row 7j, 9 objects);
--      a machine without it gets `kit.mesh`'s own stand-in and one warning.
--   4. Every attribute write goes through `kit.track` (or `kit.at`), never
--      through `kit.during`. A `during` is NOT visited after `kit.fastForward`
--      - only tracks settle and only `at`s fire - so a skip through the old
--      pass left the whale wherever the last drawn frame had put it. The
--      props still ride a `during`, because a prop a skip leaves behind is
--      destroyed with the run.
--
-- THE THREE CONTRACTS THE CHANNEL OWNER FIXED, and where each one lives:
--
--   A. POSECENTER STOPS BEFORE BURST STARTS. During a burst `PoseCenter` is
--      not the head, it is the BURST POINT (Fn.rimefangCenter's own comment:
--      "burst and skyfall move the head VERTICALLY about the centre... so
--      PoseCenter comes out as exactly what the client is promised: the burst
--      point on the surface"). The fight earns that by pinning `creature.pos`
--      at the ice breach's `fire`. So the pass ends at `N.passEnd` and the
--      centre is pinned to `pD` from `N.lockBeat` - 0.7 s of dead-still ice
--      before `Burst` leaves 0, which is longer than the 0.6 s minimum and
--      is also the beat the lock ring wants.
--   B. SUBMERGE IS HELD AT 1 FOR THE WHOLE RUN and bled to 0 over the part of
--      BURST THE FIGHT BLEEDS IT OVER - not over a slice of the window, and
--      not over a number picked for the cinematic. `K.RF_MOVES.icebreach`
--      sheds the depth across `rise / duration` of its strike (0.2 / 0.7),
--      and the fight's own climb puts `burst` at 0.4890 there; `submergeShed`
--      is SOLVED from that and `timeOfBurst` inverts the ease this file
--      registered, so the drawn Burst reaches the fight's value exactly as
--      Submerge reaches 0 and a retune of the row moves both. The body bursts
--      OUT of the water rather than being teleported to the surface under it.
--   C. BURST = 1 IS BEACHED = 1. The handoff drives `Beached` 0 -> 1 while
--      `Burst` goes 1 -> 0 in lockstep over one window with one ease, so the
--      shape never moves and `Burst` is never dropped alone. That is the
--      contract `RimefangPath`'s header states and the recover phase of
--      `K.RF_MOVES.icebreach` performs.
--
-- THE LOBTAIL, and the one design-vs-code mismatch worth stating in the file
-- rather than only in NOTES.md. Section 3.2 asks for a lobtail at 12.4-14.0,
-- on the beached body. `FlukeUp` CANNOT DRAW THERE. `RimefangPath.directionAt`
-- adds `flukePitch` inside `if wBase > 0`, and `wBase = 1 - (wRise + wBeach +
-- wBurst + wArch + wSky)`, so at `Beached = 1` the fluke swing is multiplied
-- by zero: the attribute would move and the body would not. So the tail beat
-- is played at 6.3-8.0, where `wBase` is 1 (submerged cruise) and the swing
-- is the sound before the eruption, and the beached beat is instead made of
-- the two channels that DO draw through `wBeach`: `Gape` (the jaw is the
-- controller's, not the path's, and is pose-independent) and `Roll` (post-
-- applied in `rollAt`, outside every weight, on top of the automatic
-- BEACHED_ROLL rock). A roar on the ice, and the body heaving over onto its
-- flank.
--
-- THE HANDOFF, stated out loud rather than left where the tweens stopped.
-- `Fn.rimefangDrive`'s rising branch publishes, at progress 0:
--   Submerge = 1 (1 - modeProgress), Swim = 1, FaceAngle = creature.yaw0 = 0,
--   Rise/Roll/Arch/Burst/Skyfall/Beached/FlukeUp/Gape/Lunge = 0,
--   PoseCenter = Fn.rimefangCenter(state, creature.pos).
-- That last one is `creature.pos` EXACTLY for this pose and not merely near
-- it: `Fn.rimefangCenter` returns `at - flat(pointAt(state, 0))` evaluated
-- about a zero centre, and `anchorOf`'s base branch is `center - UP *
-- submergeDepth(submerge)` - purely vertical - so the flat part is zero and
-- the centre IS the anchor point, which for a freshly raised boss is its own
-- arena anchor, i.e. `kit.center`. So the sink below lands on the rise's
-- first frame arithmetically, not approximately.
--
-- Beats: OMEN    0 - 8.4  (the blow, the shadow under the sheet, the sound)
--        REVEAL  8.4 - 14.0 (the eruption, the crash, the roar on the ice)
--        ROAR    14.0 - 20 (it takes the water back, the real rise, the card)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RimefangPath = require(Shared.Modules.RimefangPath)

-- Every number the cinematic is tuned on, in one place. The geometry ones are
-- authored Floe values (assets/arena_gen.py), the pose ones mirror the
-- fight's own icebreach, and nothing below is repeated anywhere else in the
-- file; a retune is an edit here and nowhere else.
local N = {
	-- The Pose attribute the body controller adopts on: RimefangBodyController
	-- POSE_KEY, = CreatureService's K.RIMEFANG_BOSS. The Bosses row carries no
	-- `pose` field, so this is the literal both sides already use.
	pose = "rimefang",

	-- The hunt curve, as a quadratic Bezier in the arena's own plane: it comes
	-- in from open water beyond the whaler (RF_HULL is r 152 at 200 degrees),
	-- runs straight under the hull, crosses the pressure ridge and swings onto
	-- the burst point. Radii are authored Floe numbers: RF_FLOOR_R 120,
	-- RF_RIDGE_R 122-132, the torn edge at 166.
	startR = 164,
	ctrlR = 120,
	burstR = 30,
	burstTurn = 0.85, -- radians the curve swings off the hull bearing
	hullDeg = 200, -- RF_HULL bearing, authored degrees
	hullR = 152,
	bergDeg = 62, -- RF_BERGS[1], for the cold rim light on the roar
	bergR = 150,
	edgeR = 166, -- past this the sheet is gone, so the meshes are too

	-- The pass, in seconds, and the acceleration curve along it: stalking,
	-- then it has decided. It ENDS at 7.7 rather than at the burst, which is
	-- contract A above - 0.7 s of still ice before Burst leaves 0.
	passStart = 0.8,
	passEnd = 7.7,
	passEase = 1.35,
	hullBeat = 2.6, -- when the curve is at r 151, i.e. under the whaler
	lockBeat = 7.7, -- PoseCenter pinned to the burst point from here

	-- THE SOUND. The tail rears through the sheet and hammers back down,
	-- inside the submerged cruise where `wBase` is 1 and the swing draws.
	-- `flukeUp` is PROGRESS through the whole swing, not a lift: 1 is reared
	-- (RimefangPath FLUKE_RISE, tip at +19.0), it crosses its rest line at
	-- 0.45 and punches deepest near 0.22, and the fight drives 1 -> 0 in
	-- 0.15 s. So rear slowly, hammer fast, settle.
	flukeRear = 6.3,
	flukeTop = 7.15,
	flukeHit = 7.4,
	flukeRest = 8.0,
	flukePunch = 0.22,

	-- The eruption, mirroring K.RF_MOVES.icebreach at cinematic speed.
	burstT0 = 8.4,
	burstImpact = 0.55, -- K.RF_BURST_IMPACT: the apex, where the roar peaks
	burstEnd = 11.0,
	-- CONTRACT B, and THE FIGHT IS THE SOURCE OF TRUTH FOR IT. The burst VALUE
	-- at which Submerge has finished bleeding out is not a cinematic choice:
	-- `K.RF_MOVES.icebreach`'s strike sheds the depth over `rise` of its
	-- `duration` seconds - `pose.submerge = 1 - smootherstep(min(u * dur /
	-- rise, 1))` - so the shed ends at strike u = rise / duration, and the
	-- burst value there is whatever the fight's own curve says. These two are
	-- the ONLY numbers typed for it, and they are quoted straight off
	-- `Bosses.items.rimefang.attacks.icebreach`; the burst value itself is
	-- SOLVED below (`submergeShed`) off these and `burstImpact`, so a retune of
	-- the row moves the shed with it and there is no second copy to go stale.
	icebreachRise = 0.2, -- icebreach.rise: seconds to shed the submerge
	icebreachStrike = 0.7, -- icebreach.duration: the strike phase's length
	landEnd = 12.0, -- Burst 1 -> 0 and Beached 0 -> 1, in lockstep

	-- The roar on the ice: the two channels that draw through `wBeach`.
	roarStart = 12.4,
	roarPeak = 12.9,
	roarEnd = 13.8,
	roarGape = 0.85,
	heaveRoll = math.rad(12), -- on TOP of the path's automatic BEACHED_ROLL

	sinkStart = 14.0,
	sinkEnd = 15.6,

	-- The bank under the ice, from the curve's own turn rate. `rollAt`'s
	-- profile is full at the head and 30% by the flukes, and `directionAt`
	-- arcs the body in proportion, so this is a real turn and not a tilt.
	rollMax = math.rad(22),
	rollGain = 2.6, -- radians of bank per radian of bearing change per unit s
	rollHold = 0.88, -- ...and level again over the last 12% of the pass

	-- The drawn shape under the ice: eight stations down a 56-stud body
	-- (RimefangPath.BODY_LENGTH), widths off the girth curve's shape - full
	-- past mid-body, then the peduncle pinch, then the flukes.
	slabs = 8,
	slabPitch = 7.2,
	slabLength = 9.5,
	slabWidth = { 6.4, 9.6, 10.8, 11.0, 10.0, 7.6, 4.6, 6.8 },

	cracks = 12,
	shards = 18,
	gravity = 42,
}

-- THE PALETTE, and why it is passed to `kit.mesh` rather than left to the
-- import. `kit.mesh` repaints a clone from `MeshColors.get` and then applies
-- the caller's props over the top, so a `Color` here WINS over the pack's own
-- row - which is deliberate: these four props are also the props the
-- no-import fallback slab is built from, and passing them keeps that slab
-- byte-identical to the one this cinematic drew before the pack existed. The
-- values are the arena's own ice blues, so the override is a shade, not a
-- repaint. (Listed in NOTES.md as a deliberate deviation.)
local C = {
	sheet = Color3.fromRGB(196, 226, 244), -- lit through the ice
	split = Color3.fromRGB(71, 107, 140), -- a lead: dark, because a crack is
	shard = Color3.fromRGB(214, 234, 246), -- the sheet, thrown
	lamp = Color3.fromRGB(150, 205, 235),
	spray = Color3.fromRGB(226, 240, 250),
	quake = Color3.fromRGB(150, 195, 225),
	lock = Color3.fromRGB(120, 175, 210),
	rim = Color3.fromRGB(180, 220, 245),
	card = Color3.fromRGB(232, 244, 255),
}

return function(kit)
	-- ------------------------------------------------------------ geometry
	local hullB = kit.authored(N.hullDeg)
	local iceIn = kit.floorY(60, hullB) -- the fight floor: RF_PROFILE's flat 2.60
	local iceOut = kit.floorY(146, hullB) -- the outer pack the backdrop stands on
	local iceRing = kit.floorY(78, 0) -- under the party's drop-in ring

	-- The sheet's height at an arena radius. RF_PROFILE is flat to 120 and then
	-- steps down across the ridge foot to the outer pack, so two probes and a
	-- ramp between them is the whole surface the camera and the meshes need.
	local function sheetY(radius: number): number
		return iceIn + (iceOut - iceIn) * math.clamp((radius - 118) / 28, 0, 1)
	end

	local pA = kit.polar(N.startR, hullB, kit.center.Y)
	local pC = kit.polar(N.ctrlR, hullB, kit.center.Y)
	local pD = kit.polar(N.burstR, hullB + N.burstTurn, kit.center.Y)

	-- Progress along the hunt curve at cutscene time `t`. IDENTICAL by
	-- construction to the eased `u` the pass TRACK below is handed - the kit's
	-- numeric ease is `u ^ ease` and this is the same expression - so the props
	-- drawn from `t` and the attributes written from `u` cannot disagree. That
	-- equality is the reason the pass is a track at all: a `during` is not
	-- visited after a skip, and the whale would stop where the last frame left
	-- it (see the header, point 4).
	local function passS(t: number): number
		return math.clamp((t - N.passStart) / (N.passEnd - N.passStart), 0, 1) ^ N.passEase
	end

	local function passPoint(s: number): Vector3
		local a, b, c = (1 - s) * (1 - s), 2 * (1 - s) * s, s * s
		return Vector3.new(pA.X * a + pC.X * b + pD.X * c, kit.center.Y, pA.Z * a + pC.Z * b + pD.Z * c)
	end

	local function passDir(s: number): Vector3
		local d = (pC - pA) * (2 * (1 - s)) + (pD - pC) * (2 * s)
		local flat = Vector3.new(d.X, 0, d.Z)
		return if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(1, 0, 0)
	end

	-- RimefangPath.heading: forward = (cos yaw, 0, -sin yaw), the same
	-- convention CreatureService.bossFacing and yawToward use.
	local function yawOf(dir: Vector3): number
		return math.atan2(-dir.Z, dir.X)
	end

	-- THE BANK, from the curve and nothing else. The bearing's rate of change
	-- per unit of `s`, signed by which way it swings, scaled and clamped. A
	-- Bezier's turn is smooth, so this needs no filter.
	--
	-- ...and it UNWINDS over the last of the pass, so the body is level and
	-- still before the sheet gives way. Folded in here rather than written as
	-- a second tween on `Roll`, because two writers on one channel over one
	-- window is decided by registration order, and this file should not need a
	-- reader to know what that order was.
	local function passRoll(s: number): number
		local step = 0.02
		local a = yawOf(passDir(math.max(s - step, 0)))
		local b = yawOf(passDir(math.min(s + step, 1)))
		local delta = math.atan2(math.sin(b - a), math.cos(b - a)) / (2 * step)
		local level = 1 - math.clamp((s - N.rollHold) / (1 - N.rollHold), 0, 1)
		return math.clamp(delta * N.rollGain, -N.rollMax, N.rollMax) * level
	end

	local function radiusOf(point: Vector3): number
		return (Vector3.new(point.X, kit.center.Y, point.Z) - kit.center).Magnitude
	end

	-- The point on the sheet directly over the swimming head.
	local function surfaceAt(t: number): Vector3
		local point = passPoint(passS(t))
		return Vector3.new(point.X, sheetY(radiusOf(point)) + 0.05, point.Z)
	end

	local burstSurface = Vector3.new(pD.X, sheetY(N.burstR), pD.Z)
	local hullPos = kit.landmark("Hull")
	local hullFoot = if hullPos
		then Vector3.new(hullPos.X, sheetY(N.hullR), hullPos.Z)
		else kit.polar(N.hullR, hullB, sheetY(N.hullR))
	local bergPos = kit.landmark("Bergs")
	local bergAt = bergPos or kit.polar(N.bergR, kit.authored(N.bergDeg), sheetY(N.bergR) + 14)

	local faceIn = yawOf(passDir(1))
	local pdBearing = math.atan2(pD.Z - kit.center.Z, pD.X - kit.center.X)

	-- ------------------------------------------------- the burst curve, solved
	-- The two halves of the fight's own eruption: out to the apex at
	-- K.RF_BURST_IMPACT, then in to the landing. Written here as functions of
	-- cutscene time because the CAMERA and contract B both need to ask the
	-- curve questions, and a second copy of the shape is how this codebase
	-- grows a stale number.
	local burstApex = N.burstT0 + N.burstImpact * (N.burstEnd - N.burstT0)

	-- `kit`'s "out" ease is 1 - (1-u)^2 and its "in" ease is u^2, which is what
	-- the tweens below are registered with, so this IS the drawn curve.
	local function burstAt(t: number): number
		if t <= N.burstT0 then
			return 0
		end
		if t >= N.burstEnd then
			return 1
		end
		if t <= burstApex then
			local u = (t - N.burstT0) / (burstApex - N.burstT0)
			return N.burstImpact * (1 - (1 - u) * (1 - u))
		end
		local u = (t - burstApex) / (N.burstEnd - burstApex)
		return N.burstImpact + (1 - N.burstImpact) * u * u
	end

	-- ...and its inverse on the climb, which is the only place contract B
	-- asks. Solved rather than measured: 1 - (1-u)^2 = b / IMPACT.
	local function timeOfBurst(value: number): number
		local ratio = math.clamp(value / N.burstImpact, 0, 1)
		local u = 1 - math.sqrt(1 - ratio)
		return N.burstT0 + u * (burstApex - N.burstT0)
	end

	-- CONTRACT B, solved. Where the FIGHT's shed ends, expressed as a burst
	-- value: the strike fraction is `icebreach.rise / icebreach.duration`
	-- (0.2 / 0.7 = 0.2857), and the fight's climb is
	-- `pose.burst = IMPACT * easeOutCubic(u / IMPACT)` - a CUBIC ease-out,
	-- which is the shape `K.RF_MOVES.icebreach` uses and therefore the one
	-- that has to be evaluated here, even though this cinematic's own climb is
	-- registered with the kit's quadratic "out". So:
	--   burst at the shed's end = 0.55 * (1 - (1 - 0.2857/0.55)^3) = 0.4890
	-- ...which is then handed to `timeOfBurst`, the inverse of the ease this
	-- file actually registered, so the DRAWN Burst reaches the fight's value
	-- exactly as Submerge reaches 0. Two curves, one number, and the number is
	-- the fight's.
	local shedStrikeU = N.icebreachRise / N.icebreachStrike
	local submergeShed = N.burstImpact * (1 - (1 - shedStrikeU / N.burstImpact) ^ 3)
	local submergeEnd = timeOfBurst(submergeShed)

	-- ------------------------------------------------- where the body will be
	-- The camera's aim points, taken from the path module rather than from a
	-- literal. `newState` + one field is exactly what the controller eases to,
	-- so "the apex" and "the skull on the ice" are the path's own answers and
	-- move when it is retuned. `time` stays 0, so the swim wave is sampled at
	-- one phase - worth about a stud on a 56-stud animal, and the camera is
	-- tens of studs away.
	local function poseHead(fields): Vector3
		local state = RimefangPath.newState(pD)
		for key, value in fields do
			state[key] = value
		end
		return RimefangPath.pointAt(state, 0)
	end

	local apexHead = poseHead({ faceAngle = faceIn, swim = 1, burst = N.burstImpact })
	local landedHead = poseHead({ faceAngle = faceIn, swim = 0.25, burst = 1 })
	local beachedHead = poseHead({ faceAngle = faceIn, swim = 0.25, beached = 1 })

	-- ------------------------------------------------------------ the actor
	-- Born already under the ice and already pointing down the curve: the
	-- controller eases FaceAngle at rate 5, and starting it at 0 would spend
	-- the first second of the omen swinging a body nobody can see anyway.
	local whale = kit.actor({
		pose = N.pose,
		center = passPoint(0),
		attrs = {
			Swim = 1,
			Submerge = 1,
			FaceAngle = yawOf(passDir(0)),
			Rise = 0,
			Roll = passRoll(0),
			Arch = 0,
			Burst = 0,
			Skyfall = 0,
			Beached = 0,
			FlukeUp = 0,
			Gape = 0,
			Lunge = 0,
		},
	})
	kit.onRealBoss(function()
		whale:destroy()
	end)

	-- ------------------------------------------------- the sheet over its back
	-- Eight patches of the arena's own young ice (`RimefangArena_ThinIce`),
	-- laid ON the sheet along the body's own stations: the ice BULGES over the
	-- whale instead of glowing. `Size` is passed so the imported geometry is
	-- squashed into the station's footprint - the shape is the pack's, the
	-- silhouette is the body's - and so the no-import fallback is exactly the
	-- slab this drew before (see the C table's note).
	local sheet = {}
	for i = 1, N.slabs do
		sheet[i] = kit.mesh("RimefangArena", "ThinIce", {
			Size = Vector3.new(N.slabWidth[i], 0.16, N.slabLength),
			CFrame = CFrame.new(pA),
			Color = C.sheet,
			Material = Enum.Material.Ice,
			Transparency = 1,
		})
	end
	local lamp = kit.light(pA, C.lamp, 74, 0)
	local lampHost = lamp.Parent

	kit.during(0.5, N.burstT0, function(_u, _dt, t)
		local s = passS(t)
		local head, dir = passPoint(s), passDir(s)
		-- It surfaces INTO view: far out the sheet is thick pack and the shape
		-- is a rumour; by the time it is inside the ridge you can count it.
		local near = 1 - math.clamp((radiusOf(head) - 40) / 110, 0, 1)
		for i = 1, N.slabs do
			local back = head - dir * ((i - 0.5) * N.slabPitch)
			local radius = radiusOf(back)
			local slab = sheet[i]
			if radius > N.edgeR then
				slab.Transparency = 1
			else
				local y = sheetY(radius) + 0.05
				local at = Vector3.new(back.X, y, back.Z)
				slab.CFrame = CFrame.lookAt(at, at + dir)
				slab.Transparency = 1 - (0.28 + 0.34 * near) * math.clamp((t - 0.5) / 1.2, 0, 1)
			end
		end
		local over = surfaceAt(t)
		lampHost.CFrame = CFrame.new(over + Vector3.new(0, 1.6, 0))
		lamp.Brightness = 2.4 * near
	end)

	-- They go out the instant the sheet does - after the eruption there is
	-- nothing left to be lit through.
	kit.at(N.burstT0 + 0.12, function()
		for i = 1, N.slabs do
			sheet[i].Transparency = 1
		end
		lamp.Brightness = 0
	end)

	-- ------------------------------------------------------------ the splits
	-- Twelve leads, each born where the head was when it was born, and none of
	-- them ever heals: ice that has been opened stays open, and by the
	-- eruption the whole run-in is written on the floor. `RimefangArena_Leads`
	-- is the arena's own open-water lead object, which is the thing a split in
	-- the sheet IS.
	for i = 0, N.cracks - 1 do
		local born = 2.6 + i * 0.42
		local s = passS(born)
		local at = surfaceAt(born)
		local skew = (if i % 2 == 0 then 1 else -1) * (0.5 + 0.06 * i)
		local dir = passDir(s)
		local lead = kit.mesh("RimefangArena", "Leads", {
			Size = Vector3.new(0.7, 0.14, 3),
			CFrame = CFrame.lookAt(at, at + dir) * CFrame.Angles(0, skew, 0),
			Color = C.split,
			Material = Enum.Material.Slate,
			Transparency = 1,
		})
		kit.meshTween(lead, { Transparency = 0.24 }, born, born + 0.16)
		kit.meshTween(lead, { Size = Vector3.new(0.7, 0.14, 18 + 1.4 * i) }, born, born + 0.9, "out")
	end

	-- ------------------------------------------------------------- the shards
	-- The sheet, thrown: bergs and young ice off the same arena pack, on
	-- ballistic arcs. Pre-built and flown by one `during` rather than spawned
	-- from a callback - a track registered mid-step would be inserted into the
	-- list the kit is walking.
	local shards = {}
	for k = 1, N.shards do
		local angle = k * 2.39996 -- the golden angle: even scatter, no rng
		shards[k] = {
			part = kit.mesh("RimefangArena", if k % 2 == 0 then "Bergs" else "ThinIce", {
				Size = Vector3.new(1.6 + (k % 4) * 0.9, 0.5, 2.4 + (k % 5) * 1.1),
				CFrame = CFrame.new(burstSurface),
				Color = C.shard,
				Material = Enum.Material.Ice,
				Transparency = 1,
			}),
			dir = Vector3.new(math.cos(angle), 0, math.sin(angle)),
			out = 6 + 13 * ((k % 7) / 6),
			up = 24 + 11 * ((k % 5) / 4),
			at = N.burstT0 + 0.08 + (k % 3) * 0.05,
			spin = 2.0 + (k % 6) * 0.5,
		}
	end

	kit.during(N.burstT0, N.sinkEnd, function(_u, _dt, t)
		for _, shard in shards do
			local age = t - shard.at
			if age <= 0 then
				shard.part.Transparency = 1
			else
				local y = shard.up * age - 0.5 * N.gravity * age * age
				local at = burstSurface + shard.dir * (shard.out * age) + Vector3.new(0, y, 0)
				local rest = sheetY(radiusOf(at)) + 0.24
				local down = at.Y <= rest
				shard.part.CFrame = if down
					then CFrame.new(Vector3.new(at.X, rest, at.Z)) * CFrame.Angles(0, shard.spin, 0)
					else CFrame.new(at) * CFrame.Angles(age * shard.spin, age * 1.7, age * shard.spin * 0.6)
				shard.part.Transparency = math.clamp((age - 2.2) / 1.1, 0, 1)
			end
		end
	end)

	-- ------------------------------------------------------- the whaler heaves
	-- The Hull is authored arena geometry and belongs to the arena, so it is
	-- not mine to tilt; what CAN say "something enormous just went under it" is
	-- its own footing coming up. Six patches of the sheet around the keel,
	-- lifted and dropped on the beat the curve crosses r 151.
	for i = 1, 6 do
		local angle = i * 1.047
		local at = hullFoot + Vector3.new(math.cos(angle) * (7 + i), 0, math.sin(angle) * (7 + i))
		local heave = kit.mesh("RimefangArena", "ThinIce", {
			Size = Vector3.new(6 + i, 0.9, 5 + i * 0.6),
			CFrame = CFrame.new(at) * CFrame.Angles(0, angle, 0),
			Color = C.shard,
			Material = Enum.Material.Ice,
			Transparency = 0.1,
		})
		kit.meshTween(
			heave,
			{ CFrame = CFrame.new(at + Vector3.new(0, 1.5 + i * 0.2, 0)) * CFrame.Angles(0.12, angle, 0.09) },
			N.hullBeat,
			N.hullBeat + 0.55,
			"out"
		)
		kit.meshTween(heave, { Transparency = 1 }, N.hullBeat + 1.4, N.hullBeat + 2.6)
	end

	-- --------------------------------------------------------------- the poses
	--
	-- THE HUNT. One track, three channels, and the eased `u` it is handed is
	-- `passS` by construction (see `passS`). `PoseCenter` walks the curve, the
	-- heading follows the tangent, and `Roll` follows the turn - which is the
	-- one channel that makes this read as an animal swimming rather than a
	-- prop being slid. `Submerge` is NOT written here: it was stamped at 1 on
	-- the actor and stays there for the whole run, which is contract B's first
	-- half.
	kit.track(N.passStart, N.passEnd, N.passEase, function(s)
		whale:set("PoseCenter", passPoint(s))
		whale:set("FaceAngle", yawOf(passDir(s)))
		whale:set("Roll", passRoll(s))
	end)

	-- THE SOUND, at 6.3-8.0: the tail rears through the sheet and hammers
	-- down. Inside the pass, so `wBase` is 1 and the swing actually draws
	-- (see the header's LOBTAIL note).
	whale:tween("FlukeUp", 0, 1, N.flukeRear, N.flukeTop, "out")
	whale:tween("FlukeUp", 1, N.flukePunch, N.flukeTop, N.flukeHit, "in")
	whale:tween("FlukeUp", N.flukePunch, 0, N.flukeHit, N.flukeRest, "inout")

	-- CONTRACT A, said in code: from `lockBeat` the centre is the BURST POINT
	-- and it does not move again until the sink. `kit.at` rather than a track,
	-- because a value that must be exact at a named instant is an event, and
	-- a skip fires it.
	kit.at(N.lockBeat, function()
		whale:set("PoseCenter", pD)
		whale:set("FaceAngle", faceIn)
		whale:set("Roll", 0)
	end)
	-- THE ERUPTION, on the fight's own numbers. `burstAt` above is this pair
	-- of tweens read as a function; if either is retuned the other follows.
	whale:tween("Burst", 0, N.burstImpact, N.burstT0, burstApex, "out")
	whale:tween("Burst", N.burstImpact, 1, burstApex, N.burstEnd, "in")

	-- CONTRACT B: held at 1 for the whole run, then bled out over the same part
	-- of Burst the fight bleeds it over - `submergeEnd` is SOLVED from
	-- icebreach's own `rise / duration` above, not typed here.
	whale:tween("Submerge", 1, 0, N.burstT0, submergeEnd, "inout")

	-- CONTRACT 4 (the roar): ~0.15 on launch, wide open on the way up, and
	-- SHUT before the body lands. The fight's own gape peaks at 0.9 halfway up
	-- and returns to 0.2 at the apex; the channel owner's cinematic shape is
	-- 0.15 -> 1 and closed by the landing, which is what is written here (the
	-- difference is listed in NOTES.md).
	whale:tween("Gape", 0, 0.15, N.lockBeat, N.burstT0, "out")
	whale:tween("Gape", 0.15, 1, N.burstT0, burstApex - 0.5, "out")
	whale:tween("Gape", 1, 0, burstApex - 0.5, N.burstEnd - 0.3, "in")

	-- CONTRACT C: `Burst = 1` and `Beached = 1` are the same body, so this
	-- crossfade moves nothing and only changes which channel owns the shape.
	-- ONE window, ONE ease, both directions - `Burst` is never dropped alone.
	whale:tween("Beached", 0, 1, N.burstEnd, N.landEnd, "inout")
	whale:tween("Burst", 1, 0, N.burstEnd, N.landEnd, "inout")
	whale:tween("Swim", 1, 0.25, N.burstEnd, N.landEnd, "inout")

	-- THE ROAR ON THE ICE. `Gape` is drawn by the controller's jaw and is
	-- pose-independent; `Roll` is post-applied in `rollAt` outside every pose
	-- weight, so it heaves the beached body over onto its flank on top of the
	-- path's own BEACHED_ROLL rock. These are the only two channels that draw
	-- at `Beached = 1`, which is why the design's lobtail moved earlier.
	whale:tween("Gape", 0, N.roarGape, N.roarStart, N.roarPeak, "out")
	whale:tween("Gape", N.roarGape, 0, N.roarPeak, N.roarEnd, "in")
	whale:tween("Roll", 0, N.heaveRoll, N.roarStart, N.roarPeak + 0.3, "out")
	whale:tween("Roll", N.heaveRoll, 0, N.roarPeak + 0.3, N.sinkStart, "inout")

	-- ...and then it takes itself back. Everything below lands on exactly the
	-- frame `Fn.rimefangDrive`'s rising branch publishes at progress 0 - see
	-- THE HANDOFF in the header for why `kit.center` is that frame's
	-- `PoseCenter` arithmetically rather than approximately.
	whale:tween("Beached", 1, 0, N.sinkStart, N.sinkEnd, "inout")
	whale:tween("Submerge", 0, 1, N.sinkStart, N.sinkEnd, "inout")
	whale:tween("Swim", 0.25, 1, N.sinkStart, N.sinkEnd, "inout")
	whale:tween("FaceAngle", faceIn, 0, N.sinkStart, N.sinkEnd, "inout")
	whale:tween("PoseCenter", pD, kit.center, N.sinkStart, N.sinkEnd, "inout")

	-- THE HANDOFF FRAME, written as values and not as the ends of tweens. The
	-- slowest ease among these is `submerge` at 3.2/s, which the 1.6 s sink
	-- closes to 0.6%, and this lands 0.6 s before `raiseAt` so the drawn body
	-- is already there when the server's first rising frame arrives.
	kit.at(N.sinkEnd, function()
		whale:set("Swim", 1)
		whale:set("Submerge", 1)
		whale:set("FaceAngle", 0)
		whale:set("PoseCenter", kit.center)
		whale:set("Rise", 0)
		whale:set("Roll", 0)
		whale:set("Arch", 0)
		whale:set("Burst", 0)
		whale:set("Skyfall", 0)
		whale:set("Beached", 0)
		whale:set("FlukeUp", 0)
		whale:set("Gape", 0)
		whale:set("Lunge", 0)
	end)

	-- ...and the opening pose, said out loud. Every value below MUST equal its
	-- `attrs` entry on the actor; if the two ever disagree, `attrs` is the one
	-- that runs (`Actor:tween` stamps its `from` only onto an attribute
	-- nothing has set yet). Kept because a reader should be able to find the
	-- t = 0 frame - the hunt, under the ice, already pointing down the curve,
	-- already banked into the first turn - without replaying twenty tweens.
	whale:set("Swim", 1)
	whale:set("Submerge", 1)
	whale:set("Burst", 0)
	whale:set("Beached", 0)
	whale:set("FlukeUp", 0)
	whale:set("Gape", 0)
	whale:set("Roll", passRoll(0))
	whale:set("FaceAngle", yawOf(passDir(0)))
	whale:set("PoseCenter", passPoint(0))

	-- ------------------------------------------------------------ sound & feel
	kit.at(0.25, function()
		-- The blow, out past the ridge: the one thing the floe hears before it
		-- feels anything.
		kit.sfx("rimeSpout", kit.polar(N.startR, hullB, sheetY(N.startR) + 1))
		kit.vfx.puff(kit.polar(N.startR, hullB, sheetY(N.startR) + 2), C.spray, 2.2)
	end)
	kit.rumble(1.2, N.burstT0, 0.006)
	kit.every(2.4, N.burstT0 - 0.2, 0.9, function()
		kit.sfx("rimeCrackWeb", surfaceAt(kit.t))
	end)

	kit.at(N.hullBeat, function()
		kit.sfx("rimeQuake", hullFoot)
		kit.shake(0.032, 1.1)
		kit.vfx.ring(hullFoot + Vector3.new(0, 0.3, 0), 4, 26, 1.4, C.quake)
	end)

	-- THE TAIL THROUGH THE SHEET. The fluke tip rears to +19 studs from 18
	-- studs down, so it comes out where the body's rear station is.
	kit.at(N.flukeTop, function()
		local tail = surfaceAt(N.flukeTop)
		local back = tail - passDir(passS(N.flukeTop)) * (RimefangPath.BODY_LENGTH * 0.86)
		local at = Vector3.new(back.X, sheetY(radiusOf(back)), back.Z)
		kit.sfx("rimeFlukeSlam", at)
		kit.sfx("rimeFloeCrack", at)
		kit.shake(0.042, 0.9)
		kit.vfx.splash(at, 2.6)
		kit.vfx.ring(at + Vector3.new(0, 0.3, 0), 2, 22, 0.9, C.quake)
	end)

	kit.at(N.burstT0 - 0.6, function()
		-- The lock: the ground is chosen. The fight's own "MOVE" beat.
		kit.sfx("rimeCrackLock", burstSurface)
		kit.vfx.ring(burstSurface + Vector3.new(0, 0.3, 0), 2, 16, 0.6, C.lock)
	end)
	kit.at(N.burstT0, function()
		kit.sfx("rimeBreachLaunch", burstSurface)
		kit.sfx("rimeIceBurst", burstSurface)
		kit.sfx("rimeFloeCrack", burstSurface)
		kit.shake(0.055, 1.0)
		kit.vfx.shockwave(burstSurface + Vector3.new(0, 0.4, 0), 3, 54, 1.1, C.spray, 0.4)
		kit.vfx.burst(burstSurface + Vector3.new(0, 2, 0), C.spray, 22)
	end)
	kit.at(N.burstEnd, function()
		kit.sfx("rimeBreachCrash", burstSurface)
		kit.sfx("rimeShock", burstSurface)
		kit.shake(0.085, 1.35)
		kit.flash(C.spray, 0.3, 0.6)
		kit.vfx.shockwave(burstSurface + Vector3.new(0, 0.4, 0), 6, 88, 1.5, C.spray, 0.5)
		kit.vfx.splash(burstSurface, 3.4)
	end)
	kit.at(N.roarStart, function()
		kit.sfx("rimeThrash", landedHead)
		kit.sfx("rimeSpyHop", beachedHead)
		kit.shake(0.05, 1.2, 0.03)
		kit.vfx.puff(beachedHead + Vector3.new(0, 2, 0), C.spray, 3.2)
	end)
	kit.at(N.sinkStart, function()
		-- It lets the floe go and takes the water back. The wash cue is the
		-- longest low thing in the catalogue and carries the whole slide under.
		kit.sfx("rimeWash", burstSurface)
		kit.vfx.ring(burstSurface + Vector3.new(0, 0.3, 0), 10, 40, 2.0, C.quake)
	end)

	-- ---------------------------------------------------------------- the roar
	-- The card lands on the beat CreatureEventController's bossRise handler
	-- already fires (0.85 * riseTime into the real rise): one roar, one shake,
	-- one title. The frost is the flash - there is no vignette to paint with.
	local cardAt = kit.raiseAt + 0.85 * kit.riseTime
	local berg = kit.light(bergAt, C.rim, 180, 0)
	kit.at(cardAt, function()
		kit.card(string.upper(kit.boss.shortName), "the Glacier Serpent")
		kit.shake(0.075, 1.3, 0.05)
		kit.flash(C.card, 0.62, 1.5)
		berg.Brightness = 3
	end)

	-- ------------------------------------------------------------- the camera
	-- Every shot stays inside r 120 (the whole fight floor is bare, HANDOFF:
	-- "NOTHING stands inside r 120"), or out on the pack at r 133-150 - past
	-- the ridge crest at 122-132 and 12+ studs short of the whaler's 19-stud
	-- half-length - or high enough over the sheet that nothing reaches it.
	-- Nothing is ever below the sheet.
	kit.shot({
		t0 = 0,
		t1 = 3.4,
		-- Low on the ice looking seaward past the whaler, with the shape sliding
		-- between the lens and the hull.
		pos = kit.line(kit.polar(140, hullB + 0.26, iceOut + 1.5), kit.polar(133, hullB + 0.18, iceOut + 3.2)),
		look = function(_u, t)
			return surfaceAt(t)
		end,
		fov = 62,
	})
	kit.shot({
		t0 = 3.4,
		t1 = 7.0,
		-- THE RUN, SEEN FROM ABOVE. The one shot that shows the bank: from
		-- r 150 / y 90 the whole curve is in frame and the body's arc through
		-- its own turn is the subject. Long lens, because the animal is 90
		-- studs below and 56 studs long.
		pos = kit.orbit(kit.center, 150, 90, hullB + 0.30, hullB + 0.72),
		look = function(_u, t)
			return surfaceAt(t)
		end,
		fov = 52,
		blendIn = 0.8,
	})
	kit.shot({
		t0 = 7.0,
		t1 = N.burstT0,
		-- IT SOUNDS. Dropping to the sheet behind the animal as the fluke comes
		-- up through it, and holding on the still ice over the lock point.
		pos = kit.arc(kit.polar(104, hullB + 0.58, iceIn + 34), kit.polar(62, hullB + 0.74, iceIn + 9), 14),
		look = function(_u, t)
			return surfaceAt(math.min(t, N.passEnd))
		end,
		fov = 66,
		blendIn = 0.9,
	})
	kit.shot({
		t0 = N.burstT0,
		t1 = N.burstEnd,
		-- THE ERUPTION, from underneath it. A hard cut to the ice, low and
		-- close, looking up the line the body drives: the aim point is the
		-- path's own head position through the burst, so the frame tracks the
		-- animal and not a guessed height.
		pos = kit.line(kit.polar(56, hullB + 0.60, iceIn + 6), kit.polar(80, hullB + 0.50, iceIn + 24)),
		look = function(_u, t)
			return poseHead({ faceAngle = faceIn, swim = 1, burst = burstAt(t) })
		end,
		fov = 78,
		blendIn = 0,
	})
	kit.shot({
		t0 = N.burstEnd,
		t1 = N.roarStart,
		-- THE CRASH, swinging round the body it left on the ice. Bearings are
		-- relative to the burst point, so the orbit stays behind the animal
		-- wherever the curve was retuned to put it.
		pos = kit.orbit(kit.center, 90, 40, pdBearing - 0.9, pdBearing + 0.2),
		look = kit.line(apexHead, landedHead),
		fov = 68,
		blendIn = 0.9,
	})
	kit.shot({
		t0 = N.roarStart,
		t1 = N.sinkStart,
		-- THE ROAR ON THE ICE, from the party's own ground. Low, close to the
		-- drop-in ring, looking at the skull - which is where the fight's
		-- punish window puts it.
		pos = kit.line(kit.polar(72, 0, iceRing + 4.5), kit.polar(64, 0.12, iceRing + 5.5)),
		look = beachedHead,
		fov = 70,
		blendIn = 1.0,
	})
	kit.shot({
		t0 = N.sinkStart,
		t1 = kit.raiseAt,
		-- Out and up over the hole it made and around onto the party's bearing,
		-- so the last shot is already in place when the real rise starts.
		pos = kit.line(kit.polar(64, 0.12, iceRing + 5.5), kit.polar(88, 0, iceRing + 15)),
		look = kit.line(beachedHead, kit.center + Vector3.new(0, 2, 0)),
		fov = 66,
		blendIn = 1.0,
	})
	kit.shot({
		t0 = kit.raiseAt,
		t1 = kit.duration,
		-- Where the party is standing: BossArenaService.ringPositions puts them
		-- at `arena.radius + 8` = 78 on bearing 0 at floor + 3.5, so this pushes
		-- in from 88 and lands on their own eye line for the 0.8 s blend home.
		pos = kit.line(kit.polar(88, 0, iceRing + 15), kit.polar(78, 0, iceRing + 5.2)),
		look = kit.line(kit.center + Vector3.new(0, 2, 0), kit.center + Vector3.new(0, 7, 0)),
		fov = 62,
	})
end
