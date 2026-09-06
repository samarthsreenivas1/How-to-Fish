--!nonstrict
-- BossHudController.luau
-- The island boss's presence on screen: a big named health bar across the
-- top while one is up, a title card when it rises, and the "ISLAND CLEARED"
-- card when it falls.
--
-- Everything it needs is already replicated: a boss is any creature Model in
-- Workspace.Creatures carrying the BossName attribute (CreatureService sets
-- it as the boss rises), and its Health / MaxHealth attributes drive the
-- bar; Enraged turns the bar red. The rise and fall cards come off the
-- CreatureEvent remote (bossRise / bossDown, with the boss's name and what
-- the win unlocked) - the same remote CreatureEventController draws from.
--
-- THE SEAL (2026-08-29). Two of the bosses cannot simply be attacked, and a
-- bar that just sits there while you empty a magazine into an invulnerable
-- boss is a bar that lies. Both cases are readable from data the client
-- already has, so the bar carries the fight's own rule:
--   * entrenched (Brinejaw) - `Bosses.items.*.entrenched`. It is untargetable
--     the whole time it holds its perch and only opens for an EARNED stagger,
--     which the server announces with the Exposed attribute on the model.
--   * a tentacle ring (the Kraken) - `Bosses.items.*.parts`. The head is
--     refused while any arm stands; the exposed / regrow events that already
--     draw its cards below are the same two edges, so they drive the bar too.
-- Anything else is an ordinary boss you can hit whenever you like, and its
-- bar behaves exactly as it did before - the seal must never read on a boss
-- that hasn't got one.
--
-- WHOSE FIGHT (2026-09-01). Everything below is scoped to the fight this
-- client is actually in - see "the bound" further down. The bar used to
-- belong to the NEAREST live boss with nothing bounding "nearest", and the
-- cards threw away the position they arrive with, so one party's summon put
-- a health bar across every screen in the server and told every player the
-- next island was open. That was survivable while the bosses fought beside
-- their islands; the lair arenas (Shared/Config/BossArenas) put them
-- thousands of studs out in open water and it stopped being survivable.
--
-- Sits below the fishing grade banner (y=40) and the level-up banner (y=84)
-- so the three never overlap.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local Bosses = require(Shared.Data.Bosses)

local Theme = require(script.Parent.Parent.UI.Theme)

local player = Players.LocalPlayer

local BossHudController = {}

-- Must match CreatureService; server modules aren't requireable here.
local CREATURES_FOLDER = "Creatures"
local ATTR_BOSS_NAME = "BossName"
local ATTR_HEALTH = "Health"
local ATTR_MAX_HEALTH = "MaxHealth"
local ATTR_ENRAGED = "Enraged"
local ATTR_CREATURE_ID = "CreatureId" -- the Creatures row id, our link into Bosses
local ATTR_EXPOSED = "Exposed" -- an entrenched boss's earned window is open

-- ---------------------------------------------------------------- layout

local BAR_Y = 124 -- below the grade (40) and level-up (84) banners
local BAR_WIDTH = 0.46 -- of the screen
local BAR_HEIGHT = 16
local NAME_SIZE = 20
local NAME_GAP = 6

local BAR_COLOR = Color3.fromRGB(120, 255, 214) -- the lure's glow
local BAR_RAGE_COLOR = Color3.fromRGB(255, 80, 60)
local BAR_BACK = Color3.fromRGB(14, 18, 24)
local BAR_FILL_TIME = 0.18

-- Sealed: cold plate, and the fill goes half-lit - the bar reads as switched
-- off, which is exactly what the health number is doing. Open: the gold the
-- exposure card already speaks in, at full brightness with the track's edge
-- breathing so it's caught out of the corner of an eye mid-dodge.
local BAR_SEALED_COLOR = Color3.fromRGB(126, 142, 160)
local BAR_SEALED_FADE = 0.2
local BAR_SEALED_STROKE = Color3.fromRGB(178, 194, 212)
local BAR_OPEN_COLOR = Theme.Color.gold
local STROKE_THIN = 1.5
local STROKE_OPEN = 3
local STROKE_PULSE = 4.5
local PULSE_TIME = 0.5
local STATUS_SIZE = 12

