--!nonstrict
-- Armor.luau
-- Armor sets and pieces. A PIECE fills one of three slots (helmet / chest /
-- legs), carries flat `defense` (damage reduction, PlayerService) and
-- optional bonus `health`; wearing ALL THREE pieces of one set wakes the
-- set's BONUS. A piece with a `recipe` is crafted (the "armor" descriptor
-- in CraftingService); one without is NPC/quest-only stock (shop `item`
-- slots / quest `items` rewards).
--
-- The perk rule holds set-wide: bonus fields are ONLY the three with live
-- consumers - `health` + `defense` (PlayerService: max-health recompute +
-- the damage reducer) and `damageBonus` (CombatService.landHit, beside the
-- trinket's). Do not invent fields ahead of their reader.
--
-- Worn state is three server-set Player attributes (Armor.ATTRIBUTES),
-- published by InventoryService; every consumer and the worn-model welds
-- (ArmorService lane) read those. Mesh naming for the ArmorPack:
-- <SetName>_Helm / _Chest / _Legs, where SetName = sets[id].modelPrefix.

local Armor = {}

Armor.SLOTS = { "helmet", "chest", "legs" }

Armor.ATTRIBUTES = {
	helmet = "EquippedHelmetId",
	chest = "EquippedChestId",
	legs = "EquippedLegsId",
}

export type Bonus = {
	name: string,
	description: string,
	health: number?,
	defense: number?,
	damageBonus: number?,
}

export type Set = {
	id: string,
	name: string,
	blurb: string,
	modelPrefix: string, -- ArmorPack mesh prefix (<Prefix>_Helm etc.)
	bonus: Bonus,
}

export type Piece = {
	id: string,
	name: string,
	set: string,
	slot: string,
	rarity: string,
	color: Color3?,
	defense: number,
	health: number?,
	recipe: { requiresLevel: number, coins: number, materials: { [string]: number } }?,
}

Armor.sets = {} :: { [string]: Set }
Armor.items = {} :: { [string]: Piece }

-- ============================================================ lookups

-- The worn piece rows by slot, off the replicated attributes.
function Armor.wornPieces(player: Player): { [string]: Piece }
	local out = {}
	for slot, attribute in Armor.ATTRIBUTES do
		local pieceId = player:GetAttribute(attribute)
		local piece = pieceId and Armor.items[pieceId]
		if piece then
			out[slot] = piece
		end
	end
	return out
end

-- The set bonus in effect: all three slots filled by pieces of ONE set.
function Armor.setBonusFor(player: Player): Bonus?
	local setId = nil
	local count = 0
	for _, piece in Armor.wornPieces(player) do
		if setId == nil then
			setId = piece.set
		elseif piece.set ~= setId then
			return nil
		end
		count += 1
	end
	if count < #Armor.SLOTS or not setId then
		return nil
	end
	local set = Armor.sets[setId]
	return set and set.bonus
end

-- Flat damage reduction: worn pieces' defense plus the set bonus's.
function Armor.defenseOf(player: Player): number
	local total = 0
	for _, piece in Armor.wornPieces(player) do
		total += piece.defense or 0
	end
	local bonus = Armor.setBonusFor(player)
	if bonus and bonus.defense then
		total += bonus.defense
	end
	return total
end

-- Bonus max health: worn pieces' plus the set bonus's.
function Armor.healthOf(player: Player): number
	local total = 0
	for _, piece in Armor.wornPieces(player) do
		total += piece.health or 0
	end
	local bonus = Armor.setBonusFor(player)
	if bonus and bonus.health then
		total += bonus.health
	end
	return total
end

-- One set-bonus field (CombatService reads damageBonus through this).
function Armor.bonusField(player: Player, field: string): number?
	local bonus = Armor.setBonusFor(player)
	return bonus and bonus[field]
end

-- ============================================================ the pilot sets
-- (Cove and mid-band, on EXISTING materials - the other lanes' sets bring
-- the new armor-stock materials with them.)

Armor.sets.chitin = {
	id = "chitin",
	name = "Chitin Shell",
	blurb = "Snapjaw plate scrubbed and lashed into wearable shell. Smells like low tide; stops teeth.",
	modelPrefix = "Chitin",
	bonus = {
		name = "Tidewall",
		description = "Full set: +12 max health, +2 defense.",
		health = 12,
		defense = 2,
	},
}

Armor.items.chitin_helm = {
	id = "chitin_helm",
	name = "Chitin Helm",
	set = "chitin",
	slot = "helmet",
	rarity = "Uncommon",
	color = Color3.fromRGB(214, 148, 110),
	defense = 2,
	recipe = { requiresLevel = 5, coins = 120, materials = { barnacle_chitin = 4, fish_scale = 3 } },
}

Armor.items.chitin_chest = {
	id = "chitin_chest",
	name = "Chitin Carapace",
	set = "chitin",
	slot = "chest",
	rarity = "Uncommon",
	color = Color3.fromRGB(214, 148, 110),
	defense = 4,
	health = 4,
	recipe = { requiresLevel = 7, coins = 200, materials = { barnacle_chitin = 6, kelp_fiber = 4 } },
}

Armor.items.chitin_legs = {
	id = "chitin_legs",
	name = "Chitin Greaves",
	set = "chitin",
	slot = "legs",
	rarity = "Uncommon",
	color = Color3.fromRGB(214, 148, 110),
	defense = 3,
	recipe = { requiresLevel = 6, coins = 160, materials = { barnacle_chitin = 5, driftwood = 3 } },
}

Armor.sets.boneplate = {
	id = "boneplate",
	name = "Boneplate",
	blurb = "Cursed bone drilled and wired into a lattice. It remembers being something that fought back.",
	modelPrefix = "Boneplate",
	bonus = {
		name = "Grave Ward",
		description = "Full set: +20 max health, +5% weapon damage.",
		health = 20,
		damageBonus = 0.05,
	},
}

Armor.items.boneplate_helm = {
	id = "boneplate_helm",
	name = "Boneplate Skullcap",
	set = "boneplate",
	slot = "helmet",
	rarity = "Rare",
	color = Color3.fromRGB(222, 214, 192),
	defense = 4,
	health = 3,
	recipe = { requiresLevel = 14, coins = 600, materials = { cursed_bone = 5, nacre = 2 } },
}

Armor.items.boneplate_chest = {
	id = "boneplate_chest",
	name = "Boneplate Ribcage",
	set = "boneplate",
	slot = "chest",
	rarity = "Rare",
	color = Color3.fromRGB(222, 214, 192),
	defense = 7,
	health = 6,
	recipe = { requiresLevel = 18, coins = 950, materials = { cursed_bone = 8, gator_scute = 3 } },
}

Armor.items.boneplate_legs = {
	id = "boneplate_legs",
	name = "Boneplate Tassets",
	set = "boneplate",
	slot = "legs",
	rarity = "Rare",
	color = Color3.fromRGB(222, 214, 192),
	defense = 5,
	health = 3,
	recipe = { requiresLevel = 16, coins = 750, materials = { cursed_bone = 6, bog_iron = 3 } },
}

return Armor
