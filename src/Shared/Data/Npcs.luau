--!nonstrict
-- Npcs.luau
-- The islands' named characters, as data. An NPC is a stationary friendly
-- body (built from a CreaturePack species - bespoke NPC models can replace
-- these later without touching anything but `body`) with a nameplate and a
-- ProximityPrompt; walking up and pressing E opens the dialog (NpcService
-- pushes NpcDialog, NpcDialogController draws it on the Kit).
--
-- Placement: `spawnOffset` is relative to the ISLAND'S SPAWN POINT
-- (Islands.items[island].spawn, world coords) - spawns sit on reviewed,
-- walkable ground on every island, so an NPC a few studs from one does too.
-- The Y is probed against the real terrain at build time.
--
-- Roles arrive with their slices: `quests` (A2+) lists Quests.luau ids this
-- NPC gives; `shop` (C4) will name a Shops.luau stock. A1 ships greeting
-- dialog only.

local Npcs = {}

export type Npc = {
	id: string,
	name: string, -- nameplate + dialog title
	title: string, -- the line under the name ("Cove Fishwife")
	island: string, -- Islands.items key
	spawnOffset: Vector3, -- relative to the island's spawn point (Y ignored, probed)
	facing: number, -- yaw, degrees, world frame
	body: { model: string, species: string?, scale: number? },
	greeting: { string }, -- paragraphs shown when you talk
	quests: { string }?, -- Quests.luau ids, in offer order (A2+)
}

Npcs.items = {} :: { [string]: Npc }

-- Old Maren, the cove fishwife: the first voice in the game. She stands a
-- few steps from where every new player wakes up on the starter beach.
Npcs.items.old_maren = {
	id = "old_maren",
	name = "Old Maren",
	title = "Cove Fishwife",
	island = "tropical",
	spawnOffset = Vector3.new(21, 0, -5),
	facing = 162, -- behind her stall counter, shack at her back
	-- The Deckhand biped as a stand-in body (recolored warmly by NpcService
	-- so she reads friendly, not drowned); a bespoke Maren model can slot in
	-- here later.
	body = { model = "CreaturePack", species = "Deckhand", scale = 1.05 },
	greeting = {
		"Another face washed up on the cove, eh? Good. The fish have been getting bold.",
		"Everything out there bites now, love - reel it in, knock it down, and bring me the stories.",
		"Come back when you've got your sea legs. Old Maren always has work for willing hands.",
	},
	quests = { "marens_wager", "teeth_of_the_cove", "the_wider_water", "the_daily_haul" },
	shop = "marens_stall", -- Shops.luau id: the Browse-wares pane
}

-- Morra, the fen's bog-witch: quests in the murk.
Npcs.items.morra = {
	id = "morra",
	name = "Morra",
	title = "Bog-Witch of the Fen",
	island = "swamp",
	spawnOffset = Vector3.new(-20, 0, 2),
	facing = 258, -- in her dooryard where the plank path meets the hut
	body = { model = "CreaturePack", species = "SunkenTrapper", scale = 1.0 },
	greeting = {
		"Mind the roots, wanderer. The fen knows you're here - it told me before you stepped off the sand.",
		"The murk gives to those who feed it. Leeches, mostly. Do something about the leeches.",
	},
	quests = { "leech_tithe", "murk_harvest", "a_skin_for_the_mire" },
}

-- Halvard, the frost hermit of the Reach.
Npcs.items.halvard = {
	id = "halvard",
	name = "Halvard",
	title = "Frost Hermit",
	island = "ice",
	spawnOffset = Vector3.new(18, 0, -4),
	facing = 102, -- at the hull's door, out of the wind
	body = { model = "CreaturePack", species = "FrozenMariner", scale = 1.0 },
	greeting = {
		"Shut the wind out and speak quick. The holes freeze over faster than a soft-handed southerner can cast.",
		"The pups have been at my lines again. Deal with them and I'll deal fair with you.",
	},
	quests = { "pups_and_lines", "under_the_sheet" },
	shop = "halvards_cache",
}

