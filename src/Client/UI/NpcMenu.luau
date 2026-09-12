--!nonstrict
-- NpcMenu.luau
-- The NPC business panel: the dark, readable half of the conversation
-- redesign (2026-09-12). NpcDialogController owns the cinematic talk (black
-- screen, typed lines, full-sentence replies); when the talk ends the server
-- pushes a `pane = "menu"` payload and THIS draws it.
--
-- Why it has its own palette instead of Theme's: the shared kit is a bright
-- "sticker" theme - warm paper, cream text, a lagoon-blue chrome - and a wall
-- of quest text in cream on cream is the exact thing the user called
-- unreadable. So this file builds its own surfaces out of Kit's primitives
-- (corner / stroke / padding / listLayout / scroll, which are neutral) over a
-- charcoal ground with cream text and ONE warm accent. Theme.luau and Kit.luau
-- are untouched: nothing else in the game changes look because this panel
-- exists.
--
-- It draws and it reports. Every button calls `onChoice(id)` with a wire id the
-- SERVER understands ("accept:<q>", "claim:<q>", "buy:<n>", "talk",
-- "farewell") and nothing else: no local state machine, no assumptions about
-- what an id does. A fresh payload re-renders the whole panel, which is how a
-- purchase or a turn-in shows its result. Nothing is numbered.
--
-- TABS (user, 2026-09-12: "make the shop menu less confusing - add tabs"). The
-- work and the wares are no longer two sections in one scroll: a two-tab bar
-- sits under the header and the body shows ONE of them. A villager with no
-- stall has no bar at all, only their work - a tab bar with one tab is just
-- noise. The chosen tab is remembered for the session, and an incoming push
-- picks the tab its news belongs to: a purchase or a refusal re-opens on Trade,
-- anything about a quest on Work.
--
-- CRAFT (user, 2026-09-12: "move crafting entirely to the npcs"). The `C`
-- window is gone; a villager with `crafts = true` sends a third section, `craft`,
-- and gets a third tab. Inside it a row of SUB-TABS (Rods / Weapons / Armor /
-- Charms / Boats / Bait - only the ones with anything in them) picks one list of
-- cards, each card a recipe: name + level pill, the cost as coins and every
-- material as "3/6 Kelp Fiber" (dim where you are short), and the one action the
-- row has earned. Whether a Craft is pressable is the SERVER'S verdict
-- (`canCraft` / `reason`), never arithmetic done here - this file has never
-- decided what a player may do and does not start now.
--
-- Every field of the payload is optional. A missing `quests` is an empty Work
-- tab, a nil `shop` means this person keeps no stall (no tab bar, no Trade
-- tab), a nil `craft` means they work no bench, a missing `remark` hides the
-- speech strip. A payload is a wire message, and a wire message is allowed to be
-- sparse.

local Kit = require(script.Parent.Kit)

local NpcMenu = {}

-- ============================================================ palette

-- Charcoal ground, cream text, one warm brass accent. Contrast against the
-- panel ground is the whole point of the pass: body copy is 19px cream on
-- RGB(31,33,38), which is ~13:1.
local INK = Color3.fromRGB(31, 33, 38) -- the panel
local INK_DEEP = Color3.fromRGB(18, 19, 23) -- the scrim behind it
local INK_RAISE = Color3.fromRGB(42, 45, 52) -- cards, rows, the speech strip
local INK_SUNK = Color3.fromRGB(25, 27, 31) -- a locked card's ground
local EDGE = Color3.fromRGB(62, 66, 75) -- the 1px lighter border
local CREAM = Color3.fromRGB(245, 238, 220)
local CREAM_DIM = Color3.fromRGB(168, 163, 150)
local ACCENT = Color3.fromRGB(214, 154, 74) -- warm brass: pills, buttons, coins
local ACCENT_TEXT = Color3.fromRGB(28, 24, 18) -- ink ON the accent
local GOOD = Color3.fromRGB(138, 196, 120)

local FONT_HEAD = Enum.Font.GothamBold
local FONT_BODY = Enum.Font.GothamMedium

local SIZE_NAME = 26
local SIZE_BODY = 19
local SIZE_META = 15

local RADIUS = 10
local PAD = 12

-- Fixed chrome heights; the body takes whatever is left (see layout() below).
local HEADER_H = 68
local FOOTER_H = 44
local TAB_H = 32
local SUB_H = 26 -- the Craft tab's own row of sub-tabs, under the tab bar
local GAP = 10

-- Which tab a payload's `kind` belongs to. A push with no opinion (a plain
-- "menu", the "talk" replay) leaves the player where they were.
local KIND_TAB = {
	shop = "trade",
	bought = "trade",
	refused = "trade",
	quest_accept = "work",
	quest_done = "work",
	quest_refused = "work",
	crafted = "craft",
	craft_refused = "craft",
	equipped = "craft",
}

