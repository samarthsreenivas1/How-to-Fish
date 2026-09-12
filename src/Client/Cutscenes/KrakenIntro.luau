--!nonstrict
-- KrakenIntro.luau
-- The finale's opening, on the rig. The storm shuts around the Tidebreak, FOUR
-- LIMBS CLIMB OUT OF THE SEA AT THEIR OWN MANTLE SOCKETS and lay themselves on
-- the planking, the crown breaks the surface off the port beam, one limb scythes
-- the deck the way it will in a minute's time, and everything goes back under so
-- the animal can stand up out of a flat sea under the real rise.
--
-- WHERE THIS IS STAGED. The Kraken has an arena row (BossArenas.maelstrom): the
-- fight is on a 170-stud galleon moored out in the ocean and the party is
-- teleported to her quarterdeck. So `kit.center` is the SHIP's centre at the
-- waterline, and the HEAD is 370 studs off her PORT rail (-Z), derived - never
-- published. The maelstrom disc MaelstromVfxController spins is 24,000 studs
-- away at the island and is not in shot; every scrap of storm here is drawn by
-- this file.
--
-- ============================================================ TWO THINGS THIS
-- FILE GOT WRONG BEFORE, BOTH FIXED HERE, BOTH WORTH THE SPACE
--
-- (1) POSE CENTER IS THE SHIP. This script used to publish the HEAD's world
-- position as `PoseCenter` and assert in a comment that the contract said so.
-- It says the opposite, in as many words: KrakenBodyController's header - "Pose
-- Center IS THE SHIP, not the head... the head is derived from it by KrakenPath
-- .HEAD_OFFSET and nothing here reads PoseCenter as a head position" - and
-- `KrakenPath.headCenter(state) = shipCenter(state) + HEAD_OFFSET`. Publishing
-- the head therefore drew the whole animal at `centre + 2 * HEAD_OFFSET`: 370
-- studs off frame for the whole 24 s, with the real boss popping 370 studs back
-- at the cut.
--
-- It is now ENFORCED rather than documented, which is the second reason this
-- paragraph is long: `shipCentreFrom` reconciles the published centre against
-- `BossArenas.maelstrom.center` and treats anything past 2000 studs as
-- authoritative - the GULLET EXEMPTION, the one legitimate far-flung centre.
-- 370 is UNDER that threshold, so a head-for-ship publish does not read as
-- another room, it reads as a ship centre that has drifted, and the
-- reconciliation warns and drags the animal back. So this file publishes the
-- SHIP CENTRE and nothing else, ever - never the head, never a limb socket -
-- and it never moves it. It is derived here the way the server derives it
-- (`KrakenPath.newState(Vector3.new(anchor.X, World.WATER_Y, anchor.Z))`): the
-- arena centre's X and Z at the WATERLINE, so the vertical datum is the sea and
-- not whatever Y the payload carried. The server now re-publishes it from
-- `creature.krakenShip` every frame while the fight is in phase 1-2, but the
-- stand-in still has to pass it explicitly: the rig can be adopted before the
-- creature has replicated at all.
--
-- Every scrap of entry motion below is therefore expressed as
-- `frame.tentacles[i].{bearing, radius, rise}`, which are relative to that
-- centre BY CONSTRUCTION (the controller measures them off
-- `KrakenPath.shipCenter(state)` and writes them back through the same point).
--
-- (2) THE LIMBS ARE THE RIG NOW. This file used to draw eight tapered kit.part
-- stacks on a decorative ring at r 105 and eight kit.beam lightning bolts - 56
-- primitives - and said so: "the rig and its path module were being rewritten in
-- the same hour this was written". They are not being rewritten any more, the
-- pack is imported (KrakenPack, 17 objects), and `setCutscene` has been sitting
-- there the whole time. The 56 are gone. The 28 sea-wall slabs STAY, because
-- they are the SEA STOOD ON END and no pack ships a wave; `KrakenArena_Foam`
-- clones now give the near crest a legible edge.
--
-- ======================================================= HOW THE HOOK IS USED,
-- AND WHY THE HANDOFF IS EXACT WITHOUT A POSE CONSTANT
--
-- `KrakenBodyController.setCutscene(fn)` hands `fn` the frame the controller
-- has just built from the live attributes, and then writes the rig from whatever
-- the frame contains. There is ONE code path - a single `if cutscene then
-- cutscene(frame) end` between building the frame and consuming it, with no
-- second branch that computes the pose a different way - so the guarantee at
-- the cut is structural, not a number anybody has to keep in step.
--
-- This file leans on that three times over:
--
--   * THE ATTRIBUTES ARE THE RISE'S FIRST FRAME FROM t = 0 AND NEVER LEAVE IT.
--     `Rise` is only ever driven 0 -> HEAD_LIFT / SUBMERGE -> 0 and is back at 0 by
--     15.6; `PhaseIndex` is 1 and `SiphonOpen` shuts at 17.0. Nothing else is
--     written. So there is no attribute to "put back" at the handoff.
--   * THE STAGING IS A BLEND WEIGHT, NOT A DESTINATION. Every limb's polar
--     triple is written as `lerp(incoming, staged, w)` where `incoming` is what
--     the controller just wrote - i.e. the limb's OWN fight pose. `w` walks 1 to
--     0 over SINK, and at `w = 0` the hook touches nothing at all. An untouched
--     limb is compared BIT-FOR-BIT against the value the controller wrote
--     (not against a tolerance), keeps its computed curve, and pays nothing.
--     So the last frame of the cinematic is not "close to" the fight's first -
--     it is the same arithmetic, reached continuously rather than cut to.
--   * THE HOOK RETIRES ITSELF. `setCutscene(nil)` at HANDOFF, again when the
--     real boss lands, and - the path that matters - from INSIDE the hook the
--     moment the stand-in leaves the tree, because a cancelled cinematic
--     (`kit.finish`) destroys the actor but knows nothing about a module-level
--     hook, and a hook left armed would freeze the live fight on a cutscene
--     frame. Three ways off, one of which cannot be skipped.
--
-- POLAR FIELDS ONLY, AND THAT IS WHAT SATISFIES THE BEND LAW. `KrakenPath`'s
-- verification note (`armPoint`, measured by a five-point finite difference over
-- the ASSEMBLED curve - Bezier plus coil plus drift - every pose x four seats x
-- ArmT {0, .5, 1} x four wrap points x nine deck aims x two drift phases, then
-- every ordered phase pair at weights 0.1..0.9) gives the worst ratio
-- R_min / (1.1 * girthAt(u)) per pose, where 1.00 is the bound:
--
--     Rest 1.23   Rear 2.90   Slam 1.40   SweepCock 1.50
--     Sweep 1.40  Wrapped 1.08  Down 2.02  Withdrawn 5.45
--
-- This cinematic NEVER SETS ArmPhase - it cannot; the frame does not carry it -
-- so every limb holds the pose the controller seated it in for the whole run,
-- and the only thing that moves is `tipOverride`, the fight's own seam, which
-- moves p3 and carries p2 by the same delta and therefore preserves the pose's
-- arrival direction and its handle length. The margin each limb runs at is its
-- own pose's margin, per limb:
--
--     limb 1  seat 1, AMBIENT  pose "Adrift"  (see the mismatch note below)
--     limb 2  seat 2, FIGHT    pose "Rest"    1.23
--     limb 3  seat 3, FIGHT    pose "Rest"    1.23   <- the one that sweeps
--     limb 4  seat 4, AMBIENT  pose "Adrift"  (see the mismatch note below)
--
-- `Adrift` IS NOT IN THAT TABLE. It is the decoration seats' only pose
-- (`KrakenPath.POSE.Adrift`, seated outboard and turned away) and is the same
-- family as `Rest` - same construction, same arrival direction, a longer drape -
-- but it is not separately tabulated and this file will not invent a number for
-- it. Flagged in the lane's NOTES.md for KrakenPath's owner; it wants one
-- re-run of that file's own bendcheck sweep with `Adrift` in the pose list.
--
-- Two residuals of that note, both respected here rather than argued with:
--   * "the Rear -> Rest CROSSFADE bottoms at 0.59 of the bound" - no limb
--     crossfades ANY pose pair during this cinematic, because no phase is ever
--     written. The prohibition is met by construction.
--   * "REST DURING THE RISE bottoms at 0.53 at Rise 0.35" - `Rise` never exceeds
--     0.10 here, a third of the way to that trough, and is 0 for
--     all but 2.6 s of the run.
--
-- WHY `Rise` AND `SiphonOpen` GO THROUGH THE ATTRIBUTES AND NOT THE FRAME. Both
-- could be staged on the frame, and the head alone would look the same - but
-- `KrakenPath.lift(state)` is read by `rootPosition` as well as by the head, so
-- the attribute is what brings the LIMB ROOTS up with the crown. Staging
-- `frame.head.rise` instead would lift the 480-stud head 48 studs off its own
-- sockets. `roar` has no attribute at all (the fight raises it from an event),
-- so it is the one head field the hook writes.

