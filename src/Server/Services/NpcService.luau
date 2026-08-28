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
local Remotes = require(Shared.Net.Remotes)
local CreatureModel = require(Shared.Modules.CreatureModel)

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

-- The pane push. A1: one pane ("greeting") with one choice. The choice list
-- is data the client renders as buttons and echoes back by id - the server
-- decides what each id does, so a forged id is just ignored.
local function sendGreeting(player: Player, npc)
	Remotes.NpcDialog:FireClient(player, {
		npcId = npc.id,
		name = npc.name,
		title = npc.title,
		pane = "greeting",
		lines = npc.greeting,
		choices = {
			{ id = "farewell", label = "Farewell" },
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
	if not npc or not playerNear(player, npc.id, TALK_RANGE) then
		return
	end
	if choiceId == "farewell" then
		-- Nothing server-side yet: the client closes its own modal. Quest
		-- accept / turn-in / shop choices land here with their slices.
		return
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
