--!nonstrict
-- WrackBodyController.luau
-- Draws Admiral Wrack, the Fleet-Eater: his flagship hove down on her
-- starboard bilge at 48 degrees with the drowned admiral still standing on
-- her stern.
--
-- THIS IS THE SIMPLEST OF THE SEVEN BODY CONTROLLERS, and deliberately so.
-- Its six siblings all drive a RIG - a chain walked by arc length
-- (Brinejaw, Rimefang, the Kraken's arms, Noctyss's stalks) or a jointed
-- limb set posed from a path module (Gnashroot, Pyrelisk) - because those
-- bosses move. Wrack does not. `Bosses.items.admiral_wrack` carries
-- `speed = 0`: he is a planted gun platform and his fight is a bullet hell
-- that happens in FRONT of him, not a body that swings.
--
-- So there is no path module, no pose attributes and no per-frame limb maths
-- here, and none should be added. All 25 objects in assets/boss_wrack.glb are
-- authored in ONE shared space at their final positions (boss_gen.py's
-- build_wrack: "STATIC. One CFrame for the whole model - he never moves,
-- never turns"), so the entire ship places with a single CFrame and a
-- per-piece offset that is measured once at clone time and never recomputed.
--
-- WHAT IS STILL PER-FRAME, and why this is not a one-shot placement:
--
--   * he rises out of the shoal on spawn (`riseDepth = 22`, `riseTime = 4.2`),
--     and the prowl loop breathes him on a small hop and a +-3 degree sway.
--     Both move the server model's pivot, and the assembly rides it for free.
--     He does NOT slew: `turnRate` is 0, because his four gun decks are
--     authored at four bearings and a hull that turns to face you presents the
--     same two forever;
--   * the hull SPLITS for the melee window - two plates off the keel hinge,
--     eased on one scalar. See "the melee window" below. That scalar is the
--     only thing in this file that is interpolated, and it should stay the
--     only one: it is a door opening, not a body being animated.
--
-- Pieces come from ReplicatedStorage/Assets/WrackPack (assets/boss_wrack.glb,
-- see docs/import-checklist.md row 7p). Until that import lands this draws
-- correctly-placed, correctly-sized stand-ins rather than nothing, exactly
-- like every sibling, so the fight is always debuggable.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local WrackBodyController = {}

local CREATURES_FOLDER = "Creatures"
local PACK_NAME = "WrackPack"
local PREFIX = "Wrack_"
local FOLDER_NAME = "WrackBody"

-- HOW THIS CONTROLLER FINDS ITS BOSS, and why it is not `Pose`.
--
-- The other six adopt on `model:GetAttribute("Pose")`, which CreatureService
-- writes only for a boss whose Bosses row carries `pose = "<kind>"` (or, for
-- Rimefang, from its own driver). Admiral Wrack carries NO `pose` on
-- purpose, and giving him one would break his fight rather than help it:
-- `wrackScale`'s own note in CreatureService says the patterns' latched
-- firing bearings come from `bossFacing` -> `creature.yaw0`, and yaw0 is
-- written by updateBoss's PROWL branch, "which a `pose`d boss returns before
-- ever reaching". A posed Wrack would aim every volley off a dead bearing.
--
-- So he is adopted on `CreatureId` instead - CreatureService's ATTR_ID, set
-- on every creature model there is. KrakenBodyController already keys its
-- tentacles off the same attribute, and BossHudController finds every boss
-- with it. No server change is needed for this controller to work.
local CREATURE_ID = "admiral_wrack"

-- The authored centre of `Wrack_Base` in boss space, measured off the glb.
-- boss_gen's HANDOFF names Base the anchor - "its centre is the boss origin
-- at sand level (z=0 = the shoal)" - and BossArenaService.placeAuthored
-- anchors every authored ARENA mesh on the same `<model>_Base` convention,
-- so this controller follows it for the boss mesh.
--
-- It is used ONLY to place the stand-ins: the clone path measures each
-- piece's offset from the real `Wrack_Base` it finds in the pack, so a
-- re-export that shifts the ship cannot desync the imported body. This
-- constant only has to keep the stand-in agreeing with the clone.
local AUTHORED_ANCHOR = Vector3.new(2.8, 1.2, 0.6)

-- Every piece the assembly draws, in build order.
--
-- `Wrack_MuzzleGlow` is the 25th object and is deliberately NOT here. It is
-- a MODULE, not a piece: boss_gen authors it at the origin with +X as the
-- bore and instances it once per live muzzle, so it has no single home to be
-- placed at. The import checklist calls it "decoration only, and nothing
-- breaks if it is never placed". Whoever draws muzzle flash owns it, and
-- routing it through makePiece() below is all it needs to come out Neon.
local PIECES = {
	"Base",
	"Hull",
	"Strakes",
	"Keel",
	"Crust",
	"Ribs",
	"ShellUpper",
	"ShellLower",
	"HeartGlow",
	"HeartCage",
	"BatteryDeck",
	"BatteryKeel",
	"BatteryStern",
	"BatteryTop",
	"Mast",
	"Rigging",
	"Sail",
	"Coat",
	"Arm",
	"Sabre",
	"Facings",
	"Skull",
	"EyeGlow",
	"Hat",
}

-- Stand-in geometry, used only until the pack is imported: every piece's
-- authored bounding box and its WR_* palette colour, read straight out of
-- assets/boss_wrack.glb and assets/boss_gen.py. Blocks rather than shapes,
-- but at the authored size AND the authored place, so an un-imported fight
-- shows a careened ship of the right bulk in the right spot (87 studs bow to
-- stern, 72 to the masthead) instead of a grey box.
local AUTHORED = {
	Base = { at = Vector3.new(2.8, 1.2, 0.6), size = Vector3.new(87.1, 4.5, 47), color = Color3.fromRGB(62, 59, 53) },
	Hull = { at = Vector3.new(-0.5, 16.8, 0.1), size = Vector3.new(67, 44.2, 44.8), color = Color3.fromRGB(30, 35, 41) },
	Strakes = {
		at = Vector3.new(-0.5, 24.8, -1.2),
		size = Vector3.new(66.2, 39.1, 46.7),
		color = Color3.fromRGB(59, 67, 74),
	},
	Keel = {
		at = Vector3.new(-0.5, 11.1, 5.9),
		size = Vector3.new(71.8, 31.8, 33.4),
		color = Color3.fromRGB(25, 29, 34),
	},
	Crust = {
		at = Vector3.new(-0.3, 18.9, 12.1),
		size = Vector3.new(63.1, 28.9, 22.3),
		color = Color3.fromRGB(97, 104, 90),
	},
	Ribs = {
		at = Vector3.new(4, 14.7, 2.7),
		size = Vector3.new(24.8, 37.3, 37),
		color = Color3.fromRGB(218, 212, 189),
	},
	ShellUpper = { at = Vector3.new(4, 21.3, 6.8), size = Vector3.new(20, 30, 30), color = Color3.fromRGB(30, 35, 41) },
	ShellLower = {
		at = Vector3.new(4, 9.8, 0.3),
		size = Vector3.new(20, 29.4, 38.9),
		color = Color3.fromRGB(30, 35, 41),
	},
	HeartGlow = {
		at = Vector3.new(3, 14.8, 3.1),
		size = Vector3.new(4.8, 7.1, 5),
		color = Color3.fromRGB(255, 199, 107),
	},
	HeartCage = {
		at = Vector3.new(3, 16.7, -0.1),
		size = Vector3.new(8.4, 11.8, 11.6),
		color = Color3.fromRGB(186, 132, 53),
	},
	BatteryDeck = {
		at = Vector3.new(-19.5, 33.7, -8.7),
		size = Vector3.new(22.2, 15, 16.3),
		color = Color3.fromRGB(186, 132, 53),
	},
	BatteryKeel = {
		at = Vector3.new(20.2, 10.1, 17.9),
		size = Vector3.new(17.2, 13, 12.9),
		color = Color3.fromRGB(186, 132, 53),
	},
	BatteryStern = {
		at = Vector3.new(-33.7, 29.2, -14.8),
		size = Vector3.new(10.4, 18.8, 16.5),
		color = Color3.fromRGB(186, 132, 53),
	},
	BatteryTop = {
		at = Vector3.new(37.2, 27.8, -12),
		size = Vector3.new(8.6, 7.9, 8.4),
		color = Color3.fromRGB(186, 132, 53),
	},
	Mast = {
		at = Vector3.new(16.3, 24.9, -7.3),
		size = Vector3.new(56.8, 48, 49.5),
		color = Color3.fromRGB(96, 92, 85),
	},
	Rigging = {
		at = Vector3.new(4.8, 26.6, -8),
		size = Vector3.new(75.8, 43.7, 43.3),
		color = Color3.fromRGB(79, 73, 61),
	},
	Sail = {
		at = Vector3.new(-9, 22.8, -16.5),
		size = Vector3.new(4.4, 47.9, 21.8),
		color = Color3.fromRGB(150, 156, 163),
	},
	Coat = {
		at = Vector3.new(-23.8, 39.8, -10.4),
		size = Vector3.new(12, 27.6, 17),
		color = Color3.fromRGB(30, 37, 62),
	},
	Arm = {
		at = Vector3.new(-23.6, 49.4, -8.9),
		size = Vector3.new(9.2, 23.4, 18.9),
		color = Color3.fromRGB(30, 37, 62),
	},
	Sabre = {
		at = Vector3.new(-19.6, 65.2, -14.5),
		size = Vector3.new(4.5, 13.7, 4.5),
		color = Color3.fromRGB(189, 196, 201),
	},
	Facings = {
		at = Vector3.new(-24, 49.8, -8.3),
		size = Vector3.new(10.1, 24.5, 17.9),
		color = Color3.fromRGB(201, 177, 102),
	},
	Skull = {
		at = Vector3.new(-25.1, 55.2, -7.3),
		size = Vector3.new(7.9, 9.2, 6.8),
		color = Color3.fromRGB(218, 212, 189),
	},
	EyeGlow = {
		at = Vector3.new(-23.5, 56.4, -7.3),
		size = Vector3.new(2.1, 1.8, 5),
		color = Color3.fromRGB(255, 204, 92),
	},
	Hat = { at = Vector3.new(-25.8, 59, -7.3), size = Vector3.new(7.5, 4.3, 15.7), color = Color3.fromRGB(22, 22, 27) },
}

-- The pieces that must burn, by the marker boss_gen puts in the OBJECT name
-- (a material name never survives the glTF import - Studio names a MeshPart
-- after its object). Substring, so `Wrack_HeartGlow`, `Wrack_EyeGlow` and
-- `Wrack_MuzzleGlow` all match, and so does anything a re-export adds.
--
-- This mirrors BossArenaService's GLOW_MARKERS exactly, because it is the
-- same contract - but that implementation is honoured for ARENA meshes only,
-- which is the whole reason this line has to exist here. boss_gen's own
-- HANDOFF says so out loud: "the boss path (<Boss>BodyController clones pack
-- parts) has NO Neon-by-name rule, so these three import FLAT unless the
-- Wrack body controller sets Material.Neon on them."
--
-- `Wrack_HeartGlow` is the one that matters. It is the lantern hanging in
-- the hold, and the whole point of the melee punish window is that silencing
-- all four batteries splits the hull and exposes it. Left flat it is a grey
-- lump, and the payoff of the fight's one opening reads as nothing.
local GLOW_MARKER = "Glow"

