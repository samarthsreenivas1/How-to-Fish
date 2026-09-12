--!nonstrict
-- NoctyssIntro.luau
-- Noctyss, the Trench Mother: the intro you watch in the dark.
--
-- REWRITTEN 2026-09-12 against docs/boss-cutscenes-redesign.md section 3.3.
--
-- THE RULE THIS FILE USED TO BE BUILT AROUND WAS "you never see her", AND IT
-- HAS BEEN AMENDED - ONCE, EXACTLY, AND WITH A CEILING. The brief is "we
-- should actually see all of the bosses before we fight them", and of the
-- seven intros this was the only one that showed no boss at all. So she comes
-- up. But she comes up EXACTLY AS FAR AS THE FIGHT'S OWN TELL DOES AND NO
-- FURTHER: `NoctyssPath.SNAP.RISE_TO`, read out of the module rather than
-- typed here, which is the fraction "tuned to a height" that puts the skull's
-- origin at arena-local y -3.6 - the height at which "the lower jaw's lip and
-- the fang line breach the pit rim and nothing else does" (SNAP's own
-- comment). Bone-white on black, out of the water (the pit's plane at
-- GL_PIT_WATER_Z = -5.0 is fraction 0.371, so 0.406 clears it by 1.4 studs of
-- travel and nothing more), and then she sinks.
--
-- THE CEILING IS THE DESIGN, not a tuning value. The punish window is the
-- whole fight: a cinematic that showed the full rise would spend the thing the
-- player is meant to earn. The partial rise is the opposite - it teaches the
-- read. Section 3.3's table says 0.45; the cap here is 0.406, which is the
-- user-locked number and the one the module already owns. (Listed in NOTES.md.)
--
-- SO THE REVEAL IS NOW THREE THINGS, in order, and the first two are unchanged
-- from the version this replaces: the FLOOR (the Choirfloor's mantle pass -
-- arena_gen.py, "the shelf as her back" - rolled the pit's inner edge into a
-- lower lip and ran seven tendon ridges out to the seven socket collars, with
-- a VEIN down the crest of each), the CHOIR that grows out of it, and then,
-- for two and a half seconds, HER.
--
-- NOTE ON THE BRIEF. The brief called the Mantle a ceiling ("the ceiling
-- tears"). It is not: `NoctyssArena_Mantle` is FLOOR - the rolled lip r
-- 15.5-21.7 plus seven ridges out to r 34, one to two studs proud of the
-- shelf, measured walkable by the generator's own slope check. There is no
-- ceiling in this arena at all. The beat is kept and inverted: the shudder and
-- the vein glow run through the ground the party is standing on, which is a
-- better version of the same idea and the one the mesh can actually draw.
--
-- SEVEN STAND-INS, CREATED ONE AT A TIME. Each is a `choir_stalk` model that
-- NoctyssBodyController adopts off `Pose`, so the stalks in the cinematic are
-- drawn by the same chain solver, from the same pack, as the stalks in the
-- fight. `Grow` (0 under the collar, 1 fully out) now lives in `NoctyssPath`
-- (`growOf`/`setGrow`) and the SERVER writes it during a choir regrow, so the
-- module's own rule applies here in as many words: "the cutscene lane's
-- stand-in stalks may still drive it client-only". EVERY `Grow` WRITE BELOW
-- GOES THROUGH `actor:tween` ON A MODEL THIS FILE CREATED - see `mine`, which
-- is also what the retirement check uses to tell a real stalk from one of
-- ours. Nothing here ever writes an attribute on a model it did not make.
--
-- THE LIGHTING PLAN IS NOW THE FIGHT'S. Two sources and no third: the pit
-- lantern far down in the mouth, and the choir's own lanterns - which are
-- REAL lights the rig hangs on each bulb itself (`NoctyssBodyController`
-- makeLantern: a PointLight, range 44, driven by `Douse`), so seven stalks
-- arriving IS seven lights arriving and this file does not need to add any.
-- Removed in this pass: the dim violet fill hung 68 studs over the pit, and
-- the seven floor lights under the veins. Both were fill, and the Choirfloor
-- is meant to be black - the veins are self-lit Neon, which is the whole read
-- in a dark room, and a glowing cord does not need a lamp pointed at it. The
-- maw brings her own two (the gullet and the esca) when she comes up.
--
-- THE HANDOFF. `raiseAt` is where the real boss starts up through the pit.
-- The rising branch publishes ONLY the three maw channels for this boss
-- (CreatureService's pose publish: `elseif creature.poseKind == "noctyss"`),
-- from a `NoctyssPath.newState`, so the frame it starts on is
-- `MawRise = 0, MawGape = 0, MawYaw = authored(LANES[1])` and nothing else.
-- The sink below lands on exactly that, 0.2 s early, and it is given 1.4 s to
-- get there because `EASE.mawRise` is 2.2/s and the eased head has to actually
-- ARRIVE - at 1.4 s it is within 0.019 of the fraction, which is 0.8 studs of
-- a 40.4-stud travel, 19 studs under the shelf.
--
-- Beats: OMEN   0 - 6.4  (black, one lantern, her back moves)
--        CHOIR  6.4 - 13.4 (seven stalks, the lean, the pit exhales)
--        HER    13.4 - 17.3 (she rears to the rim, the chord, she sinks)
--        ROAR   17.5 - 22 (the real rise, the douse, the card)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local NoctyssPath = require(Shared.Modules.NoctyssPath)

-- THE TIMELINE, in one table, because a retune is a re-read of this block and
-- nothing else. Total 22 s (BossCutscenes.noctyss, 20 -> 22 in this pass to
-- buy the maw its two and a half seconds), riseTime 4.5, so the real rise
-- starts at 17.5 and the card lands at 17.5 + 0.85 * 4.5 = 21.325.
local T = {
	fadeHold = 0.6, -- how long the screen stays fully black
	fadeIn = 2.0, -- ...and how long it takes to come off it
	lantern = 1.1, -- one light, far down in the pit
	shudder = 4.6, -- her back moves
	vein = 6.4, -- the first vein takes the light out of the mouth
	stalk = 6.9, -- ...and the first stalk arrives where it ends
	stalkGap = 0.72, -- seven of them, one by one
	grow = 0.85, -- how long one takes to clear its collar
	beamIn = 12.4, -- the choir turns its lanterns over the mouth
	lean = 12.7,
	exhale = 13.4, -- the pit breathes out...
	born = 13.45, -- ...and she is created inside the dark of it
	riseT0 = 13.8, -- SHE COMES UP
	riseT1 = 15.6, -- 1.8 s, the fight's own fixed rise
	chord = 15.6, -- a chord, not a roar
	sinkT0 = 15.9, -- ...and she goes back down
	sinkT1 = 17.3,
	douse = 20.7, -- every lantern at once, so the card lands on black
	relight = 21.55,
	shot = { 3.4, 7.2, 12.6, 13.8, 15.9, 20.7 }, -- the cut points that are not raiseAt
}

-- THE GEOMETRY, all of it re-keyed from the modules that own it rather than
-- measured off a screenshot. Fallbacks only: `socketWorld` prefers
-- NoctyssPath.socketPoint and these are what it falls back to.
local N = {
	sockets = 7,
	socketR = 34.0, -- NoctyssPath.SOCKET_R / arena_gen GL_SOCKET_R
	socket0 = 12.0, -- the first collar's authored bearing
	rootY = 2.2, -- NoctyssPath.REST.ROOT_Y, the collar's mouth
	pitR = 15.0, -- NoctyssPath.PIT_R
	pitWaterY = -5.0, -- arena_gen GL_PIT_WATER_Z, relative to kit.center
	veinInner = 17.0, -- the vein strips run r 16.5 -> 30.2 (arena_gen)
	veinOuter = 30.0,
	ringR = 40.0, -- the reveal orbit: outside the collars, INSIDE the fins
	finR = 46.0, -- arena_gen GL_FINS: nothing of the fins reaches inboard
	partyR = 44.0, -- Bosses.noctyss.arena.radius 36 + 8 = the drop-in ring
	mawGape = 0.7, -- how far the jaw swings at the top of the tell
}

-- Her palette, off arena_gen.py's own constants (GLOW_CYAN, GLOW_VIOLET,
-- DARKWATER) so the cinematic's light is the arena's light.
local C = {
	lure = Color3.fromRGB(74, 239, 224), -- GLOW_CYAN: a lantern
	vein = Color3.fromRGB(169, 106, 239), -- GLOW_VIOLET: what runs under her skin
	dark = Color3.fromRGB(6, 11, 22), -- DARKWATER: what the pit exhales
	bone = Color3.fromRGB(226, 220, 198), -- what breaks the rim
}

return function(kit)
	local c = kit.center
	-- The party's arrival bearing. BossArenaService.ringPositions walks
	-- `(i / count) * 2pi` from +X, so a solo summoner stands at bearing 0 and a
	-- party rings the centre through it: ending the camera here is the shortest
	-- blend back to somebody's own shoulder. In authored degrees it is 360,
	-- which is also one of NoctyssPath.LANES (352) - the gaps between the
	-- shadow fins - so the last three shots fly a lane rather than a blade.
	local home = kit.authored(360)
	local lane = kit.authored(224) -- likewise a lane: fins sit at 196 and 252

	-- THE LANE SHE SURFACES ON, from the module that decides it in the fight:
	-- `laneFor` takes a bearing and returns the nearest authored fin gap, and
	-- the fight hands it the party's centre. Bearing 0 is where the party
	-- stands (above), so she rears facing them down the same lane the last
	-- three shots fly.
	local mawLane = NoctyssPath.laneFor(0)
	-- ...and the lane the RISING BRANCH starts on, which is the one the sink
	-- has to return to: `NoctyssPath.newState`'s own default.
	local mawHome = kit.authored(NoctyssPath.LANES[1])
	-- THE CAP, read out of the module rather than typed. See the header.
	local mawTop = NoctyssPath.SNAP.RISE_TO

	-- The pit water, from the authored part when it is there. `DecoPitWater` is
	-- a disc at GL_PIT_WATER_Z over the bed, and its bbox is the mouth.
	local waterPos, waterSize = kit.landmark("DecoPitWater")
	local pitY = if waterPos then waterPos.Y else c.Y + N.pitWaterY
	local pitR = if waterSize then math.max(waterSize.X, waterSize.Z) * 0.5 else N.pitR
	local mouth = Vector3.new(c.X, pitY, c.Z)

	-- The vein strips are ONE merged object, so their seven crest curves cannot
	-- be recovered from it - only how far out they reach. That is the one thing
	-- worth reading (a retuned mantle moves it), and the bearings come from the
	-- sockets, which is where the generator gets them too.
	local _, veinSize = kit.landmark("DecoVeins")
	local veinOuter = if veinSize then math.max(veinSize.X, veinSize.Z) * 0.5 else N.veinOuter
	local mantlePos = kit.landmark("Mantle")
	local mantleY = if mantlePos then mantlePos.Y else c.Y + 1.9

	-- ------------------------------------------------------------ geometry

	local function socketBearing(index: number): number
		local angle = if NoctyssPath.socketAngle then NoctyssPath.socketAngle(index) else nil
		if typeof(angle) == "number" then
			return angle
		end
		return kit.authored(N.socket0 + (index - 1) * (360 / N.sockets))
	end

	local function socketWorld(index: number): Vector3
		local point = if NoctyssPath.socketPoint then NoctyssPath.socketPoint(index) else nil
		if typeof(point) == "Vector3" then
			return c + point
		end
		return kit.polar(N.socketR, socketBearing(index), c.Y + N.rootY)
	end

	-- A camera point on an arena-local bearing, `height` studs over kit.center
	-- (the arena's own floor datum).
	local function camAt(radius: number, bearing: number, height: number): Vector3
		return kit.polar(radius, bearing, c.Y + height)
	end

	-- ...and the same thing measured off the floor actually under it, for the
	-- two shots low enough that the mantle's relief matters.
	local function camFloor(radius: number, bearing: number, above: number): Vector3
		return kit.polar(radius, bearing, kit.floorY(radius, bearing) + above)
	end

	-- WHERE HER MOUTH IS AT A GIVEN FRACTION, from the path module rather than
	-- from a literal - `mawMouth` is the middle of the lower jaw, which is what
	-- the camera should be looking at, and it hinges with the gape, so asking
	-- the module is the only way to aim at it. Built on a scratch state rather
	-- than on the stand-in's own, because the stand-in's state lives in the
	-- body controller and is eased: this is the AUTHORED frame, which is what
	-- a camera wants.
	local mawScratch = NoctyssPath.newState(c)
	local function mawMouthAt(rise: number, gape: number): Vector3
		mawScratch.mawRise = rise
		mawScratch.mawGape = gape
		mawScratch.mawYaw = mawLane
		return NoctyssPath.mawMouth(mawScratch).Position
	end

	local mawUp = mawMouthAt(mawTop, N.mawGape)
	local mawDown = mawMouthAt(0, 0)

	-- ------------------------------------------------------------ the light

	-- A PointLight whose brightness and range are a track rather than a tween,
	-- so a skip lands on the settled value like everything else here.
	local function lightTo(light: PointLight, t0: number, t1: number, brightness: number, range: number, ease: any?)
		local b0, r0 = light.Brightness, light.Range
		kit.track(t0, t1, ease, function(u)
			light.Brightness = b0 + (brightness - b0) * u
			light.Range = r0 + (range - r0) * u
		end)
	end

	-- THE OMEN LIGHT, and now one of only two light sources in the cinematic
	-- (see the header). One lantern, far down in the water at the bottom of
	-- the mouth, climbing toward the rim: the only thing on screen for six
	-- seconds.
	local pitLight = kit.light(mouth - Vector3.new(0, 1.5, 0), C.lure, 24, 0)
	local pitHost = pitLight.Parent
	lightTo(pitLight, T.lantern, 5.0, 2.1, 105, "out")
	if pitHost then
		kit.tweenPart(pitHost, { CFrame = CFrame.new(mouth + Vector3.new(0, 3.0, 0)) }, T.lantern, 6.4, "out")
	end

	-- ------------------------------------------------------------ her back

	-- Seven veins, each a run of short neon segments lying in the ridge gutter
	-- from the lip out to the collar. Neon and nothing else: they are self-lit,
	-- they cost nothing, and in a black room a glowing cord in the floor is the
	-- whole read. These stay `kit.part` rather than becoming `kit.mesh` clones
	-- of `NoctyssArena_DecoVeins` for a stated reason - DecoVeins is ONE merged
	-- object carrying all seven crests, so there is no per-vein mesh to clone
	-- and a size-squashed clone of a seven-armed star is a blob, not a cord.
	-- (Listed in NOTES.md against section 3.3's table.)
	local function buildVein(index: number)
		local bearing = socketBearing(index)
		local segments = {}
		for step = 0, 3 do
			local radius = N.veinInner + (veinOuter - N.veinInner) * (step / 3)
			local floor = kit.floorY(radius, bearing)
			local part = kit.part({
				Size = Vector3.new(1.3, 0.28, 4.6),
				CFrame = CFrame.new(kit.polar(radius, bearing, floor + 0.34))
					* CFrame.Angles(0, -bearing + math.pi * 0.5, 0),
				Color = C.vein,
				Material = Enum.Material.Neon,
				Transparency = 1,
			})
			segments[step + 1] = part
		end
		return segments
	end

	-- ------------------------------------------------------------ the choir

	-- The stand-ins, filled in as they are created. Every later beat walks this
	-- table and skips what is not there yet, so nothing depends on the order
	-- the events happen to fire in after a fast-forward.
	local stalks = {}
	local mine = {}

	local function grow(index: number)
		local root = socketWorld(index)
		local bearing = socketBearing(index)
		-- The vocabulary the controller adopts on (NoctyssBodyController
		-- `adoptStalk`: SocketIndex, TrueLure, PoseCenter, Lean, BeamAngle,
		-- Douse, Grow).
		--
		-- Douse 1 = dark: a stalk clears its collar unlit and KINDLES, which is
		-- the whole point of doing them one at a time. TrueLure goes on socket
		-- 4 and nothing in the shot singles socket 4 out - the true lure is
		-- re-marked every regrow, so a cinematic that pointed at one collar
		-- would be teaching a tell that is false by the first cycle. What it
		-- does teach is that one of the seven breathes lower than the rest,
		-- which is the tell that IS true.
		local actor = kit.actor({
			pose = "choir_stalk",
			name = "CutsceneChoirStalk" .. index,
			center = c,
			attrs = {
				SocketIndex = index,
				TrueLure = index == 4,
				Lean = 0,
				BeamAngle = bearing,
				Douse = 1,
				Grow = 0,
			},
		})
		stalks[index] = actor
		mine[actor.model] = true
		actor:tween("Grow", 0, 1, kit.t, kit.t + T.grow, "out")
		actor:tween("Douse", 1, 0, kit.t + 0.30, kit.t + 0.95, "inout")

		-- The arrival itself: silt off the collar, a ring on the stone, and the
		-- rig's own lantern coming up with it (makeLantern hangs a real
		-- PointLight on the bulb and `Douse` drives it, so the light arrives
		-- with the stalk and this file adds none).
		kit.vfx.puff(root, C.dark, 1.5)
		kit.vfx.ring(root - Vector3.new(0, 1.2, 0), 3, 13, 0.85, C.vein)
		kit.sfx("emerge", root)
		kit.sfx(if index == 4 then "choirPulseTrue" else "choirPulse", root)
		kit.shake(0.012, 0.45, 0.006)
	end

	for index = 1, N.sockets do
		local stalkAt = T.stalk + (index - 1) * T.stalkGap
		local veinAt = stalkAt - (T.stalk - T.vein)
		kit.at(veinAt, function()
			local segments = buildVein(index)
			for step, part in segments do
				local lit = veinAt + (step - 1) * 0.11
				kit.tweenPart(part, { Transparency = 0.12 }, lit, lit + 0.26, "out")
			end
		end)
		kit.at(stalkAt, function()
			grow(index)
		end)
	end

	-- ------------------------------------------------------------ the omen

	-- The trench's own note under everything, and her pulse over it. The
	-- heartbeat is `choirPulse` at the mouth rather than a loop: the fight's
	-- breath cue, played on a beat, which is the sound the party will spend the
	-- next five minutes listening for.
	kit.at(0, function()
		-- Black first and the clear as its own beat: `kit.fade` reads the
		-- CURRENT alpha as its start, so the two in one breath would cancel and
		-- the cinematic would open on a lit arena it has not lit yet.
		kit.fade(1, 0.01)
		kit.loop("whirlpool", mouth)
	end)
	kit.at(T.fadeHold, function()
		kit.fade(0, T.fadeIn)
	end)
	kit.every(0.5, T.chord, 1.9, function(i)
		kit.sfx(if i % 2 == 0 then "choirPulse" else "choirPulseTrue", mouth)
	end)
	kit.at(T.lantern, function()
		kit.vfx.ring(mouth, 2, pitR * 0.8, 2.4, C.lure)
		kit.sfx("lureFlare", mouth)
	end)

	-- HER BACK MOVES. A shudder that starts at the lip and runs out over the
	-- shelf the party is standing on, one shockwave along the stone and a
	-- sustained rumble under it.
	kit.at(T.shudder, function()
		kit.vfx.shockwave(Vector3.new(c.X, mantleY + 0.4, c.Z), pitR, N.socketR + 8, 1.5, C.vein, 0.3)
		kit.sfx("bossStagger", mouth)
		kit.sfx("iceCreak", c)
	end)
	kit.rumble(T.shudder, T.shudder + 1.6, 0.02)
	kit.rumble(T.vein, T.stalk + 6 * T.stalkGap + T.grow, 0.009)

	-- ------------------------------------------------------------ the choir leans

	-- Every lantern turns over the mouth. `BeamAngle` is the bearing a stalk's
	-- light is on and `Lean` pushes the lantern toward it (NoctyssPath
	-- LEAN_REACH), so the socket's bearing plus pi is "reach in over the pit" -
	-- and the controller eases the angle, which is why it is set half a second
	-- before the lean that uses it. The lean is also the LIGHTING for the beat
	-- that follows: seven lanterns hanging over the mouth is what she rears
	-- into.
	kit.at(T.beamIn, function()
		for index, actor in stalks do
			actor:set("BeamAngle", socketBearing(index) + math.pi)
		end
	end)
	kit.at(T.lean, function()
		for _, actor in stalks do
			actor:tween("Lean", 0, 0.55, kit.t, T.chord, "inout")
		end
		lightTo(pitLight, kit.t, T.chord, 3.4, 150, "in")
	end)

	-- THE PIT EXHALES. Dark comes up out of the mouth and spreads over the
	-- water, and the light in the water goes with it. This is also the mask the
	-- stand-in is born behind, one frame later.
	kit.at(T.exhale, function()
		kit.vfx.puff(mouth + Vector3.new(0, 2, 0), C.dark, 5.5)
		kit.vfx.ring(mouth, 3, pitR, 1.6, C.dark)
		kit.vfx.ring(mouth, pitR * 0.4, pitR + 6, 2.2, C.lure)
		kit.sfx("mawRise", mouth)
		kit.sfx("inkBlast", mouth)
		kit.shake(0.03, 1.0)
	end)

	-- ------------------------------------------------------------ SHE RISES
	--
	-- The eighth stand-in, and the one this rewrite exists for: a
	-- `Pose = "noctyss"` model, which NoctyssBodyController's `adoptMaw` picks
	-- up and draws from the same NoctyssPack skull, jaw, gullet and barbels the
	-- fight draws - forty pieces of authored mesh doing the one thing the head
	-- does. Nothing else in this file is her, and there is no second way to
	-- draw her: `mawCFrame` is the only frame, and it is built from
	-- `state.center` plus `MAW.Y_DOWN + fraction * (Y_UP - Y_DOWN)`.
	--
	-- SHE IS CREATED ALREADY DOWN, inside the dark of the exhale. At
	-- `MawRise = 0` her origin is 20 studs under the shelf and the highest
	-- point of the head (Noctyss_SkullBone, 8.3 studs over the origin at
	-- SCALE 2.0 - measured off the shipped glb, MAW.Y_DOWN's own note) is at
	-- -11.7, which is under the pit's water plane at -5. So nothing of her is
	-- on screen before `riseT0`, and the puff covers the adopt regardless.
	local maw = nil
	kit.at(T.born, function()
		maw = kit.actor({
			pose = "noctyss",
			name = "CutsceneNoctyssMaw",
			center = c,
			attrs = {
				MawRise = 0,
				MawGape = 0,
				MawYaw = mawLane,
			},
		})
		mine[maw.model] = true

		-- 1.8 s, which is the fight's own rise: "the rise is a fixed 1.8s
		-- because CreatureService steps mawRise on the FRACTION at a fixed
		-- rate, not in studs" (MAW.Y_DOWN's note). Registered from inside the
		-- `at` because the actor does not exist until here, and a skip past
		-- this point fires the `at`, creates her, and lets the tracks settle -
		-- so a skipped run still lands on the handoff pose rather than on no
		-- model at all.
		maw:tween("MawRise", 0, mawTop, T.riseT0, T.riseT1, "out")
		maw:tween("MawGape", 0, N.mawGape, T.riseT0 + 0.35, T.riseT1 - 0.2, "out")
		-- THE YAW SWINGS ONTO THE PARTY on the way up and back onto the rising
		-- branch's own lane on the way down. `EASE.mawYaw` is 3.0/s and this is
		-- a 1.1 rad swing, so the sink's 1.4 s closes it to under a degree.
		maw:tween("MawYaw", mawHome, mawLane, T.riseT0, T.riseT1 - 0.3, "inout")

		-- ...and back down. `MawGape` shuts first - the jaws close, and THEN
		-- she goes - which is the order the fight's own snap uses (SNAP.BITE
		-- before SNAP.SINK) and the only order that reads as a mouth rather
		-- than as a model sliding.
		maw:tween("MawGape", N.mawGape, 0, T.chord, T.sinkT0 + 0.3, "in")
		maw:tween("MawRise", mawTop, 0, T.sinkT0, T.sinkT1, "inout")
		maw:tween("MawYaw", mawLane, mawHome, T.sinkT0, T.sinkT1, "inout")

		-- THE HANDOFF FRAME, written as values rather than left as the ends of
		-- three tweens: exactly what the rising branch publishes at progress 0
		-- from a fresh `NoctyssPath.newState`. 0.2 s before `raiseAt`, on top
		-- of the 1.4 s the sink already gave the ease.
		kit.at(T.sinkT1, function()
			if maw then
				maw:set("MawRise", 0)
				maw:set("MawGape", 0)
				maw:set("MawYaw", mawHome)
			end
		end)

		-- The real head replaces this one the moment it lands. Registered here
		-- rather than beside the choir's retirement because the two retire on
		-- DIFFERENT events and for different reasons: there is exactly one maw
		-- and the boss model IS it, so two drawings of one head must never
		-- overlap for a frame.
		kit.onRealBoss(function()
			if maw then
				maw:destroy()
				maw = nil
			end
		end)
	end)

	-- What it sounds like. `mawRise` is the water she comes up through and
	-- `mawBite` is the jaw; the chord is below.
	kit.at(T.riseT0, function()
		kit.sfx("mawRise", mouth)
		kit.sfx("bossStagger", mouth)
		kit.vfx.splash(mouth, 4.2)
		kit.vfx.ring(mouth, 2, pitR + 4, 1.4, C.lure)
		kit.shake(0.04, 1.6, 0.02)
	end)
	kit.rumble(T.riseT0, T.chord, 0.016)
	kit.at(T.riseT1 - 0.35, function()
		-- The lip and the fang line clearing the rim: the one frame the whole
		-- beat is for, and the only bone-white thing in the arena.
		kit.vfx.flash(mawUp + Vector3.new(0, 2, 0), C.bone, 22, 0.6)
		kit.sfx("mawBite", mawUp)
	end)

	-- THE CHORD. Seven lanterns at once instead of a throat: this boss does not
	-- roar, and the catalogue's Noctyss block says so in as many words ("the
	-- one fight fought by ear"). `choirBeam` carries, `bellToll` is the note,
	-- `mawRise` is the water under both.
	kit.at(T.chord, function()
		local now = Workspace:GetServerTimeNow()
		for _, actor in stalks do
			actor:set("Flare", now)
		end
		kit.sfx("choirBeam", c)
		kit.sfx("bellToll", c)
		kit.sfx("mawRise", mouth)
		kit.flash(C.lure, 0.32, 0.9)
		kit.vfx.flash(mouth + Vector3.new(0, 4, 0), C.lure, 26, 0.7)
		kit.shake(0.045, 1.3)
	end)
	kit.at(T.sinkT0, function()
		kit.sfx("mawRise", mouth)
		kit.vfx.ring(mouth, 3, pitR, 1.8, C.dark)
	end)
	kit.rumble(T.chord, kit.raiseAt, 0.014)

	-- ------------------------------------------------------------ the handoff

	-- THE LAST 4.5 SECONDS BELONG TO THE SERVER. `raiseAt` is where the real
	-- boss starts up through the pit, and from here the script is camera,
	-- water and choir only - her own stand-in is retired by `onRealBoss`
	-- above, on the frame the real head exists.
	--
	-- The stand-in CHOIR is a different question and it does not hand over at
	-- raiseAt: the server spawns the real stalks at u >= 1 of the rise (the
	-- `spawnBossParts` call at the end of CreatureService's rise branch), which
	-- is `duration`, so destroying the stand-ins when the maw's model lands
	-- would take the choir off screen for the whole rise and put it back at the
	-- end. Instead the maw's arrival ARMS the retirement and the real stalks
	-- (or the last frame, whichever comes first) spend it.
	local function retire()
		for index, actor in stalks do
			actor:destroy()
			stalks[index] = nil
		end
	end
	--
	-- The armed beat sits just PAST the last frame on purpose: the kit's own
	-- teardown destroys every actor at `duration`, so this is the overrun
	-- insurance (a run held open past its end by a late raise payload), not the
	-- normal path. Firing it a hair early instead would take the choir away in
	-- the middle of the card for nothing.
	kit.onRealBoss(function()
		kit.at(kit.raiseAt + kit.riseTime + 0.25, retire)
	end)
	-- ...and the real choir itself, whenever it lands. A `choir_stalk` model
	-- under Workspace.Creatures that is not one of mine is the server's, and
	-- the moment one exists the stand-ins are two drawings of one body.
	kit.every(kit.raiseAt, kit.duration + 2, 0.1, function()
		local folder = Workspace:FindFirstChild("Creatures")
		if not folder then
			return
		end
		for _, child in folder:GetChildren() do
			if child:IsA("Model") and child:GetAttribute("Pose") == "choir_stalk" and not mine[child] then
				retire()
				return
			end
		end
	end)

	-- The pose the stand-ins hold at the moment the real ones replace them is
	-- the pose a freshly spawned stalk has: Grow 1, Lean 0, Douse 0, BeamAngle
	-- back on its own socket's bearing (NoctyssPath.newState's defaults). So
	-- the lean comes out over the rise, and the light comes back after the
	-- card.
	kit.at(kit.raiseAt, function()
		for _, actor in stalks do
			actor:tween("Lean", 0.55, 0, kit.t, kit.t + 2.0, "inout")
		end
		kit.vfx.ring(mouth, 2, pitR + 10, 2.6, C.lure)
		kit.vfx.splash(mouth, 3.2)
		kit.sfx("mawRise", mouth)
		lightTo(pitLight, kit.t, kit.t + 2.4, 4.2, 190, "out")
	end)
	kit.at(kit.raiseAt + 1.5, function()
		for index, actor in stalks do
			actor:set("BeamAngle", socketBearing(index))
		end
	end)
	kit.rumble(kit.raiseAt, T.douse, 0.02)

	-- EVERY LANTERN AT ONCE, so the card lands on near-black. This is the
	-- fight's own `dousehunt` - the beat where the choir takes the light away -
	-- used as the last thing before the title, and it means the card is read
	-- against the arena's true colour rather than against a lit set.
	kit.at(T.douse, function()
		for _, actor in stalks do
			actor:tween("Douse", 0, 1, kit.t, kit.t + 0.45, "in")
		end
		lightTo(pitLight, kit.t, kit.t + 0.5, 0.25, 60, "in")
		kit.sfx("choirDouse", c)
	end)

	-- The card, on the beat CreatureEventController's bossRise handler already
	-- fires its roar and shake on.
	kit.at(kit.raiseAt + 0.85 * kit.riseTime, function()
		kit.card(string.upper(kit.boss.shortName), "the Trench Mother")
		kit.shake(0.07, 1.4, 0.03)
		kit.sfx("bellToll", c)
	end)

	-- ...and the choir comes back up under it, so the last frame handed to the
	-- player is the one the fight starts on: seven lanterns lit, in the dark.
	kit.at(T.relight, function()
		for _, actor in stalks do
			actor:tween("Douse", 1, 0, kit.t, kit.t + 0.42, "out")
		end
		lightTo(pitLight, kit.t, kit.t + 0.5, 2.6, 140, "out")
		kit.sfx("choirBeam", c)
	end)

	-- ------------------------------------------------------------ the camera
	--
	-- CLEARANCE, once, for all eight shots. The Choirfloor's solid geometry is:
	-- the shelf (about +1.5 from r 18 out to r 68), the rolled lip (crest +2.8
	-- at r 18.6), the collars (+2.2 at r 34), SIX SHADOW FINS at r 46-58
	-- standing 13-19 studs proud, and the boundary teeth past r 69. Nothing at
	-- all stands between the lip and r 46.
	--
	-- So every shot below is one of three things: over the mouth (r < 34, where
	-- there is only air), on the ring at r 40 (six studs inboard of the fins'
	-- inner edge, and the fins are set TANGENTIALLY so their length runs along
	-- the ring rather than at the camera), or out on a LANE - one of
	-- NoctyssPath.LANES, the authored gaps between the fins - where the nearest
	-- blade is 25+ degrees off the flight line. Heights are all measured off
	-- kit.center, which sits at the arena's own floor datum, and the two low
	-- shots take theirs from kit.floorY at the radius they are actually at.

	-- 1. DOWN THE THROAT. Over the mouth, pushing down toward the one light in
	-- the world. Nothing is under it but the pit.
	kit.shot({
		t0 = 0,
		t1 = T.shot[1],
		pos = kit.line(camAt(30, lane, 40), camAt(24, lane, 16)),
		look = mouth,
		fov = 68,
	})

	-- 2. HER BACK. Down on the stone at the lip, backing out along a lane while
	-- the shudder and then the first veins run outward past the lens. The
	-- height is floorY-relative because this is the one shot low enough for the
	-- mantle's own relief to matter.
	kit.shot({
		t0 = T.shot[1],
		t1 = T.shot[2],
		pos = kit.line(camAt(24, lane, 16), camFloor(N.ringR, lane, 11)),
		look = Vector3.new(c.X, mantleY + 1.5, c.Z),
		fov = 70,
	})

	-- 3. THE CHOIR. The ring shot: r 40, inboard of every fin, swinging 136
	-- degrees from the lane it arrived on round to the party's own bearing
	-- while it climbs from 11 to 28 studs. The lanterns top out around +35 at
	-- r 23, so the look point rises with them.
	kit.shot({
		t0 = T.shot[2],
		t1 = T.shot[3],
		pos = function(u)
			local bearing = lane + (home - lane) * u
			return camAt(N.ringR, bearing, 11 + 17 * u)
		end,
		look = function(u)
			return Vector3.new(c.X, c.Y + 9 + 15 * u, c.Z)
		end,
		fov = 72,
	})

	-- 4. INTO THE MOUTH. Straight in along the party's bearing as the choir
	-- leans over the pit and the pit answers. Ends over the water, inside the
	-- collar ring, under the crooks - which is where she is about to be.
	kit.shot({
		t0 = T.shot[3],
		t1 = T.shot[4],
		pos = kit.line(camAt(N.ringR, home, 28), camAt(27, home, 13)),
		look = function(u)
			return Vector3.new(c.X, c.Y + 4 - 7 * u, c.Z)
		end,
		fov = 74,
	})

	-- 5. SHE RISES INTO THE LIGHT. A HARD CUT (blendIn 0) to the rim on her own
	-- lane, low and looking down into the pit, and then backing out and up as
	-- she fills the frame. The aim point is `mawMouth` walked between the two
	-- authored fractions, so the frame holds the jaw and not a guessed height -
	-- and it is the one shot in this cinematic with a boss in it.
	kit.shot({
		t0 = T.shot[4],
		t1 = T.shot[5],
		pos = kit.line(camAt(22, mawLane, 9), camAt(38, mawLane, 21)),
		look = kit.line(mawDown, mawUp),
		fov = 74,
		blendIn = 0,
	})

	-- 6. SHE SINKS, and the camera rises out of the pit with the chord, so the
	-- last thing the beat does is take her away.
	kit.shot({
		t0 = T.shot[5],
		t1 = kit.raiseAt,
		pos = kit.line(camAt(38, mawLane, 21), camAt(N.ringR, home, 26)),
		look = kit.line(mawUp, Vector3.new(c.X, c.Y + 2, c.Z)),
		fov = 72,
		blendIn = 1.0,
	})

	-- 7. THE RISE. Backing out to where the party is standing while she comes
	-- up for real, so the last thing that happens happens at the party's own
	-- distance.
	kit.shot({
		t0 = kit.raiseAt,
		t1 = T.shot[6],
		pos = kit.line(camAt(N.ringR, home, 26), camAt(N.partyR, home, 11)),
		look = Vector3.new(c.X, c.Y + 2, c.Z),
		fov = 72,
		blendIn = 0.9,
	})

	-- 8. THE CARD, and the seat the player is handed back. r 52 on the arrival
	-- bearing, eight and a half studs over the stone the party is standing on -
	-- roughly a third-person camera's own perch behind somebody on the drop-in
	-- ring - so the controller's 0.8 s blend has almost nothing to travel.
	kit.shot({
		t0 = T.shot[6],
		t1 = kit.duration,
		pos = kit.line(camAt(N.partyR, home, 11), camFloor(52, home, 8.5)),
		look = Vector3.new(c.X, c.Y + 6, c.Z),
		fov = 70,
	})
end
