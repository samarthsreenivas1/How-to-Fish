--!nonstrict
-- CollectionsController.luau
-- The fishing bestiary's client half: the snapshot + "New species!" toast
-- (B1), and now the browse modal (B2) - N, or the bottom-left FISH tile.
-- One tab per fishable WATERS (each island's roster), one row per rollable
-- species in it: discovered rows show name, catch count, best reel grade
-- and first-landed date; undiscovered rows show ??? - the chase list.
-- Pure reader; set-completion rewards are the server's (B3).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local Creatures = require(Shared.Data.Creatures)
local Tuning = require(Shared.Config.Tuning)

local Theme = require(script.Parent.Parent.UI.Theme)
local Kit = require(script.Parent.Parent.UI.Kit)
local CameraController = require(script.Parent.CameraController)
local ProgressionController = require(script.Parent.ProgressionController)

local CollectionsController = {}

local player = Players.LocalPlayer

local C = Theme.Color
local F = Theme.Font

local TOGGLE_ACTION = "CollectionsToggle"

-- The browse tabs: one per fishable waters, in saga order. Labels are the
-- island names players know; the keys are Creatures rows' `waters`.
local WATER_TABS = {
	{ kind = "ocean", label = "Cove", token = "FISH" },
	{ kind = "swamp", label = "Fen", token = "FISH" },
	{ kind = "ice", label = "Ice", token = "FISH" },
	{ kind = "volcano", label = "Lava", token = "FISH" },
	{ kind = "gloom", label = "Gloom", token = "FISH" },
	{ kind = "wreck", label = "Wreck", token = "FISH" },
	{ kind = "maelstrom", label = "Storm", token = "FISH" },
}

local snapshot: { [string]: any } = {}

local modal
local tabs
local list: ScrollingFrame
local activeKind = "ocean"

function CollectionsController.get(): { [string]: any }
	return snapshot
end

-- ============================================================ roster

-- The rollable species of one waters: anything a cast there can bring up
-- (a rarity with a roll weight; bosses and specials excluded).
local function rosterFor(waters: string): { any }
	local out = {}
	for _, row in Creatures.items do
		if row.waters == waters and Tuning.Rarity.WEIGHTS[row.rarity] then
			table.insert(out, row)
		end
	end
	table.sort(out, function(a, b)
		local wa = Tuning.Rarity.WEIGHTS[a.rarity] or 0
		local wb = Tuning.Rarity.WEIGHTS[b.rarity] or 0
		if wa ~= wb then
			return wa > wb -- commons first, the chase at the bottom
		end
		return a.id < b.id
	end)
	return out
end

-- ============================================================ modal

local function renderList()
	if not list then
		return
	end
	for _, child in list:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	local roster = rosterFor(activeKind)
	local found = 0
	for order, row in roster do
		local entry = snapshot[row.id]
		if entry then
			found += 1
		end
		local card = Kit.frame(list, {
			Name = "Species_" .. row.id,
			BackgroundTransparency = 0.12,
			BackgroundColor3 = if entry then Color3.fromRGB(238, 234, 224) else Color3.fromRGB(216, 214, 208),
			Size = UDim2.new(1, -8, 0, 44),
		})
		Kit.corner(card, 8)
		Kit.stroke(card, C.ink, 1.2, if entry then 0.5 else 0.75)
		card.LayoutOrder = order
		Kit.label(card, {
			Name = "Name",
			Font = F.header,
			TextSize = 15,
			TextColor3 = if entry then C.text else C.textDim,
			Text = if entry then row.name else "???",
			Position = UDim2.new(0, 14, 0, 4),
			Size = UDim2.new(0.62, -14, 0, 20),
		})
		Kit.label(card, {
			Name = "Rarity",
			Font = F.body,
			TextSize = 12,
			TextColor3 = C.textDim,
			Text = row.rarity,
			Position = UDim2.new(0, 14, 0, 24),
			Size = UDim2.new(0.62, -14, 0, 14),
		})
		if entry then
			Kit.label(card, {
				Name = "Stats",
				Font = F.bodyBold,
				TextSize = 13,
				TextColor3 = C.text,
				TextXAlignment = Enum.TextXAlignment.Right,
				Text = string.format("x%d   best %s", entry.n or 0, tostring(entry.best)),
				Position = UDim2.new(0.4, 0, 0, 4),
				Size = UDim2.new(0.6, -14, 0, 20),
			})
			Kit.label(card, {
				Name = "First",
				Font = F.body,
				TextSize = 11,
				TextColor3 = C.textDim,
				TextXAlignment = Enum.TextXAlignment.Right,
				Text = "first landed " .. os.date("%d %b %Y", tonumber(entry.first) or 0),
				Position = UDim2.new(0.4, 0, 0, 24),
				Size = UDim2.new(0.6, -14, 0, 14),
			})
		end
	end
	modal.subtitle.Text = string.format("%d of %d species landed", found, #roster)
end

local function buildUi()
	modal = Kit.modal({
		name = "CollectionsGui",
		title = "Fishing Log",
		subtitle = "",
		token = "FISH",
		size = UDim2.fromOffset(600, 520),
		minSize = Vector2.new(560, 400),
		maxSize = Vector2.new(680, 640),
	})
	local body = modal.body
	local top = Kit.frame(body, {
		Name = "Top",
		Position = UDim2.new(0, 16, 0, 10),
		Size = UDim2.new(1, -32, 0, 40),
	})
	tabs = Kit.tabs(top, WATER_TABS, function(kind)
		activeKind = kind
		tabs.set(kind)
		renderList()
	end)
	list = Kit.scroll(body, {
		name = "List",
		position = UDim2.new(0, 16, 0, 58),
		size = UDim2.new(1, -32, 1, -(58 + 12)),
		gap = 8,
		padding = 2,
	})
	modal.close.Activated:Connect(function()
		CollectionsController.setOpen(false)
	end)
	modal.backdrop.Activated:Connect(function()
		CollectionsController.setOpen(false)
	end)
	modal.gui.Parent = player:WaitForChild("PlayerGui")
end

-- ============================================================ open / close

function CollectionsController.setOpen(open: boolean)
	if not modal then
		return
	end
	modal.backdrop.Visible = open
	CameraController.setCursorFree(open)
	if open then
		tabs.set(activeKind)
		renderList()
	end
end

function CollectionsController.isOpen(): boolean
	return modal ~= nil and modal.backdrop.Visible
end

-- ============================================================ lifecycle

function CollectionsController.init()
	buildUi()
end

function CollectionsController.start()
	Remotes.CollectionsUpdated.OnClientEvent:Connect(function(data)
		if type(data) == "table" then
			snapshot = data
			if CollectionsController.isOpen() then
				renderList()
			end
		end
	end)
	task.spawn(function()
		local data = Remotes.GetCollections:InvokeServer()
		if type(data) == "table" then
			snapshot = data
		end
	end)

	Remotes.CollectionGranted.OnClientEvent:Connect(function(delta)
		if type(delta) ~= "table" then
			return
		end
		local entry = snapshot[delta.speciesId]
		if type(entry) ~= "table" then
			entry = { n = 0, best = delta.best, first = os.time() }
			snapshot[delta.speciesId] = entry
		end
		entry.n = delta.n
		entry.best = delta.best
		if delta.isFirst then
			local row = Creatures.items[delta.speciesId]
			ProgressionController.pop(
				string.format("New species: %s!", row and row.name or tostring(delta.speciesId)),
				Theme.Color.green
			)
		end
		if CollectionsController.isOpen() then
			renderList()
		end
	end)

	ContextActionService:BindActionAtPriority(TOGGLE_ACTION, function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			CollectionsController.setOpen(not CollectionsController.isOpen())
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.N)
end

return CollectionsController
