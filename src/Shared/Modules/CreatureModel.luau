--!nonstrict
-- CreatureModel.luau
-- Builds the visual Model for a creature row: picks the row's species out
-- of the shared FishPack under ReplicatedStorage/Assets (or a parts
-- stand-in if it hasn't been imported yet), recolours it from the row's
-- body block, and scales it.
--
-- The pack holds every species side by side as <Species>_Body / _Fins /
-- _Eyes / _Marks (assets/fish_gen.py). Those get cloned out and renamed to
-- the generic Fish_Body / Fish_Fins / Fish_Eyes / Fish_Marks, so everything
-- downstream - CreatureService's physics, the hit feedback, the VFX - keeps
-- looking for one set of names no matter which fish it is. A row with no
-- `species` clones its template whole, the way the single generic fish
-- used to work.
--
-- Same shape as RodModel: one builder, one fallback, one place that knows
-- the mesh's part names. Lives in Shared rather than the server because the
-- client will want to build the same thing for pooled previews later (the
-- Bestiary, an inventory icon); nothing on the client uses it yet.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local World = require(ReplicatedStorage:WaitForChild("Shared").Config.World)

local CreatureModel = {}

-- Nose-to-tail length of the authored template, before a row's scale.
-- Must match BODY_LENGTH in assets/fish_gen.py.
CreatureModel.BASE_LENGTH = 2.0

-- Note on orientation: the imported mesh's axes proved unpredictable (the
-- fish surfaced side-on, then upright, under two different guesses), so
-- CreatureService no longer assumes a nose direction at all - it reads the
-- longest/shortest bounding-box axes to lay the fish flat. Nothing here
-- needs to name an axis. Keep the fallback stand-in's proportions
-- (long = Z, short = X) so that same detection works on it too.

local EYE_COLOR = Color3.fromRGB(12, 12, 16)

-- The part suffixes every species is built from; the recolour contract.
local PART_SUFFIXES = { "Body", "Fins", "Eyes", "Marks" }

local warnedMissing = {}

local function colorParts(model: Model, body)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			local color
			if descendant.Name == "Fish_Body" then
				color = body.color
			elseif descendant.Name == "Fish_Fins" then
				color = body.finColor
			elseif descendant.Name == "Fish_Eyes" then
				color = EYE_COLOR
			elseif descendant.Name == "Fish_Marks" then
				-- Markings default to a darker body tone if the row doesn't
				-- say, so a species with marks never shows raw import colour.
				color = body.markColor or body.color:Lerp(Color3.new(0, 0, 0), 0.45)
			end
			if color then
				descendant.Color = color
				descendant.Material = Enum.Material.SmoothPlastic
				local appearance = descendant:FindFirstChildWhichIsA("SurfaceAppearance")
				if appearance then
					appearance:Destroy()
				end
			end
		end
	end
end

-- A stand-in with the same part names as the real mesh: an elongated ball
-- for the body and a flat block for the tail. Nose along -Z like the mesh.
local function buildFallback(body, reason: string): Model
	local key = body.model .. "/" .. tostring(body.species)
	if not warnedMissing[key] then
		warnedMissing[key] = true
		warn(
			string.format(
				"[CreatureModel] %s.\n"
					.. "  Import it once: Studio > Home > Import > assets/fish.glb,\n"
					.. "  then move the imported model to ReplicatedStorage/Assets and name it '%s'\n"
					.. "  (every species is in that one file). See assets/README.md.\n"
					.. "  Using a plain stand-in until then.",
				reason,
				body.model
			)
		)
	end

	local model = Instance.new("Model")
	model.Name = body.model

	local fish = Instance.new("Part")
	fish.Name = "Fish_Body"
	fish.Shape = Enum.PartType.Ball
	fish.Size = Vector3.new(0.5, 0.55, CreatureModel.BASE_LENGTH)
	fish.CFrame = CFrame.new(0, 0, 0)
	fish.Parent = model

	local tail = Instance.new("Part")
	tail.Name = "Fish_Fins"
	tail.Size = Vector3.new(0.05, 0.7, 0.45)
	tail.CFrame = CFrame.new(0, 0, CreatureModel.BASE_LENGTH / 2 + 0.15)
	tail.Parent = model

	return model
end

