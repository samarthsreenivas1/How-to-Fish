--!nonstrict
-- FloeService.luau
-- THE BREAKING FLOE: the state of the ice Rimefang's fight is played on.
--
-- The v3 arena floor is not one mesh, it is 43 irregular shards
-- (`RimefangArena_Shard01..43`, the graph in Shared/Config/RimefangFloe) over a
-- dark water plate (`RimefangArena_Water`) with a pre-cut breathing hole in the
-- middle. Every shard is in one of four states:
--
--   solid      - walkable, collidable, where it was authored.
--   cracking   - telegraphed: it is GOING to open, in `seconds`. Still walkable.
--   open       - sunk three studs, collision off: open water. Standing in it
--                builds the Frozen meter.
--   refreezing - frost creeping back in, and walkable from its first frame:
--                the ice is there, its surface is just still knitting.
--
-- WHY A SERVICE AND NOT THE FIGHT. Three different owners need the same
-- answers: the attack handlers (CreatureService) open lines and rings and ask
-- "where is there still ice near this player"; the cast windows ask "is this
-- player standing on ice"; and the Frozen meter ticks whether or not an attack
-- is running. One table, one tick, one replication channel - and the whole of
-- it dies quietly on an arena whose shard parts are not there (the procedural
-- fallback), which is what `bound` below is for.
--
-- WHAT REPLICATES, AND HOW. The shard PARTS replicate themselves: the server
-- owns their CFrame, CanCollide and Transparency, so a sunk shard is sunk on
-- every client and the Undertow drift is the engine's own property replication
-- rather than a message anyone has to interpolate. Everything that is NOT a
-- property of a part - the crack seam, the frost creep, the refreeze glow, the
-- slick shimmer, the Frozen vignette, the rod-window banners - goes out on the
-- one `FloeEvent` remote as { kind, ids, seconds, ... } and is drawn by
-- FloeController. The server never draws, the client never decides.
--
-- SUNK SHARDS COME BACK ON THEIR OWN (user's rule): 20 seconds for most of the
-- fight's moves, 60 for act three's ring collapses, 8 for the checkerboard.
-- Nothing has to remember to close a hole, which is what keeps a long fight
-- from ending on a floe with no floor.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BossArenas = require(Shared.Config.BossArenas)
local RimefangFloe = require(Shared.Config.RimefangFloe)
local Remotes = require(Shared.Net.Remotes)

local FloeService = {}

-- WHICH ARENA THIS IS. One island, one arena model, one floe; the service is
-- inert everywhere else in the game.
local ISLAND = "ice"
local WATER_OBJECT = "RimefangArena_Water"

-- ------------------------------------------------------------------ numbers

-- How long an opened shard stays open, by the move that opened it. The plain
-- one is the fight's default; the ring collapse's is long because act three's
-- job is to SHRINK the arena, and the checkerboard's is short because its job
-- is to move everybody at once and then give the floor back.
FloeService.REFREEZE = 20
FloeService.RING_REFREEZE = 60
FloeService.CHECKER_REFREEZE = 8
-- The frost creeping in. The shard carries the player again for all three
-- seconds of it - a hole that closes is a gift, not a second trap - so this
-- number is purely how long the floe looks half-healed.
FloeService.REFREEZING = 3
-- The open itself: three studs down, over this long, and the collision goes
-- on the FIRST frame of it (the floor is gone the moment the shard lets go -
-- a 0.6 s grace would be a hole you can stand on).
local SINK_TIME = 0.6
local SINK_DROP = 3
-- How transparent a fully sunk shard is. Not invisible: it is ice under dark
-- water, and a player has to be able to see where the floor will come back.
local SINK_FADE = 0.65

-- The Frozen meter, as fractions per second. Gained in the water, lost on the
-- ice, and the asymmetry is the mechanic: 2.5 s in the water to freeze solid
-- and 4 s on the ice to shed it, so swimming the arena is never a route.
local FROZEN_GAIN = 0.40
local FROZEN_DECAY = 0.25
-- What 100% costs: immobilised, then thrown out onto the nearest ice.
local FROZEN_HOLD = 3
-- How often the meters tick. Fast enough that the client's bar moves, slow
-- enough that a raycast per player per tick is nothing.
local FROZEN_TICK = 0.1

-- How long a refrozen-by-her shard stays slick (the Refreeze heal's payload).
local SLICK_TIME = 20

-- "A solid neighbour within 12 studs", the checkerboard's guarantee. Measured
-- as part BOUNDS near the player rather than centre-to-centre: the shards are
-- 200-1650 square studs, so a centre is tens of studs away from an edge the
-- player can step onto.
local SAFE_REACH = 12

-- How close a rod cast has to be to the thing it is aimed at.
local CAST_REACH = 40

-- ------------------------------------------------------------------- state

-- The placed arena model and its shard parts, found once in `start`. `bound`
-- is the whole of this service's tolerance for the procedural fallback arena:
-- false means there are no shard parts, every entry point below returns
-- immediately, and exactly one warn was printed.
local bound = false
local warned = false
local arenaModel: Instance? = nil
local waterPart: BasePart? = nil

-- id -> { part, base (CFrame), state, untilAt, sink, sinkTo, slickUntil }
local shards: { [number]: any } = {}
local partToId: { [BasePart]: number } = {}
-- Every shard part, for the overlap/ray filters. Rebuilt only in `bind`.
local shardParts: { BasePart } = {}

-- The drift (Undertow): { dir, studs, seconds, startedAt } or nil.
local drift = nil

-- player -> frozen fraction 0..1; player -> os.clock() they are released at.
local frozen: { [Player]: number } = {}
local heldUntil: { [Player]: number } = {}

-- The rod window: { kind = "blowhole" | "shoal", at = Vector3, radius, expiresAt }
local window = nil
-- Players with a boss cast already in flight this window, so one player cannot
-- open two.
local casting: { [Player]: boolean } = {}

-- What the FIGHT wants to happen when a boss cast resolves. Registered by
-- CreatureService (`FloeService.setHooks`), because the effects of a won cast -
-- drag her onto the ice, beach her, heal her, send her after the bait - are all
-- statements about the creature, and this service must never require the one
-- that owns creatures. Absent hooks are a no-op, not an error: the windows
-- still open and close, they just do nothing to her.
local hooks = {}

local accumulated = 0

-- ------------------------------------------------------------------ binding

local function arenaCentre(): Vector3
	local arena = BossArenas.items[ISLAND]
	return (arena and arena.center) or Vector3.zero
end

-- Find the placed arena and every shard under it. BossArenaService clones the
-- authored template into Workspace/BossArenas keeping the template's own name
-- (`arena.model`, which `armCaldera` asserts), and the shards are MeshParts
-- somewhere under it - so the lookup is the model by name and then the shard by
-- RimefangFloe.objectName, recursively. ONE warn if the shards are not there:
-- that is the procedural stand-in arena, which has a floor and no floe, and a
-- fight on it simply plays without the ice mechanics.
local function bind(): boolean
	if bound then
		return true
	end
	local folder = Workspace:FindFirstChild("BossArenas")
	local arena = BossArenas.items[ISLAND]
	local model = folder and arena and folder:FindFirstChild(arena.model)
	local first = model and model:FindFirstChild(RimefangFloe.objectName(1), true)
	if not model or not first then
		if not warned then
			warned = true
			warn(
				"[Floe] no RimefangArena shard parts in Workspace/BossArenas - the ice mechanics are"
					.. " inert on this arena (the procedural fallback has a floor, not a floe)"
			)
		end
		return false
	end

	arenaModel = model
	for id = 1, RimefangFloe.count do
		local part = model:FindFirstChild(RimefangFloe.objectName(id), true)
		if part and part:IsA("BasePart") then
			shards[id] = {
				part = part,
				base = part.CFrame,
				state = "solid",
				untilAt = 0,
				sink = 0,
				sinkTo = 0,
				slickUntil = 0,
			}
			partToId[part] = id
			table.insert(shardParts, part)
		end
	end
	local water = model:FindFirstChild(WATER_OBJECT, true)
	waterPart = if water and water:IsA("BasePart") then water else nil
	bound = true
	return true
end

FloeService.ready = function(): boolean
	return bound
end

-- ------------------------------------------------------------- replication

local function fire(payload)
	Remotes.FloeEvent:FireAllClients(payload)
end

-- ------------------------------------------------------------------ queries

FloeService.centre = arenaCentre

-- The breathing hole, in world space. Its X/Z are the arena's centre (no shard
-- covers it) and its Y is the floe's own top, which is read off a real shard
-- rather than computed from the arena row's `meshBottom` - the parts are where
-- the floor actually is, and a derived height is a second answer that can drift
-- from the first.
function FloeService.holeCentre(): Vector3
	local centre = arenaCentre()
	local y = centre.Y
	local shard = shards[1]
	if shard then
		y = shard.base.Position.Y + shard.part.Size.Y * 0.5
	end
	return Vector3.new(centre.X + RimefangFloe.hole.centre.X, y, centre.Z + RimefangFloe.hole.centre.Z)
end

function FloeService.holeRadius(): number
	return RimefangFloe.hole.radius
end

-- A shard's centre in world space, off the part's authored rest position (so a
-- sunk or drifting shard still answers with the place its floor belongs).
function FloeService.shardCentre(id: number): Vector3?
	local shard = shards[id]
	if not shard then
		return nil
	end
	local at = shard.base.Position
	return Vector3.new(at.X, at.Y + shard.part.Size.Y * 0.5, at.Z)
end

function FloeService.stateOf(id: number): string?
	local shard = shards[id]
	return shard and shard.state
end

-- Walkable right now? `cracking` is: the whole point of a telegraph is that
-- the floor is still there while it runs.
local function isFloor(shard): boolean
	return shard.state == "solid" or shard.state == "cracking" or shard.state == "refreezing"
end

function FloeService.openCount(): number
	local n = 0
	for _, shard in shards do
		if shard.state == "open" or shard.state == "cracking" then
			n += 1
		end
	end
	return n
end

-- HOW MANY MORE SHARDS MAY BE OPENED, for a cap stated as a fraction of the
-- floe (act two 0.40, act three 0.60). Every picker goes through this, and a
-- negative budget reads as zero - a fight that is already over its cap opens
-- nothing rather than going further over it.
function FloeService.budget(fraction: number): number
	return math.max(math.floor(RimefangFloe.count * fraction) - FloeService.openCount(), 0)
end

local function overlapParams(): OverlapParams
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = shardParts
	return params
end

-- Every shard whose BOUNDS come within `radius` of a point, as ids. The
-- cheapest honest answer to "what ice is within reach of this player": the
-- shard centres are tens of studs from their own edges, so a centre test would
-- call a player standing at a shard's edge 30 studs from the floor under them.
function FloeService.shardsNear(at: Vector3, radius: number): { number }
	local out = {}
	if not bound then
		return out
	end
	for _, part in Workspace:GetPartBoundsInRadius(at, radius, overlapParams()) do
		local id = partToId[part]
		if id then
			table.insert(out, id)
		end
	end
	return out
end

-- Is there still somewhere to stand within `SAFE_REACH` of this point? Takes
-- an optional set of ids to treat as ALREADY GONE, which is what lets the
-- checkerboard test a pick before it commits to it.
function FloeService.solidNear(at: Vector3, doomed: { [number]: boolean }?): boolean
	for _, id in FloeService.shardsNear(at, SAFE_REACH) do
		local shard = shards[id]
		if shard and isFloor(shard) and not (doomed and doomed[id]) then
			return true
		end
	end
	return false
end

-- The shard a player is standing on, by raycast at the real geometry (which is
-- what the module's header says a point-in-shard test is: a polygon copy can go
-- stale, a ray cannot). nil means they are over the water plate, over the hole,
-- or not on the floe at all.
function FloeService.shardUnder(player: Player): (number?, BasePart?)
	if not bound then
		return nil, nil
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil, nil
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { arenaModel }
	local hit = Workspace:Raycast(root.Position + Vector3.new(0, 2, 0), Vector3.new(0, -12, 0), params)
	local part = hit and hit.Instance
	if not part then
		return nil, nil
	end
	return partToId[part], part
end

-- IS THIS PLAYER ON ICE? The Frozen meter's only question, and it is asked of
-- every player in the arena every tick. False for a player over an open shard,
-- over the breathing hole, or over the water plate; true for anyone outside the
-- arena entirely, because the meter is the FIGHT's pressure and the dock is not
-- part of it.
function FloeService.isPlayerOnIce(player: Player): boolean
	if not bound then
		return true
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return true
	end
	local arena = BossArenas.items[ISLAND]
	local centre = arenaCentre()
	local flat = Vector3.new(root.Position.X - centre.X, 0, root.Position.Z - centre.Z)
	if flat.Magnitude > ((arena and arena.floorRadius) or 120) + 10 then
		return true
	end
	local id = FloeService.shardUnder(player)
	if not id then
		return false
	end
	local shard = shards[id]
	return shard ~= nil and isFloor(shard)
end

-- The nearest shard that is floor right now, for the Frozen meter's ejection
-- and for anything that has to put a player back on the ice.
function FloeService.nearestSolidCentre(at: Vector3): Vector3?
	local best, bestD = nil, math.huge
	for id, shard in shards do
		if isFloor(shard) then
			local centre = FloeService.shardCentre(id)
			if centre then
				local d = (Vector3.new(centre.X - at.X, 0, centre.Z - at.Z)).Magnitude
				if d < bestD then
					best, bestD = centre, d
				end
			end
		end
	end
	return best
end

-- ------------------------------------------------------------- transitions

-- The one place a shard changes state, so every transition fires its event and
-- nothing can change a state without saying so.
local function setState(ids: { number }, state: string, seconds: number)
	local changed = {}
	for _, id in ids do
		local shard = shards[id]
		if shard and shard.state ~= state then
			shard.state = state
			shard.untilAt = os.clock() + seconds
			if state == "open" then
				-- The floor is gone on THIS frame; the three studs of sinking
				-- are the look of it, not the timing of it.
				shard.sinkTo = 1
				shard.part.CanCollide = false
			elseif state == "solid" or state == "refreezing" then
				-- `refreezing` is walkable from its first frame, deliberately:
				-- the shard is back, its surface is just still knitting, and
				-- the frost creeping in is the client's draw of that. Only
				-- `cracking` leaves both fields alone - it has not moved.
				shard.sinkTo = 0
				shard.part.CanCollide = true
			end
			table.insert(changed, id)
		end
	end
	if #changed > 0 then
		fire({ kind = state, ids = changed, seconds = seconds })
	end
	return changed
end

-- OPEN, with its own refreeze clock. `seconds` is how long the water stays
-- water; the 3 s of `refreezing` after it is on top.
function FloeService.openShards(ids: { number }, seconds: number?)
	if not bound then
		return
	end
	setState(ids, "open", seconds or FloeService.REFREEZE)
end

function FloeService.openShard(id: number, seconds: number?)
	FloeService.openShards({ id }, seconds)
end

-- Back to ice NOW, whatever its clock said - the Refreeze heal's cancel, and
-- the only way a hole closes early.
function FloeService.refreezeNow(ids: { number })
	if not bound then
		return
	end
	setState(ids, "refreezing", FloeService.REFREEZING)
end

-- CRACK, THEN OPEN. The telegraph IS the attack: `seconds` of cracking (the
-- floor still there, the seam drawn, `rimeCrackWeb` at each shard on the
-- client) and then the open, with `openFor` seconds of water after it.
-- `thenFn` runs on the same frame the ice lets go, for a move that has more to
-- do at that moment.
function FloeService.crack(ids: { number }, seconds: number, openFor: number?, thenFn: (() -> ())?)
	if not bound or #ids == 0 then
		return
	end
	local marked = setState(ids, "cracking", seconds)
	if #marked == 0 then
		return
	end
	task.delay(seconds, function()
		local still = {}
		for _, id in marked do
			local shard = shards[id]
			-- Only shards STILL cracking on this clock: a shard the fight
			-- refroze or re-cracked in the meantime belongs to whatever did
			-- that, not to this call.
			if shard and shard.state == "cracking" then
				table.insert(still, id)
			end
		end
		FloeService.openShards(still, openFor)
		if thenFn then
			thenFn(still)
		end
	end)
end

-- SLICK ICE: the Refreeze heal's payload. The friction change is client-side
-- (a player's character is simulated on their own machine, so a server-side
-- physical property would be a suggestion), which is the same division the
-- pools' `slow` already uses.
function FloeService.slick(ids: { number }, seconds: number?)
	if not bound or #ids == 0 then
		return
	end
	local span = seconds or SLICK_TIME
	for _, id in ids do
		local shard = shards[id]
		if shard then
			shard.slickUntil = os.clock() + span
		end
	end
	fire({ kind = "slick", ids = ids, seconds = span })
end

-- ------------------------------------------------------------ the pickers

-- EVERY SHARD A STRAIGHT LINE CROSSES. The Fault Line's line runs through the
-- arena's centre (through the hole, which is the whole read: the seam comes out
-- of the water she is under) on the bearing of `toward`, and a shard counts as
-- crossed when the line passes within its own effective radius - sqrt(area/pi),
-- the honest size of an irregular shard, rather than a fixed width that would
-- miss the 1657-stud rim plates and swallow the 206-stud ones.
function FloeService.lineIds(toward: Vector3): { number }
	local out = {}
	if not bound then
		return out
	end
	local centre = arenaCentre()
	local dir = Vector3.new(toward.X - centre.X, 0, toward.Z - centre.Z)
	if dir.Magnitude < 1e-3 then
		dir = Vector3.new(1, 0, 0)
	end
	dir = dir.Unit
	for id, _ in shards do
		local at = RimefangFloe.shards[id]
		if at then
			local off = Vector3.new(at.centre.X, 0, at.centre.Z)
			local across = (off - dir * off:Dot(dir)).Magnitude
			if across <= math.sqrt(at.area / math.pi) then
				table.insert(out, id)
			end
		end
	end
	table.sort(out)
	return out
