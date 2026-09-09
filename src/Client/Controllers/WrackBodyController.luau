--!nonstrict
-- WrackBodyController.luau
-- Draws Admiral Wrack, the Fleet-Eater: his flagship standing upright and
-- keel-bedded in the shoal, with the drowned admiral on her quarterdeck.
--
-- REDESIGNED 2026-09-08, from the player, and all three notes land in this
-- file as constants: the 48-degree careen is gone (she stands up), the ship
-- is a little over half its old bulk (48 studs bow to stern and 34.4 to the
-- sabre tip, against 87 and 72), and the four floating "batteries" are now
-- four actual cannons built into the hull - `Wrack_CannonBow`,
-- `Wrack_CannonStarboard`, `Wrack_CannonStern`, `Wrack_CannonPort`. The old
-- `Wrack_Battery*` names are GONE from the mesh; anything still addressing
-- them draws nothing.
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

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MeshColors = require(Shared.Config.MeshColors)

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
local AUTHORED_ANCHOR = Vector3.new(-0.1, 0.7, 0.3)

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
	"CannonBow",
	"CannonStarboard",
	"CannonStern",
	"CannonPort",
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
-- shows an upright ship of the right bulk in the right spot (48 studs bow to
-- stern, 26.5 to the masthead, 34.4 to the sabre tip) instead of a grey box.
--
-- REGENERATED, never typed: these are the glb's own per-object bounding
-- boxes, and the export is already in Roblox space (Blender x,y,z -> x,z,-y),
-- so a row here is `at` = bbox centre and `size` = bbox extent, verbatim. The
-- redesign moved every one of them; hand-editing a subset is how a stand-in
-- ship ends up half in the old careen and half in the new one.
local AUTHORED = {
	Base = { at = Vector3.new(-0.1, 0.7, 0.3), size = Vector3.new(53.5, 2.8, 26.8), color = Color3.fromRGB(62, 59, 53) },
	Hull = { at = Vector3.new(-0.5, 7.8, 0.3), size = Vector3.new(41, 13.5, 14.5), color = Color3.fromRGB(30, 35, 41) },
	Strakes = {
		at = Vector3.new(-0.5, 8.2, 0),
		size = Vector3.new(40.3, 14.5, 13.8),
		color = Color3.fromRGB(59, 67, 74),
	},
	Keel = { at = Vector3.new(-0.4, 6.4, 0), size = Vector3.new(45.3, 13.1, 10.3), color = Color3.fromRGB(25, 29, 34) },
	Crust = { at = Vector3.new(-0.5, 4, -0.1), size = Vector3.new(38, 7.6, 15.3), color = Color3.fromRGB(97, 104, 90) },
	Ribs = {
		at = Vector3.new(3, 5.9, -0.1),
		size = Vector3.new(15.2, 10.3, 11.8),
		color = Color3.fromRGB(218, 212, 189),
	},
	ShellUpper = {
		at = Vector3.new(3, 6.6, 3.3),
		size = Vector3.new(12, 11.4, 6.7),
		color = Color3.fromRGB(30, 35, 41),
	},
	ShellLower = { at = Vector3.new(3, 6.6, -2), size = Vector3.new(12, 11.5, 9.2), color = Color3.fromRGB(30, 35, 41) },
	HeartGlow = {
		at = Vector3.new(3, 6.8, 0),
		size = Vector3.new(3.6, 5.4, 3.8),
		color = Color3.fromRGB(255, 199, 107),
	},
	HeartCage = { at = Vector3.new(3, 7.2, 0), size = Vector3.new(5.4, 7, 4), color = Color3.fromRGB(186, 132, 53) },
	CannonBow = {
		at = Vector3.new(17.6, 12.2, 1.1),
		size = Vector3.new(13.7, 6.3, 8.4),
		color = Color3.fromRGB(186, 132, 53),
	},
	CannonStarboard = {
		at = Vector3.new(12.5, 10.3, -6.3),
		size = Vector3.new(9.8, 10.5, 11.5),
		color = Color3.fromRGB(186, 132, 53),
	},
	CannonStern = {
		at = Vector3.new(-18.9, 9.6, -1),
		size = Vector3.new(11.3, 8.3, 10.4),
		color = Color3.fromRGB(186, 132, 53),
	},
	CannonPort = {
		at = Vector3.new(-11, 10.5, 6.9),
		size = Vector3.new(9.8, 10.5, 11.5),
		color = Color3.fromRGB(186, 132, 53),
	},
	Mast = {
		at = Vector3.new(10.5, 14.5, 1.2),
		size = Vector3.new(37.8, 26.8, 23.5),
		color = Color3.fromRGB(96, 92, 85),
	},
	Rigging = {
		at = Vector3.new(3.5, 13.8, 1.2),
		size = Vector3.new(49.2, 23.8, 23.6),
		color = Color3.fromRGB(79, 73, 61),
	},
	Sail = {
		at = Vector3.new(-6.5, 16, 2.4),
		size = Vector3.new(3.4, 12.6, 21.4),
		color = Color3.fromRGB(150, 156, 163),
	},
	Coat = { at = Vector3.new(-13.9, 18.3, -0.4), size = Vector3.new(6, 13.8, 8.5), color = Color3.fromRGB(30, 37, 62) },
	Arm = { at = Vector3.new(-13.8, 23.1, 0.3), size = Vector3.new(4.6, 11.7, 9.4), color = Color3.fromRGB(30, 37, 62) },
	Sabre = {
		at = Vector3.new(-11.8, 31, -2.5),
		size = Vector3.new(2.2, 6.9, 2.2),
		color = Color3.fromRGB(189, 196, 201),
	},
	Facings = {
		at = Vector3.new(-14, 23.3, 0.6),
		size = Vector3.new(5.1, 12.3, 9),
		color = Color3.fromRGB(201, 177, 102),
	},
	Skull = { at = Vector3.new(-14.5, 26, 1.1), size = Vector3.new(4, 4.6, 3.4), color = Color3.fromRGB(218, 212, 189) },
	EyeGlow = {
		at = Vector3.new(-13.8, 26.6, 1.1),
		size = Vector3.new(1, 0.9, 2.5),
		color = Color3.fromRGB(255, 204, 92),
	},
	Hat = { at = Vector3.new(-14.9, 27.9, 1.1), size = Vector3.new(3.7, 2.1, 7.8), color = Color3.fromRGB(22, 22, 27) },
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
-- Upright, the keel IS the boss-local X axis, so the hinge is simply the keel
-- rabbet on the centreline: boss_gen's WR_KEEL_Z, Blender (0, 0, 1.1). The
-- export maps Blender (x, y, z) -> Roblox (x, z, -y), so here it is
-- (0, 1.1, 0), and boss_gen's HANDOFF now prints BOTH spellings for exactly
-- this reason - the careened version printed only the Blender one and taking
-- it verbatim would have hinged about a point fifteen studs underground.
--
-- Stated in boss space (origin = the boss origin at sand level) and converted
-- to assembly-local at use, because `relative` is measured from Wrack_Base.
local HINGE = Vector3.new(0, 1.1, 0)

-- How far each plate swings at full open, from boss_gen's WR_OPEN_UPPER_DEG /
-- WR_OPEN_LOWER_DEG. Opposite signs about the same axis is what makes it a
-- ribcage splitting rather than a lid lifting.
--
-- Upright these are a PORT plate and a STARBOARD plate, so the two angles are
-- equal and opposite and the hull opens along its own centreline like double
-- doors - which is the read the careened version could not have had, because
-- its low plate swung into the sand. 50 degrees is the sand's number, not a
-- taste call: past ~55 the port rail goes through the shoal.
--
-- The signs are the authored ones and they are load-bearing. Re-derived for
-- this geometry: as authored the plate centres separate from 5.3 studs apart
-- to 11.9, and BOTH retreat from the heart-lantern at (3, 6.4, 0) - upper
-- 3.3 -> 7.7, lower 2.0 -> 6.4. Swung the other way the upper plate closes ON
-- the lantern instead (3.3 -> 2.2) and crosses into its sister, so the punish
-- window would seal the very thing it exists to expose. The lantern is
-- revealed by the geometry moving off it, which is why nothing here touches
-- its transparency or its material.
local SHELL_SWING = {
	ShellUpper = math.rad(50),
	ShellLower = math.rad(-50),
}

-- How fast the swing eases. Deliberately slow: this is thirty studs of hull
-- plate, and PyreliskBodyController's note applies with more force here -
-- something this big that snaps between states reads as a cut, not a swing.
-- (Twelve studs of plate now rather than thirty, but they swing through the
-- same arc in the same time - the rate is about legibility, not mass.)
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
	-- REPAINT THE IMPORT. Studio's glTF importer does NOT carry colour across:
	-- every cloned pack part arrives at Roblox's default grey, which is why the
	-- first import of the Careenage came up flat, arena and boss alike.
	--
	-- The inversion this fixes is worth stating, because it reads as a broken
	-- import rather than a missing repaint: the stand-in branch above has ALWAYS
	-- tinted from `AUTHORED`, so before this line, importing the real mesh made
	-- Wrack look WORSE than not importing it.
	--
	-- Same placement rule as the Neon assert below and for the same reason -
	-- AFTER the branch, never inside it, so it reaches the cloned pack part and
	-- the stand-in alike. It sits BEFORE the Neon assert so the glow pieces keep
	-- their material: a repaint that ran afterwards would flatten the
	-- heart-lantern back to plastic.
	--
	-- Keyed on the FULL object name, `PREFIX .. name` - `MeshColors` rows are
	-- the Blender object names ("Wrack_Hull"), not the bare piece names this
	-- file indexes `PIECES` and `AUTHORED` by. Not `part.Name`: that is not
	-- assigned until below, so a stand-in would silently miss every lookup.
	local color = MeshColors.get(PREFIX .. name)
	if color then
		part.Color = color
		-- A textured PBR surface overrides Color outright. boss_gen authors one
		-- flat material per object and never a texture, so anything the importer
		-- attached here is noise (BossArenaService drops it on the same grounds).
		local appearance = part:FindFirstChildWhichIsA("SurfaceAppearance")
		if appearance then
			appearance:Destroy()
		end
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
