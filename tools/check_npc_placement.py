#!/usr/bin/env python3
"""Adversarial audit of NPC and teleport-landing placement against the REAL meshes.

    blender --background --python tools/check_npc_placement.py -- <island_pack.glb> \
        [--json out.json] [--render <dir>] [--only <island|npc_id>] \
        [--control [<npc_id>]] [--offset <npc_id>=X,Z] [--facing <npc_id>=deg]

WHY THIS EXISTS. `NpcService.placeNpc` takes `Islands.items[<island>].spawn`
(world) plus the row's `spawnOffset` (X/Z only) and probes straight DOWN for the
ground. It used to seat the humanoid on the FIRST thing a ray from y=120 hit,
with no "is this walkable" test anywhere in the path - so a stand authored UNDER
cover (Old Maren behind her counter on the porch, Quartermaster Hollow behind
his ledger desk under the awning) put the NPC on the ROOF, 18 studs up, and it
read as a normal successful placement in the log.

THE PROBE RULE, which this tool mirrors exactly (see `Island.column` /
`Island.ground` and `runtime_standable`). Collect every UPWARD-facing hit in the
XZ column, top-down. Take the LOWEST one that is

  * above the waterline (Y >= World.WATER_Y + 0.3 = MIN_GROUND_Z),
  * still COLLIDABLE at runtime - a part WorldService.NON_COLLIDE strips is
    something you fall through, never a floor (parsed from WorldService, not
    transcribed, by `parse_non_collide`),
  * not a fluid or a cover by name - RUNTIME_NOT_FLOOR: Water, Foam, Lava, Bay,
    Lagoon, Pool, Roof, Canvas, Glow. The roof/awning half of that list is the
    only thing separating a hut roof from the porch floor under it: WorldService
    deliberately keeps `_Hut_Roof` and `_Hut_Walls` SOLID so players cannot walk
    through a house, so collidability alone does not decide it,
  * and with at least FLOOR_HEADROOM (5) studs of air to the nearest SOLID
    surface above it, or nothing solid above at all. To the nearest SOLID
    surface, not the nearest hit: Hollow's ledger desk is `_Hut_Props`, which
    the runtime strips, and it hangs 3.5 studs over the sand he stands on.

If nothing in the column qualifies, the probe falls back to the old first-hit
answer and warns - that is the case check (a) reports as a FAIL here, and it is
the shape the roof bug now takes. Mismeasuring the drifted row is still the bug
class this tool exists to find; it is now checks (a) + (g) together.

The generator is the authority on intent: `assets/island_gen.py` prints HANDOFF
lines for every hut door, counter and NPC stand, and those numbers are what the
Npcs.luau rows were copied from. HANDOFF_STAND below is that table, transcribed
with the log line each entry came from, so check (g) can say "the row has
drifted off the point the builder measured" rather than only "the row lands on
something".

WHAT IS CHECKED, per NPC and (ground/slope/clearance/approach only) per island
spawn - the teleport landing:

  (a) The surface the probe rule above lands on: the object and its height.
      FAIL if the probe had to fall back (nothing standable in the column at
      all - a stand point with ONLY a roof over it), and FAIL if the object it
      did choose is not a walkable landform/deck/floor. Object names are sorted
      into four classes by the WALKABLE / SHELL / HARD_FAIL tables below: OK,
      SHELL (a building - its top is a roof, so standing on it is ON the
      building, a FAIL, but it may hold the walk-in floor, which matters for
      (f)), BAD, and UNKNOWN. UNKNOWN means "in no table", and reports as a
      WARN to be looked at, never as a silent pass.
  (b) Slope under the feet: 4 probes 0.8 studs out, cast locally (from 2.5
      studs above the feet, 8 studs of travel) so a roof overhead cannot
      swallow the measurement. FAIL over 35 deg, or if a probe misses, or if
      any probe differs from the stand height by more than 1.2 studs.
  (c) Body clearance: a 2.2 x 2.2 stud box from BODY_STEP (1.2) above the hit
      up to 5.5. FAIL if a polygon of a part that is still COLLIDABLE at
      runtime intersects it - standing inside a wall, a hull, a post, a stilt.
      An intrusion by a part WorldService strips (Hollow's ledger, Maren's stall
      clutter, a canvas awning) is a cosmetic clip a body walks through, and is
      a WARN: the same runtime truth the probe uses to reject a fluid as a
      floor, applied to the walls. Measured by BVH-to-BVH polygon overlap, so
      the report names the intruding objects. The box does NOT
      start at the feet: the ground an NPC stands on is a displaced
      heightfield, a plank deck or a rubble apron, so a box whose bottom face
      sits ON the hit is pierced by the very surface holding it up, on every
      island. Intrusions below BODY_STEP print as a "note (c) low" instead - a
      Roblox character walks over a 2-stud step.
  (d) Headroom: straight up from the feet. FAIL under 5.5 (the body does not
      fit), WARN under 7.0 (it fits, but there is a ceiling). This used to be
      tautologically infinite whenever (a) passed; now that (a) accepts a floor
      under cover it is a real measurement, and it is the check that decides
      whether an authored stand under a porch or an awning actually has room
      for a person. It is stricter than the probe on purpose (5.5 and 7.0
      against the probe's 5), and unlike the probe it counts ANY geometry
      overhead, so a low awning shows up here as a WARN.
  (e) Facing: a ray along `facing` at chest height (feet + 3.0). FAIL if it
      hits within 2.5 studs (nose in a wall). WARN if a 2-wide x 3-deep x 5.5
      box starting 2 studs ahead is intruded - the talker has nowhere to stand.
  (f) Approach: 16 points on each of three rings (3, 5 and 8 studs - the
      ProximityPrompt range is 14, so all three are places a player can talk
      from). A point is standable if the ground there is walkable, no further
      below/above the NPC than r * tan(35 deg) - the same slope limit (b)
      enforces - and its own body box is clear. A point whose FIRST hit from
      z=120 is non-walkable but which has walkable ground or a building shell
      under cover at the right height counts as INDOOR standable (that is a
      player inside the hut with the NPC, which is exactly right for a walk-in
      building) and is counted and reported separately. FAIL if NO ring
      reaches 40% of 16.
  (g) Distance from the generator's HANDOFF stand point. WARN over 3 studs,
      FAIL over 8. No HANDOFF entry -> reported as (no handoff).
  (h) Ground height >= 0.3 (the sea is z=0): FAIL if the feet are at or under
      the waterline.
  (i) Distance from the island's own teleport landing (NPCs only). FAIL under
      2.0 studs: WorldService.islandLanding puts the arriving player at
      `entry.spawn` X/Z, and on the islets that is the NPC pad itself.

COORDINATES. The .glb is Y-up and Blender's importer converts to Z-up; the
generator's mapping (island_gen.py, and check_floaters.py's `rbx`) is

    Roblox X = blender x     Roblox Y = blender z     Roblox Z = -blender y

An island's mesh origin is its `worldPosition`, so a row's stand point in
island-local Roblox coords is (spawn - worldPosition) + spawnOffset, and the
Blender probe point is (X, -Z). `facing` is a Roblox yaw, and
`CFrame.Angles(0, yaw, 0)` looks along (-sin yaw, 0, -cos yaw), so the Blender
direction is (-sin yaw, +cos yaw, 0).

POSITIVE CONTROL - `--control [npc_id]`, default old_maren. It searches the
island's `*_Hut_Roof` faces for a point the roof actually SHADOWS (a centroid
whose first downward hit is the roof itself - searching rather than assuming,
because the roof's bbox centre turned out to sit under the chimney), and then
makes BOTH assertions the probe rule needs, because a rule that sees past cover
has to be tested from both sides:

  A (negative): the same point over an island rebuilt from the ROOF POLYGONS
    ALONE - a roof with no floor under it. Check (a) must FAIL, naming the roof.
    The situation is built, not faked: a real Island over the real roof
    polygons, probed at the real point. It has to be built, because on a real
    island there is always ground somewhere below a hut - which is exactly why
    the old first-hit rule looked fine in the log.
  B (positive): the same point on the WHOLE island, where the hut floor does
    exist under the roof. The probe must skip the roof, land on a floor strictly
    BELOW it, and (a) must pass. This is the half that would have caught the old
    rule: it stood Old Maren on this roof.

A control that cannot run - no pack, no such island, no roof object, no
downward hit - prints CONTROL FAILED, and there is no path here that prints
CONTROL OK without both assertions having actually been evaluated. In control
mode the exit code is the control's verdict.

WHAT THIS TOOL DOES NOT KNOW.

  * It reads the exported .glb, which is what Studio imports - but Roblox
    raycasts test COLLISION geometry, not the render mesh, and a Default hull
    caps carved bowls. A hit reported here on the inside of a shell may be a
    hull cap at runtime. `PreciseConvexDecomposition` on walkables is the
    other half of this check and it lives in docs/import-checklist.md.
  * UNKNOWN in check (a) means "this name is in neither list", not "fine".
    Look at the render before believing an UNKNOWN pass.
  * The approach test is a 16-point sample on one ring, not a pathfind. 40% of
    a ring can still be 40% on the far side of a wall.
  * `spawnOffset.Y` is ignored by the service and ignored here.
  * HANDOFF_STAND is the generator's intent, but a generator line that phrases
    its suggestion as a spawnOffset is only as good as the island `spawn` it was
    computed against. Hollow's line quotes rel Z=167 and Islands.luau has since
    moved that landing to rel Z=178: the suggested offset is 11 studs stale, the
    stand it encodes is not. Drift is measured against the STAND.

    blender --background --python tools/check_npc_placement.py -- assets/island_pack.glb
    blender --background --python tools/check_npc_placement.py -- /tmp/pack.glb --control
    blender --background --python tools/check_npc_placement.py -- /tmp/pack.glb \
        --only tropical --render /tmp/shots
"""

