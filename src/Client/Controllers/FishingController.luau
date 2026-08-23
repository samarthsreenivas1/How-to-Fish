--!nonstrict
-- FishingController.luau
-- Casts the rod and drives the reel minigame it opens into.
--
-- Right-click starts the cast swing on the spot (RodViewmodelController
-- plays the Blender-authored clip in Shared/Data/RodCastAnim) and asks the
-- server - FishingService is what actually starts a cast. Once accepted, the
-- bobber leaves the rod tip at the clip's release moment, arcs out to the
-- landing point with the line trailing back to the tip, and the reel bar
-- opens when it lands (no separate "wait for a bite" step yet; that can come
-- later if it turns out to be worth the wait). A rejection just eases the
-- rod back to idle.
--
-- The bar is simulated locally from the server's seed (ReelMath is pure and
-- shared - see FishingService) so a click can flash on the same frame it's
-- pressed; the server independently replays the same layout and stays
-- authoritative. There's no dedicated catch button - a left click or tap
-- anywhere on screen, or Space, all register a click, so the mouse stays
-- locked to the centre of the screen the whole time (no setCursorFree
-- here) exactly like the rest of first-person play.
--
-- No on-screen cast prompt either - right-click just casts whenever you're
-- holding a rod and not already mid-cast (tryCast() no-ops otherwise). This
-- means touch has no way to trigger a cast right now; a tap target will need
-- to come back for touch specifically if that's still wanted.
--
-- A cast only goes where you're looking, and only if that's open water within
-- reach (CastAim, shared with the server). Aiming at sand, the dock, or the
-- sky, or at water too far out, shows a short banner and doesn't swing.
--
-- Hotkeys go through ContextActionService, not UserInputService.InputBegan:
-- Roblox's own camera scripts already bind several keys that way, which
-- marks the keypress game-processed and makes a plain InputBegan handler
-- miss it (this bit InventoryController's `I` key first - see context.md).

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Equipment = require(Shared.Config.Equipment)
local Bosses = require(Shared.Data.Bosses)
local RodCastAnim = require(Shared.Data.RodCastAnim)
local CastAim = require(Shared.Modules.CastAim)
local Rods = require(Shared.Data.Rods)
local Remotes = require(Shared.Net.Remotes)

local Theme = require(script.Parent.Parent.UI.Theme)
local Minigames = require(script.Parent.Parent.Minigames)
local RodViewmodelController = require(script.Parent.RodViewmodelController)
local Vfx = require(script.Parent.Parent.Modules.Vfx)
local Sfx = require(script.Parent.Parent.Modules.Sfx)

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

local FishingController = {}

-- Must match RodService.EQUIPPED_NAME; server modules aren't requireable
-- from the client, so this is the same literal-name pattern
-- RodViewmodelController already uses for the same reason.
local EQUIPPED_NAME = "EquippedRod"

local BOB_AMPLITUDE = 0.15
local BOB_FREQUENCY = 1.1 -- cycles per second
local GRADE_BANNER_DURATION = 2.6

-- The bobber's flight from the rod tip to the landing point after release.
local ARC_DURATION = 0.55 -- seconds
local ARC_HEIGHT = 3.5 -- studs of lift at the midpoint

-- If the server never answers a cast request, stop waiting and let the
-- player try again rather than leaving casting locked out.
local PENDING_TIMEOUT = 3

-- Sparkle colour of the catch pop, by the creature's rarity.
local RARITY_COLOR = {
	Common = Color3.fromRGB(240, 244, 248),
	Uncommon = Color3.fromRGB(120, 220, 130),
	Rare = Color3.fromRGB(96, 178, 232),
	Epic = Color3.fromRGB(190, 120, 240),
	Legendary = Color3.fromRGB(255, 200, 80),
}

-- Effects timing / sizing.
local SWING_TRAIL_LIFETIME = 0.14 -- seconds a point on the rod-tip trail lingers
local SWING_TRAIL_HALF_WIDTH = 0.22 -- studs either side of the tip
local RIPPLE_INTERVAL = 0.9 -- seconds between rings while the bobber sits
local LAND_SPLASH = 0.8

local gui: ScreenGui
local bannerLabel: TextLabel

-- Active cast (generic, minigame-agnostic): { id, seed, config, startedAt,
-- finished, mg }. The chosen minigame (config.kind) owns cast.mg and its own
-- view/input; this controller only runs the cast lifecycle around it.
local cast = nil

-- The active minigame's client module and the context handed to it. Set when a
-- cast is accepted, cleared in endCast.
local mg = nil
local mgCtx = nil

-- os.clock() of a right-click the server hasn't answered yet. Doubles as
-- when the cast swing started, so the bobber can launch at the clip's
-- release moment rather than whenever the reply happens to arrive.
local pendingCast: number? = nil

local bobber: BasePart? = nil
local lineTip: BasePart? = nil
local bobberBaseY = 0

-- The bobber's flight, while it's in the air: { from, to, startedAt, onLanded }
local arc = nil

-- Effects: the ring loop around a floating bobber, and the invisible part
-- that carries the rod-tip trail during the cast swing (pinned to the tip
-- each frame like lineTip is).
local ripples = nil
local swingTrail: BasePart? = nil

-- ============================================================ Bobber + line

local function destroyRig()
	arc = nil
	if ripples then
		ripples.stop()
		ripples = nil
	end
	if bobber then
		bobber:Destroy()
		bobber = nil
	end
	if lineTip then
		lineTip:Destroy()
		lineTip = nil
	end
	-- The rod mesh's own idle line + bobber come back once the cast is gone.
	RodViewmodelController.setTackleVisible(true)
end

-- Builds the bobber at the rod tip and sends it flying to `landingPos`;
-- `onLanded` runs once it gets there (see updateRig).
local function buildRig(landingPos: Vector3, onLanded: () -> ())
	destroyRig()

	-- Hide the idle tackle baked into the rod mesh: the line is out on the
	-- water now, and two bobbers would look wrong.
	RodViewmodelController.setTackleVisible(false)

	local start = RodViewmodelController.getTipPosition() or landingPos

	local ball = Instance.new("Part")
	ball.Name = "Bobber"
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.new(0.9, 0.9, 0.9)
	ball.Color = Color3.fromRGB(235, 238, 242)
	ball.Material = Enum.Material.SmoothPlastic
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CastShadow = false
	ball.Position = start
	ball.Parent = Workspace

	local bobberAttach = Instance.new("Attachment")
	bobberAttach.Parent = ball

	-- A tiny, invisible part that FishingController repositions to the rod
	-- tip every frame - Beams need an Attachment parented to a BasePart, and
	-- the tip itself is just a computed point, not a real part.
	local tip = Instance.new("Part")
	tip.Name = "FishingLineTip"
	tip.Anchored = true
	tip.CanCollide = false
	tip.CanQuery = false
	tip.CastShadow = false
	tip.Transparency = 1
	tip.Size = Vector3.new(0.1, 0.1, 0.1)
	tip.CFrame = CFrame.new(RodViewmodelController.getTipPosition() or camera.CFrame.Position)
	tip.Parent = Workspace

	local tipAttach = Instance.new("Attachment")
	tipAttach.Parent = tip

	local beam = Instance.new("Beam")
	beam.Name = "Line"
	beam.Attachment0 = tipAttach
	beam.Attachment1 = bobberAttach
	beam.Width0 = 0.05
	beam.Width1 = 0.05
	beam.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255))
	beam.Transparency = NumberSequence.new(0.15)
	beam.FaceCamera = true
	beam.Parent = tip

	bobber = ball
	lineTip = tip
	bobberBaseY = landingPos.Y
	arc = { from = start, to = landingPos, startedAt = os.clock(), onLanded = onLanded }
