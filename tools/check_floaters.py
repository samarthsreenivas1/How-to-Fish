#!/usr/bin/env python3
"""Find geometry that hangs in mid-air in a generated island .glb.

    blender --background --python tools/check_floaters.py -- <island.glb> \
        [--radius R] [--contact 0.3] [--json out.json] [--control] [--per-empty] \
        [--no-underside] [--gap 1.0] [--min-support 0.25]

WHY THIS EXISTS (2026-09-09). The user's report is "random bits and pieces
all over the place" - props, branches, planks and lamps sitting disconnected
from whatever should hold them up. `island_gen.py` already has a float guard
(`validate_no_floaters`, ~line 7061) and it is wired into exactly two of the
sixteen islands, so most of the content has never been tested at all. That
guard also has two blind spots this tool exists to close:

  * It clusters primitives by PADDED BOUNDING BOX. Any floating piece whose
    box comes within 1.5 studs of a seated piece's box is ADOPTED by it and
    inherits its support - and a bounding box is a solid brick, so a lamp
    hanging in the empty middle of a doorway is "within 1.5 studs of" the
    door frame's box and passes. This tool tests real SURFACE proximity
    (BVH nearest-distance between polygons), so an empty gap is an empty gap.
  * It tolerates 1.5 studs of hover, and it only asks for support from the
    ground heightfield or the water. A crate resting on a deck that is
    itself floating is judged against the terrain far below and reported;
    a crate 1.4 studs above that deck is judged fine. This tool builds a
    CONTACT GRAPH between components and asks for reachability to a root -
    so support propagates through props, and the hover tolerance is 0.3
    studs of real surface separation, not 1.5 studs of box slack.

THE SECOND PASS: UNDERSIDE (on by default, --no-underside turns it off).
Reachability is a test of ATTACHMENT, and attachment launders along a chain.
Field results from sixteen islands, every one of them passing the contact
test: a bridge whose two ends rest on platforms and whose whole span hangs
over open water; six deck planks lying on the sea, each one touching its
neighbour; a leg sawn off in mid-air, still welded to a deck that has other
legs; a whale's backbone held up by one buried skull sixty studs away. Every
one of those is attached to something that reaches the ground, and every one
of them is a hole in the floor.

So the second pass ignores the graph entirely and asks a local question of
each component: grid its footprint, find its lowest surface in each cell,
look straight DOWN, and count the cell held if the first foreign geometry
below is within --gap. Below --min-support of its underside held, it is
reported as UNDERSIDE. THE WATERLINE IS NOT SUPPORT HERE - being above the
sea with nothing but sea beneath is the exact case reachability calls fine.
Hanging decor is held from above, so a cell also counts if the component's
top surface there has geometry within --gap overhead.

UNDERSIDE is a separate class and does NOT affect the floating/warn/stray
counts or the exit code. It is a much blunter instrument than the contact
graph and it is meant for triage, not for gating - see the limitations.

It is deliberately an INDEPENDENT instrument: it reads the exported .glb,
not the generator's in-memory scene, and shares no code with the guard it is
checking. Two implementations that agree are evidence; one implementation
run twice is not.

POSITIVE CONTROL - and it must be a case you expect to FAIL. `--control`
injects two defects into the imported scene and asserts the checker reports
them: a 2x2x2 cube hovering 6 studs over the landform's highest point (must
come back FLOATING) and a 0.5-stud sphere hovering 0.6 studs over the ground
(must come back at least WARN - it is the near-miss case, the one a
tolerance that is too generous would swallow). A green run on a clean island
proves nothing on its own: it looks exactly like a checker whose import
silently produced no geometry. So a control that cannot run - import failed,
no landform found, no injected object survived - prints CONTROL FAILED, and
there is no path through this file that prints CONTROL OK without both
assertions having actually been evaluated.

COORDINATES. The .glb is Y-up; Blender's importer converts to Z-up, and the
tool VERIFIES that (the landform must be wide in x/y and shallow in z) and
says so on stdout rather than assuming it. Everything is reported in Blender
world coords AND in the Roblox-relative frame the generator's HANDOFF lines
print, using the generator's own mapping:

    Roblox X = blender x     Roblox Y = blender z     Roblox Z = -blender y

The sea is at z = 0.

EXIT CODE. 1 if any FLOATING cluster was found, else 0. In `--control` mode
the exit code is the CONTROL's verdict instead (0 = CONTROL OK), because a
control run injects a floater on purpose and its exit status would otherwise
always be 1.

    blender --background --python tools/check_floaters.py -- /tmp/x.glb
    blender --background --python tools/check_floaters.py -- /tmp/x.glb --control
    blender --background --python tools/check_floaters.py -- assets/island_pack.glb \
        --per-empty --json /tmp/pack.json      # 16 islands, ~29s

WHAT IT DOES NOT KNOW - read this before believing a finding.

  * It has no idea what is DELIBERATE. Rookery's birds are in flight and
    Gloomtrench's glowfish circle in mid-air; both come back FLOATING, and
    correctly so by this tool's definition. There is no exempt list on
    purpose - the generator's guard has one, and an exempt list here would
    be a place to hide findings rather than fix them. Triage the report.
  * It is not a physics check. Support propagates sideways as readily as
    downward, so a shelf glued to a wall by one touching face is SUPPORTED
    even if it would topple. The question answered is "is this attached to
    anything that reaches the ground or the water", not "would it fall".
  * The default stray radius (the landform's horizontal extent x 1.15) is
    wrong for any island with intended offshore content: Wreckwater's sea
    fleet is scattered to 600 studs and produces 416 STRAY lines. Pass
    --radius for those, and read STRAY as "check this", never as a defect.
  * `--per-empty` is REQUIRED for island_pack.glb. The pack stacks every
    island at the origin under its own Empty, so a single run would build
    one contact graph out of sixteen interpenetrating islands and call
    almost everything supported.
  * The embedded (buried-in-something) test assumes the thing you are buried
    in is closed. An open single-sided shell whose normal points up can read
    as "inside" from below; the bbox containment guard limits the damage but
    does not eliminate it.
  * It tests the EXPORTED .glb, which is the artifact Studio imports - so it
    sees exactly what ships, but it cannot point at the line of island_gen.py
    that produced a floater. Take the coordinates back to the builder.

AND WHAT THE UNDERSIDE PASS IN PARTICULAR CANNOT SEE. It assumes a thing is
held up ACROSS ITS FOOTPRINT, and a great deal of correct geometry is not:

  * Anything held on a stem or cantilevered fails by construction - a cattail
    head on a stalk thinner than itself, a canopy on a trunk, a leaning palm,
    a sail, a hull heeled onto one bilge. Measured: the swamp reports 738,
    of which 430 are cattail heads and most of the rest is foliage; tropical
    reports 66, half of them dock planks and palm parts. The signal is real
    and so is the noise, which is why findings print biggest-first and capped.
  * Decor hung off the SIDE of something (Ferryraft's rope fenders, its
    lanterns) has support neither below it nor directly above it, so the
    up-ray does not rescue it and it reports.
  * A leg sawn off in mid-air but still welded to the deck ABOVE it is read
    as hanging decor by that same up-ray and does NOT report. That is a
    direct consequence of the rule that keeps lanterns quiet; the two cases
    are the same measurement with different intent.
  * --min-support is a shape threshold, not a physics one. A 6-stud deck on
    two 1-stud piers measures 0.33 and passes the 0.25 default; the same deck
    at 10 studs measures 0.20 and fails. Read the fraction, not the verdict.
"""

