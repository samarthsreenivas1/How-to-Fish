# Boss-cutscene rework — commit-time handoff record

> **THIS FILE IS UNTRACKED AND MUST STAY THAT WAY UNTIL THE UNIT LANDS.**
>
> It lives in `docs/` for the same reason `docs/wrack-fight-handoff.md` and
> `docs/pyrelisk-fight-handoff.md` do — the checklist for a long-lived
> uncommitted unit cannot live somewhere a `/private/tmp` purge or a new
> session can take it. Every slice's `NOTES.md`, `SOURCES.md` and `patches/`
> for this work are in a session scratchpad under
> `/private/tmp/claude-501/…/scratchpad/cutscenes/{brinejaw,rn,kw}/`.
> **Assume they are already gone.** This file is the durable record; it is not
> staged.
>
> - **Do not `git add -A`, `git add .`, or `git commit -a`.** This is a shared
>   checkout with live sessions in these files, and **five** of the unit's
>   eleven paths are *untracked*, which is the worst combination there is: a
>   reconstruct-commit flow that stages from a diffstat lands none of them and
>   says nothing.
> - When the cutscene consolidation commit is approved, this file is committed
>   **by explicit path, in the same commit as the unit** (§8).
> - Until then it is invisible to every gate and to every other lane, which is
>   correct: it describes work that is not in HEAD.

Written **2026-09-12** by running the audit from scratch against the current
worktree. Every landmark below was **executed**, not transcribed.
Result: **104 / 104 landmarks present, 0 missing.**

**Re-run 2026-09-12, later the same day**, after the collapse-ordering hunk
landed in `BrinejawIntro` / `tools/check_brinejaw_entry.py` (§6a). That hunk
added six landmarks in `BrinejawIntro`, one expected-zero in the controller and
five in the gate — 94 → 104 — and it turned the unit's largest open risk into
**gate 8**, an executable one. The gate count in every §-reference below is
therefore **8**, not 7.

---

## 0. What the unit is

The boss-cutscene rework: **five intro cinematics rewritten to be drawn by the
bosses' own rigs and paths instead of by script-built primitives**, plus the one
piece of new engine it needed — the Brinejaw **`Entry` channel**, a body-length
arrival track on `BrinejawPath` that the client collapses back into the fight
pose with no seam at the handoff.

It was built as three drafted slices, each applied to the worktree from a gated
copy, none staged:

| slice | scratchpad | what |
|---|---|---|
| `brinejaw` | `scratchpad/cutscenes/brinejaw/` | the `Entry` channel (path + controller + script) and its gate |
| `rn` | `scratchpad/cutscenes/rn/` | `RimefangIntro`, `NoctyssIntro`, two `duration` rows |
| `kw` | `scratchpad/cutscenes/kw/` | `KrakenIntro`, `WrackIntro`, one `duration` row |

The slices are a build order, **not a commit order** — §3 is the dependency
statement and it says *one unit or none*.

### The eleven paths, and their git state

| path | git state | owner |
|---|---|---|
| `src/Shared/Modules/BrinejawPath.luau` | **tracked, modified** | Brinejaw was unowned → **mine** |
| `src/Client/Controllers/BrinejawBodyController.luau` | **tracked, modified** | **mine** |
| `src/Client/Cutscenes/BrinejawIntro.luau` | **untracked** (whole dir is `??`) | **mine** |
| `src/Client/Cutscenes/RimefangIntro.luau` | **untracked** | channel owner **00** |
| `src/Client/Cutscenes/NoctyssIntro.luau` | **untracked** | channel owner **c1** |
| `src/Client/Cutscenes/KrakenIntro.luau` | **untracked** | channel owner **8e** |
| `src/Client/Cutscenes/WrackIntro.luau` | **untracked** | wrack channel |
| `src/Shared/Data/BossCutscenes.luau` | **untracked** | **cutscene lane (session 30)** |
| `tools/check_brinejaw_entry.py` | **untracked** | **mine** (gate six) |
| `tools/brinejaw_entry_stub.luau` | **untracked** | **mine** |
| `tools/brinejaw_entry_probe.luau` | **untracked** | **mine** |

`src/Client/Cutscenes/` being untracked in full means `GnashrootIntro.luau`,
`PyreliskIntro.luau` and `_Example.luau` — **not this unit's, session 30's** —
land with the same `git add` that lands ours. That is the whole reason §8 has a
coordination step before the stage.

### Explicitly NOT in this unit

- **`src/Client/Modules/CutsceneKit.luau`** and its `kit.mesh` / `kit.meshTween`.
  All five scripts **call them directly, with no capability branch**, so the unit
  **cannot go green without them** — but the file is the cutscene lane's and this
  unit adds nothing to it. Recorded as a **dependency** (§3.1), not a hunk.
- **`BossCutsceneController.luau`, `GnashrootIntro.luau`, `PyreliskIntro.luau`** —
  session 30's, untouched.
- **`KrakenPath.luau`, `KrakenBodyController.luau`, `WrackBodyController.luau`,
  `RimefangPath.luau`, `NoctyssPath.luau`, `RimefangBodyController.luau`,
  `NoctyssBodyController.luau`** — read by this unit, **written by none of it**.
  Channel owner **8e** is mid-pass on `KrakenPath` (adding `Adrift` to the
  bend-law sweep, §7.4); that pass and this unit do not meet in a file.

---

## 1. Landmarks, per file

All counts below are the **executed** result on the current worktree. Every
pattern is line-anchored so it cannot drift when the shared files move.

> **Reading the patterns:** `\t` below stands for a **literal TAB** — Luau
> indents with tabs and `grep -E` does **not** expand `\t`. The §4 script
> contains real tab characters; if you retype a landmark by hand, type a tab.
> `\|` is table escaping for `|` (alternation). Everything else is verbatim.

### `src/Shared/Modules/BrinejawPath.luau` — 13 landmarks (3 hunks)

| ID | Hunk | Landmark (`grep -cE`) | Count |
|----|------|------------------------|-------|
| BP1 | hunk 1: the header note | `^-- \.\.\.AND ONE ELEVENTH THAT IS NOT ON THE WIRE` | 1 |
| BP2 | hunk 2: the waterline, **derived** | `^BrinejawPath\.ENTRY_WATER_Y = 0\.0$` | 1 |
| BP3 | hunk 2: the snout's start depth | `^BrinejawPath\.ENTRY_SUBMERGE = 0\.10$` | 1 |
| BP4 | hunk 2: the two sample counts | `^BrinejawPath\.ENTRY_(SAMPLES\|REST_SAMPLES) = ` | 2 |
| BP5a | hunk 2: the knot table opens | `^BrinejawPath\.ENTRY_KNOTS = \{$` | 1 |
| BP5b | **16 AUTHORED knots** (table-scoped, §4) | `^\t\{ ` inside the table | **16** |
| BP5c | knot 8 **is** the breach | `^\t\{ 248\.000, 162\.000, 0\.000 \}, -- THE BREACH` | 1 |
| BP6 | hunk 2: the seven Entry functions | `^function BrinejawPath\.(entryKnots\|entryAux\|entryData\|entrySpline\|entryJoined\|entryHead\|entryOfBreach)\(` | 7 |
| BP7 | the arc-length cache is **one table field** | `^\tBrinejawPath\.entryCache = data$` | 1 |
| BP8a | hunk 3: guard line 1 | `^\tlocal entry = state\.entry$` | 1 |
| BP8b | hunk 3: guard line 2 | `^\tif entry and entry < 1 then$` | 1 |
| BP8c | hunk 3: guard line 3 | `^\t\treturn \(state\.center or Vector3\.zero\) \+ BrinejawPath\.entryJoined\(state, x\)$` | 1 |
| BP9 | **top-level locals STILL 26** | `^local ` | **26** |

**BP8a–c are the whole reason the channel is safe, and their POSITION is the
contract.** The guard is the first thing `pointAt` does after the clamp: ahead of
the unwind/sweep blend, ahead of the slump, ahead of every attack mode, and
ahead of anything that reads `state.sweepBranch` / `state.sweepRate` — so a body
on its way in can never trip the latched sweep branch the fight's whip depends
on. Moving it down by three lines does not break a gate; it breaks the fight,
later, in a way that looks like a whip bug.

**`Entry = nil` and `Entry >= 1` both FALL THROUGH the guard.** That is why the
handoff is exact rather than convergent: measured `max |Entry=1 − rest|` is
**0.000e+00 studs over 2001 samples** (§4, gate `handoff-exact`). The server never
writes `Entry` and never can — `colossusState` builds this boss's pose with
`newState`, which has no such field.

**BP9 is a hard gate, not a statistic** (§5).

### `src/Client/Controllers/BrinejawBodyController.luau` — 15 landmarks (9 hunks)

| ID | Hunk | Landmark | Count |
|----|------|----------|-------|
| BC1 | hunk 1: the ease row | `^\tentry = 3\.0,$` | 1 |
| BC2 | hunk 1: the four thresholds | `^local ENTRY = \{ HOME = 0\.998, ATTR_HOME = 0\.995, STEP_MAX = 0\.02, CUT = 0\.25 \}$` | 1 |
| BC3 | hunk 2: the parked-hook table | `^local pendingSplash = \{\}$` | 1 |
| BC4 | hunk 3: the read, **with no `or`** | `^\ttarget\.entry = model:GetAttribute\("Entry"\)$` | 1 |
| BC5 | hunk 4: the public hook installer | `^function BrinejawBodyController\.setEntrySplash\(model: Model, fn\)$` | 1 |
| BC6 | hunk 5: the three body fields | `^\t\t(aboveWater\|entrySplash\|entryLast) = ` | 3 |
| BC7 | hunk 6: `adoptBoss` claims the hook | `^\tbody\.entrySplash = pendingSplash\[model\]$` | 1 |
| BC8 | hunks 6+7: the park is cleared **twice** | `^\tpendingSplash\[model\] = nil$` | **2** |
| BC9 | hunk 8: collapse rule **A** (the attribute) | `^\tif wantedEntry ~= nil and wantedEntry >= ENTRY\.ATTR_HOME then$` | 1 |
| BC10 | hunk 8: collapse rule **B** (the eased value) | `^\t\tstate\.entry = if eased >= ENTRY\.HOME then nil else eased$` | 1 |
| BC11 | hunk 8: a step past `CUT` is a **cut** | `^\t\tif state\.entry and math\.abs\(wantedEntry - state\.entry\) > ENTRY\.CUT then$` | 1 |
| BC12 | hunk 9: the water plane is the **body's own** | `^\tlocal waterY = \(state\.center or Vector3\.zero\)\.Y \+ BrinejawPath\.ENTRY_WATER_Y$` | 1 |
| BC13 | hunk 8/9: the splash believes only small steps | `^\tlocal splashOk = entryStep <= ENTRY\.STEP_MAX$` | 1 |
| BC14 | hunk 9: the per-link crossing calls the hook | `^\t\t\t\tlocal ok, err = pcall\(splash, index, cframe\.Position, state\.entry\)$` | 1 |
| BC15 | the collapse is **UNCONDITIONAL** — no `Slump` gate (block-scoped, §4) | `slump` between BC9's line and BC10's | **0** |