import json
import math
import os
import re
import sys

import bpy  # noqa: E402
from mathutils import Vector  # noqa: E402
from mathutils.bvhtree import BVHTree  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

RAY_TOP = 120.0          # NpcService probes from y=120
RAY_LEN = 320.0
BODY_W = 2.2             # body box footprint, studs
BODY_H = 5.5             # body box height, studs
# The clearance box starts a step ABOVE the feet, not at them. The ground an
# NPC stands on is not a plane - it is a displaced heightfield, a plank deck or
# a rubble apron - so a box whose bottom face sits ON the hit point is pierced
# by the very surface holding it up, on every island. That is a measurement
# artifact, not a defect. A Roblox character walks over a 2-stud step, so
# anything under BODY_STEP is not an obstruction; it is reported as a note
# ("(c) low") and only intrusions ABOVE it are a FAIL.
BODY_STEP = 1.2
SLOPE_R = 0.8            # slope probe radius
SLOPE_MAX_DEG = 35.0
SLOPE_MAX_STEP = 1.2
HEAD_WANT = 7.0
HEAD_MIN = 5.5
FACE_MIN = 2.5           # nose-in-a-wall distance
FACE_BOX_AHEAD = 2.0     # talker box starts this far ahead
FACE_BOX_DEEP = 3.0
FACE_BOX_WIDE = 2.0
# The brief's approach ring is "3-6 studs". Two radii are tested rather than
# one: a 5.0-stud ring is the honest question on open ground, but on a small
# islet pad (Chapel's 6x4 yard, Ferryraft's bow deck) a 5-stud ring lies
# entirely off the pad and would condemn a placement a player can plainly walk
# up to. The check passes if EITHER radius clears the fraction, and both are
# printed so the shape of the pad is visible.
# 8.0 is there because the ProximityPrompt range is 14 studs: a player standing
# 8 studs off is talking to the NPC, so a ring at 8 answers the brief's actual
# question ("can a player get within prompt range on foot"). It is the radius
# that clears The Ferryman, who stands in a U of counter and cabin wall on a
# 4-stud-wide raft deck and is APPROACHED from the far side of his own counter.
# It cannot launder a genuinely bad stand: every case this audit found was
# caught by (a), (b), (c) or (h) as well as by (f).
RING_RADII = (3.0, 5.0, 8.0)
RING_R = RING_RADII[-1]
RING_N = 16
RING_MIN_FRAC = 0.40
# How far below/above the NPC a ring point may be and still count as reachable:
# derived per-radius as r * tan(SLOPE_MAX_DEG), i.e. "a point you could walk to
# without exceeding the same slope limit check (b) enforces". A flat 1.5 studs
# (the brief's number) is 18 degrees over a 5-stud ring, which is stricter than
# walkable - it failed every ring point on Whalefall's domed sandbar and
# Loadstone's rubble apron, both of which measure ~24 degrees and are plainly
# walkable ground.
HANDOFF_WARN = 3.0
HANDOFF_FAIL = 8.0
MIN_GROUND_Z = 0.3       # the sea top is z=0
# How far an NPC must stand from their island's teleport landing. WorldService
# .islandLanding drops the arriving player at `entry.spawn` X/Z (groundY + 5),
# and on every islet `spawn` IS the NPC pad with spawnOffset zero - so the
# player materialises inside the NPC. 2.0 studs is a body's width of daylight;
# it also keeps the row inside the 3.0-stud HANDOFF warn band.
MIN_LANDING_GAP = 2.0
LOCAL_UP = 2.5           # local probes start this far above the stand height
LOCAL_LEN = 8.0

# ---------------------------------------------------------------- classifying
# A first hit on one of these is a real standing surface. `_Base<digits>` is
# the landform (same rule as check_floaters.is_landform); the hut FLOOR and
# PORCH live in `*_Hut_Walls` (island_gen.py: "the porch is floor Maren and
# the player stand on ... only Island_Hut_Props is a candidate" for stripping).
WALKABLE = (
    r"_Base\d*$",
    r"Dock_Planks$",
    r"Quay_Planks$",
    r"_Hut_Walls$",      # the main-island huts' FLOOR and PORCH live here
    r"_Terraces$",
    r"_Apron$",
    r"_Yard$",
    r"_Sand$",
    r"_Dunes$",
    r"_Rim$",
    r"_Platforms$",
    r"_Wedge$",
    r"_Stacks$",
    r"_Ledges$",
    r"_Path$",
    r"_Bow$",            # Ferryraft's four platforms, per its HANDOFF line
    r"_Barge$",
    r"_Logs$",
    r"_Bridges$",
    r"^Lampwork_Rock$",  # this islet's landform is named Rock, not Base
    r"^Whalefall_Bar$",  # the whale's SANDBAR (M_WhaleSand/Wet), not a counter
    # island_gen.py builds "the flat shard-slab pad itself" (11.4 x 5.6) into
    # Loadstone_Rubble and validates it flat and prop-free by raycast ring, so
    # the rubble field IS Ansel's ground on that islet.
    r"^Loadstone_Rubble$",
)

