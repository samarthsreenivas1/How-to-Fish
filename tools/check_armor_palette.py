#!/usr/bin/env python3
"""Gate: the armor naming contract, the palette, and the generated Luau agree.

    python3 tools/check_armor_palette.py            # exit 1 on any failure
    python3 tools/check_armor_palette.py --strict   # ALSO fail on any piece
                                                    # still using the legacy
                                                    # two-field name

WHAT IT CHECKS. Every object in the ArmorPack is named

    <Prefix>_<Slot>_<Target>_<Role>[<n>]

and each field is a foreign key into a different file. Nothing else in the
repo notices when one of them drifts: stylua, selene, rojo and check_content
have no idea that a string in a Blender script has to match a key in a Luau
table. That is the failure `tools/gen_mesh_colors.py`'s header describes -
33 rows silently missing, every gate green. So:

  (a) every <Prefix> is a real `Armor.sets[*].modelPrefix`
  (b) every <Slot> is Helm | Chest | Legs
  (c) every <Target> is a key of armor_palette.FIT, and is a target the
      SLOT actually dresses (a Helm object on LeftFoot is a typo, not a look)
  (d) every <Role> resolves to a palette row for that set, following the
      Accent -> Plate and Glow -> Accent fallbacks
  (e) every set in Armor.sets has a palette block, and every palette block
      names a real set
  (f) every declared fit exception names an object of its own set
  (g) every palette `material` is a plausible Enum.Material member
  (h) armor_palette.ROW_COLOR matches the `color` on the actual pieces in
      Armor.luau - the copy the preview renderer reads is a cache with a gate
      on it, not a second source of truth
  (i) src/Shared/Config/ArmorPalette.luau is not stale

It reads armor_gen.py as TEXT (no Blender, no bpy - it runs in milliseconds)
and armor_palette.py as a plain import.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "assets"))
sys.path.insert(0, os.path.join(ROOT, "tools"))

import armor_palette  # noqa: E402
import gen_armor_palette  # noqa: E402

GEN = os.path.join(ROOT, "assets", "armor_gen.py")
ARMOR = os.path.join(ROOT, "src", "Shared", "Data", "Armor.luau")
OUT = os.path.join(ROOT, "src", "Shared", "Config", "ArmorPalette.luau")

SLOTS = ("Helm", "Chest", "Legs")

# Enum.Material members this repo's packs actually use or reasonably could.
# Not the full Roblox list - the point is to catch a typo ("Corrodedmetal")
# before Studio throws at equip, where `Enum.Material[name]` is indexed.
MATERIALS = {
    "Asphalt", "Basalt", "Brick", "Cobblestone", "Concrete", "CorrodedMetal",
    "CrackedLava", "DiamondPlate", "Fabric", "Foil", "ForceField", "Glacier",
    "Glass", "Granite", "Grass", "Ice", "Leather", "LeafyGrass", "Limestone",
    "Marble", "Metal", "Mud", "Neon", "Pavement", "Pebble", "Plastic", "Rock",
    "RoofShingles", "Rubber", "Salt", "Sand", "Sandstone", "SmoothPlastic",
    "Snow", "Slate", "Wood", "WoodPlanks",
}

problems = []
notes = []


def problem(message):
    problems.append(message)


def read(path):
    with open(path) as handle:
        return handle.read()


# ------------------------------------------------------------- the data side

armor_text = read(ARMOR)
gen_text = read(GEN)

prefixes = set(re.findall(r'modelPrefix\s*=\s*"([A-Za-z0-9_]+)"', armor_text))
if not prefixes:
    problem("Armor.luau: found no modelPrefix rows at all - has the file moved?")

# piece id -> (set id, colour), for the ROW_COLOR cross-check.
set_ids = {}
for block in re.finditer(
    r"Armor\.sets\.([A-Za-z0-9_]+)\s*=\s*\{(.*?)\n\}", armor_text, re.S
):
    found = re.search(r'modelPrefix\s*=\s*"([A-Za-z0-9_]+)"', block.group(2))
    if found:
        set_ids[block.group(1)] = found.group(1)

row_colors = {}
for block in re.finditer(r"Armor\.items\.([A-Za-z0-9_]+)\s*=\s*\{(.*?)\n\}", armor_text, re.S):
    body = block.group(2)
    which = re.search(r'set\s*=\s*"([A-Za-z0-9_]+)"', body)
    color = re.search(r"color\s*=\s*Color3\.fromRGB\((\d+),\s*(\d+),\s*(\d+)\)", body)
    if which and color:
        prefix = set_ids.get(which.group(1))
        if prefix:
            row_colors.setdefault(prefix, set()).add(tuple(int(c) for c in color.groups()))

# --------------------------------------------------------- (e) palette blocks

for prefix in sorted(prefixes):
    if prefix not in armor_palette.PALETTES:
        problem("palette: set '%s' has no block in armor_palette.PALETTES" % prefix)
for prefix in sorted(armor_palette.PALETTES):
    if prefix not in prefixes:
        problem("palette: block '%s' names no set in Armor.luau" % prefix)
    block = armor_palette.PALETTES[prefix]
    for role in ("Under", "Plate", "Trim"):
        if role not in block:
            problem("palette: %s is missing the required '%s' row" % (prefix, role))
    for role, row in block.items():
        if role not in armor_palette.ROLES:
            problem("palette: %s has unknown role '%s'" % (prefix, role))
        if row["material"] not in MATERIALS:
            problem(
                "palette: %s %s names material '%s', which is not an Enum.Material member"
                % (prefix, role, row["material"])
            )
        if row["material"] == "Neon" and not row["neon"]:
            problem("palette: %s %s is Neon material but neon=False" % (prefix, role))
        if not 0.0 <= row["transparency"] <= 1.0:
            problem("palette: %s %s transparency out of range" % (prefix, role))
        if not row.get("cite"):
            problem("palette: %s %s has no colour citation" % (prefix, role))
for prefix in armor_palette.HIDES_FACE:
    if prefix not in armor_palette.PALETTES:
        problem("palette: HIDES_FACE names '%s', which has no palette block" % prefix)

# --------------------------------------------------------- (h) ROW_COLOR cache

for prefix, rgb in sorted(armor_palette.ROW_COLOR.items()):
    actual = row_colors.get(prefix)
    if actual is None:
        problem("ROW_COLOR: '%s' matches no set in Armor.luau" % prefix)
    elif len(actual) > 1:
        problem(
            "ROW_COLOR: %s's three pieces disagree in Armor.luau: %s"
            % (prefix, ", ".join(str(c) for c in sorted(actual)))
        )
    elif rgb not in actual:
        problem(
            "ROW_COLOR: %s says %s, Armor.luau says %s - the preview would draw a lie"
            % (prefix, rgb, sorted(actual)[0])
        )
for prefix in sorted(prefixes):
    if prefix not in armor_palette.ROW_COLOR:
        problem("ROW_COLOR: no entry for set '%s'" % prefix)

# ---------------------------------------------------- (a-d) the object names


def check_name(name, where):
    fields = name.split("_")
    if len(fields) == 2:
        prefix, slot = fields
        if prefix in prefixes and slot in SLOTS:
            notes.append("%s is still the LEGACY two-field name" % name)
            if "--strict" in sys.argv[1:]:
                problem("%s: legacy two-field name '%s' (strict)" % (where, name))
            return
        problem("%s: '%s' is neither a four-field name nor a legacy piece" % (where, name))
        return
    if len(fields) != 4:
        problem("%s: '%s' does not split into four fields" % (where, name))
        return
    prefix, slot, target, role = fields
    role = role.rstrip("0123456789")
    if prefix not in prefixes:
        problem("%s: '%s' names set prefix '%s', which is not in Armor.luau" % (where, name, prefix))
    if slot not in SLOTS:
        problem("%s: '%s' names slot '%s', which is not Helm/Chest/Legs" % (where, name, slot))
        return
    if target not in armor_palette.FIT:
        problem("%s: '%s' names target '%s', which is not a key of FIT" % (where, name, target))
    elif target not in armor_palette.SLOT_TARGETS[slot]:
        problem(
            "%s: '%s' puts a %s object on %s, which that slot does not dress"
            % (where, name, slot, target)
        )
    if role not in armor_palette.ROLES:
        problem("%s: '%s' names role '%s', which is not a role" % (where, name, role))
    elif prefix in armor_palette.PALETTES and armor_palette.row(prefix, role) is None:
        problem("%s: '%s' has no %s row in %s's palette (even after fallback)" % (where, name, role, prefix))


literals = re.findall(r'finish\(\s*"([A-Za-z0-9_]+)"', gen_text)
for name in sorted(set(literals)):
    if name == "Mannequin":  # the preview prop, not a pack object
        continue
    check_name(name, "armor_gen.py finish()")

# ------------------------------- the spec layer's names, built not written out

spec_text = ""
found = re.search(r"\nSET_SPEC = \{\n(.*?)\n\}\n", gen_text, re.S)
if found:
    spec_text = found.group(1)
else:
    problem("armor_gen.py: SET_SPEC block not found")

spec_prefix = None
spec_slot = None
spec_names = []
declared_exceptions = []
for line in spec_text.splitlines():
    header = re.match(r'\s{4}"([A-Za-z0-9_]+)":\s*\{', line)
    if header:
        spec_prefix = header.group(1)
        if spec_prefix not in prefixes:
            problem("SET_SPEC: '%s' is not a set in Armor.luau" % spec_prefix)
        continue
    if re.match(r'\s{8}"fit_exceptions"', line):
        spec_slot = None
    slot_open = re.match(r'\s{8}"([A-Za-z0-9_]+)":\s*\[', line)
    if slot_open and slot_open.group(1) != "fit_exceptions":
        spec_slot = slot_open.group(1)
        if spec_slot not in SLOTS:
            problem("SET_SPEC: %s has slot key '%s'" % (spec_prefix, spec_slot))
        continue
    for name in re.findall(r'"([A-Za-z0-9_]+_(?:Helm|Chest|Legs)_[A-Za-z0-9_]+)"', line):
        declared_exceptions.append((spec_prefix, name))
    entry = re.search(r'"target":\s*"([A-Za-z0-9_]+)".*?"role":\s*"([A-Za-z0-9_]+)"', line)
    if entry and spec_slot:
        target, role = entry.groups()
        digit = re.search(r'"n":\s*(\d+)', line)
        suffix = digit.group(1) if digit else ""
        spec_names.append("%s_%s_%s_%s%s" % (spec_prefix, spec_slot, target, role, suffix))
        if '"mirror": True' in line and target in armor_palette.FIT:
            twin = armor_palette.FIT[target].get("mirror")
            if not twin:
                problem("SET_SPEC: %s asks to mirror %s, which has no mirror in FIT" % (spec_prefix, target))
            else:
                spec_names.append("%s_%s_%s_%s%s" % (spec_prefix, spec_slot, twin, role, suffix))

for name in spec_names:
    check_name(name, "SET_SPEC")

# --------------------------------------------------- (f) the fit exceptions

for prefix, name in declared_exceptions:
    check_name(name, "SET_SPEC fit_exceptions")
    if prefix and not name.startswith(prefix + "_"):
        problem("SET_SPEC: %s declares a fit exception for '%s', another set's object" % (prefix, name))

# ------------------------------------------------ (i) the generated Luau file

try:
    current = read(OUT)
except IOError:
    current = None
if current != gen_armor_palette.render():
    problem(
        "%s is STALE - run `python3 tools/gen_armor_palette.py`"
        % os.path.relpath(OUT, ROOT)
    )

# ------------------------------------------------------------------- report

print(
    "armor palette: %d sets, %d palette rows, %d FIT targets, %d name(s) checked"
    % (
        len(armor_palette.PALETTES),
        sum(len(b) for b in armor_palette.PALETTES.values()),
        len(armor_palette.FIT),
        len(set(literals)) + len(spec_names),
    )
)
if notes:
    print("  %d object(s) still on the legacy two-field name" % len(notes))
if problems:
    for message in problems:
        print("  !! " + message)
    print("armor palette: %d problem(s)" % len(problems))
    raise SystemExit(1)
print("armor palette: OK")
