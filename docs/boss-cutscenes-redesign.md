# Boss intro cutscenes: diagnosis and redesign

**Status:** diagnosis + design, nothing implemented. Written 2026-09-12 from the WORKTREE
(uncommitted work included). Every number here is either measured (marked **[M]**, with the
command that produced it), quoted from code (file:line), or flagged **[UNVERIFIED]**.

**The brief, verbatim:**

> "for all of the cutscenes, make sure that it is not using the roblox studio objects or
> whatever instead of the actual blender models, it needs to be using the blender models and
> animating the blender models to make this stuff work. like completely redo the animations
> for the blender models for the cutscenes to make them actually do stuff. like brinejaw
> should jump out of the ocean like an actual serpent and we should see it exit the water
> further from the lighthouse and it should be head first followed by the rest of his body
> sequentially like coming out of the water like a dragon and then we should actually see it
> curling around the lighthouse. like we should have stuff like that for each boss make it
> more interesting so that we can actually see all of the bosses before we fight them."

---

## 0. FIRST: the import question is settled. Every pack is imported.

The load-bearing input was whether the user's Studio actually has the boss packs — if not, the
`makePiece` fallback branch fires and the cutscenes draw tinted blocks no matter what the code
says, and that alone would be the whole complaint.

`assets/Assets.rbxm` (5.7 MB, exported by the user 2026-09-12 09:35; the committed copy is
from 08-26) is the asset tree. `strings` is inconclusive because rbxm chunks are LZ4-block
compressed, so it was decoded properly: binary rbxm header → `INST`/`PROP`/`PRNT` chunks, each
LZ4-block decompressed with a hand-written 20-line decoder, instance names read from the `Name`
`PROP` chunks, tree rebuilt from `PRNT`'s zigzag-interleaved referent deltas.

**[M]** Decoder + walker: `/private/tmp/.../scratchpad/rbxm.py`. Header: 3 classes, 3180
instances — `Folder` ×1, `Model` ×1527, `MeshPart` ×1652.

| Pack / arena | Objects present | Checklist expects | Verdict |
|---|---|---|---|
| `BrinejawPack` | 9 | 9 (row 7c) | **present, complete** |
| `BrinejawArena` | 19 | row 7b says 13 | present; **checklist count is stale** (arena re-authored since) |
| `BrinejawFxPack` | 10 | 10 (row 7q) | **present, complete** |
| `GnashrootPack` | 14 | 14 (row 7f) | **present, complete** |
| `GnashrootArena` | 16 | 16 (row 7d) | **present, complete** |
| `RimefangPack` | 11 | 11 (row 7k) | **present, complete** |
| `RimefangArena` | 9 | row 7j (redesigned 09-09) | **present** |
| `NoctyssPack` | 14 | 14 (row 7i) | **present, complete** |
| `NoctyssArena` | 23 | row 7h says 2x | **present** |
| `PyreliskPack` | 17 | 17 (row 7o) | **present, complete** |
| `PyreliskArena` | 14 | 14 (row 7n) | **present, complete** |
| `PyreliskHeart` | 22 | 22 (row 7n2, dated **today**) | **present, complete** |
| `WrackPack` | 36 | 36 (commit `f585013`) | **present, complete** |
| `WrackArena` | 10 | row 7g | **present** |
| `KrakenPack` | 17 | 17 (row 7m) | **present, complete** |
| `KrakenArena` | 19 | 19 (row 7m) | **present, complete** |
| `KrakenGullet` | 15 | row 7m | **present** |
| `ArmorPack` | 30 | row 7 | present |
| `IslandPack` 16, `Maelstrom` 9, `RodPack` 216, `WeaponPack` 297, `BoatPack` 53, `FishPack` 135, `CreaturePack` 275 | | | present |

**[M]** Leaf geometry verified: each `<Name>_Node` is a `Model` wrapping exactly one `MeshPart`
named without the `_Node` suffix — e.g. `Brinejaw_Head_Node/Brinejaw_Head [MeshPart]`. That is
exactly what every controller's `pack:FindFirstChild(PREFIX .. name, true)` resolves (recursive,
exact match), and `:IsA("BasePart")` guards the wrapper. **No name-mismatch fallback bug in any
of the seven controllers.** (Kraken specifically: the controller asks for 14 names — `Head, Cap,
Scrollwork, Crust, Eyes, Pupil, Lashes, Barnacles, Eyespots, Siphon, SiphonCore, TentacleSeg,
TentacleTip, TentacleSucker` — all 14 exist in the pack. `RibArch/Polyp/GutStrand` appear in
`FALLBACK_SIZE` only and are never passed to `makePiece`.)

Row 7m's Kraken hold was lifted 2026-09-09: *"IMPORT ALL THREE NOW (hold lifted 2026-09-09 —
the three-phase ship fight is fully wired)"*. Any earlier "do-not-import-Kraken" note is stale.

### Therefore: the fix is code-side, not import-side.

With one live exception worth chasing separately: the Kraken fight is reported to draw a **grey
sphere**. Grey + spherical is `FALLBACK_SHAPE.Head = Ball` at `FALLBACK_SIZE.Head = (97.7,
103.2, 103.0) × SCALE 6` — a ~600-stud ball — which means the fallback branch ran. But if
the *clone* branch ran and merely looked grey, the cause is different and is a real asymmetry:
`WrackBodyController:2360-2375` and `BrinejawBodyController.makePiece` both strip any
`SurfaceAppearance` after cloning (a PBR appearance overrides `Color` outright and renders
default grey), and **`KrakenBodyController.makePiece` (`:362-390`) does not**. That is the one
controller missing the strip. See §4, slice K0.

---

## 1. DIAGNOSIS

### 1.1 The one-line table: what actually draws, and why

| Boss | Rig geometry on screen | Source | Script-built Roblox primitives | Why the primitives exist |
|---|---|---|---|---|
| **brinejaw** | ~109 parts: 6 head pieces + 100 vertebrae + rattle | **Blender meshes** — `packPiece` → `Assets/BrinejawPack` → `Brinejaw_<name>`, pack present | 1 ball bulb, 1 lamp light, 1 ball lure, 1 lure light, **8 Glass spray columns** | the rig cannot leave the tower (§1.3), so the eruption is spray + a peeling tail |
| **old_gnashroot** | 22 body pieces + 2×(5 arm links + hand) | **Blender meshes** — `Assets/GnashrootPack` → `Gnashroot_<name>`, pack present | **~64**: 46 mud/reed/stone slabs, 12 mound slabs, 6 neon eye balls, 1 neon root-knot, 7 lights | the rig's only travel channel is `Rise` (42 world studs); "the mere gathering itself" has no channel |
| **rimefang** | 16 vertebra pairs + head/jaw/fins/fluke | **Blender meshes** — `Assets/RimefangPack` → `Rimefang_<name>`, pack present | **45**: 8 ice slabs, 12 crack strips, 18 shards, 6 heave slabs, 1 lamp, 1 berg light | the whale is 18 studs under a floe mesh for the whole omen, so the omen is drawn on the ice |
| **noctyss** | ~140 parts across 7 stalks | **Blender meshes** — `Assets/NoctyssPack` → `Noctyss_<name>`, pack present | **28 neon vein strips + 9 point lights** | **the boss body is never on screen at all** — deliberate (`NoctyssIntro:5-8`) |
| **pyrelisk** | ~40 pieces (torso/head/jaw/crown/2 arms/7 seams/3 vents/deck) | **Blender meshes** — `Assets/PyreliskPack` → `Pyrelisk_<name>`, pack present | **26**: 1 ash emitter, 1 neon cylinder 1240 studs across, 6 molten sheets, 9 monolith slabs, 9 lights | `Rise` buys 40 studs on a 206.9-stud body; the reveal is a *cut* between two actors |
| **admiral_wrack** | **35 ship pieces** | **Blender meshes** — `Assets/WrackPack` → `Wrack_<name>`, pack present | **18 light-host parts only** (0 `kit.part`, 0 `kit.beam`) | the cleanest of the seven; smoke is `kit.vfx.puff`, not geometry |
| **kraken** | 11 head pieces + **4 uncommanded drifting limbs** | **Blender meshes** — `Assets/KrakenPack` → `Kraken_<name>`, pack present | **84**: 28 sea-wall slabs, 40 tentacle-column blocks, 16 lightning beam-parts | the script explicitly refuses the rig: *"the rig and its path module were being rewritten in the same hour this was written… a cinematic that reaches into a module mid-rewrite fails silently and in the dark"* (`KrakenIntro:19-28`) |

**So the user is both right and wrong, and the distinction is the whole diagnosis.**

- **Wrong** about the bosses: every one of the seven adopts the imported Blender pack. Nothing
  on screen is a "Roblox studio object" *standing in for a boss*.
