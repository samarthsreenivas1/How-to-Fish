--!nonstrict
-- QuestService.luau
-- Quest state, progress and rewards (rows in Shared/Data/Quests.luau). All
-- server-owned: the client only ever sees pushes and echoes choice ids.
--
--   - State per player: { active = { [questId] = { progress = {n,...} } },
--     completed = { [questId] = completedAt } }, persisted as the "quests"
--     DataService slice (ids validated against Quests.items on load, the
--     MaterialService habit, so cut quests drop out of old profiles).
--   - Progress arrives through QuestService.notify(kind, payload) - a small
--     funnel called from a handful of one-line sites (FishingService's
--     resolveCast for "catch"; kill/craft/visit arrive with their slice).
--     An event ticks EVERY matching objective on every active quest.
--   - Offer/accept/turn-in run through NpcService's dialog: this service
--     answers "what can this NPC offer this player" and performs the
--     transitions; NpcService owns proximity and panes.
--
-- Replication is the materials idiom: GetQuests (pull once), QuestsUpdated
-- (full push on any change), QuestProgress (delta - the HUD pop).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Islands = require(Shared.Config.Islands)
local Quests = require(Shared.Data.Quests)
local Remotes = require(Shared.Net.Remotes)
local Progression = require(Shared.Modules.Progression)

local DataService = require(script.Parent.DataService)
local MaterialService = require(script.Parent.MaterialService)
local BaitService = require(script.Parent.BaitService)
local InventoryService = require(script.Parent.InventoryService)
local CreatureService = require(script.Parent.CreatureService)

-- ProgressionService sits BELOW this service in ORDER (it must boot after
-- CreatureService to hear Killed), so it is required lazily at reward time:
-- addCoins/addXp have no init-order dependence, and the first turn-in
-- happens long after boot.
local ProgressionService = nil
local function progression()
	if not ProgressionService then
		ProgressionService = require(script.Parent.ProgressionService)
	end
	return ProgressionService
end

local QuestService = {}

local state: { [Player]: { active: { [string]: any }, completed: { [string]: number } } } = {}

-- Which island each player was last seen standing on, for the "visit"
-- objective: the poller below notifies on CHANGE, so a quest accepted while
-- already standing there still needs a genuine arrival... except it
-- doesn't - the poller seeds nil, so the first tick after accept counts
-- the island you're on. Deliberate: "set foot on the fen" reading as
-- already-done for someone standing in the fen is correct, not a bug.
local lastIsland: { [Player]: string? } = {}

-- How often the visit poller looks. Islands.islandAt is pure math over a
-- handful of entries; 3s is generous for an objective about arriving.
local VISIT_POLL = 3.0

-- ============================================================ replication

local function snapshot(player: Player)
	local s = state[player]
	if not s then
		return { active = {}, completed = {} }
	end
	return { active = s.active, completed = s.completed }
end

local function push(player: Player)
	Remotes.QuestsUpdated:FireClient(player, snapshot(player))
end

-- ============================================================ matching

-- Does this objective care about this event? Filters are AND; absent = any.
local function objectiveMatches(objective, kind: string, payload): boolean
	if objective.type ~= kind then
		return false
	end
	if kind == "catch" or kind == "kill" then
		if objective.species and objective.species ~= payload.species then
			return false
		end
		if objective.rarity and objective.rarity ~= payload.rarity then
			return false
		end
		if objective.waters and objective.waters ~= payload.waters then
			return false
		end
		return true
	end
	if kind == "craft" then
		return objective.itemId == payload.itemId
	end
	if kind == "visit" then
		return objective.island == payload.island
	end
	return false
end

local function objectiveDone(quest, entry, index: number): boolean
	local objective = quest.objectives[index]
	if objective.type == "deliver" then
		return true -- checked (and spent) at turn-in, never tracked live
	end
	return (entry.progress[index] or 0) >= (objective.count or 1)
end