-- What the bar says in each state. Kept to the truth the engine actually
-- enforces: an entrenched boss refuses every hit until it staggers, and a
-- ringed head refuses every hit until the last arm is down.
local STATUS_OPEN = "EXPOSED - STRIKE NOW"
local STATUS_SEALED = {
	entrenched = "SEALED - HITS DO NOTHING UNTIL IT STAGGERS",
	ring = "SEALED - BRING THE ARMS DOWN FIRST",
}

local CARD_Y = 0.3 -- of the screen, for the rise / cleared cards
local CARD_TITLE_SIZE = 38
local CARD_SUB_SIZE = 18
local CARD_IN = 0.45
local CARD_HOLD = 2.6
local CARD_OUT = 0.6
-- The stagger card is on a short hold on purpose: the shortest punish window
-- in the game is 2.2 s (Brinejaw's slam on bare sand), and this has to be off
-- the screen inside that - both so it never says "strike now" at a boss that
-- has already stood back up, and so it isn't in the way while you spend it.
local CARD_HOLD_SHORT = 1.15

-- ---------------------------------------------------------------- state

local gui: ScreenGui
local barFrame: Frame
local barFill: Frame
local barStroke: UIStroke
local nameLabel: TextLabel
local statusLabel: TextLabel
local cardTitle: TextLabel
local cardSub: TextLabel

local current: Model? = nil
local connections: { RBXScriptConnection } = {}
local cardToken = 0

-- The tracked boss's Bosses row, its ward ("entrenched" / "ring" / nil for a
-- boss you can just hit), the ring's window if it has one, and the seal state
-- the bar is currently drawn in - the last of those only so the open EDGE can
-- raise a card without every health tick raising another.
local currentRow = nil
local ward: string? = nil
local ringOpen = false
local sealDrawn: string? = nil
local pulses: { Tween } = {}

-- The cards live at the bottom of the file, but a window opening is a card
-- and that is noticed up here in the bar's refresh.
local showCard

-- WHEN THIS CLIENT LAST HELD A GIVEN BOSS'S BAR, so the fall card can still
-- reach a fighter who is no longer standing there - the one who DIED. The
-- server pays the unlock to every player who damaged the boss, wherever they
-- ended up (BossService.onKilled builds `winners` from the damage
-- participants and never asks where they are), while dying puts you back at
-- the world spawn ~15k studs from the arena with no ride back. Distance
-- alone would therefore hand that player the island in silence. Consumed on
-- use, and short enough that it cannot speak for a fight long abandoned.
local ENGAGED_MEMORY = 300
local engagedAt: { [string]: number } = {}

-- A rise card can arrive BEFORE its audience does. BossService.summonFor
-- raises the boss FIRST and only then task.defers the party out to the arena,
-- so the event can be in flight while the challengers are still standing on
-- their island. Rather than guess from a position they have not reached yet,
-- the card waits for the bar: if this client picks that boss up within the
-- grace, the rise was ours after all.
local RISE_GRACE = 6
local pendingRise: { name: string, expires: number }? = nil

-- Creature row id -> its Bosses entry. The boss models carry CreatureId, and
-- BossName is a fallback for anything that somehow spawned without one.
local bossByCreature: { [string]: any } = {}
local bossByName: { [string]: any } = {}
for _, boss in Bosses.items do
	bossByCreature[boss.creature] = boss
	bossByName[boss.name] = boss
end

-- ---------------------------------------------------------------- build

