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
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Net.Remotes)
local Bosses = require(Shared.Data.Bosses)
-- ONE BAR PER BOSS: the palette, type, ornament and motion of the bar, keyed
-- by the Bosses row id. See "the look" below; a boss with no entry there
-- draws the default, which is this bar exactly as it was before.
local Themes = require(Shared.Data.BossHudThemes)

local Theme = require(script.Parent.Parent.UI.Theme)
local Sfx = require(script.Parent.Parent.Modules.Sfx)
local MusicController = require(script.Parent.MusicController)

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
-- THE SEAM METERS (Pyrelisk). The READ side of the attribute contract
-- written out in full at the top of PyreliskBodyController: two 0..1 flank
-- stagger meters the server publishes on the boss model.
--   SeamMeterL - the side +1 flank, seams 2/4/6, the golem's LEFT arm.
--   SeamMeterR - the side -1 flank, seams 3/5/7, its RIGHT.
-- (PyreliskBodyController's SEAM_FLANK is the cross-reference: +1 = L, -1 = R,
-- 0 = the chest, which belongs to neither meter and gets no bar here.)
--
-- STAGING PROPERTY, and it is the whole reason these are separate instances
-- hidden by default: the meter bars are built once and shown ONLY while the
-- tracked model actually carries at least one of these attributes. The test
-- is PRESENCE (GetAttribute ~= nil), never value - a published 0 is a real
-- empty meter and must draw, while an absent attribute is a boss with no such
-- system. The server half is not landed, so today every boss in the game
-- takes the absent branch and gets a HUD byte-identical to the one before
-- this existed: seamFrame stays Visible = false, nothing moves, nothing is
-- recoloured, and the health bar above is untouched (the meters are parented
-- beside barFrame, not inside it, so they cannot resize or shift it).
local ATTR_SEAM_L = "SeamMeterL"
local ATTR_SEAM_R = "SeamMeterR"

-- ---------------------------------------------------------------- layout

local BAR_Y = 124 -- below the grade (40) and level-up (84) banners
local BAR_WIDTH = 0.46 -- of the screen
local BAR_HEIGHT = 16
local NAME_SIZE = 20
local NAME_GAP = 6

local BAR_COLOR = Color3.fromRGB(120, 255, 214) -- the lure's glow, and the rise card's
-- (The one rage colour that used to live here is gone: enrage is per boss
-- now - see `palette.enraged` in BossHudThemes and Look.paintFill below.)
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

-- The seam meters, sat under the health bar in the fight's own lava palette:
-- an ember fill that goes gold the moment the flank is ready, on the same
-- dark plate, corner radius and stroke weight the health track uses.
local SEAM_HEIGHT = 12
local SEAM_GAP = 5 -- between the health bar and the meter row
local SEAM_SPLIT = 8 -- between the two meters
local SEAM_TEXT_SIZE = 10
local SEAM_PAD = 6
-- The ember/gold pair these two used to be hard-coded to is now the DEFAULT
-- theme's `seam`, and every boss that publishes meters gets its own (Look.seam).
local SEAM_COLOR = Theme.Color.ember
local SEAM_FLASH_FADE = 0.6 -- the one-shot flash starts here and tweens to 0
local SEAM_FLASH_TIME = 0.25
local SEAM_L_TEXT = "L ARM"
local SEAM_R_TEXT = "R ARM"
local SEAM_READY = " - READY"

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
local seamFrame: Frame
local seamL
local seamR
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

-- THE LOOK. Every themed instance and every scrap of animation state lives in
-- this one table rather than in a dozen more upvalues - the file is already
-- close enough to Luau's 200-locals-per-chunk ceiling that a new top-level
-- local per moving part is not a thing this HUD can afford. The functions
-- that fill it in are all fields on it too, for the same reason, and they are
-- defined under "the look" further down (they need `stopPulse` and `label`).
local Look = {
	theme = nil, -- the active BossHudThemes entry
	root = nil, -- the themed subtree; destroyed and rebuilt per boss
	track = nil,
	ghost = nil, -- the chip trail behind the fill
	flash = nil, -- the white hit flash over it
	glow = nil, -- the fill's UIStroke bloom
	fillGrad = nil,
	fillCore = nil, -- the lantern thread, for a theme with a faint fill
	fillBase = 0, -- the fill transparency the seal wants, before any pulse
	epithetLabel = nil,
	tickRoot = nil,
	scale = nil,
	seamScale = nil,
	ticks = {}, -- { inst, at, rage } per phase boundary
	motes = {}, -- the animated ornament pieces
	value = 1, -- the health fraction last drawn
	ghostValue = 1,
	ghostWait = 0,
	flashLevel = 0,
	shakeLevel = 0,
	enraged = false,
	clock = 0,
	layoutAt = 0,
	stepConn = nil,
}

-- THE ACT ROWS (Pyrelisk), and they live in ONE table for the reason `Look`
-- does: this file is at 120 top-level locals against Luau's 200-per-chunk
-- ceiling, and three acts' worth of bars and pips is a dozen moving parts. One
-- local, everything hanging off it.
--
-- WHAT THEY ARE. Each act publishes one attribute per its own shape, and each
-- act's row is the READ side of it:
--
--   act 2  PyreliskArmL / PyreliskArmR (number, 0..1) - the two downed arms'
--          own health. Two bars. NIL MEANS THE ARM IS NOT A CREATURE - act 1,
--          or once that arm is spent - and is NOT the same as 0, which is an
--          arm at the point of breaking. Each bar is hidden by its own
--          attribute's absence, so a fight with one arm left draws one bar.
--   act 3  PyreliskPillars (integer BITMASK, bits 0..7) on the HEART's model -
--          eight pips. Staged NOW because the attribute is frozen and because
--          a row added later is a row nobody re-tests; it simply never appears
--          until the heart's own slice publishes the attribute.
--
-- THE ROCK PIPS AND THE `CORE` BAR ARE GONE (2026-09-12), on the directive
-- "okay now the fallen rocks on its arm stuff maybe we can remove that entire
-- idea. maybe after the first phase it just goes straight into the volcano and
-- we move into that." They were the climb act's row - six survivor pips off
-- `PyreliskRocks` and a bar off `PyreliskCore` - and neither attribute is ever
-- published again. The act after the arms is the colossus SINKING into the
-- caldera, which has no meter: the read on it is the body going down.
--
-- SO THE PILLARS ARE ACT 3's ROW NOW rather than act 4's, and that re-key is
-- the only thing that changed about them. It costs no code - the gate was
-- always the attribute's presence on the heart's model and never an act
-- number - which is exactly why it was worth staging early.
--
-- THE GATE IS PRESENCE, never value, exactly as `refreshSeams` documents at
-- length: `GetAttribute ~= nil`. Every boss in the game today answers nil to
-- all three and gets a HUD byte-identical to the one before this existed.
--
-- The rows are SIBLINGS of the bar and of each other, stacked by a
-- UIListLayout that skips invisible children - so an act that is not being
-- fought costs no vertical space and nothing above ever moves.
local Act = {
	ATTR = {
		armL = "PyreliskArmL",
		armR = "PyreliskArmR",
		pillars = "PyreliskPillars",
	},
	PILLARS = 8, -- eight sockets, eight bits (SS7.3)
	PIP = 10, -- a pip's side, in pixels
	PIP_GAP = 4,
	GAP = 4, -- between stacked rows
	frame = nil,
	rows = {}, -- { arms, pillars } - the two stacked containers
	armL = nil,
	armR = nil,
	pillarPips = {},
}

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

-- One flank meter: the health track's own plate, corner and stroke at a
-- third of the height, with its name written ACROSS it exactly the way the
-- seal's status line is written across the health bar - so the row costs no
-- extra vertical space and nothing below it moves when it appears.
local function seamMeter(parent: GuiObject, name: string, text: string, onRight: boolean)
	local track = Instance.new("Frame")
	track.Name = name
	track.AnchorPoint = Vector2.new(if onRight then 1 else 0, 0)
	track.Position = UDim2.fromScale(if onRight then 1 else 0, 0)
	track.Size = UDim2.new(0.5, -SEAM_SPLIT / 2, 1, 0)
	track.BackgroundColor3 = BAR_BACK
	track.BackgroundTransparency = 0.25
	track.BorderSizePixel = 0
	track.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = track
	local stroke = Instance.new("UIStroke")
	stroke.Color = Theme.Color.border
	stroke.Thickness = STROKE_THIN
	stroke.Parent = track

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = SEAM_COLOR
	fill.BorderSizePixel = 0
	fill.Parent = track
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 4)
	fillCorner.Parent = fill

	local nameText = label(track, {
		Name = "Label",
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
		TextSize = SEAM_TEXT_SIZE,
		TextStrokeTransparency = 0.25,
		TextXAlignment = if onRight then Enum.TextXAlignment.Right else Enum.TextXAlignment.Left,
		Text = text,
	})
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, SEAM_PAD)
	pad.PaddingRight = UDim.new(0, SEAM_PAD)
	pad.Parent = nameText

	-- `track` and `stroke` come back too: the meters are built once, so the
	-- only way they can wear the current fight's colours is for the theme to
	-- repaint them (Look.apply).
	return { fill = fill, label = nameText, base = text, full = false, track = track, stroke = stroke }
