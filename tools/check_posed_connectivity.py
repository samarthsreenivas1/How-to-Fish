#!/usr/bin/env python3
"""Find boss geometry that is adrift ONCE THE BOSS IS POSED, by surface contact.

    blender --background --python tools/check_posed_connectivity.py -- \
        [--boss pyrelisk] [--root Pyrelisk_Core] [--contact 0.3] [--control] \
        [--glb assets/boss_pyrelisk.glb] [--export /tmp/posed.glb]

WHY THIS EXISTS (2026-09-12, rescued from a session scratchpad). The Pyrelisk
remake clads the body in hundreds of authored rocks, and the build-side guard
that is supposed to catch a rock left hanging - `PY_COMPONENTS` / `_py_knit`
in `assets/boss_gen.py` - is not an independent check of that geometry. It is
computed FROM the generator's own primitive list, in the generator's own
unposed frame, by the same code that placed the rocks. When the generator's
idea of where a rock is and the mesh's idea of where its surface is disagree,
the guard agrees with the generator and the player sees the mesh.

That disagreement is the whole reason this file exists. The first instruments
written for the Pyrelisk rocks measured VERTEX DISTANCE - nearest vertex of A
to nearest vertex of B - and reported a clean body. They were lying in both
directions at once: two rocks that INTERPENETRATE deeply can have every
vertex far from every other vertex (each one's vertices sit inside the other's
faces, not near them), so real, gross interpenetration read as "no contact";
and a big rock's sparse vertices sat far from a small rock resting on its
broad flat face, so real contact read as a gap. What settled it was measuring
SURFACE to surface - BVH nearest-polygon distance - on the POSED body:

  * POSED, because the rocks are authored in a part's local frame and the
    parts are then rotated and stacked onto each other by `PLACERS[boss]`.
    A join that closes in the rest frame can open in the posed one, and the
    posed one is what ships.
  * SURFACE, because a polygon is where the geometry actually is.
  * A CONTACT GRAPH rooted at the body's root object, because support
    launders through a chain: a rock touching a rock touching the Core is
    attached, and a cluster of forty rocks touching only each other is not.

`tools/check_floaters.py` is the sibling instrument and it CANNOT do this job.
It roots reachability at a landform/waterline found by island heuristics - it
looks for a wide, shallow ground mesh and the sea at z=0 - and a boss .glb has
neither. Point it at `assets/boss_pyrelisk.glb` and it finds no root, so every
component is a floater and the report is noise. This tool roots at a NAMED
OBJECT instead (`--root`), which is the only thing a free-standing creature
has to be attached to.

HONESTLY, WHAT THIS READS. By default it does NOT read the exported .glb. It
imports `assets/boss_gen.py` and builds the boss in-process - `B.BOSSES[boss]()`
- then poses it with `B.PLACERS[boss]`. So it shares the generator's geometry
authoring and tests a DIFFERENT question about it (posed surface contact) with
different code; it is independent of the guard, not of the generator. The
advantage is that it tests the WORKTREE generator, which during a live lane is
hours or days ahead of the committed .glb, and it can name the object a defect
came from. `--glb <path>` switches to importing the exported file instead and
posing THOSE objects through the same placer (the exporter writes the parts
stacked at the origin, unposed, under their generator names, which is exactly
what a placer expects) - use it to confirm that what shipped matches what the
generator currently builds. If a glb's object names have been mangled by the
exporter the placer will not find its parts and the run says so and stops.

POSITIVE CONTROL - and it is TWO probes, because one proves nothing. A green
run on a clean body looks identical to a checker that built no geometry, and a
checker with a fat tolerance reports a clean body too. `--control` finds the
outermost surface point on the chest and puts a 4-stud cube probe at +5.0
studs off it and another at +0.2 studs off it. The far one MUST come back
adrift; the near one MUST NOT. Both assertions are evaluated or the run prints
CONTROL FAILED - there is no path through this file that prints CONTROL OK
without them.

EXIT CODE. 0 when nothing is adrift from the root, 1 otherwise. In `--control`
mode the exit code is the CONTROL's verdict instead (0 = CONTROL OK), because
a control run injects a floater on purpose and would otherwise always exit 1.

WHAT IT DOES NOT KNOW - read this before believing a finding.

  * It is a test of ATTACHMENT, not of physics or of intent. A rock glued to
    the body by one touching face is attached even if it would fall off, and
    anything meant to float free (a detached shard, an orbiting ember) is
    correctly reported adrift by this tool's definition. There is no exempt
    list on purpose.
  * `--contact` is a real surface separation in studs, not bounding-box
    slack. Raising it to hide a finding widens the hole for every other rock.
  * It poses ONE frame (the rest frame the previews use). A join that opens
    only at the top of a slam swing is not tested here.
  * It cannot tell interpenetration from contact: both measure <= 0 and both
    count as attached. The seam quality question is a separate one.
"""