-- The three tabs, in bar order. A tab whose payload section is missing is not
-- drawn at all, and a bar with one tab left is not drawn either.
local TAB_DEFS = {
	{ key = "work", text = "Work" },
	{ key = "trade", text = "Trade" },
	{ key = "craft", text = "Craft" },
}

-- ============================================================ primitives

local function label(parent: Instance, text: string, props): TextLabel
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.BorderSizePixel = 0
	lbl.Font = FONT_BODY
	lbl.TextSize = SIZE_BODY
	lbl.TextColor3 = CREAM
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.TextYAlignment = Enum.TextYAlignment.Top
	lbl.RichText = false
	lbl.Text = text
	lbl.Size = UDim2.new(1, 0, 0, SIZE_BODY + 6)
	if props then
		for key, value in props do
			lbl[key] = value
		end
	end
	lbl.Parent = parent
	return lbl
end

local function surface(parent: Instance, color: Color3, props): Frame
	local frame = Kit.frame(parent, props)
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = 0
	Kit.corner(frame, RADIUS)
	Kit.stroke(frame, EDGE, 1, 0.25)
	return frame
end

-- A button in this panel's own language. `primary` fills with the accent,
-- otherwise it is an outlined cream button; `enabled = false` greys it out AND
-- disconnects it (a Buy the player cannot afford must not reach the server).
local function pressable(parent: Instance, opts): TextButton
	local button = Instance.new("TextButton")
	button.Name = opts.name or "Button"
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.Font = FONT_HEAD
	button.TextSize = SIZE_META + 1
	button.Text = opts.text
	button.Size = opts.size or UDim2.fromOffset(140, 34)
	button.Position = opts.position or UDim2.new(0, 0, 0, 0)
	button.AnchorPoint = opts.anchor or Vector2.new(0, 0)
	button.LayoutOrder = opts.order or 1
	local enabled = opts.enabled ~= false
	if opts.primary then
		button.BackgroundColor3 = if enabled then ACCENT else INK_RAISE
		button.BackgroundTransparency = 0
		button.TextColor3 = if enabled then ACCENT_TEXT else CREAM_DIM
	else
		button.BackgroundColor3 = INK_RAISE
		button.BackgroundTransparency = if enabled then 0 else 0.4
		button.TextColor3 = if enabled then CREAM else CREAM_DIM
	end
	Kit.corner(button, 8)
	Kit.stroke(button, EDGE, 1, 0.2)
	button.Parent = parent
	if enabled and opts.onClick then
		button.Activated:Connect(opts.onClick)
	end
	button.Active = enabled
	return button
end

-- A small accent word over a hairline, with an optional right-hand value - which
-- is where the coin balance lives on the Trade tab (the money belongs beside the
-- prices, not up in the chrome where it was easy to miss).
local function sectionHeader(parent: Instance, text: string, order: number, right: string?): Frame
	local holder = Kit.frame(parent, {
		Name = "Section_" .. text,
		Size = UDim2.new(1, 0, 0, 22),
		LayoutOrder = order,
	})
	label(holder, text, {
		Font = FONT_HEAD,
		TextSize = 13,
		TextColor3 = ACCENT,
		Size = UDim2.new(1, -140, 1, 0),
		TextYAlignment = Enum.TextYAlignment.Bottom,
	})
	if right then
		label(holder, right, {
			Name = "Right",
			Font = FONT_HEAD,
			TextSize = SIZE_META + 3,
			TextColor3 = ACCENT,
			TextXAlignment = Enum.TextXAlignment.Right,
			TextYAlignment = Enum.TextYAlignment.Bottom,
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, 0, 1, 0),
			Size = UDim2.fromOffset(136, 22),
		})
	end
	Kit.frame(holder, {
		Name = "Rule",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		Size = UDim2.new(1, 0, 0, 1),
		BackgroundColor3 = EDGE,
		BackgroundTransparency = 0.3,
	})
	return holder
end

-- ============================================================ quest cards

local STATUS_LOOK = {
	available = { text = "Available", color = ACCENT },
	active = { text = "In progress", color = CREAM_DIM },
	ready = { text = "Ready to hand in", color = GOOD },
	locked = { text = "Locked", color = CREAM_DIM },
}

local function pillText(card): (string, Color3)
	local look = STATUS_LOOK[card.status] or STATUS_LOOK.available
	if card.status == "active" then
		local done, total = 0, 0
		for _, row in card.progress or {} do
			total += 1
			if row.done then
				done += 1
			end
		end
		if total > 0 then
			return string.format("In progress %d/%d", done, total), look.color
		end
	end
	return look.text, look.color
end