end

-- ONE PIP: a small square in the health track's own plate, lit or dark. The
-- vocabulary is deliberately NOT a bar - the heart's eight pillars are a
-- COUNT, and a count drawn as a bar tells you a fraction when what you need
-- is "which ones are left". Same plate, same corner, same stroke as the
-- meters beside them, so the row reads as one instrument.
function Act.pip(parent: GuiObject, index: number)
	local pip = Instance.new("Frame")
	pip.Name = "Pip" .. index
	pip.AnchorPoint = Vector2.new(0, 0.5)
	pip.Position = UDim2.new(0, (index - 1) * (Act.PIP + Act.PIP_GAP), 0.5, 0)
	pip.Size = UDim2.fromOffset(Act.PIP, Act.PIP)
	pip.BackgroundColor3 = SEAM_COLOR
	pip.BorderSizePixel = 0
	pip.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 2)
	corner.Parent = pip
	local stroke = Instance.new("UIStroke")
	stroke.Color = Theme.Color.border
	stroke.Thickness = STROKE_THIN
	stroke.Parent = pip
	return { pip = pip, stroke = stroke, lit = true }
end

-- A strip of `count` pips, left-aligned, returned with the width it occupies
-- so whatever shares the row can be sized against it rather than guessing.
function Act.pipStrip(parent: GuiObject, name: string, count: number, into: { any })
	local width = count * Act.PIP + (count - 1) * Act.PIP_GAP
	local strip = Instance.new("Frame")
	strip.Name = name
	strip.Size = UDim2.new(0, width, 1, 0)
	strip.BackgroundTransparency = 1
	strip.Parent = parent
	for index = 1, count do
		into[index] = Act.pip(strip, index)
	end
	return strip, width
end

