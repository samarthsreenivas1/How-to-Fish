--!nonstrict
-- WeaponModel.luau
-- Builds the held Model for a weapon row out of plain parts. No mesh import
-- step, for the same reason the pufferfish is procedural: a crafted weapon
-- is testable the moment its row exists, with nothing to re-import or
-- re-export. A Blender mesh per weapon can replace a builder here later
-- without changing anyone who calls build().
--
-- Authored like the rod (RodModel): the weapon stands along +Y with its
-- butt at y = 0 and its tip at y = row.model.length, and a part named
-- `Weapon_Grip` whose centre is the hand point (y = row.model.grip). Callers
-- place every part relative to the grip's CFrame - the server welds a copy
-- into the character for other players (WeaponService), the client builds
-- its own for the first-person viewmodel (WeaponViewmodelController).
--
-- One builder per `shape`; an unknown shape gets a plain stick and a warning
-- so the game never fails to hand something over.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WeaponModel = {}

-- Where the weapon sits relative to the character's hand part when welded by
-- WeaponService (what other players see). The authored axis is +Y; a
-- hanging hand's forward is -Z. Pitched so the weapon points forward and a
-- little up, grip centre in the palm, then rolled -90 about its own axis so
-- a blade's edge leads and its flats face sideways (without the roll the
-- flat of the blade faces the camera - same fix as WEAPON_ROLL in
-- WeaponViewmodelController, keep the two in step). The first-person
-- viewmodel has its own pose constants (the arm is raised there, not
-- hanging).
WeaponModel.HOLD_OFFSET = CFrame.Angles(math.rad(-70), 0, 0) * CFrame.Angles(0, math.rad(-90), 0)

-- A GUN in a third-person hand: the authored +Y is the BORE (gun-mesh
-- contract, 2026-08-27), so instead of the melee "blade up" carry the bore
-- lies level, pointing the way the character faces. One knob: if a pack
-- lands guns rolled sideways in world view, adjust the trailing roll here.
WeaponModel.HOLD_OFFSET_RANGED = CFrame.Angles(math.rad(-90), 0, 0) * CFrame.Angles(0, math.rad(-90), 0)

local MATERIAL = Enum.Material.SmoothPlastic

-- A block at (0, y, 0) in weapon space, sized (x, y, z).
local function block(parent: Model, name: string, size: Vector3, y: number, color: Color3, className: string?): BasePart
	local part = Instance.new(className or "Part")
	part.Name = name
	part.Size = size
	part.CFrame = CFrame.new(0, y, 0)
	part.Color = color
	part.Material = MATERIAL
	part.Parent = parent
	return part
end

-- ============================================================ shapes

-- A knotted club: a thin haft, a fat head, a couple of knots, a wrapped grip.
local function buildClub(model: Model, m)
	local headLength = 1.3
	local haftLength = m.length - headLength

	block(model, "Weapon_Haft", Vector3.new(0.32, haftLength, 0.32), haftLength / 2, m.color)
	block(model, "Weapon_Grip", Vector3.new(0.44, 1.3, 0.44), m.grip, m.wrap)
	block(model, "Weapon_Head", Vector3.new(0.85, headLength, 0.85), m.length - headLength / 2, m.accent)

	-- Knots poking out of the head, offset sideways so the silhouette reads
	-- as driftwood rather than a mallet.
	local knot1 = block(model, "Weapon_Knot", Vector3.new(0.34, 0.34, 0.34), m.length - 0.95, m.accent)
	knot1.CFrame = CFrame.new(0.5, m.length - 0.95, 0.1) * CFrame.Angles(0.4, 0.3, 0.2)
	local knot2 = block(model, "Weapon_Knot", Vector3.new(0.3, 0.3, 0.3), m.length - 0.4, m.accent)
	knot2.CFrame = CFrame.new(-0.42, m.length - 0.4, -0.15) * CFrame.Angles(0.2, 0.6, 0.5)
end

-- A short blade: pommel, wrapped grip, a crossguard, a flat blade with a
-- swept wedge tip.
local function buildBlade(model: Model, m)
	local gripLength = 1.1
	local guardThickness = 0.18
	local tipLength = 0.7

	block(model, "Weapon_Pommel", Vector3.new(0.5, 0.3, 0.5), 0.15, m.color)
	block(model, "Weapon_Grip", Vector3.new(0.38, gripLength, 0.38), m.grip, m.wrap)

	local guardY = m.grip + gripLength / 2 + guardThickness / 2
	block(model, "Weapon_Guard", Vector3.new(1.2, guardThickness, 0.36), guardY, m.color)

	local bladeStart = guardY + guardThickness / 2
	local bladeLength = m.length - tipLength - bladeStart
	block(model, "Weapon_Blade", Vector3.new(0.12, bladeLength, 0.7), bladeStart + bladeLength / 2, m.accent)

	-- A WedgePart's slope runs from the top of its +Z face down to the -Z
	-- bottom edge, so stood on the blade's end it narrows to an angled point.
	block(model, "Weapon_Tip", Vector3.new(0.12, tipLength, 0.7), m.length - tipLength / 2, m.accent, "WedgePart")
