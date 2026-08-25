--!nonstrict
-- CraftingService.luau
-- Turns materials + coins into rods and weapons. The recipe lives on the
-- item's row (Rods.items.<id>.recipe / Weapons.items.<id>.recipe =
-- { requiresLevel, coins, materials, requiresHearts? }); this service just
-- validates and spends. Item-agnostic on purpose: an id is looked up in every content
-- table that can carry a recipe, and InventoryService.grantItem takes either.
--
-- Validation order matters for atomicity. Coins are checked (peeked) before
-- anything is spent, then the materials are spent (all-or-nothing), then the
-- coins. Nothing yields between those steps - RemoteEvent fires don't yield -
-- so no other request can slip in and change a balance mid-craft. If the
-- material spend fails, coins were never touched.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Bait = require(Shared.Data.Bait)
local Bosses = require(Shared.Data.Bosses)
local Rods = require(Shared.Data.Rods)
local Weapons = require(Shared.Data.Weapons)
local Remotes = require(Shared.Net.Remotes)

local BaitService = require(script.Parent.BaitService)
local InventoryService = require(script.Parent.InventoryService)
local MaterialService = require(script.Parent.MaterialService)
local ProgressionService = require(script.Parent.ProgressionService)

local CraftingService = {}

local function fail(player: Player, itemId: string, reason: string)
	Remotes.CraftResult:FireClient(player, { ok = false, itemId = itemId, reason = reason })
end

local function onRequestCraft(player: Player, itemId)
	if type(itemId) ~= "string" then
		return
	end

	local item = Rods.items[itemId] or Weapons.items[itemId] or Bait.items[itemId]
	local recipe = item and item.recipe
	if not recipe then
		fail(player, itemId, "That can't be crafted.")
		return
	end

	-- Bait is a stackable consumable, so the "already own it" guard (which stops
	-- re-crafting a rod/weapon you already hold) must not apply to it - you
	-- always want to make more bait.
	local isBait = Bait.items[itemId] ~= nil
	if not isBait and InventoryService.ownsItem(player, itemId) then
		fail(player, itemId, "You already own that.")
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

	-- Bait bumps a stackable count (by the recipe's yield); rods/weapons add an
	-- owned id. Same recipe/spend path up to here.
	if isBait then
		BaitService.grant(player, itemId, recipe.yield)
	else
		InventoryService.grantItem(player, itemId)
	end
	Remotes.CraftResult:FireClient(player, { ok = true, itemId = itemId })
end

function CraftingService.init()
	Remotes.RequestCraft.OnServerEvent:Connect(onRequestCraft)
end

function CraftingService.start() end

return CraftingService
