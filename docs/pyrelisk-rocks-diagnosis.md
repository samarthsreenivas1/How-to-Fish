# Pyrelisk: floating objects and "random, weird" rocks — diagnosis + edit plan

> **2026-09-12 — TOOL MOVED.** The scratch instruments this diagnosis was written
> against (`tools/posed_connectivity/posed_connectivity.py` and its helpers
> `components.py` and `joints.py`) no longer exist as a
> directory. The posed contact-graph instrument is now the single self-contained
> `tools/check_posed_connectivity.py` — run it as
> `blender --background --python tools/check_posed_connectivity.py -- [--boss pyrelisk]
> [--root Pyrelisk_Core] [--contact 0.3] [--control]`. Every reference to the old script
> below means that file. The old `components.py`'s per-object component count is now the KNIT
> lines the generator prints and the per-object histogram the new tool prints;
> `joints.py`'s clearances are the per-object nearest-gap stats at the end of its run.

Read-only diagnosis. Nothing in the repo was written, staged or committed.

## 0. WHICH FILE THIS IS ABOUT (read first)

The brief said to base the plan on `git show HEAD:assets/boss_gen.py`. **That is the
wrong file.** HEAD's Pyrelisk section (HEAD lines 2067–2916) is the PRE-REMAKE body:
`PY_SHELL_RINGS`, `_py_plate_chunk`, height 300, shoulder z 186. The shipped
`assets/boss_pyrelisk.glb` and every preview PNG were produced by the **uncommitted
worktree** `assets/boss_gen.py` — the 2026-09-09 remake: `PY_BODY` / `_py_clad` /
`_py_rock`, height 206, shoulder z 126. Every number below is measured against the
worktree.

Two timestamps, because the file is live under another session:

* **BASELINE** (all headline numbers): `assets/boss_gen.py` mtime **2026-09-09 16:11:43**,
  `assets/boss_pyrelisk.glb` mtime 2026-09-09 15:42:39. This is what the user looked at.
* **RE-MEASURE**: snapshot taken at **2026-09-11 23:47** (copied to
  `boss_gen_wt_2347.py` here), after the Pyrelisk lane began landing a `_py_knit` pass.
  Between 23:46 and 23:47 the file was mid-edit and did not parse. I did not chase it
  further.

## 1. INSTRUMENTS

`tools/check_floaters.py` **cannot be made to work on this boss as-is**:

    blender --background --python tools/check_floaters.py -- assets/boss_pyrelisk.glb --control
    [control] no landform (*_Base) object found
    FLOATERS: 0 floating, ... across 0 objects/0 components
    CONTROL FAILED

Its root rule is `is_landform(name) or lo.z <= WATERLINE` (check_floaters.py:748–751,
`is_landform` at :180) and its control needs a `*_Base` object (:1013). It also has a
deeper mismatch: the glb is **14 modules all authored at the origin**, not an assembled
boss, so a contact graph over it means nothing. Faking a `_Base` name would make the
control lie, so I wrote two instruments instead (both in this directory):

* `components.py` — per-object connected-component count off the exported glb.
  Control: a two-cube mesh must report 2. **CONTROL OK.**
* `tools/check_posed_connectivity.py` — builds the boss from the worktree generator, poses it with
  `_place_pyrelisk(head_yaw=-16°)` (the rest pose `render_py_previews` renders), splits
  every posed object into mesh components, builds a **BVH surface-distance contact graph**
  (contact ≤ 0.30 studs, bbox-grid prefilter) and reports everything unreachable from
  `Pyrelisk_Core`. Control: two 4-stud probes on the chest surface, one at +5.0 studs
  (must report adrift) and one at +0.2 studs (must report attached). **CONTROL OK**
  (both assertions evaluated; the first control I wrote — pushing a real chest rock 5
  studs outward — came back CONTROL FAILED, because chest rocks are ~16 studs wide and
  5 studs does not disconnect one. That negative is itself data: the chest is densely
  overlapped.)
  Known limitation: a component wholly swallowed inside another reads as adrift.