-- ---------------------------------------------------------- the melee window
--
-- THE HULL OPENS. Silence all four gun decks and the waist splits: the two
-- shell plates swing off the keel and the colossus is visibly broken in half,
-- bow and stern joined only by the keel and a bare ribcage, with the
-- heart-lantern burning in the gap. It reads best from directly above, which
-- is where the fight camera sits.
--
-- THE SIGNAL. `Exposed` - CreatureService's ATTR_EXPOSED - written on the
-- parts-down path since 7258b4c. It is LEVEL-triggered, and that is the whole
-- reason this is drawable: it is a state to read, not an edge to catch. The
-- server sets it in kill() when the last battery falls and clears it in
-- spawnBossParts when the ring regrows, so "is the hull open" is answerable at
-- any instant by anyone who can see the model.
--
-- It is also the same attribute the stagger and maw paths write, so this is
-- one rule for every way a boss opens up rather than a Wrack special case -
-- PyreliskBodyController reads exactly the same attribute for the same reason.
local ATTR_EXPOSED = "Exposed"

-- THE HINGE, in boss space: both plates turn about boss-local X through here.
--
-- boss_gen prints this as `_wr_at(0, 0, 0)` - the ship-space origin, which is
-- the keel rabbet - and its HANDOFF states it in BLENDER space as
-- (0, -15.5, 3.2), being WR_SHIP_Y / WR_SHIP_Z. The export maps Blender
-- (x, y, z) -> Roblox (x, z, -y), so in the space this controller works in it
-- is (0, 3.2, 15.5). Taken from the handoff verbatim it would hinge about a
-- point fifteen studs underground.
--
-- Stated in boss space (origin = the boss origin at sand level) and converted
-- to assembly-local at use, because `relative` is measured from Wrack_Base.
local HINGE = Vector3.new(0, 3.2, 15.5)

