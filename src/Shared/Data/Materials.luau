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

-- ============================================================ Frostmaw Reach

Materials.items.glacier_shard = {
	id = "glacier_shard",
	name = "Glacier Shard",
	description = "A splinter of the reach's blue ice. It never quite melts.",
	tier = "rare",
	rarity = "Uncommon",
	icon = "",
	color = Color3.fromRGB(150, 196, 224),
}

Materials.items.rime_pelt = {
	id = "rime_pelt",
	name = "Rime Pelt",
	description = "A frost-stiffened hide off something the cold couldn't kill. You managed.",
	tier = "rare",
	rarity = "Uncommon",
	icon = "",
	color = Color3.fromRGB(214, 224, 234),
}

Materials.items.everice = {
	id = "everice",
	name = "Everice",
	description = "Ice older than the reach itself. It stays frozen in a forge.",
	tier = "rare",
	rarity = "Rare",
	icon = "",
	color = Color3.fromRGB(120, 190, 255),
}

Materials.items.aurora_essence = {
	id = "aurora_essence",
	name = "Aurora Essence",
	description = "A bottled ribbon of the southern lights. It moves when nobody watches.",
	tier = "rare",
	rarity = "Epic",
	icon = "",
	color = Color3.fromRGB(150, 230, 200),
}

-- ============================================================ Gloomtrench

Materials.items.gloom_scale = {
	id = "gloom_scale",
	name = "Gloom Scale",
	description = "A scale that drinks the light around it. Hold it and your hand goes dim.",
	tier = "rare",
	rarity = "Uncommon",
	icon = "",
	color = Color3.fromRGB(90, 82, 110),
}

Materials.items.trench_chitin = {
	id = "trench_chitin",
	name = "Trench Chitin",
	description = "Shell plate forged by the crush of the deep. Pressure-proof, and then some.",
	tier = "rare",
	rarity = "Uncommon",
	icon = "",
	color = Color3.fromRGB(100, 110, 128),
}

Materials.items.lantern_gland = {
	id = "lantern_gland",
	name = "Lantern Gland",
	description = "The light off a thing that lied with it. Still warm, still lying.",
	tier = "rare",
	rarity = "Rare",
	icon = "",
	color = Color3.fromRGB(255, 226, 130),
}

Materials.items.abyss_ichor = {
	id = "abyss_ichor",
	name = "Abyss Ichor",
	description = "What passes for blood at the bottom of everything. It runs uphill.",
	tier = "rare",
	rarity = "Epic",
	icon = "",
	color = Color3.fromRGB(170, 120, 255),
}

-- ============================================================ Wreckwater

Materials.items.ghost_plank = {
	id = "ghost_plank",
	name = "Ghost Plank",
	description = "Hull timber off the drowned fleet. It creaks in a swell it still remembers.",
	tier = "rare",
	rarity = "Uncommon",
	icon = "",
	color = Color3.fromRGB(130, 144, 132),
}

Materials.items.tarnished_doubloon = {
	id = "tarnished_doubloon",
	name = "Tarnished Doubloon",
	description = "The fleet's pay, black with the sea. Still spends, somehow.",
	tier = "rare",
	rarity = "Uncommon",
	icon = "",
	color = Color3.fromRGB(180, 150, 80),
}

Materials.items.spectral_sailcloth = {
	id = "spectral_sailcloth",
	name = "Spectral Sailcloth",
	description = "Canvas that still holds a wind nobody living has felt.",
	tier = "rare",
	rarity = "Rare",
	icon = "",
	color = Color3.fromRGB(220, 250, 236),
}

Materials.items.wraith_essence = {
	id = "wraith_essence",
	name = "Wraith Essence",
	description = "What's left of a sailor who won't leave. Cold to the touch, and it watches.",
	tier = "rare",
	rarity = "Epic",
	icon = "",
	color = Color3.fromRGB(160, 255, 210),
}

-- ============================================================ Materials

Materials.items.storm_glass = {
	id = "storm_glass",
	name = "Storm Glass",
	description = "Sea-glass fused by lightning strikes. It hums before thunder.",
	tier = "rare",
	rarity = "Uncommon",
	icon = "",
	color = Color3.fromRGB(140, 190, 230),
}

Materials.items.riptide_scale = {
	id = "riptide_scale",
	name = "Riptide Scale",
	description = "A scale off something that swims AGAINST the maelstrom, for fun.",
	tier = "rare",
	rarity = "Uncommon",
	icon = "",
	color = Color3.fromRGB(90, 150, 190),
}

Materials.items.thunder_pearl = {
	id = "thunder_pearl",
	name = "Thunder Pearl",
	description = "A pearl grown around a trapped spark. It jumps in your hand.",
	tier = "rare",
	rarity = "Rare",
	icon = "",
	color = Color3.fromRGB(220, 230, 255),
}

Materials.items.maelstrom_core = {
	id = "maelstrom_core",
	name = "Maelstrom Core",
	description = "A knot of the storm itself, still turning. Do not stop watching it.",
	tier = "rare",
	rarity = "Epic",
	icon = "",
	color = Color3.fromRGB(90, 130, 255),
}

