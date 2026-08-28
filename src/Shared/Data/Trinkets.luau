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
--   rareLuck   - multiplies the rarity roll's luck (FishingService)
--   damageBonus - +X% weapon damage, melee and ranged (CombatService landHit)
--   lootBonus   - +X% material drops from kills (MaterialService.onKilled)
-- reelWindow stays unshipped (it needs the client/server minigame config
-- pair, like rod perks) - do not add rows using it before its consumer.

local Trinkets = {}

export type Trinket = {
	id: string,
	name: string,
	blurb: string,
	rarity: string,
	color: Color3?,
	recipe: { requiresLevel: number, coins: number, materials: { [string]: number } },
	perk: {
		name: string,
		description: string,
		coinBonus: number?,
		rareLuck: number?,
		damageBonus: number?,
		lootBonus: number?,
	},
}

-- The worn trinket's perk field for this player, or nil. THE lookup every
-- consumer uses - server-side reads of the server-set attribute.
function Trinkets.wornPerk(player: Player, field: string): number?
	local trinketId = player:GetAttribute("EquippedTrinketId")
	local trinket = trinketId and Trinkets.items[trinketId]
	local perk = trinket and trinket.perk
	return perk and perk[field]
end

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

Trinkets.items.moons_eye = {
	id = "moons_eye",
	name = "Moon's Eye",
	blurb = "A chitin ring around a nacre bead. Squint through it and the rare ones seem to squint back.",
	rarity = "Rare",
	color = Color3.fromRGB(196, 214, 236),
	recipe = { requiresLevel = 10, coins = 700, materials = { barnacle_chitin = 5, nacre = 3 } },
	perk = {
		name = "Squint of Fortune",
		description = "+20% luck on the rarity roll.",
		rareLuck = 0.2,
	},
}

Trinkets.items.fang_fetish = {
	id = "fang_fetish",
	name = "Fang Fetish",
	blurb = "Cursed bone filed to points and strung tight. It wants to be swung.",
	rarity = "Epic",
	color = Color3.fromRGB(214, 206, 188),
	recipe = { requiresLevel = 16, coins = 1200, materials = { cursed_bone = 5, barnacle_chitin = 4 } },
	perk = {
		name = "Bared Teeth",
		description = "+6% weapon damage.",
		damageBonus = 0.06,
	},
}

Trinkets.items.gutting_charm = {
	id = "gutting_charm",
	name = "Gutting Charm",
	blurb = "A volt-gland dried hard and lashed to a hook. Nothing goes to waste around it.",
	rarity = "Rare",
	color = Color3.fromRGB(170, 208, 130),
	recipe = { requiresLevel = 14, coins = 900, materials = { volt_gland = 4, barnacle_chitin = 4 } },
	perk = {
		name = "Waste Not",
		description = "+15% materials from kills.",
		lootBonus = 0.15,
	},
}

return Trinkets
