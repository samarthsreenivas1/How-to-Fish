--!nonstrict
-- AdminService.luau
-- Dev/admin cheat grants: hands the caller a big pile of coins, XP or
-- materials on request (repeatable, so "infinite" is just clicking again).
-- The panel UI is AdminController; this is the authoritative grant side.
--
-- Grants route through the normal service API (ProgressionService.addCoins /
-- addXp, MaterialService.grant) so totals stay consistent and replicate
-- exactly as a real reward would - the HUD and crafting menus update on
-- their own off the same attributes / MaterialsUpdated push.
--
-- Server-authoritative gate: the AdminGrant remote exists for everyone, but
-- a grant only applies for Studio play, a UserId in ADMIN_USER_IDS, or the
-- place's own creator - so it can't be abused in a live server.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Islands = require(Shared.Config.Islands)
local Bait = require(Shared.Data.Bait)
local Boats = require(Shared.Data.Boats)
local Bosses = require(Shared.Data.Bosses)
local Creatures = require(Shared.Data.Creatures)
local Materials = require(Shared.Data.Materials)
local Rods = require(Shared.Data.Rods)
local Weapons = require(Shared.Data.Weapons)
local Remotes = require(Shared.Net.Remotes)

local ProgressionService = require(script.Parent.ProgressionService)
local MaterialService = require(script.Parent.MaterialService)
local CreatureService = require(script.Parent.CreatureService)
local WorldService = require(script.Parent.WorldService)
local InventoryService = require(script.Parent.InventoryService)
local BaitService = require(script.Parent.BaitService)
local BoatService = require(script.Parent.BoatService)

local AdminService = {}

-- Add your Roblox UserId here to use the panel in a PUBLISHED game. Studio
-- play and the place's creator are always allowed, so this can stay empty
-- while testing.
local ADMIN_USER_IDS: { number } = {}

-- One click's worth. Big enough that a click or two is plenty; click again
-- for more. Coins/XP are added (XP rolls up levels); each material is topped
-- up by GRANT_MATERIAL.
local GRANT_COINS = 100000
local GRANT_XP = 100000
local GRANT_MATERIAL = 9999
local GRANT_BAIT = 99 -- per bait id, on "items"; baits are counts, not owned-once
local UNLOCK_XP = 10000000 -- "unlock" slams the level to MAX_LEVEL (addXp caps there)

-- How far in front of the player an admin-spawned creature surfaces before
-- it arcs in to their feet (same throw a real catch uses).
local SPAWN_DISTANCE = 18

-- The client reads this Player attribute to decide whether to show the panel.
local ADMIN_ATTRIBUTE = "IsAdmin"

local function isAdmin(player: Player): boolean
	if RunService:IsStudio() then
		return true
	end
	for _, id in ADMIN_USER_IDS do
		if player.UserId == id then
			return true
		end
	end
	if game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId then
		return true
	end
	return false
end

local function grantMaterials(player: Player)
	for _, matId in Materials.order do
		MaterialService.grant(player, matId, GRANT_MATERIAL)
	end
end

-- Every rod, weapon and bait in the game, through the normal grant APIs so
-- the menus/HUD update live. Rods/weapons are owned-once (grantItem no-ops on
-- a duplicate, so the button is idempotent); baits are counts and top up.
local function grantAllItems(player: Player)
	for id in Rods.items do
		InventoryService.grantItem(player, id)
	end
	for id in Weapons.items do
		InventoryService.grantItem(player, id)
	end
	for id in Bait.items do
		BaitService.grant(player, id, GRANT_BAIT)
	end
end

-- Drop every progression gate at once: max level (addXp caps at MAX_LEVEL),
-- every island's Cleared_ flag, every boss heart, and the top boat tier.
-- These are the exact attributes BossService/BoatService set on real
-- progress, so mayEnter / recipes / the Trophy Hall / heart-gated crafts all
-- read them identically - and DataService persists them like the real thing.
-- Beware in a real save: there is deliberately NO "relock" action.
local function unlockEverything(player: Player)
	ProgressionService.addXp(player, UNLOCK_XP)
	for id in Islands.items do
		player:SetAttribute("Cleared_" .. id, true)
	end
	for bossId in Bosses.items do
		player:SetAttribute("Heart_" .. bossId, true)
	end
	-- Through the service, not a raw attribute: grantTier also retires any
	-- spawned hull and announces the upgrade like a real craft would.
	BoatService.grantTier(player, Boats.MAX_TIER)
end

local function onGrant(player: Player, action)
	if not isAdmin(player) or type(action) ~= "string" then
		return
	end
	if action == "coins" or action == "all" then
		ProgressionService.addCoins(player, GRANT_COINS)
	end
	if action == "xp" or action == "all" then
		ProgressionService.addXp(player, GRANT_XP)
	end
	if action == "materials" or action == "all" then
		grantMaterials(player)
	end
	if action == "items" or action == "all" then
		grantAllItems(player)
	end
	if action == "unlock" or action == "all" then
		unlockEverything(player)
	end
end

-- Spawns `creatureId` a little in front of the caller and lets it arc in to
-- them, exactly the way a real catch arrives (CreatureService.spawn reads
-- the row's stance / archetype / drops - fish and hostiles alike go through
-- the same call). position's Y is forced to the waterline inside spawn, so
-- this reads best cast near the water; far inland it surfaces at y = 0.
local function onSpawn(player: Player, creatureId)
	if not isAdmin(player) or type(creatureId) ~= "string" then
		return
	end
	local row = Creatures.items[creatureId]
	if not row then
		return
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end

	local look = (root :: BasePart).CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	flat = if flat.Magnitude > 0.01 then flat.Unit else Vector3.new(0, 0, -1)
	local position = (root :: BasePart).Position + flat * SPAWN_DISTANCE

	CreatureService.spawn(row, position, (root :: BasePart).Position, "Neutral")
end

-- Admin travel: drop the caller on any island's spawn, skipping the level/boss
-- unlock gates the normal travel menu enforces (WorldService.teleportToIsland
-- takes no gates). Still admin-only, and the island's mesh must be placed.
local function onTeleport(player: Player, islandId)
	if not isAdmin(player) or type(islandId) ~= "string" then
		return
	end
	WorldService.teleportToIsland(player, islandId)
end

local function flagAdmin(player: Player)
	player:SetAttribute(ADMIN_ATTRIBUTE, isAdmin(player))
end

function AdminService.init()
	Remotes.AdminGrant.OnServerEvent:Connect(onGrant)
	Remotes.AdminSpawn.OnServerEvent:Connect(onSpawn)
	Remotes.AdminTeleport.OnServerEvent:Connect(onTeleport)
end

function AdminService.start()
	Players.PlayerAdded:Connect(flagAdmin)
	for _, player in Players:GetPlayers() do
		flagAdmin(player)
	end
end

return AdminService