import json
import math
import os
import re
import sys
import time

import bmesh
import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree

# ---- tunables ------------------------------------------------------------

CONTACT = 0.3  # studs of surface separation still counted as "touching"
WARN_CONTACT = 1.0  # a contact between CONTACT and this is a near-miss
WATERLINE = 0.25  # a component reaching this low is held up by the sea
TINY_DIM = 0.4  # bbox max dimension below which a component is debris
SAMPLE_CAP = 400  # vertices sampled per component for contact queries
WELD = 1e-4  # merge-by-distance that undoes the exporter's vertex splitting
INDEX_CELL = 16.0  # bbox-hash cell for neighbour lookups in the refinement pass
RADIUS_SLACK = 1.15  # stray radius = landform horizontal extent * this
DIAG_CAP = 40  # clusters given the exact nearest-foreign-surface diagnostic
UNDER_GAP = 1.0  # geometry this close under a cell counts as holding it up
UNDER_MIN_SUPPORT = 0.25  # report a component with less of its underside held
UNDER_CELL = 0.5  # smallest underside sampling cell, studs
UNDER_SAMPLES = 200  # cap on cells per component
UNDER_PRINT = 25  # underside findings printed (biggest first); --json has all
UP = Vector((0.0, 0.0, 1.0))


def rbx(p):
    """Blender world (x, y, z) -> the Roblox-relative triple HANDOFF uses."""
    return (p[0], p[2], -p[1])


def fmt(p):
    return (
        f"(x={p[0]:8.2f} y={p[1]:8.2f} z={p[2]:7.2f})"
        f"  Roblox(X={p[0]:8.2f} Y={p[2]:7.2f} Z={-p[1]:8.2f})"
    )


def is_landform(name):
    """True for the base landform objects: <Island>_Base, and Base2/Base3.

    The name may carry the importer's `.001` disambiguator, so strip that
    first. Nothing else in the generator is named `*_Base<digits>`."""
    stem = re.sub(r"\.\d+$", "", name)
    return re.search(r"_Base\d*$", stem) is not None


# ---- union-find ----------------------------------------------------------


class DSU:
    def __init__(self, n):
        self.p = list(range(n))

    def find(self, a):
        p = self.p
        while p[a] != a:
            p[a] = p[p[a]]
            a = p[a]
        return a

    def union(self, a, b):
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            self.p[rb] = ra
            return True
        return False


# ---- geometry ------------------------------------------------------------


