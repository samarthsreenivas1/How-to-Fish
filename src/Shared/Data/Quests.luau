--!nonstrict
-- Quests.luau
-- Every quest, as data. A quest belongs to an NPC (`giver` - it appears in
-- their dialog when offerable), carries a list of typed OBJECTIVES that must
-- ALL complete, and pays `rewards` at turn-in. QuestService owns all state
-- and progress; this file is pure rows.
--
-- Objective types (the matcher in QuestService):
--   { type = "catch", count = n, species = id?, rarity = name?, waters = key? }
--       - a resolved cast's creature. Filters are AND; absent = any.
--   { type = "kill", count = n, species = id?, rarity = name? }        (A4)
--   { type = "craft", itemId = id }                                    (A4)
--   { type = "deliver", materials = { [matId] = n } }                  (A4)
--       - checked AND SPENT at turn-in, not tracked live.
--   { type = "visit", island = id }                                    (A4)
-- RULE: an event ticks EVERY matching objective on every active quest - a
-- swamp Rare catch advances both a "5 swamp fish" and a "3 Rare fish" quest.
--
-- `prereq` (quest id) + `requiresLevel` gate when a quest is OFFERED;
-- `repeatable = "daily"` re-offers after a UTC day (A5). Rewards may carry
-- coins, xp, materials = {[matId]=n}, bait = {[baitId]=n}.

local Quests = {}

export type Objective = {
	type: string,
	count: number?,
	species: string?,
	rarity: string?,
	waters: string?,
	itemId: string?,
	materials: { [string]: number }?,
	island: string?,
}

export type Quest = {
	id: string,
	name: string,
	giver: string, -- Npcs.luau id
	blurb: string, -- the pitch, shown on the offer pane
	objectives: { Objective },
	prereq: string?,
	requiresLevel: number?,
	repeatable: (boolean | string)?,
	rewards: {
		coins: number?,
		xp: number?,
		materials: { [string]: number }?,
		bait: { [string]: number }?,
	},
}

Quests.items = {} :: { [string]: Quest }

-- Old Maren's opener: the tutorial-shaped first errand. Any five catches -
-- every catch fights back now, so this teaches the whole loop.
Quests.items.marens_wager = {
	id = "marens_wager",
	name = "Maren's Wager",
	giver = "old_maren",
	blurb = "Five catches, landed and put down. Prove the cove hasn't gotten the better of you, and I'll make it worth the bruises.",
	objectives = {
		{ type = "catch", count = 5 },
	},
	rewards = { coins = 150, xp = 120 },
}

-- The follow-up: the cove's crabs have been at her drying racks.
Quests.items.teeth_of_the_cove = {
	id = "teeth_of_the_cove",
	name = "Teeth of the Cove",
	giver = "old_maren",
	blurb = "The snapjaws have chewed through two of my racks this week. Thin them out - and while you're wading, land me something with a bit of shine to it.",
	prereq = "marens_wager",
	objectives = {
		{ type = "kill", count = 4, species = "snapjaw_crab" },
		{ type = "catch", count = 2, rarity = "Rare" },
	},
	rewards = { coins = 320, xp = 260, materials = { driftwood = 4 } },
}

-- The chain's capstone: she points you at the wider world. Craft (the
-- bamboo rod is the first recipe anyone can reach), bring her kelp for her
-- racks, and set foot on the fen - every objective type is live from here.
Quests.items.the_wider_water = {
	id = "the_wider_water",
	name = "The Wider Water",
	giver = "old_maren",
	blurb = "You've outgrown my little cove, love. Lash yourself a proper rod, bring me kelp for the racks before you go - and when you stand in the Blackmire mud, think of old Maren.",
	prereq = "teeth_of_the_cove",
	requiresLevel = 5,
	objectives = {
		{ type = "craft", itemId = "bamboo_rod" },
		{ type = "deliver", materials = { kelp_fiber = 6 } },
		{ type = "visit", island = "swamp" },
	},
	rewards = { coins = 500, xp = 420 },
}

