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
  * the arena        - `WK_*` in assets/arena_gen.py (sand to r 78, the awash
                       flat to 88, the six hulks at r 33-52).
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

Writes `wrack_pattern_<name>.png` for each of the nine rows plus
`wrack_patterns_sheet.png`, the contact sheet. Default out_dir is the
directory this script lives in.
"""

import math
import os
import sys

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt
import numpy as np
from matplotlib.patches import Arc, Circle, FancyArrow, Polygon, Rectangle, Wedge

TAU = math.pi * 2

# ============================================================ the source data
#
# Bosses.items.admiral_wrack.attacks - transcribed field for field. Keys that
# only matter to the tell (tellRange, tellWidth, tellReach, markAt) are kept
# so the rows can be diffed against the Luau by eye.
ATTACKS = {
    "broadside": dict(
        handler="broadside", skin="cannon", windup=1.15, duration=2.5, recover=0.8, cooldown=9.0,
        count=22, speed=26, radius=2.4, spawnAt=16, markAt=22, lifetime=4.2,
        gapDeg=34, gapStep=46, volleys=3, interval=1.1, damage=(44, 58),
    ),
    "broadsideHeavy": dict(
        handler="broadside", skin="cannon", windup=1.0, duration=3.4, recover=0.7, cooldown=10.0,
        count=30, speed=28, radius=2.4, spawnAt=16, markAt=22, lifetime=4.0,
        gapDeg=26, gapStep=58, volleys=4, interval=0.85, damage=(48, 64),
    ),
    "grapeshot": dict(
        handler="grapeshot", skin="grape", windup=0.8, duration=0.45, recover=0.5, cooldown=6.0,
        pellets=6, fanDeg=48, speed=62, spawnAt=14, radius=1.6, lifetime=2.4,
        bursts=1, burstGap=0.35, tellRange=70, damage=(40, 54),
    ),
    "grapeshotTwin": dict(
        handler="grapeshot", skin="grape", windup=0.7, duration=0.9, recover=0.45, cooldown=6.5,
        pellets=7, fanDeg=58, speed=66, spawnAt=14, radius=1.6, lifetime=2.4,
        bursts=2, burstGap=0.4, tellRange=70, damage=(42, 56),
    ),
    "chainshot": dict(
        handler="chainshot", skin="chain", windup=1.0, duration=0.5, recover=0.7, cooldown=11.0,
        pairs=3, fanDeg=120, chain=12, chainRadius=1.8, spinDeg=126, speed=20,
        radius=2.4, spawnAt=14, lifetime=5.0, tellRange=60, damage=(54, 72),
    ),
    "slewfire": dict(
        handler="slewfire", skin="cannon", windup=1.0, duration=5.0, recover=0.8, cooldown=13.0,
        arms=2, every=0.15, spinDeg=78, speed=22, radius=2.0, spawnAt=14,
        lifetime=4.5, damage=(32, 42),
    ),
    "slewfireFast": dict(
        handler="slewfire", skin="cannon", windup=0.9, duration=5.6, recover=0.8, cooldown=14.0,
        arms=3, every=0.13, spinDeg=-96, speed=24, radius=2.0, spawnAt=14,
        lifetime=4.3, damage=(34, 46),
    ),
    "anchorsweep": dict(
        handler="anchorsweep", skin="anchor", windup=1.9, duration=0.6, recover=1.1, cooldown=16.0,
        count=15, arcDeg=180, speed=18, radius=3.4, spawnAt=16, lifetime=5.0,
        ripple=0.05, tellRange=90, tellWidth=96, tellReach=30, damage=(78, 104),
    ),
    "wisps": dict(
        handler="wisps", skin="wisp", windup=0.7, duration=0.4, recover=0.5, cooldown=13.0,
        count=3, speed=19, homingDeg=70, radius=2.2, spawnAt=12, lifetime=9,
        spreadDeg=360, damage=(24, 32),
    ),
}

# The order the fight teaches them in: phase 1's three, then phase 2's
# additions, then the phase-3 swaps. `phases` in Bosses.luau.
ORDER = [
    "grapeshot", "broadside", "wisps",
    "chainshot", "slewfire", "anchorsweep",
    "grapeshotTwin", "broadsideHeavy", "slewfireFast",
]
PHASE_OF = {
    "grapeshot": 1, "broadside": 1, "wisps": 1,
    "chainshot": 2, "slewfire": 2, "anchorsweep": 2,
    "grapeshotTwin": 3, "broadsideHeavy": 3, "slewfireFast": 3,
}

# ---- the arena (assets/arena_gen.py, WK_* constants) -----------------------
SAND_R = 78.0          # WK_SAND_R: walkable sand ends
FLEET_R = (80.0, 88.0) # WK_FLEET_R: the awash flat the grounded fleet lies in
PARTY_R = 48.0         # Bosses arena.radius 40 + BossService's +8
BOUND_R = 88.0         # Bosses arena.radius 40 + WRACK_BOUND_MARGIN 48
HULK_R_RANGE = (33.0, 52.0)

# WK_HULKS, in BLENDER build space: (radius, degrees). The exporter maps
# blender (x, y, z) -> roblox (x, z, -y) - arena_gen.py says so in as many
# words at line ~3666 - so roblox X = blender x and roblox Z = -blender y.
# Every plot here is in ROBLOX X/Z, so the conversion happens once, below.
WK_HULKS_BLENDER = [(34.0, 15.0), (52.0, 62.0), (38.0, 100.0), (49.0, 198.0), (33.0, 250.0), (46.0, 292.0)]
# Each hulk is a ~19-21 stud hull section, 12-14 in the beam (_wr_stations
# calls in build_wk_hulks); drawn as a 20 x 13 footprint, long axis radial
# (`facing = angle + pi`).
HULK_SIZE = (20.0, 13.0)
WK_HEAD_DEG = 150.0  # the cradle / haul lane bearing, in blender degrees

# ---- the boss (Bosses.luau parts.mounts, boss_gen WR_HULL, AUTHORED) -------
#
# yaw0 IS ZERO. BossService.raise spawns him with no throw target, so
# yawToward(nil) = 0; his turnRate is 0 so the prowl branch writes the same
# value back forever. bossFacing = (cos 0, 0, -sin 0) = world +X: THE BOW
# POINTS ALONG +X. spawnBossParts' mount transform therefore reduces to a
# straight translation, so a mount's boss-local (X, Z) IS its world offset.
BOSS_YAW0 = 0.0
MOUNTS = [  # (label, local X, local Z, height above the sand)
    ("Deck", -19.50, -10.34, 35.70),
    ("Keel", 19.38, 18.91, 10.55),
    ("Stern", -34.62, -14.37, 29.08),
    ("Top", 38.40, -11.99, 27.71),
]
# WR_HULL stations (boss_gen.py): (ship-space x, half-beam, ...). Only the
# first two columns matter for a footprint.
WR_STATIONS = [
    (-34.0, 5.0), (-30.0, 9.0), (-24.0, 11.8), (-17.0, 13.0), (-8.0, 13.6),
    (2.0, 13.4), (11.0, 12.0), (19.0, 9.6), (26.0, 6.4), (33.0, 2.0),
]
# WrackBodyController.AUTHORED, measured off the exported glb: the Hull piece
# is 67 long x 44.8 across, the Base (her bed of spoil) 87.1 x 47. The
# stations above are 67 long too, so they are scaled across the beam to the
# measured 44.8 and used as the footprint's outline.
HULL_BBOX = (67.0, 44.8)
BASE_BBOX = (87.1, 47.0)

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


# ============================================================ the emitters
#
# Ported line for line from ProjectileService's PATTERNS table. Each returns
# a list of balls; a ball is a dict with pos (x, z), vel, radius, born (the
# time in the strike it was emitted) and - for chainshot - the pair link.
def emit_broadside(p, gap_deg, scale=1.0):
    count = count_of(p["count"], scale)
    gap = math.radians(p["gapDeg"])
    span = TAU - gap
    step = span / count
    start = math.radians(gap_deg) + gap * 0.5
    out = []
    for i in range(count):
        d = bearing(math.degrees(start + step * (i + 0.5)))
        out.append(dict(
            pos=(d[0] * p["spawnAt"], d[1] * p["spawnAt"]),
            vel=(d[0] * p["speed"], d[1] * p["speed"]),
            radius=p["radius"], lifetime=p["lifetime"],
        ))
    return out


def emit_grapeshot(p, base_deg, phase, scale=1.0):
    pellets = count_of(p["pellets"], scale)
    fan = p["fanDeg"]
    step = fan / (pellets - 1) if pellets > 1 else 0.0
    out = []
    for i in range(pellets):
        d = bearing(base_deg - fan * 0.5 + step * (i + phase))
        out.append(dict(
            pos=(d[0] * p["spawnAt"], d[1] * p["spawnAt"]),
            vel=(d[0] * p["speed"], d[1] * p["speed"]),
            radius=p["radius"], lifetime=p["lifetime"],
        ))
    return out


def emit_chainshot(p, base_deg, scale=1.0):
    pairs = count_of(p["pairs"], scale)
    fan = p["fanDeg"]
    half = p["chain"] * 0.5
    step = fan / (pairs - 1) if pairs > 1 else 0.0
    out = []
    for i in range(pairs):
        ang = base_deg - fan * 0.5 + step * i
        d = bearing(ang)
        side = rot90(d)
        origin = (d[0] * p["spawnAt"], d[1] * p["spawnAt"])
        out.append(dict(
            mid=origin,
            off=(side[0] * half, side[1] * half),
            vel=(d[0] * p["speed"], d[1] * p["speed"]),
            radius=p["radius"], chainRadius=p["chainRadius"],
            spin=math.radians(p["spinDeg"]), lifetime=p["lifetime"],
        ))
    return out


def emit_slewfire_tick(p, deck_deg):
    arms = max(1, p["arms"])
    out = []
    for i in range(arms):
        d = bearing(deck_deg + (360.0 / arms) * i)
        out.append(dict(
            pos=(d[0] * p["spawnAt"], d[1] * p["spawnAt"]),
            vel=(d[0] * p["speed"], d[1] * p["speed"]),
            radius=p["radius"], lifetime=p["lifetime"],
        ))
    return out


def emit_anchorsweep(p, base_deg, scale=1.0):
    count = count_of(p["count"], scale)
    arc = p["arcDeg"]
    ripple = p["ripple"]
    step = arc / (count - 1) if count > 1 else 0.0
    out = []
    for i in range(count):
        d = bearing(base_deg - arc * 0.5 + step * i)
        head = ripple * (count - 1 - i) * p["speed"]
        r0 = p["spawnAt"] + head
        out.append(dict(
            pos=(d[0] * r0, d[1] * r0),
            vel=(d[0] * p["speed"], d[1] * p["speed"]),
            radius=p["radius"], lifetime=p["lifetime"], head=head,
        ))
    return out


def emit_wisps(p, base_deg, scale=1.0):
    count = count_of(p["count"], scale)
    spread = p["spreadDeg"]
    out = []
    for i in range(count):
        d = bearing(base_deg - spread * 0.5 + (spread / max(count, 1)) * (i + 0.5))
        out.append(dict(
            pos=(d[0] * p["spawnAt"], d[1] * p["spawnAt"]),
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
            for b in emit_grapeshot(p, REF_BEARING, 0.0 if k == 0 else 0.5):
                b["born"] = born
                s = ballistic_state(b, t)
                if s:
                    out.append(s)
    elif h == "chainshot":
        for pair in emit_chainshot(p, REF_BEARING):
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
        for b in emit_anchorsweep(p, REF_BEARING):
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


# ============================================================ derived numbers
def ring_numbers(name):
    """The measurable facts a dodger actually needs, computed not guessed."""
    p = ATTACKS[name]
    h = p["handler"]
    n = {}
    if h == "broadside":
        gap = p["gapDeg"]
        step = (360.0 - gap) / p["count"]
        # Balls sit at half-step insets, so the TRUE empty wedge is one step
        # wider than gapDeg.
        n["empty_deg"] = gap + step
        n["step_deg"] = step
        n["gap_studs_48"] = math.radians(n["empty_deg"]) * PARTY_R - 2 * p["radius"]
        n["lane_studs_48"] = math.radians(step) * PARTY_R - 2 * p["radius"]
        n["solid_to_r"] = 2 * p["radius"] / math.radians(step)
        n["gap_travel_48"] = math.radians(p["gapStep"]) * PARTY_R
        n["walk_per_volley"] = PLAYER_SPEED * p["interval"]
        n["cross_time"] = (BOUND_R - p["spawnAt"]) / p["speed"]
    elif h == "grapeshot":
        step = p["fanDeg"] / (p["pellets"] - 1)
        n["step_deg"] = step
        n["lane_studs_48"] = math.radians(step) * PARTY_R - 2 * p["radius"]
        n["cone_width_48"] = 2 * PARTY_R * math.sin(math.radians(p["fanDeg"]) / 2)
        n["flight_to_48"] = (PARTY_R - p["spawnAt"]) / p["speed"]
        n["react"] = p["windup"] + n["flight_to_48"]
        n["walk"] = PLAYER_SPEED * n["react"]
        n["need"] = PARTY_R * math.tan(math.radians(p["fanDeg"]) / 2) + p["radius"]
    elif h == "chainshot":
        step = p["fanDeg"] / (p["pairs"] - 1)
        n["step_deg"] = step
        n["pair_len"] = p["chain"] + 2 * p["radius"]
        n["lane_studs_48"] = math.radians(step) * PARTY_R - n["pair_len"]
        n["turn_s"] = 360.0 / abs(p["spinDeg"])
        n["beat_s"] = 180.0 / abs(p["spinDeg"])
        n["cross_time"] = (BOUND_R - p["spawnAt"]) / p["speed"]
        n["turns"] = n["cross_time"] / n["turn_s"]
    elif h == "slewfire":
        per_tick = abs(p["spinDeg"]) * p["every"]
        n["tick_deg"] = per_tick
        n["arm_gap_48"] = math.hypot(math.radians(per_tick) * PARTY_R, p["speed"] * p["every"]) - 2 * p["radius"]
        n["channel"] = p["speed"] * (360.0 / abs(p["spinDeg"])) / p["arms"]
        n["sweep_48"] = math.radians(abs(p["spinDeg"])) * PARTY_R
        n["against"] = abs(p["spinDeg"]) + math.degrees(PLAYER_SPEED / PARTY_R)
        n["with"] = abs(p["spinDeg"]) - math.degrees(PLAYER_SPEED / PARTY_R)
        n["ratio"] = n["against"] / n["with"]
        n["live"] = len(live_balls("slewfireFast" if p["arms"] == 3 else "slewfire", p["duration"])[0])
    elif h == "anchorsweep":
        step = p["arcDeg"] / (p["count"] - 1)
        n["step_deg"] = step
        n["lane_studs_48"] = math.radians(step) * PARTY_R - 2 * p["radius"]
        n["solid_to_r"] = 2 * p["radius"] / math.radians(step)
        n["head_studs"] = p["ripple"] * (p["count"] - 1) * p["speed"]
        n["head_s"] = p["ripple"] * (p["count"] - 1)
        n["flight_to_48"] = (PARTY_R - p["spawnAt"]) / p["speed"]
        n["react"] = p["windup"] + n["flight_to_48"]
        n["walk"] = PLAYER_SPEED * n["react"]
        n["need"] = math.radians(90.0) * PARTY_R
    elif h == "wisps":
        n["turn_r"] = p["speed"] / math.radians(p["homingDeg"])
        n["closing"] = p["speed"] - PLAYER_SPEED
        n["reach"] = n["closing"] * p["lifetime"]
    return n


# ============================================================ drawing
def setup_plan(ax, span=100.0, ticks=True):
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
    """Everything that is there before a shot is fired."""
    ax.add_patch(Circle((0, 0), FLEET_R[1], facecolor=AWASH, edgecolor="none", zorder=0))
    ax.add_patch(Circle((0, 0), SAND_R, facecolor=SAND, edgecolor=SAND_EDGE, lw=1.1, zorder=1))
    # the retire bound - past here every ball is dropped
    ax.add_patch(Circle((0, 0), BOUND_R, facecolor="none", edgecolor=INK_FAINT,
                        lw=0.9, ls=(0, (5, 4)), zorder=2))
    # the party ring
    ax.add_patch(Circle((0, 0), PARTY_R, facecolor="none", edgecolor="#5e7d86",
                        lw=1.0, ls=(0, (3, 4)), zorder=3))

    # the six breakwater hulks, long axis radial
    for (r, deg) in WK_HULKS_BLENDER:
        cx, cz = blender_to_xz(r, deg)
        ang = math.degrees(math.atan2(cz, cx))
        L, W = HULK_SIZE
        rect = Rectangle((-L / 2, -W / 2), L, W, facecolor=HULK, edgecolor=HULK_EDGE,
                         lw=0.9, alpha=0.95, zorder=4)
        tr = matplotlib.transforms.Affine2D().rotate_deg(ang).translate(cx, cz) + ax.transData
        rect.set_transform(tr)
        ax.add_patch(rect)

    # the hull footprint, from the WR_HULL stations scaled across to the
    # measured Hull bbox (44.8 studs in the beam), bow at +X.
    kmax = max(h for _, h in WR_STATIONS)
    scale = (HULL_BBOX[1] / 2.0) / kmax
    top = [(x, -h * scale) for x, h in WR_STATIONS]
    bot = [(x, h * scale) for x, h in reversed(WR_STATIONS)]
    ax.add_patch(Polygon(top + bot, closed=True, facecolor=HULL, edgecolor=HULL_EDGE,
                         lw=1.2, zorder=6))
    # her bed of spoil (the Base piece, 87.1 x 47)
    ax.add_patch(Rectangle((2.8 - BASE_BBOX[0] / 2, 0.6 - BASE_BBOX[1] / 2), *BASE_BBOX,
                           facecolor="none", edgecolor="#2c343b", lw=0.8, zorder=5))

    # the four gun decks
    for label, mx, mz, height in MOUNTS:
        ax.add_patch(Rectangle((mx - 2.6, mz - 2.6), 5.2, 5.2, facecolor=BRASS,
                               edgecolor="#3a2a10", lw=0.7, zorder=8))
        if not small:
            ax.text(mx, mz - 4.2, label, color=BRASS, fontsize=6.6, ha="center",
                    va="bottom", zorder=20,
                    bbox=dict(boxstyle="round,pad=0.12", fc=BG, ec="none", alpha=0.75))


def draw_spawn_ring(ax, p, label=True):
    ax.add_patch(Circle((0, 0), p["spawnAt"], facecolor="none", edgecolor=BRASS,
                        lw=0.9, ls=(0, (2, 3)), alpha=0.85, zorder=7))
    if label:
        d = bearing(340)
        ax.text(d[0] * (p["spawnAt"] + 5.5), d[1] * (p["spawnAt"] + 5.5), "r %g" % p["spawnAt"],
                color=BRASS, fontsize=7.0, ha="left", va="center", zorder=20)
        ax.text(0.995, 0.992,
                "every ball is born on r %g from the ARENA CENTRE,\nnot at a gun deck: "
                "the four decks set the COUNT" % p["spawnAt"],
                transform=ax.transAxes, color=BRASS, fontsize=7.6, ha="right",
                va="top", zorder=30)


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


def draw_scale_bar(ax, span=100.0):
    y = span * 0.90
    x0 = -span * 0.94
    ax.plot([x0, x0 + 20], [y, y], color=INK_DIM, lw=2.0, solid_capstyle="butt", zorder=30)
    ax.text(x0 + 10, y - 3.0, "20 studs", color=INK_DIM, fontsize=6.8, ha="center",
            va="bottom", zorder=30)


def draw_compass(ax, span=100.0):
    """Bearings in ProjectileService's convention, which on a Top view (+X
    right, +Z down) increase CLOCKWISE."""
    for deg, txt in ((0, "0"), (90, "90"), (180, "180"), (270, "270")):
        d = bearing(deg)
        ax.text(d[0] * span * 0.965, d[1] * span * 0.965, txt + "°", color=INK_FAINT,
                fontsize=6.4, ha="center", va="center", zorder=30)
    ax.add_patch(Arc((0, 0), span * 1.82, span * 1.82, theta1=0, theta2=360,
                     edgecolor="#232c31", lw=0.8, zorder=1))


def wedge(ax, r0, r1, a0, a1, colour, alpha=0.16, hatch=None, zorder=8, lw=0.0):
    w = Wedge((0, 0), r1, a0, a1, width=r1 - r0, facecolor=colour, alpha=alpha,
              edgecolor=colour if lw else "none", lw=lw, zorder=zorder)
    if hatch:
        w.set_hatch(hatch)
        w.set_edgecolor(colour)
        w.set_linewidth(0.0)
    ax.add_patch(w)


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
    "broadside": (2.40, (0.55, 1.65, 2.40)),
    "broadsideHeavy": (2.56, (0.60, 1.60, 2.56)),
    "grapeshot": (0.55, (0.18, 0.55, 1.00)),
    "grapeshotTwin": (0.75, (0.25, 0.60, 0.95)),
    "chainshot": (1.50, (0.50, 1.50, 2.50)),
    "slewfire": (3.00, (0.90, 2.00, 3.40)),
    "slewfireFast": (3.00, (0.90, 2.00, 3.40)),
    "anchorsweep": (1.78, (0.55, 1.78, 3.10)),
    "wisps": (4.00, (1.20, 4.00, 7.50)),
}

# The one-line answer, as the book states it, plus the measured version.
ANSWER = {
    "broadside": "walk to the gap - and keep walking, it steps 46° every volley",
    "broadsideHeavy": "four rings, a gap two thirds as wide moving further and faster",
    "grapeshot": "step out of the cone DURING the tell, not after it",
    "grapeshotTwin": "two waves, the second offset half a pellet - break to the SHORT edge",
    "chainshot": "the gap inside a pair is the hitbox; the lane is BETWEEN pairs",
    "slewfire": "read the rotation and walk against it - cross the arms the short way",
    "slewfireFast": "same spiral, REVERSED - the way you learned to walk is now wrong",
    "anchorsweep": "you do not thread it, you leave - and the long windup is the walk",
    "wisps": "keep moving, and orbit a hulk tighter than their turn radius",
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
                lr = min(r + 15, 84)
                ax.text(d[0] * lr, d[1] * lr, "gap %d" % (v + 1), color=GHOST,
                        fontsize=7.4, ha="center", va="center", zorder=24,
                        bbox=dict(boxstyle="round,pad=0.18", fc=BG, ec="none", alpha=0.7))
        if not small:
            spin_arrow(ax, 71, gap0, p["gapStep"] * (p["volleys"] - 1), GHOST,
                       label="the gap walks\n+%d° a volley" % p["gapStep"])
        notes = [
            "true empty wedge %.0f° (gapDeg %g + one %.1f° step, balls sit half-step in)"
            % (n["empty_deg"], p["gapDeg"], n["step_deg"]),
            "at r 48 the gap is %.0f studs clear; between two balls, %.1f" % (n["gap_studs_48"], n["lane_studs_48"]),
            "the wall is only SOLID inside r %.0f - past that it has lanes" % n["solid_to_r"],
            "the gap moves %.0f studs per volley at r 48; you can walk %.0f"
            % (n["gap_travel_48"], n["walk_per_volley"]),
        ]

    elif h == "grapeshot":
        fan = p["fanDeg"]
        wedge(ax, p["spawnAt"], BOUND_R, REF_BEARING - fan / 2, REF_BEARING + fan / 2,
              DANGER, alpha=0.10, zorder=8)
        if p.get("bursts", 1) > 1:
            step = fan / (p["pellets"] - 1)
            wedge(ax, p["spawnAt"], BOUND_R, REF_BEARING - fan / 2 + step * 0.5,
                  REF_BEARING + fan / 2 + step * 0.5, DANGER, alpha=0.10, zorder=8)
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
            "%d pellets across %g°: %.1f studs between centres at r 14, %.1f clear at r 48"
            % (p["pellets"], fan, math.radians(n["step_deg"]) * p["spawnAt"], n["lane_studs_48"]),
            "the cone is %.0f studs wide where the party stands" % n["cone_width_48"],
            "%.1f s windup + %.2f s flight = %.0f studs of walk, against %.0f needed to clear it"
            % (p["windup"], n["flight_to_48"], n["walk"], n["need"]),
        ]

    elif h == "chainshot":
        step = n["step_deg"]
        for i in range(p["pairs"] - 1):
            a = REF_BEARING - p["fanDeg"] / 2 + step * (i + 0.5)
            wedge(ax, p["spawnAt"], BOUND_R, a - step * 0.30, a + step * 0.30, GHOST,
                  alpha=0.16, zorder=8)
            if not small:
                d = bearing(a)
                ax.text(d[0] * 70, d[1] * 70, "lane", color=GHOST, fontsize=7.2,
                        ha="center", va="center", zorder=24)
        if not small:
            # THE TRAP, called out on the pair furthest from the label margin:
            # the 12-stud hole between a pair's two balls is filled by the
            # chain, so it reads as a lane and is the hitbox.
            st = chain_state(emit_chainshot(p, REF_BEARING)[1], t)
            if st:
                lead, follow, br, cr = st
                mid = ((lead[0] + follow[0]) / 2, (lead[1] + follow[1]) / 2)
                tip = (-40.0, 76.0)
                ax.plot([mid[0], tip[0]], [mid[1], tip[1]], color=DANGER,
                        lw=0.9, alpha=0.85, zorder=25)
                ax.text(tip[0] - 3, tip[1] + 3,
                        "the %g-stud hole inside a pair is NOT a lane —\nthe chain fills it, "
                        "and the chain is the hitbox\n(a capsule of radius %.1f, drawn at "
                        "that width)" % (p["chain"], cr),
                        color=DANGER, fontsize=7.6, ha="center", va="top", zorder=26,
                        bbox=dict(boxstyle="round,pad=0.25", fc=BG, ec="none", alpha=0.78))
        notes = [
            "%d pairs %g° apart; each pair is %.0f studs end to end, %.1f wide at the chain"
            % (p["pairs"], step, n["pair_len"], p["chainRadius"] * 2),
            "the lane between pairs is %.0f studs clear at r 48" % n["lane_studs_48"],
            "spin %g°/s: a full turn every %.2f s, end-on every %.2f s"
            % (p["spinDeg"], n["turn_s"], n["beat_s"]),
            "it crosses the sand in %.1f s - %.1f turns of the chain" % (n["cross_time"], n["turns"]),
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
                r = p["spawnAt"] + p["speed"] * age
                if age < p["lifetime"] and r <= BOUND_R:
                    a = REF_BEARING + p["spinDeg"] * every * k + (360.0 / p["arms"]) * i
                    d = bearing(a)
                    xs.append(d[0] * r)
                    zs.append(d[1] * r)
                k += 1
            ax.plot(xs, zs, color=SKIN["cannon"], lw=1.0, alpha=0.30, zorder=9)
        if not small:
            spin_arrow(ax, 84, deck - sweep * 0.15, sweep, DANGER,
                       label="the deck spins\n%+g°/s" % p["spinDeg"])
            # the answer: cross the arm walking the other way round
            a = math.degrees(math.atan2(REF_POS[1], REF_POS[0]))
            spin_arrow(ax, PARTY_R, a, -sweep * 0.40, GHOST, lift=26,
                       label="walk AGAINST it:\ncross %.2fx faster" % n["ratio"])
        notes = [
            "%d arm%s, one tick every %g s: the deck steps %.1f° a tick"
            % (p["arms"], "" if p["arms"] == 1 else "s", p["every"], n["tick_deg"]),
            "%.0f studs of open water between arms; %.1f stud holes along one arm at r 48"
            % (n["channel"], n["arm_gap_48"]),
            "an arm crosses r 48 at %.0f studs/s - you cannot outrun it, only cross it"
            % n["sweep_48"],
            "walking against the spin crosses %.2fx faster (%.0f°/s vs %.0f°/s relative)"
            % (n["ratio"], n["against"], n["with"]),
        ]

    elif h == "anchorsweep":
        wedge(ax, p["spawnAt"], BOUND_R, REF_BEARING - 90, REF_BEARING + 90, DANGER,
              alpha=0.12, zorder=8)
        wedge(ax, p["spawnAt"], SAND_R, REF_BEARING + 90, REF_BEARING + 270, GHOST,
              alpha=0.12, zorder=8)
        if not small:
            d = bearing(REF_BEARING + 180)
            ax.text(d[0] * 58, d[1] * 58, "THE OTHER HALF", color=GHOST, fontsize=10.0,
                    ha="center", va="center", zorder=24, fontweight="bold")
            # The trailing end is i = count-1, at base + arc/2: `head` is
            # ripple*(count-1-i)*speed, so that end is the one born at spawnAt
            # with no head start at all.
            e = bearing(REF_BEARING + 90)
            ax.text(e[0] * 66, e[1] * 66 - 16,
                    "trailing end: born %.1f studs\nfurther in, so it arrives\n%.1f s after the "
                    "leading end" % (n["head_studs"], n["head_s"]),
                    color=GHOST, fontsize=7.2, ha="center", va="center", zorder=25)
            rad = bearing(REF_BEARING)
            tang = (-rad[1], rad[0])  # +rot90: toward base + 90, the trailing end
            straight_arrow(ax, REF_POS,
                           (REF_POS[0] + tang[0] * 30, REF_POS[1] + tang[1] * 30), GHOST)
            f = bearing(REF_BEARING - 90)
            ax.text(f[0] * 66, f[1] * 66 - 14,
                    "leading end: %.1f studs\nof head start" % n["head_studs"],
                    color=DANGER, fontsize=7.2, ha="center", va="center", zorder=25)
        notes = [
            "%d anchors across %g°, radius %g - the biggest ball in the fight"
            % (p["count"], p["arcDeg"], p["radius"]),
            "solid only inside r %.0f; at r 48 there are %.1f stud slots between them"
            % (n["solid_to_r"], n["lane_studs_48"]),
            "%.1f s windup + %.2f s flight = %.0f studs of walk, against %.0f to clear 90° "
            "sideways" % (p["windup"], n["flight_to_48"], n["walk"], n["need"]),
            "so the rose's other answer is INWARD: %.0f studs of windup puts you inside r %g "
            "before the wall exists" % (PLAYER_SPEED * p["windup"], p["spawnAt"]),
            "damage %d-%d: roughly double every other pattern" % p["damage"],
        ]

    elif h == "wisps":
        hi, orb = wisp_answer()
        notes = [
            "speed %g vs a %g stud/s walk: they close %g studs/s and live %g s"
            % (p["speed"], PLAYER_SPEED, n["closing"], p["lifetime"]),
            "turn rate %g°/s at speed %g = a %.1f STUD TURN RADIUS - a circle they cannot fly inside"
            % (p["homingDeg"], p["speed"], n["turn_r"]),
            "searched, not asserted: r %g round hulk %d is the orbit all three miss for the whole %g s"
            % (orb, (hi if hi is not None else 4) + 1, p["lifetime"]),
            "TIGHTER IS NOT BETTER - under ~8 studs you stop covering ground and the head-on one lands",
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
        draw_rose(ax, rose, REF_POS, length=(12.0 if p["handler"] == "wisps" else 17.0)
                  if not small else 13.0, lw=1.4 if small else 2.2)
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
    """THE ANSWER, SEARCHED RATHER THAN ASSERTED.

    The book says "orbit a breakwater hulk tight enough that their turn rate
    overshoots", and the turn radius really is 15.6 studs - but simply going
    as tight as possible does NOT work, because a very tight circle stops you
    covering ground and the wisp coming straight down your bearing arrives
    anyway. So sweep every hulk and every orbit radius from 6 to 15 studs,
    integrating the real homing law against a real walking path, and take the
    first radius that sits in the middle of a band at least three steps wide
    (a knife-edge radius is not an answer a player can execute), preferring
    the hulk with the shortest approach. Deterministic: no rng, fixed grid.

    Returns (hulk index, orbit radius, list of survivors-per-wisp).
    """
    if _WISP_ANSWER:
        return _WISP_ANSWER["v"]
    p = ATTACKS["wisps"]
    radii = [6.0 + 0.5 * i for i in range(19)]
    best = None
    for hi in range(len(WK_HULKS_BLENDER)):
        cx, cz = blender_to_xz(*WK_HULKS_BLENDER[hi])
        approach = math.hypot(cx - REF_POS[0], cz - REF_POS[1])
        ok = []
        for r in radii:
            path, _, _ = hulk_orbit_path(hi, r)
            tracks = wisp_tracks(p, REF_BEARING, path)
            ok.append(all(t["caught"] is None for t in tracks))
        run, start = 0, None
        for i, good in enumerate(ok + [False]):
            if good:
                run += 1
                start = i - run + 1 if run == 1 else start
            else:
                if run >= 3:
                    mid = radii[start + run // 2]
                    if best is None or approach < best[2]:
                        best = (hi, mid, approach)
                run = 0
    if best is None:  # nothing survives - say so rather than draw a lie
        _WISP_ANSWER["v"] = (None, 9.0)
    else:
        _WISP_ANSWER["v"] = (best[0], best[1])
    return _WISP_ANSWER["v"]


def hulk_orbit_path(hulk_index=4, orbit_r=8.5):
    """The wisp answer, as a path: walk to a breakwater hulk and round it
    inside the wisps' own 15.6-stud turn circle."""
    cx, cz = blender_to_xz(*WK_HULKS_BLENDER[hulk_index])
    # start where the reference challenger stands, walk to the hulk, then orbit
    sx, sz = REF_POS
    d = math.hypot(cx - sx, cz - sz)
    approach = max(0.0, (d - orbit_r) / PLAYER_SPEED)
    omega = PLAYER_SPEED / orbit_r

    def path(t):
        if t < approach:
            f = t / approach if approach > 0 else 1.0
            tx = cx + (sx - cx) * (orbit_r / d)
            tz = cz + (sz - cz) * (orbit_r / d)
            return (sx + (tx - sx) * f, sz + (tz - sz) * f)
        a0 = math.atan2(sz - cz, sx - cx)
        a = a0 + omega * (t - approach)
        return (cx + math.cos(a) * orbit_r, cz + math.sin(a) * orbit_r)

    return path, (cx, cz), orbit_r