class Scene:
    """World-space triangle soup plus its true connected components.

    Components are TOPOLOGICAL: union-find over shared edges (two faces that
    share only a vertex are still joined, because that vertex is in both
    faces' edge sets).

    BUT FIRST THE MESH IS WELDED BY POSITION, and that is not optional. A
    .glb stores per-face vertices wherever the shading is flat, so the
    exporter has already torn every sharp edge apart: measured on
    island_tropical.glb, raw index topology reports 7025 "components" for
    14004 triangles - every single quad of a palm trunk its own island.
    Union-find over that answers a question about the exporter, not about the
    island. `remove_doubles` at 1e-4 studs restores the authored connectivity
    (the same file drops to a few hundred real components), and only then
    does "is this piece attached to anything?" mean what it says."""

    def __init__(self, objects):
        self.verts = []  # world-space Vectors, global index
        self.polys = []  # triangles as (i, j, k) into self.verts
        self.poly_comp = []  # component id per triangle
        self.comps = []  # per-component dicts

        for obj in objects:
            if obj.type != "MESH" or obj.data is None or not len(obj.data.vertices):
                continue
            bm = bmesh.new()
            bm.from_mesh(obj.data)
            bm.transform(obj.matrix_world)
            bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=WELD)
            bm.verts.ensure_lookup_table()
            bm.verts.index_update()

            dsu = DSU(len(bm.verts))
            for e in bm.edges:
                dsu.union(e.verts[0].index, e.verts[1].index)

            base = len(self.verts)
            local_comp = {}  # dsu root -> global component id
            vcomp = [0] * len(bm.verts)
            for v in bm.verts:
                root = dsu.find(v.index)
                cid = local_comp.get(root)
                if cid is None:
                    cid = len(self.comps)
                    local_comp[root] = cid
                    self.comps.append(
                        {
                            "id": cid,
                            "object": obj.name,
                            "verts": [],
                            "edges": [],
                            "lo": [1e30, 1e30, 1e30],
                            "hi": [-1e30, -1e30, -1e30],
                        }
                    )
                vcomp[v.index] = cid
                c = self.comps[cid]
                co = v.co.copy()
                gi = base + v.index
                c["verts"].append(gi)
                for k in range(3):
                    if co[k] < c["lo"][k]:
                        c["lo"][k] = co[k]
                    if co[k] > c["hi"][k]:
                        c["hi"][k] = co[k]
                self.verts.append(co)

            # Edges, kept for the refinement pass (see `refine`).
            for e in bm.edges:
                a, b = e.verts[0].index, e.verts[1].index
                self.comps[vcomp[a]]["edges"].append((base + a, base + b))

            # Triangulate for the BVH. This only adds edges INSIDE existing
            # faces, so it cannot change the components computed above.
            bmesh.ops.triangulate(bm, faces=bm.faces[:])
            bm.faces.ensure_lookup_table()
            for f in bm.faces:
                idx = [base + lv.index for lv in f.verts]
                self.polys.append(tuple(idx[:3]))
                self.poly_comp.append(vcomp[f.verts[0].index])
            bm.free()

        for c in self.comps:
            c["size"] = [c["hi"][k] - c["lo"][k] for k in range(3)]
            c["centroid"] = [(c["lo"][k] + c["hi"][k]) / 2.0 for k in range(3)]
            c["nverts"] = len(c["verts"])
            c["tiny"] = max(c["size"]) < TINY_DIM

        self.bvh = (
            BVHTree.FromPolygons(self.verts, self.polys, all_triangles=True, epsilon=0.0)
            if self.polys
            else None
        )

    # -- sampling ----------------------------------------------------------

    def samples(self, comp):
        """Up to SAMPLE_CAP vertices spread evenly through the component,
        plus its six bbox-extreme vertices (the ones most likely to be the
        actual contact point - a prop touches its support at its bottom)."""
        vs = comp["verts"]
        n = len(vs)
        if n <= SAMPLE_CAP:
            picked = list(vs)
        else:
            stride = max(1, math.ceil(n / SAMPLE_CAP))
            picked = vs[::stride]
        extreme = {}
        for gi in vs:
            co = self.verts[gi]
            for k in range(3):
                lo = extreme.get(("lo", k))
                if lo is None or co[k] < self.verts[lo][k]:
                    extreme[("lo", k)] = gi
                hi = extreme.get(("hi", k))
                if hi is None or co[k] > self.verts[hi][k]:
                    extreme[("hi", k)] = gi
        return set(picked) | set(extreme.values())

    # -- contact graph -----------------------------------------------------

    def contact_edges(self, reach):
        """{(a, b): min surface distance} for every pair of DIFFERENT
        components within `reach` studs of one another.

        One pass at the widest radius we care about, tagging each edge with
        its distance, so the strict graph and the near-miss graph are both
        subsets of this result - the spec's "second pass at 1.0" without
        paying for the query twice.

        SURFACE DISTANCE ALONE IS NOT ENOUGH, and the first version of this
        file got it wrong. Nearest-vertex-to-polygon distance cannot see
        INTERPENETRATION: `build_palm` seats every trunk at
        `height_at(px, pz) - 0.6`, i.e. 0.6 studs INTO the terrain, and the
        trunk's own vertices are then rings 5 studs apart down inside the
        rock - none of them within 0.3 studs of the terrain's surface. Every
        palm on the island came back as a near-miss. So each sample also gets
        an EMBEDDED test: march a ray up from the vertex, skip our own
        polygons, and if the first foreign polygon we meet is a BACK face
        (its normal points the same way we are travelling) then we started
        underneath that surface - buried in it, which is the firmest support
        there is. It is guarded by a bbox containment check so an infinite
        flat plane overhead (a water quad) cannot swallow the island."""
        edges = {}
        if self.bvh is None:
            return edges
        up = Vector((0.0, 0.0, 1.0))
        for comp in self.comps:
            cid = comp["id"]
            for gi in self.samples(comp):
                pt = self.verts[gi]
                for _loc, _nrm, pidx, dist in self.bvh.find_nearest_range(pt, reach):
                    other = self.poly_comp[pidx]
                    if other == cid:
                        continue
                    key = (cid, other) if cid < other else (other, cid)
                    prev = edges.get(key)
                    if prev is None or dist < prev:
                        edges[key] = dist
                other = self.embedded_in(pt, cid, up)
                if other is not None:
                    key = (cid, other) if cid < other else (other, cid)
                    edges[key] = 0.0
        return edges

    def refine(self, edges, suspects, reach):
        """Re-test only the components that came back unsupported, sampling
        ALONG THEIR EDGES instead of only at their vertices.

        This exists because of `_wr_beam`, which builds a yard, a rib or a
        deck plank as a SCALED CUBE: a 30-stud crossyard has eight vertices,
        all of them at its two ends, and it is stepped through the middle of
        a mast that likewise has no vertex there. The two prisms genuinely
        intersect and no vertex of either is anywhere near the other, so
        vertex sampling calls the whole rig a floater - it reported every
        lone mast in Wreckwater's sea fleet. Walking the edges puts sample
        points inside the mast, where the embedded test can see them.

        The walk is SYMMETRIC: for each suspect we also walk the edges of the
        thin neighbours around it. Walking only the suspect is not enough
        when the thin piece is the OTHER one - a 1.8-stud spar stepped
        through the middle of a 2.6-stud masthead block keeps every edge of
        the block a hair over a stud from the spar's surface, so the block
        looks isolated from its own side and joined from the spar's. Only
        neighbours with few edges are walked (a spar, a yard, a plank);
        anything with a big edge budget is the landform or a hull, and a
        suspect buried in one of those is already caught by its own samples.

        It is deliberately a SECOND pass over the suspects only. Edge-walking
        every component of the swamp would be millions of queries for an
        answer the cheap pass already had; the suspects are a few dozen."""
        for cid in suspects:
            walk = [cid] + [n for n in self.neighbours(cid) if len(self.comps[n]["edges"]) <= 2000]
            for src in walk:
                self.walk_edges(edges, self.comps[src], cid, reach)

    def walk_edges(self, edges, comp, cid, reach):
        """Sample along `comp`'s edges, recording contacts against `cid`."""
        up = Vector((0.0, 0.0, 1.0))
        step = max(CONTACT, 0.25)
        src = comp["id"]
        budget = 6000
        for ga, gb in comp["edges"]:
            if budget <= 0:
                return
            a, b = self.verts[ga], self.verts[gb]
            n = min(64, int((b - a).length / step))
            if n < 2:
                continue
            for k in range(1, n):
                budget -= 1
                pt = a.lerp(b, k / n)
                for _loc, _nrm, pidx, dist in self.bvh.find_nearest_range(pt, reach):
                    other = self.poly_comp[pidx]
                    if other == src:
                        continue
                    key = (src, other) if src < other else (other, src)
                    prev = edges.get(key)
                    if prev is None or dist < prev:
                        edges[key] = dist
                other = self.embedded_in(pt, src, up)
                if other is not None:
                    key = (src, other) if src < other else (other, src)
                    edges[key] = 0.0

    def nearest_foreign(self, ids):
        """Exact distance from this cluster's surface to the nearest surface
        that is not part of it, and the object that surface belongs to.

        Done by rebuilding a BVH WITHOUT the cluster's own polygons, so
        `find_nearest` cannot answer with the cluster itself. There is no
        search radius to get wrong."""
        keep = [p for i, p in enumerate(self.polys) if self.poly_comp[i] not in ids]
        if not keep:
            return None, None
        keep_comp = [c for c in self.poly_comp if c not in ids]
        tree = BVHTree.FromPolygons(self.verts, keep, all_triangles=True, epsilon=0.0)
        best, obj = None, None
        pts = []
        for cid in ids:
            pts.extend(self.samples(self.comps[cid]))
        for gi in pts[:600]:
            loc, _nrm, pidx, dist = tree.find_nearest(self.verts[gi])
            if loc is None or dist is None:
                continue
            if best is None or dist < best:
                best, obj = dist, self.comps[keep_comp[pidx]]["object"]
        return best, obj

    def build_index(self):
        """Coarse bbox hash of components, for neighbour lookups. A component
        spanning absurdly many cells (the landform) goes in `self.big`."""
        self.cells = {}
        self.big = []
        for c in self.comps:
            span = [
                range(int(math.floor(c["lo"][k] / INDEX_CELL)), int(math.floor(c["hi"][k] / INDEX_CELL)) + 1)
                for k in range(3)
            ]
            if len(span[0]) * len(span[1]) * len(span[2]) > 400:
                self.big.append(c["id"])
                continue
            for i in span[0]:
                for j in span[1]:
                    for k in span[2]:
                        self.cells.setdefault((i, j, k), []).append(c["id"])

    def neighbours(self, cid):
        """Components whose bbox comes within WARN_CONTACT of `cid`'s."""
        c = self.comps[cid]
        lo = [c["lo"][k] - WARN_CONTACT for k in range(3)]
        hi = [c["hi"][k] + WARN_CONTACT for k in range(3)]
        found = set()
        for i in range(int(math.floor(lo[0] / INDEX_CELL)), int(math.floor(hi[0] / INDEX_CELL)) + 1):
            for j in range(int(math.floor(lo[1] / INDEX_CELL)), int(math.floor(hi[1] / INDEX_CELL)) + 1):
                for k in range(int(math.floor(lo[2] / INDEX_CELL)), int(math.floor(hi[2] / INDEX_CELL)) + 1):
                    found.update(self.cells.get((i, j, k), ()))
        found.update(self.big)
        out = []
        for n in found:
            if n == cid:
                continue
            o = self.comps[n]
            if all(lo[k] <= o["hi"][k] and o["lo"][k] <= hi[k] for k in range(3)):
                out.append(n)
        return out

    def embedded_in(self, pt, cid, up):
        """The component `pt` is buried inside, or None."""
        p = Vector(pt) + Vector((0.0, 0.0, WELD))
        for _ in range(8):
            hit = self.bvh.ray_cast(p, up)
            if hit[0] is None:
                return None
            loc, nrm, pidx, _dist = hit
            other = self.poly_comp[pidx]
            if other != cid:
                if nrm.z <= 1e-6:
                    return None  # a front face: something is above us, not around us
                c = self.comps[other]
                inside = all(
                    c["lo"][k] - CONTACT <= pt[k] <= c["hi"][k] + CONTACT for k in range(3)
                )
                return other if inside else None
            p = Vector((loc.x, loc.y, loc.z + WELD))
        return None

    # -- rays --------------------------------------------------------------

    def ray_gap(self, origin, own, dz):
        """(gap, hit location, component hit, inside) straight up or down
        from `origin`, ignoring polygons belonging to components in `own`.

        `inside` means the first foreign face we met was a BACK face - we
        were travelling down and hit a downward-pointing surface - which for
        a closed solid means we started INSIDE it. That distinction is
        load-bearing: a plank whose post penetrates it has its underside
        inside the post, and the first surface below that underside is the
        post's own bottom face six studs down. Read naively, the best-seated
        joint in the island measures as the emptiest."""
        if self.bvh is None:
            return None, None, None, False
        d = Vector((0.0, 0.0, 1.0 if dz > 0 else -1.0))
        p = Vector(origin)
        for _ in range(200):
            hit = self.bvh.ray_cast(p, d)
            if hit[0] is None:
                return None, None, None, False
            loc, nrm, pidx, _dist = hit
            if self.poly_comp[pidx] not in own:
                inside = (nrm.z < -1e-6) if dz < 0 else (nrm.z > 1e-6)
                return (
                    abs(loc.z - origin[2]),
                    [loc.x, loc.y, loc.z],
                    self.poly_comp[pidx],
                    inside,
                )
            p = Vector((loc.x, loc.y, loc.z + (1e-3 if dz > 0 else -1e-3)))
        return None, None, None, False

    def gap_below(self, origin, own):
        g, loc, c, _inside = self.ray_gap(origin, own, -1.0)
        return g, loc, c

    def own_surface(self, x, y, cid, z_from, dz, span):
        """Where does component `cid` actually present a surface in this
        column? Ray from outside the component toward it and keep the first
        hit that belongs to it.

        THE COMPONENT'S VERTICES ARE NOT ENOUGH, and this is the whole reason
        the underside test is ray-based. `_wr_beam` and every deck plank in
        the generator is a SCALED CUBE: eight vertices, all at the corners.
        Sampling "the component's own min-z vertex per cell" on a 6x6 slab
        finds four corner samples, all four of them over the piers holding
        the ends up, and pronounces the bridge fully supported - the exact
        defect it was written to catch. Marching a ray up the column finds
        the underside of the span itself, corners or no corners."""
        p = Vector((x, y, z_from))
        d = Vector((0.0, 0.0, 1.0 if dz > 0 else -1.0))
        for _ in range(24):
            hit = self.bvh.ray_cast(p, d, span)
            if hit[0] is None:
                return None
            loc, _nrm, pidx, _dist = hit
            if self.poly_comp[pidx] == cid:
                return loc
            span -= abs(loc.z - p.z) + 1e-3
            if span <= 0:
                return None
            p = Vector((loc.x, loc.y, loc.z + (1e-3 if dz > 0 else -1e-3)))
        return None

    def underside(self, comp, gap, min_support):
        """Is there anything UNDER this component, or is it spanning air?

        The contact graph cannot answer this, which is why this pass exists.
        Contact tests ATTACHMENT, and attachment launders along a chain: a
        bridge whose two ends rest on piers is attached to the ground however
        far its middle sags over open water; six deck planks lying on the sea
        are each attached to their neighbour; a leg sawn off in mid-air is
        welded to a deck that has other legs; a whale's backbone is held up
        by one buried skull sixty studs away. Every one of those passes a
        reachability test and every one of them is a hole in the floor.

        So: grid the component's XY footprint, find its lowest surface in
        each cell, and look straight down. A cell is supported if the first
        foreign geometry below is within `gap`. Hanging decor - a lantern
        under a beam, a vine, a chain - is held from ABOVE, so a cell also
        counts as supported if the component's top surface there has foreign
        geometry within `gap` overhead.

        THE WATERLINE IS NOT SUPPORT HERE. That is the point of the pass:
        being above the sea with nothing but sea underneath is precisely the
        case the root-reachability test calls fine."""
        lo, hi = comp["lo"], comp["hi"]
        cid = comp["id"]
        area = max(1e-6, (hi[0] - lo[0]) * (hi[1] - lo[1]))
        cell = max(UNDER_CELL, math.sqrt(area / UNDER_SAMPLES))
        nx = max(1, int(math.ceil((hi[0] - lo[0]) / cell)))
        ny = max(1, int(math.ceil((hi[1] - lo[1]) / cell)))
        span_z = (hi[2] - lo[2]) + 2.0
        own = {cid}

        cells = []
        for i in range(nx):
            for j in range(ny):
                cells.append((lo[0] + (i + 0.5) * cell, lo[1] + (j + 0.5) * cell))

        total = 0
        supported = 0
        min_gap = None
        # Once the supported fraction can no longer fall below the threshold
        # the component is not a finding, so stop paying for it. Sound: the
        # fraction only rises as more supported cells are counted.
        for (x, y) in cells:
            under = self.own_surface(x, y, cid, lo[2] - 1.0, +1.0, span_z)
            if under is None:
                continue  # the footprint is not solid here
            total += 1
            # BURIED FIRST, and the question has to be asked AT the sample
            # point, not inferred from what the downward ray meets. A pier
            # standing in the ground is itself penetrated by the terrain, so
            # the first foreign surface below a deck resting on that pier is
            # the terrain poking through it, several studs down and facing
            # up - indistinguishable from open air. That read the same deck
            # as 0.33 supported on flat tropical ground, 0.16 on Wreckwater
            # and 0.00 on the swamp, from geometry identical to the stud.
            g = None
            ok = self.embedded_in((x, y, under.z), cid, UP) is not None
            if not ok:
                g, _loc, _c, _inside = self.ray_gap((x, y, under.z), own, -1.0)
                ok = g is not None and g <= gap
            if not ok:
                top = self.own_surface(x, y, cid, hi[2] + 1.0, -1.0, span_z)
                if top is not None:
                    ok = self.embedded_in((x, y, top.z), cid, UP) is not None
                    if not ok:
                        gu, _l, _c, _i = self.ray_gap((x, y, top.z), own, +1.0)
                        ok = gu is not None and gu <= gap
            if not ok and g is not None and (min_gap is None or g < min_gap):
                min_gap = g  # the drop under the part that is NOT held
            if ok:
                supported += 1
                if supported >= min_support * len(cells):
                    return None
        if total == 0 or supported >= min_support * total:
            return None
        return {
            "object": comp["object"],
            "fraction": supported / total,
            "cells": total,
            "supported_cells": supported,
            "min_gap": min_gap,
            "centroid": list(comp["centroid"]),
            "centroid_roblox": list(rbx(comp["centroid"])),
            "bbox_size": list(comp["size"]),
            "volume": comp["size"][0] * comp["size"][1] * comp["size"][2],
            "lowest_z": lo[2],
        }