-- One quest, as a card: a title row that toggles the detail, the blurb, the
-- objectives with their tallies, the reward line, and the one button this
-- status earns. A locked card shows the giver's reason instead of a button and
-- sits on a sunken ground so the eye skips it.
local function questCard(parent: Instance, card, order: number, onChoice)
	local locked = card.status == "locked"
	local frame = surface(parent, if locked then INK_SUNK else INK_RAISE, {
		Name = "Quest_" .. tostring(card.id),
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
	})
	Kit.padding(frame, PAD, PAD - 2, PAD, PAD - 2)
	Kit.listLayout(frame, 6)

	-- Status FIRST, then the name: what the player is scanning for down a stack of
	-- cards is "can I do anything with this one", not the title.
	local titleRow = Kit.frame(frame, { Name = "Title", Size = UDim2.new(1, 0, 0, 26), LayoutOrder = 1 })
	local pill, pillColor = pillText(card)
	local pillWidth = 22 + #pill * 7
	label(titleRow, tostring(card.name), {
		Font = FONT_HEAD,
		TextSize = SIZE_BODY + 1,
		TextColor3 = if locked then CREAM_DIM else CREAM,
		Position = UDim2.new(0, pillWidth + 10, 0, 0),
		Size = UDim2.new(1, -(pillWidth + 10 + 24), 1, 0),
		TextYAlignment = Enum.TextYAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	local pillFrame = Kit.frame(titleRow, {
		Name = "Pill",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.fromOffset(pillWidth, 22),
		BackgroundColor3 = pillColor,
		BackgroundTransparency = 0.78,
	})
	Kit.corner(pillFrame, 11)
	Kit.stroke(pillFrame, pillColor, 1, 0.45)
	label(pillFrame, pill, {
		Font = FONT_HEAD,
		TextSize = 13,
		TextColor3 = pillColor,
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center,
	})

	if card.blurb and card.blurb ~= "" then
		label(frame, card.blurb, {
			Name = "Blurb",
			TextSize = SIZE_META,
			TextColor3 = CREAM_DIM,
			TextWrapped = true,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
			LayoutOrder = 2,
		})
	end

	-- The detail block: objectives + reward, collapsed by default for work the
	-- player has not taken on (a stall with four offers is otherwise a wall).
	local detail = Kit.frame(frame, {
		Name = "Detail",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 3,
	})
	Kit.listLayout(detail, 4)
	detail.Visible = card.status == "active" or card.status == "ready"

	for index, row in card.progress or {} do
		local line = Kit.frame(detail, {
			Name = string.format("Objective%d", index),
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = index,
		})
		local tally = if row.done
			then "done"
			else string.format("%d/%d", tonumber(row.count) or 0, tonumber(row.needed) or 1)
		label(line, "- " .. tostring(row.text), {
			TextSize = SIZE_META + 1,
			TextColor3 = if row.done then GOOD else CREAM,
			TextWrapped = true,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, -64, 0, 0),
		})
		label(line, tally, {
			Name = "Tally",
			Font = FONT_HEAD,
			TextSize = SIZE_META,
			TextColor3 = if row.done then GOOD else CREAM_DIM,
			TextXAlignment = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 0, 0, 1),
			Size = UDim2.fromOffset(60, SIZE_META + 4),
		})
	end
	if card.reward and card.reward ~= "" then
		label(detail, tostring(card.reward), {
			Name = "Reward",
			TextSize = SIZE_META,
			TextColor3 = ACCENT,
			TextWrapped = true,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
			LayoutOrder = 90,
		})
	end

	-- The action, or the reason there isn't one.
	if locked then
		label(frame, "Locked: " .. tostring(card.locked or "not yet."), {
			Name = "Locked",
			TextSize = SIZE_META,
			TextColor3 = CREAM_DIM,
			TextWrapped = true,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
			LayoutOrder = 4,
		})
	elseif card.status == "available" or card.status == "ready" then
		local isAccept = card.status == "available"
		local row = Kit.frame(frame, { Name = "Action", Size = UDim2.new(1, 0, 0, 36), LayoutOrder = 4 })
		pressable(row, {
			name = "Act",
			text = if isAccept then "I'll take it" else "Hand it in",
			primary = true,
			anchor = Vector2.new(1, 0),
			position = UDim2.new(1, 0, 0, 2),
			size = UDim2.fromOffset(150, 32),
			onClick = function()
				onChoice((if isAccept then "accept:" else "claim:") .. tostring(card.id))
			end,
		})
	end

	-- The whole title row toggles the detail. It is a button UNDER the labels
	-- (ZIndex 0) so the pill and the name still read normally - and a chevron on
	-- the right says the row is a thing you can press, which nothing did before.
	local chevron = label(titleRow, "", {
		Name = "Chevron",
		Font = FONT_HEAD,
		TextSize = 13,
		TextColor3 = CREAM_DIM,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextYAlignment = Enum.TextYAlignment.Center,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(20, 22),
	})
	local function markChevron()
		chevron.Text = if detail.Visible then "\u{25B4}" else "\u{25BE}"
	end
	markChevron()

	local toggle = Instance.new("TextButton")
	toggle.Name = "Toggle"
	toggle.BackgroundTransparency = 1
	toggle.Text = ""
	toggle.Size = UDim2.fromScale(1, 1)
	toggle.ZIndex = 0
	toggle.Parent = titleRow
	toggle.Activated:Connect(function()
		detail.Visible = not detail.Visible
		markChevron()
	end)