-- ============================================================ the fen (Morra)
Quests.items.leech_tithe = {
	id = "leech_tithe",
	name = "Leech Tithe",
	giver = "morra",
	blurb = "The murk is fat with leeches and thin with everything else. Redress the balance.",
	objectives = { { type = "kill", count = 5, species = "mire_leech" } },
	rewards = { coins = 260, xp = 220 },
}
Quests.items.murk_harvest = {
	id = "murk_harvest",
	name = "Murk Harvest",
	giver = "morra",
	blurb = "Six things pulled living from the fen's own water. The fen will notice. That's rather the point.",
	prereq = "leech_tithe",
	objectives = { { type = "catch", count = 6, waters = "swamp" } },
	rewards = { coins = 380, xp = 300, materials = { fen_venom = 2 } },
}

-- ============================================================ the Reach (Halvard)
Quests.items.pups_and_lines = {
	id = "pups_and_lines",
	name = "Pups and Lines",
	giver = "halvard",
	blurb = "Frostbite pups. Sweet-looking. They eat my catch lines whole. Three fewer would warm my week.",
	objectives = { { type = "kill", count = 3, species = "frostbite_pup" } },
	rewards = { coins = 520, xp = 420 },
}
Quests.items.under_the_sheet = {
	id = "under_the_sheet",
	name = "Under the Sheet",
	giver = "halvard",
	blurb = "Five from the holes, landed clean. The sheet gives nothing to the timid.",
	prereq = "pups_and_lines",
	objectives = { { type = "catch", count = 5, waters = "ice" } },
	rewards = { coins = 700, xp = 560, materials = { everice = 2 } },
}

-- ============================================================ the Caldera (Brakk)
Quests.items.the_sulfur_toll = {
	id = "the_sulfur_toll",
	name = "The Sulfur Toll",
	giver = "brakk",
	blurb = "The forge eats sulfur and I'm short. Bring four measures and we'll call the smoke between us settled.",
	objectives = { { type = "deliver", materials = { sulfur = 4 } } },
	rewards = { coins = 900, xp = 640 },
}
Quests.items.lake_of_fire = {
	id = "lake_of_fire",
	name = "Lake of Fire",
	giver = "brakk",
	blurb = "Five out of the melt. If your line survives the ponds, you're worth arming.",
	prereq = "the_sulfur_toll",
	objectives = { { type = "catch", count = 5, waters = "volcano" } },
	rewards = { coins = 1200, xp = 800, materials = { ember = 3 } },
}

-- ============================================================ the Trench (Lumen)
Quests.items.what_the_dark_eats = {
	id = "what_the_dark_eats",
	name = "What the Dark Eats",
	giver = "lumen",
	blurb = "Gulpers circle the lamp at slack tide. Thin them before they learn to swallow light whole.",
	objectives = { { type = "kill", count = 3, species = "gulper_eel" } },
	rewards = { coins = 1600, xp = 1000 },
}
Quests.items.gullet_census = {
	id = "gullet_census",
	name = "Gullet Census",
	giver = "lumen",
	blurb = "Five specimens from the black water, for the log. The log must be FED, you understand. Kept. Kept-fed.",
	prereq = "what_the_dark_eats",
	objectives = { { type = "catch", count = 5, waters = "gloom" } },
	rewards = { coins = 2000, xp = 1300, materials = { lantern_gland = 2 } },
}

-- ============================================================ the Bay (Hollow)
Quests.items.ledger_of_teeth = {
	id = "ledger_of_teeth",
	name = "Ledger of Teeth",
	giver = "hollow",
	blurb = "Cannonball crabs, eating the fleet's stores. The book says four must answer for it. The book is never wrong.",
	objectives = { { type = "kill", count = 4, species = "cannonball_crab" } },
	rewards = { coins = 2600, xp = 1600 },
}

-- ============================================================ dailies
-- repeatable = "daily": offered again each new UTC day (QuestService gates
-- the re-offer; the reward is the login habit, priced under a chain quest).
Quests.items.the_daily_haul = {
	id = "the_daily_haul",
	name = "The Daily Haul",
	giver = "old_maren",
	blurb = "Same as every day, love: eight in the basket. The cove doesn't feed itself.",
	repeatable = "daily",
	objectives = { { type = "catch", count = 8 } },
	rewards = { coins = 220, xp = 180 },
}
Quests.items.salvage_rights = {
	id = "salvage_rights",
	name = "Salvage Rights",
	giver = "hollow",
	blurb = "Standing contract: six entries struck from the ledger, any name. Renewed daily. The fleet is patient; the book is not.",
	repeatable = "daily",
	objectives = { { type = "kill", count = 6 } },
	rewards = { coins = 800, xp = 520 },
}

return Quests
