--!nonstrict
-- NoctyssPath.luau
-- Where every piece of the Lantern Choir is, right now: ONE boss's shapes.
--
-- The generic half lives in ChainPose (walking a path by arc length and
-- handing out CFrames). This file is only the trench's geometry, and it
-- carries TWO shapes rather than Brinejaw's one, because this boss is two
-- things:
--
--   THE CHOIR - seven angler-lure stalks stood in the Choirfloor's sockets
--   (assets/arena_gen.py). Each is a chain: `stalkPoint(state, i, t)` with
--   t = 0 at the root in its collar and t = 1 at the hood. A stalk rises and
--   then CROOKS inward over the pit, so its lantern hangs free out over the
--   floor - an angler's illicium, not a lamppost. Every attack is this shape
--   leaning somewhere and coming back.
--
--   THE MAW - Noctyss herself, who is under the shelf and surfaces only in
--   the punish window. Not a chain at all: one rise, one hinge.
--
-- Server and client both require this file, and that is the point:
--   * the server needs the BULB positions (that is where a stalk's hitbox
--     lives - the light is the target) and analytic beam tests, so a
--     lightsweep costs it no geometry;
--   * the client walks each stalk every frame to draw it.
-- Sharing the math means the light you dodge and the light you see cannot
-- drift apart.
--
-- The numbers below ARE the pose in assets/boss_noctyss_staged.png - the
-- staged render is the review artifact for this table, and boss_gen.py
-- mirrors these constants so a render can never flatter a shape the fight
-- cannot hold. Coordinates are Roblox's (Y up), arena-local until
-- `state.center` is added.

local Workspace = game:GetService("Workspace")

local NoctyssPath = {}

local TAU = math.pi * 2

-- THE CLOCK BOTH SIDES ANIMATE ON.
--
-- Ambient motion moves the lantern, and the lantern is the hitbox: the server
-- stands each stalk's model at `bulbPosition` while the client draws the bulb
-- from the same function. If the two used their own `os.clock()` the light you
-- shoot and the light you see would sit up to a sway apart - a miss that looks
-- like a hit, forever, with nothing in either log to explain it. GetServerTimeNow
-- is synchronised on both sides, so they cannot drift.
function NoctyssPath.clock(): number
	return Workspace:GetServerTimeNow()
end

-- ---------------------------------------------------------------- the floor

-- The socket ring, mirroring arena_gen's GL_SOCKETS: seven collars at r 34,
-- the first at 12 degrees. A stalk grows out of collar `i` and nowhere else.
NoctyssPath.SOCKET_R = 34.0
NoctyssPath.SOCKETS = 7

-- The pit the maw comes up through (arena_gen GL_PIT_R), and the shelf's
-- walking height. The pit's water sits at -5 over a bed at -7.5.
NoctyssPath.PIT_R = 15.0
NoctyssPath.SHELF_Y = 1.5

-- The six gaps between the arena's shadow fins, in AUTHORED degrees (see
-- `authored` below). She surfaces facing one of these: a colossus that rose
-- facing a rock would be the arena fighting its own boss, and these lanes are
-- how the party moves.
NoctyssPath.LANES = { 56.0, 112.0, 168.0, 224.0, 284.0, 352.0 }

-- THE MIRROR. Blender's +Y exports as Roblox's -Z (export_yup, the pack
-- convention), so a bearing authored in arena_gen.py is its NEGATIVE in here.
-- Every authored angle in this file goes through `authored()` so the two
-- files can be read side by side without holding a mirror in your head - and
-- so the choir cannot end up growing out of bare stone 90 degrees from its
-- collars, which is the one mistake this whole module exists to prevent.
local function authored(degrees: number): number
	return -math.rad(degrees)
end

-- The bearing of socket `i` (1-based), in radians.
function NoctyssPath.socketAngle(index: number): number
	return authored(12.0 + (index - 1) * (360.0 / NoctyssPath.SOCKETS))
end

-- Socket `i`'s position, arena-local (the collar's mouth).
function NoctyssPath.socketPoint(index: number): Vector3
	local angle = NoctyssPath.socketAngle(index)
	return Vector3.new(math.cos(angle) * NoctyssPath.SOCKET_R, 2.2, math.sin(angle) * NoctyssPath.SOCKET_R)
end

-- THE SEVEN VEIN STRIPS, as the arena mesh actually lays them down.
--
-- `NoctyssArena_DecoVeins` is ONE merged object, so nothing on the client can
-- recover the seven crest curves from the imported mesh - and a light strip
-- whose positions nobody can compute is a light strip that never gets lit.
-- Until now NoctyssBodyController hung its 28 PointLights on STRAIGHT rim ->
-- socket lines, which the strips are not: they sway +-1.7 studs across the
-- ridge crests and they are SUNK in a gutter, so a light on the straight line
-- sat beside its own vein for most of its length and floated over the gutter
-- for the rest.
--
-- So arena_gen.py prints the crests, and this is that print, verbatim:
--
--   blender --background --python assets/arena_gen.py -- <tmp>.glb noctyss
--   -> "HANDOFF noctyss: Vein%d crest, roblox rel XYZ: ..." (5 marks per strip,
--      sampled at r 17, 20, 24, 27, 30 along the swaying crest)
--
-- ALREADY IN THE ROBLOX FRAME, and already mirrored: the generator prints
-- blender (x, y, z) as (x, z, -y), which is the same mirror `authored()` above
-- applies to a bearing - so these need no sign work here, and they are checked
-- against the sockets they belong to rather than trusted: strip `i`'s first
-- point lands just outside the pit lip (r ~17, PIT_R is 15) and its last on
-- socket `i`'s own bearing (measured: 1.4-2.6 degrees off `socketAngle(i)`, the
-- sway's own width) at r ~30, four studs short of the collar at SOCKET_R.
--
-- Arena-local, like everything else in this file: add `state.center`. Y is the
-- crest's own height on the mantle (the gutter floor plus the strip's 0.12
-- proud), so a light seated here wants a small lift and nothing more.
NoctyssPath.VEIN_POINTS = {
	{
		Vector3.new(16.5, 1.05, -4.0),
		Vector3.new(19.3, 2.51, -5.3),
		Vector3.new(23.1, 2.80, -6.6),
		Vector3.new(26.0, 3.05, -7.1),
		Vector3.new(29.1, 3.13, -7.3),
	},
	{
		Vector3.new(8.0, 0.96, -15.0),
		Vector3.new(10.0, 2.40, -17.3),
		Vector3.new(12.2, 2.83, -20.7),
		Vector3.new(13.5, 3.11, -23.4),
		Vector3.new(14.4, 3.10, -26.3),
	},
	{
		Vector3.new(-7.6, 1.05, -15.2),
		Vector3.new(-9.5, 2.50, -17.6),
		Vector3.new(-11.6, 2.79, -21.0),
		Vector3.new(-12.8, 2.89, -23.8),
		Vector3.new(-13.6, 3.16, -26.8),
	},
	{
		Vector3.new(-16.4, 1.03, -4.5),
		Vector3.new(-19.1, 2.48, -5.9),
		Vector3.new(-22.9, 2.71, -7.3),
		Vector3.new(-25.8, 2.90, -7.9),
		Vector3.new(-28.9, 3.26, -8.1),
	},
	{
		Vector3.new(-13.2, 0.97, 10.8),
		Vector3.new(-15.1, 2.42, 13.2),
		Vector3.new(-17.9, 2.67, 16.0),
		Vector3.new(-20.4, 2.98, 17.7),
		Vector3.new(-23.1, 3.30, 19.2),
	},
	{
		Vector3.new(-0.7, 0.59, 17.0),
		Vector3.new(-1.5, 2.02, 19.9),
		Vector3.new(-2.0, 2.70, 23.9),
		Vector3.new(-2.0, 3.05, 26.9),
		Vector3.new(-1.5, 3.25, 30.0),
	},
	{
		Vector3.new(13.4, 1.00, 10.4),
		Vector3.new(16.2, 2.45, 11.8),
		Vector3.new(19.6, 2.78, 13.9),
		Vector3.new(21.8, 3.06, 15.9),
		Vector3.new(23.8, 3.15, 18.2),
	},
}

-- ---------------------------------------------------------------- rest pose

NoctyssPath.REST = {
	HEIGHT = 33.0, -- root to the top of the rise
	CROOK = 11.0, -- studs the top arcs INWARD over the pit
	BOW = 2.6, -- a lazy S, alternating around the ring
	ROOT_Y = 2.2, -- the root sits down in the socket collar
}

-- How far a leaning stalk pushes its lantern toward what it is aiming at.
-- Big enough that a swept beam visibly comes FROM a stalk you can point at.
NoctyssPath.LEAN_REACH = 9.0

-- The beam a lit stalk paints on the floor: a wedge from the socket out past
-- the shelf's edge, so there is nowhere to simply stand outside the light.
NoctyssPath.BEAM_REACH = 74.0
NoctyssPath.BEAM_INNER = 5.0 -- directly under the crook is the one safe pocket
NoctyssPath.BEAM_HALF_ANGLE = math.rad(9.0)

