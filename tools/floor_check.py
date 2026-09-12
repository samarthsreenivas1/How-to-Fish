#!/usr/bin/env python3
"""floor_check - where does a player LAND, and on what?

Rebuilt at this path on 2026-09-12. It used to live in a session scratchpad
(`scratchpad/floor_check.py`) and those are purged, so every reference to it in
the docs and in the generators' comments has been dangling: arena_gen's
PY_CLEAR_R cites it by name for the measurement that set the constant, and the
pyrelisk checklist owes a run of it against the climb route. It lives in
`tools/` now so that stops happening. UNTRACKED on purpose - do not `git add`
it; it is a measuring instrument, not content.

WHAT IT DOES. Loads an exported glb, fires a ray straight DOWN at a probe
point, and reports the height of the first surface under it AND WHICH OBJECT
was hit. The second half is the point: "the floor is at y 7.25" is useless
next to "the floor is at y 7.25 and it is the Rim, not the Base" - which is
exactly how the volcano's outer path turned out to be under an overhang.

    blender --background --python tools/floor_check.py -- <file.glb> \\
        [--at X,Z ...] [--ring R:COUNT ...] [--radial BEARING:R0:R1:STEP] \\
        [--from-y 2000] [--roblox]

THE AXIS TRAP, and it is the one thing a caller must get right. These packs
are exported y-up (`export_yup`), so a point authored in Blender at (x, y, z)
arrives in Roblox as (x, z, -y). Going the other way - which is what a caller
does when it has a Roblox probe point and wants to ask the .blend-space mesh
about it - the ROBLOX Z MUST BE NEGATED to get the blender y:

    blender_x = roblox_x        blender_y = -roblox_z        blender_z = roblox_y

Pass `--roblox` and the probe points you give are read as Roblox (x, z) pairs
and negated for you; without it they are taken as blender (x, y) and used as
given. Getting this wrong is silent and it is symmetric: the probe lands on
the mirror image of the spot you meant, which on a body with two arms is the
OTHER arm and looks like a rig bug rather than a units bug.
"""
import math
import os
import sys

import bpy
from mathutils import Vector


def _argv():
    return sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []


def load(path):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    ext = os.path.splitext(path)[1].lower()
    if ext == ".glb" or ext == ".gltf":
        bpy.ops.import_scene.gltf(filepath=path)
    elif ext == ".obj":
        bpy.ops.wm.obj_import(filepath=path)
    else:
        raise SystemExit("floor_check: don't know how to load %s" % path)
    return [o for o in bpy.context.scene.objects if o.type == "MESH"]


def probe(meshes, x, y, from_z):
    """The first surface below (x, y, from_z): its height and the object.

    Rays are cast per object in that object's own local space, because
    `Object.ray_cast` wants local coordinates - handing it world ones is the
    other silent failure this tool can have, and it presents as "nothing is
    under the probe" on a scene that is visibly solid.
    """
    best_z, best_obj = None, None
    origin_world = Vector((x, y, from_z))
    for obj in meshes:
        try:
            inv = obj.matrix_world.inverted()
        except ValueError:
            continue
        origin = inv @ origin_world
        direction = (inv.to_3x3() @ Vector((0.0, 0.0, -1.0)))
        if direction.length < 1e-9:
            continue
        hit, location, _normal, _index = obj.ray_cast(origin, direction.normalized())
        if not hit:
            continue
        world = obj.matrix_world @ location
        if best_z is None or world.z > best_z:
            best_z, best_obj = world.z, obj.name
    return best_z, best_obj


def main():
    argv = _argv()
    if not argv:
        print(__doc__)
        return
    path = argv[0]
    points, from_z, roblox = [], 2000.0, False
    index = 1
    while index < len(argv):
        flag = argv[index]
        if flag == "--roblox":
            roblox = True
            index += 1
        elif flag == "--from-y":
            from_z = float(argv[index + 1])
            index += 2
        elif flag == "--at":
            a, b = argv[index + 1].split(",")
            points.append((float(a), float(b), "at"))
            index += 2
        elif flag == "--ring":
            radius, count = argv[index + 1].split(":")
            radius, count = float(radius), int(count)
            for k in range(count):
                bearing = (k / count) * math.tau
                points.append((math.cos(bearing) * radius, math.sin(bearing) * radius,
                               "r%.0f b%.0f" % (radius, math.degrees(bearing))))
            index += 2
        elif flag == "--radial":
            bearing, r0, r1, step = (float(v) for v in argv[index + 1].split(":"))
            radius = r0
            while radius <= r1 + 1e-6:
                points.append((math.cos(math.radians(bearing)) * radius,
                               math.sin(math.radians(bearing)) * radius,
                               "b%.0f r%.1f" % (bearing, radius)))
                radius += step
            index += 2
        else:
            raise SystemExit("floor_check: unknown flag %s" % flag)

    meshes = load(path)
    print("floor_check: %s - %d meshes, probing from z %.0f, points read as %s"
          % (os.path.basename(path), len(meshes), from_z, "ROBLOX (x, z) [negating z -> y]" if roblox else "BLENDER (x, y)"))
    print("%-16s %10s %10s   %10s  %s" % ("label", "probe x", "probe y", "surface", "object"))
    for x, y, label in points:
        px, py = (x, -y) if roblox else (x, y)
        height, name = probe(meshes, px, py, from_z)
        if height is None:
            print("%-16s %10.2f %10.2f   %10s  %s" % (label, px, py, "NOTHING", "-"))
        else:
            print("%-16s %10.2f %10.2f   %10.3f  %s" % (label, px, py, height, name))


if __name__ == "__main__":
    main()
