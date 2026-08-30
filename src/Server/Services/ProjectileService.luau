--!nonstrict
-- ProjectileService.luau
-- Server-authoritative bullet simulation, built for Admiral Wrack's bullet
-- hell (the Careenage). Wrack is a static gun platform: he never approaches,
-- he shoots, and the fight is the DODGE. That needs hundreds of cheap moving
-- hazards a frame, which is one thing CreatureService's arsenal never had.
--
-- It is the `lures` timed system with velocity: a flat array of plain tables
-- carrying position + velocity + radius + damage + lifetime, advanced by one
-- Heartbeat, tested against player roots on flat XZ distance (the lure
-- trigger's idiom), damaged through the same PlayerService.damage path every
-- boss AoE already uses, and retired on hit / expiry / leaving the arena.
--
-- Lives OUTSIDE CreatureService on purpose (that file is 5.3k lines and shared
-- by three lanes). It requires nothing from CreatureService, so there is no
-- cycle: the attack handlers over there call in, never the reverse.
--
-- ============================================================================
-- THE CLIENT CONTRACT  (the rendering lane codes against exactly this)
-- ============================================================================
-- Everything rides the EXISTING `CreatureEvent` remote through
-- Hazards.fireEvent(kind, position, extra) - no new Remote. Three kinds. A
-- broadside is dozens of balls, so each `emit` fires ONE event for the whole
-- volley; nothing here is ever one-event-per-bullet.
--
-- (1) kind = "wrackVolley"   - a volley was born.
--     position : Vector3  the muzzle (boss pivot). Draw the flash here.
--     extra = {
--       id     : number   volley id, unique for the server's lifetime.
--       skin   : string   "cannon" | "grape" | "chain" | "wisp" | "anchor".
--       y      : number   world Y of the flight plane. Every ball in the
--                         volley flies flat at this height, forever.
--       life   : number   seconds until the LAST ball of the volley expires;
--                         safe to cull the whole volley after it.
--       accel  : number?  studs/s^2 along each ball's own heading (nil = 0,
--                         constant speed). Position = p0 + v*t + a*t^2/2 * v^.
--       sync   : boolean? true  -> the server streams "wrackShots" for this
--                         volley (homing wisps, spinning chains); follow the
--                         stream and interpolate, do NOT dead-reckon.
--                         false/nil -> pure ballistic, dead-reckon it and
--                         expect no stream at all.
--       spin   : number?  rad/s the linked pairs rotate about their midpoint
--                         (chainshot only; informational - `sync` is truth).
--       shots  : { { sid, x, z, r } }  one array per ball:
--                         sid : number  shot id, unique WITHIN this volley.
--                         x,z : number  spawn position on the `y` plane.
--                         vx,vz: number velocity, studs/s (indices 4,5).
--                         r   : number  hit radius in studs (index 6); draw
--                         the ball about this size so what you see is what
--                         kills you.
--                 -> the array is { sid, x, z, vx, vz, r }, 6 numbers.
--       links  : { { sidA, sidB, r } }?  chainshot pairs. Draw a chain of
--                         radius `r` between the two balls; THE CHAIN IS THE
--                         HITBOX and the gap between a pair is a trap, so it
--                         must be drawn, at `r` and not at a hardcoded guess.
--     }
--
-- (2) kind = "wrackShots"    - low-cadence truth for `sync` volleys (~4.5/s).
--     position : Vector3  the arena centre (the channel needs one; unused).
--     extra = { id = <volley id>, shots = { { sid, x, z } } }
--     Balls not listed in a stream have already been retired.
--
-- (3) kind = "wrackPop"      - balls retired this frame, batched per volley.
--     position : Vector3  a representative retirement point (burst origin).
--     extra = { id = <volley id>, hit = { sid, ... }, gone = { sid, ... } }
--       hit  : struck a player  -> impact burst + hit sound.
--       gone : expired or left the arena -> quiet fizzle.
--     Either list may be empty. A volley whose balls are never popped
--     individually still gets a `gone` event when they time out.
--
-- Skins map to Wrack's six patterns: broadside -> "cannon", grapeshot ->
-- "grape", chainshot -> "chain", slewfire -> "cannon", wisps -> "wisp",
-- anchorsweep -> "anchor". Every one is set from the attack row's `p.skin`,
-- so a new pattern needs no client change beyond a new skin case.
-- ============================================================================

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local World = require(Shared.Config.World)