-- The maw, in the punish window.
--
-- THE PIT IS HER MOUTH. The pose this replaces reared her out of the hole:
-- skull origin at Y 30.7 on a 26-degree pitch and a 44-degree gape, which put
-- the brow at 42 and the illicium's arch at 66 over a 30-stud hole - a head
-- that could not fit through the thing it was supposedly coming through,
-- parked in front of the camera for the whole punish window. The user's read
-- was the correct one: "it doesn't make sense that this random head comes out
-- of the hole."
--
-- So the head is laid INTO the pit instead, and every number below is solved
-- backwards from four facts that have to be true at once (all heights are
-- arena-local, the shelf at SHELF_Y = 1.5 and the solid ocean slab at 0):
--
--   * the tongue - the floor the party fights on - is a near-level lid over
--     the hole at 2.05 (throat) .. 2.82 (entrance), never under 1.6;
--   * the lower jaw's lip lands at 1.50, flush with the shelf's 1.5, so you
--     step off the stone into her mouth rather than climbing a ramp;
--   * the throat, and the gullet with it, sits over the pit's centre
--     (r -5.4, well inside the 15-stud disc), so what you are shooting at is
--     down the hole;
--   * the braincase is at the FAR rim (r -15.0) and low - crest 14.8 - so
--     nothing rears over the party's heads on their own side.
--
-- AND THE HEAD FITS THROUGH THE HOLE, which is what SCALE 2.0 buys (user:
-- "the head must fit inside the hole"). At 2.4 the skull's widest section was
-- 14.4 studs of half-width against the pit's 15 - she came up touching the rim
-- on both sides, so the hole read as a collar she was wedged in rather than as
-- a mouth she was rising out of, and the snout tip hung 18.5 studs past the
-- near rim. At 2.0 the half-width is 12.0 (3 studs of daylight each side) and
-- the overhang is 10. Every number in this table is re-solved at 2.0 and the
-- heights above are the verified ones, not the 2.4 pose's.
--
-- PITCH and GAPE are now a matched pair, 2 degrees apart. The jaw's tilt is
-- PITCH - GAPE, and that tilt IS the floor: at the old 26/44 the floor sloped
-- 18 degrees NOSE-DOWN, which is why it could only be flattened by hoisting
-- the whole skull 30 studs into the air. +2 degrees tips the room gently in
-- toward the throat, which is what a mouth does.
NoctyssPath.MAW = {
	PITCH = math.rad(21.0),
	GAPE = math.rad(19.0),
	-- HOW FAR HER THROAT SITS FORWARD OF THE PIT'S CENTRE, in studs, along the
	-- lane she surfaces on (+X is the snout, which the yaw points at the
	-- party). The head is 50 studs long and the hole is 30 across, so
	-- something has to overhang; this chooses WHICH end. At 0 the braincase
	-- hung 22 studs out over solid stone on the far side with a 12-stud gap
	-- under it - a head floating behind a hole. At 3.4 (7.1 when she was scaled
	-- 2.4) the crest lands exactly on the far rim - the braincase's top corner
	-- measures x = -15.03 against PIT_R 15.0 - the gullet sits inside the disc,
	-- and the overhang is the open jaw laid forward onto the shelf, which is
	-- the half you want lying on the floor the party walks in over.
	FORWARD = 3.4,
	-- Solved so the tongue's top face lands at 2.44 in the middle of the room
	-- (see mawMouth: the slab's top surface is the mouth CFrame + 0.6). The
	-- skull's origin is not the thing being placed - the floor is. It moved
	-- with SCALE: 24.2 held the same floor when she was 2.4.
	Y_UP = 20.4,
	-- Where she waits. -36 was solved for an ILLICIUM THAT NO LONGER EXISTS:
	-- the arch off her snout used to top out 28.5 studs over the origin at SCALE
	-- 2.0, and the whole of that depth was bought to hide the lit rod. The mesh
	-- pass cut the rod down, so the number was paying for something that is not
	-- in the file any more.
	--
	-- RE-DERIVED off the shipped mesh (assets/boss_noctyss.glb, read straight out
	-- of the glTF POSITION accessors - every vertex of Skull, SkullBone, Eyes,
	-- Gullet, Jaw, JawBone and Barbels, which is the whole head):
	--
	--   * the head is drawn in mawCFrame's frame, pitched by PITCH about Z, and
	--     FORWARD is applied BEFORE the pitch and is horizontal - so a point's
	--     height over the origin is SCALE * (x*sin(PITCH) + y*cos(PITCH)) and
	--     nothing else;
	--   * the highest such point is on Noctyss_SkullBone, authored (12.65, -0.43,
	--     -0.15): 4.13 authored units, = 8.3 STUDS at SCALE 2.0. The old illicium
	--     was 14.25 authored (28.5 studs); that arch is gone from the mesh.
	--
	-- So the dark beat needs 8.3 (head) + 1.4 (the drift heave the client rides
	-- her on while she is under - NoctyssBodyController DRIFT.HEAVE) + 2.0 of
	-- margin = 11.7 studs under the ocean slab at arena-local 0. -20 clears that
	-- and keeps clearing it for the STAND-IN blocks the fight draws until
	-- NoctyssPack is imported (boxes at each piece's bbox, whose top corner rides
	-- ~18 studs up) and for a shudder still ringing as she drops. Anything from
	-- -12 down is correct by the derivation alone; -36 was 16 further studs of
	-- travel bought for a rod that no longer exists.
	--
	-- No timing moves with this: the rise is a fixed 1.8s because CreatureService
	-- steps mawRise on the FRACTION at a fixed rate, not in studs. What changes is
	-- how far she travels in it - 56.4 studs before, 40.4 now.
	Y_DOWN = -20.0,
	-- THE ROW'S body.scale, and it must EQUAL Creatures.items.noctyss's (that
	-- row's comment points back here). The jaw floor, the gullet offset, the
	-- hinge and `insideMouth`'s box are all sized off it, and CreatureService's
	-- K.NOCTYSS_GULLET_REACH is solved from the tongue slab this number sizes -
	-- so it is never edited alone.
	SCALE = 2.0,
}

-- ---------------------------------------------------------------- motion
--
-- There is no rig anywhere in this game: "animation" here is time terms and
-- an impulse inside the shape function, evaluated identically on both sides.
-- Three layers, and every one of them is a handful of numbers:
--
--   SWAY + BREATH - the choir is never still. Phase per socket so seven
--   stalks never move as one block, and both scale by t so the hood travels
--   while the root stays put in its collar.
--
--   IMPULSE - a decaying whip down one stalk. Every recoil in the fight is
--   this: a shot landing on a lantern, an attack's snap, the shudder when a
--   stalk relights. One number, so no attack needs its own animation.
--
--   The maw gets the same two, at its own scale (SHUDDER).
NoctyssPath.SWAY = {
	PERIOD = 5.2, -- seconds for one drift
	AMPLITUDE = 2.4, -- studs at the hood
	BREATH_PERIOD = 3.4,
	BREATH = 0.9, -- studs of rise and fall
}

-- A flinch: a damped sine, so the stalk whips back and rings down rather than
-- easing politely. DURATION is when it stops being worth evaluating.
-- REACH is deliberately about a third of the lantern's own hitbox (~2.6
-- studs). A recoil is feedback, and feedback that throws the target off the
-- player's crosshair is a punishment for hitting it - which, in a fight whose
-- whole loop is sustained fire on one lantern, is exactly backwards. The
-- drawn bulb kicks; the thing you are shooting does not move at all
-- (`bulbPosition` is solid), and at this size the two never separate enough
-- to matter.
NoctyssPath.IMPULSE = {
	DECAY = 5.5,
	FREQ = 13.0,
	REACH = 0.9, -- studs at the hood, at strength 1
	DURATION = 0.6, -- it is inaudible past this; evaluating longer was waste
}

NoctyssPath.SHUDDER = { DECAY = 6.5, FREQ = 17.0, REACH = 1.5, DURATION = 1.0 }

-- The choir breathes in unison, and the TRUE lure breathes against it. That
-- half-cycle offset is the whole tell, so it is defined once, here, rather
-- than in whichever controller happens to draw a bulb.
NoctyssPath.PULSE_PERIOD = 2.6
NoctyssPath.TRUE_LURE_OFFSET = 0.5 -- in cycles: dead against the choir

-- THE SHADOW FINS ARE THE ARENA'S ONE ANSWER TO THE LIGHT, and until now
-- they were decoration: `beamHits` was a bearing and two distances, with no
-- occlusion of any kind, so the six knife-edge blades the Choirfloor is built
-- around stopped nothing. The whole stated trade - stand in cover and lose
-- your view of the arena, or see and be seen - had no code behind it.
--
-- One raycast from the lantern to the player, against the arena's own
-- geometry only. It fails SAFE: if the ray is blocked the beam does not
-- burn you, and the worst case is light drawn across a player who takes
-- nothing, rather than damage with no light to explain it.
local shadowParams: RaycastParams? = nil

local function beamBlocked(from: Vector3, to: Vector3): boolean
	if not shadowParams then
		local arenas = Workspace:FindFirstChild("BossArenas")
		if not arenas then
			return false
		end
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { arenas }
		params.IgnoreWater = true
		shadowParams = params
	end
	local span = to - from
	if span.Magnitude < 1e-3 then
		return false
	end
	return Workspace:Raycast(from, span, shadowParams) ~= nil
end

local function smoothstep(x: number): number
	x = math.clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end

-- ------------------------------------------------------------- the telegraphs
--
-- ONE LANGUAGE, DECLARED ONCE, FOR EVERY MARK THIS FIGHT DRAWS. It lives here
-- rather than in whichever controller happens to draw a shape because the
-- fight was, measurably, four telegraph languages layered on one floor: six
-- tell colours in NoctyssBodyController, two more in CreatureEventController's
-- skin table, four of the eight within a hue step of the lanterns themselves,
-- and every one of them peaking below the Transparency at which Roblox Neon
-- saturates to white. The colour code was only legible while the attack was
-- still far away.
--
-- So: THREE colours, and nothing else in this fight may declare a fourth.
--
--   LIGHT - her LIGHT is coming (lightsweep, strobewave, lurepull). Gold,
--           because the arena is already made of gold light and "the lamps
--           are about to do something" needs no learning.
--   LIMB  - a LIMB is coming (slam, scythe, jab, the herd V, the portcullis
--           bars). Violet: the one hue that holds 3:1 against both the black
--           floor and the gold lights, and the one hue that is never a lantern.
--   HEAD  - her MOUTH is coming (the snap rim, the jaw). Bone, reserved for
--           the two shapes in the fight that cannot be out-walked.
--
-- A BAR IS NOT A NEW COLOUR. The portcullis is violet like every other limb;
-- what says "door" is the SHAPE - two parallel bars plus a drawn safe
-- centreline. Shape is the verb, colour is only the source.
NoctyssPath.TELL = {
	LIGHT = Color3.fromRGB(255, 206, 92),
	LIMB = Color3.fromRGB(176, 96, 255),
	HEAD = Color3.fromRGB(236, 232, 214),

	-- THE RAMP, in Transparency. Brightness is time-to-impact and nothing
	-- else: a mark that is merely on says "something is happening", a mark
	-- that is accelerating says "this lands in half a second", and in a room
	-- with four other lit shapes the second is the only one worth drawing.
	FLOOR_T = 0.92, -- when a tell first appears
	LEAD_T = 0.42, -- ...and at the last frame before impact
	FLASH_T = 0.05, -- the impact frame
	FLASH = 0.08, -- seconds the flash is held
	LIVE_T = 0.30, -- while the hitbox is STILL live after the flash
	FADE = 0.30, -- seconds from LIVE_T to invisible, and never longer
	FILL_T = 0.82, -- the interior, during the lead-in
	FILL_LIVE = 0.62, -- the interior, while live
	EDGE_W = 0.90, -- studs of edge band, centred on the tested boundary
	WHITE_MIX = 0.60, -- how far the colour lerps to white on the flash frame
	-- NEON WHITEOUT. Roblox Neon saturates toward white as Transparency falls;
	-- below about 0.25 every colour in the table above renders as the same
	-- blown-out paddle. Nothing but the one-frame flash may go under this, and
	-- that is why LEAD_T and LIVE_T are where they are.
	NEON_MIN = 0.25,
}

-- WHERE TO LOOK FOR THE FLOOR, and how far off it a mark sits.
--
-- The Choirfloor is not a plane: the socket collars stand on raised mounds
-- (authored collar top at arena-local 4.6, against a shelf at 1.5), so a mark
-- laid on a flat SHELF_Y spends its first eight studs inside the rock - which
-- is exactly the end of a slam stripe the player most needs to see, because it
-- is the end the limb comes from. CreatureEventController learned this for the
-- beam rungs and carries K.BEAM_PROBE_Y = 3.0; this is the same fix, shared,
-- and the probe window is opened upward so it clears a collar rather than
-- starting under one.
NoctyssPath.PROBE_Y = 3.0
NoctyssPath.PROBE_UP = 3.0 -- studs above PROBE_Y the cast starts
NoctyssPath.PROBE_DOWN = 10.0 -- and how far down it looks
NoctyssPath.MARK_LIFT = 0.09 -- studs over whatever it found, so nothing z-fights

local WHITE = Color3.new(1, 1, 1)

-- THE ONE BRIGHTNESS FUNCTION. Both client files call this for every mark they
-- draw, and nothing else in this fight decides a telegraph's alpha.
--
--   u     - 0..1 through the LEAD-IN (the windup), 1 once the lead-in is over.
--   live  - is the hitbox live THIS FRAME. Not a phase name: the slam's damage
--           deliberately outlasts its travel by SLAM.LIVE - SLAM.STRIKE, and a
--           mark that faded on the phase boundary was fading over players it
--           was still killing.
--   since - seconds since the hitbox CHANGED STATE: since it went live while
--           `live` is true, since it went dead once it is false. nil (or
--           negative) means it has not been live yet, i.e. this is the lead-in.
--   color - the source colour from the table above. Defaults to LIMB.
--
-- Returns (edge Transparency, colour, fill Transparency) - one call, both
-- parts of every mark. `NoctyssPath.tellPhase` hands you the first three
-- arguments off a descriptor, so no caller has to spell the windows twice.
function NoctyssPath.tellRamp(u: number, live: boolean?, since: number?, color: Color3?): (number, Color3, number)
	local tell = NoctyssPath.TELL
	local base = color or tell.LIMB
	if live then
		-- THE FLASH IS THE HITBOX GOING LIVE, and it is the only thing in this
		-- fight allowed under NEON_MIN - one frame of deliberate whiteout, on
		-- the frame it stops being a warning and starts being damage.
		if (since or 0) < tell.FLASH then
			return tell.FLASH_T, base:Lerp(WHITE, tell.WHITE_MIX), tell.FLASH_T
		end
		return tell.LIVE_T, base, tell.FILL_LIVE
	end
	if since and since >= 0 then
		-- Dead. The fade starts on the frame damage stops and is over in FADE;
		-- a footprint that outlived its own hitbox taught the player to dodge
		-- a shape that could not hurt them.
		local f = math.clamp(since / tell.FADE, 0, 1)
		return tell.LIVE_T + (1 - tell.LIVE_T) * f, base, tell.FILL_LIVE + (1 - tell.FILL_LIVE) * f
	end
	-- The lead-in. ACCELERATING, not linear: a linear ramp reads as "something
	-- is on", a squared one reads as a countdown.
	local e = math.clamp(u, 0, 1)
	local alpha = tell.FLOOR_T - (tell.FLOOR_T - tell.LEAD_T) * e * e
	return math.max(alpha, tell.NEON_MIN), base, tell.FILL_T
end

-- THE GROUND UNDER A MARK, probed, plus MARK_LIFT - arena geometry only.
--
-- Include-filtered on BossArenas exactly as `beamBlocked` is, which is what
-- makes it safe to call from a draw loop: it cannot hit a player, a creature
-- or a mark this same frame laid down, so the answer is the stone and nothing
-- else. Fails safe to the flat shelf, which is where every mark used to be.
--
-- Only the client calls this today (the server tests flat capsules and discs
-- and does not care what height they are drawn at), but it lives here so the
-- two client files probe one way and not two.
local probeParams: RaycastParams? = nil

function NoctyssPath.markFloor(state, x: number, z: number): Vector3
	local flat = state.center.Y + NoctyssPath.SHELF_Y
	if not probeParams then
		local arenas = Workspace:FindFirstChild("BossArenas")
		if not arenas then
			return Vector3.new(x, flat + NoctyssPath.MARK_LIFT, z)
		end
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { arenas }
		params.IgnoreWater = true
		probeParams = params
	end
	local from = Vector3.new(x, state.center.Y + NoctyssPath.PROBE_Y + NoctyssPath.PROBE_UP, z)
	local hit = Workspace:Raycast(from, Vector3.new(0, -NoctyssPath.PROBE_DOWN, 0), probeParams)
	return Vector3.new(x, (if hit then hit.Position.Y else flat) + NoctyssPath.MARK_LIFT, z)
end

-- A fresh pose state. One entry per socket, plus the maw's two numbers.
function NoctyssPath.newState(center: Vector3)
	local stalks = {}
	for i = 1, NoctyssPath.SOCKETS do
		stalks[i] = {
			alive = true,
			lean = 0, -- 0 at rest, 1 fully leaning into `beamAngle`
			beamAngle = NoctyssPath.socketAngle(i), -- the bearing its light is on
			douse = 0, -- 0 lit, 1 dark
			fall = 0, -- 0 standing, 1 collapsed (death)
			-- 0 a point down in the collar, 1 fully out of it. SHARED, and the
			-- server writes it: see `NoctyssPath.setGrow`.
			grow = 1,
			impulse = 0, -- strength of the current flinch
			impulseAt = -math.huge, -- when it landed, on NoctyssPath.clock()
			impulseDir = Vector3.new(1, 0, 0), -- which way it whips
		}
	end
	return {
		center = center,
		stalks = stalks,
		trueLure = 1, -- which socket carries the real lure this cycle
		-- socket -> the attack descriptor that socket's limb is committed to
		-- (see "the tentacles attack"). Retired by `attackFor`, so an entry in
		-- here is always a swing still in progress.
		attacks = {},
		mawRise = 0, -- 0 under the shelf, 1 fully up through the pit
		mawGape = 0, -- 0 shut, 1 open
		mawYaw = authored(NoctyssPath.LANES[1]),
		shudder = 0,
		shudderAt = -math.huge,
		time = 0,
	}
end

-- ---------------------------------------------------------------- growing
--
-- GROW IS A SHARED TERM, and that is the whole of the fix.
--
-- A stalk that has not finished coming out of its socket is drawn as the shape
-- it will have, scaled about the collar it grows from - height, crook, hood
-- and lantern together - so the eye RISES OUT of the stone instead of the
-- choir popping into existence fully formed after every punish window.
--
-- It used to live in NoctyssBodyController alone, gated behind an attribute
-- only the intro cutscene ever wrote, with a comment explaining that the
-- server must never write it: the hitbox is `bulbPosition`, which knew nothing
-- about Grow, so a live-fight stalk drawn at grow < 1 would have been a
-- lantern you can see low in its collar and can only shoot thirty studs above
-- it. That reasoning was right about the danger and wrong about the cure - the
-- answer is not to keep the growth off the server, it is to put the scale
-- INSIDE the one curve both sides evaluate, which is what this is. `stalkCurve`
-- and `bulbPosition` now scale identically, so the drawn eye and the tested
-- one are the same point at every value of grow.
--
--   * the attribute is still called `Grow` (number, 0..1, absent means 1) and
--     the client still EASES toward it (NoctyssBodyController EASE.grow);
--   * the server writes it during a regrow and is expected to gate targeting
--     and damage while it is under 1 - a stalk half out of its collar is not a
--     lantern anyone should be able to trade with;
--   * the cutscene lane's stand-in stalks may still drive it client-only, and
--     nothing about that changes: they have no server behind them, and a
--     stand-in nobody shoots cannot desync from a hitbox nobody tests.
--
-- HOW FAR OUT OF ITS COLLAR STALK `index` IS, 0..1. Absent means 1, so every
-- caller that has never heard of a regrow pays one compare and gets the shape
-- it has always had.
function NoctyssPath.growOf(state, index: number): number
	local stalks = state.stalks
	local stalk = stalks and stalks[index]
	local grow = stalk and stalk.grow
	return if grow then math.clamp(grow, 0, 1) else 1
end

-- Set it. The server ramps this over its regrow; the client eases its own copy
-- toward the replicated attribute and calls the same function, so there is one
-- place the number is clamped and one shape it can produce.
function NoctyssPath.setGrow(state, index: number, value: number)
	local stalks = state.stalks
	local stalk = stalks and stalks[index]
	if stalk then
		stalk.grow = math.clamp(value or 1, 0, 1)
	end
end

-- ---------------------------------------------------------------- the choir

-- One stalk, root (t = 0) to hood (t = 1), arena-local.
--
-- A quadratic Bezier: straight up, then arcing INWARD over the pit so the
-- last tangent is near-horizontal and the hood overhangs. A lean rotates the
-- crook's end toward `beamAngle` and pushes it out; a fall drops the whole
-- curve to the stone and keeps only the root standing.
-- `drawing` opts INTO the flinch. Everything that decides damage - the bulb
-- the server stands a hitbox on, the beam's apex, the hit tests - passes
-- false, so a recoil can never move the thing a player is shooting at.
--
-- That was not a style choice: the flinch reaches 3.4 studs (5.4 on a killing
-- blow) against a lantern hitbox of about 2.6, and it re-arms on every hit. A
-- flinch inside the shared curve meant that landing a shot knocked the target
-- off your crosshair, for the next second and a half, in a fight whose entire
-- loop is sustained fire on one lantern. The recoil has to be a lie told to
-- the eye only.
-- FORWARD-DECLARED, and assigned in "the tentacles attack" below. An attack
-- pose is a rotation of the whole curve about its own root, so it has to be
-- applied INSIDE `stalkCurve` - that is the one function both sides evaluate,
-- and a pose bolted on outside it would be a pose the hit tests cannot see.
-- The pose itself is derived from the REST curve (`noAttack`), so this is a
-- one-level recursion and never more.
local attackPose

local function stalkCurve(state, index: number, t: number, drawing: boolean?, noAttack: boolean?): Vector3
	local stalk = state.stalks[index]
	local angle = NoctyssPath.socketAngle(index)
	local inward = Vector3.new(-math.cos(angle), 0, -math.sin(angle))
	local lateral = Vector3.new(-inward.Z, 0, inward.X)
	local root = Vector3.new(
		math.cos(angle) * NoctyssPath.SOCKET_R,
		NoctyssPath.REST.ROOT_Y,
		math.sin(angle) * NoctyssPath.SOCKET_R
	)

	local rest = NoctyssPath.REST
	local fall = smoothstep(stalk.fall or 0)
	local height = rest.HEIGHT * (1 - 0.82 * fall)
	local bow = if index % 2 == 0 then rest.BOW else -rest.BOW

	-- AMBIENT. A dead stalk does not breathe, and a leaning one is holding
	-- itself still to aim - so both fade the drift out rather than fighting
	-- the pose the fight put it in.
	local clock = state.time or 0
	local phase = index * 1.7
	-- A LIMB THAT IS SWINGING DOES NOT ALSO DRIFT. `noAttack` is the pose
	-- derivation asking for the rest shape, so it must never see this.
	local attack = if noAttack then nil else NoctyssPath.attackFor(state, index, clock)
	-- ...and `noAttack` kills it too, which is not a nicety. `noAttack` is the
	-- pose solver asking what shape it is about to swing, and it is only ever
	-- asked while an attack is on - so if it saw the drift and the swung curve
	-- did not, the solver would be aiming a shape that is not the shape being
	-- posed, and every strike would land the sway's amplitude off its own
	-- telegraph. (Measured, before this line: 3.5 studs, permanently, on a
	-- 4-stud eye - the solver converged perfectly onto the wrong stalk.)
	local calm = (1 - fall) * (1 - 0.7 * smoothstep(stalk.lean or 0)) * (if attack or noAttack then 0 else 1)
	local sway = math.sin(clock / NoctyssPath.SWAY.PERIOD * TAU + phase) * NoctyssPath.SWAY.AMPLITUDE * calm
	local breath = math.sin(clock / NoctyssPath.SWAY.BREATH_PERIOD * TAU + phase * 0.6) * NoctyssPath.SWAY.BREATH * calm

	-- FLINCH. A damped sine along whatever direction the hit came from,
	-- riding on top of everything else, so being shot reads even mid-attack.
	--
	-- ...AND NOT WHILE A POSE OWNS THE SHAPE. `kick` is applied to the rest
	-- curve and is then ROTATED AND STRETCHED by the attack pose (up to
	-- STRETCH_MAX), which put the drawn eye about 1.4 studs off the tested one
	-- in a direction rotated into the strike axis - on the one attack whose
	-- whole promise is that the limb lands on its own stripe. A hit landing on
	-- a swinging limb is worth feedback, but not feedback that moves the thing
	-- the shooter is tracking: the client answers it with a lantern stutter and
	-- a flash at the bulb instead (NoctyssBodyController, `onCreatureHit`).
	local kick = 0
	local age = clock - (stalk.impulseAt or -math.huge)
	if drawing and not attack and age >= 0 and age < NoctyssPath.IMPULSE.DURATION then
		kick = (stalk.impulse or 0)
			* math.exp(-age * NoctyssPath.IMPULSE.DECAY)
			* math.sin(age * NoctyssPath.IMPULSE.FREQ)
			* NoctyssPath.IMPULSE.REACH
	end

	-- Where the crook points. At rest it falls inward over the pit; leaning
	-- swings it onto the bearing the light is sweeping, and a collapse throws
	-- it outward and flat.
	local restTip = inward * rest.CROOK + lateral * (bow * 0.6)
	local aim = Vector3.new(math.cos(stalk.beamAngle or angle), 0, math.sin(stalk.beamAngle or angle))
	local leanTip = aim * (rest.CROOK + NoctyssPath.LEAN_REACH)
	local lean = smoothstep(stalk.lean or 0)
	local tip = restTip:Lerp(leanTip, lean) + aim * (28.0 * fall)

	local p0 = root
	local p1 = root + Vector3.new(0, height + breath * 0.4, 0) + lateral * (bow + sway * 0.35)
	-- 6.5, not 26: at fall = 1 the curve's own height has already collapsed to
	-- ~5.9, so a 26-stud drop finished the hood twenty studs INSIDE the shelf
	-- and buried every fallen stalk - hood, cage, dead lantern and all - which
	-- is the entire thing the wreck exists to show.
	local p2 = root
		+ Vector3.new(0, height * 0.93 - 6.5 * fall + breath, 0)
		+ tip
		+ lateral * sway
		+ (stalk.impulseDir or Vector3.new(1, 0, 0)) * kick

	local inv = 1 - t
	local point = p0 * (inv * inv) + p1 * (2 * inv * t) + p2 * (t * t)

	-- THE ATTACK POSE, LAST. Everything above is the stalk at rest doing what
	-- it does; an attack takes that whole shape and swings it about the root
	-- it is welded into, which is what a limb with no joints in it can do.
	-- Solid AND drawn take this branch - a slam that moved only the drawing
	-- would be a limb that visibly hits you and cannot.
	if attack then
		local rot, stretch = attackPose(state, index, attack, t)
		if rot then
			point = root + rot:VectorToWorldSpace((point - root) * stretch)
			-- NOTHING REACHES THROUGH THE STONE. A stalk lying flat along a
			-- slam line is an arc, and the middle of that arc dips: without
			-- this the party watches half a limb swim through the shelf.
			-- Applied on both sides, so the clamp cannot be a drawing-only lie.
			--
			-- AND IT LETS GO BEFORE THE HOOD. The pose solver puts the LANTERN
			-- on the latched point, and it derives the lantern from the curve's
			-- last two samples - so a clamp still biting at t = 0.98 lifts the
			-- tip, tilts the tangent it is measured from, and walks the bulb
			-- off the target the whole attack was aimed at (6.6 studs, on a
			-- far low aim, with the eye ending up UNDER the floor it was told
			-- to hit). Faded out across the last quarter, so it is gone by the
			-- time the tangent is sampled and the solve stays exact. The cost
			-- is a hood that tucks about a stud into the stone at full stretch,
			-- under a limb that is at that moment slamming into it.
			local guard = 1 - smoothstep((t - 0.75) / 0.2)
			if guard > 0 then
				local lift = NoctyssPath.SHELF_Y + 0.4 - point.Y
				if lift > 0 then
					point += Vector3.new(0, lift * guard, 0)
				end
			end
		end
	end

	-- THE REGROW SCALE, LAST AND ON BOTH SIDES. One uniform scale about the
	-- root, so a half-grown stalk is a stub arcing over its own collar rather
	-- than a full-sized stalk sunk into the floor - and, because it is applied
	-- here rather than in a renderer, the shape the server tests shrinks with
	-- it. At 0 every point collapses onto the root at REST.ROOT_Y = 2.2, which
	-- is 2.4 studs UNDER the collar's top (arena_gen's socket HANDOFF: collar
	-- top z 4.6), so the eye is inside the collar mesh and not hovering in its
	-- mouth. See "growing", above.
	local grow = NoctyssPath.growOf(state, index)
	if grow < 1 then
		point = root + (point - root) * grow
	end
	return point
