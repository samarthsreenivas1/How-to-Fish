#!/usr/bin/env python3
"""wrack_patterns_gen.py - preview diagrams for Admiral Wrack's bullet hell.

WHY THIS FILE EXISTS
--------------------
Every other boss can be looked at: `boss_gen.py` and `arena_gen.py` build
meshes, and a headless Blender render answers "what does it look like".
Wrack's ATTACKS are not geometry. They are emitted at runtime by
ProjectileService from numbers in `Bosses.items.admiral_wrack`, so there is
nothing in the repo to render and no way to see the fight without launching
Studio. This script closes that gap: it re-implements the emission and the
integration EXACTLY as the two Luau files do, and draws the result as
top-down dodging maps.

WHY MATPLOTLIB AND NOT BLENDER (the house pattern)
--------------------------------------------------
Blender is right for the other previews because the thing being previewed IS
a mesh, and a 3/4 render answers "does the silhouette read". The thing being
previewed here is a *dodging problem* - where the safe lane is, how wide it
is in studs, how fast it moves relative to a 16-stud/s walk. That is a plan
view with exact analytic geometry and measured annotations, and every
strength of a rendered 3-D image (material, light, depth) works against it:
perspective destroys the one thing the reader has to judge, which is
distance. So: a 2-D plan, drawn to scale, with the numbers on it.

EVERY NUMBER BELOW IS COPIED FROM THE SOURCE, NEVER INVENTED
------------------------------------------------------------
  * `ATTACKS`        - verbatim from `Bosses.items.admiral_wrack.attacks`
                       (src/Shared/Data/Bosses.luau).
  * the emitters     - a line-for-line port of `PATTERNS.*` in
                       src/Server/Services/ProjectileService.luau.
  * the integration  - the same file's `tick()`: constant velocity, the
                       turn-rate-limited homing, the linked pair whose
                       midpoint runs on the lead's velocity while the offset
                       spins, retirement on lifetime / on leaving `bound`.
  * the cadence      - the Wrack handlers in
                       src/Server/Services/CreatureService.luau (volley
                       interval and gap step, burst gap and half-pellet
                       phase, the slewfire tick loop).
  * the arena        - `WK_*` in assets/arena_gen.py (sand walkable to r 132
                       and EMPTY, the palisade of grounded hulls at r 140-152).
                       The six breakwater hulks are gone; so is every other
                       obstacle. Nothing stands on the floor.
  * the hull + guns  - `parts.mounts` in Bosses.luau and `WR_HULL` /
                       `AUTHORED` (boss_gen.py, WrackBodyController.luau).

DETERMINISTIC AND RE-RUNNABLE
-----------------------------
There is no rng anywhere in this file. The two things the fight randomises -
broadside's initial gap bearing and the damage roll - are pinned to stated
constants (`GAP0_*`) so a re-run is byte-comparable, and the choice is
labelled on the drawing rather than hidden.

USAGE
-----
    python3 assets/wrack_patterns_gen.py [out_dir]

Writes `wrack_pattern_<name>.png` for each of the FIVE surviving ball rows
plus `wrack_patterns_sheet.png`, the contact sheet. Default out_dir is the
directory this script lives in.

WHAT THIS FILE DOES *NOT* DRAW, AS OF THE 2026-09-08 ROSTER REWORK
------------------------------------------------------------------
Four of the nine ball rows were retired (chainshot, slewfire, slewfireFast,
grapeshotTwin) and five mechanics took their place - a homing keg you shoot,
three pillars you douse, a battery you jam, a chain you break, a boarding
party you stop. They are gone from `ATTACKS` and `ORDER` here, so the escape
roses below are re-measured over the surviving five and nothing else.

The five NEW mechanics are deliberately not drawn. A plan view answers
"where is the safe lane and how wide is it in studs", which is the whole
question for a wall of cannonballs and almost none of the question for any of
them: their answers are ranges, timings and target priorities, not geometry.
A picture of a keg at one instant would say nothing true. What they get
instead is the HANDOFF block at the bottom of a run - their key numbers,
derived rather than transcribed where a derivation exists (the fuse budget
against the closing speed, the march against the health bar, the jam against
the battery), printed so they can be diffed against the Luau exactly the way
the drawn rows' numbers are.
"""

import math
import os
import sys
import textwrap

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt
import numpy as np
from matplotlib.patches import Arc, Circle, Ellipse, FancyArrow, Polygon, Rectangle, Wedge

TAU = math.pi * 2

# ============================================================ the source data
#
# Bosses.items.admiral_wrack.attacks - transcribed field for field. Keys that
# only matter to the tell (tellRange, tellWidth, tellReach, markAt) are kept
# so the rows can be diffed against the Luau by eye.
ATTACKS = {
    "broadside": dict(
        handler="broadside", skin="cannon", windup=1.15, duration=2.5, recover=0.8, cooldown=9.0,
        count=30, speed=30, radius=3.0, spawnAt=16, markAt=26, lifetime=4.15,
        gapDeg=34, gapStep=46, volleys=3, interval=1.1, damage=(44, 58),
    ),
    "broadsideHeavy": dict(
        handler="broadside", skin="cannon", windup=1.0, duration=3.4, recover=0.7, cooldown=10.0,
        count=40, speed=34, radius=3.0, spawnAt=16, markAt=26, lifetime=3.65,
        gapDeg=24, gapStep=58, volleys=4, interval=0.85, damage=(48, 64),
    ),
    "grapeshot": dict(
        handler="grapeshot", skin="grape", windup=0.8, duration=0.45, recover=0.5, cooldown=6.0,
        pellets=8, fanDeg=40, speed=66, spawnAt=22, radius=1.6, lifetime=1.8,
        bursts=1, burstGap=0.35, tellRange=110, damage=(40, 54),
    ),
    "anchorsweep": dict(
        handler="anchorsweep", skin="anchor", windup=3.2, duration=0.6, recover=1.1, cooldown=16.0,
        count=23, arcDeg=180, speed=26, radius=4.2, spawnAt=16, lifetime=4.8,
        ripple=0.09, tellRange=130, tellWidth=150, tellReach=40, damage=(78, 104),
    ),
    "wisps": dict(
        handler="wisps", skin="wisp", windup=0.7, duration=0.4, recover=0.5, cooldown=13.0,
        count=3, speed=19, homingDeg=70, radius=2.2, spawnAt=12, lifetime=6,
        spreadDeg=360, damage=(24, 32),
    ),
}

# The order the fight teaches them in: phase 1's three, then phase 2's
# additions, then the phase-3 swaps. `phases` in Bosses.luau.
ORDER = [
    "grapeshot", "broadside", "wisps",
    "anchorsweep",
    "broadsideHeavy",
]
# `PHASE_OF` is GONE, not merely unused. The fight no longer has three health
# phases: it has three ACTS that advance on events, and the drawn rows are
# labelled off `ACT_OF` (derived from ACT_PHASES below) instead. A stale table
# saying "broadsideHeavy is phase 3" beside an act-gated fight is exactly the
# number the next reader would believe.

# ---- the arena (assets/arena_gen.py, WK_* constants) -----------------------
#
# THE CAREENAGE AS REBUILT (231a200 / 31386ab). One plain walkable beach out
# to r 132 with NOTHING standing on it, ringed by a palisade of grounded hulls
# whose centres sit at r 141-160. The six breakwater hulks the old fight used
# for cover are gone, and so is every other obstacle: no cradle, no furrows,
# no spoil, no pools. Every number below is read off arena_gen.py's WK_*
# block, not remembered.
SAND_R = 132.0          # WK_SAND_R: walkable sand ends. Nothing stands on it.
FLEET_R = (140.0, 152.0)  # WK_FLEET_R: where the palisade's grounded hulls start
FOAM_R = (161.0, 167.5)   # WK_FOAM_R: the surf breaking round the outside
PARTY_R = 88.0          # Bosses arena.radius 80 + BossService's +8
BOUND_R = 140.0         # Bosses arena.radius 80 + WRACK_BOUND_MARGIN 60
# WK_FLEET_GAP_DEG / WK_SEA_DEG: the mouth in the palisade, 46 degrees wide,
# centred on the water. In BLENDER degrees, so it converts like everything
# else below.
WK_SEA_DEG = 90.0
WK_FLEET_GAP_DEG = 46.0

# The beach's walkable height band (WK_SEA_Z .. WK_HEAD_Z): +0.45 at the
# water's edge, +4.85 at the head. Flat enough that the flat XZ hit test this
# file simulates is the whole truth - HEIGHT_TOLERANCE in ProjectileService is
# far wider than 4.4 studs of beach.
SAND_Z = (0.45, 4.85)

# Half-width of every plan in studs. Wide enough to hold the whole walkable
# beach, the retire bound and the inner face of the palisade.
PLAN_SPAN = 152.0

# ---- the boss (Bosses.luau parts.mounts, boss_gen WR_HULL, AUTHORED) -------
#
# yaw0 IS ZERO. BossService.raise spawns him with no throw target, so
# yawToward(nil) = 0; his turnRate is 0 so the prowl branch writes the same
# value back forever. bossFacing = (cos 0, 0, -sin 0) = world +X: THE BOW
# POINTS ALONG +X. spawnBossParts' mount transform therefore reduces to a
# straight translation, so a mount's boss-local (X, Z) IS its world offset.
BOSS_YAW0 = 0.0
# THE UPRIGHT REBUILD (mesh 7673cd1, 2026-09-08). She stands instead of lying
# careened, at less than half the size, with four INTEGRAL cannons. Transcribed
# from `parts.mounts` in Bosses.luau, where the entry is Vector3(X, Y, Z) and Y
# is the height: the columns below are (label, X, Z, Y).
#
# THE THREE-ACT REWORK (2026-09-09) MOVED ALL FOUR AGAIN. The user's mandate:
# "the 4 cannons ... should be visible to the user and they should have to move
# around the map to shoot all 4, they shouldnt be able to shoot through the
# boss. it should be all 4 corners of the main ship should be the 4 cannons."
# The mesh lane answered with SPONSONS at +-30 / +-150 degrees, centroid radius
# 19, wholly OUTBOARD of the hull - corners of the ship rather than four
# bearings 90 degrees apart. Canonical order is the mesh's:
# BowStbd, BowPort, SternStbd, SternPort.
#
# AND THEY ARE PERMANENT. `parts.regrow` is DELETED for this rework, so the
# fourth kill is the act-1 -> act-2 transition rather than the top of another
# cycle. Nothing here regrows them either: ACT_ONE_STEPS below walks the count
# down 4 -> 0 once.
MOUNTS = [  # (label, local X, local Z, height above the sand)
    ("BowStbd", 16.45, -9.50, 13.20),
    ("BowPort", 16.45, 9.50, 13.20),
    ("SternStbd", -16.45, -9.50, 14.00),
    ("SternPort", -16.45, 9.50, 14.00),
]
# THE GUNS, AS EMITTERS. Since 2026-09-06 every ball leaves a LIVE BATTERY,
# not a circle round the arena centre - `ctx.muzzle` / `ctx.decks` in
# ProjectileService. The flat offsets are the whole of what the emitters need
# (the balls fly in one plane; the heights above only place the muzzle flash).
MOUNT_XZ = [(mx, mz) for _label, mx, mz, _h in MOUNTS]
MOUNT_LABEL = [label for label, _x, _z, _h in MOUNTS]
# Flat radii of the four cannons, and the closest pair's spacing. Derived here
# rather than remembered, because three of the new mechanics are tuned against
# them (the keg's spawn, the boarders' `reach`, the overload's marker size) and
# all three moved when the mesh did.
GUN_R = [math.hypot(mx, mz) for _label, mx, mz, _h in MOUNTS]
GUN_R_MIN, GUN_R_MAX = min(GUN_R), max(GUN_R)
MOUNT_MIN_GAP = min(math.hypot(a[1] - b[1], a[2] - b[2])
                    for i, a in enumerate(MOUNTS) for b in MOUNTS[i + 1:])
# Creatures.items.wrack_battery.health - what `jam` and `repair` are fractions
# of, and the one number those two rows cannot be read without.
#
# 3600, not 2800: with `regrow` gone the four guns ARE act one, so their bar is
# the act's whole length rather than one cycle of a loop. See ACT_HP below.
BATTERY_HP = 3600

# Every battery alive. `wrackDecks` in CreatureService hands ProjectileService
# exactly this list, minus whatever the party has broken.
DECKS_ALIVE = [0, 1, 2, 3]
# THE FOOTPRINT, AND WHAT IT IS NOT. The careened wreck was drawn here from
# `WR_HULL`'s ten stations, scaled across to the measured beam - a real
# waterline profile. The upright rebuild's stations are the mesh lane's to
# publish and this file does not have them, so it draws the MEASURED BOUNDING
# BOX instead: 48 studs bow to stern, 12.6 in the beam (mesh HANDOFF, 7673cd1),
# as a plain ellipse. That is honest about being an outline rather than a hull,
# and it is the right call for these diagrams anyway - nothing here is a
# question about the ship's shape, and at a 152-stud half-span the difference
# between an ellipse and a fair curve is under a pixel. Her bed of spoil is
# gone with the careening: she stands on the sand.
HULL_BBOX = (48.0, 12.6)

# ---- the shot occluder (three-act rework, 2026-09-09) ----------------------
#
# "they shouldnt be able to shoot through the boss." The server builds an
# invisible anchored part at spawn - a clone of the mesh lane's
# `Wrack_HullCollider` (closed loft over the hull stations, +0.3 margin, no
# waist gap), Transparency 1, CanQuery AND CanCollide true, parented to
# Workspace.World.
#
# THE FOLDER IS THE MECHANISM, not a detail. ShotAim.terrainLimit builds
# `FilterType = Include` over the World folder ALONE, so a collider parented
# anywhere else - the Creatures folder, the BossArenas folder, bare Workspace -
# is invisible to every server-side shot and the whole thing silently does
# nothing. RespectCanCollide is true there, which is why CanCollide must be set
# and CanQuery alone is not enough. The client's half
# (RangedController.aimDistance) excludes the character and the four FX folders
# with RespectCanCollide, so the same part stops the same ray there.
#
# Extents are the mesh lane's, boss space (x, y, height), converted to the
# (X, Z, height) columns this file uses everywhere else.
# Restated by the mesh lane in this file's (X, height, Z) convention,
# 2026-09-09 (WR_HULLCOLLIDER). Not hand-converted here - a transform applied
# twice, once by each lane, is a number nobody owns.
COLLIDER_X = (-21.5, 20.5)
COLLIDER_H = (0.70, 15.00)
COLLIDER_Z = (-6.60, 6.60)

# THE TWO ORIGINS, and they are NOT interchangeable - this is the whole reason
# the check below runs twice.
#
#   * the EYE is the raised Careenage orbit's camera (BIRDSEYE 27.3 up,
#     142.5 out). It decides what the player can SEE.
#   * the SHOT leaves the CHARACTER, not the lens - RangedController resolves
#     the crosshair's depth down the camera ray and then fires from the
#     shooter's root + ORIGIN_LIFT. It decides what the player can HIT.
#
# The mesh lane traced the eye and found that a 13.7-stud hull cannot occlude
# anything from 27.3 studs up: hull occlusion FAILS at camera height, and the
# "only two at a time" property has to come from each sponson's own inboard
# BULKHEAD instead. That is mesh-side. This file's job is the other origin -
# the shot, from ground level, where the hull does block - plus the check that
# the two answers agree.
EYE_Y = 27.3
SHOT_Y = 4.5  # HumanoidRootPart (~3 up) + RangedController's ORIGIN_LIFT 1.5

GUN_BEARING = [(mx / math.hypot(mx, mz), mz / math.hypot(mx, mz))
               for _label, mx, mz, _h in MOUNTS]

