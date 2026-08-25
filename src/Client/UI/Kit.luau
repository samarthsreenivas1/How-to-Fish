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
-- The 2026-08-24 "sticker" pass (user reference: bright pet-sim UI) made
-- the kit vibrant and cartoon, still image-free: every element carries a
-- thick INK outline (frames AND text glyphs, via UIStroke), chrome is
-- glossy candy blue (light top half from a hard split gradient), content
-- sits on warm paper stamped with a faint watermark school of fish, the
-- world blurs behind an open menu, and windows scale in with a pop.
-- Display text is white FredokaOne outlined in ink. The red-over-white
-- bobber stays as the one "yours / active" mark (equipped badge, lit stat
-- pips). Decor helpers live in the "sticker" section; every builder's
-- return shape is unchanged.
--
-- Conventions: every builder returns the instance (or a small handle table)
-- and parents it for you; `order` sets LayoutOrder for list/grid children.

local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")

local Theme = require(script.Parent.Theme)
local Rarity = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").Modules.Rarity)

local Kit = {}

local C = Theme.Color
local F = Theme.Font
local R = Theme.Radius
local S = Theme.Size

local HOVER_TIME = 0.08

-- One shared world blur behind whichever menus are open, refcounted so
-- swapping straight from one menu to another never strands it on.
local openMenus = 0
local menuBlur: BlurEffect? = nil
local function setMenuBlur(open: boolean)
	openMenus = math.max(0, openMenus + (if open then 1 else -1))
	if not menuBlur then
		menuBlur = Instance.new("BlurEffect")
		menuBlur.Name = "KitMenuBlur"
		menuBlur.Size = 0
		menuBlur.Parent = Lighting
	end
	TweenService:Create(menuBlur, TweenInfo.new(0.25), { Size = if openMenus > 0 then 12 else 0 }):Play()
end

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
	-- Ink by default: the kit is paper-first now. Chrome text (headers,
	-- tabs, buttons) sets white + an ink glyph outline explicitly.
	label.TextColor3 = C.ink
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

-- Small-caps section header over a cast line: a tiny sinker bead, then the
-- line pays out to the right and fades like it sank. "ABILITY", "STATS".
function Kit.section(parent: Instance, text: string, order: number?): Frame
	local holder =
		Kit.frame(parent, { Name = "Section_" .. text, Size = UDim2.new(1, 0, 0, 22), LayoutOrder = order or 0 })
	Kit.label(holder, {
		Font = F.header,
		TextSize = S.section,
		TextColor3 = C.accentDark,
		Text = string.upper(text),
		Size = UDim2.new(1, 0, 0, 16),
	})
	local sinker = Kit.frame(holder, {
		Name = "Sinker",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, 3, 0, 20),
		Size = UDim2.fromOffset(5, 5),
		BackgroundTransparency = 0.15,
		BackgroundColor3 = C.accentDark,
		Rotation = 45,
	})
	Kit.corner(sinker, 1)
	local line = Kit.frame(holder, {
		Name = "Line",
		BackgroundTransparency = 0,
		BackgroundColor3 = C.ink,
		Position = UDim2.new(0, 8, 0, 20),
		Size = UDim2.new(1, -8, 0, 1),
	})
	local fade = Instance.new("UIGradient")
	fade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(0.55, 0.6),
		NumberSequenceKeypoint.new(1, 1),
	})
	fade.Parent = line
	return holder
end

-- A stretch of fishing line: a hairline that fades out at both ends.
function Kit.divider(parent: Instance, order: number?): Frame
	local line = Kit.frame(parent, { Name = "Divider", Size = UDim2.new(1, 0, 0, 1), LayoutOrder = order or 0 })
	line.BackgroundTransparency = 0
	line.BackgroundColor3 = C.border
	local fade = Instance.new("UIGradient")
	fade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.2, 0.35),
		NumberSequenceKeypoint.new(0.8, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	fade.Parent = line
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
		BackgroundTransparency = 0,
		BackgroundColor3 = Color3.new(1, 1, 1),
	})
	Kit.corner(cap, 5)
	Kit.stroke(cap, C.ink, 1.5, 0.4)
	if props then
		for k, v in props do
			cap[k] = v
		end
	end
	return cap
end

