#!/usr/bin/env python3
"""Regenerate `src/Shared/Config/MeshColors.luau` from the mesh generators.

WHY THIS EXISTS (2026-08-31). Studio's glTF importer does NOT carry colour
across: every imported part arrives at Roblox's default grey. The islands
already knew this - `WorldService.MESH_COLOR` is a per-part table that repaints
them at placement - but the arena and boss packs had no equivalent, so the
first import of the Tidebreak came up entirely grey, boss included.

The table is GENERATED rather than typed, and that is the point. A parallel
lane hand-maintained the islet half of the island table and left 33 of its
parts out; every gate passed, because nothing in stylua/selene/rojo/
check_content knows that a name in a Blender script needs a matching row in a
Luau table. Absence is only loud when something is looking. Generating the
rows from the builders themselves means a new mesh object cannot be forgotten
- it means re-running this.

USAGE - after ANY change to an arena or boss builder:

    python3 tools/gen_mesh_colors.py

It drives Blender once per target (13 of them, so it takes a few minutes),
reads each object's REAL authored colour, and rewrites the Luau module.

READING THE COLOUR IS THE FIDDLY PART, and the obvious way is wrong. An
object's `diffuse_color` is Blender's VIEWPORT SWATCH, not its material: it
reads a perfectly plausible (204, 204, 204) for every object in the scene, so
a probe using it produces a full table of confident greys and looks like it
worked. The authored value lives on the material's Principled BSDF "Base
Color" input, which is what the generators write and what the exporter emits.

The float -> 0..255 mapping is a plain `round(f * 255)` with NO gamma
conversion. That is not a guess: it is the mapping `WorldService.MESH_COLOR`
already uses, derived from island_gen's own constants - `M_Grass` is
(0.424, 0.698, 0.361) and its shipped row is fromRGB(108, 178, 92), which is
exactly 0.424*255, 0.698*255, 0.361*255. Matching the convention that already
ships beats inventing a more theoretically correct one.
"""

import os
import re
import subprocess
import sys
import tempfile

BLENDER = os.environ.get("BLENDER", "/opt/homebrew/bin/blender")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "src", "Shared", "Config", "MeshColors.luau")

# (generator, target) pairs. Kept explicit rather than imported, because these
# modules only load inside Blender.
ARENAS = ["brinejaw", "gnashroot", "wrack", "rimefang", "noctyss", "pyrelisk"]
BOSSES = ["brinejaw", "kraken", "gnashroot", "noctyss", "rimefang", "pyrelisk", "wrack"]

DUMP = '''
import bpy
def base_color(mat):
    if not mat or not mat.use_nodes:
        return None
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    if not bsdf:
        return None
    v = bsdf.inputs["Base Color"].default_value
    return (round(v[0] * 255), round(v[1] * 255), round(v[2] * 255))
print("=== COLORS ===")
for obj in sorted(bpy.data.objects, key=lambda o: o.name):
    if obj.type != "MESH":
        continue
    slots = [s.material for s in obj.material_slots if s.material]
    for i, m in enumerate(slots):
        rgb = base_color(m)
        if rgb:
            # A multi-material object splits on export and Studio numbers the
            # 2nd and 3rd parts <Name>2 / <Name>3 (the Island_Base precedent).
            print("COLOR %s%s %d %d %d" % (obj.name, "" if i == 0 else str(i + 1), *rgb))
print("=== END ===")
'''


def run(generator, target, dump_path, tmpdir):
    out = os.path.join(tmpdir, "%s_%s.glb" % (generator, target))
    cmd = [
        BLENDER,
        "--background",
        "--python",
        os.path.join(ROOT, "assets", generator),
        "--python",
        dump_path,
        "--",
        out,
        target,
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    rows = {}
    for line in proc.stdout.splitlines():
        m = re.match(r"^COLOR (\S+) (\d+) (\d+) (\d+)$", line)
        if m:
            rows[m.group(1)] = (int(m.group(2)), int(m.group(3)), int(m.group(4)))
    if not rows:
        sys.stderr.write("  !! %s %s produced no colours\n" % (generator, target))
        sys.stderr.write(proc.stdout[-800:] + "\n" + proc.stderr[-800:] + "\n")
    return rows


def main():
    colors = {}
    conflicts = []
    with tempfile.TemporaryDirectory() as tmpdir:
        dump_path = os.path.join(tmpdir, "dump.py")
        with open(dump_path, "w") as handle:
            handle.write(DUMP)
        for generator, targets in (("arena_gen.py", ARENAS), ("boss_gen.py", BOSSES)):
            for target in targets:
                rows = run(generator, target, dump_path, tmpdir)
                print("  %-14s %-10s %3d objects" % (generator, target, len(rows)))
                for name, rgb in rows.items():
                    if name in colors and colors[name] != rgb:
                        conflicts.append((name, colors[name], rgb))
                    colors[name] = rgb

    # A name meaning two colours would make the table order-dependent, which is
    # exactly the silent kind of wrong this file exists to prevent.
    for name, a, b in conflicts:
        sys.stderr.write("  !! %s authored twice with different colours: %s vs %s\n" % (name, a, b))

    lines = [
        "--!strict",
        "-- MeshColors.luau",
        "-- GENERATED by tools/gen_mesh_colors.py - do not hand-edit.",
        "--",
        "-- Studio's glTF importer does not carry colour across: every imported part",
        "-- arrives at Roblox's default grey. This is the per-part repaint for the",
        "-- ARENA and BOSS packs, the same job WorldService.MESH_COLOR does for the",
        "-- islands (that table stays where it is - it also carries per-part MATERIAL",
        "-- and water-layer handling that these packs do not need).",
        "--",
        "-- Re-run the generator after any change to an arena or boss builder. A part",
        "-- with no row here keeps the importer's grey, and BossArenaService warns by",
        "-- name when that happens rather than leaving someone to notice a flat arena.",
        "",
        "local MeshColors = {}",
        "",
        "MeshColors.items = {",
    ]
    for name in sorted(colors):
        r, g, b = colors[name]
        lines.append('\t["%s"] = Color3.fromRGB(%d, %d, %d),' % (name, r, g, b))
    lines += [
        "}",
        "",
        "-- The colour for an imported part, or nil if the packs never authored one.",
        "function MeshColors.get(partName: string): Color3?",
        "\treturn MeshColors.items[partName]",
        "end",
        "",
        "return MeshColors",
        "",
    ]
    with open(OUT, "w") as handle:
        handle.write("\n".join(lines))
    print("\nwrote %s - %d parts" % (os.path.relpath(OUT, ROOT), len(colors)))
    if conflicts:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