# Building shells: their top surface is a roof, so a FIRST hit on one means the
# NPC is standing on the building rather than in it - a FAIL. But they may also
# contain the walk-in floor, so a ring point whose UNDER-COVER hit is a shell
# still counts as an indoor approach (see check (f)).
SHELL = (
    r"_Hut$", r"_Shack$", r"_Cabin$", r"_Shop$", r"_Eyrie$", r"_Nave$",
    r"_Camp$", r"_Rig$", r"_Gear$",
)

# A first hit on one of these is the bug: a roof, an awning, a prop, a post
# cap, decor, or a fluid sheet. Standing on any of them is a FAIL.
HARD_FAIL = (
    r"_Roof$", r"_Canvas$", r"Canopy", r"Awning",
    r"_Props$", r"_Posts$", r"_Trim$", r"_Walls$",
    r"_Foam$", r"Water$", r"_Lava$", r"_Lagoon$", r"_Shallows$",
    r"^Wreckwater_Bay$",  # the harbour water sheet (M_BayWater), top at z~0.17
    r"Glow", r"_Steam$", r"_Embers$", r"_Elmo$",
    r"_Birds$", r"_Moths$", r"_Gulls$", r"_Fish$", r"_Nests$",
    r"Leaves", r"_Fronds$", r"_Coconuts$", r"_Trunks$", r"_Vines$",
    r"HangMoss$", r"Cattail", r"_Mushrooms$", r"_Lilies$", r"LilyBlooms$",
    r"_Bushes$", r"_Kelp$", r"_Weed$", r"_Grass$", r"_Pines$", r"PineSnow$",
    r"DeadTrees$", r"_Crystals$", r"_Chain$", r"_Chains$", r"_Sails$",
    r"_Lamp$", r"_Lamps$", r"_Bell$", r"_Gantry$", r"_Baleen$", r"_Bones$",
    r"_Litter$", r"ShardLitter$", r"_Guano$", r"_Tally$", r"_Salvage$",
    r"_Compass$", r"_Fulgurite$", r"_Scrap$", r"_Spires$", r"_Barrels$",
    r"_Cargo$", r"_Fenders$", r"_Dinghy$", r"_Iron$", r"_Ironwork$",
    r"_Hulks$", r"SeaHulks$", r"_Wrecks$", r"_Debris$", r"_Rocks$",
    r"_Vents$", r"_Smalls$", r"_Berg$", r"_Arch$", r"_Pools$", r"_Crust$",
    r"_SnowCaps$", r"_SnowMounds$", r"_IceHoles$", r"_Stones$", r"_Stalks$",
    r"_TidePools$", r"_Rift$", r"_Mounds$",
)


# ------------------------------------------------- the RUNTIME probe rule
# NpcService.probeGroundY no longer takes the first downward hit: it collects
# every UPWARD-facing hit in the column and picks the LOWEST one that is above
# the waterline, collidable, not a fluid/roof/awning by name, and has at least
# FLOOR_HEADROOM studs of air to the next hit above it. This section is that
# rule, mirrored, so the audit measures the placement the service will actually
# make. Keep the three pieces in sync with NpcService: NOT_FLOOR below, the
# CanCollide test (emulated by parse_non_collide from WorldService's NON_COLLIDE
# list, since a .glb has no collision flags), and the headroom number.
RUNTIME_NOT_FLOOR = (
    "Water", "Foam", "Lava", "Bay", "Lagoon", "Pool", "Roof", "Canvas", "Glow",
)
FLOOR_HEADROOM = 5.0     # NpcService.FLOOR_HEADROOM
PROBE_MAX_HITS = 24      # NpcService.PROBE_MAX_HITS
NON_COLLIDE = []         # filled by parse_non_collide() in main()


def parse_non_collide():
    """WorldService's NON_COLLIDE name substrings - the parts the runtime makes
    pass-through. A non-collidable part can never be a floor (you fall through
    it), so this list is half of the probe's "is it standable" test. It is
    PARSED rather than transcribed: a copy would drift the moment an islet adds
    a new prop, and the drift would be invisible (the tool would simply stop
    agreeing with the game)."""
    text = open(os.path.join(ROOT, "src/Server/Services/WorldService.luau")).read()
    i = text.index("local NON_COLLIDE = {")
    block = _braced(text, i)
    names = re.findall(r'"([^"]+)"', block)
    if len(names) < 40:
        raise SystemExit(
            f"NON_COLLIDE parse looks wrong: {len(names)} names - the probe rule "
            "would not match the runtime")
    return names


def runtime_solid(name):
    """Does a part with this name still collide at runtime? Mirrors the
    CanCollide test NpcService makes on the live instance. A pass-through part
    is neither a floor nor a ceiling."""
    nm = stem(name)
    for bad in NON_COLLIDE:
        if bad in nm:
            return False
    return True


def runtime_standable(name):
    """Could a player stand on a part with this name at runtime? Mirrors
    NpcService.isFloorName plus the CanCollide test."""
    nm = stem(name)
    for bad in RUNTIME_NOT_FLOOR:
        if bad in nm:
            return False
    return runtime_solid(nm)


def stem(name):
    """Drop the importer's `.001` disambiguator."""
    return re.sub(r"\.\d+$", "", name)


def classify(name):
    """OK = a real standing surface, SHELL = a building (roof on top, floor
    inside), BAD = a roof/prop/decor/fluid, UNKNOWN = in no list - look at it.

    WALKABLE wins over HARD_FAIL where both match, because `*_Hut_Walls` (the
    main-island hut FLOOR and PORCH) would otherwise be caught by `_Walls$`."""
    nm = stem(name)
    for pat in WALKABLE:
        if re.search(pat, nm):
            return "OK"
    for pat in SHELL:
        if re.search(pat, nm):
            return "SHELL"
    for pat in HARD_FAIL:
        if re.search(pat, nm):
            return "BAD"
    return "UNKNOWN"


# ---------------------------------------------------------------- HANDOFF
# The generator's authored intent, transcribed from the HANDOFF lines printed
# by `blender --background --python assets/island_gen.py -- <out> pack`. Each
# value is (Roblox-relative X, Z, what the line calls it). Keep in sync with
# island_gen.py - a mismatch here is a stale audit, not a placement bug.
HANDOFF_STAND = {
    "old_maren": (20.6, -55.0, "counter stand"),
    "morra": (-20.2, 118.7, "dooryard stand"),
    "halvard": (21.0, 169.0, "hull door"),
    "brakk": (87.0, 491.0, "anvil counter"),
    "lumen": (-13.0, 160.0, "lighthouse door"),
    # The wreckwater line prints the counter at X=-38 Z=164 AND a suggested
    # offset resolved against "island spawn X=0 Z=167". The offset is the stand:
    # -1 + 167 = rel Z=166. (Islands.luau has since moved that landing to rel
    # Z=178, which is why the suggested offset itself is stale - the STAND is
    # not.) The counter is 2.2 studs from it, so measuring drift against the
    # counter would have warned on a row that is exactly where it was authored.
    "hollow": (-39.0, 166.0, "stand behind the ledger counter"),
    "nettle": (25.0, -3.6, "NPC stand"),
    "bellkeeper_odd": (0.4, 17.6, "NPC stand"),
    "pip": (18.5, -1.5, "NPC stand"),
    "cinder": (-14.2, -21.8, "bath-house apron"),
    "lampwright": (-6.0, 2.0, "NPC stand"),
    "coil": (31.5, 32.5, "NPC stand"),
    "saltmother_vess": (44.7, 9.2, "NPC stand"),
    "ferryman": (-9.65, 1.50, "NPC stand"),
    "ansel": (0.0, 33.2, "NPC stand"),
}

