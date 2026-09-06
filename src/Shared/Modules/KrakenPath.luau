--!nonstrict
-- KrakenPath.luau
-- The shape of the Kraken: one domed head parked in the middle of the
-- whirlpool, and eight arms leaving its crown.
--
-- Companion to BrinejawPath, and the same contract: PURE MATH, no Instances,
-- no state of its own. The server publishes a handful of numbers, both sides
-- run these functions off them, and the arm you dodge is the arm you see.
--
-- The difference from Brinejaw is what a "chain" means here. Brinejaw is ONE
-- body on one curve. The Kraken is eight independent curves that all start at
-- the same crown, so every arm carries its own state table (which IS the
-- ChainPose shape state) and they never talk to each other.
--
-- WHY THE ARMS ARE BOUND TO THE TENTACLE ROW: the fight spawns `parts.count`
-- kraken_tentacle creatures on a ring - those are the things you actually
-- hit. Rather than draw a separate monster at each one, each arm REACHES its
-- tentacle: t=0 is welded in the crown socket, t=1 lands on the tentacle's
-- hitbox. One octopus, eight targets, and no arm that points at nothing.

local KrakenPath = {}

-- ---------------------------------------------------------------- the mesh
-- Every number here is measured off the authored model (assets/boss_gen.py,
-- build_kraken) at scale 1, so a drawn arm leaves the socket the modelled
-- crown was actually cut for. Change the mesh, change these.
KrakenPath.HEAD_HEIGHT = 46.2 -- crown (z=0) to the top of the mantle
KrakenPath.HEAD_HALF_WIDTH = 19.8 -- the widest ring, at z = 14.5
KrakenPath.SOCKET_RADIUS = 18.2 -- the eight arm sockets' circle
KrakenPath.SOCKET_HEIGHT = -2.0 -- and how far below the crown they sit
KrakenPath.SEG_LENGTH = 5.4 -- one authored arm segment, tip to tip
KrakenPath.SEG_SPACING = 2.6 -- and the pitch they were authored to overlap at
-- How far an arm drops as it leaves the socket, before it starts to climb.
-- An arm has to come out from UNDER the mantle skirt; one that starts rising
-- immediately grows out of the head's cheek instead.
--
-- SCALED TO THE IN-GAME SPAN, which is the trap here. The authored pose in
-- boss_gen.py reaches 82 studs from an 18-stud socket - 64 studs of radial
-- room. In the fight the arm only has to get from the socket at 25.5 out to
-- the tentacle ring at 46, which is TWENTY. Numbers copied across from the
-- render without rescaling turn a sprawling arm into a vertical fountain.
--
-- THE ENVELOPE, not just the number. This used to ride a half-sine BUMP that
-- came back to zero at u = 0.16 - the arm dove the full drop and then
-- hairpinned straight back up inside 4 studs of radial travel, which is not
-- a skirt, it is a fold. The authored reference (_kraken_arm_path) uses a
-- SUSTAINED drop instead: down, HELD along the shoulder, released slowly.
-- armPoint now does the same - a smoothstep in over the first 16% of the
-- arm, then a (1-u)^2 release that reaches exactly zero at the tip, because
-- in the fight (unlike the render) the tip has to land ON its tentacle.
--
-- 3.0, MEASURED AGAINST THE MANTLE IT HAS TO CLEAR, not chosen for drama.
-- The socket ring sits at r = 25.5 and the crown's widest ring at 27.4, so
-- an arm has about 2 studs of overhang to get out from under; the envelope
-- holds 2.1 studs of drop at u = 0.16 and is still 1.1 down at u = 0.40.
-- The old 5.5 bought no more clearance and cost the whole bend.
--
-- THE RULE THIS IS MEASURED AGAINST is local, not a single global number: at
-- every u the centreline's radius of curvature must beat the arm's OWN girth
-- radius there, with 10% margin. A limb folds through itself exactly when it
-- bends tighter than its own half-thickness, and this arm tapers - the drawn
-- half-thickness is (8.6 / 2) * SCALE * (1 - TIP_GIRTH * u), 6.02 studs at
-- the shoulder down to 2.89 at the tip - so the bound tapers with it.
--
-- VERIFIED (4000 samples of r(u) vs y(u), both poses, worst R / 1.1*girth):
--   BOUND   (ring 46->50, hump 13->9, tipY -9): 0.016 -> 0.406  FAILS
--   RESTING (36,7,-16 -> 48,3.50,-14)         : 0.010 -> 1.002  PASSES
-- with max pitch |dy/ds| down from 0.989 (81.6 deg) to 0.909 (65.3) at BOUND
-- and 0.996 (84.6) to 0.793 (52.4) at RESTING. Both endpoints stay exact:
-- y(0) = SOCKET_HEIGHT * SCALE and y(1) = tipY to float precision.
--
-- THE IDLE ARM CLEARS THE BOUND; THE BOUND ARM DOES NOT, and the difference
-- is the only honest summary of this whole term. RESTING was free to be
-- reshaped until it passed, because it is just where a dead arm rests. BOUND
-- is pinned by things that are not ours - the tentacle ring is where the
-- fight is staged, the tip height is the waterline, and the arch has to read
-- as an arch - so it sits at 0.41 of the bound and its crest self-intersects
-- by design. See the BOUND comment in KrakenBodyController for the ceiling
-- arithmetic and for what would actually close it. Nothing tunable HERE
-- does: this term is out of the binding position now and raising or lowering
-- SKIRT_DROP moves the BOUND ratio by less than 0.02 either way.
KrakenPath.SKIRT_DROP = 3.0