-- ============================================================ sticker (decor)
-- The cartoon dressing every surface shares (2026-08-24 "sticker" pass):
-- ink outlines on frames AND text glyphs, glossy tops, watermark fish art
-- and the red/white bobber. All plain frames - still no images.

-- A hard two-tone vertical split (the bobber's waterline, a button's
-- glossy top half). Multiplies the instance's BackgroundColor3 like any
-- UIGradient, so use it on white/foam backgrounds.
local function splitGradient(inst: GuiObject, top: Color3, bottom: Color3, at: number): UIGradient
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, top),
		ColorSequenceKeypoint.new(math.max(at - 0.03, 0.01), top),
		ColorSequenceKeypoint.new(math.min(at + 0.03, 0.99), bottom),
		ColorSequenceKeypoint.new(1, bottom),
	})
	gradient.Rotation = 90
	gradient.Parent = inst
	return gradient
end

-- Chunky sticker text: an ink outline around the glyphs themselves. This
-- is what makes the white display text pop off any colour.
local function inkText(label: GuiObject, thickness: number?): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Color = C.ink
	stroke.Thickness = thickness or 2
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = label
	return stroke
end

-- A flat fish silhouette (round body + a rotated-square tail), used as
-- watermark pattern art on headers and content areas. `flip` points it the
-- other way.
local function stampFish(parent: Instance, opts): Frame
	local size = opts.size or 32
	local fish = Kit.frame(parent, {
		Name = "PatternFish",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = opts.position,
		Size = UDim2.fromOffset(size, math.max(7, math.floor(size * 0.46))),
		Rotation = opts.rotation or 0,
		BackgroundTransparency = 1,
	})
	local color = opts.color or C.ink
	local transparency = opts.transparency or 0.9
	local bodyPart = Kit.frame(fish, {
		Name = "Body",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(if opts.flip then 0.42 else 0.58, 0, 0.5, 0),
		Size = UDim2.new(0.68, 0, 1, 0),
		BackgroundTransparency = transparency,
		BackgroundColor3 = color,
	})
	Kit.corner(bodyPart, 99)
	local tail = Kit.frame(fish, {
		Name = "Tail",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(if opts.flip then 0.92 else 0.08, 0, 0.5, 0),
		Size = UDim2.new(0.3, 0, 0.6, 0),
		BackgroundTransparency = transparency,
		BackgroundColor3 = color,
		Rotation = 45,
	})
	Kit.corner(tail, 2)
	return fish
end

-- A glass highlight across the top of a rounded element - the "wet" look.
-- Rendered under any label/image the caller adds afterwards.
local function gloss(inst: GuiObject, radius: number, strength: number?): Frame
	local shine = Kit.frame(inst, {
		Name = "Gloss",
		Position = UDim2.new(0, 3, 0, 2),
		Size = UDim2.new(1, -6, 0.42, 0),
		BackgroundTransparency = strength or 0.8,
		BackgroundColor3 = Color3.new(1, 1, 1),
	})
	Kit.corner(shine, math.max(2, radius - 2))
	local fade = Instance.new("UIGradient")
	fade.Transparency = NumberSequence.new(0, 1)
	fade.Rotation = 90
	fade.Parent = shine
	return shine
end

-- The classic red-over-white float. It is the game's "yours / active" mark:
-- the close button, the "in hand" badge on cards and the lit stat pips are
-- all this one shape, so the motif reads everywhere. `topColor` swaps the
-- red half (tinted stat pips).
function Kit.bobber(parent: Instance, size: number, topColor: Color3?, props: { [string]: any }?): Frame
	local float = Kit.frame(parent, {
		Name = "Bobber",
		Size = UDim2.fromOffset(size, size),
		BackgroundTransparency = 0,
		BackgroundColor3 = C.foam,
	})
	Kit.corner(float, math.ceil(size / 2))
	splitGradient(float, topColor or C.bobberRed, C.foam, 0.5)
	Kit.stroke(float, C.ink, math.max(1.5, math.floor(size / 14)), 0.1)
	if size >= 24 then
		-- A specular glint on the red cap; too small to read below 24px.
		local glint = Kit.frame(float, {
			Name = "Glint",
			Position = UDim2.new(0.16, 0, 0.1, 0),
			Size = UDim2.new(0.4, 0, 0.24, 0),
			BackgroundTransparency = 0.4,
			BackgroundColor3 = Color3.new(1, 1, 1),
			Rotation = -16,
		})
		Kit.corner(glint, 99)
	end
	if props then
		for key, value in props do
			float[key] = value
		end
	end
	return float
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
	Kit.stroke(tile, C.ink, 1.5, 0.35)
	gloss(tile, opts.radius or R.tile)

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
	Kit.stroke(gem, C.ink, 1.5, 0.3)
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
	primary = { bg = C.accent, hover = Color3.fromRGB(110, 198, 250) },
	success = { bg = C.green, hover = Color3.fromRGB(130, 232, 146) },
	danger = { bg = C.red, hover = Color3.fromRGB(250, 122, 108) },
	gold = { bg = C.gold, hover = Color3.fromRGB(255, 216, 116) },
	secondary = { bg = C.panel, hover = C.panelLight },
	ghost = { bg = Color3.fromRGB(148, 190, 220), hover = Color3.fromRGB(170, 208, 234) },
}
local BUTTON_DISABLED_BG = Color3.fromRGB(174, 192, 206)
local BUTTON_DISABLED_TEXT = Color3.fromRGB(236, 242, 247)