# ---------------------------------------------------------------- Luau parsing


def _braced(text, start):
    """The source between the `{` at/after `start` and its match."""
    i = text.index("{", start)
    depth, j = 1, i + 1
    while j < len(text) and depth:
        depth += {"{": 1, "}": -1}.get(text[j], 0)
        j += 1
    return text[i + 1:j - 1]


def _vec3(block, field):
    m = re.search(
        rf"{field}\s*=\s*Vector3\.new\(\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*\)",
        block,
    )
    if m:
        return tuple(float(g) for g in m.groups())
    return None


def parse_world():
    text = open(os.path.join(ROOT, "src/Shared/Config/World.luau")).read()
    out = {}
    for key in ("SPAWN_POSITION",):
        v = _vec3(text, rf"World\.{key}")
        out[key] = v
    return out


def parse_islands():
    """island key -> {model, worldPosition, spawn, radius}."""
    path = os.path.join(ROOT, "src/Shared/Config/Islands.luau")
    text = open(path).read()
    world = parse_world()
    body = _braced(text, text.index("Islands.items"))
    out = {}
    # Rows are one indent level in: `\n\t<key> = {`
    for m in re.finditer(r"\n\t([a-z_][A-Za-z0-9_]*)\s*=\s*\{", body):
        block = _braced(body, m.start())
        model = re.search(r'model\s*=\s*"([^"]+)"', block)
        wp = _vec3(block, "worldPosition")
        sp = _vec3(block, "spawn")
        if sp is None:
            sm = re.search(r"spawn\s*=\s*World\.([A-Z_]+)", block)
            if sm:
                sp = world.get(sm.group(1))
        rad = re.search(r"radius\s*=\s*([\d.]+)", block)
        radw = re.search(r"radius\s*=\s*World\.ISLAND_RADIUS", block)
        out[m.group(1)] = {
            "model": model.group(1) if model else None,
            "worldPosition": wp,
            "spawn": sp,
            "radius": float(rad.group(1)) if rad else (96.0 if radw else None),
        }
    return out


def parse_npcs():
    path = os.path.join(ROOT, "src/Shared/Data/Npcs.luau")
    text = open(path).read()
    rows = []
    hits = list(re.finditer(r"Npcs\.items\.([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\{", text))
    for i, m in enumerate(hits):
        end = hits[i + 1].start() if i + 1 < len(hits) else len(text)
        block = text[m.start():end]
        name = re.search(r'name\s*=\s*"([^"]+)"', block)
        island = re.search(r'island\s*=\s*"([^"]+)"', block)
        facing = re.search(r"facing\s*=\s*(-?[\d.]+)", block)
        rows.append({
            "id": m.group(1),
            "name": name.group(1) if name else m.group(1),
            "island": island.group(1) if island else None,
            "offset": _vec3(block, "spawnOffset") or (0.0, 0.0, 0.0),
            "facing": float(facing.group(1)) if facing else 0.0,
        })
    return rows


# ---------------------------------------------------------------- the scene


class Island:
    """One island's polygon soup, with a face -> object-name map."""

    def __init__(self, name, objects):
        self.name = name
        self.objects = list(objects)
        verts, polys, self.face_obj = [], [], []
        for obj in objects:
            mesh = obj.data
            mw = obj.matrix_world
            base = len(verts)
            verts.extend([mw @ v.co for v in mesh.vertices])
            for p in mesh.polygons:
                idx = [base + k for k in p.vertices]
                if len(idx) == 3:
                    polys.append(tuple(idx))
                    self.face_obj.append(obj.name)
                else:
                    for k in range(1, len(idx) - 1):
                        polys.append((idx[0], idx[k], idx[k + 1]))
                        self.face_obj.append(obj.name)
        self.verts = verts
        self.polys = polys
        self.bvh = BVHTree.FromPolygons(
            [tuple(v) for v in verts], polys, all_triangles=True
        )

    # ---- probes
    def down(self, x, y, top=RAY_TOP, length=RAY_LEN):
        """First downward hit -> (z, object name) or None."""
        loc, _n, idx, dist = self.bvh.ray_cast(
            Vector((x, y, top)), Vector((0, 0, -1)), length
        )
        if loc is None:
            return None
        return (loc.z, self.face_obj[idx])

    def column(self, x, y, top=RAY_TOP, length=RAY_LEN):
        """Every UPWARD-facing hit in the column, top-down: [(z, name), ...].

        Re-cast from just below the last hit, the same idiom NpcService uses.
        Only upward-facing faces count: a ray dropped through a landform also
        punches out through its underside, and that back face is a ceiling, not
        a floor. (The .glb's windings are the authority here - Blender's BVH
        happily reports back faces, where a Roblox raycast mostly does not.)"""
        bottom = top - length
        hits, z = [], top
        for _ in range(PROBE_MAX_HITS):
            if z <= bottom:
                break
            loc, n, idx, _d = self.bvh.ray_cast(
                Vector((x, y, z)), Vector((0, 0, -1)), z - bottom
            )
            if loc is None:
                break
            if n is not None and n.z > 0:
                hits.append((loc.z, self.face_obj[idx]))
            z = loc.z - 0.05
        return hits

    def ground(self, x, y, top=RAY_TOP, length=RAY_LEN):
        """The runtime probe: (z, name, fell_back, hits) or None.

        `fell_back` is True when nothing in the column qualified and the old
        first-hit answer was used - which is what NpcService warns about."""
        hits = self.column(x, y, top, length)
        if not hits:
            return None
        for i in range(len(hits) - 1, -1, -1):
            z, nm = hits[i]
            if z < MIN_GROUND_Z or not runtime_standable(nm):
                continue
            # Headroom to the nearest SOLID surface above, not to the nearest
            # hit: a canvas awning or a prop counter overhead is pass-through at
            # runtime, so it cannot disqualify the floor underneath it. (Hollow's
            # ledger desk sits 3.5 studs over the beach he stands on.)
            gap = math.inf
            for j in range(i - 1, -1, -1):
                if runtime_solid(hits[j][1]):
                    gap = hits[j][0] - z
                    break
            if gap >= FLOOR_HEADROOM:
                return (z, nm, False, hits)
        return (hits[0][0], hits[0][1], True, hits)

    def solid_intruders(self, *a, **kw):
        """box_intruders, minus the parts the runtime makes pass-through. A
        player (and an NPC) walks THROUGH Hollow's ledger, Maren's stall clutter
        and a canvas awning - `Wreckwater_Hut_Props` and `_Hut_Canvas` are in
        WorldService's NON_COLLIDE. Those are a cosmetic clip, reported as a
        WARN; only something still solid can trap a body, and that stays a FAIL.
        This is the same runtime truth the probe uses to reject a fluid as a
        floor, applied to the walls instead of the floor."""
        return [n for n in self.box_intruders(*a, **kw) if runtime_solid(n)]

    def up(self, x, y, z, length=40.0):
        loc, _n, idx, dist = self.bvh.ray_cast(
            Vector((x, y, z)), Vector((0, 0, 1)), length
        )
        if loc is None:
            return None
        return (dist, self.face_obj[idx])

    def shoot(self, origin, direction, length):
        loc, _n, idx, dist = self.bvh.ray_cast(
            Vector(origin), Vector(direction).normalized(), length
        )
        if loc is None:
            return None
        return (dist, self.face_obj[idx])

    def box_intruders(self, cx, cy, z0, w, h, yaw_deg=0.0, depth=None):
        """Objects whose polygons intersect an axis/yaw-aligned box.

        The box spans w wide, `depth or w` deep, h tall, sitting on z0.
        Returns a sorted list of object names."""
        d = w if depth is None else depth
        hw, hd = w * 0.5, d * 0.5
        c, s = math.cos(math.radians(yaw_deg)), math.sin(math.radians(yaw_deg))
        corners = []
        for sx, sy in ((-hw, -hd), (hw, -hd), (hw, hd), (-hw, hd)):
            rx, ry = sx * c - sy * s, sx * s + sy * c
            corners.append((cx + rx, cy + ry))
        bverts = [(x, y, z0 + 0.02) for x, y in corners]
        bverts += [(x, y, z0 + h) for x, y in corners]
        bfaces = [
            (0, 1, 2), (0, 2, 3), (4, 6, 5), (4, 7, 6),
            (0, 4, 5), (0, 5, 1), (1, 5, 6), (1, 6, 2),
            (2, 6, 7), (2, 7, 3), (3, 7, 4), (3, 4, 0),
        ]
        box = BVHTree.FromPolygons(bverts, bfaces, all_triangles=True)
        names = set()
        for a, _b in self.bvh.overlap(box):
            names.add(stem(self.face_obj[a]))
        return sorted(names)


