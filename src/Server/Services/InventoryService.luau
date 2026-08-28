--!nonstrict
-- InventoryService.luau
-- Owns what each player carries and what's in their hands. Ownership and the
-- equipped rod/weapon choices persist through DataService (this service
-- registers an "inventory" slice); an id that no longer exists in the data
-- tables is silently dropped on load, so cutting an item from Rods/Weapons
-- retires it from old profiles too. Every player gets the starter rod and
-- the starter weapon (fists) the moment they join, and starts holding the rod.
--
-- Items are ids from two namespaces - Rods.luau and Weapons.luau - kept in
-- ONE list per player. This service doesn't care what an id points at, only
-- that the player owns it (grantItem checks the id is real in either table);
-- the clients split the list by looking each id up in the table they render.
-- A third item kind later is another table in grantItem's lookup, nothing
-- else.
--
-- The loadout - rod or weapon, see Shared/Config/Equipment - is published
-- as an attribute on the Player so it replicates on its own: the owner's
-- client draws the matching viewmodel, and anyone (late joiners included)
-- can read it. WHICH rod and WHICH weapon are two more attributes, so "1"
-- and "2" always mean "whatever I've picked". Other services react through
-- onEquipChanged rather than polling: RodService / WeaponService weld or
-- remove the world model, FishingService drops a cast when the rod goes away.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Equipment = require(Shared.Config.Equipment)
local Rods = require(Shared.Data.Rods)
local Weapons = require(Shared.Data.Weapons)
local Trinkets = require(Shared.Data.Trinkets)
local Remotes = require(Shared.Net.Remotes)

local DataService = require(script.Parent.DataService)

local InventoryService = {}

local inventories: { [Player]: { string } } = {}

-- Which owned rod goes in the hand when the rod is equipped, and which
-- owned weapon when the weapon is.
local equippedRod: { [Player]: string } = {}
local equippedWeapon: { [Player]: string } = {}
local equippedTrinket: { [Player]: string } = {}

-- What's actually in the hands right now: Equipment.ROD or Equipment.WEAPON.
local equippedKind: { [Player]: string } = {}

-- Callbacks for (player, kind) whenever the hands change.
local equipListeners: { (Player, string) -> () } = {}

-- ============================================================ queries

function InventoryService.getEquippedRod(player: Player): string?
	return equippedRod[player]
end

function InventoryService.getEquippedWeapon(player: Player): string?
	return equippedWeapon[player]
end

-- Whether the player owns `itemId` (a rod or a weapon id).
function InventoryService.ownsItem(player: Player, itemId: string): boolean
	local owned = inventories[player]
	return owned ~= nil and table.find(owned, itemId) ~= nil
end

function InventoryService.getEquipped(player: Player): string?
	return equippedKind[player]
end

-- Register for loadout changes. Safe to call before init() - the list is
-- module-level. Each callback runs in its own thread so one that yields
-- (RodService waits for the hand part) can't hold up the others.
function InventoryService.onEquipChanged(callback: (Player, string) -> ())
	table.insert(equipListeners, callback)
end

local function fireEquipChanged(player: Player, kind: string)
	for _, callback in equipListeners do
		task.spawn(callback, player, kind)
	end
end

-- ============================================================ loadout

-- Switches what's in the hands. Returns false (and changes nothing) if the
-- kind isn't one we know or the player has nothing of that kind to equip.
function InventoryService.setEquipped(player: Player, kind: string): boolean
	if not Equipment.KINDS[kind] then
		return false
	end
	if kind == Equipment.ROD and not equippedRod[player] then
		return false
	end
	if kind == Equipment.WEAPON and not equippedWeapon[player] then
		return false
	end
	if equippedKind[player] == kind then
		return true
	end

	equippedKind[player] = kind
	player:SetAttribute(Equipment.ATTRIBUTE, kind)
	fireEquipChanged(player, kind)
	return true
end

-- Chooses which owned item of `kind` goes in the hand. Returns false if the
-- player doesn't own it. If that kind is what's currently held, re-fires the
-- equip listeners so the world model re-welds (and the viewmodel rebuilds,
-- and any active cast abandons); otherwise it just takes effect next time
-- they equip that kind. The choice is published as `attribute` so the client
-- can show which one is equipped.
local function setEquippedOf(player: Player, itemId: string, chosen, attribute: string, kind: string): boolean
	if not InventoryService.ownsItem(player, itemId) then
		return false
	end
	if chosen[player] == itemId then
		return true
	end

	chosen[player] = itemId
	player:SetAttribute(attribute, itemId)

	if equippedKind[player] == kind then
		fireEquipChanged(player, kind)
	end
	return true
end

function InventoryService.setEquippedRod(player: Player, rodId: string): boolean
	if not Rods.items[rodId] then
		return false
	end
	return setEquippedOf(player, rodId, equippedRod, Equipment.ROD_ATTRIBUTE, Equipment.ROD)
end

function InventoryService.setEquippedWeapon(player: Player, weaponId: string): boolean
	if not Weapons.items[weaponId] then
		return false
	end
	return setEquippedOf(player, weaponId, equippedWeapon, Equipment.WEAPON_ATTRIBUTE, Equipment.WEAPON)
end

-- The worn trinket. Not a hand kind: nothing changes in anyone's grip, so
-- there is no equippedKind interplay - just ownership-checked publication of
-- the attribute the perk consumers read.
function InventoryService.setEquippedTrinket(player: Player, trinketId: string): boolean
	if not Trinkets.items[trinketId] then
		return false
	end
	local owned = inventories[player]
	if not owned or not table.find(owned, trinketId) then
		return false
	end
	equippedTrinket[player] = trinketId
	player:SetAttribute(Equipment.TRINKET_ATTRIBUTE, trinketId)
	return true