## 2. MEASURED: COMPONENTS PER OBJECT (exported glb, baseline)

    Pyrelisk_Core       452 tris   COMPONENTS   3    largest 224.0 studs
    Pyrelisk_Crown       64 tris   COMPONENTS   4    largest  15.5
    Pyrelisk_Eyes        24 tris   COMPONENTS   2    largest   6.4
    Pyrelisk_Forearm    920 tris   COMPONENTS  46    largest  27.7
    Pyrelisk_Hand       360 tris   COMPONENTS  18    largest  23.7
    Pyrelisk_Head       720 tris   COMPONENTS  36    largest  30.7
    Pyrelisk_Jaw         80 tris   COMPONENTS   4    largest  22.5
    Pyrelisk_Seam       136 tris   COMPONENTS   6    largest  30.0
    Pyrelisk_Shoulder   416 tris   COMPONENTS  21    largest  27.4
    Pyrelisk_Torso     9480 tris   COMPONENTS 474    largest  45.1
    Pyrelisk_UpperArm  1000 tris   COMPONENTS  50    largest  27.2
    Pyrelisk_Vent       156 tris   COMPONENTS   9    largest  19.5
    Pyrelisk_WalkArm     12 tris   COMPONENTS   1
    Pyrelisk_WalkDeck    36 tris   COMPONENTS   3
    TOTAL 677 components across 14 objects

**Mesh-topology components are not the target.** Rocks are never booleaned, so 474
interpenetrating boulders are 474 components and look like one rock. "One connected
component" must mean **one contact-connected component** (every rock overlapping a
neighbour), which is what §3 measures. Demanding topological unity would mean a boolean
union and a triangle budget nobody wants.

## 3. MEASURED: FLOATERS ON THE POSED BOSS

Rest pose, 29 placed parts, **889 components**, 2085 of 7729 candidate pairs in contact.

**BASELINE (2026-09-09 16:11 file): 212 components adrift from the Core, in 35 clusters.**

    Pyrelisk_Forearm      92 of  92 adrift      Pyrelisk_Torso      11 of 474
    Pyrelisk_UpperArm     46 of 100 adrift      Pyrelisk_Seam        6 of  66
    Pyrelisk_Hand         36 of  36 adrift      Pyrelisk_WalkDeck    1 of   3
    Pyrelisk_Vent         19 of  27 adrift      Pyrelisk_Head        1 of  36