end

-- Where the bobber lands: wherever the camera is looking, if that's open
-- water within reach of the character (CastAim has the rules). Returns nil
-- and a reason to show the player otherwise. Sent to the server with the
-- cast request; the server re-checks it and echoes back the point both sides
-- then use, so the creature surfaces exactly where the bobber is.
-- The data row for the rod actually in hand. The server stamps `RodId` on the
-- welded rod (same attribute RodViewmodelController reads), so the client can
-- gate its aim by the same rod the server will validate against - a long-cast
-- perk has to widen BOTH or the player is told "get closer" about water the
-- server would happily accept.
local function equippedRodData()
	local character = player.Character
	local worldRod = character and character:FindFirstChild(EQUIPPED_NAME)
	local rodId = worldRod and worldRod:GetAttribute("RodId")
	return rodId and Rods.items[rodId] or nil
end

local function aimLanding(): (Vector3?, string?)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local from = (root and (root :: BasePart).Position) or camera.CFrame.Position
	return CastAim.aim(from, camera.CFrame.Position, camera.CFrame.LookVector, equippedRodData())
end

-- A short-lived ribbon off the rod tip while the cast swings, so the whip
-- reads as fast. Lives for the clip, then fades.
local function startSwingTrail()
	if swingTrail then
		swingTrail:Destroy()
		swingTrail = nil
	end
	local tipPos = RodViewmodelController.getTipPosition()
	if not tipPos then
		return
	end

	local part = Vfx.anchorPart(tipPos)
	part.Name = "SwingTrail"
	local trail = Vfx.trail(part, SWING_TRAIL_HALF_WIDTH, Vfx.Color.line, SWING_TRAIL_LIFETIME)
	swingTrail = part

	task.delay(RodCastAnim.DURATION, function()
		trail.Enabled = false
		task.delay(SWING_TRAIL_LIFETIME + 0.1, function()
			if swingTrail == part then
				swingTrail = nil
			end
			part:Destroy()
		end)
	end)
