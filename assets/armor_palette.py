# armor_palette.py
# THE one place an armor colour or surface material is written down.
#
# Pure Python - NO `bpy` import, on purpose. Two consumers read it:
#
#   * assets/armor_gen.py       imports it for the mannequin preview's
#                               materials, so the render and the game agree
#                               on colour by construction.
#   * tools/gen_armor_palette.py  writes src/Shared/Config/ArmorPalette.luau
#                               from it (plain python3, no Blender, seconds).
#
# Hand-typing the same table in two languages is the exact failure
# tools/gen_mesh_colors.py's header documents (a parallel lane maintained half
# a table by hand and left 33 rows out; every gate passed). So: edit HERE,
# then re-run `python3 tools/gen_armor_palette.py` and
# `python3 tools/check_armor_palette.py`. Never hand-edit the .luau.
#
# ---------------------------------------------------------------- the roles
#
# Every mesh object in the ArmorPack carries exactly ONE role, encoded in its
# name (see armor_gen.py's naming contract: <Prefix>_<Slot>_<Target>_<Role>).
# The role supplies BOTH the object's colour and its Enum.Material:
#
#   Under   the under-suit / body glove; the coverage layer.   standoff 0.06
#           A target that gets an Under also gets its body part hidden at
#           equip (ArmorModel), which is what makes full coverage read as a
#           suit rather than as loose plates.
#   Plate   the set's hard armour; the primary silhouette read.  0.15-0.30
#   Trim    cords, straps, buckles, rivets, fur edging.           0.10-0.20
#   Accent  the one secondary luxury material (inlay, cape, ribbon).
#   Glow    luminous sources only, where the MATERIAL is luminous (Neon).
#
# Accent falls back to Plate and Glow falls back to Accent at runtime (the
# same idiom WeaponModel.colorMeshParts uses, WeaponModel.luau:238-240), so
# three declared roles (Under / Plate / Trim) is the floor per set.
#
# ------------------------------------------------------------ colour policy
#
# PALETTES ARE DERIVED, NEVER INVENTED. Every rgb below is either
#   (a) a Materials.items[*].color from src/Shared/Data/Materials.luau - the
#       material the piece is actually crafted from, or
#   (b) a MESH_COLOR row from src/Server/Services/WorldService.luau - the
#       island the set comes from,
# and the `cite` field names which, verbatim, for every single row. A row
# whose colour is a darkened/lifted/warmed version of its source says so.
# All 50 citations were verified against those two files on 2026-09-12.
#
# `material` must be a real Enum.Material member name; ArmorModel indexes
# Enum.Material[material]. `transparency` 0.0 unless the design calls for
# glass/shroud. `neon` is redundant with material == "Neon" and is kept as
# the explicit design intent (a Neon role is a LIGHT, not a tint).