end

-- Which shards are in a ring, as the collapse walks it. Ring 0 touches the
-- hole, 3 touches the pressure ridge.
function FloeService.ringIds(index: number): { number }
	local out = {}
	for _, id in RimefangFloe.ring(index) do
		if shards[id] then
			table.insert(out, id)
		end
	end
	return out
end

local function shuffled(list: { number }): { number }
	local out = table.clone(list)
	for i = #out, 2, -1 do
		local j = math.random(i)
		out[i], out[j] = out[j], out[i]
	end
	return out
end

-- THE CHECKERBOARD'S PICK, and the guarantee it is built around: after it
-- lands, every living player in the arena still has floor within 12 studs.
--
-- Each player's reachable shards are resolved ONCE, up front, and a candidate
-- is only taken if it leaves every one of those sets with something in it. That
-- is why the pick is a loop with a test rather than "every other shard": the
-- parity of an irregular Voronoi fracture means nothing, and a player standing
-- on the one shard a parity rule would take has no answer at all.
function FloeService.checkerIds(fraction: number, cap: number?): { number }
	local out = {}
	if not bound then
		return out
	end
	local solids = {}
	for id, shard in shards do
		if shard.state == "solid" then
			table.insert(solids, id)
		end
	end
	-- Every player's own escape set, by bounds rather than by centres.
	local escapes = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid and humanoid.Health > 0 then
			local near = FloeService.shardsNear(root.Position, SAFE_REACH)
			local set = {}
			local any = false
			for _, id in near do
				local shard = shards[id]
				if shard and isFloor(shard) then
					set[id] = true
					any = true
				end
			end
			if any then
				table.insert(escapes, set)
			end
		end
	end

	local doomed = {}
	local want = math.floor(#solids * fraction + 0.5)
	if cap then
		want = math.min(want, cap)
	end
	for _, id in shuffled(solids) do
		if #out >= want then
			break
		end
		doomed[id] = true
		local ok = true
		for _, set in escapes do
			local left = false
			for other in set do
				if not doomed[other] then
					left = true
					break
				end
			end
			if not left then
				ok = false
				break
			end
		end
		if ok then
			table.insert(out, id)
		else
			doomed[id] = nil
		end
	end
	table.sort(out)
	return out
end

-- ------------------------------------------------------------------- drift

-- THE UNDERTOW. The whole sheet - every shard and the water under it - slides
-- `studs` along her circling direction and comes back, over `seconds`. It is a
-- property change on anchored parts, so it replicates itself; the event is only
-- so the client can put the groan and the vignette on it.
function FloeService.startDrift(dir: Vector3, seconds: number, studs: number)
	if not bound then
		return
	end
	local flat = Vector3.new(dir.X, 0, dir.Z)
	if flat.Magnitude < 1e-3 then
		flat = Vector3.new(1, 0, 0)
	end
	drift = { dir = flat.Unit, seconds = seconds, studs = studs, startedAt = os.clock() }
	fire({ kind = "drift", seconds = seconds, dir = drift.dir, studs = studs })
end

-- Where the sheet is, this frame: out on a half-sine and back, so it leaves
-- and returns at zero speed and the ground never jerks under a player.
local function driftOffset(now: number): Vector3
	if not drift then
		return Vector3.zero
	end
	local u = (now - drift.startedAt) / math.max(drift.seconds, 1e-3)
	if u >= 1 then
		drift = nil
		return Vector3.zero
	end
	return drift.dir * (math.sin(u * math.pi) * drift.studs)
end

-- ------------------------------------------------------------ rod windows

-- A MOMENT THE ROD IS THE ANSWER. `at` is what the cast snaps to (the blowhole,
-- or the shoal's ring centre) and the client draws the banner and the target
-- ring off the same event, so what the player is told and what the server will
-- accept are one statement.
function FloeService.openWindow(kind: string, seconds: number, at: Vector3, radius: number?)
	window = { kind = kind, at = at, radius = radius or 10, expiresAt = os.clock() + seconds }
	casting = {}
	fire({ kind = "window", window = kind, at = at, radius = radius or 10, seconds = seconds })
end

function FloeService.closeWindow()
	if not window then
		return
	end
	window = nil
	casting = {}
	fire({ kind = "window", window = nil })
end

function FloeService.windowKind(): string?
	if window and os.clock() < window.expiresAt then
		return window.kind
	end
	return nil
end

-- MAY THIS PLAYER CAST AT THIS WINDOW, and where does the line land? The client
-- names the window it believed was open; everything else is re-decided here.
function FloeService.castWindow(player: Player, kind: string?): (Vector3?, string?)
	if not window or os.clock() >= window.expiresAt then
		return nil, "Nothing to cast at."
	end
	if kind ~= nil and kind ~= window.kind then
		return nil, "Nothing to cast at."
	end
	if casting[player] then
		return nil, "Your line is already out."
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil, "Nothing to cast at."
	end
	if (root.Position - window.at).Magnitude > CAST_REACH then
		return nil, "Too far - get closer."
	end
	casting[player] = true
	return window.at, nil
end

-- The cast played out. `won` is the minigame's verdict; the EFFECTS are the
-- fight's, through the hooks CreatureService registers - this service owns the
-- window, not the whale.
function FloeService.resolveCast(player: Player, kind: string, won: boolean, perf: number)
	casting[player] = nil
	local hook = hooks[kind]
	if hook then
		hook(player, won, perf)
	end
end

function FloeService.cancelCast(player: Player)
	casting[player] = nil
end

-- Registered by CreatureService's rimefang region: { blowhole = fn(player,
-- won, perf), shoal = fn(...) }. Merged rather than replaced so two callers
-- cannot silently unregister each other.
function FloeService.setHooks(table_: { [string]: (Player, boolean, number) -> () })
	for name, fn in table_ do
		hooks[name] = fn
	end
