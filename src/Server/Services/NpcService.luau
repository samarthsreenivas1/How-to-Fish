--!nonstrict
-- NpcService.luau
-- The islands' named characters (Npcs.luau): stationary bodies with a
-- nameplate and a ProximityPrompt. Pressing the prompt opens dialog - the
-- prompt's Triggered fires SERVER-side, so the server owns the whole
-- handshake: it pushes the pane over NpcDialog and handles the client's
-- NpcChoice replies, re-validating distance on every one (never trust the
-- pane the client claims to be in).
--
-- Bodies are ORDINARY ROBLOX CHARACTERS now (2026-09-09): a HumanoidDescription
-- filled from the row's `look` (colours + scale, never an asset id - those load
-- only for the uploader's account) through
-- Players:CreateHumanoidModelFromDescription, with a procedural block rig as
-- the fallback so the game boots even when that call fails or yields nothing.
-- The old CreatureModel path is gone: it crashed NpcService.start at boot for
-- every NPC row. Hats and hair are procedural parts welded to the Head.
--
-- The rig is held up by ONE anchored HumanoidRootPart - every other limb stays
-- unanchored so the Motor6D chain (and therefore the idle animation) still
-- moves; the whole assembly is anchored through the root. Every BasePart is
-- CanCollide/CanTouch false (the no-prop-walls rule) and only two are
-- CanQuery: the root and the invisible TalkHitbox, which is what a mouse click
-- actually lands on. Deliberately NOT CreatureService.spawn: that would buy an
-- update loop and targeting exemptions we'd immediately have to fight.
--
-- Talking is either the ProximityPrompt (E) or a ClickDetector on the model -
-- both open the same conversation, both throttled per player.
--
-- CONVERSATIONS ARE NODE TREES NOW (2026-09-12). The old pane machine
-- (greeting/offer/progress/turnin/shop, one flat list of labelled buttons) is
-- gone. A row's `dialogue` field carries { first, again, nodes }: each node is
-- a few lines the NPC says (the client types them out) plus up to three
-- full-sentence replies, each naming the next node - or the terminal "menu"
-- (end the talk, open the business panel) or "end" (a polite exit). The FIRST
-- meeting ever runs `first` on a black screen; every later one runs `again`
-- over a dimmed world. "Ever" is persisted: the "npcs" DataService slice is
-- `{ met = { [npcId] = true } }`.
--
-- The server still owns everything. It tracks the player's CURRENT node per
-- NPC and honours a "node:<id>" reply ONLY if that node's own choices name it
-- (a forged jump to the end of a lore branch is dropped), re-validates
-- distance on every id, and keeps the quarter-second throttle. The menu
-- payload is STRUCTURED (quest cards + shop rows + coins), built from
-- QuestService.offersFor/progressOf and the shop's stockToday, because the
-- client draws it as a panel rather than as a list of sentences. `npc.voice`
-- still supplies every remark and the farewell button's label, and a row with
-- no `dialogue` at all gets a generated two-node talk out of its
-- `greeting`/`hello` lines - so an NPC is never mute.
--
-- CRAFTING LIVES HERE NOW (2026-09-12, user: "move crafting entirely to the
-- npcs"). The `C` window is gone. A row with `crafts = true` gets a THIRD thing
-- in its menu payload - `craft`, a list of sections (Rods / Weapons / Armor /
-- Charms / Boats / Bait) whose item rows carry exactly what the old cards showed
-- (level, coins, each material as have/need, a heart requirement, owned,
-- equipped) plus the server's own verdict: `canCraft`, and a plain `reason` when
-- not. The verdict is CraftingService.check - the same gate, in the same order,
-- that CraftingService.craft then re-runs - so the panel never offers a Craft the
-- server would refuse. "craft:<itemId>" and "equip:<kind>:<itemId>" are choice
-- ids like any other: distance, throttle and the `crafts` flag are all re-checked
-- before either runs, and both answer with a fresh menu.
--
-- POSES. `pose = { kind = "sit"|"stand", seat = ..., seatColor = ... }`. A
-- seated NPC gets a small anchored prop built under it at the same stand point
-- the placement probe verified, sits its hips on the prop's top face and plays
-- the R15 sit clip instead of the idle; it turns at most SEATED_YAW_LIMIT
-- toward a talker, because swinging the root would slide the body off the seat.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Islands = require(Shared.Config.Islands)
local World = require(Shared.Config.World)
local Npcs = require(Shared.Data.Npcs)
local Quests = require(Shared.Data.Quests)
local Shops = require(Shared.Data.Shops)
local Armor = require(Shared.Data.Armor)
local Trinkets = require(Shared.Data.Trinkets)
local Bait = require(Shared.Data.Bait)
local Boats = require(Shared.Data.Boats)
local Bosses = require(Shared.Data.Bosses)
local Rods = require(Shared.Data.Rods)
local Weapons = require(Shared.Data.Weapons)
local Equipment = require(Shared.Config.Equipment)
local Creatures = require(Shared.Data.Creatures)
local Materials = require(Shared.Data.Materials)
local Remotes = require(Shared.Net.Remotes)
local Progression = require(Shared.Modules.Progression)

local QuestService = require(script.Parent.QuestService)
local MaterialService = require(script.Parent.MaterialService)
local BaitService = require(script.Parent.BaitService)
local DataService = require(script.Parent.DataService)
local InventoryService = require(script.Parent.InventoryService)
local BoatService = require(script.Parent.BoatService)
local CraftingService = require(script.Parent.CraftingService)

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

-- Every `look` field is optional (a row may carry no `look` at all); these
-- are the defaults the NPC contract names.
local LOOK_SKIN = Color3.fromRGB(196, 156, 116)
local LOOK_SHIRT = Color3.fromRGB(94, 82, 120)
local LOOK_PANTS = Color3.fromRGB(60, 54, 70)
local LOOK_HAT = Color3.fromRGB(60, 50, 44)

-- The Roblox-owned R15 defaults. Loading these can fail outright in an
-- offline Studio session, so every use is wrapped: an NPC that stands
-- perfectly still is a blemish, an NPC that kills the boot is a bug.
local IDLE_ANIM = "rbxassetid://507766666"
local WAVE_ANIM = "rbxassetid://507770239"

-- Turning to face whoever is talking, and drifting back to `facing` after.
local FACE_TIME = 0.35
local UNFACE_TIME = 1.0

local placed: { [string]: Model } = {}
local homeCFrame: { [string]: CFrame } = {}
local waveTracks: { [string]: AnimationTrack } = {}
local facingTweens: { [string]: Tween } = {}
-- Who each NPC is currently turned toward, so two players in one hut don't
-- fight over the body: the last person to open the dialog wins, and only
-- that person's farewell turns them back.
local facingWho: { [string]: Player } = {}
-- Which NPCs are sitting (poseOf said so at placement): they may not swing
-- their root to face a talker, and they wave at nobody.
local seated: { [string]: boolean } = {}

-- ============================================================ look

local function lookOf(npc)
	local raw = if type(npc.look) == "table" then npc.look else {}
	local shirt = raw.shirt or LOOK_SHIRT
	return {
		skin = raw.skin or LOOK_SKIN,
		shirt = shirt,
		sleeves = raw.sleeves or shirt,
		pants = raw.pants or LOOK_PANTS,
		hair = raw.hair,
		hat = if type(raw.hat) == "string" then raw.hat else "none",
		hatColor = raw.hatColor or LOOK_HAT,
		height = math.clamp(tonumber(raw.height) or 1, 0.85, 1.25),
		width = math.clamp(tonumber(raw.width) or 1, 0.8, 1.3),
	}
end

-- ============================================================ poses

-- Weathered wood: what a seat is when the row names no colour.
local POSE_SEAT_COLOR = Color3.fromRGB(122, 92, 62)

-- How high a seat's TOP FACE sits above the floor. 1.5 studs is a stool under
-- an R15 at default scale (that rig stands with a HipHeight of 2), and the
-- placement below rests the root part's BOTTOM face on that top face - the root
-- is the pelvis, so its underside is where the thighs leave the body. Hips ON
-- the seat, not hovering over it and not sunk through it.
local SEAT_TOP_OVER_FLOOR = 1.5

-- The Roblox-owned R15 sit clip, played looped INSTEAD of the idle. Like every
-- other animation here it is pcall'd: a clip Studio cannot reach must cost a
-- stiff villager, never the island.
local SIT_ANIM = "rbxassetid://2506281703"

-- How far a seated body may turn toward whoever is talking to it.
local SEATED_YAW_LIMIT = math.rad(35)

local SEAT_KINDS = { stool = true, crate = true, bench = true, log = true, none = true }

-- The row's `pose`, defaulted: no pose at all means standing, which is what
-- every NPC did before this field existed.
local function poseOf(npc)
	local raw = if type(npc.pose) == "table" then npc.pose else {}
	local kind = if raw.kind == "sit" then "sit" else "stand"
	local seat = if type(raw.seat) == "string" and SEAT_KINDS[raw.seat] then raw.seat else "stool"
	return {
		kind = kind,
		seat = if kind == "sit" then seat else "none",
		seatColor = if typeof(raw.seatColor) == "Color3" then raw.seatColor else POSE_SEAT_COLOR,
	}
end

-- ============================================================ body

-- Substrings of a part NAME that mean "this is not a floor, whatever the ray
-- says". Two kinds live here. Fluids (Water/Foam/Lava/Bay/Lagoon/Pool) are
-- surfaces you fall INTO, and WorldService.NON_COLLIDE already makes most of
-- them pass-through - the names are repeated here so a new island's water
-- sheet cannot become an NPC's floor by being forgotten in that list. Roof,
-- Canvas and Glow are the opposite case: a hut roof and an awning stay SOLID
-- at runtime (WorldService deliberately keeps `_Hut_Roof`/`_Hut_Walls`
-- collidable so players can't walk through a house), so nothing but the name
-- distinguishes the roof from the porch floor underneath it.
local NOT_FLOOR = {
	"Water",
	"Foam",
	"Lava",
	"Bay", -- Wreckwater_Bay, the harbour sheet (a fishable surface per World.FISHABLE_NAMES)
	"Lagoon", -- Boilshoal_Lagoon, likewise fishable
	"Pool", -- Bellbuoy_Pools, Frostmaw/Gloom tide pools
	"Roof",
	"Canvas",
	"Glow",
}

-- How much clear air a candidate floor needs above it before an NPC can stand
-- there, and how far above the waterline the floor itself must be. The sea is
-- a solid collidable slab whose top face is World.WATER_Y (see WorldService's
-- verifyWaterline), so a "floor" at or below it is the ocean or geometry
-- drowned under it.
local FLOOR_HEADROOM = 5
local FLOOR_MIN_Y = World.WATER_Y + 0.3
local PROBE_BOTTOM = -200
local PROBE_MAX_HITS = 24

local function isFloorName(name: string): boolean
	for _, bad in NOT_FLOOR do
		if string.find(name, bad, 1, true) then
			return false
		end
	end
	return true
end

-- Every hit in the column under (x, z), top-down, as { y, name, solid, floor }.
-- The
-- idiom is re-cast-from-just-below-the-last-hit rather than a growing Exclude
-- list, because the Include filter on `World` has to stay (it is what keeps
-- boats, creatures and the NPCs themselves out of the answer) and RaycastParams
-- cannot hold both. Only UPWARD-facing faces are collected: dropping through a
-- landform also punches out through its underside, and that back face is a
-- ceiling, not a floor.
local function columnHits(x: number, z: number, fromY: number?)
	-- The folder WorldService.init creates, by its shared name - never the
	-- literal, so a rename cannot silently empty every island out of the probe
	-- and leave fourteen NPCs quietly unplaced.
	local world = Workspace:FindFirstChild(World.FOLDER_NAME)
	if not world then
		return nil
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { world }
	local hits = {}
	local y = fromY or 120
	for _ = 1, PROBE_MAX_HITS do
		if y <= PROBE_BOTTOM then
			break
		end
		local hit = Workspace:Raycast(Vector3.new(x, y, z), Vector3.new(0, -(y - PROBE_BOTTOM), 0), params)
		if not hit then
			break
		end
		local part = hit.Instance
		if hit.Normal.Y > 0 then
			local name = if part then part.Name else "?"
			-- A part the runtime made pass-through is neither a floor (you fall
			-- through it) NOR a ceiling (you walk through it) - Hollow's ledger
			-- desk is `Wreckwater_Hut_Props`, stripped by WorldService, and it
			-- sits 3.5 studs over the beach he stands on. Reading the live
			-- property rather than re-listing NON_COLLIDE means the two can
			-- never drift (NpcService is LAST in ORDER - the world is already
			-- stripped by the time we ask).
			local solid = part == nil or part.CanCollide
			table.insert(hits, {
				y = hit.Position.Y,
				name = name,
				solid = solid,
				floor = solid and isFloorName(name),
			})
		end
		y = hit.Position.Y - 0.05
	end
	return hits
end

-- The ground an NPC's feet go on: the LOWEST standable surface in the column,
-- not the first thing a ray from y=120 touches.
--
-- The first-hit rule put Old Maren on her own porch ROOF, 18 studs above the
-- counter she is written to stand behind, and Quartermaster Hollow on his
-- awning - and both read as ordinary successful placements in the log, because
-- nothing in the path ever asked whether the hit was a floor. A stand point is
-- authored UNDER cover on purpose, so the probe has to see past the cover.
--
-- A hit qualifies when it is above the waterline, collidable, not a
-- fluid/roof/awning by name, and has at least FLOOR_HEADROOM studs of air to
-- the next SOLID surface above it (or nothing solid above at all). The lowest
-- qualifier wins, which is the floor of the innermost enclosure over that XZ.
-- If nothing
-- qualifies we fall back to the old first-hit answer and WARN - a bad
-- placement that says so beats an NPC who never appears.
-- Returns the Y and the NAME of the part that Y came from (the second value is
-- what the placement log prints, so a villager standing somewhere odd names the
-- surface they are standing on instead of leaving you to guess).
local function probeGroundY(x: number, z: number, fromY: number?): (number?, string?)
	local hits = columnHits(x, z, fromY)
	if not hits or #hits == 0 then
		return nil, if hits then "no hit in the column" else "no " .. World.FOLDER_NAME .. " folder"
	end
	for i = #hits, 1, -1 do
		local h = hits[i]
		if h.floor and h.y >= FLOOR_MIN_Y then
			-- Headroom is measured to the nearest SOLID surface above, not to
			-- the nearest hit: a canvas awning or a prop counter overhead is
			-- something the body passes through, so it cannot disqualify the
			-- floor underneath it.
			local gap = math.huge
			for j = i - 1, 1, -1 do
				if hits[j].solid then
					gap = hits[j].y - h.y
					break
				end
			end
			if gap >= FLOOR_HEADROOM then
				return h.y, h.name
			end
		end
	end
	warn(
		string.format(
			"[NpcService] No standable floor under (%.1f, %.1f): %d hit(s), topmost %q at Y=%.1f."
				.. " Standing on it anyway - check the row's spawnOffset against the generator's HANDOFF stand.",
			x,
			z,
			#hits,
			hits[1].name,
			hits[1].y
		)
	)
	return hits[1].y, hits[1].name
end

-- A cosmetic part: never collides, never queries, never weighs anything (a
-- hat that adds mass to an anchored rig is harmless, but Massless keeps the
-- assembly honest if one is ever unanchored).
local function decorPart(name: string, size: Vector3, color: Color3, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.Parent = parent
	return part
end

-- Headwear rides the Head with a WeldConstraint, so it follows the animated
-- head without being a joint in the rig's Motor6D chain.
local function weldTo(part: BasePart, target: BasePart)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = target
	weld.Part1 = part
	weld.Parent = part
end

-- Procedural hats: no asset ids anywhere (a catalogue accessory only loads
-- for the account that owns it, and these must render for everyone).
local function addHeadwear(model: Model, head: BasePart, look)
	local kind = look.hat
	if kind == "none" or kind == nil then
		return
	end
	local w, h, d = head.Size.X, head.Size.Y, head.Size.Z
	local top = h * 0.5

	-- A slab sits square on the head; a disc is a Part cylinder turned to lie
	-- flat (a cylinder's length runs along its X axis). The weld is made LAST
	-- in both: a WeldConstraint captures the offset it is created at, so a
	-- CFrame written afterwards would be snapped back out again.
	local function slab(name: string, size: Vector3, offset: CFrame)
		local part = decorPart(name, size, look.hatColor, model)
		part.CFrame = head.CFrame * offset
		weldTo(part, head)
		return part
	end
	local function disc(name: string, diameter: number, thickness: number, y: number)
		local part = decorPart(name, Vector3.new(thickness, diameter, diameter), look.hatColor, model)
		part.Shape = Enum.PartType.Cylinder
		part.CFrame = head.CFrame * CFrame.new(0, y, 0) * CFrame.Angles(0, 0, math.rad(90))
		weldTo(part, head)
		return part
	end

	if kind == "brim" then
		disc("HatBrim", w * 2.0, 0.16, top + 0.08)
		disc("HatCrown", w * 0.95, 0.62, top + 0.45)
	elseif kind == "hood" then
		slab("Hood", Vector3.new(w * 1.28, h * 1.16, d * 1.34), CFrame.new(0, top * 0.22, d * 0.18))
	elseif kind == "scarf" then
		disc("Scarf", w * 1.18, 0.46, -top - 0.16)
	elseif kind == "cap" then
		disc("Cap", w * 1.06, 0.34, top + 0.16)
	elseif kind == "tricorn" then
		-- Three slabs pinned up around the crown: the shape reads from any
		-- angle, which a single brim does not.
		disc("TricornCrown", w * 0.9, 0.42, top + 0.3)
		for i = 0, 2 do
			slab(
				string.format("TricornFlap%d", i + 1),
				Vector3.new(w * 1.55, 0.14, w * 0.46),
				CFrame.new(0, top + 0.18, 0)
					* CFrame.Angles(0, math.rad(i * 120), 0)
					* CFrame.new(0, 0, -w * 0.5)
					* CFrame.Angles(math.rad(24), 0, 0)
			)
		end
	elseif kind == "furhat" then
		disc("FurHat", w * 1.38, 0.78, top + 0.34)
	elseif kind == "mask" then
		slab("FacePlate", Vector3.new(w * 0.94, h * 0.56, 0.12), CFrame.new(0, h * 0.06, -(d * 0.5) - 0.06))
	end
end

local function addHair(model: Model, head: BasePart, color: Color3)
	local w, h, d = head.Size.X, head.Size.Y, head.Size.Z
	local cap = decorPart("HairCap", Vector3.new(w * 1.04, h * 0.4, d * 1.04), color, model)
	cap.CFrame = head.CFrame * CFrame.new(0, h * 0.5 - h * 0.18, 0)
	weldTo(cap, head)
end

local function describe(look): HumanoidDescription
	local desc = Instance.new("HumanoidDescription")
	desc.HeadColor = look.skin
	desc.TorsoColor = look.shirt
	desc.LeftArmColor = look.sleeves
	desc.RightArmColor = look.sleeves
	desc.LeftLegColor = look.pants
	desc.RightLegColor = look.pants
	desc.HeightScale = look.height
	desc.WidthScale = look.width
	desc.DepthScale = look.width
	desc.HeadScale = 1
	return desc
end

-- The fallback when CreateHumanoidModelFromDescription is unavailable or
-- returns nothing (offline Studio, a throttled avatar endpoint): a plain R6
-- block rig, same colours, same contract. HipHeight is set to the real 2 so
-- the one grounding formula below works for BOTH rigs.
local function blockRig(look): Model
	local model = Instance.new("Model")
	local root = decorPart("HumanoidRootPart", Vector3.new(2, 2, 1), look.shirt, model)
	root.Transparency = 1
	root.CFrame = CFrame.new(0, 0, 0)

	local function limb(name: string, size: Vector3, color: Color3, offset: Vector3): BasePart
		local part = decorPart(name, size, color, model)
		part.CFrame = root.CFrame * CFrame.new(offset)
		local motor = Instance.new("Motor6D")
		motor.Name = name .. "Joint"
		motor.Part0 = root
		motor.Part1 = part
		motor.C0 = CFrame.new(offset)
		motor.Parent = root
		return part
	end

	local scaleY, scaleXZ = look.height, look.width
	limb("Torso", Vector3.new(2 * scaleXZ, 2 * scaleY, 1 * scaleXZ), look.shirt, Vector3.new(0, 0, 0))
	local head = limb("Head", Vector3.new(2 * scaleXZ, 1 * scaleY, 1 * scaleXZ), look.skin, Vector3.new(0, 1.5, 0))
	head.Name = "Head"
	limb("Right Arm", Vector3.new(1 * scaleXZ, 2 * scaleY, 1 * scaleXZ), look.sleeves, Vector3.new(1.5, 0, 0))
	limb("Left Arm", Vector3.new(1 * scaleXZ, 2 * scaleY, 1 * scaleXZ), look.sleeves, Vector3.new(-1.5, 0, 0))
	limb("Right Leg", Vector3.new(1 * scaleXZ, 2 * scaleY, 1 * scaleXZ), look.pants, Vector3.new(0.5, -2, 0))
	limb("Left Leg", Vector3.new(1 * scaleXZ, 2 * scaleY, 1 * scaleXZ), look.pants, Vector3.new(-0.5, -2, 0))

	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R6
	humanoid.HipHeight = 2
	humanoid.Parent = model
	model.PrimaryPart = root
	return model
end

-- Returns the model and its Humanoid, or nil if even the fallback couldn't
-- produce a rig (which would be a Roblox-side failure, not a data one).
local function buildBody(npc): (Model?, Humanoid?)
	local look = lookOf(npc)
	local model: Model? = nil
	local ok, built = pcall(function()
		return Players:CreateHumanoidModelFromDescription(describe(look), Enum.HumanoidRigType.R15)
	end)
	-- Four ways the avatar path fails, and ALL FOUR take the block rig: it
	-- errors (offline Studio, a throttled avatar endpoint), it returns nil, it
	-- returns something that is not a Model, or it returns a Model that is
	-- missing the Humanoid or the HumanoidRootPart the rest of this function
	-- indexes. The last two used to fall through to `return nil, nil` further
	-- down - a rig half-built by Roblox meant NO villager rather than a blocky
	-- one, which is the wrong trade for a cosmetic body.
	local usable = ok
		and typeof(built) == "Instance"
		and built:IsA("Model")
		and built:FindFirstChildWhichIsA("Humanoid") ~= nil
		and built:FindFirstChild("HumanoidRootPart") ~= nil
	if usable then
		model = built
	else
		local why = if not ok
			then string.format("errored (%s)", tostring(built))
			elseif built == nil then "returned nil"
			elseif typeof(built) ~= "Instance" or not built:IsA("Model") then "returned a non-Model"
			else "returned a rig with no Humanoid/HumanoidRootPart"
		warn(
			string.format(
				"[NpcService] %s: CreateHumanoidModelFromDescription %s; using the block rig",
				tostring(npc.id),
				why
			)
		)
		if typeof(built) == "Instance" then
			built:Destroy()
		end
		model = blockRig(look)
	end
	local humanoid = model and model:FindFirstChildWhichIsA("Humanoid")
	local root = model and model:FindFirstChild("HumanoidRootPart")
	if not (model and humanoid and root and root:IsA("BasePart")) then
		if model then
			model:Destroy()
		end
		warn(string.format("[NpcService] %s: no rig could be built", npc.id))
		return nil, nil
	end

	model.Name = "Npc_" .. npc.id
	model.PrimaryPart = root
	model:SetAttribute("NpcId", npc.id)
	for _, inst in model:GetDescendants() do
		if inst:IsA("BasePart") then
			-- Only the ROOT anchors: the limbs must stay free for the Motor6D
			-- chain (and the idle animation) to move them, and the assembly is
			-- held in place through the root regardless.
			inst.Anchored = false
			inst.CanCollide = false
			inst.CanQuery = false
			inst.CanTouch = false
			inst.Massless = true
		end
	end
	root.Anchored = true
	-- The root alone is queryable: it is the small invisible box at the hips,
	-- and a ClickDetector only fires on a part a mouse ray can hit. Every
	-- Exclude-filtered ray in the game either respects CanCollide (the camera
	-- occluder) or is an aim/probe ray for which a hidden hip box is harmless;
	-- the visible limbs stay CanQuery=false so nothing ever targets a villager.
	root.CanQuery = true

	-- THE NAMEPLATE PROPERTIES, AND WHY THEY ARE PCALL'D. `Humanoid` has
	-- `DisplayDistanceType`, `HealthDisplayType`, `HealthDisplayDistance`,
	-- `NameDisplayDistance` and `DisplayName` - it has NO
	-- `HealthDisplayDistanceType`. Writing that name threw
	-- "HealthDisplayDistanceType is not a valid member of Humanoid" on the FIRST
	-- row, out of buildBody, out of placeNpc, out of NpcService.start - and the
	-- boot loop is fail-fast, so every NPC in the game was missing while the
	-- islands and the HUD looked perfect. stylua, selene, rojo and luau-compile
	-- all pass a misspelled property: nothing but the running engine knows the
	-- name. So the whole cosmetic block is pcall'd as one unit now - if Roblox
	-- ever renames one of these, an NPC gets a nameplate it shouldn't have
	-- instead of taking the server down.
	pcall(function()
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.NameDisplayDistance = 0
		humanoid.HealthDisplayDistance = 0
		humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
		-- The BillboardGui in addNameplate is the only name the player reads;
		-- DisplayName is what a chat mention or a future default plate would
		-- use, so it carries the row's name rather than "Npc_<id>".
		humanoid.DisplayName = tostring(npc.name or npc.id)
	end)
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid.AutoRotate = false
	-- A rig whose every part is CanCollide=false stands on nothing as far as the
	-- Humanoid is concerned: its state machine sees no floor, drops into
	-- Freefall/FallingDown and starts running GettingUp on a body that is held
	-- up by an anchored root. Physics is the "hold this pose" state - animations
	-- still play in it, the state machine stops deciding things - and the two
	-- falling states are disabled so nothing puts it back. BreakJointsOnDeath is
	-- the other half: if anything ever kills this Humanoid (a RequiresNeck
	-- complaint, a stray Health write), the default is to sever every Motor6D
	-- and drop the villager into a heap of loose limbs.
	humanoid.BreakJointsOnDeath = false
	humanoid.RequiresNeck = false
	pcall(function()
		humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
	end)

	local head = model:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		if look.hair then
			addHair(model, head, look.hair)
		end
		addHeadwear(model, head, look)
	end

	-- THE CLICK TARGET. The ClickDetector answers for the whole model, but a
	-- mouse ray can only land on a part with CanQuery=true - and the only such
	-- part is the invisible root box at the hips, so clicking the head, an arm or
	-- a leg did nothing at all (the ray passes straight through every visible
	-- limb). One invisible box the size of the person fixes that. It stays
	-- CanCollide=false, so every aim/probe/occlusion ray in the game still misses
	-- it: they all set RespectCanCollide = true (CreatureService,
	-- RangedController, CameraController), and nothing reads Mouse.Target.
	-- Centred on the root, which sits footDrop (~3) above the feet, so the box
	-- runs from the soles to a little over the head at every `look.height`.
	local hitbox = decorPart("TalkHitbox", Vector3.new(3.2, 6.4, 2.4), look.shirt, model)
	hitbox.Transparency = 1
	hitbox.CFrame = root.CFrame
	hitbox.CanQuery = true
	weldTo(hitbox, root)
	return model, humanoid
end

-- The seat under a seated NPC, built from primitives at the stand point the
-- placement probe verified (`atFloor`: position on the floor, rotation the
-- row's `facing`) with its top face `top` studs up. Nothing here collides or
-- queries - a stool you can trip over in a hut doorway is worse than no stool,
-- and the TalkHitbox must stay the only thing a mouse ray finds. Every piece is
-- ANCHORED and parented AFTER the body is posed, so neither PivotTo nor the
-- facing tween (both of which move only the root) can drag it.
local function buildSeat(model: Model, kind: string, color: Color3, atFloor: CFrame, top: number)
	if kind == "none" then
		return
	end
	local function piece(name: string, size: Vector3, offset: CFrame, shape: Enum.PartType?): Part
		local part = decorPart(name, size, color, model)
		part.Material = Enum.Material.Wood
		if shape then
			part.Shape = shape
		end
		part.CFrame = atFloor * offset
		part.Anchored = true
		return part
	end
	if kind == "stool" then
		-- A round seat on three legs. A Part cylinder's length runs along its X
		-- axis, so the disc is turned onto its side; the legs stay boxes.
		local legH = math.max(top - 0.34, 0.2)
		piece(
			"SeatTop",
			Vector3.new(0.34, 2.1, 2.1),
			CFrame.new(0, top - 0.17, 0) * CFrame.Angles(0, 0, math.rad(90)),
			Enum.PartType.Cylinder
		)
		for i = 0, 2 do
			piece(
				string.format("SeatLeg%d", i + 1),
				Vector3.new(0.26, legH, 0.26),
				CFrame.Angles(0, math.rad(i * 120), 0) * CFrame.new(0, legH * 0.5, 0.72)
			)
		end
	elseif kind == "crate" then
		piece("SeatCrate", Vector3.new(2.2, top, 2.2), CFrame.new(0, top * 0.5, 0))
	elseif kind == "bench" then
		local blockH = math.max(top - 0.36, 0.2)
		piece("SeatPlank", Vector3.new(5.2, 0.36, 1.8), CFrame.new(0, top - 0.18, 0))
		for i, side in { -1, 1 } do
			piece(
				string.format("SeatBlock%d", i),
				Vector3.new(0.8, blockH, 1.6),
				CFrame.new(side * 1.9, blockH * 0.5, 0)
			)
		end
	elseif kind == "log" then
		-- A cylinder on its side: its length already runs along X, so it only
		-- needs lifting to its own radius, which IS the seat height.
		piece("SeatLog", Vector3.new(4.4, top * 2, top * 2), CFrame.new(0, top, 0), Enum.PartType.Cylinder)
	end
end

-- Animator + the two default clips. Every step is pcall'd: LoadAnimation on
-- an id Studio can't reach throws, and that must not take the island down.
local function setupAnimation(npc, model: Model, humanoid: Humanoid, sitting: boolean)
	if humanoid.RigType ~= Enum.HumanoidRigType.R15 then
		return -- the block rig is R6; the default clips are R15 only
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	local function load(id: string): AnimationTrack?
		local anim = Instance.new("Animation")
		anim.AnimationId = id
		anim.Parent = model
		local loaded, track = pcall(function()
			return animator:LoadAnimation(anim)
		end)
		return if loaded then track else nil
	end
	-- A seated body plays the sit clip in the idle's place: two looped
	-- full-body tracks would fight, and the sit has to be the one that wins.
	local resting = load(if sitting then SIT_ANIM else IDLE_ANIM)
	if resting then
		resting.Looped = true
		resting.Priority = Enum.AnimationPriority.Idle
		pcall(function()
			resting:Play(0.2)
		end)
	end
	if not sitting then
		-- No wave while seated: the wave is an Action-priority FULL BODY clip,
		-- so it would stand the villager up out of their own chair for a second.
		local wave = load(WAVE_ANIM)
		if wave then
			wave.Priority = Enum.AnimationPriority.Action
			waveTracks[npc.id] = wave
		end
	end
end

local function waveAt(npcId: string)
	local track = waveTracks[npcId]
	if track then
		pcall(function()
			track:Play(0.15)
		end)
	end
end

-- Turn the anchored root's YAW toward a point, keeping its position. The
-- tween runs on the root; the rest of the rig hangs off it.
local function turnRoot(npcId: string, goal: CFrame, seconds: number)
	local model = placed[npcId]
	local root = model and model.PrimaryPart
	if not root then
		return
	end
	local previous = facingTweens[npcId]
	if previous then
		previous:Cancel()
	end
	local tween = TweenService:Create(root, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		CFrame = goal,
	})
	facingTweens[npcId] = tween
	tween:Play()
end

-- The yaw a pure-yaw CFrame is carrying. CFrame.Angles(0, y, 0) has a
-- LookVector of (-sin y, 0, -cos y), so this inverts exactly that - no Euler
-- decomposition, and it works on a CFrame.lookAt result too.
local function yawOf(cf: CFrame): number
	local look = cf.LookVector
	return math.atan2(-look.X, -look.Z)
end

local function faceToward(npcId: string, player: Player)
	local model = placed[npcId]
	local root = model and model.PrimaryPart
	local character = player.Character
	local at = character and character:FindFirstChild("HumanoidRootPart")
	if not (root and at and at:IsA("BasePart")) then
		return
	end
	local flat = Vector3.new(at.Position.X, root.Position.Y, at.Position.Z)
	if (flat - root.Position).Magnitude < 0.05 then
		return
	end
	local goal = yawOf(CFrame.lookAt(root.Position, flat))
	if seated[npcId] then
		-- A seated body turns its shoulders, not its whole self: the root IS the
		-- hips, and the seat was built under where the hips are, so a full turn
		-- would swing the body off its own stool. Clamp the change against the
		-- row's `facing` (the home CFrame), wrapping the difference into
		-- (-pi, pi] first so a target behind them doesn't clamp the long way.
		local home = homeCFrame[npcId]
		local base = if home then yawOf(home) else goal
		local delta = (goal - base + math.pi) % (2 * math.pi) - math.pi
		goal = base + math.clamp(delta, -SEATED_YAW_LIMIT, SEATED_YAW_LIMIT)
	end
	facingWho[npcId] = player
	turnRoot(npcId, CFrame.new(root.Position) * CFrame.Angles(0, goal, 0), FACE_TIME)
end

-- Back to the row's `facing`, but only for the player they actually turned
-- to: someone else's farewell must not spin them away mid-sentence.
local function faceHome(npcId: string, player: Player)
	if facingWho[npcId] ~= player then
		return
	end
	facingWho[npcId] = nil
	local home = homeCFrame[npcId]
	if home then
		turnRoot(npcId, home, UNFACE_TIME)
	end
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
	-- `name`/`title` are contract fields, but a TextLabel assigned nil THROWS,
	-- and this runs inside the fail-fast boot: a row that forgot its title must
	-- cost a blank line, not the server.
	name.Text = tostring(npc.name or npc.id)
	name.Parent = gui
	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.new(0, 0, 0, 24)
	title.Size = UDim2.new(1, 0, 0, 18)
	title.Font = Enum.Font.Gotham
	title.TextSize = 13
	title.TextColor3 = Color3.fromRGB(214, 224, 206)
	title.TextStrokeTransparency = 0.4
	title.Text = tostring(npc.title or "")
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
	-- Defensive about the row's SHAPE, not its contents: a shop with no `stock`
	-- (or a `rotating` missing either half) is a data mistake, and it has to read
	-- as an empty shelf rather than an error thrown inside a pane push - which
	-- would leave the player looking at a dialog that simply never answers.
	local shelves = if type(shop.stock) == "table" then table.clone(shop.stock) else {}
	local rotating = if type(shop.rotating) == "table" then shop.rotating else nil
	local slots = if rotating then tonumber(rotating.slots) or 0 else 0
	if rotating and slots > 0 and type(rotating.pool) == "table" and #rotating.pool > 0 then
		local seed = math.floor(os.time() / 86400) * 131
		for i = 1, #shop.id do
			seed += string.byte(shop.id, i) * i
		end
		local rng = Random.new(seed)
		local pool = table.clone(rotating.pool)
		for _ = 1, math.min(slots, #pool) do
			local pick = rng:NextInteger(1, #pool)
			table.insert(shelves, pool[pick])
			table.remove(pool, pick)
		end
	end
	return shelves
end

-- A shop slot's display NAME (the amount and the price ride the wire as
-- numbers now - the trade row draws them itself, so no label has to be parsed
-- back apart on the client).
local function slotName(slot): string
	if slot.kind == "bait" then
		local row = Bait.items[slot.id]
		return row and row.name or slot.id
	elseif slot.kind == "material" then
		local row = Materials.items[slot.id]
		return row and row.name or slot.id
	elseif slot.kind == "item" then
		local row = Armor.items[slot.id] or Trinkets.items[slot.id]
		return row and row.name or slot.id
	end
	return slot.id
end

-- ============================================================ voice

-- Neutral fallbacks for every `voice` key the contract names. A row that
-- omits one still reads like a person; these deliberately carry no verbal
-- tic of their own - the flavour belongs in the row, not in this file.
local VOICE_DEFAULT: { [string]: string } = {
	accept = "Then it's settled. Off you go.",
	done = 'That squares "%s". Well done.',
	notYet = "That work isn't finished yet.",
	missingGoods = "You don't have the goods on you.",
	busy = '(Still at work on "%s", I see.)',
	nothing = "Nothing for you today. Come back when the water's changed.",
	locked = "I'll have \"%s\" for you once you've reached level %d.",
	lockedPrereq = 'Finish "%s" first, then we\'ll talk about the rest.',
	shopOpen = "Have a look, then. Coin up front.",
	shopBought = "There you go. Anything else?",
	shopShort = "Short on coin. Come back heavier.",
	shopOwned = "You've already got one of those.",
	farewell = "Farewell",
	progress = 'Where are you with "%s", then?',
	complete = 'So that\'s "%s" done. Let me settle up.',
}

local function voiceOf(npc, key: string): string
	local voice = if type(npc.voice) == "table" then npc.voice else nil
	local line = voice and voice[key]
	if type(line) == "string" and line ~= "" then
		return line
	end
	return VOICE_DEFAULT[key] or ""
end

-- string.format over AUTHORED text. A row whose "%s" went missing (or grew a
-- stray "%") must not throw inside a dialog push, so a bad template falls
-- back to itself, unformatted.
local function fmt(template: string, ...): string
	local ok, out = pcall(string.format, template, ...)
	return if ok then out else template
end

-- A quest's own line for a moment, if it has one (Quests.items.<id>.lines).
local function questLine(quest, key: string): string?
	local lines = if quest and type(quest.lines) == "table" then quest.lines else nil
	local line = lines and lines[key]
	return if type(line) == "string" and line ~= "" then line else nil
end

-- The one wire call. Every payload carries { npcId, name, title, pane, kind }
-- and whatever else the pane needs: `pane` says what is being drawn
-- ("dialogue" or "menu"), `kind` says what just happened (the sound lane keys
-- its chime off that, never off the text).
local function send(player: Player, npc, pane: string, kind: string, fields: { [string]: any })
	local payload: { [string]: any } = {
		npcId = npc.id,
		name = npc.name,
		title = npc.title,
		pane = pane,
		kind = kind,
	}
	for key, value in fields do
		payload[key] = value
	end
	Remotes.NpcDialog:FireClient(player, payload)
end

-- ============================================================ met + state

-- WHO EACH PLAYER HAS ALREADY MET, persisted as the "npcs" DataService slice
-- ({ met = { [npcId] = true } }). The first meeting ever is the black-screen
-- introduction, and it must not replay next session - which is the whole reason
-- this is a slice and not the session table it used to be. Ids are validated
-- against Npcs.items on load (the QuestService/MaterialService habit), so a cut
-- NPC drops out of old profiles instead of sitting in them forever.
local met: { [Player]: { [string]: boolean } } = {}

local function metOf(player: Player): { [string]: boolean }
	local seen = met[player]
	if not seen then
		seen = {}
		met[player] = seen
	end
	return seen
end

local function loadMet(player: Player, slice)
	local seen = metOf(player)
	local rows = if type(slice) == "table" and type(slice.met) == "table" then slice.met else {}
	for npcId, value in rows do
		if type(npcId) == "string" and value and Npcs.items[npcId] then
			seen[npcId] = true
		end
	end
end

local function serializeMet(player: Player)
	return { met = table.clone(metOf(player)) }
end

-- ONE LIVE CONVERSATION per player per NPC:
--   node  - the node whose replies are the ONLY transitions this player may
--           take with this NPC. A "node:<id>" naming anything else is a forged
--           jump (straight into the middle of a lore branch, say) and is
--           dropped. nil means no talk is in progress - the menu is open, or
--           the conversation ended.
--   said  - the last line the NPC actually spoke, which becomes the menu's
--           remark when the menu opens off the end of a talk: the panel's
--           speech strip then carries what they JUST said instead of a
--           generic line.
--   black - whether this conversation is the black-screen one. It has to
--           persist across every push of the talk, or page two of a first
--           meeting would drop the curtain mid-sentence.
local conv: { [Player]: { [string]: { node: string?, said: string?, black: boolean } } } = {}

local function convOf(player: Player, npcId: string)
	local rows = conv[player]
	if not rows then
		rows = {}
		conv[player] = rows
	end
	local row = rows[npcId]
	if not row then
		row = { node = nil, said = nil, black = false }
		rows[npcId] = row
	end
	return row
end

-- ============================================================ dialogue trees

-- The stand-in tree for a row with no `dialogue`: the old two-pane greeting in
-- the new shape - one node of the full `greeting` for a first meeting, one node
-- of a single `hello` line for every meeting after, neither with any replies,
-- so both end by opening the menu. Built fresh per talk rather than memoised,
-- because `hello` is a POOL (a different line each visit); nothing caches a
-- node id across pushes except `conv`, and a generated node has no choices to
-- validate against anyway.
local GEN_FIRST = "auto_first"
local GEN_AGAIN = "auto_again"

local function generatedDialogue(npc)
	local greeting = if type(npc.greeting) == "table" then npc.greeting else {}
	local first = {}
	for _, line in greeting do
		if type(line) == "string" and line ~= "" then
			table.insert(first, line)
		end
	end
	if #first == 0 then
		-- A row with no greeting AND no dialogue: say the one thing `voice`
		-- always has rather than opening a silent black screen.
		table.insert(first, voiceOf(npc, "nothing"))
	end
	local hello = if type(npc.hello) == "table" then npc.hello else {}
	local again = if #hello > 0 then tostring(hello[math.random(1, #hello)]) else first[1]
	return {
		first = GEN_FIRST,
		again = GEN_AGAIN,
		nodes = {
			[GEN_FIRST] = { say = first, choices = {} },
			[GEN_AGAIN] = { say = { again }, choices = {} },
		},
	}
end

local function dialogueOf(npc)
	local tree = if type(npc.dialogue) == "table" then npc.dialogue else nil
	if not (tree and type(tree.nodes) == "table") then
		return generatedDialogue(npc)
	end
	return tree
end

-- A node's pages, as strings and never empty: the client types each one out in
-- turn, and a page that is nil would leave the window waiting on a line that
-- never arrives.
local function sayLines(node): { string }
	local out = {}
	local pages = if type(node.say) == "table" then node.say else {}
	for _, line in pages do
		if type(line) == "string" and line ~= "" then
			table.insert(out, line)
		end
	end
	if #out == 0 then
		table.insert(out, "...")
	end
	return out
end

-- A node's replies as the wire's { id, text }. `next` is a node id unless it is
-- one of the two terminals: "menu" (end the talk, open the business panel) and
-- "end" (a polite exit - the window simply closes). A reply pointing at a node
-- that does not exist is dropped HERE and warned about, rather than pushed and
-- then refused when it is pressed: check_content cannot see `next` typos, and a
-- dead button is worse than a missing one.
local function wireChoices(npc, tree, node): { any }
	local out = {}
	local choices = if type(node.choices) == "table" then node.choices else {}
	for _, choice in choices do
		local text = if type(choice) == "table" and type(choice.text) == "string" then choice.text else nil
		local target = if type(choice) == "table" and type(choice.next) == "string" then choice.next else ""
		if text and text ~= "" then
			if target == "menu" or target == "end" then
				table.insert(out, { id = target, text = text })
			elseif tree.nodes[target] then
				table.insert(out, { id = "node:" .. target, text = text })
			else
				warn(
					string.format(
						"[NpcService] %s: reply %q points at unknown node %q - dropped",
						tostring(npc.id),
						text,
						target
					)
				)
			end
		end
	end
	return out
end

-- ============================================================ the menu

-- The client's buy chime reads a bought remark and keys off this exact prefix
-- when the payload carries no `kind`, so a row whose shopBought forgot it gets
-- it prefixed here rather than silently losing the cue.
local SHOP_SUCCESS_PREFIX = "There you go"

local function boughtLine(npc): string
	local line = voiceOf(npc, "shopBought")
	if string.sub(line, 1, #SHOP_SUCCESS_PREFIX) ~= SHOP_SUCCESS_PREFIX then
		line = SHOP_SUCCESS_PREFIX .. ". " .. line
	end
	return line
end

-- WORK: one card per thing this giver has for this player, in the giver's own
-- order. `status` is the pill the panel draws; `progress` is the expandable
-- objective list (a tally for an accepted quest, the terms for one on offer);
-- `locked` is the giver's own line about why they can't hand it over yet.
local function questCards(player: Player, npc): { any }
	local cards = {}
	for _, offer in QuestService.offersFor(player, npc) do
		local quest = offer.quest
		local card = {
			id = quest.id,
			name = tostring(quest.name or quest.id),
			blurb = tostring(quest.blurb or ""),
			status = offer.status,
			progress = {},
			reward = rewardText(quest.rewards or {}),
		}
		if offer.status == "active" then
			card.status = if offer.ready then "ready" else "active"
			for _, row in QuestService.progressOf(player, quest.id) or {} do
				table.insert(card.progress, {
					text = objectiveText(row.objective),
					count = math.min(row.count, row.needed),
					needed = row.needed,
					done = row.done,
				})
			end
		else
			-- On offer (or locked): the TERMS, not a tally - there is nothing to
			-- count yet.
			for _, objective in quest.objectives or {} do
				table.insert(card.progress, {
					text = objectiveText(objective),
					count = 0,
					needed = objective.count or 1,
					done = false,
				})
			end
		end
		if offer.status == "locked" then
			if offer.reason == "level" then
				card.locked = fmt(voiceOf(npc, "locked"), card.name, quest.requiresLevel or 0)
			else
				local prereq = offer.prereqQuest
				card.locked = fmt(voiceOf(npc, "lockedPrereq"), (prereq and prereq.name) or card.name)
			end
		end
		table.insert(cards, card)
	end
	return cards
end

-- TRADE: today's shelves as rows. The INDEX is the only thing a buy ever names
-- (the client cannot ask for an item id, a price or an amount), so the server
-- re-derives the identical shelf from the same deterministic day seed when the
-- purchase comes back. nil means this NPC keeps no stall at all.
local function shopRows(player: Player, npc): { any }?
	local shop = npc.shop and Shops.items[npc.shop]
	if not shop then
		return nil
	end
	local rows = {}
	for index, slot in stockToday(shop) do
		table.insert(rows, {
			index = index,
			name = slotName(slot),
			amount = if slot.kind == "item" then 1 else tonumber(slot.amount) or 1,
			price = tonumber(slot.price) or 0,
			-- Only a one-of-a-kind thing can be owned already; bait and
			-- materials stack forever.
			owned = slot.kind == "item" and InventoryService.ownsItem(player, slot.id) or false,
		})
	end
	return rows
end

-- ============================================================ the craft tab

-- CRAFT: the old `C` window's tabs, as menu sections. `items` is the data table
-- the recipes live on and `key` is the kind the wire carries, which is also what
-- an "equip:<kind>:<id>" names. Order here is the order of the sub-tabs.
local CRAFT_SECTIONS = {
	{ key = "rod", label = "Rods", items = Rods.items },
	{ key = "weapon", label = "Weapons", items = Weapons.items },
	{ key = "armor", label = "Armor", items = Armor.items },
	{ key = "trinket", label = "Charms", items = Trinkets.items },
	{ key = "boat", label = "Boats", items = Boats.items },
	{ key = "bait", label = "Bait", items = Bait.items },
}

-- OWNED and EQUIPPED per kind, which is where the six kinds actually differ.
-- Armor's worn state spans three attributes (one per slot, Armor.ATTRIBUTES);
-- bait is a COUNT, not an id in the inventory; a boat is a LADDER, so "owned"
-- means the tier is at or below the one you have and "equipped" means it is
-- the hull you would summon.
local function craftState(player: Player, kind: string, item): (boolean, boolean)
	if kind == "bait" then
		local count = BaitService.getCount(player, item.id)
		return count > 0, player:GetAttribute(Equipment.BAIT_ATTRIBUTE) == item.id
	end
	if kind == "boat" then
		local tier = BoatService.tierOf(player)
		return tier >= item.tier, tier == item.tier
	end
	local owned = InventoryService.ownsItem(player, item.id)
	if kind == "rod" then
		return owned, player:GetAttribute(Equipment.ROD_ATTRIBUTE) == item.id
	end
	if kind == "weapon" then
		return owned, player:GetAttribute(Equipment.WEAPON_ATTRIBUTE) == item.id
	end
	if kind == "armor" then
		local attribute = Armor.ATTRIBUTES[item.slot]
		return owned, attribute ~= nil and player:GetAttribute(attribute) == item.id
	end
	return owned, player:GetAttribute(Equipment.TRINKET_ATTRIBUTE) == item.id
end

-- One row's cost, as the panel prints it: the coins, then each material with
-- what you have against what it needs. Walked in Materials.order rather than
-- over the recipe table so two pushes of the same recipe list them in the same
-- order (a pairs() walk would shuffle the lines under the player's eyes).
local function materialRows(player: Player, recipe): { any }
	local rows = {}
	for _, matId in Materials.order do
		local need = recipe.materials[matId]
		if need then
			local mat = Materials.items[matId]
			table.insert(rows, {
				id = matId,
				name = if mat then mat.name else matId,
				need = need,
				have = MaterialService.getCount(player, matId),
			})
		end
	end
	return rows
end

-- The heart-gated Legendaries: a requirement that is owned-or-not, never a
-- count, because a heart is a permanent attribute and never a spent material.
local function heartRows(player: Player, recipe): { any }?
	if not recipe.requiresHearts then
		return nil
	end
	local rows = {}
	for _, bossId in recipe.requiresHearts do
		local boss = Bosses.items[bossId]
		table.insert(rows, {
			id = bossId,
			name = if boss then boss.shortName else bossId,
			have = player:GetAttribute("Heart_" .. bossId) == true,
		})
	end
	return rows
end

-- One section's rows. A row shows up when there is a recipe to work OR the thing
-- is already yours (the starter rod and the fists have no recipe but are still
-- equipped from here, and the first hull is Brinejaw's bounty). Sorted by the
-- level gate then the id, exactly as the old grid was, so a section reads as a
-- ladder.
local function craftRows(player: Player, section): { any }
	local rows = {}
	for id, item in section.items do
		local recipe = item.recipe
		local owned, equipped = craftState(player, section.key, item)
		if recipe or owned then
			local canCraft, reason = false, nil
			if recipe then
				canCraft, reason = CraftingService.check(player, id)
			end
			table.insert(rows, {
				id = id,
				name = tostring(item.name or id),
				kind = section.key,
				level = if recipe then recipe.requiresLevel else 0,
				coins = if recipe then recipe.coins else 0,
				materials = if recipe then materialRows(player, recipe) else {},
				hearts = if recipe then heartRows(player, recipe) else nil,
				-- Bait stacks and is never "owned" the way a rod is; the count is
				-- what the card shows, and `yield` is how many one craft makes.
				count = if section.key == "bait" then BaitService.getCount(player, id) else nil,
				yield = if section.key == "bait" and recipe then recipe.yield else nil,
				owned = owned,
				equipped = equipped,
				craftable = recipe ~= nil,
				canCraft = canCraft,
				reason = if canCraft then nil else reason,
			})
		end
	end
	table.sort(rows, function(a, b)
		if a.level ~= b.level then
			return a.level < b.level
		end
		return a.id < b.id
	end)
	return rows
end

-- The whole Craft tab, or nil for a villager who works no bench. A section with
-- nothing in it is dropped rather than sent as an empty sub-tab.
local function craftSections(player: Player, npc): { any }?
	if npc.crafts ~= true then
		return nil
	end
	local sections = {}
	for _, section in CRAFT_SECTIONS do
		local rows = craftRows(player, section)
		if #rows > 0 then
			table.insert(sections, { key = section.key, label = section.label, items = rows })
		end
	end
	return sections
end

-- Opening the business panel. This is also where a talk ENDS: clearing the
-- current node is what makes a "node:<id>" arriving afterwards a forged jump
-- rather than a late click.
local function sendMenu(player: Player, npc, remark: string?, kind: string?)
	local row = convOf(player, npc.id)
	row.node = nil
	send(player, npc, "menu", kind or "menu", {
		remark = remark or row.said,
		coins = player:GetAttribute(Progression.ATTR.coins) or 0,
		quests = questCards(player, npc),
		shop = shopRows(player, npc),
		craft = craftSections(player, npc),
		farewell = voiceOf(npc, "farewell"),
	})
end

-- ============================================================ the talk

local function sendNode(player: Player, npc, tree, nodeId: string)
	local node = tree.nodes[nodeId]
	if type(node) ~= "table" then
		warn(string.format("[NpcService] %s: node %q is not a table - opening the menu", tostring(npc.id), nodeId))
		sendMenu(player, npc)
		return
	end
	local say = sayLines(node)
	local row = convOf(player, npc.id)
	row.node = nodeId
	row.said = say[#say]
	send(player, npc, "dialogue", "talk", {
		node = nodeId,
		say = say,
		choices = wireChoices(npc, tree, node),
		black = row.black,
	})
end

-- Starting (or replaying) the talk. The first meeting EVER - `met` is
-- persisted, so that is once per player per NPC for the life of the profile -
-- runs the `first` branch behind a black screen; every later one runs `again`
-- over a dimmed world, and the menu's "Talk some more" always replays `again`
-- (allowFirst = false).
local function startTalk(player: Player, npc, allowFirst: boolean)
	local tree = dialogueOf(npc)
	local seen = metOf(player)
	local firstEver = allowFirst and not seen[npc.id]
	if firstEver then
		seen[npc.id] = true
	end
	local row = convOf(player, npc.id)
	row.black = firstEver
	local entry = if firstEver then tree.first else tree.again
	if type(entry) ~= "string" or type(tree.nodes[entry]) ~= "table" then
		-- A row whose `first`/`again` names nothing that exists: fall back to
		-- the generated tree rather than dropping the player into silence.
		warn(
			string.format(
				"[NpcService] %s: dialogue.%s names no node (%s) - using the generated talk",
				tostring(npc.id),
				if firstEver then "first" else "again",
				tostring(entry)
			)
		)
		local gen = generatedDialogue(npc)
		sendNode(player, npc, gen, if firstEver then gen.first else gen.again)
		return
	end
	sendNode(player, npc, tree, entry)
end

-- ============================================================ transactions

-- One purchase: re-derive the slot server-side (the client only ever names an
-- index), refuse before coins move, spend, grant, and answer with a fresh menu
-- carrying the outcome as its remark and its `kind`.
local function buySlot(player: Player, npc, index: number)
	local shop = npc.shop and Shops.items[npc.shop]
	local slot = shop and stockToday(shop)[index]
	if not slot or not DataService.isLoaded(player) then
		sendMenu(player, npc)
		return
	end
	if slot.kind == "item" and InventoryService.ownsItem(player, slot.id) then
		sendMenu(player, npc, voiceOf(npc, "shopOwned"), "refused")
		return
	end
	if not progression().spendCoins(player, slot.price) then
		sendMenu(player, npc, voiceOf(npc, "shopShort"), "refused")
		return
	end
	if slot.kind == "bait" then
		BaitService.grant(player, slot.id, slot.amount)
	elseif slot.kind == "material" then
		MaterialService.grant(player, slot.id, slot.amount)
	elseif slot.kind == "item" then
		InventoryService.grantItem(player, slot.id)
	end
	sendMenu(player, npc, boughtLine(npc), "bought")
end

-- The kind -> data table map the two transactions below look an id up in, built
-- once off the section list so the sub-tabs and the transactions can never
-- disagree about what a "rod" is.
local CRAFT_ITEMS: { [string]: any } = {}
for _, section in CRAFT_SECTIONS do
	CRAFT_ITEMS[section.key] = section.items
end

-- An item's display name for a remark, whichever kind it is. A craft names only
-- an id on the wire, and the answer has to say what was made.
local function craftName(itemId: string): string
	for _, section in CRAFT_SECTIONS do
		local item = section.items[itemId]
		if item then
			return tostring(item.name or itemId)
		end
	end
	return itemId
end

-- ONE CRAFT at this villager's bench. CraftingService owns the whole gate (and
-- fires its own CraftResult, as it always did); the only decision here is which
-- remark the fresh menu wears - the thing they just made, or the server's own
-- reason for saying no.
local function craftAt(player: Player, npc, itemId: string)
	local ok, reason = CraftingService.craft(player, itemId)
	if ok then
		sendMenu(player, npc, string.format("Done. Here's your %s.", craftName(itemId)), "crafted")
	else
		-- A refusal with no reason is the profile still loading (check()'s one
		-- silent case); say something rather than re-drawing in silence.
		sendMenu(player, npc, reason or "Not just now.", "craft_refused")
	end
end

-- Putting something you already own to use, from the same tab. Every kind routes
-- to the service that OWNS the choice - InventoryService re-checks ownership
-- itself (setEquippedOf), BaitService re-checks the id - so a forged
-- "equip:rod:<something you don't have>" is refused there, not here.
local EQUIP_REMARK: { [string]: string } = {
	rod = "You're holding the %s now.",
	weapon = "You're holding the %s now.",
	armor = "You're wearing the %s now.",
	trinket = "You're wearing the %s now.",
	bait = "That's your bait now: %s.",
}

local function equipAt(player: Player, npc, kind: string, itemId: string)
	local items = CRAFT_ITEMS[kind]
	local item = items and items[itemId]
	-- No boat here on purpose: a hull is not equipped, it is summoned, and that
	-- stays the RequestBoat remote BoatService already validates.
	if not (item and EQUIP_REMARK[kind]) then
		return
	end
	local ok = false
	if kind == "rod" then
		ok = InventoryService.setEquippedRod(player, itemId)
		if ok then
			-- The old window fired RequestEquip(kind) straight after, so the thing
			-- lands IN HAND rather than merely being the chosen one.
			InventoryService.setEquipped(player, Equipment.ROD)
		end
	elseif kind == "weapon" then
		ok = InventoryService.setEquippedWeapon(player, itemId)
		if ok then
			InventoryService.setEquipped(player, Equipment.WEAPON)
		end
	elseif kind == "armor" then
		ok = InventoryService.setEquippedArmor(player, itemId)
	elseif kind == "trinket" then
		ok = InventoryService.setEquippedTrinket(player, itemId)
	else
		-- Bait selection is INTENT: BaitService allows any real id even at zero
		-- count, and a cast falls back to no bait until you craft more.
		ok = BaitService.setSelected(player, itemId)
	end
	if ok then
		sendMenu(player, npc, fmt(EQUIP_REMARK[kind], tostring(item.name or itemId)), "equipped")
	else
		sendMenu(player, npc, "You don't have that yet.", "craft_refused")
	end
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

-- THE HANDSHAKE THROTTLE. Every entry point below is client-driven and answers
-- with a pane push: a ProximityPrompt trigger (which an exploiting client can
-- fire as fast as it likes - the prompt is not a trusted input), a ClickDetector
-- click, and NpcChoice. Unthrottled, one player can make the server re-derive a
-- shop's shelves and FireClient a pane thousands of times a second. A
-- quarter-second floor is slower than any human click and invisible to an
-- honest one.
local CHOICE_INTERVAL = 0.25
local lastChoiceAt: { [Player]: number } = {}

local function throttled(player: Player): boolean
	local now = os.clock()
	if now - (lastChoiceAt[player] or -math.huge) < CHOICE_INTERVAL then
		return true
	end
	lastChoiceAt[player] = now
	return false
end

-- Opening a conversation: turn to them (a seated body only leans), wave if
-- they are on their feet, and run the talk. Both the prompt and the
-- ClickDetector land here.
local function greet(player: Player, npc)
	faceToward(npc.id, player)
	if not seated[npc.id] then
		waveAt(npc.id)
	end
	startTalk(player, npc, true)
end

-- Was `nodeId` one of the replies on the node this player is actually standing
-- in? THE transition rule: the client may only ever walk an edge the server
-- just drew for it.
local function transitionAllowed(tree, here: string?, nodeId: string): boolean
	local node = here and tree.nodes[here]
	if type(node) ~= "table" or type(tree.nodes[nodeId]) ~= "table" then
		return false
	end
	local choices = if type(node.choices) == "table" then node.choices else {}
	for _, choice in choices do
		if type(choice) == "table" and choice.next == nodeId then
			return true
		end
	end
	return false
end

local function onChoice(player: Player, npcId, choiceId)
	local npc = type(npcId) == "string" and Npcs.items[npcId]
	if not npc or type(choiceId) ~= "string" then
		return
	end
	if throttled(player) then
		return
	end
	if choiceId == "farewell" or choiceId == "end" then
		-- Every close path lands here: the farewell button, a polite "end"
		-- reply, Escape, and the client's own teardown when the player dies.
		-- Deliberately outside the distance check - walking away IS a close.
		faceHome(npc.id, player)
		local row = convOf(player, npc.id)
		row.node = nil
		row.said = nil
		row.black = false
		return -- the client closes its own window
	end
	if not playerNear(player, npc.id, TALK_RANGE) then
		return
	end
	if choiceId == "menu" then
		sendMenu(player, npc)
		return
	end
	if choiceId == "talk" then
		startTalk(player, npc, false)
		return
	end
	local nodeId = string.match(choiceId, "^node:(.+)$")
	if nodeId then
		local tree = dialogueOf(npc)
		local here = convOf(player, npc.id).node
		if not here then
			-- No talk in progress (the menu is open, or this is a click from a
			-- window the server has already moved on from): there is nothing to
			-- validate the jump against, so answer with the menu rather than
			-- with silence.
			sendMenu(player, npc)
			return
		end
		if transitionAllowed(tree, here, nodeId) then
			sendNode(player, npc, tree, nodeId)
		end
		return
	end
	local buyIndex = string.match(choiceId, "^buy:(%d+)$")
	if buyIndex then
		buySlot(player, npc, tonumber(buyIndex))
		return
	end
	-- The Craft tab's two ids. BEFORE the generic "<word>:<rest>" match below,
	-- which would read "craft" as a quest action; `crafts` is re-checked here so a
	-- forged craft at a villager who keeps no bench does nothing at all.
	local craftId = string.match(choiceId, "^craft:(.+)$")
	if craftId then
		if npc.crafts == true then
			craftAt(player, npc, craftId)
		end
		return
	end
	local equipKind, equipId = string.match(choiceId, "^equip:(%a+):(.+)$")
	if equipKind and equipId then
		if npc.crafts == true then
			equipAt(player, npc, equipKind, equipId)
		end
		return
	end
	local action, questId = string.match(choiceId, "^(%a+):(.+)$")
	if not (action == "accept" or action == "claim") then
		return
	end
	local quest = Quests.items[questId]
	-- Only quests THIS npc gives are actionable here (a forged id for another
	-- giver's quest is ignored). QuestService.accept re-checks the level/prereq
	-- gate itself; this is the giver check.
	local isGivers = false
	for _, id in npc.quests or {} do
		if id == questId then
			isGivers = true
		end
	end
	if not (quest and isGivers) then
		return
	end
	if action == "accept" then
		if QuestService.accept(player, questId) then
			sendMenu(player, npc, questLine(quest, "accept") or voiceOf(npc, "accept"), "quest_accept")
		else
			sendMenu(player, npc)
		end
	else
		-- tryTurnIn answers with a reason CODE, never with text: which of the
		-- giver's OWN lines a refusal gets is this file's decision.
		local ok, reason = QuestService.tryTurnIn(player, questId)
		if ok then
			sendMenu(player, npc, fmt(voiceOf(npc, "done"), quest.name), "quest_done")
		elseif reason == "missingGoods" then
			sendMenu(player, npc, voiceOf(npc, "missingGoods"), "quest_refused")
		else
			sendMenu(player, npc, voiceOf(npc, "notYet"), "quest_refused")
		end
	end
end

-- ============================================================ placement

-- Where the feet are relative to the root: the Humanoid's own HipHeight plus
-- half the root part. A bounding-box guess would bury a hatted NPC to the
-- knees (the hat is part of the box) and float a short one.
local function footDrop(humanoid: Humanoid, root: BasePart): number
	return humanoid.HipHeight + root.Size.Y * 0.5
end

local function npcFolder(): Folder
	local folder = Workspace:FindFirstChild("Npcs")
	if not (folder and folder:IsA("Folder")) then
		folder = Instance.new("Folder")
		folder.Name = "Npcs"
		folder.Parent = Workspace
	end
	return folder
end

-- Is the island this NPC stands on actually in the world? WorldService places
-- each island as a model containing `<entry.model>_Base` (the landform part it
-- anchors on), so the base part's presence is the same question placeIsland
-- asks. The answer goes in the warn: "no ground" means something very different
-- when the island isn't imported (wait for the import) than when it is (the
-- row's spawnOffset is wrong).
local function islandIsPlaced(entry): boolean
	local world = Workspace:FindFirstChild(World.FOLDER_NAME)
	if not world or type(entry.model) ~= "string" then
		return false
	end
	return world:FindFirstChild(entry.model .. "_Base", true) ~= nil
end

-- Returns (placed, reason). `reason == "noground"` is the ONE retryable
-- failure: the island's collision geometry isn't there yet. Every other reason
-- is permanent for this boot and has already been warned about.
local function placeNpc(npc): (boolean, string?)
	local entry = Islands.items[npc.island]
	if not entry then
		-- tostring, not %q: %q on a nil id throws, and a warn that kills the
		-- boot loop is worse than the row it was reporting.
		warn(
			string.format(
				"[NpcService] %s: names unknown island %q - no such row in Islands.items",
				tostring(npc.id),
				tostring(npc.island)
			)
		)
		return false, "island"
	end
	-- Every island row carries a `spawn` today; reading one that does not would
	-- throw inside NpcService.start, and boot is fail-fast (one nil index here
	-- and the whole server is third-person camera and an empty world).
	local spawn = entry.spawn
	if typeof(spawn) ~= "Vector3" then
		warn(
			string.format(
				"[NpcService] %s: island %q has no spawn point (Islands.items.%s.spawn)",
				tostring(npc.id),
				tostring(npc.island),
				tostring(npc.island)
			)
		)
		return false, "spawn"
	end
	local offset = if typeof(npc.spawnOffset) == "Vector3" then npc.spawnOffset else Vector3.new(0, 0, 0)
	local x = spawn.X + offset.X
	local z = spawn.Z + offset.Z
	-- Start the column ABOVE the island, not at a flat 120: a ray that starts
	-- inside a landform never reports that landform's upward faces, so an
	-- island whose stand point sits high (Rookery's stack is at Y=34 today, and
	-- the volcano rim is ~200) would probe from inside its own rock and find
	-- nothing. The spawn's own Y is the only altitude hint the row carries.
	local groundY, groundName = probeGroundY(x, z, math.max(120, spawn.Y + 80))
	if not groundY then
		local why = if islandIsPlaced(entry)
			then "the island IS placed, so the row's spawnOffset points off its collision geometry"
			else string.format(
				"island model %q is not in Workspace/%s yet - import it",
				tostring(entry.model),
				World.FOLDER_NAME
			)
		warn(
			string.format(
				"[NpcService] %s (%s): no ground at (%.1f, %.1f) [%s] - %s",
				tostring(npc.id),
				tostring(npc.island),
				x,
				z,
				tostring(groundName),
				why
			)
		)
		return false, "noground"
	end

	local model, humanoid = buildBody(npc)
	if not (model and humanoid) then
		warn(
			string.format(
				"[NpcService] %s (%s): no rig - neither the avatar description nor the block rig produced a Humanoid",
				tostring(npc.id),
				tostring(npc.island)
			)
		)
		return false, "norig"
	end
	local root = model.PrimaryPart
	if not root then
		-- buildBody sets PrimaryPart itself, so this is unreachable unless it
		-- changes; it warns rather than returning quietly so the next person
		-- sees the contract break instead of an empty island.
		warn(
			string.format(
				"[NpcService] %s (%s): rig has no PrimaryPart (buildBody should have set it)",
				tostring(npc.id),
				tostring(npc.island)
			)
		)
		model:Destroy()
		return false, "noroot"
	end

	local yaw = CFrame.Angles(0, math.rad(npc.facing or 0), 0)
	local pose = poseOf(npc)
	-- The seat scales with the body: HipHeight is 2 on a default R15 (and on
	-- the block rig, which sets it to the real 2 for exactly this reason), so
	-- the ratio is the rig's own size hint. Clamped, because `look.height` is
	-- clamped and a stool the size of a table is worse than a slightly low one.
	local seatTop = SEAT_TOP_OVER_FLOOR * math.clamp(humanoid.HipHeight / 2, 0.8, 1.3)
	-- FLOOR -> ROOT, in both poses, which is what the probe check below
	-- subtracts back off. Standing: HipHeight plus half the root. Sitting: the
	-- root's bottom face rests on the seat's top face (see SEAT_TOP_OVER_FLOOR).
	local drop = if pose.kind == "sit" then seatTop + root.Size.Y * 0.5 else footDrop(humanoid, root)
	model:PivotTo(CFrame.new(x, groundY + drop, z) * yaw)

	-- Verify against the ground UNDER the rig once it's standing, with the SAME
	-- walkable-surface probe (not a bare first hit - re-probing with the old
	-- rule was the second half of the roof bug: it confirmed the roof). Starting
	-- from just above the feet instead of y=120 also clips any cover out of the
	-- column, so the two answers agree on a porch. NPC parts are CanQuery=false,
	-- so this ray sees the world, not the body.
	local check, checkName = probeGroundY(x, z, root.Position.Y + 8)
	if check and math.abs((root.Position.Y - drop) - check) > 0.25 then
		model:PivotTo(CFrame.new(x, check + drop, z) * yaw)
		-- The second answer is the one the body is standing on, so it is the one
		-- the placement line should name.
		groundName = checkName or groundName
	end
	homeCFrame[npc.id] = root.CFrame

	-- The seat goes in AFTER the body is posed (nothing moves it again) and at
	-- the FLOOR under the rig, which is root.Y minus the same `drop`.
	if pose.kind == "sit" then
		seated[npc.id] = true
		buildSeat(model, pose.seat, pose.seatColor, CFrame.new(x, root.Position.Y - drop, z) * yaw, seatTop)
	end

	-- The plate hangs off the ROOT, so it needs the head's height above the
	-- root, not the rig's overall size.
	local head = model:FindFirstChild("Head")
	local plateAt = if head and head:IsA("BasePart")
		then (head.Position.Y - root.Position.Y) + head.Size.Y * 0.5
		else drop
	addNameplate(npc, model, plateAt)

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "TalkPrompt"
	prompt.ActionText = "Talk"
	prompt.ObjectText = tostring(npc.name or npc.id)
	prompt.MaxActivationDistance = PROMPT_RANGE
	prompt.HoldDuration = 0
	prompt.RequiresLineOfSight = false
	prompt.Style = Enum.ProximityPromptStyle.Default
	prompt.Triggered:Connect(function(player)
		if not throttled(player) and playerNear(player, npc.id, PROMPT_RANGE + 6) then
			greet(player, npc)
		end
	end)
	prompt.Parent = root

	-- Click as well as E: on a laptop trackpad (and for anyone who never sees
	-- the prompt because they're looking past it) the body itself is the
	-- affordance. Same greeting, same distance rule.
	-- The detector lives on the MODEL (it answers for every descendant part),
	-- and the mouse ray reaches the queryable root through the non-query limbs
	-- - see buildBody, where the root is the one part left CanQuery=true.
	local click = Instance.new("ClickDetector")
	click.Name = "TalkClick"
	click.MaxActivationDistance = PROMPT_RANGE
	click.MouseClick:Connect(function(player)
		if not throttled(player) and playerNear(player, npc.id, PROMPT_RANGE + 6) then
			greet(player, npc)
		end
	end)
	click.Parent = model

	model.Parent = npcFolder()
	placed[npc.id] = model
	-- After parenting: an animation loaded on a model outside Workspace plays
	-- nowhere, and a state pushed onto a Humanoid outside Workspace does not
	-- stick (the state machine starts over when the rig enters the world).
	-- Both are cosmetic and both are pcall'd: the villager is already standing
	-- there, and a missing idle clip must not report as a missing NPC.
	local animOk, animErr = pcall(setupAnimation, npc, model, humanoid, pose.kind == "sit")
	if not animOk then
		warn(string.format("[NpcService] %s: animation setup failed: %s", tostring(npc.id), tostring(animErr)))
	end
	pcall(function()
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	end)

	-- THE SELF-CHECK LINE. One per placed NPC, always printed: where the body
	-- ended up and what it is standing on. It is the difference between "the
	-- NPCs are missing" and "the NPCs are on the roof" - and it prints from the
	-- server, so it is in Studio's Output next to the [Boot] lines.
	local at = root.Position
	print(string.format(
		"[NpcService] %s %s at (%.1f, %.1f, %.1f) on %s",
		tostring(npc.id),
		-- `drop` (not footDrop) is the floor-to-root distance for the pose
		-- this body is actually in: a seated one sits lower, and a line that
		-- reported its floor half a stud under the real one would send the
		-- next person hunting a placement bug that isn't there.
		if pose.kind == "sit" then "sitting" else "standing",
		at.X,
		at.Y - drop,
		at.Z,
		tostring(groundName)
	))
	return true
end

-- ============================================================ lifecycle

function NpcService.init()
	-- The "npcs" slice: who this player has already met, and nothing else. The
	-- release handler is where every per-player table is wiped - DataService
	-- calls it strictly AFTER the final serialize, and registered services must
	-- not connect their own PlayerRemoving wipe (doing so here would have saved
	-- an empty `met` over a profile that had met everyone).
	DataService.register("npcs", {
		load = loadMet,
		serialize = serializeMet,
		release = function(player: Player)
			met[player] = nil
			conv[player] = nil
			lastChoiceAt[player] = nil
		end,
	})
	Remotes.NpcChoice.OnServerEvent:Connect(onChoice)
end

-- ONE NPC, FULLY ISOLATED. Every row gets its own thread and its own xpcall,
-- for two independent reasons:
--
--  * `NpcService.start` runs inside the boot loop's pcall, and the boot loop is
--    FAIL-FAST: anything that throws out of here prints
--    "[Boot] NpcService.start failed" and the server comes up with no NPCs at
--    all. It has done exactly that (a misspelled Humanoid property, see
--    buildBody) - fourteen villagers missing because of one bad line in one of
--    them. One rig failing may now cost one villager, never fourteen.
--  * `Players:CreateHumanoidModelFromDescription` YIELDS. Calling it inline
--    held the whole boot loop - every service after us, and the "[Boot] N
--    service(s) online." line - for as long as the avatar endpoint took.
--
-- Returns the reason string (nil on success) so the caller can tally.
local function placeGuarded(npc): string?
	local ok, result, reason = xpcall(placeNpc, function(err)
		return debug.traceback(tostring(err), 2)
	end, npc)
	if not ok then
		warn(
			string.format(
				"[NpcService] %s (%s): placement THREW - %s",
				tostring(npc.id),
				tostring(npc.island),
				tostring(result)
			)
		)
		return "error"
	end
	if result then
		return nil
	end
	return reason or "unknown"
end

-- The NPCs that failed only because their island had no collision geometry get
-- a second chance for RETRY_WINDOW seconds: WorldService places every island in
-- its own init (before us), but a future async import - or a hand-placed island
-- dropped into Workspace/World in Studio - arrives later, and the old code's
-- answer to that was a silent nothing until the next server boot. Each new
-- child of the World folder re-arms one debounced sweep.
local RETRY_WINDOW = 60
local RETRY_DEBOUNCE = 0.5

local function retryPending(pending: { [string]: any }, pendingCount: number)
	local deadline = os.clock() + RETRY_WINDOW
	local armed = false
	local connections: { RBXScriptConnection } = {}
	local function watchWorld(world: Instance)
		table.insert(
			connections,
			world.ChildAdded:Connect(function()
				armed = true
			end)
		)
	end
	local world = Workspace:FindFirstChild(World.FOLDER_NAME)
	if world then
		watchWorld(world)
	end
	table.insert(
		connections,
		Workspace.ChildAdded:Connect(function(child)
			if child.Name == World.FOLDER_NAME then
				watchWorld(child)
				armed = true
			end
		end)
	)

	while pendingCount > 0 and os.clock() < deadline do
		task.wait(RETRY_DEBOUNCE)
		if armed then
			armed = false
			-- Removing the current key during generalized iteration is allowed;
			-- nothing is ever ADDED to `pending` here.
			for id, npc in pending do
				if placeGuarded(npc) == nil then
					pending[id] = nil
					pendingCount -= 1
					print(string.format("[NpcService] %s placed on retry (its island arrived late).", id))
				end
			end
		end
	end
	for _, connection in connections do
		connection:Disconnect()
	end
	if pendingCount > 0 then
		local missing = {}
		for id in pending do
			table.insert(missing, id)
		end
		table.sort(missing)
		warn(
			string.format(
				"[NpcService] gave up after %ds on %d NPC(s) with no ground: %s."
					.. " Their islands are not placed - check docs/import-checklist.md.",
				RETRY_WINDOW,
				pendingCount,
				table.concat(missing, ", ")
			)
		)
	end
end

local function placeAll()
	local total = 0
	for _ in Npcs.items do
		total += 1
	end
	local finished, count = 0, 0
	local pending: { [string]: any } = {}
	local pendingCount = 0
	local missing: { string } = {}

	for _, npc in Npcs.items do
		task.spawn(function()
			local reason = placeGuarded(npc)
			if reason == nil then
				count += 1
			else
				local id = tostring(npc.id)
				table.insert(missing, string.format("%s (%s)", id, reason))
				if reason == "noground" and type(npc.id) == "string" then
					pending[npc.id] = npc
					pendingCount += 1
				end
			end
			finished += 1
		end)
	end

	-- The summary waits for every thread (each of which may have yielded inside
	-- the avatar build) and then prints ONCE, whatever happened.
	task.spawn(function()
		-- With a DEADLINE: the avatar build is a web call, and a thread parked
		-- in one forever must not be the reason the summary never appears. A
		-- straggler that finishes later still gets its own placement line.
		local deadline = os.clock() + 30
		while finished < total and os.clock() < deadline do
			task.wait(0.1)
		end
		if finished < total then
			warn(
				string.format(
					"[NpcService] %d of %d placement threads are still running after 30s"
						.. " (CreateHumanoidModelFromDescription yields); the count below is a snapshot.",
					total - finished,
					total
				)
			)
		end
		table.sort(missing)
		print(
			string.format(
				"[NpcService] placed %d of %d NPCs%s",
				count,
				total,
				if #missing == 0 then "" else " - missing: " .. table.concat(missing, ", ")
			)
		)
		if pendingCount > 0 then
			retryPending(pending, pendingCount)
		end
	end)
end

function NpcService.start()
	placeAll()
	-- Bodies only: every per-player TABLE is cleared in the DataService release
	-- handler above (this signal fires before the final serialize).
	Players.PlayerRemoving:Connect(function(player)
		for npcId, who in facingWho do
			if who == player then
				facingWho[npcId] = nil
				local home = homeCFrame[npcId]
				if home then
					turnRoot(npcId, home, UNFACE_TIME)
				end
			end
		end
	end)
end

return NpcService
