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
	-- The cowl is gear for the journey she just talked you into.
	rewards = { coins = 500, xp = 420, items = { "tideward_helm" } },
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
Quests.items.a_skin_for_the_mire = {
	id = "a_skin_for_the_mire",
	name = "A Skin for the Mire",
	giver = "morra",
	blurb = "Bring me gator leather worth the name and I'll cut you a hood the bog can't tell from itself.",
	prereq = "murk_harvest",
	requiresLevel = 9,
	objectives = {
		{ type = "catch", count = 6, waters = "swamp" },
		{ type = "deliver", materials = { mire_hide = 3 } },
	},
	rewards = { coins = 420, xp = 340, items = { "mirewalker_helm" } },
}

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
Quests.items.a_veil_against_the_dark = {
	id = "a_veil_against_the_dark",
	name = "A Veil Against the Dark",
	giver = "lumen",
	blurb = "The trench takes the ones it can see. Bring me duskhide and it will stop seeing you.",
	prereq = "what_the_dark_eats",
	requiresLevel = 30,
	objectives = {
		{ type = "catch", count = 8, waters = "gloom" },
		{ type = "deliver", materials = { duskhide = 3 } },
	},
	rewards = { coins = 2400, xp = 1700, items = { "duskveil_helm" } },
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
	rewards = { coins = 2600, xp = 1600, items = { "corsairs_rest_helm" } },
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

-- ============================================================ the islet quests
-- One errand each for the six unclaimed islets, and three multi-chapter sagas
-- for the hermits: meet them, kill the thing that took what they lost, bring
-- it back, and they build you the rod they have been meaning to build. The
-- rods are the point and every one of them makes the taking easier - which is
-- the whole story, said by nobody.
--
-- NOTE ON `waters`, corrected 2026-08-30 after reading the code instead of
-- reasoning about it. An islet sits in the OPEN SEA, and a creature `waters`
-- roster ("wreck", "volcano"...) is that ISLAND's interior water, so a roster
-- name on an islet errand does send the player back across the map. But the
-- rest of what was written here was WRONG: `waters = "ocean"` works, and is
-- the right filter for these. FishingService normalises a row with no
-- `waters` to World.WATERS_OCEAN, World.WATERS_BY_PART maps the ocean part to
-- "ocean", and a finished cast reports that string to QuestService - so an
-- open-sea catch matches `waters = "ocean"` exactly. Without it these errands
-- are completable by fishing the fen, which makes every one of them a lie
-- about where it is set.
--
-- KILL objectives are the opposite case and must NEVER carry `waters`:
-- QuestService.notify("kill", ...) sends only { player, species, rarity }, so
-- `objective.waters` compares against nil and the objective can never
-- complete. That asymmetry is invisible at the call site and is why
-- `struck_twice` below filters by nothing.

Quests.items.what_the_bell_brings = {
	id = "what_the_bell_brings",
	name = "What the Bell Brings",
	giver = "nettle",
	blurb = "The noise carries. Things come up to see what it is, and some of them come ashore. Four of them, and I'll not ask which.",
	requiresLevel = 10,
	objectives = { { type = "kill", count = 4, species = "drowned_deckhand" } },
	rewards = { coins = 500, xp = 420 },
}

Quests.items.the_parliament = {
	id = "the_parliament",
	name = "The Parliament",
	giver = "pip",
	blurb = "They've voted on me and it went badly. Thin the loudest five and they'll go back to arguing among themselves.",
	requiresLevel = 16,
	objectives = { { type = "kill", count = 5, species = "bog_gull" } },
	rewards = { coins = 900, xp = 700, materials = { fish_scale = 4 } },
}

Quests.items.what_bites_in_boiling_water = {
	id = "what_bites_in_boiling_water",
	name = "What Bites in Boiling Water",
	giver = "cinder",
	blurb = "Anything worth catching out here is already half-cooked and furious about it. Six of the good ones.",
	requiresLevel = 22,
	objectives = { { type = "catch", count = 6, rarity = "Uncommon", waters = "ocean" } },
	rewards = { coins = 1300, xp = 1000 },
}

Quests.items.the_taut_chain = {
	id = "the_taut_chain",
	name = "The Taut Chain",
	giver = "coil",
	blurb = "I'm not hauling on it and neither are you. Fish the reef a while - whatever is on the end has been patient this long.",
	requiresLevel = 34,
	objectives = { { type = "catch", count = 6, waters = "ocean" } },
	rewards = { coins = 2000, xp = 1500 },
}

Quests.items.the_long_way_round = {
	id = "the_long_way_round",
	name = "The Long Way Round",
	giver = "ferryman",
	blurb = "I trade with sailors, not with tourists. Show me you've made the crossings and my counter is open.",
	requiresLevel = 20,
	objectives = {
		{ type = "visit", island = "swamp" },
		{ type = "visit", island = "ice" },
	},
	rewards = { coins = 1200, xp = 1000 },
}

Quests.items.struck_twice = {
	id = "struck_twice",
	name = "Struck Twice",
	giver = "ansel",
	blurb = "The rays come in under the strikes and lie in it like a hot bath. Four of them, and don't be holding the rod when it goes.",
	requiresLevel = 38,
	objectives = { { type = "kill", count = 4, species = "voltray" } },
	rewards = { coins = 2600, xp = 1900 },
}

-- ---------------------------------------------------------------- Bellkeeper Odd
Quests.items.odds_toll = {
	id = "odds_toll",
	name = "Odd's Toll",
	giver = "bellkeeper_odd",
	blurb = "The bell wants ringing on the hour and I've only the two hands. Fish the chapel while I climb, and mind the roof.",
	requiresLevel = 12,
	objectives = { { type = "catch", count = 6, waters = "ocean" } },
	rewards = { coins = 600, xp = 500 },
}

Quests.items.the_tollmaw_hunt = {
	id = "the_tollmaw_hunt",
	name = "The Tollmaw",
	giver = "bellkeeper_odd",
	blurb = "It swallowed the clapper. I have been ringing a bell with a stone tied to a rope for two years. Get it back.",
	prereq = "odds_toll",
	requiresLevel = 14,
	objectives = {
		{ type = "kill", count = 1, species = "tollmaw" },
		{ type = "deliver", materials = { bell_clapper = 1 } },
	},
	rewards = { coins = 1800, xp = 1200 },
}

Quests.items.the_bellringer = {
	id = "the_bellringer",
	name = "The Bellringer",
	giver = "bellkeeper_odd",
	blurb = "Hang it at the tip instead of in the tower and they come up senseless. Kinder, I tell myself. Go and have it made.",
	prereq = "the_tollmaw_hunt",
	objectives = { { type = "craft", itemId = "bellringer_rod" } },
	rewards = { coins = 900, xp = 900 },
}

-- ---------------------------------------------------------------- Saltmother Vess
Quests.items.the_gutting_stone = {
	id = "the_gutting_stone",
	name = "The Gutting Stone",
	giver = "saltmother_vess",
	blurb = "Something's been at my stone in the night. Bring me work to do while I watch for it - eight will do.",
	requiresLevel = 26,
	objectives = { { type = "catch", count = 8, waters = "ocean" } },
	rewards = { coins = 1400, xp = 1100 },
}

Quests.items.the_ribbonjaw_hunt = {
	id = "the_ribbonjaw_hunt",
	name = "Old Ribbonjaw",
	giver = "saltmother_vess",
	blurb = "It took the whetstone out of the middle of my stone. Not the fish, mind. The whetstone. It knew which part mattered.",
	prereq = "the_gutting_stone",
	requiresLevel = 28,
	objectives = {
		{ type = "kill", count = 1, species = "old_ribbonjaw" },
		{ type = "deliver", materials = { whetstone_heart = 1 } },
	},
	rewards = { coins = 2600, xp = 1800 },
}

Quests.items.the_ribboncutter = {
	id = "the_ribboncutter",
	name = "The Ribboncutter",
	giver = "saltmother_vess",
	blurb = "Set it in a blade and nothing goes to waste. Nothing wasted is a mercy, of a kind. Have it made and don't argue with me.",
	prereq = "the_ribbonjaw_hunt",
	objectives = { { type = "craft", itemId = "ribboncutter_rod" } },
	rewards = { coins = 1200, xp = 1200 },
}

-- ---------------------------------------------------------------- the Lampwright
Quests.items.every_lamp_dark = {
	id = "every_lamp_dark",
	name = "Every Lamp Dark",
	giver = "lampwright",
	blurb = "I don't light them any more and I won't be talked round. Fish the trench if you want to see what I'm not lighting them for.",
	requiresLevel = 30,
	objectives = { { type = "catch", count = 8, waters = "gloom" } },
	rewards = { coins = 1600, xp = 1300 },
}

Quests.items.the_moth_hunt = {
	id = "the_moth_hunt",
	name = "The Moth of the Deep",
	giver = "lampwright",
	blurb = "It came for the lamp I gave away, found the man who made it instead, and it has been circling ever since. Put it out.",
	prereq = "every_lamp_dark",
	requiresLevel = 32,
	objectives = {
		{ type = "kill", count = 1, species = "moth_of_the_deep" },
		{ type = "deliver", materials = { unburnt_wick = 1 } },
	},
	rewards = { coins = 3000, xp = 2000 },
}

Quests.items.the_lampwrights_line = {
	id = "the_lampwrights_line",
	name = "The Lampwright's Line",
	giver = "lampwright",
	blurb = "It never burned. Forty years of wicks and that one never burned. Hang it at the tip and the deep will show you what it keeps.",
	prereq = "the_moth_hunt",
	objectives = { { type = "craft", itemId = "lampwrights_line_rod" } },
	rewards = { coins = 1400, xp = 1400 },
}

return Quests