-- Every button renders slightly lightened; the split gradient darkens the
-- bottom half back to the base colour, which is what makes the top half
-- read as gloss (a UIGradient can only darken, never lighten).
local function glossBase(color: Color3): Color3
	return color:Lerp(Color3.new(1, 1, 1), 0.22)
end

-- A glossy sticker button: candy colour, light top half, thick ink outline,
-- white display text outlined in ink. `style` picks the colour; `enabled =
-- false` greys it and swallows clicks (Activated still fires; check
-- button:GetAttribute "Enabled").
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
	button.BackgroundColor3 = glossBase(if enabled then style.bg else BUTTON_DISABLED_BG)
	button.TextColor3 = if enabled then C.text else BUTTON_DISABLED_TEXT
	button:SetAttribute("Enabled", enabled)
	button.Parent = parent
	Kit.corner(button, opts.radius or R.button)
	splitGradient(button, Color3.new(1, 1, 1), Color3.fromRGB(200, 200, 200), 0.46)
	inkText(button, 2)
	-- Named: the button carries TWO UIStrokes (glyph outline + border), so
	-- setButton must find this one by name, never by class.
	local stroke = Kit.stroke(button, C.ink, 2.5, if enabled then 0.05 else 0.4)
	stroke.Name = "InkBorder"

	-- Hover swell and press dip, one UIScale (not Position, so buttons inside
	-- list layouts and anchored slots all move in place).
	local scale = Instance.new("UIScale")
	scale.Parent = button
	local hovering = false
	local pressed = false
	local function settle()
		local target = if pressed then 0.95 elseif hovering then 1.03 else 1
		TweenService:Create(scale, TweenInfo.new(0.07), { Scale = target }):Play()
	end
	button.MouseButton1Down:Connect(function()
		if button:GetAttribute("Enabled") then
			pressed = true
			settle()
		end
	end)
	button.MouseButton1Up:Connect(function()
		pressed = false
		settle()
	end)

	button.MouseEnter:Connect(function()
		if button:GetAttribute("Enabled") then
			hovering = true
			settle()
			TweenService:Create(button, TweenInfo.new(HOVER_TIME), { BackgroundColor3 = glossBase(style.hover) }):Play()
		end
	end)
	button.MouseLeave:Connect(function()
		hovering = false
		pressed = false
		settle()
		if button:GetAttribute("Enabled") then
			TweenService:Create(button, TweenInfo.new(HOVER_TIME), { BackgroundColor3 = glossBase(style.bg) }):Play()
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
	button.BackgroundColor3 = glossBase(if enabled then style.bg else BUTTON_DISABLED_BG)
	button.TextColor3 = if enabled then C.text else (opts.disabledText or BUTTON_DISABLED_TEXT)
	local stroke = button:FindFirstChild("InkBorder")
	if stroke and stroke:IsA("UIStroke") then
		stroke.Transparency = if enabled then 0.05 else 0.4
	end
	button:SetAttribute("Enabled", enabled)
end

-- The glossy cherry-red X that closes a window: light top half, chunky ink
-- ring, white X with its own ink outline. Wiggles on hover.
function Kit.closeButton(parent: Instance): TextButton
	local button = Instance.new("TextButton")
	button.Name = "Close"
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.AnchorPoint = Vector2.new(1, 0.5)
	button.Position = UDim2.new(1, -14, 0.5, 0)
	button.Size = UDim2.fromOffset(36, 36)
	button.BackgroundColor3 = C.red
	button.Font = F.header
	button.TextSize = 18
	button.TextColor3 = C.text
	-- Plain ASCII on purpose: the fonts have no glyph for a real cross.
	button.Text = "X"
	button.Parent = parent
	Kit.corner(button, 12)
	splitGradient(button, Color3.new(1, 1, 1), Color3.fromRGB(198, 198, 198), 0.46)
	Kit.stroke(button, C.ink, 2.5, 0.05)
	inkText(button, 2)

	button.MouseEnter:Connect(function()
		TweenService:Create(button, TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Rotation = 10,
			BackgroundColor3 = Color3.fromRGB(250, 120, 106),
		}):Play()
	end)
	button.MouseLeave:Connect(function()
		TweenService:Create(button, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Rotation = 0,
			BackgroundColor3 = C.red,
		}):Play()
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
	-- A light lagoon tint, not a black dim: the blurred world behind should
	-- stay bright and sunny.
	backdrop.BackgroundColor3 = Color3.fromRGB(20, 70, 110)
	backdrop.BackgroundTransparency = 0.62
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
	-- Warm paper content sheet with a thick ink outline - the whole window
	-- reads as one die-cut sticker over the blurred world.
	window.BackgroundColor3 = C.paper
	window.BorderSizePixel = 0
	window.ZIndex = 3
	window.ClipsDescendants = true
	window.Parent = backdrop
	Kit.corner(window, R.window)
	Kit.gradient(window, Color3.new(1, 1, 1), Color3.fromRGB(238, 238, 238), 90)
	Kit.stroke(window, C.ink, 3, 0.05)

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

	-- Header: a glossy sky-blue bar - light top half, saturated bottom -
	-- with faint white fish stamped across it and a thick ink line under it.
	local HEADER = 62
	local TRIM = 4
	local header = Kit.frame(window, {
		Name = "Header",
		Size = UDim2.new(1, 0, 0, HEADER),
		BackgroundTransparency = 0,
		BackgroundColor3 = C.panel,
	})
	splitGradient(header, Color3.fromRGB(255, 255, 255), Color3.fromRGB(196, 214, 228), 0.46)
	-- UICorner on the window does NOT clip children, so the header must
	-- round its own top corners to the window radius - then square its
	-- bottom edge back off with a patch. The patch colour is the split
	-- gradient's flat bottom half (panel x 196/214/228), so no seam shows.
	Kit.corner(header, R.window)
	Kit.frame(header, {
		Name = "SquareBottom",
		Position = UDim2.new(0, 0, 1, -R.window),
		Size = UDim2.new(1, 0, 0, R.window),
		BackgroundTransparency = 0,
		BackgroundColor3 = Color3.fromRGB(65, 149, 207),
	})
	-- Watermark school swimming along the bar, behind the title.
	for i, x in { 0.3, 0.42, 0.56, 0.68, 0.8 } do
		stampFish(header, {
			position = UDim2.new(x, 0, if i % 2 == 0 then 0.36 else 0.64, 0),
			size = if i % 2 == 0 then 22 else 28,
			rotation = if i % 2 == 0 then -8 else 6,
			flip = i % 2 == 0,
			color = Color3.new(1, 1, 1),
			transparency = 0.72,
		})
	end
	Kit.frame(window, {
		Name = "HeaderLine",
		Position = UDim2.new(0, 0, 0, HEADER),
		Size = UDim2.new(1, 0, 0, TRIM),
		BackgroundTransparency = 0.05,
		BackgroundColor3 = C.ink,
	})

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
		TextColor3 = C.text,
		Text = opts.title or "",
		Position = UDim2.new(0, textX, 0, if opts.subtitle ~= nil then 9 else 0),
		Size = UDim2.new(1, -(textX + 70), 0, if opts.subtitle ~= nil then 30 else HEADER),
	})
	inkText(title, 2.5)
	local subtitle = Kit.label(header, {
		Name = "Subtitle",
		Font = F.bodyBold,
		TextSize = S.subtitle,
		TextColor3 = C.text,
		TextTransparency = 0.1,
		Text = opts.subtitle or "",
		Position = UDim2.new(0, textX, 0, 37),
		Size = UDim2.new(1, -(textX + 70), 0, 18),
		Visible = opts.subtitle ~= nil,
	})
	inkText(subtitle, 1.5)

	local close = Kit.closeButton(header)

	gui.Destroying:Connect(function()
		if backdrop.Visible then
			setMenuBlur(false)
		end
	end)

	-- Watermark art on the paper: a scattered school of ink-faint fish, like
	-- the pattern printed on a sticker sheet. Static and cheap; created
	-- BEFORE `body` so it renders behind everything the caller adds.
	local ambience = Kit.frame(window, {
		Name = "Ambience",
		Position = UDim2.new(0, 0, 0, HEADER + TRIM),
		Size = UDim2.new(1, 0, 1, -(HEADER + TRIM)),
		ClipsDescendants = true,
	})
	local pattern = {
		{ x = 0.12, y = 0.16, s = 30, r = -8 },
		{ x = 0.38, y = 0.1, s = 24, r = 6, flip = true },
		{ x = 0.66, y = 0.18, s = 34, r = -5 },
		{ x = 0.9, y = 0.12, s = 24, r = 9, flip = true },
		{ x = 0.22, y = 0.42, s = 26, r = 7, flip = true },
		{ x = 0.52, y = 0.38, s = 30, r = -6 },
		{ x = 0.82, y = 0.45, s = 26, r = 5 },
		{ x = 0.12, y = 0.7, s = 32, r = 6 },
		{ x = 0.4, y = 0.66, s = 24, r = -7, flip = true },
		{ x = 0.68, y = 0.74, s = 30, r = 8 },
		{ x = 0.9, y = 0.8, s = 24, r = -6, flip = true },
		{ x = 0.28, y = 0.9, s = 26, r = -5 },
		{ x = 0.58, y = 0.92, s = 28, r = 7, flip = true },
	}
	for _, spot in pattern do
		stampFish(ambience, {
			position = UDim2.new(spot.x, 0, spot.y, 0),
			size = spot.s,
			rotation = spot.r,
			flip = spot.flip,
			color = C.ink,
			transparency = 0.93,
		})
	end

	local body = Kit.frame(window, {
		Name = "Body",
		Position = UDim2.new(0, 0, 0, HEADER + TRIM),
		Size = UDim2.new(1, 0, 1, -(HEADER + TRIM)),
	})

	-- Entrance: the world blurs, the backdrop fades in and the window scales
	-- up with a small overshoot. Driven off backdrop.Visible, so every
	-- controller's existing open/close toggling gets it for free.
	local windowScale = Instance.new("UIScale")
	windowScale.Parent = window
	backdrop:GetPropertyChangedSignal("Visible"):Connect(function()
		setMenuBlur(backdrop.Visible)
		if backdrop.Visible then
			backdrop.BackgroundTransparency = 1
			TweenService:Create(backdrop, TweenInfo.new(0.16), { BackgroundTransparency = 0.62 }):Play()
			windowScale.Scale = 0.92
			TweenService:Create(windowScale, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
				Scale = 1,
			}):Play()
		end
	end)

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