-- A procedural pufferfish, built from parts so it needs no mesh import: a
-- chunky body ringed with spines. Part names are the same Fish_* contract as
-- the pack, so colorParts recolours it (body.color / finColor) and the throw
-- welds catch it.
--
-- The body is deliberately elongated (Z clearly longest, then X, then Y) and
-- every axis gets an on-axis spine of equal length, so the bounding box the
-- spines produce keeps that same Z > X > Y ordering. CreatureService reads
-- that ordering to lay the fish flat (long axis = nose-tail, short axis = up),
-- so a too-round puffer would surface on its side - the elongation is what
-- keeps it belly-down and pointed the right way.
-- `spikeLength` is the puffer's 0.5 by default; the urchin reuses this
-- builder with longer spines (every axis gets one, so the ordering holds).
local function buildPuffer(body, spikeLength: number?): Model
	local model = Instance.new("Model")
	model.Name = body.model

	local bodyPart = Instance.new("Part")
	bodyPart.Name = "Fish_Body"
	bodyPart.Shape = Enum.PartType.Ball
	bodyPart.Size = Vector3.new(1.5, 1.15, 2.1) -- X mid, Y short (belly-down), Z long (nose-tail)
	bodyPart.CFrame = CFrame.new()
	bodyPart.Parent = model

	local half = bodyPart.Size / 2
	local SPIKE_LEN = spikeLength or 0.5

	-- Spine directions: three latitude rings of six, offset alternately, plus a
	-- spine at each pole and one at the nose and tail. The poles (Y) and
	-- nose/tail (Z) guarantee every axis has an on-axis spine of the same
	-- length, so the spines extend all three axes equally and the body's
	-- Z > X > Y ordering carries through to the bounding box.
	local dirs = {}
	for _, latDeg in { -35, 0, 35 } do
		local lat = math.rad(latDeg)
		for i = 0, 5 do
			local lon = (i / 6) * math.pi * 2 + (if latDeg == 0 then 0 else math.pi / 6)
			table.insert(dirs, Vector3.new(math.cos(lat) * math.cos(lon), math.sin(lat), math.cos(lat) * math.sin(lon)))
		end
	end
	table.insert(dirs, Vector3.yAxis)
	table.insert(dirs, -Vector3.yAxis)
	table.insert(dirs, Vector3.zAxis)
	table.insert(dirs, -Vector3.zAxis)

	for _, dir in dirs do
		local d = dir.Unit
		-- The point on the body's surface along d, then jut the spine out past it.
		local surface = Vector3.new(d.X * half.X, d.Y * half.Y, d.Z * half.Z)
		local spike = Instance.new("Part")
		spike.Name = "Fish_Fins"
		spike.Shape = Enum.PartType.Cylinder -- length runs along its local X
		spike.Size = Vector3.new(SPIKE_LEN, 0.16, 0.16)
		local up = if math.abs(d.Y) < 0.99 then Vector3.yAxis else Vector3.xAxis
		local perp = d:Cross(up).Unit
		spike.CFrame = CFrame.fromMatrix(surface + d * (SPIKE_LEN / 2 - 0.05), d, perp)
		spike.Parent = model
	end

	-- Eyes near the nose (+Z), up and to the sides.
	for _, sx in { -1, 1 } do
		local eye = Instance.new("Part")
		eye.Name = "Fish_Eyes"
		eye.Shape = Enum.PartType.Ball
		eye.Size = Vector3.new(0.3, 0.3, 0.3)
		eye.CFrame = CFrame.new(sx * 0.4, 0.32, 0.86)
		eye.Parent = model
	end

	return model
end