local function label(parent: GuiObject, props: { [string]: any }): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = Theme.Font.header
	l.TextColor3 = Theme.Color.text
	l.TextStrokeColor3 = Color3.fromRGB(8, 12, 18)
	l.TextStrokeTransparency = 0.4
	l.TextXAlignment = Enum.TextXAlignment.Center
	for key, value in props do
		l[key] = value
	end
	l.Parent = parent
	return l
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "BossHudGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 5

	-- The bar: a name above a thin wide bar, centred near the top.
	barFrame = Instance.new("Frame")
	barFrame.Name = "BossBar"
	barFrame.AnchorPoint = Vector2.new(0.5, 0)
	barFrame.Position = UDim2.new(0.5, 0, 0, BAR_Y)
	barFrame.Size = UDim2.new(BAR_WIDTH, 0, 0, NAME_SIZE + NAME_GAP + BAR_HEIGHT)
	barFrame.BackgroundTransparency = 1
	barFrame.Visible = false
	barFrame.Parent = gui

	nameLabel = label(barFrame, {
		Name = "Name",
		Size = UDim2.new(1, 0, 0, NAME_SIZE),
		TextSize = NAME_SIZE,
		Text = "",
	})

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0.5, 1)
	track.Position = UDim2.new(0.5, 0, 1, 0)
	track.Size = UDim2.new(1, 0, 0, BAR_HEIGHT)
	track.BackgroundColor3 = BAR_BACK
	track.BackgroundTransparency = 0.25
	track.BorderSizePixel = 0
	track.Parent = barFrame
	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(0, 4)
	trackCorner.Parent = track
	barStroke = Instance.new("UIStroke")
	barStroke.Color = Theme.Color.border
	barStroke.Thickness = STROKE_THIN
	barStroke.Parent = track

	barFill = Instance.new("Frame")
	barFill.Name = "Fill"
	barFill.Size = UDim2.fromScale(1, 1)
	barFill.BackgroundColor3 = BAR_COLOR
	barFill.BorderSizePixel = 0
	barFill.Parent = track
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 4)
	fillCorner.Parent = barFill

	-- The seal's line, written across the bar itself rather than beside it:
	-- nothing moves when it appears, so the three banners stacked above stay
	-- where they are. Empty (and invisible) on a boss with no seal.
	statusLabel = label(track, {
		Name = "Status",
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
		TextSize = STATUS_SIZE,
		TextStrokeTransparency = 0.25,
		Text = "",
		TextTransparency = 1,
	})

	-- The rise / cleared cards.
	cardTitle = label(gui, {
		Name = "CardTitle",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, CARD_Y),
		Size = UDim2.new(1, 0, 0, CARD_TITLE_SIZE + 6),
		TextSize = CARD_TITLE_SIZE,
		Text = "",
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	})
	cardSub = label(gui, {
		Name = "CardSub",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, CARD_Y, CARD_TITLE_SIZE / 2 + 8),
		Size = UDim2.new(1, 0, 0, CARD_SUB_SIZE + 4),
		Font = Theme.Font.body,
		TextSize = CARD_SUB_SIZE,
		TextColor3 = Theme.Color.textDim,
		Text = "",
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	})

	gui.Parent = player:WaitForChild("PlayerGui")
end

-- ---------------------------------------------------------------- the bar

-- Which Bosses entry this model is, by row id first and title second.
local function rowFor(model: Model)
	local id = model:GetAttribute(ATTR_CREATURE_ID)
	if type(id) == "string" and bossByCreature[id] then
		return bossByCreature[id]
	end
	local name = model:GetAttribute(ATTR_BOSS_NAME)
	return if type(name) == "string" then bossByName[name] else nil
end

-- Both wards come straight out of the shared data the server fights by:
-- `entrenched` holds a perch and opens only for an earned stagger, `parts` is
-- a ring of arms standing between you and the head. A row with neither is a
-- boss you can hit whenever you like.
local function wardOf(row): string?
	if row == nil then
		return nil
	elseif row.entrenched then
		return "entrenched"
	elseif row.parts then
		return "ring"
	end
	return nil
end

-- "open" (hit it NOW) / "sealed" (nothing gets through) / nil (an ordinary
-- boss, no seal to draw).
local function sealOf(model: Model): string?
	if ward == "entrenched" then
		return if model:GetAttribute(ATTR_EXPOSED) == true then "open" else "sealed"
	elseif ward == "ring" then
		-- The head's window carries no attribute today, so its two events are
		-- the signal; if one is ever published, it counts as well.
		local exposed = ringOpen or model:GetAttribute(ATTR_EXPOSED) == true
		return if exposed then "open" else "sealed"
	end
	return nil
