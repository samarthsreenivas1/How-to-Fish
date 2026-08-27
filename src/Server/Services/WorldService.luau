--!nonstrict
-- WorldService.luau
-- Builds the ocean and places the island mesh (which includes the dock) on
-- boot.
--
-- Visual target: a small natural sand-bank island in a flat-shaded, low-poly
-- toy style - pale dry sand rising gently in the middle, a darker wet rim where
-- it meets the water, and a low plank dock running out over the sea.

local Lighting = game:GetService("Lighting")
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Islands = require(Shared.Config.Islands)
local Boats = require(Shared.Data.Boats)
local Bosses = require(Shared.Data.Bosses)
local Ocean = require(Shared.Config.Ocean)
local World = require(Shared.Config.World)
local Progression = require(Shared.Modules.Progression)
local Remotes = require(Shared.Net.Remotes)

local WorldService = {}

local islandFolder: Folder

-- The landform surfaces of every placed island (Island_Base / _Base2 / _Base3
-- and any other island's <Id>_Base*). The under-map net probes against these
-- and nothing else: rocks, trees, docks and the ocean must not count, or
-- standing under the rock arch would read as being under the map.
local baseParts: { BasePart } = {}
-- Where to drop a character that has slipped under the island (set in buildSpawn).
local safeSpawn: Vector3?
-- islandId -> true for every island whose mesh was actually found and placed;
-- travel is only allowed to these (Islands may list one before its mesh exists).
local placed: { [string]: boolean } = {}
-- islandId -> the placed island Model (for the bounds sampler).
local placedModels: { [string]: Instance } = {}

-- Collision groups (registered in registerCollisionGroups, used from
-- buildOcean up so declared here with the other state).
local BOAT_GROUP = World.BOAT_COLLISION_GROUP
local WATER_GROUP = World.WATER_COLLISION_GROUP

-- Flat-shaded palette. SmoothPlastic (not the Sand material) on purpose: the
-- reference look is clean low-poly faces, and Sand's grain texture fights it.
local COLOR = {
	drySand = Color3.fromRGB(236, 217, 166),
	wetSand = Color3.fromRGB(205, 181, 134),
	shallows = Color3.fromRGB(170, 168, 133),
	dockWood = Color3.fromRGB(158, 112, 68),
	postWood = Color3.fromRGB(120, 84, 52),
}

-- Small helper so the geometry below reads as a list of shapes rather than as
-- forty lines of property assignment.
local function part(props): BasePart
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth

	for key, value in props do
		if key ~= "Parent" then
			(p :: any)[key] = value
		end
	end

	p.Parent = props.Parent
	return p
end

-- A flat-lying cylinder disc: the building block of the sand bank. `topY` is
-- the walkable surface height; the disc extends down below the waterline so
-- overlapping discs never show gaps at the shore.
local function disc(x: number, z: number, radius: number, topY: number, color: Color3, parent: Instance): BasePart
	local height = topY + 4 -- reaches to y = -4, safely underwater
	return part({
		Name = "Sand",
		Shape = Enum.PartType.Cylinder,
		-- A cylinder's circular face is on its X axis, so the size is
		-- (thickness, diameter, diameter) and it is rolled 90 degrees to lie flat.
		Size = Vector3.new(height, radius * 2, radius * 2),
		CFrame = CFrame.new(x, topY - height / 2, z) * CFrame.Angles(0, 0, math.rad(90)),
		Color = color,
		Material = Enum.Material.SmoothPlastic,
		Parent = parent,
	})
end

-- ============================================================ Atmosphere

local function buildLighting()
	Lighting.Ambient = Color3.fromRGB(90, 100, 115)
	Lighting.OutdoorAmbient = Color3.fromRGB(120, 135, 150)
	Lighting.Brightness = 2.2
	Lighting.ClockTime = 13
	Lighting.GeographicLatitude = 12
	Lighting.ExposureCompensation = 0.15
	Lighting.GlobalShadows = true

	if not Lighting:FindFirstChildOfClass("Atmosphere") then
		local atmosphere = Instance.new("Atmosphere")
		atmosphere.Density = 0.28
		atmosphere.Offset = 0.25
		atmosphere.Color = Color3.fromRGB(200, 215, 230)
		atmosphere.Decay = Color3.fromRGB(105, 130, 160)
		atmosphere.Glare = 0.15
		atmosphere.Haze = 1.2
		atmosphere.Parent = Lighting
	end

	if not Lighting:FindFirstChildOfClass("Sky") then
		local sky = Instance.new("Sky")
		sky.SunAngularSize = 12
		sky.Parent = Lighting
	end

	-- Gentle bloom to sell the highlights on the water without washing out UI.
	if not Lighting:FindFirstChild("SeaBloom") then
		local bloom = Instance.new("BloomEffect")
		bloom.Name = "SeaBloom"
		bloom.Intensity = 0.5
		bloom.Size = 24
		bloom.Threshold = 1.6
		bloom.Parent = Lighting
	end
end

-- ============================================================ Ocean

-- The caustics tile, laid on the ocean's top face once per entry in
-- Ocean.LAYERS. The client scrolls these (OceanController); the server only
-- creates them so every client finds the same layers by name.
local function addWaterLayers(ocean: BasePart)
	-- An id of 0 means the image hasn't been uploaded yet - skip the layers
	-- rather than show Roblox's broken-texture placeholder across the sea.
	if Ocean.TEXTURE_ID == 0 then
		warn(
			"[WorldService] Water texture id not set in Shared/Config/Ocean.luau.\n"
				.. "  Upload once: Studio > View > Asset Manager > Import > assets/water.png,\n"
				.. "  then copy the image's asset id into Ocean.TEXTURE_ID.\n"
				.. "  See assets/README.md for the full walkthrough. Running on a bare blue plane until then."
		)
		return
	end

	for _, config in Ocean.LAYERS do
		local layer = Instance.new("Texture")
		layer.Name = config.name
		layer.Face = Enum.NormalId.Top
		layer.Texture = "rbxassetid://" .. tostring(Ocean.TEXTURE_ID)
		layer.StudsPerTileU = config.tileStuds
		layer.StudsPerTileV = config.tileStuds
		layer.Transparency = config.transparency
		layer.Color3 = config.color
		layer.Parent = ocean
	end
end

-- One ocean plane covers every placed island (2f's OceanController animates
-- this single part as the tide). Big enough to reach the farthest island plus
-- a margin, with a 3000 floor so the starter-only world is unchanged.
-- How much open water lies beyond the FARTHEST island's shore before the
-- plane (and the seabed under it) ends. Raised 500 -> 2000 (user,
-- 2026-08-27: "outside the island should be the vast expansive ocean"):
-- 500 put the world's visible edge a short swim from the Maelstrom's shore,
-- while the starter enjoys ~1,400+ studs of horizon - now every island,
-- the finale included, looks out over open sea past the fog.
local OCEAN_MARGIN = 2000

-- The sea should read as INFINITE (user, 2026-08-27: "make the ocean infinite
-- in size... make the ocean texture continue throughout the entire map"): a
-- true infinite plane doesn't exist in Roblox, so the span gets a hard floor
-- instead.
--
-- WHY EVERY EARLIER SPAN INCREASE DID NOTHING (user, 2026-08-28: "the water
-- still isnt there"): Roblox SILENTLY CLAMPS every BasePart to 2048 studs per
-- axis. The old single-part ocean asked for 60k, then 128k - and the engine
-- pinned it at 2048x2048 without an error every time, which is exactly the
-- small sheet whose edge kept showing up in screenshots. The ocean is
-- therefore built as a GRID of maximum-size tiles now (buildOcean below);
-- OCEAN_TILE stays a multiple of the caustics tileStuds (40) so the texture
-- pattern runs seamlessly across tile seams, and every tile shares the
-- OCEAN_NAME so CastAim / splash checks / the client tide treat the grid
-- exactly like the one plane they were written against.
local OCEAN_TILE = 2040 -- <= 2048 engine cap, and 51 repeats of the 40-stud caustics tile
local OCEAN_MIN_SPAN = 65280 -- 32x32 tiles; nearest edge ~16k past the farthest island

local function oceanSpan(): number
	local reach = 1500
	for id in placed do
		local entry = Islands.items[id]
		local p = entry.worldPosition
		local d = math.max(math.abs(p.X), math.abs(p.Z)) + (entry.radius or 0)
		reach = math.max(reach, d + OCEAN_MARGIN)
	end
	return math.max(reach * 2, OCEAN_MIN_SPAN)
end

local function buildOcean(parent: Instance)
	local span = oceanSpan()
	local tiles = math.ceil(span / OCEAN_TILE)
	local origin = -tiles * OCEAN_TILE / 2

	-- Flat parts rather than terrain water. Terrain at this scale costs real
	-- memory and streaming time, and nothing here needs buoyancy or swimming -
	-- the creatures never actually travel through it. The stylised look is
	-- painted on: one tiling caustics texture from assets/water_gen.py over a
	-- flat bright blue. A GRID of parts because the engine caps any one part
	-- at 2048 studs (see the OCEAN_TILE note above); every tile carries the
	-- same name, group, and layers, so nothing downstream can tell the
	-- difference.
	for i = 0, tiles - 1 do
		for j = 0, tiles - 1 do
			local cx = origin + (i + 0.5) * OCEAN_TILE
			local cz = origin + (j + 0.5) * OCEAN_TILE
			local ocean = part({
				Name = World.OCEAN_NAME, -- CastAim finds the water by this name
				Size = Vector3.new(OCEAN_TILE, 4, OCEAN_TILE),
				CFrame = CFrame.new(cx, World.WATER_Y - 2, cz),
				Color = Ocean.COLOR,
				Material = Enum.Material.SmoothPlastic,
				Reflectance = Ocean.REFLECTANCE,
				Parent = parent,
			})
			-- In its own group so the boat (BOAT group) passes through the slab
			-- and floats on code-held Y instead; players still stand on the
			-- surface. Assigning an unregistered group throws, and init must
			-- not die on it.
			pcall(function()
				ocean.CollisionGroup = WATER_GROUP
			end)

			addWaterLayers(ocean)

			-- Seabed, so looking over the rail shows a floor instead of the void.
			part({
				Name = "Seabed",
				Size = Vector3.new(OCEAN_TILE, 4, OCEAN_TILE),
				CFrame = CFrame.new(cx, World.SEABED_Y, cz),
				Color = Color3.fromRGB(30, 45, 55),
				Material = Enum.Material.SmoothPlastic,
				CanCollide = false,
				Parent = parent,
			})
		end
	end
end

-- ============================================================ Island mesh

-- The island is a Blender-authored low-poly mesh, generated by
-- assets/island_gen.py and imported into Studio once via Home > Import (see
-- assets/README.md). The game does not hand-build the island out of parts any
-- more; this code only finds the imported model, normalises it, and places it.
--
-- Authoring contract with the generator script: 1 unit = 1 stud, waterline at
-- y = 0, and the underwater skirt bottoms out at exactly SKIRT_BOTTOM. That
-- bottom is what we align on, so the imported model can sit anywhere in the
-- file and still land with its waterline matching the ocean.
--
-- Islands whose round-2 meshes carry geometry BELOW the skirt (Wreckwater's
-- seabed dunes and sunken keels, Gloomtrench's trench base) declare their true
-- authored bottom as `meshBottom` in Islands.luau; aligning on that instead
-- keeps the authored waterline on the ocean. Without it the bbox-bottom pin
-- hoisted the whole island by the overshoot - Wreckwater rode 9.3 studs high
-- and every hulk and piece of flotsam hung in the air (user, 2026-08-27:
-- "floating ships and litter").

local SKIRT_BOTTOM = -9

-- The barriers are ONE-WAY (user, 2026-08-23: "the fish can come through the
-- barriers but then they can't leave"): every wall this service builds is in
-- the BARRIER collision group and every creature part is in the CREATURE
-- group, and the two are set non-collidable - so a thrown catch flies in
-- through a wall instead of smacking into it, while the server's
-- clampToBounds is what keeps creatures from wandering back out. Players are
-- in the default group and are stopped normally. Registered in init, before
-- anything is built; the names are also read by Shared/Modules/CreatureModel.
local BARRIER_GROUP = World.BARRIER_COLLISION_GROUP
local CREATURE_GROUP = World.CREATURE_COLLISION_GROUP

local function registerCollisionGroups()
	for _, name in { BARRIER_GROUP, CREATURE_GROUP, BOAT_GROUP, WATER_GROUP } do
		-- Registering an existing group throws; a re-run of init must not die.
		pcall(function()
			PhysicsService:RegisterCollisionGroup(name)
		end)
	end
	local ok = pcall(function()
		PhysicsService:CollisionGroupSetCollidable(BARRIER_GROUP, CREATURE_GROUP, false)
		-- The boat holds its own waterline (BoatController) instead of resting
		-- on the solid ocean slab, and a thrown catch must not smack a parked
		-- hull. Water<->Creature stays COLLIDABLE - thrown fish have always
		-- been able to skip off the sea surface, and that look is approved.
		PhysicsService:CollisionGroupSetCollidable(WATER_GROUP, BOAT_GROUP, false)
		PhysicsService:CollisionGroupSetCollidable(CREATURE_GROUP, BOAT_GROUP, false)
	end)
	if not ok then
		warn("[WorldService] Could not make barriers pass-through for creatures; they may bounce off invisible walls.")
	end
end

-- Parts a player should walk through rather than collide with, by name prefix.
-- The foam is a paper-thin slab floating on the waterline; colliding with it
-- would make a swimmer stand on the foam. Lava is a surface you fall into, not
-- a floor, so it's non-collidable too (a damage volume comes in a later slice).
local NON_COLLIDE = {
	"Palm_Fronds",
	"Island_Bushes",
	"Palm_Coconuts",
	"Volcano_Lava",
	-- Every island's shoreline foam slab (Island_Foam, Volcano_Foam,
	-- Swamp_Foam, Frostmaw_Foam, ...): matched by the substring so a new
	-- island's foam can never be stood on by omission.
	"_Foam",
	-- The four new islands' fishable water surfaces - like the lava, water
	-- is a surface you fall into, not a floor (the procedural
	-- Maelstrom_Water sets its own CanCollide directly).
	"Swamp_Water",
	"Frostmaw_IceHoles",
	"Gloomtrench_DarkWater",
	"Wreckwater_Bay",
	-- The fen's cattail brakes and small dressing (swamp restart): you wade
	-- through reeds, step over lilies, logs and stones - no prop walls.
	"Swamp_Cattails",
	"Swamp_CattailHeads",
	"Swamp_Lilies",
	"Swamp_LilyBlooms",
	"Swamp_Logs",
	"Swamp_Stones",
	"Swamp_Mushrooms",
	"Swamp_TreeLeaves",
	"Swamp_TreeLeaves2",
	"Swamp_TreeLeaves3",
	"Swamp_HangMoss",
	"Swamp_Vines",
	-- The open-sea ghost hulks (round 2) and the bay wrecks' rotted sail
	-- scraps: box/hull collision on a +-700-stud wreck scatter would wall
	-- off the sea for the boat, and the fiction earns the pass-through -
	-- the ghost-fire glow says they aren't solid. Approved by the fleet
	-- coordinator 2026-08-26.
	"Wreckwater_SeaHulks",
	"Wreckwater_Sails",
	-- The Maelstrom's doomed fleet + dressing (2026-08-27): same ruling as
	-- the SeaHulks - hull collision across a 480-stud wreck field would wall
	-- off the finale for the boat. The fight floor (Maelstrom_Platforms), the
	-- spires, the reef rocks and the submerged base all stay collidable.
	"Maelstrom_Wrecks",
	"Maelstrom_Sails",
	"Maelstrom_Chains",
	"Maelstrom_Debris",
	"Maelstrom_StormGlow",
}

local function shouldCollide(instanceName: string): boolean
	for _, name in NON_COLLIDE do
		if string.find(instanceName, name, 1, true) then
			return false
		end
	end
	return true
end

-- Exact MeshPart names to colour, keyed the way Studio's glTF importer actually
-- names them. This is deliberately not left to the imported material: Studio's
-- Import pipeline has changed shape more than once already this project (OBJ
-- silently dropped materials entirely), and the in-editor preview is not a
-- reliable signal of what Play mode will show. Setting colour from code makes
-- the final look this module's responsibility instead of the importer's.
--
-- Island_Base has three materials on one Blender object (grass/sand/wet sand),
-- so it splits into three primitives on export; Studio numbers the 2nd and 3rd
-- "Island_Base2" / "Island_Base3". Confirmed by inspecting island.glb's
-- material assignments directly, not assumed.
local MESH_COLOR = {
	Island_Base = Color3.fromRGB(108, 178, 92), -- M_Grass
	Island_Base2 = Color3.fromRGB(238, 221, 170), -- M_Sand
	Island_Base3 = Color3.fromRGB(208, 186, 140), -- M_WetSand
	Island_Rocks = Color3.fromRGB(66, 66, 72),
	Palm_Trunks = Color3.fromRGB(122, 85, 58),
	-- Fronds carry two alternating greens (canopy depth), so like Island_Base
	-- they split into two numbered parts on import.
	Palm_Fronds = Color3.fromRGB(74, 160, 74), -- M_Frond
	Palm_Fronds2 = Color3.fromRGB(56, 128, 61), -- M_FrondDark
	Palm_Coconuts = Color3.fromRGB(92, 66, 46),
	Island_Bushes = Color3.fromRGB(64, 138, 74),
	-- The dock is part of the same mesh: planks + stringers in one part,
	-- posts + caps + cross-beams in a darker one.
	Dock_Planks = Color3.fromRGB(176, 125, 74),
	Dock_Posts = Color3.fromRGB(116, 79, 48),
	-- Stylised-water dressing (build_foam in island_gen.py): the white rim
	-- where water meets sand, sitting a hair above the ocean plane.
	Island_Foam = Color3.fromRGB(248, 254, 255),

	-- Ashfall Caldera - RESTARTED FROM SCRATCH (2026-08-27, user; the swamp
	-- pattern). Step 1: the bare ~895-stud landform (Volcano_Base, three band
	-- materials). Step 2: the lava is BACK - crater lake + six notch-fed
	-- rivers running rim to sea + apron pools/deltas, all ONE Volcano_Lava
	-- object (the fishable contract). The remaining old entries (Rocks/Dock/
	-- Foam/DeadTrees/Basalt/Vents/Dunes/Scree) return with their steps.
	Volcano_Base = Color3.fromRGB(43, 41, 48), -- M_VolRock
	Volcano_Base2 = Color3.fromRGB(79, 71, 71), -- M_VolAsh
	Volcano_Base3 = Color3.fromRGB(51, 48, 54), -- M_VolWet
	Volcano_Lava = Color3.fromRGB(255, 107, 15), -- M_Lava (glows; see MESH_MATERIAL)
	Volcano_DeadTrees = Color3.fromRGB(26, 22, 20), -- M_Charred (step 3: the dead giants)
	Volcano_Rocks = Color3.fromRGB(23, 23, 31), -- M_Obsidian (step 4: apron boulders + talus)
	-- Step 5: the tropical dock's wood, verbatim (user: same dock as home).
	Volcano_Dock_Planks = Color3.fromRGB(176, 125, 74),
	Volcano_Dock_Posts = Color3.fromRGB(116, 79, 48),
	Volcano_Foam = Color3.fromRGB(217, 217, 227), -- M_VolFoam (step 6: the surf line; NON_COLLIDE via "_Foam")

	-- Blackmire Fen - RESTARTED FROM SCRATCH (2026-08-27, user; see
	-- island_gen.py's swamp section). Step 2 brought the fen palette back
	-- onto the bare landform: peat/mud/wet-mud on the three base bands,
	-- matching the generator's COLORS. The old fen prop entries (Trunks/
	-- Canopy/Reeds/Snags/Hummocks/Lilies/Stones/Dock/Foam/Water) are gone
	-- with the mesh; each returns with its rebuild step - a re-added object
	-- without an entry here renders importer-grey, which is the reminder.
	Swamp_Base = Color3.fromRGB(61, 77, 50), -- M_Peat (dark waterlogged moss-peat)
	Swamp_Base2 = Color3.fromRGB(101, 85, 60), -- M_Mud (the mud "beach")
	Swamp_Base3 = Color3.fromRGB(74, 63, 47), -- M_WetMud
	Swamp_Cattails = Color3.fromRGB(122, 134, 66), -- reed-green stalks + blades
	Swamp_CattailHeads = Color3.fromRGB(94, 62, 35), -- the brown seed heads
	Swamp_Lilies = Color3.fromRGB(115, 164, 81), -- floating pads: the fen's colour pop
	Swamp_LilyBlooms = Color3.fromRGB(224, 158, 191), -- the occasional pale-pink flower
	Swamp_Logs = Color3.fromRGB(66, 53, 40), -- half-sunken logs + cypress knees
	Swamp_Stones = Color3.fromRGB(90, 93, 85), -- mossy bog stones
	Swamp_Mushrooms = Color3.fromRGB(199, 117, 71), -- toadstool clusters on logs and banks
	-- (The interior boardwalk was tried and REMOVED - user, 2026-08-28:
	-- "it doesnt fit in properly". The fen is fished from its banks.)
	Swamp_Foam = Color3.fromRGB(217, 224, 212), -- scummy pale shoreline rim (non-collide via the _Foam substring)
	-- The fen's trees, reference-style (user images): smooth tan curved
	-- trunks - willows w/ drooping blades, bare crooked snags. Trunks are
	-- deliberately NOT in NON_COLLIDE (a trunk is a real obstacle); the
	-- import uses PreciseConvexDecomposition so only the actual wood
	-- blocks, never a hull over the whole forest. The leaves ARE
	-- non-collide - you walk through hanging foliage.
	Swamp_Trees = Color3.fromRGB(150, 116, 84),
	Swamp_Trees2 = Color3.fromRGB(150, 116, 84), -- the forest is split over three meshes (triangle budget)
	Swamp_Trees3 = Color3.fromRGB(150, 116, 84),
	Swamp_TreeLeaves = Color3.fromRGB(56, 72, 47),
	Swamp_TreeLeaves2 = Color3.fromRGB(56, 72, 47), -- canopy split like the wood (triangle budget)
	Swamp_TreeLeaves3 = Color3.fromRGB(56, 72, 47),
	Swamp_HangMoss = Color3.fromRGB(115, 131, 93), -- pale spanish-moss ribbons off the tips
	Swamp_Vines = Color3.fromRGB(52, 68, 44), -- long dark vines reaching for the water

	-- Frostmaw Reach (assets/island_ice_gen.py).
	Frostmaw_Base = Color3.fromRGB(234, 239, 244), -- M_Snow
	Frostmaw_Base2 = Color3.fromRGB(199, 217, 230), -- M_IceSheet (the walked, fished shelf)
	Frostmaw_Base3 = Color3.fromRGB(163, 186, 207), -- M_IceWet
	Frostmaw_IceHoles = Color3.fromRGB(18, 33, 55),
	-- Round-2 soft-glacier rebuild (pack after 5904cf0): blunt chunky
	-- forms in a pastel arctic palette. RimIce/Seracs/Rocks/Snags are gone
	-- from the mesh; these ten replace them.
	Frostmaw_Berg = Color3.fromRGB(182, 214, 241), -- the rounded central berg
	Frostmaw_Arch = Color3.fromRGB(150, 195, 232), -- the ice arch
	Frostmaw_Walls = Color3.fromRGB(122, 173, 225), -- thick blue ice walls
	Frostmaw_Terraces = Color3.fromRGB(216, 231, 245), -- stepped snow mesas
	Frostmaw_Crystals = Color3.fromRGB(122, 218, 215), -- stubby teal clusters
	Frostmaw_PineSnow = Color3.fromRGB(246, 249, 251), -- snow load on the pines
	Frostmaw_Pines = Color3.fromRGB(90, 140, 102),
	Frostmaw_DeadTrees = Color3.fromRGB(74, 62, 56),
	Frostmaw_SnowMounds = Color3.fromRGB(246, 249, 252),
	Frostmaw_ShardLitter = Color3.fromRGB(237, 245, 252), -- flat ice-shard scatter
	Frostmaw_SnowCaps = Color3.fromRGB(245, 248, 252), -- M_SnowCap: snow strata on berg/walls/arches (shelf rebuild)
	Frostmaw_Dock_Planks = Color3.fromRGB(142, 122, 96),
	Frostmaw_Dock_Posts = Color3.fromRGB(103, 86, 67),
	Frostmaw_Foam = Color3.fromRGB(240, 246, 250),

	-- Gloomtrench (assets/island_gloom_gen.py). The glow objects are Neon.
	Gloomtrench_Base = Color3.fromRGB(33, 32, 42), -- M_GloomRock (near-black basalt)
	Gloomtrench_Base2 = Color3.fromRGB(52, 50, 62), -- M_GloomSand (ashen violet-grey shore)
	Gloomtrench_Base3 = Color3.fromRGB(40, 39, 50), -- M_GloomWet
	Gloomtrench_DarkWater = Color3.fromRGB(6, 11, 22),
	-- Round-2 coastal overhaul objects (87's lane): both near-black, NOT Neon.
	Gloomtrench_TidePools = Color3.fromRGB(20, 21, 30), -- M_GloomShelf
	Gloomtrench_Rift = Color3.fromRGB(37, 34, 46), -- M_GloomRift
	Gloomtrench_Spires = Color3.fromRGB(33, 32, 42),
	Gloomtrench_Stalks = Color3.fromRGB(59, 62, 76),
	Gloomtrench_GlowCyan = Color3.fromRGB(74, 239, 224),
	Gloomtrench_GlowViolet = Color3.fromRGB(169, 106, 239),
	Gloomtrench_Dock_Planks = Color3.fromRGB(71, 66, 82),
	Gloomtrench_Dock_Posts = Color3.fromRGB(50, 46, 60),
	Gloomtrench_Foam = Color3.fromRGB(171, 179, 199),

	-- Wreckwater (assets/island_wreck_gen.py). The ghost-glow is Neon.
	Wreckwater_Base = Color3.fromRGB(60, 62, 60), -- M_BayFloor (drowned grey-green silt)
	Wreckwater_Base2 = Color3.fromRGB(170, 163, 142), -- M_WreckSand (bone-grey sand)
	Wreckwater_Base3 = Color3.fromRGB(132, 126, 109), -- M_WreckWet
	Wreckwater_Bay = Color3.fromRGB(22, 50, 55),
	Wreckwater_Hulks = Color3.fromRGB(55, 46, 37),
	-- The open-sea graveyard (round 2): same rotten timber as the bay hulks.
	-- Deliberately NON_COLLIDE (below) - ghost wrecks the boat glides through.
	Wreckwater_SeaHulks = Color3.fromRGB(55, 46, 37),
	Wreckwater_GhostGlow = Color3.fromRGB(173, 241, 196),
	Wreckwater_Sails = Color3.fromRGB(189, 190, 179), -- M_WreckSail (rotted canvas, bone with a green cast)
	Wreckwater_Dunes = Color3.fromRGB(165, 154, 131), -- M_WreckDrift (drifted dune ridges)
	Wreckwater_Rocks = Color3.fromRGB(90, 92, 96),
	-- Round 1 added a lagoon-side quay ALONGSIDE the standard sea dock (the
	-- export carries both name sets), so both get the plank/post palette.
	Wreckwater_Quay_Planks = Color3.fromRGB(121, 103, 79),
	Wreckwater_Quay_Posts = Color3.fromRGB(84, 69, 52),
	Wreckwater_Dock_Planks = Color3.fromRGB(121, 103, 79),
	Wreckwater_Dock_Posts = Color3.fromRGB(84, 69, 52),
	Wreckwater_Foam = Color3.fromRGB(225, 231, 228),

	-- The Maelstrom (assets/island_gen.py `maelstrom`, 2026-08-27). The base
	-- is a fully SUBMERGED storm-shoal (three materials, so it splits into
	-- three numbered primitives like every base); the glow is Neon.
	-- Maelstrom_Water is NOT here - the whirlpool disc stays procedural
	-- (buildMaelstromSite) and deliberately out of the ocean dress (87's
	-- 42b73d7: MaelstromVfxController owns its CFrame).
	Maelstrom_Base = Color3.fromRGB(26, 28, 41), -- M_StormFloor (the vortex bowl)
	Maelstrom_Base2 = Color3.fromRGB(41, 46, 61), -- M_StormShoal (the pale shelf)
	Maelstrom_Base3 = Color3.fromRGB(33, 36, 48), -- M_StormWet
	Maelstrom_Platforms = Color3.fromRGB(46, 48, 60), -- the procedural stacks' grey-blue
	Maelstrom_Spires = Color3.fromRGB(33, 34, 46),
	Maelstrom_Rocks = Color3.fromRGB(46, 48, 60),
	Maelstrom_Wrecks = Color3.fromRGB(35, 28, 25), -- storm-blackened timbers
	Maelstrom_Sails = Color3.fromRGB(139, 144, 153), -- rain-grey canvas
	Maelstrom_Chains = Color3.fromRGB(22, 23, 28),
	Maelstrom_Debris = Color3.fromRGB(51, 42, 31),
	Maelstrom_StormGlow = Color3.fromRGB(107, 240, 255), -- electric storm-fire
}

-- Per-part material overrides; anything not listed gets SmoothPlastic (the flat
-- low-poly default). Lava glows.
local MESH_MATERIAL = {
	Volcano_Lava = Enum.Material.Neon,
	Gloomtrench_GlowCyan = Enum.Material.Neon,
	Gloomtrench_GlowViolet = Enum.Material.Neon,
	Wreckwater_GhostGlow = Enum.Material.Neon,
	Maelstrom_StormGlow = Enum.Material.Neon,
	-- Frostmaw's big glacial forms glint like real ice; nothing Neon here.
	Frostmaw_Berg = Enum.Material.Ice,
	Frostmaw_Arch = Enum.Material.Ice,
	Frostmaw_Walls = Enum.Material.Ice,
	Frostmaw_Crystals = Enum.Material.Ice,
}

local function applyMeshColors(island: Model)
	for _, descendant in island:GetDescendants() do
		if descendant:IsA("MeshPart") then
			-- Interior island waters wear the ocean's exact dress (user,
			-- 2026-08-27): same colour, material, reflectance and caustics
			-- layers as the sea plane, so a fen pool or an ice hole reads as
			-- WATER, not a painted slab. Takes precedence over the island
			-- palette; OceanController scrolls the layers and tides the part.
			if Ocean.INTERIOR_WATER_NAMES[descendant.Name] then
				descendant.Color = Ocean.COLOR
				descendant.Material = Enum.Material.SmoothPlastic
				descendant.Reflectance = Ocean.REFLECTANCE
				local appearance = descendant:FindFirstChildWhichIsA("SurfaceAppearance")
				if appearance then
					appearance:Destroy()
				end
				if not descendant:FindFirstChild(Ocean.LAYERS[1].name) then
					addWaterLayers(descendant)
				end
				continue
			end
			local color = MESH_COLOR[descendant.Name]
			if color then
				descendant.Color = color
				descendant.Material = MESH_MATERIAL[descendant.Name] or Enum.Material.SmoothPlastic

				-- Frond blades are closed solids now, but render them
				-- double-sided anyway: if a future mesh tweak reopens a face,
				-- the leaves thin out instead of vanishing outright.
				if string.find(descendant.Name, "Palm_Fronds", 1, true) then
					descendant.DoubleSided = true
				end
				-- Kill whatever surface appearance the importer attached; a
				-- textured PBR surface would otherwise override Color outright.
				local appearance = descendant:FindFirstChildWhichIsA("SurfaceAppearance")
				if appearance then
					appearance:Destroy()
				end
			else
				-- Usually means ReplicatedStorage/Assets/Island is an older
				-- import than the current island.glb - a part that the
				-- generator no longer produces. Re-import, don't add a colour.
				warn(
					string.format(
						"[WorldService] imported mesh part %q has no MESH_COLOR entry - it keeps the "
							.. "importer's own colour/material instead of the island palette. Add it to "
							.. "MESH_COLOR (a multi-material Blender object splits into <Name> / <Name>2 / "
							.. "<Name>3), or re-import assets/island_pack.glb if the pack is stale "
							.. "(assets/README.md).",
						descendant.Name
					)
				)
			end
		end
	end
end

-- Fallback so the game still boots before the mesh has been imported: a bare
-- sand disc and a loud warning explaining exactly what to do.
local function buildFallbackIsland(parent: Instance)
	warn(
		"[WorldService] No island mesh found (no ReplicatedStorage/Assets/IslandPack, no Assets/Island).\n"
			.. "  Import it once: Studio > Home > Import > assets/island_pack.glb (every island in one file),\n"
			.. "  set Collision Fidelity to PreciseConvexDecomposition on the mesh parts,\n"
			.. "  then move the imported model to ReplicatedStorage/Assets and name it 'IslandPack'.\n"
			.. "  See assets/README.md for the full walkthrough. Running on a plain sand disc until then."
	)
	disc(0, 0, World.ISLAND_RADIUS, 2, COLOR.drySand, parent)
	disc(0, 0, World.ISLAND_RADIUS + 10, 0.6, COLOR.wetSand, parent)
end

-- The first island in the order is the starter: it always exists (a fallback
-- disc stands in until its mesh is imported) so there is always somewhere to
-- spawn. Any other island simply doesn't appear (and can't be travelled to)
-- until its mesh is imported.
local STARTER_ID = Islands.order[1]

-- Find one island's imported template. Islands are authored together in a
-- single "IslandPack" model (assets/island_gen.py pack build): one group per
-- island, its parts under a container named for the island's model. The group
-- is found by the island's base part so it works whatever the importer names
-- the intermediate node. Falls back to a standalone Assets/<model> import (the
-- older one-island-per-file layout), so either import style works.
local function islandTemplate(entry): Instance?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if not assets then
		return nil
	end
	local pack = assets:FindFirstChild("IslandPack")
	if pack then
		local base = pack:FindFirstChild(entry.model .. "_Base", true)
		if base then
			-- Walk up to the pack's direct child that contains this island.
			local group: Instance = base
			while group.Parent and group.Parent ~= pack do
				group = group.Parent
			end
			if group ~= pack then
				return group
			end
		end
	end
	return assets:FindFirstChild(entry.model)
end

-- Clone one island's imported mesh, colour it, and drop it onto the ocean at
-- its configured spot. Returns true if it was actually placed.
local function placeIsland(parent: Instance, id: string, entry): boolean
	local template = islandTemplate(entry)

	if not template then
		if id == STARTER_ID then
			buildFallbackIsland(parent)
			return true -- the disc is a valid place to stand / spawn / travel to
		end
		warn(
			string.format(
				"[WorldService] Island %q has no mesh at ReplicatedStorage/Assets/%s yet - "
					.. "skipping it (import it to enable travel there; see assets/README.md).",
				id,
				entry.model
			)
		)
		return false
	end

	local island = template:Clone()

	for _, descendant in island:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = shouldCollide(descendant.Name)
			-- Remember the landform surfaces for the under-map net below.
			if string.find(descendant.Name, "_Base", 1, true) then
				table.insert(baseParts, descendant)
			end
			-- DO NOT set CollisionFidelity here. It is a Plugin-capability
			-- property: writing it from a server script throws "The current
			-- thread cannot write 'CollisionFidelity' (lacking capability
			-- Plugin)", which fails WorldService.init, which halts the whole
			-- boot loop - so the island, the ocean, the spawn AND every
			-- service after this one silently never load (user, 2026-08-22:
			-- "the island disappeared and the rod is gone"). Collision
			-- fidelity is baked into the parts at import time instead: set it
			-- in Studio before re-exporting assets/Assets.rbxm, per
			-- assets/README.md. That is the one thing the game code genuinely
			-- cannot do at runtime.
		end
	end

	applyMeshColors(island)

	-- Place it. Vertically: skirt bottom at its authored depth so EVERY
	-- island's waterline lines up with the one ocean plane. Horizontally: the
	-- generator builds <model>_Base centred on the island's own origin, so
	-- that part's centre is the anchor (NOT the whole model's bounding box,
	-- which the dock would drag off-centre) - moved to entry.worldPosition.
	local boxCFrame, boxSize = island:GetBoundingBox()
	-- The coastline wobbles and the underwater skirt flares out past the
	-- nominal radius, so the real span runs a good bit over 2*radius; only a
	-- gross scale mistake (a re-import at the wrong unit) should trip this.
	local expected = (entry.radius or World.ISLAND_RADIUS) * 2
	if boxSize.X < expected * 0.5 or boxSize.X > expected * 2.0 then
		warn(
			string.format(
				"[WorldService] Island %q is %.0f studs across - expected roughly %.0f. "
					.. "Re-import its mesh without changing the scale.",
				id,
				boxSize.X,
				expected
			)
		)
	end

	-- Anchor horizontally on the base part's centre. It's ~14 studs off the true
	-- crater centre (the lopsided underwater skirt pulls its bbox centre), but
	-- that's the closest simple proxy: the lava part's bbox is far worse (~78
	-- studs off, dragged by the two outflow channels), and the whole model's box
	-- is dragged by the dock. The rim/pier bounds tolerate the small offset
	-- (they key off geometry, not this centre); a truly-centred rim would come
	-- from the centroid of the sampled rim ring in sampleRim, not from here.
	local base = island:FindFirstChild(entry.model .. "_Base", true)
	local anchor = if base and base:IsA("BasePart") then base.Position else boxCFrame.Position

	local pos = entry.worldPosition
	-- Align the model's bbox bottom to its authored minimum (meshBottom, from
	-- the pack build's HANDOFF lines) so authored z=0 lands exactly on the
	-- ocean; SKIRT_BOTTOM covers every island whose lowest point IS the skirt.
	local targetCenterY = (entry.meshBottom or SKIRT_BOTTOM) + boxSize.Y / 2
	local delta = Vector3.new(pos.X - anchor.X, targetCenterY - boxCFrame.Position.Y, pos.Z - anchor.Z)
	island:PivotTo(island:GetPivot() + delta)

	island.Parent = parent
	placedModels[id] = island
	return true
end

-- ============================================================ Island bounds (the volcano's rim)
--
-- The volcano's playable area is its crater rim - a flat ring at ~y 200
-- (island_gen PROFILE / RIM_FLAT) - plus the fishing pier that runs inward
-- from it over the lava lake. Players must not fall off the outer flank or
-- into the lake, and creatures must not be shoved, lunge, tunnel or flop
-- off the rim (user, 2026-08-23). The ring's outline is jagged (GRASS_TERMS
-- wobble plus per-vertex CRAG_RADIAL jitter baked into the mesh), so no
-- formula reproduces it: at boot the placed mesh is SAMPLED - for each of
-- `rim.samples` angles a radial march of down-probes against the island's
-- base parts only (rim rocks are collidable and would read as false rim)
-- finds where the ground sits at rim height - giving an inner and outer
-- edge radius per angle, nil where a spillway notch cuts the ring.
--
-- From that: invisible walls (CanCollide, but CanQuery OFF so CastAim's and
-- the creatures' raycasts pass straight through) along both edges, radial
-- closers where the band is cut by a notch, a gap in the inner wall at the
-- pier's mouth, and railings round the pier and its end platform; and
-- `clampToBounds`, which CreatureService runs every creature position
-- through. The pier is located from its Volcano_Dock_Planks part (radial,
-- so its centre gives its direction and distance) and skipped if the pack
-- in play predates it. Islands without a `rim` block (the starter) have no
-- bounds at all.

-- islandId -> sampled bounds { center, samples, inner[], outer[], rim, pier? }
local bounds: { [string]: any } = {}

-- Flip to true to SEE the rim walls (red slabs) in-game while debugging the
-- pier-mouth gap - the gap should line up with the visible dock.
local DEBUG_WALLS = false

local function wallBetween(parent: Instance, a: Vector3, b: Vector3, bottomY: number, height: number)
	local flatA, flatB = Vector3.new(a.X, 0, a.Z), Vector3.new(b.X, 0, b.Z)
	local along = flatB - flatA
	local length = along.Magnitude
	if length < 0.5 then
		return
	end
	local mid = (flatA + flatB) / 2 + Vector3.new(0, bottomY + height / 2, 0)
	local wall = part({
		Name = "RimWall",
		Size = Vector3.new(1, height, length + 1),
		CFrame = CFrame.lookAt(mid, mid + along),
		Transparency = if DEBUG_WALLS then 0.5 else 1,
		Color = Color3.fromRGB(255, 60, 60),
		Material = Enum.Material.SmoothPlastic,
		-- Casts pass through: CastAim's ray and the surface probes skip
		-- non-query-able parts, and CastAim also hops any part named RimWall /
		-- PierRail by name, so a barrier can never stop you fishing.
		CanQuery = false,
		CanTouch = false,
		Parent = parent,
	})
	-- One-way (user, 2026-08-23): solid to players, but creatures pass
	-- straight through - a catch thrown in off the lava must not bounce off an
	-- invisible wall on its way to your feet. What keeps them from leaving is
	-- clampToBounds, not this part. Set AFTER creation and guarded: assigning
	-- an unregistered collision group throws, and this must never be able to
	-- kill WorldService.init (which would take the whole server boot with it).
	pcall(function()
		wall.CollisionGroup = BARRIER_GROUP
	end)
	return wall
end

-- `centre` overrides the island's worldPosition as the ring's origin: the
-- second pass samples around the centroid of the first pass's inner-rim
-- points, which closes on the true crater centre however far off the
-- placed mesh's anchor is (9b, 2026-08-23 - a part's bbox centre proved to
-- be 14-78 studs off).
local function sampleRim(id: string, entry, island: Instance, centre: Vector3?)
	local rim = entry.rim
	local c = centre or entry.worldPosition
	local bases = {}
	for _, descendant in island:GetDescendants() do
		if descendant:IsA("BasePart") and string.find(descendant.Name, "_Base", 1, true) then
			table.insert(bases, descendant)
		end
	end
	if #bases == 0 then
		return nil
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = bases

	-- The lava lake's parts, for the shore test below.
	local lavaParts = {}
	for _, descendant in island:GetDescendants() do
		if descendant:IsA("BasePart") and string.find(descendant.Name, "_Lava", 1, true) then
			table.insert(lavaParts, descendant)
		end
	end
	local lavaParams = RaycastParams.new()
	lavaParams.FilterType = Enum.RaycastFilterType.Include
	lavaParams.FilterDescendantsInstances = lavaParts

	local n = rim.samples
	local inner, outer = {}, {}
	local top = rim.height + 150
	local reach = top - rim.height + 100
	local valid = 0
	local shoreAnchored = 0
	local capped = 0
	for i = 1, n do
		local a = (i - 1) / n * math.pi * 2
		local ca, sa = math.cos(a), math.sin(a)
		local first, last = nil, nil
		local r = rim.minRadius
		while r <= rim.maxRadius do
			local hit =
				Workspace:Raycast(Vector3.new(c.X + ca * r, top, c.Z + sa * r), Vector3.new(0, -reach, 0), params)
			if hit and math.abs(hit.Position.Y - rim.height) <= rim.tolerance then
				first = first or r
				last = r
			elseif first then
				break -- past the band
			end
			r += rim.step
		end

		-- The inner edge must sit at the top of the cliff above the lava, i.e.
		-- the lava's SHORE plus the cliff's width - never further in. The
		-- base's down-probe alone can't be trusted for that: a raycast tests
		-- a MeshPart's COLLISION geometry, and with the Default (convex hull)
		-- fidelity the crater is capped by an invisible floor at rim height,
		-- which reads as "rim" all the way to minRadius - and which a player
		-- can walk out over the lake on (user, 2026-08-23: "floats over the
		-- lava until it reaches the barrier"). The lava part's own hull is a
		-- flat disc, so its extent is reliable either way.
		if first and #lavaParts > 0 then
			local lavaOuter = nil
			local rr = rim.minRadius
			while rr <= (last or rim.maxRadius) do
				local hit = Workspace:Raycast(
					Vector3.new(c.X + ca * rr, top, c.Z + sa * rr),
					Vector3.new(0, -reach, 0),
					lavaParams
				)
				if hit then
					lavaOuter = rr
				end
				rr += rim.step
			end
			if lavaOuter then
				local shore = lavaOuter + (rim.cliff or 12)
				if shore > first and shore < last then
					if first <= rim.minRadius + rim.step then
						capped += 1
					end
					first = shore
					shoreAnchored += 1
				end
			end
		end

		inner[i], outer[i] = first, last
		if first then
			valid += 1
		end
	end
	if capped > n * 0.25 then
		warn(
			string.format(
				"[WorldService] Island %q: ground reads as rim height right out over the lava at %d of %d angles - "
					.. "its mesh collision is almost certainly the Default convex hull (an invisible floor caps the crater). "
					.. "The rim barrier has been anchored to the lava's shore instead, but players will still walk on that "
					.. "cap wherever the barrier doesn't reach: set CollisionFidelity = PreciseConvexDecomposition on the %s "
					.. "parts in Studio and re-export assets/Assets.rbxm (assets/README.md).",
				id,
				capped,
				n,
				entry.model
			)
		)
	end
	if valid < n * 0.5 then
		warn(
			string.format(
				"[WorldService] Island %q: found rim ground (y ~ %d) at only %d of %d angles - no bounds built. "
					.. "Is the mesh placed and at the expected scale?",
				id,
				rim.height,
				valid,
				n
			)
		)
		return nil
	end
	return {
		center = c,
		samples = n,
		inner = inner,
		outer = outer,
		rim = rim,
		shoreAnchored = shoreAnchored,
		bases = bases, -- the landform, for "is there still rim beside the deck?"
	}
end

-- The rim pier, from its planks part: it's radial, so the part's centre
-- gives both its direction from the crater's centre and how far along it
-- sits; the authored dimensions (Islands.pier) give the rest.
local function findPier(entry, island: Instance, data)
	local p = entry.pier
	if not p then
		return
	end
	local planks = island:FindFirstChild(p.partName, true)
	if not planks or not planks:IsA("BasePart") then
		return -- pack predates the pier; no gap, no railings
	end
	local c = data.center
	local off = Vector3.new(planks.Position.X - c.X, 0, planks.Position.Z - c.Z)
	if off.Magnitude < 1 then
		return
	end
	local dist = off.Magnitude
	local dir = off.Unit -- from the crater's centre out toward the rim

	-- Is the part's Position the pier's MIDPOINT or its BASE on the rim? The
	-- generator bakes the deck in world space with the object's origin at the
	-- rim end, and the import kept that (the user's boot line put it 214 from
	-- the centre - the rim edge - where a midpoint would be ~150). Don't
	-- assume: probe for planks 25 studs further OUT than the position; if
	-- they're there the position is the midpoint, else it's the base.
	local dockParams = RaycastParams.new()
	dockParams.FilterType = Enum.RaycastFilterType.Include
	dockParams.FilterDescendantsInstances = { planks }
	local probeAt = Vector3.new(c.X, 0, c.Z) + dir * (dist + 25)
	local outward =
		Workspace:Raycast(Vector3.new(probeAt.X, p.deckY + 150, probeAt.Z), Vector3.new(0, -300, 0), dockParams)
	local outerR, innerR
	if outward then
		outerR, innerR = dist + p.length / 2, dist - p.length / 2 -- midpoint
	else
		outerR, innerR = dist, dist - p.length -- base on the rim
	end

	data.pier = {
		dir = dir,
		outerR = outerR, -- where it meets the rim
		innerR = innerR, -- its far end, out over the lava
		width = p.width,
		endLength = p.endLength,
		endWidth = p.endWidth,
		deckY = p.deckY,
		positionIs = if outward then "midpoint" else "base",
	}
	data.planksPart = planks -- the railings are built from its own frame
	print(
		string.format(
			"[WorldService] pier found: planks at (%.0f, %.0f) = its %s, centre (%.0f, %.0f), azimuth %.0f deg, outerR %.0f, innerR %.0f",
			planks.Position.X,
			planks.Position.Z,
			data.pier.positionIs,
			c.X,
			c.Z,
			math.deg(math.atan2(dir.Z, dir.X)),
			outerR,
			innerR
		)
	)
end

-- The walls: the rim's inner and outer edges, radial closers where a notch
-- cuts the band, and NOTHING on the pier. The pier mouth is found
-- geometrically - an inner-wall point is dropped if a straight-down probe
-- at it (or just beside it, tangentially) lands on the island's dock parts
-- - rather than from a computed pier axis: two earlier versions (a tiny
-- angular test, then an axis-distance test) both left a wall across the
-- deck when the computed axis and the real planks disagreed (user
-- screenshots, 2026-08-23). The pier has no railings either: the user
-- wants no barrier on the dock or sticking out of it onto the rim.
local function buildRimWalls(parent: Instance, data)
	local rim = data.rim
	local n = data.samples
	local c = data.center
	local bottom = rim.height - 6
	local h = rim.wallHeight

	local function pt(i: number, r: number): Vector3
		local a = (i - 1) / n * math.pi * 2
		return Vector3.new(c.X + math.cos(a) * r, 0, c.Z + math.sin(a) * r)
	end

	local dockParams = nil
	if data.dockParts and #data.dockParts > 0 then
		dockParams = RaycastParams.new()
		dockParams.FilterType = Enum.RaycastFilterType.Include
		dockParams.FilterDescendantsInstances = data.dockParts
	end
	local top = rim.height + 150
	local reach = top - rim.height + 100
	local function overDock(p: Vector3): boolean
		if not dockParams then
			return false
		end
		return Workspace:Raycast(Vector3.new(p.X, top, p.Z), Vector3.new(0, -reach, 0), dockParams) ~= nil
	end
	-- A wall point counts as "on the dock" if the deck is under it or under
	-- a point MOUTH_MARGIN studs to either side along the ring, so the gap
	-- clears the planks with room to walk. Belt and braces: the pier-axis
	-- test (valid now that placeIsland anchors the island on the true crater
	-- centre - 9b, 2026-08-23) also opens it, generously, in case the probe
	-- misses (a renamed part, a pack without posts, a hull quirk).
	local MOUTH_MARGIN = 10
	local pier = data.pier
	local function nearPierAxis(p: Vector3): boolean
		if not pier then
			return false
		end
		local off = Vector3.new(p.X - c.X, 0, p.Z - c.Z)
		local along = off:Dot(pier.dir)
		if along < pier.innerR - 10 or along > pier.outerR + 40 then
			return false
		end
		local sideAxis = Vector3.new(-pier.dir.Z, 0, pier.dir.X)
		return math.abs(off:Dot(sideAxis)) <= pier.width / 2 + MOUTH_MARGIN
	end
	-- Name-free test, the one that can't be fooled by an import naming the
	-- pier something else: the deck is the only collidable surface at
	-- `deckY` (198) inside the cliff line - the rim is 200+, the cliff face
	-- and the lake are lower - so ground at deck height under a wall point
	-- means the wall is crossing the pier.
	local islandParams = nil
	if data.island then
		islandParams = RaycastParams.new()
		islandParams.FilterType = Enum.RaycastFilterType.Include
		islandParams.FilterDescendantsInstances = { data.island }
		islandParams.RespectCanCollide = true
	end
	-- (A deck-HEIGHT test lived here for one build and opened 158 of 180
	-- inner segments: the deck is 198 and the rim 200, inside its +/-3. Gone.)
	-- The test that needs NOTHING from the import - not names, not the deck
	-- height, not a computed axis: the pier is the only place on the rim
	-- where walkable ground CONTINUES inward past the edge, as a NARROW
	-- strip. From a wall point, probe 12 and 24 studs toward the crater:
	-- ground at about the same height both times = something runs inward;
	-- then at 24 in, probe 20 studs to either side: NO ground at that height
	-- = it's a strip, not a plateau. (The Default-fidelity hull cap over the
	-- crater is a plateau - it fails the narrowness check - so this can't
	-- strip the whole inner wall on an un-decomposed mesh.)
	local function isPierStrip(p: Vector3): boolean
		if not islandParams then
			return false
		end
		local radial = Vector3.new(p.X - c.X, 0, p.Z - c.Z)
		if radial.Magnitude < 0.01 then
			return false
		end
		local inward = -radial.Unit
		local tangent = Vector3.new(-radial.Unit.Z, 0, radial.Unit.X)
		local function groundAt(q: Vector3): number?
			local hit = Workspace:Raycast(Vector3.new(q.X, top, q.Z), Vector3.new(0, -reach, 0), islandParams)
			return hit and hit.Position.Y or nil
		end
		local here = groundAt(p)
		if not here then
			return false
		end
		local near, far = groundAt(p + inward * 12), groundAt(p + inward * 24)
		if not (near and far and math.abs(near - here) <= 5 and math.abs(far - here) <= 5) then
			return false
		end
		local farPoint = p + inward * 24
		local left, right = groundAt(farPoint + tangent * 20), groundAt(farPoint - tangent * 20)
		local leftOpen = left == nil or math.abs(left - here) > 8
		local rightOpen = right == nil or math.abs(right - here) > 8
		return leftOpen and rightOpen
	end
	local function onDock(p: Vector3): boolean
		if nearPierAxis(p) then
			return true
		end
		if isPierStrip(p) then
			return true
		end
		local radial = Vector3.new(p.X - c.X, 0, p.Z - c.Z)
		if radial.Magnitude < 0.01 then
			return overDock(p)
		end
		local tangent = Vector3.new(-radial.Unit.Z, 0, radial.Unit.X)
		local left, right = p + tangent * MOUTH_MARGIN, p - tangent * MOUTH_MARGIN
		return overDock(p) or overDock(left) or overDock(right)
	end

	local mouthSegments = 0
	local innerWalls = {} -- { part, i, radius } for the survivors' report below
	for i = 1, n do
		local j = i % n + 1
		local ii, io, ji, jo = data.inner[i], data.outer[i], data.inner[j], data.outer[j]
		if ii and ji then
			local a, b = pt(i, ii), pt(j, ji)
			if onDock(a) or onDock(b) or onDock((a + b) / 2) then
				mouthSegments += 1
			else
				local wall = wallBetween(parent, a, b, bottom, h)
				if wall then
					table.insert(innerWalls, { part = wall, i = i, radius = ii })
				end
			end
			wallBetween(parent, pt(i, io), pt(j, jo), bottom, h)
		elseif ii and not ji then
			wallBetween(parent, pt(i, ii), pt(i, io), bottom, h) -- the band stops: close it
		elseif ji and not ii then
			wallBetween(parent, pt(j, ji), pt(j, jo), bottom, h)
		end
	end
	-- Backstop, after the fact: any wall that physically overlaps a
	-- collidable island part sitting at deck height (the planks, whatever
	-- they're called) is torn down. Uses real collision geometry, not names
	-- or angles.
	if data.island then
		local dockOverlap = nil
		if data.dockParts and #data.dockParts > 0 then
			dockOverlap = OverlapParams.new()
			dockOverlap.FilterType = Enum.RaycastFilterType.Include
			dockOverlap.FilterDescendantsInstances = data.dockParts
		end
		for _, wall in parent:GetChildren() do
			if wall:IsA("BasePart") and wall.Name == "RimWall" then
				local doomed = false
				-- (a) it stands on the pier strip - the name/height-free test,
				-- on the FINAL wall position whichever loop built it;
				local centre = wall.Position
				local half = wall.CFrame.LookVector * (wall.Size.Z / 2 - 0.5)
				if isPierStrip(centre) or isPierStrip(centre + half) or isPierStrip(centre - half) then
					doomed = true
				end
				-- (b) it physically intersects a dock part (planks / posts) -
				-- real collision geometry, no heights involved.
				if not doomed and dockOverlap and #Workspace:GetPartsInPart(wall, dockOverlap) > 0 then
					doomed = true
				end
				if doomed then
					wall:Destroy()
					mouthSegments += 1
				end
			end
		end
	end

	-- The survivors' report: every inner-wall segment still standing, with
	-- its angle, radius, and what each test said about its midpoint - so the
	-- next boot names the panels on the pier exactly instead of us guessing.
	local survivors = {}
	for _, entry in innerWalls do
		if entry.part.Parent then
			local a = (entry.i - 1) / n * 360
			local mid = entry.part.Position
			table.insert(
				survivors,
				string.format(
					"%.0fdeg r%.0f axis=%s dock=%s strip=%s",
					a,
					entry.radius,
					tostring(nearPierAxis(mid)),
					tostring(overDock(mid)),
					tostring(isPierStrip(mid))
				)
			)
		end
	end
	print(
		string.format(
			"[WorldService] inner wall: %d segments standing (%d opened). Standing: %s",
			#survivors,
			mouthSegments,
			table.concat(survivors, " | ")
		)
	)

	data.mouthSegments = mouthSegments
	if mouthSegments == 0 and ((data.dockParts and #data.dockParts > 0) or pier) then
		warn(
			"[WorldService] A dock was found but NO inner-wall segment sits over it - the mouth did not open. "
				.. "Check the dock parts' names (matched on 'Dock') and whether the inner wall actually crosses the pier."
		)
	end
end

-- Railings along the pier, so you can't walk off the deck into the lava -
-- but NOT along the stretch that still sits on the rim (user, 2026-08-23:
-- "add barriers for the dock but make sure the section that is on the rim
-- does not have a barrier"), and never across the walkway.
--
-- FULL, CONTINUOUS walls (user, same day: "make them full walls like it was
-- before"): a first pass built one short wall per 4-stud step, which came
-- out as a row of floating panels. This measures the deck once and then
-- lays down a handful of long straight walls along its true centreline -
-- the narrow run, a step out where the wide end platform begins, the
-- platform's own sides, and a cap across the far end.
--
-- Everything is measured, nothing assumed: the pier's long axis comes from
-- the planks part's own CFrame (the deck is NOT radial about the crater
-- centre - its axis line passes ~26 studs to one side of it), its ends and
-- width come from probing for where the planks stop, and the rim stretch is
-- where there is still rim-height ground beside the deck.
local RAIL_STEP = 2
local RAIL_EDGE_PAD = 1.5 -- how far outside the planks the wall stands

local function buildPierRailings(parent: Instance, data): number
	local planks = data.planksPart
	if not planks or not data.dockParts or #data.dockParts == 0 then
		return 0
	end
	local rim = data.rim
	local c = data.center

	local deckParams = RaycastParams.new()
	deckParams.FilterType = Enum.RaycastFilterType.Include
	deckParams.FilterDescendantsInstances = data.dockParts

	local baseParams = nil
	if data.bases and #data.bases > 0 then
		baseParams = RaycastParams.new()
		baseParams.FilterType = Enum.RaycastFilterType.Include
		baseParams.FilterDescendantsInstances = data.bases
	end

	local top = rim.height + 150
	local reach = top - rim.height + 140
	local function groundAt(p: Vector3, params): number?
		local hit = Workspace:Raycast(Vector3.new(p.X, top, p.Z), Vector3.new(0, -reach, 0), params)
		return hit and hit.Position.Y or nil
	end

	-- The deck's own footprint, MEASURED. The part's CFrame is no use here:
	-- Roblox's glTF importer bakes the orientation into the mesh geometry and
	-- leaves the MeshPart at identity rotation, so cf.LookVector / RightVector
	-- are just world axes - building along them put the railings across the
	-- deck at an angle (user, 2026-08-23: "the walls aren't properly formed").
	-- Instead: probe a grid of down-rays over the planks' bounding box and
	-- take the PRINCIPAL AXIS of the hits. That is the pier's true direction,
	-- whatever the import did.
	local bbCentre = Vector3.new(planks.Position.X, 0, planks.Position.Z)
	local halfX, halfZ = planks.Size.X / 2 + 4, planks.Size.Z / 2 + 4
	local points = {}
	local gx = -halfX
	while gx <= halfX do
		local gz = -halfZ
		while gz <= halfZ do
			local q = bbCentre + Vector3.new(gx, 0, gz)
			local y = groundAt(q, deckParams)
			if y then
				table.insert(points, { x = q.X, z = q.Z, y = y })
			end
			gz += RAIL_STEP
		end
		gx += RAIL_STEP
	end
	if #points < 16 then
		warn("[WorldService] Could not measure the pier's deck (too few probe hits); no railings built.")
		return 0
	end

	local cx, cz = 0, 0
	for _, p in points do
		cx += p.x
		cz += p.z
	end
	cx, cz = cx / #points, cz / #points
	local sxx, sxz, szz = 0, 0, 0
	for _, p in points do
		local dx, dz = p.x - cx, p.z - cz
		sxx += dx * dx
		sxz += dx * dz
		szz += dz * dz
	end
	local theta = 0.5 * math.atan2(2 * sxz, sxx - szz)
	local axis = Vector3.new(math.cos(theta), 0, math.sin(theta))
	-- Point it INWARD, away from the rim and toward the crater's centre.
	local centreline = Vector3.new(cx, 0, cz)
	if axis:Dot(Vector3.new(c.X - cx, 0, c.Z - cz)) < 0 then
		axis = -axis
	end
	local tangent = Vector3.new(-axis.Z, 0, axis.X)
	local function pointAt(s: number): Vector3
		return centreline + axis * s
	end

	-- Bucket the hits along the axis: each bin's left / right half-width and
	-- deck height, in order from the rim end inward.
	local BIN = 4
	local bins, indices = {}, {}
	for _, p in points do
		local d = Vector3.new(p.x - cx, 0, p.z - cz)
		local sv, tv = d:Dot(axis), d:Dot(tangent)
		local key = math.floor(sv / BIN)
		local bin = bins[key]
		if not bin then
			bin = { key = key, left = 0, right = 0, y = p.y }
			bins[key] = bin
			table.insert(indices, key)
		end
		bin.left = math.max(bin.left, tv)
		bin.right = math.max(bin.right, -tv)
		bin.y = math.min(bin.y, p.y)
	end
	table.sort(indices)

	local steps = {}
	for _, key in indices do
		local bin = bins[key]
		local sv = (key + 0.5) * BIN
		local p = pointAt(sv)
		local left, right = bin.left + RAIL_EDGE_PAD, bin.right + RAIL_EDGE_PAD
		-- Still over the rim? Then no railing here.
		local onRim = false
		if baseParams then
			for _, side in { left + 6, -(right + 6) } do
				local g = groundAt(p + tangent * side, baseParams)
				if g and math.abs(g - rim.height) <= rim.tolerance + 2 then
					onRim = true
				end
			end
		end
		table.insert(
			steps,
			{ s = sv, left = left, right = right, half = math.max(left, right), y = bin.y, onRim = onRim }
		)
	end
	if #steps < 3 then
		return 0
	end

	-- Where the railings start: past the rim stretch (which is contiguous at
	-- the rim end), and where they stop: the deck's far end.
	local first = 1
	while first <= #steps and steps[first].onRim do
		first += 1
	end
	if first > #steps - 1 then
		warn("[WorldService] The pier reads as sitting on the rim along its whole length; no railings built.")
		return 0
	end
	local last = #steps

	-- The wide end platform: the run of bins at the far end that is
	-- noticeably wider than the walkway.
	local minWidth, maxWidth = math.huge, 0
	for i = first, last do
		local w = steps[i].left + steps[i].right
		minWidth = math.min(minWidth, w)
		maxWidth = math.max(maxWidth, w)
	end
	local transition = last + 1
	if maxWidth - minWidth > 6 then
		local threshold = (minWidth + maxWidth) / 2
		local i = last
		while i >= first and steps[i].left + steps[i].right >= threshold do
			transition = i
			i -= 1
		end
	end

	-- One width per side per section, so every wall is straight. The MEDIAN,
	-- not the maximum: the bin that straddles the join between the walkway
	-- and the wide end platform reads platform-wide, and taking the max
	-- pushed the whole walkway's railing out to the platform's width (user,
	-- 2026-08-23 - the walkway's edges were left open with the wall metres
	-- away over the lava).
	local function medianOf(from: number, to: number, key: string): number
		local values = {}
		for i = from, to do
			table.insert(values, steps[i][key])
		end
		if #values == 0 then
			return 0
		end
		table.sort(values)
		return values[math.ceil(#values / 2)]
	end
	local hasPlatform = transition <= last
	local narrowTo = math.min(transition - 1, last)
	local narrowLeft = if narrowTo >= first then medianOf(first, narrowTo, "left") else 0
	local narrowRight = if narrowTo >= first then medianOf(first, narrowTo, "right") else 0
	local wideLeft = if hasPlatform then medianOf(transition, last, "left") else narrowLeft
	local wideRight = if hasPlatform then medianOf(transition, last, "right") else narrowRight
	if not hasPlatform then
		narrowLeft, narrowRight = wideLeft, wideRight
	end

	local bottom = steps[first].y
	for i = first, last do
		bottom = math.min(bottom, steps[i].y)
	end
	bottom -= 1
	local height = rim.wallHeight -- full walls, the same as the rim's

	local built = 0
	local function rail(a: Vector3, b: Vector3)
		local wall = wallBetween(parent, a, b, bottom, height)
		if wall then
			wall.Name = "PierRail"
			built += 1
		end
	end

	local startPoint = pointAt(steps[first].s - BIN / 2)
	local endPoint = pointAt(steps[last].s + BIN / 2)
	local transitionPoint = if hasPlatform then pointAt(steps[transition].s - BIN / 2) else endPoint

	for _, side in
		{
			{ sign = 1, narrow = narrowLeft, wide = wideLeft },
			{ sign = -1, narrow = narrowRight, wide = wideRight },
		}
	do
		local narrow = tangent * (side.sign * side.narrow)
		local wide = tangent * (side.sign * side.wide)
		-- The walkway's side, all the way from the rim stretch's end.
		rail(startPoint + narrow, transitionPoint + narrow)
		if hasPlatform then
			-- Step out to the platform, then along it.
			rail(transitionPoint + narrow, transitionPoint + wide)
			rail(transitionPoint + wide, endPoint + wide)
		end
	end
	-- The far end, where the deck actually stops.
	rail(endPoint + tangent * wideLeft, endPoint - tangent * wideRight)

	-- The measured centreline, for anything that needs the pier's real line
	-- rather than a radial guess.
	if data.pier then
		data.pier.axis = axis
		data.pier.rimEndPoint = startPoint
		data.pier.farEndPoint = endPoint
		data.pier.length = (endPoint - startPoint).Magnitude
		-- How far along from the rim end the wide platform begins.
		data.pier.platformFrom = if hasPlatform then (transitionPoint - startPoint).Magnitude else math.huge
		data.pier.measuredHalfWidth = math.max(narrowLeft, narrowRight)
		data.pier.platformHalfWidth = math.max(wideLeft, wideRight)
	end
	return built
end

local function buildBounds(parent: Instance)
	for id, island in placedModels do
		local entry = Islands.items[id]
		if entry and entry.rim then
			local data = sampleRim(id, entry, island)
			if data then
				-- Re-centre on the ring itself: the centroid of the inner-rim
				-- points is the crater's true centre; re-sample around it so
				-- every radius, the pier's azimuth and clampToBounds agree.
				local sum, count = Vector3.zero, 0
				for i = 1, data.samples do
					local r = data.inner[i]
					if r then
						local a = (i - 1) / data.samples * math.pi * 2
						sum += Vector3.new(data.center.X + math.cos(a) * r, 0, data.center.Z + math.sin(a) * r)
						count += 1
					end
				end
				if count > 0 then
					local centroid = sum / count
					local shift = (centroid - Vector3.new(data.center.X, 0, data.center.Z)).Magnitude
					if shift > 3 then
						local recentred =
							sampleRim(id, entry, island, Vector3.new(centroid.X, entry.worldPosition.Y, centroid.Z))
						if recentred then
							print(
								string.format(
									"[WorldService] Island %q: crater centre re-sampled at (%.0f, %.0f), %.0f studs from worldPosition.",
									id,
									centroid.X,
									centroid.Z,
									shift
								)
							)
							data = recentred
						end
					end
				end
				findPier(entry, island, data)
				-- Every dock part (planks, posts): the inner wall opens wherever
				-- these sit under it.
				data.dockParts = {}
				data.island = island
				data.deckY = entry.pier and entry.pier.deckY
				local names = {}
				for _, descendant in island:GetDescendants() do
					if descendant:IsA("BasePart") then
						table.insert(names, descendant.Name)
						if string.find(descendant.Name, "Dock", 1, true) then
							table.insert(data.dockParts, descendant)
						end
					end
				end
				-- So a mismatch between the generator's names and the import's
				-- is visible in Output instead of guessed at.
				print(string.format("[WorldService] Island %q parts: %s", id, table.concat(names, ", ")))
				bounds[id] = data
				local folder = Instance.new("Folder")
				folder.Name = "RimWalls_" .. id
				folder.Parent = parent
				buildRimWalls(folder, data)
				local rails = buildPierRailings(folder, data)
				if rails > 0 then
					print(string.format("[WorldService] Island %q: %d pier railing sections built.", id, rails))
				end
				print(
					string.format(
						"[WorldService] Island %q: rim bounds sampled (%d angles; %d anchored to the lava shore), walls built, "
							.. "%d inner-wall segments opened over the dock%s.",
						id,
						data.samples,
						data.shoreAnchored or 0,
						data.mouthSegments or 0,
						if #data.dockParts == 0 then " (no dock parts in this pack)" else ""
					)
				)
			end
		end
	end
end

-- The inner/outer edge radius at an arbitrary angle: interpolated between
-- the two neighbouring samples, or the nearest sampled value when the
-- angle falls in a notch (so a creature over a spillway is pulled back
-- onto the band, not dropped into the channel).
local function edgeAt(list, n: number, f: number): number?
	local i0 = math.floor(f) % n + 1
	local i1 = i0 % n + 1
	local t = f - math.floor(f)
	local v0, v1 = list[i0], list[i1]
	if v0 and v1 then
		return v0 + (v1 - v0) * t
	elseif v0 then
		return v0
	elseif v1 then
		return v1
	end
	for k = 1, n do
		local vA = list[((i0 - 1 - k) % n) + 1]
		local vB = list[((i0 - 1 + k) % n) + 1]
		if vA then
			return vA
		elseif vB then
			return vB
		end
	end
	return nil
end

-- Keeps `position` inside the playable area of whichever bounded island
-- it's near (only X/Z move; Y is untouched). Unbounded islands and open
-- sea return it unchanged. Used by CreatureService for every creature
-- position.
function WorldService.clampToBounds(position: Vector3): Vector3
	for _, data in bounds do
		local c = data.center
		local off = Vector3.new(position.X - c.X, 0, position.Z - c.Z)
		local r = off.Magnitude
		if r > 0.01 and r <= data.rim.maxRadius + 60 then
			local n = data.samples
			local angle = math.atan2(off.Z, off.X)
			if angle < 0 then
				angle += math.pi * 2
			end
			local f = angle / (math.pi * 2) * n
			local ri, ro = edgeAt(data.inner, n, f), edgeAt(data.outer, n, f)
			if not ri or not ro then
				return position
			end
			local m = data.rim.margin
			local rc = math.clamp(r, ri + m, math.max(ri + m, ro - m))
			local dir = off.Unit
			local best = Vector3.new(c.X + dir.X * rc, position.Y, c.Z + dir.Z * rc)

			-- The pier is a place you're allowed to be even though it hangs
			-- out over the lava, so a point on it is left where it is. Use the
			-- MEASURED centreline (buildPierRailings) when it's there: the
			-- deck is not radial about the crater centre - its axis line
			-- passes ~26 studs to one side - so the old "corridor out from the
			-- centre" model put the pier tens of studs off and flung anything
			-- landing on it back to the rim (2b, 2026-08-23: catches on the
			-- volcano ending up over the lava).
			local pier = data.pier
			if pier and pier.axis and pier.rimEndPoint then
				local axis = pier.axis
				local side = Vector3.new(-axis.Z, 0, axis.X)
				local fromEnd = Vector3.new(position.X - pier.rimEndPoint.X, 0, position.Z - pier.rimEndPoint.Z)
				local s = math.clamp(fromEnd:Dot(axis), 0, math.max(0, (pier.length or 0) - m))
				local halfW = (
					if s >= (pier.platformFrom or math.huge)
						then (pier.platformHalfWidth or 0)
						else (pier.measuredHalfWidth or 0)
				) - m
				if halfW > 0 then
					local t = math.clamp(fromEnd:Dot(side), -halfW, halfW)
					local onPier = Vector3.new(pier.rimEndPoint.X, position.Y, pier.rimEndPoint.Z) + axis * s + side * t
					if (onPier - position).Magnitude < (best - position).Magnitude then
						best = onPier
					end
				end
			elseif pier then
				-- Before the deck has been measured: the old radial guess.
				local side = Vector3.new(-pier.dir.Z, 0, pier.dir.X)
				local s = off:Dot(pier.dir)
				local t = off:Dot(side)
				local sc = math.clamp(s, pier.innerR + m, pier.outerR)
				local halfW = (if sc <= pier.innerR + pier.endLength then pier.endWidth / 2 else pier.width / 2) - m
				local tc = math.clamp(t, -halfW, halfW)
				local onPier = Vector3.new(c.X, position.Y, c.Z) + pier.dir * sc + side * tc
				if (onPier - position).Magnitude < (best - position).Magnitude then
					best = onPier
				end
			end
			return best
		end
	end
	return position
end

-- Which way is "inland" for a thrown catch landing near `target` - the side
-- it's safe to overshoot toward. On the starter that's toward the island's
-- centre at the origin (up the beach, back along the dock). On a bounded
-- island it's OUTWARD from the crater's centre: toward the centre is the
-- lava, outward is the rim (and along the pier, back toward the rim).
function WorldService.inlandDirection(target: Vector3): Vector3
	for _, data in bounds do
		local c = data.center
		local off = Vector3.new(target.X - c.X, 0, target.Z - c.Z)
		if off.Magnitude <= data.rim.maxRadius + 60 then
			return off
		end
	end
	-- No bounds cover this target - which is the NORMAL case for an island
	-- without a rim ring, the starter included. There "inland" is toward that
	-- island's own centre: you fish from the shore outward, so past the player
	-- is up the beach (and from the dock, back along the planks). Measured
	-- from the island's `worldPosition`, NOT the world origin: `-target` only
	-- held while the only island sat at (0, 0), and on any island placed
	-- elsewhere it points off across the map (2b, 2026-08-23 - it flung
	-- volcano catches into the lava).
	local nearest, nearestDist = nil, math.huge
	for _, entry in Islands.items do
		local p = entry.worldPosition
		local d = Vector3.new(target.X - p.X, 0, target.Z - p.Z).Magnitude
		if d < nearestDist then
			nearest, nearestDist = entry, d
		end
	end
	if nearest and nearestDist <= (nearest.radius or World.ISLAND_RADIUS) * 2 then
		return Vector3.new(nearest.worldPosition.X - target.X, 0, nearest.worldPosition.Z - target.Z)
	end

	-- Out at sea, far from anything: zero, so the caller uses its OWN
	-- fallback - overshoot along the bobber -> player line, which points out
	-- of the water toward the player and is right wherever they are.
	return Vector3.zero
end

-- Place every configured island whose mesh exists, recording which landed so
-- travel can be refused to ones not yet imported. A `site` entry (the
-- Maelstrom) is skipped in the ordered pass: it lives OUT of Islands.order
-- and builds through buildMaelstromSite below, which places the authored
-- mesh when imported (via placeIsland - safe now that the entry carries a
-- `model` name) and falls back to the procedural rock ring otherwise.
-- The Maelstrom: the finale SITE (site = true). The arena water - the dark
-- whirlpool disc, the fishable "Maelstrom_Water" surface (waters =
-- "maelstrom"; the name is the contract, never split it) - is ALWAYS built
-- procedurally here: MaelstromVfxController spins it by name, and it must be
-- a DIRECT child of the Instance named "Maelstrom" (the controller
-- WaitForChilds it, non-recursively).
--
-- The land around it comes in two flavours (2026-08-27, "build the complete
-- maelstrom island"): when the AUTHORED mesh exists
-- (ReplicatedStorage/Assets/Maelstrom, or the Maelstrom group of the
-- IslandPack - assets/island_gen.py "maelstrom": the drowned storm-shoal,
-- basalt fight stacks on the same r 38-52 ring, titan fangs, the doomed
-- fleet, chains, storm-fire), placeIsland drops it with the full island
-- treatment (MESH_COLOR, collide rules, the meshBottom pin) and the disc is
-- parented into that model. Before the import, the original procedural
-- stand-in - nine jagged rock platforms, a spawn platform on +Z, a crown of
-- outer spires, deterministically seeded - keeps the finale playable.
-- Marked `placed` either way so the shared ocean spans out to it and
-- mayEnter's placement check passes.
local function buildMaelstromSite(parent: Instance, id: string, entry): boolean
	local origin = Vector3.new(entry.worldPosition.X, 0, entry.worldPosition.Z)

	local hasMesh = islandTemplate(entry) ~= nil
	local container: Model
	if hasMesh then
		placeIsland(parent, id, entry)
		container = placedModels[id]
	else
		container = Instance.new("Model")
		container.Name = "Maelstrom"
	end

	local function rock(size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?): Part
		local p = Instance.new("Part")
		p.Anchored = true
		p.Size = size
		p.CFrame = cf
		p.Color = color
		p.Material = material or Enum.Material.Slate
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Parent = container
		return p
	end

	-- The whirlpool disc, slightly proud of the sea so it reads against the
	-- ocean plane. Non-collidable, like every fishable water.
	local water = rock(
		Vector3.new(0.6, 150, 150),
		CFrame.new(origin.X, World.WATER_Y + 0.12, origin.Z) * CFrame.Angles(0, 0, math.rad(90)),
		Color3.fromRGB(24, 32, 64),
		Enum.Material.SmoothPlastic
	)
	water.Name = "Maelstrom_Water"
	water.Shape = Enum.PartType.Cylinder
	water.CanCollide = false

	if hasMesh then
		-- The mesh brought the platforms/spires; nothing procedural to add.
		placed[id] = true
		return true
	end

	local rng = Random.new(180000)
	for i = 1, 9 do
		local angle = (i / 9) * math.pi * 2 + rng:NextNumber(-0.12, 0.12)
		local r = rng:NextNumber(38, 52)
		local x = origin.X + math.cos(angle) * r
		local z = origin.Z + math.sin(angle) * r
		local w = rng:NextNumber(14, 20)
		local topY = rng:NextNumber(3.4, 6.0)
		rock(
			Vector3.new(w, topY + 14, w * rng:NextNumber(0.8, 1.2)),
			CFrame.new(x, topY - (topY + 14) / 2, z) * CFrame.Angles(0, angle + rng:NextNumber(-0.4, 0.4), 0),
			Color3.fromRGB(46, 48, 60)
		)
		rock(
			Vector3.new(w * 0.35, 2.4, w * 0.3),
			CFrame.new(x + rng:NextNumber(-w / 3, w / 3), topY + 0.9, z + rng:NextNumber(-w / 3, w / 3))
				* CFrame.Angles(rng:NextNumber(-0.3, 0.3), angle, rng:NextNumber(-0.3, 0.3)),
			Color3.fromRGB(33, 34, 44)
		)
	end

	-- The spawn platform (+Z): matches the entry's spawn point.
	rock(Vector3.new(26, 18, 22), CFrame.new(origin.X, -4, origin.Z + 44), Color3.fromRGB(52, 54, 66))

	-- Outer spires: the storm's teeth on the horizon.
	for i = 1, 12 do
		local angle = (i / 12) * math.pi * 2 + rng:NextNumber(-0.2, 0.2)
		local r = rng:NextNumber(78, 110)
		local h = rng:NextNumber(18, 46)
		rock(
			Vector3.new(rng:NextNumber(5, 10), h, rng:NextNumber(5, 10)),
			CFrame.new(origin.X + math.cos(angle) * r, h / 2 - rng:NextNumber(2, 6), origin.Z + math.sin(angle) * r)
				* CFrame.Angles(rng:NextNumber(-0.1, 0.1), angle, rng:NextNumber(-0.1, 0.1)),
			Color3.fromRGB(40, 42, 54)
		)
	end

	container.Parent = parent
	placed[id] = true
	return true
end

local function loadIslands(parent: Instance)
	for _, id in Islands.order do
		local entry = Islands.items[id]
		if entry and not entry.site then
			placed[id] = placeIsland(parent, id, entry)
		end
	end
	-- Site entries (out of Islands.order, no mesh) build themselves: the
	-- Maelstrom's rock ring rises wherever its entry points.
	for id, entry in Islands.items do
		if entry.site and not placed[id] then
			buildMaelstromSite(parent, id, entry)
		end
	end
end

-- ============================================================ Spawn

-- The dock is part of the island mesh now (build_dock in island_gen.py), not
-- parts built here. The arena deck is still deliberately absent; its
-- constants stay in World.luau as the plan of record.

-- The sand's real height at the spawn point. The island is an imported mesh
-- whose dune profile has changed more than once, so a hand-typed Y in
-- World.luau goes stale and the character ends up starting inside the mesh
-- and falling out underneath it. Probe straight down instead; only
-- collidable parts count, so a palm canopy over the beach can't catch it.
-- `fromY` is where the probe starts; it must be ABOVE the ground you're
-- looking for (the volcano's rim is ~200 studs up, level with the default
-- World.SPAWN_PROBE_HEIGHT - a probe starting inside the rock finds nothing
-- or the wrong face). The ray runs down to well below the seabed.
local function groundHeightAt(x: number, z: number, parent: Instance, fromY: number?): number?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { parent }
	params.RespectCanCollide = true

	local top = math.max(fromY or 0, World.SPAWN_PROBE_HEIGHT)
	local origin = Vector3.new(x, top, z)
	local hit = Workspace:Raycast(origin, Vector3.new(0, -(top - World.SEABED_Y + 50), 0), params)
	if hit and hit.Instance.Name ~= World.OCEAN_NAME then
		return hit.Position.Y
	end
	return nil
end

-- Where a teleport to an island actually puts the character: the entry's
-- spawn X/Z, standing on whatever collidable ground is there RIGHT NOW
-- (probed from well above the entry's nominal Y), a few studs up so they
-- drop onto it. The hand-typed `spawn.Y` is only the fallback when nothing
-- solid is found - a typed Y goes stale the moment a mesh is regenerated
-- (the volcano's rim moved when it was shrunk to import), and a character
-- pivoted into rock falls straight through it (user, 2026-08-22: "drops
-- through the mountain"). Returns the point and whether ground was found.
local function islandSpawnPoint(entry, islandId): (CFrame, boolean)
	-- Prefer the real pier: stand on the rim just back from its mouth, FACING
	-- inward along it, so walking forward steps straight onto the dock. Read
	-- from the placed pier part (bounds[].pier), so the spawn is on the dock's
	-- side and facing it no matter how the mesh imported - a hand-typed spawn
	-- kept landing on the opposite side (user, 2026-08-23).
	local data = if islandId then bounds[islandId] else nil
	local pier = data and data.pier
	if pier and pier.dir and pier.outerR then
		-- Stand on the rim just back from the pier's mouth, facing inward along
		-- it, so forward steps onto the dock. Derived from the crater centre +
		-- the pier's radial direction.
		local c = data.center
		local standR = pier.outerR + 8
		local x = c.X + pier.dir.X * standR
		local z = c.Z + pier.dir.Z * standR
		local deckY = pier.deckY or 198
		local groundY = if islandFolder then groundHeightAt(x, z, islandFolder, deckY + 320) else nil
		local pos = Vector3.new(x, (groundY or deckY) + 5, z)
		local inward = Vector3.new(-pier.dir.X, 0, -pier.dir.Z)
		return CFrame.lookAt(pos, pos + inward), groundY ~= nil
	end

	local spawn = entry.spawn
	local groundY = if islandFolder then groundHeightAt(spawn.X, spawn.Z, islandFolder, spawn.Y + 300) else nil
	if groundY then
		return CFrame.new(spawn.X, groundY + 5, spawn.Z), true
	end
	return CFrame.new(spawn), false
end

local function buildSpawn(parent: Instance)
	local target = World.SPAWN_POSITION
	local groundY = groundHeightAt(target.X, target.Z, parent)
	if not groundY then
		warn(
			string.format(
				"[WorldService] Nothing to stand on at the spawn point (%.0f, %.0f); using World.SPAWN_POSITION's Y.",
				target.X,
				target.Z
			)
		)
	end

	-- Invisible: the player should just appear standing on the sand, not on a
	-- pad that breaks the island's shape. The pad sits just above the sand so
	-- the character is placed on its top face, clear of the mesh.
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "IslandSpawn"
	spawn.Size = Vector3.new(12, 1, 12)
	spawn.CFrame = CFrame.new(target.X, (groundY or target.Y) + spawn.Size.Y, target.Z)
	spawn.Anchored = true
	spawn.CanCollide = false
	spawn.Transparency = 1
	spawn.Neutral = true
	spawn.Duration = 0 -- no forcefield; there is nothing to be protected from yet
	spawn.Parent = parent

	-- A point a little above the sand, used as the recovery target for the
	-- under-the-map safety net in start().
	safeSpawn = Vector3.new(target.X, (groundY or target.Y) + 5, target.Z)
end

-- ============================================================ Under-map recovery

-- How far below the landform a character has to be before we call it "under
-- the map". Their root normally rides a couple of studs ABOVE the surface, so
-- anything past this is unambiguous.
local UNDER_MAP_CLEARANCE = 4

-- Is this character below the island's own surface?
--
-- Probe straight DOWN from high above the character's own X/Z against the
-- landform parts only, and compare heights. If the ground at your position is
-- above you, you are inside or beneath it.
--
-- This replaced an "island overhead AND ocean below" pair of rays, which
-- missed the cases that actually happen (user, 2026-08-22 - fell through a
-- collision seam near the rock arch and was not recovered):
--   * mid-fall, or wedged in a seam, there is often nothing solid directly
--     overhead, so the up-ray found sky and the net stood down;
--   * the ocean is a 4-stud-thick slab, so anyone below y = -4 under the
--     island had the ocean's underside overhead and was dismissed outright.
-- Comparing against the surface has neither blind spot, and catches falling
-- through the terrain AND swimming in under the skirt with one test.
--
-- Probing `baseParts` and not the whole island is what keeps the legitimate
-- walkable rock arch safe: under the arch the probe passes the rock and finds
-- the grass you are standing ON, so you read as above the surface.
local function isUnderMap(position: Vector3): boolean
	if #baseParts == 0 then
		return false
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = baseParts
	params.RespectCanCollide = true -- ignores fronds / foam / seabed (non-collidable)

	-- Start well above the highest terrain so the probe always begins in open
	-- air, even when the character is standing on the island's peak.
	local from = Vector3.new(position.X, position.Y + 300, position.Z)
	local hit = Workspace:Raycast(from, Vector3.new(0, -600, 0), params)
	if not hit then
		return false -- no landform at this X/Z at all: open sea, or off the map
	end
	return position.Y < hit.Position.Y - UNDER_MAP_CLEARANCE
end

-- ============================================================ Travel

-- The gate-free move: put the player onto an island's spawn point. Checks only
-- that the island exists, its mesh is placed, and the character is ready - NOT
-- the level/boss unlocks. handleTeleport calls this after its gates; the admin
-- travel (AdminService) calls it directly to skip them. Returns ok, reason.
function WorldService.teleportToIsland(player: Player, islandId: any): (boolean, string?)
	if type(islandId) ~= "string" then
		return false, "Unknown island"
	end
	local entry = Islands.items[islandId]
	if not entry then
		return false, "Unknown island"
	end
	if not placed[islandId] then
		return false, "Not open yet"
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not (root and root:IsA("BasePart")) then
		return false, "Not ready"
	end
	local cframe, grounded = islandSpawnPoint(entry, islandId)
	if not grounded then
		warn(
			string.format(
				"[WorldService] Nothing collidable under island %q's spawn (%.0f, %.0f); using its typed Y %.0f. "
					.. "Check the mesh's CollisionFidelity (assets/README.md) and Islands.luau's spawn.",
				islandId,
				cframe.Position.X,
				cframe.Position.Z,
				cframe.Position.Y
			)
		)
	end
	-- Kill any momentum from the trip over, so a mid-fall travel doesn't
	-- carry its speed into the new ground.
	root.AssemblyLinearVelocity = Vector3.zero
	character:PivotTo(cframe)
	return true
end

-- The island whose footprint contains `position`, or nil for open sea. The
-- one footprint rule lives in Islands.islandAt (shared with the client's
-- raid HUD); this alias just keeps the service-side callers reading well.
function WorldService.islandAt(position: Vector3, margin: number?): (string?, any)
	return Islands.islandAt(position, margin)
end

-- EVERY way onto an island funnels through this one gate: the teleport menu,
-- and (via the containment sweep below) simply arriving - by boat, or walking
-- the solid ocean slab. Checks the island exists, its mesh is placed, the
-- player's level clears the unlock, the PREVIOUS island's boss is beaten
-- (`Cleared_<prevId>`, set by BossService), and - Session 3 - the player's
-- boat is seaworthy enough for the crossing: island N+1 in Islands.order
-- needs BoatTier >= N (the plan's "boat tier N unlocks crossing to N+1").
-- Returns ok plus a player-facing reason when not.
function WorldService.mayEnter(player: Player, islandId: any): (boolean, string?)
	if type(islandId) ~= "string" then
		return false, "Unknown island"
	end
	local entry = Islands.items[islandId]
	if not entry then
		return false, "Unknown island"
	end
	if not placed[islandId] then
		return false, "Not open yet"
	end

	local level = player:GetAttribute(Progression.ATTR.level) or Progression.START_LEVEL
	if level < entry.unlockLevel then
		return false, string.format("Reach level %d", entry.unlockLevel)
	end

	-- A site entry (the Maelstrom) sits outside Islands.order, so the linear
	-- chain below never sees it: its gate is every island boss's heart, plus
	-- the last boat (the plan's Stormbreaker Keel unlocks the crossing).
	if entry.site then
		for _, orderedId in Islands.order do
			local ordered = Islands.items[orderedId]
			if ordered and ordered.boss and player:GetAttribute("Heart_" .. ordered.boss) ~= true then
				return false, "Claim every island boss's heart first"
			end
		end
		local finalTier = #Islands.order
		local tier = player:GetAttribute("BoatTier") or 0
		if tier < finalTier then
			local wanted = Boats.byTier[finalTier]
			return false,
				if wanted
					then string.format("Only the %s survives that crossing", wanted.name)
					else string.format("You need a tier-%d boat for that crossing", finalTier)
		end
		return true
	end

	local index = table.find(Islands.order, islandId)
	if index and index > 1 then
		local prevId = Islands.order[index - 1]
		local prevEntry = Islands.items[prevId]
		local boss = prevEntry and prevEntry.boss and Bosses.items[prevEntry.boss]
		if boss and player:GetAttribute("Cleared_" .. prevId) ~= true then
			return false, string.format("Defeat %s first", boss.shortName)
		end

		local neededTier = index - 1
		local tier = player:GetAttribute("BoatTier") or 0
		if tier < neededTier then
			local wanted = Boats.byTier[neededTier]
			return false,
				if wanted and wanted.recipe
					then string.format("Craft the %s first", wanted.name)
					else string.format("You need a boat for that crossing (tier %d)", neededTier)
		end
	end

	return true
end

-- XZ distance from `position` to the shoreline of the nearest island this
-- player may enter (negative inside the shoreline). The boat's seaworthiness
-- check (BoatService): open water only starts counting past the coast of
-- somewhere you're allowed to be, so a legal crossing measures at most half
-- the island spacing while a locked destination gives you no shelter.
function WorldService.openSeaDistance(player: Player, position: Vector3): number
	local best = math.huge
	for id, entry in Islands.items do
		if placed[id] and WorldService.mayEnter(player, id) then
			local d = Vector3.new(position.X - entry.worldPosition.X, 0, position.Z - entry.worldPosition.Z).Magnitude
				- entry.radius
			best = math.min(best, d)
		end
	end
	return best
end

-- Where a summoned boat surfaces: just off the coast the player is nearest,
-- bow out to sea. On an island that's a push from the centre out past the
-- shoreline; on open water (walking the slab, or re-summoning after a sink)
-- it's simply a few studs ahead of the character.
function WorldService.boatLaunchCFrame(player: Player): CFrame?
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return nil
	end
	local position = root.Position
	local id, entry = WorldService.islandAt(position, 160)
	local outward
	local at
	if id then
		local centre = Vector3.new(entry.worldPosition.X, 0, entry.worldPosition.Z)
		local flat = Vector3.new(position.X, 0, position.Z)
		outward = flat - centre
		outward = if outward.Magnitude > 1 then outward.Unit else Vector3.zAxis
		-- Past the coastline wobble and any dock: the shoreline radius plus a
		-- clear margin, but never behind where the player already stands.
		local r = math.max(entry.radius + 30, (flat - centre).Magnitude + 12)
		at = centre + outward * r
	else
		outward = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
		outward = if outward.Magnitude > 0.05 then outward.Unit else Vector3.zAxis
		at = Vector3.new(position.X, 0, position.Z) + outward * 14
	end

	-- The coastline wobbles and rocks crowd some shores: if the chosen spot
	-- still has LAND under it (a down-probe that hits anything of the world
	-- besides the sea), keep stepping seaward before anchoring a hull inside
	-- a boulder (review find). Four tries, then take the last point anyway -
	-- open ocean at worst.
	if islandFolder then
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { islandFolder }
		params.RespectCanCollide = true
		for _ = 1, 4 do
			local hit = Workspace:Raycast(Vector3.new(at.X, 300, at.Z), Vector3.new(0, -400, 0), params)
			if not hit or hit.Instance.Name == World.OCEAN_NAME then
				break
			end
			at += outward * 15
		end
	end

	return CFrame.lookAt(Vector3.new(at.X, World.WATER_Y, at.Z), Vector3.new(at.X, World.WATER_Y, at.Z) + outward)
end

-- Move a player to an island, server-authoritatively. Re-checks everything the
-- menu shows (mayEnter, above) so a hacked client can't reach an island it
-- shouldn't. Replies on TeleportResult either way so the menu can show why it
-- was refused.
local function handleTeleport(player: Player, islandId: any)
	local allowed, why = WorldService.mayEnter(player, islandId)
	if not allowed then
		Remotes.TeleportResult:FireClient(player, { ok = false, islandId = islandId, reason = why })
		return
	end

	local ok, reason = WorldService.teleportToIsland(player, islandId)
	if ok then
		Remotes.TeleportResult:FireClient(player, { ok = true, islandId = islandId })
	else
		Remotes.TeleportResult:FireClient(
			player,
			{ ok = false, islandId = islandId, reason = reason or "Can't travel there" }
		)
	end
end

-- ============================================================ Lifecycle

-- The place template ships a 2048-stud Baseplate whose top face sits at
-- exactly y = 0 - coplanar with the water surface - so its grid texture
-- z-fights up through the ocean as a "blue grid floor". Nothing here stands
-- on it; the island mesh and the seabed are the ground.
--
-- It also ships a SpawnLocation on that baseplate at the origin - which is
-- now *inside* the island mesh. Roblox picks randomly between every neutral
-- SpawnLocation in the place, so leaving it meant spawning under the island
-- about half the time. Every SpawnLocation that isn't ours goes; the only
-- spawn is the one buildSpawn puts on the sand.
local function removeTemplateLeftovers()
	local baseplate = Workspace:FindFirstChild("Baseplate")
	if baseplate then
		baseplate:Destroy()
	end

	for _, descendant in Workspace:GetDescendants() do
		if descendant:IsA("SpawnLocation") then
			warn(
				string.format(
					"[WorldService] Removing stray SpawnLocation %q from the place file.",
					descendant:GetFullName()
				)
			)
			descendant:Destroy()
		end
	end
end

function WorldService.init()
	buildLighting()
	removeTemplateLeftovers()

	islandFolder = Instance.new("Folder")
	islandFolder.Name = World.FOLDER_NAME -- CastAim raycasts against this folder
	islandFolder.Parent = Workspace

	-- Before anything is built: the groups that make the barriers one-way.
	registerCollisionGroups()

	-- Islands first so the ocean can be sized to cover whichever ones placed.
	loadIslands(islandFolder)
	buildBounds(islandFolder) -- samples the placed meshes; needs them in Workspace
	buildOcean(islandFolder)
	buildSpawn(islandFolder)

	Remotes.RequestTeleport.OnServerEvent:Connect(handleTeleport)
end

-- Where the under-map net lifts a character to: the spawn of the island
-- they're under (nearest placed island by X/Z), standing on its real ground
-- - NOT always the starter's, which is what sent a player who fell through
-- the volcano straight back to Starter Cove (user, 2026-08-22: "teleports
-- me back to the regular island"). If that island has no standable ground
-- at its spawn (mesh without collision), the net would just drop them
-- through again every half-second, so it falls back to the starter.
local function recoveryPoint(position: Vector3): CFrame?
	local bestEntry, bestId, bestDist = nil, nil, math.huge
	for id, entry in Islands.items do
		if placed[id] then
			local d = (Vector3.new(position.X, 0, position.Z) - Vector3.new(
				entry.worldPosition.X,
				0,
				entry.worldPosition.Z
			)).Magnitude
			if d < bestDist then
				bestEntry, bestId, bestDist = entry, id, d
			end
		end
	end
	if bestEntry then
		local cframe, grounded = islandSpawnPoint(bestEntry, bestId)
		if grounded then
			return cframe
		end
	end
	return if safeSpawn then CFrame.new(safeSpawn) else nil
end

-- Where the containment sweep sends a trespasser: the spawn of the nearest
-- island they're actually allowed on, falling back to the starter spawn.
local function bounceTarget(player: Player, position: Vector3): CFrame?
	local bestEntry, bestId, bestDist = nil, nil, math.huge
	for id, entry in Islands.items do
		if placed[id] and WorldService.mayEnter(player, id) then
			local d = (Vector3.new(position.X, 0, position.Z) - Vector3.new(
				entry.worldPosition.X,
				0,
				entry.worldPosition.Z
			)).Magnitude
			if d < bestDist then
				bestEntry, bestId, bestDist = entry, id, d
			end
		end
	end
	if bestEntry then
		local cframe, grounded = islandSpawnPoint(bestEntry, bestId)
		if grounded then
			return cframe
		end
	end
	return if safeSpawn then CFrame.new(safeSpawn) else nil
end

function WorldService.start()
	-- Two safety sweeps in one loop, a ray or two per player, twice a second:
	--   - the under-map net ("walked under the island and got stuck"): lift a
	--     character beneath the landform back onto that island's spawn;
	--   - the containment sweep (Session 3): a player inside an island's
	--     footprint who fails mayEnter is bounced to the nearest island they
	--     ARE allowed on. This closes the walk-on-the-solid-ocean hole and
	--     makes sailing and teleporting one rule - the boat doesn't need its
	--     own gate checks. Admins are exempt (AdminTeleport skips gates by
	--     design, and the sweep must not fight it).
	task.spawn(function()
		while true do
			task.wait(0.5)
			for _, player in Players:GetPlayers() do
				local character = player.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				if root and root:IsA("BasePart") then
					if isUnderMap(root.Position) then
						-- Non-admins recover to somewhere they're ALLOWED:
						-- lifting a trespasser onto the locked island they
						-- were under just hands them to the containment
						-- sweep for a second teleport (review find). Admins
						-- keep the nearest-island lift (AdminTeleport walks
						-- locked islands by design).
						local target
						if player:GetAttribute("IsAdmin") == true then
							target = recoveryPoint(root.Position)
						else
							target = bounceTarget(player, root.Position) or recoveryPoint(root.Position)
						end
						if target then
							root.AssemblyLinearVelocity = Vector3.zero
							character:PivotTo(target)
						end
					elseif player:GetAttribute("IsAdmin") ~= true then
						-- Only a PLACED island's footprint is enforceable
						-- ground: before its mesh imports, the footprint is
						-- open sea, and bouncing someone sailing across it
						-- would punish legal water (review find).
						local islandId = WorldService.islandAt(root.Position)
						if islandId and placed[islandId] and not WorldService.mayEnter(player, islandId) then
							local target = bounceTarget(player, root.Position)
							if target then
								-- A seated character is welded to the seat, and
								-- Sit = false does NOT kill that weld in the same
								-- step - pivoting through it would drag the whole
								-- (driver-owned) boat to the bounce target, or be
								-- clobbered by the driver's replication. Break the
								-- SeatWeld explicitly, then move the character a
								-- step later, once it's a free assembly again.
								local humanoid = character:FindFirstChildOfClass("Humanoid")
								local seatPart = humanoid and humanoid.SeatPart
								if seatPart then
									humanoid.Sit = false
									local weld = seatPart:FindFirstChild("SeatWeld")
									if weld then
										weld:Destroy()
									end
									task.defer(function()
										if character.Parent and root.Parent then
											root.AssemblyLinearVelocity = Vector3.zero
											character:PivotTo(target)
										end
									end)
								else
									root.AssemblyLinearVelocity = Vector3.zero
									character:PivotTo(target)
								end
							end
						end
					end
				end
			end
		end
	end)
end

return WorldService