# ---- the casemates, and why the flat bulkhead was the wrong model ----------
#
# The first pass here modelled each sponson's shielding as ONE inboard plate -
# a half-plane through the gun with the gun's own bearing as its normal. It
# flattered the geometry, and the mesh lane then proved there is NO working
# half-width for a flat plate: under 20 studs it still leaks three guns, over
# 26 it eats the sponson's OWN gun on 56 of 144 samples. No window exists, and
# a central superstructure changes nothing, because the leaks run AROUND the
# hull's ends rather than over her middle.
#
# So the sponsons are three-sided CASEMATES: a back wall and two cheeks,
# collidable, bounded by the gun's own box - which by construction cannot
# swallow the gun it houses. Modelling only the back face reports a leak the
# real geometry does not have, which is what the earlier revision of this file
# did.
#
# The mesh lane's solved dimensions (2026-09-09), per gun, in its own bearing
# frame, with `r` measured from the ship's centre along that bearing:
CASEMATE_R_BACK = 13.0   # back wall
CASEMATE_HW = 4.0        # half-width: back wall's, and the cheeks' offset
CASEMATE_R_OUT = 23.0    # how far out the cheeks project past the gun
CASEMATE_Z = (8.5, 17.5)  # the plates' height band, absolute above the sand
#
# `CASEMATE_R_OUT` IS THE PARAMETER THIS CHECK EXISTS TO WATCH. The other two
# are a plateau - back r 12 vs 13 crossed with cheek +-3.2 vs +-4.0 are
# byte-identical - but the projection is KNIFE-EDGED at +-2 studs and fails in
# both directions: r 21 leaks the far gun on 28 of 72 bearings, r 25 eats the
# sponson's own on 4. Only r 23 is inside the window. A model that cannot
# express this parameter cannot see the cliff, and will report the flat
# plate's "no window" result forever - which is why `mouth` is threaded all
# the way through `guns_clear` and `gun_sweep` rather than being a constant.
#
# The acceptance half-angle the box implies, derived rather than stated so a
# retune shows up as a changed angle instead of a changed histogram nobody can
# explain. Measured at the gun, which stands `GUN_R_MAX` out.
CASEMATE_HALF_DEG = math.degrees(math.atan2(CASEMATE_HW, CASEMATE_R_OUT - GUN_R_MAX))

# ---- the three acts (2026-09-09) ------------------------------------------
#
# ACT 1 THE GUNS   hull IMMUNE and a physical occluder; the four permanent
#                  sponson cannons are the fight. Cannon-native rows only.
# ACT 2 THE SHIP   hull VULNERABLE and now the emitter; the ship-body rows.
# ACT 3 THE DUEL   a SECOND creature (`wrack_admiral`, Bosses row `wrack_duel`)
#                  on the sand, mobile, hittable by melee and guns alike.
#
# Acts advance by EVENTS, not by health fractions: act 1 ends on the fourth
# permanent gun kill, act 2 on the hull reaching zero. Within an act the health
# fraction still sub-phases. `Fn.bossPhaseAttacks` only speaks health
# fractions, so acts 1-2 ride ONE synthetic dial (`creature.actFraction`,
# read through `Fn.bossPhaseFraction`) that is monotonic across both:
#
#     act 1:  0.60 + 0.40 * (gunsAlive / 4)     4:1.00 3:0.90 2:0.80 1:0.70
#     act 2:  0.60 * (hullHp / hullMax)         full:0.60  dead:0.00
#
# Act 3 is a different creature with its own row, so it keeps the ordinary
# health fraction and needs no dial.
ACT_HP = {1: 4 * BATTERY_HP, 2: 24000, 3: 20000}

# The two classes a phase may run, and no more (Bosses.luau's rule):
#   (a) READ AND WALK - a pattern with a shape and a hole in it
#   (b) BREAK A CLOCK - something you must damage before its timer runs out
CLASS_OF = {
    "grapeshot": "a", "broadside": "a", "broadsideHeavy": "a", "wisps": "a",
    "anchorsweep": "a", "anchorline": "a", "bilgeblow": "a",
    "powderrun": "b", "powderrunTwin": "b", "ghostbraziers": "b",
    "cannonoverload": "b", "longboat": "b", "ladybelow": "b",
    "ladybelowTriple": "b", "boomsweep": "b",
    # the duel: everything is (a) except the stance, which is (b) inverted -
    # the clock you must NOT put damage into.
    "sabrelunge": "a", "cleave": "a", "cleaveDouble": "a", "flintlock": "a",
    "lastbroadside": "a", "ripostestance": "b",
}

# The phase table as it will be authored, band by band, with the act each band
# belongs to and the dial value that opens it.
ACT_PHASES = [
    (1, 1.00, ["grapeshot", "broadside", "powderrun", "cannonoverload"]),
    (1, 0.80, ["grapeshot", "broadsideHeavy", "powderrun", "cannonoverload", "anchorline"]),
    (2, 0.60, ["broadside", "wisps", "ladybelow", "bilgeblow"]),
    (2, 0.40, ["broadside", "wisps", "ladybelow", "boomsweep", "ghostbraziers", "longboat"]),
    (2, 0.20, ["broadsideHeavy", "wisps", "ladybelowTriple", "boomsweep",
               "ghostbraziers", "longboat", "bilgeblow", "anchorsweep"]),
]
# Act 3's own table, on `wrack_duel`'s ordinary health fraction.
DUEL_PHASES = [
    (1.00, ["sabrelunge", "cleave", "flintlock"]),
    (0.66, ["sabrelunge", "cleave", "flintlock", "ripostestance"]),
    (0.33, ["sabrelunge", "cleaveDouble", "flintlock", "ripostestance", "lastbroadside"]),
]
# Which act each DRAWN ball row is live in, for the diagrams' labels. A row can
# be live in both acts (broadside is the signature and never leaves).
ACT_OF = {}
for _act, _below, _rows in ACT_PHASES:
    for _row in _rows:
        ACT_OF.setdefault(_row, _act)

# Act one walks the gun count down ONCE - no regrow. The scale each step emits
# at is Fn.wrackScale's `0.4 + 0.6 * (alive / count)`, unchanged.
ACT_ONE_STEPS = [4, 3, 2, 1, 0]

PLAYER_SPEED = 16.0  # Roblox default; nothing in src/ sets Humanoid.WalkSpeed.
PLAYER_DOT_R = 1.0   # the root part is 2x2x1; the hit test is a POINT vs the ball radius.

# The reference challenger, used identically by all nine diagrams: dropped on
# the party ring at bearing 90 deg (BossService.ringPositions puts the party
# on arena.radius + 8). Every aimed pattern latches this bearing, because
# wrackAim reads the nearest player once at windup start.
REF_BEARING = 90.0
REF_POS = (math.cos(math.radians(REF_BEARING)) * PARTY_R, math.sin(math.radians(REF_BEARING)) * PARTY_R)

# broadside's gap bearing is seeded random in the fight (`creature.wrackGap or
# math.random() * 2pi`). Pinned here so the render is reproducible; the
# drawing says so.
GAP0_BROADSIDE = 205.0
GAP0_HEAVY = 190.0

# ============================================================ the palette
#
# Five bullet skins is more than the three categorical slots that clear the
# all-pairs colourblind gate, so the relief the method allows is used: the
# contact sheet is SMALL MULTIPLES (one skin per panel, every panel titled
# with its own name), and mark geometry is a second, data-driven channel -
# the radii really are 1.6 / 2.0 / 2.4 / 2.2 / 3.4 and only the chain is a
# capsule. Slots 1-3 (validated all-pairs, dark) carry cannon / grape /
# chain; wisp and anchor take slots 4 and 8.
INK = "#e9edf2"
INK_DIM = "#9fadba"
INK_FAINT = "#6b7885"
BG = "#111619"
SAND = "#332e27"
SAND_EDGE = "#4a4238"
AWASH = "#1b2225"
HULK = "#5d4e3b"
HULK_EDGE = "#9a8467"
HULL = "#1d242b"
HULL_EDGE = "#46535f"
BRASS = "#e0a03a"
GHOST = "#8ff2cc"   # WK_GHOST, the arena's own ghost-fleet light: THE ANSWER
DANGER = "#ff6b6b"

SKIN = {
    "cannon": "#3987e5",
    "grape": "#d95926",
    "chain": "#199e70",
    "wisp": "#c98500",
    "anchor": "#e66767",
}
SKIN_LABEL = {
    "cannon": "cannon",
    "grape": "grape",
    "chain": "chain",
    "wisp": "wisp",
    "anchor": "anchor",
}

plt.rcParams.update({
    "figure.facecolor": BG,
    "savefig.facecolor": BG,
    "axes.facecolor": BG,
    "font.family": "DejaVu Sans",
    "text.color": INK,
})


# ============================================================ geometry
def bearing(deg):
    """ProjectileService's `bearing(angle)`: (cos t, sin t) in world (X, Z)."""
    a = math.radians(deg)
    return (math.cos(a), math.sin(a))


def rot90(v):
    """rotateFlat(v, pi/2) - the side vector chainshot hangs its pair from."""
    return (-v[1], v[0])


def blender_to_xz(radius, degrees):
    """arena_gen build space -> roblox X/Z. roblox Z = -blender y."""
    a = math.radians(degrees)
    return (math.cos(a) * radius, -math.sin(a) * radius)


def count_of(n, scale):
    """ProjectileService.countOf."""
    return max(1, int(round(n * scale)))


# ---- the gun decks as emitters --------------------------------------------
#
# A port of ProjectileService's `deckRunOut` / `muzzleOf`, which are the two
# ways a pattern can be fired FROM THE BRASS rather than from the middle of
# the hull.
def decks(alive=None):
    """The live batteries as flat (x, z) offsets from the arena centre."""
    return [MOUNT_XZ[i] for i in (DECKS_ALIVE if alive is None else alive)]


def deck_run_out(dir_, alive=None):
    """RADIAL patterns (broadside, slewfire). The ball leaves the deck that
    faces its own bearing, so the muzzle is that deck's RANGE along the ball's
    own ray: `spawnAt + dot(mount, dir)`, never the full offset.

    Only the along-ray component, deliberately. Applying the whole mount
    vector would translate each deck's arc sideways by up to 40 studs and tear
    three permanent extra holes in the broadside wall at the sector seams -
    a second gap, standing still, in the one pattern whose entire identity is
    "exactly ONE gap". Projected onto the ray, every ball keeps its authored
    BEARING exactly (so the gap is exactly `gapDeg`) and the only thing the
    decks change is how far out the wall is born on each side: the ring bulges
    toward the live guns, and flattens where one has been silenced."""
    live = decks(alive)
    if not live:
        return 0.0
    best, best_cos = 0.0, -1e9
    for (mx, mz) in live:
        mag = math.hypot(mx, mz)
        if mag < 1e-3:
            continue
        along = mx * dir_[0] + mz * dir_[1]
        cosine = along / mag
        if cosine > best_cos:
            best_cos, best = cosine, along
    return max(best, 0.0)


def deck_for_aim(aim_deg, alive=None):
    """AIMED patterns (grapeshot, chainshot, anchorsweep). The whole fan
    leaves ONE gun - the live battery best lined up with the shot - so the
    telegraph, the muzzle flash and the balls all come from the same brass."""
    live = decks(alive)
    if not live:
        return (0.0, 0.0)
    d = bearing(aim_deg)
    return max(live, key=lambda m: (m[0] * d[0] + m[1] * d[1]) / max(math.hypot(*m), 1e-3))


def aim_from(origin, target):
    """Re-aim: a fan fired from a gun 40 studs off-centre has to point at the
    target FROM THERE, or the shot the tell promised lands somewhere else."""
    dx, dz = target[0] - origin[0], target[1] - origin[1]
    m = math.hypot(dx, dz) or 1.0
    return math.degrees(math.atan2(dz / m, dx / m))


# ============================================================ the emitters
#
# Ported line for line from ProjectileService's PATTERNS table. Each returns
# a list of balls; a ball is a dict with pos (x, z), vel, radius, born (the
# time in the strike it was emitted) and - for chainshot - the pair link.
def emit_broadside(p, gap_deg, scale=1.0, alive=None):
    count = count_of(p["count"], scale)
    gap = math.radians(p["gapDeg"])
    # THE AUTHORED GAP IS THE TRUE EMPTY WEDGE. `count` balls are laid across
    # the rest of the circle INCLUSIVE of both ends, so the arc from the last
    # ball to the first - the hole the player walks into - is exactly `gapDeg`
    # and nothing else. (Before 2026-09-06 the balls sat half a step inside a
    # span of TAU - gap, which made the real hole gapDeg + one step: 48.8 deg
    # against an authored 34.)
    span = TAU - gap
    step = span / (count - 1) if count > 1 else 0.0
    start = math.radians(gap_deg) + gap * 0.5
    out = []
    for i in range(count):
        d = bearing(math.degrees(start + step * i))
        r0 = p["spawnAt"] + deck_run_out(d, alive)
        out.append(dict(
            pos=(d[0] * r0, d[1] * r0),
            vel=(d[0] * p["speed"], d[1] * p["speed"]),
            radius=p["radius"], lifetime=p["lifetime"],
        ))
    return out


def emit_grapeshot(p, base_deg, phase, scale=1.0, alive=None, target=None):
    pellets = count_of(p["pellets"], scale)
    fan = p["fanDeg"]
    step = fan / (pellets - 1) if pellets > 1 else 0.0
    gun = deck_for_aim(base_deg, alive)
    base = aim_from(gun, target if target else bearing(base_deg))
    out = []
    for i in range(pellets):
        d = bearing(base - fan * 0.5 + step * (i + phase))
        out.append(dict(
            pos=(gun[0] + d[0] * p["spawnAt"], gun[1] + d[1] * p["spawnAt"]),
            vel=(d[0] * p["speed"], d[1] * p["speed"]),
            radius=p["radius"], lifetime=p["lifetime"],
        ))
    return out


def emit_chainshot(p, base_deg, scale=1.0, alive=None, target=None):
    pairs = count_of(p["pairs"], scale)
    fan = p["fanDeg"]
    half = p["chain"] * 0.5
    step = fan / (pairs - 1) if pairs > 1 else 0.0
    gun = deck_for_aim(base_deg, alive)
    base = aim_from(gun, target if target else bearing(base_deg))
    out = []
    for i in range(pairs):
        ang = base - fan * 0.5 + step * i
        d = bearing(ang)
        side = rot90(d)
        origin = (gun[0] + d[0] * p["spawnAt"], gun[1] + d[1] * p["spawnAt"])
        out.append(dict(
            mid=origin,
            off=(side[0] * half, side[1] * half),
            vel=(d[0] * p["speed"], d[1] * p["speed"]),
            radius=p["radius"], chainRadius=p["chainRadius"],
            spin=math.radians(p["spinDeg"]), lifetime=p["lifetime"],
        ))
    return out


def emit_slewfire_tick(p, deck_deg, scale=1.0, alive=None):
    # SCALES LIKE EVERY OTHER PATTERN since 2026-09-06 - it used to read
    # `max(1, p.arms)` raw and was the one row that did not thin as the
    # batteries fell, contradicting CreatureService's own header.
    arms = count_of(p["arms"], scale)
    out = []
    for i in range(arms):
        d = bearing(deck_deg + (360.0 / arms) * i)
        r0 = p["spawnAt"] + deck_run_out(d, alive)
        out.append(dict(
            pos=(d[0] * r0, d[1] * r0),
            vel=(d[0] * p["speed"], d[1] * p["speed"]),
            radius=p["radius"], lifetime=p["lifetime"],
        ))
    return out


def emit_anchorsweep(p, base_deg, scale=1.0, alive=None, target=None):
    count = count_of(p["count"], scale)
    arc = p["arcDeg"]
    ripple = p["ripple"]
    step = arc / (count - 1) if count > 1 else 0.0
    gun = deck_for_aim(base_deg, alive)
    base = aim_from(gun, target if target else bearing(base_deg))
    out = []
    for i in range(count):
        d = bearing(base - arc * 0.5 + step * i)
        head = ripple * (count - 1 - i) * p["speed"]
        r0 = p["spawnAt"] + head
        out.append(dict(
            pos=(gun[0] + d[0] * r0, gun[1] + d[1] * r0),
            vel=(d[0] * p["speed"], d[1] * p["speed"]),
            radius=p["radius"], lifetime=p["lifetime"], head=head,
        ))
    return out