-- A row of glossy sticker tabs, each with a small token tile and an ink
-- outline. Inactive tabs are candy blue with white text; the picked one
-- flips to white with blue text and swells slightly. `onSelect(kind)` fires
-- on click; the handle's `set(kind)` restyles without firing.
function Kit.tabs(parent: Instance, tabs, onSelect)
	local row = Kit.frame(parent, { Name = "Tabs", Size = UDim2.new(1, 0, 0, 38) })
	local holder = Kit.frame(row, {
		Name = "Tags",
		Position = UDim2.new(0, 6, 0, 2),
		Size = UDim2.new(1, -6, 1, -4),
	})
	Kit.listLayout(holder, 10, true)

	local buttons = {}
	local scales = {}
	local handle = {}

	function handle.set(kind: string)
		for tabKind, button in buttons do
			local active = tabKind == kind
			button:SetAttribute("Active", active)
			button.BackgroundColor3 = if active then Color3.new(1, 1, 1) else glossBase(C.accent)
			scales[tabKind].Scale = if active then 1.05 else 1
			local text = button:FindFirstChild("Text")
			if text then
				text.TextColor3 = if active then C.accentDark else C.text
				local glyphInk = text:FindFirstChildOfClass("UIStroke")
				if glyphInk then
					glyphInk.Transparency = if active then 1 else 0
				end
			end
			local tile = button:FindFirstChild("Tile")
			if tile then
				tile.BackgroundColor3 = if active then C.accent else C.accentDark
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
		button.Size = UDim2.fromOffset(tab.width or 118, 34)
		button.BackgroundColor3 = glossBase(C.accent)
		button.Parent = holder
		Kit.corner(button, 12)
		Kit.stroke(button, C.ink, 2.5, 0.05)
		splitGradient(button, Color3.new(1, 1, 1), Color3.fromRGB(206, 206, 206), 0.46)
		local scale = Instance.new("UIScale")
		scale.Parent = button
		scales[tab.kind] = scale

		Kit.tile(button, {
			name = "Tile",
			size = 24,
			color = C.accentDark,
			token = tab.token or Kit.monogram(tab.label),
			tokenSize = 10,
			position = UDim2.new(0, 6, 0.5, 0),
			anchor = Vector2.new(0, 0.5),
			radius = 12,
		})
		local text = Kit.label(button, {
			Name = "Text",
			Font = F.header,
			TextSize = 15,
			TextColor3 = C.text,
			Text = tab.label,
			Position = UDim2.new(0, 37, 0, 0),
			Size = UDim2.new(1, -41, 1, 0),
		})
		inkText(text, 2)

		button.MouseEnter:Connect(function()
			if not button:GetAttribute("Active") then
				TweenService:Create(button, TweenInfo.new(HOVER_TIME), {
					BackgroundColor3 = glossBase(Color3.fromRGB(110, 198, 250)),
				}):Play()
				TweenService:Create(scale, TweenInfo.new(HOVER_TIME), { Scale = 1.03 }):Play()
			end
		end)
		button.MouseLeave:Connect(function()
			if not button:GetAttribute("Active") then
				TweenService:Create(button, TweenInfo.new(HOVER_TIME), { BackgroundColor3 = glossBase(C.accent) })
					:Play()
				TweenService:Create(scale, TweenInfo.new(HOVER_TIME), { Scale = 1 }):Play()
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
	card.BackgroundColor3 = C.paperDark
	card.BackgroundTransparency = dim * 0.4
	card.Parent = parent
	Kit.corner(card, R.card)
	local stroke = Kit.stroke(card, C.ink, 1.5, 0.55)
	Kit.gradient(card, Color3.new(1, 1, 1), Color3.fromRGB(228, 228, 228), 90)

	local tileColor = if opts.locked then Color3.fromRGB(206, 190, 172) else (opts.color or Rarity.colorOf(opts.rarity))
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
		TextColor3 = if opts.locked then C.textDim else C.ink,
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

	-- Count pill, top-right: white sticker with an ink ring.
	local count = Kit.label(card, {
		Name = "Count",
		Font = F.header,
		TextSize = 11,
		TextColor3 = C.accentDark,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -6, 0, 6),
		Size = UDim2.fromOffset(30, 17),
		BackgroundTransparency = 0,
		BackgroundColor3 = Color3.new(1, 1, 1),
		Visible = false,
	})
	Kit.corner(count, 9)
	Kit.stroke(count, C.ink, 1.5, 0.25)

	-- "In hand": a little red/white bobber floating on the card - the same
	-- mark as the close button and the lit pips, so "bobber = yours" reads.
	local ring = Kit.bobber(card, 15, nil, {
		Name = "Equipped",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -7, 0, size - 22),
		Visible = opts.equipped == true,
	})

	local handle = { frame = card, tile = tile }

	-- Hover lift, shared with the selection logic below.
	local lift = Instance.new("UIScale")
	lift.Parent = card

	-- The selected card's stroke "breathes" - a slow glow pulse, cancelled on
	-- deselect so idle grids stay static.
	local breathe: Tween? = nil

	function handle.setSelected(on: boolean)
		if breathe then
			breathe:Cancel()
			breathe = nil
		end
		stroke.Color = if on then C.accent else C.ink
		stroke.Thickness = if on then 3 else 1.5
		stroke.Transparency = if on then 0 else 0.55
		card.BackgroundColor3 = if on then Color3.new(1, 1, 1) else C.paperDark
		if on then
			breathe = TweenService:Create(
				stroke,
				TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
				{ Transparency = 0.45 }
			)
			breathe:Play()
		end
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
		TweenService:Create(lift, TweenInfo.new(HOVER_TIME), { Scale = 1.04 }):Play()
		if stroke.Thickness < 2 then
			card.BackgroundColor3 = C.paper
		end
	end)
	card.MouseLeave:Connect(function()
		TweenService:Create(lift, TweenInfo.new(HOVER_TIME), { Scale = 1 }):Play()
		if stroke.Thickness < 2 then
			card.BackgroundColor3 = C.paperDark
		end
	end)
	if opts.onSelect then
		card.Activated:Connect(opts.onSelect)
	end
	return handle
