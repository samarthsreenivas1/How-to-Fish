--!nonstrict
-- NpcDialogController.luau
-- The conversation. TWO layers, one per `pane` the server pushes over
-- NpcDialog, and never both at once:
--
--  (a) THE TALK (`pane = "dialogue"`). A classic dialogue BOX at the bottom of
--      the screen (user, 2026-09-12: the black cinematic "took up all of the
--      screen"): ~62% of the viewport wide, clamped to 520..900 px, ~30% tall,
--      24 px off the bottom edge, on the same charcoal surfaces NpcMenu draws
--      so the two layers read as one window. A name tag straddles its top-left
--      edge (name in brass, title smaller beside it); the line is TYPED out
--      inside at ~45 characters a second. A node can carry several pages;
--      click / Space / Enter completes the line that is running and then turns
--      the page, and a small brass chevron bottom-right says so while pages
--      remain. After the last page the player's replies fade in as full
--      sentences in a vertical list in the box's lower part - no numbers, ever
--      - navigable with up/down + Enter or with the mouse, and scrolling if
--      four of them won't fit. Escape sends "end".
--      THE WORLD STAYS VISIBLE: no backdrop at all for an `again` meeting, and
--      only a light 25% dim (plus a short fade-in of the box) for `black =
--      true`, the first meeting.
--
--  (b) THE BUSINESS PANEL (`pane = "menu"`), drawn by Client/UI/NpcMenu.luau:
--      the dark charcoal panel with the WORK and TRADE sections. It is a
--      separate module only because this file was already the longest thing in
--      the lane; the wiring is the same - every button reports a wire id.
--
-- This file still never decides what an id MEANS. It echoes ids back over
-- NpcChoice and re-renders whatever comes back, exactly as the pane machine
-- did; the server owns the tree, the transitions, the money and the distance
-- checks. THREE ids are understood locally. Two are the closes: "end" (a polite
-- exit reply, and Escape out of the talk) and "farewell" (the panel's own button,
-- Escape out of the panel, dying mid-sentence) - both shut the window here AND
-- tell the server, because the server turns the body back to its post when the
-- conversation ends. Walking away is a close too; the server just never hears
-- that one. The third is "summon" from the Craft tab's boat card: a hull is not
-- equipped, it is summoned, and that has always been the RequestBoat remote
-- BoatService validates - so it goes there rather than to NpcChoice.
--
-- SOUND. The cues keep their names and their meanings: dialogOpen / dialogClose
-- for the window, dialogBlip per chunk of typed text (throttled - see
-- BLIP_MIN_GAP), dialogChoice on a reply or a panel button, and the verdict
-- chime off the payload's `kind` (shopBuy / shopFail / uiError, and - since
-- crafting moved in here from the deleted C window - craftSuccess / craftFail).
-- boatUpgrade rides the BoatTier attribute, as it did in that window: the
-- fanfare for a new hull belongs to the tier landing, not to a panel being open.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)

local NpcMenu = require(script.Parent.Parent.UI.NpcMenu)
local CameraController = require(script.Parent.CameraController)
local Sfx = require(script.Parent.Parent.Modules.Sfx)

local player = Players.LocalPlayer

local NpcDialogController = {}

-- Above every HUD layer (5), the menu buttons (40) and the admin panel (50),
-- below the boss cutscene's letterbox (90/100) - a boss cinematic must never
-- come up behind a villager's window.
local TALK_ORDER = 70
local MENU_ORDER = 68

-- The box's palette, copied from NpcMenu rather than taken from Theme: the
-- shared kit is the bright paper "sticker" theme, and these two layers are the
-- one dark window in the game. Charcoal ground, cream text, one warm brass.
local INK = Color3.fromRGB(31, 33, 38)
local INK_RAISE = Color3.fromRGB(42, 45, 52)
local EDGE = Color3.fromRGB(62, 66, 75)
local CREAM = Color3.fromRGB(245, 238, 220)
local CREAM_DIM = Color3.fromRGB(170, 164, 150)
local SPEECH = Color3.fromRGB(250, 246, 236)
local ACCENT = Color3.fromRGB(214, 154, 74)