end

-- ============================================================ ownership

local function pushInventory(player: Player)
	Remotes.InventoryUpdated:FireClient(player, inventories[player] or {})
end

-- Adds an item to the player's inventory (crafting). No-op if already owned;
-- false if the id isn't a real rod, weapon or trinket. Does not equip it.
function InventoryService.grantItem(player: Player, itemId: string): boolean
	if not Rods.items[itemId] and not Weapons.items[itemId] and not Trinkets.items[itemId] then
		return false
	end
	local owned = inventories[player]
	if not owned then
		return false
	end
	if not table.find(owned, itemId) then
		table.insert(owned, itemId)
		pushInventory(player)
	end
	return true
end

local function grantStarters(player: Player)
	local owned = inventories[player]
	if not owned then
		owned = {}
		inventories[player] = owned
	end

	for _, starterId in { Rods.STARTER_ROD_ID, Weapons.STARTER_WEAPON_ID } do
		if not table.find(owned, starterId) then
			table.insert(owned, starterId)
		end
	end

	if not equippedRod[player] then
		equippedRod[player] = Rods.STARTER_ROD_ID
	end
	if not equippedWeapon[player] then
		equippedWeapon[player] = Weapons.STARTER_WEAPON_ID
	end
	player:SetAttribute(Equipment.ROD_ATTRIBUTE, equippedRod[player])
	player:SetAttribute(Equipment.WEAPON_ATTRIBUTE, equippedWeapon[player])
end

-- ============================================================ persistence

-- DataService slice. Ids are re-validated against the live data tables so a
-- cut item vanishes from old profiles instead of resurfacing as a ghost.
local function loadSlice(player: Player, slice)
	if type(slice) ~= "table" then
		return -- fresh profile: starters already granted
	end
	local owned = inventories[player]
	if not owned then
		return
	end
	if type(slice.items) == "table" then
		for _, itemId in slice.items do
			if
				type(itemId) == "string"
				and (Rods.items[itemId] or Weapons.items[itemId] or Trinkets.items[itemId])
				and not table.find(owned, itemId)
			then
				table.insert(owned, itemId)
			end
		end
	end
	-- Restore the picks only if still owned and still real; otherwise the
	-- starter defaults from grantStarters stand.
	if
		type(slice.equippedRod) == "string"
		and Rods.items[slice.equippedRod]
		and table.find(owned, slice.equippedRod)
	then
		equippedRod[player] = slice.equippedRod
	end
	if
		type(slice.equippedWeapon) == "string"
		and Weapons.items[slice.equippedWeapon]
		and table.find(owned, slice.equippedWeapon)
	then
		equippedWeapon[player] = slice.equippedWeapon
	end
	if
		type(slice.equippedTrinket) == "string"
		and Trinkets.items[slice.equippedTrinket]
		and table.find(owned, slice.equippedTrinket)
	then
		equippedTrinket[player] = slice.equippedTrinket
		player:SetAttribute(Equipment.TRINKET_ATTRIBUTE, slice.equippedTrinket)
	end
	player:SetAttribute(Equipment.ROD_ATTRIBUTE, equippedRod[player])
	player:SetAttribute(Equipment.WEAPON_ATTRIBUTE, equippedWeapon[player])
	pushInventory(player)
	if equippedKind[player] then
		fireEquipChanged(player, equippedKind[player])
	end
end

local function serializeSlice(player: Player)
	return {
		items = table.clone(inventories[player] or {}),
		equippedRod = equippedRod[player],
		equippedWeapon = equippedWeapon[player],
		equippedTrinket = equippedTrinket[player],
	}
end

-- ============================================================ lifecycle

local function onPlayerAdded(player: Player)
	grantStarters(player)
	pushInventory(player)

	-- Published directly rather than through setEquipped: nobody needs a
	-- "change" callback for the initial state - RodService reads it when
	-- the character spawns.
	if not equippedKind[player] then
		equippedKind[player] = Equipment.DEFAULT
		player:SetAttribute(Equipment.ATTRIBUTE, Equipment.DEFAULT)
	end
end

-- Called by DataService after the final serialize on leave - never from our
-- own PlayerRemoving connection (that raced the save; DataService's header).
local function releasePlayer(player: Player)
	inventories[player] = nil
	equippedRod[player] = nil
	equippedWeapon[player] = nil
	equippedTrinket[player] = nil
	equippedKind[player] = nil
end

function InventoryService.init()
	DataService.register("inventory", { load = loadSlice, serialize = serializeSlice, release = releasePlayer })

	Remotes.GetInventory.OnServerInvoke = function(player: Player)
		return inventories[player] or {}
	end

	Remotes.RequestEquip.OnServerEvent:Connect(function(player: Player, kind)
		if type(kind) ~= "string" then
			return
		end
		InventoryService.setEquipped(player, kind)
	end)

	Remotes.RequestEquipRod.OnServerEvent:Connect(function(player: Player, rodId)
		if type(rodId) ~= "string" then
			return
		end
		InventoryService.setEquippedRod(player, rodId)
	end)

	Remotes.RequestEquipWeapon.OnServerEvent:Connect(function(player: Player, weaponId)
		if type(weaponId) ~= "string" then
			return
		end
		InventoryService.setEquippedWeapon(player, weaponId)
	end)

	Remotes.RequestEquipTrinket.OnServerEvent:Connect(function(player: Player, trinketId)
		if type(trinketId) ~= "string" then
			return
		end
		InventoryService.setEquippedTrinket(player, trinketId)
	end)
end

function InventoryService.start()
	Players.PlayerAdded:Connect(onPlayerAdded)

	-- Catch players already in the server (Studio's "Run" without a fresh
	-- join, or this service starting after PlayerAdded already fired).
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return InventoryService
