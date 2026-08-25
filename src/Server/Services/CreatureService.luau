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
local CreatureModel = require(Shared.Modules.CreatureModel)
local Remotes = require(Shared.Net.Remotes)
local Tuning = require(Shared.Config.Tuning)
local World = require(Shared.Config.World)

-- For the hostile archetypes' contact damage. PlayerService is listed above
-- this service in the boot order.
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

local function despawn(index: number)
	local creature = creatures[index]
	byModel[creature.model] = nil
	creature.model:Destroy()
	-- Swap-remove: order doesn't matter and this keeps removal O(1).
	local last = #creatures
	creatures[index] = creatures[last]
	creatures[last] = nil
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

-- Every live creature whose centre is within `radius` of `position`, nearest
-- first. For attacks that check reach rather than raycast.
function CreatureService.inRange(position: Vector3, radius: number): { any }
	local hits = {}
	for _, creature in creatures do
		-- A buried lurker or a shut mimic is simply not there to be hit; the
		-- swing reaches past it to the next-nearest creature. Nor is your own
		-- hatchling: CombatService swings at the NEAREST thing this returns, so
		-- leaving a companion in the list would mean punching your own pet the
		-- moment it got between you and the enemy. It can still be damaged
		-- through CreatureService.damage (an urchin's blast catches it) - it's
		-- untargetable by the player, not invulnerable.
		if not creature.dead and not creature.untargetable and not creature.friendly then
			-- A boss's body extends well past its pivot (`hitRadius`, from
			-- Bosses.luau scaled by the row); reach is measured to its hide,
			-- not its centre, or a 26-stud boss at stand-off is unhittable.
			local distance = (creature.model:GetPivot().Position - position).Magnitude - (creature.hitRadius or 0)
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

-- Killed rides a 4th value: { loot = coins the thief was carrying,
-- participants = every player who damaged it (a boss shares its win) } plus
-- whatever `extra` the spawner handed spawn() (a bait bounty). Listeners
-- that don't know about a key just ignore it.
local function kill(creature, killer: Player?)
	creature.dead = true
	byModel[creature.model] = nil

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

-- Archetype hooks defined further down (they need the health API and the
-- health API needs them): the urchin's swell-and-pop on every hit.
local onBloaterHit

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
	if creature.untargetable and not (opts and opts.ignoreUntargetable) then
		return nil
	end
	amount = math.max(0, amount)

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
local function fireEvent(kind: string, position: Vector3, extra)
	Remotes.CreatureEvent:FireAllClients(kind, position, extra or {})
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
local function damagePlayersInRadius(
	at: Vector3,
	radius: number,
	minDmg: number,
	maxDmg: number,
	source,
	edgeFraction: number,
	heightTolerance: number?
)
	local tolerance = heightTolerance or C.AOE_HEIGHT_TOLERANCE
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root then
			local d = (Vector3.new(root.Position.X, 0, root.Position.Z) - Vector3.new(at.X, 0, at.Z)).Magnitude
			if d <= radius and math.abs(root.Position.Y - at.Y) <= tolerance then
				local falloff = 1 - (1 - edgeFraction) * (d / radius)
				PlayerService.damage(
					player,
					math.floor(math.random(minDmg, maxDmg) * falloff + 0.5),
					source,
					{ bypassIframe = true }
				)
			end
		end
	end
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
		PlayerService.damage(player, math.random(minDmg, maxDmg), creature)
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
	drawKind: string
)
	creature.globs = creature.globs or {}
	local lo, hi = bossRoll(creature, def, p.damage)
	table.insert(creature.globs, {
		landing = landing,
		landAt = now + flight,
		radius = p.radius,
		min = lo,
		max = hi,
		event = event,
	})
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
local BOSS_ATTACKS = {}