-- A procedural crab, built from parts (no import). Like the puffer it uses
-- the Fish_* name contract and lies FLAT (bbox path): it is built length > width
-- > height (Z the single longest axis, Y the shortest) so CreatureService's
-- flatOrientation reads +Z as nose-tail and lays it belly-down - and the claws
-- reach forward along +Z so it charges the player claws-first (rusher).
local function buildCrab(body): Model
	local model = Instance.new("Model")
	model.Name = body.model

	local shell = Instance.new("Part")
	shell.Name = "Fish_Body"
	shell.Shape = Enum.PartType.Ball
	shell.Size = Vector3.new(1.9, 0.8, 2.3) -- X width, Y short (up), Z long (forward)
	shell.CFrame = CFrame.new()
	shell.Parent = model

	-- Two claws reaching forward (+Z), one per side: an arm block + a chunky
	-- pincer. They push the +Z extent well past the width so the charge axis
	-- is unambiguous.
	for _, sx in { -1, 1 } do
		local arm = Instance.new("Part")
		arm.Name = "Fish_Fins"
		arm.Size = Vector3.new(0.42, 0.42, 1.2)
		arm.CFrame = CFrame.new(sx * 0.8, 0.0, 1.45)
		arm.Parent = model

		local claw = Instance.new("Part")
		claw.Name = "Fish_Fins"
		claw.Size = Vector3.new(0.6, 0.75, 0.75)
		claw.CFrame = CFrame.new(sx * 0.8, 0.0, 2.3)
		claw.Parent = model
	end

	-- Three legs per side, thin, angled out and a little down. Kept short so
	-- the total width stays under the length.
	for _, sx in { -1, 1 } do
		for i = 0, 2 do
			local leg = Instance.new("Part")
			leg.Name = "Fish_Fins"
			leg.Shape = Enum.PartType.Cylinder -- length runs along local X
			leg.Size = Vector3.new(0.65, 0.13, 0.13)
			local out = Vector3.new(sx, -0.4, 0).Unit
			local perp = out:Cross(Vector3.zAxis).Unit
			leg.CFrame = CFrame.fromMatrix(Vector3.new(sx * 0.85, -0.1, 0.6 - i * 0.65), out, perp)
			leg.Parent = model
		end
	end

	-- Eyes on short stalks up front.
	for _, sx in { -1, 1 } do
		local eye = Instance.new("Part")
		eye.Name = "Fish_Eyes"
		eye.Shape = Enum.PartType.Ball
		eye.Size = Vector3.new(0.26, 0.26, 0.26)
		eye.CFrame = CFrame.new(sx * 0.32, 0.5, 0.95)
		eye.Parent = model
	end

	return model
end

-- A procedural upright biped (the drowned zombies), built from parts. Unlike
-- the fish it is authored **Y-up** (feet down, head up) and spawned with
-- body.stance = "upright", so CreatureService stands it as-built instead of
-- laying it flat. The torso is the Fish_Body PrimaryPart; skin/limbs take
-- body.color, the coat/hat/gaff take finColor (Fish_Fins). Arms reach forward
-- so it reads as a shambling zombie.
local function buildZombie(body): Model
	local model = Instance.new("Model")
	model.Name = body.model

	-- Torso (PrimaryPart). Everything is positioned around it in Y.
	local torso = Instance.new("Part")
	torso.Name = "Fish_Body"
	torso.Size = Vector3.new(1.1, 1.5, 0.55)
	torso.CFrame = CFrame.new(0, 0.25, 0)
	torso.Parent = model

	local head = Instance.new("Part")
	head.Name = "Fish_Body"
	head.Shape = Enum.PartType.Ball
	head.Size = Vector3.new(0.72, 0.78, 0.72)
	head.CFrame = CFrame.new(0, 1.4, 0)
	head.Parent = model

	-- Arms reaching forward (+Z) at shoulder height.
	for _, sx in { -1, 1 } do
		local arm = Instance.new("Part")
		arm.Name = "Fish_Body"
		arm.Size = Vector3.new(0.3, 0.3, 1.25)
		arm.CFrame = CFrame.new(sx * 0.58, 0.85, 0.55)
		arm.Parent = model
	end

	-- Legs down to the feet.
	for _, sx in { -1, 1 } do
		local leg = Instance.new("Part")
		leg.Name = "Fish_Body"
		leg.Size = Vector3.new(0.4, 1.5, 0.42)
		leg.CFrame = CFrame.new(sx * 0.3, -1.05, 0)
		leg.Parent = model
	end

	-- Coat slab over the torso front + a soft hat: the accent (finColor).
	local coat = Instance.new("Part")
	coat.Name = "Fish_Fins"
	coat.Size = Vector3.new(1.2, 1.7, 0.18)
	coat.CFrame = CFrame.new(0, 0.1, 0.33)
	coat.Parent = model

	local brim = Instance.new("Part")
	brim.Name = "Fish_Fins"
	brim.Shape = Enum.PartType.Cylinder
	brim.Size = Vector3.new(0.16, 1.0, 1.0)
	brim.CFrame = CFrame.new(0, 1.78, 0.02) * CFrame.Angles(0, 0, math.rad(90))
	brim.Parent = model

	local crown = Instance.new("Part")
	crown.Name = "Fish_Fins"
	crown.Size = Vector3.new(0.62, 0.4, 0.62)
	crown.CFrame = CFrame.new(0, 1.98, 0.02)
	crown.Parent = model

	-- A gaff held in the forward-reaching right hand: a long pole + a hook.
	local pole = Instance.new("Part")
	pole.Name = "Fish_Fins"
	pole.Size = Vector3.new(0.11, 2.1, 0.11)
	pole.CFrame = CFrame.new(0.58, 0.75, 1.05)
	pole.Parent = model

	local hook = Instance.new("Part")
	hook.Name = "Fish_Fins"
	hook.Size = Vector3.new(0.5, 0.12, 0.12)
	hook.CFrame = CFrame.new(0.78, 1.75, 1.05)
	hook.Parent = model

	-- Eyes.
	for _, sx in { -1, 1 } do
		local eye = Instance.new("Part")
		eye.Name = "Fish_Eyes"
		eye.Shape = Enum.PartType.Ball
		eye.Size = Vector3.new(0.16, 0.16, 0.16)
		eye.CFrame = CFrame.new(sx * 0.18, 1.46, 0.34)
		eye.Parent = model
	end

	return model
