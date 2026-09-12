--!nonstrict
-- WrackIntro.luau
-- Admiral Wrack, the Fleet-Eater - the Careenage (BossArenas.wreck, model
-- "WrackArena"). Twenty-two seconds: the tide runs out, the ghost fleet lights
-- hull by hull, SHE SAILS IN THROUGH THE PALISADE'S MOUTH under her own boom,
-- runs the gunports out deck by deck, takes the ground bow-first, the Admiral
-- turns onto the party and fires a broadside over their heads - and then she
-- settles back into the flat, because the last 4.2 seconds are the REAL rise on
-- the real rig.
--
-- ============================================= WHY SHE SAILS IN, AND WHY THAT
-- IS THE ONE BEAT THE FIGHT CAN NEVER SHOW
--
-- Wrack is the freest of the seven in TRANSLATION and the poorest in
-- ARTICULATION: there is no `WrackPath.luau` and no pose attribute, the whole
-- 35-piece assembly places off a single pivot with no clamp of any kind
-- (`stand:pivot(cf)` -> `model:PivotTo(cf)`), and his own Bosses row carries
-- `speed = 0` because in the fight he is a planted gun platform bedded in the
-- shoal. So the thing this cinematic can do that the fight cannot is MOVE HER,
-- and the thing it must not do is invent articulation - every channel driven
-- below already exists in the controller's 34-row table.
--
-- WHY SHE GOES BACK UNDER AT THE END. Every other boss's stand-in can hold its
-- final pose and let the server's rise continue it. Wrack is a PLAIN boss:
-- CreatureService's `rising` branch pivots him up from `riseDepth` (22) below
-- with a -20 degree pitch over `riseTime` (4.2 s), and that curve starts UNDER
-- THE SAND no matter what the cinematic did. So the arrival has to be a lie she
-- tells and takes back: she sails in, grounds, salutes, and settles into the
-- flat under her own spray. At `kit.raiseAt` the stand-in is at exactly
-- `place(0)` - the rise's own first frame - which makes the handoff invisible
-- whether the real rig arrives on time, late, or (a skip) early.
--
-- THE POSE ARITHMETIC IS THE SERVER'S, COPIED. `place(e)` below is
-- CreatureService.updateBoss's non-entrenched rising line
--     PivotTo(poseCFrame(creature, -riseDepth + (riseDepth + sub) * e, 0, rad(-20) * (1 - e)))
-- with `sub = -def.submerge` and `e = 1 - (1 - u)^3`, re-expressed against WHAT
-- THE RIG ACTUALLY DRAWS OFF. WrackBodyController.drawBody builds its assembly
-- at `base = CFrame.new(pivot.Position + (0, groundDrop, 0)) * pivot.Rotation`,
-- where `groundDrop` is that model's pivot-to-box-bottom, measured once at
-- adopt. For the SERVER model that is `halfThickness`, and since `groundedPos`
-- stands the model at surface + halfThickness, the base lands at
-- `surface + hop` exactly. For a kit stand-in the box is the one 1-stud root
-- part, so groundDrop is **-0.5** - the box bottom is BELOW the pivot, and the
-- sign matters: this header used to say 0.5 while the code used `-C.rootHalf`.
-- The code was right; the prose is fixed here. Every pivot below is therefore
-- `kit.center.Y + hop + C.rootHalf`, both models put their base at the same
-- height for the same `hop`, and neither one's halfThickness enters the answer.
--
-- THE SAILING POSE IS A SUPERSET OF THE GROUNDED ONE, not a second arithmetic.
-- `shipPose(at, yaw, pitch, roll)` is the only thing in this file that touches
-- the pivot, and `place(e)` is one call into it with the server's own numbers:
--     place(e) = shipPose(centre + (0, hop(e) + rootHalf, 0), yaw0, pitch*(1-e), 0)
-- so "she is at the rise's first frame" is `place(0)` and cannot drift away from
-- whatever the approach did, and the approach cannot grow an arithmetic of its
-- own that the handoff has to be reconciled against.
--
-- BEARINGS. yaw0 is 0: BossService.raise spawns him with no throw target and
-- `yawToward(nil)` returns 0, `turnRate = 0` keeps it there, and
-- `uprightOrientation` hands an upright row CFrame.identity for `flat`. So the
-- bow (+X in boss space - the figurehead at x 22.3, the bowsprit past it)
-- points at world +X, which is also where a solo challenger stands
-- (BossArenaService.ringPositions' disc branch puts one player at bearing 0,
-- r = arena.radius + 8 = 88). The camera ends there. The palisade's mouth - 46
-- degrees of clear water, the only way in - is on authored bearing 90, world
-- -Z, and she comes in through it on a heading of world +Z: so she SAILS on
-- yaw -pi/2 and SLEWS onto yaw 0 as she takes the ground, which is the only
-- rotation in the run that is not the server's own pitch.
--
-- ================================== THE FOUR GUNS, AND THE BUG THIS FILE HAD
--
-- This script used to name `CannonBow / CannonStarboard / CannonStern /
-- CannonPort` and claim the four points were "verbatim from WrackBodyController's
-- AUTHORED table". They were verbatim from the PRE-09-08 CAREENED SHIP. That
-- redesign stood her up, halved her bulk, and moved the four floating
-- "batteries" out to the corners on sponsons; the controller's own header says
-- it in as many words - "the old `Wrack_Battery*` names AND the one-per-flank
-- `Wrack_CannonBow/Starboard/Stern/Port` names are both GONE from the mesh;
-- anything still addressing either draws nothing". So every muzzle flash, burst
-- and puff of the broadside salute was being placed on bearings the ship no
-- longer has, up to 9.7 studs out in Z, with no error anywhere: the positions
-- were plausible numbers about a plausible ship.
--
-- The real four are `CannonBowStbd / CannonBowPort / CannonSternStbd /
-- CannonSternPort` at (+-15.19, 13.1-14.1, +-8.57) as PLACED, standing outboard
-- in their own three-sided casemates at bearings +-30 / +-150. GUNS below is
-- the controller's own gun table - `at` (the span centroid, which is the number
-- boss_gen prints into `Bosses.items.admiral_wrack.parts.mounts`, i.e. where the
-- server stands the battery creature), `muzzle` (the bore's mouth) and `bore`
-- (the unit direction, carried at full precision because a rounded bore sits the
-- flare visibly off the barrel). The flare goes at the MUZZLE along the BORE,
-- which is the only pair of numbers that can put it on the brass.
--
-- AND THE HATCHES. This script used to write `WrackHatches` masks 1, 3, 7, 15
-- and say the writes "are silent today". They are not silent - the row landed
-- 2026-09-09 - and there are THREE lids, not four: `mask = 15` set a bit with no
-- `Hatch4` behind it. The masks are 1, 3, 7 and the fourth write is gone. They
-- also now SHUT at the settle, because the real boss arrives with them closed
-- and leaving them open at the cut was a visible pop.
--
-- THE CHANNELS THIS DRIVES, and all of them already existed:
--   Exposed        held false - the hull stays shut; a listing ship with her
--                  mast down is act 3, not her entrance
--   WrackBoom      the spar's live WORLD bearing in radians (nil = stowed), set
--                  to leeward on each tack and CLEARED before the ground so the
--                  boom is home for the handoff
--   WrackHatches   the bitmask, 1 -> 3 -> 7 -> 0
--   WrackDive      on a SECOND actor: the Lady. See "the figurehead" below
--   cue "windup"   admHigh + admPoint + admLook, aimed at the party's ring
--   cue "fire"     the radial case - admSweep + admFlick, plus gunRecoil and
--                  muzzleFlash on every live deck
--
-- AND THE ONE THE DESIGN ASKED FOR THAT DOES NOT EXIST FOR HER. `cue("arrive")`
-- is `admArriveLand` / `admArriveDraw`, and both rows are `kinds = { duel =
-- true }` - the DUELIST's landing, act 3's opening beat. The ship's kind does
-- not carry them, so cueing "arrive" on a `CreatureId = "admiral_wrack"` model
-- reaches a body and changes nothing. It is not called here; the Admiral is
-- conducted onto the party with `windup` (which the ship does carry) instead.
--
-- THE ONE REQUIRE. `WrackBodyController.cue(model, signal, extra?)` fires the
-- boss's own animation channels without a wire event - the sabre and the guns -
-- and it is looked up defensively: a lookup that fails costs the salute's
-- gestures and not the cinematic. Requiring the controller is free (the module
-- is already loaded by init.client.luau, so this is the cached table) and it
-- cannot adopt a model, only conduct one already adopted - see its header.
local Wrack = (function()
	local controllers = script.Parent.Parent:FindFirstChild("Controllers")
	local module = controllers and controllers:FindFirstChild("WrackBodyController")
	if not module then
		return nil
	end
	local ok, result = pcall(require, module)
	return if ok then result else nil
end)()

return function(kit)
	-- One table, so a retune is one edit and the chunk stays inside its
	-- register budget. Every number is sourced in the comment beside it.
	local C = {
		-- Bosses.items.admiral_wrack: riseDepth 22, submerge 2.8, riseTime 4.2.
		riseDepth = 22,
		submerge = 2.8,
		-- kit.actor's root part is 1 stud, so pivot-to-box-bottom is -0.5 and
		-- the pivot sits half a stud above the base. See the header.
		rootHalf = 0.5,
		yaw0 = 0,
		pitch = math.rad(-20),
		-- WrackBodyController.AUTHORED_ANCHOR - `Wrack_Base`'s authored centre,
		-- which every piece offset is measured from.
		anchor = Vector3.new(-0.1, 0.7, 0.3),
		-- arena_gen.py build_wrack: walkable sand r 0-132 (WK_SAND_R), palisade
		-- WK_FLEET_R 140-152, foam WK_FOAM_R 161-167.5, mouth WK_FLEET_GAP_DEG
		-- 46 centred on WK_SEA_DEG 90.
		sandR = 132,
		fleetR = 146,
		foamR = 164,
		mouthDeg = 90,
		gapDeg = 46,
		-- The party's ring: Bosses.admiral_wrack.arena.radius (80) + 8.
		partyR = 88,
		-- THE APPROACH. She makes her offing outside the foam ring and comes in
		-- on the mouth's own bearing; `groundR` is where the keel touches and
		-- the slew begins, chosen so the 48-stud hull is still wholly over water
		-- when it starts and wholly on the shoal when it ends.
		seaR = 190,
		groundR = 34,
		-- Her draught while she is afloat, and the swell she rides in on: 3
		-- studs of heave and 6 degrees of roll on one 2.6 s phase, so the two
		-- cannot disagree about which way is down.
		draught = 9,
		swell = 3,
		swellFor = 2.6,
		heel = math.rad(6),
		-- THE BOW LIFTING as the keel finds the sand, and it has to be a BUMP
		-- that starts and ends at zero rather than the server's own `pitch *
		-- (1 - e)`. She is AFLOAT AND LEVEL coming in, so opening the grounding
		-- window on the server's e = 0 pitch would snap the bow 20 degrees down
		-- on one frame; `place`'s pitch term only belongs to a rise that starts
		-- under the sand nose-first, which the settle at the far end does.
		-- Positive is bow-UP: pitch turns about local Z and the bow is +X, so
		-- `CFrame.Angles(0, 0, phi)` takes (1,0,0) toward +Y.
		bowLift = math.rad(9),
		-- Beats.
		tSail = 5.4,
		tSurfaced = 6.3,
		tGround = 11.0,
		tLevel = 13.2,
		tSalute = 14.8,
		tSettle = 16.4,
		-- Colours off the two generators: WK_GHOST (sea-fire teal), WR_LAMP
		-- (the heart-lantern warm), WR_FLARE (muzzle fire), WK_FOAM.
		ghost = Color3.fromRGB(143, 242, 204),
		lamp = Color3.fromRGB(255, 199, 107),
		flare = Color3.fromRGB(255, 241, 199),
		foam = Color3.fromRGB(204, 210, 207),
		smoke = Color3.fromRGB(96, 98, 96),
	}

	local raiseAt = kit.raiseAt -- 17.8 at duration 22 / riseTime 4.2

	-- THE FOUR GUNS, boss-local Roblox, from WrackBodyController's `GUNS` table -
	-- the span centroid the server stands the battery on, the bore's mouth, and
	-- the bore direction. See the header: the four names this file used to
	-- address have not existed since 2026-09-08.
	local guns = {
		{
			at = Vector3.new(16.45, 13.2, -9.5),
			muzzle = Vector3.new(20.4, 13.2, -11.8),
			bore = Vector3.new(0.87, 0, -0.5),
		},
		{
			at = Vector3.new(16.45, 13.2, 9.5),
			muzzle = Vector3.new(20.4, 13.2, 11.8),
			bore = Vector3.new(0.87, 0, 0.5),
		},
		{
			at = Vector3.new(-16.45, 14, -9.5),
			muzzle = Vector3.new(-20.4, 14, -11.8),
			bore = Vector3.new(-0.87, 0, -0.5),
		},
		{ at = Vector3.new(-16.45, 14, 9.5), muzzle = Vector3.new(-20.4, 14, 11.8), bore = Vector3.new(-0.87, 0, 0.5) },
	}

	-- The three hatch lids, from WrackBodyController's AUTHORED rows, in the
	-- bitmask's own order (bit i-1 is `Hatch i`). Used only to put the powder
	-- run's sound on the lid that just threw open.
	local hatches = {
		Vector3.new(-5.94, 11.59, 3.2),
		Vector3.new(-8.94, 12.06, 3.4),
		Vector3.new(-10, 12.18, -3.8),
	}

	-- The quarterdeck station: `Wrack_Skull` is centred (-14.54, 26, 1.1), so
	-- this is the Admiral's own head, which is what the close shot frames and
	-- what the windup turns.
	local admiralAt = Vector3.new(-14.54, 26, 1.1)

	-- ---------------------------------------------------------------- the ship
	--
	-- Adopted on `CreatureId`, not on `Pose`: WrackBodyController's header gives
	-- the reason (a posed Wrack would aim every volley off a dead bearing,
	-- because yaw0 is written by updateBoss's PROWL branch, "which a `pose`d boss
	-- returns before ever reaching"). `kit.actor` writes `CreatureId` BEFORE
	-- parenting, so his adopt rides the `ChildAdded` path like the server's own.
	-- `Exposed` is written false rather than left absent because it is
	-- LEVEL-triggered and polled every frame: the hull must be shut for the whole
	-- cinematic, and saying so costs nothing.
	local stand = kit.actor({
		creatureId = "admiral_wrack",
		name = "Cutscene_AdmiralWrack",
		attrs = { Exposed = false },
	})
	kit.onRealBoss(function()
		stand:destroy()
	end)

	-- Props that ride the hull: the rail lanterns. Their host parts are moved by
	-- `shipPose` with the ship, so they cannot swim away from her as she sails.
	local props = {}
	local base = CFrame.new(kit.center)

	-- THE ONLY THING IN THIS FILE THAT TOUCHES THE PIVOT. `at` is the pivot
	-- position, `yaw` her heading about Y, `pitch` the bow's rise about local Z
	-- (the bow is +X, so a turn about Z lifts it) and `roll` the heel about the
	-- keel, which IS local X. Everything - the approach, the grounding, the
	-- settle and the handoff - is one call into this, so there is no second pose
	-- arithmetic for the handoff to be reconciled against.
	local function shipPose(at: Vector3, yaw: number, pitch: number, roll: number)
		local pivot = CFrame.new(at) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(roll, 0, pitch)
		stand:pivot(pivot)
		base = CFrame.new(pivot.Position + Vector3.new(0, -C.rootHalf, 0)) * pivot.Rotation
		for _, prop in props do
			prop.host.CFrame = base * CFrame.new(prop.at - C.anchor)
		end
	end

	-- THE SERVER'S OWN RISE FRAME, at `e`. `place(0)` is the rise's u = 0 pose
	-- and `place(1)` is her levelled on the shoal.
	local function place(e: number)
		local hop = -C.riseDepth + (C.riseDepth - C.submerge) * e
		shipPose(Vector3.new(kit.center.X, kit.center.Y + hop + C.rootHalf, kit.center.Z), C.yaw0, C.pitch * (1 - e), 0)
	end

	-- A point on the ship, in world space, at wherever she currently is.
	local function shipPoint(at: Vector3): Vector3
		return (base * CFrame.new(at - C.anchor)).Position
	end

	-- --------------------------------------------------------------- geometry
	local mouth = kit.authored(C.mouthDeg)
	local floorSand = kit.floorY(60, mouth)
	local floorParty = kit.floorY(C.partyR, 0)
	-- HER HEADING UNDER SAIL, IN BOTH CONVENTIONS, because this file needs both
	-- and they have opposite signs - which is the whole reason `kit.authored`
	-- exists and is exactly the kind of seam this codebase pays for.
	--
	--   `sailBearing` is a kit.polar BEARING: the direction she TRAVELS, which
	--   is the mouth's bearing turned round (she comes in from the mouth toward
	--   the centre). It is also the convention `WrackBoom` is published in -
	--   `Fn.wrackAngle`'s `atan2(dir.Z, dir.X)`, 0 = +X - so the spar's bearings
	--   below are measured off it and not off the yaw.
	--
	--   `sailYaw` is a MODEL YAW about +Y. `CFrame.Angles(0, y, 0)` maps the
	--   bow (+X) to `(cos y, 0, -sin y)` while `kit.polar` reads a bearing as
	--   `(cos b, 0, sin b)`, so pointing the bow along a bearing is `y = -b`.
	--   Written as the negation rather than as -pi/2, so a re-authored mouth
	--   carries the ship, the boom and the camera with it.
	local sailBearing = mouth + math.pi
	local sailYaw = -sailBearing

	-- The palisade and the spars over it, read off the imported arena where it
	-- exists. `Fleet` is the ring of grounded hulls (r 140-152); `FleetMasts` is
	-- what leans in over the sand, and its bounding box is the ceiling every
	-- shot below stays under. Both fall back to the authored numbers.
	local fleetAt, fleetSize = kit.landmark("Fleet")
	local ringR = if fleetSize then math.max(fleetSize.X, fleetSize.Z) * 0.5 - 6 else C.fleetR
	local ringY = if fleetAt then fleetAt.Y else kit.center.Y + 6
	local _, mastSize = kit.landmark("FleetMasts")
	local mastTop = if mastSize then ringY + mastSize.Y * 0.5 else kit.center.Y + 40

	-- THE CEILING every shot below stays under, so a re-export that raises the
	-- palisade cannot put a camera inside a yard: six studs clear of the leaning
	-- spars, or the authored height when the arena is the procedural stand-in.
	local ceilY = math.min(floorSand + 34, mastTop - 6)

	-- The surf ring OceanController rides on the tide - where the water is when
	-- the cinematic opens, and where it has to go.
	local foamAt, foamSize = kit.landmark("Foam")
	local foamR = if foamSize then math.max(foamSize.X, foamSize.Z) * 0.5 - 3 else C.foamR
	local foamY = if foamAt then foamAt.Y else kit.waterY

	-- ============================================================== THE PIVOT
	--
	-- ONE track over the whole pre-handoff span rather than six. A track reads
	-- `kit.t` itself, so the piecewise curve lives in one place - and, the part
	-- that matters, the kit applies a passed track once at u = 1, which means a
	-- SKIP lands the stand-in on `place(0)` instead of leaving a ship standing
	-- in the air off the palisade.
	--
	-- The five windows, in order:
	--   t < tSail            `place(0)`: under the sand at the centre. Nothing
	--                        on screen, and 190 studs from where she surfaces.
	--   tSail -> tSurfaced   she comes up out of the deep water OUTSIDE the
	--                        palisade, at r seaR on the mouth bearing. She is
	--                        not teleported into frame: she rises into it, on
	--                        the same hop the server's own rise uses.
	--   tSurfaced -> tGround the reach in, riding the swell.
	--   tGround -> tLevel    she takes the ground: the run-in from groundR to 0,
	--                        the slew from sailYaw to yaw0, the heel and the
	--                        draught out, and the bow lifting on
	--                        CreatureService's own `1 - (1 - u)^3`.
	--   tLevel -> tSettle    held level on the shoal - `place(1)`.
	--   tSettle -> raiseAt   she settles back to `place(0)`.
	local function swellAt(t: number): (number, number)
		local phase = (math.pi * 2) * t / C.swellFor
		return C.swell * math.sin(phase), C.heel * math.sin(phase)
	end

	kit.track(0, raiseAt, nil, function()
		local t = kit.t
		if t < C.tSail then
			place(0)
		elseif t < C.tGround then
			-- Afloat. `surface` walks 0 -> 1 across the surfacing window and
			-- stays there; `run` walks the reach in.
			local surface = math.clamp((t - C.tSail) / math.max(C.tSurfaced - C.tSail, 1e-3), 0, 1)
			local run = math.clamp((t - C.tSurfaced) / math.max(C.tGround - C.tSurfaced, 1e-3), 0, 1)
			local radius = C.seaR + (C.groundR - C.seaR) * (run * run * (3 - 2 * run))
			local heave, roll = swellAt(t)
			-- Out of the deep on the server's own hop curve, so the one motion
			-- this file invents starts from the one it copied.
			local rise = 1 - (1 - surface) ^ 3
			local y = kit.center.Y + (-C.riseDepth + (C.riseDepth - C.draught) * rise) + heave * rise + C.rootHalf
			local at = kit.polar(radius, mouth, y)
			shipPose(at, sailYaw, 0, roll * rise)
		elseif t < C.tLevel then
			local u = (t - C.tGround) / (C.tLevel - C.tGround)
			local e = 1 - (1 - u) ^ 3 -- CreatureService's own rise curve
			local heave, roll = swellAt(t)
			-- The keel finds the sand: the run-in, the slew and the heel all die
			-- on the same `e`, so at e = 1 this IS `place(1)` - same position,
			-- same yaw, same pitch, no roll - and the two arithmetics meet at a
			-- value rather than at a coincidence.
			local radius = C.groundR * (1 - e)
			local hop = -C.draught + (C.draught - C.submerge) * e
			local y = kit.center.Y + hop + heave * (1 - e) + C.rootHalf
			local at = kit.polar(radius, mouth, y)
			shipPose(at, sailYaw * (1 - e) + C.yaw0 * e, C.bowLift * math.sin(math.pi * e), roll * (1 - e))
		elseif t < C.tSettle then
			place(1)
		else
			-- CLAMPED, and this is not defensive: the kit applies a track that
			-- has PASSED once at u = 1, which calls this with `kit.t` already
			-- beyond `raiseAt`. Unclamped, `1 - u^2` goes negative there and the
			-- settled pose is BELOW `place(0)` - i.e. the one frame the handoff
			-- is measured against would be the one frame that is wrong.
			local u = math.clamp((t - C.tSettle) / math.max(raiseAt - C.tSettle, 1e-3), 0, 1)
			place(1 - u * u) -- hangs, then goes under fast
		end
	end)

	-- =============================================================== OMEN 0-5.4
	--
	-- The shoal is empty and the tide is high. The camera comes in from the sea
	-- through the palisade's mouth - 46 degrees of clear water on authored
	-- bearing 90, the one bearing with no hull in it - dropping as the water
	-- drops, while the ghost fleet lights hull by hull round the ring behind it.
	-- Nothing solid is on this line: the gap is open to r 132 and the foam ring
	-- it crosses is non-collidable surf lying on the flat. She is 190 studs
	-- further out and 22 studs under the sea for all of it, which is under the
	-- ocean slab and therefore not on screen.
	kit.shot({
		t0 = 0,
		t1 = C.tSail,
		pos = kit.line(kit.polar(foamR + 24, mouth, foamY + 34), kit.polar(112, mouth, floorSand + 12)),
		look = kit.center + Vector3.new(0, 5, 0),
		fov = 68,
	})

	local tide = kit.loop("boatWash", kit.polar(foamR, mouth, foamY))
	kit.at(0.15, function()
		kit.sfx("wrackBell", kit.polar(ringR, mouth, ringY + 6))
	end)
	kit.at(1.1, function()
		kit.sfx("wrackHullGroan", kit.center)
	end)
	kit.rumble(0.8, 5.2, 0.010)

	-- THE TIDE RUNS OUT, and it runs out wrong: rings leaving the shoal instead
	-- of arriving on it, faster each time, with the wet flat behind them. Eight
	-- of them, indexed rather than random - `kit.every` hands the call an index
	-- and the whole run has to be identical on every party member's screen.
	kit.every(1.0, 5.2, 0.5, function(i)
		local from = 40 + i * 14
		kit.vfx.ring(kit.center + Vector3.new(0, 0.4, 0), from, from + 96, 1.6 - i * 0.08, C.foam)
		local bearing = kit.authored(C.mouthDeg + (i % 2 == 0 and 26 or -26) * (1 + i * 0.4))
		kit.vfx.splash(kit.polar(96 + i * 6, bearing, floorSand + 0.6), 1.4 + i * 0.15)
	end)
	kit.at(2.6, function()
		kit.sfx("wrackBilgeblow", kit.polar(C.sandR, mouth, floorSand))
	end)

	-- WHAT THE TIDE WAS HIDING: thirty grounded hulls, and every one of them
	-- still crewed. Twelve lights round the ring, skipping the mouth, built UP
	-- FRONT with no brightness and raised by a track each rather than created
	-- inside an `every`: a repeater is wound past by a skip, and a fleet that
	-- lights only when nobody skipped is a fleet that is dark half the time.
	local span = 360 - C.gapDeg
	for i = 0, 11 do
		local bearing = kit.authored(C.mouthDeg + C.gapDeg / 2 + span * (i / 11))
		local light = kit.light(kit.polar(ringR, bearing, kit.floorY(ringR, bearing) + 9), C.ghost, 74, 0)
		local t0 = 1.4 + i * 0.29
		kit.track(t0, t0 + 0.4, "out", function(u)
			light.Brightness = 2.6 * u
		end)
		kit.at(t0, function()
			kit.sfx(i % 3 == 0 and "wrackBrazier" or "wrackWisps", light.Parent and light.Parent.Position)
		end)
	end

	-- ...and then the sea is simply gone, and the arena is silent. The loop
	-- stops here rather than at the end: the quiet IS the omen, and it is what
	-- the bell she answers it with lands into.
	kit.at(5.0, function()
		kit.stopLoop(tide)
		kit.sfx("wrackLadybelow", kit.center)
	end)

	-- ======================================================= SHE SAILS IN 5.4-11
	--
	-- Low on the water at the mouth, watching her come up out of the deep and
	-- through the gap, then a line in to meet her. The camera is 12 studs off
	-- her track and never on it: she runs the mouth bearing exactly, and both
	-- shots sit to the side of it.
	kit.shot({
		t0 = C.tSail,
		t1 = 8.4,
		pos = kit.polar(C.foamR + 6, mouth - math.rad(9), foamY + 9),
		look = function(u)
			return kit.polar(C.seaR + (110 - C.seaR) * u, mouth, kit.center.Y + 12)
		end,
		fov = 70,
		blendIn = 0.6,
	})
	kit.shot({
		t0 = 8.4,
		t1 = C.tGround,
		pos = kit.line(
			kit.polar(126, mouth - math.rad(22), math.min(floorSand + 22, ceilY)),
			kit.polar(72, mouth - math.rad(40), math.min(floorSand + 15, ceilY))
		),
		look = function(u)
			return kit.polar(110 + (C.groundR - 110) * u, mouth, kit.center.Y + 14)
		end,
		fov = 66,
		blendIn = 0.8,
	})

	kit.at(C.tSail, function()
		kit.sfx("bossRise", kit.polar(C.seaR, mouth, kit.waterY))
		kit.sfx("wrackHullGroan", kit.polar(C.seaR, mouth, kit.waterY))
		kit.vfx.splash(kit.polar(C.seaR, mouth, kit.waterY), 14)
	end)
	kit.at(C.tSurfaced, function()
		kit.sfx("wrackLongboat", kit.polar(C.seaR - 20, mouth, kit.waterY))
	end)

	-- HER WAKE, and the water off her bow for the whole reach. Placed off her
	-- LIVE hull rather than off a radius, so it stays with her whatever the
	-- swell is doing.
	kit.every(C.tSurfaced, C.tGround, 0.34, function(i)
		local bow = shipPoint(Vector3.new(24, 2, 0))
		kit.vfx.splash(Vector3.new(bow.X, kit.waterY + 0.5, bow.Z), 3.2)
		if i % 3 == 0 then
			kit.vfx.ring(Vector3.new(bow.X, kit.waterY + 0.4, bow.Z), 16, 58, 1.2, C.foam)
		end
	end)
	kit.rumble(C.tSurfaced, C.tLevel, 0.014)

	-- THE BOOM, on each tack. `WrackBoom` is the spar's live WORLD bearing in
	-- `Fn.wrackAngle`'s convention (`atan2(dir.Z, dir.X)`, 0 = +X) and its
	-- PRESENCE is the level: nil is "no boom out", which is the state a shot-away
	-- tackle has to be able to reach as well as a finished sweep. The controller
	-- derives the spar's elevation itself from the hull's own envelope
	-- (`RIG.boomAim`, "the lowest peak this bearing allows without the spar going
	-- through the ship") because THE WIRE CARRIES YAW ONLY - so all this has to
	-- get right is which way the wind is on.
	--
	-- Set to leeward of her heading, swapped once mid-reach, and CLEARED before
	-- she takes the ground: the real boss arrives with the spar stowed, and the
	-- channel eases home from wherever it was latched rather than snapping, so
	-- clearing it 2.0 s early is what makes the handoff quiet.
	kit.at(C.tSurfaced + 0.2, function()
		stand:set("WrackBoom", sailBearing + math.rad(104))
		kit.sfx("wrackBoomsweep", shipPoint(Vector3.new(0.13, 16.34, -18.25)))
	end)
	kit.at(8.8, function()
		stand:set("WrackBoom", sailBearing - math.rad(104))
		kit.sfx("wrackBoomsweep", shipPoint(Vector3.new(0.13, 16.34, -18.25)))
	end)
	kit.at(C.tGround - 1.0, function()
		stand:set("WrackBoom", nil)
	end)

	-- THE LADY UNSHIPS. `Wrack_Figurehead` and `Wrack_FigureheadGlow` are real
	-- pack pieces, and `figureheadFlight` flies them onto whatever model near the
	-- hull carries `WrackDive` - keyed on the ATTRIBUTE, deliberately, so the
	-- controller "never has to agree with `Bosses` about a row name it cannot see
	-- change". A second `kit.actor` carrying it is therefore all a cutscene needs
	-- to fly her, and the value 0 is the honest one: 0 is "swinging out or
	-- re-arming", `n` is the n-th DAMAGING pass, and this is not a pass. She flies
	-- ahead of the ship down the mouth bearing and redocks before the ground, so
	-- the stem is bare while she is out and carries her again for the handoff -
	-- the channel eases at rate 5, so 3.6 s of dock is ~18 time constants.
	local lady = kit.actor({
		name = "Cutscene_WrackLady",
		center = kit.polar(C.seaR - 30, mouth, kit.center.Y + 22),
		attrs = { WrackDive = 0 },
	})
	kit.track(C.tSurfaced + 0.4, C.tGround - 1.4, "inout", function(u)
		local radius = (C.seaR - 30) + (52 - (C.seaR - 30)) * u
		local bearing = mouth - math.rad(46) * u
		local y = kit.center.Y + 22 + 16 * math.sin(math.pi * u)
		lady:pivot(CFrame.lookAt(kit.polar(radius, bearing, y), kit.center + Vector3.new(0, 16, 0)))
	end)
	kit.at(C.tGround - 1.4, function()
		lady:destroy()
		kit.sfx("wrackAnchorline", shipPoint(Vector3.new(22.27, 8.55, 0)))
	end)

	-- GUNPORTS, DECK BY DECK. `WrackHatches` is a bitmask LEVEL on the model -
	-- which is exactly why a cutscene can drive it, and why it can be HELD open
	-- through the salute instead of having to be re-pulsed. THREE lids: masks 1,
	-- 3, 7, and the old fourth write (`mask = 15`) set a bit with no `Hatch4`
	-- behind it and is gone.
	for i, mask in { 1, 3, 7 } do
		kit.at(8.0 + (i - 1) * 0.62, function()
			stand:set("WrackHatches", mask)
			kit.sfx("wrackPowderrun", shipPoint(hatches[i]))
		end)
	end

	-- LANTERNS ALONG THE RAILS. Six hosts riding the hull (see `props`), lit as
	-- she comes in. The rail is at boss-local y 14.5 - `Hull` is centred 7.83
	-- with a 13.47 box - and z +-7 is her beam.
	for i = 0, 5 do
		local at = Vector3.new(-16 + i * 6.4, 14.5, if i % 2 == 0 then 7 else -7)
		local light = kit.light(kit.center, C.lamp, 30, 0)
		local host = light.Parent
		if host then
			table.insert(props, { host = host, at = at })
		end
		local t0 = 6.6 + i * 0.18
		kit.track(t0, t0 + 0.5, "out", function(u)
			light.Brightness = 2.2 * u
		end)
	end
	-- Registered AFTER the props exist so the first placement carries them; the
	-- pivot track above would otherwise not touch them until its next frame.
	place(0)

	-- ====================================================== SHE TAKES THE GROUND
	--
	-- From the sand, looking up the bow as she comes on. The bowsprit reaches
	-- ~28 studs from the boss origin, so r 52 at the closest point is
	-- twenty-four studs clear of her and 132 - 52 = 80 studs inside the sand's
	-- edge; the shot never goes above 28, which is under the spars leaning in
	-- over the rim (`mastTop`).
	kit.shot({
		t0 = C.tGround,
		t1 = 13.4,
		pos = kit.line(kit.polar(74, 0.34, floorSand + 6), kit.polar(52, 0.10, floorSand + 26)),
		look = function(u)
			return kit.center + Vector3.new(0, 4 + 22 * u, 0)
		end,
		fov = 55,
		blendIn = 0.8,
	})
	kit.at(C.tGround, function()
		kit.sfx("wrackHullGroan", kit.center)
		kit.sfx("bossSlam", kit.center)
		kit.shake(0.05, 1.2, 0.02)
	end)
	-- Sand and water off her shoulders for the whole grounding.
	kit.every(C.tGround, C.tLevel, 0.28, function(i)
		local bearing = kit.authored(i * 61)
		kit.vfx.splash(kit.polar(26 + (i % 3) * 7, bearing, floorSand + 1), 2.2)
		if i % 3 == 0 then
			kit.vfx.ring(kit.center + Vector3.new(0, 0.4, 0), 24, 74, 1.2, C.foam)
		end
	end)

	-- ============================================================== THE SALUTE
	--
	-- Close on the quarterdeck for the tell, then wide from the party's own
	-- bearing for the broadside.
	kit.shot({
		t0 = 13.4,
		t1 = C.tSalute,
		pos = kit.line(
			kit.polar(46, kit.authored(196), math.min(floorSand + 30, ceilY)),
			kit.polar(34, kit.authored(206), math.min(floorSand + 27, ceilY))
		),
		look = function()
			return shipPoint(admiralAt)
		end,
		fov = 50,
		blendIn = 0.7,
	})
	kit.shot({
		t0 = C.tSalute,
		t1 = C.tSettle,
		pos = kit.line(
			kit.polar(78, 0.08, math.min(floorParty + 16, ceilY)),
			kit.polar(96, 0.02, math.min(floorParty + 24, ceilY))
		),
		look = kit.center + Vector3.new(0, 16, 0),
		fov = 84,
		blendIn = 0.5,
	})

	-- THE SABRE. `windup` is the Admiral's own tell channel - admHigh, and
	-- admPoint/admLook when an aim is given - aimed at the party's ring, so the
	-- salute is addressed to the people it is meant for. No `shape` is passed:
	-- the shape field is what picks the DUELIST's four gestures and "a wrong
	-- gesture is worse than a missing one", so the ship gets its own tell.
	kit.at(13.6, function()
		if Wrack and Wrack.cue then
			Wrack.cue(stand.model, "windup", {
				duration = 1.5,
				aim = kit.polar(C.partyR, 0, floorParty + 4),
			})
		end
		kit.sfx("bossTell", shipPoint(admiralAt))
	end)

	-- THE BROADSIDE. `fire` with no `at` is the radial case by arithmetic rather
	-- than by special case - the hull's own base point is 13.3 studs from the
	-- nearest gun centroid and so matches none, and matching none is precisely
	-- how the wire says "a broadside": every live deck speaks, gunRecoil and
	-- muzzleFlash both, and the sabre sweeps down with it (admSweep, admFlick).
	kit.at(C.tSalute, function()
		if Wrack and Wrack.cue then
			Wrack.cue(stand.model, "fire", {})
		end
		kit.sfx("wrackBroadside", kit.center)
		kit.flash(C.flare, 0.5, 0.5)
		kit.shake(0.075, 1.0, 0.03)
		-- ON THE BRASS, and this is the bug: the flare goes at the MUZZLE and 2
		-- studs along the BORE, both of them the controller's own numbers for
		-- these four guns. The version this replaces used four boss-local points
		-- from the careened ship and put every flash in open air.
		for _, gun in guns do
			local muzzle = shipPoint(gun.muzzle + gun.bore * 2)
			kit.vfx.flash(muzzle, C.flare, 7, 0.4)
			kit.vfx.burst(muzzle, C.flare, 10)
		end
	end)

	-- THE SMOKE OF IT, rolling off her for a second and a half. `WrackArena_
	-- DecoSailRag` is the torn canvas lying round the shoal - the arena's own
	-- rag - cloned small and thrown up off each bore, so the smoke is authored
	-- geometry tumbling rather than a primitive. `kit.mesh` degrades to the slab
	-- `kit.part` would have drawn if the arena was never imported, so this is
	-- safe on any machine, and `kit.vfx.puff` still carries the volume.
	for i, gun in guns do
		local from = shipPoint(gun.muzzle + gun.bore * 3)
		local rag = kit.mesh("WrackArena", "DecoSailRag", {
			Scale = 0.055,
			CFrame = CFrame.new(from),
			Color = C.smoke,
			Transparency = 0.2,
		})
		local drift = gun.bore * 26 + Vector3.new(0, 34, 0)
		kit.tweenPart(
			rag,
			{ CFrame = CFrame.new(from + drift) * CFrame.Angles(2.1, 1.4, 0.7), Transparency = 1 },
			C.tSalute + i * 0.07,
			C.tSalute + 1.7 + i * 0.07,
			"out"
		)
	end
	kit.every(C.tSalute + 0.05, C.tSalute + 1.6, 0.16, function(i)
		local gun = guns[(i % 4) + 1]
		kit.vfx.puff(shipPoint(gun.muzzle + gun.bore * 3 + Vector3.new(0, 4 + i * 2.0, 0)), C.smoke, 3.4)
	end)

	-- =============================================================== THE SETTLE
	--
	-- And then she goes back down - the pivot track above walks `place` from 1 to
	-- 0 across tSettle -> raiseAt, which IS the real rise's first frame played
	-- backwards. THE HATCHES SHUT WITH HER: the real boss arrives with them
	-- closed, and the version this replaces left them open at the cut, which was
	-- a visible pop on three lids. The camera pulls out onto the party's bearing
	-- while she sinks, so the handoff shot is already in place when the server's
	-- boss arrives.
	kit.at(C.tSettle, function()
		stand:set("WrackHatches", 0)
		kit.sfx("wrackHullGroan", kit.center)
	end)
	kit.shot({
		t0 = C.tSettle,
		t1 = raiseAt,
		pos = kit.line(kit.polar(96, 0.02, math.min(floorParty + 24, ceilY)), kit.polar(98, 0, floorParty + 17)),
		look = function(u)
			return kit.center + Vector3.new(0, 22 - 20 * u, 0)
		end,
		fov = 60,
		blendIn = 0.6,
	})
	kit.at(raiseAt - 0.55, function()
		kit.sfx("wrackBilgeblow", kit.center)
		kit.vfx.splash(kit.center, 6)
		kit.vfx.ring(kit.center + Vector3.new(0, 0.4, 0), 30, 120, 1.6, C.foam)
		kit.shake(0.03, 0.7, 0.012)
	end)
	kit.at(raiseAt - 0.2, function()
		kit.loop("boatWash", kit.polar(C.sandR, mouth, floorSand))
	end)

	-- ============================================================ ROAR / handoff
	--
	-- THE HANDOFF, stated in plain sight rather than left implied by where the
	-- tweens stopped: at `raiseAt` the stand-in is at `place(0)`, which is
	-- `PivotTo(poseCFrame(creature, -riseDepth, 0, rad(-20)))` - the server's own
	-- `e = 0` frame - with `Exposed = false`, `WrackHatches = 0`, `WrackBoom`
	-- cleared and eased home since tGround - 1.0, and the Lady docked since
	-- tGround - 1.4. The last 4.2 seconds are the genuine rise on the genuine
	-- rig and this script owns nothing but the camera and the noise over it.
	--
	-- The shot sits where a solo challenger stands - r 88 on bearing 0, the ring
	-- BossArenaService drops the party on - and pushes in a few studs, so the
	-- controller's 0.8 s blend back to the player's own camera is almost no move
	-- at all. Height stays 12-17 over the sand: well under `mastTop`, and the
	-- whole path is over open shoal.
	kit.shot({
		t0 = raiseAt,
		t1 = kit.duration,
		pos = kit.line(kit.polar(98, 0, floorParty + 17), kit.polar(C.partyR, 0, floorParty + 12)),
		look = function(u)
			return kit.center + Vector3.new(0, 6 + 16 * u, 0)
		end,
		fov = 62,
		blendIn = 1.0,
	})
	kit.rumble(raiseAt, raiseAt + kit.riseTime * 0.8, 0.016)

	-- The card lands on the beat CreatureEventController's own bossRise handler
	-- already roars and shakes on.
	kit.at(raiseAt + 0.85 * kit.riseTime, function()
		kit.card(string.upper(kit.boss.shortName), "the Fleet-Eater")
		kit.shake(0.085, 1.3, 0.035)
		kit.sfx("wrackBell", kit.center)
		kit.vfx.shockwave(kit.center + Vector3.new(0, 1, 0), 20, 150, 1.8, C.foam, 0.4)
	end)
end