local Hazards = require(script.Parent.Parent.Modules.Hazards)
local PlayerService = require(script.Parent.PlayerService)

local ProjectileService = {}

-- ============================================================ tuning

-- The hard cap. A phase-3 Wrack with every pattern overlapping peaks around
-- 140 live balls; 320 is double that, so the cap is a backstop against a bug
-- (or a zombie owner), never a thing the fight bumps into. Oldest retires
-- first: the wall you already dodged dies before the one still coming at you.
local MAX_LIVE = 320

-- Flight plane, above World.WATER_Y. The Careenage's sand sits z ~0.7-1.5
-- above the waterline, so a root part is ~3.5-4.5 up; 3.0 puts the balls at
-- chest height on the flat.
local FLIGHT_Y = 3.0

-- Vertical reach of a ball. Generous on purpose, and the same judgement as
-- CreatureService's BOSS_HEIGHT_TOLERANCE: a hitbox that misses because the
-- shoal dishes, or because the player climbed a breakwater hulk, would make
-- the fight feel broken and would make hulk-camping a free win. Camping one
-- spot is supposed to lose.
local HEIGHT_TOLERANCE = 12

-- Position stream for homing/linked volleys. 0.22s is the lure system's
-- `decoyMove` cadence (0.3s) tightened a little, because a wisp that has
-- latched onto you has to read as latched onto you.
local SYNC_EVERY = 0.22

-- Nothing lives longer than this regardless of what a row asks for.
local MAX_LIFETIME = 16

-- ============================================================ state

local live = {} -- flat array of bullet tables, oldest first
local nextVolleyId = 0
local lastSyncAt = 0
local popbox = {} -- [volleyId] = { at = Vector3, hit = { sid }, gone = { sid } }
local popPending = false
local connection = nil

-- ============================================================ helpers

local function flatDist(ax: number, az: number, bx: number, bz: number): number
	local dx, dz = ax - bx, az - bz
	return math.sqrt(dx * dx + dz * dz)
end

-- Flat XZ distance from a point to the segment AB - the chainshot hitbox.
-- The chain between a pair is the thing that kills, so the pair's gap has to
-- be tested as a line, not as two circles with a hole between them.
local function segDistFlat(px: number, pz: number, ax: number, az: number, bx: number, bz: number): number
	local abx, abz = bx - ax, bz - az
	local len2 = abx * abx + abz * abz
	local t = 0
	if len2 > 1e-6 then
		t = math.clamp(((px - ax) * abx + (pz - az) * abz) / len2, 0, 1)
	end
	return flatDist(px, pz, ax + abx * t, az + abz * t)
end

local function rotateFlat(v: Vector3, angle: number): Vector3
	local c, s = math.cos(angle), math.sin(angle)
	return Vector3.new(v.X * c - v.Z * s, 0, v.X * s + v.Z * c)
end

local function bearing(angle: number): Vector3
	return Vector3.new(math.cos(angle), 0, math.sin(angle))
end