end

-- ------------------------------------------------------------------- mist

-- THE REFREEZE HEAL'S GLOW, as an event rather than a part this service owns:
-- the thing a player BREAKS to cancel it is a spawned creature (the polyps'
-- pattern, and the only way a hit already routes through CombatService), so all
-- the floe has to say is which shards are being misted and for how long.
function FloeService.mist(ids: { number }, seconds: number)
	if not bound or #ids == 0 then
		return
	end
	fire({ kind = "mist", ids = ids, seconds = seconds })
end

-- ...and how each one ended. `healed` true is hers - the shard comes back
-- SLICK, which `FloeService.slick` states separately because the slickness
-- outlives the event that made it.
function FloeService.mistEnd(ids: { number }, healed: boolean)
	if not bound or #ids == 0 then
		return
	end
	fire({ kind = "mistEnd", ids = ids, healed = healed })
end

-- --------------------------------------------------------------- the tick

-- The shard bodies: the sink curve, the refreeze clock, and the drift offset,
-- in that order, written once per frame per shard that needs it.
local function stepShards(now: number, dt: number)
	local offset = driftOffset(now)
	local moving = offset.Magnitude > 1e-4 or drift ~= nil
	for id, shard in shards do
		-- The clocks first: a shard that refreezes this frame should be written
		-- at its new height, not at the old one.
		if shard.untilAt > 0 and now >= shard.untilAt then
			if shard.state == "open" then
				setState({ id }, "refreezing", FloeService.REFREEZING)
			elseif shard.state == "refreezing" then
				setState({ id }, "solid", 0)
				shard.untilAt = 0
			elseif shard.state == "solid" then
				shard.untilAt = 0
			end
		end
		local target = shard.sinkTo
		if shard.sink ~= target then
			local step = dt / SINK_TIME
			shard.sink = if target > shard.sink
				then math.min(shard.sink + step, target)
				else math.max(shard.sink - step, target)
			shard.part.Transparency = SINK_FADE * shard.sink
			moving = true
		end
		if moving then
			shard.part.CFrame = shard.base + offset - Vector3.new(0, SINK_DROP * shard.sink, 0)
		end
	end
