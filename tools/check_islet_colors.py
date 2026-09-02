#!/usr/bin/env python3
"""Every islet mesh part needs a MESH_COLOR row, or it imports default grey.

The generator bakes colours into the .glb materials and Roblox does not read
them: the Luau table is the only thing that dresses an island. A missing row
is silent - it has a plausible-looking default - and no other gate can see it,
because none of them knows a Blender mesh implies a row in a Luau table.

v2 (2026-09-02): the expected part list is read from `assets/island_pack.glb`
- THE ARTIFACT ROBLOX IMPORTS - rather than regex-parsed out of the builders'
source. The redesigned builders emit objects through module helpers and
multi-line calls that a source regex cannot see, and v1 duly produced 100+
false findings against a correct table. The glb is ground truth by
construction: a mesh's primitives, in slot order, ARE the parts the importer
creates (Name / Name2 / Name3...). The cost is that the pack must be current;
the generator's own HANDOFF checks police that separately.

  python3 tools/check_islet_colors.py        # exits 1 on any mismatch
"""

import json
import pathlib
import re
import struct
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PACK = ROOT / "assets" / "island_pack.glb"

# Islet mesh-name prefixes. The seven big islands keep their own warn-at-boot
# coverage in WorldService; this tool owns the islets only.
PREFIXES = (
    "Bellbuoy_", "Chapel_", "Rookery_", "Boilshoal_", "Lampwork_",
    "Anchorage_", "Whalefall_", "Ferryraft_", "Loadstone_",
)


def pack_parts():
    data = PACK.read_bytes()
    if data[:4] != b"glTF":
        sys.exit(f"{PACK} is not a binary glTF")
    json_len, _ = struct.unpack_from("<II", data, 12)
    g = json.loads(data[20 : 20 + json_len])
    mat_names = [m.get("name", "?") for m in g.get("materials", [])]
    parts = {}
    for mesh in g["meshes"]:
        name = mesh["name"]
        if not name.startswith(PREFIXES):
            continue
        for i, prim in enumerate(mesh["primitives"]):
            part = name if i == 0 else f"{name}{i + 1}"
            parts[part] = mat_names[prim["material"]]
    return parts


expected = pack_parts()
world = (ROOT / "src" / "Server" / "Services" / "WorldService.luau").read_text()
block = re.search(r"local MESH_COLOR = \{(.*?)\n\}", world, re.S).group(1)
have = set(re.findall(r"^\t([A-Za-z0-9_]+) = Color3", block, re.M))

missing = sorted(p for p in expected if p not in have)
stale = sorted(p for p in have if p.startswith(PREFIXES) and p not in expected)

for p in missing:
    print(f"MISSING: {p} (material {expected[p]}) has no MESH_COLOR row - it will import default grey")
for p in stale:
    print(f"STALE:   {p} has a MESH_COLOR row but the pack no longer ships it")
if missing or stale:
    sys.exit(1)
islets = {p.split("_")[0] for p in expected}
print(f"ISLET COLOURS OK: {len(expected)} parts across {len(islets)} islets, every one has a row")