# ---------------------------------------------------------------- the R15 fit
#
# THE SHARED FIT TABLE, and it is shared THREE ways: armor_gen.py authors and
# previews against it, and gen_armor_palette.py emits it into
# ArmorPalette.luau so ArmorModel can scale a sub-part to the rig it is
# actually being worn on. One table, three consumers, no hand-copies.
#
#   size   = (x, y, z) in studs at the part's own centre, in BLENDER axes
#            (width, depth, height). Roblox's own order is (X, Y, Z) with Y
#            up, so the last two swap on the way out; the generator does the
#            swap once, in gen_armor_palette.py.
#   center = the part's centre in MANNEQUIN space, ground at z = 0. Used ONLY
#            by the preview renderer. Armour objects are still authored at the
#            ORIGIN centred on their target - that contract is unchanged.
#   mirror = the right-side twin, emitted by negating X on a copy.
#   chain  = the posable chain a part belongs to, for the preview's relaxed
#            A-pose ("arm" parts swing out about the shoulder).
#
# >> PINNED 2026-09-12 (wave 1) <<  These were PROVISIONAL - Roblox's
# documented default R15 sizes, never measured - and the wave-1 mannequin
# render showed what that cost: arms that reached the knees and legs 1.7x too
# long. Every judgement about a set's silhouette is made THROUGH this table,
# so a wrong number here does not look like a wrong number, it looks like bad
# art. Pinned now to:
#
#   * THE REPO'S OWN RIG. src/Server/Services/NpcService.luau's blockRig()
#     fallback (:485-488) builds every NPC body the player stands next to:
#     arms and legs Vector3.new(1, 2, 1) at x +/-1.5 (arms) and +/-0.5 (legs),
#     root 2 x 2 x 1. So a LIMB IS 2.0 STUDS TALL AND 1.0 SQUARE, and the two
#     x offsets are measured, not guessed. That is the one rig fact this
#     repository actually asserts anywhere.
#   * THE R15 SPLIT OF THAT 2.0, taken as the default R15 block rig's own
#     RATIOS (upper : lower : extremity = 1.2 : 1.2 : 0.4) and normalised onto
#     the 2.0 above: 0.86 : 0.86 : 0.28. Keeping the ratio rather than the raw
#     numbers is what makes the elbow and the knee land where a player expects
#     them while the limb still totals the 2.0 the repo's own rig uses.
#   * Head, UpperTorso and the hip width are unchanged - they are the three
#     constants all 30 shipped pieces are authored against and armor_gen.py
#     asserts them against HEAD / UPPER_TORSO / HIP_W.
#
# The asserts below the table are the point: arm sum, leg sum and standing
# height are checked at import, so the next person to "improve" a number here
# breaks a test instead of quietly breaking every render.
#
# Standing height = 2.00 leg + 0.40 LowerTorso + 1.60 UpperTorso + 1.20 Head
# = 5.20, i.e. the familiar 5.0-stud Roblox character plus the 0.2 an R15
# head is taller than an R6 one.
#
# It still costs FIT PRECISION AND NOTHING ELSE at equip: ArmorModel reads the
# rig's real `character[Target].Size` and scales each sub-part (and its
# offset) by actual/authored. If a real R15 rig measures differently, the
# armour is still worn correctly - it just was not DESIGNED against the right
# proportions, which is exactly the mistake being corrected here. To confirm
# on a live rig:
#
#     local c = game.Players.LocalPlayer.Character
#     for _, p in c:GetChildren() do
#         if p:IsA("BasePart") then print(p.Name, p.Size) end
#     end
#
# (Roblox prints X, Y, Z - swap the last two for this table's Blender order.)
FIT = {
    "Head": {"size": (1.20, 1.20, 1.20), "center": (0.0, 0.0, 4.60)},
    "UpperTorso": {"size": (2.00, 1.00, 1.60), "center": (0.0, 0.0, 3.20)},
    "LowerTorso": {"size": (2.00, 1.00, 0.40), "center": (0.0, 0.0, 2.20)},
    "LeftUpperArm": {
        "size": (1.00, 1.00, 0.86),
        "center": (-1.50, 0.0, 3.57),
        "mirror": "RightUpperArm",
        "chain": "arm",
    },
    "LeftLowerArm": {
        "size": (1.00, 1.00, 0.86),
        "center": (-1.50, 0.0, 2.71),
        "mirror": "RightLowerArm",
        "chain": "arm",
    },
    "LeftHand": {
        "size": (1.00, 1.00, 0.28),
        "center": (-1.50, 0.0, 2.14),
        "mirror": "RightHand",
        "chain": "arm",
    },
    "LeftUpperLeg": {
        "size": (1.00, 1.00, 0.86),
        "center": (-0.50, 0.0, 1.57),
        "mirror": "RightUpperLeg",
    },
    "LeftLowerLeg": {
        "size": (1.00, 1.00, 0.86),
        "center": (-0.50, 0.0, 0.71),
        "mirror": "RightLowerLeg",
    },
    "LeftFoot": {
        "size": (1.00, 1.00, 0.28),
        "center": (-0.50, 0.0, 0.14),
        "mirror": "RightFoot",
    },
}