end

local function stopPulse()
	for _, tween in pulses do
		tween:Cancel()
	end
	table.clear(pulses)
end

-- Two properties breathing together while the window is open.
local function startPulse()
	local info = TweenInfo.new(PULSE_TIME, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	table.insert(pulses, TweenService:Create(barStroke, info, { Thickness = STROKE_PULSE }))
	table.insert(pulses, TweenService:Create(statusLabel, info, { TextTransparency = 0.55 }))
	for _, tween in pulses do
		tween:Play()
	end
end

-- Paint the seal. Only ever called on a CHANGE, so the pulse isn't restarted
-- every time a point of health lands.
local function drawSeal(seal: string?)
	stopPulse()
	if seal == "open" then
		barStroke.Color = BAR_OPEN_COLOR
		barStroke.Thickness = STROKE_OPEN
		statusLabel.Text = STATUS_OPEN
		statusLabel.TextTransparency = 0
		startPulse()
	elseif seal == "sealed" then
		barStroke.Color = BAR_SEALED_STROKE
		barStroke.Thickness = STROKE_THIN
		statusLabel.Text = STATUS_SEALED[ward] or "SEALED"
		statusLabel.TextTransparency = 0
	else
		barStroke.Color = Theme.Color.border
		barStroke.Thickness = STROKE_THIN
		statusLabel.Text = ""
		statusLabel.TextTransparency = 1
	end
end

local function refresh()
	local model = current
	if not model then
		return
	end
	local health = tonumber(model:GetAttribute(ATTR_HEALTH)) or 0
	local maxHealth = math.max(1, tonumber(model:GetAttribute(ATTR_MAX_HEALTH)) or 1)
	TweenService:Create(barFill, TweenInfo.new(BAR_FILL_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.fromScale(math.clamp(health / maxHealth, 0, 1), 1),
	}):Play()
	local enraged = model:GetAttribute(ATTR_ENRAGED) == true
	-- The seal outranks the rage on the FILL - whether you can hurt it at all
	-- matters more than how angry it is - but the name keeps carrying the
	-- rage, so neither piece of news is lost.
	local seal = sealOf(model)
	if seal == "open" then
		barFill.BackgroundColor3 = BAR_OPEN_COLOR
	elseif seal == "sealed" then
		barFill.BackgroundColor3 = BAR_SEALED_COLOR
	else
		barFill.BackgroundColor3 = if enraged then BAR_RAGE_COLOR else BAR_COLOR
	end
	barFill.BackgroundTransparency = if seal == "sealed" then BAR_SEALED_FADE else 0
	nameLabel.TextColor3 = if enraged then BAR_RAGE_COLOR else Theme.Color.text

	if seal ~= sealDrawn then
		sealDrawn = seal
		drawSeal(seal)
		-- The window opening is the fight's best moment: say so out loud,
		-- the same way the Kraken's own exposure card does below (that one
		-- comes off the event, so a ringed boss is announced once, not twice).
		if seal == "open" and ward == "entrenched" then
			local short = currentRow and currentRow.shortName or model:GetAttribute(ATTR_BOSS_NAME) or "THE BOSS"
			showCard(
				string.upper(tostring(short)) .. " STAGGERS",
				"its grip fails - strike now",
				Theme.Color.gold,
				CARD_HOLD_SHORT
			)
		end
	end
end

local function untrack()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	current = nil
	currentRow = nil
	ward = nil
	ringOpen = false
	sealDrawn = nil
	drawSeal(nil)
	barFrame.Visible = false
end

