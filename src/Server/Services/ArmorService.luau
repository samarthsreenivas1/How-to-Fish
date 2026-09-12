--!nonstrict
-- ArmorService.luau
-- Makes worn armor VISIBLE: welds each equipped piece's meshes onto the
-- wearer's character so every player sees it. The gameplay half (defense /
-- health / set bonuses, the equip flow, the attributes) lives in Armor.luau
-- + InventoryService; this service only reads the three replicated
-- attributes (Armor.ATTRIBUTES - nil when a slot is bare) and dresses the
-- character to match.
--
-- WHAT THE PIECE LOOKS LIKE is not decided here - `Shared.Modules.ArmorModel`
-- assembles and paints it (the WeaponModel / RodModel / CreatureModel
-- split). This file owns the LIFECYCLE: attributes in, parts welded onto a
-- live rig, body parts hidden and restored, nothing left behind.
--
-- Meshes come from the imported ArmorPack (assets/armor_gen.py) and there are
-- TWO name shapes, both supported, in this order:
--
--   1. `<Prefix>_<Slot>_<Target>_<Role>` - the multi-part redesign. One piece
--      dresses a whole REGION (a chest covers the torso, both arms and both
--      hands), each object welding to the R15 part its own name names.
--   2. `<Prefix>_<Slot>` - the legacy single part, which is what the shipped
--      pack still carries. Unchanged behaviour: one clone, one colour, on the
--      slot's primary target.
--
-- and if the pack is not imported at all, a simple tinted shell box - armor
-- is never invisible. Falling back PER SLOT rather than per sub-part is what
-- makes the pack re-import a non-breaking change instead of a flag day: a set
-- that has not been rebuilt yet keeps rendering exactly as it does today.
--
-- Worn pieces must never fight the character's physics: everything is
-- massless, collision-free, and welded to the limb - the WeaponService
-- pattern (and the fen's hard lesson). ArmorModel applies that to every part
-- it hands back; the fallback box sets it here.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Armor = require(Shared.Data.Armor)
local ArmorModel = require(Shared.Modules.ArmorModel)

local ArmorService = {}

-- slot -> character part names to weld onto, in preference order (R15 first,
-- R6 fallback). This is the ANCHOR only - the legacy single part, the
-- fallback box, and any multi-part object whose named target is missing from
-- the rig. A multi-part object normally welds to `character[Target]` straight
-- off its own name; see ArmorModel's header.
local SLOT_ANCHORS = {
	helmet = { "Head" },
	chest = { "UpperTorso", "Torso" },
	legs = { "LowerTorso", "Torso" },
}

-- On an R6 Torso (one part for the whole trunk) the chest rides high and the
-- hip skirt hangs low; R15 parts need no offset (meshes are authored centred
-- on them). An R6 rig has none of the limb targets either, so a multi-part
-- set collapses onto the Torso anchor with this same nudge - loose, but worn.
local R6_OFFSET = {
	chest = CFrame.new(0, 0.35, 0),
	legs = CFrame.new(0, -0.95, 0),
}

-- Half a turn, because the pack's front and the character's front are
-- opposite axes. armor_gen.py authors every piece FACING BLENDER -Y (its
-- header's stated contract: the helm's face opening, the chest's crossed
-- straps). The glTF Y-up export maps Blender -Y to Roblox +Z - the same
-- transform that sends the creature pack's Blender +X to Roblox +X - while a
-- character faces its own -Z (LookVector). Without this yaw a helm's horns
-- sit behind the head and its neck flare covers the face.
--
-- Applied here rather than by re-authoring the pack so its contract stays
-- exactly as written and as built. If a future pack ever authors to +Y
-- instead, drop this and say so in armor_gen.py's header.
local PACK_FACING = CFrame.Angles(0, math.pi, 0)

-- Body parts this service made invisible, and the transparency they had
-- before: [character] = { [slot] = { [BasePart] = originalTransparency } }.
-- Weak keys, so a character that despawns takes its bookkeeping with it -
-- and a fresh CharacterAdded rig is fully opaque anyway, so nothing leaks.
--
-- Per SLOT, because that is the granularity an unequip happens at. The three
-- slots' target regions are disjoint (head / torso+arms+hands /
-- hips+legs+feet), so two slots can never claim the same part and a restore
-- can never fight another slot's hide.
local hiddenParts = setmetatable({}, { __mode = "k" })

-- ============================================================ helpers

local function wornName(slot: string): string
	return "Armor_" .. slot
end

-- Fallback shell size when a slot has no authored mesh at all: a box just
-- proud of the anchor part (legs read as a hip band, not a full wrap).
local function fallbackSize(slot: string, target: BasePart): Vector3
	if slot == "legs" then
		return Vector3.new(target.Size.X + 0.35, 0.85, target.Size.Z + 0.35)
	end
	return target.Size + Vector3.new(0.3, 0.3, 0.3)
end

local function findAnchor(character: Model, slot: string): BasePart?
	for _, name in SLOT_ANCHORS[slot] do
		local part = character:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			return part
		end
	end
	return nil
end

-- One part onto one body part. `localOffset` is the sub-part's own offset
-- from the joint (multi-part only, from ArmorModel.fitTo); the legacy single
-- part and the fallback box pass nothing, which leaves their placement
-- exactly as it has always been.
local function weldTo(part: BasePart, target: BasePart, slot: string, localOffset: CFrame?)
	-- Meshes are authored centred on the target part's frame; R6's single
	-- Torso needs the slot nudged into place. The yaw turns the pack's front
	-- to the character's (see PACK_FACING); it commutes with the R6 offset,
	-- which is a pure lift along the same axis, and it must come BEFORE the
	-- sub-part offset, which is expressed in the pack's own axes. The
	-- fallback box is symmetric, so the yaw is harmless there.
	local offset = if target.Name == "Torso" then (R6_OFFSET[slot] or CFrame.identity) else CFrame.identity
	part.CFrame = target.CFrame * offset * PACK_FACING * (localOffset or CFrame.identity)

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = target
	weld.Part1 = part
	weld.Parent = part