local Kraken = (function()
	local controllers = script.Parent.Parent:FindFirstChild("Controllers")
	local module = controllers and controllers:FindFirstChild("KrakenBodyController")
	if not module then
		return nil
	end
	-- Guarded exactly as WrackIntro guards its own: a require that throws costs
	-- the limbs and not the cinematic. The module is already loaded by
	-- init.client.luau, so this is the cached table.
	local ok, result = pcall(require, module)
	return if ok then result else nil
end)()

return function(kit)
	-- ================================================================ numbers
	--
	-- EVERY rig-derived number in one table. Nothing below reads KrakenPath
	-- directly - a retune there is an edit here and nowhere else - and every
	-- entry names where it came from.
	local RIG = {
		-- KrakenPath.HEAD_OFFSET: the head off the PORT beam, ship-local Roblox.
		HEAD_Z = -370.0,
		-- KrakenPath.SCALE.
		SCALE = 6.0,
		-- KrakenPath.SUBMERGE = HEAD_TOP 80 * SCALE. At Rise 0 the crown sits
		-- exactly on the water, which is the omen and the rise's u = 0 frame.
		SUBMERGE = 480.0,
		-- The mantle out of the water at Rise 1, and its widest ring
		-- (KA_HEAD_H / KA_HEAD_W * 0.5 = HEAD_HALF_WIDTH 47 * SCALE).
		HEAD_TOP = 480.0,
		HEAD_HALF_WIDTH = 282.0,
		-- The four mantle sockets: KrakenPath.ROOT_LATERAL (authored units, the
		-- head's own lateral axis = world X), ROOT_FORWARD (authored, toward the
		-- ship = world +Z). A root therefore sits at
		--   head + (lateral * SCALE, ROOT_Z * SCALE, ROOT_FORWARD * SCALE)
		-- so its SHIP-relative Z is HEAD_Z + ROOT_FORWARD * SCALE.
		ROOT_LATERAL = { -33.0, -11.0, 11.0, 33.0 },
		ROOT_FORWARD = 36.0,
		-- KrakenBodyController.TENTACLE_RISE_SPAN = REAR_LIFT + SHIP.DECK_Y: the
		-- studs above the ship's waterline that `rise = 1` means, so `rise = -1`
		-- is the same distance BELOW it.
		RISE_SPAN = 268.0,
		-- KrakenPath.SHIP: the deck datum, the port bulwark line, the starboard
		-- one a limb has to cross to, the mast, the castles and the spawn dais.
		DECK_Y = 8.0,
		QD_Y = 17.0,
		RAIL_PORT_Z = -19.0,
		RAIL_STBD_Z = 19.0,
		SPAWN_X = -66.0,
		SPAWN_Y = 17.4,
		-- KrakenPath.girthAt(1) = GIRTH 24 * (1 - TIP_GIRTH 0.72): the drawn
		-- half-thickness at the tip, which is `deckContact` - what makes a landed
		-- limb REST on the planking instead of inside it.
		TIP_GIRTH = 6.72,
		-- KrakenPath.SHIP.SWEEP_CLEAR: the measured plane a lateral sweep's
		-- UNDERSIDE rides on. arena_gen checked every crate against it.
		SWEEP_CLEAR = 3.0,
		-- How far the crown comes up mid-cinematic, IN STUDS, because that is the
		-- thing being decided - `Rise` is derived from it against SUBMERGE below.
		-- 48 studs of a 480-stud submergence: the crown breaks the surface off
		-- the port beam and nothing more, so the animal is still a shadow with a
		-- head on it.
		HEAD_LIFT = 48.0,
		-- The apex a staged limb is hauled to, in `rise` units. 1.0 would be
		-- KrakenPath.REAR_LIFT exactly over a deck target; 0.85 holds it just
		-- under that, which keeps the tip inside a 76-degree frame with the
		-- planking in it.
		REAR_RISE = 0.85,
	}

	-- The storm. WALL_R sits outside the hull's 85-stud half length with room
	-- for every camera to fly INSIDE it, and the ring is pulled down toward
	-- GAP_FLOOR on the head's own bearing - the storm leaves one door open, and
	-- the animal is standing in it.
	local STORM = {
		WALL_R = 170,
		WALL_H = 118,
		WALL_N = 28,
		WALL_W = 42,
		WALL_T = 8,
		GAP_FLOOR = 0.2,
		FOAM_N = 9,
		FOAM_SCALE = 0.075, -- KrakenArena_Foam is the whole 200-stud wake collar
	}

	local PAL = {
		wall = Color3.fromRGB(19, 27, 36), -- the sea stood on end, near black
		spray = Color3.fromRGB(186, 208, 220),
		bolt = Color3.fromRGB(214, 238, 255),
		storm = Color3.fromRGB(150, 178, 200),
	}

	-- ================================================================ the beats
	local WALL_UP = 3.4
	local FIRST_LIMB = 7.4
	local LIMB_STEP = 1.1
	local LIMB_RISE_FOR = 1.8 -- out of the sea at its own socket
	local LIMB_REACH_FOR = 0.9 -- ...then in onto the planking
	local HEAD_UP = 13.0
	local SWEEP0 = 15.6
	local SWEEP1 = 17.6
	local SINK1 = 18.6 -- THE HANDOFF: the hook retires on this line
	local raiseAt = kit.raiseAt -- 19.0 at duration 24 / riseTime 5

	-- ================================================================ geometry
	--
	-- THE SHIP CENTRE, derived the way the server derives it: the arena centre's
	-- X and Z at the WATERLINE. See (1) in the header - this value is what goes
	-- on the wire as `PoseCenter`, it is the only thing that ever does, and it
	-- never moves.
	local waterY = kit.waterY
	local shipCentre = Vector3.new(kit.center.X, waterY, kit.center.Z)
	local function aboard(x: number, y: number, z: number): Vector3
		return Vector3.new(shipCentre.X + x, waterY + y, shipCentre.Z + z)
	end

	-- Where the head is DRAWN, for the camera only. Never published.
	local headAt = shipCentre + Vector3.new(0, 0, RIG.HEAD_Z)
	local headBearing = math.atan2(RIG.HEAD_Z, 0) -- -pi/2; derived, so a re-key carries the door

	-- The party's own eye on the spawn dais (BossArenaService.ringPositions' pad
	-- branch plus its 3.5 settle clearance). The head is off their left hand.
	local partyEye = aboard(RIG.SPAWN_X, RIG.SPAWN_Y + 3.5 + 5.0, 0)

	local function angleGap(a: number, b: number): number
		local d = (a - b) % (math.pi * 2)
		if d > math.pi then
			d = math.pi * 2 - d
		end
		return d
	end

	-- A ship-local point as a polar pair ABOUT THE SHIP, which is the frame's
	-- own coordinate system for a limb tip: the controller measures
	-- `atan2(tip.Z - ship.Z, tip.X - ship.X)` and the magnitude in XZ, and
	-- writes the tip back through exactly that pair. One helper, so no staged
	-- number below is a hand-computed bearing.
	local function polarOf(x: number, z: number): (number, number)
		return math.atan2(z, x), math.sqrt(x * x + z * z)
	end

	-- ONE SEAT'S NUMBERS, all four derived rather than typed.
	--
	--   socket - where the limb's own root is, in ship polar. `rise = -1` under
	--            THIS bearing and radius is the limb waiting one apex-height
	--            below the surface at its own mantle socket, which is the whole
	--            point: it climbs out of the sea where it is attached instead of
	--            appearing on a decorative ring.
	--   deck   - where its tip lands, just inboard of the port bulwark, at
	--            `DECK_Y + girthAt(1)` so it RESTS on the planking (the fight's
	--            own `deckContact` rule).
	local rootZ = RIG.HEAD_Z + RIG.ROOT_FORWARD * RIG.SCALE
	local deckRise = (RIG.DECK_Y + RIG.TIP_GIRTH) / RIG.RISE_SPAN
	local seats = {}
	for i, lateral in RIG.ROOT_LATERAL do
		local sb, sr = polarOf(lateral * RIG.SCALE, rootZ)
		-- The stations run outboard-to-outboard in the same order as the roots,
		-- so no limb has to cross another to reach its own.
		local deckX = lateral * 0.97 -- -32, -10.7, 10.7, 32: inside the waist
		local db, dr = polarOf(deckX, RIG.RAIL_PORT_Z + 5)
		seats[i] = { bearing = sb, radius = sr, deckBearing = db, deckRadius = dr }
	end

	-- THE SWEEP LANE, for the one limb that shows the fight's opening move. The
	-- tip travels the waist along X at the height `KrakenPath.sweepCentreY`
	-- puts a centreline: `deckY + SWEEP_CLEAR + girthAt(1)`, which is what keeps
	-- the limb's UNDERSIDE on the measured plane instead of half-buried in the
	-- planking.
	-- `Rise` for the head beat, as a fraction of the submergence it is measured
	-- against. Derived rather than typed so a re-keyed SUBMERGE carries it.
	local headRise = RIG.HEAD_LIFT / RIG.SUBMERGE

	local SWEEP_SEAT = 3 -- a FIGHT seat (KrakenPath.FIGHT_SEAT = { 2, 3 })
	local SWEEP_Z = -6.0
	local SWEEP_FROM_X = 40.0
	local SWEEP_TO_X = -34.0
	local sweepRise = (RIG.DECK_Y + RIG.SWEEP_CLEAR + RIG.TIP_GIRTH) / RIG.RISE_SPAN

	-- ================================================================ the actor
	--
	-- PoseCenter = the SHIP centre. `Rise`, `PhaseIndex` and `SiphonOpen` are
	-- seeded at the rise's own first frame and only ever return to it.
	local head = kit.actor({
		pose = kit.boss.pose or "kraken",
		name = "Cutscene_Kraken",
		center = shipCentre,
		attrs = { Rise = 0, PhaseIndex = 1, SiphonOpen = false },
	})

	-- ================================================================ the hook
	--
	-- `stage.w` is the blend weight described in the header: 1 while the
	-- cinematic is staging, walked to 0 across SINK, and at 0 the hook writes
	-- NOTHING so the frame reaches the rig bit-unchanged. Every number in here
	-- is set by a `kit.track` (never a `during`) so a skip settles it at u = 1
	-- instead of leaving a limb in the air.
	local stage = { w = 1, visible = false, roar = 0 }
	local drive = {}
	for i, seat in seats do
		drive[i] = { bearing = seat.bearing, radius = seat.radius, rise = -1, visible = false }
	end

	local live = false
	local function retire()
		if not live then
			return
		end
		live = false
		if Kraken and Kraken.setCutscene then
			Kraken.setCutscene(nil)
		end
	end

	local function conduct(frame)
		-- THE THREE WAYS OFF, and this is the one that cannot be skipped: a
		-- cancelled run destroys the actor through `kit.finish`, which knows
		-- nothing about a module-level hook. Checked here, on the frame after,
		-- because this is the only code of ours that still runs.
		if not head.model.Parent or kit.t >= SINK1 then
			retire()
			return
		end
		local w = stage.w
		if w <= 0 then
			return
		end
		frame.visible = stage.visible
		-- `roar` is the one head field with no attribute behind it.
		frame.head.roar = stage.roar * w
		for i, d in drive do
			local slot = frame.tentacles[i]
			if slot then
				slot.visible = d.visible
				-- Lerped FROM what the controller just wrote - this limb's own
				-- fight pose - so w = 0 is the fight and w = 1 is the staging,
				-- and there is no third pose anywhere in between.
				slot.bearing += (d.bearing - slot.bearing) * w
				slot.radius += (d.radius - slot.radius) * w
				slot.rise += (d.rise - slot.rise) * w
			end
		end
	end

	if Kraken and Kraken.setCutscene then
		live = true
		Kraken.setCutscene(conduct)
	end
	kit.at(SINK1, retire)
	kit.onRealBoss(function()
		retire()
		head:destroy()
	end)

	-- ================================================================ the wall
	--
	-- The sea stood on end - 28 slabs, KEPT, because no pack ships a wave. Built
	-- already sunk and tweened up, height falling away to GAP_FLOOR on the
	-- head's bearing so the storm leaves one door and the animal comes through
	-- it.
	local wall = {}
	for i = 1, STORM.WALL_N do
		local bearing = (i - 1) * (math.pi * 2 / STORM.WALL_N)
		local door = math.clamp(angleGap(bearing, headBearing) / (math.pi * 0.5), 0, 1)
		-- Two low harmonics instead of noise: deterministic, so every party
		-- member sees the same wall, and no seed to derive.
		local ripple = 1 + 0.09 * math.sin(bearing * 3) + 0.05 * math.sin(bearing * 7 + 1.1)
		local h = STORM.WALL_H * (STORM.GAP_FLOOR + (1 - STORM.GAP_FLOOR) * door) * ripple
		local top = kit.polar(STORM.WALL_R, bearing, waterY + h * 0.5 - 2)
		local part = kit.part({
			Size = Vector3.new(STORM.WALL_W, h, STORM.WALL_T),
			CFrame = CFrame.lookAt(
				Vector3.new(top.X, waterY - h * 0.5 - 6, top.Z),
				Vector3.new(shipCentre.X, waterY - h * 0.5 - 6, shipCentre.Z)
			),
			Color = PAL.wall,
			Material = Enum.Material.Slate,
			Transparency = 0.08,
		})
		local risen = CFrame.lookAt(top, Vector3.new(shipCentre.X, top.Y, shipCentre.Z))
		local t0 = WALL_UP + door * 1.6
		kit.tweenPart(part, { CFrame = risen }, t0, t0 + 2.4, "out")
		table.insert(wall, { part = part, bearing = bearing, risen = risen, door = door, at = t0 })
	end

	-- THE CREST. `KrakenArena_Foam` is the ship's own wake collar - the one
	-- authored foam in this arena - cloned small along the near arc so the wall
	-- has an edge the eye can read instead of ending in a hard line. A mesh
	-- where the old version had nothing at all; `kit.mesh` falls back to a slab
	-- on a machine that never got the import, so this is safe either way.
	for i = 1, STORM.FOAM_N do
		local bearing = headBearing + (i - (STORM.FOAM_N + 1) * 0.5) * math.rad(13)
		local at = kit.polar(STORM.WALL_R - 13, bearing, waterY + 2)
		local foam = kit.mesh("KrakenArena", "Foam", {
			Scale = STORM.FOAM_SCALE,
			CFrame = CFrame.new(at - Vector3.new(0, 26, 0)),
			Transparency = 0.25,
		})
		local t0 = WALL_UP + 0.5 + i * 0.09
		kit.tweenPart(foam, { CFrame = CFrame.new(at) }, t0, t0 + 1.9, "out")
	end

	-- =============================================================== the limbs
	--
	-- Four of them, staggered LIMB_STEP apart. Each one: up out of the sea at
	-- its own socket (bearing and radius HELD at the socket's, `rise` -1 to
	-- REAR_RISE), then in onto the planking (bearing and radius onto its deck
	-- station, `rise` down to `deckRise`). Two tracks per limb and no `during`
	-- anywhere, so a skip settles every one of them at its landed pose.
	for i, seat in seats do
		local d = drive[i]
		local t0 = FIRST_LIMB + (i - 1) * LIMB_STEP
		local tRisen = t0 + LIMB_RISE_FOR

		kit.track(t0, tRisen, "out", function(u)
			-- Set inside the track rather than by a `kit.at`, so a skip past the
			-- window settles the limb visible at its apex in one call.
			d.visible = true
			d.bearing = seat.bearing
			d.radius = seat.radius
			d.rise = -1 + (RIG.REAR_RISE + 1) * u
		end)
		kit.track(tRisen, tRisen + LIMB_REACH_FOR, "inout", function(u)
			d.visible = true
			d.bearing = seat.bearing + (seat.deckBearing - seat.bearing) * u
			d.radius = seat.radius + (seat.deckRadius - seat.radius) * u
			d.rise = RIG.REAR_RISE + (deckRise - RIG.REAR_RISE) * u
		end)

		-- The water breaking where it comes through, and the lightning that used
		-- to be sixteen kit.beam parts and is now a screen flash and a splash.
		-- Muted across a skip by the kit (flash, shake, sfx and decorative vfx
		-- are), which is why none of the STATE above lives in here.
		kit.at(t0 + 0.35, function()
			local surface = kit.polar(seat.radius, seat.bearing, waterY)
			kit.flash(PAL.bolt, 0.38, 0.26)
			kit.sfx("thunder", surface)
			kit.sfx("krakenTentacleRise", surface)
			kit.shake(0.026, 0.6)
			kit.vfx.splash(surface, 26)
			kit.vfx.ring(surface + Vector3.new(0, 0.4, 0), 18, 96, 1.3, PAL.spray)
		end)
		kit.at(tRisen + LIMB_REACH_FOR - 0.1, function()
			kit.sfx("bossSlam", kit.polar(seat.deckRadius, seat.deckBearing, waterY + RIG.DECK_Y))
			kit.shake(0.03, 0.7)
		end)
	end

	-- THE FIRST LIMB IS WHAT PUTS THE RIG ON SCREEN. Before it there is nothing
	-- to see but a ship and a wall: `frame.visible = false` is the honest way to
	-- say so (it gates the write rather than short-circuiting the frame, which
	-- is why the hook can still stage the head afterwards).
	kit.track(FIRST_LIMB, FIRST_LIMB + 1e-3, nil, function()
		stage.visible = true
	end)

	-- ================================================================ the head
	--
	-- `Rise` through the ATTRIBUTE, not the frame, so `KrakenPath.lift` brings
	-- the four roots up with the crown - see the header's last paragraph. 0.10
	-- of SUBMERGE is 48 studs: the crown breaks the surface off the port beam
	-- while the limbs are already on the rail, and nothing more.
	-- THE TWO WINDOWS ABUT EXACTLY AND DO NOT OVERLAP. The kit applies tracks in
	-- registration order, so "the later track wins while active" - an overlap
	-- here would let the fall start before the climb had finished and the crown
	-- would peak short of HEAD_LIFT for no visible reason.
	head:tween("Rise", 0, headRise, HEAD_UP, SWEEP0 - 1.0, "inout")
	head:tween("Rise", headRise, 0, SWEEP0 - 1.0, SWEEP0, "inout")
	-- The siphon - the door, on an animal boss_gen gave no mouth. `gape`'s
	-- default value IS this bool eased, so the cutscene and the fight drive one
	-- channel and this is the first time anything has opened it.
	kit.at(HEAD_UP + 0.6, function()
		head:set("SiphonOpen", true)
	end)
	kit.at(SWEEP1 - 0.6, function()
		head:set("SiphonOpen", false)
	end)
	-- The face surge: both orbs hard-bright and the siphon core spiked with
	-- them. Deliberately NOT the star pupils - `Kraken_Pupil` is matte cream and
	-- staying steady is what reads as a pupil, which the controller enforces by
	-- keeping NEON a closed list rather than by anyone remembering.
	kit.track(HEAD_UP + 1.4, HEAD_UP + 2.2, "out", function(u)
		stage.roar = u
	end)
	kit.track(HEAD_UP + 2.2, SWEEP0, "in", function(u)
		stage.roar = 1 - u
	end)

	-- =============================================================== the sweep
	--
	-- One limb scythes the deck, at the fight's own plane and along the fight's
	-- own lane, so the player has seen the opening move before it is aimed at
	-- them. Expressed as a polar walk of the tip rather than as `ArmPhase =
	-- Sweep` for the reason the header gives: the frame carries no phase, and
	-- re-aiming the seated pose through `tipOverride` is the sanctioned seam.
	do
		local seat = seats[SWEEP_SEAT]
		local d = drive[SWEEP_SEAT]
		local fromB, fromR = seat.deckBearing, seat.deckRadius
		local laneB, laneR = polarOf(SWEEP_FROM_X, SWEEP_Z)
		-- Cocked: back to the lane's far end, at the sweep plane.
		kit.track(SWEEP0 - 0.7, SWEEP0, "inout", function(u)
			d.bearing = fromB + (laneB - fromB) * u
			d.radius = fromR + (laneR - fromR) * u
			d.rise = deckRise + (sweepRise - deckRise) * u
		end)
		-- ...and through. The whole lane is in the -Z half plane, so the bearing
		-- runs monotonically and no wrap can appear in the middle of the swing.
		kit.track(SWEEP0, SWEEP1, "inout", function(u)
			local x = SWEEP_FROM_X + (SWEEP_TO_X - SWEEP_FROM_X) * u
			local b, r = polarOf(x, SWEEP_Z)
			d.bearing = b
			d.radius = r
			d.rise = sweepRise
		end)
		kit.at(SWEEP0, function()
			kit.sfx("krakenTentaclelash", aboard(SWEEP_FROM_X, RIG.DECK_Y + 6, SWEEP_Z))
			kit.shake(0.05, 1.4, 0.02)
		end)
		kit.at(SWEEP1 - 0.4, function()
			kit.sfx("bossSweep", aboard(SWEEP_TO_X, RIG.DECK_Y + 6, SWEEP_Z))
		end)
	end

	-- ================================================================ the sink
	--
	-- THE HANDOFF, and it is one number. `stage.w` walks 1 -> 0, so every limb
	-- travels from where the cinematic put it to ITS OWN FIGHT POSE - `Rest` for
	-- the two fight seats, `Adrift` for the two decoration seats, both of which
	-- drape 150-230 studs under the sea, which is why they go out of sight
	-- without anything having to be told where "under" is. At w = 0 the hook
	-- touches nothing, so the last frame the cinematic draws IS the fight's
	-- arithmetic rather than a copy of it. `Rise` is already 0 (it returned at
	-- SWEEP0), `SiphonOpen` is already shut, `PhaseIndex` never moved, and
	-- `PoseCenter` has been the ship centre since the first frame.
	kit.track(SWEEP1, SINK1, "inout", function(u)
		stage.w = 1 - u
	end)
	kit.at(SWEEP1, function()
		kit.sfx("krakenUndertow", headAt)
		kit.vfx.ring(Vector3.new(headAt.X, waterY + 0.4, headAt.Z), 80, RIG.HEAD_HALF_WIDTH, 2.2, PAL.storm)
	end)

	-- ================================================================= the omen
	kit.fade(1, 0.001)
	kit.at(0.3, function()
		kit.fade(0, 1.6)
	end)

	local whirl = nil
	kit.at(0.05, function()
		whirl = kit.loop("whirlpool", shipCentre)
		kit.sfx("windGust", partyEye)
	end)
	kit.at(SWEEP1, function()
		kit.stopLoop(whirl)
	end)

	-- The deck trembling under a party that cannot move: low, and running the
	-- whole omen, because it is the only thing telling them the ship is not safe.
	kit.rumble(1.2, FIRST_LIMB, 0.012)

	-- Foam running OUT from under the hull as the sea starts to turn.
	kit.every(1.4, WALL_UP + 3.0, 0.85, function(n)
		kit.vfx.ring(aboard(0, 0.4, 0), 40 + n * 18, STORM.WALL_R - 10, 1.6, PAL.storm)
	end)

	kit.at(WALL_UP, function()
		kit.sfx("krakenStormcall", shipCentre)
		kit.shake(0.03, 1.2)
	end)
	kit.at(WALL_UP + 1.4, function()
		kit.sfx("krakenRingwave", shipCentre)
	end)
	for _, slab in wall do
		kit.at(slab.at + 0.15, function()
			kit.vfx.splash(kit.polar(STORM.WALL_R - 6, slab.bearing, waterY), 7)
		end)
	end
	kit.at(HEAD_UP, function()
		kit.sfx("krakenUndertow", headAt)
	end)
	kit.at(HEAD_UP + 0.6, function()
		kit.sfx("bossTell", headAt)
	end)
	kit.at(HEAD_UP + 1.4, function()
		kit.sfx("bossRoar", headAt)
		kit.shake(0.05, 1.4, 0.02)
	end)

	-- ================================================================= the roar
	--
	-- The real boss is raised by the server here and plays its own Rise 0 -> 1.
	-- Everything from this line down is camera and weather over it.
	kit.at(raiseAt, function()
		kit.sfx("krakenRingwave", headAt)
		kit.vfx.splash(Vector3.new(headAt.X, waterY, headAt.Z), 40)
		kit.shake(0.035, 1.6)
	end)
	kit.every(raiseAt, kit.duration, 0.55, function(n)
		kit.vfx.ring(
			Vector3.new(headAt.X, waterY + 0.5, headAt.Z),
			RIG.HEAD_HALF_WIDTH * 0.5,
			RIG.HEAD_HALF_WIDTH * (1.2 + n * 0.12),
			1.4,
			PAL.spray
		)
	end)

	-- The wall on the head's bearing is shoved flat as the animal comes through
	-- its own door.
	for _, slab in wall do
		if slab.door < 0.34 then
			local shoved = slab.risen * CFrame.new(0, -22, 6)
			kit.track(raiseAt + 0.6, raiseAt + 2.6, "out", function(u)
				if slab.part.Parent then
					slab.part.CFrame = slab.risen:Lerp(shoved, u)
				end
			end)
		end
	end

	-- The card lands on the roar CreatureEventController already fires at
	-- 0.85 * riseTime into the rise, so the two are one beat.
	kit.at(raiseAt + 0.85 * kit.riseTime, function()
		kit.card(string.upper(kit.boss.shortName), string.match(kit.boss.name, ",%s*(.+)$") or "Maw of the Maelstrom")
		kit.sfx("krakenRoar", headAt)
		kit.flash(Color3.fromRGB(255, 244, 226), 0.3, 0.55)
		kit.shake(0.075, 1.5, 0.05)
	end)

	-- ================================================================ camera
	--
	-- CLEARANCE, once, for all seven shots.
	--
	-- THE LIMBS ARE ALL ON ONE SIDE NOW, and that is what re-composed every
	-- shot: the four sockets are at ship-polar bearings 218 / 247 / 293 / 322
	-- degrees (all of them on the PORT quarter, because that is where the head
	-- is), and their tips reach in to r 11-34 on the planking. So the camera
	-- lives on the STARBOARD arc, 60-112 degrees, which is 106 degrees clear of
	-- the nearest socket and has no limb on it at any point in the run - and
	-- looks ACROSS the ship at the limbs with the head behind them. The old
	-- version orbited THROUGH the limb ring, which was safe only because the
	-- limbs were props on a ring of their own.
	--
	-- The wall is a ring at r 170 and every shot after WALL_UP flies INSIDE it.
	-- The ship is 170 x 40 with a mainmast to +70 and a quarterdeck at +17; the
	-- two deck shots stand at 25-26 over the water and never travel forward of
	-- x -50 or outboard of the starboard bulwark, so the mast (x -6) is only
	-- ever a silhouette. Nothing dips below the waterline at any point.

	-- A: the ship alone in a flat calm, lamps lit. The only shot OUTSIDE the
	-- wall's radius, and it ends on the frame the wall starts rising.
	kit.shot({
		t0 = 0,
		t1 = WALL_UP,
		pos = kit.orbit(shipCentre, 200, 40, math.rad(58), math.rad(96)),
		look = shipCentre + Vector3.new(0, 10, 0),
		fov = 66,
		blendIn = 0,
	})

	-- B: up off the deck and out, watching the sea stand up around her.
	kit.shot({
		t0 = WALL_UP,
		t1 = FIRST_LIMB,
		pos = kit.line(aboard(24, RIG.DECK_Y + 16, RIG.RAIL_STBD_Z - 3), kit.polar(140, math.rad(84), waterY + 92)),
		look = shipCentre + Vector3.new(0, 20, 0),
		fov = 74,
		blendIn = 0.9,
	})

	-- C: round the starboard arc while the limbs come up off the port quarter,
	-- the look point walking out onto the field of them.
	kit.shot({
		t0 = FIRST_LIMB,
		t1 = FIRST_LIMB + 4.0,
		pos = kit.orbit(shipCentre, 150, 60, math.rad(70), math.rad(112)),
		look = function(u)
			return (shipCentre + Vector3.new(0, 30, 0)):Lerp(shipCentre + Vector3.new(0, 90, -150), u)
		end,
		fov = 76,
		blendIn = 0.7,
	})

	-- D: a hard cut to the starboard rail, looking up and across at the last
	-- limbs arriving over the deck. 8 studs inboard of the bulwark, 36 from the
	-- nearest landed tip.
	kit.shot({
		t0 = FIRST_LIMB + 4.0,
		t1 = HEAD_UP,
		pos = aboard(-2, RIG.DECK_Y + 7, RIG.RAIL_STBD_Z - 8),
		look = function(u)
			return aboard(0, RIG.DECK_Y + 40 + 60 * u, RIG.RAIL_PORT_Z - 30 - 60 * u)
		end,
		fov = 88,
		blendIn = 0,
	})

	-- E: pulled back and up to take in the head, the four limbs and the ship in
	-- one frame. Still inside the wall; the head is 480 studs tall and the door
	-- on its bearing is 24, so it is seen over the storm and not through it.
	kit.shot({
		t0 = HEAD_UP,
		t1 = SWEEP0,
		pos = kit.line(kit.polar(150, math.rad(112), waterY + 70), kit.polar(158, math.rad(94), waterY + 132)),
		look = function(u)
			return (shipCentre + Vector3.new(0, 40, -60)):Lerp(Vector3.new(headAt.X, waterY + 150, headAt.Z), u)
		end,
		fov = 90,
		blendIn = 1.0,
	})

	-- F: deck level on the quarterdeck, looking forward along the waist as the
	-- limb comes through it. Behind the sweep's own far end by 18 studs and 9
	-- studs above the plane it rides, which is the only place on this ship the
	-- swing can be watched from rather than blocked by.
	kit.shot({
		t0 = SWEEP0,
		t1 = SWEEP1,
		pos = aboard(-52, RIG.QD_Y + 9, 11),
		look = function(u)
			local x = SWEEP_FROM_X + (SWEEP_TO_X - SWEEP_FROM_X) * (u * u * (3 - 2 * u))
			return aboard(x, RIG.DECK_Y + 12, SWEEP_Z)
		end,
		fov = 78,
		blendIn = 0.8,
	})

	-- G: back to the party's own eye for the sink and the handoff, so the shot
	-- the server's boss arrives into is already in place.
	kit.shot({
		t0 = SWEEP1,
		t1 = raiseAt,
		pos = kit.line(aboard(-52, RIG.QD_Y + 9, 11), partyEye),
		look = function(u)
			return Vector3.new(headAt.X, waterY + 10 + 26 * u, headAt.Z)
		end,
		fov = 74,
		blendIn = 1.1,
	})

	-- H: the rise, from where the party is standing, tilting up the whole 480
	-- studs of it. Ends AT `duration` on the frame the controller blends out of,
	-- which is a few studs and no rotation from the player's own camera.
	kit.shot({
		t0 = raiseAt,
		t1 = kit.duration,
		pos = function(u)
			return partyEye + Vector3.new(0, 4 * u, 6 * u)
		end,
		look = function(u)
			return Vector3.new(headAt.X, waterY + 20 + (RIG.HEAD_TOP * 0.62 - 20) * u, headAt.Z)
		end,
		fov = 68,
		blendIn = 0.9,
	})
end