end

-- ============================================================ enemy stand-ins (2026-08-22)
-- Procedural parts for the eight new enemies, so each is testable before
-- its CreaturePack species is authored (art slice). Same Fish_* contract,
-- same orientation rules: a FLAT creature is authored front along +Z with
-- Z the single longest bbox axis and Y the shortest (so flatOrientation
-- lays it belly-down, nose forward); an UPRIGHT one (row stance) is Y-up as
-- built. Fish_Body takes the row's `color`, Fish_Fins `finColor`, Fish_Marks
-- `markColor`. Every builder's bbox ordering is noted at its top - keep it.

local function addPart(model: Model, name: string, shape: Enum.PartType, size: Vector3, cframe: CFrame): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = shape
	part.Size = size
	part.CFrame = cframe
	part.Parent = model
	return part
end

local BALL = Enum.PartType.Ball
local BLOCK = Enum.PartType.Block
local CYLINDER = Enum.PartType.Cylinder -- its length runs along local X

-- A cylinder standing on end (axis along world Y) centred at `at`.
local function upright(at: Vector3): CFrame
	return CFrame.new(at) * CFrame.Angles(0, 0, math.rad(90))
end

-- A limb cylinder from `base` pointing along `direction` for `length`.
local function limb(model: Model, name: string, base: Vector3, direction: Vector3, length: number, radius: number): Part
	local d = direction.Unit
	local up = if math.abs(d.Y) < 0.99 then Vector3.yAxis else Vector3.xAxis
	local perp = d:Cross(up).Unit
	return addPart(
		model,
		name,
		CYLINDER,
		Vector3.new(length, radius, radius),
		CFrame.fromMatrix(base + d * (length / 2), d, perp)
	)
end

local function eyes(model: Model, radius: number, x: number, y: number, z: number)
	for _, sx in { -1, 1 } do
		addPart(model, "Fish_Eyes", BALL, Vector3.new(radius, radius, radius), CFrame.new(sx * x, y, z))
	end
end

-- Tideline Skipper: a slim fish on four stilt legs. Flat; bbox Z 2.9 > X 1.5 > Y 1.2.
local function buildSkipper(body): Model
	local model = Instance.new("Model")
	model.Name = body.model
	addPart(model, "Fish_Body", BALL, Vector3.new(0.7, 0.6, 2.4), CFrame.new())
	addPart(model, "Fish_Body", BALL, Vector3.new(0.8, 0.7, 0.8), CFrame.new(0, 0.05, 0.95)) -- head
	addPart(model, "Fish_Fins", BLOCK, Vector3.new(0.06, 0.4, 1.0), CFrame.new(0, 0.38, -0.2)) -- dorsal sail
	addPart(model, "Fish_Fins", BLOCK, Vector3.new(0.05, 0.5, 0.45), CFrame.new(0, 0, -1.35)) -- tail
	addPart(model, "Fish_Marks", BLOCK, Vector3.new(0.72, 0.08, 1.6), CFrame.new(0, -0.28, 0.1)) -- belly stripe
	for _, sx in { -1, 1 } do
		for _, z in { 0.6, -0.6 } do
			limb(model, "Fish_Fins", Vector3.new(sx * 0.3, -0.2, z), Vector3.new(sx, -0.7, 0), 0.55, 0.14)
		end
	end
	eyes(model, 0.22, 0.28, 0.38, 1.1)
	return model
end