import math
import statistics
import sys
from pathlib import Path

import bpy
import bmesh
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

# ---- repo layout, derived from this file -------------------------------
REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "assets"))

# ---- arguments ---------------------------------------------------------
argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []


def _opt(flag, default=None):
    if flag in argv:
        i = argv.index(flag)
        if i + 1 < len(argv):
            return argv[i + 1]
    return default


BOSS = _opt("--boss", "pyrelisk")
ROOT_NAME = _opt("--root", "Pyrelisk_Core")
CONTACT = float(_opt("--contact", "0.3"))
CONTROL = "--control" in argv
GLB = _opt("--glb")
EXPORT = _opt("--export")

import boss_gen as B  # noqa: E402  (needs assets/ on sys.path first)

if BOSS not in B.BOSSES:
    print("unknown boss %r; known: %s" % (BOSS, ", ".join(sorted(B.BOSSES))))
    sys.exit(2)

# ---- build (or import) and pose ----------------------------------------
B.clear_scene()
if GLB:
    path = Path(GLB)
    if not path.is_absolute():
        path = REPO / path
    if not path.exists():
        print("no such glb: %s" % path)
        sys.exit(2)
    bpy.ops.import_scene.gltf(filepath=str(path))
    objects = [o for o in bpy.data.objects if o.type == "MESH"]
    print("IMPORTED %d meshes from %s" % (len(objects), path))
else:
    objects = B.BOSSES[BOSS]()
    print("BUILT %d parts from boss_gen.BOSSES[%r]" % (len(objects), BOSS))

for o in objects:
    o.hide_render = True

placer = B.PLACERS.get(BOSS)
try:
    if placer is None:
        made = B._place_chain(objects, B._swim_path)
    elif BOSS == "pyrelisk":
        # the rest frame render_py_previews' silhouette shot uses: both arms
        # hanging, head turned 16 degrees. That is what the party walks in on.
        made = placer(objects, head_yaw=math.radians(-16))
    else:
        made = placer(objects)
except KeyError as exc:
    print("POSING FAILED: the placer could not find part %s." % exc)
    if GLB:
        print("The imported .glb's object names do not match what "
              "PLACERS[%r] expects. Run without --glb." % BOSS)
    sys.exit(2)
made = [o for o in made if o.type == "MESH" and len(o.data.vertices)]
print("POSED %d parts" % len(made))
if not made:
    print("NOTHING POSED - aborting rather than reporting a clean body.")
    sys.exit(2)

# ---- positive control: two probes off the chest -------------------------
if CONTROL:
    bpy.context.view_layer.update()
    lo = Vector((9e9, 9e9, 9e9))
    hi = Vector((-9e9, -9e9, -9e9))
    for o in made:
        for corner in o.bound_box:
            p = o.matrix_world @ Vector(corner)
            lo = Vector((min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)))
            hi = Vector((max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)))
    # the chest band: 40-60% of the body's height, near the mid-plane in y
    zlo, zhi = lo.z + (hi.z - lo.z) * 0.40, lo.z + (hi.z - lo.z) * 0.60
    ymid, yspan = (lo.y + hi.y) * 0.5, (hi.y - lo.y)
    surf = None
    for o in made:
        mw = o.matrix_world
        for v in o.data.vertices:
            p = mw @ v.co
            if zlo < p.z < zhi and abs(p.y - ymid) < yspan * 0.12:
                if surf is None or p.x > surf.x:
                    surf = p.copy()
    if surf is None:
        print("[control] no chest surface found in the posed body")
        print("CONTROL FAILED")
        sys.exit(1)
    for tag, off in (("far", 5.0), ("near", 0.2)):
        ctr = Vector((surf.x + off + 2.0, surf.y, surf.z))  # 2.0 = probe half size
        pb = bmesh.new()
        bmesh.ops.create_cube(pb, size=4.0, matrix=Matrix.Translation(ctr))
        me = bpy.data.meshes.new("_probe_" + tag)
        pb.to_mesh(me)
        pb.free()
        ob = bpy.data.objects.new("Probe_" + tag, me)
        bpy.context.scene.collection.objects.link(ob)
        made.append(ob)
    print("[control] chest surface at x %.1f y %.1f z %.1f; probes at +5.0 and +0.2 studs"
          % (surf.x, surf.y, surf.z))