-- How far each plate swings at full open, from boss_gen's WR_OPEN_UPPER_DEG /
-- WR_OPEN_LOWER_DEG. Opposite signs about the same axis is what makes it a
-- ribcage splitting rather than a lid lifting.
--
-- The signs are the authored ones and they are load-bearing: swung the other
-- way the lower plate closes ON the heart-lantern (its centre moves from 5.8
-- studs away to 4.6) instead of clearing it, so the punish window would seal
-- the very thing it exists to expose. As authored, the plates separate from
-- 13.2 studs apart to 35.1, and both retreat from the heart (to 26.6 and
-- 15.4) - the lantern is revealed by the geometry moving off it, which is why
-- nothing here touches its transparency or its material.
local SHELL_SWING = {
	ShellUpper = math.rad(70),
	ShellLower = math.rad(-35),
}

-- How fast the swing eases. Deliberately slow: this is thirty studs of hull
-- plate, and PyreliskBodyController's note applies with more force here -
-- something this big that snaps between states reads as a cut, not a swing.
-- At this rate the hull is ~95% open in 1.2s, comfortably inside the 4.0s of
-- true silence `staggerFor` buys, so the plates finish moving while the guns
-- are still quiet and the opening is legible before the burst window starts.
local OPEN_RATE = 2.6

