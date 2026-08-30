--!nonstrict
-- TrophyShelfController.luau
-- The boat's trophy shelf: every boat (BoatService) carries a Model named
-- "TrophyShelf" with six Attachments "HeartMount1".."HeartMount6" ordered
-- bow to stern - one mount per island boss, in saga order. This controller
-- decorates those mounts on every boat it sees: a glowing heart orb in the
-- boss's colour where the boat's OWNER has that Heart_<bossId> attribute, a
-- dim glass bead where they don't. Pure decoration, entirely client-side,
-- rebuilt whenever a boat appears or an owner's hearts change.
--
-- Contracts: the boat Model carries an "OwnerUserId" number attribute
-- (BoatService stamps it); hearts are the replicated Heart_* attributes
-- BossService sets. Saga order comes from Islands.order plus gate level,
-- exactly like the Trophy Hall - the six island bosses only (the Kraken's
-- own heart has no mount; it IS the trophy run's end).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Islands = require(Shared.Config.Islands)
local Bosses = require(Shared.Data.Bosses)

local TrophyShelfController = {}

local SHELF_NAME = "TrophyShelf"
local MOUNT_PREFIX = "HeartMount"
local MOUNT_COUNT = 6
local HEART_ATTRIBUTE_PREFIX = "Heart_"
local OWNER_ATTRIBUTE = "OwnerUserId"

local ORB_NAME = "HeartOrb"
local ORB_SIZE = 0.9
local DIM_COLOR = Color3.fromRGB(70, 80, 90)

-- Kept in step with TrophyController.HEART_COLORS.
local HEART_COLORS: { [string]: Color3 } = {
	brinejaw = Color3.fromRGB(64, 190, 200),
	old_gnashroot = Color3.fromRGB(150, 235, 200), -- the gnashroot core
	rimefang = Color3.fromRGB(120, 190, 255),
	pyrelisk = Color3.fromRGB(255, 128, 48),
	noctyss = Color3.fromRGB(150, 110, 235),
	admiral_wrack = Color3.fromRGB(140, 205, 160),
}
local HEART_DEFAULT = Color3.fromRGB(150, 110, 235)

-- shelf Model -> the connections watching its owner, for cleanup.
local watched: { [Model]: { RBXScriptConnection } } = {}

-- ============================================================ helpers

-- The six island bosses in saga order (Islands.order; the Kraken and any
-- other out-of-order boss has no shelf mount).
local function sagaBosses(): { string }
	local ordered = {}
	for _, islandId in Islands.order do
		local entry = Islands.items[islandId]
		local bossId = entry and entry.boss
		if bossId and Bosses.items[bossId] then
			table.insert(ordered, bossId)
		end
	end
	return ordered
end

local function ownerOf(shelf: Model): Player?
	local boat = shelf.Parent
	while boat and boat ~= workspace do
		if boat:IsA("Model") and boat:GetAttribute(OWNER_ATTRIBUTE) ~= nil then
			return Players:GetPlayerByUserId(boat:GetAttribute(OWNER_ATTRIBUTE))
		end
		boat = boat.Parent
	end
	return nil
end

-- ============================================================ render

local function orbAt(mount: Attachment): Part
	local existing = mount:FindFirstChild(ORB_NAME)
	if existing and existing:IsA("Part") then
		return existing
	end
	local orb = Instance.new("Part")
	orb.Name = ORB_NAME
	orb.Shape = Enum.PartType.Ball
	orb.Size = Vector3.new(ORB_SIZE, ORB_SIZE, ORB_SIZE)
	orb.CanCollide = false
	orb.CanQuery = false
	orb.CanTouch = false
	orb.Massless = true
	orb.CastShadow = false
	local light = Instance.new("PointLight")
	light.Name = "Glow"
	light.Range = 6
	light.Brightness = 0.8
	light.Parent = orb
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = orb
	weld.Part1 = mount.Parent
	weld.Parent = orb
	orb.CFrame = mount.WorldCFrame * CFrame.new(0, ORB_SIZE / 2, 0)
	orb.Parent = mount
	return orb
end

local function renderShelf(shelf: Model)
	local owner = ownerOf(shelf)
	local order = sagaBosses()
	for i = 1, MOUNT_COUNT do
		local mount = shelf:FindFirstChild(MOUNT_PREFIX .. i, true)
		if not (mount and mount:IsA("Attachment")) then
			continue
		end
		local bossId = order[i]
		local orb = orbAt(mount)
		local lit = bossId ~= nil and owner ~= nil and owner:GetAttribute(HEART_ATTRIBUTE_PREFIX .. bossId) == true
		if lit then
			orb.Color = HEART_COLORS[bossId] or HEART_DEFAULT
			orb.Material = Enum.Material.Neon
			orb.Transparency = 0
			orb.Glow.Color = orb.Color
			orb.Glow.Enabled = true
		else
			orb.Color = DIM_COLOR
			orb.Material = Enum.Material.Glass
			orb.Transparency = 0.45
			orb.Glow.Enabled = false
		end
	end
end

-- ============================================================ watch

local function unwatch(shelf: Model)
	local connections = watched[shelf]
	if not connections then
		return
	end
	for _, connection in connections do
		connection:Disconnect()
	end
	watched[shelf] = nil
end

local function watchShelf(shelf: Model)
	if watched[shelf] then
		return
	end
	renderShelf(shelf)
	local connections = {}
	local owner = ownerOf(shelf)
	if owner then
		table.insert(
			connections,
			owner.AttributeChanged:Connect(function(attribute: string)
				if string.sub(attribute, 1, #HEART_ATTRIBUTE_PREFIX) == HEART_ATTRIBUTE_PREFIX then
					renderShelf(shelf)
				end
			end)
		)
	end
	table.insert(
		connections,
		shelf.AncestryChanged:Connect(function(_, parent)
			if parent == nil then
				unwatch(shelf)
			end
		end)
	)
	watched[shelf] = connections
end

-- ============================================================ lifecycle

function TrophyShelfController.init()
	workspace.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("Model") and descendant.Name == SHELF_NAME then
			-- Wait a beat for the mounts + owner attribute to replicate.
			task.defer(watchShelf, descendant)
		end
	end)
end

function TrophyShelfController.start()
	for _, descendant in workspace:GetDescendants() do
		if descendant:IsA("Model") and descendant.Name == SHELF_NAME then
			watchShelf(descendant)
		end
	end
end

return TrophyShelfController