local function track(model: Model)
	untrack()
	current = model
	currentRow = rowFor(model)
	ward = wardOf(currentRow)
	nameLabel.Text = string.upper(tostring(model:GetAttribute(ATTR_BOSS_NAME) or "BOSS"))
	barFill.Size = UDim2.fromScale(1, 1)
	barFrame.Visible = true
	for _, attr in { ATTR_HEALTH, ATTR_MAX_HEALTH, ATTR_ENRAGED, ATTR_EXPOSED } do
		table.insert(connections, model:GetAttributeChangedSignal(attr):Connect(refresh))
	end
	-- Draw whatever state it's already in without carding it: picking the bar
	-- up mid-window is not the window opening.
	sealDrawn = sealOf(model)
	drawSeal(sealDrawn)
	refresh()

	-- The rise that was in flight before we got here (RISE_GRACE): taking up
	-- this boss's bar is the proof it was addressed to us.
	if pendingRise then
		local mine = model:GetAttribute(ATTR_BOSS_NAME)
		if os.clock() > pendingRise.expires then
			pendingRise = nil
		elseif type(mine) == "string" and pendingRise.name == mine then
			local name = pendingRise.name
			pendingRise = nil
			showCard(string.upper(name), "rises from the deep", BAR_COLOR)
		end
	end
end

-- ---------------------------------------------------------------- the bound
--
-- With seven islands, several bosses can be alive at once, and the bar
-- belongs to the nearest one - but only if that one is CLOSE, which is the
-- half this used to be missing. "Nearest" with nothing bounding it was a
-- safe answer only while every boss fought beside its own island, 3000 studs
-- from the next; the lair arenas (Shared/Config/BossArenas) moved them
-- thousands of studs out into open water, and an unbounded nearest then
-- handed every client in the server a bar for a fight it was nowhere near.
--
-- Measured from the CAMERA, which is what CreatureEventController gates its
-- own effects on (`nearCamera`) and for the reason it gives there: a player
-- watching from a boat or waiting to respawn is still at the fight and their
-- character is not. Horizontal only - an arena floor can be 292 studs up
-- (the Ashfall Throne) and the Kraken sits down in a whirlpool.
--
--   ENGAGE    - how close a boss must be to be PICKED UP.
--   DISENGAGE - how far the one already held must get to be DROPPED. The
--               gap between them is hysteresis: a bar must not flicker off
--               and on while you fight along a boundary.
--
-- Both are enormous next to any fight and small next to the gap between two
-- fights, which is what makes them safe in BOTH directions:
--   * the widest a fight ever gets is the Ashfall Throne. Pyrelisk is
--     entrenched at the centre, the walkable rim path runs to r232 and its
--     longest rake reads r250 (Bosses.luau) - so a legitimate fighter is at
--     most ~250 studs from the boss. Every other arena roams inside r152 and
--     sets its party down on a ring of radius + 8 (BossService.summonFor).
--   * the two closest arena centres are the swamp's (22200, 9000) and the
--     volcano's (23400, 5200): 3985 studs apart, and BossArenas guarantees
--     every arena 8k+ studs of clear water to the nearest island. So a
--     player standing in one fight is >3700 studs from any other boss.
-- 250 and 3700 leave a wide band, and these two numbers sit in the middle of
-- it; there is no value in between for them to collide on.
local ENGAGE_RADIUS = 1000
local DISENGAGE_RADIUS = 1800
local RETARGET_INTERVAL = 0.5

local creaturesFolder: Instance? = nil
local camera = Workspace.CurrentCamera

-- Where this player is watching from, or nil if there is nothing to ask yet.
local function viewPoint(): Vector3?
	local cam = camera or Workspace.CurrentCamera
	if cam then
		camera = cam
		return cam.CFrame.Position
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root.Position else nil
end

local function flatDistance(a: Vector3, b: Vector3): number
	return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
end

-- Is `position` the fight this player is in? What the cards ask, on the
-- generous radius - a card is a moment, not a fixture on the screen.
local function atMyFight(position: Vector3?): boolean
	if typeof(position) ~= "Vector3" then
		return false
	end
	local from = viewPoint()
	return from ~= nil and flatDistance(from, position) <= DISENGAGE_RADIUS
end

