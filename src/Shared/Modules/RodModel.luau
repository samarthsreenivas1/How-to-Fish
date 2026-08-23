--!nonstrict
-- RodModel.luau
-- Builds the visual Model for a rod row: clones the imported mesh from
-- ReplicatedStorage/Assets (or a plain-parts stand-in if it hasn't been
-- imported yet), recolours by part name, and strips physics so the rod is
-- purely visual.
--
-- Shared because two things need the same rod: the server welds one into
-- the character's hand for everyone else to see, and the client builds its
-- own copy for the first-person viewmodel. One builder, one fallback, one
-- colour table.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RodModel = {}

-- Every rod is one variant in the shared RodPack (assets/rod_gen.py). The
-- pack holds them side by side as <Variant>_Twig / _Grip / _Trim / _Line /
-- _BobberTop / _BobberBottom; assembleVariant clones one variant's parts out
-- and renames them to these generic Rod_* names, so RodService, the
-- viewmodel and the tackle toggle all look for one set of names. Mirrors
-- CreatureModel/FishPack. Trim (guides, reel, bands, tip ring) is optional -
-- a variant without one just has no Rod_Trim.
local PART_SUFFIXES = { "Twig", "Grip", "Trim", "Line", "BobberTop", "BobberBottom" }

-- Which Rods.luau model.colors key recolours which part. Same reasoning as
-- WorldService.MESH_COLOR: the importer's material handling isn't trusted,
-- so the final look belongs to code - every part of every rod is coloured
-- from its row, with these defaults for any key a row leaves out.
local COLOR_KEY = {
	Rod_Twig = "twig",
	Rod_Grip = "grip",
	Rod_Trim = "trim",
	Rod_Line = "line",
	Rod_BobberTop = "bobberTop",
	Rod_BobberBottom = "bobberBottom",
}

local DEFAULT_COLOR = {
	twig = Color3.fromRGB(139, 104, 68),
	grip = Color3.fromRGB(92, 81, 57),
	trim = Color3.fromRGB(150, 150, 150),
	line = Color3.fromRGB(224, 224, 214),
	bobberTop = Color3.fromRGB(217, 46, 41),
	bobberBottom = Color3.fromRGB(245, 245, 240),
}

-- Where the rod sits relative to the character's hand part when welded by
-- RodService (what other players see). The authored rod axis is +Y (butt to
-- tip); a hanging hand's forward is -Z. Rolled so the rod points forward and
-- up with the grip centre in the palm. The first-person viewmodel has its
-- own pose constants because the arm is raised there, not hanging.
RodModel.HOLD_OFFSET = CFrame.Angles(math.rad(-65), 0, 0)

local function colorParts(model: Model, rodData)
	-- Per-rod colours for every part (Rods.luau model.colors), with the
	-- defaults filling any gap. Parts the row lists in model.neon glow (the
	-- Abyssal's teal rings and lantern); everything else is matte plastic.
	local override = (rodData.model and rodData.model.colors) or {}
	local neon = (rodData.model and rodData.model.neon) or {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			local key = COLOR_KEY[descendant.Name]
			local color = key and (override[key] or DEFAULT_COLOR[key])
			if color then
				descendant.Color = color
				descendant.Material = if table.find(neon, descendant.Name)
					then Enum.Material.Neon
					else Enum.Material.SmoothPlastic
				local appearance = descendant:FindFirstChildWhichIsA("SurfaceAppearance")
				if appearance then
					appearance:Destroy()
				end
			end
		end
	end
end

-- Pulls one variant's parts out of the pack template into a fresh Model,
-- renamed to the generic Rod_* names. nil if the pack has no such variant (a
-- row naming a variant the .glb was built without, or a stale import).
local function assembleVariant(template: Instance, variant: string): Model?
	local model = Instance.new("Model")
	local found = 0
	for _, suffix in PART_SUFFIXES do
		-- The importer wraps each mesh in a <name>_Node; search recursively.
		local part = template:FindFirstChild(variant .. "_" .. suffix, true)
		if part and part:IsA("BasePart") then
			local copy = part:Clone()
			copy.Name = "Rod_" .. suffix
			copy.Parent = model
			found += 1
		end
	end
	if found == 0 or not model:FindFirstChild("Rod_Grip") then
		model:Destroy()
		return nil
	end
	return model
end

-- A stand-in with the same two part names as the real mesh, so nothing
-- downstream cares which one it got.
local function buildFallback(rodData): Model
	warn(
		string.format(
			"[RodModel] No rod mesh for %q at ReplicatedStorage.Assets.%s.\n"
				.. "  Import it once: Studio > Home > Import > assets/rod.glb,\n"
				.. "  then move the imported model to ReplicatedStorage/Assets and name it '%s'\n"
				.. "  (every rod is in that one pack). See assets/README.md. Plain stand-in until then.",
			tostring(rodData.model.variant),
			rodData.model.model,
			rodData.model.model
		)
	)

	local model = Instance.new("Model")
	model.Name = rodData.model.model

	-- Plain blocks, unrotated, so each part's local +Y is the rod axis -
	-- the same frame the imported mesh parts have. Callers use the grip's
	-- full CFrame (not just its position) as the rod's reference frame.
	local twig = Instance.new("Part")
	twig.Name = "Rod_Twig"
	twig.Size = Vector3.new(0.3, 7, 0.3)
	twig.CFrame = CFrame.new(0, 3.5, 0)
	twig.Parent = model

	local grip = Instance.new("Part")
	grip.Name = "Rod_Grip"
	grip.Size = Vector3.new(0.55, 1.6, 0.55)
	grip.CFrame = CFrame.new(0, rodData.model.grip, 0)
	grip.Parent = model

	return model
end

-- Returns a fresh, unparented Model. Its Rod_Grip part's centre is the
-- authored hand point (rod_gen.py exports the grip as its own object for
-- exactly this reason); callers place everything relative to that.
function RodModel.build(rodData): Model
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local template = assets and assets:FindFirstChild(rodData.model.model)

	local model
	if template and rodData.model.variant then
		model = assembleVariant(template, rodData.model.variant)
	elseif template then
		model = template:Clone() -- a row with no variant clones its template whole
	end
	if not model then
		model = buildFallback(rodData)
	end

	colorParts(model, rodData)

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.CastShadow = true
			descendant.Massless = true -- never changes how the character moves
		end
	end

	return model
end

-- The grip part, searched by name so it works for the mesh and the stand-in.
function RodModel.findGrip(model: Model): BasePart?
	local grip = model:FindFirstChild("Rod_Grip", true)
	return if grip and grip:IsA("BasePart") then grip else nil
end

-- The idle line + bobber baked into the mesh. They're what you see hanging
-- off the tip while not fishing; FishingController hides them for the
-- duration of a cast because it draws its own line out to the water.
RodModel.TACKLE_PARTS = { "Rod_Line", "Rod_BobberTop", "Rod_BobberBottom" }

function RodModel.setTackleVisible(model: Model, visible: boolean)
	for _, name in RodModel.TACKLE_PARTS do
		local part = model:FindFirstChild(name, true)
		if part and part:IsA("BasePart") then
			part.Transparency = if visible then 0 else 1
		end
	end
end

return RodModel
