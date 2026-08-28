--!nonstrict
-- CraftingController.luau
-- The crafting menu: C opens a centred window with three tabs - Rods,
-- Weapons, Bait - a scrolling grid of EVERY item on the open tab (locked
-- ones veiled with a "?" tile and their level), and the shared detail
-- column on the right. The detail shows the thing itself (ability card,
-- stat pips, effect chips) and then, depending on what you have:
--   - owned + in hand  -> "In Hand"
--   - owned            -> Equip (RequestEquipRod / RequestEquipWeapon)
--   - not owned        -> the RECIPE (level / coins / each material as a
--                         have-need bar, red when short) and Craft, gated
--                         live on what you have
--   - bait             -> always the recipe + Craft (it stacks), plus
--                         Select / Selected (RequestSelectBait)
--
-- Rebuilt on the shared UI kit in the 2026-08-23 overhaul; the state,
-- remotes and hotkey are unchanged. Items come from the static Rods /
-- Weapons / Bait tables, owned ids via GetInventory / InventoryUpdated,
-- materials via GetMaterials / MaterialsUpdated, bait counts via GetBait /
-- BaitUpdated, and level / coins / equipped choices from the replicated
-- Player attributes - so the panel stays live while open.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Equipment = require(Shared.Config.Equipment)
local Bait = require(Shared.Data.Bait)
local Boats = require(Shared.Data.Boats)
local Bosses = require(Shared.Data.Bosses)
local Materials = require(Shared.Data.Materials)
local Rods = require(Shared.Data.Rods)
local Weapons = require(Shared.Data.Weapons)
local Trinkets = require(Shared.Data.Trinkets)
local Armor = require(Shared.Data.Armor)
local Progression = require(Shared.Modules.Progression)
local Rarity = require(Shared.Modules.Rarity)
local Remotes = require(Shared.Net.Remotes)

local Theme = require(script.Parent.Parent.UI.Theme)
local Kit = require(script.Parent.Parent.UI.Kit)
local Describe = require(script.Parent.Parent.UI.Describe)
local ItemDetail = require(script.Parent.Parent.UI.ItemDetail)
local CameraController = require(script.Parent.CameraController)

local player = Players.LocalPlayer

local CraftingController = {}

local C = Theme.Color

local CARD_SIZE = 96
local CARD_GAP = 10
local DETAIL_WIDTH = 330
local PAD = 16

-- The tabs. Everything kind-specific lives on the tab entry.
local TABS = {
	{
		kind = "rod",
		label = "Rods",
		token = "ROD",
		noun = "rod",
		items = Rods.items,
		attribute = Equipment.ROD_ATTRIBUTE,
		equipRemote = Remotes.RequestEquipRod,
		equipKind = Equipment.ROD,
	},
	{
		kind = "weapon",
		label = "Weapons",
		token = "WPN",
		noun = "weapon",
		width = 128,
		items = Weapons.items,
		attribute = Equipment.WEAPON_ATTRIBUTE,
		equipRemote = Remotes.RequestEquipWeapon,
		equipKind = Equipment.WEAPON,
	},
	{
		kind = "armor",
		label = "Armor",
		token = "ARM",
		noun = "piece",
		items = Armor.items,
		-- Worn state spans three attributes; armorWorn() handles it and the
		-- refresh hookup listens to all three. `attribute` stays one of them
		-- for the generic machinery that only needs "some" attribute.
		attribute = Equipment.HELMET_ATTRIBUTE,
		equipRemote = Remotes.RequestEquipArmor,
	},
	{
		kind = "trinket",
		label = "Charms",
		token = "CHARM",
		noun = "charm",
		items = Trinkets.items,
		attribute = Equipment.TRINKET_ATTRIBUTE,
		equipRemote = Remotes.RequestEquipTrinket,
		-- No equipKind: a charm is worn, not held - equipping never changes
		-- the hand, so no RequestEquip(kind) follows (the server ignores the
		-- nil kind the shared button fires).
	},
	{
		kind = "bait",
		label = "Bait",
		token = "BAIT",
		noun = "bait",
		items = Bait.items,
		attribute = Equipment.BAIT_ATTRIBUTE,
	},
	-- The boat ladder (Session 3). "Owning" is the BoatTier attribute, not an
	-- inventory id: each hull is built onto the previous one, so exactly one
	-- row is ever craftable - the next tier up.
	{
		kind = "boat",
		label = "Boat",
		token = "BOAT",
		noun = "hull",
		items = Boats.items,
		attribute = "BoatTier",
	},
}

