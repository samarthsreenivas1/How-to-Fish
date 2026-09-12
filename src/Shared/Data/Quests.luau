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
--
-- `lines` is the giver's VOICE for this particular job: `accept` is the reply
-- when the player takes it (it overrides the giver's generic voice.accept),
-- `progress` is what they say on the About pane while it is unfinished, and
-- `complete` is what they say on the turn-in pane, before the payout. The
-- field is optional - a row without it falls back to Npcs.items.<giver>.voice.
-- Keep the text brace-free: tools/check_content.py walks these rows by brace
-- depth and a curly brace inside a string literal derails it.

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
	lines: { accept: string, progress: string, complete: string }?, -- the giver's per-quest voice
	objectives: { Objective },
	prereq: string?,
	requiresLevel: number?,
	repeatable: (boolean | string)?,
	rewards: {
		coins: number?,
		xp: number?,
		materials: { [string]: number }?,
		bait: { [string]: number }?,
		-- Finished gear, granted by id through InventoryService.grantItem
		-- (rods, weapons, armor, trinkets). Four rows below pay one of these
		-- and the type never admitted the field existed.
		items: { string }?,
	},
}

Quests.items = {} :: { [string]: Quest }

-- Old Maren's opener: the tutorial-shaped first errand. Any five catches -
-- every catch fights back now, so this teaches the whole loop.
Quests.items.marens_wager = {
	id = "marens_wager",
	name = "Maren's Wager",
	giver = "old_maren",
	blurb = "Catch 5 fish for me. It's the quickest way to learn how fishing here works.",
	lines = {
		accept = "Thanks. Come back when you have all five.",
		progress = "You're still working on this. I need 5 fish.",
		complete = "Good work. Here's your reward.",
	},
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
	blurb = "The crabs keep breaking my drying racks. Kill 4 snapjaw crabs and catch 2 rare fish for me.",
	lines = {
		accept = "Thanks. Come back when both parts are done.",
		progress = "You're still working on this. I need 4 snapjaw crabs and 2 rare fish.",
		complete = "Good work. The racks are safe now. Here's your reward.",
	},
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
	blurb = "You're ready to leave the cove. Craft a bamboo rod, bring me 6 kelp fiber, and visit Blackmire Fen.",
	lines = {
		accept = "Thanks. Do the rod first, then the kelp, then the trip.",
		progress = "You're still working on this. A bamboo rod, 6 kelp fiber, and a visit to Blackmire Fen.",
		complete = "Good work. You're ready for bigger water now. Here's your reward.",
	},
	prereq = "teeth_of_the_cove",
	-- L8, not L5: the third objective is the fen, and Blackmire's
	-- unlockLevel IS 8 (plus Brinejaw's heart, and Leviathan's Call is a L7
	-- recipe). Offered at 5 this chain dead-ends on its last step with the
	-- giver unable to say why.
	requiresLevel = 8,
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
	blurb = "There are too many leeches in the swamp pools. Kill 5 mire leeches for me.",
	lines = {
		accept = "Thanks. Come back when the five are dead.",
		progress = "You're still working on this. I need 5 mire leeches killed.",
		complete = "Good work. That's five fewer in the water. Here's your reward.",
	},
	objectives = { { type = "kill", count = 5, species = "mire_leech" } },
	rewards = { coins = 260, xp = 220 },
}
Quests.items.murk_harvest = {
	id = "murk_harvest",
	name = "Murk Harvest",
	giver = "morra",
	blurb = "I need fish from the swamp water, not from the sea. Catch 6 of them in Blackmire Fen.",
	lines = {
		accept = "Thanks. Come back when you have all six.",
		progress = "You're still working on this. I need 6 fish caught in swamp water.",
		complete = "Good work. Here's your reward.",
	},
	prereq = "leech_tithe",
	objectives = { { type = "catch", count = 6, waters = "swamp" } },
	rewards = { coins = 380, xp = 300, materials = { fen_venom = 2 } },
}

Quests.items.a_skin_for_the_mire = {
	id = "a_skin_for_the_mire",
	name = "A Skin for the Mire",
	giver = "morra",
	blurb = "I can make you a swamp hood. Catch 6 fish in Blackmire Fen and bring me 3 mire hides.",
	lines = {
		accept = "Thanks. Bring the hides and the fish and I'll cut the hood.",
		progress = "You're still working on this. I need 6 swamp fish and 3 mire hides.",
		complete = "Good work. The hood is cut. Here's your reward.",
	},
	prereq = "murk_harvest",
	requiresLevel = 9,
	objectives = {
		{ type = "catch", count = 6, waters = "swamp" },
		{ type = "deliver", materials = { mire_hide = 3 } },
	},
	rewards = { coins = 420, xp = 340, items = { "mirewalker_helm" } },
}

