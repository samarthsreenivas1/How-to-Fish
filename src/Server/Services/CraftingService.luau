--!nonstrict
-- CraftingService.luau
-- Turns materials + coins into anything with a recipe row. The recipe lives
-- on the item ({ requiresLevel, coins, materials, requiresHearts?, yield? });
-- this service validates and spends, and CATEGORIES below says what each
-- craftable kind IS: its data table, its ownership rule, its grant. Adding a
-- craftable category (trinkets, furniture, cosmetics...) is ONE descriptor
-- entry plus a client tab - the validation/spend path never changes.
--
-- Validation order matters for atomicity. Coins are checked (peeked) before
-- anything is spent, then the materials are spent (all-or-nothing), then the
-- coins. Nothing yields between those steps - RemoteEvent fires don't yield -
-- so no other request can slip in and change a balance mid-craft. If the
-- material spend fails, coins were never touched.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Bait = require(Shared.Data.Bait)
local Boats = require(Shared.Data.Boats)
local Bosses = require(Shared.Data.Bosses)
local Rods = require(Shared.Data.Rods)
local Trinkets = require(Shared.Data.Trinkets)
local Weapons = require(Shared.Data.Weapons)
local Remotes = require(Shared.Net.Remotes)

local BaitService = require(script.Parent.BaitService)
local BoatService = require(script.Parent.BoatService)
local DataService = require(script.Parent.DataService)
local InventoryService = require(script.Parent.InventoryService)
local MaterialService = require(script.Parent.MaterialService)
local ProgressionService = require(script.Parent.ProgressionService)
local QuestService = require(script.Parent.QuestService)

local CraftingService = {}

-- What each craftable kind IS. `owns(player, item) -> blocked, reason?`
-- guards re-crafting (bait never blocks: it's a stackable consumable; a
-- boat is a LADDER - owning is a tier number and each hull builds onto the
-- previous, so exactly the next tier up is craftable); `grant` hands the
-- finished thing over. Lookup order is cosmetic - ids are unique across
-- tables by construction (check_content enforces the data files).
local CATEGORIES = {
	{
		key = "rod",
		items = Rods.items,
		owns = function(player: Player, item)
			return InventoryService.ownsItem(player, item.id), "You already own that."
		end,
		grant = function(player: Player, item)
			InventoryService.grantItem(player, item.id)
		end,
	},
	{
		key = "weapon",
		items = Weapons.items,
		owns = function(player: Player, item)
			return InventoryService.ownsItem(player, item.id), "You already own that."
		end,
		grant = function(player: Player, item)
			InventoryService.grantItem(player, item.id)
		end,
	},
	{
		key = "trinket",
		items = Trinkets.items,
		owns = function(player: Player, item)
			return InventoryService.ownsItem(player, item.id), "You already own that."
		end,
		grant = function(player: Player, item)
			InventoryService.grantItem(player, item.id)
		end,
	},
	{
		key = "bait",
		items = Bait.items,
		owns = function()
			return false
		end,
		grant = function(player: Player, item)
			BaitService.grant(player, item.id, item.recipe.yield)
		end,
	},
	{
		key = "boat",
		items = Boats.items,
		owns = function(player: Player, item)
			local tier = BoatService.tierOf(player)
			if tier >= item.tier then
				return true, "You already own that."
			end
			if item.tier ~= tier + 1 then
				local needed = Boats.byTier[item.tier - 1]
				return true, string.format("Build the %s first.", needed and needed.name or "previous hull")
			end
			return false
		end,
		grant = function(player: Player, item)
			BoatService.grantTier(player, item.tier)
		end,
	},
}

local function categoryOf(itemId: string)
	for _, category in CATEGORIES do
		local item = category.items[itemId]
		if item then
			return category, item
		end
	end
	return nil, nil
end

local function fail(player: Player, itemId: string, reason: string)
	Remotes.CraftResult:FireClient(player, { ok = false, itemId = itemId, reason = reason })
end

local function onRequestCraft(player: Player, itemId)
	if type(itemId) ~= "string" then
		return
	end

	-- Same gate as casting (FishingService): spending or earning against the
	-- session defaults during the async profile load would be overwritten
	-- when the real data lands.
	if not DataService.isLoaded(player) then
		fail(player, itemId, "Hauling in your things... one moment.")
		return
	end

	local category, item = categoryOf(itemId)
	local recipe = item and item.recipe
	if not (category and recipe) then
		fail(player, itemId, "That can't be crafted.")
		return
	end

	local blocked, reason = category.owns(player, item)
	if blocked then
		fail(player, itemId, reason or "You already own that.")
		return
	end

	local state = ProgressionService.getState(player)
	if not state then
		return
	end

	if state.level < recipe.requiresLevel then
		fail(player, itemId, string.format("Requires level %d.", recipe.requiresLevel))
		return
	end

	-- A heart-gated recipe needs the boss beaten, not a material spent: the
	-- Heart_<bossId> attribute BossService sets is permanent proof, so the
	-- trophy is never consumed and the item stays craftable forever after.
	if recipe.requiresHearts then
		for _, bossId in recipe.requiresHearts do
			if player:GetAttribute("Heart_" .. bossId) ~= true then
				local boss = Bosses.items[bossId]
				fail(player, itemId, string.format("Requires the heart of %s.", boss and boss.shortName or bossId))
				return
			end
		end
	end
	if state.coins < recipe.coins then
		fail(player, itemId, "Not enough coins.")
		return
	end

	-- Coins are affordable (checked above, no yield since); spend the mats
	-- first - if the player is short, nothing else was touched.
	if not MaterialService.spend(player, recipe.materials) then
		fail(player, itemId, "Not enough materials.")
		return
	end
	ProgressionService.spendCoins(player, recipe.coins)

	category.grant(player, item)
	-- The quest funnel: one line, the whole hook (Beyond the Cast A4).
	QuestService.notify("craft", { player = player, itemId = itemId })
	Remotes.CraftResult:FireClient(player, { ok = true, itemId = itemId })
end

function CraftingService.init()
	Remotes.RequestCraft.OnServerEvent:Connect(onRequestCraft)
end

function CraftingService.start() end

return CraftingService