**BC4 is the landmark this whole controller hunk exists for, and it is a
`silent-absence-failures.md` case in its purest form.** `readTarget` names ten
attributes one at a time; there is **no loop over the model's attributes anywhere
in the file** (grepped). Left unnamed, `Entry` would have replicated correctly,
been dropped by the one function that had to read it, and presented as *"the
cutscene's Entry track does nothing"*. And the read must have **no `or 0`**: nil
is a *meaning* here (the fight pose), and defaulting it to 0 puts **every**
serpent in the game out at sea.

**BC9 and BC10 are two thresholds, and that is deliberate** — see §6.2. Doing it
as one, on the attribute alone, snaps the drawn body by however far the ease
still had to travel.

### `src/Client/Cutscenes/BrinejawIntro.luau` — 17 landmarks (rewrite, +445/−305)

| ID | Hunk | Landmark | Count |
|----|------|----------|-------|
| BI1 | the arrival's **one** schedule | `^local ENTRY_STEPS = \{$` | 1 |
| BI2 | five rows, one shape each (table-scoped) | `^\t\{ t0 = T\.` | 5 |
| BI3 | the splash hook, **not** 25 `kit.at` cues | `^\t\tBrinejawBodyController\.setEntrySplash\(stand\.model, function\(index, position\)$` | 1 |
| BI4 | the require (same depth kit uses; no cycle) | `^local BrinejawBodyController = require\(script\.Parent\.Parent\.Controllers\.BrinejawBodyController\)$` | 1 |
| BI5 | the waterline is **derived from kit**, not typed | `^\tlocal waterLocal = kit\.waterY - cy$` | 1 |
| BI6 | `FaceAngle` opens at `BEARING − 0.8` | `^\tlocal restFace = rest\.BEARING - 0\.8$` | 1 |
| BI7 | pack geometry, `kit.mesh` call sites | `kit\.mesh\("BrinejawFxPack"` | 3 |
| BI8 | **12 script primitives → 1 `kit.part`** | `kit\.part\(` | **1** |
| BI9 | `Entry` **removed** at the handoff | `^\t\tstand:set\("Entry", nil\)$` | 1 |
| BI10 | shots that aim at `headAt(t)`, not a point | `^\t\t\treturn headAt\(t\)$` | 3 |
| BI11 | the `Slump` ramp is **named**, not typed | `^\tkit\.track\(T\.slump0, T\.slump1, "in", function\(u\)$` | 1 |
| BI12 | **`T.entryHome` = 16.4** — where `Entry` reaches 1 | `^\tentryHome = 16\.4,$` | 1 |
| BI13 | `T.slump0` 16.6 / `T.slump1` 17.3 | `^\tslump(0 = 16\.6\|1 = 17\.3),$` | 2 |
| BI14 | `T.coil1` / `T.settle0` pulled to **15.6** | `^\t(coil1\|settle0) = 15\.6,$` | 2 |
| BI15 | last row: **`smooth`**, ending at `T.entryHome` | `^\t\{ t0 = T\.settle0, t1 = T\.entryHome, from = 0\.970, to = 1\.000, shape = smooth \},$` | 1 |
| BI16 | …and the comment says **where the collapse lands** | `^\t-- THE COLLAPSE, AND WHERE IT LANDS\.` | 1 |

**BI1/BI2 are one landmark in two halves and the point is that there is only
one.** The five `kit.track` rows *and* the camera's `headAt` / wake sampling read
the same table, so a shot cannot aim at where the serpent used to be. Every
`Entry` write is a `kit.track` (**none** is a `during`), so a skip settles each at
`u = 1`.

**BI10's count is 3, not 4.** The slice note says "four of the eight shots look at
`headAt(t)`"; three of them are the `^\t\t\treturn headAt(t)$` aim-callback form
and the fourth reads `headAt` at a fixed instant (`kit.sfx("serpentSweepHigh",
headAt(9.60))`, and `local at = headAt(T.beach)`). The *claim* is right and the
*shape* differs, so the landmark counts what is actually there.

### `src/Client/Cutscenes/RimefangIntro.luau` — 12 landmarks (rewrite, 830 lines)

| ID | Hunk | Landmark | Count |
|----|------|----------|-------|
| RI1a | `icebreach.rise`, quoted off the `Bosses` row | `^\ticebreachRise = 0\.2, -- icebreach\.rise` | 1 |
| RI1b | `icebreach.duration`, likewise | `^\ticebreachStrike = 0\.7, -- icebreach\.duration` | 1 |
| RI2 | **the typed `submergeShed = 0.16` is DELETED** | `submergeShed = 0\.16` | **0** |
| RI3a | the strike fraction | `^\tlocal shedStrikeU = N\.icebreachRise / N\.icebreachStrike$` | 1 |
| RI3b | the **fight's** cubic climb | `^\tlocal submergeShed = N\.burstImpact \* \(1 - \(1 - shedStrikeU / N\.burstImpact\) \^ 3\)$` | 1 |
| RI3c | the **cinematic's** own inverse for the time | `^\tlocal submergeEnd = timeOfBurst\(submergeShed\)$` | 1 |
| RI4 | and the shed is written against it | `^\twhale:tween\("Submerge", 1, 0, N\.burstT0, submergeEnd, "inout"\)$` | 1 |
| RI5 | **`FlukeUp` newly driven** | `^\twhale:tween\("FlukeUp", ` | 3 |
| RI6 | **`Roll` newly driven** on the roar | `^\twhale:tween\("Roll", ` | 2 |
| RI7 | `RimefangArena` mesh call sites (44 clones) | `kit\.mesh\("RimefangArena"` | 4 |
| RI8 | **no script-built slab left** | `kit\.part\(` | **0** |
| RI9 | camera aim points come from `RimefangPath` | `^\tlocal function poseHead\(fields\): Vector3$` | 1 |
| RI10 | the beached lobtail **cannot draw** (moved) | `^-- on the beached body\. .FlukeUp. CANNOT DRAW THERE\.` | 1 |

**RI2 is a deletion and it is load-bearing.** `0.16` was the cinematic's own guess
at the shed; the fight's number is `icebreach.rise / icebreach.duration` = 0.2/0.7
= **28.6%** of the strike, and the shed is now **solved** from it (RI3a–c) rather
than typed. There is no second copy to go stale: retune either row field in
`Bosses.items.rimefang.attacks.icebreach` and the shed moves with it. Putting
`0.16` back is not a tidy-up, it is a decoupling.

**The one consequence worth knowing** (§6.5): the shed now ends at t 9.354 instead
of 8.653, and `weights()` saturates `wBurst = smootherstep(burst / BURST_FADE)` at
`burst = 0.22`, past which `wBase` is 0 and `submergeDepth` no longer contributes
to the draw at all. What the longer authored shed buys is the **eased** value
during the first frames of the launch, which is the whole "bursts out rather than
teleporting to the surface" read.

### `src/Client/Cutscenes/NoctyssIntro.luau` — 8 landmarks (rewrite, 740 lines)

| ID | Hunk | Landmark | Count |
|----|------|----------|-------|
| NI1 | the rise cap is **read**, not typed | `^\tlocal mawTop = NoctyssPath\.SNAP\.RISE_TO$` | 1 |
| NI2 | **the `DecoVeins` substitution is REFUSED** | `kit\.mesh\(` | **0** |
| NI3 | **one** light source — no violet fill | `kit\.light\(` | **1** |
| NI4 | …and the refusal is stated, not silent | `DecoVeins is ONE merged` | 1 |
| NI5 | the `mine[]` ledger: stand-ins only | `^\t\tmine\[(actor\|maw)\.model\] = true$` | 2 |
| NI6 | `MawYaw` home through `kit.authored` | `^\tlocal mawHome = kit\.authored\(NoctyssPath\.LANES\[1\]\)$` | 1 |
| NI7 | the handoff frame, three explicit values | `^\t\t\t\tmaw:set\("Maw(Rise\|Gape\|Yaw)", ` | 3 |
| NI8 | two `onRealBoss` retirements (choir, maw) | `^\t\tkit\.onRealBoss\(function\(\)$` \| `^\tkit\.onRealBoss\(function\(\)$` | 2 |

**NI2 is the only expected-zero `kit.mesh` count in the unit and it is a
decision, not an omission.** `NoctyssArena_DecoVeins` is **one merged object
carrying all seven crests**, so there is no per-vein object to clone, seven clones
would each draw all seven strips, and the `Size`-squash that works on Rimefang's
flat ice (§6.6) produces a compressed seven-armed star. The beat's whole read is
*light running outward along one vein at a time*, which only a directional segment
can carry. NI4 is there so the next reader does not "fix" it.

**NI1 is a contradiction in the design resolved toward the code** — see §6.7.

**NI5 is how a real `choir_stalk` is told from one of ours.** Every `Grow` write is
an `actor:tween` on a model this file created; the retirement scan consults
`mine[]`. No real fight model is ever written by this script.

### `src/Client/Cutscenes/KrakenIntro.luau` — 11 landmarks (rewrite, 792 lines)

| ID | Hunk | Landmark | Count |
|----|------|----------|-------|
| KI1 | the hook is armed with the frame writer | `^\t\tKraken\.setCutscene\(conduct\)$` | 1 |
| KI2 | …and retired by `setCutscene(nil)` | `^\t\t\tKraken\.setCutscene\(nil\)$` | 1 |
| KI3 | **blend weight 0 WRITES NOTHING** | `^\t\tif w <= 0 then$` | 1 |
| KI4 | the weight walks 1 → 0 at the handoff | `^\t\tstage\.w = 1 - u$` | 1 |
| KI5 | **`ArmPhase` is NEVER written** | `:set\("ArmPhase"` | **0** |
| KI6a | `rootZ` derived from the rig primitives | `^\tlocal rootZ = RIG\.HEAD_Z \+ RIG\.ROOT_FORWARD \* RIG\.SCALE$` | 1 |
| KI6b | `deckRise` derived | `^\tlocal deckRise = \(RIG\.DECK_Y \+ RIG\.TIP_GIRTH\) / RIG\.RISE_SPAN$` | 1 |
| KI6c | `sweepRise` derived | `^\tlocal sweepRise = \(RIG\.DECK_Y \+ RIG\.SWEEP_CLEAR \+ RIG\.TIP_GIRTH\) / RIG\.RISE_SPAN$` | 1 |
| KI7 | **`PoseCenter` = the SHIP centre** | `^\t-- PoseCenter = the SHIP centre\.` | 1 |
| KI8 | the handoff instant, 18.6 | `^\tlocal SINK1 = 18\.6 -- THE HANDOFF$` | 1 |
| KI9 | `Adrift` untabulated in the bend law | `^-- .Adrift. IS NOT IN THAT TABLE` | 1 |