-- The two rows, built once and left invisible. Called from `build` after
-- seamFrame exists, because this row sits under that one. (It was three until
-- 2026-09-12 - see THE ROCK PIPS AND THE `CORE` BAR ARE GONE.)
function Act.build(parent: Instance)
	Act.frame = Instance.new("Frame")
	Act.frame.Name = "PyreliskActs"
	Act.frame.AnchorPoint = Vector2.new(0.5, 0)
	Act.frame.Size = UDim2.new(BAR_WIDTH, 0, 0, SEAM_HEIGHT)
	Act.frame.BackgroundTransparency = 1
	Act.frame.Visible = false
	Act.frame.Parent = parent
	-- A LIST LAYOUT, and it is what makes "presence-gated" cost nothing: an
	-- invisible child is not laid out at all, so an act that is not being
	-- fought takes no vertical space and the rows below never shuffle.
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, Act.GAP)
	list.Parent = Act.frame

	for order, name in { "Arms", "Pillars" } do
		local row = Instance.new("Frame")
		row.Name = name
		row.LayoutOrder = order
		row.Size = UDim2.new(1, 0, 0, SEAM_HEIGHT)
		row.BackgroundTransparency = 1
		row.Visible = false
		row.Parent = Act.frame
		Act.rows[string.lower(name)] = row
	end

	-- ACT 2: the two arms' own bars. LEFT of the row is the golem's LEFT, the
	-- same hand the seam row's L means - `PyreliskArmL` is side +1, which is
	-- the authored +Y flank (PyreliskBodyController's SEAM_FLANK). They are
	-- labelled HP rather than ARM so they cannot be read as the stagger
	-- meters sat directly above them: those fill to bring an arm DOWN, these
	-- empty as you break the arm once it is down.
	Act.armL = seamMeter(Act.rows.arms, "ArmL", "L ARM HP", false)
	Act.armR = seamMeter(Act.rows.arms, "ArmR", "R ARM HP", true)

	-- ACT 3: eight pips, and nothing else - the heart's own bar is the boss
	-- bar above, because at that point the heart IS the boss. (This was act
	-- 4's row until 2026-09-12; the climb act between the arms and the heart
	-- is gone and the colossus sinks straight into the caldera instead.)
	local pillars = Act.pipStrip(Act.rows.pillars, "PillarPips", Act.PILLARS, Act.pillarPips)
	pillars.AnchorPoint = Vector2.new(0.5, 0)
	pillars.Position = UDim2.fromScale(0.5, 0)
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

	-- The track, the fill, the name and the seal's status line are NOT written
	-- out here any more: they are the part of the bar that differs per boss,
	-- so `Look.apply` builds them from the tracked boss's theme (and rebuilds
	-- them when the tracked boss changes). Everything below still drives the
	-- same four upvalues it always did.

	-- THE SEAM METERS. A row of its own, a sibling of barFrame rather than a
	-- child, sat just under it. Built once and left INVISIBLE: only a boss
	-- carrying the meter attributes ever switches it on (see `refreshSeams`),
	-- and because it is a sibling it can never resize or move the health bar
	-- above it - a boss without the attributes draws exactly today's HUD.
	seamFrame = Instance.new("Frame")
	seamFrame.Name = "SeamMeters"
	seamFrame.AnchorPoint = Vector2.new(0.5, 0)
	seamFrame.Position = UDim2.new(0.5, 0, 0, BAR_Y + NAME_SIZE + NAME_GAP + BAR_HEIGHT + SEAM_GAP)
	seamFrame.Size = UDim2.new(BAR_WIDTH, 0, 0, SEAM_HEIGHT)
	seamFrame.BackgroundTransparency = 1
	seamFrame.Visible = false
	seamFrame.Parent = gui

	-- LEFT of the row is the golem's LEFT flank - SeamMeterL, side +1, seams
	-- 2/4/6 (PyreliskBodyController's SEAM_FLANK). RIGHT of the row is
	-- SeamMeterR, side -1, seams 3/5/7. The two must not be swapped: the whole
	-- point is telling a player which side to keep shooting.
	seamL = seamMeter(seamFrame, "SeamL", SEAM_L_TEXT, false)
	seamR = seamMeter(seamFrame, "SeamR", SEAM_R_TEXT, true)

	-- THE ACT ROWS, under the meter row and a sibling of it for the same
	-- reason - see the `Act` table. Built here, laid out by `Look.layout`,
	-- and invisible until a boss publishes one of the five attributes.
	Act.build(gui)

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

	-- Built once with the DEFAULT theme so nameLabel / barFill / barStroke /
	-- statusLabel are live instances before any boss is ever adopted - untrack
	-- and drawSeal both run on an empty HUD at startup. Done last, after
	-- seamFrame exists, because the layout pass places the meter row under the
	-- bar the theme just sized.
	Look.apply(nil)

	-- ONE loop for the whole HUD (see "the motion"): it returns immediately
	-- while the bar is hidden, which is almost always.
	if Look.stepConn == nil then
		Look.stepConn = RunService.Heartbeat:Connect(function(dt: number)
			Look.step(dt)
		end)
	end

	gui.Parent = player:WaitForChild("PlayerGui")
end

-- ---------------------------------------------------------------- the bar

-- ---------------------------------------------------------------- the score
--
-- THE VOICE / MUSIC LIFECYCLE, and why it hangs off track / untrack rather
-- than off the rise and fall events. The bar's owner IS this client's fight:
-- `track` is the one place that decides "this boss is mine now" (it is the
-- far side of the bound above, hysteresis and all), and `untrack` the one
-- place that decides it isn't any more - a death, a hand-over to another
-- live boss, or wandering out past DISENGAGE. Anything driven off bossRise
-- instead would leave a player who wandered off mid-fight, or who never got
-- the bar at all, listening to a boss theme for a fight they are not in.
--
-- So the two are strictly paired: every `track` sets the voice and starts
-- the theme, every `untrack` clears both, and `track` calls `untrack` first,
-- which is what makes a boss-to-boss hand-over come out as clear-then-set
-- rather than two overlapping themes.
local currentPhase: number? = nil

-- Which phase the tracked boss's health puts it in, 1-based: the LAST phase
-- whose `below` the fraction is at or under. Same rule as the server's
-- bossPhaseIndex in CreatureService - the client can compute it because the
-- inputs (Health, MaxHealth, the row's phases) are all already here, so the
-- music follows the fight without a new remote.
local function phaseIndexOf(row, hpFraction: number): number?
	if row == nil or type(row.phases) ~= "table" then
		return nil
	end
	local index = 1
	for i, phase in row.phases do
		if hpFraction <= (phase.below or 1) then
			index = i
		end
	end
	return index
end

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
		-- Back to the boss's own frame, not the generic border it used to be.
		barStroke.Color = Look.pick("stroke")
		barStroke.Thickness = Look.frameSpec().stroke or STROKE_THIN
		statusLabel.Text = ""
		statusLabel.TextTransparency = 1
	end
end

-- ---------------------------------------------------------------- the look
--
-- ONE BAR PER BOSS (2026-09-12). Everything above this line decides WHICH
-- fight owns the bar and WHAT it is allowed to say; this section decides what
-- that bar LOOKS like, and it is the only part of the file that knows the
-- answer differs per boss. The palette, the type, the ornament and the motion
-- all come out of Shared/Data/BossHudThemes, keyed by the tracked boss's
-- Bosses row id (`Look.apply`), and a boss with no theme - or a model that
-- arrived with no CreatureId at all - draws the default, which is the bar
-- exactly as it was before this existed.
--
-- IT OWNS FOUR UPVALUES. nameLabel / barFill / barStroke / statusLabel are
-- built HERE and rebuilt whenever the tracked boss's theme changes, so the
-- seal (drawSeal), the health read (refresh), the cards and the seam meters
-- all keep driving the same four instances they always did and none of them
-- had to learn about themes.
--
-- NO ASSETS. Every ornament is procedural - Frames with UICorner, UIGradient,
-- UIStroke and Rotation - because the HUD may not cost an image upload.
--
-- ONE LOOP. A single Heartbeat drives every animation in the file. It returns
-- on its first line while the bar is hidden, and while it is up it only
-- touches what the active theme actually asked to move.
-- The active theme's value for `key`, with the enraged override on top when
-- the boss is enraged, and the default theme's value if a theme is missing it.
function Look.pick(key: string)
	local palette = (Look.theme and Look.theme.palette) or Themes.default.palette
	local rage = if Look.enraged then palette.enraged else nil
	if rage and rage[key] ~= nil then
		return rage[key]
	end
	if palette[key] ~= nil then
		return palette[key]
	end
	return Themes.default.palette[key]
end

function Look.motion()
	return (Look.theme and Look.theme.motion) or Themes.default.motion
end

function Look.frameSpec()
	return (Look.theme and Look.theme.frame) or Themes.default.frame
end

-- The flank meters' palette, so the two bosses that publish SeamMeter
-- attributes get meters in their own fight's colours rather than the lava
-- ones that were hard-coded for Pyrelisk.
function Look.seam()
	return (Look.theme and Look.theme.seam) or Themes.default.seam
end

-- A theme's fill stops as a ColorSequence. One stop is legal (it becomes a
-- flat bar), and so is a flat colour, which is how the seal paints over the
-- theme without having to know anything about gradients.
function Look.sequence(stops: any): ColorSequence
	if typeof(stops) == "Color3" then
		return ColorSequence.new(stops)
	end
	if type(stops) ~= "table" or #stops == 0 then
		return ColorSequence.new(Color3.new(1, 1, 1))
	end
	if #stops == 1 then
		return ColorSequence.new(stops[1])
	end
	local keys = {}
	for i, color in stops do
		table.insert(keys, ColorSequenceKeypoint.new((i - 1) / (#stops - 1), color))
	end
	return ColorSequence.new(keys)
end

-- Every ornament piece is one of these: a Frame, no asset, parented into the
-- track so it travels with the bar and is destroyed with it.
function Look.piece(parent: GuiObject, props: { [string]: any }): Frame
	local piece = Instance.new("Frame")
	piece.AnchorPoint = Vector2.new(0.5, 0.5)
	piece.BorderSizePixel = 0
	piece.ZIndex = 3
	for key, value in props do
		piece[key] = value
	end
	piece.Parent = parent
	return piece
end

function Look.round(inst: GuiObject, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = inst
end

-- A piece that fades out along its length - the trick every "tapered" thing
-- here is made of (icicles, roots, tentacle curls), since a Frame cannot be
-- a triangle.
function Look.taper(inst: GuiObject, rotation: number)
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = rotation
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.55, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	gradient.Parent = inst
end

-- ------------------------------------------------------------- ornaments

-- The procedural decoration for one theme. Each branch builds its pieces
-- once and registers the ones that move in `Look.motes`, tagged with the mode
-- the single step loop below knows how to animate:
--   bob   - rides up and down on the spot        rise  - drifts upward, wraps
--   flow  - travels along the bar, wraps         drift - hangs and wanders
--   sway  - rocks about its built rotation       spin  - turns continuously
--   twinkle - breathes its transparency
function Look.ornaments(kind: string, parent: GuiObject)
	local height = Look.frameSpec().height or 16
	local base = Look.pick("ornament")
	local alt = Look.pick("ornamentAlt")

	if kind == "scales" then
		-- Brinejaw: a row of scales along the top edge, one rolling wave crest
		-- on the fill, and foam breaking off the crest.
		for i = 1, 16 do
			local scale = Look.piece(parent, {
				Name = "Scale",
				Size = UDim2.fromOffset(7, 7),
				Position = UDim2.new((i - 0.5) / 16, 0, 0, 1),
				Rotation = 45,
				BackgroundColor3 = base,
				BackgroundTransparency = 0.58,
			})
			Look.round(scale, 2)
			table.insert(
				Look.motes,
				{ inst = scale, mode = "bob", phase = i * 0.6, speed = 1.5, amp = 1.5, fade = 0.58 }
			)
		end
		local crest = Look.piece(parent, {
			Name = "Crest",
			Size = UDim2.new(0.12, 0, 1, -2),
			Position = UDim2.new(0, 0, 0.5, 0),
			BackgroundColor3 = alt,
			BackgroundTransparency = 0.78,
		})
		Look.round(crest, 6)
		table.insert(
			Look.motes,
			{ inst = crest, mode = "flow", speed = 1, phase = 0, y = 0.5, fade = 0.78, alt = true }
		)
		for i = 1, 6 do
			local foam = Look.piece(parent, {
				Name = "Foam",
				Size = UDim2.fromOffset(3, 3),
				Position = UDim2.new(0, 0, 0, 2),
				BackgroundColor3 = alt,
				BackgroundTransparency = 0.3,
			})
			Look.round(foam, 2)
			table.insert(
				Look.motes,
				{ inst = foam, mode = "flow", speed = 1.6, phase = i / 6, y = 0.08, fade = 0.3, alt = true }
			)
		end
	elseif kind == "embers" then
		-- Pyrelisk: flecks rising off the crack and dying in the ash above it.
		for i = 1, 12 do
			local ember = Look.piece(parent, {
				Name = "Ember",
				Size = UDim2.fromOffset(if i % 3 == 0 then 4 else 3, if i % 3 == 0 then 4 else 3),
				Position = UDim2.new(i / 13, 0, 1, 0),
				BackgroundColor3 = if i % 4 == 0 then alt else base,
				BackgroundTransparency = 0.2,
			})
			Look.round(ember, 2)
			table.insert(Look.motes, {
				inst = ember,
				mode = "rise",
				speed = 0.34 + (i % 5) * 0.07,
				phase = (i * 0.137) % 1,
				x = i / 13,
				fade = 0.2,
				alt = i % 4 == 0,
			})
		end
	elseif kind == "roots" then
		-- Gnashroot: tendrils curling off both ends of the plate, rocking the
		-- way something half-floating does.
		for i = 1, 6 do
			local left = i <= 3
			local index = if left then i else i - 3
			local rotation = (if left then -1 else 1) * (18 + index * 22)
			local root = Look.piece(parent, {
				Name = "Root",
				Size = UDim2.fromOffset(3, 14 + index * 5),
				Position = UDim2.new(if left then 0 else 1, 0, 0.5, 0),
				Rotation = rotation,
				BackgroundColor3 = if index == 2 then alt else base,
				BackgroundTransparency = 0.1,
			})
			Look.round(root, 2)
			Look.taper(root, 90)
			table.insert(Look.motes, {
				inst = root,
				mode = "sway",
				phase = i * 0.8,
				speed = 0.7,
				amp = 4,
				rot = rotation,
				fade = 0.1,
				alt = index == 2,
			})
		end
	elseif kind == "icicles" then
		-- Rimefang: teeth hanging off the underside, frost on the plate.
		for i = 1, 11 do
			local length = 7 + (i % 3) * 5
			local spike = Look.piece(parent, {
				Name = "Icicle",
				AnchorPoint = Vector2.new(0.5, 0),
				Size = UDim2.fromOffset(4, length),
				Position = UDim2.new((i - 0.5) / 11, 0, 1, -1),
				BackgroundColor3 = base,
				BackgroundTransparency = 0.15,
			})
			Look.round(spike, 2)
			Look.taper(spike, 90)
			table.insert(
				Look.motes,
				{ inst = spike, mode = "sway", phase = i * 0.5, speed = 0.5, amp = 1.5, rot = 0, fade = 0.15 }
			)
		end
		for i = 1, 7 do
			local crystal = Look.piece(parent, {
				Name = "Frost",
				Size = UDim2.fromOffset(5, 5),
				Position = UDim2.new((i - 0.5) / 7, 0, if i % 2 == 0 then 0.28 else 0.72, 0),
				Rotation = 45,
				BackgroundColor3 = alt,
				BackgroundTransparency = 0.65,
			})
			table.insert(
				Look.motes,
				{ inst = crystal, mode = "twinkle", phase = i * 0.9, speed = 1.1, fade = 0.65, alt = true }
			)
		end
	elseif kind == "lantern" then
		-- Noctyss: motes hanging in the black, and the lure itself - a bright
		-- thread down the middle of an otherwise faint fill.
		for i = 1, 9 do
			local mote = Look.piece(parent, {
				Name = "Mote",
				Size = UDim2.fromOffset(if i % 3 == 0 then 5 else 3, if i % 3 == 0 then 5 else 3),
				Position = UDim2.new((i - 0.5) / 9, 0, 0.5, 0),
				BackgroundColor3 = if i % 3 == 0 then alt else base,
				BackgroundTransparency = 0.25,
			})
			Look.round(mote, 3)
			local halo = Instance.new("UIStroke")
			halo.Color = if i % 3 == 0 then alt else base
			halo.Thickness = 2
			halo.Transparency = 0.7
			halo.Parent = mote
			table.insert(Look.motes, {
				inst = mote,
				mode = "drift",
				phase = i * 0.77,
				speed = 0.5,
				amp = 4,
				x = (i - 0.5) / 9,
				fade = 0.25,
				alt = i % 3 == 0,
			})
		end
	elseif kind == "brass" then
		-- Wrack: rivets down both rails, rope whipped round both ends.
		local rivets = math.max(6, math.floor((Look.frameSpec().width or 0.46) * 22))
		for i = 1, rivets do
			for _, edge in { 0, 1 } do
				local rivet = Look.piece(parent, {
					Name = "Rivet",
					Size = UDim2.fromOffset(4, 4),
					Position = UDim2.new((i - 0.5) / rivets, 0, edge, if edge == 0 then 2 else -2),
					BackgroundColor3 = base,
					BackgroundTransparency = 0.1,
				})
				Look.round(rivet, 2)
			end
		end
		for i = 1, 6 do
			local left = i <= 3
			local index = if left then i else i - 3
			local rotation = (if left then -1 else 1) * 14
			local rope = Look.piece(parent, {
				Name = "Rope",
				Size = UDim2.fromOffset(7, height - 2),
				Position = UDim2.new(if left then 0 else 1, (if left then -1 else 1) * (index * 7 - 3), 0.5, 0),
				Rotation = rotation,
				BackgroundColor3 = alt,
				BackgroundTransparency = 0.18,
			})
			Look.round(rope, 3)
			table.insert(Look.motes, {
				inst = rope,
				mode = "sway",
				phase = i * 0.7,
				speed = 0.6,
				amp = 2,
				rot = rotation,
				fade = 0.18,
				alt = true,
			})
		end
	elseif kind == "whirlpool" then
		-- The Kraken: two rings turning at the empty end, arms curling off
		-- both, and storm foam blowing past.
		for i = 1, 2 do
			local ring = Look.piece(parent, {
				Name = "Spiral",
				Size = UDim2.fromOffset(height + i * 7, height + i * 7),
				Position = UDim2.new(0, 0, 0.5, 0),
				BackgroundTransparency = 1,
				Rotation = i * 30,
			})
			Look.round(ring, 999)
			local ink = Instance.new("UIStroke")
			ink.Color = if i == 1 then alt else base
			ink.Thickness = 1.5
			ink.Transparency = 0.45
			ink.Parent = ring
			Look.taper(ring, i * 120)
			table.insert(
				Look.motes,
				{ inst = ring, mode = "spin", speed = if i == 1 then 34 else -22, phase = i * 30, fade = 1 }
			)
		end
		for i = 1, 6 do
			local left = i <= 3
			local index = if left then i else i - 3
			local rotation = (if left then -1 else 1) * (24 + index * 26)
			local arm = Look.piece(parent, {
				Name = "Arm",
				Size = UDim2.fromOffset(4, 13 + index * 6),
				Position = UDim2.new(if left then 0 else 1, 0, 0.5, 0),
				Rotation = rotation,
				BackgroundColor3 = base,
				BackgroundTransparency = 0.15,
			})
			Look.round(arm, 2)
			Look.taper(arm, 90)
			table.insert(
				Look.motes,
				{ inst = arm, mode = "sway", phase = i * 0.9, speed = 0.8, amp = 6, rot = rotation, fade = 0.15 }
			)
		end
		for i = 1, 8 do
			local fleck = Look.piece(parent, {
				Name = "Foam",
				Size = UDim2.fromOffset(4, 2),
				Position = UDim2.new(0, 0, 0, 0),
				BackgroundColor3 = alt,
				BackgroundTransparency = 0.35,
			})
			Look.round(fleck, 1)
			table.insert(Look.motes, {
				inst = fleck,
				mode = "flow",
				speed = 1.4 + (i % 3) * 0.5,
				phase = i / 8,
				y = 0.2 + (i % 4) * 0.2,
				fade = 0.35,
				alt = true,
			})
		end
	end
end

-- ----------------------------------------------------------------- build

-- Build (or rebuild) the whole bar for one boss's theme. Called with the
-- Bosses row id; the same id twice in a row is a no-op, so a hand-over
-- between two bosses of the same family (the Admiral's two rows are the only
-- pair that differ) costs nothing and a re-adopt mid-fight does not flicker.
function Look.apply(id: any)
	local theme = Themes.get(id)
	if Look.root and Look.root.Parent and Look.theme == theme then
		return
	end
	-- Anything tweening points at instances that are about to be destroyed.
	stopPulse()
	if Look.root then
		Look.root:Destroy()
	end
	table.clear(Look.ticks)
	table.clear(Look.motes)
	Look.theme = theme
	Look.enraged = false
	Look.value = 1
	Look.ghostValue = 1

	local typography = theme.typography or Themes.default.typography
	local spec = theme.frame or Themes.default.frame
	local corner = if spec.endCap == "round" then math.floor((spec.height or 16) / 2) else (spec.corner or 4)

	local root = Instance.new("Frame")
	root.Name = "Look"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = barFrame
	Look.root = root

	nameLabel = label(root, {
		Name = "Name",
		Size = UDim2.new(1, 0, 0, typography.nameSize or 20),
		Font = if typeof(typography.name) == "EnumItem" then typography.name else Theme.Font.header,
		TextSize = typography.nameSize or 20,
		TextColor3 = Look.pick("text"),
		TextStrokeTransparency = 0.15,
		Text = "",
	})
	Look.epithetLabel = label(root, {
		Name = "Epithet",
		Position = UDim2.new(0, 0, 0, typography.nameSize or 20),
		Size = UDim2.new(1, 0, 0, typography.epithetSize or 11),
		Font = if typeof(typography.epithet) == "EnumItem" then typography.epithet else Theme.Font.body,
		TextSize = typography.epithetSize or 11,
		TextColor3 = Look.pick("epithet"),
		TextStrokeTransparency = 0.3,
		Text = "",
		TextTransparency = 1,
	})

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0.5, 1)
	track.Position = UDim2.new(0.5, 0, 1, 0)
	track.Size = UDim2.new(1, 0, 0, spec.height or 16)
	track.BackgroundColor3 = Look.pick("track")
	track.BackgroundTransparency = 0.1
	track.BorderSizePixel = 0
	track.Parent = root
	Look.track = track
	Look.round(track, corner)
	local plate = Instance.new("UIGradient")
	plate.Color = ColorSequence.new(Look.pick("track"), Look.pick("trackEdge"))
	plate.Rotation = 90
	plate.Parent = track
	barStroke = Instance.new("UIStroke")
	barStroke.Color = Look.pick("stroke")
	barStroke.Thickness = spec.stroke or STROKE_THIN
	barStroke.Parent = track

	-- The plate's texture: a second gradient at an angle over the first, which
	-- is what makes peat mottled, tar grainy and ice cloudy without an image.
	local mottle = Instance.new("Frame")
	mottle.Name = "Mottle"
	mottle.Size = UDim2.fromScale(1, 1)
	mottle.BackgroundColor3 = Look.pick("mottle")
	mottle.BackgroundTransparency = (theme.palette and theme.palette.mottleFade) or 0.85
	mottle.BorderSizePixel = 0
	mottle.ZIndex = 1
	mottle.Parent = track
	Look.round(mottle, corner)
	local grain = Instance.new("UIGradient")
	grain.Rotation = 24
	grain.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(0.3, 0.9),
		NumberSequenceKeypoint.new(0.55, 0.15),
		NumberSequenceKeypoint.new(0.8, 0.95),
		NumberSequenceKeypoint.new(1, 0.2),
	})
	grain.Parent = mottle

	-- THE CHIP TRAIL: a pale ghost of the health you had a moment ago, left
	-- behind the fill and eased down after it, so a hit reads as a hit.
	Look.ghost = Instance.new("Frame")
	Look.ghost.Name = "Chip"
	Look.ghost.Size = UDim2.fromScale(1, 1)
	Look.ghost.BackgroundColor3 = Look.pick("chip")
	Look.ghost.BackgroundTransparency = 1
	Look.ghost.BorderSizePixel = 0
	Look.ghost.ZIndex = 2
	Look.ghost.Parent = track
	Look.round(Look.ghost, corner)

	barFill = Instance.new("Frame")
	barFill.Name = "Fill"
	barFill.Size = UDim2.fromScale(1, 1)
	barFill.BackgroundColor3 = Color3.new(1, 1, 1)
	barFill.BorderSizePixel = 0
	barFill.ZIndex = 3
	barFill.Parent = track
	Look.round(barFill, corner)
	Look.fillGrad = Instance.new("UIGradient")
	Look.fillGrad.Color = Look.sequence(Look.pick("fill"))
	Look.fillGrad.Parent = barFill
	Look.glow = Instance.new("UIStroke")
	Look.glow.Color = Look.pick("glow")
	Look.glow.Thickness = 1.5
	Look.glow.Transparency = 0.55
	Look.glow.Parent = barFill
	-- The lure's thread: for a theme that wants a faint fill, the light lives
	-- in one bright line down the middle instead of the whole slab.
	if theme.ornament == "lantern" then
		Look.fillCore = Look.piece(barFill, {
			Name = "Thread",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.new(1, -4, 0, 2),
			Position = UDim2.fromScale(0.5, 0.5),
			BackgroundColor3 = Look.pick("ornament"),
			BackgroundTransparency = 0.1,
			ZIndex = 4,
		})
		Look.round(Look.fillCore, 1)
	else
		Look.fillCore = nil
	end
	-- The hit flash, white over the fill and transparent until a hit lands.
	Look.flash = Look.piece(barFill, {
		Name = "Flash",
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromScale(1, 1),
		Position = UDim2.fromScale(0, 0),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 1,
		ZIndex = 5,
	})
	Look.round(Look.flash, corner)

	-- A squared plate with a diamond driven onto each end reads as a point;
	-- the other two end caps are already said by the corner radius.
	if spec.endCap == "point" then
		for _, side in { 0, 1 } do
			local cap = Look.piece(track, {
				Name = "Cap",
				Size = UDim2.fromOffset((spec.height or 16) * 0.7, (spec.height or 16) * 0.7),
				Position = UDim2.new(side, 0, 0.5, 0),
				Rotation = 45,
				BackgroundColor3 = Look.pick("stroke"),
				BackgroundTransparency = 0.25,
				ZIndex = 4,
			})
			Look.round(cap, 2)
		end
	end

	Look.tickRoot = Look.piece(track, {
		Name = "Ticks",
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromScale(1, 1),
		Position = UDim2.fromScale(0, 0),
		BackgroundTransparency = 1,
		ZIndex = 6,
	})
	local ornRoot = Look.piece(track, {
		Name = "Ornaments",
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromScale(1, 1),
		Position = UDim2.fromScale(0, 0),
		BackgroundTransparency = 1,
		ZIndex = 3,
	})
	Look.ornaments(theme.ornament or "none", ornRoot)

	-- The seal's line, still written ACROSS the bar rather than beside it, so
	-- nothing moves when it appears and the banners stacked above stay put.
	statusLabel = label(track, {
		Name = "Status",
		Size = UDim2.fromScale(1, 1),
		ZIndex = 7,
		TextSize = STATUS_SIZE,
		TextStrokeTransparency = 0.15,
		Text = "",
		TextTransparency = 1,
	})

	-- The flank meters wear the fight's colours too.
	local seam = Look.seam()
	for _, meter in { seamL, seamR } do
		if meter then
			meter.fill.BackgroundColor3 = if meter.full then seam.full else seam.fill
			if meter.track then
				meter.track.BackgroundColor3 = seam.track
			end
			if meter.stroke then
				meter.stroke.Color = Look.pick("stroke")
			end
		end
	end
	-- ...and so do the act rows. Same palette, same call, because they are the
	-- same instrument one row down: two bars, then pips, then more pips.
	for _, meter in { Act.armL, Act.armR } do
		if meter then
			meter.fill.BackgroundColor3 = if meter.full then seam.full else seam.fill
			if meter.track then
				meter.track.BackgroundColor3 = seam.track
			end
			if meter.stroke then
				meter.stroke.Color = Look.pick("stroke")
			end
		end
	end
	for _, entry in Act.pillarPips do
		entry.pip.BackgroundColor3 = if entry.lit then seam.fill else seam.track
		entry.stroke.Color = Look.pick("stroke")
	end

	Look.layout()
end

-- The bar's size on THIS screen. Everything is scale-based or scaled by one
-- UIScale, so the same theme reads the same on a 16:9 monitor and on a phone
-- held sideways - where the bar also widens, because 46% of a narrow viewport
-- is not enough room for "NOCTYSS, THE TRENCH MOTHER".
function Look.layout()
	local spec = Look.frameSpec()
	local typography = (Look.theme and Look.theme.typography) or Themes.default.typography
	local viewport = Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize or Vector2.new(1280, 720)
	local narrow = viewport.X < 760
	local width = math.clamp(if narrow then (spec.width or 0.46) * 1.7 else (spec.width or 0.46), 0.2, 0.92)
	local scale = math.clamp(viewport.X / 1280, 0.82, 1.15)
	local height = (typography.nameSize or 20)
		+ (typography.epithetSize or 11)
		+ (spec.gap or NAME_GAP)
		+ (spec.height or BAR_HEIGHT)

	if not Look.scale then
		Look.scale = barFrame:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
		Look.scale.Parent = barFrame
	end
	Look.scale.Scale = scale
	barFrame.Size = UDim2.new(width, 0, 0, height)
	if Look.epithetLabel then
		Look.epithetLabel.Position = UDim2.new(0, 0, 0, typography.nameSize or 20)
	end

	if seamFrame then
		if not Look.seamScale then
			Look.seamScale = seamFrame:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
			Look.seamScale.Parent = seamFrame
		end
		Look.seamScale.Scale = scale
		seamFrame.Size = UDim2.new(width, 0, 0, SEAM_HEIGHT)
		seamFrame.Position = UDim2.new(0.5, 0, 0, BAR_Y + (height + SEAM_GAP) * scale)
	end

	-- THE ACT ROWS SIT UNDER THE METER ROW WHETHER OR NOT IT IS SHOWING, and
	-- that is on purpose: the meter row is a sibling with a fixed slot, so
	-- reserving its height keeps this block's position a pure function of the
	-- bar's own size. A layout that shuffled upward when the meters hid would
	-- move the act row mid-fight - the seams close on every recover.
	if Act.frame then
		if not Act.scale then
			Act.scale = Act.frame:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
			Act.scale.Parent = Act.frame
		end
		Act.scale.Scale = scale
		Act.frame.Size = UDim2.new(width, 0, 0, SEAM_HEIGHT)
		Act.frame.Position =
			UDim2.new(0.5, 0, 0, BAR_Y + (height + SEAM_GAP) * scale + (SEAM_HEIGHT + SEAM_GAP) * scale)
	end
end

-- ------------------------------------------------------------------ type

-- The name is split at its first comma: the big NAME, and the EPITHET under
-- it in the theme's second face, letter-spaced and faded in a beat later so
-- the two arrive in the right order. Both halves come out of the Bosses row's
-- own `name` - nothing here duplicates a boss's title.
function Look.setName(fullName: any)
	local typography = (Look.theme and Look.theme.typography) or Themes.default.typography
	local head, tail = Themes.split(fullName)
	nameLabel.Text = string.upper(head)
	nameLabel.TextColor3 = Look.pick("text")
	nameLabel.TextTransparency = 0
	if not Look.epithetLabel then
		return
	end
	if typography.epithetCase == "upper" then
		tail = string.upper(tail)
	elseif typography.epithetCase == "lower" then
		tail = string.lower(tail)
	end
	Look.epithetLabel.Text = Themes.spaced(tail, typography.spacing)
	Look.epithetLabel.TextColor3 = Look.pick("epithet")
	Look.epithetLabel.TextTransparency = 1
	if tail ~= "" then
		TweenService:Create(
			Look.epithetLabel,
			TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, 0.28),
			{ TextTransparency = 0.1 }
		):Play()
	end
end

-- ----------------------------------------------------------- phase ticks

-- A mark on the track at every phase boundary the row declares, in the
-- theme's tick colour and the theme's idea of what a mark looks like (a
-- crack for the ice, a rivet-and-line for the Admiral, a nick for the rest),
-- plus the enrage line where the row's `enrageBelow` doesn't already sit on
-- one. Only boundaries strictly inside the bar are drawn: a row whose phases
-- do not advance on health at all (the Kraken - every row after the first is
-- `below = 0.0`) honestly gets no ticks rather than a pile of them at zero.
function Look.setTicks(row: any)
	for _, tick in Look.ticks do
		tick.inst:Destroy()
		if tick.head then
			tick.head:Destroy()
		end
	end
	table.clear(Look.ticks)
	if not Look.tickRoot or row == nil then
		return
	end
	local kind = (Look.theme and Look.theme.ornament) or "none"
	local marks: { number } = {}
	if type(row.phases) == "table" then
		for i, phase in row.phases do
			local at = tonumber(phase.below)
			if i > 1 and at and at > 0.02 and at < 0.98 then
				table.insert(marks, at)
			end
		end
	end
	local rage = tonumber(row.enrageBelow)
	local rageMark = false
	if rage and rage > 0.02 and rage < 0.98 then
		local shared = false
		for _, at in marks do
			if math.abs(at - rage) < 0.015 then
				shared = true
			end
		end
		if not shared then
			table.insert(marks, rage)
			rageMark = true
		end
	end

	for index, at in marks do
		local isRage = rageMark and index == #marks
		local inst = Look.piece(Look.tickRoot, {
			Name = "Tick",
			Size = UDim2.new(0, if isRage then 3 else 2, 1, if kind == "brass" then -4 else 2),
			Position = UDim2.new(at, 0, 0.5, 0),
			Rotation = if kind == "icicles" then 14 elseif kind == "whirlpool" then 8 else 0,
			BackgroundColor3 = if isRage then Look.pick("glow") else Look.pick("tick"),
			BackgroundTransparency = if isRage then 0.2 else 0.35,
			ZIndex = 6,
		})
		Look.round(inst, 1)
		local head = nil
		if kind == "brass" then
			head = Look.piece(Look.tickRoot, {
				Name = "TickHead",
				Size = UDim2.fromOffset(5, 5),
				Position = UDim2.new(at, 0, 0, 1),
				BackgroundColor3 = Look.pick("tick"),
				BackgroundTransparency = 0.2,
				ZIndex = 6,
			})
			Look.round(head, 3)
		end
		table.insert(Look.ticks, { inst = inst, at = at, rage = isRage, head = head })
	end
end

-- Crossing one is the fight changing gear: the mark it crossed flares, and
-- the bar takes the smallest possible knock so the change is felt without
-- competing with the telegraph the boss is drawing on the ground.
function Look.phaseFlourish(index: number?)
	local best, bestGap = nil, math.huge
	for _, tick in Look.ticks do
		local gap = math.abs(tick.at - Look.value)
		if gap < bestGap then
			best = tick
			bestGap = gap
		end
	end
	if best and bestGap <= 0.1 then
		best.inst.BackgroundTransparency = 0
		best.inst.Size = UDim2.new(0, 5, 1, 8)
		TweenService:Create(best.inst, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			BackgroundTransparency = if best.rage then 0.2 else 0.35,
			Size = UDim2.new(0, if best.rage then 3 else 2, 1, 2),
		}):Play()
	end
	Look.flashLevel = math.max(Look.flashLevel, math.clamp(0.45 + 0.08 * (index or 1), 0, 0.8))
	Look.shakeLevel = math.max(Look.shakeLevel, 0.4 * (Look.motion().shake or 1))
