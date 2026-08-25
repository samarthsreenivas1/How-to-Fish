--!nonstrict
-- Remotes.luau
-- Declarative registry of the whole network surface. One list of names and
-- classes instead of ad-hoc Instance.new calls scattered through services -
-- the server creates each instance the first time this module is required,
-- and the client just waits for the same names. This file is meant to grow,
-- not be replaced.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local DEFS = {
	-- Pulled once by the client on load, in case the push below raced a
	-- client that wasn't listening yet.
	{ name = "GetInventory", class = "RemoteFunction" },
	-- Pushed by the server whenever a player's owned items change.
	{ name = "InventoryUpdated", class = "RemoteEvent" },

	-- Fishing: the cast, then the reel timing minigame it opens into. The
	-- server owns the seed and the score; the client only ever proposes.
	{ name = "RequestCast", class = "RemoteEvent" }, -- client -> server: landing (Vector3, where the bobber lands)
	{ name = "CastAccepted", class = "RemoteEvent" }, -- server -> client: castId, seed, config, landing (validated)
	{ name = "CastRejected", class = "RemoteEvent" }, -- server -> client: reason
	{ name = "SubmitReelClick", class = "RemoteEvent" }, -- client -> server: castId, round, barTime
	{ name = "ReelRoundResult", class = "RemoteEvent" }, -- server -> client: castId, round, kind, score
	{ name = "CastResolved", class = "RemoteEvent" }, -- server -> client: castId, summary ({ grade, creature } or { cancelled = true, reason })
	{ name = "AbandonCast", class = "RemoteEvent" }, -- client -> server: castId

	-- Loadout: what's in the player's hands. The answer comes back as the
	-- Player's replicated `Equipped` attribute (see Shared/Config/Equipment),
	-- not a remote, so late joiners and other clients read the same thing.
	{ name = "RequestEquip", class = "RemoteEvent" }, -- client -> server: kind ("rod" | "weapon")

	-- Combat: the client asks to attack, the server decides what got hit
	-- (CombatService). No result comes back through here - a hit shows up as
	-- the creature's replicated Health attribute dropping, which every client
	-- already watches for the flash / health bar / damage number.
	{ name = "RequestAttack", class = "RemoteEvent" }, -- client -> server, no args
	-- A landed hit, for the impact VFX (CombatVfxController). Carries where
	-- on the creature it connected so the burst sits on the contact face,
	-- not the fish's centre; the attacker's UserId so only their camera
	-- kicks. Health itself still replicates as the attribute.
	{ name = "CreatureHit", class = "RemoteEvent" }, -- server -> all clients: hitPoint, direction, killed, attackerUserId

	-- Ranged weapons (revamp Session 2, docs/revamp-plan.md Systems §1). The
	-- client proposes a camera ray (the CastAim trust model); CombatService
	-- re-validates the origin against the character (Tuning.Ranged.ORIGIN_SLACK),
	-- raycasts at fire time, and applies the damage after the flight delay.
	-- Melee's argument-less RequestAttack above stays untouched.
	{ name = "RequestShoot", class = "RemoteEvent" }, -- client -> server: rayOrigin (Vector3), look (Vector3)
	-- One fired shot for the tracer/muzzle-flash pool (RangedFxController).
	-- `termini` is a small array of world points the tracer(s) end at (one per
	-- pellet for a scattergun); the local shooter already predicted their own.
	{ name = "ShotFired", class = "RemoteEvent" }, -- server -> all clients: attackerUserId, origin, termini { Vector3 }, weaponId

	-- Progression: the running totals live as replicated attributes on the
	-- Player (Shared/Modules/Progression.ATTR); this only carries the
	-- "+coins +xp" moment for the HUD pop, which attributes can't express.
	{ name = "RewardGranted", class = "RemoteEvent" }, -- server -> client: { coins, xp, creature, levelsGained }

	-- Crafting materials: counts are a table (attributes can't hold one), so
	-- the same pull-then-push pattern as the inventory (MaterialService owns
	-- the counts). GetMaterials pulls the full { [matId] = count } once on
	-- load; MaterialsUpdated pushes it whenever it changes; MaterialGranted
	-- carries just the "+N of each" moment for the HUD pop.
	{ name = "GetMaterials", class = "RemoteFunction" }, -- client -> server: pulls { [matId] = count }
	{ name = "MaterialsUpdated", class = "RemoteEvent" }, -- server -> client: { [matId] = count } (full)
	{ name = "MaterialGranted", class = "RemoteEvent" }, -- server -> client: { [matId] = amountGained }

	-- Crafting: spend materials + coins (level-gated) to craft a rod or a
	-- weapon, and pick which owned one is in hand. CraftingService owns the
	-- recipe checks; InventoryService owns ownership + the equipped choices
	-- (published as the Equipment.*_ATTRIBUTE Player attributes).
	{ name = "RequestCraft", class = "RemoteEvent" }, -- client -> server: itemId (a Rods or Weapons id)
	{ name = "CraftResult", class = "RemoteEvent" }, -- server -> client: { ok, itemId, reason? }
	{ name = "RequestEquipRod", class = "RemoteEvent" }, -- client -> server: rodId
	{ name = "RequestEquipWeapon", class = "RemoteEvent" }, -- client -> server: weaponId

	-- Admin/dev cheat panel (AdminService / AdminController). Server-gated to
	-- Studio + an admin allowlist, so the event existing for everyone is safe.
	{ name = "AdminGrant", class = "RemoteEvent" }, -- client -> server: action ("coins" | "xp" | "materials" | "all")
	{ name = "AdminSpawn", class = "RemoteEvent" }, -- client -> server: creatureId (spawns it in front of the caller)

	-- A rare finished item dropped by a killed creature (DropService), for the
	-- "You found:" banner (DropController). The item itself lands in inventory
	-- via grantItem, which pushes InventoryUpdated - this is just the fanfare.
	{ name = "ItemDropped", class = "RemoteEvent" }, -- server -> killer: itemId

	-- Creature moments that attributes can't express (CreatureService ->
	-- CreatureEventController): a spat glob, its splash, an explosion, a burrower
	-- bursting up, a mimic's snap, a pickpocket, a shockwave. One generic
	-- event; clients branch on `kind`. Ongoing states (Buried / Open /
	-- Charging / Dashing / Exposed) are attributes on the creature Model.
	{ name = "CreatureEvent", class = "RemoteEvent" }, -- server -> all clients: kind, position, extra (table)

	-- Island travel (IslandsController -> WorldService). The client asks to
	-- teleport to an island id; the server re-checks it exists, is placed, and
	-- the player's level clears its unlock, then moves the character there.
	{ name = "RequestTeleport", class = "RemoteEvent" }, -- client -> server: islandId
	{ name = "TeleportResult", class = "RemoteEvent" }, -- server -> client: { ok, islandId, reason? }

	-- Bait (BaitService / BaitController). Counts replicate the material way:
	-- GetBait pulls { [baitId] = count }, BaitUpdated pushes it, BaitGranted
	-- carries just the "+N" moment. RequestSelectBait sets the active bait
	-- (published as the Equipment.BAIT_ATTRIBUTE Player attribute).
	{ name = "GetBait", class = "RemoteFunction" }, -- client -> server: pulls { [baitId] = count }
	{ name = "BaitUpdated", class = "RemoteEvent" }, -- server -> client: { [baitId] = count } (full)
	{ name = "BaitGranted", class = "RemoteEvent" }, -- server -> client: { [baitId] = amountGained }
	{ name = "RequestSelectBait", class = "RemoteEvent" }, -- client -> server: baitId ("" clears)

	-- Admin travel (AdminController -> AdminService). Teleport to ANY island,
	-- skipping the level/boss unlock gates - admin-gated server-side like the
	-- other Admin* remotes, so it existing for everyone is safe.
	{ name = "AdminTeleport", class = "RemoteEvent" }, -- client -> server: islandId
}

local Remotes = {}

if RunService:IsServer() then
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ReplicatedStorage
	end

	for _, def in DEFS do
		if not folder:FindFirstChild(def.name) then
			local instance = Instance.new(def.class)
			instance.Name = def.name
			instance.Parent = folder
		end
	end

	for _, def in DEFS do
		Remotes[def.name] = folder:FindFirstChild(def.name)
	end
else
	local folder = ReplicatedStorage:WaitForChild("Remotes")
	for _, def in DEFS do
		Remotes[def.name] = folder:WaitForChild(def.name)
	end
end

return Remotes