RE-MEASURE (23:47 snapshot, after the lane's `_py_knit` landed): **202 adrift in 30
clusters** — torso 11→5, head 1→2, arms/vents unchanged. `_py_knit` is an *intra-object*
pass over the `_PY_CHUNKS` ledger (snapshot :2973) using a **sphere proxy**
(centre distance vs `(r_i + r_j) * PY_KNIT_OVERLAP`, :2926/:2950). It therefore cannot
see (a) joints *between* pieces, which only exist at pose time, (b) anything not built
through `_py_rock` — the whole `Pyrelisk_Vent`, and (c) surface separations that its
sphere proxy calls closed.

**How big is each gap** — distance from each adrift cluster to the nearest *attached*
surface. This splits the report cleanly in two:

    cluster of 83  (one arm: UpperArm+Forearm+Hand)  0.30 studs from attached UpperArm
    cluster of 82  (the other arm)                   0.30
    cluster of  1  UpperArm                          0.36
    3x cluster of 1 Torso                            0.32 / 0.34 / 0.40 / 0.47 / 0.84
    cluster of  1  Head                              1.14 and 1.61
    ---- the above are NEAR MISSES. Below are REAL holes in the air: ----
    cluster of  1  Forearm (the elbow point rock)   31.9 and 37.2   (one per arm)
    13x cluster of 1  Vent                           5.8 .. 21.1
    cluster of 10  Seam (30-stud fissure)            0.33 from a WalkDeck slab only

Joint clearances measured piece-to-piece (`joints.py`), which is why the arms are
near-misses and not gaps you can see:

    arm y-: torso->pauldron 0.08  pauldron->upperarm 0.03  upperarm->forearm 0.04  forearm->hand 0.01
    arm y+: torso->pauldron 0.07  pauldron->upperarm 0.00  upperarm->forearm 0.02  forearm->hand 0.02
    head:   torso->head 0.28  head->jaw 0.01  head->crown 0.09  head->eyes 0.02
    deck:   torso->walkdeck 0.58        vent->torso 5.51 / 7.42 / 7.57

So: **the two arms and most of the body are held together by contacts of 0.00–0.08
studs** — kissing, not overlapping. Every one of them is a coin flip of the seed. The
visible floaters the user is actually pointing at are the **Vent chimneys**, the
**vent-mouth Seams**, and the **elbow-point rocks**.

## 4. ROOT CAUSES, with line refs

Line numbers are the 2026-09-11 23:47 snapshot (`boss_gen_wt_2347.py` here); the
baseline file's numbers for the same symbols are ~250 lower and the code is identical
except for the knit pass.

### 4a. Nothing guarantees a rock overlaps its neighbour — coverage is a mean, not a floor

`_py_clad` (:3141–3177): `half_w = pitch * 0.72 * plate * U(0.76, 1.34)`,
`half_h = span * 0.72 * stretch * plate * U(0.74, 1.32)`, `deep = thick * U(0.70, 1.34)`,
cell centre jittered by `U(-0.42, 0.42)` of a column and `U(-0.34, 0.34)` of a row, ring
phase `twist = U(0, TAU)` per row. Two adjacent rocks at the bottom of the roll
(0.76 × 0.76) with their jitters pointing apart cover ~1.09 of the 2.0 cells between
their centres — a gap. The docstring says as much: "the spread still leaves every third
junction open". That is deliberate for *cracks*, and it is also exactly what produces
8 zero-contact torso rocks and 32 single-contact ones. Same construction in
`_py_clad_shell` (:3185, golden-angle lattice, same 0.76–1.34 roll) and `_py_limb_clad`
(:3415) — the limb version is the worst, because a limb is a thin tube: one open ring
junction cuts the arm in half, which is precisely the 82- and 83-component clusters.

### 4b. Pose-time joints are never measured

`_place_pyrelisk` (:3940+) walks shoulder → elbow → wrist and places each piece at the
joint. Each piece is clad from its own origin outward: `_py_limb_clad` puts its first
ring centre at `span * 0.5` (:3427) and puts **no cap at x = 0**, so the bone's butt end
is open and the junction is whatever the two pieces' outermost rocks happen to do.
Measured: 0.00–0.08 studs. There is no assertion anywhere that a limb piece touches its
parent.

### 4c. `Pyrelisk_Vent` is built as separated rings — this is the user's "floating objects"

`build_py_vent` (:3565):

    for i in range(4):
        disc(bm, t * 8.0, t * 8.0 + 5.5, 10.0 - t * 2.0, 9.0 - t * 2.0, sides=7)

Collars occupy [0,5.5], [8,13.5], [16,21.5], [24,29.5] — **2.5-stud air gaps between
every pair**. Then five spikes are based at x = 23.0, which is *inside one of those
gaps*, tipped to x ≈ 32 (past the last collar). That is 9 components with nothing
joining them, placed three times: 19 of 27 adrift, 5.8–21.1 studs from any rock. It is
also the piece standing highest on the silhouette (z 162–177), i.e. the most visible.

### 4d. The walk decks are deliberately lifted clear of the rock

`_py_seat_decks` (:3639) seats each deck at `top + 0.6 + size/2` — 0.6 studs of
clearance, by design, so the slab is never inside the rock. 0.6 > the 0.3 contact
threshold, so the deck floats by measurement, and the Vents standing on it inherit that.
HANDOFF confirms: "0.6 of clearance" on all three decks.

### 4e. The vent-mouth Seam is placed 13 studs off the surface

`_place_pyrelisk` (:3989): a Seam is copied to
`position + normal * 13.0` for each vent site. Since the 2026-09-09 fissure rework the
Seam is a **30-stud zigzag crack**, not a small wedge — so this is a 30-stud fissure
hanging 13 studs out in the air over the boss's back (cluster of 10 at
x −35.5, z 158.4, nearest rock 0.33 studs away via a deck slab only).