def emit_wisps(p, base_deg, scale=1.0, alive=None):
    count = count_of(p["count"], scale)
    spread = p["spreadDeg"]
    live = decks(alive) or [(0.0, 0.0)]
    out = []
    for i in range(count):
        d = bearing(base_deg - spread * 0.5 + (spread / max(count, 1)) * (i + 0.5))
        # ONE LANTERN PER DECK, round-robin. They home, so an origin scattered
        # across the hull distorts no shape - it only makes the brass visibly
        # the thing that lit them.
        gun = live[i % len(live)]
        out.append(dict(
            pos=(gun[0] + d[0] * p["spawnAt"], gun[1] + d[1] * p["spawnAt"]),
            vel=(d[0] * p["speed"], d[1] * p["speed"]),
            radius=p["radius"], lifetime=p["lifetime"],
            homing=math.radians(p["homingDeg"]),
        ))
    return out


# ============================================================ the simulation
#
# `tick()` in ProjectileService, minus the parts a picture cannot use (the
# damage roll, the wire, the cap). t is measured from FIRE - the first frame
# of the strike phase. The tell starts p["windup"] seconds before that.
def ballistic_state(ball, t):
    """A free ball at time t since it was born, or None once retired."""
    age = t - ball.get("born", 0.0)
    if age < 0 or age >= ball["lifetime"]:
        return None
    x = ball["pos"][0] + ball["vel"][0] * age
    z = ball["pos"][1] + ball["vel"][1] * age
    if math.hypot(x, z) > BOUND_R:
        return None
    return (x, z, ball["radius"])


def chain_state(pair, t):
    """A linked pair: the midpoint runs on the lead's velocity while the
    offset spins about it (tick()'s `bullet.link` branch)."""
    if t < 0 or t >= pair["lifetime"]:
        return None
    mx = pair["mid"][0] + pair["vel"][0] * t
    mz = pair["mid"][1] + pair["vel"][1] * t
    a = pair["spin"] * t
    c, s = math.cos(a), math.sin(a)
    ox = pair["off"][0] * c - pair["off"][1] * s
    oz = pair["off"][0] * s + pair["off"][1] * c
    lead = (mx + ox, mz + oz)
    follow = (mx - ox, mz - oz)
    # Retirement reads the LEAD's position against the bound.
    if math.hypot(*lead) > BOUND_R:
        return None
    return (lead, follow, pair["radius"], pair["chainRadius"])


def wisp_tracks(p, base_deg, player_path, dt=1.0 / 120.0):
    """Integrate the homing law exactly as tick() does. `player_path(t)`
    returns the root's (x, z) - homing chases a live root, so the answer
    (orbit something tighter than the turn radius) needs a moving one."""
    wisps = emit_wisps(p, base_deg)
    tracks = []
    for w in wisps:
        pos = list(w["pos"])
        vel = list(w["vel"])
        pts = [tuple(pos)]
        caught_at = None
        t = 0.0
        while t < w["lifetime"]:
            px, pz = player_path(t)
            wx = px - pos[0]
            wz = pz - pos[1]
            wm = math.hypot(wx, wz)
            if wm > 1e-3:
                wx, wz = wx / wm, wz / wm
                vm = math.hypot(vel[0], vel[1])
                hx, hz = vel[0] / vm, vel[1] / vm
                cross = hx * wz - hz * wx
                dot = max(-1.0, min(1.0, hx * wx + hz * wz))
                step = min(math.acos(dot), w["homing"] * dt)
                if cross < 0:
                    step = -step
                c, s = math.cos(step), math.sin(step)
                vel = [vel[0] * c - vel[1] * s, vel[0] * s + vel[1] * c]
            pos[0] += vel[0] * dt
            pos[1] += vel[1] * dt
            t += dt
            pts.append(tuple(pos))
            if math.hypot(pos[0] - px, pos[1] - pz) <= w["radius"] and caught_at is None:
                caught_at = t
            if math.hypot(*pos) > BOUND_R:
                break
        tracks.append(dict(points=pts, caught=caught_at, radius=w["radius"]))
    return tracks


# ---- the live-set builders, one per handler -------------------------------
def live_balls(name, t):
    """Every ball in the air at `t` seconds after FIRE, as
    (x, z, radius) - plus, for chainshot, a separate pair list."""
    p = ATTACKS[name]
    h = p["handler"]
    out, chains = [], []
    if h == "broadside":
        gap0 = GAP0_HEAVY if name == "broadsideHeavy" else GAP0_BROADSIDE
        for v in range(p["volleys"]):
            born = v * p["interval"]
            if t < born:
                continue
            for b in emit_broadside(p, gap0 + v * p["gapStep"]):
                b["born"] = born
                s = ballistic_state(b, t)
                if s:
                    out.append(s)
    elif h == "grapeshot":
        for k in range(p.get("bursts", 1)):
            born = k * p["burstGap"]
            if t < born:
                continue
            for b in emit_grapeshot(p, REF_BEARING, 0.0 if k == 0 else 0.5, target=REF_POS):
                b["born"] = born
                s = ballistic_state(b, t)
                if s:
                    out.append(s)
    elif h == "chainshot":
        for pair in emit_chainshot(p, REF_BEARING, target=REF_POS):
            s = chain_state(pair, t)
            if s:
                chains.append(s)
    elif h == "slewfire":
        every = max(p["every"], 0.05)
        deck = REF_BEARING
        k = 0
        while k * every <= min(t, p["duration"]):
            born = k * every
            for b in emit_slewfire_tick(p, deck + p["spinDeg"] * every * k):
                b["born"] = born
                s = ballistic_state(b, t)
                if s:
                    out.append(s)
            k += 1
    elif h == "anchorsweep":
        for b in emit_anchorsweep(p, REF_BEARING, target=REF_POS):
            b["born"] = 0.0
            s = ballistic_state(b, t)
            if s:
                out.append(s)
    return out, chains


# ============================================================ the escape test
#
# THE HONEST, CONSERVATIVE DODGE TEST. From the tell's first frame the player
# walks one constant heading at 16 studs/s (clamped to the walkable sand) and
# we ask whether any ball's centre ever comes within its own radius of the
# root point - which is exactly ProjectileService's hit test. A heading that
# survives PROVES the pattern is dodgeable from that spot; a heading that
# dies does not prove the reverse, because a real player can turn. So a full
# red rose means "no straight line gets out", which is a strong statement,
# and a green arc means "these ways out are real".
def escape_rose(name, start, headings=72, dt=1.0 / 120.0):
    p = ATTACKS[name]
    windup = p["windup"]
    if p["handler"] == "wisps":
        horizon = windup + p["lifetime"]
    else:
        horizon = windup + p["duration"] + p["lifetime"]
    out = []
    for k in range(headings):
        deg = k * (360.0 / headings)
        d = bearing(deg)
        survived = True
        t = 0.0
        pos = [start[0], start[1]]
        # wisps need their own integration (they chase), so they are handled
        # by rerunning wisp_tracks against this straight-line path.
        if p["handler"] == "wisps":
            def path(tt, d=d):
                x = start[0] + d[0] * PLAYER_SPEED * max(0.0, tt)
                z = start[1] + d[1] * PLAYER_SPEED * max(0.0, tt)
                r = math.hypot(x, z)
                if r > SAND_R:
                    x, z = x * SAND_R / r, z * SAND_R / r
                return (x, z)
            tracks = wisp_tracks(p, REF_BEARING, path, dt=1.0 / 90.0)
            survived = all(tr["caught"] is None for tr in tracks)
            out.append((deg, survived))
            continue
        while t < horizon and survived:
            walked = max(0.0, t)
            pos[0] = start[0] + d[0] * PLAYER_SPEED * walked
            pos[1] = start[1] + d[1] * PLAYER_SPEED * walked
            r = math.hypot(pos[0], pos[1])
            if r > SAND_R:
                pos[0], pos[1] = pos[0] * SAND_R / r, pos[1] * SAND_R / r
            st = t - windup
            if st >= 0:
                balls, chains = live_balls(name, st)
                for (bx, bz, br) in balls:
                    if math.hypot(pos[0] - bx, pos[1] - bz) <= br:
                        survived = False
                        break
                for (lead, follow, br, cr) in chains:
                    if seg_dist(pos, lead, follow) <= cr:
                        survived = False
                        break
                    if min(math.hypot(pos[0] - lead[0], pos[1] - lead[1]),
                           math.hypot(pos[0] - follow[0], pos[1] - follow[1])) <= br:
                        survived = False
                        break
            t += dt
        out.append((deg, survived))
    return out


def seg_dist(pt, a, b):
    """ProjectileService.segDistFlat - the chain capsule's axis distance."""
    abx, abz = b[0] - a[0], b[1] - a[1]
    l2 = abx * abx + abz * abz
    tt = 0.0
    if l2 > 1e-6:
        tt = max(0.0, min(1.0, ((pt[0] - a[0]) * abx + (pt[1] - a[1]) * abz) / l2))
    return math.hypot(pt[0] - (a[0] + abx * tt), pt[1] - (a[1] + abz * tt))


# ============================================================ the two-origin gun check
#
# "they should have to move around the map to shoot all 4, they shouldnt be
# able to shoot through the boss." That is TWO claims about two different rays,
# and running one check for both is how this would silently pass:
#
#   SEE  - from the raised orbit's EYE, 27.3 studs up. Answered by the sponson
#          bulkheads (the hull is too short to occlude from up there).
#   HIT  - from the SHOT origin, 4.5 studs up at the character. Answered by the
#          hull collider AND the bulkheads together.
#
# Same grid, opposite question. A checker that took the eye's answer for the
# shot's would report the fight working while every far gun was shootable
# through the ship, and one that took the shot's answer for the eye's would
# report an occlusion the camera never sees.


def _seg_hits_box(p, q, samples=1200):
    """Does the segment p->q pass through the hull collider? p, q are
    (x, z, height) in boss space, which is world space here (yaw0 = 0)."""
    for i in range(1, samples):
        t = i / samples
        x = p[0] + (q[0] - p[0]) * t
        z = p[1] + (q[1] - p[1]) * t
        h = p[2] + (q[2] - p[2]) * t
        if (COLLIDER_X[0] < x < COLLIDER_X[1]
                and COLLIDER_Z[0] < z < COLLIDER_Z[1]
                and COLLIDER_H[0] < h < COLLIDER_H[1]):
            return True
    return False


# WHAT A SHOT IS ACTUALLY AIMED AT, and the first version of this check had it
# wrong. A gun is not a point: `Creatures.items.wrack_battery.shotRadius` is
# published to both sides and IS the capture both of them use - server-side by
# CreatureService.raycastNearest to decide what a shot hit, client-side by
# RangedController.aimDistance to resolve how far down the cursor ray the
# target is. So a ray that clips the sphere's outboard edge hits the gun even
# when a ray to its centre is stopped by the casemate's own cheek.
#
# Testing the CENTRE ONLY is what produced this file's first disagreement with
# the mesh lane's solver: 26% of bearings with nothing shootable at all,
# against their "never zero". The blind sectors were an artefact of aiming at a
# point that the fight never aims at.
SHOT_RADIUS = 5.0  # wrack_battery.shotRadius under the three-act rework


# ...AND THE CAPTURE IS CLIPPED BY THE HOUSE IT SITS IN. The sphere is r 5 and
# the cheeks are only +-4 apart, so most of it is inside timber: an aim point
# at the full radius sits OUTSIDE the casemate, and a check that used one would
# bypass both cheeks and report every gun visible from every bearing. (It did,
# on the first run: 4 x 144 at the eye.) The reachable capture is the sphere
# INTERSECTED with the casemate's mouth, so the lateral samples are clamped
# just inside the cheeks.
AIM_LATERAL = min(SHOT_RADIUS, CASEMATE_HW - 0.5)


def _aim_points(index):
    """The gun's reachable capture, sampled where it matters: the centre and
    the two lateral extremes that are still inside the casemate. Three points,
    not a sphere sweep - the cheeks bound the arc, and they bound it
    laterally."""
    _label, gx, gz, gh = MOUNTS[index]
    nx, nz = GUN_BEARING[index]
    tx, tz = -nz, nx
    return [
        (gx, gz, gh),
        (gx + tx * AIM_LATERAL, gz + tz * AIM_LATERAL, gh),
        (gx - tx * AIM_LATERAL, gz - tz * AIM_LATERAL, gh),
    ]


def _casemate_blocks(p, index, mouth=None, aim=None):
    """Does gun `index`'s own casemate stop a ray from `p` reaching it?

    Exact, not sampled: three rectangles in the gun's bearing frame, each hit
    by solving for the one coordinate that crosses it. `u` is radius from the
    ship's centre ALONG the gun's bearing (the gun stands at u = GUN_R[index]),
    `v` runs across it, `h` is height above the sand.

      back wall  u = CASEMATE_R_BACK,  |v| <= CASEMATE_HW
      cheeks     v = +-CASEMATE_HW,    CASEMATE_R_BACK <= u <= `mouth`

    The gun sits at v = 0 and u > CASEMATE_R_BACK, so no plate can contain it.
    That is the property the flat bulkhead did not have, and the whole reason
    for the shape.
    """
    if mouth is None:
        mouth = CASEMATE_R_OUT
    _label, gx, gz, gh = MOUNTS[index]
    if aim is None:
        aim = (gx, gz, gh)
    nx, nz = GUN_BEARING[index]
    tx, tz = -nz, nx
    pu, pv, ph = p[0] * nx + p[1] * nz, p[0] * tx + p[1] * tz, p[2]
    gu, gv, gh = aim[0] * nx + aim[1] * nz, aim[0] * tx + aim[1] * tz, aim[2]

    def at(t):
        return (pu + (gu - pu) * t, pv + (gv - pv) * t, ph + (gh - ph) * t)

    # THE BACK WALL.
    if abs(gu - pu) > 1e-9:
        t = (CASEMATE_R_BACK - pu) / (gu - pu)
        if 0.0 < t < 1.0:
            _u, v, h = at(t)
            if abs(v) <= CASEMATE_HW and CASEMATE_Z[0] <= h <= CASEMATE_Z[1]:
                return True
    # THE CHEEKS.
    if abs(gv - pv) > 1e-9:
        for side in (CASEMATE_HW, -CASEMATE_HW):
            t = (side - pv) / (gv - pv)
            if 0.0 < t < 1.0:
                u, _v, h = at(t)
                if CASEMATE_R_BACK <= u <= mouth and CASEMATE_Z[0] <= h <= CASEMATE_Z[1]:
                    return True
    return False


def guns_clear(origin, use_collider=True, use_bulkheads=True, mouth=None):
    """Which guns this origin has an unoccluded line to. `origin` is
    (x, z, height)."""
    clear = []
    for i, (_label, gx, gz, gh) in enumerate(MOUNTS):
        ok = False
        for ax, az, ah in _aim_points(i):
            if use_bulkheads and _casemate_blocks(origin, i, mouth=mouth, aim=(ax, az, ah)):
                continue
            if use_collider and _seg_hits_box(origin, (ax, az, ah)):
                continue
            ok = True
            break
        if ok:
            clear.append(i)
    return clear


def gun_sweep(ring, height, bearings=144, **kw):
    """The visible-gun count at every bearing on a ring: a histogram
    {count: bearings} plus the worst case and the nearest-gun result."""
    hist = {}
    eaten = []
    for k in range(bearings):
        deg = k * 360.0 / bearings
        rad = math.radians(deg)
        p = (math.cos(rad) * ring, math.sin(rad) * ring, height)
        n = len(guns_clear(p, **kw))
        hist[n] = hist.get(n, 0) + 1
        # The other half of the promise: the gun you are STANDING next to must
        # never be eaten by the ship you are standing beside.
        near = min(range(len(MOUNTS)),
                   key=lambda i: (p[0] - MOUNTS[i][1]) ** 2 + (p[1] - MOUNTS[i][2]) ** 2)
        if near not in guns_clear(p, **kw):
            eaten.append((round(deg), MOUNT_LABEL[near]))
    return hist, eaten


