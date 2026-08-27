--!nonstrict
-- WeaponService.luau
-- Puts the player's equipped weapon in their hand, for everyone else to see.
-- The twin of RodService: server-side so the weld replicates, welded to the
-- right hand with the grip centre in the palm, present only while the weapon
-- is what's equipped (InventoryService) AND the weapon row has a model -
-- bare fists weld nothing.
--
-- The owner never sees this copy: in first person Roblox hides their own
-- character, and WeaponViewmodelController draws a camera-pinned copy built
-- from the same row (the welded one carries the row id as a `WeaponId`
-- attribute, the way the rod carries `RodId`).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Equipment = require(Shared.Config.Equipment)
local Weapons = require(Shared.Data.Weapons)
local WeaponModel = require(Shared.Modules.WeaponModel)

local InventoryService = require(script.Parent.InventoryService)

local WeaponService = {}

-- Name of the weapon Model under the character.
WeaponService.EQUIPPED_NAME = "EquippedWeapon"

-- ============================================================ attaching

local function findHand(character: Model): BasePart?
	return character:WaitForChild("RightHand", 5) or character:FindFirstChild("Right Arm")
end

local function detachWeapon(character: Model)
	local existing = character:FindFirstChild(WeaponService.EQUIPPED_NAME)
	if existing then
		existing:Destroy()
	end
end

local function attachWeapon(character: Model, weaponData)
	local hand = findHand(character)
	if not hand then
		warn("[WeaponService] character has no hand part to hold a weapon")
		return
	end

	detachWeapon(character)

	local model = WeaponModel.build(weaponData)
	if not model then
		return
	end
	model.Name = WeaponService.EQUIPPED_NAME
	model:SetAttribute("WeaponId", weaponData.id)

	local grip = WeaponModel.findGrip(model)
	if not grip then
		warn(string.format("[WeaponService] weapon %q has no Weapon_Grip part", weaponData.id))
		model:Destroy()
		return
	end
	local gripCFrame = grip.CFrame

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			local relative = gripCFrame:ToObjectSpace(descendant.CFrame)
			-- Guns carry level (bore forward); melee defaults to the blade-up
			-- carry, but a row with a `hold` override (spears, the gauntlet)
			-- carries the way its viewmodel does - holdOffsetFor picks.
			descendant.CFrame = hand.CFrame * WeaponModel.holdOffsetFor(weaponData) * relative

			local weld = Instance.new("WeldConstraint")
			weld.Part0 = hand
			weld.Part1 = descendant
			weld.Parent = descendant
		end
	end

	model.Parent = character
end

-- Puts the character's hands in the state the loadout says.
local function applyLoadout(player: Player, character: Model)
	if InventoryService.getEquipped(player) ~= Equipment.WEAPON then
		detachWeapon(character)
		return
	end

	local weaponId = InventoryService.getEquippedWeapon(player)
	local weaponData = weaponId and Weapons.items[weaponId]
	if not weaponData or not weaponData.model then
		detachWeapon(character)
		return
	end
	attachWeapon(character, weaponData)
end

-- ============================================================ lifecycle

local function onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(function(character)
		applyLoadout(player, character)
	end)
	if player.Character then
		applyLoadout(player, player.Character)
	end
end

function WeaponService.init()
	InventoryService.onEquipChanged(function(player: Player, _kind: string)
		local character = player.Character
		if character then
			applyLoadout(player, character)
		end
	end)
end

function WeaponService.start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return WeaponService
