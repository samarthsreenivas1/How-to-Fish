--!nonstrict
-- RodService.luau
-- Puts the player's equipped rod in their hand.
--
-- Server-side rather than client-side on purpose: a rod welded by the client
-- would only exist on that client, and everyone else on the island would see
-- empty hands. Welding here replicates it to all players for free.
--
-- The owning player never actually sees this copy: the game is first-person,
-- Roblox hides the character's own body (and anything parented to it) from
-- its own camera, and RodViewmodelController draws a camera-pinned copy
-- instead. This one is for everybody else.
--
-- The rod is only in the hand while the rod is what's equipped
-- (InventoryService). Switching to fists removes it - and because the
-- owner's viewmodel keys off this very model existing, that removal is also
-- what swaps their first-person view over.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Equipment = require(Shared.Config.Equipment)
local Rods = require(Shared.Data.Rods)
local RodModel = require(Shared.Modules.RodModel)

local InventoryService = require(script.Parent.InventoryService)

local RodService = {}

-- Name of the rod Model under the character. The client looks for this.
RodService.EQUIPPED_NAME = "EquippedRod"

-- ============================================================ attaching

local function findHand(character: Model): BasePart?
	-- R15 first; R6 has no separate hand, so the whole arm is the best we get.
	return character:WaitForChild("RightHand", 5) or character:FindFirstChild("Right Arm")
end

local function attachRod(character: Model, rodData)
	local hand = findHand(character)
	if not hand then
		warn("[RodService] character has no hand part to hold a rod")
		return
	end

	local existing = character:FindFirstChild(RodService.EQUIPPED_NAME)
	if existing then
		existing:Destroy()
	end

	local model = RodModel.build(rodData)
	model.Name = RodService.EQUIPPED_NAME
	-- The owner's client reads this to build its first-person viewmodel from
	-- the same row, rather than cloning this already-posed copy.
	model:SetAttribute("RodId", rodData.id)

	local grip = RodModel.findGrip(model)
	if not grip then
		warn(string.format("[RodService] rod model %q has no Rod_Grip part", rodData.model.model))
		model:Destroy()
		return
	end
	-- The grip's full CFrame, so the rod's authored +Y axis carries through
	-- the weld regardless of how the template happens to sit in the file.
	local gripCFrame = grip.CFrame

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			local relative = gripCFrame:ToObjectSpace(descendant.CFrame)
			descendant.CFrame = hand.CFrame * RodModel.HOLD_OFFSET * relative

			local weld = Instance.new("WeldConstraint")
			weld.Part0 = hand
			weld.Part1 = descendant
			weld.Parent = descendant
		end
	end

	model.Parent = character
end

local function detachRod(character: Model)
	local existing = character:FindFirstChild(RodService.EQUIPPED_NAME)
	if existing then
		existing:Destroy()
	end
end

-- Puts the character's hands in the state the loadout says.
local function applyLoadout(player: Player, character: Model)
	if InventoryService.getEquipped(player) ~= Equipment.ROD then
		detachRod(character)
		return
	end

	local rodId = InventoryService.getEquippedRod(player)
	local rodData = rodId and Rods.items[rodId]
	if not rodData then
		detachRod(character)
		return
	end
	attachRod(character, rodData)
end

-- ============================================================ lifecycle

local function onCharacterAdded(player: Player, character: Model)
	applyLoadout(player, character)
end

local function onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
	if player.Character then
		onCharacterAdded(player, player.Character)
	end
end

function RodService.init()
	InventoryService.onEquipChanged(function(player: Player, _kind: string)
		local character = player.Character
		if character then
			applyLoadout(player, character)
		end
	end)
end

function RodService.start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return RodService
