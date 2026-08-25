--!nonstrict
-- BoatModel.luau
-- Builds the drivable boat Model for a Boats.luau row out of plain parts, the
-- WeaponModel way: procedural by default, so every tier is testable the
-- moment its row exists, with a mesh path (the shared "BoatPack" from
-- assets/boat_gen.py) that takes over per-variant once the pack is imported -
-- without changing anyone who calls build().
--
-- Boat space: origin at the WATERLINE amidships, bow toward -Z (so the hull's
-- LookVector points where the boat drives), +Y up. The row's model spec is the
-- physics truth: the ONLY collidable part is `Boat_Collider` - an invisible
-- box sized beam x (draft + deckHeight) x length - and every visual part
-- (procedural or mesh) is welded to it massless and non-collidable, so a
-- fancier hull can never change how the boat floats or shoves players.
--
-- Fixed part names are the contract (like Weapon_*/Fish_*):
--   Boat_Collider - PrimaryPart, the physics box. Carries the "BoatRoot"
--                   Attachment plus the Boat_Move (LinearVelocity) and
--                   Boat_Align (AlignOrientation) constraints the driver's
--                   client steers with.
--   Boat_Seat     - the VehicleSeat, facing the bow.
--   TrophyShelf   - a Model holding Boat_Shelf, whose top carries Attachments
--                   HeartMount1..6 (bow -> stern order port to starboard) for
--                   the boss-heart trophy renderer (TrophyController).
--   Boat_Hull/Bow/Deck/Rail/Mast/Sail/Trim/Lantern/Figurehead - visuals only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BoatModel = {}

BoatModel.PACK_NAME = "BoatPack"
BoatModel.HEART_MOUNTS = 6

local MATERIAL = Enum.Material.SmoothPlastic

-- The parts a BoatPack variant may carry (assets/boat_gen.py exports
-- <Variant>_<Suffix>), cloned out and renamed to the generic Boat_<Suffix>.
-- Helm is a marker (where the seat goes) and is consumed, not kept.
local PART_SUFFIXES =
	{ "Hull", "Deck", "Bow", "Mast", "Sail", "Rail", "Trim", "Lantern", "Figurehead", "Shelf", "Helm" }

-- Which row colour paints which part (mesh and procedural share this table).
local COLOR_KEY = {
	Boat_Hull = "hull",
	Boat_Bow = "hull",
	Boat_Deck = "deck",
	Boat_Rail = "trim",
	Boat_Mast = "trim",
	Boat_Trim = "trim",
	Boat_Figurehead = "trim",
	Boat_Shelf = "trim",
	Boat_Sail = "sail",
	Boat_Lantern = "glow",
}

local function part(props): BasePart
	local p = Instance.new(props.className or "Part")
	p.Name = props.name
	p.Size = props.size
	p.CFrame = props.cframe
	p.Color = props.color or Color3.fromRGB(128, 128, 128)
	p.Material = props.material or MATERIAL
	p.Anchored = false
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	return p
end

-- ============================================================ procedural hull