-- Jaw Snap: rears back, then lunges and bites everything in front.
BOSS_ATTACKS.snap = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.8 * u, 0, math.rad(24) * u))
	end,
	strike = function(creature, def, p, _now, dt, u, _root, sub)
		creature.pos = resolveHorizontal(creature, bossFacing(creature) * (p.lunge / p.duration) * dt)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.8 * (1 - u), 0, math.rad(-14)))
		if not creature.attack.fired and u >= 0.4 then
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
BOSS_ATTACKS.tail = {
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
BOSS_ATTACKS.volley = {
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
BOSS_ATTACKS.slam = {
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
BOSS_ATTACKS.pull = {
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
BOSS_ATTACKS.brood = {
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
BOSS_ATTACKS.dive = {
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
	finish = function(creature, def, p)
		setBuried(creature, false)
		local lo, hi = bossRoll(creature, def, p.damage)
		damagePlayersInRadius(creature.pos, p.radius, lo, hi, creature, 0.5, BOSS_HEIGHT_TOLERANCE)
		fireEvent("emerge", creature.pos, { radius = p.radius, big = true })
	end,
	recover = function(creature, def, _p, u, sub)
		-- Bursts up past its rest height and settles back into it.
		local e = 1 - (1 - u) ^ 3
		local hop = -def.riseDepth + (sub + def.riseDepth) * e + 2.5 * math.sin(e * math.pi)
		creature.model:PivotTo(poseCFrame(creature, hop, 0, math.rad(28) * (1 - e)))
	end,
}

-- Spine Barrage: quivers, then rains spines down around the player.
BOSS_ATTACKS.spines = {
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
	for _, name in bossPhaseAttacks(def, creature.health / creature.maxHealth) do
		local readyAt = creature.cooldowns and creature.cooldowns[name] or 0
		if name ~= creature.lastAttack and now >= readyAt then
			table.insert(pool, name)
		end
	end
	if #pool == 0 then
		return "snap" -- always something; snap has the shortest cooldown
	end
	return pool[math.random(#pool)]
end

local function beginBossAttack(creature, def, name: string, now: number)
	local p = def.attacks[name]
	creature.attack =
		{ name = name, p = p, phase = "windup", phaseStart = now, phaseUntil = now + p.windup, fired = false }
	creature.lastAttack = name
	setMode(creature, "attack", 0, now)
	fireEvent("telegraph", creature.model:GetPivot().Position, {
		kind = name,
		duration = p.windup,
		radius = p.radius,
		facing = bossFacing(creature),
	})
end

local function endBossAttack(creature, def, now: number)
	local a = creature.attack
	local rage = if creature.enraged then def.enrageCooldownMult else 1
	creature.cooldowns = creature.cooldowns or {}
	creature.cooldowns[a.name] = now + a.p.cooldown * rage
	if a.p.follow then
		creature.forcedAttack = a.p.follow
		creature.nextAttackAt = now + 0.15
	else
		creature.nextAttackAt = now + randomBetween(def.attackGapMin, def.attackGapMax) * rage
	end
	creature.attack = nil
	setMode(creature, "prowl", 0, now)
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
	local handler = BOSS_ATTACKS[a.name]
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
		creature.cooldowns = {}
		creature.nextAttackAt = now + def.riseTime + 1.2
		model:SetAttribute(ATTR_BOSS_NAME, def.name)
		setMode(creature, "rising", def.riseTime, now)
		fireEvent("bossRise", creature.pos, { name = def.name, duration = def.riseTime })
	end

	-- Never lingers out: the fight's over when it's dead.
	creature.lastFoughtAt = now
	creature.knockVel = nil

	local sub = -def.submerge
	local root, player, dist = nearestPlayerRoot(creature.pos)

	if not creature.enraged and creature.health / creature.maxHealth <= def.enrageBelow then
		creature.enraged = true
		model:SetAttribute(ATTR_ENRAGED, true)
		fireEvent("enrage", model:GetPivot().Position, { name = def.name })
	end

	if creature.mode == "rising" then
		local u = modeProgress(creature, now)
		local e = 1 - (1 - u) ^ 3
		model:PivotTo(poseCFrame(creature, -def.riseDepth + (def.riseDepth + sub) * e, 0, math.rad(-20) * (1 - e)))
		if u >= 1 then
			creature.untargetable = false
			setMode(creature, "prowl", 0, now)
		end
		return
	end

	if creature.mode == "attack" then
		updateBossAttack(creature, def, now, dt, root, player, dist, sub)
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
			creature.pos = resolveHorizontal(creature, flatUnit(to) * math.min(creature.diveRun * dt, to.Magnitude))
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
		if not victim or victim.dead or victim.carriedBy or victim.state ~= "resting" then
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
			victim.carriedBy = creature
			victim.knockVel = nil
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
		creature.pos = resolveHorizontal(creature, step)
		creature.fleeDistance = (creature.fleeDistance or 0) + step.Magnitude
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

local ARCHETYPE_UPDATERS = {
	boss = updateBoss,
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
					damagePlayersInRadius(glob.landing, glob.radius, glob.min, glob.max, creature, 0.5)
					fireEvent(glob.event, glob.landing, { radius = glob.radius })
				end
			end
			if #creature.globs == 0 then
				creature.globs = nil
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
			-- else goes after LINGER seconds unfought.
			(creature.expiresAt and now >= creature.expiresAt)
			or (now - creature.lastFoughtAt > C.LINGER and not creature.row.boss and not creature.friendly)
		then
			-- The LINGER timer resets on every hit, so a fight in progress
			-- keeps a creature here. A boss never leaves on its own (its
			-- updater keeps the timer fresh through its untargetable dives,
			-- where damage() can't).
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
			local updater = ARCHETYPE_UPDATERS[creature.row.archetype]
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