def load_pack(path):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=path)
    meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    if not meshes:
        raise SystemExit("no meshes imported - the glb is empty or unreadable")
    groups = {}
    for o in meshes:
        cur, last = o, None
        while cur.parent is not None:
            cur = cur.parent
            if cur.type == "EMPTY":
                last = cur
        groups.setdefault(last.name if last else "(no empty)", []).append(o)
    # Axis sanity, the same assertion check_floaters makes: a landform must be
    # wide in x/y and shallow in z, which is only true after the Y-up -> Z-up
    # conversion.
    land = None
    for objs in groups.values():
        for o in objs:
            if re.search(r"_Base\d*$", stem(o.name)):
                land = o
                break
        if land:
            break
    if land is None:
        raise SystemExit("no *_Base landform found - cannot verify the axis frame")
    dims = land.dimensions
    if not (dims.x > dims.z and dims.y > dims.z):
        raise SystemExit(
            f"axis check FAILED on {land.name}: dims {tuple(round(d, 1) for d in dims)}"
        )
    print(f"[axes] Z-up confirmed on {land.name}: "
          f"x={dims.x:.0f} y={dims.y:.0f} z={dims.z:.0f}")
    return {k: Island(k, v) for k, v in groups.items()}


# ---------------------------------------------------------------- the checks


def face_dir(yaw_deg):
    """Roblox yaw -> Blender XY direction (see COORDINATES in the docstring)."""
    r = math.radians(yaw_deg)
    return (-math.sin(r), math.cos(r), 0.0)