-- ============================================================ the Reach (Halvard)
Quests.items.pups_and_lines = {
	id = "pups_and_lines",
	name = "Pups and Lines",
	giver = "halvard",
	blurb = "Frostbite pups keep eating my catch lines. Kill 3 of them for me.",
	lines = {
		accept = "Thanks. Come back when the three are dead.",
		progress = "You're still working on this. I need 3 frostbite pups killed.",
		complete = "Good work. My lines are safe now. Here's your reward.",
	},
	objectives = { { type = "kill", count = 3, species = "frostbite_pup" } },
	rewards = { coins = 520, xp = 420 },
}
Quests.items.under_the_sheet = {
	id = "under_the_sheet",
	name = "Under the Sheet",
	giver = "halvard",
	blurb = "I want to see if you can fish the ice. Catch 5 fish here on Frostmaw Reach.",
	lines = {
		accept = "Thanks. Come back when you have all five.",
		progress = "You're still working on this. I need 5 fish caught under the ice.",
		complete = "Good work. You can fish the ice. Here's your reward.",
	},
	prereq = "pups_and_lines",
	objectives = { { type = "catch", count = 5, waters = "ice" } },
	rewards = { coins = 700, xp = 560, materials = { everice = 2 } },
}

-- ============================================================ the Caldera (Brakk)
Quests.items.the_sulfur_toll = {
	id = "the_sulfur_toll",
	name = "The Sulfur Toll",
	giver = "brakk",
	blurb = "The forge runs on sulfur and I've run short. Bring me 4 sulfur.",
	lines = {
		accept = "Thanks. Come back when you have all four.",
		progress = "You're still working on this. I need 4 sulfur for the forge.",
		complete = "Good work. The forge can run again. Here's your reward.",
	},
	objectives = { { type = "deliver", materials = { sulfur = 4 } } },
	rewards = { coins = 900, xp = 640 },
}
Quests.items.lake_of_fire = {
	id = "lake_of_fire",
	name = "Lake of Fire",
	giver = "brakk",
	blurb = "I need to know your line can take the heat. Catch 5 fish in the caldera ponds.",
	lines = {
		accept = "Thanks. Come back when you have all five.",
		progress = "You're still working on this. I need 5 fish caught in the ponds.",
		complete = "Good work. Your gear can take the heat. Here's your reward.",
	},
	prereq = "the_sulfur_toll",
	objectives = { { type = "catch", count = 5, waters = "volcano" } },
	rewards = { coins = 1200, xp = 800, materials = { ember = 3 } },
}

-- ============================================================ the Trench (Lumen)
Quests.items.what_the_dark_eats = {
	id = "what_the_dark_eats",
	name = "What the Dark Eats",
	giver = "lumen",
	blurb = "Gulper eels circle my lamp and put the light out. Kill 3 of them for me.",
	lines = {
		accept = "Thanks. Come back when the three are dead.",
		progress = "You're still working on this. I need 3 gulper eels killed.",
		complete = "Good work. The lamp is clear again. Here's your reward.",
	},
	objectives = { { type = "kill", count = 3, species = "gulper_eel" } },
	rewards = { coins = 1600, xp = 1000 },
}
Quests.items.a_veil_against_the_dark = {
	id = "a_veil_against_the_dark",
	name = "A Veil Against the Dark",
	giver = "lumen",
	blurb = "I can make you a hood the trench can't see. Catch 8 fish in Gloomtrench and bring me 3 duskhide.",
	lines = {
		accept = "Thanks. Bring the duskhide and the fish and I'll stitch the hood.",
		progress = "You're still working on this. I need 8 Gloomtrench fish and 3 duskhide.",
		complete = "Good work. The hood is stitched. Here's your reward.",
	},
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
	blurb = "I record everything that lives down here. Catch 5 fish in Gloomtrench so I can log them.",
	lines = {
		accept = "Thanks. Come back when you have all five.",
		progress = "You're still working on this. I need 5 fish caught in Gloomtrench.",
		complete = "Good work. All five are logged. Here's your reward.",
	},
	prereq = "what_the_dark_eats",
	objectives = { { type = "catch", count = 5, waters = "gloom" } },
	rewards = { coins = 2000, xp = 1300, materials = { lantern_gland = 2 } },
}