end

-- THE WATER PLATE'S OWN REST, captured once: it is the only part here whose
-- base is not a shard's, and re-deriving it from its live CFrame every frame
-- (which the line above would do) would let the drift accumulate.
local waterBase: CFrame? = nil

local function stepWater(now: number)
	if not waterPart then
		return
	end
	waterBase = waterBase or waterPart.CFrame
	waterPart.CFrame = waterBase + driftOffset(now)
end

-- THE FROZEN METER. Every player in the arena, every tenth of a second: in the
-- water it fills, on the ice it drains, and at full it costs three seconds of
-- standing still and a throw back onto the nearest floor.
local function stepFrozen(now: number, dt: number)
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if humanoid and root and humanoid.Health > 0 then
			local hold = heldUntil[player]
			if hold then
				if now >= hold then
					heldUntil[player] = nil
					humanoid.WalkSpeed = 16
					humanoid.JumpPower = 50
					local to = FloeService.nearestSolidCentre(root.Position)
					if to then
						root.CFrame = CFrame.new(to + Vector3.new(0, 4, 0))
					end
					frozen[player] = 0
					Remotes.FloeEvent:FireClient(player, { kind = "frozen", value = 0, held = false })
				end
			else
				local onIce = FloeService.isPlayerOnIce(player)
				local was = frozen[player] or 0
				local value = math.clamp(was + (if onIce then -FROZEN_DECAY else FROZEN_GAIN) * dt, 0, 1)
				frozen[player] = value
				if value >= 1 then
					heldUntil[player] = now + FROZEN_HOLD
					humanoid.WalkSpeed = 0
					humanoid.JumpPower = 0
					Remotes.FloeEvent:FireClient(player, { kind = "frozen", value = 1, held = true })
				elseif math.abs(value - was) > 1e-4 then
					Remotes.FloeEvent:FireClient(player, { kind = "frozen", value = value, held = false })
				end
			end
		end
	end