end

local function updateRig(t: number)
	local tipPos = if lineTip or swingTrail then RodViewmodelController.getTipPosition() else nil
	if lineTip and tipPos then
		lineTip.CFrame = CFrame.new(tipPos)
	end
	if swingTrail and tipPos then
		swingTrail.CFrame = CFrame.new(tipPos)
	end
	if bobber then
		if arc then
			-- In flight: a straight run to the landing point with a parabolic
			-- lift, so it reads as thrown rather than slid across the water.
			local s = math.clamp((os.clock() - arc.startedAt) / ARC_DURATION, 0, 1)
			local lift = ARC_HEIGHT * 4 * s * (1 - s)
			bobber.Position = arc.from:Lerp(arc.to, s) + Vector3.new(0, lift, 0)
			if s >= 1 then
				local landed = arc.onLanded
				arc = nil
				landed()
			end
		else
			local bob = math.sin(t * BOB_FREQUENCY * (2 * math.pi)) * BOB_AMPLITUDE
			local pos = bobber.Position
			bobber.CFrame = CFrame.new(pos.X, bobberBaseY + bob, pos.Z)
		end
	end
end

-- ============================================================ Reel flow

local function showBanner(text: string, color: Color3)
	bannerLabel.Text = text
	bannerLabel.TextColor3 = color
	bannerLabel.Visible = true
	task.delay(GRADE_BANNER_DURATION, function()
		if bannerLabel.Text == text then
			bannerLabel.Visible = false
		end
	end)
end

local function endCast()
	if mg and mgCtx then
		mg.endCast(mgCtx)
	end
	mg = nil
	mgCtx = nil
	cast = nil
	pendingCast = nil
	destroyRig()
	RodViewmodelController.releaseCast()
end

local function onCastAccepted(castId, seed, config, landing)
	local requestedAt = pendingCast or os.clock()
	pendingCast = nil

	cast = {
		id = castId,
		seed = seed,
		config = config,
		startedAt = os.clock(),
		finished = false,
	}

	-- Resolve the minigame this cast rolled (config.kind, chosen server-side)
	-- and give it the context every minigame needs, without exposing the cast
	-- internals: how to submit an input, and where the bobber is.
	mg = Minigames.get(config.kind)
	mgCtx = {
		cast = cast,
		gui = gui,
		submit = function(round, elapsed, extra)
			Remotes.SubmitReelClick:FireServer(cast.id, round, elapsed, extra)
		end,
		bobberPosition = function()
			return bobber and bobber.Position
		end,
	}

	-- The server's validated landing point, so the bobber sits where the
	-- catch will surface. It always sends one; the re-aim is only a guard
	-- against a malformed reply, and a dead-ahead point the guard's guard.
	local landingPos = if typeof(landing) == "Vector3"
		then landing
		else (aimLanding() or camera.CFrame.Position + camera.CFrame.LookVector * 10)
	-- The landing carries its surface's own height (the waterline, or the
	-- volcano's lava lake up in the crater); the bobber floats just on it.
	landingPos = Vector3.new(landingPos.X, landingPos.Y + 0.25, landingPos.Z)

	-- The line leaves the rod at the clip's release moment, not on the click:
	-- wait out whatever's left of the wind-up (the swing started on the
	-- right-click), launch the bobber, and open the bar once it lands. The
	-- reel clock already runs from `startedAt`; the bar just appears a
	-- little way into it.
	local delay = math.max(0, RodCastAnim.RELEASE_TIME - (os.clock() - requestedAt))
	task.delay(delay, function()
		if not cast or cast.id ~= castId then
			return -- resolved or abandoned while we waited
		end
		buildRig(landingPos, function()
			if not cast or cast.id ~= castId then
				return
			end

			-- Plop, then rings spreading from the bobber for as long as it sits.
			local surfaceY = landingPos.Y - 0.05
			local splashAt = Vector3.new(landingPos.X, surfaceY, landingPos.Z)
			Vfx.splash(splashAt, LAND_SPLASH)
			Sfx.play("bobberPlop", splashAt)
			ripples = Vfx.ripples(function()
				local current = bobber
				return current and Vector3.new(current.Position.X, surfaceY, current.Position.Z)
			end, RIPPLE_INTERVAL)

			-- The bobber's down: hand off to the rolled minigame (shows its
			-- view, binds its input, first render).
			if mg and mgCtx then
				mg.onAccepted(mgCtx)
			end
		end)
	end)
