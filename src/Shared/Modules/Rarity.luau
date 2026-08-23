--!nonstrict
-- Rarity.luau
-- The one place the rarity tiers, their order and their colours live, so
-- rods, weapons, creatures and every UI that shows rarity (the inventory /
-- crafting cards, the catch pop) read the same names and paint the same
-- colours instead of each defining its own table.
--
-- Common is a muted grey on purpose - a "Common" tag should read as plain
-- against the dark panels, letting the rarer tiers pop.

local Rarity = {}

Rarity.ORDER = { "Common", "Uncommon", "Rare", "Epic", "Legendary" }

Rarity.COLOR = {
	Common = Color3.fromRGB(178, 186, 198),
	Uncommon = Color3.fromRGB(120, 220, 130),
	Rare = Color3.fromRGB(96, 178, 232),
	Epic = Color3.fromRGB(190, 120, 240),
	Legendary = Color3.fromRGB(255, 200, 80),
}

-- The colour for a rarity, defaulting to Common's grey for an unknown value.
function Rarity.colorOf(rarity: string?): Color3
	return (rarity and Rarity.COLOR[rarity]) or Rarity.COLOR.Common
end

-- Tier index (1 = Common), or 1 if unknown. Handy for sorting / comparisons.
function Rarity.indexOf(rarity: string?): number
	if rarity then
		for i, name in Rarity.ORDER do
			if name == rarity then
				return i
			end
		end
	end
	return 1
end

return Rarity
