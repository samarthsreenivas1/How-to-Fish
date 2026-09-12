--!nonstrict
-- CutsceneKit.luau
-- The runtime every boss intro cinematic is written against. A per-boss
-- script under src/Client/Cutscenes/ is a single `return function(kit) ... end`
-- that REGISTERS things - actors, tracks, shots, timed events - and then never
-- runs again; BossCutsceneController steps the kit each RenderStepped and the
-- kit does the drawing. That split is the whole point: a script that only
-- declares "at t=6 the head breaches at bearing 40" can be fast-forwarded past
-- (the skip), joined halfway (a late party member), and torn down mid-beat
-- without every script having to spell out how.
--
-- WHY A STAND-IN AND NOT THE REAL BOSS. The real rig only exists once
-- CreatureService has spawned it, and the server deliberately holds that back
-- until `duration - riseTime` so the genuine rise is the cinematic's last beat
-- (BossService, BossCutscenes.luau's header). Everything before that is drawn
-- by a client-only Model under Workspace.Creatures carrying the same `Pose` /
-- `PoseCenter` attributes the server writes - which the body controllers adopt
-- without knowing or caring that nobody replicated it. `kit.actor` builds that
-- model in exactly the order BrinejawBodyController's `watch`/`adoptBoss` pair
-- expects (attributes first, parent, `Pose` LAST), and Wrack - who is adopted
-- on `CreatureId` instead, for the reason WrackBodyController's header gives -
-- works through the same call with `creatureId` set and no pose at all.
--
-- TIME IS SERVER TIME. `step` is handed `Workspace:GetServerTimeNow()` and
-- subtracts the run's `startsAt`, so every party member is on the same frame of
-- the same cinematic and a client that joins the run late starts in the middle
-- rather than at the top. Nothing here reads os.clock() for timeline purposes -
-- the body controllers made the same choice for the same reason
-- (BrinejawBodyController.start's note).
--
-- MESHES, NOT SLABS. `kit.part` and its descendants (`kit.beam`, `kit.light`)
-- draw untextured blocks, and a cinematic built only from those is the "Roblox
-- objects" complaint in one sentence. `kit.mesh(pack, name, props)` clones the
-- authored Blender object out of `ReplicatedStorage/Assets/<pack>` instead -
-- repainted from `MeshColors`, Neon by the `Glow` name rule, flagged exactly as
-- `kit.part` flags its own geometry, and degrading to `kit.part` (with one
-- warning per pack/name) when the pack is not imported, so a cutscene is never
-- worse off for asking. `kit.meshTween(part, props, t0, t1, ease?)` is
-- `kit.tweenPart` with one extra key: `Scale`, a multiple of the size the
-- object was imported at. Both are the clone-or-fallback pattern four body
-- controllers already carry privately (BrinejawBodyController.makePiece,
-- WrackBodyController's and GnashrootBodyController's namesakes,
-- CreatureEventController.K.fxMarker), hoisted so a cutscene can use it too.
--
-- BEARINGS. `kit.polar` uses the Roblox convention - bearing 0 is +X, rising
-- toward +Z, i.e. Vector3.new(cos, 0, sin). The arena generators author in
-- Blender, where +Y exports as -Z (BossArenas' `sockets` note,
-- Shared/Modules/NoctyssPath), so an authored degree from an arena_gen.py
-- HANDOFF line goes through `kit.authored(deg)` = -math.rad(deg) and never
-- through math.rad directly.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BossArenas = require(Shared.Config.BossArenas)
-- The per-object repaint for every imported pack. Generated from the builders
-- themselves, so a piece added by a re-export cannot be quietly left grey.
local MeshColors = require(Shared.Config.MeshColors)
local World = require(Shared.Config.World)

local Sfx = require(script.Parent.Sfx)
local Vfx = require(script.Parent.Vfx)
local Theme = require(script.Parent.Parent.UI.Theme)
local CombatVfxController = require(script.Parent.Parent.Controllers.CombatVfxController)

local CutsceneKit = {}

-- The kit's own ScreenGui. Named so BossCutsceneController can skip it when it
-- hides the HUD - hiding the cinematic's own title card would be a funny bug to
-- chase - and exported rather than typed twice.
CutsceneKit.GUI_NAME = "BossCutsceneKitGui"

-- Where `kit.part` hangs its throwaway geometry. One folder per run, destroyed
-- whole at `finish`, so a cancelled cutscene cannot leave a neon slab in the
-- sea. Mirrors Vfx.luau's `ClientVfx` container idea.
local FX_FOLDER = "BossCutsceneFx"

local CREATURES_FOLDER = "Creatures"
local ARENA_FOLDER = "BossArenas"
local WORLD_FOLDER = "World"

-- The floor probe, mirroring BossArenaService.floorY: start well above the
-- waterline and cast far enough down to catch a summit arena's rim path AND a
-- sea-level one, filtered to arena/world geometry so the ocean slabs, boats and
-- players cannot answer.
local PROBE_TOP = 500
local PROBE_DEPTH = 1200

-- One warning per missing pack piece, for the whole session rather than per
-- run: a cutscene asking for the same absent object 30 times a second (a
-- `during` that spawns debris) would otherwise bury the output channel, and
-- the four body controllers guard the same warning with the same kind of flag.
local warnedMeshes: { [string]: boolean } = {}

-- What a missing import degrades to: the 4-stud cube `kit.part` would have
-- drawn anyway, before any `Scale`.
local FALLBACK_MESH_SIZE = Vector3.new(4, 4, 4)

-- A pack's object prefix. Every pack in this game names its Blender objects
-- `<prefix>_<piece>` where the prefix is the pack folder's name with a
-- trailing "Pack" removed: BrinejawPack -> `Brinejaw_Head`, BrinejawFxPack ->
-- `BrinejawFx_Foam`, WrackPack -> `Wrack_Hull`, GnashrootPack ->
-- `Gnashroot_Core`. An arena group has no "Pack" to strip and is therefore its
-- own prefix (`RimefangArena` -> `RimefangArena_ThinIce`) - the same rule, not
-- a special case, which is why it is written as a strip rather than a table.
local function packPrefix(pack: string): string
	return (string.gsub(pack, "Pack$", "")) .. "_"
end

-- A sustained rumble is re-kicked this often. CombatVfxController.kick decays
-- over its own duration, so anything longer than a beat has to be re-struck;
-- 0.25 s is short enough that the decay never reaches zero between hits.
local RUMBLE_INTERVAL = 0.25

-- ============================================================ small helpers

local function easeU(u: number, ease: any): number
	if type(ease) == "number" then
		return u ^ ease
	elseif ease == "in" then
		return u * u
	elseif ease == "out" then
		return 1 - (1 - u) * (1 - u)
	elseif ease == "inout" then
		return u * u * (3 - 2 * u)
	elseif ease == "back" then
		-- Overshoot and settle: the standard back-out constant.
		local c = 1.70158
		local p = u - 1
		return 1 + (c + 1) * p * p * p + c * p * p
	elseif ease == "elastic" then
		if u <= 0 or u >= 1 then
			return u
		end
		return 2 ^ (-9 * u) * math.sin((u * 10 - 0.75) * (2 * math.pi / 3)) + 1
	end
	return u
end

-- Lerp anything the tracks are allowed to carry. Typed by `from`, so a track
-- whose ends disagree simply snaps rather than erroring mid-cinematic.
local function lerpValue(from: any, to: any, u: number): any
	local kind = typeof(from)
	if kind == "number" and typeof(to) == "number" then
		return from + (to - from) * u
	elseif kind == "Vector3" and typeof(to) == "Vector3" then
		return from:Lerp(to, u)
	elseif kind == "CFrame" and typeof(to) == "CFrame" then
		return from:Lerp(to, u)
	elseif kind == "Color3" and typeof(to) == "Color3" then
		return from:Lerp(to, u)
	end
	return if u >= 1 then to else from
end

-- A point/look pair that may be a constant or a function of the shot's own u.
local function resolvePoint(value: any, u: number, t: number): Vector3?
	if typeof(value) == "Vector3" then
		return value
	elseif type(value) == "function" then
		return value(u, t)
	end
	return nil
end

-- ============================================================ construction

-- `run` is what BossCutsceneController assembled from the BossIntro payload:
-- { bossId, boss, islandId, center, duration, riseTime, startsAt }.
function CutsceneKit.new(run)
	local kit: any = {}

	-- ---------------------------------------------------------- read-only
	kit.bossId = run.bossId
	kit.boss = run.boss
	kit.islandId = run.islandId
	kit.center = run.center
	kit.waterY = World.WATER_Y
	kit.duration = run.duration
	kit.riseTime = run.riseTime
	-- Where the REAL rise starts. The server schedules it at
	-- `duration - riseTime`; a "raise" payload re-anchors it to when the raise
	-- actually happened (`setRaiseAt`), and a skip pulls it forward.
	kit.raiseAt = math.max(0, run.duration - run.riseTime)
	kit.player = Players.LocalPlayer
	kit.camera = Workspace.CurrentCamera
	kit.t = 0
	-- FEEL IS MUTED WHILE A SKIP CATCHES UP. `fastForward` fires every
	-- one-shot it jumps across so a script's destroy()/set()/actor() calls
	-- land - and, unguarded, so did eight lightning flashes, eight shakes and
	-- eight thunderclaps in one frame (the Kraken's limb reveals). Sound, shake,
	-- flash and the decorative Vfx are therefore no-ops while `muted`; parts,
	-- attributes, lights and cards still go through, because those are STATE
	-- the rest of the run depends on. `kit.vfx` is a proxy over Vfx for the
	-- same reason - scripts call it directly.
	local muted = false
	kit.vfx = setmetatable({}, {
		__index = function(_, key)
			local fn = Vfx[key]
			if type(fn) ~= "function" then
				return fn
			end
			return function(...)
				if muted then
					return nil
				end
				return fn(...)
			end
		end,
	})

	-- ---------------------------------------------------------- internals
	local tracks: { any } = {} -- { t0, t1, ease, apply(u), settled }
	local shots: { any } = {}
	local events: { any } = {} -- one-shots
	local durings: { any } = {}
	local everys: { any } = {}
	local actors: { any } = {}
	local loops: { any } = {}
	local guiConns: { RBXScriptConnection } = {}
	local bossConns: { RBXScriptConnection } = {}
	local bossHandlers: { any } = {}

	local fxFolder: Folder? = nil
	local gui: ScreenGui? = nil
	local fadeFrame: Frame? = nil
	local flashFrame: Frame? = nil
	local cardFrame: Frame? = nil
	local cardTitle: TextLabel? = nil
	local cardSub: TextLabel? = nil

	-- Fade/flash/card are driven off `kit.t` like everything else (so the skip
	-- fast-forwards them too) rather than off TweenService.
	local fadeState = { from = 0, to = 0, t0 = 0, t1 = 0 }
	local flashState = { color = Color3.new(1, 1, 1), peak = 0, fade = 0, at = -1 }
	local cardState = { at = -1, fadeIn = 0.45, hold = 0, fadeOut = 0.6 }

	-- The timeline offset a skip introduces: `step` is always handed real server
	-- time, so jumping forward is an offset added to it rather than a write to
	-- `kit.t` that the next frame would undo.
	local offset = 0
	local finished = false
	local originalFov: number? = nil
	local lastFrame: CFrame? = nil
	local blendFrom: CFrame? = nil
	local activeShot: any = nil

	-- ============================================================ containers

	local function container(): Folder
		if not fxFolder or not fxFolder.Parent then
			local f = Instance.new("Folder")
			f.Name = FX_FOLDER
			f.Parent = Workspace
			fxFolder = f
		end
		return fxFolder :: Folder
	end

	local function screen(): ScreenGui
		if gui and gui.Parent then
			return gui :: ScreenGui
		end
		local g = Instance.new("ScreenGui")
		g.Name = CutsceneKit.GUI_NAME
		g.ResetOnSpawn = false
		g.IgnoreGuiInset = true
		g.DisplayOrder = 90 -- under the controller's letterbox (100), over the HUD
		g.Parent = kit.player:WaitForChild("PlayerGui")

		local fade = Instance.new("Frame")
		fade.Name = "Fade"
		fade.Size = UDim2.fromScale(1, 1)
		fade.BackgroundColor3 = Color3.new(0, 0, 0)
		fade.BackgroundTransparency = 1
		fade.BorderSizePixel = 0
		fade.ZIndex = 1
		fade.Parent = g
		fadeFrame = fade

		local flash = fade:Clone()
		flash.Name = "Flash"
		flash.ZIndex = 2
		flash.Parent = g
		flashFrame = flash

		local card = Instance.new("Frame")
		card.Name = "Card"
		card.AnchorPoint = Vector2.new(0.5, 0.5)
		card.Position = UDim2.fromScale(0.5, 0.5)
		card.Size = UDim2.fromScale(0.9, 0.3)
		card.BackgroundTransparency = 1
		card.Visible = false
		card.ZIndex = 3
		card.Parent = g
		cardFrame = card

		local title = Instance.new("TextLabel")
		title.Name = "Title"
		title.Size = UDim2.fromScale(1, 0.6)
		title.BackgroundTransparency = 1
		title.Font = Theme.Font.header
		title.TextScaled = true
		title.TextColor3 = Theme.Color.text
		title.TextStrokeColor3 = Theme.Color.ink
		title.TextStrokeTransparency = 0
		title.Text = ""
		title.ZIndex = 3
		title.Parent = card
		cardTitle = title

		local sub = Instance.new("TextLabel")
		sub.Name = "Subtitle"
		sub.Position = UDim2.fromScale(0, 0.62)
		sub.Size = UDim2.fromScale(1, 0.2)
		sub.BackgroundTransparency = 1
		sub.Font = Theme.Font.body
		sub.TextScaled = true
		sub.TextColor3 = Theme.Color.sand
		sub.TextStrokeColor3 = Theme.Color.ink
		sub.TextStrokeTransparency = 0.2
		sub.Text = ""
		sub.ZIndex = 3
		sub.Parent = card
		cardSub = sub

		gui = g
		return g
	end

	-- ============================================================ geometry

	-- Arena-local polar to world. See the BEARINGS note in the header.
	function kit.polar(radius: number, bearing: number, y: number?): Vector3
		return Vector3.new(
			kit.center.X + math.cos(bearing) * radius,
			y or kit.waterY,
			kit.center.Z + math.sin(bearing) * radius
		)
	end

	-- An arena_gen.py "authored" bearing (Blender degrees) in this file's
	-- convention. Blender +Y exports as Roblox -Z, so the handedness flips and
	-- the sign with it.
	function kit.authored(deg: number): number
		return -math.rad(deg)
	end

	-- The floor at an arena-local polar point, or the waterline when nothing is
	-- under it. The probe filter mirrors BossArenaService.floorY (arena geometry
	-- only) plus Workspace.World, because a fight-in-place island has no arena
	-- folder at all and its ground is the island's.
	function kit.floorY(radius: number, bearing: number?): number
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		local include = {}
		local arena = Workspace:FindFirstChild(ARENA_FOLDER)
		if arena then
			table.insert(include, arena)
		end
		local world = Workspace:FindFirstChild(WORLD_FOLDER)
		if world then
			table.insert(include, world)
		end
		if #include == 0 then
			return kit.waterY
		end
		params.FilterDescendantsInstances = include
		local from = kit.polar(radius, bearing or 0, kit.waterY + PROBE_TOP)
		local hit = Workspace:Raycast(from, Vector3.new(0, -PROBE_DEPTH, 0), params)
		return if hit then hit.Position.Y else kit.waterY
	end

	-- An authored arena object by name: `<model>_<name>` first (the import
	-- convention BossArenaService.placeAuthored preserves), then the bare name.
	-- Returns the bbox centre and size of a BasePart or a Model.
	function kit.landmark(name: string): (Vector3?, Vector3?)
		local folder = Workspace:FindFirstChild(ARENA_FOLDER)
		if not folder then
			return nil, nil
		end
		local arena = BossArenas.items[kit.islandId]
		local full = if arena and arena.model then arena.model .. "_" .. name else nil
		-- EVERY match, unioned - not the first. The procedural stand-in arena
		-- builds the Tidebreak Spire as twelve cylinder slices all named
		-- `BrinejawArena_Spire` (BossArenaService.buildSpire), and a
		-- FindFirstChild answered with one arbitrary 4-stud slice whose bbox was
		-- not the tower (the Brinejaw author hit it). The authored mesh is one
		-- part, for which the union is just that part.
		local minV: Vector3? = nil
		local maxV: Vector3? = nil
		local function take(position: Vector3, size: Vector3)
			local lo = position - size * 0.5
			local hi = position + size * 0.5
			minV = if minV
				then Vector3.new(math.min(minV.X, lo.X), math.min(minV.Y, lo.Y), math.min(minV.Z, lo.Z))
				else lo
			maxV = if maxV
				then Vector3.new(math.max(maxV.X, hi.X), math.max(maxV.Y, hi.Y), math.max(maxV.Z, hi.Z))
				else hi
		end
		local function scan(wanted: string)
			for _, inst in folder:GetDescendants() do
				if inst.Name == wanted then
					if inst:IsA("BasePart") then
						take(inst.Position, inst.Size)
					elseif inst:IsA("Model") then
						local cf, size = inst:GetBoundingBox()
						take(cf.Position, size)
					end
				end
			end
		end
		if full then
			scan(full)
		end
		if not minV then
			scan(name)
		end
		if not minV or not maxV then
			return nil, nil
		end
		return (minV + maxV) * 0.5, maxV - minV
	end

	-- ============================================================ tracks

	-- Every animated value in a cutscene is one of these: a window and a
	-- function of the eased fraction through it. Later registrations are applied
	-- later in the frame, which IS the "later track wins while active" rule -
	-- and a window that has passed is applied once at u = 1 and then left alone,
	-- so the last value written stays (and a fast-forward lands on it).
	local function addTrack(t0: number, t1: number, ease: any, apply: (number) -> ())
		table.insert(tracks, { t0 = t0, t1 = math.max(t1, t0 + 1e-4), ease = ease, apply = apply, settled = false })
	end
	kit.track = addTrack

	-- ============================================================ actors

	-- A client-only stand-in the body controllers adopt. See the header for the
	-- order these attributes are written in and why it is not negotiable.
	function kit.actor(spec)
		spec = spec or {}
		local center = spec.center or kit.center
		local model = Instance.new("Model")
		model.Name = spec.name or ("Cutscene_" .. tostring(spec.pose or spec.creatureId or kit.bossId))

		local root = Instance.new("Part")
		root.Name = "Root"
		root.Size = Vector3.one
		root.Anchored = true
		root.CanCollide = false
		root.CanQuery = false
		root.CanTouch = false
		root.CastShadow = false
		root.Transparency = 1
		root.CFrame = CFrame.new(center)
		root.Parent = model
		model.PrimaryPart = root

		-- PoseCenter BEFORE Pose: adoptBoss reads the centre in the same breath
		-- it adopts (BrinejawPath.newState is handed it), so a centre that lands
		-- a frame later builds the body around the wrong origin.
		model:SetAttribute("PoseCenter", center)
		if spec.creatureId then
			model:SetAttribute("CreatureId", spec.creatureId)
		end
		for attr, value in spec.attrs or {} do
			model:SetAttribute(attr, value)
		end

		local folder = Workspace:FindFirstChild(CREATURES_FOLDER) or Workspace:WaitForChild(CREATURES_FOLDER, 5)
		model.Parent = folder or Workspace
		-- ...and Pose LAST, after the model is in the tree: `watch` connects the
		-- Pose-changed signal on ChildAdded and `adoptBoss` bails when Pose is
		-- absent, so this write is the adopt.
		if spec.pose then
			model:SetAttribute("Pose", spec.pose)
		end

		local actor: any = { model = model, root = root }

		function actor.set(_self, attr: string, value: any)
			model:SetAttribute(attr, value)
		end
		function actor.get(_self, attr: string): any
			return model:GetAttribute(attr)
		end
		function actor.tween(_self, attr: string, from: any, to: any, t0: number, t1: number, ease: any?)
			-- `from` is stamped only onto an attribute nothing has set yet. The
			-- first draft stamped it unconditionally, which made the LAST tween
			-- registered on an attribute decide its opening value - a script
			-- that tweened Gape 0.2 -> 0.9 at t 8 and 0.9 -> 0 at t 11 opened on
			-- 0.9 (the Rimefang author found it and re-stamped after every call).
			-- An explicit `attrs` entry or `actor:set` now always wins.
			if model:GetAttribute(attr) == nil then
				model:SetAttribute(attr, from)
			end
			addTrack(t0, t1, ease, function(u)
				model:SetAttribute(attr, lerpValue(from, to, u))
			end)
		end
		function actor.pivot(_self, cf: CFrame)
			if model.Parent then
				model:PivotTo(cf)
			end
		end
		function actor.destroy(_self)
			if model.Parent then
				model:Destroy()
			end
		end

		table.insert(actors, actor)
		return actor
	end

	-- The real rig has landed when a Model under Workspace.Creatures carries the
	-- boss's title - CreatureService's ATTR.BOSS_NAME, "set when it rises", the
	-- same attribute BossHudController finds its bar off. This is where a script
	-- destroys its stand-in so the two are never on screen together.
	function kit.onRealBoss(fn)
		table.insert(bossHandlers, fn)
	end

	local function offerBoss(model: Instance)
		if not model:IsA("Model") or model:GetAttribute("BossName") ~= (kit.boss and kit.boss.name) then
			return
		end
		for _, fn in bossHandlers do
			task.spawn(fn, model)
		end
	end

	local function watchForRealBoss()
		local folder = Workspace:FindFirstChild(CREATURES_FOLDER)
		if not folder then
			return
		end
		local function watch(child: Instance)
			offerBoss(child)
			if child:IsA("Model") then
				table.insert(
					bossConns,
					child:GetAttributeChangedSignal("BossName"):Connect(function()
						offerBoss(child)
					end)
				)
			end
		end
		for _, child in folder:GetChildren() do
			watch(child)
		end
		table.insert(bossConns, folder.ChildAdded:Connect(watch))
	end

	-- ============================================================ events

	function kit.at(t: number, fn)
		table.insert(events, { t = t, fn = fn, fired = false })
	end
	function kit.during(t0: number, t1: number, fn)
		table.insert(durings, { t0 = t0, t1 = t1, fn = fn })
	end
	function kit.every(t0: number, t1: number, interval: number, fn)
		table.insert(everys, { t0 = t0, t1 = t1, interval = math.max(interval, 1 / 60), fn = fn, next = 0 })
	end

	-- ============================================================ feel

	-- Routed through CombatVfxController rather than written as a camera offset
	-- here, for the reason its own header gives: one restore/apply bracket
	-- around the camera scripts, so shakes can never stack or leak into the look.
	function kit.shake(angle: number, duration: number, pitch: number?)
		if muted then
			return
		end
		CombatVfxController.kick(angle, pitch or angle * 0.5, duration)
	end

	function kit.rumble(t0: number, t1: number, angle: number)
		kit.every(t0, t1, RUMBLE_INTERVAL, function()
			kit.shake(angle, RUMBLE_INTERVAL * 1.6, angle * 0.35)
		end)
	end

	-- Sfx.play warns once on an unknown name and returns, so a script naming a
	-- sound that does not exist loses a cue rather than the cinematic.
	function kit.sfx(name: string, position: Vector3?)
		if muted then
			return
		end
		Sfx.play(name, position)
	end
	function kit.loop(name: string, position: Vector3?): BasePart?
		local handle = Sfx.loop(name, position or kit.center)
		if handle then
			table.insert(loops, handle)
		end
		return handle
	end
	function kit.stopLoop(handle: BasePart?)
		if not handle then
			return
		end
		local index = table.find(loops, handle)
		if index then
			table.remove(loops, index)
		end
		Sfx.stopLoop(handle)
	end

	-- ============================================================ screen

	-- The cinematic's own title card. The letterbox bars belong to the
	-- controller and stay put underneath; this is only the lettering.
	function kit.card(title: string, subtitle: string?, hold: number?)
		screen()
		if cardTitle then
			cardTitle.Text = string.upper(title)
		end
		if cardSub then
			cardSub.Text = subtitle or ""
		end
		cardState.at = kit.t
		cardState.hold = hold or 2.2
		if cardFrame then
			cardFrame.Visible = true
		end
	end

	function kit.fade(alpha: number, seconds: number?)
		screen()
		local current = if fadeFrame then 1 - fadeFrame.BackgroundTransparency else 0
		fadeState.from = current
		fadeState.to = math.clamp(alpha, 0, 1)
		fadeState.t0 = kit.t
		fadeState.t1 = kit.t + math.max(seconds or 0, 1e-3)
	end

	function kit.flash(color: Color3?, peak: number?, fade: number?)
		if muted then
			return
		end
		screen()
		flashState.color = color or Color3.new(1, 1, 1)
		flashState.peak = math.clamp(peak or 0.85, 0, 1)
		flashState.fade = math.max(fade or 0.35, 1e-3)
		flashState.at = kit.t
	end

	-- ============================================================ parts

	-- Anchored, non-collidable, NON-QUERYABLE: everything a fight draws is
	-- CanQuery = false so it can never pull the third-person camera in
	-- (CameraController's occlusion note), and a cinematic prop is no different.
	function kit.part(props): BasePart
		local part = Instance.new("Part")
		part.Name = "CutscenePart"
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Material = Enum.Material.SmoothPlastic
		part.Size = Vector3.one
		for key, value in props or {} do
			part[key] = value
		end
		part.Parent = container()
		return part
	end

	-- Lerp any set of a part's numeric/Vector3/CFrame/Color3 properties between
	-- two times. `from` is read AT REGISTRATION, not at t0 - scripts build their
	-- props in order, and a value sampled at t0 would be whatever some later
	-- track had already written.
	function kit.tweenPart(part: BasePart, props, t0: number, t1: number, ease: any?)
		-- `from` is sampled on the window's FIRST frame, not at registration:
		-- a second tween chained after a first would otherwise lerp back from
		-- where the part was when the script ran, not where the first tween
		-- left it. (A fast-forward that lands past the window samples and
		-- settles in the same call, which is still the right answer.)
		local from = nil
		addTrack(t0, t1, ease, function(u)
			if not part.Parent then
				return
			end
			if not from then
				from = {}
				for key in props do
					from[key] = part[key]
				end
			end
			for key, target in props do
				part[key] = lerpValue(from[key], target, u)
			end
		end)
	end

	-- ============================================================ meshes

	-- The authored object behind (pack, name): `Assets/<pack>` (a Folder or a
	-- Model) searched for a descendant named `<prefix>_<name>` first and the
	-- bare `name` second. Prefixed first because that is what every import
	-- actually carries and a bare-named sibling would be the accident;
	-- `kit.landmark` resolves an arena object in the same order for the same
	-- reason.
	local function packObject(pack: string, name: string): Instance?
		local assets = ReplicatedStorage:FindFirstChild("Assets")
		local folder = assets and assets:FindFirstChild(pack)
		if not folder then
			return nil
		end
		return folder:FindFirstChild(packPrefix(pack) .. name, true) or folder:FindFirstChild(name, true)
	end

	-- A cinematic prop drawn with the imported mesh when it is there, and with
	-- exactly today's block when it is not. Props are `kit.part`'s - CFrame,
	-- Color, Transparency, Material, Size - plus `Scale`, a uniform multiple of
	-- the size the object was imported at (stamped as `BaseSize` before any
	-- scaling, the way the body controllers' `applyPiece` stamps it, so
	-- `kit.meshTween` and a later re-scale both measure from the import rather
	-- than from whatever the last frame left).
	function kit.mesh(pack: string, name: string, props): BasePart
		props = props or {}
		local scale = props.Scale
		local object = packObject(pack, name)
		local source: BasePart? = nil
		if object then
			if object:IsA("BasePart") then
				source = object
			elseif object:IsA("Model") then
				source = object:FindFirstChildWhichIsA("BasePart", true)
			end
		end

		-- Nothing imported: hand the caller the slab the cinematic drew before
		-- the pack existed. `Scale` still applies, and `BaseSize` is still
		-- stamped, so a script written against the mesh animates identically on
		-- a machine that never got the import.
		if not source then
			local key = pack .. "/" .. name
			if not warnedMeshes[key] then
				warnedMeshes[key] = true
				warn("[CutsceneKit] " .. key .. " not imported - drawing a stand-in")
			end
			local fallback = {}
			for prop, value in props do
				if prop ~= "Scale" and prop ~= "Size" then
					fallback[prop] = value
				end
			end
			local base = if typeof(props.Size) == "Vector3" then props.Size else FALLBACK_MESH_SIZE
			fallback.Size = base * (scale or 1)
			local stand = kit.part(fallback)
			stand:SetAttribute("BaseSize", base)
			return stand
		end

		local part = (source :: BasePart):Clone()
		local objectName = part.Name
		-- REPAINT THE IMPORT, and drop any PBR surface with it. Studio's glTF
		-- importer carries no colour across - every cloned pack part arrives at
		-- Roblox's default grey - so without this, importing the real mesh would
		-- make a cutscene look WORSE than the slab it replaced. Keyed on the
		-- object's own Blender name, which is what `MeshColors` rows are (its
		-- header says so); the Model branch above may have reached a child, so
		-- the child's name is tried before the matched group's.
		local appearance = part:FindFirstChildWhichIsA("SurfaceAppearance")
		if appearance then
			appearance:Destroy()
		end
		local color = MeshColors.get(objectName) or (if object then MeshColors.get(object.Name) else nil)
		if color then
			part.Color = color
		end
		-- BY NAME, not by a list of names - BossArenaService's rule for arena
		-- meshes and the body controllers' for boss packs, so both halves of an
		-- import obey the one convention.
		if string.find(objectName, "Glow", 1, true) or string.find(name, "Glow", 1, true) then
			part.Material = Enum.Material.Neon
		end
		-- ...and the same flags `kit.part` asserts, non-queryable included: a
		-- cinematic prop must never pull the third-person camera in.
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false

		if typeof(props.Size) == "Vector3" then
			part.Size = props.Size
		end
		local base = part.Size
		part:SetAttribute("BaseSize", base)
		for prop, value in props do
			if prop ~= "Scale" and prop ~= "Size" then
				part[prop] = value
			end
		end
		if scale then
			part.Size = base * scale
		end
		part.Parent = container()
		return part
	end

	-- `kit.tweenPart` for a `kit.mesh` part: identical, except that `Scale` is
	-- read against the stamped `BaseSize`. It is a TRANSLATION rather than a
	-- second tween loop - `Size = BaseSize * Scale` is linear in Scale, so
	-- lerping the size between two multiples of the same base IS lerping the
	-- multiple - which means the lazy `from` sampling below is literally
	-- tweenPart's, including its "sampled on the window's first frame, not at
	-- registration" rule that lets one mesh tween chain after another.
	function kit.meshTween(part: BasePart, props, t0: number, t1: number, ease: any?)
		props = props or {}
		local scale = props.Scale
		if not scale then
			kit.tweenPart(part, props, t0, t1, ease)
			return
		end
		local base = part:GetAttribute("BaseSize")
		if typeof(base) ~= "Vector3" then
			-- A part that never came through `kit.mesh` (or a `kit.part` slab a
			-- script wants to scale): its size NOW is its base, stamped once so
			-- a second call agrees with the first.
			base = part.Size
			part:SetAttribute("BaseSize", base)
		end
		local translated = {}
		for prop, value in props do
			if prop ~= "Scale" then
				translated[prop] = value
			end
		end
		translated.Size = (base :: Vector3) * scale
		kit.tweenPart(part, translated, t0, t1, ease)
	end

	-- A straight neon bar between two points (a lantern's beam, a lightning
	-- line). A part, because everything else here is - a real Beam needs two
	-- attachments and a texture, and nothing in this game's flat-shaded look
	-- wants one.
	function kit.beam(from: Vector3, to: Vector3, thickness: number?, color: Color3?): BasePart
		local delta = to - from
		return kit.part({
			Size = Vector3.new(thickness or 0.6, thickness or 0.6, math.max(delta.Magnitude, 0.05)),
			CFrame = CFrame.lookAt(from + delta * 0.5, to),
			Color = color or Theme.Color.foam,
			Material = Enum.Material.Neon,
		})
	end

	function kit.light(position: Vector3, color: Color3, range: number, brightness: number): PointLight
		local host = kit.part({ Size = Vector3.new(0.2, 0.2, 0.2), CFrame = CFrame.new(position), Transparency = 1 })
		local light = Instance.new("PointLight")
		light.Color = color
		light.Range = range
		light.Brightness = brightness
		light.Parent = host
		return light
	end

	-- ============================================================ camera

	function kit.shot(spec)
		spec.t0 = spec.t0 or 0
		spec.t1 = spec.t1 or kit.duration
		table.insert(shots, spec)
		table.sort(shots, function(a, b)
			return a.t0 < b.t0
		end)
	end

	function kit.orbit(center: Vector3, radius: number, height: number, fromBearing: number, toBearing: number)
		return function(u: number): Vector3
			local bearing = fromBearing + (toBearing - fromBearing) * u
			return Vector3.new(
				center.X + math.cos(bearing) * radius,
				center.Y + height,
				center.Z + math.sin(bearing) * radius
			)
		end
	end

	function kit.line(a: Vector3, b: Vector3)
		return function(u: number): Vector3
			return a:Lerp(b, u)
		end
	end

	function kit.arc(a: Vector3, b: Vector3, apex: number)
		return function(u: number): Vector3
			return Vfx.arcPoint(a, b, apex, u)
		end
	end

	local function shotFrame(shot, t: number): CFrame?
		local span = math.max(shot.t1 - shot.t0, 1e-4)
		local u = math.clamp((t - shot.t0) / span, 0, 1)
		if shot.cam then
			return shot.cam(u, t)
		end
		local pos = resolvePoint(shot.pos, u, t)
		local look = resolvePoint(shot.look, u, t)
		if not pos then
			return nil
		end
		if not look then
			return CFrame.new(pos)
		end
		if (look - pos).Magnitude < 1e-3 then
			return CFrame.new(pos)
		end
		return CFrame.lookAt(pos, look)
	end

	-- The active shot is the last one that has STARTED. A gap between shots
	-- holds the previous one's final frame (its u is clamped to 1 above), which
	-- is what makes "end your last shot at `duration`" merely a convention
	-- rather than a requirement.
	local function updateCamera(t: number, dt: number): CFrame?
		local current = nil
		for _, shot in shots do
			if t >= shot.t0 then
				current = shot
			end
		end
		if not current then
			return lastFrame
		end
		if current ~= activeShot then
			activeShot = current
			blendFrom = lastFrame
		end
		local frame = shotFrame(current, t)
		if not frame then
			return lastFrame
		end
		local blendIn = current.blendIn or 0
		local blend = 1
		if blendIn > 0 and blendFrom then
			blend = math.clamp((t - current.t0) / blendIn, 0, 1)
			frame = (blendFrom :: CFrame):Lerp(frame, blend)
		end
		if current.fov and kit.camera then
			if originalFov == nil then
				originalFov = kit.camera.FieldOfView
			end
			-- Eased on the same blend as the cut, so a hard cut changes FOV on
			-- the same frame the position jumps and a soft one rides with it.
			local base = if blendIn > 0 then originalFov :: number else current.fov
			kit.camera.FieldOfView = base + (current.fov - base) * blend
		end
		lastFrame = frame
		local _ = dt
		return frame
	end

	-- ============================================================ the step

	-- Fire everything that should have happened by `t`. Shared by the normal
	-- step and by `fastForward`, which is exactly why a skip does not silently
	-- drop the sfx, card and destroy() calls a script hung off `kit.at`.
	local function fireEventsTo(t: number)
		for i = 1, #events do
			local event = events[i]
			if not event.fired and t >= event.t then
				event.fired = true
				local ok, err = pcall(event.fn)
				if not ok then
					warn("[CutsceneKit] at(" .. tostring(event.t) .. ") failed: " .. tostring(err))
				end
			end
		end
	end

	local function stepScreen(t: number)
		if fadeFrame then
			local u = math.clamp((t - fadeState.t0) / math.max(fadeState.t1 - fadeState.t0, 1e-3), 0, 1)
			fadeFrame.BackgroundTransparency = 1 - lerpValue(fadeState.from, fadeState.to, u)
		end
		if flashFrame then
			if flashState.at < 0 then
				flashFrame.BackgroundTransparency = 1
			else
				local u = math.clamp((t - flashState.at) / flashState.fade, 0, 1)
				flashFrame.BackgroundColor3 = flashState.color
				flashFrame.BackgroundTransparency = 1 - flashState.peak * (1 - u)
			end
		end
		if cardFrame and cardState.at >= 0 then
			local since = t - cardState.at
			local total = cardState.fadeIn + cardState.hold + cardState.fadeOut
			-- One envelope: up over fadeIn, flat for hold, down over fadeOut, and
			-- zero outside it (before, because a fast-forward can land the card's
			-- own `at` in the future; after, because the card is spent).
			local alpha = 0
			if since >= 0 and since < cardState.fadeIn then
				alpha = since / cardState.fadeIn
			elseif since >= cardState.fadeIn and since < cardState.fadeIn + cardState.hold then
				alpha = 1
			elseif since >= cardState.fadeIn + cardState.hold and since < total then
				alpha = 1 - (since - cardState.fadeIn - cardState.hold) / cardState.fadeOut
			end
			cardFrame.Visible = alpha > 0.001
			if cardTitle then
				cardTitle.TextTransparency = 1 - alpha
				cardTitle.TextStrokeTransparency = 1 - alpha
			end
			if cardSub then
				cardSub.TextTransparency = 1 - alpha
				cardSub.TextStrokeTransparency = 1 - alpha * 0.8
			end
		end
	end

	-- Advance the whole run to `now` (server time) and return the camera frame
	-- this cutscene wants, or nil when no shot has started yet (the controller
	-- leaves the player's own camera alone until then).
	function kit.step(_self, now: number, dt: number): CFrame?
		if finished then
			return nil
		end
		local t = (now - run.startsAt) + offset
		kit.t = t

		fireEventsTo(t)

		-- Numeric loops over a length snapshot: a callback may register a new
		-- track/during/every mid-step (a `kit.at` that spawns props), and Luau
		-- forbids appending to a table under generalized iteration. Anything
		-- appended this frame is simply picked up next frame.
		for i = 1, #tracks do
			local track = tracks[i]
			if t >= track.t0 then
				if t <= track.t1 then
					local u = (t - track.t0) / (track.t1 - track.t0)
					local ok, err = pcall(track.apply, easeU(math.clamp(u, 0, 1), track.ease))
					if not ok then
						warn("[CutsceneKit] track failed: " .. tostring(err))
					end
				elseif not track.settled then
					track.settled = true
					pcall(track.apply, 1)
				end
			end
		end

		for i = 1, #durings do
			local entry = durings[i]
			if t >= entry.t0 and t <= entry.t1 then
				local u = (t - entry.t0) / math.max(entry.t1 - entry.t0, 1e-4)
				local ok, err = pcall(entry.fn, u, dt, t)
				if not ok then
					warn("[CutsceneKit] during failed: " .. tostring(err))
				end
			end
		end

		for i = 1, #everys do
			local entry = everys[i]
			if t >= entry.t0 and t <= entry.t1 then
				local index = math.floor((t - entry.t0) / entry.interval)
				if index >= entry.next then
					entry.next = index + 1
					pcall(entry.fn, index)
				end
			end
		end

		stepScreen(t)
		return updateCamera(t, dt)
	end

	-- The real raise landed (or was pulled forward by a skip). Scripts read
	-- `kit.raiseAt` when they register, so this is a re-anchor for anything that
	-- asks again per frame - and for the controller's own handoff.
	function kit.setRaiseAt(_self, t: number)
		kit.raiseAt = t
	end

	-- Jump the local timeline to `t`. One-shots between here and there are FIRED
	-- rather than skipped (a script's `at` is where it destroys its stand-in and
	-- stops its loops, and dropping those is how a skip leaves a ghost serpent
	-- in the sea), and repeaters are wound past so a 10-second every() does not
	-- fire forty times on the frame after the skip.
	function kit.fastForward(_self, t: number)
		if finished or t <= kit.t then
			return
		end
		offset += t - kit.t
		kit.t = t
		muted = true
		fireEventsTo(t)
		muted = false
		for _, entry in everys do
			if t > entry.t0 then
				entry.next = math.max(entry.next, math.floor((t - entry.t0) / entry.interval) + 1)
			end
		end
	end

	-- Tear the whole run down: every actor, every part, every loop, every
	-- connection, the gui, and the camera's own FOV. Called on the normal end
	-- AND on every cancel path, so it has to be safe to call twice.
	function kit.finish(_self)
		if finished then
			return
		end
		finished = true
		for _, actor in actors do
			pcall(function()
				actor:destroy()
			end)
		end
		table.clear(actors)
		for _, handle in loops do
			Sfx.stopLoop(handle)
		end
		table.clear(loops)
		for _, conn in bossConns do
			conn:Disconnect()
		end
		for _, conn in guiConns do
			conn:Disconnect()
		end
		table.clear(bossConns)
		table.clear(guiConns)
		if fxFolder then
			fxFolder:Destroy()
			fxFolder = nil
		end
		-- The title card lands at raiseAt + 0.85 * riseTime by convention - the
		-- roar beat - which is inside the last second of every run, and the
		-- run ends when the boss is up. Tearing the gui down there cut the card
		-- off before it reached full opacity (the Gnashroot author measured
		-- 0.57 s). So a card still inside its envelope keeps the gui and plays
		-- out over the live fight on its own clock, and the gui goes when it is
		-- spent. Everything else on the screen is cleared at once.
		if gui then
			local since = kit.t - cardState.at
			local total = cardState.fadeIn + cardState.hold + cardState.fadeOut
			if cardFrame and cardState.at >= 0 and since >= 0 and since < total then
				if fadeFrame then
					fadeFrame.BackgroundTransparency = 1
				end
				if flashFrame then
					flashFrame.BackgroundTransparency = 1
				end
				local lingering = gui
				local base = kit.t
				local started = os.clock()
				-- stepScreen draws through the card upvalues, so those stay
				-- bound until the loop is done; only the fade/flash refs go now.
				fadeFrame, flashFrame = nil, nil
				task.spawn(function()
					while lingering.Parent and (os.clock() - started) < (total - since) + 0.1 do
						stepScreen(base + (os.clock() - started))
						task.wait()
					end
					cardFrame, cardTitle, cardSub = nil, nil, nil
					lingering:Destroy()
				end)
			else
				gui:Destroy()
				fadeFrame, flashFrame, cardFrame, cardTitle, cardSub = nil, nil, nil, nil, nil
			end
			gui = nil
		else
			fadeFrame, flashFrame, cardFrame, cardTitle, cardSub = nil, nil, nil, nil, nil
		end
		if originalFov and kit.camera then
			kit.camera.FieldOfView = originalFov
			originalFov = nil
		end
		table.clear(tracks)
		table.clear(shots)
		table.clear(events)
		table.clear(durings)
		table.clear(everys)
		table.clear(bossHandlers)
	end

	-- The last frame the cutscene drew, for the controller's blend-out.
	function kit.lastCameraFrame(_self): CFrame?
		return lastFrame
	end

	watchForRealBoss()
	return kit
end

return CutsceneKit