end

-- The server's authoritative regrade of one input; the active minigame
-- reconciles it (e.g. the reel resyncs its miss-driven zone shrink).
local function onReelRoundResult(castId, round, kind, _score)
	if not cast or cast.id ~= castId or not mg or not mgCtx then
		return
	end
	mg.onResult(mgCtx, round, kind)
end

-- Text for a cast the server cancelled (FishingService.cancelCast). One
-- line for every reason (user, 2026-08-22). Dim, not red: it's a
-- consequence of walking away, not an error.
local CANCEL_TEXT = "Cast cancelled."

-- The boss-summon cast (Leviathan's Call): no catch, no minigame, so it comes
-- back as a resolve carrying `summoned` instead of a creature. Announced in the
-- lure-glow teal of the bait that called it, not a rarity colour - it isn't a
-- catch, and shouldn't read like one.
local SUMMON_COLOR = Color3.fromRGB(120, 255, 214)

-- Gravelure's salvage haul: the silt-green of the bait that dragged it up.
local SALVAGE_COLOR = Color3.fromRGB(120, 200, 150)

local function onCastResolved(castId, summary)
	if cast and cast.id ~= castId then
		return
	end
	local catchAt = bobber and bobber.Position
	endCast()

	if type(summary) ~= "table" then
		return
	end

	-- Walked away from (rod put away / swapped, character lost) or left idle
	-- until it timed out: the server landed nothing and granted nothing.
	if summary.cancelled then
		showBanner(CANCEL_TEXT, Theme.Color.textDim)
		return
	end

	-- Gravelure dragged the bottom instead of hooking anything: no catch, so
	-- the banner names the haul instead. Without this branch a salvage cast
	-- would resolve in total silence (the banner below needs a creature).
	if summary.salvage then
		showBanner(string.format("Salvage!  +%d coins", summary.coins or 0), SALVAGE_COLOR)
		if catchAt then
			Vfx.burst(Vector3.new(catchAt.X, catchAt.Y + 0.4, catchAt.Z), SALVAGE_COLOR)
		end
		return
	end

	-- The deep answered instead of biting: the boss is already rising at the
	-- island's arena (BossService), so this cast has nothing to land.
	if summary.summoned then
		local boss = Bosses.items[summary.summoned]
		showBanner(string.format("%s answers the call.", boss and boss.shortName or "The deep"), SUMMON_COLOR)
		return
	end

	local creature = summary.creature

	-- The catch pop: sparkles in the rarity's colour where the bobber was.
	-- (The breach splash itself comes from CreatureVfxController when the
	-- creature appears there, so everyone sees it, not just the caster.)
	if creature and catchAt then
		local color = RARITY_COLOR[creature.rarity] or RARITY_COLOR.Common
		Vfx.burst(Vector3.new(catchAt.X, catchAt.Y + 0.4, catchAt.Z), color)
	end

	-- The reel grade (Hooked / Neutral / Enraged) silently scales the fish's
	-- health and payout server-side; it is deliberately NOT named in the UI
	-- (user, 2026-08-22) - the banner just announces what you caught, coloured
	-- by rarity.
	if creature then
		showBanner(
			string.format("%s (%s)", creature.name, creature.rarity),
			RARITY_COLOR[creature.rarity] or Theme.Color.text
		)
	end
end

local function onCastRejected(reason: string)
	pendingCast = nil
	RodViewmodelController.releaseCast()
	showBanner(tostring(reason), Theme.Color.red)
end

-- ============================================================ Input

local function hasRod(): boolean
	local character = player.Character
	return character ~= nil and character:FindFirstChild(EQUIPPED_NAME) ~= nil
end

local function tryCast()
	if cast or pendingCast or not hasRod() then
		return
	end

	-- Not looking at reachable water: say why and don't swing. The server
	-- applies the same rules, so this is feedback, not the gate itself.
	local landing, reason = aimLanding()
	if not landing then
		showBanner(reason or CastAim.REASON_NOT_WATER, Theme.Color.red)
		return
	end

	local requestedAt = os.clock()
	pendingCast = requestedAt

	-- Client predicts: the rod starts swinging on the click, before the
	-- server has answered. If it rejects, the swing just eases back.
	RodViewmodelController.playCast()
	startSwingTrail()
	Sfx.play("castSwing")
	Remotes.RequestCast:FireServer(landing)

	-- Never let a lost reply lock casting out for good.
	task.delay(PENDING_TIMEOUT, function()
		if pendingCast == requestedAt then
			pendingCast = nil
			RodViewmodelController.releaseCast()
		end
	end)
end

-- The reel-click / minigame input binding now lives inside each minigame
-- module (Client/Minigames/<kind>), bound in its onAccepted and released in
-- its endCast - different minigames need different key sets (Space vs arrows
-- vs hold), so the controller no longer owns a single reel-click action.

-- ============================================================ Lifecycle

function FishingController.init()
	gui = Instance.new("ScreenGui")
	gui.Name = "FishingGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	bannerLabel = Instance.new("TextLabel")
	bannerLabel.Name = "GradeBanner"
	bannerLabel.AnchorPoint = Vector2.new(0.5, 0)
	bannerLabel.Position = UDim2.new(0.5, 0, 0, 40)
	bannerLabel.Size = UDim2.new(0, 420, 0, 32)
	bannerLabel.BackgroundTransparency = 1
	bannerLabel.Font = Theme.Font.header
	bannerLabel.TextSize = 22
	bannerLabel.TextColor3 = Theme.Color.text
	bannerLabel.Visible = false
	bannerLabel.Text = ""
	bannerLabel.Parent = gui

	Remotes.CastAccepted.OnClientEvent:Connect(onCastAccepted)
	Remotes.ReelRoundResult.OnClientEvent:Connect(onReelRoundResult)
	Remotes.CastResolved.OnClientEvent:Connect(onCastResolved)
	Remotes.CastRejected.OnClientEvent:Connect(onCastRejected)
end

function FishingController.start()
	-- Bound for the whole session, same as InventoryController's `I`; tryCast
	-- already no-ops with no rod or mid-cast, so there's no need to
	-- bind/unbind this one dynamically the way the reel click is.
	ContextActionService:BindActionAtPriority("CastRod", function(_, state)
		if state == Enum.UserInputState.Begin then
			tryCast()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.UserInputType.MouseButton2)

	local startTime = os.clock()
	RunService.RenderStepped:Connect(function()
		updateRig(os.clock() - startTime)
		if mg and mgCtx and cast and not cast.finished then
			mg.update(mgCtx)
		end
	end)

	-- Losing the character mid-reel shouldn't strand the cast open server-side.
	player.CharacterRemoving:Connect(function()
		if cast then
			Remotes.AbandonCast:FireServer(cast.id)
			endCast()
		end
	end)

	-- Putting the rod away mid-cast cancels it. The server cancels the cast
	-- itself on the same loadout change (no fish, no materials - user
	-- decision, 2026-08-22); this just clears the bar and line right away
	-- instead of waiting for the cancelled CastResolved.
	player:GetAttributeChangedSignal(Equipment.ATTRIBUTE):Connect(function()
		if player:GetAttribute(Equipment.ATTRIBUTE) ~= Equipment.ROD and (cast or pendingCast) then
			endCast()
		end
	end)
end

return FishingController
