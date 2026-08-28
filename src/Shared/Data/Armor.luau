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

-- ============================================================ the island sets (f5 lane, 2026-08-28)
-- One set per mid-game band, each built from that island's armor-stock
-- materials (ee01ac5) + its signature mat, and each with ONE piece that
-- never touches the forge - a quest or a shopkeeper has it (recipe = nil).

-- Blackmire Fen (L8-14): peat-cured leathers. Helm is Morra's quest reward.
Armor.sets.mirewalker = {
	id = "mirewalker",
	name = "Mirewalker",
	blurb = "Gator leather and fen chitin, cured in peat. The bog stops claiming your boots and starts making them.",
	modelPrefix = "Mirewalker",
	bonus = {
		name = "Bog-Blooded",
		description = "Full set: +12 max health.",
		health = 12,
	},
}

Armor.items.mirewalker_helm = {
	id = "mirewalker_helm",
	name = "Mirewalker Hood",
	set = "mirewalker",
	slot = "helmet",
	rarity = "Uncommon",
	color = Color3.fromRGB(104, 96, 58),
	defense = 2,
	-- No recipe: Morra pays it for "A Skin for the Mire" (Quests.luau).
}

Armor.items.mirewalker_chest = {
	id = "mirewalker_chest",
	name = "Mirewalker Jerkin",
	set = "mirewalker",
	slot = "chest",
	rarity = "Uncommon",
	color = Color3.fromRGB(104, 96, 58),
	defense = 3,
	health = 2,
	recipe = { requiresLevel = 11, coins = 520, materials = { mire_hide = 6, fen_chitin = 3, bog_iron = 2 } },
}

Armor.items.mirewalker_legs = {
	id = "mirewalker_legs",
	name = "Mirewalker Waders",
	set = "mirewalker",
	slot = "legs",
	rarity = "Uncommon",
	color = Color3.fromRGB(104, 96, 58),
	defense = 2,
	health = 1,
	recipe = { requiresLevel = 9, coins = 380, materials = { mire_hide = 5, fen_chitin = 2, gator_scute = 2 } },
}

-- Frostmaw Reach (L15-21): rimewool under everfrost shell. Legs are
-- Halvard's stock (Shops.luau).
Armor.sets.rimebound = {
	id = "rimebound",
	name = "Rimebound",
	blurb = "Rimewool for the blood, everfrost for the blows. The reach stops biting first.",
	modelPrefix = "Rimebound",
	bonus = {
		name = "Hearthfrost",
		description = "Full set: +3 defense.",
		defense = 3,
	},
}

Armor.items.rimebound_helm = {
	id = "rimebound_helm",
	name = "Rimebound Cowl",
	set = "rimebound",
	slot = "helmet",
	rarity = "Rare",
	color = Color3.fromRGB(148, 194, 232),
	defense = 3,
	health = 1,
	recipe = { requiresLevel = 16, coins = 1100, materials = { rimewool = 6, everfrost_plate = 2, glacier_shard = 1 } },
}

Armor.items.rimebound_chest = {
	id = "rimebound_chest",
	name = "Rimebound Hauberk",
	set = "rimebound",
	slot = "chest",
	rarity = "Rare",
	color = Color3.fromRGB(148, 194, 232),
	defense = 5,
	health = 2,
	recipe = { requiresLevel = 19, coins = 1800, materials = { rimewool = 8, everfrost_plate = 4, glacier_shard = 2 } },
}

Armor.items.rimebound_legs = {
	id = "rimebound_legs",
	name = "Rimebound Greaves",
	set = "rimebound",
	slot = "legs",
	rarity = "Rare",
	color = Color3.fromRGB(148, 194, 232),
	defense = 4,
	health = 1,
	-- No recipe: Halvard sells the pair he made for a keel-hand who never
	-- came back off the sheet (halvards_cache).
}

-- Ashfall Caldera (L22-28): cinderscale mail on basaltweave. Chest is
-- Brakk's stock (Shops.luau).
Armor.sets.cindershell = {
	id = "cindershell",
	name = "Cindershell",
	blurb = "Cinderscale mail on a basaltweave backing. Walks through embers; picks fights on the way.",
	modelPrefix = "Cindershell",
	bonus = {
		name = "Emberwalk",
		description = "Full set: +5% damage.",
		damageBonus = 0.05,
	},
}

Armor.items.cindershell_helm = {
	id = "cindershell_helm",
	name = "Cindershell Casque",
	set = "cindershell",
	slot = "helmet",
	rarity = "Rare",
	color = Color3.fromRGB(214, 106, 44),
	defense = 5,
	health = 2,
	recipe = {
		requiresLevel = 23,
		coins = 2600,
		materials = { cinder_scale = 6, basalt_weave = 2, obsidian_shard = 2 },
	},
}

Armor.items.cindershell_chest = {
	id = "cindershell_chest",
	name = "Cindershell Cuirass",
	set = "cindershell",
	slot = "chest",
	rarity = "Rare",
	color = Color3.fromRGB(214, 106, 44),
	defense = 6,
	health = 4,
	-- No recipe: Brakk forged exactly one and priced it like he means to
	-- keep it (brakks_forge).
}

Armor.items.cindershell_legs = {
	id = "cindershell_legs",
	name = "Cindershell Greaves",
	set = "cindershell",
	slot = "legs",
	rarity = "Rare",
	color = Color3.fromRGB(214, 106, 44),
	defense = 5,
	health = 3,
	recipe = { requiresLevel = 26, coins = 3400, materials = { cinder_scale = 8, basalt_weave = 4, magma_core = 1 } },
}

-- Gloomtrench (L29-35): duskhide lined with abyss silk. Helm is Lumen's
-- quest reward.
Armor.sets.duskveil = {
	id = "duskveil",
	name = "Duskveil",
	blurb = "Duskhide lined with abyss silk. The dark reads it as one of its own.",
	modelPrefix = "Duskveil",
	bonus = {
		name = "One With the Dark",
		description = "Full set: +18 max health, +4% damage.",
		health = 18,
		damageBonus = 0.04,
	},
}

Armor.items.duskveil_helm = {
	id = "duskveil_helm",
	name = "Duskveil Cowl",
	set = "duskveil",
	slot = "helmet",
	rarity = "Epic",
	color = Color3.fromRGB(42, 40, 56),
	defense = 6,
	health = 4,
	-- No recipe: Lumen pays it for "A Veil Against the Dark" (Quests.luau).
}

Armor.items.duskveil_chest = {
	id = "duskveil_chest",
	name = "Duskveil Shroud",
	set = "duskveil",
	slot = "chest",
	rarity = "Epic",
	color = Color3.fromRGB(42, 40, 56),
	defense = 8,
	health = 6,
	recipe = { requiresLevel = 33, coins = 7200, materials = { duskhide = 8, abyss_silk = 4, lantern_gland = 2 } },
}

Armor.items.duskveil_legs = {
	id = "duskveil_legs",
	name = "Duskveil Leggings",
	set = "duskveil",
	slot = "legs",
	rarity = "Epic",
	color = Color3.fromRGB(42, 40, 56),
	defense = 7,
	health = 5,
	recipe = { requiresLevel = 30, coins = 5600, materials = { duskhide = 6, abyss_silk = 3, gloom_scale = 4 } },
}

return Armor
