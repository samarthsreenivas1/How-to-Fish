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
	"WorldService",
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
	"CraftingService", -- after Inventory + Material + Progression: spends mats/coins, grants rods + weapons
	"BossService", -- after Creature + Inventory + Progression: raises island bosses when a player qualifies, records the win
	"AdminService", -- after Progression + Material: dev cheat grants (coins/xp/materials), gated to admins
	"DropService", -- after Creature + Inventory: rare finished-item drops off the Killed event
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