# THE TARGET IS TWO-TIERED, and the tiers are not the same promise:
#
#   HARD  what you can HIT, from root+1.5 at both rings: never more than two,
#         and the gun you are standing beside is never eaten. This is the
#         mandate ("they shouldnt be able to shoot through the boss") and a
#         failure here is a broken fight.
#   SOFT  what you can SEE, from the raised orbit's eye: two on most bearings.
#         Three VISIBLE-but-unshootable on the axial bearings is tolerable -
#         seeing a gun you cannot yet hit is a reason to walk, which is the
#         loop the acts are built on.
#
# Written down because the two were one check for one revision of this file,
# and one check for two promises always ends up enforcing the easier one.
def gun_check_lines():
    """The check, per (ring, origin), with the histogram the mesh lane sizes
    its casemates against - and the collider-only column beside it, which is
    the evidence for why the casemates have to exist at all."""
    lines = []
    for ring, ring_label in ((PARTY_R, "drop ring r%.0f" % PARTY_R),
                             (SAND_R, "sand edge r%.0f" % SAND_R)):
        for height, origin_label, collider, tier in (
                (EYE_Y, "eye  %.1f" % EYE_Y, False, "SOFT"),
                (SHOT_Y, "shot %.1f" % SHOT_Y, True, "HARD")):
            bare, _ = gun_sweep(ring, height, use_bulkheads=False, use_collider=True)
            full, eaten = gun_sweep(ring, height, use_collider=collider, use_bulkheads=True)
            total = sum(full.values())
            over = sum(c for n, c in full.items() if n > 2)
            if tier == "HARD":
                ok = over == 0 and not eaten
            else:
                ok = over <= total * 0.25
            lines.append((
                "%-18s %-10s %s %-4s  %s   collider alone: %s"
                % (ring_label, origin_label, "OK  " if ok else "FAIL", tier,
                   " ".join("%dx%d" % (n, c) for n, c in sorted(full.items())),
                   " ".join("%dx%d" % (n, c) for n, c in sorted(bare.items()))),
                eaten))
    return lines


# THE MESH LANE'S PUBLISHED RESULT for the same casemate, same two origins,
# same rings (2026-09-09), from their analytic ray-vs-prism solver. Recorded
# here so the two independent implementations are DIFFED rather than trusted,
# which is the whole reason two of them exist.
MESH_LANE_HIST = {1: 16, 2: 128}
MESH_LANE_NOTE = ("<=2 everywhere, never 0, nearest never eaten, "
                  "3-visible on 0% of bearings")


def casemate_sensitivity():
    """How the shootable histogram moves with the casemate's mouth - the one
    dimension the sight lines can feel. Printed so this lane and the mesh lane
    are comparing a CURVE rather than trading single numbers."""
    rows = []
    for mouth in (21.0, 23.0, 25.0):
        half = math.degrees(math.atan2(CASEMATE_HW, max(mouth - GUN_R_MAX, 1e-6)))
        merged, eaten_n = {}, 0
        for ring in (PARTY_R, SAND_R):
            hist, eaten = gun_sweep(ring, SHOT_Y, use_collider=True, mouth=mouth)
            for n, c in hist.items():
                merged[n] = merged.get(n, 0) + c
            eaten_n += len(eaten)
        rows.append((mouth, half, merged, eaten_n))
    return rows


# ============================================================ derived numbers
def gun_range():
    """How far the reference challenger stands from the gun that fires an
    AIMED pattern. Every width, lane and flight time for those rows is
    measured from here, because that is where the shot leaves."""
    gx, gz = deck_for_aim(REF_BEARING)
    return math.hypot(REF_POS[0] - gx, REF_POS[1] - gz)


def ring_numbers(name):
    """The measurable facts a dodger actually needs, computed not guessed."""
    p = ATTACKS[name]
    h = p["handler"]
    n = {}
    # REACH, and whether the two retirement knobs agree.
    #
    # A ball dies on whichever comes first: `lifetime` seconds, or leaving
    # `bound` studs from the ARENA CENTRE. Those are two knobs for one job, and
    # if they disagree by much one of them is a lie. `reach` is how far a ball
    # gets on its lifetime alone (spawnAt + speed x lifetime); `bound` is
    # BOUND_R. A pattern whose reach falls short of the walkable edge leaves a
    # rest area out there, which is the death of a bullet hell; one whose reach
    # hugely exceeds the bound has an inert lifetime.
    n["reach"] = p["spawnAt"] + p["speed"] * p["lifetime"]
    n["reach_vs_sand"] = n["reach"] - SAND_R
    n["reach_vs_bound"] = n["reach"] - BOUND_R
    n["cross_s"] = (BOUND_R - p["spawnAt"]) / p["speed"]
    if h == "broadside":
        gap = p["gapDeg"]
        # Balls are laid INCLUSIVE of both ends of the occupied arc, so the
        # empty wedge is exactly gapDeg - see PATTERNS.broadside.
        step = (360.0 - gap) / max(p["count"] - 1, 1)
        n["empty_deg"] = gap
        n["step_deg"] = step
        n["gap_studs"] = math.radians(gap) * PARTY_R - 2 * p["radius"]
        n["lane_studs"] = math.radians(step) * PARTY_R - 2 * p["radius"]
        n["solid_to_r"] = 2 * p["radius"] / math.radians(step)
        n["gap_travel"] = math.radians(p["gapStep"]) * PARTY_R
        n["walk_per_volley"] = PLAYER_SPEED * p["interval"]
    elif h == "grapeshot":
        # MEASURED FROM THE GUN, not from the arena centre: the fan leaves one
        # battery, so every width and every flight time is that battery's.
        d = gun_range()
        step = p["fanDeg"] / (p["pellets"] - 1)
        n["gun_range"] = d
        n["step_deg"] = step
        n["lane_studs"] = math.radians(step) * d - 2 * p["radius"]
        n["cone_width"] = 2 * d * math.sin(math.radians(p["fanDeg"]) / 2)
        n["flight_party"] = max(d - p["spawnAt"], 0.0) / p["speed"]
        n["react"] = p["windup"] + n["flight_party"]
        n["walk"] = PLAYER_SPEED * n["react"]
        n["need"] = d * math.tan(math.radians(p["fanDeg"]) / 2) + p["radius"]
    elif h == "chainshot":
        d = gun_range()
        step = p["fanDeg"] / (p["pairs"] - 1)
        n["gun_range"] = d
        n["step_deg"] = step
        n["pair_len"] = p["chain"] + 2 * p["radius"]
        n["lane_studs"] = math.radians(step) * d - n["pair_len"]
        n["turn_s"] = 360.0 / abs(p["spinDeg"])
        n["beat_s"] = 180.0 / abs(p["spinDeg"])
        n["turns"] = n["cross_s"] / n["turn_s"]
    elif h == "slewfire":
        per_tick = abs(p["spinDeg"]) * p["every"]
        n["tick_deg"] = per_tick
        n["arm_gap"] = math.hypot(math.radians(per_tick) * PARTY_R, p["speed"] * p["every"]) - 2 * p["radius"]
        n["channel"] = p["speed"] * (360.0 / abs(p["spinDeg"])) / p["arms"]
        n["sweep_party"] = math.radians(abs(p["spinDeg"])) * PARTY_R
        n["against"] = abs(p["spinDeg"]) + math.degrees(PLAYER_SPEED / PARTY_R)
        n["with"] = abs(p["spinDeg"]) - math.degrees(PLAYER_SPEED / PARTY_R)
        n["ratio"] = n["against"] / n["with"]
        n["live"] = len(live_balls("slewfireFast" if p["arms"] == 3 else "slewfire", p["duration"])[0])
    elif h == "anchorsweep":
        d = gun_range()
        step = p["arcDeg"] / (p["count"] - 1)
        n["gun_range"] = d
        n["step_deg"] = step
        n["lane_studs"] = math.radians(step) * d - 2 * p["radius"]
        n["solid_to_r"] = 2 * p["radius"] / math.radians(step)
        n["head_studs"] = p["ripple"] * (p["count"] - 1) * p["speed"]
        n["head_s"] = p["ripple"] * (p["count"] - 1)
        n["flight_party"] = max(d - p["spawnAt"], 0.0) / p["speed"]
        n["react"] = p["windup"] + n["flight_party"]
        n["walk"] = PLAYER_SPEED * n["react"]
        # WHAT LEAVING ACTUALLY COSTS. A 180-degree arc is a HALF-PLANE whose
        # boundary is the line through the gun perpendicular to the aim, so
        # "get to the other half" means crossing that line - and standing on
        # the axis at range d, the nearest point of it is d studs away. The
        # old figure (90 degrees of arc round the ARENA centre) measured a
        # different journey and, at r 88, an impossible one.
        n["need"] = d
    elif h == "wisps":
        n["turn_r"] = p["speed"] / math.radians(p["homingDeg"])
        n["closing"] = p["speed"] - PLAYER_SPEED
        n["net_close"] = n["closing"] * p["lifetime"]
    return n


# ============================================================ drawing
def setup_plan(ax, span=PLAN_SPAN, ticks=True):
    ax.set_xlim(-span, span)
    ax.set_ylim(-span, span)
    ax.invert_yaxis()  # +Z DOWN: Studio's Top view, so bearings run clockwise
    ax.set_aspect("equal")
    ax.set_facecolor(BG)
    for s in ax.spines.values():
        s.set_visible(False)
    ax.set_xticks([])
    ax.set_yticks([])


def draw_arena(ax, small=False):
    """Everything that is there before a shot is fired.

    Which, on the rebuilt Careenage, is almost nothing: one plain beach out to
    r 132 with no cover of any kind on it, and the palisade of grounded hulls
    standing round the outside of it. The six breakwater hulks that used to sit
    at r 33-52 - and that used to be the wisps' only answer - are gone."""
    ax.add_patch(Circle((0, 0), FOAM_R[1], facecolor=AWASH, edgecolor="none", zorder=0))
    # the palisade: an annulus of grounded hulls with the sea mouth cut out of
    # it. Nothing walks out here; it is the boundary, drawn so the beach reads
    # as enclosed rather than as ending in nothing.
    mouth = math.degrees(math.atan2(*reversed(blender_to_xz(1.0, WK_SEA_DEG))))
    ax.add_patch(Wedge((0, 0), FLEET_R[1], mouth + WK_FLEET_GAP_DEG / 2,
                       mouth - WK_FLEET_GAP_DEG / 2 + 360, width=FLEET_R[1] - FLEET_R[0],
                       facecolor=HULK, edgecolor=HULK_EDGE, lw=0.8, alpha=0.85, zorder=4))
    ax.add_patch(Circle((0, 0), SAND_R, facecolor=SAND, edgecolor=SAND_EDGE, lw=1.1, zorder=1))
    # the retire bound - past here every ball is dropped
    ax.add_patch(Circle((0, 0), BOUND_R, facecolor="none", edgecolor=INK_FAINT,
                        lw=0.9, ls=(0, (5, 4)), zorder=2))
    # the party ring
    ax.add_patch(Circle((0, 0), PARTY_R, facecolor="none", edgecolor="#5e7d86",
                        lw=1.0, ls=(0, (3, 4)), zorder=3))
    if not small:
        ax.text(0, -SAND_R + 4.0, "walkable sand ends — r %g, and nothing stands on it" % SAND_R,
                color=SAND_EDGE, fontsize=7.4, ha="center", va="bottom", zorder=20)
        ax.text(0, -PARTY_R + 3.5, "the party drops here — r %g" % PARTY_R, color="#5e7d86",
                fontsize=7.0, ha="center", va="bottom", zorder=20)

    # the hull footprint: the measured bounding box of the upright ship, bow at
    # +X (see HULL_BBOX for why this is an ellipse and not a station curve).
    ax.add_patch(Ellipse((0, 0), HULL_BBOX[0], HULL_BBOX[1], facecolor=HULL,
                         edgecolor=HULL_EDGE, lw=1.2, zorder=6))

    # the four gun decks
    for label, mx, mz, height in MOUNTS:
        # 3.6 studs across, not the wreck's 5.2: the four cannons are only
        # 10.9-13.5 studs apart now and two 5.2-stud squares would touch.
        ax.add_patch(Rectangle((mx - 1.8, mz - 1.8), 3.6, 3.6, facecolor=BRASS,
                               edgecolor="#3a2a10", lw=0.7, zorder=8))
        if not small:
            ax.text(mx, mz - 3.4, label, color=BRASS, fontsize=6.6, ha="center",
                    va="bottom", zorder=20,
                    bbox=dict(boxstyle="round,pad=0.12", fc=BG, ec="none", alpha=0.75))


def draw_spawn_ring(ax, p, label=True):
    """WHERE THE SHOT IS BORN, drawn as the locus it really is.

    Since 2026-09-06 nothing is born on a circle round the arena centre. A
    RADIAL pattern's muzzle locus is `spawnAt + deck_run_out(dir)` - a ring
    bulging toward each live battery; an AIMED pattern leaves one gun."""
    h = p["handler"]
    if h in ("broadside", "slewfire"):
        angs = np.linspace(0, 360, 721)
        rs = np.array([p["spawnAt"] + deck_run_out(bearing(float(a))) for a in angs])
        ax.plot(np.cos(np.radians(angs)) * rs, np.sin(np.radians(angs)) * rs,
                color=BRASS, lw=1.0, ls=(0, (2, 3)), alpha=0.9, zorder=7)
        note = ("the muzzle locus: r %g in front of whichever\nLIVE battery faces that bearing "
                "— it bulges toward\nthe guns and flattens where one is silenced" % p["spawnAt"])
    else:
        gun = deck_for_aim(REF_BEARING)
        i = MOUNT_XZ.index(gun)
        ax.add_patch(Circle(gun, p["spawnAt"], facecolor="none", edgecolor=BRASS,
                            lw=1.0, ls=(0, (2, 3)), alpha=0.9, zorder=7))
        ax.plot([gun[0]], [gun[1]], marker="*", ms=9, color=BRASS, zorder=22)
        note = ("fired from the %s battery — the live gun best lined\nup with the shot, "
                "re-aimed from where it actually stands\n(%+.0f, %+.0f from the centre, %.1f "
                "studs up)" % (MOUNT_LABEL[i], gun[0], gun[1], MOUNTS[i][3]))
    if label:
        ax.text(0.995, 0.992, note, transform=ax.transAxes, color=BRASS, fontsize=7.6,
                ha="right", va="top", zorder=30)


def draw_balls(ax, balls, colour, alpha=1.0, zorder=14, edge=True):
    for (x, z, r) in balls:
        ax.add_patch(Circle((x, z), r, facecolor=colour, alpha=alpha,
                            edgecolor=BG if edge else "none", lw=0.6, zorder=zorder))


def draw_chains(ax, chains, colour, alpha=1.0, zorder=14):
    for (lead, follow, br, cr) in chains:
        ax.plot([lead[0], follow[0]], [lead[1], follow[1]], color=colour,
                lw=cr * 2 * _lw_per_stud(ax), solid_capstyle="round",
                alpha=alpha * 0.9, zorder=zorder)
        for c in (lead, follow):
            ax.add_patch(Circle(c, br, facecolor=colour, alpha=alpha,
                                edgecolor=BG, lw=0.6, zorder=zorder + 1))


def _lw_per_stud(ax):
    """Points of line width per stud, so the chain is drawn AT ITS HITBOX."""
    bbox = ax.get_window_extent()
    span = ax.get_xlim()[1] - ax.get_xlim()[0]
    return (bbox.width / span) * 72.0 / ax.figure.dpi