end

function FloeService.frozenOf(player: Player): number
	return frozen[player] or 0
end

-- EVERYTHING BACK TO ICE. The fight ending (or never having started) must not
-- leave a hole in the floor for the next party: BossService tears an arena's
-- fight down, and this is the same idea one layer out.
function FloeService.reset()
	if not bound then
		return
	end
	drift = nil
	window = nil
	casting = {}
	local ids = {}
	for id, shard in shards do
		shard.untilAt = 0
		shard.slickUntil = 0
		if shard.state ~= "solid" then
			table.insert(ids, id)
		end
	end
	if #ids > 0 then
		setState(ids, "solid", 0)
	end
	for player in frozen do
		frozen[player] = 0
	end
	fire({ kind = "window", window = nil })
end

-- ------------------------------------------------------------------ lifecycle

function FloeService.init()
	Players.PlayerRemoving:Connect(function(player)
		frozen[player] = nil
		heldUntil[player] = nil
		casting[player] = nil
	end)
end

function FloeService.start()
	-- BOUND IN `start`, NOT `init`: BossArenaService places the arena in its
	-- own init, and this service is registered after it - so by the time every
	-- init has run the parts exist, and by the time this line runs they have
	-- existed for a phase.
	bind()
	RunService.Heartbeat:Connect(function(dt)
		if not bound then
			return
		end
		local now = os.clock()
		stepShards(now, dt)
		stepWater(now)
		accumulated += dt
		if accumulated >= FROZEN_TICK then
			stepFrozen(now, accumulated)
			accumulated = 0
		end
	end)
end

return FloeService
