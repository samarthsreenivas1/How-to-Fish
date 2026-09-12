--!nonstrict
-- NpcMarkerController.luau
-- The gold "!" over a villager's head. Every NPC body the server places lives
-- in Workspace/Npcs as Npc_<id> with an NpcId attribute (NpcService's half of
-- the contract); this hangs a BillboardGui "QuestMarker" on each one and keeps
-- it honest:
--
--   gold "!"  - this NPC has a quest you could take RIGHT NOW
--   gold "?"  - a quest of theirs is finished and waiting to be turned in
--   dim  "?"  - a quest of theirs is underway
--   nothing   - no business with them
--
-- The state is computed CLIENT-SIDE, mirroring QuestService.offersFor over the
-- quest snapshot QuestController already holds (prereq completed, level from
-- the player's replicated Level attribute, a daily's UTC-day rollover). That
-- keeps the marker free - no remote, no per-NPC server work - at the price of
-- this file having to stay in step with offersFor. It is a HINT, not a
-- permission: the server re-decides everything when you actually talk, so a
-- marker that lies for a frame costs nothing.
--
-- Recomputed on: a quest snapshot change (QuestController.Changed), a Level
-- change, a new body appearing, and once a minute (the daily rollover is a
-- clock event nothing else announces).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

-- TIMED, not an open-ended wait: a controller that blocks here never returns
-- from `require`, and the client boot loop is sequential - one infinite
-- WaitForChild in one controller is a game with no UI and no error in Output.
-- With a timeout the assert names the problem instead.
local Shared = ReplicatedStorage:WaitForChild("Shared", 30)
assert(Shared, "[NpcMarkerController] ReplicatedStorage/Shared never replicated")
local Npcs = require(Shared.Data.Npcs)
local Quests = require(Shared.Data.Quests)
local Progression = require(Shared.Modules.Progression)

local QuestController = require(script.Parent.QuestController)

local player = Players.LocalPlayer

local NpcMarkerController = {}

-- Far enough to read across a hut clearing or from a boat coming in; the
-- nameplate stops at 70, so the marker is what pulls you over.
local MARKER_DISTANCE = 140
local ROLLOVER_POLL = 60

local GOLD = Color3.fromRGB(255, 206, 84)
local DIM = Color3.fromRGB(186, 194, 204)

local markers: { [string]: BillboardGui } = {}
local folder: Folder? = nil

-- ============================================================ availability

-- Mirrors QuestService's progress reading: the snapshot's progress table may
-- arrive int-keyed (the live push) or string-keyed (a profile round-trip).
local function progressAt(entry, index: number): number
	local progress = if type(entry) == "table" then entry.progress else nil
	if type(progress) ~= "table" then
		return 0
	end
	return tonumber(progress[index]) or tonumber(progress[tostring(index)]) or 0
end

-- Mirrors QuestService.allObjectivesDone: a "deliver" objective is checked
-- (and spent) at turn-in, never tracked live, so it never blocks readiness.
local function allDone(quest, entry): boolean
	for index, objective in quest.objectives do
		if objective.type ~= "deliver" and progressAt(entry, index) < (objective.count or 1) then
			return false
		end
	end
	return true
end

-- nil | "available" | "ready" | "active", strongest first.
local function stateFor(npcId: string): string?
	local npc = Npcs.items[npcId]
	if not npc or type(npc.quests) ~= "table" then
		return nil
	end
	local snapshot = QuestController.getSnapshot and QuestController.getSnapshot()
	if type(snapshot) ~= "table" then
		return nil
	end
	local active = if type(snapshot.active) == "table" then snapshot.active else {}
	local completed = if type(snapshot.completed) == "table" then snapshot.completed else {}
	local level = player:GetAttribute(Progression.ATTR.level) or Progression.START_LEVEL
	local today = math.floor(os.time() / 86400)

	local anyActive = false
	local anyAvailable = false
	for _, questId in npc.quests do
		local quest = Quests.items[questId]
		if quest then
			local entry = active[questId]
			local completedAt = completed[questId]
			if entry then
				if allDone(quest, entry) then
					return "ready" -- a turn-in outranks everything else they have
				end
				anyActive = true
			else
				local repeatableNow = quest.repeatable
					and (quest.repeatable ~= "daily" or not completedAt or math.floor(completedAt / 86400) < today)
				if not completedAt or repeatableNow then
					local levelOk = not quest.requiresLevel or level >= quest.requiresLevel
					local prereqOk = not quest.prereq or completed[quest.prereq] ~= nil
					if levelOk and prereqOk then
						anyAvailable = true
					end
				end
			end
		end
	end
	if anyAvailable then
		return "available"
	end
	return if anyActive then "active" else nil
end