def stand_check(isl, rx, rz, label, yaw=None, handoff=None, indoor_ok=True,
                landing=None):
    """Every geometric check at one Roblox-relative XZ. Returns a dict."""
    x, y = rx, -rz
    res = {"label": label, "rel": (rx, rz), "fails": [], "warns": [], "notes": []}

    probe = isl.ground(x, y)
    if probe is None:
        res["fails"].append("(a) no downward hit at all - off the mesh")
        res["ground"] = None
        return res
    gz, gname, fell_back, hits = probe
    res["ground"] = gz
    res["hit"] = stem(gname)
    res["hit_class"] = classify(gname)
    res["column"] = [(round(hz, 2), stem(hn)) for hz, hn in hits]
    res["fell_back"] = fell_back
    if fell_back:
        res["fails"].append(
            f"(a) NOTHING standable in the column - the probe falls back to the "
            f"first hit {res['hit']} at Y={gz:.2f} (column: "
            f"{', '.join(f'{n}@{z}' for z, n in res['column'])})")
    elif len(hits) > 1:
        res["notes"].append(
            f"(a) probe skipped {hits.index((gz, gname))} hit(s) above this floor: "
            f"{', '.join(f'{n}@{z}' for z, n in res['column'])}")
    if res["hit_class"] == "BAD":
        res["fails"].append(f"(a) the standing surface is NOT walkable: {res['hit']} "
                            f"at Y={gz:.2f}")
    elif res["hit_class"] == "SHELL":
        res["fails"].append(f"(a) the standing surface is a building shell, so this is "
                            f"ON the building not in it: {res['hit']} at Y={gz:.2f}")
    elif res["hit_class"] == "UNKNOWN":
        res["warns"].append(f"(a) standing surface {res['hit']} is in neither list "
                            "- LOOK at it")

    # (h) waterline
    if gz < MIN_GROUND_Z:
        res["fails"].append(f"(h) feet at Y={gz:.2f} - at or under the waterline")

    # (b) slope / step
    heights, misses = [], 0
    for k in range(4):
        a = math.radians(90 * k)
        px, py = x + SLOPE_R * math.cos(a), y + SLOPE_R * math.sin(a)
        p = isl.down(px, py, top=gz + LOCAL_UP, length=LOCAL_LEN)
        if p is None:
            misses += 1
        else:
            heights.append(p[0])
    if misses:
        res["fails"].append(f"(b) {misses}/4 slope probes found no ground within "
                            f"{LOCAL_LEN:.0f} studs")
    if heights:
        step = max(abs(h - gz) for h in heights)
        span = max(heights) - min(heights)
        slope = math.degrees(math.atan2(span, 2 * SLOPE_R))
        res["slope_deg"] = slope
        res["step"] = step
        if slope > SLOPE_MAX_DEG:
            res["fails"].append(f"(b) slope {slope:.1f} deg > {SLOPE_MAX_DEG:.0f}")
        if step > SLOPE_MAX_STEP:
            res["fails"].append(f"(b) ground under a foot differs by {step:.2f} studs")

    # (c) body clearance
    intr = isl.box_intruders(x, y, gz + BODY_STEP, BODY_W, BODY_H - BODY_STEP)
    low = isl.box_intruders(x, y, gz, BODY_W, BODY_STEP)
    solid = [n for n in intr if runtime_solid(n)]
    soft = [n for n in intr if not runtime_solid(n)]
    res["intruders"] = solid
    res["intruders_soft"] = soft
    res["intruders_low"] = [n for n in low if n not in intr]
    if solid:
        res["fails"].append(f"(c) body box intruded by {', '.join(solid)}")
    if soft:
        res["warns"].append(f"(c) body box clips pass-through dressing (cosmetic, "
                            f"a body walks through it): {', '.join(soft)}")
    if res["intruders_low"]:
        res["notes"].append(f"(c) low (under {BODY_STEP} studs, steppable): "
                            f"{', '.join(res['intruders_low'])}")

    # (d) headroom
    head = isl.up(x, y, gz + 0.2, length=HEAD_WANT + 40)
    res["headroom"] = head[0] + 0.2 if head else None
    res["headroom_obj"] = head[1] if head else None
    if head:
        h = head[0] + 0.2
        if h < HEAD_MIN:
            res["fails"].append(
                f"(d) headroom {h:.2f} < {HEAD_MIN} ({stem(head[1])})")
        elif h < HEAD_WANT:
            res["warns"].append(
                f"(d) headroom {h:.2f} < {HEAD_WANT} ({stem(head[1])})")

    # (e) facing
    if yaw is not None:
        d = face_dir(yaw)
        chest = (x, y, gz + 3.0)
        nose = isl.shoot(chest, d, 30.0)
        res["nose"] = None if nose is None else (nose[0], stem(nose[1]))
        if nose and nose[0] < FACE_MIN:
            res["fails"].append(f"(e) facing into {res['nose'][1]} at "
                                f"{nose[0]:.2f} studs")
        # the talker's box, 2 studs ahead
        cx = x + d[0] * (FACE_BOX_AHEAD + FACE_BOX_DEEP * 0.5)
        cy = y + d[1] * (FACE_BOX_AHEAD + FACE_BOX_DEEP * 0.5)
        tg = isl.down(cx, cy, top=gz + LOCAL_UP + 2, length=LOCAL_LEN + 4)
        base = tg[0] if tg else gz
        tb = isl.box_intruders(cx, cy, base + BODY_STEP, FACE_BOX_WIDE,
                              BODY_H - BODY_STEP,
                              yaw_deg=math.degrees(math.atan2(d[1], d[0])),
                              depth=FACE_BOX_DEEP)
        res["talker_intruders"] = tb
        if tb:
            res["warns"].append(f"(e) no room for a player in front: {', '.join(tb)}")

    # (f) approach ring - see RING_RADII
    res["rings"] = {}
    best = -1.0
    for rr in RING_RADII:
        out, inside, bad = 0, 0, []
        for k in range(RING_N):
            a = 2 * math.pi * k / RING_N
            px, py = x + rr * math.cos(a), y + rr * math.sin(a)
            f = isl.down(px, py)
            if f is None:
                bad.append(f"{int(math.degrees(a))}:void")
                continue
            pz, pname = f
            cls = classify(pname)
            dz_ok = abs(pz - gz) <= rr * math.tan(math.radians(SLOPE_MAX_DEG))
            clear = not isl.solid_intruders(px, py, pz + BODY_STEP, BODY_W,
                                            BODY_H - BODY_STEP)
            if cls == "OK" and dz_ok and clear:
                out += 1
                continue
            # Under cover: the first hit was a roof, but is there walkable
            # floor at the right height beneath it?
            u = isl.down(px, py, top=gz + LOCAL_UP, length=LOCAL_LEN)
            if (indoor_ok and u and classify(u[1]) in ("OK", "SHELL")
                    and abs(u[0] - gz) <= rr * math.tan(math.radians(SLOPE_MAX_DEG))
                    and not isl.solid_intruders(px, py, u[0] + BODY_STEP, BODY_W,
                                                BODY_H - BODY_STEP)):
                inside += 1
                continue
            bad.append(f"{int(math.degrees(a))}:{stem(pname)}")
        frac = (out + inside) / float(RING_N)
        res["rings"][rr] = {"out": out, "in": inside, "frac": frac, "bad": bad}
        if frac > best:
            best = frac
            res["ring_out"], res["ring_in"], res["ring_bad"] = out, inside, bad
            res["ring_r"] = rr
    res["ring_frac"] = best
    if best < RING_MIN_FRAC:
        detail = "; ".join(
            f"r={rr}: {res['rings'][rr]['out']}+{res['rings'][rr]['in']}/{RING_N}"
            f" [{', '.join(res['rings'][rr]['bad'][:6])}]" for rr in RING_RADII)
        res["fails"].append(f"(f) no approach ring reaches {RING_MIN_FRAC * 100:.0f}%"
                            f" standable - {detail}")

    # (g) handoff drift
    # (i) not standing on the teleport landing
    if landing:
        lx, lz = landing
        dl = math.hypot(rx - lx, rz - lz)
        res["landing_gap"] = dl
        if dl < MIN_LANDING_GAP:
            res["fails"].append(
                f"(i) {dl:.2f} studs from the teleport landing (X={lx:.1f} "
                f"Z={lz:.1f}) - the arriving player materialises inside the NPC")

    if handoff:
        hx, hz, what = handoff
        d = math.hypot(rx - hx, rz - hz)
        res["handoff"] = (hx, hz, what, d)
        if d > HANDOFF_FAIL:
            res["fails"].append(f"(g) {d:.1f} studs from the HANDOFF {what} "
                                f"(X={hx} Z={hz})")
        elif d > HANDOFF_WARN:
            res["warns"].append(f"(g) {d:.1f} studs from the HANDOFF {what} "
                                f"(X={hx} Z={hz})")
    return res


# ---------------------------------------------------------------- rendering


