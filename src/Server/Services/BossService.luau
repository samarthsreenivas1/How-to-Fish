--!nonstrict
-- BossService.luau
-- Raises each island's boss (Bosses.luau) when a player has earned it, and
-- records the win that opens the next island.
--
-- The boss is SUMMONED, never ambient: a cast with the island's capstone
-- bait (FishingService → BossService.summonFor) raises it at the island's
-- arena for a player who is on that island, at or above the boss's level,
-- owning its rod and its weapon (the island's best gear), and hasn't beaten
-- it yet - one at a time per island - and it stays (bosses don't linger
-- out) until it's killed. The fight itself is CreatureService's "boss"
-- archetype driven by the Bosses entry; this service only decides WHEN and
-- WHERE, and what a win means:
--
--   - every player who damaged it (Killed's `participants`) gets the row's
--     rewards, the replicated `Cleared_<islandId>` attribute (WorldService's
--     travel gate reads it), and the `Heart_<bossId>` attribute - the boss's
--     heart, a permanent trophy that recipes gate on (Recipe.requiresHearts)
--     and that the final summon will one day count.
--
--     There is NO level gate on that payout. User decision, 2026-09-06: "the
--     killing blow should pay all of the team members", and "the lower level
--     friend should be able to be carried, but since the boss will scale with
--     party size, it will just be more difficult." Being in the fight IS the
--     qualification; what a carry costs is DIFFICULTY, not a paywall - see
--     partyHealthMult below, which scales the boss's (and its parts') health
--     by the size of the party the summon gathered.
--
--     Hearts are owned, never spent - and because they are, the coins and XP
--     are paid ONCE: a player who already holds the heart may fight it again
--     beside a friend, but is not paid for it again. (That is the anti-farm
--     half of the earlier exploit fix, deliberately kept; the level gate is
--     the half the decision above revokes.)
--   - a "bossDown" CreatureEvent names what just opened up.
--
-- Cleared_* and Heart_* persist through DataService, which scans and restores
-- these attribute prefixes as part of the profile.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Islands = require(Shared.Config.Islands)
local World = require(Shared.Config.World)
local Bosses = require(Shared.Data.Bosses)
local BossCutscenes = require(Shared.Data.BossCutscenes)
local Creatures = require(Shared.Data.Creatures)
local Progression = require(Shared.Modules.Progression)
local Remotes = require(Shared.Net.Remotes)

local BossArenaService = require(script.Parent.BossArenaService)
local CreatureService = require(script.Parent.CreatureService)
local InventoryService = require(script.Parent.InventoryService)
local ProgressionService = require(script.Parent.ProgressionService)
local WorldService = require(script.Parent.WorldService)

local BossService = {}

-- A player counts as "on" an island within its radius plus this much
-- (the dock runs well past the shoreline).
local ISLAND_MARGIN = 160

-- The lair-arena fight flow (BossArenas islands only; an island with no
-- arena row keeps the old fight-in-place behavior - the Kraken's site).
local SUMMON_GATHER_RADIUS = 60 -- summoner's companions within this come along, studs
local RETURN_DELAY = 4 -- seconds between the kill and the ride home
local RETURN_NEAR = 120 -- past the roam disc: still "at the fight" for the return trip
local ABANDON_RADIUS = 300 -- a participant this close to the arena keeps the fight alive
local ABANDON_SECONDS = 20 -- empty this long -> the boss sinks back (despawn)
local ABANDON_GRACE = 10 -- after the rise: never reap a fight still starting up
-- ALREADY IN THE ROOM, for `ArenaMove`'s PARTY form. A participant this close
-- to the destination arena's centre is not swept there again.
--
-- The listener below learned to move ONE player, which is what makes the
-- Pyrelisk's caldera a jump you take rather than a yank you watch - and the
-- moment a move can fire per player it can also fire twice for the same
-- player: the design's 30-second grace sweeps the stragglers in with a
-- PARTY-form fire, and a party form that re-pivoted everybody would drag the
-- people already fighting in there back onto the entry pad half a minute in.
-- The per-player form is exempt; the listener says why.
--
-- 260 studs: the heart chamber is r96 inside a r94 belt, so nobody standing in
-- it is more than ~110 from its centre, and the nearest other arena is 13,000
-- studs away. There is no radius between those two that this number could be
-- wrong at. It is generous on purpose - the question it answers is "is this
-- player in the destination room", not "where exactly are they".
local ARENA_MOVE_HERE = 260

-- Party-size scaling. User decision, 2026-09-06: "the boss will scale with
-- party size, [so a carry] will just be more difficult." Each extra body past
-- the first adds this much of the boss's base health:
--
--   1 -> 1.0x   2 -> 1.5x   3 -> 2.0x   4 -> 2.5x   ...
--
-- i.e. `1 + PARTY_HEALTH_STEP * (n - 1)`. Sub-linear on purpose: a duo has
-- twice the damage output but only 1.5x the health bar to chew through, so
-- per-head effort drops a little with each body - the party is rewarded for
-- being a party - while a carried friend who contributes nothing still adds
-- half a boss's worth of work for everyone else. That is the cost the decision
-- asks for, and it is paid in time, not in anyone's rewards.
--
-- HEALTH ONLY, never damage: scaling damage would kill the under-levelled
-- friend the decision exists to let in, which is exactly backwards.
local PARTY_HEALTH_STEP = 0.5

-- The health multiplier for a party of `n`. Clamped at 1 so a party of one is
-- byte-for-byte today's fight (no scaling, no rounding drift).
local function partyHealthMult(n: number): number
	return math.max(1, 1 + PARTY_HEALTH_STEP * (n - 1))
end

-- Attribute name for a beaten island boss.
local function clearedAttribute(islandId: string): string
	return "Cleared_" .. islandId
end

-- Attribute name for an owned boss heart. Public so CraftingService (recipe
-- gates) and the trophy UI build the same name.
function BossService.heartAttribute(bossId: string): string
	return "Heart_" .. bossId
end

function BossService.hasHeart(player: Player, bossId: string): boolean
	return player:GetAttribute(BossService.heartAttribute(bossId)) == true
end

-- islandId -> the live boss Model, while one is up.
local active: { [string]: Model } = {}

-- islandId -> the running lair fight, while one is up on an arena island:
-- { bossId, participants: {Player}, startedAt }. Cleared on the win and by
-- the abandon reaper. Fight-in-place islands never get an entry.
--
-- A boss with a BossCutscenes row carries four MORE fields for the length of
-- its intro cinematic, and every reader of them treats absent as "the way it
-- has always been" - a fight written by any other path, or by a later handoff
-- that re-points this record, must keep behaving exactly as it did:
--
--   introUntil  when the cinematic ends (os.clock). Absent -> no intro ran.
--   raiseToken  a fresh table, the delayed raise's identity check. Compared,
--               never cleared, so a fight record that is later re-pointed at
--               another boss can leave it alone.
--   raised      false while the boss has not surfaced yet; true after, and
--               ABSENT on every fight that never had a cinematic - which is
--               why every test is `raised ~= false` rather than `raised`.
--   skipped     player -> true, the intro skips. Absent until the first one.
--   audience    who the intro was fired to, so the "raise" goes to the same
--               set (an arena-less island's audience is wider than its party).
local fights: { [string]: { bossId: string, participants: { Player }, startedAt: number } } = {}

-- ============================================================ gate

local function onIsland(player: Player, islandId: string): boolean
	local entry = Islands.items[islandId]
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not entry or not root then
		return false
	end
	local d = Vector3.new(root.Position.X - entry.worldPosition.X, 0, root.Position.Z - entry.worldPosition.Z).Magnitude
	return d <= entry.radius + ISLAND_MARGIN
end

-- The level gate plus whatever gear the boss's entry names (none for
-- Brinejaw: its bait is the gate). Public so a HUD can explain what's missing.
function BossService.qualifies(player: Player, boss): boolean
	local level = player:GetAttribute(Progression.ATTR.level) or Progression.START_LEVEL
	if level < boss.gate.level then
		return false
	end
	if boss.gate.rod and not InventoryService.ownsItem(player, boss.gate.rod) then
		return false
	end
	if boss.gate.weapon and not InventoryService.ownsItem(player, boss.gate.weapon) then
		return false
	end
	if boss.gate.hearts and not BossService.hasHearts(player, boss.gate.hearts) then
		return false
	end
	return true
end

-- Every heart in the list - the Kraken's gate (all six island hearts,
-- owned, never spent).
function BossService.hasHearts(player: Player, bossIds: { string }): boolean
	for _, bossId in bossIds do
		if not BossService.hasHeart(player, bossId) then
			return false
		end
	end
	return true
end

function BossService.isCleared(player: Player, islandId: string): boolean
	return player:GetAttribute(clearedAttribute(islandId)) == true
end

-- ============================================================ spawning

local function arenaPosition(boss): Vector3
	-- A BOSS THAT FIGHTS SOMEWHERE ITS ISLAND IS NOT, and it is one field.
	--
	-- Every row until now answered "where is this fight" with its own
	-- `islandId`, because a BossArenas key IS an island id for all of them.
	-- The Ashfall Heart breaks that: it is act four of the Pyrelisk's fight, so
	-- its `islandId` has to stay "volcano" (the fight record, the participants,
	-- `Cleared_volcano`, the ride home and `heartAs` all key off it) while the
	-- room it is fought in is the `pyrelisk_heart` arena 40,000 studs away and
	-- 600 studs up. Two questions, one field each: `islandId` says whose fight
	-- this is, `arenaKey` says which room.
	--
	-- IT BELONGS HERE AND NOT AT THE PIVOT IN `handoff`. The successor could
	-- have been spawned at its island's arena and moved afterwards - that is
	-- what the Admiral's `at` does - but this position is not merely where the
	-- model appears: CreatureService.updateBoss takes the FIGHT'S ARENA CENTRE
	-- from the spawn position, so a post-spawn pivot would leave a heart
	-- standing in its chamber while every height, every telegraph and every
	-- roam test in its book was still measured against a volcano summit. Fixing
	-- it at the source fixes `fightCenter`, `sendHome` and the abandon reaper in
	-- the same line, because all three come through here.
	--
	-- ADDITIVE: no shipped row has `arenaKey`, so every one of them resolves
	-- exactly the key it always did.
	local arenaKey = boss.arenaKey or boss.islandId
	-- Lair islands fight at their arena out in the ocean; the rest (the
	-- Kraken's whirlpool site) keep the old spot beside the island.
	local center = BossArenaService.centerFor(arenaKey)
	if center then
		-- ...at the arena's OWN floor, which is not the waterline any more.
		-- The Ashfall Throne is a volcano summit: its rim path is 292 studs
		-- up, so the old `World.WATER_Y` here rose Pyrelisk in the open sea
		-- underneath its arena. And this position is not just where the model
		-- appears - CreatureService.updateBoss takes the fight's arena centre
		-- from it, so every height the pose measures would have been 292 studs
		-- out too, silently. Probed at the roam radius rather than at the
		-- centre column, because that is the ground the fight is actually
		-- fought on; BossArenaService.floorY returns World.WATER_Y unchanged
		-- for every arena that really is at sea level.
		return Vector3.new(center.X, BossArenaService.floorY(arenaKey, boss.arena.radius), center.Z)
	end
	local island = Islands.items[boss.islandId]
	local origin = if island then island.worldPosition else Vector3.zero
	return Vector3.new(origin.X + boss.arena.offset.X, World.WATER_Y, origin.Z + boss.arena.offset.Z)
end

-- WHERE THE FIGHT ACTUALLY IS, which stopped being "where the boss rose" the
-- day a fight learned to change rooms.
--
-- Two things in this file ask that question - the ride home and the abandon
-- reaper - and both asked `arenaPosition`, which answers with the arena the
-- boss was SUMMONED to. That is the same place for every boss in the project
-- but one: the Kraken's third phase swallows the party into the gullet, a
-- separate arena 20,000 studs away, and from there both readers see a fight
-- with nobody standing near it. The reaper would despawn a boss the party is
-- actively fighting and strand them in a sealed room with no ride home, and
-- `sendHome` (which the reaper then calls) would find them all out of range and
-- take nobody anywhere. Silent, twenty seconds in, every time.
--
-- So the FIGHT publishes where it is and this reads it: `FightCenter` on the
-- boss's own model, a Vector3, written by CreatureService when a fight
-- relocates and absent on every boss that never does. Level-triggered rather
-- than an event, the WeakpointHot idiom - a reaper that wakes on a 2-second
-- poll cannot be handed a one-shot.
local function fightCenter(boss): Vector3
	local model = active[boss.islandId]
	local relocated = model and model.Parent and model:GetAttribute("FightCenter")
	if typeof(relocated) == "Vector3" then
		return relocated
	end
	return arenaPosition(boss)
end

-- WHO IS IN A BOSS FIGHT RIGHT NOW - the one question the rest of the server
-- asks about one (user, 2026-09-12: no casting and no boat summons during a
-- boss fight). Answers `(islandId, bossId)`, or nil.
--
-- TWO WAYS TO BE IN ONE, because a fight has two kinds of member:
--
--   A PARTICIPANT - named on the `fights` record, so they were carried out to
--   the lair with the party and are in the fight whether or not they happen to
--   be standing near the boss at this instant (knocked into the sea, mid-
--   respawn, walked to the rail).
--   A BYSTANDER INSIDE THE ARENA - an arena-less fight-in-place boss gets no
--   `fights` record at all (see `fights` above), so proximity is the ONLY
--   reading available for that path, and it is the honest one for the lair
--   bosses too: somebody who walked into a live fight is in it.
--
-- Iterates `active` rather than `fights` for exactly that reason: `active` is
-- the one table every live boss appears in, by either path.
--
-- `fightCenter`, not `arenaPosition`, so the Kraken's gullet is measured from
-- where the party actually is. The 60-stud margin is deliberately generous and
-- deliberately not shared with anything else: a false positive costs one
-- refused cast, a false negative lets someone fish through a boss fight.
--
-- NIL-SAFE BY CONTRACT - the callers (FishingService, BoatService) have no idea
-- whether any fight exists and may ask about a player with no character.
function BossService.fightFor(player: Player): (string?, string?)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return nil
	end
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	for islandId, model in active do
		if not (model and model.Parent) then
			continue
		end
		local fight = fights[islandId]
		-- The fight's OWN row when there is a record (so a successor act -
		-- Admiral Wrack on the wreck - reports the boss being fought, not the
		-- island's summonable one), else the island's boss.
		local boss = (fight and Bosses.items[fight.bossId]) or Bosses.byIsland[islandId]
		if not boss then
			continue
		end
		if fight then
			for _, member in fight.participants do
				if member == player then
					return islandId, boss.id
				end
			end
		end
		if root then
			local center = fightCenter(boss)
			local d = Vector3.new(root.Position.X - center.X, 0, root.Position.Z - center.Z).Magnitude
			if d <= boss.arena.radius + 60 then
				return islandId, boss.id
			end
		end
	end
	return nil
end

-- Move one character, safely out of a boat seat if need be - the containment
-- sweep's pattern: Sit = false does not kill the SeatWeld in the same step,
-- so pivoting through it would drag the whole boat along.
local function moveTo(player: Player, cframe: CFrame)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not root then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local seatPart = humanoid and humanoid.SeatPart
	if seatPart then
		humanoid.Sit = false
		local weld = seatPart:FindFirstChild("SeatWeld")
		if weld then
			weld:Destroy()
		end
		task.defer(function()
			if character.Parent and root.Parent then
				root.AssemblyLinearVelocity = Vector3.zero
				character:PivotTo(cframe)
			end
		end)
	else
		root.AssemblyLinearVelocity = Vector3.zero
		character:PivotTo(cframe)
	end
end

-- The summoner plus every living player standing with them (within
-- SUMMON_GATHER_RADIUS on the same island) who could have made this call
-- themselves - standing that close to a Call you are ready for is the
-- invitation.
--
-- NO LEVEL GATE on who comes along. User decision, 2026-09-06: "the lower
-- level friend should be able to be carried" - and a friend who cannot be
-- brought to the arena cannot be carried at all, so the gate that used to
-- stand here (BossService.qualifies, the summoner's own check) is gone.
--
-- The press-gang worry that gate answered is now answered economically
-- instead: the boss's health scales with the size of THIS party
-- (partyHealthMult), so every extra body - willing or conscripted - makes the
-- fight longer and harder for the people actually swinging. Dragging in
-- bystanders is no longer free grief with an upside; it is a cost the
-- summoner pays first. Proximity stays the invitation: standing within
-- SUMMON_GATHER_RADIUS of a Call being cast is what puts you in the fight.
local function gatherParty(summoner: Player, boss): { Player }
	local islandId = boss.islandId
	local party = { summoner }
	local root = summoner.Character and summoner.Character:FindFirstChild("HumanoidRootPart")
	if not root then
		return party
	end
	for _, player in Players:GetPlayers() do
		if player ~= summoner and onIsland(player, islandId) then
			local character = player.Character
			local otherRoot = character and character:FindFirstChild("HumanoidRootPart")
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if otherRoot and humanoid and humanoid.Health > 0 then
				local d =
					Vector3.new(otherRoot.Position.X - root.Position.X, 0, otherRoot.Position.Z - root.Position.Z).Magnitude
				if d <= SUMMON_GATHER_RADIUS then
					table.insert(party, player)
				end
			end
		end
	end
	return party
end

local function raise(boss, healthMult: number): Model?
	local row = Creatures.items[boss.creature]
	if not row then
		warn(string.format("[BossService] boss %q names unknown creature row %q", boss.id, boss.creature))
		return nil
	end
	-- No throw target: it surfaces where it's put and the boss archetype plays
	-- its own rise from the deep (Bosses.riseDepth / riseTime).
	--
	-- `healthMult` rides the existing `extra` bag (the same channel as
	-- noLinger / suppressDrops / bounty; `spawn` has read the key since the
	-- ooze's halves) so party scaling needs no new argument and no new hook.
	-- It is stored on the creature record, which is how CreatureService's
	-- spawnBossParts finds the SAME factor for the Kraken's arms and Noctyss's
	-- choir - parts that did not scale would make a parts-gated fight EASIER
	-- per head as the party grows.
	--
	-- `suppressRewards`: the killing blow must not also collect the generic
	-- per-kill payout on top of the team payout this service pays below.
	-- Mirrors `suppressDrops`, which MaterialService and DropService already
	-- honour out of this same bag. NOTE: ProgressionService does not read this
	-- key yet - see the report / the comment in onKilled.
	local model = CreatureService.spawn(row, arenaPosition(boss), nil, "Neutral", {
		healthMult = healthMult,
		suppressRewards = true,
		-- ...AND NO MATERIALS EITHER, for a boss whose death is an ACT BREAK
		-- rather than a win. Admiral Wrack's hull going down is the middle of
		-- his fight: `onKilled` hands off to the Admiral and returns before it
		-- pays anybody, but MaterialService and DropService listen to the same
		-- Killed event and would happily pay the boss's full drop table for a
		-- ship sinking halfway through. The loot lives on the row that actually
		-- ends the fight.
		suppressDrops = boss.succeededBy ~= nil,
	})
	active[boss.islandId] = model
	model.AncestryChanged:Connect(function(_, parent)
		if parent == nil and active[boss.islandId] == model then
			active[boss.islandId] = nil
		end
	end)
	return model
end

-- The boss of the island `player` is standing on, or nil.
local function bossHere(player: Player)
	for _, boss in Bosses.items do
		-- ...BUT NEVER A SUCCESSOR. `summonable == false` marks a row that is a
		-- later ACT of another boss's fight rather than an island's boss -
		-- Admiral Wrack's duel is the only one today, and it shares his
		-- islandId. Without this the Careenage's Call would be a coin flip
		-- between the ship and her captain, decided by table iteration order.
		-- (Bosses.luau's `byIsland` builder skips on the same flag, for the same
		-- reason and with worse consequences: it feeds the arena's floor.)
		if boss.summonable ~= false and onIsland(player, boss.islandId) then
			return boss
		end
	end
	return nil
end

-- CARRY THE PARTY OUT TO THE LAIR. Lifted whole out of beginFight so the
-- cinematic path can drop the party in without a second copy of it: the
-- deferred pivot, the ring, and the arrival WorldEvent are exactly what they
-- were, and the comment below is the one that was here.
--
-- Deferred so the cast's CastResolved { summoned } reaches the client and
-- closes the cast BEFORE the camera jumps. Fight-in-place islands (no arena
-- row) never call it.
local function dropIn(boss, party: { Player })
	local ring = BossArenaService.ringPositions(boss.islandId, #party, boss.arena.radius + 8)
	task.defer(function()
		for i, member in party do
			if member.Parent == Players and ring[i] then
				moveTo(member, ring[i])
				-- Land the lair's ambience with the player. The client's mood
				-- probe is on a 1s interval and then cross-fades, and a
				-- summoner can be outside their island's mood footprint and
				-- still inside ISLAND_MARGIN (a boat off the dock), so the
				-- Gloomtrench - "the arena is pitch black and the boss's
				-- lanterns are the only light" - could open on daylight and
				-- fade to black. That is the wrong first impression of the
				-- fight, on every summon. WorldEvent rather than a new remote:
				-- this is an island event whose whole client half is ambience,
				-- the same shape as a blizzard window, and WeatherController is
				-- already listening there.
				Remotes.WorldEvent:FireClient(member, {
					kind = "arrival",
					islandId = boss.islandId,
					active = true,
				})
			end
		end
	end)
end

-- WHO SEES THE INTRO. On a lair island that is the party and nobody else -
-- they are the only people within 24,000 studs of the arena. An island with no
-- arena row teleports NOBODY (the fight-in-place fallback), so the cinematic
-- plays where everyone standing there can see it, and firing only to the
-- summoner would run a locked camera for one person in a crowd.
local function introAudience(boss, party: { Player }): { Player }
	if BossArenaService.centerFor(boss.islandId) ~= nil then
		return party
	end
	local audience = table.clone(party)
	for _, player in Players:GetPlayers() do
		if not table.find(audience, player) and onIsland(player, boss.islandId) then
			table.insert(audience, player)
		end
	end
	return audience
end

-- THE RAISE, AS ITS OWN CALL, because two things reach it now: the scheduled
-- end of the cinematic, and every participant skipping before it. Both must
-- run the identical path or a skipped intro would open a subtly different
-- fight from a watched one.
--
-- `fight.raised` is the guard: a skip that lands in the same frame as the
-- timer, or a second skip after the raise, must not raise twice.
local function doRaise(fight, boss): boolean
	if fight.raised then
		return true
	end
	local model = raise(boss, partyHealthMult(#fight.participants))
	if not model then
		-- The boss names an unknown creature row (`raise` has already warned).
		-- The cinematic is over either way, so say so: `raised = true` hands the
		-- stranded party to the abandon reaper's "the model went without a win"
		-- branch, which sends them home and drops the record - the one path in
		-- this file that already knows how to collect people from an arena.
		-- Clearing `fights` here instead would strand them at the lair with no
		-- boss and no ride home.
		fight.raised = true
		warn(string.format("[BossService] %s failed to rise after its intro; the fight is over", boss.id))
		return false
	end
	fight.raised = true
	local payload = {
		kind = "raise",
		bossId = boss.id,
		islandId = boss.islandId,
		startsAt = Workspace:GetServerTimeNow(),
		riseTime = boss.riseTime,
	}
	for _, member in fight.audience or fight.participants do
		if member.Parent == Players then
			Remotes.BossIntro:FireClient(member, payload)
		end
	end
	return true
end

-- THE CINEMATIC SUMMON: the fight record is written FIRST, the party is
-- carried out and shown the intro, and the real raise is the cinematic's last
-- beat rather than its first (BossCutscenes.luau's header).
--
-- Writing `fights` before anything else is what makes the intro a state the
-- rest of this file can see: without it, a second cast during those 22 seconds
-- finds `active[islandId]` empty (the boss genuinely is not up yet) and raises
-- a second one on top.
local function beginIntroFight(boss, party: { Player }, cutscene): boolean
	local token = {}
	local now = os.clock()
	local fight = {
		bossId = boss.id,
		participants = party,
		startedAt = now,
		introUntil = now + cutscene.duration,
		raiseToken = token,
		raised = false,
		skipped = {},
	}
	fight.audience = introAudience(boss, party)
	fights[boss.islandId] = fight

	if BossArenaService.centerFor(boss.islandId) ~= nil then
		dropIn(boss, party)
	end

	local payload = {
		kind = "start",
		bossId = boss.id,
		islandId = boss.islandId,
		center = arenaPosition(boss),
		startsAt = Workspace:GetServerTimeNow(),
		duration = cutscene.duration,
	}
	for _, member in fight.audience do
		if member.Parent == Players then
			Remotes.BossIntro:FireClient(member, payload)
		end
	end

	-- ...and the raise, `riseTime` before the cinematic's end, so the rise the
	-- fight has always played IS the last beat of it.
	--
	-- IDENTITY, not existence: a fight that was torn down and re-summoned
	-- inside this window is a DIFFERENT fight with a different token, and the
	-- old closure must not raise a boss into it. The token is only ever
	-- compared - never cleared - so a later pass that re-points this record can
	-- leave it where it is.
	task.delay(math.max(0, cutscene.duration - boss.riseTime), function()
		local current = fights[boss.islandId]
		if current == fight and current.raiseToken == token then
			doRaise(current, boss)
		end
	end)
	return true
end

-- EVERYTHING A SUMMON DOES ONCE THE GATE HAS SAID YES. Split out of
-- summonFor so the admin playtest entry point (BossService.adminStart) can
-- reuse it whole instead of growing a parallel copy that drifts: a second
-- raise-and-teleport would be one refactor away from spawning a boss with no
-- `fights` record (no abandon reaper, no ride home) or a party of one at full
-- health, and both of those look fine right up until they don't.
--
-- `party` is already counted - the count sets the boss's health and health is
-- fixed at spawn, so the caller gathers before it calls. Returns false only
-- when the raise itself failed (a boss naming an unknown creature row).
local function beginFight(boss, party: { Player }): boolean
	-- THE CINEMATIC BRANCH, and the only one there is: a boss with a
	-- BossCutscenes row opens with an intro and rises at the end of it; a boss
	-- without one takes the path below, byte-for-byte what this function has
	-- always done.
	local cutscene = BossCutscenes.items[boss.id]
	if cutscene then
		return beginIntroFight(boss, party, cutscene)
	end

	if not raise(boss, partyHealthMult(#party)) then
		return false
	end

	-- A lair island: the call drags the summoner and everyone standing with
	-- them to the boss's arena out in the open sea. Fight-in-place islands (no
	-- arena row) skip all this.
	if BossArenaService.centerFor(boss.islandId) == nil then
		return true
	end
	fights[boss.islandId] = {
		bossId = boss.id,
		participants = party,
		startedAt = os.clock(),
	}
	dropIn(boss, party)
	return true
end

-- Summon the boss of the island the player is on, for that player - the
-- capstone bait's cast (FishingService calls this when a cast uses it;
-- user, 2026-08-23: "the boss should be fished up"). The bait is the ONLY
-- way it appears - there is no automatic raise - and it REPLACES the old
-- best-rod + best-weapon rule: the only gate left is the boss's level (the
-- bait's own recipe is level-locked too). `bossId` is the boss the bait
-- names (effect.summonsBoss): with more than one boss in the world, each
-- island's Call only works in that boss's own waters. Returns ok and, when
-- not, a player-facing reason so the cast can say why (the caller should
-- only consume the bait on ok).
function BossService.summonFor(player: Player, bossId: string?): (boolean, string?)
	local boss = bossHere(player)
	if not boss then
		return false, "Nothing answers the call here"
	end
	if bossId and boss.id ~= bossId then
		local wanted = Bosses.items[bossId]
		return false, string.format("%s does not dwell in these waters", if wanted then wanted.shortName else "That")
	end
	if BossService.isCleared(player, boss.islandId) then
		return false, string.format("%s is already defeated", boss.shortName)
	end
	-- ...and a fight whose INTRO is still running counts as already here, even
	-- though the boss genuinely has not surfaced yet: those are the seconds in
	-- which `active[islandId]` is empty by design, and without this a second
	-- cast during the cinematic raises a second boss into the same arena.
	-- `raised == false` rather than `not raised`, because a fight record from
	-- any other path has no such field at all.
	local pending = fights[boss.islandId]
	if active[boss.islandId] or (pending and pending.raised == false) then
		return false, string.format("%s is already here", boss.shortName)
	end
	local level = player:GetAttribute(Progression.ATTR.level) or Progression.START_LEVEL
	if level < boss.gate.level then
		return false, string.format("Reach level %d", boss.gate.level)
	end
	if boss.gate.hearts and not BossService.hasHearts(player, boss.gate.hearts) then
		return false, "It ignores the call. Bring every island's heart."
	end
	if not BossService.qualifies(player, boss) then
		return false, "You're not ready for this" -- only reachable for a boss whose gate names gear
	end

	-- THE PARTY IS COUNTED BEFORE THE BOSS RISES, because the count sets its
	-- health and health is fixed at spawn. A lair island's party is everyone
	-- the call is about to drag out to the arena; a fight-in-place island
	-- (the Kraken's site - no arena row) teleports nobody, so nobody is
	-- committed to the fight and the summoner is the whole party. Either way a
	-- party of one is exactly today's fight (partyHealthMult(1) == 1).
	local lair = BossArenaService.centerFor(boss.islandId) ~= nil
	local party = if lair then gatherParty(player, boss) else { player }

	if not beginFight(boss, party) then
		return false, "Nothing answers the call here"
	end
	return true
end

-- ============================================================ the win

-- Set every participant still standing at the arena back on the island. The
-- proximity filter quietly excludes the dead (they respawned at the world
-- spawn) and anyone who already travelled out. A party member was CARRIED to
-- the arena, so this is their only way back: anything that ends a lair fight
-- owes them this call, not just the win.
local function sendHome(fight, boss)
	-- WHERE THEY ARE, not where they started: a wipe inside the Kraken's
	-- gullet has to be collected from the gullet. See `fightCenter`.
	local center = fightCenter(boss)
	local nearLimit = boss.arena.radius + RETURN_NEAR
	for _, member in fight.participants do
		local character = member.Parent == Players and member.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid and humanoid.Health > 0 then
			local d = Vector3.new(root.Position.X - center.X, 0, root.Position.Z - center.Z).Magnitude
			if d <= nearLimit then
				WorldService.teleportToIsland(member, boss.islandId)
			end
		end
	end
end

-- ============================================================ admin playtest

-- THE ADMIN'S PLAYTEST ENTRY POINT (AdminService, off the cheat panel's BOSSES
-- section). One click puts you in any boss fight from a cold start, which is
-- the thing the normal summon deliberately makes expensive: reach the level,
-- own the rod and the weapon, hold the earlier hearts, craft the capstone bait,
-- sail to the island, cast. That ritual is right for players and ruinous for
-- iteration - tuning a phase-three enrage should not cost a fresh save.
--
-- SO THIS SKIPS EVERY GATE, ON PURPOSE: level, hearts, rod, weapon, the bait,
-- standing on the island, and "already defeated" (replaying a beaten boss is
-- most of what playtesting IS - and the heart check in onKilled means a replay
-- still cannot be farmed for coins or XP). Authorization is the caller's
-- problem: AdminService checks isAdmin before this is ever reached, the same
-- check every other Admin* remote uses.
--
-- WHAT IT DOES NOT SKIP IS THE FIGHT. Everything past the gate runs through
-- beginFight, the exact path a real summon takes - the same raise, the same
-- `fights` record (so the abandon reaper and the ride home both work), the same
-- ring drop-in, the same arrival ambience, the same party scaling. A boss you
-- test here is the boss that ships.
--
-- Lives BELOW sendHome rather than beside summonFor because its teardown calls
-- it: the reset half of "from fresh" is exactly what the abandon reaper does.
function BossService.adminStart(player: Player, bossId: string): (boolean, string?)
	local boss = Bosses.items[bossId]
	if not boss then
		return false, "Unknown boss"
	end

	-- START FROM FRESH means tearing down whatever is already up on this island
	-- first, and through the SAME teardown the abandon reaper uses rather than a
	-- second one invented here: drop the fight record, send anyone it stranded
	-- at the arena back to the island, and despawn the model through
	-- CreatureService (never model:Destroy(), which would leave the creature
	-- struct running - still attacking, still damaging - while this island
	-- happily raises a second boss on top of the invisible one). despawn's
	-- removeOwnedParts takes the parts ring - the Kraken's arms, Noctyss's
	-- choir - down with it; `active` is cleared by the model's own
	-- AncestryChanged, whose `active[id] == model` guard is what makes it safe
	-- to raise the replacement immediately below.
	-- Dropping the record is also what disarms a running intro: the delayed
	-- raise checks that `fights[islandId]` is still the SAME table it was
	-- scheduled for, so a cinematic torn down here can never raise its boss on
	-- top of the one this call is about to summon. Nothing else is needed, and
	-- nothing here clears the token itself - see `beginIntroFight`.
	local fight = fights[boss.islandId]
	fights[boss.islandId] = nil
	if fight then
		sendHome(fight, boss)
	end
	local model = active[boss.islandId]
	if model then
		CreatureService.despawn(model)
	end

	-- A fight-in-place boss (no BossArenas row - the Kraken, at the Maelstrom's
	-- whirlpool site) has no ring to be dropped into: beginFight teleports
	-- nobody, and the boss rises at the island's own arena offset. So the admin
	-- has to already BE there, or the rise plays to an empty sea a world away.
	-- WorldService.teleportToIsland is the same call AdminTeleport makes, and it
	-- is synchronous, so we are standing on the site before the boss rises.
	-- Lair bosses need nothing here - beginFight's ring drop-in carries the
	-- caller out to the arena a frame after the raise, well inside riseTime, so
	-- the rise plays for them exactly as it does on a real summon.
	if BossArenaService.centerFor(boss.islandId) == nil then
		local ok, reason = WorldService.teleportToIsland(player, boss.islandId)
		if not ok then
			return false, reason
		end
	end

	if not beginFight(boss, { player }) then
		return false, "Nothing answers the call here"
	end
	return true
end

-- ============================================================ the act break
--
-- ONE FIGHT, TWO CREATURES. Admiral Wrack is three acts: his four corner guns,
-- then his ship, then the man himself on the sand. The first two are one
-- creature (the hull); the third is its own, because everything the boss
-- archetype provides is reached through `row.boss` -> `Bosses.items`, one row
-- per fight, and a planted 41-stud gun platform and a running swordsman cannot
-- share one `speed`, one `turnRate` and one attack book.
--
-- So the hull's death is not an ending, and `onKilled` must not treat it as
-- one: no heart, no coins, no unlock banner, no ride home. This raises the
-- successor at the wreck and leaves the fight running.
--
-- IT DOES NOT GO THROUGH `beginFight` OR `doRaise`, deliberately:
--   * `beginFight` would look up a BossCutscenes row and could open a second
--     cinematic in the middle of a fight.
--   * `doRaise` early-returns on `fight.raised` (long true by now) and fires
--     `Remotes.BossIntro { kind = "raise" }` at the cinematic's audience. That
--     is the intro's raise beat. This is an act transition; it has already had
--     its beat - the ship wrecking.
local function handoff(boss, fight, at: Vector3?, healthMult: number?)
	local next_ = Bosses.items[boss.succeededBy]
	if not next_ then
		warn(string.format("[BossService] %q names unknown successor %q", boss.id, tostring(boss.succeededBy)))
		return
	end
	-- THE PARTY SCALING COMES ACROSS AS IT WAS AT THE SUMMON, and it is read
	-- rather than recomputed. `raise` puts `healthMult` in the spawn bag,
	-- `spawn` keeps it on the creature, and `kill` merges the bag into the
	-- Killed info - so the caller hands us the exact factor the hull spawned
	-- with. Recounting `#fight.participants` here would be WRONG, not merely
	-- redundant: PlayerRemoving prunes that list, so a party that loses a body
	-- during acts one and two would meet an Admiral scaled for the smaller
	-- party - the leave-and-shrink exploit this file's own header warns about,
	-- re-opened at the act boundary.
	local model = raise(next_, healthMult or partyHealthMult(#fight.participants))
	if not model then
		return
	end
	-- ...BUT NOT WHEN THE SUCCESSOR HAS A ROOM OF ITS OWN.
	--
	-- `at` is the dying boss's position, and for the Admiral that is exactly
	-- right: he leaps down off the ship that just went under, onto the sand the
	-- party is standing on, inside the same arena. The Ashfall Heart's act
	-- break is the other kind - the colossus dies on its summit and the heart
	-- is raised in a sealed chamber 40,000 studs away - so honouring `at` there
	-- would take the heart `raise` has just correctly placed in its own room
	-- and pivot it back onto the volcano the party is about to leave. The model
	-- would be somewhere the fight is not, which is the one thing `fightCenter`
	-- exists to stop happening.
	--
	-- `arenaKey` is the same field `arenaPosition` reads, and the test is the
	-- same test: a successor that names its own arena was placed by that
	-- lookup, deliberately, and nothing here may move it.
	if at and not next_.arenaKey then
		-- At the wreck, not at the arena's centre: he leaps down off the ship
		-- that just went under, and that is where the party is looking.
		model:PivotTo(CFrame.new(at) * model:GetPivot().Rotation)
	end
	-- THE SAME FIGHT RECORD, RE-POINTED. Not a new one: the participants, the
	-- audience and the ride home all belong to a fight that has not ended.
	--
	-- `bossId` moves to the successor because every reader of it - the abandon
	-- reaper's `Bosses.items[fight.bossId]`, `boss.riseTime`, `arena.radius`,
	-- `arenaPosition`, `sendHome` - wants the LIVE boss. The reward identity is
	-- already decoupled by `heartAs`, so nothing is lost by moving it and every
	-- one of those readers stays correct without learning about acts.
	fight.bossId = next_.id
	-- Re-arms the reaper's grace across the leap: the Admiral has his own
	-- `riseTime` to land in and must not be reaped mid-air.
	fight.startedAt = os.clock()
	-- Explicit rather than left nil. The cinematic lane's tests read
	-- `raised ~= false`, which nil already satisfies - but "right by accident on
	-- a field we never set" is not a thing to leave for the next reader of
	-- either lane's code.
	fight.raised = true
	-- ...and the stale intro window goes. `introUntil` fed a grace term
	-- measured against `startedAt`, which was just reset; the term clamps at
	-- zero so the arithmetic is already correct, but a dead field feeding a
	-- clamp is exactly the number someone later trusts.
	fight.introUntil = nil
	-- `raiseToken` is left alone: it was consumed when the intro raised, and the
	-- cinematic lane's reads of it are nil-safe.
end

local function onKilled(row, _grade: string, killer: Player?, extra)
	local boss = row.boss and Bosses.items[row.boss]
	if not boss then
		return
	end

	-- THE FIGHT IS NOT OVER. A boss carrying `succeededBy` has died into its own
	-- next act: hand off and return before anything below pays, announces or
	-- sends anybody home. Only the last act's death does any of that.
	if boss.succeededBy then
		local fight = fights[boss.islandId]
		if fight then
			handoff(
				boss,
				fight,
				type(extra) == "table" and extra.position or nil,
				type(extra) == "table" and extra.healthMult or nil
			)
		end
		return
	end

	-- Everyone who hit it shares the win AND the payout - the killer included,
	-- on the same terms as everybody else. User decision, 2026-09-06: "the
	-- killing blow should pay all of the team members." Landing the last hit is
	-- not a role, so it is not a bonus.
	local winners = {}
	local seen = {}
	local function add(player)
		if player and player.Parent == Players and not seen[player] then
			seen[player] = true
			table.insert(winners, player)
		end
	end
	add(killer)
	if type(extra) == "table" and type(extra.participants) == "table" then
		for _, player in extra.participants do
			add(player)
		end
	end

	-- ONE PAYOUT, PAID HERE. ProgressionService's generic Killed handler also
	-- pays whoever landed the killing blow the row's full coins and XP, with no
	-- heart check and no participant check - which for a boss is a second
	-- payment stacked on the team payout below, and a farm (a cleared player
	-- can keep sniping the last hit on other people's summons). `raise` spawns
	-- the boss with `suppressRewards = true` in its `extra` bag - the same bag
	-- and the same idiom as `suppressDrops`, which MaterialService and
	-- DropService already honour. ProgressionService's onKilled returns early
	-- on this key (landed 2026-09-06), so the generic killer payout never
	-- fires for a boss.
	--
	-- Deliberately not worked around from this side: `bounty = 0` would zero
	-- the coins but also collapse the boss's material drops to the
	-- `math.max(1, ...)` floor in MaterialService, and a nil killer would
	-- silence materials and drops entirely. Until that line lands, the killer
	-- is over-paid on a boss exactly as much as they were before this change.
	local rewards = row.rewards
	for _, player in winners do
		-- NO LEVEL GATE HERE ANY MORE. An earlier exploit fix required every
		-- winner to pass BossService.qualifies (the summoner's own check), so a
		-- carried friend fought the boss, watched it die, and got nothing -
		-- no coins, no island unlock, no heart. User decision, 2026-09-06:
		-- "the lower level friend should be able to be carried." A carry that
		-- pays nothing is not a carry, so the gate is gone: being in the fight
		-- is the qualification. What replaced it is a PRICE rather than a
		-- refusal - partyHealthMult scaled the boss (and its parts) by the size
		-- of the party at summon, so the level-5 tagging along made the whole
		-- fight measurably longer for the people who could actually hurt it.
		-- Skipping six islands of progression now costs the friends who let you.
		--
		-- A heart is owned once, so the win it stands for pays once. Without
		-- this, anyone holding the heart was paid the boss's full coins and XP
		-- again on every later summon anyone else made, forever. This half of
		-- the exploit fix is KEPT, deliberately: it is the anti-farm, not the
		-- anti-carry, and the decision above did not revoke it. Checked before
		-- the SetAttribute below, so the first win still pays. Fighting a boss
		-- you have already beaten, beside a friend who hasn't, stays free: you
		-- keep your heart, they get theirs, nobody farms.
		-- UNDER WHOSE NAME THE WIN IS RECORDED. A successor row is a later ACT
		-- of another boss's fight, not a separate trophy: the player fought one
		-- Admiral Wrack across three of them, and every recipe gate and the
		-- Kraken's own `gate.hearts` name `admiral_wrack`. Without `heartAs`
		-- the win would quietly mint `Heart_wrack_duel` - an attribute nothing
		-- reads, on a save that would then never satisfy the finale's gate,
		-- with the fight looking completed the whole time.
		--
		-- `Cleared_<islandId>` needs no such treatment: it is keyed by island,
		-- and both acts name the same one.
		local heartId = boss.heartAs or boss.id
		if rewards and not BossService.hasHeart(player, heartId) then
			ProgressionService.addCoins(player, math.random(rewards.coins[1], rewards.coins[2]))
			ProgressionService.addXp(player, rewards.xp)
		end
		player:SetAttribute(clearedAttribute(boss.islandId), true)
		player:SetAttribute(BossService.heartAttribute(heartId), true)
	end

	-- What just opened up, for the banner. A site's boss (the Maelstrom - out
	-- of Islands.order, nothing after it) is the FINALE: the client shows the
	-- saga-complete card instead of an unlock line.
	local island = Islands.items[boss.islandId]
	local index = table.find(Islands.order, boss.islandId)
	local nextEntry = index and Islands.items[Islands.order[index + 1] or ""]
	Remotes.CreatureEvent:FireAllClients("bossDown", arenaPosition(boss), {
		name = boss.name,
		unlocks = nextEntry and nextEntry.name or nil,
		finale = (island and island.site) == true or nil,
	})

	-- The ride home from the lair: a beat to take the kill in, then every
	-- participant still standing at the arena is set back on the island.
	local fight = fights[boss.islandId]
	fights[boss.islandId] = nil
	if fight then
		task.delay(RETURN_DELAY, sendHome, fight, boss)
	end
end

-- ============================================================ lifecycle

function BossService.init()
	CreatureService.Killed.Event:Connect(onKilled)

	-- THE SKIP. A participant holding the skip button says "I have seen it";
	-- when every participant STILL IN THE GAME has said so and the boss has not
	-- surfaced yet, it surfaces now, through the same `doRaise` the timer would
	-- have called. Unanimity rather than a majority or a first-past-the-post,
	-- because the cinematic is the fight's opening and one player skipping it
	-- for everybody else is the thing nobody would forgive.
	--
	-- A non-participant is ignored outright: this remote decides when a boss
	-- rises, so it is only ever answered for the people already in that fight.
	Remotes.BossIntroSkip.OnServerEvent:Connect(function(player: Player)
		for _, fight in fights do
			if fight.raised ~= false or not table.find(fight.participants, player) then
				continue
			end
			fight.skipped = fight.skipped or {}
			fight.skipped[player] = true
			local everyone = true
			for _, member in fight.participants do
				if member.Parent == Players and not fight.skipped[member] then
					everyone = false
					break
				end
			end
			local boss = Bosses.items[fight.bossId]
			if everyone and boss then
				doRaise(fight, boss)
			end
		end
	end)

	-- A FIGHT THAT CHANGES ROOMS, and the one direction the dependency can run.
	--
	-- The Kraken's third phase swallows the party: everyone still standing is
	-- moved into the gullet arena, and the collapse at the end puts them back on
	-- the ship. Only this service knows who the participants ARE (`fights`), and
	-- only CreatureService knows when the swallow happens - and CreatureService
	-- cannot require this file, because this file requires CreatureService. So
	-- the fight says "move my party to arena X" on a Bindable and this listens,
	-- the same shape and the same reason as `CreatureService.Killed` above.
	--
	-- `arenaKey` is a BossArenas key, not an island id, which is why it is a
	-- separate argument from `islandId`: the gullet is keyed under an island
	-- that does not exist (see BossArenas), and `ringPositions` is happy to be
	-- asked about any key in that table.
	--
	-- THE THIRD ARGUMENT, and the beat it exists for. Given a player this moves
	-- ONLY that player; given nil it moves the whole party, which is what the
	-- Kraken's swallow has always done and still does byte for byte. The
	-- Pyrelisk's caldera is the reason: the directive's beat is "you have to
	-- like jump in", and a whole-party yank turns the jump into a cutscene. So
	-- CreatureService's shaft watch fires this per player as each one falls
	-- past the trigger, and the design's 30-second grace fires the party form
	-- afterwards as the BACKSTOP for anyone still standing on a summit whose
	-- boss has left.
	--
	-- ONE MOVE PER FIGHT IS STILL THE ASSUMPTION, and the Pyrelisk keeps it:
	-- rim -> heart, once. The shaft is a FALL, not a move. What per-player fire
	-- does change is that the same player can now be named twice - once by
	-- their own jump and once by the grace sweep - so the assumption is
	-- extended explicitly rather than left to hold by luck: a participant
	-- already standing in the destination room is skipped. See ARENA_MOVE_HERE.
	--
	-- PARTICIPATION IS KEYED BY USERID. The Kraken's lane matched an
	-- `extra.name` against `player.Name` and owes a cleanup for it; a display
	-- name is not an identity. Matching on the Player instance would in fact be
	-- stronger still, and is what the loop below really does - but the test is
	-- written against `UserId` so that the day this argument arrives as
	-- anything other than the live instance (a userId off a remote, a record
	-- rebuilt after a rejoin) it keeps meaning the person rather than the
	-- object.
	CreatureService.ArenaMove.Event:Connect(function(islandId: string, arenaKey: string, only: Player?)
		local fight = fights[islandId]
		if not fight then
			return
		end
		-- A NAMED PLAYER WHO IS NOT IN THIS FIGHT IS NOT MOVED. The party form
		-- can only ever name its own participants; the per-player form is fired
		-- from a proximity test, and "whoever is standing in the shaft" is not
		-- the same set as "whoever is in the fight" - a passer-by who is not a
		-- participant has no ride home from a sealed room and must not be put
		-- in one.
		if only then
			local found = false
			for _, candidate in fight.participants do
				if candidate.UserId == only.UserId then
					found = true
					break
				end
			end
			if not found then
				return
			end
		end
		-- THE RING IS ALWAYS THE PARTY'S, even when one player is moving, so
		-- the spot a given participant lands on is the same whether they
		-- arrived with everyone or alone. Sizing it to 1 per arrival would put
		-- every straggler on ring[1] - the pad's own centre - and stack a party
		-- that jumped in one at a time into a single column.
		--
		-- THE RADIUS IS NO LONGER A BARE 0. It was, because both arenas the
		-- Kraken moves between author a `spawnPad`, which overrides it - and
		-- the comment that stood here called a fight relocating somewhere
		-- WITHOUT a pad "the honest fallback rather than a silent miss". It is
		-- neither, and the Pyrelisk's ride home is the case that proves it: the
		-- heart's victory recall fires `ArenaMove(volcano, volcano)` (the
		-- `krakenheart` gimmick's shape), the volcano row has no pad, and a
		-- radius of 0 rings the CENTRE COLUMN of the Ashfall Throne - which is
		-- the lava lake, which does not collide, over a caldera that is by then
		-- open. The party would be dropped 292 studs through the arena into the
		-- sea by the ride home. So ask the destination's own boss how wide its
		-- fight is; where a pad exists this is still overridden and nothing
		-- changes for the Kraken.
		local destination = Bosses.byIsland[arenaKey]
		local radius = if destination then destination.arena.radius else 0
		local ring = BossArenaService.ringPositions(arenaKey, #fight.participants, radius)
		local here = BossArenaService.centerFor(arenaKey)
		for i, member in fight.participants do
			-- The dead are skipped rather than resurrected into the new room:
			-- they respawned at the world spawn and are out of this fight until
			-- they walk back, exactly as `sendHome` already rules.
			local character = member.Parent == Players and member.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local wanted = (only == nil) or (member.UserId == only.UserId)
			-- ...and, ON THE PARTY FORM ONLY, so is anyone already in the
			-- room. See ARENA_MOVE_HERE.
			--
			-- THE PER-PLAYER FORM IS NEVER SKIPPED, and the asymmetry is the
			-- whole point rather than a shortcut. The party form is a SWEEP -
			-- "bring in whoever is left" - so it has to be able to run over
			-- people it must not touch, and the grace is fired thirty seconds
			-- after half the party has already jumped. The per-player form is
			-- one deliberate, already-filtered request about one body that has
			-- just fallen past a trigger, and a proximity guard on it would
			-- veto the move it was fired to make: slice 5 ships the shaft
			-- pointed at "volcano" itself, so that the transport can be proved
			-- before the heart room exists - and on that target the falling
			-- player is INSIDE the destination's own radius by definition.
			-- Skipping them would make the inert stage silently do nothing,
			-- which is the exact failure this slice exists to rule out.
			local settled = false
			if only == nil and here and root then
				settled = Vector3.new(root.Position.X - here.X, 0, root.Position.Z - here.Z).Magnitude
					<= ARENA_MOVE_HERE
			end
			if wanted and not settled and humanoid and humanoid.Health > 0 and ring[i] then
				moveTo(member, ring[i])
			end
		end
	end)

	-- THE WAY BACK IS NOT THIS SERVICE'S, and that is a decision rather than an
	-- omission. When the Ashfall Heart dies the party is sealed in a chamber
	-- 40,000 studs from the island, and something has to fire the collapse, drop
	-- `FightCenter` and put them back on the summit before `RETURN_DELAY` - but
	-- that something is the heart creature's own `gimmick` (`K.GIMMICKS`, the
	-- `krakenheart` shape one boss over), not a second recall here. Two reasons,
	-- and the second is the one that matters:
	--   * the gimmick's `onKill` runs at the death, inside CreatureService,
	--     where the collapse beat and the attribute it clears already live;
	--   * `onKilled` below pays out, banners and then `task.delay`s `sendHome`
	--     by RETURN_DELAY. A recall added here would have to race that delay to
	--     put people somewhere `sendHome` can still measure them, and a recall
	--     that lost the race would silently take nobody anywhere - `sendHome`'s
	--     proximity filter excludes exactly the people it failed to move. The
	--     gimmick fires first, by construction, so RETURN_DELAY keeps working
	--     untouched.
	-- The `pyreliskheart` gimmick is the slice-4/6 creature lane's; its spec is
	-- in this slice's HANDOFF.

	-- A leaver is out of the fight; the abandon reaper below handles a fight
	-- this empties. The boss's health is NOT rescaled down - party scaling is
	-- fixed at summon, on purpose. A mid-fight rescale would be the obvious
	-- exploit: bring six bodies for the ring positions, have five leave (or
	-- leave-and-rejoin) once the fight is up, and fight a boss that shrinks
	-- back to solo health. Health also cannot be lowered honestly mid-fight
	-- anyway - the phase thresholds and every enrage-below test read
	-- health/maxHealth, so moving maxHealth re-triggers phases.
	Players.PlayerRemoving:Connect(function(player)
		for _, fight in fights do
			local index = table.find(fight.participants, player)
			if index then
				table.remove(fight.participants, index)
			end
		end
	end)
end

function BossService.start()
	-- No polling for RAISES: the boss only rises when summoned (summonFor,
	-- off the capstone bait's cast). The earlier auto-raise (first qualifying
	-- player on the island) was replaced on 2026-08-23 so the summon is a
	-- deliberate ritual rather than an ambush.
	--
	-- The abandon reaper: a lair fight whose participants are all dead, gone,
	-- or fled sinks its boss back into the sea, so the island can summon
	-- again. (Before the lair arenas, an abandoned boss lingered forever.)
	task.spawn(function()
		local emptySince: { [string]: number } = {}
		while true do
			task.wait(2)
			local now = os.clock()
			for islandId, fight in fights do
				local model = active[islandId]
				local boss = Bosses.items[fight.bossId]
				-- "The model went without a win" - but NOT while an intro
				-- cinematic is still running, because during those seconds there
				-- is deliberately no model yet and this branch would reap the
				-- fight (and teleport the party home) out from under the
				-- cutscene it is watching. `raised ~= false` rather than
				-- `raised`: every fight record written by any other path has no
				-- such field, and nil has to keep meaning "raised", or this test
				-- would silently stop firing for every boss without a row.
				if not boss or (not model and fight.raised ~= false) then
					-- The boss went without a win (something else despawned or
					-- destroyed the model). The fight record was dropped here in
					-- silence, which strands anyone the summon CARRIED out to the
					-- arena: no boat, no boss, no ride home. Send them back first.
					if boss and fight then
						sendHome(fight, boss)
					end
					fights[islandId] = nil
					emptySince[islandId] = nil
					continue
				end
				-- Never reap a fight still rising / gathering itself - and an
				-- intro cinematic is part of "still starting up": the party is
				-- standing in the ring with their camera taken away and cannot
				-- prove they are present by walking. `introUntil` is absent on
				-- every fight without a cutscene, which makes this the number it
				-- has always been for them.
				local intro = if fight.introUntil then math.max(0, fight.introUntil - fight.startedAt) else 0
				if now - fight.startedAt < intro + boss.riseTime + ABANDON_GRACE then
					continue
				end
				-- ...and the reaper asks the same relocated question the ride
				-- home does: a party fighting phase three of the Kraken is
				-- 20,000 studs from where its boss rose, and measuring presence
				-- against the summon point would reap the fight out from under
				-- them. See `fightCenter`.
				local center = fightCenter(boss)
				local present = 0
				for _, member in fight.participants do
					local character = member.Parent == Players and member.Character
					local root = character and character:FindFirstChild("HumanoidRootPart")
					local humanoid = character and character:FindFirstChildOfClass("Humanoid")
					if root and humanoid and humanoid.Health > 0 then
						local d = Vector3.new(root.Position.X - center.X, 0, root.Position.Z - center.Z).Magnitude
						if d <= boss.arena.radius + ABANDON_RADIUS then
							present += 1
						end
					end
				end
				if present > 0 then
					emptySince[islandId] = nil
				elseif not emptySince[islandId] then
					emptySince[islandId] = now
				elseif now - emptySince[islandId] >= ABANDON_SECONDS then
					emptySince[islandId] = nil
					fights[islandId] = nil
					-- Through CreatureService, not model:Destroy(): destroying
					-- the Model alone leaves the creature struct running
					-- forever - still attacking, still damaging anyone who
					-- comes back - while this island happily summons a second
					-- boss on top of the invisible one.
					CreatureService.despawn(model) -- AncestryChanged clears active[islandId]
				end
			end
		end
	end)
end

return BossService
