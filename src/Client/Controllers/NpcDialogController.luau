--!nonstrict
-- NpcDialogController.luau
-- The talking window. The server pushes a pane over NpcDialog ({ npcId,
-- name, title, pane, lines, choices }) whenever the player triggers an
-- NPC's prompt; this draws it on the Kit - the speaker as the modal title,
-- their lines as paragraphs, the choices as buttons along the bottom.
-- Clicking a choice echoes its id back over NpcChoice; the SERVER decides
-- what an id does (this file never assumes), and a fresh pane push simply
-- re-renders the same window - that's how quest offers, turn-ins and the
-- shop arrive in later slices without this file growing a state machine.
-- "farewell" is the one locally-understood id: it closes the window.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)

local Theme = require(script.Parent.Parent.UI.Theme)
local Kit = require(script.Parent.Parent.UI.Kit)
local CameraController = require(script.Parent.CameraController)
local ProgressionController = require(script.Parent.ProgressionController)

local player = Players.LocalPlayer

local NpcDialogController = {}

local C = Theme.Color
local F = Theme.Font

local modal
local linesFrame: ScrollingFrame
local choicesFrame: Frame
local currentNpcId: string? = nil

-- ============================================================ ui

local function buildUi()
	modal = Kit.modal({
		name = "NpcDialogGui",
		title = "",
		subtitle = "",
		token = "TALK",
		size = UDim2.fromOffset(520, 420),
		minSize = Vector2.new(480, 340),
		maxSize = Vector2.new(600, 520),
	})
	local body = modal.body

	linesFrame = Kit.scroll(body, {
		name = "Lines",
		position = UDim2.new(0, 20, 0, 16),
		size = UDim2.new(1, -40, 1, -(16 + 64 + 12)),
		gap = 12,
		padding = 2,
	})

	choicesFrame = Kit.frame(body, {
		Name = "Choices",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 20, 1, -14),
		Size = UDim2.new(1, -40, 0, 46),
	})
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 10)
	layout.Parent = choicesFrame

	modal.close.Activated:Connect(function()
		NpcDialogController.setOpen(false)
	end)
	modal.backdrop.Activated:Connect(function()
		NpcDialogController.setOpen(false)
	end)

	modal.gui.Parent = player:WaitForChild("PlayerGui")
end

local function renderPane(payload)
	currentNpcId = payload.npcId
	modal.title.Text = payload.name or ""
	modal.subtitle.Text = payload.title or ""

	for _, child in linesFrame:GetChildren() do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	for i, line in payload.lines or {} do
		local paragraph = Kit.label(linesFrame, {
			Name = string.format("Line%d", i),
			Font = F.body,
			TextSize = 16,
			TextColor3 = C.text,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			Text = tostring(line),
			Size = UDim2.new(1, -8, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = i,
		})
		paragraph.RichText = false
	end

	for _, child in choicesFrame:GetChildren() do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
	for i, choice in payload.choices or {} do
		local button = Kit.button(choicesFrame, {
			name = string.format("Choice_%s", tostring(choice.id)),
			text = tostring(choice.label),
			size = UDim2.fromOffset(math.max(130, 24 + #tostring(choice.label) * 9), 40),
		})
		button.LayoutOrder = i
		button.Activated:Connect(function()
			local npcId = currentNpcId
			if not npcId then
				return
			end
			Remotes.NpcChoice:FireServer(npcId, choice.id)
			if choice.id == "farewell" then
				NpcDialogController.setOpen(false)
			end
		end)
	end
end

-- ============================================================ open / close

function NpcDialogController.setOpen(open: boolean)
	if not modal then
		return
	end
	modal.backdrop.Visible = open
	CameraController.setCursorFree(open)
	if not open then
		currentNpcId = nil
	end
end

function NpcDialogController.isOpen(): boolean
	return modal ~= nil and modal.backdrop.Visible
end

-- ============================================================ lifecycle

function NpcDialogController.init()
	buildUi()
end

function NpcDialogController.start()
	Remotes.NpcDialog.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end
		renderPane(payload)
		NpcDialogController.setOpen(true)
	end)

	-- The quest progress pop ("Maren's Wager 3/5"). Lives here until the
	-- quest log controller arrives (A3), which takes it over.
	Remotes.QuestProgress.OnClientEvent:Connect(function(delta)
		if type(delta) ~= "table" then
			return
		end
		if delta.ready then
			ProgressionController.pop(string.format("%s - ready to turn in!", tostring(delta.name)), Theme.Color.accent)
		else
			ProgressionController.pop(
				string.format(
					"%s  %d/%d",
					tostring(delta.name),
					tonumber(delta.count) or 0,
					tonumber(delta.needed) or 0
				),
				Theme.Color.accent
			)
		end
	end)
end

return NpcDialogController
