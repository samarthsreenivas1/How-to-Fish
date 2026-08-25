--!nonstrict
-- Materials.luau
-- Crafting materials, as rows - same id-keyed shape as Rods.luau and
-- Creatures.luau. A material is just an id the player owns a count of;
-- MaterialService tracks the counts, the crafting recipes (Slice 2) spend
-- them, and nothing here needs to know how it's earned.
--
-- Two tiers, by how they're earned (see MaterialService):
--   basic - pulled up on every cast, the debris your line drags in.
--   rare  - dropped only when you kill the surfaced catch, better fish
--           dropping better mats.
-- This is the answer to "a fish dropping rod-wood is weird": the wood/kelp
-- come from fishing itself, the fish-derived mats (scales) and treasure
-- (pearls) come from actually landing and fighting the catch.

local Materials = {}

-- `rarity` is the display tier (Shared/Modules/Rarity - the inventory card's
-- strip and label), separate from `tier`, which is the EARN path. `icon` is
-- the image the inventory card and detail preview show - an
-- "rbxassetid://..." once the art is uploaded; empty shows the blank
-- placeholder. `color` is no longer drawn on the inventory cards (the icon
-- replaces it); it still tints the crafting recipe rows and the "+N" reward
-- pop.
export type Material = {
	id: string,
	name: string,
	description: string,
	tier: string, -- "basic" | "rare" - how it's earned
	rarity: string, -- Common | Uncommon | Rare | Epic | Legendary - how it's shown
	icon: string, -- image asset id for the inventory; "" until art exists
	color: Color3, -- recipe-row dot + reward-pop text colour
}

Materials.items = {} :: { [string]: Material }

Materials.items.driftwood = {
	id = "driftwood",
	name = "Driftwood",
	description = "Sea-worn wood snagged off the line. The bones of any rod.",
	tier = "basic",
	rarity = "Common",
	icon = "rbxassetid://113312461348185", -- assets/icons/driftwood.png
	color = Color3.fromRGB(168, 128, 84),
}

Materials.items.kelp_fiber = {
	id = "kelp_fiber",
	name = "Kelp Fiber",
	description = "Tough strands of kelp, twisted into fishing line.",
	tier = "basic",
	rarity = "Common",
	icon = "rbxassetid://125486906161378", -- assets/icons/kelp_fiber.png
	color = Color3.fromRGB(94, 156, 92),
}

Materials.items.fish_scale = {
	id = "fish_scale",
	name = "Fish Scale",
	description = "A broad, tough scale off a landed catch. Rarer fish, better scales.",
	tier = "rare",
	rarity = "Uncommon",
	icon = "rbxassetid://73373543908761", -- assets/icons/fish_scale.png
	color = Color3.fromRGB(150, 186, 210),
}

Materials.items.pearl = {
	id = "pearl",
	name = "Pearl",
	description = "A lustrous pearl, only the biggest catches give one up.",
	tier = "rare",
	rarity = "Rare",
	icon = "rbxassetid://115745804697809", -- assets/icons/pearl.png
	color = Color3.fromRGB(238, 232, 240),
}

-- Dropped by the hostile things dragged up from the deep (see Creatures.luau
-- `drops`), not by fish. Rare-tier, for high-end gear once its recipes exist.
Materials.items.barnacle_chitin = {
	id = "barnacle_chitin",
	name = "Barnacle Chitin",
	description = "Crusted shell plating prised off something with claws. Tough as armour.",
	tier = "rare",
	rarity = "Rare",
	icon = "rbxassetid://101757389418016", -- assets/icons/barnacle_chitin.png
	color = Color3.fromRGB(126, 150, 150),
}

Materials.items.cursed_bone = {
	id = "cursed_bone",
	name = "Cursed Bone",
	description = "Brine-blackened bone from the drowned. It never quite dries.",
	tier = "rare",
	rarity = "Epic",
	icon = "rbxassetid://71696055383797", -- assets/icons/cursed_bone.png
	color = Color3.fromRGB(120, 116, 96),
}

-- Signature drops off the hostile creatures (Creatures.luau `drops`), for the
-- rods/weapons/bait that consume them. All rare-tier (earned by killing the
-- catch, not pulled up on a plain cast). THINNED 2026-08-25
-- (docs/revamp-plan.md): each island keeps ~4 signature materials; the six
-- one-off per-enemy drops (skitterfin, brine_gland, gild_shell, moonjelly,
-- tidebomb_spine, lurker_hide) were cut and their creatures' drops remapped
-- onto the survivors. Boss hearts are no longer materials either - a heart is
-- the Heart_<bossId> attribute BossService sets, owned forever, never spent.