# The rig facts, asserted rather than commented. A limb is 2.00 studs and the
# character stands 5.20 - if an edit here breaks either, it breaks at import.
_ARM = sum(FIT["Left%s" % p]["size"][2] for p in ("UpperArm", "LowerArm", "Hand"))
_LEG = sum(FIT["Left%s" % p]["size"][2] for p in ("UpperLeg", "LowerLeg", "Foot"))
_TALL = _LEG + FIT["LowerTorso"]["size"][2] + FIT["UpperTorso"]["size"][2] + FIT["Head"]["size"][2]
assert abs(_ARM - 2.00) < 1e-6, "FIT: an arm must total 2.00 studs, got %.3f" % _ARM
assert abs(_LEG - 2.00) < 1e-6, "FIT: a leg must total 2.00 studs, got %.3f" % _LEG
assert abs(_TALL - 5.20) < 1e-6, "FIT: the rig must stand 5.20 studs, got %.3f" % _TALL
for _part in ("LeftUpperArm", "LeftLowerArm", "LeftHand", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot"):
    assert FIT[_part]["size"][0] == 1.00 and FIT[_part]["size"][1] == 1.00, "FIT: %s is not 1.0 square" % _part
# Each chain's parts must STACK - no gaps, no overlaps - or the mannequin has
# a seam the armour cannot cover and nobody can see why.
for _chain in (("LeftFoot", "LeftLowerLeg", "LeftUpperLeg"), ("LeftHand", "LeftLowerArm", "LeftUpperArm")):
    for _lower, _upper in zip(_chain, _chain[1:]):
        _top = FIT[_lower]["center"][2] + FIT[_lower]["size"][2] / 2
        _bottom = FIT[_upper]["center"][2] - FIT[_upper]["size"][2] / 2
        assert abs(_top - _bottom) < 0.011, "FIT: %s and %s do not meet (%.3f vs %.3f)" % (_lower, _upper, _top, _bottom)

# The right-hand rows are MIRRORS of the left, generated rather than typed so
# the two halves cannot drift apart.
for _left, _row in list(FIT.items()):
    _twin = _row.get("mirror")
    if _twin:
        _cx, _cy, _cz = _row["center"]
        FIT[_twin] = {
            "size": _row["size"],
            "center": (-_cx, _cy, _cz),
            "mirror": _left,
            "chain": _row.get("chain"),
        }

# Which R15 parts each equip SLOT dresses. The three slots, the thirty pieces
# and check_content's enforced shape all stay exactly as they are - the slots
# simply take over whole REGIONS of the body instead of one part each, so a
# full set covers head, torso, both arms, both hands, both legs, both feet
# with no new data rows at all.
SLOT_TARGETS = {
    "Helm": ["Head"],
    "Chest": [
        "UpperTorso",
        "LeftUpperArm",
        "RightUpperArm",
        "LeftLowerArm",
        "RightLowerArm",
        "LeftHand",
        "RightHand",
    ],
    "Legs": [
        "LowerTorso",
        "LeftUpperLeg",
        "RightUpperLeg",
        "LeftLowerLeg",
        "RightLowerLeg",
        "LeftFoot",
        "RightFoot",
    ],
}

# Nothing solid further out than this at any height, or it fouls the arm swing.
SHOULDER_CLEAR = 1.35

# Role -> the authored standoff off the target part's surface, in studs.
# armor_gen.py's check_fit() enforces these; MAX_STANDOFF caps them.
STANDOFF = {
    "Under": 0.06,
    "Plate": 0.22,
    "Trim": 0.14,
    "Accent": 0.16,
    "Glow": 0.10,
}
MAX_STANDOFF = 0.30

ROLES = ("Under", "Plate", "Trim", "Accent", "Glow")

# Accent defaults to Plate, Glow defaults to Accent (then Plate).
ROLE_FALLBACK = {"Accent": "Plate", "Glow": "Accent"}

# Sets whose Under closes over the face BY DESIGN (a full mask). These three
# and only these three: check_faces() skips them, and ArmorModel is allowed
# to hide the Head for them. Everything else keeps the face open - a faceless
# avatar is not "cool", it is a bug report.
HIDES_FACE = ("Duskveil", "Wraithbound", "Stormcaller")


def _row(rgb, material, cite, transparency=0.0, neon=False):
    return {
        "rgb": rgb,
        "material": material,
        "transparency": transparency,
        "neon": neon,
        "cite": cite,
    }


PALETTES = {
    # ---------------------------------------------- Chitin - Tidebreak Cove
    # A fisherman lashing crab shell to himself with fishing line. Handmade
    # and cheap; the CORD is the detail that carries it.
    "Chitin": {
        "Under": _row((52, 74, 56), "Fabric", "kelp_fiber (94,156,92) darkened - woven kelp"),
        "Plate": _row((126, 150, 150), "Pebble", "barnacle_chitin verbatim"),
        "Trim": _row((168, 128, 84), "Wood", "driftwood verbatim"),
        "Accent": _row((150, 186, 210), "Foil", "fish_scale verbatim"),
    },
    # -------------------------------------------- Tideward - cove-late/Maren
    # A sou'wester and a scale lamellar coat: the most CIVILISED set.
    "Tideward": {
        "Under": _row((46, 62, 78), "Fabric", "Wreckwater_Bay (22,50,55) lifted - oiled navy canvas"),
        "Plate": _row((150, 186, 210), "Foil", "fish_scale verbatim"),
        "Trim": _row((94, 156, 92), "Fabric", "kelp_fiber verbatim"),
        "Accent": _row((238, 232, 240), "Marble", "pearl verbatim"),
    },
    # ------------------------------------------ Mirewalker - Blackmire Fen
    # A poacher's hooded long coat. Leather, not plate: the set that reads SOFT.
    "Mirewalker": {
        "Under": _row((44, 40, 32), "Leather", "mire_hide (104,96,58) darkened - peat-black cured hide"),
        "Plate": _row((94, 116, 72), "Sandstone", "gator_scute verbatim"),
        "Trim": _row((164, 98, 62), "CorrodedMetal", "bog_iron verbatim"),
        "Accent": _row((115, 131, 93), "LeafyGrass", "Swamp_HangMoss verbatim"),
    },
    # ------------------------------------- Boneplate - the drowned + the mire
    # A scrimshaw cuirass and a smooth half-mask; the curse does the work the
    # horns used to do.
    "Boneplate": {
        "Under": _row((38, 34, 30), "Fabric", "tarred cloth - cursed_bone (120,116,96) darkened to near-black"),
        "Plate": _row((120, 116, 96), "Limestone", "cursed_bone verbatim"),
        "Trim": _row((164, 98, 62), "CorrodedMetal", "bog_iron verbatim"),
        "Accent": _row((226, 232, 240), "Foil", "nacre verbatim"),
        "Glow": _row((173, 241, 196), "Neon", "Wreckwater_GhostGlow verbatim", neon=True),
    },
    # ------------------------------------------ Rimebound - Frostmaw Reach
    # A sealer's fur-collared parka with an ice-glass breastplate: the only
    # rounded, SOFT silhouette in the top half of the game.
    "Rimebound": {
        "Under": _row((224, 234, 242), "Snow", "rimewool verbatim"),
        # WAVE 2: transparency 0.12. everfrost_plate is "a slab of ICE off
        # something that fought back, and it has not begun to melt" - a slab
        # of ice that renders as opaque paint is the material lying about
        # itself. 0.12 is deliberately under Stormcaller's 0.15: storm_glass
        # is the see-through set and has to stay the most see-through one.
        "Plate": _row((148, 194, 232), "Glacier", "everfrost_plate verbatim", transparency=0.12),
        # WAVE 2: material Leather -> Snow, colour UNCHANGED. This row dresses
        # the fur ruff, the cuffs and the boot fur - the set's whole soft read
        # - and Leather on a ruff is a shiny dark strap, which is the opposite
        # of fur. Snow is the closest thing Enum.Material has to pelt. The
        # colour stays verbatim Frostmaw_DeadTrees because a DARK trim is the
        # only value separation in a set that is otherwise white-on-pale-blue.
        "Trim": _row((74, 62, 56), "Snow", "Frostmaw_DeadTrees verbatim - sealskin fur"),
        "Accent": _row((150, 196, 224), "Ice", "glacier_shard verbatim"),
        "Glow": _row((122, 218, 215), "Neon", "Frostmaw_Crystals verbatim", neon=True),
    },
    # ---------------------------------------- Cindershell - Ashfall Caldera
    # A forge-smith's harness. The heat lives in the SEAMS, not in spikes -
    # the only set whose glow is a network rather than a point.
    "Cindershell": {
        "Under": _row((66, 68, 82), "Basalt", "basalt_weave verbatim"),
        "Plate": _row((214, 106, 44), "Pebble", "cinder_scale verbatim"),
        "Trim": _row((48, 44, 60), "Marble", "obsidian_shard verbatim"),
        "Accent": _row((23, 23, 31), "Slate", "Volcano_Rocks verbatim"),
        "Glow": _row((255, 107, 15), "Neon", "Volcano_Lava verbatim", neon=True),
    },
    # ------------------------------------------- Duskveil - Gloomtrench
    # An anglerfish stalker: a smooth featureless full mask with ONE lantern
    # lure. Reads as a shape first and armour second.
    "Duskveil": {
        "Under": _row((42, 40, 56), "Leather", "duskhide verbatim"),
        "Plate": _row((90, 82, 110), "Slate", "gloom_scale verbatim"),
        "Trim": _row((96, 74, 140), "Fabric", "abyss_silk verbatim"),
        "Accent": _row((93, 90, 113), "Fabric", "Gloomtrench_Path verbatim"),
        "Glow": _row((255, 226, 130), "Neon", "lantern_gland verbatim", neon=True),
    },
    # ------------------------- Wraithbound - three seas (wreck + ice + gloom)
    # A drowned sailor who kept walking. TWO Neon roles is deliberate here
    # and ONLY here: the ribbon/joint split IS the three-seas identity.
    #
    # The shroud's hem fades 0.0 -> 0.55 down the hem objects. That grade is
    # PER-OBJECT, so it cannot live in a per-role row; the Trim row carries
    # the hem's base (0.0) and the wave-4 spec applies the grade by object
    # suffix. Noted here so the next reader does not "fix" the 0.0.
    "Wraithbound": {
        "Under": _row((34, 36, 44), "SmoothPlastic", "Maelstrom_Base (26,28,41) lifted - dark lacquer"),
        "Plate": _row((134, 150, 168), "Metal", "the wraithbound row's wraith grey, kept"),
        "Trim": _row((160, 255, 210), "Fabric", "wraith_essence verbatim"),
        "Accent": _row((150, 230, 200), "Neon", "aurora_essence verbatim", neon=True),
        "Glow": _row((170, 120, 255), "Neon", "abyss_ichor verbatim", neon=True),
    },
    # ------------------------- Corsair's Rest - Wreckwater ghost fleet, Epic
    # No recipes at all ("the fleet does not teach outsiders to forge its
    # dead"), so the palette comes from the ISLAND - which is correct for a
    # set with no material story.
    "CorsairsRest": {
        "Under": _row((44, 42, 38), "Fabric", "Wreckwater_Hulks (55,46,37) darkened - tarred slops"),
        "Plate": _row((55, 46, 37), "WoodPlanks", "Wreckwater_Hulks verbatim"),
        "Trim": _row((163, 131, 66), "Foil", "Wreckwater_Quay_Planks (121,103,79) warmed - brass"),
        "Accent": _row((189, 190, 179), "Fabric", "Wreckwater_Sails verbatim"),
        "Glow": _row((173, 241, 196), "Neon", "Wreckwater_GhostGlow verbatim", neon=True),
    },
    # ------------------------------------------ Stormcaller - Maelstrom, L43+
    # The most restrained set in the game and the coolest for exactly that
    # reason. The Plate is SEE-THROUGH (T = 0.15) - no other set is, and this
    # is the last set the player earns.
    "Stormcaller": {
        "Under": _row((26, 28, 41), "Fabric", "Maelstrom_Base verbatim - blackened cloth"),
        "Plate": _row((140, 190, 230), "Glass", "storm_glass verbatim", transparency=0.15),
        "Trim": _row((22, 23, 28), "Metal", "Maelstrom_Chains verbatim"),
        "Accent": _row((220, 230, 255), "Marble", "thunder_pearl verbatim"),
        "Glow": _row((107, 240, 255), "Neon", "Maelstrom_StormGlow verbatim", neon=True),
    },
}


# The set row's single `color` in src/Shared/Data/Armor.luau, keyed by
# modelPrefix - AFTER the five corrections the redesign lands.
#
# Armor.luau is the AUTHORITY: that field is the crafting/inventory tile
# swatch (CraftingController.luau:285, :548) and is also what the LEGACY
# single-part path paints a piece, so the preview renderer needs it to draw
# an honest "before" picture of a set that has not been rebuilt yet.
# tools/check_armor_palette.py cross-checks every row here against
# Armor.luau and fails if the two drift - the copy is a cache with a gate on
# it, not a second source.
#
# The five that CHANGED (each was invented rather than derived; the material
# now wins):
#   chitin        (214,148,110) -> (126,150,150)  barnacle_chitin
#   tideward      (150,176,194) -> (150,186,210)  fish_scale
#   boneplate     (222,214,192) -> (120,116,96)   cursed_bone
#   corsairs_rest (96,118,112)  -> (55,46,37)     Wreckwater_Hulks
#   stormcaller   (120,160,200) -> (140,190,230)  storm_glass
ROW_COLOR = {
    "Chitin": (126, 150, 150),
    "Tideward": (150, 186, 210),
    "Mirewalker": (104, 96, 58),
    "Boneplate": (120, 116, 96),
    "Rimebound": (148, 194, 232),
    "Cindershell": (214, 106, 44),
    "Duskveil": (42, 40, 56),
    "Wraithbound": (134, 150, 168),
    "CorsairsRest": (55, 46, 37),
    "Stormcaller": (140, 190, 230),
}


def hides_face(prefix):
    return prefix in HIDES_FACE


def row(prefix, role):
    """The palette row for a prefix+role, following the Accent->Plate->Glow
    fallback chain. None if the set has no such role at all."""
    block = PALETTES.get(prefix)
    if not block:
        return None
    seen = set()
    while role and role not in seen:
        if role in block:
            return block[role]
        seen.add(role)
        role = ROLE_FALLBACK.get(role)
    return None


def rgb01(prefix, role):
    """The row's colour as a 0..1 triple, for Blender."""
    r = row(prefix, role)
    if r is None:
        return (0.5, 0.5, 0.5)
    return tuple(c / 255.0 for c in r["rgb"])