def draw_player(ax, pos, label=True, size=1.0):
    ax.add_patch(Circle(pos, PLAYER_DOT_R * size + 0.9, facecolor=BG, edgecolor="none",
                        zorder=25))
    ax.add_patch(Circle(pos, PLAYER_DOT_R * size, facecolor=GHOST, edgecolor=BG,
                        lw=0.8, zorder=26))
    if label:
        ax.text(pos[0], pos[1] + 4.0, "you", color=GHOST, fontsize=7.4,
                ha="center", va="top", zorder=26)


def draw_rose(ax, rose, pos, length=17.0, lw=2.0, zorder=10):
    """The escape rose: one spoke per tested heading, mint = a straight walk
    survives, red = it does not. Drawn UNDER the bullets, so it never hides
    the thing it is a verdict about."""
    ax.add_patch(Circle(pos, length + 1.2, facecolor=BG, alpha=0.55,
                        edgecolor="none", zorder=zorder - 1))
    for deg, ok in rose:
        d = bearing(deg)
        ax.plot([pos[0], pos[0] + d[0] * length], [pos[1], pos[1] + d[1] * length],
                color=GHOST if ok else DANGER, lw=lw if ok else lw * 0.6,
                alpha=0.95 if ok else 0.5, solid_capstyle="butt", zorder=zorder)


def draw_scale_bar(ax, span=PLAN_SPAN):
    y = span * 0.90
    x0 = -span * 0.94
    ax.plot([x0, x0 + 40], [y, y], color=INK_DIM, lw=2.0, solid_capstyle="butt", zorder=30)
    ax.text(x0 + 20, y - 4.5, "40 studs", color=INK_DIM, fontsize=6.8, ha="center",
            va="bottom", zorder=30)


def draw_compass(ax, span=PLAN_SPAN):
    """Bearings in ProjectileService's convention, which on a Top view (+X
    right, +Z down) increase CLOCKWISE."""
    for deg, txt in ((0, "0"), (90, "90"), (180, "180"), (270, "270")):
        d = bearing(deg)
        ax.text(d[0] * span * 0.965, d[1] * span * 0.965, txt + "°", color=INK_FAINT,
                fontsize=6.4, ha="center", va="center", zorder=30)
    ax.add_patch(Arc((0, 0), span * 1.82, span * 1.82, theta1=0, theta2=360,
                     edgecolor="#232c31", lw=0.8, zorder=1))


def wedge(ax, r0, r1, a0, a1, colour, alpha=0.16, hatch=None, zorder=8, lw=0.0,
          at=(0.0, 0.0)):
    """`at` IS THE ORIGIN THE WEDGE IS SWEPT FROM, and for every aimed pattern
    that is the gun, not the arena centre. A cone drawn round the middle of the
    hull for a fan that leaves the bowsprit shades ground the shot never
    crosses - which is the exact lie this whole retune is about. Clipped to the
    walkable sand so a half-plane cannot paint over the palisade."""
    w = Wedge(at, r1, a0, a1, width=r1 - r0, facecolor=colour, alpha=alpha,
              edgecolor=colour if lw else "none", lw=lw, zorder=zorder)
    if hatch:
        w.set_hatch(hatch)
        w.set_edgecolor(colour)
        w.set_linewidth(0.0)
    ax.add_patch(w)
    if at != (0.0, 0.0):
        w.set_clip_path(Circle((0, 0), SAND_R, transform=ax.transData))


def spin_arrow(ax, radius, a0, sweep, colour, label=None, lw=2.2, zorder=24, lift=6.5):
    """A curved arrow at `radius` from bearing a0 through `sweep` degrees
    (positive = the +bearing direction, which is clockwise on this plan)."""
    n = 40
    angs = np.linspace(a0, a0 + sweep, n)
    xs = np.cos(np.radians(angs)) * radius
    zs = np.sin(np.radians(angs)) * radius
    ax.plot(xs, zs, color=colour, lw=lw, zorder=zorder, solid_capstyle="round")
    hx, hz = xs[-1], zs[-1]
    dx, dz = xs[-1] - xs[-4], zs[-1] - zs[-4]
    m = math.hypot(dx, dz) or 1.0
    ax.add_patch(FancyArrow(hx, hz, dx / m * 0.1, dz / m * 0.1, width=0,
                            head_width=4.6, head_length=5.4, length_includes_head=False,
                            facecolor=colour, edgecolor="none", zorder=zorder))
    if label:
        mid = a0 + sweep * 0.5
        ax.text(math.cos(math.radians(mid)) * (radius + lift),
                math.sin(math.radians(mid)) * (radius + lift), label, color=colour,
                fontsize=7.6, ha="center", va="center", zorder=zorder,
                bbox=dict(boxstyle="round,pad=0.2", fc=BG, ec="none", alpha=0.72))


def straight_arrow(ax, p0, p1, colour, lw=2.2, zorder=24, head=5.0):
    dx, dz = p1[0] - p0[0], p1[1] - p0[1]
    ax.add_patch(FancyArrow(p0[0], p0[1], dx, dz, width=lw * 0.5, head_width=head,
                            head_length=head * 1.15, length_includes_head=True,
                            facecolor=colour, edgecolor="none", zorder=zorder))


# ============================================================ the moments
#
# When to draw each pattern. `main` is the decisive frame; `moments` are the
# three small multiples, because a wall of cannonballs is only legible as
# motion. All in seconds after FIRE.
MOMENTS = {
    "broadside": (3.00, (1.00, 2.20, 3.40)),
    "broadsideHeavy": (3.00, (0.90, 2.00, 3.20)),
    "grapeshot": (0.85, (0.30, 0.85, 1.40)),
    "anchorsweep": (2.40, (0.80, 2.40, 4.00)),
    "wisps": (3.00, (1.00, 3.00, 5.20)),
}

# The one-line answer, as the book states it, plus the measured version.
ANSWER = {
    "broadside": "walk to the gap - and keep walking, it steps 46° every volley",
    "broadsideHeavy": "four rings, a gap two thirds as wide moving further and faster",
    "grapeshot": "step out of the cone DURING the tell, not after it",
    "anchorsweep": "you do not thread it, you leave - and the long windup is the walk",
    "wisps": "run a circle tighter than their turn radius — any bare sand will do",
}


def moment_balls(name, t):
    return live_balls(name, t)


# ============================================================ the overlays
def overlay(ax, name, t, small=False):
    """The pattern-specific 'answer', drawn. Returns extra label lines."""
    p = ATTACKS[name]
    h = p["handler"]
    n = ring_numbers(name)
    notes = []

    if h == "broadside":
        gap0 = GAP0_HEAVY if name == "broadsideHeavy" else GAP0_BROADSIDE
        half = n["empty_deg"] / 2.0
        for v in range(p["volleys"]):
            born = v * p["interval"]
            if t < born:
                continue
            r = p["spawnAt"] + p["speed"] * (t - born)
            if r > BOUND_R:
                continue
            g = gap0 + v * p["gapStep"]
            wedge(ax, max(0, r - 10), min(BOUND_R, r + 10), g - half, g + half, GHOST,
                  alpha=0.32, zorder=8)
            if not small:
                d = bearing(g)
                lr = min(r + 26, SAND_R * 1.06)
                ax.text(d[0] * lr, d[1] * lr, "gap %d" % (v + 1), color=GHOST,
                        fontsize=7.4, ha="center", va="center", zorder=24,
                        bbox=dict(boxstyle="round,pad=0.18", fc=BG, ec="none", alpha=0.7))
        if not small:
            spin_arrow(ax, SAND_R * 0.92, gap0, p["gapStep"] * (p["volleys"] - 1), GHOST,
                       label="the gap walks\n+%d° a volley" % p["gapStep"])
        notes = [
            "the empty wedge IS gapDeg: %.0f°, with the balls laid %.1f° apart onto both its edges"
            % (n["empty_deg"], n["step_deg"]),
            "at r %g the gap is %.0f studs clear; between two balls, %.1f"
            % (PARTY_R, n["gap_studs"], n["lane_studs"]),
            "the wall is only SOLID inside r %.0f - past that it has lanes" % n["solid_to_r"],
            "the gap moves %.0f studs per volley at r %g; you can walk %.0f"
            % (n["gap_travel"], PARTY_R, n["walk_per_volley"]),
        ]

    elif h == "grapeshot":
        fan = p["fanDeg"]
        gun = deck_for_aim(REF_BEARING)
        base = aim_from(gun, REF_POS)
        wedge(ax, p["spawnAt"], SAND_R * 2.4, base - fan / 2, base + fan / 2,
              DANGER, alpha=0.10, zorder=8, at=gun)
        if p.get("bursts", 1) > 1:
            step = fan / (p["pellets"] - 1)
            wedge(ax, p["spawnAt"], SAND_R * 2.4, base - fan / 2 + step * 0.5,
                  base + fan / 2 + step * 0.5, DANGER, alpha=0.10, zorder=8, at=gun)
            if not small:
                # THE SHORT EDGE. The half-pellet phase shifts the WHOLE second
                # burst toward +bearing, so the union runs (base - fan/2) to
                # (base + fan/2 + half a step): the -fan/2 edge is the one that
                # is a half-step nearer. Break toward DECREASING bearing.
                rad = bearing(REF_BEARING)
                tang = (rad[1], -rad[0])  # -rot90: the decreasing-bearing side
                straight_arrow(ax, REF_POS,
                               (REF_POS[0] + tang[0] * 30, REF_POS[1] + tang[1] * 30), GHOST)
                ax.text(REF_POS[0] + tang[0] * 40, REF_POS[1] + tang[1] * 40,
                        "the SHORT edge:\nburst 2 stops %.1f°\ninside this side"
                        % (step * 0.5),
                        color=GHOST, fontsize=7.2, ha="center", va="center", zorder=25)
        if not small:
            ax.add_patch(Circle(REF_POS, n["walk"], facecolor="none", edgecolor=GHOST,
                                lw=1.0, ls=(0, (3, 3)), alpha=0.7, zorder=20))
            ax.text(REF_POS[0], REF_POS[1] + n["walk"] + 2.5,
                    "%.1f s of tell + flight = %.0f studs of walk" % (n["react"], n["walk"]),
                    color=GHOST, fontsize=6.8, ha="center", va="top", zorder=25)
        notes = [
            "%d pellets across %g°: %.1f studs between centres at the muzzle, %.1f clear at r %g"
            % (p["pellets"], fan, math.radians(n["step_deg"]) * p["spawnAt"], n["lane_studs"], PARTY_R),
            "the cone is %.0f studs wide where the party stands" % n["cone_width"],
            "%.1f s windup + %.2f s flight = %.0f studs of walk, against %.0f needed to clear it"
            % (p["windup"], n["flight_party"], n["walk"], n["need"]),
        ]

    elif h == "chainshot":
        step = n["step_deg"]
        gun = deck_for_aim(REF_BEARING)
        base = aim_from(gun, REF_POS)
        for i in range(p["pairs"] - 1):
            a = base - p["fanDeg"] / 2 + step * (i + 0.5)
            wedge(ax, p["spawnAt"], SAND_R * 2.4, a - step * 0.30, a + step * 0.30, GHOST,
                  alpha=0.16, zorder=8, at=gun)
            if not small:
                d = bearing(a)
                ax.text(gun[0] + d[0] * SAND_R * 0.72, gun[1] + d[1] * SAND_R * 0.72, "lane",
                        color=GHOST, fontsize=7.2, ha="center", va="center", zorder=24)
        if not small:
            # THE TRAP, called out on the pair furthest from the label margin:
            # the 12-stud hole between a pair's two balls is filled by the
            # chain, so it reads as a lane and is the hitbox.
            st = chain_state(emit_chainshot(p, REF_BEARING)[1], t)
            if st:
                lead, follow, br, cr = st
                mid = ((lead[0] + follow[0]) / 2, (lead[1] + follow[1]) / 2)
                tip = (-SAND_R * 0.52, SAND_R * 0.98)
                ax.plot([mid[0], tip[0]], [mid[1], tip[1]], color=DANGER,
                        lw=0.9, alpha=0.85, zorder=25)
                ax.text(tip[0] - 3, tip[1] + 3,
                        "the %g-stud hole inside a pair is NOT a lane —\nthe chain fills it, "
                        "and the chain is the hitbox\n(a capsule of radius %.1f, drawn at "
                        "that width)" % (p["chain"], cr),
                        color=DANGER, fontsize=7.6, ha="center", va="top", zorder=26,
                        bbox=dict(boxstyle="round,pad=0.25", fc=BG, ec="none", alpha=0.78))
        notes = [
            "%d pairs %.1f° apart; each pair is %.0f studs end to end, %.1f wide at the chain"
            % (p["pairs"], step, n["pair_len"], p["chainRadius"] * 2),
            "the lane between pairs is %.0f studs clear at r %g" % (n["lane_studs"], PARTY_R),
            "spin %g°/s: a full turn every %.2f s, end-on every %.2f s"
            % (p["spinDeg"], n["turn_s"], n["beat_s"]),
            "it crosses the beach in %.1f s - %.1f turns of the chain" % (n["cross_s"], n["turns"]),
        ]

    elif h == "slewfire":
        deck = REF_BEARING + p["spinDeg"] * min(t, p["duration"])
        sweep = 62.0 if p["spinDeg"] > 0 else -62.0
        # The spiral each arm lays down, drawn as its own locus so the two (or
        # three) arms are unmistakable: an arm laid down at deck angle a is at
        # radius spawnAt + speed*(t - (deck - a)/spin).
        every = max(p["every"], 0.05)
        for i in range(p["arms"]):
            xs, zs = [], []
            k = 0
            while k * every <= min(t, p["duration"]):
                age = t - k * every
                a = REF_BEARING + p["spinDeg"] * every * k + (360.0 / p["arms"]) * i
                d = bearing(a)
                # Born at the deck facing that bearing, exactly as the balls
                # are - so the locus and the balls cannot drift apart.
                r = p["spawnAt"] + deck_run_out(d) + p["speed"] * age
                if age < p["lifetime"] and r <= BOUND_R:
                    xs.append(d[0] * r)
                    zs.append(d[1] * r)
                k += 1
            ax.plot(xs, zs, color=SKIN["cannon"], lw=1.0, alpha=0.30, zorder=9)
        if not small:
            spin_arrow(ax, SAND_R * 1.05, deck - sweep * 0.15, sweep, DANGER,
                       label="the deck spins\n%+g°/s" % p["spinDeg"])
            # the answer: cross the arm walking the other way round
            a = math.degrees(math.atan2(REF_POS[1], REF_POS[0]))
            spin_arrow(ax, PARTY_R, a, -sweep * 0.40, GHOST, lift=26,
                       label="walk AGAINST it:\ncross %.2fx faster" % n["ratio"])
        notes = [
            "%d arm%s, one tick every %g s: the deck steps %.1f° a tick"
            % (p["arms"], "" if p["arms"] == 1 else "s", p["every"], n["tick_deg"]),
            "%.0f studs of open water between arms; %.1f stud holes along one arm at r %g"
            % (n["channel"], n["arm_gap"], PARTY_R),
            "an arm crosses r %g at %.0f studs/s - you cannot outrun it, only cross it"
            % (PARTY_R, n["sweep_party"]),
            "walking against the spin crosses %.2fx faster (%.0f°/s vs %.0f°/s relative)"
            % (n["ratio"], n["against"], n["with"]),
        ]

    elif h == "anchorsweep":
        gun = deck_for_aim(REF_BEARING)
        base = aim_from(gun, REF_POS)
        # The half-planes really are half-planes THROUGH THE GUN: the boundary
        # the player has to cross runs through the battery, not through the
        # middle of the arena, and at 40 studs of offset that is the whole
        # difference between an escape that works and one that does not.
        wedge(ax, p["spawnAt"], SAND_R * 2.4, base - 90, base + 90, DANGER,
              alpha=0.12, zorder=8, at=gun)
        wedge(ax, 0.0, SAND_R * 2.4, base + 90, base + 270, GHOST,
              alpha=0.12, zorder=8, at=gun)
        if not small:
            d = bearing(REF_BEARING + 180)
            ax.text(d[0] * SAND_R * 0.62, d[1] * SAND_R * 0.62, "THE OTHER HALF", color=GHOST, fontsize=10.0,
                    ha="center", va="center", zorder=24, fontweight="bold")
            # The trailing end is i = count-1, at base + arc/2: `head` is
            # ripple*(count-1-i)*speed, so that end is the one born at spawnAt
            # with no head start at all.
            e = bearing(REF_BEARING + 90)
            ax.text(e[0] * SAND_R * 0.80, e[1] * SAND_R * 0.80 - 26,
                    "trailing end: born %.1f studs\nfurther in, so it arrives\n%.1f s after the "
                    "leading end" % (n["head_studs"], n["head_s"]),
                    color=GHOST, fontsize=7.2, ha="center", va="center", zorder=25)
            rad = bearing(REF_BEARING)
            tang = (-rad[1], rad[0])  # +rot90: toward base + 90, the trailing end
            straight_arrow(ax, REF_POS,
                           (REF_POS[0] + tang[0] * 30, REF_POS[1] + tang[1] * 30), GHOST)
            f = bearing(REF_BEARING - 90)
            ax.text(f[0] * SAND_R * 0.80, f[1] * SAND_R * 0.80 - 24,
                    "leading end: %.1f studs\nof head start" % n["head_studs"],
                    color=DANGER, fontsize=7.2, ha="center", va="center", zorder=25)
        notes = [
            "%d anchors across %g°, radius %g - the biggest ball in the fight"
            % (p["count"], p["arcDeg"], p["radius"]),
            "solid only inside r %.0f; at r %g there are %.1f stud slots between them"
            % (n["solid_to_r"], PARTY_R, n["lane_studs"]),
            "%.1f s windup + %.2f s flight = %.0f studs of walk, against the %.0f that leaves "
            "the half-plane" % (p["windup"], n["flight_party"], n["walk"], n["need"]),
            "the OTHER answer is the trailing end: it arrives %.1f s late, and is passable for "
            "that beat if you commit" % n["head_s"],
        ]

    elif h == "wisps":
        place, orb = wisp_answer()
        notes = [
            "speed %g vs a %g stud/s walk: they close %g studs/s and live %g s"
            % (p["speed"], PLAYER_SPEED, n["closing"], p["lifetime"]),
            "turn rate %g°/s at speed %g = a %.1f STUD TURN RADIUS - a circle they cannot fly inside"
            % (p["homingDeg"], p["speed"], n["turn_r"]),
            "searched, not asserted: an r %g circle ON BARE SAND is the orbit all %d miss for the whole %g s"
            % (orb, p["count"], p["lifetime"]),
            "TIGHTER IS NOT BETTER - under ~5 studs you stop covering ground and the head-on one lands",
            "damage %d-%d - they barely hurt; they take standing still off the table" % p["damage"],
        ]

    return notes