# ---- split every posed object into mesh components (world space) --------
comps = []
for obj in made:
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=1e-4)
    bm.verts.ensure_lookup_table()
    bm.faces.ensure_lookup_table()
    mw = obj.matrix_world
    seen = set()
    for v in bm.verts:
        if v.index in seen:
            continue
        stack = [v]
        seen.add(v.index)
        g = []
        while stack:
            c = stack.pop()
            g.append(c)
            for e in c.link_edges:
                o2 = e.other_vert(c)
                if o2.index not in seen:
                    seen.add(o2.index)
                    stack.append(o2)
        idx = {vv.index: k for k, vv in enumerate(g)}
        co = [mw @ vv.co for vv in g]
        faces = set()
        tris = []
        for vv in g:
            for f in vv.link_faces:
                if f.index in faces:
                    continue
                faces.add(f.index)
                loop = [idx[lv.index] for lv in f.verts]
                for k in range(1, len(loop) - 1):
                    tris.append((loop[0], loop[k], loop[k + 1]))
        lo = Vector((min(p.x for p in co), min(p.y for p in co), min(p.z for p in co)))
        hi = Vector((max(p.x for p in co), max(p.y for p in co), max(p.z for p in co)))
        comps.append({"obj": obj.name.split(".")[0], "co": co, "tris": tris,
                      "lo": lo, "hi": hi, "c": (lo + hi) * 0.5, "size": max(hi - lo)})
    bm.free()
print("COMPONENTS: %d" % len(comps))

# ---- candidate pairs: a bbox-grid prefilter, then real surface distance --
CELL = 24.0
grid = {}
for i, c in enumerate(comps):
    for gx in range(int(math.floor((c["lo"].x - CONTACT) / CELL)), int(math.floor((c["hi"].x + CONTACT) / CELL)) + 1):
        for gy in range(int(math.floor((c["lo"].y - CONTACT) / CELL)), int(math.floor((c["hi"].y + CONTACT) / CELL)) + 1):
            for gz in range(int(math.floor((c["lo"].z - CONTACT) / CELL)), int(math.floor((c["hi"].z + CONTACT) / CELL)) + 1):
                grid.setdefault((gx, gy, gz), []).append(i)
cands = set()
for cell in grid.values():
    for a in range(len(cell)):
        for b in range(a + 1, len(cell)):
            i, j = cell[a], cell[b]
            A, C = comps[i], comps[j]
            if (A["lo"].x - CONTACT > C["hi"].x or C["lo"].x - CONTACT > A["hi"].x or
                    A["lo"].y - CONTACT > C["hi"].y or C["lo"].y - CONTACT > A["hi"].y or
                    A["lo"].z - CONTACT > C["hi"].z or C["lo"].z - CONTACT > A["hi"].z):
                continue
            cands.add((min(i, j), max(i, j)))
print("CANDIDATE PAIRS: %d" % len(cands))

bvhs = {}


def bvh(i):
    if i not in bvhs:
        bvhs[i] = BVHTree.FromPolygons(comps[i]["co"], comps[i]["tris"], all_triangles=True)
    return bvhs[i]


def nearest(tree, pts):
    """Least distance from any of `pts` to a polygon of `tree` (9e9 if none near)."""
    best = 9e9
    for p in pts:
        hit = tree.find_nearest(p, 40.0)
        if hit[0] is not None and hit[3] < best:
            best = hit[3]
    return best


class DSU:
    def __init__(s, n):
        s.p = list(range(n))

    def find(s, a):
        while s.p[a] != a:
            s.p[a] = s.p[s.p[a]]
            a = s.p[a]
        return a

    def union(s, a, b):
        ra, rb = s.find(a), s.find(b)
        if ra != rb:
            s.p[ra] = rb


dsu = DSU(len(comps))
touch = 0
for i, j in cands:
    d = nearest(bvh(j), comps[i]["co"])
    if d > CONTACT:
        # points-of-A-to-surface-of-B misses the case where B is the sparse
        # mesh resting on A's broad face, so ask the question both ways.
        d = min(d, nearest(bvh(i), comps[j]["co"]))
    comps[i]["near"] = min(comps[i].get("near", 9e9), d)
    comps[j]["near"] = min(comps[j].get("near", 9e9), d)
    if d <= CONTACT:
        dsu.union(i, j)
        touch += 1
        comps[i]["deg"] = comps[i].get("deg", 0) + 1
        comps[j]["deg"] = comps[j].get("deg", 0) + 1
print("CONTACTS: %d of %d candidate pairs within %.2f studs" % (touch, len(cands), CONTACT))

# ---- reachability from the root object ---------------------------------
roots = {dsu.find(i) for i, c in enumerate(comps) if c["obj"] == ROOT_NAME}
if not roots:
    print("NO ROOT: no component belongs to an object named %r. Known objects: %s"
          % (ROOT_NAME, ", ".join(sorted({c["obj"] for c in comps}))))
    sys.exit(2)
