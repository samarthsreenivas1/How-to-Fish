--!nonstrict
-- InventoryController.luau
-- The inventory menu: I (or B) opens a centred window with four tabs - Rods,
-- Materials, Weapons, Bait - a scrolling grid of cards for the open tab, and
-- a detail column on the right for whatever card is selected: the thing's
-- tile, rarity, ability card (rods / weapons), stat pips, effect chips
-- (bait), count (materials / bait), and an Equip / Select button.
--
-- Rebuilt on the shared UI kit in the 2026-08-23 overhaul (Client/UI/Kit,
-- ItemDetail, Describe): the state, remotes and hotkeys are unchanged from
-- the first version; only what it looks like is new.
--
-- Where each tab's contents come from:
--   Rods      - InventoryService's owned-item ids (GetInventory /
--               InventoryUpdated - one mixed list of rod AND weapon ids),
--               keeping the ones Rods.luau knows.
--   Materials - MaterialService's counts (GetMaterials / MaterialsUpdated),
--               one card per Materials.order row, dimmed at zero.
--   Weapons   - the same owned list, keeping the ids Weapons.luau knows, in
--               Weapons.order. Everyone owns the fists.
--   Bait      - BaitService's counts (GetBait / BaitUpdated), every bait row;
--               the selected one carries the "in hand" ring.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Equipment = require(Shared.Config.Equipment)
local Bait = require(Shared.Data.Bait)
local Materials = require(Shared.Data.Materials)
local Rods = require(Shared.Data.Rods)
local Weapons = require(Shared.Data.Weapons)
local Rarity = require(Shared.Modules.Rarity)
local Remotes = require(Shared.Net.Remotes)

local Theme = require(script.Parent.Parent.UI.Theme)
local Kit = require(script.Parent.Parent.UI.Kit)
local Describe = require(script.Parent.Parent.UI.Describe)
local ItemDetail = require(script.Parent.Parent.UI.ItemDetail)
local Sfx = require(script.Parent.Parent.Modules.Sfx)
local CameraController = require(script.Parent.CameraController)

local player = Players.LocalPlayer

local InventoryController = {}

local C = Theme.Color

-- Layout.
local CARD_SIZE = 96
local CARD_GAP = 10
local DETAIL_WIDTH = 318
local PAD = 16
local MATERIAL_DIM = 0.5 -- a material / bait you have none of

-- The tabs, in display order. `kind` is what a card / selection carries.
local TABS = {
	{ kind = "rod", label = "Rods", token = "ROD", noun = "rod" },
	{ kind = "material", label = "Materials", token = "MAT", noun = "material", width = 132 },
	{ kind = "weapon", label = "Weapons", token = "WPN", noun = "weapon", width = 128 },
	{ kind = "bait", label = "Bait", token = "BAIT", noun = "bait" },
}

local modal -- Kit.modal handle
local tabs -- Kit.tabs handle
local grid: ScrollingFrame
local detail -- ItemDetail

local activeKind = "rod"
local ownedIds: { string } = {}
local materialCounts: { [string]: number } = {}
local baitCounts: { [string]: number } = {}

local selected: { kind: string, id: string }? = nil
local cards: { [string]: any } = {} -- id -> Kit.card handle, open tab only

-- ============================================================ helpers

local function isEquipped(kind: string, id: string): boolean
	local loadout = player:GetAttribute(Equipment.ATTRIBUTE)
	if kind == "weapon" then
		local weaponId = player:GetAttribute(Equipment.WEAPON_ATTRIBUTE) or Weapons.STARTER_WEAPON_ID
		return loadout == Equipment.WEAPON and weaponId == id
	elseif kind == "rod" then
		return loadout == Equipment.ROD and player:GetAttribute(Equipment.ROD_ATTRIBUTE) == id
	elseif kind == "bait" then
		return (player:GetAttribute(Equipment.BAIT_ATTRIBUTE) or "") == id
	end
	return false
end

-- Puts an owned rod / weapon in the player's hands: pick it as the chosen
-- one of its kind, then raise that kind. Both are server-validated.
local function requestEquip(kind: string, id: string)
	if kind == "rod" then
		Remotes.RequestEquipRod:FireServer(id)
		Remotes.RequestEquip:FireServer(Equipment.ROD)
	elseif kind == "weapon" then
		Remotes.RequestEquipWeapon:FireServer(id)
		Remotes.RequestEquip:FireServer(Equipment.WEAPON)
	elseif kind == "bait" then
		Remotes.RequestSelectBait:FireServer(id)
	end
end