end

-- ============================================================ stats + effects

-- A stat as five little floats: lit = a bobber riding the water (top half
-- in the stat's colour, red by default), unlit = a hollow glass bead sunk
-- dark. `value` is 0..1.
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
	local pipSize = 13
	local gap = 5
	local holder = Kit.frame(row, {
		Name = "Dots",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(count * pipSize + (count - 1) * gap, pipSize),
	})
	for i = 1, count do
		if i <= lit then
			Kit.bobber(holder, pipSize, opts.color, {
				Name = "Pip" .. i,
				Position = UDim2.new(0, (i - 1) * (pipSize + gap), 0, 0),
			})
		else
			local bead = Kit.frame(holder, {
				Name = "Pip" .. i,
				Position = UDim2.new(0, (i - 1) * (pipSize + gap), 0, 0),
				Size = UDim2.fromOffset(pipSize, pipSize),
				BackgroundTransparency = 0,
				BackgroundColor3 = Color3.new(1, 1, 1),
			})
			Kit.corner(bead, math.ceil(pipSize / 2))
			Kit.stroke(bead, C.ink, 1.5, 0.55)
		end
	end
	return row
end

-- An effect chip: a small coloured token tile + one plain line, on a white
-- sticker strip.
function Kit.chip(parent: Instance, opts): Frame
	local chip = Kit.frame(parent, {
		Name = "Chip_" .. tostring(opts.token),
		Size = UDim2.new(1, 0, 0, 34),
		LayoutOrder = opts.order or 0,
		BackgroundTransparency = 0.25,
		BackgroundColor3 = Color3.new(1, 1, 1),
	})
	Kit.corner(chip, 10)
	Kit.stroke(chip, C.ink, 1.5, 0.6)
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
		TextColor3 = opts.textColor or C.ink,
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
		BackgroundColor3 = Color3.new(1, 1, 1),
	})
	Kit.corner(card, 12)
	Kit.stroke(card, opts.color or C.accent, 2, 0.1)
	Kit.gradient(card, Color3.new(1, 1, 1), Color3.fromRGB(232, 232, 232), 90)
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
		TextColor3 = opts.color or C.accentDark,
		Text = opts.name or "",
		Position = UDim2.new(0, 54, 0, 0),
		Size = UDim2.new(1, -54, 0, 20),
	})
	Kit.label(card, {
		Name = "Text",
		Font = F.body,
		TextSize = 13,
		TextColor3 = C.ink,
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
		TextColor3 = if ok then C.ink else C.textDim,
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
		BackgroundTransparency = 0.75,
		BackgroundColor3 = C.ink,
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
		-- `text` overrides the numeric readout for yes/no requirements (a boss
		-- heart is "OWNED" or "UNDEFEATED", never "1 / 1").
		Text = opts.text or string.format("%s / %s", tostring(opts.have or 0), tostring(opts.need or 0)),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.new(0.45, 0, 1, 0),
	})
	return row
end

-- A soft panel (detail column, list box): a lighter paper sheet with an
-- ink outline, sitting on the window's paper.
function Kit.panel(parent: Instance, props: { [string]: any }?): Frame
	local panel = Kit.frame(parent, { BackgroundTransparency = 0, BackgroundColor3 = C.paper })
	Kit.corner(panel, R.panel)
	Kit.stroke(panel, C.ink, 2, 0.35)
	Kit.gradient(panel, Color3.new(1, 1, 1), Color3.fromRGB(238, 238, 238), 90)
	if props then
		for key, value in props do
			panel[key] = value
		end
	end
	return panel
end

return Kit