-- Gullet Cod: a fat cod with a gaping dark maw. Flat; bbox Z 3.5 > X 2.2 > Y 1.5.
local function buildGulletCod(body): Model
	local model = Instance.new("Model")
	model.Name = body.model
	addPart(model, "Fish_Body", BALL, Vector3.new(1.3, 1.1, 2.6), CFrame.new())
	addPart(model, "Fish_Body", BALL, Vector3.new(1.4, 0.9, 1.4), CFrame.new(0, -0.25, 0.2)) -- belly
	addPart(model, "Fish_Marks", BALL, Vector3.new(1.0, 0.8, 0.8), CFrame.new(0, -0.1, 1.35)) -- the maw
	addPart(model, "Fish_Fins", BLOCK, Vector3.new(0.06, 0.45, 0.9), CFrame.new(0, 0.6, -0.1)) -- dorsal
	for _, sx in { -1, 1 } do
		addPart(model, "Fish_Fins", BLOCK, Vector3.new(0.5, 0.06, 0.4), CFrame.new(sx * 0.85, -0.1, 0.5)) -- pectorals
	end
	addPart(model, "Fish_Fins", BLOCK, Vector3.new(0.06, 0.7, 0.5), CFrame.new(0, 0, -1.5)) -- tail
	eyes(model, 0.26, 0.5, 0.3, 1.0)
	return model
end

-- Moonbell Jelly: a translucent bell over trailing tendrils. UPRIGHT (the row
-- sets stance), authored Y-up with the bell as the body; the tendril tips are
-- the lowest point, so the bell rides high off the ground.
local function buildJelly(body): Model
	local model = Instance.new("Model")
	model.Name = body.model
	local bell = addPart(model, "Fish_Body", BALL, Vector3.new(2.2, 1.4, 2.2), CFrame.new())
	bell.Transparency = 0.3
	addPart(model, "Fish_Marks", BALL, Vector3.new(0.7, 0.5, 0.7), CFrame.new(0, -0.05, 0)) -- inner glow
	local skirt = addPart(model, "Fish_Fins", CYLINDER, Vector3.new(0.12, 2.0, 2.0), upright(Vector3.new(0, -0.55, 0)))
	skirt.Transparency = 0.2
	for i = 0, 7 do
		local a = (i / 8) * math.pi * 2
		local tendril = addPart(
			model,
			"Fish_Fins",
			CYLINDER,
			Vector3.new(1.3, 0.1, 0.1),
			upright(Vector3.new(math.cos(a) * 0.75, -1.15, math.sin(a) * 0.75))
		)
		tendril.Transparency = 0.25
	end
	for i = 0, 3 do
		local a = (i / 4) * math.pi * 2 + 0.4
		addPart(
			model,
			"Fish_Marks",
			CYLINDER,
			Vector3.new(1.6, 0.16, 0.16),
			upright(Vector3.new(math.cos(a) * 0.3, -1.3, math.sin(a) * 0.3))
		)
	end
	return model
end

-- Sand Lurker: a flat flounder, eyes on top. Flat and belly-down: bbox
-- Z 3.25 > X 2.6 > Y 0.5 - the side fringes must stay narrower than the body.
local function buildLurker(body): Model
	local model = Instance.new("Model")
	model.Name = body.model
	addPart(model, "Fish_Body", BALL, Vector3.new(2.0, 0.45, 2.8), CFrame.new())
	for _, sx in { -1, 1 } do
		addPart(model, "Fish_Fins", BLOCK, Vector3.new(0.4, 0.08, 2.2), CFrame.new(sx * 1.1, 0, -0.1)) -- fringe
	end
	addPart(model, "Fish_Fins", BLOCK, Vector3.new(0.6, 0.08, 0.5), CFrame.new(0, 0, -1.6)) -- tail
	for _, spot in
		{
			Vector3.new(0.5, 0.23, 0.3),
			Vector3.new(-0.6, 0.23, -0.4),
			Vector3.new(0.2, 0.23, -0.9),
			Vector3.new(-0.3, 0.23, 0.8),
		}
	do
		addPart(model, "Fish_Marks", CYLINDER, Vector3.new(0.06, 0.35, 0.35), upright(spot)) -- mottling
	end
	eyes(model, 0.26, 0.25, 0.25, 0.9)
	return model
end

