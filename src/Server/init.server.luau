--!nonstrict
-- init.server.luau
-- Server boot.
--
-- Services are plain modules with two optional methods, and this file owns the
-- order explicitly. No framework, no dependency graph to reason about:
--
--   init()  - create instances, bind remotes, register handlers.
--             Must not assume any later service is running yet.
--   start() - connect loops and process players already in the server.
--
-- A service may require any service listed above it. Adding one means adding a
-- name to ORDER.

local Services = script.Services

local ORDER = {
	"DataService", -- first: owns persistence; later services register their slices in init()
	"WorldService",
	"BossArenaService", -- after WorldService (waterline/world conventions): builds each boss's lair arena out in the ocean
	"InventoryService",
	"PlayerService", -- before CreatureService: the rusher's contact damage routes through it
	"RodService", -- after InventoryService: reads the equipped rod
	"WeaponService", -- after InventoryService: welds the equipped crafted weapon for other players
	"CreatureService", -- before FishingService: a resolved cast spawns through it
	"MaterialService", -- after CreatureService (listens to Killed), before FishingService (grants on cast resolve)
	"BaitService", -- after MaterialService; before FishingService (spends bait per cast) + CraftingService (grants bait)
	"FishingService", -- after InventoryService: reads the equipped rod's reel config
	"CombatService", -- after CreatureService + InventoryService: swings route through both (reads the equipped weapon row)
	"ProgressionService", -- after CreatureService: pays coins + XP off its Killed event
	"BoatService", -- after WorldService (launch points, open-sea distance); grants tiers, summons/parks/sinks the boat
	"CraftingService", -- after Inventory + Material + Progression + Boat: spends mats/coins, grants rods + weapons + boat tiers
	"BossService", -- after Creature + Inventory + Progression: raises island bosses when a player qualifies, records the win
	"AdminService", -- after Progression + Material + Inventory + Bait + Boat: dev cheat grants (coins/xp/materials/items/unlock), gated to admins
	"DropService", -- after Creature + Inventory: rare finished-item drops off the Killed event
	"SpawnerService", -- after Creature + World: ambient island hostiles off Islands.items[id].ambient
	"RaidService", -- after Spawner + Creature + Progression: wave raids off Islands.items[id].raid
	"WeatherService", -- after Spawner (blizzard biases flyers): timed weather windows on the WorldEvent remote
	"NpcService", -- last: places the islands' talking NPCs on ground the placed islands provide (probes Workspace/World)
}

local loaded = {}

for _, name in ORDER do
	local module = Services:FindFirstChild(name)
	assert(module, string.format("[Boot] missing service module %q", name))
	loaded[name] = require(module)
end

for _, phase in { "init", "start" } do
	for _, name in ORDER do
		local method = loaded[name][phase]
		if method then
			local ok, err = pcall(method)
			if not ok then
				error(string.format("[Boot] %s.%s failed: %s", name, phase, tostring(err)), 0)
			end
		end
	end
end

print(string.format("[Boot] %d service(s) online.", #ORDER))
