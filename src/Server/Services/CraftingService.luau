--!nonstrict
-- CraftingService.luau
-- Turns materials + coins into anything with a recipe row. The recipe lives
-- on the item ({ requiresLevel, coins, materials, requiresHearts?, yield? });
-- this service validates and spends, and CATEGORIES below says what each
-- craftable kind IS: its data table, its ownership rule, its grant. Adding a
-- craftable category (trinkets, furniture, cosmetics...) is ONE descriptor
-- entry plus a client tab - the validation/spend path never changes.
--
-- CRAFTING IS NPC-ONLY NOW (2026-09-12, user: "move crafting entirely to the
-- npcs"). The `C` window is gone, and with it the RequestCraft remote as a way
-- in: the entry point is CraftingService.craft(player, itemId) -> (ok, reason),
-- called by NpcService when a villager's Craft tab is pressed. The remote is
-- still declared and still answered, but only to REFUSE - an old client (or a
-- forged fire) gets a CraftResult saying where crafting happens now.
--
-- check() is the same validation with nothing spent, split out so the villager's
-- menu can say "Craft" only where the server would actually say yes: the panel
-- and the transaction read the same gate in the same order, and a refusal the
-- menu did not predict (a race on a material, a level read a frame stale) still
-- comes back as a reason rather than a silent no-op.
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
local Armor = require(Shared.Data.Armor)
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
		key = "armor",
		items = Armor.items,
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

-- THE GATE, with nothing spent. Returns (true) when this player could craft
-- this id right now, else (false, reason) with the SAME reason string the
-- transaction would have refused with - the villager's menu prints it on a
-- greyed Craft button, so the two must never disagree.
--
-- (false, nil) is the one silent refusal: no ProgressionService state at all
-- (the profile is mid-load in a way DataService.isLoaded did not catch). The old
-- handler answered that with no CraftResult either, and a menu with no reason to
-- give simply offers no button.
--
-- Materials are PEEKED here (getCount), never spent: this runs on every menu
-- push, for every row.
function CraftingService.check(player: Player, itemId: string): (boolean, string?)
	if type(itemId) ~= "string" then
		return false, "That can't be crafted."
	end

	-- Same gate as casting (FishingService): spending or earning against the
	-- session defaults during the async profile load would be overwritten
	-- when the real data lands.
	if not DataService.isLoaded(player) then
		return false, "Hauling in your things... one moment."
	end

	local category, item = categoryOf(itemId)
	local recipe = item and item.recipe
	if not (category and recipe) then
		return false, "That can't be crafted."
	end

	local blocked, reason = category.owns(player, item)
	if blocked then
		return false, reason or "You already own that."
	end

	local state = ProgressionService.getState(player)
	if not state then
		return false, nil
	end

	if state.level < recipe.requiresLevel then
		return false, string.format("Requires level %d.", recipe.requiresLevel)
	end

	-- A heart-gated recipe needs the boss beaten, not a material spent: the
	-- Heart_<bossId> attribute BossService sets is permanent proof, so the
	-- trophy is never consumed and the item stays craftable forever after.
	if recipe.requiresHearts then
		for _, bossId in recipe.requiresHearts do
			if player:GetAttribute("Heart_" .. bossId) ~= true then
				local boss = Bosses.items[bossId]
				return false, string.format("Requires the heart of %s.", boss and boss.shortName or bossId)
			end
		end
	end
	if state.coins < recipe.coins then
		return false, "Not enough coins."
	end
	for matId, need in recipe.materials do
		if MaterialService.getCount(player, matId) < need then
			return false, "Not enough materials."
		end
	end
	return true
end

-- ONE CRAFT. The only way anything is ever crafted: NpcService calls this when a
-- villager's Craft button comes back over NpcChoice, and answers with a fresh
-- menu carrying `reason` as the remark. CraftResult still goes out on both paths
-- - it is the wire's record of the verdict, unchanged from the old window.
function CraftingService.craft(player: Player, itemId: string): (boolean, string?)
	local ok, reason = CraftingService.check(player, itemId)
	if not ok then
		if reason then
			fail(player, itemId, reason)
		end
		return false, reason
	end

	-- check() said yes and nothing has yielded since (RemoteEvent fires and
	-- attribute reads don't), so the balances it peeked are still the balances
	-- here. Spend the mats first anyway - the all-or-nothing spend is the real
	-- authority, and if it somehow fails, coins were never touched.
	local category, item = categoryOf(itemId)
	local recipe = item.recipe
	if not MaterialService.spend(player, recipe.materials) then
		fail(player, itemId, "Not enough materials.")
		return false, "Not enough materials."
	end
	ProgressionService.spendCoins(player, recipe.coins)

	category.grant(player, item)
	-- The quest funnel: one line, the whole hook (Beyond the Cast A4).
	QuestService.notify("craft", { player = player, itemId = itemId })
	Remotes.CraftResult:FireClient(player, { ok = true, itemId = itemId })
	return true
end

-- The retired way in. RequestCraft is kept connected rather than dropped so the
-- refusal is a sentence in the game's own voice instead of a request that
-- vanishes: a client built before the move (or one poking the remote by hand)
-- is TOLD where the bench is.
local function onRequestCraft(player: Player, itemId)
	fail(player, if type(itemId) == "string" then itemId else "", "Craft at a villager")
end

function CraftingService.init()
	Remotes.RequestCraft.OnServerEvent:Connect(onRequestCraft)
end

function CraftingService.start() end

return CraftingService