- **Right** about the cutscenes: **265 Roblox primitives across the seven intros** carry the
  spectacle, and the bosses themselves barely move. Two intros show no whole-boss motion at all
  (Noctyss shows no boss; Kraken's boss is off-frame — §1.2), and the other five move the boss
  through between one and four channels out of eight to twenty available.

The real defect is **rig vocabulary**, not asset plumbing. Every rig was authored for a fight
that happens *in one place* — the boss is already there, and the channels describe posing, not
arriving. So every intro that wants "the boss comes from somewhere" has to fake it with props.

### 1.2 Two real bugs found while tracing

**BUG-1 — Kraken's stand-in is drawn 370 studs off-frame, and the handoff teleports.**
`KrakenIntro:145-150` passes `center = headAt = kit.center + (0,0,-370)` and asserts
(`:139-144`) *"PoseCenter is the HEAD's world position, not the ship's"*.
`KrakenBodyController:33-38` says the opposite in as many words: *"PoseCenter IS THE SHIP, not
the head… the head is derived from it by `KrakenPath.HEAD_OFFSET` and nothing here reads
PoseCenter as a head position."* `KrakenPath.headCenter(state) = shipCenter(state) +
HEAD_OFFSET`, and `drawBody:867` uses it, so the drawn head lands at
`kit.center + (0,0,-740)`. Shots E and F both `look` at `headAt`, so the rig is off-frame for
the entire 24 s, and the real boss — whose `PoseCenter` the server seeds from `creature.anchor`
at `World.WATER_Y`, i.e. the ship — pops 370 studs at the cut. The 84 primitives are the only
thing the player actually sees. **Fix: one line, `center = kit.center`.**

**BUG-2 — Wrack's four gun positions match no piece that exists.** `WrackIntro:99-107` claims
its four points are *"verbatim from WrackBodyController's AUTHORED table"* and names
`CannonBow / CannonStarboard / CannonStern / CannonPort`. The controller's `AUTHORED`
(`:251-270`) has `CannonBowStbd/BowPort/SternStbd/SternPort` at `(±15.19, 13.1–14.1, ±8.57)`.
The intro's points are the **stale pre-09-08 careened layout** — up to 9.7 studs off in Z. Every
muzzle flash, burst and puff of the broadside salute is placed on bearings the ship no longer
has. Also `WrackIntro:331-341` says the `WrackHatches` writes *"are silent today"*; the
controller says the row **landed 2026-09-09 and there are three lids, not four**
(`:2244-2246`), so those writes drive real geometry un-storyboarded, and the fourth
(`mask = 15`) sets a bit with no `Hatch4` behind it.

### 1.3 What each rig CAN animate, and what the script drives

Full channel inventories, with the subset each intro touches. "Level" means the attribute is a
position on a continuum the client eases toward, never an event.

#### brinejaw — 10 channels, 6 driven
`BrinejawBodyController.readTarget:214-231`, `EASE:98-99`.

| Channel | Default | Meaning | Ease | Intro drives? |
|---|---|---|---|---|
| `Coil` | `MAX_COIL`=3 | turns still gripping; counts DOWN | 1.6 | ✅ `0 → 3` over 11.4–14.6 |
| `Unwind` | 0 | 0 coiled, 1 tail fully off | 6.0 up / **0.9 back** | ✅ `1 → 0` over 11.4–14.6 |
| `SweepAngle` | 0 | arm bearing, rad | **55.0** | ✅ `240° → 0°` over 11.4–14.6 |
| `SweepHeight` | `SWEEP_LOW`=1.6 | arm centre above sand | 7.0 | ✅ `-14 → +26` over 9.4–10.35, then `→1.6` |
| `Slump` | 0 | 0 reared, 1 skull on the sand | 5.0 | ✅ `0 → 1` over 13.9–15.0 |
| `FaceAngle` | `BEARING-0.8` | who it watches; clamped to `HEAD_TURN`=125° | 5.0 | ✅ `240° → 296.2°` over 13.4–15.3 |
| `AttackKind` | `""` | `lunge/bite/belltoll/undertow/spiral/coilslam` | raw | ❌ `""` throughout |
| `AttackU` | 0 | phase within the kind | raw | ❌ |
| `AimX`,`AimZ` | 0 | world aim for the attack | raw | ❌ |

**No channel translates the body.** `restPoint` builds everything off `state.center`, and
`adoptBoss:388` reads `PoseCenter` **once**: `BrinejawPath.newState(model:GetAttribute("PoseCenter")
or model:GetPivot().Position)`. There is no per-frame re-read anywhere in the file. So the
serpent is welded to the spire's foot from the frame it is adopted.

#### old_gnashroot — 8 channels, 5 driven
`Rise` (0–1, `RISE_DEPTH`=28 authored / **42 world studs**), `FaceAngle`, `Attack`
(`gnash/wallow/disgorge/heave/mire/hammerfall`), `AttackBlend`, `Strike`, `AimAngle`, `AimSide`,
`Exposed`. Intro drives `Rise 0→0.62→0`, `Attack="heave"`, `AttackBlend 0→0.6`, `Strike 0→0.4`,
`AimAngle/AimSide` once. Never turns `FaceAngle`; never opens `Exposed`.
**Translation:** `state.center = model:GetPivot().Position` **every frame** (`:526`) — so this
rig *could* be walked, but the intro never calls `stand:pivot`.

#### rimefang — 12 channels, 6 driven
`Swim, Submerge, Rise, Roll, Arch, Burst, Skyfall, Beached, FlukeUp, FaceAngle, Gape, Lunge`
(+`Enraged`). Intro drives `PoseCenter, FaceAngle, Submerge, Burst, Gape, Beached, Swim`.
**Never** `Rise, Roll, Arch, Skyfall, FlukeUp, Lunge` — six of twelve, including both remaining
vertical attacks and the entire bank cue.
**Translation: yes, per frame.** `RimefangBodyController:802` — `state.center =
model:GetAttribute("PoseCenter") or state.center`. This is the only one of the seven rigs that
already travels, and the intro already uses it (r 164 → r 30 along a quadratic Bézier).
Arc length is *exactly* `BODY_LENGTH = 56.0` in every pose because `pointAt:799-812` integrates
unit directions: `point += directionAt(state, (i+0.5)*STEP_T) * step`, `STEPS = 24`. The server
hitbox samples the same `pointAt` (`Fn.rimefangBody:5047-5064`).

#### noctyss — 8 stalk channels + 4 maw channels; the maw is never used
Stalk: `SocketIndex, TrueLure, Lean (LEAN_REACH=9.0), BeamAngle, Douse, Grow, Flare, PoseCenter`.
Maw: `MawRise, MawGape, MawYaw, ChoirDown` — **none driven**, by design.
**Translation: impossible.** `stalkCurve:621-628` rebuilds the collar from the socket index
(`SOCKET_R = 34.0`) every call, and `PoseCenter` is read **only at adopt** (`:1370`, `:1431`) —
a grep over all 2386 lines finds no other read. Largest lateral excursion available to anything
in this arena is `LEAN_REACH 9.0` + `SWAY.AMPLITUDE 2.4`.
**`Grow` is now shared, not client-only:** it lives in `NoctyssPath` (`growOf:575`,
`setGrow:585`), is applied inside both `stalkCurve:740` and `bulbPosition:800`, and the server
writes it on real fight stalks during choir regrow (`Fn.choirGrowT:8743`, `K.CHOIR_REGROW = 1.2`
smoothstep, `part.untargetable = grown < 1`). A cutscene may drive `Grow` on a **stand-in** and
must never drive it on a real fight model.

#### pyrelisk — 20 channels, 6 driven
`Rise, FaceAngle, AimAngle, AimSide, Attack, AttackBlend, Strike, Slump, Planted, Stance,
Stances, Exposed, SeamsOpen, SeamsBroken, SeamMeterL, SeamMeterR, PyreliskAct, PyreliskRocks,
PyreliskCore, PoseCenter`. Intro drives `Rise, FaceAngle, AimAngle, SeamsOpen, Attack("ashfall"),
AttackBlend, Strike`.
**Translation: `PoseCenter` is re-read every frame** (`:1196-1199`) — but the intro sets it only
at *creation*, twice: one actor sunk `165.9` studs, destroyed at the ash cut, and a second one
created at true centre behind a flash. The reveal is a **hard cut between two actors**, not a
motion. `Rise` buys 40 studs on a 206.9-stud body, and every hand-down pose is measured to land
on the rim at `Rise 1`, so at `Rise 0` *"every one of them drives the fist forty studs INSIDE
the rock"* — which is why `ashfall` (arms up) is the only attack the intro can legally play.

#### admiral_wrack — 34 channels, 3 driven
Adopted on **`CreatureId`**, not `Pose`: `DUEL.KINDS[model:GetAttribute("CreatureId")]`
(`:2804-2811`), `"admiral_wrack"` = the ship, `"wrack_admiral"` = the act-3 duelist. No
`WrackPath.luau` exists — **[M]** `find src -iname "*wrack*"` returns only the controller and
the intro. All geometry math is inline (`AUTHORED`, `RIG`, `DUEL`).
Intro drives `Exposed=false` (held), `WrackHatches` (4 writes, 3 real), and the pivot by hand.
**Never** `WrackBoom, WrackDive, WrackWreck, WrackRiposte, Weakpoint*`, and never the `"arrive"`
cue. The `cue(model, signal, payload)` hook fires `admHigh/admPoint/admLook/admSweep/admFlick` —
the intro uses two cues out of the fight's full set.
**Translation: unlimited.** The boss *is* its pivot; `stand:pivot(cf)` → `model:PivotTo(cf)`
with no clamp. Wrack is the freest of the seven in translation and the poorest in articulation.

#### kraken — 5 boss channels + 9 per-limb; 3 driven, 0 limb channels driven
Boss: `Rise` (0–1 over `SUBMERGE = 480`), `SiphonOpen`, `PhaseIndex`, `PoseCenter`, `Pose`.
Per-limb (read off separate `kraken_arm` creature models): `ArmPhase` (`Rest/Rear/Slam/
SweepCock/Sweep/Wrapped/Down/Withdrawn`), `ArmPhaseAt`, `ArmT`, `WrapIndex`, `TargetX/Z`,
`Weakpoint/Hot/Pos`, `SocketIndex`.
Intro drives `Rise 0→0.045→0` (one breath), `PhaseIndex=1`, `SiphonOpen=false`. Limbs: nothing.
**And the rig already has the hook the intro refuses.** `KrakenBodyController.setCutscene(fn)`
(header `:44-56`) hands a per-frame frame: `frame.visible`, `frame.head {position, yaw, rise,
gape, roar}`, `frame.tentacles[i] {bearing, radius, rise, curl, tip}`, `frame.ink`. Per-limb
`rise` is **signed −1..1** — *"0 is the waterline, 1 the reared apex over the deck, −1 one
apex-height BELOW the surface"* (`:894-899`) — and *"RADIUS IS NOT CLAMPED, deliberately…
anything short of ~630 studs is a place a limb can honestly be"* (`:901-904`). That is precisely
"limbs rise out of the sea at their real sockets", already built, already exact at the handoff
(§3.7), and unused.

### 1.4 THE BRINEJAW GAP — exactly where it is

The user's beat needs four things:

1. head-first emergence from the sea **at distance**,
2. the rest of the body following **sequentially** through the water plane,
3. a **dragon-like arc** through the air,
4. then **coiling around the lighthouse**.

The script's own header is an honest confession that none of it is expressible:

> "that path has exactly one topology: a serpent wrapped round the lighthouse. At Unwind = 1
> the peel only reaches `blendStart = 1 - 0.40 * unwind` = t 0.6 (BrinejawPath.pointAt), so the
> most of the body that can ever leave the tower is the back 40% — the sweep arm — and the head
> and two coils are on the masonry at every legal value of the ten attributes. There is
> therefore no pose in the vocabulary for 'the chain is airborne over the arena'."

**The peel limit is a bare literal, not a named constant.** `BrinejawPath.pointAt:1351`:

```lua
local blendStart = 1.0 - 0.40 * unwind
local w = smoothstep((t - blendStart) / 0.14) * unwind
```

**[M]** Confirmed by measurement, not by reading: at `unwind = 1`, sweeping t in 0.01 steps and
comparing `pointAt(sweptState,t)` against `pointAt(restState,t)`, the first body position that
moves more than 0.5 studs is **t = 0.61**. The front 61% of the serpent cannot be asked to go
anywhere.

**So where is the gap?** Not in one place — it is four, and this matters for the fix:

| Candidate | Is it the gap? |
|---|---|
| The script | **No.** Given the channel set, the current staging is the best available. The eruption-at-the-arena-edge fallback is the correct reading of the brief's own fallback clause. |
| The 0.40 peel constant | **No, and overriding it would not help.** Raising it to 1.0 would let the whole body peel onto the *swept arm* pose — one straight radial line at `sweepHeight` above the sand. That is a serpent lying flat on a beach, not one flying. The swept pose has no altitude vocabulary beyond a single scalar height. |
| `ChainPose` | **No.** `ChainPose` is already exactly the right machine: `:update` resamples the shape at 160 t-values, accumulates a cumulative-arc-length table, and `:eachN(100, …)` lays 100 links at even arc length along whatever curve it was handed. Hand it a curve that runs from the open sea to the tower and *head-first sequential emergence falls out for free* — it is what walking by arc length means. |
| **The stand-in's position lock** | **Half of it.** `adoptBoss:388` reads `PoseCenter` once and never again, so the "move the whole rig" escape hatch Rimefang has is closed for Brinejaw. But that hatch would be the wrong fix anyway: translating the whole rig rigidly would slide the *coiled* pose across the sea like a prop. |
| **The rig's channel set** | **Yes. This is the gap.** `BrinejawPath` exposes exactly one topology and ten scalars that deform it. There is no parameter whose meaning is *"how far along its journey is this animal"*. |

**Therefore the fix is a new channel, and the channel's shape is a track the body walks.**

---

## 2. THE CONTRACT: an `Entry` channel, one pattern for every chain boss

One new attribute, `Entry`, a **level in 0..1** on the stand-in model. `nil` (absent) means "use
the fight pose"; the fight never writes it. The path module gains an authored **entry spline**
that ends by joining the fight pose's own path, so `Entry` is a position along one joined track,
and at `Entry = 1` the body *is* the rest pose — not close to it, the same arithmetic.

### 2.1 The parametrisation, and why it is the right one

Work in a track coordinate `x`. Let `R(t)` be the existing rest path, `t = 0` snout, `t = 1`
rattle. Define

```
J(x) = R(1 - x)        for x >= 0      -- the rest path, walked TAIL-end first
J(x) = E(-x)           for x <  0      -- the entry spline, E(0) = R(1)
```

and place the body's head at `x_head = A + (1 - A) * Entry`, with the body occupying
`x ∈ [x_head - 1, x_head]` in head→tail order:

```lua
function BrinejawPath.pointAt(state, t)
    local entry = state.entry
    if entry and entry < 1 then
        return BrinejawPath.entryJoined(state, (A + (1 - A) * entry) - t)
    end
    local point = restPoint(state, t)   -- unchanged from here down
    ...
end
```

At `Entry = 1`: `x_head = 1`, so `pointAt(t) = J(1 - t) = R(1 - (1 - t)) = R(t)` — literally the
same call with the same argument. **[M]** Measured anyway, over 2001 samples of t:
`max |pointAt(Entry=1,t) − restPoint(t)| = 3.96e-14 studs`. That is float noise, and it is
structural: the `entry >= 1` guard returns `restPoint` by the *same code path* the fight uses.

**Why the track runs tail-end-first is the insight.** The rest pose's head is at the **top** of
the tower (`HEAD_Y = 60`) and the tail is on the beach (`TAIL_OUT = 31`); the helix ascends as
`t` *decreases*. So walking the rest path from `t = 1` to `t = 0` **is** the path a serpent
climbing the lighthouse head-first would take: beach → up the slack spiral → three turns of
helix → over the gallery → snout. The rest pose is already a record of the arrival. Joining the
entry spline to `R(1)` and walking the whole thing forward gives:

- every vertebra traces the head's exact path, which is what a serpent does;
- head-first sequential surfacing is automatic, because each link crosses the water plane when
  the head-parameter reaches that link's offset;
- "curling around the lighthouse" needs no new geometry at all — the last body-length of the
  track **is** the helix.

### 2.2 Brinejaw's entry spline, authored and measured

**[M]** All numbers below produced by running the real `BrinejawPath.luau` under `luau` (present
at `/opt/homebrew/bin/luau`) with a 20-line `Vector3` stub. Harness:
`/private/tmp/.../scratchpad/runE3.luau`.

Baseline facts measured from the rest pose first:

```
L_rest (2000 samples)                = 288.47 studs
L_rest (160 samples, = ChainPose)    = 288.15 studs
R(0)  snout   r=16.60  y=60.00  bearing=296.2 deg
R(0.11) neck  r= 9.22  y=44.39  bearing=342.0
R(0.74) helix r=11.33  y=12.38  bearing=342.0
R(1.00) rattle r=31.00 y= 3.41  bearing=180.4
arc to t=0.11: 22.6 (7.8%)   0.25: 62.8 (21.8%)   0.50: 139.6 (48.4%)   0.74: 218.8 (75.9%)
```

The spline is authored as **knots in cylindrical (bearing, radius, arena-local y)** — not in
XYZ. This is not style: `BrinejawPath` learned it the hard way twice (`pointAt:1359-1367`, the
slack Hermite at `:900-940`), because a positional lerp between two bearings passes straight
through the masonry — *"Measured worst case, over 24 park bearings: 7.98 studs INSIDE it"* —
while the same interpolation in `(θ, r, y)` never comes nearer than 5.04 studs outside. The
final `r` is clamped `math.max(r, spireRadius(y) + REST.CLEARANCE)`, the same guard the slack
already carries at `:939`.

**`BrinejawPath.ENTRY_KNOTS`** (bearing degrees unwrapped, radius, arena-local y).
Knots 1 and 2 are **computed, not authored** — `cylOf(restPoint(t))` at t = 0.90 and t = 1.00 —
which is what makes the join C¹: knot 1 is the Catmull-Rom ghost that supplies the arrival
tangent, and it is the rest path's own tangent by construction.

```
  {  126.535,  24.590,   5.888 },  -- ghost  = restPoint(t=0.90), computed at load
  {  180.443,  31.001,   3.407 },  -- JOIN   = restPoint(t=1.00), computed at load
  {  196.000,  46.000,  11.000 },  -- head lands on the sand, still moving inward
  {  210.000,  70.000,  38.000 },  -- the descent limb of the arc
  {  224.000,  96.000,  62.000 },
  {  236.000, 122.000,  72.000 },  -- APEX, out over open water
  {  244.000, 146.000,  46.000 },
  {  248.000, 162.000,   0.000 },  -- THE BREACH: crosses the water plane
  {  251.000, 178.000, -20.000 },
  {  262.000, 190.000, -34.000 },
  {  250.000, 196.000, -44.000 },  -- the submerged body is sinuous, which is
  {  264.000, 206.000, -50.000 },  -- how it holds 288 studs of length without
  {  252.000, 214.000, -54.000 },  -- running to r 500
  {  266.000, 224.000, -56.000 },
  {  250.000, 232.000, -58.000 },
  {  268.000, 242.000, -60.000 },
  {  252.000, 252.000, -62.000 },
  {  270.000, 262.000, -64.000 },
```

The arrival bearing 240–270° is kept from the current script for the reason its own `N.sea`
comment gives: the party ring puts a challenger at bearing 0, so the arc sweeps **across** the
camera rather than at it, and the wind-on lands short of where the head rests (342°).

**`Entry` must be re-parametrised by arc length, in units of body-lengths.** This is the step
that makes it work, and it failed without it — the first draft spaced knots by hand-chosen σ and
`chain.length` swung from 546 down to 212 studs as `Entry` advanced (**[M]** `runE.luau`), i.e.
the serpent visibly stretched to double length and then shrank to two thirds. Build the
Catmull-Rom on a uniform auxiliary parameter, integrate its arc length once at load into a
4000-entry table, and define `E(σ)` as the point at cumulative length `σ × L_rest`. Then
`|dE/dσ| = L_rest` by construction.

```
spline total arc length = 782.3 studs = 2.712 body-lengths
breach at sigma = 0.788
A = -(0.788 + 0.10) = -0.888   -- head starts 0.10 body-lengths (29 studs of track) under
Entry -> x_head : x_head = -0.888 + 1.888 * Entry
```

#### Gate results — all pass **[M]**

| Gate | Requirement | Measured |
|---|---|---|
| Body length constant | `chain.length` within ±5% of 288.15 for all `Entry` | **worst +3.30%** (at `Entry` 0.90); range 282.5–297.7 |
| Handoff exact | `Entry = 1` ≡ rest pose | **3.96e-14 studs** over 2001 samples |
| Hidden at `Entry = 0` | highest body point below the water plane | **y = −20.56** (plane at 0.0) |
| Never clips the tower | `r ≥ spireRadius(y) + CLEARANCE` | **min clearance 19.10 studs** |
| Arc reads as a leap | apex above the broken lantern (~64.6) | **apex y = 72.6** (`SPIRE_TOP` 54.0) |
| Sequential surfacing | links breach head-first, evenly spaced | head at `Entry` **0.053**, link 25 at **0.185**, link 50 at **0.318**, link 75 at **0.450**, rattle at **0.583** |

Because the track crosses the water plane exactly once, link *i* (body param `t_i = (i-0.5)/100`)
breaches when `x_head = -σ_breach + t_i`, i.e. at `Entry_i = (t_i - σ_breach - A)/(1 - A)` —
**linear in `i`**. The splash cues are therefore computable at registration, which is what makes
them survive a skip (§2.4).

#### The staging that falls out **[M]**

| `Entry` | head r | head y | head bearing | tail r | tail y | reads as |
|---|---|---|---|---|---|---|
| 0.00 | 178.5 | −20.6 | 251.3° | 229.9 | −57.5 | nothing on screen; 288 studs of serpent under the sea |
| 0.15 | 144.7 | **+48.3** | 243.6° | 219.0 | −55.1 | the head is **airborne**, 48 studs up, 145 out |
| 0.30 | 91.2 | 58.5 | 221.6° | 203.7 | −48.8 | the arc's top, coming in over the water |
| 0.45 | 39.0 | 6.1 | 191.8° | 191.3 | −35.9 | the skull lands on the sand at the tower's foot |
| 0.55 | 19.0 | 7.8 | 100.4° | 172.2 | −13.9 | rearing; the body is still all at sea |
| 0.65 | 11.1 | 15.7 | 206.1° | 150.9 | +34.2 | **first turn on the drum**; the tail is now airborne behind it |
| 0.75 | 10.4 | 25.0 | 242.5° | 121.7 | 72.1 | second turn; the tail is at the arc's apex |
| 0.85 | 9.8 | 35.5 | 278.9° | 84.2 | 52.3 | third turn |
| 0.95 | 9.6 | 45.7 | 321.1° | 50.6 | 15.6 | the neck clears the gallery; the tail crosses the beach |
| 1.00 | 16.6 | 60.0 | 296.2° | 31.0 | 3.4 | **the rest pose, exactly** |

That is the user's beat, in one channel.

### 2.3 What the other bosses get, and what they do NOT need

The `Entry` pattern generalises only where a chain walks arc length. Three of the seven need it,
two already have an equivalent, and two need authored pose sets instead.

| Boss | Needs `Entry`? | Why |
|---|---|---|
| **brinejaw** | **YES — new** | §2.2. The only rig with no travel channel of any kind. |
| **kraken** | **NO — use `setCutscene`** | The hook already delivers per-limb signed rise (−1..1, below the waterline) and unclamped radius. Adding `Entry` would be a second way to do what one code path already does exactly. |
| **rimefang** | **NO — use the fight's own channels** | The under-ice run *is* a fight move: `K.RF_MOVES.icebreach` runs `Submerge = 1` with `PoseCenter` travelling under the sheet, then `Burst 0 → 1`. `PoseCenter` is re-read every frame. An `Entry` spline would also have to be built as an **angle field** through `weights()`/`directionAt`, never a point-lerp, or arc length stops being exactly `BODY_LENGTH = 56` and the server's spine-sampled hitbox leaves the drawn body. Not worth it: the channels already express the beat. |
| **noctyss** | **NO — `Grow` already is `Entry`** | `Grow` is arc-length growth of the stalk curve about its root, applied inside `stalkCurve` and `bulbPosition`. That is the same idea, already shared, already exact at `Grow = 1`. And no `Entry` could help the maw: `PoseCenter` is adopt-only for every Noctyss body. |
| **old_gnashroot** | **NO — authored pose set** | Not a chain. Its lane is authoring an `"emerge"` pose now; the intro should drive that set rather than 64 slabs. |
| **pyrelisk** | **NO — authored pose set** | Not a chain, and 40 studs of `Rise` on a 206.9-stud body means no travel channel can hide it. Its reveal must stay a cut; the fix is what the props become (§3.5). |
| **admiral_wrack** | **NO — `PivotTo`** | Already unlimited translation. |

### 2.4 The constraints every design below respects

- **No new top-level locals in `CreatureService` / `CreatureEventController`** (Luau's 200-local
  register limit; it took the game down 2026-09-06 and is invisible to four of five gates).
  Everything new goes in a table field: `K.<name>` / `Fn.<name>` / `ATTR.<name>`.
- **Attributes are LEVELS, not events.** `Entry` is a position, eased by the client; a late
  joiner reading `Entry = 0.62` mid-run sees the right frame with no history.
- **`Entry >= 0.995` collapses to `nil`** in the controller, so the handoff is enforced by code
  rather than argued from a limit. Specified in §4.
- **`kit.fastForward` must still work.** One-shots are *fired* across a skip (muted for sound,
  shake, flash and decorative vfx; parts, attributes, lights and cards still land), and tracks
  settle at `u = 1`. So **every `Entry` write goes through `kit.track`, never `kit.during`** — a
  `during` is simply not visited after a skip and would leave the serpent mid-air. The splash
  cues go through `kit.at` at registration-computed times, which a skip fires muted.
- **The stand-in's final pose = the rise's first frame**, restated in plain sight in each script
  rather than left implied by where tweens stopped.
- **Wrack adopts on `CreatureId`**, and `kit.actor` writes it *before* parenting, so his adopt
  rides the `ChildAdded` path. Unchanged.

---

## 3. DESIGN — seven choreographies

Each is 12–25 s, shows the whole boss doing something characteristic, and drives Blender
geometry through rig channels. `raiseAt = duration − riseTime` in every case; the last
`riseTime` seconds are the genuine rise under the camera.

**[M]** `riseTime` per boss, read from `Bosses.luau`: brinejaw 4.2, old_gnashroot 3.8,
rimefang 3.8, pyrelisk 6.5, noctyss 4.5, admiral_wrack 4.2, kraken 5.0.

### 3.0 One new kit primitive that fixes the "Roblox objects" complaint everywhere

**`kit.mesh(pack, name, props) -> BasePart`** — clone `Assets/<pack>/<prefix><name>` if it
exists, else fall back to `kit.part(props)`; repaint from `MeshColors.get(prefix .. name)`,
destroy any `SurfaceAppearance`, set `Neon` when the name contains `Glow`, and apply
`Anchored/CanCollide=false/CanQuery=false/CanTouch=false/CastShadow=false` as `kit.part` does.
Also **`kit.meshTween`**, the `kit.tweenPart` equivalent that scales from a stamped `BaseSize`.

This is the established pattern in four places already (`BrinejawBodyController.makePiece`,
`WrackBodyController:2334-2375`, `GnashrootBodyController:246-320`,
`CreatureEventController.K.fxMarker:1777-1800`) and is private to each. Hoisting it into
`CutsceneKit` is what lets every prop below be a Blender mesh rather than a slab:

- **`BrinejawFxPack` is imported (10 objects)** and is exactly the spray/rock/spine vocabulary
  the intros are faking: `Foam, SpoutBase, Crest1, Crest2, Rock1, Rock2, Spike1, Spike2,
  Spike3, Spine`. It is the single highest-leverage asset in this whole redesign.
- Arena packs supply the rest: `RimefangArena_ThinIce/_Bergs` for ice, `KrakenArena_*` for the
  ship, `GnashrootArena_Stump*` and `_DecoMoss` for bank material,
  `PyreliskArena_CrustDeco/_AshDeco` for shed rock.

### 3.1 BRINEJAW — 22 s (row unchanged), `raiseAt = 17.8`

The one the user described. `Entry` is the only new channel; everything else is existing.

| t | beat | camera (kit primitive) | channels | vfx / sfx |
|---|---|---|---|---|
| 0.0–3.6 | **The glassy sea.** Rings on the water, fewer and smaller, then none. Keeper's lamp burning. | `kit.shot` `pos = kit.line(polar(126,38°,cy+8) → polar(104,26°,cy+13))`, `look = lamp`, fov 58, `blendIn 0` | — | `kit.vfx.ring` ×3 as today; `lanternBreak` at 2.95 |
| 2.4–3.3 | the lamp gutters — decaying flicker, not a fade | — | — | `kit.track` on the `PointLight` as today |
| 3.6–5.4 | **The dark tower**, climbing its seaward face | `kit.line(polar(36,24°,cy+15) → polar(31,8°,cy+45))`, `blendIn 0.8` | — | `bossTell` 4.3; `kit.rumble(4.6, 6.2, 0.004)` |
| **5.4** | **the stand-in is born, submerged.** `Entry = 0` is 288 studs of serpent 20 studs under the water plane at r 178–230 — invisible, so no flash is needed to cover it | — | `kit.actor` with `attrs = { Entry = 0, Coil = MAX_COIL, Unwind = 0, SweepAngle = 0, SweepHeight = SWEEP_LOW, Slump = 0, FaceAngle = 240°, AttackKind = "", AttackU = 0, AimX = 0, AimZ = 0 }` | — |
| 5.4–7.4 | **the wake.** The submerged body drives a travelling swell on the surface. Because the body's world position is now known per frame, the swell is computed from it, not authored: sample `pointAt(Entry, t)` at 8 t-values, ring at `(x, waterY, z)` for each whose `y < waterY` | `kit.line(polar(104,250°,cy+16) → polar(150,248°,cy+11))`, `look` = the head's own position, fov 62 | `Entry 0 → 0.045` `kit.track` "inout" | `kit.every(5.6, 7.4, 0.28)` → `kit.vfx.ring(…, 2, 12, 0.9, glass)`; `bossTell` at 6.9 |
| **7.4–8.6** | **THE BREACH.** `Entry 0.045 → 0.16`. The head crosses the water plane at **`Entry = 0.053`** and is 48 studs in the air by 0.15. Sequential surfacing: link 25 at 0.185, link 50 at 0.318, link 75 at 0.450 — the body pours out behind the head over the next 5 s, and every 4th link gets a splash at a registration-computed time | **hard cut, `blendIn 0`**: `kit.line(polar(190,236°,cy+6) → polar(176,244°,cy+34))`, `look` = head position, **fov 74** — low, close, looking up as it comes over | `Entry` "out" | `kit.flash(glass, 0.92, 0.55)`; `kit.shake(0.055,1.0,0.03)`; `bossRise`, `serpentSlam`, `emerge`; `kit.vfx.splash(head, 5)`; **`kit.mesh("BrinejawFxPack","SpoutBase")`** scaled 0→1 at the breach point and 8 **`…"Foam"`** meshes thrown on `kit.meshTween` arcs — replacing the 8 Glass columns |
| 8.6–11.4 | **the dragon arc.** `Entry 0.16 → 0.45`. Apex y = 72.6, above the broken lantern. The head comes down and lands on the sand at r 39 | `kit.orbit(center, 132, 54, 250°, 300°)` — outside everything, 30 studs over the lantern posts — `look` = head position, fov 66, `blendIn 0.9` | `Entry` linear | 25 `kit.at` splashes at the per-link breach times; `kit.rumble(8.6, 11.4, 0.008)`; `serpentSweepHigh` 9.6 |
| **11.4** | **the skull hits the beach** | — | — | `kit.shake(0.075,1.2,0.05)`; `serpentSlam` + `bossDown` at the head; `kit.vfx.puff` + ring in `sandDust`; a **`…"Crest1"`** mesh as the thrown wave |
| 11.4–16.4 | **THE COIL.** `Entry 0.45 → 0.97`. The head rears and climbs: first turn on the drum at 0.65, second at 0.75, third at 0.85, neck over the gallery at 0.95. The tail is still leaving the water until `Entry = 0.583`, so for the first second of the climb the animal is simultaneously on the tower and in the sea — which is the shot | `kit.orbit(center, 78, 46, 300°, 392°)`, `look = (center.X, cy + 20 + 26*smooth(u), center.Z)` — tilting **up** with the climb, the inverse of today's shot 5. fov 64, `blendIn 1.0` | `Entry` "inout"; `Slump` stays 0, `Unwind` 0, `Coil` `MAX_COIL` — the entry branch bypasses all three | `kit.every(11.6, 14.0, 0.24)` splash at the tail's own position while it is still over water; `serpentSweepLow` 13.0; `bossStance` 15.4 |
| 16.4–17.3 | **the settle.** `Entry 0.97 → 1`, then `Slump 0 → 1` over 16.6–17.3. The skull comes down on the sand where the fight's punish window puts it — derived from `slumpPoint`, not eyeballed | `kit.line(polar(70,20°,cy+30) → polar(50,2°,cy+12))`, `look = towerMid:Lerp(slumpSkull, smooth(u))`, `blendIn 1.1` | `Entry`, then `Slump` | `kit.vfx.ring` in sand at the skull |
| **17.3** | **HANDOFF, stated out loud.** `Entry = nil` (attribute removed), `Coil = MAX_COIL`, `Unwind = 0`, `SweepAngle = 0`, `SweepHeight = SWEEP_LOW`, `Slump = 1`, `FaceAngle = REST.BEARING − 0.8`, attack channel clear. `CreatureService`'s entrenched rising branch calls a fresh `BrinejawPath.newState` and writes `slump = 1 − (1 − (1−u)²)`, which is 1 at u = 0 — so this *is* the rise's first frame. 0.5 s early so the slowest ease (`Coil` at 1.6/s) has arrived | — | — |
| 17.8–22.0 | the real rise; the lamp relights **red** | `kit.line(polar(50,2°,cy+12) → polar(54,0°,cy+14))`, `look = slumpSkull:Lerp(rearThroat, smooth(u))`, fov 68 | server-driven | card at `17.8 + 0.85×4.2 = 21.37`; no roar cue from here (`CreatureEventController` already fires one) |

**`Entry` easing.** `EASE.entry = 3.0`/s in the controller. Nothing lethal reads it, so lag is
free and desirable. At 3.0/s a 0.15 step is 99% closed in 1.5 s, so the handoff write at
`raiseAt − 0.5` is **not** enough margin for `Entry` alone — hence the separate `Entry → 1` at
16.4 and the `nil` at 17.3, 1.4 s apart.

**Water-plane surfacing, concretely.** Compute once at registration:

```lua
-- The track crosses the water plane exactly once, so a link's breach is a
-- closed form rather than a per-frame test.
local function entryOfLink(t) return (t - S_BREACH - A) / (1 - A) end   -- S_BREACH = 0.788
for i = 1, 100, 4 do
    local e = entryOfLink((i - 0.5) / 100)
    if e > 0 and e < 1 then
        kit.at(timeOfEntry(e), function()
            local p = BrinejawPath.pointAt(standState(e), (i - 0.5) / 100)
            kit.vfx.splash(Vector3.new(p.X, kit.waterY, p.Z), 1.6)
        end)
    end
end
```

`timeOfEntry` is the inverse of the piecewise `Entry` schedule above — a small table, written
once. Using `kit.at` (not `kit.every`) is deliberate: a skip fires them muted, so no splash is
dropped and no sound stacks.

**The peel constant.** Leave `0.40` alone. `Entry` does not touch it — the entry branch returns
before the unwind blend is reached. If a future cutscene *does* want more peel, the honest form
is `BrinejawPath.PEEL_SPAN = 0.40` plus `state.peelSpan or PEEL_SPAN`, set only by a cutscene.
Not needed here, and adding it now would be an unused channel.

### 3.2 RIMEFANG — 20 s (row 18 → **20**), `raiseAt = 16.2`

No path-module change. The rig already travels and the beat already exists as a fight move.

| t | beat | camera | channels |
|---|---|---|---|
| 0–3.4 | the floe, dead quiet; a shadow **under** the sheet | low over the ice, `kit.line` in from r 180 | `Submerge = 1`, `Swim = 1`, `PoseCenter` walking the authored run-in |
| 3.4–7.0 | **the under-ice run, seen from above.** Replace the 8 neon slabs with **`kit.mesh("RimefangArena","ThinIce")`** clones tinted and pushed down by the body's own depth — the ice *bulges over* the whale instead of glowing | `kit.orbit` at r 150 / y 90 looking straight down, fov 52 | `PoseCenter` per frame; **`Roll`** driven off the curve's turn rate (currently never touched); `Swim 1` |
| 7.0–8.4 | **it turns and dives.** A real dive, using the channel that exists: `Submerge 1 → 1`, `FlukeUp 0 → 1 → 0.45` as it sounds — the fluke breaks the ice | follow the tail; `kit.arc` | **`FlukeUp`** (never touched today) |
| 8.4–11.0 | **THE BURST.** `Burst 0 → 0.55` "out" to the apex at 10.0, `→ 1` "in". `Gape 0.2 → 0.9 → 0`. 22 studs of whale straight up through the sheet | hard cut, low, fov 78, looking up | `Burst`, `Gape` |
| 11.0–12.4 | **the breach arc and the crash.** `Beached 0 → 1`; the sheet is thrown as **`kit.mesh("RimefangArena","Bergs")`** and `…"ThinIce"` shards on ballistic `kit.meshTween`s (`gravity = 42`), replacing 18 primitive slabs | `kit.orbit` 260° → 320° at r 90 / y 40 | `Beached`, `Swim 1 → 0.25` |
| 12.4–14.0 | **the lobtail.** `FlukeUp 0 → 1` and down — the hammer blow the fight opens with, shown once so the player knows it | ground level behind the party mark | **`FlukeUp`** |
| 14.0–15.6 | it slides back into the lead | `kit.line` out and up | `Submerge 0 → 1`, `Beached 1 → 0`, `Swim 0.25 → 1`, `PoseCenter → kit.center`, `FaceAngle → 0` |
| **15.6** | **HANDOFF** = `Fn.rimefangDrive`'s rising frame: `Submerge = 1`, `Swim = 1`, `FaceAngle = yaw0`, `PoseCenter = Fn.rimefangCenter(state, creature.pos)`, and `Rise/Roll/Arch/Burst/Skyfall/Beached/FlukeUp/Gape/Lunge = 0` | — | — |
| 16.2–20.0 | the real rise | party's eye height | server |

**Why 18 → 20 s:** the dive and the lobtail are two new beats and 18 s has no room. `duration`
is the per-boss script author's own field.
**Channels newly used:** `Roll`, `FlukeUp`. **New rig work: none.**

### 3.3 NOCTYSS — 22 s (row 20 → **22**), `raiseAt = 17.5`

**No path-module change at all** — and this is worth stating plainly, because it is the one boss
where the existing channels already say everything. `Grow` *is* an entry channel; `MawRise` is
the arrival.

The one change of intent: the brief says *"we can actually see all of the bosses before we fight
them"*, and today you never see Noctyss. So the maw comes up.

| t | beat | camera | channels |
|---|---|---|---|
| 0–3.4 | black, then one lantern far down in the pit | held, fov 60 | `pitLight` as today |
| 3.4–7.2 | her back moves, under the water | `kit.orbit` over the rim | the `shudder` cue |
| 7.2–12.6 | **the choir arrives**, seven stalks one at a time, `Grow 0 → 1` over 0.85 s each, `Douse 1 → 0`. Replace the 28 neon vein strips with **`kit.mesh("NoctyssArena","DecoVeins")`** clones lit by transparency | descending into the pit, `kit.line` | `Grow`, `Douse` per stalk (stand-ins only — never on a real fight stalk) |
| 12.6–14.0 | the choir turns its lanterns over the mouth | slow push in | `BeamAngle → socketBearing + π`, `Lean 0 → 0.55` |
| **14.0–16.4** | **SHE RISES INTO THE LIGHT.** `MawRise 0 → 0.45` over 2.4 s, `MawGape 0 → 0.7`, `MawYaw` swinging onto the party. At `MawRise = 0.406` the skull's origin is at arena-local y −3.6 and the jaws breach the rim (`NoctyssPath.SNAP.RISE_TO`, from `MAW.Y_DOWN = −20.0` / `MAW.Y_UP = 20.4`). The pit water plane is `GL_PIT_WATER_Z = −5.0`, which is `smoothstep(mawRise) = 0.371`, i.e. **`MawRise ≈ 0.415`** — so 0.45 puts the jaws clearly out of the water and nothing else. **The fight's own maw geometry, 40 pieces of it, doing the one thing it does.** | hard cut to the rim, looking down into the pit, fov 74; then pull back as she fills the frame | **`MawRise`, `MawGape`, `MawYaw`** — all three currently never touched |
| 16.4–17.2 | **the chord**, not a roar. She sinks back. `MawRise 0.45 → 0`, jaws shut | rising out of the pit | `MawRise → 0`, `MawGape → 0`, `Flare` stamped on every stalk |
| **17.2** | **HANDOFF:** `MawRise = 0`, `MawGape = 0`, `MawYaw = authored(LANES[1]) = 56°`, and per stalk `Grow = 1, Lean = 0, Douse = 0, BeamAngle = socketAngle(i)` — `NoctyssPath.newState`'s defaults. Note the rising branch publishes **only** the three maw channels for this boss, so `state.rise` is written server-side and read by nothing | — | — |
| 17.5–22.0 | every lantern doused at once so the card lands on black, then relit | held | `Douse 0 → 1 → 0` |

**The one hazard, called out:** the real choir is planted only at `u >= 1`, i.e. at `duration`.
The existing retirement logic (armed by `kit.onRealBoss`, spent by a real `choir_stalk`
appearing **or** by the kit's teardown) is correct and must be kept verbatim.
**Correction to a lane claim:** there is no `MawRise = 0.31` constant anywhere. The only
under-shelf thresholds are `MAW_HIT_RISE = 0.15` and the audio crossings 0.12 / 0.05. Use
0.415 as the waterline and 0.406 as the rim.

### 3.4 OLD_GNASHROOT — 22 s (row unchanged), `raiseAt = 18.2`

Not a chain. Its lane (session 30) is authoring an `"emerge"` pose set now, so this design is
written **against that set** and lists exactly what it must contain.

The rig *can* be walked — `state.center = model:GetPivot().Position` every frame — and the intro
never does. That is the whole opportunity: a mud colossus should **drag itself out of the mere**,
across the peat, and stand up. Two channels, one of them free.

| t | beat | camera | channels |
|---|---|---|---|
| 0–4.6 | bubbles on the black mere; something below | low across the water | — |
| 4.6–7.0 | **the mere gathers.** Keep this beat but swap the 46 primitive slabs for **`kit.mesh("GnashrootArena","DecoMoss")`** and `…"Stump1..4"` clones rising and sliding inward — bank material that already exists in the arena pack | `kit.orbit` at r 90 | — |
| **7.0** | stand-in born **submerged and off-centre**: `stand:pivot(CFrame.new(kit.center + polar(46, 210°)))` with `Rise = 0` (42 world studs down, fully buried) | — | `Rise = 0`, `FaceAngle = 210°` |
| 7.0–11.4 | **IT CRAWLS.** `Rise 0 → 0.34` (head and shoulders only) while `stand:pivot` walks it from r 46 to r 12 along the bank. `Attack = "heave"`, `AttackBlend 0 → 0.8`, `Strike` pulsing 0 → 0.5 → 0 twice — **the two arms hauling, one per pull**, with `AimSide` flipping between them. This is the rig's `heavePlant`/`heaveBrace` poses doing the thing they were authored for | tracking alongside at head height, `kit.line`, fov 66 | `Rise`, pivot, `Attack`, `AttackBlend`, `Strike`, `AimSide` |
| 11.4–13.0 | it reaches the bank's lip and **stops being a mound**. `Rise 0.34 → 0.78`; the six eye pairs open — but on the rig, not on props: `"emerge"` must expose the eye row as part of the pose rather than needing 6 neon balls | low, looking up, fov 72 | `Rise`, `AttackBlend 0.8 → 0` |
| 13.0–15.4 | **it stands.** `Rise 0.78 → 1.0`, `FaceAngle 210° → 0°` — it turns and looks at the party, which today it never does | `kit.orbit` 240° → 330° at r 74 / y 40, tilting up | `Rise`, **`FaceAngle`** |
| 15.4–17.0 | one `"gnash"` at nothing — the jaw works, which `heave` alone can never show (`JAW_MAX = rad(38)`, and gape is derived and nonzero only for `gnash/disgorge/hammerfall`) | close on the head | `Attack = "gnash"`, `AttackBlend 0 → 1 → 0`, `Strike 0 → 1` |
| 17.0–17.9 | **it sinks back.** `Rise → 0`, pivot → `kit.center`, `Attack = ""`, `AttackBlend = 0`, `Strike = 0`, `FaceAngle = 0`, `AimSide = 1`, `Exposed = false` | pulling out | — |
| **17.9** | **HANDOFF.** `Fn.gnashrootPublish` writes `rise = 1 − (1 − modeProgress)³`, i.e. **`Rise = 0`** at u = 0, with the pivot held at `−submerge` and **zero pitch** (`CreatureService:18194-18209`, the `def.rig == K.GN_RIG` branch). Note: the current `GnashrootIntro` header claims the first frame is `poseCFrame(creature, −riseDepth, 0, rad(−20))` — **that is the generic `else` branch, not the rig branch, and it is stale.** 0.3 s of margin for the rig's ~0.42 s lag | — | — |
| 18.2–22.0 | the real rise | party mark | server |

**New rig work:** the `"emerge"` pose set must contain (a) a low crawl silhouette at
`Rise ≈ 0.3` whose arms reach *forward* rather than sideways, and (b) the eye row as pose
geometry. Owned by session 30 — this design consumes it, does not author it.
**Props deleted:** 46 mud slabs, 12 mound slabs, 6 eye balls, 1 root knot = **65 primitives
gone**, replaced by ~12 arena-pack meshes and the rig itself.

### 3.5 PYRELISK — 26 s (row unchanged), `raiseAt = 19.5`

The hardest case and the only one where the honest answer is "the props stay, but they become
meshes". `Rise` is 40 studs on a 206.9-stud body, so there is no arrival to animate: at `Rise 0`
it is still a 167-stud mountain standing in plain sight. The reveal has to remain a **cut**.

What changes is (a) what the props are made of, (b) that the colossus *moves* before the fight
instead of shrugging twice, and (c) the camera admits the scale instead of hiding it.

| t | beat | camera | channels |
|---|---|---|---|
| 0–5.0 | the caldera, ash falling. Replace the 464×4×464 ash slab with a **`ParticleEmitter` on a `kit.mesh("PyreliskArena","CloudDeco")`** clone | `kit.line` along the rim, fov 58 | — |
| 5.0–9.2 | the lava lake breathes. The 1240-stud neon cylinder **stays** — it is the one prop with a stated engineering reason (*"a PointLight cannot do this — Roblox caps Range at 60 studs and the deck is 1200 across"*) and no mesh substitutes for it | `kit.orbit` at r 300 | — |
| 9.2–13.4 | **the two shrugs**, unchanged in timing: `Rise 0.28 → 0.62 → 1.0`. Replace the 6 neon molten sheets with **`kit.mesh("PyreliskArena","CrustDeco")`** clones sliding off the shoulders on `kit.meshTween` — shed rock that is actually rock | pushing in, fov 38 | `Rise`, `FaceAngle`, `AimAngle` |
| **13.55** | the ash cut: destroy the sunken actor, create the standing one at true centre behind `kit.flash` + `kit.vfx.shockwave` | **hard cut, no `blendIn`** | — |
| 13.55–16.0 | **it walks.** One step. `PoseCenter` is re-read every frame, so drive it: the body advances 46 studs along the rim path over 2.4 s while `Attack = "handfall"` plants one fist at `Rise 1` — where every hand-down pose is *measured* to land on the rock — and `AimSide` picks the other for the next. A 207-stud colossus taking a single step is the whole character | ground level at the rim, looking up past the knee, fov 80 | **`PoseCenter`** (new use), `Attack = "handfall"`, `AttackBlend`, `Strike`, `AimSide` |
| 16.0–18.2 | **the seams open**, `SeamsOpen 0 → 1 → 7 → 127`, and `Attack = "ashfall"` — arms up, the pose the intro already uses because it is the only one legal at the handoff. The 9 monolith slabs become **`kit.mesh("PyreliskArena","Teeth")`** clones | `kit.orbit` 280° → 340° at r 320 / y 180 | `SeamsOpen`, `Attack`, `AttackBlend`, `Strike` |
| 18.2–19.3 | arms down, seams reseal `127 → 7 → 1 → 0`, `PoseCenter → kit.center` | settling | — |
| **19.3** | **HANDOFF:** `Rise = 0`, `Slump = 1`, everything else cleared. `CreatureService:18175-18176`, the entrenched branch: `state.rise = 1 − (1−u)³`, `state.slump = 1 − (1 − (1−u)²)` — at u = 0 that is exactly `Rise 0, Slump 1`. (The current intro's citation of `:15594-15595` is stale.) | — | — |
| 19.5–26.0 | the real rise, 6.5 s of a mountain standing up | party mark, fov 74 | server |

**The one honest limit, stated:** `PoseCenter` must return to `kit.center` before the handoff,
because the server seeds the real body from `creature.anchor`. A step *out and back* is the only
travel shape available. Say so in the script header rather than letting a future author try to
walk it in from the horizon.

### 3.6 ADMIRAL WRACK — 22 s (row 20 → **22**), `raiseAt = 17.8`

Already the cleanest intro — 35 Blender pieces, zero `kit.part`. What it lacks is articulation:
3 channels driven out of 34. Wrack can be translated arbitrarily and posed barely, so the
choreography is **the ship sails in** and the Admiral is *conducted* through the cues.

| t | beat | camera | channels |
|---|---|---|---|
| 0–5.4 | the tide goes out; the ghost fleet's hulls light one at a time | `kit.line` along the beach | 12 lights as today |
| **5.4–11.0** | **SHE SAILS IN THROUGH THE MOUTH.** `stand:pivot` walks the ship from r 190 on the 46°-wide mouth bearing (90°) to r 0, riding a swell: `y = waterY − 9 + 3·sin(2πt/2.6)` and a 6° roll on the same phase. Because she is one `PivotTo`, this is free — and it is the beat the fight can never show, since the fight's ship is bedded in the shoal | low on the water at the mouth, `kit.line` in to meet her, fov 70; then `kit.orbit` alongside | pivot; **`WrackBoom`** swinging with each tack (never driven today) |
| 8.0–11.0 | **the gunports run out, deck by deck**, `WrackHatches 1 → 3 → 7`. **Three lids, not four** — `mask = 15` sets a bit with no `Hatch4` and must be dropped | tracking the starboard side | `WrackHatches` |
| 11.0–13.2 | **she takes the ground.** `pivot` heaves her onto the shoal, the bow lifting: the existing `place(e)` heave curve `1 − (1−u)³`, but arrived at rather than sprung from nothing | from the beach, looking up the bow | pivot |
| 13.2–14.6 | **the Admiral appears on the quarterdeck.** Fire the **`"arrive"`** cue — the intro has never used it — then `"windup"` with `aim = kit.polar(88, 0, floorParty + 4)`, which drives `admArrive*`, `admHigh`, `admPoint`, `admLook` | close on the quarterdeck, fov 50 | `cue("arrive")`, `cue("windup")` |
| **14.8** | **the broadside salute.** `cue("fire", {})` → the radial case, so `gunRecoil` + `muzzleFlash` on every live deck, plus `admSweep` + `admFlick`. **Fix the four gun positions first** — use the controller's real muzzle table (`CannonBowStbd/BowPort/SternStbd/SternPort` at `(±15.19, 13.1–14.1, ±8.57)`, muzzles from `:567-586`), not the stale 4-bearing layout | wide, from the beach, fov 84 | `cue("fire")` |
| 14.8–16.4 | smoke rolls off her — `kit.mesh("WrackArena","DecoSailRag")` clones tumbling, plus the existing `kit.vfx.puff` | pulling back through the smoke | — |
| 16.4–17.4 | **she settles back.** The existing `settle` track walks `e` to 0 so the pivot reaches the rise's u = 0 pose. `WrackHatches → 0` (the real boss arrives with them shut — today the intro leaves them **open** at the cut, which is a visible pop) | held | pivot, `WrackHatches` |
| **17.4** | **HANDOFF:** `pivot = poseCFrame(creature, −22, 0, rad(−20))`, `Exposed = false`, `WrackHatches = 0`. The plain-boss `else` branch at `CreatureService:18211`: `PivotTo(poseCFrame(creature, −riseDepth + (riseDepth + sub)·e, 0, rad(−20)·(1−e)))` with `sub = −2.8`, `e = 1 − (1−u)³`. `place(0)` reproduces it exactly | — | — |
| 17.8–22.0 | the real rise | party mark | server |

**Also fix the prose bug:** the header says `groundDrop` is `0.5` for a kit stand-in; the code
uses `−C.rootHalf` = **−0.5**, which is correct (the box bottom is below the pivot).
**Channels newly used:** `WrackBoom`, the `"arrive"` cue, `WrackHatches` at the handoff.
**New rig work: none.** Everything above already exists in the 34-channel table.

### 3.7 KRAKEN — 24 s (row unchanged), `raiseAt = 19.0`

The biggest single win in the redesign: **84 primitives and 4 ghost limbs collapse into the rig
the controller already documents.**

Two fixes first (§4, slice K0): `PoseCenter = kit.center`, and install the `setCutscene` hook.
(The `SurfaceAppearance` strip was the grey-sphere fix and **has since landed in that lane** —
`KrakenPath`'s cutscene contract, `setCutscene` / `landmark` / the frame shape / the
`HEAD_HEIGHT` seam, is unchanged by it.)

**`PoseCenter` MUST stay the SHIP centre — this is now enforced, not merely documented.**
The client reconciles the published `PoseCenter` against `BossArenas.maelstrom.center`
(`shipCentreFrom` in `KrakenBodyController`) and treats a value more than 2000 studs away as
authoritative on purpose — that is the **gullet exemption**, the one legitimate case of a
far-flung centre. A stand-in that publishes the *head* (BUG-1) is therefore not just 370 studs
wrong, it is wrong in a way the reconciliation cannot rescue, because 370 is under the 2000
threshold and reads as a ship centre that has drifted. So: **the cutscene publishes the ship
centre and nothing else, ever — never the head, never a limb socket.** All entry motion is
expressed as `frame.tentacles[i].{bearing, radius, rise}` and `frame.head.rise`, which are
*relative to that centre by construction* (`headCenter = shipCenter + HEAD_OFFSET`;
`rootPosition` builds off `headCenter`). There is no case in this design where `PoseCenter`
moves at all.

**`setCutscene` is exactly the entry channel this boss needs, and it is already exact at the
handoff.** The guarantee is a *one-code-path* guarantee, not a pose constant
(`KrakenBodyController:82-91`): the frame is built and consumed every frame whether or not a
cutscene is set — one `if cutscene then cutscene(frame) end` between building it and writing it,
with **no second branch that computes the pose a different way**. The head goes through
`KrakenPath.headFrameAt(position, rise, yaw)`, the same call on the same three numbers the fight
uses; a limb whose polar fields come back **bit-unchanged** (compared against the exact values
written, not against a tolerance) keeps its computed curve untouched, and only a *mutated* limb
pays a polar round-trip. So leaving a limb alone draws the fight's curve, and mutating one goes
through `armPoint`'s `tipOverride` seam (`:846-856`), which moves `p3` and carries `p2` by the
same delta — *"which preserves the pose's arrival direction and its handle length, so a driven
limb bends the way this limb bends rather than becoming a different animal's arm."*

**The bend law each entry curve must satisfy** (`KrakenPath:875-905`, verbatim in part):

> THE LAW: at every u the DRAWN centreline's radius of curvature must beat the limb's own
> half-thickness there — `girthAt(u)`, 24 studs at the shoulder tapering to 6.7 at the tip —
> with 10% margin. […] Worst ratio `R_min / (1.1 * girth)`, so 1.00 IS the bound:
> Rest 1.23, Rear 2.90, Slam 1.40, SweepCock 1.50, Sweep 1.40, **Wrapped 1.08**, Down 2.02,
> Withdrawn 5.45.

`girthAt(u) = GIRTH × (1 − TIP_GIRTH × u)`, `GIRTH = 24`, `TIP_GIRTH = 0.72`;
`bendRadius = |d1|³ / |d1 × d2|` with analytic Bézier derivatives.

**How each entry curve satisfies it — by construction, not by hope.** Do *not* author a free
under-sea spline. Instead drive only the three polar fields the frame already exposes:

```
frame.tentacles[i].rise    signed -1..1   (-1 = one apex-height below the surface)
frame.tentacles[i].radius  unclamped      ("anything short of ~630 studs")
frame.tentacles[i].bearing
```

A limb's *curve shape* then remains whichever `ArmPhase` pose it is in — `Rest` at 1.23 of the
bound, `Rear` at 2.90 — and `rise`/`radius`/`bearing` are a **rigid re-aim of an already-proven
pose**, not a new curvature. The only curvature the cutscene introduces is via `tipOverride`,
which is the same seam the fight uses and which preserves handle length. So the entry motion
inherits the swept pose's own margin.

Two residuals to respect: `KrakenPath:906-932` states *"the Rear → Rest CROSSFADE bottoms at
0.59 of the bound at its 80% mark"* — so **no limb may crossfade Rear → Rest during the
cinematic**; hold `Rear` and cut, or pass through `Down` (2.02). And `HANDLE_ROOT`'s comment says
*"0.42 is measured, not chosen"* while the constant on the next line is `0.55` — **[UNVERIFIED]**,
flagged for its owner.

| t | beat | camera | channels |
|---|---|---|---|
| 0–3.4 | the ship alone in a flat calm, lamps lit | `kit.orbit` at r 200 / y 40 | `frame.visible = false` |
| 3.4–7.4 | **the sea stands up.** Keep the 28-slab wall — it is *the sea*, and no pack has a wave mesh — but drop the height to `WALL_H 118` only on the far arc and use **`kit.mesh("KrakenArena","Foam")`** clones along the near crest so the wall has a legible edge | `kit.line` up from the deck | — |
| **7.4–13.0** | **FOUR LIMBS RISE OUT OF THE SEA, AT THEIR REAL SOCKETS.** Per limb *i*, staggered 1.1 s apart: `rise −1 → +0.85` over 1.8 s, `radius 420 → 150`, `bearing` swinging onto the hull, `ArmPhase` held at `Rear`. Because `rise = −1` is one apex-height below the surface and `REAR_LIFT = 260`, each limb genuinely climbs out of the water at its own mantle socket (`ROOT_LATERAL = {−33, −11, 11, 33}`, `ROOT_FORWARD = 36`) instead of being a column on a decorative ring. `frame.visible = true` from the first limb | low on the deck, `kit.orbit` 250° → 340° at r 150 / y 60, fov 76; then a hard cut to the rail looking up | `setCutscene` frame: per-limb `rise/radius/bearing`; `frame.head.rise = 0` |
| 13.0–15.4 | **the head comes up.** `Rise 0 → 0.10` — with `SUBMERGE = 480`, 0.10 is 48 studs, so the crown breaks the surface off the port beam while the limbs are already on the rail. `frame.head.gape` via **`SiphonOpen = true`** (never opened today), and `frame.head.roar` on the beat | pulling back to take in head + four limbs + ship in one frame, fov 90 | `Rise`, `SiphonOpen`, `frame.head.roar` |
| 15.4–17.6 | **one limb sweeps the deck** — `ArmPhase = Sweep` at 1.40 of the bound — and withdraws. The player sees the fight's actual opening move once | deck level, tracking the limb | per-limb `ArmPhase`, `ArmT` |
| 17.6–18.6 | limbs sink back: `rise → −1`, `radius → 420`; head `Rise → 0`; `SiphonOpen = false`. **Pass through `Down`, never crossfade `Rear → Rest`** | rising out | — |
| **18.6** | **HANDOFF.** `frame` left unmutated → the rig draws the fight's exact arithmetic (§3.7 above). `Rise = 0` puts the crown **on** the waterline, which is `SUBMERGE`'s own definition and the rise's u = 0 frame: `Fn.colossusState(creature, def).rise = e`, `e = 1 − (1−u)³`, no pivot motion. `PhaseIndex = 1`, `SiphonOpen = false`, **`PoseCenter = kit.center`** | — | — |
| 19.0–24.0 | the real rise, 5 s; the four arm creatures appear at `u >= 1` (`Fn.spawnBossParts`) and `claimArms` seats them | party mark | server |

**Props deleted:** 40 tentacle-column blocks and 16 lightning beam-parts = **56 primitives
gone**, plus the 4 uncommanded drifting limbs now commanded. 28 sea-wall slabs stay.

---

## 4. IMPLEMENTATION PLAN

### 4.1 Ownership — who may touch what, today

| File | Owner | Note |
|---|---|---|
`src/Client/Modules/CutsceneKit.luau` | **cutscene lane (session 30)** | hot; `kit.mesh` lands here |
`src/Client/Controllers/BossCutsceneController.luau` | cutscene lane (30) | no change needed |
`src/Shared/Data/BossCutscenes.luau` | cutscene lane (30) | three duration rows change |
`src/Client/Cutscenes/GnashrootIntro.luau` | cutscene lane (30) | |
`src/Client/Cutscenes/PyreliskIntro.luau` | cutscene lane (30) | |
`src/Client/Cutscenes/{Brinejaw,Rimefang,Noctyss,Wrack,Kraken}Intro.luau` | **this lane** | |
`src/Shared/Modules/BrinejawPath.luau` | **unowned** — take it | the only new rig work |
`src/Client/Controllers/BrinejawBodyController.luau` | unowned | `EASE.entry`, `readTarget` |
`src/Shared/Modules/PyreliskPath.luau`, `PyreliskBodyController.luau`, `assets/boss_gen.py` (pyrelisk) | **session 71, mid-remodel** | **do not touch** — Pyrelisk design needs none of them |
`src/Shared/Modules/GnashrootPath.luau`, `GnashrootBodyController.luau`, `boss_gen.py` (gnashroot) | **session 30, mid-redesign** | **do not touch** — the `"emerge"` set is theirs to author |
`src/Shared/Modules/RimefangPath.luau` | session 00 | **no change needed** |
`src/Shared/Modules/NoctyssPath.luau` | session c1 | **no change needed** |
`src/Shared/Modules/KrakenPath.luau`, `KrakenBodyController.luau` | **sessions 72 / 8e, mid-edit** | coordinate; K0 is 3 small edits |
`src/Client/Controllers/WrackBodyController.luau` | this lane | worktree-only |

**Shared-checkout rules apply:** explicit-path commits only, never `git add` a file another
session is editing, `&&` not `;`, no `--amend`, symbol-set diff before every commit.

### 4.2 Slices — each ends playable

Ordered so Brinejaw is written and reviewed first.

**Slice 0 — `kit.mesh` (CutsceneKit, cutscene lane)**
Add `kit.mesh(pack, name, props)` and `kit.meshTween`, lifting the clone-or-fallback pattern from
`BrinejawBodyController.makePiece`. No caller yet. *Verify:* five gates; a Studio run of any
existing intro is byte-identical (nothing calls it).

**Slice B1 — Brinejaw: the `Entry` channel (BrinejawPath + BrinejawBodyController)**
- `BrinejawPath.ENTRY_KNOTS` (§2.2), `ENTRY_A = -0.888`, `ENTRY_BREACH = 0.788`.
- `BrinejawPath.entryLength()` — arc-length table built once, lazily, 4000 entries.
- `BrinejawPath.entryJoined(state, x)` and the 3-line guard at the top of `pointAt`.
- `readTarget`: `target.entry = model:GetAttribute("Entry")`; `EASE.entry = 3.0`; in `drawBody`,
  `if target.entry == nil or target.entry >= 0.995 then state.entry = nil else state.entry =
  approach(state.entry or 0, target.entry, EASE.entry, dt) end`, and collapse to `nil` once
  `state.entry > 0.995`.
- **No new top-level locals** — all of it hangs off `BrinejawPath.*`.
*Verify:* five gates, **plus** the measurement harness re-run as a unit check: the six gates in
§2.2's table, asserted. `Entry` absent ⇒ the fight is bit-identical (the `pointAt` guard returns
`restPoint` on the same path). Studio run: summon Brinejaw with no cutscene row and confirm the
fight is unchanged.

**Slice B2 — Brinejaw: the choreography (BrinejawIntro)**
Rewrite against §3.1. Delete the 8 Glass columns; add `kit.mesh` spray. *Verify:* Studio run must
show — nothing on screen before 7.4; the head breaching at r ~178 with the body still submerged;
25 splashes marching tail-ward; the apex above the lantern; three distinct turns on the drum; the
skull settling into the fight's punish spot; and **no pop at 17.8**. Skip-test at t = 2, 8, 13,
16: each must land on the slumped pose with no serpent left in the sea. Late-join at t = 12 must
show a mid-climb serpent, not a coiled one.

**Slice K0 — Kraken: the two remaining fixes (KrakenIntro + KrakenBodyController)**
`center = kit.center` (so `PoseCenter` is the ship, which `shipCentreFrom` now reconciles
against `BossArenas.maelstrom.center`), and install `setCutscene` with a no-op. The
`SurfaceAppearance` strip has already landed in the owning lane — do not re-apply it.
*Verify:* the drawn head is at `kit.center + HEAD_OFFSET`, on frame, in both shots E and F;
`shipCentreFrom` does not warn or correct; the grey sphere is gone (it should already be).
Coordinate with sessions 72 / 8e first.

**Slice K1 — Kraken: the choreography (KrakenIntro)** — §3.7. Delete 56 primitives.
*Verify:* four limbs rising at their sockets, not on a ring; no `Rear → Rest` crossfade anywhere;
the bend-law sweep re-run over the driven `rise/radius/bearing` ranges; handoff with an
unmutated frame.

**Slice R1 — Rimefang: the choreography (RimefangIntro + BossCutscenes row 18 → 20)**
§3.2. No path change. *Verify:* `Roll` and `FlukeUp` visibly driven; the ice meshes replace the
neon slabs; the handoff frame equals `Fn.rimefangDrive`'s rising frame.

**Slice N1 — Noctyss: the maw rises (NoctyssIntro + row 20 → 22)**
§3.3. No path change. *Verify:* the maw clears the pit water at `MawRise ≈ 0.415` and the rim at
0.406; the choir retirement logic is untouched; nothing drives `Grow` on a real `choir_stalk`.

**Slice W1 — Wrack: she sails in (WrackIntro + row 20 → 22)**
§3.6, including the gun-position and hatch-count fixes. *Verify:* muzzle flashes land on the four
real bores; `mask = 15` is gone; hatches shut at the cut; the pivot at `raiseAt` equals
`place(0)`.

**Slice G1 — Gnashroot: it crawls out (GnashrootIntro, cutscene lane)** — blocked on session 30's
`"emerge"` set. §3.4.

**Slice P1 — Pyrelisk: one step (PyreliskIntro, cutscene lane)** — §3.5. Touches no session-71
file.

### 4.3 Verification, per slice

**The five gates**, every slice. Gate five (`luau-compile -O0`) is the only one that sees the
200-local limit and is therefore non-optional on any file touching `CreatureService` or
`CreatureEventController` — none of these slices do, but `BrinejawPath` is 1980 lines and one
more top-level local there is a real risk, so it is checked anyway.

**A Brinejaw-specific sixth gate** that is worth adding permanently, because every number in
§2.2 came out of it and a future knot edit would silently break the body length: run
`BrinejawPath` under `luau` with a `Vector3` stub and assert the six gates. It is ~60 lines,
needs no Studio, and catches exactly the class of defect this codebase keeps hitting — a value
that is right in one file and stale in another.

**What a Studio run must show**, per boss: listed inline in each slice above. In every case the
universal three are (1) no pop at `raiseAt`, (2) a skip at four points lands on the handoff pose
with nothing orphaned, (3) a late join mid-run shows a sane frame.

---

## 5. Open questions and every number I could not verify

1. **[UNVERIFIED] The arena-local waterline.** Every Brinejaw y above is arena-local with the
   water plane at **0.0**, on the assumption `kit.center.Y == World.WATER_Y` for the tropical
   arena. The script must use `kit.waterY - kit.center.Y` and not the literal. If that is not
   ~0, the breach σ moves and `A` must be re-solved — one harness re-run.
2. **[UNVERIFIED] Does the ocean render at r 262?** The submerged tail knots reach r 262 from
   the arena centre. Nothing is *visible* there at `Entry = 0` (all below the plane), but if the
   ocean slabs stop short the body would be seen in open air at r > some radius. Sea stacks stop
   at r 86 and the current camera goes to r 118, so r 262 is untested ground.
3. **[UNVERIFIED] `L_rest = 288.47` is state-dependent.** Measured at `newState` defaults. It
   shifts with `Coil` (via `coilOffset`) and `Slump`. The design holds `Coil = MAX_COIL` and
   `Slump = 0` throughout the entry, so it is the right number *there* — but the ±5% length gate
   should be re-run at `Coil = 0` before anyone drives `Coil` during an entry.
4. **[UNVERIFIED] `Entry` at 3.0/s is a guess.** It is a feel number. Nothing lethal reads it.
5. **RESOLVED — the Kraken grey sphere.** Its own lane found and fixed it; the cutscene contract
   (`setCutscene` / `landmark` / frame shape / `HEAD_HEIGHT`) is unchanged. Slice K0 shrinks to
   two edits. The new constraint it introduced — `shipCentreFrom` reconciling `PoseCenter`
   against `BossArenas.maelstrom.center`, with a >2000-stud value treated as the gullet
   exemption — is encoded in §3.7.
6. **[UNVERIFIED] `KrakenPath.HANDLE_ROOT`** — prose says *"0.42 is measured, not chosen"*, the
   constant is `0.55`. One of them is wrong; its owner should say which.
7. **[UNVERIFIED] `boss_gen.py` hinge/lead constants** for the Gnashroot `"emerge"` set — cannot
   be specified until session 30 lands it.
8. **Open: should `Entry` be published by the server, ever?** No, in this design. But a future
   "the boss retreats and re-enters mid-fight" would want it, and if that day comes the level/
   event distinction and the `>= 0.995 → nil` collapse are what make it safe.
9. **Open: three `duration` rows grow** (rimefang 18 → 20, noctyss 20 → 22, admiral_wrack
   20 → 22). The server reads `duration` to schedule the raise at `duration − riseTime`, so this
   lengthens the pre-fight hold by 2 s for three bosses. That is a design call, not a code one.
10. **Stale prose to fix while in the files** (not behaviour, but this codebase's most expensive
    defect class): `GnashrootIntro`'s rising-branch quote is the wrong branch;
    `PyreliskIntro`'s `readTarget :756-778` and `CreatureService :15594-15595` citations are
    both off; `WrackIntro`'s `groundDrop` sign; `WrackIntro`'s "silent today" hatch comment;
    `ChainPose`'s header claims Wrack's anchor chains as a user and no such code exists;
    import-checklist row 7b says `BrinejawArena` is 13 objects and the export has 19.

## Errata §3.4 (Gnashroot, from its lane 2026-09-12)
The `Eyes` channel exists (`Eyes` 0..1, nil = 1, client-only, 14 eye seats lit face-first). The
crawl silhouette cannot read at Rise 0.3 — shoulders clear the mere at 0.27, the face at 0.48 —
so G1 crawls at Rise ≈ 0.5–0.62. Pack renames: Gnashroot_Eyes → Gnashroot_Eye, Gnashroot_Legs
deleted, Gnashroot_Roots added. G1/P1 are the cutscene lane's.

---

# APPENDIX — as-built deltas / errata (2026-09-12)

**Appended by the boss-cutscene rework unit at commit time.** This document
records what was *designed*; this appendix records where the *built* code does
something else, and why. Nothing above has been rewritten — silently editing a
design to match its implementation erases the fact that a number moved, which is
the one thing a reader needs in order to not copy it forward.

Every value below was **executed** against the worktree, not transcribed.
Landmark IDs in **bold** refer to `docs/boss-cutscenes-handoff.md` §1, which is
the durable commit-time record for this unit (**untracked until the unit lands**);
§4 there re-runs all 104 landmarks, and `tools/check_brinejaw_entry.py` re-runs
the eight geometric/ordering gates.

Three entries are marked **CORRECTION**: the design's number is wrong and the
measured value is the truth. The rest are marked **AS BUILT** (the code
deliberately does something else), **CONTRADICTION** (the design disagrees with
itself and the code picked one), or **REFUSED** (the design asked for something
the code cannot do, with the reason).

---

## A. Brinejaw — the `Entry` channel

### A.1 §5 open item #1 — the arena-local waterline — **CLOSED, and it is 0.0**

Not assumed: **derived, both directions.** `CreatureService:6873` builds this
boss's pose as
`BrinejawPath.newState(Vector3.new(anchor.X, World.WATER_Y, anchor.Z))` — snapped
to the waterline **on purpose**, with its own note saying why (the low sweep band
is 3.4 studs thick and inheriting the spawn lift inverted the fight's central read
across 79% of the floor). `World.WATER_Y = 0` (`World.luau:99`). `BossArenas`
centres are `Vector3.new(x, 0, z)` with that file's own comment "Y ignored; the
platform sits at the waterline". And from the other side, the cutscene's centre
comes through `BossService.arenaPosition` → `BossArenaService.floorY`, which
"returns `World.WATER_Y` unchanged for every arena that really is at sea level",
with `kit.waterY = World.WATER_Y` (`CutsceneKit.luau:180`).

So the 18-knot table stands and the breach staging did **not** need re-running.
`BrinejawPath.ENTRY_WATER_Y = 0.0` carries the derivation (**BP2**), and
**`BrinejawIntro` reads `kit.waterY − kit.center.Y` and warns** if the two ever
diverge, naming the harness to re-run, rather than trusting the constant
(**BI5**).

### A.2 §3.1 "the head breaching at r ~178" — **CORRECTION: r 162.00, bearing 248.0**

The water crossing measures **r 162.00 at bearing 248.0, y 0.000** — which is
exactly this document's own knot 8 comment, `{248, 162, 0} -- THE BREACH`
(**BP5c**). **r 178.5 is the head's position at `Entry = 0`**, one
`ENTRY_SUBMERGE` further out and 20.6 studs *down*, i.e. still hidden. The
document contradicts itself by 16 studs. Camera shot 4 (r 190 → 176, y 6 → 34,
looking at `headAt`) frames both, so the staging is unaffected.

**The measured values are the truth. r 162.00 / 248.0.**

### A.3 The apex gate's spire clearance — **CORRECTION: 22.50 studs, not 19.10**

Measured over the entry spline only (σ 0…σmax); the minimum is at **σ = 0, the
join itself** (r 31 against `spireRadius(3.4)` = 8.5). **19.10 was not
reproducible from any sweep of the spline**, and this document does not say what
range it swept. Both clear the ≥ 15 gate, so nothing downstream moves.

**The measured value is the truth. 22.50 at σ 0.000.**

### A.4 The lantern height — **CORRECTION: 64.6, and the gate uses it**

This document gives the height twice and differently: §3.1 puts the lamp at
`SPIRE_TOP + 4.6` = **58.6**, while the apex gate says "above the broken lantern
(~64.6)" — 64.6 being the lantern **posts** (`BrinejawIntro`'s own
camera-clearance note). The gate uses the **stricter** 64.6
(`SPIRE_TOP + 10.6`), and the apex clears it: `apex y = 72.58 at sigma 0.457`.

**64.6 is the number to hold.** 58.6 describes the lamp, not the obstacle.

### A.5 `L_rest` — 288.64 vs the design's 288.47, and they measure different things

Both are right about different quantities and the 0.06% is not the point:

- **288.64** integrates `restPoint` at `newState` defaults over 2000 samples. This
  is the **parametrisation** unit — what `entryJoined`'s arc length is in.
- **288.15** is the ChainPose-equivalent **drawn** length (160 samples of
  `pointAt`, ambient included), and it matches this document exactly.

So the ±5% body-length gate is stated against the **drawn** number (`rest 288.15
studs; worst +3.27% at Entry 0.90`) and the parametrisation is the 2000-sample
one. **Two numbers, one name** — worth a rename if either is ever quoted again.

§5 open item #3 still stands and is inherited, not closed: `L_rest` is
state-dependent (it moves with `Coil` via `coilOffset`, and with `Slump`). The
entry holds both at defaults and the anchors are computed from the default state,
so **the join is exact only there. Re-run the length gate before anyone drives
`Coil` during an arrival.**

### A.6 §4's `Entry ≥ 0.995 → nil` — **AS BUILT: two thresholds, not one**

Done literally — collapsing on the **attribute** — a script writing `Entry = 1`
makes the controller drop `state.entry` while the ease is still 0.01 short,
snapping the drawn body **2.7 studs** (measured). As built:

- the **attribute** at ≥ `ENTRY.ATTR_HOME` (0.995) *means* home, and is **eased
  to** (target 1) rather than cut to — **BC9**;
- the **eased** value crossing `ENTRY.HOME` (0.998) is what collapses to nil —
  **BC10**.

The property §4 wanted — *a stand-in that always ends in the fight pose whether or
not the script removes the attribute* — holds either way, and it is **stronger**
this way: the collapse is unconditional enforcement, owned by the controller, not
something a cutscene has to remember.

### A.7 The residual the guard's position costs — **1.63 studs, and where it lands**

The entry branch must return ahead of every blend (binding note 1), which also
puts it ahead of `pointAt`'s ambient terms — the travelling breath, the head sway,
the rattle flick. So on the frame `Entry` collapses, the ambient reappears as a
step: **1.631 studs** at `ENTRY.HOME`, of which **1.273 is the ambient alone**.
The harness prints it every run, at three thresholds, deliberately **reported
rather than gated**.

**The honest fix, if it ever reads badly in Studio, is to hoist `pointAt`'s
ambient block into a `BrinejawPath` function the entry branch also calls.** **Not
done**, because it edits the fight's hot path for a cinematic. Recorded so that
the decision is visible rather than looking like an oversight.

### A.8 **ERRATUM on this appendix's own lane** — the first applied schedule put that step outside the ramp

The step above is acceptable **only while the skull is already moving**, i.e.
inside the `Slump` ramp, where the head travels 26 studs in 0.7 s. **The schedule
as first applied did not put it there**, and nothing in the project could see it:

`ENTRY_STEPS`' last row was `{ T.settle0 16.4 → T.settle1 17.3, 0.970 → 1.000,
shape = easeIn }`. The controller chases `Entry` with a first-order filter
(`approach` = `1 − e^(−rate·dt)`, `EASE.entry` 3.0/s), and **such a filter's lag
against a ramp is slope / rate** — so the drawn value can only arrive after the
attribute has *stopped* ramping. `easeIn` (`u²`) has its **maximum** slope exactly
at the end of its window, so the drawn `Entry` was still short of home when the
attribute reached 1; the eased crossing never fired; and the script's
`Entry = nil` at 17.3 collapsed the channel **from a value well short of home**,
at the ramp's closing edge.

**As landed** (`T.coil1`/`T.settle0` → 15.6, `T.entryHome` = 16.4 named, last row
`shape = smooth`, the ramp's own window named `T.slump0`/`T.slump1`): `smooth`
leaves with **zero** terminal slope, the lag falls to nothing as the target
arrives, and the eased value crosses `HOME` at **t = 16.967** — **0.367 s after
the ramp opens and 0.333 s before it closes**, with 0.002 of track left: the
documented 1.63 studs, on a frame where the skull is a quarter through its descent
and accelerating (**BI11–BI16**).

The residual at the collapse, measured with the harness's published method (max
over 401 body samples):

| eased value at collapse | step |
|---|---|
| **0.9980** — `ENTRY.HOME`, as landed | **1.631 studs** |
| 0.9950 | 3.525 |
| 0.9900 | 6.819 |
| 0.9863 / 0.9855 / 0.9835 — the old schedule's range at t 17.3 | **9.13 / 9.64 / 10.76** |

> **One number to reconcile.** The landing note and `BrinejawIntro`'s new comment
> describe the old behaviour as "four studs instead of one and a half". By the
> harness's own method, at the 0.0145 shortfall that same comment states, it is
> **9.64 studs** (6.15 by head displacement alone). Nothing in the decision turns
> on which — every value is multiples of 1.63 and the fix removes all of them —
> but they are not the same measurement, and the smaller one is now in a code
> comment. **Owed: one sentence naming the method, or the measured number.**

**The collapse is deliberately NOT gated on `Slump`.** A `Slump > 0` gate would
make A.6's unconditional guarantee depend on a *second* channel the cutscene also
has to drive — so a skip, a late adopt, or any future arrival that never touches
`Slump` would never collapse at all. **The handoff was moved to coincide with the
ramp instead of the enforcement being weakened.**

**And it is now checked: gate 8, `collapse-inside-slump`.** It **reads** the four
inputs rather than restating them (`BrinejawIntro`'s `T` table and `ENTRY_STEPS`
rows *with their shape names*, the controller's `EASE.entry`, `ENTRY.HOME` and
`ENTRY.ATTR_HOME`), simulates the controller's own filter at 60 Hz, and requires
`MIN_MARGIN = 0.10 s` of ramp on **each** side — six frames of a 0.7-s ramp,
because the drawn slump lags the attribute by its own ease and landing on the
edge is landing on jitter. **Verified failing on the old schedule and on a
knife-edge variant**, and it **FAILs rather than passes if it cannot parse its
inputs**. 8 / 8 green as landed.

**The transferable lesson, and the reason this erratum is this long:** the
ordering was a consequence of **four numbers in two files** — a schedule's last
row *and its easing shape*, a ramp window, an ease rate and a threshold — and no
gate in the project read more than one of them. It looked right in both files
separately. That is the same silent-absence shape as the rest of this unit, with
the value "correct in one file and stale against another".

### A.9 §3.1's 25 `kit.at` splash cues — **AS BUILT: the controller's own crossings**

Per-segment water-plane crossing detection lives in
`BrinejawBodyController.setEntrySplash` (**BC5**, **BC12**, **BC14**), so the
splashes come from the **drawn body's** crossings instead of a schedule computed
at registration (**BI3**). Nothing is lost across a skip — a skipped `kit.at`
fires **muted**, so its `kit.vfx.splash` was already a no-op. This document's
closed form survives in the code as `BrinejawPath.entryOfBreach(t)` and the
harness gates its monotonicity with it: *100 of 100 links breach inside 0..1;
link 1 at Entry 0.056, link 100 at 0.580, monotonic true.*

**§3.1's separate tail-splash `kit.every(11.6, 14.0, 0.24)` is dropped** — the
crossing hook already covers those links, which surface at Entry 0.45…0.583.

### A.10 §3.1's actor table says `FaceAngle` opens at 240° — **AS BUILT: `BEARING − 0.8`**

The entry branch returns before the neck arc, so `faceAngle` is **inert for the
whole arrival**; opening on 240° would only add a channel to ease back at the
handoff. Born at `REST.BEARING − 0.8` (**BI6**), which is what
`CreatureService`'s entrenched rising branch publishes — so the handoff has
nothing to do.

The stand-in's other nine non-`Entry` attributes are likewise born at `newState`'s
defaults (`Coil = MAX_COIL`, `Unwind = 0`, `SweepAngle = 0`,
`SweepHeight = SWEEP_LOW`), per §3.1 — the **opposite** of the old script's
`Coil = 0, Unwind = 1`.

### A.11 Two rules that are in no design at all, both for failure modes §4 implies

- **`ENTRY.CUT = 0.25`** (**BC2**, **BC11**) — an `Entry` step larger than any
  arrival makes in a frame is a skip or a mid-run adopt, so it is taken as a
  **cut**, not a movement. Without it, a skip to t = 16 flew the serpent in from
  the sea for ~2 s *after* the cinematic, which is "no serpent left in the sea"
  inverted. `ENTRY.STEP_MAX = 0.02` is the other half: the splash hook is only
  believed on frames small enough to be real motion (**BC13**).
- **`pendingSplash`** (**BC3**, **BC7**) — `kit.actor` writes `Pose` last and the
  adopt rides **deferred** signals, so a hook installed on the next line would
  have been handed to a model the controller had not met. It is parked and claimed
  by `adoptBoss`.

### A.12 `BossCutscenes.brinejaw` needed no edit

The row was already `duration = 22`, which is what this document asks for. Listed
because a reader auditing "the duration rows that moved" would otherwise go
looking for a fourth hunk that does not exist (**DC1**).

---

## B. Rimefang

### B.1 §3.2's beached lobtail (12.4–14.0) — **REFUSED: it cannot draw**

`RimefangPath.directionAt` adds `flukePitch` **inside `if wBase > 0`**, and
`wBase = 1 − (wArch + wRise + wBeach + wBurst + wSky)` — so at `Beached = 1` the
whole fluke swing is multiplied by zero. **The attribute would move and the body
would not.** Adapted deliberately and documented in the file's own header
(**RI10**):

- the **tail beat moved to 6.3–8.0**, the submerged cruise where `wBase = 1`, and
  which is §3.2's own "it turns and dives / the fluke breaks the ice" beat;
- the **beached beat** is made of the two channels that *do* draw through
  `wBeach` — `Gape` (the controller's jaw, pose-independent) and `Roll`
  (post-applied in `rollAt`, outside every pose weight).

**Both channels §3.2 asked to newly use — `Roll` and `FlukeUp` — are driven**
(**RI5**, **RI6**).

### B.2 The `Submerge` shed — **AS BUILT: the fight's 28.6%, solved from the row**

§3.2 describes only "Submerge 1 → 1" across the burst and **states no shed
fraction at all**; the lane's first pass typed `submergeShed = 0.16`. The fight is
the source of truth, so the typed constant is **deleted** (**RI2**) and the value
is solved from `Bosses.items.rimefang.attacks.icebreach` (**RI1a/b**, **RI3a–c**):

```
strike fraction = icebreach.rise / icebreach.duration = 0.2 / 0.7 = 0.2857
fight's climb   = IMPACT * easeOutCubic(u / IMPACT)     -- K.RF_MOVES.icebreach, CUBIC
burst at shed   = 0.55 * (1 - (1 - 0.2857/0.55)^3)      = 0.4890
timeOfBurst(0.4890)                                     = t 9.354   (apex 9.830)
```

`timeOfBurst` inverts the kit's **quadratic** `"out"` — the ease this file
actually registered — so the two eases are kept distinct on purpose: the **value**
comes from the fight's cubic, the **time** from this cinematic's own curve.
Verified under `luau`: `strikeU=0.2857 burstValue=0.4890 u=0.6669 t=9.3537`.
**One number, and it is the fight's; there is no second copy to go stale.**

**The consequence, which is why the correction matters rather than an argument
against it:** the shed now ends at 9.354 instead of 8.653 — 0.95 s into the 2.6 s
burst window instead of 0.25 s. `weights()` saturates
`wBurst = smootherstep(burst / BURST_FADE)` at **`burst = 0.22`**, past which
`wBase` is 0 and `submergeDepth` no longer contributes to the draw at all. What
the longer authored shed buys is the **eased** value during the first frames of
the launch (`EASE.submerge` is 3.2/s), which is the whole "bursts out rather than
teleporting to the surface" read.

### B.3 §3.2's `Gape 0.2 → 0.9 → 0` vs "0.15 → 1, shut before landing"

The fight's own curve is `0.2 + 0.7·sin(π·min(u/0.55, 1))` — it peaks at **0.9 at
u = 0.275** and is back to **0.2 at the apex**, then holds 0.2 through the topple
and bleeds out in recover. The cinematic's shape (`0 → 0.15` over the lock beat,
`0.15 → 1` by `apex − 0.5`, `1 → 0` by `burstEnd − 0.3` — **shut 0.3 s before the
body lands**) is what is implemented. Not the fight's curve, deliberately: this is
a roar, not a strike.

### B.4 §3.2's "the apex at 10.0" — **AS BUILT: t 9.83**

§3.2 also fixes the window at 8.4–11.0 and the impact fraction at
`K.RF_BURST_IMPACT = 0.55`; `8.4 + 0.55 × 2.6 = 9.83`. **The fight's fraction
wins** and the stated instant is the one that moves.

### B.5 §3.2's opening camera, "`kit.line` in from r 180" — **REFUSED, with geometry**

The pressure ridge is a rubble berm at r 122–132 standing 8.4–18.4 studs over the
sheet (import-checklist row 7j, raycast, 360 bearings) and the whaler is at r 152
with a 19-stud half-length — so a low lens at r 180 looks **through both**. The
shot keeps the previously measured clearance (r 140 → 133 on the hull bearing, out
on the outer pack past the crest).

### B.6 §3.2's "`kit.orbit` 260° → 320°" — **AS BUILT: relative to the burst bearing**

§3.2 gives absolute degrees but does not fix which convention they are in, and the
burst point lands at authored ≈ 151° (`hullB + burstTurn`). The crash shot orbits
`pdBearing − 0.9 → pdBearing + 0.2`, so it stays behind the animal **under any
retune of the curve**.

### B.7 44 of 45 primitives are now `RimefangArena` meshes

`RimefangArena` is imported (checklist row 7j, 9 objects, redesigned 09-09).
Executed: **4 `kit.mesh("RimefangArena", …)` call sites, 0 `kit.part`**
(**RI7**, **RI8**).

| was | is now | count |
|---|---|---|
| 8 neon ice slabs (the shape under the ice) | `kit.mesh("RimefangArena", "ThinIce", { Size = … })` | 8 |
| 12 crack strips | `kit.mesh(…, "Leads", …)` + `kit.meshTween` | 12 |
| 18 thrown shards | `kit.mesh(…, "Bergs"/"ThinIce", …)`, alternating | 18 |
| 6 heave slabs at the keel | `kit.mesh(…, "ThinIce", …)` + `kit.meshTween` | 6 |
| 1 cold lamp + 1 berg light | `kit.light` (unchanged — a light needs a host part) | 2 |

Two mechanics of that substitution are load-bearing and are stated in the file:

- **`kit.mesh`'s `Color`/`Material` props override `MeshColors.get`** — the clone
  is repainted and *then* the caller's props are applied. Done deliberately: those
  same props are what the no-import fallback slab is built from, so passing them
  keeps the fallback byte-identical to what this cinematic drew before the pack
  existed. The values are the arena's own ice blues, so it is a shade, not a
  repaint.
- **`Size` is passed rather than `Scale`.** `RimefangArena_ThinIce` (four
  patches), `_Leads` and `_Bergs` are each **ONE merged object**, so a `Scale`
  clone draws the whole cluster. `Size` squashes the imported geometry into the
  station's authored footprint — the shape is the pack's, the silhouette is the
  body's — and it is safe **here** because these are *flat* decorative objects (a
  flat thing squashed flat stays flat). **See C.1 for where the same trick is
  refused.**

Camera aim points now come from `RimefangPath` (`poseHead`: `newState` + one field
→ `pointAt(state, 0)`, which short-circuits to `anchorOf`), so "the apex" and "the
skull on the ice" are the path's own answers and move when it is retuned
(**RI9**). `state.time` stays 0 there, so the swim wave is sampled at one phase —
worth about a stud on a 56-stud animal.

### B.8 An opportunity NOT taken, flagged for its owner

`CreatureEventController` already draws the crack web (`K.stepRimeWeb`, live when
`Move == "icebreach"` and `Submerge ≥ K.WEB_SUBMERGED = 0.45`) and the pre-burst
sheet dome from **exactly the four attributes this stand-in publishes** — `Move`,
`PoseCenter`, `Submerge`, `Burst` — for any tracked model carrying
`CreatureId == "rimefang"` (`rimefang()` at `:4870`; `watch()` at `:686` tracks
every `Model` under `Workspace.Creatures`, **client-only ones included**). Adding
`creatureId = "rimefang"` + `Move = "icebreach"` to the stand-in would retire all
12 hand-drawn splits and give the fight's own tell for free.

**Not done here**: it wires a cutscene stand-in into a controller this lane does
not own, with a nameplate/HUD and `stepRimeShatter`/`rimeGrade` surface that needs
a Studio run to clear. **Cheap, high value, wants that controller's owner.**

---

## C. Noctyss

### C.1 §3.3's `kit.mesh("NoctyssArena","DecoVeins")` substitution — **REFUSED**

`DecoVeins` is **one merged object carrying all seven crests** — the file's own
existing comment says so and `kit.landmark` confirms a single bbox. So (a) there
is no per-vein object to clone, (b) seven clones would each draw all seven strips,
and (c) the `Size`-squash that works on Rimefang's flat ice (B.7) produces a
**compressed seven-armed star**, which is a blob rather than a directional cord.
The beat's whole read is *light running outward along one vein at a time*, which
only a directional segment can carry.

**The veins stay `kit.part`, and there are zero `kit.mesh` calls in this file**
(**NI2**), with the reason written beside them (**NI4**) so the next reader does
not "fix" it.

### C.2 §3.3's `MawRise 0 → 0.45` — **CONTRADICTION; the code reads `SNAP.RISE_TO` = 0.406**

§3.3's **table** says 0.45 and its own **correction paragraph** says 0.406 — the
two sentences disagree with each other. The user-locked constraint is **the rim,
not the waterline**, so the implementation reads the module:
`local mawTop = NoctyssPath.SNAP.RISE_TO` (**NI1**) = **0.406**.

The waterline is fraction **0.371** (`MAW.Y_DOWN −20`, `Y_UP 20.4`, pit water at
−5.0), so 0.406 is **1.4 studs of travel above the water and nothing more** — the
lower-jaw lip and fang line over the rim, bone-white on black, per `SNAP`'s own
comment. (0.415 is where the *origin* crosses the pit water plane, which is what
§3.3's "use 0.415 as the waterline and 0.406 as the rim" sentence is about; the
maw's **visible** parts, 8.3 studs over the origin, are far above the water at
0.406 either way.)

**Reading the module means neither number can drift.**

### C.3 §3.3's handoff instant (17.2) — **AS BUILT: 17.3, with the arithmetic**

At 0.3 s of hold the drawn head would still be **22%** of the way up when the real
model lands, because `EASE.mawRise` is 2.2/s. So the sink starts at **15.9** and is
given **1.4 s**: residual 0.019 of the fraction ≈ 0.8 studs, 19 studs under the
shelf. The handoff instant moves to **17.3** with `raiseAt` at **17.5**. Stated in
the file header with the arithmetic.

### C.4 §3.3 lists `ChoirDown` as a maw channel — **it is correctly not driven**

It is the fallen-choir mask and **there are no fallen stalks in an intro.** Noted
so a reader does not think it was forgotten.

### C.5 §3.3's "`MawYaw = authored(LANES[1]) = 56°`" — the sign

`authored` is `−math.rad(deg)`, so the value is **−0.977 rad**, i.e. bearing −56°
in Roblox convention. The script uses `kit.authored(NoctyssPath.LANES[1])`
(**NI6**) so the sign cannot drift.

### C.6 Lighting — **AS BUILT: two sources, and the script adds none of the seven**

**Deleted:** the dim violet fill 68 studs over the pit, and the seven floor
`PointLight`s under the veins. What is left is the pit lantern
(`kit.light`, executed count **1** — **NI3**) plus the choir's own lanterns, and
those are *real* lights the rig hangs itself
(`NoctyssBodyController.makeLantern`: a `PointLight`, range 44, brightness 2.2,
driven by `Douse`) — so **seven stalks arriving is seven lights arriving** and the
script adds none. The maw brings the gullet and esca lamps with her.

### C.7 Timings rescaled from the 20 s row

`douse` 18.7 → **20.7** and `relight` 19.55 → **21.55**, preserving their offsets
from the card (−0.625 s and +0.225 s). The choir arrival was pulled 0.5 s earlier
(`stalk` 7.6 → 6.9) so the seventh stalk is fully grown before the lean, which is
what she rears into.

### C.8 `Grow` is written on stand-ins only

Every `Grow` write is an `actor:tween` on a model this file created; `mine[model]`
records them (**NI5**) and is what the retirement scan uses to tell a **real**
`choir_stalk` from one of ours. **No real fight model is ever written.** The choir
retirement logic is kept verbatim; the maw stand-in retires on its **own**
`onRealBoss`, immediately, because there is exactly one head and two drawings of it
must never overlap (**NI8**).

---

## D. Kraken

### D.1 §1.2's "one line, `center = kit.center`" — **AS BUILT: the server's derivation**

Applied as `Vector3.new(kit.center.X, kit.waterY, kit.center.Z)`. Identical today
(`maelstrom.center.Y == 0 == World.WATER_Y`), but it is the derivation the server
actually uses
(`newState(Vector3.new(anchor.X, World.WATER_Y, anchor.Z))`), and it is **named**
so that a payload whose Y stops being the waterline cannot silently shift the
vertical datum of a 480-stud animal.

**`PoseCenter` is the SHIP centre** (**KI7**) — derived as the server derives it.
The assertion that `PoseCenter` is "the HEAD's world position" is the one this
slice exists to delete.

### D.2 §3.7's `ArmPhase` / `ArmT` — **REFUSED: the frame carries neither**

`frame.tentacles[i]` is `{ bearing, radius, rise, curl, tip, visible }`. The sweep
is therefore expressed as a **polar walk of the tip** along the fight's own lane at
`KrakenPath.sweepCentreY`'s height, through the `tipOverride` seam — the same read,
by the only available mechanism. **Zero `ArmPhase` writes** (**KI5**).

**§3.7's "`ArmPhase` held at `Rear`" is likewise unreachable.** Each limb holds the
pose the controller seated it in and never changes it: `Rest` for the two FIGHT
seats (2, 3), `Adrift` for the two AMBIENT seats (1, 4). Making the design's
version possible would need two new fields on the frame — a real API change in
`KrakenBodyController`, which is session 30's.

### D.3 §3.7's `radius 420 → 150` — **AS BUILT: socket → deck station**

The brief's "every limb rises from below the waterline to its socket" governs, so
radius runs **socket → deck station** (250.8 / 167.5 → 34.9 / 17.6). **420 would
have put the tips out at sea rather than on the hull.** The derived seat geometry,
computed in-script from copied `KrakenPath` primitives (**KI6a–c**) and
re-derived independently during review:

```
rootZ     = HEAD_Z -370 + ROOT_FORWARD 36 * SCALE 6           = -154
deckRise  = (DECK_Y 8 + girthAt(1) 6.72) / RISE_SPAN 268       = 0.0549  (14.7 studs)
sweepRise = (8 + SWEEP_CLEAR 3 + 6.72) / 268                   = 0.0661  (17.7 studs)

seat 1  lat -33  socket r 250.8  b -142.1°   deck r 34.9  b -156.4°   swing 14.3°
seat 2  lat -11  socket r 167.5  b -113.2°   deck r 17.6  b -127.3°   swing 14.1°
seat 3  lat +11  socket r 167.5  b  -66.8°   deck r 17.6  b  -52.7°   swing 14.1°
seat 4  lat +33  socket r 250.8  b  -37.9°   deck r 34.9  b  -23.6°   swing 14.3°
```

All four sockets are on the **port** quarter (bearings 218/247/293/322°), which is
why **every camera moved to the starboard arc (58–112°)** — 106° clear of the
nearest socket, no limb on any camera bearing at any point in the run. The version
this replaces orbited *through* the limb ring, which was only safe because the
limbs were props on a ring of their own.

### D.4 The blend-weight staging, and why `w = 0` writes nothing

`stage.w` walks **1 → 0** across 17.6–18.6 (**KI4**) and at `w <= 0` the hook
**returns without writing** (**KI3**): every limb ends on **its own fight pose**,
and the handoff is not "we computed the same numbers" but "we stopped computing".
`setCutscene(nil)` at **18.6** (**KI1**, **KI2**, **KI8**).

### D.5 The live hazard worth a second pair of eyes

`KrakenBodyController.setCutscene` is **module state, not rig state**: a hook left
armed after the cinematic ends would **freeze the live fight on a cutscene frame
for the rest of the session.** `KrakenIntro` retires it three ways —
`kit.at(18.6)`, `kit.onRealBoss`, and (the path that cannot be skipped) **from
inside the hook itself**, the frame after the stand-in leaves the tree, because
`kit.finish` destroys the actor on every cancel path and knows nothing about a
module-level hook. **If anyone adds a fourth way out of a cutscene, that third
guard is the one that has to keep working.**

### D.6 §3.7's "drop `WALL_H` to 118 on the far arc" — already true

`WALL_H` is 118 and the existing door factor already tapers it. No change beyond
the Foam crest (28 slabs **kept** + 9 `KrakenArena_Foam` crest clones).

### D.7 Three items for `KrakenPath`'s owner — raised, not touched

1. **`Adrift` is not in the bend-law table.** The verification note lists eight
   poses (Rest 1.23, Rear 2.90, Slam 1.40, SweepCock 1.50, Sweep 1.40, Wrapped
   1.08, Down 2.02, Withdrawn 5.45). `POSE.Adrift` — the AMBIENT seats' only pose,
   and therefore **the pose two of the four staged limbs run for this entire
   cinematic** — is absent. Same family as `Rest` (same construction, same arrival
   direction, a longer drape), but this lane will not invent a number. **Asks: one
   re-run of that file's own sweep with `Adrift` in the pose list.** *(The channel
   owner is mid-pass adding exactly this.)* Stated in the script (**KI9**).
2. **The bend-law argument for the staged tips is a construction argument, not a
   measurement**, and `bendcheck.py` is not in the repo (`find . -name
   "bendcheck*"` → nothing; it lives in that lane's scratchpad), so it could not be
   re-run. The argument: `tipOverride` moves p3 and carries p2 by the same delta,
   preserving handle length, so **lengthening** the chord *straightens* the curve;
   every staged chord here is **575–581 studs** root-to-tip (the roots sit ~540
   under while `Rise` is 0) against the fight's own `Rest` chord, so all of it is
   in the **safe** direction — the documented failure mode is a *shortened* chord
   (`ROOT_FORWARD` 30 gave a 37-stud chord and 0.04 of the bound). **Unmeasured;
   worth one sweep** over the driven `rise`/`radius`/`bearing` ranges.
3. **`HANDLE_ROOT` is still `[UNVERIFIED]`** (§5 item 6): the prose says "0.42 is
   measured, not chosen", the constant on the next line is **0.55**. Untouched,
   still open.

---

## E. Admiral Wrack

### E.1 §3.6's `cue("arrive")` — **REFUSED: it is duel-only and does nothing on the ship**

`admArriveLand` and `admArriveDraw` are both `kinds = { duel = true }` — the
**duelist's** act-3 landing. The ship's kind (`CreatureId = "admiral_wrack"`) does
not carry those rows, so cueing "arrive" reaches a body and **changes nothing**.
**Not called** (**WI6**). The Admiral is conducted onto the party with `windup`
(admHigh / admPoint / admLook, which the ship *does* carry) instead (**WI7**).

**This document's "Channels newly used: … the `arrive` cue" line is wrong for this
boss.** A cue that reaches a body and silently does nothing is the exact failure
shape this appendix exists for.

### E.2 §3.6's `place(e)` heave — **AS BUILT: a bow-lift bump**

She is afloat and **level** coming in, so opening the grounding window on the
server's `pitch * (1 − e)` at `e = 0` is a **one-frame 20° jump**. Replaced with
`rad(9) * sin(π · e)` — **zero at both ends** (**WI4**). The server's pitch term
still governs the settle at the far end, where it belongs (she really is going
nose-first under the sand there).

### E.3 §3.6's "walks from r 190 to r 0" in one window — **AS BUILT: split in two**

Afloat to **r 34**, then the run-in **r 34 → 0** fused with the slew, heel and
draught — so the 48-stud hull is **wholly over water** when the keel touches and
**wholly on the shoal** when it stops. She also **surfaces** at r 190 rather than
appearing there, so there is no pop on the frame the reveal shot cuts to.

Pose continuity, **measured** at every window boundary (radius, y, yaw, pitch,
roll):

```
afloat(11.0-)  34.0000  -5.5219  -1.5708  0.0000  0.1040
ground(11.0+)  34.0000  -5.5219  -1.5708  0.0000  0.1040   <- exact
ground(13.2-)   0.0000  -2.3000  -0.0000  0.0000  0.0000
place(1)        0.0000  -2.3000   0.0000 -0.0000  0.0000   <- exact
place(0)        0.0000 -21.5000   0.0000 -0.3491  0.0000   <- what raiseAt lands on
settle(17.8)    0.0000 -21.5000   0.0000 -0.3491  0.0000   <- exact
```

`place(e)` is the **server's** pose arithmetic, copied (**WI9**), which is what
makes "she is at the rise's first frame" `place(0)` rather than a constant that can
drift.

### E.4 The hatches — **three lids, not four, and they SHUT at the settle**

This script used to write `WrackHatches` masks **1, 3, 7, 15**. The row landed
2026-09-09 and the writes are **not** silent — and **there are THREE lids**:
`mask = 15` set a bit with no `Hatch4` behind it and **is gone** (**WI3**). The
masks are **1 → 3 → 7** at 8.0 / 8.62 / 9.24 (**WI2a**) and they now **shut** at
the settle (**WI2b**), because the real boss arrives with them closed and leaving
them open at the cut was a visible pop on three real lids.

### E.5 The four guns, and the muzzle-along-bore flare

Taken from `WrackBodyController`'s own `GUNS` table (**WI1**) — the span centroid
the server stands the battery creature on, the bore's **mouth**, and the bore
**direction**, carried at full precision because a rounded bore sits the flare
inside the planking:

```
BowStbd    at (16.45, 13.2, -9.5)  muzzle (20.4, 13.2, -11.8)  bore (0.87, 0, -0.5)
BowPort    at (16.45, 13.2,  9.5)  muzzle (20.4, 13.2,  11.8)  bore (0.87, 0,  0.5)
SternStbd  at (-16.45, 14, -9.5)   muzzle (-20.4, 14, -11.8)   bore (-0.87, 0, -0.5)
SternPort  at (-16.45, 14,  9.5)   muzzle (-20.4, 14,  11.8)   bore (-0.87, 0,  0.5)
```

The four names this file used to address **have not existed since 2026-09-08**;
they were renamed with the Wrack pack's eleven new objects. Every muzzle flash,
burst and powder cue is placed **along the bore** from the muzzle, not at the
casemate centre.

### E.6 The sign convention — bearing and yaw are opposite, and `WrackBoom` is a bearing

`CFrame.Angles(0, y, 0)` maps the bow (+X) to `(cos y, 0, −sin y)`; `kit.polar`
reads a bearing as `(cos b, 0, sin b)`. **So `yaw = −bearing`** — and `WrackBoom`
is published in the **bearing** convention (`Fn.wrackAngle`'s
`atan2(dir.Z, dir.X)`), i.e. **the boom's pivot is the opposite sign from the
hull's yaw.** The file carries both, adjacent, with the derivation written out
(`sailBearing`, `sailYaw = -sailBearing` — **WI5a/b**). Verified: the bow
direction under `sailYaw` is `(0.000, 1.000)`, i.e. she heads +Z from the −Z mouth.

**This was one of two bugs found in that slice's own first draft, and both drafts
passed every gate.** (The other: the settle window's `u` was unclamped — `kit`
applies a passed track **once at `u = 1`** with `kit.t` already beyond `raiseAt`,
so `1 − u²` went negative and the *settled* pose was **below** `place(0)`, which
is precisely the one frame the whole handoff is measured against. Now clamped,
with the reason beside it.)

### E.7 §3.6 has no Lady beat — **one was added**

The brief named the figurehead among the real pieces to use, so a second
`kit.actor` carries **`WrackDive = 0`** (**WI8**) — the attribute
`figureheadFlight` keys on **by design**, so this file never has to agree with
`Bosses` about a row name it cannot see change — flown ahead of the ship and
destroyed at `tGround − 1.4` so the stem carries her again for the handoff. **0 is
the honest value**: 0 is "swinging out or re-arming", `n` is the n-th damaging
pass.

### E.8 §3.6's "12 lights as today" moved earlier

**1.4–4.6 instead of 5.6–9.0**, because the fleet-lighting orbit shot is gone —
5.4–11.0 is now the approach.

### E.9 Stale prose fixed while in the file

`groundDrop`'s sign: the header said `0.5`, the code used `-C.rootHalf` =
**−0.5**. **The code was right** (the box bottom is below the pivot); the header
now says so. This is §5 item 10's list, two entries of which (`groundDrop`, the
"silent today" hatch comment) are now closed.

---

## F. Cross-cutting

### F.1 `kit.mesh` / `kit.meshTween` are called directly, with no capability branch

All five scripts call them with **no `if kit.mesh then … else … end` fallback
anywhere**, per the coordinator's instruction that the pair had landed. Verified
against the live `CutsceneKit.luau` before writing (`packPrefix` at `:108`,
`kit.mesh` at `:727`, `kit.meshTween` at `:818`) and re-verified at audit time as
a **dependency landmark** (handoff **D1**, **D2**). **`CutsceneKit.luau` is the
cutscene lane's file and this unit adds nothing to it.**

### F.2 §5 item 9 — three `duration` rows grow

`rimefang` 18 → **20**, `noctyss` 20 → **22**, `admiral_wrack` 20 → **22**
(handoff **DC2–DC4**); `brinejaw` was already 22 (**DC1**) and `kraken` stays
**24** (**DC5**). The server reads `duration` to schedule the raise at
`duration − riseTime`, so this lengthens the pre-fight hold by 2 s for three
bosses — **the design call this document says it is.**

`BossCutscenes.luau` is **untracked and belongs to the cutscene lane (session
30)**; the three rows are handed over as the three-line change they are, not
staged by this unit. The `admiral_wrack` row was applied through a read-then-write
that re-reads at the instant of writing and asserts both an anchor and a guard,
because the file had a live writer four minutes earlier:

```
anchor : '\tadmiral_wrack = { duration = 20, script = "WrackIntro" },\n'   count == 1
guard  : 'kraken = { duration = 24, script = "KrakenIntro" },'             present
```

### F.3 Skip and late-join, per boss — reasoned, not watched

Every attribute write in all five scripts is a `kit.track`, an `actor:tween` (also
a track) or a `kit.at`; the prop animators are still `kit.during`, deliberately —
a `during` is **not** visited after a skip, and every prop it drives is destroyed
with the run. So a `fastForward` to any t settles every track at `u = 1` and fires
the terminal `at`s → **the handoff pose, with nothing left in the sea**.

Noctyss is the subtle one: the maw's six tweens and its handoff `at` are registered
**inside** the `born` `at`, because the actor does not exist before it.
`fireEventsTo` snapshots `#events`, so a skip past `born` creates her in that call
and the newly-appended tracks settle on the **next** frame → the handoff pose. A
skipped or late-joined run therefore lands with **a maw model in the handoff
frame**, never with no model at all and never mid-rear.

**None of this has been watched.** §4's universal three, per boss — no pop at
`raiseAt`; a skip at four points landing on the handoff pose with nothing
orphaned; a late join mid-run showing a sane frame — plus the per-boss visual
checks, are itemised in `docs/boss-cutscenes-handoff.md` §7a and **owe a Studio
run**.

### F.4 §5 item 10's stale-prose list — partially closed

Closed in-file by this unit: `WrackIntro`'s `groundDrop` sign (E.9),
`WrackIntro`'s "silent today" hatch comment (E.4), and `KrakenIntro`'s
"`PoseCenter` is the HEAD's world position" (D.1). **Still open and not this
unit's**: `GnashrootIntro`'s rising-branch quote; `PyreliskIntro`'s `readTarget`
and `CreatureService` line citations; `ChainPose`'s header claiming Wrack's anchor
chains as a user when no such code exists; import-checklist row 7b's
`BrinejawArena` object count (13 claimed, 19 exported).

**The rule this unit adopted after hitting it twice:** *anchor a replacement at the
top of the comment block that documents it, not at the line being changed.*
Comments are invisible to all five gates, and a comment that contradicts the code
beside it is worse than no comment, because it is evidence. A.8 is this appendix's
own instance of paying for it.

## Errata §3.6 (Kraken, from its lane 2026-09-12, animation pass)
`Adrift` is now in KrakenPath's bend-law sweep, MEASURED: authored pose sweeps at 60.0 studs
submersion / 3.05× bend bound (was 0.27 — a real hairpin on the two always-on-screen limbs, fixed
on the departure so the silhouette the intro stages against did not move); its Rest/Withdrawn
blends 1.89. Caveat: the sweep covers the AUTHORED Adrift (chord 302), not the intro's
`tipOverride` curve family at chords 575–581 — those remain a construction argument (straighter
than the fight's Rest chord; the safe direction). Pre-existing bug fixed in the same pass:
`KrakenPath.lane` never set `prevView`, so the first blend out of a sweep threw and the pcall
latch stopped the whole Kraken drawing from the first deck scythe onward. Frame contract unchanged.