local function entryFor(kind: string, id: string)
	if kind == "rod" then
		return Rods.items[id]
	elseif kind == "material" then
		return Materials.items[id]
	elseif kind == "bait" then
		return Bait.items[id]
	end
	return Weapons.items[id]
end

-- ============================================================ detail

local function showDetail(sel)
	local entry = sel and entryFor(sel.kind, sel.id)
	if not entry then
		detail:clear("Nothing here yet. Cast a line!")
		return
	end

	local equipped = isEquipped(sel.kind, sel.id)
	local spec = {
		name = entry.name,
		rarity = entry.rarity,
		nameColor = Rarity.colorOf(entry.rarity),
		description = entry.description,
		image = entry.icon,
		token = Kit.monogram(entry.name),
		tileColor = entry.color or Rarity.colorOf(entry.rarity),
	}

	if sel.kind == "rod" then
		spec.state = if equipped then "IN HAND" else nil
		spec.perk = entry.perk
		spec.pips = Describe.rodPips(entry)
		spec.actions = {
			{
				text = if equipped then "In Hand" else "Equip",
				style = if equipped then "secondary" else "primary",
				enabled = not equipped,
				disabledText = C.green,
				onClick = function()
					requestEquip("rod", sel.id)
				end,
			},
		}
	elseif sel.kind == "weapon" then
		spec.state = if equipped then "IN HAND" else nil
		spec.perk = entry.perk
		spec.pips = Describe.weaponPips(entry)
		spec.actions = {
			{
				text = if equipped then "In Hand" else "Equip",
				style = if equipped then "secondary" else "primary",
				enabled = not equipped,
				disabledText = C.green,
				onClick = function()
					requestEquip("weapon", sel.id)
				end,
			},
		}
	elseif sel.kind == "material" then
		spec.count = materialCounts[sel.id] or 0
		spec.tileColor = entry.color or Rarity.colorOf(entry.rarity)
	elseif sel.kind == "bait" then
		local count = baitCounts[sel.id] or 0
		spec.count = count
		spec.state = if equipped then "SELECTED" else nil
		spec.stateColor = C.green
		spec.effects = Describe.baitEffects(entry.effect)
		spec.actions = {
			{
				text = if equipped then "Selected" else "Select",
				style = if equipped then "secondary" else "primary",
				enabled = not equipped and count > 0,
				disabledText = if equipped then C.green else nil,
				onClick = function()
					requestEquip("bait", sel.id)
				end,
			},
		}
	end

	detail:show(spec)
end

local function setSelected(sel)
	if selected and cards[selected.id] then
		cards[selected.id].setSelected(false)
	end
	selected = sel
	if selected and cards[selected.id] then
		cards[selected.id].setSelected(true)
	end
	showDetail(selected)
end

-- ============================================================ grid

local function idsFor(kind: string): { string }
	if kind == "rod" then
		local ids = {}
		for _, id in ownedIds do
			if Rods.items[id] then
				table.insert(ids, id)
			end
		end
		return ids
	elseif kind == "material" then
		return Materials.order
	elseif kind == "bait" then
		return Bait.order
	end
	local owned = {}
	for _, id in ownedIds do
		owned[id] = true
	end
	local ids = {}
	for _, id in Weapons.order do
		if owned[id] then
			table.insert(ids, id)
		end
	end
	return ids
end

local function clearCards()
	for id, handle in cards do
		handle.frame:Destroy()
		cards[id] = nil
	end
end

local function render()
	clearCards()

	local ids = idsFor(activeKind)
	for i, id in ids do
		local entry = entryFor(activeKind, id)
		if entry then
			local count = nil
			if activeKind == "material" then
				count = materialCounts[id] or 0
			elseif activeKind == "bait" then
				count = baitCounts[id] or 0
			end
			local kind = activeKind
			cards[id] = Kit.card(grid, {
				name = id,
				order = i,
				size = CARD_SIZE,
				label = entry.name,
				rarity = entry.rarity,
				color = entry.color,
				image = entry.icon,
				count = count,
				dim = if count == 0 then MATERIAL_DIM else 0,
				equipped = isEquipped(kind, id),
				onSelect = function()
					-- The cue hangs off the CARD, not off setSelected(): render()
					-- re-selects on every InventoryUpdated / tab switch to keep the
					-- detail pane populated, and hooking the setter would fire a
					-- click for selections the player never made.
					Sfx.play("uiSelect")
					setSelected({ kind = kind, id = id })
				end,
			})
		end
	end

	local tab = nil
	for _, t in TABS do
		if t.kind == activeKind then
			tab = t
		end
	end
	local n = #ids
	modal.subtitle.Text = if n == 1 then "1 " .. tab.noun else string.format("%d %ss", n, tab.noun)

	if selected and selected.kind == activeKind and cards[selected.id] then
		setSelected(selected)
	elseif ids[1] then
		setSelected({ kind = activeKind, id = ids[1] })
	else
		setSelected(nil)
	end
