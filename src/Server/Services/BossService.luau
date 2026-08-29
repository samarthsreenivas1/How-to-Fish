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
--     rewards (the killer already gets them through ProgressionService), the
--     replicated `Cleared_<islandId>` attribute (WorldService's travel gate
--     reads it), and the `Heart_<bossId>` attribute - the boss's heart, a
--     permanent trophy that recipes gate on (Recipe.requiresHearts) and that
--     the final summon will one day count. Hearts are owned, never spent.
--   - a "bossDown" CreatureEvent names what just opened up.
--
-- Cleared_* and Heart_* persist through DataService, which scans and restores
-- these attribute prefixes as part of the profile.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Islands = require(Shared.Config.Islands)
local World = require(Shared.Config.World)
local Bosses = require(Shared.Data.Bosses)
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
	-- Lair islands fight at their arena out in the ocean; the rest (the
	-- Kraken's whirlpool site) keep the old spot beside the island.
	local center = BossArenaService.centerFor(boss.islandId)
	if center then
		return Vector3.new(center.X, World.WATER_Y, center.Z)
	end
	local island = Islands.items[boss.islandId]
	local origin = if island then island.worldPosition else Vector3.zero
	return Vector3.new(origin.X + boss.arena.offset.X, World.WATER_Y, origin.Z + boss.arena.offset.Z)
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
-- SUMMON_GATHER_RADIUS on the same island) - standing that close to a Call
-- being cast is the invitation.
local function gatherParty(summoner: Player, islandId: string): { Player }
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

local function raise(boss): Model?
	local row = Creatures.items[boss.creature]
	if not row then
		warn(string.format("[BossService] boss %q names unknown creature row %q", boss.id, boss.creature))
		return nil
	end
	-- No throw target: it surfaces where it's put and the boss archetype plays
	-- its own rise from the deep (Bosses.riseDepth / riseTime).
	local model = CreatureService.spawn(row, arenaPosition(boss), nil, "Neutral")
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
		if onIsland(player, boss.islandId) then
			return boss
		end
	end
	return nil
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
	if active[boss.islandId] then
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

	if not raise(boss) then
		return false, "Nothing answers the call here"
	end

	-- A lair island: the call drags the summoner and everyone standing with
	-- them to the boss's arena out in the open sea. Deferred so the cast's
	-- CastResolved { summoned } reaches the client and closes the cast BEFORE
	-- the camera jumps. Fight-in-place islands (no arena row) skip all this.
	if BossArenaService.centerFor(boss.islandId) then
		local party = gatherParty(player, boss.islandId)
		fights[boss.islandId] = {
			bossId = boss.id,
			participants = party,
			startedAt = os.clock(),
		}
		local ring = BossArenaService.ringPositions(boss.islandId, #party, boss.arena.radius + 8)
		task.defer(function()
			for i, member in party do
				if member.Parent == Players and ring[i] then
					moveTo(member, ring[i])
				end
			end
		end)
	end
	return true
end

-- ============================================================ the win

local function onKilled(row, _grade: string, killer: Player?, extra)
	local boss = row.boss and Bosses.items[row.boss]
	if not boss then
		return
	end

	-- Everyone who hit it shares the win (and the payout; the killer's came
	-- through ProgressionService already).
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

	local rewards = row.rewards
	for _, player in winners do
		if rewards and player ~= killer then
			ProgressionService.addCoins(player, math.random(rewards.coins[1], rewards.coins[2]))
			ProgressionService.addXp(player, rewards.xp)
		end
		player:SetAttribute(clearedAttribute(boss.islandId), true)
		player:SetAttribute(BossService.heartAttribute(boss.id), true)
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
	-- participant still standing at the arena is set back on the island. The
	-- proximity filter quietly excludes the dead (they respawned at the world
	-- spawn) and anyone who already travelled out.
	local fight = fights[boss.islandId]
	fights[boss.islandId] = nil
	if fight then
		local center = arenaPosition(boss)
		local nearLimit = boss.arena.radius + RETURN_NEAR
		task.delay(RETURN_DELAY, function()
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
		end)
	end
end

-- ============================================================ lifecycle

function BossService.init()
	CreatureService.Killed.Event:Connect(onKilled)

	-- A leaver is out of the fight; the abandon reaper below handles a fight
	-- this empties.
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
				if not model or not boss then
					fights[islandId] = nil
					emptySince[islandId] = nil
					continue
				end
				-- Never reap a fight still rising / gathering itself.
				if now - fight.startedAt < boss.riseTime + ABANDON_GRACE then
					continue
				end
				local center = arenaPosition(boss)
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
					-- Guarded because the two halves cannot land together:
					-- CreatureService currently carries another lane's
					-- in-flight work, so `despawn` may not exist at this
					-- commit. Falling back to the old behaviour is wrong but
					-- survivable; calling a nil function would kill this
					-- reaper loop outright and leave EVERY abandoned boss up.
					-- Drop the guard once the CreatureService half lands.
					local despawn = (CreatureService :: any).despawn
					if despawn then
						despawn(model)
					else
						model:Destroy()
					end -- AncestryChanged clears active[islandId]
				end
			end
		end
	end)
end

return BossService