end

-- ---------------------------------------------------------------- paint

-- The three fill states, in the boss's own palette. The seal still outranks
-- the rage exactly as it did - whether you can hurt it at all matters more
-- than how angry it is - and it paints FLAT over the theme's gradient, which
-- is the point: a sealed bar should not look like a healthy one.
function Look.paintFill(seal: string?, enraged: boolean)
	Look.enraged = enraged == true
	if seal == "open" then
		Look.fillGrad.Color = ColorSequence.new(BAR_OPEN_COLOR)
		Look.fillBase = 0
	elseif seal == "sealed" then
		Look.fillGrad.Color = ColorSequence.new(BAR_SEALED_COLOR)
		Look.fillBase = BAR_SEALED_FADE
	else
		Look.fillGrad.Color = Look.sequence(Look.pick("fill"))
		Look.fillBase = if Look.theme and Look.theme.ornament == "lantern" then 0.42 else 0
	end
	barFill.BackgroundTransparency = Look.fillBase
	Look.glow.Color = Look.pick("glow")
	Look.glow.Transparency = if seal == "sealed" then 0.85 else (if Look.enraged then 0.25 else 0.55)
	Look.glow.Thickness = if Look.enraged
		then 1.5 + ((Look.theme.enrage and Look.theme.enrage.glow) or 0.35) * 4
		else 1.5
	if Look.ghost then
		Look.ghost.BackgroundColor3 = Look.pick("chip")
	end
	if Look.fillCore then
		Look.fillCore.BackgroundColor3 = Look.pick("ornament")
	end
	if Look.track then
		Look.track.BackgroundColor3 = Look.pick("track")
	end
	nameLabel.TextColor3 = Look.pick("text")
	if Look.epithetLabel then
		Look.epithetLabel.TextColor3 = Look.pick("epithet")
	end
	-- ENRAGE IS PER THEME, not "the bar goes red": the ornament changes with
	-- the palette - embers flare, the ice cracks and lights orange, the lure
	-- goes magenta - and the motion steps up a gear.
	local ornament = Look.pick("ornament")
	local ornamentAlt = if Look.enraged then Look.pick("ornament") else Look.pick("ornamentAlt")
	local mode = Look.enraged and Look.theme.enrage and Look.theme.enrage.ornament or nil
	for _, mote in Look.motes do
		if mote.inst:IsA("Frame") and mote.fade ~= 1 then
			mote.inst.BackgroundColor3 = if mote.alt then ornamentAlt else ornament
		end
		mote.rage = Look.enraged
		if mode == "crack" and mote.mode == "sway" then
			mote.inst.Rotation = (mote.rot or 0) + (if Look.enraged then 9 else 0)
		end
	end
	for _, tick in Look.ticks do
		tick.inst.BackgroundColor3 = if tick.rage then Look.pick("glow") else Look.pick("tick")
	end