### 4f. The elbow-point rock misses the arm

`build_py_forearm` (:3459+): `_py_rock(bm, (2.0, 0.0, -13.0), (9.0, 10.0, 6.0), normal=(-0.45, 0, -0.9))`
— authored at the very butt of the flattened forearm (half-height there is
18 × 0.74 ≈ 13.3) and pushed further out by its own sink. Measured 31.9 / 37.2 studs
from attached rock, one per arm, deterministic.

### 4g. Why the rocks read "random and weird"

Measured spread of component bbox max-dimension on the posed boss:

    Pyrelisk_Torso     n=474   min  7.1  median 23.2  max 45.1   (6.3x)
    Pyrelisk_Head      n= 36   min  9.9  median 20.7  max 28.8   (2.9x)
    Pyrelisk_UpperArm  n=100   min 14.1  median 19.7  max 27.3   (1.9x)
    ALL ROCK           n=886   p05 8.4   median 20.0  p95 35.2   (p95/p05 = 4.2x)

Four multiplicative sources of variance stack on every single rock:
1. band `plate` 0.86 → 1.20 across `PY_CLAD_BANDS` (:3283) — intended, and it is the
   good half of the design ("big on the chest, small at waist and neck");
2. the per-rock roll `U(0.76, 1.34)` on *each* tangential axis independently (:3172–3174)
   — 1.76x within one band, and applied per axis, so aspect ratio wanders too;
3. `deep = thick * U(0.70, 1.34)` — every rock sits at a different height off the shell;
4. `_py_rock` (:3090) per-vertex kick of `PY_JITTER` (0.26; 0.34 in the baseline file)
   **of each radius**, plus `yaw U(-0.5, 0.5)` rad and `tilt U(-0.30, 0.30)` rad on two
   axes — and `_py_rubble` (:3219) uses `yaw = π` (free spin) and `jitter = 0.40`.
   A 20-face icosahedron whose every vertex moves up to ±26–40% of its own radius has no
   recognisable shape family left: every rock is a different silhouette.

The three together mean neighbouring rocks share **no** property: not size, not aspect,
not depth off the shell, not orientation. That is the "random and weird" the user saw —
the 2026-09-09 remake overshot the correction for "rectangular and ugly".

## 5. THE EDIT PLAN (smallest change that holds)

Ordered by value per line touched. (1)–(4) are the floaters, (5)–(7) the uniformity,
(8) the guard. All of it keeps the 14-object contract, the names, z=0 = lake surface,
the `+X`-per-joint arm authoring, `_Seam` / `_Vent` / `_WalkArm` / `_WalkDeck`.

1. **Fix `build_py_vent` (:3565) — the one visible win.** Overlap the collars instead
   of spacing them: run `disc(bm, t * 6.0, t * 6.0 + 8.0, ...)` for `t in 0..3`
   (spans [0,8], [6,14], [12,20], [18,26] — 2 studs of overlap at every junction), and
   base the spikes at x ≤ 20 so each one is rooted *inside* a collar rather than in the
   gap. Net: 9 components → 1 contact-connected mass, 19 of the 27 adrift components gone.
2. **Seat the vent-mouth Seam on the rock, not 13 studs off it** (`_place_pyrelisk` :3989).
   Replace the fixed `* 13.0` with the vent's own measured throat depth, or simply drop
   it to `* 2.0` so the fissure is on the collar it lights. If the glow needs to be
   *inside* the chimney, that is `normal * 2.0` plus the collar radius, not 13.