local function allObjectivesDone(quest, entry): boolean
	for index in quest.objectives do
		if not objectiveDone(quest, entry, index) then
			return false
		end
	end
	return true
end

-- The progress funnel. kind: "catch" | "kill" | "craft" | "visit";
-- payload: { player, species?, rarity?, waters?, itemId?, island? }.
function QuestService.notify(kind: string, payload)
	local player = payload.player
	local s = player and state[player]
	if not s then
		return
	end
	for questId, entry in s.active do
		local quest = Quests.items[questId]
		if quest then
			for index, objective in quest.objectives do
				if objectiveMatches(objective, kind, payload) and not objectiveDone(quest, entry, index) then
					entry.progress[index] = (entry.progress[index] or 0) + 1
					Remotes.QuestProgress:FireClient(player, {
						questId = questId,
						name = quest.name,
						objectiveIndex = index,
						count = entry.progress[index],
						needed = objective.count or 1,
						done = objectiveDone(quest, entry, index),
						ready = allObjectivesDone(quest, entry),
					})
				end
			end
		end
	end
end

-- ============================================================ offer / accept / turn-in

-- What this NPC has for this player right now, in the giver's listed order.
-- status: "available" | "active" (ready = every objective done) | nil (gated
-- or already completed and not repeatable - not shown at all).
function QuestService.offersFor(player: Player, npc): { { quest: any, status: string, ready: boolean? } }
	local out = {}
	local s = state[player]
	if not s or not npc.quests then
		return out
	end
	for _, questId in npc.quests do
		local quest = Quests.items[questId]
		if quest then
			local entry = s.active[questId]
			-- A daily re-offers only once the UTC day has turned since its
			-- last turn-in; the completed timestamp is the whole clock.
			local completedAt = s.completed[questId]
			local repeatableNow = quest.repeatable
				and (
					quest.repeatable ~= "daily"
					or not completedAt
					or math.floor(completedAt / 86400) < math.floor(os.time() / 86400)
				)
			if entry then
				table.insert(out, { quest = quest, status = "active", ready = allObjectivesDone(quest, entry) })
			elseif not completedAt or repeatableNow then
				local levelOk = not quest.requiresLevel
					or (player:GetAttribute(Progression.ATTR.level) or Progression.START_LEVEL)
						>= quest.requiresLevel
				local prereqOk = not quest.prereq or s.completed[quest.prereq] ~= nil
				if levelOk and prereqOk then
					table.insert(out, { quest = quest, status = "available" })
				end
			end
		end
	end
	return out
end

function QuestService.accept(player: Player, questId: string): boolean
	local s = state[player]
	local quest = Quests.items[questId]
	if not (s and quest) or not DataService.isLoaded(player) then
		return false
	end
	if s.active[questId] then
		return false
	end
	local completedAt = s.completed[questId]
	if completedAt then
		if not quest.repeatable then
			return false
		end
		if quest.repeatable == "daily" and math.floor(completedAt / 86400) >= math.floor(os.time() / 86400) then
			return false
		end
	end
	s.active[questId] = { progress = {} }
	push(player)
	return true
end

-- Turn-in: every objective done, deliver costs spendable - then pay out.
-- Returns ok plus a player-facing refusal.
function QuestService.tryTurnIn(player: Player, questId: string): (boolean, string?)
	local s = state[player]
	local quest = Quests.items[questId]
	local entry = s and s.active[questId]
	if not (quest and entry) or not DataService.isLoaded(player) then
		return false, "Nothing to turn in."
	end
	if not allObjectivesDone(quest, entry) then
		return false, "That work isn't finished yet."
	end
	for _, objective in quest.objectives do
		if objective.type == "deliver" then
			if not MaterialService.spend(player, objective.materials or {}) then
				return false, "You don't have the goods on you."
			end
		end
	end

	local rewards = quest.rewards or {}
	if rewards.coins then
		progression().addCoins(player, rewards.coins)
	end
	if rewards.xp then
		progression().addXp(player, rewards.xp)
	end
	for matId, amount in rewards.materials or {} do
		MaterialService.grant(player, matId, amount)
	end
	for baitId, amount in rewards.bait or {} do
		BaitService.grant(player, baitId, amount)
	end
	-- Finished items (armor pieces, rods, weapons, trinkets) - granted by
	-- id; already-owned ids are InventoryService no-ops.
	for _, itemId in rewards.items or {} do
		InventoryService.grantItem(player, itemId)
	end

	s.active[questId] = nil
	s.completed[questId] = os.time()
	push(player)
	return true
