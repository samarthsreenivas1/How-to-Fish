--!nonstrict
-- Trinkets.luau
-- Charms worn alongside the rod and weapon: one trinket slot (the
-- EquippedTrinketId attribute), small passive perks, recipes that
-- deliberately SINK the thin materials (nacre / barnacle_chitin /
-- volt_gland / cursed_bone appear in only 3-4 recipes elsewhere).
--
-- The perk rule is the project's strict one: ONE effect field, read in
-- exactly ONE place - and a field only exists once its consumer is live
-- (the lootLuck lesson: never advertise a dead effect). Live today:
--   coinBonus - +X% coins from KILLS (ProgressionService.onKilled).
-- rareLuck / damageBonus / lootBonus arrive WITH their consumers in a
-- later slice; do not add rows using them before then.

local Trinkets = {}

export type Trinket = {
	id: string,
	name: string,
	blurb: string,
	rarity: string,
	color: Color3?,
	recipe: { requiresLevel: number, coins: number, materials: { [string]: number } },
	perk: { name: string, description: string, coinBonus: number? },
}

Trinkets.items = {} :: { [string]: Trinket }

Trinkets.items.pearl_locket = {
	id = "pearl_locket",
	name = "Pearl Locket",
	blurb = "A cove-pearl set in scavenged shell. Merchants soften at the sight of it.",
	rarity = "Rare",
	color = Color3.fromRGB(238, 232, 244),
	recipe = { requiresLevel = 6, coins = 350, materials = { nacre = 6, barnacle_chitin = 3 } },
	perk = {
		name = "Tidewealth",
		description = "+8% coins from kills.",
		coinBonus = 0.08,
	},
}

Trinkets.items.wardens_doubloon = {
	id = "wardens_doubloon",
	name = "Warden's Doubloon",
	blurb = "A drowned paymaster's coin, strung on gut. Old debts keep finding their way back to whoever wears it.",
	rarity = "Epic",
	color = Color3.fromRGB(222, 186, 92),
	recipe = { requiresLevel = 20, coins = 1600, materials = { cursed_bone = 4, volt_gland = 3, nacre = 4 } },
	perk = {
		name = "Old Debts",
		description = "+15% coins from kills.",
		coinBonus = 0.15,
	},
}

return Trinkets