-- Brakk, the ash-smith at the volcano's foot.
Npcs.items.brakk = {
	id = "brakk",
	name = "Brakk",
	title = "Cinder-Smith",
	island = "volcano",
	spawnOffset = Vector3.new(87, 0, -20),
	facing = 190, -- at the anvil counter on the forge's open face
	body = { model = "CreaturePack", species = "SlagGolem", scale = 0.9 },
	greeting = {
		"Stand off the bellows. Everything on this rock wants to cook you, and half of it reports to me.",
		"Sulfur. Always sulfur. Bring it and the forge stays friendly.",
	},
	quests = { "the_sulfur_toll", "lake_of_fire" },
	shop = "brakks_forge",
}

-- Keeper Lumen, the trench's half-mad lightkeeper.
Npcs.items.lumen = {
	id = "lumen",
	name = "Keeper Lumen",
	title = "Lightkeeper of the Trench",
	island = "gloom",
	spawnOffset = Vector3.new(-10, 0, 6),
	facing = 270, -- at the lighthouse door under his own light
	body = { model = "CreaturePack", species = "Deckhand", scale = 1.05 },
	greeting = {
		"You SEE it too, yes? The dark that leans in when the lamp gutters? Good. Then you're not mad. Or we both are.",
		"Feed the lamp, feed the log, never trust a light that drifts. Now - work?",
	},
	quests = { "what_the_dark_eats", "gullet_census", "a_veil_against_the_dark" },
}

-- Quartermaster Hollow, the ghost fleet's bookkeeper.
Npcs.items.hollow = {
	id = "hollow",
	name = "Quartermaster Hollow",
	title = "Of the Drowned Fleet",
	island = "wreck",
	spawnOffset = Vector3.new(-39, 0, -1),
	facing = 316, -- behind the gangplank counter, ship at his back, facing up the beach
	body = { model = "CreaturePack", species = "DrownedBoatswain", scale = 1.0 },
	greeting = {
		"Name and business in the ledger. Everything in this bay is owed to somebody, and I keep the book.",
		"The crabs have been eating my inventory. Literally. See to it and the fleet remembers its friends.",
	},
	shop = "hollows_locker", -- Shops.luau id: the fleet's salvage, armor included
	quests = { "ledger_of_teeth", "salvage_rights" },
}

-- ============================================================ the islet folk
-- One resident per islet. They are the only people out here, and every one of
-- them lives off the water: the story's moral is carried by what they DO, and
-- none of them ever says it. Their `spawnOffset` is zero because each islet's
-- `spawn` is already the flat pad its builder measured and reserved.

Npcs.items.nettle = {
	id = "nettle",
	name = "Nettle",
	title = "Of the Bell Rock",
	island = "bellbuoy",
	spawnOffset = Vector3.new(0, 0, 0),
	facing = 250, -- back to the bell, watching the water it drives things out of
	body = { model = "CreaturePack", species = "PlunderSprite", scale = 1.1 },
	greeting = {
		"It rings itself, that. Nobody hung it and nobody minds it. Things come to see what the noise is, and I'm here when they do.",
		"You get used to it. You stop hearing it about a week in, and that's when you know you've been out here too long.",
	},
	quests = { "what_the_bell_brings" },
}

Npcs.items.bellkeeper_odd = {
	id = "bellkeeper_odd",
	name = "Bellkeeper Odd",
	title = "Of the Drowned Chapel",
	island = "chapel",
	spawnOffset = Vector3.new(0, 0, 0),
	facing = 300, -- facing the tower he climbs, back to the open water
	body = { model = "CreaturePack", species = "DrownedBoatswain", scale = 1.0 },
	greeting = {
		"The bell wants ringing. Not for anyone - there's nobody left down there to hear it. It just wants ringing, and it's quieter after.",
		"There was a village. You're standing over the nave. Mind the hole in the roof; it's the only way in and it's the only way out.",
	},
	quests = { "odds_toll", "the_tollmaw_hunt", "the_bellringer" },
}