end

-- Arena-local -> world.
-- The DRAWN point: carries the flinch. Only renderers should call this.
function NoctyssPath.stalkPoint(state, index: number, t: number): Vector3
	return state.center + stalkCurve(state, index, math.clamp(t, 0, 1), true)
end

-- The AUTHORITATIVE point: no flinch, so hitboxes hold still while the drawn
-- body recoils around them.
function NoctyssPath.stalkPointSolid(state, index: number, t: number): Vector3
	return state.center + stalkCurve(state, index, math.clamp(t, 0, 1), false)
end

-- The curve's direction at `t`, pointing UP-stalk toward the hood - the
-- pack's +X convention (assets/boss_gen.py: t = 0 at the root, so this is the
-- opposite sign to Brinejaw's head-first chain).
function NoctyssPath.stalkTangent(state, index: number, t: number, drawing: boolean?): Vector3
	local step = 0.02
	local a = stalkCurve(state, index, math.clamp(t - step, 0, 1), drawing)
	local b = stalkCurve(state, index, math.clamp(t + step, 0, 1), drawing)
	local delta = b - a
	if delta.Magnitude < 1e-4 then
		return Vector3.new(0, 1, 0)
	end
	return delta.Unit
end

-- WHERE THE LANTERN IS. Three systems need this exact point and must agree:
-- the client parents the bulb's light to it, the server stands the stalk's
-- hitbox on it (the light IS the target - see the choir_stalk row), and the
-- fight's "shoot the true lure" check measures against it.
--
-- The hood is authored with its neck joint at the curve's end and the bulb
-- slung under its lip, so the bulb is the hood's own offset carried into
-- world space: forward along the tangent, and down.
function NoctyssPath.bulbPosition(state, index: number): Vector3
	-- Solid on purpose: this one point is the server's hitbox, the frozen
	-- beam apex and the client's light anchor, and a recoiling hitbox is a
	-- fight that punishes you for hitting it.
	local at = NoctyssPath.stalkPointSolid(state, index, 1)
	local forward = NoctyssPath.stalkTangent(state, index, 1, false)
	local up = if math.abs(forward.Y) > 0.99 then Vector3.new(0, 0, 1) else Vector3.new(0, 1, 0)
	local right = forward:Cross(up)
	if right.Magnitude < 1e-4 then
		right = Vector3.new(1, 0, 0)
	end
	local realUp = right.Unit:Cross(forward).Unit
	-- boss_gen NC_BULB scaled by the hood's 0.86: (6.6, 0, -3.2) in hood space.
	--
	-- ...and by `grow` on top of that. `stalkCurve` scales the CURVE about the
	-- root; the hood's offset rides on the curve's tangent and does not scale
	-- with it, so without this the lantern of a stalk at grow = 0 would stand
	-- 5.7 studs out of a socket containing nothing. Both sides run this line,
	-- which is the only reason the server may write Grow at all.
	local grow = NoctyssPath.growOf(state, index)
	return at + forward * (6.6 * 0.86 * grow) + realUp * (-3.2 * 0.86 * grow)
end