end

-- ============================================================ trade rows

local function tradeRow(parent: Instance, row, coins: number, order: number, onChoice)
	local price = tonumber(row.price) or 0
	local amount = tonumber(row.amount) or 1
	local short = coins < price
	local frame = surface(parent, INK_RAISE, {
		Name = string.format("Slot%d", tonumber(row.index) or order),
		Size = UDim2.new(1, 0, 0, 40),
		LayoutOrder = order,
	})
	Kit.padding(frame, PAD, 0, PAD, 0)
	local name = if amount > 1 then string.format("%d x %s", amount, tostring(row.name)) else tostring(row.name)
	label(frame, name, {
		TextSize = SIZE_BODY - 1,
		TextColor3 = CREAM,
		Size = UDim2.new(1, -200, 1, 0),
		TextYAlignment = Enum.TextYAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	label(frame, string.format("%d coins", price), {
		Name = "Price",
		Font = FONT_HEAD,
		TextSize = SIZE_META,
		TextColor3 = if short and not row.owned then CREAM_DIM else ACCENT,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -96, 0.5, 0),
		Size = UDim2.fromOffset(90, 20),
		TextYAlignment = Enum.TextYAlignment.Center,
	})
	if row.owned then
		label(frame, "owned", {
			Name = "Owned",
			Font = FONT_HEAD,
			TextSize = SIZE_META,
			TextColor3 = GOOD,
			TextXAlignment = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, 0, 0.5, 0),
			Size = UDim2.fromOffset(88, 20),
			TextYAlignment = Enum.TextYAlignment.Center,
		})
		return
	end
	pressable(frame, {
		name = "Buy",
		text = if short then "Too dear" else "Buy",
		primary = not short,
		enabled = not short,
		anchor = Vector2.new(1, 0.5),
		position = UDim2.new(1, 0, 0.5, 0),
		size = UDim2.fromOffset(88, 30),
		onClick = function()
			onChoice("buy:" .. tostring(row.index))
		end,
	})
end

-- ============================================================ craft cards

-- A little run of coloured words on one line: the cost, and the heart line. Each
-- word is its own label because they are not all the same colour - a material you
-- are short of goes dim, which is the whole point of the row.
local function chipRow(parent: Instance, name: string, order: number): Frame
	local row = Kit.frame(parent, {
		Name = name,
		Size = UDim2.new(1, 0, 0, SIZE_META + 6),
		LayoutOrder = order,
	})
	Kit.listLayout(row, 10, true)
	return row
end

local function chip(parent: Instance, text: string, color: Color3, order: number)
	label(parent, text, {
		Font = FONT_HEAD,
		TextSize = SIZE_META,
		TextColor3 = color,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, SIZE_META + 6),
		TextYAlignment = Enum.TextYAlignment.Center,
		LayoutOrder = order,
	})
end

