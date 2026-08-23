--!nonstrict
-- EquipController.luau
-- Hotkeys for what's in your hands: 1 = rod, 2 = weapon (the fists until
-- something better is crafted and picked in the crafting menu).
--
-- This only asks. InventoryService owns the choice (and refuses a rod the
-- player doesn't have); the answer comes back as the Player's replicated
-- `Equipped` attribute, which the viewmodel controllers and FishingController
-- watch. Nothing is predicted client-side - a swap is cheap, and flashing the
-- wrong hands on a refused request would look worse than a few ms of delay.
--
-- ContextActionService rather than InputBegan, for the same reason as every
-- other hotkey here (see context.md): Roblox's own scripts bind keys through
-- it and mark them game-processed.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Equipment = require(Shared.Config.Equipment)
local Remotes = require(Shared.Net.Remotes)

local player = Players.LocalPlayer

local EquipController = {}

local HOTKEYS = {
	{ key = Enum.KeyCode.One, kind = Equipment.ROD },
	{ key = Enum.KeyCode.Two, kind = Equipment.WEAPON },
}

function EquipController.getEquipped(): string?
	return player:GetAttribute(Equipment.ATTRIBUTE)
end

local function request(kind: string)
	if EquipController.getEquipped() == kind then
		return
	end
	Remotes.RequestEquip:FireServer(kind)
end

function EquipController.init() end

function EquipController.start()
	for _, hotkey in HOTKEYS do
		ContextActionService:BindActionAtPriority("Equip_" .. hotkey.kind, function(_, state)
			if state == Enum.UserInputState.Begin then
				request(hotkey.kind)
			end
			return Enum.ContextActionResult.Sink
		end, false, Enum.ContextActionPriority.High.Value, hotkey.key)
	end
end

return EquipController