-- How big it is drawn. The arena is 34 studs to the platforms, and the brief
-- is that the head fills the middle of it: 19.8 x 1.4 = 27.7 studs of half-
-- width, standing 65 studs out of the water. You do not shoot over this.
KrakenPath.SCALE = 1.4

KrakenPath.ARM_COUNT = 8

-- The crown rides this far above the waterline once it is fully up.
--
-- The old intent still holds - the arms have to come off the crown INTO the
-- water rather than hanging over it - but that job now belongs to the skirt
-- term in armPoint, which dives the arm out from under the mantle whatever
-- the lift is. So this number is no longer set by the arms at all.
--
-- IT IS SET BY THE BEAK'S WATERLINE. The beak was rebuilt as two parted
-- mandibles hanging under the crown's +X rim, spanning mesh z = +1.5 down to
-- -14.5. At the old lift of 5.0 the surface cut the mesh at z = -3.6, which
-- put the whole lower mandible underwater: from the rocks you saw one fang
-- and no mouth, which is precisely what the rebuild was for. At 9.0 the
-- waterline sits at z = -7.6, below the parting line, so the jaws read as
-- open and only the hook tips stay wet - a mouth breaking the surface.
KrakenPath.CROWN_LIFT = 9.0
-- And this far under while it is still rising.
KrakenPath.RISE_DEPTH = 46.0

-- WHICH WAY THE HEAD LOOKS, once and for all. This is the world bearing of
-- the landing and the centre of the tentacle arc; the authored mesh faces
-- +X, so this one fixed yaw turns the eyes and the beak toward the only side
-- the fight ever happens on.
KrakenPath.FACING = math.pi / 2

-- ---------------------------------------------------------------- head

function KrakenPath.newState(center: Vector3)
	return {
		center = center,
		time = 0,
		rise = 0, -- 0 = under the whirlpool, 1 = fully up
		-- Replicated and eased, but NOT what the drawn head is turned by -
		-- see headCFrame. Kept because the server aims with it and the field
		-- is part of the published state.
		faceAngle = 0,
	}
end

-- How far the whole animal is lifted this frame. Shared by the head and by
-- every arm, so a rising Kraken brings its arms up with it instead of
-- leaving them floating where the crown used to be.
function KrakenPath.lift(state): number
	local rise = math.clamp(state.rise or 1, 0, 1)
	return KrakenPath.CROWN_LIFT - KrakenPath.RISE_DEPTH * (1 - rise)
end

-- The head's frame: +X points where it is facing, the pack convention.
-- Sits at the crown, because that is where the mesh's origin is - the dome
-- is built upward from z=0 and the sockets hang just under it.
function KrakenPath.headCFrame(state): CFrame
	local c = state.center
	-- A slow swell so a waiting Kraken is never a statue.
	local swell = math.sin((state.time or 0) * 0.7) * 0.8
	local at = Vector3.new(c.X, c.Y + KrakenPath.lift(state) + swell, c.Z)
	-- STATIONARY, on purpose, and NOT off `state.faceAngle`.
	--
	-- FaceAngle is still replicated and still meant something: the server aims
	-- the beak and the ringwave with it. What it must not do is turn the
	-- DRAWN head. The eight arm sockets are CARVED INTO the crown mesh at
	-- fixed bearings, while the arms themselves are drawn in world space to
	-- wherever the tentacles stand - so a head that yawed slid its own carved
	-- sockets out from under the arms that are supposed to be growing from
	-- them, and eight limbs floated off the shoulders they were welded into.
	--
	-- With the ring on one 206-degree arc there is nothing left to track
	-- anyway: the fight only ever happens on one side of the animal, and a
	-- head parked facing it is looking at the party the whole time.
	return CFrame.new(at) * CFrame.Angles(0, -KrakenPath.FACING, 0)