-- One recipe, as a card in the same language as a quest card: the level pill
-- first, then the name; the cost line; the reason it can't be worked yet, if the
-- server gave one; and the action row.
--
-- THE ACTIONS, and there is at most one decision per row:
--   a boat you have      -> Summon (the RequestBoat remote, via the controller)
--   a boat you outgrew   -> nothing, just the word
--   bait                 -> Craft (it stacks) AND Use / In use
--   gear you own         -> Equip / Equipped
--   anything else        -> Craft, greyed with its reason when the server says no
local function craftCard(parent: Instance, card, order: number, onChoice)
	local id = tostring(card.id or "")
	local kind = tostring(card.kind or "")
	local isBait = kind == "bait"
	local isBoat = kind == "boat"
	local frame = surface(parent, INK_RAISE, {
		Name = "Craft_" .. id,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
	})
	Kit.padding(frame, PAD, PAD - 2, PAD, PAD - 2)
	Kit.listLayout(frame, 6)

	local titleRow = Kit.frame(frame, { Name = "Title", Size = UDim2.new(1, 0, 0, 26), LayoutOrder = 1 })
	local level = tonumber(card.level) or 0
	local pill = if level > 0 then string.format("Lv %d", level) else "Basic"
	local pillWidth = 22 + #pill * 7
	local pillColor = if card.canCraft or card.owned then ACCENT else CREAM_DIM
	local pillFrame = Kit.frame(titleRow, {
		Name = "Pill",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.fromOffset(pillWidth, 22),
		BackgroundColor3 = pillColor,
		BackgroundTransparency = 0.78,
	})
	Kit.corner(pillFrame, 11)
	Kit.stroke(pillFrame, pillColor, 1, 0.45)
	label(pillFrame, pill, {
		Font = FONT_HEAD,
		TextSize = 13,
		TextColor3 = pillColor,
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center,
	})
	-- The right-hand word: how many bait you are holding, or that a piece is on
	-- you right now.
	local right = if isBait and (tonumber(card.count) or 0) > 0
		then string.format("x%d", tonumber(card.count) or 0)
		elseif card.equipped and not isBoat then "in use"
		elseif isBoat and card.equipped then "your boat"
		else ""
	local rightWidth = if right == "" then 0 else 22 + #right * 8
	label(titleRow, tostring(card.name or id), {
		Font = FONT_HEAD,
		TextSize = SIZE_BODY + 1,
		TextColor3 = CREAM,
		Position = UDim2.new(0, pillWidth + 10, 0, 0),
		Size = UDim2.new(1, -(pillWidth + 10 + rightWidth), 1, 0),
		TextYAlignment = Enum.TextYAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	if right ~= "" then
		label(titleRow, right, {
			Name = "Right",
			Font = FONT_HEAD,
			TextSize = SIZE_META,
			TextColor3 = GOOD,
			TextXAlignment = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, 0, 0.5, 0),
			Size = UDim2.fromOffset(rightWidth, 22),
			TextYAlignment = Enum.TextYAlignment.Center,
		})
	end

	-- THE COST. Coins first, then every material as have/need; dim is "you are
	-- short of this one", which is the fastest read on the card.
	local coinCost = tonumber(card.coins) or 0
	local materials = if type(card.materials) == "table" then card.materials else {}
	if card.craftable and (coinCost > 0 or #materials > 0) then
		local row = chipRow(frame, "Cost", 2)
		local slot = 0
		if coinCost > 0 then
			slot += 1
			chip(row, string.format("%d coins", coinCost), ACCENT, slot)
		end
		for _, mat in materials do
			if type(mat) == "table" then
				local have = tonumber(mat.have) or 0
				local need = tonumber(mat.need) or 0
				slot += 1
				chip(
					row,
					string.format("%d/%d %s", math.min(have, need), need, tostring(mat.name or mat.id)),
					if have < need then CREAM_DIM else CREAM,
					slot
				)
			end
		end
		-- Bait is the one thing a craft makes several of, and the old detail column
		-- said so in its recipe header ("Recipe - makes 3"). Same fact, one chip.
		local yield = tonumber(card.yield) or 0
		if yield > 1 then
			slot += 1
			chip(row, string.format("makes %d", yield), CREAM_DIM, slot)
		end
	end

	-- The heart gate (the island Legendaries): owned or undefeated, never a count.
	local hearts = if type(card.hearts) == "table" then card.hearts else nil
	if hearts and #hearts > 0 then
		local row = chipRow(frame, "Hearts", 3)
		for index, heart in hearts do
			if type(heart) == "table" then
				chip(
					row,
					string.format(
						"Heart of %s - %s",
						tostring(heart.name or heart.id),
						if heart.have then "yours" else "undefeated"
					),
					if heart.have then GOOD else CREAM_DIM,
					index
				)
			end
		end
	end

	local actions = Kit.frame(frame, { Name = "Action", Size = UDim2.new(1, 0, 0, 36), LayoutOrder = 6 })
	local reason = if type(card.reason) == "string" and card.reason ~= "" then card.reason else nil

	local function craftButton(x: number)
		pressable(actions, {
			name = "Craft",
			text = "Craft",
			primary = card.canCraft == true,
			enabled = card.canCraft == true,
			anchor = Vector2.new(1, 0),
			position = UDim2.new(1, x, 0, 2),
			size = UDim2.fromOffset(110, 32),
			onClick = function()
				onChoice("craft:" .. id)
			end,
		})
		-- A greyed button says "no"; the server's own sentence says why.
		if card.canCraft ~= true and reason then
			label(frame, reason, {
				Name = "Reason",
				TextSize = SIZE_META,
				TextColor3 = CREAM_DIM,
				TextWrapped = true,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.new(1, 0, 0, 0),
				LayoutOrder = 5,
			})
		end
	end

	if isBoat then
		if card.equipped then
			pressable(actions, {
				name = "Summon",
				text = "Summon",
				primary = true,
				anchor = Vector2.new(1, 0),
				position = UDim2.new(1, 0, 0, 2),
				size = UDim2.fromOffset(110, 32),
				onClick = function()
					onChoice("summon")
				end,
			})
		elseif card.owned then
			label(actions, "Outgrown.", {
				Name = "Outgrown",
				TextSize = SIZE_META,
				TextColor3 = CREAM_DIM,
				TextXAlignment = Enum.TextXAlignment.Right,
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, 0, 0, 8),
				Size = UDim2.fromOffset(160, 20),
			})
		elseif card.craftable then
			craftButton(0)
		else
			label(actions, "Won from a boss.", {
				Name = "Boss",
				TextSize = SIZE_META,
				TextColor3 = CREAM_DIM,
				TextXAlignment = Enum.TextXAlignment.Right,
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, 0, 0, 8),
				Size = UDim2.fromOffset(180, 20),
			})
		end
	elseif isBait then
		if card.craftable then
			craftButton(-118)
		end
		pressable(actions, {
			name = "Use",
			text = if card.equipped then "In use" else "Use",
			primary = not card.equipped,
			enabled = not card.equipped and (tonumber(card.count) or 0) > 0,
			anchor = Vector2.new(1, 0),
			position = UDim2.new(1, 0, 0, 2),
			size = UDim2.fromOffset(110, 32),
			onClick = function()
				onChoice("equip:bait:" .. id)
			end,
		})
	elseif card.owned then
		pressable(actions, {
			name = "Equip",
			text = if card.equipped then "Equipped" else "Equip",
			primary = not card.equipped,
			enabled = not card.equipped,
			anchor = Vector2.new(1, 0),
			position = UDim2.new(1, 0, 0, 2),
			size = UDim2.fromOffset(110, 32),
			onClick = function()
				onChoice(string.format("equip:%s:%s", kind, id))
			end,
		})
	elseif card.craftable then
		craftButton(0)
	end