-- Every add / remove / tick RE-TARGETS instead of last-writer-wins: a boss
-- dying elsewhere must never hide the bar of the one still trying to eat you
-- (review finding, 2026-08-25). The boss already held is measured against the
-- wider radius, so holding it is strictly easier than picking it up.
local function nearestBoss(): Model?
	if not creaturesFolder then
		return nil
	end
	local from = viewPoint()
	if not from then
		-- Nowhere to measure from. Hold whatever the bar has rather than
		-- guess: dropping it here would be losing your bar for nothing.
		return current
	end
	local best: Model? = nil
	local bestDist = math.huge
	for _, child in creaturesFolder:GetChildren() do
		if child:IsA("Model") and child:GetAttribute(ATTR_BOSS_NAME) then
			local dist = flatDistance(child:GetPivot().Position, from)
			local limit = if child == current then DISENGAGE_RADIUS else ENGAGE_RADIUS
			if dist <= limit and dist < bestDist then
				best = child
				bestDist = dist
			end
		end
	end
	return best
end

local function retarget()
	local best = nearestBoss()
	if best ~= current then
		if best then
			track(best)
		else
			untrack()
		end
	end
	-- Holding the bar is what "I am in this fight" MEANS on this client, so
	-- that is where the fall card's memory is written from (ENGAGED_MEMORY).
	if current then
		local name = current:GetAttribute(ATTR_BOSS_NAME)
		if type(name) == "string" then
			engagedAt[name] = os.clock()
		end
	end
end

-- A creature becomes a boss the moment its BossName lands (set by the
-- server as it rises - a frame or so after the model appears).
local function consider(child: Instance)
	if not child:IsA("Model") then
		return
	end
	if child:GetAttribute(ATTR_BOSS_NAME) then
		retarget()
		return
	end
	local connection
	connection = child:GetAttributeChangedSignal(ATTR_BOSS_NAME):Connect(function()
		if child:GetAttribute(ATTR_BOSS_NAME) and child.Parent then
			connection:Disconnect()
			retarget()
		end
	end)
end

-- ---------------------------------------------------------------- the cards