-- ============================================================ the Bay (Hollow)
Quests.items.ledger_of_teeth = {
	id = "ledger_of_teeth",
	name = "Ledger of Teeth",
	giver = "hollow",
	blurb = "Cannonball crabs are eating the fleet's stores. Kill 4 of them and I'll close the entry.",
	lines = {
		accept = "Thanks. I've entered it in the book. Come back when the four are dead.",
		progress = "You're still working on this. I need 4 cannonball crabs killed.",
		complete = "Good work. The entry is closed. Here's your reward.",
	},
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
	blurb = "I sell fish every day and I need 8 more. Catch 8 of anything and bring them to me.",
	lines = {
		accept = "Thanks. Come back when you have all eight.",
		progress = "You're still working on this. I need 8 fish.",
		complete = "Good work. That's the day covered. Here's your reward.",
	},
	repeatable = "daily",
	objectives = { { type = "catch", count = 8 } },
	rewards = { coins = 220, xp = 180 },
}
Quests.items.salvage_rights = {
	id = "salvage_rights",
	name = "Salvage Rights",
	giver = "hollow",
	blurb = "This is a standing contract, renewed every day. Kill 6 creatures of any kind in the bay.",
	lines = {
		accept = "Thanks. The contract runs until you fill it.",
		progress = "You're still working on this. I need 6 kills of any kind.",
		complete = "Good work. The contract is filled. Here's your reward.",
	},
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
	blurb = "Drowned deckhands come ashore for the noise. Kill 4 of them so I can work in peace.",
	lines = {
		accept = "Thanks. Come back when the four are dead.",
		progress = "You're still working on this. I need 4 drowned deckhands killed.",
		complete = "Good work. The rock is quiet again. Here's your reward.",
	},
	requiresLevel = 10,
	objectives = { { type = "kill", count = 4, species = "drowned_deckhand" } },
	rewards = { coins = 500, xp = 420 },
}

Quests.items.the_parliament = {
	id = "the_parliament",
	name = "The Parliament",
	giver = "pip",
	blurb = "The loudest gulls set off the whole ledge at me. Kill 5 bog gulls and the rest calm down.",
	lines = {
		accept = "Thanks. Come back when the five are dead.",
		progress = "You're still working on this. I need 5 bog gulls killed.",
		complete = "Good work. The ledge is calmer now. Here's your reward.",
	},
	requiresLevel = 16,
	objectives = { { type = "kill", count = 5, species = "bog_gull" } },
	rewards = { coins = 900, xp = 700, materials = { fish_scale = 4 } },
}

Quests.items.what_bites_in_boiling_water = {
	id = "what_bites_in_boiling_water",
	name = "What Bites in Boiling Water",
	giver = "cinder",
	blurb = "The good fish here only live in the hot water. Catch 6 uncommon fish off the shoal.",
	lines = {
		accept = "Thanks. Fish the hot side and come back.",
		progress = "You're still working on this. I need 6 uncommon fish from the shoal.",
		complete = "Good work. Those all came out of the hot water. Here's your reward.",
	},
	requiresLevel = 22,
	objectives = { { type = "catch", count = 6, rarity = "Uncommon", waters = "ocean" } },
	rewards = { coins = 1300, xp = 1000 },
}

Quests.items.the_taut_chain = {
	id = "the_taut_chain",
	name = "The Taut Chain",
	giver = "coil",
	blurb = "I won't pull on that taut chain and neither should you. Fish the reef instead and catch 6.",
	lines = {
		accept = "Thanks. Fish the reef and leave the chain alone.",
		progress = "You're still working on this. I need 6 fish off the reef.",
		complete = "Good work. The chain is still taut. Here's your reward.",
	},
	requiresLevel = 34,
	objectives = { { type = "catch", count = 6, waters = "ocean" } },
	rewards = { coins = 2000, xp = 1500 },
}

Quests.items.the_long_way_round = {
	id = "the_long_way_round",
	name = "The Long Way Round",
	giver = "ferryman",
	blurb = "I trade with sailors who have made the crossings. Visit Blackmire Fen and Frostmaw Reach.",
	lines = {
		accept = "Thanks. Make both crossings and my counter stays open.",
		progress = "You're still working on this. I need you to visit Blackmire Fen and Frostmaw Reach.",
		complete = "Good work. My counter is open to you now. Here's your reward.",
	},
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
	blurb = "Voltrays lie in the hot water under the lightning strikes. Kill 4 of them, and don't hold your rod.",
	lines = {
		accept = "Thanks. Put the rod down when the storm comes in.",
		progress = "You're still working on this. I need 4 voltrays killed.",
		complete = "Good work. You didn't get hit either. Here's your reward.",
	},
	requiresLevel = 38,
	objectives = { { type = "kill", count = 4, species = "voltray" } },
	rewards = { coins = 2600, xp = 1900 },
}