-- Pearl Mimic: two shell halves and a pearl. UPRIGHT (row stance), facing
-- the player with +X like every upright creature, so the gape is at +X and
-- the lid - the single Fish_Fins part, which CreatureService hinges
-- MIMIC_HINGE_BACK behind the centre on -X - swings up at the front.
local function buildMimic(body): Model
	local model = Instance.new("Model")
	model.Name = body.model
	addPart(model, "Fish_Body", BALL, Vector3.new(2.4, 0.6, 1.9), CFrame.new()) -- lower shell, deeper along X
	addPart(model, "Fish_Fins", BALL, Vector3.new(2.45, 0.6, 1.95), CFrame.new(0, 0.5, 0)) -- the lid
	addPart(model, "Fish_Marks", BALL, Vector3.new(0.5, 0.5, 0.5), CFrame.new(0.15, 0.4, 0)) -- the pearl, toward the gape
	return model
end

-- Pickpocket Hermit: a crab wearing a clay pot with coins on top. The pot is
-- the body (row `color`), the crab its fins (`finColor`), the coins marks.
-- Flat; bbox Z 2.65 > X 1.8 > Y 1.3.
local function buildHermit(body): Model
	local model = Instance.new("Model")
	model.Name = body.model
	addPart(model, "Fish_Body", BALL, Vector3.new(1.5, 1.1, 1.5), CFrame.new(0, 0.25, -0.5)) -- the pot
	addPart(
		model,
		"Fish_Body",
		CYLINDER,
		Vector3.new(0.25, 1.1, 1.1),
		CFrame.new(0, 0.25, 0.3) * CFrame.Angles(0, math.rad(90), 0)
	) -- rim
	addPart(model, "Fish_Fins", BALL, Vector3.new(0.9, 0.5, 0.9), CFrame.new(0, 0, 0.55)) -- the crab
	for _, sx in { -1, 1 } do
		addPart(model, "Fish_Fins", BLOCK, Vector3.new(0.35, 0.3, 0.6), CFrame.new(sx * 0.5, -0.05, 1.1)) -- claws
		for _, z in { 0.3, 0.75 } do
			limb(model, "Fish_Fins", Vector3.new(sx * 0.35, -0.1, z), Vector3.new(sx, -0.5, 0), 0.6, 0.12)
		end
	end
	for _, coin in { Vector3.new(-0.2, 0.83, -0.5), Vector3.new(0.2, 0.86, -0.4), Vector3.new(0, 0.9, -0.7) } do
		addPart(model, "Fish_Marks", CYLINDER, Vector3.new(0.06, 0.3, 0.3), upright(coin))
	end
	eyes(model, 0.2, 0.2, 0.35, 0.9)
	return model
end

-- Voltray: a flat diamond ray with a long whip tail; the two Fish_Marks
-- discs on its back are the electric organs (the client lights them while
-- it charges). Flat and belly-down; bbox Z 6.0 > X 3.7 > Y 0.4.
local function buildRay(body): Model
	local model = Instance.new("Model")
	model.Name = body.model
	addPart(model, "Fish_Body", BALL, Vector3.new(1.4, 0.35, 2.2), CFrame.new()) -- spine (PrimaryPart, unrotated)
	addPart(
		model,
		"Fish_Body",
		BLOCK,
		Vector3.new(2.6, 0.22, 2.6),
		CFrame.new(0, 0, 0.2) * CFrame.Angles(0, math.rad(45), 0)
	) -- the diamond
	addPart(model, "Fish_Fins", BLOCK, Vector3.new(0.14, 0.1, 2.6), CFrame.new(0, 0, -2.6)) -- whip tail
	addPart(model, "Fish_Fins", BLOCK, Vector3.new(0.3, 0.08, 0.5), CFrame.new(0, 0, -3.7)) -- barb
	for _, sx in { -1, 1 } do
		addPart(model, "Fish_Marks", CYLINDER, Vector3.new(0.08, 0.6, 0.6), upright(Vector3.new(sx * 0.9, 0.2, 0.2)))
	end
	eyes(model, 0.2, 0.3, 0.2, 1.0)
	return model
end