-- Is `position` standing in stalk `index`'s beam? A wedge from the socket,
-- out past the shelf's edge, with one safe pocket directly underneath.
--
-- Analytic on purpose: the beam is a bearing and a half-angle, so testing a
-- player is three cheap numbers, and the server never builds any geometry to
-- run the fight's signature attack.
-- `apex` is the lantern's position AT THE MOMENT THE SWEEP FIRED, and callers
-- are expected to pass it. It matters that this is a snapshot: a leaning stalk
-- carries its lantern along its own bearing, so a live apex travels a 20-stud
-- radius arc during the sweep - a hitbox whose origin moves 39 studs mid-attack
-- is not one a player can read, and it would no longer be the wedge the client
-- drew from the position the event carried.
function NoctyssPath.beamHits(state, index: number, position: Vector3, pad: number?, apex: Vector3?): boolean
	local stalk = state.stalks[index]
	if not stalk or not stalk.alive or (stalk.douse or 0) > 0.5 then
		return false
	end
	-- THE WEDGE STARTS AT THE LANTERN, not at the socket in the floor.
	--
	-- The stalk's crook carries its light ~11 studs inward of its collar, and
	-- further when it leans, so a wedge hinged on the socket would sit up to a
	-- dozen studs off the light the player can actually see - and at a 9 degree
	-- half-angle that is metres of "I was standing in the dark and still took
	-- it" at the far end. The apex has to be the thing that emits.
	local bulb = apex or NoctyssPath.bulbPosition(state, index)
	local to = Vector3.new(position.X - bulb.X, 0, position.Z - bulb.Z)
	local distance = to.Magnitude
	if distance < NoctyssPath.BEAM_INNER or distance > NoctyssPath.BEAM_REACH then
		return false
	end
	local bearing = math.atan2(to.Z, to.X)
	local delta = math.abs((bearing - stalk.beamAngle + math.pi) % TAU - math.pi)
	-- The wedge widens with distance in world terms already; `pad` lets a
	-- caller forgive a stud or two of body width.
	local half = NoctyssPath.BEAM_HALF_ANGLE + (pad or 0) / math.max(distance, 1)
	if delta > half then
		return false
	end
	-- Inside the wedge - now, can the light actually SEE you? Tested last
	-- because it is the only expensive line in the function, and the cheap
	-- bearing and distance tests reject almost everyone first.
	return not beamBlocked(bulb, position + Vector3.new(0, 2, 0))
end

-- FLINCH A STALK. `strength` is roughly studs of whip at the hood (1 is a
-- solid hit); `direction` is which way it goes, normally the shot's travel.
-- Called from either side: the server for scripted recoils, the client for
-- hit reactions off the shot it just watched land. Both read the same clock,
-- so neither has to tell the other.
function NoctyssPath.flinch(state, index: number, strength: number, direction: Vector3?)
	local stalk = state.stalks[index]
	if not stalk or not stalk.alive then
		return
	end
	local dir = direction
	if not dir or dir.Magnitude < 1e-4 then
		dir = Vector3.new(math.cos(stalk.beamAngle or 0), 0, math.sin(stalk.beamAngle or 0))
	else
		dir = Vector3.new(dir.X, 0, dir.Z)
		dir = if dir.Magnitude > 1e-4 then dir.Unit else Vector3.new(1, 0, 0)
	end
	-- A fresh hit takes over rather than stacking: two flinches summed just
	-- cancel into mush at these frequencies.
	stalk.impulse = math.clamp(strength, 0, 3)
	stalk.impulseAt = NoctyssPath.clock()
	stalk.impulseDir = dir
end

-- The same, for the maw: the whole head shudders when the gullet is hit.
function NoctyssPath.shudder(state, strength: number)
	state.shudder = math.clamp(strength, 0, 3)
	state.shudderAt = NoctyssPath.clock()
end

-- How far the maw is jarred right now, in studs - applied by whoever draws it.
function NoctyssPath.shudderOffset(state): number
	local age = (state.time or 0) - (state.shudderAt or -math.huge)
	if age < 0 or age >= NoctyssPath.SHUDDER.DURATION then
		return 0
	end
	return (state.shudder or 0)
		* math.exp(-age * NoctyssPath.SHUDDER.DECAY)
		* math.sin(age * NoctyssPath.SHUDDER.FREQ)
		* NoctyssPath.SHUDDER.REACH
end

-- The choir's breathing, 0..1. The true lure runs half a cycle out of step -
-- the fight's whole read, and the reason this lives in shared code.
function NoctyssPath.pulse(state, index: number, clock: number): number
	local offset = if index == state.trueLure then NoctyssPath.TRUE_LURE_OFFSET else 0
	return 0.5 + 0.5 * math.sin((clock / NoctyssPath.PULSE_PERIOD + offset) * TAU)
end

-- ------------------------------------------------- the tentacles attack
--
-- Until now the choir was a light show: every move in Noctyss's book spawned
-- a telegraph somewhere on the stone and the seven stalks stood there being
-- scenery with hitboxes. The limbs themselves now swing, and this section is
-- the whole of it: three attacks, each a pure function of
--
--     (pose state, socket index, ONE descriptor, the shared clock)
--
-- so the server's hitbox and the client's drawing are the same arithmetic run
-- twice - the rule this file exists to keep. No per-side integration, no
-- "where was the limb last frame": ask for a time, get a shape.
--
-- ------------------------------------------------------------ THE DESCRIPTOR
--
-- ONE table shape covers all three. The server builds it, hands it to
-- `NoctyssPath.setAttack`, and fires the same table down `Remotes.ChoirAttack`;
-- the client calls `setAttack` with what it receives. Nothing else is
-- replicated for an attack, ever - not a frame, not a progress number.
--
--   {
--     kind   = "stalkslam" | "gloomscythe" | "feelerstrike" | "portcullis",
--     index  = 1..7,        -- which socket's stalk is swinging
--     target = Vector3,     -- WORLD, LATCHED at the windup. Never re-aimed.
--     start  = number,      -- NoctyssPath.clock() at the windup's first frame
--
--     -- gloomscythe only; `setAttack` fills all four if they are absent:
--     from   = number,      -- world bearing (radians) the sweep starts at
--     dir    = 1 | -1,      -- which way round the socket it travels
--     arc    = number,      -- radians swept (default SCYTHE.ARC)
--     reach  = number,      -- studs from the socket the bulb drags at
--   }
--
-- TWO OPTIONAL FIELDS THE SERVER FILLS FOR THE MOVES THAT ARE MADE OF SLAMS.
-- Both are plain table fields on the descriptor that already crosses the wire,
-- so neither costs a remote and neither is replicated per frame:
--
--     hold = number,        -- EXTRA seconds the landed pose is pinned before
--                           -- the peel front starts, on top of SLAM.HOLD.
--                           -- `herdingsnap`'s two bars pass SNAP.RISE (1.0):
--                           -- a funnel whose walls are visibly peeling off the
--                           -- stone while the mouth is still rising unmakes
--                           -- itself at the exact moment it is needed. A
--                           -- portcullis bar passes 0 - the door's beat is the
--                           -- jaw, not a rise. Read by `attackKeep`.
--
--     pair = boolean,       -- this descriptor is one of a MATCHED PAIR thrown
--                           -- on the same frame (the herd V, the portcullis).
--                           -- `true` on the one that speaks, `false` on the
--                           -- other; nil on every ordinary attack, which
--                           -- speaks. Two bodies firing two `slamImpact`s on
--                           -- one frame is a doubled, phase-cancelled crack
--                           -- that sounds smaller than one bar, and nothing in
--                           -- it says the two stripes are ONE move. The client
--                           -- sounds the `true` one only.
--                           -- CONVENTION: the +lateral bar is the voice, so it
--                           -- carries `pair = true` and its partner carries
--                           -- `pair = false`. `false` and not nil, or the
--                           -- silent half is indistinguishable from a slam.
--
-- AIMING LATCHES AT THE WINDUP. `target` is read once, when the telegraph is
-- drawn, and every later frame - the strike, the hit test, the floor stripe -
-- reads that same number. A limb that tracked would make its own telegraph a
-- lie, which in a pitch-black arena is the only thing a player has.
--
-- ------------------------------------------------------------------ THE POSE
--
-- A stalk has no joints. What it CAN do is swing the shape it already is about
-- the root welded into its collar, and lengthen or shorten as it goes - so an
-- attack pose is exactly two numbers-worth of thing: a rotation and a uniform
-- stretch, both applied about the root inside `stalkCurve`. That is why a slam
-- moves the hitbox honestly: the solid curve takes the same branch the drawn
-- one does.
--
-- The rotation is solved, not authored: `aimFrame` finds the rotation and the
-- stretch that put THE BULB exactly on the point being aimed at. So "the bulb
-- smacks the latched point" is true by construction rather than by tuning, and
-- `bulbPosition` - the thing shots are tested against - lands there too.

-- The lantern is an EYE now, and this is its radius: the drawn sphere and the
-- creature row's hit sphere are both this number (see the choir_stalk row's
-- scale, which is solved backwards from it). Anything that aims at a stalk's
-- bulb - a slam's target height, the scythe's drag height - measures from here,
-- so an eye resting on the stone has its CENTRE one radius up.
NoctyssPath.EYE_R = 4.0

-- The lantern's offset from the end of the curve, in the hood's own frame -
-- the same two numbers `bulbPosition` carries (boss_gen NC_BULB x the hood's
-- 0.86). Named here because the pose solver needs them as a vector rather than
-- as a place to stand a part.
local BULB_FORWARD = 6.6 * 0.86
local BULB_DOWN = -3.2 * 0.86

-- THE SLAM. The signature: the lantern goes OUT, the limb rears, and then the
-- whole stalk comes down along a line drawn on the floor.
--
-- WINDUP is long (1.2s) because the tell is a light going out, and a light
-- going out needs a beat to be noticed in a room lit by seven of them. STRIKE
-- is short and accelerating - a crack, not a fall. LIVE outlasts STRIKE so the
-- limb is dangerous while it lies there, not only during the 15 frames it
-- travels. RECOVER is the longest phase in the fight: this is the window the
-- attack is paid for with, and it peels up base-first (see `attackKeep`).
NoctyssPath.SLAM = {
	WINDUP = 1.2,
	STRIKE = 0.25,
	LIVE = 0.4, -- damage from the strike's first frame, measured from WINDUP
	RECOVER = 1.6,
	REAR = math.rad(30), -- how far back off the line it rocks first
	RISE = 0.12, -- and how much it stretches doing it
	RADIUS = 7.0, -- the down-line capsule's radius; the floor stripe's half-width
	PEEL = 0.55, -- width of the release wave travelling root -> hood
	-- THE HANG, as a fraction of WINDUP. The rear used to be a smoothstep over
	-- the whole 1.2s, which is a DRIFT: the limb was still moving on the frame
	-- it struck, so the windup read as the attack starting late rather than as
	-- a threat being held. Front-loaded instead - the reared pose is reached at
	-- 0.46 x 1.2 = ~0.55s and HELD for the remaining 0.65 - and a hang is what
	-- makes a windup read as a decision. Costs nothing: no phase moves.
	HANG = 0.46,
	-- THE IMPACT HOLD, in seconds of RECOVER, and it is not a round number:
	-- it is exactly LIVE - STRIKE, so the limb is visibly pinned to the stone
	-- for precisely as long as it is still dangerous. The slam's last 0.15s of
	-- damage lands inside `phase == "recover"`, and before this the peel front
	-- had already started travelling over players it was still killing.
	HOLD = 0.15,
}

-- THE SCYTHE. Original: it bows until the eye is ON the stone and then walks
-- that eye around its own socket. In a black arena the pool of light crawling
-- across the floor arrives before the limb does, and it is visible from behind
-- as a glow rising off the ground - which is what makes a 75-degree sweep at
-- walking height dodgeable in locked first person.
NoctyssPath.SCYTHE = {
	BOW = 0.9, -- the bow-down, which is half the telegraph
	SWEEP = 2.2,
	RECOVER = 1.1,
	ARC = math.rad(75),
	RADIUS = 6.5, -- the moving sphere at the bulb
	REACH = 22.0, -- default studs from the socket the drag runs at
	-- Bounded so a sweep is always something a stalk can physically reach and
	-- always crosses ground a player can be standing on.
	REACH_MIN = 13.0,
	REACH_MAX = 30.0,
	-- THE COUNTER-BOW: the only anticipation this move has. The eye winds
	-- BACK, 12 degrees against the travel, for the first COUNTER_HOLD of the
	-- bow and then eases onto the true start over the rest - so the pool of
	-- light visibly loads before it sweeps, rather than simply arriving.
	COUNTER = math.rad(12.0),
	COUNTER_HOLD = 0.35,
	-- THE RECOVERY LIFT, in fractions of RECOVER. The landed pose aims at the
	-- stone, so releasing it dragged the eye back ALONG the ground it had just
	-- swept, across the players who correctly stepped out of the band, with no
	-- hitbox on it - a second sweep that does not hurt, which teaches the wrong
	-- thing about the first one. The aim point rises by EYE_R * 2 over this
	-- first slice of the recovery, so the limb comes off the floor and THEN
	-- goes home.
	LIFT = 0.3,
}

-- THE JAB, which `feelerstrike` becomes: coil, spear, snap back. Short enough
-- that it is a punish rather than a set piece - the move she throws when a pull
-- has just put someone in the open.
NoctyssPath.JAB = {
	COIL = 0.5,
	THRUST = 0.12,
	HOLD = 0.1,
	RETURN = 0.45,
	REAR = math.rad(22),
	TWIST = math.rad(16), -- the S: a roll about the aim, against the resting bow
	COIL_IN = 0.2, -- how far it draws itself in before the spear
	RADIUS = 5.5,
	-- The same hang the slam has, at the jab's scale: the S is reached by
	-- 0.38s and held for the last 0.12 of COIL. A coil that is still coiling
	-- when it fires has no moment the player can answer.
	COIL_HANG = 0.76,
}