def draw_pattern(ax, name, t, small=False, rose=None, show_overlay=True):
    p = ATTACKS[name]
    colour = SKIN[p["skin"]]
    draw_arena(ax, small=small)
    draw_spawn_ring(ax, p, label=not small)
    notes = overlay(ax, name, t, small=small) if show_overlay else []

    here = REF_POS
    if p["handler"] == "wisps":
        here = draw_wisps(ax, p, t, small=small)
    else:
        balls, chains = live_balls(name, t)
        draw_balls(ax, balls, colour)
        draw_chains(ax, chains, colour)

    if rose is not None:
        # Scaled to the plan: on a 152-stud half-span a 17-stud rose is a
        # speck, and the rose is the verdict the whole diagram is about.
        reach = PLAN_SPAN * (0.15 if p["handler"] == "wisps" else 0.19)
        draw_rose(ax, rose, REF_POS, length=reach if not small else reach * 0.8,
                  lw=1.4 if small else 2.2)
    if here is not REF_POS:
        # the start is where the rose was measured from; say so
        ax.add_patch(Circle(REF_POS, 2.0, facecolor="none", edgecolor=GHOST, lw=1.0,
                            alpha=0.7, zorder=25))
    draw_player(ax, here, label=not small)
    if not small:
        draw_scale_bar(ax)
        draw_compass(ax)
    return notes


_WISP_ANSWER = {}


