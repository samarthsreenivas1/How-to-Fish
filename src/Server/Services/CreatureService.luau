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

-- Chunk-scope local budget: Luau allows 200 live locals per scope and this
-- module blew past it. Constants live as fields of K (and ATTR_* strings as
-- fields of ATTR) instead of chunk locals. DO NOT add new top-level `local`
-- constants to this file - add a field here.
local ATTR = {}
local K = {}
local Fn = {}

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

-- Fired with (islandId, arenaKey) when a FIGHT CHANGES ROOMS: the Kraken's
-- siphon swallowing the party into the gullet, and the collapse putting them
-- back on the ship. BossService listens and moves the participants it is the
-- only owner of.
--
-- A BINDABLE FOR THE SAME REASON `Killed` IS ONE, and it is the only shape that
-- works: BossService requires this file, so this file cannot require it back,
-- and the two halves of a relocation live one on each side of that line - the
-- fight knows WHEN, and only BossService knows WHO. The alternative (this file
-- keeping its own participant list) would be a second, staler copy of a truth
-- that already exists, which is the shape of bug this file has been bitten by
-- repeatedly.
CreatureService.ArenaMove = Instance.new("BindableEvent")

-- Attribute names on the creature Model. They replicate on their own, so a
-- client health bar can just read / listen to these without a remote.
ATTR.ID = "CreatureId"
ATTR.HEALTH = "Health"
ATTR.MAX_HEALTH = "MaxHealth"
-- Motion cues for CreatureVfxController (client): in the air, came down,
-- and a counter that ticks once per flop.
ATTR.THROWN = "Thrown"
ATTR.LANDED = "Landed"
ATTR.FLOPS = "Flops"
-- Enemy states for CreatureEventController (client). All booleans, each set
-- only by the archetype that owns it; one-off moments go through the
-- CreatureEvent remote instead (fireEvent below).
ATTR.DASHING = "Dashing" -- charger: mid-dash (streak)
ATTR.EXPOSED = "Exposed" -- charger: turning back, takes double damage (dazed tell)
ATTR.BURIED = "Buried" -- burrower: under the sand, hidden + untargetable
ATTR.OPEN = "Open" -- mimic: gaping, hittable
ATTR.CHARGING = "Charging" -- pulser: charging up, hitting it shocks you
-- Island bosses (BossHudController reads the name; CreatureEventController
-- the rage).
ATTR.STUNNED = "Stunned" -- dazed by a stun bait: flops helplessly, can't act
-- The one creature that is NOT an enemy: Split Roe's hatchling, which fights
-- on the player's side. Clients key off this to draw it as an ally rather than
-- a target (a green bar instead of the enemy red - CombatFeedbackController).
ATTR.FRIENDLY = "Friendly"
-- Volcano tells (docs/volcano-content-spec.md).
ATTR.CRACKED = "Cracked" -- crust: the slag is broken, the core is exposed
ATTR.DOWNED = "Downed" -- reborn: dead once, about to rise again

-- The client-event helper (fireEvent) lives down with the archetypes, but the
-- kill and damage paths above it need to fire tells too. Assigned there.
local fireCreatureEvent
ATTR.BOSS_NAME = "BossName" -- the boss's title, set when it rises
ATTR.ENRAGED = "Enraged" -- below Bosses.enrageBelow health: faster, harder
-- HOW BIG THIS THING IS TO A SHOT, when the row says so (`row.shotRadius`).
--
-- IT IS PUBLISHED BECAUSE THE ANSWER IS NEEDED IN TWO PLACES AND WAS ONLY
-- DERIVED IN EACH (user, 2026-09-08, live: "when i point my crosshair at
-- something and shoot, it doesnt work... especially the little black thing
-- that follows me around"). `raycastNearest` here captures within
-- `max(1.4, boundingBox.Magnitude * 0.3)` of the ray, and RangedController's
-- `aimDistance` independently computes the SAME formula off the same model to
-- decide how far down the cursor ray the target is. Both were individually
-- correct and the composition was not: for a small target on open sand the
-- client's sweep misses, the depth falls through to the SAND BEHIND it, and
-- because the shot is fired from the shooter's root rather than the camera,
-- that wrong depth bends the direction by the rig's whole parallax - so the
-- server then tests a ray that genuinely does not pass near the target. Two
-- estimates, one of which silently decides the other's input.
--
-- So the size is authored once on the row and READ by both, instead of being
-- guessed twice. Nil on every row that does not carry it, which is every row
-- but Wrack's shootables, and the derived formula stands for all of them.
ATTR.SHOT_RADIUS = "ShotRadius"
-- THIS IS THE THING TO SHOOT, and the boss cannot be hurt while it stands
-- (user, 2026-09-08, live: they did not clearly know the cannons were the
-- targets). Stamped by Fn.spawnBossParts on every part of a `vulnerableWhen =
-- "partsDown"` boss - Wrack's four cannons, the Kraken's eight arms - and true
-- for the whole life of that part.
--
-- IT IS A CONTRACT, NOT A VISUAL. The server owns the claim ("the fight is
-- gated on this object") and nothing here draws anything; a client lane can
-- key an outline, a marker or an off-screen arrow off it, and the honest
-- alternative - each renderer keeping its own list of which rows happen to be
-- weakpoints - is the shape of bug this file has been bitten by repeatedly.
ATTR.WEAKPOINT = "Weakpoint"
-- ...and THIS one is winding up right now (Wrack's cannon overload picks one
-- live battery and charges a mega-shot out of it; damaging that battery during
-- the windup jams the shot). Set at the windup's latch, cleared when the move
-- leaves. Same contract: the server says which, the client decides how loud.
ATTR.WEAKPOINT_HOT = "WeakpointHot"
-- ------------------------------------------------ Wrack's three moving pieces
-- (2026-09-09). All three are ANIMATION CONTRACTS in the WEAKPOINT_HOT idiom:
-- the server states what the piece is doing, held for as long as it is true, and
-- the client decides how to draw it. A one-shot event cannot express any of the
-- three, because a client that adopts the hull mid-move would see nothing at all
-- and would draw a figurehead still docked while the server flew it at someone.
--
-- WHAT IS *NOT* HERE, AND WHY. The Lady's POSITION is not published. She is a
-- creature model the server moves with PivotTo every frame, so her CFrame
-- replicates natively - the same channel the powder keg has used since
-- 2026-09-08 (see the `NO "decoy" SPAWN EVENT` note in the powderrun handler:
-- the keg is drawn purely from replication and nothing sends it a move event).
-- A per-frame attribute copy of a position the engine already replicates is a
-- second, slower, lossier truth about the same thing, and the first time the two
-- disagree the hitbox and the picture part company. So: her MODEL is where she
-- is, and these attributes carry only what her model cannot say.
ATTR.WRACK_DIVE = "WrackDive"
-- On the FIGUREHEAD's own model. 0 while she is swinging out or re-arming
-- between passes, `n` for the n-th damaging pass (1-based), nil once she has
-- re-docked or been shot down. The heading of a pass is not published either:
-- it is constant for the whole pass and readable from her own motion.
ATTR.WRACK_BOOM = "WrackBoom"
-- On the BOSS's model. The main boom's live world bearing in radians, in
-- ProjectileService's convention (the one Fn.wrackAngle returns), written every
-- frame it moves and set to nil the instant the boom is stowed OR its tackle is
-- shot away. Nil therefore means "no boom out", which is the state the client
-- has to be able to reach from a dropped tackle as well as from a finished
-- sweep. It is the SAME number the damage sector is tested against, taken one
-- line apart from the same clock (the anchorline's "ridden off the same
-- kinematics" rule), so the drawn spar and the hitbox cannot drift.
ATTR.WRACK_HATCHES = "WrackHatches"
-- On the BOSS's model. A bitmask of which bilge hatches are open: bit (i-1) set
-- means hatch `i` of the boss row's `hatches` list is open, in that list's
-- authored order - the same "order is the authored one" convention `parts.mounts`
-- lives under. Nil when every hatch is shut. ONE attribute rather than three
-- booleans because the client would otherwise keep its own list of which hatch
-- is which, which is the shape of bug this file has been bitten by repeatedly.

-- ---------------------------------------------- Wrack's three acts (2026-09-09)
ATTR.WRACK_ACT = "WrackAct"
-- On the BOSS's model, 1 or 2 - which act of his own fight the ship is in. It is
-- FIGHT STATE, not a pose, and that is why it is published rather than inferred:
-- act one is four live cannons and an immune hull, act two is a hull that shoots
-- for herself, and the two are told apart by an event (the fourth permanent
-- kill) that leaves no other trace on the model. `partsAlive` is not a
-- substitute - it is the same 0 during the act break and for the whole of act
-- two.
ATTR.WRACK_WRECK = "WrackWreck"
-- On the BOSS's model. A LEVEL, 0 to 1, not a flag: how far through wrecking the
-- ship is once her hull has reached zero. The client eases the list and the mast
-- fall off it, so it has to ramp rather than flip - a boolean would give the
-- rig one frame to play a sinking in.
--
-- It reaches 1 on the last frame the model exists. `kill()` destroys the model
-- and THEN fires Killed, and BossService's handoff spawns the Admiral inside
-- that handler, so the duelist's model appears in the same frame the ship's
-- disappears: the rig hides the ship's copy of him on this model's own removal,
-- which is a seam with no gap in it rather than a threshold to tune.
ATTR.WRACK_RIPOSTE = "WrackRiposte"
-- On the ADMIRAL's model (act three), 0, 1 or 2. THREE values, not two, and the
-- third is the whole point: 1 is the stance being held, 2 is the counter
-- actually going off, 0 is over. With only 1 and 0 the client cannot tell "he
-- countered you" from "the window expired untouched" - the same 1 -> 0 edge for
-- opposite outcomes - and those are the two halves of the move the player is
-- being asked to read. Held at 2 for the counter's whole duration, so a client
-- adopting mid-counter still gets it (level-triggered, like Exposed).

-- ------------------------------------------- THE KRAKEN'S REPLICATION CONTRACT
-- (2026-09-09, the rework). Everything KrakenBodyController needs that a model's
-- own CFrame cannot say, in one place, in the WRACK_DIVE idiom: the server
-- states what a piece is DOING and holds the statement for as long as it is
-- true, and the client decides how to draw it. Not events, because a client that
-- adopts a body mid-move must be able to reach the right pose from nothing.
--
-- ON EACH ARM'S MODEL (there are two, `kraken_arm` rows):
--   ArmPhase   one of "Rest" | "Rear" | "Slam" | "SweepCock" | "Sweep" |
--              "Wrapped" | "Down" | "Withdrawn". The limb's state machine.
--   ArmPhaseAt the os.clock() the phase began. THE SMOOTHNESS CONTRACT: the
--              client eases from this timestamp rather than snapping on the
--              change signal, so a phase that arrives one frame late still
--              plays from where it should have started. Nothing about this
--              fight may ever be drawn by "the attribute changed, jump".
--   ArmT       0..1 progress through the current phase, written every frame.
--              Redundant with ArmPhaseAt on purpose: the server owns the
--              curve for the phases whose timing is not linear (a slam
--              accelerates into the deck), and a client easing on its own
--              clock would draw the impact early or late.
--   WrapIndex  1..4 while ArmPhase is "Wrapped": WHICH boarding gap, indexed
--              into BossArenas.maelstrom.wraps in that table's authored order.
--              nil otherwise.
--   TargetX/TargetZ  world XZ the limb is reaching for - a slam's impact
--              centre, a sweep's far end. nil when the phase has no target.
--   WeakpointHot  true while this arm's knuckle is the glowing 3x hit (see
--              ATTR.WEAKPOINT_HOT above, whose contract this reuses rather
--              than forking). ATTR.WEAKPOINT is stamped once at plant, by the
--              existing `vulnerableWhen = "partsDown"` rule.
--   WeakpointPos  where the knuckle IS, in world space, while it is hot. The
--              arm's own hitbox is the WHOLE limb; the knuckle is a point on
--              it, and a client that guessed would draw the glow somewhere the
--              server is not counting hits.
ATTR.ARM_PHASE = "ArmPhase"
ATTR.ARM_PHASE_AT = "ArmPhaseAt"
ATTR.ARM_T = "ArmT"
ATTR.WRAP_INDEX = "WrapIndex"
ATTR.TARGET_X = "TargetX"
ATTR.TARGET_Z = "TargetZ"
ATTR.WEAKPOINT_POS = "WeakpointPos"
-- ON THE BOSS'S OWN MODEL:
--   PhaseIndex  1 (the waist), 2 (the full ship) or 3 (the gullet). The
--               machine's state, and the one number that tells a renderer
--               which of three fights it is drawing.
--   SiphonOpen  true for the ~10s the head is slumped and its siphon is open -
--               the only window its health bar can be touched. Beside
--               ATTR.EXPOSED rather than instead of it: `Exposed` is the
--               general "this boss is open" contract every body controller
--               already reads, and this is the Kraken's own statement about
--               WHICH door is open, which phase three turns into a room.
--   FightCenter  where the fight IS, in world space. Written when the swallow
--               moves it into the gullet 20,000 studs away and read by
--               BossService's ride home and its abandon reaper - see
--               `fightCenter` there for the two silent failures it removes.
--               Level-triggered because a 2-second poll cannot be handed an
--               event.
--   Rise        the head's climb out of the sea, 0..1 - already published by
--               `publishPose` for this pose and named here because the
--               contract is one list or it is nothing.
ATTR.PHASE_INDEX = "PhaseIndex"
ATTR.SIPHON_OPEN = "SiphonOpen"
ATTR.FIGHT_CENTER = "FightCenter"

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
function Fn.flatOrientation(model: Model): (CFrame, number)
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
function Fn.uprightOrientation(model: Model): (CFrame, number)
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
	model:SetAttribute(ATTR.THROWN, true)
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
	-- ...AND WRACK'S SHOT OCCLUDER, which is a solid collidable hull sitting in
	-- the World folder (Fn.wrackOccluder). This filter Excludes only creatures
	-- and characters and RespectCanCollide is true, so without this line every
	-- prop the fight places near the ship - the boarding party marching at her
	-- side, the anchor chain's landing, a powder keg spawned behind a player
	-- standing close - would ground on the DECK, twelve studs up, instead of on
	-- the sand. It is invisible geometry: nothing about the resulting scene
	-- would look like a raycast filter, it would look like the props are wrong.
	if K.WRACK_OCCLUDER then
		table.insert(ignore, K.WRACK_OCCLUDER)
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

	model:SetAttribute(ATTR.THROWN, false)
	model:SetAttribute(ATTR.LANDED, true)
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
		flat, halfThickness = Fn.uprightOrientation(model)
	else
		flat, halfThickness = Fn.flatOrientation(model)
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

	model:SetAttribute(ATTR.ID, row.id)
	model:SetAttribute(ATTR.MAX_HEALTH, maxHealth)
	model:SetAttribute(ATTR.HEALTH, maxHealth)
	-- Published so the CLIENT's aim depth uses the same capture this server's
	-- shot select does. See ATTR.SHOT_RADIUS: two independent estimates of one
	-- number, where the client's silently decides the server's input.
	if row.shotRadius then
		model:SetAttribute(ATTR.SHOT_RADIUS, row.shotRadius)
	end
	if creature.friendly then
		model:SetAttribute(ATTR.FRIENDLY, true)
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
K.RF_SHOT_SLACK = 2.0

-- `from` is the ATTACKER'S position when the caller has one (a swinger's root,
-- a shot's re-validated origin). It only matters for a window that is
-- positional as well as timed - see the `markedDown` branch. Callers that
-- cannot name a shooter (an urchin's blast, an arc shell's re-check at its
-- landing point) pass nothing and get the old, purely-declarative answer.
function Fn.unaimable(creature, from: Vector3?): boolean
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
		-- the biggest capture cylinder on the arena (12 hitRadius plus a
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
-- is skipped by `Fn.unaimable` above while it is immune, which is the general
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
			and not Fn.unaimable(creature, from)
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

-- ------------------------------------------------- pyrelisk: the seams
--
-- THE FIGHT'S CORE LOOP, and the server half of PyreliskBodyController's
-- ATTRIBUTE CONTRACT. The colossus is `untargetable` for everything except an
-- earned window, which is true of its BODY and stays true: `Fn.unaimable` keeps
-- it out of every target pick, and nothing below changes that. What this adds
-- is a second, much smaller door - the glowing seams that split open when it
-- commits to a move. A shot that passes close to an OPEN seam, from the side
-- the seam faces, lands: it hurts the boss and fills that flank's meter, and
-- a full meter drops that arm and buys a window.
--
-- The four published attributes and their exact names live in publishPose;
-- everything here writes the pose state they are read off.
--
-- Which meter a seam answers to. DERIVED off PyreliskPath.SEAMS rather than
-- written out, exactly as the client derives it, so the two cannot drift:
-- `authored(x, y, z)` lands at (x, z, -y), so the authored +y flank (side +1,
-- PyreliskPath's `flank`) arrives with a NEGATIVE body-local Z. Index 1 is the
-- CHEST - authored y = 0, so it falls out with side 0 and belongs to NEITHER
-- mask. That is the whole of "never set bit 0 in phase 2": there is no phase
-- check anywhere below, the chest is simply in no flank's mask and no attack
-- can open it.
K.PY_SEAM_FLANK = table.create(#PyreliskPath.SEAMS, 0)
K.PY_SEAM_MASK_L, K.PY_SEAM_MASK_R = 0, 0
for index, seam in PyreliskPath.SEAMS do
	local side = if math.abs(seam.at.Z) < 1e-3 then 0 elseif seam.at.Z < 0 then 1 else -1
	K.PY_SEAM_FLANK[index] = side
	local bit = bit32.lshift(1, index - 1)
	if side > 0 then
		K.PY_SEAM_MASK_L += bit
	elseif side < 0 then
		K.PY_SEAM_MASK_R += bit
	end
end

-- HOW CLOSE A SHOT HAS TO PASS. The drawn seam module is ~8.5 studs across,
-- and this is a 270-stud body shot from up to 200 studs away, so the capture
-- has to be a little more generous than the art or the move becomes pixel
-- hunting at the ranges the arena is played at. Measured against the fight:
-- the chest-height flank seam (SEAMS[2]) sits 163 studs from a shooter on the
-- ring at r160, so 9 studs is an aim tolerance of atan(9/163) = 3.2 degrees -
-- about three times a 1-degree tremor (2.85 studs of miss at that range) and
-- nowhere near the tens of degrees the body's own 96-stud capture sphere
-- would give if the boss were simply made aimable.
K.PY_SEAM_HIT_RADIUS = 9.0

-- WHAT A FLANK COSTS. Damage dealt through that flank's seams, summed; at
-- this much that flank SCARS - permanently - and the pair of them is the whole
-- of act 1.
--
-- 5400, UP FROM 2600, and the reason is that the meter stopped being a
-- repeatable window and became a third of the fight. Two flanks at 5400 is
-- 10,800 of seam damage for act 1 entire; at the old 2600 the act was over in
-- under thirty seconds of real uptime. Against the two guns of the band -
-- Cinderlock (110 dps sustained), Vulkan (200 dps) - that is 49s and 27s of
-- unbroken fire per flank, and since seams are only open while the boss is
-- ATTACKING, real uptime is nearer half that.
--
-- UNMEASURED (design flag F-2). Band-4 sustained party DPS has never been
-- measured, so this number and the arms' 7,000 are one guess made twice.
-- Re-derive them together off a real playtest or not at all.
--
-- AND IT IS DIVIDED BY THE PARTY (F-1), which it was not before - see
-- `Fn.pyreliskSeamCredit`. `Fn.spawnBossParts` has always passed the party's
-- `healthMult` down to every part, on the argument that a wall which stayed
-- solo-sized "would make the fight EASIER per head as the party grew, which is
-- backwards". The seam meters are the biggest wall in the redesigned fight and
-- were the one thing in it not scaled at all.
K.PY_SEAM_METER_HP = 5400.0

-- A shot is resolved (and its seam hit judged) at FIRE time, but it lands
-- after its flight - CombatService queues it, capped at Tuning.Ranged
-- MAX_FLIGHT = 2.0s. A seam claim has to outlive that flight and nothing
-- longer, so it expires here.
K.PY_SEAM_CLAIM_LIFE = 2.5
-- One volley of the widest shotgun, and a hard ceiling so a stray claim can
-- never grow into a leak.
K.PY_SEAM_CLAIM_CAP = 16

-- The pose state of a live pyrelisk, or nil for every other creature in the
-- game - which is what keeps every function below inert everywhere else.
function Fn.pyreliskSeamState(creature)
	if creature.poseKind ~= "pyrelisk" then
		return nil
	end
	local state = creature.pose
	if type(state) ~= "table" or state.center == nil then
		return nil
	end
	return state
end

-- WHICH SEAMS A MOVE OPENS, off the row's `seams`:
--   "arm"  - the committing flank strains: the seams of `state.aimSide`.
--   "both" - whole-body strain (a breath, a shrug of the whole summit).
--   "none" / absent - nothing opens.
function Fn.pyreliskSeamMask(state, seams: string?): number
	if seams == "both" then
		return K.PY_SEAM_MASK_L + K.PY_SEAM_MASK_R
	elseif seams == "arm" then
		return if (state.aimSide or 1) < 0 then K.PY_SEAM_MASK_R else K.PY_SEAM_MASK_L
	end
	return 0
end

-- Called from every windup frame (the aim is already latched by then, so
-- `aimSide` is the flank that is about to commit) and idempotent.
function Fn.pyreliskOpenSeams(state, p)
	state.seamsOpen = Fn.pyreliskSeamMask(state, p.seams)
end

-- THE MASK IS CLEARED ON EVERY EXIT, and there are five of them. Four are
-- swept by one line in `Fn.placeColossus` - "no attack running means no seam
-- open" - because every one of them ends with `creature.attack` nil:
--
--   exit                                  where the mask is cleared
--   ------------------------------------  ----------------------------------
--   recover runs to its end               here, from Fn.pyreliskRecoverPose /
--                                         handfall's own recover
--   Fn.openStagger (nils creature.attack)    Fn.placeColossus sweep, same frame
--   Fn.endBossAttack (nils creature.attack)  Fn.placeColossus sweep, same frame
--   Fn.updateBossAttack's missing-handler    Fn.endBossAttack, then the sweep
--   beginBossCollapse (nils it too)       Fn.placeColossus sweep, same frame
--
-- A mask left set after its attack is the lie this system cannot tell, so the
-- sweep is unconditional rather than a set of matched pairs.
function Fn.pyreliskCloseSeams(state)
	state.seamsOpen = 0
end

-- Does this ray reach an OPEN seam? Returns that seam's flank (+1 / -1) and
-- the distance along the ray, or nil.
--
-- The normal test is what makes this a seam and not a sphere: a shot whose
-- direction AGREES with the seam's outward normal is travelling into the
-- shell from behind it - it came through the far side of a mountain - and
-- must not land. Only a shot arriving from the side the seam faces counts.
function Fn.pyreliskSeamOnRay(creature, origin: Vector3, dir: Vector3, maxT: number): (number?, number?)
	local state = Fn.pyreliskSeamState(creature)
	if state == nil then
		return nil, nil
	end
	local open = state.seamsOpen or 0
	if open == 0 then
		return nil, nil
	end
	local bestSide, bestT = nil, maxT
	for index, side in K.PY_SEAM_FLANK do
		if side ~= 0 and bit32.band(open, bit32.lshift(1, index - 1)) ~= 0 then
			local at, out = PyreliskPath.seamPoint(state, index)
			if out:Dot(dir) < 0 then
				local to = at - origin
				local t = to:Dot(dir)
				if t > 0 and t < bestT and (to - dir * t).Magnitude <= K.PY_SEAM_HIT_RADIUS then
					bestSide, bestT = side, t
				end
			end
		end
	end
	if bestSide == nil then
		return nil, nil
	end
	return bestSide, bestT
end

-- THE NARROW BYPASS, and it is narrow on purpose. `raycastNearest` is the only
-- thing that can judge a seam hit - it is the only place a ray exists - but
-- `damage()` is where the untargetable gate lives, and the two are separated
-- by the shot's flight. So a seam hit that WINS its ray leaves a claim on the
-- creature, and `damage()` spends exactly one claim to get through the gate.
-- Claims expire (K.PY_SEAM_CLAIM_LIFE), are capped (K.PY_SEAM_CLAIM_CAP), and are
-- spent one per hit, so nothing can farm a single seam shot into free damage.
function Fn.pyreliskSeamArm(creature, side: number, now: number)
	local claims = creature.seamClaims
	if claims == nil then
		claims = {}
		creature.seamClaims = claims
	end
	if #claims >= K.PY_SEAM_CLAIM_CAP then
		table.remove(claims, 1)
	end
	table.insert(claims, { side = side, expires = now + K.PY_SEAM_CLAIM_LIFE })
end

-- Spend the oldest live claim, dropping any that have expired. Returns the
-- flank that shot lands on, or nil - and nil is what every other creature in
-- the game returns, always.
function Fn.pyreliskSeamClaim(creature): number?
	local claims = creature.seamClaims
	if claims == nil or #claims == 0 then
		return nil
	end
	local now = os.clock()
	while #claims > 0 do
		local claim = table.remove(claims, 1)
		if now <= claim.expires then
			return claim.side
		end
	end
	return nil
end

-- THE PARTY'S SCALING FACTOR, read off the record rather than recomputed.
-- `BossService.raise` fixes it at summon (a mid-fight rescale is the
-- leave-and-shrink exploit) and rides it in on `extra.healthMult`, which
-- `spawn` already reads; `Fn.spawnBossParts` reads the same field for the
-- parts ring. Nothing else may work out how big the party is, because a second
-- answer to that question is a second answer.
--
-- Generic, and deliberately not pyrelisk-named: the seam meters are its first
-- caller, not its only possible one.
function Fn.partyMult(creature): number
	local extra = creature.extra
	local mult = extra and extra.healthMult
	if type(mult) ~= "number" or mult <= 0 then
		return 1
	end
	return mult
end

-- Put `fraction` of one flank's meter in, and SCAR that flank if it fills.
--
-- THE ONE PLACE THE SCAR MASK IS EVER SET. It has two callers with nothing in
-- common - a seam hit (damage, divided by the meter's HP and the party) and
-- the monolith bait (a flat fraction off `handfall.seamCredit`) - and a second
-- copy of the full-meter branch beside either of them would be the scar mask
-- written in two places, to be got wrong separately. The mask is the client's
-- contract and is monotonic for the life of the fight; a lane that sets it
-- somewhere else is the bug this function exists to make impossible.
--
-- `creature.seamBreakSide` is the debt, spent on the boss's own tick, because
-- `Fn.openStagger` lives with the fight's window machinery and a damage call
-- has no business opening a window from inside CombatService's shot queue.
function Fn.pyreliskMeterFill(creature, state, side: number, fraction: number)
	if fraction <= 0 then
		return
	end
	local key = if side < 0 then "seamMeterR" else "seamMeterL"
	local meter = (state[key] or 0) + fraction
	if meter < 1 then
		state[key] = meter
		return
	end
	state[key] = 0
	state.seamsBroken = bit32.bor(state.seamsBroken or 0, if side < 0 then K.PY_SEAM_MASK_R else K.PY_SEAM_MASK_L)
	creature.seamBreakSide = side
end

-- Fill a flank's meter with what the hit actually dealt, DIVIDED BY THE PARTY.
--
-- The divisor is the gap this closes (design flag F-1): every other wall in
-- this fight - the arms, and the parts ring generally - has carried
-- `extra.healthMult` since `Fn.spawnBossParts` was written, and the seam
-- meters, which are the largest wall of the four acts, carried nothing. A
-- four-stack filled a flank in a quarter of the time a solo player did, so act
-- 1 got SHORTER as the party got bigger, which is the exact backwards the
-- parts ring's own comment warns about.
function Fn.pyreliskSeamCredit(creature, side: number, amount: number)
	local state = Fn.pyreliskSeamState(creature)
	if state == nil or amount <= 0 then
		return
	end
	Fn.pyreliskMeterFill(creature, state, side, amount / (K.PY_SEAM_METER_HP * Fn.partyMult(creature)))
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
	local seamCreature, seamSide = nil, nil
	for _, creature in creatures do
		-- THE SEAM DOOR, and it is OUTSIDE the `Fn.unaimable` gate on purpose.
		-- The colossus's body stays exactly as unshootable as it was - this
		-- does not widen a capture sphere or clear a flag - but a ray that
		-- passes through one of its open seams, from the side that seam
		-- faces, selects it. Inert for every creature that is not a pyrelisk
		-- with seams open right now: `Fn.pyreliskSeamOnRay` returns on its
		-- poseKind check before it touches geometry.
		if not creature.dead and not creature.friendly then
			local side, seamT = Fn.pyreliskSeamOnRay(creature, origin, dir, bestT)
			if side then
				best, bestT = creature, seamT
				seamCreature, seamSide = creature, side
			end
		end
		-- `origin` is the shooter's own position, not the camera's: CombatService
		-- takes it from the client but ShotAim.originOk refuses any origin more
		-- than ORIGIN_SLACK (6) studs off the firer's root.
		if not creature.dead and not Fn.unaimable(creature, origin) and not creature.friendly then
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
					if t > 0 and t < bestT and (to - dir * t).Magnitude <= node.radius + K.RF_SHOT_SLACK then
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
				-- (only the colossus branch of Fn.updateBoss sets it), so this whole
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
						-- THE ROW'S OWN ANSWER FIRST, if it has one. A row that
						-- carries `shotRadius` is one whose size the derived
						-- formula below gets wrong for the fight it is in -
						-- Wrack's shootable props, which are small, low, and in
						-- two cases MOVING while you shoot at them. Authored
						-- rather than derived because the client's aim depth has
						-- to agree with this number, and it cannot agree with a
						-- formula it re-runs on its own copy of the model (see
						-- ATTR.SHOT_RADIUS).
						radius = creature.row.shotRadius
					end
					if not radius then
						-- Half the bounding sphere reads generous on purpose - a
						-- shot that visibly clips a fin should land. Cached: the
						-- model's size doesn't change (the bloater's swell is the
						-- one exception, and being EASIER to hit as it swells is
						-- correct anyway).
						local _, size = creature.model:GetBoundingBox()
						radius = math.max(1.4, size.Magnitude * 0.3)
					end
					creature.shotRadius = radius
					local perpendicular = (to - dir * t).Magnitude
					if perpendicular <= radius + (creature.hitRadius or 0) then
						best, bestT = creature, t
					end
				end
			end
		end
	end
	-- ...and the claim is left only if the seam actually WON the ray. A nearer
	-- creature between the shooter and the boss takes the shot, and then no
	-- claim is owed: leaving one would let an unrelated hit later spend it.
	if seamCreature ~= nil and best == seamCreature then
		Fn.pyreliskSeamArm(seamCreature, seamSide, os.clock())
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
	-- ...AND IT TAKES THE HOLE IN THE MOUNTAIN WITH IT.
	--
	-- `PyreliskCaldera` lives on the ARENA model, so it survives every creature
	-- in the fight. Left at 1 it is not a stale attribute, it is a LOADED TRAP
	-- for the next party: the volcano's next summon opens on an act-1 fight
	-- whose moat is a 120-stud hole with no lake floor under it, and the first
	-- person to walk out onto the rim path falls through the middle of their
	-- own arena with no boss at the bottom of it.
	--
	-- HERE because this is the ONE choke point both endings pass through:
	-- `kill()` calls it, and so does `CreatureService.despawn`, which is what
	-- BossService's abandon reaper uses. One line, both paths, no third place
	-- to forget.
	--
	-- ON THE HEART AND NOT ON THE COLOSSUS, and that is the whole subtlety. The
	-- colossus's death is a HANDOFF, not an ending - it dies at the bottom of
	-- its collapse having just opened the caldera on purpose, and resetting
	-- here would slam the hole shut in the same breath that opened it, which is
	-- the one bug this rule could plausibly introduce. The colossus abandoned
	-- mid-fight never opened it at all (it only opens during the death fall),
	-- so there is nothing for its teardown to close. The heart is the last
	-- creature in the chain either way: it dies (victory) or it is reaped
	-- (abandoned), and both come through here.
	if creature.row and creature.row.boss == K.PY_HEART_BOSS then
		local heart = Bosses.items[K.PY_HEART_BOSS]
		Fn.pyreliskCloseCaldera(heart and heart.islandId)
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

	-- RIMEFANG'S SHATTERED SHEET is the one hazard in the project that
	-- outlives the attack that made it: the four thin-ice pools carry a
	-- fight-long duration (K.RF_SHEET_LIFE), so nothing else would ever
	-- expire them. The fight is over - drop them where the body drops.
	-- Guarded on the row, so no other boss's pools change behaviour.
	if creature.row.boss == K.RIMEFANG_BOSS then
		creature.pools = nil
	end

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
	-- head while partsAlive > 0; Fn.updateBoss owns the regrow clock).
	local owner = creature.partOf
	if owner and not owner.dead and owner.partsAlive then
		owner.partsAlive = math.max(0, owner.partsAlive - 1)
		-- THE LANTERN CHOIR: WHICH stalk died is the fight. Breaking the
		-- MARKED one - the true lure, the one whose light breathes out of
		-- step - brings the maw up; breaking any other one flares white and
		-- the trench takes a swing at whoever shot it. Recorded here rather
		-- than acted on, so kill() stays free of the fight's machinery;
		-- Fn.updateBoss answers both on the next frame.
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
			owner.model:SetAttribute(ATTR.EXPOSED, true)
			fireCreatureEvent("exposed", owner.pos, {
				name = owner.model:GetAttribute(ATTR.BOSS_NAME),
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
-- on the shelf. Her hitRadius is 6 x the row's 2.0 scale = 12, and
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
-- corners measure 25.1 studs from the gullet at full gape - so the test
-- degrades into "be at her mouth" rather than into a locked door. `insideMouth`
-- is still honoured first, so standing on the floor ALWAYS counts even if the
-- gullet offset later moves.
--
-- Clamping `hitRadius` for the window was the other option and is wrong: melee
-- reach is measured off that same number from the model's PIVOT, which is the
-- skull's origin ~20 studs up, so shrinking it makes the mouth unmeleeable
-- from inside the mouth.
K.NOCTYSS_GULLET_REACH = 26.7
-- Assigns the local forward-declared up by `Fn.unaimable`, which needs this exact
-- ruling to keep target selection and `damage()` from drifting apart.
function noctyssInReach(state, position: Vector3): boolean
	if NoctyssPath.insideMouth(state, position) then
		return true
	end
	return (position - NoctyssPath.gulletPosition(state)).Magnitude <= K.NOCTYSS_GULLET_REACH
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
	-- Every reason a thing cannot be hit, in one place - see `Fn.unaimable`. All
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
	-- THE SEAM DOOR'S OTHER HALF. `raycastNearest` has already judged the
	-- geometry - this ray passed inside K.PY_SEAM_HIT_RADIUS of an OPEN seam,
	-- from the side it faces, and won its ray - and left a claim saying so.
	-- Spending one here is what lets that shot through a gate the body is
	-- still behind, and it is the ONLY thing that does: the flag, `Fn.unaimable`
	-- and every other consumer of both are untouched.
	--
	-- Asked before `ignoreUntargetable` rather than after, so a poison tick
	-- (which is already exempt) can never eat a claim a real shot is owed.
	-- Returns nil for every creature in the game that is not a pyrelisk with
	-- a live claim on it.
	local seamSide = nil
	if not (opts and opts.ignoreUntargetable) then
		seamSide = Fn.pyreliskSeamClaim(creature)
	end
	if seamSide == nil and Fn.unaimable(creature) and not (opts and opts.ignoreUntargetable) then
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
	-- MEANS for its other consumers, all of which were checked: `Fn.unaimable`
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

	-- THE SHATTER'S WINDOW OF NOTHING. Rimefang's phase-two opener is the
	-- one beat in the fight the party cannot trade with, and the whale is
	-- immune for its windup and its strike (K.ATTACK_HANDLERS.shatter sets
	-- the deadline; the row guard means every other creature in the game
	-- reads a nil field and falls straight through).
	--
	-- IT RETURNS THE HEALTH, NOT NIL. `damage()` returning nil means 'that
	-- shot did not connect at all', which is the immune-boss-body bug the
	-- Kraken's head note is about: the swing eats its cooldown and the
	-- player sees a broken weapon rather than a blocked hit. This is a hit
	-- that dealt nothing, and the credit and despawn bookkeeping above has
	-- already run, so a party that keeps swinging through the opener keeps
	-- its participation.
	if creature.rfInvulnUntil and creature.row.boss == K.RIMEFANG_BOSS and os.clock() < creature.rfInvulnUntil then
		return creature.health
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
				creature.model:SetAttribute(ATTR.CRACKED, true)
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

	-- A seam hit fills the flank it went through, with what the blow actually
	-- dealt after every multiplier above - so a perk, a trinket or an armour
	-- set makes the window come sooner, exactly as it makes the boss die
	-- sooner. Credited before the health line so a killing blow still counts
	-- toward a meter nobody will ever see, rather than being a special case.
	if seamSide ~= nil then
		Fn.pyreliskSeamCredit(creature, seamSide, amount)
	end

	creature.health = math.max(0, creature.health - amount)
	creature.model:SetAttribute(ATTR.HEALTH, creature.health)

	-- THE RIPOSTE. Act three's signature, and the one move in the whole fight
	-- whose answer is to stop shooting: while the Admiral holds guard, the first
	-- hit he takes is answered.
	--
	-- IT LIVES HERE, NOT IN `hitModifiers`, and the distinction is real rather
	-- than tidiness. `hitModifiers` answers "how much does this hit do", is
	-- first-match, and is consulted for things that are not hits at all; a
	-- counter is a CONSEQUENCE of a hit landing, so it belongs after the health
	-- has actually moved - which also means it cannot shadow a branch above it
	-- or fire on a hit that was refused.
	--
	-- Guarded on a field only the duel ever sets, so this is one nil test for
	-- every other creature in the game.
	if creature.riposteUntil and os.clock() < creature.riposteUntil and not creature.dead then
		Fn.wrackRiposte(creature, os.clock())
	end

	-- Ashfeather Phoenix: its first death isn't one. It goes down untouchable
	-- for a moment, then rises at a fraction of its health and has to be killed
	-- again. Checked before kill() so nothing downstream (loot, the chain, the
	-- boss's participant list) ever sees the first death happen.
	if creature.health <= 0 and creature.row.archetype == "reborn" and not creature.rebornUsed then
		creature.rebornUsed = true
		creature.untargetable = true
		creature.knockVel = nil
		creature.downUntil = os.clock() + C.REBORN_DOWN
		creature.model:SetAttribute(ATTR.DOWNED, true)
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
	-- A HOT KNUCKLE, and it is the first question because it is the strongest
	-- answer: a Kraken arm that is Down, Wrapped or planted has one glowing
	-- joint on it and hitting the arm while that joint is lit is worth triple.
	--
	-- ASKED OF THE ARM, NOT OF A POSITION. `from` here is the ATTACKER's
	-- position (CombatService's only caller passes the shooter's root), not
	-- where the shot struck, so a positional test against `WeakpointPos` would
	-- be measuring the wrong end of the line - it would reward standing near
	-- the knuckle rather than hitting it. The knuckle's coordinates are
	-- published for the RENDERER (ATTR.WEAKPOINT_POS, the contract at the top of
	-- this file); what gates the multiplier is the window, which is the thing
	-- the fight actually asks you to play around: the arm is only vulnerable
	-- while it is committed to something, and being committed is what the phase
	-- attributes say out loud.
	--
	-- Off the struct rather than off the model attribute, deliberately - one
	-- writer (the fight tick) sets both together, and a GetAttribute in the
	-- damage path of every hit in the game is a cost nothing else here pays.
	if creature.krakenHot then
		return K.KRAKEN.WEAK_MULT, 0
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
	-- A LIT EYE, on the Kraken's HEAD rather than on one of its arms - the only
	-- window in the fight on the animal itself that is not the siphon window (the
	-- new-attacks pass, 2026-09-12; the design is on
	-- Bosses.items.kraken.attacks.eyelance, which now carries `glint`).
	--
	-- IT IS ITS OWN BRANCH RATHER THAN `exposedUntil` BECAUSE IT IS A DIFFERENT
	-- NUMBER, and the distinction is the charger's ruling rather than a preference:
	-- `exposedUntil` means a creature that OVER-COMMITTED and is standing there
	-- helpless, which is worth 2x everywhere in this file. An eye that has just
	-- fired a lance has not over-committed, it has merely finished, so the window is
	-- priced at 1.5 - small enough to COMPETE with the arms for the party's
	-- attention instead of replacing them, which is the choice the opening is for.
	--
	-- AFTER the expose branch, deliberately and for the one case where both are
	-- open: the head is `Exposed` for the whole siphon window and for the siphon
	-- overcharge's charge, and both of those are worth 2x. Checked in this order,
	-- the bigger window simply wins and a glint can never make one of them cheaper.
	if creature.krakenGlintUntil and os.clock() < creature.krakenGlintUntil then
		return K.KRAKEN.GLINT_MULT, 0
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
		creature.model:SetAttribute(ATTR.FLOPS, (creature.model:GetAttribute(ATTR.FLOPS) or 0) + 1)
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
function Fn.nearestPlayerRoot(pos: Vector3): (BasePart?, Player?, number)
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
function Fn.resolveHorizontal(creature, delta: Vector3): (Vector3, boolean)
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
function Fn.slideKnockback(creature, dt: number)
	if creature.knockVel then
		local delta = Vector3.new(creature.knockVel.X, 0, creature.knockVel.Z) * dt
		local newPos, blocked = Fn.resolveHorizontal(creature, delta)
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
function Fn.updateAirborne(creature, dt: number)
	-- Horizontal drift: same push the ground slide uses, just damped gently.
	if creature.knockVel then
		local delta = Vector3.new(creature.knockVel.X, 0, creature.knockVel.Z) * dt
		local newPos, blocked = Fn.resolveHorizontal(creature, delta)
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
			creature.model:SetAttribute(ATTR.FLOPS, (creature.model:GetAttribute(ATTR.FLOPS) or 0) + 1)
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
function Fn.updateRusher(creature, now: number, dt: number)
	Fn.slideKnockback(creature, dt)

	if not creature.mode then
		creature.mode = "idle"
		creature.modeUntil = now + randomBetween(C.RUSH_REST_MIN, C.RUSH_REST_MAX)
		creature.lastHitAt = 0
	end

	local root, player, dist = Fn.nearestPlayerRoot(creature.pos)

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
		local newPos, blocked = Fn.resolveHorizontal(creature, creature.rushDir * C.RUSH_SPEED * dt)
		creature.pos = newPos
		creature.yaw0 = yawToward(creature.rushDir)
		local u = math.clamp((now - creature.rushStart) / C.RUSH_DURATION, 0, 1)
		local hop = C.RUSH_HOP * math.abs(math.sin(u * math.pi * C.RUSH_HOPS))
		creature.model:PivotTo(poseCFrame(creature, hop, 0, C.RUSH_PITCH))

		if root and player and dist <= C.CONTACT_RADIUS and now - creature.lastHitAt >= C.CONTACT_COOLDOWN then
			creature.lastHitAt = now
			PlayerService.damage(player, math.random(C.CONTACT_DAMAGE_MIN, C.CONTACT_DAMAGE_MAX), creature)
			-- Recoil back off the ram (also obstacle-checked) and flop again.
			creature.pos = Fn.resolveHorizontal(creature, -creature.rushDir * C.CONTACT_BOUNCE)
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
function Fn.updateShambler(creature, now: number, dt: number)
	Fn.slideKnockback(creature, dt)
	creature.lastHitAt = creature.lastHitAt or 0

	local root, player, dist = Fn.nearestPlayerRoot(creature.pos)
	if root and dist <= C.SHAMBLE_AGGRO then
		-- Turn toward the player and step forward.
		creature.yaw0 = approachAngle(creature.yaw0, yawToward(root.Position - creature.pos), C.SHAMBLE_TURN_RATE * dt)
		local forward = flatUnit(root.Position - creature.pos)
		creature.pos = Fn.resolveHorizontal(creature, forward * C.SHAMBLE_SPEED * dt)

		-- A trudging bob so the stand-and-slide reads as walking.
		local bob = math.abs(math.sin(now * C.SHAMBLE_BOB_RATE)) * C.SHAMBLE_BOB
		creature.model:PivotTo(poseCFrame(creature, bob, 0, 0))

		if player and dist <= C.CONTACT_RADIUS and now - creature.lastHitAt >= C.CONTACT_COOLDOWN then
			creature.lastHitAt = now
			PlayerService.damage(player, math.random(C.CONTACT_DAMAGE_MIN, C.CONTACT_DAMAGE_MAX), creature)
			creature.pos = Fn.resolveHorizontal(creature, -forward * C.CONTACT_BOUNCE)
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
-- through Fn.resolveHorizontal, one PivotTo per frame, contact damage through
-- PlayerService.damage. Each is written to tolerate being interrupted by a
-- juggle (Fn.updateAirborne pre-empts them): timers are absolute, so the next
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
function Fn.tryContact(
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
function Fn.setBuried(creature, buried: boolean)
	creature.untargetable = buried
	creature.knockVel = nil
	creature.model:SetAttribute(ATTR.BURIED, buried)
end

-- ---------------------------------------------------------------- charger (Tideline Skipper)
-- idle -> windup -> dash (straight past the player, one hit on the way
-- through) -> turning (exposed: hits land double) -> idle.
function Fn.updateCharger(creature, now: number, dt: number)
	Fn.slideKnockback(creature, dt)
	if not creature.mode then
		setMode(creature, "idle", randomBetween(C.CHARGE_REST_MIN, C.CHARGE_REST_MAX), now)
		creature.lastHitAt = 0
	end
	local model = creature.model
	local root, player, dist = Fn.nearestPlayerRoot(creature.pos)

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
			model:SetAttribute(ATTR.DASHING, true)
		end
	elseif creature.mode == "dash" then
		local step = C.CHARGE_SPEED * dt
		local newPos, blocked = Fn.resolveHorizontal(creature, creature.rushDir * step)
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
			model:SetAttribute(ATTR.DASHING, false)
			model:SetAttribute(ATTR.EXPOSED, true)
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
			model:SetAttribute(ATTR.EXPOSED, false)
			setMode(creature, "idle", randomBetween(C.CHARGE_REST_MIN, C.CHARGE_REST_MAX), now)
		end
	end
end

-- ---------------------------------------------------------------- spitter (Gullet Cod)
-- Keeps SPIT_MIN..MAX_RANGE from the player, rears up, spits. The glob is a
-- timer on the struct: it lands at the player's position AT LAUNCH after
-- SPIT_FLIGHT seconds (the dodge window) - the clients draw the arc from the
-- "spit" event, the server only decides the landing. Fn.landSpit runs from
-- update() regardless of what the cod is doing by then.
function Fn.landSpit(creature)
	local spit = creature.spit
	creature.spit = nil
	damagePlayersInRadius(spit.landing, C.SPIT_SPLASH_RADIUS, C.SPIT_DAMAGE_MIN, C.SPIT_DAMAGE_MAX, creature, 0.5)
	fireEvent("splash", spit.landing, { radius = C.SPIT_SPLASH_RADIUS })
end

function Fn.updateSpitter(creature, now: number, dt: number)
	Fn.slideKnockback(creature, dt)
	if not creature.mode then
		setMode(creature, "idle", randomBetween(C.SPIT_INTERVAL_MIN, C.SPIT_INTERVAL_MAX), now)
	end
	local model = creature.model
	local root, _, dist = Fn.nearestPlayerRoot(creature.pos)

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
			creature.pos = Fn.resolveHorizontal(creature, move * C.SPIT_HOP_SPEED * dt)
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

function Fn.updateBloater(creature, now: number, dt: number)
	Fn.slideKnockback(creature, dt)
	local root, _, dist = Fn.nearestPlayerRoot(creature.pos)

	local hop, yaw, pitch = flop(creature, now)
	if root and dist <= C.BLOAT_AGGRO and dist > 2 then
		creature.yaw0 = approachAngle(creature.yaw0, yawToward(root.Position - creature.pos), C.RUSH_TURN_RATE * dt)
		creature.pos = Fn.resolveHorizontal(creature, flatUnit(root.Position - creature.pos) * C.BLOAT_ROLL_SPEED * dt)
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
function Fn.updateDrifter(creature, now: number, dt: number)
	Fn.slideKnockback(creature, dt)
	local root, player, dist = Fn.nearestPlayerRoot(creature.pos)

	if root and dist <= C.DRIFT_AGGRO then
		creature.yaw0 = approachAngle(creature.yaw0, yawToward(root.Position - creature.pos), C.RUSH_TURN_RATE * dt)
		if dist > C.DRIFT_CONTACT_RADIUS * 0.6 then
			creature.pos = Fn.resolveHorizontal(creature, flatUnit(root.Position - creature.pos) * C.DRIFT_SPEED * dt)
		end
		Fn.tryContact(creature, player, dist, C.DRIFT_CONTACT_RADIUS, C.DRIFT_DAMAGE_MIN, C.DRIFT_DAMAGE_MAX, now)
	end

	local bob = math.sin(now * C.DRIFT_BOB_RATE + creature.spawnedAt) * C.DRIFT_BOB
	creature.model:PivotTo(poseCFrame(creature, C.DRIFT_HOVER + bob, 0, 0))
end

-- ---------------------------------------------------------------- burrower (Sand Lurker)
-- surfaced (hittable, flops) -> sinking -> buried (hidden, untargetable,
-- tunnels at the player) -> emerging (bursts up and bites) -> surfaced.
function Fn.updateBurrower(creature, now: number, dt: number)
	local model = creature.model
	if not creature.mode then
		setMode(creature, "surfaced", C.BURROW_SURFACE_TIME, now)
	end
	local root, _, dist = Fn.nearestPlayerRoot(creature.pos)

	if creature.mode == "surfaced" then
		Fn.slideKnockback(creature, dt)
		local hop, yaw, pitch = flop(creature, now)
		if root then
			creature.yaw0 = approachAngle(creature.yaw0, yawToward(root.Position - creature.pos), C.RUSH_TURN_RATE * dt)
		end
		model:PivotTo(poseCFrame(creature, hop, yaw, pitch))
		if now >= creature.modeUntil and root and dist <= C.BURROW_AGGRO then
			setMode(creature, "sinking", C.BURROW_SINK_TIME, now)
			Fn.setBuried(creature, true)
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
			creature.pos = Fn.resolveHorizontal(creature, flatUnit(root.Position - creature.pos) * C.BURROW_SPEED * dt)
		end
		model:PivotTo(poseCFrame(creature, -C.BURROW_DEPTH, 0, 0))
		if root and dist <= C.BURROW_AMBUSH_RADIUS then
			setMode(creature, "emerging", C.BURROW_EMERGE_TIME, now)
			Fn.setBuried(creature, false)
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
function Fn.updateMimic(creature, now: number, dt: number)
	local model = creature.model
	if not creature.mode then
		setMode(creature, "closed", C.MIMIC_CLOSED_MIN, now)
		creature.untargetable = true
		model:SetAttribute(ATTR.OPEN, false)
		local body = model.PrimaryPart
		local lid = model:FindFirstChild("Fish_Fins")
		if body and lid and lid:IsA("BasePart") then
			creature.lid = lid
			creature.lidOffset = body.CFrame:ToObjectSpace(lid.CFrame)
		end
	end
	local root, _, dist = Fn.nearestPlayerRoot(creature.pos)
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
			model:SetAttribute(ATTR.OPEN, true)
		end
	else -- open: hangs wide, then shuts quickly at the end
		Fn.slideKnockback(creature, dt)
		local u = modeProgress(creature, now)
		lidAngle = C.MIMIC_LID_OPEN * (1 - u * u * u)
		model:PivotTo(poseCFrame(creature, 0, 0, 0))
		if u >= 1 then
			setMode(creature, "closed", C.MIMIC_CLOSED_MIN, now)
			creature.untargetable = true
			creature.knockVel = nil
			model:SetAttribute(ATTR.OPEN, false)
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
function Fn.stealCoins(creature, player: Player, now: number): number
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

function Fn.updateThief(creature, now: number, dt: number)
	Fn.slideKnockback(creature, dt)
	if not creature.mode then
		setMode(creature, "chase", 0, now)
		creature.lastHitAt = 0
	end
	local model = creature.model
	local root, player, dist = Fn.nearestPlayerRoot(creature.pos)
	local hop = C.THIEF_HOP * math.abs(math.sin(now * C.THIEF_HOP_RATE))

	if creature.mode == "flee" then
		if root then
			local away = flatUnit(creature.pos - root.Position)
			local zig = math.sin(now * C.THIEF_ZIGZAG_RATE) * C.THIEF_ZIGZAG
			local dir = CFrame.Angles(0, zig, 0) * away
			creature.yaw0 = yawToward(dir)
			local newPos, blocked = Fn.resolveHorizontal(creature, dir * C.THIEF_FLEE_SPEED * dt)
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
		creature.pos = Fn.resolveHorizontal(creature, flatUnit(root.Position - creature.pos) * C.THIEF_SPEED * dt)
		model:PivotTo(poseCFrame(creature, hop, 0, 0))
		if
			Fn.tryContact(
				creature,
				player,
				dist,
				C.CONTACT_RADIUS,
				C.THIEF_CONTACT_DAMAGE_MIN,
				C.THIEF_CONTACT_DAMAGE_MAX,
				now
			)
		then
			if Fn.stealCoins(creature, player, now) > 0 then
				setMode(creature, "flee", C.THIEF_FLEE_TIME, now)
			else
				-- Nothing to take: bounce off like a rusher and try again.
				creature.pos =
					Fn.resolveHorizontal(creature, -flatUnit(root.Position - creature.pos) * C.CONTACT_BOUNCE)
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
function Fn.updatePulser(creature, now: number, dt: number)
	Fn.slideKnockback(creature, dt)
	if not creature.mode then
		setMode(creature, "idle", randomBetween(C.PULSE_IDLE_MIN, C.PULSE_IDLE_MAX), now)
	end
	local model = creature.model
	local root, _, dist = Fn.nearestPlayerRoot(creature.pos)

	if creature.mode == "charging" then
		local u = modeProgress(creature, now)
		local quiver = math.sin(now * 40) * math.rad(3) * u
		model:PivotTo(poseCFrame(creature, 0.1 * u, quiver, 0))
		if now >= creature.modeUntil then
			creature.charging = false
			model:SetAttribute(ATTR.CHARGING, false)
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
			creature.pos = Fn.resolveHorizontal(creature, flatUnit(root.Position - creature.pos) * C.PULSE_SPEED * dt)
		end
		if now >= creature.modeUntil and dist <= C.PULSE_TRIGGER_RANGE then
			setMode(creature, "charging", C.PULSE_CHARGE, now)
			creature.charging = true
			model:SetAttribute(ATTR.CHARGING, true)
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
K.BOSS_HEIGHT_TOLERANCE = 14

-- Forward: defined with the boss arsenal below (dive's shatter, defined
-- above it, spawns one too).
local spawnPool

-- World-space unit vector the boss is facing (an upright creature's local
-- +X, turned by yaw0).
function Fn.bossFacing(creature): Vector3
	return Vector3.new(math.cos(creature.yaw0), 0, -math.sin(creature.yaw0))
end

-- A boss attack's damage range, enraged or not.
function Fn.bossRoll(creature, def, range: { number }): (number, number)
	local mult = if creature.enraged then def.enrageDamageMult else 1
	return math.floor(range[1] * mult + 0.5), math.floor(range[2] * mult + 0.5)
end

-- Hurts every living player within `radius` of `at` whose direction from it
-- lies inside the cone of half-angle `halfAngle` about `facing` - or, with
-- `invert`, everyone in range who is NOT in that cone (the tail lash: all
-- round except dead ahead).
function Fn.damagePlayersInCone(
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
function Fn.clampToArena(creature, def)
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
function Fn.scatterAround(root: BasePart, spread: number): Vector3
	local angle = math.random() * math.pi * 2
	local r = math.sqrt(math.random()) * spread
	local at = root.Position + Vector3.new(math.cos(angle) * r, 0, math.sin(angle) * r)
	return groundedPos(at, 0)
end

-- Queue a projectile that lands on its own clock (the update loop lands it,
-- even mid-attack) and tell the clients to draw it flying.
--
-- `origin` is where the throw comes FROM, and it is optional because for
-- every ordinary creature the answer is the same: its mouth, a few studs
-- ahead of the pivot. A posed boss is the exception - Pyrelisk's proxy pivot
-- is a 23-stud lump standing at the feet of a 270-stud body, so the default
-- launched its shoulder slabs out of the colossus's ANKLES while the hand
-- that tore them off was 333 studs up and a hundred studs away. A caller
-- that knows where its own hand is passes it; nothing else has to change.
function Fn.throwGlob(
	creature,
	def,
	p,
	landing: Vector3,
	flight: number,
	now: number,
	event: string,
	drawKind: string,
	extras: { [string]: any }?,
	origin: Vector3?
)
	creature.globs = creature.globs or {}
	local lo, hi = Fn.bossRoll(creature, def, p.damage)
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
	local mouth = origin or (creature.model:GetPivot().Position + Fn.bossFacing(creature) * 4 + Vector3.new(0, 2, 0))
	-- `boss = true` picks the boss's own sound set on the client.
	fireEvent(drawKind, mouth, { to = landing, flight = flight, arc = 10, boss = true })
end

function Fn.bossMouth(creature): Vector3
	return creature.model:GetPivot().Position + Fn.bossFacing(creature) * 5
end

-- Attack handlers. Each may define:
--   windup(creature, def, p, u, sub)               - pose the tell (u 0..1)
--   fire(creature, def, p, now, root, player, dist)  - once, as the strike begins
--   strike(creature, def, p, now, dt, u, root, sub)  - per frame during the strike (u 0..1)
--   finish(creature, def, p, now)                    - once, as the strike ends
--   recover(creature, def, p, u, sub)                - pose the recovery (u 0..1)
-- A handler without a pose hook just sits at its submerged rest pose.
K.ATTACK_HANDLERS = {}

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
-- (`K.SLAM_IMPACT`); it is not on this table only because its row opts out of
-- the stock tell and fires its own marker. Any handler added here that
-- damages mid-strike belongs on this table, or its tell will lie by
-- construction.
K.PHANTOM_IMPACT = 0.80
K.LUNGE_IMPACT = 0.72
K.RINGPULSE_IMPACT = 0.95
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
K.HANDFALL_IMPACT = 0.95
K.RIMSWEEP_IMPACT = 1.0
K.VENTBREATH_IMPACT = 1.0
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
K.CHARGE_IMPACT = 1.0
-- A BITE CLOSES ITS JAWS PART-WAY IN, and `snap` always has: its handler
-- damages at `u >= K.SNAP_IMPACT` of the strike, and the constant below is the
-- one the handler reads, so the countdown and the jaws cannot drift apart the
-- way they could while that 0.4 was a literal in one place and absent in the
-- other. Worth 0.14s on both rows that use it (a 0.35s strike): Gnashroot's
-- bite and Rimefang's. The four kitted hostile rows on `snap` gain the same
-- honesty, since a kit runs this very loop.
K.SNAP_IMPACT = 0.4
K.HANDLER_IMPACT = {
	charge = K.CHARGE_IMPACT,
	snap = K.SNAP_IMPACT,
	phantom = K.PHANTOM_IMPACT,
	lunge = K.LUNGE_IMPACT,
	ringpulse = K.RINGPULSE_IMPACT,
	handfall = K.HANDFALL_IMPACT,
	rimsweep = K.RIMSWEEP_IMPACT,
	ventbreath = K.VENTBREATH_IMPACT,
}

-- ------------------------------------------------------- conducting a ring
--
-- A boss with a `parts` ring (the Kraken) does not need a second system to
-- animate its arms: every arm is already a creature with a rear-slam-recover
-- machine of its own (Fn.updateTentacle), and the client already draws the limb
-- to wherever that creature is. So an arm attack is not new choreography - it
-- is the boss ORDERING arms that were going to slam anyway to slam together,
-- in an order it chooses, on its clock instead of theirs.
--
-- That is the whole trick, and it is why these handlers are short. What they
-- buy is the difference between eight things that happen to be near you and
-- one animal using eight arms.

-- Its live arms in RING ORDER, on the socket index Fn.spawnBossParts already
-- stamps. Dead arms leave gaps rather than renumbering, so a wave still
-- travels the way the ring is actually laid out.
function Fn.livingArms(creature)
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
-- AN ORDER IS ALSO A DEADLINE, which is what K.SLAM_ORDER_GRACE below is for.
-- `slamAt` has exactly one consumer - the idle branch of `Fn.updateTentacle` -
-- so an arm that is mid-windup or mid-recovery when the wave reaches its
-- socket cannot act on the order at the moment it is given. It used to hold
-- it instead and fire it the next time it fell idle: out of formation,
-- seconds after the beat, ignoring its own cooldown - and the next command
-- would queue behind that one, so a ring knocked off the beat once stayed
-- off it for the rest of the fight.
function Fn.commandArm(part, at: number, windup: number, lift: number)
	part.slamAt = at
	part.slamOrderWindup = windup
	part.slamOrderLift = lift
end

-- How long after its beat a commanded slam is still worth performing. Past
-- this the order is dropped WITHOUT firing: a wave beat that has gone by is
-- dropped honestly, because a late lone slam out of formation reads as the
-- arena hitting you at random, and that is worse than a gap in the wave.
K.SLAM_ORDER_GRACE = 0.75

-- Jaw Snap: rears back, then lunges and bites everything in front.
K.ATTACK_HANDLERS.snap = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.8 * u, 0, math.rad(24) * u))
	end,
	strike = function(creature, def, p, _now, dt, u, _root, sub)
		creature.pos = Fn.resolveHorizontal(creature, Fn.bossFacing(creature) * (p.lunge / p.duration) * dt)
		-- CLAMP FIRST. The lunge is 13-14 studs and the clamp only ran in
		-- `finish`, so a bite taken at the arena's rim dealt its cone damage
		-- and drew its `bossSnap` ring from a position outside the arena that
		-- the boss was yanked back from immediately afterwards.
		Fn.clampToArena(creature, def)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.8 * (1 - u), 0, math.rad(-14)))
		if not creature.attack.fired and u >= K.SNAP_IMPACT then
			creature.attack.fired = true
			local lo, hi = Fn.bossRoll(creature, def, p.damage)
			Fn.damagePlayersInCone(creature.pos, Fn.bossFacing(creature), p.radius, p.cone, false, lo, hi, creature)
			fireEvent("bossSnap", Fn.bossMouth(creature), { radius = p.radius })
		end
	end,
	finish = function(creature, def)
		Fn.clampToArena(creature, def)
	end,
}

-- Tail Lash: winds up, then whips the whole body round - hits everyone
-- within `radius` of its pivot, all the way round. It USED to spare the
-- front cone ("everything not in front"), but the boss turns to face its
-- target through the windup, so a lone player was always in front and it
-- never landed (playtest, 2026-08-22). The dodge is distance: back off
-- past the ring the tell draws.
K.ATTACK_HANDLERS.tail = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub, math.rad(-28) * u, 0))
	end,
	fire = function(creature, def, p)
		local lo, hi = Fn.bossRoll(creature, def, p.damage)
		damagePlayersInRadius(creature.pos, p.radius, lo, hi, creature, 0.7, K.BOSS_HEIGHT_TOLERANCE)
		fireEvent("sweep", creature.pos, { radius = p.radius, facing = Fn.bossFacing(creature) })
	end,
	strike = function(creature, _def, _p, _now, _dt, u, _root, sub)
		creature.model:PivotTo(poseCFrame(creature, sub, math.rad(-28) + math.rad(70) * math.sin(u * math.pi * 0.5), 0))
	end,
}

-- Brine Volley: a fan of globs that splash down around the player.
K.ATTACK_HANDLERS.volley = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.4 * u, 0, math.rad(30) * u))
	end,
	fire = function(creature, def, p, now, root)
		if not root then
			return
		end
		for i = 1, p.count do
			Fn.throwGlob(
				creature,
				def,
				p,
				Fn.scatterAround(root, p.spread),
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
K.ATTACK_HANDLERS.slam = {
	windup = function(creature, _def, _p, u, sub)
		local e = smoothstep(u)
		creature.model:PivotTo(poseCFrame(creature, sub + 3.0 * e, 0, math.rad(38) * e))
	end,
	fire = function(creature, def, p)
		local lo, hi = Fn.bossRoll(creature, def, p.damage)
		damagePlayersInRadius(creature.pos, p.radius, lo, hi, creature, 0.5, K.BOSS_HEIGHT_TOLERANCE)
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
K.ATTACK_HANDLERS.pull = {
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
K.ATTACK_HANDLERS.brood = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.3 * u, 0, math.rad(-16) * u))
	end,
	fire = function(creature, _def, p, _now, root)
		local from = Fn.bossMouth(creature)
		for i = 1, p.count do
			local rowId = p.rows[((i - 1) % #p.rows) + 1]
			local row = Creatures.items[rowId]
			if row then
				local target = if root then root.Position else from + Fn.bossFacing(creature) * 12
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
K.ATTACK_HANDLERS.dive = {
	windup = function(creature, def, _p, u, sub)
		local e = smoothstep(u)
		creature.model:PivotTo(poseCFrame(creature, sub + (-def.riseDepth - sub) * e, 0, math.rad(-30) * e))
	end,
	fire = function(creature)
		Fn.setBuried(creature, true)
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
		Fn.setBuried(creature, false)
		local lo, hi = Fn.bossRoll(creature, def, p.damage)
		damagePlayersInRadius(creature.pos, p.radius, lo, hi, creature, 0.5, K.BOSS_HEIGHT_TOLERANCE)
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
K.ATTACK_HANDLERS.spines = {
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
			Fn.throwGlob(
				creature,
				def,
				p,
				Fn.scatterAround(root, p.spread),
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

K.BOSS_POOL_TICK = 0.7

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
function Fn.queueStrike(creature, def, p, at: Vector3, tellAt: number, hitAt: number, opts)
	opts = opts or {}
	creature.strikes = creature.strikes or {}
	local lo, hi = nil, nil
	local range = opts.damage or p.damage
	if range then
		lo, hi = Fn.bossRoll(creature, def, range)
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
function Fn.damagePlayersInAnnulus(at: Vector3, inner: number, outer: number, minDmg, maxDmg, source)
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid and humanoid.Health > 0 then
			local d = (Vector3.new(root.Position.X, 0, root.Position.Z) - Vector3.new(at.X, 0, at.Z)).Magnitude
			if d >= inner and d <= outer and math.abs(root.Position.Y - at.Y) <= K.BOSS_HEIGHT_TOLERANCE then
				PlayerService.damage(player, math.random(minDmg, maxDmg), source, { bypassIframe = true })
			end
		end
	end
end

-- Every living player's root within `range` of `at`.
function Fn.livingRootsNear(at: Vector3, range: number): { { player: Player, root: BasePart } }
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
function Fn.bodyContact(creature, body, reach: number, lo: number, hi: number, hitSet, skin: string?)
	for _, entry in Fn.livingRootsNear(creature.pos, reach + RimefangPath.BODY_LENGTH) do
		if not hitSet[entry.player] then
			local at = entry.root.Position
			for _, node in body do
				local to = at - node.pos
				if Vector3.new(to.X, 0, to.Z).Magnitude <= reach and math.abs(to.Y) <= K.BOSS_HEIGHT_TOLERANCE then
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
K.ATTACK_HANDLERS.charge = {
	windup = function(creature, _def, _p, u, sub)
		local e = smoothstep(u)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.7 * e, 0, math.rad(20) * e))
	end,
	fire = function(creature, _def, p, _now, root)
		local a = creature.attack
		a.dir = if root then flatUnit(root.Position - creature.pos) else Fn.bossFacing(creature)
		a.hitSet = {}
		a.dist = 0
		a.nextTrail = if p.trail then p.trail.every * 0.5 else math.huge
		creature.yaw0 = yawToward(a.dir)
		fireEvent("splash", creature.pos, { radius = 4 })
	end,
	strike = function(creature, def, p, now, dt, u, _root, sub)
		local a = creature.attack
		local step = (p.length / p.duration) * dt
		creature.pos = Fn.resolveHorizontal(creature, a.dir * step)
		-- CLAMP BEFORE ANYTHING READS THE POSITION. This used to run only in
		-- `finish`, so every frame of contact damage - and every `strikeHit`
		-- ring the client drew for it - was resolved at a position the arena
		-- would refuse a moment later, and the last of them landed where the
		-- boss demonstrably no longer was. A charge that runs into the rim
		-- should stop at the rim, and be the rim's length of charge.
		Fn.clampToArena(creature, def)
		a.dist += step
		local hop = if p.leap then math.sin(u * math.pi) * p.leap else 0
		creature.model:PivotTo(poseCFrame(creature, sub + hop, 0, math.rad(-8)))
		-- Contact damage, once per player per charge - not while airborne.
		--
		-- A boss with a BODY tests its whole body (see `Fn.bodyContact`): for
		-- Rimefang the `hop` test is the wrong question entirely, because the
		-- head being 26 studs up its leap says nothing about the 40 studs of
		-- whale behind it that are still ploughing the floe. Each node's own
		-- height stands in for `hop`, node by node. Every other charging boss
		-- has no body and takes the branch it always took, to the stud.
		local body = rimefangBody(creature)
		if body then
			local lo, hi = Fn.bossRoll(creature, def, p.damage)
			Fn.bodyContact(creature, body, p.width, lo, hi, a.hitSet, p.skin)
		elseif hop < 1.5 then
			local lo, hi = Fn.bossRoll(creature, def, p.damage)
			for _, entry in Fn.livingRootsNear(creature.pos, p.width) do
				if not a.hitSet[entry.player] then
					a.hitSet[entry.player] = true
					if math.abs(entry.root.Position.Y - creature.pos.Y) <= K.BOSS_HEIGHT_TOLERANCE then
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
		Fn.clampToArena(creature, def)
		if p.slamRadius then
			local lo, hi = Fn.bossRoll(creature, def, p.damage)
			local body = rimefangBody(creature)
			if body then
				-- THE WHOLE ANIMAL LANDS, not its nose. A 56-stud whale coming
				-- down flat cracks the floe along its length; a single ring at
				-- the head left the crash's back half harmless.
				Fn.bodyContact(creature, body, p.slamRadius, lo, hi, {}, p.skin)
			else
				damagePlayersInRadius(creature.pos, p.slamRadius, lo, hi, creature, 0.5, K.BOSS_HEIGHT_TOLERANCE)
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
K.ATTACK_HANDLERS.beam = {
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
			local facing = Fn.bossFacing(creature)
			local origin = creature.model:GetPivot().Position
			local lo, hi = Fn.bossRoll(creature, def, p.damage)
			local half = math.rad(p.cone)
			for _, entry in Fn.livingRootsNear(creature.pos, p.range) do
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
K.ATTACK_HANDLERS.poolvolley = {
	windup = K.ATTACK_HANDLERS.volley.windup,
	fire = function(creature, def, p, now, root)
		if not root then
			return
		end
		for i = 1, p.count do
			Fn.throwGlob(
				creature,
				def,
				p,
				Fn.scatterAround(root, p.spread),
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
	strike = K.ATTACK_HANDLERS.volley.strike,
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
K.ATTACK_HANDLERS.barrage = {
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
				Fn.queueStrike(creature, def, p, center, hitAt - arm, hitAt, {
					shape = "annulus",
					inner = math.max(0, r - width * 0.5),
					outer = r + width * 0.5,
				})
			end
		elseif p.pattern == "line" then
			local dir0 = if root then flatUnit(root.Position - creature.pos) else Fn.bossFacing(creature)
			for _, fanDeg in (p.fan or { 0 }) do
				local dir = rotateFlat(dir0, math.rad(fanDeg))
				for i = 1, p.count do
					local at = groundedPos(creature.pos + dir * ((p.startAt or 8) + (i - 1) * p.spacing), 0)
					local hitAt = now + arm + (i - 1) * (p.interval or 0.16)
					Fn.queueStrike(creature, def, p, at, hitAt - arm, hitAt, {})
				end
			end
		elseif p.pattern == "wall" then
			local dir = if root then flatUnit(root.Position - creature.pos) else Fn.bossFacing(creature)
			local right = rotateFlat(dir, math.pi * 0.5)
			local across = math.max(2, math.floor(p.width / 6) + 1)
			for rank = 0, (p.ranks or 4) - 1 do
				local d = (p.startAt or 10) + rank * (p.rankSpacing or 7)
				local hitAt = now + arm + rank * (p.interval or 0.4)
				for k = 0, across - 1 do
					local offset = (k / (across - 1) - 0.5) * p.width
					local at = groundedPos(creature.pos + dir * d + right * offset, 0)
					Fn.queueStrike(creature, def, p, at, hitAt - arm, hitAt, {})
				end
			end
		elseif p.pattern == "everyone" then
			local center = creature.anchor or creature.pos
			-- `tellHold`: EXTRA seconds between the mark being drawn and the
			-- blow landing, for a move that draws its tell somewhere it cannot
			-- yet be seen. Noctyss's `dousehunt` is the one row that carries it
			-- and the reason it exists: its mark is stamped where you were
			-- standing when the lanterns died (which is the whole move) and
			-- then buried under 1.6s of opaque blackout, so a 44-60 hit landed
			-- one arm-window later with its telegraph drawn and invisible. The
			-- hold pushes the LANDING out to where the blackout is lifting, so
			-- the last `arm` seconds of the mark are the first anyone can see
			-- it - the scare keeps every frame of its true black and stops
			-- being a coin flip. Absent on every other row, and absent means 0.
			local hold = p.tellHold or 0
			for _, entry in Fn.livingRootsNear(center, def.aggro * 1.5) do
				local hitAt = now + hold + arm
				Fn.queueStrike(creature, def, p, groundedPos(entry.root.Position, 0), now, hitAt, {
					snare = p.snare,
					pool = p.pool,
				})
				for _ = 1, p.extra or 0 do
					Fn.queueStrike(creature, def, p, Fn.scatterAround(entry.root, p.spread or 10), now, hitAt + 0.3, {})
				end
			end
		else -- scatter
			if root then
				for i = 1, p.count do
					local hitAt = now + arm + (i - 1) * ((p.duration - 0.2) / math.max(p.count, 1))
					Fn.queueStrike(creature, def, p, Fn.scatterAround(root, p.spread), hitAt - arm, hitAt, {
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
K.ATTACK_HANDLERS.armwave = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.5 * u, 0, math.rad(-10) * u))
	end,
	fire = function(creature, _def, p, now)
		local arms = Fn.livingArms(creature)
		if #arms == 0 then
			return
		end
		local dir = if math.random() < 0.5 then 1 else -1
		local from = math.random(1, #arms)
		local span = math.min(p.sweep or #arms, #arms)
		for k = 0, span - 1 do
			local index = ((from - 1 + dir * k) % #arms) + 1
			Fn.commandArm(arms[index], now + k * (p.interval or 0.26), p.windupEach or 0.8, p.lift or 13)
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
K.ATTACK_HANDLERS.armgap = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.7 * u, 0, math.rad(-16) * u))
	end,
	fire = function(creature, _def, p, now)
		local arms = Fn.livingArms(creature)
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
				Fn.commandArm(arm, now, p.windupEach or 2.0, p.lift or 16)
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
				Fn.commandArm(arm, now, p.windupEach or 2.0, p.lift or 16)
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
K.ATTACK_HANDLERS.snaretrap = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub - 0.4 * u, 0, math.rad(-10) * u))
	end,
	fire = function(creature, def, p, now)
		for _, entry in Fn.livingRootsNear(creature.pos, def.aggro * 1.2) do
			Fn.queueStrike(creature, def, p, groundedPos(entry.root.Position, 0), now, now + p.arm, {
				snare = p.snare,
			})
		end
	end,
}

-- Decoys: plants glowing lures / drifting mines that detonate when anyone
-- comes close (or fizzle after p.lifetime). p: count, spread, trigger,
-- blast, damage, lifetime; optional drift (studs/s toward the nearest
-- player - the powder keg).
K.ATTACK_HANDLERS.decoys = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.4 * u, 0, math.rad(18) * u))
	end,
	fire = function(creature, def, p, now, root)
		creature.lures = creature.lures or {}
		local center = if root then root.Position else creature.pos
		for _ = 1, p.count do
			local angle = math.random() * math.pi * 2
			local r = p.spread * (0.35 + 0.65 * math.random())
			-- Float over whatever is actually below: a fixed waterline height
			-- half-sank Noctyss's lures into the Choirfloor's raised stone
			-- (shelf top 1.5-1.9). The waterline stays the FLOOR of the probe,
			-- so Wrack's kegs drifting his bay are placed exactly as before.
			local x, z = center.X + math.cos(angle) * r, center.Z + math.sin(angle) * r
			local floorHit = Workspace:Raycast(Vector3.new(x, 8, z), Vector3.new(0, -20, 0), groundParams())
			local y = math.max(World.WATER_Y + 1.2, if floorHit then floorHit.Position.Y + 1.2 else -math.huge)
			local at = Vector3.new(x, y, z)
			local lo, hi = Fn.bossRoll(creature, def, p.damage)
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
K.ATTACK_HANDLERS.phantom = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub - 1.2 * u, 0, math.rad(-12) * u))
	end,
	fire = function(creature, _def, p, _now, root)
		local a = creature.attack
		Fn.setBuried(creature, true)
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
				Fn.setBuried(creature, false)
				if root then
					creature.yaw0 = yawToward(root.Position - creature.pos)
				end
				fireEvent("phantomIn", creature.pos, { radius = p.radius, skin = p.skin })
			end
			return
		end
		creature.model:PivotTo(poseCFrame(creature, sub + 0.5, 0, math.rad(-12)))
		if not a.fired and u >= K.PHANTOM_IMPACT then
			a.fired = true
			local lo, hi = Fn.bossRoll(creature, def, p.damage)
			Fn.damagePlayersInCone(
				creature.pos,
				Fn.bossFacing(creature),
				p.radius,
				math.rad(p.cone),
				false,
				lo,
				hi,
				creature
			)
			fireEvent("bossSnap", Fn.bossMouth(creature), { radius = p.radius })
		end
	end,
	finish = function(creature, def)
		Fn.clampToArena(creature, def)
	end,
}

-- Undertow: the maelstrom's own current - a long, arena-wide drag toward the
-- maw while wreckage rains on whoever it's pulling. p: radius, strength,
-- duration, globEvery, damage (per glob), radius is the pull's reach and the
-- globs land radius p.globRadius.
K.ATTACK_HANDLERS.undertow = {
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
			local targets = Fn.livingRootsNear(center, p.radius)
			if #targets > 0 then
				local entry = targets[math.random(#targets)]
				local at = Fn.scatterAround(entry.root, 7)
				-- THE RAIN HAS TO REACH THE ROCKS. This is a six-second move
				-- whose entire second half is wreckage coming down on whoever
				-- the current is dragging, and the people being dragged are
				-- standing on the arena's caps 4-6 studs over the water. The
				-- glob's landing is grounded, so a scatter that clears the cap
				-- resolves at the waterline and the default 6-stud gate voided
				-- the hit - the pull landed, the wreckage drew, and nothing
				-- happened. Same tolerance the rest of the boss kit's AoE uses.
				Fn.throwGlob(
					creature,
					def,
					{ damage = p.damage, radius = p.globRadius or 7 },
					at,
					0.9,
					now,
					"spineHit",
					"spit",
					{ tolerance = K.BOSS_HEIGHT_TOLERANCE }
				)
			end
		end
	end,
}

-- Anchortoss: hurls the anchor at where the target stands - the ring is the
-- warning - and whoever it lands on is CHAINED to the spot (the client
-- leashes its own character to the anchor). p: flight, radius, damage,
-- leash, chainDuration.
K.ATTACK_HANDLERS.anchortoss = {
	windup = function(creature, _def, _p, u, sub)
		local e = smoothstep(u)
		creature.model:PivotTo(poseCFrame(creature, sub + 1.3 * e, 0, math.rad(32) * e))
	end,
	fire = function(creature, def, p, now, root)
		if not root then
			return
		end
		local at = groundedPos(root.Position, 0)
		fireEvent("spine", Fn.bossMouth(creature) + Vector3.new(0, 5, 0), {
			to = at,
			flight = p.flight,
			arc = 14,
			boss = true,
		})
		Fn.queueStrike(creature, def, p, at, now, now + p.flight, {
			chain = { leash = p.leash, duration = p.chainDuration, radius = p.radius + 3 },
		})
	end,
	strike = function(creature, _def, _p, _now, _dt, u, _root, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 1.3 * (1 - u), 0, math.rad(32 - 46 * u)))
	end,
}

-- Which attacks the current health fraction allows: the LAST phase whose
-- `below` the fraction is at or under.
function Fn.bossPhaseAttacks(def, hpFraction: number): { string }
	local attacks = def.phases[1].attacks
	for _, phase in def.phases do
		if hpFraction <= phase.below then
			attacks = phase.attacks
		end
	end
	return attacks
end

-- ...OR THE PHASE A MACHINE PUT IT IN, which is a different question and the
-- Kraken is the first boss to ask it.
--
-- Every other fight in the project escalates on a health threshold, and that is
-- the right rule for a boss whose phases are chapters of one continuous fight.
-- The Kraken's are not: its phases advance on ARM-BREAK CYCLES (see
-- `machine` on its row and `Fn.updateKrakenFight` below), because the head's
-- health bar is only touchable inside a window the party has to earn, so
-- "health fraction" and "how far through the fight are we" have almost nothing
-- to do with each other there - a party four windows deep may have taken less
-- than a tenth of the bar off.
--
-- A SECOND READER OF THE SAME `phases` TABLE, not a second table. The pools
-- stay where every other boss's pools are; only the index is chosen elsewhere.
-- `creature.krakenPhase` is nil on every other creature in the game, so this
-- returns the health answer, unchanged, for all of them.
function Fn.bossPhasePool(creature, def): { string }
	local index = creature.krakenPhase
	local phase = index and def.phases[index]
	if phase then
		return phase.attacks
	end
	return Fn.bossPhaseAttacks(def, Fn.bossPhaseFraction(creature))
end

-- WHICH FRACTION THE PHASE TABLE IS READ AT, and for every boss but one it is
-- exactly the health fraction it has always been.
--
-- Admiral Wrack's fight advances on EVENTS, not on damage: act one ends when
-- the fourth permanent cannon falls, act two when the hull reaches zero. A
-- health fraction cannot express the first of those at all - the hull is IMMUNE
-- for the whole of act one (`vulnerableWhen = "partsDown"`), so its bar never
-- moves and a health-fraction table would leave him in phase one until the act
-- was already over.
--
-- So the Wrack tick writes `creature.actFraction` (see Fn.wrackActStep), a
-- single dial that runs monotonically down across BOTH of his acts - 1.00 to
-- 0.60 on cannons destroyed, then 0.60 to 0.00 on hull damage - and his row's
-- five bands are cut against it.
--
-- NOTHING ELSE IN THE GAME SETS THE FIELD, so this returns the health answer,
-- byte-identical, for every other boss. Preferred here rather than at the call
-- sites because there are three of them and a fourth would forget.
function Fn.bossPhaseFraction(creature): number
	return creature.actFraction or creature.health / creature.maxHealth
end

function Fn.pickBossAttack(creature, def, now: number): string
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
	-- The pool: the health phase for every boss, or the one a machine put this
	-- creature in. See Fn.bossPhasePool - one call rather than two, because the
	-- empty-pool fallback below has to draw its `[1]` from the SAME list it
	-- filtered or a fight with everything on cooldown would silently jump
	-- phases.
	local phasePool = Fn.bossPhasePool(creature, def)
	for _, name in phasePool do
		local readyAt = creature.cooldowns and creature.cooldowns[name] or 0
		local p = def.attacks[name]
		local spent = p and p.once == "stance" and used and used[name]
		-- ...and one last gate, for a move that can only land somewhere the
		-- boss does not aim. `Fn.rfPickAllows` returns true on its first line
		-- for every row that does not opt in (which is every row but one), so
		-- this is inert for the whole project except Rimefang's fluke slam -
		-- see the note on that function.
		-- ...and the RANGE GATE, which is the same shape of thing for the one
		-- boss that cannot close a distance. `Fn.gnPickAllows` returns true on
		-- its first line for every row without `rig = "gnashroot"`, which is
		-- every row in the project but one.
		if
			name ~= creature.lastAttack
			and now >= readyAt
			and not spent
			and Fn.rfPickAllows(creature, p, name)
			and Fn.gnPickAllows(creature, def, p)
		then
			table.insert(pool, name)
		end
	end
	if #pool == 0 then
		-- Always something: the phase list's first attack (each boss leads
		-- its lists with its short-cooldown bread-and-butter bite).
		--
		-- EXCEPT THAT THE RANGE GATE HAS TO SURVIVE THE FALLBACK. Old
		-- Gnashroot leads every phase list with `gnash`, which is exactly the
		-- move the gate exists to withhold - so a frame where everything is on
		-- cooldown would hand back the one attack that cannot reach, and a
		-- rooted boss whose bread-and-butter is a bite it can never land looks
		-- broken in the most visible way available. Walk the list for the
		-- first pick the gate allows; if it allows none, the old answer stands
		-- rather than the boss doing nothing at all.
		for _, name in phasePool do
			if Fn.gnPickAllows(creature, def, def.attacks[name]) then
				return name
			end
		end
		return phasePool[1]
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
function Fn.signalArenaStorm(def, p, active: boolean)
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

function Fn.beginBossAttack(creature, def, name: string, now: number)
	local p = def.attacks[name]
	-- FASTER TELLS AS A FIGHT ESCALATES, and it has to be applied HERE - once,
	-- at the one place every attack starts - or it is not one change, it is
	-- fourteen rows that have to be re-tuned by hand and kept in step.
	--
	-- `creature.tellMult` is written by the Kraken's fight tick off its row's
	-- `machine.tellMult` and is nil on every other creature in the game, so
	-- this line is `windup * 1` for the whole project outside that fight. It
	-- scales the WINDUP, which is the same number the generic telegraph's
	-- countdown is drawn from below and the same number `Fn.updateBossAttack`
	-- measures its 0..1 windup progress against - so the tell, the pose and the
	-- blow all move together and no handler learns about it. A multiplier that
	-- only shortened the damage clock would be the single worst bug this fight
	-- could ship: a telegraph that lies about when it lands.
	local windup = p.windup * (creature.tellMult or 1)
	creature.attack = {
		name = name,
		p = p,
		phase = "windup",
		phaseStart = now,
		phaseUntil = now + windup,
		fired = false,
		-- The scaled figure, for a handler that needs to know how long its own
		-- tell really has (`a.windup`, never `p.windup`, inside a handler that
		-- draws one).
		windup = windup,
	}
	creature.lastAttack = name
	-- The lunge's plant is the only punish window a HANDLER owns, and a
	-- handler that is interrupted (a stagger, the collapse) never reaches
	-- its own `finish`. Cleared at every attack's start as well as at the
	-- lunge's end, so a stale `true` can never carry into another move.
	creature.lungeOpen = false
	-- ...and the two the second pass added, for the identical reason: a
	-- handler interrupted by a stagger or the collapse never reaches its own
	-- `finish`, so a stale `true` would carry the full-damage window into the
	-- next move.
	creature.coilOpen = false
	creature.biteOpen = false
	-- Spent for this stance the moment it BEGINS, not when it finishes: a
	-- set-piece interrupted by the boss's own death or a stagger has still
	-- been shown, and offering it again in the same stance would read as the
	-- fight repeating itself. See `once` in Fn.pickBossAttack.
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
	--
	-- COMBOS. Late in a fight the serpent sometimes throws two things at once;
	-- resolved here, at the one place every attack starts, so no handler has
	-- to know about it. Row-gated (`def.combo`) - no other boss changes.
	Fn.rollCombo(creature, def, name, now)
	if p.tell ~= false then
		-- WHERE THE TELL IS DRAWN. The pivot is right for a boss that attacks
		-- around itself and wrong for one whose move works the floor from a
		-- centre that is not its head: Rimefang's carousel pulls on
		-- `creature.anchor` and drops its bergs there (K.ATTACK_HANDLERS.undertow
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
			-- strike are listed in K.HANDLER_IMPACT, and for them a countdown
			-- that ended at the windup was inviting the player back in - by up
			-- to 1.52 seconds. See the note on that table.
			duration = windup + (p.duration or 0) * (K.HANDLER_IMPACT[p.handler] or 0),
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
			facing = Fn.bossFacing(creature),
			-- WHICH MOVE THIS TELL BELONGS TO - Rimefang only, and nil (so
			-- absent from the payload, so nothing else on the wire changes) for
			-- every other creature in the project. Its client dispatches its
			-- bespoke draws on `move` FIRST and only falls back to matching
			-- radii, and that fallback's tolerance is 0.4 studs because
			-- skyfall's 18 sits one stud from the bite's 17. Every Rimefang
			-- telegraph therefore has to carry this, including the stock ones -
			-- the bite, the wash and the whiteout come through here.
			move = if creature.row.boss == K.RIMEFANG_BOSS then name else nil,
			skin = p.skin,
		})
	end
	-- The sky closes with the TELL, not with the blow: the whole windup
	-- budget is spent watching it come in.
	Fn.signalArenaStorm(def, p, true)
end

function Fn.endBossAttack(creature, def, now: number)
	local a = creature.attack
	local rage = if creature.enraged then def.enrageCooldownMult else 1
	creature.cooldowns = creature.cooldowns or {}
	-- A FIGHT MAY TIGHTEN ITS OWN METRONOME. `creature.cooldownStep` is nil on
	-- every creature in the game except the Ashfall Heart, which sets it to
	-- `K.PY_PILLAR_STEP ^ (pillars broken)` - so the room speeds up as its
	-- cover comes down, by the party's own hand, and the eighth pillar is
	-- fought at roughly twice the opening cadence.
	--
	-- HERE rather than in the heart's own tick, because this is the ONE line
	-- that writes a cooldown; a second place that adjusted them afterwards
	-- would be a number computed twice and reconciled never. Inert at nil.
	creature.cooldowns[a.name] = now + a.p.cooldown * rage * (creature.cooldownStep or 1)
	Fn.signalArenaStorm(def, a.p, false)
	-- A move with `expose = seconds` leaves the creature wide open after its
	-- recover: hits land at the charger's exposed multiplier for the window
	-- (hitModifiers), and the client draws the dazed tell off the attribute.
	if a.p.expose then
		creature.exposedUntil = now + a.p.expose
		-- The attribute is the tell: the client already draws the charger's
		-- dazed sparks off Exposed, so every kitted expose window inherits
		-- that language for free (no boss-roar "exposed" event - too grand).
		creature.model:SetAttribute(ATTR.EXPOSED, true)
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

function Fn.updateBossAttack(
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
	local handler = K.ATTACK_HANDLERS[p.handler or a.name]
	if not handler then
		Fn.endBossAttack(creature, def, now)
		return
	end

	if a.phase == "windup" then
		-- Tracks the player through the tell, so dodging means MOVING, not
		-- standing off to one side.
		if root then
			creature.yaw0 =
				approachAngle(creature.yaw0, yawToward(root.Position - creature.pos), def.turnRate * 1.5 * dt)
		end
		-- `a.windup`, not `p.windup`: an escalating fight can shorten its own
		-- tells (see Fn.beginBossAttack), and the windup POSE has to finish on
		-- the same clock the phase does or the arm would still be rearing when
		-- the blow lands. Identical for every attack that is not scaled, since
		-- `a.windup` is written as `p.windup * 1` in that case.
		local u = math.clamp((now - a.phaseStart) / math.max(a.windup or p.windup, 1e-3), 0, 1)
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
			Fn.endBossAttack(creature, def, now)
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
K.ATTACK_HANDLERS.lunge = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub, 0, math.rad(-12) * u))
	end,
	fire = function(creature, _def, p, _now, root)
		local a = creature.attack
		if root then
			local to = Vector3.new(root.Position.X - creature.pos.X, 0, root.Position.Z - creature.pos.Z)
			a.leap = math.min(to.Magnitude, p.reach or 14)
			a.dir = if to.Magnitude > 0.01 then to.Unit else Fn.bossFacing(creature)
		else
			a.leap = p.reach or 14
			a.dir = Fn.bossFacing(creature)
		end
	end,
	strike = function(creature, def, p, _now, dt, u, _root, sub)
		local a = creature.attack
		creature.pos = Fn.resolveHorizontal(creature, a.dir * (a.leap / math.max(p.duration, 1e-3)) * dt)
		local hop = (p.hop or 3) * 4 * u * (1 - u)
		creature.model:PivotTo(poseCFrame(creature, sub + hop, 0, math.rad(18) * (1 - u)))
		if not a.fired and u >= K.LUNGE_IMPACT then
			a.fired = true
			local lo, hi = Fn.bossRoll(creature, def, p.damage)
			Fn.damagePlayersInCone(creature.pos, a.dir, p.radius or 6, p.cone or math.rad(60), false, lo, hi, creature)
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
K.ATTACK_HANDLERS.conebreath = {
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
			local lo, hi = Fn.bossRoll(creature, def, p.damage)
			local facing = Fn.bossFacing(creature)
			Fn.damagePlayersInCone(creature.pos, facing, p.reach or 12, p.cone or math.rad(35), false, lo, hi, creature)
			fireEvent("beam", creature.pos + Vector3.new(0, 1.5, 0), {
				to = creature.pos + facing * (p.reach or 12) + Vector3.new(0, 1, 0),
				skin = p.skin,
			})
		end
		if u >= 0.95 and not a.fired and p.pool then
			a.fired = true
			local facing = Fn.bossFacing(creature)
			spawnPool(creature, creature.pos + facing * (p.reach or 12) * 0.6, p.pool, now)
		end
	end,
}

-- Ring pulse: an expanding shockwave band swept outward over `duration`
-- (step across or outrun it) - or, with `invert`, one detonation of the
-- annulus [safeRadius, radius] at the end of the strike: the SAFE spot is
-- up close, and the tell says so. p: radius (outer), ringWidth?, safeRadius
-- (invert), invert?.
K.ATTACK_HANDLERS.ringpulse = {
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
			if not a.fired and u >= K.RINGPULSE_IMPACT then
				a.fired = true
				local lo, hi = Fn.bossRoll(creature, def, p.damage)
				Fn.damagePlayersInAnnulus(creature.pos, p.safeRadius or 6, p.radius, lo, hi, creature)
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
		local lo, hi = Fn.bossRoll(creature, def, p.damage)
		for _, entry in Fn.livingRootsNear(creature.pos, front) do
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

-- Mortar: N telegraphed ground marks (Fn.queueStrike - the marks land on their
-- own clock, whatever the creature does next). p: count, spread, delay
-- (tell-to-hit), stagger, aim ("player" scatters around the player,
-- "self" around the creature), plus Fn.queueStrike riders: shape/inner/outer,
-- snare, chain, pool, hitEvent.
K.ATTACK_HANDLERS.mortar = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.6 * u, 0, math.rad(-16) * u))
	end,
	fire = function(creature, def, p, now, root)
		local count = p.count or 3
		for i = 1, count do
			local at
			if root and (p.aim or "player") == "player" then
				at = Fn.scatterAround(root, p.spread or 7)
			else
				local angle = math.random() * math.pi * 2
				local r = math.sqrt(math.random()) * (p.spread or 10)
				at = groundedPos(creature.pos + Vector3.new(math.cos(angle) * r, 0, math.sin(angle) * r), 0)
			end
			local tellAt = now + (i - 1) * (p.stagger or 0.25)
			Fn.queueStrike(creature, def, p, at, tellAt, tellAt + (p.delay or 1.1), {
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
K.ATTACK_HANDLERS.gustpush = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.7 * u, 0, math.rad(-10) * u))
	end,
	fire = function(creature, def, p, _now)
		local facing = Fn.bossFacing(creature)
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
			local lo, hi = Fn.bossRoll(creature, def, p.damage)
			if p.cone then
				Fn.damagePlayersInCone(creature.pos, facing, p.radius, p.cone, false, lo, hi, creature)
			else
				damagePlayersInRadius(creature.pos, p.radius, lo, hi, creature, 0.7)
			end
		end
	end,
}

-- ---------------------------------------------------------------- rimefang
--
-- The Floe-Breaker's bespoke moves. Everything else in its book runs on
-- handlers that already exist (snap / slam / barrage).
--
-- THE WASH'S COVER MECHANIC IS GONE (kit v2), and the occlusion raycast with
-- it. `Fn.washSheltered` used to ask the arena furniture whether a player was
-- behind something, and the rebuilt r=120 sheet has no standing geometry at
-- all - so the test could only ever return false, at the cost of one raycast
-- per player per wash, and the `sheltered` roster it produced was a wire
-- field that was always empty. Deleted rather than left returning false: a
-- shelter test that cannot shelter anybody is exactly the kind of number the
-- next reader would tune. The client keeps its own `sheltered` exemption as a
-- harmless no-op on a roster nobody sends. If furniture ever comes back, the
-- move that needs it is the wash and this is where the test went.

-- Everyone the crest has reached since the last frame. Backwards, because it
-- removes as it goes; `PlayerService.damage` is already safe for a player who
-- has died or left between the schedule and the arrival (no humanoid, no
-- hit), so there is no second liveness test to keep in step with it.
function Fn.washLand(creature, now: number)
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
K.ATTACK_HANDLERS.wash = {
	-- NO POSE HOOKS. The whale's body is published as attributes and drawn by
	-- the client (Fn.rimefangDrive below), so a pivot here would only move a
	-- model nobody can see. The roll onto its side - the tell, which has to
	-- read from the far side of the arena, because the answer is to move - is
	-- posed from the phase this loop is already in.
	fire = function(creature, def, p, now, root)
		local a = creature.attack
		-- LATCHED ONCE, never per frame. A bearing recomputed each frame
		-- snaps to whoever is nearest, so in a party the wall would jump
		-- across the arena mid-attack and stop being dodgeable.
		a.dir = if root then flatUnit(root.Position - creature.pos) else Fn.bossFacing(creature)
		local lo, hi = Fn.bossRoll(creature, def, p.damage)
		-- THE WALL TRAVELS, SO THE DAMAGE TRAVELS WITH IT. Everything below
		-- used to resolve in this one loop, at the instant the windup ended:
		-- a player at the far rim took the hit before the crest had left the
		-- whale's shoulder. No client can make a travelling wall honest
		-- against a one-frame hit, so the scheduling belongs here.
		--
		-- The whole cone is decided NOW and never revisited: who is in the
		-- wedge and how hard it hits. Only the MOMENT is deferred. That
		-- ordering is the point - re-testing the wedge as the crest arrived
		-- would let a player who stepped aside AFTER the wall committed still
		-- be caught by geometry the wall had already passed, and it would make
		-- the move re-aim itself, which is the exact failure kit v2 exists to
		-- fix everywhere else in this book.
		local reach = math.max(p.radius - (p.sweepFrom or 0), 1e-3)
		a.washHits = {}
		for _, entry in Fn.livingRootsNear(creature.pos, p.radius) do
			local to = flatUnit(entry.root.Position - creature.pos)
			if to:Dot(a.dir) >= math.cos(p.cone) then
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
		-- Rides the kit engine's `gust` vocabulary (displacement is the pull
		-- machinery in reverse, client-side). No `sheltered` roster any more -
		-- see the note at the top of this region; the client's exemption reads
		-- a field nobody sends and does nothing, which is the correct no-op.
		fireEvent("gust", creature.pos, {
			radius = p.radius,
			push = p.push or 70,
			duration = math.max(p.duration, 0.2),
			cone = p.cone,
			facing = a.dir,
			move = "wash",
			skin = p.skin,
		})
		if p.slick then
			spawnPool(creature, groundedPos(creature.pos + a.dir * (p.radius * 0.45), 0), p.slick, now)
		end
		-- Anyone the crest is already on top of is hit on THIS frame, not on
		-- the next one: with `sweep` unset every delay is zero, and a move
		-- that opts out of the travelling wall must land exactly where it
		-- landed before this existed.
		Fn.washLand(creature, now)
	end,
	-- The wall arriving, one player at a time, on the schedule `fire` wrote.
	-- The PivotTo is what the attack loop does for a handler with no strike
	-- hook, kept verbatim so adding this hook changes nothing but the timing.
	strike = function(creature, _def, _p, now, _dt, _u, _root, sub)
		Fn.washLand(creature, now)
		creature.model:PivotTo(poseCFrame(creature, sub, 0, 0))
	end,
	-- Nobody is dropped if the strike ends early (it cannot today - the sweep
	-- is 0.22s inside a 0.9s strike - but a retune must not silently start
	-- eating hits).
	finish = function(creature)
		Fn.washLand(creature, math.huge)
	end,
}

-- THE SPY-HOP. Not an attack: the LOOK. It rises vertically out of the
-- water, half its body clear, and picks someone. Orcas really do this to
-- find prey on a floe, and it earns its slot by being the one beat in the
-- fight where nothing is coming - which is what makes the beats that ARE
-- coming legible. It marks its target, and the mark is who the NEXT move
-- opens on.
K.ATTACK_HANDLERS.spyhop = {
	-- No pose hooks, for the same reason the wash has none: the stand, the
	-- hold and the slow scan are published (Fn.rimefangDrive below), not pivoted.
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
-- (`Fn.rimefangFace` reads it) and reads as the animal committing. And the
-- MOMENT: the countdown runs through the fall rather than finishing while the
-- tail is still up. The row opts out of the stock tell (`tell = false`) so
-- there is exactly one marker and it is this one.
K.RF_FLUKE_IMPACT = 0.3

-- Where the fluke will come down: the last spine sample's ground position.
-- The lobtail is no longer a lift - the tail rears and then HAMMERS, the tip
-- travelling from +11.9 to -14.5 studs through the waterline - but it is a
-- rotation of the peduncle about a fixed heading, so the tip's FOOTPRINT
-- barely moves: the resting tip measures 1.20 studs from the true hammer
-- point, well inside this move's 24-stud radius. Reading the rest pose is
-- therefore both correct and the only thing available at windup start, which
-- is when the marker has to be placed.
function Fn.flukeGround(creature): Vector3
	local body = rimefangBody(creature)
	local at = if body then body[#body].pos else creature.pos
	return groundedPos(Vector3.new(at.X, creature.pos.Y, at.Z), 0)
end

K.ATTACK_HANDLERS.flukeslam = {
	-- No pose hooks: the whale is published as attributes and drawn by the
	-- client, so a PivotTo here would only move a model nobody can see.
	windup = function(creature, _def, p, _u, _sub)
		local a = creature.attack
		if a.aimed then
			return
		end
		a.aimed = true
		a.dir = Fn.bossFacing(creature)
		a.impact = Fn.flukeGround(creature)
		fireEvent("telegraph", a.impact, {
			kind = p.tellKind or "burst",
			duration = p.windup + (p.duration or 0) * K.RF_FLUKE_IMPACT,
			radius = p.radius,
			facing = a.dir,
			-- WHICH MOVE THIS IS, on every Rimefang telegraph and every
			-- Rimefang slam. The client dispatches on `move` FIRST and only
			-- falls back to matching radii - a fallback whose tolerance is now
			-- 0.4 studs, because skyfall's 18 sits one stud from the bite's 17.
			-- Nothing here may rely on that fallback.
			move = "flukeslam",
			skin = p.skin,
		})
	end,
	strike = function(creature, def, p, _now, _dt, u, _root, _sub)
		local a = creature.attack
		if a.fired or u < K.RF_FLUKE_IMPACT then
			return
		end
		a.fired = true
		local at = a.impact or Fn.flukeGround(creature)
		local lo, hi = Fn.bossRoll(creature, def, p.damage)
		damagePlayersInRadius(at, p.radius, lo, hi, creature, 0.5, K.BOSS_HEIGHT_TOLERANCE)
		fireEvent("slam", at, { radius = p.radius, move = "flukeslam", skin = p.skin })
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

K.RIMEFANG_BOSS = "rimefang"
-- Mirrors ATTR.POSE / ATTR.POSE_CENTER, which are declared with the colossus
-- driver further down this file and so are not in scope here. Same two names,
-- because they are the same contract: `Pose` is what makes the client adopt
-- the model, `PoseCenter` is where the body is drawn from.
K.RF_ATTR_POSE = "Pose"
K.RF_ATTR_CENTER = "PoseCenter"

-- The prowl's breath cycle: how long it runs under the sheet, and how long
-- it lies up top before it goes back down.
K.RF_DIVE_HOLD = 3.6
K.RF_SURFACE_HOLD = 4.2
-- Not a full `submerge`: it hunts under the sheet, it does not leave, and
-- the thing you are shooting at has to stay findable between attacks.
K.RF_DIVE_DEPTH = 0.6

-- An attribute is a replicated write, so a pose number is only sent when it
-- has actually moved. (Same reasoning as the choir's ChoirDown, which is
-- published on change for the same reason.)
K.RF_EPSILON = 0.004

local function rfPut(model: Model, cache, attr: string, value: number)
	-- A NaN reaching the cache would latch this channel off for the life of
	-- the creature: every later `math.abs(value - NaN) > eps` is false, so the
	-- attribute is never written again and the client freezes on a stale
	-- value with no error anywhere.
	if value ~= value then
		return
	end
	local last = cache[attr]
	if last == nil or math.abs(value - last) > K.RF_EPSILON then
		cache[attr] = value
		model:SetAttribute(attr, value)
	end
end

-- The pose state, and the one-time handshake with the client.
function Fn.rimefangState(creature)
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
	creature.model:SetAttribute(K.RF_ATTR_CENTER, state.center)
	creature.model:SetAttribute(K.RF_ATTR_POSE, K.RIMEFANG_BOSS)
	return state
end

-- WHERE THE BODY IS DRAWN FROM, so that the head lands on the server's own
-- authority point every frame. Rather than duplicating any pose's constants
-- here, the offset is asked of the path itself: pose the shape about the
-- origin and see where t = 0 came out. The vertical is deliberately NOT
-- cancelled - the spy-hop's stand, the dive's depth, the ice breach's
-- eruption and the sky slam's 70 studs of climb ARE the pose.
--
-- THIS IS WHY THE TWO KIT-V2 CHANNELS SATISFY THEIR CONTRACT FOR FREE. Both
-- burst and skyfall move the head VERTICALLY about the centre, so the
-- horizontal cancellation above is a no-op for them and PoseCenter comes out
-- as exactly what the client is promised: the burst point on the surface for
-- the ice breach, and the ground point under the head for the sky slam. The
-- handlers earn that by keeping creature.pos on the mark - pinned to the lock
-- point at the ice breach's `fire`, eased onto it and parked by 0.58 of the
-- sky slam's strike.
function Fn.rimefangCenter(state, at: Vector3): Vector3
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
-- WHY SAMPLES AND NOT A `parts` RING. Fn.spawnBossParts is the other way to give
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
-- Raising K.RF_MIN_RADIUS to 3.6 would have closed the same gap and is the
-- wrong fix: the fluke's drawn half-width is 6.6 * girth(1) = 1.45, so 3.0 is
-- already twice the hide and 3.6 would be swinging at open water. Sampling
-- finer keeps every radius honest to the body and costs two more `pointAt`
-- calls per test.
K.RF_HIT_SAMPLES = 11
-- The pack's authored half-width at full girth (the row's note on `hitRadius`
-- measures the drawn whale at ~6.6 half-width, 7.2 half-height), and a floor
-- under the peduncle's pinch: `RimefangPath.girth` bottoms out at 0.22, which
-- would leave the fluke a 1.5-stud target you could not reliably swing at.
K.RF_HALF_WIDTH = 6.6
K.RF_MIN_RADIUS = 3.0

-- The spine, sampled, as capture spheres - or nil for anything that is not
-- Rimefang, which is what keeps every other creature on the pivot sphere it
-- has always had. Guarded on `creature.row.boss` exactly as `Fn.rimefangDrive`
-- is, and on the pose state as well: before the first drive frame (and all
-- through `rising`) there is no body yet, and the caller falls back.
--
-- The nodes are allocated once per creature and refilled in place - this is
-- called per swing and per shot, and a fresh table of nine per call would be
-- churn for nothing.
function rimefangBody(creature)
	if creature.row.boss ~= K.RIMEFANG_BOSS then
		return nil
	end
	local state = creature.rimefangPose
	if not state then
		return nil
	end
	local nodes = creature.rimefangHitNodes
	if not nodes then
		nodes = table.create(K.RF_HIT_SAMPLES)
		for i = 1, K.RF_HIT_SAMPLES do
			nodes[i] = { pos = Vector3.zero, radius = 0, t = (i - 1) / (K.RF_HIT_SAMPLES - 1) }
		end
		creature.rimefangHitNodes = nodes
	end
	for _, node in nodes do
		node.pos = RimefangPath.pointAt(state, node.t)
		node.radius = math.max(K.RF_HALF_WIDTH * RimefangPath.girth(node.t), K.RF_MIN_RADIUS)
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
function Fn.rimefangFace(creature, a): number
	return if a.dir then yawToward(a.dir) else creature.yaw0
end

-- EASING, the whole job of this region. `smoothstep` above zeroes the first
-- derivative at both ends; these zero more, or bias the acceleration, so a
-- pose value LEAVES and ARRIVES with weight instead of a linear ramp.

-- Quintic. Zero first AND second derivative at 0 and 1, so a channel eased
-- with it has no kick at either end - the default for surge-and-settle beats.
local function smootherstep(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * t * (t * (t * 6 - 15) + 10)
end

-- Accelerate from rest: slow off the mark, fast into the end. The tail
-- gathering speed into a hammer, a body dropping under its own weight.
local function easeInCubic(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * t
end

-- Decelerate to rest: fast off the mark, ease to a stop. A snap that lands
-- and a jaw that shuts.
local function easeOutCubic(t: number): number
	t = math.clamp(t, 0, 1)
	local f = 1 - t
	return 1 - f * f * f
end

-- THE LEAP CLOCK. `arch` is the parabola parameter (RimefangPath draws height
-- sin(arch*pi) and ground ARCH_SPAN*(arch-0.5)), so walking it LINEARLY in
-- time gives a constant ground speed and only the sine's natural hang at the
-- apex. This warps that walk so the progress is FAST near the water (arch 0
-- and 1) and SLOW over the top: it accelerates off the surface, floats the
-- apex, and accelerates into re-entry. da/du = 1 + k*cos(2pi*u) stays > 0 for
-- k < 1, so it never stalls or reverses, and arch(0)=0, arch(0.5)=0.5,
-- arch(1)=1 land the endpoints and the apex exactly where the parabola wants.
local function hangArc(u: number, k: number): number
	u = math.clamp(u, 0, 1)
	return u + k * math.sin(2 * math.pi * u) / (2 * math.pi)
end

-- ------------------------------------------------- rimefang: the kit v2 moves
--
-- THE VERDICT ON KIT v1 was that the whale never actually hit you: "they don't
-- really hit the user at all; it's mainly just the whale rushing and hitting
-- the user". Every one of those was a move that landed somewhere the player
-- was not, and each for a different reason:
--   * `breach` rode the shared `charge` - a FIXED 46-stud run on a latched
--     bearing, so against a player at the 14-stud standoff it landed 32 studs
--     PAST them, every time.
--   * `flukeslam` lands where the TAIL is, 56 studs behind the nose, and
--     nothing steers the tail anywhere.
--   * `carousel` pulled on `creature.anchor` - the arena's middle - wherever
--     anybody happened to be standing.
-- Only `bite` connected, so the whole fight read as a rush.
--
-- THE RULE THE THREE HANDLERS BELOW ARE BUILT ON: every attack lands on the
-- player's MARKED position. The body does the spectacle; the mark is the
-- contract. Concretely that means each of them (a) predicts, with rfAimPoint,
-- (b) LOCKS that prediction at a stated moment and stops re-aiming, (c) fires
-- its own telegraph AT the locked point with an honest countdown, and (d)
-- damages that same latched point rather than wherever the body ended up. The
-- three differ only in where they come FROM: under the ice, out of the sky,
-- and along the sheet.

-- Where the client's continuous visuals read which move is running. Numeric
-- pose channels go through rfPut; this one is a string, so it is published
-- through its own change-cache in the driver.
K.RF_ATTR_MOVE = "Move"
-- HOW FAR AHEAD A LOCK AIMS. A mark placed on where you STAND is dodged by
-- walking; a mark placed on where you are GOING is dodged by changing
-- direction, which is a decision rather than a reflex. 0.35s of horizontal
-- velocity is about one stride at run speed - enough to punish a straight
-- line, short enough that a stop beats it.
K.RF_AIM_LEAD = 0.35
-- The burst's damage frame, as a fraction of the ice breach's strike: the
-- instant the head is fully out and the sheet lets go. The pose curve, the
-- telegraph's countdown and the hit all read this one number.
K.RF_BURST_IMPACT = 0.55
-- Skyfall lands AT THE END of its strike, by construction - the whole strike
-- is the flight. Kept as a named constant so the pose, the countdown and the
-- hit cannot drift apart the way a literal 1.0 in three places would.
K.RF_SKY_IMPACT = 1.0
-- ...and the floe quake heaves on the very first frame of its strike, which
-- is `fire` - the exact instant the windup expires. The client draws the
-- heave on its own clock from the telegraph's `duration`, so this MUST be 0:
-- any impact fraction here would be a countdown that finishes before the
-- damage does.
K.RF_LANE_IMPACT = 0.0
-- How much of the ground track is spent before the dive begins, so PoseCenter
-- (the ground point under the head) has stopped moving by the time the body
-- is coming down it. Matches the pose contract's hang-and-pitch-over at 0.58.
K.RF_SKY_SETTLE = 0.58
-- JUMPED, NOT OUTRUN. A player in Jumping/Freefall - or simply this many
-- studs clear of the impact plane - is over the shockwave when it passes.
K.RF_AIR_CLEAR = 3.0

-- The countdowns the stock telegraph draws for the new handlers. Registered
-- here rather than in the K.HANDLER_IMPACT literal so the whole of Rimefang's
-- kit stays inside Rimefang's region; the table is only ever read at runtime,
-- long after this chunk has finished loading. All three moves opt OUT of the
-- stock tell today (they mark their own, better-placed points), so these are
-- the honest values for the day somebody turns one back on.
K.HANDLER_IMPACT.icebreach = K.RF_BURST_IMPACT
K.HANDLER_IMPACT.skyfall = K.RF_SKY_IMPACT
K.HANDLER_IMPACT.lane = K.RF_LANE_IMPACT

-- PREDICTIVE AIM, and the one function every new lock goes through. The point
-- is grounded (so a mark drawn on it sits on the sheet rather than at the
-- player's waist) and clamped into the arena (so a player who runs for the
-- rim cannot drag the whale's commit outside the circle Fn.clampToArena will
-- immediately haul it back inside of - which is how a "locked" point used to
-- end up somewhere the body could never reach).
function Fn.rfAimPoint(creature, root: BasePart?, lead: number): Vector3
	if not root then
		return groundedPos(creature.pos, 0)
	end
	local velocity = root.AssemblyLinearVelocity
	local at = root.Position + Vector3.new(velocity.X, 0, velocity.Z) * lead
	local def = bossDef(creature)
	local anchor = creature.anchor
	if anchor and def and def.arena then
		local off = Vector3.new(at.X - anchor.X, 0, at.Z - anchor.Z)
		if off.Magnitude > def.arena.radius then
			at = anchor + off.Unit * def.arena.radius
		end
	end
	-- The player's own Y is the ray's hint, not the answer: groundedPos casts
	-- from just above it onto whatever is underneath.
	return groundedPos(Vector3.new(at.X, root.Position.Y, at.Z), 0)
end

-- Is this player off the ice? Two tests, because either one alone lies: the
-- humanoid state is authoritative for a jump but reads Freefall for a single
-- frame off a ledge, and a height band alone would spare anybody standing on
-- a rise. Together they mean "in the air over the impact plane".
function Fn.rfAirborne(root: BasePart, groundY: number): boolean
	if root.Position.Y > groundY + K.RF_AIR_CLEAR then
		return true
	end
	local character = root.Parent
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local state = humanoid:GetState()
		return state == Enum.HumanoidStateType.Jumping or state == Enum.HumanoidStateType.Freefall
	end
	return false
end

-- Flat distance from a point to the segment [from, from + dir*length]. The
-- floe quake's corridor is a segment, not a circle, and a radius test would
-- either miss the far end or catch the whole arena.
function Fn.rfSegDist(at: Vector3, from: Vector3, dir: Vector3, length: number): number
	local off = Vector3.new(at.X - from.X, 0, at.Z - from.Z)
	local along = math.clamp(off:Dot(dir), 0, length)
	return (off - dir * along).Magnitude
end

-- MAY THE PICKER OFFER THIS MOVE? Rimefang-only, and only for a row that asks
-- (`needsFlukeTarget`), so every other boss and every kitted hostile takes the
-- `true` on the first line. The fluke slam hammers the ice at the TAIL, 56
-- studs behind the nose, and nothing aims the tail: on a 70-stud arena it is
-- usually pointed at open ice, and rolling it there spent 2.1 seconds of the
-- fight on a move that could not hit anybody. Gated at the PICK rather than
-- re-aimed, because re-aiming the tail is exactly the lie kit v2 removes.
function Fn.rfPickAllows(creature, p, name: string?): boolean
	if creature.row.boss ~= K.RIMEFANG_BOSS then
		return true
	end
	-- THE OPENER OWNS THE NEXT SLOT. While the sheet is still due to be
	-- shattered nothing else may be offered. `shatter` is in no phase list
	-- and so can never come out of this pool - it arrives through the
	-- engine's own `creature.forcedAttack`, which Fn.pickBossAttack spends
	-- before it ever builds one (Fn.rfPhaseWatch re-asserts it every idle
	-- frame until the move has actually landed). This is the belt to that
	-- brace: if the override were ever lost, the pool empties and the
	-- picker falls back to the phase list's first entry rather than
	-- rolling a set piece over the top of the opener.
	if creature.rfShatterDue then
		return name == "shatter"
	end
	if not p or not p.needsFlukeTarget then
		return true
	end
	return #Fn.livingRootsNear(Fn.flukeGround(creature), p.radius or 24) > 0
end

-- THE ICE BREACH. It sinks, hunts you UNDER the sheet at `hunt` studs/second
-- toward where you are going, and `lock` seconds before the windup ends it
-- COMMITS: it stops moving, and the mark goes down on the ice. Then it comes
-- up through that mark nose-first and topples onto the floe.
--
-- The lock is the whole design. Everything before it is pressure you can walk
-- away from (the crack-web follows you, drawn at PoseCenter, which is the
-- head); everything after it is a fixed circle with an honest countdown. The
-- 0.6s between them is the reaction budget, stated once, in the row.
K.ATTACK_HANDLERS.icebreach = {
	-- `u` is the shared loop's windup progress; the POSE reads it, this hook
	-- works off the loop's own deadline instead (see `left` below).
	windup = function(creature, def, p, _u, sub)
		local a = creature.attack
		local now = os.clock()
		-- The shared loop does not hand a windup hook its dt, and this one
		-- MOVES the boss, so the step is measured here. Clamped: a hitch must
		-- not teleport the hunt across the arena in one frame.
		local dt = math.clamp(now - (a.rfLast or now), 0, 0.25)
		a.rfLast = now
		creature.model:PivotTo(poseCFrame(creature, sub, 0, 0))
		if a.locked then
			return
		end
		-- Time until the strike begins, from the loop's OWN deadline rather
		-- than from `u` - the telegraph's countdown is this number, and a
		-- countdown reconstructed from a progress fraction is a frame long.
		local left = math.max(a.phaseUntil - now, 0)
		a.aim = Fn.rfAimPoint(creature, (Fn.nearestPlayerRoot(creature.pos)), K.RF_AIM_LEAD)
		if left <= (p.lock or 0.6) then
			a.locked = true
			a.impact = a.aim
			fireEvent("telegraph", a.impact, {
				kind = "mark",
				move = "icebreach",
				radius = p.radius,
				-- Through the BURST, not up to the surfacing: the sheet does
				-- not let go until 0.55 of the strike.
				duration = left + (p.duration or 0) * K.RF_BURST_IMPACT,
				skin = p.skin,
			})
			return
		end
		local to = Vector3.new(a.aim.X - creature.pos.X, 0, a.aim.Z - creature.pos.Z)
		local step = math.min((p.hunt or 30) * dt, to.Magnitude)
		if step > 1e-3 then
			creature.pos = groundedPos(creature.pos + to.Unit * step, creature.halfThickness)
			Fn.clampToArena(creature, def)
		end
	end,
	-- Belt and braces: a windup shorter than `lock` (a retune, or an enrage
	-- that ever touches windups) would otherwise reach the strike unlocked and
	-- silently damage the whale's own position - v1's exact bug.
	fire = function(creature, def, p, _now, root)
		local a = creature.attack
		-- HOW MANY ERUPTIONS THIS BREACH IS. Decided once, at the strike, and
		-- only in phase two or later: `chain = 2` on the row means the whale
		-- comes up twice. Latched here rather than at the recover so the pose
		-- can read it on the same frame the recover begins, and guarded on nil
		-- so Fn.rfChainRearm's second pass cannot re-arm the counter.
		if a.chainLeft == nil then
			local escalated = creature.enraged or (creature.rfPhase or 1) >= 2
			a.chainLeft = if escalated and (p.chain or 0) > 1 then p.chain - 1 else 0
		end
		if not a.locked then
			a.locked = true
			a.impact = a.aim or Fn.rfAimPoint(creature, root, K.RF_AIM_LEAD)
			fireEvent("telegraph", a.impact, {
				kind = "mark",
				move = "icebreach",
				radius = p.radius,
				duration = (p.duration or 0) * K.RF_BURST_IMPACT,
				skin = p.skin,
			})
		end
		-- IT COMES UP WHERE THE MARK IS. The head is teleported onto the lock
		-- point for the strike; the client never sees a jump because the body
		-- is under the ice at Submerge 1 on this frame and the burst pose
		-- lifts it out of exactly this spot.
		creature.pos = groundedPos(Vector3.new(a.impact.X, creature.pos.Y, a.impact.Z), creature.halfThickness)
		Fn.clampToArena(creature, def)
	end,
	strike = function(creature, def, p, now, _dt, u, _root, sub)
		local a = creature.attack
		creature.model:PivotTo(poseCFrame(creature, sub, 0, 0))
		if a.fired or u < K.RF_BURST_IMPACT then
			return
		end
		a.fired = true
		local at = a.impact or creature.pos
		local lo, hi = Fn.bossRoll(creature, def, p.damage)
		-- Height-tolerant like the rest of the boss kit's radial hits: the
		-- mark is grounded and a player standing on a rise is still standing
		-- on the sheet that just exploded.
		damagePlayersInRadius(at, p.radius, lo, hi, creature, 0.5, K.BOSS_HEIGHT_TOLERANCE)
		-- OUTWARD AND UP, on the kit engine's own displacement vocabulary -
		-- the sheet coming apart under you, not a shove.
		fireEvent("gust", at, {
			radius = p.radius,
			push = p.push or 62,
			lift = p.lift or 34,
			duration = 0.45,
			move = "icebreach",
			skin = p.skin,
		})
		fireEvent("slam", at, { radius = p.radius, move = "icebreach", skin = p.skin })
		if p.slick then
			spawnPool(creature, at, p.slick, now)
		end
	end,
	recover = function(creature, _def, _p, _u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub, 0, 0))
		local a = creature.attack
		-- THE RE-DIVE. The chained eruption's recover is K.RF_CHAIN_RECOVER long
		-- rather than the row's 2.0, and it does not end the attack: it rewinds
		-- the same attack to a fresh windup, so the hunt runs again at the
		-- player's NEW predicted point and every telegraph and slam payload is
		-- byte-identical to the first eruption's. Only the LAST eruption reaches
		-- Fn.endBossAttack, which is what pays the `expose`/`holdExpose` window -
		-- one beached punish per chain, not one per breach.
		if not a or (a.chainLeft or 0) <= 0 or not a.chainAt or os.clock() < a.chainAt then
			return
		end
		a.chainLeft -= 1
		a.chainAt = nil
		Fn.rfChainRearm(creature, os.clock())
	end,
	finish = function(creature, _def, _p, now)
		local a = creature.attack
		if not a or (a.chainLeft or 0) <= 0 then
			return
		end
		-- Read by Fn.rimefangPhaseProgress as the recover's span, so the pose's
		-- re-dive curve finishes on exactly the frame the re-arm fires.
		a.recoverSpan = K.RF_CHAIN_RECOVER
		a.chainAt = now + K.RF_CHAIN_RECOVER
	end,
}

-- THE SHOCKWAVE'S SECOND PULSE, half a second behind the slam. Grounded-only,
-- and the band is strictly OUTSIDE the slam's own radius so nobody is billed
-- twice for one landing. `bypassIframe`, because it lands inside the
-- invulnerability the slam just handed out and the whole point of the beat is
-- that it is a separate thing to answer.
function Fn.rfShockPulse(creature, def, p, at: Vector3)
	local inner = p.radius or 18
	local outer = p.shock or 40
	local lo, hi = Fn.bossRoll(creature, def, p.shockDamage or { 18, 26 })
	for _, entry in Fn.livingRootsNear(at, outer) do
		local off = entry.root.Position - at
		if Vector3.new(off.X, 0, off.Z).Magnitude > inner and not Fn.rfAirborne(entry.root, at.Y) then
			PlayerService.damage(entry.player, math.random(lo, hi), creature, { bypassIframe = true })
		end
	end
	-- The shove is NOT gated on the jump: being knocked about by a wave you
	-- cleared costs nothing, and gating it would mean the ring visibly stops
	-- at whoever timed it right.
	fireEvent("gust", at, {
		radius = outer,
		push = p.shockPush or 46,
		duration = 0.4,
		move = "skyfall",
		skin = p.skin,
	})
end

-- The landing itself, called from the strike's last frame AND from `finish` -
-- a strike that ends between frames must not drop the blow, which is the same
-- reason the wash's finish flushes its queue.
function Fn.rfSkyLand(creature, def, p, now: number)
	local a = creature.attack
	if not a or a.fired then
		return
	end
	a.fired = true
	local at = a.impact or creature.pos
	creature.pos = groundedPos(Vector3.new(at.X, creature.pos.Y, at.Z), creature.halfThickness)
	local lo, hi = Fn.bossRoll(creature, def, p.damage)
	damagePlayersInRadius(at, p.radius, lo, hi, creature, 0.4, K.BOSS_HEIGHT_TOLERANCE)
	fireEvent("gust", at, {
		radius = p.radius,
		push = p.push or 90,
		lift = p.lift or 55,
		duration = 0.5,
		move = "skyfall",
		skin = p.skin,
	})
	fireEvent("slam", at, { radius = p.radius, move = "skyfall", skin = p.skin })
	-- The expanding ring, its own event kind because it is its own mechanic:
	-- the client draws 40 studs of shockwave over 0.7s and the player's answer
	-- is a jump timed against it.
	fireEvent("rimeShock", at, { radius = p.shock or 40, duration = p.shockDuration or 0.7 })
	a.shockAt = now + (p.shockAt or 0.5)
end

-- THE SKY SLAM. Windup tracks; `fire` locks and marks; the strike is the
-- flight, with the ground track finished before the dive so the mark under
-- the head stops moving; the impact is at the very end of it, and the
-- shockwave's second pulse lands half a second into the recover.
K.ATTACK_HANDLERS.skyfall = {
	windup = function(creature, _def, _p, _u, sub)
		local a = creature.attack
		creature.model:PivotTo(poseCFrame(creature, sub, 0, 0))
		-- TRACKED, not latched, for the whole windup: the commit is the
		-- telegraph, and it is fired below at the windup's end.
		a.aim = Fn.rfAimPoint(creature, (Fn.nearestPlayerRoot(creature.pos)), K.RF_AIM_LEAD)
	end,
	fire = function(creature, _def, p, _now, root)
		local a = creature.attack
		a.impact = a.aim or Fn.rfAimPoint(creature, root, K.RF_AIM_LEAD)
		a.launch = creature.pos
		fireEvent("telegraph", a.impact, {
			kind = "mark",
			move = "skyfall",
			radius = p.radius,
			-- The whole strike IS the countdown: it lands at the end of it.
			duration = (p.duration or 0) * K.RF_SKY_IMPACT,
			skin = p.skin,
		})
	end,
	strike = function(creature, def, p, now, _dt, u, _root, sub)
		local a = creature.attack
		local launch = a.launch or creature.pos
		local impact = a.impact or creature.pos
		-- THE GROUND TRACK, and why it is finished early. PoseCenter for this
		-- move is the ground point under the head, so creature.pos IS the
		-- shadow: easing it all the way to the mark by the time the dive
		-- starts means the shadow settles on the mark and then the body falls
		-- into it, rather than the two arriving together and the mark reading
		-- as a moving target right up to the hit.
		local at = launch:Lerp(impact, smoothstep(math.min(u / K.RF_SKY_SETTLE, 1)))
		creature.pos = groundedPos(Vector3.new(at.X, creature.pos.Y, at.Z), creature.halfThickness)
		creature.model:PivotTo(poseCFrame(creature, sub, 0, 0))
		if a.fired or u < K.RF_SKY_IMPACT then
			return
		end
		Fn.rfSkyLand(creature, def, p, now)
	end,
	finish = function(creature, def, p, now)
		Fn.rfSkyLand(creature, def, p, now)
	end,
	recover = function(creature, def, p, _u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub, 0, 0))
		local a = creature.attack
		if not a or not a.shockAt or a.shocked or os.clock() < a.shockAt then
			return
		end
		a.shocked = true
		Fn.rfShockPulse(creature, def, p, a.impact or creature.pos)
	end,
}

-- THE FLOE QUAKE. A shoulder-down ram along the sheet. The bearing is latched
-- on the FIRST windup frame - the corridor is drawn once and never moves,
-- which is what makes a sidestep an answer - and the heave lands in `fire`,
-- the exact instant the windup expires. That exactness is a contract: the
-- client draws the heave on its own clock from the telegraph's `duration`, so
-- a server-side impact fraction (or a re-arm) would put the two out of step.
K.ATTACK_HANDLERS.lane = {
	windup = function(creature, _def, p, _u, sub)
		local a = creature.attack
		creature.model:PivotTo(poseCFrame(creature, sub, 0, 0))
		if a.aimed then
			return
		end
		a.aimed = true
		local root = Fn.nearestPlayerRoot(creature.pos)
		a.dir = if root then flatUnit(root.Position - creature.pos) else Fn.bossFacing(creature)
		a.from = groundedPos(creature.pos, 0)
		fireEvent("telegraph", a.from, {
			kind = "lane",
			move = "floequake",
			-- REQUIRED. Without a Vector3 facing the client falls back to the
			-- stock circular draw and the corridor is never shown.
			facing = a.dir,
			length = p.length or 60,
			-- FULL width on the wire; the client halves it. The server's hit
			-- test uses `half` for exactly that reason - two names, so neither
			-- side has to guess which convention the other holds.
			width = p.width or 10,
			duration = math.max(a.phaseUntil - os.clock(), 0),
			skin = p.skin,
		})
	end,
	fire = function(creature, def, p, _now, _root)
		local a = creature.attack
		if a.fired then
			return
		end
		a.fired = true
		local from = a.from or groundedPos(creature.pos, 0)
		local dir = a.dir or Fn.bossFacing(creature)
		local length = p.length or 60
		local half = p.half or 5
		local lo, hi = Fn.bossRoll(creature, def, p.damage)
		for _, entry in Fn.livingRootsNear(from, length + half) do
			if Fn.rfSegDist(entry.root.Position, from, dir, length) <= half then
				PlayerService.damage(entry.player, math.random(lo, hi), creature)
				-- LAUNCHED, not shoved: the gust is fired at the player's own
				-- feet with a small radius and a large `lift`, so the sheet
				-- bucking under them throws them up rather than outward along
				-- a radius the corridor does not have.
				fireEvent("gust", groundedPos(entry.root.Position, 0), {
					radius = 6,
					push = p.push or 24,
					lift = p.lift or 62,
					duration = 0.5,
					move = "floequake",
					skin = p.skin,
				})
			end
		end
	end,
	strike = function(creature, _def, _p, _now, _dt, _u, _root, sub)
		creature.model:PivotTo(poseCFrame(creature, sub, 0, 0))
	end,
}

-- move name -> the pose it wants, per phase. `pose` is a scratch table
-- already filled with the cruise pose, so each of these only writes what it
-- changes. Windup is the tell, strike is the blow, recover is the opening -
-- the same three beats the shared loop is already counting.
K.RF_MOVES = {}

-- COIL, SNAP, SETTLE. `snap` deals its damage at u >= K.SNAP_IMPACT, so the
-- jaws yawn wide through the lunge and slam shut ON that frame. Windup drops
-- the head (a submerge dip that returns to nothing before the strike) and
-- parts the jaws - the tell that a bite is loading; the snap whips the reach
-- out fast and decelerating into the hit; recover draws the head back.
K.RF_MOVES.bite = function(pose, phase, u, _now)
	pose.swim = 1
	if phase == "windup" then
		local e = smootherstep(u)
		-- The head-drop coil: a dip that rises and returns to 0 by mid-windup,
		-- so the strike (which does not touch submerge) inherits a level head.
		pose.submerge = 0.14 * math.sin(math.pi * math.min(u / 0.5, 1))
		pose.gape = 0.6 * e
		pose.lunge = 0.12 * e
	elseif phase == "strike" then
		local snapT = math.min(u / K.SNAP_IMPACT, 1)
		-- Reach whips out fast off the coil (0.12 at the handoff) and eases
		-- into the bite.
		pose.lunge = 0.12 + 0.88 * easeOutCubic(snapT)
		if u < K.SNAP_IMPACT then
			-- Yawns from the windup's 0.6 to a full gape right at the chomp.
			pose.gape = 0.6 + 0.4 * easeOutCubic(snapT)
		else
			-- Slams shut on the damage frame and after.
			pose.gape = 1 - easeOutCubic((u - K.SNAP_IMPACT) / (1 - K.SNAP_IMPACT))
		end
	else
		pose.swim = 1 - 0.4 * smootherstep(u)
		pose.lunge = 1 - smootherstep(u)
	end
end

-- It stands on its tail and LOOKS at you. The slow turn through the hold is
-- the whole point of the beat - it is picking someone - and it turns about
-- the bearing it latched, not toward whoever is nearest now.
K.RF_MOVES.spyhop = function(pose, phase, u, now)
	pose.swim = 0.3
	if phase == "windup" then
		-- A small gather dip (0 at both ends of it) as it loads the stand,
		-- then the surge up - smootherstep so it powers off the water and
		-- eases as it reaches the top rather than jerking to a halt.
		pose.submerge = 0.14 * math.sin(math.pi * math.min(u / 0.45, 1))
		pose.rise = smootherstep(u)
	elseif phase == "strike" then
		-- The scan: a single smooth sweep left-centre-right-centre across the
		-- hold (sin(2pi*u) is 0 at both ends, so it hands off clean), and a
		-- breathing bob and jaw that both vanish at the boundaries.
		local breath = math.sin(u * math.pi)
		pose.rise = 1 - 0.035 * breath * (0.5 - 0.5 * math.cos(now * 3.2))
		pose.gape = 0.08 * breath
		pose.face += math.sin(u * math.pi * 2) * math.rad(18)
	else
		-- Sinks back with weight - it hangs, then drops (easeIn accelerates
		-- down) - and settles a touch under before levelling.
		pose.rise = 1 - easeInCubic(u)
		pose.submerge = 0.16 * math.sin(math.pi * u)
		pose.swim = 0.3 + 0.3 * smootherstep(u)
	end
end

-- THE ICE BREACH. `burst` is a PROGRESS channel, not a weight: 0 is lying
-- horizontal under the sheet at RimefangPath.BURST_DEPTH, 0.55 is the head
-- fully out and vertical at BURST_HEIGHT, and 1 is flat on the floe in the
-- shape `beached = 1` draws. PoseCenter for the whole strike is the burst
-- point, which the handler has already pinned creature.pos to.
--
-- The 0.55 is not decoration: it is K.RF_BURST_IMPACT, the same number the
-- handler damages on and the telegraph counts down to, so the sheet cannot
-- let go on a frame where the head is still coming up.
K.RF_MOVES.icebreach = function(pose, phase, u, _now, a)
	local p = a and a.p
	if phase == "windup" then
		pose.swim = 1
		-- IT BURIES ITSELF FIRST, over `sink` real seconds rather than over a
		-- fraction of the windup: the row states the sink in seconds because
		-- that is what it reads as on screen, and the windup is long (2.2s) and
		-- mostly travel. smootherstep so it slips under rather than dropping.
		local win = math.max((p and p.windup) or 2.2, 1e-3)
		-- ...unless this is the SECOND eruption of a chain, which begins with
		-- the whale already under the sheet (the re-dive is the first one's
		-- recover). Ramping from 0 here would pop the body up through the ice
		-- for a frame before burying it again.
		pose.submerge = if a and a.rfSunk
			then 1
			else smootherstep(math.min(u * win / math.max((p and p.sink) or 0.4, 1e-3), 1))
		-- Nothing of the burst yet: under the ice IS burst 0, and the hunt is
		-- drawn by the crack-web the client lays at PoseCenter.
		pose.burst = 0
		-- The jaw cracks open over the last quarter, continuing into the roar.
		pose.gape = 0.2 * smootherstep(math.max((u - 0.75) / 0.25, 0))
	elseif phase == "strike" then
		pose.swim = 1
		-- Sheds the submerge over `rise` seconds as the body leaves the water,
		-- so the burst is not fighting a depth blend on the way up.
		local dur = math.max((p and p.duration) or 0.7, 1e-3)
		pose.submerge = 1 - smootherstep(math.min(u * dur / math.max((p and p.rise) or 0.2, 1e-3), 1))
		if u < K.RF_BURST_IMPACT then
			-- THE ERUPTION: fast off the mark, easing as it reaches full height
			-- - it is thrown out by the sheet giving way, not lifted.
			pose.burst = K.RF_BURST_IMPACT * easeOutCubic(u / K.RF_BURST_IMPACT)
		else
			-- THE TOPPLE: accelerating the whole way down, because it is
			-- falling. Lands on burst 1 exactly at the strike's end, which is
			-- the shape `beached = 1` draws and where the recover picks it up.
			local t = (u - K.RF_BURST_IMPACT) / (1 - K.RF_BURST_IMPACT)
			pose.burst = K.RF_BURST_IMPACT + (1 - K.RF_BURST_IMPACT) * easeInCubic(t)
		end
		-- THE ROAR, peaking as the head clears the ice at 0.55 and shut by the
		-- time it comes down; 0 at u = 1 (sin(pi)), so it hands off clean.
		pose.gape = 0.2 + 0.7 * math.sin(math.pi * math.min(u / K.RF_BURST_IMPACT, 1))
	elseif a and (a.chainLeft or 0) > 0 then
		-- THE RE-DIVE, and the chain's whole visual argument: it does NOT lie
		-- on the ice. `burst` runs back down to 0 as the body slides through
		-- its own hole and `submerge` comes back on, so the pose lands on
		-- exactly the state the next windup's `rfSunk` branch holds - 1 - and
		-- nothing snaps across the re-arm.
		local e = smootherstep(u)
		pose.swim = 1
		pose.burst = 1 - e
		pose.submerge = e
		pose.gape = 0.2 * (1 - e)
	else
		-- THE HANDOFF. `burst = 1` and `beached = 1` are the same shape, so
		-- crossfading one into the other moves nothing - which is the whole
		-- reason the contract makes them match. Ramped rather than dropped, for
		-- the reason the old breach's `arch` was ramped: a hard drop rewinds
		-- the body down its own curve while the override is only half blended.
		pose.swim = 1 - 0.75 * smootherstep(math.min(u * 3, 1))
		pose.beached = smootherstep(math.min(u * 3, 1))
		pose.burst = math.max(0, 1 - pose.beached)
		pose.gape = 0.2 * (1 - smootherstep(u))
	end
end

-- THE SKY SLAM. `skyfall` is the other progress channel: 0 on the surface,
-- 0->0.45 the climb to RimefangPath.SKY_HEIGHT, 0.45->0.58 the hang and the
-- pitch over, 0.58->1 the descent, impact at 1 in the shape `beached = 1`
-- draws. PoseCenter is the ground point under the head, which is creature.pos
-- - the handler eases it onto the mark by 0.58 so the shadow settles before
-- the body falls into it.
--
-- THE PROGRESS IS WALKED WITH hangArc, and that is the beat. Linear progress
-- would give a constant climb rate and a hang that lasts as long as the
-- contract's 0.13 of the channel; hangArc(u, 0.55) leaves the ground fast,
-- STRETCHES the apex in time (that stretch is the count-in for the jump the
-- shockwave is about to ask for), and accelerates into the landing. It hits
-- 0, 0.5 and 1 exactly at u = 0, 0.5 and 1, so the impact lands on the frame
-- K.RF_SKY_IMPACT names and nowhere else.
K.RF_MOVES.skyfall = function(pose, phase, u, _now)
	if phase == "windup" then
		pose.swim = 1
		-- ANTICIPATION: it dips, gathers, and is back at the surface before the
		-- launch (sin(pi * u/0.7) is 0 at u = 0 and again at u = 0.7), with the
		-- jaw opening the whole way through - the tell that this is the big one.
		pose.submerge = 0.75 * math.sin(math.pi * math.min(u / 0.7, 1))
		pose.gape = 0.75 * smootherstep(u)
		pose.skyfall = 0
	elseif phase == "strike" then
		pose.swim = 1
		pose.submerge = 0
		pose.skyfall = hangArc(u, 0.55)
		-- Bellows through the climb and the hang, and is shut for the descent:
		-- the silence on the way down is the tell that it is about to land.
		pose.gape = 0.75 * (1 - smootherstep(math.max((u - 0.55) / 0.45, 0)))
	else
		-- Same handoff as the ice breach: skyfall 1 and beached 1 are one
		-- shape, crossfaded rather than dropped.
		pose.swim = 1 - 0.75 * smootherstep(math.min(u * 5, 1))
		pose.beached = smootherstep(math.min(u * 5, 1))
		pose.skyfall = math.max(0, 1 - pose.beached)
	end
end

-- THE FLOE QUAKE. The wash's vocabulary - shoulder down, dig in - but held
-- straight and driven FORWARD rather than swept: the roll is the tell that
-- something is coming along a line, and `lunge` is the body carrying through
-- it. Less roll than the wash (52 degrees against 74) on purpose, so the two
-- moves do not read as the same animation from across the arena.
K.RF_MOVES.floequake = function(pose, phase, u, _now)
	local hard = math.rad(-52)
	pose.swim = 1
	if phase == "windup" then
		-- Counter-roll the other way first (anticipation), dying out as it
		-- commits; the shoulder digs in, and the body loads over the last 40%.
		pose.roll = hard * smootherstep(u) + math.rad(7) * math.sin(math.pi * math.min(u / 0.35, 1))
		pose.submerge = 0.34 * smootherstep(u)
		pose.lunge = 0.25 * smootherstep(math.max((u - 0.6) / 0.4, 0))
	elseif phase == "strike" then
		-- THE RAM. 0.4s, and the damage is on its first frame, so the pose here
		-- is the follow-through of a blow that has already landed: hold the
		-- roll and the dig, and throw the reach out decelerating.
		pose.roll = hard
		pose.submerge = 0.34
		pose.lunge = 0.25 + 0.75 * easeOutCubic(u)
	else
		pose.roll = hard * (1 - smootherstep(u))
		pose.submerge = 0.34 * (1 - smootherstep(u))
		pose.lunge = 1 - smootherstep(u)
		pose.swim = 1 - 0.4 * smootherstep(u)
	end
end

-- THE WAVE WASH. Hard over onto its side, shoulder down, and sweep. The roll
-- IS the tell, and it has to read from the far side of the arena, because
-- the answer to this move is to move.
K.RF_MOVES.wash = function(pose, phase, u, _now)
	local hard = math.rad(-74)
	pose.swim = 1
	if phase == "windup" then
		-- A counter-roll the OTHER way first (anticipation), dying out as the
		-- body commits hard over; the shoulder digs in as it goes.
		pose.roll = hard * smootherstep(u) + math.rad(9) * math.sin(math.pi * math.min(u / 0.35, 1))
		pose.submerge = 0.18 * smootherstep(u)
	elseif phase == "strike" then
		-- Holds the roll and digs a touch deeper through the sweep (0 extra at
		-- both ends, so the boundaries stay put), shoulder held under.
		pose.roll = hard * (1 + 0.06 * math.sin(u * math.pi))
		pose.submerge = 0.18
	else
		-- Rights itself, smootherstep so it eases up under its own weight.
		pose.roll = hard * (1 - smootherstep(u))
		pose.submerge = 0.18 * (1 - smootherstep(u))
		pose.swim = 1 - 0.4 * smootherstep(u)
	end
end

-- The tail comes up clear of the water and hammers down. The fall and the
-- blow read the SAME constant (K.RF_FLUKE_IMPACT, with the handler): the ring
-- lands on the frame the fluke reaches the ice, and the marker's countdown
-- runs to that frame too.
K.RF_MOVES.flukeslam = function(pose, phase, u, _now)
	if phase == "windup" then
		-- ANTICIPATION: the head plunges (an extra dip that returns to 0) to
		-- lever the tail, and the rear itself holds low for the first slice
		-- before whipping up - the counter-beat before the hammer. It loads
		-- the body (swim rising late) as the tail reaches its full rear.
		pose.swim = 0.3 + 0.7 * smootherstep(math.max((u - 0.55) / 0.45, 0))
		pose.submerge = 0.55 * smootherstep(u) + 0.08 * math.sin(math.pi * math.min(u / 0.4, 1))
		pose.flukeUp = math.max(0, smootherstep(u) - 0.14 * math.sin(math.pi * math.min(u / 0.28, 1)))
	elseif phase == "strike" then
		pose.swim = 1
		pose.submerge = 0.55
		-- THE HAMMER: from reared (1) it accelerates DOWN to the contract's
		-- "hammered" ~0.2 exactly on the impact frame (K.RF_FLUKE_IMPACT), then
		-- relaxes fast toward rest - fast blow, hard settle.
		if u < K.RF_FLUKE_IMPACT then
			pose.flukeUp = 1 - 0.8 * easeInCubic(u / K.RF_FLUKE_IMPACT)
		else
			pose.flukeUp = 0.2 * (1 - easeOutCubic((u - K.RF_FLUKE_IMPACT) / (1 - K.RF_FLUKE_IMPACT)))
		end
	else
		-- The tail wallows back: swim eases to cruise, the head rises out of
		-- its dip, and one gentle settling flop (0 at both ends).
		pose.swim = 1 - 0.4 * smootherstep(u)
		pose.submerge = 0.55 * (1 - smootherstep(u))
		pose.flukeUp = 0.1 * math.sin(math.pi * u)
	end
end

-- The carousel's pose went with the carousel (see the note in its place in
-- Bosses.luau): a bank held around a circle centred on the arena, for a move
-- that could not land on anybody's mark. No dead pose code is left behind -
-- K.RF_MOVES is looked up by ATTACK NAME, so an entry for a move no phase can
-- roll is a curve nothing will ever run and a body nobody can check.

-- It rears out of the water and CALLS, and the storm answers. Partial rise,
-- and a jaw working through the call.
K.RF_MOVES.whiteout = function(pose, phase, u, now)
	if phase == "windup" then
		local e = smootherstep(u)
		-- A gather dip, then rear partway up and open the jaw for the call.
		pose.swim = 0.6 - 0.1 * e
		pose.submerge = 0.1 * math.sin(math.pi * math.min(u / 0.4, 1))
		pose.rise = 0.55 * e
		pose.gape = 0.6 * e
	elseif phase == "strike" then
		-- Held menacing through the storm: the rear stands, the jaw works the
		-- call, and the head sways to survey. Both the call and the sway are
		-- windowed by sin(u*pi) so they are 0 at the phase boundaries and the
		-- pose hands off without a jump.
		local hold = math.sin(u * math.pi)
		pose.swim = 0.5
		pose.rise = 0.55
		pose.gape = 0.6 + 0.3 * math.abs(math.sin(now * 5.5)) * hold
		pose.face += math.rad(10) * math.sin(now * 0.8) * hold
	else
		local e = 1 - smootherstep(u)
		pose.swim = 0.5 + 0.1 * smootherstep(u)
		pose.rise = 0.55 * e
		pose.gape = 0.6 * e
	end
end

-- ------------------------------------------------- rimefang: phase two (2026-09-09)
-- THE FIGHT'S SECOND HALF, and it is the ENRAGE: `enrageBelow` is 0.5 and so
-- is phase two's `below`, so the bar going red, the cooldowns tightening and
-- the moveset opening up are all one event rather than three that drift.
--
-- What is gained at 50%: skyfall, flukeslam and whiteout join the pool, the
-- ice breach starts chaining, and the sheet SHATTERS once - the opener below.

-- The phase-long blizzard. The client caps an arena storm at 20 s and stamps
-- its own deadline on arrival, so a storm that has to last a whole phase is
-- held by RE-SIGNALLING it, not by asking for a longer one. 12 s of refresh
-- against a 20 s window leaves 8 s of slack for a dropped frame or a
-- FireAllClients that arrives late; a refresh at 20 would strobe.
K.RF_STORM_REFRESH = 12
K.RF_PHASE_STORM = { storm = { mode = "blizzard", duration = 20 } }
-- The shattered sheet's pools last THE REST OF THE FIGHT. There is no
-- "forever" in the pool tick - it compares `now` against `expiresAt` - so the
-- fight-long lifetime is spelled as an hour, which no Rimefang kill has ever
-- come close to, and `kill()` drops them with the body so a duration this long
-- can never outlive the boss that made it.
K.RF_SHEET_LIFE = 3600
K.RF_SHEET_SLOW = 0.5
K.RF_SHEET_MIN = 4
K.RF_SHEET_MAX = 6
K.RF_THIN_ICE_RADIUS = 13
-- THE CHAIN'S SHORT RECOVER. A chained eruption does not lie on the ice: it
-- slides back under through its own hole after 0.8 s and hunts again, and the
-- full 2.0 s beached window is paid ONCE, by the last eruption in the chain.
-- Read twice - as the recover POSE's span (so the re-dive curve finishes
-- exactly as the next windup starts) and as the moment the re-arm fires.
K.RF_CHAIN_RECOVER = 0.8
-- The shatter's own impact fraction: it lands on the first frame of its
-- strike, like the floe quake, so its countdown is the windup exactly. `tell`
-- is false on the row (the handler draws the burst itself at the body), so
-- this is the honest value for the day somebody turns the stock tell back on.
K.RF_SHATTER_IMPACT = 0.0
K.HANDLER_IMPACT.shatter = K.RF_SHATTER_IMPACT

-- WHICH PHASE THE HEALTH FRACTION PUTS IT IN. A deliberate mirror of the
-- engine's `bossPhaseIndex`, which is a file-local declared ~500 lines BELOW
-- this one and therefore not an upvalue here; a forward declaration would be a
-- new top-level local, which this file cannot afford (the 200-register limit).
-- Same rule, same table, same answer.
function Fn.rfPhaseIndex(def, hpFraction: number): number
	local index = 1
	for i, phase in def.phases do
		if hpFraction <= phase.below then
			index = i
		end
	end
	return index
end

-- The four thin-ice patches as WORLD points. `BossArenas.items.ice.thinIce`
-- holds OFFSETS from the arena centre (the same convention `stones` and
-- `sockets` use), so they are resolved against the boss's anchor and grounded
-- - a pool drawn at the offset's raw Y would float or bury itself.
function Fn.rfShatterSites(creature, def): { Vector3 }
	local arena = def.islandId and BossArenas.items[def.islandId]
	local center = creature.anchor or creature.pos
	local sites = {}
	for _, offset in (arena and arena.thinIce or {}) do
		table.insert(sites, groundedPos(center + offset, 0))
	end
	return sites
end

-- The sheet coming apart, as hazard. One persistent pool per thin-ice patch:
-- open water that chills and nibbles, so the rim - which was the safe place to
-- read the fight from - costs something to stand on for the rest of it. The
-- damage is deliberately tiny (4-6 a tick); this is a floor tax, not a move.
function Fn.rfShatterPools(creature, def, now: number)
	local arena = def.islandId and BossArenas.items[def.islandId]
	local spec = {
		radius = (arena and arena.thinIceRadius) or K.RF_THIN_ICE_RADIUS,
		duration = K.RF_SHEET_LIFE,
		slow = K.RF_SHEET_SLOW,
		min = K.RF_SHEET_MIN,
		max = K.RF_SHEET_MAX,
		skin = "frost",
	}
	for _, site in Fn.rfShatterSites(creature, def) do
		spawnPool(creature, site, spec, now)
	end
end

-- THE PHASE WATCH, called once a frame from Fn.rimefangDrive. Three jobs, all
-- of which need to happen whatever the boss is doing:
--
--   1. Track the phase index, and the FIRST time it reaches 2 mark the shatter
--      due. Once only, for the whole fight (`rfShattered`).
--   2. Force the opener. `creature.forcedAttack` is the engine's own override -
--      Fn.pickBossAttack spends it before it builds a pool, and it is how
--      `follow` combos already work - so the shatter needs no picker change and
--      is not in any phase list. Re-asserted every idle frame rather than set
--      once, so an uproot that cancels the windup mid-flight cannot swallow the
--      opener: it is due until it has actually fired.
--   3. Hold the blizzard. Re-signalled every K.RF_STORM_REFRESH seconds while
--      the phase index is >= 2, and immediately whenever an attack ends -
--      Fn.endBossAttack closes the storm window for the move that owned it
--      (the whiteout carries one), and there is one window per island, so
--      without that second trigger the sky would clear for up to 12 s.
--
-- Nothing here runs after death: Fn.rimefangDrive returns on `creature.dead`.
function Fn.rfPhaseWatch(creature, def, now: number)
	local index = Fn.rfPhaseIndex(def, creature.health / math.max(creature.maxHealth, 1))
	local was = creature.rfPhase or 1
	creature.rfPhase = index
	if index >= 2 and was < 2 and not creature.rfShattered then
		creature.rfShatterDue = true
	end
	if creature.rfShatterDue and not creature.attack then
		creature.forcedAttack = "shatter"
	end
	local running = creature.attack ~= nil
	if creature.rfWasAttacking and not running then
		creature.rfStormAt = 0
	end
	creature.rfWasAttacking = running
	if index >= 2 and creature.rfShattered and now >= (creature.rfStormAt or math.huge) then
		creature.rfStormAt = now + K.RF_STORM_REFRESH
		Fn.signalArenaStorm(def, K.RF_PHASE_STORM, true)
	end
end

-- RE-ARM, for the ice breach's chain. The engine's attack loop only ever moves
-- windup -> strike -> recover -> Fn.endBossAttack, so a move that wants to run
-- twice rewinds its OWN state from inside its recover hook: the loop reads
-- `a.phase` and `a.phaseUntil` fresh on the next frame and simply starts the
-- windup again. Nothing else in the struct is reused, so every latched value
-- the hunt owns is cleared here - a stale `locked`/`impact` would erupt the
-- second breach at the first one's mark.
--
-- `a.rfSunk` is the pose handoff: the whale is ALREADY under the ice at the
-- moment it re-arms, so the windup curve must hold submerge at 1 rather than
-- ramping it from 0 and snapping the body up through the sheet for a frame.
function Fn.rfChainRearm(creature, now: number)
	local a = creature.attack
	if not a then
		return
	end
	a.phase = "windup"
	a.phaseStart = now
	a.phaseUntil = now + (a.windup or a.p.windup)
	a.locked, a.fired, a.aim, a.impact = false, false, nil, nil
	a.rfLast = now
	a.recoverSpan = nil
	a.rfSunk = true
end

-- THE SHEET SHATTERS: phase two's opener, and the only move in the fight the
-- player cannot answer by dodging alone - the answer is to be somewhere else
-- entirely when it lands, and then to live with the arena it leaves behind.
--
-- It rears into the spy-hop stand, roars, and comes down on its own position
-- with 26 studs of blow and an outward shove. The read is inverted from every
-- other move in the kit: every other one marks where YOU are going, and this
-- one marks where IT is. It is invulnerable for the windup and the strike -
-- the one moment in the fight the party cannot trade with it - so the beat
-- reads as a cutscene the fight is still running.
--
-- Fired EXACTLY ONCE per fight, by Fn.rfPhaseWatch, through the engine's
-- `forcedAttack`. It is in no phase list and its cooldown is nominal; the
-- once-only guarantee is `creature.rfShattered`, set the instant it lands.
K.ATTACK_HANDLERS.shatter = {
	windup = function(creature, _def, p, _u, sub)
		local a = creature.attack
		creature.model:PivotTo(poseCFrame(creature, sub, 0, 0))
		if a.rfTold then
			return
		end
		a.rfTold = true
		-- INVULNERABLE THROUGH THE BLOW. Stated as a deadline rather than a
		-- flag so no exit path - a stagger, an uproot cancelling the attack,
		-- the boss's own death - can leave it stuck on. `damage()` honours it,
		-- guarded on this row.
		creature.rfInvulnUntil = a.phaseUntil + (p.duration or 0)
		-- The tell is at the BODY, and the whole windup is its countdown: the
		-- move lands on the first frame of the strike (K.RF_SHATTER_IMPACT).
		fireEvent("telegraph", groundedPos(creature.pos, 0), {
			kind = "burst",
			move = "shatter",
			radius = p.radius,
			duration = math.max(a.phaseUntil - os.clock(), 0),
			skin = p.skin,
		})
	end,
	fire = function(creature, def, p, now, _root)
		local a = creature.attack
		if a.fired then
			return
		end
		a.fired = true
		-- ONCE, FOR THE WHOLE FIGHT. Cleared here rather than at the pick, so
		-- an opener interrupted before it landed is still owed.
		creature.rfShattered = true
		creature.rfShatterDue = false
		local at = groundedPos(creature.pos, 0)
		local lo, hi = Fn.bossRoll(creature, def, p.damage)
		damagePlayersInRadius(at, p.radius, lo, hi, creature, 0.5, K.BOSS_HEIGHT_TOLERANCE)
		-- Thrown OUT, barely up: the sheet dropping out from under you, which
		-- is a different displacement from the eruption's throw (lift 34).
		fireEvent("gust", at, {
			radius = p.radius,
			push = p.push or 80,
			lift = p.lift or 20,
			duration = 0.5,
			move = "shatter",
			skin = p.skin,
		})
		fireEvent("slam", at, { radius = p.radius, move = "shatter", skin = p.skin })
		-- THE ARENA CHANGES, and this is the event that says so. World points,
		-- not offsets: `position` is the anchor for the client's own framing and
		-- `sites` are already resolved, so nothing on the far side has to know
		-- the arena row's convention. Fired once, with the pools it describes.
		local arena = def.islandId and BossArenas.items[def.islandId]
		fireEvent("rimeShatter", creature.anchor or at, {
			-- Sent in the payload as well as on the wire: the wire position is
			-- where the effect happens, and `position` is the SHEET's centre,
			-- which is what a draw covering the whole floe has to be built from.
			-- They are the same point today and the contract states both.
			position = creature.anchor or at,
			-- The whole sheet, from the arena row rather than from the roam
			-- radius: the walked floe is r 120 and the leash is 70.
			radius = (arena and arena.floorRadius) or 120,
			sites = Fn.rfShatterSites(creature, def),
		})
		Fn.rfShatterPools(creature, def, now)
		-- ...and the sky closes for the rest of the phase. Signalled here and
		-- HELD by Fn.rfPhaseWatch's re-signal; the row carries no `storm` block
		-- on purpose, because Fn.endBossAttack would close one at the recover's
		-- end and the blizzard has to outlive the move that called it.
		Fn.signalArenaStorm(def, K.RF_PHASE_STORM, true)
		creature.rfStormAt = now + K.RF_STORM_REFRESH
	end,
	strike = function(creature, _def, _p, _now, _dt, _u, _root, sub)
		creature.model:PivotTo(poseCFrame(creature, sub, 0, 0))
	end,
	recover = function(creature, _def, _p, _u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub, 0, 0))
	end,
}

-- THE SHATTER'S BODY. Rear, roar, slam - and it hands back to the cruise pose
-- exactly, so the prowl picks it up without a step:
--   cruise -> windup: swim 0.6 -> 0.4, rise 0 -> 1, gape 0 -> 1, submerge 0.
--   windup -> strike:  swim 0.4 -> 0.25, rise 1 -> 0 by u 0.3, gape 1 -> 0 by
--                      u 0.4, beached pulsed 0 -> 1 -> 0 inside the strike.
--   strike -> recover: swim 0.25 -> 0.6, everything else already 0, which is
--                      the cruise pose the ambient prowl writes.
-- There is no expose on the row, so the recover hands straight to the prowl
-- rather than to Fn.rimefangDrive's beached window.
K.RF_MOVES.shatter = function(pose, phase, u, _now)
	if phase == "windup" then
		local e = smootherstep(u)
		pose.swim = 0.6 - 0.2 * e
		-- A gather dip that is back to 0 by mid-windup, so the rear lifts off a
		-- level body rather than out of a hole.
		pose.submerge = 0.12 * math.sin(math.pi * math.min(u / 0.35, 1))
		-- THE STAND. Rise 1 is the spy-hop, the tallest shape the path draws.
		pose.rise = e
		pose.gape = e
	elseif phase == "strike" then
		pose.swim = 0.4 - 0.15 * smootherstep(u)
		-- Down fast: the stand is spent in the first third of the strike, which
		-- is where the blow already landed (K.RF_SHATTER_IMPACT is 0).
		pose.rise = 1 - smootherstep(math.min(u / 0.3, 1))
		pose.gape = 1 - smootherstep(math.min(u / 0.4, 1))
		-- THE PULSE. `beached` is the flat-on-the-ice shape; here it is struck
		-- and released rather than held, because the whale does not lie down -
		-- it slams and is back in the water. 0 at both ends by construction.
		local up = smootherstep(math.min(u / 0.3, 1))
		local down = smootherstep(math.max((u - 0.5) / 0.5, 0))
		pose.beached = up * (1 - down)
	else
		-- Back to cruise. Every other channel is already at its cruise value.
		pose.swim = 0.25 + 0.35 * smootherstep(u)
	end
end

-- How far through the phase the shared attack loop is, on that loop's own
-- clock, so the pose and the damage can never be reading different times.
function Fn.rimefangPhaseProgress(a, p, now: number): number
	-- `a.recoverSpan` is the ice breach's chain, and nothing else writes it:
	-- a chained eruption recovers in K.RF_CHAIN_RECOVER rather than the row's
	-- full window, and the pose has to finish its re-dive on the same clock
	-- the re-arm fires on or the body rewinds mid-curve.
	local span = if a.phase == "windup"
		then p.windup
		elseif a.phase == "strike" then p.duration
		else (a.recoverSpan or p.recover)
	return math.clamp((now - a.phaseStart) / math.max(span or 0, 1e-3), 0, 1)
end

-- THE AMBIENT PROWL: a swim cycle that works as hard as the animal is
-- actually moving, a breath cycle that takes it under the sheet and brings
-- it back up to blow, and a bank into its own turns.
function Fn.rimefangAmbient(creature, def, pose, state, now: number, dt: number)
	-- The tail's effort, from the distance the boss covered this frame -
	-- free, and it can never disagree with where the fight actually put it.
	local moved = (creature.pos - (state.lastPos or creature.pos)).Magnitude / math.max(dt, 1e-3)
	-- ...plus a slow breath swell in the tail, so even a whale holding station
	-- between attacks keeps stroking rather than freezing at a flat effort.
	local breath = 0.06 * math.sin(now * 1.3)
	pose.swim = math.clamp(0.45 + moved / math.max(def.speed or 8, 1) * 0.55 + breath, 0.35, 1)

	if creature.rimefangBreathUntil == nil then
		creature.rimefangBreathUntil = now + K.RF_SURFACE_HOLD
		creature.rimefangDown = false
	end
	if now >= creature.rimefangBreathUntil then
		creature.rimefangDown = not creature.rimefangDown
		creature.rimefangBreathUntil = now + (if creature.rimefangDown then K.RF_DIVE_HOLD else K.RF_SURFACE_HOLD)
		if creature.rimefangDown then
			-- THE BLOW, then it slips under. Borrowed vocabulary, the way the
			-- wash rides `gust`: `bossDive` is already a plume of spray at
			-- the waterline, which is exactly what a blowhole looks like.
			fireEvent("bossDive", creature.pos, {})
		end
	end
	-- Under the sheet it holds the dive depth; up top it rides a small
	-- breathing heave (in phase with the tail's swell) instead of sitting
	-- frozen at the waterline - the surface half of "never static".
	pose.submerge = if creature.rimefangDown then K.RF_DIVE_DEPTH else 0.03 * (1 - math.cos(now * 1.3))

	-- A BANK INTO THE TURN: a whale rolls its shoulders through a heading
	-- change. Prowl only - an attack that wants a roll says so itself, and
	-- adding this on top would fight the wash's shoulder-down and the floe
	-- quake's held roll. Smoothed, because the yaw is already rate-limited and
	-- the raw per-frame delta is noise.
	local turn = angleDelta(state.faceAngle or pose.face, pose.face) / math.max(dt, 1e-3)
	local want = math.clamp(-turn * 0.22, -0.38, 0.38)
	state.bank = (state.bank or 0) + (want - (state.bank or 0)) * math.clamp(dt * 3, 0, 1)
	pose.roll += state.bank
end

-- One frame of Rimefang's body. Everything above the publish is a target;
-- the controller eases toward it (RimefangBodyController.EASE), so these are
-- step values rather than animation curves - except `arch`, which is leap
-- progress and tracks nearly rigidly on both sides.
function Fn.rimefangDrive(creature, now: number, dt: number)
	if creature.row.boss ~= K.RIMEFANG_BOSS or creature.dead or not creature.model.Parent then
		return
	end
	local def = bossDef(creature)
	if not def then
		return
	end
	-- PHASE TWO'S BOOKKEEPING, before anything else this frame reads it:
	-- the phase index, the once-only shatter, and the phase-long blizzard's
	-- re-signal. Runs whatever branch the body takes below, including while
	-- an attack is mid-flight.
	Fn.rfPhaseWatch(creature, def, now)
	local state = Fn.rimefangState(creature)
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
	-- The two kit-v2 progress channels. Both are 0 at rest and both are only
	-- ever written by their own move, so a frame outside those moves publishes
	-- them at 0 and the client's `Move` attribute is what says whether 0 means
	-- "under the ice" or "not running".
	pose.burst, pose.skyfall = 0, 0
	pose.face = creature.yaw0

	local attack = creature.attack
	if creature.mode == "rising" then
		-- It comes up out of the deep. The model is hidden, so "rising" is a
		-- number the client draws rather than a pivot the server performs.
		pose.submerge = 1 - modeProgress(creature, now)
		pose.swim = 1
		creature.rimefangBreathUntil = nil
	elseif attack then
		pose.face = Fn.rimefangFace(creature, attack)
		local move = K.RF_MOVES[attack.name]
		if move then
			-- `attack` is handed to the move as well so a beat can read its
			-- latched state (the two progress channels read their own row's
			-- `sink`/`rise` seconds off `a.p`); moves that do not need it
			-- simply ignore the argument.
			move(pose, attack.phase, Fn.rimefangPhaseProgress(attack, attack.p, now), now, attack)
		end
		-- The prowl's breath restarts once the move is over: it comes up and
		-- blows after a fight beat, not halfway through one.
		creature.rimefangBreathUntil = nil
	elseif
		(creature.lastAttack == "icebreach" or creature.lastAttack == "skyfall")
		and creature.exposedUntil
		and now < creature.exposedUntil
	then
		-- THE PUNISH WINDOW, and it is the DATA's window: `icebreach` carries
		-- `expose = 2` and `skyfall` `expose = 3.5`, Fn.endBossAttack opens it
		-- (after stamping the cooldown), and this only draws what that window
		-- already means. Nothing here decides how long it lasts.
		--
		-- BOTH big moves now open one, and both hand `beached = 1` to this
		-- branch - the ice breach through `burst` and the sky slam through
		-- `skyfall`, which is exactly why the contract makes all three shapes
		-- the same at 1. Naming them is deliberate: a move that does NOT end
		-- lying on the floe must not inherit the beached body just because it
		-- happens to carry an expose window.
		local left = creature.exposedUntil - now
		pose.beached = if left < 0.7 then smoothstep(left / 0.7) else 1
		pose.swim = 0.25
		creature.rimefangBreathUntil = nil
	else
		Fn.rimefangAmbient(creature, def, pose, state, now, dt)
	end

	state.swim, state.submerge, state.rise, state.roll = pose.swim, pose.submerge, pose.rise, pose.roll
	state.arch, state.beached, state.flukeUp = pose.arch, pose.beached, pose.flukeUp
	state.gape, state.lunge, state.faceAngle = pose.gape, pose.lunge, pose.face
	-- WRITTEN INTO THE STATE, not only onto the wire, and that is what keeps
	-- the server's hitbox honest for free: `rimefangBody` samples
	-- RimefangPath.pointAt on THIS state, so the moment the path understands
	-- `burst` and `skyfall` the 11-node hit chain follows the head up out of
	-- the ice and up into the sky without a line of new hit code.
	state.burst, state.skyfall = pose.burst, pose.skyfall
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
	rfPut(model, cache, "Burst", state.burst)
	rfPut(model, cache, "Skyfall", state.skyfall)
	-- WHICH MOVE IS RUNNING, as a string, so the client's continuous visuals
	-- (the crack-web under the hunt, the shadow under the sky slam) know which
	-- channel to believe. It has to be a string and so cannot ride rfPut's
	-- numeric NaN guard; the same change-cache rule applies for the same
	-- reason - an attribute write is a replicated write.
	--
	-- "" WHEN NOTHING IS RUNNING, never nil: clearing an attribute and setting
	-- it empty look identical on the client only if the client is checking for
	-- both, and one of the two is a habit nobody keeps.
	local moveName = if attack then attack.name else ""
	if cache.Move ~= moveName then
		cache.Move = moveName
		model:SetAttribute(K.RF_ATTR_MOVE, moveName)
	end
	-- THE PUNISH WINDOW PUBLISHES ITS OWN DEADLINE, in server time, because
	-- ATTR.EXPOSED cannot be trusted here: Fn.endBossAttack sets it, but its only
	-- expiry lives in Fn.updateKitted, which a plain `archetype = "boss"` never
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
	local center = Fn.rimefangCenter(state, creature.pos)
	if (center - state.center).Magnitude > 0.05 then
		state.center = center
		model:SetAttribute(K.RF_ATTR_CENTER, center)
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
-- The attack loop is the BOSS loop: begin/update/Fn.endBossAttack already read
-- only `def.attacks / turnRate / attackGapMin/Max / enrageCooldownMult` (and
-- handlers read `enrageDamageMult` via Fn.bossRoll, `riseDepth`/`aggro` for
-- dive-style moves; Fn.clampToArena no-ops without `creature.anchor`) - so a
-- kitted creature just feeds those functions a `book` built from its row
-- instead of a Bosses entry. Between moves it walks with `Fn.updateProwl`
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
function Fn.pickKitMove(creature, book, now: number, dist: number): string?
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
function Fn.updateProwl(creature, now: number, dt: number)
	Fn.slideKnockback(creature, dt)
	local root, _, dist = Fn.nearestPlayerRoot(creature.pos)
	if not root or dist > tune(creature, "RUSH_AGGRO_RANGE") then
		local hop, yaw, pitch = flop(creature, now)
		creature.model:PivotTo(poseCFrame(creature, hop, yaw, pitch))
		return
	end
	creature.yaw0 = approachAngle(creature.yaw0, yawToward(root.Position - creature.pos), math.rad(220) * dt)
	local standoff = (creature.row.tuning and creature.row.tuning.STANDOFF) or 8
	local delta = Vector3.new(root.Position.X - creature.pos.X, 0, root.Position.Z - creature.pos.Z)
	if delta.Magnitude > standoff then
		creature.pos = Fn.resolveHorizontal(creature, delta.Unit * tune(creature, "SHAMBLE_SPEED") * dt)
	end
	local breathe = math.sin(now * 2.1) * 0.12
	creature.model:PivotTo(poseCFrame(creature, math.max(0, breathe), 0, 0))
end

-- The kitted updater: attack in flight -> drive the shared loop; otherwise
-- walk (prowl, or the row's named `movement` archetype) and consider a pick.
function Fn.updateKitted(creature, now: number, dt: number)
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
		creature.model:SetAttribute(ATTR.EXPOSED, false)
	end

	local root, player, dist = Fn.nearestPlayerRoot(creature.pos)

	if creature.attack then
		Fn.updateBossAttack(creature, book, now, dt, root, player, dist, 0)
		return
	end

	local movement = creature.row.movement
	local walker = (movement and ARCHETYPE_UPDATERS[movement]) or Fn.updateProwl
	walker(creature, now, dt)

	if root and now >= (creature.nextAttackAt or 0) then
		local name = Fn.pickKitMove(creature, book, now, dist)
		if name then
			Fn.beginBossAttack(creature, book, name, now)
		end
	end
end

-- ============================================================ gimmicks (the quirk layer)
--
-- Small passive/reactive behaviours a row opts into via `gimmick = { kind,
-- ... }`. Each hook is consulted from exactly one engine point:
--   onDamage(creature, amount, now)  -> modified amount   (damage(), pre-HP)
--   onHit(creature)                  -> mult, reflect     (hitModifiers())
--   onContact(creature, dealt)                            (Fn.tryContact(), after a landed ram)
--   onKill(creature)                                      (kill(), before Killed fires)
K.GIMMICKS = {}

-- Armoured while telegraphing: hits during a windup do a fraction, so
-- panic-swinging into a tell is punished and the recover window is the
-- reward. { kind = "harden", mult = 0.35? }
K.GIMMICKS.harden = {
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
K.GIMMICKS.frenzy = {
	onDamage = function(creature, amount)
		local g = creature.row.gimmick
		if not creature.enraged and (creature.health - amount) / creature.maxHealth <= (g.below or 0.4) then
			creature.enraged = true
			creature.model:SetAttribute(ATTR.ENRAGED, true)
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
K.GIMMICKS.phasey = {
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
K.GIMMICKS.spines = {
	onHit = function(creature)
		return 1, creature.row.gimmick.reflect or C.THORN_REFLECT
	end,
}

-- Statically charged: every melee hit shocks the attacker a little.
-- { kind = "static", shock = n? }
K.GIMMICKS.static = {
	onHit = function(creature)
		return 1, creature.row.gimmick.shock or math.floor(C.PULSE_SHOCK_DAMAGE * 0.5)
	end,
}

-- Comedy physics: knockback sends it flying. { kind = "slippery", mult = 2? }
-- (Consulted in applyKnockback, not via a hook - one line there.)
K.GIMMICKS.slippery = {}

-- Heals a fraction of the contact damage it deals. { kind = "leech", frac = 0.5? }
K.GIMMICKS.leech = {
	onContact = function(creature, dealt)
		local g = creature.row.gimmick
		creature.health = math.min(creature.maxHealth, creature.health + math.ceil(dealt * (g.frac or 0.5)))
		creature.model:SetAttribute(ATTR.HEALTH, creature.health)
	end,
}

-- Detonates on death. { kind = "deathburst", radius = 9?, damage = {lo,hi}? }
K.GIMMICKS.deathburst = {
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
	return g and K.GIMMICKS[g.kind]
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
-- handler opens with Fn.openStagger(). The loop the redesign is built on:
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

ATTR.STANCE = "Stance" -- 1 = final stance; counts DOWN as it loses ground
-- How many it STARTED with, published once. Without it a client can only take
-- the first Stance it sees as the maximum, which is right for anyone present
-- at the summon and wrong for everyone who joins after: a boss two stances
-- down draws to a latecomer as an undamaged one.
ATTR.STANCES = "Stances"
ATTR.POSE = "Pose" -- which path module draws this body, for the client
ATTR.POSE_CENTER = "PoseCenter" -- the perch's anchor (the tower's foot)
-- Brinejaw's replicated pose. The client draws its entire body from these, so
-- this list is the contract with BrinejawBodyController.
ATTR.COIL = "Coil"
ATTR.UNWIND = "Unwind"
ATTR.SWEEP_ANGLE = "SweepAngle"
ATTR.SWEEP_HEIGHT = "SweepHeight"
ATTR.SLUMP = "Slump"
ATTR.FACE_ANGLE = "FaceAngle"
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
ATTR.ATTACK_KIND = "AttackKind"
ATTR.ATTACK_U = "AttackU"
ATTR.AIM_X = "AimX"
ATTR.AIM_Z = "AimZ"
-- Noctyss's replicated pose. The BOSS model publishes only the maw's three
-- numbers, because the choir publishes itself: each stalk is its own entity
-- with its own health bar, so it carries its own pose on its own model
-- (SocketIndex / TrueLure / Lean / BeamAngle / Douse / Grow, set by
-- Fn.updateChoir). This list is the contract with NoctyssBodyController.
ATTR.MAW_RISE = "MawRise"
ATTR.MAW_GAPE = "MawGape"
ATTR.MAW_YAW = "MawYaw"
ATTR.SOCKET_INDEX = "SocketIndex"
ATTR.TRUE_LURE = "TrueLure"
ATTR.LEAN = "Lean"
ATTR.BEAM_ANGLE = "BeamAngle"
ATTR.DOUSE = "Douse"
-- HOW FAR OUT OF ITS COLLAR A STALK IS, 0..1, absent meaning 1 - and the one
-- attribute in this contract the server had never written. The client has had
-- the whole growth animation for as long as the fight has existed, gated behind
-- this name and set by nothing but the intro cutscene: so after every punish
-- window the arena went dark for four seconds and then seven 33-stud stalks and
-- seven lanterns existed, fully formed, in one frame.
--
-- IT IS SAFE TO WRITE NOW, and that is a NoctyssPath change rather than this
-- one: `Grow` used to scale the DRAWN shape only, so a live stalk at grow < 1
-- would have been a lantern you can see low in its collar and can only shoot
-- thirty studs above it. The scale lives inside `stalkCurve`/`bulbPosition`
-- now - one curve, both sides - so the drawn eye and the tested one are the
-- same point at every value of it. `Fn.updateChoir` ramps it over
-- K.CHOIR_REGROW and gates targeting while it is under 1; see there.
ATTR.GROW = "Grow"
-- WHICH SOCKETS ARE EMPTY, as a bitmask on the BOSS model: bit (i - 1) set
-- means socket i is down. A dead stalk's model is destroyed, so the client
-- has nothing left to hang a collapse or a stump on - this is the only
-- record that socket ever held one. A bitmask rather than seven attributes
-- because it changes as a set, and one number can never replicate half a
-- choir.
ATTR.CHOIR_DOWN = "ChoirDown"
-- The Kraken's. It needs far less than Brinejaw: its head does not travel,
-- so all the client has to know is how far out of the water it is. Where the
-- eight arms are is not published at all - each one is drawn to the tentacle
-- creature it holds, and those replicate already.
ATTR.RISE = "Rise"
-- THE RIGGED-COLOSSUS SET. A boss whose limbs are animated needs more than a
-- height and a bearing, and these are the five: what it is doing, how far into
-- the pose, how far through the blow, and the aim it COMMITTED to at windup.
-- The names are the ones GnashrootBodyController already reads (bd, who is
-- migrating to them), so a second rigged boss adds a row to K.RIG_POSE below
-- rather than a second parallel branch.
ATTR.ATTACK = "Attack"
ATTR.ATTACK_BLEND = "AttackBlend"
ATTR.STRIKE = "Strike"
ATTR.AIM_ANGLE = "AimAngle"
ATTR.AIM_SIDE = "AimSide"
-- Pyrelisk's own: which arm is lying across the moat as the climb ramp, 0 for
-- neither. The client draws the ramp only while this is set, because that is
-- the only window the server actually offers footing.
ATTR.PLANTED = "Planted"
-- Pyrelisk's seams, and these four names are THE ATTRIBUTE CONTRACT
-- (PyreliskBodyController's header block) spelled the same way on both sides
-- of the wire. Two bitmasks with bit (i-1) = PyreliskPath.SEAMS[i]:
-- `SeamsOpen` is what is split open right now (set on windup, held through
-- the strike, cleared on every exit) and `SeamsBroken` is the permanent
-- scarring, monotonic for the life of the fight. The two meters are 0..1 per
-- flank: L is side +1 (seams 2, 4, 6), R is side -1 (seams 3, 5, 7). Bit 0 is
-- the chest and belongs to neither - phase 3's target, never opened here.
ATTR.SEAMS_OPEN = "SeamsOpen"
ATTR.SEAMS_BROKEN = "SeamsBroken"
ATTR.SEAM_METER_L = "SeamMeterL"
ATTR.SEAM_METER_R = "SeamMeterR"
-- WHICH ACT OF THE PYRELISK FIGHT THIS MODEL IS DRAWING: 1 the shell, 2 the
-- stun and the arms, 3 the heart. A LEVEL, held for as long as it is true and
-- never an edge, so a client adopting the fight at any instant reads the act
-- off the model instead of off a broadcast it was not there for.
--
-- THE CLIMB IS CUT (2026-09-12, the directive). Act 3 used to be the arm climb
-- - six ventrocks, the neck core, `crownshed` and the back vents - and it is
-- gone: the SECOND ARM'S DEATH is the hull's lethal chip, the body collapses
-- for `collapseFor`, the caldera opens under it and the party goes down the
-- shaft. So the colossus publishes 1 and 2 ONLY, the heart publishes
-- `K.PY_ACT_HEART`, and the numbering is still monotonic across the handoff
-- with nothing in between. NOTHING PUBLISHES AN ACT 4 ANY MORE.
-- One name across two models (the colossus carries 1-2, the heart 3), which is
-- why it is not `PhaseIndex`: that value already carries a specific
-- instruction on the Kraken ("do not draw the body") and an attribute may not
-- mean two things on the strength of a pose gate in a neighbouring file.
ATTR.PY_ACT = "PyreliskAct"
-- Each arm's bar, 0..1, published every frame of act 2. NIL IS NOT ZERO: nil
-- means "this arm is not a creature right now" (act 1, or act 3 once they are
-- gone) and 0 means "it is down there and it is dead", which are different
-- pictures for a HUD to draw.
ATTR.PY_ARM_L = "PyreliskArmL"
ATTR.PY_ARM_R = "PyreliskArmR"
-- THE ARENA's, not a creature's: the lake drains on the MODEL, so the level
-- survives the boss that opened it and replicates to anyone who arrives after.
-- A NUMBER (`1`), never a boolean - `BossArenaService` tests `== 1`.
ATTR.PY_CALDERA = "PyreliskCaldera"
-- THE SHAFT'S DATUM. Ratified into the section 7.2 contract (2026-09-12).
--
-- SERVER-CONSUMED, CLIENT-READABLE. Nothing on the client reads it today, and
-- that is a fact about today rather than a restriction: it sits on a replicated
-- instance like every other arena level, so a VFX lane that wants to know where
-- the shaft's mouth is may read it. What it must never become is a value the
-- client WRITES, or one the server reads back from the client.
--
-- Why it lives on the arena at all: the depth half of the shaft test needs the
-- arena's floor plane, and the only thing that knows it is the colossus
-- (`state.center.Y`) - which is destroyed a second and a half after the caldera
-- opens, while the thing that has to go on using it is the HEART, in another
-- room, which cannot ask. Nor is it derivable: `BossArenas.volcano.center.Y` is
-- 0 and `meshBottom` is the mesh's own bbox, not the rim path.
--
-- IT IS ONE HALF OF A PAIR, AND THE PAIR IS AN INVARIANT:
--
--     PyreliskCaldera == 1  <=>  PyreliskShaftFloor is a number
--
-- They are written together by `Fn.pyreliskOpenCaldera` and cleared together by
-- `Fn.pyreliskCloseCaldera`, and NOTHING ELSE MAY WRITE EITHER OF THEM. A stale
-- floor left behind by a closed caldera is not a stale number, it is a live
-- depth test with no hole under it - the next fight's party walking the rim
-- path over a plane that says "committed to the fall", arming a phantom shaft
-- test that teleports people out of an act-1 fight into an empty chamber.
--
-- That is why the clear is inside `Fn.pyreliskCloseCaldera` rather than beside
-- each of its callers: there are two endings (the heart's death and the
-- reaper's teardown) and a third would be written by somebody who had not read
-- this comment.
ATTR.PY_SHAFT_FLOOR = "PyreliskShaftFloor"
-- THE EIGHT OBSIDIAN PILLARS, as a bitmask of SURVIVORS, on the heart's model.
-- Bit (i-1) is `BossArenas.items.pyrelisk_heart.sockets[i]` in that table's
-- authored order - the `SeamsOpen` / `PyreliskRocks` convention, and the count
-- is load-bearing the same way: eight sockets, eight bits, eight parts. A ninth
-- socket with no bit behind it is the failure mode a bitmask has.
ATTR.PY_PILLARS = "PyreliskPillars"
-- (`ATTR.PY_ROCKS` and `ATTR.PY_CORE` stood here until the climb was cut. The
-- server writes NEITHER of them now, and no client change is owed by that: the
-- contract already says nil means "not planted, draw nothing", which is the
-- true statement about a fight that never plants them.)

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
function Fn.colossusState(creature, def)
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
			-- lifts a creature by half its own thickness - ~4.6 studs at her
			-- 2.0 scale - while every arena-local number this fight uses (the
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
			-- INTO the water, and `Fn.spawnBossParts` plants the whole tentacle
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
K.RIG_POSE = {
	-- `planted`: the arm that becomes the climb ramp. `seams`: the shootable
	-- shell (the four contract attributes below).
	pyrelisk = { planted = true, seams = true },
}

local function publishPose(creature, state)
	local model = creature.model
	if model:GetAttribute(ATTR.POSE) == nil then
		model:SetAttribute(ATTR.POSE_CENTER, state.center)
		model:SetAttribute(ATTR.POSE, creature.poseKind)
	end
	if creature.poseKind == "brinejaw" then
		model:SetAttribute(ATTR.COIL, state.coil)
		model:SetAttribute(ATTR.UNWIND, state.unwind)
		model:SetAttribute(ATTR.SWEEP_ANGLE, state.sweepAngle)
		model:SetAttribute(ATTR.SWEEP_HEIGHT, state.sweepHeight)
		model:SetAttribute(ATTR.SLUMP, state.slump)
		model:SetAttribute(ATTR.FACE_ANGLE, state.faceAngle)
		-- The attack channel. Defaulted here rather than at every writer, so a
		-- handler that sets nothing publishes a coherent idle rather than nil.
		model:SetAttribute(ATTR.ATTACK_KIND, state.attackKind or "")
		model:SetAttribute(ATTR.ATTACK_U, state.attackU or 0)
		model:SetAttribute(ATTR.AIM_X, state.aimX or 0)
		model:SetAttribute(ATTR.AIM_Z, state.aimZ or 0)
	elseif creature.poseKind == "kraken" then
		model:SetAttribute(ATTR.RISE, state.rise)
		model:SetAttribute(ATTR.FACE_ANGLE, state.faceAngle)
		-- POSE CENTRE IS THE SHIP, NOT THE HEAD, and the generic publish above
		-- cannot know that: it sends `state.center`, which on this fight is the
		-- head. Fn.colossusState seeds the pose from `creature.anchor`, and
		-- Fn.updateKrakenFight has already moved that anchor onto
		-- K.KRAKEN.HEAD_AT = (0, 0, -370) earlier in the same frame - so the
		-- 370 studs are on the wire, and KrakenBodyController adds them again
		-- through KrakenPath.HEAD_OFFSET. The animal lands 740 studs off the
		-- port beam with every limb reaching back across the sea for a deck
		-- target. `creature.krakenShip` is the value that was latched BEFORE the
		-- anchor moved, for exactly this reason.
		--
		-- RE-PUBLISHED EVERY FRAME rather than once, unlike the generic head:
		-- Fn.krakenSwallow moves the centre into the gullet mid-fight and this
		-- must not fight it, so phase 3 is skipped entirely. An unchanged
		-- SetAttribute does not replicate, so the cost is a comparison.
		local ship = creature.krakenShip
		if ship and (creature.krakenPhase or 1) < 3 then
			model:SetAttribute(ATTR.POSE_CENTER, ship)
		end
	elseif K.RIG_POSE[creature.poseKind] then
		-- The rigged-colossus publish, shared. Every field is on the state by
		-- the same name the client reads, so adding a rigged boss is a row in
		-- K.RIG_POSE - not another branch that can drift from this one.
		model:SetAttribute(ATTR.RISE, state.rise)
		-- FACE ANGLE STOPS AT ACT 2, AND IT IS CLEARED RATHER THAN FROZEN.
		--
		-- `PyreliskPath.frozen(state)` is true for `act >= 2`, and a frozen body
		-- computes its own bearing and ignores this field entirely - so from the
		-- moment the arms come down this is a number crossing the wire every
		-- frame that nothing reads. That alone would only be waste.
		--
		-- WHAT MAKES IT WORTH A BRANCH IS THE TRAP. A live `FaceAngle` on a body
		-- that cannot turn is exactly the kind of plausible-looking field a
		-- future reader picks up - a HUD arrow, a VFX lane wanting "which way is
		-- it looking" - and it would track the boss's last pre-freeze heading
		-- forever while the drawn body faces somewhere else. Set to nil it reads
		-- as what it is: not applicable to this act.
		--
		-- Pyrelisk only. Every other rigged boss on this shared branch keeps
		-- publishing it, because none of them freezes.
		if creature.poseKind == "pyrelisk" and (state.act or 1) >= 2 then
			model:SetAttribute(ATTR.FACE_ANGLE, nil)
		else
			model:SetAttribute(ATTR.FACE_ANGLE, state.faceAngle)
		end
		model:SetAttribute(ATTR.ATTACK, state.attack or "")
		model:SetAttribute(ATTR.ATTACK_BLEND, state.blend or 0)
		model:SetAttribute(ATTR.STRIKE, state.strike or 0)
		model:SetAttribute(ATTR.AIM_ANGLE, state.aimAngle or state.faceAngle or 0)
		model:SetAttribute(ATTR.AIM_SIDE, state.aimSide or 1)
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
		model:SetAttribute(ATTR.STANCE, state.stance)
		model:SetAttribute(ATTR.STANCES, creature.poseStances or 1)
		if K.RIG_POSE[creature.poseKind].planted then
			model:SetAttribute(ATTR.SLUMP, state.slump or 0)
			model:SetAttribute(ATTR.PLANTED, state.planted or 0)
		end
		if K.RIG_POSE[creature.poseKind].seams then
			-- ON THE RIG'S OWN CADENCE, and defaulted here rather than at any
			-- writer. PRESENCE IS THE HUD'S GATE: it decides there is a seam
			-- fight to draw from these existing at all, so all four are
			-- published from the first pose frame - the whole rise included -
			-- at the identity values (0, 0, 0, 0) that are exactly the
			-- pre-seam draw. Nothing is published lazily and nothing is left
			-- nil for the HUD to guess at.
			model:SetAttribute(ATTR.SEAMS_OPEN, state.seamsOpen or 0)
			model:SetAttribute(ATTR.SEAMS_BROKEN, state.seamsBroken or 0)
			model:SetAttribute(ATTR.SEAM_METER_L, state.seamMeterL or 0)
			model:SetAttribute(ATTR.SEAM_METER_R, state.seamMeterR or 0)
		end
	elseif creature.poseKind == "noctyss" then
		model:SetAttribute(ATTR.MAW_RISE, state.mawRise)
		model:SetAttribute(ATTR.MAW_GAPE, state.mawGape)
		model:SetAttribute(ATTR.MAW_YAW, state.mawYaw)
	end
end

-- The whole visible boss is drawn by the client from the pose attributes, so
-- the server's model is authority only: it keeps its parts (hits and the HUD
-- read them) but shows nothing, or the head would be drawn twice.
function Fn.hideColossusModel(creature)
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
-- WHY THE SLABS ARE SPAWNED AND NOT BORROWED. `Fn.hideColossusModel` sets
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

-- ------------------------------------------------- THE CHIP LEDGER
--
-- The colossus's health bar is not a bar any more, it is a PROGRESS DIAL, and
-- these five fractions are everything that turns it. Nothing damages the
-- colossus directly in the redesigned fight: each milestone takes an exact
-- fraction off it (`Fn.pyreliskChip`), and the fractions are chosen so the
-- shipped stance machinery - `bossPhaseIndex` -> `ATTR.STANCE`, untouched -
-- tells the exact truth about which act the fight is in.
--
--   act 1   two flank scars      2 x 0.15 = 0.30    1.00 -> 0.70
--   act 2   two arms             2 x 0.35 = 0.70    0.70 -> 0.00
--
-- TWO CHIPS, NOT FOUR, SINCE THE CLIMB WAS CUT (2026-09-12). The six rocks'
-- 0.05s and the neck core's 0.00 are gone with act 3, and the arms absorbed
-- the 0.30 they used to spend: 0.20 -> 0.35 each. THE SECOND ARM'S CHIP IS THE
-- LETHAL ONE - it floors at `K.PY_CHIP_FLOOR` like every other chip, and
-- `Fn.pyreliskArmsDone` then takes the body down through `damage()` on the
-- same frame, by the same route `Fn.pyreliskCoreBroken` used to.
--
-- THE THRESHOLD IS 0.70 (Bosses.items.pyrelisk.phases), and it is not a round
-- number chosen for looks: a chip that does not land exactly on a boundary
-- fires a stance change - a banner, a sting and a new attack pool - in the
-- MIDDLE of an act, silently. `tools/check_content.py` asserts both equalities
-- across this file and Bosses.luau for exactly that reason; the second one
-- asserts the ledger SUMS TO 1.0, so the day someone re-tunes a chip alone the
-- gate fails instead of the fight.
--
-- Authored as exact two-decimal values so the sum is representable; the gate
-- compares to 1e-9 regardless.
K.PY_FLANK_FRACTION = 0.15
K.PY_ARM_FRACTION = 0.35
-- (`K.PY_ROCK_COUNT`, `K.PY_ROCK_LIFT`, `K.PY_ROCK_WEAVE` and `K.PY_CORE_LIFT`
-- stood here until the climb was cut. Nothing places a rock or a core any
-- more, and nothing can: the mesh lane DELETED `PyreliskPath.armRocks` and
-- `.neckCorePoint` in the same unit, so a surviving call would not silently
-- place a rock somewhere plausible - it would take the type-check-and-warn
-- path. `.climbSlabs` and `.rampCFrame` are still live, and are still act 1's:
-- the bait `handfall` plant window reads them, and they hand back nothing once
-- the body is fallen, which is what makes the mount layer's own gate belt and
-- braces rather than the only thing standing between act 2 and a ramp.)
-- WHEN THE CALDERA OPENS, in seconds into the collapse. The write itself is
-- slice 5; this is the number the hook is measured against, and it lives here
-- so the two slices cannot disagree about it. `collapseFor` (Bosses row) is
-- 4.0, so the lake drains with 1.5 seconds of fall still to watch.
K.PY_CALDERA_AT = 2.5
-- THE SHAFT, once the lake floor is gone. 100 against the lake's own 120: the
-- hole is INSIDE the lake, which is the whole reason `Fn.pyreliskLavaWatch` has
-- to stand down while it is open (it would rescue every jumper straight back
-- out onto the rim).
K.PY_SHAFT_R = 100.0
-- HOW FAR DOWN COUNTS AS COMMITTED. Measured from the arena's own floor plane
-- rather than from an absolute height, so it travels with an arena that moves.
-- Seventy studs is far enough that nobody is taken by walking near the edge and
-- near enough that it fires while the fall still reads as a fall.
K.PY_SHAFT_DROP = 70.0
-- ...AND THE BACKSTOP. Nobody may be stranded on a summit whose boss has left,
-- so this long after the caldera opens the stragglers are taken whether they
-- jumped or not. THE JUMP IS THE BEAT AND THIS IS THE NET - the Kraken's
-- whole-party swallow used as a backstop rather than as the beat.
K.PY_SHAFT_GRACE = 30.0
-- How often the shaft is polled. The lava watch's own cadence, and for the same
-- reason: this is a proximity test over a handful of players, not a raycast.
K.PY_SHAFT_TICK = 0.5

-- ------------------------------------------------- ACT 4: THE HEART
--
-- Which row is the heart. Named rather than compared inline so the two places
-- that ask (the fight tick and the gimmick) cannot drift apart, and so the
-- string that has to match `Bosses.items.pyrelisk_heart` exists once.
K.PY_HEART_BOSS = "pyrelisk_heart"
-- WHICH ACT THE HEART IS. The act numbering lives in ONE place because the cut
-- of the climb renumbered it once already (the heart was act 4 while the arm
-- climb was act 3) and the next person to move it must not have to find every
-- literal: `Fn.pyreliskPublishAct` writes 1 and 2 on the colossus, this is the
-- only other value anything publishes, and `ATTR.PY_ACT`'s contract block is
-- written against the pair.
K.PY_ACT_HEART = 3
-- EIGHT PILLARS, EIGHT SOCKETS, EIGHT BITS. Same sentence as the six arm rocks,
-- and asserted at plant for the same reason.
K.PY_PILLAR_COUNT = 8
-- EVERY BROKEN PILLAR TIGHTENS THE ROOM. The heart's cooldowns are multiplied
-- by this once per pillar down, so the eighth is fought at 0.90^7 = 0.478 of
-- the opening cadence - about twice as fast, reached gradually, and reached by
-- the party's own hand. The fight gets louder as it gets shorter, which is the
-- argument the Kraken's `polypStep` makes one room over.
K.PY_PILLAR_STEP = 0.90
-- A broken pillar vents a PERMANENT pool at its own socket. `duration` is the
-- age of the universe rather than `math.huge`: pools are swept by an
-- `expiresAt` comparison and an infinity there is a number that never fails a
-- test but also never sorts, which is a different class of bug. The collapse
-- takes them all anyway (`creature.pools` dies with the creature).
K.PY_PILLAR_POOL = { radius = 12, duration = 1e9, min = 16, max = 24, skin = "lava" }
-- (ACT 3's AMBIENT PRESSURE - the three back vents on a clock, with
-- `K.PY_VENT_GAP` / `_ARM` / `_POOL` - stood here until the climb was cut.
-- Nobody walks on the body now, so there is no deck to make dangerous.
-- `PyreliskPath.VENTS` and `ventPoint` stay: they are the shipped vent
-- objects' sites and `ventbreath` is unchanged.)
-- A chip may not kill. Everything that CAN kill the colossus goes through
-- `damage()` and `beginBossCollapse`, so a chip floors here instead - a hair
-- above zero, so the dial can read "spent" without the death path having been
-- entered by a subtraction.
K.PY_CHIP_FLOOR = 1.0

-- ------------------------------------------------- ACT 2: THE STUN AND THE ARMS
--
-- HOW LONG THE COLOSSUS DOES NOTHING, capped. The stun lasts until both arms
-- are dead OR this long, whichever comes first, and both exits are real: the
-- arms dying is the act break, the cap expiring is the failure branch.
--
-- A FIXED NUMBER WOULD BE ONE OR THE OTHER FAILURE. Too short and the arms
-- survive with nothing in the design saying what happens; too long and the
-- arms die and the party stands about. 120 is six times `handfall.stagger`,
-- which the row calls "the most important number in the file", and it is the
-- only stretch of this fight in which the colossus does nothing at all -
-- unmistakably "super long" against the fight's own vocabulary.
--
-- UNMEASURED (design flag F-3): 120 and the arms' 7,000 HP are one decision
-- taken twice against a party DPS nobody has measured. Re-derive together.
K.PY_ARM_WINDOW = 120.0
-- How long the body takes to settle into the slump as the arms come down. The
-- shipped stagger shapes its slump off `modeProgress`, which over a 120-second
-- window would have spent twenty seconds easing in and twenty-one easing out;
-- act 2 holds the pose instead and eases only at the front.
K.PY_ARM_SLUMP_EASE = 1.4
-- THE ARMS BLEED ONTO THE GROUND YOU HAVE TO STAND ON TO HIT THEM. Every
-- `GAP` seconds an arm marks a point within `R` of itself on the rim path and
-- leaves a lava pool there after `ARM` seconds of warning. That is act 2's
-- whole clock: 120 seconds of zero pressure is a damage check, not a fight,
-- and the path shrinking is the Pyrelisk signature (`ventbreath`'s "the move
-- that permanently takes path away") turned into the act's timer.
K.PY_ARM_POOL_GAP = 7.0
K.PY_ARM_POOL_R = 55.0
K.PY_ARM_POOL_ARM = 1.4
-- The pool itself, `ventbreath`'s shape one size down (its own is radius 15 /
-- duration 10). A `spawnPool` spec, so nothing new draws it.
K.PY_ARM_POOL = { radius = 13, duration = 9, min = 14, max = 20, skin = "lava" }

-- The lake, and the two numbers that decide what happens to someone in it.
-- 120 is the caldera lake's edge (the row's `arena.radius` reasoning, and
-- handfall's `minReach`): everything inside it is lava.
K.PY_LAKE_R = 120.0
-- Where a rescue puts you down: the middle of the rim path, forty studs off
-- the lake and forty inside the lip's undercut - the same band the summon
-- ring drops the party on, and the only stretch of floor the whole fight can
-- reach you on.
K.PY_RESCUE_R = 150.0
-- HOW FAR ABOVE THE LAKE STILL COUNTS AS IN IT, and this is the load-bearing
-- half of the test. Everyone on the mount is inside the lake's radius - the
-- back deck is 202 studs straight up over it - so a flat radius check would
-- boil the entire party the moment they finished the climb they were asked
-- to make. Only something at the lava's own surface is in the lava.
K.PY_LAVA_HEAD = 16.0
K.PY_LAVA_TICK = 0.75
K.PY_LAVA_DAMAGE = { 70, 95 }
-- The shrug. Radius is the LAKE's, not the arena's: it has to reach everyone
-- standing on the body and nobody standing on the rim path, and those two
-- sets are separated by exactly that circle.
K.PY_SHAKE_PUSH = 62
K.PY_SHAKE_TIME = 0.55
-- How long the rig takes to put a pose down when a stagger opened with
-- nothing planted. Short - it is the tail of a blow that has already landed,
-- not an animation in its own right - but not a frame, which is what it was.
K.PY_WEAK_EASE = 0.4
-- How long the lava keeps watching after the window shuts. The shove happens
-- as the slabs go, so anyone it throws is still in the air at that instant -
-- a watch that ended with the window would miss every death it exists for.
K.PY_SHAKE_GRACE = 4.0
-- THE VENT-SMASH MINIGAME IS RETIRED, AND SO ARE ITS FOUR CONSTANTS
-- (`PY_VENT_REACH`, `PY_VENT_HITS`, `PY_VENT_FRACTION`, `PY_SWING_GAP`), its
-- listener, its per-player throttle and the three requires it needed to read a
-- player's hands (`InventoryService`, `Equipment`, `Weapons` - none of which
-- anything else on this page uses; audited by grep before deletion, the only
-- other mentions are in two comments).
--
-- WHY IT GOES. It existed because the punish window was a twenty-second visit
-- to the boss's back and needed something to do up there. Act 3 IS the climb
-- now, it lasts until the neck core dies, and what you do on the way up is
-- break six rocks that are real creatures with real health bars - shot or
-- swung at through CombatService like everything else in the game.
--
-- AND RETIRING IT IS A NET SIMPLIFICATION OF THE SECURITY SURFACE. This was
-- the one place in the project where a remote bypassed CombatService's weapon
-- cooldown and therefore needed to re-implement its equip check and carry a
-- rate limit of its own. Four numbers, three requires and a second listener on
-- `RequestAttack`, all so a swing could be read where it was sent. None of it
-- is needed to shoot a rock.
--
-- `K.PY_VENT_FRACTION` WAS THE PRECEDENT THE WHOLE CHIP LEDGER IS BUILT ON -
-- a milestone taking a fraction off the boss rather than damaging it - and it
-- leaves the file having been generalised into `Fn.pyreliskChip` and the five
-- `K.PY_*_FRACTION` values the gate asserts. The idea survives; the minigame
-- does not.
--
-- The three `PyreliskPath.VENTS` sites and the `Pyrelisk_Vent` objects are
-- untouched: they are geometry and they stay. Turning them into act-3 hazards
-- that fire on a clock is design section 4.4 and is NOT in this slice.

-- Every fight that currently has footing standing (creature -> mount). Only
-- ever zero or one entries, but keyed rather than a single upvalue so a
-- second arena on one server cannot make two windows share a state.
local pyreliskMounts = {}

-- One piece of the climb. Invisible and unqueryable, exactly like the maw
-- floor: the rock the player SEES is the client's, and a queryable slab in
-- the middle of the arena would eat the ranged shots aimed at the body behind
-- it and re-seat every ground telegraph drawn under it.
function Fn.pyreliskSlab(folder: Folder, name: string, size: Vector3, cframe: CFrame)
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
function Fn.openPyreliskMount(creature, state, now: number)
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
		Fn.pyreliskSlab(folder, slab.name, slab.size, slab.cframe)
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
function Fn.shakePyreliskMount(creature, state, now: number)
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
		radius = K.PY_LAKE_R,
		push = K.PY_SHAKE_PUSH,
		duration = K.PY_SHAKE_TIME,
		skin = "lava",
	})
	creature.pyreliskLavaUntil = now + K.PY_SHAKE_GRACE
	-- BACK TO REST. Opening a window skips the handler's `recover` (see
	-- Fn.openStagger), so the attack that earned this one is still sitting on
	-- the rig with blend 1 - and the moment `planted` clears, the working arm
	-- would snap back into a handfall windup it is not performing. The pose
	-- is this fight's furniture too; putting it down is part of packing up.
	--
	-- Except during the death, which is a pose of its own and has already been
	-- set for this frame (Fn.updateBossCollapse runs before Fn.placeColossus): a
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
-- THE ARENA MODEL, BY THE NAME ITS OWN ROW AUTHORS.
--
-- WHY BY NAME AND NOT THROUGH A HANDLE. `BossArenaService` builds the instance
-- (`placeAuthored` returns it to `init`, which arms the listener on it) but
-- exports no accessor for it, and that file belongs to another lane. Reaching
-- it as `Workspace.BossArenas.<arena.model>` is not a workaround, it IS the
-- documented contract between the two files - `BossArenaService`'s own
-- `CALDERA_ATTR` comment names this function as the writer and says so, and
-- `armCaldera` WARNS BY NAME at startup when the placed group does not carry
-- the row's `model` name, precisely so this lookup cannot fail silently.
--
-- The name comes off the BossArenas row rather than being typed here, so the
-- two ends cannot drift: change `arena.model` and both the listener and this
-- follow it.
-- Takes an ISLAND ID rather than a def, and deliberately: one of its callers
-- is `removeOwnedParts`, which is defined ~1500 lines ABOVE `bossDef` and
-- therefore cannot see it at all - a `bossDef(...)` call there is a global
-- lookup returning nil, which compiles clean, passes every gate, and throws
-- the first time the heart dies. A string has no such problem.
function Fn.pyreliskArenaModel(islandId: string?): Instance?
	local arena = islandId and BossArenas.items[islandId]
	local name = arena and arena.model
	if not name then
		return nil
	end
	local arenas = Workspace:FindFirstChild("BossArenas")
	return arenas and arenas:FindFirstChild(name)
end

-- IS THE CALDERA OPEN? Read off the ARENA model, as a LEVEL, every time it is
-- asked - never latched. A player who jumps in ten seconds after the lake
-- drains has to get the same answer as the one who jumped on the first frame.
--
-- The attribute is a NUMBER and the test is `== 1`, which is
-- `BossArenaService`'s own test on the same field; a boolean here would read
-- false against the value that is actually written.
function Fn.pyreliskCalderaOpen(islandId: string?): boolean
	local model = Fn.pyreliskArenaModel(islandId)
	return model ~= nil and model:GetAttribute(ATTR.PY_CALDERA) == 1
end

-- THE LAKE DRAINS. One write, a LEVEL, on the arena rather than on the boss -
-- so it outlives the colossus that opened it (which is dead moments later) and
-- replicates to anyone who joins mid-fall for free.
--
-- `1`, A NUMBER, never `true`: `BossArenaService.applyCaldera` tests `== 1`, and
-- a boolean there reads as closed while looking set in the explorer.
function Fn.pyreliskOpenCaldera(islandId: string?, floorY: number?)
	local model = Fn.pyreliskArenaModel(islandId)
	if not model then
		-- The one thing this cannot do is fail quietly. A caldera that never
		-- opens is a fight that stops at act three with a lake in the way and
		-- nothing in any log to say why.
		warn(
			string.format(
				"[CreatureService] the caldera cannot open: no Workspace.BossArenas.%s - "
					.. "the arena group was imported under another name (BossArenaService warns about "
					.. "this at startup) or the arena never placed",
				(islandId and BossArenas.items[islandId] and BossArenas.items[islandId].model) or tostring(islandId)
			)
		)
		return
	end
	-- THE SHAFT'S OWN DATUM, STAMPED BESIDE THE LEVEL THAT OPENED IT, and it
	-- is here because of WHO has to read it later.
	--
	-- The depth test that decides "this player has committed to the fall"
	-- needs the arena's floor plane, and the only thing that knows it is the
	-- colossus - `state.center.Y`, the plane it stands on and the plane the
	-- lava watch burns at. But the colossus is dead a second and a half after
	-- this line, and the creature that has to keep watching the hole after
	-- that is the HEART, forty thousand studs away in another room, which
	-- cannot ask. Neither can it be derived: `BossArenas.volcano.center.Y` is
	-- 0 and `meshBottom` is the mesh's bbox, not the rim path.
	--
	-- So it rides the one instance both of them can reach, written once, at the
	-- moment it is known, by the only thing that knows it. SERVER-SIDE: no
	-- client reads it, and it is NOT part of the frozen section 7.2 contract -
	-- see NOTES, it is flagged for ratification rather than assumed.
	if floorY then
		model:SetAttribute(ATTR.PY_SHAFT_FLOOR, floorY)
	end
	model:SetAttribute(ATTR.PY_CALDERA, 1)
end

-- ...AND IT CLOSES BEHIND THE FIGHT. Idempotent, and safe to call when it was
-- never opened: `BossArenaService`'s listener is level-triggered, so writing 0
-- over a 0 fires nothing.
function Fn.pyreliskCloseCaldera(islandId: string?)
	local model = Fn.pyreliskArenaModel(islandId)
	if model then
		-- BOTH, ALWAYS, AS A PAIR - see ATTR.PY_SHAFT_FLOOR's invariant. The
		-- floor is cleared FIRST so there is no instant, however short, in
		-- which the caldera reads closed while a live depth plane is still
		-- sitting on the model for a watch to pick up.
		--
		-- Clearing the floor is not tidiness. `PyreliskCaldera` going to 0 is
		-- the shaft watch's OWN gate, so a leftover plane is harmless only for
		-- as long as nobody reorders these two lines or adds a caller that
		-- clears one - and this fight has two endings already.
		model:SetAttribute(ATTR.PY_SHAFT_FLOOR, nil)
		model:SetAttribute(ATTR.PY_CALDERA, 0)
	end
end

-- THE RESCUE HAS TO STAND DOWN WHEN THE HOLE OPENS, and this is the single
-- highest-consequence line in slice 5's handoff (its section 1.1, accepted as a
-- MUST).
--
-- THE ARITHMETIC, because it is not obvious and it is what makes this fatal
-- rather than untidy. The watch fires on `K.PY_LAKE_R = 120`, and the shaft the
-- caldera opens is `K.PY_SHAFT_R = 100` - the shaft is INSIDE the lake. So on
-- the exact frame a player finally does the thing the whole act exists for -
-- jump into the open caldera - the function written to SAVE them from the lava
-- reads them as having fallen in it, and teleports them back out to
-- `K.PY_RESCUE_R = 150` on the rim path. Every time. Forever. The beat cannot
-- happen while this is running, and nothing about it looks like a bug: the
-- rescue is working perfectly, at the one moment it must not.
--
-- AND IT IS A LEVEL TEST, NOT AN EDGE. Gating on "the caldera just opened"
-- would rescue anybody who fell in a second later, which is most of a party.
function Fn.pyreliskLavaWatch(creature, def, state, now: number)
	if now < (creature.pyreliskLavaAt or 0) then
		return
	end
	if Fn.pyreliskCalderaOpen(def.islandId) then
		-- Nothing to be saved from and nowhere to be put: the lava has drained
		-- and the floor under it is gone. Falling is the POINT now.
		creature.pyreliskLavaAt = now + K.PY_LAVA_TICK
		return
	end
	creature.pyreliskLavaAt = now + K.PY_LAVA_TICK
	local center = state.center
	local lo, hi = Fn.bossRoll(creature, def, K.PY_LAVA_DAMAGE)
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid and humanoid.Health > 0 then
			local out = Vector3.new(root.Position.X - center.X, 0, root.Position.Z - center.Z)
			if out.Magnitude < K.PY_LAKE_R and root.Position.Y <= center.Y + K.PY_LAVA_HEAD then
				local burn = Vector3.new(root.Position.X, center.Y, root.Position.Z)
				fireEvent("slam", burn, { radius = 11, skin = "lava" })
				PlayerService.damage(player, math.random(lo, hi), creature, { bypassIframe = true })
				local dir = if out.Magnitude > 0.01 then out.Unit else Vector3.xAxis
				local at = center + dir * K.PY_RESCUE_R + Vector3.new(0, 4, 0)
				-- Set down facing the thing that threw them, on their own
				-- bearing out of the lake, so a rescue never spins the camera
				-- round or drops two players on the same stud.
				root.CFrame = CFrame.lookAt(at, at - dir * 10)
			end
		end
	end
end

-- One frame of the mount, run from Fn.placeColossus so it ticks in every mode
-- this boss can be in - including the collapse, which is the one exit that
-- does not pass through the stagger's own end.
function Fn.updatePyreliskMount(creature, def, state, now: number)
	-- THE GATE IS "a stagger with something planted", AND IT IS BACK TO EXACTLY
	-- THAT. It was widened to "a stagger, OR act 3" while act 3 was the climb;
	-- the climb is cut, so the act clause is gone with it and this is once
	-- again the shipped act-1 monolith mount and nothing else.
	--
	-- NO PATH RE-ENABLES MOUNTING IN ACT 2 OR LATER, and it is worth saying how
	-- that is enforced rather than trusting the gate to look right: the only
	-- other way in is a non-zero `planted`, and `Fn.pyreliskDropArms` writes
	-- `planted = 0` at the top of act 2 while the collapse writes 0 again -
	-- neither the arms nor the death plants anything. (The vent-smash minigame
	-- that used to ride this layer was retired in slice 4 and its four locals
	-- were spent elsewhere; nothing brings it back.)
	--
	-- Everything downstream is untouched: `Fn.openPyreliskMount` still builds
	-- the slabs from `PyreliskPath.climbSlabs`, `Fn.pyreliskLavaWatch` keeps
	-- its damage-and-rescue contract, and `clearPyreliskMount` still fills the
	-- forward declaration so `removeOwnedParts` and `kill` can both reach it.
	if creature.mode == "stagger" and (state.planted or 0) ~= 0 and not creature.collapsing then
		if not creature.pyreliskMount then
			Fn.openPyreliskMount(creature, state, now)
		end
		local mount = creature.pyreliskMount
		if mount then
			-- HELD STILL. Fn.placeColossus has already turned the body toward
			-- the nearest player this frame; this puts it back. Both angles,
			-- because `bearing` folds one into the other and the slabs were
			-- placed from the result.
			state.faceAngle = mount.faceAngle
			state.aimAngle = mount.aimAngle
		end
		creature.pyreliskEaseAt = nil
	elseif creature.pyreliskMount then
		Fn.shakePyreliskMount(creature, state, now)
		creature.pyreliskEaseAt = nil
	elseif creature.mode == "stagger" and not creature.collapsing then
		-- THE WEAK STAGGER, and the reason it needs its own branch: it is the
		-- one way into this window that plants NOTHING. A handfall that finds
		-- no monolith calls Fn.openStagger with `weakStagger` and leaves
		-- `planted` at 0, and Fn.openStagger nils `creature.attack` - so the
		-- handler's own `recover` never runs, and nothing else on this page
		-- had any reason to touch the rig. The strong path is cleaned up by
		-- the mount teardown above (Fn.shakePyreliskMount puts the pose down as
		-- part of packing up); the weak path had no equivalent, so the body
		-- held the handfall pose at blend 1 with the fist buried in the path
		-- for the whole 3 seconds and then snapped to rest in one frame when
		-- the next attack wrote the rig.
		--
		-- Eased rather than cleared for the same reason the mount teardown
		-- eases nothing: there the arm IS the furniture and has to go at
		-- once, here there is nothing standing on it and a colossus that
		-- snapped out of a blow it just threw reads as a dropped frame.
		-- Same three numbers Fn.shakePyreliskMount writes, spread over
		-- K.PY_WEAK_EASE.
		local last = creature.pyreliskEaseAt or now
		creature.pyreliskEaseAt = now
		local step = math.clamp((now - last) / K.PY_WEAK_EASE, 0, 1)
		state.blend = math.max((state.blend or 0) - step, 0)
		state.strike = math.max((state.strike or 0) - step, 0)
		if state.blend <= 0 and state.strike <= 0 then
			state.attack = ""
		end
	else
		creature.pyreliskEaseAt = nil
	end
	-- THE MOAT IS THE FIGHT'S MELEE GATE, AND IT IS MADE OF THIS CALL.
	--
	-- Unconditional, in every mode, for as long as the boss is alive - which
	-- is what `Fn.placeColossus` is. It used to run only while a mount was
	-- standing (plus K.PY_SHAKE_GRACE), and that left the whole premise of the
	-- fight optional: PyreliskArena_Base is authored FLAT all the way under
	-- the lava sheet (the arena's horizontal-only rule) and the sheet itself
	-- is non-collidable, so a player who walks inward past r120 is not in a
	-- hazard - they are standing on solid basalt a tenth of a stud down. From
	-- there `inRange` is 3D pivot distance minus hitRadius 96, so anywhere
	-- inside r112 melees a 40,000-HP colossus for free, and the bait, the
	-- climb, the window and the vents are all things you may skip. The lake
	-- cannot be made collidable (it is the floor the arena does not have) and
	-- the base cannot be dished without breaking the import, so the moat is
	-- enforced by DAMAGE. The watch is cheap - K.PY_LAVA_TICK throttles it to
	-- four passes a second over the player list - and it rescues rather than
	-- kills, so being wrong about someone's height costs them a set-down on
	-- the path, not a death.
	Fn.pyreliskLavaWatch(creature, def, state, now)
end

-- (`Fn.pyreliskVentSwing` and its second `Remotes.RequestAttack` listener
-- stood here until act 3 became the climb. See the note on their grave, with
-- the four constants, above `pyreliskMounts`.)

-- WHO IS IN THE SHAFT, AND WHAT ACTUALLY DELIVERS THEM.
--
-- THE FALL DOES NOT DELIVER ANYBODY. It is only the TRIGGER. The shaft's foot
-- is a hundred-odd studs below a rim path that is itself 292 studs up, and the
-- heart's chamber is forty thousand studs away and six hundred studs in the
-- air - there is no geometry connecting them and there was never going to be.
-- What moves a player is `CreatureService.ArenaMove`, per player, fired from
-- here the moment they are far enough down the hole to have meant it. The fall
-- is the fiction; the ArenaMove is the mechanism.
--
-- (And a fall this watch MISSES does not land anywhere good: the shaft is
-- authored walls-only, so an uncaught player continues past its foot to the
-- sea, ~170 studs further, in open ocean 23,400 studs from anywhere. There is
-- no fall damage anywhere in `src/` so they live, but they are lost. That is
-- why the poll is cheap enough to run every half second and why the grace
-- below exists at all - slice 5's handoff section 2.7 asks for a floor or an
-- earlier trigger, and both are the mesh lane's.)
--
-- PER PLAYER, NOT PER PARTY, because the directive's beat is "you have to like
-- jump in" and a yank makes the jump a cutscene. `ArenaMove`'s third argument
-- moves exactly one participant; the party form is the grace, below.
function Fn.pyreliskShaftWatch(creature, def, now: number)
	if now < (creature.pyreliskShaftAt or 0) then
		return
	end
	creature.pyreliskShaftAt = now + K.PY_SHAFT_TICK
	if not Fn.pyreliskCalderaOpen(def.islandId) then
		return
	end
	local centre = BossArenas.centerFor(def.islandId)
	local model = Fn.pyreliskArenaModel(def.islandId)
	local floor = model and model:GetAttribute(ATTR.PY_SHAFT_FLOOR)
	-- A NIL FLOOR MEANS "NO CALDERA HAS OPENED IN THIS FIGHT" AND THE WATCH DOES
	-- NOT RUN. It is the second half of the pair invariant (ATTR.PY_SHAFT_FLOOR)
	-- read back: the plane is written with the caldera and cleared with it, so
	-- its absence is the same statement as `PyreliskCaldera ~= 1` and the watch
	-- refuses on either.
	--
	-- BELT AND BRACES ON PURPOSE. The caldera gate above already returned for a
	-- closed hole, so reaching here with no floor means the two attributes have
	-- come apart - which is the one state the invariant forbids. Refusing is
	-- the safe reading: the alternative is a depth test against a nil or a
	-- stale plane, which either throws or silently teleports a party out of an
	-- act-1 fight.
	--
	-- `type(floor) ~= "number"` rather than `floor == nil`, because an
	-- attribute is whatever was last written to it and a wrong-typed value must
	-- fail the same way a missing one does.
	if centre == nil or type(floor) ~= "number" then
		return
	end
	-- THE BACKSTOP, FIRST, and it is a level test on a deadline rather than a
	-- one-shot: nobody may be left on a summit whose boss has gone, so once the
	-- grace is spent the whole remaining party is taken in the party form -
	-- which is the Kraken's swallow, used as the net instead of as the beat.
	-- `ArenaMove`'s party form already skips anyone standing in the
	-- destination, so this cannot drag people out of the fight they are already
	-- in and put them back on the entry pad.
	if now >= (creature.pyreliskShaftGraceAt or math.huge) then
		creature.pyreliskShaftGraceAt = nil
		CreatureService.ArenaMove:Fire(def.islandId, K.PY_HEART_BOSS)
		return
	end
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid and humanoid.Health > 0 then
			local out = Vector3.new(root.Position.X - centre.X, 0, root.Position.Z - centre.Z)
			-- Inside the hole's own column AND far enough down it. Both terms
			-- are needed: the radius alone is the whole middle of the arena
			-- (people stand there), and the depth alone is anywhere off the
			-- lip.
			if out.Magnitude < K.PY_SHAFT_R and root.Position.Y <= floor - K.PY_SHAFT_DROP then
				-- Participation is BossService's to judge - it tests by UserId
				-- and refuses a player who is not in this fight, which is the
				-- right ruling: "whoever is standing in the shaft" is not the
				-- same set as "whoever is in the fight", and a passer-by has no
				-- ride home out of a sealed room.
				CreatureService.ArenaMove:Fire(def.islandId, K.PY_HEART_BOSS, player)
			end
		end
	end
end

-- ------------------------------------------------------------ act 4: the heart
--
-- A DIFFERENT ROW, A DIFFERENT ROOM, THE SAME FIGHT. `succeededBy` hands the
-- colossus's death to `pyrelisk_heart`, which `BossService.handoff` raises in
-- the heart arena carrying the party's `healthMult` across; `heartAs` makes the
-- win mint `Heart_pyrelisk`, so the Kraken's gate opens for anyone who beat
-- this. Everything below is what the room does while you are in it.

-- The six wall vents, in world. Authored on the arena row as FULL XYZ - they
-- are at three different heights and the height is the point - and resolved
-- against the arena centre, which is the `sockets` convention with the Y term
-- kept instead of flattened.
--
-- WHICH ONES SPEAK, and it is weighted AWAY from the one that spoke last so the
-- pressure rotates round the wall rather than settling on whoever is unlucky.
-- Six vents at three heights is a room that shoots from everywhere; six vents
-- that all pick randomly is a room that shoots from the same place twice in a
-- row often enough to read as aimed.
function Fn.pyreliskHeartVents(creature, count: number): { Vector3 }
	local arena = BossArenas.items[K.PY_HEART_BOSS]
	local vents = arena and arena.vents
	local out = {}
	if not vents or #vents == 0 then
		-- No authored vents is a room with no shooters, which reads in play as
		-- "the heart does nothing" rather than as a missing table.
		warn(
			string.format(
				"[CreatureService] BossArenas.%s has no `vents` - the heart room has no shooters and "
					.. "`ventspit` will throw nothing",
				K.PY_HEART_BOSS
			)
		)
		return out
	end
	local centre = creature.anchor or creature.pos
	local last = creature.pyreliskLastVent
	local pool = {}
	for i = 1, #vents do
		if i ~= last or #vents < 2 then
			table.insert(pool, i)
		end
	end
	for _ = 1, math.min(count, #pool) do
		local at = math.random(#pool)
		local index = table.remove(pool, at)
		creature.pyreliskLastVent = index
		table.insert(out, centre + vents[index])
	end
	return out
end

-- WHERE A GLOB LANDS: marked ground, scattered around the party's own footing
-- and pulled back inside the room.
--
-- The clamp is `pyreliskLatch`'s rule in a circle instead of a band - a glob
-- that lands past the wall is a glob nobody could have been standing under, and
-- the floor's own radius is the only honest bound on it.
function Fn.pyreliskHeartGround(creature, p, root): Vector3
	local arena = BossArenas.items[K.PY_HEART_BOSS]
	local centre = creature.anchor or creature.pos
	local far = (arena and arena.floorRadius or 96) - (p.radius or 12)
	local at = if root then root.Position else centre
	local theta = math.random() * math.pi * 2
	local spread = math.sqrt(math.random()) * (p.spread or 20)
	at = Vector3.new(at.X + math.cos(theta) * spread, centre.Y, at.Z + math.sin(theta) * spread)
	local out = Vector3.new(at.X - centre.X, 0, at.Z - centre.Z)
	local reach = out.Magnitude
	if reach > far and reach > 0.01 then
		at = centre + (out / reach) * far
	end
	return Vector3.new(at.X, centre.Y, at.Z)
end

-- VENTSPIT: two to four wall vents throw globs at marked ground. The room's
-- bread and butter, and it is ZERO new projectile code - `Fn.throwGlob` has
-- always taken an arbitrary origin (the Kraken's `inkmortar` passes the eye
-- that threw it), so six shooters are six origins and nothing else.
--
-- NOT `ProjectileService`. Its volleys hardcode the flight plane as
-- `World.WATER_Y + FLIGHT_Y`, and this room is six hundred studs up - every
-- ball would fly flat through the sea underneath it, invisibly, hitting nobody.
-- Design flag F-12; the fix is one line plus a client contract field and it is
-- out of scope here.
K.ATTACK_HANDLERS.ventspit = {
	fire = function(creature, def, p, now, root)
		for i, vent in Fn.pyreliskHeartVents(creature, p.count or 3) do
			local at = Fn.pyreliskHeartGround(creature, p, root)
			local flight = (p.flight or 1.6) + (i - 1) * (p.stagger or 0.2)
			-- The disc at the impact site for exactly the flight time - the
			-- `krakenmortar` rule: a mark that outlives its glob is a lie about
			-- where the floor is dangerous.
			fireEvent("telegraph", at, { kind = "mark", duration = flight, radius = p.radius, skin = p.skin })
			Fn.throwGlob(creature, def, p, at, flight, now, "strikeHit", "spit", {
				tolerance = K.BOSS_HEIGHT_TOLERANCE,
				pool = p.pool,
			}, vent)
		end
	end,
}

-- HEARTPULSE: the heart beats and a ring goes out from the dais. Safe at the
-- middle and safe at the wall; the ring is the space between.
--
-- THE METRONOME THE PILLARS TIGHTEN. Its cooldown is stepped by
-- `creature.cooldownStep` like everything else the heart casts, so the beat
-- literally speeds up as the room's cover comes down.
K.ATTACK_HANDLERS.heartpulse = {
	fire = function(creature, def, p, now)
		local centre = creature.anchor or creature.pos
		local arm = p.arm or 1.2
		Fn.queueStrike(creature, def, p, centre, now, now + arm, {
			shape = "annulus",
			inner = p.inner or 26,
			outer = p.radius or 84,
		})
	end,
}

-- MAGMARAIN: the ceiling sheds on everybody at once. The shipped `barrage`
-- `everyone` pattern, unchanged - `ashfall`'s shape in a smaller room.
K.ATTACK_HANDLERS.magmarain = {
	fire = function(creature, def, p, now, root)
		local base = K.ATTACK_HANDLERS.barrage.fire
		if base then
			base(creature, def, p, now, root)
		end
	end,
}

-- VENTBARRAGE: phase two only. All six vents at once, one glob each, NO AIM -
-- a wall of falling rock you walk out of rather than a thing pointed at you.
-- Scattered on the floor rather than on the party, which is what makes it
-- readable: the answer is "be somewhere else", and there is always a somewhere.
K.ATTACK_HANDLERS.ventbarrage = {
	fire = function(creature, def, p, now)
		local arena = BossArenas.items[K.PY_HEART_BOSS]
		local centre = creature.anchor or creature.pos
		local far = (arena and arena.floorRadius or 96) - (p.radius or 12)
		for i, vent in Fn.pyreliskHeartVents(creature, p.count or 6) do
			local theta = math.random() * math.pi * 2
			local reach = math.sqrt(math.random()) * math.max(far, 1)
			local at = centre + Vector3.new(math.cos(theta) * reach, 0, math.sin(theta) * reach)
			local flight = (p.flight or 2.0) + (i - 1) * (p.stagger or 0.12)
			fireEvent("telegraph", at, { kind = "mark", duration = flight, radius = p.radius, skin = p.skin })
			Fn.throwGlob(creature, def, p, at, flight, now, "strikeHit", "spit", {
				tolerance = K.BOSS_HEIGHT_TOLERANCE,
			}, vent)
		end
	end,
}

-- THE HEART'S OWN FRAME, called at the top of `Fn.updateBoss` for this row and
-- nowhere else, the way `Fn.updateKrakenFight` is - BEFORE the mode dispatch, so
-- a heart that is busy attacking still counts its pillars.
--
-- Everything it does is a LEVEL published off the world: which act this is, how
-- many pillars still stand, and how fast the room is therefore beating. Nothing
-- here is an edge, so a client that adopts the model at any instant draws the
-- right room.
-- `def` again, not `_def`: slice 6 underscored it because the heart's frame
-- genuinely had no use for the row, and the shaft watch below now does.
function Fn.updatePyreliskHeart(creature, def, now: number)
	if creature.row.boss ~= K.PY_HEART_BOSS then
		return
	end
	-- THE LAST ACT, ON THE HEART'S OWN MODEL. The same attribute name the
	-- colossus carries 1-2 on, which is the whole point of it: one name, one
	-- meaning ("which act of the Pyrelisk fight is this model drawing"),
	-- monotonic across a handoff that swaps the model underneath it. The client
	-- gates rig-drawing on THIS rather than on position, or the exterior
	-- colossus rig draws inside the chamber.
	--
	-- `K.PY_ACT_HEART` AND NOT A LITERAL. It was 4 while the arm climb held 3;
	-- the climb is cut and the heart moved up, and the one thing that must not
	-- happen again is a renumber that leaves one literal behind in a branch
	-- nobody runs until the fight's last minute.
	if creature.pyreliskAct ~= K.PY_ACT_HEART then
		creature.pyreliskAct = K.PY_ACT_HEART
		creature.model:SetAttribute(ATTR.PY_ACT, K.PY_ACT_HEART)
	end
	if creature.collapsing or creature.dead then
		return
	end
	-- THE HOLE IS STILL OPEN AND SOMEBODY IS STILL FALLING DOWN IT.
	--
	-- The colossus ran this for the last second and a half of its own fall and
	-- is then destroyed - `Fn.updateBoss` is not called for a dead creature -
	-- so from the handoff onward the only live thing that can keep watching the
	-- shaft is the heart the fall is delivering people TO. Same function, same
	-- arena (`def.islandId` is "volcano" on this row too, deliberately), same
	-- per-player ArenaMove.
	--
	-- Its own grace clock starts on the heart's first frame rather than being
	-- carried across: the colossus's deadline died with it, and the number that
	-- matters is "how long after the room existed was somebody still not in it".
	if creature.pyreliskShaftGraceAt == nil then
		creature.pyreliskShaftGraceAt = now + K.PY_SHAFT_GRACE
	end
	Fn.pyreliskShaftWatch(creature, def, now)
	-- THE EIGHT, RECONCILED OFF THE WORLD - the idiom acts 2 and 3 both use,
	-- and for the same reasons: a pillar that died to a pool tick, a collapse
	-- or a despawn counts exactly once and counts the same, and `kill()` stays
	-- free of this fight's machinery.
	-- `socketIndex` RATHER THAN A FIELD OF MY OWN. `Fn.spawnBossParts` already
	-- stamps it - entry `i` IS socket index `i`, which is the number the client
	-- claims a part by - and the heart's only parts are these eight, so a
	-- second per-pillar field would be the same integer written twice. Bounded
	-- against the mask's width, because a socket list that grew past eight is
	-- exactly the silent failure a bitmask has.
	local mask = 0
	for _, other in creatures do
		local index = other.partOf == creature and not other.dead and other.socketIndex
		if index and index >= 1 and index <= K.PY_PILLAR_COUNT then
			mask = bit32.bor(mask, bit32.lshift(1, index - 1))
		end
	end
	local was = creature.pyreliskPillarMask
	if was == nil or mask ~= was then
		local arena = BossArenas.items[K.PY_HEART_BOSS]
		local sockets = arena and arena.sockets
		for i = 1, K.PY_PILLAR_COUNT do
			local bit = bit32.lshift(1, i - 1)
			if was and bit32.band(was, bit) ~= 0 and bit32.band(mask, bit) == 0 then
				-- A BROKEN PILLAR VENTS AT ITS OWN FOOT, permanently. The room
				-- gets smaller as its cover comes down, which is the same
				-- bargain the arms and the arm rocks make: the reward for
				-- progress is a harder floor, and it is the only reward
				-- structure a fight with no punish window can offer.
				local socket = sockets and sockets[i]
				if socket then
					local at = (creature.anchor or creature.pos) + Vector3.new(socket.X, 0, socket.Z)
					spawnPool(creature, at, K.PY_PILLAR_POOL, now)
					fireEvent("slam", at, { radius = K.PY_PILLAR_POOL.radius, skin = "lava" })
				end
			end
		end
		creature.pyreliskPillarMask = mask
		creature.model:SetAttribute(ATTR.PY_PILLARS, mask)
		-- ...AND THE ROOM TIGHTENS. Counted from the mask rather than kept as a
		-- tally, so it cannot drift from what is actually standing.
		local down = 0
		for i = 1, K.PY_PILLAR_COUNT do
			if bit32.band(mask, bit32.lshift(1, i - 1)) == 0 then
				down += 1
			end
		end
		creature.cooldownStep = K.PY_PILLAR_STEP ^ down
	end
end

-- THE RETURN PATH, and it is the ONLY place this fight can answer its own
-- death: `Fn.updateBoss` is not called for a creature that is already dead, so
-- the recall out of a sealed room 40,000 studs from the island has nowhere else
-- to live. `kill()` runs `gimmick.onKill` while `pos` still means something and
-- before Killed pays anyone out, which is exactly the beat wanted.
--
-- BossService deliberately adds NO second recall - its own comment says why:
-- `onKilled` delays `sendHome` by `RETURN_DELAY`, and a recall racing that
-- delay that lost the race would silently take nobody anywhere, because
-- `sendHome`'s proximity filter excludes precisely the people it failed to move.
K.GIMMICKS.pyreliskheart = {
	onKill = function(creature)
		fireEvent("krakenCollapse", creature.pos, { duration = 3.0 })
		-- The fight's centre stops being a room nobody is in any more, so the
		-- abandon reaper and `sendHome` stop measuring presence against it.
		creature.model:SetAttribute(ATTR.FIGHT_CENTER, nil)
		local def = bossDef(creature)
		if def and def.islandId then
			-- CLOSE THE CALDERA BEHIND YOU, BEFORE THE RECALL. The party is
			-- about to be set back down on the Ashfall Throne's rim path, and
			-- that path currently has a 120-stud hole in the middle of it with
			-- no lake floor under it. `PyreliskCaldera` lives on the ARENA
			-- model, so it survives the boss that opened it and would still be
			-- 1 at the next summon: an act-1 fight whose moat is a shaft.
			--
			-- Level-triggered and idempotent on the far side, so writing 0 when
			-- it was never opened costs nothing.
			--
			-- THROUGH THE RESOLVER, which takes the instance name off the arena
			-- row (`arena.model`) rather than spelling "PyreliskArena" here.
			-- The name is a contract with `BossArenaService` - it warns at
			-- startup when the placed group does not carry it - and a second
			-- hand-typed copy of it in this file is the half of that contract
			-- nothing would ever check.
			--
			-- REDUNDANT WITH `removeOwnedParts`, DELIBERATELY. That is the
			-- catch-all for every way this fight can end; this one is here for
			-- ORDER, because the caldera has to be shut before the recall puts
			-- the party back on a rim path that currently has a hole in it.
			Fn.pyreliskCloseCaldera(def.islandId)
			CreatureService.ArenaMove:Fire(def.islandId, def.islandId)
		end
	end,
}

-- ------------------------------------------------ the colossus's four acts
--
-- Everything from here to the choir is the Pyrelisk's act machine, and the
-- whole of it is fields on `Fn` - `CreatureService.luau` is at Luau's 200-local
-- chunk limit and a new top-level `local` here does not fail a gate, it stops
-- the server booting (2026-09-06).
--
-- THE STATE OF THIS FIGHT IS NOT A PHASE FIELD. It is the health bar, which
-- `Fn.pyreliskChip` turns; `creature.partsAlive`, which the shipped parts ring
-- counts; and `state.seamsBroken`, which the shipped seam system sets. The one
-- new attribute (`ATTR.PY_ACT`) is a STATEMENT FOR THE CLIENT about those
-- three, published as a level, never an edge.

-- Take an exact fraction off the dial and republish it.
--
-- THE ONE NEW PRIMITIVE THE WHOLE REDESIGN TURNS ON, and it is the vent
-- smash's existing arithmetic (`creature.maxHealth * fraction`) lifted into a
-- name so every milestone shares it instead of each one open-coding the same
-- subtraction against a different rounding.
--
-- IT DOES NOT GO THROUGH `damage()`, and that is not an optimisation. In act 1
-- the colossus is `untargetable`, so `damage()` returns nil and the chip would
-- be silently swallowed - the exact failure shape this repo is made of: a
-- value needed somewhere it is never read, presenting as "the boss's bar never
-- moves". It writes the health line and the attribute the same way `damage()`
-- does, and it FLOORS rather than killing, because the death path is
-- `beginBossCollapse`'s and a chip may not enter it by arithmetic.
function Fn.pyreliskChip(creature, _def, fraction: number)
	if not creature or creature.dead or fraction <= 0 then
		return
	end
	local chunk = creature.maxHealth * fraction
	creature.health = math.max(K.PY_CHIP_FLOOR, creature.health - chunk)
	creature.model:SetAttribute(ATTR.HEALTH, creature.health)
	-- The stance line on the boss's own tick reads the health fraction on the
	-- very next frame, so the act banner follows from here with no second path.
	return creature.health
end

-- HAVE WE EVER PAID FOR THIS FLANK? A two-bit mask on the CREATURE RECORD,
-- deliberately not on `state.seamsBroken`: the scar mask is the client's
-- contract and must not grow a second meaning, and this one is the server's
-- private ledger of which 0.15 chips have been spent.
--
-- WHY THE CHIP IS PAID ON THE SCAR'S 0 -> 1 TRANSITION AND NOT ON THE METER
-- FILLING. The 120-second failure branch clears the meters and lets a party
-- re-fill one. Paid on meter-full, a second fill would chip a second 0.15 and
-- the dial would walk down through 0.55, 0.40, 0.25 on cycles that were
-- supposed to cost nothing but time - firing a stance banner and swapping the
-- attack pool in the middle of act 1, silently. Paid on the transition, health
-- is PINNED at exactly 0.70 for every cycle after the first, which is what
-- makes "a second cycle is strictly cheaper, and nothing resets" true rather
-- than aspirational. At most twice in the life of a fight, ever.
function Fn.pyreliskFlankBit(side: number): number
	return if side < 0 then 2 else 1
end

function Fn.pyreliskFlankPaid(creature, side: number): boolean
	return bit32.band(creature.pyreliskFlanksPaid or 0, Fn.pyreliskFlankBit(side)) ~= 0
end

function Fn.pyreliskMarkFlankPaid(creature, side: number)
	creature.pyreliskFlanksPaid = bit32.bor(creature.pyreliskFlanksPaid or 0, Fn.pyreliskFlankBit(side))
end

-- Both flanks scarred. A LEVEL TEST on the monotonic mask, and the drop gate
-- below is deliberately this and not "the pair just completed": that edge
-- happens once and can never happen again, so a party that lost the first
-- window would have no way back into act 2 at all. See `Fn.pyreliskDropArms`.
function Fn.pyreliskBothFlanksBroken(state): boolean
	local broken = state.seamsBroken or 0
	return bit32.band(broken, K.PY_SEAM_MASK_L) ~= 0 and bit32.band(broken, K.PY_SEAM_MASK_R) ~= 0
end

-- Which flank has NOT scarred yet, or nil when neither or both have. The
-- scarred-flank preference: a colossus that has lost the use of an arm
-- visibly stops swinging it, which is the reward for breaking a flank.
function Fn.pyreliskUnscarredSide(state): number?
	local broken = state.seamsBroken or 0
	local left = bit32.band(broken, K.PY_SEAM_MASK_L) ~= 0
	local right = bit32.band(broken, K.PY_SEAM_MASK_R) ~= 0
	if left == right then
		return nil
	end
	return if left then -1 else 1
end

-- The act, as a level on the model. One place, so nothing can publish half of
-- it, and `creature.pyreliskAct` is the server's own copy for the branches
-- that would otherwise have to read an attribute back.
function Fn.pyreliskPublishAct(creature, act: number)
	if creature.pyreliskAct == act then
		return
	end
	creature.pyreliskAct = act
	creature.model:SetAttribute(ATTR.PY_ACT, act)
	-- ...AND INTO THE POSE STATE, which is the half the rig reads.
	--
	-- `PyreliskPath` is required by BOTH sides, and `state.act` is how it
	-- learns which act it is drawing without either side inventing its own
	-- answer: the server writes it here, the client's `colossusState` round
	-- trip carries the same number, and both compute the pose from one field.
	--
	-- IT IS ALSO THE PROSTRATE FLAG. The body goes down at the top of act 2
	-- and stays down through act 3, and "down" cannot ride `state.attack` -
	-- that field is the CURRENT ATTACK's pose, and act 3's colossus still
	-- casts. `act >= 2` is the level that means prostrate, and it is the same
	-- condition the path module's hard freeze of `bearing` / `breath` / `lean`
	-- is written against (design F-14, the mesh lane's, slice 2). Publishing it
	-- here is what lets that land without a second wire.
	local state = creature.pose
	if state then
		state.act = act
	end
end

-- Each arm's bar, every frame of act 2, and NIL WHEN THERE IS NO ARM. A HUD
-- that cannot tell "no arm" from "a dead arm" draws an empty bar for a limb
-- that was never there.
function Fn.pyreliskArmBars(creature)
	local left, right = nil, nil
	for _, other in creatures do
		if other.partOf == creature and not other.dead and other.pyreliskSide then
			local frac = math.clamp(other.health / math.max(other.maxHealth, 1), 0, 1)
			if other.pyreliskSide < 0 then
				right = frac
			else
				left = frac
			end
		end
	end
	-- (`creature.pyreliskLastArmSide` was recorded here - "the arm that was
	-- alone at the end is the one the second death leaves, and that one is the
	-- climb ramp". There is no ramp now: the cut of act 3 means NOTHING is ever
	-- planted after the arms come down, `ATTR.PLANTED` stays 0 from
	-- `Fn.pyreliskDropArms` through the collapse, and which flank died last is
	-- not a question anything asks.)
	creature.model:SetAttribute(ATTR.PY_ARM_L, left)
	creature.model:SetAttribute(ATTR.PY_ARM_R, right)
end

-- Plant one arm. The SINGLE-PART form of `Fn.spawnBossParts` (the shape
-- `Fn.plantKrakenArm` uses), and it is that rather than `parts.at = "mounts"`
-- on purpose: a mounts list cannot express "mirrored by flank", and it would
-- be a second copy of geometry `PyreliskPath` already owns, to be got wrong
-- separately. That is the mirrored-monolith bug with a different set of
-- numbers, and this fight has had it once already.
--
-- WHERE IT LANDS. `PyreliskPath.armJoints(state, side).fist`, through the live
-- pose - so the day the `fallen` pose exists the arms land where the drawn
-- limb lies, with no number pasted anywhere.
--
-- THE BAND CLAMP IS A RAIL, NOT THE RULE, in `pyreliskLatch`'s sense. The
-- `fallen` pose is not built yet (it is the mesh lane's slice 2, design flag
-- F-4/F-7), so today's idle pose can put a fist somewhere nobody can shoot it
-- from. The clamp drags the plant back onto the rim path and SAYS SO, loudly,
-- on the first drop - so a pose retune that walks out of the band is a warning
-- on the first swing rather than two arms quietly parked in the lava.
function Fn.pyreliskPlantArm(creature, row, state, side: number, now: number)
	local at = PyreliskPath.armJoints(state, side).fist
	local centre = state.center
	local out = Vector3.new(at.X - centre.X, 0, at.Z - centre.Z)
	local reach = out.Magnitude
	-- THE ARM LIES ALONG A CHORD, NOT DOWN A RADIUS, and this clamp is the one
	-- place in the Pyrelisk server code that talks in radii at all. It survives
	-- the distinction because it is CONTAINMENT, not placement: it asks only
	-- "is this point on the walkable annulus", which is a true question about
	-- any point however the limb got there, and it moves nothing that already
	-- is. Measured against the fallen pose the fist sits at r 192.00, inside
	-- [130, 222], so it is inert and the warn below does not fire.
	--
	-- What it must never become is a DERIVATION - "the arm runs from r X to
	-- r Y, so place things along that line". The joints sweep 46.6 degrees of
	-- bearing from fist to shoulder; a radial line through them is not the arm
	-- and nothing may be placed on one. The rocks come from
	-- `PyreliskPath.armRocks` and the crownshed landings from the route's own
	-- plates, both for this reason.
	local near, far = K.PY_LAKE_R + 10, K.PY_PATH_OUT - 10
	if reach < 0.01 then
		out, reach = Vector3.new(1, 0, 0), 1
	end
	local want = math.clamp(reach, near, far)
	if math.abs(want - reach) > 0.5 then
		warn(
			string.format(
				"[Pyrelisk] the fallen pose puts flank %d's fist at r %.1f, outside the rim path's "
					.. "[%.0f, %.0f] - clamped to %.1f, so the arm is not lying where the client draws it. "
					.. "Re-derive the fallen pose (design F-4/F-7) rather than widening this band.",
				side,
				reach,
				near,
				far,
				want
			)
		)
	end
	at = centre + (out / reach) * want
	local model = CreatureService.spawn(row, at, nil, "Neutral", {
		noLinger = true,
		suppressDrops = true,
		bounty = 0.5,
		-- The party's factor, the same one the generic ring reads. The arms
		-- ARE the wall in act 2; a solo-sized wall would make the act easier
		-- per head as the party grew, which is backwards.
		healthMult = Fn.partyMult(creature),
	})
	local part = byModel[model]
	if not part then
		return nil
	end
	part.partOf = creature
	-- `socketIndex` so the generic machinery (and any client claiming an arm)
	-- can name it; `pyreliskSide` is the flank, which is what act 3 needs to
	-- know when it asks which arm was the second to die.
	part.socketIndex = Fn.pyreliskFlankBit(side)
	part.pyreliskSide = side
	part.pos = at
	model:PivotTo(restCFrame(part))
	model:SetAttribute(ATTR.SOCKET_INDEX, part.socketIndex)
	if creature.row.vulnerableWhen == "partsDown" then
		model:SetAttribute(ATTR.WEAKPOINT, true)
	end
	part.pyreliskPoolAt = now + randomBetween(2.0, K.PY_ARM_POOL_GAP)
	creature.partsAlive = (creature.partsAlive or 0) + 1
	return part
end

-- ACT 2 BEGINS. Both arms crash across the moat onto the rim path and become
-- two creatures; the colossus does nothing at all for as long as they stand.
--
-- ONE CALL SITE AND ONE GUARD, and neither of them is an edge - see the seam
-- cash-out in `Fn.updateBoss`.
function Fn.pyreliskDropArms(creature, def, now: number)
	local row = def.parts and Creatures.items[def.parts.row]
	if not row then
		warn(string.format("[CreatureService] boss %q has no arm row - act 2 cannot begin", def.id))
		return
	end
	local state = Fn.colossusState(creature, def)
	creature.pyreliskArmsOut = true
	-- NEITHER ARM IS THE RAMP YET: both are down, and `Planted` means "which
	-- flank is the climb ramp", which is act 3's question and not this act's.
	state.planted = 0
	creature.model:SetAttribute(ATTR.PLANTED, 0)
	creature.partsAlive = 0
	creature.partsDownAt = nil
	Fn.pyreliskPlantArm(creature, row, state, 1, now)
	Fn.pyreliskPlantArm(creature, row, state, -1, now)
	creature.pyreliskArmsLive = creature.partsAlive
	Fn.pyreliskArmBars(creature)
	Fn.pyreliskPublishAct(creature, 2)
	-- The shipped window, with its per-source duration used for what it is
	-- for. `Fn.openStagger` is also the retirement path - it stamps the running
	-- attack's cooldown and nils `creature.attack` - so a meter that fills
	-- mid-swing retires that swing with no second retirement path anywhere.
	Fn.openStagger(creature, def, now, K.PY_ARM_WINDOW)
	fireEvent("bossStance", creature.pos, { name = def.name, stance = 2 })
end

-- THE FAILURE BRANCH, AND IT IS NOT A RESET. The window ran out with the arms
-- still standing: they go off the board with no kill and no loot
-- (`Fn.krakenRetireArm`'s idiom), the colossus stands back up, and the fight
-- returns to act 1.
--
-- WHAT SURVIVES A FAILED CYCLE: `state.seamsBroken` (untouched - the mask is
-- documented monotonic and this design does not break that, so the scars
-- accumulate visibly across cycles) and `creature.pyreliskFlanksPaid` (so the
-- 0.15s are never paid twice, and health is PINNED at exactly 0.70 for every
-- cycle after the first).
--
-- WHAT DOES NOT: the two meters, and the re-arm latch. With both flanks
-- already scarred the drop gate is a LEVEL test, so the next meter to fill
-- brings the arms back - re-entry costs ONE meter, not two, which is the right
-- price for a retry and is why the meters are cleared rather than left full.
function Fn.pyreliskArmsRetire(creature)
	for _, other in creatures do
		if other.partOf == creature and not other.dead and other.pyreliskSide then
			other.dead = true
			other.partOf = nil
			byModel[other.model] = nil
			if other.model.Parent then
				other.model:Destroy()
			end
			-- `Fn.krakenRetireArm`'s own bookkeeping, for the same reason it
			-- has it: the update loop is iterating `creatures` right now, so a
			-- removal is only safe when it is not.
			if not updating then
				local index = table.find(creatures, other)
				if index then
					removeAt(index)
				end
			end
		end
	end
	creature.partsAlive = 0
	creature.partsDownAt = nil
	creature.pyreliskArmsLive = 0
end

function Fn.pyreliskArmsFailed(creature, def, now: number)
	local state = Fn.colossusState(creature, def)
	Fn.pyreliskArmsRetire(creature)
	creature.pyreliskArmsOut = nil
	state.seamMeterL = 0
	state.seamMeterR = 0
	creature.seamBreakSide = nil
	state.planted = 0
	state.slump = 0
	creature.model:SetAttribute(ATTR.PLANTED, 0)
	creature.model:SetAttribute(ATTR.PY_ARM_L, nil)
	creature.model:SetAttribute(ATTR.PY_ARM_R, nil)
	creature.model:SetAttribute(ATTR.EXPOSED, nil)
	creature.untargetable = def.chip == nil
	Fn.pyreliskPublishAct(creature, 1)
	creature.nextAttackAt = now + 2.0
	setMode(creature, "entrenched", 0, now)
	fireEvent("bossStance", creature.pos, { name = def.name, stance = 3 })
end

-- BOTH ARMS DEAD: THE END OF THE FIGHT ON THE SUMMIT, and it is one-way.
-- `creature.pyreliskArmsOut` is deliberately LEFT SET - the re-cycle gate
-- reads it, and nothing gives the arms back.
--
-- THIS IS THE CUT (2026-09-12, the directive: "maybe after the first phase it
-- just goes straight into the volcano and we move into that"). There used to be
-- an act 3 here - the ramp, the six rocks, the neck core - and the second arm's
-- death merely chipped the dial to 0.30 and published act 3. Now the second
-- arm's death IS the death: the tick's arm reconciliation has already taken the
-- last 0.35 (floored at `K.PY_CHIP_FLOOR`, because a chip may never enter the
-- death path by arithmetic), and this takes the body down.
--
-- THE ROUTE IS THE NECK CORE'S, LINE FOR LINE, because it is the route the
-- caldera hangs off: `damage()` with `ignoreUntargetable` lands on the
-- zero-health branch, which calls `beginBossCollapse`, which holds the death
-- open for `collapseFor` (4.0) while `Fn.updateBossCollapse`'s pyrelisk branch
-- drives the `collapse` pose, opens the caldera at `K.PY_CALDERA_AT` (2.5) and
-- starts `Fn.pyreliskShaftWatch`. Then `kill()`, then BossService's rewards and
-- the handoff to the heart. NOT A CHIP, for the same reason the core's kill was
-- not one.
--
-- NO KILLER, AND THE PARTICIPANT SET IS WHY THAT IS RIGHT rather than merely
-- tolerable. The generic parts path knows who broke the second arm and this
-- reconciliation deliberately does not hook it: the payout is the FIGHT's
-- participant set, which BossService built at summon and which every other boss
-- death in the project pays from - so nobody loses a reward and the credit is
-- identical to the one the core's death produced. Only `deathBlow` is nil, and
-- the one thing that reads it is the collapse's own hand-back to `kill()`.
--
-- THE ACT STAYS 2 THROUGH THE FALL, and that is the F-14 freeze: the mesh
-- lane's pin on `bearing` / `breath` / `lean` is keyed on "planted ~= 0 OR
-- act >= 2", the body is already prostrate from the top of act 2, and the
-- fallen pose IS the collapse (their side, confirmed). Publishing a 3 here
-- would be a claim that the model is drawing the heart's act, which it is not -
-- the heart writes `K.PY_ACT_HEART` on its own model, and nothing writes an act
-- on this one again.
--
-- `state.planted` IS NOT WRITTEN. There is no ramp; act 2 left it at 0 and the
-- collapse clears it to 0 in any case.
function Fn.pyreliskArmsDone(creature, def, now: number)
	local state = Fn.colossusState(creature, def)
	creature.pyreliskArmsLive = 0
	state.slump = 0
	creature.model:SetAttribute(ATTR.PY_ARM_L, nil)
	creature.model:SetAttribute(ATTR.PY_ARM_R, nil)
	creature.model:SetAttribute(ATTR.EXPOSED, nil)
	-- THE BODY IS UNTOUCHABLE AGAIN for the one frame before the collapse takes
	-- it (`beginBossCollapse` sets it too). Kept because the death below is not
	-- guaranteed to be reached by a future edit and a colossus left standing in
	-- an expired stagger must not also be free to melee.
	creature.untargetable = def.chip == nil
	-- ...AND SO IS THE MODE, for the same reason: a stagger that has been left
	-- behind by the act it belonged to is the one state the shaping below
	-- cannot read. Written BEFORE the death so the collapse's own `setMode`
	-- wins, and so the failure mode of a death that does not happen is "it
	-- stands back up" rather than "it loops the window forever".
	creature.nextAttackAt = now + 1.2
	setMode(creature, "entrenched", 0, now)
	CreatureService.damage(creature, creature.health, nil, { ignoreUntargetable = true })
end

-- (ACT 3's HELPERS STOOD HERE AND ARE CUT (2026-09-12). Eight functions, in
-- this order: `Fn.pyreliskRampPlates` and `Fn.pyreliskRampPoints` (the climb
-- route's arm plates and the banded landings along them, used only by
-- `crownshed`), `Fn.pyreliskVentHazard` (the three back vents on a clock),
-- `Fn.pyreliskRockPoints` and `Fn.pyreliskCorePoint` (the placement read into
-- `PyreliskPath.armRocks` / `.neckCorePoint`, both of which the mesh lane has
-- since DELETED - so these two could not be left behind even if someone wanted
-- them), `Fn.pyreliskPlantPart`,
-- `Fn.pyreliskPlantRocks` (the seven) and `Fn.pyreliskCoreBroken` (the death
-- the core used to trigger, which `Fn.pyreliskArmsDone` now triggers itself by
-- the same route).
--
-- `Fn.pyreliskPlantArm` IS NOT ONE OF THEM and is above, unchanged: the arms
-- are act 2 and act 2 stays. `Fn.pyreliskSlab`, `Fn.openPyreliskMount`,
-- `Fn.shakePyreliskMount` and `clearPyreliskMount` are also kept - they are
-- act 1's monolith mount, which predates the redesign and is untouched by it.)

-- THE ARMS' ONE BEHAVIOUR. They are dead weight on the ground - `krakenarm`
-- and `krakenpolyp` are `function() end` and a no-op is nearly right - but an
-- act with 120 seconds of zero pressure is a damage check, not a fight. So an
-- arm bleeds: every `K.PY_ARM_POOL_GAP` seconds it marks a point on the rim
-- path near itself and leaves a lava pool there.
--
-- The pool is owned by the COLOSSUS, not by the arm: `spawnPool` hangs the
-- hazard off `creature.pools`, and a pool on a body that is about to be killed
-- would vanish with it - which would make the act's clock run backwards every
-- time an arm died.
--
-- Signature is the dispatcher's `(creature, now, dt)` - the order
-- `ARCHETYPE_UPDATERS` is called with, not the order this move reads in.
function Fn.updatePyreliskArm(creature, now: number, _dt: number)
	local owner = creature.partOf
	if not owner or owner.dead or creature.dead then
		return
	end
	local at = creature.pos
	if not at then
		return
	end
	if creature.pyreliskPoolPending then
		if now < creature.pyreliskPoolPending.at then
			return
		end
		spawnPool(owner, creature.pyreliskPoolPending.pos, K.PY_ARM_POOL, now)
		creature.pyreliskPoolPending = nil
		creature.pyreliskPoolAt = now + K.PY_ARM_POOL_GAP
		return
	end
	if now < (creature.pyreliskPoolAt or 0) then
		return
	end
	-- A point on the rim path within reach of this arm. Kept inside the band
	-- the party can actually stand on, for the same reason `pyreliskLatch`
	-- clamps: a pool in the lake is a pool nobody was ever standing in.
	local state = owner.pose
	local centre = if state and state.center then state.center else at
	local angle = math.random() * math.pi * 2
	local spread = randomBetween(0, K.PY_ARM_POOL_R)
	local want = at + Vector3.new(math.cos(angle) * spread, 0, math.sin(angle) * spread)
	local out = Vector3.new(want.X - centre.X, 0, want.Z - centre.Z)
	local reach = math.max(out.Magnitude, 0.01)
	local band = math.clamp(reach, K.PY_LAKE_R + 6, K.PY_PATH_OUT - 6)
	local site = centre + (out / reach) * band
	site = Vector3.new(site.X, at.Y, site.Z)
	-- The `mark` telegraph, an existing CreatureEventController branch, then
	-- the pool. Warned ground, always - the arms are a clock, not a gotcha.
	fireEvent("telegraph", site, {
		kind = "mark",
		radius = K.PY_ARM_POOL.radius,
		duration = K.PY_ARM_POOL_ARM,
		skin = "lava",
	})
	creature.pyreliskPoolPending = { pos = site, at = now + K.PY_ARM_POOL_ARM }
end

-- ------------------------------------------------------------- the choir
--
-- Everything below is Noctyss's, and it is deliberately small: seven stalks
-- that are ordinary creatures, one number saying which of them is real, and
-- a mouth that comes up when that one breaks.

-- SEVEN EYES RISE OUT OF THE STONE, over this many seconds. Long enough to be
-- a beat the party watches happen and short enough that it is not a pause: the
-- 4s regrow dark (`parts.regrow`) is the wait, and this is the arrival at the
-- end of it. NBC's GROW_DARK holds each lantern dark until its eye clears the
-- collar lip, so what is actually read is "seven lights come up out of the
-- floor" rather than "seven stalks appear".
K.CHOIR_REGROW = 1.2

-- HOW FAR THROUGH THAT RISE THE CHOIR IS, 0..1, eased. `creature.choirGrowAt`
-- is stamped by Fn.spawnBossParts and cleared here on the frame it completes,
-- so 1 is the answer for the whole rest of the fight and the ramp costs one
-- field test per frame once it is done. Smoothstepped: a linear scale reads as
-- a telescope extending, an eased one as something growing.
function Fn.choirGrowT(creature): number
	local at = creature.choirGrowAt
	if not at then
		return 1
	end
	local u = (os.clock() - at) / math.max(K.CHOIR_REGROW, 1e-3)
	if u >= 1 then
		creature.choirGrowAt = nil
		return 1
	end
	u = math.clamp(u, 0, 1)
	return u * u * (3 - 2 * u)
end

-- IS THE WHOLE CHOIR OUT OF THE STONE? The seven rise together off one clock,
-- so this is really one question asked seven times - written as a loop anyway,
-- because the state is per stalk and a future regrow that staggers them should
-- not have to find this.
function Fn.choirGrown(state): boolean
	for index in state.stalks do
		if NoctyssPath.growOf(state, index) < 1 then
			return false
		end
	end
	return true
end

-- Pin every living stalk to its lantern and hand it its pose.
--
-- A stalk's hitbox IS its light: the server stands the model at the BULB, 35
-- studs up at the end of the crook, so shooting the lantern is what
-- registers and the trunk the design says is out of reach really is. The
-- model itself is hidden - the client draws the chain - exactly like the
-- colossus it belongs to.
function Fn.updateChoir(creature, state, dt: number)
	for _, stalk in state.stalks do
		stalk.standing = false
	end
	-- THE REGROW, AS A NUMBER. One value for all seven (they came out of the
	-- stone together), read once a frame rather than per stalk - and written
	-- onto EVERY socket rather than only onto the ones with a part still
	-- standing behind them. A stalk shot dead half way out of its collar
	-- otherwise leaves `grow` frozen at 0.5 in the pose state for the rest of
	-- the cycle, which reads to `Fn.choirGrown` as a choir that never finished
	-- rising and quietly retires `herdingsnap` until the next regrow.
	--
	-- Written BEFORE the ring walk below, because `grow` is a term in
	-- `bulbPosition`: the curve is scaled about the collar, so a stalk half out
	-- of its socket stands its lantern - and its capsule - half way up, and the
	-- hitbox solved on the next few lines has to be solved from this frame's
	-- value rather than the last one's.
	local grown = Fn.choirGrowT(creature)
	for index in state.stalks do
		NoctyssPath.setGrow(state, index, grown)
	end
	-- HER OWN RING, NOT THE WORLD. This walked the entire `creatures` array
	-- every frame to find seven parts - O(everything alive) per boss per
	-- frame, against an ambient population capped at 40 (Tuning SPAWNER
	-- GLOBAL_CAP) plus raid waves, hatchlings, the boss and the choir itself:
	-- ~50 structs and ~50 field tests, sixty times a second, to touch seven.
	-- `Fn.spawnBossParts` already knows exactly which seven it planted, so it
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
				-- A STALK STILL RISING CANNOT BE TRADED WITH. A lantern
				-- rising out of the floor is a thing to watch, not a target: it
				-- is drawn dark under the collar lip (NBC's GROW_DARK) and its
				-- hitbox is somewhere inside the stone. `untargetable` is the
				-- flag every target pick and `damage()` already honour through
				-- `Fn.unaimable`, so this needs no new gate anywhere - and it is
				-- written every frame rather than latched, so no path can leave
				-- a stalk stuck out of the fight.
				part.untargetable = grown < 1
				Fn.hideColossusModel(part)
				part.pos = NoctyssPath.bulbPosition(state, index)
				part.model:PivotTo(CFrame.new(part.pos))
				local model = part.model
				model:SetAttribute(ATTR.LEAN, stalk.lean)
				model:SetAttribute(ATTR.BEAM_ANGLE, stalk.beamAngle)
				model:SetAttribute(ATTR.DOUSE, stalk.douse)
				-- ON A CHANGE ONLY, unlike the three above: `Grow` moves for
				-- 1.2 seconds after a regrow and never again, and a stalk that
				-- has finished rising should not be paying replication for a
				-- number that is 1 forever. The final write of exactly 1 is the
				-- frame `Fn.choirGrowT` completes, so the client is never left
				-- easing toward 0.997.
				if (part.growPub or 1) ~= grown then
					part.growPub = grown
					model:SetAttribute(ATTR.GROW, grown)
				end
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
		creature.model:SetAttribute(ATTR.CHOIR_DOWN, down)
	end
end

-- Pick the stalk that runs the next light attack: a LIVING, LIT one,
-- preferring whichever has the target at a workable distance. A beam out of
-- a dead socket would be the fight lying about where its attacks come from.
function Fn.pickChoirStalk(state, root: BasePart?): number?
	local best, bestScore = nil, -math.huge
	for index, stalk in state.stalks do
		-- ...AND NOT ONE THAT IS ALREADY SWINGING. A limb mid-slam is not a
		-- lantern breathing at you, and handing it a lightsweep would be the
		-- fight asking a player to read the rhythm of a light that is at that
		-- moment a weapon - as well as fighting the attack pose for the lean.
		-- ...NOR ONE STILL COMING OUT OF ITS COLLAR. A sweep is drawn FROM the
		-- bulb, and a bulb at grow < 1 is inside the stone: the wedge would
		-- come out of the floor with no lantern above it to explain it.
		if
			stalk.alive
			and (stalk.douse or 0) < 0.5
			and NoctyssPath.growOf(state, index) >= 1
			and not NoctyssPath.stalkBusy(state, index, state.time)
		then
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

function Fn.placeMawFloor(creature, state)
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
-- reason `pyreliskLatch` and `clearMawFloor` are: `Fn.placeColossus` is the one
-- call every mode of this fight passes through, so it is where they have to
-- be stepped, and it sits above the code that owns them.
local updateBrineHazards

-- Stand the model where its pose says its head is, aimed up-body.
function Fn.placeColossus(creature, def, now: number, root: BasePart?)
	local state = Fn.colossusState(creature, def)
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
		-- Fn.bossFacing() reads THAT, not the pose. Left alone, everything drawn
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
		-- there permanently. Re-asserting it here, after Fn.updateBossAttack has
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
		--   * `Fn.bossMouth` / `Fn.throwGlob`'s launch point: visual origin only,
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
		-- `Fn.setSweepRate`). A sweeping handler writes `sweepTargetRate` for the
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
		-- THE HITTABLE PROXY FOLLOWS THE WINDOW. Ordinarily the authority
		-- position is the head, which is where every window in this fight used
		-- to be; the two windows the second pass added are not on the head.
		-- The coilslam's is a LOOP lying across the sand and the bite's is the
		-- head hanging low over the person it just snapped at, and both have a
		-- twin in BrinejawPath that says exactly where. Written before the
		-- PivotTo below so the server model moves with it and the thing you
		-- swing at is the thing you can see.
		--
		-- Both flags are recomputed every frame by their own handler and
		-- cleared on its `finish`, so nothing here can latch: no attack
		-- running means no proxy moved.
		if creature.coilOpen then
			creature.pos = BrinejawPath.coilslamPoint(state)
		elseif creature.biteOpen then
			creature.pos = BrinejawPath.biteHeadPoint(state)
		end
		local forward = BrinejawPath.tangentAt(state, 0)
		local up = if math.abs(forward.Y) > 0.99 then Vector3.new(0, 0, 1) else Vector3.new(0, 1, 0)
		local right = forward:Cross(up)
		if right.Magnitude > 1e-4 then
			creature.model:PivotTo(CFrame.fromMatrix(creature.pos, forward, right.Unit:Cross(forward).Unit))
		end
	end
	if def.pose == "pyrelisk" then
		-- WHAT THE STOCK TELL POINTS AT. Fn.beginBossAttack draws the row's
		-- telegraph from Fn.bossFacing(), which reads `yaw0` - and for an
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
	if def.pose == "pyrelisk" and creature.attack == nil then
		-- THE SWEEP THAT MAKES THE MASK HONEST. Four of the five ways out of
		-- an attack (Fn.openStagger, Fn.endBossAttack, the missing-handler bail and
		-- the collapse) never run the handler's own `recover`, and each of
		-- them leaves `creature.attack` nil - so rather than four matched
		-- clears that a future exit could forget to join, the invariant is
		-- stated once, here, on the one call every mode of this fight passes
		-- through: NO ATTACK RUNNING MEANS NO SEAM OPEN. It runs in the same
		-- frame the exit does, because Fn.updateBoss calls Fn.placeColossus after
		-- the attack tick. See `Fn.pyreliskCloseSeams` for the full table.
		state.seamsOpen = 0
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
		Fn.updatePyreliskMount(creature, def, state, now)
	end
	publishPose(creature, state)
end

-- The earned opening: it loses its grip, comes down, and takes damage for
-- `seconds`. Called by a handler that has just been baited into a mistake.
function Fn.openStagger(creature, def, now: number, seconds: number)
	creature.untargetable = false
	creature.exposedUntil = now + seconds
	creature.model:SetAttribute(ATTR.EXPOSED, true)
	-- Retire the attack here, because opening a window SKIPS Fn.endBossAttack -
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
-- they have always been - just K.COLLAPSE_TIME later. That is the whole reason
-- this is a delay in front of the death rather than a rewrite of it.
K.COLLAPSE_TIME = 2.5
-- How much further down the perch the fall drags the body, in Brinejaw's
-- units: one more full turn than any stance ever costs it, so the coils end
-- up sprawled round the tower's foot instead of gripping its drum.
K.COLLAPSE_COILS = 1.0

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
	-- A SHIP DOES NOT DIE, SHE WRECKS - and she needs a beat to do it in.
	--
	-- Admiral Wrack's hull reaching zero is the act-two -> act-three break, and
	-- an act break with no time in it is a boss that blinks out of existence and
	-- a duelist that blinks in. This takes the death and holds it open for
	-- `wreckFor` seconds while `ATTR.WRACK_WRECK` ramps 0 -> 1 (the client eases
	-- her list and her mast fall off that level), then hands the real death back
	-- to kill() exactly as the colossus fall does.
	--
	-- IT ALSO GIVES THE CLOSING VOLLEY ITS ROOM. `ProjectileService.watch` fires
	-- the ring of gun-deck explosions and the hull's splash when the owner is
	-- GONE - so without a hold, the ship blew up on the same frame she stopped
	-- existing. Now she lists, the masts come down, and then she goes.
	--
	-- Checked BEFORE the perch test below, and deliberately not folded into it:
	-- he has no `pose` and no `entrenched`, holds no perch, and must never touch
	-- `Fn.colossusState` - he has no rig for it.
	--
	-- ============================================================
	-- `def.wreckFor` IS PART OF THE GATE, AND IT IS THE WHOLE FIX (2026-09-12).
	--
	-- This branch used to read `def and def.succeededBy and creature.mode and
	-- creature.mode ~= "rising"`, and `succeededBy` is NOT "this is a ship that
	-- wrecks" - it is "this boss has a successor". The Pyrelisk has one
	-- (`pyrelisk_heart`), is `entrenched`, is posed, and therefore took THE
	-- SHIP'S BRANCH: `creature.wrecking` set, `ATTR.WRACK_WRECK` published on a
	-- rig that does not read it, the hold sized by `wreckFor` (absent -> 2.5)
	-- instead of its own `collapseFor` (4.0) - and then `Fn.updateBossCollapse`
	-- returned at its `creature.wrecking` test BEFORE the `poseKind ==
	-- "pyrelisk"` branch ever ran. So the colossus never drove its `collapse`
	-- pose, NEVER OPENED THE CALDERA, never wrote `PyreliskShaftFloor` and never
	-- started `Fn.pyreliskShaftWatch`: the heart was raised into a chamber the
	-- party had no way to reach, with nothing in any log. Every landmark in the
	-- caldera/shaft slice was present and correct; the code they point at was
	-- simply never reached.
	--
	-- SO THE BRANCH NOW TESTS FOR WHAT IT CONSUMES. Everything inside it is
	-- Wrack-specific - `ATTR.WRACK_WRECK`, `creature.wrackKit`, and the
	-- `def.wreckFor` hold itself - and `wreckFor` is the field that drives the
	-- beat. It exists on exactly ONE row (`Bosses.items.admiral_wrack`), which
	-- is the right shape for a gate: a boss opts INTO wrecking by carrying the
	-- number that sizes it, rather than being swept in by a field that means
	-- something else. Testing `not def.pose` would have worked too and is worse
	-- - a branch that asks about the absence of an unrelated field is one
	-- rename away from being wrong again.
	--
	-- The `or 2.5` fallbacks below are therefore now unreachable defaults
	-- rather than live behaviour. Left as written: a default that can only be
	-- reached by a future row is not dead code, it is the contract for one.
	-- ============================================================
	if def and def.succeededBy and def.wreckFor and creature.mode and creature.mode ~= "rising" then
		creature.collapsing = true
		creature.wrecking = true
		creature.deathBlow = killer
		creature.untargetable = true
		creature.attack = nil
		creature.forcedAttack = nil
		creature.poison = nil
		creature.knockVel = nil
		creature.stunnedUntil = nil
		creature.exposedUntil = nil
		-- The crack window is over with the act. Cleared rather than left to
		-- expire, because the hull is untargetable now and an EXPOSED hull
		-- nothing can hit is a lie the client would keep drawing.
		creature.model:SetAttribute(ATTR.EXPOSED, nil)
		-- HER OWN MOVES STOP WITH HER. The kegs and the boarding party outlive
		-- the attacks that made them (that is what `wrackKit` is for), and a
		-- boarding party still marching to repair a gun deck on a ship that is
		-- going under is the exact shape of hazard the colossus fall clears
		-- below for Brinejaw's polyps.
		if creature.wrackKit then
			for _, run in creature.wrackKit.runners or {} do
				if run.prop and CreatureService.isAlive(run.prop) then
					CreatureService.despawn(run.prop.model)
				end
			end
			for _, man in creature.wrackKit.boarders or {} do
				if man.prop and CreatureService.isAlive(man.prop) then
					CreatureService.despawn(man.prop.model)
				end
			end
			creature.wrackKit = nil
		end
		creature.model:SetAttribute(ATTR.WRACK_WRECK, 0)
		setMode(creature, "collapse", def.wreckFor or 2.5, os.clock())
		fireEvent("bossCollapse", creature.pos, { name = def.name, duration = def.wreckFor or 2.5 })
		return true
	end
	-- Only a boss that is HOLDING a perch has anything to fall off. A posed
	-- boss that swims (the Kraken) and every ordinary creature take the
	-- ordinary death, untouched.
	if not def or not def.entrenched or not def.pose or not creature.mode or creature.mode == "rising" then
		return false
	end
	local state = Fn.colossusState(creature, def)
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
	creature.coilOpen = false
	creature.biteOpen = false
	creature.punishOpen = false
	creature.model:SetAttribute(ATTR.EXPOSED, nil)
	-- AND ITS HAZARDS DIE WITH IT. Brinejaw's wave, rings, bombardment and
	-- flood are all resolved from `Fn.placeColossus`, which keeps running through
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
	-- HOW LONG THE FALL IS, and a row may now say. `K.COLLAPSE_TIME` (2.5) is
	-- Brinejaw's number and stays the default for every boss that does not ask
	-- for another; the Pyrelisk asks for 4.0 (`collapseFor`), because its death
	-- is not only a body coming down - the lake has to drain and the shaft has
	-- to open underneath it while it does, and 2.5 seconds is not enough beats
	-- to read both. Same field shape as the Wrack's `wreckFor` one branch up.
	local fall = def.collapseFor or K.COLLAPSE_TIME
	setMode(creature, "collapse", fall, os.clock())
	fireEvent("bossCollapse", creature.pos, { name = def.name, duration = fall })
	return true
end

-- One frame of the fall. Ends by handing the death straight back to kill().
function Fn.updateBossCollapse(creature, def, now: number)
	local u = modeProgress(creature, now)
	-- THE SHIP'S OWN FALL, and it returns before anything below touches a rig
	-- she does not have. One published level and no pose: `Fn.placeColossus`
	-- and `Fn.colossusState` are for a body with joints, and she is drawn off
	-- `CreatureId` by WrackBodyController instead.
	--
	-- ONE WRITER, AND THAT IS WHY THIS TEST IS STILL A FLAG AND NOT A RE-READ OF
	-- THE ROW. `creature.wrecking` is set in exactly one place - the
	-- `def.succeededBy and def.wreckFor` branch of `beginBossCollapse` - and
	-- cleared in exactly one, four lines below. So it says precisely "that
	-- branch opened this collapse", which is the question this early return is
	-- asking, and re-deriving it from `def` here would be a SECOND place to
	-- disagree about which fall this is. That is the shape of the 2026-09-12
	-- bug one function up: the gate said `succeededBy` while the body of the
	-- branch meant `wreckFor`, and the Pyrelisk fell down the gap between them.
	-- Fix the gate, keep one writer, and this stays honest for free.
	if creature.wrecking then
		creature.model:SetAttribute(ATTR.WRACK_WRECK, math.clamp(u, 0, 1))
		if u >= 1 then
			creature.collapsing = nil
			creature.wrecking = nil
			-- The death that always happened. kill() destroys the model - taking
			-- this attribute with it at exactly 1 - and then fires Killed, inside
			-- which BossService raises the Admiral. The duelist therefore exists
			-- in the same frame the ship stops existing, which is the seam the
			-- client hides her copy of him on.
			kill(creature, creature.deathBlow)
		end
		return
	end
	local e = u * u * (3 - 2 * u)
	local from = creature.collapseFrom
	local state = Fn.colossusState(creature, def)
	-- Per-pose, the way publishPose is: what "coming down" LOOKS like is the
	-- boss's own vocabulary, and a pose with no branch here still gets the
	-- beat and the event - the generic half of the contract.
	if creature.poseKind == "brinejaw" then
		-- The grip goes (coil slides a turn past its last stance), the head
		-- comes down on the sand (slump), and the tail lets go of the tower
		-- and lies out in the shallows (unwind, at sweep height).
		state.coil = from.coil - K.COLLAPSE_COILS * e
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
		-- ============================================================
		-- THE CALDERA OPENS, 2.5 SECONDS INTO A FOUR-SECOND FALL.
		--
		-- The lava drains, the lake floor goes, and a 120-stud shaft is open
		-- where it was - with a second and a half of fall still to watch it
		-- happen under the body, which is what makes it read as cause and
		-- effect rather than as two things that occurred.
		--
		-- IT IS AN ATTRIBUTE ON THE ARENA AND NOT A CALL, and the reason is
		-- this file's local budget: `BossArenaService` requires nothing from
		-- CreatureService, so CreatureService COULD require it - but that is a
		-- new file-scope `local` in a module at Luau's 200-local chunk limit,
		-- and the limit is a boot failure rather than a gate failure. An
		-- attribute on a replicated Workspace instance costs no local,
		-- replicates to late joiners for free, and the client VFX lane can read
		-- it without a second wire.
		--
		-- A LEVEL, NEVER AN EDGE, so a client that adopts the model mid-fall
		-- still sees an open caldera. The latch below is only there to keep
		-- this from writing the same value sixty times a second.
		--
		-- `u * fall` AND NOT `u`: `u` is the fraction of a duration that a ROW
		-- chooses (`collapseFor`), so testing `u >= 0.625` would silently move
		-- the beat every time that number was retuned. This asks the question
		-- in seconds, which is the unit `K.PY_CALDERA_AT` is written in.
		--
		-- AND THE SHAFT WATCH STARTS HERE, not at the death: the hole is open
		-- for the last 1.5 seconds of the fall and somebody will jump into it
		-- before the body has finished sinking. `pyreliskShaftFloor` is the
		-- arena's own floor plane, captured while the boss still knows where it
		-- is standing - the heart, which takes the watch over below, is forty
		-- thousand studs away and cannot ask.
		local fall = def.collapseFor or K.COLLAPSE_TIME
		if not creature.pyreliskCaldera and u * fall >= K.PY_CALDERA_AT then
			creature.pyreliskCaldera = true
			creature.pyreliskShaftGraceAt = now + K.PY_SHAFT_GRACE
			Fn.pyreliskOpenCaldera(def.islandId, (creature.pose and creature.pose.center or creature.pos).Y)
		end
		if creature.pyreliskCaldera then
			Fn.pyreliskShaftWatch(creature, def, now)
		end
		-- ============================================================
	end
	-- No `root`: a dying boss does not track anybody, so the face angle it
	-- died on is the one it falls on.
	Fn.placeColossus(creature, def, now, nil)
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
function Fn.colossusStones(creature, def)
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
			-- Fn.restoreStones would faithfully put it back underground. The
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
-- local is not in scope for it. What actually cleans up is `Fn.colossusStones`,
-- which raises anything the last party sank while building the next fight's
-- table (see the comment at its `restCFrame`). Spent stones therefore sit in
-- the ground BETWEEN fights and stand again on the next summon, which is
-- correct but is not what this comment said.
function Fn.restoreStones(creature, def)
	for _, stone in Fn.colossusStones(creature, def) do
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
function Fn.regrowStones(creature, def, now: number)
	if not def.stoneRegrow then
		return
	end
	for _, stone in Fn.colossusStones(creature, def) do
		if not stone.standing then
			-- Stamped lazily rather than at `Fn.spendStone`, so a stone spent
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
-- Fn.spendStone will make when the blow lands, asked at TELEGRAPH time so the
-- marker can already say "this one is on rock" - which is the whole reason
-- to aim a slam at a stone in the first place.
local function stoneNear(creature, def, at: Vector3, reach: number): boolean
	for _, stone in Fn.colossusStones(creature, def) do
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
function Fn.spendStone(creature, def, at: Vector3, reach: number)
	local best, bestDist = nil, reach
	for _, stone in Fn.colossusStones(creature, def) do
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
	-- (Fn.restoreStones), and the authored and procedural arenas both work
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
-- `fire` runs when the strike starts (Fn.updateBossAttack: windup ends -> phase
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
	local state = Fn.colossusState(creature, def)
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
	-- THE ORANGE GROUND-RUNG MARKER IS GONE, AND NOTHING REPLACES IT
	-- (2026-09-08, contract REVISION 2 §6). This used to fire `serpentSweep`
	-- here with the arc, the reach, the girth and both halves of the lead
	-- time, and the client drew a lit band on the sand from it. Two things
	-- were wrong with that and only the second one is fixable by tuning:
	--
	--   * the band is a STATIC wedge and the arm is a DRAG CURVE, so the
	--     marker promised a lane the tail was already bending out of;
	--   * and there is nothing to warn about. The whip is a hundred parts of
	--     serpent unwinding off a lighthouse in front of you, held on the
	--     start bearing for the whole windup. It IS the telegraph, and a
	--     second one drawn under it only taught players to watch the floor
	--     instead of the animal.
	--
	-- Every Brinejaw row that reaches this function - whip, doublewhip,
	-- whipback, spiral - is therefore marker-less, and `aimSweep` has no
	-- caller outside this boss. The client's serpentSweep handler stays where
	-- it is: it is the pattern other lanes build their ground rungs from, and
	-- nothing here fires it any more.
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
-- SO THE FILTER IS STEPPED FROM `Fn.placeColossus`, NOT FROM THE HANDLERS, and
-- that is the whole reason this is a one-line field rather than a call: a
-- handler only runs while its own attack is running, and stepSweepRate has to
-- keep running AFTER one ends or the rate freezes at whatever it held on the
-- last strike frame and the arm keeps its 28-degree bend for the rest of the
-- fight. Fn.placeColossus is the one call every mode of this fight passes
-- through and it is the only place `dt` exists, so a sweeping handler writes
-- its exact rate here and everything else - windups, recoveries, the idle
-- serpent, the punish window - leaves it alone and gets the 0 that unwinds
-- the tip over about a third of a second.
function Fn.setSweepRate(state, rate: number)
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
function Fn.sweepWedgeHits(creature, def, p, state, fromAngle: number)
	local a = creature.attack
	local girth = p.girth or 3.2
	local lo, hi = Fn.bossRoll(creature, def, p.damage)
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

K.ATTACK_HANDLERS.orbitsweep = {
	windup = function(creature, def, p, u, _sub)
		aimSweep(creature, def, p)
		local state = Fn.colossusState(creature, def)
		-- Not travelling yet: the arm holds the start bearing for the whole
		-- windup, so the rate decays toward 0 and the tip straightens out.
		Fn.setSweepRate(state, 0)
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
		local state = Fn.colossusState(creature, def)
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
		local state = Fn.colossusState(creature, def)
		state.unwind = 1
		local rate = a.arc / math.max(p.duration, 1e-3)
		local from = state.sweepAngle
		state.sweepAngle += a.dir * rate * dt
		-- THE EXACT RATE, signed, handed to the shared filter. The server
		-- knows it - it is the number that drives the line above - and it is
		-- what puts the drag in the arm that is about to be hit-tested.
		Fn.setSweepRate(state, a.dir * rate)
		Fn.sweepWedgeHits(creature, def, p, state, from)
	end,
	finish = function(creature, def, _p, _now)
		-- The arm stays out; the entrenched branch winds it back onto the
		-- tower, so the recovery reads as the serpent re-gripping - and the
		-- rate is left to decay to 0 on its own, which IS the springback.
		local state = Fn.colossusState(creature, def)
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
-- NO GROUND MARKER, as of REVISION 2 §6 - and this row is the one that never
-- could have had an honest one anyway. A static marker draws ONE fixed band
-- for the whole move, so a contracting reach sent through it would promise
-- safe ground the arm is still crossing. The closing edge is drawn by the
-- body controller from `sweepReach` instead - same function, same frame.
K.ATTACK_HANDLERS.serpentspiral = {
	windup = function(creature, def, p, u, _sub)
		aimSweep(creature, def, p)
		local state = Fn.colossusState(creature, def)
		state.unwind = math.max(state.unwind or 0, u)
		state.sweepHeight = BrinejawPath.SWEEP_LOW
		state.sweepAngle = creature.attack.startAngle or state.sweepAngle
		Fn.setSweepRate(state, 0)
		-- The kind goes on at the START of the windup, at U = 0, so the reach
		-- is still SWEEP_REACH while the arm peels off the tower: the closing
		-- only begins when the arm does.
		state.attackKind = "spiral"
		state.attackU = 0
		state.aimX, state.aimZ = 0, 0 -- spiral does not aim; the header says so
	end,
	fire = function(creature, def, p, _now, _root)
		local a = creature.attack
		local state = Fn.colossusState(creature, def)
		aimSweep(creature, def, p)
		state.unwind = 1
		a.hit = {}
		state.sweepAngle = a.startAngle
	end,
	strike = function(creature, def, p, _now, dt, u, _root, _sub)
		local a = creature.attack
		local state = Fn.colossusState(creature, def)
		state.unwind = 1
		local rate = a.arc / math.max(p.duration, 1e-3)
		local from = state.sweepAngle
		state.sweepAngle += a.dir * rate * dt
		Fn.setSweepRate(state, a.dir * rate)
		-- U IS THE CLOSING. Run it across the whole strike so the reach
		-- reaches its inner limit exactly as the arc finishes.
		state.attackU = u
		Fn.sweepWedgeHits(creature, def, p, state, from)
	end,
	finish = function(creature, def, _p, _now)
		local state = Fn.colossusState(creature, def)
		state.unwind = math.min(state.unwind or 1, 1)
		-- U TO 1 FIRST, published this frame with the kind still set: the
		-- spiral's arm is at its innermost here, and clearing the kind now
		-- would snap 53 studs of reach back in one frame.
		state.attackU = 1
	end,
	recover = function(creature, def, _p, _u, _sub)
		-- ...and NOW the kind goes. The first recover frame, one frame after
		-- the one that published U = 1.
		local state = Fn.colossusState(creature, def)
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
K.SLAM_IMPACT = 0.62

local function aimSlam(creature, def, p)
	local a = creature.attack
	if a.aimed then
		return
	end
	a.aimed = true
	local state = Fn.colossusState(creature, def)
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
	-- EVERY STANDING STONE'S POSITION, so the bait can be SEEN (contract §7 -
	-- "the mechanic exists; nobody can see it"). The client already gets the
	-- impact point and `stoneNear`; what it could not know was where the rocks
	-- are, so it had nothing to glow. Positions rather than a count, and the
	-- SERVER's list rather than the arena config's, because a stone spent
	-- earlier in the fight is sunk and must not light up: `standing` is the
	-- only place that truth lives.
	local stones = {}
	for _, stone in Fn.colossusStones(creature, def) do
		if stone.standing then
			table.insert(stones, stone.position)
		end
	end
	fireEvent("serpentSlam", a.impact, {
		radius = p.radius or 13,
		-- The client used to derive the landing from `duration` measured at
		-- arrival, so the baited-stone shatter fired one network hop late.
		-- The blow lands at K.SLAM_IMPACT of the strike, after the windup;
		-- ship the absolute server clock so a mid-attack adopter is exact.
		impactAt = Workspace:GetServerTimeNow() + p.windup + (p.duration or 0) * K.SLAM_IMPACT,
		stones = stones,
		-- THROUGH the blow, not up to the swing. The rings used to close at
		-- the end of the windup, but the rattle only starts falling then and
		-- the damage resolves at K.SLAM_IMPACT of the strike - so the countdown
		-- finished 0.53s before anything happened, and a player who read it
		-- correctly stepped back into the circle and died to it.
		duration = p.windup + (p.duration or 0) * K.SLAM_IMPACT,
		-- Whether this landing is ON rock: the client tints the marker, so a
		-- correct bait is legible before the tail comes down, not after.
		-- 11 -> 13 with the row (contract §5). The default is the row's twin
		-- and must move with it, or a book that omits the field silently
		-- tests a narrower bait than the one the client is glowing.
		stoneNear = stoneNear(creature, def, a.impact, p.stoneReach or 13),
	})
end

K.ATTACK_HANDLERS.tailslam = {
	windup = function(creature, def, p, u, _sub)
		aimSlam(creature, def, p)
		local state = Fn.colossusState(creature, def)
		state.unwind = math.min(u * 1.2, 1)
		state.sweepHeight = BrinejawPath.SWEEP_HIGH + (p.lift or 9) * u
		state.sweepAngle = creature.attack.aimAngle or state.sweepAngle
	end,
	fire = function(creature, def, p, _now, _root)
		local a = creature.attack
		local state = Fn.colossusState(creature, def)
		aimSlam(creature, def, p) -- no-op after windup: the marker IS the blow
		state.sweepAngle = a.aimAngle
	end,
	strike = function(creature, def, p, now, _dt, u, _root, _sub)
		local a = creature.attack
		local state = Fn.colossusState(creature, def)
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
		local fall = math.min(u / K.SLAM_IMPACT, 1)
		local top = BrinejawPath.SWEEP_HIGH + (p.lift or 9)
		state.sweepHeight = top + (BrinejawPath.SWEEP_LOW - top) * fall * fall
		if a.fired or u < K.SLAM_IMPACT then
			return
		end
		a.fired = true
		local lo, hi = Fn.bossRoll(creature, def, p.damage)
		Fn.damagePlayersInCone(a.impact, Vector3.new(1, 0, 0), p.radius or 13, math.pi, false, lo, hi, creature)
		fireEvent("slam", a.impact, { radius = p.radius or 13, skin = p.skin })
		-- Same 13 as the marker above asked with: the reach that DECIDES and
		-- the reach that was DRAWN are one number.
		local stone = Fn.spendStone(creature, def, a.impact, p.stoneReach or 13)
		if stone then
			Fn.openStagger(creature, def, now, p.stagger or 8)
		elseif p.weakStagger then
			-- Sand absorbs most of it: the serpent is jarred, not brought
			-- down. Enough to keep the fight winnable, far too short to be
			-- the plan.
			Fn.openStagger(creature, def, now, p.weakStagger)
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
-- instead by `updateBrineHazards`, run from `Fn.placeColossus` - the one call
-- every mode of this fight passes through, including the collapse. The
-- handlers below only ARM them.

-- The arena's cover, plus the one piece no table lists: the lighthouse
-- itself. Built once per fight and kept on the creature - `waveSheltered` is
-- asked about every player on every frame of a crossing, and BrinejawPath
-- deliberately takes the list as an argument (it is required by the pose math
-- on both sides of the wire, so a BossArenas dependency there is a cycle
-- waiting to happen).
K.BRINE_SPIRE_COVER = { offset = Vector3.zero, radius = 9 }

local function brineCover(creature, def)
	if creature.brineCover then
		return creature.brineCover
	end
	local arena = def.islandId and BossArenas.items[def.islandId]
	local cover = { K.BRINE_SPIRE_COVER }
	for _, piece in (arena and arena.cover or {}) do
		table.insert(cover, piece)
	end
	creature.brineCover = cover
	return cover
end

-- The hazard record this boss hangs its live effects off. One table, created
-- on demand, torn down with the creature.
function Fn.brineHazards(creature)
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
function Fn.shoveAlong(at: Vector3, dir: Vector3, push: number, duration: number)
	fireEvent("gust", at - dir * 6, { radius = 12, push = push, duration = duration })
end

-- Is this root standing on the beach rather than in the air? The bell's rings
-- and nothing else ask: a jumping player clears them, which is the entire
-- read of that attack. 4.6 studs is a standing R15 root (~3.0 over the sand)
-- with 1.6 of slack for the beach profile and the arena's own half-stud of
-- authored slop, and well under the ~7 a jump's apex reaches.
K.BRINE_GROUNDED = 4.6

function Fn.brineGrounded(state, position: Vector3): boolean
	local dx, dz = position.X - state.center.X, position.Z - state.center.Z
	local r = math.sqrt(dx * dx + dz * dz)
	return position.Y - (state.center.Y + BrinejawPath.sandY(r)) < K.BRINE_GROUNDED
end

-- How far out a player is standing, in the arena's own frame.
function Fn.brineRadiusOf(state, position: Vector3): number
	local dx, dz = position.X - state.center.X, position.Z - state.center.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- ------------------------------------------------------------- the wave
--
-- RIPTIDE, REDESIGNED (2026-09-08, contract REVISION 2 §1). It was a wall of
-- water crossing the arena on one bearing, answered only by the lee of a rock;
-- it is now an EXPANDING RING heaved outward by the coils, with TWO GAP ARCS
-- the party RUNS TO. Still TALL - there is no height band in the test below
-- and jumping never evades it.
--
-- The two answers, in the order they matter:
--   * the GAPS. Two arc centres at least `gapSpread` apart, each `gapHalf`
--     wide, picked at fire time and marked with foam before the ring moves.
--     Being inside one is being safe, at any radius.
--   * the COVER SHADOW, kept exactly as it was and now secondary. It is what
--     makes the reef stones matter to something other than the tailslam, and
--     `BrinejawPath.waveSafe` folds both tests into the one call the client
--     also asks - the shadow is still a promise, not a suggestion.
--
-- WHY TWO GAPS AND NOT ONE. One gap is a single point the whole party sprints
-- to and the move stops being a decision; two, at least 100 degrees apart,
-- means somebody is always nearer one than the other and the party splits.
K.RIPTIDE_GAP_SPREAD = math.rad(100)

-- Pick the pair. `gapA` is free; `gapB` is drawn at a separation of
-- spread..(2*pi - spread) from it, so the SHORT way round between the two is
-- always at least `spread` - a naive "two independent draws, reroll if close"
-- would keep the bias and cost a loop.
function Fn.riptideGaps(spread: number, anchor: number?): (number, number)
	-- NEAR THE PLAYER, not anywhere. The user's playtest verdict on the
	-- random pair was "literally undodgeable": at r=40 a gap 120 degrees
	-- away is an 84-stud run against a ring that closes the distance in
	-- ~2 s. `anchor` is the boss's current target's bearing; gapA lands
	-- within +-K.RIPTIDE_GAP_JITTER of it, so from r=40 the run is at most
	-- ~15 studs (one second) and the read is "step sideways into the calm
	-- water", which is a dodge a first-timer can find. gapB keeps the old
	-- rule off gapA, so a party still splits. No anchor (nobody targeted)
	-- falls back to the old free draw.
	local a
	if anchor then
		a = (anchor + (math.random() * 2 - 1) * K.RIPTIDE_GAP_JITTER) % (math.pi * 2)
	else
		a = math.random() * math.pi * 2
	end
	local separation = spread + math.random() * (math.pi * 2 - 2 * spread)
	return a, (a + separation) % (math.pi * 2)
end
-- 22 -> 36 after the second playtest ("make the wave a little harder"): the
-- gap still opens on the player's side, just a longer sidestep - from r=40
-- up to ~25 studs instead of ~15.
K.RIPTIDE_GAP_JITTER = math.rad(36)

local function armWave(creature, def, p, state, startAt: number)
	local speed = p.speed or 24
	local inner, outer = p.inner or 10, p.outer or 76
	local gapHalf = p.gapHalf or math.rad(16)
	-- Anchor the near gap on whoever the serpent is looking at: the same
	-- `targetPos` the tail slam locks onto, read at fire time.
	local anchor = nil
	if state.targetPos then
		local dx, dz = state.targetPos.X - state.center.X, state.targetPos.Z - state.center.Z
		if dx * dx + dz * dz > 1 then
			anchor = math.atan2(dz, dx)
		end
	end
	local gapA, gapB = Fn.riptideGaps(p.gapSpread or K.RIPTIDE_GAP_SPREAD, anchor)
	Fn.brineHazards(creature).wave = {
		start = startAt,
		speed = speed,
		inner = inner,
		outer = outer,
		gapA = gapA,
		gapB = gapB,
		gapHalf = gapHalf,
		hit = {},
		p = p,
	}
	fireEvent("serpentWave", state.center, {
		start = startAt,
		speed = speed,
		inner = inner,
		outer = outer,
		gapA = gapA,
		gapB = gapB,
		gapHalf = gapHalf,
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
	-- WHERE THE RING IS, from the shared helper and nowhere else: nil once it
	-- has passed `outer`, which is also the frame the client stops drawing it.
	local ring = BrinejawPath.waveRing(wave.start, wave.speed, wave.inner, wave.outer, now)
	if not ring then
		creature.brine.wave = nil
		return
	end
	local cover = brineCover(creature, def)
	local lo, hi = Fn.bossRoll(creature, def, wave.p.damage)
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid and humanoid.Health > 0 and not wave.hit[player] then
			-- THE FRAME THE RING CROSSES THEIR OWN RADIUS, once. No height
			-- band anywhere in this test: the wave is taller than a jump on
			-- purpose, and it always will be.
			if ring >= Fn.brineRadiusOf(state, root.Position) then
				wave.hit[player] = true
				if
					not BrinejawPath.waveSafe(wave.gapA, wave.gapB, wave.gapHalf, cover, state.center, root.Position)
				then
					PlayerService.damage(player, math.random(lo, hi), creature, { bypassIframe = true })
					-- OUTWARD, along the ring's own radius - the sea is going
					-- out, so it carries you out with it. A player caught at
					-- the tower's foot is thrown toward open beach rather than
					-- into the masonry.
					local out = Vector3.new(root.Position.X - state.center.X, 0, root.Position.Z - state.center.Z)
					local dir = if out.Magnitude > 0.01 then out.Unit else Vector3.xAxis
					Fn.shoveAlong(root.Position, dir, wave.p.push or 46, 0.5)
				end
			end
		end
	end
end

K.ATTACK_HANDLERS.riptide = {
	windup = function(creature, def, p, _u, _sub)
		local a = creature.attack
		if a.aimed then
			return
		end
		a.aimed = true
		local state = Fn.colossusState(creature, def)
		-- ARMED ON THE FIRST WINDUP FRAME, TO START WHEN THE WINDUP ENDS.
		-- `start` is a server clock, so the client has the whole windup to
		-- draw the sea gathering at the tower's foot and to lay the two gaps'
		-- foam markers down BEFORE the ring moves: the read starts before the
		-- water does, which is the only reason a 24-stud/second ring is fair.
		armWave(creature, def, p, state, Workspace:GetServerTimeNow() + p.windup)
	end,
	fire = function(creature, def, p, _now, _root)
		-- A zero-windup row could reach the strike unarmed; this cannot be
		-- reached twice (aimSweep's rule, and for the same reason).
		K.ATTACK_HANDLERS.riptide.windup(creature, def, p, 0, 0)
	end,
	-- No `strike`: the crossing is resolved by updateBrineHazards, which runs
	-- in every mode. `duration` on the row only has to be long enough that the
	-- attack does not end absurdly before the water does; the ring's real
	-- clock is (outer - inner) / speed, and it is the same clock on both
	-- sides.
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
		-- 1.1 -> 0.75 with the row (contract §5): the default is the row's
		-- twin, and moving one without the other would let a book that omits
		-- the field draw markers the damage no longer follows.
		fall = p.fall or 0.75,
		radius = p.radius or 7,
	}
	local hazards = Fn.brineHazards(creature)
	hazards.rain = { chunks = BrinejawPath.rainChunks(payload), radius = payload.radius, p = p, fired = {} }
	fireEvent("serpentRain", state.center, payload)
end

-- One frame of any bombardment: every chunk whose impact has arrived and has
-- not been spent yet. Shared by masonryrain and the surge's derived rain,
-- because they ARE the same shape - `surgeRain` only builds the payload.
local function stepRainRun(creature, def, state, run, now: number): boolean
	local lo, hi = Fn.bossRoll(creature, def, run.p.damage)
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

K.ATTACK_HANDLERS.masonryrain = {
	windup = function(creature, def, p, _u, _sub)
		local a = creature.attack
		if a.aimed then
			return
		end
		a.aimed = true
		local state = Fn.colossusState(creature, def)
		-- FIRST IMPACT AT THE END OF THE WINDUP, which puts each chunk's
		-- ground marker (`fall` ahead of its own impact) inside the windup:
		-- the markers ARE the telegraph, and they are drawn from this table.
		armRain(creature, def, p, state, Workspace:GetServerTimeNow() + p.windup)
	end,
	fire = function(creature, def, p, _now, _root)
		K.ATTACK_HANDLERS.masonryrain.windup(creature, def, p, 0, 0)
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
	Fn.brineHazards(creature).rings = { payload = payload, p = p, hit = {} }
	fireEvent("serpentRings", state.center, payload)
end

local function stepRings(creature, def, state, now: number)
	local rings = creature.brine and creature.brine.rings
	if not rings then
		return
	end
	local payload = rings.payload
	local lo, hi = Fn.bossRoll(creature, def, rings.p.damage)
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
					local r = Fn.brineRadiusOf(state, root.Position)
					if math.abs(r - radius) < payload.band * 0.5 and Fn.brineGrounded(state, root.Position) then
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

K.ATTACK_HANDLERS.belltoll = {
	windup = function(creature, def, _p, u, _sub)
		local state = Fn.colossusState(creature, def)
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
		local state = Fn.colossusState(creature, def)
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
		Fn.colossusState(creature, def).attackU = 1
	end,
	recover = function(creature, def, _p, _u, _sub)
		local state = Fn.colossusState(creature, def)
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
K.LUNGE_FALL = 0.30 -- seconds of U 0.35 -> 0.50, the descent
K.LUNGE_SETTLE = 0.35 -- seconds of U 0.50 -> 0.72, the skull settling
K.LUNGE_CLIMB = 0.85 -- seconds of U 0.72 -> 1, the peel back up the tower

-- The farthest living player past `minRange`, or the farthest one at all if
-- everybody is inside it (a party that has crowded the tower still gets
-- lunged at - the move is a punish, not a refusal).
function Fn.farthestPlayerRoot(from: Vector3, minRange: number): BasePart?
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
function Fn.setBrineAim(state, at: Vector3)
	local dx, dz = at.X - state.center.X, at.Z - state.center.Z
	local r = math.sqrt(dx * dx + dz * dz)
	if r < 1e-3 then
		return
	end
	local clamped = math.clamp(r, BrinejawPath.AIM_MIN, BrinejawPath.AIM_MAX)
	state.aimX, state.aimZ = dx / r * clamped, dz / r * clamped
end

K.ATTACK_HANDLERS.serpentlunge = {
	windup = function(creature, def, p, u, _sub)
		local state = Fn.colossusState(creature, def)
		state.attackKind = "lunge"
		-- U 0 -> LUNGE_COCK_U across the windup: the whole tracking window.
		state.attackU = u * BrinejawPath.LUNGE_COCK_U
		local root = Fn.farthestPlayerRoot(state.center, p.minRange or 25)
		if root then
			Fn.setBrineAim(state, root.Position)
		end
	end,
	fire = function(creature, def, p, _now, _root)
		local a = creature.attack
		local state = Fn.colossusState(creature, def)
		-- AIM FREEZES HERE, at LUNGE_COCK_U, and this is the last write to it.
		-- The client draws its countdown ring from the same two numbers, so a
		-- late correction would move the ring people are standing out of.
		local root = Fn.farthestPlayerRoot(state.center, p.minRange or 25)
		if root then
			Fn.setBrineAim(state, root.Position)
		end
		a.hold = p.hold or 4.0
		a.landed = false
		state.attackU = BrinejawPath.LUNGE_COCK_U
	end,
	strike = function(creature, def, p, now, _dt, _u, _root, _sub)
		local a = creature.attack
		local state = Fn.colossusState(creature, def)
		-- U FROM ELAPSED TIME, not from the engine's `u`, because the four
		-- segments have wildly different rates and the middle one is a HOLD.
		-- The row's `duration` must be hold + K.LUNGE_FALL + K.LUNGE_SETTLE +
		-- K.LUNGE_CLIMB, which is where its "hold + 1.5" comment comes from.
		local t = now - a.phaseStart
		local cock, impact = BrinejawPath.LUNGE_COCK_U, BrinejawPath.LUNGE_IMPACT_U
		local held = 0.72 -- the top of the punish window, from the header
		if t < K.LUNGE_FALL then
			state.attackU = cock + (impact - cock) * (t / K.LUNGE_FALL)
		elseif t < K.LUNGE_FALL + K.LUNGE_SETTLE then
			state.attackU = impact + (held - impact) * ((t - K.LUNGE_FALL) / K.LUNGE_SETTLE)
		elseif t < K.LUNGE_FALL + K.LUNGE_SETTLE + a.hold then
			state.attackU = held
		else
			local climb = (t - K.LUNGE_FALL - K.LUNGE_SETTLE - a.hold) / K.LUNGE_CLIMB
			state.attackU = held + (1 - held) * math.clamp(climb, 0, 1)
		end
		-- THE BLOW, at LUNGE_IMPACT_U. `lungeHits` reads the same U and the
		-- same Aim the client's shrinking ring does, and the radius comes from
		-- the path module - never from this row - so the disc that hurts and
		-- the disc that was drawn are one circle.
		if not a.landed and state.attackU >= impact then
			a.landed = true
			local lo, hi = Fn.bossRoll(creature, def, p.damage)
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
		-- the sand, `Fn.placeColossus` has already parked the authority model on
		-- it (`creature.pos = headPosition` IS `lungeHeadPosition`), and the
		-- chip scaling steps aside while this is true. Recomputed every frame
		-- rather than latched, so no exit - a stagger, a death, an interrupted
		-- attack - can leave it stuck open.
		creature.lungeOpen = state.attackU >= impact and state.attackU <= held
	end,
	finish = function(creature, def, _p, _now)
		creature.lungeOpen = false
		Fn.colossusState(creature, def).attackU = 1
	end,
	recover = function(creature, def, _p, _u, _sub)
		local state = Fn.colossusState(creature, def)
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
K.ATTACK_HANDLERS.serpentundertow = {
	windup = function(creature, def, _p, u, _sub)
		local a = creature.attack
		local state = Fn.colossusState(creature, def)
		if not a.aimed then
			a.aimed = true
			-- FROZEN AT U = 0, which for this kind means the moment the attack
			-- is chosen: the body has to unwind a turn and a half of coil to
			-- get under the sand, and an aim that kept tracking through that
			-- would drag the whole buried run sideways.
			local at = state.targetPos
			if at then
				Fn.setBrineAim(state, at)
			end
		end
		-- The kind is not on yet: the windup is the body diving, which the
		-- `undertow` pose's own entry ramp (30% of U) performs. Peel the tail
		-- off the tower so the dive has something to dive with.
		state.unwind = math.max(state.unwind or 0, u * 0.6)
	end,
	fire = function(creature, def, _p, _now, _root)
		local state = Fn.colossusState(creature, def)
		state.attackKind = "undertow"
		state.attackU = 0
		creature.attack.hit = {}
	end,
	strike = function(creature, def, p, _now, _dt, u, _root, _sub)
		local a = creature.attack
		local state = Fn.colossusState(creature, def)
		state.attackU = u
		local lo, hi = Fn.bossRoll(creature, def, p.damage)
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
					Fn.shoveAlong(root.Position, if out.Magnitude > 0.01 then out.Unit else Vector3.xAxis, 34, 0.4)
				end
			end
		end
	end,
	finish = function(creature, def, p, _now)
		local state = Fn.colossusState(creature, def)
		-- THE ERUPTION at the far end of the run, which is what makes the
		-- bulge a threat you have to leave rather than one you outwalk.
		state.attackU = 1
		local at, _ = BrinejawPath.undertowPoint(state)
		local lo, hi = Fn.bossRoll(creature, def, p.damage)
		damagePlayersInRadius(at, p.radius or 14, lo, hi, creature, 0.4)
		fireEvent("slam", at, { radius = p.radius or 14 })
	end,
	recover = function(creature, def, _p, _u, _sub)
		local state = Fn.colossusState(creature, def)
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
K.SURGE_TAIL = 0.35 -- seconds at U = 1 before the window opens; see below

local function armSurge(creature, _def, p, state, startAt: number)
	local payload = {
		start = startAt,
		duration = p.duration,
		floodR = p.floodR or 46,
		seed = math.random(1, 2147483000),
	}
	local rainPayload = BrinejawPath.surgeRain(payload)
	Fn.brineHazards(creature).surge = {
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
	local lo, hi = Fn.bossRoll(creature, def, p.damage)
	local floodR = surge.payload.floodR
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid and humanoid.Health > 0 then
			local r = Fn.brineRadiusOf(state, root.Position)
			if r > floodR then
				PlayerService.damage(player, math.random(lo, hi), creature, { bypassIframe = true })
				-- SHOVED INWARD, toward the band they are supposed to be
				-- standing in. The flood is a boundary, not a kill box.
				local inward = Vector3.new(state.center.X - root.Position.X, 0, state.center.Z - root.Position.Z)
				if inward.Magnitude > 0.01 then
					Fn.shoveAlong(root.Position, inward.Unit, p.shove or 30, 0.5)
				end
			end
		end
	end
end

K.ATTACK_HANDLERS.tidalsurge = {
	windup = function(creature, def, _p, u, _sub)
		local state = Fn.colossusState(creature, def)
		state.attackKind = "rear"
		-- U 0 -> 0.5 across the windup: REAR_U is 0.30, so it reaches full
		-- height part-way through and holds the rest, which reads as the body
		-- standing up and then GATHERING.
		state.attackU = u * 0.5
		state.aimX, state.aimZ = 0, 0 -- `rear` rears on the bearings it has
	end,
	fire = function(creature, def, p, _now, _root)
		local state = Fn.colossusState(creature, def)
		state.attackU = 0.5
		armSurge(creature, def, p, state, Workspace:GetServerTimeNow())
	end,
	strike = function(creature, def, p, now, _dt, _u, _root, _sub)
		local a = creature.attack
		local state = Fn.colossusState(creature, def)
		local t = now - a.phaseStart
		local fall = math.max(p.duration - K.SURGE_TAIL, 1e-3)
		-- HELD AT 0.5 for the flood, then U 0.5 -> 1 to come down. It reaches
		-- 1 with K.SURGE_TAIL to spare, and those frames are the whole point:
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
			-- fighting it for the body. Fn.openStagger retires the attack and
			-- switches the mode, which is why this is safe to call from a
			-- strike (the engine only touches the orphaned attack table
			-- afterwards) and would NOT be from a recover.
			state.attackKind = ""
			state.attackU = 0
			Fn.openStagger(creature, def, now, p.stagger or 8)
		end
	end,
	finish = function(creature, def, _p, _now)
		-- Only reached if the strike ran out without opening the window (a
		-- duration shorter than K.SURGE_TAIL, or a death mid-set-piece).
		local state = Fn.colossusState(creature, def)
		state.attackU = 1
	end,
	recover = function(creature, def, _p, _u, _sub)
		local state = Fn.colossusState(creature, def)
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
function Fn.polypSites(creature, def, count: number): { Vector3 }
	local state = Fn.colossusState(creature, def)
	local arena = def.islandId and BossArenas.items[def.islandId]
	local sites = {}
	for _, piece in (arena and arena.cover or {}) do
		local offset = piece.offset or Vector3.zero
		-- Just outside the rock rather than inside it, so a polyp is never
		-- buried in the geometry that made it a landmark.
		local out = Vector3.new(offset.X, 0, offset.Z)
		local push = if out.Magnitude > 0.01 then out.Unit * ((piece.radius or 3) + 2.5) else Vector3.new(3, 0, 0)
		local at = state.center + offset + push
		table.insert(sites, Vector3.new(at.X, state.center.Y + BrinejawPath.sandY(Fn.brineRadiusOf(state, at)), at.Z))
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
				local lo, hi = Fn.bossRoll(creature, def, p.damage)
				damagePlayersInRadius(entry.position, p.radius or 10, lo, hi, creature, 0.5)
				-- The heal, as a fraction of MAX health so it does not shrink
				-- as the fight goes on - a heal that scales with what is left
				-- would be meaningless by the time it mattered.
				local heal = (p.heal or 0.035) * creature.maxHealth
				creature.health = math.min(creature.maxHealth, creature.health + heal)
				creature.model:SetAttribute(ATTR.HEALTH, creature.health)
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

K.ATTACK_HANDLERS.serpentpolyps = {
	windup = function(creature, def, _p, u, _sub)
		-- No pose kind: the serpent does not change shape to grow these, and
		-- an attack kind with no ATTACK entry would pose nothing anyway. The
		-- coils grind, which is the tail coming a little off the tower.
		local state = Fn.colossusState(creature, def)
		state.unwind = math.max(state.unwind or 0, u * 0.35)
	end,
	fire = function(creature, def, p, _now, _root)
		local state = Fn.colossusState(creature, def)
		local row = Creatures.items.brine_polyp
		if not row then
			return
		end
		local deadline = Workspace:GetServerTimeNow() + (p.deadline or 12)
		local entries, positions = {}, {}
		for _, at in Fn.polypSites(creature, def, p.count or 3) do
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
		Fn.brineHazards(creature).polyps = { entries = entries, deadline = deadline, p = p }
		fireEvent("serpentPolyps", state.center, { deadline = deadline, positions = positions })
	end,
	-- Resolved by updateBrineHazards for the next twelve seconds, while the
	-- boss goes on attacking: the party has to answer the polyps AND the book
	-- at the same time, which is the whole cost of the mechanic.
}

-- ----------------------------------------------------------- the geysers
--
-- STANCE-1 PRESSURE, AND THE FIGHT'S ANSWER TO STANDING STILL. Eight columns
-- of brine come up through the sand one every `interval`, and every one of
-- them is placed near where a LIVE PLAYER WAS STANDING when the move began.
--
-- THE WHOLE LIST IS PRECOMPUTED HERE AND SENT (contract §2), which is the one
-- place this boss's events break their own "derive, never send" rule - and it
-- has to be. Everything else Brinejaw scatters is scattered by the shared LCG
-- off a seed, because both sides can run the same generator; player positions
-- are SERVER-ONLY, so a client handed a seed could not reproduce a single
-- burst. Sending the placements is therefore not a shortcut, it is the only
-- way the thing you dodge and the thing you see can be one list.
--
-- AND THE LIST IS DELIBERATELY STALE. It is drawn once, at fire time, and
-- never re-aimed: the later bursts land where you WERE, so the move rewards
-- walking and punishes parking. A tracked version of this would be a
-- five-second sustained AoE nobody can leave.
-- VOLLEYS THAT FOLLOW. The first design placed every burst at fire time
-- around where players WERE ("deliberately stale", so you could walk out of
-- it); the user's verdict was that the spikes should hunt them. So the run is
-- now dealt in short volleys - `volley` bursts each - and every volley is
-- re-aimed at the players' LIVE positions when it is armed. Each marker still
-- leads its burst by `lead`, so the dodge is "move off the marked spot": the
-- rocks come to you, but never faster than you can read them.
K.GEYSER_LEAD_VEL = 0.5

function Fn.armGeysers(creature, def, p, state, startAt: number, remaining: number?)
	local total = math.clamp(math.floor(p.count or 8), 1, 24)
	local volley = math.clamp(math.floor(p.volley or total), 1, total)
	local count = math.min(volley, remaining or total)
	local interval = p.interval or 0.7
	local scatter = p.scatter or 10
	-- The live roots, taken ONCE: re-reading Players inside the loop would
	-- make the eight bursts follow whoever happened to die part-way through.
	local roots = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid and humanoid.Health > 0 then
			table.insert(roots, { pos = root.Position, vel = root.AssemblyLinearVelocity })
		end
	end
	if #roots == 0 then
		return
	end
	local lead = p.lead or 0.9
	local bursts = {}
	for i = 1, count do
		local pick = roots[math.random(#roots)]
		-- AIMED AHEAD OF A RUNNING PLAYER. The second playtest asked for the
		-- rocks to "follow the user better": with the burst placed on the
		-- position alone, a player already running in a straight line was
		-- never inside the mark by the time it erupted, so the move read as
		-- chasing where they had been. Leading by half the marker's lead
		-- (K.GEYSER_LEAD_VEL x `lead` seconds of flat velocity) puts the mark
		-- where a straight run ENDS UP, so the honest dodge is to change
		-- direction - and a standing player is still aimed at exactly.
		local flat = Vector3.new(pick.vel.X, 0, pick.vel.Z)
		local from = pick.pos + flat * (K.GEYSER_LEAD_VEL * lead)
		-- UNIFORM IN AREA, not in radius: a uniform draw on the offset piles
		-- the bursts onto the player's own feet (area grows with r^2), and a
		-- move that always lands on you is not a move you can walk out of.
		local angle = math.random() * math.pi * 2
		local off = scatter * math.sqrt(math.random())
		local x, z = from.X + math.cos(angle) * off, from.Z + math.sin(angle) * off
		-- Grounded on the beach profile, because the damage circle is a sphere
		-- test and a burst floating at a root's Y would miss anybody crouched
		-- on the sand under it.
		local r = Fn.brineRadiusOf(state, Vector3.new(x, state.center.Y, z))
		bursts[i] = {
			pos = Vector3.new(x, state.center.Y + BrinejawPath.sandY(r), z),
			at = startAt + (i - 1) * interval,
		}
	end
	Fn.brineHazards(creature).geysers = {
		bursts = bursts,
		radius = p.radius or 6,
		p = p,
		fired = {},
		-- What is still owed after this volley; stepGeysers re-arms the next
		-- one from fresh positions when this one has fully fired.
		remaining = (remaining or total) - count,
	}
	fireEvent("serpentGeysers", state.center, {
		start = startAt,
		count = count,
		interval = interval,
		radius = p.radius or 6,
		-- HOW FAR EACH MARKER LEADS ITS OWN BURST, and the countdown ends AT
		-- the burst rather than at the end of the windup - the same rule the
		-- slam marker's `duration` follows. Sent rather than assumed, so a
		-- retune of `lead` moves the drawn warning with the damage.
		lead = p.lead or 0.9,
		bursts = bursts,
		islandId = def.islandId,
	})
end

function Fn.stepGeysers(creature, def, _state, now: number)
	local run = creature.brine and creature.brine.geysers
	if not run then
		return
	end
	local lo, hi = Fn.bossRoll(creature, def, run.p.damage)
	local pending = false
	for index, burst in run.bursts do
		if not run.fired[index] then
			if now >= burst.at then
				run.fired[index] = true
				damagePlayersInRadius(burst.pos, run.radius, lo, hi, creature, 0.5)
			else
				pending = true
			end
		end
	end
	if not pending then
		if run.remaining > 0 then
			-- Next volley, aimed at where the players are NOW. Its first burst
			-- lands `lead` seconds out so the marker gets its full lead.
			local state = Fn.colossusState(creature, def)
			Fn.armGeysers(creature, def, run.p, state, now + (run.p.lead or 0.9), run.remaining)
		else
			creature.brine.geysers = nil
		end
	end
end

K.ATTACK_HANDLERS.serpentgeysers = {
	windup = function(creature, def, p, u, _sub)
		local a = creature.attack
		local state = Fn.colossusState(creature, def)
		-- The coils grind and the tail comes a little off the tower - the same
		-- shape the polyps use, and for the same reason: nothing about this
		-- move is expressible as one of the ten pose attributes, so the body
		-- only has to look like it is doing work.
		state.unwind = math.max(state.unwind or 0, u * 0.35)
		if a.aimed then
			return
		end
		a.aimed = true
		-- ARMED ON THE FIRST WINDUP FRAME with the first burst at the windup's
		-- END. `lead` is 0.9 and the row's windup is 1.2, so burst 1's marker
		-- lands 0.3 s into the windup and gets its full lead; a row that ever
		-- sets windup < lead would draw the first marker in the past.
		Fn.armGeysers(creature, def, p, state, Workspace:GetServerTimeNow() + p.windup)
	end,
	fire = function(creature, def, p, _now, _root)
		K.ATTACK_HANDLERS.serpentgeysers.windup(creature, def, p, 1, 0)
	end,
	-- Resolved by updateBrineHazards; see the note on riptide.
}

-- ------------------------------------------------------------ the spines
--
-- A RADIAL VOLLEY WITH SAFE LANES (contract §3). Ten spines leave the tower
-- along ten evenly spaced bearings at once and fly outward at 55 studs a
-- second; the ground BETWEEN the lanes is untouched. The answer is not to be
-- somewhere else, it is to be in a GAP - and the gaps are 220 of the ring's
-- 360 degrees, which is what makes a volley this fast fair.
--
-- NOTHING BUT `bearing0` IS SENT ABOUT THE LANES. Lane k's centre is
-- bearing0 + k * (2*pi/lanes) on both sides, so ten bearings never travel the
-- wire and can never disagree. Grounded or airborne makes no difference: this
-- one is not jumped, and there is no height band in the test.
function Fn.armSpines(creature, def, p, state, startAt: number)
	local payload = {
		start = startAt,
		-- Rolled ONTO the tracked player's bearing when there is one, so the
		-- volley is a question asked of somebody: the lane you are standing in
		-- is the lane you have to leave.
		bearing0 = state.faceAngle or 0,
		lanes = math.clamp(math.floor(p.lanes or 10), 2, 24),
		laneHalf = p.laneHalf or math.rad(7),
		speed = p.speed or 55,
		reach = p.reach or 70,
		islandId = def.islandId,
	}
	local at = state.targetPos
	if at then
		local to = at - state.center
		if to.Magnitude > 0.01 then
			payload.bearing0 = math.atan2(to.Z, to.X)
		end
	end
	Fn.brineHazards(creature).spines = { payload = payload, p = p, hit = {} }
	fireEvent("serpentSpines", state.center, payload)
end

-- ------------------------------------------------------------- combos
--
-- TWO ATTACKS AT ONCE, SOMETIMES (user, 2026-09-09: "as the fight progresses
-- the boss is able to do multiple attacks at once... somewhat rare but
-- possible"). The attack slot is single - one pose, one AttackKind - so a
-- combo is never two POSES. It is whatever attack is beginning with a HAZARD
-- attack started underneath it: the wave, the masonry, the geysers and the
-- spines all resolve in updateBrineHazards on their own clocks, independent
-- of `creature.attack`, which is exactly why "the water outlives the move"
-- already worked. Each has its own slot in `creature.brine`, so two can
-- coexist; the same hazard is never doubled (its slot is checked).
--
-- Rarity rides the stance: the row gives a chance per phase index, and a
-- combo cooldown keeps a lucky streak from chaining. The secondary's own
-- cooldown is stamped as if it had been picked normally, so the pool does
-- not owe a second copy right after. Its telegraph starts `delay` after the
-- primary's, so the two reads arrive as two things and not one blur.
K.COMBO_ARMS = {
	riptide = function(creature, def, p, state, at)
		armWave(creature, def, p, state, at)
	end,
	masonryrain = function(creature, def, p, state, at)
		armRain(creature, def, p, state, at)
	end,
	geysers = function(creature, def, p, state, at)
		Fn.armGeysers(creature, def, p, state, at)
	end,
	spines = function(creature, def, p, state, at)
		Fn.armSpines(creature, def, p, state, at)
	end,
}
K.COMBO_SLOT = { riptide = "wave", masonryrain = "rain", geysers = "geysers", spines = "spines" }

function Fn.rollCombo(creature, def, primary: string, now: number)
	local combo = def.combo
	if not combo or not def.entrenched then
		return
	end
	if (creature.comboReadyAt or 0) > now then
		return
	end
	local hpFraction = creature.health / creature.maxHealth
	local chance = combo.chance[bossPhaseIndex(def, hpFraction)] or 0
	if chance <= 0 or math.random() >= chance then
		return
	end
	-- Candidates: hazard secondaries the current phase already offers, not
	-- the primary, off cooldown, and not already running.
	local offered = {}
	for _, name in Fn.bossPhaseAttacks(def, hpFraction) do
		offered[name] = true
	end
	local hazards = creature.brine or {}
	local pool = {}
	for _, name in combo.secondaries do
		local p = def.attacks[name]
		local ready = (creature.cooldowns and creature.cooldowns[name] or 0) <= now
		if
			p
			and K.COMBO_ARMS[name]
			and name ~= primary
			and offered[name]
			and ready
			and not hazards[K.COMBO_SLOT[name]]
		then
			table.insert(pool, name)
		end
	end
	if #pool == 0 then
		return
	end
	local name = pool[math.random(#pool)]
	local p = def.attacks[name]
	local state = Fn.colossusState(creature, def)
	K.COMBO_ARMS[name](creature, def, p, state, Workspace:GetServerTimeNow() + p.windup + (combo.delay or 0.6))
	creature.cooldowns = creature.cooldowns or {}
	creature.cooldowns[name] = now + p.cooldown
	creature.comboReadyAt = now + (combo.cooldown or 20)
end

function Fn.stepSpines(creature, def, state, now: number)
	local run = creature.brine and creature.brine.spines
	if not run then
		return
	end
	local payload = run.payload
	if now >= payload.start + payload.reach / math.max(payload.speed, 1e-3) then
		creature.brine.spines = nil
		return
	end
	local lo, hi = Fn.bossRoll(creature, def, run.p.damage)
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid and humanoid.Health > 0 and not run.hit[player] then
			-- THE SHARED LANE TEST, and the ONE call that decides it. The
			-- payload goes in whole so the helper reads `lanes`, `laneHalf`,
			-- `speed`, `reach` and `start` from the same table the client was
			-- sent - a hand-rolled bearing loop here is exactly the "one value,
			-- two homes" fault BrinejawPath's header exists to forbid.
			if BrinejawPath.spineHits(payload, state.center, root.Position, now) then
				run.hit[player] = true
				PlayerService.damage(player, math.random(lo, hi), creature, { bypassIframe = true })
			end
		end
	end
end

K.ATTACK_HANDLERS.serpentspines = {
	windup = function(creature, def, p, u, _sub)
		local a = creature.attack
		local state = Fn.colossusState(creature, def)
		-- The body rears its spines: the tail comes off the tower, and the
		-- lanes are drawn on the sand for the whole windup.
		state.unwind = math.max(state.unwind or 0, u * 0.5)
		if a.aimed then
			return
		end
		a.aimed = true
		-- The lanes leave WHEN THE WINDUP ENDS, so the drawn lanes and the
		-- flying spines are the same ten bearings and the windup is the read.
		Fn.armSpines(creature, def, p, state, Workspace:GetServerTimeNow() + p.windup)
	end,
	fire = function(creature, def, p, _now, _root)
		K.ATTACK_HANDLERS.serpentspines.windup(creature, def, p, 1, 0)
	end,
	-- Resolved by updateBrineHazards; see the note on riptide.
}

-- ----------------------------------------------------------- the coilslam
--
-- A MID-BODY LOOP RISES OFF THE TOWER AND CRASHES ALONG ONE LINE THROUGH IT,
-- and then it LIES THERE. The line is a corridor, so you step sideways off it
-- rather than running from it; the loop on the sand afterwards is a FULL
-- punish window on the body, no bait required.
--
-- THE SHAPE OF U, from the contract and not from taste:
--   0    .. 0.40  the loop rises, the line marker live
--   0.40 .. 0.50  the crash; THE BLOW LANDS AT 0.50
--   0.50 .. 0.85  the fallen loop lies across the arena - THE MELEE WINDOW,
--                 full damage, proxy parked on `coilslamPoint`
--   0.85 .. 1     recover, the loop peels back onto the tower
--
-- The windup drives 0 -> 0.40 and the strike owns the rest - and the strike
-- drives U FROM ELAPSED TIME rather than from the engine's `u`, for the same
-- reason the lunge does: the middle segment is a HOLD, and four segments with
-- wildly different rates cannot share one linear ramp.
K.COILSLAM_RISE_U = 0.40 -- the loop is up; the crash starts here
K.COILSLAM_IMPACT_U = 0.50 -- THE BLOW
K.COILSLAM_HELD_U = 0.85 -- the top of the melee window; hold U here
K.COILSLAM_CRASH = 0.22 -- seconds of U 0.40 -> 0.50, the fall
K.COILSLAM_SETTLE = 0.30 -- seconds of U 0.50 -> 0.85, the loop laying out
K.COILSLAM_CLIMB = 0.70 -- seconds of U 0.85 -> 1, the peel back up

K.ATTACK_HANDLERS.serpentcoilslam = {
	windup = function(creature, def, p, u, _sub)
		local a = creature.attack
		local state = Fn.colossusState(creature, def)
		state.attackKind = "coilslam"
		-- U 0 -> K.COILSLAM_RISE_U across the whole windup: the rise IS the
		-- windup, so the loop is at full height exactly as the crash begins.
		state.attackU = u * K.COILSLAM_RISE_U
		if a.aimed then
			return
		end
		a.aimed = true
		-- LATCHED ON THE FIRST WINDUP FRAME. The line runs THROUGH the tower,
		-- so re-aiming mid-windup would swivel a 100-stud corridor across the
		-- whole beach while the party is reading the one it was shown. Only
		-- the BEARING of Aim is used (the contract: magnitude unused), but the
		-- aim is written through the same clamp everything else uses so the
		-- ten attributes stay one channel.
		local at = state.targetPos
		if at then
			Fn.setBrineAim(state, at)
		else
			state.aimX = math.cos(state.faceAngle or 0) * BrinejawPath.AIM_MAX
			state.aimZ = math.sin(state.faceAngle or 0) * BrinejawPath.AIM_MAX
		end
		a.bearing = math.atan2(state.aimZ or 0, state.aimX or 0)
		-- THE COUNTDOWN ENDS AT THE BLOW, not at the end of the windup. The
		-- crash is K.COILSLAM_CRASH past the windup's end, and a marker that
		-- closed early would invite players back onto the line 0.22 s before
		-- a loop of serpent landed on it.
		local now = Workspace:GetServerTimeNow()
		fireEvent("serpentCoilslam", state.center, {
			start = now,
			bearing = a.bearing,
			impactAt = now + p.windup + K.COILSLAM_CRASH,
			islandId = def.islandId,
		})
	end,
	fire = function(creature, def, p, _now, _root)
		local a = creature.attack
		local state = Fn.colossusState(creature, def)
		K.ATTACK_HANDLERS.serpentcoilslam.windup(creature, def, p, 1, 0)
		a.hold = p.hold or 4.5
		a.landed = false
		state.attackU = K.COILSLAM_RISE_U
	end,
	strike = function(creature, def, p, now, _dt, _u, _root, _sub)
		local a = creature.attack
		local state = Fn.colossusState(creature, def)
		local t = now - a.phaseStart
		local rise, impact, held = K.COILSLAM_RISE_U, K.COILSLAM_IMPACT_U, K.COILSLAM_HELD_U
		if t < K.COILSLAM_CRASH then
			state.attackU = rise + (impact - rise) * (t / K.COILSLAM_CRASH)
		elseif t < K.COILSLAM_CRASH + K.COILSLAM_SETTLE then
			state.attackU = impact + (held - impact) * ((t - K.COILSLAM_CRASH) / K.COILSLAM_SETTLE)
		elseif t < K.COILSLAM_CRASH + K.COILSLAM_SETTLE + a.hold then
			state.attackU = held
		else
			local climb = (t - K.COILSLAM_CRASH - K.COILSLAM_SETTLE - a.hold) / K.COILSLAM_CLIMB
			state.attackU = held + (1 - held) * math.clamp(climb, 0, 1)
		end
		if not a.landed and state.attackU >= impact then
			a.landed = true
			local lo, hi = Fn.bossRoll(creature, def, p.damage)
			for _, player in Players:GetPlayers() do
				local character = player.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if root and humanoid and humanoid.Health > 0 then
					-- THE LINE BAND, from the path module: within `girth` of
					-- the line through the tower on the aim bearing, between
					-- the radii the loop actually spans. Same function the
					-- client draws the corridor from.
					if BrinejawPath.coilslamHits(state, root.Position, p.girth or 5.0) then
						PlayerService.damage(player, math.random(lo, hi), creature, { bypassIframe = true })
					end
				end
			end
		end
		-- THE MELEE WINDOW, recomputed every frame rather than latched, so no
		-- exit - a stagger, a death, an interrupted attack - can leave it
		-- stuck open. `Fn.placeColossus` reads this to park the hittable proxy
		-- on the fallen loop, and `punishOpen` reads it to lift the chip
		-- scaling, exactly as the lunge's plant does.
		creature.coilOpen = state.attackU >= impact and state.attackU <= held
	end,
	finish = function(creature, def, _p, _now)
		creature.coilOpen = false
		-- U TO 1 FIRST, published this frame with the kind still set: the loop
		-- is half-way back onto the tower here and clearing now would snap it.
		Fn.colossusState(creature, def).attackU = 1
	end,
	recover = function(creature, def, _p, _u, _sub)
		local state = Fn.colossusState(creature, def)
		state.attackKind = ""
		state.attackU = 0
		state.aimX, state.aimZ = 0, 0
	end,
}

-- --------------------------------------------------------------- the bite
--
-- THE ONE MOVE IN THE BOOK THAT IS NOT ON A ROTATION. It is not in any phase
-- list; the entrenched tick fires it when somebody has been parked inside
-- `reach` of the tower for longer than `dwell` (see Fn.updateBoss's brinejaw
-- branch), on its own ~9 s cooldown, in any stance.
--
-- WHY IT HAS TO EXIST. The tower foot is the safest ground on the beach and
-- nothing was asking anything of it: the whip cannot reach inside SWEEP_INNER
-- (13), the riptide's ring launches at 10, the masonry's sector starts at 12
-- and the bell's rings are nil under radius 4. A party that stood at the
-- masonry could ignore a third of the book.
--
-- AND IT PAYS FOR ITSELF. U 0.45..0.75 leaves the head hanging LOW where you
-- are standing - damageable at full rate, `biteHeadPoint` under the proxy -
-- so taking the bite on purpose is a real, tight play rather than a mistake.
--
--   0    .. 0.30  rear
--   0.30 .. 0.45  the snap; THE BLOW LANDS AT 0.45
--   0.45 .. 0.75  the head hangs low - the mini punish window
--   0.75 .. 1     recover
K.BITE_REAR_U = 0.30
K.BITE_IMPACT_U = 0.45
K.BITE_HELD_U = 0.75
K.BITE_SNAP = 0.16 -- seconds of U 0.30 -> 0.45, the snap
K.BITE_SETTLE = 0.20 -- seconds of U 0.45 -> 0.75, the head coming to rest
K.BITE_CLIMB = 0.55 -- seconds of U 0.75 -> 1, back onto the coil

K.ATTACK_HANDLERS.serpentbite = {
	windup = function(creature, def, p, u, _sub)
		local a = creature.attack
		local state = Fn.colossusState(creature, def)
		state.attackKind = "bite"
		state.attackU = u * K.BITE_REAR_U
		-- TRACKED THROUGH THE WHOLE REAR, unlike every other aim in this book,
		-- and that is the point: the windup is 0.7 s and the target is inside
		-- 14 studs. A latched aim at that range would be dodged by one step,
		-- which would make the punishment for camping the tower nothing at all.
		--
		-- AND THE CLAMP IS CORRECT HERE, not merely tolerated. `setBrineAim`
		-- pushes the aim out to AIM_MIN = 16 so the neck never threads the
		-- masonry, and the row's `reach` is 14 - so a camper standing at r =
		-- 10..14 has the snap point 2..6 studs beyond them, well inside the
		-- 9-stud footprint. Nobody can be nearer than the spire's own 8.5-stud
		-- radius at the sand, so the worst case is 7.5 studs of offset against
		-- 9 of reach and the bite always lands on the person it answered.
		local at = state.targetPos
		if at then
			Fn.setBrineAim(state, at)
		end
		if a.aimed then
			return
		end
		a.aimed = true
		local now = Workspace:GetServerTimeNow()
		fireEvent("serpentBite", state.center, {
			-- ARENA-LOCAL, the same frame Aim itself is written in, so the
			-- marker and the attribute channel cannot drift apart.
			aim = Vector3.new(state.aimX or 0, 0, state.aimZ or 0),
			-- THROUGH the snap, not up to it: the blow is K.BITE_SNAP past the
			-- windup's end.
			impactAt = now + p.windup + K.BITE_SNAP,
			radius = p.radius or 9,
			islandId = def.islandId,
		})
	end,
	fire = function(creature, def, p, _now, _root)
		local a = creature.attack
		local state = Fn.colossusState(creature, def)
		-- The last write to Aim. A zero-windup row could reach here unaimed.
		K.ATTACK_HANDLERS.serpentbite.windup(creature, def, p, 1, 0)
		a.hold = p.hold or 1.6
		a.landed = false
		state.attackU = K.BITE_REAR_U
	end,
	strike = function(creature, def, p, now, _dt, _u, _root, _sub)
		local a = creature.attack
		local state = Fn.colossusState(creature, def)
		local t = now - a.phaseStart
		local rear, impact, held = K.BITE_REAR_U, K.BITE_IMPACT_U, K.BITE_HELD_U
		if t < K.BITE_SNAP then
			state.attackU = rear + (impact - rear) * (t / K.BITE_SNAP)
		elseif t < K.BITE_SNAP + K.BITE_SETTLE then
			state.attackU = impact + (held - impact) * ((t - K.BITE_SNAP) / K.BITE_SETTLE)
		elseif t < K.BITE_SNAP + K.BITE_SETTLE + a.hold then
			state.attackU = held
		else
			local climb = (t - K.BITE_SNAP - K.BITE_SETTLE - a.hold) / K.BITE_CLIMB
			state.attackU = held + (1 - held) * math.clamp(climb, 0, 1)
		end
		if not a.landed and state.attackU >= impact then
			a.landed = true
			local lo, hi = Fn.bossRoll(creature, def, p.damage)
			for _, player in Players:GetPlayers() do
				local character = player.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if root and humanoid and humanoid.Health > 0 then
					if BrinejawPath.biteHits(state, root.Position, p.radius or 9) then
						PlayerService.damage(player, math.random(lo, hi), creature, { bypassIframe = true })
					end
				end
			end
		end
		-- The mini punish window; same rules as the coilslam's, same reason
		-- for being recomputed rather than latched.
		creature.biteOpen = state.attackU >= impact and state.attackU <= held
	end,
	finish = function(creature, def, _p, _now)
		creature.biteOpen = false
		Fn.colossusState(creature, def).attackU = 1
	end,
	recover = function(creature, def, _p, _u, _sub)
		local state = Fn.colossusState(creature, def)
		state.attackKind = ""
		state.attackU = 0
		state.aimX, state.aimZ = 0, 0
	end,
}

-- ONE FRAME OF EVERYTHING BRINEJAW HAS LEFT LYING AROUND. Run from
-- `Fn.placeColossus`, so it ticks in every mode this boss can be in - attacking,
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
	-- the right phase instead of at the right elapsed time. `Fn.placeColossus`
	-- reasons in `os.clock()`, which is a completely different epoch: using
	-- the number it is holding would compare two clocks that share nothing
	-- but a unit, and every ring, chunk and deadline here would resolve
	-- either instantly or never.
	local now = Workspace:GetServerTimeNow()
	stepWave(creature, def, state, now)
	stepRings(creature, def, state, now)
	stepSurge(creature, def, state, now)
	stepPolyps(creature, def, now)
	-- The two the second pass added, and they belong here for the same reason
	-- everything above does: the geysers' eight bursts run 5.6 s past a 1.2 s
	-- windup and the spines outlive their own 1.6 s strike, so a handler that
	-- resolved either would silently drop its tail the moment the next move
	-- began.
	Fn.stepGeysers(creature, def, state, now)
	Fn.stepSpines(creature, def, state, now)
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
-- `Fn.spendStone` and `Fn.openStagger` underneath it are generic and are what this
-- borrows.
K.ATTACK_HANDLERS.handfall = {
	windup = function(creature, def, p, u, _sub)
		local state = Fn.colossusState(creature, def)
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
			-- target instead of 60-70 degrees past it. `K.HANDFALL_IMPACT`
			-- is where in the swing the blow lands, so the point marked here
			-- is where the fist will BE then - not where it starts.
			a.impact = pyreliskLatch(creature, def, p, "handfall", K.HANDFALL_IMPACT)
			-- The shadow on the ground, for the whole lead time. `slam` is a
			-- real telegraph branch on the client (a pulsing ring at the
			-- radius); an unknown kind would degrade to a 3-stud sparkle,
			-- which on a blow this size is no warning at all.
			-- IT RUNS TO THE BLOW, not to the middle of the strike. The
			-- shadow used to be told `duration * 0.5` while the fist lands at
			-- K.HANDFALL_IMPACT (0.95): on the row's 1.4s strike the mark
			-- finished 0.63s BEFORE the hand arrived, so the last thing the
			-- telegraph did was tell you it was over while the blow was still
			-- coming. Same constant the damage reads, for the same reason it
			-- is a named constant at all.
			fireEvent("telegraph", a.impact, {
				kind = "slam",
				radius = p.radius,
				duration = p.windup + p.duration * K.HANDFALL_IMPACT,
				skin = "lava",
			})
		end
		state.attack = "handfall"
		state.blend = u
		state.strike = 0
		-- THE SEAMS SPLIT AS IT COMMITS. handfall does not go through
		-- `Fn.pyreliskWindupPose` - it predates it and is declared above it - so
		-- it opens its own, off the same row field and the same latched
		-- `aimSide` the other four use.
		Fn.pyreliskOpenSeams(state, p)
	end,
	-- `now` IS `_now` NOW. This handler's only use of the clock was the two
	-- `Fn.openStagger` calls the bait used to make, and act 1 has no window to
	-- open any more - see the bait below. Underscored rather than deleted: the
	-- five pyrelisk strike handlers share one signature, and a short one here
	-- would be the odd row out for no gain.
	strike = function(creature, def, p, _now, _dt, u, _root, _sub)
		local state = Fn.colossusState(creature, def)
		local a = creature.attack
		state.strike = u
		-- The blow lands when the ARM does. This used to fire at 0.45, which
		-- is 0.77s before the pose brings the fist down - the shockwave went
		-- off while the hand was still 235 studs in the air and 60 studs
		-- outside the arena.
		if a.fired or u < K.HANDFALL_IMPACT then
			return
		end
		a.fired = true
		local lo, hi = Fn.bossRoll(creature, def, p.damage)
		damagePlayersInRadius(a.impact, p.radius, lo, hi, creature, 0.35, K.BOSS_HEIGHT_TOLERANCE)
		-- `strikeHit`, not `bossSlam`: there is no EVENTS.bossSlam on the
		-- client, so that call hit the catch-all and drew nothing at all.
		fireEvent("strikeHit", a.impact, { radius = p.radius, skin = "lava" })
		-- THE BAIT, RE-POINTED. It used to shatter a monolith and buy a
		-- twenty-second punish window with the arm left across the moat. There
		-- is no window to open in act 1 any more - the body is untargetable and
		-- stays that way, and the window is act 2, which is ninety seconds
		-- longer. So the bait pays SEAM METER instead: a spent monolith fills
		-- `seamCredit` of the committing flank's meter outright.
		--
		-- THE NINE STONES ALL SURVIVE, and so do `stoneReach = 30` (derived off
		-- the fist's r 188 band), `Fn.spendStone`, `Fn.regrowStones` and
		-- `Fn.restoreStones`. Every one of them still means what it meant; what
		-- changed is what the shattered rock BUYS.
		--
		-- It goes through `Fn.pyreliskMeterFill` and not through a second copy
		-- of the full-meter branch, so a bait that finishes a flank scars it by
		-- exactly the path a seam shot does - one place the mask is ever set.
		local stone = Fn.spendStone(creature, def, a.impact, p.stoneReach or 26)
		if stone and p.seamCredit then
			Fn.pyreliskMeterFill(creature, state, state.aimSide or 1, p.seamCredit)
		end
		-- NOTHING IS PLANTED BY A FIST ANY MORE. `Planted` means "which flank
		-- is the climb ramp", and in the redesigned fight that is act 3's
		-- answer and nobody else's.
		state.planted = 0
	end,
	recover = function(creature, def, _p, u, _sub)
		local state = Fn.colossusState(creature, def)
		-- ...and they seal as it takes the arm back. The other exits are swept
		-- in Fn.placeColossus; this is the ordinary one.
		Fn.pyreliskCloseSeams(state)
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
K.PY_BAND_OUT = 200.0 -- PY_CLEAR_R: the outer edge of open sky
K.PY_PATH_OUT = 232.0 -- the lip itself: the last stud anyone can stand on

-- COMMIT. Latches the pose's aim and hands back the ground point the attack
-- has just promised, clamped into the band. Called once, from a windup, and
-- never again for the life of that attack.
function pyreliskLatch(creature, def, p, poseName: string?, strikeAt: number?): (Vector3, number, number)
	local state = Fn.colossusState(creature, def)
	local angle = state.faceAngle or 0
	local radius = (K.PY_LAKE_R + K.PY_BAND_OUT) * 0.5
	local near = math.max(p.minReach or K.PY_LAKE_R, K.PY_LAKE_R)
	local far = math.min(p.maxReach or K.PY_BAND_OUT, K.PY_BAND_OUT)
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
	-- A SCARRED FLANK DOES NOT COMMIT. Breaking a flank costs the colossus the
	-- use of that arm, visibly, and that is the reward for having broken it.
	--
	-- A PREFERENCE, NOT A GATE, and the distinction is the bug one level down:
	-- with BOTH flanks scarred `Fn.pyreliskUnscarredSide` returns nil and this
	-- falls through to the geometry's own answer, because a latch that refused
	-- every side would have to return something anyway and the something would
	-- be whatever the last line happened to leave behind.
	--
	-- `ashfall` and `ventbreath` are whole-body moves and are unaffected, so a
	-- party that breaks one flank early does not run out of things to shoot.
	local unscarred = Fn.pyreliskUnscarredSide(state)
	if unscarred then
		side = unscarred
	end
	local bodyAngle = angle
	if poseName then
		local localBearing, fistRadius = PyreliskPath.fistOffset(poseName, side, strikeAt)
		bodyAngle = angle - localBearing
		-- The reach is the ARM's, not the player's distance: where the fist
		-- can be is a property of the pose.
		--
		-- AND THE CLAMP IS A RAIL, NOT THE RULE. It is supposed to be dead
		-- code: every pose that reaches this line is tuned to land inside
		-- [120, 200] on its own (handfall's fist is at r 188.04 at
		-- K.HANDFALL_IMPACT), so the number below is the pose's, unaltered.
		-- It was not always: the staged handfall landed at r 209.1 and was
		-- clamped to a flat 200 on EVERY swing - the drawn fist under the
		-- lip's undercut, the shockwave nine studs inboard of it, the impact
		-- radius never varying, and the two innermost monoliths permanently
		-- out of `stoneReach`. All of that was silent, which is why this
		-- warns now: a future pose retune that walks back out of the band
		-- should be loud on the first swing rather than quietly flattening
		-- the move again.
		local clamped = math.clamp(fistRadius, near, math.max(near, far))
		if math.abs(clamped - fistRadius) > 0.5 then
			warn(
				string.format(
					"[Pyrelisk] pose '%s' puts its fist at r %.1f, outside the [%.0f, %.0f] band - "
						.. "clamped to %.1f, so the telegraph no longer marks where the fist lands. Retune the pose.",
					poseName,
					fistRadius,
					near,
					far,
					clamped
				)
			)
		end
		radius = clamped
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
function Fn.pyreliskWindupPose(state, name: string, u: number)
	state.attack = name
	state.blend = u
	state.strike = 0
end

-- ...and the recovery, which is the same three numbers unwound. Clearing
-- `attack` at the end matters: `poseFor` reads POSE[state.attack], so a name
-- left behind holds the working arm in a pose it is no longer performing.
function Fn.pyreliskRecoverPose(state, u: number)
	-- The shell seals the moment the recover starts: an open seam is a "shoot
	-- me now" and the blow is already spent. Every other way out of an attack
	-- is swept in Fn.placeColossus - see `Fn.pyreliskCloseSeams`.
	Fn.pyreliskCloseSeams(state)
	state.blend = 1 - u
	state.strike = 1 - u
	if u >= 1 then
		state.attack = ""
	end
end

-- Shortest signed way from `from` to `to`, in radians.
function Fn.pyreliskWrap(a: number): number
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
K.ATTACK_HANDLERS.rimsweep = {
	windup = function(creature, def, p, u, _sub)
		local state = Fn.colossusState(creature, def)
		local a = creature.attack
		if not a.aimed then
			a.aimed = true
			-- Latched WITH the pose, so the drawn arm is on the bearing that
			-- is about to be dangerous rather than 70 degrees behind it: the
			-- rake's fist sits `fistOffset` round the body's own facing, the
			-- same correction handfall makes.
			local _, angle = pyreliskLatch(creature, def, p, "rimsweep", 0)
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
			a.inner = math.max(p.inner or 160, K.PY_LAKE_R)
			-- RAKE_OUT, NOT REACH, and they stopped being the same number when
			-- the body was remodelled (2026-09-09). REACH is the ARM's length
			-- from its own shoulder - 150 now, down from 228 - while this
			-- clamp wants the outermost stud of PATH the fist crosses,
			-- measured from the body's axis, which is 200. Clamping with
			-- REACH would have pulled the damaged annulus in to 150, INSIDE
			-- the row's own `inner` of 160, and the rake would have swept an
			-- empty band for the rest of the fight without erroring anywhere.
			a.outer = math.min(p.radius or PyreliskPath.RAKE_OUT, PyreliskPath.RAKE_OUT)
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
			-- ...and turned onto the START of the rake rather than its
			-- middle, because that is where the arm is held for the whole
			-- windup and it is what the entry mark above is pointing at. The
			-- strike takes it from here, frame by frame, along the path this
			-- windup has just committed to.
			local fistLocal = (PyreliskPath.fistOffset("rimsweep", state.aimSide or 1, 0))
			state.aimAngle = a.startAngle - fistLocal
		end
		Fn.pyreliskWindupPose(state, "rimsweep", u)
		Fn.pyreliskOpenSeams(state, p)
	end,
	strike = function(creature, def, p, _now, dt, u, _root, _sub)
		local state = Fn.colossusState(creature, def)
		local a = creature.attack
		state.strike = u
		local from = a.angle
		a.angle = from + a.dir * (a.arc / math.max(p.duration, 1e-3)) * dt
		local step = (a.angle - from) * a.dir
		-- THE DRAWN ARM RIDES THE RAKE. This is the one place in the fight
		-- that writes `aimAngle` after the windup, it is deliberate, and
		-- PyreliskPath's CONTRACT names it as the single sanctioned case.
		-- What was latched is the PATH - a.startAngle, a.arc and a.dir, all
		-- fixed before the first frame of the strike - so the bearing being
		-- damaged right now is a pure function of the clock and nothing here
		-- reads a player. Turning the body by it is the server animating a
		-- committed swing, not re-aiming: the entry mark drawn at windup does
		-- not move, the arc does not change, and a player who runs cannot
		-- drag the arm after them. Without it the rake's damage travelled 150
		-- degrees while the drawn arm turned 26, so the thing you dodge and
		-- the thing you see agreed only at the start.
		-- Measured at THIS frame's strike fraction, not at the cached windup
		-- one: the rake's fist swings 15 degrees round the body over the
		-- course of the pose (-73.5 at s=0 to -58.7 at s=0.85), and a fixed
		-- offset would let the drawn arm lead the damage by that much.
		local fistLocal = (PyreliskPath.fistOffset("rimsweep", state.aimSide or 1, u))
		state.aimAngle = a.angle - fistLocal
		local lo, hi = Fn.bossRoll(creature, def, p.damage)
		for _, entry in Fn.livingRootsNear(state.center, a.outer + 8) do
			if not a.hit[entry.player] then
				local stood = entry.root.Position
				local to = Vector3.new(stood.X - state.center.X, 0, stood.Z - state.center.Z)
				local d = to.Magnitude
				local level = math.abs(stood.Y - state.center.Y) <= K.BOSS_HEIGHT_TOLERANCE
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
					local rel = Fn.pyreliskWrap(math.atan2(to.Z, to.X) - from) * a.dir
					if rel >= -pad and rel <= step + pad then
						a.hit[entry.player] = true
						PlayerService.damage(entry.player, math.random(lo, hi), creature, { bypassIframe = true })
					end
				end
			end
		end
	end,
	recover = function(creature, def, _p, u, _sub)
		Fn.pyreliskRecoverPose(Fn.colossusState(creature, def), u)
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
--     Fn.damagePlayersInCone gates on 12 studs of height difference - so at this
--     body's scale the cone would simply miss everyone, every time, with no
--     error anywhere;
--   * it PivotTo's the model each frame, dragging the invisible authority
--     hitbox around under a body the client draws from the pose.
-- The tick-and-pool SHAPE below is conebreath's, deliberately, so the two
-- moves stay recognisably the same move.
K.ATTACK_HANDLERS.ventbreath = {
	windup = function(creature, def, p, u, _sub)
		local state = Fn.colossusState(creature, def)
		local a = creature.attack
		if not a.aimed then
			a.aimed = true
			local _, angle = pyreliskLatch(creature, def, p)
			a.facing = Vector3.new(math.cos(angle), 0, math.sin(angle))
			-- No telegraph of its own: the row's stock `coneTell` IS this
			-- move's warning, drawn along Fn.bossFacing at the pivot, and
			-- Fn.placeColossus now holds this boss's yaw0 on the tracked player
			-- one frame ahead of this latch - so the wedge that was drawn is
			-- the wedge that burns.
		end
		Fn.pyreliskWindupPose(state, "ventbreath", u)
		Fn.pyreliskOpenSeams(state, p)
	end,
	fire = function(creature, def, p, _now, _root)
		local state = Fn.colossusState(creature, def)
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
		local state = Fn.colossusState(creature, def)
		local a = creature.attack
		state.strike = u
		local reach = p.range or p.reach or 250
		if now >= (a.nextTickAt or 0) then
			a.nextTickAt = now + (p.tick or p.tickEvery or 0.35)
			local lo, hi = Fn.bossRoll(creature, def, p.damage)
			-- From the CENTRE at path height, not from the head: the cone
			-- test is horizontal and gates on height, and the players are on
			-- the floor the lake's surface defines.
			Fn.damagePlayersInCone(state.center, a.facing, reach, p.cone or math.rad(44), false, lo, hi, creature)
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
		Fn.pyreliskRecoverPose(Fn.colossusState(creature, def), u)
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
K.ATTACK_HANDLERS.ashfall = {
	windup = function(creature, def, p, u, _sub)
		local state = Fn.colossusState(creature, def)
		local a = creature.attack
		if not a.aimed then
			a.aimed = true
			pyreliskLatch(creature, def, p)
		end
		Fn.pyreliskWindupPose(state, "ashfall", u)
		Fn.pyreliskOpenSeams(state, p)
	end,
	fire = function(creature, def, p, now, root)
		local base = K.ATTACK_HANDLERS.barrage.fire
		if base then
			base(creature, def, p, now, root)
		end
	end,
	strike = function(creature, def, _p, _now, _dt, u, _root, _sub)
		Fn.colossusState(creature, def).strike = u
	end,
	recover = function(creature, def, _p, u, _sub)
		Fn.pyreliskRecoverPose(Fn.colossusState(creature, def), u)
	end,
}

-- CROWNSHED: the head shakes and slabs of its own crown come down the ARM.
--
-- (`K.ATTACK_HANDLERS.crownshed` stood here - act 3's one aimed hazard, slabs
-- of the burning crown coming down the climb route, landings banded along the
-- limb by `Fn.pyreliskRampPoints`. It is cut with the act that was its only
-- phase pool, and its row is gone from `Bosses.items.pyrelisk.attacks` in the
-- same unit. Nothing else referenced it: `Fn.pickBossAttack` draws from the
-- phase pools and a handler nothing names is unreachable.)

-- SHARDHURL: it tears a slab off its own shell and throws it. Chip damage,
-- and the only thing in the book that reaches the outer band under the lip.
--
-- The throw is `volley`'s primitive (Fn.throwGlob: one queued rock that lands on
-- its own clock and takes the damage with it), but volley's own `fire` cannot
-- be used - it scatters around `root` at the moment of the strike, which
-- re-aims after the telegraph and cannot respect this arena's bands. So the
-- landings are chosen at WINDUP, marked there, and merely spent at `fire`.
K.ATTACK_HANDLERS.shardhurl = {
	windup = function(creature, def, p, u, _sub)
		local state = Fn.colossusState(creature, def)
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
				local d = math.clamp(out.Magnitude, K.PY_LAKE_R + 4, K.PY_PATH_OUT)
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
		Fn.pyreliskWindupPose(state, "shardhurl", u)
		Fn.pyreliskOpenSeams(state, p)
	end,
	fire = function(creature, def, p, now, _root)
		local a = creature.attack
		local state = Fn.colossusState(creature, def)
		-- FROM THE HAND THAT THREW IT. Fn.throwGlob's default origin is the
		-- pivot, which on this boss is the proxy standing in the lake at its
		-- feet: the slabs flew out of the ground while the drawn arm was
		-- cocked across the chest 333 studs up, so the one attack whose whole
		-- read is "it tears a piece off itself and throws it" showed nothing
		-- leaving it.
		--
		-- ASK THE RIG WHERE THE HAND IS, rather than rebuilding it. This used
		-- to take `fistOffset(..., 0)` - body-local polar - and push it back
		-- through `toWorld` to pick up the yaw. That was correct while
		-- `fistOffset` returned an UNCOMMITTED point; since the jointed
		-- rebuild it returns one that already carries the body's pitch and
		-- tilt (PyreliskPath's THE BODY COMMITMENT), so `toWorld` would apply
		-- that rotation a second time and the rock would leave from a hand
		-- that is not the drawn one. `fistPoint` is the drawn fist, in world,
		-- and `fire` runs on the first strike frame - which is exactly the
		-- windup's held shape, the moment of release.
		-- WHERE THE ROCK LEAVES FROM: the fist, in every act this move is cast
		-- in, which is now only 1 and 2.
		--
		-- (A `>= 3` branch stood here and took the origin from the SHOULDER
		-- instead, because act 3's colossus had no arms to throw with. The
		-- climb is cut: the phase pool that could draw this move past the arms
		-- is gone, the colossus is falling within a frame of the second arm's
		-- death, and `state.act` is never 3 on this model at all - so the
		-- branch was unreachable, and an unreachable branch about a limb that
		-- may or may not exist is exactly the kind of dead code that gets read
		-- as a live rule later. ACTS 1 AND 2 ARE BYTE-IDENTICAL either way:
		-- `state.act` is 1 or 2 through both and the test never fired in them.)
		local side = state.aimSide or 1
		local hand = PyreliskPath.fistPoint(state, side)
		for i, landing in (a.landings or {}) do
			Fn.throwGlob(
				creature,
				def,
				p,
				landing,
				(p.flight or 1.2) + (i - 1) * (p.stagger or 0.25),
				now,
				"strikeHit",
				"spine",
				nil,
				hand
			)
		end
	end,
	strike = function(creature, def, _p, _now, _dt, u, _root, _sub)
		Fn.colossusState(creature, def).strike = u
	end,
	recover = function(creature, def, _p, u, _sub)
		Fn.pyreliskRecoverPose(Fn.colossusState(creature, def), u)
	end,
}

-- --------------------------------------------- the choir swings its own limbs
--
-- THE THREE SWINGS. Until now the choir was scenery with hitboxes: every move
-- in her book spawned a telegraph somewhere on the stone and the seven limbs
-- stood there breathing while something else did the hurting. These three make
-- the limbs themselves the weapon, and none of the geometry is here - the pose,
-- the floor stripe and the hitbox all live in NoctyssPath ("the tentacles
-- attack"), derived on both sides from ONE descriptor. All this file does is
-- choose a limb, latch a point, hand the descriptor over once, and tick damage.
--
-- MIND THE TWO CLOCKS. `now` in a handler is `os.clock()`; every NoctyssPath
-- call runs on `Workspace:GetServerTimeNow()` (NoctyssPath.clock), which is the
-- one the client shares and the one every `start` is stamped from.
-- `Fn.updateNoctyss` writes the second onto `state.time` at the top of its
-- frame, so that is what goes into attackPhase / attackLive / attackHits below.
-- Feeding a handler's `now` to those would ask for the shape at a time in a
-- different epoch - the two differ by however long the server has been up.

-- WHICH LIMB SWINGS: the nearest stalk that can actually reach the point,
-- never a fallen one, never one already mid-swing (NoctyssPath.stalkBusy), and
-- - for the two heavy swings - never the MARKED one. The true lure is the
-- thing the party is hunting; a lure that hurls itself across the arena while
-- someone is lining up the shot is the fight dodging its own answer. The jab is
-- exempt: it is short, it is thrown as a punish, and it moves the lantern
-- barely further than an ordinary lean already does.
--
-- Returns the socket index and the point to latch, or nil if no limb covers it.
function Fn.pickAttackStalk(state, root: BasePart?, kind: string): (number?, Vector3?)
	if not root then
		return nil
	end
	-- ON THE FLOOR, one eye-radius up: a swing aimed at a player's chest drives
	-- the limb through the stone to get there. Latched from this, not from the
	-- root part, so the point the stripe is drawn to is the point tested.
	local aim = NoctyssPath.aimPoint(state, root.Position)
	local clock = state.time or NoctyssPath.clock()
	local best, bestDist = nil, math.huge
	for index, stalk in state.stalks do
		-- `growOf` is the regrow's gate, and it is here rather than at the four
		-- call sites for the same reason `stalkBusy` is: a pick must never hand
		-- back a limb the caller then has to check. A stalk half out of its
		-- collar cannot reach anything (the whole curve is scaled about the
		-- root), so a swing thrown from one would draw a stripe to a point the
		-- arm is nowhere near.
		if
			stalk.alive
			and NoctyssPath.growOf(state, index) >= 1
			and not NoctyssPath.stalkBusy(state, index, clock)
			and (kind == "feelerstrike" or index ~= state.trueLure)
		then
			local socket = state.center + NoctyssPath.socketPoint(index)
			local span = (aim - socket).Magnitude
			local near, far = NoctyssPath.stalkReach(state, index)
			-- COVERS IT, rather than merely "is nearest to it". `setAttack`
			-- pulls a target the arm cannot reach back inside the arm, so a
			-- stalk picked out of range would draw its stripe short of the
			-- player it was aimed at and land nothing - the one lie a telegraph
			-- is not allowed to tell.
			if span >= near and span <= far and span < bestDist then
				best, bestDist = index, span
			end
		end
	end
	return best, aim
end

-- CAN THIS MOVE BE THROWN AT ALL? A book that offers a limb swing while every
-- limb is down, busy or out of reach spends the move's whole windup + strike +
-- recover doing nothing and then sits on its cooldown - which is exactly the
-- hole `lightsweep` had, and it is several seconds of the fight standing still.
-- Asked before `Fn.beginBossAttack`, the one place a move can still be swapped.
function Fn.choirMoveReady(state, name: string, root: BasePart?): boolean
	if name == "lightsweep" then
		return Fn.pickChoirStalk(state, root) ~= nil
	end
	if name == "stalkslam" or name == "gloomscythe" or name == "feelerstrike" then
		return (Fn.pickAttackStalk(state, root, name)) ~= nil
	end
	-- THE HERDING SNAP NEEDS TWO ADJACENT LIMBS AND A HEAD THAT IS DOWN.
	-- `herdTargets` answers the first question in full - two neighbouring
	-- sockets, both alive, neither already swinging, or nil - so there is
	-- nothing to re-check at the call site. The second is `mawRise`: the snap
	-- publishes a PARTIAL rise onto that same number, so offering it while the
	-- real window is up, coming up or sinking would put two authors on the one
	-- value and read on screen as a maw that stalled half way. Any rise at all
	-- disqualifies it; a fully sunk head is exactly 0.
	if name == "herdingsnap" then
		if (state.mawRise or 0) > 0.01 then
			return false
		end
		-- AND SEVEN STALKS THAT ARE ALL THE WAY OUT. `herdTargets` picks the
		-- pair off the arena's geometry and knows about death and about being
		-- busy, but not about a regrow - so the one move whose limbs are chosen
		-- by NoctyssPath rather than by `Fn.pickAttackStalk` asks here. (The
		-- portcullis' pair is screened in `Fn.armChoirAttackAt` instead: it is
		-- a window event and never passes through this function at all.)
		if not Fn.choirGrown(state) then
			return false
		end
		return root ~= nil and (NoctyssPath.herdTargets(state, root.Position)) ~= nil
	end
	return true
end

-- ARM ONE. Called on the first windup frame of all three handlers: pick the
-- limb, latch the point, hand the same table to NoctyssPath and to every
-- client, once. Everything afterwards is derived from it on both sides.
function Fn.armChoirAttack(creature, def, kind: string, root: BasePart?)
	local state = Fn.colossusState(creature, def)
	local a = creature.attack
	-- Set even when the arming fails, so a swing that found no limb on its
	-- first frame does not re-run the search sixty times a second for the rest
	-- of a windup during which nothing has changed.
	a.armed = true
	local index, aim = Fn.pickAttackStalk(state, root, kind)
	if not index or not aim then
		return nil
	end
	-- LATCHED HERE AND NOWHERE ELSE. The point is read once, as the telegraph
	-- is drawn, and the strike, the stripe and the hit test all read this same
	-- number afterwards. A limb that tracked would make its own telegraph a
	-- lie, and in a pitch-black arena the telegraph is all a player has.
	local attack = NoctyssPath.setAttack(state, {
		kind = kind,
		index = index,
		target = aim,
		start = NoctyssPath.clock(),
		-- The sweep's other three fields (the bearing it opens on, the arc, the
		-- radius the eye drags at) are `setAttack`'s to fill, and it fills them
		-- identically from the descriptor on the client - so the only one sent
		-- is the coin flip, which cannot be derived from anything.
		dir = if kind ~= "gloomscythe" then nil elseif math.random() < 0.5 then -1 else 1,
	})
	if not attack then
		return nil
	end
	a.swingIndex = index
	a.hit = {}
	a.nextTick = 0
	-- THE ONLY THING SENT, AND IT IS SENT ONCE. NoctyssBodyController runs the
	-- pose, the floor mark and the sound off this table's `start` on the shared
	-- clock; nothing about a swing is replicated per frame, ever.
	Remotes.ChoirAttack:FireAllClients(attack)
	return attack
end

-- ONE FRAME OF A SWING: hold the limb's lean at zero, and land whatever the
-- hitbox is touching.
--
-- LEAN 0 FOR THE WHOLE ATTACK, and it is not cosmetic. `lean` swings the crook
-- onto the beam bearing, and the attack pose is SOLVED FROM the shape the stalk
-- is in - so a limb that entered a slam still leaning out of a lightsweep would
-- be posed off a curve the solver never aimed, and the eye would land off its
-- own stripe. Set rather than saved and restored: `Fn.updateChoir` eases every
-- un-attacking lean back to 0 on its own, so letting go IS the restore.
--
-- `once` is the difference between the two damage shapes. The slam and the jab
-- land at most once per player per swing - a heavy single hit that ticked would
-- be three heavy hits - and the scythe ticks on `p.tick` for as long as its eye
-- is dragging over you.
function Fn.tickChoirAttack(creature, def, p, now: number, once: boolean)
	local state = Fn.colossusState(creature, def)
	local a = creature.attack
	local index = a.swingIndex
	if not index then
		return
	end
	local clock = state.time or NoctyssPath.clock()
	-- SHOT OUT FROM UNDER ITS OWN SWING. `attackFor` retires a descriptor whose
	-- stalk is dead (and one whose time is up), so a lantern broken mid-slam
	-- stops damaging on the frame it breaks rather than at the end of the phase
	-- - which is the reward for shooting the thing that is winding up at you.
	local attack = NoctyssPath.attackFor(state, index, clock)
	if not attack then
		a.swingIndex = nil
		return
	end
	local stalk = state.stalks[index]
	if stalk then
		stalk.lean = 0
	end
	if not NoctyssPath.attackLive(attack, clock) then
		return
	end
	if not once then
		if now < (a.nextTick or 0) then
			return
		end
		-- 0.45 against Tuning's 0.35 i-frame: a tick landing inside the contact
		-- window is refused outright, so a faster interval would not be more
		-- damage, it would be a number in the book that means nothing.
		a.nextTick = now + (p.tick or 0.45)
	end
	local lo, hi = Fn.bossRoll(creature, def, p.damage)
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local playerRoot = character and character:FindFirstChild("HumanoidRootPart")
		-- NO PAD. The client draws the slam's stripe at exactly SLAM.RADIUS and
		-- the scythe's band at exactly SCYTHE.RADIUS, so stepping off what is
		-- drawn is stepping out of what is tested - exactly, not approximately.
		if
			playerRoot
			and not (once and a.hit[player])
			and NoctyssPath.attackHits(state, attack, playerRoot.Position, p.girth or 0, clock)
		then
			if once then
				a.hit[player] = true
			end
			PlayerService.damage(player, math.random(lo, hi), creature)
		end
	end
end

-- EVERY SWING RETIRED AT ONCE, and every limb put back down. `attackFor` drops
-- a descriptor whose stalk is dead or whose time is up, but nothing ever asks
-- it about a socket standing empty - so a choir withdrawn mid-swing
-- (`closeMaw`) leaves its descriptor in the pose state, and the regrow's
-- `stalk.alive = true` a few seconds later would hand the new choir a limb the
-- fight believes is still busy (and could hand it the true lure). Called from
-- both ends of that gap, which is the only gap: a boss that DIES takes its pose
-- state with it (Noctyss is not `entrenched`, so there is no collapse to hold
-- one open), and a stalk that dies alone is `attackFor`'s own case above.
function Fn.clearChoirAttacks(state)
	if not state then
		return
	end
	state.attacks = {}
	-- AND THE SNAP, which is the head's own descriptor rather than a socket's.
	-- `snapFor` retires one whose time is up, but nothing ever asks it about a
	-- head that has gone back down: a window that shuts (or a choir that
	-- regrows) mid-herd would otherwise leave `state.snap` standing, and the
	-- next frame that read it would publish a partial rise onto a maw that is
	-- not there - or bite for it.
	state.snap = nil
	for index, stalk in state.stalks do
		stalk.lean = 0
		-- AND THE RISE, which is retired here for the same reason the swings
		-- are: this is called from both ends of the gap in which a choir does
		-- not exist (`closeMaw` withdraws one, `Fn.spawnBossParts` stands the
		-- next one up), and a `grow` left half way through from the last cycle
		-- would be a stalk the fight believes is still climbing out of its
		-- collar - untargetable, unpickable for every limb move, until the next
		-- regrow happened to overwrite it. Put back to 1 (a stalk that is all
		-- the way out), which is also what every caller that never heard of a
		-- regrow reads. `creature.choirGrowAt` is the other half and is stamped
		-- fresh by the regrow itself.
		NoctyssPath.setGrow(state, index, 1)
	end
end

-- ---------------------------------------- the head throwing the limbs (2026-09-09)
--
-- TWO MOVES, ONE NEW IDEA: the head chooses the targets and the limbs deliver
-- them, in PAIRS. See NoctyssPath's "the head and the limbs together" - a
-- portcullis is two ordinary slams across the doorway, a herding snap is two
-- ordinary slams plus a bite at her own rim. Neither is a new pose and neither
-- is a new hit shape, so all that lives here is the arming and the ticking.
--
-- WHY A SLOT AND NOT `creature.attack`. Fn.armChoirAttack / Fn.tickChoirAttack
-- keep their one swing on `creature.attack` (`swingIndex`, `hit`, `nextTick`),
-- which is the engine's single attack record - and both of these moves need
-- TWO at once. The portcullis needs its two OUTSIDE a book move entirely: it
-- is a window event, and she goes on throwing book attacks while the jaw
-- shuts, so writing the door's limbs into `creature.attack` would overwrite
-- whatever swing that move is half-way through. So the three fields travel in
-- a plain table the caller owns, and these two functions are the same code
-- reading it from there.

-- Damage for a bar when the row somehow has no `stalkslam` to borrow from: a
-- portcullis IS a slam and is paid as one. A K field rather than a table built
-- per frame at the call site.
K.PORTCULLIS_FALLBACK = { damage = { 34, 40 } }

-- ARM ONE, AT AN INDEX AND A POINT THE CALLER ALREADY CHOSE. Fn.armChoirAttack
-- picks its own limb off the player; the head's two moves have theirs from
-- NoctyssPath (`flankingStalks` + `doorTargets`, `herdTargets`), which is the
-- whole point of them - the geometry is the attack. A nil index is not an
-- error: `flankingStalks` returns nil for a side with nobody left, and one bar
-- is a legitimate half-door.
-- `hold` and `pair` are the descriptor's two optional fields (NoctyssPath, "the
-- tentacles attack"), and BOTH of them exist for this function's two callers -
-- the only moves in the fight made of two slams thrown on one frame:
--
--   hold  EXTRA seconds `attackKeep` pins the landed pose before the peel front
--         starts. A herd bar passes SNAP.RISE (1.0): the funnel has to still be
--         on the stone while the mouth climbs out of the middle of it, and a V
--         visibly peeling apart as the jaws breach unmakes itself at the exact
--         moment it is needed. A door bar passes 0 - the portcullis' beat is
--         the jaw shutting, not a rise, and its bars land ON that frame.
--   pair  which of the two speaks. Two bodies firing two `slamImpact`s on one
--         frame is a doubled, phase-cancelled crack that sounds SMALLER than
--         one bar, and nothing in it says the two stripes are one move. `true`
--         on the voice, `false` (and not nil - nil means an ordinary swing,
--         which speaks) on its partner.
function Fn.armChoirAttackAt(creature, def, kind: string, index: number?, target: Vector3?, slot, hold, pair)
	if not index or not target or not slot then
		return nil
	end
	local state = Fn.colossusState(creature, def)
	-- A LIMB STILL COMING OUT OF ITS COLLAR IS NOT AVAILABLE. `Fn.pickAttackStalk`
	-- and `Fn.pickChoirStalk` screen this for the moves that pick their own limb;
	-- the head's two moves have theirs from NoctyssPath's geometry, which knows
	-- about reach and about who is busy but not about a regrow, so the screen for
	-- them is here - one gate covering both callers.
	--
	-- AND A LIMB MID-LIGHTSWEEP IS NOT AVAILABLE EITHER. `state.activeStalk`
	-- is the stalk the sweep owns for the length of its wind-up and beam, and
	-- it keeps writing that stalk's `lean` and `beamAngle` every frame. Handed
	-- the same limb as a door bar, the client pins lean = 0 and freezes
	-- beamAngle to hold the slam pose while the server sweeps on underneath -
	-- so the drawn lantern separates from the hitbox the beam is tested from
	-- (~10 studs by the end of the windup) and the light lands nowhere near
	-- where it is shown. Refusing the limb costs one bar; taking it breaks the
	-- move the player is currently reading.
	if NoctyssPath.growOf(state, index) < 1 or index == state.activeStalk then
		return nil
	end
	local attack = NoctyssPath.setAttack(state, {
		kind = kind,
		index = index,
		target = target,
		start = NoctyssPath.clock(),
		hold = hold,
		pair = pair,
	})
	if not attack then
		return nil
	end
	slot.index, slot.hit, slot.nextTick = index, {}, 0
	-- The same one-shot replication every other swing gets: NoctyssBodyController
	-- runs the pose, the floor mark and the sound off this table's `start`.
	Remotes.ChoirAttack:FireAllClients(attack)
	return attack
end

-- ONE FRAME OF ONE SLOT. Line for line Fn.tickChoirAttack's body, reading the
-- three fields off `slot` instead of off `creature.attack` - including the two
-- rules that matter: `attackFor` re-read every frame (a limb shot out from
-- under its own bar stops damaging on the frame it breaks) and NO PAD beyond
-- the row's `girth`, so what the client draws is exactly what is tested.
function Fn.tickChoirSlot(creature, def, p, slot, now: number, once: boolean)
	local index = slot and slot.index
	if not index then
		return
	end
	local state = Fn.colossusState(creature, def)
	local clock = state.time or NoctyssPath.clock()
	local attack = NoctyssPath.attackFor(state, index, clock)
	if not attack then
		slot.index = nil
		return
	end
	local stalk = state.stalks[index]
	if stalk then
		stalk.lean = 0
	end
	if not NoctyssPath.attackLive(attack, clock) then
		return
	end
	if not once then
		if now < (slot.nextTick or 0) then
			return
		end
		slot.nextTick = now + (p.tick or 0.45)
	end
	slot.hit = slot.hit or {}
	local lo, hi = Fn.bossRoll(creature, def, p.damage)
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local playerRoot = character and character:FindFirstChild("HumanoidRootPart")
		if
			playerRoot
			and not (once and slot.hit[player])
			and NoctyssPath.attackHits(state, attack, playerRoot.Position, p.girth or 0, clock)
		then
			if once then
				slot.hit[player] = true
			end
			PlayerService.damage(player, math.random(lo, hi), creature)
		end
	end
end

-- THE PORTCULLIS, ARMED. DOOR.LEAD (1.6s) before the jaw shuts, which is one
-- SLAM.WINDUP (1.2) plus SLAM.LIVE (0.4): the bars finish landing on the exact
-- frame the bite lands, so a player in the mouth reads the exit narrowing while
-- the roof comes down and has the whole windup to run the slot.
--
-- IT NEVER SEALS. `doorTargets` stands the two capsules DOOR.HALF either side
-- of the entrance lane, leaving 8 studs of walkable centreline - the punish is
-- that you have to run the middle of it, not that you are trapped.
function Fn.armPortcullis(creature, def)
	local state = Fn.colossusState(creature, def)
	local indexA, indexB = NoctyssPath.flankingStalks(state)
	if not indexA and not indexB then
		-- Silently, as far as the fight is concerned: no bars, the window runs
		-- exactly as it did before. Logged because "the door never came down"
		-- has no symptom on screen at all, and the cause is always the same
		-- one - the choir this cycle has nobody left standing near the lane.
		warn(string.format("[CreatureService] boss %q had no limb free to bar its door", def.id))
		return
	end
	local targetA, targetB = NoctyssPath.doorTargets(state)
	creature.doorSlots = { {}, {} }
	-- `flankingStalks` and `doorTargets` both return (+lateral, -lateral) in
	-- that order, which is what lets the voice be chosen by POSITION here
	-- rather than by re-deriving a side: the first is the +lateral bar, so it
	-- carries `pair = true` and sounds, and its partner carries `pair = false`
	-- and comes down silent. `hold` is 0 for both - a door bar lands on the
	-- frame the jaw shuts and has no rise to wait out.
	--
	-- THE SILENCE IS CONDITIONAL ON THE VOICE EXISTING. `armChoirAttackAt`
	-- returns nil when its limb is unusable (no index, no target, mid-regrow,
	-- mid-sweep), and a door whose A bar was refused would otherwise hand its
	-- only surviving bar a hard `pair = false` - a half-door that comes down
	-- with no slamSnuff, no slamImpact and no peel, which is indistinguishable
	-- on screen and in the ears from the door never arming at all. So the B
	-- bar is screened `false` only when there IS an A bar to be screened
	-- behind; alone, it passes nil and speaks as the ordinary swing it is.
	local voice = Fn.armChoirAttackAt(creature, def, "portcullis", indexA, targetA, creature.doorSlots[1], 0, true)
	Fn.armChoirAttackAt(
		creature,
		def,
		"portcullis",
		indexB,
		targetB,
		creature.doorSlots[2],
		0,
		(if voice then false else nil)
	)
end

-- ...AND TICKED, once per frame for as long as the window is open. `once` is
-- true: a bar is a slam, and a slam lands at most once per player per swing.
function Fn.tickPortcullis(creature, def)
	local slots = creature.doorSlots
	if not slots then
		return
	end
	local p = (def.attacks and def.attacks.stalkslam) or K.PORTCULLIS_FALLBACK
	local now = os.clock()
	Fn.tickChoirSlot(creature, def, p, slots[1], now, true)
	Fn.tickChoirSlot(creature, def, p, slots[2], now, true)
	if not slots[1].index and not slots[2].index then
		creature.doorSlots = nil
	end
end

-- ONE FRAME OF A HERDING SNAP: the two bars, and then the head.
--
-- THE PARTIAL RISE IS NOT THE PUNISH WINDOW. `state.mawRise` is published to
-- NoctyssBodyController every frame by Fn.placeColossus, and the client eases
-- toward it exactly as it does during the window - so a snap costs no new
-- replication. What it deliberately does NOT touch is `creature.mawOpen` and
-- ATTR.EXPOSED: those two are the damage window, and a mouth that breached to
-- NoctyssPath.SNAP.RISE_TO is not one. Written AFTER Fn.updateNoctyss' own rise/decay
-- for the frame, because this call hangs off Fn.updateBossAttack at the bottom
-- of that function - and skipped outright while the real window is up, so a
-- true lure broken mid-snap cannot have its rise stalled at SNAP.RISE_TO by
-- a snap that is still sinking.
--
-- MawGape is floored at 0.12 for the same frames: the client suppresses its
-- bite note under that, and a snap with no bite note is a mouth closing in
-- silence.
function Fn.tickHerd(creature, def, p, now: number)
	local state = Fn.colossusState(creature, def)
	local a = creature.attack
	if a.herd then
		Fn.tickChoirSlot(creature, def, p, a.herd[1], now, true)
		Fn.tickChoirSlot(creature, def, p, a.herd[2], now, true)
	end
	local clock = state.time or NoctyssPath.clock()
	local snap = NoctyssPath.snapFor(state, clock)
	if not snap or creature.mawOpen then
		return
	end
	state.mawRise = NoctyssPath.snapRise(snap.start, clock)
	state.mawGape = math.max(state.mawGape or 0, 0.12)
	if (NoctyssPath.snapPhase(snap.start, clock)) ~= "bite" then
		return
	end
	-- ONCE PER PLAYER PER SNAP, like the bite at the close and for the same
	-- reason: BITE is 0.3s and a disc that ticked would be three of these.
	a.snapHit = a.snapHit or {}
	local lo, hi = Fn.bossRoll(creature, def, p.damage)
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local playerRoot = character and character:FindFirstChild("HumanoidRootPart")
		if
			playerRoot
			and not a.snapHit[player]
			and NoctyssPath.snapHits(state, playerRoot.Position, p.girth or 0, clock, snap.start)
		then
			a.snapHit[player] = true
			PlayerService.damage(player, math.random(lo, hi), creature)
		end
	end
end

-- STALKSLAM: the lantern goes out, the limb rears, and the whole stalk comes
-- down along a line drawn on the stone from its own collar. A 1.2s windup
-- against a 7-stud half-width, so the answer is seven studs sideways - about
-- 0.44s at a walk of 16 - and the tell is a light dying in a room lit by seven.
K.ATTACK_HANDLERS.stalkslam = {
	windup = function(creature, def, p, _u, _sub)
		local state = Fn.colossusState(creature, def)
		if not creature.attack.armed then
			Fn.armChoirAttack(creature, def, "stalkslam", (Fn.nearestPlayerRoot(state.center)))
		end
		Fn.tickChoirAttack(creature, def, p, os.clock(), true)
	end,
	strike = function(creature, def, p, now, _dt, _u, _root, _sub)
		Fn.tickChoirAttack(creature, def, p, now, true)
	end,
	recover = function(creature, def, p, _u, _sub)
		-- Still ticked through the recovery: no damage (the descriptor's live
		-- window is long over) but the limb is still posed, and the lean has to
		-- stay pinned until it lets go of its own accord.
		Fn.tickChoirAttack(creature, def, p, os.clock(), true)
	end,
}

-- GLOOMSCYTHE: it bows until the eye is ON the stone and then walks that eye
-- around its own socket. The pool of light crawling across the floor arrives
-- before the limb does and is visible from behind as a glow rising off the
-- ground, which is what makes a 75-degree sweep dodgeable in locked first
-- person. The dodge is the radial step out of the band, not a footrace with it.
K.ATTACK_HANDLERS.gloomscythe = {
	windup = function(creature, def, p, _u, _sub)
		local state = Fn.colossusState(creature, def)
		if not creature.attack.armed then
			Fn.armChoirAttack(creature, def, "gloomscythe", (Fn.nearestPlayerRoot(state.center)))
		end
		Fn.tickChoirAttack(creature, def, p, os.clock(), false)
	end,
	strike = function(creature, def, p, now, _dt, _u, _root, _sub)
		Fn.tickChoirAttack(creature, def, p, now, false)
	end,
	recover = function(creature, def, p, _u, _sub)
		Fn.tickChoirAttack(creature, def, p, os.clock(), false)
	end,
}

-- FEELERSTRIKE: coil, spear, snap back - and it is a real limb doing it now
-- rather than a `barrage` of blind circles under everyone at once. Short enough
-- to stay a punish rather than a set piece, which is what `lurepull` follows
-- with it for.
K.ATTACK_HANDLERS.feelerstrike = {
	windup = function(creature, def, p, _u, _sub)
		local state = Fn.colossusState(creature, def)
		if not creature.attack.armed then
			Fn.armChoirAttack(creature, def, "feelerstrike", (Fn.nearestPlayerRoot(state.center)))
		end
		Fn.tickChoirAttack(creature, def, p, os.clock(), true)
	end,
	strike = function(creature, def, p, now, _dt, _u, _root, _sub)
		Fn.tickChoirAttack(creature, def, p, now, true)
	end,
	recover = function(creature, def, p, _u, _sub)
		Fn.tickChoirAttack(creature, def, p, os.clock(), true)
	end,
}

-- HERDINGSNAP: two adjacent limbs slam onto a V whose point is ON THE PIT'S
-- RIM, and then she snaps at the rim. The V does not push anyone in - it makes
-- walking in the direction that feels safest (away from the limbs, into the
-- dark middle) the thing that kills you.
--
-- THE BEAT, and every number of it is NoctyssPath's rather than this row's:
-- the bars land at SLAM.WINDUP (1.2s), the snap starts on that same frame and
-- rises for SNAP.RISE (1.0s), bites for SNAP.BITE (0.3s) and sinks for
-- SNAP.SINK (0.9s). So the tell for the bite is a full second of mouth
-- breaching out of the floor you are standing on, AFTER the bars have already
-- told you where the funnel points.
K.ATTACK_HANDLERS.herdingsnap = {
	windup = function(creature, def, p, _u, _sub)
		local state = Fn.colossusState(creature, def)
		local a = creature.attack
		if not a.armed then
			-- Set even when the arming finds nothing, so a snap that lost its
			-- limbs on the first frame does not re-run the search sixty times
			-- a second through a windup during which nothing has changed.
			a.armed = true
			a.herd = { {}, {} }
			local root = Fn.nearestPlayerRoot(state.center)
			if root then
				-- BOTH BARS FROM ONE CALL, and latched here: `herdTargets`
				-- already ran the same `clampToReach` `setAttack` will, so what
				-- it hands back IS what is drawn and tested.
				local indexA, indexB, targetA, targetB = NoctyssPath.herdTargets(state, root.Position)
				-- BOTH BARS STAY DOWN UNTIL THE MOUTH IS UP (`hold` =
				-- SNAP.RISE, 1.0s): the V is the funnel the bite is aimed
				-- into, and a funnel whose walls are peeling off the stone
				-- while the jaws climb is telling the player the move is over
				-- one full second before it is. The first bar is the voice
				-- (`pair`), so the pair cracks once instead of twice - and the
				-- second is screened `false` ONLY if that voice actually armed.
				-- A V that lost its A limb (regrow, or mid-lightsweep) would
				-- otherwise put down one silent wall, with the bite still
				-- coming and nothing in the mix saying a wall had landed.
				local hold = NoctyssPath.SNAP.RISE
				local voice = Fn.armChoirAttackAt(creature, def, "stalkslam", indexA, targetA, a.herd[1], hold, true)
				Fn.armChoirAttackAt(
					creature,
					def,
					"stalkslam",
					indexB,
					targetB,
					a.herd[2],
					hold,
					(if voice then false else nil)
				)
			end
		end
		Fn.tickHerd(creature, def, p, os.clock())
	end,
	-- THE SNAP STARTS AS THE BARS LAND. `fire` runs on the frame the windup
	-- ends, which is SLAM.WINDUP after the descriptors were stamped - so
	-- snapStart == slam start + 1.2 exactly, which is the arithmetic every
	-- dodge in this move was priced against.
	fire = function(creature, def, _p, _now, _root, _player, _dist)
		local state = Fn.colossusState(creature, def)
		local snap = NoctyssPath.setSnap(state, {
			kind = "herdingsnap",
			-- 0 and the pit's centre only so the descriptor passes the same
			-- wire validation every other one does; nothing reads either.
			index = 0,
			start = NoctyssPath.clock(),
			target = state.center,
		})
		if snap then
			-- Down the same one-shot pipe as a limb's swing: the client draws
			-- the snap ring off this table's `start`, on the shared clock.
			Remotes.ChoirAttack:FireAllClients(snap)
		end
		creature.attack.snapHit = {}
	end,
	strike = function(creature, def, p, now, _dt, _u, _root, _sub)
		Fn.tickHerd(creature, def, p, now)
	end,
	recover = function(creature, def, p, _u, _sub)
		-- The rise, the bite and the whole sink live in here: the row's
		-- recover is sized so the engine lets go on the frame `snapFor`
		-- retires the snap, and the bars' own descriptors expire under it.
		Fn.tickHerd(creature, def, p, os.clock())
	end,
}

K.ATTACK_HANDLERS.lightsweep = {
	windup = function(creature, def, p, u, _sub)
		local state = Fn.colossusState(creature, def)
		local a = creature.attack
		if not a.stalk then
			-- Picked on the first windup frame rather than at `fire`, because
			-- the lean IS the telegraph: the stalk has to start moving before
			-- the light arrives or there is nothing to read.
			local root = Fn.nearestPlayerRoot(state.center)
			a.stalk = Fn.pickChoirStalk(state, root)
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
		local state = Fn.colossusState(creature, def)
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
		local state = Fn.colossusState(creature, def)
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
		local lo, hi = Fn.bossRoll(creature, def, p.damage)
		for _, player in Players:GetPlayers() do
			local character = player.Character
			local playerRoot = character and character:FindFirstChild("HumanoidRootPart")
			if playerRoot and NoctyssPath.beamHits(state, a.stalk, playerRoot.Position, p.girth or 3.0, a.apex) then
				PlayerService.damage(player, math.random(lo, hi), creature)
			end
		end
	end,
	finish = function(creature, def, _p, _now)
		local state = Fn.colossusState(creature, def)
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
K.ATTACK_HANDLERS.lurepull = {
	windup = function(creature, def, p, u, sub)
		local a = creature.attack
		if not a.told then
			a.told = true
			local state = Fn.colossusState(creature, def)
			-- At the rim, at shelf height, for the whole wind-up: the lure
			-- flaring is the warning, and it has to be read from the floor.
			-- SHELF_Y by name rather than the 1.5 it happens to be - this and
			-- the `fire` below are the same height for the same reason, and a
			-- literal here is a number that would not move with the arena.
			fireEvent("telegraph", state.center + Vector3.new(0, NoctyssPath.SHELF_Y, 0), {
				kind = "mark",
				duration = p.windup,
				radius = NoctyssPath.PIT_R + 3,
				skin = p.skin,
			})
		end
		local base = K.ATTACK_HANDLERS.pull.windup
		if base then
			base(creature, def, p, u, sub)
		end
	end,
	-- ...AND ITS OWN `fire`, FOR THE SAME REASON THE TELEGRAPH IS OVERRIDDEN.
	-- The stock handler fires the `pull` event at `model:GetPivot().Position`,
	-- which is right for every boss whose pivot is its body - and for this one
	-- is 20 studs INSIDE the rock: `Fn.placeColossus` parks her model at
	-- `NoctyssPath.mawCFrame`, whose resting Y is MAW.Y_DOWN. So the shockwave,
	-- the dust and every other bit of the drag's feedback were rendering under
	-- the shelf, and the fight's one displacement move announced itself with
	-- nothing at all while the floor started sliding. Fired at the pit's rim
	-- instead, under the mark the wind-up just drew.
	--
	-- VISUAL ONLY, deliberately: `stepPull`'s force is flat in distance, so
	-- moving the event's origin moves what the player SEES and not a stud of
	-- what the drag does.
	fire = function(creature, def, p)
		local state = Fn.colossusState(creature, def)
		fireEvent("pull", state.center + Vector3.new(0, NoctyssPath.SHELF_Y, 0), {
			radius = p.radius,
			strength = p.strength,
			duration = p.duration,
		})
	end,
	strike = K.ATTACK_HANDLERS.pull.strike,
	finish = K.ATTACK_HANDLERS.pull.finish,
}

K.ATTACK_HANDLERS.dousehunt = {
	windup = function(creature, def, p, u, sub)
		local state = Fn.colossusState(creature, def)
		-- Out over the last third of the windup: fast enough to feel like the
		-- choir being switched off, slow enough to be a tell.
		local douse = math.clamp((u - 0.62) / 0.38, 0, 1)
		for _, stalk in state.stalks do
			if stalk.alive then
				stalk.douse = douse
			end
		end
		local base = K.ATTACK_HANDLERS.barrage.windup
		if base then
			base(creature, def, p, u, sub)
		end
	end,
	fire = function(creature, def, p, now, root)
		local state = Fn.colossusState(creature, def)
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
		local base = K.ATTACK_HANDLERS.barrage.fire
		if base then
			base(creature, def, p, now, root)
		end
	end,
	strike = function(creature, def, p, now, dt, u, root, sub)
		local base = K.ATTACK_HANDLERS.barrage.strike
		if base then
			base(creature, def, p, now, dt, u, root, sub)
		end
	end,
	finish = function(creature, def, p, now)
		local base = K.ATTACK_HANDLERS.barrage.finish
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
--     a phase, calls Fn.endBossAttack, or clears creature.attack. Every pattern
--     runs windup -> strike -> recover -> Fn.endBossAttack and therefore always
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
K.WRACK_BOUND_MARGIN = 60
K.WRACK_MUZZLE_LIFT = 5

-- ACT TWO FIRES AT FULL STRENGTH. See Fn.wrackScale: this replaces the retired
-- `windowFire` (0.3), which meant "what a skeleton crew keeps up until the decks
-- grow back" - a number that only had meaning inside a loop that came back.
K.WRACK_ACT2_FIRE = 1.0

-- THE SHOT OCCLUDER, while one is up. Held here rather than on the creature
-- because `groundParams` needs it and is handed no creature - it is a
-- module-level filter for a module-level part. Exactly one exists at a time
-- (Fn.wrackOccluder sweeps any leak before building), and Fn.wrackOccluderDrop
-- clears both the field and the part.
K.WRACK_OCCLUDER = nil

-- THE GUN DECKS ARE THE GUNS - and since 2026-09-06 that is literal: every
-- ball in the fight leaves a live battery (see Fn.wrackDeckPositions and
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
function Fn.wrackScale(creature, def, now: number): number
	local parts = def.parts
	if not parts or creature.partsAlive == nil then
		return 1
	end
	if creature.partsAlive <= 0 then
		-- ALL FOUR DOWN, AND THEY ARE NOT COMING BACK. `parts.regrow` is gone
		-- from his row, so this is not the top of a burst window any more - it
		-- is the ACT BREAK. `staggerFor` seconds of true silence while the guns
		-- die and the hull wakes...
		local downAt = creature.partsDownAt
		if not downAt or now - downAt < (def.staggerFor or 4) then
			return 0
		end
		-- ...and then ACT TWO, at FULL density. This used to return
		-- `def.windowFire` (0.3) - the thin fire of a skeleton crew holding the
		-- decks until they grew back. Nothing grows back now and nobody is
		-- working the guns: the SHIP is the emitter, firing from her ports and
		-- her own body, and she is not a remnant of act one. Returning 0.3 here
		-- would have left the whole second act at a third of its intended
		-- pressure, under a field name that described a fight that no longer
		-- exists - which is why `windowFire` was retired from the row rather
		-- than left sitting at 0.3 for this line to find.
		return K.WRACK_ACT2_FIRE
	end
	return 0.4 + 0.6 * (creature.partsAlive / math.max(parts.count, 1))
end

-- The latch. Fixes the firing bearing on the FIRST windup frame and never
-- looks again for the rest of the move (rule 1 above). Returns the bearing.
--
-- Note WHERE the fallback comes from. Fn.bossFacing() reads creature.yaw0, and
-- yaw0 is written by Fn.updateBoss's PROWL branch - which a `pose`d boss returns
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
-- opposite. A note saying "Fn.bossFacing is live for this boss", sitting beside
-- a boss for whom it is frozen, is exactly what lets the next person
-- re-introduce a frozen-bearing bug while believing they had checked.
local function wrackAim(creature): Vector3
	local a = creature.attack
	if not a then
		return Fn.bossFacing(creature)
	end
	if not a.wrackAim then
		local centre = creature.anchor or creature.pos
		local root = Fn.nearestPlayerRoot(centre)
		a.wrackAim = if root then flatUnit(root.Position - centre) else Fn.bossFacing(creature)
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
function Fn.wrackAimFrom(creature, from: Vector3): Vector3
	local a = creature.attack
	local mark = a and a.wrackMark
	if not mark then
		return wrackAim(creature)
	end
	local to = Vector3.new(mark.X - from.X, 0, mark.Z - from.Z)
	return if to.Magnitude > 0.001 then to.Unit else wrackAim(creature)
end

-- THE LIVE GUN DECKS, where they actually stand. `Fn.livingArms` is not
-- Kraken-specific despite the name - `partOf` and `socketIndex` are stamped by
-- Fn.spawnBossParts for every parts boss - so this reuses it rather than growing
-- a second parts list to keep in sync, which is the thing Fn.spawnBossParts'
-- `ringParts` comment refuses to do for exactly this reason. Sorted by socket,
-- so a wisp's round-robin is stable across volleys.
function Fn.wrackDeckPositions(creature): { Vector3 }
	local out = {}
	for _, part in Fn.livingArms(creature) do
		table.insert(out, part.pos)
	end
	-- ...AND THE WRECK'S GUNS, for the one act that has no live ones. The
	-- Admiral's duel row carries `wreckMounts` - where the sunken ship's cannons
	-- lie - so his "last broadside" leaves the same four points act one's did,
	-- resolved against the arena centre. Reached through the SAME list every
	-- other consumer already reads (the emitter's decks, `wrackDeckReach`,
	-- the tell radii), rather than by teaching each of them about act three.
	--
	-- Only ever hit when there are no living parts at all, so it cannot shadow
	-- a fight that has some.
	if #out == 0 then
		local def = bossDef(creature)
		local mounts = def and def.wreckMounts
		if mounts then
			local centre = creature.anchor or creature.pos
			for _, m in mounts do
				table.insert(out, Vector3.new(centre.X + m.X, centre.Y + m.Y, centre.Z + m.Z))
			end
		end
	end
	return out
end

-- The four decks as flat offsets from the arena centre - what a radial
-- pattern and the wisps read, and what picks the gun for an aimed one.
function Fn.wrackDeckOffsets(creature, centre: Vector3): ({ Vector3 }, { Vector3 })
	local at = Fn.wrackDeckPositions(creature)
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
function Fn.wrackGunFor(creature): (Vector3?, Vector3)
	local a = creature.attack
	local centre = creature.anchor or creature.pos
	local aim = wrackAim(creature)
	local offsets, at = Fn.wrackDeckOffsets(creature, centre)
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
	return best, Fn.wrackAimFrom(creature, best)
end

-- How far the furthest live deck stands from the centre. The ring and mark
-- tells are drawn round the muzzle LOCUS, which is no longer a circle of
-- radius `spawnAt` but that circle pushed out to each gun's own range.
function Fn.wrackDeckReach(creature): number
	local centre = creature.anchor or creature.pos
	local far = 0
	for _, world in Fn.wrackDeckPositions(creature) do
		local dx, dz = world.X - centre.X, world.Z - centre.Z
		far = math.max(far, math.sqrt(dx * dx + dz * dz))
	end
	return far
end

-- World angle of a flat bearing, in ProjectileService's convention
-- (bearing(t) = cos t, 0, sin t). Fn.bossFacing's yaw0 runs the other way.
function Fn.wrackAngle(dir: Vector3): number
	return math.atan2(dir.Z, dir.X)
end

-- Which patterns fire from ONE gun. The rest are all-round: broadside and
-- slewfire radiate from the arena centre with each ball born at the range of
-- the deck facing it, and wisps take one lantern per deck. See
-- ProjectileService's "firing from the guns" block for why the radial two
-- cannot simply be translated onto their decks.
-- `megashot` joins them: the cannon overload's payload leaves the ONE battery
-- the telegraph named, which is the entire read of the move, so it must go
-- through the aimed path or the ball would appear at the middle of the hull
-- while the disc pulsed on a gun twenty studs away. (The overload handler
-- pre-seeds `a.wrackGunAt` with that battery's own position, so wrackGunFor
-- returns the gun the tell drew on rather than picking its own.)
--
-- `anchorline` is deliberately NOT here. It is not fired from a gun at all -
-- the anchor is lobbed past the player and the hazard is born where it lands -
-- so it takes its geometry from the handler through wrackEmit's `extra`.
K.WRACK_AIMED = { grapeshot = true, chainshot = true, anchorsweep = true, megashot = true }

-- One volley out. Returns the ball count (0 when the decks are silent).
--
-- A silenced volley emits nothing and changes NOTHING else: the move still
-- completes its strike and recover and still goes on cooldown through
-- Fn.endBossAttack, so a player standing in the burst window cannot farm free
-- openings by keeping the batteries down.
-- `extra` (added 2026-09-08) is the geometry a pattern needs that is neither a
-- bearing nor a gun: the anchor line's landing point and drag direction, and
-- the server-side handle that lets its handler retire that one hazard when the
-- midlink is shot. Three named fields copied onto the ctx, not a merge, so the
-- ctx's shape stays something a reader can enumerate.
function Fn.wrackEmit(pattern: string, creature, def, p, now: number, gap: number?, phase: number?, extra): number
	local scale = Fn.wrackScale(creature, def, now)
	if scale <= 0 then
		return 0
	end
	local centre = creature.anchor or creature.pos
	local lo, hi = Fn.bossRoll(creature, def, p.damage)
	-- Registers him for the closing beat on his first volley. A plain boss
	-- gets no collapse (that is the perch-holding colossus's death), so the
	-- gun decks going up one at a time is the fight's own ending.
	-- The batteries' OWN positions, as Fn.spawnBossParts placed them (see
	-- `creature.mountAt`), so the closing explosions land on the brass.
	ProjectileService.watch(creature, centre, creature.mountAt or {}, "cannon")
	-- THE BRASS FIRES. `centre` stays the arena centre and keeps its one
	-- remaining job (it is what `bound` is measured from); `decks` and
	-- `muzzle` are where the shot actually leaves. An aimed pattern gets one
	-- gun and a bearing re-aimed from it; the rest get the whole live list.
	local decks = Fn.wrackDeckOffsets(creature, centre)
	local aim = wrackAim(creature)
	local muzzle, flash = nil, nil
	if K.WRACK_AIMED[pattern] then
		local gun, from = Fn.wrackGunFor(creature)
		if gun then
			muzzle = Vector3.new(gun.X, centre.Y, gun.Z)
			aim = from
			-- The flash at the gun's own HEIGHT - the Deck battery is 35.7
			-- studs up. The balls stay on the flat flight plane, because the
			-- hit test is flat; only the muzzle burst knows about the mortar
			-- deck it came off.
			flash = gun + Vector3.new(0, K.WRACK_MUZZLE_LIFT, 0)
		end
	end
	return ProjectileService.emit(pattern, {
		owner = creature,
		centre = centre,
		spot = extra and extra.spot,
		dir = extra and extra.dir,
		tag = extra and extra.tag,
		speed = extra and extra.speed,
		muzzle = muzzle,
		decks = decks,
		origin = flash or (creature.model:GetPivot().Position + Vector3.new(0, K.WRACK_MUZZLE_LIFT, 0)),
		aim = aim,
		gap = gap or 0,
		phase = phase,
		scale = scale,
		bound = p.bound or (def.arena.radius + K.WRACK_BOUND_MARGIN),
		now = now,
		min = lo,
		max = hi,
	}, p)
end

-- WILL THIS VOLLEY ACTUALLY FIRE? `Fn.wrackEmit` returns 0 without emitting
-- anything while `Fn.wrackScale` is 0 - the `staggerFor` seconds of true silence
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
-- (Fn.updateBoss's `now`, and `partsDownAt` in kill()), and the windup hook is
-- the one place in the handler contract that is not handed it.
function Fn.wrackWillFire(creature, def): boolean
	return Fn.wrackScale(creature, def, os.clock()) > 0
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
function Fn.wrackRingTell(creature, p, radius: number)
	fireEvent("wrackTell", creature.anchor or creature.pos, {
		shape = "ring",
		radius = radius,
		duration = p.windup,
		skin = p.skin,
	})
end

function Fn.wrackLaneTell(p, at: Vector3, aim: Vector3, width: number, length: number)
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
function Fn.wrackConeTell(p, at: Vector3, aim: Vector3, arcDeg: number, wedges: number)
	local base = Fn.wrackAngle(aim)
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
K.ATTACK_HANDLERS.broadside = {
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
		if not a.wrackTold and Fn.wrackWillFire(creature, def) then
			a.wrackTold = true
			-- Two cues, because a ring with a hole in it needs both: the ring
			-- itself (loud, and readable from any facing), then the gap. Both
			-- are drawn OUTSIDE the muzzle locus - which is no longer a plain
			-- circle of radius `spawnAt` but that circle pushed out to each
			-- live deck's own range - so the cue never lands inside the wall
			-- it is announcing.
			local mark = Fn.wrackDeckReach(creature) + (p.spawnAt or 16) + (p.markAt or 22)
			Fn.wrackRingTell(creature, p, mark)
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
		Fn.wrackEmit("broadside", creature, def, p, now, a.wrackGapAt)
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
			Fn.wrackEmit("broadside", creature, def, p, now, a.wrackGapAt)
		end
		creature.model:PivotTo(poseCFrame(creature, sub + 0.25, math.sin(now * 26) * math.rad(2), math.rad(15)))
	end,
}

-- Grapeshot: a fast aimed fan at the latched player. Punishes standing still
-- in the open - it is quick, so the dodge happens during the tell. A second
-- burst (p.bursts) reuses the SAME bearing offset half a pellet, filling the
-- first burst's lanes. p: pellets, fanDeg, speed, radius, damage, spawnAt,
-- lifetime, bursts, burstGap.
-- ==================================================== ACT THREE: THE DUEL (2026-09-09)
--
-- Five moves against the ship's fourteen, and that ratio IS the design. Two acts
-- of reading a wall of cannonballs from eighty studs away, and then the fight
-- ends in reach with a man who throws one thing at a time and means all of them.
-- Every row here is readable, answerable, and expensive to answer wrong.
--
-- They all reuse Wrack's own telegraph vocabulary (`wrackLaneTell`,
-- `wrackConeTell`, `wrackRingTell`, `telegraph`/`mark`) because the client
-- already draws exactly those and act three should feel like the same fight's
-- last act rather than a different game. Nothing new is wired.

-- THE THRUST. He latches a bearing at windup and covers `reach` studs down a
-- `lane`-wide corridor without steering. Step off the lane. Miss him and he is
-- open for `expose` seconds - the row carries `holdExpose`, so the window is
-- real rather than a beat before the next move.
K.ATTACK_HANDLERS.sabrelunge = {
	windup = function(creature, _def, p, u, sub)
		local a = creature.attack
		if not a.wrackAimed then
			a.wrackAimed = true
			wrackAim(creature)
		end
		if not a.wrackTold then
			a.wrackTold = true
			-- Drawn from HIM, along the bearing he latched, over the exact
			-- distance he will travel: the tell is the corridor.
			Fn.wrackLaneTell(p, creature.pos, wrackAim(creature), p.lane or 7, p.reach or 55)
		end
		-- Winding back onto the rear foot.
		creature.model:PivotTo(poseCFrame(creature, sub - 0.4 * u, 0, math.rad(-14) * u))
	end,
	fire = function(creature, _def, _p, now)
		local a = creature.attack
		a.wrackLungeFrom = creature.pos
		a.wrackLungeAt = now
		a.wrackLungeHit = {}
		a.wrackLungeLanded = false
	end,
	strike = function(creature, def, p, _now, _dt, u, _root, sub)
		local a = creature.attack
		local aim = wrackAim(creature)
		local travel = (p.reach or 55) * math.clamp(u, 0, 1)
		local at = (a.wrackLungeFrom or creature.pos) + aim * travel
		creature.pos = groundedPos(at, creature.halfThickness or 0)
		creature.model:PivotTo(poseCFrame(creature, sub + 1.1, 0, math.rad(10)))
		local lo, hi = Fn.bossRoll(creature, def, p.damage)
		for _, entry in Fn.livingRootsNear(creature.pos, (p.lane or 7) * 0.5 + 2) do
			if not a.wrackLungeHit[entry.player] then
				a.wrackLungeHit[entry.player] = true
				a.wrackLungeLanded = true
				PlayerService.damage(entry.player, math.random(lo, hi), creature, {})
			end
		end
	end,
	finish = function(creature, _def, p)
		local a = creature.attack
		-- A LANDED THRUST COSTS HIM NOTHING; A WHIFF COSTS HIM THE WINDOW.
		-- `expose` on the row is applied by Fn.endBossAttack unconditionally, so
		-- the punish is REMOVED here when he actually hit somebody. Without this
		-- the correct play would be to stand in the lane and eat it: take the
		-- damage, collect the free window anyway.
		if a and a.wrackLungeLanded then
			creature.exposedUntil = nil
			creature.model:SetAttribute(ATTR.EXPOSED, nil)
		end
		if p then
			creature.lungeOpen = false
		end
	end,
}

-- THE ARC. A cone at sabre length, told as a wedge. `beats` 2 sweeps back the
-- other way after `beatGap`, so phase 3's version answers "dodge once" with
-- "dodge twice, the other way".
K.ATTACK_HANDLERS.cleave = {
	windup = function(creature, _def, p, u, sub)
		local a = creature.attack
		if not a.wrackAimed then
			a.wrackAimed = true
			wrackAim(creature)
			-- Which way the first beat sweeps, latched so the tell and the
			-- damage cannot disagree about it.
			a.wrackCleaveDir = if math.random() < 0.5 then 1 else -1
		end
		if not a.wrackTold then
			a.wrackTold = true
			Fn.wrackConeTell(p, creature.pos, wrackAim(creature), p.arcDeg or 120, 3)
		end
		creature.model:PivotTo(poseCFrame(creature, sub, 0, math.rad(-11) * u))
	end,
	fire = function(creature, def, p, now)
		local a = creature.attack
		a.wrackCleaveLeft = math.max(1, p.beats or 1) - 1
		a.wrackCleaveNext = now + (p.beatGap or 0.45)
		Fn.wrackCleaveBeat(creature, def, p, wrackAim(creature))
	end,
	strike = function(creature, def, p, now, _dt, _u, _root, sub)
		local a = creature.attack
		if a.wrackCleaveLeft > 0 and now >= a.wrackCleaveNext then
			a.wrackCleaveLeft -= 1
			a.wrackCleaveNext = now + (p.beatGap or 0.45)
			-- THE SECOND BEAT IS THE FIRST ONE MIRRORED, and it is re-told:
			-- a beat the player is not warned about is a beat they cannot
			-- answer, which is the opposite of what this move is for.
			a.wrackCleaveDir = -(a.wrackCleaveDir or 1)
			Fn.wrackConeTell(p, creature.pos, wrackAim(creature), p.arcDeg or 120, 3)
			Fn.wrackCleaveBeat(creature, def, p, wrackAim(creature))
		end
		creature.model:PivotTo(poseCFrame(creature, sub + 0.5, 0, math.rad(8)))
	end,
}

-- One swing's worth of damage, in a cone about `aim`. Shared by both beats so
-- the mirrored one cannot drift from the first.
function Fn.wrackCleaveBeat(creature, def, p, aim: Vector3)
	local lo, hi = Fn.bossRoll(creature, def, p.damage)
	local half = math.rad((p.arcDeg or 120) * 0.5)
	for _, entry in Fn.livingRootsNear(creature.pos, p.reach or 22) do
		local to = entry.root.Position - creature.pos
		local flat = Vector3.new(to.X, 0, to.Z)
		if flat.Magnitude > 0.001 and math.acos(math.clamp(flat.Unit:Dot(aim), -1, 1)) <= half then
			PlayerService.damage(entry.player, math.random(lo, hi), creature, {})
		end
	end
end

-- THE RIPOSTE STANCE. The duel's signature, and the only move in the fight
-- whose answer is to do nothing.
--
-- He plants and holds guard for `hold`. `CreatureService.damage` calls
-- Fn.wrackRiposte on the first hit that lands inside the window: everything
-- within `punish` wears it and the stance REFRESHES, so panicking into it is a
-- loop you pay for repeatedly. Let it run out untouched and he over-commits -
-- the row's `expose`/`holdExpose` open the biggest window in the fight, earned
-- by putting the gun down.
--
-- READABLE, NOT A GOTCHA: the ring tell is drawn at exactly `punish`, so the
-- radius is published rather than learned by dying in it.
K.ATTACK_HANDLERS.ripostestance = {
	windup = function(creature, _def, p, u, sub)
		local a = creature.attack
		if not a.wrackTold then
			a.wrackTold = true
			Fn.wrackRingTell(creature, p, p.punish or 12)
		end
		creature.model:PivotTo(poseCFrame(creature, sub, 0, math.rad(-6) * u))
	end,
	fire = function(creature, _def, p, now)
		creature.riposteUntil = now + (p.hold or 3.5)
		creature.riposteP = p
		creature.riposteHit = false
		creature.model:SetAttribute(ATTR.WRACK_RIPOSTE, 1)
	end,
	strike = function(creature, _def, _p, _now, _dt, _u, _root, sub)
		-- Planted. He does not track, he does not step: the stance is a
		-- commitment on his side too, which is what makes ignoring it pay.
		creature.model:PivotTo(poseCFrame(creature, sub, 0, 0))
	end,
	finish = function(creature)
		creature.riposteUntil = nil
		creature.riposteP = nil
		creature.model:SetAttribute(ATTR.WRACK_RIPOSTE, nil)
		-- HE ONLY OVER-COMMITS IF HE WAS NEVER TOUCHED. `expose` on the row is
		-- applied unconditionally by Fn.endBossAttack, so a stance that DID
		-- counter has its reward taken back here - otherwise hitting him would
		-- be strictly better than not (a counter AND a free window), which is
		-- the exact inversion the move exists to prevent.
		if creature.riposteHit then
			creature.exposedUntil = nil
			creature.model:SetAttribute(ATTR.EXPOSED, nil)
		end
		creature.riposteHit = nil
	end,
}

-- The counter itself. Called from CreatureService.damage, never from a handler,
-- because it is triggered by the PLAYER rather than by the fight's clock.
function Fn.wrackRiposte(creature, now: number)
	local p = creature.riposteP
	if not p then
		return
	end
	local def = bossDef(creature)
	if not def then
		return
	end
	creature.riposteHit = true
	-- 2, HELD FOR `counterFor`. The client cannot tell "he countered you" from
	-- "the window expired untouched" off a 1 -> 0 edge, and those are the two
	-- halves of the move the player is being asked to read - so the counter is
	-- its own value rather than the absence of the stance.
	creature.model:SetAttribute(ATTR.WRACK_RIPOSTE, 2)
	-- ...AND THE STANCE REFRESHES. Shooting him is not a way to make the window
	-- shorter; it is a way to make it longer.
	creature.riposteUntil = now + (p.hold or 3.5)
	local lo, hi = Fn.bossRoll(creature, def, p.damage)
	for _, entry in Fn.livingRootsNear(creature.pos, p.punish or 12) do
		PlayerService.damage(entry.player, math.random(lo, hi), creature, {})
	end
	fireEvent("bossStagger", creature.pos, { name = def.name, duration = p.counterFor or 0.45 })
	task.delay(p.counterFor or 0.45, function()
		-- Back to 1 only if the stance is still up: `finish` may have cleared it
		-- underneath this, and re-lighting a stance that has ended would leave
		-- the client drawing a guard he is not holding.
		if creature.riposteUntil and not creature.dead and creature.model.Parent then
			creature.model:SetAttribute(ATTR.WRACK_RIPOSTE, 1)
		end
	end)
end

-- THE PISTOL. One aimed ball, fast, no tracking - the windup is the whole
-- dodge. Its tell is a MARK where the ball lands, not a lane: `sabrelunge`
-- already owns the lane, and two aimed moves wearing one telegraph shape cannot
-- be told apart, by the player or by the client choosing which gesture to draw.
K.ATTACK_HANDLERS.flintlock = {
	windup = function(creature, _def, p, u, sub)
		local a = creature.attack
		if not a.wrackAimed then
			a.wrackAimed = true
			wrackAim(creature)
		end
		if not a.wrackTold then
			a.wrackTold = true
			local mark = a.wrackMark or (creature.pos + wrackAim(creature) * 60)
			fireEvent("telegraph", groundedPos(mark, 0), {
				kind = "mark",
				radius = p.radius or 3.0,
				duration = p.windup,
				skin = p.skin,
			})
		end
		creature.model:PivotTo(poseCFrame(creature, sub, 0, math.rad(-4) * u))
	end,
	fire = function(creature, def, p, now)
		Fn.wrackEmit("grapeshot", creature, def, {
			pellets = 1,
			fanDeg = 0,
			speed = p.speed or 110,
			spawnAt = p.spawnAt or 4,
			radius = p.radius or 3.0,
			lifetime = p.lifetime or 1.6,
			damage = p.damage,
			skin = p.skin,
			bound = p.bound,
		}, now, 0, 0)
	end,
	strike = function(creature, _def, _p, _now, _dt, _u, _root, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.2, 0, math.rad(5)))
	end,
}

-- THE LAST BROADSIDE. He raises the sabre and the WRECK answers: one ring with
-- a gap, out of the drowned ship's own gun positions (`wreckMounts` on his row,
-- served through Fn.wrackDeckPositions' fallback so the emitter needs no branch).
--
-- The fight's closing rhyme. The first thing act one taught was "find the gap in
-- the ring"; the last thing act three asks is the same question, from a ship
-- that is already dead.
K.ATTACK_HANDLERS.lastbroadside = {
	windup = function(creature, _def, p, u, sub)
		local a = creature.attack
		if not a.wrackAimed then
			a.wrackAimed = true
			a.wrackGapAt = Fn.wrackAngle(wrackAim(creature))
		end
		if not a.wrackTold then
			a.wrackTold = true
			-- The ring is drawn round the WRECK, which is where the balls come
			-- from - not round him, which is where he is standing.
			Fn.wrackRingTell(creature, p, Fn.wrackDeckReach(creature) + (p.spawnAt or 16) + (p.markAt or 26))
		end
		creature.model:PivotTo(poseCFrame(creature, sub + 0.6 * u, 0, math.rad(-16) * u))
	end,
	fire = function(creature, def, p, now)
		local a = creature.attack
		Fn.wrackEmit("broadside", creature, def, p, now, a.wrackGapAt)
	end,
	strike = function(creature, _def, _p, _now, _dt, _u, _root, sub)
		creature.model:PivotTo(poseCFrame(creature, sub, 0, math.rad(6)))
	end,
}

K.ATTACK_HANDLERS.grapeshot = {
	windup = function(creature, def, p, u, sub)
		local a = creature.attack
		if not a.wrackTold and Fn.wrackWillFire(creature, def) then
			a.wrackTold = true
			-- One wedge, from the gun that is going to fire it: the fan is a
			-- wedge's width, and it leaves one battery.
			local gun, from = Fn.wrackGunFor(creature)
			Fn.wrackConeTell(p, gun or creature.model:GetPivot().Position, from, 0, 1)
		end
		creature.model:PivotTo(poseCFrame(creature, sub, 0, math.rad(-9) * u))
	end,
	fire = function(creature, def, p, now)
		local a = creature.attack
		Fn.wrackEmit("grapeshot", creature, def, p, now, 0, 0)
		a.wrackLeft = (p.bursts or 1) - 1
		a.wrackNextAt = now + (p.burstGap or 0.35)
	end,
	strike = function(creature, def, p, now, _dt, _u, _root, sub)
		local a = creature.attack
		if a.wrackLeft > 0 and now >= a.wrackNextAt then
			a.wrackLeft -= 1
			a.wrackNextAt = now + (p.burstGap or 0.35)
			Fn.wrackEmit("grapeshot", creature, def, p, now, 0, 0.5)
		end
		creature.model:PivotTo(poseCFrame(creature, sub + 0.15, 0, math.rad(6)))
	end,
}

-- Chainshot: pairs of balls linked by a spinning chain. The gap between a
-- pair LOOKS like a lane and is the hitbox; the real lane is between pairs,
-- and the spin opens and closes it on a beat you can count. p: pairs, fanDeg,
-- chain, chainRadius, spinDeg, speed, radius, damage, spawnAt, lifetime.
K.ATTACK_HANDLERS.chainshot = {
	windup = function(creature, def, p, u, sub)
		local a = creature.attack
		if not a.wrackTold and Fn.wrackWillFire(creature, def) then
			a.wrackTold = true
			-- One wedge per pair, so the tell shows where the PAIRS go and
			-- the lanes between them read as the lanes they are. Drawn from
			-- the gun the pairs actually leave, and capped at three wedges
			-- because each one is another bossTell one-shot (see above).
			local gun, from = Fn.wrackGunFor(creature)
			Fn.wrackConeTell(
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
		Fn.wrackEmit("chainshot", creature, def, p, now)
	end,
	strike = function(creature, _def, _p, now, _dt, _u, _root, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.3, math.sin(now * 18) * math.rad(2), math.rad(11)))
	end,
}

-- Slewfire: a continuous spiral streaming off a rotating deck. The deck angle
-- is the tell and the answer both - the model turns with it, so you can read
-- the rotation and walk against it to cross the arms the short way. p: arms,
-- every, spinDeg, speed, radius, damage, spawnAt, lifetime.
K.ATTACK_HANDLERS.slewfire = {
	windup = function(creature, def, p, u, sub)
		local a = creature.attack
		-- Latched even when the decks are silent: `strike` adds the spin to
		-- `a.wrackGapAt` every tick and cannot be handed a nil.
		if not a.wrackAimed then
			a.wrackAimed = true
			a.wrackGapAt = Fn.wrackAngle(wrackAim(creature))
		end
		if not a.wrackTold and Fn.wrackWillFire(creature, def) then
			a.wrackTold = true
			-- The annulus has to cover the whole muzzle locus, which runs from
			-- `spawnAt` out to `spawnAt` + the furthest live deck's range.
			fireEvent("telegraph", creature.anchor or creature.pos, {
				kind = "ringTell",
				duration = p.windup,
				radius = Fn.wrackDeckReach(creature) + (p.spawnAt or 14) + 4,
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
			Fn.wrackEmit("slewfire", creature, def, p, now, a.wrackGapAt)
			a.wrackGapAt += a.wrackSpin * every
		end
		-- THE HULL DOES NOT TURN WITH THE GUNS, and must not. This used to feed
		-- `-a.wrackGapAt - creature.yaw0` into poseCFrame's yawOffset, which
		-- ADDS to yaw0 - a full revolution of the drawn ship every 4-5 seconds,
		-- dragging the four drawn cannons the player aims at (the upright
		-- rebuild's Bow / Starboard / Stern / Port, WrackBodyController.PIECES)
		-- away from the four `wrack_battery` hitboxes, which `parts.at =
		-- "mounts"` resolved ONCE against yaw0 at spawn and which never move.
		-- The old careened mesh's `Wrack_Battery*` objects are gone with it;
		-- the trap is not, and is worse on a 41-stud hull whose mounts are only
		-- 10.9 studs apart. His row
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
K.ATTACK_HANDLERS.wisps = {
	windup = function(creature, def, p, u, sub)
		local a = creature.attack
		if not a.wrackTold and Fn.wrackWillFire(creature, def) then
			a.wrackTold = true
			wrackAim(creature)
			-- The ring they are born from, which is now the DECKS' ring: one
			-- lantern lifts off each live battery, so the mark has to reach
			-- the furthest of them or it points at empty hull.
			fireEvent("telegraph", creature.anchor or creature.pos, {
				kind = "mark",
				duration = p.windup,
				radius = Fn.wrackDeckReach(creature) + (p.spawnAt or 12),
				skin = p.skin,
			})
		end
		creature.model:PivotTo(poseCFrame(creature, sub - 0.35 * u, 0, math.rad(-7) * u))
	end,
	fire = function(creature, def, p, now)
		Fn.wrackEmit("wisps", creature, def, p, now)
	end,
}

-- Anchorsweep: the one big telegraph. A heavy arc across half the arena, the
-- balls overlapping into a wall you cannot thread - the answer is the OTHER
-- half, and the long windup exists so you can get there. `ripple` gives one
-- end a head start so the arc visibly sweeps, which also leaves the trailing
-- end passable for a beat if you commit to it. p: count, arcDeg, speed,
-- radius, damage, spawnAt, lifetime, ripple.
K.ATTACK_HANDLERS.anchorsweep = {
	windup = function(creature, def, p, u, sub)
		local a = creature.attack
		if not a.wrackTold and Fn.wrackWillFire(creature, def) then
			a.wrackTold = true
			-- THE ONE BIG TELEGRAPH, and the one pattern that can arrive from
			-- the camera's rear blind spot. So it gets a RING first - drawn
			-- around the player's own ground, legible whichever way they face
			-- - and then a lane naming the half about to become a wall.
			local gun, from = Fn.wrackGunFor(creature)
			Fn.wrackRingTell(creature, p, Fn.wrackDeckReach(creature) + (p.spawnAt or 16) + (p.tellReach or 30))
			Fn.wrackLaneTell(p, gun or creature.model:GetPivot().Position, from, p.tellWidth or 96, p.tellRange or 90)
		end
		local e = smoothstep(u)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.9 * e, 0, math.rad(-24) * e))
	end,
	fire = function(creature, def, p, now)
		Fn.wrackEmit("anchorsweep", creature, def, p, now)
	end,
	strike = function(creature, _def, _p, _now, _dt, u, _root, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.9 * (1 - u), 0, math.rad(26) * (1 - u)))
	end,
}

-- ---------------------------------------------------- Wrack: the five new verbs (2026-09-08)
--
-- Nine rows of balls is ONE verb - read the shape, walk to the hole - and a
-- verb is finished the moment it is learned. Five of the nine were retired
-- (see the boss row's header) and these five mechanics took their place. Each
-- one asks for something walking cannot answer:
--
--   powderrun      a fuse-lit keg homes on you; SHOOT it, and where you shoot
--                  it is the move (it detonates at its own position).
--   ghostbraziers  three pillars charge a floor-wide wave; each one you DOUSE
--                  opens the sector behind it as the only safe ground.
--   cannonoverload one named battery winds up a mega-shot; enough damage into
--                  THAT battery during the windup jams it entirely.
--   anchorline     a chain drags back across the sand as a moving LINE; leave
--                  by its end, or break its shootable midlink.
--   longboat       a boarding party marches AT the hull to repair a gun deck;
--                  the fight inverts and his health gate becomes yours.
--
-- FOUR OF THE FIVE PUT A SHOOTABLE OBJECT ON THE SAND, and every one of them
-- is an ordinary creature row (Creatures.items.wrack_*) rather than a new kind
-- of object, because "shootable" in this engine means "creature": targeting,
-- the hit test, the damage numbers and the health bar all come for free.
--
-- THEY DO NOT CARRY `partOf`, AND THAT IS LOAD-BEARING. `kill()` decrements
-- `owner.partsAlive` for ANY creature carrying `partOf`, with no test for what
-- kind of part it is - so a keg or a brazier adopted into the parts ring would
-- count DOWN the four gun decks as it died. Three braziers doused would open
-- the hull's burst window without a single battery being broken, and the
-- fight's whole gate would be bypassable by shooting scenery. So these props
-- are tracked in the handler's own state (`creature.attack.*`) or on
-- `creature.wrackKit`, and their deaths are noticed by POLLING them, which
-- costs one table lookup per prop per frame and cannot corrupt anything.
--
-- EVERY PROP IS SPAWNED WITH A `lifetime`, always longer than the mechanic
-- that owns it. That is the backstop against the one failure this design can
-- have: a fight that ends underneath a mechanic (the boss killed mid-charge,
-- the party wiping, the arena abandoned) leaving props standing on the beach
-- with nothing left to update them. The linger sweep collects them.

-- One prop. `p.rows` names the row in the brood handler's idiom - and in the
-- plural even for a single row, because tools/check_content.py validates
-- `rows = { ... }` against Creatures.items and does not look at a singular
-- `row =`. The warn is the other half of that: a row that vanishes from under
-- a book at runtime should say so, not spawn nothing quietly.
function Fn.wrackProp(creature, p, at: Vector3, life: number)
	local rowId = p.rows and p.rows[1]
	local row = if rowId then Creatures.items[rowId] else nil
	if not row then
		warn(
			string.format("[CreatureService] wrack move %q names unknown row %q", tostring(p.handler), tostring(rowId))
		)
		return nil
	end
	local model = CreatureService.spawn(row, at, nil, "Neutral", {
		noLinger = true,
		suppressDrops = true,
		bounty = 0.25,
		lifetime = life,
		-- The party's scaling, exactly as the batteries inherit it: a prop that
		-- stayed solo-sized while the fight scaled would make every one of
		-- these mechanics EASIER per head as the party grew.
		healthMult = creature.extra and creature.extra.healthMult,
	})
	local prop = byModel[model]
	if prop then
		prop.pos = at
		model:PivotTo(restCFrame(prop))
	end
	return prop
end

-- Is this prop still standing? The whole "was it shot?" test, and it asks
-- about the MODEL as well as the flag because a prop can also leave through
-- despawn (its lifetime, the owner's teardown), which sets neither.
function Fn.wrackPropLive(prop): boolean
	return prop ~= nil and not prop.dead and prop.model.Parent ~= nil
end

-- Move a prop, and return where it actually ended up. Grounded every frame
-- rather than once: the Careenage's sand rises 4.4 studs from rim to head, and
-- a keg that kept its spawn height would be knee-deep by the time it crossed.
--
-- `yaw` (optional, world radians in Fn.bossFacing's convention - `restCFrame`
-- feeds it straight to CFrame.Angles) turns the prop as well as moving it. The
-- three props that had this function before it existed all travel as blobs and
-- pass nil; the figurehead is a FIGUREHEAD, and one that flew sideways down its
-- own lane would read as a bug in the mesh rather than as a dive. Written onto
-- `yaw0` because that is the field `restCFrame` reads - the alternative, a
-- second rotation applied here, would be a heading the record does not know
-- about and every other placement of that prop would silently undo it.
--
-- `lift` (optional) holds the prop that many studs ABOVE the grounding, for the
-- two pieces that do not travel on the sand: the figurehead flies and the boom's
-- tackle swings. It is applied after the grounding rather than instead of it, so
-- a flying piece still follows the shoal's 4.4-stud rise instead of drifting into
-- it - the same reason the grounding is per-frame in the first place.
function Fn.wrackPlaceProp(prop, at: Vector3, yaw: number?, lift: number?): Vector3?
	if not Fn.wrackPropLive(prop) then
		return nil
	end
	if yaw then
		prop.yaw0 = yaw
	end
	local rest = groundedPos(at, prop.halfThickness or 0)
	prop.pos = if lift then rest + Vector3.new(0, lift, 0) else rest
	prop.model:PivotTo(restCFrame(prop))
	return prop.pos
end

-- The two lists that outlive the attack that made them: runners burn an
-- eight-second fuse and boarders march for eleven, both longer than any
-- windup->recover the phase machine will hold open. Everything else the five
-- mechanics own lives on `creature.attack` and dies with it.
function Fn.wrackKit(creature)
	local kit = creature.wrackKit
	if not kit then
		kit = { runners = {}, boarders = {} }
		creature.wrackKit = kit
	end
	return kit
end

-- The keg going off. `atFuse` is the difference between the two ways it can
-- end, and it is the whole risk curve: a keg you SHOT bursts at 15 studs
-- wherever it happened to be, so killing it across the beach costs nothing and
-- killing it at arm's length costs you; a keg whose fuse RAN OUT bursts at 20,
-- centred on the player it had caught up with, and there is no dodge left
-- because the dodge was the eight seconds already spent.
function Fn.wrackKegBlast(creature, run, now: number, atFuse: boolean)
	local at = run.at
	local radius = if atFuse then run.blastFuse else run.blast
	run.done = true
	damagePlayersInRadius(at, radius, run.min, run.max, creature, 0.5, K.BOSS_HEIGHT_TOLERANCE)
	fireEvent("decoyPop", at, { radius = radius, skin = run.skin })
	if Fn.wrackPropLive(run.prop) then
		CreatureService.despawn(run.prop.model)
	end
	-- SYMPATHETIC DETONATION, phase 3's whole addition to the move: a blast
	-- lights any other keg within `chainAt`, and the chained one goes off where
	-- IT is (the small radius) rather than on anybody's feet. Scheduled a beat
	-- later instead of recursing, so a cluster pops as a run of bangs rather
	-- than one frame's worth of stacked damage - and so this cannot re-enter
	-- itself while the caller is walking the same list.
	if (run.chainAt or 0) > 0 then
		for _, other in Fn.wrackKit(creature).runners do
			if other ~= run and not other.done and not other.popAt then
				local dx, dz = other.at.X - at.X, other.at.Z - at.Z
				if math.sqrt(dx * dx + dz * dz) <= run.chainAt then
					other.popAt = now + 0.18
					other.popFuse = false
				end
			end
		end
	end
end

-- Give a gun deck a quarter of its bar back. The lowest one, deliberately: a
-- boarder that arrives should undo the party's most recent work, so the repair
-- is felt as a setback on the battery they were about to break rather than
-- spent invisibly on one already at full.
--
-- WITH EVERY BATTERY DOWN THIS DOES NOTHING AND RETURNS FALSE, which is the
-- burst window's guarantee: bringing a gun deck back inside the one beat of
-- the fight the party earned by silencing all four would take the reward away
-- after it had been given.
function Fn.wrackRepair(creature, fraction: number): boolean
	local best = nil
	for _, part in Fn.livingArms(creature) do
		if best == nil or part.health < best.health then
			best = part
		end
	end
	if not best then
		return false
	end
	local amount = math.max(1, math.floor(best.maxHealth * fraction + 0.5))
	best.health = math.min(best.maxHealth, best.health + amount)
	-- The replicated number, kept in step by hand because this is the one place
	-- in the file that RAISES a creature's health and CreatureService.damage
	-- (which owns the pairing everywhere else) cannot express a heal.
	best.model:SetAttribute(ATTR.HEALTH, best.health)
	fireEvent("strikeHit", best.pos, { radius = 8, skin = "wreck" })
	return true
end

-- THE TWO MECHANICS THAT OUTLIVE THEIR OWN ATTACK, stepped from the creature
-- walk rather than from a handler. Called every frame a Wrack has a kit; the
-- kit is dropped the moment both lists empty, so the cost is bounded by the
-- fight actually having something running.
-- ---------------------------------------------------- the act clock (2026-09-09)
--
-- THE ONE PLACE THAT KNOWS WHICH ACT IT IS. Three jobs, and they are together
-- because they are the same question asked three ways:
--
--   1. `creature.actFraction` - the synthetic dial `Fn.bossPhaseFraction`
--      prefers, monotonic across both of the ship's acts:
--          act 1:  0.60 + 0.40 * (gunsAlive / count)
--          act 2:  0.60 * (hull hp / hull max)
--      Act one HAS to be on the gun count: the hull is immune for its whole
--      length, so its health bar never moves and a health-fraction table would
--      sit in band one until the act was over.
--   2. `ATTR.WRACK_ACT` - so the client can light the hull and open the ports.
--   3. ACT TWO'S EARNED WINDOW. Every `acts.crackEvery` of the hull's bar the
--      party takes off her, she cracks open for `acts.crackFor`.
--
-- THE WINDOW IS THE SHIPPED `expose` MACHINERY, NOT A NEW ONE. Setting
-- `exposedUntil` gets the 2x in `hitModifiers`, `ATTR.EXPOSED` gets the client's
-- shells-open animation, and pushing `nextAttackAt` past the window is exactly
-- what `holdExpose` does for an authored move. The only thing that is new is
-- the TRIGGER: a damage threshold rather than the end of an attack, because a
-- window the player earns is what act two is about. Writing a second window
-- system would have meant a second thing to keep in step with the client.
function Fn.wrackActStep(creature, def, now: number)
	local model = creature.model
	if not model or not model.Parent then
		return
	end
	local parts = def.parts
	local alive = creature.partsAlive
	if parts and alive and alive > 0 then
		-- ACT ONE. The dial descends as the cannons fall and stops at 0.60.
		creature.actFraction = 0.60 + 0.40 * (alive / math.max(parts.count, 1))
		if creature.wrackAct ~= 1 then
			creature.wrackAct = 1
			model:SetAttribute(ATTR.WRACK_ACT, 1)
		end
		return
	end
	-- ACT TWO. The guns are gone for good (no `regrow`), so reaching here once
	-- means reaching here for the rest of the fight.
	creature.actFraction = 0.60 * (creature.health / math.max(creature.maxHealth, 1))
	if creature.wrackAct ~= 2 then
		creature.wrackAct = 2
		model:SetAttribute(ATTR.WRACK_ACT, 2)
		-- The first threshold is measured from the hull she still has when the
		-- act opens, which is all of it - seeded here rather than at spawn so a
		-- stray hit landing during act one (there cannot be one; the hull is
		-- immune) could not consume a crack before act two began.
		creature.wrackCrackAt = creature.health - (def.acts and def.acts.crackEvery or 0.20) * creature.maxHealth
	end
	local acts = def.acts
	if not acts or not creature.wrackCrackAt then
		return
	end
	if creature.health <= creature.wrackCrackAt and not creature.collapsing then
		creature.wrackCrackAt = creature.health - (acts.crackEvery or 0.20) * creature.maxHealth
		local until_ = now + (acts.crackFor or 3.0)
		-- `math.max`, never a bare assignment: a crack landing while an earlier
		-- one is still open must EXTEND it, not cut it short. Two thresholds can
		-- fall inside one burst from a party.
		creature.exposedUntil = math.max(creature.exposedUntil or 0, until_)
		model:SetAttribute(ATTR.EXPOSED, true)
		-- The window has to be a real one. `holdExpose`'s arithmetic, applied
		-- here because this window is not an attack's and so never passes
		-- through Fn.endBossAttack.
		creature.nextAttackAt = math.max(creature.nextAttackAt or now, creature.exposedUntil)
		fireEvent("bossStagger", creature.anchor or creature.pos, {
			name = def.name,
			duration = creature.exposedUntil - now,
		})
	end
end

function Fn.wrackKitStep(creature, now: number, dt: number)
	local kit = creature.wrackKit
	if not kit then
		return
	end
	for i = #kit.runners, 1, -1 do
		local run = kit.runners[i]
		-- SHOT DOWN. Noticed by polling rather than by a hook: see the section
		-- header on why these props cannot carry `partOf`.
		if not run.popAt and not Fn.wrackPropLive(run.prop) then
			run.popAt, run.popFuse = now, false
		end
		if run.popAt and now >= run.popAt then
			Fn.wrackKegBlast(creature, run, now, run.popFuse == true)
			table.remove(kit.runners, i)
		elseif now >= run.fuseAt then
			Fn.wrackKegBlast(creature, run, now, true)
			table.remove(kit.runners, i)
		else
			-- HOMES ON THE PLAYER IT WAS LATCHED TO AT WINDUP, and re-latches
			-- only if that player has gone. It turns instantly - there is no
			-- wisp-style turn radius to run circles around, because the answer
			-- to this one is the gun, not the feet.
			local character = run.target and run.target.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if not root then
				local nearest, player = Fn.nearestPlayerRoot(run.at)
				root, run.target = nearest, player
			end
			if root then
				local step = flatUnit(root.Position - run.at) * run.speed * dt
				run.at = Fn.wrackPlaceProp(run.prop, run.at + step) or run.at
			end
		end
	end
	for i = #kit.boarders, 1, -1 do
		local man = kit.boarders[i]
		-- WRAPPED, never written through onto the creature record. The march's
		-- state (`speed`, `reach`, `repair`) would otherwise be four new fields
		-- invented on a shared struct that a dozen archetypes already read -
		-- `speed` in particular is a name the row layer owns.
		if not Fn.wrackPropLive(man.prop) then
			table.remove(kit.boarders, i)
		elseif now >= man.expireAt then
			CreatureService.despawn(man.prop.model)
			table.remove(kit.boarders, i)
		else
			local centre = creature.anchor or creature.pos
			local at = man.prop.pos
			local dx, dz = centre.X - at.X, centre.Z - at.Z
			if math.sqrt(dx * dx + dz * dz) <= man.reach then
				-- ABOARD. Whether or not there is anything left to repair (the
				-- burst window: see Fn.wrackRepair), the boarder is spent - it
				-- climbed the side and is gone.
				Fn.wrackRepair(creature, man.repair)
				CreatureService.despawn(man.prop.model)
				table.remove(kit.boarders, i)
			else
				Fn.wrackPlaceProp(man.prop, at + flatUnit(Vector3.new(dx, 0, dz)) * man.speed * dt)
			end
		end
	end
	if #kit.runners == 0 and #kit.boarders == 0 then
		creature.wrackKit = nil
	end
end

-- THE POWDER RUNNER. p: rows, count, fuse, speed, spawnAt, blast, blastFuse,
-- chainAt, damage.
K.ATTACK_HANDLERS.powderrun = {
	windup = function(creature, def, p, u, sub)
		local a = creature.attack
		-- LATCHED OUTSIDE THE TOLD-GATE, the documented trap in this section:
		-- the tell is skipped while the decks are silent, and a latch that
		-- lived inside it would leave the fire hook with no target at all on
		-- exactly the windups that start inside the stagger and end outside it.
		if not a.wrackAimed then
			a.wrackAimed = true
			wrackAim(creature)
			local _, player = Fn.nearestPlayerRoot(creature.anchor or creature.pos)
			a.wrackChase = player
			-- WHERE THE KEG LANDS, latched with everything else. It is LOBBED
			-- from the gun and comes down `spawnAt` studs short of the latched
			-- target, on the line between them - it does not roll the whole way
			-- across the beach, and that distinction is the difference between
			-- a mechanic and a decoration.
			--
			-- The arithmetic, because it is the only thing holding this move up:
			-- the keg closes at 2 studs/s (18 against a 16-stud walk) and the
			-- fuse is 8 seconds, so it gains SIXTEEN STUDS in its whole life. A
			-- keg born at its gun would be 68 studs from the drop ring and
			-- would need thirty-four seconds to arrive - it could be ignored
			-- completely, by anybody, forever. Born 28 studs out it ends the
			-- fuse 12 studs from a player who ran flat out the entire time,
			-- which is inside `blastFuse`: RUNNING DOES NOT BEAT IT, and it is
			-- not supposed to. The answer to this one is the gun.
			local centre = creature.anchor or creature.pos
			local mark = a.wrackMark or (centre + wrackAim(creature) * 90)
			a.wrackKegAt = mark
			a.wrackKegBack = p.spawnAt or 28
		end
		if not a.wrackTold and Fn.wrackWillFire(creature, def) then
			a.wrackTold = true
			-- WHERE, not what: the keg is a visible model with a lit fuse from
			-- the moment it exists, so the telegraph only has to name the ground
			-- it comes down on - which is ground the player can already see,
			-- between them and the ship.
			local gun = Fn.wrackGunFor(creature)
			local from = if gun then Vector3.new(gun.X, a.wrackKegAt.Y, gun.Z) else creature.model:GetPivot().Position
			local back = a.wrackKegAt - from
			local dir = if back.Magnitude > 0.001 then flatUnit(back) else wrackAim(creature)
			fireEvent("telegraph", groundedPos(a.wrackKegAt - dir * a.wrackKegBack, 0), {
				kind = "mark",
				duration = p.windup,
				radius = 8,
				skin = p.skin,
			})
		end
		creature.model:PivotTo(poseCFrame(creature, sub + 0.2 * u, 0, math.rad(-8) * u))
	end,
	fire = function(creature, def, p, now)
		-- The burst window silences the SPAWN, not just the tell. Everything
		-- else about the move still runs (cooldown included), so keeping the
		-- batteries down cannot farm free openings - the same contract every
		-- ball row above lives under.
		if not Fn.wrackWillFire(creature, def) then
			return
		end
		local a = creature.attack
		local centre = creature.anchor or creature.pos
		local decks = Fn.wrackDeckPositions(creature)
		if #decks == 0 then
			return
		end
		local lo, hi = Fn.bossRoll(creature, def, p.damage)
		local kit = Fn.wrackKit(creature)
		for i = 1, (p.count or 1) do
			-- One deck each when there are two kegs, so phase 3's pair is lobbed
			-- from two bearings and comes down on two sides of the target - it
			-- cannot be answered by facing one way and firing.
			local gun = decks[((i - 1) % #decks) + 1]
			local mark = a.wrackKegAt or (centre + wrackAim(creature) * 90)
			local back = Vector3.new(mark.X - gun.X, 0, mark.Z - gun.Z)
			local dir = if back.Magnitude > 0.5 then back.Unit else wrackAim(creature)
			-- Short of the target on the gun's own line: see the windup's latch
			-- for why the distance is the whole move.
			local at = groundedPos(mark - dir * (a.wrackKegBack or p.spawnAt or 28), 0)
			local prop = Fn.wrackProp(creature, p, at, (p.fuse or 8) + 2)
			if prop then
				table.insert(kit.runners, {
					prop = prop,
					at = prop.pos,
					target = a.wrackChase,
					speed = p.speed or 18,
					fuseAt = now + (p.fuse or 8),
					blast = p.blast or 15,
					blastFuse = p.blastFuse or 20,
					chainAt = p.chainAt or 0,
					min = lo,
					max = hi,
					skin = p.skin,
				})
				-- NO "decoy" SPAWN EVENT, and that is a decision rather than an
				-- omission. The lure system's cue plants a persistent client-
				-- side orb that is moved only by `decoyMove` - which this keg
				-- never sends, because the keg is a real creature model the
				-- server is already replicating. Firing it would leave a second
				-- glowing ball sitting at the gun deck for the whole fuse while
				-- the real one rolled away from it. Only the POP is borrowed
				-- (see Fn.wrackKegBlast); `decoyPop` finds no orb to clear and
				-- draws the blast anyway, which is exactly what is wanted.
			end
		end
	end,
	strike = function(creature, _def, _p, _now, _dt, _u, _root, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.1, 0, math.rad(4)))
	end,
}

-- THE GHOST BRAZIERS' WAVE. Everyone on the floor takes it except whoever is
-- inside the sector behind a doused brazier - and "behind" is two conditions,
-- not one: within `safeDeg` of that brazier's own bearing AND at least as far
-- out as it stands. Standing between a doused pillar and the ship is not
-- behind it in any sense a player would accept, and a sector test alone would
-- award the safest ground in the arena to whoever was hugging the hull.
--
-- NO HEIGHT TEST, and that is deliberate rather than an omission: this is a
-- floor-wide wave over one flat shoal, the only ground in the arena is the
-- beach, and the boss's own record Y sits `submerge` studs above the sand the
-- players stand on. A tolerance measured from it would be a rule about the
-- boss's pivot pretending to be a rule about the floor.
function Fn.wrackGhostWave(creature, def, p, a)
	local centre = creature.anchor or creature.pos
	local half = math.rad(p.safeDeg or 100) * 0.5
	local inner = (p.ring or 70) - (p.behindAt or 8)
	local reach = def.arena.radius + K.WRACK_BOUND_MARGIN
	local lo, hi = a.wrackWaveLo, a.wrackWaveHi
	for _, entry in Fn.livingRootsNear(centre, reach) do
		local rp = entry.root.Position
		local dx, dz = rp.X - centre.X, rp.Z - centre.Z
		local sheltered = false
		if math.sqrt(dx * dx + dz * dz) >= inner then
			local at = math.atan2(dz, dx)
			for _, brazier in a.wrackBraz do
				if brazier.doused and math.abs(angleDelta(at, brazier.angle)) <= half then
					sheltered = true
					break
				end
			end
		end
		if not sheltered then
			PlayerService.damage(entry.player, math.random(lo, hi), creature, { bypassIframe = true })
		end
	end
	fireEvent("strikeHit", centre, { radius = reach, inner = 0, skin = p.skin })
end

-- THE GHOST BRAZIERS. p: rows, count, ring, charge, safeDeg, behindAt, damage.
K.ATTACK_HANDLERS.ghostbraziers = {
	windup = function(creature, def, p, u, sub)
		local a = creature.attack
		if not a.wrackAimed then
			a.wrackAimed = true
			-- The trio's bearings are latched off the aim so they never land in
			-- the same three places twice, and latched OUTSIDE the told-gate
			-- because `fire` lays the pillars out from this angle whether or
			-- not the telegraph was drawn.
			a.wrackGapAt = Fn.wrackAngle(wrackAim(creature))
		end
		if not a.wrackTold and Fn.wrackWillFire(creature, def) then
			a.wrackTold = true
			fireEvent("telegraph", creature.anchor or creature.pos, {
				kind = "ringTell",
				duration = p.windup,
				radius = (p.ring or 70) + 6,
				inner = math.max(0, (p.ring or 70) - 6),
				skin = p.skin,
			})
		end
		creature.model:PivotTo(poseCFrame(creature, sub + 0.3 * u, 0, math.rad(10) * u))
	end,
	fire = function(creature, def, p, now)
		local a = creature.attack
		if not Fn.wrackWillFire(creature, def) then
			return
		end
		local centre = creature.anchor or creature.pos
		local count = math.max(1, p.count or 3)
		local lo, hi = Fn.bossRoll(creature, def, p.damage)
		a.wrackBraz = {}
		a.wrackWaveAt = now + (p.charge or 6)
		a.wrackWaveLo, a.wrackWaveHi = lo, hi
		for i = 0, count - 1 do
			local angle = a.wrackGapAt + (math.pi * 2 / count) * i
			local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
			local at = groundedPos(centre + dir * (p.ring or 70), 0)
			local prop = Fn.wrackProp(creature, p, at, (p.charge or 6) + 4)
			if prop then
				table.insert(a.wrackBraz, { prop = prop, angle = angle, at = prop.pos })
				-- Each pillar counts down its own charge, on itself.
				fireEvent("telegraph", prop.pos, {
					kind = "mark",
					duration = p.charge or 6,
					radius = 7,
					skin = p.skin,
				})
			end
		end
	end,
	strike = function(creature, def, p, now, _dt, _u, _root, sub)
		local a = creature.attack
		if a.wrackBraz and not a.wrackWaved then
			for _, brazier in a.wrackBraz do
				if not brazier.doused and not Fn.wrackPropLive(brazier.prop) then
					brazier.doused = true
					fireEvent("decoyPop", brazier.at, { fizzle = true, skin = p.skin })
					-- THE REWARD, DRAWN WHERE IT IS. Dousing a brazier opens a
					-- sector, and a sector nobody can see is a mechanic nobody
					-- can use - so the moment one goes out, the ground it just
					-- made safe is marked, for as long as the charge has left.
					local dir = Vector3.new(math.cos(brazier.angle), 0, math.sin(brazier.angle))
					local out = (p.ring or 70) + 28
					fireEvent("telegraph", groundedPos((creature.anchor or creature.pos) + dir * out, 0), {
						kind = "mark",
						duration = math.max(a.wrackWaveAt - now, 0.2),
						radius = math.rad(p.safeDeg or 100) * out * 0.5,
						skin = p.skin,
					})
				end
			end
			if now >= a.wrackWaveAt then
				a.wrackWaved = true
				Fn.wrackGhostWave(creature, def, p, a)
			end
		end
		creature.model:PivotTo(poseCFrame(creature, sub, 0, math.rad(6)))
	end,
	finish = function(creature, _def, _p, _now)
		-- The pillars are the charge, not scenery: whatever survived the wave
		-- goes out with it. Their spawn `lifetime` is the belt to this brace,
		-- for the fight that ends before `finish` is ever reached.
		local a = creature.attack
		if a and a.wrackBraz then
			for _, brazier in a.wrackBraz do
				if Fn.wrackPropLive(brazier.prop) then
					CreatureService.despawn(brazier.prop.model)
				end
			end
			a.wrackBraz = nil
		end
	end,
}

-- THE CANNON OVERLOAD. p: jam, bonus, markAt, speed, radius, spawnAt,
-- lifetime, tellRange, damage, burst.
K.ATTACK_HANDLERS.cannonoverload = {
	windup = function(creature, def, p, u, sub)
		local a = creature.attack
		if not a.wrackAimed then
			a.wrackAimed = true
			local aim = wrackAim(creature)
			local centre = creature.anchor or creature.pos
			-- THE PART ITSELF, held rather than its index. Two reasons, and the
			-- second is the fight's own history: indices shift the moment a
			-- deck dies (wrackGunFor holds a POSITION for exactly that reason),
			-- and this handler has to read that battery's HEALTH every frame,
			-- which only the record can answer.
			local best, bestScore = nil, -math.huge
			for _, part in Fn.livingArms(creature) do
				local off = Vector3.new(part.pos.X - centre.X, 0, part.pos.Z - centre.Z)
				local mag = off.Magnitude
				local score = if mag > 0.001 then (off.X * aim.X + off.Z * aim.Z) / mag else -1
				if score > bestScore then
					bestScore, best = score, part
				end
			end
			a.wrackOver = best
			a.wrackOverHp = best and best.health
			-- AND THE TELL AND THE BALL LEAVE THE SAME BRASS. wrackGunFor picks
			-- its own gun on first call and latches it; seeding `wrackGunAt`
			-- here makes it return the battery the disc is about to pulse on
			-- instead. On a hull whose mounts are 10.9 studs apart, a mega-shot
			-- out of the wrong one is a tell that lies by a whole cannon.
			if best then
				a.wrackGunAt = best.pos
				-- WHICH CANNON, on the wire as well as on the ground. The disc
				-- and the wedge below are the telegraph; this is the same claim
				-- in a form a renderer can hold for the whole windup and drop
				-- when it ends, which a one-shot event cannot do (a client that
				-- adopts the model mid-windup sees nothing at all).
				best.model:SetAttribute(ATTR.WEAKPOINT_HOT, true)
			end
		end
		if not a.wrackTold and a.wrackOver and Fn.wrackWillFire(creature, def) then
			a.wrackTold = true
			local gun, from = Fn.wrackGunFor(creature)
			-- WHICH CANNON, said twice: a disc on the gun itself (sized under
			-- half the gap to its neighbour, so it names one), and a wedge
			-- leaving it along the bearing the shot will take.
			fireEvent("telegraph", a.wrackOver.pos, {
				kind = "mark",
				duration = p.windup,
				radius = p.markAt or 5,
				skin = p.skin,
			})
			Fn.wrackConeTell(p, gun or a.wrackOver.pos, from, 0, 1)
		end
		-- THE JAM, tested every windup frame. It is measured against the health
		-- this battery had when the windup STARTED, not against a fraction of
		-- its current bar: the threshold has to mean "damage done during the
		-- windup", and a battery that was already at 20% would otherwise be
		-- jammable by a scratch.
		local part = a.wrackOver
		if part and not a.wrackJammed then
			if not Fn.wrackPropLive(part) then
				-- Broken outright mid-windup. There is no gun left to fire.
				a.wrackJammed = true
			elseif a.wrackOverHp and (a.wrackOverHp - part.health) >= (p.jam or 0.15) * part.maxHealth then
				a.wrackJammed = true
				-- The reward for choosing it: the jam is not only defence, it
				-- is the fastest way to break that battery.
				CreatureService.damage(
					part,
					math.max(1, math.floor(part.maxHealth * (p.bonus or 0.1) + 0.5)),
					nil,
					{ ignoreUntargetable = true }
				)
				fireEvent("strikeHit", part.pos, { radius = 9, skin = p.skin })
			end
		end
		creature.model:PivotTo(poseCFrame(creature, sub + 0.2 * u, 0, math.rad(-12) * u))
	end,
	fire = function(creature, def, p, now)
		local a = creature.attack
		-- The glow goes out with the windup, jammed or not: the attribute means
		-- "this gun is winding up", and it is no longer winding up. Cleared here
		-- rather than only in `finish`, because a JAMMED overload has nothing
		-- left to do and should stop advertising itself the instant it fires
		-- nothing.
		if Fn.wrackPropLive(a.wrackOver) then
			a.wrackOver.model:SetAttribute(ATTR.WEAKPOINT_HOT, nil)
		end
		-- NOTHING IS CANCELLED and no phase is exited - rule 3 at the top of
		-- this section. A jammed overload simply emits nothing, so it still
		-- runs its strike and recover and still writes its own cooldown.
		if a.wrackJammed then
			return
		end
		Fn.wrackEmit("megashot", creature, def, p, now)
	end,
	strike = function(creature, _def, _p, _now, _dt, _u, _root, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.3, 0, math.rad(9)))
	end,
	finish = function(creature, _def, _p, _now)
		-- The belt to `fire`'s brace: a windup interrupted by a stagger or the
		-- boss's own collapse never reaches `fire`, and a battery left glowing
		-- for the rest of the fight would be a tell that never comes true.
		local a = creature.attack
		if a and Fn.wrackPropLive(a.wrackOver) then
			a.wrackOver.model:SetAttribute(ATTR.WEAKPOINT_HOT, nil)
		end
	end,
}

-- THE ANCHOR LINE. p: rows, overshoot, drag, stopAt, chain, chainRadius,
-- radius, lifetime, tellWidth, tellRange, damage.
K.ATTACK_HANDLERS.anchorline = {
	windup = function(creature, def, p, u, sub)
		local a = creature.attack
		if not a.wrackAimed then
			a.wrackAimed = true
			local centre = creature.anchor or creature.pos
			local aim = wrackAim(creature)
			local mark = a.wrackMark or (centre + aim * 90)
			local out = Vector3.new(mark.X - centre.X, 0, mark.Z - centre.Z)
			local dir = if out.Magnitude > 0.001 then out.Unit else aim
			-- PAST them, not at them - the anchor is thrown OVER the player so
			-- the hazard is behind them and comes back through. Landing it on
			-- their feet would make it a disc dodge like everything else.
			--
			-- AND CLAMPED INSIDE THE BOUND, which is not a tidy-up: the chain
			-- is a pair of ProjectileService balls, and the tick retires any
			-- ball further from `centre` than `bound` (arena.radius + 60 = 140)
			-- ON ITS FIRST FRAME. A player standing at the sand's edge (r 132)
			-- plus a 25-stud overshoot lands at 157, so the hazard would have
			-- been born already dead - a telegraph drawn, a chain spawned, and
			-- nothing on the beach - and it would have failed ONLY for players
			-- out at the rim, which is the hardest kind of bug to be told about.
			local far = def.arena.radius + K.WRACK_BOUND_MARGIN - 8
			local land = mark + dir * (p.overshoot or 25)
			local lx, lz = land.X - centre.X, land.Z - centre.Z
			local lr = math.sqrt(lx * lx + lz * lz)
			if lr > far then
				land = centre + Vector3.new(lx, 0, lz) * (far / lr)
			end
			a.wrackLand = groundedPos(land, 0)
			a.wrackDragDir = -dir
		end
		if not a.wrackTold and Fn.wrackWillFire(creature, def) then
			a.wrackTold = true
			-- Where it lands, then the corridor it will drag through - drawn
			-- before the hazard exists, which is the only warning a line
			-- hazard can give that is worth anything.
			fireEvent("telegraph", a.wrackLand, {
				kind = "mark",
				duration = p.windup,
				radius = (p.chain or 34) * 0.5,
				skin = p.skin,
			})
			Fn.wrackLaneTell(p, a.wrackLand, a.wrackDragDir, p.chain or 34, p.tellRange or 120)
		end
		creature.model:PivotTo(poseCFrame(creature, sub + 0.5 * smoothstep(u), 0, math.rad(-16) * u))
	end,
	fire = function(creature, def, p, now)
		local a = creature.attack
		if not Fn.wrackWillFire(creature, def) then
			return
		end
		local centre = creature.anchor or creature.pos
		local land = a.wrackLand
		local dx, dz = land.X - centre.X, land.Z - centre.Z
		-- THE DRAG TAKES `drag` SECONDS WHATEVER THE DISTANCE, which is why the
		-- speed is computed here and handed down instead of being authored. A
		-- fixed studs/s would be a formality against a player at the rim and
		-- unsurvivable against one hugging the hull.
		local span = math.max(math.sqrt(dx * dx + dz * dz) - (p.stopAt or 18), 4)
		local speed = span / math.max(p.drag or 4.2, 0.2)
		-- A FRESH TABLE IS THE HANDLE. Nothing reads it - it only has to be
		-- unique and comparable, so that retiring this hazard cannot touch a
		-- second anchor line, and cannot be confused with any other volley.
		a.wrackTag = {}
		a.wrackDragAt = land
		a.wrackDragSpeed = speed
		a.wrackDragFrom = now
		Fn.wrackEmit("anchorline", creature, def, p, now, nil, nil, {
			spot = land,
			dir = a.wrackDragDir,
			tag = a.wrackTag,
			speed = speed,
		})
		-- THE OFF SWITCH, standing in the middle of its own chain.
		a.wrackChainProp = Fn.wrackProp(creature, p, land, (p.drag or 4.2) + 2)
	end,
	strike = function(creature, _def, p, now, _dt, u, _root, sub)
		local a = creature.attack
		if a.wrackChainProp then
			if not Fn.wrackPropLive(a.wrackChainProp) then
				-- SNAPPED. The hazard dies on this frame, not at the end of its
				-- lifetime - a shootable part that only PROMISES to end the
				-- thing it is attached to is worse than no part at all.
				local at = a.wrackChainProp.pos
				a.wrackChainProp = nil
				if a.wrackTag then
					ProjectileService.retireTag(creature, a.wrackTag)
					a.wrackTag = nil
				end
				fireEvent("decoyPop", at, { fizzle = true, skin = p.skin })
			else
				-- Ridden off the same kinematics the balls were given, rather
				-- than read back off them: the pair travels at a constant
				-- velocity from a known point, so the midlink can be placed
				-- from the clock and the two can never disagree.
				local t = math.min(now - a.wrackDragFrom, p.drag or 4.2)
				Fn.wrackPlaceProp(a.wrackChainProp, a.wrackDragAt + a.wrackDragDir * (a.wrackDragSpeed * t))
			end
		end
		creature.model:PivotTo(poseCFrame(creature, sub + 0.3 * (1 - u), 0, math.rad(12) * (1 - u)))
	end,
	finish = function(creature, _def, _p, _now)
		local a = creature.attack
		if not a then
			return
		end
		if a.wrackTag then
			ProjectileService.retireTag(creature, a.wrackTag)
			a.wrackTag = nil
		end
		if Fn.wrackPropLive(a.wrackChainProp) then
			CreatureService.despawn(a.wrackChainProp.model)
		end
		a.wrackChainProp = nil
	end,
}

-- THE LONGBOAT. p: rows, count, beachAt, spread, speed, reach, march, repair.
K.ATTACK_HANDLERS.longboat = {
	windup = function(creature, def, p, u, sub)
		local a = creature.attack
		if not a.wrackAimed then
			a.wrackAimed = true
			local centre = creature.anchor or creature.pos
			local aim = wrackAim(creature)
			-- They beach on the player's OWN side of the arena, so the march is
			-- something the party is standing in the middle of rather than a
			-- rumour happening behind the ship.
			a.wrackBeach = groundedPos(centre + aim * (def.arena.radius + (p.beachAt or 46)), 0)
			a.wrackBeachSide = Vector3.new(-aim.Z, 0, aim.X)
		end
		if not a.wrackTold and Fn.wrackWillFire(creature, def) then
			a.wrackTold = true
			fireEvent("telegraph", a.wrackBeach, {
				kind = "mark",
				duration = p.windup,
				radius = (p.spread or 11) + 6,
				skin = p.skin,
			})
		end
		creature.model:PivotTo(poseCFrame(creature, sub - 0.3 * u, 0, math.rad(7) * u))
	end,
	fire = function(creature, def, p, now)
		if not Fn.wrackWillFire(creature, def) then
			return
		end
		local a = creature.attack
		local kit = Fn.wrackKit(creature)
		local count = math.max(1, p.count or 3)
		local life = p.march or 26
		for i = 1, count do
			-- Spread ALONG the beach rather than in a clump, so they arrive as
			-- a line the party has to sweep instead of one target three shots
			-- happen to overlap on.
			local across = ((i - 0.5) / count - 0.5) * 2 * (p.spread or 11)
			local at = groundedPos(a.wrackBeach + a.wrackBeachSide * across, 0)
			local man = Fn.wrackProp(creature, p, at, life)
			if man then
				table.insert(kit.boarders, {
					prop = man,
					speed = p.speed or 9.5,
					reach = p.reach or 20,
					repair = p.repair or 0.25,
					expireAt = now + life,
				})
			end
		end
		fireEvent("summon", a.wrackBeach, { count = count })
	end,
	strike = function(creature, _def, _p, _now, _dt, _u, _root, sub)
		creature.model:PivotTo(poseCFrame(creature, sub - 0.2, 0, math.rad(-5)))
	end,
}

-- ---------------------------------------------------- Wrack: the ship itself (2026-09-09)
--
-- The five verbs above are things the Admiral PUTS ON THE SAND - kegs, pillars,
-- a chain, a boat. These three are things the SHIP DOES, and that is the whole
-- reason they exist: after five mechanics of "shoot the thing that landed near
-- you", the hull had still never once moved. Each of the three takes a piece of
-- her and swings it at you.
--
--   ladybelow    the figurehead unships herself and hunts - two or three
--                telegraphed lane dives at one player, then she re-docks. SHOOT
--                HER and she is off the board a dive early.
--   boomsweep    the main boom swings outboard and sweeps the near ring. There
--                is nowhere to run TANGENTIALLY (see the arithmetic on the row);
--                you leave radially, or you shoot the tackle and it drops.
--   bilgeblow    three deck hatches blow in sequence and a geyser marches out
--                along each one's radial. Nothing to shoot at all: it is ground
--                being taken away, and it is scheduled against the moves that
--                want you standing on that ground.
--
-- THEY INHERIT EVERY RULE OF THE SECTION ABOVE and add none:
--   * aim latched once at windup, OUTSIDE the told-gate (the trap documented on
--     powderrun: a latch inside it leaves `fire` with no target on exactly the
--     windups that begin inside the stagger);
--   * every tell drawn from the latched geometry, once-guarded, gated on
--     `Fn.wrackWillFire`, and only in kinds the client actually draws
--     (`wrackTell` lane/ring, `ringTell`, `mark` - see the boss row's note);
--   * nothing touches the phase machine: no early return out of a phase, no
--     Fn.endBossAttack, no clearing of `creature.attack`. A move silenced by the
--     burst window still runs its strike and recover and still writes its
--     cooldown, so keeping the batteries down cannot farm free openings;
--   * the hull does not turn. Every pose below passes yawOffset 0, like all
--     eleven before them, because `parts.mounts` are resolved once against
--     `yaw0` and a slewing hull would leave the guns behind.
--
-- AND NONE OF THE THREE ADDS A SYSTEM THAT OUTLIVES ITS OWN ATTACK. The kit
-- (`Fn.wrackKitStep`) exists for the two mechanics that had to - an eight-second
-- fuse and an eleven-second march. The Lady re-docks, the boom stows and the
-- hatches shut inside their own rows' `duration`, so all three are stepped from
-- their own `strike` hook the way the anchor line's midlink is, and `finish`
-- clears what is left if the fight ends underneath them. The one thing that DOES
-- outlive its row is bilgeblow's queued eruptions, and that is deliberate: they
-- are `creature.strikes` entries, which the creature walk already owns and
-- already drops when the boss dies. A second copy of that machinery, on a kit,
-- would be the thing the section header above refuses to build.

-- The pose centre and the boss-local transform, in ONE place. `Fn.spawnBossParts`
-- reaches the second of these for `parts.mounts`; the three handlers below reach
-- it for the rigging. Same convention, same arithmetic, one definition: a point's
-- Y is the piece's own CENTRE measured from the sand of the DRAWN hull (so the
-- record's `halfThickness` and the row's `submerge` both come off), and X/Z are
-- boss-local, resolved against the heading the hull spawned with.
function Fn.wrackPoseCentre(creature): Vector3
	local centre = creature.anchor or creature.pos
	if creature.pose and creature.pose.center then
		centre = creature.pose.center
	end
	return centre
end

-- ---------------------------------------------------- the shot occluder (2026-09-09)
--
-- "they shouldnt be able to shoot through the boss" (user, 2026-09-09). Nothing
-- in this engine made that true: creature parts are `CanQuery = false` and
-- targeting has always been proximity rather than raycast, so a shot at a
-- cannon on the far side of a 42-stud ship was resolved exactly as if the ship
-- were not there. Acts one and two are built on the opposite premise - four
-- corner guns, only two reachable from any bearing, and repositioning to reach
-- the far pair IS the loop - so the hull has to become a real obstacle.
--
-- ONE INVISIBLE PART DOES IT, AND WHERE IT IS PARENTED IS THE WHOLE MECHANISM.
--
--   * SERVER: `ShotAim.terrainLimit` builds its RaycastParams as
--     `FilterType = Include` over `Workspace[World.FOLDER_NAME]` AND NOTHING
--     ELSE. A collider parented to the Creatures folder, to the `BossArenas`
--     folder, or to bare Workspace is invisible to every shot in the game -
--     silently, with no error and no symptom except a boss you can shoot
--     through. It also sets `RespectCanCollide = true`, which is why
--     `CanCollide` must be set and `CanQuery` alone is not enough.
--   * CLIENT: `RangedController.aimDistance` excludes the character and the
--     four FX folders with `RespectCanCollide = true`. The World folder is not
--     among them and this replicates as an ordinary anchored BasePart, so the
--     client's depth probe stops on the same geometry the server does. Both
--     halves agree by construction, from one object, rather than by two
--     filters being kept in step.
--
-- Players cannot walk through her either. That is intended: she is a ship.
--
-- THE PACK PIECE IS THE REAL ANSWER AND THE BOX IS NOT A SUBSTITUTE.
-- `Wrack_HullCollider` carries the four sponsons' casemates - a back wall and
-- two cheeks per gun, folded into the one object so this stays a single clone -
-- and those cheeks are what actually bound the fight to two guns per bearing.
-- The hull ALONE leaks: the sponsons stand at |z| 9.5 while the hull is only
-- |z| 6.6, so a bow-on ray from the sand's edge crosses her near face OUTSIDE
-- the timber and runs down her side to a far gun. The fallback box below cannot
-- reproduce cheeks and therefore leaks on the axial bearings; it exists so the
-- fight is playable before the pack imports, and it is not the shipped shape.
K.WRACK_OCCLUDER_NAME = "WrackOccluder"
-- The authored hull-collider extents, boss-local, in the same Roblox
-- (X, height, Z) convention as `parts.mounts`: x -21.5..20.5, y 0.70..15.00,
-- z -6.60..6.60. Used only when the pack piece is absent.
K.WRACK_HULL_BOX = Vector3.new(42.0, 14.3, 13.2)
K.WRACK_HULL_MID = Vector3.new(-0.5, 7.85, 0.0)

function Fn.wrackOccluderDrop(creature)
	local part = creature and creature.wrackOccluder or K.WRACK_OCCLUDER
	if part then
		part:Destroy()
	end
	if creature then
		creature.wrackOccluder = nil
	end
	K.WRACK_OCCLUDER = nil
end

function Fn.wrackOccluder(creature, def)
	local world = Workspace:FindFirstChild(World.FOLDER_NAME)
	if not world then
		-- Named rather than generic: this is the one failure of the occluder
		-- that produces NO symptom except a boss you can shoot through, so the
		-- log line has to be enough to recognise it by.
		warn(string.format("[CreatureService] no World folder: %s's hull will not stop shots", def.name))
		return
	end
	-- SWEEP FIRST, ALWAYS. A fight that crashed, a server that reloaded, an
	-- admin restart that raised a second Wrack on top of the first - any of
	-- them can leave a collider behind, and a leaked one is worse than a
	-- missing one: it is invisible, it blocks shots and bodies forever, and
	-- `BossArenaService.floorY` would probe the NEXT fight's arena and find the
	-- old ship's deck. Idempotent by name.
	local stale = world:FindFirstChild(K.WRACK_OCCLUDER_NAME)
	while stale do
		stale:Destroy()
		stale = world:FindFirstChild(K.WRACK_OCCLUDER_NAME)
	end

	local centre = Fn.wrackPoseCentre(creature)
	local part
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local template = assets and assets:FindFirstChild("Wrack_HullCollider", true)
	if template and template:IsA("BasePart") then
		part = template:Clone()
	else
		part = Instance.new("Part")
		part.Size = K.WRACK_HULL_BOX
	end
	part.Name = K.WRACK_OCCLUDER_NAME
	part.Anchored = true
	part.Transparency = 1
	part.CanCollide = true
	part.CanQuery = true
	-- No touch events: it is geometry, not a trigger, and a 42-stud part firing
	-- Touched for every player and every prop that brushes it is pure cost.
	part.CanTouch = false
	part.Massless = true
	-- Resolved ONCE against `yaw0`, exactly as `parts.mounts` are and for the
	-- same reason: he does not turn. A hull that slewed would need this every
	-- frame, and the mounts would be wrong too.
	local mid = K.WRACK_HULL_MID
	part.CFrame = CFrame.new(centre) * CFrame.Angles(0, -(creature.yaw0 or 0), 0) * CFrame.new(mid)
	part.Parent = world
	creature.wrackOccluder = part
	K.WRACK_OCCLUDER = part
	-- IT DIES WITH HER, by every route. The model's own removal covers the
	-- kill, `CreatureService.despawn`, the abandon reaper and adminStart's
	-- teardown in one connection, which is the only way to be sure none of the
	-- four was missed - and act three is fought on open sand with no ship in
	-- it, so the wreck must not keep blocking.
	local model = creature.model
	model.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			Fn.wrackOccluderDrop(creature)
		end
	end)
end

function Fn.wrackMountPoint(creature, def, m: Vector3): Vector3
	local centre = Fn.wrackPoseCentre(creature)
	local sand = centre.Y - (creature.halfThickness or 0) - (def.submerge or 0)
	local cos, sin = math.cos(creature.yaw0 or 0), math.sin(creature.yaw0 or 0)
	return Vector3.new(centre.X + m.X * cos + m.Z * sin, sand + m.Y, centre.Z - m.X * sin + m.Z * cos)
end

-- THE MESH HANDOFF SLOT, AND THE ONLY HONEST WAY TO BE WITHOUT IT.
--
-- Where the figurehead docks, where the boom is stepped and how long it is, and
-- where the three bilge hatches sit are MEASUREMENTS off the drawn hull - they
-- belong to `WR_FIGUREHEAD` / `WR_BOOM` / `WR_HATCHES` in assets/boss_gen.py,
-- exactly as the four gun mounts belong to `WR_CANNONS`, and they arrive on the
-- boss row as `rigging`. They had not arrived when this was written.
--
-- So each reader takes a FALLBACK and says so out loud, once per attack, rather
-- than carrying a made-up constant that would read like a measurement to the
-- next person. Every fallback below is derived from a number the mesh has ALREADY
-- published - the hull box (48 studs bow to stern, 12.6 in the beam, mesh HANDOFF
-- 7673cd1) and the mount heights (9.0-12.4) - so the moves are playable and
-- self-consistent now, and visibly provisional until the real points land.
--
-- The warn is the other half of that. A missing measurement that presents as a
-- slightly-wrong-looking animation is the exact failure this file keeps having;
-- one line per twenty seconds is cheap and it disappears the moment the constants
-- are wired.
function Fn.wrackRigging(creature, def, key: string, fallback)
	local rigging = def.rigging
	local value = rigging and rigging[key]
	if value ~= nil then
		return value
	end
	local told = creature.wrackRigTold
	if not told then
		told = {}
		creature.wrackRigTold = told
	end
	if not told[key] then
		told[key] = true
		warn(
			string.format(
				"[CreatureService] boss %q has no rigging.%s yet (mesh HANDOFF pending) - using the derived fallback",
				def.id,
				key
			)
		)
	end
	return fallback
end

-- THE LADY BELOW. p: rows, dives, lead, rearm, redock, speed, approach, pastBy,
-- lane, fly, damage.
--
-- She is a moving hitbox the server owns outright: a creature model stepped
-- along a straight lane, tested against the players every frame she is on a pass,
-- and drawn by nothing but her own replicated CFrame (see ATTR.WRACK_DIVE's note
-- on why her position is deliberately NOT on the wire twice).
--
-- THE ONE PLACE THIS EXTENDS THE SECTION'S FIRST RULE, stated rather than
-- smuggled: "aim is latched once at windup" is a rule about a TELL NOT LYING,
-- not about a move having one target. Each dive re-latches at the instant its own
-- lane is drawn, and then that lane is frozen for the whole of the pass it warns
-- about. A player who walked out of dive one's lane has genuinely dodged dive
-- one; dive two is a new telegraph with its own full `lead`, and the hunt is the
-- move. What is forbidden - and what does not happen here - is her curving mid-
-- pass toward someone the lane was never drawn on.
K.ATTACK_HANDLERS.ladybelow = {
	windup = function(creature, def, p, u, sub)
		local a = creature.attack
		if not a.wrackAimed then
			a.wrackAimed = true
			wrackAim(creature)
			-- WHERE SHE UNSHIPS FROM. Fallback: just past the bow tip (the hull
			-- box's own half-length, 24) at gun-deck height.
			a.wrackLadyDock =
				Fn.wrackMountPoint(creature, def, Fn.wrackRigging(creature, def, "dock", Vector3.new(25, 9, 0)))
			a.wrackLadyLeft = math.max(1, p.dives or 2)
			Fn.wrackLadyLane(creature, p, os.clock())
		end
		if not a.wrackTold and Fn.wrackWillFire(creature, def) then
			a.wrackTold = true
			-- Dive one's lane, drawn for the whole windup: the windup IS its
			-- lead, which is why the row's `lead` and `windup` are the same
			-- number and the row says so.
			Fn.wrackLaneTell(p, a.wrackLadyFrom, a.wrackLadyAim, p.lane or 12, (p.approach or 56) + (p.pastBy or 56))
		end
		creature.model:PivotTo(poseCFrame(creature, sub + 0.25 * u, 0, math.rad(-10) * u))
	end,
	fire = function(creature, def, p, now)
		if not Fn.wrackWillFire(creature, def) then
			return
		end
		local a = creature.attack
		-- She lives as long as the whole run plus a beat, so a fight that ends
		-- underneath her is collected by the linger sweep even if `finish` never
		-- runs. Same backstop every prop in this section carries.
		local life = (p.dives or 2) * ((p.lead or 1.1) + ((p.approach or 56) + (p.pastBy or 56)) / (p.speed or 54))
			+ (p.redock or 0.8)
			+ 2
		local prop = Fn.wrackProp(creature, p, a.wrackLadyDock, life)
		if not prop then
			return
		end
		a.wrackLadyProp = prop
		a.wrackLadyAt = a.wrackLadyDock
		local lo, hi = Fn.bossRoll(creature, def, p.damage)
		a.wrackLadyLo, a.wrackLadyHi = lo, hi
		-- SWINGING OUT to dive one's start, over what is left of the lead. The
		-- speed is computed from the distance rather than authored, so her
		-- arrival and the telegraph's countdown are the same clock - the anchor
		-- line's rule, and for the same reason: a fixed studs/s would be early
		-- against a player at the rim and late against one hugging the hull.
		Fn.wrackLadyLeg(creature, p, "swing", now, a.wrackLadyFrom, p.lead or 1.1)
		prop.model:SetAttribute(ATTR.WRACK_DIVE, 0)
	end,
	strike = function(creature, def, p, now, dt, _u, _root, sub)
		Fn.wrackLadyStep(creature, def, p, now, dt)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.15, 0, math.rad(6)))
	end,
	finish = function(creature, _def, _p, _now)
		local a = creature.attack
		if a and Fn.wrackPropLive(a.wrackLadyProp) then
			a.wrackLadyProp.model:SetAttribute(ATTR.WRACK_DIVE, nil)
			CreatureService.despawn(a.wrackLadyProp.model)
		end
		if a then
			a.wrackLadyProp = nil
		end
	end,
}

-- The next dive's lane: re-latched on the nearest player, then frozen. `from` is
-- pushed back up the lane so the pass CROSSES the target rather than starting on
-- them, and the tell that goes with it is drawn over exactly the span she flies.
function Fn.wrackLadyLane(creature, p, _now: number)
	local a = creature.attack
	local centre = creature.anchor or creature.pos
	local root = Fn.nearestPlayerRoot(centre)
	local mark = if root then Vector3.new(root.Position.X, centre.Y, root.Position.Z) else (a.wrackMark or centre)
	local dock = a.wrackLadyDock or centre
	local run = Vector3.new(mark.X - dock.X, 0, mark.Z - dock.Z)
	local aim = if run.Magnitude > 0.001 then run.Unit else wrackAim(creature)
	a.wrackLadyAim = aim
	a.wrackLadyFrom = mark - aim * (p.approach or 56)
	a.wrackLadyTo = mark + aim * (p.pastBy or 56)
end

-- One leg of the flight. `kind` is what she is doing while she covers it, and
-- the speed always falls out of the distance and the time she has been given.
function Fn.wrackLadyLeg(creature, p, kind: string, now: number, to: Vector3, span: number)
	local a = creature.attack
	local from = a.wrackLadyAt or a.wrackLadyDock
	a.wrackLadyKind = kind
	a.wrackLadyLegFrom = from
	a.wrackLadyLegTo = to
	a.wrackLadyLegAt = now
	if kind == "pass" then
		-- The one leg with an authored speed: a dive's pace is the move's feel
		-- and its dodge window, not a consequence of where the player stood.
		local d = (Vector3.new(to.X - from.X, 0, to.Z - from.Z)).Magnitude
		a.wrackLadyLegFor = math.max(d / math.max(p.speed or 54, 1), 0.05)
		a.wrackLadyHit = {}
	else
		a.wrackLadyLegFor = math.max(span, 0.05)
	end
end

-- Fly her, hurt whoever the current lane's pass runs over (once each), and hand
-- the flight from leg to leg. Polled for her own death, like every prop in this
-- section: she carries no `partOf` and must not, or shooting her down would
-- count against the four gun decks and open the burst window for free.
function Fn.wrackLadyStep(creature, def, p, now: number, _dt: number)
	local a = creature.attack
	local prop = a.wrackLadyProp
	if not prop then
		return
	end
	if not Fn.wrackPropLive(prop) then
		-- SHOT DOWN. She is off the board for the rest of the move; the row's
		-- remaining strike time simply runs out with nothing in it, and the
		-- cooldown is written by Fn.endBossAttack exactly as if she had docked.
		a.wrackLadyProp = nil
		fireEvent("decoyPop", a.wrackLadyAt or (creature.anchor or creature.pos), { fizzle = true, skin = p.skin })
		return
	end
	local t = math.clamp((now - a.wrackLadyLegAt) / a.wrackLadyLegFor, 0, 1)
	local from, to = a.wrackLadyLegFrom, a.wrackLadyLegTo
	local at = from:Lerp(to, t)
	local head = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	local yaw = if head.Magnitude > 0.001 then yawToward(head.Unit) else prop.yaw0
	a.wrackLadyAt = Fn.wrackPlaceProp(prop, at, yaw, p.fly or 7) or a.wrackLadyAt
	if a.wrackLadyKind == "pass" then
		-- LANE DAMAGE, as a disc riding the lane she was telegraphed on: the
		-- half-width IS the tell's half-width, so the ground that hurts is the
		-- ground that was drawn. Once per player per pass - a line crosses you
		-- once, and a per-frame test would otherwise bill a slow player for
		-- every frame of contact.
		--
		-- No height test, for the ghost wave's reason: this is one flat shoal,
		-- there is no other floor to be on, and a tolerance measured from a
		-- pivot that floats `submerge` studs over the sand would be a rule about
		-- the boss's record pretending to be a rule about the beach.
		for _, entry in Fn.livingRootsNear(a.wrackLadyAt, (p.lane or 12) * 0.5) do
			if not a.wrackLadyHit[entry.player] then
				a.wrackLadyHit[entry.player] = true
				PlayerService.damage(entry.player, math.random(a.wrackLadyLo, a.wrackLadyHi), creature, {
					bypassIframe = true,
				})
			end
		end
	end
	if t < 1 then
		return
	end
	local kind = a.wrackLadyKind
	if kind == "swing" or kind == "rearm" then
		prop.model:SetAttribute(ATTR.WRACK_DIVE, (p.dives or 2) - a.wrackLadyLeft + 1)
		Fn.wrackLadyLeg(creature, p, "pass", now, a.wrackLadyTo, 0)
	elseif kind == "pass" then
		a.wrackLadyLeft -= 1
		prop.model:SetAttribute(ATTR.WRACK_DIVE, 0)
		if a.wrackLadyLeft > 0 then
			Fn.wrackLadyLane(creature, p, now)
			if Fn.wrackWillFire(creature, def) then
				Fn.wrackLaneTell(
					p,
					a.wrackLadyFrom,
					a.wrackLadyAim,
					p.lane or 12,
					(p.approach or 56) + (p.pastBy or 56)
				)
			end
			Fn.wrackLadyLeg(creature, p, "rearm", now, a.wrackLadyFrom, p.rearm or p.lead or 1.1)
		else
			Fn.wrackLadyLeg(creature, p, "home", now, a.wrackLadyDock, p.redock or 0.8)
		end
	elseif kind == "home" then
		-- Re-docked. She is scenery again, and the model goes with her: the hull
		-- has its own figurehead drawn on it, so leaving a second one standing at
		-- the prow would be a shootable prop that answers nothing.
		prop.model:SetAttribute(ATTR.WRACK_DIVE, nil)
		a.wrackLadyProp = nil
		CreatureService.despawn(prop.model)
	end
end

-- THE MAIN BOOM. p: rows, arc, sweep, inner, outer, width, boomLen, tackleFly,
-- damage.
--
-- A rotating line, which is the anchor line's drag bent into an arc - and the
-- same discipline: the angle is computed from the clock in ONE place, and both
-- the hitbox and the published bearing are taken from it a line apart, so the
-- drawn spar and the thing that hurts cannot drift.
--
-- THE HIT TEST IS A PERPENDICULAR DISTANCE, NOT AN ANGLE. A fixed angular
-- half-width would make the boom eleven studs wide at the hull and thirty at the
-- band's edge - a spar that grows as it swings - and the player standing at the
-- outer edge would be hit by ground the tell never covered.
K.ATTACK_HANDLERS.boomsweep = {
	windup = function(creature, def, p, u, sub)
		local a = creature.attack
		if not a.wrackAimed then
			a.wrackAimed = true
			local aim = wrackAim(creature)
			-- Where the spar is stepped. Fallback: amidships, above the guns.
			a.wrackBoomAt =
				Fn.wrackMountPoint(creature, def, Fn.wrackRigging(creature, def, "boom", Vector3.new(0, 14, 0)))
			local half = math.rad(p.arc or 140) * 0.5
			-- IT STARTS ON ONE SIDE OF THE LATCHED PLAYER AND ENDS ON THE OTHER,
			-- so the sweep crosses him halfway through rather than chasing him:
			-- the whole warning is "this arc, in this direction, starting now".
			-- The direction is rolled so the fight cannot be answered by always
			-- stepping the same way.
			a.wrackBoomDir = if math.random() < 0.5 then 1 else -1
			a.wrackBoomFrom = Fn.wrackAngle(aim) - half * a.wrackBoomDir
			a.wrackBoomAngle = a.wrackBoomFrom
			a.wrackBoomHit = {}
		end
		if not a.wrackTold and Fn.wrackWillFire(creature, def) then
			a.wrackTold = true
			local inner = p.inner or 24
			local outer = p.outer or 34
			-- WHICH GROUND (the band) and WHICH SIDE (the spar's start), because
			-- either alone is a lie: a ring says nothing about where the swing
			-- begins, and a lane says nothing about how far out it reaches.
			fireEvent("telegraph", creature.anchor or creature.pos, {
				kind = "ringTell",
				duration = p.windup,
				radius = outer,
				inner = inner,
				skin = p.skin,
			})
			local dir = Vector3.new(math.cos(a.wrackBoomFrom), 0, math.sin(a.wrackBoomFrom))
			Fn.wrackLaneTell(p, creature.anchor or creature.pos, dir, p.width or 10, outer)
			-- THE SPAR ITSELF IS PART OF THE TELEGRAPH, which is why the tackle
			-- is put up here and not in `fire`: it hangs over the sand for the
			-- whole windup, it is shootable for the whole windup, and breaking it
			-- there is the earliest and cheapest answer the move has.
			local prop = Fn.wrackProp(creature, p, a.wrackBoomAt, (p.windup or 2.2) + (p.sweep or 3.0) + 2)
			if prop then
				a.wrackBoomProp = prop
				Fn.wrackBoomPlace(creature, p, a.wrackBoomFrom)
			end
			creature.model:SetAttribute(ATTR.WRACK_BOOM, a.wrackBoomFrom)
		end
		creature.model:PivotTo(poseCFrame(creature, sub + 0.35 * smoothstep(u), 0, math.rad(-14) * u))
	end,
	fire = function(creature, def, p, now)
		local a = creature.attack
		-- NOTHING IS EMITTED: the sweep is the strike, and it is stepped below.
		-- This hook exists to start the clock, and to be the one place the burst
		-- window can stop the move without touching the phase machine.
		a.wrackBoomFrom = a.wrackBoomFrom or 0
		a.wrackBoomStart = now
		a.wrackBoomLive = Fn.wrackWillFire(creature, def) and a.wrackBoomProp ~= nil
		local lo, hi = Fn.bossRoll(creature, def, p.damage)
		a.wrackBoomLo, a.wrackBoomHi = lo, hi
	end,
	strike = function(creature, _def, p, now, _dt, _u, _root, sub)
		Fn.wrackBoomStep(creature, p, now)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.2, 0, math.rad(10)))
	end,
	finish = function(creature, _def, _p, _now)
		local a = creature.attack
		creature.model:SetAttribute(ATTR.WRACK_BOOM, nil)
		if a and Fn.wrackPropLive(a.wrackBoomProp) then
			CreatureService.despawn(a.wrackBoomProp.model)
		end
		if a then
			a.wrackBoomProp = nil
		end
	end,
}

-- The tackle rides the spar's tip: same angle, same frame, one call apart from
-- the attribute that publishes it. That is the whole reason the client can draw
-- the boom two ways and get one answer.
function Fn.wrackBoomPlace(creature, p, angle: number)
	local a = creature.attack
	local pivot = a.wrackBoomAt
	if not pivot then
		return
	end
	local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
	Fn.wrackPlaceProp(a.wrackBoomProp, pivot + dir * (p.boomLen or 30), yawToward(dir), p.tackleFly or 6)
end

-- The swing, and the band it clears.
function Fn.wrackBoomStep(creature, p, now: number)
	local a = creature.attack
	if not a.wrackBoomLive then
		return
	end
	if not Fn.wrackPropLive(a.wrackBoomProp) then
		-- THE TACKLE IS SHOT AWAY AND THE BOOM DROPS - on this frame, not at the
		-- end of the sweep. A shootable part that only promises to end the thing
		-- it is attached to is worse than no part at all (the midlink's rule).
		local at = a.wrackBoomAt or (creature.anchor or creature.pos)
		a.wrackBoomLive = false
		a.wrackBoomProp = nil
		creature.model:SetAttribute(ATTR.WRACK_BOOM, nil)
		fireEvent("decoyPop", at, { fizzle = true, skin = p.skin })
		return
	end
	local sweep = math.max(p.sweep or 3.0, 0.1)
	local t = math.clamp(now - (a.wrackBoomStart or now), 0, sweep)
	local angle = a.wrackBoomFrom + a.wrackBoomDir * math.rad(p.arc or 140) * (t / sweep)
	a.wrackBoomAngle = angle
	creature.model:SetAttribute(ATTR.WRACK_BOOM, angle)
	Fn.wrackBoomPlace(creature, p, angle)
	local centre = creature.anchor or creature.pos
	local inner, outer = p.inner or 24, p.outer or 34
	local halfWidth = (p.width or 10) * 0.5
	for _, entry in Fn.livingRootsNear(centre, outer) do
		if not a.wrackBoomHit[entry.player] then
			local rp = entry.root.Position
			local dx, dz = rp.X - centre.X, rp.Z - centre.Z
			local r = math.sqrt(dx * dx + dz * dz)
			-- Inside the band, and inside the SPAR's own width measured square to
			-- it: r * sin(delta) is the perpendicular distance to the line, which
			-- is the same eleven studs at every radius.
			if r >= inner and r <= outer then
				local off = math.abs(r * math.sin(angleDelta(math.atan2(dz, dx), angle)))
				if off <= halfWidth then
					a.wrackBoomHit[entry.player] = true
					PlayerService.damage(entry.player, math.random(a.wrackBoomLo, a.wrackBoomHi), creature, {
						bypassIframe = true,
					})
				end
			end
		end
	end
	if t >= sweep then
		-- Stowed. The attribute goes to nil for the same reason it does when the
		-- tackle is shot away: "no boom out" is one state, however it was reached.
		a.wrackBoomLive = false
		creature.model:SetAttribute(ATTR.WRACK_BOOM, nil)
		if Fn.wrackPropLive(a.wrackBoomProp) then
			CreatureService.despawn(a.wrackBoomProp.model)
		end
		a.wrackBoomProp = nil
	end
end

-- BILGE BLOW. p: hatchGap, steps, spacing, startAt, interval, arm, radius,
-- damage.
--
-- Three hatches, three radials, and NOTHING TO SHOOT. Every other move in this
-- fight can be answered with the gun; this one can only be answered with the
-- feet, which is what makes it worth pairing (see the phase table's note) with
-- the two moves that most want you standing still on the near ring.
--
-- THE ERUPTIONS ARE `Fn.queueStrike` ENTRIES AND NOTHING ELSE. The tell (a `mark`
-- carrying this row's skin), the arm window, the damage roll, the impact event
-- and the cleanup are all the arsenal's, already written and already drawn by the
-- client - a geyser is a barrage "line" that happens to start at a hatch instead
-- of at the boss. The handler's whole job is to say where the lines are.
K.ATTACK_HANDLERS.bilgeblow = {
	windup = function(creature, def, p, u, sub)
		local a = creature.attack
		if not a.wrackAimed then
			a.wrackAimed = true
			local aim = wrackAim(creature)
			-- The three hatches, boss-local. Fallback: three points off the
			-- centreline of the published hull box, far enough off it that each
			-- one has a radial worth marching along (a hatch ON the centre has no
			-- outward direction at all, which is the one shape this cannot use).
			local hatches = Fn.wrackRigging(creature, def, "hatches", {
				Vector3.new(10, 9, 4),
				Vector3.new(-2, 9, -5),
				Vector3.new(-14, 9, 4),
			})
			local centre = creature.anchor or creature.pos
			local aimAngle = Fn.wrackAngle(aim)
			local order = {}
			for i, m in hatches do
				local at = Fn.wrackMountPoint(creature, def, m)
				local angle = math.atan2(at.Z - centre.Z, at.X - centre.X)
				table.insert(order, { index = i, at = at, angle = angle })
			end
			-- IT STARTS UNDER THE PLAYER IT LATCHED. The sequence runs from the
			-- hatch whose radial points nearest at him outward through the other
			-- two, so the first geyser is the one he has least time to read and
			-- the move opens by taking the ground he is actually on.
			table.sort(order, function(x, y)
				return math.abs(angleDelta(x.angle, aimAngle)) < math.abs(angleDelta(y.angle, aimAngle))
			end)
			a.wrackHatch = order
		end
		if not a.wrackTold and Fn.wrackWillFire(creature, def) then
			a.wrackTold = true
			local reach = (p.startAt or 26) + ((p.steps or 6) - 1) * (p.spacing or 9)
			fireEvent("telegraph", creature.anchor or creature.pos, {
				kind = "ringTell",
				duration = p.windup,
				radius = reach + 5,
				inner = math.max(0, (p.startAt or 26) - 5),
				skin = p.skin,
			})
		end
		creature.model:PivotTo(poseCFrame(creature, sub - 0.25 * u, 0, math.rad(8) * u))
	end,
	fire = function(creature, def, p, now)
		local a = creature.attack
		if not Fn.wrackWillFire(creature, def) or not a.wrackHatch then
			return
		end
		local centre = creature.anchor or creature.pos
		local gap = p.hatchGap or 0.9
		local steps = math.max(1, p.steps or 6)
		local interval = p.interval or 0.30
		local arm = p.arm or 0.85
		for k, hatch in a.wrackHatch do
			local pop = now + (k - 1) * gap
			local dir = Vector3.new(math.cos(hatch.angle), 0, math.sin(hatch.angle))
			for i = 1, steps do
				-- MARCHING OUT, one step at a time, each one told `arm` seconds
				-- before it lands: the column is readable as a direction rather
				-- than as a set of discs, and the answer is to step off the
				-- radial, not to outrun it.
				local at = groundedPos(centre + dir * ((p.startAt or 26) + (i - 1) * (p.spacing or 9)), 0)
				local hitAt = pop + arm + (i - 1) * interval
				Fn.queueStrike(creature, def, p, at, hitAt - arm, hitAt, {})
			end
			-- The lid's own clock, for the attribute below: open a beat before
			-- its first eruption is told, shut when its last one has landed.
			hatch.openAt = pop
			hatch.shutAt = pop + arm + (steps - 1) * interval + 0.3
		end
	end,
	strike = function(creature, _def, _p, now, _dt, _u, _root, sub)
		Fn.wrackHatchPublish(creature, now)
		creature.model:PivotTo(poseCFrame(creature, sub - 0.15, 0, math.rad(-6)))
	end,
	finish = function(creature, _def, _p, _now)
		-- The lids shut with the move. The GEYSERS do not need collecting: they
		-- are `creature.strikes`, which the creature walk owns and drops when the
		-- boss dies - the one piece of these three moves that deliberately
		-- outlives its own row, so a column told at the last moment still lands.
		creature.model:SetAttribute(ATTR.WRACK_HATCHES, nil)
		local a = creature.attack
		if a then
			a.wrackHatch = nil
		end
	end,
}

-- Which lids are open, as one bitmask, written only when it CHANGES. A number
-- per frame would be three-quarters of a wire message saying nothing new; the
-- edges are the whole content of this channel.
function Fn.wrackHatchPublish(creature, now: number)
	local a = creature.attack
	if not a or not a.wrackHatch then
		return
	end
	local mask = 0
	for _, hatch in a.wrackHatch do
		if hatch.openAt and now >= hatch.openAt and now < (hatch.shutAt or 0) then
			mask += bit32.lshift(1, hatch.index - 1)
		end
	end
	if mask ~= a.wrackHatchMask then
		a.wrackHatchMask = mask
		creature.model:SetAttribute(ATTR.WRACK_HATCHES, if mask == 0 then nil else mask)
	end
end

function Fn.spawnBossParts(creature, def)
	local parts = def.parts
	local row = Creatures.items[parts.row]
	if not row then
		warn(string.format("[CreatureService] boss %q parts name unknown row %q", def.id, parts.row))
		return
	end
	-- THE SAME CENTRE THE POSE USES, not the raw anchor. `spawn` lifts a
	-- creature by half its own thickness and `Fn.colossusState` snaps that back
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
		-- `arenaKey or islandId` - THE SAME FIELD, AND THE SAME REASON, AS
		-- `BossService.arenaPosition`.
		--
		-- A boss's island says which FIGHT this is; `arenaKey` says which ROOM
		-- it is fought in, and for every shipped boss they are the same string,
		-- so this is inert for all of them. `pyrelisk_heart` is the first row
		-- where they differ: its `islandId` is `"volcano"` on purpose (the
		-- fight record, the participants, `Cleared_volcano` and the ride home
		-- all key off it) while its eight pillar collars are authored in the
		-- `pyrelisk_heart` arena row, 40,000 studs away.
		--
		-- WITHOUT THIS the lookup finds `BossArenas.items.volcano`, which has
		-- no `sockets` at all, so `offsets` is nil and the plant falls through
		-- to the even-ring branch - which reads `parts.ring`, which the heart's
		-- row does not carry either. That is arithmetic on nil out of
		-- `Fn.spawnBossParts`: the eight pillars never stand, and a heart
		-- gated on `partsDown` with no parts is a boss nothing can ever make
		-- vulnerable. Silent in the data, loud only in the log.
		local arena = (def.arenaKey or def.islandId) and BossArenas.items[def.arenaKey or def.islandId]
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
	-- THE PARTY'S HEALTH MULTIPLIER, INHERITED. BossService scales a summoned
	-- boss by the size of the party the call gathered (user decision,
	-- 2026-09-06: "the boss will scale with party size") and rides the factor
	-- in on `extra.healthMult`, which `spawn` already reads. The parts must
	-- carry the SAME factor: in a parts-gated fight - the Kraken's arms, the
	-- Lantern Choir's `choir_stalk` - the arms and lanterns ARE the wall, and
	-- a wall that stayed solo-sized while the head scaled would make the fight
	-- EASIER per head as the party grew, which is backwards. Read off the
	-- record rather than passed in, so a ring that GROWS BACK mid-fight
	-- (Fn.updateChoir / the phase regrowth calls below) inherits it too.
	local healthMult = creature.extra and creature.extra.healthMult

	-- THE TRUE LURE: one of them, redrawn every time the choir grows back, so
	-- "which light is real" is never answered twice by the same socket.
	local marked = if parts.mark then math.random(1, count) else nil
	local planted, markedPlanted = 0, false
	-- THE CHOIR, AS A LIST. `Fn.updateChoir` needs these seven every frame and
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
			--
			-- THE TRANSFORM ITSELF NOW LIVES IN `Fn.wrackMountPoint`, one call
			-- away, and this is the only place that reaches it through a parts
			-- ring. It was lifted out (2026-09-09) because Wrack's rigging - the
			-- figurehead's dock, the boom's pivot, the three bilge hatches -
			-- arrives from the SAME mesh handoff in the SAME boss-local
			-- convention as these mounts, and a second copy of this arithmetic
			-- written beside those handlers would be a convention to get wrong
			-- twice. `at = "mounts"` is Wrack's mode alone (the Kraken's ring
			-- takes `bearings`, the Choir takes `sockets`), so nothing else
			-- passes through here.
			at = Fn.wrackMountPoint(creature, def, m)
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
			healthMult = healthMult, -- the party's scaling, see above (nil = 1x)
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
			-- "SHOOT THIS" - published rather than left for each client to
			-- infer from a row id. Only for a ring that actually GATES the
			-- boss: a marked ring (Noctyss's choir) is a which-one puzzle, and
			-- flagging all seven as the answer would give that puzzle away.
			if creature.row.vulnerableWhen == "partsDown" then
				model:SetAttribute(ATTR.WEAKPOINT, true)
			end
			-- A RING WAKES STAGGERED. `Fn.updateTentacle` reads
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
			model:SetAttribute(ATTR.SOCKET_INDEX, i)
			-- The client needs this to draw the off-rhythm pulse, which IS
			-- the tell - so it is published, not hidden. The honest
			-- alternative (publishing each bulb's phase offset) carries the
			-- same information in a form that is harder to read.
			model:SetAttribute(ATTR.TRUE_LURE, part.marked)
			model:SetAttribute(ATTR.POSE_CENTER, centre)
			if parts.mark then
				model:SetAttribute(ATTR.POSE, "choir_stalk")
				-- OUT OF THE STONE, NOT INTO EXISTENCE. Stamped 0 on the frame
				-- the stalk is planted and ramped to 1 by `Fn.updateChoir` over
				-- K.CHOIR_REGROW; see ATTR.GROW for why the server is allowed
				-- to write this at all now. Both halves are here, not just the
				-- attribute: `growPub` is the published copy the ramp diffs
				-- against, and `untargetable` keeps the party from trading with
				-- a lantern that is still inside its collar (the ramp rewrites
				-- it every frame from here on).
				part.growPub = 0
				part.untargetable = true
				model:SetAttribute(ATTR.GROW, 0)
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
	creature.model:SetAttribute(ATTR.EXPOSED, nil)
	creature.choir = parts.mark == true
	creature.trueLure = marked
	if creature.choir and creature.pose then
		-- A fresh choir stands up: clear the last cycle's fallen shapes, and
		-- the last cycle's SWINGS. The stalk loop below marks all seven alive
		-- again, which is exactly what would resurrect a stale descriptor into
		-- a limb the fight thinks is busy - and `state.trueLure` is being
		-- rewritten on the next line, so the socket carrying the answer could
		-- be the one holding it.
		Fn.clearChoirAttacks(creature.pose)
		creature.pose.trueLure = marked
		for _, stalk in creature.pose.stalks do
			stalk.alive, stalk.fall, stalk.douse, stalk.lean = true, 0, 0, 0
		end
	end
	-- THE RISE'S CLOCK, and it is one clock for all seven rather than one
	-- each: they come out of the stone together, which is the beat (a choir
	-- standing up), and one number is also what makes `Fn.choirGrown` a
	-- question with an answer. Stamped last, after the pose state above has
	-- finished putting the stalks back - the first `Fn.updateChoir` frame after
	-- this writes the 0 into that state and into every model.
	if creature.choir then
		creature.choirGrowAt = os.clock()
	end
end

-- ---------------------------------------------------------- the maw window
--
-- The three-beat loop's third beat, and the only time she can be hurt:
-- break the true lure, the maw comes up through the pit, the party fights
-- INSIDE it until the jaw closes. Then the choir grows back with a different
-- true lure and the question is asked again.
local function openMaw(creature, def, now: number)
	local state = Fn.colossusState(creature, def)
	creature.mawOpen = true
	creature.mawUntil = now + ((def.parts and def.parts.window) or 12)
	creature.mawDueAt = nil
	-- ONE PORTCULLIS PER WINDOW, and this is the flag that says so. Cleared at
	-- the open rather than at the close, so the arming below cannot be
	-- inherited from the previous cycle by any path that reaches `openMaw`.
	creature.doorArmed = nil
	creature.doorSlots = nil
	creature.untargetable = false
	creature.model:SetAttribute(ATTR.EXPOSED, true)
	-- She surfaces facing a gap between the shadow fins, aimed at whoever
	-- broke the lure: the fight comes to meet the party, not a rock.
	local root = Fn.nearestPlayerRoot(creature.anchor or creature.pos)
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
	local state = Fn.colossusState(creature, def)
	creature.mawOpen = false
	creature.mawUntil = nil
	creature.untargetable = true
	-- ANY LIMB STILL SWINGING STOPS HERE. This close withdraws the whole choir
	-- (`removeOwnedParts`, below), and a withdrawn stalk is never asked about
	-- again - so a descriptor left in the pose state would outlive the limb it
	-- described and be waiting when the regrow marks that socket alive. Damage
	-- already cannot land (the tick re-reads `attackFor` every frame and the
	-- stalk is about to be dead), so this is the busy flag, the lean and the
	-- regrow's `grow` (see there).
	Fn.clearChoirAttacks(state)
	-- ...and the ring's rise clock with it: the choir this stamped is being
	-- withdrawn on the next few lines, and the next one stamps its own.
	creature.choirGrowAt = nil
	-- CLEARED, not set false: the HUD only ever asks `Exposed == true` (both
	-- read as sealed), but every other earned window in this file - the
	-- stagger's, the collapse's - removes the attribute, and one boss leaving
	-- a stale `false` behind is the kind of difference someone later reads as
	-- meaning something.
	creature.model:SetAttribute(ATTR.EXPOSED, nil)
	-- THE BITE. Whoever is still standing in her mouth when it shuts wears
	-- it: the window is generous, and leaving is the player's job.
	-- Player MAX_HEALTH is 100: at 120-170 this was a guaranteed kill with no
	-- counterplay for anyone knocked back into the mouth on the last beat.
	-- 70-95 still ends a hurt player and still means "leave when it starts to
	-- shut", which is the read the window is teaching.
	local lo, hi = Fn.bossRoll(creature, def, { 70, 95 })
	-- ...AND IT ACTUALLY LANDS. `bypassIframe` skips the ordinary contact
	-- window but NOT the previous bypassing burst's, and bursts gate each
	-- other for 0.35s (PlayerService `lastBurst`). She keeps attacking while
	-- the jaw shuts, so a strobe ring or a feeler landing a fraction before
	-- the close swallowed the bite outright - and the one lesson the window
	-- teaches, "leave when it starts to shut", was enforced or not by a coin
	-- flip nobody could see. What could not be delivered is written down and
	-- re-offered by `Fn.updateNoctyss` until it lands. The ROLL is kept: the
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
-- rather than the code. Strobewave is an ordinary `barrage` entry (so was
-- abysscall, until the legibility pass cut that row), and the punctuation that
-- used to live here jolted the ring on the
-- move's own `interval` by writing `stalk.impulse`. That field is not
-- replicated (see the note above `mawFloor`), so the jolt moved nothing any
-- player could see; the recoils that survive are the ones the CLIENT raises
-- off the hits it watches land. The comment outlived its function and had run
-- headlong into the one below it, mid-sentence, describing machinery that no
-- longer exists.

-- The whole Gloomtrench fight, in one pass: keep the choir standing, answer
-- a broken lure, run the maw window, and let the book pick what happens next.
-- Deliberately its own function rather than more branches inside Fn.updateBoss -
-- nothing about this boss shares the prowl/entrench machinery, because she
-- never moves and is never reachable except inside her own mouth.
function Fn.updateNoctyss(creature, def, now: number, dt: number, root, player, dist: number)
	local state = Fn.colossusState(creature, def)
	-- THE SHAPE'S CLOCK, ADVANCED. Sway, breath and every flinch are terms in
	-- `state.time`, and the bulb they move IS the stalk's hitbox: left at 0
	-- the server would stand each hitbox at the un-swayed lantern while the
	-- client drew a swaying one, and a shot through the light you can see
	-- would miss for reasons nothing in either log could explain. The module's
	-- clock is server time on both sides, so feeding it here is what keeps
	-- them the same object.
	state.time = NoctyssPath.clock()
	Fn.hideColossusModel(creature)
	Fn.updateChoir(creature, state, dt)

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
		fireEvent("lureFlare", at, { radius = 18, skin = "lure" })
		-- The flare belongs at the lantern, but the DAMAGE has to reach the
		-- floor. A stalk's position IS its bulb, ~30 studs up, and the AOE's
		-- default height tolerance is 6 - so this burst was hitting nobody,
		-- every time, and breaking a false lure cost the party nothing at all.
		local ground = Vector3.new(at.X, (creature.anchor or creature.pos).Y, at.Z)
		-- THE RING IS THE FOOTPRINT, so it is drawn at the radius that hurts.
		-- 12 against a 15-stud burst was the fight drawing a smaller shape than
		-- it tested, which is the one lie a telegraph is never allowed to tell -
		-- and this one is a reactive punish with no windup to re-read it in.
		fireEvent("slam", ground, { radius = 18, skin = "ink" })
		-- 55-75 IN r18, UP FROM 40-58 IN r15. `falselight` was cut by the
		-- legibility pass (Bosses.luau, above `phases`) and this is where its
		-- weight went: three ambient fake lanterns with no floor mark, replaced
		-- by paying properly for the punish the fight already EARNS. Shooting
		-- the wrong lantern is a mistake the player made by misreading the one
		-- rhythm the whole fight is built on, and it should cost like one.
		local lo, hi = Fn.bossRoll(creature, def, { 55, 75 })
		damagePlayersInRadius(ground, 18, lo, hi, creature, 0.35)
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
		-- THE DOOR COMES DOWN. `creature.mawUntil` IS the jaw's shut time - it
		-- is what the close below compares `now` against - so jawShutsAt is
		-- that number and the bars are armed at jawShutsAt - DOOR.LEAD, which
		-- is `left <= DOOR.LEAD`. Once per window (`doorArmed`), and tunable
		-- off the row: `portcullis = false` puts the window back exactly as it
		-- was, with no other line in the fight touched.
		if def.portcullis ~= false and not creature.doorArmed and left <= NoctyssPath.DOOR.LEAD then
			creature.doorArmed = true
			Fn.armPortcullis(creature, def)
		end
		-- Ticked for the whole window and not only after the arming: the slots
		-- are nil until then, and the bars' live window ends on the exact frame
		-- the jaw shuts (LEAD 1.6 = SLAM.WINDUP 1.2 + SLAM.LIVE 0.4), so
		-- nothing of theirs outlives the close.
		Fn.tickPortcullis(creature, def)
		local target = 1
		if state.mawRise < 0.75 then
			target = 0
		elseif left < 2.0 then
			target = math.max(left / 2.0, 0)
		end
		state.mawGape = (state.mawGape or 0) + (target - (state.mawGape or 0)) * math.min(dt * 3.0, 1)
		Fn.placeMawFloor(creature, state)
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
		Fn.spawnBossParts(creature, def)
		fireEvent("regrow", creature.anchor or creature.pos, { count = def.parts.count, name = def.name })
	end

	if creature.mode == "attack" then
		Fn.updateBossAttack(creature, def, now, dt, root, player, dist, -def.submerge)
	elseif root and now >= creature.nextAttackAt and dist <= def.aggro then
		local name = Fn.pickBossAttack(creature, def, now)
		-- LIGHTSWEEP WITHOUT A STALK IS FOUR AND A HALF SECONDS OF NOTHING.
		-- Its handler needs a living, LIT lantern to sweep from; with none it
		-- plays no telegraph, fires no beam and lands nothing, then spends
		-- windup + duration + recover (4.5s) and its 5.5s cooldown doing it.
		-- That is not a rare case: it is the whole 4-second regrow dark after
		-- every window, every dousehunt, and any moment the party has cleared
		-- the choir - and lightsweep is listed TWICE in stances 1 and 3 and is
		-- what `Fn.pickBossAttack`'s empty-pool fallback returns (the phase
		-- list's first entry). Checked here, before the attack begins, because
		-- this is the fight's only call site and a handler cannot un-begin
		-- itself once `Fn.beginBossAttack` has drawn its tell and set its clock.
		--
		-- ...AND THE HOLE IS FOUR MOVES WIDE NOW. The three limb swings need a
		-- stalk that is alive, not already mid-swing, and long enough to reach
		-- the target, so `Fn.choirMoveReady` asks the question for all four.
		-- Twice, because one re-pick can hand back another move with the same
		-- problem.
		for _ = 1, 2 do
			if Fn.choirMoveReady(state, name, root) then
				break
			end
			-- Held off for a beat so the re-pick below cannot hand back the
			-- same move, and so a dark that lasts several attack gaps does not
			-- re-ask the same question every time.
			creature.cooldowns = creature.cooldowns or {}
			creature.cooldowns[name] = now + ((def.attacks[name] and def.attacks[name].cooldown) or 5.5)
			name = Fn.pickBossAttack(creature, def, now)
		end
		-- The fallback's fallback: everything else is on cooldown too, so it
		-- returned the phase list's first entry, which is lightsweep again.
		-- `feelerstrike` used to be the answer here because it needed nothing
		-- but a player; it is a limb swing now and needs a limb, so it is only
		-- offered if it actually has one.
		--
		-- AND WHEN IT DOES NOT, SHE DEFERS. `abysscall` used to stand here as
		-- the move that needed neither a limb nor a lantern, which is also the
		-- only reason it was still in the book - and twenty-one ink discs
		-- marching out of the pit was the single largest contributor to the
		-- mark count this fight was drowning in (see the legibility note above
		-- `phases` in Bosses.luau). The hole it was plugging is not a hole:
		-- there is no moment in this fight that needs a filler attack. The two
		-- moments this branch is actually reached are the punish window - when
		-- the choir is withdrawn and the pressure IS the closing jaw and the
		-- portcullis - and the regrow dark, when the pressure is the dark. So
		-- nothing is thrown, `nextAttackAt` is nudged a beat and the frame
		-- falls through to Fn.placeColossus exactly as it would have.
		--
		-- 0.6s rather than a full attack gap: this is a re-ask, not a rest, and
		-- the thing it is waiting on (a limb finishing its swing, the choir
		-- clearing its collars) resolves in about that long.
		local ready = Fn.choirMoveReady(state, name, root)
		if not ready and def.attacks.feelerstrike and Fn.choirMoveReady(state, "feelerstrike", root) then
			name, ready = "feelerstrike", true
		end
		if ready then
			Fn.beginBossAttack(creature, def, name, now)
		else
			creature.nextAttackAt = now + 0.6
		end
	end
	Fn.placeColossus(creature, def, now, root)
end

-- ============================================================ THE KRAKEN (2026-09-09)
--
-- THREE FIGHTS IN ONE BOOK. See Bosses.items.kraken for the design; this is the
-- machinery. In one paragraph: the party is dropped on a SHIP with the animal's
-- head planted 350 studs off the port beam, two ARMS are the damage targets,
-- breaking both inside one cycle slumps the head and opens a ~10s window on its
-- own health bar, four windows walk the fight through the waist, the full ship,
-- and finally the gullet - a second arena the siphon swallows everyone into.
--
-- WHAT THIS SECTION DELIBERATELY DOES NOT DO:
--   * it does not use `def.parts`. The generic ring regrows the WHOLE ring when
--     the LAST member falls, and this fight needs a per-arm twelve seconds. See
--     the `machine` comment on the row. Everything the ring gave for free is
--     kept, because the arms still carry `partOf`.
--   * it does not move the ship or tilt the deck (substitutions A and B on the
--     row, owner-approved). Both would mean moving authored geometry that every
--     height in this file is measured against, for a few seconds of feel.
--   * it does not draw anything. Every visual is an event or an attribute, and
--     the contract for both is at the top of this file.
--
-- THE GEOMETRY IS NOT GUESSED. Every number in K.KRAKEN is from
-- assets/arena_gen.py's `HANDOFF kraken` lines or measured off the exported
-- glb, and the axis mapping is stated once here: the generator authors X along
-- the ship (bow +X), Y across the beam with PORT at +Y, and Z as height with
-- the waterline at 0; the glTF export maps that to Roblox (X, Z, -Y). So
-- everything below is arena-local Roblox: X along the hull, Y height off the
-- sea, Z across the beam with PORT at NEGATIVE Z.
K.KRAKEN = {
	-- --------------------------------------------------------------- the ship
	DECK_Y = 8.0, -- main deck top (KA_DECK_Z)
	FC_Y = 15.0, -- forecastle (KA_DECK_Z + 7)
	QD_Y = 17.0, -- quarterdeck (KA_DECK_Z + 9)
	QD_TO_X = -40.0, -- x <= this is the quarterdeck (KA_QD_FRONT)
	FC_FROM_X = 50.0, -- x >= this is the forecastle (KA_FC_AFT)
	HULL_X = 85.0, -- the bow and stern posts (KA_SHIP_LEN / 2)
	-- THE SWEEP PLANE, and it is the one number a scythe is nothing without: a
	-- lateral sweep's underside sits deck + 3.0. Measured against that: the
	-- bulwark tops at deck+2.8 (clears by 0.2 - the rail never saves you), the
	-- tallest cargo at deck+2.7 (clears by 0.3 - the cover does), and a
	-- STANDING head at deck+5.0, which is two studs inside it.
	SWEEP_RISE = 3.0,
	STAND_HEAD = 5.0,
	-- How far a character's head stands over its HumanoidRootPart. Roblox has no
	-- crouch, so the fight's "low is spared" is played by cover rather than by
	-- posture - but the sweep still has to be tested against a head rather than
	-- a hip, or it would pass over a standing player by two studs of arithmetic.
	HEAD_OVER_ROOT = 2.5,
	-- How far outboard of a cover's authored footprint still counts as behind
	-- it. A body is about 2 studs wide and nobody stands INSIDE a crate; without
	-- this the only safe spot would be a mathematical point on its edge.
	COVER_MARGIN = 3.5,
	-- THE HEAD, arena-local. Off the PORT beam, which is -Z. It never moves.
	HEAD_AT = Vector3.new(0.0, 0.0, -370.0),
	-- ...and where its EYE is, relative to the head's own centre, at the pack's
	-- authored SCALE 6.0: the orbs sit at author (36.5, +/-16.3, 46.0), so 276
	-- studs up and 219 studs toward whatever it is facing. Only the eye lance
	-- reads this, and only to cast a line of sight from it - a ray that started
	-- at the head's pivot would begin 276 studs inside the animal's own hide.
	EYE_LIFT = 276.0,
	EYE_REACH = 219.0,
	-- SLAM DISCS, from the HANDOFF: the waist is 90 x 40, so r 12-16 owns its
	-- width without owning either cover stack and r 22 owns the room. The
	-- telegraph is the bigger one and the damage the smaller: the read is "get
	-- out of the middle", not "stand one stud outside a painted line".
	SLAM_R = 14.0,
	SLAM_TELL_R = 22.0,
	-- The knuckle: how far back along the limb from the hitbox toward the head
	-- the glowing joint sits, and how far it stands proud of the deck. Published
	-- for the renderer only - see ATTR.WEAKPOINT_POS.
	KNUCKLE_BACK = 26.0,
	KNUCKLE_LIFT = 6.0,
	-- WHAT A HOT KNUCKLE IS WORTH. Triple, and it is the only 3x in the game
	-- (the charger's expose window is 2x): the arm is only vulnerable while it
	-- is committed to something that is hurting you, so the multiplier has to be
	-- big enough that turning to hit it is worth eating the move.
	WEAK_MULT = 3.0,
	-- WHAT A LIT EYE IS WORTH, and it is deliberately the weakest window in the
	-- fight (the new-attacks pass, 2026-09-12). The eye lance now holds its flare
	-- for `glint` seconds after it fires and the HEAD takes this much for that
	-- window - see Bosses.items.kraken.attacks.eyelance for why 1.5 and not the
	-- 2.0 that `exposedUntil` means everywhere else: an eye that has just shot
	-- somebody has not over-committed, it has merely finished.
	GLINT_MULT = 1.5,
	-- HOW FAR UNDER THE SEA A CIRCLING LIMB'S HITBOX RIDES, during the maelstrom
	-- coil's three seconds of tracking. It has to be a real number rather than
	-- "at the target like every other planted phase", because the whole premise of
	-- the move is that the limb is UNDER the water and cannot be hit: parking the
	-- hitbox on the deck station it is tracking would let the party shoot a
	-- tentacle that visibly is not there, and shoot it at the exact moment the
	-- move is supposed to be making them move instead.
	--
	-- 70 down and 46 outboard are KrakenPath.COIL_DEPTH and COIL_OUT - the drawn
	-- limb's own station - so the thing you cannot hit is where the thing you
	-- cannot see is. (Not required to agree, since nothing can reach either; but
	-- two numbers that mean one thing should be one number's worth of wrong.)
	COIL_SINK = 70.0,
	COIL_OUT = 46.0,
	-- ------------------------------------------------------------- the gullet
	-- The room's own z = 0 floor datum, relative to its arena mesh's authored
	-- bbox bottom of -16. DERIVED from BossArenas.maelstrom_gullet.meshBottom
	-- rather than written down twice: move the row and the fight follows.
	GULLET_ARENA = "maelstrom_gullet",
	GULLET_BBOX = 16.0,
	GULLET_R = 118.0, -- the wall foot (KG_R)
	DAIS_R = 26.0, -- the finale dais (KG_DAIS_R)
	DAIS_TOP = 2.2, -- its top over the floor datum
	HEART_Y = 21.0, -- the heart mass, slung over the dais (KG_HEART_Z)
	-- The heart's capture sphere, against the head's 280. See Fn.krakenSwallow.
	HEART_HIT_R = 30.0,
	-- How far a character's HumanoidRootPart floats over its own feet. The acid
	-- tide is the one move in the fight with a height CEILING rather than a
	-- tolerance band, and a ceiling tested against a root instead of a pair of
	-- feet is three studs of free clearance - which on a 1.8-stud ceiling is
	-- everybody, everywhere, always safe.
	ROOT_OVER_FEET = 3.0,
	ENTRY_AT = Vector3.new(0.0, 2.4, 86.0), -- the entry pad, mirrored into Roblox
}

-- The three ArmPhases that mean "the limb is at its target and staying there".
-- Distinct to a renderer and identical to a hitbox; see Fn.krakenArmPlace.
-- FOUR MORE OF THEM AFTER THE NEW-ATTACKS PASS (2026-09-12), on exactly the same
-- argument: a phase belongs here when the hitbox is simply AT the arm's published
-- target, however different the four look to a renderer.
--   Spear  - the jab, at the mark it is going through.
--   Stuck  - the tip buried in the planking at that same mark, held for four
--            seconds. This is the grating spear's whole opening, so the hitbox
--            being exactly where the drawn tip is matters more here than anywhere:
--            a player is aiming at it for four seconds.
--   Drape  - spent over the near bulwark above its own station.
--   Erupt  - the column, which is only up for 0.6s and whose damage is at the
--            target by construction.
--
-- `Coil` is POINTEDLY NOT HERE and has its own branch in Fn.krakenArmPlace: it is
-- the one committed phase in the book whose limb is not where its target is, and
-- planting it would hand the party a tentacle to shoot on the deck while the real
-- one circles 70 studs under the sea. See K.KRAKEN.COIL_SINK.
K.KRAKEN_PLANTED = {
	Slam = true,
	Down = true,
	Wrapped = true,
	Spear = true,
	Stuck = true,
	Drape = true,
	Erupt = true,
}

-- How long a limb may stay committed with no attack running before the fight
-- tick stands it back up. Comfortably past the longest hold any move in the book
-- asks for (the wrench's 4-second channel plus its 6-second expose), so it can
-- only ever fire on a limb whose handler was cancelled out from under it. See
-- the STRANDED note in Fn.updateKrakenFight.
K.KRAKEN_ARM_STRAND = 12.0

-- THE FIGHT'S OWN STATE, created on first use. Kept on the creature struct
-- rather than in a module table so it dies with the boss - the abandon reaper,
-- the parentless-model drop and an admin restart all take it with them, and
-- none of them has to know it exists.
function Fn.krakenState(creature)
	local state = creature.kraken
	if not state then
		state = {
			-- Per-arm records, indexed by slot. `part` is the creature struct
			-- while the arm is standing and nil while it is withdrawn.
			arms = {},
			-- Custom hazard waves - the gullet's annuli-with-a-gap and its
			-- flood ranks. NOT `creature.strikes`: those resolve through
			-- `damagePlayersInRadius` with the boss kit's flat 14-stud height
			-- tolerance, and both of these moves are ABOUT height (the dais is
			-- safe from the tide) or about an arc (the gap is the whole
			-- mechanic). See Fn.krakenStepWaves.
			waves = {},
			-- Anchored props the fight steps itself: the wrench's sliding
			-- barrels and the mast bell's spar. Every one carries its own
			-- `expiresAt` AND a task.delay self-destruct, so a fight that ends
			-- underneath one is never the reason a part is left in the world.
			props = {},
			windows = 0,
			polypsPlanted = 0,
		}
		creature.kraken = state
	end
	return state
end

-- The ship arena's row, and the world point its authored origin sits on. The
-- boss rose at the arena centre (BossService.arenaPosition), and for a
-- sea-level arena `floorY` answers WATER_Y exactly - so `creature.anchor` IS
-- arena-local (0, 0, 0) and every number in K.KRAKEN adds straight onto it.
function Fn.krakenShip(creature)
	return creature.krakenShip or creature.anchor or creature.pos
end

-- Arena-local (Roblox axes, see the header) to world.
function Fn.krakenAt(creature, x: number, y: number, z: number): Vector3
	local o = Fn.krakenShip(creature)
	return Vector3.new(o.X + x, o.Y + y, o.Z + z)
end

-- ...and back: world to arena-local. Returns the three components rather than a
-- Vector3 because every caller wants them apart (which deck is this X on, is
-- this Z inside the lane, is this Y over the sweep plane).
function Fn.krakenLocal(creature, at: Vector3): (number, number, number)
	local o = Fn.krakenShip(creature)
	return at.X - o.X, at.Y - o.Y, at.Z - o.Z
end

-- WHICH DECK IS UNDER THIS STATION, and its sweep plane. Phase one only ever
-- sees the middle branch - the waist is the whole arena until the castles open -
-- but the function does not need to know that, because phase one never asks
-- about a station outside the waist.
function Fn.krakenDeckY(x: number): number
	local kr = K.KRAKEN
	if x <= kr.QD_TO_X then
		return kr.QD_Y
	elseif x >= kr.FC_FROM_X then
		return kr.FC_Y
	end
	return kr.DECK_Y
end

-- The three decks a phase can sweep, as { local X min, local X max, deck Y }.
-- Phase one gets the waist alone; phase two gets all three, which is exactly
-- what makes a single world-height sweep stop working (arena_gen's own warning:
-- one plane would be head-high in the waist and knee-high nowhere).
function Fn.krakenDecks(phase: number)
	local kr = K.KRAKEN
	if phase >= 2 then
		return {
			{ kr.QD_TO_X, kr.FC_FROM_X, kr.DECK_Y },
			{ kr.FC_FROM_X, kr.HULL_X, kr.FC_Y },
			{ -kr.HULL_X, kr.QD_TO_X, kr.QD_Y },
		}
	end
	return { { kr.QD_TO_X, kr.FC_FROM_X, kr.DECK_Y } }
end

-- IS THIS POINT BEHIND A PIECE OF DECK CARGO? The answer to the scythe, to the
-- wrench's barrels and to the heave's drag, and it is one function because it
-- has to be one answer - three tests that disagreed about where safety is would
-- all look right in isolation, which is the failure this project has a standing
-- rule about.
--
-- Rectangular, because the cargo is crates: `sizeX`/`sizeZ` off the arena row
-- (BossArenas), falling back to the circular `radius` for a row that has not
-- opted in. Grown by COVER_MARGIN, because nobody stands inside a crate.
function Fn.krakenBehindCover(creature, at: Vector3): boolean
	local arena = BossArenas.items.maelstrom
	local cover = arena and arena.cover
	if not cover then
		return false
	end
	local x, _y, z = Fn.krakenLocal(creature, at)
	local margin = K.KRAKEN.COVER_MARGIN
	for _, site in cover do
		local hx = (site.sizeX or site.radius) + margin
		local hz = (site.sizeZ or site.radius) + margin
		if math.abs(x - site.offset.X) <= hx and math.abs(z - site.offset.Z) <= hz then
			return true
		end
	end
	return false
end

-- The four cover footprints in WORLD space, in the shape a client can test a
-- character against without knowing anything about arena-local axes. Sent with
-- the heave's pull, because that drag is applied by each client to its own
-- character (the lure-pull channel) and the exemption has to travel with it.
function Fn.krakenCoverBoxes(creature)
	local arena = BossArenas.items.maelstrom
	local boxes = {}
	for _, site in (arena and arena.cover or {}) do
		local at = Fn.krakenAt(creature, site.offset.X, 0, site.offset.Z)
		table.insert(boxes, {
			x = at.X,
			z = at.Z,
			hx = (site.sizeX or site.radius) + K.KRAKEN.COVER_MARGIN,
			hz = (site.sizeZ or site.radius) + K.KRAKEN.COVER_MARGIN,
		})
	end
	return boxes
end

-- Where the head's EYE is in world space. It faces the ship, so "forward" is
-- from the head toward the arena origin.
function Fn.krakenEye(creature): Vector3
	local kr = K.KRAKEN
	local head = Fn.krakenAt(creature, kr.HEAD_AT.X, 0, kr.HEAD_AT.Z)
	local ship = Fn.krakenShip(creature)
	local toward = Vector3.new(ship.X - head.X, 0, ship.Z - head.Z)
	toward = if toward.Magnitude > 0.001 then toward.Unit else Vector3.new(0, 0, 1)
	return head + toward * kr.EYE_REACH + Vector3.new(0, kr.EYE_LIFT, 0)
end

-- The gullet's floor datum in world Y, and its centre. DERIVED from the arena
-- row so the room can be moved in one place: `meshBottom` pins the mesh's
-- authored bbox floor (-16) and the room's own z = 0 is GULLET_BBOX above it.
function Fn.krakenGulletFloor(): Vector3
	local arena = BossArenas.items[K.KRAKEN.GULLET_ARENA]
	if not arena then
		return Vector3.zero
	end
	return Vector3.new(arena.center.X, (arena.meshBottom or 0) + K.KRAKEN.GULLET_BBOX, arena.center.Z)
end

-- ---------------------------------------------------------------- the arms

-- Write one arm's state, publish it, and stamp the timestamp the client eases
-- from. THE SMOOTHNESS RULE lives here and nowhere else: `ArmPhaseAt` is set
-- once per transition and `ArmT` every frame, so a renderer never has to guess
-- when a phase began and never sees a limb teleport between poses.
function Fn.krakenArmPhase(arm, phase: string, now: number, target: Vector3?, wrap: number?)
	arm.phase = phase
	arm.phaseAt = now
	arm.t = 0
	arm.target = target
	arm.wrap = wrap
	local part = arm.part
	if not part or part.dead or not part.model.Parent then
		return
	end
	local model = part.model
	model:SetAttribute(ATTR.ARM_PHASE, phase)
	model:SetAttribute(ATTR.ARM_PHASE_AT, now)
	model:SetAttribute(ATTR.ARM_T, 0)
	model:SetAttribute(ATTR.WRAP_INDEX, wrap)
	model:SetAttribute(ATTR.TARGET_X, target and target.X or nil)
	model:SetAttribute(ATTR.TARGET_Z, target and target.Z or nil)
end

-- RE-AIM A LIMB WITHOUT RE-STAMPING ITS PHASE, and the distinction is the whole
-- reason this exists next to Fn.krakenArmPhase rather than inside it.
--
-- `ArmPhaseAt` is THE CLIENT'S TRANSITION EDGE - KrakenBodyController.readArm
-- opens a fresh crossfade on every change of it, and resets ArmT with it - so a
-- move that wanted to move its aim mid-phase could not use krakenArmPhase: calling
-- it every frame would restart the blend every frame and the limb would never
-- finish arriving anywhere. That is exactly what the maelstrom coil needs to do
-- for three seconds, and it is the only move in the book that tracks.
--
-- So this writes the AIM and nothing else: the struct field the server's own
-- placement reads and the two attributes the drawn limb and its deck mark read.
-- No phase, no timestamp, no ArmT. One writer for the pair, for the same reason
-- Fn.krakenArmHot is one writer for its pair.
function Fn.krakenArmAim(arm, at: Vector3)
	arm.target = at
	local part = arm.part
	if not part or part.dead or not part.model.Parent then
		return
	end
	part.model:SetAttribute(ATTR.TARGET_X, at.X)
	part.model:SetAttribute(ATTR.TARGET_Z, at.Z)
end

-- WHERE A SPENT LIMB LIES, and it exists so the hitbox and the drawn limb cannot
-- disagree about the most-used opening in the fight (the new-attacks pass,
-- 2026-09-12).
--
-- `Drape` is a PLANTED phase - Fn.krakenArmPlace parks the hitbox exactly on the
-- arm's published target - so whatever is handed to Fn.krakenArmPhase as that
-- target is where the party's shots have to land. The drawn pose, meanwhile, rests
-- its tip on the planking `KrakenPath.DRAPE_Z` studs inboard of the port bulwark at
-- that station's own deck height. The first draft of the deck scythe's new ending
-- handed it the SWEEP LANE's far end, which is at the sweep plane - deck + 3 + a
-- shoulder's girth, 35 studs up - so the thing to shoot was a sphere floating three
-- storeys above the limb you could see. Exactly the silent-absence shape: a window
-- that is open, visibly open, and unhittable.
--
-- Taken from KrakenPath rather than from a number written twice, so re-authoring
-- the pose moves the hitbox with it.
function Fn.krakenDrapeAt(creature, x: number): Vector3
	local clamped = math.clamp(x, K.KRAKEN.QD_TO_X + 8, K.KRAKEN.FC_FROM_X - 8)
	return Fn.krakenAt(creature, clamped, Fn.krakenDeckY(clamped), KrakenPath.DRAPE_Z)
end

-- The knuckle glow, both halves together: the struct flag `damage()` reads
-- through `hitModifiers` and the two attributes the client draws. ONE writer,
-- so the multiplier and the glow can never disagree about whether the window is
-- open - which is the only way a 3x window can be unfair.
function Fn.krakenArmHot(arm, hot: boolean, at: Vector3?)
	arm.hot = hot
	local part = arm.part
	if not part or part.dead or not part.model.Parent then
		return
	end
	part.krakenHot = hot or nil
	part.model:SetAttribute(ATTR.WEAKPOINT_HOT, hot or nil)
	part.model:SetAttribute(ATTR.WEAKPOINT_POS, if hot then at else nil)
end

-- Plant one arm. The single-arm form of `Fn.spawnBossParts`, and it exists
-- because this fight's regrow is per arm rather than per ring - see the row's
-- `machine` comment. It keeps every property the generic ring gives a part:
-- `partOf` (so `kill` counts `partsAlive` down and `removeOwnedParts` takes it
-- with the boss), `socketIndex` (so `Fn.livingArms` finds it), the party's
-- health multiplier, the `Weakpoint` stamp the partsDown rule earns, and
-- noLinger / suppressed drops / a token bounty.
function Fn.plantKrakenArm(creature, def, slot: number, now: number)
	local row = Creatures.items["kraken_arm"]
	local rest = def.machine and def.machine.armRest and def.machine.armRest[slot]
	if not row or not rest then
		return
	end
	local at = Fn.krakenAt(creature, rest.X, K.KRAKEN.DECK_Y, rest.Z)
	local model = CreatureService.spawn(row, at, nil, "Neutral", {
		noLinger = true,
		suppressDrops = true,
		bounty = 0.5,
		healthMult = Fn.partyMult(creature), -- was creature.healthMult: NO SUCH FIELD (extra.healthMult is the real home) - nil rode through and the kraken's arms, dais adds and polyps never party-scaled
	})
	local part = byModel[model]
	if not part then
		return
	end
	part.partOf = creature
	part.socketIndex = slot
	part.pos = at
	model:PivotTo(CFrame.new(at))
	if creature.row.vulnerableWhen == "partsDown" then
		model:SetAttribute(ATTR.WEAKPOINT, true)
	end
	local state = Fn.krakenState(creature)
	local arm = state.arms[slot] or { slot = slot }
	arm.part = part
	arm.rest = rest
	arm.returnAt = nil
	state.arms[slot] = arm
	creature.partsAlive = (creature.partsAlive or 0) + 1
	Fn.krakenArmPhase(arm, "Rest", now)
	Fn.krakenArmHot(arm, false)
	return arm
end

-- An arm that is standing, not withdrawn, and not already committed to a move.
-- `Rest` is the only idle phase; everything else is a limb in the middle of
-- something and taking a second order would rewrite a telegraph a player is
-- already reading (`Fn.commandArm`'s standing rule, applied to two arms instead
-- of eight).
function Fn.krakenFreeArm(creature, skip)
	local state = Fn.krakenState(creature)
	for slot = 1, 2 do
		local arm = state.arms[slot]
		if arm and arm ~= skip and arm.part and not arm.part.dead and arm.phase == "Rest" then
			return arm
		end
	end
	return nil
end

-- Where an arm's hitbox stands, given its phase. Called every frame, so this is
-- the ONE place an arm's position is decided and the client's chain, the
-- server's hitbox and the knuckle's glow are all read off it.
function Fn.krakenArmPlace(creature, arm, now: number)
	local part = arm.part
	if not part or part.dead or not part.model.Parent then
		return
	end
	local kr = K.KRAKEN
	local rest = Fn.krakenAt(creature, arm.rest.X, kr.DECK_Y, arm.rest.Z)
	local at = rest
	local span = arm.phaseFor or 1
	local u = math.clamp((now - (arm.phaseAt or now)) / math.max(span, 1e-3), 0, 1)
	arm.t = u
	local target = arm.target
	if arm.phase == "Rear" and target then
		-- Up and over the rail: the limb crests between its rest point and the
		-- impact site, which is what makes the tell readable from the deck.
		at = rest:Lerp(target, smoothstep(u) * 0.55) + Vector3.new(0, 26 * math.sin(u * math.pi * 0.5), 0)
	elseif arm.phase == "SweepCock" and target then
		at = rest:Lerp(target, smoothstep(u))
	elseif arm.phase == "Sweep" and target and arm.sweepTo then
		at = target:Lerp(arm.sweepTo, smoothstep(u))
	elseif arm.phase == "Coil" and target then
		-- UNDER THE SEA AND OUT OF REACH, the one committed phase whose hitbox is
		-- not at its target. The limb is circling 70 studs down and 46 outboard of
		-- the station it is tracking (KrakenPath's COIL_DEPTH / COIL_OUT, mirrored
		-- in K.KRAKEN), so that is where the thing you cannot hit is - rather than
		-- on the planking, where the party would find an invisible tentacle to
		-- shoot at exactly the moment the move wants them moving.
		--
		-- Taken off the TARGET rather than off the rest point, because the target
		-- moves: this is re-aimed every `trackStep` by Fn.krakenArmAim, and a
		-- hitbox left at the seat would be the one part of the move that did not
		-- follow anybody.
		at = Vector3.new(target.X, Fn.krakenShip(creature).Y - kr.COIL_SINK, target.Z - kr.COIL_OUT)
	elseif target and K.KRAKEN_PLANTED[arm.phase] then
		-- PLANTED. Slam, Down and Wrapped are all "the limb is at its target and
		-- staying there" - three names for one placement, because the three are
		-- different things to the CLIENT (a blow, a punish window, a haul) and
		-- the same thing to the hitbox. Named in a table rather than in a chain
		-- of identical branches so the fact that they agree is stated once.
		at = target
	end
	part.pos = at
	part.model:PivotTo(CFrame.new(at))
	part.model:SetAttribute(ATTR.ARM_T, u)
	if arm.hot then
		-- The knuckle: back along the limb toward the head, and proud of the
		-- deck. Republished every frame because the limb is moving under it.
		local head = Fn.krakenAt(creature, kr.HEAD_AT.X, kr.EYE_LIFT * 0.4, kr.HEAD_AT.Z)
		local back = head - at
		back = if back.Magnitude > 0.001 then back.Unit else Vector3.new(0, 0, -1)
		part.model:SetAttribute(ATTR.WEAKPOINT_POS, at + back * kr.KNUCKLE_BACK + Vector3.new(0, kr.KNUCKLE_LIFT, 0))
	end
end

-- ------------------------------------------------------------ the props

-- One anchored part the fight steps itself: the wrench's barrels and the mast
-- bell's spar. THE BACKSTOP IS NOT OPTIONAL - every prop in this file carries
-- one, because a fight can end underneath a prop (the boss dies, the reaper
-- takes it, an admin restarts it) and the tick that would have collected it
-- stops running in the same frame. So: `expiresAt` for the tick, and a
-- `task.delay` destroy that does not need the tick to be alive at all.
function Fn.krakenProp(creature, name: string, size: Vector3, at: Vector3, life: number, spec)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = CFrame.new(at)
	part.Anchored = true
	part.CanCollide = false
	-- Solid to LOOK at and to CAST at, but never a floor and never a wall: a
	-- rolling cask you could stand on would turn the wrench's own hazard into
	-- the safest place on the deck.
	part.CanQuery = false
	part.Color = Color3.fromRGB(84, 66, 44)
	part.Material = Enum.Material.Wood
	part.Parent = Workspace
	task.delay(life, function()
		if part.Parent then
			part:Destroy()
		end
	end)
	local prop = spec or {}
	prop.part = part
	prop.expiresAt = os.clock() + life
	prop.hit = {}
	table.insert(Fn.krakenState(creature).props, prop)
	return prop
end

function Fn.krakenClearProps(creature)
	local state = creature.kraken
	if not state then
		return
	end
	for _, prop in state.props do
		if prop.part and prop.part.Parent then
			prop.part:Destroy()
		end
	end
	table.clear(state.props)
end

-- Step every live prop: move it along its own leg, hurt whoever it runs over
-- (once each per prop, the figurehead's rule), and retire it at its deadline.
function Fn.krakenStepProps(creature, now: number)
	local state = creature.kraken
	if not state then
		return
	end
	for i = #state.props, 1, -1 do
		local prop = state.props[i]
		if now >= prop.expiresAt or not prop.part or not prop.part.Parent then
			if prop.part and prop.part.Parent then
				prop.part:Destroy()
			end
			table.remove(state.props, i)
			continue
		end
		local t = math.clamp((now - prop.startAt) / math.max(prop.travel, 1e-3), 0, 1)
		local at
		if prop.arc then
			-- THE SPAR: a swing, not a slide. It sweeps back and forth across
			-- the waist, so `t` is folded into a triangle wave and each fold is
			-- one damaging pass. `hit` is cleared at the turn, so a player who
			-- ate one pass can be caught by the next - which is the whole point
			-- of a thing that swings.
			local passes = prop.passes or 1
			local phase = t * passes
			local leg = math.floor(phase)
			local frac = phase - leg
			if leg ~= prop.leg then
				prop.leg = leg
				table.clear(prop.hit)
			end
			local swing = if leg % 2 == 0 then frac else 1 - frac
			at = prop.from:Lerp(prop.to, smoothstep(swing))
		else
			at = prop.from:Lerp(prop.to, t)
		end
		prop.part.CFrame = CFrame.new(at, at + (prop.to - prop.from).Unit)
		for _, entry in Fn.livingRootsNear(at, prop.radius) do
			-- Cover stops a cask AND a spar: the same four crates that answer
			-- the scythe, so the deck's furniture reads as one idea rather than
			-- four special cases.
			if not prop.hit[entry.player] and not Fn.krakenBehindCover(creature, entry.root.Position) then
				prop.hit[entry.player] = true
				PlayerService.damage(entry.player, math.random(prop.min, prop.max), creature, { bypassIframe = true })
			end
		end
		if t >= 1 and not prop.arc then
			prop.part:Destroy()
			table.remove(state.props, i)
		end
	end
end

-- ------------------------------------------------------------ the waves

-- THE GULLET'S OWN HAZARD LIST, and it is not `creature.strikes` for two
-- reasons the generic stepper cannot express:
--   * A GAP. Peristalsis is an annulus with an arc cut out of it, and the arc
--     is the entire mechanic. `Fn.damagePlayersInAnnulus` has no notion of one.
--   * A HEIGHT CEILING. The acid tide floods the floor and the dais stands
--     above it, so "safe if you are more than 1.8 studs up" is the move.
--     `damagePlayersInRadius` takes a height TOLERANCE (a symmetric band), not
--     a ceiling, and the boss kit passes 14 - which would drown the dais.
-- Everything else about them is the strike stepper's contract: a tell at
-- `tellAt` whose duration runs to the blow, damage at `hitAt`, one event out.
function Fn.krakenQueueWave(creature, def, p, spec)
	local lo, hi = Fn.bossRoll(creature, def, spec.damage or p.damage or { 1, 1 })
	spec.min, spec.max = lo, hi
	spec.skin = spec.skin or p.skin
	table.insert(Fn.krakenState(creature).waves, spec)
end

function Fn.krakenStepWaves(creature, now: number)
	local state = creature.kraken
	if not state then
		return
	end
	for i = #state.waves, 1, -1 do
		local w = state.waves[i]
		if not w.told and now >= w.tellAt then
			w.told = true
			fireEvent("telegraph", w.at, {
				kind = if w.inner then "ringTell" else "mark",
				duration = math.max(w.hitAt - now, 0.1),
				radius = w.outer or w.radius,
				inner = w.inner,
				-- THE GAP, ON THE WIRE. Two bearings in radians naming the arc
				-- that is NOT part of the ring. A client that ignores them draws
				-- a closed ring and lies to the player about the one piece of
				-- safe ground in the move, so they are part of the telegraph
				-- rather than a decoration on it.
				gapFrom = w.gapFrom,
				gapTo = w.gapTo,
				skin = w.skin,
			})
		end
		if now >= w.hitAt then
			table.remove(state.waves, i)
			for _, entry in Fn.livingRootsNear(w.at, (w.outer or w.radius) + 2) do
				local root = entry.root
				local off = Vector3.new(root.Position.X - w.at.X, 0, root.Position.Z - w.at.Z)
				local d = off.Magnitude
				local inBand = if w.inner then (d >= w.inner and d <= w.outer) else (d <= w.radius)
				if inBand and w.gapFrom then
					-- Inside the cut arc is outside the ring. Bearings are
					-- wrapped into the gap's own frame so a gap that straddles
					-- the -pi seam is not silently half a gap.
					local bearing = math.atan2(off.Z, off.X)
					local rel = (bearing - w.gapFrom) % (math.pi * 2)
					local span = (w.gapTo - w.gapFrom) % (math.pi * 2)
					if rel <= span then
						inBand = false
					end
				end
				-- A CEILING, MEASURED AT THE FEET. See K.KRAKEN.ROOT_OVER_FEET:
				-- the root floats three studs over the ground a character is
				-- standing on, so testing it against a 1.8-stud flood would
				-- spare the entire room including the floor of it.
				if inBand and w.maxY and (root.Position.Y - K.KRAKEN.ROOT_OVER_FEET) - w.at.Y > w.maxY then
					inBand = false
				end
				if inBand and w.height and math.abs(root.Position.Y - w.at.Y) > w.height then
					inBand = false
				end
				if inBand then
					PlayerService.damage(entry.player, math.random(w.min, w.max), creature, { bypassIframe = true })
				end
			end
			fireEvent(w.event or "strikeHit", w.at, {
				radius = w.outer or w.radius,
				inner = w.inner,
				gapFrom = w.gapFrom,
				gapTo = w.gapTo,
				skin = w.skin,
			})
			if w.pool then
				spawnPool(creature, w.at, w.pool, now)
			end
		end
	end
end

-- ---------------------------------------------------------- the attack book

-- Common setup for a handler that has to pick an arm and a target once, on its
-- first windup frame. `a.krSetup` is the latch; a handler whose arm pick fails
-- (both arms withdrawn) simply plays no telegraph and lands nothing, and burns
-- its clock and its cooldown doing it - the jammed-overload ruling, and the
-- honest outcome for a move whose limb is not there.
function Fn.krakenSetup(creature): boolean
	local a = creature.attack
	if a.krSetup then
		return false
	end
	a.krSetup = true
	return true
end

-- Where a slam should land: the deck under the nearest player, clamped inside
-- whatever floor this phase has opened. Clamped rather than skipped, because a
-- disc drawn half over the sea is a telegraph that lies about its own shape.
function Fn.krakenSlamTarget(creature, root): Vector3
	local kr = K.KRAKEN
	local phase = creature.krakenPhase or 1
	local x, z = 0, 0
	if root then
		local lx, _ly, lz = Fn.krakenLocal(creature, root.Position)
		x, z = lx, lz
	end
	local lowX, highX = kr.QD_TO_X + kr.SLAM_R, kr.FC_FROM_X - kr.SLAM_R
	if phase >= 2 then
		lowX, highX = -kr.HULL_X + kr.SLAM_R, kr.HULL_X - kr.SLAM_R
	end
	x = math.clamp(x, lowX, highX)
	z = math.clamp(z, -12, 12)
	return Fn.krakenAt(creature, x, Fn.krakenDeckY(x), z)
end

-- PILE SLAM. One arm rears clear of the rail and comes down.
K.ATTACK_HANDLERS.krakenpileslam = {
	windup = function(creature, _def, p, u, sub)
		local a = creature.attack
		if Fn.krakenSetup(creature) then
			local arm = Fn.krakenFreeArm(creature)
			a.krArm = arm
			if arm then
				local root = Fn.nearestPlayerRoot(Fn.krakenShip(creature))
				local at = Fn.krakenSlamTarget(creature, root)
				a.krAt = at
				arm.phaseFor = a.windup
				Fn.krakenArmPhase(arm, "Rear", os.clock(), at)
				-- THE TELL IS THE DISC AND IT IS AT THE IMPACT SITE, drawn for
				-- exactly as long as the blow takes to arrive.
				fireEvent("telegraph", at, {
					kind = "slam",
					duration = a.windup,
					radius = p.tellRadius or K.KRAKEN.SLAM_TELL_R,
					skin = p.skin,
				})
			end
		end
		creature.model:PivotTo(poseCFrame(creature, sub + 0.4 * u, 0, math.rad(-8) * u))
	end,
	fire = function(creature, def, p, now)
		local a = creature.attack
		local at = a.krAt
		if not at then
			return
		end
		local arm = a.krArm
		if arm then
			arm.phaseFor = p.duration
			Fn.krakenArmPhase(arm, "Slam", now, at)
		end
		local lo, hi = Fn.bossRoll(creature, def, p.damage)
		damagePlayersInRadius(at, p.radius, lo, hi, creature, 0.5, K.BOSS_HEIGHT_TOLERANCE)
		fireEvent("slam", at, { radius = p.radius, skin = p.skin })
	end,
	finish = function(creature, _def, p, now)
		local a = creature.attack
		local arm = a and a.krArm
		if arm and arm.part and not arm.part.dead then
			-- THE PUNISH. The limb lies on the planking with its knuckle lit
			-- for `down` seconds; the fight tick stands it back up.
			arm.phaseFor = p.down or 3.0
			arm.downUntil = now + (p.down or 3.0)
			Fn.krakenArmPhase(arm, "Down", now, a.krAt)
			Fn.krakenArmHot(arm, true, a.krAt)
		end
	end,
}

-- One arm's lateral sweep along one deck. Shared by `deckscythe` (one arm) and
-- `crossscythe` (both, on different decks) so the two cannot drift: the lane,
-- the plane and the damage rule are written once.
function Fn.krakenArmSweep(creature, p, arm, deck, now: number, windup: number)
	local kr = K.KRAKEN
	local planeY = deck[3] + kr.SWEEP_RISE
	local from = Fn.krakenAt(creature, deck[1] + 4, planeY, 0)
	local to = Fn.krakenAt(creature, deck[2] - 4, planeY, 0)
	arm.phaseFor = windup
	arm.sweepTo = to
	Fn.krakenArmPhase(arm, "SweepCock", now, from)
	-- "sweepLane": a CORRIDOR, not a circle. from/to are its ends and `height`
	-- is the world Y of the blade's underside, which is what a player has to be
	-- BELOW to survive it - so the client can draw the plane rather than a
	-- flat decal that says nothing about the mechanic.
	fireEvent("sweepLane", (from + to) * 0.5, {
		from = from,
		to = to,
		height = planeY + (Fn.krakenShip(creature)).Y,
		width = p.lane or 20,
		duration = windup,
		skin = p.skin,
	})
	return { from = from, to = to, deck = deck, planeY = planeY }
end

-- Resolve one swept lane. THE RULE, and every number in it is measured off the
-- build rather than chosen: the blade's underside is at deck + 3.0, a standing
-- head is at deck + 5.0, so anyone standing on this deck inside the lane is two
-- studs into it - and the ONLY thing that clears is a cargo footprint. Players
-- on another deck are untouched, because their station is outside this lane's
-- X range, which is the whole reason the lane is expressed as one.
function Fn.krakenResolveSweep(creature, def, p, lane)
	local kr = K.KRAKEN
	local lo, hi = Fn.bossRoll(creature, def, p.damage)
	local planeWorld = Fn.krakenAt(creature, 0, lane.planeY, 0).Y
	local half = p.lane or 20
	for _, entry in Fn.livingRootsNear((lane.from + lane.to) * 0.5, 140) do
		local root = entry.root
		local x, _y, z = Fn.krakenLocal(creature, root.Position)
		local headY = root.Position.Y + kr.HEAD_OVER_ROOT
		if
			x >= lane.deck[1]
			and x <= lane.deck[2]
			and math.abs(z) <= half
			and headY > planeWorld
			and not Fn.krakenBehindCover(creature, root.Position)
		then
			PlayerService.damage(entry.player, math.random(lo, hi), creature, { bypassIframe = true })
		end
	end
	fireEvent("strikeHit", (lane.from + lane.to) * 0.5, { radius = half, skin = p.skin })
end

K.ATTACK_HANDLERS.krakenscythe = {
	windup = function(creature, _def, p, u, sub)
		local a = creature.attack
		if Fn.krakenSetup(creature) then
			local arm = Fn.krakenFreeArm(creature)
			a.krArm = arm
			if arm then
				local decks = Fn.krakenDecks(creature.krakenPhase or 1)
				a.krLane = Fn.krakenArmSweep(creature, p, arm, decks[math.random(#decks)], os.clock(), a.windup)
			end
		end
		creature.model:PivotTo(poseCFrame(creature, sub + 0.3 * u, math.rad(10) * u, math.rad(-6) * u))
	end,
	fire = function(creature, def, p, now)
		local a = creature.attack
		if not a.krLane then
			return
		end
		if a.krArm then
			a.krArm.phaseFor = p.duration
			Fn.krakenArmPhase(a.krArm, "Sweep", now, a.krLane.from)
		end
		Fn.krakenResolveSweep(creature, def, p, a.krLane)
	end,
	finish = function(creature, _def, p, now)
		local a = creature.attack
		local arm = a and a.krArm
		if not arm then
			return
		end
		-- THE DRAG (the new-attacks pass, 2026-09-12). The swing used to end by
		-- snapping the limb straight back to Rest, which is the one moment in the
		-- whole fight where the animal did something instantaneous - and it threw
		-- away the best-read move in the book's best opportunity for a window.
		--
		-- `drape` seconds of the arm lying spent over the NEAR bulwark with its
		-- knuckle lit instead. The fight tick stands it up when `downUntil`
		-- expires, exactly as it does for a slam's `down` - no new lifetime rule,
		-- and the STRANDED backstop still covers a cancelled cast because Drape is
		-- not Rest.
		--
		-- Guarded on the field rather than on a default, so a row that does not ask
		-- for the opening keeps the old behaviour verbatim: `crossscythe` shares
		-- Fn.krakenArmSweep with this move but has its OWN finish (both arms), and
		-- giving two simultaneous limbs a window would be a different balance
		-- decision than the one the owner asked for.
		if p.drape and arm.part and not arm.part.dead then
			-- At the END of the lane, which is where the swing actually stopped -
			-- and through Fn.krakenDrapeAt, because the lane's own `to` is at the
			-- SWEEP PLANE (35 studs up) and the limb drapes on the planking. See
			-- that function's note: this was a real bug in the first draft.
			local at = Fn.krakenDrapeAt(creature, if a.krLane then select(1, Fn.krakenLocal(creature, a.krLane.to)) else 0)
			arm.phaseFor = p.drape
			arm.downUntil = now + p.drape
			Fn.krakenArmPhase(arm, "Drape", now, at)
			Fn.krakenArmHot(arm, true, at)
			return
		end
		arm.phaseFor = 0.8
		Fn.krakenArmPhase(arm, "Rest", now)
	end,
}

-- BOTH ARMS, TWO DECKS. Phase two only, and it is a phase-two move because it
-- needs a second deck to be a second question rather than the same one twice.
K.ATTACK_HANDLERS.krakencross = {
	windup = function(creature, _def, p, u, sub)
		local a = creature.attack
		if Fn.krakenSetup(creature) then
			local first = Fn.krakenFreeArm(creature)
			local second = Fn.krakenFreeArm(creature, first)
			local decks = Fn.krakenDecks(creature.krakenPhase or 1)
			a.krLanes = {}
			a.krArms = {}
			local pick = math.random(#decks)
			for index, arm in { first, second } do
				if arm then
					local deck = decks[((pick + index - 2) % #decks) + 1]
					table.insert(a.krArms, arm)
					table.insert(a.krLanes, Fn.krakenArmSweep(creature, p, arm, deck, os.clock(), a.windup))
				end
			end
		end
		creature.model:PivotTo(poseCFrame(creature, sub + 0.4 * u, 0, math.rad(-10) * u))
	end,
	fire = function(creature, def, p, now)
		local a = creature.attack
		for index, lane in (a.krLanes or {}) do
			local arm = a.krArms[index]
			if arm then
				arm.phaseFor = p.duration
				Fn.krakenArmPhase(arm, "Sweep", now, lane.from)
			end
			Fn.krakenResolveSweep(creature, def, p, lane)
		end
	end,
	finish = function(creature, _def, _p, now)
		local a = creature.attack
		for _, arm in (a and a.krArms or {}) do
			arm.phaseFor = 0.8
			Fn.krakenArmPhase(arm, "Rest", now)
		end
	end,
}

-- WRAP WRENCH. The set-piece of phase one: the arm takes a boarding gap and
-- hauls, cargo breaks loose and crosses the deck, and burning the arm's hot
-- knuckle cancels the whole thing. See the row for substitution A.
K.ATTACK_HANDLERS.krakenwrench = {
	windup = function(creature, _def, p, u, sub)
		local a = creature.attack
		if Fn.krakenSetup(creature) then
			local arm = Fn.krakenFreeArm(creature)
			a.krArm = arm
			local wraps = (BossArenas.items.maelstrom or {}).wraps
			if arm and wraps then
				local index = math.random(#wraps)
				local w = wraps[index]
				local at = Fn.krakenAt(creature, w.X, w.Y, w.Z)
				a.krAt, a.krWrap = at, index
				arm.phaseFor = a.windup
				Fn.krakenArmPhase(arm, "Wrapped", os.clock(), at, index)
				fireEvent("telegraph", at, { kind = "mark", duration = a.windup, radius = 10, skin = p.skin })
			end
		end
		creature.model:PivotTo(poseCFrame(creature, sub + 0.5 * u, 0, math.rad(12) * u))
	end,
	fire = function(creature, def, p, now)
		local a = creature.attack
		local arm = a.krArm
		if not arm or not arm.part or arm.part.dead then
			return
		end
		arm.phaseFor = p.duration
		Fn.krakenArmPhase(arm, "Wrapped", now, a.krAt, a.krWrap)
		Fn.krakenArmHot(arm, true, a.krAt)
		-- THE COUNTER'S BASELINE. Measured against the health this arm had when
		-- the haul STARTED, not against a fraction of its current bar - the
		-- threshold has to mean "damage done during the channel", or an arm
		-- already at 20% would be cancellable by a scratch (the overload's
		-- ruling, and the same arithmetic).
		a.krHp0 = arm.part.health
		-- SUBSTITUTION A: the LIST is the client's, the CONSEQUENCE is the
		-- server's. `shipList` carries the direction and the duration so the
		-- camera roll, the rigging strain and the debris all run on the same
		-- clock the barrels do.
		local side = if a.krAt.Z < Fn.krakenShip(creature).Z then -1 else 1
		fireEvent("shipList", Fn.krakenShip(creature), {
			duration = p.duration,
			side = side,
			active = true,
			skin = p.skin,
		})
		local lo, hi = Fn.bossRoll(creature, def, p.damage)
		local count = p.barrels or 4
		for i = 1, count do
			-- Crossing the waist from the hauling side to the other, staggered
			-- along the deck so the four are a moving fence rather than a wall.
			local x = -30 + (i - 1) * (70 / math.max(count - 1, 1))
			local deck = Fn.krakenDeckY(x)
			local from = Fn.krakenAt(creature, x, deck + 2, side * 26)
			local to = Fn.krakenAt(creature, x, deck + 2, -side * 26)
			local travel = (to - from).Magnitude / math.max(p.barrelSpeed or 26, 1)
			Fn.krakenProp(creature, "KrakenBarrel", Vector3.new(4.4, 4.4, 6.6), from, travel + 1.5, {
				from = from,
				to = to,
				startAt = now + (i - 1) * 0.35,
				travel = travel,
				radius = p.barrelRadius or 6,
				min = lo,
				max = hi,
			})
		end
	end,
	strike = function(creature, _def, p, now, _dt, _u, _root, sub)
		local a = creature.attack
		local arm = a.krArm
		creature.model:PivotTo(poseCFrame(creature, sub + 0.5 + math.sin(now * 4) * 0.2, 0, math.rad(14)))
		if a.krBroken or not arm then
			return
		end
		-- THE COUNTER, TESTED EVERY FRAME. Either the arm went down outright, or
		-- the party put `breakDamage` into it since the haul began.
		local part = arm.part
		local broke = not part or part.dead
		if not broke and a.krHp0 and (a.krHp0 - part.health) >= (p.breakDamage or 2000) then
			broke = true
		end
		if not broke then
			return
		end
		a.krBroken = true
		Fn.krakenClearProps(creature)
		fireEvent("shipList", Fn.krakenShip(creature), { active = false, duration = 0.4, skin = p.skin })
		if part and not part.dead then
			-- The reward: the limb is torn off the rail and lies open. `Exposed`
			-- is the attribute every body controller already reads for "this
			-- thing is wide open"; the 3x is the knuckle, still lit.
			part.exposedUntil = now + (p.expose or 6.0)
			part.model:SetAttribute(ATTR.EXPOSED, true)
			arm.phaseFor = p.expose or 6.0
			arm.downUntil = now + (p.expose or 6.0)
			Fn.krakenArmPhase(arm, "Down", now, a.krAt)
			Fn.krakenArmHot(arm, true, a.krAt)
		end
		-- THE HAUL IS OVER, so the move is over: the strike phase is cut short
		-- rather than left to run out with nothing in it. Damage, cooldown and
		-- the recover all follow the ordinary path from here.
		a.phaseUntil = now
	end,
	finish = function(creature, _def, p, now)
		local a = creature.attack
		Fn.krakenClearProps(creature)
		if a and not a.krBroken then
			fireEvent("shipList", Fn.krakenShip(creature), { active = false, duration = 0.5, skin = p.skin })
			local arm = a.krArm
			if arm and arm.part and not arm.part.dead then
				arm.phaseFor = 1.0
				Fn.krakenArmPhase(arm, "Rest", now)
				Fn.krakenArmHot(arm, false)
			end
		end
	end,
}

-- INK MORTAR. The siphon flares and four globs come down on marked ground,
-- leaving slicks. Existing tech end to end: `Fn.throwGlob` for the flight, its
-- `tolerance` opt-in for the height gate a ship's decks need, and its `pool`
-- rider for the slick.
K.ATTACK_HANDLERS.krakenmortar = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.25 * u, 0, math.rad(6) * u))
	end,
	fire = function(creature, def, p, now)
		local eye = Fn.krakenEye(creature)
		fireEvent("inkFlare", eye, { duration = p.duration, skin = p.skin })
		local phase = creature.krakenPhase or 1
		local kr = K.KRAKEN
		local lowX, highX = kr.QD_TO_X + 6, kr.FC_FROM_X - 6
		if phase >= 2 then
			lowX, highX = -kr.HULL_X + 8, kr.HULL_X - 8
		end
		for i = 1, (p.count or 4) do
			local x = randomBetween(lowX, highX)
			local z = randomBetween(-14, 14)
			local at = Fn.krakenAt(creature, x, Fn.krakenDeckY(x), z)
			local flight = (p.flight or 1.4) + (i - 1) * (p.stagger or 0.25)
			-- The disc, at the impact site, for exactly the flight time.
			fireEvent("telegraph", at, { kind = "mark", duration = flight, radius = p.radius, skin = p.skin })
			Fn.throwGlob(creature, def, p, at, flight, now, "strikeHit", "spit", {
				tolerance = K.BOSS_HEIGHT_TOLERANCE,
				pool = p.pool,
			}, eye)
		end
	end,
}

-- MAST BELL. The main spar tears loose and swings across the waist while the
-- rigging comes down in pieces.
K.ATTACK_HANDLERS.krakenmastbell = {
	windup = function(creature, _def, p, u, sub)
		local a = creature.attack
		if Fn.krakenSetup(creature) then
			-- The spar's arc, published before it moves so the tell and the
			-- flight are one clock: the same rule the anchor line runs on.
			local deck = K.KRAKEN.DECK_Y
			a.krFrom = Fn.krakenAt(creature, -18, deck + 6, -22)
			a.krTo = Fn.krakenAt(creature, 22, deck + 6, 22)
			fireEvent("mastBell", (a.krFrom + a.krTo) * 0.5, {
				from = a.krFrom,
				to = a.krTo,
				passes = p.passes or 3,
				duration = p.duration,
				lead = a.windup,
				radius = p.sparRadius or 7,
				skin = p.skin,
			})
		end
		creature.model:PivotTo(poseCFrame(creature, sub + 0.3 * u, 0, math.rad(-6) * u))
	end,
	fire = function(creature, def, p, now)
		local a = creature.attack
		if not a.krFrom then
			return
		end
		local lo, hi = Fn.bossRoll(creature, def, p.damage)
		Fn.krakenProp(creature, "KrakenSpar", Vector3.new(3.2, 3.2, 44), a.krFrom, p.duration + 1.0, {
			from = a.krFrom,
			to = a.krTo,
			startAt = now,
			travel = p.duration,
			passes = p.passes or 3,
			arc = true,
			leg = -1,
			radius = p.sparRadius or 7,
			min = lo,
			max = hi,
		})
		-- ...and the rigging coming down with it: ordinary queued marks, because
		-- rubble does not need to be simulated to be dodged.
		local kr = K.KRAKEN
		for i = 1, (p.strikes or 3) do
			local x = randomBetween(kr.QD_TO_X + 8, kr.FC_FROM_X - 8)
			local z = randomBetween(-15, 15)
			local at = Fn.krakenAt(creature, x, Fn.krakenDeckY(x), z)
			local hitAt = now + 1.0 + (i - 1) * (p.duration / math.max(p.strikes or 3, 1))
			Fn.queueStrike(creature, def, p, at, hitAt - 1.0, hitAt, { damage = p.debrisDamage })
		end
	end,
	strike = function(creature, _def, _p, now, _dt, _u, _root, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.3, math.sin(now * 2.2) * math.rad(5), math.rad(-6)))
	end,
	finish = function(creature, _def, _p, _now)
		Fn.krakenClearProps(creature)
	end,
}

-- UNDERTOW HEAVE. The sea heels toward the animal for five seconds, then the
-- arm comes down where everyone ended up. See the row for substitution B.
K.ATTACK_HANDLERS.krakenheave = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.6 * u, 0, math.rad(18) * u))
	end,
	fire = function(creature, _def, p, now)
		local a = creature.attack
		-- The port rail amidships: the drag's centre and, five seconds later,
		-- the slam's. One point, so the move is one sentence.
		local rail = Fn.krakenAt(creature, 0, K.KRAKEN.DECK_Y, -19)
		a.krAt = rail
		a.krTickAt = now + 0.8
		-- THE EXISTING PULL, aimed at a rail instead of a whirlpool. `braced`
		-- is the exemption travelling with it: this drag is applied by each
		-- client to its own character (the lure-pull channel), so the client
		-- has to be told which footprints hold you. The server enforces the
		-- same list on its own damage tick below, so bracing means something
		-- even to a client that ignores it.
		fireEvent("pull", rail, {
			radius = p.radius,
			strength = p.strength,
			duration = p.duration,
			braced = Fn.krakenCoverBoxes(creature),
			skin = p.skin,
		})
	end,
	strike = function(creature, def, p, now, _dt, u, _root, sub)
		local a = creature.attack
		creature.model:PivotTo(poseCFrame(creature, sub + 0.6 + math.sin(now * 3) * 0.25, 0, math.rad(16)))
		if now >= (a.krTickAt or math.huge) then
			a.krTickAt = now + 0.8
			local lo, hi = Fn.bossRoll(creature, def, p.damage)
			for _, entry in Fn.livingRootsNear(Fn.krakenShip(creature), 140) do
				if not Fn.krakenBehindCover(creature, entry.root.Position) then
					PlayerService.damage(entry.player, math.random(lo, hi), creature, {})
				end
			end
		end
		-- THE FOLLOW-UP, queued at the last moment of the drag rather than at
		-- the start: its telegraph has to open when the pull STOPS, or players
		-- would be reading a disc while still being moved through it.
		if u >= 1 and not a.krFollow then
			a.krFollow = true
			local arm = Fn.krakenFreeArm(creature)
			if arm then
				arm.phaseFor = p.slamTell or 1.1
				Fn.krakenArmPhase(arm, "Rear", now, a.krAt)
				a.krArm = arm
			end
			fireEvent("telegraph", a.krAt, {
				kind = "slam",
				duration = p.slamTell or 1.1,
				radius = p.slamRadius or 18,
				skin = p.skin,
			})
			Fn.queueStrike(creature, def, p, a.krAt, now, now + (p.slamTell or 1.1), {
				radius = p.slamRadius or 18,
				damage = p.slamDamage,
			})
		end
	end,
	finish = function(creature, _def, p, now)
		local a = creature.attack
		fireEvent("pull", Fn.krakenShip(creature), { radius = p.radius, strength = 0, duration = 0, skin = p.skin })
		local arm = a and a.krArm
		if arm and arm.part and not arm.part.dead then
			arm.phaseFor = p.down or 2.5
			arm.downUntil = now + (p.down or 2.5)
			Fn.krakenArmPhase(arm, "Down", now, a.krAt)
			Fn.krakenArmHot(arm, true, a.krAt)
		end
	end,
}

-- EYE LANCE. One player, two seconds of lock, and a tip through where they will
-- be - unless they have put the ship between themselves and the eye.
K.ATTACK_HANDLERS.krakeneyelance = {
	windup = function(creature, _def, p, u, sub)
		local a = creature.attack
		if Fn.krakenSetup(creature) then
			local root, player = Fn.nearestPlayerRoot(Fn.krakenShip(creature))
			a.krRoot, a.krPlayer = root, player
			if root then
				fireEvent("eyeLock", root.Position, {
					duration = a.windup,
					from = Fn.krakenEye(creature),
					userId = player and player.UserId or nil,
					skin = p.skin,
				})
			end
		end
		creature.model:PivotTo(poseCFrame(creature, sub + 0.2 * u, 0, math.rad(-4) * u))
	end,
	fire = function(creature, def, p, now)
		local a = creature.attack
		local root = a.krRoot
		if not root or not root.Parent then
			return
		end
		local eye = Fn.krakenEye(creature)
		-- LINE OF SIGHT, AT FIRE TIME. Against the arena folder and nothing
		-- else: the ship's masts, castle bulkheads and cargo are what a player
		-- can break the animal's view behind, and casting against everything
		-- would let another player's body block a lance aimed through them.
		local arenaFolder = Workspace:FindFirstChild("BossArenas")
		if arenaFolder then
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Include
			params.FilterDescendantsInstances = { arenaFolder }
			local to = root.Position - eye
			if Workspace:Raycast(eye, to, params) then
				fireEvent("eyeLanceBlocked", eye, { to = root.Position, skin = p.skin })
				return
			end
		end
		-- ...and the lead, so standing still is not strictly better than moving.
		local lead = root.AssemblyLinearVelocity * (p.lead or 0.35)
		local at = groundedPos(root.Position + Vector3.new(lead.X, 0, lead.Z), 0)
		Fn.queueStrike(creature, def, p, at, now, now + (p.lead or 0.35), { radius = p.radius })
		-- THE GLINT (the new-attacks pass, 2026-09-12). The orb stays lit for
		-- `glint` seconds and the head takes 1.5x for exactly that window - see
		-- CreatureService.hitModifiers' own branch and the row for why 1.5.
		--
		-- HELD HERE AND NOT IN `finish`, and it is a real difference: this move's
		-- `duration` is 0.6 and its `recover` 0.7, so a window opened at finish
		-- would start 0.6 seconds after the thing it is a reward for reading. The
		-- window is the consequence of the eye having FIRED, so it starts when the
		-- eye fires.
		--
		-- AND IT IS SET ON THE WHIFF PATH TOO, which is upstream of here: the
		-- blocked branch returns before this line, so a lance that was broken by
		-- cover gets no glint. That is the right way round - the opening is
		-- payment for the eye committing to a shot, and a shot into a bulkhead
		-- committed just as hard. The deliberate asymmetry is that the party who
		-- broke the line of sight already got their reward, which was not being hit
		-- for 118-156.
		if p.glint then
			creature.krakenGlintUntil = now + p.glint
			fireEvent("krakenGlint", Fn.krakenEye(creature), { duration = p.glint, skin = p.skin })
		end
	end,
}

-- INK DELUGE. A wall of ink crossing the main deck end to end. The castles are
-- above it, which is what makes phase two's three floors a resource.
K.ATTACK_HANDLERS.krakendeluge = {
	windup = function(creature, _def, p, u, sub)
		local a = creature.attack
		if Fn.krakenSetup(creature) then
			fireEvent("inkFlare", Fn.krakenEye(creature), { duration = a.windup, charge = true, skin = p.skin })
		end
		creature.model:PivotTo(poseCFrame(creature, sub + 0.5 * u, 0, math.rad(10) * u))
	end,
	fire = function(creature, def, p, now)
		local kr = K.KRAKEN
		local ranks = p.ranks or 5
		local arm = p.arm or 0.9
		-- Sternward or bowward, rolled per cast: the wall has a direction and
		-- which way it comes from is half the read.
		local reverse = math.random() < 0.5
		for rank = 0, ranks - 1 do
			local t = rank / math.max(ranks - 1, 1)
			local x = kr.QD_TO_X + (kr.FC_FROM_X - kr.QD_TO_X) * (if reverse then 1 - t else t)
			local hitAt = now + arm + rank * (p.interval or 0.42)
			for _, z in { -13, 0, 13 } do
				Fn.queueStrike(creature, def, p, Fn.krakenAt(creature, x, kr.DECK_Y, z), hitAt - arm, hitAt, {
					pool = p.pool,
				})
			end
		end
	end,
}

-- ============================================== THE NEW MOVES (2026-09-12)
--
-- Four moves, and the thing they have in common is the thing the owner asked for:
-- each one ENDS with the arm somewhere a player can hurt it. The fight's problem
-- was never difficulty, it was that phase one had two windows and phase two had
-- none that were not the siphon window - so a party's only real decision was
-- which crate to stand behind. Every move below is a decision instead.
--
-- NO NEW MECHANISM IN ANY OF THEM, which is why four moves fit in one block:
-- Fn.queueStrike draws and resolves the volley, `Fn.krakenArmPhase` /
-- `Fn.krakenArmHot` open every window, `arm.downUntil` closes them on the fight
-- tick's existing rule, and the misfire's deluge is `krakendeluge.fire` called on
-- a different row. The only genuinely new piece of machinery in the pass is
-- Fn.krakenArmAim (see its note): the ability to move a limb's aim WITHOUT
-- restamping its phase, which the maelstrom coil's three seconds of tracking
-- needs and nothing in the book had ever wanted before.

-- THE GRATING SPEAR'S THREE MARKS, walking down the deck to the target's station.
--
-- THE MARCH ALWAYS COMES FROM THE FAR END, and that is not a flourish: the third
-- mark IS the target's own station, so the first two have to be somewhere, and
-- putting them BEHIND the target (aft of an aft target, forward of a forward one)
-- would walk the sequence off the end of the ship and clamp two of the three marks
-- on top of each other. Walking IN from the opposite end keeps all three on open
-- planking and makes the read unambiguous: a line of light coming at you.
function Fn.krakenSpearLine(creature, root, p)
	local kr = K.KRAKEN
	local phase = creature.krakenPhase or 1
	local tx, tz = 0, 0
	if root then
		local lx, _ly, lz = Fn.krakenLocal(creature, root.Position)
		tx, tz = lx, lz
	end
	local lowX = if phase >= 2 then -kr.HULL_X + 8 else kr.QD_TO_X + 8
	local highX = if phase >= 2 then kr.HULL_X - 8 else kr.FC_FROM_X - 8
	local count = p.stabs or 3
	local step = p.stabMarch or 17
	-- Toward the BOW if the target is aft of amidships, toward the stern if
	-- forward of it - i.e. the marches always run the long way.
	local toward = if tx >= 0 then -1 else 1
	tz = math.clamp(tz, -14, 14)
	local out = {}
	for i = 1, count do
		local x = math.clamp(tx + toward * step * (count - i), lowX, highX)
		table.insert(out, Fn.krakenAt(creature, x, Fn.krakenDeckY(x), tz))
	end
	return out
end

-- One stab: the phase, the damage and - on the LAST one - the opening.
--
-- THE STUCK TRANSITION IS QUEUED RATHER THAN IMMEDIATE, and it has to be. Setting
-- Spear and then Stuck in the same frame would give the drawn jab a zero-length
-- phase: the client would crossfade straight from the cocked poise into the buried
-- tip and the stab that did the damage would never be drawn at all. So the third
-- stab lands like the other two and `a.krStuckAt` hands the tip over 0.28s later,
-- which is the jab's own travel time.
function Fn.krakenSpearStab(creature, def, p, now: number, index: number)
	local a = creature.attack
	local at = a.krMarks and a.krMarks[index]
	if not at then
		return
	end
	a.krStab = index
	local step = p.stabStep or 0.7
	local arm = a.krArm
	if arm and arm.part and not arm.part.dead then
		arm.phaseFor = step * 0.45
		Fn.krakenArmPhase(arm, "Spear", now, at)
	end
	local lo, hi = Fn.bossRoll(creature, def, p.damage)
	damagePlayersInRadius(at, p.radius or 7, lo, hi, creature, 0.5, K.BOSS_HEIGHT_TOLERANCE)
	fireEvent("strikeHit", at, { radius = p.radius or 7, skin = p.skin })
	if index >= #a.krMarks then
		a.krStuckAt = now + step * 0.40
	end
end

-- GRATING SPEAR. Three jabs walking down the deck, and the third one sticks.
K.ATTACK_HANDLERS.krakenspear = {
	windup = function(creature, _def, p, u, sub)
		local a = creature.attack
		if Fn.krakenSetup(creature) then
			local arm = Fn.krakenFreeArm(creature)
			a.krArm = arm
			if arm then
				local root = Fn.nearestPlayerRoot(Fn.krakenShip(creature))
				a.krMarks = Fn.krakenSpearLine(creature, root, p)
				a.krStab = 0
				a.krCocked = 1
				arm.phaseFor = a.windup
				Fn.krakenArmPhase(arm, "SpearCock", os.clock(), a.krMarks[1])
				-- ALL THREE DISCS AT ONCE, EXPIRING IN ORDER. Each telegraph's
				-- `duration` is the time until ITS OWN stab, so the three come up
				-- together and go out one after another down the line - which is
				-- the sequence the move is, drawn with nothing but the existing
				-- tell. (The arm's own deck mark rides the SpearCock phase and
				-- says which is next; see KrakenBodyController's MARK table.)
				local step = p.stabStep or 0.7
				for i, at in a.krMarks do
					fireEvent("telegraph", at, {
						kind = "mark",
						duration = a.windup + (i - 1) * step,
						radius = p.tellRadius or 11,
						skin = p.skin,
					})
				end
			end
		end
		creature.model:PivotTo(poseCFrame(creature, sub + 0.3 * u, math.rad(6) * u, math.rad(-5) * u))
	end,
	fire = function(creature, def, p, now)
		local a = creature.attack
		if not a.krMarks then
			return
		end
		-- The first jab lands AT fire, because the windup is the first cock: the
		-- limb is already poised over mark one with ArmT at 1.
		a.krT0 = now
		Fn.krakenSpearStab(creature, def, p, now, 1)
	end,
	strike = function(creature, def, p, now, _dt, _u, _root, sub)
		local a = creature.attack
		creature.model:PivotTo(poseCFrame(creature, sub + 0.3, math.sin(now * 5) * math.rad(4), math.rad(-5)))
		if not a.krMarks or not a.krT0 then
			return
		end
		local step = p.stabStep or 0.7
		local arm = a.krArm
		local next_ = (a.krStab or 0) + 1
		if next_ <= #a.krMarks then
			-- The cock, a little ahead of its own stab: the tip lifts off the last
			-- mark and swings to the next one over 45% of the gap, then drives.
			if (a.krCocked or 0) < next_ and now >= a.krT0 + (next_ - 1) * step - step * 0.45 then
				a.krCocked = next_
				if arm and arm.part and not arm.part.dead then
					arm.phaseFor = step * 0.45
					Fn.krakenArmPhase(arm, "SpearCock", now, a.krMarks[next_])
				end
			end
			if now >= a.krT0 + (next_ - 1) * step then
				Fn.krakenSpearStab(creature, def, p, now, next_)
			end
		end
		-- THE OPENING, and it is the move's own ending rather than a counter: the
		-- tip is through the planking and cannot come out for `stuck` seconds, at
		-- the same 3x a Down knuckle takes. The fight tick stands it up on
		-- `downUntil` like every other window in the fight.
		if a.krStuckAt and now >= a.krStuckAt then
			a.krStuckAt = nil
			local at = a.krMarks[#a.krMarks]
			if arm and arm.part and not arm.part.dead then
				arm.phaseFor = p.stuck or 4.0
				arm.downUntil = now + (p.stuck or 4.0)
				Fn.krakenArmPhase(arm, "Stuck", now, at)
				Fn.krakenArmHot(arm, true, at)
			end
			fireEvent("krakenSpearStuck", at, { duration = p.stuck or 4.0, skin = p.skin })
		end
	end,
	finish = function(creature, _def, _p, now)
		local a = creature.attack
		local arm = a and a.krArm
		-- Only if the stick never happened - a cancelled cast, or a mark list that
		-- never got built because no arm was free. A limb that IS stuck is owned by
		-- `downUntil` from here, and standing it up at finish would close the
		-- window the move exists for about four seconds early.
		if arm and arm.phase ~= "Stuck" and arm.part and not arm.part.dead then
			arm.phaseFor = 1.0
			Fn.krakenArmPhase(arm, "Rest", now)
			Fn.krakenArmHot(arm, false)
		end
	end,
}

-- SUCKER VOLLEY. The arm rears right back and whips over, throwing a fan of
-- suckers onto marked ground - and then hangs over the bulwark, spent.
K.ATTACK_HANDLERS.krakenvolley = {
	windup = function(creature, _def, p, u, sub)
		local a = creature.attack
		if Fn.krakenSetup(creature) then
			local arm = Fn.krakenFreeArm(creature)
			a.krArm = arm
			if arm then
				local root = Fn.nearestPlayerRoot(Fn.krakenShip(creature))
				local at = Fn.krakenSlamTarget(creature, root)
				a.krAt = at
				arm.phaseFor = a.windup
				-- REAR, REUSED RATHER THAN RE-AUTHORED. The volley's windup is the
				-- pile slam's silhouette - a limb hauling 260 studs clear of the
				-- rail over two and a half seconds - and that is exactly right: the
				-- two moves start identically and the BLOW is the surprise. A
				-- player who reads a rear as "get out of the disc" is not wrong,
				-- they are just about to find out there are six discs.
				Fn.krakenArmPhase(arm, "Rear", os.clock(), at)
				fireEvent("telegraph", at, {
					kind = "mark",
					duration = a.windup,
					radius = p.spread or 30,
					skin = p.skin,
				})
			end
		end
		creature.model:PivotTo(poseCFrame(creature, sub + 0.45 * u, 0, math.rad(-12) * u))
	end,
	fire = function(creature, def, p, now)
		local a = creature.attack
		local at = a.krAt
		if not at then
			return
		end
		local kr = K.KRAKEN
		local phase = creature.krakenPhase or 1
		local lowX = if phase >= 2 then -kr.HULL_X + 8 else kr.QD_TO_X + 8
		local highX = if phase >= 2 then kr.HULL_X - 8 else kr.FC_FROM_X - 8
		local cx, _cy, cz = Fn.krakenLocal(creature, at)
		local count = p.count or 6
		local spread = p.spread or 30
		local marks = {}
		for i = 1, count do
			-- A FAN AND NOT A SCATTER, which is the difference between this and the
			-- mortar: evenly spaced along the deck about the aim point, alternating
			-- to either side of the centreline, so what lands is a readable arc
			-- with gaps in it rather than six rolls of the dice. The mortar is
			-- random on purpose (it is about taking the floor away); this is
			-- ordered on purpose (it is about one step sideways).
			local t = if count > 1 then (i - 1) / (count - 1) - 0.5 else 0
			local x = math.clamp(cx + t * spread * 2, lowX, highX)
			local z = math.clamp(cz + (if i % 2 == 0 then 7 else -7), -14, 14)
			local mark = Fn.krakenAt(creature, x, Fn.krakenDeckY(x), z)
			table.insert(marks, mark)
			-- Fn.queueStrike end to end: it draws the disc at `tellAt`, resolves
			-- the hit at `hitAt` with the boss height tolerance, and fires the
			-- impact. No new tech, which is why this move is two dozen lines.
			Fn.queueStrike(creature, def, p, mark, now, now + (p.flight or 1.1) + (i - 1) * (p.stagger or 0.14), {
				radius = p.radius or 8,
			})
		end
		local arm = a.krArm
		fireEvent("krakenVolley", at, {
			from = if arm and arm.part then arm.part.pos else Fn.krakenEye(creature),
			marks = marks,
			flight = p.flight or 1.1,
			stagger = p.stagger or 0.14,
			skin = p.skin,
		})
		-- THE OPENING, OPENED AT FIRE AND NOT AT FINISH, deliberately: the drape IS
		-- the whip's follow-through, so the crossfade out of Rear has to start while
		-- the suckers are still in the air. What a player sees is one motion - the
		-- limb throws and falls onto the rail - with the window already open by the
		-- time the first disc resolves.
		if arm and arm.part and not arm.part.dead then
			-- Over the bulwark at the fan's own station, through Fn.krakenDrapeAt so
			-- the hitbox lands on the planking where the limb is drawn rather than
			-- on the aim point out in the middle of the deck.
			local rest = Fn.krakenDrapeAt(creature, cx)
			arm.phaseFor = p.drape or 2.5
			arm.downUntil = now + (p.drape or 2.5)
			Fn.krakenArmPhase(arm, "Drape", now, rest)
			Fn.krakenArmHot(arm, true, rest)
		end
	end,
	strike = function(creature, _def, _p, now, _dt, _u, _root, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.2, math.sin(now * 1.6) * math.rad(3), math.rad(-6)))
	end,
}

-- MAELSTROM COIL. Three seconds of being followed by something under the water,
-- then a column - and if the column comes up through nobody, the limb flops.
K.ATTACK_HANDLERS.krakencoil = {
	windup = function(creature, _def, p, u, sub)
		local a = creature.attack
		if Fn.krakenSetup(creature) then
			local arm = Fn.krakenFreeArm(creature)
			a.krArm = arm
			if arm then
				local root, player = Fn.nearestPlayerRoot(Fn.krakenShip(creature))
				a.krPlayer = player
				a.krAt = Fn.krakenSlamTarget(creature, root)
				a.krTrackAt = 0
				arm.phaseFor = a.windup
				Fn.krakenArmPhase(arm, "Coil", os.clock(), a.krAt)
				fireEvent("krakenCoil", a.krAt, { duration = a.windup, skin = p.skin })
			end
		end
		-- THE TRACK. Re-aimed on its own clock rather than every frame (see the
		-- row's `trackStep`), through Fn.krakenArmAim rather than krakenArmPhase -
		-- which is the whole reason that function exists: restamping the phase
		-- would restart the client's crossfade every sixth of a second and the limb
		-- would never finish sinking.
		--
		-- AND IT STOPS BEFORE THE END, which is the move's counterplay and the only
		-- reason it is a dodge rather than a tax: the last 15% of the windup is
		-- COMMITTED, so a step taken once the mark goes still is a step out of the
		-- column. Without this the attack would be unavoidable by construction, and
		-- an unavoidable attack does not need a three-second tell.
		local arm = a.krArm
		if arm and arm.part and not arm.part.dead and u < 0.85 and os.clock() >= (a.krTrackAt or 0) then
			a.krTrackAt = os.clock() + (p.trackStep or 0.15)
			-- The player it PICKED, while they are alive and on the board; whoever
			-- is nearest otherwise, so a tracked player logging out mid-cast does
			-- not leave a wake circling an empty deck.
			local character = a.krPlayer and a.krPlayer.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if not root then
				root, a.krPlayer = Fn.nearestPlayerRoot(Fn.krakenShip(creature))
			end
			if root then
				a.krAt = Fn.krakenSlamTarget(creature, root)
				Fn.krakenArmAim(arm, a.krAt)
			end
		end
		creature.model:PivotTo(poseCFrame(creature, sub + 0.2 * u, 0, math.rad(4) * u))
	end,
	fire = function(creature, def, p, now)
		local a = creature.attack
		local at = a.krAt
		if not at then
			return
		end
		local arm = a.krArm
		if arm and arm.part and not arm.part.dead then
			arm.phaseFor = p.duration
			Fn.krakenArmPhase(arm, "Erupt", now, at)
		end
		-- THE HITS ARE COUNTED, not just dealt, because the WHIFF is the mechanic:
		-- whether anybody was standing there decides whether the party gets a
		-- three-second window or the boss gets its damage. Written out rather than
		-- handed to `damagePlayersInRadius` for exactly that reason - that helper
		-- returns nothing, and a move whose reward turns on the answer cannot ask a
		-- question it does not get an answer to.
		local lo, hi = Fn.bossRoll(creature, def, p.damage)
		local hits = 0
		for _, entry in Fn.livingRootsNear(at, p.radius or 18) do
			if math.abs(entry.root.Position.Y - at.Y) <= K.BOSS_HEIGHT_TOLERANCE then
				hits += 1
				PlayerService.damage(entry.player, math.random(lo, hi), creature, { bypassIframe = true })
			end
		end
		a.krHits = hits
		fireEvent("krakenErupt", at, { radius = p.radius or 18, hit = hits > 0, skin = p.skin })
	end,
	finish = function(creature, _def, p, now)
		local a = creature.attack
		local arm = a and a.krArm
		if not arm or not arm.part or arm.part.dead then
			return
		end
		if (a.krHits or 0) > 0 then
			-- IT LANDED, so there is no reward: the column sinks back the way it
			-- came. Routed through Coil rather than straight to Rest, and that is a
			-- measured choice rather than a tidy one - Erupt's crest is 158 studs
			-- over the deck and Rest's tip is 150 studs under the sea, so the
			-- direct crossfade passes through a shape neither pose is (it measured
			-- 0.39 of the girth bound, the worst pair in the pass). Erupt -> Coil is
			-- 1.05 and Coil -> Rest is 1.25, so the two-step is strictly better AND
			-- is what the move looks like: the column goes back under.
			arm.phaseFor = 0.9
			arm.downUntil = now + 0.9
			Fn.krakenArmPhase(arm, "Coil", now, a.krAt)
			Fn.krakenArmHot(arm, false)
			return
		end
		-- THE WHIFF. The only place in this fight where a successful dodge is worth
		-- damage: a column with nobody under it has nothing holding it up, so the
		-- limb comes down across the deck Exposed AND hot - the 2x window every
		-- body controller already draws, plus the 3x knuckle, which is the same
		-- pairing the wrench's break earns.
		arm.part.exposedUntil = now + (p.flop or 3.0)
		arm.part.model:SetAttribute(ATTR.EXPOSED, true)
		arm.phaseFor = p.flop or 3.0
		arm.downUntil = now + (p.flop or 3.0)
		Fn.krakenArmPhase(arm, "Down", now, a.krAt)
		Fn.krakenArmHot(arm, true, a.krAt)
		fireEvent("krakenErupt", a.krAt, { radius = p.radius or 18, hit = false, whiff = true, skin = p.skin })
	end,
}

-- SIPHON OVERCHARGE. Five seconds of charging a deluge at half again the usual
-- coverage, at DOUBLE damage taken, and the party can make it blow up in the
-- animal's own funnel.
K.ATTACK_HANDLERS.krakenovercharge = {
	windup = function(creature, _def, p, u, sub)
		local a = creature.attack
		local now = os.clock()
		if Fn.krakenSetup(creature) then
			-- THE BASELINE, measured off the health the head had when the charge
			-- STARTED. The wrench's ruling, applied to a boss instead of an arm: a
			-- threshold has to mean "damage done during the charge", or a head
			-- already at 20% would misfire to a scratch.
			a.krHp0 = creature.health
			-- THE 2x, and it is the ordinary expose window rather than a new
			-- multiplier: `exposedUntil` already means "hits land double" in
			-- hitModifiers and the client already draws the dazed tell off
			-- ATTR.EXPOSED, so the biggest risk window in the fight costs one
			-- assignment and inherits a language players have seen on every
			-- charger since the first island.
			creature.exposedUntil = now + a.windup
			creature.model:SetAttribute(ATTR.EXPOSED, true)
			-- The siphon gapes and its core winds up: `inkFlare` drives
			-- KrakenBodyController.flareSiphon for the whole charge, which is the
			-- only Neon the animal owns besides its eyes.
			fireEvent("inkFlare", Fn.krakenEye(creature), { duration = a.windup, charge = 1, skin = p.skin })
		end
		-- THE INTERRUPT, TESTED EVERY FRAME, and cutting the phase short rather
		-- than setting a flag and waiting: `a.phaseUntil = now` is the wrench's own
		-- idiom for "this is over", and it hands control to `fire` on the next tick
		-- with the ordinary damage, cooldown and recover path intact.
		if not a.krMisfire and a.krHp0 and (a.krHp0 - creature.health) >= (p.breakDamage or 3600) then
			a.krMisfire = true
			a.phaseUntil = now
		end
		creature.model:PivotTo(poseCFrame(creature, sub + 0.55 * u, 0, math.rad(8) * u))
	end,
	fire = function(creature, def, p, now)
		local a = creature.attack
		-- THE CHARGE WINDOW CLOSES HERE, however the charge ended. Re-asserted
		-- rather than simply cleared, because the head may ALSO be inside a real
		-- siphon window (both arms broken in one cycle), which owns the same
		-- attribute and is not this move's to close: the generic expose tick will
		-- have set it false on the frame `exposedUntil` expired, so the window's own
		-- tell has to be put back.
		creature.exposedUntil = nil
		creature.model:SetAttribute(ATTR.EXPOSED, if creature.krakenWindowUntil then true else nil)
		if a.krMisfire then
			-- THE MISFIRE, and the reward is the largest in the fight: BOTH arms on
			-- the planking with both knuckles lit, for `down` seconds. Not "the arms
			-- that were free" - both of them, whatever they were doing, because the
			-- deluge going off inside the animal is something that happens to the
			-- whole animal.
			fireEvent("krakenMisfire", Fn.krakenEye(creature), { duration = 1.2, skin = p.skin })
			local state = Fn.krakenState(creature)
			for slot = 1, 2 do
				local arm = state.arms[slot]
				if arm and arm.part and not arm.part.dead then
					-- Apart on X, so two limbs crashing down at once are two
					-- targets rather than one pile: Fn.krakenArmPlace parks a Down
					-- hitbox on its target exactly, and KrakenPath's Down pose
					-- takes its station from the same point.
					local x = -22 + (slot - 1) * 44
					local at = Fn.krakenAt(creature, x, Fn.krakenDeckY(x), 0)
					arm.phaseFor = p.down or 4.0
					arm.downUntil = now + (p.down or 4.0)
					Fn.krakenArmPhase(arm, "Down", now, at)
					Fn.krakenArmHot(arm, true, at)
				end
			end
			return
		end
		-- NOBODY STOPPED IT: the wall lands, off `krakendeluge`'s own fire path with
		-- THIS row's numbers. One implementation of "a wall of ink crosses the main
		-- deck", two sets of constants - seven ranks at r11 here against five at r9
		-- there - so the overcharge can never drift away from the move it is a
		-- bigger version of.
		K.ATTACK_HANDLERS.krakendeluge.fire(creature, def, p, now)
	end,
	strike = function(creature, _def, _p, now, _dt, _u, _root, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.3, math.sin(now * 2.4) * math.rad(4), math.rad(6)))
	end,
}

-- ---------------------------------------------------------- the gullet's book

-- The room's centre at floor level: the dais, and what every wave in phase
-- three expands out of.
function Fn.krakenDais(creature): Vector3
	return creature.anchor or creature.pos
end

K.ATTACK_HANDLERS.krakenheartbeat = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.2 * math.sin(u * math.pi), 0, 0))
	end,
	fire = function(creature, def, p, now)
		local at = Fn.krakenDais(creature)
		local width = p.ringWidth or 7
		local arm = p.arm or 0.85
		-- THE METRONOME TIGHTENS as the polyps fall - `creature.krakenBeat` is
		-- written by the fight tick off the row's `machine.polypStep`, so the
		-- room speeds up because the party is winning rather than because a
		-- health bar moved.
		local interval = (p.interval or 0.62) * (creature.krakenBeat or 1)
		for i, r in p.rings do
			local hitAt = now + arm + (i - 1) * interval
			Fn.krakenQueueWave(creature, def, p, {
				at = at,
				inner = math.max(0, r - width * 0.5),
				outer = r + width * 0.5,
				tellAt = hitAt - arm,
				hitAt = hitAt,
				-- A thin band the same height as the room: the dodge is
				-- crossing it before it detonates, which is how every ring wave
				-- in this project is answered.
				height = K.BOSS_HEIGHT_TOLERANCE,
			})
		end
	end,
}

K.ATTACK_HANDLERS.krakenperistalsis = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.3 * u, 0, 0))
	end,
	fire = function(creature, def, p, now)
		local at = Fn.krakenDais(creature)
		local width = p.ringWidth or 9
		local arm = p.arm or 0.9
		-- ONE GAP FOR THE WHOLE WAVE, rolled per cast. Rolling it per RING
		-- would be a different move: four unrelated arcs is a coin flip, one arc
		-- travelling outward is a lane you run down.
		local gapFrom = math.random() * math.pi * 2
		local gapTo = gapFrom + (p.gap or math.rad(70))
		for i, r in p.rings do
			local hitAt = now + arm + (i - 1) * (p.interval or 0.72)
			Fn.krakenQueueWave(creature, def, p, {
				at = at,
				inner = math.max(0, r - width * 0.5),
				outer = r + width * 0.5,
				gapFrom = gapFrom,
				gapTo = gapTo,
				tellAt = hitAt - arm,
				hitAt = hitAt,
				height = K.BOSS_HEIGHT_TOLERANCE,
			})
		end
	end,
}

K.ATTACK_HANDLERS.krakenacidtide = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.4 * u, 0, math.rad(8) * u))
	end,
	fire = function(creature, def, p, now)
		local at = Fn.krakenDais(creature)
		local ranks = p.ranks or 6
		local arm = p.arm or 0.85
		-- Wall to wall on a rolled bearing, so the high ground is the answer
		-- rather than a memorised corner.
		local bearing = math.random() * math.pi * 2
		local dir = Vector3.new(math.cos(bearing), 0, math.sin(bearing))
		local across = rotateFlat(dir, math.pi * 0.5)
		local width = p.width or 250
		local lanes = math.max(2, math.floor(width / 24) + 1)
		for rank = 0, ranks - 1 do
			local d = -width * 0.5 + rank * (p.rankSpacing or 34)
			local hitAt = now + arm + rank * (p.interval or 0.36)
			for k = 0, lanes - 1 do
				local offset = (k / (lanes - 1) - 0.5) * width
				Fn.krakenQueueWave(creature, def, p, {
					at = at + dir * d + across * offset,
					radius = p.radius or 12,
					tellAt = hitAt - arm,
					hitAt = hitAt,
					-- THE FLOOD HAS A CEILING, not a tolerance band: anything
					-- more than `safeHeight` over the room's floor is over the
					-- tide. The dais's top is 2.2 and the entry pad's 1.1, so
					-- the middle of the room is the high ground - which is
					-- where every other move here wants you anyway.
					maxY = p.safeHeight or 1.8,
					pool = p.pool,
				})
			end
		end
	end,
}

K.ATTACK_HANDLERS.krakenantibodies = {
	windup = function(creature, _def, _p, u, sub)
		creature.model:PivotTo(poseCFrame(creature, sub + 0.2 * u, 0, 0))
	end,
	fire = function(creature, _def, p, _now)
		local row = Creatures.items[p.row or "kraken_antibody"]
		if not row then
			return
		end
		local at = Fn.krakenDais(creature)
		local count = math.random(p.countMin or 3, p.countMax or 5)
		for i = 1, count do
			local bearing = (i / count) * math.pi * 2 + math.random() * 0.6
			local spawn = at
				+ Vector3.new(math.cos(bearing) * (p.spawnR or 96), 1.5, math.sin(bearing) * (p.spawnR or 96))
			-- NOT `partOf`. These are adds, not a gate: an antibody counted
			-- against `partsAlive` would make the heart unaimable for as long as
			-- one of them lived, which is not what the move is for and would
			-- turn a pressure spawn into a second boss gate.
			--
			-- ...and NOT `noLinger` either, which is the other half of the same
			-- decision. Every other body this fight spawns has an owner that
			-- takes it down (`partOf`, and `removeOwnedParts`); an antibody has
			-- neither, so the linger sweep has to be the thing that collects it
			-- or a wipe would leave five chasers loose in a sealed room forever.
			CreatureService.spawn(row, spawn, nil, "Neutral", {
				suppressDrops = true,
				bounty = 0.4,
				healthMult = Fn.partyMult(creature), -- was creature.healthMult: NO SUCH FIELD (extra.healthMult is the real home) - nil rode through and the kraken's arms, dais adds and polyps never party-scaled
			})
			fireEvent("emerge", spawn, { radius = 6, skin = p.skin })
		end
	end,
}

-- ------------------------------------------------------- the phase machine

-- THE SWALLOW. Phase two ends, the siphon opens, and everyone still standing is
-- moved 20,000 studs into the animal.
--
-- WHAT MOVES AND WHAT DOES NOT: the boss's ANCHOR and POS move (the fight
-- measures every phase-three wave off the dais, and `Fn.nearestPlayerRoot`,
-- `aggro` and the pool tick all read `creature.pos`), and so does its pose
-- centre, so nothing is drawn at a ship the party has left. The MODEL is
-- already hidden - it has been since the rise - so there is no teleport to see.
-- The party is moved by BossService, which is the only owner of the list of who
-- they are; this side only says where.
function Fn.krakenSwallow(creature, def, now: number)
	local state = Fn.krakenState(creature)
	local gullet = Fn.krakenGulletFloor()
	fireEvent("krakenSwallow", Fn.krakenEye(creature), {
		to = gullet,
		duration = 2.0,
		name = def.name,
	})
	-- The arms go with the ship. Retired rather than killed: nobody earned
	-- these, and a kill would count `partsAlive` down into the window machinery
	-- one last time on the way out.
	for slot = 1, 2 do
		local arm = state.arms[slot]
		if arm and arm.part and not arm.part.dead then
			Fn.krakenRetireArm(creature, arm)
		end
		state.arms[slot] = nil
	end
	Fn.krakenClearProps(creature)
	creature.partsAlive = 0
	creature.partsDownAt = nil
	creature.krakenPhase = 3
	creature.krakenShip = Fn.krakenShip(creature)
	creature.anchor = gullet
	creature.pos = gullet
	-- A HEART IS NOT A HEAD. The capture sphere was 280 studs so that a party on
	-- the deck could reach a mantle standing 350 studs off the beam; the same
	-- sphere in a room 236 studs across would BE the room, and every shot fired
	-- anywhere in it would land on the heart whether or not it was aimed there -
	-- including the shots aimed at the six polyps that are supposed to gate it.
	-- The heart mass is ~34 x 29 x 37 slung over the dais, so 30 is the animal.
	creature.hitRadius = K.KRAKEN.HEART_HIT_R
	if creature.pose then
		creature.pose.center = gullet
	end
	creature.model:SetAttribute(ATTR.PHASE_INDEX, 3)
	creature.model:SetAttribute(ATTR.SIPHON_OPEN, nil)
	creature.model:SetAttribute(ATTR.EXPOSED, nil)
	creature.model:SetAttribute(ATTR.POSE_CENTER, gullet)
	-- The one thing BossService cannot work out for itself - see `fightCenter`
	-- there, and ATTR.FIGHT_CENTER's note at the top of this file.
	creature.model:SetAttribute(ATTR.FIGHT_CENTER, gullet)
	CreatureService.ArenaMove:Fire(def.islandId, K.KRAKEN.GULLET_ARENA)
	Fn.plantKrakenPolyps(creature, def)
	creature.nextAttackAt = now + 4.0
end

-- Take one arm off the board WITHOUT killing it. `removeOwnedParts`' per-part
-- retire, for one part: no Killed event, no loot, no drop, and no ring count -
-- which is the whole difference from a break. Used by the withdrawal and by the
-- swallow.
function Fn.krakenRetireArm(creature, arm)
	local part = arm.part
	arm.part = nil
	if not part or part.dead then
		return
	end
	part.dead = true
	part.partOf = nil
	part.krakenHot = nil
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
	creature.partsAlive = math.max(0, (creature.partsAlive or 0) - 1)
end

-- The six growths, on the gullet's authored socket collars. `partOf` again, so
-- the `vulnerableWhen = "partsDown"` rule the arms used on the ship gates the
-- heart in the room - one mechanism, two fights.
function Fn.plantKrakenPolyps(creature, def)
	local row = Creatures.items["kraken_polyp"]
	local arena = BossArenas.items[K.KRAKEN.GULLET_ARENA]
	local sockets = arena and arena.sockets
	if not row or not sockets then
		return
	end
	local state = Fn.krakenState(creature)
	local want = math.min((def.machine and def.machine.polyps) or 6, #sockets)
	local floor = Fn.krakenGulletFloor()
	local planted = 0
	for i = 1, want do
		local socket = sockets[i]
		local at = Vector3.new(floor.X + socket.X, floor.Y + socket.Y, floor.Z + socket.Z)
		local model = CreatureService.spawn(row, at, nil, "Neutral", {
			noLinger = true,
			suppressDrops = true,
			bounty = 0.5,
			healthMult = Fn.partyMult(creature), -- was creature.healthMult: NO SUCH FIELD (extra.healthMult is the real home) - nil rode through and the kraken's arms, dais adds and polyps never party-scaled
		})
		local part = byModel[model]
		if part then
			part.partOf = creature
			part.socketIndex = i
			part.pos = at
			model:PivotTo(CFrame.new(at))
			model:SetAttribute(ATTR.SOCKET_INDEX, i)
			if creature.row.vulnerableWhen == "partsDown" then
				model:SetAttribute(ATTR.WEAKPOINT, true)
			end
			planted += 1
		end
	end
	creature.partsAlive = planted
	creature.partsDownAt = nil
	state.polypsPlanted = planted
	creature.krakenBeat = 1
end

-- THE HEART'S DEATH, off the gimmick hook (`Creatures.items.kraken.gimmick`) -
-- which is the only place in this file a boss's own death can be answered from,
-- because `Fn.updateBoss` is not called for a creature that is already dead.
--
-- It fires the collapse and asks BossService to put the party back on the ship.
-- The ride HOME from there is BossService's own, four seconds later
-- (RETURN_DELAY): by then the participants are standing on the Tidebreak, which
-- is where `sendHome` looks for them once FightCenter is cleared.
K.GIMMICKS.krakenheart = {
	onKill = function(creature)
		if creature.krakenPhase ~= 3 then
			return
		end
		Fn.krakenClearProps(creature)
		fireEvent("krakenCollapse", creature.pos, { duration = 3.0 })
		creature.model:SetAttribute(ATTR.FIGHT_CENTER, nil)
		local def = bossDef(creature)
		if def and def.islandId then
			CreatureService.ArenaMove:Fire(def.islandId, def.islandId)
		end
	end,
}

-- THE FIGHT'S OWN FRAME. Called at the top of `Fn.updateBoss` for this pose and
-- nowhere else, BEFORE the collapse branch and before the mode dispatch, so it
-- runs whatever the boss is doing - a machine that stalled because an attack was
-- running would be a fight that stops advancing when it is busiest.
function Fn.updateKrakenFight(creature, def, now: number)
	local state = Fn.krakenState(creature)
	local machine = def.machine
	if not machine then
		return
	end
	-- Props and waves first, and unconditionally: they are hazards already in
	-- the world, and a boss that is collapsing must not leave a cask rolling.
	if creature.collapsing or creature.dead then
		Fn.krakenClearProps(creature)
		table.clear(state.waves)
		return
	end
	Fn.krakenStepProps(creature, now)
	Fn.krakenStepWaves(creature, now)
	if not creature.mode then
		return
	end

	if not creature.krakenPhase then
		-- FIRST FRAME, AND IT IS DURING THE RISE ON PURPOSE. The head's own
		-- health bar is gated on `partsAlive > 0` (the row's `vulnerableWhen =
		-- "partsDown"`), and the rise's last frame clears `untargetable` - so
		-- planting the arms only once the boss was on its feet would leave one
		-- frame with the flag down and no arm standing, which is one frame of a
		-- finale boss taking full damage for free. The arms come up WITH it,
		-- which is also what the animal looks like.
		--
		-- The ship's origin is latched here rather than read every frame,
		-- because phase three moves `creature.anchor` into the gullet and the
		-- ship's own coordinates have to survive that.
		creature.krakenPhase = 1
		creature.krakenShip = creature.anchor or creature.pos
		-- THE BOSS IS NOT AT THE ARENA CENTRE, and this is the line that makes
		-- that true rather than a comment about it. `BossArenaService.
		-- placeAuthored` lands the SHIP on the arena centre (`KrakenArena_Base`
		-- is the hull), and `BossService.arenaPosition` therefore raises the
		-- boss there too - in the middle of the deck the party is standing on.
		-- The head belongs 350 studs off the port beam (K.KRAKEN.HEAD_AT, the
		-- generator's own HANDOFF: "do not expect the boss at the arena
		-- centre"), and moving it is the wiring's job.
		--
		-- IT MOVES THREE THINGS AT ONCE, and all three for the same reason -
		-- they are the same claim seen from three sides: `pos` is the capture
		-- sphere a shot has to reach, `anchor` is what `Fn.updateBoss` re-pins
		-- `pos` to every frame and what the range check measures, and the pose
		-- centre is where the client draws the animal. Leaving any one of them
		-- at the arena centre would put the head, its hitbox and its range check
		-- in three different places - and each of them would look right alone.
		--
		-- The ship's own origin is latched ABOVE, before this, because every
		-- deck coordinate in this fight is relative to it and phase three moves
		-- `anchor` again - 20,000 studs, into the gullet.
		local head = Fn.krakenAt(creature, K.KRAKEN.HEAD_AT.X, 0, K.KRAKEN.HEAD_AT.Z)
		creature.anchor = head
		creature.pos = head
		-- (The hide is already the size of the animal: `Fn.updateBoss`'s init
		-- block set `creature.hitRadius` from the row's 200 x the body scale =
		-- 280, which is the mantle's own half-width at the pack's authored
		-- SCALE 6.0. That is what puts its nearest face ~70 studs off the port
		-- rail and therefore inside a weapon's reach during the siphon window;
		-- see the row. Phase three shrinks it - a heart is not a head.)
		creature.partsAlive = 0
		creature.model:SetAttribute(ATTR.PHASE_INDEX, 1)
		Fn.plantKrakenArm(creature, def, 1, now)
		Fn.plantKrakenArm(creature, def, 2, now)
	end
	creature.tellMult = (machine.tellMult or {})[creature.krakenPhase] or 1
	if creature.mode == "rising" then
		-- Everything past here is the fight: windows, withdrawals and the phase
		-- step. None of it can happen before the animal is up, and the arms are
		-- placed by the loop below only once it is - during the rise they sit
		-- where they were planted, which is their rest point.
		return
	end

	if creature.krakenPhase >= 3 then
		-- --------------------------------------------------------- the gullet
		local live = #Fn.livingArms(creature)
		creature.partsAlive = live
		-- The heart is unaimable while any polyp stands - the same declarative
		-- rule the arms used, so nothing here has to touch `untargetable`.
		local dead = math.max(state.polypsPlanted - live, 0)
		creature.krakenBeat = (machine.polypStep or 0.86) ^ dead
		if live == 0 and state.polypsPlanted > 0 and not creature.krakenFrantic then
			-- FRANTIC OVERLAP. All six are cut and the heart is open, so the
			-- room stops taking turns: the tells tighten again and the gaps
			-- between moves collapse. Expressed as the existing `enraged` flag
			-- rather than a second pacing system - it is exactly what that flag
			-- means, and `Fn.endBossAttack` already halves the cooldowns off it.
			creature.krakenFrantic = true
			creature.enraged = true
			creature.model:SetAttribute(ATTR.ENRAGED, true)
			creature.tellMult = ((machine.tellMult or {})[3] or 1) * 0.7
			creature.model:SetAttribute(ATTR.SIPHON_OPEN, true)
			fireEvent("enrage", creature.pos, { name = def.name })
		end
		-- kill() stamped these when the last polyp fell; the window they mean on
		-- the ship does not exist here, so they are cleared rather than left to
		-- open a siphon inside the animal's own gut.
		creature.partsDownAt = nil
		return
	end

	-- ------------------------------------------------------------ the ship
	-- Arms: place them, stand a Down one back up, and bring a withdrawn one
	-- back when its twelve seconds are up.
	for slot = 1, 2 do
		local arm = state.arms[slot]
		if arm then
			local part = arm.part
			if part and part.dead then
				-- BROKEN. `kill` has already counted `partsAlive` down and, at
				-- zero, stamped Exposed - the window below reads that. What is
				-- left is the withdrawal, which is this fight's own.
				arm.part = nil
				arm.returnAt = now + (machine.armReturn or 12.0)
				Fn.krakenArmPhase(arm, "Withdrawn", now)
				fireEvent("regrow", Fn.krakenAt(creature, arm.rest.X, K.KRAKEN.DECK_Y, arm.rest.Z), {
					count = 1,
					name = def.name,
					withdraw = true,
				})
			elseif part then
				-- TWO WAYS A COMMITTED LIMB COMES BACK UP, and they end in the
				-- same place because "back up" is one state:
				--
				--   * its punish window expired - a slam's three seconds on the
				--     planking, a broken haul's six of lying open;
				--   * OR IT WAS STRANDED, which is the case nothing else can
				--     notice. An attack can be cancelled without ever reaching
				--     its own `finish`: a juggle clears `creature.attack`
				--     outright (`Fn.applyKnockback`), and so does the boss's
				--     collapse, and the handler that would have stood this limb
				--     back up goes with it. `Fn.krakenFreeArm` only ever hands
				--     out an arm at Rest, so one limb left mid-sweep is one the
				--     fight never uses again and two is a fight with no attacks
				--     left in it that still runs forever. The test is "nothing
				--     is running AND this limb has been committed longer than
				--     any move commits one", which cannot be true of a live
				--     handler - the longest hold in the book is the wrench's
				--     four-second channel plus its six-second expose.
				local expired = arm.downUntil and now >= arm.downUntil
				local stranded = not creature.attack
					and arm.phase ~= "Rest"
					and now - (arm.phaseAt or now) > K.KRAKEN_ARM_STRAND
				if expired or stranded then
					arm.downUntil = nil
					arm.phaseFor = 1.0
					Fn.krakenArmPhase(arm, "Rest", now)
					Fn.krakenArmHot(arm, false)
				end
				Fn.krakenArmPlace(creature, arm, now)
			elseif arm.returnAt and now >= arm.returnAt and not creature.krakenWindowUntil then
				-- HELD WHILE THE WINDOW IS OPEN. A party that broke both arms
				-- earned all ten seconds; an arm whose twelve happened to expire
				-- in the middle of it would close the window early and take the
				-- reward back for a reason nobody could see.
				arm.returnAt = nil
				Fn.plantKrakenArm(creature, def, slot, now)
			end
		end
	end

	-- THE WINDOW. `kill` sets `partsDownAt` the moment the ring empties, which
	-- on this fight means BOTH arms are down inside one cycle - the whole loop.
	-- Latched here and the flag cleared, so `Fn.updateBoss`'s generic regrow
	-- branch (which would replant a ring this fight does not have) can never
	-- see it.
	if creature.partsDownAt and not creature.krakenWindowUntil then
		creature.partsDownAt = nil
		state.windows += 1
		creature.krakenWindowUntil = now + (machine.siphonWindow or 10.0)
		creature.model:SetAttribute(ATTR.SIPHON_OPEN, true)
		creature.model:SetAttribute(ATTR.EXPOSED, true)
		fireEvent("exposed", Fn.krakenEye(creature), { name = def.name })
	end
	if creature.krakenWindowUntil and now >= creature.krakenWindowUntil then
		creature.krakenWindowUntil = nil
		creature.model:SetAttribute(ATTR.SIPHON_OPEN, nil)
		creature.model:SetAttribute(ATTR.EXPOSED, nil)
		-- THE PHASE STEP, and it is counted rather than measured: two windows
		-- open the castles, two more and the animal swallows the ship's crew.
		local per = machine.windowsPerPhase or 2
		if state.windows >= per * 2 then
			Fn.krakenSwallow(creature, def, now)
			return
		end
		if state.windows >= per and creature.krakenPhase < 2 then
			creature.krakenPhase = 2
			creature.model:SetAttribute(ATTR.PHASE_INDEX, 2)
			fireEvent("bossStance", Fn.krakenEye(creature), { name = def.name, stance = 2 })
		end
		-- The arms come back the instant the window shuts, both of them, so the
		-- next cycle starts from a clean board rather than from whatever was
		-- left of the last one.
		for slot = 1, 2 do
			local arm = state.arms[slot]
			if arm and not arm.part then
				arm.returnAt = nil
				Fn.plantKrakenArm(creature, def, slot, now)
			end
		end
	end
end

-- ============================================================ gnashroot: the wire (2026-09-12)
--
-- THE MUD COLOSSUS IS DRAWN BY THE CLIENT, and this function is everything the
-- server owes it. GnashrootBodyController adopts a model on `Pose ==
-- "gnashroot"` and then draws the whole animal off GnashrootPath from the eight
-- channels in that module's THE STATE block. Until this existed nothing
-- published one, so the fight ran on the row's CreaturePack stand-in - the old
-- crocodile - and the rig was only ever seen in the intro cutscene, which
-- drives a stand-in of its own.
--
-- RIMEFANG'S ARRANGEMENT, NOT THE COLOSSUS ONE. This boss takes the plain
-- branch through every line of Fn.updateBoss; the row opts in with `rig`, NOT
-- `pose`, precisely so none of that changes (see the row). So this publishes,
-- hides the authority model, and touches nothing else.
--
-- IT IS ROOTED AS OF 2026-09-12 (the user: "he must be COMPLETELY
-- STATIONARY") and it is STILL not a `pose` boss: the row does it with
-- `speed = 0` and `standoff = 200`, so the prowl branch's move line is a
-- no-op it never reaches, exactly as `admiral_wrack` does. Nothing in this
-- function changed for that - it publishes `creature.yaw0` as the face and
-- takes the position from the pivot either way - but the sentence above used
-- to say "roams its mere", and a stale claim in the one comment that explains
-- the wiring is how the next reader learns the wrong thing.
--
-- AND IT DOES NOT PUBLISH `Eyes`. That channel is the client's
-- (GnashrootPath's THE STATE block): the eye row is a look with no hitbox, no
-- target pick and no HUD behind it, and GnashrootIntro drives it locally.
-- Publishing it would be a replicated write per frame for a decoration.
--
-- It returns on its first line for every row that is not Old Gnashroot -
-- Fn.rimefangDrive's and Fn.updatePyreliskHeart's rule - so one unconditional
-- call from the boss frame is the whole of the wiring.
K.GN_RIG = "gnashroot"

-- A RANGE GATE FOR THE ONE BOSS THAT CANNOT CLOSE A DISTANCE.
--
-- Old Gnashroot is rooted (`speed = 0`, `standoff = 200`), so unlike every
-- other row in this file it cannot answer "you are standing too far away" by
-- walking. Its book still holds a close-range move - `gnash`, a 33-stud snap
-- cone that is the punish for standing on the near bank - and the picker is
-- otherwise a uniform random draw over whatever is off cooldown. Against a
-- party at r 60 that draw spends one of the fight's attack slots on a bite
-- into empty water, on a 4.5s cooldown, roughly one pick in five: not a
-- balance problem so much as a boss that visibly does not work.
--
-- SO IT IS A ROW FIELD AND NOT A SPECIAL CASE. An attack may carry
-- `minRange` / `maxRange`, in studs from the boss's pivot to the nearest
-- player, and this refuses to offer it outside that band. Today exactly one
-- attack in the project has either (`old_gnashroot.gnash.maxRange = 36`), and
-- this function returns true on its first line for every row that is not that
-- boss - the same shape as `Fn.rfPickAllows`, for the same reason: a gate
-- that is inert for 30 rows should cost 30 rows nothing and should be
-- readable as inert.
--
-- IT GATES THE PICK, NOT THE BLOW. Once `beginBossAttack` has committed, the
-- attack runs to its end whatever the party does - a move that could be
-- cancelled by walking away is a move with no tell worth reading, and the aim
-- is latched at windup anyway (GnashrootPath's contract).
function Fn.gnPickAllows(creature, def, p): boolean
	if def.rig ~= K.GN_RIG or p == nil then
		return true
	end
	local low, high = p.minRange, p.maxRange
	if low == nil and high == nil then
		return true
	end
	local root, _player, dist = Fn.nearestPlayerRoot(creature.pos)
	-- Nobody to measure against: let the picker do what it always did rather
	-- than emptying the pool on an arena with no players left in it.
	if not root then
		return true
	end
	if low and dist < low then
		return false
	end
	if high and dist > high then
		return false
	end
	return true
end

function Fn.gnashrootPublish(creature, def, now: number)
	if def.rig ~= K.GN_RIG or not creature.model.Parent then
		return
	end
	local model = creature.model
	local cache = creature.gnWrote
	local first = cache == nil
	if first then
		cache = {}
		creature.gnWrote = cache
		-- The authority model stops being a picture: hits, the HUD and the
		-- cutscene's BossName handoff all still read it, but nothing on it is
		-- drawn or the animal would be there twice. Transparency only - it
		-- never touches CanCollide or the query flags, so every hit test in
		-- this fight keeps working on exactly the parts it always used.
		Fn.hideColossusModel(creature)
	end

	-- THE RISE IS THE RIG'S, AND THERE IS EXACTLY ONE OF IT. GnashrootPath.lift
	-- is `RISE_DEPTH * (rise - 1)`, and RISE_DEPTH is taken off the animal's own
	-- CROWN (42 world studs) precisely so the rig can bury itself - so
	-- publishing the FRACTION is what puts the whole 40-stud body under the
	-- peat. The price is that the server pivot must not climb as well, which is
	-- why the rising branch below holds a rigged boss at `-def.submerge`: pivot
	-- plus lift would be two rises stacked, and the row's 18 was sized for a
	-- stand-in a quarter of this thing's height.
	--
	-- The -20 degree nose-down pitch that branch also drops here was never
	-- visible either way: the controller takes POSITION from the pivot and
	-- nothing else (its rotation is GnashrootPath.bearing/lean).
	--
	-- The cubic is the easing the rising branch gives its own `e`. This runs
	-- before the mode dispatch, so it cannot be handed that number.
	local rise = 1
	if creature.mode == "rising" then
		rise = 1 - (1 - modeProgress(creature, now)) ^ 3
	end

	-- A DYING BOSS IS NOT MID-SWING. The collapse returns before
	-- Fn.updateBossAttack can run again, so an attack left standing by the
	-- death would hold both arms in a blow that never lands while the body goes
	-- down. Dropped here, the arms ease home (the controller holds the name
	-- until its own blend decays) and the fall is the last thing it does.
	local a = if creature.collapsing then nil else creature.attack
	local name, blend, strike = "", 0, 0
	if a then
		local p = a.p
		name = a.name
		-- THE PHASE CLOCK THE DAMAGE IS ON. Fn.updateBossAttack measures its own
		-- progress against these same three spans - `a.windup` (the SCALED
		-- figure, so an escalating fight's shorter tell moves the pose with it),
		-- then p.duration, then p.recover - so the body and the blow cannot be
		-- reading different times.
		if a.phase == "windup" then
			blend = math.clamp((now - a.phaseStart) / math.max(a.windup or p.windup, 1e-3), 0, 1)
		elseif a.phase == "strike" then
			-- The blow lands on the frame the strike phase OPENS (that is where
			-- the handler's `fire` runs), so it is struck for all of it.
			blend, strike = 1, 1
		else
			local u = math.clamp((now - a.phaseStart) / math.max(p.recover, 1e-3), 0, 1)
			blend, strike = 1 - u, 1 - u
		end
		-- AIM IS LATCHED ONCE, AT THE WINDUP, AND HELD UNTIL THE ATTACK ENDS -
		-- GnashrootPath's contract, and the attack TABLE's identity is the
		-- latch: Fn.beginBossAttack builds a fresh one per move and
		-- Fn.endBossAttack drops it, so this runs exactly once per attack and
		-- no phase change can re-enter it.
		if creature.gnAimFor ~= a then
			creature.gnAimFor = a
			-- Toward the target, not off the current yaw: `yaw0` lags the player
			-- by up to a turn and then spends the whole windup catching up,
			-- while the cone the blow actually cuts is taken from Fn.bossFacing
			-- at `fire` - that is, from where yaw0 will have ARRIVED. The
			-- target's bearing is the value those two converge on, so the fist
			-- commits to where the damage is going.
			local root = Fn.nearestPlayerRoot(creature.pos)
			creature.gnAim = if root then yawToward(root.Position - creature.pos) else creature.yaw0
			-- GnashrootPath.plantSide's rule, named so the two stay together:
			-- the +1 flank sits at body-local -Z, so a target at a negative
			-- body-local bearing is the one that arm reaches without the animal
			-- crossing over itself.
			local bearing = (creature.gnAim - creature.yaw0 + math.pi) % (math.pi * 2) - math.pi
			creature.gnAimSide = if math.sin(bearing) < 0 then 1 else -1
		end
	end
	local aim = if a then creature.gnAim or creature.yaw0 else creature.yaw0
	local side = if a then creature.gnAimSide or 1 else 1

	-- `rfPut` rather than a second copy of it: the change-cache and the NaN
	-- guard are the same contract here (an attribute write is a replicated
	-- write, and a NaN latches a channel off for the life of the creature), and
	-- it is handed whichever cache it is told to use.
	rfPut(model, cache, "Rise", rise)
	-- The idle watch, free to move every frame by the contract. `yaw0` is what
	-- the plain branch turns and what poseCFrame draws the hidden model with, so
	-- the drawn body and its authority point face the same way.
	rfPut(model, cache, "FaceAngle", creature.yaw0)
	rfPut(model, cache, "AttackBlend", blend)
	rfPut(model, cache, "Strike", strike)
	rfPut(model, cache, "AimAngle", aim)
	rfPut(model, cache, "AimSide", side)
	-- A string, so it cannot ride rfPut - same change-cache rule, same reason.
	-- "" BETWEEN ATTACKS AND NEVER nil: the controller's `isFed` tests this
	-- attribute's EXISTENCE, so an idle boss that published nothing at all would
	-- be reported as a rig with nobody driving it.
	if cache.Attack ~= name then
		cache.Attack = name
		model:SetAttribute("Attack", name)
	end

	-- AND THE PUNISH WINDOW HAS TO SHUT AGAIN. `hammerfall` carries `expose =
	-- 3.5`, so Fn.endBossAttack opens the window by setting BOTH
	-- `creature.exposedUntil` and ATTR.EXPOSED - but the only code that ever
	-- clears that attribute again lives in Fn.updateKitted, which a plain
	-- `archetype = "boss"` row never runs. It is the trap Fn.rimefangDrive
	-- documents at its `OpenUntil` publish, and this rig walked straight into
	-- it: the attribute LATCHED at the first hammerfall, so the core burned
	-- open for the rest of the fight and no later window could reopen a cue
	-- that had never shut.
	--
	-- THE ATTRIBUTE, AND NOTHING ELSE. `creature.exposedUntil` is the DAMAGE
	-- side and is left exactly where it is - clearing it here would be a
	-- balance change wearing a rendering fix. The test is the one `damage()`
	-- makes (`os.clock() < creature.exposedUntil`, hitModifiers): same clock -
	-- `update` takes `now` from os.clock() - and same comparison, so the drawn
	-- core and the window that is really taking double damage open and shut on
	-- the same frame.
	--
	-- IT ONLY EVER CLEARS. The window's `true` stays Fn.endBossAttack's to
	-- write, so a future exposure with no `exposedUntil` behind it (the parts
	-- ring's, say) cannot be stomped by this line a frame after it is set - it
	-- would simply not be latched here, which is exactly today's behaviour.
	if creature.exposedUntil and now < creature.exposedUntil then
		cache.Exposed = true
	elseif cache.Exposed then
		cache.Exposed = false
		model:SetAttribute(ATTR.EXPOSED, false)
	end

	if first then
		-- LAST, AND IN THIS ORDER. `Pose` is the signal the controller adopts on
		-- and it reads `PoseCenter` in the same breath. Every channel above is
		-- already on the model by now, so the adopt reads the real pose instead
		-- of readTarget's defaults - and that one matters: its default `Rise` is
		-- 1, a fully risen colossus that would then sink to meet its own rise.
		--
		-- PoseCenter is the ADOPT-TIME origin only. drawBody takes the centre
		-- from the model's pivot every frame after that, which is what keeps the
		-- mass you dodge and the mass you see the same object while this boss
		-- walks its mere.
		model:SetAttribute(ATTR.POSE_CENTER, creature.anchor or creature.pos)
		model:SetAttribute(ATTR.POSE, K.GN_RIG)
	end
end

function Fn.updateBoss(creature, now: number, dt: number)
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
		model:SetAttribute(ATTR.BOSS_NAME, def.name)
		-- A MULTI-ACT SHIP GETS A HULL THAT STOPS SHOTS. Built here because
		-- this is the one place a boss is initialised, and it needs `yaw0` and
		-- the pose centre, both of which exist by now. Opted in by
		-- `succeededBy` - the field that says "this creature's death is an act
		-- break, not an ending" - rather than by a boss id, so the collider
		-- belongs to the SHAPE of the fight and not to a name someone might
		-- copy. See Fn.wrackOccluder for why the World folder is the mechanism.
		if def.succeededBy then
			Fn.wrackOccluder(creature, def)
		end
		setMode(creature, "rising", def.riseTime, now)
		fireEvent("bossRise", creature.pos, { name = def.name, duration = def.riseTime })
	end

	-- Never lingers out: the fight's over when it's dead.
	creature.lastFoughtAt = now
	creature.knockVel = nil

	-- THE KRAKEN'S OWN FRAME, and it runs BEFORE the collapse branch and before
	-- the mode dispatch on purpose. Its arms, its hazards and its phase machine
	-- all have to advance while an attack is running - a machine that stalled
	-- because the boss was busy would be a fight that stops progressing exactly
	-- when it is loudest - and its props have to be collected on the frame the
	-- boss starts coming down, which is a frame the branch below returns on.
	-- `Fn.updateKrakenFight` returns on its first line for any row without a
	-- `machine` block, which is every boss but this one.
	if def.pose == "kraken" then
		Fn.updateKrakenFight(creature, def, now)
	end
	-- THE HEART'S FRAME, here for the Kraken's reason exactly: it publishes
	-- levels (the act, the pillar mask, the room's cadence) that must stay true
	-- whatever the boss is doing, and the branch below returns on the frames a
	-- fight is busiest. `Fn.updatePyreliskHeart` returns on its first line for
	-- every row that is not the Ashfall Heart, which is every row but one.
	Fn.updatePyreliskHeart(creature, def, now)
	-- THE MUD RIG'S FRAME, here for the same reason as the two above: the body
	-- is drawn entirely from what this publishes, so it has to be published on
	-- EVERY frame the boss has - including the ones the branches below return
	-- on (the rise, an attack, the collapse). `Fn.gnashrootPublish` returns on
	-- its first line for every row without `rig = "gnashroot"`, which is every
	-- row but one.
	Fn.gnashrootPublish(creature, def, now)

	-- Coming down. Checked before every other mode so that nothing - a stance
	-- change, an enrage, a queued attack - gets to speak over the death.
	if creature.collapsing then
		Fn.updateBossCollapse(creature, def, now)
		return
	end

	local sub = -def.submerge
	local root, player, dist = Fn.nearestPlayerRoot(creature.pos)

	if not creature.enraged and creature.health / creature.maxHealth <= def.enrageBelow then
		creature.enraged = true
		model:SetAttribute(ATTR.ENRAGED, true)
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
				Fn.hideColossusModel(creature)
			end
			local state = Fn.colossusState(creature, def)
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
			Fn.placeColossus(creature, def, now, root)
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
			Fn.hideColossusModel(creature)
			Fn.colossusState(creature, def).rise = e
			Fn.placeColossus(creature, def, now, root)
		elseif def.rig == K.GN_RIG then
			-- A RIGGED BOSS CLIMBS ON ITS OWN SIDE OF THE WIRE, so the pivot
			-- only holds its ground. `Fn.gnashrootPublish` publishes the rise as
			-- a fraction and GnashrootPath.lift turns that into 42 world studs
			-- of climb, sized off the animal's crown; lifting the pivot as well
			-- would be the same rise performed twice, from a depth (the row's
			-- 18) that was measured for the stand-in this replaced. Held at
			-- `sub`, where the prowl leaves it, so the frame the rise ends is
			-- not a step either.
			model:PivotTo(poseCFrame(creature, sub, 0, 0))
		else
			model:PivotTo(poseCFrame(creature, -def.riseDepth + (def.riseDepth + sub) * e, 0, math.rad(-20) * (1 - e)))
		end
		if u >= 1 then
			creature.untargetable = false
			setMode(creature, "prowl", 0, now)
			-- The tentacle ring rises with it (the Kraken).
			if def.parts then
				Fn.spawnBossParts(creature, def)
			end
		end
		return
	end

	-- ---------------------------------------------------------- colossus
	if def.pose == "noctyss" then
		Fn.updateNoctyss(creature, def, now, dt, root, player, dist)
		return
	end

	if def.entrenched then
		local state = Fn.colossusState(creature, def)
		-- THE CHIP FLOOR'S TWO FIELDS, WRITTEN ONCE A FRAME AND NOWHERE ELSE.
		-- `chip` is copied off the row so `damage()` - which is handed no
		-- `def` - can find it; `punishOpen` is RECOMPUTED rather than latched,
		-- so no exit from a window (a stagger ending, a death mid-lunge, an
		-- attack interrupted by a collapse) can leave it stuck open. The two
		-- windows are the stagger and the lunge's held plant; the post-surge
		-- window IS a stagger, so it is already counted.
		creature.chip = def.chip
		-- THE WINDOWS ARE NOW FOUR, not two: the stagger (which the post-surge
		-- one already is), the lunge's plant, the coilslam's fallen loop and
		-- the bite's low head. All three handler-owned ones are FULL damage
		-- (contract §4: "the server makes the creature damageable at full
		-- rate"), so they all lift the chip scaling the same way, and all three
		-- are recomputed rather than latched by their handlers.
		creature.punishOpen = creature.mode == "stagger"
			or (
				creature.mode == "attack"
				and (creature.lungeOpen == true or creature.coilOpen == true or creature.biteOpen == true)
			)
		-- THE FILLED METER, CASHED OUT. A flank whose meter filled owes two
		-- things, and they are DIFFERENT THINGS with different triggers, which
		-- is the whole of this block.
		--
		-- It is paid HERE - on the boss's own tick, where the fight's window
		-- machinery lives - rather than inside the `damage()` call that
		-- finished the meter off, which runs out of CombatService's shot queue.
		-- Held, not spent, while a window is already open or the boss is coming
		-- down.
		if def.pose == "pyrelisk" and creature.seamBreakSide and not creature.collapsing then
			if creature.mode ~= "stagger" and creature.mode ~= "rising" then
				local side = creature.seamBreakSide
				creature.seamBreakSide = nil
				-- ONE: THE 0.15, AND IT IS ON THE SCAR'S 0 -> 1 TRANSITION.
				-- `Fn.pyreliskMeterFill` ors this flank's mask into
				-- `state.seamsBroken`, which is MONOTONIC and therefore
				-- idempotent - so "was this flank already paid for?" is a
				-- question with the answer `no` exactly twice in the life of a
				-- fight. See `Fn.pyreliskFlankPaid` for why paying on
				-- meter-full instead would walk the dial down through 0.55 and
				-- 0.40 on cycles that are supposed to cost nothing but time.
				if not Fn.pyreliskFlankPaid(creature, side) then
					Fn.pyreliskMarkFlankPaid(creature, side)
					Fn.pyreliskChip(creature, def, K.PY_FLANK_FRACTION)
				end
				-- TWO: THE DROP, and the gate is deliberately NOT "this
				-- cash-out completed the pair". That is an EDGE, it happens
				-- once, and after a failed window it can never happen again -
				-- which would leave a party that lost the first window with no
				-- route back into act 2 at all. It is a LEVEL test on the scar
				-- mask instead: with both flanks already scarred, EITHER meter
				-- re-filling returns the arms. One meter, not two, which is the
				-- right price for a retry.
				if Fn.pyreliskBothFlanksBroken(state) and not creature.pyreliskArmsOut then
					Fn.pyreliskDropArms(creature, def, now)
				end
			end
		end
		-- THE ACT, PUBLISHED AS A LEVEL. Act 1 is the resting statement and it
		-- is made on the colossus's first entrenched frame rather than at rise,
		-- so a client that adopts the model at any instant reads it.
		if def.pose == "pyrelisk" and creature.pyreliskAct == nil then
			Fn.pyreliskPublishAct(creature, 1)
		end
		-- EACH ARM'S 0.35, RECONCILED OFF `partsAlive` RATHER THAN HOOKED INTO
		-- `kill()`. The generic parts path already counts the ring down and has
		-- no business learning about this fight; watching the count fall is the
		-- same information one frame later, and it cannot be missed by a death
		-- that took a different route (a collapse taking its parts with it, a
		-- pool tick landing the blow). Gated on `pyreliskArmsOut`, which
		-- `Fn.pyreliskArmsRetire` clears in the same call that zeroes the
		-- count - so a RETIREMENT can never be read as two kills.
		--
		-- GATED ON ACT 2, AND THE GATE IS KEPT THOUGH ITS FIRST REASON IS GONE.
		-- It was written because `creature.pyreliskArmsOut` stays SET past the
		-- arms (it is the re-cycle latch, and the act break is one-way) while
		-- act 3 planted seven more parts on this same `partsAlive` counter - so
		-- an ungated reconciliation read the first arm rock as an arm. Act 3 is
		-- cut and nothing plants on the counter again, but the test still says
		-- the true thing: these chips are act 2's, and the frame the second one
		-- lands on is the frame the body starts falling.
		--
		-- THE SECOND CHIP IS THE LETHAL ONE and it still floors here, at
		-- `K.PY_CHIP_FLOOR`. `Fn.pyreliskArmsDone`, below in the stagger
		-- branch, takes the remaining hair through `damage()` on this same
		-- frame - so the dial reads spent without a subtraction ever having
		-- entered the death path.
		if def.pose == "pyrelisk" and creature.pyreliskArmsOut and (creature.pyreliskAct or 0) == 2 then
			local live = creature.partsAlive or 0
			local was = creature.pyreliskArmsLive or live
			if live < was then
				Fn.pyreliskChip(creature, def, K.PY_ARM_FRACTION * (was - live))
				creature.pyreliskArmsLive = live
			end
		end
		-- (ACT 3'S SEVEN were reconciled here - a survivor mask rebuilt from
		-- what still stood, `K.PY_ROCK_FRACTION` per rock gone, the core's bar
		-- published every frame and its disappearance taken as the colossus's
		-- death, with `Fn.pyreliskVentHazard` ticked alongside because the deck
		-- was not safe ground either. All of it is cut with the climb. The
		-- arms' reconciliation above is the only chip path left, and the second
		-- arm's death is the ending.)
		-- THE STONES REGROW ON A CLOCK. Here rather than in the stance branch
		-- below, because that one fires on a health threshold and this has to
		-- run whether or not the fight is making progress - which is the
		-- entire point: three baits cannot produce a stance's worth of damage,
		-- so a party that misread them used to have no way back into the fight
		-- at all. The stance-change restore is kept on top of it.
		Fn.regrowStones(creature, def, now)
		-- Stance follows the health phase: each one it loses costs it ground.
		local stance = (def.stances or 1) - (bossPhaseIndex(def, creature.health / creature.maxHealth) - 1)
		stance = math.max(stance, 1)
		-- `~=` alone never fires on the first pass (both start at MAX_COIL),
		-- so anything reading Stance saw nil for the fight's first third.
		if model:GetAttribute(ATTR.STANCE) == nil or state.coil ~= stance then
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
			model:SetAttribute(ATTR.STANCE, stance)
			Fn.restoreStones(creature, def)
			-- A new stance is a new hand: the once-per-stance moves (`once`
			-- in Fn.pickBossAttack) are offered again. Cleared even on the first
			-- pass, which is harmless - there is nothing in it yet.
			creature.stanceUsed = nil
			if announce then
				fireEvent("bossStance", creature.pos, { name = def.name, stance = stance })
			end
		end

		if creature.mode == "stagger" then
			-- ACT 2 RUNS INSIDE THIS BRANCH, for up to 120 seconds, and it
			-- takes it over: `mode == "stagger"` means `untargetable` is false
			-- and `Exposed` is stamped, which is exactly the state act 2 wants,
			-- but the shipped shaping below is written for a 20-second window
			-- and would spend twenty seconds easing into the slump.
			--
			-- TWO EXITS, AND BOTH ARE REAL. The arms dying is the act break;
			-- the window expiring with them still standing is the failure
			-- branch, which is not a reset (see `Fn.pyreliskArmsFailed`).
			if creature.pyreliskArmsOut and (creature.pyreliskAct or 0) == 2 then
				if (creature.partsAlive or 0) <= 0 then
					Fn.pyreliskArmsDone(creature, def, now)
					return
				end
				if now >= (creature.exposedUntil or now) then
					Fn.pyreliskArmsFailed(creature, def, now)
					return
				end
				Fn.pyreliskArmBars(creature)
				state.slump = math.clamp((now - (creature.modeStart or now)) / K.PY_ARM_SLUMP_EASE, 0, 1)
				Fn.placeColossus(creature, def, now, root)
				return
			end
			-- The punish window: it is down, open, and taking hits. The head
			-- eases to the sand and back so the window has a shape.
			local u = modeProgress(creature, now)
			state.slump = math.clamp(math.min(u * 6, 1) - math.max(u - 0.82, 0) / 0.18, 0, 1)
			Fn.placeColossus(creature, def, now, root)
			if u >= 1 then
				state.slump = 0
				creature.untargetable = def.chip == nil -- see the rise's note
				creature.model:SetAttribute(ATTR.EXPOSED, nil)
				creature.nextAttackAt = now + 0.6
				setMode(creature, "entrenched", 0, now)
			end
			return
		end

		if creature.mode == "attack" then
			Fn.updateBossAttack(creature, def, now, dt, root, player, dist, sub)
			Fn.placeColossus(creature, def, now, root)
			return
		end

		-- Entrenched: hold the perch, watch, and pick the next pattern. The
		-- tail eases back onto the tower between attacks.
		state.unwind = math.max((state.unwind or 0) - dt * 1.8, 0)
		Fn.placeColossus(creature, def, now, root)
		-- THE ONE REACTIVE MOVE IN THE PROJECT (contract REVISION 2 §8). Every
		-- other attack in every book is drawn from a phase list on a cooldown;
		-- `bite` is not in any list and is fired from HERE, by standing still
		-- in the wrong place.
		--
		-- WHY THE DWELL TIMER IS NOT A DISTANCE CHECK. Firing on proximity
		-- alone would snap at anybody who ran through the tower's foot on the
		-- way to a punish window - which is most of the fight's good play. Two
		-- seconds inside 14 studs is PARKING, and parking is the thing the move
		-- exists to answer: it is the ground the whip cannot reach (SWEEP_INNER
		-- 13), the ring launches outside (10), the masonry's sector starts past
		-- (12) and the bell's rings are nil under (4).
		--
		-- MEASURED FROM THE TOWER'S FOOT, not from `dist`: `dist` is to
		-- `creature.pos`, which is the head sixty studs up the lighthouse, so
		-- it would never fall under 14 no matter where anyone stood. This is
		-- the flat radius the rest of the fight's geometry is expressed in.
		--
		-- Gated on the row carrying the move, so the branch is inert for any
		-- other entrenched boss that shares this code.
		local biteRow = def.attacks and def.attacks.bite
		if biteRow and root then
			local near = Fn.brineRadiusOf(state, root.Position) <= (biteRow.reach or 14)
			creature.biteDwellSince = if near then (creature.biteDwellSince or now) else nil
			local ready = now >= (creature.cooldowns and creature.cooldowns.bite or 0)
			if creature.biteDwellSince and now - creature.biteDwellSince >= (biteRow.dwell or 2.0) and ready then
				-- Cleared BEFORE the attack begins, so a camper who never moves
				-- re-earns the full dwell after each snap instead of triggering
				-- again the frame the cooldown expires.
				creature.biteDwellSince = nil
				Fn.beginBossAttack(creature, def, "bite", now)
				return
			end
		end
		if root and now >= creature.nextAttackAt and dist <= def.aggro then
			Fn.beginBossAttack(creature, def, Fn.pickBossAttack(creature, def, now), now)
		end
		return
	end

	-- The ring regrows: `parts.regrow` seconds after the last tentacle falls
	-- (the head's exposure window), the arms come back - as long as the boss
	-- still lives. Checked in every mode so an attack can't stall the clock.
	-- `regrow` MAY BE ABSENT, AND ITS ABSENCE MEANS NEVER.
	--
	-- The guard read `now - partsDownAt >= def.parts.regrow` with nothing
	-- checking that the field exists - which was true of every parts boss when
	-- it was written and has not been since. A ring whose `regrow` is DELETED
	-- is now the idiom for an ACT BREAK (`admiral_wrack`'s four gun decks, and
	-- the Pyrelisk's two arms): nothing resets the count, so the last kill
	-- opens the next act forever.
	--
	-- Without the nil check that is not a ring which fails to regrow, it is a
	-- comparison against nil - an ERROR out of the boss's own update, every
	-- frame, from the moment the last part falls. The Pyrelisk never reached it
	-- (its entrenched branch returns unconditionally further up), which is
	-- exactly why this sat here unnoticed: the boss that has the deleted
	-- `regrow` AND passes through this line is the Admiral.
	--
	-- nil is "never", not "immediately", so the test is `and def.parts.regrow`
	-- rather than `or math.huge` - same behaviour, and it reads as the
	-- statement it is.
	if
		def.parts
		and def.parts.regrow
		and creature.partsAlive == 0
		and creature.partsDownAt
		and now - creature.partsDownAt >= def.parts.regrow
	then
		Fn.spawnBossParts(creature, def)
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
		creature.model:SetAttribute(ATTR.EXPOSED, nil)
		fireEvent("regrow", creature.anchor or creature.pos, { count = def.parts.count, name = def.name })
	end

	if creature.mode == "attack" then
		Fn.updateBossAttack(creature, def, now, dt, root, player, dist, sub)
		if def.pose then
			Fn.placeColossus(creature, def, now, root)
		end
		return
	end

	-- A POSED boss that is not entrenched (the Kraken): it holds the middle
	-- of its arena instead of swimming at you. Its head IS the arena centre -
	-- 28 studs of it - so closing to `standoff` would shove the thing you are
	-- standing on. It turns to face, and its arms do the travelling.
	if def.pose then
		Fn.hideColossusModel(creature)
		local state = Fn.colossusState(creature, def)
		state.rise = math.min((state.rise or 0) + dt * 0.5, 1)
		creature.pos = creature.anchor or creature.pos
		Fn.placeColossus(creature, def, now, root)
		if root and now >= creature.nextAttackAt and dist <= def.aggro then
			Fn.beginBossAttack(creature, def, Fn.pickBossAttack(creature, def, now), now)
		end
		return
	end

	-- Prowl: turn to face, close in, breathe.
	if root then
		creature.yaw0 = approachAngle(creature.yaw0, yawToward(root.Position - creature.pos), def.turnRate * dt)
		if dist > def.standoff then
			creature.pos = Fn.resolveHorizontal(creature, flatUnit(root.Position - creature.pos) * def.speed * dt)
		end
	end
	Fn.clampToArena(creature, def)
	local breathe = math.sin(now * 1.6) * 0.25
	model:PivotTo(
		poseCFrame(creature, sub + breathe, math.sin(now * 0.9) * math.rad(3), math.sin(now * 1.6 + 1) * math.rad(2))
	)

	if root and now >= creature.nextAttackAt and dist <= def.aggro then
		Fn.beginBossAttack(creature, def, Fn.pickBossAttack(creature, def, now), now)
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
function Fn.updateCrust(creature, now: number, dt: number)
	if creature.crustOpenUntil and now >= creature.crustOpenUntil then
		creature.crustOpenUntil = nil
		creature.model:SetAttribute(ATTR.CRACKED, false)
	end
	Fn.updateShambler(creature, now, dt)
end

-- Ashfeather Phoenix: charges like the skipper, except while it's down. Being
-- down is a real pause - untargetable, motionless, no contact damage - so the
-- rise reads as a second fight starting rather than a hiccup in the first.
function Fn.updateReborn(creature, now: number, dt: number)
	if creature.downUntil then
		if now < creature.downUntil then
			creature.model:PivotTo(poseCFrame(creature, 0, 0, 0))
			return
		end
		creature.downUntil = nil
		creature.untargetable = false
		creature.health = math.max(1, math.floor(creature.maxHealth * C.REBORN_FRACTION + 0.5))
		creature.lastFoughtAt = now -- coming back doesn't count as being left alone
		creature.model:SetAttribute(ATTR.HEALTH, creature.health)
		creature.model:SetAttribute(ATTR.DOWNED, false)
		fireEvent("rebornRise", creature.pos, {})
	end
	Fn.updateCharger(creature, now, dt)
end

-- Cinder Djinn: shambles, shedding burning smoke as it goes. The puffs are
-- static once dropped and burn on their own clocks (ticked in update()), so the
-- danger is the ground it HAS covered - following it through its own trail is
-- the mistake the fight is built around.
function Fn.updateGasCloud(creature, now: number, dt: number)
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
	Fn.updateShambler(creature, now, dt)
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
function Fn.updateMagnetize(creature, now: number, dt: number)
	if now >= (creature.nextPullAt or 0) then
		creature.nextPullAt = now + C.MAG_INTERVAL
		local root, _player, dist = Fn.nearestPlayerRoot(creature.pos)
		if root and dist <= C.MAG_RANGE then
			fireEvent("pull", creature.pos, {
				radius = C.MAG_RANGE,
				strength = C.MAG_STRENGTH,
				duration = C.MAG_DURATION,
			})
		end
	end
	Fn.updateCharger(creature, now, dt)
end

-- ============================================================ tentacle archetype (the finale)
-- A Kraken arm: PLANTED where Fn.spawnBossParts put it - it never walks, never
-- takes knockback or launch (both multipliers 0), and never lingers
-- (noLinger rides its spawn). It sways, faces the nearest player, and slams
-- a telegraphed ring around itself on a cooldown; the counterplay is that
-- killing the whole ring is what exposes the head. Reuses the boss slam's
-- telegraph + slam events, so every client tell already exists.
function Fn.updateTentacle(creature, now: number, dt: number)
	local root, _player, dist = Fn.nearestPlayerRoot(creature.pos)
	if root then
		creature.yaw0 = approachAngle(creature.yaw0, yawToward(root.Position - creature.pos), math.rad(110) * dt)
	end
	-- A slam its owner ordered (Fn.commandArm): the boss's clock, the boss's
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
			-- K.BOSS_HEIGHT_TOLERANCE, like every other AoE in the boss kit,
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
				K.BOSS_HEIGHT_TOLERANCE
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
		-- see K.SLAM_ORDER_GRACE. An arm busy when the beat came round arrives
		-- here late and finds nothing to obey, which is the intended outcome.
		if creature.slamAt and now > creature.slamAt + K.SLAM_ORDER_GRACE then
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
function Fn.nearestHostile(pos: Vector3, radius: number)
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

function Fn.updateCompanion(creature, now: number, dt: number)
	Fn.slideKnockback(creature, dt)
	creature.lastBiteAt = creature.lastBiteAt or 0

	-- It swims rather than flops: a quick steady bob, never the fish's
	-- landed-and-dying thrash.
	local bob = math.abs(math.sin(now * B.HATCHLING_HOP_RATE)) * B.HATCHLING_HOP

	local target, dist = Fn.nearestHostile(creature.pos, B.HATCHLING_SEEK)
	if target then
		local delta = target.pos - creature.pos
		creature.yaw0 = approachAngle(creature.yaw0, yawToward(delta), C.RUSH_TURN_RATE * dt)
		if dist > B.HATCHLING_BITE_RANGE then
			creature.pos = Fn.resolveHorizontal(creature, flatUnit(delta) * B.HATCHLING_SPEED * dt)
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
			creature.pos = Fn.resolveHorizontal(creature, flatUnit(delta) * B.HATCHLING_FOLLOW_SPEED * dt)
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
	creature.pos = Fn.resolveHorizontal(creature, dir * C.FLY_SPEED * dt)
end

-- The flyer's whole machine, WITHOUT the knockback slide (the registry
-- wrappers below own that), so the skythief can delegate its shared modes
-- here without sliding twice in one frame.
function Fn.updateFlyerCore(creature, now: number, dt: number)
	local model = creature.model
	if not creature.mode then
		creature.flyHeight = 0
		setMode(creature, "climb", 0, now)
	end
	local root, _player, dist = Fn.nearestPlayerRoot(creature.pos)

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
				-- Still airborne: the obstacle ray in Fn.resolveHorizontal runs at
				-- the GROUND-clamped pos, so a rock the bird is flying OVER
				-- would stop the dive short of the telegraphed ring (review
				-- find, 2026-08-25). Clear of the ground, it only re-grounds.
				creature.pos = groundedPos(creature.pos + step, creature.halfThickness)
			else
				-- The final approach happens at head height; scenery counts.
				creature.pos = Fn.resolveHorizontal(creature, step)
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
			model:SetAttribute(ATTR.FLOPS, (model:GetAttribute(ATTR.FLOPS) or 0) + 1)
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

function Fn.updateFlyer(creature, now: number, dt: number)
	Fn.slideKnockback(creature, dt)
	Fn.updateFlyerCore(creature, now, dt)
end

-- The nearest resting PASSIVE catch worth stealing: alive, targetable, on the
-- ground, nobody's companion, not already in someone's claws, and a flopper -
-- the skythief takes your loot, not your fight.
function Fn.nearestStealable(pos: Vector3, radius: number)
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
function Fn.updateSkythief(creature, now: number, dt: number)
	Fn.slideKnockback(creature, dt)
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
		creature.pos = Fn.resolveHorizontal(creature, flatUnit(to) * C.SKYTHIEF_SWOOP_SPEED * dt)
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
		local root = Fn.nearestPlayerRoot(creature.pos)
		local away = if root
			then flatUnit(creature.pos - root.Position)
			else Vector3.new(math.cos(creature.yaw0), 0, -math.sin(creature.yaw0))
		creature.yaw0 = approachAngle(creature.yaw0, yawToward(away), C.FLY_TURN_RATE * dt)
		local step = away * C.SKYTHIEF_FLEE_SPEED * dt
		local before = creature.pos
		creature.pos = Fn.resolveHorizontal(creature, step)
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
			local victim = Fn.nearestStealable(creature.pos, C.SKYTHIEF_SEEK)
			if victim then
				creature.stealTarget = victim
				setMode(creature, "swoop", 0, now)
				return
			end
		end
		Fn.updateFlyerCore(creature, now, dt)
	else
		Fn.updateFlyerCore(creature, now, dt)
	end
end

ARCHETYPE_UPDATERS = {
	-- Rimefang publishes its body as pose attributes, and has to do it AFTER
	-- the shared boss frame whatever branch that frame took - rising, an
	-- attack, the beached window, prowling. Every other boss is byte-identical
	-- to before: Fn.rimefangDrive returns on its first line unless the row is
	-- Rimefang's.
	boss = function(creature, now: number, dt: number)
		Fn.updateBoss(creature, now, dt)
		Fn.rimefangDrive(creature, now, dt)
	end,
	companion = Fn.updateCompanion,
	flyer = Fn.updateFlyer,
	skythief = Fn.updateSkythief,
	rusher = Fn.updateRusher,
	shambler = Fn.updateShambler,
	charger = Fn.updateCharger,
	spitter = Fn.updateSpitter,
	bloater = Fn.updateBloater,
	drifter = Fn.updateDrifter,
	burrower = Fn.updateBurrower,
	mimic = Fn.updateMimic,
	thief = Fn.updateThief,
	pulser = Fn.updatePulser,
	-- Volcano. `splitter` and `thornback` have no updater of their own: an ooze
	-- rushes and divides in kill(), a shardback rushes and reflects in
	-- hitModifiers, so both keep the rusher loop their rows already name.
	crust = Fn.updateCrust,
	reborn = Fn.updateReborn,
	gascloud = Fn.updateGasCloud,
	magnetize = Fn.updateMagnetize,
	splitter = Fn.updateRusher,
	thornback = Fn.updateRusher,
	-- The finale: a Kraken arm, planted by the boss's parts ring.
	tentacle = Fn.updateTentacle,
	-- A Lantern Stalk, planted by Noctyss's. It has no updater of its own on
	-- purpose: the boss's pose driver puts every stalk where it belongs
	-- (Fn.updateChoir) and her attack book is the only thing that makes one do
	-- anything. Without this row the generic flop would send a 35-stud
	-- lantern hopping across the arena floor.
	choirstalk = function() end,
	-- The Kraken's two arms and its six gullet polyps, and both are no-ops for
	-- the `choirstalk` reason exactly: the boss's own fight tick
	-- (Fn.updateKrakenFight) puts every one of them where it belongs, and its
	-- attack book is the only thing that makes one do anything. Without these
	-- rows the generic flop would send a limb the size of a building hopping
	-- across the deck - and, worse, would move the hitbox out from under the
	-- chain the client is drawing to it.
	--
	-- NOT `tentacle`, which is the other thing they could plausibly have been:
	-- that archetype is an autonomous slam machine with its own aggro range and
	-- its own cooldown, and an arm that also attacked on its own initiative
	-- would put untelegraphed damage on a deck whose entire counterplay is
	-- reading telegraphs.
	krakenarm = function() end,
	krakenpolyp = function() end,
	-- The Pyrelisk's two fallen arms, and this one is NOT a no-op - it is the
	-- only pressure in act 2. See `Fn.updatePyreliskArm`: an arm bleeds a lava
	-- pool onto the rim path near itself on a clock, so the ground the party
	-- has to stand on to hit it shrinks while they do. 120 seconds with a
	-- silent boss and inert arms is a damage check, not an act.
	pyreliskarm = Fn.updatePyreliskArm,
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
		-- Fn.updateBoss refreshes lastFoughtAt every frame, so it would run
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
			Fn.landSpit(creature) -- the cod's glob lands on its own clock
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
					-- (Fn.scatterAround runs its point through groundedPos), and
					-- when the scatter falls off a rock cap into open water
					-- that ground is the waterline while the target is still
					-- up on the cap: 7-9 studs, which the default gate throws
					-- away. The rest of the boss kit already answers this with
					-- K.BOSS_HEIGHT_TOLERANCE; a glob simply had no way to say
					-- so. See K.ATTACK_HANDLERS.undertow, the one caller today.
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
					pool.nextTickAt = now + K.BOSS_POOL_TICK
					if pool.min then
						damagePlayersInRadius(
							pool.pos,
							pool.radius,
							pool.min,
							pool.max,
							creature,
							0.4,
							K.BOSS_HEIGHT_TOLERANCE
						)
					end
					if pool.slow then
						fireEvent("chill", pool.pos, {
							radius = pool.radius,
							mult = pool.slow,
							duration = K.BOSS_POOL_TICK * 1.7,
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
						Fn.damagePlayersInAnnulus(s.pos, s.inner, s.outer, s.min, s.max, creature)
					elseif s.min then
						damagePlayersInRadius(s.pos, s.radius, s.min, s.max, creature, 0.5, K.BOSS_HEIGHT_TOLERANCE)
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
				local root, _, dist = Fn.nearestPlayerRoot(lure.pos)
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
						K.BOSS_HEIGHT_TOLERANCE
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
		-- Admiral Wrack's two mechanics that OUTLIVE the attack that made them:
		-- a powder runner burns an eight-second fuse and a boarding party
		-- marches for eleven, both longer than any windup->recover the phase
		-- machine holds open, so neither can be stepped from its own handler.
		-- Same shape as the three timed systems above it - a list on the record,
		-- walked here, dropped when it empties.
		if creature.wrackKit then
			Fn.wrackKitStep(creature, now, dt)
		end
		-- ...and the ACT CLOCK, which is not a kit and runs whether or not one
		-- exists: it is what turns "four cannons died" and "the hull is at 40%"
		-- into the single dial the phase table is cut against, and it owns act
		-- two's earned window. Guarded on `succeededBy` rather than on a boss
		-- id, so it is the multi-act SHAPE that opts a fight in, not a name.
		if creature.row.boss and not creature.dead then
			local actDef = Bosses.items[creature.row.boss]
			if actDef and actDef.succeededBy then
				Fn.wrackActStep(creature, actDef, now)
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
			-- Fn.spawnBossParts, which only runs behind bossDef(), which needs
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
				creature.model:SetAttribute(ATTR.FLOPS, (creature.model:GetAttribute(ATTR.FLOPS) or 0) + 1)
			else
				creature.lastFoughtAt = now
				creature.pos = carrier.pos
				local hang = math.max(0.5, (carrier.flyHeight or 0) - C.SKYTHIEF_CARRY_DROP)
				creature.model:PivotTo(poseCFrame(creature, hang, 0, 0))
			end
		elseif isAirborne(creature) then
			-- Juggled: hanging in the air from a hit. Suspends whatever the
			-- archetype would be doing until it lands.
			Fn.updateAirborne(creature, dt)
		elseif creature.stunnedUntil and now < creature.stunnedUntil then
			-- Dazed by a stun bait: the archetype loop is suspended, so even a
			-- hostile just flops there and takes free hits. Same pre-emption
			-- as the juggle above, and it still slides from knockback so it
			-- doesn't feel like a rock.
			if not creature.stunShown then
				creature.stunShown = true
				creature.model:SetAttribute(ATTR.STUNNED, true)
				-- Same interrupt rule as the juggle: the stun eats the move.
				creature.attack = nil
			end
			Fn.slideKnockback(creature, dt)
			local hop, yaw, pitch = flop(creature, now)
			creature.model:PivotTo(poseCFrame(creature, hop, yaw, pitch))
		else
			if creature.stunShown then
				-- Just came round: drop the flag so the client can stop
				-- drawing the daze.
				creature.stunShown = nil
				creature.stunnedUntil = nil
				creature.model:SetAttribute(ATTR.STUNNED, false)
			end
			-- A row with `moves` fights on the kit engine; the archetype
			-- string then only names its between-moves locomotion.
			local updater = if creature.row.moves then Fn.updateKitted else ARCHETYPE_UPDATERS[creature.row.archetype]
			if updater then
				-- A hostile: its own state machine owns the knockback slide,
				-- flop and pivot for this frame.
				updater(creature, now, dt)
			else
				-- The passive catch ("flopper"): knockback slide, then flop in
				-- place. The pose is heading + swish about world up, then a
				-- little nose pitch, then the flat-lay orientation - no roll,
				-- so it can't flip over.
				Fn.slideKnockback(creature, dt)
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