**KI2's executed count is 1, and the slice note's "retires three ways" is still
true.** The single `setCutscene(nil)` line sits inside one guarded retire helper
that is reached from **three** places — `kit.at(18.6)`, `kit.onRealBoss`, and (the
path that cannot be skipped) from inside the hook itself the frame after the
stand-in leaves the tree. The landmark counts the line; the three ways are the
call sites into it. **If anyone adds a fourth way out of a cutscene, the third
guard is the one that has to keep working** — `KrakenBodyController.setCutscene`
is **module state, not rig state**, so a hook left armed after the cinematic ends
freezes the live fight on a cutscene frame for the rest of the session, and
`kit.finish` destroys the actor on every cancel path and knows nothing about a
module-level hook.

**KI3 is the staging discipline in one line.** `stage.w` is a blend weight, and at
`w = 0` the hook writes **nothing** rather than writing the fight's own values —
so the handoff is not "we computed the same numbers", it is "we stopped
computing".

**KI5 is an expected zero and it is a *capability* statement, not a choice.**
`frame.tentacles[i]` is `{ bearing, radius, rise, curl, tip, visible }` — it
carries **no `ArmPhase` and no `ArmT`** — so the design's "`ArmPhase` held at
`Rear`" is unreachable through this seam at all (§7.4). The sweep is expressed as
a polar walk of the tip through `tipOverride`, the fight's own sanctioned seam.

### `src/Client/Cutscenes/WrackIntro.luau` — 11 landmarks (rewrite, 795 lines)