-- The box. Width is 62% of the viewport clamped to 520..900 px, height ~30%
-- clamped to 200..440, and both are clamped AGAIN against the viewport less the
-- margin, which is what keeps it on a phone (a 520 px minimum on a 400 px
-- screen would hang off both sides); the UISizeConstraint is the belt.
local BOX_W_SCALE = 0.62
local BOX_MIN_W = 520
local BOX_MAX_W = 900
local BOX_H_SCALE = 0.30
local BOX_MIN_H = 200
local BOX_MAX_H = 440
local BOX_MARGIN = 24 -- off the bottom edge, and the side gutter when clamped
local BOX_RADIUS = 12
local BOX_PAD = 18
local BOX_PAD_TOP = 24 -- the name tag straddles the top edge; keep text clear of it

-- The reply list: at most four full sentences, never more than this much of the
-- box's inner height (the spoken line keeps the rest), and it scrolls if the
-- four still don't fit.
local REPLY_MAX = 4
local REPLY_ROOM = 0.6
local REPLY_GAP = 10
-- Room left under the line for the chevron when there are no replies yet.
local HINT_ROOM = 22

-- Typing speed and the blip's floor. 45 chars/s is a brisk reading pace; the
-- blip is capped in TIME rather than per character, or a line would buzz.
local CHARS_PER_SEC = 45
local BLIP_MIN_GAP = 0.08

-- The first meeting's dim: a LIGHT 25% black over the world, never a blackout.
-- Every later meeting has no backdrop at all.
local DIM_TRANSPARENCY = 0.75

-- ============================================================ state

local talkGui: ScreenGui
local backdrop: Frame
local boxWrap: Frame -- the box AND its shadow and name tag, sized by layoutBox()
local box: Frame -- the charcoal panel itself
local content: Frame -- the padded, clipping inside of the box
local nameTag: Frame
local nameLabel: TextLabel
local titleLabel: TextLabel
local lineLabel: TextLabel
local hintLabel: TextLabel
local repliesScroll: ScrollingFrame
local replyLayout: UIListLayout
local menu

local currentNpcId: string? = nil
local opened = false

-- The page machine for the node on screen.
local pages: { string } = {}
local pageIndex = 0
local replies: { any } = {}
local replyButtons: { TextButton } = {}
local replyActions: { () -> () } = {}
local selected = 0
local repliesShown = false
-- Set once the empty-choices "…and that was the last page" click has asked the
-- server for the menu, so a second click doesn't ask twice.
local menuRequested = false

-- The typewriter: one Heartbeat connection while a line is running.
local typeConn: RBXScriptConnection? = nil
local typing = false
local shownChars = 0
local totalChars = 0
local lastBlipAt = 0

-- Armed when a "buy:N" goes out, for the ONE case the verdict cue can't read
-- `kind`: a server that pushed a menu without one. Every payload carries `kind`
-- today, so this is a belt, not the braces.
local pendingBuy = false
local SHOP_SUCCESS_PREFIX = "There you go"

-- Keyboard lives only while a layer is up: Escape belongs to the Roblox menu
-- the rest of the time, and the arrow keys to walking.
local TALK_ACTION = "NpcTalkKeys"
local MENU_ACTION = "NpcMenuKeys"

-- ============================================================ the talk's ui

-- The two pieces of arithmetic this layer owns. They are up here because
-- buildTalkUi() wires them to the size signals that drive them.

-- How the box's inner height is split: the reply list takes what it wants up to
-- REPLY_ROOM of it, the spoken line takes the rest. The line's region is fixed
-- (not AutomaticSize) precisely so a long line can never squeeze the replies out
-- of the box - `content` clips instead. `repliesShown` is the state block's.
local function layoutReplies()
	if not content then
		return
	end
	local avail = content.AbsoluteSize.Y
	if avail <= 0 then
		return
	end
	local want = if repliesShown then replyLayout.AbsoluteContentSize.Y else 0
	local height = math.floor(math.min(want, avail * REPLY_ROOM))
	repliesScroll.Visible = height > 0
	repliesScroll.Size = UDim2.new(1, 0, 0, height)
	repliesScroll.ScrollingEnabled = want > height
	local lineRoom = if height > 0 then avail - height - REPLY_GAP else avail - HINT_ROOM
	lineLabel.Size = UDim2.new(1, 0, 0, math.max(24, math.floor(lineRoom)))