local warnedMissingPack = false

-- ---------------------------------------------------------------- pieces

local function packPiece(name: string): BasePart?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local pack = assets and assets:FindFirstChild(PACK_NAME)
	local piece = pack and pack:FindFirstChild(PREFIX .. name, true)
	return if piece and piece:IsA("BasePart") then piece else nil
end

-- One drawable piece: the authored mesh if it is imported, else a block of
-- its authored bulk so the ship still reads.
local function makePiece(name: string, parent: Instance): BasePart
	local template = packPiece(name)
	local part
	if template then
		part = template:Clone()
	else
		if not warnedMissingPack then
			warnedMissingPack = true
			warn("[WrackBody] " .. PACK_NAME .. " not imported - drawing stand-ins")
		end
		local authored = AUTHORED[name]
		part = Instance.new("Part")
		part.Size = if authored then authored.size else Vector3.new(10, 10, 10)
		part.Color = if authored then authored.color else Color3.fromRGB(30, 35, 41)
		part.Material = Enum.Material.SmoothPlastic
	end
	-- AFTER the branch, never inside it. A clone keeps whatever the importer
	-- gave it and a stand-in has just been set to SmoothPlastic, so this is
	-- the only place that reaches both - and the cloned mesh is the case that
	-- actually matters. Put in the else branch it would light the stand-in
	-- and leave the real heart-lantern flat, which is the exact failure it
	-- exists to prevent and the one that reads as correct in review.
	if string.find(name, GLOW_MARKER, 1, true) then
		part.Material = Enum.Material.Neon
	end
	part.Name = PREFIX .. name
	part.Anchored = true
	-- The footing and the hitboxes are the SERVER's, never ours: his hit
	-- volume is `hitRadius` math and the four battery creatures, and nothing
	-- about him is walked on (there is no climb route like Pyrelisk's
	-- _WalkArm - you fight him from the Careenage's sand).
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.Parent = parent
	return part
end

-- Where the assembly's own origin sits inside the pack, so a piece's offset
-- can be measured from it. Falls back to the authored constant when the pack
-- is missing, which is what keeps the stand-in path and the clone path
-- placing the ship in the same spot.
local function packAnchor(): CFrame
	local base = packPiece("Base")
	return CFrame.new(if base then base.Position else AUTHORED_ANCHOR)
end

-- ---------------------------------------------------------------- lifecycle

local bodies: { [Model]: any } = {}

local function destroyBody(model: Model)
	local entry = bodies[model]
	if not entry then
		return
	end
	bodies[model] = nil
	if entry.folder then
		entry.folder:Destroy()
	end
end

-- The visible boss is ours, so the server's model has to stop showing - or
-- there are two Wracks standing in the same sand.
--
-- Every sibling gets this for free from the server: CreatureService's
-- hideColossusModel does it, and every call site is gated on the Bosses row
-- carrying `pose` (Rimefang's driver does the same thing inline). Wrack has
-- no `pose` and must not be given one - see CREATURE_ID above - and there is
-- no Wrack driver in CreatureService, so nothing server-side will ever hide
-- him and the client that draws the replacement is the only place left that
-- can. Doing it here is local to this player, costs the fight nothing, and
-- goes quietly idempotent the day a server-side hide does land.
--
-- Transparency only, exactly like hideColossusModel: the parts stay, because
-- hits and BossHudController read them, and CanCollide is never touched.
local function hideServerModel(model: Model)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Transparency = 1
			descendant.CastShadow = false
		elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
			descendant.Transparency = 1
		end
	end
end

local function adoptBoss(model: Model)
	if bodies[model] or model:GetAttribute("CreatureId") ~= CREATURE_ID then
		return
	end

	-- WHERE SAND LEVEL IS, measured once. The ship is authored with y = 0 at
	-- the shoal's surface, but a creature's pivot is its CENTRE: spawn()
	-- hands an `upright` row `uprightOrientation`, whose halfThickness is
	-- exactly pivot-to-box-bottom, and groundedPos then stands the model at
	-- surface + halfThickness. So the server model's bounding-box bottom IS
	-- the sand, and this drop is the same number read back off the geometry.
	--
	-- Measured once rather than per frame because it is a property of the
	-- model's shape, not of where the fight has moved it - which is what lets
	-- the assembly ride the rise and the deck slew for free.
	local pivot = model:GetPivot()
	local boxCFrame, boxSize = model:GetBoundingBox()
	local groundDrop = (boxCFrame.Position.Y - boxSize.Y / 2) - pivot.Position.Y

	hideServerModel(model)

	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = Workspace

	-- One measurement of the authored layout, taken from the pack itself, so
	-- the 24 pieces keep the exact relationship they were built with. The
	-- whole ship then moves as one CFrame forever after.
	local anchor = packAnchor()
	local pieces = {}
	for index, name in PIECES do
		local part = makePiece(name, folder)
		local authored = AUTHORED[name]
		local relative
		if packPiece(name) then
			relative = anchor:Inverse() * part.CFrame
		else
			relative = CFrame.new((if authored then authored.at else Vector3.zero) - AUTHORED_ANCHOR)
		end
		-- A shell plate carries the angle it reaches at full open; every other
		-- piece carries nil and is placed straight off `relative`.
		pieces[index] = { part = part, relative = relative, swing = SHELL_SWING[name] }
	end

	bodies[model] = {
		folder = folder,
		pieces = pieces,
		groundDrop = groundDrop,
		-- ADOPTED AT THE STATE THE FIGHT IS ALREADY IN, not at closed.
		--
		-- This is the case the level-triggered attribute exists for. A player
		-- who joins mid-window - or whose controller adopts the boss a frame
		-- after the last battery fell, or who walks into streaming range with
		-- the hull already split - has no edge to have missed, so the window
		-- is read here and the plates START there rather than easing open from
		-- shut. Easing in on adopt would animate an event that happened before
		-- this client was watching, which is the same lie as missing it.
		open = if model:GetAttribute(ATTR_EXPOSED) then 1 else 0,
		-- Local, so a plate can never be left mid-swing by a dropped update:
		-- the attribute is the truth and this only ever chases it.
		hinge = CFrame.new(HINGE - AUTHORED_ANCHOR),
	}
end

-- ---------------------------------------------------------------- the draw

-- The entire per-frame cost of this boss: one CFrame for the ship, and one
-- number for how far the hull has split. The pivot says where the hull is and
-- which way the guns point, and every piece is a fixed offset from it.
--
-- No yaw correction is applied and none is needed. The engine's creature
-- convention puts a body's +X along its heading (yawToward swings "the
-- flat-laid long axis (+X)" onto the bearing), and boss_gen authors Wrack
-- "facing +X (bow at +X, stern at -X)". The two already agree.
local function drawBody(model: Model, entry, dt: number)
	local pivot = model:GetPivot()
	local base = CFrame.new(pivot.Position + Vector3.new(0, entry.groundDrop, 0)) * pivot.Rotation

	-- Chase the window. Reading the attribute every frame rather than binding
	-- a changed-signal is what makes the close as reliable as the open: the
	-- hull follows whatever the server currently says, so a missed signal
	-- costs a few frames of easing and never a plate stuck open.
	local goal = if model:GetAttribute(ATTR_EXPOSED) then 1 else 0
	entry.open += (goal - entry.open) * math.clamp(OPEN_RATE * dt, 0, 1)

	for _, piece in entry.pieces do
		local relative = piece.relative
		if piece.swing then
			-- Turn about boss-local X through the keel hinge, then place as
			-- usual. Written out rather than folded into `relative` because
			-- the angle changes every frame while `relative` never does.
			relative = entry.hinge * CFrame.Angles(piece.swing * entry.open, 0, 0) * entry.hinge:Inverse() * relative
		end
		piece.part.CFrame = base * relative
	end
end

-- ---------------------------------------------------------------- watching

local function watch(child: Instance)
	if not child:IsA("Model") then
		return
	end
	adoptBoss(child)
	-- CreatureService stamps CreatureId as the model is built, so it is
	-- normally already there; this covers a model that replicates to us a
	-- frame before its attributes do.
	child:GetAttributeChangedSignal("CreatureId"):Connect(function()
		adoptBoss(child)
	end)
	child.AncestryChanged:Connect(function()
		if not child:IsDescendantOf(Workspace) then
			destroyBody(child)
		end
	end)
end

function WrackBodyController.init()
	task.spawn(function()
		local folder = Workspace:WaitForChild(CREATURES_FOLDER, 30)
		if not folder then
			return
		end
		for _, child in folder:GetChildren() do
			watch(child)
		end
		folder.ChildAdded:Connect(watch)
		folder.ChildRemoved:Connect(function(child)
			if child:IsA("Model") then
				destroyBody(child)
			end
		end)
	end)
end

function WrackBodyController.start()
	RunService.RenderStepped:Connect(function(dt)
		for model, entry in bodies do
			if model.Parent then
				drawBody(model, entry, dt)
			else
				destroyBody(model)
			end
		end
	end)
end

return WrackBodyController
