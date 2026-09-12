--!nonstrict
-- ArmorModel.luau
-- Turns one equipped armor piece into a fresh, unparented Model of welded-
-- ready parts, painted per ROLE. The lifecycle half - which slots a player
-- has on, the three replicated attributes, welding onto a live character -
-- stays in ArmorService; this module only answers "what does this piece look
-- like".
--
-- It is the exact parallel of WeaponModel / RodModel / CreatureModel, and it
-- is deliberately a SHARED module rather than server code: the crafting UI's
-- 3-D piece preview wants the same assembly, and a second copy of the
-- name-splitting rules is how the two drift apart.
--
-- ============================================================ THE CONTRACT
--
-- ArmorPack object names carry FOUR underscore-delimited fields:
--
--     <Prefix>_<Slot>_<Target>_<Role>[<n>]
--
--   <Prefix>  Armor.sets[id].modelPrefix - "Chitin", "CorsairsRest", ...
--   <Slot>    Helm | Chest | Legs, the equip slot that owns the object
--   <Target>  the EXACT R15 part name the object welds to ("Head",
--             "LeftLowerArm", "RightFoot", ...). No lookup table is needed
--             at runtime: the code welds to `character[Target]`. No R15 part
--             name contains an underscore, so the split is unambiguous.
--   <Role>    Under | Plate | Trim | Accent | Glow - supplies the object's
--             colour AND its Enum.Material, from ArmorPalette.
--   [<n>]     an optional trailing digit when one target+role needs several
--             objects (`..._Plate2`); stripped before the role lookup.
--
-- e.g. `Cindershell_Chest_LeftUpperArm_Plate`, `Stormcaller_Helm_Head_Glow2`.
--
-- This is the same trick WeaponModel.assembleVariant + MESH_COLOR_KEY already
-- ship (WeaponModel.luau:209-255): the mesh's own name carries its role, the
-- runtime maps role -> colour + material, and the pack stays one flat import.
--
-- ========================================================== THE TWO PATHS
--
-- 1. MULTI-PART (the redesign): every pack part whose name starts
--    `<Prefix>_<Slot>_` is cloned into one Model. Each clone keeps its target
--    and role on attributes so ArmorService can weld and so a later reader
--    does not re-parse the name.
-- 2. LEGACY SINGLE-PART (what ships today): one part named exactly
--    `<Prefix>_<Slot>`, painted the piece row's single colour, as
--    ArmorService has always done.
--
-- The legacy path is NOT a courtesy - it is what makes re-importing the pack
-- a non-breaking change instead of a flag day. A set that has not been
-- rebuilt yet keeps working, unchanged, off the same pack.
--
-- COVERAGE AND BODY-PART HIDING. A target that receives an `Under` object is
-- fully enclosed by it, so the body part underneath is hidden at equip
-- (ArmorService does the write; `ArmorModel.hiddenTargets` decides the set).
-- Only a target that got an Under - never one that got only a Plate, which
-- would leave a floating shell over an invisible limb. And never the Head
-- unless the set declares `hidesFace`: hiding a player's face is a bug
-- report, not a look. The three sets that are full masks by design
-- (Duskveil, Wraithbound, Stormcaller) declare it in ArmorPalette.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Armor = require(Shared.Data.Armor)
local ArmorPalette = require(Shared.Config.ArmorPalette)

local ArmorModel = {}

-- slot -> the pack name's <Slot> field.
ArmorModel.SLOT_SUFFIX = {
	helmet = "Helm",
	chest = "Chest",
	legs = "Legs",
}

-- slot -> the R15 parts the slot's objects may target, DERIVED from the
-- generated palette rather than typed again here (the same table the
-- generator's check_coverage() enforces at build time - one source, so the
-- build side and the runtime side cannot disagree about which limbs a chest
-- is supposed to cover).
--
-- It is not used to assemble: an object's own name says its target. This is
-- the published region map, and ArmorService uses the first entry as the
-- anchor for a legacy piece or the fallback box.
ArmorModel.SLOT_TARGETS = {}
for slot, suffix in ArmorModel.SLOT_SUFFIX do
	ArmorModel.SLOT_TARGETS[slot] = ArmorPalette.SLOT_TARGETS[suffix]
end

-- Surface for an object whose role has no palette row at all: the piece row's
-- own colour on a deliberate-looking matte, so a half-authored set reads as
-- unfinished art rather than as a bug.
local DEFAULT_MATERIAL = Enum.Material.SmoothPlastic

-- ============================================================ pack lookup

local function armorPack(): Instance?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	return assets and assets:FindFirstChild("ArmorPack")
end

-- Where the pack's authored ORIGIN sits, so a sub-part's offset from its
-- joint can be recovered. Every object in the pack is authored around the one
-- Blender origin, each centred on its OWN target's centre - so an object's
-- position relative to the pack's origin IS its offset from that target's
-- centre, which is exactly what the weld needs.
local function packOrigin(pack: Instance): Vector3
	if pack:IsA("Model") then
		return pack:GetPivot().Position
	end
	return Vector3.zero
end

-- "LeftUpperArm_Plate2" -> "LeftUpperArm", "Plate". nil, nil for anything
-- that is not two fields (a stale name, or a wrapper the importer added).
local function splitTail(tail: string): (string?, string?)
	local target, role = string.match(tail, "^(.+)_([A-Za-z]+)%d*$")
	if not target or not role then
		return nil, nil
	end
	return target, role
end

-- ============================================================ painting