-- Brinejaw, the island boss: a colossal anglerfish-leviathan. UPRIGHT (row
-- stance), authored Y-up facing +X like every upright creature: the maw and
-- lure at +X, the tail at -X. ~13 studs long, ~7 tall with the sail. The
-- torso is added first so it's the PrimaryPart / pivot; the head reaches ~5
-- studs forward of it toward the player. Fish_Body = hide, Fish_Fins =
-- fins / fangs / sail spines / lure stalk, Fish_Marks = the lure bulb + gill
-- slits (the client lights these when it enrages).
local function buildLeviathan(body): Model
	local model = Instance.new("Model")
	model.Name = body.model

	-- Torso first: the pivot. Then the head, the belly and the tail.
	addPart(model, "Fish_Body", BALL, Vector3.new(7.0, 3.8, 4.0), CFrame.new(-2.0, 0, 0))
	addPart(model, "Fish_Body", BALL, Vector3.new(5.6, 4.4, 4.8), CFrame.new(2.8, 0.4, 0)) -- armoured head
	addPart(model, "Fish_Body", BALL, Vector3.new(5.0, 3.0, 3.6), CFrame.new(-0.5, -0.7, 0)) -- belly
	addPart(model, "Fish_Body", BALL, Vector3.new(4.0, 1.8, 1.8), CFrame.new(-6.6, 0.3, 0)) -- tail stock
	addPart(
		model,
		"Fish_Fins",
		BLOCK,
		Vector3.new(0.3, 3.4, 2.4),
		CFrame.new(-8.6, 0.8, 0) * CFrame.Angles(0, 0, math.rad(-20))
	) -- tail fin

	-- Lower jaw, hung open, and two rows of fangs.
	addPart(
		model,
		"Fish_Body",
		BLOCK,
		Vector3.new(3.8, 0.9, 3.8),
		CFrame.new(4.0, -1.45, 0) * CFrame.Angles(0, 0, math.rad(-12))
	)
	for i = 0, 5 do
		local z = -1.5 + i * 0.6
		addPart(model, "Fish_Fins", BLOCK, Vector3.new(0.32, 1.0, 0.32), CFrame.new(5.3, -0.55, z)) -- upper fangs, pointing down
		addPart(model, "Fish_Fins", BLOCK, Vector3.new(0.3, 0.8, 0.3), CFrame.new(5.5, -1.3, z + 0.3)) -- lower fangs
	end
	for _, sz in { -1, 1 } do
		addPart(model, "Fish_Fins", BLOCK, Vector3.new(0.5, 1.4, 0.5), CFrame.new(5.0, -0.3, sz * 2.0)) -- the big side fangs
	end

	-- Dorsal sail: a row of spines rising along the back.
	for i = 0, 5 do
		local x = 2.0 - i * 1.5
		local h = 1.8 + math.sin((i + 1) / 7 * math.pi) * 1.6
		addPart(
			model,
			"Fish_Fins",
			BLOCK,
			Vector3.new(0.55, h, 0.35),
			CFrame.new(x, 1.6 + h / 2, 0) * CFrame.Angles(0, 0, math.rad(18))
		)
	end

	-- Pectoral fins, swept back and out.
	for _, sz in { -1, 1 } do
		addPart(
			model,
			"Fish_Fins",
			BLOCK,
			Vector3.new(2.6, 0.25, 3.2),
			CFrame.new(0.2, -0.8, sz * 2.9) * CFrame.Angles(math.rad(sz * -25), math.rad(-30), 0)
		)
	end

	-- The lure: a stalk off the forehead, a glowing bulb at its tip.
	limb(model, "Fish_Fins", Vector3.new(3.6, 2.4, 0), Vector3.new(0.75, 0.55, 0), 3.4, 0.22)
	addPart(model, "Fish_Marks", BALL, Vector3.new(1.1, 1.1, 1.1), CFrame.new(6.4, 4.4, 0))

	-- Gill slits, three a side.
	for _, sz in { -1, 1 } do
		for i = 0, 2 do
			addPart(
				model,
				"Fish_Marks",
				BLOCK,
				Vector3.new(0.25, 1.4, 0.12),
				CFrame.new(0.6 - i * 0.5, 0.4, sz * 2.3) * CFrame.Angles(0, 0, math.rad(10))
			)
		end
	end

	-- Eyes on the head's sides (the shared `eyes` helper mirrors in X; these
	-- mirror in Z because the boss faces +X).
	for _, sz in { -1, 1 } do
		addPart(model, "Fish_Eyes", BALL, Vector3.new(0.75, 0.75, 0.75), CFrame.new(4.2, 1.5, sz * 2.1))
	end

	return model
end

local URCHIN_SPIKE = 0.9