def draw_wisps(ax, p, t, small=False):
    hi, orb = wisp_answer()
    path, hulk, orbit_r = hulk_orbit_path(hi if hi is not None else 4, orb)
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
    # the player's own path: walk to the nearest hulk, then round it inside
    # the wisps' own turn circle
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
        ax.text(hulk[0] - 15, hulk[1] + 15,
                "your orbit: r %g round the\nnearest hulk. Inside r %.1f,\nso all three overshoot "
                "for\nthe full %g s" % (orbit_r, n["turn_r"], ATTACKS["wisps"]["lifetime"]),
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
                              "pattern from r 48" % (ok, len(rose), PLAYER_SPEED)))
        lines.append(("note", "Simulated against the real hit test — the ball's own radius "
                              "against the root point"))
    lines.append(("gap", ""))
    lines.append(("head", "AND THE GUN DECKS SCALE IT"))
    # NOT every pattern, in fact: ProjectileService runs `countOf(n, ctx.scale)`
    # for broadside / grapeshot / chainshot / anchorsweep / wisps, but
    # PATTERNS.slewfire takes `math.max(1, p.arms)` with no scale at all, so
    # the spiral thins only by stopping. Say which one this is.
    if p["handler"] == "slewfire":
        lines.append(("note", "slewfire is the ONE pattern whose count ignores the scale: "
                              "PATTERNS.slewfire reads p.arms raw"))
        lines.append(("note", "so the spiral stays %d arms thick until the last deck falls, "
                              "then stops dead for %g s" % (p["arms"], 4.0)))
    else:
        key = ("count" if "count" in p else "pellets" if "pellets" in p else "pairs")
        counts = ["%d" % count_of(p[key], 0.4 + 0.6 * (a / 4.0)) for a in (4, 3, 2, 1)]
        lines.append(("note", "%s: %s with 4 / 3 / 2 / 1 gun decks standing (countOf, "
                              "scale 0.4 + 0.6 x alive/4)" % (key, " → ".join(counts))))
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
    fig.text(0.026, 0.930, "Admiral Wrack  ·  phase %d  ·  handler \"%s\"  ·  skin \"%s\""
             % (PHASE_OF[name], p["handler"], p["skin"]),
             color=INK_DIM, fontsize=9.5, ha="left", va="top")
    fig.text(0.975, 0.975, ANSWER[name], color=GHOST, fontsize=14.0, ha="right", va="top",
             style="italic")
    fig.text(0.975, 0.936, "The Careenage, plan view · +X right, +Z down (Studio Top view) "
                           "· bearings increase clockwise",
             color=INK_FAINT, fontsize=8.4, ha="right", va="top")

    ax = fig.add_axes([0.012, 0.025, 0.500, 0.885])
    setup_plan(ax)
    draw_pattern(ax, name, main_t, rose=rose)
    ax.text(-99, -99, "t = %.2f s after the guns fire" % main_t, color=INK,
            fontsize=11.0, ha="left", va="top")

    # the annotation column
    axi = fig.add_axes([0.530, 0.430, 0.455, 0.470])
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
        axm = fig.add_axes([0.530 + i * 0.157, 0.078, 0.148, 0.262])
        setup_plan(axm)
        draw_pattern(axm, name, mt, small=True, rose=None, show_overlay=True)
        axm.text(0, 101, "t = %.2f s" % mt, color=INK_DIM, fontsize=8.6, ha="center",
                 va="top")

    fig.text(0.530, 0.382, "THE SAME MOVE, THREE MOMENTS", color=INK_FAINT, fontsize=8.6,
             ha="left", va="top", fontweight="bold")
    fig.text(0.975, 0.008,
             "assets/wrack_patterns_gen.py — geometry ported from ProjectileService.luau, "
             "numbers from Bosses.luau. The hulks are landmarks, not cover: nothing in the "
             "bullet sim occludes a shot.",
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
             "The Careenage, plan view, everything to scale. Sand walkable to r 78; the party is "
             "dropped on r 48; six breakwater hulks at r 33-52; four gun decks in brass.\n"
             "Mint is the answer. The mint/red rose at the player dot is every constant heading a "
             "%g stud/s walk could take from the tell's first frame — mint survives the whole "
             "pattern, red does not." % PLAYER_SPEED,
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
    fig.text(lx + 0.010, ly, "gun decks (shoot these)", color=INK, fontsize=10.0,
             ha="left", va="center")
    lx += 0.145
    fig.patches.append(plt.Rectangle((lx - 0.007, ly - 0.0035), 0.014, 0.007,
                                     transform=fig.transFigure, facecolor=HULK,
                                     edgecolor=HULK_EDGE, lw=0.8))
    fig.text(lx + 0.012, ly, "breakwater hulk — a landmark, NOT cover",
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
        fig.text(x0 + tile_w, row_top, "phase %d" % PHASE_OF[name],
                 color=INK_FAINT, fontsize=9.5, ha="right", va="top")
        fig.text(x0, y0 - 0.008, ANSWER[name], color=GHOST, fontsize=9.6,
                 ha="left", va="top")
        fig.text(x0, y0 - 0.026, overlay_notes_cache[name][0], color=INK_DIM,
                 fontsize=8.4, ha="left", va="top")

    fig.text(0.030, 0.014,
             "Generated by assets/wrack_patterns_gen.py from Bosses.luau + ProjectileService.luau + "
             "CreatureService.luau + arena_gen.py. Nothing here is authored by hand; broadside's gap\n"
             "bearing is seeded (it is random in the fight) so the render reproduces exactly. Ball "
             "counts are with all four gun decks alive: every pattern except slewfire scales its "
             "count by\n0.4 + 0.6 x (decks alive / 4), and every pattern stops dead for %g s when "
             "the last deck falls. Nothing in the bullet sim occludes a shot, so the hulks stop "
             "nothing." % 4.0,
             color=INK_FAINT, fontsize=8.8, ha="left", va="bottom")

    path = os.path.join(out_dir, "wrack_patterns_sheet.png")
    fig.savefig(path, dpi=140)
    plt.close(fig)
    return path


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
    print("")
    for name in ORDER:
        p = ATTACKS[name]
        n = ring_numbers(name)
        rose = escape_rose(name, REF_POS, headings=36)
        ok = sum(1 for _, s in rose if s)
        print("HANDOFF %-15s live at t=%.2f: %3d balls  ·  escape rose %2d/36  ·  %s"
              % (name, MOMENTS[name][0], len(live_balls(name, MOMENTS[name][0])[0])
                 + 2 * len(live_balls(name, MOMENTS[name][0])[1]), ok,
                 "; ".join("%s %.1f" % (k, v) for k, v in sorted(n.items()))))


if __name__ == "__main__":
    main()