-- IS THIS KIND A SLAM? Two kinds are: `stalkslam`, and the `portcullis` bar
-- that the head throws with two of its limbs at once (see "the head and the
-- limbs together"). A portcullis IS a slam - same windup, same pose, same
-- capsule, same peel - and the only thing that separates them is that the
-- client draws a barred door rather than a single stripe, and that the server
-- launches them in matched pairs. So every place in this file that used to
-- spell "stalkslam" asks this instead: one predicate, so a bar can never end
-- up with a slam's hitbox and a scythe's recovery, or vice versa.
local function isSlam(kind: string?): boolean
	return kind == "stalkslam" or kind == "portcullis"
end

-- kind -> { windup, strike, recover }, in seconds. One table so no phase
-- boundary can be spelled differently on the two sides.
local PHASES = {
	stalkslam = { NoctyssPath.SLAM.WINDUP, NoctyssPath.SLAM.STRIKE, NoctyssPath.SLAM.RECOVER },
	gloomscythe = { NoctyssPath.SCYTHE.BOW, NoctyssPath.SCYTHE.SWEEP, NoctyssPath.SCYTHE.RECOVER },
	feelerstrike = { NoctyssPath.JAB.COIL, NoctyssPath.JAB.THRUST + NoctyssPath.JAB.HOLD, NoctyssPath.JAB.RETURN },
}
-- THE SAME THREE SPANS, not a copy of them. The bar's whole promise is that it
-- lands on the beat a slam would have: a second table of the same three
-- numbers is a second place for them to be tuned apart, and the two of them
-- disagreeing by a tenth is a door that shuts before the telegraph says.
PHASES.portcullis = PHASES.stalkslam

-- Which phase an attack is in, and how far through it, from nothing but the
-- descriptor's `start` and a clock. Both sides call this; nobody counts frames.
-- Returns ("windup" | "strike" | "recover" | "done", 0..1).
function NoctyssPath.attackPhase(attack, now: number): (string, number)
	local spans = PHASES[attack and attack.kind]
	if not spans then
		return "done", 1
	end
	local t = now - (attack.start or 0)
	if t <= 0 then
		return "windup", 0
	end
	if t < spans[1] then
		return "windup", t / spans[1]
	end
	t -= spans[1]
	if t < spans[2] then
		return "strike", t / spans[2]
	end
	t -= spans[2]
	if t < spans[3] then
		return "recover", t / spans[3]
	end
	return "done", 1
end

-- Windup + strike + recover, in seconds: how long the limb is committed.
function NoctyssPath.attackDuration(attack): number
	local spans = PHASES[attack and attack.kind]
	return if spans then spans[1] + spans[2] + spans[3] else 0
end

-- IS THE HITBOX LIVE? Separate from the phase because the slam's damage
-- deliberately outlasts its travel - the limb lying across the stone is still
-- a limb lying across the stone.
function NoctyssPath.attackLive(attack, now: number): boolean
	if not attack or not PHASES[attack.kind] then
		return false
	end
	local t = now - (attack.start or 0)
	if isSlam(attack.kind) then
		local w = NoctyssPath.SLAM.WINDUP
		return t >= w and t <= w + NoctyssPath.SLAM.LIVE
	end
	if attack.kind == "feelerstrike" then
		local c = NoctyssPath.JAB.COIL
		return t >= c and t <= c + NoctyssPath.JAB.THRUST + NoctyssPath.JAB.HOLD
	end
	local phase = NoctyssPath.attackPhase(attack, now)
	return phase == "strike"
end

-- HOW LONG THE HITBOX IS LIVE, in seconds, for the kind it is handed. The
-- other half of `attackLive`, named so `tellPhase` can measure back from the
-- END of the live window without re-spelling any of these three windows.
local function liveSpan(attack): number
	if isSlam(attack.kind) then
		return NoctyssPath.SLAM.LIVE
	end
	if attack.kind == "feelerstrike" then
		return NoctyssPath.JAB.THRUST + NoctyssPath.JAB.HOLD
	end
	local spans = PHASES[attack.kind]
	return if spans then spans[2] else 0
end

-- THE THREE ARGUMENTS EVERY MARK'S RAMP NEEDS, off nothing but a descriptor
-- and the shared clock: (u through the lead-in, is the hitbox live, seconds
-- since it changed state). Feed them straight to `NoctyssPath.tellRamp`.
--
-- DERIVED FROM THE LIVE PREDICATE, NEVER FROM A PHASE NAME. That distinction
-- is the entire bug this function exists to close: the slam's damage runs
-- 0.15s past the end of its `strike` phase, so every mark that branched on
-- `phase == "recover"` began fading while its own hitbox was still killing
-- people - the exact lie the telegraph half of this fight is built to never
-- tell. Ask `attackLive`, which is the same function the server damages on.
function NoctyssPath.tellPhase(attack, now: number): (number, boolean, number?)
	local spans = PHASES[attack and attack.kind]
	if not spans then
		return 1, false, NoctyssPath.TELL.FADE
	end
	local t = now - (attack.start or 0)
	local lead = math.max(spans[1], 1e-3)
	if NoctyssPath.attackLive(attack, now) then
		return 1, true, t - spans[1]
	end
	if t <= spans[1] then
		return math.clamp(t / lead, 0, 1), false, nil
	end
	return 1, false, t - (spans[1] + liveSpan(attack))
end

-- ------------------------------------------------------------ the pose solver

-- A CFrame VALUE, not the CFrame library's `identity` field: `Lerp` is a
-- method on an instance and the type checker is right to refuse it on the
-- static. Same rotation, and it is the pose every attack starts and ends at.
local IDENTITY = CFrame.new()

local function safeUnit(v: Vector3, fallback: Vector3): Vector3
	return if v.Magnitude > 1e-5 then v.Unit else fallback
end

-- The shortest rotation carrying `from` onto `to`. Pure rotation: callers
-- apply it with VectorToWorldSpace, so its position half is never read.
local function rotationBetween(from: Vector3, to: Vector3): CFrame
	local a = safeUnit(from, Vector3.new(0, 1, 0))
	local b = safeUnit(to, Vector3.new(0, 1, 0))
	local axis = a:Cross(b)
	local dot = math.clamp(a:Dot(b), -1, 1)
	if axis.Magnitude < 1e-5 then
		if dot > 0 then
			return CFrame.identity
		end
		-- Exactly opposed: any perpendicular will do, and there is always one.
		local perp = a:Cross(Vector3.new(0, 1, 0))
		if perp.Magnitude < 1e-5 then
			perp = a:Cross(Vector3.new(1, 0, 0))
		end
		return CFrame.fromAxisAngle(perp.Unit, math.pi)
	end
	return CFrame.fromAxisAngle(axis.Unit, math.acos(dot))
end

-- Socket `index`'s root, arena-local: the point the whole pose turns about.
-- The same three lines `stalkCurve` opens with, which is the point.
local function socketRoot(index: number): Vector3
	local angle = NoctyssPath.socketAngle(index)
	return Vector3.new(
		math.cos(angle) * NoctyssPath.SOCKET_R,
		NoctyssPath.REST.ROOT_Y,
		math.sin(angle) * NoctyssPath.SOCKET_R
	)
end

-- THE STALK AS THE SOLVER SEES IT, at rest: the root, the vector from the root
-- to the END OF THE CURVE (`c`), and the lantern's offset off that end (`h`).
-- The bulb at rest is root + c + h - `bulbPosition`, taken apart.
--
-- `noAttack` on every sample: this is what the pose is derived FROM, so it must
-- be the shape the stalk would be in with no attack on it. Anything else is a
-- pose defined in terms of itself.
-- THE LANTERN'S OFFSET OFF THE END OF THE CURVE, for a hood pointing
-- `forward`. The same three lines `bulbPosition` builds - and the reason the
-- solver below has to iterate: `realUp` is rebuilt from WORLD up every time, so
-- this offset does NOT simply rotate with the limb. Swing a stalk 90 degrees
-- over and the hood's own up re-derives to something that is not the rotated
-- rest up, and a solver that assumed it did put the bulb up to 3.4 studs off
-- the point it had just drawn a stripe to - most of an eye's diameter, on the
-- one attack whose whole promise is that it lands where it said it would.
local function hoodOffset(forward: Vector3): Vector3
	local up = if math.abs(forward.Y) > 0.99 then Vector3.new(0, 0, 1) else Vector3.new(0, 1, 0)
	local right = safeUnit(forward:Cross(up), Vector3.new(1, 0, 0))
	local realUp = safeUnit(right:Cross(forward), Vector3.new(0, 1, 0))
	return forward * BULB_FORWARD + realUp * BULB_DOWN
end

local function restReach(state, index: number): (Vector3, Vector3, Vector3)
	local root = socketRoot(index)
	local at = stalkCurve(state, index, 1, false, true)
	local before = stalkCurve(state, index, 0.98, false, true)
	return root, at - root, safeUnit(at - before, Vector3.new(0, 1, 0))
end

-- HOW FAR TO STRETCH so the lantern lands exactly `distance` from the root.
--
-- The stretch scales the CURVE about the root; the hood's offset `h` rides on
-- the curve's tangent and does NOT scale with it (a bigger stalk does not get a
-- bigger head). So the bulb ends up at s*c + h, and the reach the pose needs is
-- the positive root of |s*c + h| = distance - one quadratic, in closed form,
-- rather than an iteration nobody would run identically on two machines.
-- HOW FAR A STALK MAY BE DRAWN IN OR PAID OUT. A limb that folded to a third
-- of itself, or doubled, would stop being the same animal - and these two
-- numbers ARE the fight's reach, so `stalkReach` reports them in studs and
-- `setAttack` clamps every target inside them. An attack that aimed past the
-- arm would draw a stripe the limb then fell short of, which is the one lie a
-- telegraph is not allowed to tell.
local STRETCH_MIN = 0.45
local STRETCH_MAX = 1.55

local function reachScale(c: Vector3, h: Vector3, distance: number): number
	local a = c:Dot(c)
	if a < 1e-6 then
		return 1
	end
	local b = 2 * c:Dot(h)
	local k = h:Dot(h) - distance * distance
	local disc = b * b - 4 * a * k
	if disc <= 0 then
		-- The target is nearer than the head is long: the stalk cannot fold
		-- into itself, so it draws in as far as the clamp allows and no more.
		return STRETCH_MIN
	end
	return math.clamp((-b + math.sqrt(disc)) / (2 * a), STRETCH_MIN, STRETCH_MAX)
end

-- THE POSE THAT PUTS THE LANTERN ON `aim` (world). Rotation + stretch.
--
-- Solved, and solved TWICE OVER. One pass would be exact if the hood's offset
-- rotated with the limb, and it does not (see `hoodOffset`) - so each pass
-- re-reads where that offset actually ended up, carries it back into the rest
-- frame, and re-solves against it. It converges hard: the correction is a
-- 3-stud vector on a 35-stud arm, and three passes leave under a hundredth of
-- a stud. Cheap, closed-form inside each pass, and identical on both machines
-- because it is the same fixed number of the same arithmetic - which an
-- iterate-until-close loop would not have been.
--
-- MEASURED, over all seven sockets against slam, scythe and jab aims across
-- the whole shelf (including every aim the reach clamp has to move): the eye
-- lands within 0.04 studs of the latched point. The one exception is a limb
-- pointing very near straight down, where `hoodOffset` swaps its reference up
-- - the same branch `bulbPosition` has always had, at the same threshold - and
-- the solve settles about 0.26 studs out. That is 6% of the eye's own radius,
-- and both sides read it identically, which is the property that matters.
local PASSES = 3

local function aimFrame(state, index: number, aim: Vector3): (CFrame, number)
	local root, c, forward = restReach(state, index)
	local want = aim - (state.center + root)
	local distance = want.Magnitude
	if distance < 1e-3 then
		return IDENTITY, 1
	end
	local h = hoodOffset(forward)
	local rot, stretch = IDENTITY, 1
	for _ = 1, PASSES do
		stretch = reachScale(c, h, distance)
		rot = rotationBetween(c * stretch + h, want)
		-- Where the hood's offset really is under this rotation, brought back
		-- into the rest frame so the next pass solves with the truth.
		h = rot:VectorToObjectSpace(hoodOffset(rot:VectorToWorldSpace(forward)))
	end
	return rot, stretch
end

-- The horizontal axis a limb rocks about to lean TOWARD `aim`, and the flat
-- bearing to it. Rotating by a POSITIVE angle about this axis tips the stalk
-- onto the aim; negative rears it away, which is every windup in here.
local function tiltAxis(state, index: number, aim: Vector3): (Vector3, Vector3)
	local root = state.center + socketRoot(index)
	local flat = safeUnit(Vector3.new(aim.X - root.X, 0, aim.Z - root.Z), Vector3.new(1, 0, 0))
	return safeUnit(Vector3.new(0, 1, 0):Cross(flat), Vector3.new(0, 0, 1)), flat
end

-- HOW MUCH OF THE POSE IS STILL ON, at curve parameter `t`.
--
-- 1 through the windup and the strike; on the way out it lets go. The slam
-- lets go BASE-FIRST - a release front travelling from the collar to the hood,
-- which is what a whip reversing looks like and what makes the recovery read as
-- the limb being hauled back in rather than rewinding. The other two just
-- release as one, because a jab that peeled would stop being a snap.
local function attackKeep(attack, now: number, t: number): number
	local phase, u = NoctyssPath.attackPhase(attack, now)
	if phase == "done" then
		return 0
	end
	if phase ~= "recover" then
		return 1
	end
	if not isSlam(attack.kind) then
		return 1 - smoothstep(u)
	end
	-- THE IMPACT HOLD. `keep = 1` for the first SLAM.HOLD of the recovery -
	-- which is exactly LIVE - STRIKE, the slice of damage that lands after the
	-- limb has stopped travelling - plus whatever extra the descriptor asked
	-- for (`hold`: a herd bar stays down until the mouth is up). The peel then
	-- runs its full width over what is left, so the release still reads as one
	-- wave from the collar and nothing about it is compressed.
	local recover = math.max(NoctyssPath.SLAM.RECOVER, 1e-3)
	local pinned = (NoctyssPath.SLAM.HOLD + math.max(attack.hold or 0, 0)) / recover
	if u <= pinned then
		return 1
	end
	if pinned >= 1 then
		return 1
	end
	local width = NoctyssPath.SLAM.PEEL
	local front = (u - pinned) / (1 - pinned) * (1 + width)
	return smoothstep((t - front + width) / width)