-- shape name -> builder. A row's `shape` is the pre-import fallback; adding
-- a procedural creature is a builder + an entry here.
local BUILDERS = {
	puffer = buildPuffer,
	crab = buildCrab,
	zombie = buildZombie,
	skipper = buildSkipper,
	gulletcod = buildGulletCod,
	urchin = function(body)
		return buildPuffer(body, URCHIN_SPIKE)
	end,
	jelly = buildJelly,
	lurker = buildLurker,
	mimic = buildMimic,
	hermit = buildHermit,
	ray = buildRay,
	leviathan = buildLeviathan,
}

-- Pulls one species' parts out of the pack template into a fresh Model,
-- renamed to the generic Fish_* names. nil (with a reason) if the pack has
-- no such species - a row naming a species the .glb was generated without,
-- or a pack imported before that species was added.
local function assembleSpecies(template: Instance, species: string): (Model?, string?)
	local model = Instance.new("Model")
	local found = 0
	for _, suffix in PART_SUFFIXES do
		-- The importer wraps each mesh in a <name>_Node; search recursively
		-- and take the actual part, not the wrapper.
		local part = template:FindFirstChild(species .. "_" .. suffix, true)
		if part and part:IsA("BasePart") then
			local copy = part:Clone()
			copy.Name = "Fish_" .. suffix
			copy.Parent = model
			found += 1
		end
	end
	if found == 0 or not model:FindFirstChild("Fish_Body") then
		model:Destroy()
		return nil, string.format("No species %q in ReplicatedStorage.Assets.%s", species, template.Name)
	end
	return model
end

-- Returns a fresh, unparented, anchored Model whose pivot is the body's
-- centre. Callers position it with PivotTo.
function CreatureModel.build(row): Model
	local body = row.body
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local template = assets and assets:FindFirstChild(body.model)

	-- Prefer the imported pack species. A row can also carry `shape` as a
	-- procedural fallback (the puffer), shown when the pack hasn't been
	-- (re)imported yet so the creature is never invisible.
	local model
	if body.species and template then
		model = assembleSpecies(template, body.species)
	end
	if not model then
		local builder = body.shape and BUILDERS[body.shape]
		if builder then
			-- Built from parts, not a mesh, so it shows even before the pack is imported.
			model = builder(body)
		elseif not template then
			model = buildFallback(body, "No creature mesh found at ReplicatedStorage.Assets." .. body.model)
		elseif body.species then
			model = buildFallback(
				body,
				string.format("No species %q in ReplicatedStorage.Assets.%s", body.species, body.model)
			)
		else
			model = template:Clone()
		end
	end
	model.Name = row.id
	colorParts(model, body)

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			-- Anchored: the server moves creatures by CFrame from one loop.
			-- CreatureService unanchors it only for the throw from the bobber,
			-- then anchors it again the moment it lands.
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false -- never blocks a targeting query later
			descendant.CanTouch = false
			-- The CREATURE collision group, so the world's invisible barriers
			-- (WorldService, BARRIER group) let a thrown catch fly THROUGH
			-- them to the player instead of bouncing off - the barriers are
			-- one-way, and what keeps creatures inside is the server's
			-- clampToBounds, not a wall (user, 2026-08-23). pcall'd because
			-- the group only exists once WorldService.init has registered it,
			-- and this module is Shared (a client preview may build first).
			pcall(function()
				descendant.CollisionGroup = World.CREATURE_COLLISION_GROUP
			end)
			-- No cast shadow: a fish held up on the line / mid-throw drops a
			-- hard shadow onto the water or ground below it that reads as a
			-- separate dark blob rather than as the fish's own shading. The
			-- low-poly flat-shaded look carries its own form without it.
			descendant.CastShadow = false
		end
	end

	local bodyPart = model:FindFirstChild("Fish_Body", true)
	if bodyPart and bodyPart:IsA("BasePart") then
		model.PrimaryPart = bodyPart

		-- Weld everything to the body so the model is one rigid assembly
		-- when CreatureService hands it to physics for the throw. Fins and
		-- eyes are massless so the body alone decides how it flies.
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") and descendant ~= bodyPart then
				local weld = Instance.new("WeldConstraint")
				weld.Name = "BodyWeld"
				weld.Part0 = bodyPart
				weld.Part1 = descendant
				weld.Parent = descendant
				descendant.Massless = true
			end
		end
	end

	if body.scale ~= 1 then
		model:ScaleTo(body.scale)
	end

	return model
end

-- Length of a built creature along its nose-tail axis, in studs.
function CreatureModel.lengthFor(row): number
	return CreatureModel.BASE_LENGTH * row.body.scale
end

return CreatureModel