local modal
local tabs
local grid: ScrollingFrame
local detail
local cards: { [string]: any } = {} -- open tab only

local activeTab = TABS[1]
local ownedSet: { [string]: boolean } = {}
local materialCounts: { [string]: number } = {}
local baitCounts: { [string]: number } = {}
local selectedId: string? = nil
local statusText: string? = nil
local statusOk = false

-- Items in display order for a tab: starter (no recipe) first, then by level
-- gate, then by id so ties are stable.
local function orderFor(tab): { string }
	local ids = {}
	for id in tab.items do
		table.insert(ids, id)
	end
	table.sort(ids, function(a, b)
		local ra = tab.items[a].recipe
		local rb = tab.items[b].recipe
		local la = if ra then ra.requiresLevel else 0
		local lb = if rb then rb.requiresLevel else 0
		if la ~= lb then
			return la < lb
		end
		return a < b
	end)
	return ids
end

-- ============================================================ live player state

local function level(): number
	return player:GetAttribute(Progression.ATTR.level) or Progression.START_LEVEL
end

local function coins(): number
	return player:GetAttribute(Progression.ATTR.coins) or 0
end

local function equippedId(): string?
	return player:GetAttribute(activeTab.attribute)
end

-- Armor has THREE worn attributes; a piece is worn when its own slot's
-- attribute names it. Every kind=="armor" branch uses this instead of
-- equippedId().
local function armorWorn(item): boolean
	local attribute = Armor.ATTRIBUTES[item.slot]
	return attribute ~= nil and player:GetAttribute(attribute) == item.id
end

-- ============================================================ recipe section

-- Builds the RECIPE section into the detail scroll. Returns the next
-- layout order and whether the player can afford it right now.
local function recipeSection(item, scroll: Instance, order: number): (number, boolean)
	local recipe = item.recipe
	order += 1
	Kit.section(
		scroll,
		if activeTab.kind == "bait" then string.format("Recipe  -  makes %d", recipe.yield or 1) else "Recipe",
		order
	)

	local playerLevel = level()
	local levelOk = playerLevel >= recipe.requiresLevel
	order += 1
	Kit.requirement(scroll, {
		order = order,
		label = "Level",
		token = "LV",
		color = C.accentDark,
		have = playerLevel,
		need = recipe.requiresLevel,
	})

	local coinsOk = coins() >= recipe.coins
	order += 1
	Kit.requirement(scroll, {
		order = order,
		label = "Coins",
		token = "$",
		color = C.gold,
		have = coins(),
		need = recipe.coins,
	})

	-- Heart-gated recipes (the island Legendaries): the requirement is beating
	-- the boss, shown as owned-or-not rather than a count - the heart is the
	-- permanent Heart_<bossId> attribute, never a spendable material.
	local heartsOk = true
	if recipe.requiresHearts then
		for _, bossId in recipe.requiresHearts do
			local boss = Bosses.items[bossId]
			local hasHeart = player:GetAttribute("Heart_" .. bossId) == true
			if not hasHeart then
				heartsOk = false
			end
			order += 1
			Kit.requirement(scroll, {
				order = order,
				label = "Heart of " .. (if boss then boss.shortName else bossId),
				token = "HRT",
				color = Color3.fromRGB(255, 96, 104),
				have = if hasHeart then 1 else 0,
				need = 1,
				text = if hasHeart then "OWNED" else "UNDEFEATED",
			})
		end
	end

	local matsOk = true
	for _, matId in Materials.order do
		local need = recipe.materials[matId]
		if need then
			local mat = Materials.items[matId]
			local have = materialCounts[matId] or 0
			if have < need then
				matsOk = false
			end
			order += 1
			Kit.requirement(scroll, {
				order = order,
				label = mat.name,
				image = mat.icon,
				color = mat.color or Rarity.colorOf(mat.rarity),
				have = have,
				need = need,
			})
		end
	end

	return order, levelOk and coinsOk and matsOk and heartsOk