def supported_set(comps, edges, roots, threshold):
    """Components reachable from a root through contacts <= threshold."""
    dsu = DSU(len(comps))
    for (a, b), d in edges.items():
        if d <= threshold:
            dsu.union(a, b)
    root_groups = {dsu.find(r) for r in roots}
    return {c["id"] for c in comps if dsu.find(c["id"]) in root_groups}, dsu


# ---- the analysis --------------------------------------------------------


def analyse(objects, contact, radius_arg, label, underside=True,
            under_gap=UNDER_GAP, min_support=UNDER_MIN_SUPPORT):
    t0 = time.time()
    scene = Scene(objects)
    t_build = time.time() - t0
    report = {
        "label": label,
        "objects": len({c["object"] for c in scene.comps}),
        "components": len(scene.comps),
        "triangles": len(scene.polys),
        "contact": contact,
        "warn_contact": WARN_CONTACT,
        "floating": [],
        "warn": [],
        "stray": [],
        "underside": [],
        "tiny": {},
        "axis": None,
        "radius": None,
    }
    if not scene.comps:
        report["error"] = "no mesh geometry"
        return scene, report

    # -- up-axis verification: the landform must be wide and shallow -------
    land = [c for c in scene.comps if is_landform(c["object"])]
    if land:
        lo = [min(c["lo"][k] for c in land) for k in range(3)]
        hi = [max(c["hi"][k] for c in land) for k in range(3)]
        dx, dy, dz = (hi[k] - lo[k] for k in range(3))
        ok = dz < dx and dz < dy
        report["axis"] = {
            "landform_objects": sorted({c["object"] for c in land}),
            "extent": [dx, dy, dz],
            "z_up": bool(ok),
        }
        print(
            f"[axis] landform {sorted({c['object'] for c in land})} extent "
            f"x={dx:.1f} y={dy:.1f} z={dz:.1f} -> "
            + ("up axis is Z (glTF Y-up converted on import, as expected)" if ok else
               "!! NOT Z-up: the shallow axis is not z. Reporting is suspect.")
        )
        horiz = max(abs(lo[0]), abs(hi[0]), abs(lo[1]), abs(hi[1]))
    else:
        print("[axis] NO LANDFORM (*_Base) object found - cannot verify the up axis.")
        horiz = max(
            max(abs(c["lo"][0]), abs(c["hi"][0]), abs(c["lo"][1]), abs(c["hi"][1]))
            for c in scene.comps
        )
    radius = radius_arg if radius_arg is not None else horiz * RADIUS_SLACK
    report["radius"] = radius

    # -- contact graph -----------------------------------------------------
    t1 = time.time()
    reach = max(contact, WARN_CONTACT)
    edges = scene.contact_edges(reach)
    t_contact = time.time() - t1
    report["contact_edges"] = len(edges)

    roots = [
        c["id"]
        for c in scene.comps
        if is_landform(c["object"]) or c["lo"][2] <= WATERLINE
    ]
    report["roots"] = len(roots)
    strict, _dsu = supported_set(scene.comps, edges, roots, contact)

    # Second pass over the suspects only, walking their edges. One round is
    # enough: anything still unsupported afterwards has already been walked,
    # and support propagates through the graph when it is recomputed.
    suspects = [c["id"] for c in scene.comps if c["id"] not in strict]
    t2 = time.time()
    scene.build_index()
    scene.refine(edges, suspects, reach)
    report["refined"] = len(suspects)
    report["contact_edges"] = len(edges)
    t_refine = time.time() - t2

    strict, dsu_strict = supported_set(scene.comps, edges, roots, contact)
    loose, _ = supported_set(scene.comps, edges, roots, WARN_CONTACT)

    # -- clusters of unsupported components --------------------------------
    groups = {}
    for c in scene.comps:
        if c["id"] in strict:
            continue
        groups.setdefault(dsu_strict.find(c["id"]), []).append(c)

    for members in groups.values():
        ids = {c["id"] for c in members}
        lo = [min(c["lo"][k] for c in members) for k in range(3)]
        hi = [max(c["hi"][k] for c in members) for k in range(3)]
        centroid = [
            sum(c["centroid"][k] * c["nverts"] for c in members)
            / sum(c["nverts"] for c in members)
            for k in range(3)
        ]
        bottom = [(lo[0] + hi[0]) / 2.0, (lo[1] + hi[1]) / 2.0, lo[2]]
        gap, hit, hit_comp = scene.gap_below(bottom, ids)
        if gap is None:
            gap = lo[2]  # nothing below at all: measure to the sea at z = 0
            below = "sea(z=0)"
        else:
            below = scene.comps[hit_comp]["object"]
        near = min(
            (d for (a, b), d in edges.items() if (a in ids) != (b in ids)),
            default=None,
        )
        # How far is the nearest FOREIGN SURFACE, at any distance? This is
        # the number that separates "the tolerance is too tight" from "there
        # is a hole here", and it is why bbox proximity must not be trusted:
        # these clusters have bounding boxes that OVERLAP their neighbours
        # (which is what makes the generator's padded-bbox guard adopt them)
        # while no actual surface comes anywhere near. Exact, not sampled
        # against a radius: a BVH built with this cluster's polygons removed.
        item = {
            "objects": sorted({c["object"] for c in members}),
            "pieces": len(members),
            "centroid": centroid,
            "centroid_roblox": list(rbx(centroid)),
            "bbox_size": [hi[k] - lo[k] for k in range(3)],
            "lowest_z": lo[2],
            "gap": gap,
            "below": below,
            "below_at": hit,
            "nearest_other_component": near,
            "nearest_any_gap": None,
            "nearest_any_object": None,
            "_ids": ids,
            "tiny": all(c["tiny"] for c in members),
            "verts": sum(c["nverts"] for c in members),
        }
        if ids & loose:
            report["warn"].append(item)
        else:
            report["floating"].append(item)

    report["floating"].sort(key=lambda i: -i["gap"])
    report["warn"].sort(key=lambda i: -i["gap"])

    # The exact nearest-foreign-surface measurement, for the worst clusters
    # only - it rebuilds a BVH per cluster, so it is capped. Deliberately
    # AFTER the sort: the clusters a reader looks at first are the ones that
    # must carry the number, and doing it in discovery order gave it to
    # whichever happened to be found first.
    for item in report["floating"][:DIAG_CAP] + report["warn"][:DIAG_CAP]:
        item["nearest_any_gap"], item["nearest_any_object"] = scene.nearest_foreign(item["_ids"])
    for item in report["floating"] + report["warn"]:
        item.pop("_ids", None)

    # -- strays ------------------------------------------------------------
    for c in scene.comps:
        d = math.hypot(c["centroid"][0], c["centroid"][1])
        if d > radius:
            report["stray"].append(
                {
                    "object": c["object"],
                    "distance": d,
                    "centroid": c["centroid"],
                    "centroid_roblox": list(rbx(c["centroid"])),
                    "bbox_size": c["size"],
                    "supported": c["id"] in strict,
                }
            )
    report["stray"].sort(key=lambda i: -i["distance"])

    # -- tiny fragments ----------------------------------------------------
    for c in scene.comps:
        if c["tiny"]:
            report["tiny"][c["object"]] = report["tiny"].get(c["object"], 0) + 1

    # -- underside ---------------------------------------------------------
    t3 = time.time()
    if underside:
        for c in scene.comps:
            if c["tiny"] or c["lo"][2] <= WATERLINE or is_landform(c["object"]):
                continue
            item = scene.underside(c, under_gap, min_support)
            if item is not None:
                report["underside"].append(item)
        report["underside"].sort(key=lambda i: -i["volume"])
    t_under = time.time() - t3

    report["timing"] = {
        "under_s": t_under,
        "build_s": t_build,
        "contact_s": t_contact,
        "refine_s": t_refine,
        "total_s": time.time() - t0,
    }
    return scene, report