end

-- ------------------------------------------------------------ the three poses

-- THE SLAM, as one rotation and one stretch, at this instant.
--
-- Windup: rock BACK off the line and stretch up, so the limb is high and wrong
-- before it is right. Strike: quadratic into the landed pose, so most of the
-- travel happens in the last few frames - the crack. Recover: hold the landed
-- pose and let `attackKeep` peel it off the stone.
function NoctyssPath.slamFrame(state, index: number, attack): (CFrame, number)
	local phase, u = NoctyssPath.attackPhase(attack, state.time or 0)
	local axis = tiltAxis(state, index, attack.target)
	local reared = CFrame.fromAxisAngle(axis, -NoctyssPath.SLAM.REAR)
	local rise = NoctyssPath.SLAM.RISE
	if phase == "windup" then
		-- Front-loaded ease-out into the rear, then a HANG (SLAM.HANG): the
		-- limb is high and wrong early and holds there, rather than drifting
		-- into position on the frame it strikes.
		local e = 1 - (1 - math.clamp(u / NoctyssPath.SLAM.HANG, 0, 1)) ^ 2
		return IDENTITY:Lerp(reared, e), 1 + rise * e
	end
	local landed, stretch = aimFrame(state, index, attack.target)
	if phase == "strike" then
		local e = u * u
		return reared:Lerp(landed, e), (1 + rise) + (stretch - 1 - rise) * e
	end
	return landed, stretch
end

-- How far round its arc the scythe has travelled, 0..1. Public because the
-- client draws the arc band ahead of exactly this number and the server tests
-- the sphere at exactly this number, and the two may not be two functions.
function NoctyssPath.scytheTravel(attack, now: number): number
	local phase, u = NoctyssPath.attackPhase(attack, now)
	if phase == "windup" then
		return 0
	end
	if phase ~= "strike" then
		return 1
	end
	-- Mostly eased, with a linear floor: pure smoothstep crawls at both ends
	-- and then bolts through the middle, which is the one part of the sweep a
	-- player needs time to read.
	return 0.15 * u + 0.85 * smoothstep(u)
end

-- WHERE THE EYE IS DRAGGING, at `travel` (0..1) round the arc: on the arena's
-- floor, one eye-radius up, `reach` studs from its own socket. This is the
-- attack's hit anchor and the centre of the pool of light on the stone.
-- `bias` is radians added to the bearing AFTER the travel is clamped, and it
-- is how the counter-bow reaches a point BEHIND the arc's start without the
-- clamp eating it. Optional, and nothing that tests or draws the band passes
-- it: the hit test and the lit ground are still the same call with the same
-- three arguments.
function NoctyssPath.scythePoint(state, index: number, attack, travel: number, bias: number?): Vector3
	local start = attack.from or NoctyssPath.socketAngle(index)
	local arc = attack.arc or NoctyssPath.SCYTHE.ARC
	local dir = if (attack.dir or 1) < 0 then -1 else 1
	local reach = attack.reach or NoctyssPath.SCYTHE.REACH
	local phi = start + dir * arc * math.clamp(travel, 0, 1) + (bias or 0)
	local root = state.center + socketRoot(index)
	return Vector3.new(
		root.X + math.cos(phi) * reach,
		state.center.Y + NoctyssPath.SHELF_Y + NoctyssPath.EYE_R,
		root.Z + math.sin(phi) * reach
	)
end

-- THE SCYTHE. Bow down onto the arc's first point, then keep aiming at a point
-- that walks round the arc - the drag falls out of the aim, so there is no
-- second animation for the sweep and nothing to disagree with the hit test.
function NoctyssPath.scytheFrame(state, index: number, attack): (CFrame, number)
	local now = state.time or 0
	local phase, u = NoctyssPath.attackPhase(attack, now)
	local scythe = NoctyssPath.SCYTHE
	if phase == "windup" then
		-- THE COUNTER-BOW. The eye bows onto a point COUNTER radians against
		-- the travel and stays there for COUNTER_HOLD of the bow, then eases
		-- onto the arc's true start - reaching it exactly as the sweep begins,
		-- so the strike is continuous with the pose the windup ends in.
		local dir = if (attack.dir or 1) < 0 then -1 else 1
		local hold = scythe.COUNTER_HOLD
		local wound = 1 - smoothstep(math.clamp((u - hold) / math.max(1 - hold, 1e-3), 0, 1))
		local back = NoctyssPath.scythePoint(state, index, attack, 0, -dir * scythe.COUNTER * wound)
		local bowed, bowStretch = aimFrame(state, index, back)
		local e = smoothstep(u)
		return IDENTITY:Lerp(bowed, e), 1 + (bowStretch - 1) * e
	end
	local aim = NoctyssPath.scythePoint(state, index, attack, NoctyssPath.scytheTravel(attack, now))
	if phase == "recover" then
		-- OFF THE STONE FIRST. The landed pose aims one eye-radius above the
		-- floor, so simply releasing it hauled the eye back along the ground it
		-- had just swept. The aim point rises by EYE_R * 2 over the first LIFT
		-- of the recovery instead, and `attackKeep` takes the limb home from
		-- there - the same release, from a metre up.
		aim += Vector3.new(0, NoctyssPath.EYE_R * 2 * smoothstep(math.clamp(u / scythe.LIFT, 0, 1)), 0)
	end
	local landed, stretch = aimFrame(state, index, aim)
	return landed, stretch
end

-- THE JAB. Coil into an S - rocked back off the aim and rolled about it,
-- against the resting bow the shape already carries - then a cubic ease-out
-- into the landed pose, which is a piston rather than a swing.
function NoctyssPath.jabFrame(state, index: number, attack): (CFrame, number)
	local phase, u = NoctyssPath.attackPhase(attack, state.time or 0)
	local axis, flat = tiltAxis(state, index, attack.target)
	local coiled = CFrame.fromAxisAngle(axis, -NoctyssPath.JAB.REAR) * CFrame.fromAxisAngle(flat, NoctyssPath.JAB.TWIST)
	local drawn = 1 - NoctyssPath.JAB.COIL_IN
	if phase == "windup" then
		-- ...reached by COIL_HANG of the coil and held there for the rest, so
		-- the S is a loaded spring and not a slow lean.
		local e = smoothstep(math.clamp(u / NoctyssPath.JAB.COIL_HANG, 0, 1))
		return IDENTITY:Lerp(coiled, e), 1 - NoctyssPath.JAB.COIL_IN * e
	end
	local landed, stretch = aimFrame(state, index, attack.target)
	if phase == "strike" then
		-- The strike span is the spear AND the beat it holds out there; the
		-- spear itself is only the first fraction of it.
		local span = NoctyssPath.JAB.THRUST / (NoctyssPath.JAB.THRUST + NoctyssPath.JAB.HOLD)
		local e = 1 - (1 - math.clamp(u / span, 0, 1)) ^ 3
		return coiled:Lerp(landed, e), drawn + (stretch - drawn) * e
	end
	return landed, stretch
end