free = [i for i, c in enumerate(comps) if dsu.find(i) not in roots]
groups = {}
for i in free:
    groups.setdefault(dsu.find(i), []).append(i)
print()
print("=== DISCONNECTED FROM %s: %d components in %d clusters (of %d total) ==="
      % (ROOT_NAME, len(free), len(groups), len(comps)))
by_obj = {}
for i in free:
    by_obj[comps[i]["obj"]] = by_obj.get(comps[i]["obj"], 0) + 1
for name, n in sorted(by_obj.items(), key=lambda kv: -kv[1]):
    total = sum(1 for c in comps if c["obj"] == name)
    print("  %-26s %4d of %4d components adrift" % (name, n, total))
print()
rows = sorted(groups.values(), key=lambda g: -max(comps[i]["size"] for i in g))
for g in rows[:40]:
    big = max(g, key=lambda i: comps[i]["size"])
    c = comps[big]
    print("  cluster of %2d: %-24s size %5.1f  at (x=%7.1f y=%7.1f z=%7.1f)"
          % (len(g), c["obj"], c["size"], c["c"].x, c["c"].y, c["c"].z))
if len(rows) > 40:
    print("  ... %d more clusters" % (len(rows) - 40))

control_ok = None
if CONTROL:
    adrift = {comps[i]["obj"] for i in free}
    far_adrift = "Probe_far" in adrift
    near_adrift = "Probe_near" in adrift
    print("[control] probe at +5.0 studs adrift: %s (expect True)" % far_adrift)
    print("[control] probe at +0.2 studs adrift: %s (expect False)" % near_adrift)
    control_ok = bool(far_adrift and not near_adrift)
    print("CONTROL OK" if control_ok else "CONTROL FAILED")

if rows:
    print()
    print("=== HOW BIG IS EACH GAP: nearest ATTACHED surface to each adrift cluster ===")
    attached = [i for i in range(len(comps)) if dsu.find(i) in roots]
    for g in rows[:24]:
        best = (9e9, None)
        for i in g:
            for j in attached:
                A, C = comps[i], comps[j]
                if (A["c"] - C["c"]).length > 60:
                    continue
                d = min(nearest(bvh(j), A["co"]), nearest(bvh(i), C["co"]))
                if d < best[0]:
                    best = (d, comps[j]["obj"])
        big = max(g, key=lambda i: comps[i]["size"])
        print("  cluster of %2d (%-20s size %5.1f) -> nearest attached surface %6.2f studs (%s)"
              % (len(g), comps[big]["obj"], comps[big]["size"], best[0], best[1]))

print()
print("=== SIZE AND CONTACT STATS (posed, per component) ===")
for name in sorted({c["obj"] for c in comps}):
    g = [c for c in comps if c["obj"] == name]
    sizes = sorted(c["size"] for c in g)
    degs = [c.get("deg", 0) for c in g]
    lone = sum(1 for d in degs if d == 0)
    weak = sum(1 for d in degs if d == 1)
    gaps = sorted(c.get("near", 9e9) for c in g if c.get("near", 9e9) < 50)
    print("  %-22s n=%4d size min/med/max %5.1f /%5.1f /%5.1f (spread %4.1fx)  deg med %d  "
          "zero-contact %3d  single-contact %3d  nearest-gap med %.2f p90 %.2f"
          % (name, len(g), sizes[0], statistics.median(sizes), sizes[-1],
             sizes[-1] / max(sizes[0], 0.01), int(statistics.median(degs)), lone, weak,
             statistics.median(gaps) if gaps else -1,
             gaps[int(len(gaps) * 0.9)] if gaps else -1))
body = sorted(c["size"] for c in comps if c["obj"] != ROOT_NAME)
if body:
    print("  ALL NON-ROOT: n=%d  p05 %.1f  median %.1f  p95 %.1f  max %.1f  (p95/p05 = %.1fx)"
          % (len(body), body[int(len(body) * .05)], statistics.median(body),
             body[int(len(body) * .95)], body[-1],
             body[int(len(body) * .95)] / max(body[int(len(body) * .05)], 0.01)))

if EXPORT:
    bpy.ops.object.select_all(action="DESELECT")
    bpy.ops.export_scene.gltf(filepath=EXPORT, export_format="GLB", use_selection=False)
    print("EXPORTED", EXPORT)

print()
if CONTROL:
    # the control injects a floater deliberately, so the adrift count cannot be
    # the verdict here - the control's own two assertions are.
    print("VERDICT: control %s" % ("OK" if control_ok else "FAILED"))
    sys.exit(0 if control_ok else 1)
print("VERDICT: %d components adrift from %s" % (len(free), ROOT_NAME))
sys.exit(0 if not free else 1)