end

-- ============================================================ detail

local function showDetail(itemId: string?)
	local item = itemId and activeTab.items[itemId]
	if not item then
		detail:clear("Pick a " .. activeTab.noun .. " to see what it takes.")
		return
	end

	local owned = ownedSet[itemId]
	local equipped = if activeTab.kind == "armor" then armorWorn(item) else equippedId() == itemId
	local spec = {
		name = item.name,
		rarity = item.rarity,
		nameColor = Rarity.colorOf(item.rarity),
		description = item.description,
		image = item.icon,
		token = Kit.monogram(item.name),
		tileColor = item.color or Rarity.colorOf(item.rarity),
		perk = item.perk,
	}

	if activeTab.kind == "rod" then
		spec.pips = Describe.rodPips(item)
	elseif activeTab.kind == "weapon" then
		spec.pips = Describe.weaponPips(item)
	elseif activeTab.kind == "boat" then
		spec.description = string.format(
			"%s\n\nSpeed %d  ·  Hull %d  ·  Open sea %d studs",
			item.blurb,
			item.speed,
			item.hullHealth,
			item.seaworthiness
		)
	elseif activeTab.kind == "armor" then
		local set = Armor.sets[item.set]
		local statLine = string.format(
			"Defense %d%s",
			item.defense,
			if item.health then string.format("  ·  +%d health", item.health) else ""
		)
		local bonusLine = if set then string.format("Set bonus - %s: %s", set.bonus.name, set.bonus.description) else ""
		spec.description = string.format("%s\n\n%s\n%s", set and set.blurb or "", statLine, bonusLine)
	elseif activeTab.kind == "trinket" then
		spec.description = item.blurb
	else
		spec.effects = Describe.baitEffects(item.effect)
	end

	local canCraft = false
	if activeTab.kind == "boat" then
		local tier = player:GetAttribute("BoatTier") or 0
		if tier >= item.tier then
			spec.state = if tier == item.tier then "YOUR BOAT" else "OUTGROWN"
			spec.stateColor = if tier == item.tier then C.green else C.panelLight
			if tier == item.tier then
				spec.actions = {
					{
						text = "Summon (R)",
						style = "primary",
						enabled = true,
						onClick = function()
							Remotes.RequestBoat:FireServer("summon")
							CraftingController.setOpen(false)
						end,
					},
				}
			end
		elseif item.recipe then
			local isNext = item.tier == tier + 1
			spec.state = if not isNext
				then "NEEDS PREVIOUS HULL"
				elseif level() >= item.recipe.requiresLevel then "CRAFTABLE"
				else ("LEVEL " .. item.recipe.requiresLevel)
			spec.stateColor = if isNext and level() >= item.recipe.requiresLevel then C.green else C.red
			spec.extra = function(scroll, order)
				local nextOrder, ok = recipeSection(item, scroll, order)
				canCraft = ok and isNext
				return nextOrder
			end
			spec.actions = {
				{
					text = "Craft",
					style = "success",
					enabled = true, -- re-gated below once the recipe has run
					onClick = function()
						if canCraft then
							Remotes.RequestCraft:FireServer(item.id)
						end
					end,
				},
			}
		else
			-- Tier 1: Brinejaw's bounty, never crafted.
			spec.state = "DEFEAT BRINEJAW"
			spec.stateColor = C.red
		end
	elseif activeTab.kind == "bait" then
		local count = baitCounts[itemId] or 0
		spec.count = count
		spec.state = if equipped then "SELECTED" else nil
		spec.stateColor = C.green
		spec.extra = function(scroll, order)
			local next, ok = recipeSection(item, scroll, order)
			canCraft = ok
			return next
		end
		spec.actions = {
			{
				text = "Craft",
				style = "success",
				enabled = true, -- re-gated below once the recipe has run
				onClick = function()
					if canCraft then
						Remotes.RequestCraft:FireServer(item.id)
					end
				end,
			},
			{
				text = if equipped then "Selected" else "Select",
				style = if equipped then "secondary" else "primary",
				enabled = not equipped and count > 0,
				disabledText = if equipped then C.green else nil,
				onClick = function()
					Remotes.RequestSelectBait:FireServer(item.id)
				end,
			},
		}
	elseif owned then
		local wornWord = if activeTab.kind == "trinket" or activeTab.kind == "armor" then "WORN" else "IN HAND"
		spec.state = if equipped then wornWord else "OWNED"
		spec.stateColor = if equipped then C.accent else C.panelLight
		spec.actions = {
			{
				text = if equipped
					then (if activeTab.kind == "trinket" or activeTab.kind == "armor" then "Worn" else "In Hand")
					else "Equip",
				style = if equipped then "secondary" else "primary",
				enabled = not equipped,
				disabledText = C.green,
				onClick = function()
					activeTab.equipRemote:FireServer(itemId)
					Remotes.RequestEquip:FireServer(activeTab.equipKind)
				end,
			},
		}
	elseif item.recipe then
		spec.state = if level() >= item.recipe.requiresLevel
			then "CRAFTABLE"
			else ("LEVEL " .. item.recipe.requiresLevel)
		spec.stateColor = if level() >= item.recipe.requiresLevel then C.green else C.red
		spec.extra = function(scroll, order)
			local next, ok = recipeSection(item, scroll, order)
			canCraft = ok
			return next
		end
		spec.actions = {
			{
				text = "Craft",
				style = "success",
				enabled = true,
				onClick = function()
					if canCraft then
						Remotes.RequestCraft:FireServer(item.id)
					end
				end,
			},
		}
	else
		spec.state = "NOT CRAFTABLE"
		spec.stateColor = C.panelLight
	end

	detail:show(spec)

	-- The Craft button's enabled state depends on the recipe section that
	-- ran inside show(); re-style it now that canCraft is known.
	local craft = detail.actions:FindFirstChild("Button_Craft")
	if craft then
		Kit.setButton(craft, { style = "success", enabled = canCraft })
	end

	if statusText then
		detail:setStatus(statusText, if statusOk then C.green else C.red)
	else
		detail:setStatus("")
	end