-- The full pose, cached for the instant it was asked about: `stalkCurve` calls
-- this once per sample (48 a frame per stalk, plus the server's), and the
-- answer cannot change inside one frame because it is a function of state.time.
local function posed(state, index: number, attack, t: number, frameFn): (CFrame?, number)
	local now = state.time or 0
	local keep = attackKeep(attack, now, t)
	if keep <= 0.002 then
		return nil, 1
	end
	local rot, stretch = attack._frameRot, attack._frameStretch
	if attack._frameAt ~= now or not rot then
		rot, stretch = frameFn(state, index, attack)
		attack._frameAt, attack._frameRot, attack._frameStretch = now, rot, stretch
	end
	return IDENTITY:Lerp(rot, keep), 1 + (stretch - 1) * keep
end

-- The three the renderer and the shape share: (rotation about the root,
-- uniform stretch) at curve parameter `t`, or nil once the limb is home.
function NoctyssPath.slamCurve(state, index: number, attack, t: number): (CFrame?, number)
	return posed(state, index, attack, t, NoctyssPath.slamFrame)
end

function NoctyssPath.scytheCurve(state, index: number, attack, t: number): (CFrame?, number)
	return posed(state, index, attack, t, NoctyssPath.scytheFrame)
end

function NoctyssPath.jabCurve(state, index: number, attack, t: number): (CFrame?, number)
	return posed(state, index, attack, t, NoctyssPath.jabFrame)
end

attackPose = function(state, index: number, attack, t: number): (CFrame?, number)
	if isSlam(attack.kind) then
		return NoctyssPath.slamCurve(state, index, attack, t)
	elseif attack.kind == "gloomscythe" then
		return NoctyssPath.scytheCurve(state, index, attack, t)
	elseif attack.kind == "feelerstrike" then
		return NoctyssPath.jabCurve(state, index, attack, t)
	end
	return nil, 1
end

-- ------------------------------------------------------------ the book-keeping

-- HOW FAR SOCKET `index`'s LANTERN CAN GET FROM ITS ROOT, in studs: the two
-- ends of the stretch clamp, measured on the shape the stalk is in right now.
-- About 12 to 50 at rest - which is why a slam is a threat to most of the
-- shelf but not to all of it, and why standing at the rim is a real answer.
function NoctyssPath.stalkReach(state, index: number): (number, number)
	local _, c, forward = restReach(state, index)
	local h = hoodOffset(forward)
	return (c * STRETCH_MIN + h).Magnitude, (c * STRETCH_MAX + h).Magnitude
end

-- PULL A TARGET INSIDE THE ARM, keeping its height. A point the limb cannot
-- reach is walked in (or out) along the flat bearing to it until it can, so
-- what gets latched, drawn and tested is a point the bulb will actually arrive
-- at. Out-of-reach used to mean the stretch clamp silently ate up to eleven
-- studs and the strike landed short of its own stripe.
local function clampToReach(state, index: number, target: Vector3): Vector3
	local root = state.center + socketRoot(index)
	local near, far = NoctyssPath.stalkReach(state, index)
	local span = target - root
	if span.Magnitude >= near and span.Magnitude <= far then
		return target
	end
	local want = math.clamp(span.Magnitude, near, far)
	-- Height is kept and the flat radius carries the change: these attacks are
	-- aimed at the floor, and dropping a slam's target ten studs down the pit
	-- to make it reachable would be worse than moving it in.
	local flat = Vector3.new(span.X, 0, span.Z)
	local radius = math.sqrt(math.max(want * want - span.Y * span.Y, 1.0))
	return root + safeUnit(flat, Vector3.new(1, 0, 0)) * radius + Vector3.new(0, span.Y, 0)
end

-- SNAP A WORLD POINT TO WHERE A LANTERN CAN SIT ON IT: the arena's floor,
-- one eye-radius up. Every attack's `target` should go through this - a slam
-- aimed at a player's chest drives the limb through the stone to reach it.
function NoctyssPath.aimPoint(state, position: Vector3): Vector3
	return Vector3.new(position.X, state.center.Y + NoctyssPath.SHELF_Y + NoctyssPath.EYE_R, position.Z)
end

-- ARM AN ATTACK. Both sides call this with the same table: the server when it
-- begins the move, the client when the descriptor arrives. Missing scythe
-- parameters are filled HERE rather than at either call site, so a descriptor
-- that crossed the wire and one that did not describe the same sweep.
function NoctyssPath.setAttack(state, attack)
	if not attack or not PHASES[attack.kind] or not attack.index then
		return nil
	end
	attack.start = attack.start or NoctyssPath.clock()
	attack.target = clampToReach(state, attack.index, attack.target or NoctyssPath.aimPoint(state, state.center))
	if attack.kind == "gloomscythe" then
		local root = state.center + socketRoot(attack.index)
		local to = Vector3.new(attack.target.X - root.X, 0, attack.target.Z - root.Z)
		-- The sweep radius is bounded by the design AND by the arm: the eye
		-- rides one radius off the stone, so the far end of the band has to be
		-- somewhere the limb can actually put it.
		local near, far = NoctyssPath.stalkReach(state, attack.index)
		local lift = state.center.Y + NoctyssPath.SHELF_Y + NoctyssPath.EYE_R - root.Y
		local armed = math.sqrt(math.max(far * far - lift * lift, 1.0))
		attack.reach = math.clamp(
			attack.reach or to.Magnitude,
			math.max(NoctyssPath.SCYTHE.REACH_MIN, math.sqrt(math.max(near * near - lift * lift, 1.0))),
			math.min(NoctyssPath.SCYTHE.REACH_MAX, armed)
		)
		attack.arc = attack.arc or NoctyssPath.SCYTHE.ARC
		attack.dir = if (attack.dir or 1) < 0 then -1 else 1
		-- Start half an arc BEHIND the latched bearing, so the sweep travels
		-- THROUGH where the target was standing rather than stopping at it -
		-- the same anticipation `lightsweep` opens with.
		attack.from = attack.from or (math.atan2(to.Z, to.X) - attack.dir * attack.arc * 0.5)
	end
	-- A stale cache from the previous armament of this same table would be a
	-- pose one frame out of date, at the one instant nobody is watching for it.
	attack._frameAt = nil
	state.attacks = state.attacks or {}
	state.attacks[attack.index] = attack
	return attack
end

-- The attack socket `index` is committed to, or nil. Retires itself: a
-- descriptor whose time is up, or whose stalk has been shot out from under it,
-- is dropped here so no caller has to remember to.
function NoctyssPath.attackFor(state, index: number, now: number?)
	local attacks = state.attacks
	local attack = attacks and attacks[index]
	if not attack then
		return nil
	end
	local stalk = state.stalks[index]
	if not stalk or not stalk.alive then
		attacks[index] = nil
		return nil
	end
	if (now or state.time or 0) - (attack.start or 0) >= NoctyssPath.attackDuration(attack) then
		attacks[index] = nil
		return nil
	end
	return attack
end

-- IS THIS STALK MID-SWING? The predicate both sides read.
--
-- A limb in the middle of a slam is not a lantern breathing at you: the server
-- must not hand it the true lure or count it as a candidate for a light move,
-- and the client must not draw its pulse. Both would be saying "read my
-- rhythm" about a light that is currently a weapon.
function NoctyssPath.stalkBusy(state, index: number, now: number?): boolean
	return NoctyssPath.attackFor(state, index, now) ~= nil
end

-- ------------------------------------------------------------ the hit tests

-- Distance from `p` to the segment a..b, measured flat. The arena is one
-- storey and everything here is decided on the floor plan.
local function segmentDistanceXZ(p: Vector3, a: Vector3, b: Vector3): number
	local ab = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
	local ap = Vector3.new(p.X - a.X, 0, p.Z - a.Z)
	local len2 = ab:Dot(ab)
	local h = if len2 > 1e-6 then math.clamp(ap:Dot(ab) / len2, 0, 1) else 0
	return (ap - ab * h).Magnitude
end

-- The band of heights a limb lying on (or swinging just above) the stone can
-- reach: a crouching player's feet to a standing player's head, generously.
local function onTheFloor(state, position: Vector3, low: number, high: number): boolean
	local floor = state.center.Y + NoctyssPath.SHELF_Y
	return position.Y >= floor - low and position.Y <= floor + high
end

-- THE SLAM'S HITBOX: a capsule along the down-line, from the socket the limb
-- grew out of to the point it was latched onto - which is precisely the stripe
-- the client drew on the floor a second earlier. Live for SLAM.LIVE from the
-- strike's first frame.
function NoctyssPath.slamHits(state, attack, position: Vector3, pad: number?, now: number): boolean
	if not attack or not isSlam(attack.kind) or not NoctyssPath.attackLive(attack, now) then
		return false
	end
	if not onTheFloor(state, position, 6, 14) then
		return false
	end
	local socket = state.center + NoctyssPath.socketPoint(attack.index)
	return segmentDistanceXZ(position, socket, attack.target) <= NoctyssPath.SLAM.RADIUS + (pad or 0)
end

-- THE SCYTHE'S HITBOX: the moving sphere at the dragging eye. Flat, because
-- the dodge is stepping out of the band it walks - not jumping over a limb
-- that is on the ground by definition.
function NoctyssPath.scytheHits(state, attack, position: Vector3, pad: number?, now: number): boolean
	if not attack or attack.kind ~= "gloomscythe" or not NoctyssPath.attackLive(attack, now) then
		return false
	end
	if not onTheFloor(state, position, 5, 12) then
		return false
	end
	local at = NoctyssPath.scythePoint(state, attack.index, attack, NoctyssPath.scytheTravel(attack, now))
	local to = Vector3.new(position.X - at.X, 0, position.Z - at.Z)
	return to.Magnitude <= NoctyssPath.SCYTHE.RADIUS + (pad or 0)
end

-- THE JAB'S HITBOX: a sphere at the latched point, in full 3D - this one IS a
-- spear coming in at whatever height it was aimed at, so height matters.
-- (`_state` is unread, and kept so the three hit tests take one signature: a
-- server that has to remember which of them is the odd one out will get it
-- wrong on the day someone adds a fourth.)
function NoctyssPath.jabHits(_state, attack, position: Vector3, pad: number?, now: number): boolean
	if not attack or attack.kind ~= "feelerstrike" or not NoctyssPath.attackLive(attack, now) then
		return false
	end
	return (position - attack.target).Magnitude <= NoctyssPath.JAB.RADIUS + (pad or 0)
end

-- One call for a caller that does not care which move it is holding.
function NoctyssPath.attackHits(state, attack, position: Vector3, pad: number?, now: number): boolean
	if not attack then
		return false
	end
	if isSlam(attack.kind) then
		return NoctyssPath.slamHits(state, attack, position, pad, now)
	elseif attack.kind == "gloomscythe" then
		return NoctyssPath.scytheHits(state, attack, position, pad, now)
	elseif attack.kind == "feelerstrike" then
		return NoctyssPath.jabHits(state, attack, position, pad, now)
	end
	return false
end

-- WHERE THE DANGER IS RIGHT NOW, for anything that wants to point at it (a
-- sound, a light, a camera shake). The slam and the jab hold still; the scythe
-- walks.
function NoctyssPath.attackAim(state, attack, now: number): Vector3
	if attack and attack.kind == "gloomscythe" then
		return NoctyssPath.scythePoint(state, attack.index, attack, NoctyssPath.scytheTravel(attack, now))
	end
	return if attack then attack.target else state.center
end

-- HOW LIT THE LANTERN IS ALLOWED TO BE while its limb is swinging, 0..1 - a
-- multiplier on whatever the pulse was already showing, so it can only ever
-- take light away.
--
-- The slam SNUFFS: over the windup the light dies to an ember, which in an
-- arena lit by seven lanterns is the loudest thing that can happen, and it
-- comes back as the limb peels up. It never reaches zero - the eye has to stay
-- an eye, or the player loses the limb that is about to hit them at the exact
-- moment they need to track it. The scythe stays lit: the pool of light on the
-- stone IS its telegraph.
function NoctyssPath.attackGlow(attack, now: number): number
	if not attack or not isSlam(attack.kind) then
		return 1
	end
	local phase, u = NoctyssPath.attackPhase(attack, now)
	local ember = 0.09
	if phase == "windup" then
		return 1 - (1 - ember) * smoothstep(u)
	elseif phase == "recover" then
		-- Rekindling, and behind the shape: the light comes back over the last
		-- two thirds of the peel, so the limb is visibly on its way home before
		-- the lantern is worth reading again.
		return ember + (1 - ember) * smoothstep((u - 0.3) / 0.7)
	end
	return ember
end

-- ------------------------------------------------------------------ the maw

-- The lane she surfaces on: whichever fin gap the party's centre is nearest.
function NoctyssPath.laneFor(angle: number): number
	local best, bestDelta = authored(NoctyssPath.LANES[1]), math.huge
	for _, degrees in NoctyssPath.LANES do
		local lane = authored(degrees)
		local delta = math.abs((lane - angle + math.pi) % TAU - math.pi)
		if delta < bestDelta then
			best, bestDelta = lane, delta
		end
	end
	return best
end

-- The skull's CFrame: up through the pit, nose high, facing its lane. The
-- jaw is this turned about the authored hinge (the client does the hinge;
-- the server only needs the mouth).
--
-- FORWARD is applied AFTER the yaw and BEFORE the pitch, and that order is the
-- whole meaning of it: after the yaw so she leans toward whichever lane she
-- surfaced on rather than toward a fixed compass point, before the pitch so it
-- is a HORIZONTAL shift along the shelf and not a slide up her own nose (which
-- would move the floor the party stands on every time the pitch was tuned).
function NoctyssPath.mawCFrame(state): CFrame
	local rise = smoothstep(state.mawRise or 0)
	local maw = NoctyssPath.MAW
	local y = maw.Y_DOWN + (maw.Y_UP - maw.Y_DOWN) * rise
	local at = state.center + Vector3.new(0, y, 0)
	return CFrame.new(at)
		* CFrame.Angles(0, -(state.mawYaw or 0), 0)
		* CFrame.new(maw.FORWARD, 0, 0)
		* CFrame.Angles(0, 0, maw.PITCH)
end

-- WHERE THE PARTY FIGHTS during the punish window: the middle of the lower
-- jaw, in world space. The walkable floor is anchored parts pinned here (the
-- creature mesh itself is collision-free like every other creature part), and
-- the gullet - the weak point - sits at the back of it.
function NoctyssPath.mawMouth(state): CFrame
	local scale = NoctyssPath.MAW.SCALE
	-- IT HINGES. The floor the party stands on is inside the LOWER JAW, and
	-- the jaw swings MAW.GAPE about the authored hinge for the whole window -
	-- so deriving the mouth from the skull alone left the floor about thirteen
	-- studs away from the scoop it is meant to be the inside of. The gape is a
	-- tuned number (19 degrees today, 44 before the pit-mouth pose); reading it
	-- out of the table rather than baking a slope in here is what lets it be.
	local hinge = Vector3.new(-8.0, -2.2, 0) * scale
	local gape = NoctyssPath.MAW.GAPE * math.clamp(state.mawGape or 0, 0, 1)
	local jaw = NoctyssPath.mawCFrame(state) * CFrame.new(hinge) * CFrame.Angles(0, 0, -gape) * CFrame.new(-hinge)
	-- boss_gen's NC_JAW widest section is (x = -1.2, centre z = -3.9, half
	-- height 3.2), so the scoop's FLOOR is -7.1. The earlier -5.0 was read out
	-- of the half-WIDTH column; +0.6 puts the slab's top surface on the floor.
	return jaw * CFrame.new(-1.2 * scale, -7.1 * scale + 0.6, 0)
end

function NoctyssPath.gulletPosition(state): Vector3
	-- boss_gen NC_GULLET, in the skull's space.
	return (NoctyssPath.mawCFrame(state) * CFrame.new(-5.4 * NoctyssPath.MAW.SCALE, -1.8 * NoctyssPath.MAW.SCALE, 0)).Position
end

-- WHICH WAY SHE IS FACING, flat: the lane she surfaced on, and the axis across
-- it. `forward` runs from the pit out along her snout - which is the way a
-- player walks INTO the mouth, and the way they run to get out - and `lateral`
-- is the door's own left/right. Both unit, both level: everything the head and
-- the limbs do together is laid out on the floor plan, and reading the tilt of
-- her nose into it would swing the doorposts every time she pitched.
function NoctyssPath.mawFacing(state): (Vector3, Vector3)
	local right = NoctyssPath.mawCFrame(state).RightVector
	local forward = safeUnit(Vector3.new(right.X, 0, right.Z), Vector3.new(1, 0, 0))
	return forward, Vector3.new(0, 1, 0):Cross(forward)
end

-- Is `position` inside the closing mouth? The bite at the end of the window
-- catches whoever is still standing in there.
function NoctyssPath.insideMouth(state, position: Vector3): boolean
	local mouth = NoctyssPath.mawMouth(state)
	local local_ = mouth:PointToObjectSpace(position)
	local scale = NoctyssPath.MAW.SCALE
	return math.abs(local_.X) <= 7.0 * scale
		and math.abs(local_.Z) <= 5.6 * scale
		and local_.Y > -3.0
		and local_.Y < 9.0 * scale
end

-- ------------------------------------------- the head and the limbs together
--
-- "The head should use the tentacles to do attacks too" (user). Until now the
-- fight was two fights sharing a room: seven limbs threw slams, scythes and
-- jabs at the shelf, and the maw came up in its own window and did its own
-- thing to whoever was standing in it. Nothing was ever thrown BY the head
-- THROUGH the limbs.
--
-- These two are. Neither is a new pose and neither is a new hit shape - that
-- is the point. A portcullis is two ordinary slams whose targets the HEAD
-- chooses; a herding snap is two ordinary slams plus one disc centred on her
-- own pit. Everything the limbs do is still `slamHits` against a latched
-- capsule the client already knows how to draw, so the whole cost of "she
-- fights with her arms" is the arithmetic that picks the targets.
--
--   PORTCULLIS - inside the punish window, DOOR.LEAD seconds before the jaw
--   shuts, the two limbs flanking the entrance slam down across the doorway,
--   one each side. The bars land 0.4s before the bite, so what a player in
--   the mouth sees is the exit narrowing while the roof comes down. It never
--   SEALS: `doorTargets` puts the two capsules DOOR.HALF studs either side of
--   the entrance lane, which leaves an 8-stud slot on the centreline (see
--   `doorTargets`) - the punish is that you have to run the middle of it.
--
--   HERDING SNAP - in the choir phase, the two adjacent limbs nearest a
--   player slam onto targets that converge on the pit's rim: a V with its
--   point at the hole and its open end out at the socket ring, so the safe
--   ground inside it narrows toward the pit. Then she snaps at the rim - a
--   PARTIAL rise, lower jaw and fangs breaching, and everything on the pit
--   disc plus SNAP.MARGIN is bitten. The V does not push you in; it makes
--   walking in the direction that feels safest (away from the limbs, into the
--   dark middle) the thing that kills you.

-- THE DOOR, in studs.
--
-- AHEAD/HALF are measured off the mouth's own frame rather than off the
-- arena, so the doorposts follow the lane she surfaced on and the pitch she
-- is holding. LIP_* mirror CreatureService's `mawFloor`: the walkable ledge is
-- a 5.0 x 9.0 (x SCALE) slab stood 8.0 x SCALE forward of the mouth, so its
-- outer edge is (8.0 + 2.5) x SCALE forward and its half-width is 4.5 x SCALE
-- = 9 studs. HALF 11 therefore lands each bar two studs OUTSIDE the ledge's
-- own edge, biting SLAM.RADIUS 7 back in over it.
--
-- THE SLOT IS THE WHOLE DESIGN. Bars 22 studs apart, capsules 7 studs of
-- radius: 8 studs of walkable centreline through a door that is 18 studs wide,
-- and (measured over all six lanes, flood-filled across the shelf against both
-- capsules) never less than 9.0 studs of connected corridor from the ledge out
-- to open floor. A player standing in the mouth can always leave; they cannot
-- leave sideways, which is what a portcullis is for.
--
-- MARGIN is reach slack, not geometry: `flankingStalks` will not hand a bar to
-- a limb whose target sits within this of either end of its own reach, because
-- `stalkReach` is measured on the CURRENT shape and the client's `lean` is
-- eased on its own clock - a target on the exact edge of the arm could be
-- clamped by one side and not the other, and the two would draw different
-- doors.
NoctyssPath.DOOR = {
	AHEAD = 3.0,
	HALF = 11.0,
	MARGIN = 3.0,
	LEAD = 1.6, -- seconds before the jaw shuts that the server arms the pair
	LIP_FORWARD = 8.0, -- x SCALE: CreatureService placeMawFloor's lip offset
	LIP_HALF = 2.5, -- x SCALE: half the lip slab's length
}