end

-- The health read, and the two things a drop is allowed to do: leave a chip
-- trail behind, and - only for a real hit, 3% of the boss's maximum or more -
-- flash the fill and knock the bar. Both are scaled by the theme so a heavy
-- boss hits harder than a quick one.
function Look.setHealth(fraction: number)
	fraction = math.clamp(fraction, 0, 1)
	local motion = Look.motion()
	local drop = Look.value - fraction
	if drop > 0.0005 then
		Look.ghostValue = math.max(Look.ghostValue, Look.value)
		Look.ghostWait = motion.chipHold or 0.35
		if drop >= 0.03 then
			Look.flashLevel = 1
			Look.shakeLevel = math.min(1, drop * 10) * (motion.shake or 1)
		else
			Look.flashLevel = math.max(Look.flashLevel, 0.3)
		end
	elseif fraction > Look.value then
		Look.ghostValue = fraction
	end
	Look.value = fraction
	TweenService:Create(barFill, TweenInfo.new(BAR_FILL_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.fromScale(fraction, 1),
	}):Play()
end

-- Back to a bar at rest: the trail, the flash, the knock and the epithet all
-- cleared, so the next boss to be picked up cannot inherit this one's state.
function Look.reset()
	Look.value = 1
	Look.ghostValue = 1
	Look.ghostWait = 0
	Look.flashLevel = 0
	Look.shakeLevel = 0
	Look.enraged = false
	if Look.ghost then
		Look.ghost.Size = UDim2.fromScale(1, 1)
		Look.ghost.BackgroundTransparency = 1
	end
	if Look.flash then
		Look.flash.BackgroundTransparency = 1
	end
	if Look.epithetLabel then
		Look.epithetLabel.TextTransparency = 1
	end
	barFrame.Position = UDim2.new(0.5, 0, 0, BAR_Y)