end

-- ============================================================ grid

local function setSelected(itemId: string?)
	statusText = nil
	if selectedId and cards[selectedId] then
		cards[selectedId].setSelected(false)
	end
	selectedId = itemId
	if selectedId and cards[selectedId] then
		cards[selectedId].setSelected(true)
	end
	showDetail(selectedId)
end

-- The card's state tag + veil, from live data.
local function refreshCard(itemId: string)
	local handle = cards[itemId]
	local item = activeTab.items[itemId]
	if not handle or not item then
		return
	end
	if activeTab.kind == "boat" then
		local tier = player:GetAttribute("BoatTier") or 0
		handle.setEquipped(tier == item.tier)
		if tier >= item.tier then
			handle.setTag(
				if tier == item.tier then "YOURS" else "OUTGROWN",
				if tier == item.tier then C.green else C.textDim
			)
		elseif not item.recipe then
			handle.setTag("BOSS", C.red)
		elseif item.tier == tier + 1 then
			local ok = level() >= item.recipe.requiresLevel
			handle.setTag("LV " .. item.recipe.requiresLevel, if ok then C.accent else C.red)
		else
			handle.setTag("LOCKED", C.textDim)
		end
	elseif activeTab.kind == "bait" then
		local count = baitCounts[itemId] or 0
		handle.setCount(count)
		handle.setEquipped(equippedId() == itemId)
		if equippedId() == itemId then
			handle.setTag("SELECTED", C.green)
		elseif level() >= item.recipe.requiresLevel then
			handle.setTag("CRAFT", C.accent)
		else
			handle.setTag("LV " .. item.recipe.requiresLevel, C.red)
		end
	else
		local owned = ownedSet[itemId]
		local equipped = if activeTab.kind == "armor" then armorWorn(item) else equippedId() == itemId
		handle.setEquipped(equipped)
		if equipped then
			handle.setTag(
				if activeTab.kind == "trinket" or activeTab.kind == "armor" then "WORN" else "IN HAND",
				C.green
			)
		elseif owned then
			handle.setTag("OWNED", C.textDim)
		elseif item.recipe then
			local ok = level() >= item.recipe.requiresLevel
			handle.setTag("LV " .. item.recipe.requiresLevel, if ok then C.accent else C.red)
		else
			handle.setTag("")
		end
	end
