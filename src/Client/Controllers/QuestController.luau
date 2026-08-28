--!nonstrict
-- QuestController.luau
-- The quest log (J, or the bottom-left QUESTS button) and the on-screen
-- tracker. Both are pure readers of the server's quest snapshot: GetQuests
-- pulls it once on start (in case the push raced the boot), QuestsUpdated
-- replaces it wholesale, and QuestProgress deltas update the tracker live
-- plus drive the HUD pop (taken over from NpcDialogController, which
-- carried it through A2).
--
--   Log: one card per active quest - name, giver, a line per objective
--   with its count - and a completed tally underneath. Accept/turn-in stay
--   in the NPC dialog on purpose: the log is where you check, the person
--   is where you deal.
--
--   Tracker: a compact top-left readout of the FIRST active quest's
--   objectives, visible whenever something is in progress and no menu is
--   open. Deliberately small: name + "n/m" lines, no bars.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local Quests = require(Shared.Data.Quests)
local Npcs = require(Shared.Data.Npcs)

local Theme = require(script.Parent.Parent.UI.Theme)
local Kit = require(script.Parent.Parent.UI.Kit)
local CameraController = require(script.Parent.CameraController)
local ProgressionController = require(script.Parent.ProgressionController)

local player = Players.LocalPlayer

local QuestController = {}

local C = Theme.Color
local F = Theme.Font

local TOGGLE_ACTION = "QuestLogToggle"

local snapshot = { active = {}, completed = {} }

local modal
local list: ScrollingFrame
local tally: TextLabel
local trackerGui: ScreenGui
local trackerFrame: Frame

-- ============================================================ helpers

-- Objective text mirrors the server's dialog wording, kept deliberately
-- shorter here (the log lists many at once).
local function objectiveLine(objective, count: number): string
	local needed = objective.count or 1
	local desc
	if objective.type == "catch" then
		desc = objective.species
			or objective.rarity
			or (objective.waters and objective.waters .. " catches")
			or "catches"
		desc = "Catch " .. desc
	elseif objective.type == "kill" then
		desc = "Slay " .. (objective.species or objective.rarity or "creatures")
	elseif objective.type == "craft" then
		return string.format("Craft %s", tostring(objective.itemId))
	elseif objective.type == "deliver" then
		return "Deliver goods at turn-in"
	elseif objective.type == "visit" then
		return string.format("Visit %s", tostring(objective.island))
	else
		desc = "?"
	end
	return string.format("%s  %d/%d", desc, math.min(count, needed), needed)
end

local function activeInOrder(): { { id: string, quest: any, entry: any } }
	local out = {}
	for questId, entry in snapshot.active do
		local quest = Quests.items[questId]
		if quest then
			table.insert(out, { id = questId, quest = quest, entry = entry })
		end
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

local function progressOf(entry, index: number): number
	local progress = type(entry) == "table" and entry.progress
	if type(progress) ~= "table" then
		return 0
	end
	return tonumber(progress[index]) or tonumber(progress[tostring(index)]) or 0
end

-- ============================================================ log modal