end

-- ------------------------------------------------------------- the motion

-- ONE loop for the whole HUD. It leaves on its first line while the bar is
-- hidden, and while it is up it only writes the properties this theme asked
-- to move - a still theme (`motion.pulse` 0, no motes) costs a clamp and a
-- couple of compares per frame.
function Look.step(dt: number)
	if not barFrame or not barFrame.Visible then
		return
	end
	dt = math.min(dt, 0.1)
	Look.clock += dt
	local motion = Look.motion()
	local rage = if Look.enraged then ((Look.theme.enrage and Look.theme.enrage.pulse) or 1.6) / 1.6 else 1

	-- The chip trail: hold where the health was, then ease down to where it is.
	if Look.ghost then
		if Look.ghostValue > Look.value + 0.001 then
			if Look.ghostWait > 0 then
				Look.ghostWait -= dt
			else
				local fall = math.max(0.05, motion.chipFall or 0.5)
				Look.ghostValue = math.max(Look.value, Look.ghostValue - dt / fall)
			end
			Look.ghost.Size = UDim2.fromScale(Look.ghostValue, 1)
			Look.ghost.BackgroundTransparency = 0.3
		elseif Look.ghost.BackgroundTransparency < 1 then
			Look.ghostValue = Look.value
			Look.ghost.Size = UDim2.fromScale(Look.value, 1)
			Look.ghost.BackgroundTransparency = 1
		end
	end

	-- The hit flash and the knock, both decaying to nothing within a beat.
	if Look.flashLevel > 0 and Look.flash then
		Look.flashLevel = math.max(0, Look.flashLevel - dt * 4)
		Look.flash.BackgroundTransparency = 1 - Look.flashLevel * 0.6
	end
	if Look.shakeLevel > 0 then
		Look.shakeLevel = math.max(0, Look.shakeLevel - dt * 3.5)
		local swing = math.sin(Look.clock * 46) * Look.shakeLevel * 5
		local lift = math.cos(Look.clock * 38) * Look.shakeLevel * 2
		barFrame.Position = UDim2.new(0.5, swing, 0, BAR_Y + lift)
		if Look.shakeLevel <= 0 then
			barFrame.Position = UDim2.new(0.5, 0, 0, BAR_Y)
		end
	end

	-- The fill's own breath, and the gradient turning for a theme that swirls.
	if Look.fillGrad then
		if (motion.pulse or 0) > 0 then
			local breath = 0.5 + 0.5 * math.sin(Look.clock * (motion.pulse or 0) * rage * 6.28)
			barFill.BackgroundTransparency = math.clamp((Look.fillBase or 0) + breath * 0.12, 0, 1)
			if Look.fillCore then
				Look.fillCore.BackgroundTransparency = math.clamp(0.05 + breath * 0.35, 0, 1)
			end
		end
		if (motion.rotate or 0) ~= 0 then
			Look.fillGrad.Rotation = (Look.fillGrad.Rotation + (motion.rotate or 0) * rage * dt) % 360
		elseif (motion.drift or 0) > 0 and Look.theme.ornament == "brass" then
			Look.fillGrad.Offset =
				Vector2.new(math.sin(Look.clock * (motion.drift or 0) * 6.28) * 0.06, Look.fillGrad.Offset.Y)
		end
	end

	-- The ornaments. Six modes, one branch each, and a mote whose theme is at
	-- rest never appears in this list at all.
	for _, mote in Look.motes do
		local inst = mote.inst
		if inst.Parent == nil then
			continue
		end
		local speed = (mote.speed or 1) * rage
		if mote.mode == "bob" then
			inst.Position =
				UDim2.new(inst.Position.X.Scale, 0, 0, 1 + math.sin(Look.clock * speed + mote.phase) * (mote.amp or 2))
		elseif mote.mode == "rise" then
			local travel = ((mote.phase or 0) + Look.clock * speed * (motion.drift or 0.3) * 2) % 1
			inst.Position = UDim2.new(mote.x or 0.5, 0, 1 - travel * 1.35, 0)
			inst.BackgroundTransparency = math.clamp((mote.fade or 0.2) + travel * (1 - (mote.fade or 0.2)), 0, 1)
		elseif mote.mode == "flow" then
			local travel = ((mote.phase or 0) + Look.clock * speed * (motion.drift or 0.1)) % 1
			inst.Position = UDim2.new(travel, 0, mote.y or 0.5, 0)
		elseif mote.mode == "drift" then
			local wander = Look.clock * speed + mote.phase
			inst.Position =
				UDim2.new((mote.x or 0.5) + math.sin(wander * 0.6) * 0.02, 0, 0.5, math.cos(wander) * (mote.amp or 4))
			inst.BackgroundTransparency = math.clamp((mote.fade or 0.25) + 0.25 + math.sin(wander * 1.3) * 0.25, 0, 1)
		elseif mote.mode == "sway" then
			inst.Rotation = (mote.rot or 0)
				+ math.sin(Look.clock * speed + mote.phase) * (mote.amp or 3)
				+ (if mote.rage and Look.theme.enrage and Look.theme.enrage.ornament == "crack" then 9 else 0)
		elseif mote.mode == "spin" then
			inst.Rotation = (inst.Rotation + speed * dt) % 360
		elseif mote.mode == "twinkle" then
			inst.BackgroundTransparency =
				math.clamp((mote.fade or 0.6) + math.sin(Look.clock * speed + mote.phase) * 0.3, 0, 1)
		end
	end

	-- The viewport can change under us (a phone rotating, a window dragged).
	-- Twice a second is far cheaper than a signal per boss and never misses.
	if Look.clock - Look.layoutAt > 0.5 then
		Look.layoutAt = Look.clock
		Look.layout()
	end