-- One builder covers every tier: the row's dimensions set the silhouette and
-- the colours set the tier's identity, so all six read as the same family of
-- boats growing sturdier. Returns the visual parts parented to `model`, each
-- positioned in boat space (welding happens in build()).
local function buildProcedural(model: Model, m)
	local halfLen = m.length / 2
	local hullHeight = m.draft + m.deckHeight
	local hullCentreY = (m.deckHeight - m.draft) / 2
	local colors = m.colors or {}

	-- Main hull box, slightly inside the collider, with a wedge bow.
	local bowLength = math.min(4, m.length * 0.22)
	local bodyLength = m.length - bowLength
	part({
		name = "Boat_Hull",
		size = Vector3.new(m.beam - 0.2, hullHeight, bodyLength),
		cframe = CFrame.new(0, hullCentreY, (m.length - bodyLength) / 2),
		color = colors.hull,
	}).Parent =
		model

	-- WedgePart slopes up toward +Z, so yawed 180 it noses down toward the bow.
	part({
		name = "Boat_Bow",
		className = "WedgePart",
		size = Vector3.new(m.beam - 0.2, hullHeight, bowLength),
		cframe = CFrame.new(0, hullCentreY, -halfLen + bowLength / 2) * CFrame.Angles(0, math.pi, 0),
		color = colors.hull,
	}).Parent =
		model

	-- Deck plate sitting on the hull.
	part({
		name = "Boat_Deck",
		size = Vector3.new(m.beam - 0.6, 0.2, bodyLength - 0.4),
		cframe = CFrame.new(0, m.deckHeight + 0.1, (m.length - bodyLength) / 2),
		color = colors.deck,
	}).Parent =
		model

	-- Low rails down each side.
	local railLength = bodyLength - 1
	for _, side in { -1, 1 } do
		part({
			name = "Boat_Rail",
			size = Vector3.new(0.3, 0.7, railLength),
			cframe = CFrame.new(side * (m.beam / 2 - 0.35), m.deckHeight + 0.55, (m.length - railLength) / 2 - 0.5),
			color = colors.trim,
		}).Parent =
			model
	end

	-- Mast forward of amidships, with a simple square sail.
	local mastHeight = m.length * 0.55
	part({
		name = "Boat_Mast",
		size = Vector3.new(0.4, mastHeight, 0.4),
		cframe = CFrame.new(0, m.deckHeight + mastHeight / 2, -m.length * 0.12),
		color = colors.trim,
	}).Parent =
		model
	part({
		name = "Boat_Sail",
		size = Vector3.new(m.beam * 0.9, mastHeight * 0.55, 0.15),
		cframe = CFrame.new(0, m.deckHeight + mastHeight * 0.6, -m.length * 0.12 + 0.35),
		color = colors.sail,
	}).Parent =
		model

	-- A lantern on the mast for the tiers whose row marks it Neon.
	part({
		name = "Boat_Lantern",
		size = Vector3.new(0.7, 0.7, 0.7),
		cframe = CFrame.new(0, m.deckHeight + mastHeight + 0.5, -m.length * 0.12),
		color = colors.glow,
	}).Parent =
		model
end

-- ============================================================ mesh pack

-- Pulls one variant's parts out of the BoatPack into `model`, renamed to the
-- generic Boat_* set. Returns the Helm marker's CFrame (in boat space, already
-- normalised by the caller) if the variant carries one, plus whether anything
-- was found at all - the caller falls back to procedural on nil/false.
local function assembleVariant(model: Model, template: Instance, variant: string): boolean
	local found = 0
	for _, suffix in PART_SUFFIXES do
		-- The importer wraps each mesh in a <name>_Node; search recursively,
		-- and take every match (rails come in pairs).
		for _, descendant in template:GetDescendants() do
			if descendant.Name == variant .. "_" .. suffix and descendant:IsA("BasePart") then
				local copy = descendant:Clone()
				copy.Name = "Boat_" .. suffix
				copy.Anchored = false
				copy.CanCollide = false
				copy.CanQuery = false
				copy.CanTouch = false
				copy.Massless = true
				local appearance = copy:FindFirstChildWhichIsA("SurfaceAppearance")
				if appearance then
					appearance:Destroy()
				end
				copy.Parent = model
				found += 1
			end
		end
	end
	return found > 0 and model:FindFirstChild("Boat_Hull") ~= nil
end

local function colorParts(model: Model, m)
	local colors = m.colors or {}
	local neon = m.neon or {}
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") then
			local key = COLOR_KEY[p.Name]
			if key and colors[key] then
				p.Color = colors[key]
			end
			if p.Name ~= "Boat_Collider" and p.Name ~= "Boat_Seat" then
				p.Material = if table.find(neon, p.Name) then Enum.Material.Neon else MATERIAL
			end
		end
	end
end

-- ============================================================ API