-- Forward-declared above: the bar raises one of these when a window opens.
-- `hold` overrides how long it sits there - a card that announces a window
-- has to be gone before the window is, or it starts lying too.
function showCard(title: string, sub: string?, color: Color3, hold: number?)
	cardToken += 1
	local token = cardToken
	cardTitle.Text = title
	cardTitle.TextColor3 = color
	cardSub.Text = sub or ""
	local tweenIn = TweenInfo.new(CARD_IN, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(cardTitle, tweenIn, { TextTransparency = 0, TextStrokeTransparency = 0.4 }):Play()
	TweenService:Create(cardSub, tweenIn, { TextTransparency = 0, TextStrokeTransparency = 0.5 }):Play()
	task.delay(CARD_IN + (hold or CARD_HOLD), function()
		if token ~= cardToken then
			return
		end
		local tweenOut = TweenInfo.new(CARD_OUT, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(cardTitle, tweenOut, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		TweenService:Create(cardSub, tweenOut, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	end)
end

-- A ringed boss's window has no attribute of its own - the head is refused
-- while any arm stands, and these two events ARE the edges. Only the tracked
-- boss's own events count: two bosses can be up at once.
local function noteRing(open: boolean, name: any)
	if ward ~= "ring" or not current then
		return
	end
	local mine = current:GetAttribute(ATTR_BOSS_NAME)
	if name ~= nil and mine ~= nil and tostring(name) ~= tostring(mine) then
		return
	end
	ringOpen = open
	refresh()
end

-- A moment INSIDE a fight - a window opening, the arms coming back - is ours
-- when it belongs to the boss whose bar we are holding. Holding the bar
-- already means being inside the bound, so there is no second distance test
-- here; the name is only there to keep two live bosses apart.
local function mineNow(name: any): boolean
	if not current then
		return false
	end
	local mine = current:GetAttribute(ATTR_BOSS_NAME)
	return name == nil or mine == nil or tostring(name) == tostring(mine)
end

-- The FALL card is the one that must not be gated on presence alone: it
-- carries the unlock, and the server pays that unlock to people who are no
-- longer standing there (see ENGAGED_MEMORY). So it is ours if we are at the
-- fight now, OR if we held this boss's bar recently enough to be one of the
-- players it just paid. Either way the memory is spent - the fight is over.
local function ownsFall(name: any, position: Vector3?): boolean
	local remembered: number? = nil
	if type(name) == "string" then
		remembered = engagedAt[name]
		engagedAt[name] = nil
	end
	if atMyFight(position) then
		return true
	end
	return remembered ~= nil and (os.clock() - remembered) <= ENGAGED_MEMORY
end

-- These arrive on a FireAllClients, so every one of them starts by asking
-- whether it is addressed to this player at all.
local function onCreatureEvent(kind, position, extra)
	if type(extra) ~= "table" then
		extra = {}
	end
	if kind == "bossRise" then
		local name = extra.name
		if atMyFight(position) then
			pendingRise = nil
			showCard(string.upper(tostring(name or "THE BOSS")), "rises from the deep", BAR_COLOR)
		elseif type(name) == "string" then
			-- Not there YET - the party is still mid-teleport. RISE_GRACE.
			pendingRise = { name = name, expires = os.clock() + RISE_GRACE }
		end
	elseif kind == "exposed" then
		-- The Kraken: the last tentacle is down and the head can be hurt.
		noteRing(true, extra.name)
		if mineNow(extra.name) then
			showCard("THE MAW IS EXPOSED", "every arm is down - strike now", Theme.Color.gold)
		end
	elseif kind == "regrow" then
		noteRing(false, extra.name)
		if mineNow(extra.name) then
			showCard("THE ARMS REGROW", "bring them down again", Theme.Color.red)
		end
	elseif kind == "bossDown" then
		if not ownsFall(extra.name, position) then
			return
		end
		if extra.finale then
			-- The Kraken. There is no next island; this is the saga's end.
			showCard(
				"THE MAELSTROM FALLS SILENT",
				string.format("%s is slain - the saga is complete", tostring(extra.name)),
				Theme.Color.gold
			)
			return
		end
		local sub = if extra.unlocks
			then string.format("%s defeated - %s is open", tostring(extra.name), tostring(extra.unlocks))
			else string.format("%s defeated", tostring(extra.name))
		showCard("ISLAND CLEARED", sub, Theme.Color.green)
	end
end

-- ---------------------------------------------------------------- lifecycle

function BossHudController.init()
	build()
end

function BossHudController.start()
	Remotes.CreatureEvent.OnClientEvent:Connect(onCreatureEvent)

	task.spawn(function()
		local creatures = Workspace:WaitForChild(CREATURES_FOLDER, 30)
		if not creatures then
			warn("[BossHud] no Workspace." .. CREATURES_FOLDER .. " folder; boss bar off")
			return
		end
		creaturesFolder = creatures
		creatures.ChildAdded:Connect(consider)
		creatures.ChildRemoved:Connect(function(child)
			if child == current then
				-- The tracked boss went down; another may still be live on
				-- this player's island (or anywhere) - hand the bar over
				-- rather than killing it.
				untrack()
				retarget()
			end
		end)
		for _, existing in creatures:GetChildren() do
			consider(existing)
		end

		-- The bound has to be re-tested as the fight moves, not only when a
		-- boss appears or dies. BossService.summonFor raises the boss FIRST
		-- and task.defers the party out to the arena after, so at the instant
		-- the model lands every one of its challengers is still standing on
		-- their island thousands of studs away: a one-shot test there would
		-- take the bar off the WHOLE PARTY for the entire fight, which is far
		-- worse than the bug this bound exists to fix. It is also what lets a
		-- fighter who wandered out and came back get their bar again. Half a
		-- second is well inside the boss's own rise.
		while true do
			task.wait(RETARGET_INTERVAL)
			retarget()
		end
	end)
end

return BossHudController
