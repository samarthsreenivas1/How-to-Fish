--!nonstrict
-- ItemDetail.luau
-- The right-hand detail column the inventory and crafting menus share: what
-- one selected thing IS. A hero row (big tile, name in its rarity's colour,
-- the rarity gem line, an "in hand" / "selected" pill, a count), the
-- flavour line, then - only for the kinds that have them - an ABILITY card
-- with its fact chips, STATS as pips, EFFECTS as chips, and whatever extra
-- section the caller adds (the crafting menu's recipe). All of that scrolls;
-- the action buttons sit pinned below it so Equip / Craft is never off
-- screen.
--
-- Everything shown comes through Describe, which is what keeps "what does
-- this power-up do" honest and consistent between the two menus.

local Theme = require(script.Parent.Theme)
local Kit = require(script.Parent.Kit)
local Describe = require(script.Parent.Describe)

local ItemDetail = {}
ItemDetail.__index = ItemDetail

local C = Theme.Color
local F = Theme.Font

local ACTION_HEIGHT = 48
local ACTION_GAP = 10
local STATUS_HEIGHT = 18

-- ============================================================ build

function ItemDetail.new(parent: Instance)
	local self = setmetatable({}, ItemDetail)

	local panel = Kit.panel(parent, {
		Name = "Detail",
		Size = UDim2.fromScale(1, 1),
	})
	self.panel = panel

	local footerHeight = ACTION_HEIGHT + STATUS_HEIGHT + 14
	self.scroll = Kit.scroll(panel, {
		name = "Content",
		position = UDim2.new(0, 12, 0, 12),
		size = UDim2.new(1, -24, 1, -(footerHeight + 18)),
		gap = 10,
		padding = 2,
	})

	self.placeholder = Kit.label(panel, {
		Name = "Placeholder",
		Font = F.body,
		TextSize = 14,
		TextColor3 = C.textDim,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "Pick something to see it here.",
		Position = UDim2.new(0, 16, 0, 0),
		Size = UDim2.new(1, -32, 1, 0),
	})

	self.footer = Kit.frame(panel, {
		Name = "Footer",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 12, 1, -12),
		Size = UDim2.new(1, -24, 0, footerHeight),
	})
	self.status = Kit.label(self.footer, {
		Name = "Status",
		Font = F.bodyBold,
		TextSize = 12,
		TextColor3 = C.textDim,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "",
		Size = UDim2.new(1, 0, 0, STATUS_HEIGHT),
	})
	self.actions = Kit.frame(self.footer, {
		Name = "Actions",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		Size = UDim2.new(1, 0, 0, ACTION_HEIGHT),
	})
	Kit.listLayout(self.actions, ACTION_GAP, true)

	return self
end

-- ============================================================ pieces

local function clearChildren(inst: Instance, keepLayouts: boolean)
	for _, child in inst:GetChildren() do
		if not (keepLayouts and (child:IsA("UIListLayout") or child:IsA("UIPadding"))) then
			child:Destroy()
		end
	end
end