-- ---------------------------------------------------------------- Bellkeeper Odd
Quests.items.odds_toll = {
	id = "odds_toll",
	name = "Odd's Toll",
	giver = "bellkeeper_odd",
	blurb = "I ring the bell on the hour and it takes both hands. Catch 6 fish here while I climb.",
	lines = {
		accept = "Thanks. You have about an hour while I climb.",
		progress = "You're still working on this. I need 6 fish caught off the chapel.",
		complete = "Good work. The hour was rung on time. Here's your reward.",
	},
	requiresLevel = 12,
	objectives = { { type = "catch", count = 6, waters = "ocean" } },
	rewards = { coins = 600, xp = 500 },
}

Quests.items.the_tollmaw_hunt = {
	id = "the_tollmaw_hunt",
	name = "The Tollmaw",
	giver = "bellkeeper_odd",
	blurb = "A fish called the Tollmaw swallowed my bell clapper. Kill it and bring the clapper back.",
	lines = {
		accept = "Thanks. Kill it and bring me the clapper.",
		progress = "You're still working on this. I need the Tollmaw dead and the clapper back.",
		complete = "Good work. The bell can ring properly again. Here's your reward.",
	},
	prereq = "odds_toll",
	-- L16, and this time the DATA agrees. The L36 that stood here was the
	-- audit's stop-gap: the Tollmaw was a wreck-band row, so the hunt had to
	-- wait on Wreckwater, which left Odd's chapel saga dead for ~30 levels
	-- after his L12 opener. 2026-09-12 took the geography seriously instead
	-- and swapped the two hermit elites' BANDS - the Tollmaw is the ice band's
	-- Epic now (waters "ice", 3,800 HP, bell_clapper still its own), so the
	-- hunt sits one level into Frostmaw Reach (unlockLevel 15) and the saga
	-- runs L12 -> L16 -> L20 inside one band.
	requiresLevel = 16,
	objectives = {
		{ type = "kill", count = 1, species = "tollmaw" },
		{ type = "deliver", materials = { bell_clapper = 1 } },
	},
	-- Priced for the ice band it now sits in: ~2.5x its band's ordinary
	-- errands (under_the_sheet 700/560, the_parliament 900/700), the same
	-- shape the gloom band's elite hunt has against its own neighbours.
	rewards = { coins = 1800, xp = 1200 },
}

Quests.items.the_bellringer = {
	id = "the_bellringer",
	name = "The Bellringer",
	giver = "bellkeeper_odd",
	blurb = "A bell hung at a rod tip stuns fish in the water. Craft the Bellringer rod and I'll pay for it.",
	lines = {
		accept = "Thanks. Craft the rod and come back.",
		progress = "You're still working on this. I need the Bellringer rod crafted.",
		complete = "Good work. That rod will call fish to you. Here's your reward.",
	},
	prereq = "the_tollmaw_hunt",
	-- The craft objective is only completable at the recipe's own gate, and
	-- bellringer_rod is requiresLevel 20 in Rods.luau since the band swap
	-- (was 41). Without this the quest is accepted and then sits
	-- un-completable with no explanation.
	requiresLevel = 20,
	rewards = { coins = 1200, xp = 1200 },
	objectives = { { type = "craft", itemId = "bellringer_rod" } },
}

-- ---------------------------------------------------------------- Saltmother Vess
Quests.items.the_gutting_stone = {
	id = "the_gutting_stone",
	name = "The Gutting Stone",
	giver = "saltmother_vess",
	blurb = "Something works my stone at night and I want to watch for it. Catch 8 fish to keep me busy.",
	lines = {
		accept = "Thanks. Come back when you have all eight.",
		progress = "You're still working on this. I need 8 fish for the stone.",
		complete = "Good work. That kept my hands busy. Here's your reward.",
	},
	-- L36, not 26: Saltmother Vess lives on the Whale Fall, which is not
	-- sailable until L36 (Wreckwater opens, tier 6 crosses the last 4,147
	-- studs), so any lower gate here was decoration. Her elite moved to the
	-- wreck band with the 2026-09-12 swap, so the whole saga is banded L36 ->
	-- L38 -> L41 where she actually stands.
	requiresLevel = 36,
	objectives = { { type = "catch", count = 8, waters = "ocean" } },
	-- Wreck-band opener pricing: the_taut_chain (L34) pays 2000/1500 and
	-- struck_twice (L38) 2600/1900.
	rewards = { coins = 2400, xp = 1700 },
}