end

local function renderTab()
	for id, handle in cards do
		handle.frame:Destroy()
		cards[id] = nil
	end

	local ids = orderFor(activeTab)
	for i, itemId in ids do
		local item = activeTab.items[itemId]
		local locked
		if activeTab.kind == "bait" then
			locked = false
		elseif activeTab.kind == "boat" then
			-- The current hull and the next rung show; the rest stay veiled.
			locked = item.tier > (player:GetAttribute("BoatTier") or 0) + 1
		else
			locked = not ownedSet[itemId]
		end
		cards[itemId] = Kit.card(grid, {
			name = itemId,
			order = i,
			size = CARD_SIZE,
			label = item.name,
			rarity = item.rarity,
			color = item.color,
			image = item.icon,
			locked = locked,
			onSelect = function()
				setSelected(itemId)
			end,
		})
		refreshCard(itemId)
	end

	modal.subtitle.Text = string.format("%d %ss", #ids, activeTab.noun)

	if selectedId and cards[selectedId] then
		setSelected(selectedId)
	else
		setSelected(ids[1])
	end
end

local function setTab(kind: string)
	for _, tab in TABS do
		if tab.kind == kind then
			activeTab = tab
		end
	end
	selectedId = nil
	statusText = nil
	tabs.set(kind)
	renderTab()
end

-- Everything the open panel shows can change from outside (coins, mats, a
-- level, a craft / equip confirmation): re-tag the cards and redraw the
-- detail. Ownership changes flip a card's veil, so that re-renders the tab.
local function refresh()
	for itemId in cards do
		refreshCard(itemId)
	end
	showDetail(selectedId)
end

-- ============================================================ open / close

function CraftingController.setOpen(open: boolean)
	if not modal then
		return
	end
	modal.backdrop.Visible = open
	CameraController.setCursorFree(open)
	if open then
		renderTab()
	end
end

function CraftingController.isOpen(): boolean
	return modal ~= nil and modal.backdrop.Visible
end

-- ============================================================ build

local function buildUi()
	modal = Kit.modal({
		name = "CraftingGui",
		title = "Crafting",
		subtitle = "",
		token = "ANVIL",
		size = UDim2.new(0.8, 0, 0.8, 0),
		minSize = Vector2.new(700, 460),
		maxSize = Vector2.new(1020, 640),
	})
	local body = modal.body

	local left = Kit.frame(body, {
		Name = "Left",
		Position = UDim2.new(0, PAD, 0, PAD),
		Size = UDim2.new(1, -(DETAIL_WIDTH + PAD * 3), 1, -PAD * 2),
	})
	tabs = Kit.tabs(left, TABS, setTab)

	local gridBox = Kit.panel(left, {
		Name = "GridBox",
		Position = UDim2.new(0, 0, 0, 48),
		Size = UDim2.new(1, 0, 1, -48),
	})
	grid = Kit.scroll(gridBox, {
		name = "Grid",
		position = UDim2.new(0, 10, 0, 10),
		size = UDim2.new(1, -20, 1, -20),
		grid = { cell = CARD_SIZE, cellHeight = CARD_SIZE + 22, gap = CARD_GAP },
		padding = 2,
	})

	local right = Kit.frame(body, {
		Name = "Right",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -PAD, 0, PAD),
		Size = UDim2.new(0, DETAIL_WIDTH, 1, -PAD * 2),
	})
	detail = ItemDetail.new(right)

	local setOpen = CraftingController.setOpen
	modal.close.Activated:Connect(function()
		setOpen(false)
	end)
	modal.backdrop.Activated:Connect(function()
		setOpen(false)
	end)

	ContextActionService:BindActionAtPriority("ToggleCrafting", function(_, state)
		if state == Enum.UserInputState.Begin then
			setOpen(not modal.backdrop.Visible)
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.C)

	modal.gui.Parent = player:WaitForChild("PlayerGui")