| ID | Hunk | Landmark | Count |
|----|------|----------|-------|
| WI1 | the four `GUNS` rows (controller's table) | `at = Vector3\.new\(-?16\.45, 1[34](\.2)?, -?9\.5\),` | 4 |
| WI2a | **three** lids: masks 1, 3, 7 | `^\tfor i, mask in \{ 1, 3, 7 \} do$` | 1 |
| WI2b | …and they **SHUT** at the settle | `^\t\tstand:set\("WrackHatches", 0\)$` | 1 |
| WI3 | **the `mask = 15` write is GONE** | `^\t\t\tstand:set\("WrackHatches", 15\)` | **0** |
| WI4 | the heave is a **bow-lift bump** | `^\t\tbowLift = math\.rad\(9\),$` | 1 |
| WI5a | `sailBearing` — the `kit.polar` convention | `^\tlocal sailBearing = mouth \+ math\.pi$` | 1 |
| WI5b | `sailYaw = −sailBearing` — the model convention | `^\tlocal sailYaw = -sailBearing$` | 1 |
| WI6 | **`cue("arrive")` is NOT called** | `cue\(stand\.model, "arrive"` | **0** |
| WI7 | …the Admiral is conducted with `windup` | `^\t\t\tWrack\.cue\(stand\.model, "windup", \{$` | 1 |
| WI8 | the Lady flies on `WrackDive = 0` | `^\t\tattrs = \{ WrackDive = 0 \},$` | 1 |
| WI9 | `place(0)` **is** the rise's own first frame | `^\tlocal function place\(e: number\)$` | 1 |

**WI3 and WI6 are the unit's two other expected zeros, and both are real
deletions of things that looked like they worked.** `mask = 15` set a bit with no
`Hatch4` behind it — there are **three** lids. `cue("arrive")` reaches the ship's
body and changes nothing: `admArriveLand` and `admArriveDraw` are both
`kinds = { duel = true }`, the *duelist's* act-3 landing, and the ship's kind
(`CreatureId = "admiral_wrack"`) does not carry those rows. A cue that reaches a
body and does nothing is the exact failure shape this record exists to catch, and
the design's "Channels newly used: … the `arrive` cue" line is **wrong for this
boss** (§7.3).

**WI5a/WI5b are a sign-convention pair and they must stay adjacent.**
`CFrame.Angles(0, y, 0)` maps the bow (+X) to `(cos y, 0, −sin y)`; `kit.polar`
reads a bearing as `(cos b, 0, sin b)`. So **`yaw = −bearing`** — and `WrackBoom`
is published in the *bearing* convention (`Fn.wrackAngle`'s `atan2(dir.Z, dir.X)`),
not the yaw one, i.e. the boom's pivot is the opposite sign from the hull's yaw.
Mixing them was one of two bugs found in that slice's own first draft, and both
drafts passed every gate.

**WI9's `place(e)` is the server's pose arithmetic, copied**, which is what makes
"she is at the rise's first frame" `place(0)` rather than a constant that can
drift. Measured continuity at every window boundary is **exact** to four decimals
in radius, y, yaw, pitch and roll (§6.9).

### `src/Shared/Data/BossCutscenes.luau` — 5 landmarks, **untracked, and NOT ours**

| ID | Hunk | Landmark | Count |
|----|------|----------|-------|
| DC1 | `brinejaw` **22 — UNCHANGED, no edit owed** | `^\tbrinejaw = \{ duration = 22, script = "BrinejawIntro" \},$` | 1 |
| DC2 | `rimefang` 18 → **20** | `^\trimefang = \{ duration = 20, script = "RimefangIntro" \},$` | 1 |
| DC3 | `noctyss` 20 → **22** | `^\tnoctyss = \{ duration = 22, script = "NoctyssIntro" \},$` | 1 |
| DC4 | `admiral_wrack` 20 → **22** | `^\tadmiral_wrack = \{ duration = 22, script = "WrackIntro" \},$` | 1 |
| DC5 | `kraken` **STAYS 24** (the guard string) | `^\tkraken = \{ duration = 24, script = "KrakenIntro" \},$` | 1 |

**This whole file is untracked and belongs to the cutscene lane (session 30).**
Three of its rows are this unit's stake; the unit **cannot go green without
DC2–DC4**, because the server reads `duration` to schedule the raise at
`duration − riseTime` and all three scripts are written to the longer row (§3.2).
**Coordinate, don't stage it.**

**DC1 is the row with no edit, and it is listed on purpose.** The Brinejaw design
asks for 22 and the row was *already* 22, so there is nothing to do — and a reader
auditing "four durations moved" would otherwise go looking for a fourth hunk that
does not exist.

**DC5 is a guard, not a change.** The `kw` slice applied DC4 through a
read-then-write that re-reads at the instant of writing and asserts the
`admiral_wrack` anchor is present exactly once *and* that the `kraken` row is
still there — because the file's mtime was **four minutes old** when that slice
reached it (another lane had just landed DC2 and DC3). If DC4 ever has to be
re-applied, those are the two strings.

### `tools/` — 10 landmarks, the Brinejaw Entry gate, **all three files untracked**

| ID | Hunk | Landmark | Count |
|----|------|----------|-------|
| T1 | the driver takes `--control` | `^    ap\.add_argument\("--control"` | 1 |
| T2 | …and `--keep` prints the assembled chunk | `^    ap\.add_argument\("--keep"` | 1 |
| T3 | the stub is a Vector3 stand-in | `^local Vector3 = \{\}$` | 1 |
| T4 | the probe prints machine-readable rows | `^\tprint\(string\.format\("GATE` | 1 |
| T5 | **GATE 0 exists and the design does not list it** | `^-- GATE 0 ` | 1 |
| T6 | **gate 8: `collapse-inside-slump`** | `^    print\(f"GATE\\tcollapse-inside-slump` | 1 |
| T7 | …`MIN_MARGIN` = 0.10 s of ramp each side | `^MIN_MARGIN = 0\.10$` | 1 |
| T8 | …the four numbers are **READ, never restated** | `^def number_table\(text: str, name: str\) -> dict:$` | 1 |
| T9 | …the controller's filter simulated at **60 Hz** | `^STEP_HZ = 60\.0$` | 1 |
| T10 | …and the driver reports `gates + 1` | `^    print\(f"\\nBRINEJAW ENTRY CHECK OK: \{len\(gates\) \+ 1\} gates pass\."\)$` | 1 |

The driver concatenates stub + module (wrapped in `(function() … end)()`, with the
`--!nonstrict` hot comment stripped) + probe into one chunk and runs `luau` on it.
`--keep` prints `luau <path>` for the assembled chunk, which is the "how do I run
it by hand" answer.

**The gate ships with the unit** (§3.5). Executed, on the current worktree:

```
GATE anchors-computed  PASS  join r 31.000 (restPoint 31.001), ghost r 24.590
                             (restPoint 24.590); TAIL_OUT +7 moved the join 7.000
INFO L_rest(2000) = 288.64  spline = 782.7 studs = 2.712 body-lengths
     breach sigma = 0.7887  A = -0.8887
GATE body-length       PASS  rest 288.15 studs; worst +3.27% at Entry 0.90
GATE handoff-exact     PASS  max |Entry=1 - rest| = 0.000e+00 studs over 2001 samples
GATE hidden-at-zero    PASS  highest body y = -20.58, plane at 0.00
GATE spire-clearance   PASS  min clearance 22.50 studs at sigma 0.000
GATE apex-over-lantern PASS  apex y = 72.58 at sigma 0.457, lantern 64.60
GATE surfacing-order   PASS  100 of 100 links breach inside 0..1; link 1 at Entry
                             0.056, link 100 at 0.580, monotonic true
SUMMARY 7 gates, 0 failed
GATE collapse-inside-slump PASS  eased Entry crosses HOME 0.998 at t = 16.967;
                             slump ramp 16.60..17.30 (margins +0.367 / +0.333,
                             need 0.10); EASE.entry 3.0/s
BRINEJAW ENTRY CHECK OK: 8 gates pass.

--control (APEX knot y 72 -> 40):
CONTROL OK: 1 of 7 measured gates failed on the perturbed knot
(apex-over-lantern). The ordering gate reads the schedule rather than the knots
and is unaffected by design.
```

**Seven gates live in the Luau probe; gate 8 lives in the Python driver**, and
that split is not cosmetic — gate 8's inputs are in **two files neither of which
the probe can see** (`BrinejawIntro`'s schedule, the controller's ease rate and
two thresholds), so it parses them out and simulates the controller's own
first-order filter at 60 Hz. **It refuses to pass if it cannot parse them**,
which is the `--control` lesson applied to a gate whose inputs are prose-adjacent.
`--control` perturbs a *knot*, so gate 8 is correctly unaffected by it and the
driver's control line says so by name rather than counting it as a silent pass.
(The function's docstring calls itself "GATE 7" while the driver prints 8 — an
off-by-one in **prose only**, and the kind this codebase pays for; worth one
word's fix by the gate's owner.)

**`--control` is the half that makes the other seven mean anything.** A probe run
against a module whose function has vanished looks exactly like a probe that
measured nothing and prints a confident PASS; `--control` perturbs one authored
knot (`APEX` y 72 → 40) and the run **must** fail exactly one gate.

### `src/Client/Modules/CutsceneKit.luau` — 2 landmarks, **DEPENDENCY, not a hunk**

| ID | What | Landmark | Count |
|----|------|----------|-------|
| D1 | `kit.mesh` present in the worktree kit | `^\tfunction kit\.mesh\(pack: string, name: string, props\): BasePart$` | 1 |
| D2 | `kit.meshTween` present in the worktree kit | `^\tfunction kit\.meshTween\(part: BasePart, props, t0: number, t1: number, ease: any\?\)$` | 1 |

Checked here **because all five scripts call them with no fallback branch**, on the
coordinator's instruction that they had landed. **This unit adds nothing to this
file and must not stage it** (§3.1, §8).

---

## 2. By-name baselines: HEAD vs worktree

The pyrelisk record's brace-aware row walker is the right tool for
`Bosses.items`-shaped files; **this unit has almost nothing for it to walk**,
because eight of its eleven paths have no HEAD side at all. So the baseline here
is by **membership**, and it is executed.

### `src/Client/Cutscenes/` — the whole directory is untracked

`git show HEAD:src/Client/Cutscenes/` → **does not exist**. Every file in it is
"new" against HEAD and a set-diff is meaningless. Comparison is by membership:

| file | lines | this unit? |
|---|---|---|
| `BrinejawIntro.luau` | 724 | **yes** |
| `RimefangIntro.luau` | 830 | **yes** |
| `NoctyssIntro.luau` | 740 | **yes** |
| `KrakenIntro.luau` | 792 | **yes** |
| `WrackIntro.luau` | 795 | **yes** |
| `GnashrootIntro.luau` | 608 | **no — session 30's** |
| `PyreliskIntro.luau` | 786 | **no — session 30's** |
| `_Example.luau` | 52 | **no — session 30's** |

**Eight files, five of them ours, and one `git add src/Client/Cutscenes/` lands
all eight.** That is not a reason to stage by directory; it is the reason §8 has
a coordination step. Confirm the count is still 8 before staging — a ninth file
appearing means another lane is mid-write in this directory.

### `src/Shared/Data/BossCutscenes.luau` — untracked, 7 rows

`git show HEAD:src/Shared/Data/BossCutscenes.luau` → **does not exist.** Executed
membership, all seven rows and their durations:

| boss | duration | script | lane |
|---|---|---|---|
| `brinejaw` | 22 | `BrinejawIntro` | **ours (unchanged, DC1)** |
| `old_gnashroot` | 22 | `GnashrootIntro` | session 30 |
| `rimefang` | **20** (was 18) | `RimefangIntro` | **ours, DC2** |
| `pyrelisk` | 26 | `PyreliskIntro` | session 30 |
| `noctyss` | **22** (was 20) | `NoctyssIntro` | **ours, DC3** |
| `admiral_wrack` | **22** (was 20) | `WrackIntro` | **ours, DC4** |
| `kraken` | 24 | `KrakenIntro` | **ours by adjacency only — DC5 guard, unchanged** |

**REMOVED must always be empty** — a row disappearing is the tripwire for a
reconstruct-commit, and here it would take a boss's whole cinematic offline with
`durationFor` returning nil. Executed: **7 rows, none removed.**

### The two tracked files

These are the only two paths in the unit with a HEAD side, and they are shared
and live. Attribute **by name, never by offset.**

| file | HEAD | worktree | this unit's stake |
|---|---|---|---|
| `BrinejawPath.luau` | 26 top-level locals | **26** | BP1–BP9, 13 landmarks, **+327/−1** (untouched by the §6a hunk) |
| `BrinejawBodyController.luau` | — | — | BC1–BC15, 15 landmarks, **+180/−3** |

`grep -cE '^local ' src/Shared/Modules/BrinejawPath.luau` → **26**, unchanged
across the whole slice (§5). The `Entry` section's twelve additions all hang off
`BrinejawPath.*` and the arc-length cache is one table field
(`BrinejawPath.entryCache`), precisely so this number does not move.

---

## 3. The dependency statement — **one unit, or none**

No subset of this work is green. Each link below was checked against the current
worktree, not assumed.

1. **All five scripts → `kit.mesh` / `kit.meshTween` → the worktree
   `CutsceneKit.luau`.** They are called **directly, with no
   `if kit.mesh then … else … end` branch anywhere**, per the coordinator's
   instruction that the pair had landed (verified: D1, D2, and in the `rn` slice
   against `packPrefix` at `:108`, `kit.mesh` at `:727`, `kit.meshTween` at
   `:818`). Land the scripts without that `CutsceneKit` and **four of five
   cinematics call a nil value on their first prop**. The file is session 30's:
   **coordinate, do not stage it.**
2. **`BossCutscenes` durations → the scripts' own timelines.** The server reads
   `duration` and schedules the raise at `duration − riseTime`. `RimefangIntro` is
   written against 20 (`raiseAt` 16.2), `NoctyssIntro` against 22 (`raiseAt` 17.5,
   card 21.325, douse 20.7, relight 21.55), `WrackIntro` against 22 (`raiseAt`
   17.8). Land the scripts on the **old** rows and every one of them has its
   handoff instant *after* the real boss is raised — which is not an error, it is
   a visible double body. Land the rows without the scripts and the pre-fight hold
   grows 2 s for three bosses with nothing filling it.
3. **`BrinejawIntro` → the `BrinejawPath` Entry section → the controller's read,
   and the chain breaks in a different place at each cut.**
   - Script without the path section: `stand:set("Entry", …)` writes an attribute
     nothing consumes, and the serpent is drawn in its **fight** pose, at the
     arena centre, for the whole arrival. Nothing errors.
   - Script + path without **BC4** (the controller's read): identical outcome, and
     it is worse to diagnose, because the channel is *implemented* and *documented*
     and simply never reaches `state.entry`. This is the
     `silent-absence-failures.md` shape and it is why BC4 is its own landmark.
   - Path + controller without the script: inert. `entry == nil` falls through the
     guard and everything is lazy — `entryData()` builds on the first frame that
     reads the channel, so a server that never writes `Entry` never builds the
     4001-entry table at all. **This is the one cut that is safe**, and it is the
     only reason the two tracked files could in principle go first.
4. **`BrinejawBodyController.setEntrySplash` → `BrinejawIntro`'s hook →
   `pendingSplash`.** The splashes come from the drawn body's own water-plane
   crossings, **not** from the design's 25 scheduled `kit.at` cues (§6.8). Land the
   script without BC5 and it calls a nil member; land BC5 without BC3/BC7 and the
   hook is handed to a model the controller has not met yet — `kit.actor` writes
   `Pose` last and the adopt rides **deferred** signals, so a hook installed on the
   next line arrives before `adoptBoss` does. `pendingSplash` parks it.
5. **The gate ships with the unit.** `git show HEAD:tools/check_brinejaw_entry.py`
   → **does not exist**; all three tool files are untracked. Land the `Entry`
   channel without them and every one of the eight invariants — the join
   is exact, the body holds its length, the handoff is bit-identical, nothing is
   visible at `Entry 0`, the spline clears the spire, the apex clears the lantern,
   the links surface tail-ward in order — becomes **unchecked forever**, and each
   one fails *silently and plausibly*: a serpent that stretches, an arrival that
   clips the tower, a handoff that pops. **Gate 8 is the sharpest case**: it is
   the only thing anywhere that checks four numbers in two files still agree, and
   the schedule it guards was wrong on its first apply (§6a). Nothing else in the
   project can see any of it.
6. **`NoctyssIntro` → `NoctyssPath.SNAP.RISE_TO`; `RimefangIntro` →
   `Bosses.items.rimefang.attacks.icebreach.{rise,duration}`; `WrackIntro` →
   `WrackBodyController`'s `GUNS` rows; `KrakenIntro` → `setCutscene`'s polar
   frame fields.** All four are **reads of files this unit does not write**, and
   that is the design: the value has exactly one home and the cinematic asks for
   it. The cost is that a rename in any of those four files breaks a cinematic
   with no gate seeing it — `SNAP.RISE_TO`, the two `icebreach` field names, the
   `GUNS` row shape, and `frame.tentacles[i]`'s six fields are **contract names**.
7. **`KrakenIntro`'s hook is module state and its retirement is part of the unit.**
   `KrakenBodyController.setCutscene` is not rig state: a hook left armed after
   the cinematic ends freezes the **live fight** on a cutscene frame for the rest
   of the session. Three paths retire it and the third (from inside the hook, the
   frame after the stand-in leaves the tree) is the one no cancel path can skip.

> Every link in this chain has the same shape — **the value exists somewhere
> nothing reads it**, and it presents as a milder, different problem: a cinematic
> that draws the fight pose, a cue that reaches a body and does nothing, a
> duration that raises the boss over its own stand-in, a frozen fight three
> sessions later. Not a crash. That is why the rule is *one unit or none*, and why
> the check is a landmark count rather than "did it build".

**Gate reminder:** `selene` / `check_compile` / `check_content` / `rojo build`
**cannot see any of this.** They cannot see an attribute nobody reads, a cue with
no matching `kinds` row, a duration that disagrees with a script's timeline, or a
module-level hook left armed. Nor can they see the Luau 200-local limit —
`luau-compile -O0` (gate five) is the only check that does, and
`tools/check_brinejaw_entry.py` (gate six, **in this unit**) is the only thing in
the project that checks the arrival's geometry. All gates passing on a partial
commit means nothing here.

---

## 4. Inline re-run script

Save anywhere (it resolves the repo root itself) and run. It is read-only.
Expected output: **104 OK lines and `ALL LANDMARKS PRESENT`**, exit 0.

```sh
#!/bin/sh
# Boss-cutscene rework unit audit. Run from anywhere; it cds to the repo root.
root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "not a git checkout"; exit 1; }
[ -n "$root" ] || { echo "empty repo root"; exit 1; }
cd "$root" || exit 1
BP=src/Shared/Modules/BrinejawPath.luau
BC=src/Client/Controllers/BrinejawBodyController.luau
BI=src/Client/Cutscenes/BrinejawIntro.luau
RI=src/Client/Cutscenes/RimefangIntro.luau
NI=src/Client/Cutscenes/NoctyssIntro.luau
KI=src/Client/Cutscenes/KrakenIntro.luau
WI=src/Client/Cutscenes/WrackIntro.luau
DC=src/Shared/Data/BossCutscenes.luau
GP=tools/check_brinejaw_entry.py
GS=tools/brinejaw_entry_stub.luau
GB=tools/brinejaw_entry_probe.luau
KT=src/Client/Modules/CutsceneKit.luau
fail=0; n=0
ck() { n=$((n+1)); got=$(grep -cE "$4" "$3" 2>/dev/null); got=${got:-0}
  if [ "$got" = "$1" ]; then printf 'OK   %-52s %s\n' "$2" "$got"
  else printf 'FAIL %-52s want %s got %s\n' "$2" "$1" "$got"; fail=1; fi; }
blk() { n=$((n+1)); got=$(sed -n "$4,$5p" "$3" | grep -cE "$6"); got=${got:-0}
  if [ "$got" = "$1" ]; then printf 'OK   %-52s %s\n' "$2" "$got"
  else printf 'FAIL %-52s want %s got %s\n' "$2" "$1" "$got"; fail=1; fi; }

echo "--- BrinejawPath.luau (hunks 1-3) ---"
ck 1  "BP1  header: Entry is NOT ON THE WIRE"        $BP '^-- \.\.\.AND ONE ELEVENTH THAT IS NOT ON THE WIRE'
ck 1  "BP2  ENTRY_WATER_Y = 0.0 (derived)"           $BP '^BrinejawPath\.ENTRY_WATER_Y = 0\.0$'
ck 1  "BP3  ENTRY_SUBMERGE = 0.10"                   $BP '^BrinejawPath\.ENTRY_SUBMERGE = 0\.10$'
ck 2  "BP4  ENTRY_SAMPLES / ENTRY_REST_SAMPLES"      $BP '^BrinejawPath\.ENTRY_(SAMPLES|REST_SAMPLES) = '
ck 1  "BP5a ENTRY_KNOTS table opens"                 $BP '^BrinejawPath\.ENTRY_KNOTS = \{$'
ck 1  "BP5c knot 8 IS THE BREACH (248, 162, 0)"      $BP '^	\{ 248\.000, 162\.000, 0\.000 \}, -- THE BREACH'
ck 7  "BP6  the seven Entry functions"               $BP '^function BrinejawPath\.(entryKnots|entryAux|entryData|entrySpline|entryJoined|entryHead|entryOfBreach)\('
ck 1  "BP7  arc-length cache is ONE table field"     $BP '^	BrinejawPath\.entryCache = data$'
ck 1  "BP8a pointAt guard line 1 (reads state.entry)" $BP '^	local entry = state\.entry$'
ck 1  "BP8b pointAt guard line 2 (entry < 1)"        $BP '^	if entry and entry < 1 then$'
ck 1  "BP8c pointAt guard line 3 (entryJoined)"      $BP '^		return \(state\.center or Vector3\.zero\) \+ BrinejawPath\.entryJoined\(state, x\)$'
ck 26 "BP9  top-level locals STILL 26 (gate five)"   $BP '^local '

echo "--- BrinejawPath.luau: the 16 AUTHORED knots ---"
n=$((n+1)); got=$(sed -n '/^BrinejawPath\.ENTRY_KNOTS = {/,/^}/p' $BP | grep -cE '^	\{ ')
if [ "$got" = "16" ]; then printf 'OK   %-52s %s\n' "BP5b 16 authored knot rows" "$got"
else printf 'FAIL %-52s want 16 got %s\n' "BP5b 16 authored knot rows" "$got"; fail=1; fi

echo "--- BrinejawBodyController.luau (hunks 1-9) ---"
ck 1  "BC1  EASE.entry = 3.0"                        $BC '^	entry = 3\.0,$'
ck 1  "BC2  ENTRY thresholds table (0.998/0.995/0.02/0.25)" $BC '^local ENTRY = \{ HOME = 0\.998, ATTR_HOME = 0\.995, STEP_MAX = 0\.02, CUT = 0\.25 \}$'
ck 1  "BC3  pendingSplash declared beside bodies"    $BC '^local pendingSplash = \{\}$'
ck 1  "BC4  target.entry read with NO 'or' default"  $BC '^	target\.entry = model:GetAttribute\("Entry"\)$'
ck 1  "BC5  public setEntrySplash"                   $BC '^function BrinejawBodyController\.setEntrySplash\(model: Model, fn\)$'
ck 3  "BC6  body literal: aboveWater/entrySplash/entryLast" $BC '^		(aboveWater|entrySplash|entryLast) = '
ck 1  "BC7  adoptBoss claims the parked hook"        $BC '^	body\.entrySplash = pendingSplash\[model\]$'
ck 2  "BC8  pendingSplash cleared (adopt + destroy)" $BC '^	pendingSplash\[model\] = nil$'
ck 1  "BC9  collapse rule A: attr >= ATTR_HOME"      $BC '^	if wantedEntry ~= nil and wantedEntry >= ENTRY\.ATTR_HOME then$'
ck 1  "BC10 collapse rule B: EASED >= HOME -> nil"   $BC '^		state\.entry = if eased >= ENTRY\.HOME then nil else eased$'
ck 1  "BC11 cut rule: a step past ENTRY.CUT is a cut" $BC '^		if state\.entry and math\.abs\(wantedEntry - state\.entry\) > ENTRY\.CUT then$'
ck 1  "BC12 water plane = centre.Y + ENTRY_WATER_Y"  $BC '^	local waterY = \(state\.center or Vector3\.zero\)\.Y \+ BrinejawPath\.ENTRY_WATER_Y$'
ck 1  "BC13 splash gated on the frame step"          $BC '^	local splashOk = entryStep <= ENTRY\.STEP_MAX$'
ck 1  "BC14 per-link crossing calls the hook once"   $BC '^				local ok, err = pcall\(splash, index, cframe\.Position, state\.entry\)$'
n=$((n+1)); got=$(sed -n '/if wantedEntry ~= nil and wantedEntry >= ENTRY\.ATTR_HOME then/,/state\.entry = if eased >= ENTRY\.HOME/p' $BC | grep -ci slump)
if [ "$got" = "0" ]; then printf 'OK   %-52s %s\n' "BC15 the collapse is UNCONDITIONAL (no Slump gate)" "$got"
else printf 'FAIL %-52s want 0 got %s\n' "BC15 the collapse is UNCONDITIONAL (no Slump gate)" "$got"; fail=1; fi

echo "--- BrinejawIntro.luau (rewrite) ---"
ck 1  "BI1  ENTRY_STEPS is the arrival's ONE home"   $BI '^local ENTRY_STEPS = \{$'
blk 5 "BI2  five ENTRY_STEPS rows, one shape each"   $BI '/^local ENTRY_STEPS = {/' '/^}/' '^	\{ t0 = T\.'
ck 1  "BI3  the splash hook, not 25 kit.at cues"     $BI '^		BrinejawBodyController\.setEntrySplash\(stand\.model, function\(index, position\)$'
ck 1  "BI4  requires the controller (no cycle)"      $BI '^local BrinejawBodyController = require\(script\.Parent\.Parent\.Controllers\.BrinejawBodyController\)$'
ck 1  "BI5  waterline DERIVED from kit, not typed"   $BI '^	local waterLocal = kit\.waterY - cy$'
ck 1  "BI6  FaceAngle opens at BEARING - 0.8"        $BI '^	local restFace = rest\.BEARING - 0\.8$'
ck 3  "BI7  kit.mesh call sites (BrinejawFxPack)"    $BI 'kit\.mesh\("BrinejawFxPack"'
ck 1  "BI8  the 12 script primitives are down to 1 kit.part" $BI 'kit\.part\('
ck 1  "BI9  Entry removed at the handoff"            $BI '^		stand:set\("Entry", nil\)$'
ck 3  "BI10 shots that AIM AT headAt(t), not a point" $BI '^			return headAt\(t\)$'
ck 1  "BI11 the slump ramp is NAMED, not typed"      $BI '^	kit\.track\(T\.slump0, T\.slump1, "in", function\(u\)$'
ck 1  "BI12 T.entryHome = 16.4 (Entry reaches 1)"    $BI '^	entryHome = 16\.4,$'
ck 2  "BI13 T.slump0 16.6 / T.slump1 17.3"           $BI '^	slump(0 = 16\.6|1 = 17\.3),$'
ck 2  "BI14 T.coil1 / T.settle0 pulled to 15.6"      $BI '^	(coil1|settle0) = 15\.6,$'
ck 1  "BI15 last row: SMOOTH, ends at T.entryHome"   $BI '^	\{ t0 = T\.settle0, t1 = T\.entryHome, from = 0\.970, to = 1\.000, shape = smooth \},$'
ck 1  "BI16 the handoff comment states WHERE it lands" $BI '^	-- THE COLLAPSE, AND WHERE IT LANDS\.'

echo "--- RimefangIntro.luau (rewrite) ---"
ck 1  "RI1a icebreach.rise quoted off the Bosses row" $RI '^	icebreachRise = 0\.2, -- icebreach\.rise'
ck 1  "RI1b icebreach.duration quoted off the row"   $RI '^	icebreachStrike = 0\.7, -- icebreach\.duration'
ck 0  "RI2  submergeShed = 0.16 DELETED (was typed)" $RI 'submergeShed = 0\.16'
ck 1  "RI3a shed fraction SOLVED, not typed"         $RI '^	local shedStrikeU = N\.icebreachRise / N\.icebreachStrike$'
ck 1  "RI3b the fight.s cubic climb"                 $RI '^	local submergeShed = N\.burstImpact \* \(1 - \(1 - shedStrikeU / N\.burstImpact\) \^ 3\)$'
ck 1  "RI3c the time is this cinematic.s own inverse" $RI '^	local submergeEnd = timeOfBurst\(submergeShed\)$'
ck 1  "RI4  Submerge shed ends at submergeEnd"       $RI '^	whale:tween\("Submerge", 1, 0, N\.burstT0, submergeEnd, "inout"\)$'
ck 3  "RI5  FlukeUp newly driven (3 tweens)"         $RI '^	whale:tween\("FlukeUp", '
ck 2  "RI6  Roll newly driven on the roar"           $RI '^	whale:tween\("Roll", '
ck 4  "RI7  RimefangArena mesh call sites (44 clones)" $RI 'kit\.mesh\("RimefangArena"'
ck 0  "RI8  no script-built kit.part left"           $RI 'kit\.part\('
ck 1  "RI9  camera aim points come from RimefangPath" $RI '^	local function poseHead\(fields\): Vector3$'
ck 1  "RI10 the beached lobtail CANNOT DRAW (moved)" $RI '^-- on the beached body\. .FlukeUp. CANNOT DRAW THERE\.'

echo "--- NoctyssIntro.luau (rewrite) ---"
ck 1  "NI1  MawRise cap READ from SNAP.RISE_TO"      $NI '^	local mawTop = NoctyssPath\.SNAP\.RISE_TO$'
ck 0  "NI2  DecoVeins substitution REFUSED: 0 kit.mesh" $NI 'kit\.mesh\('
ck 1  "NI3  one light only - no violet fill"         $NI 'kit\.light\('
ck 1  "NI4  the refusal is stated, not silent"       $NI 'DecoVeins is ONE merged'
ck 2  "NI5  mine\[\] ledger: stand-ins only"           $NI '^		mine\[(actor|maw)\.model\] = true$'
ck 1  "NI6  MawYaw handoff via kit.authored(LANES\[1\])" $NI '^	local mawHome = kit\.authored\(NoctyssPath\.LANES\[1\]\)$'
ck 3  "NI7  the handoff frame, three explicit values" $NI '^				maw:set\("Maw(Rise|Gape|Yaw)", '
ck 2  "NI8  two onRealBoss retirements (choir + maw)" $NI '^		kit\.onRealBoss\(function\(\)$|^	kit\.onRealBoss\(function\(\)$'

echo "--- KrakenIntro.luau (rewrite) ---"
ck 1  "KI1  the hook is armed with the frame writer" $KI '^		Kraken\.setCutscene\(conduct\)$'
ck 1  "KI2  ...and retired by setCutscene(nil)"      $KI '^			Kraken\.setCutscene\(nil\)$'
ck 1  "KI3  blend weight 0 WRITES NOTHING"           $KI '^		if w <= 0 then$'
ck 1  "KI4  the weight walk 1 -> 0 at the handoff"   $KI '^		stage\.w = 1 - u$'
ck 0  "KI5  ArmPhase is NEVER written (frame lacks it)" $KI ':set\("ArmPhase"'
ck 1  "KI6a rootZ derived from the rig primitives"   $KI '^	local rootZ = RIG\.HEAD_Z \+ RIG\.ROOT_FORWARD \* RIG\.SCALE$'
ck 1  "KI6b deckRise derived"                        $KI '^	local deckRise = \(RIG\.DECK_Y \+ RIG\.TIP_GIRTH\) / RIG\.RISE_SPAN$'
ck 1  "KI6c sweepRise derived"                       $KI '^	local sweepRise = \(RIG\.DECK_Y \+ RIG\.SWEEP_CLEAR \+ RIG\.TIP_GIRTH\) / RIG\.RISE_SPAN$'
ck 1  "KI7  PoseCenter = the SHIP centre"            $KI '^	-- PoseCenter = the SHIP centre\.'
ck 1  "KI8  HANDOFF at 18.6, the hook retires there" $KI '^	local SINK1 = 18\.6 -- THE HANDOFF'
ck 1  "KI9  Adrift untabulated in the bend law (owner)" $KI '^-- .Adrift. IS NOT IN THAT TABLE'

echo "--- WrackIntro.luau (rewrite) ---"
ck 4  "WI1  the four GUNS rows (controller.s table)" $WI 'at = Vector3\.new\(-?16\.45, 1[34](\.2)?, -?9\.5\),'
ck 1  "WI2a three lids: masks 1, 3, 7"               $WI '^	for i, mask in \{ 1, 3, 7 \} do$'
ck 1  "WI2b ...and they SHUT at the settle"          $WI '^		stand:set\("WrackHatches", 0\)$'
ck 0  "WI3  mask = 15 write is GONE (no Hatch4)"     $WI '^			stand:set\("WrackHatches", 15\)'
ck 1  "WI4  place(e) heave replaced by a bow-lift bump" $WI '^		bowLift = math\.rad\(9\),$'
ck 1  "WI5a sailBearing (kit.polar convention)"      $WI '^	local sailBearing = mouth \+ math\.pi$'
ck 1  "WI5b sailYaw = -sailBearing (opposite signs)" $WI '^	local sailYaw = -sailBearing$'
ck 0  "WI6  cue(.arrive.) NOT called (duel-only)"    $WI 'cue\(stand\.model, "arrive"'
ck 1  "WI7  ...the Admiral is conducted with windup" $WI '^			Wrack\.cue\(stand\.model, "windup", \{$'
ck 1  "WI8  the Lady flies on WrackDive = 0"         $WI '^		attrs = \{ WrackDive = 0 \},$'
ck 1  "WI9  place(0) IS the rise.s own first frame"  $WI '^	local function place\(e: number\)$'

echo "--- BossCutscenes.luau (untracked; durations) ---"
ck 1  "DC1  brinejaw 22 (UNCHANGED, no edit owed)"   $DC '^	brinejaw = \{ duration = 22, script = "BrinejawIntro" \},$'
ck 1  "DC2  rimefang 18 -> 20"                       $DC '^	rimefang = \{ duration = 20, script = "RimefangIntro" \},$'
ck 1  "DC3  noctyss 20 -> 22"                        $DC '^	noctyss = \{ duration = 22, script = "NoctyssIntro" \},$'
ck 1  "DC4  admiral_wrack 20 -> 22"                  $DC '^	admiral_wrack = \{ duration = 22, script = "WrackIntro" \},$'
ck 1  "DC5  kraken STAYS 24 (the guard string)"      $DC '^	kraken = \{ duration = 24, script = "KrakenIntro" \},$'

echo "--- tools/: the Brinejaw Entry gate (untracked, gate six) ---"
ck 1  "T1  the driver exists and takes --control"    $GP '^    ap\.add_argument\("--control"'
ck 1  "T2  ...and --keep prints the assembled chunk" $GP '^    ap\.add_argument\("--keep"'
ck 1  "T3  the stub is a 50-line Vector3 stand-in"   $GS '^local Vector3 = \{\}$'
ck 1  "T4  the probe prints machine-readable GATE rows" $GB '^	print\(string\.format\("GATE'
ck 1  "T5  GATE 0 exists and the doc does not list it" $GB '^-- GATE 0 '
ck 1  "T6  gate 8: collapse-inside-slump"             $GP '^    print\(f"GATE\\tcollapse-inside-slump'
ck 1  "T7  ...MIN_MARGIN 0.10 s of ramp each side"   $GP '^MIN_MARGIN = 0\.10$'
ck 1  "T8  ...the four numbers are READ, not restated" $GP '^def number_table\(text: str, name: str\) -> dict:$'
ck 1  "T9  ...the controller filter simulated at 60 Hz" $GP '^STEP_HZ = 60\.0$'
ck 1  "T10 ...and the driver reports gates+1"        $GP '^    print\(f"\\nBRINEJAW ENTRY CHECK OK: \{len\(gates\) \+ 1\} gates pass\."\)$'

echo "--- CutsceneKit.luau: DEPENDENCY, not a hunk (cutscene lane owns it) ---"
ck 1  "D1  kit.mesh present in the worktree kit"     $KT '^	function kit\.mesh\(pack: string, name: string, props\): BasePart$'
ck 1  "D2  kit.meshTween present in the worktree kit" $KT '^	function kit\.meshTween\(part: BasePart, props, t0: number, t1: number, ease: any\?\)$'

echo "--- LANDED 2026-09-12: the collapse lands inside the slump ramp ---"
echo "     (gate 8 is the executable form of this; run: python3 tools/check_brinejaw_entry.py)"
echo
echo "landmarks checked: $n"
if [ $fail = 0 ]; then echo "ALL LANDMARKS PRESENT"; else echo "*** MISSING CUTSCENE HUNKS - SEE FAIL LINES ABOVE ***"; fi
exit $fail
```

### The four portability traps this script avoids

Each is recorded in `docs/pyrelisk-fight-handoff.md` §4 because a script failed on
it there. All four are live in this unit too.

1. **`cd "$(git rev-parse --show-toplevel)" || exit 1` does not fail when it
   should.** Outside a checkout `git rev-parse` fails, the substitution collapses
   to `cd ""`, and `cd ""` is a **successful no-op** in `sh` — so `|| exit 1`
   never fires and the audit runs against whatever directory you were in,
   reporting cheerful `OK 0`s. This script captures the root into a variable,
   tests the command **and** tests that the variable is non-empty. **Verified by
   running it from the scratchpad**: it prints `not a git checkout` and exits 1.
2. **`grep -c` exits 1 when the count is 0**, so `$(grep -c … || echo 0)` yields
   the string `"0\n0"` and every *expected-zero* landmark reports a false FAIL.
   The script uses plain substitution with `${got:-0}`. **This unit has seven
   expected-zero landmarks** — BC15, RI2, RI8, NI2, KI5, WI3, WI6 — which is more
   than the Pyrelisk unit's five, and a false FAIL on a deletion check is exactly
   the noise that gets an audit ignored.
3. **In a `sed` *address*, `\{` opens an interval** and errors with "braces not
   balanced". The two table-scoped checks here (BP5b, BI2) match the Luau `{` as a
   **bare** `{`, which is literal in a BRE address — *not* as `\{`, and not as
   `[{]` either (that would also work; bare is what is written).
4. **`printf '%-48s'` truncates nothing but misaligns everything** once IDs get
   long. Widened to `%-52s` here because the cutscene IDs carry a boss prefix.

One trap that is **new to this unit**: several landmarks are in **comment text**
(BP1, KI7, KI9, NI4, RI10, WI-header material). Comments are invisible to all five
gates, so a landmark on one is checking prose — which is deliberate, because the
prose *is* the deliverable for a mismatch that was flagged rather than fixed. But
it also means **a reflow can break a landmark without breaking the code.** If one
of those six FAILs, read the file before believing the hunk is gone.

---

## 5. The naming conventions that will trip the next reader

**1. `BrinejawPath.luau` is near the Luau 200-local limit, and every symbol this
unit adds is a field on `BrinejawPath`.** Top-level `local` count: **26**
(executed), unchanged across the whole slice. The twelve additions — four
constants, the knot table and the seven functions — all hang off `BrinejawPath.*`,
and the arc-length cache is **one table field** (`BrinejawPath.entryCache`) rather
than a file-level `local`. `luau-compile -O0` (gate five) is the only check in the
project that sees this; it took the game down on 2026-09-06. **No new top-level
`local` in this file, or in `CreatureService.luau` / `CreatureEventController.luau`.**

**2. `Entry` is the eleventh attribute and it is NOT ON THE WIRE.** The other ten
Brinejaw channels are published by the server every frame. `Entry` is written
**only** by a client cutscene, on a client-only stand-in model. The server builds
this boss's pose with `newState`, which has **no such field** — so
`state.entry` is `nil` on every server frame forever, and `pointAt`'s guard falls
through. A future reader who "completes" the channel by publishing it from
`CreatureService` has not finished the feature, they have put a cinematic
attribute on the fight's hot path (§7.9).

**3. `nil` is a value here, and `or 0` is the bug.** Nine of the controller's ten
reads end `or 0` or `or ""`. **BC4 must not**, and that asymmetry will look like
an oversight to the next person who tidies the function. `target.entry = nil`
means *the fight pose*; `target.entry = 0` means *out at sea, 178 studs away,
submerged*. There is a comment saying so directly above the line; the landmark
exists so a reflow cannot quietly drop it.

**4. Two thresholds, two names, and they are not interchangeable.**
`ENTRY.ATTR_HOME` (0.995) is a claim **the script makes** — "you are home"; it is
eased **to**, not cut to. `ENTRY.HOME` (0.998) is a fact **the controller
observes** about the drawn value, and crossing it is the collapse. Collapsing on
the attribute alone snaps the body by however far the ease still had to go (2.7
studs, measured at 0.99). Naming them the same thing, or folding them into one
constant, reintroduces exactly that.

**5. Bearing and yaw have opposite signs, and `WrackBoom` is published in the
bearing convention.** `yaw = −bearing` (§1, WI5a/b). This is written out in
`WrackIntro`'s header with the derivation because mixing them was one of two bugs
in that slice's own first draft — and both drafts passed every gate.

**6. `kit.mesh`'s `Color` / `Material` props override `MeshColors.get`.**
`kit.mesh` repaints the clone and *then* applies caller props, so passing `Color`
wins over the pack's own row. `RimefangIntro` does this **deliberately** — the same
props are what the no-import fallback slab is built from, so passing them keeps
the fallback byte-identical to what the cinematic drew before the pack existed.
The values are the arena's own ice blues, so it is a shade, not a repaint.

**7. `Size` is passed rather than `Scale` for every Rimefang ice prop** — see
§6.6. That is safe for *flat* objects only, and `NoctyssIntro` refuses the same
trick for exactly that reason (§6.7). The distinction is load-bearing and it is
stated in both files.

---

## 6. As-built findings — where the code and the design disagree

Every number below was **executed against the current worktree**, not transcribed
from a slice note. The full list, with the design's own wording, is the
"as-built deltas / errata" appendix appended to `docs/boss-cutscenes-redesign.md`
on 2026-09-12; this section carries the ones a **committer** needs.

### 6a. LANDED 2026-09-12 — the collapse now lands inside the `Slump` ramp, and **gate 8 asserts it**

**This was the unit's largest open risk when this record was first written, and
it is closed.** It is recorded at length because the *first* applied schedule was
wrong, the error was invisible to all five gates, and the fix is four numbers in
two files that nothing else ties together.

**The rule:** the ambient residual the collapse costs is acceptable **only while
the skull is already moving** — i.e. inside `BrinejawIntro`'s `Slump` ramp, where
the head travels 26 studs in 0.7 s. On a still frame the same step is a pop.

**What changed:**

| | as first applied | as landed |
|---|---|---|
| `T.coil1` / `T.settle0` | 16.4 | **15.6** |
| `Entry` reaches 1 at | `T.settle1` = 17.3 | **`T.entryHome` = 16.4** (named) |
| last `ENTRY_STEPS` shape | `easeIn` (`u²`) | **`smooth`** |
| the slump ramp | `kit.track(16.6, T.settle1, …)` — typed | **`kit.track(T.slump0, T.slump1, …)`** — named |
| collapse route | rule **1** (the script removes the attribute at 17.3) | rule **3** (the *eased* value crosses `HOME`) |
| collapse instant | t 17.300, at the ramp's closing edge | **t 16.967**, margins **+0.367 / +0.333 s** |
| checked by | nothing | **gate 8, `collapse-inside-slump`** |

**Why the shape was the bug, and it is the most transferable thing in this
record.** The controller chases `Entry` with a first-order filter
(`approach` = `1 − e^(−rate·dt)`, `EASE.entry` 3.0/s). **Such a filter's lag
against a ramp is slope / rate** — so the drawn value arrives at home only after
the attribute has *stopped* ramping. `easeIn` has its **maximum** slope at the end
of its window, precisely where the ease has to arrive: the drawn `Entry` was still
0.0145 short when the attribute hit 1, so rule 3 never fired, the script's
`Entry = nil` at 17.3 took over as rule 1, and the collapse became a **cut from a
value well short of home**. `smooth` leaves with **zero** slope, the lag falls to
nothing as the target arrives, and the collapse happens 0.57 s later with 0.002 of
track left — the documented 1.63 studs.

**The residual, measured with the harness's own method** (stub + worktree module +
the probe's `stateAt` helper; max over 401 body samples, the same method that
produces the published 1.63):

| eased value at collapse | max over body | head only |
|---|---|---|
| **0.9980** — `ENTRY.HOME`, **the landed case** | **1.631** | 1.106 |
| 0.9950 — `ATTR_HOME` | 3.525 | — |
| 0.9900 | 6.819 | — |
| 0.9863 — this audit's simulation of the old schedule at t 17.3 | **9.130** | 5.887 |
| 0.9855 — the 0.0145 shortfall as stated in the landed comment | 9.637 | 6.145 |
| 0.9835 | 10.759 | 6.771 |

> **One number to reconcile, flagged rather than adopted.** The landing note
> describes the old schedule as forcing "a ~4-stud step"; the file's own comment
> says "four studs instead of one and a half". Measured by the harness's
> published method at the shortfalls that same comment states, the step is
> **9.6–10.8 studs**, and by head displacement alone **6.1–6.8**. Nothing in the
> *decision* turns on which it is — every value is multiples of the documented
> 1.63 and the fix removes all of them — but the two numbers are not the same
> measurement and the smaller one is now in a code comment. **Owed: one sentence
> saying which method "four studs" came from, or the measured number.**

**The collapse is deliberately NOT gated on `Slump`.** That was the alternative
the coordinator offered and it was declined for a stated reason: the controller's
collapse is **unconditional handoff enforcement** — *"a cutscene that forgets to
remove the attribute still ends in the fight pose"* — and a `Slump > 0` gate makes
that guarantee conditional on a *second* channel the cutscene also has to get
right. A skip, a late adopt, or any future arrival that never touches `Slump`
would then never collapse at all, and the body would be drawn by the entry branch
forever. **The handoff was moved to coincide with the ramp instead of the
enforcement being weakened**, and landmark **BC15** is the expected-zero that
keeps it that way: no `slump` reference between BC9's line and BC10's.

**Gate 8, `collapse-inside-slump`** (T6–T10) is the executable form of all of the
above. It **reads** the four inputs rather than restating them —
`BrinejawIntro`'s `T` table and `ENTRY_STEPS` rows with their shape names, the
controller's `EASE.entry` and its `ENTRY.HOME` / `ATTR_HOME` — simulates the
filter at 60 Hz, and requires `MIN_MARGIN = 0.10 s` (six frames of the 0.7-s
ramp) of ramp left on **each** side. Landing on the ramp's last five frames is
landing on its edge: the drawn slump lags the attribute by its own ease, and a
frame or two of jitter would push the ambient step onto a still skull.

**It was verified failing on the old schedule and on a knife-edge variant** —
which is the `--control` discipline applied to the one gate whose inputs are
spread across two files, and it is why this gate is trustworthy rather than
decorative. It also **FAILs rather than passes if it cannot parse its inputs**, so
a rename in either file reads as a broken gate and not as a green one.

Executed: **8 / 8 green**, `--control` still fails exactly one measured gate
(`apex-over-lantern`) and correctly reports gate 8 as unaffected. `stylua --check`
re-run clean on the Brinejaw paths — **which also closes §7.8's identity-only
caveat for this file.**

### 6b. The other nine findings a committer needs

Each is verified; the appendix in the redesign doc carries the full reasoning.

1. **The waterline is 0.0, DERIVED — the design's open item #1 is closed.** Chain,
   both ends: `CreatureService:6873` builds this boss's pose as
   `BrinejawPath.newState(Vector3.new(anchor.X, World.WATER_Y, anchor.Z))` —
   snapped to the waterline **on purpose**, with its own note saying why;
   `World.WATER_Y = 0` (`World.luau:99`); `kit.waterY = World.WATER_Y`
   (`CutsceneKit.luau:180`). `ENTRY_WATER_Y = 0.0` states the derivation, and
   **BrinejawIntro reads `kit.waterY − kit.center.Y` and warns** if the two ever
   diverge rather than trusting the constant. The 18-knot table stands; the breach
   staging did **not** need re-running.
2. **The breach is at r 162.00 / bearing 248.0, not "r ~178".** r 178.5 is the
   head's position at `Entry = 0`, one `ENTRY_SUBMERGE` further out and 20.6 studs
   **down**. The design contradicts itself by 16 studs; its own knot 8 comment
   (`{248, 162, 0} -- THE BREACH`) is the right one. Camera shot 4 frames both, so
   staging is unaffected. **Corrected in the appendix; the measured value is the
   truth** (coordinator, 2026-09-12).
3. **Min spire clearance is 22.50, not 19.10.** Measured over the entry spline only
   (σ 0…σmax), minimum at σ = 0 — the join itself (r 31, `spireRadius(3.4)` 8.5).
   19.10 was **not reproducible from any sweep** and the design does not say what
   range it swept. Both clear the ≥ 15 gate. **Corrected in the appendix.**
4. **The lantern has two heights in the design**: 58.6 (`SPIRE_TOP + 4.6`, the
   lamp) and ~64.6 (the lantern **posts**). **The gate uses the stricter 64.6**
   (`SPIRE_TOP + 10.6`) and the apex clears it at 72.58. **Corrected in the
   appendix.**
5. **`L_rest` = 288.64, the design says 288.47** (0.06%). Two different
   measurements of two different things: 288.64 integrates `restPoint` at
   `newState` defaults over 2000 samples (the **parametrisation** unit); the
   ChainPose-equivalent **drawn** length, 160 samples of `pointAt` with ambient
   included, is **288.15**, which matches the design exactly. So the ±5% gate is
   stated against the drawn number and the parametrisation is the 2000-sample one.
   Not an error in either — but it is two numbers with one name.
6. **Rimefang's shed is the fight's 28.6%, derived** (RI1–RI4), and the design's
   §3.2 states no shed fraction at all. See §1's note for the `wBurst` saturation
   consequence.
7. **Noctyss's `MawRise` cap is `SNAP.RISE_TO` = 0.406, read from the module.**
   The design's table says 0.45 and its own correction paragraph says 0.406 —
   **the two sentences disagree with each other**, and the code reads the module
   so neither can drift.
8. **The splashes come from the controller hook, not 25 `kit.at` cues** (§3.4).
   Nothing is lost across a skip: a skipped `kit.at` fires **muted**, so its
   `kit.vfx.splash` was already a no-op. The design's closed form survives in the
   code as `BrinejawPath.entryOfBreach(t)` and the harness gates monotonicity with
   it (`surfacing-order`: 100 of 100 links, link 1 at Entry 0.056, link 100 at
   0.580, monotonic true). The design's separate tail-splash
   `kit.every(11.6, 14.0, 0.24)` is **dropped** — the hook already covers those
   links, which surface at Entry 0.45…0.583.
9. **Wrack's `place(e)` heave would have snapped the bow 20° down**, so it is a
   bow-lift bump `rad(9)·sin(π·e)`, zero at both ends (WI4). The server's pitch
   term still governs the settle at the far end, where she really is going
   nose-first under the sand.

---

## 7. Still open

Nothing here blocks the commit.

1. **CLOSED — §6a's collapse-ordering hunk has landed** and is now gate 8. One
   prose item survives it: the "~4-stud" figure in `BrinejawIntro`'s new comment
   disagrees with the harness's own measurement of 9.6–10.8 studs at the
   shortfall that comment states (§6a). **Owed: one sentence naming the method,
   or the measured number.** Also owed by the gate's owner: its docstring calls
   itself "GATE 7" while the driver prints 8.
2. **`Fn.pyreliskRampPlates`-style single-source discipline is NOT yet applied to
   the Rimefang `CreatureEventController` opportunity.** That controller already
   draws the crack web (`K.stepRimeWeb`, live at `Move == "icebreach"` and
   `Submerge ≥ 0.45`) and the pre-burst sheet dome, from **exactly the four
   attributes this stand-in publishes** — `Move`, `PoseCenter`, `Submerge`,
   `Burst` — for any tracked model carrying `CreatureId == "rimefang"`. Adding two
   attributes to the stand-in would retire all 12 hand-drawn splits and give the
   fight's own tell for free. **Not done**: it wires a cutscene stand-in into a
   controller this unit does not own, with a nameplate/HUD and
   `stepRimeShatter`/`rimeGrade` surface that needs a Studio run to clear. Cheap,
   high value, **wants that controller's owner.**
3. **`cue("arrive")` is duel-only** (WI6) and the design's "Channels newly used:
   … the `arrive` cue" line is wrong for `admiral_wrack`. Prose fix owed in the
   design; no code owed.
4. **`KrakenPath`: three items for channel owner 8e**, all raised by the `kw`
   slice and none touched by it:
   - **`Adrift` is not in the bend-law table.** The verification note lists eight
     poses; `POSE.Adrift` — the AMBIENT seats' only pose, and therefore the pose
     **two of the four staged limbs run for this entire cinematic** — is absent.
     Same family as `Rest`, but this unit will not invent a number. **Asks: one
     re-run of that file's own sweep with `Adrift` in the pose list.** *The owner
     is mid-pass adding exactly this.*
   - **The bend-law argument for the staged tips is a construction argument, not a
     measurement**, and `bendcheck.py` is not in the repo (`find . -name
     "bendcheck*"` → nothing; it lives in that lane's scratchpad). The argument:
     `tipOverride` moves p3 and carries p2 by the same delta, preserving handle
     length, so **lengthening** the chord straightens the curve — and every staged
     chord here is 575–581 studs root-to-tip against the fight's own `Rest` chord,
     i.e. all of it in the SAFE direction (the documented failure mode is a
     *shortened* chord). **Unmeasured; worth one sweep** over the driven
     `rise`/`radius`/`bearing` ranges.
   - **`HANDLE_ROOT` is still `[UNVERIFIED]`** — the prose says "0.42 is measured,
     not chosen", the constant on the next line is `0.55`. Untouched, still open.
5. **`frame` carries no `ArmPhase` / `ArmT`**, so the design's "`ArmPhase` held at
   `Rear`" is unreachable (KI5). Either the frame shape grows two fields — session
   30's `KrakenBodyController`, and a real API change — or the design drops the
   claim. **No code owed by this unit.**
6. **`L_rest` is state-dependent** and the design's open item #3 still stands: it
   moves with `Coil` (via `coilOffset`) and with `Slump`. The entry holds both at
   defaults and the anchors are computed from the default state, so the join is
   exact **only there**. If anyone ever drives `Coil` during an arrival, **re-run
   the length gate first.**
7. **Does the ocean render at r 262?** The design's open item #2. The submerged
   tail knots reach r 262 from the arena centre and nothing is above the plane
   there at `Entry = 0` (gate `hidden-at-zero`: highest body y = −20.58), but sea
   stacks stop at r 86 and the camera goes to r 118, so r 262 is untested ground.
   **Studio only.**
8. **`stylua --check` on the Brinejaw paths was originally by IDENTITY, not by
   re-run** — formatted and checked clean **as the scratch copies**, with the
   applied files byte-identical (`cmp`), because the repo-path check was blocked by
   that session's sandbox classifier. **The §6a hunk re-ran it on the repo paths
   and it is clean**, so this is closed for the three Brinejaw files. It is still
   worth one pass over the four other rewritten scripts (§8 step 4).
9. **Should `Entry` ever be published by the server?** No, in this design. A future
   "the boss retreats and re-enters mid-fight" would want it, and if that day comes
   the level/event distinction and the `>= 0.995 → nil` collapse are what make it
   safe. Recorded so the answer is a decision rather than an omission.

### 7a. What a Studio run still owes — **none of this has been watched**

No slice included a Studio run. Every item below is reasoned in the slice notes
and **none of it is tested**. The three universal checks are per boss, so the
matrix is 5 × 3 plus the per-boss visuals.

**Universal, all five bosses:**

| check | why it is the one that matters |
|---|---|
| **No pop at `raiseAt`** | brinejaw 17.8, rimefang 16.2, noctyss 17.5, wrack 17.8, kraken 19.0. The handoff frame is derived in every script, but derived is not drawn. |
| **A skip at four points lands on the handoff pose** with nothing orphaned | every `Entry`/attribute write is a `kit.track` (none a `during`), so a `fastForward` settles all of them at `u = 1`. Brinejaw's four: **t = 2 / 8 / 13 / 16.** |
| **A late join mid-run shows a sane frame** | brinejaw t = 12 → a mid-climb serpent; rimefang t = 12 → the crash pose; noctyss → a maw in the handoff frame, never no model and never mid-rear; kraken/wrack hold no state that depends on having seen an earlier beat, but **that is a reading, not a test**. |

**Brinejaw** (slice NOTES §6): nothing on screen before 7.4; the head through at
r 162 / bearing 248 with the body still submerged; ~25 splashes marching
tail-ward; the apex over the lantern; the skull landing at r 39; three distinct
turns on the drum; **the 1.63-stud ambient step at t 16.97 being invisible** —
gate 8 now proves it lands 0.367 s into the slump ramp with the skull a quarter
through a 26-stud descent, which is an *argument* that it is hidden, not a
viewing; whether the ocean renders out at r 262.

**Rimefang** (slice NOTES §6): that the four `RimefangArena` object names resolve
through `packPrefix` in the live `Assets` tree (`RimefangArena_ThinIce` / `_Leads`
/ `_Bergs`; a miss warns **once** and draws `kit.mesh`'s stand-in rather than
failing); that `Size`-squashed `_Bergs` / `_ThinIce` / `_Leads` clones **read as
ice** at their drawn scale.

**Noctyss** (slice NOTES §6): that nothing in the Choirfloor is visible behind the
maw at `MawRise = 0` from shot 5's 22-stud rim position (the derivation says
−11.7 against a −5.0 water plane, so it should not be).

**Kraken** (slice NOTES, "NOT verified"): that the drawn head is at
`kit.center + HEAD_OFFSET` and on frame in every shot, and `shipCentreFrom`
neither warns nor corrects; that the four limbs come out of the water **at their
sockets**, not on a ring, and limbs 1/4 (sockets at r 250.8, **outside** the r 170
wall) read as rising *beyond* the storm rather than behind it — the wall at their
bearings is ~78 studs and their tips reach 228, so the argument is that they tower
over it; that **no camera is ever inside a limb** (the starboard-arc composition,
58–112°, is the argument — all four sockets are on the port quarter at 218/247/293/322°).

**Wrack** (slice NOTES, "NOT verified"): that the muzzle flashes land on the four
bores; that the hatches are **shut** at the cut; that the Lady is **docked** at the
cut; no pop at 17.8.

---

## 8. Commit-time procedure

Per the shared-checkout rules — live sessions in these files, explicit paths only,
`&&` not `;`, never `--amend`, and **never `git add` a file another session is
editing**:

1. Run §4. Require **`ALL LANDMARKS PRESENT`**, exit 0, **104 checked**.
2. Re-run §2 and confirm: **`src/Client/Cutscenes/` still holds exactly 8 files**
   (a ninth means another lane is mid-write in there), and
   **`BossCutscenes.luau` still holds exactly 7 rows with none removed** and the
   five DC landmarks at their values.
3. Run gate five, `luau-compile --null -O0`, on all eight `.luau` paths in the
   unit — the other four gates cannot see the 200-local limit. Confirm
   `grep -cE '^local ' src/Shared/Modules/BrinejawPath.luau` is still **26**.
4. Run **`stylua --check` on this unit's paths only** — never `stylua src`, which
   reformats other lanes' in-flight files under them. This closes §7.8, where the
   check is currently by byte-identity rather than by re-run.
5. Run gate six, **`python3 tools/check_brinejaw_entry.py`** — **8 gates**, the
   eighth being `collapse-inside-slump` (§6a) — **and `--control`**, which must
   fail exactly one **measured** gate (`apex-over-lantern`) and report gate 8 as
   unaffected. The gate is part of this unit and is the only thing in the project
   that checks the arrival's geometry **or** that its four collapse-ordering
   numbers still agree across two files.
6. Run `selene src`, `python3 tools/check_compile.py` (153 files),
   `python3 tools/check_content.py`, `rojo build -o /tmp/check.rbxlx` (**to
   `/tmp`, so no build artifact lands in the repo**).
7. **Confirm with the cutscene lane (session 30) before ANYONE stages
   `src/Shared/Data/BossCutscenes.luau` or `src/Client/Modules/CutsceneKit.luau`.**
   Both are their untracked files. Three of the `BossCutscenes` rows are our
   stake and the unit cannot go green without them (§3.2); `CutsceneKit` is a pure
   dependency and this unit adds nothing to it (§3.1). Per the shared-file
   protocol the three `duration` rows are **handed over as the three-line change
   they are**, not staged from here.
8. **Confirm with channel owners 00 (Rimefang), c1 (Noctyss) and 8e (Kraken)**
   that their scripts are at rest. 8e is mid-pass on `KrakenPath.luau` — that file
   is **not** in this unit and the two do not meet in a file, so it does not block;
   but `KrakenIntro.luau` is theirs to release.
9. Stage **by explicit path only** — never `-A`, never `.`, never `-a`:

   ```sh
   git add src/Shared/Modules/BrinejawPath.luau \
           src/Client/Controllers/BrinejawBodyController.luau \
           src/Client/Cutscenes/BrinejawIntro.luau \
           src/Client/Cutscenes/RimefangIntro.luau \
           src/Client/Cutscenes/NoctyssIntro.luau \
           src/Client/Cutscenes/KrakenIntro.luau \
           src/Client/Cutscenes/WrackIntro.luau \
           tools/check_brinejaw_entry.py \
           tools/brinejaw_entry_stub.luau \
           tools/brinejaw_entry_probe.luau \
           docs/boss-cutscenes-handoff.md \
           docs/boss-cutscenes-redesign.md
   ```

   **Note what is NOT in that list and why it is the dangerous half.**
   `src/Shared/Data/BossCutscenes.luau` and `src/Client/Modules/CutsceneKit.luau`
   are added **only** by whoever owns them, in this same commit or an immediately
   adjacent one (§3.1, §3.2, step 7). `src/Client/Cutscenes/GnashrootIntro.luau`,
   `PyreliskIntro.luau` and `_Example.luau` are session 30's and are **not staged
   by this unit** — which is why the five scripts are listed **individually**
   rather than as `git add src/Client/Cutscenes/`.

   **Eight of this unit's paths are UNTRACKED.** A reconstruct-commit flow that
   stages by `update-index --cacheinfo` against paths it already knows about will
   land **none of them**, and neither will a pathspec'd commit written from a
   diffstat. That loss is invisible to all five gates: `check_compile` and `rojo
   build` read the worktree, not the index, and they will go right on passing.
10. **Never reconstruct the commit from HEAD.** The two tracked files carry other
    lanes' in-flight hunks. Before committing, diff the **staged symbol set**
    against the **worktree symbol set** for `BrinejawPath.luau` and
    `BrinejawBodyController.luau`
    (`git show :<path> | grep -oE '^(local |function )[A-Za-z_.:]+' | sort`
    against the same over the worktree file). The failure this catches is a
    reconstruct-commit that silently drops another lane's work from a shared file.
11. Commit. Do not amend afterwards.

**Gates green at the last apply (2026-09-12), as recorded by the three slices:**
`luau-compile --null -O0` on all modified `.luau` · `stylua --check` on this
unit's paths (Brinejaw: by identity, §7.8) · `selene src` **0 / 0 / 0** ·
`check_compile` OK, **153** files · `check_content` OK, 9 bosses / 16 islands /
131 creatures · `rojo build` OK · `check_brinejaw_entry` OK, **8 gates** ·
`check_brinejaw_entry --control` **CONTROL OK** (apex-over-lantern fails; the
ordering gate is unaffected by a knot perturbation, by design).
