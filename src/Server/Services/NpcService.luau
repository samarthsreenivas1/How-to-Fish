--!nonstrict
-- NpcService.luau
-- The islands' named characters (Npcs.luau): stationary bodies with a
-- nameplate and a ProximityPrompt. Pressing the prompt opens dialog - the
-- prompt's Triggered fires SERVER-side, so the server owns the whole
-- handshake: it pushes the pane over NpcDialog and handles the client's
-- NpcChoice replies, re-validating distance on every one (never trust the
-- pane the client claims to be in).
--
-- Bodies are CreatureModel builds parked OUTSIDE the Creatures folder: no
-- creature struct, no AI tick, no combat - an NPC is scenery that talks.
-- All parts are anchored and non-collidable (the no-prop-walls rule; the
-- prompt doesn't need collision). Deliberately NOT CreatureService.spawn:
-- that would buy an update loop and targeting exemptions we'd immediately
-- have to fight.
--
-- A1 ships the greeting pane with a single farewell choice; quest offer /
-- turn-in panes arrive with QuestService (A2), the shop pane with C4.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Islands = require(Shared.Config.Islands)
local Npcs = require(Shared.Data.Npcs)
local Quests = require(Shared.Data.Quests)
local Shops = require(Shared.Data.Shops)
local Armor = require(Shared.Data.Armor)
local Trinkets = require(Shared.Data.Trinkets)
local Bait = require(Shared.Data.Bait)
local Creatures = require(Shared.Data.Creatures)
local Materials = require(Shared.Data.Materials)
local Remotes = require(Shared.Net.Remotes)
local CreatureModel = require(Shared.Modules.CreatureModel)

local QuestService = require(script.Parent.QuestService)
local MaterialService = require(script.Parent.MaterialService)
local BaitService = require(script.Parent.BaitService)
local DataService = require(script.Parent.DataService)
local InventoryService = require(script.Parent.InventoryService)

-- ProgressionService boots below us in ORDER (it listens to Killed);
-- spendCoins has no init-order dependence - the QuestService precedent.
local ProgressionService = nil
local function progression()
	if not ProgressionService then
		ProgressionService = require(script.Parent.ProgressionService)
	end
	return ProgressionService
end

local NpcService = {}

-- How far from the NPC a prompt press (or a dialog choice) is honoured.
-- The prompt itself shows at PROMPT_RANGE; the server allows a little
-- drift past it before it stops listening.
local PROMPT_RANGE = 12
local TALK_RANGE = 24

-- A warm, living palette painted over the stand-in bodies (the CreaturePack
-- bipeds are authored as drowned hostiles; an NPC must not read as one).
local BODY_COLORS: { [string]: Color3 } = {
	Fish_Body = Color3.fromRGB(196, 156, 116), -- weathered skin
	Fish_Fins = Color3.fromRGB(94, 82, 120), -- oilskin clothes
	Fish_Eyes = Color3.fromRGB(40, 36, 32),
	Fish_Marks = Color3.fromRGB(228, 206, 148), -- lantern-warm trim
}

local placed: { [string]: Model } = {}

-- ============================================================ body

local function probeGroundY(x: number, z: number): number?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	local world = Workspace:FindFirstChild("World")
	if not world then
		return nil
	end
	params.FilterDescendantsInstances = { world }
	local hit = Workspace:Raycast(Vector3.new(x, 120, z), Vector3.new(0, -240, 0), params)
	return hit and hit.Position.Y
end

local function buildBody(npc): Model?
	-- A minimal creature-row shape: build() reads row.id (model name) and
	-- row.body; BODY_COLORS repaints whatever colorParts defaulted to.
	local model = CreatureModel.build({ id = "Npc_" .. npc.id, body = npc.body })
	if not model then
		return nil
	end
	if npc.body.scale and npc.body.scale ~= 1 then
		model:ScaleTo(npc.body.scale)
	end
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			local recolor = BODY_COLORS[part.Name]
			if recolor then
				part.Color = recolor
				part.Material = Enum.Material.SmoothPlastic
			end
		end
	end
	model.Name = "Npc_" .. npc.id
	return model
end

local function addNameplate(npc, model: Model, height: number)
	local root = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
	if not root then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "Nameplate"
	gui.Size = UDim2.fromOffset(220, 44)
	gui.StudsOffsetWorldSpace = Vector3.new(0, height + 1.6, 0)
	gui.MaxDistance = 70
	gui.AlwaysOnTop = false
	local name = Instance.new("TextLabel")
	name.BackgroundTransparency = 1
	name.Size = UDim2.new(1, 0, 0, 26)
	name.Font = Enum.Font.GothamBold
	name.TextSize = 19
	name.TextColor3 = Color3.fromRGB(255, 244, 214)
	name.TextStrokeTransparency = 0.2
	name.Text = npc.name
	name.Parent = gui
	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.new(0, 0, 0, 24)
	title.Size = UDim2.new(1, 0, 0, 18)
	title.Font = Enum.Font.Gotham
	title.TextSize = 13
	title.TextColor3 = Color3.fromRGB(214, 224, 206)
	title.TextStrokeTransparency = 0.4
	title.Text = npc.title
	title.Parent = gui
	gui.Parent = root
end

-- ============================================================ dialog

-- Player-facing text for an objective / a reward bundle. Server-built so
-- the client stays a dumb renderer.
local function objectiveText(objective): string
	if objective.type == "catch" or objective.type == "kill" then
		local what = "creatures"
		if objective.species then
			local row = Creatures.items[objective.species]
			what = row and row.name or objective.species
		elseif objective.rarity then
			what = objective.rarity .. " catches"
		end
		local where = if objective.waters then string.format(" from %s waters", objective.waters) else ""
		local verb = if objective.type == "catch" then "Catch" else "Slay"
		return string.format("%s %d %s%s", verb, objective.count or 1, what, where)
	end
	if objective.type == "craft" then
		return string.format("Craft: %s", tostring(objective.itemId))
	end
	if objective.type == "deliver" then
		local parts = {}
		for matId, amount in objective.materials or {} do
			local row = Materials.items[matId]
			table.insert(parts, string.format("%d %s", amount, row and row.name or matId))
		end
		return "Bring me " .. table.concat(parts, ", ")
	end
	if objective.type == "visit" then
		local entry = Islands.items[objective.island]
		return string.format("Set foot on %s", entry and entry.name or tostring(objective.island))
	end
	return "?"
end

local function rewardText(rewards): string
	local parts = {}
	if rewards.coins then
		table.insert(parts, string.format("%d coins", rewards.coins))
	end
	if rewards.xp then
		table.insert(parts, string.format("%d XP", rewards.xp))
	end
	for matId, amount in rewards.materials or {} do
		local row = Materials.items[matId]
		table.insert(parts, string.format("%d %s", amount, row and row.name or matId))
	end
	for baitId, amount in rewards.bait or {} do
		table.insert(parts, string.format("%d %s", amount, baitId))
	end
	for _, itemId in rewards.items or {} do
		local row = Armor.items[itemId] or Trinkets.items[itemId]
		table.insert(parts, row and row.name or itemId)
	end
	if #parts == 0 then
		return ""
	end
	return "Reward: " .. table.concat(parts, ", ")
end

-- Today's full shelf list for a shop: the fixed stock plus `rotating.slots`
-- picks from the pool, drawn WITHOUT replacement by a Random seeded from the
-- UTC day and the shop id - deterministic, so a buy re-derives the identical
-- shelves and nothing needs storing. Rolls over at midnight UTC.
local function stockToday(shop): { any }
	local shelves = table.clone(shop.stock)
	local rotating = shop.rotating
	if rotating and rotating.slots > 0 and #rotating.pool > 0 then
		local seed = math.floor(os.time() / 86400) * 131
		for i = 1, #shop.id do
			seed += string.byte(shop.id, i) * i
		end
		local rng = Random.new(seed)
		local pool = table.clone(rotating.pool)
		for _ = 1, math.min(rotating.slots, #pool) do
			local pick = rng:NextInteger(1, #pool)
			table.insert(shelves, pool[pick])
			table.remove(pool, pick)
		end
	end
	return shelves
end

-- A shop slot's shelf label ("5x Chum - 60c").
local function slotText(slot): string
	local name = slot.id
	if slot.kind == "bait" then
		local row = Bait.items[slot.id]
		name = row and row.name or slot.id
	elseif slot.kind == "material" then
		local row = Materials.items[slot.id]
		name = row and row.name or slot.id
	elseif slot.kind == "item" then
		-- A finished thing (armor piece, rod, weapon, trinket): one grant,
		-- no amount on the shelf label.
		local row = Armor.items[slot.id] or Trinkets.items[slot.id]
		name = row and row.name or slot.id
		return string.format("%s - %d coins", name, slot.price)
	end
	return string.format("%dx %s - %d coins", slot.amount, name, slot.price)
end

-- The shop pane: the stall's shelves as buy buttons. `remark` carries the
-- outcome of the last purchase ("There you go." / "Short on coin, love.").
local function sendShop(player: Player, npc, remark: string?)
	local shop = npc.shop and Shops.items[npc.shop]
	if not shop then
		return
	end
	local lines = {}
	if remark then
		table.insert(lines, remark)
	end
	table.insert(lines, "Have a look, then. Coin up front.")
	local choices = {}
	for index, slot in stockToday(shop) do
		table.insert(choices, { id = "buy:" .. index, label = slotText(slot) })
	end
	table.insert(choices, { id = "back", label = "Done" })
	Remotes.NpcDialog:FireClient(player, {
		npcId = npc.id,
		name = npc.name,
		title = npc.title,
		pane = "shop",
		lines = lines,
		choices = choices,
	})
end

-- One purchase: re-derive the slot server-side (the client only ever names
-- an index), check + spend coins, grant, answer with a fresh shop pane.
local function buySlot(player: Player, npc, index: number)
	local shop = npc.shop and Shops.items[npc.shop]
	local slot = shop and stockToday(shop)[index]
	if not slot or not DataService.isLoaded(player) then
		return
	end
	if slot.kind == "item" then
		-- Owned already? Refuse BEFORE coins move.
		if InventoryService.ownsItem(player, slot.id) then
			sendShop(player, npc, "You've already got one of those, love.")
			return
		end
	end
	if not progression().spendCoins(player, slot.price) then
		sendShop(player, npc, "Short on coin, love. Come back heavier.")
		return
	end
	if slot.kind == "bait" then
		BaitService.grant(player, slot.id, slot.amount)
	elseif slot.kind == "material" then
		MaterialService.grant(player, slot.id, slot.amount)
	elseif slot.kind == "item" then
		InventoryService.grantItem(player, slot.id)
	end
	sendShop(player, npc, "There you go. Anything else?")
end

-- The greeting pane: the NPC's lines (plus an optional leading remark from
-- whatever just happened), then a button per offerable/ready quest, then
-- farewell. A fresh push re-renders the client's window - that IS the pane
-- machine; the server never trusts what the client claims to be looking at.
local function sendGreeting(player: Player, npc, remark: string?)
	local lines = {}
	if remark then
		table.insert(lines, remark)
	end
	for _, line in npc.greeting do
		table.insert(lines, line)
	end
	local choices = {}
	for _, offer in QuestService.offersFor(player, npc) do
		if offer.status == "available" then
			table.insert(choices, {
				id = "offer:" .. offer.quest.id,
				label = string.format('"%s"', offer.quest.name),
			})
		elseif offer.status == "active" and offer.ready then
			table.insert(choices, {
				id = "turnin:" .. offer.quest.id,
				label = string.format("Turn in: %s", offer.quest.name),
			})
		elseif offer.status == "active" then
			table.insert(
				lines,
				string.format('(Still at work on "%s", I see. Come back when it\'s done.)', offer.quest.name)
			)
		end
	end
	if npc.shop and Shops.items[npc.shop] then
		table.insert(choices, { id = "shop", label = "Browse wares" })
	end
	table.insert(choices, { id = "farewell", label = "Farewell" })
	Remotes.NpcDialog:FireClient(player, {
		npcId = npc.id,
		name = npc.name,
		title = npc.title,
		pane = "greeting",
		lines = lines,
		choices = choices,
	})
end

-- The offer pane: the pitch, the terms, accept or step back.
local function sendOffer(player: Player, npc, quest)
	local lines = { quest.blurb, "" }
	for _, objective in quest.objectives do
		table.insert(lines, "- " .. objectiveText(objective))
	end
	local rewards = rewardText(quest.rewards or {})
	if rewards ~= "" then
		table.insert(lines, "")
		table.insert(lines, rewards)
	end
	Remotes.NpcDialog:FireClient(player, {
		npcId = npc.id,
		name = npc.name,
		title = npc.title,
		pane = "offer",
		lines = lines,
		choices = {
			{ id = "accept:" .. quest.id, label = "I'll do it" },
			{ id = "back", label = "Not now" },
		},
	})
end

local function npcPosition(npcId: string): Vector3?
	local model = placed[npcId]
	if not model then
		return nil
	end
	return model:GetPivot().Position
end

local function playerNear(player: Player, npcId: string, range: number): boolean
	local at = npcPosition(npcId)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (at and root) then
		return false
	end
	return (root.Position - at).Magnitude <= range
end

local function onChoice(player: Player, npcId, choiceId)
	local npc = type(npcId) == "string" and Npcs.items[npcId]
	if not npc or type(choiceId) ~= "string" or not playerNear(player, npc.id, TALK_RANGE) then
		return
	end
	if choiceId == "farewell" then
		return -- the client closes its own modal
	end
	if choiceId == "back" then
		sendGreeting(player, npc)
		return
	end
	if choiceId == "shop" then
		sendShop(player, npc)
		return
	end
	local buyIndex = string.match(choiceId, "^buy:(%d+)$")
	if buyIndex then
		buySlot(player, npc, tonumber(buyIndex))
		return
	end
	local action, questId = string.match(choiceId, "^(%w+):(.+)$")
	local quest = questId and Quests.items[questId]
	-- Only quests THIS npc gives are actionable here (a forged id for
	-- another giver's quest is ignored).
	local isGivers = false
	for _, id in npc.quests or {} do
		if id == questId then
			isGivers = true
		end
	end
	if not (quest and isGivers) then
		return
	end
	if action == "offer" then
		sendOffer(player, npc, quest)
	elseif action == "accept" then
		if QuestService.accept(player, questId) then
			sendGreeting(player, npc, "Then it's settled. Off you go.")
		else
			sendGreeting(player, npc)
		end
	elseif action == "turnin" then
		local ok, reason = QuestService.tryTurnIn(player, questId)
		if ok then
			sendGreeting(player, npc, string.format('Ha! Knew you had it in you. That squares "%s".', quest.name))
		else
			sendGreeting(player, npc, reason or "Not yet, love.")
		end
	end
end

-- ============================================================ placement

local function placeNpc(npc)
	local entry = Islands.items[npc.island]
	if not entry then
		warn(string.format("[NpcService] NPC %q names unknown island %q", npc.id, npc.island))
		return
	end
	local spawn = entry.spawn
	local x = spawn.X + npc.spawnOffset.X
	local z = spawn.Z + npc.spawnOffset.Z
	local groundY = probeGroundY(x, z)
	if not groundY then
		-- The island's mesh isn't imported/placed; the NPC waits for the next
		-- server boot after the import (same rule as the island itself).
		return
	end

	local model = buildBody(npc)
	if not model then
		return
	end
	local _, size = model:GetBoundingBox()
	model:PivotTo(CFrame.new(x, groundY + size.Y * 0.5, z) * CFrame.Angles(0, math.rad(npc.facing), 0))
	addNameplate(npc, model, size.Y * 0.5)

	local root = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
	if root then
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "TalkPrompt"
		prompt.ActionText = "Talk"
		prompt.ObjectText = npc.name
		prompt.MaxActivationDistance = PROMPT_RANGE
		prompt.RequiresLineOfSight = false
		prompt.Triggered:Connect(function(player)
			if playerNear(player, npc.id, PROMPT_RANGE + 6) then
				sendGreeting(player, npc)
			end
		end)
		prompt.Parent = root
	end

	model.Parent = Workspace
	placed[npc.id] = model
end

-- ============================================================ lifecycle

function NpcService.init()
	Remotes.NpcChoice.OnServerEvent:Connect(onChoice)
end

function NpcService.start()
	for _, npc in Npcs.items do
		placeNpc(npc)
	end
end

return NpcService
