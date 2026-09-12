--!nonstrict
-- GnashrootIntro.luau
-- Old Gnashroot, the Drowned Mire: the Rootmere's intro cinematic.
--
-- REWRITTEN 2026-09-12 against docs/boss-cutscenes-redesign.md section 3.4 and
-- its Errata, and against the REDESIGNED rig (GnashrootPath /
-- GnashrootBodyController, same day). The complaint that drives it is the
-- user's: an intro must animate the Blender model, not a heap of Roblox
-- primitives. The old pass drew 65 `kit.part` slabs - 46 sliding mud clumps,
-- 12 mound slabs, 6 neon eye balls and a root knot, plus 7 PointLight hosts,
-- 72 instances in all. The rig itself got Rise (0 -> 0.62 -> 0) and one
-- `heave` held for 1.5 s; `FaceAngle` never moved, `Eyes` did not exist yet,
-- and the pivot sat on the arena centre for the whole 22 seconds. So the
-- animal was a mound that swelled once while the player watched slabs.
--
-- IT CRAWLS NOW, and that beat is available for one reason: GnashrootBody-
-- Controller takes `state.center = model:GetPivot().Position` EVERY FRAME
-- (drawBody, and its comment names this cutscene), so a stand-in is walkable
-- by its pivot even though the fight itself is rooted (`speed = 0`,
-- "he must be COMPLETELY STATIONARY"). So the mire colossus is born buried
-- and off-centre on the bank, hauls itself to the middle of its own mere on
-- two fists, opens ten eyes, stands up, tries its jaw, lights its chest,
-- and goes back under - all of it on rig channels.
--
-- WHAT IS DRIVEN, and it is the whole published contract bar none:
--   Rise, FaceAngle, Attack, AttackBlend, Strike, AimAngle, AimSide, Exposed,
--   the client-only `Eyes`, and the model's PIVOT.
--
-- ---------------------------------------------------------------- THE HANDOFF
--
-- The stand-in ENDS SUBMERGED (Rise 0, at kit.center) because that is exactly
-- the real rise's first frame, and this is now measured rather than argued:
--
--   CreatureService's rising mode takes the `elseif def.rig == K.GN_RIG`
--   branch (near Fn.updateBoss) - NOT the generic `else` this file's header
--   used to quote, which is where the stale "-riseDepth, pitch -20 degrees"
--   claim came from. That branch does `model:PivotTo(poseCFrame(creature,
--   sub, 0, 0))` with `sub = -def.submerge` (2.4) and ZERO pitch: the pivot
--   only holds its ground, because the climb happens on the client's side of
--   the wire. `Fn.gnashrootPublish` publishes `Rise = 1 - (1 - u)^3` from
--   u = 0, i.e. Rise = 0 on the handoff frame, with FaceAngle = yaw0,
--   AttackBlend/Strike 0, Attack "", AimSide +1 and Exposed false. The boss
--   is stationary at the arena centre.
--
-- So the final pose of this stand-in, stated in plain sight rather than left
-- implied by where the tweens stopped:
--
--   pivot = kit.center   Rise = 0        FaceAngle = party (0)
--   Attack = ""          AttackBlend = 0 Strike = 0
--   AimAngle = party     AimSide = +1    Exposed = false   Eyes = 1
--
-- Both bodies are UNDER THE MUD on that frame - the rig at Rise 0 puts its
-- crown at RISE_DEPTH * (0 - 1) * SCALE + CROWN * SCALE = -49.95 + 48.45 = 1.5
-- studs below the mere - so the cut is the one frame in the cinematic where
-- the two cannot disagree.
--
-- THE 0.4 s OF MARGIN IS NOT DECORATION. The controller EASES rise toward the
-- attribute (`EASE.rise = 2.4`/s) rather than copying it, so it lags this
-- script. The sink runs 16.6 -> 17.8 on an `inout` ease - which lands with
-- ZERO terminal velocity, so the tracking error is already collapsing when
-- the ramp ends - and then has 0.4 s at a held 0 to shed what is left
-- (a further e^(-2.4 * 0.4) = 0.38x). A ramp that ended AT raiseAt would hand
-- over a crown several studs proud of the mere with the real boss already
-- climbing underneath it.
--
-- ------------------------------------------------- WHY EVERY WRITE IS A TRACK
--
-- `kit.fastForward` fires one-shots (muted) and then lets tracks SETTLE at
-- u = 1 on the next step - and it does those in that order, events first,
-- tracks second (CutsceneKit.step: `fireEventsTo` then the track loop). Two
-- consequences this file is built on, the second of which is a bug the old
-- pass had:
--
--   * a `kit.during` is never visited after a skip, so no state may live in
--     one. Nothing here does.
--   * a channel that is TWEENED must have its LAST-REGISTERED tween end on
--     the handoff value. The old pass tweened `AttackBlend 0 -> 0.6` and then
--     cleared it with a `kit.at`; across a skip the `at` fired first and the
--     track then settled at 0.6, leaving a stand-in mid-heave for its last
--     frame. Here every blend/strike RELEASE is itself a tween to 0, and the
--     only `kit.at` writes are the ones the contract says must be COPIED and
--     never eased: `Attack`, `AimAngle`, `AimSide`, `Exposed`.
--
-- Tracks are applied in registration order, so the Rise / pivot / Eyes tracks
-- below are registered strictly in time order and the last of each is the
-- handoff value.
--
-- ---------------------------------------------------------------- THE ARMS
--
-- `heave` is the crawl. GnashrootPath's POSE table says so in as many words
-- ("...and it is also THE CRAWL"): `heavePlant` drives the LATCHED arm's fist
-- forward and low, `heaveBrace` puts the other one down to carry the weight,
-- and the pair was re-rendered at this cinematic's own rise
-- (assets/boss_gnashroot_pose_emerge.png, Rise 0.62). Flipping `AimSide`
-- between pulls swaps which arm plants, so the two front arms haul one pull
-- each.
--
-- TWO PULLS ARE TWO ATTACKS, and that is forced by the controller rather than
-- chosen: while `Attack ~= ""` it HOLDS strike at its peak
-- (`state.strike = math.max(state.strike, approach(...))`, to stop hammerfall
-- running backwards on release), so a second pull inside one attack would
-- have no windup to play. Each pull therefore latches aim, names the attack,
-- blends in, strikes, and is released to "" before the next one latches - the
-- fight's own sequence, at the fight's own rate.
--
-- The rig is buried to its crown at Rise 0 and the bands matter - and they
-- MOVED under this file on 2026-09-12, when the second pass stood the animal
-- up and put its skull on top. RISE_DEPTH is taken off CROWN (33.3 authored,
-- 49.95 world), and the head is now the crown: the top of the skull breaks
-- the surface at Rise 0.03, the two big eyes at 0.15, the shoulders at 0.36
-- and the ember core at 0.51. On the morning rig the face was slung low at
-- authored z 14.6 and did not clear until 0.48, which is why the Errata had
-- to say the design doc's "Rise 0.3" does not read - on THIS rig it very
-- nearly does. The bands below are kept as they are anyway: 0 -> 0.34 is now
-- a head and shoulders coming out rather than a moving mound, 0.58 is the
-- chest and the ember, the lip takes it to 0.80, and only then does it stand
-- to 1. That is a better version of the same beat, not a different one.
--
-- ---------------------------------------------------------------- THE EYES
--
-- One channel, not six props. `Eyes` is client-only, 0..1, nil = 1, and it is
-- the FRACTION of the ten `Gnashroot_Eye` instances that are lit, applied
-- in EYE_SEATS order - which is authored FACE FIRST (GnashrootPath: "the thing
-- looks at you before you can see the rest of it"). The one eye crossing the
-- boundary gets the remainder, so a single tween 0 -> 1 IS "they open one at a
-- time" and is choreographed to the animal's own geometry. The old six neon
-- balls floating near the mass are gone, and so are their six lights.
--
-- ---------------------------------------------------------------- THE MERE
--
-- Twelve imported meshes, not 46 slabs: `GnashrootArena_DecoMoss`, the four
-- `GnashrootArena_Stump*` platforms and `GnashrootPack_Stones` / `_Drips`,
-- sliding inward along their own bearings and sinking through the surface.
-- `kit.mesh` clones the import, repaints it from MeshColors, drops any
-- SurfaceAppearance, and falls back to exactly the slab this used to draw on a
-- machine that never got the pack (one warning, not one per prop). Each is ONE
-- `kit.track` over its whole life - slide, curl, sink, fade in a single
-- apply(u) - so a skip settles it at u = 1 and leaves the bank clean.
--
-- Randomness is a FIXED seed. Every party member must see the same mere, and a
-- constant satisfies that strictly harder than a shared clock would.
--
-- ---------------------------------------------------------------- CAMERA
--
-- Seven shots, every one moving, none longer than 4.8 s, all bearings relative
-- to PARTY - the drop-in ring's first mark, which BossArenaService
-- .ringPositions puts at bearing 0 for the solo summoner, radius
-- `arena.radius + 8` = 44. The last shot ends there, so the controller's 0.8 s
-- blend back to the player's own camera is a few studs rather than a flight.
--
-- Clearances, against the authored Rootmere (assets/arena_gen.py,
-- build_gnashroot), unchanged in discipline from the pass before:
--   * the mere is open water to r 27; the bank is bare peat r 29-70; the only
--     things standing are the reed brakes at r 23-27.5 (tips ~4.3 over the
--     water) and the four Stump platforms at r 44 on bearings 45/135/225/315
--     authored, 5 studs proud (tops ~6.8 over the peat). The drowned cypress
--     grove is r 67-80.
--   * shot 1 skims from 6.2 down to 3.4 over the water and is inside r 14 by
--     then, passing the reed band at ~5.2 - a stud over the tallest tip.
--   * shot 2 orbits at r 86, OUTSIDE the grove, 34 studs over the peat.
--   * shot 3 runs the crawl in from r 74 to r 30 on bearings 158-179 degrees;
--     it crosses r 44 at ~164 degrees, 29 degrees off the 135 stump - 33 studs
--     of lateral clearance - and is at 7.3 over the peat there anyway.
--   * shot 4 sits at r 26-20 inside the reed band's radius but 9-13 studs up.
--   * shot 5 orbits 240 -> 330 degrees at r 74, 40 studs up: over the grove.
--   * shot 6 comes in over open water from r 34 to r 21, 16-20 studs up.
--   * shot 7 sits on bearing 0, 22.5 degrees off the nearest stump: 34 studs
--     of separation at r 44, and 5.6-6.8 studs up.
--   * nothing goes below the water plane.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BossArenas = require(Shared.Config.BossArenas)
local GnashrootPath = require(Shared.Modules.GnashrootPath)

-- Every number the cinematic is tuned with, in one table, so a retune is one
-- edit and never a hunt through the body of the script.
local N = {
	-- The pose key GnashrootBodyController adopts on (its POSE_KEY). NOT
	-- `kit.boss.pose`: the Bosses row carries `rig = "gnashroot"` and no pose
	-- field at all, which is the subject of the handoff note above.
	pose = "gnashroot",
	seed = 6203, -- build_gnashroot's own rng seed, so the props share its grain

	mereR = 27.0, -- GN_MERE_R: black water out to here
	bankInner = 29.0, -- GN_PROFILE: the peat comes up just proud of the water
	bankOuter = 66.0, -- the peat ends at 70; keep the props off the lip
	bankMid = 46.0, -- where the floor probe is taken for camera heights
	-- (the four GN_STUMPS sit at r 44 on bearings 45/135/225/315 authored and
	-- are a CAMERA constraint, not a number this file computes with; every
	-- clearance against them is worked out in the header.)

	gather = 12, -- imported bank meshes. Was 46 kit.part clumps.

	-- WHERE IT IS BORN. Section 3.4's own polar: r 46 (out on the bank, past
	-- the mere's lip), bearing 210 degrees - 15 degrees off the 225 stump and
	-- behind the party's shoulder, so the first thing that moves is not in the
	-- middle of frame. At Rise 0 it is 42 studs down and nothing is on screen.
	bornR = 46.0,
	bornBearing = math.rad(210),

	-- The rise bands, off the rig's own geometry (see THE ARMS above).
	crawlLow = 0.34, -- shoulders out (they clear at 0.27)
	crawlHigh = 0.58, -- a face (it clears at 0.48)
	lipRise = 0.80, -- it stops being a mound
	haulBlend = 0.9, -- how far into `heave` each pull goes
	gnashBlend = 1.0,
}

-- The Rootmere's own palette. `floor`/`rim` are the arena row's (BossArenas
-- .items.swamp.palette); the rest are arena_gen.py's constants for the same
-- build, quoted here because the row does not carry them.
local C = {
	mud = Color3.fromRGB(74, 63, 47), -- WETMUD
	peat = Color3.fromRGB(54, 48, 34), -- palette.floor, packed peat
	rim = Color3.fromRGB(40, 52, 34), -- palette.rim, the mangrove wall
	murk = Color3.fromRGB(27, 42, 36), -- MURK, the standing water
	stone = Color3.fromRGB(90, 93, 85), -- BOGSTONE
	wisp = Color3.fromRGB(139, 242, 186), -- WISP, Morra's lantern green: the eyes
	core = Color3.fromRGB(150, 235, 200), -- the row's markColor: the gnashroot burning
}

-- The bank material the gather is made of, in draw order. Arena objects first
-- (they ARE the bank), then the two the boss pack brought for its own apron.
-- `kit.mesh` resolves `<prefix><name>`, so "GnashrootArena"/"Stump1" is
-- `GnashrootArena_Stump1` and "GnashrootPack"/"Stones" is `Gnashroot_Stones`.
local GATHER = {
	{ pack = "GnashrootArena", name = "DecoMoss", color = C.rim, material = Enum.Material.Grass },
	{ pack = "GnashrootPack", name = "Stones", color = C.stone, material = Enum.Material.Slate },
	{ pack = "GnashrootArena", name = "Stump1", color = C.mud, material = Enum.Material.Wood },
	{ pack = "GnashrootPack", name = "Drips", color = C.mud, material = Enum.Material.Mud },
	{ pack = "GnashrootArena", name = "Stump2", color = C.peat, material = Enum.Material.Wood },
	{ pack = "GnashrootArena", name = "DecoMoss", color = C.peat, material = Enum.Material.Grass },
	{ pack = "GnashrootPack", name = "Stones", color = C.stone, material = Enum.Material.Slate },
	{ pack = "GnashrootArena", name = "Stump3", color = C.mud, material = Enum.Material.Wood },
	{ pack = "GnashrootArena", name = "DecoMoss", color = C.rim, material = Enum.Material.Grass },
	{ pack = "GnashrootPack", name = "Drips", color = C.mud, material = Enum.Material.Mud },
	{ pack = "GnashrootArena", name = "Stump4", color = C.peat, material = Enum.Material.Wood },
	{ pack = "GnashrootPack", name = "Stones", color = C.stone, material = Enum.Material.Slate },
}

-- Smoothstep, named because the crawl uses it three times and a bare
-- `t * t * (3 - 2 * t)` in a surge term reads as a typo.
local function smooth(x: number, a: number, b: number): number
	local t = math.clamp((x - a) / math.max(b - a, 1e-4), 0, 1)
	return t * t * (3 - 2 * t)
end

return function(kit)
	-- ------------------------------------------------------------- geometry
	local center = kit.center
	local waterY = kit.waterY -- GN_MERE_Z is 0: the mere IS the sea welling up
	local bankY = kit.floorY(N.bankMid, 0)
	local palette = (BossArenas.items[kit.islandId] or {}).palette
	local peat = (palette and palette.floor) or C.peat
	local rim = (palette and palette.rim) or C.rim

	-- Where the party is standing when this ends (BossArenaService
	-- .ringPositions: `arena.radius + 8`, first mark on bearing 0).
	local party = 0
	local ringR = ((kit.boss.arena and kit.boss.arena.radius) or 36) + 8

	-- Which way it faces while it hauls: straight at the middle of its own
	-- mere, i.e. the reciprocal of the bearing it was born on. 210 + 180 = 30
	-- degrees, so the turn to the party at the end is a real 30-degree swing
	-- of a 60-stud body and not a nudge.
	--
	-- WRAPPED TO (-pi, pi], and that is not tidiness. `FaceAngle` is TWEENED to
	-- `party` (0) at the stand, and a tween is a plain lerp of the number: an
	-- unwrapped 390 degrees would walk the target the LONG way round, and the
	-- controller - which chases it the short way every frame
	-- (`approachAngle`) - would faithfully follow the animal through a full
	-- extra revolution. 30 degrees is the same bearing and the right sweep.
	local heading = (N.bornBearing + math.pi) % (math.pi * 2)
	if heading > math.pi then
		heading -= math.pi * 2
	end

	-- The body origin, and so the chest, at a given Rise - the same two lines
	-- GnashrootPath.lift and bodyCFrame use, read off the module rather than
	-- copied, so a re-measured crown moves the core glow with it.
	local function originY(rise: number): number
		return center.Y + GnashrootPath.RISE_DEPTH * (rise - 1) * GnashrootPath.SCALE
	end
	local function corePoint(rise: number): Vector3
		local core = GnashrootPath.CORE * GnashrootPath.SCALE
		-- Facing `party` (FaceAngle by then), so the chest offset rotates onto
		-- that bearing exactly as bodyCFrame's CFrame.Angles(0, -bearing, 0)
		-- would put it.
		return Vector3.new(
			center.X + math.cos(party) * core.X,
			originY(rise) + core.Y,
			center.Z + math.sin(party) * core.X
		)
	end

	local rng = Random.new(N.seed)

	-- ------------------------------------------------------------- the clock
	local T = {
		bubbles0 = 0.35,
		bubbles1 = 4.6,
		creak = 2.2,
		gather0 = 4.6,
		gatherLast = 5.9, -- the last prop SETS OFF here; the slowest runs 2.4 s
		wide = 4.6, -- shot 2
		crawl0 = 7.0, -- shot 3, and the birth
		pull1 = 7.5,
		pull1Hit = 8.3,
		pull1Off = 8.9,
		pull2 = 9.6,
		pull2Hit = 10.5,
		pull2Off = 11.2,
		crawl1 = 11.8,
		lip0 = 11.8, -- shot 4
		lip1 = 13.4,
		eyes0 = 11.9,
		eyes1 = 13.7,
		stand0 = 13.6, -- shot 5
		stand1 = 15.2,
		gnash0 = 15.3, -- shot 6
		gnashHit = 16.0,
		gnashOff = 16.5,
		core = 16.3,
		groan = 16.6,
		sink0 = 16.6,
		sink1 = 17.8, -- 0.4 s before the raise; see THE HANDOFF
		stance = 17.2, -- shot 7
		raise = kit.raiseAt,
		card = kit.raiseAt + 0.85 * kit.riseTime,
	}

	-- ------------------------------------------------------- the crawl's path
	-- ONE function of the crawl's own u, because three things read it: the
	-- pivot track that walks the body, the camera that tracks alongside, and
	-- the lip track that finishes the journey from wherever this left off.
	--
	-- It is radial - the bearing never changes - so `u = 1` lands the pivot on
	-- kit.center exactly rather than near it, which is the handoff's whole
	-- requirement. And it SURGES: 86% of the travel is spent in two smoothstep
	-- pulls timed onto the two strikes below, the remaining 14% as a steady
	-- creep, so the mass moves when a fist lands and drags between.
	local function pullWindow(t: number): (number, number)
		local span = T.crawl1 - T.crawl0
		return (t - 0.35 - T.crawl0) / span, (t + 0.25 - T.crawl0) / span
	end
	local a1, b1 = pullWindow(T.pull1Hit)
	local a2, b2 = pullWindow(T.pull2Hit)
	local function crawlAdvance(u: number): number
		return 0.14 * u + 0.43 * smooth(u, a1, b1) + 0.43 * smooth(u, a2, b2)
	end
	-- The floor it hauls itself over: the bank at the birth point, the mere's
	-- own surface at the middle. Two studs of difference over the whole crawl,
	-- which is the peat sloping into the water and is what the walk should
	-- follow.
	local bornY = kit.floorY(N.bornR, N.bornBearing)
	local function crawlPoint(u: number): Vector3
		local advance = crawlAdvance(u)
		local r = N.bornR - (N.bornR - 8.0) * advance
		return kit.polar(r, N.bornBearing, bornY + (center.Y - bornY) * advance)
	end
	local function crawlAt(t: number): Vector3
		return crawlPoint(math.clamp((t - T.crawl0) / (T.crawl1 - T.crawl0), 0, 1))
	end

	-- ------------------------------------------------------------- the actor
	-- Every attribute the controller reads is written up front, `Attack` very
	-- much included: `isFed` tests exactly that one, and a rig that never sees
	-- it warns "drawing but never fed" eight seconds in, which is a lie about
	-- this run. `Eyes = 0` from the first frame: the default is nil, and nil
	-- means EVERY eye open, so a stand-in that never wrote it would come out of
	-- the mere already blazing and the beat would be gone.
	--
	-- `center` is the birth point, not kit.center: PoseCenter is what
	-- GnashrootPath.newState is handed at adopt, and the pivot takes over from
	-- the next frame.
	local birth = crawlPoint(0)
	local stand = kit.actor({
		pose = N.pose,
		name = "Cutscene_Gnashroot",
		center = birth,
		attrs = {
			Rise = 0,
			FaceAngle = heading,
			Attack = "",
			AttackBlend = 0,
			Strike = 0,
			AimAngle = heading,
			AimSide = 1,
			Exposed = false,
			Eyes = 0,
		},
	})
	stand:pivot(CFrame.new(birth))
	kit.onRealBoss(function()
		stand:destroy()
	end)
	-- Belt and braces, and cheap: by here the stand-in has been under the mud
	-- for a second with the real body climbing through the same water, so there
	-- is nothing left for it to draw even if the rig never replicates.
	kit.at(T.raise + 0.9, function()
		stand:destroy()
	end)

	-- ------------------------------------------------------------ OMEN 0-4.6
	-- The mere breathing under everything. Sfx.loop ignores `maxDuration` (only
	-- Sfx.play fades a cue out), so a 1 s bog cue sustains here; the kit stops
	-- every loop at the end of the run.
	local bog = kit.loop("gnashWallow", center)

	-- Bubbles across the WHOLE mere, not a patch of it: bearing walks by the
	-- golden angle so successive pops never cluster.
	kit.every(T.bubbles0, T.bubbles1, 0.18, function(i)
		local bearing = i * 2.399963
		local radius = 3.0 + ((i * 7) % 23)
		local at = kit.polar(radius, bearing, waterY + 0.05)
		kit.vfx.ring(at, 0.3, 1.4 + (i % 3) * 0.5, 0.75, C.murk)
		if i % 3 == 0 then
			kit.vfx.splash(at, 0.28)
		end
		if i % 5 == 0 then
			kit.sfx("gnashGurgle", at)
		end
	end)
	kit.at(T.creak, function()
		kit.sfx("gnashRootCreak", center)
	end)
	kit.rumble(T.creak, T.wide, 0.005)

	-- ------------------------------------------ THE MERE GATHERS 4.6-8.3
	-- Twelve imported bank objects, one `kit.track` each over the whole of its
	-- life. See THE MERE above for why these are meshes and not the 46 slabs
	-- this used to be.
	kit.at(T.gather0, function()
		kit.sfx("gnashMire", center)
	end)

	for i = 1, N.gather do
		local row = GATHER[((i - 1) % #GATHER) + 1]
		local bearing = (i / N.gather) * math.pi * 2 + rng:NextNumber(-0.12, 0.12)
		local r0 = rng:NextNumber(N.bankInner + 2, N.bankOuter)
		local r1 = rng:NextNumber(3.0, N.mereR - 5.0)
		local curl = rng:NextNumber(-0.3, 0.3)
		local t0 = T.gather0 + ((i - 1) / N.gather) * (T.gatherLast - T.gather0) + rng:NextNumber(0, 0.3)
		local span = rng:NextNumber(1.6, 2.4)
		local y0 = kit.floorY(r0, bearing) + 0.4
		local y1 = waterY - 0.6
		local spin = rng:NextNumber(-2.0, 2.0)
		local tilt = rng:NextNumber(-0.45, 0.45)

		-- `Size` is passed so the import is squashed into a bank-clump
		-- footprint - the SHAPE is the pack's, the silhouette is the mere's -
		-- and so that the no-import fallback is the same clump this drew
		-- before. `kit.mesh` stamps it as BaseSize either way.
		local width = rng:NextNumber(3.6, 7.4)
		local prop = kit.mesh(row.pack, row.name, {
			Size = Vector3.new(width, rng:NextNumber(1.0, 2.4), width * rng:NextNumber(0.7, 1.2)),
			CFrame = CFrame.new(kit.polar(r0, bearing, y0)),
			Color = if i % 3 == 0 then peat else row.color,
			Material = row.material,
			Transparency = 1,
		})

		kit.track(t0, t0 + span, "inout", function(u)
			-- The last fifth is the merge: it drops through the surface and
			-- goes, so nothing is left floating in the middle of the mere.
			local sunk = math.max(0, (u - 0.78) / 0.22)
			local at = kit.polar(r0 + (r1 - r0) * u, bearing + curl * u, y0 + (y1 - y0) * u - sunk * 3.4)
			prop.CFrame = CFrame.new(at) * CFrame.Angles(tilt * u, spin * u, tilt * u * 0.6)
			prop.Transparency = math.max(1 - u / 0.1, sunk)
		end)
	end

	-- The mere taking them: rings where the flow crosses the waterline, and the
	-- peat smoking as it tears loose.
	kit.every(T.gather0 + 0.2, T.crawl0, 0.25, function(i)
		local bearing = i * 2.399963
		kit.vfx.ring(kit.polar(N.mereR - 1.5, bearing, waterY + 0.05), 1.0, 4.5, 1.1, C.murk)
		kit.vfx.puff(kit.polar(N.bankInner + 6 + (i % 17), bearing * 1.3, bankY + 0.6), rim, 0.9)
		if i % 6 == 0 then
			kit.sfx("gnashMire", kit.polar(N.mereR, bearing, waterY))
		end
	end)
	kit.rumble(T.gather0, T.crawl0, 0.008)

	-- ------------------------------------------------- IT CRAWLS 7.0-11.8
	-- The pivot, walked. This is the beat the rig redesign made possible and
	-- the one the old pass never took: drawBody reads `model:GetPivot()
	-- .Position` every frame, so a stand-in is a body that can be moved.
	-- "linear" because the surge is inside `crawlAdvance`, where the strikes
	-- can be pointed at it; an ease on top would smear both pulls.
	kit.track(T.crawl0, T.crawl1, "linear", function(u)
		stand:pivot(CFrame.new(crawlPoint(u)))
	end)

	-- Rise, in the two bands the geometry allows (THE ARMS). Registered in
	-- time order with every other Rise track in this file.
	stand:tween("Rise", 0, N.crawlLow, T.crawl0, T.pull1Off, "out")
	stand:tween("Rise", N.crawlLow, N.crawlHigh, T.pull2, T.crawl1, "inout")

	kit.at(T.crawl0, function()
		kit.sfx("gnashHeave", center)
		kit.vfx.ring(crawlAt(T.crawl0), 3, 18, 1.5, C.murk)
	end)
	kit.rumble(T.crawl0, T.lip1, 0.01)

	-- Peat and water sheeting off whatever is currently above the surface. The
	-- position is taken from the same `crawlAt` the pivot track uses, so the
	-- spray is on the body rather than on the middle of the mere.
	kit.every(T.crawl0, T.lip1, 0.16, function(i)
		local at = crawlAt(kit.t) + Vector3.new(0, 1.0, 0)
		local off = kit.polar(6.0 + (i % 9), i * 2.399963, 0) - center
		kit.vfx.puff(at + off, C.mud, 1.2)
		if i % 4 == 0 then
			kit.vfx.ring(Vector3.new(at.X + off.X, waterY + 0.05, at.Z + off.Z), 1.0, 6.0, 0.9, C.murk)
		end
	end)

	-- PULL ONE: the +1 arm plants. Aim is LATCHED before the blend starts -
	-- GnashrootPath's contract, and the controller COPIES these two rather than
	-- easing them, so a latch written late is a fist that teleports.
	kit.at(T.pull1, function()
		stand:set("AimAngle", heading)
		stand:set("AimSide", 1)
		stand:set("Attack", "heave")
		kit.sfx("gnashHeave", center)
	end)
	stand:tween("AttackBlend", 0, N.haulBlend, T.pull1, T.pull1Hit, "out")
	stand:tween("Strike", 0, 1, T.pull1Hit, T.pull1Hit + 0.55, "in")
	kit.at(T.pull1Hit, function()
		kit.sfx("gnashMire", crawlAt(T.pull1Hit))
		kit.shake(0.02, 0.5, 0.01)
	end)
	-- RELEASED AS A TWEEN, not as a `kit.at`: see WHY EVERY WRITE IS A TRACK.
	-- The attack's NAME is the one thing that must be a copy, and the
	-- controller holds it until the blend has eased home.
	stand:tween("AttackBlend", N.haulBlend, 0, T.pull1Off, T.pull1Off + 0.45, "inout")
	stand:tween("Strike", 1, 0, T.pull1Off, T.pull1Off + 0.45, "inout")
	kit.at(T.pull1Off, function()
		stand:set("Attack", "")
	end)

	-- PULL TWO: the OTHER arm. `AimSide = -1` swaps `heavePlant` and
	-- `heaveBrace` between the flanks, so the second haul is visibly the other
	-- side of the animal doing the work.
	kit.at(T.pull2, function()
		stand:set("AimAngle", heading)
		stand:set("AimSide", -1)
		stand:set("Attack", "heave")
		kit.sfx("gnashHeave", center)
	end)
	stand:tween("AttackBlend", 0, N.haulBlend, T.pull2, T.pull2Hit, "out")
	stand:tween("Strike", 0, 1, T.pull2Hit, T.pull2Hit + 0.55, "in")
	kit.at(T.pull2Hit, function()
		kit.sfx("gnashMire", crawlAt(T.pull2Hit))
		kit.shake(0.024, 0.5, 0.012)
	end)
	stand:tween("AttackBlend", N.haulBlend, 0, T.pull2Off, T.pull2Off + 0.5, "inout")
	stand:tween("Strike", 1, 0, T.pull2Off, T.pull2Off + 0.5, "inout")
	kit.at(T.pull2Off, function()
		stand:set("Attack", "")
		stand:set("AimSide", 1)
	end)

	-- ------------------------------------------- THE LIP 11.8-13.4: the eyes
	-- The last of the journey, and the moment it stops being a mound. The pivot
	-- finishes on kit.center EXACTLY (crawlPoint(1) -> center is a straight
	-- lerp with the destination written out), which is the handoff's pose.
	local lipFrom = crawlPoint(1)
	kit.track(T.lip0, T.lip1, "inout", function(u)
		stand:pivot(CFrame.new(lipFrom:Lerp(center, u)))
	end)
	stand:tween("Rise", N.crawlHigh, N.lipRise, T.lip0, T.lip1, "out")

	-- FOURTEEN EYES ON ONE TRACK, face first. See THE EYES.
	stand:tween("Eyes", 0, 1, T.eyes0, T.eyes1, "inout")
	-- The only light in this beat, and it is on the water rather than on a
	-- prop: the eye row is rig geometry now and lights itself (Neon), but a
	-- Neon part casts nothing, so the mere under the face needs a source or the
	-- reflection is missing. One of this file's two PointLights.
	local wisp = kit.light(Vector3.new(center.X, waterY + 1.2, center.Z), C.wisp, 44, 0)
	kit.track(T.eyes0, T.eyes1, "inout", function(u)
		wisp.Brightness = 2.6 * u
	end)
	kit.track(T.sink0, T.sink1, "linear", function(u)
		wisp.Brightness = 2.6 * (1 - u)
	end)
	kit.at(T.eyes0, function()
		kit.sfx("gnashRootCreak", center)
	end)
	kit.every(T.eyes0, T.eyes1, 0.26, function(i)
		kit.sfx("gnashGurgle", kit.polar(5 + (i % 7), i * 2.399963, waterY + 2))
	end)

	-- ---------------------------------------------- IT STANDS 13.6-15.2
	-- Rise to 1, and the turn the old pass never made: it looks at the party.
	stand:tween("Rise", N.lipRise, 1, T.stand0, T.stand1, "inout")
	stand:tween("FaceAngle", heading, party, T.stand0, T.stand1, "inout")
	kit.at(T.stand0, function()
		kit.sfx("gnashHeave", center)
		kit.vfx.ring(Vector3.new(center.X, waterY + 0.05, center.Z), 6, 34, 1.6, C.murk)
		kit.shake(0.03, 0.9, 0.015)
	end)

	-- ------------------------------------------------- ONE GNASH AT NOTHING
	-- The jaw, which `heave` alone can never show: gape is derived and nonzero
	-- only for gnash/disgorge/hammerfall, and on this rig the LOWER JAW swings
	-- DOWN and back about JAW_HINGE at the chest (the controller applies
	-- `CFrame.Angles(0, 0, -jawAngle)`; the skull never moves). JAW_MAX is 34
	-- degrees and the chin ends 4.1 world studs over the mere.
	--
	-- AT NOTHING: the aim is latched half a radian off the party, so the bite
	-- closes on empty air beside them rather than reading as a first attack.
	kit.at(T.gnash0, function()
		stand:set("AimAngle", party - 0.5)
		stand:set("AimSide", 1)
		stand:set("Attack", "gnash")
	end)
	stand:tween("AttackBlend", 0, N.gnashBlend, T.gnash0, T.gnashHit, "out")
	stand:tween("Strike", 0, 1, T.gnashHit, T.gnashHit + 0.3, "in")
	kit.at(T.gnashHit, function()
		kit.sfx("gnashBite", center)
		kit.shake(0.035, 0.7, 0.02)
	end)
	stand:tween("AttackBlend", N.gnashBlend, 0, T.gnashOff, T.gnashOff + 0.6, "inout")
	stand:tween("Strike", 1, 0, T.gnashOff, T.gnashOff + 0.6, "inout")
	kit.at(T.gnashOff, function()
		stand:set("Attack", "")
		stand:set("AimAngle", party)
	end)

	-- ------------------------------------------------------- THE CORE IGNITES
	-- ON THE RIG, not on a prop. `Gnashroot_Core` is a Neon piece recessed in
	-- the chest hollow at the throat (GnashrootPath.CORE, authored 8.6/0/18.2),
	-- and the controller lights it off `Exposed`:
	-- `glow = 0.18 + 0.12 * pulse + 0.7 * exposed`, eased at 6/s. So the punish
	-- window's own channel IS the ignition, and it fires on the gnash's peak -
	-- the maw opening is what lights it. Handed back false at the sink, which
	-- is what the server publishes.
	--
	-- The one prop is a PointLight in the chest, at GnashrootPath.corePosition's
	-- own point for a risen body: a Neon part lights nothing around it.
	local coreAt = corePoint(1)
	local coreGlow = kit.light(coreAt, C.core, 46, 0)
	kit.at(T.core, function()
		stand:set("Exposed", true)
		kit.vfx.flash(coreAt, C.core, 7, 0.5)
		kit.sfx("gnashRootCreak", coreAt)
		kit.shake(0.025, 0.6)
	end)
	kit.track(T.core, T.core + 0.8, "out", function(u)
		coreGlow.Brightness = 6 * u
	end)
	kit.track(T.sink0 + 0.4, T.sink1, "linear", function(u)
		coreGlow.Brightness = 6 * (1 - u)
	end)

	-- ------------------------------------------------- the groan, and under
	-- "Low enough to shake the camera, everything running off it": the rumble
	-- runs from here to the real rise without a gap, and the rings it pushes
	-- across the mere are still travelling when the body comes back through.
	kit.at(T.groan, function()
		kit.sfx("gnashDisgorge", center)
		kit.sfx("bossStance", center)
		kit.shake(0.045, 1.4, 0.02)
	end)
	kit.rumble(T.groan, T.raise, 0.016)
	kit.every(T.groan, T.sink1, 0.12, function(i)
		kit.vfx.ring(Vector3.new(center.X, waterY + 0.05, center.Z), 6 + i * 1.5, 34 + i * 3.0, 1.4, C.murk)
	end)

	-- DOWN, and this is the handoff pose. Rise is the LAST Rise track
	-- registered, so a fast-forward settles it at 0 after every other one; the
	-- pivot is already kit.center; Exposed is copied back to false; and
	-- `Eyes` is left at the 1 its own last track settles on, which is what the
	-- controller reads for a nil channel anyway.
	stand:tween("Rise", 1, 0, T.sink0, T.sink1, "inout")
	kit.at(T.sink0, function()
		stand:set("Exposed", false)
	end)
	kit.at(T.sink1 - 0.3, function()
		kit.vfx.splash(Vector3.new(center.X, waterY, center.Z), 3.5)
		kit.vfx.ring(Vector3.new(center.X, waterY + 0.05, center.Z), 8, 40, 1.8, C.murk)
		kit.sfx("gnashWallow", center)
		kit.stopLoop(bog)
	end)

	-- ---------------------------------------------- ROAR: the real rise, 18.2+
	-- Nothing of ours is on screen from here: the server has the boss and the
	-- client's own bossRise handler has the splash rings. This is water and
	-- ground shaking under a camera that has stopped moving toward anything.
	kit.every(T.raise, T.card, 0.28, function(i)
		kit.vfx.ring(Vector3.new(center.X, waterY + 0.05, center.Z), 3, 16 + (i % 4) * 4, 1.2, C.murk)
	end)
	kit.rumble(T.raise, T.card, 0.01)

	-- The card lands on the roar CreatureEventController already fires at
	-- 0.85 * riseTime, so they are one beat rather than two.
	local epithet = string.match(kit.boss.name, ",%s*(.+)$") or "the Drowned Mire"
	kit.at(T.card, function()
		kit.card(string.upper(kit.boss.shortName), epithet)
		kit.shake(0.08, 1.3, 0.045)
	end)

	-- ------------------------------------------------------------- the camera
	-- 1. Low over the black water, coming in. Starts 6.2 above the surface and
	--    is inside r 14 before it is down to 3.4, so it passes the reed brakes
	--    at r 23-27 around 5.2 - a stud over the tallest of them.
	kit.shot({
		t0 = 0,
		t1 = T.wide,
		pos = kit.line(kit.polar(33, party + 2.5, waterY + 6.2), kit.polar(13, party + 2.1, waterY + 3.4)),
		look = center + Vector3.new(0, 0.8, 0),
		fov = 64,
	})

	-- 2. The gather, from OUTSIDE the grove: an orbit at r 86 and 34 studs over
	--    the peat, which is the only vantage from which "from every bank at
	--    once" is a thing you can see. The grove is r 67-80, so this is past it
	--    and above it both.
	kit.shot({
		t0 = T.wide,
		t1 = T.crawl0,
		pos = kit.orbit(center, 86, (bankY - center.Y) + 34, party + 2.6, party + 1.9),
		look = center + Vector3.new(0, 2, 0),
		fov = 70,
		blendIn = 0.55,
	})

	-- 3. ALONGSIDE THE CRAWL, at the body's own height, closing from r 74 to
	--    r 30 as it comes. It looks at `crawlAt` - the same function the pivot
	--    track walks - so the mass stays framed while it moves, which is the
	--    whole point of the beat. Crosses r 44 at ~164 degrees, 29 degrees off
	--    the 135 stump.
	kit.shot({
		t0 = T.crawl0,
		t1 = T.lip0,
		pos = function(u)
			return kit.polar(74 - 44 * u, N.bornBearing - 0.55 - 0.35 * u, bankY + 11 - 5.5 * u)
		end,
		look = function(_u, t)
			return crawlAt(t) + Vector3.new(0, 8, 0)
		end,
		fov = 66,
		blendIn = 0.6,
	})

	-- 4. Low and looking UP for the lip and the eyes: the face comes over the
	--    lens rather than into the middle of frame. Inside the reed band's
	--    radius but 9-13 studs above it.
	kit.shot({
		t0 = T.lip0,
		t1 = T.stand0,
		pos = function(u)
			return kit.polar(26 - 6 * u, party + 0.6 - 0.3 * u, waterY + 9 + 4 * u)
		end,
		look = function(u)
			return center + Vector3.new(0, 2 + 14 * u, 0)
		end,
		fov = 72,
		blendIn = 0.5,
	})

	-- 5. IT STANDS. Section 3.4's own move: an orbit from 240 to 330 degrees at
	--    r 74, 40 studs up and tilting to follow the crown - over the grove, and
	--    ending near the party's bearing so the next two shots are short moves.
	kit.shot({
		t0 = T.stand0,
		t1 = T.gnash0,
		pos = kit.orbit(center, 74, (bankY - center.Y) + 40, party + math.rad(240), party + math.rad(330)),
		look = function(u)
			return center + Vector3.new(0, 14 + 12 * u, 0)
		end,
		fov = 62,
		blendIn = 0.7,
	})

	-- 6. Close on the head for the gnash and the core. The head's top sits
	--    ~22 world studs over the body origin, which at Rise 1 is the arena
	--    centre's own Y, so the look walks from the head down to the chest as
	--    the knot lights. Open water the whole way.
	kit.shot({
		t0 = T.gnash0,
		t1 = T.stance,
		pos = function(u)
			return kit.polar(34 - 13 * u, party + 0.42 - 0.3 * u, waterY + 16 + 4 * u)
		end,
		look = function(u)
			return (center + Vector3.new(0, 22, 0)):Lerp(coreAt, u * 0.8)
		end,
		fov = 55,
		blendIn = 0.6,
	})

	-- 7. Back to where the party is standing, on the drop-in ring's own bearing
	--    and radius, in time to be settled there before the real boss comes up.
	--    Still moving - a slow 4-stud dolly and a lift - so the last four
	--    seconds are not a locked-off tripod, and the 0.8 s blend the controller
	--    appends at `duration - 0.8` has almost nothing to travel.
	kit.shot({
		t0 = T.stance,
		t1 = kit.duration,
		pos = function(u)
			return kit.polar(ringR + 4 - 4 * u, party, bankY + 5.6 + 1.2 * u)
		end,
		look = function(u)
			return center + Vector3.new(0, 6 + 6 * u, 0)
		end,
		fov = 60,
		blendIn = 1.0,
	})
end