local function hero(parent: Instance, opts, order: number)
	local row = Kit.frame(parent, { Name = "Hero", Size = UDim2.new(1, 0, 0, 78), LayoutOrder = order })
	Kit.tile(row, {
		name = "Tile",
		size = 72,
		color = opts.tileColor,
		image = opts.image,
		token = opts.token,
		tokenSize = 22,
		radius = 16,
	})
	Kit.label(row, {
		Name = "Name",
		Font = F.header,
		TextSize = Theme.Size.name,
		-- Ink fallback: the detail panel sits on paper now, so an uncoloured
		-- name must be dark, not white.
		TextColor3 = opts.nameColor or C.ink,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = opts.name or "",
		Position = UDim2.new(0, 84, 0, 4),
		Size = UDim2.new(1, -84, 0, 26),
	})
	if opts.rarity then
		local line = Kit.rarityLine(row, opts.rarity)
		line.Position = UDim2.new(0, 84, 0, 32)
		line.Size = UDim2.new(1, -84, 0, 16)
	end
	-- Pills along the bottom of the hero: state + count.
	local pills =
		Kit.frame(row, { Name = "Pills", Position = UDim2.new(0, 84, 0, 52), Size = UDim2.new(1, -84, 0, 22) })
	Kit.listLayout(pills, 6, true)
	local function pill(text: string, color: Color3, textColor: Color3?, order2: number)
		local p = Kit.label(pills, {
			Font = F.header,
			TextSize = 11,
			TextColor3 = textColor or C.textOnAccent,
			TextXAlignment = Enum.TextXAlignment.Center,
			Text = text,
			Size = UDim2.fromOffset(12 + #text * 7, 20),
			BackgroundTransparency = 0,
			BackgroundColor3 = color,
			LayoutOrder = order2,
		})
		Kit.corner(p, 10)
	end
	if opts.state then
		pill(opts.state, opts.stateColor or C.accent, nil, 1)
	end
	if opts.count ~= nil then
		pill("x" .. tostring(opts.count), C.background, C.text, 2)
	end
	return row
end

-- ============================================================ show

-- `spec`:
--   name, rarity, description, image, token, tileColor
--   state / stateColor   - "IN HAND", "SELECTED" pill
--   count                - owned count (materials, bait)
--   perk                 - a rod / weapon perk row -> ABILITY card + facts
--   pips                 - { {label, value, color} } -> STATS
--   effects              - { {token, text, color} } -> EFFECTS
--   extra(scroll, order) - caller-built sections (a recipe); returns next order
--   actions              - { { text, style, enabled, onClick, width? } } (1-2)
function ItemDetail:show(spec)
	self.placeholder.Visible = false
	self.scroll.Visible = true
	clearChildren(self.scroll, true)
	clearChildren(self.actions, true)

	local order = 0
	local function next(): number
		order += 1
		return order
	end

	hero(self.scroll, spec, next())

	if spec.description and spec.description ~= "" then
		Kit.paragraph(self.scroll, spec.description, { LayoutOrder = next(), TextSize = 13 })
	end

	if spec.perk then
		local ability = Describe.perk(spec.perk)
		Kit.section(self.scroll, "Ability", next())
		Kit.abilityCard(self.scroll, {
			order = next(),
			token = ability.token,
			color = ability.color,
			name = ability.name,
			text = ability.text,
		})
		for _, fact in Describe.perkFacts(spec.perk) do
			Kit.chip(self.scroll, { order = next(), token = fact.token, color = fact.color, text = fact.text })
		end
	end

	if spec.pips and #spec.pips > 0 then
		Kit.section(self.scroll, "Stats", next())
		for _, pip in spec.pips do
			Kit.pips(self.scroll, { order = next(), label = pip.label, value = pip.value, color = pip.color })
		end
	end

	if spec.effects and #spec.effects > 0 then
		Kit.section(self.scroll, "Effects", next())
		for _, chip in spec.effects do
			Kit.chip(self.scroll, { order = next(), token = chip.token, color = chip.color, text = chip.text })
		end
	end

	if spec.extra then
		order = spec.extra(self.scroll, order) or order
	end

	for i, action in spec.actions or {} do
		local count = #spec.actions
		local button = Kit.button(self.actions, {
			order = i,
			text = action.text,
			style = action.style,
			enabled = action.enabled,
			size = UDim2.new(1 / count, -(ACTION_GAP * (count - 1)) / count, 1, 0),
		})
		if action.disabledText then
			button.TextColor3 = action.disabledText
		end
		if action.onClick then
			button.Activated:Connect(function()
				if button:GetAttribute("Enabled") then
					action.onClick()
				end
			end)
		end
	end
end

function ItemDetail:clear(text: string?)
	clearChildren(self.scroll, true)
	clearChildren(self.actions, true)
	self.scroll.Visible = false
	self.placeholder.Visible = true
	self.placeholder.Text = text or "Pick something to see it here."
	self.status.Text = ""
end

function ItemDetail:setStatus(text: string?, color: Color3?)
	self.status.Text = text or ""
	self.status.TextColor3 = color or C.textDim
end

return ItemDetail