local function renderLog()
	if not modal then
		return
	end
	for _, child in list:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	local actives = activeInOrder()
	for order, item in actives do
		local giver = Npcs.items[item.quest.giver]
		-- Kit.card is a square tile; a log row is a full-width strip.
		local card = Kit.frame(list, {
			Name = "Quest_" .. item.id,
			BackgroundTransparency = 0.12,
			BackgroundColor3 = Color3.fromRGB(238, 234, 224),
			Size = UDim2.new(1, -8, 0, 56 + #item.quest.objectives * 20),
		})
		Kit.corner(card, 10)
		Kit.stroke(card, Theme.Color.ink, 1.5, 0.5)
		card.LayoutOrder = order
		Kit.label(card, {
			Name = "Name",
			Font = F.header,
			TextSize = 17,
			TextColor3 = C.text,
			Text = item.quest.name,
			Position = UDim2.new(0, 14, 0, 8),
			Size = UDim2.new(1, -28, 0, 22),
		})
		Kit.label(card, {
			Name = "Giver",
			Font = F.body,
			TextSize = 13,
			TextColor3 = C.textDim,
			Text = if giver then string.format("for %s, %s", giver.name, giver.title) else "",
			Position = UDim2.new(0, 14, 0, 30),
			Size = UDim2.new(1, -28, 0, 16),
		})
		for index, objective in item.quest.objectives do
			local done = progressOf(item.entry, index) >= (objective.count or 1) or objective.type == "deliver"
			Kit.label(card, {
				Name = string.format("Objective%d", index),
				Font = F.bodyBold,
				TextSize = 14,
				TextColor3 = if done then C.green else C.text,
				Text = (if done then "  [done] " else "  - ")
					.. objectiveLine(objective, progressOf(item.entry, index)),
				Position = UDim2.new(0, 14, 0, 48 + (index - 1) * 20),
				Size = UDim2.new(1, -28, 0, 18),
			})
		end
	end
	local completedCount = 0
	for _ in snapshot.completed do
		completedCount += 1
	end
	modal.subtitle.Text = string.format("%d underway", #actives)
	tally.Text = string.format("%d quest%s completed", completedCount, if completedCount == 1 then "" else "s")
	if #actives == 0 then
		Kit.label(list, {
			Name = "Empty",
			Font = F.body,
			TextSize = 15,
			TextColor3 = C.textDim,
			Text = "Nothing underway. The islands' folk always have work - go talk to them.",
			Size = UDim2.new(1, -8, 0, 40),
			TextWrapped = true,
		})
	end
end

local function buildLog()
	modal = Kit.modal({
		name = "QuestLogGui",
		title = "Quest Log",
		subtitle = "",
		token = "QUEST",
		size = UDim2.fromOffset(540, 480),
		minSize = Vector2.new(500, 360),
		maxSize = Vector2.new(620, 600),
	})
	local body = modal.body
	list = Kit.scroll(body, {
		name = "List",
		position = UDim2.new(0, 16, 0, 16),
		size = UDim2.new(1, -32, 1, -(16 + 40 + 12)),
		gap = 10,
		padding = 2,
	})
	tally = Kit.label(body, {
		Name = "Tally",
		Font = F.bodyBold,
		TextSize = 13,
		TextColor3 = C.textDim,
		TextXAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -14),
		Size = UDim2.new(1, -32, 0, 24),
		Text = "",
	})
	modal.close.Activated:Connect(function()
		QuestController.setOpen(false)
	end)
	modal.backdrop.Activated:Connect(function()
		QuestController.setOpen(false)
	end)
	modal.gui.Parent = player:WaitForChild("PlayerGui")
end

-- ============================================================ tracker

local function renderTracker()
	if not trackerFrame then
		return
	end
	for _, child in trackerFrame:GetChildren() do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	local actives = activeInOrder()
	local first = actives[1]
	trackerFrame.Visible = first ~= nil
	if not first then
		return
	end
	Kit.label(trackerFrame, {
		Name = "Name",
		Font = F.header,
		TextSize = 15,
		TextColor3 = Color3.fromRGB(255, 244, 214),
		TextStrokeTransparency = 0.4,
		Text = first.quest.name,
		Position = UDim2.new(0, 10, 0, 6),
		Size = UDim2.new(1, -20, 0, 18),
	})
	for index, objective in first.quest.objectives do
		local done = progressOf(first.entry, index) >= (objective.count or 1) or objective.type == "deliver"
		Kit.label(trackerFrame, {
			Name = string.format("Objective%d", index),
			Font = F.bodyBold,
			TextSize = 13,
			TextColor3 = if done then Color3.fromRGB(150, 232, 160) else Color3.fromRGB(232, 238, 244),
			TextStrokeTransparency = 0.5,
			Text = objectiveLine(objective, progressOf(first.entry, index)),
			Position = UDim2.new(0, 10, 0, 24 + (index - 1) * 17),
			Size = UDim2.new(1, -20, 0, 16),
		})
	end
	trackerFrame.Size = UDim2.fromOffset(210, 30 + #first.quest.objectives * 17)
end

local function buildTracker()
	trackerGui = Instance.new("ScreenGui")
	trackerGui.Name = "QuestTrackerGui"
	trackerGui.ResetOnSpawn = false
	trackerGui.DisplayOrder = 4
	trackerFrame = Instance.new("Frame")
	trackerFrame.Name = "Tracker"
	trackerFrame.BackgroundColor3 = Color3.fromRGB(16, 34, 48)
	trackerFrame.BackgroundTransparency = 0.35
	trackerFrame.BorderSizePixel = 0
	trackerFrame.Position = UDim2.new(0, 14, 0, 96)
	trackerFrame.Size = UDim2.fromOffset(210, 48)
	trackerFrame.Visible = false
	trackerFrame.Parent = trackerGui
	Kit.corner(trackerFrame, 10)
	trackerGui.Parent = player:WaitForChild("PlayerGui")
end

-- ============================================================ open / close

function QuestController.setOpen(open: boolean)
	if not modal then
		return
	end
	modal.backdrop.Visible = open
	CameraController.setCursorFree(open)
	if open then
		renderLog()
	end
end

function QuestController.isOpen(): boolean
	return modal ~= nil and modal.backdrop.Visible
end

-- ============================================================ lifecycle

local function applySnapshot(data)
	if type(data) ~= "table" then
		return
	end
	snapshot = {
		active = if type(data.active) == "table" then data.active else {},
		completed = if type(data.completed) == "table" then data.completed else {},
	}
	renderTracker()
	if QuestController.isOpen() then
		renderLog()
	end
end

function QuestController.init()
	buildLog()
	buildTracker()
end

function QuestController.start()
	Remotes.QuestsUpdated.OnClientEvent:Connect(applySnapshot)
	task.spawn(function()
		applySnapshot(Remotes.GetQuests:InvokeServer())
	end)

	-- The progress delta: bump the local copy for the tracker, and pop.
	Remotes.QuestProgress.OnClientEvent:Connect(function(delta)
		if type(delta) ~= "table" then
			return
		end
		local entry = snapshot.active[delta.questId]
		if type(entry) == "table" and type(entry.progress) == "table" then
			entry.progress[delta.objectiveIndex] = delta.count
		end
		renderTracker()
		if delta.ready then
			ProgressionController.pop(string.format("%s - ready to turn in!", tostring(delta.name)), C.accent)
		else
			ProgressionController.pop(
				string.format(
					"%s  %d/%d",
					tostring(delta.name),
					tonumber(delta.count) or 0,
					tonumber(delta.needed) or 0
				),
				C.accent
			)
		end
	end)

	ContextActionService:BindActionAtPriority(TOGGLE_ACTION, function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			QuestController.setOpen(not QuestController.isOpen())
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.J)
end

return QuestController