-- THE FUNNEL. The apex sits ON the rim (PIT_R) on the bearing halfway between
-- the two sockets, and each target is set SPREAD studs off it toward its own
-- socket's side. 10 studs between the two tips against a 7-stud capsule radius
-- means the tips OVERLAP by 4: the point of the V is shut, so the funnel's only
-- opening is the wide end out at the collars. Both targets end up 18.4 studs
-- from their sockets - comfortably inside the 14.2 the arm can fold to.
NoctyssPath.HERD = { SPREAD = 5.0 }

-- THE SNAP, in seconds and studs.
--
-- RISE is the tell and it is a PARTIAL one: she comes up to RISE_TO, which
-- breaches the lower jaw and the fang line over the rim and nothing else. That
-- is the read - a mouth opening in the floor is unmistakable, and it is
-- unmistakably different from the full rise of the punish window, so nobody
-- runs in to fight her.
--
-- BITE is short on purpose: everything the tell bought is spent in a third of
-- a second. MARGIN is how far past the rim the fangs come down - the disc is
-- the hole plus a lip, because a bite that stopped exactly at the rim would be
-- dodged by standing on the rim, which is where the V has just herded you.
NoctyssPath.SNAP = {
	RISE = 1.0,
	BITE = 0.3,
	SINK = 0.9,
	-- A FRACTION TUNED TO A HEIGHT, so it has to be re-solved whenever the two
	-- ends of the travel move. The tell is the ORIGIN AT ARENA-LOCAL Y -3.6:
	-- at that height the lower jaw's lip and the fang line breach the pit rim
	-- and nothing else does. Origin Y at fraction f is
	-- MAW.Y_DOWN + f * (MAW.Y_UP - MAW.Y_DOWN), so with Y_DOWN now -20 (it was
	-- -36, where 0.55 gave that same -3.6) and Y_UP 20.4:
	--   f = (-3.6 - (-20)) / (20.4 - (-20)) = 16.4 / 40.4 = 0.406
	RISE_TO = 0.406,
	MARGIN = 4.0,
}

-- WHERE THE TWO BARS LAND: just outside the lip, one each side of the entrance
-- lane. Returned in the same order `flankingStalks` returns its sockets - the
-- first is on +lateral, the second on -lateral - so a caller pairs them by
-- position in the list and never by guessing which limb is on which side.
--
-- A bar is aimed at the FLOOR (`aimPoint`), like every other slam: the capsule
-- the server tests and the stripe the client draws are both the flat segment
-- from the socket to this point.
function NoctyssPath.doorTargets(state): (Vector3, Vector3)
	local door = NoctyssPath.DOOR
	local scale = NoctyssPath.MAW.SCALE
	local mouth = NoctyssPath.mawMouth(state)
	local _, lateral = NoctyssPath.mawFacing(state)
	local centre = (mouth * CFrame.new((door.LIP_FORWARD + door.LIP_HALF) * scale + door.AHEAD, 0, 0)).Position
	return NoctyssPath.aimPoint(state, centre + lateral * door.HALF),
		NoctyssPath.aimPoint(state, centre - lateral * door.HALF)
end

-- WHICH TWO LIMBS BAR THE DOOR: the nearest socket to the entrance lane on
-- each side THAT CAN REACH ITS OWN DOORPOST. Returns (+lateral, -lateral), or
-- nil for a side that has nobody left.
--
-- "That can reach" is doing real work and is not a guard against a rare case.
-- The sockets stand at r 34 and the doorposts land at r ~26, so the limb
-- physically closest to the lane is usually 16 studs from its post - INSIDE
-- the 14.2-stud fold the arm has, but not by enough to survive MARGIN, and at
-- some lanes inside it outright. `clampToReach` would silently walk such a
-- target outward along its own bearing and the bar would land somewhere the
-- head never chose. So the pick skips those and takes the next socket round,
-- which is 18-42 studs out and swings its bar in across the lane - which is
-- also, as it happens, the better picture: a limb reaching over the door from
-- the side, rather than one folding onto its own collar.
function NoctyssPath.flankingStalks(state): (number?, number?)
	local targetA, targetB = NoctyssPath.doorTargets(state)
	local _, lateral = NoctyssPath.mawFacing(state)
	local yaw = state.mawYaw or 0
	local order = table.create(NoctyssPath.SOCKETS)
	for index = 1, NoctyssPath.SOCKETS do
		local angle = NoctyssPath.socketAngle(index)
		table.insert(order, {
			index = index,
			-- How far off the lane it stands, unsigned: the ordering.
			off = math.abs((angle - yaw + math.pi) % TAU - math.pi),
			side = lateral:Dot(Vector3.new(math.cos(angle), 0, math.sin(angle))),
		})
	end
	table.sort(order, function(a, b)
		return a.off < b.off
	end)
	local a, b = nil, nil
	for _, entry in order do
		local stalk = state.stalks[entry.index]
		-- A limb already committed to a swing is not available to bar a door:
		-- `setAttack` would overwrite the descriptor it is mid-way through and
		-- the client would watch a scythe teleport into a slam. Skipped here
		-- rather than at the call site, so the pick can never hand back a socket
		-- the caller then has to check.
		if stalk and stalk.alive and (stalk.fall or 0) < 0.5 and not NoctyssPath.stalkBusy(state, entry.index) then
			local target = if entry.side > 0 then targetA else targetB
			local near, far = NoctyssPath.stalkReach(state, entry.index)
			local root = state.center + NoctyssPath.socketPoint(entry.index)
			local span = (target - root).Magnitude
			if span >= near + NoctyssPath.DOOR.MARGIN and span <= far - NoctyssPath.DOOR.MARGIN then
				if entry.side > 0 then
					a = a or entry.index
				else
					b = b or entry.index
				end
			end
		end
	end
	return a, b
end

-- THE V. Returns (indexA, indexB, targetA, targetB): the two ADJACENT sockets
-- nearest `playerPos`, and the two points on the rim their bars converge on.
--
-- Adjacent because a V has to have a mouth: two limbs on opposite sides of the
-- ring would draw two unrelated stripes with the whole arena between them, and
-- nobody would read a funnel out of that. The pair is chosen by the sum of the
-- flat distances to the player, over the seven neighbouring pairs, so it is a
-- pure function of where they are standing - and a dead limb simply takes its
-- two pairs out of the running.
--
-- The targets go through `clampToReach`, which at these distances is a no-op -
-- but it is the same clamp `setAttack` will apply, so what this returns IS
-- what gets latched, drawn and tested. A caller that adjusted them afterwards
-- would be drawing a V the limbs then miss.
function NoctyssPath.herdTargets(state, playerPos: Vector3): (number?, number?, Vector3?, Vector3?)
	local bestA, bestB, bestScore = nil, nil, math.huge
	for index = 1, NoctyssPath.SOCKETS do
		local other = index % NoctyssPath.SOCKETS + 1
		local one, two = state.stalks[index], state.stalks[other]
		-- Both must be free, for the same reason `flankingStalks` checks it: a
		-- V drawn with a limb that is already swinging elsewhere is half a V.
		if
			one
			and two
			and one.alive
			and two.alive
			and not NoctyssPath.stalkBusy(state, index)
			and not NoctyssPath.stalkBusy(state, other)
		then
			local pa = state.center + NoctyssPath.socketPoint(index)
			local pb = state.center + NoctyssPath.socketPoint(other)
			local score = Vector3.new(pa.X - playerPos.X, 0, pa.Z - playerPos.Z).Magnitude
				+ Vector3.new(pb.X - playerPos.X, 0, pb.Z - playerPos.Z).Magnitude
			if score < bestScore then
				bestA, bestB, bestScore = index, other, score
			end
		end
	end
	if not bestA or not bestB then
		return nil, nil, nil, nil
	end
	-- The apex: on the rim, on the bearing between the two collars. Taken as a
	-- half-step from A's bearing rather than as an average of two angles, which
	-- would point at the far side of the arena for the pair that straddles the
	-- wrap.
	local angleA = NoctyssPath.socketAngle(bestA)
	local angleB = NoctyssPath.socketAngle(bestB)
	local mid = angleA + ((angleB - angleA + math.pi) % TAU - math.pi) * 0.5
	local out = Vector3.new(math.cos(mid), 0, math.sin(mid))
	local across = Vector3.new(0, 1, 0):Cross(out)
	local apex = state.center + out * NoctyssPath.PIT_R
	-- Each tip is set off the apex toward ITS OWN socket's side, so the two
	-- stripes cross the floor as a V and not as an X.
	local sideA = across:Dot(Vector3.new(math.cos(angleA), 0, math.sin(angleA)))
	local sign = if sideA > 0 then 1 else -1
	local targetA = NoctyssPath.aimPoint(state, apex + across * (NoctyssPath.HERD.SPREAD * sign))
	local targetB = NoctyssPath.aimPoint(state, apex - across * (NoctyssPath.HERD.SPREAD * sign))
	return bestA, bestB, clampToReach(state, bestA, targetA), clampToReach(state, bestB, targetB)
end

-- WHERE THE SNAP IS IN ITS OWN LIFE, from nothing but `snapStart` and a clock -
-- the same contract `attackPhase` runs the limbs on. Returns
-- ("rise" | "bite" | "sink" | "done", 0..1).
function NoctyssPath.snapPhase(snapStart: number, now: number): (string, number)
	local snap = NoctyssPath.SNAP
	local t = now - (snapStart or 0)
	if t <= 0 then
		return "rise", 0
	end
	if t < snap.RISE then
		return "rise", t / snap.RISE
	end
	t -= snap.RISE
	if t < snap.BITE then
		return "bite", t / snap.BITE
	end
	t -= snap.BITE
	if t < snap.SINK then
		return "sink", t / snap.SINK
	end
	return "done", 1
end

function NoctyssPath.snapDuration(): number
	return NoctyssPath.SNAP.RISE + NoctyssPath.SNAP.BITE + NoctyssPath.SNAP.SINK
end

-- `tellPhase`, for the one move that belongs to the head rather than to a
-- socket. The rise IS the lead-in, the bite IS the live window, and the sink
-- is the fade - so the rim ring runs the same ramp as every limb mark in the
-- fight off the same three numbers. Feed the result to `NoctyssPath.tellRamp`
-- with TELL.HEAD.
function NoctyssPath.snapTell(snapStart: number, now: number): (number, boolean, number?)
	local snap = NoctyssPath.SNAP
	local t = now - (snapStart or 0)
	if t < snap.RISE then
		return math.clamp(t / math.max(snap.RISE, 1e-3), 0, 1), false, nil
	end
	if t <= snap.RISE + snap.BITE then
		return 1, true, t - snap.RISE
	end
	return 1, false, t - (snap.RISE + snap.BITE)
end

-- HOW FAR UP SHE IS DURING A SNAP, 0..SNAP.RISE_TO. The SERVER publishes this
-- as the maw-rise attribute every frame of a snap (the client eases toward it
-- exactly as it does during the punish window, so no new replication and no
-- new easing rule); anything that needs the number without an attribute -
-- another server system, a test - reads it here rather than re-deriving the
-- curve. Eased up, held flat across the bite so the jaws close on a head that
-- is holding still, and eased back down.
function NoctyssPath.snapRise(snapStart: number, now: number): number
	local phase, u = NoctyssPath.snapPhase(snapStart, now)
	local top = NoctyssPath.SNAP.RISE_TO
	if phase == "rise" then
		return top * smoothstep(u)
	elseif phase == "bite" then
		return top
	elseif phase == "sink" then
		return top * (1 - smoothstep(u))
	end
	return 0
end

-- THE SNAP'S HITBOX: the pit disc plus a lip, and ONLY during the bite.
--
-- Flat, like the scythe's, because there is no jumping this: the fangs come up
-- out of the floor the player is standing on. The height band is generous
-- downward (anyone who has fallen in is in the mouth by definition) and up
-- (the tongue's floor sits a stud over the shelf, and a jump is not a dodge).
--
-- `snapStart` is passed rather than read off the state, so the same call
-- answers for a snap the caller is holding a descriptor for and for one it is
-- simulating - and so this is a pure function of its arguments, which is what
-- lets the client draw the exact ring the server is about to test.
function NoctyssPath.snapHits(state, position: Vector3, pad: number?, now: number, snapStart: number): boolean
	local snap = NoctyssPath.SNAP
	local t = now - (snapStart or 0)
	if t < snap.RISE or t > snap.RISE + snap.BITE then
		return false
	end
	if not onTheFloor(state, position, 9, 16) then
		return false
	end
	local to = Vector3.new(position.X - state.center.X, 0, position.Z - state.center.Z)
	return to.Magnitude <= NoctyssPath.PIT_R + snap.MARGIN + (pad or 0)
end

-- ARM A SNAP. The mirror of `setAttack` for the one move that belongs to the
-- head rather than to a socket: the server calls it and fires the same table
-- down Remotes.ChoirAttack, the client calls it with what arrives.
--
--   { kind = "herdingsnap", index = 0, start = number, target = Vector3 }
--
-- `index` is 0 and `target` is the pit's centre - both only so the descriptor
-- passes the same wire validation every other one does. Nothing reads them:
-- the disc is `state.center` and the timing is `start`.
function NoctyssPath.setSnap(state, snap)
	if not snap or snap.kind ~= "herdingsnap" then
		return nil
	end
	snap.start = snap.start or NoctyssPath.clock()
	state.snap = snap
	return snap
end

-- The snap that is still running, or nil - retiring it here, like `attackFor`
-- does for a limb, so no caller has to remember to.
function NoctyssPath.snapFor(state, now: number?)
	local snap = state.snap
	if not snap then
		return nil
	end
	if (now or state.time or 0) - (snap.start or 0) >= NoctyssPath.snapDuration() then
		state.snap = nil
		return nil
	end
	return snap
end

return NoctyssPath