-- ============================================================ the billboard

local function mountFor(model: Model): BasePart?
	local head = model:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head
	end
	return model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
end

local function buildMarker(model: Model): BillboardGui?
	local mount = mountFor(model)
	if not mount then
		return nil
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "QuestMarker"
	gui.Size = UDim2.fromOffset(44, 56)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 2.6, 0)
	gui.MaxDistance = MARKER_DISTANCE
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	local glyph = Instance.new("TextLabel")
	glyph.Name = "Glyph"
	glyph.BackgroundTransparency = 1
	glyph.Size = UDim2.fromScale(1, 1)
	glyph.Font = Enum.Font.GothamBlack
	glyph.TextSize = 40
	glyph.TextStrokeTransparency = 0.1
	glyph.TextStrokeColor3 = Color3.fromRGB(18, 22, 28)
	glyph.Text = "!"
	glyph.Parent = gui
	gui.Parent = mount
	return gui
end

local function paint(npcId: string, gui: BillboardGui)
	local state = stateFor(npcId)
	local glyph = gui:FindFirstChild("Glyph")
	if not (glyph and glyph:IsA("TextLabel")) then
		return
	end
	if state == "available" then
		glyph.Text = "!"
		glyph.TextColor3 = GOLD
	elseif state == "ready" then
		glyph.Text = "?"
		glyph.TextColor3 = GOLD
	elseif state == "active" then
		glyph.Text = "?"
		glyph.TextColor3 = DIM
	end
	gui.Enabled = state ~= nil
end

local function refreshAll()
	for npcId, gui in markers do
		if gui.Parent then
			paint(npcId, gui)
		else
			markers[npcId] = nil
		end
	end
end

local function track(child: Instance)
	if not child:IsA("Model") then
		return
	end
	local npcId = child:GetAttribute("NpcId")
	if type(npcId) ~= "string" then
		return
	end
	-- The body is built and parented in one go server-side, but the parts
	-- replicate on their own schedule: retry briefly rather than mount on
	-- whatever part happened to arrive first.
	task.spawn(function()
		for _ = 1, 20 do
			if not child.Parent then
				return
			end
			if child:FindFirstChild("Head") or child.PrimaryPart then
				break
			end
			task.wait(0.25)
		end
		if not child.Parent or markers[npcId] then
			return
		end
		local gui = buildMarker(child)
		if gui then
			markers[npcId] = gui
			paint(npcId, gui)
		end
	end)
end

local function untrack(child: Instance)
	local npcId = child:GetAttribute("NpcId")
	if type(npcId) == "string" then
		markers[npcId] = nil
	end
end

local function watchFolder(candidate: Instance)
	if candidate.Name ~= "Npcs" or not candidate:IsA("Folder") then
		return
	end
	-- A folder we are already bound to is skipped, but one that has since left
	-- Workspace is NOT: the server creates Workspace/Npcs lazily (the first NPC
	-- that places), and a rebuild replaces the instance. Latching onto the first
	-- folder forever meant no markers at all after that.
	if folder == candidate or (folder and folder.Parent) then
		return
	end
	folder = candidate
	candidate.ChildAdded:Connect(track)
	candidate.ChildRemoved:Connect(untrack)
	for _, child in candidate:GetChildren() do
		track(child)
	end
end

-- Belt and braces for the folder appearing between the FindFirstChild below and
-- the ChildAdded connect, and for a body that arrived while we were not looking:
-- re-scanning is idempotent (track bails on an id that already has a marker).
local function rescan()
	local candidate = Workspace:FindFirstChild("Npcs")
	if candidate then
		watchFolder(candidate)
		for _, child in candidate:GetChildren() do
			if child:IsA("Model") and not markers[tostring(child:GetAttribute("NpcId"))] then
				track(child)
			end
		end
	end
end

-- ============================================================ lifecycle

function NpcMarkerController.start()
	-- The folder appears when the server finishes placing (which waits on the
	-- island meshes and now on a retry window), so it can well be after the
	-- client boots. Connect FIRST, then scan, so nothing slips through the gap.
	Workspace.ChildAdded:Connect(watchFolder)
	rescan()

	if QuestController.Changed then
		QuestController.Changed.Event:Connect(refreshAll)
	end
	player:GetAttributeChangedSignal(Progression.ATTR.level):Connect(refreshAll)

	-- A daily quest coming back around is a clock event with no signal behind
	-- it; a minute of staleness on a once-a-day change is invisible.
	task.spawn(function()
		while true do
			task.wait(ROLLOVER_POLL)
			-- Also the late-body safety net: a server-side retry that places an
			-- NPC a minute into the session gets a marker without a signal.
			rescan()
			refreshAll()
		end
	end)
end

return NpcMarkerController