-- One clone's colour + material, from its role. `piece` supplies the fallback
-- colour (it is also the crafting tile swatch, so it is always present in
-- practice).
local function paint(part: BasePart, prefix: string, role: string, piece)
	local row = ArmorPalette.role(prefix, role)
	if row then
		part.Color = row.color
		part.Material = row.material
		part.Transparency = row.transparency
	else
		if piece and piece.color then
			part.Color = piece.color
		end
		part.Material = DEFAULT_MATERIAL
	end
end

-- Repo-wide convention: imported SurfaceAppearance is stripped, because
-- there is no uploaded-PBR pipeline here and a leftover appearance overrides
-- the colour we just set. WorldService, BossArenaService, BoatModel,
-- WeaponModel, CreatureModel, RodModel and CutsceneKit all do this.
local function stripAppearance(part: BasePart)
	local appearance = part:FindFirstChildWhichIsA("SurfaceAppearance")
	if appearance then
		appearance:Destroy()
	end
end

-- Worn parts must never fight the character's physics - massless,
-- collision-free, query-free, welded. Unchanged rule, now applied over many
-- parts instead of one.
local function makeWorn(part: BasePart)
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
end

-- ============================================================ API

-- Assembles the multi-part model for a piece: every pack part named
-- `<Prefix>_<Slot>_*`, cloned, painted by role, tagged with its target.
-- nil when the pack has no such parts (not imported, or this set has not been
-- rebuilt yet) - the caller then tries `ArmorModel.legacy`.
function ArmorModel.build(piece): Model?
	local set = Armor.sets[piece.set]
	local suffix = ArmorModel.SLOT_SUFFIX[piece.slot]
	local pack = armorPack()
	if not (set and suffix and pack) then
		return nil
	end

	local wanted = set.modelPrefix .. "_" .. suffix .. "_"
	local origin = packOrigin(pack)
	local model = Instance.new("Model")
	local found = 0
	for _, source in pack:GetDescendants() do
		if source:IsA("BasePart") and string.sub(source.Name, 1, #wanted) == wanted then
			local target, role = splitTail(string.sub(source.Name, #wanted + 1))
			if target and role then
				local clone = source:Clone()
				stripAppearance(clone)
				makeWorn(clone)
				paint(clone, set.modelPrefix, role, piece)
				clone:SetAttribute("ArmorTarget", target)
				clone:SetAttribute("ArmorRole", role)
				clone:SetAttribute("ArmorOffset", source.Position - origin)
				clone.Parent = model
				found += 1
			end
		end
	end

	if found == 0 then
		model:Destroy()
		return nil
	end
	return model
end

-- The legacy single-part clone (`<Prefix>_<Slot>`), painted the piece row's
-- one colour - exactly what ArmorService has always done. nil pre-import.
function ArmorModel.legacy(piece): BasePart?
	local set = Armor.sets[piece.set]
	local suffix = ArmorModel.SLOT_SUFFIX[piece.slot]
	local pack = armorPack()
	if not (set and suffix and pack) then
		return nil
	end
	-- The importer wraps each mesh in a <name>_Node; search recursively.
	local template = pack:FindFirstChild(set.modelPrefix .. "_" .. suffix, true)
	if not (template and template:IsA("BasePart")) then
		return nil
	end
	local clone = template:Clone()
	stripAppearance(clone)
	makeWorn(clone)
	if piece.color then
		clone.Color = piece.color
	end
	return clone
end

-- Sizes one assembled sub-part to the rig it is about to be worn on, and
-- returns the local CFrame offset the weld should apply.
--
-- WHY THIS EXISTS. The pack is authored against ArmorPalette.FIT, whose six
-- LIMB rows are PROVISIONAL (see assets/armor_palette.py). Rather than trust
-- them, this reads the rig's REAL `target.Size` and scales the shell - and
-- its offset from the joint - by actual/authored, per axis. So a wrong
-- authored number costs fit PRECISION and nothing else: the shell still sits
-- on the limb at the same proportion of its surface, instead of clipping
-- through a bigger part or floating off a smaller one. It also means one
-- pack dresses a default rig, a slim avatar and a scaled character with no
-- second export.
--
-- The offset is in PACK axes and the scale in the target part's axes; the
-- half-turn between them (ArmorService's PACK_FACING) maps X to -X and Z to
-- -Z, so the per-axis MAGNITUDES correspond and a componentwise scale is
-- correct in either frame.
--
-- No FIT row for the target (a name naming a part the table never listed):
-- scale 1, offset as authored. Loose, but worn.
function ArmorModel.fitTo(part: BasePart, target: BasePart): CFrame
	local targetName = part:GetAttribute("ArmorTarget")
	local authored = if type(targetName) == "string" then ArmorPalette.FIT[targetName] else nil
	local stored = part:GetAttribute("ArmorOffset")
	local offset = if typeof(stored) == "Vector3" then stored else Vector3.zero
	if not authored then
		return CFrame.new(offset)
	end
	local actual = target.Size
	local scale = Vector3.new(actual.X / authored.X, actual.Y / authored.Y, actual.Z / authored.Z)
	part.Size = part.Size * scale
	return CFrame.new(offset * scale)
end

-- The R15 parts an assembled model encloses, and whose body part should
-- therefore go invisible: the targets that received an `Under`. The Head is
-- excluded unless the set is one of the declared full masks.
function ArmorModel.hiddenTargets(model: Model, prefix: string): { string }
	local seen = {}
	local targets = {}
	for _, part in model:GetChildren() do
		if part:IsA("BasePart") and part:GetAttribute("ArmorRole") == "Under" then
			local target = part:GetAttribute("ArmorTarget")
			if type(target) == "string" and not seen[target] then
				if target ~= "Head" or ArmorPalette.hidesFace[prefix] then
					seen[target] = true
					table.insert(targets, target)
				end
			end
		end
	end
	return targets
end

return ArmorModel