end

-- WHERE THE EIGHT TENTACLES STAND, as bearings around the arena centre, in
-- ascending order - a 206-degree arc centred on +90 degrees (+Z), which is
-- the player landing. The wide gap in the middle of the list is the arc's
-- back, where nothing stands.
--
-- SEEDS ONLY, and the distinction matters. `Bosses.items.kraken.parts` on
-- the server is AUTHORITATIVE for where tentacles actually stand, and the
-- client claims an arm to a tentacle by that tentacle's SocketIndex
-- attribute, never by comparing against this table. All these bearings
-- decide is where an UNCLAIMED arm rests - the drape an arm falls into while
-- its tentacle is dead and the ring is regrowing. So if the two tables ever
-- drift apart the cost is a resting arm pointing somewhere slightly odd for
-- a few seconds, and never an arm welded to the wrong shoulder.
KrakenPath.SOCKET_BEARINGS = {
	math.rad(-13),
	math.rad(13),
	math.rad(39),
	math.rad(65),
	math.rad(115),
	math.rad(141),
	math.rad(167),
	math.rad(193),
}

-- Where socket `index` (1..count) sits on the crown, in world space.
--
-- Reads SOCKET_BEARINGS, because the ring is no longer a ring: it is the arc
-- above, and the even `(index / count) * 2pi` this used to return put two of
-- the eight resting arms out behind the head where no tentacle has stood
-- since. The even spacing survives only as the fallback for an index outside
-- the table, so a `count` that outgrows the authored arc still spreads its
-- extra arms somewhere rather than piling them all on bearing zero.
function KrakenPath.socketAngle(index: number, count: number): number
	local bearing = KrakenPath.SOCKET_BEARINGS[index]
	if bearing then
		return bearing
	end
	return (index / (count or KrakenPath.ARM_COUNT)) * math.pi * 2
end

function KrakenPath.socketPosition(state, index: number, count: number): Vector3
	local angle = KrakenPath.socketAngle(index, count)
	local c, r = state.center, KrakenPath.SOCKET_RADIUS * KrakenPath.SCALE
	return Vector3.new(
		c.X + math.cos(angle) * r,
		c.Y + KrakenPath.lift(state) + KrakenPath.SOCKET_HEIGHT * KrakenPath.SCALE,
		c.Z + math.sin(angle) * r
	)
end

-- ---------------------------------------------------------------- arms

-- One arm's state. This table IS the ChainPose shape state, so the renderer
-- mutates it in place every frame and never reallocates.
--   angle    - the socket's bearing; where the arm leaves the crown
--   reach    - horizontal studs from the arena centre to the arm's tip
--   tipY     - the tip's height relative to the crown socket
--   hump     - how high it arches on the way out (0 = a straight drape)
--   wave     - lateral sway, radians, biggest mid-arm
--   phase    - per-arm offset so eight arms never move as one
function KrakenPath.newArm(state, index: number, count: number)
	return {
		center = state.center,
		time = 0,
		lift = 0,
		angle = KrakenPath.socketAngle(index, count),
		reach = KrakenPath.SOCKET_RADIUS * KrakenPath.SCALE + 18,
		tipY = -6,
		hump = 7,
		wave = 0.10,
		breathe = 1.6,
		phase = index * 2.399, -- golden-angle-ish: no two arms in step
	}
end

