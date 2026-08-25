--!nonstrict
-- DropService.luau
-- Rare finished-item drops from killed creatures - the jackpot path. Most of
-- a creature's loot is materials (MaterialService) and coins/XP
-- (ProgressionService); this handles a creature row's optional `drops.items`,
-- a list of existing Rods/Weapons ids each with a small chance, granted
-- straight into the killer's inventory. A third listener on
-- CreatureService.Killed alongside the other two - it never touches their
-- material/coin payouts.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)

local CreatureService = require(script.Parent.CreatureService)
local InventoryService = require(script.Parent.InventoryService)

local DropService = {}

local function onKilled(row, _grade: string, killer: Player?, info)
	if not killer or killer.Parent ~= Players then
		return
	end
	-- Raid mobs (and any other suppressed spawn - an ooze's split halves) pay
	-- no finished-item jackpots: the raid's payout is its clear reward. Same
	-- flag MaterialService already honours.
	if type(info) == "table" and info.suppressDrops then
		return
	end
	local items = row.drops and row.drops.items
	if not items then
		return
	end

	for _, drop in items do
		-- A fresh grant only: grantItem is a no-op (and worthless) if already
		-- owned, so don't roll a dupe or announce one. Convert dupes to
		-- materials later if it matters.
		if math.random() < drop.chance and not InventoryService.ownsItem(killer, drop.id) then
			if InventoryService.grantItem(killer, drop.id) then
				Remotes.ItemDropped:FireClient(killer, drop.id)
			end
		end
	end
end

function DropService.init()
	CreatureService.Killed.Event:Connect(onKilled)
end

function DropService.start() end

return DropService
