--!nonstrict
-- Kit.luau
-- The shared UI parts every menu and HUD is built from (2026-08-23 overhaul).
-- One place for the window shell, tabs, scrolling grids and lists, item
-- cards, buttons, stat pips, effect chips and ability cards, so the
-- inventory, crafting, travel and admin screens look like one game instead
-- of four copies of the same helpers drifting apart.
--
-- Everything is plain Roblox instances styled from Theme - no images are
-- required (none are uploaded yet): icons are "tiles", a rounded gradient
-- square carrying either the item's image, when a row has one, or a short
-- token in the display font (the material's first letters, an ability's
-- word). Swap a tile to an image later by giving the row an `icon` id.
--
-- Conventions: every builder returns the instance (or a small handle table)
-- and parents it for you; `order` sets LayoutOrder for list/grid children.

local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Theme)
local Rarity = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").Modules.Rarity)

local Kit = {}

local C = Theme.Color
local F = Theme.Font
local R = Theme.Radius
local S = Theme.Size

local HOVER_TIME = 0.08

-- ============================================================ primitives

function Kit.corner(inst: GuiObject, radius: number): UICorner
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = inst
	return corner
end

function Kit.stroke(inst: GuiObject, color: Color3, thickness: number, transparency: number?): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness
	stroke.Transparency = transparency or 0
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = inst
	return stroke
end

function Kit.gradient(inst: GuiObject, top: Color3, bottom: Color3, rotation: number?): UIGradient
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new(top, bottom)
	gradient.Rotation = rotation or 90
	gradient.Parent = inst
	return gradient
end

function Kit.padding(inst: GuiObject, left: number, top: number?, right: number?, bottom: number?): UIPadding
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, left)
	pad.PaddingTop = UDim.new(0, top or left)
	pad.PaddingRight = UDim.new(0, right or left)
	pad.PaddingBottom = UDim.new(0, bottom or top or left)
	pad.Parent = inst
	return pad
end

function Kit.listLayout(inst: GuiObject, gap: number, horizontal: boolean?): UIListLayout
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, gap)
	layout.FillDirection = if horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical
	layout.Parent = inst
	return layout
end

function Kit.frame(parent: Instance, props: { [string]: any }?): Frame
	local frame = Instance.new("Frame")
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	if props then
		for key, value in props do
			frame[key] = value
		end
	end
	frame.Parent = parent
	return frame
end

function Kit.label(parent: Instance, props: { [string]: any }?): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Font = F.body
	label.TextSize = S.body
	label.TextColor3 = C.text
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.Size = UDim2.new(1, 0, 0, S.body + 6)
	if props then
		for key, value in props do
			label[key] = value
		end
	end
	label.Parent = parent
	return label
end

-- A wrapped paragraph that grows to fit its text (for scrolling detail panels).
function Kit.paragraph(parent: Instance, text: string, props: { [string]: any }?): TextLabel
	local label = Kit.label(parent, {
		Text = text,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextColor3 = C.textDim,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
	})
	if props then
		for key, value in props do
			label[key] = value
		end
	end
	return label
end

-- Small-caps section header with a hairline under it: "ABILITY", "STATS".
function Kit.section(parent: Instance, text: string, order: number?): Frame
	local holder =
		Kit.frame(parent, { Name = "Section_" .. text, Size = UDim2.new(1, 0, 0, 22), LayoutOrder = order or 0 })
	Kit.label(holder, {
		Font = F.header,
		TextSize = S.section,
		TextColor3 = C.accent,
		Text = string.upper(text),
		Size = UDim2.new(1, 0, 0, 16),
	})
	local line = Kit.frame(holder, {
		BackgroundTransparency = 0.6,
		BackgroundColor3 = C.border,
		Position = UDim2.new(0, 0, 0, 20),
		Size = UDim2.new(1, 0, 0, 1),
	})
	line.BackgroundTransparency = 0.4
	return holder
end

function Kit.divider(parent: Instance, order: number?): Frame
	local line = Kit.frame(parent, { Name = "Divider", Size = UDim2.new(1, 0, 0, 1), LayoutOrder = order or 0 })
	line.BackgroundTransparency = 0.5
	line.BackgroundColor3 = C.border
	return line