end

-- ============================================================ persistence

local function loadSlice(player: Player, slice)
	if type(slice) ~= "table" then
		return
	end
	local s = state[player]
	if not s then
		return
	end
	if type(slice.completed) == "table" then
		for questId, at in slice.completed do
			if Quests.items[questId] and tonumber(at) then
				s.completed[questId] = tonumber(at)
			end
		end
	end
	if type(slice.active) == "table" then
		for questId, entry in slice.active do
			local quest = Quests.items[questId]
			if quest and type(entry) == "table" then
				local progress = {}
				for index in quest.objectives do
					progress[index] = math.max(
						0,
						math.floor(tonumber(type(entry.progress) == "table" and entry.progress[index]) or 0)
					)
				end
				s.active[questId] = { progress = progress }
			end
		end
	end
	push(player)
end

local function serializeSlice(player: Player)
	local s = state[player]
	if not s then
		return { active = {}, completed = {} }
	end
	-- progress is a sparse int-keyed table; store it string-keyed so JSON
	-- round-trips it safely, and re-read it either way (tonumber on load
	-- handles both shapes).
	local active = {}
	for questId, entry in s.active do
		local progress = {}
		for index, count in entry.progress do
			progress[tostring(index)] = count
		end
		active[questId] = { progress = progress }
	end
	return { active = active, completed = table.clone(s.completed) }
end

-- ============================================================ lifecycle

local function onPlayerAdded(player: Player)
	state[player] = { active = {}, completed = {} }
	push(player)
end

function QuestService.init()
	DataService.register("quests", {
		load = function(player, slice)
			-- The sparse progress table may arrive string-keyed (see
			-- serializeSlice); normalise before the typed load.
			if type(slice) == "table" and type(slice.active) == "table" then
				for _, entry in slice.active do
					if type(entry) == "table" and type(entry.progress) == "table" then
						local fixed = {}
						for key, value in entry.progress do
							local index = tonumber(key)
							if index then
								fixed[index] = value
							end
						end
						entry.progress = fixed
					end
				end
			end
			loadSlice(player, slice)
		end,
		serialize = serializeSlice,
		release = function(player: Player)
			state[player] = nil
			lastIsland[player] = nil
		end,
	})
	Remotes.GetQuests.OnServerInvoke = function(player: Player)
		return snapshot(player)
	end
end

function QuestService.start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	-- Kills: subscribe to the Killed event ourselves (the Progression /
	-- Material precedent) - zero edits to combat code. `killer` may be nil
	-- (an explosion chain, a raid clear); only a real player progresses.
	CreatureService.Killed.Event:Connect(function(row, _grade, killer)
		if typeof(killer) == "Instance" and killer:IsA("Player") then
			QuestService.notify("kill", { player = killer, species = row.id, rarity = row.rarity })
		end
	end)

	-- Visits: poll each player's island and notify on change. This catches
	-- BOTH arrival paths - the travel menu and sailing in by boat - with no
	-- edits to WorldService.
	task.spawn(function()
		while true do
			task.wait(VISIT_POLL)
			for _, player in Players:GetPlayers() do
				if state[player] then
					local character = player.Character
					local root = character and character:FindFirstChild("HumanoidRootPart")
					if root then
						local here = Islands.islandAt(root.Position)
						if here and here ~= lastIsland[player] then
							lastIsland[player] = here
							QuestService.notify("visit", { player = player, island = here })
						end
					end
				end
			end
		end
	end)
end

return QuestService
