--!nonstrict
-- BoatService.luau
-- Owns every player's boat (docs/revamp-plan.md Session 3): grants the tiers,
-- summons/parks the hull, hands the physics to the driver, and chews through
-- it when they push past their tier's seaworthiness.
--
-- Ownership model: a player HAS a boat as the replicated `BoatTier` Player
-- attribute (0 = none; DataService persists it as profile.boatTier). The
-- world only ever contains at most ONE spawned boat per player, built by
-- BoatModel from the Boats.luau row for their tier and summoned to the
-- nearest shoreline on RequestBoat. Tier 1 is never crafted - it's granted
-- when Brinejaw's heart lands (the Heart_brinejaw attribute BossService
-- sets), which also back-fills a returning player on load, since DataService
-- restores Heart_* attributes and this service watches the same signal.
-- Tiers 2-6 arrive through CraftingService (the row's recipe) via grantTier.
--
-- Driving is client-owned physics, the Roblox way: while the OWNER sits in
-- the seat the hull's network ownership is theirs and BoatController steers
-- the Boat_Move/Boat_Align constraints (holding Y at World.WATER_Y + rest
-- height - never the tide-animated visual plane). The server keeps what
-- can't be trusted to a client: WHERE a summon lands, WHO may sit, the gates
-- (WorldService.mayEnter + its containment sweep - the boat needs no gate
-- checks of its own), and the open-sea DoT.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local World = require(Shared.Config.World)
local Tuning = require(Shared.Config.Tuning)
local Boats = require(Shared.Data.Boats)
local BoatModel = require(Shared.Modules.BoatModel)
local Remotes = require(Shared.Net.Remotes)

local WorldService = require(script.Parent.WorldService)

local BoatService = {}

local BOAT_ATTR = "BoatTier" -- on the Player; DataService persists it

-- Per-boat state, keyed by owner.
type BoatState = {
	model: Model,
	row: any,
	collider: BasePart,
	seat: VehicleSeat,
	warned: boolean, -- the seaworthiness warning fired for this excursion
	sinking: boolean, -- set by sink(); the park path must never resurface a wreck
	parkThread: thread?,
}
local boats: { [Player]: BoatState } = {}
local lastSummon: { [Player]: number } = {}
-- Hull damage carried between summons (see summon: a shore summon repairs,
-- an open-water re-summon keeps its dents - otherwise re-summoning mid
-- crossing would be a free repair and the seaworthiness DoT would be
-- toothless). Cleared by an upgrade (a new hull is a new hull).
local lastHull: { [Player]: number } = {}

local boatFolder: Folder

-- The collider's rest height: its centre sits this far above the waterline
-- when the hull floats at its lines. BoatController holds the same number.
function BoatService.restHeight(row): number
	return (row.model.deckHeight - row.model.draft) / 2
end

local function message(player: Player, text: string)
	Remotes.BoatMessage:FireClient(player, text)
end

local function despawn(player: Player)
	local state = boats[player]
	if not state then
		return
	end
	boats[player] = nil
	if state.parkThread then
		task.cancel(state.parkThread)
	end
	if state.model.Parent then
		local hull = state.model:GetAttribute("HullHealth")
		if type(hull) == "number" then
			lastHull[player] = hull
		end
		state.model:Destroy()
	end
end

-- ============================================================ tiers

-- Raise (never lower) a player's boat tier. The crafted upgrade path
-- (CraftingService) and the Brinejaw grant both land here. An upgrade
-- retires any spawned hull - the next summon builds the new one.
function BoatService.grantTier(player: Player, tier: number)
	local current = player:GetAttribute(BOAT_ATTR) or 0
	if tier <= current then
		return
	end
	player:SetAttribute(BOAT_ATTR, tier)
	local state = boats[player]
	if state then
		despawn(player)
	end
	lastHull[player] = nil -- a new hull is a new hull: no inherited dents
	local row = Boats.byTier[tier]
	if row then
		message(
			player,
			if tier == 1
				then string.format("%s is yours! Press R at the shore to launch it.", row.name)
				else string.format("Upgraded: %s. Summon it with R.", row.name)
		)
	end
end

-- The tier this player would upgrade TO next (CraftingController's ladder).
function BoatService.tierOf(player: Player): number
	return player:GetAttribute(BOAT_ATTR) or 0
end

-- ============================================================ spawn / park

-- Re-anchor a driverless hull flat at the waterline where it drifted to.
local function park(state: BoatState)
	local collider = state.collider
	if not collider.Parent then
		return
	end
	local _, yaw = collider.CFrame:ToEulerAnglesYXZ()
	collider.Anchored = true
	collider.CFrame = CFrame.new(
		collider.Position.X,
		World.WATER_Y + BoatService.restHeight(state.row),
		collider.Position.Z
	) * CFrame.Angles(0, yaw, 0)
end

local function onOccupantChanged(player: Player, state: BoatState)
	-- A sinking wreck unseats its driver on the way down; the park path must
	-- not catch that and re-anchor it back up at the waterline (the "wreck
	-- pops back to the surface before despawning" bug).
	if state.sinking then
		return
	end
	local humanoid = state.seat.Occupant
	if humanoid then
		if state.parkThread then
			task.cancel(state.parkThread)
			state.parkThread = nil
		end
		local sitter = Players:GetPlayerFromCharacter(humanoid.Parent)
		if sitter ~= player then
			-- Not your boat: passengers may stand on deck, but the helm is
			-- the owner's (network ownership means the driver simulates it).
			humanoid.Sit = false
			if sitter then
				message(sitter, "That's not your boat.")
			end
			return
		end
		state.collider.Anchored = false
		local ok = pcall(function()
			state.collider:SetNetworkOwner(sitter)
		end)
		if not ok then
			warn("[BoatService] could not hand the hull to its driver")
		end
	else
		-- Driver stood up (or was bounced): give physics a beat to settle,
		-- then freeze the hull flat at the waterline, server-owned.
		state.parkThread = task.delay(Tuning.Boat.PARK_SNAP_DELAY, function()
			state.parkThread = nil
			pcall(function()
				if not state.collider.Anchored then
					state.collider:SetNetworkOwner(nil)
				end
			end)
			park(state)
		end)
	end
end

local function summon(player: Player)
	local now = os.clock()
	if now - (lastSummon[player] or -math.huge) < Tuning.Boat.SUMMON_COOLDOWN then
		return
	end
	lastSummon[player] = now

	local tier = player:GetAttribute(BOAT_ATTR) or 0
	local row = Boats.byTier[tier]
	if tier < 1 or not row then
		message(player, "You have no boat yet - Brinejaw guards your first hull.")
		return
	end

	local launch = WorldService.boatLaunchCFrame(player)
	if not launch then
		return
	end

	despawn(player) -- a summon is also the recall: one boat, moved to you

	local model = BoatModel.build(row)
	local collider = BoatModel.findCollider(model)
	local seat = BoatModel.findSeat(model)
	if not (collider and seat) then
		warn("[BoatService] built a boat with no collider or seat; row " .. row.id)
		model:Destroy()
		return
	end

	-- A summon at the shore of somewhere you're allowed to be is the free
	-- patch-up (REPAIR_ON_SUMMON); a re-summon on open water keeps the dents
	-- it had, so summoning mid-crossing can't cheat the seaworthiness DoT.
	local hull = row.hullHealth
	local atShore = WorldService.openSeaDistance(player, launch.Position) <= 0
	if not (Tuning.Boat.REPAIR_ON_SUMMON and atShore) then
		hull = math.max(1, math.min(row.hullHealth, lastHull[player] or row.hullHealth))
	end

	model:SetAttribute("OwnerUserId", player.UserId)
	model:SetAttribute("BoatId", row.id)
	model:SetAttribute("MaxHullHealth", row.hullHealth)
	model:SetAttribute("HullHealth", hull)

	-- Boats pass through the sea slab and creatures, never players (the
	-- groups are registered by WorldService.init; assigning an unregistered
	-- group throws, and a boat must never take the server down).
	pcall(function()
		for _, p in model:GetDescendants() do
			if p:IsA("BasePart") then
				p.CollisionGroup = World.BOAT_COLLISION_GROUP
			end
		end
	end)

	collider.Anchored = true
	model:PivotTo(launch * CFrame.new(0, BoatService.restHeight(row), 0))
	model.Parent = boatFolder

	local state: BoatState = {
		model = model,
		row = row,
		collider = collider,
		seat = seat,
		warned = false,
		sinking = false,
		parkThread = nil,
	}
	boats[player] = state

	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		onOccupantChanged(player, state)
	end)
end

local function onRequestBoat(player: Player, action)
	if action == "summon" then
		summon(player)
	elseif action == "dismiss" then
		despawn(player)
	end
end

-- ============================================================ the open sea

local function sink(player: Player, state: BoatState)
	-- Flag FIRST: unseating the driver below fires onOccupantChanged, whose
	-- park path would otherwise re-anchor the wreck flat at the waterline a
	-- beat later - a sunk boat popping back to the surface to die.
	state.sinking = true
	message(player, "The sea claims her - your boat has sunk!")
	local occupant = state.seat.Occupant
	if occupant then
		occupant.Sit = false
	end
	boats[player] = nil
	if state.parkThread then
		task.cancel(state.parkThread)
	end
	-- The next summon raises a barely-patched hull (25%), not a fresh one:
	-- chain-sinking across an ocean must not be a free ferry. Reaching any
	-- legal shore repairs it properly (see summon).
	lastHull[player] = math.max(1, math.floor(state.row.hullHealth * 0.25))
	-- The wreck settles for a beat, then goes; the swimmers are the ocean
	-- slab's and the under-map net's problem now (both catch them).
	local model = state.model
	pcall(function()
		if not state.collider.Anchored then
			state.collider:SetNetworkOwner(nil)
		end
		state.collider.Anchored = false
		local move = state.collider:FindFirstChild("Boat_Move")
		if move and move:IsA("LinearVelocity") then
			move.VectorVelocity = Vector3.new(0, -4, 0) -- she goes down by the head
		end
	end)
	task.delay(Tuning.Boat.SINK_LINGER, function()
		if model.Parent then
			model:Destroy()
		end
	end)
end

-- Past the row's seaworthiness the hull takes ramping damage per second.
-- Distance is measured to the nearest island the OWNER may enter, so a legal
-- crossing (destination unlocked) never measures more than about half the
-- island spacing, while a locked shore offers no shelter.
local function seaworthinessTick()
	for player, state in boats do
		if not state.model.Parent then
			boats[player] = nil
			continue
		end
		local beyond = WorldService.openSeaDistance(player, state.collider.Position) - state.row.seaworthiness
		if beyond > 0 then
			if not state.warned then
				state.warned = true
				message(player, Tuning.Boat.WARNING)
			end
			local dot = Tuning.Boat.DOT_BASE * (1 + beyond / Tuning.Boat.RAMP_DISTANCE)
			local hull = (state.model:GetAttribute("HullHealth") or state.row.hullHealth) - dot
			state.model:SetAttribute("HullHealth", math.max(0, hull))
			if hull <= 0 then
				sink(player, state)
			end
		elseif state.warned then
			-- Back in charted waters: the leak stops (the dents stay until
			-- the next shoreline summon rebuilds the hull - REPAIR_ON_SUMMON).
			state.warned = false
		end
	end
end

-- ============================================================ lifecycle

-- Tier 1 rides Brinejaw's heart: BossService sets Heart_brinejaw on the
-- kill, DataService restores it on load, and both trip this one watcher.
-- Called from PlayerAdded AND for everyone already present when the service
-- starts; the `watched` set keeps a join in the init->start gap from
-- connecting twice (a dupe would be harmless - grantTier no-ops on an owned
-- tier - but one watcher per player is the honest shape).
local watched: { [Player]: boolean } = {}

local function watchHeart(player: Player)
	if watched[player] then
		return
	end
	watched[player] = true
	local function check()
		if player:GetAttribute("Heart_brinejaw") == true then
			BoatService.grantTier(player, 1)
		end
	end
	player:GetAttributeChangedSignal("Heart_brinejaw"):Connect(check)
	check()
end

function BoatService.init()
	boatFolder = Instance.new("Folder")
	boatFolder.Name = "Boats"
	boatFolder.Parent = Workspace

	Remotes.RequestBoat.OnServerEvent:Connect(onRequestBoat)

	Players.PlayerAdded:Connect(watchHeart)

	Players.PlayerRemoving:Connect(function(player)
		despawn(player)
		lastSummon[player] = nil
		lastHull[player] = nil
		watched[player] = nil
	end)
end

function BoatService.start()
	-- The boot contract: start() processes players already in the server -
	-- init()'s PlayerAdded alone would skip anyone who joined before this
	-- service came up, and they'd miss the Cove Skiff for the whole session.
	for _, player in Players:GetPlayers() do
		watchHeart(player)
	end

	task.spawn(function()
		while true do
			task.wait(1)
			seaworthinessTick()
		end
	end)
end

return BoatService