Quests.items.the_ribbonjaw_hunt = {
	id = "the_ribbonjaw_hunt",
	name = "Old Ribbonjaw",
	giver = "saltmother_vess",
	blurb = "Old Ribbonjaw stole the whetstone out of my gutting stone. Kill it and bring the whetstone back.",
	lines = {
		accept = "Thanks. Kill it and bring me the whetstone.",
		progress = "You're still working on this. I need Old Ribbonjaw dead and the whetstone back.",
		complete = "Good work. The whetstone is back where it belongs. Here's your reward.",
	},
	prereq = "the_gutting_stone",
	-- L38: Old Ribbonjaw is a `waters = "wreck"` row since the band swap
	-- (14,000 HP now), so the hunt needs Wreckwater's bay open - and that is
	-- the water outside Vess's own door.
	requiresLevel = 38,
	objectives = {
		{ type = "kill", count = 1, species = "old_ribbonjaw" },
		{ type = "deliver", materials = { whetstone_heart = 1 } },
	},
	-- The wreck band's elite-hunt price: ledger_of_teeth (2600/1600) is the
	-- band's ordinary work and the_moth_hunt (3000/2000) the band below's hunt.
	rewards = { coins = 3400, xp = 2400 },
}

Quests.items.the_ribboncutter = {
	id = "the_ribboncutter",
	name = "The Ribboncutter",
	giver = "saltmother_vess",
	blurb = "That whetstone will hold an edge in a blade. Craft the Ribboncutter rod and I'll pay for it.",
	lines = {
		accept = "Thanks. Craft the rod and come back.",
		progress = "You're still working on this. I need the Ribboncutter rod crafted.",
		complete = "Good work. That rod will cut clean. Here's your reward.",
	},
	prereq = "the_ribbonjaw_hunt",
	-- The craft is only completable at the recipe's own gate: ribboncutter_rod
	-- is requiresLevel 41 in Rods.luau since the band swap (was 20). This gate
	-- was absent entirely, so the quest could be taken and then sit.
	requiresLevel = 41,
	objectives = { { type = "craft", itemId = "ribboncutter_rod" } },
	rewards = { coins = 1600, xp = 1600 },
}

-- ---------------------------------------------------------------- the Lampwright
Quests.items.every_lamp_dark = {
	id = "every_lamp_dark",
	name = "Every Lamp Dark",
	giver = "lampwright",
	blurb = "I want you to see why I keep the lamps dark. Catch 8 fish in Gloomtrench and come back.",
	lines = {
		accept = "Thanks. Fish the trench and then we'll talk.",
		progress = "You're still working on this. I need 8 fish caught in Gloomtrench.",
		complete = "Good work. Now you have seen what the light draws. Here's your reward.",
	},
	requiresLevel = 30,
	objectives = { { type = "catch", count = 8, waters = "gloom" } },
	rewards = { coins = 1600, xp = 1300 },
}

Quests.items.the_moth_hunt = {
	id = "the_moth_hunt",
	name = "The Moth of the Deep",
	giver = "lampwright",
	blurb = "The Moth of the Deep came up for the lamp I built. Kill it and bring me its unburnt wick.",
	lines = {
		accept = "Thanks. Kill it and bring me the wick.",
		progress = "You're still working on this. I need the Moth dead and the unburnt wick back.",
		complete = "Good work. It won't circle the shelf again. Here's your reward.",
	},
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
	blurb = "That wick never burned, so let's put it in the water. Craft the Lampwright's Line rod.",
	lines = {
		accept = "Thanks. Craft the rod and come back.",
		progress = "You're still working on this. I need the Lampwright's Line rod crafted.",
		complete = "Good work. That rod lights the deep water. Here's your reward.",
	},
	prereq = "the_moth_hunt",
	-- lampwrights_line_rod is a L34 recipe and the_moth_hunt gates at 32, so
	-- without this the last two levels of the saga are an un-completable
	-- quest in the log.
	requiresLevel = 34,
	objectives = { { type = "craft", itemId = "lampwrights_line_rod" } },
	rewards = { coins = 1400, xp = 1400 },
}

return Quests