end

-- ------------------------------------------------------------ seam meters

-- The contract's sanitizer, the same rule as PyreliskBodyController's
-- `unitOf`: absent, wrong type or NaN all read as 0. A meter is only ever
-- 0..1, so anything outside that is clamped rather than trusted.
local function unitOf(value: any): number
	if type(value) ~= "number" or value ~= value then
		return 0
	end
	return math.clamp(value, 0, 1)
end

-- One meter's fill. The colour and the label only change on the EDGE into or
-- out of full, so a meter ticking up does not restart the flash every frame.
local function drawMeter(meter, value: number)
	TweenService:Create(meter.fill, TweenInfo.new(BAR_FILL_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.fromScale(value, 1),
	}):Play()
	local full = value >= 1
	if full == meter.full then
		return
	end
	meter.full = full
	local seam = Look.seam()
	meter.fill.BackgroundColor3 = if full then seam.full else seam.fill
	meter.label.Text = if full then meter.base .. SEAM_READY else meter.base
	if full then
		-- The whole reward for filling it is one short flash, on purpose: the
		-- server opens the window a moment later and the stagger card and the
		-- bar's own open state say the rest. Nothing loops, so there is no
		-- tween to own or cancel.
		meter.fill.BackgroundTransparency = SEAM_FLASH_FADE
		TweenService:Create(
			meter.fill,
			TweenInfo.new(SEAM_FLASH_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = 0 }
		):Play()
	else
		meter.fill.BackgroundTransparency = 0
	end
end

-- Back to empty and hidden. Called as the bar is dropped, so the next boss
-- to be picked up cannot inherit the last one's flanks.
local function resetSeams()
	seamFrame.Visible = false
	for _, meter in { seamL, seamR } do
		meter.full = false
		meter.fill.Size = UDim2.fromScale(0, 1)
		meter.fill.BackgroundColor3 = Look.seam().fill
		meter.fill.BackgroundTransparency = 0
		meter.label.Text = meter.base
	end
end

-- THE STAGING GATE. The row is shown if and only if the tracked model carries
-- at least one meter attribute, tested by PRESENCE - `GetAttribute ~= nil` -
-- and never by value, because a server publishing 0 is publishing a real
-- empty meter that has to draw. Every boss in the game today, and Pyrelisk
-- itself until the server half lands, answers nil to both and leaves the row
-- exactly where `build` left it: invisible, and a sibling of the health bar
-- rather than a child, so the HUD above is untouched.
local function refreshSeams()
	local model = current
	if not model then
		seamFrame.Visible = false
		return
	end
	local hasL = model:GetAttribute(ATTR_SEAM_L) ~= nil
	local hasR = model:GetAttribute(ATTR_SEAM_R) ~= nil
	if not (hasL or hasR) then
		seamFrame.Visible = false
		return
	end
	seamFrame.Visible = true
	-- An attribute that has not landed yet reads 0 through the sanitizer, so
	-- a half-published pair still draws a truthful pair of bars.
	drawMeter(seamL, unitOf(model:GetAttribute(ATTR_SEAM_L)))
	drawMeter(seamR, unitOf(model:GetAttribute(ATTR_SEAM_R)))
end

-- ------------------------------------------------------------- the act rows

-- One pip strip against one bitmask. Bit (i-1) SET means pip i is lit, which
-- on both masks means "still standing" - they are SURVIVOR masks, not progress
-- counters, so the row empties as the fight is won.
--
-- Written only on the EDGE, like `drawMeter`'s colour: these tick at whatever
-- rate the server publishes and repainting fourteen frames every time is
-- fourteen property writes for nothing.
function Act.drawPips(set: { any }, mask: number)
	local seam = Look.seam()
	for index, entry in set do
		local lit = bit32.btest(mask, bit32.lshift(1, index - 1))
		if lit ~= entry.lit then
			entry.lit = lit
			entry.pip.BackgroundColor3 = if lit then seam.fill else seam.track
			entry.pip.BackgroundTransparency = if lit then 0 else 0.35
		end
	end
end

-- A published bitmask made safe: absent, wrong type or NaN reads as 0, and
-- bits above the row's width are dropped rather than trusted - the same rule
-- PyreliskBodyController's `maskOf` follows, and for the same reason. The
-- PRESENCE test happens before this is ever called.
function Act.maskOf(value: any, count: number): number
	if type(value) ~= "number" or value ~= value or value < 1 then
		return 0
	end
	return bit32.band(math.floor(value), bit32.lshift(1, count) - 1)
end

-- Back to empty and hidden, as the bar is dropped - the seam row's own rule,
-- so the next boss cannot inherit this one's act.
function Act.reset()
	if not Act.frame then
		return
	end
	Act.frame.Visible = false
	for _, row in Act.rows do
		row.Visible = false
	end
	for _, meter in { Act.armL, Act.armR } do
		meter.full = false
		meter.fill.Size = UDim2.fromScale(0, 1)
		meter.fill.BackgroundColor3 = Look.seam().fill
		meter.fill.BackgroundTransparency = 0
		meter.label.Text = meter.base
	end
	for _, entry in Act.pillarPips do
		entry.lit = true
		entry.pip.BackgroundColor3 = Look.seam().fill
		entry.pip.BackgroundTransparency = 0
	end
end