Npcs.items.pip = {
	id = "pip",
	name = "Pip",
	title = "Egg-Picker",
	island = "rookery",
	spawnOffset = Vector3.new(0, 0, 0),
	facing = 180,
	body = { model = "CreaturePack", species = "Deckhand", scale = 0.95 },
	greeting = {
		"Don't look up with your mouth open. That's the whole of my advice and it's better than most.",
		"They were here first, I know it, they know it. Doesn't stop either of us.",
	},
	quests = { "the_parliament" },
}

Npcs.items.cinder = {
	id = "cinder",
	name = "Cinder",
	title = "Of the Boiling Shoal",
	island = "boilshoal",
	spawnOffset = Vector3.new(0, 0, 0),
	facing = 180, -- looking back over the vents
	body = { model = "CreaturePack", species = "CinderDjinn", scale = 0.9 },
	greeting = {
		"Cold water's got nothing in it worth having. Everything interesting lives where it hurts.",
		"Stand where I'm standing. The glass looks the same either side of the line and it very much is not.",
	},
	quests = { "what_bites_in_boiling_water" },
}

Npcs.items.lampwright = {
	id = "lampwright",
	name = "The Lampwright",
	title = "Who Made the Trench Lamp",
	island = "lampwork",
	spawnOffset = Vector3.new(0, 0, 0),
	facing = 90, -- at his bench, the open forge side toward the water
	body = { model = "CreaturePack", species = "Deckhand", scale = 1.0 },
	greeting = {
		"I made the one on the tower. Best thing these hands ever did. I'd take it back if he'd let me.",
		"Eighteen out there and not one of them lit. You'll notice I keep the shutters closed on all but the one.",
	},
	quests = { "every_lamp_dark", "the_moth_hunt", "the_lampwrights_line" },
}

Npcs.items.coil = {
	id = "coil",
	name = "Coil",
	title = "Salvor",
	island = "anchorage",
	spawnOffset = Vector3.new(0, 0, 0),
	facing = 210,
	body = { model = "CreaturePack", species = "RiggingWraith", scale = 1.0 },
	greeting = {
		"Every one of these was somebody's last good idea. Dropped in a blow, cut when the blow won.",
		"Twenty-three of them hang slack. Count them yourself. Then find the one that doesn't and tell me what you think is holding it.",
	},
	quests = { "the_taut_chain" },
}

Npcs.items.saltmother_vess = {
	id = "saltmother_vess",
	name = "Saltmother Vess",
	title = "Of the Whale Fall",
	island = "whalefall",
	spawnOffset = Vector3.new(0, 0, 0),
	facing = 200, -- at the carcass, working
	body = { model = "CreaturePack", species = "SunkenTrapper", scale = 1.0 },
	greeting = {
		"They know what I do here. Of course they're angry. Wouldn't you be?",
		"Forty years of gutting and the smell never leaves the stone. It's in the stone, not in me. That's what I tell myself.",
	},
	quests = { "the_gutting_stone", "the_ribbonjaw_hunt", "the_ribboncutter" },
}

Npcs.items.ferryman = {
	id = "ferryman",
	name = "The Ferryman",
	title = "Of No Harbour",
	island = "ferryraft",
	spawnOffset = Vector3.new(0, 0, 0),
	facing = 270, -- behind his counter, facing whoever ties up
	body = { model = "CreaturePack", species = "Deckhand", scale = 1.05 },
	greeting = {
		"Six thousand studs to the nearest anything. That's not a hardship, that's the selling point.",
		"You came all this way, so you'll want something. Everyone who gets here wants something.",
	},
	quests = { "the_long_way_round" },
}

Npcs.items.ansel = {
	id = "ansel",
	name = "Ansel",
	title = "Struck Twice",
	island = "loadstone",
	spawnOffset = Vector3.new(0, 0, 0),
	facing = 270, -- back to the spire, which he does not look at
	body = { model = "CreaturePack", species = "StormcallerDjinn", scale = 0.9 },
	greeting = {
		"Twice! Same rock, eleven years apart. The second one I felt coming - the hair goes up, you get about a breath.",
		"Don't touch the iron. Don't touch anything with iron on it. Don't stand near ME, come to think of it.",
	},
	quests = { "struck_twice" },
}

return Npcs
