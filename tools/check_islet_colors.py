#!/usr/bin/env python3
"""Every islet mesh part needs a MESH_COLOR row, or it imports default grey.

The generator bakes colours into the .glb materials and Roblox does not read
them: the Luau table is the only thing that dresses an island. A missing row
is silent - it has a plausible-looking default - and no other gate can see it,
because none of them knows a material name in a Blender script implies a row
in a Luau table. So this walks the builders, expands each object's material
list the way the importer does (Name / Name2 / Name3), and reports both
directions: parts with no row, and rows naming parts nothing builds any more.

  python3 tools/check_islet_colors.py        # exits 1 on any mismatch
"""
import re
import sys
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
gen = (ROOT / "assets" / "island_gen.py").read_text()
world = (ROOT / "src" / "Server" / "Services" / "WorldService.luau").read_text()

expected = {}
for m in re.finditer(r"def build_islet_(\w+)\(\):(.*?)(?=\ndef |\Z)", gen, re.S):
    islet, body = m.group(1), m.group(2)
    for om in re.finditer(
        r'(?:object_from_bmesh|build_island_base)\(\s*"([A-Za-z0-9_]+)"\s*,\s*(?:\w+\s*,\s*)?\[([^\]]*)\]', body
    ):
        mats = re.findall(r'"([A-Za-z0-9_]+)"', om.group(2))
        for i, mat in enumerate(mats):
            expected[om.group(1) if i == 0 else f"{om.group(1)}{i + 1}"] = (islet, mat)

# The MESH_COLOR table only - NON_COLLIDE and MESH_MATERIAL are string lists.
block = re.search(r"local MESH_COLOR = \{(.*?)\n\}", world, re.S).group(1)
have = set(re.findall(r"^\t([A-Za-z0-9_]+) = Color3", block, re.M))
islet_prefixes = {n.split("_")[0] for n in expected}

missing = sorted(n for n in expected if n not in have)
stale = sorted(n for n in have if n.split("_")[0] in islet_prefixes and n not in expected)

for n in missing:
    islet, mat = expected[n]
    print(f"MISSING: {n} (islet {islet}, material {mat}) has no MESH_COLOR row - it will import default grey")
for n in stale:
    print(f"STALE:   {n} has a MESH_COLOR row but no builder emits it any more")
if missing or stale:
    sys.exit(1)
print(f"ISLET COLOURS OK: {len(expected)} parts across {len(islet_prefixes)} islets, every one has a row")