end

local function setTab(kind: string)
	-- Only a real move between tabs is a tab sound; clicking the tab you are
	-- already on re-renders but must stay silent.
	if kind ~= activeKind then
		Sfx.play("uiTab")
	end
	activeKind = kind
	tabs.set(kind)
	render()
end

-- ============================================================ open / close

function InventoryController.setOpen(open: boolean)
	if not modal then
		return
	end
	-- setOpen(x) is called freely with the state it already has (the menu
	-- buttons close every other menu before opening one, hotkeys re-assert
	-- it), so the cue hangs off the CHANGE, not off the call.
	local changed = modal.backdrop.Visible ~= open
	modal.backdrop.Visible = open
	CameraController.setCursorFree(open)
	if changed then
		Sfx.play(if open then "uiOpen" else "uiClose")
	end
	if open then
		render()
	end
end

function InventoryController.isOpen(): boolean
	return modal ~= nil and modal.backdrop.Visible
end

-- ============================================================ build

local function buildUi()
	modal = Kit.modal({
		name = "InventoryGui",
		title = "Inventory",
		subtitle = "",
		token = "BAG",
		size = UDim2.new(0.8, 0, 0.8, 0),
		minSize = Vector2.new(680, 440),
		maxSize = Vector2.new(1000, 620),
	})

	local body = modal.body

	-- Left column: tabs over the grid.
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

	-- Right column: the detail.
	local right = Kit.frame(body, {
		Name = "Right",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -PAD, 0, PAD),
		Size = UDim2.new(0, DETAIL_WIDTH, 1, -PAD * 2),
	})
	detail = ItemDetail.new(right)

	local setOpen = InventoryController.setOpen
	modal.close.Activated:Connect(function()
		setOpen(false)
	end)
	modal.backdrop.Activated:Connect(function()
		setOpen(false)
	end)

	-- "I" (or B as a fallback) toggles the menu. Bound through
	-- ContextActionService at High priority: Roblox's camera scripts bind I as
	-- a zoom key; in Studio's Play mode that capture can't always be beaten
	-- (a known platform quirk), hence B alongside. See context.md.
	ContextActionService:BindActionAtPriority("ToggleInventory", function(_, state)
		if state == Enum.UserInputState.Begin then
			setOpen(not modal.backdrop.Visible)
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.I, Enum.KeyCode.B)

	modal.gui.Parent = player:WaitForChild("PlayerGui")
end

-- ============================================================ networking

local function refreshFromServer()
	local ok, result = pcall(function()
		return Remotes.GetInventory:InvokeServer()
	end)
	if ok and type(result) == "table" then
		ownedIds = result
	else
		warn("[InventoryController] failed to fetch inventory from server")
	end

	local okMats, mats = pcall(function()
		return Remotes.GetMaterials:InvokeServer()
	end)
	if okMats and type(mats) == "table" then
		materialCounts = mats
	else
		warn("[InventoryController] failed to fetch materials from server")
	end

	local okBait, baits = pcall(function()
		return Remotes.GetBait:InvokeServer()
	end)
	if okBait and type(baits) == "table" then
		baitCounts = baits
	else
		warn("[InventoryController] failed to fetch bait from server")
	end

	render()
end

-- ============================================================ lifecycle

function InventoryController.init()
	buildUi()
	setTab(activeKind)

	Remotes.InventoryUpdated.OnClientEvent:Connect(function(items)
		if type(items) ~= "table" then
			return
		end
		ownedIds = items
		if activeKind == "rod" or activeKind == "weapon" then
			render()
		end
	end)
	Remotes.MaterialsUpdated.OnClientEvent:Connect(function(all)
		if type(all) == "table" then
			materialCounts = all
			if activeKind == "material" then
				render()
			end
		end
	end)
	Remotes.BaitUpdated.OnClientEvent:Connect(function(all)
		if type(all) == "table" then
			baitCounts = all
			if activeKind == "bait" then
				render()
			end
		end
	end)
	for _, attribute in
		{ Equipment.ATTRIBUTE, Equipment.ROD_ATTRIBUTE, Equipment.WEAPON_ATTRIBUTE, Equipment.BAIT_ATTRIBUTE }
	do
		player:GetAttributeChangedSignal(attribute):Connect(function()
			if modal.backdrop.Visible then
				render()
			end
		end)
	end
end

function InventoryController.start()
	refreshFromServer()
end

return InventoryController
