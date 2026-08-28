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
	spawnOffset = Vector3.new(11, 0, 7),
	facing = 225,
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
	spawnOffset = Vector3.new(-12, 0, 6),
	facing = 140,
	body = { model = "CreaturePack", species = "SunkenTrapper", scale = 1.0 },
	greeting = {
		"Mind the roots, wanderer. The fen knows you're here - it told me before you stepped off the sand.",
		"The murk gives to those who feed it. Leeches, mostly. Do something about the leeches.",
	},
	quests = { "leech_tithe", "murk_harvest" },
}

-- Halvard, the frost hermit of the Reach.
Npcs.items.halvard = {
	id = "halvard",
	name = "Halvard",
	title = "Frost Hermit",
	island = "ice",
	spawnOffset = Vector3.new(13, 0, -4),
	facing = 250,
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
	spawnOffset = Vector3.new(-15, 0, 10),
	facing = 60,
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
	spawnOffset = Vector3.new(10, 0, 9),
	facing = 210,
	body = { model = "CreaturePack", species = "Deckhand", scale = 1.05 },
	greeting = {
		"You SEE it too, yes? The dark that leans in when the lamp gutters? Good. Then you're not mad. Or we both are.",
		"Feed the lamp, feed the log, never trust a light that drifts. Now - work?",
	},
	quests = { "what_the_dark_eats", "gullet_census" },
}

-- Quartermaster Hollow, the ghost fleet's bookkeeper.
Npcs.items.hollow = {
	id = "hollow",
	name = "Quartermaster Hollow",
	title = "Of the Drowned Fleet",
	island = "wreck",
	spawnOffset = Vector3.new(-11, 0, -8),
	facing = 30,
	body = { model = "CreaturePack", species = "DrownedBoatswain", scale = 1.0 },
	greeting = {
		"Name and business in the ledger. Everything in this bay is owed to somebody, and I keep the book.",
		"The crabs have been eating my inventory. Literally. See to it and the fleet remembers its friends.",
	},
	shop = "hollows_locker", -- Shops.luau id: the fleet's salvage, armor included
	quests = { "ledger_of_teeth", "salvage_rights" },
}

return Npcs