end

-- ============================================================ networking

local function setOwned(items)
	ownedSet = {}
	for _, id in items do
		ownedSet[id] = true
	end
end

local function pull(remote, apply)
	local ok, result = pcall(function()
		return remote:InvokeServer()
	end)
	if ok and type(result) == "table" then
		apply(result)
	end
end

-- ============================================================ lifecycle

function CraftingController.init()
	buildUi()
	setTab(TABS[1].kind)

	Remotes.InventoryUpdated.OnClientEvent:Connect(function(items)
		if type(items) == "table" then
			setOwned(items)
			if modal.backdrop.Visible then
				renderTab() -- a new item un-veils its card
			end
		end
	end)
	Remotes.MaterialsUpdated.OnClientEvent:Connect(function(all)
		if type(all) == "table" then
			materialCounts = all
			refresh()
		end
	end)
	Remotes.BaitUpdated.OnClientEvent:Connect(function(all)
		if type(all) == "table" then
			baitCounts = all
			refresh()
		end
	end)
	Remotes.CraftResult.OnClientEvent:Connect(function(result)
		if type(result) ~= "table" then
			return
		end
		statusOk = result.ok == true
		statusText = if result.ok then "Crafted!" else (result.reason or "Can't craft that.")
		showDetail(selectedId)
	end)

	for _, attr in
		{
			Progression.ATTR.level,
			Progression.ATTR.coins,
			Equipment.ROD_ATTRIBUTE,
			Equipment.WEAPON_ATTRIBUTE,
			Equipment.BAIT_ATTRIBUTE,
			Equipment.HELMET_ATTRIBUTE,
			Equipment.CHEST_ATTRIBUTE,
			Equipment.LEGS_ATTRIBUTE,
		}
	do
		player:GetAttributeChangedSignal(attr):Connect(refresh)
	end

	-- Heart attributes flip once per boss, ever - but the flip should light up
	-- the Legendary recipes the moment the kill lands, without reopening.
	for bossId in Bosses.items do
		player:GetAttributeChangedSignal("Heart_" .. bossId):Connect(refresh)
	end

	-- A new boat tier unveils the next rung's card, so the open tab re-renders
	-- rather than just re-tagging.
	player:GetAttributeChangedSignal("BoatTier"):Connect(function()
		if modal.backdrop.Visible and activeTab.kind == "boat" then
			renderTab()
		else
			refresh()
		end
	end)
end

function CraftingController.start()
	pull(Remotes.GetInventory, setOwned)
	pull(Remotes.GetMaterials, function(result)
		materialCounts = result
	end)
	pull(Remotes.GetBait, function(result)
		baitCounts = result
	end)
	renderTab()
end

return CraftingController