# ---- printing ------------------------------------------------------------


def emit(report):
    lab = report["label"]
    if report.get("error"):
        print(f"[{lab}] ERROR: {report['error']}")
        return
    print(
        f"[{lab}] {report['components']} components / {report['objects']} objects / "
        f"{report['triangles']} tris; {report['contact_edges']} contact pairs; "
        f"{report['roots']} root components; stray radius {report['radius']:.1f}"
    )
    for item in report["floating"]:
        print(
            f"  FLOATING gap {item['gap']:8.2f} over {item['below']:<24s}"
            f" bottom z={item['lowest_z']:7.2f} {fmt(item['centroid'])}"
            f" size {item['bbox_size'][0]:.1f}x{item['bbox_size'][1]:.1f}x{item['bbox_size'][2]:.1f}"
            f" nearest-surface {item['nearest_any_gap']:.2f} ({item['nearest_any_object']})"
            if item["nearest_any_gap"] is not None
            else " nearest-surface n/a"
            f" {item['pieces']} piece(s){' TINY' if item['tiny'] else ''}"
            f"  {', '.join(item['objects'])}"
        )
    for item in report["warn"]:
        n = item["nearest_other_component"]
        print(
            f"  WARN     gap {item['gap']:8.2f} nearest contact "
            f"{('%.2f' % n) if n is not None else '   n/a'} studs"
            f" {fmt(item['centroid'])} {item['pieces']} piece(s)"
            f"  {', '.join(item['objects'])}"
        )
    for item in report["stray"][:20]:
        print(
            f"  STRAY    {item['distance']:8.1f} studs out {fmt(item['centroid'])}"
            f"  {item['object']}{'' if item['supported'] else '  (also unsupported)'}"
        )
    if len(report["stray"]) > 20:
        print(f"  STRAY    ... and {len(report['stray']) - 20} more")
    # Printed longest-first and capped, the way STRAY is: the full list is in
    # --json and the count is in the summary, so nothing is hidden - but a
    # vegetated island produces hundreds of these (the swamp: 738, of which
    # 430 are cattail heads sitting on stalks thinner than they are) and a
    # report nobody can read is a report nobody reads.
    for item in report["underside"][:UNDER_PRINT]:
        mg = item["min_gap"]
        print(
            f"  UNDERSIDE {item['fraction'] * 100:5.1f}% of its underside held"
            f" ({item['supported_cells']}/{item['cells']} cells), drop under the unheld part"
            f" {('%.2f' % mg) if mg is not None else '  none'} studs"
            f" {fmt(item['centroid'])}"
            f" size {item['bbox_size'][0]:.1f}x{item['bbox_size'][1]:.1f}x{item['bbox_size'][2]:.1f}"
            f"  {item['object']}"
        )
    if len(report["underside"]) > UNDER_PRINT:
        print(
            f"  UNDERSIDE ... and {len(report['underside']) - UNDER_PRINT} more,"
            f" smaller (full list in --json)"
        )
    if report["underside"]:
        tally = {}
        for item in report["underside"]:
            tally[item["object"]] = tally.get(item["object"], 0) + 1
        by = ", ".join(f"{k} {v}" for k, v in sorted(tally.items(), key=lambda kv: -kv[1]))
        print(f"  INFO     underside findings by object: {by}")
    for name, n in sorted(report["tiny"].items(), key=lambda kv: -kv[1]):
        print(f"  INFO     {n} tiny fragment(s) (<{TINY_DIM} studs) in {name}")
    t = report.get("timing", {})
    print(
        f"[{lab}] {t.get('total_s', 0):.1f}s (geometry {t.get('build_s', 0):.1f}s, "
        f"contact graph {t.get('contact_s', 0):.1f}s, "
        f"underside {t.get('under_s', 0):.1f}s, "
        f"edge refinement of {report.get('refined', 0)} suspects {t.get('refine_s', 0):.1f}s)"
    )