-- Stable display order for the HUD / crafting list (table iteration order
-- isn't guaranteed). Basic first, then rare, then the creature drops by island.
-- ============================================================ armor stock (2026-08-28)
-- The armor system's raw materials (Shared/Data/Armor.luau recipes): hides,
-- weaves and plates skinned off the islands' hostiles. Two per band, an
-- everyday piece-stock (Uncommon) and the set's structural stock (Rare+),
-- so an armor recipe reads "farm these two creatures on this island".

Materials.items.tidehide = {
	id = "tidehide",
	name = "Tidehide",
	description = "Salt-cured skin off the cove's bigger catches. Tans into a leather that shrugs off spray and worse.",
	tier = "rare",
	rarity = "Uncommon",
	icon = "",
	color = Color3.fromRGB(178, 142, 96),
}

Materials.items.brine_sinew = {
	id = "brine_sinew",
	name = "Brine Sinew",
	description = "Cord stripped from the drowned. It never dried out, and it never will - the stitch that holds armor together.",
	tier = "rare",
	rarity = "Rare",
	icon = "",
	color = Color3.fromRGB(120, 144, 132),
}

Materials.items.mire_hide = {
	id = "mire_hide",
	name = "Mirehide",
	description = "Gator leather with the peat still in it. Waterproof the way only the fen knows how.",
	tier = "rare",
	rarity = "Uncommon",
	icon = "",
	color = Color3.fromRGB(104, 96, 58),
}

Materials.items.fen_chitin = {
	id = "fen_chitin",
	name = "Fen Chitin",
	description = "Segmented shell plate off the marsh's armoured things. Light, springy, and it does not rot.",
	tier = "rare",
	rarity = "Rare",
	icon = "",
	color = Color3.fromRGB(84, 110, 70),
}

Materials.items.rimewool = {
	id = "rimewool",
	name = "Rimewool",
	description = "Underfur combed from the reach's pups and skuas, frost and all. Warm enough to sleep on the ice sheet.",
	tier = "rare",
	rarity = "Uncommon",
	icon = "",
	color = Color3.fromRGB(224, 234, 242),
}

Materials.items.everfrost_plate = {
	id = "everfrost_plate",
	name = "Everfrost Plate",
	description = "A slab of ice off something that fought back, and it has not begun to melt. Armor-smiths pray it never does.",
	tier = "rare",
	rarity = "Rare",
	icon = "",
	color = Color3.fromRGB(148, 194, 232),
}

Materials.items.cinder_scale = {
	id = "cinder_scale",
	name = "Cinderscale",
	description = "A scale that cooled with the fire still inside. Warm in the hand; a mail shirt of them walks through embers.",
	tier = "rare",
	rarity = "Uncommon",
	icon = "",
	color = Color3.fromRGB(214, 106, 44),
}

Materials.items.basalt_weave = {
	id = "basalt_weave",
	name = "Basaltweave",
	description = "Stone fibre teased off the caldera's golems and shardbacks, woven like cloth. Cloth that stops a blade.",
	tier = "rare",
	rarity = "Rare",
	icon = "",
	color = Color3.fromRGB(66, 68, 82),
}

Materials.items.duskhide = {
	id = "duskhide",
	name = "Duskhide",
	description = "Skin from the trench's stalkers, black past black. Light falls into it and does not come out.",
	tier = "rare",
	rarity = "Rare",
	icon = "",
	color = Color3.fromRGB(42, 40, 56),
}

Materials.items.abyss_silk = {
	id = "abyss_silk",
	name = "Abyss Silk",
	description = "Spun by nothing anyone has seen alive. Threads of the dark itself; armor lined with it weighs nothing at all.",
	tier = "rare",
	rarity = "Epic",
	icon = "",
	color = Color3.fromRGB(96, 74, 140),
}

-- ============================================================ hermit-saga keys
--
-- The three quest KEY ITEMS (2026-08-29). Each drops guaranteed off one
-- hermit saga's miniboss (Creatures.luau `drops`, a { 1, 1 } band) and is
-- spent by exactly one rod recipe in Rods.luau. They exist to GATE that
-- recipe and nothing else: no other recipe takes them, no shop sells them,
-- and there is no second way to get one. Legendary-tier display so the
-- inventory card reads as the trophy it is.

Materials.items.bell_clapper = {
	id = "bell_clapper",
	name = "Bell Clapper",
	description = "The tongue of a chapel bell, cut from the gullet that swallowed it. Still warm. Still, faintly, ringing.",
	tier = "rare",
	rarity = "Legendary",
	icon = "",
	color = Color3.fromRGB(150, 220, 186),
}

Materials.items.whetstone_heart = {
	id = "whetstone_heart",
	name = "Whetstone Heart",
	description = "A grey stone worn smooth in the eel's belly by everything it ever stole. Draw a blade down it and the blade thanks you.",
	tier = "rare",
	rarity = "Legendary",
	icon = "",
	color = Color3.fromRGB(150, 172, 186),
}

Materials.items.unburnt_wick = {
	id = "unburnt_wick",
	name = "Unburnt Wick",
	description = "Pulled from the moth's mouth, where it had been burning for years without ever going shorter. The Lampwright wants it back.",
	tier = "rare",
	rarity = "Legendary",
	icon = "",
	color = Color3.fromRGB(255, 214, 120),
}

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
	"glacier_shard",
	"rime_pelt",
	"everice",
	"aurora_essence",
	"ember",
	"sulfur",
	"obsidian_shard",
	"magma_core",
	"gloom_scale",
	"trench_chitin",
	"lantern_gland",
	"abyss_ichor",
	"ghost_plank",
	"tarnished_doubloon",
	"spectral_sailcloth",
	"wraith_essence",
	"storm_glass",
	"riptide_scale",
	"thunder_pearl",
	"maelstrom_core",
	-- armor stock (2026-08-28)
	"tidehide",
	"brine_sinew",
	"mire_hide",
	"fen_chitin",
	"rimewool",
	"everfrost_plate",
	"cinder_scale",
	"basalt_weave",
	"duskhide",
	"abyss_silk",
	-- hermit-saga keys (2026-08-29)
	"whetstone_heart",
	"unburnt_wick",
	"bell_clapper",
}

return Materials