-- Returns a fresh, unparented boat Model for the row. Every part is welded to
-- the collider; nothing is anchored (the caller decides parked vs driven).
function BoatModel.build(row): Model
	local m = row.model
	local model = Instance.new("Model")
	model.Name = "Boat_" .. row.id

	-- The physics truth: one invisible box. Low density so the constraint
	-- forces behave the same for a skiff and a keel.
	local collider = part({
		name = "Boat_Collider",
		size = Vector3.new(m.beam, m.draft + m.deckHeight, m.length),
		cframe = CFrame.new(0, (m.deckHeight - m.draft) / 2, 0),
		color = Color3.new(0, 0, 0),
	})
	collider.Transparency = 1
	collider.CanCollide = true
	collider.CanQuery = true
	collider.Massless = false
	collider.CustomPhysicalProperties = PhysicalProperties.new(0.35, 0.4, 0.3)
	collider.Parent = model
	model.PrimaryPart = collider

	-- Visuals: mesh variant when the pack is imported, procedural otherwise.
	local usedMesh = false
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local template = assets and assets:FindFirstChild(BoatModel.PACK_NAME)
	if template and m.variant then
		usedMesh = assembleVariant(model, template, m.variant)
	end
	if not usedMesh then
		buildProcedural(model, m)
	end
	colorParts(model, m)

	-- The helm: a VehicleSeat near the stern, facing the bow. A mesh variant
	-- may place it exactly with a Boat_Helm marker; the marker is consumed.
	local seatCFrame = CFrame.new(0, m.deckHeight + 0.75, m.length / 2 - 2.2)
	local helm = model:FindFirstChild("Boat_Helm")
	if helm and helm:IsA("BasePart") then
		seatCFrame = helm.CFrame
		helm:Destroy()
	end
	local seat = Instance.new("VehicleSeat")
	seat.Name = "Boat_Seat"
	seat.Size = Vector3.new(2, 1, 2)
	seat.CFrame = seatCFrame
	seat.Color = (m.colors and m.colors.trim) or Color3.fromRGB(90, 70, 50)
	seat.Material = MATERIAL
	seat.Anchored = false
	seat.CanCollide = false
	seat.CanQuery = false
	seat.Massless = true
	seat.MaxSpeed = 0 -- the seat only reports Throttle/Steer; BoatController drives
	seat.HeadsUpDisplay = false
	seat.Parent = model

	-- The trophy shelf: one heart mount per island boss, rendered by
	-- TrophyController from the owner's Heart_* attributes. A mesh variant may
	-- ship its own Boat_Shelf; either way the attachments are ours.
	local shelfModel = Instance.new("Model")
	shelfModel.Name = "TrophyShelf"
	local shelf = model:FindFirstChild("Boat_Shelf")
	if not (shelf and shelf:IsA("BasePart")) then
		shelf = part({
			name = "Boat_Shelf",
			size = Vector3.new(math.max(6, m.beam - 1.5), 0.4, 1.4),
			cframe = CFrame.new(0, m.deckHeight + 0.2, m.length / 2 - 0.8),
			color = (m.colors and m.colors.trim) or nil,
		})
	end
	shelf.Parent = shelfModel
	local mounts = BoatModel.HEART_MOUNTS
	for i = 1, mounts do
		local attachment = Instance.new("Attachment")
		attachment.Name = "HeartMount" .. i
		local across = (i - (mounts + 1) / 2) / mounts -- -~0.42 .. ~0.42
		attachment.Position = Vector3.new(across * shelf.Size.X, shelf.Size.Y / 2, 0)
		attachment.Parent = shelf
	end
	shelfModel.Parent = model

	-- Weld everything to the collider, in place.
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") and p ~= collider then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = collider
			weld.Part1 = p
			weld.Parent = p
		end
	end

	-- The constraints the driver's client steers with (Boat_Move's velocity,
	-- Boat_Align's CFrame). One attachment, world-relative, so the maths in
	-- BoatController stays plain vectors.
	local root = Instance.new("Attachment")
	root.Name = "BoatRoot"
	root.Parent = collider

	local move = Instance.new("LinearVelocity")
	move.Name = "Boat_Move"
	move.Attachment0 = root
	move.RelativeTo = Enum.ActuatorRelativeTo.World
	move.VectorVelocity = Vector3.zero
	move.MaxForce = math.huge
	move.Parent = collider

	local align = Instance.new("AlignOrientation")
	align.Name = "Boat_Align"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = root
	align.MaxTorque = math.huge
	align.MaxAngularVelocity = math.huge
	align.Responsiveness = 35
	align.CFrame = CFrame.new()
	align.Parent = collider

	return model
end

-- The collider, by name, so services and controllers share one contract.
function BoatModel.findCollider(model: Model): BasePart?
	local collider = model:FindFirstChild("Boat_Collider")
	return if collider and collider:IsA("BasePart") then collider else nil
end

function BoatModel.findSeat(model: Model): VehicleSeat?
	local seat = model:FindFirstChild("Boat_Seat")
	return if seat and seat:IsA("VehicleSeat") then seat else nil
end

return BoatModel