def wisp_answer():
    """THE ANSWER, SEARCHED RATHER THAN ASSERTED - AND ON OPEN GROUND.

    The old answer was "orbit a breakwater hulk tighter than their turn
    radius". The hulks are gone and the floor is plain, so the answer has to
    be one the sand itself supports. It is, and it always was: the obstacle
    was never load-bearing. A player has NO turn radius - a Humanoid changes
    heading instantly - while a wisp at speed `s` turning `homingDeg`/s cannot
    fly a circle tighter than s / rad(homingDeg). Any circle the player runs
    inside that radius is a circle the wisp physically cannot hold, so it
    overshoots, swings wide, and comes back to overshoot again. No hulk is
    needed to make that true; a patch of empty sand is enough.

    Searched, not asserted, because tighter is NOT monotonically better: below
    about 5 studs the orbit stops covering ground and the wisp that is already
    head-on simply arrives. So sweep orbit radius 4 - 16 studs against four
    placements of the circle relative to the player, integrate the real homing
    law, and take the MIDDLE of the widest band that survives - a knife-edge
    radius is not an answer a player can execute. Deterministic: fixed grid,
    no rng.

    Returns (orbit centre bearing offset in degrees, orbit radius).
    """
    if _WISP_ANSWER:
        return _WISP_ANSWER["v"]
    p = ATTACKS["wisps"]
    radii = [4.0 + 0.5 * i for i in range(25)]
    # Where the circle sits relative to the player, as a bearing offset from
    # "directly away from the boss". Outward first, so a tie prefers the
    # circle that keeps the most sand between the player and the guns.
    placements = [0.0, 90.0, -90.0, 180.0]
    best = None
    for place in placements:
        ok = [all(t["caught"] is None for t in wisp_tracks(p, REF_BEARING, orbit_path(place, r)[0]))
              for r in radii]
        run, start = 0, None
        for i, good in enumerate(ok + [False]):
            if good:
                run += 1
                start = i - run + 1 if run == 1 else start
            else:
                if run >= 3 and (best is None or run > best[2]):
                    best = (place, radii[start + run // 2], run)
                run = 0
    if best is None:  # nothing survives - say so rather than draw a lie
        _WISP_ANSWER["v"] = (None, 9.0)
    else:
        _WISP_ANSWER["v"] = (best[0], best[1])
    return _WISP_ANSWER["v"]


def orbit_path(place_deg=0.0, orbit_r=8.5):
    """The wisp answer, as a path: from where you stand, run a circle of
    radius `orbit_r` on bare sand - tighter than anything a wisp can fly. The
    circle's centre is `orbit_r` studs from the player along the arena's
    outward radial, rotated by `place_deg`, so the player is ON the circle at
    t = 0 and there is no approach walk to get wrong."""
    sx, sz = REF_POS
    out = math.degrees(math.atan2(sz, sx)) + place_deg
    d = bearing(out)
    cx, cz = sx + d[0] * orbit_r, sz + d[1] * orbit_r
    omega = PLAYER_SPEED / orbit_r
    a0 = math.atan2(sz - cz, sx - cx)

    def path(t):
        a = a0 + omega * max(0.0, t)
        return (cx + math.cos(a) * orbit_r, cz + math.sin(a) * orbit_r)

    return path, (cx, cz), orbit_r


def draw_wisps(ax, p, t, small=False):
    place, orb = wisp_answer()
    path, hulk, orbit_r = orbit_path(place if place is not None else 0.0, orb)
    tracks = wisp_tracks(p, REF_BEARING, path)
    here = path(min(t, p["lifetime"]))
    colour = SKIN["wisp"]
    n = ring_numbers("wisps")
    # the wisp tracks first, so the player's answer draws on top of them
    for tr in tracks:
        pts = np.array(tr["points"])
        k = min(len(pts) - 1, int(t * 120))
        ax.plot(pts[:k + 1, 0], pts[:k + 1, 1], color=colour, lw=1.6, alpha=0.75,
                ls=(0, (5, 3)), zorder=12)
        # the halo that makes a wisp a wisp at a glance
        ax.add_patch(Circle(pts[k], tr["radius"] * 2.6, facecolor=colour, alpha=0.16,
                            edgecolor="none", zorder=13))
        ax.add_patch(Circle(pts[k], tr["radius"], facecolor=colour, edgecolor=BG,
                            lw=0.6, zorder=14))
    # the player's own path: a circle on bare sand, tighter than anything a
    # wisp can fly
    ts = np.linspace(0, min(t, p["lifetime"]), 400)
    pts = np.array([path(float(x)) for x in ts])
    ax.plot(pts[:, 0], pts[:, 1], color=GHOST, lw=2.0, alpha=0.95, zorder=18)
    if not small:
        ax.add_patch(Circle(hulk, orbit_r, facecolor="none", edgecolor=GHOST, lw=0.9,
                            ls=(0, (2, 3)), alpha=0.65, zorder=17))
        # the turn circle, drawn off the leading wisp: the tightest arc it can
        # fly, and the whole reason a tighter orbit beats it
        head = np.array(tracks[0]["points"])[min(len(tracks[0]["points"]) - 1, int(t * 120))]
        vel = head - np.array(tracks[0]["points"])[max(0, int(t * 120) - 3)]
        m = math.hypot(*vel) or 1.0
        nx, nz = -vel[1] / m, vel[0] / m
        cc = (head[0] + nx * n["turn_r"], head[1] + nz * n["turn_r"])
        ax.add_patch(Circle(cc, n["turn_r"], facecolor="none", edgecolor=colour, lw=1.2,
                            ls=(0, (4, 4)), alpha=0.85, zorder=18))
        ax.text(cc[0], cc[1] + n["turn_r"] + 3,
                "a wisp's tightest possible turn: r %.1f" % n["turn_r"],
                color=colour, fontsize=7.6, ha="center", va="top", zorder=24,
                bbox=dict(boxstyle="round,pad=0.2", fc=BG, ec="none", alpha=0.72))
        ax.text(hulk[0] - 22, hulk[1] + 22,
                "your orbit: r %g on BARE SAND.\nNo hulk, no cover — a player has no\nturn "
                "radius and a wisp has one, and\nthat asymmetry is the whole answer.\nInside r "
                "%.1f, so all %d overshoot for\nthe full %g s"
                % (orbit_r, n["turn_r"], ATTACKS["wisps"]["count"], ATTACKS["wisps"]["lifetime"]),
                color=GHOST, fontsize=7.6, ha="right", va="center", zorder=24,
                bbox=dict(boxstyle="round,pad=0.2", fc=BG, ec="none", alpha=0.72))
    return here


# ============================================================ the figures
def info_lines(name, rose):
    p = ATTACKS[name]
    n = ring_numbers(name)
    live = len(live_balls(name, MOMENTS[name][0])[0])
    chains = len(live_balls(name, MOMENTS[name][0])[1])
    if chains:
        live = chains * 2
    ok = sum(1 for _, s in rose if s)
    lines = []
    lines.append(("head", "WHAT THE NUMBERS SAY"))
    for note in overlay_notes_cache[name]:
        lines.append(("note", note))
    lines.append(("gap", ""))
    lines.append(("head", "THE ROW  (Bosses.luau)"))
    row = ["windup %.2g s  ·  strike %.2g s  ·  recover %.2g s  ·  cooldown %g s"
           % (p["windup"], p["duration"], p["recover"], p["cooldown"]),
           "skin \"%s\"  ·  ball radius %g  ·  speed %g studs/s  ·  damage %d-%d"
           % (p["skin"], p["radius"], p["speed"], p["damage"][0], p["damage"][1])]
    if p["handler"] == "broadside":
        row.append("count %d  ·  gapDeg %g  ·  gapStep %g  ·  volleys %d every %g s"
                   % (p["count"], p["gapDeg"], p["gapStep"], p["volleys"], p["interval"]))
    elif p["handler"] == "grapeshot":
        row.append("pellets %d  ·  fanDeg %g  ·  bursts %d, %g s apart, offset half a pellet"
                   % (p["pellets"], p["fanDeg"], p.get("bursts", 1), p["burstGap"]))
    elif p["handler"] == "chainshot":
        row.append("pairs %d  ·  fanDeg %g  ·  chain %g (hitbox r %g)  ·  spin %g°/s"
                   % (p["pairs"], p["fanDeg"], p["chain"], p["chainRadius"], p["spinDeg"]))
    elif p["handler"] == "slewfire":
        row.append("arms %d  ·  a tick every %g s  ·  spin %+g°/s"
                   % (p["arms"], p["every"], p["spinDeg"]))
    elif p["handler"] == "anchorsweep":
        row.append("count %d  ·  arcDeg %g  ·  ripple %g (the arc's own head start)"
                   % (p["count"], p["arcDeg"], p["ripple"]))
    elif p["handler"] == "wisps":
        row.append("count %d  ·  homingDeg %g  ·  lifetime %g s  ·  spread %g°"
                   % (p["count"], p["homingDeg"], p["lifetime"], p["spreadDeg"]))
    for r in row:
        lines.append(("row", r))
    lines.append(("gap", ""))
    lines.append(("head", "THE ESCAPE ROSE  (drawn at the player dot)"))
    if p["handler"] == "wisps":
        lines.append(("note", "%d of %d straight-line headings survive — they home, so walking "
                              "in a line only postpones it" % (ok, len(rose))))
        lines.append(("note", "The mint curve is the answer instead: a turn tighter than "
                              "anything they can fly"))
    else:
        lines.append(("note", "%d of %d constant headings at %g studs/s survive the whole "
                              "pattern from r %g" % (ok, len(rose), PLAYER_SPEED, PARTY_R)))
        lines.append(("note", "Simulated against the real hit test — the ball's own radius "
                              "against the root point"))
    lines.append(("gap", ""))
    lines.append(("head", "AND THE GUN DECKS SCALE IT"))
    # EVERY pattern, now including slewfire: PATTERNS.slewfire used to read
    # `math.max(1, p.arms)` raw and was the single row that did not thin,
    # contradicting CreatureService's own header. Fixed 2026-09-06.
    key = ("arms" if p["handler"] == "slewfire" else
           "count" if "count" in p else "pellets" if "pellets" in p else "pairs")
    counts = ["%d" % count_of(p[key], 0.4 + 0.6 * (a / 4.0)) for a in (4, 3, 2, 1)]
    lines.append(("note", "%s: %s with 4 / 3 / 2 / 1 gun decks standing (countOf, "
                          "scale 0.4 + 0.6 x alive/4)" % (key, " → ".join(counts))))
    lines.append(("note", "and the shot leaves the DECKS that are left, so silencing one "
                          "moves where the fire comes from"))
    lines.append(("note", "all four down: %g s of true silence, then a skeleton crew at "
                          "%g%% density — the burst window" % (4.0, 30)))
    return lines


overlay_notes_cache = {}


def build_notes_cache():
    fig = plt.figure(figsize=(4, 4))
    ax = fig.add_axes([0, 0, 1, 1])
    setup_plan(ax)
    for name in ORDER:
        overlay_notes_cache[name] = overlay(ax, name, MOMENTS[name][0], small=True)
        ax.clear()
        setup_plan(ax)
    plt.close(fig)


def render_pattern(name, out_dir):
    p = ATTACKS[name]
    main_t, moments = MOMENTS[name]
    rose = escape_rose(name, REF_POS)

    fig = plt.figure(figsize=(15.4, 8.7), dpi=150)
    colour = SKIN[p["skin"]]

    fig.text(0.026, 0.975, name, color=colour, fontsize=27, fontweight="bold",
             ha="left", va="top")
    fig.text(0.026, 0.930, "Admiral Wrack  ·  act %d  ·  handler \"%s\"  ·  skin \"%s\""
             % (ACT_OF.get(name, 0), p["handler"], p["skin"]),
             color=INK_DIM, fontsize=9.5, ha="left", va="top")
    fig.text(0.975, 0.975, ANSWER[name], color=GHOST, fontsize=14.0, ha="right", va="top",
             style="italic")
    fig.text(0.975, 0.936, "The Careenage, plan view · +X right, +Z down (Studio Top view) "
                           "· bearings increase clockwise",
             color=INK_FAINT, fontsize=8.4, ha="right", va="top")

    ax = fig.add_axes([0.012, 0.025, 0.500, 0.885])
    setup_plan(ax)
    draw_pattern(ax, name, main_t, rose=rose)
    ax.text(-PLAN_SPAN * 0.99, -PLAN_SPAN * 0.99, "t = %.2f s after the guns fire" % main_t, color=INK,
            fontsize=11.0, ha="left", va="top")

    # the annotation column
    axi = fig.add_axes([0.530, 0.408, 0.455, 0.492])
    axi.axis("off")
    y = 1.0
    for kind, text in info_lines(name, rose):
        if kind == "gap":
            y -= 0.040
            continue
        if kind == "head":
            axi.text(0.0, y, text, color=INK_FAINT, fontsize=8.6, ha="left", va="top",
                     fontweight="bold")
            y -= 0.062
        elif kind == "row":
            axi.text(0.0, y, text, color=INK_DIM, fontsize=8.8, ha="left", va="top")
            y -= 0.058
        else:
            axi.text(0.0, y, "•  " + text, color=INK, fontsize=9.2, ha="left", va="top")
            y -= 0.060
    axi.set_xlim(0, 1)
    axi.set_ylim(0, 1)

    # three moments, so the motion reads
    for i, mt in enumerate(moments):
        axm = fig.add_axes([0.530 + i * 0.157, 0.070, 0.148, 0.256])
        setup_plan(axm)
        draw_pattern(axm, name, mt, small=True, rose=None, show_overlay=True)
        axm.text(0, PLAN_SPAN * 1.01, "t = %.2f s" % mt, color=INK_DIM, fontsize=8.6, ha="center",
                 va="top")

    fig.text(0.530, 0.362, "THE SAME MOVE, THREE MOMENTS", color=INK_FAINT, fontsize=8.6,
             ha="left", va="top", fontweight="bold")
    fig.text(0.975, 0.008,
             "assets/wrack_patterns_gen.py — geometry ported from ProjectileService.luau, "
             "numbers from Bosses.luau. The floor is plain: nothing on it occludes a shot, "
             "and nothing on it is cover.",
             color=INK_FAINT, fontsize=7.6, ha="right", va="bottom")

    path = os.path.join(out_dir, "wrack_pattern_%s.png" % name)
    fig.savefig(path, dpi=150)
    plt.close(fig)
    return path


def render_sheet(out_dir):
    W, H = 15.4, 20.4
    fig = plt.figure(figsize=(W, H), dpi=140)
    fig.text(0.030, 0.993, "Admiral Wrack, the Fleet-Eater — nine attack patterns",
             color=INK, fontsize=28, fontweight="bold", ha="left", va="top")
    fig.text(0.030, 0.972,
             "The Careenage as rebuilt, plan view, everything to scale. Sand walkable to r %g "
             "and EMPTY — no cover anywhere on it; the party is dropped on r %g; the palisade "
             "rings it at r %g-%g;\nthe four gun decks are the brass, and every ball in the "
             "fight leaves one. Mint is the answer. The mint/red rose at the player dot is every "
             "constant heading a\n%g stud/s walk could take from the tell's first frame — mint "
             "survives the whole pattern, red does not."
             % (SAND_R, PARTY_R, FLEET_R[0], FLEET_R[1], PLAYER_SPEED),
             color=INK_DIM, fontsize=10.6, ha="left", va="top")

    # the legend strip
    ly = 0.9445
    lx = 0.030
    for skin in ("cannon", "grape", "chain", "wisp", "anchor"):
        fig.patches.append(plt.Circle((lx, ly), 0.0046, transform=fig.transFigure,
                                      facecolor=SKIN[skin], edgecolor=BG, lw=0.8))
        fig.text(lx + 0.010, ly, SKIN_LABEL[skin], color=INK, fontsize=10.0,
                 ha="left", va="center")
        lx += 0.070
    fig.patches.append(plt.Circle((lx, ly), 0.0046, transform=fig.transFigure,
                                  facecolor=GHOST, edgecolor=BG, lw=0.8))
    fig.text(lx + 0.010, ly, "you / the answer", color=INK, fontsize=10.0,
             ha="left", va="center")
    lx += 0.112
    fig.patches.append(plt.Rectangle((lx - 0.005, ly - 0.0035), 0.010, 0.007,
                                     transform=fig.transFigure, facecolor=BRASS))
    fig.text(lx + 0.010, ly, "gun deck — shoot these, and every ball in the fight leaves one",
             color=INK, fontsize=10.0, ha="left", va="center")

    # rows: title, square tile, two caption lines. Laid out explicitly so the
    # captions of one row can never land on the titles of the next.
    tile_w = 0.288
    tile_h = tile_w * W / H
    col_pitch = 0.315
    row_pitch = 0.300
    for idx, name in enumerate(ORDER):
        row, col = divmod(idx, 3)
        x0 = 0.030 + col * col_pitch
        row_top = 0.925 - row * row_pitch
        y0 = row_top - 0.020 - tile_h
        ax = fig.add_axes([x0, y0, tile_w, tile_h])
        setup_plan(ax)
        rose = escape_rose(name, REF_POS, headings=36)
        draw_pattern(ax, name, MOMENTS[name][0], small=True, rose=rose)
        p = ATTACKS[name]
        fig.text(x0, row_top, name, color=SKIN[p["skin"]], fontsize=16,
                 fontweight="bold", ha="left", va="top")
        fig.text(x0 + tile_w, row_top, "act %d" % ACT_OF.get(name, 0),
                 color=INK_FAINT, fontsize=9.5, ha="right", va="top")
        fig.text(x0, y0 - 0.008, ANSWER[name], color=GHOST, fontsize=9.6,
                 ha="left", va="top")
        fig.text(x0, y0 - 0.026, "\n".join(textwrap.wrap(overlay_notes_cache[name][0], 62)),
                 color=INK_DIM, fontsize=8.4, ha="left", va="top", linespacing=1.35)

    fig.text(0.030, 0.014,
             "Generated by assets/wrack_patterns_gen.py from Bosses.luau + ProjectileService.luau + "
             "CreatureService.luau + arena_gen.py. Nothing here is authored by hand; broadside's gap\n"
             "bearing is seeded (it is random in the fight) so the render reproduces exactly. Ball "
             "counts are with all four gun decks alive: EVERY pattern scales its count by\n"
             "0.4 + 0.6 x (decks alive / 4) — slewfire included, since 2026-09-06 — and every "
             "pattern stops dead for %g s when the last deck falls. The floor is empty, so "
             "nothing\nanywhere in the arena stops a shot: every answer below is a walk." % 4.0,
             color=INK_FAINT, fontsize=8.8, ha="left", va="bottom")

    path = os.path.join(out_dir, "wrack_patterns_sheet.png")
    fig.savefig(path, dpi=140)
    plt.close(fig)
    return path


# ============================================================ the five new verbs
#
# Transcribed from the new rows in `Bosses.items.admiral_wrack.attacks` the
# same way `ATTACKS` above is, and printed rather than drawn (see the module
# docstring for why). `derive` is where the number the DESIGN is actually
# about gets computed from the row - the fuse budget, the march, the jam - so
# that a retune which breaks the intent shows up here instead of only in play.
NEW_MECHANICS = {
    "powderrun": dict(
        row=dict(windup=1.0, duration=0.5, recover=0.6, cooldown=12.0,
                 count=1, fuse=8.0, speed=18, spawnAt=28, blast=15,
                 blastFuse=20, chainAt=12, damage=(58, 80), hp=900),
        verb="SHOOT THE CHASER - and where you shoot it is the move",
        derive=lambda r: [
            ("closing speed", "%.0f studs/s (keg %g - walk %g)" % (r["speed"] - PLAYER_SPEED,
                                                                  r["speed"], PLAYER_SPEED)),
            ("fuse reach", "%.0f studs of closing over %g s" % ((r["speed"] - PLAYER_SPEED) * r["fuse"],
                                                               r["fuse"])),
            ("lands short of you by", "%g studs (lobbed, not rolled)" % r["spawnAt"]),
            ("a perfect runner ends the fuse", "%.0f studs away - inside blastFuse %g, so RUNNING LOSES"
             % (r["spawnAt"] - (r["speed"] - PLAYER_SPEED) * r["fuse"], r["blastFuse"])),
            ("if it were born at its gun", "%.0f studs out, %.0f s to arrive - IGNORABLE"
             % (PARTY_R - GUN_R_MAX,
                (PARTY_R - GUN_R_MAX) / max(r["speed"] - PLAYER_SPEED, 1e-6))),
            ("safe kill range", "beyond %g studs (blast %g), so a shot on landing is free"
             % (r["blast"], r["blast"])),
        ],
    ),
    "powderrunTwin": dict(
        row=dict(windup=0.9, duration=0.5, recover=0.6, cooldown=13.0,
                 count=2, fuse=7.0, speed=18, spawnAt=28, blast=15,
                 blastFuse=20, chainAt=12, damage=(60, 84), hp=900),
        verb="phase 3: two kegs, two bearings, and they set each other off",
        derive=lambda r: [
            ("a perfect runner ends the fuse", "%.0f studs away (blastFuse %g)"
             % (r["spawnAt"] - (r["speed"] - PLAYER_SPEED) * r["fuse"], r["blastFuse"])),
            ("chain radius", "%g studs - kill them apart" % r["chainAt"]),
        ],
    ),
    "ghostbraziers": dict(
        row=dict(windup=1.2, duration=6.8, recover=0.9, cooldown=22.0,
                 count=3, ring=70, charge=6.0, safeDeg=100, behindAt=8,
                 damage=(72, 96), hp=1400),
        verb="SHOOT THE PILLAR - each one doused opens the sector behind it",
        derive=lambda r: [
            ("pillars", "%d on r %g, %.0f deg apart" % (r["count"], r["ring"], 360.0 / r["count"])),
            ("safe arc at the ring", "%.0f studs" % (math.radians(r["safeDeg"]) * r["ring"])),
            ("safe arc at the drop ring", "%.0f studs" % (math.radians(r["safeDeg"]) * PARTY_R)),
            ("walk to a sector edge", "%.0f studs, %.1f s at %g studs/s"
             % (math.radians(180.0 / r["count"]) * PARTY_R,
                math.radians(180.0 / r["count"]) * PARTY_R / PLAYER_SPEED, PLAYER_SPEED)),
            ("douse budget", "%d hp in %g s = %.0f dps per pillar" % (r["hp"], r["charge"],
                                                                     r["hp"] / r["charge"])),
            ("douse nothing", "the wave takes the whole floor - r %g" % BOUND_R),
        ],
    ),
    "cannonoverload": dict(
        row=dict(windup=3.0, duration=0.6, recover=0.9, cooldown=20.0,
                 jam=0.15, bonus=0.10, markAt=5, speed=22, radius=7,
                 spawnAt=20, lifetime=5.4, damage=(70, 92),
                 burst=dict(count=16, speed=34, radius=2.6, spawnAt=3, lifetime=2.4, mult=0.6)),
        verb="SHOOT THE GUN THAT IS WINDING UP - 15% of its bar jams it",
        derive=lambda r: [
            ("jam threshold", "%.0f damage in %g s = %.0f dps" % (r["jam"] * BATTERY_HP, r["windup"],
                                                                 r["jam"] * BATTERY_HP / r["windup"])),
            ("jam bonus", "%.0f damage (%.0f%% of the battery)" % (r["bonus"] * BATTERY_HP,
                                                                  r["bonus"] * 100)),
            ("mega-shot reach", "%.0f studs (bound %g)" % (r["spawnAt"] + r["speed"] * r["lifetime"],
                                                           BOUND_R)),
            ("time to cross the beach", "%.1f s at %g studs/s" % (SAND_R / r["speed"], r["speed"])),
            ("burst solid to", "r %.0f (16 balls of r %g)"
             % (2 * r["burst"]["radius"] / math.radians(360.0 / r["burst"]["count"]),
                r["burst"]["radius"])),
            ("marker vs mount spacing", "%g studs against %.1f - it names ONE gun"
             % (r["markAt"], MOUNT_MIN_GAP)),
        ],
    ),
    "anchorline": dict(
        row=dict(windup=1.6, duration=4.6, recover=0.8, cooldown=17.0,
                 overshoot=25, drag=4.2, stopAt=18, chain=34, chainRadius=4.0,
                 radius=3.0, lifetime=4.2, damage=(56, 74), hp=700),
        verb="LEAVE BY ITS END, or break the midlink and it dies that frame",
        derive=lambda r: [
            ("lands at", "r %.0f from a player on the drop ring" % min(PARTY_R + r["overshoot"],
                                                                      BOUND_R - 8)),
            ("drag speed", "%.1f studs/s (span %.0f over %g s)"
             % ((min(PARTY_R + r["overshoot"], BOUND_R - 8) - r["stopAt"]) / r["drag"],
                min(PARTY_R + r["overshoot"], BOUND_R - 8) - r["stopAt"], r["drag"])),
            ("walk to clear its end", "%.0f studs, %.1f s" % (r["chain"] / 2 + r["chainRadius"],
                                                              (r["chain"] / 2 + r["chainRadius"]) / PLAYER_SPEED)),
            ("lifetime vs drag", "%g / %g - MUST match" % (r["lifetime"], r["drag"])),
            ("snap budget", "%d hp inside %g s = %.0f dps" % (r["hp"], r["drag"], r["hp"] / r["drag"])),
        ],
    ),
    # ---------------------------------------------------------------- the
    # SHIP'S OWN THREE (2026-09-09). The five above are things the Admiral puts
    # on the sand; these take a piece of the hull and swing it.
    #
    # ON THE ESCAPE ROSE, since two of the three ARE walking problems and the
    # note under this table says none of them is. The judgement, per mechanic:
    #
    #   ladybelow  NOT rose-able, and not by omission. The rose walks a player
    #              72 ways against a hazard whose geometry is fixed; the Lady
    #              RE-LATCHES between passes, so a spoke that "escapes" pass one
    #              is simply where pass two is drawn. The honest instrument is
    #              the sideways clearance against the lead, which is derived
    #              below and is exact.
    #   boomsweep  rose-able in principle - it is a rotating line over a fixed
    #              band - and deliberately NOT rosed anyway, because the answer
    #              has a closed form. Whether a walk escapes is one comparison
    #              (radial distance to the band's edge against the time before
    #              the spar arrives) and one more that settles the tangential
    #              case for every radius at once. A 72-spoke sample of an exact
    #              answer is a worse instrument than the answer, and it would
    #              read as evidence rather than as arithmetic.
    #   bilgeblow  same shape: three radials from fixed points, so "can I get
    #              out of this column" is a step off a line whose width is
    #              authored. Derived below.
    "ladybelow": dict(
        row=dict(windup=1.1, duration=8.4, recover=0.9, cooldown=19.0,
                 dives=2, lead=1.1, rearm=1.1, redock=0.8, speed=54,
                 approach=56, pastBy=56, lane=12, fly=7,
                 damage=(62, 84), hp=900),
        verb="SHOOT HER and she is off the board a dive early - or step off the lane",
        derive=lambda r: [
            ("pass length", "%g studs (%g short + %g past), crossing you at its middle"
             % (r["approach"] + r["pastBy"], r["approach"], r["pastBy"])),
            ("a pass takes", "%.1f s at %g studs/s" % ((r["approach"] + r["pastBy"]) / r["speed"],
                                                       r["speed"])),
            ("sideways clearance", "%g studs to leave a %g-wide lane, %.2f s at %g studs/s"
             % (r["lane"] / 2, r["lane"], (r["lane"] / 2) / PLAYER_SPEED, PLAYER_SPEED)),
            ("...against a lead of", "%g s - the dodge costs %.0f%% of the warning"
             % (r["lead"], 100.0 * ((r["lane"] / 2) / PLAYER_SPEED) / r["lead"])),
            ("whole flight", "%.1f s = %d x (lead %g + pass %.1f + re-arm %g) - lead + redock %g"
             % (r["dives"] * (r["lead"] + (r["approach"] + r["pastBy"]) / r["speed"] + r["rearm"])
                - r["lead"] + r["redock"], r["dives"], r["lead"],
                (r["approach"] + r["pastBy"]) / r["speed"], r["rearm"], r["redock"])),
            ("...against the row's duration", "%g s - MUST cover it, or finish despawns her mid-air"
             % r["duration"]),
            ("end her a dive early", "%d hp inside the first %.1f s = %.0f dps"
             % (r["hp"],
                (r["dives"] - 1) * (r["lead"] + (r["approach"] + r["pastBy"]) / r["speed"] + r["rearm"]),
                r["hp"] / ((r["dives"] - 1) * (r["lead"] + (r["approach"] + r["pastBy"]) / r["speed"]
                                              + r["rearm"])))),
            ("eating every pass", "%d-%d damage over the move" % (r["dives"] * r["damage"][0],
                                                                  r["dives"] * r["damage"][1])),
        ],
    ),
    "boomsweep": dict(
        row=dict(windup=2.2, duration=3.2, recover=1.0, cooldown=21.0,
                 arc=140, sweep=3.0, inner=24, outer=34, width=10,
                 boomLen=30, tackleFly=6, damage=(66, 88), hp=700),
        verb="THERE IS NO TANGENTIAL ESCAPE - leave radially, or drop the spar",
        derive=lambda r: [
            ("sweep rate", "%g deg over %g s = %.1f deg/s" % (r["arc"], r["sweep"],
                                                              r["arc"] / r["sweep"])),
            ("tip speed at the band's edge", "%.1f studs/s at r %g - vs a %g-stud walk: NO ESCAPE"
             % (math.radians(r["arc"] / r["sweep"]) * r["outer"], r["outer"], PLAYER_SPEED)),
            ("...and at the band's inner edge", "%.1f studs/s at r %g - still losing"
             % (math.radians(r["arc"] / r["sweep"]) * r["inner"], r["inner"])),
            ("radial escape from mid-band", "%.0f studs, %.2f s at %g studs/s"
             % ((r["outer"] - r["inner"]) / 2, ((r["outer"] - r["inner"]) / 2) / PLAYER_SPEED,
                PLAYER_SPEED)),
            ("...against the warning", "windup %g s + half the sweep %.1f s = %.1f s"
             % (r["windup"], r["sweep"] / 2, r["windup"] + r["sweep"] / 2)),
            ("band vs the hull box", "r %g-%g against a hull %g x %g (half-length %g)"
             % (r["inner"], r["outer"], HULL_BBOX[0], HULL_BBOX[1], HULL_BBOX[0] / 2)),
            ("spar width", "%g studs PERPENDICULAR - the same at every radius, not a wedge"
             % r["width"]),
            ("drop budget", "%d hp inside windup + sweep %.1f s = %.0f dps"
             % (r["hp"], r["windup"] + r["sweep"], r["hp"] / (r["windup"] + r["sweep"]))),
            ("reach vs the guns", "outer %g against mounts at %.1f-%.1f - it sweeps PAST the brass"
             % (r["outer"], GUN_R_MIN, GUN_R_MAX)),
        ],
    ),
    "bilgeblow": dict(
        row=dict(windup=1.3, duration=4.6, recover=0.9, cooldown=24.0,
                 hatches=3, hatchGap=0.9, steps=6, spacing=9, startAt=26,
                 interval=0.30, arm=0.85, radius=7, damage=(46, 62)),
        verb="NOTHING TO SHOOT - the ground between the hull and the drop ring, taken away",
        derive=lambda r: [
            ("a column runs", "r %g to r %g (%d steps, %g apart)"
             % (r["startAt"], r["startAt"] + (r["steps"] - 1) * r["spacing"], r["steps"],
                r["spacing"])),
            ("...against the drop ring", "r %g - it stops %g studs short, so the rim is the answer"
             % (PARTY_R, PARTY_R - (r["startAt"] + (r["steps"] - 1) * r["spacing"]))),
            ("column speed outward", "%.0f studs/s (%g studs every %g s) - outrunning it LOSES"
             % (r["spacing"] / r["interval"], r["spacing"], r["interval"])),
            ("step off the radial", "%g studs, %.2f s at %g studs/s - inside the %g arm window"
             % (r["radius"], r["radius"] / PLAYER_SPEED, PLAYER_SPEED, r["arm"])),
            ("last eruption lands", "%.2f s after the first hatch pops"
             % ((r["hatches"] - 1) * r["hatchGap"] + r["arm"] + (r["steps"] - 1) * r["interval"])),
            ("...against the row's duration", "%g s - the LIDS shut with finish, so this must fit"
             % r["duration"]),
            ("discs on the floor", "%d of r %g, in %d lines" % (r["hatches"] * r["steps"],
                                                                r["radius"], r["hatches"])),
        ],
    ),
    "longboat": dict(
        row=dict(windup=1.4, duration=0.6, recover=0.8, cooldown=26.0,
                 count=3, beachAt=46, spread=11, speed=9.5, reach=20,
                 march=26, repair=0.25, hp=1300),
        verb="STOP THE ONES RUNNING THE OTHER WAY - each arrival repairs a gun",
        derive=lambda r: [
            ("beach at", "r %.0f" % (PARTY_R - 8 + r["beachAt"])),
            ("march", "%.0f studs at %g studs/s = %.1f s"
             % (PARTY_R - 8 + r["beachAt"] - r["reach"], r["speed"],
                (PARTY_R - 8 + r["beachAt"] - r["reach"]) / r["speed"])),
            ("kill budget", "%d hp in %.1f s = %.0f dps"
             % (r["count"] * r["hp"], (PARTY_R - 8 + r["beachAt"] - r["reach"]) / r["speed"],
                r["count"] * r["hp"] / ((PARTY_R - 8 + r["beachAt"] - r["reach"]) / r["speed"]))),
            ("cost of letting them through", "%.0f hp per boarder, %.0f for all %d"
             % (r["repair"] * BATTERY_HP, r["count"] * r["repair"] * BATTERY_HP, r["count"])),
            ("reach vs the hull", "%g studs against mounts at %.1f-%.1f" % (r["reach"], GUN_R_MIN, GUN_R_MAX)),
        ],
    ),
}


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
    os.makedirs(out_dir, exist_ok=True)
    build_notes_cache()
    written = []
    for name in ORDER:
        written.append(render_pattern(name, out_dir))
        print("wrote %s" % written[-1])
    written.append(render_sheet(out_dir))
    print("wrote %s" % written[-1])

    # The handoff: the numbers the pictures are drawn from, printed so they
    # can be diffed against the Luau without opening an image viewer.
    # BY ACT, because a rose is only meaningful beside the other rows that can
    # be live with it. Sorting these five by act is what makes it visible that
    # act 1 is a two-row walking problem and act 2 is a four-row one.
    print("")
    for act in (1, 2):
        for name in ORDER:
            if ACT_OF.get(name) != act:
                continue
            p = ATTACKS[name]
            n = ring_numbers(name)
            rose = escape_rose(name, REF_POS)
            ok = sum(1 for _, s in rose if s)
            print("HANDOFF act %d %-15s live at t=%.2f: %3d balls  ·  escape rose %2d/72  ·  %s"
                  % (act, name, MOMENTS[name][0], len(live_balls(name, MOMENTS[name][0])[0])
                     + 2 * len(live_balls(name, MOMENTS[name][0])[1]), ok,
                     "; ".join("%s %.1f" % (k, v) for k, v in sorted(n.items()))))
    unplaced = [name for name in ORDER if name not in ACT_OF]
    if unplaced:
        print("HANDOFF  WARNING: drawn rows in no act's phase list: %s"
              % ", ".join(unplaced))

    # ...and the five that are not drawn. Not an escape rose - none of these is
    # a walking problem - but the numbers the design is actually about, so a
    # retune that breaks the intent is visible in a diff of this output.
    print("")
    print("HANDOFF  the four cannons: r %.1f-%.1f, closest pair %.1f studs apart, "
          "%.1f-%.1f studs up" % (GUN_R_MIN, GUN_R_MAX, MOUNT_MIN_GAP,
                                  min(h for _, _, _, h in MOUNTS),
                                  max(h for _, _, _, h in MOUNTS)))
    print("HANDOFF  %s" % ", ".join(
        "%s at %.0f deg" % (label, math.degrees(math.atan2(mz, mx)) % 360.0)
        for label, mx, mz, _h in MOUNTS))

    # ---- the three acts ---------------------------------------------------
    print("")
    print("HANDOFF  THE THREE ACTS - %d hp total, party mult rides all three"
          % sum(ACT_HP.values()))
    print("        act 1 THE GUNS   %6d = 4 x %d, PERMANENT (no regrow); "
          "hull immune + occluder" % (ACT_HP[1], BATTERY_HP))
    print("        act 2 THE SHIP   %6d  hull vulnerable and now the emitter; "
          "cracks open every 20%%" % ACT_HP[2])
    print("        act 3 THE DUEL   %6d  wrack_admiral, mobile, melee AND guns"
          % ACT_HP[3])
    print("        transitions are EVENTS: 4th permanent gun kill, then hull zero")

    # The synthetic dial, printed as the table it will be authored as, so a
    # band that stops being monotonic is visible in a diff of this output.
    print("")
    print("HANDOFF  actFraction dial (Fn.bossPhaseFraction; acts 1-2 share one creature)")
    for alive in ACT_ONE_STEPS:
        print("        act 1  %d gun%s alive -> dial %.2f   emitter scale %.2f"
              % (alive, " " if alive == 1 else "s", 0.60 + 0.40 * (alive / 4.0),
                 (0.4 + 0.6 * (alive / 4.0)) if alive else 0.0))
    for frac in (1.0, 0.66, 0.33, 0.0):
        print("        act 2  hull %3.0f%%      -> dial %.2f"
              % (frac * 100, 0.60 * frac))

    # The two-class cap, checked rather than asserted in a comment.
    print("")
    print("HANDOFF  the phase table, and the two-class cap")
    for act, below, rows in ACT_PHASES:
        classes = sorted({CLASS_OF[r] for r in rows})
        print("        act %d  below %.2f  %s  [%s]  %s"
              % (act, below, "OK  " if len(classes) <= 2 else "FAIL",
                 "".join(classes), ", ".join(rows)))
    for below, rows in DUEL_PHASES:
        classes = sorted({CLASS_OF[r] for r in rows})
        print("        act 3  below %.2f  %s  [%s]  %s"
              % (below, "OK  " if len(classes) <= 2 else "FAIL",
                 "".join(classes), ", ".join(rows)))

    # ---- the gun check ----------------------------------------------------
    print("")
    print("HANDOFF  CAN YOU SEE / HIT ALL FOUR AT ONCE?  (must never be 4, "
          "and the answer is two different rays)")
    for line, eaten in gun_check_lines():
        print("        %s" % line)
        if eaten:
            print("        %-18s NEAREST GUN EATEN BY THE COLLIDER at %s"
                  % ("", ", ".join("%s@%ddeg" % (lab, d) for d, lab in eaten[:6])))
    print("        The hull collider ALONE leaks - the sponsons stand at |z| 9.5 and it")
    print("        is only |z| %.1f, so an axial ray crosses her near face OUTSIDE the"
          % COLLIDER_Z[1])
    print("        hull and runs down her side. The casemate plates are therefore")
    print("        COLLIDABLE geometry, folded into Wrack_HullCollider - so the clone")
    print("        is still exactly ONE object and there are no per-sponson colliders.")
    print("        THE FALLBACK BOX (pack absent) CANNOT REPRODUCE CHEEKS and leaks 3+")
    print("        on the axial bearings. Acceptable until the pack imports, not after.")

    # The cliff. Printed as a curve rather than a number, because the number is
    # what two lanes trade and the curve is what either of them can check.
    print("")
    print("HANDOFF  casemate: back r %.1f, half-width %.1f, cheeks out to r %.1f, z %.1f-%.1f"
          % (CASEMATE_R_BACK, CASEMATE_HW, CASEMATE_R_OUT, CASEMATE_Z[0], CASEMATE_Z[1]))
    print("        acceptance half-angle at the gun: %.1f deg" % CASEMATE_HALF_DEG)
    print("        CHEEK PROJECTION IS THE KNIFE EDGE - the other two dimensions are a")
    print("        plateau, this one fails BOTH ways within two studs:")
    for mouth, half, hist, eaten_n in casemate_sensitivity():
        note = ""
        if any(n > 2 for n in hist):
            note = "  LEAKS the far gun"
        elif eaten_n or 0 in hist:
            note = "  EATS its own gun"
        print("        cheeks to r %-5.1f (half-angle %4.1f deg)  shootable %s%s"
              % (mouth, half, " ".join("%dx%d" % (n, c) for n, c in sorted(hist.items())),
                 note))
    # THE TWO MODELS DO NOT AGREE, AND THAT IS THE RESULT.
    print("")
    print("HANDOFF  RECONCILIATION WITH THE MESH LANE - THEY DISAGREE, DO NOT SHIP YET")
    print("        mesh lane (ray-vs-prism solver): %s  - %s"
          % (" ".join("%dx%d" % (n, c) for n, c in sorted(MESH_LANE_HIST.items())),
             MESH_LANE_NOTE))
    _here, _eaten = gun_sweep(SAND_R, SHOT_Y, use_collider=True)
    print("        this file (segment-vs-plate):    %s  - %d bearings with NOTHING"
          % (" ".join("%dx%d" % (n, c) for n, c in sorted(_here.items())),
             _here.get(0, 0)))
    print("        The disagreement LOCALISES: it is entirely on the BROADSIDE")
    print("        bearings. No gun is authored within 45 deg of +-90, and cheeks out")
    print("        to r %.1f give an acceptance half-angle of %.1f deg, so this model"
          % (CASEMATE_R_OUT, CASEMATE_HALF_DEG))
    print("        finds nothing shootable abeam. Reaching their 'never 0' needs a")
    print("        half-angle >= 60 deg, i.e. cheeks out to r %.1f - which is the very"
          % (GUN_R_MAX + CASEMATE_HW / math.tan(math.radians(60.0))))
    print("        projection they measured as LEAKING. Their curve is knife-edged with")
    print("        a window at 23; this one is monotone with no window at all.")
    print("        ONE OF THE TWO MODELS IS WRONG. Tuning this one until it agreed")
    print("        would be fitting, not checking, so it is left as it reads.")
    print("        Next instrument: their solver and this one run against the SAME")
    print("        explicit plate rectangles, or playtest pass 1 stood abeam.")

    print("")
    print("        CAVEAT, INHERITED FROM BOTH LANES: these are analytic ray-vs-prism")
    print("        results, not Roblox's raycaster, and the hull prism slightly")
    print("        over-occludes at the section corners. This says the shape CAN work;")
    print("        it does not say it ships correct. There is no headless Workspace to")
    print("        call the real Raycast against, so the confirming instrument is")
    print("        playtest pass 1 - stand at the axial bearings and try the far gun.")
    for name, spec in NEW_MECHANICS.items():
        r = spec["row"]
        print("")
        print("HANDOFF %-15s %s" % (name, spec["verb"]))
        print("        %-26s windup %.1f · strike %.1f · recover %.1f · cooldown %.1f"
              % ("", r["windup"], r["duration"], r["recover"], r["cooldown"]))
        for label, value in spec["derive"](r):
            print("        %-26s %s" % (label, value))


if __name__ == "__main__":
    main()