end

-- The box's own size, in pixels, from the viewport. Offsets rather than scale
-- so the phone clamp and the 520..900 clamp can be resolved in one place.
local function layoutBox()
	if not boxWrap then
		return
	end
	local vp = backdrop.AbsoluteSize
	if vp.X <= 0 or vp.Y <= 0 then
		return
	end
	local width = math.clamp(vp.X * BOX_W_SCALE, BOX_MIN_W, BOX_MAX_W)
	width = math.min(width, vp.X - BOX_MARGIN * 2)
	local height = math.clamp(vp.Y * BOX_H_SCALE, BOX_MIN_H, BOX_MAX_H)
	height = math.min(height, vp.Y - BOX_MARGIN * 2)
	boxWrap.Size = UDim2.fromOffset(math.max(160, math.floor(width)), math.max(120, math.floor(height)))
	layoutReplies()
end

local function buildTalkUi()
	talkGui = Instance.new("ScreenGui")
	talkGui.Name = "NpcTalkGui"
	talkGui.ResetOnSpawn = false
	talkGui.IgnoreGuiInset = true
	talkGui.DisplayOrder = TALK_ORDER
	talkGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	talkGui.Enabled = false

	-- Transparent by default: the world is the backdrop now. renderTalk() dims it
	-- 25% for a first meeting and puts it back for every other one.
	backdrop = Instance.new("Frame")
	backdrop.Name = "Backdrop"
	backdrop.BorderSizePixel = 0
	backdrop.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	backdrop.BackgroundTransparency = 1
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.Parent = talkGui

	-- The whole screen advances the talk. It sits at ZIndex 0 so the reply
	-- buttons above it still take their own clicks.
	local catcher = Instance.new("TextButton")
	catcher.Name = "Advance"
	catcher.BackgroundTransparency = 1
	catcher.BorderSizePixel = 0
	catcher.Text = ""
	catcher.AutoButtonColor = false
	catcher.Size = UDim2.fromScale(1, 1)
	catcher.ZIndex = 0
	catcher.Parent = backdrop

	-- The wrapper carries the size; the shadow, the panel and the name tag are
	-- all sized off it, and the tag may hang outside it without being clipped
	-- (only `content` clips).
	boxWrap = Instance.new("Frame")
	boxWrap.Name = "Box"
	boxWrap.BackgroundTransparency = 1
	boxWrap.BorderSizePixel = 0
	boxWrap.AnchorPoint = Vector2.new(0.5, 1)
	boxWrap.Position = UDim2.new(0.5, 0, 1, -BOX_MARGIN)
	boxWrap.Size = UDim2.fromOffset(BOX_MIN_W, BOX_MIN_H)
	boxWrap.ZIndex = 1
	boxWrap.Parent = backdrop

	local cap = Instance.new("UISizeConstraint")
	cap.MinSize = Vector2.new(240, 140)
	cap.MaxSize = Vector2.new(BOX_MAX_W, BOX_MAX_H)
	cap.Parent = boxWrap

	-- A soft drop shadow with no image to upload: two black sheets behind the
	-- panel, each a little larger, lower and fainter than the one before.
	for index = 1, 2 do
		local shade = Instance.new("Frame")
		shade.Name = string.format("Shadow%d", index)
		shade.BorderSizePixel = 0
		shade.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		shade.BackgroundTransparency = 0.55 + 0.15 * index
		shade.AnchorPoint = Vector2.new(0.5, 0.5)
		shade.Position = UDim2.new(0.5, 0, 0.5, index * 3)
		shade.Size = UDim2.new(1, index * 6, 1, index * 6)
		shade.ZIndex = 1
		shade.Parent = boxWrap
		local shadeCorner = Instance.new("UICorner")
		shadeCorner.CornerRadius = UDim.new(0, BOX_RADIUS + index * 2)
		shadeCorner.Parent = shade
	end

	box = Instance.new("Frame")
	box.Name = "Panel"
	box.BorderSizePixel = 0
	box.BackgroundColor3 = INK
	box.BackgroundTransparency = 0
	box.Size = UDim2.fromScale(1, 1)
	box.ZIndex = 2
	box.Parent = boxWrap
	local boxCorner = Instance.new("UICorner")
	boxCorner.CornerRadius = UDim.new(0, BOX_RADIUS)
	boxCorner.Parent = box
	local boxEdge = Instance.new("UIStroke")
	boxEdge.Color = EDGE
	boxEdge.Thickness = 1
	boxEdge.Transparency = 0.2
	boxEdge.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	boxEdge.Parent = box
	local boxPad = Instance.new("UIPadding")
	boxPad.PaddingLeft = UDim.new(0, BOX_PAD)
	boxPad.PaddingRight = UDim.new(0, BOX_PAD)
	boxPad.PaddingTop = UDim.new(0, BOX_PAD_TOP)
	boxPad.PaddingBottom = UDim.new(0, BOX_PAD - 4)
	boxPad.Parent = box

	content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.BorderSizePixel = 0
	content.ClipsDescendants = true
	content.Size = UDim2.fromScale(1, 1)
	content.ZIndex = 3
	content.Parent = box

	local function line(parent: Instance, name: string, props): TextLabel
		local lbl = Instance.new("TextLabel")
		lbl.Name = name
		lbl.BackgroundTransparency = 1
		lbl.BorderSizePixel = 0
		lbl.RichText = false
		lbl.Font = Enum.Font.GothamMedium
		lbl.TextColor3 = CREAM
		lbl.TextXAlignment = Enum.TextXAlignment.Left
		lbl.TextYAlignment = Enum.TextYAlignment.Top
		lbl.Text = ""
		lbl.ZIndex = 4
		for key, value in props do
			lbl[key] = value
		end
		lbl.Parent = parent
		return lbl
	end

	-- The name tag, straddling the top-left edge of the box: its vertical centre
	-- IS the box's top edge, so it reads as pinned to the panel rather than
	-- floating above it. It is a child of the wrapper, not of the clipping
	-- content, and sizes itself to the words.
	nameTag = Instance.new("Frame")
	nameTag.Name = "NameTag"
	nameTag.BorderSizePixel = 0
	nameTag.BackgroundColor3 = INK_RAISE
	nameTag.BackgroundTransparency = 0
	nameTag.AnchorPoint = Vector2.new(0, 0.5)
	nameTag.Position = UDim2.new(0, 22, 0, 0)
	nameTag.Size = UDim2.fromOffset(0, 30)
	nameTag.AutomaticSize = Enum.AutomaticSize.X
	nameTag.ZIndex = 5
	nameTag.Parent = boxWrap
	local tagCorner = Instance.new("UICorner")
	tagCorner.CornerRadius = UDim.new(0, 8)
	tagCorner.Parent = nameTag
	local tagEdge = Instance.new("UIStroke")
	tagEdge.Color = ACCENT
	tagEdge.Thickness = 1
	tagEdge.Transparency = 0.4
	tagEdge.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	tagEdge.Parent = nameTag
	local tagPad = Instance.new("UIPadding")
	tagPad.PaddingLeft = UDim.new(0, 12)
	tagPad.PaddingRight = UDim.new(0, 12)
	tagPad.Parent = nameTag
	local tagRow = Instance.new("UIListLayout")
	tagRow.FillDirection = Enum.FillDirection.Horizontal
	tagRow.SortOrder = Enum.SortOrder.LayoutOrder
	tagRow.VerticalAlignment = Enum.VerticalAlignment.Center
	tagRow.Padding = UDim.new(0, 8)
	tagRow.Parent = nameTag

	nameLabel = line(nameTag, "Name", {
		Font = Enum.Font.GothamBold,
		TextSize = 18,
		TextColor3 = ACCENT,
		TextYAlignment = Enum.TextYAlignment.Center,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 22),
		LayoutOrder = 1,
		ZIndex = 6,
	})
	titleLabel = line(nameTag, "Title", {
		TextSize = 13,
		TextColor3 = CREAM_DIM,
		TextYAlignment = Enum.TextYAlignment.Center,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 20),
		LayoutOrder = 2,
		ZIndex = 6,
	})

	lineLabel = line(content, "Line", {
		TextSize = 21,
		TextColor3 = SPEECH,
		TextWrapped = true,
		Position = UDim2.new(0, 0, 0, 0),
		Size = UDim2.new(1, 0, 1, 0),
		LineHeight = 1.18,
	})

	-- The chevron: "there is more after this". Bottom-right, and only ever up
	-- while the replies are not (they own that corner of the box).
	hintLabel = line(content, "Hint", {
		TextSize = 13,
		TextColor3 = ACCENT,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextYAlignment = Enum.TextYAlignment.Bottom,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, 0, 1, 0),
		Size = UDim2.fromOffset(180, 18),
		Text = "continue  \u{25BE}",
	})
	hintLabel.Visible = false

	repliesScroll = Instance.new("ScrollingFrame")
	repliesScroll.Name = "Replies"
	repliesScroll.BackgroundTransparency = 1
	repliesScroll.BorderSizePixel = 0
	repliesScroll.AnchorPoint = Vector2.new(0, 1)
	repliesScroll.Position = UDim2.new(0, 0, 1, 0)
	repliesScroll.Size = UDim2.new(1, 0, 0, 0)
	repliesScroll.CanvasSize = UDim2.fromOffset(0, 0)
	repliesScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	repliesScroll.ScrollingDirection = Enum.ScrollingDirection.Y
	repliesScroll.VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar
	repliesScroll.ScrollBarThickness = 5
	repliesScroll.ScrollBarImageColor3 = EDGE
	repliesScroll.ScrollBarImageTransparency = 0.2
	repliesScroll.ZIndex = 4
	repliesScroll.Parent = content
	replyLayout = Instance.new("UIListLayout")
	replyLayout.SortOrder = Enum.SortOrder.LayoutOrder
	replyLayout.Padding = UDim.new(0, 6)
	replyLayout.Parent = repliesScroll

	-- Three signals drive the arithmetic: the viewport (the box's size), the
	-- box's inner size (the split) and the reply list's measured height.
	backdrop:GetPropertyChangedSignal("AbsoluteSize"):Connect(layoutBox)
	content:GetPropertyChangedSignal("AbsoluteSize"):Connect(layoutReplies)
	replyLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(layoutReplies)

	catcher.Activated:Connect(function()
		NpcDialogController.advance()
	end)

	talkGui.Parent = player:WaitForChild("PlayerGui")
	layoutBox()
end

-- ============================================================ typing

local function stopTyping()
	if typeConn then
		typeConn:Disconnect()
		typeConn = nil
	end
	typing = false
end

local function onLineFinished()
	if pageIndex < #pages then
		-- More pages in this node: the chevron bottom-right is the whole prompt.
		hintLabel.Visible = true
		return
	end
	NpcDialogController.showReplies()
end

local function finishLine()
	stopTyping()
	lineLabel.MaxVisibleGraphemes = -1
	onLineFinished()
end

local function typeLine(text: string)
	stopTyping()
	hintLabel.Visible = false
	lineLabel.Text = text
	lineLabel.MaxVisibleGraphemes = 0
	shownChars = 0
	totalChars = utf8.len(text) or #text
	lastBlipAt = 0
	if totalChars <= 0 then
		finishLine()
		return
	end
	typing = true
	typeConn = RunService.Heartbeat:Connect(function(dt)
		shownChars = math.min(totalChars, shownChars + dt * CHARS_PER_SEC)
		lineLabel.MaxVisibleGraphemes = math.floor(shownChars)
		local now = os.clock()
		if now - lastBlipAt >= BLIP_MIN_GAP then
			lastBlipAt = now
			Sfx.play("dialogBlip")
		end
		if shownChars >= totalChars then
			finishLine()
		end
	end)
end

local function nextPage()
	pageIndex += 1
	local text = pages[pageIndex]
	if type(text) ~= "string" then
		-- Ran off the end of a node with no pages at all: treat it as a finished
		-- line so the replies (or the menu request) still happen.
		finishLine()
		return
	end
	typeLine(text)
end

-- ============================================================ replies

local function sendChoice(id: string)
	local npcId = currentNpcId
	if not npcId then
		return
	end
	pendingBuy = string.sub(id, 1, 4) == "buy:"
	Remotes.NpcChoice:FireServer(npcId, id)
end

local function setSelected(index: number)
	if #replyButtons == 0 then
		return
	end
	selected = math.clamp(index, 1, #replyButtons)
	for i, button in replyButtons do
		local on = i == selected
		button.BackgroundColor3 = if on then ACCENT else INK_RAISE
		button.BackgroundTransparency = if on then 0.7 else 0.15
		button.TextColor3 = if on then SPEECH else CREAM
		local bar = button:FindFirstChild("Marker")
		if bar and bar:IsA("Frame") then
			bar.Visible = on
		end
	end
end

local function clearReplies()
	for _, button in replyButtons do
		button:Destroy()
	end
	table.clear(replyButtons)
	table.clear(replyActions)
	selected = 0
	repliesShown = false
	layoutReplies()
end

-- The replies, as full sentences in a column. They fade in so the eye arrives
-- at them after the line rather than with it.
function NpcDialogController.showReplies()
	clearReplies()
	hintLabel.Visible = false
	if #replies == 0 then
		-- A node with no replies ENDS the talk and opens the panel; the player
		-- still clicks once to leave the last line on screen as long as they like,
		-- and the chevron is what says so.
		hintLabel.Visible = true
		return
	end
	repliesShown = true
	for index, reply in replies do
		local text = tostring(reply.text or "")
		local button = Instance.new("TextButton")
		button.Name = string.format("Reply%d", index)
		button.AutoButtonColor = false
		button.BorderSizePixel = 0
		button.BackgroundColor3 = INK_RAISE
		button.BackgroundTransparency = 0.15
		button.Font = Enum.Font.GothamMedium
		button.TextSize = 18
		button.TextColor3 = CREAM
		button.TextXAlignment = Enum.TextXAlignment.Left
		button.TextWrapped = true
		button.Text = text
		-- Leave the scrollbar's gutter: the list scrolls when four sentences
		-- won't fit the box's lower part, and text under a bar reads badly.
		button.Size = UDim2.new(1, -8, 0, 0)
		button.AutomaticSize = Enum.AutomaticSize.Y
		button.LayoutOrder = index
		button.TextTransparency = 1
		button.ZIndex = 4
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = button
		local edge = Instance.new("UIStroke")
		edge.Color = EDGE
		edge.Thickness = 1
		edge.Transparency = 0.35
		edge.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		edge.Parent = button
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 16)
		pad.PaddingRight = UDim.new(0, 12)
		pad.PaddingTop = UDim.new(0, 7)
		pad.PaddingBottom = UDim.new(0, 7)
		pad.Parent = button
		-- The selection mark sits INSIDE the button's left padding, not outside
		-- it: anything hanging off the left edge would be clipped by the scroll.
		local marker = Instance.new("Frame")
		marker.Name = "Marker"
		marker.BorderSizePixel = 0
		marker.BackgroundColor3 = ACCENT
		marker.AnchorPoint = Vector2.new(0, 0.5)
		marker.Position = UDim2.new(0, -10, 0.5, 0)
		marker.Size = UDim2.fromOffset(3, 16)
		marker.Visible = false
		marker.ZIndex = 5
		marker.Parent = button
		button.Parent = repliesScroll

		local id = tostring(reply.id or "")
		local function activate()
			if not repliesShown then
				return
			end
			Sfx.play("dialogChoice")
			if id == "end" then
				-- A polite exit: the window closes here, and the server hears
				-- "end" (which is how the body turns back to its post).
				NpcDialogController.close("end")
				return
			end
			clearReplies()
			sendChoice(id)
		end
		button.Activated:Connect(activate)
		button.MouseEnter:Connect(function()
			setSelected(index)
		end)
		replyButtons[index] = button
		replyActions[index] = activate

		TweenService:Create(button, TweenInfo.new(0.18, Enum.EasingStyle.Quad), {
			TextTransparency = 0,
		}):Play()
	end
	setSelected(1)
	layoutReplies()
end

-- Click / Space / Enter: finish the line that is running, else turn the page,
-- else (on the last page of a node with no replies) ask for the panel.
function NpcDialogController.advance()
	if not (opened and talkGui.Enabled) then
		return
	end
	if typing then
		finishLine()
		return
	end
	if pageIndex < #pages then
		nextPage()
		return
	end
	if repliesShown then
		return -- the replies are the only way on from here
	end
	if not menuRequested then
		menuRequested = true
		Sfx.play("dialogChoice")
		sendChoice("menu")
	end
end

-- ============================================================ keys

local function bindTalkKeys()
	ContextActionService:BindActionAtPriority(
		TALK_ACTION,
		function(_, state, input)
			if state ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Sink
			end
			local key = input.KeyCode
			if key == Enum.KeyCode.Escape then
				NpcDialogController.close("end")
			elseif key == Enum.KeyCode.Up then
				setSelected(selected - 1)
			elseif key == Enum.KeyCode.Down then
				setSelected(selected + 1)
			elseif repliesShown then
				local action = replyActions[selected]
				if action then
					action()
				end
			else
				NpcDialogController.advance()
			end
			return Enum.ContextActionResult.Sink
		end,
		false,
		Enum.ContextActionPriority.High.Value,
		Enum.KeyCode.Escape,
		Enum.KeyCode.Space,
		Enum.KeyCode.Return,
		Enum.KeyCode.KeypadEnter,
		Enum.KeyCode.Up,
		Enum.KeyCode.Down
	)
end

local function bindMenuKeys()
	ContextActionService:BindActionAtPriority(MENU_ACTION, function(_, state)
		if state == Enum.UserInputState.Begin then
			NpcDialogController.close("farewell")
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Escape)
end

local function unbindKeys()
	ContextActionService:UnbindAction(TALK_ACTION)
	ContextActionService:UnbindAction(MENU_ACTION)
end

-- ============================================================ layers

local function showLayer(which: string?)
	local talk = which == "dialogue"
	local panel = which == "menu"
	talkGui.Enabled = talk
	menu.setVisible(panel)
	unbindKeys()
	if talk then
		bindTalkKeys()
	elseif panel then
		bindMenuKeys()
	end
	local nowOpen = talk or panel
	if nowOpen ~= opened then
		opened = nowOpen
		CameraController.setCursorFree(nowOpen)
		Sfx.play(if nowOpen then "dialogOpen" else "dialogClose")
	end
end

-- The first meeting only: the box slides up its last few pixels and fades in,
-- so the very first conversation of the game has a beat of its own. Nothing
-- more - no blackout, no letterbox.
local function fadeInBox()
	box.BackgroundTransparency = 1
	boxWrap.Position = UDim2.new(0.5, 0, 1, -BOX_MARGIN + 12)
	local ease = TweenInfo.new(0.24, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(box, ease, { BackgroundTransparency = 0 }):Play()
	TweenService:Create(boxWrap, ease, { Position = UDim2.new(0.5, 0, 1, -BOX_MARGIN) }):Play()
end

local function renderTalk(payload)
	pages = {}
	for _, text in (if type(payload.say) == "table" then payload.say else {}) do
		if type(text) == "string" and text ~= "" then
			table.insert(pages, text)
		end
	end
	if #pages == 0 then
		table.insert(pages, "...")
	end
	replies = {}
	for _, reply in (if type(payload.choices) == "table" then payload.choices else {}) do
		if type(reply) == "table" and type(reply.id) == "string" and #replies < REPLY_MAX then
			table.insert(replies, reply)
		end
	end
	-- The world stays visible either way. A first meeting (`black`) gets a light
	-- dim and a short fade-in of the box; every later one gets neither.
	local first = payload.black == true
	backdrop.BackgroundTransparency = if first then DIM_TRANSPARENCY else 1
	nameLabel.Text = tostring(payload.name or "")
	titleLabel.Text = tostring(payload.title or "")
	titleLabel.Visible = titleLabel.Text ~= ""
	clearReplies()
	hintLabel.Visible = false
	menuRequested = false
	pageIndex = 0
	showLayer("dialogue")
	layoutBox()
	if first then
		fadeInBox()
	else
		box.BackgroundTransparency = 0
		boxWrap.Position = UDim2.new(0.5, 0, 1, -BOX_MARGIN)
	end
	nextPage()
end

-- ============================================================ open / close

-- The ONLY way this window shuts: every close is also the end of a
-- conversation, and the server wants to hear that. `reason` is the id it hears
-- ("end" out of the talk, "farewell" out of the panel) - both mean the same
-- thing to it, and both are sent BEFORE the teardown, which forgets which NPC
-- this was.
function NpcDialogController.close(reason: string?)
	if opened and currentNpcId then
		Remotes.NpcChoice:FireServer(currentNpcId, reason or "farewell")
	end
	stopTyping()
	clearReplies()
	pages = {}
	pageIndex = 0
	menuRequested = false
	pendingBuy = false
	currentNpcId = nil
	showLayer(nil)
end

function NpcDialogController.isOpen(): boolean
	return opened
end

-- ============================================================ sound

-- THE VERDICT CUE for an incoming payload, and the one place a dialogue
-- outcome is read. `kind` is authoritative.
--
-- quest_accept / quest_done are DELIBERATELY ABSENT: QuestController already
-- fires questAccept / questComplete off its snapshot diff (which is the
-- authoritative source - it fires for a quest accepted with no window open at
-- all), and a row here would double-play every turn-in.
local VERDICT_CUE = {
	bought = "shopBuy",
	refused = "shopFail",
	quest_refused = "uiError",
	-- Carried over from the deleted C crafting window: the
	-- server's verdict on a craft is the only honest place for these, because the
	-- Craft button is gated on a payload that can be a race behind the truth.
	crafted = "craftSuccess",
	craft_refused = "craftFail",
}

local function verdictCue(payload): string?
	local kind = payload.kind
	if type(kind) == "string" then
		return VERDICT_CUE[kind]
	end
	-- No kind on the wire: fall back to the armed-buy prefix test on the panel's
	-- remark. The safe direction, not the good one - a new refusal phrasing still
	-- sounds wrong, where a new SUCCESS phrasing would lose its chime.
	if pendingBuy and payload.pane == "menu" then
		local remark = tostring(payload.remark or "")
		local bought = string.sub(remark, 1, #SHOP_SUCCESS_PREFIX) == SHOP_SUCCESS_PREFIX
		return if bought then "shopBuy" else "shopFail"
	end
	return nil
end

-- ============================================================ lifecycle

function NpcDialogController.init()
	buildTalkUi()
	menu = NpcMenu.new(function(id: string)
		Sfx.play("dialogChoice")
		if id == "farewell" then
			-- close() sends it; sending it here too would double it.
			NpcDialogController.close("farewell")
			return
		end
		if id == "summon" then
			-- The boat card. Not an NpcChoice: BoatService owns the summon (and its
			-- own refusals - a boss fight, no water, no hull yet), and the panel's
			-- state does not change, so nothing needs re-drawing.
			Remotes.RequestBoat:FireServer("summon")
			return
		end
		sendChoice(id)
	end, MENU_ORDER)
	menu.gui.Parent = player:WaitForChild("PlayerGui")
end

function NpcDialogController.start()
	-- Dying mid-conversation has to END it. Both guis are ResetOnSpawn = false,
	-- so a respawn tears nothing down: the window would stay up with Escape
	-- still bound, aimed at an NPC now an island away, and the server would
	-- never hear the farewell that turns the body back to its post.
	player.CharacterRemoving:Connect(function()
		if NpcDialogController.isOpen() then
			NpcDialogController.close("farewell")
		end
	end)

	-- THE NEW-HULL FANFARE, carried over from the deleted crafting window. Only
	-- UPWARDS and only from a tier we have already seen: the attribute's first
	-- replication after a join is the server telling us what we already own, not a
	-- purchase, and a rung can be handed back down by an admin command.
	-- `lastBoatTier` is seeded before the connection, so the join value is never a
	-- "gain".
	local lastBoatTier = player:GetAttribute("BoatTier") or 0
	player:GetAttributeChangedSignal("BoatTier"):Connect(function()
		local tier = player:GetAttribute("BoatTier") or 0
		if tier > lastBoatTier then
			Sfx.play("boatUpgrade")
		end
		lastBoatTier = tier
	end)

	Remotes.NpcDialog.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" or type(payload.npcId) ~= "string" then
			return
		end
		-- Read the verdict BEFORE drawing (the typewriter would blip over it) and
		-- disarm either way, so a later plain re-open of the panel is silent.
		local cue = verdictCue(payload)
		pendingBuy = false
		if cue then
			Sfx.play(cue)
		end
		currentNpcId = payload.npcId
		if payload.pane == "menu" then
			stopTyping()
			clearReplies()
			menu.render(payload)
			showLayer("menu")
		elseif payload.pane == "dialogue" then
			renderTalk(payload)
		end
	end)
end

return NpcDialogController