def render_npc(islands, isl_key, rx, rz, gz, yaw, out_dir, tag):
    """Two shots of a 5-stud capsule standing at the point: behind and front.

    A picture of the ground alone cannot show a body clipping a counter, so the
    capsule is the point of this - it is the NPC's volume, drawn in context. The
    pack stacks all sixteen islands on the origin, so every other island's
    objects are hidden for the shot and restored afterwards."""
    os.makedirs(out_dir, exist_ok=True)
    x, y = rx, -rz
    scene = bpy.context.scene
    for o in list(scene.objects):
        if o.name.startswith(("NPCStandIn", "AuditCam", "AuditSun")):
            bpy.data.objects.remove(o, do_unlink=True)

    isl_bvh = islands[isl_key].bvh
    hidden = []
    for key, isl in islands.items():
        if key == isl_key:
            continue
        for ob in isl.objects:
            if not ob.hide_render:
                ob.hide_render = True
                hidden.append(ob)

    bpy.ops.mesh.primitive_cylinder_add(radius=1.0, depth=5.0,
                                        location=(x, y, gz + 2.5))
    body = bpy.context.active_object
    body.name = "NPCStandIn"
    mat = bpy.data.materials.get("NPCStandInMat") or \
        bpy.data.materials.new("NPCStandInMat")
    mat.diffuse_color = (0.95, 0.12, 0.55, 1.0)
    body.data.materials.append(mat)
    # a nose cone so the render shows which way `facing` actually points
    d = face_dir(yaw)
    bpy.ops.mesh.primitive_cone_add(
        radius1=0.45, depth=1.6,
        location=(x + d[0] * 1.3, y + d[1] * 1.3, gz + 4.0),
        rotation=(math.pi / 2, 0, math.atan2(d[1], d[0]) - math.pi / 2))
    nose = bpy.context.active_object
    nose.name = "NPCStandInNose"
    nose.data.materials.append(mat)

    sun_data = bpy.data.lights.new("AuditSunL", type="SUN")
    sun_data.energy = 4.0
    sun = bpy.data.objects.new("AuditSun", sun_data)
    scene.collection.objects.link(sun)
    sun.rotation_euler = (math.radians(50), 0, math.radians(35))

    cam_data = bpy.data.cameras.new("AuditCamL")
    cam_data.lens = 30.0
    cam = bpy.data.objects.new("AuditCam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    scene.render.resolution_x = 900
    scene.render.resolution_y = 640
    scene.render.image_settings.file_format = "PNG"
    scene.render.film_transparent = False
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.display.shading.light = "STUDIO"
    scene.display.shading.color_type = "MATERIAL"

    target = Vector((x, y, gz + 2.5))
    paths = []
    for view, mult in (("behind", -1.0), ("front", 1.0)):
        # Find a camera position with line of sight to the body. A fixed
        # pull-back sits inside the cabin on Ferryraft and inside the hull on
        # Frostmaw, and a frame of solid brown proves nothing about placement -
        # so climb the elevation until the view is clear, and if nothing is,
        # shoot straight down.
        horiz = Vector((d[0] * mult, d[1] * mult, 0.0))
        side = Vector((-horiz.y, horiz.x, 0.0))
        # The low, near-level options are for a stand UNDER COVER, which the
        # probe now places on purpose: every elevated camera over Maren's porch
        # or Hollow's awning is blocked by the roof, and the old straight-down
        # fallback then photographed the roof - a picture of the exact thing the
        # fix is about, with the body invisible underneath it. An eye-level shot
        # from inside the cover is the one that shows the stand. The sideways
        # steps are for a camera that ends up threaded into an eave.
        chosen = None
        for dist, lift in ((12.0, 6.0), (10.0, 7.0), (9.0, 10.0), (7.0, 12.0),
                           (5.0, 14.0), (2.0, 18.0),
                           (12.0, 1.5), (9.0, 1.5), (7.0, 1.0), (5.0, 0.5),
                           (3.5, 0.0)):
            for lat in (0.0, 3.0, -3.0):
                want = target + horiz * dist + side * lat + Vector((0.0, 0.0, lift))
                # Keep the lens out of the dirt: a clear sight line can still
                # start below a crest between here and there. The floor is found
                # with the PROBE, not a first hit - lifting the camera onto a
                # roof it is deliberately underneath is how the shot got lost.
                floor = islands[isl_key].ground(want.x, want.y)
                if floor and want.z < floor[0] + 2.0:
                    want = Vector((want.x, want.y, floor[0] + 2.0))
                # Both directions, and from the camera's own eye: a ray that
                # leaves the body cleanly can still arrive inside a frond, and a
                # frame of solid roof proves nothing about the placement.
                ray = want - target
                if ray.length < 1.0:
                    continue
                if isl_bvh.ray_cast(target, ray.normalized(), ray.length)[0] is not None:
                    continue
                back = target - want
                if isl_bvh.ray_cast(want, back.normalized(), back.length)[0] is not None:
                    continue
                chosen = want
                break
            if chosen is not None:
                break
        if chosen is None:
            chosen = target + Vector((0.0, 0.0, 22.0)) + horiz * 0.5
        cam.location = chosen
        look = target - cam.location
        cam.rotation_euler = look.to_track_quat("-Z", "Y").to_euler()
        p = os.path.join(out_dir, f"{tag}_{view}.png")
        scene.render.filepath = p
        bpy.ops.render.render(write_still=True)
        paths.append(p)

    bpy.data.objects.remove(body, do_unlink=True)
    bpy.data.objects.remove(nose, do_unlink=True)
    bpy.data.objects.remove(cam, do_unlink=True)
    bpy.data.objects.remove(sun, do_unlink=True)
    for ob in hidden:
        ob.hide_render = False
    return paths


# ---------------------------------------------------------------- report


def emit(res, prefix=""):
    g = "none" if res["ground"] is None else f"{res['ground']:6.2f}"
    hit = res.get("hit", "-")
    cls = res.get("hit_class", "-")
    slope = res.get("slope_deg")
    head = res.get("headroom")
    nose = res.get("nose")
    ho = res.get("handoff")
    slope_s = "    -" if slope is None else f"{slope:5.1f}"
    head_s = "  inf" if head is None else f"{head:5.2f}"
    nose_s = "clear" if nose is None else f"{nose[0]:.2f}/{nose[1]}"
    ho_s = "-" if not ho else f"{ho[3]:.1f}"
    print(f"{prefix}{res['label']:<36}"
          f" rel(X={res['rel'][0]:7.2f} Z={res['rel'][1]:8.2f})"
          f" Y={g} hit={hit:<26}[{cls:<7}]"
          f" slope={slope_s} head={head_s} nose={nose_s}"
          f" ring@{res.get('ring_r', 0)}={res.get('ring_out', 0)}"
          f"+{res.get('ring_in', 0)}/{RING_N}"
          f" dHANDOFF={ho_s}")
    for f in res["fails"]:
        print(f"{prefix}   FAIL {f}")
    for w in res["warns"]:
        print(f"{prefix}   WARN {w}")
    for n in res["notes"]:
        print(f"{prefix}   note {n}")


# ---------------------------------------------------------------- main


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if not argv:
        print(__doc__)
        return 2
    path = argv[0]
    json_out, render_dir, only, control = None, None, None, None
    overrides, facings = {}, {}
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--json":
            i += 1
            json_out = argv[i]
        elif a == "--render":
            i += 1
            render_dir = argv[i]
        elif a == "--only":
            i += 1
            only = argv[i]
        elif a == "--control":
            control = "old_maren"
            if i + 1 < len(argv) and not argv[i + 1].startswith("--"):
                i += 1
                control = argv[i]
        elif a == "--offset":
            i += 1
            k, v = argv[i].split("=")
            overrides[k] = tuple(float(t) for t in v.split(","))
        elif a == "--facing":
            i += 1
            k, v = argv[i].split("=")
            facings[k] = float(v)
        else:
            print(f"unknown argument {a!r}")
            return 2
        i += 1

    global NON_COLLIDE
    NON_COLLIDE = parse_non_collide()
    print(f"[rule] lowest standable hit, >= {FLOOR_HEADROOM:.0f} studs headroom, "
          f"above Y={MIN_GROUND_Z}; {len(NON_COLLIDE)} NON_COLLIDE names from "
          f"WorldService + {len(RUNTIME_NOT_FLOOR)} NOT_FLOOR substrings")

    islands = load_pack(path)
    cfg = parse_islands()
    npcs = parse_npcs()
    print(f"[load] {len(islands)} island groups, {len(cfg)} registry rows, "
          f"{len(npcs)} NPC rows")

    def rel_of(npc):
        entry = cfg[npc["island"]]
        sp, wp = entry["spawn"], entry["worldPosition"]
        off = overrides.get(npc["id"], (npc["offset"][0], npc["offset"][2]))
        return (sp[0] - wp[0] + off[0], sp[2] - wp[2] + off[1])

    # ---- positive control
    if control:
        npc = next((n for n in npcs if n["id"] == control), None)
        if npc is None:
            print(f"CONTROL FAILED: no NPC row {control!r}")
            return 1
        isl = islands.get(cfg[npc["island"]]["model"])
        if isl is None:
            print(f"CONTROL FAILED: island {cfg[npc['island']]['model']!r} not in pack")
            return 1
        # Find a point the roof actually SHADOWS: a roof face centroid whose
        # first downward hit from z=120 is the roof itself. Searching rather
        # than assuming is the point - the roof's bbox centre turned out to sit
        # under the chimney (which lives in *_Hut_Walls), so a hardcoded guess
        # would quietly test the wrong thing.
        roof_faces = [fi for fi, nm in enumerate(isl.face_obj)
                      if re.search(r"_Hut_Roof$", stem(nm))]
        if not roof_faces:
            print(f"CONTROL FAILED: no *_Hut_Roof faces on {isl.name}")
            return 1
        cx = cy = None
        for fi in roof_faces:
            f = isl.polys[fi]
            px = sum(isl.verts[v].x for v in f) / 3.0
            py = sum(isl.verts[v].y for v in f) / 3.0
            hit = isl.down(px, py)
            if hit and re.search(r"_Hut_Roof$", stem(hit[1])):
                cx, cy = px, py
                break
        if cx is None:
            print(f"CONTROL FAILED: no point under {isl.name}'s roof whose first "
                  "downward hit is the roof - the control cannot be staged")
            return 1
        print(f"[control] {control} moved under the {isl.name} hut roof: "
              f"Roblox rel X={cx:.2f} Z={-cy:.2f} "
              f"(row says X={rel_of(npc)[0]:.2f} Z={rel_of(npc)[1]:.2f})")

        # --- control 1 (negative): the roof and NOTHING else in the column.
        # The probe's job is to see PAST cover, so "does it still refuse a bare
        # roof" has to be asked with a column that holds only the roof - on a
        # real island there is always ground somewhere below a hut, which is
        # precisely why the old first-hit rule looked fine in the log. The
        # situation is built, not faked: a real Island over the real roof
        # polygons, probed at the real point.
        roof_objs = [o for o in isl.objects if re.search(r"_Hut_Roof$", stem(o.name))]
        if not roof_objs:
            print(f"CONTROL FAILED: no *_Hut_Roof object on {isl.name}")
            return 1
        roof_only = Island(isl.name + " (roof only)", roof_objs)
        if not roof_only.column(cx, cy):
            print("CONTROL FAILED: the roof-only island has no downward hit at the "
                  "staged point - the control cannot be staged")
            return 1
        bare = stand_check(roof_only, cx, -cy,
                           f"CONTROL A {control} (roof, no floor under it)",
                           yaw=npc["facing"], indoor_ok=False)
        emit(bare)
        a_fail = [f for f in bare["fails"] if f.startswith("(a)")]
        if not a_fail:
            print("CONTROL FAILED: check (a) accepted a bare roof "
                  f"(it saw {bare.get('hit')!r} classed {bare.get('hit_class')!r})")
            return 1
        if not re.search(r"_Hut_Roof$", str(bare.get("hit"))):
            print(f"CONTROL FAILED: the roof-only stand hit {bare.get('hit')!r}, "
                  "not the roof - the control tested the wrong thing")
            return 1
        print(f"[control A] (a) reported: {a_fail[0]}")

        # --- control 2 (positive): the SAME point on the whole island, where
        # the hut floor does exist under the roof. The probe must skip the roof
        # and land on the floor, and (a) must pass. This is the half that would
        # have caught the old rule: it put Old Maren 18 studs up on this roof.
        under = stand_check(isl, cx, -cy,
                            f"CONTROL B {control} (same XZ, floor under the roof)",
                            yaw=npc["facing"])
        emit(under)
        if under.get("fell_back"):
            print("CONTROL FAILED: the probe found no standable floor under the roof")
            return 1
        if re.search(r"_Hut_Roof$", str(under.get("hit"))):
            print("CONTROL FAILED: the probe stood on the roof again")
            return 1
        if under.get("ground") is None or under["ground"] >= bare["ground"]:
            print(f"CONTROL FAILED: the chosen floor Y={under.get('ground')} is not "
                  f"below the roof Y={bare['ground']:.2f}")
            return 1
        if [f for f in under["fails"] if f.startswith("(a)")]:
            print("CONTROL FAILED: check (a) rejected the floor under the roof")
            return 1
        print(f"[control B] the probe skipped the roof at Y={bare['ground']:.2f} and "
              f"stood on {under['hit']} at Y={under['ground']:.2f}, "
              f"class {under['hit_class']}")
        print("CONTROL OK")
        return 0

    # ---- NPCs
    print("\n=== NPCs " + "=" * 60)
    reports, worst = [], 0
    for npc in sorted(npcs, key=lambda n: (n["island"], n["id"])):
        entry = cfg.get(npc["island"])
        if entry is None:
            print(f"FAIL {npc['id']}: unknown island {npc['island']!r}")
            worst = 1
            continue
        isl = islands.get(entry["model"])
        if isl is None:
            print(f"FAIL {npc['id']}: island model {entry['model']!r} not in the pack")
            worst = 1
            continue
        if only and only not in (npc["island"], npc["id"], entry["model"]):
            continue
        rx, rz = rel_of(npc)
        yaw = facings.get(npc["id"], npc["facing"])
        lx = entry["spawn"][0] - entry["worldPosition"][0]
        lz = entry["spawn"][2] - entry["worldPosition"][2]
        res = stand_check(isl, rx, rz,
                          f"{npc['id']} ({npc['name']}) @{npc['island']}",
                          yaw=yaw, handoff=HANDOFF_STAND.get(npc["id"]),
                          landing=(lx, lz))
        res["id"] = npc["id"]
        res["island"] = npc["island"]
        res["facing"] = yaw
        emit(res)
        reports.append(res)
        if res["fails"]:
            worst = 1
        if render_dir and res["ground"] is not None:
            paths = render_npc(islands, entry["model"], rx, rz,
                               res["ground"], yaw, render_dir, npc["id"])
            print(f"   renders: {', '.join(paths)}")

    # ---- teleport landings
    print("\n=== island spawns (teleport landings) " + "=" * 27)
    spawn_reports = []
    for key in sorted(cfg):
        entry = cfg[key]
        isl = islands.get(entry["model"])
        if isl is None or entry["spawn"] is None or entry["worldPosition"] is None:
            print(f"skip {key}: model={entry['model']} spawn={entry['spawn']}")
            continue
        if only and only not in (key, entry["model"]):
            continue
        rx = entry["spawn"][0] - entry["worldPosition"][0]
        rz = entry["spawn"][2] - entry["worldPosition"][2]
        res = stand_check(isl, rx, rz, f"spawn {key}")
        res["island"] = key
        res["spawn_y_row"] = entry["spawn"][1]
        emit(res)
        spawn_reports.append(res)
        if res["fails"]:
            worst = 1

    # ---- walking distance from the landing to the NPC (main islands)
    print("\n=== walk from the landing to the NPC " + "=" * 28)
    for npc in sorted(npcs, key=lambda n: n["island"]):
        off = overrides.get(npc["id"], (npc["offset"][0], npc["offset"][2]))
        d = math.hypot(off[0], off[1])
        if d < 0.01:
            continue
        print(f"  {npc['id']:<18} {npc['island']:<10} "
              f"offset(X={off[0]:6.1f} Z={off[1]:6.1f})  {d:6.1f} studs from the landing")

    if json_out:
        with open(json_out, "w") as fh:
            json.dump({"npcs": [
                {k: v for k, v in r.items() if k != "label"} for r in reports],
                "spawns": [
                {k: v for k, v in r.items() if k != "label"} for r in spawn_reports]},
                fh, indent=1, default=str)

    nf = sum(1 for r in reports + spawn_reports if r["fails"])
    nw = sum(1 for r in reports + spawn_reports if r["warns"])
    print(f"\n{len(reports)} NPCs + {len(spawn_reports)} spawns checked: "
          f"{nf} with FAILs, {nw} with WARNs")
    return worst


if __name__ == "__main__":
    sys.exit(main())