def summary_line(reports):
    f = sum(len(r["floating"]) for r in reports)
    w = sum(len(r["warn"]) for r in reports)
    s = sum(len(r["stray"]) for r in reports)
    j = sum(sum(r["tiny"].values()) for r in reports)
    o = sum(r.get("objects", 0) for r in reports)
    c = sum(r.get("components", 0) for r in reports)
    u = sum(len(r["underside"]) for r in reports)
    return (
        f"FLOATERS: {f} floating, {w} warn, {s} stray, tiny={j} "
        f"across {o} objects/{c} components; UNDERSIDE: {u}"
    )


# ---- scene loading -------------------------------------------------------


def load(path):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=path)
    return [o for o in bpy.context.scene.objects if o.type == "MESH"]


def top_empty(obj):
    """The outermost non-mesh ancestor - the pack's per-island Empty."""
    cur, last = obj, None
    while cur.parent is not None:
        cur = cur.parent
        if cur.type == "EMPTY":
            last = cur
    return last


def group_by_empty(meshes):
    groups = {}
    for o in meshes:
        e = top_empty(o)
        groups.setdefault(e.name if e else "(no empty)", []).append(o)
    # A single wrapper Empty around everything is the importer's root, not an
    # island; splitting on it is the same as not splitting.
    return groups


