--!nonstrict
-- ArmorService.luau
-- Makes worn armor VISIBLE: welds each equipped piece's mesh onto the
-- wearer's character so every player sees it. The gameplay half (defense /
-- health / set bonuses, the equip flow, the attributes) lives in Armor.luau
-- + InventoryService; this service only reads the three replicated
-- attributes (Armor.ATTRIBUTES - nil when a slot is bare) and dresses the
-- character to match.
--
-- Meshes come from the imported ArmorPack (assets/armor_gen.py):
-- <Prefix>_Helm / _Chest / _Legs where Prefix = Armor.sets[piece.set]
-- .modelPrefix, each authored CENTERED on its body part's frame, so a clone
-- welds on with the part's own CFrame. Until the pack is imported (or for a
-- set whose mesh isn't authored yet) a piece falls back to a simple tinted
-- shell box - armor is never invisible.
--
-- Worn pieces must never fight the character's physics: everything is
-- massless, collision-free, and welded to the limb - the WeaponService
-- pattern (and the fen's hard lesson).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Armor = require(Shared.Data.Armor)

local ArmorService = {}

-- slot -> the ArmorPack mesh suffix.
local SLOT_SUFFIX = {
	helmet = "Helm",
	chest = "Chest",
	legs = "Legs",
}

-- slot -> character part names to weld onto, in preference order (R15 first,
-- R6 fallback).
local SLOT_TARGETS = {
	helmet = { "Head" },
	chest = { "UpperTorso", "Torso" },
	legs = { "LowerTorso", "Torso" },
}

-- On an R6 Torso (one part for the whole trunk) the chest rides high and the
-- hip skirt hangs low; R15 parts need no offset (meshes are authored centred
-- on them).
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
-- Applied here rather than by re-authoring 30 meshes so the pack's contract
-- stays exactly as written and as built. If a future pack ever authors to
-- +Y instead, drop this and say so in armor_gen.py's header.
local PACK_FACING = CFrame.Angles(0, math.pi, 0)

-- Fallback shell sizes when a slot has no authored mesh: a box just proud of
-- the target part (legs read as a hip band, not a full wrap).
local function fallbackSize(slot: string, target: BasePart): Vector3
	if slot == "legs" then
		return Vector3.new(target.Size.X + 0.35, 0.85, target.Size.Z + 0.35)
	end
	return target.Size + Vector3.new(0.3, 0.3, 0.3)
end

local function wornName(slot: string): string
	return "Armor_" .. slot
end

-- ============================================================ dressing

local function removePiece(character: Model, slot: string)
	local existing = character:FindFirstChild(wornName(slot))
	if existing then
		existing:Destroy()
	end
end

local function findTarget(character: Model, slot: string): BasePart?
	for _, name in SLOT_TARGETS[slot] do
		local part = character:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			return part
		end
	end
	return nil
end

-- The authored mesh for a piece, or nil pre-import / pre-authoring.
local function pieceTemplate(piece): BasePart?
	local set = Armor.sets[piece.set]
	if not set then
		return nil
	end
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local pack = assets and assets:FindFirstChild("ArmorPack")
	local template = pack and pack:FindFirstChild(set.modelPrefix .. "_" .. SLOT_SUFFIX[piece.slot], true)
	return if template and template:IsA("BasePart") then template else nil
end

local function attachPiece(character: Model, slot: string, piece)
	removePiece(character, slot)

	local target = findTarget(character, slot)
	if not target then
		return
	end

	local worn: BasePart
	local template = pieceTemplate(piece)
	if template then
		worn = template:Clone()
		-- Strip any import-time dressing; the row's colour is the look.
		local appearance = worn:FindFirstChildWhichIsA("SurfaceAppearance")
		if appearance then
			appearance:Destroy()
		end
	else
		worn = Instance.new("Part")
		worn.Size = fallbackSize(slot, target)
	end

	worn.Name = wornName(slot)
	worn:SetAttribute("PieceId", piece.id)
	if piece.color then
		worn.Color = piece.color
	end
	worn.Anchored = false
	worn.CanCollide = false
	worn.CanQuery = false
	worn.CanTouch = false
	worn.Massless = true

	-- Meshes are authored centred on the target part's frame; R6's single
	-- Torso needs the slot nudged into place. The yaw turns the pack's front
	-- to the character's (see PACK_FACING); it commutes with the offset,
	-- which is a pure lift along the same axis. The fallback box is
	-- symmetric, so the yaw is harmless there.
	local offset = if target.Name == "Torso" then (R6_OFFSET[slot] or CFrame.identity) else CFrame.identity
	worn.CFrame = target.CFrame * offset * PACK_FACING

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = target
	weld.Part1 = worn
	weld.Parent = worn

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