Materials.items.nacre = {
	id = "nacre",
	name = "Nacre",
	description = "Iridescent shell lining prised from a Pearl Mimic. Harder than it looks.",
	tier = "rare",
	rarity = "Rare",
	icon = "",
	color = Color3.fromRGB(226, 232, 240),
}

Materials.items.volt_gland = {
	id = "volt_gland",
	name = "Volt Gland",
	description = "A Voltray's electric organ, still crackling long after the ray is gone.",
	tier = "rare",
	rarity = "Epic",
	icon = "",
	color = Color3.fromRGB(120, 220, 255),
}

-- Volcano drops (2026-08-23). The lava island's own material chain, dropped by
-- the volcano fish and hostiles (Creatures.luau `waters = "volcano"` rows). All
-- rare-tier; they feed the volcano rods/weapons/bait recipes.

Materials.items.ember = {
	id = "ember",
	name = "Ember",
	description = "A coal that never cools, plucked from a lava-born catch. Warm to the touch, always.",
	tier = "rare",
	rarity = "Uncommon",
	icon = "",
	color = Color3.fromRGB(240, 132, 52),
}

Materials.items.sulfur = {
	id = "sulfur",
	name = "Sulfur",
	description = "Bitter yellow crust off a fumarole-dweller. It stings the nose and the eyes.",
	tier = "rare",
	rarity = "Uncommon",
	icon = "",
	color = Color3.fromRGB(226, 206, 88),
}

Materials.items.obsidian_shard = {
	id = "obsidian_shard",
	name = "Obsidian Shard",
	description = "Volcanic glass cooled black and razor-edged. Splits light and skin alike.",
	tier = "rare",
	rarity = "Rare",
	icon = "",
	color = Color3.fromRGB(48, 44, 60),
}

Materials.items.magma_core = {
	id = "magma_core",
	name = "Magma Core",
	description = "A molten heart-stone still glowing from the deep vent. It hums with heat.",
	tier = "rare",
	rarity = "Epic",
	icon = "",
	color = Color3.fromRGB(244, 96, 40),
}

-- Blackmire Fen drops (revamp Session 2). The swamp's signature chain,
-- dropped by the `waters = "swamp"` rows; they feed the fen's rods / weapons
-- / bait recipes. U / U / R / E, per the revamp's per-island ladder.

Materials.items.bog_iron = {
	id = "bog_iron",
	name = "Bog Iron",
	description = "A lump of rust-red ore pulled from the peat. The fen has been eating shipwrecks for centuries.",
	tier = "rare",
	rarity = "Uncommon",
	icon = "",
	color = Color3.fromRGB(164, 98, 62),
}

Materials.items.gator_scute = {
	id = "gator_scute",
	name = "Gator Scute",
	description = "A ridged armour plate off something that owns its stretch of the mire. Hard as old oak.",
	tier = "rare",
	rarity = "Uncommon",
	icon = "",
	color = Color3.fromRGB(94, 116, 72),
}

Materials.items.wisp_light = {
	id = "wisp_light",
	name = "Wisp Light",
	description = "A cold flame in a jar of fen-glass. It flickers toward whatever you've lost.",
	tier = "rare",
	rarity = "Rare",
	icon = "",
	color = Color3.fromRGB(150, 235, 200),
}

Materials.items.fen_venom = {
	id = "fen_venom",
	name = "Fen Venom",
	description = "Milky venom drawn from the fen's worst. It never quite stops moving in the vial.",
	tier = "rare",
	rarity = "Epic",
	icon = "",
	color = Color3.fromRGB(178, 210, 90),
}

-- Stable display order for the HUD / crafting list (table iteration order
-- isn't guaranteed). Basic first, then rare, then the creature drops by island.
Materials.order = {
	"driftwood",
	"kelp_fiber",
	"fish_scale",
	"pearl",
	"barnacle_chitin",
	"cursed_bone",
	"nacre",
	"volt_gland",
	"bog_iron",
	"gator_scute",
	"wisp_light",
	"fen_venom",
	"ember",
	"sulfur",
	"obsidian_shard",
	"magma_core",
}

return Materials