# ---- the positive control ------------------------------------------------


def run_control(meshes, contact, radius_arg, underside=True,
                under_gap=UNDER_GAP, min_support=UNDER_MIN_SUPPORT):
    """Inject a hovering cube and a near-miss sphere, then ASSERT the
    checker reports them. Any way this cannot be carried out - no geometry,
    no landform, an object that failed to appear - is CONTROL FAILED."""
    if not meshes:
        print("[control] import produced no mesh objects")
        return None, False

    land = [o for o in meshes if is_landform(o.name)]
    if not land:
        print("[control] no landform (*_Base) object found")
        return None, False

    pts = []
    for o in land:
        m = o.matrix_world
        for v in o.data.vertices:
            pts.append(m @ v.co)
    if not pts:
        print("[control] the landform has no vertices")
        return None, False

    top = max(p.z for p in pts)
    cx = sum(p.x for p in pts) / len(pts)
    cy = sum(p.y for p in pts) / len(pts)

    # THE INJECTION SITE HAS TO BE VERIFIED, and the first version of this
    # control did not verify it. On the swamp it dropped the near-miss sphere
    # onto the landform vertex nearest the centre, which is down among the
    # reeds at the water's edge - the sphere came back SUPPORTED, and the
    # control reported CONTROL FAILED. The checker was right and the control
    # was wrong: a defect planted somewhere it is not a defect tests nothing.
    # So both sites are now chosen by measurement against the scene's own BVH
    # and the whole thing gives up loudly if no clear site exists.
    probe = Scene([o for o in bpy.context.scene.objects if o.type == "MESH"])
    if probe.bvh is None:
        print("[control] the imported scene has no polygons to build a BVH from")
        return None, False

    def clearance(p):
        loc, _n, _i, dist = probe.bvh.find_nearest(Vector(p))
        return 1e9 if loc is None or dist is None else dist

    # The near-miss: dry ground, well above the waterline root, with nothing
    # within 0.8 studs of where the sphere's centre will sit - so the only
    # thing near it is the ground 0.6 studs below, which is the defect.
    dry = [p for p in pts if p.z > WATERLINE + 1.5]
    if not dry:
        print("[control] the landform has no ground clear of the waterline to hover over")
        return None, False
    dry.sort(key=lambda p: (p.x - cx) ** 2 + (p.y - cy) ** 2)
    ground = None
    for cand in dry[:4000]:
        if clearance((cand.x, cand.y, cand.z + 0.85)) >= 0.8:
            ground = cand
            break
    if ground is None:
        print("[control] no clear patch of ground found to plant the near-miss sphere on")
        return None, False

    # The hovering cube: the spec's height (6 studs over the landform's
    # highest point), at an xy where that height is actually open air. The
    # swamp's canopy stands 30 studs over its landform, so the xy has to be
    # chosen, not assumed.
    cube_z = top + 6.0 + 1.0
    # Kept well away from the sphere in xy: two controls where one sits in
    # the other's "what is below me" ray are one control wearing a hat.
    cube_xy = None
    for cand in dry[:4000]:
        if (cand.x - ground.x) ** 2 + (cand.y - ground.y) ** 2 < 15.0**2:
            continue
        if clearance((cand.x, cand.y, cube_z)) >= 3.0:
            cube_xy = (cand.x, cand.y)
            break
    if cube_xy is None:
        print("[control] no open air found at landform-top + 6 to plant the cube in")
        return None, False

    bpy.ops.mesh.primitive_cube_add(size=2.0, location=(cube_xy[0], cube_xy[1], cube_z))
    cube = bpy.context.active_object
    cube.name = "CTRL_FloatingCube"

    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=0.25, location=(ground.x, ground.y, ground.z + 0.6 + 0.25)
    )
    sphere = bpy.context.active_object
    sphere.name = "CTRL_NearMissSphere"

    # The UNDERSIDE control needs BOTH halves to mean anything: a bridge that
    # must be caught AND a slab lying on the ground that must not. A test
    # that only fires on the defect cannot tell a working detector from one
    # that reports everything, and "it flagged the bridge" is exactly what a
    # detector stuck in the on position looks like.
    bridge_ok_site = None
    for cand in dry[:4000]:
        if (cand.x - ground.x) ** 2 + (cand.y - ground.y) ** 2 < 15.0**2:
            continue
        if (cand.x - cube_xy[0]) ** 2 + (cand.y - cube_xy[1]) ** 2 < 15.0**2:
            continue
        # Clear air above, with only the ground itself below: a point 4
        # studs over flat ground measures ~4.0, so the bar is set under it.
        if (
            clearance((cand.x, cand.y, cand.z + 4.0)) >= 3.0
            and clearance((cand.x, cand.y, cand.z + 8.0)) >= 3.0
        ):
            bridge_ok_site = cand
            break
    if bridge_ok_site is None:
        print("[control] no open site found to build the underside bridge on")
        return None, False

    bx, by, bz = bridge_ok_site.x, bridge_ok_site.y, bridge_ok_site.z
    # Two piers 6 studs tall at the ends of a 10x6x1 deck: the middle has 6
    # studs of air under it and only the 1-stud pier heads hold it, so about
    # 2 of its 10 studs are supported - a fraction near 0.20.
    #
    # The span is 10 studs and not 6 on purpose. A 6-stud deck on two 1-stud
    # piers measures 2/6 = 0.33, which is ABOVE the default --min-support of
    # 0.25 and therefore deliberately not a finding: a third of your underside
    # on real piers is a bridge, not a hole. A control has to fail on the
    # settings the tool actually ships with, so the span is long enough for
    # the default threshold to have an opinion about it.
    # The piers overlap the deck by 0.2 rather than meeting it exactly: two
    # coincident faces make the ray that starts on them a coin flip, and the
    # first version of this control measured 0.17 on one island and 0.09 on
    # the next from geometry that was identical.
    for side in (-1, 1):
        bpy.ops.mesh.primitive_cube_add(size=1.0, location=(bx + side * 4.5, by, bz + 3.1))
        pier = bpy.context.active_object
        pier.scale = (1.0, 6.0, 6.2)
        bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
        pier.name = f"CTRL_Pier{'A' if side < 0 else 'B'}"

    bpy.ops.mesh.primitive_cube_add(size=1.0, location=(bx, by, bz + 6.5))
    deck = bpy.context.active_object
    deck.scale = (10.0, 6.0, 1.0)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    deck.name = "CTRL_BridgeSpan"

    # The negative half: the same slab, lying flat on the landform.
    flat_site = None
    for cand in dry[:4000]:
        if min(
            (cand.x - q[0]) ** 2 + (cand.y - q[1]) ** 2
            for q in ((ground.x, ground.y), cube_xy, (bx, by))
        ) < 15.0**2:
            continue
        if clearance((cand.x, cand.y, cand.z + 3.0)) >= 2.5:
            flat_site = cand
            break
    if flat_site is None:
        print("[control] no open site found to lay the flat slab on")
        return None, False
    bpy.ops.mesh.primitive_cube_add(
        size=1.0, location=(flat_site.x, flat_site.y, flat_site.z + 0.5)
    )
    flat = bpy.context.active_object
    flat.scale = (6.0, 6.0, 1.0)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    flat.name = "CTRL_FlatSlab"

    names = {o.name for o in bpy.context.scene.objects}
    want = {
        "CTRL_FloatingCube", "CTRL_NearMissSphere",
        "CTRL_BridgeSpan", "CTRL_FlatSlab", "CTRL_PierA", "CTRL_PierB",
    }
    missing = want - names
    if missing:
        print(f"[control] injected objects missing from the scene: {sorted(missing)}")
        return None, False
    print(
        f"[control] injected CTRL_FloatingCube at z={cube_z:.2f} (6 studs over the "
        f"landform top z={top:.2f}; nearest surface {clearance((cube_xy[0], cube_xy[1], cube_z)):.2f} studs) "
        f"and CTRL_NearMissSphere 0.6 studs over ground at {fmt((ground.x, ground.y, ground.z))} "
        f"(nearest surface to its centre {clearance((ground.x, ground.y, ground.z + 0.85)):.2f} studs)"
    )

    for nm in ("CTRL_BridgeSpan", "CTRL_PierA", "CTRL_PierB", "CTRL_FlatSlab"):
        o = bpy.data.objects.get(nm)
        if o is None:
            continue
        cs = [o.matrix_world @ Vector(c) for c in o.bound_box]
        print(
            f"[control]   {nm:18s} x {min(c.x for c in cs):8.2f}..{max(c.x for c in cs):8.2f}"
            f"  y {min(c.y for c in cs):8.2f}..{max(c.y for c in cs):8.2f}"
            f"  z {min(c.z for c in cs):7.2f}..{max(c.z for c in cs):7.2f}"
        )

    meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    _scene, report = analyse(
        meshes, contact, radius_arg, "control", underside, under_gap, min_support
    )
    emit(report)

    def where(name):
        for item in report["floating"]:
            if name in item["objects"]:
                return "FLOATING"
        for item in report["warn"]:
            if name in item["objects"]:
                return "WARN"
        return None

    def under(name):
        for item in report["underside"]:
            if item["object"] == name:
                return item
        return None

    cube_verdict = where("CTRL_FloatingCube")
    sphere_verdict = where("CTRL_NearMissSphere")
    ok_cube = cube_verdict == "FLOATING"
    ok_sphere = sphere_verdict in ("FLOATING", "WARN")
    print(f"[control] CTRL_FloatingCube    -> {cube_verdict}  (want FLOATING)")
    print(f"[control] CTRL_NearMissSphere  -> {sphere_verdict}  (want FLOATING or WARN)")

    ok_bridge = ok_flat = True
    if underside:
        span, flat_item = under("CTRL_BridgeSpan"), under("CTRL_FlatSlab")
        ok_bridge = span is not None and 0.08 <= span["fraction"] <= 0.32
        ok_flat = flat_item is None
        print(
            "[control] CTRL_BridgeSpan     -> "
            + (
                f"UNDERSIDE, fraction {span['fraction']:.2f}"
                f" ({span['supported_cells']}/{span['cells']} cells),"
                f" drop under the unheld part {span['min_gap']:.2f}"
                if span
                else "not reported"
            )
            + "  (want UNDERSIDE, fraction ~0.20)"
        )
        print(
            "[control] CTRL_FlatSlab       -> "
            + (
                f"UNDERSIDE, fraction {flat_item['fraction']:.2f}"
                if flat_item
                else "not reported"
            )
            + "  (want not reported)"
        )
    else:
        print("[control] underside pass disabled (--no-underside): its half of the control did NOT run")

    return report, bool(ok_cube and ok_sphere and ok_bridge and ok_flat)