end

-- ============================================================ body hiding

-- Restore every body part this slot hid, then forget them. Must run on ANY
-- path that removes the slot's model, or a player who takes off a chestpiece
-- is left armless - the loudest possible version of this bug and the reason
-- the bookkeeping is explicit rather than recomputed from the model.
local function showBody(character: Model, slot: string)
	local perSlot = hiddenParts[character]
	local record = perSlot and perSlot[slot]
	if not record then
		return
	end
	for part, transparency in record do
		if part.Parent then
			part.Transparency = transparency
		end
	end
	perSlot[slot] = nil
end

-- Hide the body parts an assembled model fully encloses (the targets that
-- received an `Under`). ArmorModel decides the set, including the never-hide-
-- the-Head rule and its three declared full-mask exceptions.
local function hideBody(character: Model, slot: string, model: Model, prefix: string)
	local targets = ArmorModel.hiddenTargets(model, prefix)
	if #targets == 0 then
		return
	end
	local record = {}
	for _, name in targets do
		local part = character:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			record[part] = part.Transparency
			part.Transparency = 1
		end
	end
	local perSlot = hiddenParts[character]
	if not perSlot then
		perSlot = {}
		hiddenParts[character] = perSlot
	end
	perSlot[slot] = record
end

-- ============================================================ dressing

local function removePiece(character: Model, slot: string)
	showBody(character, slot)
	local existing = character:FindFirstChild(wornName(slot))
	if existing then
		existing:Destroy()
	end
end

-- Path 1: the multi-part model. Welds each part to the R15 part its name
-- names, falling back to the slot anchor for a rig that lacks it (R6, or a
-- rig missing a limb). Returns false if nothing could be welded at all, so
-- the caller drops through to the legacy path.
local function attachMultiPart(character: Model, slot: string, piece, prefix: string, anchor: BasePart?): boolean
	local model = ArmorModel.build(piece)
	if not model then
		return false
	end

	local welded = 0
	for _, part in model:GetChildren() do
		if part:IsA("BasePart") then
			local targetName = part:GetAttribute("ArmorTarget")
			local target = if type(targetName) == "string" then character:FindFirstChild(targetName) else nil
			if not (target and target:IsA("BasePart")) then
				target = anchor
			end
			if target then
				-- Scale the shell to the rig's real part size before welding: the
				-- FIT table's limb rows are provisional, and this is what keeps a
				-- wrong one costing fit precision rather than clipping.
				weldTo(part, target, slot, ArmorModel.fitTo(part, target))
				welded += 1
			else
				part:Destroy()
			end
		end
	end

	if welded == 0 then
		model:Destroy()
		return false
	end

	model.Name = wornName(slot)
	model:SetAttribute("PieceId", piece.id)
	model.Parent = character
	hideBody(character, slot, model, prefix)
	return true
end

local function attachPiece(character: Model, slot: string, piece)
	removePiece(character, slot)

	local set = Armor.sets[piece.set]
	local prefix = if set then set.modelPrefix else ""
	local anchor = findAnchor(character, slot)

	if attachMultiPart(character, slot, piece, prefix, anchor) then
		return
	end

	-- Path 2 + 3: the legacy single part, else the tinted box. Both need an
	-- anchor; a rig with neither an UpperTorso nor a Torso is not a rig.
	if not anchor then
		return
	end

	local worn = ArmorModel.legacy(piece)
	if not worn then
		worn = Instance.new("Part")
		worn.Size = fallbackSize(slot, anchor)
		worn.Anchored = false
		worn.CanCollide = false
		worn.CanQuery = false
		worn.CanTouch = false
		worn.Massless = true
		if piece.color then
			worn.Color = piece.color
		end
	end

	worn.Name = wornName(slot)
	worn:SetAttribute("PieceId", piece.id)
	weldTo(worn, anchor, slot)
	worn.Parent = character
end

-- Dress one slot from its attribute (nil = bare), on the current character.
local function applySlot(player: Player, slot: string)
	local character = player.Character
	if not character then
		return
	end
	local pieceId = player:GetAttribute(Armor.ATTRIBUTES[slot])
	local piece = if type(pieceId) == "string" then Armor.items[pieceId] else nil
	if piece and piece.slot == slot then
		attachPiece(character, slot, piece)
	else
		removePiece(character, slot)
	end
end

local function applyAll(player: Player)
	for _, slot in Armor.SLOTS do
		applySlot(player, slot)
	end
end

-- ============================================================ lifecycle

local function onPlayerAdded(player: Player)
	for _, slot in Armor.SLOTS do
		player:GetAttributeChangedSignal(Armor.ATTRIBUTES[slot]):Connect(function()
			applySlot(player, slot)
		end)
	end
	player.CharacterAdded:Connect(function(character)
		-- The rig's parts stream in with the character; a deferred pass sees
		-- them all (the WeaponService WaitForChild approach, without holding
		-- a thread per limb).
		task.defer(function()
			if player.Character == character then
				applyAll(player)
			end
		end)
	end)
	if player.Character then
		applyAll(player)
	end
end

function ArmorService.init()
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return ArmorService