-- The curve, t = 0 in the socket to t = 1 at the tip.
--
-- Three terms, and each one is zero at the socket ON PURPOSE - the arm can
-- swing, arch and breathe as much as it likes without ever tearing out of
-- the crown it is welded into.
function KrakenPath.armPoint(arm, t: number): Vector3
	local u = math.clamp(t, 0, 1)
	-- Segments bunch slightly toward the body, where the arm is thickest.
	local e = u ^ 0.92
	local socketR = KrakenPath.SOCKET_RADIUS * KrakenPath.SCALE
	local socketY = KrakenPath.SOCKET_HEIGHT * KrakenPath.SCALE

	-- 0 at both ends, 1 in the middle: the envelope every free term rides,
	-- which is what pins t=0 to the socket and t=1 to the tentacle.
	local bump = 4 * u * (1 - u)
	-- The arch, held off until the arm is clear of the head, and the dip that
	-- takes it there. Both are zero at u=0 and u=1 like everything else here,
	-- so the arm still starts in its socket and still ends on its tentacle.
	local climb = math.clamp((u - 0.14) / 0.86, 0, 1)
	-- The arch is EASED ON. `climb` used to enter the sine as a raw ramp, so
	-- at u = 0.14 the arm's height picked up a slope of pi * hump / 0.86 -
	-- 47 studs per unit u at BOUND - out of nothing at all: a hard crease two
	-- segments out of the socket, which is exactly where the shoulder blob
	-- was. Measured, that corner alone pinned the tightest bend radius at
	-- 0.007 studs against a limb 12 studs thick.
	--
	-- The window is the WHOLE climb: the ramp is smoothstepped end to end, so
	-- the arch eases on out of the socket and eases off onto the tip, and
	-- there is no corner anywhere on it.
	--
	-- 1.00, MEASURED, and it has moved twice - 0.20, then 0.50, now 1.00 - so
	-- the reasoning matters more than the number. A NARROW window does not
	-- remove the corner at u = 0.14 so much as compress it: the smoothstep's
	-- own second derivative goes as 1/window^2, so the crease just becomes a
	-- shorter, sharper crease. A WIDE window spreads that out but steepens
	-- the arch's DESCENT, moving the tightest bend to u ~ 0.71. Which of the
	-- two costs more depends on the radial span, which is why this changed
	-- when `parts.ring` went 46 -> 50: at the old span the descent was the
	-- worse of the two and 0.50 won; at the new one the span has bought the
	-- descent enough room that killing the corner outright wins instead.
	-- Re-measure this if the ring moves again.
	local onset = math.clamp(climb / 1.00, 0, 1)
	climb = climb * onset * onset * (3 - 2 * onset)
	local arch = math.sin(climb * math.pi) * arm.hump
	-- The skirt, as a SUSTAINED drop rather than a bump: smoothstep down over
	-- the first 40% of the arm (zero value AND zero slope at both ends of
	-- that window, so there is no corner where it finishes), then a slow
	-- (1-u)^2 release.
	--
	-- 0.40 and not the 0.16 the authored render uses. The render's knee is at
	-- 0.16 of an arm with 64 studs of radial room; ours has 24.5, so the same
	-- fraction is a quarter of the travel and the smoothstep's second
	-- derivative - which goes as 1/knee^2 - was the single tightest bend on
	-- the whole arm, pinning it at 0.87 studs no matter what the arch did.
	-- Widening to 0.40 costs the drop most of its depth (2.1 studs of shelf
	-- down to 1.2) and is still worth it: it takes the skirt out of the
	-- binding position entirely and hands the constraint back to the arch.
	--
	-- THE EXPONENT IS 2 AND MUST STAY 2. At 1.5 the second derivative
	-- diverges as u -> 1, which puts a curvature singularity on the tip - the
	-- one place on the arm that has to sit still on its tentacle. That is not
	-- theoretical: 1.5 scores fine at 4000 samples and FAILS the girth bound
	-- at 0.424 when the last 1.5% of the arm is sampled at 200k, because the
	-- blow-up is too narrow for a coarse sweep to land on.
	local q = math.min(u / 0.40, 1)
	local skirt = -KrakenPath.SKIRT_DROP * (q * q * (3 - 2 * q)) * (1 - u) ^ 2

	local radius = socketR + (arm.reach - socketR) * e
	local height = socketY
		+ (arm.tipY - socketY) * e
		+ arch
		+ skirt
		+ bump * math.sin(arm.time * 1.3 + arm.phase + u * 3.0) * arm.breathe
	local angle = arm.angle + bump * arm.wave * math.sin(arm.time * 0.9 + arm.phase)

	local c = arm.center
	return Vector3.new(c.X + math.cos(angle) * radius, c.Y + arm.lift + height, c.Z + math.sin(angle) * radius)
end

return KrakenPath