end

-- ============================================================ the panel

-- Builds the panel once and returns a handle:
--   handle.gui                 the ScreenGui (the caller parents it)
--   handle.render(payload)     redraw from a `pane = "menu"` payload
--   handle.setVisible(open)
--   handle.isOpen()
function NpcMenu.new(onChoice: (string) -> (), displayOrder: number)
	local gui = Instance.new("ScreenGui")
	gui.Name = "NpcMenuGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = displayOrder
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false

	local scrim = Kit.frame(gui, {
		Name = "Scrim",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = INK_DEEP,
		BackgroundTransparency = 0.35,
	})

	local panel = surface(scrim, INK, {
		Name = "Panel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0.94, 0, 0.9, 0),
	})
	local cap = Instance.new("UISizeConstraint")
	cap.MaxSize = Vector2.new(600, 580)
	cap.MinSize = Vector2.new(280, 240)
	cap.Parent = panel
	Kit.padding(panel, 16, 14, 16, 14)

	-- Header: who this is. The coin balance used to live up here in the corner;
	-- it now sits in the Trade tab's own header row, next to the prices it is
	-- about.
	local header = Kit.frame(panel, { Name = "Header", Size = UDim2.new(1, 0, 0, HEADER_H) })
	local nameLabel = label(header, "", {
		Name = "Name",
		Font = FONT_HEAD,
		TextSize = SIZE_NAME,
		Size = UDim2.new(1, -8, 0, SIZE_NAME + 6),
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	local titleLabel = label(header, "", {
		Name = "Title",
		TextSize = SIZE_META,
		TextColor3 = CREAM_DIM,
		Position = UDim2.new(0, 0, 0, SIZE_NAME + 8),
		Size = UDim2.new(1, -8, 0, SIZE_META + 4),
		TextTruncate = Enum.TextTruncate.AtEnd,
	})

	-- The speech strip: what they just said. Height is content-driven, so the
	-- body below is re-laid-out whenever it changes (a two-line remark must not
	-- draw over the first quest card).
	local speech = surface(panel, INK_RAISE, {
		Name = "Speech",
		Position = UDim2.new(0, 0, 0, HEADER_H),
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	})
	Kit.padding(speech, PAD, 8, PAD, 8)
	local remarkLabel = label(speech, "", {
		Name = "Remark",
		TextSize = SIZE_BODY,
		TextWrapped = true,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
	})

	-- THE TABS. One of two things to look at, never both; the bar is hidden
	-- outright for a villager with nothing to sell, and `layout()` then gives the
	-- body the height it would have taken.
	local tabBar = Kit.frame(panel, { Name = "Tabs", Size = UDim2.new(1, 0, 0, TAB_H) })
	-- Hidden until a payload says there is a stall or a bench: the bar is built at
	-- the panel's origin, and an unrendered panel must not show it over the header.
	tabBar.Visible = false
	local tabButtons: { [string]: TextButton } = {}
	local currentTab = "work" -- remembered for the session, across NPCs
	local tabsShown = false
	local available: { [string]: boolean } = { work = true }
	local shown = nil -- the payload on screen, so a tab press can redraw it
	local drawBody -- defined below, once `body` exists

	-- Which tabs this payload has, and where each visible one sits. Work is always
	-- there; Trade and Craft come and go with the NPC, so the bar is re-laid-out per
	-- payload rather than positioned once at build time.
	local function paintTabs()
		local slot = 0
		for _, entry in TAB_DEFS do
			local button = tabButtons[entry.key]
			local here = available[entry.key] == true
			button.Visible = here
			if here then
				button.Position = UDim2.new(0, slot * 126, 0, 0)
				slot += 1
				local on = entry.key == currentTab
				button.BackgroundColor3 = if on then ACCENT else INK_RAISE
				button.BackgroundTransparency = if on then 0 else 0.35
				button.TextColor3 = if on then ACCENT_TEXT else CREAM_DIM
			end
		end
	end

	local function selectTab(key: string)
		if key == currentTab then
			return
		end
		currentTab = key
		paintTabs()
		if shown then
			drawBody(shown)
		end
	end

	for _, entry in TAB_DEFS do
		tabButtons[entry.key] = pressable(tabBar, {
			name = "Tab_" .. entry.key,
			text = entry.text,
			size = UDim2.fromOffset(118, TAB_H - 4),
			onClick = function()
				selectTab(entry.key)
			end,
		})
	end
	Kit.frame(tabBar, {
		Name = "Rule",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		Size = UDim2.new(1, 0, 0, 1),
		BackgroundColor3 = EDGE,
		BackgroundTransparency = 0.45,
	})
	paintTabs()

	-- THE CRAFT TAB'S SUB-TABS. Its own strip under the bar, outside the scroll so
	-- it cannot scroll away from the cards it picks. Rebuilt per payload (a
	-- villager whose Boats section is empty has no Boats sub-tab) and hidden
	-- outright on Work and Trade. Widths are a fraction of the strip so six of them
	-- still fit on a phone.
	local subBar = Kit.frame(panel, { Name = "SubTabs", Size = UDim2.new(1, 0, 0, SUB_H) })
	subBar.Visible = false
	local subShown = false
	local currentSub: string? = nil -- remembered across pushes, per session
	local layout -- defined below, once `body` exists

	local body = Kit.scroll(panel, {
		name = "Body",
		position = UDim2.new(0, 0, 0, HEADER_H + GAP),
		size = UDim2.new(1, 0, 1, -(HEADER_H + GAP + FOOTER_H + GAP)),
		gap = 8,
		padding = 2,
	})
	body.ScrollBarImageColor3 = EDGE
	body.ScrollBarImageTransparency = 0.2

	local footer = Kit.frame(panel, {
		Name = "Footer",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		Size = UDim2.new(1, 0, 0, FOOTER_H),
	})
	pressable(footer, {
		name = "Talk",
		text = "Talk some more",
		size = UDim2.fromOffset(170, 34),
		position = UDim2.new(0, 0, 0.5, 0),
		anchor = Vector2.new(0, 0.5),
		onClick = function()
			onChoice("talk")
		end,
	})
	local leaveButton = pressable(footer, {
		name = "Leave",
		text = "Farewell",
		primary = true,
		size = UDim2.fromOffset(170, 34),
		position = UDim2.new(1, 0, 0.5, 0),
		anchor = Vector2.new(1, 0.5),
		onClick = function()
			onChoice("farewell")
		end,
	})

	-- The one piece of layout arithmetic: header + (speech, if any) + (tabs, if
	-- any) + body + footer, with the body taking the remainder. Re-run on every
	-- change of the speech strip's measured height and of the panel's own size (a
	-- phone-width window wraps the remark onto three lines).
	local speechShown = false
	function layout()
		local speechH = if speechShown then speech.AbsoluteSize.Y + GAP else 0
		local top = HEADER_H + speechH
		tabBar.Position = UDim2.new(0, 0, 0, top)
		local tabsH = if tabsShown then TAB_H + GAP - 4 else 0
		subBar.Position = UDim2.new(0, 0, 0, top + tabsH)
		local subH = if subShown then SUB_H + 6 else 0
		body.Position = UDim2.new(0, 0, 0, top + tabsH + subH)
		body.Size = UDim2.new(1, 0, 1, -(top + tabsH + subH + FOOTER_H + GAP))
	end
	speech:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
	panel:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)

	-- ONE tab's worth of body, from the payload on screen. Called by render() and
	-- again by every tab press; it always starts from an empty scroll and at the
	-- top of it, because the two tabs are different lengths.
	function drawBody(payload)
		for _, child in body:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		for _, child in subBar:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		body.CanvasPosition = Vector2.new(0, 0)

		local coins = tonumber(payload.coins) or 0
		local quests = if type(payload.quests) == "table" then payload.quests else {}
		local shop = if type(payload.shop) == "table" then payload.shop else nil
		local hasShop = shop ~= nil and #shop > 0
		local craft = if type(payload.craft) == "table" then payload.craft else nil
		local hasCraft = craft ~= nil and #craft > 0

		-- THE CRAFT TAB. The sub-tab strip picks one section; the cards below are
		-- that section's rows, with the coin balance in the section header for the
		-- same reason Trade has it - the money belongs beside the prices.
		subShown = currentTab == "craft" and hasCraft
		subBar.Visible = subShown
		if subShown then
			local sections = {}
			for _, section in craft do
				if type(section) == "table" and type(section.items) == "table" and #section.items > 0 then
					table.insert(sections, section)
				end
			end
			if #sections == 0 then
				subShown = false
				subBar.Visible = false
			else
				local pickedIndex = 1
				for index, section in sections do
					if tostring(section.key) == currentSub then
						pickedIndex = index
					end
				end
				local picked = sections[pickedIndex]
				currentSub = tostring(picked.key)
				local width = 1 / #sections
				for index, section in sections do
					local on = index == pickedIndex
					local key = tostring(section.key)
					local button = pressable(subBar, {
						name = "Sub_" .. key,
						text = tostring(section.label or key),
						size = UDim2.new(width, -4, 1, 0),
						position = UDim2.new(width * (index - 1), 2, 0, 0),
						onClick = function()
							if currentSub ~= key then
								currentSub = key
								drawBody(payload)
							end
						end,
					})
					button.TextSize = SIZE_META - 1
					button.TextTruncate = Enum.TextTruncate.AtEnd
					button.BackgroundColor3 = if on then ACCENT else INK_RAISE
					button.BackgroundTransparency = if on then 0 else 0.35
					button.TextColor3 = if on then ACCENT_TEXT else CREAM_DIM
				end
				layout()
				sectionHeader(
					body,
					string.upper(tostring(picked.label or picked.key)),
					1,
					string.format("%d coins", coins)
				)
				for index, card in picked.items do
					if type(card) == "table" then
						craftCard(body, card, 1 + index, onChoice)
					end
				end
				return
			end
		end
		layout()

		if currentTab == "trade" and hasShop then
			-- The balance rides in the section header, and the hint under the rows
			-- says the one thing a price list can't: that nothing here is affordable
			-- yet.
			sectionHeader(body, "WARES", 1, string.format("%d coins", coins))
			local cheapest: number? = nil
			for index, row in shop do
				if type(row) == "table" then
					tradeRow(body, row, coins, 1 + index, onChoice)
					local price = tonumber(row.price) or 0
					if not row.owned and (cheapest == nil or price < cheapest) then
						cheapest = price
					end
				end
			end
			if cheapest and coins < cheapest then
				label(body, string.format("Short on coins - the cheapest thing here is %d.", cheapest), {
					Name = "Short",
					TextSize = SIZE_META,
					TextColor3 = CREAM_DIM,
					TextWrapped = true,
					AutomaticSize = Enum.AutomaticSize.Y,
					Size = UDim2.new(1, 0, 0, 0),
					LayoutOrder = 900,
				})
			end
			return
		end

		if #quests > 0 then
			for index, card in quests do
				if type(card) == "table" then
					questCard(body, card, index, onChoice)
				end
			end
			return
		end

		-- Nothing to do here today: say so rather than showing a blank panel.
		label(body, if hasShop then "No work today." else "No work and no wares today.", {
			Name = "Empty",
			TextSize = SIZE_BODY,
			TextColor3 = CREAM_DIM,
			TextWrapped = true,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
			LayoutOrder = 1,
		})
	end

	local handle = {}
	handle.gui = gui

	function handle.render(payload)
		shown = payload
		nameLabel.Text = tostring(payload.name or "")
		titleLabel.Text = tostring(payload.title or "")

		local remark = if type(payload.remark) == "string" and payload.remark ~= "" then payload.remark else nil
		speechShown = remark ~= nil
		speech.Visible = speechShown
		remarkLabel.Text = remark or ""

		-- The farewell button wears the NPC's own words.
		if type(payload.farewell) == "string" and payload.farewell ~= "" then
			leaveButton.Text = payload.farewell
		else
			leaveButton.Text = "Farewell"
		end

		-- No stall and no bench: a lone "Work" tab would only be a thing to wonder
		-- about. And a push lands on the tab its news is about - a purchase or a
		-- refusal on Trade, a craft or an equip on Craft, a quest on Work - falling
		-- back to wherever the player last was.
		local shop = if type(payload.shop) == "table" then payload.shop else nil
		local craft = if type(payload.craft) == "table" then payload.craft else nil
		available = {
			work = true,
			trade = shop ~= nil and #shop > 0,
			craft = craft ~= nil and #craft > 0,
		}
		local count = 0
		for _, here in available do
			if here then
				count += 1
			end
		end
		tabsShown = count > 1
		local want = KIND_TAB[payload.kind]
		if want and available[want] then
			currentTab = want
		end
		if not available[currentTab] then
			currentTab = "work"
		end
		tabBar.Visible = tabsShown
		paintTabs()
		layout()
		drawBody(payload)
	end

	function handle.setVisible(open: boolean)
		gui.Enabled = open
	end

	function handle.isOpen(): boolean
		return gui.Enabled
	end

	return handle
end

return NpcMenu