-- THE STAGING GATE, twice over. Each row is shown if and only if the tracked
-- model carries at least one of ITS OWN attributes, tested by PRESENCE - never
-- by value, because every one of these three publishes a meaningful 0 (an arm
-- at the point of breaking, eight fallen pillars). A `not value` test would
-- hide the row at exactly the moment it matters most.
--
-- The arms are gated INDIVIDUALLY inside their shared row: act 3 keeps
-- whichever arm survived and nils the other (CreatureService clears
-- ATTR.PY_ARM_L/R when an arm is spent), so a one-armed colossus draws one bar
-- rather than one bar and one permanently-empty ghost.
function Act.refresh()
	local model = current
	if not Act.frame then
		return
	end
	if not model then
		Act.frame.Visible = false
		return
	end
	local hasL = model:GetAttribute(Act.ATTR.armL) ~= nil
	local hasR = model:GetAttribute(Act.ATTR.armR) ~= nil
	Act.rows.arms.Visible = hasL or hasR
	Act.armL.track.Visible = hasL
	Act.armR.track.Visible = hasR
	if hasL then
		drawMeter(Act.armL, unitOf(model:GetAttribute(Act.ATTR.armL)))
	end
	if hasR then
		drawMeter(Act.armR, unitOf(model:GetAttribute(Act.ATTR.armR)))
	end

	-- THE ROCK ROW IS GONE (2026-09-12): `PyreliskRocks` and `PyreliskCore`
	-- were read here and neither exists any more. Nothing stands between the
	-- arms and the heart now but the collapse, and the collapse's own read is
	-- the colossus sinking into the caldera rather than a meter.
	--
	-- ACT 3, staged and inert. `PyreliskPillars` is published on the HEART's
	-- model (SS7.3) and the heart's own slice is what starts publishing it, so
	-- today this is always nil and this row is always hidden - which is the
	-- point of staging it: the attribute is frozen, so the read side can be
	-- written and reviewed once instead of being bolted on beside a fight
	-- that is already shipping.
	local pillars = model:GetAttribute(Act.ATTR.pillars)
	Act.rows.pillars.Visible = pillars ~= nil
	if pillars ~= nil then
		Act.drawPips(Act.pillarPips, Act.maskOf(pillars, Act.PILLARS))
	end

	Act.frame.Visible = Act.rows.arms.Visible or Act.rows.pillars.Visible
end

local function refresh()
	local model = current
	if not model then
		return
	end
	local health = tonumber(model:GetAttribute(ATTR_HEALTH)) or 0
	local maxHealth = math.max(1, tonumber(model:GetAttribute(ATTR_MAX_HEALTH)) or 1)
	-- The same tween as ever, plus the two things a DROP now does: leave a
	-- chip trail behind the fill, and flash (and knock) the bar on a real hit.
	Look.setHealth(health / maxHealth)
	-- Where the HUD learns the phase: the same health read the bar is drawn
	-- from. Only a CHANGE is handed on - refresh fires on every point of
	-- damage, and setBoss with the phase it already has would restart the
	-- boss theme several times a second.
	local phase = phaseIndexOf(currentRow, health / maxHealth)
	if phase ~= currentPhase then
		local was = currentPhase
		currentPhase = phase
		if currentRow then
			MusicController.setBoss(currentRow.id, phase)
		end
		-- Crossing a boundary the bar has DRAWN (see Look.setTicks) gets a
		-- flourish on the mark it crossed. Only ever forward, and never on the
		-- first read of a bar picked up mid-fight (`was` is nil there).
		if was ~= nil and phase ~= nil and phase > was then
			Look.phaseFlourish(phase)
		end
	end

	local enraged = model:GetAttribute(ATTR_ENRAGED) == true
	-- The seal outranks the rage on the FILL - whether you can hurt it at all
	-- matters more than how angry it is - but the name keeps carrying the
	-- rage, so neither piece of news is lost.
	local seal = sealOf(model)
	-- The same three states, in this boss's palette: open is still the gold
	-- the card speaks in, sealed is still the cold half-lit plate, and an
	-- ordinary boss gets its own theme's fill - enraged or not, and enrage is
	-- now that theme's idea of enrage rather than "the bar goes red".
	Look.paintFill(seal, enraged)

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

-- IS THE LOCAL PLAYER IN A BOSS FIGHT, as far as the CLIENT can tell: this
-- controller holds a bar exactly while one is engaged, which makes it the
-- nearest thing the client has to the server's `BossService.fightFor`.
--
-- Feedback only. FishingController and BoatController read it to refuse input
-- before it costs a round trip; both servers refuse it again regardless, and
-- they are the authority.
function BossHudController.isEngaged(): boolean
	return current ~= nil and current.Parent ~= nil
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
	currentPhase = nil
	-- The other half of the pairing in "the score" above: no bar, no voice,
	-- no boss theme. Unconditional so a hand-over and a death take the same
	-- path, and safe to repeat - both calls are idempotent with nil.
	Sfx.setVoice(nil)
	MusicController.setBoss(nil)
	sealDrawn = nil
	drawSeal(nil)
	resetSeams()
	Act.reset()
	Look.reset()
	barFrame.Visible = false
end

local function track(model: Model)
	untrack()
	current = model
	currentRow = rowFor(model)
	ward = wardOf(currentRow)

	-- Taking the bar is taking the fight: the boss's voice becomes the one
	-- Sfx speaks in, and its theme starts. The phase is worked out HERE
	-- rather than left to the refresh below because a bar picked up
	-- mid-fight is already in phase 2 or 3 - starting at phase 1 and
	-- correcting a frame later would restart the theme in front of the
	-- player. (See "the score" above for why this lives in track/untrack.)
	local bossId = if currentRow then currentRow.id else nil
	Sfx.setVoice(bossId)
	if bossId then
		local health = tonumber(model:GetAttribute(ATTR_HEALTH)) or 0
		local maxHealth = math.max(1, tonumber(model:GetAttribute(ATTR_MAX_HEALTH)) or 1)
		currentPhase = phaseIndexOf(currentRow, health / maxHealth)
		MusicController.setBoss(bossId, currentPhase)
	end

	-- THE BAR BECOMES THIS BOSS'S BAR. Rebuilt only when the theme actually
	-- differs, so a re-adopt mid-fight does not flicker; the name and the
	-- epithet are the two halves of the ROW's own `name` (split at the first
	-- comma), falling back to the model's BossName attribute if the model
	-- somehow has no row at all.
	Look.apply(if currentRow then currentRow.id else nil)
	Look.setName(if currentRow then currentRow.name else model:GetAttribute(ATTR_BOSS_NAME) or "BOSS")
	Look.setTicks(currentRow)
	barFill.Size = UDim2.fromScale(1, 1)
	barFrame.Visible = true
	for _, attr in { ATTR_HEALTH, ATTR_MAX_HEALTH, ATTR_ENRAGED, ATTR_EXPOSED } do
		table.insert(connections, model:GetAttributeChangedSignal(attr):Connect(refresh))
	end
	-- Watched on EVERY boss, exactly as Exposed is above: a signal costs
	-- nothing on a model that never fires it, and watching unconditionally is
	-- what lets the row appear the moment a server publishes its first meter
	-- mid-fight. Nothing is drawn until `refreshSeams` finds the attributes
	-- actually there. Both connections live in `connections`, so `untrack`
	-- disconnects them with the health bar's own.
	for _, attr in { ATTR_SEAM_L, ATTR_SEAM_R } do
		table.insert(connections, model:GetAttributeChangedSignal(attr):Connect(refreshSeams))
	end
	-- The act rows, watched the same way and for the same reason: a signal
	-- costs nothing on a model that never fires it, and watching every boss
	-- unconditionally is what lets a row appear the moment the server
	-- publishes its first value mid-fight. Same `connections` list, so
	-- `untrack` disconnects all three with the rest.
	for _, attr in Act.ATTR do
		table.insert(connections, model:GetAttributeChangedSignal(attr):Connect(Act.refresh))
	end
	-- Draw whatever state it's already in without carding it: picking the bar
	-- up mid-window is not the window opening.
	sealDrawn = sealOf(model)
	drawSeal(sealDrawn)
	refresh()
	refreshSeams()
	Act.refresh()

	-- The rise that was in flight before we got here (RISE_GRACE): taking up
	-- this boss's bar is the proof it was addressed to us.
	if pendingRise then
		local mine = model:GetAttribute(ATTR_BOSS_NAME)
		if os.clock() > pendingRise.expires then
			pendingRise = nil
		elseif type(mine) == "string" and pendingRise.name == mine then
			local name = pendingRise.name
			pendingRise = nil
			MusicController.bossIntro()
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
			-- The stinger rides the CARD, not the event, in both places the
			-- card can be shown (here and the RISE_GRACE catch-up in
			-- `track`): the card is already the "this rise is yours" test,
			-- and only one of the two paths ever draws a given rise.
			MusicController.bossIntro()
			-- ...but not the CARD, while a boss intro cinematic is running: it
			-- draws its own title card on this exact beat (the roar at
			-- 0.85 * riseTime), and two cards on one roar is one too many.
			if Players.LocalPlayer:GetAttribute("BossCutscene") ~= true then
				showCard(string.upper(tostring(name or "THE BOSS")), "rises from the deep", BAR_COLOR)
			end
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
			MusicController.finale()
			showCard(
				"THE MAELSTROM FALLS SILENT",
				string.format("%s is slain - the saga is complete", tostring(extra.name)),
				Theme.Color.gold
			)
			return
		end
		MusicController.victory()
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
