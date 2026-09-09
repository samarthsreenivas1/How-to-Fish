--!nonstrict
-- ProjectileFxController.luau
-- Admiral Wrack's bullet hell, drawn. The server (Server/Services/
-- ProjectileService) owns every ball: where it is, what it hits, when it
-- dies. This file owns whether the player can SEE it in time. Nothing here
-- ever decides a hit, predicts one, or stops a ball early - a bullet that
-- looks like it missed you and took your health would be the worst bug this
-- fight could have, so the drawing never has an opinion.
--
-- Two rules run through all of it:
--
--   READABILITY OVER SPECTACLE. Every lethal body is drawn at EXACTLY its
--   server hit radius, in Neon, in one of five fixed hues that appear nowhere
--   in the Careenage's palette (rotten timber, barnacled grey, wet sand).
--   Anything that is not lethal - a glow, a ground shadow, a telegraph - is
--   drawn transparent and dimmer so it can never be mistaken for the thing
--   that kills. Colour tells you WHAT it is, size tells you HOW BIG the
--   danger is, and the two never lie. There is deliberately no camera shake
--   and no screen flash on a volley: both cost frames of readable field, and
--   a bullet hell you cannot read is not hard, it is unfair.
--
--   ONE EVENT, MANY BALLS. A broadside is dozens of projectiles in a frame,
--   so the server sends one event per VOLLEY and the client flies each ball
--   from its spawn point, velocity and lifetime on its own clock. Pooled
--   parts, one shared render step, no per-bullet scripts, no per-bullet
--   Instance ever created after init.
--
-- ============================================================================
-- THE SERVER CONTRACT
-- ============================================================================
-- Everything the server lane owns enters through ONE function - adaptEvent,
-- immediately below - and nothing past it knows a wire field name. When the
-- contract moves, that function moves and the renderer does not. It rides the
-- existing CreatureEvent remote (kind, position, extra), which this file
-- subscribes to alongside CreatureEventController; kinds it does not own are
-- ignored in silence.
--
-- As built against ProjectileService's header (2026-08-29):
--   wrackVolley  a volley was born. position = the muzzle.
--                extra = { id, skin, y, life, accel?, sync?, spin?,
--                          shots = { { sid, x, z, vx, vz, r } },
--                          links = { { sidA, sidB, chainRadius? } }? }
--                The third number on a link row is optional and read
--                defensively: without it the chain is drawn at the server's
--                own 1.8 default, so the two lanes can land in either order
--                without a window where the bar drawn is not the hitbox.
--   wrackShots   truth stream for `sync` volleys, ~4.5/s.
--                extra = { id, shots = { { sid, x, z } } }. A ball missing
--                from the stream has been retired - drop it.
--   wrackPop     balls retired this frame. extra = { id, hit = { sid },
--                gone = { sid } }: `hit` struck someone (burst + sound),
--                `gone` expired (vanish quietly).
--   wrackTell    a windup. LIVE since f57abfa: CreatureService fires it once
--                per pattern from the `windup` hook (guarded by `a.wrackTold`)
--                in both forms below - wrackRingTell sends shape = "ring",
--                wrackLaneTell sends shape = "lane" - alongside `coneTell`,
--                `ringTell` and `mark`, all of which this file handles. The
--                tell layer also still picks up the boss arsenal's existing
--                `telegraph` kind when it carries one of Wrack's skins, so it
--                lights up either way. See adaptEvent. An
--                optional `id` on it is remembered, so a windup that is
--                interrupted before it fires can be retracted rather than
--                left to expire into an attack that never comes
--                (ProjectileFxController.retireTell; the wire kind that
--                would call it is the server lane's to propose).
--
-- WHICH TELLS ACTUALLY DRAW (the server lane picks `tell` per pattern, and an
-- unmatched tell name falls through the arsenal to a 3-stud flash at the
-- boss's pivot, which for a bullet-hell windup is no warning at all). Exactly
-- these reach the loud layer in this file:
--
--   wrackTell + shape = "lane"   needs aim (Vector3), width, length, duration
--   wrackTell + shape = "ring"   needs radius, duration
--   telegraph + tell = "coneTell"  needs facing (Vector3) + radius -> a lane
--   telegraph + tell = "mark" | "ringTell" | "slam" | "tail" | "burst"
--                                  needs radius -> a closing ring
--
-- ...and all of the `telegraph` forms ALSO need `skin` set to one of Wrack's
-- (cannon/grape/chain/wisp/anchor, or the arsenal's ember/wreck) - the skin is
-- how this file knows a tell is his and not another boss's. Any other tell
-- name draws nothing here and gets only the arsenal's own thin ring, so a new
-- pattern wants one of the names above or a `wrackTell` of its own.
--
-- One cue this file deliberately does NOT draw: the punish window (all four
-- gun decks silenced). It is the boss's Exposed attribute, which the engine
-- currently sets true and never clears for a plain boss archetype, so a tell
-- keyed on it would fire once per fight and then go quiet - a fix that
-- belongs to CreatureService, not to a client workaround that would hide it.
--
-- THERE IS A SECOND READER OF THESE THREE KINDS. WrackBodyController now
-- subscribes to the same broadcast and adapts `wrackVolley`, `wrackTell` and
-- Wrack-skinned `telegraph` into its own two signals - "fire" and "windup" -
-- to drive the boss's animation channels (the Admiral's sabre, the cannons'
-- recoil and muzzle flash). It has its own `adaptSignal`, deliberately: the
-- two files want different fields out of the same wire and sharing one record
-- would couple a renderer to a rig. What that DOES mean is that a change to
-- these three kinds now costs two edits, not one - and that a field this file
-- stops needing may still be load-bearing over there:
--
--   wrackVolley  its `position` is the ONLY "the guns just fired" edge on the
--                wire, and its identity as a MUZZLE is what picks which cannon
--                recoils. A volley re-sourced at the hull pivot would silently
--                turn every aimed shot into a full broadside animation.
--   wrackTell    `duration` is how long the sabre is held high, and `aim`
--                (lane shape only) is the bearing he points along.
--   telegraph    `facing` on a `coneTell`, same job as `aim`.
--
-- Ballistic balls are dead-reckoned (position = p0 + v^ * distance, with the
-- speed ramp `accel` integrated exactly the way the server integrates it,
-- floor and all). `sync` volleys - homing wisps, spinning chain pairs - are
-- NOT dead-reckoned from birth: they run on the stream, extrapolated by the
-- velocity implied between the last two updates, with the correction eased
-- out over a fifth of a second so a moving hitbox never jitters and never
-- drifts away from the one the server is testing.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local World = require(Shared.Config.World)

local Vfx = require(script.Parent.Parent.Modules.Vfx)
local Sfx = require(script.Parent.Parent.Modules.Sfx)

local player = Players.LocalPlayer

local ProjectileFxController = {}

-- ---------------------------------------------------------------- the contract

-- Wrack's skins, and the two the boss arsenal already stamps on his other
-- moments (CreatureEventController's SKIN table), so a telegraph fired by the
-- old arsenal path is still recognised as his.
local WRACK_SKINS = {
	cannon = true,
	grape = true,
	chain = true,
	wisp = true,
	anchor = true,
	ember = true,
	wreck = true,
}

-- The arsenal tell names this file promotes to a closing ground ring. Kept as
-- a written-down set rather than "anything carrying a radius" so the server
-- lane can read off exactly which tells reach a real telegraph: a name that is
-- not here draws only the arsenal's own thin ring, and one that is not in the
-- arsenal's own table at all draws a 3-stud flash at the boss's pivot.
local RING_TELLS = {
	mark = true,
	ringTell = true,
	slam = true,
	tail = true,
	burst = true,
}

local function numberList(value): { any }?
	return if type(value) == "table" then value else nil
end

-- THE one plug. Turns a CreatureEvent into a normalised record this file
-- understands, or nil for every event it does not own. Field names, kind
-- names and argument order all live here and nowhere else.
local function adaptEvent(kind: string, position: Vector3, extra): any?
	if kind == "wrackVolley" then
		local shots = numberList(extra.shots)
		if not shots or #shots == 0 then
			return nil
		end
		return {
			what = "volley",
			id = tonumber(extra.id) or 0,
			skin = tostring(extra.skin or "cannon"),
			origin = position,
			y = tonumber(extra.y) or position.Y,
			life = tonumber(extra.life) or 6,
			accel = tonumber(extra.accel) or 0,
			sync = extra.sync == true,
			spin = tonumber(extra.spin) or 0,
			-- { sid, x, z, vx, vz, r }
			shots = shots,
			links = numberList(extra.links),
		}
	elseif kind == "wrackShots" then
		local shots = numberList(extra.shots)
		if not shots then
			return nil
		end
		-- { sid, x, z }
		return { what = "stream", id = tonumber(extra.id) or 0, shots = shots }
	elseif kind == "wrackPop" then
		return {
			what = "pop",
			id = tonumber(extra.id) or 0,
			at = position,
			hit = numberList(extra.hit),
			gone = numberList(extra.gone),
		}
	elseif kind == "wrackTell" then
		return {
			what = "tell",
			-- Optional, and read defensively: a tell that carries an id can be
			-- retracted before it expires (ProjectileFxController.retireTell).
			id = tonumber(extra.id),
			skin = tostring(extra.skin or "cannon"),
			at = position,
			shape = tostring(extra.shape or "lane"),
			aim = if typeof(extra.aim) == "Vector3" then extra.aim else Vector3.zAxis,
			width = tonumber(extra.width) or 12,
			length = tonumber(extra.length) or 90,
			radius = tonumber(extra.radius) or 10,
			duration = tonumber(extra.duration) or 1,
		}
	elseif kind == "telegraph" and WRACK_SKINS[tostring(extra.skin)] then
		-- The boss arsenal's own tell, promoted to the loud layer. Wrack's
		-- patterns are lanes and rings, and the arsenal's ringed tells carry
		-- a radius while its aimed one carries a facing.
		local sub = tostring(extra.kind)
		local radius = tonumber(extra.radius)
		local duration = tonumber(extra.duration) or 0.9
		if not radius then
			return nil -- nothing to draw a shape from; the arsenal's own flash stands
		end
		if sub == "coneTell" and typeof(extra.facing) == "Vector3" then
			return {
				what = "tell",
				skin = tostring(extra.skin),
				at = position,
				shape = "lane",
				aim = extra.facing,
				width = radius * 0.5,
				length = radius,
				radius = radius,
				duration = duration,
			}
		elseif RING_TELLS[sub] then
			return {
				what = "tell",
				skin = tostring(extra.skin),
				at = position,
				shape = "ring",
				aim = Vector3.zAxis,
				width = 0,
				length = 0,
				radius = radius,
				duration = duration,
			}
		end
		return nil
	end
	return nil
end

-- ---------------------------------------------------------------- readability

-- One hue per bullet type, and the eye learns them in the first volley:
--
--   cannon  hot ember     big, slow, the thing you walk between (also slew
--                         fire, which is the same ball on a rotating bearing)
--   grape   pale hot white small, fast, arrives as a spray - white reads as
--                         "many and quick" against the ember walls
--   chain   iron + RED    the two balls are deliberately DULL, unlit iron;
--                         the chain strung between them is the only red in
--                         the fight and the only thing that pulses, because
--                         the chain is the hitbox and the inviting gap
--                         between a pair is the trap
--   wisp    lantern gold  slow, homing, carries the fight's only moving light
--   anchor  verdigris     the sweeping mass, Wrack's ghost-glow green
--
-- `body` is the colour of the lethal part and is always Neon at full opacity.
local SKIN = {
	cannon = { body = Color3.fromRGB(255, 150, 60), shadow = true },
	grape = { body = Color3.fromRGB(255, 240, 196), shadow = false },
	chain = { body = Color3.fromRGB(156, 166, 178), shadow = false, dull = true },
	wisp = { body = Color3.fromRGB(255, 214, 120), shadow = false, lantern = true },
	anchor = { body = Color3.fromRGB(120, 220, 180), shadow = true },
	-- The arsenal's own two, so a telegraph stamped with them still colours.
	ember = { body = Color3.fromRGB(255, 150, 60), shadow = true },
	wreck = { body = Color3.fromRGB(120, 220, 180), shadow = true },
}

-- The chain's own hit radius. The wire's `links` rows carry only the two
-- shot ids, so this mirrors ProjectileService's `p.chainRadius or 1.8`
-- default; if a pattern row ever overrides it, that number has to reach the
-- client or the bar drawn here stops being the hitbox (see the report).
local CHAIN_RADIUS = 1.8
local CHAIN_COLOR = Color3.fromRGB(255, 74, 44)
local CHAIN_PULSE = 5.5 -- rad/s of the chain's brightness throb

-- Pools. The server caps itself at 320 live balls; 384 leaves room for a
-- fresh volley arriving before a spent one has been culled. Everything is
-- built once in init and reused forever - a slot whose turn comes round
-- again while it is still flying simply takes the part back, which retires
-- the oldest ball on screen, the one already behind the player.
local BULLET_POOL = 384
local SHADOW_POOL = 56 -- ground discs, for the two heavy skins only
local CHAIN_POOL = 12 -- linked pairs in the air at once
local LANTERN_POOL = 8 -- lights that ride the nearest wisps
local TELL_POOL = 8 -- windup markers
local ARROW_POOL = 6 -- off-screen threat arrows

-- Everything the fight draws lives on the flight plane the volley declares.
-- The Careenage's sand sits a stud or so above the waterline and the balls
-- fly at chest height, so a shadow this far under a ball lands on the sand
-- without fighting it for depth.
local SHADOW_DROP = 1.8
local SHADOW_THICKNESS = 0.08
local SHADOW_TRANSPARENCY = 0.55

-- Past this from the camera the fight is somebody else's; the arena is 176
-- studs across and the camera sits 58 back, so nothing real is ever cut.
local DRAW_RANGE = 520

-- A volley is dropped this long after the last ball's declared lifetime, in
-- case a `wrackPop` for it never arrives (a client that streamed out mid
-- fight, a dropped packet).
local VOLLEY_GRACE = 0.75
local VOLLEY_LIFE_CAP = 20

-- `sync` volleys: how long a correction from the truth stream is eased in
-- (below) and above which it is taken as a teleport instead. A hitbox that
-- slides visibly is worse than one that jumps.
local SYNC_SMOOTH = 0.18
local SYNC_SNAP = 8
local SYNC_MAX_SPEED = 400

local SPEED_FLOOR = 1 -- ProjectileService's own floor under a decelerating ball

-- At most this many impact bursts are drawn per pop event, however many balls
-- it retired: a wall clearing on one frame is 30 hits and 30 emitters would
-- cost more frames than the wall did.
local IMPACT_BURSTS = 3

-- ---------------------------------------------------------------- state

local folder: Folder
local bullets = {} -- { part, owner }
local bulletCursor = 1
local shadows = {}
local shadowCursor = 1
local chains = {} -- { bar, mark, owner }
local chainCursor = 1
local lanterns = {} -- { part, light, owner }
local tells = {}
local arrows = {} -- { frame, label }

local volleys = {} -- [volleyId] = volley
local liveVolleys = 0

-- Reused every frame by the bulk mover so the step allocates nothing.
local moveParts = {}
local moveCFrames = {}
local moveCount = 0

-- ---------------------------------------------------------------- helpers

local function camera(): Camera?
	return Workspace.CurrentCamera
end

local function nearCamera(position: Vector3, range: number): boolean
	local cam = camera()
	return cam ~= nil and (cam.CFrame.Position - position).Magnitude <= range
end

local function skinOf(name: string)
	return SKIN[name] or SKIN.cannon
end

-- Where the sand is under `position`. A telegraph is drawn ON the ground and
-- the point the server sends is a muzzle - twenty studs up the careened hull
-- for a broadside - so every windup costs one raycast. Never a ball: those
-- fly on the plane their volley declares, and there are hundreds of them.
local function groundY(position: Vector3): number
	local ignore = { folder }
	local character = player.Character
	if character then
		table.insert(ignore, character)
	end
	for _, name in { "Creatures", "ClientVfx", "CreatureFx" } do
		local other = Workspace:FindFirstChild(name)
		if other then
			table.insert(ignore, other)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.RespectCanCollide = true
	local hit = Workspace:Raycast(position + Vector3.new(0, 8, 0), Vector3.new(0, -60, 0), params)
	return if hit then hit.Position.Y else World.WATER_Y + 1.2
end

local function queueMove(part: BasePart, cf: CFrame)
	moveCount += 1
	moveParts[moveCount] = part
	moveCFrames[moveCount] = cf
end

-- One engine call for every part that moved this frame instead of one
-- property write per ball - the whole reason hundreds of these can fly.
local function flushMoves()
	for i = #moveParts, moveCount + 1, -1 do
		moveParts[i] = nil
		moveCFrames[i] = nil
	end
	if moveCount > 0 then
		Workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
	moveCount = 0
end

local function makePart(name: string, shape: Enum.PartType): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = shape
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false -- also keeps them out of the camera's occlusion ray
	part.CanTouch = false
	part.CastShadow = false
	part.Locked = true
	part.Material = Enum.Material.Neon
	part.Transparency = 1
	part.Size = Vector3.one
	part.Parent = folder
	return part
end

-- ---------------------------------------------------------------- pools

-- Every pool works the same way: a cursor walks the slots and a slot whose
-- turn comes round while it is still flying is taken back (the glob pool's
-- idiom, one back-pointer richer so the evicted ball learns it has lost its
-- body). A ball remembers its slot index, so giving one up is O(1) - a wall
-- clearing on one frame is thirty releases and none of them may walk a pool.

local function dropShadow(shot)
	local index = shot.shadowSlot
	if index then
		local slot = shadows[index]
		if slot.owner == shot then
			slot.owner = nil
			slot.part.Transparency = 1
		end
		shot.shadow = nil
		shot.shadowSlot = nil
	end
end

local function releaseShot(shot)
	shot.dead = true
	local index = shot.slot
	if index then
		local slot = bullets[index]
		if slot.owner == shot then
			slot.owner = nil
			slot.part.Transparency = 1
		end
		shot.part = nil
		shot.slot = nil
	end
	dropShadow(shot)
end

local function takeBullet(shot): Part
	local index = bulletCursor
	local slot = bullets[index]
	bulletCursor = bulletCursor % BULLET_POOL + 1
	if slot.owner and slot.owner ~= shot then
		releaseShot(slot.owner)
	end
	slot.owner = shot
	shot.slot = index
	return slot.part
end

local function takeShadow(shot): Part
	local index = shadowCursor
	local slot = shadows[index]
	shadowCursor = shadowCursor % SHADOW_POOL + 1
	if slot.owner and slot.owner ~= shot then
		dropShadow(slot.owner)
	end
	slot.owner = shot
	shot.shadowSlot = index
	return slot.part
end

local function dropChain(link)
	local rig = link.rig
	if rig then
		if rig.owner == link then
			rig.owner = nil
			rig.bar.Transparency = 1
			rig.mark.Transparency = 1
		end
		link.rig = nil
	end
end

local function takeChain(link)
	local slot = chains[chainCursor]
	chainCursor = chainCursor % CHAIN_POOL + 1
	if slot.owner and slot.owner ~= link then
		dropChain(slot.owner)
	end
	slot.owner = link
	return slot
end

local function releaseVolley(volley)
	for _, shot in volley.order do
		releaseShot(shot)
	end
	for _, link in volley.links do
		dropChain(link)
	end
	volleys[volley.id] = nil
	liveVolleys -= 1
end

-- ---------------------------------------------------------------- flight

-- How far along its own heading a ball has travelled after `t` seconds. The
-- server ramps SPEED by `accel` along a fixed heading and floors it at 1
-- stud/s, so this integrates the same curve rather than the textbook one -
-- a drawn ball that drifts off the tested one is a lie about a hitbox.
local function travelled(speed: number, accel: number, t: number): number
	if accel == 0 then
		return speed * t
	end
	if accel > 0 then
		return speed * t + 0.5 * accel * t * t
	end
	local toFloor = (SPEED_FLOOR - speed) / accel
	if toFloor <= 0 then
		return SPEED_FLOOR * t -- already crawling at the floor when it was born
	end
	if t <= toFloor then
		return speed * t + 0.5 * accel * t * t
	end
	return speed * toFloor + 0.5 * accel * toFloor * toFloor + SPEED_FLOOR * (t - toFloor)
end

local function shotPos(volley, shot, now: number): (number, number)
	if volley.sync then
		local dt = now - shot.syncAt
		local x = shot.syncX + shot.syncVx * dt
		local z = shot.syncZ + shot.syncVz * dt
		local age = now - shot.errAt
		if age < SYNC_SMOOTH then
			local k = 1 - age / SYNC_SMOOTH
			x += shot.errX * k
			z += shot.errZ * k
		end
		return x, z
	end
	local d = travelled(shot.speed, volley.accel, now - shot.t0)
	return shot.bx + shot.ux * d, shot.bz + shot.uz * d
end

-- ---------------------------------------------------------------- volleys

local function onVolley(v)
	if not nearCamera(v.origin, DRAW_RANGE) then
		return
	end
	if volleys[v.id] then
		releaseVolley(volleys[v.id])
	end

	local now = os.clock()
	local skin = skinOf(v.skin)
	local volley = {
		id = v.id,
		style = v.skin,
		skin = skin,
		y = v.y,
		accel = v.accel,
		sync = v.sync,
		diesAt = now + math.min(v.life, VOLLEY_LIFE_CAP) + VOLLEY_GRACE,
		shots = {},
		order = {},
		links = {},
	}

	for _, row in v.shots do
		local sid = tonumber(row[1])
		local x, z = tonumber(row[2]), tonumber(row[3])
		local vx, vz = tonumber(row[4]) or 0, tonumber(row[5]) or 0
		local r = tonumber(row[6]) or 1
		if sid and x and z then
			local speed = math.sqrt(vx * vx + vz * vz)
			local shot = {
				sid = sid,
				r = r,
				t0 = now,
				bx = x,
				bz = z,
				speed = speed,
				ux = if speed > 1e-4 then vx / speed else 0,
				uz = if speed > 1e-4 then vz / speed else 0,
				-- the stream's view of the same ball, seeded from its birth
				syncX = x,
				syncZ = z,
				syncVx = vx,
				syncVz = vz,
				syncAt = now,
				errX = 0,
				errZ = 0,
				errAt = 0,
				dead = false,
			}
			-- The lethal body: exactly the radius the server tests, lit.
			local part = takeBullet(shot)
			part.Size = Vector3.new(r * 2, r * 2, r * 2)
			part.Color = skin.body
			-- Unlit for the chain's two balls: cold steel against a lit field,
			-- so the eye goes to the chain and not to the pair.
			part.Material = if skin.dull then Enum.Material.SmoothPlastic else Enum.Material.Neon
			part.Transparency = 0
			part.CFrame = CFrame.new(x, v.y, z)
			shot.part = part
			-- ...and, for the heavy skins, where it is over the sand. On a
			-- pitched-down camera a ball at chest height and a ball about to
			-- pass behind you look alike; the disc under it does not.
			if skin.shadow then
				local disc = takeShadow(shot)
				disc.Size = Vector3.new(SHADOW_THICKNESS, r * 2, r * 2)
				disc.Color = skin.body
				disc.Transparency = SHADOW_TRANSPARENCY
				shot.shadow = disc
			end
			volley.shots[sid] = shot
			table.insert(volley.order, shot)
		end
	end

	if v.links then
		for _, pair in v.links do
			local a = volley.shots[tonumber(pair[1]) or -1]
			local b = volley.shots[tonumber(pair[2]) or -1]
			if a and b then
				-- The chain's own hit radius if the wire carries it, else the
				-- server's default. Read defensively so this lane and the
				-- server's can land in either order without a window where
				-- the bar drawn here is not the capsule being tested.
				local link = { a = a, b = b, sep = 0, radius = tonumber(pair[3]) or CHAIN_RADIUS }
				local rig = takeChain(link)
				link.rig = rig
				rig.bar.Color = CHAIN_COLOR
				rig.bar.Transparency = 0
				rig.mark.Color = CHAIN_COLOR
				rig.mark.Transparency = 0.6
				table.insert(volley.links, link)
			end
		end
	end

	if #volley.order == 0 then
		return
	end
	volleys[v.id] = volley
	liveVolleys += 1

	-- One flash and one report for the whole broadside, at the muzzle.
	Vfx.flash(v.origin, skin.body, 4.5, 0.16)
	Sfx.play(if v.skin == "grape" then "gunFire" else "explodeCrack", v.origin)
end

local function onStream(s)
	local volley = volleys[s.id]
	if not volley then
		return
	end
	local now = os.clock()
	for _, shot in volley.order do
		shot.seen = false
	end
	for _, row in s.shots do
		local shot = volley.shots[tonumber(row[1]) or -1]
		local x, z = tonumber(row[2]), tonumber(row[3])
		if shot and not shot.dead and x and z then
			shot.seen = true
			-- Where it is being drawn right now, so the jump to the truth can
			-- be eased out instead of snapped.
			local drawnX, drawnZ = shotPos(volley, shot, now)
			local dt = math.max(now - shot.syncAt, 1e-3)
			local vx = math.clamp((x - shot.syncX) / dt, -SYNC_MAX_SPEED, SYNC_MAX_SPEED)
			local vz = math.clamp((z - shot.syncZ) / dt, -SYNC_MAX_SPEED, SYNC_MAX_SPEED)
			shot.syncVx, shot.syncVz = vx, vz
			shot.syncX, shot.syncZ, shot.syncAt = x, z, now
			local errX, errZ = drawnX - x, drawnZ - z
			if math.abs(errX) > SYNC_SNAP or math.abs(errZ) > SYNC_SNAP then
				errX, errZ = 0, 0 -- too far gone to ease: take the truth now
			end
			shot.errX, shot.errZ, shot.errAt = errX, errZ, now
		end
	end
	-- "Balls not listed in a stream have already been retired."
	for _, shot in volley.order do
		if not shot.dead and not shot.seen then
			releaseShot(shot)
		end
	end
end

local function onPop(p)
	local volley = volleys[p.id]
	if not volley then
		return
	end
	local drawn = 0
	if p.hit then
		for _, sid in p.hit do
			local shot = volley.shots[tonumber(sid) or -1]
			if shot and not shot.dead then
				if drawn < IMPACT_BURSTS and shot.part then
					drawn += 1
					Vfx.burst(shot.part.Position, volley.skin.body, 16)
				end
				releaseShot(shot)
			end
		end
		if drawn > 0 then
			Sfx.play("bossGlobThud", p.at)
		end
	end
	if p.gone then
		for _, sid in p.gone do
			local shot = volley.shots[tonumber(sid) or -1]
			if shot then
				releaseShot(shot)
			end
		end
	end
end

-- ---------------------------------------------------------------- the step

-- Volleys that timed out this frame, collected rather than dropped inside the
-- walk: releaseVolley clears the entry, and Luau's generalized iteration
-- refuses a table that is modified while it is being iterated. Reused between
-- frames so the step still allocates nothing.
local expired = {}

local function stepVolleys(now: number)
	local expiredCount = 0
	for _, volley in volleys do
		if now >= volley.diesAt then
			expiredCount += 1
			expired[expiredCount] = volley
		else
			local y = volley.y
			for _, shot in volley.order do
				if not shot.dead and shot.part then
					local x, z = shotPos(volley, shot, now)
					shot.x, shot.z = x, z
					queueMove(shot.part, CFrame.new(x, y, z))
					if shot.shadow then
						queueMove(shot.shadow, CFrame.new(x, y - SHADOW_DROP, z) * CFrame.Angles(0, 0, math.rad(90)))
					end
				end
			end
			-- The chain between a pair IS the hitbox, so it is drawn as the
			-- capsule the server tests: a bar of the chain's own radius from
			-- ball to ball, plus its shadow flat on the sand, both pulsing.
			-- The balls themselves are unlit iron - the eye has to go to the
			-- chain, because the gap between a pair is what kills.
			if #volley.links > 0 then
				local throb = 0.12 + 0.16 * (1 + math.sin(now * CHAIN_PULSE)) * 0.5
				for _, link in volley.links do
					local a, b, rig = link.a, link.b, link.rig
					if rig and not a.dead and not b.dead and a.part and b.part then
						local pa = Vector3.new(a.x, y, a.z)
						local pb = Vector3.new(b.x, y, b.z)
						local sep = (pb - pa).Magnitude
						if sep > 0.05 then
							if math.abs(sep - link.sep) > 0.25 then
								link.sep = sep
								local thick = link.radius * 2
								rig.bar.Size = Vector3.new(thick, thick, sep)
								rig.mark.Size = Vector3.new(thick, SHADOW_THICKNESS, sep)
							end
							local mid = (pa + pb) * 0.5
							local aim = CFrame.lookAt(mid, pb)
							queueMove(rig.bar, aim)
							queueMove(rig.mark, aim - Vector3.new(0, SHADOW_DROP, 0))
							rig.bar.Transparency = throb
						end
					elseif rig then
						-- Half a chainshot is not a thing: when either ball is
						-- gone the chain goes with it.
						dropChain(link)
					end
				end
			end
		end
	end
	for i = 1, expiredCount do
		releaseVolley(expired[i])
		expired[i] = nil
	end
end

-- The lanterns: the fight's only moving lights, one riding each live wisp
-- until the pool runs out. A light per ball would be unaffordable and a wisp
-- without one stops reading as a lantern, so the pool covers the wisps in the
-- air (a wisp volley is a handful) and any beyond it ride on colour alone.
-- The light throbs; the BODY never does, because the body is the hitbox.
local function stepLanterns(now: number)
	local taken = 0
	for _, volley in volleys do
		if volley.skin.lantern then
			for _, shot in volley.order do
				if not shot.dead and shot.part and taken < LANTERN_POOL then
					taken += 1
					local slot = lanterns[taken]
					queueMove(slot.part, CFrame.new(shot.x, volley.y, shot.z))
					slot.light.Enabled = true
					slot.light.Brightness = 3.2 + 1.4 * math.sin(now * 3.1 + taken)
				end
			end
		end
	end
	for i = taken + 1, LANTERN_POOL do
		lanterns[i].light.Enabled = false
	end
end

-- ---------------------------------------------------------------- telegraphs

-- A windup has to be readable from across the arena and has to say WHEN, not
-- just where: a lane is drawn flat on the sand with a bright bar running down
-- it that reaches the far end exactly as the guns fire, and a ring closes on
-- its danger radius over the same window. Both brighten as they go, so the
-- last third of a windup is the loudest thing on screen.
local TELL_LIFT = 0.12 -- clear of the sand, so it never fights it for depth

local function hideTell(tell)
	tell.active = false
	tell.id = nil
	tell.lane.Transparency = 1
	tell.edge.Transparency = 1
	tell.ring.Transparency = 1
end

local function takeTell()
	local oldest, oldestAt = nil, math.huge
	for _, tell in tells do
		if not tell.active then
			return tell
		end
		if tell.startAt < oldestAt then
			oldest, oldestAt = tell, tell.startAt
		end
	end
	return oldest
end

local function onTell(t)
	if not nearCamera(t.at, DRAW_RANGE) then
		return
	end
	local tell = takeTell()
	if not tell then
		return
	end
	local skin = skinOf(t.skin)
	local now = os.clock()
	tell.active = true
	tell.id = t.id -- may be nil; see retireTell
	tell.startAt = now
	tell.endsAt = now + math.clamp(t.duration, 0.15, 6)
	tell.shape = t.shape
	tell.at = t.at
	tell.color = skin.body

	local flat = Vector3.new(t.aim.X, 0, t.aim.Z)
	tell.aim = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.zAxis
	tell.width = t.width
	tell.length = t.length
	tell.radius = t.radius
	-- On the sand, whatever height the muzzle it came from sits at.
	tell.y = groundY(t.at) + TELL_LIFT

	if t.shape == "lane" then
		local mid = Vector3.new(t.at.X, tell.y, t.at.Z) + tell.aim * (t.length * 0.5)
		tell.lane.Size = Vector3.new(t.width, SHADOW_THICKNESS, t.length)
		tell.lane.CFrame = CFrame.lookAt(mid, mid + tell.aim)
		tell.lane.Color = skin.body
		tell.edge.Size = Vector3.new(t.width * 1.05, SHADOW_THICKNESS * 2, 1.2)
		tell.edge.Color = skin.body
		tell.ring.Transparency = 1
	else
		tell.ring.Size = Vector3.new(SHADOW_THICKNESS, t.radius * 2, t.radius * 2)
		tell.ring.CFrame = CFrame.new(t.at.X, tell.y, t.at.Z) * CFrame.Angles(0, 0, math.rad(90))
		tell.ring.Color = skin.body
		tell.lane.Transparency = 1
		tell.edge.Transparency = 1
	end
	Sfx.play("bossTell", t.at)
end

local function stepTells(now: number)
	for _, tell in tells do
		if tell.active then
			local span = math.max(tell.endsAt - tell.startAt, 1e-3)
			local u = (now - tell.startAt) / span
			if u >= 1 then
				hideTell(tell)
			else
				-- 0.72 -> 0.3: present from the first frame, loudest at the end.
				local alpha = 0.72 - 0.42 * u
				if tell.shape == "lane" then
					tell.lane.Transparency = alpha
					tell.edge.Transparency = math.max(alpha - 0.25, 0)
					-- The bar runs the length of the lane and reaches the far
					-- end exactly as the guns fire: the windup says WHEN.
					local at = Vector3.new(tell.at.X, tell.y + 0.02, tell.at.Z) + tell.aim * (tell.length * u)
					queueMove(tell.edge, CFrame.lookAt(at, at + tell.aim))
				else
					tell.ring.Transparency = alpha
					-- Closing on the radius it will hit: 1.9x down to 1x.
					local r = tell.radius * (1.9 - 0.9 * u)
					tell.ring.Size = Vector3.new(SHADOW_THICKNESS, r * 2, r * 2)
				end
			end
		end
	end
end

-- ---------------------------------------------------------------- off-screen

-- The raised camera shows the field in front of the player and a good part of
-- the flanks, but a volley opening behind them is off the frame. Every live
-- windup that is not on screen puts an arrow on the edge it lies past, in its
-- own colour - so the information is on screen even when the danger is not.
local ARROW_INSET = 0.12

local function stepArrows()
	local cam = camera()
	local used = 0
	if cam then
		local viewport = cam.ViewportSize
		local half = viewport * 0.5
		for _, tell in tells do
			if tell.active and used < ARROW_POOL then
				local point, onScreen = cam:WorldToViewportPoint(tell.at)
				if not onScreen then
					used += 1
					local arrow = arrows[used]
					-- Behind the camera projects inverted; flip it back so the
					-- arrow points at the threat rather than away from it.
					local dir = Vector2.new(point.X - half.X, point.Y - half.Y)
					if point.Z <= 0 then
						dir = -dir
					end
					if dir.Magnitude < 1e-3 then
						dir = Vector2.new(0, 1)
					end
					dir = dir.Unit
					local reach = math.min(half.X, half.Y) * (1 - ARROW_INSET)
					local at = half + dir * reach
					arrow.frame.Position = UDim2.fromOffset(at.X, at.Y)
					-- The glyph points up (screen -Y) at Rotation 0 and GUI
					-- rotation runs clockwise in a y-down space, so the angle
					-- that lands it on `dir` is atan2(x, -y), not atan2(y, x).
					arrow.frame.Rotation = math.deg(math.atan2(dir.X, -dir.Y))
					arrow.label.TextColor3 = tell.color
					arrow.frame.Visible = true
				end
			end
		end
	end
	for i = used + 1, ARROW_POOL do
		arrows[i].frame.Visible = false
	end
end

-- ---------------------------------------------------------------- lifecycle

local function onCreatureEvent(kind, position, extra)
	if type(kind) ~= "string" or typeof(position) ~= "Vector3" then
		return
	end
	local record = adaptEvent(kind, position, if type(extra) == "table" then extra else {})
	if not record then
		return -- not ours; CreatureEventController owns the rest of the channel
	end
	if record.what == "volley" then
		onVolley(record)
	elseif record.what == "stream" then
		onStream(record)
	elseif record.what == "pop" then
		onPop(record)
	elseif record.what == "tell" then
		onTell(record)
	end
end

local function clearAll()
	-- Collected first for the same reason stepVolleys collects: releaseVolley
	-- clears the entry, and the table cannot be modified while it is walked.
	local doomed = {}
	for _, volley in volleys do
		table.insert(doomed, volley)
	end
	for _, volley in doomed do
		releaseVolley(volley)
	end
	for _, tell in tells do
		hideTell(tell)
	end
end

-- Clears a drawn windup before its own clock runs out, by the id it arrived
-- with (or every live one, if called with nil).
--
-- Interrupting a boss mid-windup is a designed counter in this engine, and a
-- telegraph whose attack never comes is worse than a late one: players who
-- see a tell resolve into nothing stop trusting tells. So a marker keeps the
-- id of the tell that drew it and can be found again - what a retraction
-- would need. Nothing calls this yet: the wire kind that carries a
-- retraction is the server lane's to propose, and when it lands it maps to
-- this in one line of adaptEvent.
function ProjectileFxController.retireTell(id): number
	local cleared = 0
	for _, tell in tells do
		if tell.active and (id == nil or tell.id == id) then
			hideTell(tell)
			cleared += 1
		end
	end
	return cleared
end

function ProjectileFxController.init()
	folder = Instance.new("Folder")
	folder.Name = "WrackShot"
	folder.Parent = Workspace

	for i = 1, BULLET_POOL do
		bullets[i] = { part = makePart("Shot", Enum.PartType.Ball), owner = nil }
	end
	for i = 1, SHADOW_POOL do
		local part = makePart("ShotMark", Enum.PartType.Cylinder)
		part.Material = Enum.Material.SmoothPlastic
		shadows[i] = { part = part, owner = nil }
	end
	for i = 1, CHAIN_POOL do
		local bar = makePart("Chain", Enum.PartType.Block)
		local mark = makePart("ChainMark", Enum.PartType.Block)
		mark.Material = Enum.Material.SmoothPlastic
		chains[i] = { bar = bar, mark = mark, owner = nil }
	end
	for i = 1, LANTERN_POOL do
		local part = makePart("Lantern", Enum.PartType.Ball)
		part.Size = Vector3.new(0.2, 0.2, 0.2)
		part.Transparency = 1
		local light = Instance.new("PointLight")
		light.Color = SKIN.wisp.body
		light.Range = 22
		light.Brightness = 3
		light.Shadows = false
		light.Enabled = false
		light.Parent = part
		lanterns[i] = { part = part, light = light }
	end
	for i = 1, TELL_POOL do
		local lane = makePart("TellLane", Enum.PartType.Block)
		lane.Material = Enum.Material.Neon
		local edge = makePart("TellEdge", Enum.PartType.Block)
		local ring = makePart("TellRing", Enum.PartType.Cylinder)
		tells[i] = { lane = lane, edge = edge, ring = ring, active = false, startAt = 0, endsAt = 0 }
	end

	-- The off-screen arrows. One ScreenGui, six labels, never rebuilt.
	local gui = Instance.new("ScreenGui")
	gui.Name = "WrackThreatGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 5
	for i = 1, ARROW_POOL do
		local frame = Instance.new("Frame")
		frame.Name = "Threat" .. i
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.Size = UDim2.fromOffset(46, 46)
		frame.BackgroundTransparency = 1
		frame.Visible = false
		frame.Parent = gui
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamBold
		label.Text = "▲"
		label.TextSize = 34
		label.TextStrokeTransparency = 0.2
		label.TextColor3 = SKIN.cannon.body
		label.Parent = frame
		arrows[i] = { frame = frame, label = label }
	end
	gui.Parent = player:WaitForChild("PlayerGui")
end

function ProjectileFxController.start()
	Remotes.CreatureEvent.OnClientEvent:Connect(onCreatureEvent)

	-- Bullets are interpolated per FRAME, not per physics step: they are pure
	-- visuals on the client's own clock, and a ball moving 60 studs a second
	-- shows a Heartbeat's worth of stutter at this speed. One connection for
	-- all of them, one bulk move at the end (RangedFxController's pattern).
	RunService.RenderStepped:Connect(function()
		local now = os.clock()
		if liveVolleys > 0 then
			stepVolleys(now)
			stepLanterns(now)
		end
		stepTells(now)
		flushMoves()
		stepArrows()
	end)

	-- A respawn (or the fight ending under you) leaves nothing hanging in the
	-- air: the server's balls are gone with the boss, and a frozen wall of
	-- them on screen would read as live danger.
	player.CharacterAdded:Connect(clearAll)
end

return ProjectileFxController
