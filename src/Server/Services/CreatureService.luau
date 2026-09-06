--!nonstrict
-- CreatureService.luau
-- Owns every creature currently out of the water.
--
-- The performance shape the plan calls for, from the first creature onward:
-- creatures are plain structs in one flat array, updated by a single
-- Heartbeat, and the Model is only a view that gets PivotTo'd. No Humanoid,
-- no per-creature scripts. Behaviour (archetypes) slots into `update` later;
-- today every creature lands, lies flat and flops, and despawns after a
-- while only because nothing exists yet to fight it with. Every catch is
-- meant to be killed (user decision) - there is no auto-collect tier.
--
-- The one deliberate exception to "no physics" (user request, 2026-08-22):
-- the THROW. A landed catch is flung from the bobber toward the player by
-- the physics engine - welded into one assembly, unanchored, given a solved
-- ballistic velocity and a spin - so it tumbles through a visible arc and
-- lands at the player's feet. The moment it comes to rest it's re-anchored
-- and handed back to the CFrame loop, so physics only ever owns a creature
-- for a second or two and never during behaviour.
--
-- Orientation is read from the model's bounding box rather than hardcoded.
-- The Blender -> Studio import has rotated the fish mesh onto an axis we
-- couldn't predict twice running, so instead of guessing: the longest
-- bounding dimension is always nose-to-tail, the shortest is the flat side.
-- Those relationships survive whatever rotation the importer applied, so
-- laying the fish flat (flat side up, long axis horizontal) works for any
-- import and for the plain-parts stand-in alike.
--
-- Pooling (reusing models instead of building per spawn) is deliberately
-- not here yet: with one creature per cast and a handful of rows, a clone
-- per spawn is fine, and the pool is easier to add once the archetype loop
-- exists to show what state actually needs resetting.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Bosses = require(Shared.Data.Bosses)
local Creatures = require(Shared.Data.Creatures)
local BossArenas = require(Shared.Config.BossArenas)
local BrinejawPath = require(Shared.Modules.BrinejawPath)
local NoctyssPath = require(Shared.Modules.NoctyssPath)
local KrakenPath = require(Shared.Modules.KrakenPath)
local RimefangPath = require(Shared.Modules.RimefangPath)
local PyreliskPath = require(Shared.Modules.PyreliskPath)
local CreatureModel = require(Shared.Modules.CreatureModel)
-- Boss weather windows (an attack's `storm` block) go out on the world
-- event remote, the way the island blizzards already do.
local Remotes = require(Shared.Net.Remotes)
local Tuning = require(Shared.Config.Tuning)
local World = require(Shared.Config.World)

-- For the hostile archetypes' contact damage. PlayerService is listed above
-- this service in the boot order.
local Hazards = require(script.Parent.Parent.Modules.Hazards)
local PlayerService = require(script.Parent.PlayerService)
-- For the islands' playable-area bounds (clampToBounds / inlandDirection).
-- WorldService boots first.
local WorldService = require(script.Parent.WorldService)

-- ProgressionService boots AFTER this service (it listens to Killed), so the
-- thief's pickpocketing requires it lazily, at call time, never at load.
local function progression()
	return require(script.Parent.ProgressionService)
end

local CreatureService = {}

local C = Tuning.Creature

-- Per-row override of a Tuning.Creature knob (hostile revamp): a kitted row
-- may carry `tuning = { KEY = n }`; everything else reads the global.
local function tune(creature, key: string)
	local t = creature.row.tuning
	return (t and t[key]) or C[key]
end

-- Forward declarations: the kit engine (mid-file) delegates locomotion into
-- ARCHETYPE_UPDATERS (populated after every updater is defined), and the
-- health/hit paths above it consult the gimmick registry defined with it.
local ARCHETYPE_UPDATERS
local gimmickOf
local Perks = Tuning.Perks

-- Flat array of creature structs; see `spawn` for the fields.
local creatures = {}
-- Model -> struct, so a hit on a part can find its creature in O(1).
local byModel: { [Model]: any } = {}
local folder: Folder

-- Fired on the server with (row, grade, killer: Player?) when a creature's
-- health reaches zero. Loot / XP / style payout hang off this later; nothing
-- listens yet.
CreatureService.Killed = Instance.new("BindableEvent")

-- Attribute names on the creature Model. They replicate on their own, so a
-- client health bar can just read / listen to these without a remote.
local ATTR_ID = "CreatureId"
local ATTR_HEALTH = "Health"
local ATTR_MAX_HEALTH = "MaxHealth"
-- Motion cues for CreatureVfxController (client): in the air, came down,
-- and a counter that ticks once per flop.
local ATTR_THROWN = "Thrown"
local ATTR_LANDED = "Landed"
local ATTR_FLOPS = "Flops"
-- Enemy states for CreatureEventController (client). All booleans, each set
-- only by the archetype that owns it; one-off moments go through the
-- CreatureEvent remote instead (fireEvent below).
local ATTR_DASHING = "Dashing" -- charger: mid-dash (streak)
local ATTR_EXPOSED = "Exposed" -- charger: turning back, takes double damage (dazed tell)
local ATTR_BURIED = "Buried" -- burrower: under the sand, hidden + untargetable
local ATTR_OPEN = "Open" -- mimic: gaping, hittable
local ATTR_CHARGING = "Charging" -- pulser: charging up, hitting it shocks you
-- Island bosses (BossHudController reads the name; CreatureEventController
-- the rage).
local ATTR_STUNNED = "Stunned" -- dazed by a stun bait: flops helplessly, can't act
-- The one creature that is NOT an enemy: Split Roe's hatchling, which fights
-- on the player's side. Clients key off this to draw it as an ally rather than
-- a target (a green bar instead of the enemy red - CombatFeedbackController).
local ATTR_FRIENDLY = "Friendly"
-- Volcano tells (docs/volcano-content-spec.md).
local ATTR_CRACKED = "Cracked" -- crust: the slag is broken, the core is exposed
local ATTR_DOWNED = "Downed" -- reborn: dead once, about to rise again

-- The client-event helper (fireEvent) lives down with the archetypes, but the
-- kill and damage paths above it need to fire tells too. Assigned there.
local fireCreatureEvent
local ATTR_BOSS_NAME = "BossName" -- the boss's title, set when it rises
local ATTR_ENRAGED = "Enraged" -- below Bosses.enrageBelow health: faster, harder

local function randomBetween(lo: number, hi: number): number
	return lo + math.random() * (hi - lo)
end

local function smoothstep(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

-- ============================================================ orientation

-- A rotation (no translation) that lays the model flat: its longest local
-- axis -> world +X (horizontal), its shortest -> world +Y (up, so the fish
-- rests on its broad side), the middle axis -> world +Z. Derived from the
-- bounding box so it's correct regardless of how the mesh imported. The
-- model must be freshly built (unrotated) when this is measured.
--
-- Also returns half the shortest dimension: how far the centre sits above
-- whatever the fish is lying on.
local function flatOrientation(model: Model): (CFrame, number)
	local _, size = model:GetBoundingBox()

	local comps = {
		{ axis = Vector3.xAxis, mag = size.X },
		{ axis = Vector3.yAxis, mag = size.Y },
		{ axis = Vector3.zAxis, mag = size.Z },
	}
	table.sort(comps, function(a, b)
		return a.mag > b.mag
	end)

	local long = comps[1].axis -- nose-tail
	local short = comps[3].axis -- flat side
	local mid = long:Cross(short) -- dorsal-belly, sign chosen for a proper rotation

	-- Columns of R = [long short mid]^T : R maps long->X, short->Y, mid->Z.
	local rotation = CFrame.fromMatrix(
		Vector3.zero,
		Vector3.new(long.X, short.X, mid.X),
		Vector3.new(long.Y, short.Y, mid.Y),
		Vector3.new(long.Z, short.Z, mid.Z)
	)
	return rotation, comps[3].mag / 2
end

-- Stands an upright creature (a biped) as-built instead of laying it flat.
-- Its procedural model is authored Y-up (feet down, head up, per
-- CreatureModel.buildZombie), so the resting "orientation" is just identity -
-- no bounding-box axis guessing (which is what lays fish on their side).
-- Returns identity plus the clearance from the pivot (PrimaryPart) down to the
-- lowest point, so the feet rest on the ground rather than the model's centre.
local function uprightOrientation(model: Model): (CFrame, number)
	local pivotY = if model.PrimaryPart then model.PrimaryPart.Position.Y else model:GetPivot().Position.Y
	local boxCFrame, boxSize = model:GetBoundingBox()
	local bottomY = boxCFrame.Position.Y - boxSize.Y / 2
	return CFrame.identity, math.max(0.1, pivotY - bottomY)
end

-- Yaw (about world up) that swings the flat-laid long axis (+X) onto
-- `direction`, ignoring its vertical component.
local function yawToward(direction: Vector3?): number
	if not direction then
		return 0
	end
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 0.001 then
		return 0
	end
	return math.atan2(-flat.Z, flat.X)
end

-- The resting CFrame for a creature lying flat at its `pos` with its
-- heading, before any flop offsets.
local function restCFrame(creature): CFrame
	return CFrame.new(creature.pos) * CFrame.Angles(0, creature.yaw0, 0) * creature.flat
end

-- ============================================================ throw

-- Initial velocity that carries a body from `from` to `to` under `gravity`,
-- peaking THROW_APEX studs above the start (higher if the target itself is
-- up there). Plain projectile algebra: go up to the apex, fall from the apex
-- to the target height, and spread the horizontal distance over that total
-- time. Also returns the flight time so the landing check knows roughly
-- when to start looking.
local function launchVelocity(from: Vector3, to: Vector3, gravity: number): (Vector3, number)
	local delta = to - from
	local flat = Vector3.new(delta.X, 0, delta.Z)

	-- A full arc's clearance ABOVE the landing however far uphill it is: a
	-- catch thrown 35 studs up out of the volcano's lake used to peak two
	-- studs over the rim and clip the cliff's edge on the way (2f, 2026-08-23).
	local apex = math.max(C.THROW_APEX, delta.Y + C.THROW_APEX)
	local vy = math.sqrt(2 * gravity * apex)
	local timeUp = vy / gravity
	local timeDown = math.sqrt(2 * math.max(apex - delta.Y, 0.1) / gravity)
	local flight = timeUp + timeDown

	local horizontal = if flat.Magnitude > 0.01 then flat.Unit * (flat.Magnitude / flight) else Vector3.zero
	return horizontal + Vector3.new(0, vy, 0), flight
end

-- Hands the creature to the physics engine: unanchor, counter some of
-- gravity for a floatier arc, and fling it at `target` with a tumble.
local function launch(creature, target: Vector3, now: number)
	local model = creature.model
	local body = model.PrimaryPart
	if not body then
		return false
	end

	local gravityScale = math.clamp(C.THROW_GRAVITY_SCALE, 0.05, 1)
	local velocity, flight = launchVelocity(body.Position, target, Workspace.Gravity * gravityScale)

	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = false
		end
	end
	-- Only the body collides, so it lands on the dock / sand / water surface
	-- (the ocean is a solid part) without fins snagging on things.
	body.CanCollide = true

	if gravityScale < 1 then
		-- A constant upward force cancelling (1 - scale) of the body's weight,
		-- so the assembly falls at scale * g and the arc hangs in the air long
		-- enough to actually watch. Removed again at landing.
		local attachment = Instance.new("Attachment")
		attachment.Name = "ThrowLift"
		attachment.Parent = body

		local lift = Instance.new("VectorForce")
		lift.Name = "ThrowLift"
		lift.Attachment0 = attachment
		lift.RelativeTo = Enum.ActuatorRelativeTo.World
		lift.ApplyAtCenterOfMass = true
		lift.Force = Vector3.new(0, body.AssemblyMass * Workspace.Gravity * (1 - gravityScale), 0)
		lift.Parent = body
		creature.lift = { attachment = attachment, force = lift }
	end

	-- The server simulates the flight so where it lands is the server's
	-- call; clients just watch the replicated arc.
	body:SetNetworkOwner(nil)
	body.AssemblyLinearVelocity = velocity

	-- Tumble nose-over-tail: spin about the horizontal axis perpendicular to
	-- the direction of travel.
	local flatDir = Vector3.new(velocity.X, 0, velocity.Z)
	local spinAxis = if flatDir.Magnitude > 0.01 then flatDir.Unit:Cross(Vector3.yAxis) else Vector3.xAxis
	body.AssemblyAngularVelocity = spinAxis * C.THROW_SPIN

	creature.state = "flying"
	creature.launchedAt = now
	creature.flight = flight
	model:SetAttribute(ATTR_THROWN, true)
	return true
end

-- Raycast filter that ignores creatures and every character, so the ground
-- under a landed fish is the dock / island / ocean surface and not a leg.
-- RespectCanCollide keeps it to solid geometry: it grounds on sand / dock /
-- rock / ocean and passes through the non-collidable palm fronds, bushes and
-- foam (WorldService sets CanCollide by name), which is also exactly what the
-- horizontal obstacle check below wants - stop at a trunk or boulder, not a
-- leaf.
local function groundParams(): RaycastParams
	local ignore = { folder }
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(ignore, player.Character)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.RespectCanCollide = true
	return params
end

-- The resting position on whatever surface sits under `at` (its X/Z; the Y is
-- only the ray's start hint): the surface height plus the fish's half-thickness
-- and the small clearance, and never below the water. Used both when a thrown
-- fish settles and every frame it's sliding under knockback, so the fish
-- always sits on the ground rather than through it.
local function groundedPos(at: Vector3, halfThickness: number): Vector3
	-- Every resting position passes through here, so this is where a creature
	-- is kept inside its island's playable area (the volcano's rim ring +
	-- pier): a shove, a lunge, a tunnel or a flop can't carry it off the rim
	-- or into the lava. Islands without bounds (the starter) are untouched.
	at = WorldService.clampToBounds(at)
	local hit = Workspace:Raycast(Vector3.new(at.X, at.Y + 4, at.Z), Vector3.new(0, -12, 0), groundParams())
	if not hit then
		-- Nothing within reach below. The bounds clamp only moves X/Z, so a
		-- creature pulled back onto the volcano's rim from over the lake is
		-- still at lake height, 35 studs under the rim it's now "on" - look
		-- again from well above for the ground at this X/Z (the rim, the
		-- pier). Short probe first so a creature under the rock arch keeps
		-- the ground it's on rather than popping onto the arch.
		hit = Workspace:Raycast(Vector3.new(at.X, at.Y + 260, at.Z), Vector3.new(0, -(260 + 12), 0), groundParams())
	end
	-- Still nothing (open sea; the lava lake is a non-collidable surface):
	-- keep the height it already has rather than dropping to the waterline -
	-- a lava-caught creature must not sink 200 studs into the mountain.
	-- Never below the water either way.
	local surfaceY = if hit then hit.Position.Y else at.Y - halfThickness - C.SURFACE_OFFSET
	surfaceY = math.max(surfaceY, World.WATER_Y)
	return Vector3.new(at.X, surfaceY + halfThickness + C.SURFACE_OFFSET, at.Z)
end

-- Takes the creature back from physics wherever it came to rest: freeze it,
-- work out the resting pose on whatever surface is underneath, and ease
-- into that pose (the tumble almost never ends perfectly flat, and a snap
-- would read as a glitch).
local function settle(creature, now: number)
	local model = creature.model
	local body = model.PrimaryPart

	if creature.lift then
		creature.lift.force:Destroy()
		creature.lift.attachment:Destroy()
		creature.lift = nil
	end
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
		end
	end

	local landed = if body then body.Position else model:GetPivot().Position

	creature.pos = groundedPos(landed, creature.halfThickness)
	creature.yaw0 = yawToward(creature.target and (creature.target - creature.pos))

	creature.state = "settling"
	creature.settleFrom = model:GetPivot()
	creature.settleStart = now
	creature.nextFlopAt = now + C.THROW_SETTLE_TIME + randomBetween(C.FLOP_REST_MIN, C.FLOP_REST_MAX)

	model:SetAttribute(ATTR_THROWN, false)
	model:SetAttribute(ATTR_LANDED, true)
end

-- ============================================================ spawning

-- Spawns `row` at `position` (the bobber - a point on the water) and throws
-- it at `target` (the player's root position) in a visible arc; it lands a
-- little short of the player and comes to rest there facing them. With no
-- target it simply surfaces and rests where it is. `grade` is the reel
-- grade that produced it; unused until combat gives a stunned/enraged
-- opening meaning, carried so it isn't lost.
-- `extra` is an optional bag of per-instance data carried untouched to the
-- Killed event's 4th value (a cast's bait bounty, say) - any key the engine
-- doesn't set itself (loot, participants) passes straight through.
function CreatureService.spawn(row, position: Vector3, target: Vector3?, grade: string?, extra: { [string]: any }?)
	local model = CreatureModel.build(row)
	-- A shrunken instance of an ordinary row (an ooze's halves). Scaled BEFORE
	-- the orientation is measured, or `halfThickness` would describe the
	-- full-size body and the little one would float.
	if extra and type(extra.scale) == "number" and extra.scale > 0 and extra.scale ~= 1 then
		model:ScaleTo(extra.scale)
	end
	-- Fish (and the crab) lie flat on their side, oriented from the bounding
	-- box; upright bipeds (the drowned) stand as-built. See the two helpers.
	local flat, halfThickness
	if row.body.stance == "upright" then
		flat, halfThickness = uprightOrientation(model)
	else
		flat, halfThickness = flatOrientation(model)
	end

	grade = grade or "Neutral"
	local gradeTuning = Tuning.Grade[grade] or Tuning.Grade.Neutral
	local healthMult = if extra and type(extra.healthMult) == "number" then extra.healthMult else 1
	local maxHealth = math.max(1, math.floor(row.health * gradeTuning.healthMult * healthMult + 0.5))

	local now = os.clock()
	local creature = {
		row = row,
		model = model,
		grade = grade,
		target = target,
		extra = extra, -- passed through to Killed (see kill)
		-- A stun bait (Glowchum) lands the catch dazed: for this long its
		-- archetype loop is suspended, so even a hostile just flops there and
		-- you get free hits. Set from the cast's bait, so it costs nothing
		-- when there is none.
		stunnedUntil = if extra and extra.stun then os.clock() + extra.stun else nil,

		-- A companion (Split Roe's hatchling) rather than a catch: it fights
		-- hostiles for its owner, the player's own swings pass through it
		-- (inRange skips it), and it leaves when its clock runs out instead of
		-- on the LINGER timer, which only makes sense for something you're
		-- supposed to be killing.
		friendly = if extra and extra.friendly then true else nil,
		owner = extra and extra.owner,
		expiresAt = if extra and extra.lifetime then os.clock() + extra.lifetime else nil,

		-- A raid mob or a Kraken tentacle must not evaporate mid-fight just
		-- because nobody hit it for LINGER seconds: `noLinger` exempts it from
		-- the left-alone despawn exactly like a boss (its owner - RaidService,
		-- the finale - despawns or releases it deliberately instead).
		noLinger = if extra and extra.noLinger then true else nil,

		-- Hit points. Damage only ever comes through CreatureService.damage
		-- (server), which keeps these and the replicated attributes in step.
		maxHealth = maxHealth,
		health = maxHealth,
		dead = false,
		halfThickness = halfThickness,
		flat = flat, -- lays the fish on its side; from the bounding box
		spawnedAt = now,
		-- The despawn timer counts from the last time it was fought (took a
		-- hit), not from spawn: a creature stays as long as the player keeps
		-- attacking it and only vanishes after LINGER seconds of being left
		-- alone. Reset in CreatureService.damage.
		lastFoughtAt = now,

		-- "flying" (physics owns it), "settling" (easing into the rest
		-- pose), or "resting" (the CFrame loop: idle wiggle + flops).
		state = "resting",
		pos = nil, -- resting point, set when it lands
		yaw0 = 0, -- heading, set when it lands

		-- Flop state. Between flops the fish only idle-wiggles; a flop is a
		-- short vertical hop with a bigger side-to-side swish and a little
		-- nose pitch. It never rolls over - it stays belly-down-ish, flat.
		flopStart = nil,
		flopDuration = 0,
		swishDir = 1,
		pitchDir = 1,
		nextFlopAt = now + randomBetween(C.FLOP_REST_MIN, C.FLOP_REST_MAX),
	}

	-- Start just above the bobber, already flat and pointed at the player,
	-- so the first frame of the throw looks right. `position` carries the
	-- surface's own height (the waterline, or the lava lake up in the
	-- volcano's crater), so the throw starts from wherever it was hooked.
	local start = Vector3.new(position.X, position.Y + C.THROW_START_HEIGHT, position.Z)
	creature.pos = start
	creature.yaw0 = yawToward(target and (target - start))
	model:PivotTo(restCFrame(creature))

	model:SetAttribute(ATTR_ID, row.id)
	model:SetAttribute(ATTR_MAX_HEALTH, maxHealth)
	model:SetAttribute(ATTR_HEALTH, maxHealth)
	if creature.friendly then
		model:SetAttribute(ATTR_FRIENDLY, true)
	end
	model.Parent = folder

	table.insert(creatures, creature)
	byModel[model] = creature

	if target then
		-- Land past the player on the inland side, at about their feet (the
		-- root part sits THROW_TARGET_DROP above the ground they stand on).
		-- "Inland" is toward the island's centre at the origin, so from the
		-- dock it flies over the player and comes down back along the planks,
		-- and from the beach it lands up the sand behind them. If the player
		-- is standing right at the origin, fall back to continuing the
		-- bobber -> player line instead.
		-- On an island with a bounded playable area (the volcano's rim ring)
		-- "inland" is whatever keeps it on the rim - WorldService knows.
		local inland = WorldService.inlandDirection(target)
		-- THROW_PAST overshoots past the player onto the "safe" side. That is only
		-- actually safe when the island's bounds will pull an over-shot landing
		-- back onto the playable area: on the volcano the safe side is a NARROW
		-- rim (overshoot outward = off the mountain) or the crater is right there
		-- (overshoot inward = into the lava). inlandDirection returns a zero vector
		-- when NO bounds cover the player (an unsampled rim, or an island with
		-- none), and clampToBounds is then a no-op - so in that case do NOT
		-- overshoot: aim at the player's own feet, which is provably solid ground,
		-- steering only enough to face the throw along the bobber -> player line.
		local past = C.THROW_PAST
		if inland.Magnitude < 1 then
			inland = Vector3.new(target.X - start.X, 0, target.Z - start.Z)
			past = 0
		end
		inland = if inland.Magnitude > 0.01 then inland.Unit else Vector3.zero
		local landing =
			WorldService.clampToBounds(Vector3.new(target.X, target.Y - C.THROW_TARGET_DROP, target.Z) + inland * past)
		if launch(creature, landing, now) then
			return model
		end
	end

	-- No target (or no body to throw): rest on the surface where it surfaced.
	creature.pos = Vector3.new(start.X, position.Y + halfThickness + C.SURFACE_OFFSET, start.Z)
	model:PivotTo(restCFrame(creature))
	return model
end

-- Forward: the parts-ring teardown, defined with the health section below
-- (it needs `removeAt`, which needs the `updating` flag, both of which are
-- declared down there). The declaration exists so THIS despawn can call it -
-- it is not a leftover, do not tidy it away. Without the call, a creature
-- that owns a ring and leaves by the linger sweep strands its parts as
-- invulnerable orphans, which is exactly the bug removeOwnedParts exists to
-- close on the other two exits.
local removeOwnedParts
-- Same reason, same idiom: `kill` sits above the maw window's code but has to
-- be able to tear its floor down. A leaked floor is an invisible solid
-- platform left standing over the arena's pit forever.
local clearMawFloor
-- And the third of the same shape: Pyrelisk's climb route, which is eight
-- anchored slabs from the rim path up onto the colossus's back (four bone
-- plates, the shoulder bridge, and one per deck - three of those since the
-- 2026-09-01 rebuild). Same failure
-- if it leaks, two hundred studs higher up.
local clearPyreliskMount

local function despawn(index: number)
	local creature = creatures[index]
	-- Flagged dead even though nothing killed it: anything still holding the
	-- struct (a gun shot in flight, a skythief's steal target) must see a
	-- lingered-out creature as gone, or it lands damage - loot pipeline and
	-- all - on a ghost whose model is already destroyed (review find,
	-- 2026-08-25).
	creature.dead = true
	byModel[creature.model] = nil
	creature.model:Destroy()
	-- Swap-remove: order doesn't matter and this keeps removal O(1).
	local last = #creatures
	creatures[index] = creatures[last]
	creatures[last] = nil
	-- Its ring goes with it, and it goes HERE, after the swap - not before.
	-- removeOwnedParts swap-removes each part too, which can move THIS
	-- creature to a different index; tearing down first would leave `index`
	-- pointing at an innocent struct and the swap above would drop that one
	-- from the array instead (a live creature nothing updates again). By this
	-- line `index` is spent and the owner is already out of the array, and
	-- the parts still find it: removeOwnedParts matches on struct identity,
	-- not position. Free for the 99% case - it returns at once when
	-- partsAlive is nil.
	removeOwnedParts(creature)
end

-- ============================================================ health

-- The creature struct a part belongs to, or nil if the part isn't a
-- creature. This is how a melee hit resolves what it touched.
function CreatureService.findByPart(part: Instance?): any?
	local node = part
	while node and node ~= folder do
		if node:IsA("Model") and byModel[node] then
			return byModel[node]
		end
		node = node.Parent
	end
	return nil
end

-- ONE ANSWER TO "CAN THIS BE PICKED AS A TARGET", read by everything that
-- picks one.
--
-- A creature can be un-hittable for two unrelated reasons, and until now only
-- one of them reached the code that CHOOSES what to shoot. `untargetable` is
-- the imperative flag - a dive, a burrow, a shut lid - and every consumer
-- honoured it. `vulnerableWhen` is the declarative one, written on the row,
-- and only `damage()` honoured it. So `raycastNearest` would happily select an
-- immune boss body, `damage()` would then return nil, and the shot did nothing
-- whatsoever with no feedback - which reads as a broken weapon, not a miss.
--
-- That is not a small gap, because an immune boss body is the largest capture
-- cylinder in its own arena. `raycastNearest` takes anything within
-- `shotRadius + hitRadius` of the ray and keeps the nearest ALONG it: measured
-- at 38.5 studs for the Kraken's head against an arm ring at 46, so five of
-- its eight arms could not be shot from any bearing; Wrack's hull at 23.4
-- against a 20-stud battery ring shadows two or three of the four. Both are
-- fights whose whole premise is "shoot the parts". Melee escaped it only
-- because `inRange` is called with `skipRangedOnly` and both rows are ranged.
--
-- `creature.untargetable` keeps its writers and its meaning exactly as they
-- are. This adds a second input to the READ, so there is no second owner of
-- the flag and no mode transition to race against.
-- Defined with the punish window, far below, because that is where the reach
-- is reasoned about; forward-declared here because target selection needs the
-- same ruling `damage()` uses and must not carry a second copy of it.
local noctyssInReach

-- RIMEFANG'S HIDE IS A CHAIN, NOT A BALL, and the two functions below are the
-- first things that have to know it. `creature.pos` is the whale's NOSE and
-- the animal is 56 studs long behind it, so a pivot sphere leaves everything
-- from the shoulder aft visible, solid-looking and unswingable - the beached
-- body during the punish window included, which is the fight's only kill
-- window. Returns the sampled spine (nil for every other creature, so nothing
-- else changes by a stud); defined with the whale's body far below, because
-- that is where the pose it reads is computed.
local rimefangBody
-- A shot that visibly clips the hide should land - the same generosity
-- `shotRadius` grants every other creature (half its bounding sphere). Here
-- it is a flat allowance on top of the sampled girth, because the whale's own
-- model is invisible and its bounding box is the authority stand-in, not the
-- animal the client draws.
local RF_SHOT_SLACK = 2.0

-- `from` is the ATTACKER'S position when the caller has one (a swinger's root,
-- a shot's re-validated origin). It only matters for a window that is
-- positional as well as timed - see the `markedDown` branch. Callers that
-- cannot name a shooter (an urchin's blast, an arc shell's re-check at its
-- landing point) pass nothing and get the old, purely-declarative answer.
local function unaimable(creature, from: Vector3?): boolean
	if creature.untargetable then
		return true
	end
	local when = creature.row and creature.row.vulnerableWhen
	if when == "partsDown" then
		-- The Kraken's head, Wrack's hull: immune while any of the ring stands.
		return (creature.partsAlive or 0) > 0
	elseif when == "markedDown" then
		-- Noctyss is under the shelf until the true lure breaks.
		if not creature.mawOpen then
			return true
		end
		-- ...and while it IS open she is only hittable from inside the mouth,
		-- which `damage()` enforces off the same `noctyssInReach`. Target
		-- selection has to agree, or the gap re-opens one level up: her body is
		-- the biggest capture cylinder on the arena (14.4 hitRadius plus a
		-- ~14-stud shot radius), so a DMR from the shelf SELECTS her, `damage`
		-- returns nil, and the shot does nothing at all - a broken weapon, not
		-- a miss. Worse, a shot aimed at a lantern stalk across the pit is
		-- eaten by her body on the way. Unaimable to an out-of-reach shooter,
		-- the same shot passes through to the stalk (or the water) behind her.
		if from ~= nil and creature.pose ~= nil and not noctyssInReach(creature.pose, from) then
			return true
		end
		return false
	end
	return false
end

-- Every live creature whose centre is within `radius` of `position`, nearest
-- first. For attacks that check reach rather than raycast.
-- `opts.skipRangedOnly` drops rows flagged `rangedOnly` (the Kraken's head):
-- the MELEE target pick passes it, so swings reach past the head to the
-- tentacles. Ranged fire does not pass it, and no longer needs to - the head
-- is skipped by `unaimable` above while it is immune, which is the general
-- form of the same idea and applies to every consumer rather than just this
-- one. (`rangedOnly` remains a separate statement: it says which WEAPONS a
-- row answers to at all, not whether it can be hurt right now.)
-- `opts.from` is the attacker's own position, when the caller's `position` is
-- not already it: a splash asks about a blast point, not a swinger. Only the
-- melee pick passes it today. Absent, nothing changes for anyone.
function CreatureService.inRange(
	position: Vector3,
	radius: number,
	opts: { skipRangedOnly: boolean?, from: Vector3? }?
): { any }
	local skipRangedOnly = opts ~= nil and opts.skipRangedOnly == true
	local from = opts ~= nil and opts.from or nil
	local hits = {}
	for _, creature in creatures do
		-- A buried lurker or a shut mimic is simply not there to be hit; the
		-- swing reaches past it to the next-nearest creature. Nor is your own
		-- hatchling: CombatService swings at the NEAREST thing this returns, so
		-- leaving a companion in the list would mean punching your own pet the
		-- moment it got between you and the enemy. It can still be damaged
		-- through CreatureService.damage (an urchin's blast catches it) - it's
		-- untargetable by the player, not invulnerable.
		if
			not creature.dead
			and not unaimable(creature, from)
			and not creature.friendly
			and not (skipRangedOnly and creature.row.rangedOnly)
		then
			-- A boss's body extends well past its pivot (`hitRadius`, from
			-- Bosses.luau scaled by the row); reach is measured to its hide,
			-- not its centre, or a 26-stud boss at stand-off is unhittable.
			--
			-- ...and one boss's hide is not a sphere at all. Rimefang is 56
			-- studs of whale laid out BEHIND its pivot, so the single sphere
			-- capped melee at ~22.7 studs from the nose and made the other
			-- two thirds of the animal scenery. For it, reach is measured to
			-- the nearest point on the sampled spine. `rimefangBody` returns
			-- nil for everything else, which keeps this branch dead for every
			-- other creature in the game.
			local distance
			local body = rimefangBody(creature)
			if body then
				distance = math.huge
				for _, node in body do
					local d = (node.pos - position).Magnitude - node.radius
					if d < distance then
						distance = d
					end
				end
			else
				distance = (creature.model:GetPivot().Position - position).Magnitude - (creature.hitRadius or 0)
			end
			if distance <= radius then
				table.insert(hits, { creature = creature, distance = distance })
			end
		end
	end
	table.sort(hits, function(a, b)
		return a.distance < b.distance
	end)
	local result = {}
	for i, hit in hits do
		result[i] = hit.creature
	end
	return result
end

-- The first live creature along a ray, nearest first - the creature half of a
-- ranged shot (CombatService's hitscan). The parts are CanQuery = false, so a
-- real raycast can't see them; this is the "proximity, not raycast" philosophy
-- applied to a line: a creature counts when the ray passes within its shot
-- radius (half its bounding sphere, floored so a thin fish is still hittable,
-- plus a boss's hitRadius). Returns the creature and the distance along the
-- ray, or nil.
function CreatureService.raycastNearest(origin: Vector3, direction: Vector3, maxDistance: number): (any?, number?)
	if direction.Magnitude < 0.001 then
		return nil, nil
	end
	local dir = direction.Unit
	local best, bestT = nil, maxDistance
	for _, creature in creatures do
		-- `origin` is the shooter's own position, not the camera's: CombatService
		-- takes it from the client but ShotAim.originOk refuses any origin more
		-- than ORIGIN_SLACK (6) studs off the firer's root.
		if not creature.dead and not unaimable(creature, origin) and not creature.friendly then
			-- ONE BOSS IS A LINE, NOT A POINT. Rimefang's body is 56 studs of
			-- whale behind its pivot, so the sphere below could only ever
			-- capture a shot aimed at the head. Each spine sample is its own
			-- capture sphere and the nearest one along the ray wins, exactly
			-- as the pivot sphere does for everything else - so a shot at the
			-- flank or the fluke lands where it looks like it should.
			local body = rimefangBody(creature)
			if body then
				for _, node in body do
					local to = node.pos - origin
					local t = to:Dot(dir)
					if t > 0 and t < bestT and (to - dir * t).Magnitude <= node.radius + RF_SHOT_SLACK then
						best, bestT = creature, t
					end
				end
			else
				local pivot = creature.model:GetPivot().Position
				local to = pivot - origin
				local t = to:Dot(dir)
				-- A TALL BODY IS A CAPSULE, NOT A BALL. The test below measures the
				-- ray's distance from the PIVOT, which is a sphere sitting wherever
				-- the model's pivot is - at the feet, for anything that stands. That
				-- is right for a fish and right for every boss whose body is about as
				-- tall as it is wide, and it quietly fails for a colossus: Pyrelisk is
				-- 263 studs of body over a pivot at the lake's surface with a 96-stud
				-- hitRadius, so a shot aimed at its chest seam passes ~156 studs off
				-- the pivot and is dropped. Ranged fire landed on the lower third of
				-- the body and nothing above it - in a fight whose whole premise is
				-- shooting the seams.
				--
				-- Raising hitRadius is NOT the fix and is the trap: `inRange` measures
				-- MELEE off the same number, and Pyrelisk's 96 was chosen so that 96 +
				-- the longest reach in Weapons (16) still lands eight studs inside the
				-- lava lake. Every stud added there is a stud of free melee across the
				-- moat, which is the one thing the arena's geometry exists to forbid.
				--
				-- `hitHeight` is opt-in and nil on every creature that exists today
				-- (only the colossus branch of updateBoss sets it), so this whole
				-- block is skipped and every other creature's capture is the same
				-- sphere, from the same pivot, to the same stud, as before.
				local axis = creature.hitHeight
				if axis then
					-- The closest point on the body's own axis (pivot up to pivot +
					-- axis) to this ray, standing in for the pivot from here on: `to`
					-- and `t` keep their meanings and the test below is untouched.
					local b = dir.Y
					local denom = 1 - b * b
					local w = origin - pivot
					local s
					if denom > 1e-6 then
						s = math.clamp((w.Y - b * dir:Dot(w)) / denom, 0, axis)
					else
						-- Fired straight up or straight down the body: every height on
						-- the axis is the same distance from the ray, so take the one
						-- level with the shooter rather than dividing by zero.
						s = math.clamp(-w.Y, 0, axis)
					end
					to = (pivot + Vector3.new(0, s, 0)) - origin
					t = to:Dot(dir)
				end
				if t > 0 and t < bestT then
					local radius = creature.shotRadius
					if not radius then
						-- Half the bounding sphere reads generous on purpose - a
						-- shot that visibly clips a fin should land. Cached: the
						-- model's size doesn't change (the bloater's swell is the
						-- one exception, and being EASIER to hit as it swells is
						-- correct anyway).
						local _, size = creature.model:GetBoundingBox()
						radius = math.max(1.4, size.Magnitude * 0.3)
						creature.shotRadius = radius
					end
					local perpendicular = (to - dir * t).Magnitude
					if perpendicular <= radius + (creature.hitRadius or 0) then
						best, bestT = creature, t
					end
				end
			end
		end
	end
	return best, bestT
end

-- True while update() is walking the creature array. A kill that happens
-- INSIDE the walk (an urchin's fuse, an explosion taking its neighbours) must
-- not swap-remove under the loop's feet, so it leaves the struct in place
-- flagged `dead` (model already gone) and the walk sweeps it.
local updating = false

-- Array bookkeeping only; the model is the caller's problem.
local function removeAt(index: number)
	local creature = creatures[index]
	byModel[creature.model] = nil
	local last = #creatures
	creatures[index] = creatures[last]
	creatures[last] = nil
end

-- A RING'S OWNER IS LEAVING WITHOUT DYING: take its parts with it.
--
-- Every parts boss - the Kraken's eight arms, Noctyss's seven stalks - hands
-- each part a `partOf` pointer at the owner's struct, and `kill` walks the
-- ring down when the owner dies. That is only the DEATH path. A boss taken
-- out by the abandon reaper, or dropped by the walk when its model vanishes
-- from under it, used to leave its parts standing: live structs attacking on
-- behalf of an owner nothing will ever update again, counting down a
-- `partsAlive` no one reads, on an arena the island is free to summon a
-- second boss into. So the link is severed as well as the struct - a part
-- can never be left pointing at a ghost.
--
-- Generic on purpose: this is the parts-ring contract, not one boss's. All
-- three exits a ring owner can take now run it: CreatureService.despawn, the
-- walk's parentless-model drop, and the linger sweep's `despawn` above (which
-- is why that one is forward-declared - see the note there).
--
-- THE INVARIANT: nothing may remove a creature from `creatures` without
-- coming through here first. `kill` is the one exception, and only because it
-- walks the ring down itself.
--
-- No `local` - this fills the forward declaration made above `despawn`.
function removeOwnedParts(creature)
	-- An owner going away takes its punish-window floor with it, if it had one.
	if clearMawFloor then
		clearMawFloor(creature)
	end
	if clearPyreliskMount then
		clearPyreliskMount(creature)
	end
	if creature.partsAlive == nil then
		return
	end
	-- Collected first: removal swap-removes, and mutating the array under
	-- its own scan is how you skip half a ring.
	local doomed = {}
	for _, part in creatures do
		if part.partOf == creature then
			part.partOf = nil
			if not part.dead then
				table.insert(doomed, part)
			end
		end
	end
	for _, part in doomed do
		-- Removed, not killed: nobody earned these. No Killed event, no loot,
		-- no drops - the same bargain CreatureService.despawn strikes.
		part.dead = true
		byModel[part.model] = nil
		if part.model.Parent then
			part.model:Destroy()
		end
		if not updating then
			local index = table.find(creatures, part)
			if index then
				removeAt(index)
			end
		end
		-- Inside the walk the flagged struct stays put and the sweep drops it
		-- this pass, exactly like every other in-walk removal.
	end
	creature.partsAlive = 0
end

-- Killed rides a 4th value: { loot = coins the thief was carrying,
-- participants = every player who damaged it (a boss shares its win) } plus
-- whatever `extra` the spawner handed spawn() (a bait bounty). Listeners
-- that don't know about a key just ignore it.
local function kill(creature, killer: Player?)
	creature.dead = true
	byModel[creature.model] = nil

	-- Noctyss is damageable ONLY inside the maw window (vulnerableWhen =
	-- "markedDown"), so every death of hers happens with the jaw's invisible
	-- floor live. Destroying the model does not reach it: the floor is
	-- parented to Workspace, because a child of the model would be dragged
	-- around by the pose's own PivotTo every frame.
	if clearMawFloor then
		clearMawFloor(creature)
	end
	-- The same for the colossus's climb: a boss that dies with its arm down
	-- has just dropped everyone standing on it, and the slabs must not outlive
	-- the body they were part of.
	if clearPyreliskMount then
		clearPyreliskMount(creature)
	end

	-- Gimmick layer: a deathburst detonates here, while `pos` still means
	-- something and before Killed pays anyone out.
	local gimmick = gimmickOf(creature)
	if gimmick and gimmick.onKill then
		gimmick.onKill(creature)
	end

	-- A boss part (a Kraken tentacle): its death counts the ring down, and
	-- the last one opens the head's exposure window (damage() refuses the
	-- head while partsAlive > 0; updateBoss owns the regrow clock).
	local owner = creature.partOf
	if owner and not owner.dead and owner.partsAlive then
		owner.partsAlive = math.max(0, owner.partsAlive - 1)
		-- THE LANTERN CHOIR: WHICH stalk died is the fight. Breaking the
		-- MARKED one - the true lure, the one whose light breathes out of
		-- step - brings the maw up; breaking any other one flares white and
		-- the trench takes a swing at whoever shot it. Recorded here rather
		-- than acted on, so kill() stays free of the fight's machinery;
		-- updateBoss answers both on the next frame.
		if owner.choir then
			-- A kill sets this socket's bit; a withdrawal never does.
			if creature.socketIndex then
				owner.choirKilled = bit32.bor(owner.choirKilled or 0, bit32.lshift(1, creature.socketIndex - 1))
			end
			if creature.marked then
				owner.mawDueAt = os.clock()
			else
				-- ON THE SHOOTER, and one per break. A stalk is `rangedOnly`
				-- with its bulb 30 studs up, so whoever broke it stands 20-plus
				-- studs from its base: bursting at the lantern's own feet meant
				-- guessing wrong cost the party nothing at all, which is the
				-- entire "which light is real" premise. A LIST, because one
				-- slot collapsed simultaneous breaks into a single flare at
				-- whichever socket happened to be last.
				local shooter = killer and killer.Character
				local root = shooter and shooter:FindFirstChild("HumanoidRootPart")
				owner.flareAt = owner.flareAt or {}
				table.insert(owner.flareAt, if root then root.Position else creature.pos)
			end
		end
		-- The Kraken's exposure window. A markedDown boss has no such thing -
		-- clearing the whole choir is not what opens her, so an "exposed"
		-- banner there would be a promise the fight does not keep.
		if owner.partsAlive == 0 and owner.row.vulnerableWhen ~= "markedDown" then
			owner.partsDownAt = os.clock()
			-- LEVEL-TRIGGERED, beside the edge-triggered event. `exposed` is a
			-- positional VFX broadcast carrying no model and no duration, so a
			-- client that adopts the model mid-window sees nothing and has no
			-- way to recover the state. This attribute is what a body
			-- controller reads to open a hull's shell plates and KEEP them
			-- open. It is the same attribute the stagger path already writes,
			-- so a renderer needs one rule for both ways a boss opens up.
			owner.model:SetAttribute(ATTR_EXPOSED, true)
			fireCreatureEvent("exposed", owner.pos, {
				name = owner.model:GetAttribute(ATTR_BOSS_NAME),
			})
		end
	end
	-- And a boss with a parts ring takes its surviving arms down with it.
	if creature.partsAlive ~= nil then
		for _, other in creatures do
			if other.partOf == creature and not other.dead then
				kill(other, killer)
			end
		end
	end

	-- Magma Ooze: killing it doesn't end it, it divides it. The halves are
	-- smaller, weaker, pay a fraction each, and carry `noSplit` so a fight is
	-- bounded at three bodies instead of doubling forever. Spawned before the
	-- model goes, while `pos` is still meaningful.
	if creature.row.archetype == "splitter" and not (creature.extra and creature.extra.noSplit) then
		local at = creature.pos
		if at then
			for i = 1, C.SPLIT_COUNT do
				local angle = (i / C.SPLIT_COUNT) * math.pi * 2
				local offset = Vector3.new(math.cos(angle) * C.SPLIT_SPREAD, 0, math.sin(angle) * C.SPLIT_SPREAD)
				CreatureService.spawn(creature.row, at + offset, nil, creature.grade, {
					noSplit = true,
					healthMult = C.SPLIT_HEALTH_MULT,
					scale = C.SPLIT_SCALE,
					-- Coins and XP DO scale for the extra fight...
					bounty = C.SPLIT_BOUNTY,
					-- ...but the halves pay no materials at all. An ooze is one
					-- loot unit: the parent drops the row's mats once. A bounty
					-- can't express this - MaterialService floors every roll at
					-- math.max(1, ...), so even 0.4 still pays a whole premium
					-- mat per half, tripling a Magma Core off one Rare kill.
					suppressDrops = true,
				})
			end
			fireCreatureEvent("split", at, {})
		end
	end
	-- No death animation yet: it just goes.
	creature.model:Destroy()
	local participants = {}
	if creature.participants then
		for player in creature.participants do
			table.insert(participants, player)
		end
	end
	-- `position` is where it went down, so a listener can put something else
	-- there (Bloodbait's chain surfaces the next hostile on the same spot).
	-- Taken from the struct rather than the model, which is already destroyed.
	local info = { loot = creature.loot, participants = participants, position = creature.pos }
	if type(creature.extra) == "table" then
		for key, value in creature.extra do
			if info[key] == nil then
				info[key] = value
			end
		end
	end
	CreatureService.Killed:Fire(creature.row, creature.grade, killer, info)

	if not updating then
		local index = table.find(creatures, creature)
		if index then
			removeAt(index)
		end
	end
end

-- Take a creature out of the world WITHOUT killing it: no Killed event, no
-- rewards, no drops. BossService's abandon reaper wants exactly this - a
-- boss nobody is fighting any more sinks back rather than dying.
--
-- Exists because destroying the Model alone is NOT removal. The struct stays
-- in `creatures`, keeps being updated, keeps answering inRange/raycastNearest
-- and keeps damaging anyone who wanders back, while `byModel` holds a key on
-- a destroyed Instance. The walk now also drops parentless models as
-- defence-in-depth, but going through here means the invariant "a struct in
-- `creatures` has a live model" is never broken in the first place, rather
-- than being repaired a frame later.
function CreatureService.despawn(model: Model)
	local creature = byModel[model]
	if creature then
		-- Flagged before the walk can see it half-removed; if we are INSIDE
		-- the walk right now, its own dead-check drops the struct this pass.
		creature.dead = true
		byModel[model] = nil
		-- Flagged first, so a part's own teardown sees an owner that is
		-- already gone rather than one halfway out.
		removeOwnedParts(creature)
		if not updating then
			local index = table.find(creatures, creature)
			if index then
				removeAt(index)
			end
		end
	end
	if model.Parent then
		model:Destroy()
	end
end

-- Archetype hooks defined further down (they need the health API and the
-- health API needs them): the urchin's swell-and-pop on every hit.
local onBloaterHit
-- Same trick for the colossus death (defined with the colossus section): a
-- boss that is holding onto something takes a fall before it takes its death.
local beginBossCollapse

-- WHERE THE PUNISH WINDOW IS, not only when it is.
--
-- `vulnerableWhen = "markedDown"` was the ONLY gate on hurting Noctyss, and it
-- is a pure time gate: while the maw is up she could be burned from anywhere
-- on the shelf. Her hitRadius is 6 x the row's 2.4 scale = 14.4, and
-- `raycastNearest` adds a ~14-stud shot radius off the model's bounding
-- sphere - a ~28-stud capture cylinder standing on the arena's centre, which
-- a 200-stud DMR clips from any bearing on the floor. So "climb into her
-- mouth and burn the gullet" was decoration, `gulletPosition` was dead code
-- the server never called, and the window was a free DPS phase.
--
-- It is a REACH from the gullet, not `insideMouth` alone. Two reasons:
-- `insideMouth` is a tight authored box around the lower jaw's scoop and the
-- moment boss_gen moves a vertex it becomes "the boss cannot be damaged at
-- all", with no symptom but a fight that never ends; and being knocked off
-- the tongue for half a second should not cancel the party's damage. The
-- radius covers the whole walkable floor with slack - the tongue slab's far
-- corners measure 31.9 studs from the gullet at full gape - so the test
-- degrades into "be at her mouth" rather than into a locked door. `insideMouth`
-- is still honoured first, so standing on the floor ALWAYS counts even if the
-- gullet offset later moves.
--
-- Clamping `hitRadius` for the window was the other option and is wrong: melee
-- reach is measured off that same number from the model's PIVOT, which is the
-- skull's origin ~30 studs up, so shrinking it makes the mouth unmeleeable
-- from inside the mouth.
local NOCTYSS_GULLET_REACH = 34.0
-- Assigns the local forward-declared up by `unaimable`, which needs this exact
-- ruling to keep target selection and `damage()` from drifting apart.
function noctyssInReach(state, position: Vector3): boolean
	if NoctyssPath.insideMouth(state, position) then
		return true
	end
	return (position - NoctyssPath.gulletPosition(state)).Magnitude <= NOCTYSS_GULLET_REACH
end

-- Applies `amount` damage (server only). Returns the health left, or nil if
-- the creature was already dead / isn't a creature / can't be hurt right now
-- (a buried lurker, a shut mimic - nothing gets through, not a punch, not an
-- explosion). Killing it despawns it and fires CreatureService.Killed with
-- the optional `attacker`.
-- `opts.ignoreUntargetable` lets a source that is already "inside" the
-- creature keep hurting it while it is hidden - Brine Rot burning on through a
-- boss's dive or a lurker's burrow. Direct hits must never pass this: being
-- unhittable is the whole point of those phases.
function CreatureService.damage(creature, amount: number, attacker: Player?, opts): number?
	if type(creature) ~= "table" or creature.dead or amount ~= amount then
		return nil
	end
	-- Every reason a thing cannot be hit, in one place - see `unaimable`. All
	-- three were spelled out here and ONLY here, which is precisely why the two
	-- functions that pick targets never learned the last two of them. Brine
	-- Rot's `ignoreUntargetable` burns through all three: the poison is already
	-- in the wound, the same ruling as a boss's dive.
	-- ...with ONE exception to the exception. A dive or a burrow hides a
	-- creature for a moment, which is what `ignoreUntargetable` exists to burn
	-- through. Noctyss's seal is not a moment - it IS the fight, and her whole
	-- health budget is priced on damage being impossible outside the window.
	-- A stacked poison ticking through it is damage in a window the design
	-- says cannot exist.
	if creature.row.vulnerableWhen == "markedDown" then
		if not creature.mawOpen then
			return nil
		end
		-- The window is open: now WHERE the hit came from decides. See
		-- `noctyssInReach` above for why this is a reach and not `insideMouth`.
		-- A poison already in the wound is exempt for the same reason it is
		-- exempt from `untargetable` - it was applied in reach, and the ruling
		-- on `ignoreUntargetable` is that the source is already inside.
		if creature.pose and not (opts and opts.ignoreUntargetable) then
			local character = attacker and attacker.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			-- No attacker root means no position to judge (a chained urchin
			-- blast, a hatchling crediting an owner who has since died), and a
			-- gate cannot refuse what it cannot measure.
			if root and not noctyssInReach(creature.pose, root.Position) then
				return nil
			end
		end
	end
	if unaimable(creature) and not (opts and opts.ignoreUntargetable) then
		return nil
	end
	amount = math.max(0, amount)

	-- THE CHIP FLOOR. A boss whose row carries `chip` (Brinejaw, and only
	-- Brinejaw) is NEVER fully invulnerable: it stays aimable and damageable
	-- for the whole fight, taking this fraction of every hit outside a punish
	-- window and the full hit inside one. Before this, "the only time it can
	-- be hurt at all" plus a stone economy that could not refill meant a party
	-- which misread its baits had no way to damage the boss AND no way to earn
	-- another opening; the trace of that fight was 40 minutes at 5% uptime.
	--
	-- SCALED HERE RATHER THAN FLAGGED, and that is the point of doing it in
	-- `damage()`. The alternative - leaving the boss `untargetable` outside
	-- windows and special-casing the flag - would change what `untargetable`
	-- MEANS for its other consumers, all of which were checked: `unaimable`
	-- (and through it `inRange` and `raycastNearest`), CombatService's
	-- re-validation of a shot in flight, and the `ignoreUntargetable` escape
	-- Brine Rot uses. A chip boss simply never sets the flag outside its rise
	-- and its collapse, so every one of those reads the truth and no other
	-- boss's behaviour moves by a stud.
	--
	-- `creature.punishOpen` is written once per frame by the entrenched tick
	-- (stagger mode, or the lunge's held plant), never latched, so no exit can
	-- leave the window stuck open. Poison ticks are scaled too: rot in the
	-- wound of an armoured animal is still hitting the armour.
	if creature.chip and not creature.punishOpen then
		amount *= creature.chip
	end

	-- Being hit resets the despawn timer: the fish sticks around as long as
	-- the fight is going, and only lingers out once left alone.
	creature.lastFoughtAt = os.clock()
	-- Who to credit if it dies of something other than a direct hit (the
	-- urchin's fuse).
	if attacker then
		creature.lastAttacker = attacker
		-- And everyone who joined in, for a boss's shared win (BossService).
		creature.participants = creature.participants or {}
		creature.participants[attacker] = true
	end

	-- Slagheart Golem: armoured in cooled slag. Nearly everything bounces off
	-- until enough hits crack it, and then its core is exposed for a few
	-- seconds and takes MORE than normal. Applied here rather than in
	-- hitModifiers so every source is armoured against - a poison stack or an
	-- urchin blast shouldn't quietly ignore the plating a punch can't get
	-- through. The counter only advances while the crust holds, so the window
	-- is a reward for breaking it, not a timer you can stack into.
	if creature.row.archetype == "crust" then
		if creature.crustOpenUntil and os.clock() < creature.crustOpenUntil then
			amount *= C.CRUST_EXPOSED_MULT
		else
			amount *= C.CRUST_DAMAGE_MULT
			creature.crustHits = (creature.crustHits or 0) + 1
			if creature.crustHits >= C.CRUST_HITS then
				creature.crustHits = 0
				creature.crustOpenUntil = os.clock() + C.CRUST_WINDOW
				creature.model:SetAttribute(ATTR_CRACKED, true)
				fireCreatureEvent("crustCrack", creature.pos, {})
			end
		end
	end

	-- The gimmick layer (kit engine): harden's windup armour, frenzy's
	-- ignition, phasey's blink-out - one consult, one place.
	local gimmick = gimmickOf(creature)
	if gimmick and gimmick.onDamage then
		amount = gimmick.onDamage(creature, amount, os.clock()) or amount
	end

	creature.health = math.max(0, creature.health - amount)
	creature.model:SetAttribute(ATTR_HEALTH, creature.health)

	-- Ashfeather Phoenix: its first death isn't one. It goes down untouchable
	-- for a moment, then rises at a fraction of its health and has to be killed
	-- again. Checked before kill() so nothing downstream (loot, the chain, the
	-- boss's participant list) ever sees the first death happen.
	if creature.health <= 0 and creature.row.archetype == "reborn" and not creature.rebornUsed then
		creature.rebornUsed = true
		creature.untargetable = true
		creature.knockVel = nil
		creature.downUntil = os.clock() + C.REBORN_DOWN
		creature.model:SetAttribute(ATTR_DOWNED, true)
		fireCreatureEvent("rebornDown", creature.pos, {})
		return creature.health
	end

	-- A colossus does not blink out where it stands. An entrenched, POSED boss
	-- takes its collapse first - it comes off its perch over a couple of
	-- seconds - and the ordinary death runs untouched at the end of the fall,
	-- with this same killer and this same participant list. Checked in exactly
	-- the place the phoenix's first death is, and for the same reason: nothing
	-- downstream may see a death that hasn't finished happening.
	if creature.health <= 0 and beginBossCollapse(creature, attacker) then
		return creature.health
	end

	if creature.health <= 0 then
		kill(creature, attacker)
	elseif creature.row.archetype == "bloater" then
		onBloaterHit(creature) -- swells; may pop (and so kill) it
	end
	return creature.health
end

function CreatureService.isAlive(creature): boolean
	return type(creature) == "table" and not creature.dead
end

-- What a melee hit on this creature does beyond its damage, for CombatService:
-- a damage multiplier (the charger's exposed back while it turns takes
-- double) and a shock dealt BACK to the attacker (hitting the Voltray while
-- it's charging).
-- `from` is where the swing came from, which only the thornback cares about -
-- it is armoured at the front and soft behind, so the same punch does very
-- different things depending on where you're standing. Optional: a caller that
-- doesn't pass it simply gets the front-agnostic answer.
function CreatureService.hitModifiers(creature, from: Vector3?): (number, number)
	if type(creature) ~= "table" or creature.dead then
		return 1, 0
	end
	-- A kitted creature's expose window (a move's `expose` field): the same
	-- double-damage punish the charger's turn has always had.
	if creature.exposedUntil and os.clock() < creature.exposedUntil then
		-- ...EXCEPT ON A CHIP BOSS, whose window is already the step. Outside
		-- one it takes `chip` of every hit and inside one it takes all of it,
		-- so opening a window is a 4x change of state on its own (0.25 -> 1.0
		-- on Brinejaw); stacking the charger's 2.0 on top made it 8x, and the
		-- simulation put roughly 80% of the health bar inside five baited
		-- staggers - the old 5%-uptime fight with the sign flipped, where
		-- everything between the windows is noise. Every other boss keeps the
		-- multiplier it has always had: no row but Brinejaw's carries `chip`.
		return (if creature.chip then 1 else C.CHARGE_EXPOSED_DAMAGE_MULT), 0
	end
	-- Gimmicks that answer melee (spines' reflect, static's shock).
	local gimmick = gimmickOf(creature)
	if gimmick and gimmick.onHit then
		return gimmick.onHit(creature)
	end
	local archetype = creature.row.archetype
	if archetype == "thornback" then
		if not from or not creature.pos then
			return 1, 0
		end
		-- The inverse of yawToward: it stores yaw = atan2(-z, x), so the way it
		-- faces is (cos yaw, 0, -sin yaw).
		local facing = Vector3.new(math.cos(creature.yaw0), 0, -math.sin(creature.yaw0))
		local delta = Vector3.new(from.X - creature.pos.X, 0, from.Z - creature.pos.Z)
		if delta.Magnitude < 0.001 then
			return 1, 0
		end
		if facing:Dot(delta.Unit) >= C.THORN_FRONT_DOT then
			return C.THORN_FRONT_MULT, C.THORN_REFLECT
		end
		return C.THORN_BACK_MULT, 0
	elseif archetype == "charger" and creature.mode == "turning" then
		return C.CHARGE_EXPOSED_DAMAGE_MULT, 0
	elseif archetype == "pulser" and creature.charging then
		return 1, C.PULSE_SHOCK_DAMAGE
	end
	return 1, 0
end

-- Brine Rot (the Drowncleaver's perk): adds one stack of damage-over-time.
-- Stacks are independent and capped, so a fast weapon builds real pressure
-- without becoming unbounded. Ticks run in the update walk and deliberately
-- ignore `untargetable` - rot is already in the wound, so it burns through a
-- boss's dive, which is the one way to hurt it mid-phase.
function CreatureService.poison(creature, totalDamage: number, duration: number, attacker: Player?)
	if type(creature) ~= "table" or creature.dead or totalDamage <= 0 or duration <= 0 then
		return
	end
	creature.poison = creature.poison or {}
	if #creature.poison >= Perks.POISON_MAX_STACKS then
		return
	end

	local ticks = math.max(1, math.floor(duration / Perks.POISON_TICK + 0.5))
	table.insert(creature.poison, {
		perTick = totalDamage / ticks,
		ticksLeft = ticks,
		nextTickAt = os.clock() + Perks.POISON_TICK,
		attacker = attacker,
	})
end

-- Shoves a resting creature away from a hit and pops it into the air.
-- `direction` is any vector from the hit's source to the creature (only its
-- horizontal part is used); `speed` is the horizontal push in studs/second,
-- which decays every frame (C.KNOCKBACK_DAMPING) as the update loop slides
-- creature.pos along it. `lift` is the vertical launch in studs/second - the
-- juggle: the creature rises and falls under C.JUGGLE_GRAVITY, and hitting it
-- again mid-air RESETS the upward velocity from wherever it is, so a fast
-- weapon can keep comboing it up. Ignored while the creature is still flying
-- or settling from the throw - it can't be nudged mid-arc - and once dead.
-- `uproot` (the Shellcrusher's perk) overrides an archetype's launch
-- resistance, so a weapon built to hurl things can pop even the enemies that
-- normally stay planted. Archetypes in Perks.UPROOT_IMMUNE ignore it - a boss
-- is never juggled, whatever you hit it with.
function CreatureService.applyKnockback(creature, direction: Vector3, speed: number, lift: number?, uproot: boolean?)
	if type(creature) ~= "table" or creature.dead or creature.state ~= "resting" then
		return
	end

	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude > 0.01 then
		-- Hostile archetypes resist the shove (C.KNOCKBACK_MULT_BY_ARCHETYPE),
		-- so an attacking creature can't just be punted out of the fight; the
		-- passive fish take the full push. Scaling here rather than at the call
		-- site keeps every weapon row's own `knockback` number meaningful.
		local resist = C.KNOCKBACK_MULT_BY_ARCHETYPE[creature.row.archetype] or 1
		-- The slippery gimmick overrides the resist outright: this thing is
		-- MEANT to rocket across the beach.
		local g = creature.row.gimmick
		if g and g.kind == "slippery" then
			resist = g.mult or 2
		end
		-- Additive, so rapid hits stack into a bigger shove.
		creature.knockVel = (creature.knockVel or Vector3.zero) + flat.Unit * (speed * resist)
	end

	-- Hostile archetypes are pinned to the ground (mult 0): a creature in the
	-- air can't attack, so juggling one would neutralise it for free. An
	-- uprooting weapon ignores that pin, except on the archetypes that are
	-- immune outright.
	local archetype = creature.row.archetype
	local liftMult = C.LAUNCH_MULT_BY_ARCHETYPE[archetype] or 1
	if uproot and not Perks.UPROOT_IMMUNE[archetype] then
		liftMult = math.max(liftMult, 1)
	end
	local launch = (lift or 0) * liftMult
	if launch > 0 then
		-- A launch interrupts a kitted move mid-flight: cancelling a windup
		-- with a well-timed uproot/juggle is a real counter, not a no-op.
		if creature.attack then
			creature.attack = nil
			creature.nextAttackAt = os.clock() + 1.0
		end
		-- Set (not add): every hit launches from the current height at the
		-- weapon's full lift, so a juggle keeps a steady rhythm instead of
		-- accelerating away. The jelly already hovers, so it launches from
		-- its hover height rather than dropping to the ground first.
		creature.vertVel = launch
		local floor = if creature.row.archetype == "drifter" then C.DRIFT_HOVER else 0
		creature.airY = math.max(creature.airY or 0, floor)
		-- Airborne creatures don't flop; clear any hop in progress.
		creature.flopStart = nil
	end
end

-- ============================================================ flopping

-- Advances one creature's flop and returns (hop height, yaw offset, pitch).
-- Yaw and pitch are small angles layered on top of the fixed heading; there
-- is no roll, so the fish never turns over.
local function flop(creature, now: number): (number, number, number)
	-- Always-present idle wiggle: the tail twitching as it lies there.
	local idleYaw = math.sin((now - creature.spawnedAt) * C.WIGGLE_RATE) * C.WIGGLE_IDLE

	if creature.flopStart then
		local t = (now - creature.flopStart) / creature.flopDuration
		if t >= 1 then
			creature.flopStart = nil
			creature.nextFlopAt = now + randomBetween(C.FLOP_REST_MIN, C.FLOP_REST_MAX)
			return 0, idleYaw, 0
		end

		-- Parabolic hop; the swish rides an in-and-out envelope so it's
		-- strongest at the top of the hop, and pitch tips the nose once.
		local hop = C.FLOP_HEIGHT * 4 * t * (1 - t)
		local env = math.sin(t * math.pi)
		local swish = math.sin(t * math.pi * 2 * C.FLOP_SWISH_CYCLES) * C.FLOP_SWISH * env * creature.swishDir
		local pitch = env * C.FLOP_PITCH * creature.pitchDir
		return hop, idleYaw + swish, pitch
	end

	if now >= creature.nextFlopAt then
		creature.flopStart = now
		creature.flopDuration = randomBetween(C.FLOP_HOP_MIN, C.FLOP_HOP_MAX)
		creature.swishDir = if math.random() < 0.5 then 1 else -1
		creature.pitchDir = if math.random() < 0.5 then 1 else -1
		-- One tick per flop; clients splash / puff on each change.
		creature.model:SetAttribute(ATTR_FLOPS, (creature.model:GetAttribute(ATTR_FLOPS) or 0) + 1)
	end

	return 0, idleYaw, 0
end

-- ============================================================ rusher archetype

-- Shortest signed angular distance from a to b, in (-pi, pi].
local function angleDelta(a: number, b: number): number
	local d = (b - a) % (2 * math.pi)
	if d > math.pi then
		d -= 2 * math.pi
	end
	return d
end

-- Turn `current` toward `target` by at most `maxStep` radians.
local function approachAngle(current: number, target: number, maxStep: number): number
	local d = angleDelta(current, target)
	if math.abs(d) <= maxStep then
		return target
	end
	return current + (if d > 0 then maxStep else -maxStep)
end

local function flatUnit(v: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 0.001 then f.Unit else Vector3.zAxis
end

-- The nearest living player's root to `pos`, with the player and the
-- horizontal distance. Root nil if nobody's alive.
local function nearestPlayerRoot(pos: Vector3): (BasePart?, Player?, number)
	local bestRoot, bestPlayer, bestDist = nil, nil, math.huge
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid and humanoid.Health > 0 then
			local d = (Vector3.new(root.Position.X, 0, root.Position.Z) - Vector3.new(pos.X, 0, pos.Z)).Magnitude
			if d < bestDist then
				bestRoot, bestPlayer, bestDist = root, player, d
			end
		end
	end
	return bestRoot, bestPlayer, bestDist
end

-- Model pose for a creature lying flat at pos + a hop, turned by yaw0 +
-- yawOffset and pitched a little. Shared by the flop and rush loops.
local function poseCFrame(creature, hop: number, yawOffset: number, pitch: number): CFrame
	return CFrame.new(creature.pos + Vector3.new(0, hop, 0))
		* CFrame.Angles(0, creature.yaw0 + yawOffset, 0)
		* CFrame.Angles(0, 0, pitch)
		* creature.flat
end

-- Moves a creature horizontally by `delta`, but stops it at any solid
-- obstacle in the way (rocks, palm trunks, the dock) so a shove or a lunge
-- can't push it through the scenery. Returns the resolved, grounded position
-- and whether it was blocked. The cast reaches `halfThickness` past the step
-- so the fish's edge - not just its centre - stops at the wall, and
-- groundParams' RespectCanCollide means fronds/bushes/foam don't count.
local function resolveHorizontal(creature, delta: Vector3): (Vector3, boolean)
	local flat = Vector3.new(delta.X, 0, delta.Z)
	local dist = flat.Magnitude
	if dist < 1e-4 then
		return groundedPos(creature.pos, creature.halfThickness), false
	end

	local dir = flat / dist
	local skin = creature.halfThickness
	local hit = Workspace:Raycast(creature.pos, dir * (dist + skin), groundParams())
	if hit then
		local allowed = math.max(0, (hit.Position - creature.pos).Magnitude - skin)
		return groundedPos(creature.pos + dir * allowed, creature.halfThickness), true
	end
	return groundedPos(creature.pos + flat, creature.halfThickness), false
end

-- Slide a resting creature along its decaying knockback push, re-grounding
-- the height each step (the beach slopes; the dock is a step up) and stopping
-- at solid obstacles. Shared by the default and rusher loops so a punch
-- shoves either without tunnelling it through a rock or a tree.
local function slideKnockback(creature, dt: number)
	if creature.knockVel then
		local delta = Vector3.new(creature.knockVel.X, 0, creature.knockVel.Z) * dt
		local newPos, blocked = resolveHorizontal(creature, delta)
		creature.pos = newPos
		if blocked then
			creature.knockVel = nil -- ran into something solid; stop dead
		else
			creature.knockVel *= math.exp(-C.KNOCKBACK_DAMPING * dt)
			if creature.knockVel.Magnitude < 0.05 then
				creature.knockVel = nil
			end
		end
	end
end

-- True while a creature is off the ground from a hit (the juggle), so the
-- archetype loops know to stand down until it lands.
local function isAirborne(creature): boolean
	return (creature.airY or 0) > 0 or creature.vertVel ~= nil
end

-- One frame of a juggled creature: it drifts horizontally on whatever
-- knockback it has (damped less than on the ground, so a hit carries it),
-- rises and falls under JUGGLE_GRAVITY, and tumbles as it goes. Archetype
-- behaviour is suspended - a fish in the air can't rush or flop - which is
-- what makes a combo feel like it's holding the creature helpless.
local function updateAirborne(creature, dt: number)
	-- Horizontal drift: same push the ground slide uses, just damped gently.
	if creature.knockVel then
		local delta = Vector3.new(creature.knockVel.X, 0, creature.knockVel.Z) * dt
		local newPos, blocked = resolveHorizontal(creature, delta)
		creature.pos = newPos
		if blocked then
			creature.knockVel = nil
		else
			creature.knockVel *= math.exp(-C.JUGGLE_AIR_DAMPING * dt)
			if creature.knockVel.Magnitude < 0.05 then
				creature.knockVel = nil
			end
		end
	end

	-- Gravity is per archetype (the jelly falls like a balloon).
	local archetype = creature.row.archetype
	local gravity = C.JUGGLE_GRAVITY * (C.GRAVITY_MULT_BY_ARCHETYPE[archetype] or 1)
	creature.vertVel = (creature.vertVel or 0) - gravity * dt
	creature.airY = (creature.airY or 0) + creature.vertVel * dt
	creature.spin = (creature.spin or 0) + C.JUGGLE_SPIN * dt

	-- The jelly hovers, so it "lands" back at its hover height and doesn't
	-- slap the sand; everything else lands on the ground and ticks Flops.
	local landHeight = if archetype == "drifter" then C.DRIFT_HOVER else 0
	if creature.airY <= landHeight + C.JUGGLE_LAND_HEIGHT and creature.vertVel <= 0 then
		-- Landed: back to the ground loop, and tick Flops so the splash / puff
		-- VFX + SFX fire where it hit.
		creature.airY = 0
		creature.vertVel = nil
		creature.spin = 0
		creature.nextFlopAt = os.clock() + randomBetween(C.FLOP_REST_MIN, C.FLOP_REST_MAX)
		if landHeight == 0 then
			creature.model:SetAttribute(ATTR_FLOPS, (creature.model:GetAttribute(ATTR_FLOPS) or 0) + 1)
		end
		creature.model:PivotTo(poseCFrame(creature, landHeight, 0, 0))
		return
	end

	-- Tumble about the (horizontal) cross axis as it flies - the pitch slot in
	-- poseCFrame, so an upright creature spins the same way a flat one does.
	creature.model:PivotTo(poseCFrame(creature, creature.airY, 0, creature.spin))
end

-- One frame of the rusher (the pufferfish): flop in place, wind up facing the
-- nearest player, then lunge and ram them for contact damage. Same CFrame
-- Heartbeat as every other creature - no Humanoid, no pathfinding. Its own
-- sub-state ("idle" / "windup" / "rush") lives on the struct, lazily seeded.
local function updateRusher(creature, now: number, dt: number)
	slideKnockback(creature, dt)

	if not creature.mode then
		creature.mode = "idle"
		creature.modeUntil = now + randomBetween(C.RUSH_REST_MIN, C.RUSH_REST_MAX)
		creature.lastHitAt = 0
	end

	local root, player, dist = nearestPlayerRoot(creature.pos)

	if creature.mode == "idle" then
		-- Flops in place (flop() ticks Flops so the splash/puff VFX + SFX fire),
		-- slowly turning to keep the player in front of it.
		local hop, yaw, pitch = flop(creature, now)
		if root then
			creature.yaw0 = approachAngle(creature.yaw0, yawToward(root.Position - creature.pos), C.RUSH_TURN_RATE * dt)
		end
		creature.model:PivotTo(poseCFrame(creature, hop, yaw, pitch))

		if now >= creature.modeUntil then
			if root and dist <= C.RUSH_AGGRO_RANGE then
				creature.mode = "windup"
				creature.modeUntil = now + C.RUSH_WINDUP
			else
				creature.modeUntil = now + randomBetween(C.RUSH_REST_MIN, C.RUSH_REST_MAX)
			end
		end
	elseif creature.mode == "windup" then
		-- Telegraph: face the target and tuck down before springing.
		if root then
			creature.yaw0 = yawToward(root.Position - creature.pos)
		end
		local u = 1 - math.clamp((creature.modeUntil - now) / C.RUSH_WINDUP, 0, 1)
		local tuck = math.sin(u * math.pi)
		creature.model:PivotTo(poseCFrame(creature, -0.15 * tuck, 0, -C.RUSH_WINDUP_PITCH * tuck))

		if now >= creature.modeUntil then
			creature.rushDir = flatUnit(if root then root.Position - creature.pos else Vector3.zAxis)
			creature.mode = "rush"
			creature.modeUntil = now + C.RUSH_DURATION
			creature.rushStart = now
		end
	else -- rush
		-- Lunge forward, but stop at solid scenery rather than charging through it.
		local newPos, blocked = resolveHorizontal(creature, creature.rushDir * C.RUSH_SPEED * dt)
		creature.pos = newPos
		creature.yaw0 = yawToward(creature.rushDir)
		local u = math.clamp((now - creature.rushStart) / C.RUSH_DURATION, 0, 1)
		local hop = C.RUSH_HOP * math.abs(math.sin(u * math.pi * C.RUSH_HOPS))
		creature.model:PivotTo(poseCFrame(creature, hop, 0, C.RUSH_PITCH))

		if root and player and dist <= C.CONTACT_RADIUS and now - creature.lastHitAt >= C.CONTACT_COOLDOWN then
			creature.lastHitAt = now
			PlayerService.damage(player, math.random(C.CONTACT_DAMAGE_MIN, C.CONTACT_DAMAGE_MAX), creature)
			-- Recoil back off the ram (also obstacle-checked) and flop again.
			creature.pos = resolveHorizontal(creature, -creature.rushDir * C.CONTACT_BOUNCE)
			creature.mode = "idle"
			creature.modeUntil = now + randomBetween(C.RUSH_REST_MIN, C.RUSH_REST_MAX)
		elseif blocked or now >= creature.modeUntil then
			-- Hit a wall or ran out of lunge time; back to flopping.
			creature.mode = "idle"
			creature.modeUntil = now + randomBetween(C.RUSH_REST_MIN, C.RUSH_REST_MAX)
		end
	end
end

-- One frame of the shambler (the drowned zombies): stands upright and trudges
-- straight at the nearest player, hitting on contact - no windup or lunge,
-- just slow and relentless. Reuses the rusher's contact damage + recoil and
-- the shared obstacle-clamped movement. Upright creatures never flop; their
-- `flat` is identity so poseCFrame keeps them standing.
local function updateShambler(creature, now: number, dt: number)
	slideKnockback(creature, dt)
	creature.lastHitAt = creature.lastHitAt or 0

	local root, player, dist = nearestPlayerRoot(creature.pos)
	if root and dist <= C.SHAMBLE_AGGRO then
		-- Turn toward the player and step forward.
		creature.yaw0 = approachAngle(creature.yaw0, yawToward(root.Position - creature.pos), C.SHAMBLE_TURN_RATE * dt)
		local forward = flatUnit(root.Position - creature.pos)
		creature.pos = resolveHorizontal(creature, forward * C.SHAMBLE_SPEED * dt)

		-- A trudging bob so the stand-and-slide reads as walking.
		local bob = math.abs(math.sin(now * C.SHAMBLE_BOB_RATE)) * C.SHAMBLE_BOB
		creature.model:PivotTo(poseCFrame(creature, bob, 0, 0))

		if player and dist <= C.CONTACT_RADIUS and now - creature.lastHitAt >= C.CONTACT_COOLDOWN then
			creature.lastHitAt = now
			PlayerService.damage(player, math.random(C.CONTACT_DAMAGE_MIN, C.CONTACT_DAMAGE_MAX), creature)
			creature.pos = resolveHorizontal(creature, -forward * C.CONTACT_BOUNCE)
		end
	else
		-- Nobody in range: stand and sway a little.
		local sway = math.sin(now * C.SHAMBLE_SWAY_RATE) * C.SHAMBLE_SWAY
		creature.model:PivotTo(poseCFrame(creature, 0, sway, 0))
	end
end

-- ============================================================ enemy archetypes (2026-08-22)
-- Eight more state machines in the same shape as the rusher: sub-state on
-- the struct (`mode` / `modeUntil` / `modeStart`, lazily seeded), every move
-- through resolveHorizontal, one PivotTo per frame, contact damage through
-- PlayerService.damage. Each is written to tolerate being interrupted by a
-- juggle (updateAirborne pre-empts them): timers are absolute, so the next
-- grounded frame just sees "expired" and moves on. Knobs: Tuning.Creature.

-- A one-off moment for the clients to draw (CreatureEventController).
-- Extracted to Modules/Hazards (revamp Session 3) so RaidService and the
-- island events share the exact same client-moment channel; this local is
-- the same function it always was.
local function fireEvent(kind: string, position: Vector3, extra)
	Hazards.fireEvent(kind, position, extra)
end
-- Same function, reachable from the health API above it.
fireCreatureEvent = fireEvent

local function setMode(creature, mode: string, duration: number, now: number)
	creature.mode = mode
	creature.modeStart = now
	creature.modeUntil = now + duration
end

-- Progress through the current mode, 0..1.
local function modeProgress(creature, now: number): number
	local span = creature.modeUntil - creature.modeStart
	if span <= 0 then
		return 1
	end
	return math.clamp((now - creature.modeStart) / span, 0, 1)
end

-- Hurts every living player within `radius` (horizontal) of `at`, the damage
-- falling off linearly from full at the centre to `edgeFraction` at the edge.
-- Telegraphed bursts bypass the player's i-frame so a stray contact tick a
-- moment earlier can't swallow a whole explosion.
-- `heightTolerance` defaults to C.AOE_HEIGHT_TOLERANCE; the boss passes a
-- bigger one because it sits at the waterline while the players stand on
-- the arena deck a few studs up.
-- Extracted to Modules/Hazards (revamp Session 3): raids and island events
-- hurt players by exactly this rule, so there is one copy. Same signature,
-- same semantics (falloff, height gate, i-frame bypass).
local function damagePlayersInRadius(
	at: Vector3,
	radius: number,
	minDmg: number,
	maxDmg: number,
	source,
	edgeFraction: number,
	heightTolerance: number?
)
	Hazards.damagePlayersInRadius(at, radius, minDmg, maxDmg, source, edgeFraction, heightTolerance)
end

-- The rusher's contact test, shared: a hit lands if the player is within
-- `radius` and this creature's CONTACT_COOLDOWN has passed. Returns true if it did.
local function tryContact(
	creature,
	player: Player?,
	dist: number,
	radius: number,
	minDmg: number,
	maxDmg: number,
	now: number
): boolean
	if player and dist <= radius and now - (creature.lastHitAt or 0) >= C.CONTACT_COOLDOWN then
		creature.lastHitAt = now
		-- A kitted row's own contact band beats the archetype's global one.
		local band = creature.row.contactDamage
		if band then
			minDmg, maxDmg = band[1], band[2]
		end
		local dealt = math.random(minDmg, maxDmg)
		PlayerService.damage(player, dealt, creature)
		local gimmick = gimmickOf(creature)
		if gimmick and gimmick.onContact then
			gimmick.onContact(creature, dealt)
		end
		return true
	end
	return false
end

-- Hidden and unhittable (the burrower under the sand) or back again. The
-- client hides the parts off the attribute; here it's just the flags.
local function setBuried(creature, buried: boolean)
	creature.untargetable = buried
	creature.knockVel = nil
	creature.model:SetAttribute(ATTR_BURIED, buried)
end

-- ---------------------------------------------------------------- charger (Tideline Skipper)
-- idle -> windup -> dash (straight past the player, one hit on the way
-- through) -> turning (exposed: hits land double) -> idle.
local function updateCharger(creature, now: number, dt: number)
	slideKnockback(creature, dt)
	if not creature.mode then
		setMode(creature, "idle", randomBetween(C.CHARGE_REST_MIN, C.CHARGE_REST_MAX), now)
		creature.lastHitAt = 0
	end
	local model = creature.model
	local root, player, dist = nearestPlayerRoot(creature.pos)

	if creature.mode == "idle" then
		local hop, yaw, pitch = flop(creature, now)
		if root then
			creature.yaw0 = approachAngle(creature.yaw0, yawToward(root.Position - creature.pos), C.RUSH_TURN_RATE * dt)
		end
		model:PivotTo(poseCFrame(creature, hop, yaw, pitch))
		if now >= creature.modeUntil then
			if root and dist <= C.CHARGE_AGGRO then
				setMode(creature, "windup", C.CHARGE_WINDUP, now)
			else
				creature.modeUntil = now + randomBetween(C.CHARGE_REST_MIN, C.CHARGE_REST_MAX)
			end
		end
	elseif creature.mode == "windup" then
		if root then
			creature.yaw0 = yawToward(root.Position - creature.pos)
		end
		local tuck = math.sin(modeProgress(creature, now) * math.pi)
		model:PivotTo(poseCFrame(creature, -0.1 * tuck, 0, -C.RUSH_WINDUP_PITCH * tuck))
		if now >= creature.modeUntil then
			creature.rushDir = flatUnit(if root then root.Position - creature.pos else Vector3.zAxis)
			-- Run to a point past where the player is standing, never further
			-- than CHARGE_MAX_DIST.
			creature.dashRemaining = math.min(dist + C.CHARGE_OVERSHOOT, C.CHARGE_MAX_DIST)
			creature.dashHit = false
			setMode(creature, "dash", C.CHARGE_MAX_DIST / C.CHARGE_SPEED + 0.5, now)
			model:SetAttribute(ATTR_DASHING, true)
		end
	elseif creature.mode == "dash" then
		local step = C.CHARGE_SPEED * dt
		local newPos, blocked = resolveHorizontal(creature, creature.rushDir * step)
		creature.pos = newPos
		creature.dashRemaining -= step
		creature.yaw0 = yawToward(creature.rushDir)
		local hop = C.CHARGE_HOP * math.abs(math.sin((now - creature.modeStart) * C.CHARGE_HOP_RATE))
		model:PivotTo(poseCFrame(creature, hop, 0, C.RUSH_PITCH))

		-- One hit per dash and no recoil: it barrels straight through.
		if not creature.dashHit and player and dist <= C.CONTACT_RADIUS then
			creature.dashHit = true
			PlayerService.damage(player, math.random(C.CHARGE_DAMAGE_MIN, C.CHARGE_DAMAGE_MAX), creature)
		end
		if blocked or creature.dashRemaining <= 0 or now >= creature.modeUntil then
			model:SetAttribute(ATTR_DASHING, false)
			model:SetAttribute(ATTR_EXPOSED, true)
			setMode(creature, "turning", C.CHARGE_TURN_TIME, now)
		end
	else -- turning: skids around to face the player again, back exposed
		if root then
			creature.yaw0 =
				approachAngle(creature.yaw0, yawToward(root.Position - creature.pos), C.CHARGE_TURN_RATE * dt)
		end
		local wobble = math.sin((now - creature.modeStart) * 9) * math.rad(10)
		model:PivotTo(poseCFrame(creature, 0, wobble, 0))
		if now >= creature.modeUntil then
			model:SetAttribute(ATTR_EXPOSED, false)
			setMode(creature, "idle", randomBetween(C.CHARGE_REST_MIN, C.CHARGE_REST_MAX), now)
		end
	end
end

-- ---------------------------------------------------------------- spitter (Gullet Cod)
-- Keeps SPIT_MIN..MAX_RANGE from the player, rears up, spits. The glob is a
-- timer on the struct: it lands at the player's position AT LAUNCH after
-- SPIT_FLIGHT seconds (the dodge window) - the clients draw the arc from the
-- "spit" event, the server only decides the landing. landSpit runs from
-- update() regardless of what the cod is doing by then.
local function landSpit(creature)
	local spit = creature.spit
	creature.spit = nil
	damagePlayersInRadius(spit.landing, C.SPIT_SPLASH_RADIUS, C.SPIT_DAMAGE_MIN, C.SPIT_DAMAGE_MAX, creature, 0.5)
	fireEvent("splash", spit.landing, { radius = C.SPIT_SPLASH_RADIUS })
end

local function updateSpitter(creature, now: number, dt: number)
	slideKnockback(creature, dt)
	if not creature.mode then
		setMode(creature, "idle", randomBetween(C.SPIT_INTERVAL_MIN, C.SPIT_INTERVAL_MAX), now)
	end
	local model = creature.model
	local root, _, dist = nearestPlayerRoot(creature.pos)

	if creature.mode == "windup" then
		if root then
			creature.yaw0 = yawToward(root.Position - creature.pos)
		end
		local rear = math.sin(modeProgress(creature, now) * math.pi)
		model:PivotTo(poseCFrame(creature, 0.2 * rear, 0, C.SPIT_REAR_PITCH * rear))
		if now >= creature.modeUntil then
			if root then
				local landing = groundedPos(root.Position, 0)
				local from = model:GetPivot().Position + Vector3.new(0, 0.6, 0)
				creature.spit = { landing = landing, landAt = now + C.SPIT_FLIGHT }
				fireEvent("spit", from, { to = landing, flight = C.SPIT_FLIGHT, arc = C.SPIT_ARC })
			end
			setMode(creature, "idle", randomBetween(C.SPIT_INTERVAL_MIN, C.SPIT_INTERVAL_MAX), now)
		end
		return
	end

	-- idle: hold the preferred range, hopping when it has to move.
	local hop, yaw, pitch = flop(creature, now)
	if root and dist <= C.SPIT_AGGRO then
		creature.yaw0 = approachAngle(creature.yaw0, yawToward(root.Position - creature.pos), C.RUSH_TURN_RATE * dt)
		local away = flatUnit(creature.pos - root.Position)
		local move = nil
		if dist < C.SPIT_MIN_RANGE then
			move = away
		elseif dist > C.SPIT_MAX_RANGE then
			move = -away
		end
		if move then
			creature.pos = resolveHorizontal(creature, move * C.SPIT_HOP_SPEED * dt)
			hop = math.max(hop, 0.35 * math.abs(math.sin(now * 8)))
		end
		if now >= creature.modeUntil and not creature.spit then
			setMode(creature, "windup", C.SPIT_WINDUP, now)
		end
	end
	model:PivotTo(poseCFrame(creature, hop, yaw, pitch))
end

-- ---------------------------------------------------------------- bloater (Tidebomb Urchin)
-- Creeps at the player. Every hit swells it and starts/continues a fuse;
-- after BLOAT_HITS_TO_POP hits or BLOAT_FUSE seconds it explodes: players
-- AND other creatures in range take the blast. Juggle it away first.
local explode

onBloaterHit = function(creature)
	creature.bloatHits = (creature.bloatHits or 0) + 1
	creature.fuseAt = creature.fuseAt or os.clock() + C.BLOAT_FUSE

	local model = creature.model
	local current = model:GetScale()
	local target = current + C.BLOAT_SWELL_PER_HIT
	model:ScaleTo(target)
	-- Its belly is lower now; keep it resting on the ground, not in it.
	creature.halfThickness *= target / current

	if creature.bloatHits >= C.BLOAT_HITS_TO_POP then
		explode(creature)
	end
end

explode = function(creature)
	if creature.dead then
		return
	end
	creature.fuseAt = nil
	local at = creature.model:GetPivot().Position
	local radius = C.BLOAT_RADIUS

	damagePlayersInRadius(at, radius, C.BLOAT_DAMAGE_MIN, C.BLOAT_DAMAGE_MAX, creature, 0.4)

	-- Everything else in range: damaged (credited to whoever lit the fuse)
	-- and thrown outward. Another urchin in the blast swells and may chain.
	for _, other in CreatureService.inRange(at, radius) do
		if other ~= creature then
			CreatureService.damage(other, C.BLOAT_CREATURE_DAMAGE, creature.lastAttacker)
			if not other.dead then
				CreatureService.applyKnockback(
					other,
					other.model:GetPivot().Position - at,
					C.BLOAT_CREATURE_KNOCKBACK,
					C.BLOAT_CREATURE_LIFT
				)
			end
		end
	end

	fireEvent("explode", at, { radius = radius })
	kill(creature, creature.lastAttacker)
end

local function updateBloater(creature, now: number, dt: number)
	slideKnockback(creature, dt)
	local root, _, dist = nearestPlayerRoot(creature.pos)

	local hop, yaw, pitch = flop(creature, now)
	if root and dist <= C.BLOAT_AGGRO and dist > 2 then
		creature.yaw0 = approachAngle(creature.yaw0, yawToward(root.Position - creature.pos), C.RUSH_TURN_RATE * dt)
		creature.pos = resolveHorizontal(creature, flatUnit(root.Position - creature.pos) * C.BLOAT_ROLL_SPEED * dt)
	end

	-- A throb that quickens as the fuse runs down.
	local throb = 0
	if creature.fuseAt then
		local burned = C.BLOAT_FUSE - math.max(creature.fuseAt - now, 0)
		throb = math.abs(math.sin(now * (6 + burned * 6))) * 0.12
	end
	creature.model:PivotTo(poseCFrame(creature, hop + throb, yaw, pitch))
end

-- ---------------------------------------------------------------- drifter (Moonbell Jelly)
-- Hovers toward the player and stings on contact. Never flops - it floats
-- (DRIFT_HOVER + a bob); hits send it up (see the LAUNCH / GRAVITY mults).
local function updateDrifter(creature, now: number, dt: number)
	slideKnockback(creature, dt)
	local root, player, dist = nearestPlayerRoot(creature.pos)

	if root and dist <= C.DRIFT_AGGRO then
		creature.yaw0 = approachAngle(creature.yaw0, yawToward(root.Position - creature.pos), C.RUSH_TURN_RATE * dt)
		if dist > C.DRIFT_CONTACT_RADIUS * 0.6 then
			creature.pos = resolveHorizontal(creature, flatUnit(root.Position - creature.pos) * C.DRIFT_SPEED * dt)
		end
		tryContact(creature, player, dist, C.DRIFT_CONTACT_RADIUS, C.DRIFT_DAMAGE_MIN, C.DRIFT_DAMAGE_MAX, now)
	end

	local bob = math.sin(now * C.DRIFT_BOB_RATE + creature.spawnedAt) * C.DRIFT_BOB
	creature.model:PivotTo(poseCFrame(creature, C.DRIFT_HOVER + bob, 0, 0))
end

-- ---------------------------------------------------------------- burrower (Sand Lurker)
-- surfaced (hittable, flops) -> sinking -> buried (hidden, untargetable,
-- tunnels at the player) -> emerging (bursts up and bites) -> surfaced.
local function updateBurrower(creature, now: number, dt: number)
	local model = creature.model
	if not creature.mode then
		setMode(creature, "surfaced", C.BURROW_SURFACE_TIME, now)
	end
	local root, _, dist = nearestPlayerRoot(creature.pos)

	if creature.mode == "surfaced" then
		slideKnockback(creature, dt)
		local hop, yaw, pitch = flop(creature, now)
		if root then
			creature.yaw0 = approachAngle(creature.yaw0, yawToward(root.Position - creature.pos), C.RUSH_TURN_RATE * dt)
		end
		model:PivotTo(poseCFrame(creature, hop, yaw, pitch))
		if now >= creature.modeUntil and root and dist <= C.BURROW_AGGRO then
			setMode(creature, "sinking", C.BURROW_SINK_TIME, now)
			setBuried(creature, true)
		end
	elseif creature.mode == "sinking" then
		local u = modeProgress(creature, now)
		model:PivotTo(poseCFrame(creature, -C.BURROW_DEPTH * u, 0, 0))
		if u >= 1 then
			setMode(creature, "buried", 0, now)
		end
	elseif creature.mode == "buried" then
		-- Tunnels straight at the player. Still obstacle-clamped: it goes
		-- round the rocks, not through them.
		if root then
			creature.yaw0 = yawToward(root.Position - creature.pos)
			creature.pos = resolveHorizontal(creature, flatUnit(root.Position - creature.pos) * C.BURROW_SPEED * dt)
		end
		model:PivotTo(poseCFrame(creature, -C.BURROW_DEPTH, 0, 0))
		if root and dist <= C.BURROW_AMBUSH_RADIUS then
			setMode(creature, "emerging", C.BURROW_EMERGE_TIME, now)
			setBuried(creature, false)
			damagePlayersInRadius(
				creature.pos,
				C.BURROW_EMERGE_RADIUS,
				C.BURROW_DAMAGE_MIN,
				C.BURROW_DAMAGE_MAX,
				creature,
				0.6
			)
			fireEvent("emerge", creature.pos, { radius = C.BURROW_EMERGE_RADIUS })
		end
	else -- emerging: leaps up out of the sand
		local u = modeProgress(creature, now)
		local arc = math.sin(u * math.pi)
		model:PivotTo(poseCFrame(creature, C.BURROW_EMERGE_HOP * arc, 0, math.rad(25) * arc))
		if u >= 1 then
			setMode(creature, "surfaced", C.BURROW_SURFACE_TIME, now)
		end
	end
end

-- ---------------------------------------------------------------- mimic (Pearl Mimic)
-- closed (untargetable, still) -> snapping (lid cracks open as the tell,
-- then the bite) -> open (gaping, hittable) -> closed. The lid is the
-- model's Fish_Fins part, hinged server-side about the back of the shell.
local function updateMimic(creature, now: number, dt: number)
	local model = creature.model
	if not creature.mode then
		setMode(creature, "closed", C.MIMIC_CLOSED_MIN, now)
		creature.untargetable = true
		model:SetAttribute(ATTR_OPEN, false)
		local body = model.PrimaryPart
		local lid = model:FindFirstChild("Fish_Fins")
		if body and lid and lid:IsA("BasePart") then
			creature.lid = lid
			creature.lidOffset = body.CFrame:ToObjectSpace(lid.CFrame)
		end
	end
	local root, _, dist = nearestPlayerRoot(creature.pos)
	local lidAngle = 0

	if creature.mode == "closed" then
		model:PivotTo(poseCFrame(creature, 0, 0, 0))
		if now >= creature.modeUntil and root and dist <= C.MIMIC_SNAP_RADIUS then
			setMode(creature, "snapping", C.MIMIC_SNAP_WINDUP, now)
		end
	elseif creature.mode == "snapping" then
		local u = modeProgress(creature, now)
		lidAngle = C.MIMIC_LID_OPEN * 0.35 * u
		if root then
			creature.yaw0 = yawToward(root.Position - creature.pos)
		end
		model:PivotTo(poseCFrame(creature, 0, 0, 0))
		if u >= 1 then
			damagePlayersInRadius(
				creature.pos,
				C.MIMIC_SNAP_DAMAGE_RADIUS,
				C.MIMIC_DAMAGE_MIN,
				C.MIMIC_DAMAGE_MAX,
				creature,
				0.7
			)
			fireEvent("snap", model:GetPivot().Position, {})
			setMode(creature, "open", C.MIMIC_OPEN_TIME, now)
			creature.untargetable = false
			model:SetAttribute(ATTR_OPEN, true)
		end
	else -- open: hangs wide, then shuts quickly at the end
		slideKnockback(creature, dt)
		local u = modeProgress(creature, now)
		lidAngle = C.MIMIC_LID_OPEN * (1 - u * u * u)
		model:PivotTo(poseCFrame(creature, 0, 0, 0))
		if u >= 1 then
			setMode(creature, "closed", C.MIMIC_CLOSED_MIN, now)
			creature.untargetable = true
			creature.knockVel = nil
			model:SetAttribute(ATTR_OPEN, false)
		end
	end

	-- Pose the lid after the pivot. An upright creature faces the player with
	-- its local +X (yawToward), so the gape is at +X and the hinge sits
	-- MIMIC_HINGE_BACK behind the shell's centre on -X; rotating about the
	-- shell's Z raises the front edge. (The CreaturePack Mimic and the
	-- stand-in are both authored to this frame.)
	local body = model.PrimaryPart
	if creature.lid and body then
		creature.lid.CFrame = body.CFrame
			* CFrame.new(-C.MIMIC_HINGE_BACK, 0, 0)
			* CFrame.Angles(0, 0, lidAngle)
			* CFrame.new(C.MIMIC_HINGE_BACK, 0, 0)
			* creature.lidOffset
	end
end

-- ---------------------------------------------------------------- thief (Pickpocket Hermit)
-- chase -> (contact: pickpocket) -> flee (zig-zag) -> chase. The loot rides
-- the struct and comes back (with a bonus) through Killed's 4th value.
local function stealCoins(creature, player: Player, now: number): number
	local service = progression()
	local coins = service.getState(player).coins
	local stolen = math.clamp(math.floor(coins * C.THIEF_STEAL_FRACTION), C.THIEF_STEAL_MIN, C.THIEF_STEAL_MAX)
	stolen = math.min(stolen, coins)
	if stolen <= 0 or not service.spendCoins(player, stolen) then
		return 0
	end
	creature.loot = (creature.loot or 0) + stolen
	-- Stealing counts as fighting: it mustn't wander off with the coins
	-- before there's a chance to chase it down.
	creature.lastFoughtAt = now
	fireEvent("steal", creature.model:GetPivot().Position, { coins = stolen, victim = player.UserId })
	return stolen
end

local function updateThief(creature, now: number, dt: number)
	slideKnockback(creature, dt)
	if not creature.mode then
		setMode(creature, "chase", 0, now)
		creature.lastHitAt = 0
	end
	local model = creature.model
	local root, player, dist = nearestPlayerRoot(creature.pos)
	local hop = C.THIEF_HOP * math.abs(math.sin(now * C.THIEF_HOP_RATE))

	if creature.mode == "flee" then
		if root then
			local away = flatUnit(creature.pos - root.Position)
			local zig = math.sin(now * C.THIEF_ZIGZAG_RATE) * C.THIEF_ZIGZAG
			local dir = CFrame.Angles(0, zig, 0) * away
			creature.yaw0 = yawToward(dir)
			local newPos, blocked = resolveHorizontal(creature, dir * C.THIEF_FLEE_SPEED * dt)
			creature.pos = newPos
			if blocked then
				-- Cornered: turn and fight sooner.
				creature.modeUntil = math.min(creature.modeUntil, now + 0.3)
			end
		end
		model:PivotTo(poseCFrame(creature, hop, 0, 0))
		if now >= creature.modeUntil then
			setMode(creature, "chase", 0, now)
		end
		return
	end

	-- chase
	if root and dist <= C.THIEF_AGGRO then
		creature.yaw0 = approachAngle(creature.yaw0, yawToward(root.Position - creature.pos), C.RUSH_TURN_RATE * dt)
		creature.pos = resolveHorizontal(creature, flatUnit(root.Position - creature.pos) * C.THIEF_SPEED * dt)
		model:PivotTo(poseCFrame(creature, hop, 0, 0))
		if
			tryContact(
				creature,
				player,
				dist,
				C.CONTACT_RADIUS,
				C.THIEF_CONTACT_DAMAGE_MIN,
				C.THIEF_CONTACT_DAMAGE_MAX,
				now
			)
		then
			if stealCoins(creature, player, now) > 0 then
				setMode(creature, "flee", C.THIEF_FLEE_TIME, now)
			else
				-- Nothing to take: bounce off like a rusher and try again.
				creature.pos = resolveHorizontal(creature, -flatUnit(root.Position - creature.pos) * C.CONTACT_BOUNCE)
			end
		end
	else
		local h, yaw, pitch = flop(creature, now)
		model:PivotTo(poseCFrame(creature, h, yaw, pitch))
	end
end

-- ---------------------------------------------------------------- pulser (Voltray)
-- Slides at the player; when close, charges up (Charging attribute - hit it
-- now and the shock is yours, see hitModifiers) then discharges a ring.
local function updatePulser(creature, now: number, dt: number)
	slideKnockback(creature, dt)
	if not creature.mode then
		setMode(creature, "idle", randomBetween(C.PULSE_IDLE_MIN, C.PULSE_IDLE_MAX), now)
	end
	local model = creature.model
	local root, _, dist = nearestPlayerRoot(creature.pos)

	if creature.mode == "charging" then
		local u = modeProgress(creature, now)
		local quiver = math.sin(now * 40) * math.rad(3) * u
		model:PivotTo(poseCFrame(creature, 0.1 * u, quiver, 0))
		if now >= creature.modeUntil then
			creature.charging = false
			model:SetAttribute(ATTR_CHARGING, false)
			damagePlayersInRadius(creature.pos, C.PULSE_RADIUS, C.PULSE_DAMAGE_MIN, C.PULSE_DAMAGE_MAX, creature, 0.5)
			fireEvent("pulse", model:GetPivot().Position, { radius = C.PULSE_RADIUS })
			setMode(creature, "idle", randomBetween(C.PULSE_IDLE_MIN, C.PULSE_IDLE_MAX), now)
		end
		return
	end

	local hop, yaw, pitch = flop(creature, now)
	if root and dist <= C.PULSE_AGGRO then
		creature.yaw0 = approachAngle(creature.yaw0, yawToward(root.Position - creature.pos), C.RUSH_TURN_RATE * dt)
		if dist > 5 then
			creature.pos = resolveHorizontal(creature, flatUnit(root.Position - creature.pos) * C.PULSE_SPEED * dt)
		end
		if now >= creature.modeUntil and dist <= C.PULSE_TRIGGER_RANGE then
			setMode(creature, "charging", C.PULSE_CHARGE, now)
			creature.charging = true
			model:SetAttribute(ATTR_CHARGING, true)
		end
	end
	model:PivotTo(poseCFrame(creature, hop, yaw, pitch))
end

-- ---------------------------------------------------------------- boss (island bosses)
-- One generic updater for every Bosses.luau entry. The boss rises from the
-- deep (untargetable, the intro), then PROWLS - faces the nearest player,
-- drifts toward them, never leaves its arena circle - and between prowls
-- runs one ATTACK at a time, picked at random from the attacks its current
-- health phase allows (never the same one twice running, never one still on
-- cooldown). Every attack is three beats: a WINDUP (the tell - a pose the
-- player can read and a "telegraph" event for the client), the STRIKE (the
-- handler fires once and may keep moving through the beat), and a RECOVER
-- (the opening to hit it). Below `enrageBelow` it enrages: shorter cooldowns
-- and gaps, bigger numbers, a flag for the client.
--
-- It never gets knocked back or juggled (Tuning multipliers 0 for "boss")
-- and never lingers out; BossService raised it and it stays until it's dead.

local function bossDef(creature)
	return creature.row.boss and Bosses.items[creature.row.boss]
end

-- Vertical reach of the boss's area attacks. It rides at the waterline
-- while the players stand on the arena deck (World.DECK_Y + the character's
-- hip height ≈ 5 studs up), so the default AOE tolerance (6) is a coin
-- toss; this covers the deck with room to spare and still ignores anyone
-- up on the island.
local BOSS_HEIGHT_TOLERANCE = 14

-- Forward: defined with the boss arsenal below (dive's shatter, defined
-- above it, spawns one too).
local spawnPool

-- World-space unit vector the boss is facing (an upright creature's local
-- +X, turned by yaw0).
local function bossFacing(creature): Vector3
	return Vector3.new(math.cos(creature.yaw0), 0, -math.sin(creature.yaw0))
end

-- A boss attack's damage range, enraged or not.
local function bossRoll(creature, def, range: { number }): (number, number)
	local mult = if creature.enraged then def.enrageDamageMult else 1
	return math.floor(range[1] * mult + 0.5), math.floor(range[2] * mult + 0.5)
end

-- Hurts every living player within `radius` of `at` whose direction from it
-- lies inside the cone of half-angle `halfAngle` about `facing` - or, with
-- `invert`, everyone in range who is NOT in that cone (the tail lash: all
-- round except dead ahead).
local function damagePlayersInCone(
	at: Vector3,
	facing: Vector3,
	radius: number,
	halfAngle: number,
	invert: boolean,
	minDmg: number,
	maxDmg: number,
	source
)
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root then
			local to = Vector3.new(root.Position.X - at.X, 0, root.Position.Z - at.Z)
			local d = to.Magnitude
			if d <= radius and math.abs(root.Position.Y - at.Y) <= C.AOE_HEIGHT_TOLERANCE * 2 then
				local inside = d < 0.01 or math.acos(math.clamp(to.Unit:Dot(facing), -1, 1)) <= halfAngle
				if inside ~= invert then
					PlayerService.damage(player, math.random(minDmg, maxDmg), source, { bypassIframe = true })
				end
			end
		end
	end
end

-- Keep the boss inside its arena circle (centre = where it rose).
local function clampToArena(creature, def)
	local anchor = creature.anchor
	if not anchor then
		return
	end
	local off = Vector3.new(creature.pos.X - anchor.X, 0, creature.pos.Z - anchor.Z)
	if off.Magnitude > def.arena.radius then
		local clamped = anchor + off.Unit * def.arena.radius
		creature.pos = groundedPos(Vector3.new(clamped.X, creature.pos.Y, clamped.Z), creature.halfThickness)
	end
end

-- A random point on the ground within `spread` of the player's feet - where
-- a glob or a spine comes down.
local function scatterAround(root: BasePart, spread: number): Vector3
	local angle = math.random() * math.pi * 2
	local r = math.sqrt(math.random()) * spread
	local at = root.Position + Vector3.new(math.cos(angle) * r, 0, math.sin(angle) * r)
	return groundedPos(at, 0)
end

-- Queue a projectile that lands on its own clock (the update loop lands it,
-- even mid-attack) and tell the clients to draw it flying.
local function throwGlob(
	creature,
	def,
	p,
	landing: Vector3,
	flight: number,
	now: number,
	event: string,
	drawKind: string,
	extras: { [string]: any }?
)
	creature.globs = creature.globs or {}
	local lo, hi = bossRoll(creature, def, p.damage)
	local glob = {
		landing = landing,
		landAt = now + flight,
		radius = p.radius,
		min = lo,
		max = hi,
		event = event,
	}
	if extras then
		for k, v in extras do
			glob[k] = v
		end
	end
	table.insert(creature.globs, glob)
	local mouth = creature.model:GetPivot().Position + bossFacing(creature) * 4 + Vector3.new(0, 2, 0)
	-- `boss = true` picks the boss's own sound set on the client.
	fireEvent(drawKind, mouth, { to = landing, flight = flight, arc = 10, boss = true })
end

local function bossMouth(creature): Vector3
	return creature.model:GetPivot().Position + bossFacing(creature) * 5
end

-- Attack handlers. Each may define:
--   windup(creature, def, p, u, sub)               - pose the tell (u 0..1)
--   fire(creature, def, p, now, root, player, dist)  - once, as the strike begins
--   strike(creature, def, p, now, dt, u, root, sub)  - per frame during the strike (u 0..1)
--   finish(creature, def, p, now)                    - once, as the strike ends
--   recover(creature, def, p, u, sub)                - pose the recovery (u 0..1)
-- A handler without a pose hook just sits at its submerged rest pose.
local ATTACK_HANDLERS = {}

-- HOW FAR INTO THE STRIKE EACH OF THESE LANDS ITS BLOW.
--
-- Named, and read by BOTH the handler that deals the damage and the telegraph
-- that announces it, because those two were disagreeing and the telegraph was
-- the one telling the truth about the wrong moment. The stock tell is fired
-- with `duration = p.windup`, so a client's countdown completes when the
-- WINDUP ends - but these three handlers deal their damage part-way into the
-- STRIKE, which happens afterwards. The marker finishes, the player reads it
-- as over, steps back in, and takes the hit.
--
-- Measured on the rows that use them: `ringpulse` at 0.95 of a 1.6s strike
-- finishes its countdown 1.52 SECONDS before the blow, against a windup of
-- only 1.8s - so nearly half the time between "warning starts" and "damage
-- lands" happens after the warning says it is finished. `phantom` is 0.72s
-- early, the four `lunge` rows 0.22 to 0.32s.
--
-- Brinejaw's tail slam had this exact defect and its own constant for it
-- (`SLAM_IMPACT`); it is not on this table only because its row opts out of
-- the stock tell and fires its own marker. Any handler added here that
-- damages mid-strike belongs on this table, or its tell will lie by
-- construction.
local PHANTOM_IMPACT = 0.80
local LUNGE_IMPACT = 0.72
local RINGPULSE_IMPACT = 0.95
-- Pyrelisk's three. `handfall` lands its blow at 0.95 of the strike, which is
-- where the pose actually brings the fist down: it used to be 0.45, and the
-- shockwave went off while the hand was still 235 studs in the air and 60
-- studs outside the arena. The handler reads THIS constant, so the tell's
-- countdown and the blow cannot drift apart again. The two continuous moves
-- are dangerous for the whole
-- of theirs - a rake is over when the arm stops travelling, a breath when it
-- stops burning - so their tells run to the end of the strike rather than to
-- the end of the windup. The other two colossus handlers are deliberately
-- absent: `ashfall` and `shardhurl` both damage on their OWN clocks (queued
-- strikes and thrown slabs, each carrying its own mark), so for them the
-- stock tell really is finished when the windup is - it is the body
-- committing, not the landing.
local HANDFALL_IMPACT = 0.95
local RIMSWEEP_IMPACT = 1.0
local VENTBREATH_IMPACT = 1.0
-- A CHARGE IS DANGEROUS FOR THE WHOLE OF ITS TRAVEL, and lands its shockwave
-- (`slamRadius`, in `finish`) at the very end of it - the same shape as
-- `rimsweep` and `ventbreath`, so it takes the same 1.0. Its absence was worth
-- a full strike's length of lie to every row that names it: the countdown
-- finished when the windup did, while the body was only then setting off.
--
-- VERIFIED, not assumed: `handler = "charge"` appears exactly twice in the
-- whole project - Bosses.luau's `rimefang.breach` (1.0s strike) and
-- `old_gnashroot.wallow` (1.1s) - and nowhere in Creatures.luau's kits. So it
-- fixes those two, and only those two. Pyrelisk does NOT charge: its book is
-- handfall, rimsweep, ventbreath, ashfall and shardhurl, three of which are
-- already on this table and two of which deliberately are not.
local CHARGE_IMPACT = 1.0
-- A BITE CLOSES ITS JAWS PART-WAY IN, and `snap` always has: its handler
-- damages at `u >= SNAP_IMPACT` of the strike, and the constant below is the
-- one the handler reads, so the countdown and the jaws cannot drift apart the
-- way they could while that 0.4 was a literal in one place and absent in the
-- other. Worth 0.14s on both rows that use it (a 0.35s strike): Gnashroot's
-- bite and Rimefang's. The four kitted hostile rows on `snap` gain the same
-- honesty, since a kit runs this very loop.
local SNAP_IMPACT = 0.4
local HANDLER_IMPACT = {
	charge = CHARGE_IMPACT,
	snap = SNAP_IMPACT,
	phantom = PHANTOM_IMPACT,
	lunge = LUNGE_IMPACT,
	ringpulse = RINGPULSE_IMPACT,
	handfall = HANDFALL_IMPACT,
	rimsweep = RIMSWEEP_IMPACT,
	ventbreath = VENTBREATH_IMPACT,
}

-- ------------------------------------------------------- conducting a ring
--
-- A boss with a `parts` ring (the Kraken) does not need a second system to
-- animate its arms: every arm is already a creature with a rear-slam-recover
-- machine of its own (updateTentacle), and the client already draws the limb
-- to wherever that creature is. So an arm attack is not new choreography - it
-- is the boss ORDERING arms that were going to slam anyway to slam together,
-- in an order it chooses, on its clock instead of theirs.
--
-- That is the whole trick, and it is why these handlers are short. What they
-- buy is the difference between eight things that happen to be near you and
-- one animal using eight arms.

-- Its live arms in RING ORDER, on the socket index spawnBossParts already
-- stamps. Dead arms leave gaps rather than renumbering, so a wave still
-- travels the way the ring is actually laid out.
local function livingArms(creature)
	local arms = {}
	for _, part in creatures do
		if part.partOf == creature and not part.dead and part.socketIndex then
			table.insert(arms, part)
		end
	end
	table.sort(arms, function(a, b)
		return a.socketIndex < b.socketIndex
	end)
	return arms
end

-- Order one arm to slam at `at`. A commanded arm ignores its own aggro range
-- and its own cooldown - the Kraken is conducting, not asking - and rears
-- `lift` studs instead of the idle machine's polite 1.8, because a slam you
-- are meant to run from has to be visible from across the arena.
-- The order is held SEPARATELY from the values the arm is currently swinging
-- on, and only becomes those at the moment the arm actually starts. Writing
-- straight through would rewrite the tell of an arm that is already rearing -
-- a telegraph that changes length while you are reading it is the one thing a
-- telegraph must never do.
--
-- AN ORDER IS ALSO A DEADLINE, which is what SLAM_ORDER_GRACE below is for.
-- `slamAt` has exactly one consumer - the idle branch of `updateTentacle` -
-- so an arm that is mid-windup or mid-recovery when the wave reaches its
-- socket cannot act on the order at the moment it is given. It used to hold
-- it instead and fire it the next time it fell idle: out of formation,
-- seconds after the beat, ignoring its own cooldown - and the next command
-- would queue behind that one, so a ring knocked off the beat once stayed
-- off it for the rest of the fight.
local function commandArm(part, at: number, windup: number, lift: number)
	part.slamAt = at
	part.slamOrderWindup = windup
	part.slamOrderLift = lift
end

-- How long after its beat a commanded slam is still worth performing. Past
-- this the order is dropped WITHOUT firing: a wave beat that has gone by is
-- dropped honestly, because a late lone slam out of formation reads as the
-- arena hitting you at random, and that is worse than a gap in the wave.
local SLAM_ORDER_GRACE = 0.75

-- Jaw Snap: rears back, then lunges and bites everything in front.
ATTACK_HANDLERS.snap = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.8 * u, 0, math.rad(24) * u))
	end,
	strike = function(creature, def, p, _now, dt, u, _root, sub)
		creature.pos = resolveHorizontal(creature, bossFacing(creature) * (p.lunge / p.duration) * dt)
		-- CLAMP FIRST. The lunge is 13-14 studs and the clamp only ran in
		-- `finish`, so a bite taken at the arena's rim dealt its cone damage
		-- and drew its `bossSnap` ring from a position outside the arena that
		-- the boss was yanked back from immediately afterwards.
		clampToArena(creature, def)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.8 * (1 - u), 0, math.rad(-14)))
		if not creature.attack.fired and u >= SNAP_IMPACT then
			creature.attack.fired = true
			local lo, hi = bossRoll(creature, def, p.damage)
			damagePlayersInCone(creature.pos, bossFacing(creature), p.radius, p.cone, false, lo, hi, creature)
			fireEvent("bossSnap", bossMouth(creature), { radius = p.radius })
		end
	end,
	finish = function(creature, def)
		clampToArena(creature, def)
	end,
}

-- Tail Lash: winds up, then whips the whole body round - hits everyone
-- within `radius` of its pivot, all the way round. It USED to spare the
-- front cone ("everything not in front"), but the boss turns to face its
-- target through the windup, so a lone player was always in front and it
-- never landed (playtest, 2026-08-22). The dodge is distance: back off
-- past the ring the tell draws.
ATTACK_HANDLERS.tail = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub, math.rad(-28) * u, 0))
	end,
	fire = function(creature, def, p)
		local lo, hi = bossRoll(creature, def, p.damage)
		damagePlayersInRadius(creature.pos, p.radius, lo, hi, creature, 0.7, BOSS_HEIGHT_TOLERANCE)
		fireEvent("sweep", creature.pos, { radius = p.radius, facing = bossFacing(creature) })
	end,
	strike = function(creature, _def, _p, _now, _dt, u, _root, sub)
		creature.model:PivotTo(poseCFrame(creature, sub, math.rad(-28) + math.rad(70) * math.sin(u * math.pi * 0.5), 0))
	end,
}

-- Brine Volley: a fan of globs that splash down around the player.
ATTACK_HANDLERS.volley = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.4 * u, 0, math.rad(30) * u))
	end,
	fire = function(creature, def, p, now, root)
		if not root then
			return
		end
		for i = 1, p.count do
			throwGlob(
				creature,
				def,
				p,
				scatterAround(root, p.spread),
				p.flight + (i - 1) * p.stagger,
				now,
				"splash",
				"spit"
			)
		end
	end,
	strike = function(creature, _def, _p, _now, _dt, u, _root, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.4 * (1 - u), 0, math.rad(30) * (1 - u)))
	end,
}

-- Tidal Slam: rears right up, crashes down - a shockwave ring.
ATTACK_HANDLERS.slam = {
	windup = function(creature, _def, _p, u, sub)
		local e = smoothstep(u)
		creature.model:PivotTo(poseCFrame(creature, sub + 3.0 * e, 0, math.rad(38) * e))
	end,
	fire = function(creature, def, p)
		local lo, hi = bossRoll(creature, def, p.damage)
		damagePlayersInRadius(creature.pos, p.radius, lo, hi, creature, 0.5, BOSS_HEIGHT_TOLERANCE)
		fireEvent("slam", creature.pos, { radius = p.radius })
	end,
	strike = function(creature, _def, _p, _now, _dt, _u, _root, sub)
		creature.model:PivotTo(poseCFrame(creature, sub - 0.7, 0, math.rad(-10)))
	end,
	recover = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub - 0.7 * (1 - u), 0, math.rad(-10) * (1 - u)))
	end,
}

-- Lure Pull: the lure flares and drags every nearby player toward the maw
-- (the clients apply the pull to their own character), then it snaps.
ATTACK_HANDLERS.pull = {
	fire = function(creature, _def, p)
		fireEvent("pull", creature.model:GetPivot().Position, {
			radius = p.radius,
			strength = p.strength,
			duration = p.duration,
		})
	end,
	strike = function(creature, _def, _p, now, _dt, _u, _root, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + math.sin(now * 9) * 0.12, 0, math.rad(8)))
	end,
}

-- Spawn Brood: coughs up minions, thrown at the player.
ATTACK_HANDLERS.brood = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.3 * u, 0, math.rad(-16) * u))
	end,
	fire = function(creature, _def, p, _now, root)
		local from = bossMouth(creature)
		for i = 1, p.count do
			local rowId = p.rows[((i - 1) % #p.rows) + 1]
			local row = Creatures.items[rowId]
			if row then
				local target = if root then root.Position else from + bossFacing(creature) * 12
				CreatureService.spawn(row, from, target, "Neutral")
			end
		end
		fireEvent("summon", from, { count = p.count })
	end,
}

-- Dive Ambush: sinks out of reach, tunnels under the player, bursts up.
-- Underwater it ignores obstacles (it's BELOW the deck - the obstacle-
-- clamped mover stopped it at the deck's edge and it burst short;
-- playtest, 2026-08-22), tracks the player's live position, and for the
-- last `lock` seconds of the strike freezes under where they are RIGHT
-- THEN with a ring tell on the surface - the window to get clear - before
-- bursting up there. It may surface on the deck itself; the prowl's arena
-- clamp walks it back into the water afterwards.
ATTACK_HANDLERS.dive = {
	windup = function(creature, def, _p, u, sub)
		local e = smoothstep(u)
		creature.model:PivotTo(poseCFrame(creature, sub + (-def.riseDepth - sub) * e, 0, math.rad(-30) * e))
	end,
	fire = function(creature)
		setBuried(creature, true)
		creature.attack.locked = false
		fireEvent("bossDive", creature.pos, {})
	end,
	strike = function(creature, def, p, now, dt, _u, root)
		local a = creature.attack
		local lock = p.lock or 0
		if not a.locked then
			if root then
				creature.yaw0 = yawToward(root.Position - creature.pos)
				local step = flatUnit(root.Position - creature.pos)
					* math.min(p.speed * dt, (root.Position - creature.pos).Magnitude)
				creature.pos = groundedPos(creature.pos + step, creature.halfThickness)
			end
			if now >= a.phaseUntil - lock then
				-- Lock: straight under the player's feet, then hold.
				if root then
					creature.pos = groundedPos(
						Vector3.new(root.Position.X, creature.pos.Y, root.Position.Z),
						creature.halfThickness
					)
				end
				a.locked = true
				fireEvent("telegraph", creature.pos, { kind = "burst", duration = lock, radius = p.radius })
			end
		end
		creature.model:PivotTo(poseCFrame(creature, -def.riseDepth, 0, 0))
	end,
	finish = function(creature, def, p, now)
		setBuried(creature, false)
		local lo, hi = bossRoll(creature, def, p.damage)
		damagePlayersInRadius(creature.pos, p.radius, lo, hi, creature, 0.5, BOSS_HEIGHT_TOLERANCE)
		fireEvent("emerge", creature.pos, { radius = p.radius, big = true })
		-- Rimefang's undersheet hunt: the burst shatters the surface into a
		-- lingering frost slick (p.shatter = spawnPool spec).
		if p.shatter then
			spawnPool(creature, creature.pos, p.shatter, now)
		end
	end,
	recover = function(creature, def, _p, u, sub)
		-- Bursts up past its rest height and settles back into it.
		local e = 1 - (1 - u) ^ 3
		local hop = -def.riseDepth + (sub + def.riseDepth) * e + 2.5 * math.sin(e * math.pi)
		creature.model:PivotTo(poseCFrame(creature, hop, 0, math.rad(28) * (1 - e)))
	end,
}

-- Spine Barrage: quivers, then rains spines down around the player.
ATTACK_HANDLERS.spines = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(
			poseCFrame(creature, sub + 0.2 * u, math.sin(u * 40) * math.rad(2) * u, math.rad(12) * u)
		)
	end,
	fire = function(creature, def, p, now, root)
		if not root then
			return
		end
		for i = 1, p.count do
			throwGlob(
				creature,
				def,
				p,
				scatterAround(root, p.spread),
				p.flight + (i - 1) * (p.duration / p.count),
				now,
				"spineHit",
				"spine"
			)
		end
	end,
	strike = function(creature, _def, _p, now, _dt, _u, _root, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.2, math.sin(now * 40) * math.rad(2), math.rad(12)))
	end,
}

-- ==================================================== the boss arsenal (2026-08-27)
-- The per-island movesets are built from these parameterized primitives; a
-- Bosses.luau attack names its engine behaviour with `p.handler` (so Old
-- Brinejaw's "sweeplow" and "constrict" are both `orbitsweep`
-- with different numbers and skins), and `p.skin` colors the client's
-- effects per island. Three timed systems live on the creature struct and
-- tick in update() beside globs/puffs, so they keep running mid-attack and
-- die with the boss: `pools` (lingering ground hazards), `strikes`
-- (telegraphed point/ring impacts), `lures` (proximity mines / decoys).

local BOSS_POOL_TICK = 0.7

-- A lingering ground hazard: damages and/or slows anyone standing in it.
-- spec = { radius, duration, min?, max? (damage per tick), slow? (walkspeed
-- mult the client applies), skin? }. The slow is client-applied like the
-- lure pull: the server broadcasts a short `chill` covering the pool every
-- tick and each client applies it to its own character if it's inside.
function spawnPool(creature, at: Vector3, spec, now: number)
	creature.pools = creature.pools or {}
	table.insert(creature.pools, {
		pos = at,
		radius = spec.radius,
		expiresAt = now + spec.duration,
		nextTickAt = now + 0.3,
		min = spec.min,
		max = spec.max,
		slow = spec.slow,
		skin = spec.skin,
	})
	fireEvent("poolSpawn", at, { radius = spec.radius, duration = spec.duration, skin = spec.skin })
end

-- A telegraphed impact at a fixed point (or ring): the tell draws at
-- `tellAt`, the hit lands at `hitAt`. opts: shape ("disc" | "annulus"),
-- inner/outer (annulus), snare (seconds), chain { leash, duration }, pool
-- (spawnPool spec), hitEvent, damage { lo, hi } override.
local function queueStrike(creature, def, p, at: Vector3, tellAt: number, hitAt: number, opts)
	opts = opts or {}
	creature.strikes = creature.strikes or {}
	local lo, hi = nil, nil
	local range = opts.damage or p.damage
	if range then
		lo, hi = bossRoll(creature, def, range)
	end
	table.insert(creature.strikes, {
		pos = at,
		tellAt = tellAt,
		hitAt = hitAt,
		tellFired = false,
		radius = opts.radius or p.radius,
		shape = opts.shape,
		inner = opts.inner,
		outer = opts.outer,
		min = lo,
		max = hi,
		snare = opts.snare,
		chain = opts.chain,
		pool = opts.pool,
		hitEvent = opts.hitEvent,
		skin = p.skin,
	})
end

-- Everyone standing in the ring band (the expanding-nova shape: safe inside
-- AND outside; the dodge is stepping across the band before it detonates).
local function damagePlayersInAnnulus(at: Vector3, inner: number, outer: number, minDmg, maxDmg, source)
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid and humanoid.Health > 0 then
			local d = (Vector3.new(root.Position.X, 0, root.Position.Z) - Vector3.new(at.X, 0, at.Z)).Magnitude
			if d >= inner and d <= outer and math.abs(root.Position.Y - at.Y) <= BOSS_HEIGHT_TOLERANCE then
				PlayerService.damage(player, math.random(minDmg, maxDmg), source, { bypassIframe = true })
			end
		end
	end
end

-- Every living player's root within `range` of `at`.
local function livingRootsNear(at: Vector3, range: number): { { player: Player, root: BasePart } }
	local out = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid and humanoid.Health > 0 then
			local d = (Vector3.new(root.Position.X, 0, root.Position.Z) - Vector3.new(at.X, 0, at.Z)).Magnitude
			if d <= range then
				table.insert(out, { player = player, root = root })
			end
		end
	end
	return out
end

local function rotateFlat(v: Vector3, angle: number): Vector3
	local c, s = math.cos(angle), math.sin(angle)
	return Vector3.new(v.X * c - v.Z * s, 0, v.X * s + v.Z * c)
end

-- CONTACT ALONG A BODY THAT IS A CHAIN, for the one boss whose hide is not a
-- ball. Each node carries its OWN height test, and that is the whole trick:
-- during Rimefang's breach the head is up its parabola (9 studs at the apex -
-- the path takes its arch height from `breach.leap` itself, so the drawn leap
-- and this hitbox cannot disagree) while the links behind it are still at the
-- surface, having not yet left the water, so the leap sweeps a
-- corridor the length of the animal instead of an 11-stud circle at the nose
-- that is airborne for 89% of the charge. Once per player, off the caller's
-- own hit set.
local function bodyContact(creature, body, reach: number, lo: number, hi: number, hitSet, skin: string?)
	for _, entry in livingRootsNear(creature.pos, reach + RimefangPath.BODY_LENGTH) do
		if not hitSet[entry.player] then
			local at = entry.root.Position
			for _, node in body do
				local to = at - node.pos
				if Vector3.new(to.X, 0, to.Z).Magnitude <= reach and math.abs(to.Y) <= BOSS_HEIGHT_TOLERANCE then
					hitSet[entry.player] = true
					PlayerService.damage(entry.player, math.random(lo, hi), creature, { bypassIframe = true })
					fireEvent("strikeHit", at, { radius = 3, skin = skin })
					break
				end
			end
		end
	end
end

-- Charge: picks its line at the moment of firing and rushes it, hitting each
-- player at most once. p: length, width (contact radius), damage; optional
-- leap (hop height - the body is airborne mid-arc and can't contact-hit),
-- slamRadius (a landing shockwave at the end), trail { every + spawnPool
-- spec } (hazards dropped along the wake).
ATTACK_HANDLERS.charge = {
	windup = function(creature, _def, _p, u, sub)
		local e = smoothstep(u)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.7 * e, 0, math.rad(20) * e))
	end,
	fire = function(creature, _def, p, _now, root)
		local a = creature.attack
		a.dir = if root then flatUnit(root.Position - creature.pos) else bossFacing(creature)
		a.hitSet = {}
		a.dist = 0
		a.nextTrail = if p.trail then p.trail.every * 0.5 else math.huge
		creature.yaw0 = yawToward(a.dir)
		fireEvent("splash", creature.pos, { radius = 4 })
	end,
	strike = function(creature, def, p, now, dt, u, _root, sub)
		local a = creature.attack
		local step = (p.length / p.duration) * dt
		creature.pos = resolveHorizontal(creature, a.dir * step)
		-- CLAMP BEFORE ANYTHING READS THE POSITION. This used to run only in
		-- `finish`, so every frame of contact damage - and every `strikeHit`
		-- ring the client drew for it - was resolved at a position the arena
		-- would refuse a moment later, and the last of them landed where the
		-- boss demonstrably no longer was. A charge that runs into the rim
		-- should stop at the rim, and be the rim's length of charge.
		clampToArena(creature, def)
		a.dist += step
		local hop = if p.leap then math.sin(u * math.pi) * p.leap else 0
		creature.model:PivotTo(poseCFrame(creature, sub + hop, 0, math.rad(-8)))
		-- Contact damage, once per player per charge - not while airborne.
		--
		-- A boss with a BODY tests its whole body (see `bodyContact`): for
		-- Rimefang the `hop` test is the wrong question entirely, because the
		-- head being 26 studs up its leap says nothing about the 40 studs of
		-- whale behind it that are still ploughing the floe. Each node's own
		-- height stands in for `hop`, node by node. Every other charging boss
		-- has no body and takes the branch it always took, to the stud.
		local body = rimefangBody(creature)
		if body then
			local lo, hi = bossRoll(creature, def, p.damage)
			bodyContact(creature, body, p.width, lo, hi, a.hitSet, p.skin)
		elseif hop < 1.5 then
			local lo, hi = bossRoll(creature, def, p.damage)
			for _, entry in livingRootsNear(creature.pos, p.width) do
				if not a.hitSet[entry.player] then
					a.hitSet[entry.player] = true
					if math.abs(entry.root.Position.Y - creature.pos.Y) <= BOSS_HEIGHT_TOLERANCE then
						PlayerService.damage(entry.player, math.random(lo, hi), creature, { bypassIframe = true })
						fireEvent("strikeHit", entry.root.Position, { radius = 3, skin = p.skin })
					end
				end
			end
		end
		if p.trail and a.dist >= a.nextTrail then
			a.nextTrail += p.trail.every
			spawnPool(creature, creature.pos, p.trail, now)
		end
	end,
	finish = function(creature, def, p, now)
		clampToArena(creature, def)
		if p.slamRadius then
			local lo, hi = bossRoll(creature, def, p.damage)
			local body = rimefangBody(creature)
			if body then
				-- THE WHOLE ANIMAL LANDS, not its nose. A 56-stud whale coming
				-- down flat cracks the floe along its length; a single ring at
				-- the head left the crash's back half harmless.
				bodyContact(creature, body, p.slamRadius, lo, hi, {}, p.skin)
			else
				damagePlayersInRadius(creature.pos, p.slamRadius, lo, hi, creature, 0.5, BOSS_HEIGHT_TOLERANCE)
			end
			fireEvent("slam", creature.pos, { radius = p.slamRadius, skin = p.skin })
		end
		if p.shatter then
			spawnPool(creature, creature.pos, p.shatter, now)
		end
	end,
	recover = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub, 0, math.rad(-8) * (1 - u)))
	end,
}

-- Beam: a sustained jet swept across an arc - the boss's whole body turns
-- through the sweep, so the dodge is running WITH or against the rotation.
-- Ticks without the i-frame bypass (it re-hits), so standing in it hurts but
-- doesn't shred. p: sweep (degrees), cone (half-angle degrees), range, tick,
-- damage (per tick); optional chill { mult, duration }, sweepDir (+1/-1).
ATTACK_HANDLERS.beam = {
	windup = function(creature, _def, _p, u, sub)
		local e = smoothstep(u)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.6 * e, 0, math.rad(26) * e))
	end,
	fire = function(creature, _def, p)
		local a = creature.attack
		a.dir0 = creature.yaw0 + math.rad(p.sweep) * 0.5 * (p.sweepDir or 1)
		a.nextTickAt = 0
	end,
	strike = function(creature, def, p, now, _dt, u, _root, sub)
		local a = creature.attack
		creature.yaw0 = a.dir0 - math.rad(p.sweep) * u * (p.sweepDir or 1)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.6, 0, math.rad(10)))
		if now >= a.nextTickAt then
			a.nextTickAt = now + (p.tick or 0.3)
			local facing = bossFacing(creature)
			local origin = creature.model:GetPivot().Position
			local lo, hi = bossRoll(creature, def, p.damage)
			local half = math.rad(p.cone)
			for _, entry in livingRootsNear(creature.pos, p.range) do
				local to =
					Vector3.new(entry.root.Position.X - creature.pos.X, 0, entry.root.Position.Z - creature.pos.Z)
				if to.Magnitude < 0.01 or math.acos(math.clamp(to.Unit:Dot(facing), -1, 1)) <= half then
					PlayerService.damage(entry.player, math.random(lo, hi), creature)
					if p.chill then
						fireEvent("chill", entry.root.Position, {
							radius = 4,
							mult = p.chill.mult,
							duration = p.chill.duration,
							skin = p.skin,
						})
					end
				end
			end
			fireEvent("beam", origin + facing * 4 + Vector3.new(0, 2, 0), {
				to = origin + facing * p.range,
				skin = p.skin,
			})
		end
	end,
	recover = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.6 * (1 - u), 0, math.rad(10) * (1 - u)))
	end,
}

-- Poolvolley: the volley, but every glob leaves a lingering pool where it
-- lands (p.pool = spawnPool spec).
ATTACK_HANDLERS.poolvolley = {
	windup = ATTACK_HANDLERS.volley.windup,
	fire = function(creature, def, p, now, root)
		if not root then
			return
		end
		for i = 1, p.count do
			throwGlob(
				creature,
				def,
				p,
				scatterAround(root, p.spread),
				p.flight + (i - 1) * p.stagger,
				now,
				"splash",
				"spit",
				{
					pool = p.pool,
				}
			)
		end
	end,
	strike = ATTACK_HANDLERS.volley.strike,
}

-- Barrage: a pattern of telegraphed strikes. p.pattern:
--   "scatter"  - p.count strikes scattered p.spread around the target player
--   "everyone" - one strike under EVERY living player (plus p.extra
--                scattered around each), arena-wide pressure
--   "line"     - p.count strikes marching from the boss toward the target,
--                p.spacing apart, p.interval seconds between steps; p.fan
--                (degrees list) repeats the line at offsets
--   "wall"     - p.ranks ranks of a p.width-wide wall marching from the boss
--                toward the target (the broadside)
--   "rings"    - concentric ring bands around the boss (p.rings radii,
--                p.ringWidth wide), detonating outward - the nova
-- p.arm is the tell lead (seconds between a strike's ring and its hit).
ATTACK_HANDLERS.barrage = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(
			poseCFrame(creature, sub + 0.3 * u, math.sin(u * 30) * math.rad(2) * u, math.rad(14) * u)
		)
	end,
	fire = function(creature, def, p, now, root)
		local arm = p.arm or 0.9
		if p.pattern == "rings" then
			local center = creature.anchor or creature.pos
			local width = p.ringWidth or 5
			for i, r in p.rings do
				local hitAt = now + arm + (i - 1) * (p.interval or 0.5)
				queueStrike(creature, def, p, center, hitAt - arm, hitAt, {
					shape = "annulus",
					inner = math.max(0, r - width * 0.5),
					outer = r + width * 0.5,
				})
			end
		elseif p.pattern == "line" then
			local dir0 = if root then flatUnit(root.Position - creature.pos) else bossFacing(creature)
			for _, fanDeg in (p.fan or { 0 }) do
				local dir = rotateFlat(dir0, math.rad(fanDeg))
				for i = 1, p.count do
					local at = groundedPos(creature.pos + dir * ((p.startAt or 8) + (i - 1) * p.spacing), 0)
					local hitAt = now + arm + (i - 1) * (p.interval or 0.16)
					queueStrike(creature, def, p, at, hitAt - arm, hitAt, {})
				end
			end
		elseif p.pattern == "wall" then
			local dir = if root then flatUnit(root.Position - creature.pos) else bossFacing(creature)
			local right = rotateFlat(dir, math.pi * 0.5)
			local across = math.max(2, math.floor(p.width / 6) + 1)
			for rank = 0, (p.ranks or 4) - 1 do
				local d = (p.startAt or 10) + rank * (p.rankSpacing or 7)
				local hitAt = now + arm + rank * (p.interval or 0.4)
				for k = 0, across - 1 do
					local offset = (k / (across - 1) - 0.5) * p.width
					local at = groundedPos(creature.pos + dir * d + right * offset, 0)
					queueStrike(creature, def, p, at, hitAt - arm, hitAt, {})
				end
			end
		elseif p.pattern == "everyone" then
			local center = creature.anchor or creature.pos
			for _, entry in livingRootsNear(center, def.aggro * 1.5) do
				local hitAt = now + arm
				queueStrike(creature, def, p, groundedPos(entry.root.Position, 0), now, hitAt, {
					snare = p.snare,
					pool = p.pool,
				})
				for _ = 1, p.extra or 0 do
					queueStrike(creature, def, p, scatterAround(entry.root, p.spread or 10), now, hitAt + 0.3, {})
				end
			end
		else -- scatter
			if root then
				for i = 1, p.count do
					local hitAt = now + arm + (i - 1) * ((p.duration - 0.2) / math.max(p.count, 1))
					queueStrike(creature, def, p, scatterAround(root, p.spread), hitAt - arm, hitAt, {
						pool = p.pool,
					})
				end
			end
		end
	end,
	strike = function(creature, _def, _p, now, _dt, _u, _root, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.3, math.sin(now * 30) * math.rad(2), math.rad(14)))
	end,
}

-- Ring Wave: the arms come down one after another around the ring, so the
-- safe ground is always wherever the wave has just been. Each arm brings its
-- own tell with it, which means the attack reads as a thing travelling toward
-- you rather than as eight simultaneous warnings.
--
-- No `damage` field, deliberately: an arm hits with an arm's force
-- (TENTACLE_DAMAGE_*), and what makes this dangerous is how many of them
-- there are and how little room is between them. Inflating a per-arm number
-- here would also silently change what a lone arm does on its own initiative.
-- p: interval (between neighbours), windupEach (each arm's tell), lift, sweep
-- (how far round it travels, in arms; absent = the whole ring).
ATTACK_HANDLERS.armwave = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.5 * u, 0, math.rad(-10) * u))
	end,
	fire = function(creature, _def, p, now)
		local arms = livingArms(creature)
		if #arms == 0 then
			return
		end
		local dir = if math.random() < 0.5 then 1 else -1
		local from = math.random(1, #arms)
		local span = math.min(p.sweep or #arms, #arms)
		for k = 0, span - 1 do
			local index = ((from - 1 + dir * k) % #arms) + 1
			commandArm(arms[index], now + k * (p.interval or 0.26), p.windupEach or 0.8, p.lift or 13)
		end
	end,
	strike = function(creature, _def, _p, _now, _dt, _u, _root, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.5, 0, math.rad(-10)))
	end,
}

-- The Closing Fist: every arm but a short run of them rears together, and
-- they all come down at once. The arms that DON'T rear ARE the tell - the
-- safe ground is something you read off the animal's own body and run to,
-- not a marker drawn on the floor for you. That is the one attack in the
-- fight that is dodged by looking at the boss instead of at your feet, which
-- is worth having exactly once.
--
-- The long tell is not generosity: the ring is 46 studs out and neighbouring
-- arms stand ~36 apart, so reaching an open seat can mean crossing most of a
-- gap. Stepping out of one arm's 12-stud slam is the cheap out and stays
-- available - the gap is for players who want to keep hitting something.
-- p: gap (arms left open), windupEach, lift.
ATTACK_HANDLERS.armgap = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.7 * u, 0, math.rad(-16) * u))
	end,
	fire = function(creature, _def, p, now)
		local arms = livingArms(creature)
		if #arms <= 1 then
			return
		end
		if #arms <= 2 then
			-- NO GAP TO READ AT THIS SIZE. One seat open out of two is not a
			-- shape you can see on the animal, it is a coin toss - and the
			-- whole point of this move is that you dodge it by looking at the
			-- boss. So the fist closes completely and the long `windupEach`
			-- carries the counterplay on its own: two 12-stud rings with a
			-- two-second tell each is something you step out of.
			for _, arm in arms do
				commandArm(arm, now, p.windupEach or 2.0, p.lift or 16)
			end
			return
		end
		-- THE GAP IS A FRACTION OF THE RING, NOT A COUNT. `gap` is authored
		-- against the full eight (3 open, 5 down), and clamping it flat left
		-- 3 of 4 arms open on a ground-down ring - so the fight's loudest
		-- moment degraded into ONE arm slamming. closingfist is phase-three
		-- only, which is exactly when the ring is short, so the degenerate
		-- case was the only case anybody ever saw. Scaled, four arms give one
		-- open and three down; the `#arms - 2` ceiling keeps at least two
		-- arms coming down, or there is no fist to close.
		local gap = math.clamp(math.floor((p.gap or 3) * #arms / 8 + 0.5), 1, math.max(#arms - 2, 1))
		local from = math.random(1, #arms)
		local open = {}
		for k = 0, gap - 1 do
			open[((from - 1 + k) % #arms) + 1] = true
		end
		for index, arm in arms do
			if not open[index] then
				commandArm(arm, now, p.windupEach or 2.0, p.lift or 16)
			end
		end
	end,
	strike = function(creature, _def, _p, _now, _dt, _u, _root, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.7, 0, math.rad(-16)))
	end,
}

-- Snaretrap: marks the ground under every player's feet; whoever is still
-- inside when it arms is rooted to the spot. p: arm (the escape window),
-- radius, damage, snare (root seconds).
ATTACK_HANDLERS.snaretrap = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub - 0.4 * u, 0, math.rad(-10) * u))
	end,
	fire = function(creature, def, p, now)
		for _, entry in livingRootsNear(creature.pos, def.aggro * 1.2) do
			queueStrike(creature, def, p, groundedPos(entry.root.Position, 0), now, now + p.arm, {
				snare = p.snare,
			})
		end
	end,
}

-- Decoys: plants glowing lures / drifting mines that detonate when anyone
-- comes close (or fizzle after p.lifetime). p: count, spread, trigger,
-- blast, damage, lifetime; optional drift (studs/s toward the nearest
-- player - the powder keg).
ATTACK_HANDLERS.decoys = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.4 * u, 0, math.rad(18) * u))
	end,
	fire = function(creature, def, p, now, root)
		creature.lures = creature.lures or {}
		local center = if root then root.Position else creature.pos
		for _ = 1, p.count do
			local angle = math.random() * math.pi * 2
			local r = p.spread * (0.35 + 0.65 * math.random())
			local at = Vector3.new(center.X + math.cos(angle) * r, World.WATER_Y + 1.2, center.Z + math.sin(angle) * r)
			local lo, hi = bossRoll(creature, def, p.damage)
			table.insert(creature.lures, {
				pos = at,
				trigger = p.trigger,
				blast = p.blast,
				min = lo,
				max = hi,
				expiresAt = now + p.lifetime,
				drift = p.drift,
				nextMoveAt = 0,
				skin = p.skin,
			})
			fireEvent("decoy", at, { lifetime = p.lifetime, skin = p.skin })
		end
	end,
}

-- Phantom: the lights go out, it vanishes, and it reappears at a player's
-- flank mid-bite. p: emergeAt (how far from the player it surfaces), radius,
-- cone (degrees), damage.
ATTACK_HANDLERS.phantom = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub - 1.2 * u, 0, math.rad(-12) * u))
	end,
	fire = function(creature, _def, p, _now, root)
		local a = creature.attack
		setBuried(creature, true)
		a.appeared = false
		fireEvent("phantomOut", creature.pos, { radius = 60, skin = p.skin })
		if root then
			local angle = math.random() * math.pi * 2
			local d = p.emergeAt or 9
			creature.pos = groundedPos(
				Vector3.new(
					root.Position.X + math.cos(angle) * d,
					creature.pos.Y,
					root.Position.Z + math.sin(angle) * d
				),
				creature.halfThickness
			)
		end
	end,
	strike = function(creature, def, p, _now, _dt, u, root, sub)
		local a = creature.attack
		if not a.appeared then
			creature.model:PivotTo(poseCFrame(creature, -def.riseDepth, 0, 0))
			if u >= 0.5 then
				a.appeared = true
				setBuried(creature, false)
				if root then
					creature.yaw0 = yawToward(root.Position - creature.pos)
				end
				fireEvent("phantomIn", creature.pos, { radius = p.radius, skin = p.skin })
			end
			return
		end
		creature.model:PivotTo(poseCFrame(creature, sub + 0.5, 0, math.rad(-12)))
		if not a.fired and u >= PHANTOM_IMPACT then
			a.fired = true
			local lo, hi = bossRoll(creature, def, p.damage)
			damagePlayersInCone(creature.pos, bossFacing(creature), p.radius, math.rad(p.cone), false, lo, hi, creature)
			fireEvent("bossSnap", bossMouth(creature), { radius = p.radius })
		end
	end,
	finish = function(creature, def)
		clampToArena(creature, def)
	end,
}

-- Undertow: the maelstrom's own current - a long, arena-wide drag toward the
-- maw while wreckage rains on whoever it's pulling. p: radius, strength,
-- duration, globEvery, damage (per glob), radius is the pull's reach and the
-- globs land radius p.globRadius.
ATTACK_HANDLERS.undertow = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.8 * u, 0, math.rad(22) * u))
	end,
	fire = function(creature, _def, p, now)
		local a = creature.attack
		local center = creature.anchor or creature.pos
		fireEvent("pull", center, { radius = p.radius, strength = p.strength, duration = p.duration })
		a.nextGlobAt = now + 0.4
	end,
	strike = function(creature, def, p, now, _dt, u, _root, sub)
		local a = creature.attack
		creature.model:PivotTo(
			poseCFrame(
				creature,
				sub + 0.8 + math.sin(now * 3) * 0.3,
				math.sin(u * math.pi * 2) * math.rad(10),
				math.rad(8)
			)
		)
		if now >= a.nextGlobAt then
			a.nextGlobAt = now + (p.globEvery or 0.7)
			local center = creature.anchor or creature.pos
			local targets = livingRootsNear(center, p.radius)
			if #targets > 0 then
				local entry = targets[math.random(#targets)]
				local at = scatterAround(entry.root, 7)
				-- THE RAIN HAS TO REACH THE ROCKS. This is a six-second move
				-- whose entire second half is wreckage coming down on whoever
				-- the current is dragging, and the people being dragged are
				-- standing on the arena's caps 4-6 studs over the water. The
				-- glob's landing is grounded, so a scatter that clears the cap
				-- resolves at the waterline and the default 6-stud gate voided
				-- the hit - the pull landed, the wreckage drew, and nothing
				-- happened. Same tolerance the rest of the boss kit's AoE uses.
				throwGlob(
					creature,
					def,
					{ damage = p.damage, radius = p.globRadius or 7 },
					at,
					0.9,
					now,
					"spineHit",
					"spit",
					{ tolerance = BOSS_HEIGHT_TOLERANCE }
				)
			end
		end
	end,
}

-- Anchortoss: hurls the anchor at where the target stands - the ring is the
-- warning - and whoever it lands on is CHAINED to the spot (the client
-- leashes its own character to the anchor). p: flight, radius, damage,
-- leash, chainDuration.
ATTACK_HANDLERS.anchortoss = {
	windup = function(creature, _def, _p, u, sub)
		local e = smoothstep(u)
		creature.model:PivotTo(poseCFrame(creature, sub + 1.3 * e, 0, math.rad(32) * e))
	end,
	fire = function(creature, def, p, now, root)
		if not root then
			return
		end
		local at = groundedPos(root.Position, 0)
		fireEvent("spine", bossMouth(creature) + Vector3.new(0, 5, 0), {
			to = at,
			flight = p.flight,
			arc = 14,
			boss = true,
		})
		queueStrike(creature, def, p, at, now, now + p.flight, {
			chain = { leash = p.leash, duration = p.chainDuration, radius = p.radius + 3 },
		})
	end,
	strike = function(creature, _def, _p, _now, _dt, u, _root, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 1.3 * (1 - u), 0, math.rad(32 - 46 * u)))
	end,
}

-- Which attacks the current health fraction allows: the LAST phase whose
-- `below` the fraction is at or under.
local function bossPhaseAttacks(def, hpFraction: number): { string }
	local attacks = def.phases[1].attacks
	for _, phase in def.phases do
		if hpFraction <= phase.below then
			attacks = phase.attacks
		end
	end
	return attacks
end

local function pickBossAttack(creature, def, now: number): string
	if creature.forcedAttack then
		local forced = creature.forcedAttack
		creature.forcedAttack = nil
		return forced
	end
	local pool = {}
	-- ONCE PER STANCE, for a move that is an EVENT rather than a rotation
	-- step. `once = "stance"` on a row (Brinejaw's tidal surge and its polyps)
	-- says the move may be picked at most once per stance the boss is in: a
	-- ten-second set-piece that ends in a guaranteed window, or a heal the
	-- party has to answer, stops being either of those things if it comes
	-- round on a cooldown. `creature.stanceUsed` is cleared by the stance
	-- change itself, so entering stance 3 offers both again exactly once.
	-- A row without the field is unaffected, which is every other row in the
	-- project.
	local used = creature.stanceUsed
	for _, name in bossPhaseAttacks(def, creature.health / creature.maxHealth) do
		local readyAt = creature.cooldowns and creature.cooldowns[name] or 0
		local p = def.attacks[name]
		local spent = p and p.once == "stance" and used and used[name]
		if name ~= creature.lastAttack and now >= readyAt and not spent then
			table.insert(pool, name)
		end
	end
	if #pool == 0 then
		-- Always something: the phase list's first attack (each boss leads
		-- its lists with its short-cooldown bread-and-butter bite).
		return bossPhaseAttacks(def, creature.health / creature.maxHealth)[1]
	end
	return pool[math.random(#pool)]
end

-- WEATHER, FROM DATA. An attack carrying `storm = { mode, duration }` opens
-- a timed window over the boss's OWN arena for as long as the move lasts.
-- Generic on purpose: the next boss that wants weather is a data change, not
-- a code change, and an attack without the field costs nothing.
--
-- Only at the LAIR: a boss fought at its in-place fallback arena has no
-- arena row, and a window nobody can stand in would only be a way to get the
-- fog stuck. FireAllClients is right - the client filters by where the
-- player is standing, exactly as the island blizzard does - and it stamps
-- its own deadline on arrival, so a boss that dies mid-attack (and never
-- reaches the close below) still has its sky clear on time.
local function signalArenaStorm(def, p, active: boolean)
	if not p.storm or not def.islandId or not BossArenas.centerFor(def.islandId) then
		return
	end
	Remotes.WorldEvent:FireAllClients({
		kind = "arenastorm",
		islandId = def.islandId,
		active = active,
		duration = if active then p.storm.duration else nil,
		mode = p.storm.mode,
	})
end

local function beginBossAttack(creature, def, name: string, now: number)
	local p = def.attacks[name]
	creature.attack =
		{ name = name, p = p, phase = "windup", phaseStart = now, phaseUntil = now + p.windup, fired = false }
	creature.lastAttack = name
	-- The lunge's plant is the only punish window a HANDLER owns, and a
	-- handler that is interrupted (a stagger, the collapse) never reaches
	-- its own `finish`. Cleared at every attack's start as well as at the
	-- lunge's end, so a stale `true` can never carry into another move.
	creature.lungeOpen = false
	-- Spent for this stance the moment it BEGINS, not when it finishes: a
	-- set-piece interrupted by the boss's own death or a stagger has still
	-- been shown, and offering it again in the same stance would read as the
	-- fight repeating itself. See `once` in pickBossAttack.
	if p.once == "stance" then
		creature.stanceUsed = creature.stanceUsed or {}
		creature.stanceUsed[name] = true
	end
	setMode(creature, "attack", 0, now)
	-- `p.tell` lets a themed attack borrow a stock telegraph (a renamed bite
	-- still flashes like a snap); `p.skin` colors the client's effects.
	--
	-- `tell = false` opts OUT entirely, for an attack that fires its own,
	-- better-placed telegraph from its handler. The generic one is drawn at
	-- the boss's PIVOT and chosen before the handler picks a target, which
	-- is right for a boss that attacks around itself and wrong for one whose
	-- reach lands far away: Brinejaw's pivot is its head, ~60 studs up a
	-- lighthouse, so a stock tell marks the tower while the tail comes down
	-- somewhere else entirely. Note there is no "silent" tell value - an
	-- unrecognised kind still falls through the client's catch-all flash and
	-- plays the tell sound - so opting out has to be explicit.
	if p.tell ~= false then
		-- WHERE THE TELL IS DRAWN. The pivot is right for a boss that attacks
		-- around itself and wrong for one whose move works the floor from a
		-- centre that is not its head: Rimefang's carousel pulls on
		-- `creature.anchor` and drops its bergs there (ATTACK_HANDLERS.undertow
		-- reads `creature.anchor or creature.pos` in both places), while its
		-- marker was drawn at the nose - so the tell and the damage named two
		-- different circles. `at = "anchor"` puts them on one. (The Kraken's
		-- inkspit has since taken the same field for the same reason - its
		-- pivot is carried 31 studs up inside the mantle.) A row that does not
		-- carry it gets the pivot, to the stud, as before.
		local tellAt = if p.at == "anchor"
			then (creature.anchor or creature.pos)
			else creature.model:GetPivot().Position
		fireEvent("telegraph", tellAt, {
			kind = p.tell or name,
			-- THROUGH the blow, not up to the swing. Most handlers strike the
			-- instant the windup expires, and for those this is exactly
			-- `p.windup` as before. The ones that damage part-way into the
			-- strike are listed in HANDLER_IMPACT, and for them a countdown
			-- that ended at the windup was inviting the player back in - by up
			-- to 1.52 seconds. See the note on that table.
			duration = p.windup + (p.duration or 0) * (HANDLER_IMPACT[p.handler] or 0),
			radius = p.radius,
			-- THE SHAPE OF THE THREAT, not just its size. A radius alone makes
			-- every tell a circle, so a client drawing a wedge or a corridor
			-- had to keep its OWN copy of the row's numbers and hope nobody
			-- retuned the data underneath it. These three bind the truth:
			-- `cone` the wedge's half-angle, `lunge` how far the body carries
			-- through, `width` the corridor's half-width. All three are nil on
			-- the overwhelming majority of attacks and a nil field simply does
			-- not appear in the payload, so nothing else on the wire changes -
			-- and the client keeps its fallbacks for rows that carry none.
			--
			-- MIND THE UNITS if you consume `cone` for a new move: it is
			-- radians on `snap` and `wash` rows and DEGREES on `phantom` ones
			-- (that handler calls `math.rad(p.cone)` itself). Today the only
			-- reader is the wash's wedge, which is keyed on the move name, so
			-- the inconsistency is carried but never acted on.
			cone = p.cone,
			lunge = p.lunge,
			width = p.width,
			facing = bossFacing(creature),
			skin = p.skin,
		})
	end
	-- The sky closes with the TELL, not with the blow: the whole windup
	-- budget is spent watching it come in.
	signalArenaStorm(def, p, true)
end

local function endBossAttack(creature, def, now: number)
	local a = creature.attack
	local rage = if creature.enraged then def.enrageCooldownMult else 1
	creature.cooldowns = creature.cooldowns or {}
	creature.cooldowns[a.name] = now + a.p.cooldown * rage
	signalArenaStorm(def, a.p, false)
	-- A move with `expose = seconds` leaves the creature wide open after its
	-- recover: hits land at the charger's exposed multiplier for the window
	-- (hitModifiers), and the client draws the dazed tell off the attribute.
	if a.p.expose then
		creature.exposedUntil = now + a.p.expose
		-- The attribute is the tell: the client already draws the charger's
		-- dazed sparks off Exposed, so every kitted expose window inherits
		-- that language for free (no boss-roar "exposed" event - too grand).
		creature.model:SetAttribute(ATTR_EXPOSED, true)
	end
	if a.p.follow then
		creature.forcedAttack = a.p.follow
		creature.nextAttackAt = now + 0.15
	else
		creature.nextAttackAt = now + randomBetween(def.attackGapMin, def.attackGapMax) * rage
	end
	-- THE PUNISH WINDOW HAS TO BE REAL. `expose` opens one, and then the
	-- ordinary gap above let the boss start its next move a fraction of the
	-- way into it: Rimefang's breach opens 4.0s and its gap is 0.65-1.25s
	-- (0.36-0.69 enraged), so the whale attacked out of the window it had
	-- just paid for - and because the pose driver only draws `beached` while
	-- no attack is running, the beached body vanished with it. The window is
	-- the fight's ONLY wide kill window; a move that says it leaves the boss
	-- open has to actually leave it open, so the gap runs from the end of the
	-- window rather than from the end of the recover.
	--
	-- OPT-IN, by `holdExpose` on the move, and that is deliberate. This is
	-- shared code: Gnashroot's hammerfall has the identical arithmetic
	-- (expose 3.5 against a 0.7-1.35s gap) and would be re-paced by a blanket
	-- rule, which is a balance change to a fight nobody asked me to retune.
	-- It does not carry the field, so nothing about it changes. Neither do
	-- the three kitted hostile rows that use `expose`.
	if a.p.expose and a.p.holdExpose then
		creature.nextAttackAt = math.max(creature.nextAttackAt, creature.exposedUntil or now)
	end
	creature.attack = nil
	-- A colossus goes back to its perch, not to prowling: it never chases.
	setMode(creature, if def.entrenched then "entrenched" else "prowl", 0, now)
end

local function updateBossAttack(
	creature,
	def,
	now: number,
	dt: number,
	root: BasePart?,
	player: Player?,
	dist: number,
	sub: number
)
	local a = creature.attack
	local p = a.p
	-- An attack's engine behaviour is `p.handler` (so every boss can name its
	-- moves in its own voice - "deathroll", "magmajet" - while sharing the
	-- parameterized primitives); a book entry without one keeps the old rule
	-- that the attack's NAME is the handler (Brinejaw's book).
	local handler = ATTACK_HANDLERS[p.handler or a.name]
	if not handler then
		endBossAttack(creature, def, now)
		return
	end

	if a.phase == "windup" then
		-- Tracks the player through the tell, so dodging means MOVING, not
		-- standing off to one side.
		if root then
			creature.yaw0 =
				approachAngle(creature.yaw0, yawToward(root.Position - creature.pos), def.turnRate * 1.5 * dt)
		end
		local u = math.clamp((now - a.phaseStart) / math.max(p.windup, 1e-3), 0, 1)
		if handler.windup then
			handler.windup(creature, def, p, u, sub)
		else
			creature.model:PivotTo(poseCFrame(creature, sub, 0, 0))
		end
		if now >= a.phaseUntil then
			a.phase = "strike"
			a.phaseStart = now
			a.phaseUntil = now + p.duration
			if handler.fire then
				handler.fire(creature, def, p, now, root, player, dist)
			end
		end
	elseif a.phase == "strike" then
		local u = math.clamp((now - a.phaseStart) / math.max(p.duration, 1e-3), 0, 1)
		if handler.strike then
			handler.strike(creature, def, p, now, dt, u, root, sub)
		else
			creature.model:PivotTo(poseCFrame(creature, sub, 0, 0))
		end
		if now >= a.phaseUntil then
			a.phase = "recover"
			a.phaseStart = now
			a.phaseUntil = now + p.recover
			if handler.finish then
				handler.finish(creature, def, p, now)
			end
		end
	else -- recover: the opening
		local u = math.clamp((now - a.phaseStart) / math.max(p.recover, 1e-3), 0, 1)
		if handler.recover then
			handler.recover(creature, def, p, u, sub)
		else
			creature.model:PivotTo(poseCFrame(creature, sub, 0, 0))
		end
		if now >= a.phaseUntil then
			endBossAttack(creature, def, now)
		end
	end
end

-- ---------------------------------------------------- hostile-scale arsenal (hostile revamp, 2026-08-28)
-- Five primitives sized for ordinary hostiles, joining the boss arsenal in
-- the same table so a kit and a boss book draw from one vocabulary. All
-- fully parameterized - variety comes from the rows, not from new code.

-- Lunge: a tracked hop-leap at the player, cone hit on landing. p: reach
-- (max leap), hop (arc height), cone (half-angle rad; default a 60-deg
-- bite), knockback?, pool? (spawnPool spec at the landing).
ATTACK_HANDLERS.lunge = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub, 0, math.rad(-12) * u))
	end,
	fire = function(creature, _def, p, _now, root)
		local a = creature.attack
		if root then
			local to = Vector3.new(root.Position.X - creature.pos.X, 0, root.Position.Z - creature.pos.Z)
			a.leap = math.min(to.Magnitude, p.reach or 14)
			a.dir = if to.Magnitude > 0.01 then to.Unit else bossFacing(creature)
		else
			a.leap = p.reach or 14
			a.dir = bossFacing(creature)
		end
	end,
	strike = function(creature, def, p, _now, dt, u, _root, sub)
		local a = creature.attack
		creature.pos = resolveHorizontal(creature, a.dir * (a.leap / math.max(p.duration, 1e-3)) * dt)
		local hop = (p.hop or 3) * 4 * u * (1 - u)
		creature.model:PivotTo(poseCFrame(creature, sub + hop, 0, math.rad(18) * (1 - u)))
		if not a.fired and u >= LUNGE_IMPACT then
			a.fired = true
			local lo, hi = bossRoll(creature, def, p.damage)
			damagePlayersInCone(creature.pos, a.dir, p.radius or 6, p.cone or math.rad(60), false, lo, hi, creature)
			if p.pool then
				spawnPool(creature, creature.pos, p.pool, os.clock())
			end
			fireEvent("slam", creature.pos, { radius = p.radius or 6, skin = p.skin })
		end
	end,
}

-- Cone breath: a held jet from the mouth swept over `duration`, ticking
-- damage inside the cone. p: reach, cone (half-angle), tickEvery?, pool?
-- (a hazard line left along the centreline as it ends).
ATTACK_HANDLERS.conebreath = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.5 * u, 0, math.rad(-20) * u))
	end,
	strike = function(creature, def, p, now, dt, u, root, sub)
		local a = creature.attack
		if root then
			-- The jet tracks slowly - walking OUT of the cone is the dodge.
			creature.yaw0 = approachAngle(creature.yaw0, yawToward(root.Position - creature.pos), math.rad(40) * dt)
		end
		creature.model:PivotTo(poseCFrame(creature, sub + 0.5, 0, math.rad(8)))
		if now >= (a.nextTickAt or 0) then
			a.nextTickAt = now + (p.tickEvery or 0.35)
			local lo, hi = bossRoll(creature, def, p.damage)
			local facing = bossFacing(creature)
			damagePlayersInCone(creature.pos, facing, p.reach or 12, p.cone or math.rad(35), false, lo, hi, creature)
			fireEvent("beam", creature.pos + Vector3.new(0, 1.5, 0), {
				to = creature.pos + facing * (p.reach or 12) + Vector3.new(0, 1, 0),
				skin = p.skin,
			})
		end
		if u >= 0.95 and not a.fired and p.pool then
			a.fired = true
			local facing = bossFacing(creature)
			spawnPool(creature, creature.pos + facing * (p.reach or 12) * 0.6, p.pool, now)
		end
	end,
}

-- Ring pulse: an expanding shockwave band swept outward over `duration`
-- (step across or outrun it) - or, with `invert`, one detonation of the
-- annulus [safeRadius, radius] at the end of the strike: the SAFE spot is
-- up close, and the tell says so. p: radius (outer), ringWidth?, safeRadius
-- (invert), invert?.
ATTACK_HANDLERS.ringpulse = {
	windup = function(creature, _def, p, u, sub)
		if u < 0.05 and not creature.attack.tellFired then
			creature.attack.tellFired = true
			if p.invert then
				fireEvent("telegraph", creature.pos, {
					kind = "ringTell",
					duration = p.windup + p.duration,
					inner = p.safeRadius or 6,
					radius = p.radius,
					skin = p.skin,
				})
			end
		end
		creature.model:PivotTo(poseCFrame(creature, sub + 0.9 * u, 0, 0))
	end,
	strike = function(creature, def, p, _now, _dt, u, _root, sub)
		local a = creature.attack
		creature.model:PivotTo(poseCFrame(creature, sub + 0.9 * (1 - u), 0, 0))
		if p.invert then
			if not a.fired and u >= RINGPULSE_IMPACT then
				a.fired = true
				local lo, hi = bossRoll(creature, def, p.damage)
				damagePlayersInAnnulus(creature.pos, p.safeRadius or 6, p.radius, lo, hi, creature)
				fireEvent("pulse", creature.pos, { radius = p.radius, skin = p.skin })
			end
			return
		end
		-- The sweeping band: each player is hit at most once per pulse.
		if not a.fired then
			a.fired = true
			fireEvent("pulse", creature.pos, { radius = p.radius, skin = p.skin })
		end
		local front = p.radius * u
		local band = p.ringWidth or 4
		a.hitPlayers = a.hitPlayers or {}
		local lo, hi = bossRoll(creature, def, p.damage)
		for _, entry in livingRootsNear(creature.pos, front) do
			local d = (Vector3.new(entry.root.Position.X, 0, entry.root.Position.Z) - Vector3.new(
				creature.pos.X,
				0,
				creature.pos.Z
			)).Magnitude
			if d >= front - band and not a.hitPlayers[entry.player] then
				a.hitPlayers[entry.player] = true
				PlayerService.damage(entry.player, math.random(lo, hi), creature, { bypassIframe = true })
			end
		end
	end,
}

-- Mortar: N telegraphed ground marks (queueStrike - the marks land on their
-- own clock, whatever the creature does next). p: count, spread, delay
-- (tell-to-hit), stagger, aim ("player" scatters around the player,
-- "self" around the creature), plus queueStrike riders: shape/inner/outer,
-- snare, chain, pool, hitEvent.
ATTACK_HANDLERS.mortar = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.6 * u, 0, math.rad(-16) * u))
	end,
	fire = function(creature, def, p, now, root)
		local count = p.count or 3
		for i = 1, count do
			local at
			if root and (p.aim or "player") == "player" then
				at = scatterAround(root, p.spread or 7)
			else
				local angle = math.random() * math.pi * 2
				local r = math.sqrt(math.random()) * (p.spread or 10)
				at = groundedPos(creature.pos + Vector3.new(math.cos(angle) * r, 0, math.sin(angle) * r), 0)
			end
			local tellAt = now + (i - 1) * (p.stagger or 0.25)
			queueStrike(creature, def, p, at, tellAt, tellAt + (p.delay or 1.1), {
				shape = p.shape,
				inner = p.inner,
				outer = p.outer,
				snare = p.snare,
				chain = p.chain,
				pool = p.pool,
				hitEvent = p.hitEvent,
			})
		end
	end,
}

-- Gust push: a displacement shove - radial, or a cone with `cone` set. The
-- client moves the character (the `pull` machinery, mirrored outward);
-- optional light damage. p: radius, push (studs/s), lift?, cone?, damage?.
ATTACK_HANDLERS.gustpush = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.7 * u, 0, math.rad(-10) * u))
	end,
	fire = function(creature, def, p, _now)
		local facing = bossFacing(creature)
		fireEvent("gust", creature.pos, {
			radius = p.radius,
			push = p.push or 42,
			lift = p.lift or 0,
			duration = math.max(p.duration, 0.15),
			cone = p.cone,
			facing = if p.cone then facing else nil,
			skin = p.skin,
		})
		if p.damage then
			local lo, hi = bossRoll(creature, def, p.damage)
			if p.cone then
				damagePlayersInCone(creature.pos, facing, p.radius, p.cone, false, lo, hi, creature)
			else
				damagePlayersInRadius(creature.pos, p.radius, lo, hi, creature, 0.7)
			end
		end
	end,
}

-- ---------------------------------------------------------------- rimefang
--
-- The Floe-Breaker's two bespoke moves. Everything else in its book runs on
-- handlers that already exist (snap / charge / slam / undertow / barrage).

-- Mirrors BossArenaService.FOLDER_NAME - the arena furniture lives here, and
-- a wash asks it whether a player is behind cover.
local BOSS_ARENA_FOLDER = "BossArenas"
local washParams: RaycastParams? = nil

-- Anything solid between the boss and a player shelters them from a wash.
-- This is what the arena's bergs and its frozen whaler are FOR: the counter
-- to the wash is position, not timing, and without an occlusion test the
-- furniture is scenery.
local function washSheltered(root: BasePart, from: Vector3): boolean
	local arenas = Workspace:FindFirstChild(BOSS_ARENA_FOLDER)
	if not arenas then
		return false
	end
	if not washParams then
		washParams = RaycastParams.new()
		washParams.FilterType = Enum.RaycastFilterType.Include
	end
	washParams.FilterDescendantsInstances = { arenas }
	local origin = from + Vector3.new(0, 2.5, 0)
	local hit = Workspace:Raycast(origin, root.Position - origin, washParams)
	-- The floor is in the same folder and a ray across a domed floe grazes
	-- it; only standing geometry counts as cover.
	if not hit then
		return false
	end
	local name = hit.Instance.Name
	return not (string.find(name, "_Base", 1, true) or string.find(name, "Floor", 1, true))
end

-- Everyone the crest has reached since the last frame. Backwards, because it
-- removes as it goes; `PlayerService.damage` is already safe for a player who
-- has died or left between the schedule and the arrival (no humanoid, no
-- hit), so there is no second liveness test to keep in step with it.
local function washLand(creature, now: number)
	local a = creature.attack
	local queue = a and a.washHits
	if not queue then
		return
	end
	for i = #queue, 1, -1 do
		local hit = queue[i]
		if now >= hit.at then
			table.remove(queue, i)
			PlayerService.damage(hit.player, hit.amount, creature, { bypassIframe = true })
		end
	end
end

-- THE WAVE WASH. An orca hunting seals on pack ice charges the floe and
-- shoulders a wall of water over it; the seal is not bitten, it is WASHED
-- OFF. So the threat here is displacement, not damage - you are shoved
-- toward the holes and the pressure ridge - and shelter beats it.
ATTACK_HANDLERS.wash = {
	-- NO POSE HOOKS. The whale's body is published as attributes and drawn by
	-- the client (rimefangDrive below), so a pivot here would only move a
	-- model nobody can see. The roll onto its side - the tell, which has to
	-- read from the far side of the arena, because the answer is to move - is
	-- posed from the phase this loop is already in.
	fire = function(creature, def, p, now, root)
		local a = creature.attack
		-- LATCHED ONCE, never per frame. A bearing recomputed each frame
		-- snaps to whoever is nearest, so in a party the wall would jump
		-- across the arena mid-attack and stop being dodgeable.
		a.dir = if root then flatUnit(root.Position - creature.pos) else bossFacing(creature)
		local sheltered = {}
		local lo, hi = bossRoll(creature, def, p.damage)
		-- THE WALL TRAVELS, SO THE DAMAGE TRAVELS WITH IT. Everything below
		-- used to resolve in this one loop, at the instant the windup ended:
		-- a player at the far rim took the hit before the crest had left the
		-- whale's shoulder. No client can make a travelling wall honest
		-- against a one-frame hit, so the scheduling belongs here.
		--
		-- The whole cone is decided NOW and never revisited: who is in the
		-- wedge, who cover saved, and how hard it hits. Only the MOMENT is
		-- deferred. That ordering is the point - re-testing shelter as the
		-- crest arrived would let cover flicker mid-sweep (a player stepping
		-- out from behind a berg after the wall committed would be saved by
		-- geometry the wall had already passed), and the raycast set is one
		-- batch rather than one per frame.
		local reach = math.max(p.radius - (p.sweepFrom or 0), 1e-3)
		a.washHits = {}
		for _, entry in livingRootsNear(creature.pos, p.radius) do
			local to = flatUnit(entry.root.Position - creature.pos)
			if to:Dot(a.dir) >= math.cos(p.cone) then
				if washSheltered(entry.root, creature.pos) then
					table.insert(sheltered, entry.player.UserId)
				else
					-- Where the crest is when it reaches them, inverted: the
					-- client walks its wall out linearly from `sweepFrom` to
					-- `radius` over `sweep` seconds, so this is that same line
					-- solved for time. A move without `sweep` keeps the old
					-- behaviour exactly - every delay is zero.
					local off = entry.root.Position - creature.pos
					local dist = Vector3.new(off.X, 0, off.Z).Magnitude
					local u = math.clamp((dist - (p.sweepFrom or 0)) / reach, 0, 1)
					table.insert(a.washHits, {
						player = entry.player,
						at = now + (p.sweep or 0) * u,
						amount = math.random(lo, hi),
					})
				end
			end
		end
		-- Rides the kit engine's `gust` vocabulary (displacement is the pull
		-- machinery in reverse, client-side) plus one new field: `sheltered`
		-- is the list of players cover saved, and their clients skip the shove.
		fireEvent("gust", creature.pos, {
			radius = p.radius,
			push = p.push or 70,
			duration = math.max(p.duration, 0.2),
			cone = p.cone,
			facing = a.dir,
			skin = p.skin,
			sheltered = sheltered,
		})
		if p.slick then
			spawnPool(creature, groundedPos(creature.pos + a.dir * (p.radius * 0.45), 0), p.slick, now)
		end
		-- Anyone the crest is already on top of is hit on THIS frame, not on
		-- the next one: with `sweep` unset every delay is zero, and a move
		-- that opts out of the travelling wall must land exactly where it
		-- landed before this existed.
		washLand(creature, now)
	end,
	-- The wall arriving, one player at a time, on the schedule `fire` wrote.
	-- The PivotTo is what the attack loop does for a handler with no strike
	-- hook, kept verbatim so adding this hook changes nothing but the timing.
	strike = function(creature, _def, _p, now, _dt, _u, _root, sub)
		washLand(creature, now)
		creature.model:PivotTo(poseCFrame(creature, sub, 0, 0))
	end,
	-- Nobody is dropped if the strike ends early (it cannot today - the sweep
	-- is 0.22s inside a 0.9s strike - but a retune must not silently start
	-- eating hits).
	finish = function(creature)
		washLand(creature, math.huge)
	end,
}

-- THE SPY-HOP. Not an attack: the LOOK. It rises vertically out of the
-- water, half its body clear, and picks someone. Orcas really do this to
-- find prey on a floe, and it earns its slot by being the one beat in the
-- fight where nothing is coming - which is what makes the beats that ARE
-- coming legible. It marks its target, and the mark is who the NEXT move
-- opens on.
ATTACK_HANDLERS.spyhop = {
	-- No pose hooks, for the same reason the wash has none: the stand, the
	-- hold and the slow scan are published (rimefangDrive below), not pivoted.
	fire = function(creature, _def, p, _now, root)
		if root then
			-- LATCHED HERE AND NEVER AGAIN, the way `charge` latches `a.dir`.
			-- The hold turns about the bearing it picked someone on; re-aiming
			-- per frame would swing the head onto whoever is nearest and the
			-- mark would stop meaning anything.
			creature.attack.dir = flatUnit(root.Position - creature.pos)
			fireEvent("telegraph", root.Position, {
				kind = "mark",
				radius = p.radius or 7,
				duration = p.hold or 1.0,
				skin = p.skin,
			})
		end
	end,
}

-- THE FLUKE SLAM. The tail comes up clear of the sheet and hammers down - and
-- it hammers down WHERE THE TAIL IS, 56 studs behind the nose. That is the
-- whole reason this is a handler of its own rather than the shared `slam`:
-- `slam` rings the boss's own position, so on a 56-stud animal it damaged a
-- 24-stud circle at the HEAD while the fluke was drawn most of the arena
-- away. Standing under the raised tail was safe; standing at the nose with no
-- tail in sight took 50-68. And `slam` fires on the FIRST frame of the
-- strike, while the pose only brings the fluke down over the first 30% of it.
--
-- Two things have to be locked for a marker at the tail to be honest, and
-- Brinejaw's `aimSlam` locks exactly the same two for exactly this reason.
-- The BEARING: the shared windup turns the boss toward its target at
-- turnRate * 1.5, which over this move's 0.9s windup is up to 108 degrees -
-- and the body is drawn swinging about the head, so that is up to 108 degrees
-- of TAIL, and a ring placed when the windup starts would be nowhere by the
-- time it ends. Latching `a.dir` on the first windup frame stops the body
-- (`rimefangFace` reads it) and reads as the animal committing. And the
-- MOMENT: the countdown runs through the fall rather than finishing while the
-- tail is still up. The row opts out of the stock tell (`tell = false`) so
-- there is exactly one marker and it is this one.
local RF_FLUKE_IMPACT = 0.3

-- Where the fluke will come down: the last spine sample's ground position.
-- The lobtail is no longer a lift - the tail rears and then HAMMERS, the tip
-- travelling from +11.9 to -14.5 studs through the waterline - but it is a
-- rotation of the peduncle about a fixed heading, so the tip's FOOTPRINT
-- barely moves: the resting tip measures 1.20 studs from the true hammer
-- point, well inside this move's 24-stud radius. Reading the rest pose is
-- therefore both correct and the only thing available at windup start, which
-- is when the marker has to be placed.
local function flukeGround(creature): Vector3
	local body = rimefangBody(creature)
	local at = if body then body[#body].pos else creature.pos
	return groundedPos(Vector3.new(at.X, creature.pos.Y, at.Z), 0)
end

ATTACK_HANDLERS.flukeslam = {
	-- No pose hooks: the whale is published as attributes and drawn by the
	-- client, so a PivotTo here would only move a model nobody can see.
	windup = function(creature, _def, p, _u, _sub)
		local a = creature.attack
		if a.aimed then
			return
		end
		a.aimed = true
		a.dir = bossFacing(creature)
		a.impact = flukeGround(creature)
		fireEvent("telegraph", a.impact, {
			kind = p.tellKind or "burst",
			duration = p.windup + (p.duration or 0) * RF_FLUKE_IMPACT,
			radius = p.radius,
			facing = a.dir,
			skin = p.skin,
		})
	end,
	strike = function(creature, def, p, _now, _dt, u, _root, _sub)
		local a = creature.attack
		if a.fired or u < RF_FLUKE_IMPACT then
			return
		end
		a.fired = true
		local at = a.impact or flukeGround(creature)
		local lo, hi = bossRoll(creature, def, p.damage)
		damagePlayersInRadius(at, p.radius, lo, hi, creature, 0.5, BOSS_HEIGHT_TOLERANCE)
		fireEvent("slam", at, { radius = p.radius, skin = p.skin })
	end,
}

-- ---------------------------------------------------------- rimefang's body
--
-- THE WHALE IS DRAWN CLIENT-SIDE. RimefangBodyController lays ~16 vertebrae
-- along the curve RimefangPath describes, off pose ATTRIBUTES this server
-- publishes on the boss Model. Authority does not move: creature.pos is
-- still the head, and the damage, timing, latching and shelter tests above
-- are untouched - the only thing that changed is that the pose is PUBLISHED
-- rather than performed with PivotTo.
--
-- WHY A DRIVER RATHER THAN POSE CODE IN THE HANDLERS. Five of Rimefang's
-- seven moves run on handlers other bosses share (snap / charge / slam /
-- undertow / barrage), and nothing boss-specific may go inside them. So this
-- reads what those handlers ALREADY publish on `creature.attack` - the
-- move's name, its phase, the phase clock, and the aim they latch in
-- `a.dir` - and translates that into the pose vocabulary from outside. It
-- hangs off ARCHETYPE_UPDATERS.boss, runs after the shared boss frame
-- whatever branch that frame took (rising, an attack, the beached window,
-- prowling), and returns on its first line for any creature whose row is not
-- Rimefang's. No other boss can reach a line of it.

local RIMEFANG_BOSS = "rimefang"
-- Mirrors ATTR_POSE / ATTR_POSE_CENTER, which are declared with the colossus
-- driver further down this file and so are not in scope here. Same two names,
-- because they are the same contract: `Pose` is what makes the client adopt
-- the model, `PoseCenter` is where the body is drawn from.
local RF_ATTR_POSE = "Pose"
local RF_ATTR_CENTER = "PoseCenter"

-- The prowl's breath cycle: how long it runs under the sheet, and how long
-- it lies up top before it goes back down.
local RF_DIVE_HOLD = 3.6
local RF_SURFACE_HOLD = 4.2
-- Not a full `submerge`: it hunts under the sheet, it does not leave, and
-- the thing you are shooting at has to stay findable between attacks.
local RF_DIVE_DEPTH = 0.6

-- An attribute is a replicated write, so a pose number is only sent when it
-- has actually moved. (Same reasoning as the choir's ChoirDown, which is
-- published on change for the same reason.)
local RF_EPSILON = 0.004

local function rfPut(model: Model, cache, attr: string, value: number)
	-- A NaN reaching the cache would latch this channel off for the life of
	-- the creature: every later `math.abs(value - NaN) > eps` is false, so the
	-- attribute is never written again and the client freezes on a stale
	-- value with no error anywhere.
	if value ~= value then
		return
	end
	local last = cache[attr]
	if last == nil or math.abs(value - last) > RF_EPSILON then
		cache[attr] = value
		model:SetAttribute(attr, value)
	end
end

-- The pose state, and the one-time handshake with the client.
local function rimefangState(creature)
	local state = creature.rimefangPose
	if state then
		return state
	end
	state = RimefangPath.newState(creature.anchor or creature.pos)
	state.faceAngle = creature.yaw0 or 0
	creature.rimefangPose = state
	creature.rimefangWrote = {}
	-- The whole visible whale belongs to the client; the server's model is
	-- authority only (hits and the HUD read its parts), so it shows nothing
	-- or the head would be drawn twice. Same rule every colossus follows.
	for _, descendant in creature.model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Transparency = 1
			descendant.CastShadow = false
		elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
			descendant.Transparency = 1
		end
	end
	-- Centre BEFORE kind: `Pose` is the signal the controller adopts on, and
	-- it reads `PoseCenter` in the same breath.
	creature.model:SetAttribute(RF_ATTR_CENTER, state.center)
	creature.model:SetAttribute(RF_ATTR_POSE, RIMEFANG_BOSS)
	return state
end

-- WHERE THE BODY IS DRAWN FROM, so that the head lands on the server's own
-- authority point every frame. Only the breach moves the head away from the
-- centre horizontally (`arch` walks it along the leap's parabola), so rather
-- than duplicating that parabola's constants here, the offset is asked of
-- the path itself: pose the shape about the origin and see where t = 0 came
-- out. The vertical is deliberately NOT cancelled - the leap's height, the
-- spy-hop's stand and the dive's depth ARE the pose.
local function rimefangCenter(state, at: Vector3): Vector3
	local keep = state.center
	state.center = Vector3.zero
	local head = RimefangPath.pointAt(state, 0)
	state.center = keep
	return at - Vector3.new(head.X, 0, head.Z)
end

-- ---------------------------------------------------------- rimefang's hide
--
-- WHAT YOU CAN SEE IS WHAT YOU CAN HIT. Every other creature in the game is a
-- ball around its pivot, and for a fish, a crab, or even a colossus standing
-- on its own centre that is close enough. Rimefang is 56 studs of animal laid
-- out BEHIND its authority point - `creature.pos` is the nose - so the pivot
-- sphere capped melee at hitRadius (6.7) plus the longest reach in Weapons
-- (16), about 22.7 studs from the head, and made everything from the shoulder
-- aft into scenery: visible, solid-looking and unswingable, the beached body
-- during the punish window included.
--
-- WHY SAMPLES AND NOT A `parts` RING. spawnBossParts is the other way to give
-- a boss more than one place to be hit, and it is the wrong tool here. A
-- `parts` row is a CREATURE - its own health, its own death, a socket index,
-- and a `vulnerableWhen = "partsDown"` gate on the parent - which is the
-- machinery of a fight ABOUT destroying limbs (the Kraken's arms, Wrack's
-- batteries). Rimefang has one health bar, one body, and a body that MOVES:
-- the carousel swings the tail through a 56-stud circle and the breach throws
-- the whole animal through the air. Sixteen entities chasing a pose that is
-- already computed exactly - and identically - on both sides from
-- RimefangPath would be sixteen replicated things to keep in step with the
-- drawing, in exchange for an answer the path hands over directly. So the
-- hide IS the spine, sampled: the same curve the client lays its vertebrae
-- on, tested where a pivot sphere used to be.
--
-- HOW MANY, and it is arithmetic rather than taste: consecutive spheres have
-- to OVERLAP or the chain has a band you cannot hit. Spacing is uniform now -
-- the path integrates its angles down the body, so arc length is exactly
-- BODY_LENGTH in every pose and the samples cannot stretch apart during a
-- breach the way they used to. At 9 samples the spacing is 56/8 = 7.0 studs,
-- and the last pair is the peduncle's: girth has bottomed out on the floor
-- below, so 3.0 + 3.0 = 6.0 against 7.0 left a ~0.9-stud dead band right at
-- the tail. At 11 the spacing is 56/10 = 5.6, and 6.0 > 5.6 closes it - with
-- every pair forward of there wider still, because girth is only rising.
--
-- Raising RF_MIN_RADIUS to 3.6 would have closed the same gap and is the
-- wrong fix: the fluke's drawn half-width is 6.6 * girth(1) = 1.45, so 3.0 is
-- already twice the hide and 3.6 would be swinging at open water. Sampling
-- finer keeps every radius honest to the body and costs two more `pointAt`
-- calls per test.
local RF_HIT_SAMPLES = 11
-- The pack's authored half-width at full girth (the row's note on `hitRadius`
-- measures the drawn whale at ~6.6 half-width, 7.2 half-height), and a floor
-- under the peduncle's pinch: `RimefangPath.girth` bottoms out at 0.22, which
-- would leave the fluke a 1.5-stud target you could not reliably swing at.
local RF_HALF_WIDTH = 6.6
local RF_MIN_RADIUS = 3.0

-- The spine, sampled, as capture spheres - or nil for anything that is not
-- Rimefang, which is what keeps every other creature on the pivot sphere it
-- has always had. Guarded on `creature.row.boss` exactly as `rimefangDrive`
-- is, and on the pose state as well: before the first drive frame (and all
-- through `rising`) there is no body yet, and the caller falls back.
--
-- The nodes are allocated once per creature and refilled in place - this is
-- called per swing and per shot, and a fresh table of nine per call would be
-- churn for nothing.
function rimefangBody(creature)
	if creature.row.boss ~= RIMEFANG_BOSS then
		return nil
	end
	local state = creature.rimefangPose
	if not state then
		return nil
	end
	local nodes = creature.rimefangHitNodes
	if not nodes then
		nodes = table.create(RF_HIT_SAMPLES)
		for i = 1, RF_HIT_SAMPLES do
			nodes[i] = { pos = Vector3.zero, radius = 0, t = (i - 1) / (RF_HIT_SAMPLES - 1) }
		end
		creature.rimefangHitNodes = nodes
	end
	for _, node in nodes do
		node.pos = RimefangPath.pointAt(state, node.t)
		node.radius = math.max(RF_HALF_WIDTH * RimefangPath.girth(node.t), RF_MIN_RADIUS)
	end
	return nodes
end

-- Aim, LATCHED. `charge` stamps the bearing it fired on into `a.dir` and
-- never looks again; the wash and the spy-hop below do the same. Reading the
-- nearest player's bearing per frame instead would swing the body onto
-- whoever is closest mid-attack, and the move would stop being dodgeable in
-- a party. Before the strike there is no latch yet, and the boss's own yaw -
-- which the shared loop turns at `turnRate` through the windup - is the
-- tell.
local function rimefangFace(creature, a): number
	return if a.dir then yawToward(a.dir) else creature.yaw0
end

-- move name -> the pose it wants, per phase. `pose` is a scratch table
-- already filled with the cruise pose, so each of these only writes what it
-- changes. Windup is the tell, strike is the blow, recover is the opening -
-- the same three beats the shared loop is already counting.
local RF_MOVES = {}

-- Lunge out, jaws open, and shut them on the frame the hit lands: `snap`
-- deals its damage at u >= 0.4, so that is where the mouth closes.
RF_MOVES.bite = function(pose, phase, u, _now)
	pose.swim = 1
	if phase == "windup" then
		local e = smoothstep(u)
		pose.gape = 0.55 * e
		pose.lunge = 0.2 * e
	elseif phase == "strike" then
		pose.lunge = math.min(u / 0.4, 1)
		pose.gape = if u < 0.4 then 1 else math.max(1 - (u - 0.4) / 0.22, 0)
	else
		pose.lunge = 1 - smoothstep(u)
	end
end

-- It stands on its tail and LOOKS at you. The slow turn through the hold is
-- the whole point of the beat - it is picking someone - and it turns about
-- the bearing it latched, not toward whoever is nearest now.
RF_MOVES.spyhop = function(pose, phase, u, now)
	pose.swim = 0.3
	if phase == "windup" then
		pose.rise = smoothstep(u)
	elseif phase == "strike" then
		pose.rise = 1
		pose.face += math.sin(now * 1.1) * math.rad(14)
	else
		pose.rise = 1 - smoothstep(u)
	end
end

-- THE BREACH. It gathers under the surface, leaves the water, and comes down
-- on the floe. `arch` is PROGRESS along the leap rather than a weight, so
-- the drawn body follows the head through the air on the same clock the
-- charge travels on. The landing hands over to `beached`, which the expose
-- window below holds up for as long as the fight leaves it alone.
RF_MOVES.breach = function(pose, phase, u, _now)
	if phase == "windup" then
		pose.swim = 1
		pose.submerge = 0.7 * smoothstep(u)
	elseif phase == "strike" then
		pose.swim = 1
		pose.arch = u
	else
		pose.swim = 0.2
		pose.beached = smoothstep(math.min(u * 2.2, 1))
		-- Once it is flat on the ice the leap is fully overridden, so the
		-- arch can be dropped without anything moving; dropping it earlier
		-- would whip the body back down its own parabola.
		-- Ramp arch DOWN as beached comes up, rather than dropping it the frame
		-- the server's own beached crosses a threshold. The client eases the two
		-- at different rates (18/s vs 4/s), so a hard drop rewound the head down
		-- its own parabola while the body was only half overridden - a 12-stud
		-- jump in one frame on every landing.
		pose.arch = math.max(0, 1 - pose.beached)
	end
end

-- THE WAVE WASH. Hard over onto its side, shoulder down, and sweep. The roll
-- IS the tell, and it has to read from the far side of the arena, because
-- the answer to this move is to move.
RF_MOVES.wash = function(pose, phase, u, _now)
	local hard = math.rad(-74)
	pose.swim = 1
	if phase == "windup" then
		pose.roll = hard * smoothstep(u)
		pose.submerge = 0.12
	elseif phase == "strike" then
		pose.roll = hard
	else
		pose.roll = hard * (1 - smoothstep(u))
	end
end

-- The tail comes up clear of the water and hammers down. The fall and the
-- blow read the SAME constant (RF_FLUKE_IMPACT, with the handler): the ring
-- lands on the frame the fluke reaches the ice, and the marker's countdown
-- runs to that frame too.
RF_MOVES.flukeslam = function(pose, phase, u, _now)
	if phase == "windup" then
		pose.swim = 0.3
		pose.submerge = 0.55 * smoothstep(u)
		pose.flukeUp = smoothstep(u)
	elseif phase == "strike" then
		pose.swim = 1
		pose.submerge = 0.55
		pose.flukeUp = math.max(1 - u / RF_FLUKE_IMPACT, 0)
	else
		pose.swim = 0.8
		pose.submerge = 0.55 * (1 - smoothstep(u))
	end
end

-- Orcas ring a bait ball and drive it inward: a bank held for the whole
-- move, and a heading that keeps coming round. The turn is published as a
-- bearing that grows past a full circle - the client eases along the
-- shortest arc, so 2pi of it costs nothing and never snaps back.
RF_MOVES.carousel = function(pose, phase, u, _now)
	local bank = math.rad(34)
	pose.swim = 1
	if phase == "windup" then
		pose.roll = bank * smoothstep(u)
		pose.face += math.rad(40) * u
	elseif phase == "strike" then
		pose.roll = bank
		pose.face += math.rad(40) + u * math.pi * 2
	else
		pose.roll = bank * (1 - smoothstep(u))
		pose.face += math.rad(40)
	end
end

-- It rears out of the water and CALLS, and the storm answers. Partial rise,
-- and a jaw working through the call.
RF_MOVES.whiteout = function(pose, phase, u, now)
	if phase == "windup" then
		local e = smoothstep(u)
		pose.swim = 0.6
		pose.rise = 0.5 * e
		pose.gape = 0.55 * e
	elseif phase == "strike" then
		pose.swim = 0.5
		pose.rise = 0.5
		pose.gape = 0.55 + 0.35 * math.abs(math.sin(now * 5.5))
	else
		local e = 1 - smoothstep(u)
		pose.rise = 0.5 * e
		pose.gape = 0.55 * e
	end
end

-- How far through the phase the shared attack loop is, on that loop's own
-- clock, so the pose and the damage can never be reading different times.
local function rimefangPhaseProgress(a, p, now: number): number
	local span = if a.phase == "windup" then p.windup elseif a.phase == "strike" then p.duration else p.recover
	return math.clamp((now - a.phaseStart) / math.max(span or 0, 1e-3), 0, 1)
end

-- THE AMBIENT PROWL: a swim cycle that works as hard as the animal is
-- actually moving, a breath cycle that takes it under the sheet and brings
-- it back up to blow, and a bank into its own turns.
local function rimefangAmbient(creature, def, pose, state, now: number, dt: number)
	-- The tail's effort, from the distance the boss covered this frame -
	-- free, and it can never disagree with where the fight actually put it.
	local moved = (creature.pos - (state.lastPos or creature.pos)).Magnitude / math.max(dt, 1e-3)
	pose.swim = math.clamp(0.45 + moved / math.max(def.speed or 8, 1) * 0.55, 0.35, 1)

	if creature.rimefangBreathUntil == nil then
		creature.rimefangBreathUntil = now + RF_SURFACE_HOLD
		creature.rimefangDown = false
	end
	if now >= creature.rimefangBreathUntil then
		creature.rimefangDown = not creature.rimefangDown
		creature.rimefangBreathUntil = now + (if creature.rimefangDown then RF_DIVE_HOLD else RF_SURFACE_HOLD)
		if creature.rimefangDown then
			-- THE BLOW, then it slips under. Borrowed vocabulary, the way the
			-- wash rides `gust`: `bossDive` is already a plume of spray at
			-- the waterline, which is exactly what a blowhole looks like.
			fireEvent("bossDive", creature.pos, {})
		end
	end
	pose.submerge = if creature.rimefangDown then RF_DIVE_DEPTH else 0

	-- A BANK INTO THE TURN: a whale rolls its shoulders through a heading
	-- change. Prowl only - an attack that wants a roll says so itself, and
	-- adding this on top would fight the wash's shoulder-down and the
	-- carousel's held bank. Smoothed, because the yaw is already rate-limited
	-- and the raw per-frame delta is noise.
	local turn = angleDelta(state.faceAngle or pose.face, pose.face) / math.max(dt, 1e-3)
	local want = math.clamp(-turn * 0.22, -0.38, 0.38)
	state.bank = (state.bank or 0) + (want - (state.bank or 0)) * math.clamp(dt * 3, 0, 1)
	pose.roll += state.bank
end

-- One frame of Rimefang's body. Everything above the publish is a target;
-- the controller eases toward it (RimefangBodyController.EASE), so these are
-- step values rather than animation curves - except `arch`, which is leap
-- progress and tracks nearly rigidly on both sides.
local function rimefangDrive(creature, now: number, dt: number)
	if creature.row.boss ~= RIMEFANG_BOSS or creature.dead or not creature.model.Parent then
		return
	end
	local def = bossDef(creature)
	if not def then
		return
	end
	local state = rimefangState(creature)
	-- The swim cycle and the beached thrash are computed on BOTH sides from
	-- this, and two machines' clocks share no epoch.
	state.time = Workspace:GetServerTimeNow()

	local pose = creature.rimefangScratch
	if not pose then
		pose = {}
		creature.rimefangScratch = pose
	end
	-- The cruise pose, which every branch below is a departure from.
	pose.swim, pose.submerge, pose.rise, pose.roll = 0.6, 0, 0, 0
	pose.arch, pose.beached, pose.flukeUp, pose.gape, pose.lunge = 0, 0, 0, 0, 0
	pose.face = creature.yaw0

	local attack = creature.attack
	if creature.mode == "rising" then
		-- It comes up out of the deep. The model is hidden, so "rising" is a
		-- number the client draws rather than a pivot the server performs.
		pose.submerge = 1 - modeProgress(creature, now)
		pose.swim = 1
		creature.rimefangBreathUntil = nil
	elseif attack then
		pose.face = rimefangFace(creature, attack)
		local move = RF_MOVES[attack.name]
		if move then
			move(pose, attack.phase, rimefangPhaseProgress(attack, attack.p, now), now)
		end
		-- The prowl's breath restarts once the move is over: it comes up and
		-- blows after a fight beat, not halfway through one.
		creature.rimefangBreathUntil = nil
	elseif creature.lastAttack == "breach" and creature.exposedUntil and now < creature.exposedUntil then
		-- THE PUNISH WINDOW, and it is the DATA's window: `breach` carries
		-- `expose = 4`, endBossAttack opens it (after stamping the cooldown),
		-- and this only draws what that window already means. Nothing here
		-- decides how long it lasts.
		local left = creature.exposedUntil - now
		pose.beached = if left < 0.7 then smoothstep(left / 0.7) else 1
		pose.swim = 0.25
		creature.rimefangBreathUntil = nil
	else
		rimefangAmbient(creature, def, pose, state, now, dt)
	end

	state.swim, state.submerge, state.rise, state.roll = pose.swim, pose.submerge, pose.rise, pose.roll
	state.arch, state.beached, state.flukeUp = pose.arch, pose.beached, pose.flukeUp
	state.gape, state.lunge, state.faceAngle = pose.gape, pose.lunge, pose.face
	state.lastPos = creature.pos

	local model, cache = creature.model, creature.rimefangWrote
	rfPut(model, cache, "Swim", state.swim)
	rfPut(model, cache, "Submerge", state.submerge)
	rfPut(model, cache, "Rise", state.rise)
	rfPut(model, cache, "Roll", state.roll)
	rfPut(model, cache, "Arch", state.arch)
	rfPut(model, cache, "Beached", state.beached)
	rfPut(model, cache, "FlukeUp", state.flukeUp)
	rfPut(model, cache, "FaceAngle", state.faceAngle)
	rfPut(model, cache, "Gape", state.gape)
	rfPut(model, cache, "Lunge", state.lunge)
	-- THE PUNISH WINDOW PUBLISHES ITS OWN DEADLINE, in server time, because
	-- ATTR_EXPOSED cannot be trusted here: endBossAttack sets it, but its only
	-- expiry lives in updateKitted, which a plain `archetype = "boss"` never
	-- runs. For this boss it latches true at the first breach and stays true -
	-- so the client's gold clock, thrash audio and slush puffs ran for the
	-- REST OF THE FIGHT, and no later breach could reopen the cue. A deadline
	-- cannot latch; it simply passes.
	local openAt = creature.exposedUntil
	rfPut(
		model,
		cache,
		"OpenUntil",
		if openAt and openAt > now then Workspace:GetServerTimeNow() + (openAt - now) else 0
	)
	local center = rimefangCenter(state, creature.pos)
	if (center - state.center).Magnitude > 0.05 then
		state.center = center
		model:SetAttribute(RF_ATTR_CENTER, center)
	end
end

-- ============================================================ per-row move kits (hostile revamp, 2026-08-28)
--
-- The boss attack book, scaled down to ordinary hostiles: a creature row may
-- carry `moves` (Creatures.luau - the boss attack vocabulary minus phases:
-- windup/duration/recover/cooldown/damage/radius/tell/skin per move, plus
-- `below` for HP-gated moves, `follow` for combos, `weight` for the pick,
-- `range` to hold a move until the player is close enough) and `gimmick`
-- (the quirk registry below). A row WITHOUT `moves` behaves exactly as
-- before - the whole revamp lands island-by-island with no flag day.
--
-- The attack loop is the BOSS loop: begin/update/endBossAttack already read
-- only `def.attacks / turnRate / attackGapMin/Max / enrageCooldownMult` (and
-- handlers read `enrageDamageMult` via bossRoll, `riseDepth`/`aggro` for
-- dive-style moves; clampToArena no-ops without `creature.anchor`) - so a
-- kitted creature just feeds those functions a `book` built from its row
-- instead of a Bosses entry. Between moves it walks with `updateProwl`
-- below - or, when a row names `movement = "<archetype>"`, that archetype's
-- full updater (opt-in: the archetype's own built-in attack then runs AS
-- part of the kit).

-- Pacing/contact defaults per rarity live in Creatures.KIT_DEFAULTS so the
-- content rows and their defaults sit in one file.

-- The book the shared attack loop needs, built once per creature and cached.
-- `enrage*` fields start neutral; the `frenzy` gimmick mutates them live.
local function kitBook(creature)
	local book = creature.kitBook
	if book then
		return book
	end
	local row = creature.row
	local defaults = Creatures.KIT_DEFAULTS[row.rarity] or Creatures.KIT_DEFAULTS.Common
	local attacks = {}
	for _, move in row.moves do
		attacks[move.name] = move
	end
	book = {
		attacks = attacks,
		moves = row.moves,
		turnRate = math.rad((row.tuning and row.tuning.TURN_RATE_DEG) or 200),
		attackGapMin = (row.attackGap and row.attackGap[1]) or defaults.gapMin,
		attackGapMax = (row.attackGap and row.attackGap[2]) or defaults.gapMax,
		enrageCooldownMult = 1,
		enrageDamageMult = 1,
		-- Dive/phantom-style handlers read these; sane ground-hostile values.
		riseDepth = 6,
		aggro = C.RUSH_AGGRO_RANGE,
	}
	creature.kitBook = book
	return book
end

-- Pick the next move: honor a forced follow, then weighted-pick among moves
-- that are off cooldown, whose `below` HP gate passes, and whose `range`
-- covers the player. Returns nil when nothing qualifies (keep walking).
local function pickKitMove(creature, book, now: number, dist: number): string?
	if creature.forcedAttack then
		local forced = creature.forcedAttack
		creature.forcedAttack = nil
		return forced
	end
	local hpFraction = creature.health / creature.maxHealth
	local pool, total = {}, 0
	for _, move in book.moves do
		local readyAt = creature.cooldowns and creature.cooldowns[move.name] or 0
		if
			now >= readyAt
			and hpFraction <= (move.below or 1)
			and dist <= (move.range or C.RUSH_AGGRO_RANGE)
			and (move.name ~= creature.lastAttack or #book.moves == 1)
		then
			-- weight 0 = follow-only: reachable through another move's
			-- `follow`, never picked on its own.
			local weight = move.weight or 1
			if weight > 0 then
				total += weight
				table.insert(pool, { name = move.name, weight = weight })
			end
		end
	end
	if total <= 0 then
		return nil
	end
	local roll = math.random() * total
	for _, entry in pool do
		roll -= entry.weight
		if roll <= 0 then
			return entry.name
		end
	end
	return pool[#pool].name
end

-- The default kitted locomotion: face the nearest player, close to standoff,
-- breathe. ~The prowl half of the boss loop at ground level. Idles as a
-- resting catch when nobody is near.
local function updateProwl(creature, now: number, dt: number)
	slideKnockback(creature, dt)
	local root, _, dist = nearestPlayerRoot(creature.pos)
	if not root or dist > tune(creature, "RUSH_AGGRO_RANGE") then
		local hop, yaw, pitch = flop(creature, now)
		creature.model:PivotTo(poseCFrame(creature, hop, yaw, pitch))
		return
	end
	creature.yaw0 = approachAngle(creature.yaw0, yawToward(root.Position - creature.pos), math.rad(220) * dt)
	local standoff = (creature.row.tuning and creature.row.tuning.STANDOFF) or 8
	local delta = Vector3.new(root.Position.X - creature.pos.X, 0, root.Position.Z - creature.pos.Z)
	if delta.Magnitude > standoff then
		creature.pos = resolveHorizontal(creature, delta.Unit * tune(creature, "SHAMBLE_SPEED") * dt)
	end
	local breathe = math.sin(now * 2.1) * 0.12
	creature.model:PivotTo(poseCFrame(creature, math.max(0, breathe), 0, 0))
end

-- The kitted updater: attack in flight -> drive the shared loop; otherwise
-- walk (prowl, or the row's named `movement` archetype) and consider a pick.
local function updateKitted(creature, now: number, dt: number)
	local book = kitBook(creature)

	-- A phasey blink-out returns here (gimmick registry below).
	if creature.phaseyUntil then
		if now < creature.phaseyUntil then
			return -- hidden: no pose, no pick
		end
		creature.phaseyUntil = nil
		creature.untargetable = false
		fireEvent("phantomIn", creature.pos, {})
	end

	-- An expose window (move `expose` field) closing.
	if creature.exposedUntil and now >= creature.exposedUntil then
		creature.exposedUntil = nil
		creature.model:SetAttribute(ATTR_EXPOSED, false)
	end

	local root, player, dist = nearestPlayerRoot(creature.pos)

	if creature.attack then
		updateBossAttack(creature, book, now, dt, root, player, dist, 0)
		return
	end

	local movement = creature.row.movement
	local walker = (movement and ARCHETYPE_UPDATERS[movement]) or updateProwl
	walker(creature, now, dt)

	if root and now >= (creature.nextAttackAt or 0) then
		local name = pickKitMove(creature, book, now, dist)
		if name then
			beginBossAttack(creature, book, name, now)
		end
	end
end

-- ============================================================ gimmicks (the quirk layer)
--
-- Small passive/reactive behaviours a row opts into via `gimmick = { kind,
-- ... }`. Each hook is consulted from exactly one engine point:
--   onDamage(creature, amount, now)  -> modified amount   (damage(), pre-HP)
--   onHit(creature)                  -> mult, reflect     (hitModifiers())
--   onContact(creature, dealt)                            (tryContact(), after a landed ram)
--   onKill(creature)                                      (kill(), before Killed fires)
local GIMMICKS = {}

-- Armoured while telegraphing: hits during a windup do a fraction, so
-- panic-swinging into a tell is punished and the recover window is the
-- reward. { kind = "harden", mult = 0.35? }
GIMMICKS.harden = {
	onDamage = function(creature, amount)
		if creature.attack and creature.attack.phase == "windup" then
			return amount * (creature.row.gimmick.mult or 0.35)
		end
		return amount
	end,
}

-- Ignites below a health fraction: Enraged attr, faster cooldowns, harder
-- hits (mutates the cached book). { kind = "frenzy", below = 0.4?, cooldownMult
-- = 0.65?, damageMult = 1.25? }
GIMMICKS.frenzy = {
	onDamage = function(creature, amount)
		local g = creature.row.gimmick
		if not creature.enraged and (creature.health - amount) / creature.maxHealth <= (g.below or 0.4) then
			creature.enraged = true
			creature.model:SetAttribute(ATTR_ENRAGED, true)
			local book = creature.kitBook
			if book then
				book.enrageCooldownMult = g.cooldownMult or 0.65
				book.enrageDamageMult = g.damageMult or 1.25
			end
			fireEvent("enrage", creature.pos, {})
		end
		return amount
	end,
}

-- Blinks out after every N hits: briefly untargetable, reappears offset.
-- { kind = "phasey", hits = 3?, gap = 0.7?, hop = 9? }
GIMMICKS.phasey = {
	onDamage = function(creature, amount, now)
		local g = creature.row.gimmick
		creature.phaseyHits = (creature.phaseyHits or 0) + 1
		if creature.phaseyHits >= (g.hits or 3) and not creature.phaseyUntil and creature.health - amount > 0 then
			creature.phaseyHits = 0
			creature.phaseyUntil = now + (g.gap or 0.7)
			creature.untargetable = true
			creature.attack = nil
			fireEvent("phantomOut", creature.pos, {})
			local angle = math.random() * math.pi * 2
			local hop = Vector3.new(math.cos(angle), 0, math.sin(angle)) * (g.hop or 9)
			creature.pos = groundedPos(creature.pos + hop, creature.halfThickness)
		end
		return amount
	end,
}

-- Thorns, front-agnostic: melee reflect. { kind = "spines", reflect = n }
GIMMICKS.spines = {
	onHit = function(creature)
		return 1, creature.row.gimmick.reflect or C.THORN_REFLECT
	end,
}

-- Statically charged: every melee hit shocks the attacker a little.
-- { kind = "static", shock = n? }
GIMMICKS.static = {
	onHit = function(creature)
		return 1, creature.row.gimmick.shock or math.floor(C.PULSE_SHOCK_DAMAGE * 0.5)
	end,
}

-- Comedy physics: knockback sends it flying. { kind = "slippery", mult = 2? }
-- (Consulted in applyKnockback, not via a hook - one line there.)
GIMMICKS.slippery = {}

-- Heals a fraction of the contact damage it deals. { kind = "leech", frac = 0.5? }
GIMMICKS.leech = {
	onContact = function(creature, dealt)
		local g = creature.row.gimmick
		creature.health = math.min(creature.maxHealth, creature.health + math.ceil(dealt * (g.frac or 0.5)))
		creature.model:SetAttribute(ATTR_HEALTH, creature.health)
	end,
}

-- Detonates on death. { kind = "deathburst", radius = 9?, damage = {lo,hi}? }
GIMMICKS.deathburst = {
	onKill = function(creature)
		local g = creature.row.gimmick
		local radius = g.radius or 9
		local range = g.damage or { 8, 14 }
		damagePlayersInRadius(creature.pos, radius, range[1], range[2], creature, 0.6)
		fireEvent("explode", creature.pos, { radius = radius })
	end,
}

function gimmickOf(creature)
	local g = creature.row.gimmick
	return g and GIMMICKS[g.kind]
end

-- The Kraken's tentacle ring (Bosses entry `parts`): `count` copies of
-- `parts.row` planted evenly on a `ring`-stud circle around the arena
-- centre. Each is an ordinary creature struct with `partOf` back at the
-- boss - noLinger (its owner is the fight), suppressed materials, a token
-- bounty - and the ring is what gates the head: damage() refuses a
-- `vulnerableWhen = "partsDown"` boss while partsAlive > 0, kill() counts
-- the ring down, and the regrow clock below re-plants it.
-- ============================================================ colossus bosses (2026-08-29)
--
-- A COLOSSUS holds a perch instead of chasing: `entrenched = true` in its
-- Bosses row. It never walks, its appendages do the attacking, and it cannot
-- be hurt at all until the players EARN a stagger - the punish window a
-- handler opens with openStagger(). The loop the redesign is built on:
-- survive a pattern, earn the opening, spend it.
--
-- Three pieces are generic, so the other colossi (Wrack's beached flagship,
-- the Kraken's arms) get them for free:
--   * entrenched  - hold the perch, face the nearest player, attack from it.
--   * stances     - how many times its stance shifts over the fight. The
--                   engine derives the current one from the health phase and
--                   publishes it; what a stance MEANS is the boss's fiction
--                   (Brinejaw drops a coil, Wrack hauls itself forward).
--   * stagger     - the punish window: targetable, Exposed, then back up.
-- What stays per-boss is the SHAPE its body takes, which lives in its own
-- path module (Shared/Modules/BrinejawPath) and is selected by `def.pose`.

local ATTR_STANCE = "Stance" -- 1 = final stance; counts DOWN as it loses ground
-- How many it STARTED with, published once. Without it a client can only take
-- the first Stance it sees as the maximum, which is right for anyone present
-- at the summon and wrong for everyone who joins after: a boss two stances
-- down draws to a latecomer as an undamaged one.
local ATTR_STANCES = "Stances"
local ATTR_POSE = "Pose" -- which path module draws this body, for the client
local ATTR_POSE_CENTER = "PoseCenter" -- the perch's anchor (the tower's foot)
-- Brinejaw's replicated pose. The client draws its entire body from these, so
-- this list is the contract with BrinejawBodyController.
local ATTR_COIL = "Coil"
local ATTR_UNWIND = "Unwind"
local ATTR_SWEEP_ANGLE = "SweepAngle"
local ATTR_SWEEP_HEIGHT = "SweepHeight"
local ATTR_SLUMP = "Slump"
local ATTR_FACE_ANGLE = "FaceAngle"
-- ...and the four the ATTACK CHANNEL rides on (BrinejawPath's header: ten
-- attributes and nothing else). `AttackKind` names which pose the body is in,
-- `AttackU` is progress 0..1 through it, and Aim is the strike point in
-- ARENA-LOCAL XZ - local because PoseCenter is already on the wire and a
-- world-space aim would be the same number written twice.
--
-- THE IRON RULE, and it is the server's alone: run AttackU to 1 BEFORE
-- clearing AttackKind. Every kind's exit ramp lives in the last few percent of
-- U (a lunge's head has 56 studs to climb), so a kind cleared at U < 1 snaps
-- ~100 parts across the arena in one frame. Every handler below does this the
-- same way: `finish` writes U = 1 (published that frame, kind still set) and
-- the FIRST `recover` frame clears the kind.
local ATTR_ATTACK_KIND = "AttackKind"
local ATTR_ATTACK_U = "AttackU"
local ATTR_AIM_X = "AimX"
local ATTR_AIM_Z = "AimZ"
-- Noctyss's replicated pose. The BOSS model publishes only the maw's three
-- numbers, because the choir publishes itself: each stalk is its own entity
-- with its own health bar, so it carries its own pose on its own model
-- (SocketIndex / TrueLure / Lean / BeamAngle / Douse, set by updateChoir).
-- This list is the contract with NoctyssBodyController.
local ATTR_MAW_RISE = "MawRise"
local ATTR_MAW_GAPE = "MawGape"
local ATTR_MAW_YAW = "MawYaw"
local ATTR_SOCKET_INDEX = "SocketIndex"
local ATTR_TRUE_LURE = "TrueLure"
local ATTR_LEAN = "Lean"
local ATTR_BEAM_ANGLE = "BeamAngle"
local ATTR_DOUSE = "Douse"
-- WHICH SOCKETS ARE EMPTY, as a bitmask on the BOSS model: bit (i - 1) set
-- means socket i is down. A dead stalk's model is destroyed, so the client
-- has nothing left to hang a collapse or a stump on - this is the only
-- record that socket ever held one. A bitmask rather than seven attributes
-- because it changes as a set, and one number can never replicate half a
-- choir.
local ATTR_CHOIR_DOWN = "ChoirDown"
-- The Kraken's. It needs far less than Brinejaw: its head does not travel,
-- so all the client has to know is how far out of the water it is. Where the
-- eight arms are is not published at all - each one is drawn to the tentacle
-- creature it holds, and those replicate already.
local ATTR_RISE = "Rise"
-- THE RIGGED-COLOSSUS SET. A boss whose limbs are animated needs more than a
-- height and a bearing, and these are the five: what it is doing, how far into
-- the pose, how far through the blow, and the aim it COMMITTED to at windup.
-- The names are the ones GnashrootBodyController already reads (bd, who is
-- migrating to them), so a second rigged boss adds a row to RIG_POSE below
-- rather than a second parallel branch.
local ATTR_ATTACK = "Attack"
local ATTR_ATTACK_BLEND = "AttackBlend"
local ATTR_STRIKE = "Strike"
local ATTR_AIM_ANGLE = "AimAngle"
local ATTR_AIM_SIDE = "AimSide"
-- Pyrelisk's own: which arm is lying across the moat as the climb ramp, 0 for
-- neither. The client draws the ramp only while this is set, because that is
-- the only window the server actually offers footing.
local ATTR_PLANTED = "Planted"

-- Which phase the health fraction puts it in (1-based), the stance's source.
local function bossPhaseIndex(def, hpFraction: number): number
	local index = 1
	for i, phase in def.phases do
		if hpFraction <= phase.below then
			index = i
		end
	end
	return index
end

-- The boss's own pose state, created on first use.
local function colossusState(creature, def)
	local state = creature.pose
	if not state then
		creature.poseKind = def.pose
		-- Kept off the row so `publishPose`, which is handed no `def`, can
		-- publish the count a stance is measured against.
		creature.poseStances = def.stances or 1
		if def.pose == "brinejaw" then
			-- SNAPPED TO THE WATERLINE, for the same reason Noctyss is just
			-- below. `spawn` lifts a creature by half its own thickness -
			-- 3.47 studs at the leviathan body's 1.5 scale - but every height
			-- this fight reasons about is measured from the BEACH: `sandY`,
			-- both sweep bands, the coil clearance. Inheriting the spawn lift
			-- floated the whole serpent off its own ground reference, and
			-- since the low band is only 3.4 studs thick, 3.47 was enough to
			-- carry the LOW sweep clean over a standing player while dropping
			-- the HIGH one to where a jump no longer cleared it. Measured
			-- against the real `sandY` profile: the fight's central read -
			-- stand under the high one, jump the low one - was inverted or
			-- entirely dead across 79% of the standable floor. It is 0% now,
			-- with at least 2.3 studs of margin on every one of the four
			-- calls, comfortably past the stud this module's header asks for.
			local anchor = creature.anchor or creature.pos
			state = BrinejawPath.newState(Vector3.new(anchor.X, World.WATER_Y, anchor.Z))
		elseif def.pose == "pyrelisk" then
			-- NOT snapped to the waterline, and that is the whole difference
			-- between this arena and every other one. The Ashfall Throne is a
			-- volcano SUMMIT: its rim path and its caldera lake are one flat
			-- plane 292 studs ABOVE World.WATER_Y, so snapping here the way
			-- Brinejaw and Noctyss do would drop the colossus through its own
			-- mountain and leave the fight standing on nothing.
			--
			-- The golem's authored z = 0 IS that plane (assets/boss_gen.py:
			-- its base sits on the lake's surface). So the only correction
			-- needed is to undo the spawn lift - `spawn` raises a creature by
			-- half its own thickness, which would float the whole body and,
			-- with it, every height this fight reasons about: the ramp, the
			-- decks, the seams a player shoots.
			local anchor = creature.anchor or creature.pos
			state = PyreliskPath.newState(Vector3.new(anchor.X, anchor.Y - (creature.halfThickness or 0), anchor.Z))
		elseif def.pose == "noctyss" then
			-- SNAPPED TO THE WATERLINE, not to where she spawned. `spawn`
			-- lifts a creature by half its own thickness - ~5.5 studs at her
			-- 2.4 scale - while every arena-local number this fight uses (the
			-- socket collars at Y 2.2, the pit floor, the maw's rise) is
			-- authored against the arena's deck. Inheriting the spawn lift
			-- floats the whole choir clear of its own collars.
			local anchor = creature.anchor or creature.pos
			state = NoctyssPath.newState(Vector3.new(anchor.X, World.WATER_Y, anchor.Z))
		elseif def.pose == "kraken" then
			-- SNAPPED TO THE WATERLINE, the same correction Brinejaw and
			-- Noctyss make above and for the same reason - it was the one
			-- posed boss that never made it. `spawn` lifts a creature by half
			-- its own thickness plus SURFACE_OFFSET, and everything about
			-- this animal is measured from the water: KrakenPath.lift is a
			-- height above the CROWN_LIFT datum, the arms leave the crown
			-- INTO the water, and `spawnBossParts` plants the whole tentacle
			-- ring at this centre's Y. Inheriting the lift floated the drawn
			-- octopus and its eight hitboxes clear of the sea they are
			-- standing in - by the body's half-thickness at scale 1.4, on a
			-- fight whose hitboxes are already 4-6 studs under the rock caps
			-- the players fight from.
			local anchor = creature.anchor or creature.pos
			state = KrakenPath.newState(Vector3.new(anchor.X, World.WATER_Y, anchor.Z))
		else
			state = { center = creature.anchor or creature.pos, time = 0 }
		end
		creature.pose = state
	end
	return state
end

-- Publish the pose for the client that draws this body. Pose/PoseCenter/
-- Stance are the GENERIC three - every colossus sets them, and they are all
-- a renderer needs to know which module draws it and where its perch is.
-- Everything past that is the boss's OWN vocabulary, so each pose publishes
-- its own named set: Wrack's chains have no use for a coil count, and a
-- shared slot named `Value3` would be worse than either.
-- Which posed bosses are RIGGED - animated limbs driven from a path module -
-- and which extras each one publishes on top of the shared five. A serpent
-- publishes coils; these publish an attack.
local RIG_POSE = {
	pyrelisk = { planted = true }, -- the arm that becomes the climb ramp
}

local function publishPose(creature, state)
	local model = creature.model
	if model:GetAttribute(ATTR_POSE) == nil then
		model:SetAttribute(ATTR_POSE_CENTER, state.center)
		model:SetAttribute(ATTR_POSE, creature.poseKind)
	end
	if creature.poseKind == "brinejaw" then
		model:SetAttribute(ATTR_COIL, state.coil)
		model:SetAttribute(ATTR_UNWIND, state.unwind)
		model:SetAttribute(ATTR_SWEEP_ANGLE, state.sweepAngle)
		model:SetAttribute(ATTR_SWEEP_HEIGHT, state.sweepHeight)
		model:SetAttribute(ATTR_SLUMP, state.slump)
		model:SetAttribute(ATTR_FACE_ANGLE, state.faceAngle)
		-- The attack channel. Defaulted here rather than at every writer, so a
		-- handler that sets nothing publishes a coherent idle rather than nil.
		model:SetAttribute(ATTR_ATTACK_KIND, state.attackKind or "")
		model:SetAttribute(ATTR_ATTACK_U, state.attackU or 0)
		model:SetAttribute(ATTR_AIM_X, state.aimX or 0)
		model:SetAttribute(ATTR_AIM_Z, state.aimZ or 0)
	elseif creature.poseKind == "kraken" then
		model:SetAttribute(ATTR_RISE, state.rise)
		model:SetAttribute(ATTR_FACE_ANGLE, state.faceAngle)
	elseif RIG_POSE[creature.poseKind] then
		-- The rigged-colossus publish, shared. Every field is on the state by
		-- the same name the client reads, so adding a rigged boss is a row in
		-- RIG_POSE - not another branch that can drift from this one.
		model:SetAttribute(ATTR_RISE, state.rise)
		model:SetAttribute(ATTR_FACE_ANGLE, state.faceAngle)
		model:SetAttribute(ATTR_ATTACK, state.attack or "")
		model:SetAttribute(ATTR_ATTACK_BLEND, state.blend or 0)
		model:SetAttribute(ATTR_STRIKE, state.strike or 0)
		model:SetAttribute(ATTR_AIM_ANGLE, state.aimAngle or state.faceAngle or 0)
		model:SetAttribute(ATTR_AIM_SIDE, state.aimSide or 1)
		-- THE STANCE, from here rather than only from the entrenched tick.
		-- That tick writes it on CHANGE, which means a rigged body draws its
		-- first frames - the whole rise - against whatever the client
		-- defaulted to, and a client that joins between two changes gets
		-- nothing at all. Published every frame here, and the MAXIMUM with it
		-- so the reader can tell how far down the count already is.
		--
		-- `state.coil` is where the shared entrenched tick keeps it (the name
		-- is Brinejaw's); mirrored onto the rig's own `stance` so the path
		-- module and the wire cannot disagree, and defaulted to the maximum
		-- rather than to 1, because 1 is the LAST stance - the wrong end.
		state.stance = state.coil or creature.poseStances or 1
		model:SetAttribute(ATTR_STANCE, state.stance)
		model:SetAttribute(ATTR_STANCES, creature.poseStances or 1)
		if RIG_POSE[creature.poseKind].planted then
			model:SetAttribute(ATTR_SLUMP, state.slump or 0)
			model:SetAttribute(ATTR_PLANTED, state.planted or 0)
		end
	elseif creature.poseKind == "noctyss" then
		model:SetAttribute(ATTR_MAW_RISE, state.mawRise)
		model:SetAttribute(ATTR_MAW_GAPE, state.mawGape)
		model:SetAttribute(ATTR_MAW_YAW, state.mawYaw)
	end
end

-- The whole visible boss is drawn by the client from the pose attributes, so
-- the server's model is authority only: it keeps its parts (hits and the HUD
-- read them) but shows nothing, or the head would be drawn twice.
local function hideColossusModel(creature)
	if creature.hiddenModel then
		return
	end
	creature.hiddenModel = true
	for _, descendant in creature.model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Transparency = 1
			descendant.CastShadow = false
		elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
			descendant.Transparency = 1
		end
	end
end

-- ============================================================ pyrelisk: the mount (2026-08-31)
--
-- THE POINT OF THE WHOLE FIGHT. A `handfall` baited onto a monolith leaves an
-- arm down across the lava moat (`state.planted`) and opens a stagger; for as
-- long as that window lasts the players CLIMB that arm, cross the deck on its
-- back and smash the vent shafts. Everything the climb needs that a client
-- cannot provide - real footing, the lava under it, the vents' health - is
-- here.
--
-- WHY THE SLABS ARE SPAWNED AND NOT BORROWED. `hideColossusModel` sets
-- Transparency and never touches CanCollide, so the server's own model IS
-- still solid - but it is the row's CreaturePack proxy, a ~23-stud lump
-- standing at the colossus's feet, nothing like the 270-stud body the client
-- draws over it. Standing on that is standing in the lake. So the footing is
-- built here from PyreliskPath.climbSlabs, the same joints
-- PyreliskBodyController draws the arm and the deck from, which is the only
-- reason the rock you see and the rock you stand on are the same rock.
--
-- WHY IT ONLY EXISTS INSIDE THE WINDOW, AND WHY THE BODY FREEZES WHILE IT
-- DOES. A player standing on an anchored part that is CFrame-moved does NOT
-- move with it: the part slides out from under them. So the slabs are placed
-- ONCE, at the instant the window opens, and the bearing the body planted on
-- is pinned for the duration. A colossus that went on turning to watch
-- whoever is nearest would swing the drawn arm out from under an invisible
-- plate with someone standing on it, a hundred studs over lava. The stillness
-- of the punish window is not an animation choice - it is what makes the
-- footing honest, and it is why the footing ends when the stillness does.
-- (The other half of that rule lives in PyreliskPath: `breath` and `lean`
-- both switch off while an arm is planted, because both sides compute them.)

-- The lake, and the two numbers that decide what happens to someone in it.
-- 120 is the caldera lake's edge (the row's `arena.radius` reasoning, and
-- handfall's `minReach`): everything inside it is lava.
local PY_LAKE_R = 120.0
-- Where a rescue puts you down: the middle of the rim path, forty studs off
-- the lake and forty inside the lip's undercut - the same band the summon
-- ring drops the party on, and the only stretch of floor the whole fight can
-- reach you on.
local PY_RESCUE_R = 150.0
-- HOW FAR ABOVE THE LAKE STILL COUNTS AS IN IT, and this is the load-bearing
-- half of the test. Everyone on the mount is inside the lake's radius - the
-- back deck is 202 studs straight up over it - so a flat radius check would
-- boil the entire party the moment they finished the climb they were asked
-- to make. Only something at the lava's own surface is in the lava.
local PY_LAVA_HEAD = 16.0
local PY_LAVA_TICK = 0.75
local PY_LAVA_DAMAGE = { 70, 95 }
-- The shrug. Radius is the LAKE's, not the arena's: it has to reach everyone
-- standing on the body and nobody standing on the rim path, and those two
-- sets are separated by exactly that circle.
local PY_SHAKE_PUSH = 62
local PY_SHAKE_TIME = 0.55
-- How long the lava keeps watching after the window shuts. The shove happens
-- as the slabs go, so anyone it throws is still in the air at that instant -
-- a watch that ended with the window would miss every death it exists for.
local PY_SHAKE_GRACE = 4.0
-- The vents: how close is "at it", how many swings it takes, and what a
-- broken one costs the boss. Three of them at 7% is a fifth of its health -
-- the mount has to be worth the climb, and this is most of the reason to
-- make it.
local PY_VENT_REACH = 30.0
local PY_VENT_HITS = 4
local PY_VENT_FRACTION = 0.07
local PY_SWING_GAP = 0.28

-- Every fight that currently has footing standing (creature -> mount). Only
-- ever zero or one entries, but keyed rather than a single upvalue so a
-- second arena on one server cannot make two windows share a state.
local pyreliskMounts = {}
-- Per-player swing throttle for the vent hits below. Weak keys: this is a
-- rate limit, not a record, and it must not be the reason a Player instance
-- outlives the player.
local pyreliskSwingAt = setmetatable({}, { __mode = "k" })

-- One piece of the climb. Invisible and unqueryable, exactly like the maw
-- floor: the rock the player SEES is the client's, and a queryable slab in
-- the middle of the arena would eat the ranged shots aimed at the body behind
-- it and re-seat every ground telegraph drawn under it.
local function pyreliskSlab(folder: Folder, name: string, size: Vector3, cframe: CFrame)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Anchored = true
	part.CanCollide = true
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Parent = folder
end

-- No `local`: this fills the forward declaration beside `clearMawFloor`, so
-- the two exits that can take a boss out from under its own furniture -
-- removeOwnedParts and kill - can both reach it. A leaked mount is a set of
-- invisible solid platforms left standing two hundred studs over the arena
-- for the rest of the server's life.
function clearPyreliskMount(creature)
	local mount = creature.pyreliskMount
	if not mount then
		return
	end
	creature.pyreliskMount = nil
	pyreliskMounts[creature] = nil
	mount.folder:Destroy()
end

-- Stand the climb up, once, from the pose as it is at this instant.
local function openPyreliskMount(creature, state, now: number)
	if creature.pyreliskMount then
		return
	end
	local slabs = PyreliskPath.climbSlabs(state)
	if #slabs == 0 then
		return -- nothing planted: there is no footing to offer, and no lie told
	end
	local folder = Instance.new("Folder")
	folder.Name = "PyreliskMount"
	for _, slab in slabs do
		pyreliskSlab(folder, slab.name, slab.size, slab.cframe)
	end
	folder.Parent = Workspace
	-- The vents' world points, taken now and kept: the body is about to be
	-- held still, so these stay true for the whole window, and reading them
	-- once means a swing can never be judged against a body that has moved
	-- since the slab it is standing on was placed.
	local vents = {}
	for index in PyreliskPath.VENTS do
		vents[index] = (PyreliskPath.ventPoint(state, index))
	end
	creature.pyreliskBroken = creature.pyreliskBroken or {}
	local mount = {
		folder = folder,
		-- The bearing it planted on, restored every frame below.
		faceAngle = state.faceAngle or 0,
		aimAngle = state.aimAngle or state.faceAngle or 0,
		vents = vents,
		hits = {},
		openedAt = now,
	}
	creature.pyreliskMount = mount
	pyreliskMounts[creature] = mount
end

-- The window closes: it takes its arm back. The slabs go, and everyone still
-- standing on the body is thrown off it.
local function shakePyreliskMount(creature, state, now: number)
	if not creature.pyreliskMount then
		return
	end
	clearPyreliskMount(creature)
	-- BROADCAST, not a velocity. Each client shoves its OWN character out of
	-- the circle (EVENTS.gust is the lure pull's machinery run outward), the
	-- same bargain the boss pull and the anchor chain already strike - the
	-- server never writes a player's motion, so nothing here fights the
	-- client's own physics ownership of its character.
	fireEvent("gust", Vector3.new(state.center.X, state.center.Y, state.center.Z), {
		radius = PY_LAKE_R,
		push = PY_SHAKE_PUSH,
		duration = PY_SHAKE_TIME,
		skin = "lava",
	})
	creature.pyreliskLavaUntil = now + PY_SHAKE_GRACE
	-- BACK TO REST. Opening a window skips the handler's `recover` (see
	-- openStagger), so the attack that earned this one is still sitting on
	-- the rig with blend 1 - and the moment `planted` clears, the working arm
	-- would snap back into a handfall windup it is not performing. The pose
	-- is this fight's furniture too; putting it down is part of packing up.
	--
	-- Except during the death, which is a pose of its own and has already been
	-- set for this frame (updateBossCollapse runs before placeColossus): a
	-- boss killed on the mount must not have its collapse wiped by the same
	-- teardown that takes the slabs away.
	if not creature.collapsing then
		state.attack = ""
		state.blend = 0
		state.strike = 0
	end
end

-- ANYONE IN THE LAVA: hurt, then put back on the path. Rescue rather than
-- kill, because the lake is not a hazard the fight ever asks you to read -
-- it is the floor the arena does not have, and drowning in it is a fall out
-- of the fight rather than a death you could have avoided.
local function pyreliskLavaWatch(creature, def, state, now: number)
	if now < (creature.pyreliskLavaAt or 0) then
		return
	end
	creature.pyreliskLavaAt = now + PY_LAVA_TICK
	local center = state.center
	local lo, hi = bossRoll(creature, def, PY_LAVA_DAMAGE)
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid and humanoid.Health > 0 then
			local out = Vector3.new(root.Position.X - center.X, 0, root.Position.Z - center.Z)
			if out.Magnitude < PY_LAKE_R and root.Position.Y <= center.Y + PY_LAVA_HEAD then
				local burn = Vector3.new(root.Position.X, center.Y, root.Position.Z)
				fireEvent("slam", burn, { radius = 11, skin = "lava" })
				PlayerService.damage(player, math.random(lo, hi), creature, { bypassIframe = true })
				local dir = if out.Magnitude > 0.01 then out.Unit else Vector3.xAxis
				local at = center + dir * PY_RESCUE_R + Vector3.new(0, 4, 0)
				-- Set down facing the thing that threw them, on their own
				-- bearing out of the lake, so a rescue never spins the camera
				-- round or drops two players on the same stud.
				root.CFrame = CFrame.lookAt(at, at - dir * 10)
			end
		end
	end
end

-- One frame of the mount, run from placeColossus so it ticks in every mode
-- this boss can be in - including the collapse, which is the one exit that
-- does not pass through the stagger's own end.
local function updatePyreliskMount(creature, def, state, now: number)
	if creature.mode == "stagger" and (state.planted or 0) ~= 0 and not creature.collapsing then
		if not creature.pyreliskMount then
			openPyreliskMount(creature, state, now)
		end
		local mount = creature.pyreliskMount
		if mount then
			-- HELD STILL. placeColossus has already turned the body toward
			-- the nearest player this frame; this puts it back. Both angles,
			-- because `bearing` folds one into the other and the slabs were
			-- placed from the result.
			state.faceAngle = mount.faceAngle
			state.aimAngle = mount.aimAngle
		end
	elseif creature.pyreliskMount then
		shakePyreliskMount(creature, state, now)
	end
	if creature.pyreliskMount or now < (creature.pyreliskLavaUntil or 0) then
		pyreliskLavaWatch(creature, def, state, now)
	end
end

-- THE VENTS, and the one thing on this page that is not geometry.
--
-- A vent is not a creature and cannot be: creature targeting is proximity to
-- a struct's pivot, and there is no Creatures row for a shaft on a boss's
-- back. Nor can a swing find the boss itself from up there - `inRange`
-- measures melee as pivot distance minus hitRadius, and the deck is ~202
-- studs from a pivot with a 96-stud radius, so a player standing ON the
-- colossus is a hundred studs out of reach of it. That is deliberate (the
-- moat is made of that number) and must not be widened: raising hitRadius
-- enough to be hittable from the deck would also make it hittable from the
-- shore.
--
-- So the swing is read where it is actually sent. RequestAttack is
-- argument-less and CombatService silently drops a swing that finds nothing
-- in reach, which is exactly what every swing on this deck does. A second
-- listener on the same remote costs nothing, needs no new network surface,
-- and cannot affect any other fight: it only ever does anything while a
-- mount is standing and the swinger is within 30 studs of an unbroken shaft.
--
-- Rate-limited on its own clock because it does NOT go through
-- CombatService's weapon cooldown - a client spamming the remote must not be
-- able to break three vents in a frame.
local function pyreliskVentSwing(player: Player)
	local now = os.clock()
	if now - (pyreliskSwingAt[player] or 0) < PY_SWING_GAP then
		return
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid or humanoid.Health <= 0 then
		return
	end
	for creature, mount in pyreliskMounts do
		local broken = creature.pyreliskBroken or {}
		for index, at in mount.vents do
			if not broken[index] and (root.Position - at).Magnitude <= PY_VENT_REACH then
				pyreliskSwingAt[player] = now
				local hits = (mount.hits[index] or 0) + 1
				mount.hits[index] = hits
				fireEvent("strikeHit", at, { radius = 9, skin = "lava" })
				if hits >= PY_VENT_HITS then
					-- BROKEN FOR THE FIGHT, not for the window: the record
					-- lives on the creature, so a second stagger cannot spend
					-- the same shaft twice and the party's third climb is for
					-- the one they have not opened yet.
					broken[index] = true
					creature.pyreliskBroken = broken
					fireEvent("slam", at, { radius = 26, skin = "lava" })
					local chunk = math.max(1, math.floor(creature.maxHealth * PY_VENT_FRACTION))
					CreatureService.damage(creature, chunk, player)
				end
				return
			end
		end
	end
end

Remotes.RequestAttack.OnServerEvent:Connect(pyreliskVentSwing)

-- ------------------------------------------------------------- the choir
--
-- Everything below is Noctyss's, and it is deliberately small: seven stalks
-- that are ordinary creatures, one number saying which of them is real, and
-- a mouth that comes up when that one breaks.

-- Pin every living stalk to its lantern and hand it its pose.
--
-- A stalk's hitbox IS its light: the server stands the model at the BULB, 35
-- studs up at the end of the crook, so shooting the lantern is what
-- registers and the trunk the design says is out of reach really is. The
-- model itself is hidden - the client draws the chain - exactly like the
-- colossus it belongs to.
local function updateChoir(creature, state, dt: number)
	for _, stalk in state.stalks do
		stalk.standing = false
	end
	-- HER OWN RING, NOT THE WORLD. This walked the entire `creatures` array
	-- every frame to find seven parts - O(everything alive) per boss per
	-- frame, against an ambient population capped at 40 (Tuning SPAWNER
	-- GLOBAL_CAP) plus raid waves, hatchlings, the boss and the choir itself:
	-- ~50 structs and ~50 field tests, sixty times a second, to touch seven.
	-- `spawnBossParts` already knows exactly which seven it planted, so it
	-- hands them over. Entries leave the list as they leave the fight: a kill
	-- flags `dead`, a withdrawal (`removeOwnedParts`) clears `partOf`, and
	-- both are checked here rather than trusted - the list is a cache of a
	-- fact those two own, never a second owner of it.
	local ring = creature.choirParts
	-- Backwards, because a departed stalk is removed from under the walk.
	for i = (if ring then #ring else 0), 1, -1 do
		local part = ring[i]
		if part.dead or part.partOf ~= creature or not part.socketIndex then
			table.remove(ring, i)
		else
			local index = part.socketIndex
			local stalk = state.stalks[index]
			if stalk then
				stalk.standing = true
				stalk.alive = true
				hideColossusModel(part)
				part.pos = NoctyssPath.bulbPosition(state, index)
				part.model:PivotTo(CFrame.new(part.pos))
				local model = part.model
				model:SetAttribute(ATTR_LEAN, stalk.lean)
				model:SetAttribute(ATTR_BEAM_ANGLE, stalk.beamAngle)
				model:SetAttribute(ATTR_DOUSE, stalk.douse)
			end
		end
	end
	-- A socket whose stalk is gone: the light goes out the instant it dies,
	-- and the shape keeps falling for a second so the client has a collapse
	-- to draw rather than a stalk vanishing mid-air.
	-- A lean eases back on its own. An attack that ends leaves its stalk
	-- reaching over the arena, and nothing else would ever put it upright.
	for index, stalk in state.stalks do
		if stalk.standing and index ~= state.activeStalk then
			stalk.lean = math.max((stalk.lean or 0) - dt * 1.6, 0)
		end
	end
	-- `down` means KILLED, not merely absent. It is the client's collapse cue
	-- and its lantern-break sound, so the survivors withdrawn at `closeMaw`
	-- must not set bits: marking them toppled seven stalks and fired seven
	-- breaks the party did not cause, at the end of every single window.
	local down = creature.choirKilled or 0
	for _, stalk in state.stalks do
		if not stalk.standing then
			stalk.alive = false
			stalk.fall = math.min((stalk.fall or 0) + dt * 1.4, 1)
			stalk.douse = 1
			stalk.lean = 0
		end
	end
	-- Published only on a change: seven sockets go down a handful of times a
	-- fight, and an attribute rewritten every frame is a replication cost
	-- for nothing.
	if down ~= creature.choirDown then
		creature.choirDown = down
		creature.model:SetAttribute(ATTR_CHOIR_DOWN, down)
	end
end

-- Pick the stalk that runs the next light attack: a LIVING, LIT one,
-- preferring whichever has the target at a workable distance. A beam out of
-- a dead socket would be the fight lying about where its attacks come from.
local function pickChoirStalk(state, root: BasePart?): number?
	local best, bestScore = nil, -math.huge
	for index, stalk in state.stalks do
		if stalk.alive and (stalk.douse or 0) < 0.5 then
			local score = math.random() * 10
			if root then
				local socket = state.center + NoctyssPath.socketPoint(index)
				-- Close enough to matter, far enough that the sweep has room
				-- to travel before it arrives.
				score = 90 - math.abs((root.Position - socket).Magnitude - 40) + math.random() * 12
			end
			if score > bestScore then
				best, bestScore = index, score
			end
		end
	end
	return best
end

-- JOLT THE WHOLE CHOIR AT ONCE: the lights dying, the lights coming back, a
-- NOTE: the choir's attack-beat flinches were REMOVED, not lost. A flinch is
-- drawn from `stalk.impulse`, which lives in each side's own pose state and is
-- not replicated - so a server-side flinch moved nothing a player could see,
-- and (before `bulbPosition` was made solid) moved the hitbox invisibly while
-- it did it. The recoils that survive are the ones the CLIENT raises off the
-- hits it watches land, which is the only place a flinch has both a cause the
-- player produced and an audience.

-- THE PUNISH WINDOW'S FLOOR. Creature meshes are collision-free (the client
-- draws them; the server model is authority only), so standing INSIDE her
-- mouth needs real geometry: an invisible tongue to fight on and a lip to
-- step over, pinned to the jaw and moving with it, because the jaw hinges the
-- whole time it is open. Same idea as the swamp's invisible trunk colliders -
-- what you see is a mesh, what you stand on is a part.
local function mawFloor(creature)
	if creature.mawFloorParts then
		return creature.mawFloorParts
	end
	local scale = NoctyssPath.MAW.SCALE
	local folder = Instance.new("Folder")
	folder.Name = "NoctyssMaw"
	local function slab(name: string, size: Vector3): BasePart
		local part = Instance.new("Part")
		part.Name = name
		part.Size = size
		part.Anchored = true
		part.CanCollide = true
		part.CanQuery = false
		part.Transparency = 1
		part.Parent = folder
		return part
	end
	local parts = {
		folder = folder,
		tongue = slab("Tongue", Vector3.new(11.0 * scale, 1.2, 9.0 * scale)),
		lip = slab("Lip", Vector3.new(5.0 * scale, 1.0, 9.0 * scale)),
	}
	folder.Parent = Workspace
	creature.mawFloorParts = parts
	return parts
end

local function placeMawFloor(creature, state)
	local parts = mawFloor(creature)
	local mouth = NoctyssPath.mawMouth(state)
	parts.tongue.CFrame = mouth
	-- The way in: a ledge off the mouth's front, bridging the pit's rim.
	parts.lip.CFrame = mouth * CFrame.new(8.0 * NoctyssPath.MAW.SCALE, -1.4, 0)
end

function clearMawFloor(creature)
	local parts = creature.mawFloorParts
	if parts then
		parts.folder:Destroy()
		creature.mawFloorParts = nil
	end
end

-- Forward: Brinejaw's live hazards - the bell's rings, a crossing wave, a
-- bombardment in flight, the flood, the polyps' deadline. Defined far below
-- with the handlers that arm them, and forward-declared here for the same
-- reason `pyreliskLatch` and `clearMawFloor` are: `placeColossus` is the one
-- call every mode of this fight passes through, so it is where they have to
-- be stepped, and it sits above the code that owns them.
local updateBrineHazards

-- Stand the model where its pose says its head is, aimed up-body.
local function placeColossus(creature, def, now: number, root: BasePart?)
	local state = colossusState(creature, def)
	-- Derived rather than passed, so every existing call site keeps working.
	local dt = math.clamp(now - (state.placedAt or now), 0, 0.1)
	state.placedAt = now
	-- Shared epoch with the client (see BrinejawBodyController): the ambient
	-- breath is the one term both sides compute independently, so it has to
	-- be driven by a clock they agree on.
	state.time = Workspace:GetServerTimeNow()
	if root then
		local to = root.Position - state.center
		if to.Magnitude > 0.01 then
			-- Turn at the row's own turnRate rather than snapping. The
			-- slumped head sits on this bearing during a punish window, and
			-- with it the melee hit point - so an unrated assignment made
			-- the target teleport around the tower the instant a different
			-- player became nearest, which is unhittable in a party.
			local goal = math.atan2(to.Z, to.X)
			local rate = (def.turnRate or math.rad(70)) * dt
			state.faceAngle = approachAngle(state.faceAngle or goal, goal, rate)
		end
	end
	-- Where the tracked player is, remembered on the pose. A handler's WINDUP
	-- is handed no `root` (only fire/strike are), and windup is the ONLY place
	-- a telegraph can still be a telegraph - `fire` runs when the strike
	-- starts, which is the blow, not the warning. So an attack aims from here.
	state.targetPos = root and root.Position or nil
	if def.pose == "kraken" then
		-- The head does not prowl, so nothing else ever writes its yaw - and
		-- bossFacing() reads THAT, not the pose. Left alone, everything drawn
		-- or thrown along the boss's facing (the stock tell's wedge, the
		-- mouth an ink glob leaves from) used whatever compass bearing the
		-- yaw happened to spawn on, for the whole fight, no matter where you
		-- stood.
		--
		-- Taking it from the pose rather than from the player is the point:
		-- faceAngle above is already turn-rate limited, so the cone inherits
		-- that instead of snapping to whoever is nearest this frame. The
		-- negation is the two conventions meeting - yawToward is
		-- atan2(-z, x), faceAngle is atan2(z, x).
		creature.yaw0 = -state.faceAngle
		-- AND THE HIDDEN MODEL GOES WHERE THE DRAWN BODY IS. Two faults, one
		-- line, and the second is the one that matters.
		--
		-- (a) NOTHING PUT IT BACK. `poseCFrame` + `PivotTo` is how every
		-- stock handler animates, and the posed branch had no counterpart to
		-- the entrenched poses that re-place the model each frame - so any
		-- handler this boss borrowed shoved the pivot somewhere and left it
		-- there permanently. Re-asserting it here, after updateBossAttack has
		-- run for the frame, makes that structurally impossible rather than a
		-- rule each handler has to remember.
		--
		-- (b) THE CAPTURE SPHERE WAS IN THE WATER. `raycastNearest` takes
		-- anything within shotRadius + hitRadius of the ray, measured from
		-- the model's PIVOT - a ~38-stud ball. The pivot sat on the waterline
		-- under a mantle drawn 65 studs tall (HEAD_HEIGHT 46.2 x SCALE 1.4),
		-- so the ball covered the foam and the lower skirt while the body you
		-- are aiming at stood entirely above it. Lifted to 0.4 of the mantle
		-- - `lift` (the rise-aware CROWN_LIFT) plus HEAD_HEIGHT*SCALE*0.4,
		-- about +31 at full height - the ball is centred in the silhouette.
		-- Raising `hitRadius` instead is the trap Pyrelisk's note describes:
		-- that number is also melee reach.
		--
		-- WHAT ELSE READS THIS PIVOT, traced before moving it, all fine:
		--   * `inRange` measures melee off it - but the kraken row is
		--     `rangedOnly` and the melee pick passes `skipRangedOnly`, so the
		--     head is not in that list at all. Splash callers see the head
		--     30 studs higher, which is where the body is.
		--   * `bossMouth` / `throwGlob`'s launch point: visual origin only,
		--     and better for it - globs now leave the mantle, not the foam.
		--   * CombatService's `hitPoint` (impact VFX) and its knockback
		--     direction: VFX follows the drawn body, and the knockback is
		--     overwritten the same frame by `creature.pos = creature.anchor`.
		--   * BossHudController's boss pick uses `flatDistance` - Y-blind.
		--   * KrakenBodyController reads the PoseCenter attribute, not the
		--     pivot, so nothing drawn moves.
		--   * Attack origins do NOT read it: the barrage family grounds off
		--     player roots, `undertow` and the stock tell read
		--     `creature.anchor`, and the arm moves read the arms.
		-- `creature.pos` is untouched and stays at the anchor, so every
		-- damagePlayersInRadius origin in the fight is the same point it was.
		local head = state.center
		local lift = KrakenPath.lift(state) + KrakenPath.HEAD_HEIGHT * KrakenPath.SCALE * 0.4
		creature.model:PivotTo(CFrame.new(head.X, head.Y + lift, head.Z) * CFrame.Angles(0, -(state.faceAngle or 0), 0))
	end
	if def.pose == "noctyss" then
		-- Her authority position is the MOUTH when it is up and the pit's
		-- centre when it is not: hits, the HUD's range checks and every
		-- damage test read this one point. She never prowls, so nothing else
		-- ever moves her.
		creature.pos = NoctyssPath.mawMouth(state).Position
		creature.model:PivotTo(NoctyssPath.mawCFrame(state))
		publishPose(creature, state)
		return
	end
	if def.pose == "brinejaw" then
		-- THE WHIP'S DRAG, stepped here because this is the one call every
		-- mode passes through and the only place `dt` exists (see
		-- `setSweepRate`). A sweeping handler writes `sweepTargetRate` for the
		-- frames its arm is travelling; everything else leaves it nil and the
		-- filter decays the bend out over WHIP_TAU. Cleared after the step so
		-- a handler that stops writing stops being believed on the next frame
		-- rather than for the rest of the fight.
		BrinejawPath.stepSweepRate(state, state.sweepTargetRate or 0, dt)
		state.sweepTargetRate = nil
		-- ...and everything the fight has left lying around: rings still
		-- crossing the beach, a wave mid-arena, a bombardment in flight, the
		-- flood, the polyps' deadline. Stepped here, so none of it is dropped
		-- when the move that started it ends.
		updateBrineHazards(creature, def, state)
		creature.pos = BrinejawPath.headPosition(state)
		local forward = BrinejawPath.tangentAt(state, 0)
		local up = if math.abs(forward.Y) > 0.99 then Vector3.new(0, 0, 1) else Vector3.new(0, 1, 0)
		local right = forward:Cross(up)
		if right.Magnitude > 1e-4 then
			creature.model:PivotTo(CFrame.fromMatrix(creature.pos, forward, right.Unit:Cross(forward).Unit))
		end
	end
	if def.pose == "pyrelisk" then
		-- WHAT THE STOCK TELL POINTS AT. beginBossAttack draws the row's
		-- telegraph from bossFacing(), which reads `yaw0` - and for an
		-- entrenched boss nothing writes yaw0 except an attack's own windup
		-- tracking, which starts from whatever the last attack happened to
		-- leave. So a directional stock tell (ventbreath's `coneTell`) drew its
		-- wedge on a stale compass bearing. Held on the tracked player here,
		-- one frame ahead of the latch that is about to commit to the same
		-- bearing, so the wedge drawn is the wedge that burns. The negation is
		-- the two conventions meeting - yawToward is atan2(-z, x), faceAngle is
		-- atan2(z, x) - the same seam the Kraken's branch above closes.
		local watching = state.targetPos
		if watching then
			local out = Vector3.new(watching.X - state.center.X, 0, watching.Z - state.center.Z)
			if out.Magnitude > 0.01 then
				creature.yaw0 = -math.atan2(out.Z, out.X)
			end
		end
	end
	if def.pose == "pyrelisk" and creature.mode ~= "stagger" then
		-- The ramp is furniture ONLY inside the punish window. Clearing it
		-- here rather than in the stagger exit keeps the whole rule in this
		-- boss's own code: the client stops drawing the ramp and the fight
		-- stops offering footing at the same instant, because both read this.
		state.planted = 0
	end
	if def.pose == "pyrelisk" then
		-- The mount ticks HERE rather than in the stagger branch, because this
		-- is the one call every mode of this fight passes through - entrenched,
		-- attacking, staggered and collapsing. The window's end, the shove and
		-- the lava watch that outlives both are all consequences of the mode
		-- changing, so they belong where the mode is always visible.
		updatePyreliskMount(creature, def, state, now)
	end
	publishPose(creature, state)
end

-- The earned opening: it loses its grip, comes down, and takes damage for
-- `seconds`. Called by a handler that has just been baited into a mistake.
local function openStagger(creature, def, now: number, seconds: number)
	creature.untargetable = false
	creature.exposedUntil = now + seconds
	creature.model:SetAttribute(ATTR_EXPOSED, true)
	-- Retire the attack here, because opening a window SKIPS endBossAttack -
	-- which is the only place cooldowns are written. Without this the move
	-- that earns a window is the one move that never goes on cooldown, so a
	-- good party gets slam -> window -> slam -> window and the patterns the
	-- fight is made of stop happening.
	local attack = creature.attack
	if attack then
		local rage = if creature.enraged then def.enrageCooldownMult else 1
		creature.cooldowns = creature.cooldowns or {}
		creature.cooldowns[attack.name] = now + attack.p.cooldown * rage
	end
	creature.attack = nil
	setMode(creature, "stagger", seconds, now)
	fireEvent("bossStagger", creature.pos, { name = def.name, duration = seconds })
end

-- ---------------------------------------------------------- the collapse
--
-- A colossus does not blink out where it stands: the thing it is HOLDING is
-- half of what it is, so its death is letting go. The killing blow starts a
-- fall instead of ending the fight, and the ordinary death - kill(), which
-- destroys the model and fires Killed - runs at the bottom of it.
--
-- NOTHING about the win changes. kill() is called with the killer that landed
-- the blow and the participant set the fight already built, so BossService's
-- rewards, the Cleared_/Heart_ attributes and the bossDown banner are the ones
-- they have always been - just COLLAPSE_TIME later. That is the whole reason
-- this is a delay in front of the death rather than a rewrite of it.
local COLLAPSE_TIME = 2.5
-- How much further down the perch the fall drags the body, in Brinejaw's
-- units: one more full turn than any stance ever costs it, so the coils end
-- up sprawled round the tower's foot instead of gripping its drum.
local COLLAPSE_COILS = 1.0

-- Assigned to the forward local beside kill(). CreatureService.damage calls
-- this INSTEAD of kill() when the health hits zero; returning true means "I
-- have taken this death, don't kill it yet".
beginBossCollapse = function(creature, killer: Player?): boolean
	if creature.collapsing then
		-- Already falling. A poison tick or a stray blast must not start a
		-- second collapse, and must not slip past this one into kill().
		return true
	end
	local def = bossDef(creature)
	-- Only a boss that is HOLDING a perch has anything to fall off. A posed
	-- boss that swims (the Kraken) and every ordinary creature take the
	-- ordinary death, untouched.
	if not def or not def.entrenched or not def.pose or not creature.mode or creature.mode == "rising" then
		return false
	end
	local state = colossusState(creature, def)
	creature.collapsing = true
	creature.deathBlow = killer
	-- Nothing lands on it and nothing is owed by it any more: the fall is not
	-- a phase of the fight, it is the end of one.
	creature.untargetable = true
	creature.attack = nil
	creature.forcedAttack = nil
	creature.poison = nil
	creature.knockVel = nil
	creature.airY, creature.vertVel = nil, nil
	creature.stunnedUntil = nil
	creature.exposedUntil = nil
	creature.lungeOpen = false
	creature.punishOpen = false
	creature.model:SetAttribute(ATTR_EXPOSED, nil)
	-- AND ITS HAZARDS DIE WITH IT. Brinejaw's wave, rings, bombardment and
	-- flood are all resolved from `placeColossus`, which keeps running through
	-- the collapse - so without this the beach would go on being shelled by an
	-- animal that is falling off its own tower, and the polyps would detonate
	-- and heal a corpse. The polyp CREATURES are real spawned structs, so they
	-- have to be taken away rather than merely forgotten.
	if creature.brine then
		local polyps = creature.brine.polyps
		if polyps then
			for _, entry in polyps.entries do
				if entry.creature and CreatureService.isAlive(entry.creature) then
					CreatureService.despawn(entry.creature.model)
				end
			end
		end
		creature.brine = nil
	end
	-- Where it is easing FROM, so the fall starts wherever the fight left it -
	-- mid-sweep, mid-stagger, still reared - instead of snapping to a pose.
	creature.collapseFrom = {
		coil = state.coil or BrinejawPath.MAX_COIL,
		slump = state.slump or 0,
		unwind = state.unwind or 0,
		sweepHeight = state.sweepHeight or BrinejawPath.SWEEP_LOW,
		-- The rigged colossus's three. Same idea as the four above and the
		-- same reason for existing: the fall starts from wherever the fight
		-- left the body - mid-swing, mid-breath, or with an arm still down
		-- across the moat - instead of snapping to a pose and then falling.
		blend = state.blend or 0,
		strike = state.strike or 0,
		rise = state.rise or 1,
	}
	setMode(creature, "collapse", COLLAPSE_TIME, os.clock())
	fireEvent("bossCollapse", creature.pos, { name = def.name, duration = COLLAPSE_TIME })
	return true
end

-- One frame of the fall. Ends by handing the death straight back to kill().
local function updateBossCollapse(creature, def, now: number)
	local u = modeProgress(creature, now)
	local e = u * u * (3 - 2 * u)
	local from = creature.collapseFrom
	local state = colossusState(creature, def)
	-- Per-pose, the way publishPose is: what "coming down" LOOKS like is the
	-- boss's own vocabulary, and a pose with no branch here still gets the
	-- beat and the event - the generic half of the contract.
	if creature.poseKind == "brinejaw" then
		-- The grip goes (coil slides a turn past its last stance), the head
		-- comes down on the sand (slump), and the tail lets go of the tower
		-- and lies out in the shallows (unwind, at sweep height).
		state.coil = from.coil - COLLAPSE_COILS * e
		state.slump = from.slump + (1 - from.slump) * e
		state.unwind = from.unwind + (1 - from.unwind) * e
		state.sweepHeight = from.sweepHeight + (BrinejawPath.SWEEP_LOW - from.sweepHeight) * e
		-- AND THE DEATH IS AN ATTACK KIND. `state.fall` is DERIVED in
		-- BrinejawPath - kind "collapse" means fall = U - and nothing on
		-- either side may write it directly, so the fall's shape is driven
		-- from here and read there. Raw U, not the eased `e`: the ease is
		-- already in the three numbers above, and doubling it would drag the
		-- body and the fall out of step with each other.
		state.attackKind = "collapse"
		state.attackU = u
		state.aimX, state.aimZ = 0, 0
	elseif creature.poseKind == "pyrelisk" then
		-- IT LETS GO. `collapse` is a real pose in PyreliskPath - both arms
		-- sliding slack into the lake - so the death is that pose driven in
		-- rather than a body being deleted where it stands.
		--
		-- Three numbers, and each one is a claim about what dying looks like
		-- for a thing that is holding itself up:
		--   * `planted` is cleared FIRST. A planted arm is furniture the pose
		--     machinery holds rigid for the whole window (poseFor returns the
		--     plant pose at full blend and ignores everything else), so a
		--     colossus that died mid-mount would have fallen with one arm still
		--     bolted across the moat. Clearing it also takes the climb's slabs
		--     with it the next frame, which is correct: nobody stands on this
		--     while it goes down.
		--   * `blend` runs UP into the collapse pose, not down out of the last
		--     attack - the fall is the last thing it does, so it gets the rig's
		--     full commitment.
		--   * `strike` runs to zero, because `armJoints` reads it as "drive the
		--     working arm back toward rest THROUGH the pose", and a limb still
		--     swinging a blow it never landed is the one thing a death must not
		--     look like.
		-- `slump` and `rise` carry the mass: the head goes down and the body
		-- sinks back into the lava it came up out of.
		state.planted = 0
		state.attack = "collapse"
		state.blend = from.blend + (1 - from.blend) * e
		state.strike = from.strike * (1 - e)
		state.slump = from.slump + (1 - from.slump) * e
		state.rise = from.rise * (1 - e * 0.45)
	end
	-- No `root`: a dying boss does not track anybody, so the face angle it
	-- died on is the one it falls on.
	placeColossus(creature, def, now, nil)
	if u >= 1 then
		creature.collapsing = nil
		-- And now the death that always happened. Same killer, same
		-- participants, same everything downstream.
		kill(creature, creature.deathBlow)
	end
end

-- The reef stones a slam can be baited onto, and each one shatters as it is
-- spent, so a wasted bait is a real cost. Three in the cove; nine round the
-- Ashfall Throne.
--
-- ON THE IMPORTED PYRELISK ARENA THERE IS NO `part` AT ALL, and every branch
-- below is written to survive that. assets/arena_gen.py exports the monoliths
-- as ONE merged `PyreliskArena_Teeth` object, so the per-stone `ReefStone<n>`
-- lookup finds nothing: the bait radius still works (it is `position`, which
-- comes from the config and not from a part), but a spent stone neither sinks
-- nor shatters, so the only feedback for spending one is the window it opens.
-- That is a known limitation and not something to paper over here - the real
-- fix is for the generator to emit the nine teeth as nine named objects.
-- Until it does, the rule for this table is: nothing may assume `part`.
local function colossusStones(creature, def)
	if creature.stones then
		return creature.stones
	end
	local stones = {}
	local arena = def.islandId and BossArenas.items[def.islandId]
	local arenas = Workspace:FindFirstChild("BossArenas")
	for index, offset in (arena and arena.stones or {}) do
		local center = creature.anchor or creature.pos
		local part = nil
		if arenas then
			for _, descendant in arenas:GetDescendants() do
				if descendant:IsA("BasePart") and string.find(descendant.Name, "ReefStone" .. index, 1, true) then
					part = descendant
					break
				end
			end
		end
		table.insert(stones, {
			index = index,
			position = Vector3.new(center.X + offset.X, center.Y, center.Z + offset.Z),
			standing = true,
			part = part,
			-- NOT `part.CFrame`: a stone spent in a previous fight is still
			-- sunk when the next summon builds this table, so capturing the
			-- live pose would record the underground position as "rest" and
			-- restoreStones would faithfully put it back underground. The
			-- config position is the only thing that stays true across
			-- fights, and the bait test already reads from there.
			-- Config POSITION, but the part's own ROTATION. Building a bare
			-- CFrame.new here threw the rotation away, and since this is
			-- applied unconditionally on the first entrenched frame, all three
			-- rocks visibly snapped up to 63 degrees straight round the moment
			-- the fight began. Sinking a stone is a pure translation, so the
			-- live rotation is always the authored one and is safe to keep.
			--
			-- AND THE PART'S OWN HEIGHT, not the waterline. This used to read
			-- World.WATER_Y + 1.6, which is only the arena floor when the
			-- arena is at sea level. Pyrelisk's is a volcano summit 292 studs
			-- above it, so the first entrenched frame teleported all nine
			-- monoliths that far under the caldera - and with them the bait
			-- the whole punish window is earned on. BossArenaService.buildStones
			-- has already stood each part on its own floor; the only thing
			-- worth recording here is where it is.
			restCFrame = part and (CFrame.new(part.Position) * part.CFrame.Rotation) or nil,
		})
		-- A new fight starts with every stone standing, so raise anything the
		-- last party sank. Nothing else does this: the previous boss's table
		-- died with it, and its stones were left in the ground.
		local stone = stones[#stones]
		if stone.part and stone.restCFrame then
			stone.part.CFrame = stone.restCFrame
		end
	end
	creature.stones = stones
	return stones
end

-- Every stance it loses, the grinding coils shed fresh masonry: the spent
-- stones come back. Without this a party that misread three baits would be
-- left with no way to open a window at all.
-- Raise every spent stone on a stance change: the coils shed fresh rock.
--
-- This used to claim it also ran at the end of a fight. It does not, and it
-- cannot from here - `beginBossCollapse` is assigned above this line, so this
-- local is not in scope for it. What actually cleans up is `colossusStones`,
-- which raises anything the last party sank while building the next fight's
-- table (see the comment at its `restCFrame`). Spent stones therefore sit in
-- the ground BETWEEN fights and stand again on the next summon, which is
-- correct but is not what this comment said.
local function restoreStones(creature, def)
	for _, stone in colossusStones(creature, def) do
		if not stone.standing then
			stone.standing = true
			stone.regrowAt = nil
			if stone.part and stone.part.Parent and stone.restCFrame then
				stone.part.CFrame = stone.restCFrame
			end
		end
	end
end

-- ...AND ONE AT A TIME, ON A CLOCK. The stance-change restore above was the
-- ONLY way a spent stone ever came back, and that was a deadlock dressed as
-- an economy: three baits cannot produce a stance's worth of damage, so a
-- party that misread all three had no way to open another window AND (before
-- the chip floor) no way to damage the boss at all. `stoneRegrow` on the row
-- turns the stones into a resource that refills - slowly enough that wasting
-- one still costs something real, fast enough that the fight cannot stall.
--
-- Opt-in by the field, so no other colossus's stones change: Pyrelisk's nine
-- monoliths do not carry it and keep the stance-change rule exactly.
local function regrowStones(creature, def, now: number)
	if not def.stoneRegrow then
		return
	end
	for _, stone in colossusStones(creature, def) do
		if not stone.standing then
			-- Stamped lazily rather than at `spendStone`, so a stone spent
			-- before this ever ran still gets a clock.
			stone.regrowAt = stone.regrowAt or (now + def.stoneRegrow)
			if now >= stone.regrowAt then
				stone.standing = true
				stone.regrowAt = nil
				if stone.part and stone.part.Parent and stone.restCFrame then
					stone.part.CFrame = stone.restCFrame
				end
				fireEvent("regrow", stone.position, { count = 1, name = def.name })
			end
		end
	end
end

-- Is there a stone still standing within `reach` of `at`? The same test
-- spendStone will make when the blow lands, asked at TELEGRAPH time so the
-- marker can already say "this one is on rock" - which is the whole reason
-- to aim a slam at a stone in the first place.
local function stoneNear(creature, def, at: Vector3, reach: number): boolean
	for _, stone in colossusStones(creature, def) do
		if stone.standing then
			local d = Vector3.new(stone.position.X - at.X, 0, stone.position.Z - at.Z).Magnitude
			if d <= reach then
				return true
			end
		end
	end
	return false
end

-- Take the stone nearest `at` if one is close enough and still standing.
local function spendStone(creature, def, at: Vector3, reach: number)
	local best, bestDist = nil, reach
	for _, stone in colossusStones(creature, def) do
		if stone.standing then
			local d = Vector3.new(stone.position.X - at.X, 0, stone.position.Z - at.Z).Magnitude
			if d <= bestDist then
				best, bestDist = stone, d
			end
		end
	end
	if not best then
		return nil
	end
	best.standing = false
	-- Sink the rock rather than destroy it: a stance change raises it again
	-- (restoreStones), and the authored and procedural arenas both work
	-- because their stones carry the same names.
	if best.part and best.part.Parent then
		best.part.CFrame = best.part.CFrame - Vector3.new(0, 9, 0)
	end
	fireEvent("reefShatter", best.position, { index = best.index })
	return best
end

-- ---------------------------------------------------------- brinejaw's two
--
-- ORBIT SWEEP: the tail unwinds off the tower and scythes round the arena
-- like a clock hand. LOW is jumped, HIGH is stood under - reading which is
-- coming is the whole dodge, and panic-jumping a high sweep is how you die.
-- Nothing spawns: the arm IS the coils, re-posed (BrinejawPath).
--
-- WHERE THE SWEEP IS CHOSEN. On the FIRST WINDUP FRAME, not in `fire`.
-- `fire` runs when the strike starts (updateBossAttack: windup ends -> phase
-- becomes "strike" -> fire), so anything decided there is decided at the
-- moment of the blow and can telegraph nothing. Picking the arc up front
-- costs the attack its mid-windup tracking, which is the point: a sweep you
-- can see the shape of is a sweep you can walk out of.
local function aimSweep(creature, def, p)
	local a = creature.attack
	if a.aimed then
		return -- windup already chose; `fire` only ever spends what it picked
	end
	a.aimed = true
	local state = colossusState(creature, def)
	local arc = p.arc or math.rad(320)
	-- WHICH WAY IT TURNS. Ordinarily a coin toss, but a row carrying
	-- `reverse` takes the OPPOSITE of the sweep before it - that is the whole
	-- of `doublewhip`: the return stroke has to come back through the ground
	-- you landed on, and a second random draw would make it a repeat half the
	-- time. `creature.sweepDir` is remembered across the follow, and defaults
	-- to 1 so a reversed sweep with no predecessor is still a valid sweep.
	local dir = if math.random() < 0.5 then 1 else -1
	if p.reverse then
		dir = -(creature.sweepDir or 1)
	end
	creature.sweepDir = dir
	local target = state.faceAngle or 0
	local at = state.targetPos
	if at then
		local to = at - state.center
		if to.Magnitude > 0.01 then
			target = math.atan2(to.Z, to.X)
		end
	end
	-- Start behind the target so the arm sweeps THROUGH them, not at them.
	a.dir = dir
	a.arc = arc
	a.startAngle = target - dir * arc * 0.5
	a.high = p.high == true
	-- The precise telegraph. `center` is the tower's FOOT, not the model's
	-- pivot (the head rides 60 studs up it), and `duration` is the whole lead
	-- time from here to the arm finishing, so the client can draw the band
	-- ahead of the body instead of chasing it.
	fireEvent("serpentSweep", state.center, {
		angle = a.startAngle,
		arc = dir * arc,
		inner = BrinejawPath.SWEEP_INNER,
		reach = BrinejawPath.SWEEP_REACH,
		height = if a.high then BrinejawPath.SWEEP_HIGH else BrinejawPath.SWEEP_LOW,
		high = a.high,
		-- The arm's real half-thickness, because the marker has no business
		-- guessing it. It is per-attack (3.4 low, 3.6 high, 3.8 constrict) and
		-- the client was drawing every one of them at a hardcoded 3.4.
		girth = p.girth or 3.2,
		-- BOTH halves, because they are not interchangeable: the arm holds
		-- still on the start bearing for `windup` and only travels the arc
		-- during `duration`. A marker that spreads the arc over the sum runs
		-- ahead of the tail by most of a sweep - players dodge the warning
		-- and get hit by the thing it was warning about.
		windup = p.windup,
		duration = p.duration,
	})
end

-- THE DRAG TERM, AND WHOSE JOB IT IS. `state.sweepRate` is the arm's signed
-- angular velocity, and it is deliberately NOT replicated - it is the
-- derivative of SweepAngle, which already is, so both sides differentiate the
-- same angle and push the result through the one shared low-pass
-- (BrinejawPath.stepSweepRate, WHIP_TAU). The server knows its own rate
-- exactly and hands it in; the client differentiates its eased angle.
--
-- A caller that supplies NOTHING gets rate 0 - a straight arm, which still
-- matches its own hit test but is not the arm anybody is shown.
--
-- SO THE FILTER IS STEPPED FROM `placeColossus`, NOT FROM THE HANDLERS, and
-- that is the whole reason this is a one-line field rather than a call: a
-- handler only runs while its own attack is running, and stepSweepRate has to
-- keep running AFTER one ends or the rate freezes at whatever it held on the
-- last strike frame and the arm keeps its 28-degree bend for the rest of the
-- fight. placeColossus is the one call every mode of this fight passes
-- through and it is the only place `dt` exists, so a sweeping handler writes
-- its exact rate here and everything else - windups, recoveries, the idle
-- serpent, the punish window - leaves it alone and gets the 0 that unwinds
-- the tip over about a third of a second.
local function setSweepRate(state, rate: number)
	state.sweepTargetRate = rate
end

-- ONE FRAME'S WORTH OF SWEPT ARM, hit-tested as a WEDGE rather than as the
-- bearing it happens to sit on now. A 340-degree sweep in 2.6 s travels 131
-- deg/sec while the arm is only ~6 degrees wide at full reach, so a single
-- 20 fps step (6.5 deg) can straddle a distant player entirely and the boss
-- whiffs for free on a loaded server. Sampling the step keeps the hit
-- independent of framerate.
--
-- AND THE PROBE COMES FROM `BrinejawPath.sweepProbe`, NEVER FROM A TABLE
-- LITERAL. This is the exact failure that module's header warns about: the
-- literal this replaces carried `center` and `sweepHeight` and nothing else,
-- so the moment the arm gained its drag term the hit test was comparing a
-- STRAIGHT spoke against a curve trailing it by up to 35 degrees - and it was
-- the drawn curve that was right. `sweepProbe` copies sweepRate, attackKind
-- and attackU too, which is also what makes `spiral` work: its contracting
-- reach is read off attackU by `sweepReach`, inside `sweepHits`.
local function sweepWedgeHits(creature, def, p, state, fromAngle: number)
	local a = creature.attack
	local girth = p.girth or 3.2
	local lo, hi = bossRoll(creature, def, p.damage)
	local swept = math.abs(state.sweepAngle - fromAngle)
	local steps = math.max(1, math.ceil(swept / math.rad(3)))
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and not a.hit[player] then
			for step = 0, steps do
				local angle = fromAngle + (state.sweepAngle - fromAngle) * (step / steps)
				if BrinejawPath.sweepHits(BrinejawPath.sweepProbe(state, angle), root.Position, girth) then
					a.hit[player] = true
					PlayerService.damage(player, math.random(lo, hi), creature, { bypassIframe = true })
					break
				end
			end
		end
	end
end

ATTACK_HANDLERS.orbitsweep = {
	windup = function(creature, def, p, u, _sub)
		aimSweep(creature, def, p)
		local state = colossusState(creature, def)
		-- Not travelling yet: the arm holds the start bearing for the whole
		-- windup, so the rate decays toward 0 and the tip straightens out.
		setSweepRate(state, 0)
		-- The tail peels off the tower during the windup - the telegraph is
		-- the body itself, so a player who reads the serpent reads the attack.
		-- It swings to the START bearing as it peels, which is now known.
		-- MONOTONIC, never a stomp: `sweeppair` and `constrict` chain a second
		-- sweep straight onto the first, and that follow-up begins its windup
		-- with the tail already fully out. Assigning `u` sent it from 1 back
		-- to 0 in one frame - the tail crossed 21.6 studs between two frames,
		-- about 1300 studs/second. The tail may only ever peel further off
		-- the tower during a windup; the recover is what puts it back.
		state.unwind = math.max(state.unwind or 0, u)
		state.sweepHeight = if p.high then BrinejawPath.SWEEP_HIGH else BrinejawPath.SWEEP_LOW
		state.sweepAngle = creature.attack.startAngle or state.sweepAngle
	end,
	fire = function(creature, def, p, _now, _root)
		local a = creature.attack
		local state = colossusState(creature, def)
		-- Reuse, never re-pick: a telegraph that shows one arc while the arm
		-- swings another is worse than no telegraph at all. (The call is a
		-- no-op after windup - it is here only so a zero-windup row can never
		-- reach the strike unaimed.)
		aimSweep(creature, def, p)
		state.unwind = 1
		a.hit = {}
		state.sweepAngle = a.startAngle
	end,
	strike = function(creature, def, p, _now, dt, _u, _root, _sub)
		local a = creature.attack
		local state = colossusState(creature, def)
		state.unwind = 1
		local rate = a.arc / math.max(p.duration, 1e-3)
		local from = state.sweepAngle
		state.sweepAngle += a.dir * rate * dt
		-- THE EXACT RATE, signed, handed to the shared filter. The server
		-- knows it - it is the number that drives the line above - and it is
		-- what puts the drag in the arm that is about to be hit-tested.
		setSweepRate(state, a.dir * rate)
		sweepWedgeHits(creature, def, p, state, from)
	end,
	finish = function(creature, def, _p, _now)
		-- The arm stays out; the entrenched branch winds it back onto the
		-- tower, so the recovery reads as the serpent re-gripping - and the
		-- rate is left to decay to 0 on its own, which IS the springback.
		local state = colossusState(creature, def)
		state.unwind = math.min(state.unwind or 1, 1)
	end,
}

-- SPIRAL: constrict's new form, and the one sweep that is also a POSE. It is
-- the orbitsweep in every respect but one - the arm's REACH contracts with U
-- (BrinejawPath's `spiral` kind, SWEEP_REACH -> SWEEP_INNER + SPIRAL_CLOSE),
-- so the lethal band closes in on the tower while the arm turns and hugging
-- the masonry stops being an answer half-way through.
--
-- The hit test is the SAME function: `spiralHits` is an alias of `sweepHits`,
-- and both read `sweepReach(state)`, which reads attackU. That is why the
-- probe must come from `sweepProbe` - a hand-built table with no attackU
-- would hit-test the full 66-stud arm against a lane the client has already
-- drawn closing in.
--
-- ONE serpentSweep event, at the FULL reach, fired from the windup by the
-- shared `aimSweep`. The contract is explicit that a shrinking reach must
-- never go through the old static-marker path: that marker draws one fixed
-- band for the whole move, so a contracting number sent through it would
-- promise safe ground that the arm is still crossing. The closing edge is
-- drawn by the body controller from `sweepReach` instead - same function,
-- same frame.
ATTACK_HANDLERS.serpentspiral = {
	windup = function(creature, def, p, u, _sub)
		aimSweep(creature, def, p)
		local state = colossusState(creature, def)
		state.unwind = math.max(state.unwind or 0, u)
		state.sweepHeight = BrinejawPath.SWEEP_LOW
		state.sweepAngle = creature.attack.startAngle or state.sweepAngle
		setSweepRate(state, 0)
		-- The kind goes on at the START of the windup, at U = 0, so the reach
		-- is still SWEEP_REACH while the arm peels off the tower: the closing
		-- only begins when the arm does.
		state.attackKind = "spiral"
		state.attackU = 0
		state.aimX, state.aimZ = 0, 0 -- spiral does not aim; the header says so
	end,
	fire = function(creature, def, p, _now, _root)
		local a = creature.attack
		local state = colossusState(creature, def)
		aimSweep(creature, def, p)
		state.unwind = 1
		a.hit = {}
		state.sweepAngle = a.startAngle
	end,
	strike = function(creature, def, p, _now, dt, u, _root, _sub)
		local a = creature.attack
		local state = colossusState(creature, def)
		state.unwind = 1
		local rate = a.arc / math.max(p.duration, 1e-3)
		local from = state.sweepAngle
		state.sweepAngle += a.dir * rate * dt
		setSweepRate(state, a.dir * rate)
		-- U IS THE CLOSING. Run it across the whole strike so the reach
		-- reaches its inner limit exactly as the arc finishes.
		state.attackU = u
		sweepWedgeHits(creature, def, p, state, from)
	end,
	finish = function(creature, def, _p, _now)
		local state = colossusState(creature, def)
		state.unwind = math.min(state.unwind or 1, 1)
		-- U TO 1 FIRST, published this frame with the kind still set: the
		-- spiral's arm is at its innermost here, and clearing the kind now
		-- would snap 53 studs of reach back in one frame.
		state.attackU = 1
	end,
	recover = function(creature, def, _p, _u, _sub)
		-- ...and NOW the kind goes. The first recover frame, one frame after
		-- the one that published U = 1.
		local state = colossusState(creature, def)
		state.attackKind = ""
		state.attackU = 0
	end,
}

-- TAIL SLAM: the opening. It hammers the tail down where a player stands.
-- Sand absorbs it. A REEF STONE does not - bait it onto one and the rattle
-- cracks against the rock, the serpent loses its grip, and it comes down.
--
-- WHERE THE SLAM IS AIMED. Same rule as the sweep, and it matters more here:
-- the whole move is a BAIT, and a bait you cannot see the landing point of is
-- just a coin toss. The impact is locked on the first windup frame and the
-- marker is fired at it, so "be standing at a stone when it lands" is a
-- decision the arena actually shows you.
-- How far into the strike the rattle actually connects. Shared, because the
-- marker's countdown and the tail's descent have to agree on it or the fight
-- lies about its own timing in one direction or the other.
local SLAM_IMPACT = 0.62

local function aimSlam(creature, def, p)
	local a = creature.attack
	if a.aimed then
		return
	end
	a.aimed = true
	local state = colossusState(creature, def)
	local at = state.targetPos or state.center
	local to = at - state.center
	if to.Magnitude > 0.01 then
		a.aimAngle = math.atan2(to.Z, to.X)
	else
		a.aimAngle = state.faceAngle or 0
	end
	-- The point the rattle will hit, at the beach's height there (sandY is
	-- measured from the perch anchor, the same frame sweepHits works in).
	local r = Vector3.new(at.X - state.center.X, 0, at.Z - state.center.Z).Magnitude
	a.impact = Vector3.new(at.X, state.center.Y + BrinejawPath.sandY(r), at.Z)
	fireEvent("serpentSlam", a.impact, {
		radius = p.radius or 13,
		-- THROUGH the blow, not up to the swing. The rings used to close at
		-- the end of the windup, but the rattle only starts falling then and
		-- the damage resolves at SLAM_IMPACT of the strike - so the countdown
		-- finished 0.53s before anything happened, and a player who read it
		-- correctly stepped back into the circle and died to it.
		duration = p.windup + (p.duration or 0) * SLAM_IMPACT,
		-- Whether this landing is ON rock: the client tints the marker, so a
		-- correct bait is legible before the tail comes down, not after.
		stoneNear = stoneNear(creature, def, a.impact, p.stoneReach or 11),
	})
end

ATTACK_HANDLERS.tailslam = {
	windup = function(creature, def, p, u, _sub)
		aimSlam(creature, def, p)
		local state = colossusState(creature, def)
		state.unwind = math.min(u * 1.2, 1)
		state.sweepHeight = BrinejawPath.SWEEP_HIGH + (p.lift or 9) * u
		state.sweepAngle = creature.attack.aimAngle or state.sweepAngle
	end,
	fire = function(creature, def, p, _now, _root)
		local a = creature.attack
		local state = colossusState(creature, def)
		aimSlam(creature, def, p) -- no-op after windup: the marker IS the blow
		state.sweepAngle = a.aimAngle
	end,
	strike = function(creature, def, p, now, _dt, u, _root, _sub)
		local a = creature.attack
		local state = colossusState(creature, def)
		state.unwind = 1
		-- Down it comes - and STAYS down. This used to read the arc off `u`
		-- unconditionally, so the frame after impact recomputed a height of
		-- 9.3 studs and put the rattle straight back in the air: dust, damage
		-- and a shockwave at ground level while the tail that supposedly
		-- caused them hovered three body-widths above it, never once touching
		-- the sand. Clamping the fall at the impact fraction lands it and
		-- keeps it landed. Squaring the fraction also matters - it makes the
		-- drop accelerate like a falling weight instead of easing out like a
		-- lift, and it means the height arrives at SWEEP_LOW continuously
		-- rather than as an 8.2-stud jump the client then has to smooth over
		-- a third of a second, which is what put the visible impact after the
		-- damage that it was supposed to explain.
		local fall = math.min(u / SLAM_IMPACT, 1)
		local top = BrinejawPath.SWEEP_HIGH + (p.lift or 9)
		state.sweepHeight = top + (BrinejawPath.SWEEP_LOW - top) * fall * fall
		if a.fired or u < SLAM_IMPACT then
			return
		end
		a.fired = true
		local lo, hi = bossRoll(creature, def, p.damage)
		damagePlayersInCone(a.impact, Vector3.new(1, 0, 0), p.radius or 13, math.pi, false, lo, hi, creature)
		fireEvent("slam", a.impact, { radius = p.radius or 13, skin = p.skin })
		local stone = spendStone(creature, def, a.impact, p.stoneReach or 11)
		if stone then
			openStagger(creature, def, now, p.stagger or 8)
		elseif p.weakStagger then
			-- Sand absorbs most of it: the serpent is jarred, not brought
			-- down. Enough to keep the fight winnable, far too short to be
			-- the plan.
			openStagger(creature, def, now, p.weakStagger)
		end
	end,
}

-- ==========================================================================
-- BRINEJAW'S OTHER HALF: THE FIVE ATTACKS THAT ARE NOT POSES
-- ==========================================================================
--
-- A wave crossing the arena, a seeded bombardment, the bell's rings, the
-- flood, the polyps. None of them is expressible as ten attributes on a
-- model, so each rides a `fireEvent` payload - and every shape below is
-- computed by a SHARED HELPER in BrinejawPath that the client calls with the
-- same payload. Nothing here re-derives a radius, a placement or a front's
-- position: the thing you dodge and the thing you see are one function.
--
-- AND THEY OUTLIVE THEIR HANDLERS. The bell's third ring is still crossing
-- the beach five seconds after the head has finished recoiling; the polyps
-- have twelve seconds to be broken while the boss goes on attacking; the
-- flood ticks through a stagger. An attack handler only runs while its own
-- attack is running, so resolving any of these inside one would silently drop
-- the tail of every effect the moment the next move began. They are resolved
-- instead by `updateBrineHazards`, run from `placeColossus` - the one call
-- every mode of this fight passes through, including the collapse. The
-- handlers below only ARM them.

-- The arena's cover, plus the one piece no table lists: the lighthouse
-- itself. Built once per fight and kept on the creature - `waveSheltered` is
-- asked about every player on every frame of a crossing, and BrinejawPath
-- deliberately takes the list as an argument (it is required by the pose math
-- on both sides of the wire, so a BossArenas dependency there is a cycle
-- waiting to happen).
local BRINE_SPIRE_COVER = { offset = Vector3.zero, radius = 9 }

local function brineCover(creature, def)
	if creature.brineCover then
		return creature.brineCover
	end
	local arena = def.islandId and BossArenas.items[def.islandId]
	local cover = { BRINE_SPIRE_COVER }
	for _, piece in (arena and arena.cover or {}) do
		table.insert(cover, piece)
	end
	creature.brineCover = cover
	return cover
end

-- The hazard record this boss hangs its live effects off. One table, created
-- on demand, torn down with the creature.
local function brineHazards(creature)
	creature.brine = creature.brine or {}
	return creature.brine
end

-- A DIRECTIONAL SHOVE, built out of the one shove the client already has.
-- `EVENTS.gust` pushes the local character AWAY from the point it is fired
-- at, so a push along `dir` is a gust fired from six studs BEHIND the player
-- along that direction - well inside the 12-stud radius, and pushes have no
-- close-range dead zone (that guard is for pulls). The server never writes a
-- player's motion directly: the client owns its own character's physics, and
-- this is the bargain the lure pull and the anchor chain already strike.
local function shoveAlong(at: Vector3, dir: Vector3, push: number, duration: number)
	fireEvent("gust", at - dir * 6, { radius = 12, push = push, duration = duration })
end

-- Is this root standing on the beach rather than in the air? The bell's rings
-- and nothing else ask: a jumping player clears them, which is the entire
-- read of that attack. 4.6 studs is a standing R15 root (~3.0 over the sand)
-- with 1.6 of slack for the beach profile and the arena's own half-stud of
-- authored slop, and well under the ~7 a jump's apex reaches.
local BRINE_GROUNDED = 4.6

local function brineGrounded(state, position: Vector3): boolean
	local dx, dz = position.X - state.center.X, position.Z - state.center.Z
	local r = math.sqrt(dx * dx + dz * dz)
	return position.Y - (state.center.Y + BrinejawPath.sandY(r)) < BRINE_GROUNDED
end

-- How far out a player is standing, in the arena's own frame.
local function brineRadiusOf(state, position: Vector3): number
	local dx, dz = position.X - state.center.X, position.Z - state.center.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- ------------------------------------------------------------- the wave
--
-- RIPTIDE. A wall of water crosses the whole arena on one bearing, and it is
-- TALL: jumping does not evade it, and the only answer is the lee of a rock.
-- The server damages a player in the frame the front's `along` passes theirs,
-- once, and only if `waveSheltered` says they are not standing in a shadow -
-- which is the same call, with the same numbers, that shades the ground on
-- the client. The shadow is a promise, not a suggestion.
local function armWave(creature, def, p, state, startAt: number)
	local bearing = math.random() * math.pi * 2
	local at = state.targetPos
	if at then
		-- Aimed THROUGH the tracked player rather than at random, so the wave
		-- is a question asked of somebody: the cover they have to reach is the
		-- cover behind them.
		local to = at - state.center
		if to.Magnitude > 0.01 then
			bearing = math.atan2(to.Z, to.X)
		end
	end
	local speed, reach = p.speed or 26, p.reach or 78
	brineHazards(creature).wave = {
		bearing = bearing,
		speed = speed,
		reach = reach,
		start = startAt,
		hit = {},
		p = p,
	}
	fireEvent("serpentWave", state.center, {
		bearing = bearing,
		speed = speed,
		reach = reach,
		start = startAt,
		-- The arena this belongs to. Without it the client matches by centre
		-- within 200 studs, which is a guess; with it the cover list it shades
		-- is provably the list the server just tested against.
		islandId = def.islandId,
	})
end

local function stepWave(creature, def, state, now: number)
	local wave = creature.brine and creature.brine.wave
	if not wave then
		return
	end
	local front = BrinejawPath.waveFront(wave.bearing, wave.speed, wave.reach, wave.start, now)
	if not front then
		creature.brine.wave = nil
		return
	end
	local dir = Vector3.new(math.cos(wave.bearing), 0, math.sin(wave.bearing))
	local cover = brineCover(creature, def)
	local lo, hi = bossRoll(creature, def, wave.p.damage)
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid and humanoid.Health > 0 and not wave.hit[player] then
			local along = (root.Position - state.center):Dot(dir)
			-- THE FRAME THE FRONT PASSES THEM. No height band anywhere in this
			-- test: the wall is taller than a jump on purpose.
			if front >= along then
				wave.hit[player] = true
				if not BrinejawPath.waveSheltered(cover, state.center, wave.bearing, root.Position) then
					PlayerService.damage(player, math.random(lo, hi), creature, { bypassIframe = true })
					shoveAlong(root.Position, dir, wave.p.push or 46, 0.5)
				end
			end
		end
	end
end

ATTACK_HANDLERS.riptide = {
	windup = function(creature, def, p, _u, _sub)
		local a = creature.attack
		if a.aimed then
			return
		end
		a.aimed = true
		local state = colossusState(creature, def)
		-- ARMED ON THE FIRST WINDUP FRAME, TO START WHEN THE WINDUP ENDS.
		-- `start` is a server clock, so the client draws the wall gathering
		-- OUTSIDE the arena for the whole windup and crossing it for the
		-- strike: the telegraph is the wave itself, arriving.
		armWave(creature, def, p, state, Workspace:GetServerTimeNow() + p.windup)
	end,
	fire = function(creature, def, p, _now, _root)
		-- A zero-windup row could reach the strike unarmed; this cannot be
		-- reached twice (aimSweep's rule, and for the same reason).
		ATTACK_HANDLERS.riptide.windup(creature, def, p, 0, 0)
	end,
	-- No `strike`: the crossing is resolved by updateBrineHazards, which runs
	-- in every mode. `duration` on the row only has to be long enough that the
	-- attack does not end absurdly before the water does; the wall's real
	-- clock is 2 * reach / speed, and it is the same clock on both sides.
}

-- ------------------------------------------------------------- the rain
--
-- MASONRY RAIN. The coils shed the lighthouse's own stonework over one sector
-- of the beach. Every chunk's landing point and its impact time come out of
-- `BrinejawPath.rainChunks` off the payload's seed - the SAME table the
-- client draws, derived rather than sent - and the server's damage circle
-- opens at each `impactAt`. No debris is kept server-side: the client's
-- rubble is cosmetic and despawns, and it must never enter the cover table.
local function armRain(creature, _def, p, state, startAt: number)
	local sector = state.faceAngle or 0
	local at = state.targetPos
	if at then
		local to = at - state.center
		if to.Magnitude > 0.01 then
			sector = math.atan2(to.Z, to.X)
		end
	end
	local payload = {
		seed = math.random(1, 2147483000),
		sector = sector,
		width = p.width or 2.1,
		inner = p.inner or 12,
		outer = p.outer or 64,
		-- The client's pool is 36 slots and it clamps to them, so a book that
		-- asked for more would have the server damaging circles nobody was
		-- ever shown. Clamped here as well, at the one place the number is
		-- turned into chunks.
		count = math.clamp(math.floor(p.count or 14), 0, 36),
		start = startAt,
		stagger = p.stagger or 0.22,
		fall = p.fall or 1.1,
		radius = p.radius or 7,
	}
	local hazards = brineHazards(creature)
	hazards.rain = { chunks = BrinejawPath.rainChunks(payload), radius = payload.radius, p = p, fired = {} }
	fireEvent("serpentRain", state.center, payload)
end

-- One frame of any bombardment: every chunk whose impact has arrived and has
-- not been spent yet. Shared by masonryrain and the surge's derived rain,
-- because they ARE the same shape - `surgeRain` only builds the payload.
local function stepRainRun(creature, def, state, run, now: number): boolean
	local lo, hi = bossRoll(creature, def, run.p.damage)
	local pending = false
	for index, chunk in run.chunks do
		if not run.fired[index] then
			if now >= chunk.impactAt then
				run.fired[index] = true
				local r = math.sqrt(chunk.pos.X * chunk.pos.X + chunk.pos.Z * chunk.pos.Z)
				local at = state.center + Vector3.new(chunk.pos.X, BrinejawPath.sandY(r), chunk.pos.Z)
				damagePlayersInRadius(at, run.radius, lo, hi, creature, 0.5)
			else
				pending = true
			end
		end
	end
	return pending
end

ATTACK_HANDLERS.masonryrain = {
	windup = function(creature, def, p, _u, _sub)
		local a = creature.attack
		if a.aimed then
			return
		end
		a.aimed = true
		local state = colossusState(creature, def)
		-- FIRST IMPACT AT THE END OF THE WINDUP, which puts each chunk's
		-- ground marker (`fall` ahead of its own impact) inside the windup:
		-- the markers ARE the telegraph, and they are drawn from this table.
		armRain(creature, def, p, state, Workspace:GetServerTimeNow() + p.windup)
	end,
	fire = function(creature, def, p, _now, _root)
		ATTACK_HANDLERS.masonryrain.windup(creature, def, p, 0, 0)
	end,
	-- Resolved by updateBrineHazards; see the note on riptide.
}

-- ------------------------------------------------------------ the rings
--
-- BELL TOLL. The head swings onto the keeper's bell and three rings leave the
-- tower. JUMP EACH ONE: the hit band is grounded-only, so an airborne player
-- passes through, and at 26 studs/second with a 1.05 s gap that is a rhythm
-- rather than a reaction test.
--
-- U here is the HEAD's, and the head is the windup: BrinejawPath's `belltoll`
-- puts the strike at BELL_IMPACT_U = 0.55, so the rings are armed in the
-- frame U crosses it and not when the engine's windup happens to expire.
local function armRings(creature, _def, p, state, startAt: number)
	local payload = {
		start = startAt,
		count = math.clamp(math.floor(p.count or 3), 1, 4),
		speed = p.speed or 26,
		gap = p.gap or 1.05,
		band = p.band or 2.6,
	}
	brineHazards(creature).rings = { payload = payload, p = p, hit = {} }
	fireEvent("serpentRings", state.center, payload)
end

local function stepRings(creature, def, state, now: number)
	local rings = creature.brine and creature.brine.rings
	if not rings then
		return
	end
	local payload = rings.payload
	local lo, hi = bossRoll(creature, def, rings.p.damage)
	local live = false
	for k = 1, payload.count do
		local radius = BrinejawPath.ringRadius(payload.start, payload.speed, payload.gap, k, now)
		-- A ring that has not left the masonry yet is nil too, so "no ring is
		-- anywhere" is only true once the LAST one has expired.
		if radius or now < payload.start + (k - 1) * payload.gap + 78 / payload.speed then
			live = true
		end
		if radius then
			rings.hit[k] = rings.hit[k] or {}
			for _, player in Players:GetPlayers() do
				local character = player.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if root and humanoid and humanoid.Health > 0 and not rings.hit[k][player] then
					local r = brineRadiusOf(state, root.Position)
					if math.abs(r - radius) < payload.band * 0.5 and brineGrounded(state, root.Position) then
						rings.hit[k][player] = true
						PlayerService.damage(player, math.random(lo, hi), creature, { bypassIframe = true })
					end
				end
			end
		end
	end
	if not live then
		creature.brine.rings = nil
	end
end

ATTACK_HANDLERS.belltoll = {
	windup = function(creature, def, _p, u, _sub)
		local state = colossusState(creature, def)
		state.attackKind = "belltoll"
		-- U 0..BELL_WINDUP_U across the engine's windup, so the head's own
		-- cock lands exactly where the path module says the windup ends.
		state.attackU = u * BrinejawPath.BELL_WINDUP_U
		state.aimX, state.aimZ = 0, 0 -- the bell is not aimed at anybody
	end,
	fire = function(creature, _def, _p, _now, _root)
		creature.attack.rung = false
	end,
	strike = function(creature, def, p, _now, _dt, u, _root, _sub)
		local a = creature.attack
		local state = colossusState(creature, def)
		-- The rest of U across the strike: BELL_WINDUP_U -> 1.
		state.attackU = BrinejawPath.BELL_WINDUP_U + u * (1 - BrinejawPath.BELL_WINDUP_U)
		if not a.rung and state.attackU >= BrinejawPath.BELL_IMPACT_U then
			a.rung = true
			-- THE FIRST RING LEAVES AS THE BELL IS STRUCK. `start` is now, so
			-- ring 1 is at radius 0 in this frame and clears the masonry a
			-- sixth of a second later - which is what the strike sounds like.
			armRings(creature, def, p, state, Workspace:GetServerTimeNow())
			fireEvent("serpentSlam", BrinejawPath.bellStrikePoint(state), { radius = 6 })
		end
	end,
	finish = function(creature, def, _p, _now)
		-- U to 1, published this frame with the kind still on: the head is
		-- half-way back up the tower here and clearing now would snap it.
		colossusState(creature, def).attackU = 1
	end,
	recover = function(creature, def, _p, _u, _sub)
		local state = colossusState(creature, def)
		state.attackKind = ""
		state.attackU = 0
	end,
}

-- ------------------------------------------------------------- the lunge
--
-- THIS ATTACK EXISTS TO PUNISH CAMPING. It picks the FARTHEST player past
-- `minRange` and puts the skull on them, and then leaves it there: the head
-- is planted on the sand at LUNGE_SIT, level with a standing root, for
-- `hold` seconds. That plant is the only punish window in the fight nobody
-- has to earn, and it is handed to the person standing furthest away.
--
-- THE SHAPE OF U, from BrinejawPath's header and not from taste:
--   0    .. 0.35  rear and TRACK - Aim may still be rewritten
--   0.35 .. 0.50  the strike; THE BLOW LANDS AT 0.50, not at the windup's end
--   0.50 .. 0.72  planted. Aim frozen from 0.35 on, or the head slides.
--   0.72 .. 1     the recover ramp, 28% of U because the skull has 56 studs
--                 to climb and an 8% exit moved the body 5.1 studs a step.
-- To hold the window open longer you HOLD U AT 0.72 - you do not stretch the
-- 0.50..1 span, which would drag the climb out with it.
local LUNGE_FALL = 0.30 -- seconds of U 0.35 -> 0.50, the descent
local LUNGE_SETTLE = 0.35 -- seconds of U 0.50 -> 0.72, the skull settling
local LUNGE_CLIMB = 0.85 -- seconds of U 0.72 -> 1, the peel back up the tower

-- The farthest living player past `minRange`, or the farthest one at all if
-- everybody is inside it (a party that has crowded the tower still gets
-- lunged at - the move is a punish, not a refusal).
local function farthestPlayerRoot(from: Vector3, minRange: number): BasePart?
	local best, bestDist = nil, -1
	local bestFar, bestFarDist = nil, -1
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid and humanoid.Health > 0 then
			local d = (Vector3.new(root.Position.X, 0, root.Position.Z) - Vector3.new(from.X, 0, from.Z)).Magnitude
			if d > bestFarDist then
				bestFar, bestFarDist = root, d
			end
			if d >= minRange and d > bestDist then
				best, bestDist = root, d
			end
		end
	end
	return best or bestFar
end

-- Write Aim from a world position, clamped to the ring the neck can reach.
-- ARENA-LOCAL, because PoseCenter is already replicated and a world-space aim
-- would be the same number on the wire twice.
local function setBrineAim(state, at: Vector3)
	local dx, dz = at.X - state.center.X, at.Z - state.center.Z
	local r = math.sqrt(dx * dx + dz * dz)
	if r < 1e-3 then
		return
	end
	local clamped = math.clamp(r, BrinejawPath.AIM_MIN, BrinejawPath.AIM_MAX)
	state.aimX, state.aimZ = dx / r * clamped, dz / r * clamped
end

ATTACK_HANDLERS.serpentlunge = {
	windup = function(creature, def, p, u, _sub)
		local state = colossusState(creature, def)
		state.attackKind = "lunge"
		-- U 0 -> LUNGE_COCK_U across the windup: the whole tracking window.
		state.attackU = u * BrinejawPath.LUNGE_COCK_U
		local root = farthestPlayerRoot(state.center, p.minRange or 25)
		if root then
			setBrineAim(state, root.Position)
		end
	end,
	fire = function(creature, def, p, _now, _root)
		local a = creature.attack
		local state = colossusState(creature, def)
		-- AIM FREEZES HERE, at LUNGE_COCK_U, and this is the last write to it.
		-- The client draws its countdown ring from the same two numbers, so a
		-- late correction would move the ring people are standing out of.
		local root = farthestPlayerRoot(state.center, p.minRange or 25)
		if root then
			setBrineAim(state, root.Position)
		end
		a.hold = p.hold or 4.0
		a.landed = false
		state.attackU = BrinejawPath.LUNGE_COCK_U
	end,
	strike = function(creature, def, p, now, _dt, _u, _root, _sub)
		local a = creature.attack
		local state = colossusState(creature, def)
		-- U FROM ELAPSED TIME, not from the engine's `u`, because the four
		-- segments have wildly different rates and the middle one is a HOLD.
		-- The row's `duration` must be hold + LUNGE_FALL + LUNGE_SETTLE +
		-- LUNGE_CLIMB, which is where its "hold + 1.5" comment comes from.
		local t = now - a.phaseStart
		local cock, impact = BrinejawPath.LUNGE_COCK_U, BrinejawPath.LUNGE_IMPACT_U
		local held = 0.72 -- the top of the punish window, from the header
		if t < LUNGE_FALL then
			state.attackU = cock + (impact - cock) * (t / LUNGE_FALL)
		elseif t < LUNGE_FALL + LUNGE_SETTLE then
			state.attackU = impact + (held - impact) * ((t - LUNGE_FALL) / LUNGE_SETTLE)
		elseif t < LUNGE_FALL + LUNGE_SETTLE + a.hold then
			state.attackU = held
		else
			local climb = (t - LUNGE_FALL - LUNGE_SETTLE - a.hold) / LUNGE_CLIMB
			state.attackU = held + (1 - held) * math.clamp(climb, 0, 1)
		end
		-- THE BLOW, at LUNGE_IMPACT_U. `lungeHits` reads the same U and the
		-- same Aim the client's shrinking ring does, and the radius comes from
		-- the path module - never from this row - so the disc that hurts and
		-- the disc that was drawn are one circle.
		if not a.landed and state.attackU >= impact then
			a.landed = true
			local lo, hi = bossRoll(creature, def, p.damage)
			for _, player in Players:GetPlayers() do
				local character = player.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if root and humanoid and humanoid.Health > 0 then
					if BrinejawPath.lungeHits(state, root.Position, BrinejawPath.LUNGE_RADIUS) then
						PlayerService.damage(player, math.random(lo, hi), creature, { bypassIframe = true })
					end
				end
			end
			fireEvent("serpentSlam", BrinejawPath.lungeImpactPoint(state), { radius = BrinejawPath.LUNGE_RADIUS })
		end
		-- THE PUNISH WINDOW. Open for exactly the held span: the skull is on
		-- the sand, `placeColossus` has already parked the authority model on
		-- it (`creature.pos = headPosition` IS `lungeHeadPosition`), and the
		-- chip scaling steps aside while this is true. Recomputed every frame
		-- rather than latched, so no exit - a stagger, a death, an interrupted
		-- attack - can leave it stuck open.
		creature.lungeOpen = state.attackU >= impact and state.attackU <= held
	end,
	finish = function(creature, def, _p, _now)
		creature.lungeOpen = false
		colossusState(creature, def).attackU = 1
	end,
	recover = function(creature, def, _p, _u, _sub)
		local state = colossusState(creature, def)
		state.attackKind = ""
		state.attackU = 0
		state.aimX, state.aimZ = 0, 0
	end,
}

-- ----------------------------------------------------------- the undertow
--
-- A bulge travels BENEATH the beach from the tower's foot out to where a
-- player was standing when it started, at CONSTANT SPEED - the read is that
-- it neither accelerates nor turns, so you step off the line. U is LINEAR IN
-- DISTANCE for exactly that reason, and Aim is frozen at U = 0.
--
-- The damage rides `undertowPoint`, which is the same call the client's dust
-- plume rides: one point, one radius (UNDERTOW_RADIUS, from the path module,
-- never from the row), no second copy of "how fast does it travel".
ATTACK_HANDLERS.serpentundertow = {
	windup = function(creature, def, _p, u, _sub)
		local a = creature.attack
		local state = colossusState(creature, def)
		if not a.aimed then
			a.aimed = true
			-- FROZEN AT U = 0, which for this kind means the moment the attack
			-- is chosen: the body has to unwind a turn and a half of coil to
			-- get under the sand, and an aim that kept tracking through that
			-- would drag the whole buried run sideways.
			local at = state.targetPos
			if at then
				setBrineAim(state, at)
			end
		end
		-- The kind is not on yet: the windup is the body diving, which the
		-- `undertow` pose's own entry ramp (30% of U) performs. Peel the tail
		-- off the tower so the dive has something to dive with.
		state.unwind = math.max(state.unwind or 0, u * 0.6)
	end,
	fire = function(creature, def, _p, _now, _root)
		local state = colossusState(creature, def)
		state.attackKind = "undertow"
		state.attackU = 0
		creature.attack.hit = {}
	end,
	strike = function(creature, def, p, _now, _dt, u, _root, _sub)
		local a = creature.attack
		local state = colossusState(creature, def)
		state.attackU = u
		local lo, hi = bossRoll(creature, def, p.damage)
		for _, player in Players:GetPlayers() do
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if root and humanoid and humanoid.Health > 0 and not a.hit[player] then
				if BrinejawPath.undertowHits(state, root.Position, BrinejawPath.UNDERTOW_RADIUS) then
					a.hit[player] = true
					PlayerService.damage(player, math.random(lo, hi), creature, { bypassIframe = true })
					local at, _ = BrinejawPath.undertowPoint(state)
					local out = Vector3.new(root.Position.X - at.X, 0, root.Position.Z - at.Z)
					shoveAlong(root.Position, if out.Magnitude > 0.01 then out.Unit else Vector3.xAxis, 34, 0.4)
				end
			end
		end
	end,
	finish = function(creature, def, p, _now)
		local state = colossusState(creature, def)
		-- THE ERUPTION at the far end of the run, which is what makes the
		-- bulge a threat you have to leave rather than one you outwalk.
		state.attackU = 1
		local at, _ = BrinejawPath.undertowPoint(state)
		local lo, hi = bossRoll(creature, def, p.damage)
		damagePlayersInRadius(at, p.radius or 14, lo, hi, creature, 0.4)
		fireEvent("slam", at, { radius = p.radius or 14 })
	end,
	recover = function(creature, def, _p, _u, _sub)
		local state = colossusState(creature, def)
		state.attackKind = ""
		state.attackU = 0
		state.aimX, state.aimZ = 0, 0
	end,
}

-- ------------------------------------------------------------ the surge
--
-- TIDAL SURGE, the stance-3 set-piece. It rears (kind "rear", U held at 0.5,
-- which is what that pose's header says a hold is) and the sea comes up over
-- everything outside `floodR` while its own masonry rains on the dry ground
-- left inside. Hold the shrinking band, then punish: the set-piece ENDS in a
-- guaranteed stagger through the existing machinery, so nothing new happens
-- client-side and the window looks exactly like an earned one.
--
-- The surge's rubble is NOT a second attack. Both sides build its rain
-- payload with `BrinejawPath.surgeRain` and hand it to the same `rainChunks`,
-- so there is one table of numbers for it and neither side typed them.
local SURGE_TAIL = 0.35 -- seconds at U = 1 before the window opens; see below

local function armSurge(creature, _def, p, state, startAt: number)
	local payload = {
		start = startAt,
		duration = p.duration,
		floodR = p.floodR or 46,
		seed = math.random(1, 2147483000),
	}
	local rainPayload = BrinejawPath.surgeRain(payload)
	brineHazards(creature).surge = {
		payload = payload,
		p = p,
		tickAt = startAt,
		rain = { chunks = BrinejawPath.rainChunks(rainPayload), radius = rainPayload.radius, p = p, fired = {} },
	}
	fireEvent("serpentSurge", state.center, payload)
end

local function stepSurge(creature, def, state, now: number)
	local surge = creature.brine and creature.brine.surge
	if not surge then
		return
	end
	local p = surge.p
	-- STEPPED FIRST, AND IT OUTLIVES THE FLOOD BY A CHUNK OR TWO.
	-- `surgeRain` lays one chunk every 0.45 s starting 0.8 s in, so the
	-- last of `duration / 0.45` of them lands just PAST `start + duration`.
	-- Tearing the record down on the flood's own clock dropped that chunk's
	-- damage while the client - which derives the same list from the same
	-- payload - still drew it falling. The record goes when both are done.
	local pending = stepRainRun(creature, def, state, surge.rain, now)
	if now >= surge.payload.start + surge.payload.duration then
		if not pending then
			creature.brine.surge = nil
		end
		return
	end
	if now < surge.tickAt then
		return
	end
	surge.tickAt = now + (p.floodTick or 0.6)
	local lo, hi = bossRoll(creature, def, p.damage)
	local floodR = surge.payload.floodR
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid and humanoid.Health > 0 then
			local r = brineRadiusOf(state, root.Position)
			if r > floodR then
				PlayerService.damage(player, math.random(lo, hi), creature, { bypassIframe = true })
				-- SHOVED INWARD, toward the band they are supposed to be
				-- standing in. The flood is a boundary, not a kill box.
				local inward = Vector3.new(state.center.X - root.Position.X, 0, state.center.Z - root.Position.Z)
				if inward.Magnitude > 0.01 then
					shoveAlong(root.Position, inward.Unit, p.shove or 30, 0.5)
				end
			end
		end
	end
end

ATTACK_HANDLERS.tidalsurge = {
	windup = function(creature, def, _p, u, _sub)
		local state = colossusState(creature, def)
		state.attackKind = "rear"
		-- U 0 -> 0.5 across the windup: REAR_U is 0.30, so it reaches full
		-- height part-way through and holds the rest, which reads as the body
		-- standing up and then GATHERING.
		state.attackU = u * 0.5
		state.aimX, state.aimZ = 0, 0 -- `rear` rears on the bearings it has
	end,
	fire = function(creature, def, p, _now, _root)
		local state = colossusState(creature, def)
		state.attackU = 0.5
		armSurge(creature, def, p, state, Workspace:GetServerTimeNow())
	end,
	strike = function(creature, def, p, now, _dt, _u, _root, _sub)
		local a = creature.attack
		local state = colossusState(creature, def)
		local t = now - a.phaseStart
		local fall = math.max(p.duration - SURGE_TAIL, 1e-3)
		-- HELD AT 0.5 for the flood, then U 0.5 -> 1 to come down. It reaches
		-- 1 with SURGE_TAIL to spare, and those frames are the whole point:
		-- the kind is still "rear" while U sits at 1, so the body finishes its
		-- exit ramp BEFORE the window opens and clears the kind. Running U to
		-- 1 and clearing it in the same frame publishes neither.
		if t >= fall then
			state.attackU = 1
		else
			local down = math.max(t - (fall - 1.2), 0) / 1.2
			state.attackU = 0.5 + 0.5 * math.clamp(down, 0, 1)
		end
		if t >= p.duration then
			-- THE GUARANTEED WINDOW. Cleared first, opened second: the stagger
			-- poses the head down on the sand and a live attack kind would be
			-- fighting it for the body. openStagger retires the attack and
			-- switches the mode, which is why this is safe to call from a
			-- strike (the engine only touches the orphaned attack table
			-- afterwards) and would NOT be from a recover.
			state.attackKind = ""
			state.attackU = 0
			openStagger(creature, def, now, p.stagger or 8)
		end
	end,
	finish = function(creature, def, _p, _now)
		-- Only reached if the strike ran out without opening the window (a
		-- duration shorter than SURGE_TAIL, or a death mid-set-piece).
		local state = colossusState(creature, def)
		state.attackU = 1
	end,
	recover = function(creature, def, _p, _u, _sub)
		local state = colossusState(creature, def)
		state.attackKind = ""
		state.attackU = 0
	end,
}

-- ------------------------------------------------------------ the polyps
--
-- THE HEAL, AND THE ONLY ATTACK THAT IS A QUESTION RATHER THAN A THREAT.
-- Three brine polyps grow on the arena's cover stones - never on the tower,
-- which is the one place a party cannot fight over. Every one still alive at
-- the deadline DETONATES: an AoE at its own feet, and its share of the
-- serpent's health running back up the beam. Every one broken in time pops
-- and denies its share.
--
-- The polyps are ordinary spawned creatures, so they are killable by whatever
-- the party is already carrying and they show a health bar like anything
-- else. Nothing about them is special-cased in combat; the only thing this
-- code owns is what happens at the deadline.
local function polypSites(creature, def, count: number): { Vector3 }
	local state = colossusState(creature, def)
	local arena = def.islandId and BossArenas.items[def.islandId]
	local sites = {}
	for _, piece in (arena and arena.cover or {}) do
		local offset = piece.offset or Vector3.zero
		-- Just outside the rock rather than inside it, so a polyp is never
		-- buried in the geometry that made it a landmark.
		local out = Vector3.new(offset.X, 0, offset.Z)
		local push = if out.Magnitude > 0.01 then out.Unit * ((piece.radius or 3) + 2.5) else Vector3.new(3, 0, 0)
		local at = state.center + offset + push
		table.insert(sites, Vector3.new(at.X, state.center.Y + BrinejawPath.sandY(brineRadiusOf(state, at)), at.Z))
	end
	-- Shuffle and take `count`: a fixed order would put the same three rocks
	-- under the same three polyps every fight, and half the mechanic is
	-- deciding which one the party can reach.
	for i = #sites, 2, -1 do
		local j = math.random(i)
		sites[i], sites[j] = sites[j], sites[i]
	end
	local chosen = {}
	for i = 1, math.min(count, #sites) do
		chosen[i] = sites[i]
	end
	return chosen
end

local function stepPolyps(creature, def, now: number)
	local run = creature.brine and creature.brine.polyps
	if not run then
		return
	end
	local p = run.p
	local expired = now >= run.deadline
	local remaining = 0
	for _, entry in run.entries do
		if not entry.resolved then
			local polyp = entry.creature
			local alive = polyp ~= nil and CreatureService.isAlive(polyp)
			if not alive then
				-- BROKEN IN TIME. The share is denied, and that is the whole
				-- reward: no loot, no XP, just a serpent that does not heal.
				entry.resolved = true
				fireEvent("polypBurst", entry.position, { healed = false, radius = p.radius or 10 })
			elseif expired then
				entry.resolved = true
				local lo, hi = bossRoll(creature, def, p.damage)
				damagePlayersInRadius(entry.position, p.radius or 10, lo, hi, creature, 0.5)
				-- The heal, as a fraction of MAX health so it does not shrink
				-- as the fight goes on - a heal that scales with what is left
				-- would be meaningless by the time it mattered.
				local heal = (p.heal or 0.035) * creature.maxHealth
				creature.health = math.min(creature.maxHealth, creature.health + heal)
				creature.model:SetAttribute(ATTR_HEALTH, creature.health)
				CreatureService.despawn(polyp.model)
				fireEvent("polypBurst", entry.position, { healed = true, radius = p.radius or 10 })
			else
				remaining += 1
			end
		end
	end
	if remaining == 0 then
		creature.brine.polyps = nil
	end
end

ATTACK_HANDLERS.serpentpolyps = {
	windup = function(creature, def, _p, u, _sub)
		-- No pose kind: the serpent does not change shape to grow these, and
		-- an attack kind with no ATTACK entry would pose nothing anyway. The
		-- coils grind, which is the tail coming a little off the tower.
		local state = colossusState(creature, def)
		state.unwind = math.max(state.unwind or 0, u * 0.35)
	end,
	fire = function(creature, def, p, _now, _root)
		local state = colossusState(creature, def)
		local row = Creatures.items.brine_polyp
		if not row then
			return
		end
		local deadline = Workspace:GetServerTimeNow() + (p.deadline or 12)
		local entries, positions = {}, {}
		for _, at in polypSites(creature, def, p.count or 3) do
			-- No `target`: a thrown spawn arcs off to a landing point, and
			-- these are rooted to the rock they grew on.
			local model = CreatureService.spawn(row, at, nil, "Neutral")
			local polyp = model and byModel[model]
			if polyp then
				table.insert(entries, { creature = polyp, position = at, resolved = false })
				table.insert(positions, at)
			end
		end
		if #entries == 0 then
			return
		end
		brineHazards(creature).polyps = { entries = entries, deadline = deadline, p = p }
		fireEvent("serpentPolyps", state.center, { deadline = deadline, positions = positions })
	end,
	-- Resolved by updateBrineHazards for the next twelve seconds, while the
	-- boss goes on attacking: the party has to answer the polyps AND the book
	-- at the same time, which is the whole cost of the mechanic.
}

-- ONE FRAME OF EVERYTHING BRINEJAW HAS LEFT LYING AROUND. Run from
-- `placeColossus`, so it ticks in every mode this boss can be in - attacking,
-- entrenched, staggered, collapsing. That is deliberate and it is the reason
-- these are not resolved in their handlers: a bell rung at the end of a move
-- is still ringing through the next one, and a party that breaks the last
-- polyp during a punish window must be credited for it.
updateBrineHazards = function(creature, def, state)
	if not creature.brine then
		return
	end
	-- THE SERVER CLOCK, NOT THE UPDATE LOOP'S. Every payload this section
	-- sends carries a `start` / `impactAt` / `deadline` measured in
	-- `Workspace:GetServerTimeNow()` - that is the contract's timing base,
	-- and it is what lets a client adopting the fight mid-attack land at
	-- the right phase instead of at the right elapsed time. `placeColossus`
	-- reasons in `os.clock()`, which is a completely different epoch: using
	-- the number it is holding would compare two clocks that share nothing
	-- but a unit, and every ring, chunk and deadline here would resolve
	-- either instantly or never.
	local now = Workspace:GetServerTimeNow()
	stepWave(creature, def, state, now)
	stepRings(creature, def, state, now)
	stepSurge(creature, def, state, now)
	stepPolyps(creature, def, now)
	local rain = creature.brine.rain
	if rain and not stepRainRun(creature, def, state, rain, now) then
		creature.brine.rain = nil
	end
end

-- ------------------------------------------------------ the choir's two
--
-- LIGHTSWEEP: one stalk leans onto a bearing and scythes its light across the
-- shelf. The lit wedge IS the hitbox - being seen is being hit - so the
-- answer is the dark behind a shadow fin, or outrunning the arc, and both are
-- things you do with your feet rather than your cooldowns. Nothing spawns and
-- no geometry is built: a beam is a bearing and a half-angle (NoctyssPath).
-- Defined with the other four handlers below, and forward-declared here for
-- the same reason the file forward-declares removeOwnedParts and
-- clearMawFloor: handfall's closures are built before that point, so a plain
-- `local` there would bind as a nil global by the time one of them ran.
local pyreliskLatch

-- HANDFALL: the colossus lifts a fist over the rim and brings it down on the
-- path. It is the fight's opener and its bait in one - come down beside one of
-- the arena's obsidian monoliths and the rock shatters, the arm stays down
-- across the moat, and that arm is the ramp players climb. On open ground the
-- same blow only jars it.
--
-- The Brinejaw shape (tailslam), rebuilt for a jointed arm: that handler
-- drives sweepHeight/sweepAngle through BrinejawPath and cannot be reused, but
-- `spendStone` and `openStagger` underneath it are generic and are what this
-- borrows.
ATTACK_HANDLERS.handfall = {
	windup = function(creature, def, p, u, _sub)
		local state = colossusState(creature, def)
		local a = creature.attack
		if not a.aimed then
			-- LATCHED ONCE. Everything in PyreliskPath's contract is about
			-- this happening here and not again: the fist is 228 studs from
			-- the shoulder, so re-picking a target mid-windup would swing the
			-- impact across most of the rim path while the player is reading
			-- the telegraph drawn for the old one.
			a.aimed = true
			-- Shared with the other four, and it aims the ARM: passing the
			-- pose turns the body far enough that the fist swings onto the
			-- target instead of 60-70 degrees past it. `HANDFALL_IMPACT`
			-- is where in the swing the blow lands, so the point marked here
			-- is where the fist will BE then - not where it starts.
			a.impact = pyreliskLatch(creature, def, p, "handfall", HANDFALL_IMPACT)
			-- The shadow on the ground, for the whole lead time. `slam` is a
			-- real telegraph branch on the client (a pulsing ring at the
			-- radius); an unknown kind would degrade to a 3-stud sparkle,
			-- which on a blow this size is no warning at all.
			fireEvent("telegraph", a.impact, {
				kind = "slam",
				radius = p.radius,
				duration = p.windup + p.duration * 0.5,
				skin = "lava",
			})
		end
		state.attack = "handfall"
		state.blend = u
		state.strike = 0
	end,
	strike = function(creature, def, p, now, _dt, u, _root, _sub)
		local state = colossusState(creature, def)
		local a = creature.attack
		state.strike = u
		-- The blow lands when the ARM does. This used to fire at 0.45, which
		-- is 0.77s before the pose brings the fist down - the shockwave went
		-- off while the hand was still 235 studs in the air and 60 studs
		-- outside the arena.
		if a.fired or u < HANDFALL_IMPACT then
			return
		end
		a.fired = true
		local lo, hi = bossRoll(creature, def, p.damage)
		damagePlayersInRadius(a.impact, p.radius, lo, hi, creature, 0.35, BOSS_HEIGHT_TOLERANCE)
		-- `strikeHit`, not `bossSlam`: there is no EVENTS.bossSlam on the
		-- client, so that call hit the catch-all and drew nothing at all.
		fireEvent("strikeHit", a.impact, { radius = p.radius, skin = "lava" })
		-- The bait. A monolith within reach shatters and buys the long window
		-- with the arm left lying across the moat; open rock buys a jar.
		local stone = spendStone(creature, def, a.impact, p.stoneReach or 26)
		if stone then
			state.planted = state.aimSide
			openStagger(creature, def, now, p.stagger or 20)
		else
			state.planted = 0
			openStagger(creature, def, now, p.weakStagger or 3)
		end
	end,
	recover = function(creature, def, _p, u, _sub)
		local state = colossusState(creature, def)
		state.blend = 1 - u
		state.strike = 1 - u
		if u >= 1 then
			state.attack = ""
		end
	end,
}

-- ---------------------------------------------------- pyrelisk's other four
--
-- RIMSWEEP, VENTBREATH, ASHFALL, SHARDHURL. Every one of them drives the same
-- three numbers `handfall` does - state.attack (which pose), state.blend (how
-- far into it) and state.strike (how far through the blow) - because
-- PyreliskBodyController draws the body from those and from nothing else. A
-- handler that forgets one of them does not leave the rig unanimated: the rig
-- holds whatever the last handler left on it, so a missed `strike = 0` is a
-- fist that starts its windup already swung.
--
-- And every one of them LATCHES ITS AIM ONCE, on the first windup frame. The
-- reason belongs next to the code and not only in PyreliskPath's header: the
-- fist is 228 studs from the shoulder, so re-picking a target between frames
-- swings the hazard across most of the rim path while the player is still
-- reading the telegraph that was drawn for the old one. Three other bosses in
-- this repo have been bitten by exactly that.
--
-- WHERE A BLOW MAY LAND. The rim path runs r=120 (the lake's edge) to r=232
-- (the lip), but anything that comes down from ABOVE is capped at 200: past
-- roughly r205 the lip undercuts and the outer strip of path is roofed, so a
-- fist or a falling slab aimed out there arrives through the ceiling. That is
-- why `pyreliskLatch` clamps the aim to [120, 200] and will not let a row
-- widen it - only narrow it. A rake, which travels horizontally at path
-- height, is not bound by that and the rimsweep row rakes to 228 on purpose.
local PY_BAND_OUT = 200.0 -- PY_CLEAR_R: the outer edge of open sky
local PY_PATH_OUT = 232.0 -- the lip itself: the last stud anyone can stand on

-- COMMIT. Latches the pose's aim and hands back the ground point the attack
-- has just promised, clamped into the band. Called once, from a windup, and
-- never again for the life of that attack.
function pyreliskLatch(creature, def, p, poseName: string?, strikeAt: number?): (Vector3, number, number)
	local state = colossusState(creature, def)
	local angle = state.faceAngle or 0
	local radius = (PY_LAKE_R + PY_BAND_OUT) * 0.5
	local near = math.max(p.minReach or PY_LAKE_R, PY_LAKE_R)
	local far = math.min(p.maxReach or PY_BAND_OUT, PY_BAND_OUT)
	local at = state.targetPos
	if at then
		local to = Vector3.new(at.X - state.center.X, 0, at.Z - state.center.Z)
		if to.Magnitude > 0.01 then
			angle = math.atan2(to.Z, to.X)
			-- The row may narrow the band; it may not widen it. A minReach
			-- under the lake's edge is a fist in its own lava, and a maxReach
			-- past the undercut is a blow nobody could have been standing
			-- under - neither is a row's decision to make.
			radius = math.clamp(to.Magnitude, near, math.max(near, far))
		end
	end
	-- AIM THE ARM, NOT THE BODY. A caller that passes a pose is aiming a
	-- FIST, and this colossus cannot put a fist in front of itself: its
	-- shoulders are 118 studs off-axis, so the arm lands 60-70 degrees round
	-- its own flank (PyreliskPath.fistOffset explains why that is geometry
	-- rather than a tunable). Latching the body at the target's own bearing
	-- therefore puts the shockwave on the player and the visible fist ~200
	-- studs of arc away. Turning the body that much further lands the arm on
	-- the target and keeps the two together, which is the promise
	-- PyreliskPath's header makes and could not previously keep.
	local side = PyreliskPath.plantSide(state, angle)
	local bodyAngle = angle
	if poseName then
		local localBearing, fistRadius = PyreliskPath.fistOffset(poseName, side, strikeAt)
		bodyAngle = angle - localBearing
		-- The reach is the ARM's, not the player's distance: where the fist
		-- can be is a property of the pose. Clamped only as a sanity rail -
		-- if this ever clamps, the pose and the band disagree and the
		-- telegraph would stop marking the real landing point.
		radius = math.clamp(fistRadius, near, math.max(near, far))
	end
	PyreliskPath.latch(state, bodyAngle, side)
	local impact = Vector3.new(
		state.center.X + math.cos(angle) * radius,
		state.center.Y,
		state.center.Z + math.sin(angle) * radius
	)
	return impact, angle, radius
end

-- The pose half of a windup, shared by all four: hold the attack's shape,
-- blend into it over the windup, and make sure the blow reads as unswung.
local function pyreliskWindupPose(state, name: string, u: number)
	state.attack = name
	state.blend = u
	state.strike = 0
end

-- ...and the recovery, which is the same three numbers unwound. Clearing
-- `attack` at the end matters: `poseFor` reads POSE[state.attack], so a name
-- left behind holds the working arm in a pose it is no longer performing.
local function pyreliskRecoverPose(state, u: number)
	state.blend = 1 - u
	state.strike = 1 - u
	if u >= 1 then
		state.attack = ""
	end
end

-- Shortest signed way from `from` to `to`, in radians.
local function pyreliskWrap(a: number): number
	return (a + math.pi) % (math.pi * 2) - math.pi
end

-- RIMSWEEP: the arm draws back low and rakes an arc of the path. The whole
-- forearm is the hazard, so the shape is a BAND of the ring rather than a
-- point - which is why the row's tell is a `ringTell` at the boss (the stock
-- draw's annulus, inner to radius) rather than a mark on the ground.
--
-- Bespoke on purpose. `orbitsweep` is the same idea and cannot be borrowed:
-- every line of it drives sweepAngle / sweepHeight / unwind through
-- BrinejawPath, which is a different animal's spine.
ATTACK_HANDLERS.rimsweep = {
	windup = function(creature, def, p, u, _sub)
		local state = colossusState(creature, def)
		local a = creature.attack
		if not a.aimed then
			a.aimed = true
			local _, angle = pyreliskLatch(creature, def, p)
			a.arc = p.arc or math.rad(150)
			-- WHICH WAY IT RAKES: away from the shoulder that throws it,
			-- decided by the arm the latch picked, never by a coin toss. A
			-- direction the body cannot explain is a direction the player
			-- cannot read, and this is a move you answer by running the right
			-- way round the ring.
			a.dir = if (state.aimSide or 1) < 0 then -1 else 1
			-- Starting behind the target so the arm sweeps THROUGH them
			-- rather than at them.
			a.startAngle = angle - a.dir * a.arc * 0.5
			a.angle = a.startAngle
			a.inner = math.max(p.inner or 160, PY_LAKE_R)
			a.outer = math.min(p.radius or PyreliskPath.REACH, PyreliskPath.REACH)
			a.hit = {}
			-- WHERE THE RAKE BEGINS, on the band, for the whole lead time.
			-- The row's stock `ringTell` says which annulus is about to be
			-- dangerous; this one says which end of it the arm enters from,
			-- and the two together are the difference between "get out of the
			-- outer band" and "get out of the outer band THAT way".
			local mid = (a.inner + a.outer) * 0.5
			local entry = Vector3.new(
				state.center.X + math.cos(a.startAngle) * mid,
				state.center.Y,
				state.center.Z + math.sin(a.startAngle) * mid
			)
			fireEvent("telegraph", entry, {
				kind = "mark",
				radius = (a.outer - a.inner) * 0.5,
				duration = p.windup + p.duration,
				skin = p.skin,
			})
		end
		pyreliskWindupPose(state, "rimsweep", u)
	end,
	strike = function(creature, def, p, _now, dt, u, _root, _sub)
		local state = colossusState(creature, def)
		local a = creature.attack
		state.strike = u
		local from = a.angle
		a.angle = from + a.dir * (a.arc / math.max(p.duration, 1e-3)) * dt
		local step = (a.angle - from) * a.dir
		local lo, hi = bossRoll(creature, def, p.damage)
		for _, entry in livingRootsNear(state.center, a.outer + 8) do
			if not a.hit[entry.player] then
				local stood = entry.root.Position
				local to = Vector3.new(stood.X - state.center.X, 0, stood.Z - state.center.Z)
				local d = to.Magnitude
				local level = math.abs(stood.Y - state.center.Y) <= BOSS_HEIGHT_TOLERANCE
				if level and d >= a.inner and d <= a.outer then
					-- THE WEDGE THE ARM CROSSED THIS FRAME, not the bearing
					-- it happens to be on now. A 150-degree arc in 1.8s
					-- travels 83 deg/s while the arm is only about 9 degrees
					-- wide out at the band, so on a loaded server one 20fps
					-- step can straddle a player entirely and the boss
					-- whiffs for free. Testing the swept interval instead
					-- makes the hit independent of the frame rate, and the
					-- pad is the forearm's own girth in radians at that
					-- player's distance rather than a guessed constant.
					local pad = (p.girth or PyreliskPath.WALK_ARM_SIZE.Z) * 0.5 / math.max(d, 1)
					local rel = pyreliskWrap(math.atan2(to.Z, to.X) - from) * a.dir
					if rel >= -pad and rel <= step + pad then
						a.hit[entry.player] = true
						PlayerService.damage(entry.player, math.random(lo, hi), creature, { bypassIframe = true })
					end
				end
			end
		end
	end,
	recover = function(creature, def, _p, u, _sub)
		pyreliskRecoverPose(colossusState(creature, def), u)
	end,
}

-- VENTBREATH: the head rears, the jaw opens (PyreliskPath.jawAngle and
-- headCFrame both read this attack BY NAME) and a molten cone comes out along
-- the bearing it committed to. What it leaves behind is the point: pools of
-- burning ground that take path away for the rest of the fight.
--
-- `conebreath` is the generic version of this and was tried first. It cannot
-- be used here, for three separate reasons, and each one fails SILENTLY:
--   * it re-aims every frame off `root` (`the jet tracks slowly`), which is
--     the one thing PyreliskPath's contract forbids;
--   * it takes its cone's origin from `creature.pos`, which for a colossus is
--     the proxy's pivot lifted by half its own thickness, and
--     damagePlayersInCone gates on 12 studs of height difference - so at this
--     body's scale the cone would simply miss everyone, every time, with no
--     error anywhere;
--   * it PivotTo's the model each frame, dragging the invisible authority
--     hitbox around under a body the client draws from the pose.
-- The tick-and-pool SHAPE below is conebreath's, deliberately, so the two
-- moves stay recognisably the same move.
ATTACK_HANDLERS.ventbreath = {
	windup = function(creature, def, p, u, _sub)
		local state = colossusState(creature, def)
		local a = creature.attack
		if not a.aimed then
			a.aimed = true
			local _, angle = pyreliskLatch(creature, def, p)
			a.facing = Vector3.new(math.cos(angle), 0, math.sin(angle))
			-- No telegraph of its own: the row's stock `coneTell` IS this
			-- move's warning, drawn along bossFacing at the pivot, and
			-- placeColossus now holds this boss's yaw0 on the tracked player
			-- one frame ahead of this latch - so the wedge that was drawn is
			-- the wedge that burns.
		end
		pyreliskWindupPose(state, "ventbreath", u)
	end,
	fire = function(creature, def, p, _now, _root)
		local state = colossusState(creature, def)
		local a = creature.attack
		local reach = p.range or p.reach or 250
		-- The jet, once, from the jaw rather than from the pivot: this body's
		-- mouth is 214 studs up and the whole read of the move is that the
		-- fire comes out of the head. Once and not per tick because the
		-- client's beam draws a puff every five studs, and at this reach that
		-- is fifty parts a tick for two and a half seconds.
		local head = PyreliskPath.headCFrame(state).Position
		fireEvent("beam", head, {
			to = state.center + a.facing * reach,
			skin = p.skin,
		})
	end,
	strike = function(creature, def, p, now, _dt, u, _root, _sub)
		local state = colossusState(creature, def)
		local a = creature.attack
		state.strike = u
		local reach = p.range or p.reach or 250
		if now >= (a.nextTickAt or 0) then
			a.nextTickAt = now + (p.tick or p.tickEvery or 0.35)
			local lo, hi = bossRoll(creature, def, p.damage)
			-- From the CENTRE at path height, not from the head: the cone
			-- test is horizontal and gates on height, and the players are on
			-- the floor the lake's surface defines.
			damagePlayersInCone(state.center, a.facing, reach, p.cone or math.rad(44), false, lo, hi, creature)
			-- The fire walking out along the wedge, one cheap ring a tick.
			local walk = reach * (0.3 + 0.6 * u)
			fireEvent("strikeHit", state.center + a.facing * walk, { radius = 18, skin = p.skin })
		end
		-- WHAT IT LEAVES. Three pools down the axis rather than one at the
		-- end: the move's whole job is to take a wedge of path away, and a
		-- single pool 250 studs out takes away a spot nobody stands on.
		if p.pool and not a.fired and u >= 0.95 then
			a.fired = true
			for _, along in { 0.45, 0.7, 0.95 } do
				spawnPool(creature, state.center + a.facing * (reach * along), p.pool, now)
			end
		end
	end,
	recover = function(creature, def, _p, u, _sub)
		pyreliskRecoverPose(colossusState(creature, def), u)
	end,
}

-- ASHFALL: the summit sheds, and marked ground lands under every player at
-- once. The one move in the book you cannot answer by being somewhere else.
--
-- The strike itself is an ordinary `barrage` - delegated, not reimplemented,
-- so its marks, its damage and its client effects are the ones every other
-- boss in the game uses. Only `fire` is borrowed: barrage's own windup and
-- strike PivotTo the model, which for a posed colossus would drag the
-- invisible authority hitbox around under a body drawn from the rig.
--
-- There is no direction to latch and nothing here re-aims: `everyone` places
-- one mark under each player at the moment the strike begins and those marks
-- do not move afterwards, so the telegraph still cannot lie. The latch is
-- still taken, for the body: it decides which way the mountain is facing when
-- it throws its arms up.
ATTACK_HANDLERS.ashfall = {
	windup = function(creature, def, p, u, _sub)
		local state = colossusState(creature, def)
		local a = creature.attack
		if not a.aimed then
			a.aimed = true
			pyreliskLatch(creature, def, p)
		end
		pyreliskWindupPose(state, "ashfall", u)
	end,
	fire = function(creature, def, p, now, root)
		local base = ATTACK_HANDLERS.barrage.fire
		if base then
			base(creature, def, p, now, root)
		end
	end,
	strike = function(creature, def, _p, _now, _dt, u, _root, _sub)
		colossusState(creature, def).strike = u
	end,
	recover = function(creature, def, _p, u, _sub)
		pyreliskRecoverPose(colossusState(creature, def), u)
	end,
}

-- SHARDHURL: it tears a slab off its own shell and throws it. Chip damage,
-- and the only thing in the book that reaches the outer band under the lip.
--
-- The throw is `volley`'s primitive (throwGlob: one queued rock that lands on
-- its own clock and takes the damage with it), but volley's own `fire` cannot
-- be used - it scatters around `root` at the moment of the strike, which
-- re-aims after the telegraph and cannot respect this arena's bands. So the
-- landings are chosen at WINDUP, marked there, and merely spent at `fire`.
ATTACK_HANDLERS.shardhurl = {
	windup = function(creature, def, p, u, _sub)
		local state = colossusState(creature, def)
		local a = creature.attack
		if not a.aimed then
			a.aimed = true
			local impact = pyreliskLatch(creature, def, p)
			a.landings = {}
			local count = p.count or 3
			for i = 1, count do
				-- Scattered around the committed point, then pulled back onto
				-- the path: the aim is capped at r200 (open sky), but a slab
				-- comes in on a low arc rather than straight down, so its
				-- scatter is allowed the full walkable band. What it may
				-- never do is land in the lake or off the arena entirely.
				local theta = math.random() * math.pi * 2
				local spread = math.sqrt(math.random()) * (p.spread or 30)
				local at = impact + Vector3.new(math.cos(theta) * spread, 0, math.sin(theta) * spread)
				local out = Vector3.new(at.X - state.center.X, 0, at.Z - state.center.Z)
				local d = math.clamp(out.Magnitude, PY_LAKE_R + 4, PY_PATH_OUT)
				local dir = if out.Magnitude > 0.01 then out.Unit else Vector3.xAxis
				local landing = state.center + dir * d
				table.insert(a.landings, landing)
				-- MARKED FROM THE WINDUP, each for its own whole lead time -
				-- the windup that is left plus that slab's flight. A mark
				-- fired when the rock is released would appear at the same
				-- moment as the rock and warn nobody.
				fireEvent("telegraph", landing, {
					kind = "mark",
					radius = p.radius,
					duration = p.windup + (i - 1) * (p.stagger or 0.25) + (p.flight or 1.2),
					skin = p.skin,
				})
			end
		end
		pyreliskWindupPose(state, "shardhurl", u)
	end,
	fire = function(creature, def, p, now, _root)
		local a = creature.attack
		for i, landing in (a.landings or {}) do
			throwGlob(
				creature,
				def,
				p,
				landing,
				(p.flight or 1.2) + (i - 1) * (p.stagger or 0.25),
				now,
				"strikeHit",
				"spine"
			)
		end
	end,
	strike = function(creature, def, _p, _now, _dt, u, _root, _sub)
		colossusState(creature, def).strike = u
	end,
	recover = function(creature, def, _p, u, _sub)
		pyreliskRecoverPose(colossusState(creature, def), u)
	end,
}

ATTACK_HANDLERS.lightsweep = {
	windup = function(creature, def, p, u, _sub)
		local state = colossusState(creature, def)
		local a = creature.attack
		if not a.stalk then
			-- Picked on the first windup frame rather than at `fire`, because
			-- the lean IS the telegraph: the stalk has to start moving before
			-- the light arrives or there is nothing to read.
			local root = nearestPlayerRoot(state.center)
			a.stalk = pickChoirStalk(state, root)
			local stalk = a.stalk and state.stalks[a.stalk]
			if stalk then
				local socket = state.center + NoctyssPath.socketPoint(a.stalk)
				local target = stalk.beamAngle
				if root then
					local to = root.Position - socket
					target = math.atan2(to.Z, to.X)
				end
				local arc = p.arc or math.rad(155)
				a.dir = if math.random() < 0.5 then 1 else -1
				a.arc = arc
				-- Start behind them so the beam sweeps THROUGH where they
				-- are, not at where they were.
				a.startAngle = target - a.dir * arc * 0.5
				-- ANTICIPATION. The stalk rocks back off the bearing it is
				-- about to sweep, so the lean reads as a wind-up rather than
				-- a drift - the same beat a thrown punch has.
			end
		end
		local stalk = a.stalk and state.stalks[a.stalk]
		if stalk then
			state.activeStalk = a.stalk
			stalk.lean = u
			stalk.beamAngle = a.startAngle or stalk.beamAngle
		end
	end,
	fire = function(creature, def, p, _now, _root)
		local state = colossusState(creature, def)
		local a = creature.attack
		local stalk = a.stalk and state.stalks[a.stalk]
		-- The stalk that spent the wind-up leaning may have been SHOT OUT
		-- during it, which in a fight about breaking lanterns is ordinary
		-- rather than an edge case. Without this the sweep fires out of a
		-- corpse: a beam drags across the arena from a point under the stone,
		-- lands nothing (strike and beamHits both refuse a dead stalk), and
		-- spends the full cooldown doing it.
		if stalk and (not stalk.alive or (stalk.douse or 0) > 0.5) then
			a.stalk, stalk = nil, nil
			state.activeStalk = nil
		end
		if stalk then
			stalk.lean = 1
			stalk.beamAngle = a.startAngle or stalk.beamAngle
			-- WHERE THE LIGHT COMES FROM, FROZEN. A leaning stalk carries its
			-- lantern along its own bearing, so a live apex travels a 20-stud
			-- radius arc across the sweep - a ~39-stud chord. The wedge the
			-- client drew from the position in this event would separate from
			-- the wedge the server tests until, past ~35 studs, the two no
			-- longer overlap at all: hit in the dark, safe in the light. One
			-- snapshot, used by the event below AND by every tick's hit test.
			a.apex = NoctyssPath.bulbPosition(state, a.stalk)
			-- The snap out of the wind-up, along the bearing the light is
			-- about to travel.
			-- THE ONLY THING THAT TELLS THE CLIENT A SWEEP IS HAPPENING.
			-- The hitbox is analytic (a bearing and a half-angle, tested per
			-- tick), so nothing about the beam exists as an object for the
			-- renderer to find: it gets the wedge's whole life in one line
			-- and animates it on its own clock. Sent at `fire` rather than
			-- per frame because the sweep is deterministic from here - the
			-- start bearing, the arc, the direction and how long it takes.
			fireEvent("choirBeam", a.apex, {
				angle = stalk.beamAngle,
				arc = a.arc,
				dir = a.dir,
				duration = p.duration,
				reach = NoctyssPath.BEAM_REACH,
				half = NoctyssPath.BEAM_HALF_ANGLE,
				skin = "lure",
			})
		end
		a.hit = {}
		a.nextTick = 0
	end,
	strike = function(creature, def, p, now, dt, _u, _root, _sub)
		local state = colossusState(creature, def)
		local a = creature.attack
		local stalk = a.stalk and state.stalks[a.stalk]
		if not stalk or not stalk.alive then
			return
		end
		stalk.lean = 1
		stalk.beamAngle = (stalk.beamAngle or 0) + a.dir * (a.arc / math.max(p.duration, 1e-3)) * dt
		-- Ticks rather than landing once: standing in a moving light is a
		-- continuous mistake, and a single hit would make the dodge binary.
		if now < (a.nextTick or 0) then
			return
		end
		a.nextTick = now + (p.tick or 0.45)
		local lo, hi = bossRoll(creature, def, p.damage)
		for _, player in Players:GetPlayers() do
			local character = player.Character
			local playerRoot = character and character:FindFirstChild("HumanoidRootPart")
			if playerRoot and NoctyssPath.beamHits(state, a.stalk, playerRoot.Position, p.girth or 3.0, a.apex) then
				PlayerService.damage(player, math.random(lo, hi), creature)
			end
		end
	end,
	finish = function(creature, def, _p, _now)
		local state = colossusState(creature, def)
		state.activeStalk = nil
	end,
}

-- DOUSEHUNT: every lantern goes out at once. Real darkness for `dark`
-- seconds, and then a strike where you were standing when the lights died.
-- The cheapest attack in the book and the one people will talk about: it
-- spawns nothing at all, it just stops being possible to see by.
--
-- The strike itself is an ordinary `barrage` - delegated, not reimplemented,
-- so its telegraphs, damage and client effects stay the ones every other
-- boss uses. All this handler owns is the dark.
-- LUREPULL: the stock pull, with a telegraph that is actually above ground.
-- The true lure flares and hauls the whole shelf toward the pit; the drag is
-- the shared handler's, and all this adds is the one thing it could not do -
-- announce itself somewhere the player can see.
ATTACK_HANDLERS.lurepull = {
	windup = function(creature, def, p, u, sub)
		local a = creature.attack
		if not a.told then
			a.told = true
			local state = colossusState(creature, def)
			-- At the rim, at shelf height, for the whole wind-up: the lure
			-- flaring is the warning, and it has to be read from the floor.
			fireEvent("telegraph", state.center + Vector3.new(0, 1.5, 0), {
				kind = "mark",
				duration = p.windup,
				radius = NoctyssPath.PIT_R + 3,
				skin = p.skin,
			})
		end
		local base = ATTACK_HANDLERS.pull.windup
		if base then
			base(creature, def, p, u, sub)
		end
	end,
	fire = ATTACK_HANDLERS.pull.fire,
	strike = ATTACK_HANDLERS.pull.strike,
	finish = ATTACK_HANDLERS.pull.finish,
}

ATTACK_HANDLERS.dousehunt = {
	windup = function(creature, def, p, u, sub)
		local state = colossusState(creature, def)
		-- Out over the last third of the windup: fast enough to feel like the
		-- choir being switched off, slow enough to be a tell.
		local douse = math.clamp((u - 0.62) / 0.38, 0, 1)
		for _, stalk in state.stalks do
			if stalk.alive then
				stalk.douse = douse
			end
		end
		local base = ATTACK_HANDLERS.barrage.windup
		if base then
			base(creature, def, p, u, sub)
		end
	end,
	fire = function(creature, def, p, now, root)
		local state = colossusState(creature, def)
		for _, stalk in state.stalks do
			if stalk.alive then
				stalk.douse = 1
			end
		end
		creature.relightAt = now + (p.dark or 1.6)
		-- The choir jolts as it goes out, so the dark has a moment rather
		-- than the lanterns simply ceasing to be drawn.
		-- The client blacks the arena down for exactly as long as the server
		-- holds the lanterns off: `dark` is the one number both sides run the
		-- scare on, so the light cannot come back before the fear does.
		fireEvent("choirDouse", state.center, { duration = p.dark or 1.6 })
		local base = ATTACK_HANDLERS.barrage.fire
		if base then
			base(creature, def, p, now, root)
		end
	end,
	strike = function(creature, def, p, now, dt, u, root, sub)
		local base = ATTACK_HANDLERS.barrage.strike
		if base then
			base(creature, def, p, now, dt, u, root, sub)
		end
	end,
	finish = function(creature, def, p, now)
		local base = ATTACK_HANDLERS.barrage.finish
		if base then
			base(creature, def, p, now)
		end
	end,
}

-- ---------------------------------------------------- Admiral Wrack: the bullet hell (2026-08-29)
-- Wrack is a STATIC GUN PLATFORM. He never approaches and never roams; the
-- fight is dodging dense patterns while putting damage into his four gun-deck
-- batteries (his book's `parts` ring). These six handlers are pattern
-- EMITTERS: they own the tell and the geometry, and hand the balls to
-- ProjectileService, which owns the simulation, the wire and the lifetime.
--
-- Three rules every one of them obeys, and the reasons they exist:
--
--  1. AIM IS LATCHED ONCE, AT WINDUP START (wrackAim). Re-reading the nearest
--     player per frame makes a fan chase whoever is momentarily closest,
--     which in a party teleports the cone around the arena mid-telegraph. A
--     tell that lies is a death the player cannot own.
--  2. THE TELL IS DRAWN FROM THE LATCHED GEOMETRY. Every Wrack row carries
--     `tell = false` (the documented opt-out) because the stock telegraph is
--     drawn at the boss's pivot before the handler picks a target - right for
--     a boss that swings around itself, wrong for one whose shot lands 80
--     studs away. Each windup draws its own, pointing where the shot goes.
--  3. NOTHING HERE TOUCHES THE PHASE MACHINE. No handler returns early out of
--     a phase, calls endBossAttack, or clears creature.attack. Every pattern
--     runs windup -> strike -> recover -> endBossAttack and therefore always
--     writes its cooldown, silenced or not.
local ProjectileService = require(script.Parent.ProjectileService)

-- How far past the roam disc a ball flies before it is retired. THE REBUILT
-- CAREENAGE (231a200) is walkable to r 132 with nothing standing on it, and
-- the palisade of grounded hulls starts at r 140, so this has to clear the
-- whole beach or the far edge becomes a safe room - which on a floor this big
-- would be an enormous one. `arena.radius` is 80, so 60 retires a ball at
-- r 140: eight studs past the last walkable sand, on the palisade itself.
--
-- AND IT IS NOW CONSISTENT WITH `lifetime`. Every ballistic row's lifetime is
-- authored as (140 - spawnAt) / speed, so a ball expires at almost exactly the
-- radius the bound would have retired it at. Before this retune the bound was
-- 88 against reaches of 106-183, so `lifetime` never fired on any of the eight
-- ballistic rows and was a dead knob that read as a live one. Overridable per
-- row as `p.bound`.
local WRACK_BOUND_MARGIN = 60
local WRACK_MUZZLE_LIFT = 5

-- THE GUN DECKS ARE THE GUNS - and since 2026-09-06 that is literal: every
-- ball in the fight leaves a live battery (see wrackDeckPositions and
-- ProjectileService's muzzleOf / deckRunOut), not a circle drawn round the
-- middle of the hull. Every pattern's ball count ALSO scales with how many
-- batteries still stand - slewfire included, which used to be the one
-- exception and is now not - so silencing one is visible on the screen the
-- same second it dies, in both the amount of fire and where it comes from.
-- Silencing all four stops the guns dead, which IS the melee burst window
-- (`vulnerableWhen = "partsDown"` opens the hull at the same instant). The 0.4
-- floor is a judgement call: a straight linear scale made the last battery a
-- formality, and no floor at all made three-down feel like the fight had
-- already ended.
local function wrackScale(creature, def, now: number): number
	local parts = def.parts
	if not parts or creature.partsAlive == nil then
		return 1
	end
	if creature.partsAlive <= 0 then
		-- ALL FOUR DOWN: the hull is open (vulnerableWhen = "partsDown") and
		-- the guns have nobody left to work them. `staggerFor` seconds of
		-- true silence - the stagger, the beat you use to close the distance
		-- and open your burst - and then a skeleton crew gets `windowFire` of
		-- the normal density back up. Dead air is not a bullet hell; a burst
		-- window you still have to dodge inside is.
		local downAt = creature.partsDownAt
		if not downAt or now - downAt < (def.staggerFor or 4) then
			return 0
		end
		return def.windowFire or 0.3
	end
	return 0.4 + 0.6 * (creature.partsAlive / math.max(parts.count, 1))
end

-- The latch. Fixes the firing bearing on the FIRST windup frame and never
-- looks again for the rest of the move (rule 1 above). Returns the bearing.
--
-- Note WHERE the fallback comes from. bossFacing() reads creature.yaw0, and
-- yaw0 is written by updateBoss's PROWL branch - which a `pose`d boss returns
-- before ever reaching. Wrack is planted with `speed = 0` and carries NO
-- pose, so he stays in the prowl branch and `approachAngle` still writes his
-- yaw0 every frame - but his `turnRate` is 0, so it writes the same value
-- back. BOSSFACING IS HIS FIXED SPAWN BEARING (+X, the bow), not a live one.
--
-- That is fine, and deliberate: a flagship careened on a shoal does not
-- pivot, and it is load-bearing rather than cosmetic - his four gun decks sit
-- at four bearings so that no position shows more than two, which is the
-- reason to move during the fight and is defeated entirely if he turns to
-- face you. All nine patterns aim at the player `wrackAim` latches and reach
-- this bearing only when the arena is empty.
--
-- Spelled out because the previous version of this comment asserted the
-- opposite. A note saying "bossFacing is live for this boss", sitting beside
-- a boss for whom it is frozen, is exactly what lets the next person
-- re-introduce a frozen-bearing bug while believing they had checked.
local function wrackAim(creature): Vector3
	local a = creature.attack
	if not a then
		return bossFacing(creature)
	end
	if not a.wrackAim then
		local centre = creature.anchor or creature.pos
		local root = nearestPlayerRoot(centre)
		a.wrackAim = if root then flatUnit(root.Position - centre) else bossFacing(creature)
		-- AND THE POINT, not only the bearing. Every aimed pattern now leaves
		-- a gun deck standing up to 40 studs off the hull's centre, and a
		-- bearing measured from the centre, fired from the bow, misses by that
		-- whole offset - by more than the width of its own cone at anything
		-- under 90 studs. The MARK is what is actually latched; the bearing
		-- above is what a caller with no muzzle of its own still asks for.
		a.wrackMark = if root then Vector3.new(root.Position.X, centre.Y, root.Position.Z) else centre + a.wrackAim * 90
	end
	return a.wrackAim
end

-- The latched target, re-aimed from a gun that is not at the centre.
local function wrackAimFrom(creature, from: Vector3): Vector3
	local a = creature.attack
	local mark = a and a.wrackMark
	if not mark then
		return wrackAim(creature)
	end
	local to = Vector3.new(mark.X - from.X, 0, mark.Z - from.Z)
	return if to.Magnitude > 0.001 then to.Unit else wrackAim(creature)
end

-- THE LIVE GUN DECKS, where they actually stand. `livingArms` is not
-- Kraken-specific despite the name - `partOf` and `socketIndex` are stamped by
-- spawnBossParts for every parts boss - so this reuses it rather than growing
-- a second parts list to keep in sync, which is the thing spawnBossParts'
-- `ringParts` comment refuses to do for exactly this reason. Sorted by socket,
-- so a wisp's round-robin is stable across volleys.
local function wrackDeckPositions(creature): { Vector3 }
	local out = {}
	for _, part in livingArms(creature) do
		table.insert(out, part.pos)
	end
	return out
end

-- The four decks as flat offsets from the arena centre - what a radial
-- pattern and the wisps read, and what picks the gun for an aimed one.
local function wrackDeckOffsets(creature, centre: Vector3): ({ Vector3 }, { Vector3 })
	local at = wrackDeckPositions(creature)
	local offsets = table.create(#at)
	for _, world in at do
		table.insert(offsets, Vector3.new(world.X - centre.X, 0, world.Z - centre.Z))
	end
	return offsets, at
end

-- THE GUN AN AIMED PATTERN FIRES FROM, latched like the aim and for the same
-- reason (rule 1 at the top of this section): the telegraph and the balls have
-- to leave the same brass, and a fan that changes which deck it is coming out
-- of halfway through its own windup is a tell that lies.
--
-- Chosen once, as the live battery best lined up with the latched bearing.
-- Held by POSITION rather than by index, because indices shift the moment a
-- deck dies: if the latched gun is broken before the volley lands, the shot
-- hands off to the nearest battery still standing instead of firing out of a
-- wreck. Returns the gun's world position and the bearing re-aimed from it,
-- or nil when nothing is left standing (the burst window - nothing fires).
local function wrackGunFor(creature): (Vector3?, Vector3)
	local a = creature.attack
	local centre = creature.anchor or creature.pos
	local aim = wrackAim(creature)
	local offsets, at = wrackDeckOffsets(creature, centre)
	if #at == 0 then
		return nil, aim
	end
	local want = a and a.wrackGunAt
	local best, bestScore = nil, -math.huge
	for i, world in at do
		local score
		if want then
			local dx, dz = world.X - want.X, world.Z - want.Z
			score = -(dx * dx + dz * dz)
		else
			local off = offsets[i]
			score = if off.Magnitude > 0.001 then (off.X * aim.X + off.Z * aim.Z) / off.Magnitude else -1
		end
		if score > bestScore then
			bestScore, best = score, world
		end
	end
	if a and not a.wrackGunAt then
		a.wrackGunAt = best
	end
	return best, wrackAimFrom(creature, best)
end

-- How far the furthest live deck stands from the centre. The ring and mark
-- tells are drawn round the muzzle LOCUS, which is no longer a circle of
-- radius `spawnAt` but that circle pushed out to each gun's own range.
local function wrackDeckReach(creature): number
	local centre = creature.anchor or creature.pos
	local far = 0
	for _, world in wrackDeckPositions(creature) do
		local dx, dz = world.X - centre.X, world.Z - centre.Z
		far = math.max(far, math.sqrt(dx * dx + dz * dz))
	end
	return far
end

-- World angle of a flat bearing, in ProjectileService's convention
-- (bearing(t) = cos t, 0, sin t). bossFacing's yaw0 runs the other way.
local function wrackAngle(dir: Vector3): number
	return math.atan2(dir.Z, dir.X)
end

-- Which patterns fire from ONE gun. The rest are all-round: broadside and
-- slewfire radiate from the arena centre with each ball born at the range of
-- the deck facing it, and wisps take one lantern per deck. See
-- ProjectileService's "firing from the guns" block for why the radial two
-- cannot simply be translated onto their decks.
local WRACK_AIMED = { grapeshot = true, chainshot = true, anchorsweep = true }

-- One volley out. Returns the ball count (0 when the decks are silent).
--
-- A silenced volley emits nothing and changes NOTHING else: the move still
-- completes its strike and recover and still goes on cooldown through
-- endBossAttack, so a player standing in the burst window cannot farm free
-- openings by keeping the batteries down.
local function wrackEmit(pattern: string, creature, def, p, now: number, gap: number?, phase: number?): number
	local scale = wrackScale(creature, def, now)
	if scale <= 0 then
		return 0
	end
	local centre = creature.anchor or creature.pos
	local lo, hi = bossRoll(creature, def, p.damage)
	-- Registers him for the closing beat on his first volley. A plain boss
	-- gets no collapse (that is the perch-holding colossus's death), so the
	-- gun decks going up one at a time is the fight's own ending.
	-- The batteries' OWN positions, as spawnBossParts placed them (see
	-- `creature.mountAt`), so the closing explosions land on the brass.
	ProjectileService.watch(creature, centre, creature.mountAt or {}, "cannon")
	-- THE BRASS FIRES. `centre` stays the arena centre and keeps its one
	-- remaining job (it is what `bound` is measured from); `decks` and
	-- `muzzle` are where the shot actually leaves. An aimed pattern gets one
	-- gun and a bearing re-aimed from it; the rest get the whole live list.
	local decks = wrackDeckOffsets(creature, centre)
	local aim = wrackAim(creature)
	local muzzle, flash = nil, nil
	if WRACK_AIMED[pattern] then
		local gun, from = wrackGunFor(creature)
		if gun then
			muzzle = Vector3.new(gun.X, centre.Y, gun.Z)
			aim = from
			-- The flash at the gun's own HEIGHT - the Deck battery is 35.7
			-- studs up. The balls stay on the flat flight plane, because the
			-- hit test is flat; only the muzzle burst knows about the mortar
			-- deck it came off.
			flash = gun + Vector3.new(0, WRACK_MUZZLE_LIFT, 0)
		end
	end
	return ProjectileService.emit(pattern, {
		owner = creature,
		centre = centre,
		muzzle = muzzle,
		decks = decks,
		origin = flash or (creature.model:GetPivot().Position + Vector3.new(0, WRACK_MUZZLE_LIFT, 0)),
		aim = aim,
		gap = gap or 0,
		phase = phase,
		scale = scale,
		bound = p.bound or (def.arena.radius + WRACK_BOUND_MARGIN),
		now = now,
		min = lo,
		max = hi,
	}, p)
end

-- WILL THIS VOLLEY ACTUALLY FIRE? `wrackEmit` returns 0 without emitting
-- anything while `wrackScale` is 0 - the `staggerFor` seconds of true silence
-- the moment the last battery falls - but the phase machine keeps running the
-- move, so every windup hook below used to draw its full telegraph into that
-- silence. The player spent the burst window they had just earned watching
-- anchorsweep's ring-and-lane resolve into nothing: a tell that lies, in the
-- one beat of the fight that is supposed to be a reward.
--
-- So each windup asks the same question the emitter will ask, and draws
-- nothing when the answer is no. It is asked per FRAME rather than once, so a
-- windup that starts inside the stagger and ends outside it still gets its
-- telegraph (late, but before the balls) - the failure that matters is shots
-- without a tell, not a tell without shots. `a.wrackTold` still makes it
-- exactly once per attack.
--
-- `os.clock()` is the clock `now` is measured on everywhere in this section
-- (updateBoss's `now`, and `partsDownAt` in kill()), and the windup hook is
-- the one place in the handler contract that is not handed it.
local function wrackWillFire(creature, def): boolean
	return wrackScale(creature, def, os.clock()) > 0
end

-- THE TELL, AND WHY IT IS SHAPED LIKE THIS. The client implements exactly
-- ten telegraph kinds (CreatureEventController.EVENTS.telegraph): slam, tail,
-- burst, pull, dive, snap, mark, ringTell, coneTell, gustTell - and anything
-- else falls through to a 3-stud flash at the point given. A bullet hell
-- warned by a 3-stud flash is not a bullet hell, it is a slot machine, so
-- every Wrack pattern is confined to a kind the client actually draws:
--   broadside -> "mark"     a pulsing disc out on the sand where the gap opens
--   slewfire  -> "ringTell" the annulus the spiral is about to stream out of
--   wisps     -> "mark"     the ring they are born from
--   the aimed patterns -> "coneTell", which marches rings out along `facing`.
-- An aimed pattern wider than a wedge draws SEVERAL coneTells across its arc,
-- because that is the only directional shape the client has.
--
-- THE SOUND IS WHY THE WEDGE COUNT IS SMALL. Sfx.play("bossTell", position)
-- sits at the TOP of EVENTS.telegraph, before any kind branch, so every
-- telegraph event plays the boss-tell one-shot - which is the whole reason
-- `tell = false` costs Wrack no audio here: he is not going silent, he is
-- re-emitting the same event at a position that is actually true. But it also
-- means N wedges is N simultaneous one-shots, and Sfx.play has no throttle
-- (it spawns a part per call). Three is the ceiling that still reads as one
-- thicker cue rather than a clipping mess. A `silent = true` flag on the
-- telegraph event - or a real arc/wall tell kind - would let a wide telegraph
-- be drawn properly; both are client-lane gaps, named rather than worked
-- around.
-- The loud layer (ProjectileFxController). `wrackTell` is Wrack's own tell
-- event and the only one that draws at full weight; `shape` picks the form.
-- A RING is the one that survives the camera's rear blind spot - at 34 deg
-- pitch nothing directly behind the player is on screen and bullets have no
-- off-screen indicator, so the patterns that can arrive from behind announce
-- themselves with a ring the player is standing inside rather than a wedge
-- they may be facing away from.
local function wrackRingTell(creature, p, radius: number)
	fireEvent("wrackTell", creature.anchor or creature.pos, {
		shape = "ring",
		radius = radius,
		duration = p.windup,
		skin = p.skin,
	})
end

local function wrackLaneTell(p, at: Vector3, aim: Vector3, width: number, length: number)
	fireEvent("wrackTell", at, {
		shape = "lane",
		aim = aim,
		width = width,
		length = length,
		duration = p.windup,
		skin = p.skin,
	})
end

-- `at` IS THE GUN, not the pivot. The client marches the wedge's rings out
-- along `facing` from the point it is given, so a cone drawn at the middle of a
-- 67-stud hull for a fan that leaves the bowsprit points at ground the shot
-- never crosses.
local function wrackConeTell(p, at: Vector3, aim: Vector3, arcDeg: number, wedges: number)
	local base = wrackAngle(aim)
	local arc = math.rad(arcDeg)
	local step = if wedges > 1 then arc / (wedges - 1) else 0
	for i = 0, wedges - 1 do
		local a = base - arc * 0.5 + step * i
		fireEvent("telegraph", at, {
			kind = "coneTell",
			duration = p.windup,
			radius = p.tellRange or 70,
			facing = Vector3.new(math.cos(a), 0, math.sin(a)),
			skin = p.skin,
		})
	end
end

-- Broadside: a ring of slow cannonballs with exactly ONE gap, fired `volleys`
-- times across the strike. The gap advances by `gapStep` between volleys AND
-- between broadsides (creature.wrackGap persists), so it is never twice in
-- the same place and pre-standing in it does not work. p: count, speed,
-- radius, damage, spawnAt, lifetime, gapDeg, gapStep, volleys, interval.
ATTACK_HANDLERS.broadside = {
	windup = function(creature, def, p, u, sub)
		local a = creature.attack
		-- THE GAP IS LATCHED WHETHER OR NOT THE VOLLEY FIRES, and separately
		-- from the tell: `strike` advances `a.wrackGapAt` and would index nil
		-- if a silenced windup had skipped this, and the walking gap is
		-- supposed to walk on across a silenced broadside too.
		if not a.wrackAimed then
			a.wrackAimed = true
			wrackAim(creature)
			creature.wrackGap = (creature.wrackGap or math.random() * math.pi * 2)
				+ math.rad(p.gapStep or 46) * (0.5 + math.random())
			a.wrackGapAt = creature.wrackGap
		end
		if not a.wrackTold and wrackWillFire(creature, def) then
			a.wrackTold = true
			-- Two cues, because a ring with a hole in it needs both: the ring
			-- itself (loud, and readable from any facing), then the gap. Both
			-- are drawn OUTSIDE the muzzle locus - which is no longer a plain
			-- circle of radius `spawnAt` but that circle pushed out to each
			-- live deck's own range - so the cue never lands inside the wall
			-- it is announcing.
			local mark = wrackDeckReach(creature) + (p.spawnAt or 16) + (p.markAt or 22)
			wrackRingTell(creature, p, mark)
			-- THE ANSWER, DRAWN: a disc out on the sand where the gap opens.
			local centre = creature.anchor or creature.pos
			local dir = Vector3.new(math.cos(a.wrackGapAt), 0, math.sin(a.wrackGapAt))
			fireEvent("telegraph", groundedPos(centre + dir * mark, 0), {
				kind = "mark",
				duration = p.windup,
				radius = math.rad(p.gapDeg or 34) * mark * 0.5,
				skin = p.skin,
			})
		end
		creature.model:PivotTo(poseCFrame(creature, sub + 0.25 * u, 0, math.rad(15) * u))
	end,
	fire = function(creature, def, p, now)
		local a = creature.attack
		wrackEmit("broadside", creature, def, p, now, a.wrackGapAt)
		a.wrackLeft = (p.volleys or 3) - 1
		a.wrackNextAt = now + (p.interval or 1.1)
	end,
	strike = function(creature, def, p, now, _dt, _u, _root, sub)
		local a = creature.attack
		if a.wrackLeft > 0 and now >= a.wrackNextAt then
			a.wrackLeft -= 1
			a.wrackNextAt = now + (p.interval or 1.1)
			-- The gap walks on. gapStep is deliberately not a divisor of 360:
			-- the safe lane never returns to where it just was.
			a.wrackGapAt += math.rad(p.gapStep or 46)
			creature.wrackGap = a.wrackGapAt
			wrackEmit("broadside", creature, def, p, now, a.wrackGapAt)
		end
		creature.model:PivotTo(poseCFrame(creature, sub + 0.25, math.sin(now * 26) * math.rad(2), math.rad(15)))
	end,
}

-- Grapeshot: a fast aimed fan at the latched player. Punishes standing still
-- in the open - it is quick, so the dodge happens during the tell. A second
-- burst (p.bursts) reuses the SAME bearing offset half a pellet, filling the
-- first burst's lanes. p: pellets, fanDeg, speed, radius, damage, spawnAt,
-- lifetime, bursts, burstGap.
ATTACK_HANDLERS.grapeshot = {
	windup = function(creature, def, p, u, sub)
		local a = creature.attack
		if not a.wrackTold and wrackWillFire(creature, def) then
			a.wrackTold = true
			-- One wedge, from the gun that is going to fire it: the fan is a
			-- wedge's width, and it leaves one battery.
			local gun, from = wrackGunFor(creature)
			wrackConeTell(p, gun or creature.model:GetPivot().Position, from, 0, 1)
		end
		creature.model:PivotTo(poseCFrame(creature, sub, 0, math.rad(-9) * u))
	end,
	fire = function(creature, def, p, now)
		local a = creature.attack
		wrackEmit("grapeshot", creature, def, p, now, 0, 0)
		a.wrackLeft = (p.bursts or 1) - 1
		a.wrackNextAt = now + (p.burstGap or 0.35)
	end,
	strike = function(creature, def, p, now, _dt, _u, _root, sub)
		local a = creature.attack
		if a.wrackLeft > 0 and now >= a.wrackNextAt then
			a.wrackLeft -= 1
			a.wrackNextAt = now + (p.burstGap or 0.35)
			wrackEmit("grapeshot", creature, def, p, now, 0, 0.5)
		end
		creature.model:PivotTo(poseCFrame(creature, sub + 0.15, 0, math.rad(6)))
	end,
}

-- Chainshot: pairs of balls linked by a spinning chain. The gap between a
-- pair LOOKS like a lane and is the hitbox; the real lane is between pairs,
-- and the spin opens and closes it on a beat you can count. p: pairs, fanDeg,
-- chain, chainRadius, spinDeg, speed, radius, damage, spawnAt, lifetime.
ATTACK_HANDLERS.chainshot = {
	windup = function(creature, def, p, u, sub)
		local a = creature.attack
		if not a.wrackTold and wrackWillFire(creature, def) then
			a.wrackTold = true
			-- One wedge per pair, so the tell shows where the PAIRS go and
			-- the lanes between them read as the lanes they are. Drawn from
			-- the gun the pairs actually leave, and capped at three wedges
			-- because each one is another bossTell one-shot (see above).
			local gun, from = wrackGunFor(creature)
			wrackConeTell(
				p,
				gun or creature.model:GetPivot().Position,
				from,
				p.fanDeg or 120,
				math.min(p.pairs or 3, 3)
			)
		end
		creature.model:PivotTo(
			poseCFrame(creature, sub + 0.3 * u, math.sin(u * 22) * math.rad(3) * u, math.rad(11) * u)
		)
	end,
	fire = function(creature, def, p, now)
		wrackEmit("chainshot", creature, def, p, now)
	end,
	strike = function(creature, _def, _p, now, _dt, _u, _root, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.3, math.sin(now * 18) * math.rad(2), math.rad(11)))
	end,
}

-- Slewfire: a continuous spiral streaming off a rotating deck. The deck angle
-- is the tell and the answer both - the model turns with it, so you can read
-- the rotation and walk against it to cross the arms the short way. p: arms,
-- every, spinDeg, speed, radius, damage, spawnAt, lifetime.
ATTACK_HANDLERS.slewfire = {
	windup = function(creature, def, p, u, sub)
		local a = creature.attack
		-- Latched even when the decks are silent: `strike` adds the spin to
		-- `a.wrackGapAt` every tick and cannot be handed a nil.
		if not a.wrackAimed then
			a.wrackAimed = true
			a.wrackGapAt = wrackAngle(wrackAim(creature))
		end
		if not a.wrackTold and wrackWillFire(creature, def) then
			a.wrackTold = true
			-- The annulus has to cover the whole muzzle locus, which runs from
			-- `spawnAt` out to `spawnAt` + the furthest live deck's range.
			fireEvent("telegraph", creature.anchor or creature.pos, {
				kind = "ringTell",
				duration = p.windup,
				radius = wrackDeckReach(creature) + (p.spawnAt or 14) + 4,
				inner = math.max(0, (p.spawnAt or 14) - 4),
				skin = p.skin,
			})
		end
		-- Roll, not yaw, for the same reason the strike below no longer slews:
		-- a 20-degree turn through poseCFrame's yawOffset swung the drawn
		-- bowsprit battery thirteen studs off the hitbox standing at its mount.
		creature.model:PivotTo(poseCFrame(creature, sub, 0, math.rad(7) * u))
	end,
	fire = function(creature, _def, p, now)
		local a = creature.attack
		a.wrackNextAt = now
		a.wrackSpin = math.rad(p.spinDeg or 78)
	end,
	strike = function(creature, def, p, now, _dt, _u, _root, sub)
		local a = creature.attack
		local every = math.max(p.every or 0.14, 0.05)
		while now >= a.wrackNextAt do
			a.wrackNextAt += every
			wrackEmit("slewfire", creature, def, p, now, a.wrackGapAt)
			a.wrackGapAt += a.wrackSpin * every
		end
		-- THE HULL DOES NOT TURN WITH THE GUNS, and must not. This used to feed
		-- `-a.wrackGapAt - creature.yaw0` into poseCFrame's yawOffset, which
		-- ADDS to yaw0 - a full revolution of the drawn ship every 4-5 seconds,
		-- dragging the four `Wrack_Battery*` objects the player aims at away
		-- from the four `wrack_battery` hitboxes, which `parts.at = "mounts"`
		-- resolved ONCE against yaw0 at spawn and which never move. His row
		-- says it outright ("HE MUST NOT TURN... only correct for a hull that
		-- stays put") and so does WrackBodyController ("He does NOT slew").
		-- The spiral's rotation is legible in the balls themselves - that is
		-- what the player reads to walk against it - so the hull only has to
		-- lean into the recoil.
		creature.model:PivotTo(poseCFrame(creature, sub, 0, math.rad(6)))
	end,
}

-- Wisps: a few slow homing lantern-lights. Weak, and that is the point - they
-- deny standing still. Each turns at a fixed rate (15.6 studs of turn radius
-- at the authored speed) and a player has none, so a circle run tighter than
-- that makes every one of them overshoot: the answer is a movement, not a
-- place, and it works on the bare floor the rebuild left. One lantern lifts
-- off each live deck. p: count, speed, homingDeg, radius, damage, spawnAt,
-- lifetime, spreadDeg.
ATTACK_HANDLERS.wisps = {
	windup = function(creature, def, p, u, sub)
		local a = creature.attack
		if not a.wrackTold and wrackWillFire(creature, def) then
			a.wrackTold = true
			wrackAim(creature)
			-- The ring they are born from, which is now the DECKS' ring: one
			-- lantern lifts off each live battery, so the mark has to reach
			-- the furthest of them or it points at empty hull.
			fireEvent("telegraph", creature.anchor or creature.pos, {
				kind = "mark",
				duration = p.windup,
				radius = wrackDeckReach(creature) + (p.spawnAt or 12),
				skin = p.skin,
			})
		end
		creature.model:PivotTo(poseCFrame(creature, sub - 0.35 * u, 0, math.rad(-7) * u))
	end,
	fire = function(creature, def, p, now)
		wrackEmit("wisps", creature, def, p, now)
	end,
}

-- Anchorsweep: the one big telegraph. A heavy arc across half the arena, the
-- balls overlapping into a wall you cannot thread - the answer is the OTHER
-- half, and the long windup exists so you can get there. `ripple` gives one
-- end a head start so the arc visibly sweeps, which also leaves the trailing
-- end passable for a beat if you commit to it. p: count, arcDeg, speed,
-- radius, damage, spawnAt, lifetime, ripple.
ATTACK_HANDLERS.anchorsweep = {
	windup = function(creature, def, p, u, sub)
		local a = creature.attack
		if not a.wrackTold and wrackWillFire(creature, def) then
			a.wrackTold = true
			-- THE ONE BIG TELEGRAPH, and the one pattern that can arrive from
			-- the camera's rear blind spot. So it gets a RING first - drawn
			-- around the player's own ground, legible whichever way they face
			-- - and then a lane naming the half about to become a wall.
			local gun, from = wrackGunFor(creature)
			wrackRingTell(creature, p, wrackDeckReach(creature) + (p.spawnAt or 16) + (p.tellReach or 30))
			wrackLaneTell(p, gun or creature.model:GetPivot().Position, from, p.tellWidth or 96, p.tellRange or 90)
		end
		local e = smoothstep(u)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.9 * e, 0, math.rad(-24) * e))
	end,
	fire = function(creature, def, p, now)
		wrackEmit("anchorsweep", creature, def, p, now)
	end,
	strike = function(creature, _def, _p, _now, _dt, u, _root, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.9 * (1 - u), 0, math.rad(26) * (1 - u)))
	end,
}

local function spawnBossParts(creature, def)
	local parts = def.parts
	local row = Creatures.items[parts.row]
	if not row then
		warn(string.format("[CreatureService] boss %q parts name unknown row %q", def.id, parts.row))
		return
	end
	-- THE SAME CENTRE THE POSE USES, not the raw anchor. `spawn` lifts a
	-- creature by half its own thickness and `colossusState` snaps that back
	-- to the waterline so the arena's authored heights hold. Publishing the
	-- unlifted anchor here put every client-drawn lantern ~5.5 studs above
	-- the hitbox the server stands at that socket - which, against a
	-- 2.6-stud lantern, is every shot in the fight missing what it hit.
	local centre = creature.anchor or creature.pos
	if creature.pose and creature.pose.center then
		centre = creature.pose.center
	end
	-- WHERE THEY STAND. `at = "sockets"` takes the AUTHORED offsets from the
	-- arena row (BossArenas), so the Lantern Choir grows out of the arena's
	-- seven carved collars instead of a guessed circle - the one thing that
	-- would make the whole set-piece read as a mistake. Anything without it
	-- keeps the even ring, which is the Kraken's tentacles.
	local offsets = nil
	if parts.at == "sockets" then
		local arena = def.islandId and BossArenas.items[def.islandId]
		offsets = arena and arena.sockets
	end
	-- `at = "mounts"` is the THREE-DIMENSIONAL form, authored on the BOSS row
	-- rather than the arena's. `sockets` cannot express what it is for: those
	-- offsets live on the arena, are two-dimensional, and force `centre.Y`.
	-- Wrack's four gun decks sit at four different bearings AND four different
	-- heights - a 25-stud spread, deliberate, so that no position on the shoal
	-- shows more than two of them, which is the whole reason to move. Flatten
	-- that onto an even ring and you get four stand-ins orbiting a hull whose
	-- brass is visibly somewhere else, in a fight whose premise is "shoot the
	-- gun decks". Boss-LOCAL, so the offsets travel with the hull's authored
	-- frame instead of the world's axes.
	local mounts = if parts.at == "mounts" then parts.mounts else nil
	local count = parts.count
	if offsets then
		count = math.min(count, #offsets)
	elseif mounts then
		count = math.min(count, #mounts)
	elseif parts.bearings then
		-- A short bearings list would silently plant a ring with holes in it
		-- and, worse, index nil into the position maths below. Clamped and
		-- said out loud, because "the fan is one arm short" is not something
		-- anybody would ever notice from inside the fight.
		if #parts.bearings ~= count then
			warn(
				string.format(
					"[CreatureService] boss %q has %d bearings for %d parts - planting %d",
					def.id,
					#parts.bearings,
					count,
					math.min(count, #parts.bearings)
				)
			)
		end
		count = math.min(count, #parts.bearings)
	end
	-- THE TRUE LURE: one of them, redrawn every time the choir grows back, so
	-- "which light is real" is never answered twice by the same socket.
	local marked = if parts.mark then math.random(1, count) else nil
	local planted, markedPlanted = 0, false
	-- THE CHOIR, AS A LIST. `updateChoir` needs these seven every frame and
	-- used to find them by scanning the whole world; this is the same seven,
	-- written down once where they are made. Built for every parts boss but
	-- published (below) only for a marked ring, so nothing else grows a
	-- second, unowned copy of its parts list to keep in sync.
	local ringParts = {}
	-- WHERE THE MOUNTED PARTS ACTUALLY LANDED, in world space and in socket
	-- order. Resolved once here and published on the record because the death
	-- beat needs the same points long after the parts themselves are gone -
	-- and recomputing them anywhere else would be a second copy of the mount
	-- transform and the sand convention above, to be got wrong separately.
	local mountAt = {}
	for i = 1, count do
		local at
		if mounts then
			-- Resolved ONCE, against the heading the boss spawned with. That
			-- is correct only for a boss that does not turn, which is exactly
			-- what this mode is for - a hull careened on a shoal, a thing
			-- wedged in rock. A colossus that slews needs its parts re-placed
			-- as it turns, and should not use this mode until that exists.
			--
			-- The rotation is `CFrame.Angles(0, yaw0, 0)` written out, the
			-- same one `poseCFrame` applies to the model, so a mount lands
			-- where the artist put it on the drawn hull.
			local m = mounts[i]
			local cos, sin = math.cos(creature.yaw0 or 0), math.sin(creature.yaw0 or 0)
			-- THE CONVENTION, IN FULL (and it is the same sentence in the
			-- `mounts` comment on the boss row): a mount's Y is the piece's
			-- own CENTRE, measured from the sand of the DRAWN hull.
			--
			-- Both halves of that need a correction here, and neither used to
			-- get one.
			--
			-- SAND. `spawn` lifts a creature by half its own thickness before
			-- it stands, so the record's Y is the pivot and `- halfThickness`
			-- takes it back down to the sand. But nothing DRAWS the hull at
			-- the record's Y: every pose in the fight goes through
			-- `poseCFrame(creature, sub, ...)` with `sub = -def.submerge`, so
			-- the ship the player sees - and the brass they aim at - sits
			-- `submerge` studs lower than that. Reference the same sand the
			-- artist's mounts were measured against, or every mount rides
			-- 2.8 studs above its own gun.
			--
			-- `halfThickness` is read off the record and never baked into the
			-- data, because it is measured from the server's own pack model
			-- and moves the day that pack is re-imported.
			local sand = centre.Y - (creature.halfThickness or 0) - (def.submerge or 0)
			at = Vector3.new(centre.X + m.X * cos + m.Z * sin, sand + m.Y, centre.Z - m.X * sin + m.Z * cos)
			-- CENTRE. `spawn` rests a creature ON the point it is handed - it
			-- adds the new body's own halfThickness and SURFACE_OFFSET, which
			-- is right for a fish put down on the ground and wrong for a
			-- battery hung on a mount, where it lifts the piece by its own
			-- half-height and the taller the piece the further off it is. The
			-- correction is applied AFTER the spawn (below), because the
			-- thickness being corrected for is measured from the model spawn
			-- has not built yet.
		elseif offsets then
			at = Vector3.new(centre.X + offsets[i].X, centre.Y, centre.Z + offsets[i].Z)
		else
			-- `bearings` is the AUTHORED form of the ring: an explicit list of
			-- world bearings in radians (+X = 0, +Z = pi/2), one per part, in
			-- the order they are planted - so entry `i` IS socket index `i`,
			-- which is the number stamped below and the number the client
			-- claims its arm by. `ring` still gives the radius; only the
			-- angles move here.
			--
			-- WHY IT EXISTS. The even fallback plants part `i` at
			-- (i / count) * 2pi, which for count 8 puts part #2 at exactly
			-- pi/2 - dead on +Z. On the Maelstrom that bearing is the landing
			-- stack the island generator deliberately keeps clear, and the
			-- ring's 46 studs put the arm two studs from the spawn point:
			-- every player arriving at the finale materialised inside a
			-- tentacle's slam. An even circle cannot express "not there"
			-- without a per-island special case buried in generic code.
			local angle
			if parts.bearings then
				angle = parts.bearings[i]
			else
				angle = (i / count) * math.pi * 2
			end
			at = Vector3.new(centre.X + math.cos(angle) * parts.ring, centre.Y, centre.Z + math.sin(angle) * parts.ring)
		end
		local model = CreatureService.spawn(row, at, nil, "Neutral", {
			noLinger = true,
			suppressDrops = true,
			bounty = 0.5,
		})
		local part = byModel[model]
		if part then
			if mounts then
				-- THE MOUNT IS THE PIECE'S CENTRE, and `spawn` has just rested
				-- this body ON it (`at.Y + halfThickness + SURFACE_OFFSET`) as
				-- though the mount were a floor. Put the centre back where the
				-- artist measured it - the only place it can be done, since
				-- `halfThickness` is measured off the model spawn just built.
				part.pos = at
				model:PivotTo(restCFrame(part))
				-- ...and remember where they stand, for the death beat: the
				-- closing volley of gun-deck explosions has to go off on the
				-- brass, not on an even circle drawn round the hull.
				table.insert(mountAt, at)
			end
			planted += 1
			markedPlanted = markedPlanted or i == marked
			part.partOf = creature
			part.socketIndex = i
			part.marked = i == marked
			-- A RING WAKES STAGGERED. `updateTentacle` reads
			-- `nextSlamAt or 0`, so a freshly planted arm is off cooldown the
			-- instant it exists: eight arms spawned in one loop iteration all
			-- pass their own-initiative test on the same frame and the ring
			-- regrows into a single simultaneous eight-arm slam that nothing
			-- ordered and nothing telegraphs as a pattern. Seeded here rather
			-- than in `spawn` because it is the RING that has the problem -
			-- one arm waking ready is fine, and is how the fight opens.
			-- Harmless on any other parts row: nothing else reads the field.
			part.nextSlamAt = os.clock() + randomBetween(1.5, 4.0)
			table.insert(ringParts, part)
			model:SetAttribute(ATTR_SOCKET_INDEX, i)
			-- The client needs this to draw the off-rhythm pulse, which IS
			-- the tell - so it is published, not hidden. The honest
			-- alternative (publishing each bulb's phase offset) carries the
			-- same information in a form that is harder to read.
			model:SetAttribute(ATTR_TRUE_LURE, part.marked)
			model:SetAttribute(ATTR_POSE_CENTER, centre)
			if parts.mark then
				model:SetAttribute(ATTR_POSE, "choir_stalk")
			end
		end
	end
	-- Counted from the parts that actually REGISTERED, not from the loop's
	-- trip count: the window opens on exactly one event - `kill` seeing the
	-- marked stalk - and there is no timeout anywhere in the fight. A marked
	-- stalk that never planted is a boss nothing can ever make vulnerable
	-- again, with a party hitting it forever and no error to explain why.
	creature.partsAlive = planted
	creature.partsDownAt = nil
	-- The mounted parts' world points, kept for the death beat (see above).
	-- nil for every other placement mode, and the one reader falls back.
	creature.mountAt = if #mountAt > 0 then mountAt else nil
	-- Replaced wholesale, never appended to: the previous choir is gone by
	-- the time a new one stands (`closeMaw` withdraws the survivors), and a
	-- list that accumulated across cycles would be the leak this replaces.
	creature.choirParts = if parts.mark then ringParts else nil
	if parts.mark and planted > 0 and not markedPlanted then
		warn(string.format("[CreatureService] boss %q planted no true lure - opening its window", def.id))
		creature.mawDueAt = os.clock()
	end
	-- A new choir is standing: nothing has been shot yet.
	creature.choirKilled = 0
	-- The ring is back up, so the window is shut again.
	creature.model:SetAttribute(ATTR_EXPOSED, nil)
	creature.choir = parts.mark == true
	creature.trueLure = marked
	if creature.choir and creature.pose then
		-- A fresh choir stands up: clear the last cycle's fallen shapes.
		creature.pose.trueLure = marked
		for _, stalk in creature.pose.stalks do
			stalk.alive, stalk.fall, stalk.douse, stalk.lean = true, 0, 0, 0
		end
	end
end

-- ---------------------------------------------------------- the maw window
--
-- The three-beat loop's third beat, and the only time she can be hurt:
-- break the true lure, the maw comes up through the pit, the party fights
-- INSIDE it until the jaw closes. Then the choir grows back with a different
-- true lure and the question is asked again.
local function openMaw(creature, def, now: number)
	local state = colossusState(creature, def)
	creature.mawOpen = true
	creature.mawUntil = now + ((def.parts and def.parts.window) or 12)
	creature.mawDueAt = nil
	creature.untargetable = false
	creature.model:SetAttribute(ATTR_EXPOSED, true)
	-- She surfaces facing a gap between the shadow fins, aimed at whoever
	-- broke the lure: the fight comes to meet the party, not a rock.
	local root = nearestPlayerRoot(creature.anchor or creature.pos)
	if root then
		local to = root.Position - state.center
		state.mawYaw = NoctyssPath.laneFor(math.atan2(to.Z, to.X))
	end
	-- At the PIT'S MOUTH, not at hers: this fires before `mawRise` has moved,
	-- so `mawMouth` is still 40-odd studs down, and the fight's payoff was
	-- announcing itself - burst, shockwave, camera shove - under the arena.
	fireEvent("bossStagger", state.center + Vector3.new(0, 1, 0), {
		name = def.name,
		duration = creature.mawUntil - now,
	})
end

local function closeMaw(creature, def, now: number)
	local state = colossusState(creature, def)
	creature.mawOpen = false
	creature.mawUntil = nil
	creature.untargetable = true
	-- CLEARED, not set false: the HUD only ever asks `Exposed == true` (both
	-- read as sealed), but every other earned window in this file - the
	-- stagger's, the collapse's - removes the attribute, and one boss leaving
	-- a stale `false` behind is the kind of difference someone later reads as
	-- meaning something.
	creature.model:SetAttribute(ATTR_EXPOSED, nil)
	-- THE BITE. Whoever is still standing in her mouth when it shuts wears
	-- it: the window is generous, and leaving is the player's job.
	-- Player MAX_HEALTH is 100: at 120-170 this was a guaranteed kill with no
	-- counterplay for anyone knocked back into the mouth on the last beat.
	-- 70-95 still ends a hurt player and still means "leave when it starts to
	-- shut", which is the read the window is teaching.
	local lo, hi = bossRoll(creature, def, { 70, 95 })
	-- ...AND IT ACTUALLY LANDS. `bypassIframe` skips the ordinary contact
	-- window but NOT the previous bypassing burst's, and bursts gate each
	-- other for 0.35s (PlayerService `lastBurst`). She keeps attacking while
	-- the jaw shuts, so a strobe ring or a feeler landing a fraction before
	-- the close swallowed the bite outright - and the one lesson the window
	-- teaches, "leave when it starts to shut", was enforced or not by a coin
	-- flip nobody could see. What could not be delivered is written down and
	-- re-offered by `updateNoctyss` until it lands. The ROLL is kept: the
	-- bite happened at the close, only its delivery is late.
	local owed = nil
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and NoctyssPath.insideMouth(state, root.Position) then
			local amount = math.random(lo, hi)
			if not PlayerService.damage(player, amount, creature, { bypassIframe = true }) then
				owed = owed or {}
				table.insert(owed, { player = player, amount = amount })
			end
		end
	end
	creature.biteOwed = owed
	-- 0.6s, comfortably past one 0.35s burst window and far short of anything
	-- a player would read as a delayed second hit.
	creature.biteOwedUntil = if owed then now + 0.6 else nil
	fireEvent("slam", NoctyssPath.mawMouth(state).Position, { radius = 16, skin = "ink" })
	-- The head jars on its own bite, so the jaw shutting is something she
	-- does rather than a number easing to zero.
	NoctyssPath.shudder(state, 1.2)
	-- Cleared here, not only in `openMaw`. A marked-stalk death remembered
	-- across a close would re-open the window on the next frame - no dark
	-- beat, no new choir - and the regrow would then fire INSIDE that window.
	-- Unreachable today, but only because three unrelated invariants happen
	-- to hold, and two lines is cheaper than depending on them.
	creature.mawDueAt = nil
	clearMawFloor(creature)
	-- THE CHOIR SINKS WITH HER. Only the MARKED stalk had to die to open this
	-- window, so up to six were still standing - and the regrow gate waits on
	-- `partsAlive == 0`. Without this the fight ran exactly ONE cycle and then
	-- stopped dead: no regrow, no new true lure, and a boss that refuses all
	-- damage outside a window that could never open again. Taking the
	-- survivors down here is also the fiction - her fingers withdraw when she
	-- does - and it is what lets the next choir put the answer somewhere else.
	removeOwnedParts(creature)
	creature.choirDueAt = now + ((def.parts and def.parts.regrow) or 5)
end

-- THE CHOIR'S BEAT UNDER A BORROWED MOVE, REMOVED - and this is the headstone
-- rather than the code. Strobewave and abysscall are ordinary `barrage`
-- entries, and the punctuation that used to live here jolted the ring on the
-- move's own `interval` by writing `stalk.impulse`. That field is not
-- replicated (see the note above `mawFloor`), so the jolt moved nothing any
-- player could see; the recoils that survive are the ones the CLIENT raises
-- off the hits it watches land. The comment outlived its function and had run
-- headlong into the one below it, mid-sentence, describing machinery that no
-- longer exists.

-- The whole Gloomtrench fight, in one pass: keep the choir standing, answer
-- a broken lure, run the maw window, and let the book pick what happens next.
-- Deliberately its own function rather than more branches inside updateBoss -
-- nothing about this boss shares the prowl/entrench machinery, because she
-- never moves and is never reachable except inside her own mouth.
local function updateNoctyss(creature, def, now: number, dt: number, root, player, dist: number)
	local state = colossusState(creature, def)
	-- THE SHAPE'S CLOCK, ADVANCED. Sway, breath and every flinch are terms in
	-- `state.time`, and the bulb they move IS the stalk's hitbox: left at 0
	-- the server would stand each hitbox at the un-swayed lantern while the
	-- client drew a swaying one, and a shot through the light you can see
	-- would miss for reasons nothing in either log could explain. The module's
	-- clock is server time on both sides, so feeding it here is what keeps
	-- them the same object.
	state.time = NoctyssPath.clock()
	hideColossusModel(creature)
	updateChoir(creature, state, dt)

	-- The lanterns come back on after a dousehunt.
	if creature.relightAt and now >= creature.relightAt then
		creature.relightAt = nil
		for _, stalk in state.stalks do
			if stalk.alive then
				stalk.douse = 0
			end
		end
		-- The choir shudders back alight - inward, against the way it flinched
		-- when the lights died, so the pair reads as one breath out and in.
	end

	-- A FALSE lure was broken: it flares white, and the trench takes a swing
	-- at whoever broke it. Answered one frame after the kill, so the player
	-- is still looking at the light they shot when the answer arrives.
	for _, at in creature.flareAt or {} do
		-- WHITE, not black. This borrowed `inkBlast` until now, which blots
		-- the screen dark - the exact opposite of a lantern going off in your
		-- face, and the one moment in the fight the trench is bright.
		fireEvent("lureFlare", at, { radius = 15, skin = "lure" })
		-- The flare belongs at the lantern, but the DAMAGE has to reach the
		-- floor. A stalk's position IS its bulb, ~30 studs up, and the AOE's
		-- default height tolerance is 6 - so this burst was hitting nobody,
		-- every time, and breaking a false lure cost the party nothing at all.
		local ground = Vector3.new(at.X, (creature.anchor or creature.pos).Y, at.Z)
		fireEvent("slam", ground, { radius = 12, skin = "ink" })
		local lo, hi = bossRoll(creature, def, { 40, 58 })
		damagePlayersInRadius(ground, 15, lo, hi, creature, 0.35)
	end
	creature.flareAt = nil

	-- The TRUE lure broke: she comes up.
	if creature.mawDueAt and not creature.mawOpen then
		openMaw(creature, def, now)
	end

	if creature.mawOpen then
		state.mawRise = math.min((state.mawRise or 0) + dt * 0.55, 1)
		-- The jaw opens once she is most of the way up, and starts shutting
		-- over the last two seconds. THE CLOSING MOUTH IS THE TIMER: nobody
		-- should need a UI bar to know how long they have left in there.
		local left = (creature.mawUntil or now) - now
		local target = 1
		if state.mawRise < 0.75 then
			target = 0
		elseif left < 2.0 then
			target = math.max(left / 2.0, 0)
		end
		state.mawGape = (state.mawGape or 0) + (target - (state.mawGape or 0)) * math.min(dt * 3.0, 1)
		placeMawFloor(creature, state)
		if now >= (creature.mawUntil or now) then
			closeMaw(creature, def, now)
		end
	else
		creature.untargetable = true
		state.mawGape = math.max((state.mawGape or 0) - dt * 1.6, 0)
		state.mawRise = math.max((state.mawRise or 0) - dt * 0.5, 0)
	end

	-- A BITE THAT COULD NOT BE DELIVERED AT THE CLOSE. See `closeMaw`: the
	-- burst window that swallowed it is 0.35s, so this resolves within a
	-- handful of frames, and a player who died in the meantime simply fails
	-- forever and is dropped at the deadline.
	if creature.biteOwed then
		if now >= (creature.biteOwedUntil or 0) then
			creature.biteOwed, creature.biteOwedUntil = nil, nil
		else
			local pending = nil
			for _, owed in creature.biteOwed do
				local landed = PlayerService.damage(owed.player, owed.amount, creature, { bypassIframe = true })
				if not landed then
					pending = pending or {}
					table.insert(pending, owed)
				end
			end
			creature.biteOwed = pending
			if not pending then
				creature.biteOwedUntil = nil
			end
		end
	end

	-- The choir grows back, and a DIFFERENT socket carries the real light.
	if
		creature.choirDueAt
		and now >= creature.choirDueAt
		and (creature.partsAlive or 0) == 0
		and not creature.mawOpen
	then
		creature.choirDueAt = nil
		spawnBossParts(creature, def)
		fireEvent("regrow", creature.anchor or creature.pos, { count = def.parts.count, name = def.name })
	end

	if creature.mode == "attack" then
		updateBossAttack(creature, def, now, dt, root, player, dist, -def.submerge)
	elseif root and now >= creature.nextAttackAt and dist <= def.aggro then
		local name = pickBossAttack(creature, def, now)
		-- LIGHTSWEEP WITHOUT A STALK IS FOUR AND A HALF SECONDS OF NOTHING.
		-- Its handler needs a living, LIT lantern to sweep from; with none it
		-- plays no telegraph, fires no beam and lands nothing, then spends
		-- windup + duration + recover (4.5s) and its 5.5s cooldown doing it.
		-- That is not a rare case: it is the whole 4-second regrow dark after
		-- every window, every dousehunt, and any moment the party has cleared
		-- the choir - and lightsweep is listed TWICE in stances 1 and 3 and is
		-- what `pickBossAttack`'s empty-pool fallback returns (the phase
		-- list's first entry). Checked here, before the attack begins, because
		-- this is the fight's only call site and a handler cannot un-begin
		-- itself once `beginBossAttack` has drawn its tell and set its clock.
		if name == "lightsweep" and not pickChoirStalk(state, root) then
			-- Held off for a beat so the re-pick below cannot hand back the
			-- same move, and so a dark that lasts several attack gaps does not
			-- re-ask the same question every time.
			creature.cooldowns = creature.cooldowns or {}
			creature.cooldowns.lightsweep = now + (def.attacks.lightsweep.cooldown or 5.5)
			name = pickBossAttack(creature, def, now)
			-- The fallback's fallback: everything else is on cooldown too, so
			-- it returned the phase list's first entry, which is lightsweep
			-- again. A feeler is her one move that needs nothing but a player.
			if name == "lightsweep" and def.attacks.feelerstrike then
				name = "feelerstrike"
			end
		end
		beginBossAttack(creature, def, name, now)
	end
	placeColossus(creature, def, now, root)
end

local function updateBoss(creature, now: number, dt: number)
	local def = bossDef(creature)
	local model = creature.model
	if not def then
		-- A "boss" row with no Bosses entry: just flop.
		local hop, yaw, pitch = flop(creature, now)
		model:PivotTo(poseCFrame(creature, hop, yaw, pitch))
		return
	end

	if not creature.mode then
		creature.anchor = creature.pos
		creature.untargetable = true
		creature.hitRadius = (def.hitRadius or 0) * (creature.row.body.scale or 1)
		-- AND HOW TALL IT IS, for shots only (raycastNearest's capsule). Set
		-- for the one boss that is far taller than its hitRadius: a 263-stud
		-- colossus over a 96-stud sphere at its feet, where the seams the fight
		-- asks you to shoot are 130-260 studs up. Everything else leaves this
		-- nil and keeps the pivot sphere it has always had - and hitRadius
		-- itself is untouched, because that number is the MOAT (see the row):
		-- 96 + the longest melee reach lands inside the lava.
		if def.pose == "pyrelisk" then
			creature.hitHeight = PyreliskPath.CROWN
		end
		creature.cooldowns = {}
		creature.nextAttackAt = now + def.riseTime + 1.2
		model:SetAttribute(ATTR_BOSS_NAME, def.name)
		setMode(creature, "rising", def.riseTime, now)
		fireEvent("bossRise", creature.pos, { name = def.name, duration = def.riseTime })
	end

	-- Never lingers out: the fight's over when it's dead.
	creature.lastFoughtAt = now
	creature.knockVel = nil

	-- Coming down. Checked before every other mode so that nothing - a stance
	-- change, an enrage, a queued attack - gets to speak over the death.
	if creature.collapsing then
		updateBossCollapse(creature, def, now)
		return
	end

	local sub = -def.submerge
	local root, player, dist = nearestPlayerRoot(creature.pos)

	if not creature.enraged and creature.health / creature.maxHealth <= def.enrageBelow then
		creature.enraged = true
		model:SetAttribute(ATTR_ENRAGED, true)
		fireEvent("enrage", model:GetPivot().Position, { name = def.name })
	end

	if creature.mode == "rising" then
		local u = modeProgress(creature, now)
		if def.entrenched then
			-- It does not rise from the deep - it is already up there. The
			-- wake is the head lifting out of its slump as the coils grind.
			--
			-- Hiding is gated on `pose`, NOT on `entrenched`: the server model
			-- is hidden because a RIG draws the body instead, so an entrenched
			-- boss without one would simply be invisible with nothing to
			-- replace it. Identical today (Brinejaw is the only entrenched
			-- boss and it has a rig), but "holds a perch" and "is drawn by a
			-- rig" are different claims and only the second one earns this.
			if def.pose then
				hideColossusModel(creature)
			end
			local state = colossusState(creature, def)
			-- AND THE RISE, on the same curve the non-entrenched branch below
			-- uses. Nothing wrote it here, and `rise` is not a wake-up flourish
			-- for a rigged colossus - it is a HEIGHT: PyreliskPath.lift returns
			-- -RISE_DEPTH * (1 - rise), so a rooted boss that publishes 0
			-- forever draws its whole body 40 studs under the lava, plant wrist
			-- and climb ramp included, for the entire fight. Brinejaw shares
			-- this branch and has no `rise` on its state, so this is inert
			-- there rather than a second meaning for the same field.
			state.rise = 1 - (1 - u) ^ 3
			state.slump = 1 - (1 - (1 - u) ^ 2)
			placeColossus(creature, def, now, root)
			if u >= 1 then
				state.rise = 1
				state.slump = 0
				-- Still untouchable, unless the row carries a CHIP FLOOR: for
				-- that boss the only way to a FULL hit is an earned stagger,
				-- but it is aimable and hurtable the whole time
				-- (`creature.chip`, scaled in `damage`). Setting the flag here
				-- would take it out of every target pick and make the floor
				-- unreachable.
				creature.untargetable = def.chip == nil
				setMode(creature, "entrenched", 0, now)
			end
			return
		end
		local e = 1 - (1 - u) ^ 3
		if def.pose then
			-- A posed boss is drawn entirely by the client, so "rising" is a
			-- number it publishes rather than a pivot it performs: the head
			-- climbs out of the whirlpool on the client's side of the wire.
			hideColossusModel(creature)
			colossusState(creature, def).rise = e
			placeColossus(creature, def, now, root)
		else
			model:PivotTo(poseCFrame(creature, -def.riseDepth + (def.riseDepth + sub) * e, 0, math.rad(-20) * (1 - e)))
		end
		if u >= 1 then
			creature.untargetable = false
			setMode(creature, "prowl", 0, now)
			-- The tentacle ring rises with it (the Kraken).
			if def.parts then
				spawnBossParts(creature, def)
			end
		end
		return
	end

	-- ---------------------------------------------------------- colossus
	if def.pose == "noctyss" then
		updateNoctyss(creature, def, now, dt, root, player, dist)
		return
	end

	if def.entrenched then
		local state = colossusState(creature, def)
		-- THE CHIP FLOOR'S TWO FIELDS, WRITTEN ONCE A FRAME AND NOWHERE ELSE.
		-- `chip` is copied off the row so `damage()` - which is handed no
		-- `def` - can find it; `punishOpen` is RECOMPUTED rather than latched,
		-- so no exit from a window (a stagger ending, a death mid-lunge, an
		-- attack interrupted by a collapse) can leave it stuck open. The two
		-- windows are the stagger and the lunge's held plant; the post-surge
		-- window IS a stagger, so it is already counted.
		creature.chip = def.chip
		creature.punishOpen = creature.mode == "stagger" or (creature.mode == "attack" and creature.lungeOpen == true)
		-- THE STONES REGROW ON A CLOCK. Here rather than in the stance branch
		-- below, because that one fires on a health threshold and this has to
		-- run whether or not the fight is making progress - which is the
		-- entire point: three baits cannot produce a stance's worth of damage,
		-- so a party that misread them used to have no way back into the fight
		-- at all. The stance-change restore is kept on top of it.
		regrowStones(creature, def, now)
		-- Stance follows the health phase: each one it loses costs it ground.
		local stance = (def.stances or 1) - (bossPhaseIndex(def, creature.health / creature.maxHealth) - 1)
		stance = math.max(stance, 1)
		-- `~=` alone never fires on the first pass (both start at MAX_COIL),
		-- so anything reading Stance saw nil for the fight's first third.
		if model:GetAttribute(ATTR_STANCE) == nil or state.coil ~= stance then
			-- THE FIRST PASS IS NOT A STANCE CHANGE. `state.coil` is nil until
			-- this line runs, so the attribute test above - which exists so
			-- anything reading Stance is not left staring at nil for the
			-- fight's first third - also fired the announcement on the boss's
			-- very first entrenched frame: a "it shifts its stance" banner
			-- and a sting before it had done anything, at full health, for
			-- the stance it started in. Set the attribute, restore the
			-- stones, say nothing.
			local announce = state.coil ~= nil
			state.coil = stance
			model:SetAttribute(ATTR_STANCE, stance)
			restoreStones(creature, def)
			-- A new stance is a new hand: the once-per-stance moves (`once`
			-- in pickBossAttack) are offered again. Cleared even on the first
			-- pass, which is harmless - there is nothing in it yet.
			creature.stanceUsed = nil
			if announce then
				fireEvent("bossStance", creature.pos, { name = def.name, stance = stance })
			end
		end

		if creature.mode == "stagger" then
			-- The punish window: it is down, open, and taking hits. The head
			-- eases to the sand and back so the window has a shape.
			local u = modeProgress(creature, now)
			state.slump = math.clamp(math.min(u * 6, 1) - math.max(u - 0.82, 0) / 0.18, 0, 1)
			placeColossus(creature, def, now, root)
			if u >= 1 then
				state.slump = 0
				creature.untargetable = def.chip == nil -- see the rise's note
				creature.model:SetAttribute(ATTR_EXPOSED, nil)
				creature.nextAttackAt = now + 0.6
				setMode(creature, "entrenched", 0, now)
			end
			return
		end

		if creature.mode == "attack" then
			updateBossAttack(creature, def, now, dt, root, player, dist, sub)
			placeColossus(creature, def, now, root)
			return
		end

		-- Entrenched: hold the perch, watch, and pick the next pattern. The
		-- tail eases back onto the tower between attacks.
		state.unwind = math.max((state.unwind or 0) - dt * 1.8, 0)
		placeColossus(creature, def, now, root)
		if root and now >= creature.nextAttackAt and dist <= def.aggro then
			beginBossAttack(creature, def, pickBossAttack(creature, def, now), now)
		end
		return
	end

	-- The ring regrows: `parts.regrow` seconds after the last tentacle falls
	-- (the head's exposure window), the arms come back - as long as the boss
	-- still lives. Checked in every mode so an attack can't stall the clock.
	if
		def.parts
		and creature.partsAlive == 0
		and creature.partsDownAt
		and now - creature.partsDownAt >= def.parts.regrow
	then
		spawnBossParts(creature, def)
		-- THE WINDOW IS CLOSING, so say so. kill() sets Exposed when the last
		-- part falls, and nothing unset it for a ring that grows BACK: the
		-- attribute latched true on the first window, so the head went on
		-- claiming to be open for the rest of the fight while being immune
		-- again. Both existing clears are unreachable from here - one belongs
		-- to the `expose` MOVE field (which this boss never uses) and one to
		-- the entrenched stagger exit (which it is not) - so this path has to
		-- own it, and it is the right owner: the only place a ring comes back.
		--
		-- The latch matters more than the wrong state. Re-setting an attribute
		-- to the value it already holds fires no change signal, so a renderer
		-- watching Exposed would open the head once per fight and never again.
		creature.model:SetAttribute(ATTR_EXPOSED, nil)
		fireEvent("regrow", creature.anchor or creature.pos, { count = def.parts.count, name = def.name })
	end

	if creature.mode == "attack" then
		updateBossAttack(creature, def, now, dt, root, player, dist, sub)
		if def.pose then
			placeColossus(creature, def, now, root)
		end
		return
	end

	-- A POSED boss that is not entrenched (the Kraken): it holds the middle
	-- of its arena instead of swimming at you. Its head IS the arena centre -
	-- 28 studs of it - so closing to `standoff` would shove the thing you are
	-- standing on. It turns to face, and its arms do the travelling.
	if def.pose then
		hideColossusModel(creature)
		local state = colossusState(creature, def)
		state.rise = math.min((state.rise or 0) + dt * 0.5, 1)
		creature.pos = creature.anchor or creature.pos
		placeColossus(creature, def, now, root)
		if root and now >= creature.nextAttackAt and dist <= def.aggro then
			beginBossAttack(creature, def, pickBossAttack(creature, def, now), now)
		end
		return
	end

	-- Prowl: turn to face, close in, breathe.
	if root then
		creature.yaw0 = approachAngle(creature.yaw0, yawToward(root.Position - creature.pos), def.turnRate * dt)
		if dist > def.standoff then
			creature.pos = resolveHorizontal(creature, flatUnit(root.Position - creature.pos) * def.speed * dt)
		end
	end
	clampToArena(creature, def)
	local breathe = math.sin(now * 1.6) * 0.25
	model:PivotTo(
		poseCFrame(creature, sub + breathe, math.sin(now * 0.9) * math.rad(3), math.sin(now * 1.6 + 1) * math.rad(2))
	)

	if root and now >= creature.nextAttackAt and dist <= def.aggro then
		beginBossAttack(creature, def, pickBossAttack(creature, def, now), now)
	end
end

-- Archetype name -> per-frame updater for a grounded, resting creature.
-- Anything not listed (the "flopper" fish, or an unknown string) takes the
-- default flop-in-place branch in update().
-- ============================================================ volcano archetypes (2026-08-23)
-- Six signature mechanics laid over movement that already exists, per
-- docs/volcano-content-spec.md. Each one delegates its walking to the ocean
-- archetype it was shipped on and adds only the new behaviour, so none of them
-- reimplements pathing, contact damage or the knockback slide. Two of the six
-- (crust, reborn) live in the damage path instead and only need their timers
-- unwound here; thornback is entirely in hitModifiers and needs no updater.

-- Slagheart Golem: shambles like the drowned. The armour is in damage(); all
-- that's left is closing the window again when it expires.
local function updateCrust(creature, now: number, dt: number)
	if creature.crustOpenUntil and now >= creature.crustOpenUntil then
		creature.crustOpenUntil = nil
		creature.model:SetAttribute(ATTR_CRACKED, false)
	end
	updateShambler(creature, now, dt)
end

-- Ashfeather Phoenix: charges like the skipper, except while it's down. Being
-- down is a real pause - untargetable, motionless, no contact damage - so the
-- rise reads as a second fight starting rather than a hiccup in the first.
local function updateReborn(creature, now: number, dt: number)
	if creature.downUntil then
		if now < creature.downUntil then
			creature.model:PivotTo(poseCFrame(creature, 0, 0, 0))
			return
		end
		creature.downUntil = nil
		creature.untargetable = false
		creature.health = math.max(1, math.floor(creature.maxHealth * C.REBORN_FRACTION + 0.5))
		creature.lastFoughtAt = now -- coming back doesn't count as being left alone
		creature.model:SetAttribute(ATTR_HEALTH, creature.health)
		creature.model:SetAttribute(ATTR_DOWNED, false)
		fireEvent("rebornRise", creature.pos, {})
	end
	updateCharger(creature, now, dt)
end

-- Cinder Djinn: shambles, shedding burning smoke as it goes. The puffs are
-- static once dropped and burn on their own clocks (ticked in update()), so the
-- danger is the ground it HAS covered - following it through its own trail is
-- the mistake the fight is built around.
local function updateGasCloud(creature, now: number, dt: number)
	creature.puffs = creature.puffs or {}
	if now >= (creature.nextPuffAt or 0) then
		creature.nextPuffAt = now + C.GAS_INTERVAL
		table.insert(creature.puffs, {
			pos = creature.pos,
			expiresAt = now + C.GAS_LIFETIME,
			nextTickAt = now + C.GAS_TICK,
		})
		-- A long fight would otherwise carpet the whole rim in fire.
		if #creature.puffs > C.GAS_MAX_PUFFS then
			table.remove(creature.puffs, 1)
		end
		fireEvent("gasPuff", creature.pos, { radius = C.GAS_RADIUS, lifetime = C.GAS_LIFETIME })
	end
	updateShambler(creature, now, dt)
end

-- Lodestone Eel: dashes like the skipper, and every few seconds hauls the
-- nearest player in. It deals no damage doing it - the point is that it ruins
-- your spacing and drags you back into everything else on the rim.
--
-- The drag reuses the boss lure's `pull` event rather than shoving the root
-- from here: a player's character is owned by their own client, so a velocity
-- set on the server is unreliable at best. The existing event applies a proper
-- VectorForce on the owning client, ramped and cancelled on respawn, which is
-- both correct and already tested.
local function updateMagnetize(creature, now: number, dt: number)
	if now >= (creature.nextPullAt or 0) then
		creature.nextPullAt = now + C.MAG_INTERVAL
		local root, _player, dist = nearestPlayerRoot(creature.pos)
		if root and dist <= C.MAG_RANGE then
			fireEvent("pull", creature.pos, {
				radius = C.MAG_RANGE,
				strength = C.MAG_STRENGTH,
				duration = C.MAG_DURATION,
			})
		end
	end
	updateCharger(creature, now, dt)
end

-- ============================================================ tentacle archetype (the finale)
-- A Kraken arm: PLANTED where spawnBossParts put it - it never walks, never
-- takes knockback or launch (both multipliers 0), and never lingers
-- (noLinger rides its spawn). It sways, faces the nearest player, and slams
-- a telegraphed ring around itself on a cooldown; the counterplay is that
-- killing the whole ring is what exposes the head. Reuses the boss slam's
-- telegraph + slam events, so every client tell already exists.
local function updateTentacle(creature, now: number, dt: number)
	local root, _player, dist = nearestPlayerRoot(creature.pos)
	if root then
		creature.yaw0 = approachAngle(creature.yaw0, yawToward(root.Position - creature.pos), math.rad(110) * dt)
	end
	-- A slam its owner ordered (commandArm): the boss's clock, the boss's
	-- reach, and no aggro or cooldown check - those gate an arm deciding for
	-- itself, which this is not.
	local windup = creature.slamWindup or C.TENTACLE_WINDUP
	local lift = creature.slamLift or 1.8

	local phase = creature.tentaclePhase
	if phase == "windup" then
		local u = math.clamp((now - creature.tentacleStart) / windup, 0, 1)
		creature.model:PivotTo(poseCFrame(creature, lift * u, 0, math.rad(-26) * u))
		if u >= 1 then
			creature.tentaclePhase = "recover"
			creature.tentacleStart = now
			-- BOSS_HEIGHT_TOLERANCE, like every other AoE in the boss kit,
			-- and this was the only one in the family without it. An arm
			-- stands at the waterline while the whole fight is conducted from
			-- rock caps 4-6 studs up - plus the character's own hip height -
			-- so the default 6-stud gate threw away most of the slams that
			-- visually connected. An arm that rears, comes down on you and
			-- does nothing is the worst thing a telegraph can do.
			damagePlayersInRadius(
				creature.pos,
				C.TENTACLE_RADIUS,
				C.TENTACLE_DAMAGE_MIN,
				C.TENTACLE_DAMAGE_MAX,
				creature,
				0.5,
				BOSS_HEIGHT_TOLERANCE
			)
			fireEvent("slam", creature.pos, { radius = C.TENTACLE_RADIUS })
		end
	elseif phase == "recover" then
		local u = math.clamp((now - creature.tentacleStart) / C.TENTACLE_RECOVER, 0, 1)
		-- The blow landed the instant the windup ENDED, so recovery starts
		-- with the arm already down, not still in the air on its way. Easing
		-- back from `lift` here meant the damage arrived while the limb was
		-- at the top of its rear, which reads as being hit by nothing - and
		-- the taller a commanded rear is, the worse that looks.
		local dip = math.min(lift * 0.35, 5.0)
		creature.model:PivotTo(poseCFrame(creature, -dip * (1 - u) ^ 2, 0, math.rad(8) * (1 - u)))
		if u >= 1 then
			creature.tentaclePhase = nil
			creature.slamWindup = nil
			creature.slamLift = nil
			creature.nextSlamAt = now + randomBetween(C.TENTACLE_COOLDOWN_MIN, C.TENTACLE_COOLDOWN_MAX)
		end
	else
		-- Idle: a slow kelp-sway, out of step with its neighbours (seeded by
		-- its own heading).
		local sway = math.sin(now * 1.3 + creature.yaw0 * 3)
		creature.model:PivotTo(poseCFrame(creature, sway * 0.5, sway * math.rad(5), math.sin(now * 0.8) * math.rad(4)))
		-- THE ORDER EXPIRES BEFORE IT IS READ. This is the only place an order
		-- can ever be performed, so it is the only place it can be retired -
		-- see SLAM_ORDER_GRACE. An arm busy when the beat came round arrives
		-- here late and finds nothing to obey, which is the intended outcome.
		if creature.slamAt and now > creature.slamAt + SLAM_ORDER_GRACE then
			creature.slamAt = nil
			creature.slamOrderWindup = nil
			creature.slamOrderLift = nil
		end
		local ordered = creature.slamAt ~= nil and now >= creature.slamAt
		local ownChoice = root and dist <= C.TENTACLE_AGGRO and now >= (creature.nextSlamAt or 0)
		if ordered or ownChoice then
			-- The order becomes this swing's numbers here and nowhere else.
			-- Slamming on its own account means its own reach, so they clear.
			creature.slamWindup = if ordered then creature.slamOrderWindup else nil
			creature.slamLift = if ordered then creature.slamOrderLift else nil
			-- CONSUMED ONLY BY THE SWING THAT PERFORMS IT. Clearing `slamAt`
			-- for an own-initiative slam too meant an arm that happened to
			-- decide for itself in the same frame silently ate a pending
			-- order: the wave lost a limb with nothing to show for it. A
			-- not-yet-due order now SURVIVES the arm's own swing - and,
			-- because that swing costs windup + recover (~1.7s), the order is
			-- comfortably stale by the time the arm is idle again and is
			-- dropped by the expiry above. No special case; the ordinary rule
			-- is what handles it.
			if ordered then
				creature.slamAt = nil
				creature.slamOrderWindup = nil
				creature.slamOrderLift = nil
			end
			creature.tentaclePhase = "windup"
			creature.tentacleStart = now
			fireEvent("telegraph", creature.pos, {
				kind = "slam",
				duration = creature.slamWindup or C.TENTACLE_WINDUP,
				radius = C.TENTACLE_RADIUS,
			})
		end
	end
end

-- ============================================================ companion archetype
-- Split Roe's hatchling - the only creature in the game that fights FOR the
-- player. It hunts the nearest hostile within HATCHLING_SEEK, bites it on a
-- cooldown, and trails its owner when there's nothing left to fight. It leaves
-- on its own clock (update() sweeps `expiresAt`), not on the LINGER timer,
-- which only makes sense for something you're meant to be killing.

local B = Tuning.Bait

-- The nearest thing a companion should bite: alive, targetable, and not
-- another friendly. Bosses count - a hatchling will cheerfully attack a
-- leviathan, it just won't achieve very much.
local function nearestHostile(pos: Vector3, radius: number)
	local best, bestDist = nil, radius
	for _, other in creatures do
		if not other.dead and not other.friendly and not other.untargetable and other.pos then
			local flat = Vector3.new(other.pos.X - pos.X, 0, other.pos.Z - pos.Z)
			local d = flat.Magnitude - (other.hitRadius or 0)
			if d < bestDist then
				best, bestDist = other, d
			end
		end
	end
	return best, bestDist
end

local function updateCompanion(creature, now: number, dt: number)
	slideKnockback(creature, dt)
	creature.lastBiteAt = creature.lastBiteAt or 0

	-- It swims rather than flops: a quick steady bob, never the fish's
	-- landed-and-dying thrash.
	local bob = math.abs(math.sin(now * B.HATCHLING_HOP_RATE)) * B.HATCHLING_HOP

	local target, dist = nearestHostile(creature.pos, B.HATCHLING_SEEK)
	if target then
		local delta = target.pos - creature.pos
		creature.yaw0 = approachAngle(creature.yaw0, yawToward(delta), C.RUSH_TURN_RATE * dt)
		if dist > B.HATCHLING_BITE_RANGE then
			creature.pos = resolveHorizontal(creature, flatUnit(delta) * B.HATCHLING_SPEED * dt)
		elseif now - creature.lastBiteAt >= B.HATCHLING_BITE_COOLDOWN then
			creature.lastBiteAt = now
			-- Credited to its owner, so its kills pay the player who brought it
			-- up - coins, XP and materials all follow the killer.
			CreatureService.damage(target, math.random(B.HATCHLING_DAMAGE_MIN, B.HATCHLING_DAMAGE_MAX), creature.owner)
		end
		creature.model:PivotTo(poseCFrame(creature, bob, 0, 0))
		return
	end

	-- Nothing to hunt: trail the owner, stopping short so it isn't swimming
	-- through their feet.
	local character = creature.owner and creature.owner.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root then
		local delta = (root :: BasePart).Position - creature.pos
		creature.yaw0 = approachAngle(creature.yaw0, yawToward(delta), C.RUSH_TURN_RATE * dt)
		if Vector3.new(delta.X, 0, delta.Z).Magnitude > B.HATCHLING_FOLLOW_RANGE then
			creature.pos = resolveHorizontal(creature, flatUnit(delta) * B.HATCHLING_FOLLOW_SPEED * dt)
		end
	end
	creature.model:PivotTo(poseCFrame(creature, bob, 0, 0))
end

-- ============================================================ flyer archetypes (revamp Session 2)
-- docs/revamp-plan.md Systems §2. A flyer's HEIGHT rides the pose's hop term
-- while `pos` stays the ground-clamped point underneath it, so every existing
-- rule - the bounds clamp, the knockback slide, LINGER, the stun and juggle
-- pre-emptions - keeps working untouched. Melee reach is measured to the
-- model's pivot, so a bird at cruise height is simply out of reach; the
-- grounded recovery after every dive is the deliberate melee window (ranged
-- reaches it any time). Launch mult 0 (already airborne), knockback 0.15.

-- One frame of circling the player: tangential motion around the preferred
-- ring plus a gentle correction toward it. Shared by the flyer and the
-- skythief's nothing-to-steal behaviour.
local function flyOrbit(creature, root: BasePart, dt: number)
	local center = root.Position
	local offset = Vector3.new(creature.pos.X - center.X, 0, creature.pos.Z - center.Z)
	local r = offset.Magnitude
	local radial = if r > 0.01 then offset / r else Vector3.xAxis
	local tangent = Vector3.new(-radial.Z, 0, radial.X)
	local toward = math.clamp((r - C.FLY_ORBIT_RADIUS) * 0.15, -1, 1)
	local dir = (tangent - radial * toward).Unit
	creature.yaw0 = approachAngle(creature.yaw0, yawToward(dir), C.FLY_TURN_RATE * dt)
	creature.pos = resolveHorizontal(creature, dir * C.FLY_SPEED * dt)
end

-- The flyer's whole machine, WITHOUT the knockback slide (the registry
-- wrappers below own that), so the skythief can delegate its shared modes
-- here without sliding twice in one frame.
local function updateFlyerCore(creature, now: number, dt: number)
	local model = creature.model
	if not creature.mode then
		creature.flyHeight = 0
		setMode(creature, "climb", 0, now)
	end
	local root, _player, dist = nearestPlayerRoot(creature.pos)

	if creature.mode == "grounded" then
		-- Downed after a dive: the melee window. It flops like a catch.
		local hop, yaw, pitch = flop(creature, now)
		model:PivotTo(poseCFrame(creature, hop, yaw, pitch))
		if now >= creature.modeUntil then
			setMode(creature, "climb", 0, now)
		end
	elseif creature.mode == "climb" then
		creature.flyHeight = math.min(C.FLY_HEIGHT, (creature.flyHeight or 0) + C.FLY_CLIMB_SPEED * dt)
		if root then
			creature.yaw0 = approachAngle(creature.yaw0, yawToward(root.Position - creature.pos), C.FLY_TURN_RATE * dt)
		end
		model:PivotTo(poseCFrame(creature, creature.flyHeight, 0, math.rad(-16)))
		if creature.flyHeight >= C.FLY_HEIGHT then
			setMode(creature, "circle", randomBetween(C.FLY_CIRCLE_MIN, C.FLY_CIRCLE_MAX), now)
		end
	elseif creature.mode == "windup" then
		-- The hover tell: it stalls in the air over you, quivering, rearing.
		if root then
			creature.yaw0 = yawToward(root.Position - creature.pos)
		end
		local u = modeProgress(creature, now)
		local quiver = math.sin(now * 30) * 0.25 * u
		model:PivotTo(
			poseCFrame(creature, (creature.flyHeight or C.FLY_HEIGHT) + 0.8 * u + quiver, 0, math.rad(24) * u)
		)
		if now >= creature.modeUntil then
			-- The dive line is locked NOW, at the player's current position -
			-- moving during the flight is the dodge (the spitter-landing rule).
			local target = if root then root.Position else creature.pos
			creature.diveFrom = Vector3.new(creature.pos.X, 0, creature.pos.Z)
			creature.diveTarget = Vector3.new(target.X, 0, target.Z)
			creature.diveHeight = creature.flyHeight or C.FLY_HEIGHT
			local run = (creature.diveTarget - creature.diveFrom).Magnitude
			local length = math.sqrt(run * run + creature.diveHeight * creature.diveHeight)
			local flight = math.max(0.25, length / C.FLY_DIVE_SPEED)
			creature.diveRun = run / flight -- horizontal studs/second down the line
			setMode(creature, "dive", flight, now)
			fireEvent(
				"telegraph",
				groundedPos(target, 0),
				{ kind = "burst", duration = flight, radius = C.FLY_DIVE_RADIUS }
			)
		end
	elseif creature.mode == "dive" then
		local u = modeProgress(creature, now)
		local to = creature.diveTarget - Vector3.new(creature.pos.X, 0, creature.pos.Z)
		if to.Magnitude > 0.1 then
			creature.yaw0 = yawToward(to)
			local step = flatUnit(to) * math.min(creature.diveRun * dt, to.Magnitude)
			if creature.flyHeight and creature.flyHeight > 2.5 then
				-- Still airborne: the obstacle ray in resolveHorizontal runs at
				-- the GROUND-clamped pos, so a rock the bird is flying OVER
				-- would stop the dive short of the telegraphed ring (review
				-- find, 2026-08-25). Clear of the ground, it only re-grounds.
				creature.pos = groundedPos(creature.pos + step, creature.halfThickness)
			else
				-- The final approach happens at head height; scenery counts.
				creature.pos = resolveHorizontal(creature, step)
			end
		end
		creature.flyHeight = creature.diveHeight * (1 - u)
		model:PivotTo(poseCFrame(creature, creature.flyHeight, 0, math.rad(38)))
		if u >= 1 then
			-- Impact: everyone near where it struck takes the hit, then it's
			-- down on the deck - hittable - until it climbs out again.
			creature.flyHeight = 0
			creature.pos = groundedPos(creature.pos, creature.halfThickness)
			damagePlayersInRadius(
				creature.pos,
				C.FLY_DIVE_RADIUS,
				C.FLY_DIVE_DAMAGE_MIN,
				C.FLY_DIVE_DAMAGE_MAX,
				creature,
				0.7
			)
			fireEvent("splash", creature.pos, { radius = C.FLY_DIVE_RADIUS })
			model:SetAttribute(ATTR_FLOPS, (model:GetAttribute(ATTR_FLOPS) or 0) + 1)
			setMode(creature, "grounded", randomBetween(C.FLY_GROUNDED_MIN, C.FLY_GROUNDED_MAX), now)
		end
	else -- circle
		local bob = math.sin(now * C.FLY_BOB_RATE + creature.spawnedAt) * C.FLY_BOB
		if root and dist <= C.FLY_AGGRO then
			flyOrbit(creature, root, dt)
			if now >= creature.modeUntil then
				setMode(creature, "windup", C.FLY_WINDUP, now)
			end
		elseif now >= creature.modeUntil then
			setMode(creature, "circle", randomBetween(C.FLY_CIRCLE_MIN, C.FLY_CIRCLE_MAX), now)
		end
		model:PivotTo(poseCFrame(creature, (creature.flyHeight or C.FLY_HEIGHT) + bob, 0, 0))
	end
end

local function updateFlyer(creature, now: number, dt: number)
	slideKnockback(creature, dt)
	updateFlyerCore(creature, now, dt)
end

-- The nearest resting PASSIVE catch worth stealing: alive, targetable, on the
-- ground, nobody's companion, not already in someone's claws, and a flopper -
-- the skythief takes your loot, not your fight.
local function nearestStealable(pos: Vector3, radius: number)
	local best, bestDist = nil, radius
	for _, other in creatures do
		if
			not other.dead
			and other.model.Parent ~= nil
			and other.row.archetype == "flopper"
			and not other.friendly
			and not other.untargetable
			and not other.carriedBy
			and other.state == "resting"
			and other.pos
		then
			local d = (Vector3.new(other.pos.X, 0, other.pos.Z) - Vector3.new(pos.X, 0, pos.Z)).Magnitude
			if d < bestDist then
				best, bestDist = other, d
			end
		end
	end
	return best
end

-- The aerial thief: circles like a flyer, but what it dives on is your
-- resting catch - it snatches the fish, carries it up, and makes for open
-- water. Kill the bird to drop the cargo where it falls; let it cover
-- SKYTHIEF_ESCAPE studs and bird and fish are both gone (the expiry path -
-- nothing died, you just lost it). With nothing to steal it dive-bombs like
-- a plain flyer.
local function updateSkythief(creature, now: number, dt: number)
	slideKnockback(creature, dt)
	local model = creature.model

	if creature.mode == "swoop" then
		local victim = creature.stealTarget
		if not victim or victim.dead or victim.carriedBy or victim.state ~= "resting" or not victim.model.Parent then
			creature.stealTarget = nil
			setMode(creature, "climb", 0, now)
			return
		end
		local to = Vector3.new(victim.pos.X - creature.pos.X, 0, victim.pos.Z - creature.pos.Z)
		creature.yaw0 = approachAngle(creature.yaw0, yawToward(to), C.FLY_TURN_RATE * dt)
		creature.pos = resolveHorizontal(creature, flatUnit(to) * C.SKYTHIEF_SWOOP_SPEED * dt)
		creature.flyHeight = math.max(1.2, (creature.flyHeight or C.FLY_HEIGHT) - C.SKYTHIEF_SWOOP_SPEED * 0.6 * dt)
		model:PivotTo(poseCFrame(creature, creature.flyHeight, 0, math.rad(30)))
		if to.Magnitude <= C.SKYTHIEF_GRAB_RADIUS and creature.flyHeight <= 3 then
			-- Snatched. The cargo is posed under the bird by the carried
			-- branch in update(); its own loop is suspended until it drops.
			-- Its linger clock is refreshed RIGHT NOW, not just per carried
			-- frame - the sweep runs before the carried branch, so a fish
			-- grabbed at its deadline would otherwise reap out of the claws.
			victim.carriedBy = creature
			victim.knockVel = nil
			victim.lastFoughtAt = now
			creature.cargo = victim
			creature.fleeDistance = 0
			fireEvent("steal", victim.model:GetPivot().Position, {})
			setMode(creature, "flee", 0, now)
		end
	elseif creature.mode == "flee" then
		local cargo = creature.cargo
		if not cargo or cargo.dead then
			-- The cargo was shot out of its claws; back to hunting.
			creature.cargo = nil
			setMode(creature, "climb", 0, now)
			return
		end
		-- Out to sea: straight away from the nearest player, climbing.
		local root = nearestPlayerRoot(creature.pos)
		local away = if root
			then flatUnit(creature.pos - root.Position)
			else Vector3.new(math.cos(creature.yaw0), 0, -math.sin(creature.yaw0))
		creature.yaw0 = approachAngle(creature.yaw0, yawToward(away), C.FLY_TURN_RATE * dt)
		local step = away * C.SKYTHIEF_FLEE_SPEED * dt
		local before = creature.pos
		creature.pos = resolveHorizontal(creature, step)
		-- Escape is measured by ground actually covered, never by intent: a
		-- bird pinned against a cliff or a bounds clamp must not "escape" in
		-- place and vaporize the cargo (review find, 2026-08-25).
		creature.fleeDistance = (creature.fleeDistance or 0)
			+ Vector3.new(creature.pos.X - before.X, 0, creature.pos.Z - before.Z).Magnitude
		creature.flyHeight = math.min(C.FLY_HEIGHT, (creature.flyHeight or 0) + C.FLY_CLIMB_SPEED * dt)
		model:PivotTo(poseCFrame(creature, creature.flyHeight, 0, math.rad(-10)))
		if creature.fleeDistance >= C.SKYTHIEF_ESCAPE then
			cargo.expiresAt = now
			creature.expiresAt = now
		end
	elseif creature.mode == "circle" then
		-- Before each dive decision, look for something better: your catch.
		if now >= creature.modeUntil then
			local victim = nearestStealable(creature.pos, C.SKYTHIEF_SEEK)
			if victim then
				creature.stealTarget = victim
				setMode(creature, "swoop", 0, now)
				return
			end
		end
		updateFlyerCore(creature, now, dt)
	else
		updateFlyerCore(creature, now, dt)
	end
end

ARCHETYPE_UPDATERS = {
	-- Rimefang publishes its body as pose attributes, and has to do it AFTER
	-- the shared boss frame whatever branch that frame took - rising, an
	-- attack, the beached window, prowling. Every other boss is byte-identical
	-- to before: rimefangDrive returns on its first line unless the row is
	-- Rimefang's.
	boss = function(creature, now: number, dt: number)
		updateBoss(creature, now, dt)
		rimefangDrive(creature, now, dt)
	end,
	companion = updateCompanion,
	flyer = updateFlyer,
	skythief = updateSkythief,
	rusher = updateRusher,
	shambler = updateShambler,
	charger = updateCharger,
	spitter = updateSpitter,
	bloater = updateBloater,
	drifter = updateDrifter,
	burrower = updateBurrower,
	mimic = updateMimic,
	thief = updateThief,
	pulser = updatePulser,
	-- Volcano. `splitter` and `thornback` have no updater of their own: an ooze
	-- rushes and divides in kill(), a shardback rushes and reflects in
	-- hitModifiers, so both keep the rusher loop their rows already name.
	crust = updateCrust,
	reborn = updateReborn,
	gascloud = updateGasCloud,
	magnetize = updateMagnetize,
	splitter = updateRusher,
	thornback = updateRusher,
	-- The finale: a Kraken arm, planted by the boss's parts ring.
	tentacle = updateTentacle,
	-- A Lantern Stalk, planted by Noctyss's. It has no updater of its own on
	-- purpose: the boss's pose driver puts every stalk where it belongs
	-- (updateChoir) and her attack book is the only thing that makes one do
	-- anything. Without this row the generic flop would send a 35-stud
	-- lantern hopping across the arena floor.
	choirstalk = function() end,
}

-- ============================================================ update

-- True once a thrown creature has stopped moving (or something went wrong
-- and it's time to take it back regardless).
local function hasLanded(creature, now: number): boolean
	local body = creature.model.PrimaryPart
	if not body then
		return true
	end
	local elapsed = now - creature.launchedAt
	if elapsed > C.THROW_MAX_FLIGHT then
		return true
	end
	if body.Position.Y < World.WATER_Y - 3 then
		return true -- fell through something; don't leave it sinking forever
	end
	-- Don't look for rest until it's had time to come down - the speed at
	-- the apex is low too.
	return elapsed > creature.flight * 0.6 and body.AssemblyLinearVelocity.Magnitude < C.THROW_SETTLE_SPEED
end

local function update(dt: number)
	local now = os.clock()
	updating = true
	-- Walk backwards so despawning (swap-remove) never skips an entry.
	for i = #creatures, 1, -1 do
		local creature = creatures[i]

		-- A model destroyed from OUTSIDE this service (BossService's abandon
		-- reaper does exactly this) leaves the struct behind, and nothing
		-- else ever collects it: bosses are exempt from the linger sweep and
		-- updateBoss refreshes lastFoughtAt every frame, so it would run
		-- forever on a parentless model - still picking attacks, still
		-- calling PlayerService.damage on anyone who came back, and still
		-- answering inRange/raycastNearest, while the island happily summons
		-- a second one on top of it. Drop it the frame its model goes away.
		if not creature.model.Parent then
			-- Its ring goes with it: parts outlive their owner's model
			-- otherwise, and there is nothing left to update them from.
			removeOwnedParts(creature)
			removeAt(i)
			continue
		end

		-- Timers that must run whatever state the creature is in - even
		-- mid-juggle or still flying from the bobber.
		if creature.spit and now >= creature.spit.landAt then
			landSpit(creature) -- the cod's glob lands on its own clock
		end
		if creature.globs then
			-- A boss's volley / spines: each comes down on its own clock.
			for g = #creature.globs, 1, -1 do
				local glob = creature.globs[g]
				if now >= glob.landAt then
					table.remove(creature.globs, g)
					-- `glob.tolerance` is the opt-in height gate, and nil on
					-- every glob that does not ask for one - so this is the
					-- default 6-stud AOE gate, to the stud, for everything
					-- that has ever thrown one. A glob lands on GROUND
					-- (scatterAround runs its point through groundedPos), and
					-- when the scatter falls off a rock cap into open water
					-- that ground is the waterline while the target is still
					-- up on the cap: 7-9 studs, which the default gate throws
					-- away. The rest of the boss kit already answers this with
					-- BOSS_HEIGHT_TOLERANCE; a glob simply had no way to say
					-- so. See ATTACK_HANDLERS.undertow, the one caller today.
					damagePlayersInRadius(glob.landing, glob.radius, glob.min, glob.max, creature, 0.5, glob.tolerance)
					fireEvent(glob.event, glob.landing, { radius = glob.radius })
					if glob.pool then
						-- A poolvolley glob leaves its lingering hazard.
						spawnPool(creature, glob.landing, glob.pool, now)
					end
				end
			end
			if #creature.globs == 0 then
				creature.globs = nil
			end
		end
		-- The boss arsenal's timed systems (see "the boss arsenal"): each
		-- keeps running whatever the boss is doing and dies with the struct.
		if creature.pools then
			-- Lingering ground hazards: damage and/or slow whoever stands in.
			for idx = #creature.pools, 1, -1 do
				local pool = creature.pools[idx]
				if now >= pool.expiresAt then
					table.remove(creature.pools, idx)
				elseif now >= pool.nextTickAt then
					pool.nextTickAt = now + BOSS_POOL_TICK
					if pool.min then
						damagePlayersInRadius(
							pool.pos,
							pool.radius,
							pool.min,
							pool.max,
							creature,
							0.4,
							BOSS_HEIGHT_TOLERANCE
						)
					end
					if pool.slow then
						fireEvent("chill", pool.pos, {
							radius = pool.radius,
							mult = pool.slow,
							duration = BOSS_POOL_TICK * 1.7,
							skin = pool.skin,
						})
					end
				end
			end
			if #creature.pools == 0 then
				creature.pools = nil
			end
		end
		if creature.strikes then
			-- Telegraphed impacts: ring at tellAt, hit at hitAt.
			for idx = #creature.strikes, 1, -1 do
				local s = creature.strikes[idx]
				if not s.tellFired and now >= s.tellAt then
					s.tellFired = true
					fireEvent("telegraph", s.pos, {
						kind = if s.shape == "annulus" then "ringTell" else "mark",
						duration = math.max(s.hitAt - now, 0.1),
						radius = if s.shape == "annulus" then s.outer else s.radius,
						inner = s.inner,
						skin = s.skin,
					})
				end
				if now >= s.hitAt then
					table.remove(creature.strikes, idx)
					if s.shape == "annulus" then
						damagePlayersInAnnulus(s.pos, s.inner, s.outer, s.min, s.max, creature)
					elseif s.min then
						damagePlayersInRadius(s.pos, s.radius, s.min, s.max, creature, 0.5, BOSS_HEIGHT_TOLERANCE)
					end
					fireEvent(s.hitEvent or "strikeHit", s.pos, {
						radius = s.outer or s.radius,
						inner = s.inner,
						skin = s.skin,
					})
					if s.snare then
						fireEvent("snare", s.pos, { radius = s.radius + 1.5, duration = s.snare, skin = s.skin })
					end
					if s.chain then
						fireEvent("chain", s.pos, {
							radius = s.chain.radius,
							leash = s.chain.leash,
							duration = s.chain.duration,
							skin = s.skin,
						})
					end
					if s.pool then
						spawnPool(creature, s.pos, s.pool, now)
					end
				end
			end
			if #creature.strikes == 0 then
				creature.strikes = nil
			end
		end
		if creature.lures then
			-- Decoy lures / drifting powder kegs: detonate on proximity,
			-- fizzle on expiry. Drifters chase the nearest player and mirror
			-- their movement to the clients at a low cadence.
			for idx = #creature.lures, 1, -1 do
				local lure = creature.lures[idx]
				local root, _, dist = nearestPlayerRoot(lure.pos)
				if root and lure.drift then
					lure.pos += flatUnit(root.Position - lure.pos) * lure.drift * dt
					if now >= lure.nextMoveAt then
						lure.nextMoveAt = now + 0.3
						fireEvent("decoyMove", lure.pos, {})
					end
				end
				if root and dist <= lure.trigger then
					table.remove(creature.lures, idx)
					damagePlayersInRadius(
						lure.pos,
						lure.blast,
						lure.min,
						lure.max,
						creature,
						0.5,
						BOSS_HEIGHT_TOLERANCE
					)
					fireEvent("decoyPop", lure.pos, { radius = lure.blast, skin = lure.skin })
				elseif now >= lure.expiresAt then
					table.remove(creature.lures, idx)
					fireEvent("decoyPop", lure.pos, { fizzle = true, skin = lure.skin })
				end
			end
			if #creature.lures == 0 then
				creature.lures = nil
			end
		end
		-- Brine Rot: each stack burns on its own clock and keeps burning while
		-- the creature is hidden, so a boss can't dive out of a poison.
		if creature.poison and not creature.dead then
			for p = #creature.poison, 1, -1 do
				local stack = creature.poison[p]
				if now >= stack.nextTickAt then
					stack.nextTickAt = now + Perks.POISON_TICK
					stack.ticksLeft -= 1
					CreatureService.damage(creature, stack.perTick, stack.attacker, { ignoreUntargetable = true })
				end
				if stack.ticksLeft <= 0 or creature.dead then
					table.remove(creature.poison, p)
				end
			end
			if #creature.poison == 0 then
				creature.poison = nil
			end
		end
		if creature.fuseAt and not creature.dead and now >= creature.fuseAt then
			explode(creature) -- the urchin's fuse runs out
		end
		-- A djinn's smoke burns wherever it was dropped, on its own clock and
		-- regardless of what the djinn is doing now - including being juggled or
		-- dead-but-not-yet-swept. Each puff ticks independently so walking
		-- through two overlapping ones genuinely hurts twice.
		if creature.puffs then
			for p = #creature.puffs, 1, -1 do
				local puff = creature.puffs[p]
				if now >= puff.expiresAt then
					table.remove(creature.puffs, p)
				elseif now >= puff.nextTickAt then
					puff.nextTickAt = now + C.GAS_TICK
					damagePlayersInRadius(puff.pos, C.GAS_RADIUS, C.GAS_DAMAGE_MIN, C.GAS_DAMAGE_MAX, creature, 0.6)
				end
			end
			if #creature.puffs == 0 then
				creature.puffs = nil
			end
		end

		if creature.dead then
			-- Killed from inside this walk (an explosion); the model is
			-- already gone, just drop the struct.
			removeAt(i)
		elseif
			-- Two ways to leave, one exit. A companion goes when its minute is
			-- up (it would otherwise never qualify below: it is never "left
			-- alone", and being fought is not what keeps it here). Everything
			-- else goes after LINGER seconds unfought - unless it is in a
			-- skythief's claws: the carried branch below refreshes its timer,
			-- but this sweep runs first, so a fish snatched right at its
			-- deadline would otherwise reap out of the grip.
			(creature.expiresAt and now >= creature.expiresAt)
			or (
				now - creature.lastFoughtAt > C.LINGER
				and not creature.row.boss
				and not creature.friendly
				and not creature.noLinger
				and not creature.carriedBy
			)
		then
			-- The LINGER timer resets on every hit, so a fight in progress
			-- keeps a creature here. A boss never leaves on its own (its
			-- updater keeps the timer fresh through its untargetable dives,
			-- where damage() can't).
			--
			-- RING OWNERS AND THIS EXIT (checked 2026-08-30): no parts owner
			-- can reach it today. `partsAlive` is only ever set by
			-- spawnBossParts, which only runs behind bossDef(), which needs
			-- `row.boss` - so every owner is a boss, and the LINGER arm above
			-- excludes bosses. But that is only half the branch: the
			-- `expiresAt` arm has NO boss test, and it fires for anything
			-- spawned with `extra.lifetime` (today only the hatchling
			-- companion) or for a skythief that escaped with its cargo. One
			-- boss row given a lifetime - a summoned add, a timed raid boss -
			-- and a parts owner leaves through here. So despawn tears the ring
			-- down unconditionally rather than trusting a data coincidence;
			-- it costs one nil check per despawn.
			despawn(i)
		elseif creature.state == "flying" then
			if hasLanded(creature, now) then
				settle(creature, now)
			end
		elseif creature.state == "settling" then
			local t = (now - creature.settleStart) / C.THROW_SETTLE_TIME
			if t >= 1 then
				creature.state = "resting"
				creature.model:PivotTo(restCFrame(creature))
			else
				creature.model:PivotTo(creature.settleFrom:Lerp(restCFrame(creature), smoothstep(t)))
			end
		elseif creature.carriedBy then
			-- Snatched by a skythief: its own behaviour is suspended and it
			-- rides under the bird. Kept "fought" so LINGER can't reap it out
			-- of the claws; the moment the carrier dies or vanishes it drops
			-- right here and goes back to being an ordinary resting catch.
			local carrier = creature.carriedBy
			if carrier.dead or not carrier.model.Parent then
				creature.carriedBy = nil
				creature.pos = groundedPos(creature.pos, creature.halfThickness)
				creature.model:SetAttribute(ATTR_FLOPS, (creature.model:GetAttribute(ATTR_FLOPS) or 0) + 1)
			else
				creature.lastFoughtAt = now
				creature.pos = carrier.pos
				local hang = math.max(0.5, (carrier.flyHeight or 0) - C.SKYTHIEF_CARRY_DROP)
				creature.model:PivotTo(poseCFrame(creature, hang, 0, 0))
			end
		elseif isAirborne(creature) then
			-- Juggled: hanging in the air from a hit. Suspends whatever the
			-- archetype would be doing until it lands.
			updateAirborne(creature, dt)
		elseif creature.stunnedUntil and now < creature.stunnedUntil then
			-- Dazed by a stun bait: the archetype loop is suspended, so even a
			-- hostile just flops there and takes free hits. Same pre-emption
			-- as the juggle above, and it still slides from knockback so it
			-- doesn't feel like a rock.
			if not creature.stunShown then
				creature.stunShown = true
				creature.model:SetAttribute(ATTR_STUNNED, true)
				-- Same interrupt rule as the juggle: the stun eats the move.
				creature.attack = nil
			end
			slideKnockback(creature, dt)
			local hop, yaw, pitch = flop(creature, now)
			creature.model:PivotTo(poseCFrame(creature, hop, yaw, pitch))
		else
			if creature.stunShown then
				-- Just came round: drop the flag so the client can stop
				-- drawing the daze.
				creature.stunShown = nil
				creature.stunnedUntil = nil
				creature.model:SetAttribute(ATTR_STUNNED, false)
			end
			-- A row with `moves` fights on the kit engine; the archetype
			-- string then only names its between-moves locomotion.
			local updater = if creature.row.moves then updateKitted else ARCHETYPE_UPDATERS[creature.row.archetype]
			if updater then
				-- A hostile: its own state machine owns the knockback slide,
				-- flop and pivot for this frame.
				updater(creature, now, dt)
			else
				-- The passive catch ("flopper"): knockback slide, then flop in
				-- place. The pose is heading + swish about world up, then a
				-- little nose pitch, then the flat-lay orientation - no roll,
				-- so it can't flip over.
				slideKnockback(creature, dt)
				local hop, yaw, pitch = flop(creature, now)
				creature.model:PivotTo(poseCFrame(creature, hop, yaw, pitch))
			end
		end
	end
	updating = false
end

-- ============================================================ lifecycle

function CreatureService.init()
	folder = Instance.new("Folder")
	folder.Name = "Creatures"
	folder.Parent = Workspace
end

function CreatureService.start()
	RunService.Heartbeat:Connect(update)
end

return CreatureService