local function flatUnit(v: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 0.001 then f.Unit else Vector3.xAxis
end

-- Every living player's root, gathered once per tick rather than per bullet.
local function livingRoots(): { { player: Player, root: BasePart } }
	local out = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid and humanoid.Health > 0 then
			table.insert(out, { player = player, root = root })
		end
	end
	return out
end

-- THE DEFENSIVE LIFETIME RULE. `dead` alone is not enough: BossService's
-- abandon reaper Destroys the boss model without ever setting `dead`, and the
-- struct keeps ticking as an invisible zombie. A zombie Wrack must not be
-- able to keep a bullet alive - or spawn one - so the owner is gone the
-- moment its model leaves the DataModel, whatever the flag says.
local function ownerGone(owner): boolean
	if type(owner) ~= "table" then
		return true
	end
	if owner.dead then
		return true
	end
	local model = owner.model
	return model == nil or model.Parent == nil
end

-- ============================================================ retirement

local function notePop(bullet, hit: boolean)
	local entry = popbox[bullet.volley]
	if not entry then
		entry = { at = bullet.pos, hit = {}, gone = {} }
		popbox[bullet.volley] = entry
	end
	if hit then
		entry.at = bullet.pos
		table.insert(entry.hit, bullet.sid)
	else
		table.insert(entry.gone, bullet.sid)
	end
	popPending = true
end

-- Retirement is MARK-AND-SWEEP, and deliberately not remove-in-place. A chain
-- pair has to retire as a unit - half a chainshot is not a thing - and the
-- partner can sit ANYWHERE in the array, including below the backward walk's
-- cursor. Removing it there shifts every element above it, which both skips a
-- live bullet and can walk the loop off the end of the array into a nil. So
-- retiring only ever sets a flag; compact() does the single pass that shrinks.
local function retire(bullet, hit: boolean)
	if not bullet or bullet.retired then
		return
	end
	bullet.retired = true
	notePop(bullet, hit)
	local partner = bullet.link
	if partner and not partner.retired then
		partner.retired = true
		notePop(partner, hit)
	end
end

-- Drops every marked bullet in one pass, preserving oldest-first order (the
-- cap below depends on that order meaning what it says).
local function compact()
	local n = 0
	for i = 1, #live do
		local bullet = live[i]
		if not bullet.retired then
			n += 1
			live[n] = bullet
		end
	end
	for i = #live, n + 1, -1 do
		live[i] = nil
	end
end

-- The hard cap, oldest first: the wall you already dodged dies before the one
-- still coming at you. Retiring a chain lead takes its partner too, so this
-- can free one more than it counted - which is correct, not a miscount.
local function enforceCap()
	local excess = #live - MAX_LIVE
	if excess <= 0 then
		return
	end
	for i = 1, #live do
		if excess <= 0 then
			break
		end
		local bullet = live[i]
		if not bullet.retired then
			retire(bullet, false)
			excess -= 1
		end
	end
	compact()
end

local function flushPops()
	if not popPending then
		return
	end
	popPending = false
	for id, entry in popbox do
		Hazards.fireEvent("wrackPop", entry.at, { id = id, hit = entry.hit, gone = entry.gone })
	end
	table.clear(popbox)
end

-- ============================================================ the tick

-- ============================================================ the death beat
--
-- A PLAIN boss's death is the model being destroyed - no fall, no beat. The
-- collapse path ("a colossus does not blink out where it stands") is reached
-- only by a boss that is HOLDING a perch, and Wrack is not one, so without
-- this he would simply wink out on the killing blow after several minutes of
-- dodging. That is an anticlimax the fight can afford to fix cheaply.
--
-- So the fight authors its own closing beat out of what it already has: the
-- four gun decks going up one at a time, then the hull settling into the
-- flat. Every event here is one the client already renders ("explode",
-- "splash"), so it costs the rendering lane nothing, and it runs off this
-- same Heartbeat rather than task.delay so nothing is left half-played if the
-- fight ends underneath it.
local watched = {} -- [owner] = { centre, ring, count, skin }
local wrecks = {} -- death beats currently playing

-- Registered by the first volley an owner fires, so nothing has to hook kill().
function ProjectileService.watch(owner, centre: Vector3, ring: number, count: number, skin: string)
	if watched[owner] == nil and not ownerGone(owner) then
		watched[owner] = { centre = centre, ring = ring, count = count, skin = skin }
	end
end

local function beginWreck(spec)
	local beats = {}
	local n = math.max(1, spec.count)
	for i = 1, n do
		-- One gun deck at a time, around the ring they stood on.
		local a = (i / n) * math.pi * 2
		table.insert(beats, {
			at = (i - 1) * 0.16,
			kind = "explode",
			pos = spec.centre + Vector3.new(math.cos(a) * spec.ring, 2, math.sin(a) * spec.ring),
			extra = { radius = 7, skin = spec.skin },
		})
	end
	-- Then the hull: a settle, the magazine, and the water closing over it.
	local tail = n * 0.16
	table.insert(beats, { at = tail + 0.22, kind = "splash", pos = spec.centre, extra = { radius = 16 } })
	table.insert(beats, {
		at = tail + 0.47,
		kind = "explode",
		pos = spec.centre + Vector3.new(0, 3, 0),
		extra = { radius = 18, skin = spec.skin },
	})
	table.insert(beats, { at = tail + 0.8, kind = "splash", pos = spec.centre, extra = { radius = 26 } })
	table.insert(wrecks, { beats = beats, start = os.clock(), index = 1 })
end

local function updateWrecks(now: number)
	for owner, spec in watched do
		if ownerGone(owner) then
			watched[owner] = nil
			beginWreck(spec)
		end
	end
	for i = #wrecks, 1, -1 do
		local w = wrecks[i]
		while w.index <= #w.beats and now - w.start >= w.beats[w.index].at do
			local beat = w.beats[w.index]
			Hazards.fireEvent(beat.kind, beat.pos, beat.extra)
			w.index += 1
		end
		if w.index > #w.beats then
			table.remove(wrecks, i)
		end
	end
end

local function syncVolleys(now: number)
	if now - lastSyncAt < SYNC_EVERY then
		return
	end
	lastSyncAt = now
	local byVolley = nil
	for _, bullet in live do
		if bullet.sync then
			byVolley = byVolley or {}
			local list = byVolley[bullet.volley]
			if not list then
				list = { centre = bullet.centre, shots = {} }
				byVolley[bullet.volley] = list
			end
			table.insert(list.shots, { bullet.sid, bullet.pos.X, bullet.pos.Z })
		end
	end
	if not byVolley then
		return
	end
	for id, list in byVolley do
		Hazards.fireEvent("wrackShots", list.centre, { id = id, shots = list.shots })
	end
end

local function tick(dt: number)
	local now = os.clock()
	-- Before the early-out: a boss can die with nothing in the air, and his
	-- closing beat still has to play.
	updateWrecks(now)
	if #live == 0 then
		flushPops()
		return
	end
	local roots = livingRoots()

	for i = #live, 1, -1 do
		local bullet = live[i]
		-- Marked earlier this frame (a chain partner, or the cap) - it is
		-- already accounted for and must not integrate or damage again.
		if bullet == nil or bullet.retired then
			continue
		end

		if ownerGone(bullet.owner) then
			retire(bullet, false)
			continue
		end

		-- ---- integrate
		if bullet.follower then
			-- Driven by its chain partner (the lead owns the pair's motion),
			-- so it only exists here to be synced, capped and retired.
			continue
		end

		if bullet.homing > 0 then
			-- Turn-rate limited, not snap-to-target: a wisp that can only
			-- turn so fast is a wisp you can shake by orbiting a hulk, which
			-- is the answer the pattern is supposed to have.
			local target = bullet.chase
			local root = target and target.Character and target.Character:FindFirstChild("HumanoidRootPart")
			if not root then
				local best, bestD = nil, math.huge
				for _, entry in roots do
					local d = flatDist(bullet.pos.X, bullet.pos.Z, entry.root.Position.X, entry.root.Position.Z)
					if d < bestD then
						best, bestD = entry, d
					end
				end
				if best then
					bullet.chase = best.player
					root = best.root
				end
			end
			if root then
				local want = flatUnit(root.Position - bullet.pos)
				local have = flatUnit(bullet.vel)
				local cross = have.X * want.Z - have.Z * want.X
				local dotp = math.clamp(have:Dot(want), -1, 1)
				local step = math.min(math.acos(dotp), bullet.homing * dt)
				if cross < 0 then
					step = -step
				end
				bullet.vel = rotateFlat(bullet.vel, step)
			end
		end

		if bullet.accel ~= 0 then
			local speed = bullet.vel.Magnitude
			local next_ = math.max(speed + bullet.accel * dt, 1)
			bullet.vel = bullet.vel * (next_ / math.max(speed, 1e-4))
		end

		if bullet.link then
			-- A linked pair travels as one body: the midpoint runs on the
			-- lead's velocity while the offset spins about it.
			bullet.mid += bullet.vel * dt
			bullet.off = rotateFlat(bullet.off, bullet.spin * dt)
			bullet.pos = bullet.mid + bullet.off
			bullet.link.pos = bullet.mid - bullet.off
		else
			bullet.pos += bullet.vel * dt
		end

		-- ---- retire on expiry / leaving the arena
		if now >= bullet.diesAt then
			retire(bullet, false)
			continue
		end
		local far = flatDist(bullet.pos.X, bullet.pos.Z, bullet.centre.X, bullet.centre.Z)
		if far > bullet.bound then
			retire(bullet, false)
			continue
		end

		-- ---- hit test: flat XZ vs radius, the lure trigger's idiom
		local struck = nil
		local bestD = math.huge
		for _, entry in roots do
			local rp = entry.root.Position
			if math.abs(rp.Y - bullet.pos.Y) <= HEIGHT_TOLERANCE then
				local d
				if bullet.link then
					local other = bullet.link.pos
					d = segDistFlat(rp.X, rp.Z, bullet.pos.X, bullet.pos.Z, other.X, other.Z)
					if d > bullet.chainRadius then
						d = math.min(
							flatDist(rp.X, rp.Z, bullet.pos.X, bullet.pos.Z),
							flatDist(rp.X, rp.Z, other.X, other.Z)
						) - (bullet.radius - bullet.chainRadius)
					end
					if d <= bullet.chainRadius and d < bestD then
						struck, bestD = entry.player, d
					end
				else
					d = flatDist(rp.X, rp.Z, bullet.pos.X, bullet.pos.Z)
					if d <= bullet.radius and d < bestD then
						struck, bestD = entry.player, d
					end
				end
			end
		end
		if struck then
			-- Same path every boss AoE takes. bypassIframe is deliberate: it
			-- routes the hit through PlayerService's BURST window, which is
			-- what stops a 22-ball broadside wall from deleting a player in
			-- one frame - overlapping bursts land once per Tuning IFRAME,
			-- exactly the rule the arsenal's overlapping telegraphed AoEs
			-- already live under. The ball is spent either way, so a wall
			-- that passes through you still pops on you.
			PlayerService.damage(struck, math.random(bullet.min, bullet.max), bullet.owner, { bypassIframe = true })
			retire(bullet, true)
		end
	end

	-- Sweep, then cap - both after integration, so the cap retires what is
	-- genuinely oldest and the stream below only ever sees live bullets.
	compact()
	enforceCap()

	syncVolleys(now)
	flushPops()
end

-- ============================================================ spawning

-- One ball. `batch` collects the wire rows so the whole volley leaves as a
-- single event. Returns the bullet so a pattern can link a pair.
local function add(batch, ctx, spec)
	local sid = #batch.shots + 1
	local lifetime = math.min(spec.lifetime or 4, MAX_LIFETIME)
	local pos = Vector3.new(spec.pos.X, batch.y, spec.pos.Z)
	local bullet = {
		pos = pos,
		vel = Vector3.new(spec.vel.X, 0, spec.vel.Z),
		radius = spec.radius,
		min = ctx.min,
		max = ctx.max,
		diesAt = ctx.now + lifetime,
		owner = ctx.owner,
		centre = ctx.centre,
		bound = ctx.bound,
		skin = batch.skin,
		volley = batch.id,
		sid = sid,
		homing = spec.homing or 0,
		accel = spec.accel or 0,
		chase = spec.chase,
		sync = batch.sync or false,
		spin = 0,
		retired = false,
	}
	table.insert(batch.bullets, bullet)
	table.insert(batch.shots, { sid, pos.X, pos.Z, bullet.vel.X, bullet.vel.Z, spec.radius })
	batch.life = math.max(batch.life, lifetime)
	return bullet
end

-- Bind two balls into a spinning pair. `lead` owns the motion; `follow` is
-- carried. The chain between them is the hitbox.
local function link(batch, lead, follow, chainRadius: number, spin: number)
	local mid = (lead.pos + follow.pos) * 0.5
	lead.mid = Vector3.new(mid.X, batch.y, mid.Z)
	lead.off = lead.pos - lead.mid
	lead.link = follow
	lead.chainRadius = chainRadius
	lead.spin = spin
	follow.link = lead
	follow.follower = true
	follow.chainRadius = chainRadius
	batch.links = batch.links or {}
	-- The radius rides the row. Without it the client has to hardcode a
	-- mirror of p.chainRadius, and the moment a pattern row overrides that
	-- number the chain the player SEES stops being the hitbox they are tested
	-- against - which is the one unfairness this fight cannot afford.
	table.insert(batch.links, { lead.sid, follow.sid, chainRadius })
	batch.spin = spin
end

-- Density scaler. Wrack's four gun-deck batteries ARE his guns: every
-- pattern's count is scaled by how many still stand, so silencing them is
-- visible on the screen the moment it happens.
local function countOf(n: number, scale: number): number
	return math.max(1, math.round(n * (scale or 1)))
end

-- ============================================================ patterns
--
-- Every knob comes off the attack row's `p` table (Bosses.luau), the way
-- `p.handler` / `p.tell` / `p.skin` already do - the numbers live in data.
-- `ctx` is the shot's world context, latched by the caller at WINDUP START
-- and never recomputed: ctx.aim is the firing bearing and ctx.target the
-- point it was aimed at. A fan that re-aims mid-telegraph is unreadable and
-- undodgeable, which is the one thing this fight cannot afford.

local PATTERNS = {}

-- BROADSIDE. A ring of slow cannonballs pushed outward from the gun deck with
-- exactly ONE gap in it. The gap is the answer; the caller advances it every
-- volley (`ctx.gap`), so standing in last volley's gap is death.
PATTERNS.broadside = function(batch, ctx, p)
	local count = countOf(p.count or 22, ctx.scale)
	local gap = math.rad(p.gapDeg or 34)
	local speed = p.speed or 26
	local spawnAt = p.spawnAt or 16
	-- Balls are spread over the circle MINUS the gap, so thinning the volley
	-- widens every lane evenly instead of tearing a second hole in the wall.
	local span = math.pi * 2 - gap
	local step = span / count
	local start = ctx.gap + gap * 0.5
	for i = 0, count - 1 do
		local dir = bearing(start + step * (i + 0.5))
		add(batch, ctx, {
			pos = ctx.centre + dir * spawnAt,
			vel = dir * speed,
			radius = p.radius or 2.4,
			lifetime = p.lifetime or 4.2,
		})
	end
end

-- GRAPESHOT. A fast aimed fan at the latched bearing, several pellets wide.
-- Punishes standing still in the open: it is quick, so the dodge has to
-- happen during the tell, not after it. `phase` offsets the fan by half a
-- pellet so a second burst fills the first one's lanes.
PATTERNS.grapeshot = function(batch, ctx, p)
	local pellets = countOf(p.pellets or 7, ctx.scale)
	local fan = math.rad(p.fanDeg or 30)
	local speed = p.speed or 62
	local spawnAt = p.spawnAt or 14
	local base = math.atan2(ctx.aim.Z, ctx.aim.X)
	local step = if pellets > 1 then fan / (pellets - 1) else 0
	for i = 0, pellets - 1 do
		local dir = bearing(base - fan * 0.5 + step * (i + (ctx.phase or 0)))
		add(batch, ctx, {
			pos = ctx.centre + dir * spawnAt,
			vel = dir * speed,
			radius = p.radius or 1.6,
			lifetime = p.lifetime or 2.4,
			accel = p.accel,
		})
	end
end

-- CHAINSHOT. Pairs of balls linked by a spinning chain. The gap between a
-- pair LOOKS like a lane and is the hitbox; the real lane is between pairs,
-- and the spin opens and closes it on a readable beat.
PATTERNS.chainshot = function(batch, ctx, p)
	local pairs_ = countOf(p.pairs or 3, ctx.scale)
	local fan = math.rad(p.fanDeg or 120)
	local speed = p.speed or 20
	local spawnAt = p.spawnAt or 14
	local half = (p.chain or 12) * 0.5
	local spin = math.rad(p.spinDeg or 126)
	local base = math.atan2(ctx.aim.Z, ctx.aim.X)
	local step = if pairs_ > 1 then fan / (pairs_ - 1) else 0
	batch.sync = true
	for i = 0, pairs_ - 1 do
		local angle = base - fan * 0.5 + step * i
		local dir = bearing(angle)
		local side = rotateFlat(dir, math.pi * 0.5)
		local origin = ctx.centre + dir * spawnAt
		local lead = add(batch, ctx, {
			pos = origin + side * half,
			vel = dir * speed,
			radius = p.radius or 2.4,
			lifetime = p.lifetime or 5,
		})
		local follow = add(batch, ctx, {
			pos = origin - side * half,
			vel = dir * speed,
			radius = p.radius or 2.4,
			lifetime = p.lifetime or 5,
		})
		link(batch, lead, follow, p.chainRadius or 1.8, spin)
	end
	for _, bullet in batch.bullets do
		bullet.sync = true
	end
end

-- SLEWFIRE. One tick of the spiral: `arms` balls on a deck angle the caller
-- advances every tick. Read the rotation and walk against it - the arms lay
-- down fixed spiral lanes and crossing them the short way is the answer.
PATTERNS.slewfire = function(batch, ctx, p)
	local arms = math.max(1, p.arms or 2)
	local speed = p.speed or 22
	local spawnAt = p.spawnAt or 14
	for i = 0, arms - 1 do
		local dir = bearing(ctx.gap + (math.pi * 2 / arms) * i)
		add(batch, ctx, {
			pos = ctx.centre + dir * spawnAt,
			vel = dir * speed,
			radius = p.radius or 2.0,
			lifetime = p.lifetime or 4.5,
		})
	end
end

-- WISPS. A few slow homing lantern-lights. Weak on their own; they exist to
-- deny standing still and to make you use the breakwater hulks - each turns
-- at a fixed rate, so a tight orbit round a hulk makes them overshoot.
PATTERNS.wisps = function(batch, ctx, p)
	local count = countOf(p.count or 3, ctx.scale)
	local speed = p.speed or 13
	local spawnAt = p.spawnAt or 12
	local spread = math.rad(p.spreadDeg or 360)
	local base = math.atan2(ctx.aim.Z, ctx.aim.X)
	batch.sync = true
	local targets = livingRoots()
	for i = 0, count - 1 do
		local dir = bearing(base - spread * 0.5 + (spread / math.max(count, 1)) * (i + 0.5))
		local pick = if #targets > 0 then targets[(i % #targets) + 1].player else nil
		add(batch, ctx, {
			pos = ctx.centre + dir * spawnAt,
			vel = dir * speed,
			radius = p.radius or 2.2,
			lifetime = p.lifetime or 11,
			homing = math.rad(p.homingDeg or 150),
			chase = pick,
		})
	end
	for _, bullet in batch.bullets do
		bullet.sync = true
	end
end

-- ANCHORSWEEP. The one big telegraph: a heavy arc across half the arena. The
-- balls overlap, so it is a wall you cannot thread - the answer is the OTHER
-- half, and the long windup is there to let you get there. `ripple` gives one
-- end of the arc a head start so it visibly sweeps, which also means the
-- trailing end is passable for a beat if you commit to it.
PATTERNS.anchorsweep = function(batch, ctx, p)
	local count = countOf(p.count or 15, ctx.scale)
	local arc = math.rad(p.arcDeg or 180)
	local speed = p.speed or 18
	local spawnAt = p.spawnAt or 16
	local ripple = p.ripple or 0.05
	local base = math.atan2(ctx.aim.Z, ctx.aim.X)
	local step = if count > 1 then arc / (count - 1) else 0
	for i = 0, count - 1 do
		local dir = bearing(base - arc * 0.5 + step * i)
		local head = ripple * (count - 1 - i) * speed
		add(batch, ctx, {
			pos = ctx.centre + dir * (spawnAt + head),
			vel = dir * speed,
			radius = p.radius or 3.4,
			lifetime = p.lifetime or 5,
		})
	end
end

-- ============================================================ API

-- Fire one volley of `pattern`. ONE client event, however many balls.
--
-- ctx = {
--   owner   : the boss creature struct (damage source + lifetime authority)
--   centre  : Vector3  the gun platform / arena centre patterns radiate from
--   origin  : Vector3  the muzzle, for the client's flash
--   aim     : Vector3  LATCHED firing bearing (flat unit)
--   gap     : number   pattern-owned angle (broadside's gap, slewfire's deck)
--   phase   : number?  grapeshot's sub-pellet offset
--   scale   : number   density multiplier (Wrack's surviving batteries)
--   bound   : number   retire past this flat radius from `centre`
--   now, min, max      clock and the rolled damage range
-- }
-- Returns the number of balls spawned.
function ProjectileService.emit(pattern: string, ctx, p): number
	local builder = PATTERNS[pattern]
	if not builder then
		warn(string.format("[ProjectileService] unknown pattern %q", pattern))
		return 0
	end
	-- A gone owner never gets to spawn anything - the zombie-boss guard on
	-- the way in, matching the one in the tick.
	if ownerGone(ctx.owner) then
		return 0
	end

	nextVolleyId += 1
	local batch = {
		id = nextVolleyId,
		skin = p.skin or "cannon",
		y = World.WATER_Y + FLIGHT_Y,
		life = 0,
		shots = {},
		bullets = {},
		sync = false,
		links = nil,
		spin = nil,
	}
	builder(batch, ctx, p)
	if #batch.bullets == 0 then
		return 0
	end

	for _, bullet in batch.bullets do
		table.insert(live, bullet)
	end
	enforceCap()

	Hazards.fireEvent("wrackVolley", ctx.origin or ctx.centre, {
		id = batch.id,
		skin = batch.skin,
		y = batch.y,
		life = batch.life,
		accel = p.accel,
		sync = batch.sync or nil,
		spin = batch.spin,
		shots = batch.shots,
		links = batch.links,
	})
	flushPops()
	return #batch.bullets
end

-- Retire everything an owner has in the air. The tick already does this on
-- its own (ownerGone), so this is for a caller that wants the screen cleared
-- on the same frame - a boss collapsing, a fight abandoned.
function ProjectileService.clearOwner(owner)
	for _, bullet in live do
		if bullet.owner == owner then
			retire(bullet, false)
		end
	end
	compact()
	flushPops()
end

function ProjectileService.liveCount(): number
	return #live
end

function ProjectileService.start()
	if connection then
		return
	end
	connection = RunService.Heartbeat:Connect(tick)
end

return ProjectileService