end

-- A keyboard key cap: "I", "C", "ALT".
function Kit.keyCap(parent: Instance, key: string, props: { [string]: any }?): TextLabel
	local cap = Kit.label(parent, {
		Name = "Key_" .. key,
		Font = F.header,
		TextSize = 11,
		TextColor3 = C.textDim,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = key,
		Size = UDim2.fromOffset(math.max(20, 10 + #key * 7), 18),
		BackgroundTransparency = 0.2,
		BackgroundColor3 = C.background,
	})
	Kit.corner(cap, 5)
	Kit.stroke(cap, C.border, 1, 0.3)
	if props then
		for k, v in props do
			cap[k] = v
		end
	end
	return cap
end

-- ============================================================ tiles + gems

-- The short token a tile shows when a row has no image: the first letters
-- of up to two words ("Kelp Fiber" -> "KF", "Pearl" -> "PE").
function Kit.monogram(name: string): string
	local words = {}
	for word in string.gmatch(name, "%a+") do
		table.insert(words, word)
	end
	if #words >= 2 then
		return string.upper(string.sub(words[1], 1, 1) .. string.sub(words[2], 1, 1))
	elseif #words == 1 then
		return string.upper(string.sub(words[1], 1, 2))
	end
	return "?"
end

-- A rounded, gradient-lit square carrying an image or a token. `color` tints
-- the tile (a rarity, a material's colour, an effect's colour).
function Kit.tile(parent: Instance, opts): Frame
	local size = opts.size or 48
	local color = opts.color or C.panelLight
	local tile = Kit.frame(parent, {
		Name = opts.name or "Tile",
		Size = UDim2.fromOffset(size, size),
		BackgroundTransparency = 0,
		BackgroundColor3 = color,
		LayoutOrder = opts.order or 0,
		AnchorPoint = opts.anchor or Vector2.new(0, 0),
		Position = opts.position or UDim2.new(0, 0, 0, 0),
	})
	Kit.corner(tile, opts.radius or R.tile)
	Kit.gradient(tile, Color3.new(1, 1, 1), Color3.fromRGB(150, 150, 150), 90)
	Kit.stroke(tile, Color3.new(1, 1, 1), 1, 0.82)

	if opts.image and opts.image ~= "" then
		local image = Instance.new("ImageLabel")
		image.Name = "Image"
		image.BackgroundTransparency = 1
		image.AnchorPoint = Vector2.new(0.5, 0.5)
		image.Position = UDim2.fromScale(0.5, 0.5)
		image.Size = UDim2.fromScale(0.8, 0.8)
		image.Image = opts.image
		image.ScaleType = Enum.ScaleType.Fit
		image.ImageTransparency = opts.dim or 0
		image.Parent = tile
	else
		Kit.label(tile, {
			Name = "Token",
			Font = F.header,
			TextSize = opts.tokenSize or math.floor(size * 0.36),
			TextColor3 = Color3.new(1, 1, 1),
			TextTransparency = 0.08 + (opts.dim or 0),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextStrokeColor3 = Color3.new(0, 0, 0),
			TextStrokeTransparency = 0.75,
			Text = opts.token or "?",
			Size = UDim2.fromScale(1, 1),
		})
	end
	if opts.dim and opts.dim > 0 then
		tile.BackgroundTransparency = opts.dim * 0.6
	end
	return tile
end

-- A rarity "gem": a small rotated square in the rarity's colour.
function Kit.gem(parent: Instance, rarity: string?, size: number?): Frame
	local s = size or 10
	local gem = Kit.frame(parent, {
		Name = "Gem",
		Size = UDim2.fromOffset(s, s),
		BackgroundTransparency = 0,
		BackgroundColor3 = Rarity.colorOf(rarity),
		Rotation = 45,
	})
	Kit.corner(gem, 2)
	Kit.stroke(gem, Color3.new(1, 1, 1), 1, 0.7)
	return gem
end

-- Rarity word in its colour, with a gem beside it: "◆ RARE".
function Kit.rarityLine(parent: Instance, rarity: string?, order: number?): Frame
	local row = Kit.frame(parent, { Name = "RarityLine", Size = UDim2.new(1, 0, 0, 16), LayoutOrder = order or 0 })
	local gem = Kit.gem(row, rarity, 9)
	gem.Position = UDim2.new(0, 4, 0.5, 0)
	gem.AnchorPoint = Vector2.new(0.5, 0.5)
	Kit.label(row, {
		Font = F.header,
		TextSize = S.small,
		TextColor3 = Rarity.colorOf(rarity),
		Text = string.upper(rarity or ""),
		Position = UDim2.new(0, 16, 0, 0),
		Size = UDim2.new(1, -16, 1, 0),
	})
	return row
end

-- ============================================================ buttons

local BUTTON_STYLES = {
	primary = { bg = C.accent, text = C.textOnAccent, hover = Color3.fromRGB(140, 232, 240) },
	success = { bg = C.green, text = C.textOnAccent, hover = Color3.fromRGB(140, 232, 166) },
	danger = { bg = C.red, text = C.text, hover = Color3.fromRGB(244, 128, 120) },
	gold = { bg = C.gold, text = C.textOnAccent, hover = Color3.fromRGB(255, 222, 140) },
	secondary = { bg = C.panelLight, text = C.text, hover = C.panelHover },
	ghost = { bg = C.panel, text = C.textDim, hover = C.panelLight, transparency = 0.3 },
}

-- A rounded button. `style` picks the palette; `enabled = false` greys it
-- and swallows clicks (Activated still fires; check button:GetAttribute
-- "Enabled" or use the returned handle's `enabled` field).
function Kit.button(parent: Instance, opts): TextButton
	local style = BUTTON_STYLES[opts.style or "primary"] or BUTTON_STYLES.primary
	local enabled = opts.enabled ~= false

	local button = Instance.new("TextButton")
	button.Name = opts.name or ("Button_" .. tostring(opts.text))
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.Font = F.header
	button.TextSize = opts.textSize or S.button
	button.Text = opts.text or ""
	button.Size = opts.size or UDim2.new(1, 0, 0, 44)
	button.Position = opts.position or UDim2.new(0, 0, 0, 0)
	button.AnchorPoint = opts.anchor or Vector2.new(0, 0)
	button.LayoutOrder = opts.order or 0
	button.BackgroundColor3 = if enabled then style.bg else C.panelLight
	button.BackgroundTransparency = if enabled then (style.transparency or 0) else 0.2
	button.TextColor3 = if enabled then style.text else C.textDim
	button:SetAttribute("Enabled", enabled)
	button.Parent = parent
	Kit.corner(button, opts.radius or R.button)
	if enabled and style.bg ~= C.panel then
		Kit.gradient(button, Color3.new(1, 1, 1), Color3.fromRGB(196, 196, 196), 90)
	end
	local stroke = Kit.stroke(button, Color3.new(1, 1, 1), 1, if enabled then 0.75 else 0.9)

	button.MouseEnter:Connect(function()
		if button:GetAttribute("Enabled") then
			TweenService:Create(button, TweenInfo.new(HOVER_TIME), { BackgroundColor3 = style.hover }):Play()
			stroke.Transparency = 0.5
		end
	end)
	button.MouseLeave:Connect(function()
		if button:GetAttribute("Enabled") then
			TweenService:Create(button, TweenInfo.new(HOVER_TIME), { BackgroundColor3 = style.bg }):Play()
			stroke.Transparency = 0.75
		end
	end)
	return button
end

-- Re-style an existing Kit.button (the label and enabled state change a lot
-- on detail panels: Equip -> Equipped, Craft grey -> green).
function Kit.setButton(button: TextButton, opts)
	local style = BUTTON_STYLES[opts.style or "primary"] or BUTTON_STYLES.primary
	local enabled = opts.enabled ~= false
	if opts.text then
		button.Text = opts.text
	end
	button.BackgroundColor3 = if enabled then style.bg else C.panelLight
	button.BackgroundTransparency = if enabled then (style.transparency or 0) else 0.2
	button.TextColor3 = if enabled then style.text else (opts.disabledText or C.textDim)
	button:SetAttribute("Enabled", enabled)
end

-- The round "X" that closes a window.
function Kit.closeButton(parent: Instance): TextButton
	local button = Instance.new("TextButton")
	button.Name = "Close"
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.AnchorPoint = Vector2.new(1, 0.5)
	button.Position = UDim2.new(1, -14, 0.5, 0)
	button.Size = UDim2.fromOffset(36, 36)
	button.BackgroundColor3 = C.background
	button.BackgroundTransparency = 0.25
	button.Font = F.header
	button.TextSize = 18
	button.TextColor3 = C.text
	-- Plain ASCII on purpose: the fonts have no glyph for a real cross.
	button.Text = "X"
	button.Parent = parent
	Kit.corner(button, 18)
	Kit.stroke(button, Color3.new(1, 1, 1), 1, 0.8)
	button.MouseEnter:Connect(function()
		button.BackgroundColor3 = C.red
		button.BackgroundTransparency = 0
	end)
	button.MouseLeave:Connect(function()
		button.BackgroundColor3 = C.background
		button.BackgroundTransparency = 0.25
	end)
	return button
end

-- ============================================================ the window shell

-- A centred modal: dimmed backdrop (Modal, so first-person releases the
-- mouse; clicking it closes), a window with a driftwood header bar carrying
-- the title, an optional subtitle slot, and a close button. Returns the
-- pieces the caller wires up. `body` is the area under the header.
function Kit.modal(opts)
	local gui = Instance.new("ScreenGui")
	gui.Name = opts.name or "ModalGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = opts.displayOrder or 10

	local backdrop = Instance.new("TextButton")
	backdrop.Name = "Backdrop"
	backdrop.AutoButtonColor = false
	backdrop.Text = ""
	backdrop.BackgroundColor3 = Color3.fromRGB(4, 10, 16)
	backdrop.BackgroundTransparency = 0.4
	backdrop.BorderSizePixel = 0
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.Visible = false
	backdrop.ZIndex = 2
	backdrop.Modal = true
	backdrop.Parent = gui

	local window = Instance.new("Frame")
	window.Name = "Window"
	window.AnchorPoint = Vector2.new(0.5, 0.5)
	window.Position = UDim2.fromScale(0.5, 0.5)
	window.Size = opts.size or UDim2.new(0.78, 0, 0.8, 0)
	window.BackgroundColor3 = C.background
	window.BorderSizePixel = 0
	window.ZIndex = 3
	window.ClipsDescendants = true
	window.Parent = backdrop
	Kit.corner(window, R.window)
	Kit.stroke(window, C.borderLight, 1.5, 0.35)

	if opts.minSize or opts.maxSize then
		local limit = Instance.new("UISizeConstraint")
		limit.MinSize = opts.minSize or Vector2.new(0, 0)
		limit.MaxSize = opts.maxSize or Vector2.new(math.huge, math.huge)
		limit.Parent = window
	end

	-- Clicks inside the window must not fall through to the backdrop.
	local shield = Instance.new("TextButton")
	shield.Name = "Shield"
	shield.AutoButtonColor = false
	shield.Text = ""
	shield.BackgroundTransparency = 1
	shield.Size = UDim2.fromScale(1, 1)
	shield.ZIndex = 0
	shield.Parent = window

	-- Header: driftwood bar with a foam line under it.
	local HEADER = 62
	local header = Kit.frame(window, {
		Name = "Header",
		Size = UDim2.new(1, 0, 0, HEADER),
		BackgroundTransparency = 0,
		BackgroundColor3 = C.wood,
	})
	Kit.gradient(header, C.wood, C.woodDark, 90)
	local foam = Kit.frame(window, {
		Name = "Foam",
		Position = UDim2.new(0, 0, 0, HEADER),
		Size = UDim2.new(1, 0, 0, 3),
		BackgroundTransparency = 0,
		BackgroundColor3 = C.accent,
	})
	foam.BackgroundTransparency = 0.15

	-- Title tile + title + subtitle.
	local titleTile = Kit.tile(header, {
		name = "TitleTile",
		size = 40,
		color = C.accentDark,
		token = opts.token or "",
		tokenSize = 14,
		position = UDim2.new(0, 16, 0.5, 0),
		anchor = Vector2.new(0, 0.5),
		radius = 12,
	})
	titleTile.Visible = opts.token ~= nil

	local textX = if opts.token ~= nil then 68 else 20
	local title = Kit.label(header, {
		Name = "Title",
		Font = F.header,
		TextSize = S.title,
		TextColor3 = C.sand,
		TextStrokeColor3 = C.woodDark,
		TextStrokeTransparency = 0.6,
		Text = opts.title or "",
		Position = UDim2.new(0, textX, 0, if opts.subtitle ~= nil then 9 else 0),
		Size = UDim2.new(1, -(textX + 70), 0, if opts.subtitle ~= nil then 30 else HEADER),
	})
	local subtitle = Kit.label(header, {
		Name = "Subtitle",
		Font = F.body,
		TextSize = S.subtitle,
		TextColor3 = C.sand,
		TextTransparency = 0.3,
		Text = opts.subtitle or "",
		Position = UDim2.new(0, textX, 0, 37),
		Size = UDim2.new(1, -(textX + 70), 0, 18),
		Visible = opts.subtitle ~= nil,
	})

	local close = Kit.closeButton(header)

	local body = Kit.frame(window, {
		Name = "Body",
		Position = UDim2.new(0, 0, 0, HEADER + 3),
		Size = UDim2.new(1, 0, 1, -(HEADER + 3)),
	})

	return {
		gui = gui,
		backdrop = backdrop,
		window = window,
		header = header,
		title = title,
		subtitle = subtitle,
		close = close,
		body = body,
	}
end

-- ============================================================ tabs

-- A row of pill tabs, each with a small token tile. `onSelect(kind)` fires
-- on click; the handle's `set(kind)` restyles without firing.
function Kit.tabs(parent: Instance, tabs, onSelect)
	local row = Kit.frame(parent, { Name = "Tabs", Size = UDim2.new(1, 0, 0, 38) })
	Kit.listLayout(row, 8, true)

	local buttons = {}
	local handle = {}

	function handle.set(kind: string)
		for tabKind, button in buttons do
			local active = tabKind == kind
			button.BackgroundColor3 = if active then C.accent else C.panel
			button.BackgroundTransparency = if active then 0 else 0.1
			local text = button:FindFirstChild("Text")
			if text then
				text.TextColor3 = if active then C.textOnAccent else C.textDim
			end
			local stroke = button:FindFirstChildOfClass("UIStroke")
			if stroke then
				stroke.Transparency = if active then 1 else 0.5
			end
			local tile = button:FindFirstChild("Tile")
			if tile then
				tile.BackgroundColor3 = if active then C.accentDark else C.panelLight
			end
		end
	end

	for i, tab in tabs do
		local button = Instance.new("TextButton")
		button.Name = "Tab_" .. tab.kind
		button.AutoButtonColor = false
		button.Text = ""
		button.BorderSizePixel = 0
		button.LayoutOrder = i
		button.Size = UDim2.fromOffset(tab.width or 118, 38)
		button.BackgroundColor3 = C.panel
		button.Parent = row
		Kit.corner(button, 19)
		Kit.stroke(button, C.border, 1, 0.5)

		Kit.tile(button, {
			name = "Tile",
			size = 26,
			color = C.panelLight,
			token = tab.token or Kit.monogram(tab.label),
			tokenSize = 10,
			position = UDim2.new(0, 6, 0.5, 0),
			anchor = Vector2.new(0, 0.5),
			radius = 13,
		})
		Kit.label(button, {
			Name = "Text",
			Font = F.header,
			TextSize = 15,
			TextColor3 = C.textDim,
			Text = tab.label,
			Position = UDim2.new(0, 38, 0, 0),
			Size = UDim2.new(1, -42, 1, 0),
		})

		button.MouseEnter:Connect(function()
			if button.BackgroundColor3 ~= C.accent then
				button.BackgroundColor3 = C.panelLight
			end
		end)
		button.MouseLeave:Connect(function()
			if button.BackgroundColor3 ~= C.accent then
				button.BackgroundColor3 = C.panel
			end
		end)
		button.Activated:Connect(function()
			handle.set(tab.kind)
			onSelect(tab.kind)
		end)
		buttons[tab.kind] = button
	end

	handle.row = row
	return handle
end

-- ============================================================ scrolling

-- A styled ScrollingFrame whose canvas grows with its content. `grid` =
-- { cell, gap } lays children out as a grid; otherwise a vertical list with
-- `gap` between children.
function Kit.scroll(parent: Instance, opts): ScrollingFrame
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = opts.name or "Scroll"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Position = opts.position or UDim2.new(0, 0, 0, 0)
	scroll.Size = opts.size or UDim2.fromScale(1, 1)
	scroll.AnchorPoint = opts.anchor or Vector2.new(0, 0)
	scroll.ScrollBarThickness = 6
	scroll.ScrollBarImageColor3 = C.accent
	scroll.ScrollBarImageTransparency = 0.35
	scroll.VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar
	scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.ElasticBehavior = Enum.ElasticBehavior.Always
	scroll.Parent = parent

	if opts.grid then
		local layout = Instance.new("UIGridLayout")
		layout.CellSize = UDim2.fromOffset(opts.grid.cell, opts.grid.cellHeight or opts.grid.cell)
		layout.CellPadding = UDim2.fromOffset(opts.grid.gap, opts.grid.gap)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = scroll
	else
		Kit.listLayout(scroll, opts.gap or 8)
	end
	local pad = opts.padding or 4
	Kit.padding(scroll, pad, pad, pad + 6, pad + 12)
	return scroll
end

-- ============================================================ item cards

-- A grid card for an item: a rarity gem, a tile (image or monogram), the
-- name, and optional badges - a count pill (materials / bait), an "in
-- hand" ring (equipped), a lock veil (not owned). Returns a handle:
--   frame, setSelected(bool), setTag(text, color), setCount(n)
function Kit.card(parent: Instance, opts)
	local size = opts.size or 96
	local dim = opts.dim or 0

	local card = Instance.new("TextButton")
	card.Name = opts.name and ("Card_" .. opts.name) or "Card"
	card.AutoButtonColor = false
	card.Text = ""
	card.BorderSizePixel = 0
	card.Size = UDim2.fromOffset(size, size + 22)
	card.LayoutOrder = opts.order or 0
	card.BackgroundColor3 = C.panel
	card.BackgroundTransparency = dim * 0.4
	card.Parent = parent
	Kit.corner(card, R.card)
	local stroke = Kit.stroke(card, C.border, 1, 0.3)
	Kit.gradient(card, Color3.new(1, 1, 1), Color3.fromRGB(214, 214, 214), 90)

	local tileColor = if opts.locked then C.panelLight else (opts.color or Rarity.colorOf(opts.rarity))
	local tile = Kit.tile(card, {
		name = "Tile",
		size = size - 34,
		color = tileColor,
		image = if opts.locked then nil else opts.image,
		token = if opts.locked then "?" else (opts.token or Kit.monogram(opts.label or "")),
		position = UDim2.new(0.5, 0, 0, 10),
		anchor = Vector2.new(0.5, 0),
		dim = dim,
	})

	-- Rarity gem top-left.
	if opts.rarity then
		local gem = Kit.gem(card, opts.rarity, 9)
		gem.Position = UDim2.new(0, 12, 0, 13)
		gem.AnchorPoint = Vector2.new(0.5, 0.5)
	end

	Kit.label(card, {
		Name = "Label",
		Font = F.bodyBold,
		TextSize = 12,
		TextColor3 = if opts.locked then C.textDim else C.text,
		TextTransparency = dim,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = opts.label or "",
		Position = UDim2.new(0, 4, 0, size - 20),
		Size = UDim2.new(1, -8, 0, 18),
	})

	local tag = Kit.label(card, {
		Name = "Tag",
		Font = F.header,
		TextSize = 11,
		TextColor3 = C.textDim,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "",
		Position = UDim2.new(0, 4, 1, -20),
		Size = UDim2.new(1, -8, 0, 16),
	})

	-- Count pill, top-right.
	local count = Kit.label(card, {
		Name = "Count",
		Font = F.header,
		TextSize = 11,
		TextColor3 = C.text,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -6, 0, 6),
		Size = UDim2.fromOffset(30, 17),
		BackgroundTransparency = 0.15,
		BackgroundColor3 = C.background,
		Visible = false,
	})
	Kit.corner(count, 9)

	-- "In hand" ring: a foam dot top-left over the gem's row.
	local ring = Kit.frame(card, {
		Name = "Equipped",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -7, 0, size - 22),
		Size = UDim2.fromOffset(14, 14),
		BackgroundTransparency = 0,
		BackgroundColor3 = C.accent,
		Visible = opts.equipped == true,
	})
	Kit.corner(ring, 7)
	Kit.stroke(ring, C.background, 2)

	local handle = { frame = card, tile = tile }

	function handle.setSelected(on: boolean)
		stroke.Color = if on then C.accent else C.border
		stroke.Thickness = if on then 2.5 else 1
		stroke.Transparency = if on then 0 else 0.3
		card.BackgroundColor3 = if on then C.panelLight else C.panel
	end

	function handle.setTag(text: string?, color: Color3?)
		tag.Text = text or ""
		tag.TextColor3 = color or C.textDim
	end

	function handle.setCount(n: number?)
		count.Visible = n ~= nil
		count.Text = if n then "x" .. tostring(n) else ""
	end

	function handle.setEquipped(on: boolean)
		ring.Visible = on
	end

	if opts.count then
		handle.setCount(opts.count)
	end
	if opts.tag then
		handle.setTag(opts.tag, opts.tagColor)
	end

	card.MouseEnter:Connect(function()
		if stroke.Thickness < 2 then
			card.BackgroundColor3 = C.panelHover
		end
	end)
	card.MouseLeave:Connect(function()
		if stroke.Thickness < 2 then
			card.BackgroundColor3 = C.panel
		end
	end)
	if opts.onSelect then
		card.Activated:Connect(opts.onSelect)
	end
	return handle
end

-- ============================================================ stats + effects

-- A stat as five pips: "Luck  ●●●○○". `value` is 0..1.
function Kit.pips(parent: Instance, opts): Frame
	local row = Kit.frame(
		parent,
		{ Name = "Pips_" .. tostring(opts.label), Size = UDim2.new(1, 0, 0, 22), LayoutOrder = opts.order or 0 }
	)
	Kit.label(row, {
		Font = F.bodyBold,
		TextSize = 13,
		TextColor3 = C.textDim,
		Text = opts.label or "",
		Size = UDim2.new(0.45, 0, 1, 0),
	})
	local count = opts.count or 5
	local lit = math.clamp(math.floor((opts.value or 0) * count + 0.5), 0, count)
	local pipSize = 12
	local gap = 5
	local holder = Kit.frame(row, {
		Name = "Dots",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(count * pipSize + (count - 1) * gap, pipSize),
	})
	for i = 1, count do
		local pip = Kit.frame(holder, {
			Name = "Pip" .. i,
			Position = UDim2.new(0, (i - 1) * (pipSize + gap), 0, 0),
			Size = UDim2.fromOffset(pipSize, pipSize),
			BackgroundTransparency = 0,
			BackgroundColor3 = if i <= lit then (opts.color or C.accent) else C.panelLight,
		})
		Kit.corner(pip, 6)
		if i <= lit then
			Kit.stroke(pip, Color3.new(1, 1, 1), 1, 0.7)
		else
			Kit.stroke(pip, C.border, 1, 0.4)
		end
	end
	return row
end

-- An effect chip: a small coloured token tile + one plain line.
function Kit.chip(parent: Instance, opts): Frame
	local chip = Kit.frame(parent, {
		Name = "Chip_" .. tostring(opts.token),
		Size = UDim2.new(1, 0, 0, 34),
		LayoutOrder = opts.order or 0,
		BackgroundTransparency = 0.55,
		BackgroundColor3 = C.panelLight,
	})
	Kit.corner(chip, 10)
	Kit.tile(chip, {
		name = "Tile",
		size = 26,
		color = opts.color or C.accentDark,
		token = opts.token or "",
		tokenSize = 9,
		position = UDim2.new(0, 5, 0.5, 0),
		anchor = Vector2.new(0, 0.5),
		radius = 8,
	})
	Kit.label(chip, {
		Font = F.bodyBold,
		TextSize = 13,
		TextColor3 = opts.textColor or C.text,
		Text = opts.text or "",
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.new(0, 38, 0, 0),
		Size = UDim2.new(1, -44, 1, 0),
	})
	return chip
end

-- An ability card: the power-up a rod / weapon carries. A big token tile in
-- the ability's colour, its name, and the one-line description, wrapped.
function Kit.abilityCard(parent: Instance, opts): Frame
	local card = Kit.frame(parent, {
		Name = "Ability",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = opts.order or 0,
		BackgroundTransparency = 0,
		BackgroundColor3 = C.panelLight,
	})
	Kit.corner(card, 12)
	Kit.stroke(card, opts.color or C.accent, 1, 0.35)
	Kit.gradient(card, Color3.new(1, 1, 1), Color3.fromRGB(200, 200, 200), 90)
	Kit.padding(card, 10, 10, 10, 10)

	Kit.tile(card, {
		name = "Tile",
		size = 44,
		color = opts.color or C.accentDark,
		token = opts.token or "",
		tokenSize = 11,
	})
	Kit.label(card, {
		Name = "Name",
		Font = F.header,
		TextSize = 16,
		TextColor3 = opts.color or C.accent,
		Text = opts.name or "",
		Position = UDim2.new(0, 54, 0, 0),
		Size = UDim2.new(1, -54, 0, 20),
	})
	Kit.label(card, {
		Name = "Text",
		Font = F.body,
		TextSize = 13,
		TextColor3 = C.text,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = opts.text or "",
		Position = UDim2.new(0, 54, 0, 22),
		Size = UDim2.new(1, -54, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	})
	-- A spacer so AutomaticSize counts the tile when the text is short.
	Kit.frame(card, { Size = UDim2.new(0, 1, 0, 44) })
	return card
end

-- A requirement line for a recipe: tile + name + a have/need bar.
function Kit.requirement(parent: Instance, opts): Frame
	local row = Kit.frame(
		parent,
		{ Name = "Req_" .. tostring(opts.label), Size = UDim2.new(1, 0, 0, 30), LayoutOrder = opts.order or 0 }
	)
	Kit.tile(row, {
		name = "Tile",
		size = 24,
		color = opts.color or C.panelLight,
		image = opts.image,
		token = opts.token or Kit.monogram(opts.label or ""),
		tokenSize = 9,
		position = UDim2.new(0, 0, 0.5, 0),
		anchor = Vector2.new(0, 0.5),
		radius = 7,
	})
	local ok = (opts.have or 0) >= (opts.need or 0)
	Kit.label(row, {
		Font = F.bodyBold,
		TextSize = 13,
		TextColor3 = if ok then C.text else C.textDim,
		Text = opts.label or "",
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.new(0, 32, 0, 0),
		Size = UDim2.new(0.55, -32, 0, 16),
	})
	-- Have / need, as a tiny bar with the numbers beside it.
	local track = Kit.frame(row, {
		Name = "Track",
		Position = UDim2.new(0, 32, 0, 19),
		Size = UDim2.new(0.55, -32, 0, 5),
		BackgroundTransparency = 0,
		BackgroundColor3 = C.background,
	})
	Kit.corner(track, 3)
	local fill = Kit.frame(track, {
		Name = "Fill",
		Size = UDim2.fromScale(math.clamp((opts.have or 0) / math.max(1, opts.need or 1), 0, 1), 1),
		BackgroundTransparency = 0,
		BackgroundColor3 = if ok then C.green else C.red,
	})
	Kit.corner(fill, 3)
	Kit.label(row, {
		Font = F.header,
		TextSize = 13,
		TextColor3 = if ok then C.green else C.red,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = string.format("%s / %s", tostring(opts.have or 0), tostring(opts.need or 0)),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.new(0.45, 0, 1, 0),
	})
	return row
end

-- A soft panel (detail column, list box).
function Kit.panel(parent: Instance, props: { [string]: any }?): Frame
	local panel = Kit.frame(parent, { BackgroundTransparency = 0, BackgroundColor3 = C.panel })
	Kit.corner(panel, R.panel)
	Kit.stroke(panel, C.border, 1, 0.4)
	if props then
		for key, value in props do
			panel[key] = value
		end
	end
	return panel
end

return Kit
