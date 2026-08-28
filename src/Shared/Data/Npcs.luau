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
	quests = { "marens_wager", "teeth_of_the_cove", "the_wider_water" },
	shop = "marens_stall", -- Shops.luau id: the Browse-wares pane
}

return Npcs
