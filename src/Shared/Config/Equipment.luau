--!nonstrict
-- Equipment.luau
-- What can be in the player's hands, and how that choice is shared.
--
-- There are exactly two kinds: the equipped rod, or the equipped melee
-- weapon. "Weapon" covers bare fists too - the fists are the starter weapon
-- row in Weapons.luau, so a player who has crafted nothing still has a
-- weapon to raise. WHICH rod / weapon is a second choice, published
-- alongside the kind (the *_ATTRIBUTE names below), so "2" always means
-- "whatever weapon I've picked" the way "1" means "whatever rod I've picked".
--
-- The server (InventoryService) owns the choice and publishes it as an
-- attribute on the Player, which replicates to everyone: the owner's
-- viewmodel controllers watch it to decide what to draw, and late joiners
-- read it without a round trip.

local Equipment = {}

-- Attribute name on the Player instance for the loadout kind (rod/weapon).
Equipment.ATTRIBUTE = "Equipped"

-- Attribute naming *which* rod is equipped (its Rods id), published by
-- InventoryService so the client can tell owned-but-not-held from held. Not
-- "EquippedRod" - that's the NAME of the welded Model in the character
-- (RodService.EQUIPPED_NAME); keeping them distinct avoids the ambiguity.
Equipment.ROD_ATTRIBUTE = "EquippedRodId"

-- Same for the weapon (its Weapons id; "fists" until something is crafted).
-- The welded world Model is WeaponService.EQUIPPED_NAME ("EquippedWeapon").
Equipment.WEAPON_ATTRIBUTE = "EquippedWeaponId"

-- Which bait is selected (its Bait id, "" for none), published by BaitService.
-- Unlike the rod/weapon, this is NOT a hand "kind" - bait is spent per cast,
-- not held - so it is deliberately absent from Equipment.KINDS below.
Equipment.BAIT_ATTRIBUTE = "SelectedBaitId"

-- Which trinket is worn (its Trinkets id, unset until one is equipped).
-- Like bait, NOT a hand kind - a charm hangs round the neck, not in a fist -
-- so it too stays out of Equipment.KINDS. Published by InventoryService.
Equipment.TRINKET_ATTRIBUTE = "EquippedTrinketId"

-- The three worn armor slots (Shared/Data/Armor.luau owns the slot list and
-- these same names as Armor.ATTRIBUTES - the armor consumers read via that
-- module). Like bait and the trinket: worn, not held; no hand kind.
Equipment.HELMET_ATTRIBUTE = "EquippedHelmetId"
Equipment.CHEST_ATTRIBUTE = "EquippedChestId"
Equipment.LEGS_ATTRIBUTE = "EquippedLegsId"

Equipment.ROD = "rod"
Equipment.WEAPON = "weapon"

Equipment.KINDS = {
	[Equipment.ROD] = true,
	[Equipment.WEAPON] = true,
}

-- What a fresh player holds.
Equipment.DEFAULT = Equipment.ROD

return Equipment
