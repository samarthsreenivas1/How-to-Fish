--!nonstrict
-- PyreliskIntro.luau
-- Pyrelisk, the Ashfall Colossus: the 26-second intro cinematic. Written
-- against CutsceneKit (src/Client/Modules/CutsceneKit.luau) and the rig
-- vocabulary PyreliskBodyController reads TODAY - Rise / FaceAngle / AimAngle
-- / AimSide / Attack / AttackBlend / Strike / Slump / Planted / Stance /
-- Stances / Exposed / SeamsOpen / SeamsBroken / SeamMeterL / SeamMeterR
-- (PyreliskBodyController.readTarget, :1072-1105) - plus `PoseCenter`, which
-- is the newest of them and the reason this cinematic can move the colossus
-- at all. See IT WALKS below.
--
-- ------------------------------------------------------ IT READS THE RIG
--
-- THE FIRST VERSION OF THIS FILE HARD-CODED THE RIG'S NUMBERS AND THE RIG
-- MOVED UNDER IT. The colossus was 277 studs of crown with a 228-stud arm; it
-- is now 206.9 with a 150-stud arm, and every height, camera distance and
-- impact point derived from the old figures was quietly 30% too big - the
-- hand-on-the-rim beat landed 62 studs short of the rock it was reaching for,
-- and nothing in any gate could see it.
--
-- So the rig's numbers are no longer written down here. `PyreliskPath` is
-- required at module load and asked, at registration, for CROWN, RISE_DEPTH,
-- NECK, the seam count and - through `fistOffset`, the function the fight's
-- own telegraphs are drawn from - where a given pose puts a fist at a given
-- strike fraction. `TUNE` below keeps the same numbers ONLY as fallbacks, for
-- the case where the require fails or an export is renamed: a cinematic that
-- draws slightly wrong is better than one that errors, but neither is what
-- should happen, so the fallbacks say what they were measured from.
--
-- ---------------------------------------------------------------- ALTITUDE
--
-- THIS ARENA IS NOT AT SEA LEVEL and that is the trap the whole file is built
-- around. The Ashfall Throne is a volcano SUMMIT: its rim path is 292 studs
-- above the water (BossArenas.volcano's meshBottom note, arena_gen.py's
-- PY_RIM_WORLD_Y), the caldera lava lake is flush with that same path
-- (PyreliskPath: "z = 0 is the caldera lake's surface, and the arena's rim
-- path is at that same height"), and the cloud deck that hides the mountain's
-- cut floats 260 studs BELOW the path. So nothing here is measured off
-- `kit.waterY`. Every height is `pathY` plus an offset, and `pathY` is
-- probed - `kit.floorY` on the rim path, cross-checked against `kit.center.Y`,
-- which BossService already probed at the roam radius for exactly this reason.
--
-- ---------------------------------------------------------------- THE RISE
--
-- The handoff is fixed by what the SERVER actually plays. CreatureService's
-- `rising` branch for an entrenched, POSED boss (CreatureService.luau, the
-- two lines at **:18279-18280**, inside the `if def.pose then
-- Fn.hideColossusModel(creature) end` arm at :18267-18271 - the citation this
-- file carried before, :15594-15595, is stale; the branch moved) publishes
-- BOTH channels from u = 0:
--
--     state.rise  = 1 - (1 - u) ^ 3       -- 0 at u = 0
--     state.slump = 1 - (1 - (1 - u) ^ 2) -- 1 at u = 0
--
-- so the real rise's FIRST FRAME is Rise 0, Slump 1 - the body RISE_DEPTH
-- studs down in its own lake (PyreliskPath.lift) with its head dipped and its
-- jaw hanging. That is the pose this script's stand-in holds at
-- `kit.raiseAt`, and it is why the true-centre stand-in must be BACK DOWN at
-- Rise 0 by then: a stand-in that ended standing would drop 40 studs on the
-- frame the real rig landed. It does spend `Rise` in between - see IT WALKS
-- for the arithmetic that forces it to - but every one of those studs is paid
-- back before the handoff.
--
-- ------------------------------------------------------- THE TWO STAND-INS
--
-- The user's beat is "the rocks in the lake turn out to be the top of its head
-- and shoulders". At the true arena centre that beat cannot exist: `Rise` is
-- worth RISE_DEPTH studs and the colossus is CROWN studs tall, so even at
-- Rise 0 it is a 167-stud mountain standing in plain sight. So the OMEN and
-- the first two shrugs are played by a stand-in whose `PoseCenter` is sunk
-- `CROWN - CROWN_OUT` studs below the lake - deep enough that only the crown
-- shards break the lava - and its `Rise` is the shrug. The third shrug is a
-- CUT: an ash blast fills the screen, the sunken stand-in is destroyed, and
-- the true-centre stand-in is created behind it at Rise 1 / Slump 1, standing
-- its full height. The scale reveal is the cut, which is also the only way
-- that much growth fits in a beat.
--
-- Both stand-ins are the SAME rig ("never a second rig"): one Pose =
-- "pyrelisk" model at a time, one after the other, never both on screen.
--
-- ------------------------------------------------------------- IT WALKS
--
-- The old cut of this file shrugged twice and then stood still for six
-- seconds. It now takes ONE STEP, and the step is the character: a 206.9-stud
-- mountain putting a fist on the rock and hauling itself forward.
--
-- `PoseCenter` IS RE-READ EVERY FRAME, verified in the worktree, not assumed:
-- `PyreliskBodyController.drawBody` reads it at **:1324-1326** behind the
-- APPENDIX K ITEM 2 note at :1307-1321 ("`PoseCenter` IS RE-PUBLISHED, SO IT
-- IS READ EVERY FRAME... `adoptBoss` seeds the state from it once, and a
-- cached centre was correct for exactly as long as this fight happened in one
-- place"). `adoptBoss`'s own read (:956) is still only the seed. So writing
-- the attribute per frame MOVES the drawn body, and the step below is a real
-- translation rather than a lean. If that read is ever pulled back out of
-- `drawBody`, this file's step silently becomes a no-op - the colossus would
-- play the whole handfall standing still - so it is cited here by line.
--
-- THE STEP IS OUT AND BACK, AND THAT IS THE ONE HONEST LIMIT. `PoseCenter`
-- must be exactly `kit.center` again BEFORE the handoff, because the server
-- seeds the real body from `creature.anchor` - the perch it was spawned on,
-- which no client write moves. A stand-in that ended 46 studs downrange would
-- teleport back on the frame the real rig landed, which is the pop this whole
-- file exists to avoid. So the only travel shape available is a step out and
-- a step back; do NOT try to walk it in from the horizon.
--
-- AND `handfall` IS PLAYED AT RISE 1, WHICH IS WHY THE BODY IS UP FOR IT.
-- Every hand-down shape in the book is MEASURED to rest ON the rim path at
-- Rise 1 - `PLANT`'s whole note is that its fist has to land on the path at
-- r 188 (PyreliskPath.luau:408-421), and `handfall`'s impact keyframe
-- (PyreliskPath's `TRACK.handfall`, :682-728, at 0.975 phase = 0.95 strike =
-- CreatureService's `K.HANDFALL_IMPACT` :3101) lands the same fist at the
-- same radius. At Rise 0 every one of them drives the fist forty studs INSIDE
-- the rock, which is a visual bug rather than a beat. So the standing stand-in
-- is created at Rise 1, walks and plants at Rise 1, and only then sinks to the
-- handoff's Rise 0 - under the ashfall, while the arms are going up, so the
-- forty studs read as the mountain settling rather than as a drop. The sink is
-- written as an attribute track and the controller's own `approach`
-- (RISE_RATE 1.6, :144) lags it by a time constant of 0.625 s, which is why
-- the track finishes at `STEP.throw1` - 1.45 s before `raiseAt` - rather than
-- on it. Held at 0 for those 1.45 s the drawn rise arrives inside 0.01, i.e.
-- under half a stud of the forty; on the frame the real rig lands there is
-- nothing to see.
--
-- `handfall` is NOT in `BOTH_ARMS` (PyreliskPath:1001 - that set is
-- collapse/ashfall/fallen), so it is a ONE-ARM shape and `AimSide` picks
-- which. The step plants the `AimSide = -1` fist and then flips `AimSide` to
-- +1: the other arm is the one cocked for the next stride, which is the whole
-- reason a single step reads as a walk rather than as a stumble.
--
-- The arms-up beat that follows is unchanged: `ashfall`, the one attack in
-- `BOTH_ARMS` that raises them, "both arms up and wide, wrists out past the
-- shoulder rubble... the marks land under everybody at once" (PyreliskPath's
-- own note on the track). It is the summit shedding - the ash the user asked
-- for, coming off the body rather than out of the sky.
--
-- ------------------------------------------------------- MESHES, NOT SLABS
--
-- The user's complaint is that the intros animate Roblox primitives instead of
-- the Blender models. Three of this file's four prop families were slabs; two
-- are now the arena's own geometry and one is gone:
--
--   * THE SIX MOLTEN SHEETS are `kit.mesh("PyreliskArena", "CrustDeco")`
--     clones on `kit.meshTween` - the arena's own cooled-crust plates, shed
--     rock that is actually rock.
--   * THE NINE MONOLITH SLABS ARE DELETED. `PyreliskArena_Teeth` is ONE
--     MERGED OBJECT - `build_py_teeth` grows all nine cones and their skirts
--     into a single bmesh and returns one `finish("PyreliskArena_Teeth", ...)`
--     (arena_gen.py:4360-4410) - so nine `kit.mesh` clones would stack nine
--     complete monolith fields on top of the arena's own. The monoliths are
--     ALREADY THERE, imported, standing on the path. They needed lighting, not
--     duplicating, so what is left is `kit.light` at `BossArenas.volcano
--     .stones` and nothing drawn at all.
--   * THE ASH EMITTER'S HOST STAYS A `kit.part`, deliberately, and this is the
--     one place the redesign's "clone `_CloudDeco`" reads wrong on contact
--     with the asset. `PyreliskArena_CloudDeco` is a ~1980-stud disc carrying
--     190 billows, authored that size on purpose to sit just inside Roblox's
--     2048-stud MeshPart cap (arena_gen.py:4495-4551; import-checklist row 7n:
--     "DO NOT scale on import"). A second copy of it hung 300 studs over the
--     caldera would be a cloud SEA in the sky, not a fall of ash, and it is the
--     single largest part in the game. The host here is `Transparency = 1` and
--     is never drawn - it is an emitter anchor, so there is no primitive on
--     screen to replace. The `ParticleEmitter` is the whole visual.
--   * THE 1240-STUD NEON LAVA CYLINDER STAYS, for the reason its own block
--     gives: a PointLight caps at Range 60 and the deck it has to light is
--     1200 across. No mesh substitutes for a light.
--
-- Net: sixteen drawn primitives become one (the cylinder) plus six clones of
-- authored arena geometry.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BossArenas = require(Shared.Config.BossArenas)

-- THE RIG'S OWN MODULE, pcall'd. It is being remodelled by another lane and a
-- require that threw at module load would take the whole cinematic down (and,
-- through BossCutsceneController's lazy require, log a boot warning for a
-- boss nobody summoned). Absent, every number below falls back to the value
-- it was last measured at, named in TUNE.
local PyreliskPath = nil
do
	local ok, module = pcall(function()
		return require(Shared.Modules.PyreliskPath)
	end)
	if ok then
		PyreliskPath = module
	else
		warn("[PyreliskIntro] PyreliskPath unavailable; falling back to measured constants")
	end
end

return function(kit)
	-- ============================================================== the dial
	--
	-- Arena and camera numbers, plus a FALLBACK for every rig number the block
	-- after this one reads out of PyreliskPath. Each fallback says where it was
	-- measured, so a stale one is a discrepancy somebody can see rather than a
	-- number somebody has to re-derive.
	local TUNE = {
		-- --- the rig, FALLBACKS ONLY (measured 2026-09-09 against the rebuilt
		--     pack; the live values are read from PyreliskPath below)
		POSE = "pyrelisk", -- PyreliskBodyController POSE_NAME, :50
		CROWN = 206.9, -- PyreliskPath.CROWN, :193
		RISE_DEPTH = 40.0, -- PyreliskPath.RISE_DEPTH, :236
		NECK_Y = 152.0, -- PyreliskPath.NECK.Y (authored 8, 0, 152), :194
		SEAM_COUNT = 7, -- #PyreliskPath.SEAMS, :252
		-- `ashfall` at full strike, from PyreliskPath.fistOffset("ashfall",
		-- side, 1): the keyframe book's last frame plus the body's own
		-- commitment. Mirrors exactly between the flanks because ashfall's
		-- tilt is 0, so one radius and one height serve both arms.
		ASHFALL_FIST_R = 191.2,
		ASHFALL_FIST_Y = 230.8, -- body-local; world = pathY - RISE_DEPTH + this
		ASHFALL_FIST_BEARING = math.rad(110.7), -- local, for AimSide -1
		-- ...and the same three for `handfall` at its impact fraction, from
		-- PyreliskPath.fistOffset("handfall", -1, HANDFALL_IMPACT). It is a
		-- hand-DOWN shape, so the height is ~0: the fist lands ON the path,
		-- which is what PLANT's note measures and what this step relies on.
		HANDFALL_IMPACT = 0.95, -- CreatureService K.HANDFALL_IMPACT, :3101
		HANDFALL_FIST_R = 188.0,
		HANDFALL_FIST_Y = 0.0, -- body-local; ~0 by construction, see above
		HANDFALL_FIST_BEARING = math.rad(9.0), -- local, for AimSide -1

		-- --- the cinematic's own shape
		CROWN_OUT = 41.0, -- how far the sunken stand-in's crown clears the lava at Rise 1
		OMEN_RISE = 0.28,
		SHRUG_ONE = 0.62,
		-- THE STEP. 46 studs, out along the arrival bearing and back again -
		-- roughly a quarter of the body's own width, which is what one stride
		-- of something this size looks like. See IT WALKS for why it is out
		-- and back rather than anywhere.
		STEP_OUT = 46.0,

		-- --- the arena (arena_gen.py build_pyrelisk, BossArenas.volcano)
		LAKE_R = 120.0, -- PY_LAKE_R: the moat the colossus stands in
		PATH_R = 232.0, -- PY_PATH_R: walkable to here
		LIP_R = 246.0, -- PY_LIP_R
		LIP_CREST = 11.0, -- PY_LIP_CREST above the path
		TEETH_TOP = 21.0, -- build_py_teeth: tallest monolith, path-relative
		CLOUD_DZ = -260.0, -- PY_CLOUD_Z: the deck PLANE below the rim path
		CLOUD_GLOW_R = 620.0, -- the lit disc: inside the deck's own 880
		GATE_DEG = 90.0, -- PY_GATE_BEARING, authored degrees
		-- Where the party lands. BossArenaService.ringPositions puts player i
		-- of n at bearing (i/n)*2pi on a circle of `arena.radius + 8`; a solo
		-- arrival is i = n = 1, i.e. bearing 0. The last shot ends there so the
		-- controller's 0.8 s blend back to the player's camera is short.
		ARRIVAL = 0.0,
		RING_PAD = 8.0,
		EYE = 6.0, -- camera eye height above the path at the ring

		-- --- clearance (see the camera block; all path-relative)
		PROBE_R = 170.0, -- where pathY is probed: on the path, inside CLEAR_R
		PROBE_TRUST = 40.0, -- disagree with kit.center.Y by more than this: distrust
		TEETH_CLEAR = 20.0, -- how far above the monoliths a shot must pass
		CLOUD_CLEAR = 45.0, -- how far above the billow tops the far shot flies
		ARM_CLEAR = 60.0, -- how far outside the reaching arms a shot must stay

		-- --- colour
		MAGMA = Color3.fromRGB(242, 48, 4),
		SEAM_COLOR = Color3.fromRGB(209, 29, 3),
		ASH = Color3.fromRGB(84, 79, 80),
		EMBER = Color3.fromRGB(255, 138, 32),
	}

	-- ============================================================== the rig
	--
	-- Everything the body's own module knows, asked once, here. `fistOffset`
	-- is the same call the fight's telegraphs are drawn from, so an impact
	-- this script marks and the fist the player watches arrive are the same
	-- point by construction rather than by two people agreeing on a number.

	local function rigNumber(name: string, fallback: number): number
		local value = PyreliskPath and (PyreliskPath :: any)[name]
		return if type(value) == "number" then value else fallback
	end

	local RIG = {
		crown = rigNumber("CROWN", TUNE.CROWN),
		riseDepth = rigNumber("RISE_DEPTH", TUNE.RISE_DEPTH),
		neckY = TUNE.NECK_Y,
		seamAll = bit32.lshift(1, TUNE.SEAM_COUNT) - 1,
	}
	do
		local neck = PyreliskPath and (PyreliskPath :: any).NECK
		if typeof(neck) == "Vector3" then
			RIG.neckY = neck.Y
		end
		local seams = PyreliskPath and (PyreliskPath :: any).SEAMS
		if type(seams) == "table" and #seams > 0 and #seams <= 31 then
			RIG.seamAll = bit32.lshift(1, #seams) - 1
		end
	end

	-- Where a pose puts its fist, in body-local polar terms, at a given strike
	-- fraction: bearing off the body's own facing, radius from its axis, and
	-- height above its base. Falls back to the measured figures for the two
	-- poses this file asks about - `ashfall` (arms up, the bellow) and
	-- `handfall` (the fist the step plants).
	local FIST_FALLBACK = {
		ashfall = { TUNE.ASHFALL_FIST_BEARING, TUNE.ASHFALL_FIST_R, TUNE.ASHFALL_FIST_Y },
		handfall = { TUNE.HANDFALL_FIST_BEARING, TUNE.HANDFALL_FIST_R, TUNE.HANDFALL_FIST_Y },
	}
	local function fistOffset(poseName: string, side: number, strike: number): (number, number, number)
		if PyreliskPath and type((PyreliskPath :: any).fistOffset) == "function" then
			local ok, bearing, radius, height = pcall((PyreliskPath :: any).fistOffset, poseName, side, strike)
			if ok and type(bearing) == "number" and type(radius) == "number" and type(height) == "number" then
				return bearing, radius, height
			end
		end
		local sign = if side < 0 then 1 else -1
		local row = FIST_FALLBACK[poseName] or FIST_FALLBACK.ashfall
		return sign * row[1], row[2], row[3]
	end

	-- ============================================================== geometry

	-- The rim path, probed rather than assumed. `kit.center.Y` is already the
	-- arena's floor datum (BossService.arenaPosition probes it at the roam
	-- radius), so the two should agree to within a stud; when they do not, the
	-- probe found a monolith or a hole and the datum wins.
	local pathY = kit.floorY(TUNE.PROBE_R, TUNE.ARRIVAL)
	if math.abs(pathY - kit.center.Y) > TUNE.PROBE_TRUST then
		pathY = kit.center.Y
	end

	-- Landmarks first, authored numbers as the fallback: the procedural
	-- stand-in arena has no `PyreliskArena_*` parts at all.
	local function topOf(name: string, fallback: number): number
		local at, size = kit.landmark(name)
		if at and size then
			return at.Y + size.Y * 0.5
		end
		return fallback
	end

	local lakeY = topOf("Lava", pathY + 0.1)
	local teethTop = topOf("Teeth", pathY + TUNE.TEETH_TOP)
	local lipTop = topOf("Rim", pathY + TUNE.LIP_CREST)
	-- The cloud deck's BILLOW tops, not its plane: this is a ceiling the far
	-- shot has to fly over, and the billows are what it would fly into.
	local cloudTop = topOf("CloudDeco", pathY + TUNE.CLOUD_DZ + 60)
	local cloudPlaneY = pathY + TUNE.CLOUD_DZ + 20

	-- The gate is the arena's one asymmetric landmark and the bearing the
	-- challengers arrive on, so the omen opens looking over it.
	local gateBearing = kit.authored(TUNE.GATE_DEG)
	local gateAt = kit.landmark("Gate")
	if gateAt then
		gateBearing = math.atan2(gateAt.Z - kit.center.Z, gateAt.X - kit.center.X)
	end

	local ringR = (kit.boss.arena and kit.boss.arena.radius or 152) + TUNE.RING_PAD
	local lakeCentre = Vector3.new(kit.center.X, lakeY, kit.center.Z)

	-- How deep the omen stand-in sits: derived from the rig's crown so that at
	-- Rise 1 exactly CROWN_OUT studs of it stand out of the lava, whatever the
	-- rig is remodelled to.
	local sunkDepth = RIG.crown - TUNE.CROWN_OUT

	-- The crown of the SUNKEN stand-in at a given Rise.
	local function sunkCrownY(rise: number): number
		return lakeY + TUNE.CROWN_OUT - RIG.riseDepth * (1 - rise)
	end

	-- The head of the TRUE-CENTRE colossus at a given Rise: the neck joint,
	-- which is where the skull, jaw and crown all hang.
	local function headY(rise: number): number
		return lakeY + RIG.neckY - RIG.riseDepth * (1 - rise)
	end

	-- The ashfall fists, both flanks, at full strike. `bearing` is body-local:
	-- world bearing is this plus the body's FaceAngle, because `bodyCFrame`
	-- yaws by -bearing and `kit.polar` reads atan2(z, x) - the two mirrors
	-- cancel.
	-- How far out the ashfall arms reach, which is the only camera-clearance
	-- number the rig owns. Where those fists actually ARE is asked for at the
	-- beat instead, through `fistAt`, because by then the body has moved.
	local ashfallR = select(2, fistOffset("ashfall", -1, 1))

	local raiseAt = kit.raiseAt
	local blastAt = raiseAt - 5.95 -- the ash cut: the third shrug happens inside it

	-- ============================================================== the step
	--
	-- THE ONE SCHEDULE THE STEP, THE RISE, THE CAMERA AND EVERY IMPACT POINT
	-- ARE ALL DERIVED FROM. This file already learned the lesson once with
	-- `SHRUGS`: a look-at with its own copy of the heights drifts off the body
	-- the moment a beat is retimed, invisibly in code and obviously on screen.
	-- The step has four consumers instead of two, so it gets the same
	-- treatment - nothing below computes where the colossus is except through
	-- `standCenter` / `standRise`.
	--
	-- Every time here is relative to the ash cut. `handoffAt` is the last
	-- instant anything writes state; after it the pose IS the rise's first
	-- frame and nothing touches it again.
	local STEP = {
		turn0 = blastAt + 0.20, -- the head comes round to the party FIRST...
		turn1 = blastAt + 1.50, -- ...so the stride is straight at them
		out0 = blastAt + 0.05,
		out1 = blastAt + 2.45, -- 2.4 s of travel, per the design's "~2.4 s"
		cock0 = blastAt + 0.10, -- handfall winds up...
		cock1 = blastAt + 1.20,
		plant0 = blastAt + 1.20, -- ...and throws, impact at HANDFALL_IMPACT
		plant1 = blastAt + 1.78,
		release0 = blastAt + 1.95, -- the arm lets go and the other cocks
		release1 = blastAt + 2.45,
		seam0 = blastAt + 2.45, -- the seams open over the ashfall
		ash0 = blastAt + 2.55,
		ash1 = blastAt + 3.75,
		throw1 = blastAt + 4.50, -- the bellow
		settle0 = blastAt + 4.65, -- arms down, seams reseal, PoseCenter home
		back1 = blastAt + 5.60,
		handoffAt = blastAt + 5.75, -- == raiseAt - 0.20
	}
	-- The impact frame, derived rather than typed: phase = 0.5 + 0.5 * strike,
	-- so the fist is at the impact keyframe when `Strike` reaches
	-- HANDFALL_IMPACT - and the `Strike` track below is eased "in", which
	-- CutsceneKit's `easeU` makes u^2. So the time is the SQUARE ROOT of the
	-- fraction, not the fraction. Written straight it lands the shockwave 14 ms
	-- and about two studs off the fist, which is exactly the size of error this
	-- file's whole "ask the rig" design exists to keep out.
	local plantAt = STEP.plant0 + (STEP.plant1 - STEP.plant0) * math.sqrt(TUNE.HANDFALL_IMPACT)

	-- Out along the arrival bearing and back. `kit.polar` is the bearing
	-- convention for everything else here, so the direction comes from it
	-- rather than from a second `math.cos` nobody would keep in step.
	local stepDir = (kit.polar(1, TUNE.ARRIVAL, kit.center.Y) - kit.center).Unit

	local function smooth(t: number, t0: number, t1: number): number
		local u = math.clamp((t - t0) / math.max(t1 - t0, 1e-4), 0, 1)
		return u * u * (3 - 2 * u)
	end

	-- How far downrange the standing stand-in is, 0..1 of STEP_OUT. Out over
	-- the stride, held through the ashfall, home before the handoff - and
	-- exactly 0 at `handoffAt`, which is what makes the server's seed from
	-- `creature.anchor` land on the frame the stand-in was holding.
	local function standTravel(t: number): number
		return smooth(t, STEP.out0, STEP.out1) - smooth(t, STEP.settle0, STEP.back1)
	end
	local function standCenter(t: number): Vector3
		return kit.center + stepDir * (TUNE.STEP_OUT * standTravel(t))
	end

	-- The standing stand-in's `Rise`: 1 for the step (see IT WALKS - a
	-- hand-down pose at Rise 0 puts the fist inside the rock), sinking to the
	-- handoff's 0 under the ashfall. The track finishes well before `raiseAt`
	-- so the controller's own RISE_RATE smoothing has time to arrive.
	local function standRise(t: number): number
		return 1 - smooth(t, STEP.ash0, STEP.throw1)
	end

	-- Where a fist is, in the world, at a given moment - the body's own
	-- `fistOffset` lifted onto the moving centre and the current rise. This is
	-- the reason `standCenter` exists: an impact mark left at `kit.center`
	-- while the body was 46 studs downrange is a shockwave beside the fist.
	local function fistAt(poseName: string, side: number, strike: number, t: number): Vector3
		local bearing, radius, height = fistOffset(poseName, side, strike)
		local at = standCenter(t)
		local world = TUNE.ARRIVAL + bearing
		return Vector3.new(
			at.X + math.cos(world) * radius,
			lakeY - RIG.riseDepth * (1 - standRise(t)) + height,
			at.Z + math.sin(world) * radius
		)
	end

	-- ============================================================== the props
	--
	-- Everything below is registered NOW, at t = 0, and animated by tracks -
	-- nothing creates a part per frame, and nothing rolls a die: the whole run
	-- is a pure function of `kit.t`, so every party member and every late
	-- joiner sees the same frame.

	-- ASH. One wide emitter hung over the caldera; the deck of ash the user
	-- asked for, and cheaper than a hundred tweened flakes.
	--
	-- ITS HOST IS A `kit.part` AND THAT IS THE CONSIDERED ANSWER, not an
	-- oversight - see MESHES, NOT SLABS at the top. `PyreliskArena_CloudDeco`
	-- is the one object in this pack that must never be cloned: ~1980 studs
	-- across with 190 billows, sized to sit just inside the 2048-stud MeshPart
	-- cap, and a second copy of it 300 studs over the caldera would be a cloud
	-- sea in the sky. This host is `Transparency = 1` and is NEVER DRAWN. It
	-- is an emitter anchor; there is no primitive on screen here to replace.
	local ashPart = kit.part({
		Size = Vector3.new(TUNE.PATH_R * 2, 4, TUNE.PATH_R * 2),
		CFrame = CFrame.new(kit.center.X, pathY + 300, kit.center.Z),
		Transparency = 1,
	})
	local ash = Instance.new("ParticleEmitter")
	ash.Texture = "rbxasset://textures/particles/smoke_main.dds"
	ash.Color = ColorSequence.new(TUNE.ASH)
	ash.Size = NumberSequence.new(6, 11)
	ash.Transparency = NumberSequence.new(0.55, 0.9)
	ash.Lifetime = NumberRange.new(7, 11)
	ash.Rate = 26
	ash.Speed = NumberRange.new(1, 4)
	ash.SpreadAngle = Vector2.new(24, 24)
	ash.EmissionDirection = Enum.NormalId.Bottom
	ash.Acceleration = Vector3.new(3, -7, 2)
	ash.Rotation = NumberRange.new(0, 360)
	ash.RotSpeed = NumberRange.new(-14, 14)
	ash.LightEmission = 0
	ash.Parent = ashPart

	-- THE CLOUD DECK, LIT FROM BELOW. A PointLight cannot do this - Roblox
	-- caps Range at 60 studs and the deck is 1200 across - so it is a neon
	-- disc lying just above the deck plane whose transparency is the dial.
	--
	-- IT IS LIT DURING THE OMEN, not at the bellow where the user's beat list
	-- puts it, and the reason is sightlines: the deck is 260 studs BELOW the
	-- rim path and outside r 430, so it is only ever in frame from the two
	-- shots that fly outside the mountain (0 - 9.2 s). From inside the caldera
	-- the lip hides it completely. Lit under the omen it is the volcano's own
	-- glare on the cloud sea, which is the same picture earlier.
	local cloudGlow = kit.part({
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(2, TUNE.CLOUD_GLOW_R * 2, TUNE.CLOUD_GLOW_R * 2),
		CFrame = CFrame.new(kit.center.X, cloudPlaneY, kit.center.Z) * CFrame.Angles(0, 0, math.rad(90)),
		Color = TUNE.MAGMA,
		Material = Enum.Material.Neon,
		Transparency = 1,
	})

	-- Its brightness is computed from `t` instead of tweened, for the reason
	-- the monolith block below spells out: a `from` sampled at registration
	-- cannot be chained.
	local GLARE_AT = { 9.4, 12.0, blastAt - 0.15 }
	kit.during(0, blastAt + 2.6, function(_, _, t)
		local lit = 0.14 * math.clamp((t - 1.4) / 7.2, 0, 1)
		for _, at in GLARE_AT do
			local since = t - at
			if since >= 0 and since < 2.4 then
				lit = math.max(lit, 0.14 + 0.10 * (1 - since / 2.4))
			end
		end
		cloudGlow.Transparency = math.clamp(1 - lit, 0, 1)
	end)

	-- MOLTEN ROCK POURING OFF THE SHRUGS. Six plates of the caldera's OWN
	-- COOLED CRUST that slide down into the lava as each shrug tops out. Props
	-- around the rig, because the rig's vocabulary has no "shedding" channel -
	-- but shed ROCK, drawn with rock, which is the point of the whole pass.
	--
	-- `PyreliskArena_CrustDeco` (arena_gen.py `build_py_plates`:4306-4330) is
	-- one merged object: ~18 flat basalt ngons scattered over the path annulus,
	-- so the clone's own bbox is the annulus. `Scale` is what makes it a plate
	-- instead of a floor - six different fractions, so the six read as six
	-- pieces of one broken shell rather than as six copies of a stamp. If the
	-- pack is not imported `kit.mesh` hands back exactly the slab this drew
	-- before, warns once, and the choreography below is unchanged.
	local sheets = {}
	local SHEET_SCALE = { 0.052, 0.061, 0.047, 0.068, 0.055, 0.043 }
	for index = 1, 6 do
		-- Deterministic placement: a fixed fan, no RNG, so every client draws
		-- the same six plates in the same six places.
		local bearing = gateBearing + (index / 6) * math.pi * 2
		sheets[index] = kit.mesh("PyreliskArena", "CrustDeco", {
			Scale = SHEET_SCALE[index],
			CFrame = CFrame.new(kit.polar(22, bearing, sunkCrownY(TUNE.OMEN_RISE) - 6))
				* CFrame.Angles(0, bearing, math.rad(14 + index * 5)),
			Color = TUNE.MAGMA,
			Material = Enum.Material.Neon,
			Transparency = 1,
		})
	end

	-- THE NINE MONOLITHS, dark until the colossus is standing over them.
	--
	-- THEY ARE LIT, NOT DRAWN, and that is a correction. This file used to hang
	-- a 4 x 15 x 4 neon slab on each of the nine - nine Roblox boxes standing
	-- inside nine imported rocks. `PyreliskArena_Teeth` is ONE MERGED OBJECT
	-- (`build_py_teeth` grows all nine cones and their skirts into a single
	-- bmesh, arena_gen.py:4360-4410), so nine `kit.mesh` clones of it would be
	-- nine complete copies of the monolith field rather than nine monoliths.
	-- The rock the player is meant to see is already imported and already
	-- standing on the path; what it lacked was ember light under it. So: the
	-- lights stay, keyed off `BossArenas.volcano.stones` - already mirrored
	-- into Roblox space (its own note) so a light lands on the rock the player
	-- can see - and the slabs are gone.
	local stones = (BossArenas.items[kit.islandId] or {}).stones or {}
	local toothLights = {}
	for index, stone in stones do
		local at = Vector3.new(kit.center.X + stone.X, pathY + 7, kit.center.Z + stone.Z)
		toothLights[index] = kit.light(at, TUNE.EMBER, 55, 0)
	end

	-- ============================================================== the actors

	-- THE OMEN STAND-IN: sunk under the lake, so only its crown is above the
	-- lava. Attributes are exactly the ones the controller reads; Stance /
	-- Stances are published at full so `damageOf` draws it undamaged, which is
	-- what the real fresh boss will draw a moment later.
	local sunken = kit.actor({
		pose = TUNE.POSE,
		name = "CutscenePyreliskDrowned",
		center = kit.center - Vector3.new(0, sunkDepth, 0),
		attrs = {
			Rise = TUNE.OMEN_RISE,
			Slump = 1,
			FaceAngle = gateBearing,
			AimAngle = gateBearing,
			AimSide = 1,
			Attack = "",
			AttackBlend = 0,
			Strike = 0,
			Planted = 0,
			Stance = kit.boss.stances or 3,
			Stances = kit.boss.stances or 3,
			Exposed = false,
			SeamsOpen = 0,
			SeamsBroken = 0,
			SeamMeterL = 0,
			SeamMeterR = 0,
		},
	})

	-- The true-centre stand-in is created at the ash cut, not now: two
	-- pyrelisks on screen at once is the one thing this file must never do.
	local standing = nil

	-- The real rig has landed - destroy whichever stand-in is alive.
	kit.onRealBoss(function()
		sunken:destroy()
		if standing then
			standing:destroy()
		end
	end)

	-- ============================================================== OMEN
	-- 0.0 - 9.2  The caldera is calm, the monoliths are dark, ash is falling
	--            and the mountain is grumbling. Nothing has moved yet.

	kit.fade(0, 1.8)
	kit.rumble(0.4, 9.2, 0.010)
	kit.every(0.8, 19.0, 2.6, function(index)
		-- A bubble somewhere on the lake, walked round a fixed spiral rather
		-- than rolled: deterministic across the party.
		kit.sfx("lavaBubble", kit.polar(TUNE.LAKE_R * 0.55, gateBearing + index * 2.399, lakeY))
	end)
	kit.every(1.6, 13.0, 3.9, function(index)
		kit.sfx("windGust", kit.polar(TUNE.PATH_R, gateBearing + index * 1.7, pathY + 8))
	end)
	-- The mountain clearing its throat. `bossTell` and not a music stinger:
	-- the three stingers were deleted from Sfx's CATALOGUE when
	-- MusicController learned to play them off SoundSprites.music, so a call
	-- for one here would only earn a warning.
	kit.at(2.4, function()
		kit.sfx("bossTell", lakeCentre)
	end)

	-- Shot 1: outside the mountain, over the cloud sea, craning up the flank.
	-- CLEARANCE: r 640-700 is 150+ studs outside the flank's widest modelled
	-- ring (r 486 at the cut, arena_gen.py build_py_flank), and the height is
	-- held CLOUD_CLEAR above the MEASURED billow tops, which is the only thing
	-- out here to hit.
	local farY = math.max(pathY - 62, cloudTop + TUNE.CLOUD_CLEAR)
	kit.shot({
		t0 = 0,
		t1 = 5.0,
		pos = function(u)
			return kit.polar(700 - 60 * u, gateBearing + math.rad(16) * u, farY + 34 * u)
		end,
		look = kit.center + Vector3.new(0, 60, 0),
		fov = 58,
	})

	-- Shot 2: over the lip and into the caldera. CLEARANCE: it starts 220
	-- studs above the flank's surface at r 430 and ends outside the lip
	-- entirely, 122 studs above the path - nothing between the two.
	kit.shot({
		t0 = 5.0,
		t1 = 9.2,
		blendIn = 1.1,
		pos = function(u)
			return kit.polar(
				430 - 150 * u,
				gateBearing + math.rad(16 + 22 * u),
				(farY + 34) + (pathY + 122 - farY - 34) * u
			)
		end,
		look = function(u)
			return lakeCentre + Vector3.new(0, 8 + 12 * u, 0)
		end,
		fov = 62,
	})

	-- ============================================================== REVEAL
	-- 9.2 - 13.55  The "rocks" in the lake shrug twice, and each shrug pours
	--              molten rock off a crown nobody had read as a head yet.

	-- THE SHRUG SCHEDULE, written down ONCE. Both the rig's `Rise` tweens and
	-- the camera's look-at are derived from this table, because they have to
	-- agree: a look-at that read its own hard-coded heights drifted off the
	-- crown the moment either shrug was retimed, and the drift is invisible in
	-- code and obvious on screen.
	local SHRUGS = {
		{ at = 9.4, till = 11.0, from = TUNE.OMEN_RISE, to = TUNE.SHRUG_ONE, force = 0.030 },
		{ at = 12.0, till = 13.4, from = TUNE.SHRUG_ONE, to = 1.0, force = 0.048 },
	}

	-- The sunken stand-in's Rise at a given cutscene time, on the same
	-- "inout" curve CutsceneKit's own easeU uses for these tracks.
	local function sunkRiseAt(t: number): number
		local rise = TUNE.OMEN_RISE
		for _, beat in SHRUGS do
			if t >= beat.till then
				rise = beat.to
			elseif t > beat.at then
				local u = (t - beat.at) / (beat.till - beat.at)
				rise = beat.from + (beat.to - beat.from) * (u * u * (3 - 2 * u))
			end
		end
		return rise
	end

	-- The head grinding round while it heaves: the first thing that says the
	-- rock is looking at something.
	sunken:tween("FaceAngle", gateBearing, gateBearing - math.rad(30), 9.4, 13.4, "inout")
	sunken:tween("AimAngle", gateBearing, gateBearing - math.rad(30), 9.4, 13.4, "inout")

	-- Each shrug: the body heaves, sheets of molten rock slide off the crown
	-- and into the lava, the lake rings out, the camera takes a hit.
	for _, beat in SHRUGS do
		sunken:tween("Rise", beat.from, beat.to, beat.at, beat.till, "inout")
		for index, sheet in sheets do
			local bearing = gateBearing + (index / #sheets) * math.pi * 2
			sheet.CFrame = CFrame.new(kit.polar(22, bearing, sunkCrownY(beat.from) - 4))
				* CFrame.Angles(0, bearing, math.rad(14 + index * 5))
			sheet.Transparency = 1
			kit.meshTween(sheet, { Transparency = 0.25 }, beat.at, beat.at + 0.35, "out")
			-- Slides off the crown, tips over and shrinks as it goes: `Scale`
			-- is read against the stamped `BaseSize`, so this is the import's
			-- own size shrinking rather than a second guess at it.
			kit.meshTween(sheet, {
				Scale = SHEET_SCALE[index] * 0.62,
				CFrame = CFrame.new(kit.polar(30 + index * 2, bearing, lakeY - 8))
					* CFrame.Angles(math.rad(38), bearing, math.rad(52 + index * 7)),
				Transparency = 1,
			}, beat.at + 0.35, beat.at + 1.7, "in")
		end
		local top = sunkCrownY(beat.to)
		local force = beat.force
		kit.at(beat.at, function()
			kit.sfx("pyreCrustCrack", lakeCentre)
			kit.sfx("lavaBurst", lakeCentre)
			kit.shake(force, 1.4, force * 0.5)
			kit.vfx.ring(Vector3.new(kit.center.X, lakeY + 0.6, kit.center.Z), 30, TUNE.LAKE_R, 1.6, TUNE.MAGMA)
			kit.vfx.puff(Vector3.new(kit.center.X, top, kit.center.Z), TUNE.ASH, 9)
		end)
	end
	kit.rumble(9.4, 13.4, 0.014)

	-- Shot 3: down toward the lake to watch the crown come out of it.
	-- CLEARANCE: it crosses inside the lip but is floored above BOTH the
	-- measured monolith tops and the measured lip, and the only body in the
	-- caldera is the sunken stand-in - whose shoulders are still 40 studs
	-- under the lava at the end of the second shrug.
	local shot3Floor = math.max(teethTop, lipTop) + TUNE.TEETH_CLEAR
	kit.shot({
		t0 = 9.2,
		t1 = blastAt,
		blendIn = 0.9,
		pos = function(u)
			return kit.polar(
				265 - 85 * u,
				gateBearing + math.rad(38 + 20 * u),
				math.max(pathY + 112 - 60 * u, shot3Floor)
			)
		end,
		look = function(_u, t)
			-- Rides the crown up out of the lava off the SAME schedule the
			-- shrugs are tweened from, so the head cannot climb out of frame.
			return Vector3.new(kit.center.X, sunkCrownY(sunkRiseAt(t)) - 5, kit.center.Z)
		end,
		fov = 38,
	})

	-- --------------------------------------------------------- the third shrug
	--
	-- It happens inside the ash. The sunken stand-in is destroyed and the true
	-- one is created at Rise 0 behind a full-screen blast, so the gap between
	-- the two crowns is a CUT rather than an impossible tween - and the cut is
	-- the scale reveal the whole cinematic is for.
	kit.at(blastAt - 0.15, function()
		kit.flash(TUNE.EMBER, 0.8, 1.0)
		kit.shake(0.105, 1.8, 0.05)
		kit.sfx("lavaBurst", lakeCentre)
		kit.sfx("pyreCrustCrack", lakeCentre)
		kit.vfx.shockwave(Vector3.new(kit.center.X, lakeY + 1, kit.center.Z), 40, 460, 1.5, TUNE.MAGMA, 2)
		for index = 1, 5 do
			kit.vfx.puff(
				kit.polar(TUNE.LAKE_R * 0.8, gateBearing + (index / 5) * math.pi * 2, lakeY + 20),
				TUNE.ASH,
				13
			)
		end
	end)

	kit.at(blastAt, function()
		sunken:destroy()
		standing = kit.actor({
			pose = TUNE.POSE,
			name = "CutscenePyreliskStanding",
			center = standCenter(blastAt),
			attrs = {
				-- IT ARRIVES AT RISE 1 AND SINKS TO THE HANDOFF POSE, which is
				-- the one change the step forced. Rise 0 / Slump 1 is the real
				-- rise's first frame exactly (CreatureService.luau:18279-18280,
				-- the entrenched-and-posed `rising` branch) and it is what the
				-- body holds from `STEP.throw1` to `raiseAt`; but a hand-down
				-- pose at Rise 0 drives its fist forty studs into the rock, so
				-- the step itself is played at Rise 1. See IT WALKS.
				Rise = 1,
				Slump = 1,
				FaceAngle = gateBearing - math.rad(30),
				AimAngle = TUNE.ARRIVAL,
				-- The flank that plants. `handfall` is a one-arm shape, so
				-- `AimSide` is which arm - and it flips at the end of the
				-- stride, because the other one is what the next stride would
				-- cock.
				AimSide = -1,
				Attack = "handfall",
				AttackBlend = 0,
				Strike = 0,
				Planted = 0,
				Stance = kit.boss.stances or 3,
				Stances = kit.boss.stances or 3,
				Exposed = false,
				SeamsOpen = 0,
				SeamsBroken = 0,
				SeamMeterL = 0,
				SeamMeterR = 0,
			},
		})
	end)

	-- ============================================================== THE STEP
	-- blastAt + 0.0 - 2.45  It turns to face the party and takes ONE STRIDE,
	--                       planting a fist on the rock as it comes.
	--
	-- EVERY WRITE BELOW IS A `kit.track`, INCLUDING THE PER-FRAME ONES, and it
	-- is registered HERE - in the registration pass - rather than inside the
	-- `kit.at(blastAt)` callback above. Two reasons, both about the skip:
	--
	--   1. A track registered mid-step is inserted into the list `kit.step` is
	--      already walking and is only picked up the NEXT frame. Registered up
	--      here it is in the list before the run starts.
	--   2. A skip advances the clock and the next `kit.step` settles every
	--      track it jumped over at u = 1, while a `during` is simply never
	--      visited again. So `PoseCenter` and `Rise` MUST be tracks: a skip to
	--      `raiseAt` settles them on `standCenter(handoffAt)` = `kit.center`
	--      and `standRise(handoffAt)` = 0, which is the handoff pose exactly.
	--      A `during` would leave a 46-stud-downrange colossus at Rise 1.
	--      (`kit.at(blastAt)` is fired by the skip too - muting only silences
	--      sound, shake, flash and vfx, never `kit.actor` - so the stand-in
	--      exists for those settles to land on.)
	--
	-- `standing` is nil until the cut. It cannot be nil when these apply -
	-- `kit.step` runs `fireEventsTo(t)` BEFORE the track loop, so the actor is
	-- built on the same frame the first of these opens - but the guard is here
	-- anyway, because "the thing that builds it runs first" is exactly the kind
	-- of ordering claim that survives until someone reorders the file.
	local function driveFrame(t0: number, t1: number, apply: (number) -> ())
		-- No ease: `u` has to be recoverable as a time, because the schedule
		-- functions own the shaping and a second ease on top of them would
		-- silently retime the step away from the camera that follows it.
		kit.track(t0, t1, nil, function(u)
			if standing then
				apply(t0 + u * (t1 - t0))
			end
		end)
	end

	-- THE STRIDE. `PoseCenter` per frame from the one schedule, held open all
	-- the way to `handoffAt` so its settle value IS the handoff value.
	driveFrame(blastAt, STEP.handoffAt, function(t)
		standing:set("PoseCenter", standCenter(t))
		standing:set("Rise", standRise(t))
	end)

	-- The head grinds round from the gate to the party BEFORE the stride, so
	-- the colossus steps at them rather than across them. AimAngle is already
	-- the arrival bearing, so `bearing()` folds the two together.
	kit.track(STEP.turn0, STEP.turn1, "inout", function(u)
		if standing then
			standing:set("FaceAngle", gateBearing - math.rad(30) * (1 - u))
		end
	end)

	-- HANDFALL: cock, throw, plant, release. `phase` is
	-- AttackBlend * (0.5 + 0.5 * Strike) (PyreliskPath.phase), so the blend is
	-- the load and the strike is the throw; the impact keyframe is at strike
	-- HANDFALL_IMPACT, which is where `plantAt` falls.
	kit.track(STEP.cock0, STEP.cock1, "inout", function(u)
		if standing then
			standing:set("AttackBlend", u)
		end
	end)
	kit.track(STEP.plant0, STEP.plant1, "in", function(u)
		if standing then
			standing:set("Strike", u)
		end
	end)
	kit.track(STEP.release0, STEP.release1, "out", function(u)
		if standing then
			standing:set("AttackBlend", 1 - u)
			standing:set("Strike", 1 - u)
		end
	end)

	-- THE FIST LANDS. Everything here is placed through `fistAt`, which reads
	-- the body's own `fistOffset` at the moving centre - so the mark, the dust
	-- and the fist the player is watching are one point by construction, the
	-- same guarantee the fight's telegraphs have.
	kit.at(plantAt, function()
		local at = fistAt("handfall", -1, TUNE.HANDFALL_IMPACT, plantAt)
		kit.sfx("pyreHandfall", at)
		kit.sfx("pyreCrustCrack", at)
		kit.shake(0.085, 1.5, 0.04)
		kit.vfx.shockwave(at, 14, 190, 1.2, TUNE.ASH, 1.8)
		kit.vfx.puff(at, TUNE.ASH, 14)
		kit.vfx.burst(at, TUNE.EMBER, 16)
	end)

	-- ...and the OTHER arm takes over. One flip, on the frame the planted arm
	-- lets go: that is the whole difference between a step and a shrug.
	kit.at(STEP.release1, function()
		if standing then
			standing:set("AimSide", 1)
		end
	end)

	-- The foot arriving, under the fist. Deliberately AFTER the plant: the
	-- hand takes the weight first and the body follows it, which is how
	-- something this heavy moves.
	kit.at(STEP.out1, function()
		local at = standCenter(STEP.out1)
		kit.sfx("pyreStep", at)
		kit.shake(0.062, 1.3, 0.03)
		kit.vfx.ring(Vector3.new(at.X, lakeY + 0.6, at.Z), 40, 150, 1.3, TUNE.MAGMA)
	end)

	-- ============================================================== THE ASHFALL
	-- blastAt + 2.45 - 4.65  The seams open, both arms go up, the summit sheds.

	-- BOTH ARMS UP AND WIDE. `ashfall` IS in PyreliskPath's BOTH_ARMS (:1001),
	-- so this poses the whole body rather than one flank, and `AimSide` stops
	-- mattering the instant it takes over from `handfall`. It is also the only
	-- attack legal at the handoff - see IT WALKS.
	kit.at(STEP.seam0, function()
		if standing then
			standing:set("Attack", "ashfall")
			standing:set("SeamsOpen", 1)
		end
		kit.sfx("pyreVentbreath", lakeCentre)
	end)
	kit.at(blastAt + 3.00, function()
		if standing then
			standing:set("SeamsOpen", 7)
		end
	end)
	kit.at(blastAt + 3.60, function()
		if standing then
			standing:set("SeamsOpen", RIG.seamAll)
		end
	end)
	kit.track(STEP.ash0, STEP.ash1, "inout", function(u)
		if standing then
			standing:set("AttackBlend", u)
		end
	end)
	kit.track(STEP.ash1, STEP.throw1, "in", function(u)
		if standing then
			standing:set("Strike", u)
		end
	end)

	-- ...and it lowers them again, so the pose at `raiseAt` is the rest pose
	-- the real rise starts from - knuckles back in the lava, which is where
	-- REST puts them (PyreliskPath.luau:353-358). The shell seals with it, and
	-- `standCenter` walks the body home over the same window.
	kit.track(STEP.settle0, STEP.handoffAt, "out", function(u)
		if standing then
			standing:set("AttackBlend", 1 - u)
		end
	end)
	kit.at(blastAt + 4.90, function()
		if standing then
			standing:set("SeamsOpen", 7)
		end
	end)
	kit.at(blastAt + 5.30, function()
		if standing then
			standing:set("SeamsOpen", 1)
		end
	end)

	-- THE HANDOFF, and it is a single place on purpose: after this instant
	-- nothing in this file writes a channel. Rise 0 / Slump 1, seams shut,
	-- attack cleared, `PoseCenter` back at `kit.center` - which is the real
	-- rise's u = 0 frame, `CreatureService.luau:18279-18280`.
	kit.at(STEP.handoffAt, function()
		if not standing then
			return
		end
		standing:set("PoseCenter", kit.center)
		standing:set("Rise", 0)
		standing:set("Slump", 1)
		standing:set("SeamsOpen", 0)
		standing:set("Strike", 0)
		standing:set("Attack", "")
		standing:set("AttackBlend", 0)
		standing:set("AimSide", -1)
	end)

	-- THE NINE MONOLITHS light one by one under the standing colossus - the
	-- IMPORTED rock lighting up, with nothing drawn over it (see MESHES, NOT
	-- SLABS). A `kit.track` rather than a `during`, so a skip settles the
	-- lights on instead of leaving nine dark stones under a lit boss.
	kit.at(blastAt + 0.35, function()
		kit.sfx("lampOn", lakeCentre)
	end)
	kit.track(blastAt + 0.3, blastAt + 5.0, nil, function(u)
		local t = blastAt + 0.3 + u * 4.7
		for index = 1, #toothLights do
			local since = t - (blastAt + 0.35 + index * 0.2)
			if since >= 0 then
				toothLights[index].Brightness = 2.4 + 1.8 * math.max(0, 1 - since / 0.9)
			end
		end
	end)

	-- THE BELLOW, on the frame the arms reach the top of the throw. The ash
	-- comes off the SUMMIT - both fists, asked for by name - rather than out
	-- of the sky, which is what the attack this pose belongs to actually does.
	kit.at(STEP.throw1, function()
		kit.sfx("pyreRoar", lakeCentre)
		kit.sfx("pyreAshfall", lakeCentre)
		kit.shake(0.075, 1.6, 0.035)
		-- Through `fistAt` rather than a fixed point: by the bellow the body
		-- is 46 studs downrange and halfway home, and a puff at the old
		-- `kit.center` figure would be a plume beside the hand.
		for _, side in { -1, 1 } do
			local at = fistAt("ashfall", side, 1, STEP.throw1)
			kit.vfx.puff(at, TUNE.ASH, 11)
			kit.vfx.burst(at, TUNE.EMBER, 20)
		end
		local under = standCenter(STEP.throw1)
		kit.vfx.shockwave(Vector3.new(under.X, pathY + 2, under.Z), TUNE.LAKE_R, 300, 1.4, TUNE.MAGMA, 1.6)
	end)
	kit.rumble(STEP.throw1, raiseAt, 0.012)

	-- Shot 4: THE STEP, from the ground. A HARD CUT on the blast (no blendIn)
	-- from a 41-stud crown in a lake to a boot-level look up a 207-stud body
	-- walking at the camera. The low eye and the 80-degree lens are the whole
	-- scale read - the wide that follows could never say it.
	--
	-- CLEARANCE, and it is the tightest in the file. The camera sits INSIDE
	-- the lip (r 232-240 against LIP_R 246): outside it the overhanging crest
	-- is between the eye and the boss at this height. It is offset 22 degrees
	-- off the arrival bearing because `BossArenas.volcano.stones[5]` stands at
	-- r 187 on bearing 6.6 deg, dead on the arrival line - 22 degrees puts
	-- ~90 studs of lateral daylight between the eye and that monolith, and
	-- `build_py_teeth` skips the gate and notch bearings so nothing else is
	-- near it. The body walks TOWARD the arrival bearing, so it crosses frame
	-- rather than walking into the lens; at `STEP.out1` its far arm reaches
	-- r 234 on the arrival line, which is 47 studs off this eye.
	local walkBearing = TUNE.ARRIVAL + math.rad(-22)
	kit.shot({
		t0 = blastAt,
		t1 = STEP.seam0,
		pos = function(u)
			return kit.polar(240 - 8 * u, walkBearing, pathY + 5 + 7 * u)
		end,
		look = function(_u, t)
			-- The knee, then the chest: the tilt is the body's own height off
			-- the one schedule the step is driven from, so a retimed stride
			-- cannot leave the camera looking at the rock it left.
			local at = standCenter(t)
			local climb = math.clamp((t - blastAt) / (STEP.seam0 - blastAt), 0, 1)
			local base = lakeY - RIG.riseDepth * (1 - standRise(t))
			return Vector3.new(at.X, base + 34 + (RIG.neckY - 34) * climb * climb, at.Z)
		end,
		fov = 80,
	})

	-- Shot 5: the reveal wide, orbiting 280 -> 340 degrees while the seams
	-- open and the arms go up, and ending near the arrival bearing so the last
	-- shot has nothing to hide.
	-- CLEARANCE: r 320 is outside the lip (246) at 180 studs above the path -
	-- clear of the monoliths (21), the lip (11) and, held ARM_CLEAR outside
	-- the radius the ashfall fists actually reach, of the arms themselves.
	local wideR = math.max(330, ashfallR + TUNE.ARM_CLEAR + 65)
	local closeR = math.max(265, ashfallR + TUNE.ARM_CLEAR)
	local orbitR = math.max(320, ashfallR + TUNE.ARM_CLEAR + 55)
	kit.shot({
		t0 = STEP.seam0,
		t1 = STEP.settle0,
		blendIn = 0.7,
		pos = kit.orbit(Vector3.new(kit.center.X, pathY, kit.center.Z), orbitR, 180, math.rad(280), math.rad(340)),
		look = function(_u, t)
			local at = standCenter(t)
			return Vector3.new(at.X, headY(standRise(t)) - 24, at.Z)
		end,
		fov = 62,
	})

	-- Shot 6: it settles. The arms come down, the shell reseals, the body
	-- walks home and sinks the last of its Rise, and the camera drifts in to
	-- exactly where the rise shot opens - so the handoff has no camera move of
	-- its own to give it away.
	kit.shot({
		t0 = STEP.settle0,
		t1 = raiseAt,
		blendIn = 0.8,
		pos = function(u)
			return kit.polar(wideR - (wideR - closeR) * u, TUNE.ARRIVAL + math.rad(-26 + 26 * u), pathY + 34 + 46 * u)
		end,
		look = function(u, t)
			-- Tilts up the body as the shot runs: the chest, then the head.
			-- Its top is the rig's own neck joint rather than a number, and it
			-- tracks the body home rather than staring at the centre.
			local at = standCenter(t)
			local base = pathY + 20
			return Vector3.new(at.X, base + (headY(standRise(t)) - base) * u * u, at.Z)
		end,
		fov = 66,
	})

	-- ============================================================== ROAR
	-- raiseAt - duration  Camera and fx only: the real colossus is standing up
	--                     under this shot and the stand-in is already gone.

	kit.at(raiseAt, function()
		kit.sfx("bossRise", lakeCentre)
	end)
	-- Registered here rather than inside the event above: `rumble` is a
	-- repeater, and repeaters belong in the registration pass so a skip's
	-- fast-forward winds them past instead of finding them newly born.
	kit.rumble(raiseAt, kit.duration, 0.016)

	-- BELT AND BRACES. `kit.onRealBoss` is the contract and it fires the
	-- instant the server's model gets its BossName - but a stand-in that
	-- outlived a raise that never arrived would be drawn straight through the
	-- real one, so it also goes here unconditionally. Two pyrelisks is the
	-- worse failure than none.
	kit.at(raiseAt + 1.6, function()
		sunken:destroy()
		if standing then
			standing:destroy()
		end
	end)

	-- Shot 7: down onto the rim path and out to where the party is standing,
	-- looking up at the head as it comes out of its slump. It picks up exactly
	-- where shot 6 left off, so the blend has nothing to hide.
	-- CLEARANCE: the descent is cubed, so the camera is still 73 studs above
	-- the path when it crosses the outermost monolith (r 218) and 51 when it
	-- crosses the nearest one to the arrival bearing (BossArenas.stones[5],
	-- r 188 at 6.6 deg). It finishes 35 studs from that stone, on the ground
	-- the party is standing on, which is the frame the controller blends to
	-- the player's own camera from.
	kit.shot({
		t0 = raiseAt,
		t1 = kit.duration,
		blendIn = 1.0,
		pos = function(u)
			return kit.polar(closeR - (closeR - ringR) * u, TUNE.ARRIVAL, pathY + 80 - (80 - TUNE.EYE) * u * u * u)
		end,
		look = function(u)
			-- The head, on the rise's own curve: Rise runs 0 -> 1 as
			-- 1 - (1 - u)^3 over exactly this shot.
			return Vector3.new(kit.center.X, headY(1 - (1 - u) ^ 3), kit.center.Z)
		end,
		fov = 74,
	})

	-- THE CARD, on the beat CreatureEventController's bossRise handler already
	-- fires its own roar and shake on.
	kit.at(raiseAt + 0.85 * kit.riseTime, function()
		-- A short hold on purpose. The card lands 5.5 s into a 6.5 s rise, so
		-- there is only a second of cinematic left to show it in - the
		-- controller tears its gui down at `duration` - and a long hold would
		-- simply be cut mid-word rather than read for longer.
		kit.card(string.upper(kit.boss.shortName), "the Ashfall Colossus", 1.8)
		kit.shake(0.115, 2.0, 0.055)
		kit.sfx("pyreRoar", lakeCentre)
		kit.sfx("bossRoar", lakeCentre)
		kit.flash(TUNE.EMBER, 0.45, 0.8)
		for index = 1, #toothLights do
			toothLights[index].Brightness = 4.2
		end
		kit.vfx.shockwave(Vector3.new(kit.center.X, pathY + 2, kit.center.Z), TUNE.LAKE_R, 520, 1.8, TUNE.MAGMA, 2.5)
	end)
end