# ---- main ----------------------------------------------------------------


def main():
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    if not argv:
        print(__doc__)
        return 2
    path = argv[0]
    contact = CONTACT
    radius_arg = None
    json_out = None
    control = False
    per_empty = False
    underside = True
    under_gap = UNDER_GAP
    min_support = UNDER_MIN_SUPPORT
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--contact":
            i += 1
            contact = float(argv[i])
        elif a == "--radius":
            i += 1
            radius_arg = float(argv[i])
        elif a == "--json":
            i += 1
            json_out = argv[i]
        elif a == "--control":
            control = True
        elif a == "--per-empty":
            per_empty = True
        elif a == "--no-underside":
            underside = False
        elif a == "--gap":
            i += 1
            under_gap = float(argv[i])
        elif a == "--min-support":
            i += 1
            min_support = float(argv[i])
        else:
            print(f"unknown argument {a!r}")
            return 2
        i += 1

    if not os.path.exists(path):
        print(f"no such file: {path}")
        if control:
            print("CONTROL FAILED")
        return 2

    print(f"[check_floaters] {path}  contact={contact} warn={WARN_CONTACT}")
    try:
        meshes = load(path)
    except Exception as exc:  # noqa: BLE001 - a failed import must not read as a pass
        print(f"[check_floaters] IMPORT FAILED: {exc}")
        if control:
            print("CONTROL FAILED")
        return 2

    if control:
        report, ok = run_control(meshes, contact, radius_arg, underside, under_gap, min_support)
        if json_out and report is not None:
            with open(json_out, "w") as fh:
                json.dump(report, fh, indent=1)
        print(summary_line([report]) if report is not None else summary_line([]))
        print("CONTROL OK" if ok else "CONTROL FAILED")
        return 0 if ok else 1

    if per_empty:
        groups = group_by_empty(meshes)
    else:
        groups = {os.path.basename(path): meshes}

    reports = []
    for name in sorted(groups):
        _scene, report = analyse(
            groups[name], contact, radius_arg, name, underside, under_gap, min_support
        )
        emit(report)
        reports.append(report)

    if json_out:
        with open(json_out, "w") as fh:
            json.dump(reports if len(reports) > 1 else reports[0], fh, indent=1)

    print(summary_line(reports))
    return 1 if any(r["floating"] for r in reports) else 0


if __name__ == "__main__":
    sys.exit(main())