3. **Root the elbow-point rock** (`build_py_forearm` :3459). Move it to x ≈ 6.0,
   z ≈ −9.0 (inside the first clad ring's envelope) and let the knit pass own it.
4. **Close the pose-time joints.** In `_py_limb_clad` (:3415) add one *joint collar*
   ring at `x = 0` — a half-ring of rocks centred on the joint, same cladding call with
   `ring = -0.5` — so every limb piece begins with rock that provably overlaps its
   parent's joint sphere. This costs ~9 rocks per limb piece (≈ 54 rocks / 1080 tris on
   the whole boss) and converts four 0.00–0.08 stud kisses per arm into real overlap.
   Alternative if the triangle budget is tight: accept a documented contact tolerance of
   1.0 stud *between pieces* and assert it, but the kiss is then still a kiss.
5. **Narrow the size band.** `_py_clad` (:3172–3174) and `_py_clad_shell` (:3204–3206):
   replace the two independent `U(0.76, 1.34)` rolls with **one** roll per rock,
   `s = U(0.92, 1.14)`, applied to both tangential radii (so aspect ratio is a property
   of the *cell*, not of the die), and change `deep` to `thick * U(0.90, 1.10)`.
   Measured spread 4.2x → ~1.5x within a band, while `PY_CLAD_BANDS`' deliberate
   chest-to-neck gradient survives untouched.
6. **One shape family.** Drop `PY_JITTER` from 0.26 to ~0.12 and `_py_rubble`'s from
   0.40 to 0.18, and cut `tilt` from ±0.30 to ±0.12 rad. The rocks stay broken (an
   icosahedron at 0.12 is still not a box) but they stop being 886 different silhouettes.
   Keep `yaw` free — spin about the surface normal is what kills masonry and costs
   nothing in uniformity.
7. **Align to the limb axis.** `_py_limb_clad` (:3446) already aims each rock at the tube
   normal; add `yaw=0.15` there (currently 0.6) so arm rocks read as courses running
   *along* the bone. The torso keeps its free yaw.
8. **A build-time connectivity assertion, in the `_wr_assert_*` style** (see
   `_wr_assert_sponsons` :6110, `_wr_assert_hatch_rise` :6146, `_wr_assert_fits` :6166).
   `_py_knit` (:2973) already guards *within* an object with a sphere proxy and already
   has a self-test (`_py_knit_selftest` :3027). What is missing is the **assembled**
   check. Add `_py_assert_assembled()`, called at the end of `build_pyrelisk`:
   * pose the built parts with `_place_pyrelisk` into a throwaway scene;
   * build the contact graph exactly as `tools/check_posed_connectivity.py` does (BVH nearest ≤ 0.35;
     the decks' authored 0.6 clearance means the deck/vent edges must either use a
     documented 0.7 tolerance or the vents must be seated on rock, not on the slab);
   * `raise SystemExit` naming every component unreachable from `Pyrelisk_Core`, with its
     position and size, the way KNIT FAILED already does;
   * **positive control, evaluated on every build**: inject two 4-stud probes on the
     chest surface, one at +5.0 studs and one at +0.2, assert the first is reported and
     the second is not, and print CONTROL FAILED if either assertion did not run.
     `tools/check_posed_connectivity.py` here is a working implementation of exactly this and can be
     lifted more or less verbatim.
   * budget: the whole run here (build + pose + 891 components + 7.7k candidate pairs)
     takes well under a minute in Blender.

### What NOT to do
* Do not boolean-union the rocks to chase "one mesh component" — 474 rocks is 9480 tris
  precisely because they are separate, and the crack-and-core read depends on them
  staying separate.
* Do not raise the contact tolerance to make the arms pass. 0.00–0.08 studs of kiss is
  the defect; a 1.0-stud tolerance just stops reporting it.
* Do not remove the decks' 0.6-stud clearance — it is what keeps the walkable slab out
  of the rock. Fix the vents' footing instead.