end

-- A recurve bow (the ranged rows' fantasy tier). The stave runs the weapon's
-- +Y length with the grip at its middle; the limbs sweep away and curve back,
-- and the string spans the tips on +Z, so the standard -90 hold roll turns
-- the string toward the shooter and the belly forward.
local function buildBow(model: Model, m)
	block(model, "Weapon_Grip", Vector3.new(0.34, 1.0, 0.4), m.grip, m.wrap)

	local limb = math.max(0.8, (m.length - 1.0) / 2)
	for _, sign in { 1, -1 } do
		local inner = block(model, "Weapon_Limb", Vector3.new(0.24, limb * 0.62, 0.3), 0, m.color)
		inner.CFrame = CFrame.new(0, m.grip + sign * (0.5 + limb * 0.3), -0.08)
			* CFrame.Angles(sign * math.rad(-8), 0, 0)
		local outer = block(model, "Weapon_Limb", Vector3.new(0.2, limb * 0.52, 0.26), 0, m.color)
		outer.CFrame = CFrame.new(0, m.grip + sign * (0.5 + limb * 0.78), 0.1)
			* CFrame.Angles(sign * math.rad(16), 0, 0)
	end

	-- The taut string, tip to tip.
	local bowstring = block(model, "Weapon_String", Vector3.new(0.05, m.length - 0.7, 0.05), m.grip, m.accent)
	bowstring.CFrame = CFrame.new(0, m.grip, 0.34)
end

-- A generic long gun (flintlock through repeater - the mesh pack carries the
-- character; this is the pre-import fallback). Butt at 0, muzzle at `length`:
-- stock up to the grip, receiver over it, then the barrel, with a sight at
-- the muzzle and a magazine dropping off the receiver.
local function buildGun(model: Model, m)
	local stockLength = math.max(0.5, m.grip - 0.15)
	block(model, "Weapon_Stock", Vector3.new(0.26, stockLength, 0.55), stockLength / 2, m.color)
	block(model, "Weapon_Grip", Vector3.new(0.3, 0.8, 0.46), m.grip, m.wrap)

	local receiverLength = math.clamp(m.length - m.grip - 0.6, 0.5, 1.1)
	local receiverY = m.grip + 0.4 + receiverLength / 2
	block(model, "Weapon_Receiver", Vector3.new(0.34, receiverLength, 0.5), receiverY, m.color)

	local barrelStart = m.grip + 0.4 + receiverLength
	local barrelLength = math.max(0.4, m.length - barrelStart)
	block(model, "Weapon_Barrel", Vector3.new(0.18, barrelLength, 0.18), barrelStart + barrelLength / 2, m.accent)

	local sight = block(model, "Weapon_Sight", Vector3.new(0.08, 0.16, 0.2), m.length - 0.2, m.accent)
	sight.CFrame = CFrame.new(0, m.length - 0.2, -0.16)
	local mag = block(model, "Weapon_Mag", Vector3.new(0.24, 0.7, 0.3), 0, m.accent)
	mag.CFrame = CFrame.new(0, m.grip + 0.55, 0.32) * CFrame.Angles(math.rad(12), 0, 0)
end

local function buildFallback(model: Model, m)
	warn(string.format("[WeaponModel] no builder for weapon shape %q; using a plain stick", tostring(m.shape)))
	block(model, "Weapon_Haft", Vector3.new(0.3, m.length, 0.3), m.length / 2, m.color)
	block(model, "Weapon_Grip", Vector3.new(0.4, 1.2, 0.4), m.grip, m.wrap)
end

local BUILDERS = {
	club = buildClub,
	blade = buildBlade,
	bow = buildBow,
	gun = buildGun,
}

-- ============================================================ mesh pack
-- The newer weapons are Blender meshes in the shared WeaponPack (one import,
-- like the RodPack/CreaturePack - see assets/weapon_gen.py). A row with a
-- `model.variant` prefers the mesh; a row with only a `shape` (the starter
-- club/blade), or any mesh row before its pack is imported, uses the
-- procedural builders above. Mirrors RodModel.assembleVariant.

-- The parts a variant may carry, cloned out and renamed to the generic
-- Weapon_* set. Only Weapon_Grip is required (it's the hand frame).
-- Mag/Action/Sight/Muzzle are the gun-mesh contract (2026-08-27): the
-- magazine and the cycling action are SEPARATE parts so reload/shoot
-- animations can move them later, and Weapon_Muzzle is a tiny marker
-- capping the bore at the tip - the muzzle-flash / projectile origin.
local PART_SUFFIXES =
	{ "Haft", "Grip", "Guard", "Pommel", "Head", "Edge", "Spike", "Glow", "Mag", "Action", "Sight", "Muzzle" }

-- Which model colour recolours which part. Haft/guard/pommel are the "handle"
-- colour, the grip its wrap, the business end the accent, and glowing runes
-- the optional `glow` (falling back to accent). Same idea as RodModel.COLOR_KEY.
local MESH_COLOR_KEY = {
	Weapon_Haft = "color",
	Weapon_Guard = "color",
	Weapon_Pommel = "color",
	Weapon_Grip = "wrap",
	Weapon_Head = "accent",
	Weapon_Edge = "accent",
	Weapon_Spike = "accent",
	Weapon_Glow = "glow",
	Weapon_Mag = "accent",
	Weapon_Action = "color",
	Weapon_Sight = "accent",
	Weapon_Muzzle = "glow",
}

-- Pulls one variant's parts out of the pack into a fresh Model, renamed to the
-- generic Weapon_* names. nil if the pack lacks the variant or a grip (a stale
-- import, or a row naming a variant the .glb was built without) - the caller
-- then falls back to the procedural builder.
local function assembleVariant(template: Instance, variant: string): Model?
	local model = Instance.new("Model")
	local found = 0
	for _, suffix in PART_SUFFIXES do
		-- The importer wraps each mesh in a <name>_Node; search recursively.
		local part = template:FindFirstChild(variant .. "_" .. suffix, true)
		if part and part:IsA("BasePart") then
			local copy = part:Clone()
			copy.Name = "Weapon_" .. suffix
			copy.Parent = model
			found += 1
		end
	end
	if found == 0 or not model:FindFirstChild("Weapon_Grip") then
		model:Destroy()
		return nil
	end
	return model
end

-- Recolours an assembled mesh weapon by part name (the procedural builders
-- colour inline instead, so this is the mesh path only). Parts listed in
-- `m.neon` glow; everything else is matte plastic.
local function colorMeshParts(model: Model, m)
	local neon = m.neon or {}
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			local key = MESH_COLOR_KEY[part.Name]
			if key then
				local color = if key == "glow" then (m.glow or m.accent) else m[key]
				if color then
					part.Color = color
				end
				part.Material = if table.find(neon, part.Name) then Enum.Material.Neon else MATERIAL
				local appearance = part:FindFirstChildWhichIsA("SurfaceAppearance")
				if appearance then
					appearance:Destroy()
				end
			end
		end
	end
end

-- ============================================================ API

-- Returns a fresh, unparented Model for the row, or nil for a row with no
-- `model` (bare hands). Parts are physics-free and massless so the weapon
-- never changes how the character moves.
function WeaponModel.build(weaponData): Model?
	local m = weaponData.model
	if not m then
		return nil
	end

	-- Prefer the imported mesh (WeaponPack) when the row names a variant; fall
	-- back to the procedural builder for the starter club/blade and for any
	-- mesh weapon whose pack hasn't been imported yet.
	local model
	if m.variant then
		local assets = ReplicatedStorage:FindFirstChild("Assets")
		local template = assets and assets:FindFirstChild(m.model or "WeaponPack")
		if template then
			model = assembleVariant(template, m.variant)
		end
	end

	if model then
		model.Name = weaponData.id
		colorMeshParts(model, m)
	else
		model = Instance.new("Model")
		model.Name = weaponData.id
		local builder = BUILDERS[m.shape] or buildFallback
		builder(model, m)
	end

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.CastShadow = true
			descendant.Massless = true
		end
	end

	model.PrimaryPart = WeaponModel.findGrip(model)
	return model
end

-- The grip part, by name, so every builder and any future imported mesh
-- share the one contract.
function WeaponModel.findGrip(model: Model): BasePart?
	local grip = model:FindFirstChild("Weapon_Grip", true)
	return if grip and grip:IsA("BasePart") then grip else nil
end

return WeaponModel
