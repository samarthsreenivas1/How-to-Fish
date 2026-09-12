# Pyrelisk redesign — commit-time handoff record

> **THIS FILE IS UNTRACKED AND MUST STAY THAT WAY UNTIL THE UNIT LANDS.**
>
> It lives in `docs/` for the same reason `docs/wrack-fight-handoff.md` does —
> the previous copy of that record was lost when `/private/tmp` was purged, and
> the checklist for a long-lived uncommitted unit cannot live somewhere a purge
> or a new session can take it. Every slice's `NOTES.md`, `HANDOFF.md` and
> `patches/` for this work are in a session scratchpad under
> `/private/tmp/claude-501/…/scratchpad/pyrelisk-phases/`. **Assume they are
> already gone.** This file is the durable record; it is not staged.
>
> - **Do not `git add -A`, `git add .`, or `git commit -a`.** This is a shared
>   checkout with live sessions in every one of these files.
> - When the Pyrelisk consolidation commit is approved, this file is committed
>   **by explicit path, in the same commit as the unit** (§6).
> - Until then it is invisible to every gate and to every other lane, which is
>   correct: it describes work that is not in HEAD.

Written **2026-09-12** by running the audit from scratch against the current
worktree. Every landmark below was **executed**, not transcribed.
Result: **98 / 98 landmarks present, 0 missing.** Re-executed after the act-3
cut (2026-09-12): **109 / 109, ALL LANDMARKS PRESENT** — the count rose because
removals are now landmarks in their own right (expected zero) and the cut's own
hunks were added.

> **ACT 3 (THE ARM CLIMB) WAS CUT LATER THE SAME DAY — see `Addendum V` in
> `docs/pyrelisk-fight-design.md`.** The unit is now **three** acts, not four:
> seams and flank scars → the two arms → *the second arm's death is the lethal
> chip, the body collapses, the caldera opens* → the heart chamber. Every
> act-3 landmark below is marked **REMOVED (expected 0)** and was re-executed
> as zero; the hunks that replaced them are in the same tables, marked **NEW**.
> A landmark marked REMOVED is a *deletion that is load-bearing*, exactly like
> PB5/PB6/PB8a: putting the symbol back is not a restoration, it is a different
> fight. Counts that moved: `Creatures.items` worktree **131 → 129**; the chip
> ledger's four equalities → **two**; `Bosses.items.pyrelisk.phases` **3 rows →
> 2** and `stances` **3 → 2**.

---

## 0. What the unit is

The Pyrelisk redesign's **server-side unit**: the Ashfall Throne's four acts —
**seams and flank scars → the two arms → the climb up the fallen limb →
the caldera opens and the fight moves into the heart chamber**. Implemented,
gate-green, and **uncommitted**, spread across eight files.

It was built as six drafted slices (3, 4, 4b, 4c, 5, 5b, 6), each applied to the
worktree from a gated copy. The slices are a build order, **not a commit order**
— §3 is the dependency statement and it says *one unit or none*.

`Bosses.items` has **7** rows at HEAD and **9** in the worktree;
`Creatures.items` has **120** at HEAD and **129** (verified by a brace-aware
walk, not a regex — §2). It was 131 until the act-3 cut took
`pyrelisk_ventrock` and `pyrelisk_neckcore` out.

Those files **also** carry other lanes' uncommitted hunks (noctyss, kraken,
rimefang, wrack, cutscene, audio, island-population). **Attribute by name,
never by offset.** Line numbers moved *during this audit*: `K.GIMMICKS.pyreliskheart`
was at L7892 when the file was first read and L7941 forty minutes later, with no
Pyrelisk edit in between. A regex over a Luau table truncates on nested braces —
the row extractor in §4 walks braces and skips strings and comments.

### Explicitly NOT in this unit

- **The wrack ring-regrow nil guard** (`and def.parts.regrow`, one clause in
  `Fn.updateBoss`). It sits in `CreatureService.luau` and was *found and written*
  by this lane (slice 4 NOTES §2.7 raised it, slice 4b landed it), but it is the
  **Wrack unit's** hunk and is counted there —
  `docs/wrack-fight-handoff.md` §1 S24 and §5. It is independent of every
  Pyrelisk hunk. Do not count it twice, and do not let the Pyrelisk commit be
  the reason it lands or does not.
- **The mesh lane's slices 2 / 4 / 6** — see §3.6. A separate uncommitted unit,
  owned by session 71.

---

## 1. Landmarks, per file

All counts below are the **executed** result on the current worktree. Every
pattern is line-anchored so it cannot drift when the shared files move.

> **Reading the patterns:** `\t` below stands for a **literal TAB** — Luau indents
> with tabs, and `grep -E` does **not** expand `\t`. The §4 script contains real
> tab characters; if you retype a landmark by hand, type a tab. `\|` is table
> escaping for `|` (alternation). Everything else is the pattern verbatim.

### `src/Shared/Data/Bosses.luau` — 22 landmarks

| ID | Hunk | Landmark (`grep -cE` unless noted) | Count |
|----|------|------------------------------------|-------|
| PB1 | `pyrelisk` act-1/2 threshold | row-scoped `^\t\t\{ below = 0\.70, ` | 1 |
| PB2 | ~~`pyrelisk` act-2/3 threshold~~ **REMOVED** — the act-3 phase row is gone with the climb | row-scoped `^\t\t\tbelow = 0\.30,$` | **0** |
| PB3 | ~~act-3 book pruned (slice 4c)~~ **REMOVED** — the book went with its only phase pool | row-scoped `^\t\t\tattacks = \{ "ashfall", "ventbreath", "crownshed", "shardhurl" \},$` | **0** |
| PB2n | **NEW**: two phase rows, not three | row-scoped, `phases` block only, `below = ` | 2 |
| PB3n | **NEW**: two stances, and it moves with the row count | row-scoped `^\tstances = 2,$` | 1 |
| PB4 | `parts` block: the two arms | row-scoped `^\t\trow = "pyrelisk_arm",$` | 1 |
| PB5 | **`regrow` ABSENT** — the arms never come back | row-scoped `^\t\tregrow = ` | **0** |
| PB6 | **`parts.at` ABSENT** — `mounts` deleted, F-4 | row-scoped `^\t\tat = ` | **0** |
| PB7 | the bait pays the seam meter | row-scoped `^\t\t\tseamCredit = 0\.40,$` | 1 |
| PB8a | **`handfall.weakStagger` DELETED** | row-scoped `^\t\t\tweakStagger = ` | **0** |
| PB8b | …and its tombstone comment kept | row-scoped `.stagger. AND .weakStagger. ARE GONE` | 1 |
| PB9 | `seamStagger` retired, not orphaned | `^\tseamStagger = ` | **0** |
| PB10 | ~~new `crownshed` attack row~~ **REMOVED** — the redesign's one new attack, cut with act 3 (its handler goes too, see S4b-D1) | row-scoped `^\t\tcrownshed = \{$` | **0** |
| PB11 | collapse held for the caldera | row-scoped `^\tcollapseFor = 4\.0,$` | 1 |
| PB12 | the handoff | row-scoped `^\tsucceededBy = "pyrelisk_heart",$` | 1 |
| PB13 | new `pyrelisk_heart` boss row | `^Bosses.items.pyrelisk_heart = \{$` | 1 |
| PB14 | heart keeps the **island** | row-scoped `^\tislandId = "volcano",$` | 1 |
| PB15 | …but names its own **room** | row-scoped `^\tarenaKey = "pyrelisk_heart",$` | 1 |
| PB16 | heart is never summoned | row-scoped `^\tsummonable = false,$` | 1 |
| PB17 | the win mints `Heart_pyrelisk` | row-scoped `^\theartAs = "pyrelisk",$` | 1 |
| PB18 | `hitRadius` 13, **not 26** | row-scoped `^\thitRadius = 13,$` | 1 |
| PB19 | eight pillars | row-scoped `^\t\tcount = 8,$` | 1 |
| PB20 | …on the authored collars | row-scoped `^\t\tat = "sockets",$` | 1 |
| PB21 | heart's four attack rows | row-scoped `^\t\t(ventspit\|heartpulse\|magmarain\|ventbarrage) = \{$` | 4 |

Row-scoped means `sed -n '/^Bosses.items.<id> = [{]/,/^}/p'` first, then grep.
(In a `sed` address `\{` opens an interval — use `[{]`.)

**PB5, PB6, PB8a and PB9 are deletions and they are load-bearing.** `regrow`
absent *is* the act boundary — the arms are a one-way door. `parts.at` absent
keeps the plant off `Fn.wrackMountPoint`, which is Wrack's hull convention and
has a comment saying so. `weakStagger` absent is the redesign in one field:
the twenty-second punish window was replaced by act 2 entirely. Putting any of
them back is not a restoration, it is a different fight.

**PB18 is the one that will look like a typo.** §6.2 of the design asks for
`hitRadius = 26`. `Fn.updateBoss`'s first frame multiplies by `body.scale`,
which is `2.0` on the heart, so 13 × 2.0 = the 26 the design wanted. Writing 26
gives a **52**-stud capture sphere in a room of radius 96 whose pillars stand at
r 44–70, and ranged selection eats every shot aimed at the pillars that gate the
heart. If `body.scale` moves, this moves with it.

### `src/Shared/Data/Creatures.luau` — 8 landmarks

| ID | Hunk | Landmark | Count |
|----|------|----------|-------|
| PC1 | `pyrelisk_arm` (slice 3) | `^Creatures.items.pyrelisk_arm = \{$` | 1 |
| PC2 | ~~`pyrelisk_ventrock` (slice 4)~~ **REMOVED** with the climb | `^Creatures.items.pyrelisk_ventrock = \{$` | **0** |
| PC3 | ~~`pyrelisk_neckcore` (slice 4)~~ **REMOVED** with the climb | `^Creatures.items.pyrelisk_neckcore = \{$` | **0** |
| PC4 | `pyrelisk_heart` (slice 6) | `^Creatures.items.pyrelisk_heart = \{$` | 1 |
| PC5 | `pyrelisk_pillar` (slice 6) | `^Creatures.items.pyrelisk_pillar = \{$` | 1 |
| PC6 | heart's return path | row-scoped `^\tgimmick = \{ kind = "pyreliskheart" \},$` | 1 |
| PC7 | heart gated on its pillars | row-scoped `^\tvulnerableWhen = "partsDown",$` | 1 |
| PC8 | heart `body.scale` — PB18's other half | row-scoped `^\t\tscale = 2\.0,$` | 1 |

`Creatures.items.pyrelisk` is also CHANGED (§2) — the colossus's drops move to
the heart, which is the payout half of `succeededBy` / `suppressDrops`.

### `src/Shared/Data/CreatureFamilies.luau` — untracked (audio lane's file)

| ID | Hunk | Landmark | Count |
|----|------|----------|-------|
| PF1 | `pyrelisk_arm` — the colossus's own body | `^\tpyrelisk_arm = "leviathan",$` | 1 |
| PF2 | ~~`pyrelisk_ventrock`~~ **REMOVED** — the row goes when the creature does, or the gate's *other* direction fires | `^\tpyrelisk_ventrock = "elemental",$` | **0** |
| PF3 | ~~`pyrelisk_neckcore`~~ **REMOVED**, same | `^\tpyrelisk_neckcore = "elemental",$` | **0** |
| PF4 | `pyrelisk_heart` | `^\tpyrelisk_heart = "elemental",$` | 1 |
| PF5 | `pyrelisk_pillar` | `^\tpyrelisk_pillar = "elemental",$` | 1 |

**This whole file is untracked and belongs to the audio lane.** The Pyrelisk unit
does not own it and must not `git add` it — but the unit **cannot go green
without PF1–PF5**, because `check_content` §9 is two-directional (§3.3). Slice 3
predicted this omission would bite slices 4 and 6, and it did, twice.

### `src/Server/Services/CreatureService.luau` — 47 landmarks

The file is **shared and hot**. It is at the Luau 200-local limit (§5), which is
why nothing below is a new top-level `local`: every symbol is a field on
`ATTR` / `K` / `Fn`.

**Slice 3 — acts 1 and 2**

| ID | Hunk | Landmark | Count |
|----|------|----------|-------|
| CS1 | act + arm-bar attributes | `^ATTR\.PY_(ACT\|ARM_L\|ARM_R) = ` | 3 |
| CS2 | seam meter re-derived, 2600 → 5400 | `^K\.PY_SEAM_METER_HP = 5400\.0$` | 1 |
| CS3a | **`Fn.partyMult` — now shared with the kraken lane** | `^function Fn\.partyMult\(creature\): number$` | 1 |
| CS3b | seam credit divides by it | `Fn\.pyreliskMeterFill\(creature, state, side, amount / \(K\.PY_SEAM_METER_HP \* Fn\.partyMult\(creature\)\)\)` | 1 |
| CS3c | the meter fill itself | `^function Fn\.pyreliskMeterFill\(` | 1 |
| CS4a | the chip fractions (the ledger's input) — **TWO now**, and `ARM` is **0.35**, not 0.20: the arms absorbed act 3's 0.30 | `^K\.PY_(FLANK\|ARM)_FRACTION = ` | 2 |
| CS4a-z | …and `ROCK` / `CORE` are **REMOVED** | `^K\.PY_(ROCK\|CORE)_FRACTION = ` | **0** |
| CS4b | no chip may enter the death path | `^K\.PY_CHIP_FLOOR = ` | 1 |
| CS4c | act-2 arm constants | `^K\.PY_ARM_(WINDOW\|SLUMP_EASE\|POOL_GAP\|POOL_R\|POOL_ARM\|POOL) = ` | 6 |
| CS5 | the act machine | `^function Fn\.pyrelisk(Chip\|FlankBit\|FlankPaid\|MarkFlankPaid\|BothFlanksBroken\|UnscarredSide\|PublishAct\|ArmBars\|PlantArm\|DropArms\|ArmsRetire\|ArmsFailed\|ArmsDone)\(` | 13 |
| CS5b | the arm updater, **dispatcher's signature** | `^function Fn\.updatePyreliskArm\(creature, now: number, _dt: number\)$` | 1 |
| CS6a | chips ride the **scar-mask level**, not an edge | `^\t\t\t\tif Fn\.pyreliskBothFlanksBroken\(state\) and not creature\.pyreliskArmsOut then$` | 1 |
| CS6b | arm reconcile gated to act 2 | `creature\.pyreliskArmsOut and \(creature\.pyreliskAct or 0\) == 2` | 2 |
| CS10 | archetype updater row | `^\tpyreliskarm = Fn\.updatePyreliskArm,$` | 1 |

**Slice 4 — act 3, the climb — THE WHOLE SLICE IS REMOVED (2026-09-12)**

Every landmark below is now **expected zero** and was re-executed as zero. The
one exception is S4-10, which was never act 3's: `collapseFor` is the collapse's
own hold and the caldera timing rides it, so it stays at 2.

| ID | Hunk | Landmark | Count |
|----|------|----------|-------|
| S4-1 | ~~rock mask + core bar attributes~~ **REMOVED** — nothing writes them; the client's "nil means absent" clause is what makes that free | `^ATTR\.PY_(ROCKS\|CORE) = ` | **0** |
| S4-4 | ~~act-3 constants~~ **REMOVED** except `CALDERA_AT`, which is the caldera's and stays | `^K\.PY_(ROCK_COUNT\|ROCK_LIFT\|ROCK_WEAVE\|CORE_LIFT) = ` | **0** |
| S4-4b | `K.PY_CALDERA_AT` **KEPT** | `^K\.PY_CALDERA_AT = 2\.5$` | 1 |
| S4-2/3 | **vent-swing minigame RETIRED** (bought back 4 locals) — still zero, and the mount gate below is what keeps it that way | `^(local pyreliskSwingAt\|function Fn\.pyreliskVentSwing\|K\.PY_VENT_REACH)` | **0** |
| S4-7 | ~~rock/core placement + plant~~ **REMOVED**, all five | `^function Fn\.pyrelisk(RockPoints\|CorePoint\|PlantPart\|PlantRocks\|CoreBroken)\(` | **0** |
| S4-10 | `def.collapseFor` honoured (both sites) — **KEPT** | `def\.collapseFor or K\.COLLAPSE_TIME` | 2 |

**Slice 4b — act-3 pressure — THE WHOLE SLICE IS REMOVED (2026-09-12)**

| ID | Hunk | Landmark | Count |
|----|------|----------|-------|
| A1 | ~~the three back vents~~ **REMOVED** — nobody walks on the body now | `^function Fn\.pyreliskVentHazard\(` | **0** |
| A1b | ~~vent banding constants~~ **REMOVED** | `^K\.PY_VENT_(GAP\|ARM\|POOL) = ` | **0** |
| A2 | ~~the shared `climbSlabs` filter~~ **REMOVED** — its only consumer was `crownshed` | `^function Fn\.pyreliskRamp(Plates\|Points)\(` | **0** |
| D1 | ~~`crownshed` handler~~ **REMOVED** (row PB10 with it) | `^K\.ATTACK_HANDLERS\.crownshed = \{$` | **0** |
| D2 | ~~thrown from the crown~~ **REMOVED** with the handler | `^\t\tlocal head = PyreliskPath\.headCFrame\(state\)$` | **0** |

**The cut's own hunks — NEW, and every one executed**

| ID | Hunk | Landmark | Count |
|----|------|----------|-------|
| X1 | the arms' chip is **0.35**, and the second one is lethal | `^K\.PY_ARM_FRACTION = 0\.35$` | 1 |
| X2 | the act numbering is ONE constant | `^K\.PY_ACT_HEART = 3$` | 1 |
| X3 | the heart publishes it, never a literal | `^\tif creature\.pyreliskAct ~= K\.PY_ACT_HEART then$` | 1 |
| X4 | **`Fn.pyreliskArmsDone` ends the fight** — the neck core's route, verbatim, nil killer and all | `^\tCreatureService\.damage\(creature, creature\.health, nil, \{ ignoreUntargetable = true \}\)$` | 1 |
| X5 | the mount gate is back to a stagger with something planted — **no path re-enables mounting** | `^\tif creature\.mode == "stagger" and \(state\.planted or 0\) ~= 0 and not creature\.collapsing then$` | 1 |
| X6 | `shardhurl`'s act-3 crown origin is gone; acts 1-2 byte-identical | `^\t\tlocal hand = PyreliskPath\.fistPoint\(state, side\)$` | 1 |
| X7 | the act machine is otherwise **untouched** (CS5's thirteen still stand) | `^function Fn\.pyrelisk(Chip\|FlankBit\|FlankPaid\|MarkFlankPaid\|BothFlanksBroken\|UnscarredSide\|PublishAct\|ArmBars\|PlantArm\|DropArms\|ArmsRetire\|ArmsFailed\|ArmsDone)\(` | 13 |
| X8 | **no act 3 on the colossus**: nothing publishes past 2 on that model, which is what F-14's `act >= 2` freeze needs through the fall | `Fn\.pyreliskPublishAct\(creature, 3\)` | **0** |

**Slice 5b — the caldera writer, the shaft, the resets**

| ID | Hunk | Landmark | Count |
|----|------|----------|-------|
| 5b-A | caldera/shaft function set | `^function Fn\.pyrelisk(ArenaModel\|OpenCaldera\|CloseCaldera\|ShaftWatch)\(` | 4 |
| 5b-F | `PyreliskShaftFloor` (§7.2, ratified) | `^ATTR\.PY_SHAFT_FLOOR = "PyreliskShaftFloor"$` | 1 |
| 5b-C | shaft constants | `^K\.PY_SHAFT_(R\|DROP\|GRACE\|TICK) = ` | 4 |
| 5b-E | the real write, at 2.5 s of a 4.0 s fall | `^\t\tif not creature\.pyreliskCaldera and u \* fall >= K\.PY_CALDERA_AT then$` | 1 |
| 5b-E2 | floor stamped **on open** | `^\t\tmodel:SetAttribute\(ATTR\.PY_SHAFT_FLOOR, floorY\)$` | 1 |
| 5b-X | floor **cleared as a pair** with the caldera | `^\t\tmodel:SetAttribute\(ATTR\.PY_SHAFT_FLOOR, nil\)$` | 1 |
| 5b-H | `removeOwnedParts` reset, heart-gated | `^\t\tFn\.pyreliskCloseCaldera\(heart and heart\.islandId\)$` | 1 |
| 5b-J | gimmick closes the hole **before** the recall | `^\t\t\tFn\.pyreliskCloseCaldera\(def\.islandId\)$` | 1 |

**5b-X is the pair-clear the §7.2 ratification requires, and it is PRESENT** —
`Fn.pyreliskCloseCaldera` clears `PyreliskShaftFloor` to `nil` on the same two
lines that write `PyreliskCaldera = 0`, so the gimmick's close-then-recall and
`removeOwnedParts` both get it for free. Executed count: 1.

**5b-H is gated on `creature.row.boss == K.PY_HEART_BOSS` and the gate is the
whole subtlety.** The colossus's death is a *handoff, not an ending*: it dies at
the bottom of the collapse having just opened the caldera on purpose, and
`kill()` → `removeOwnedParts` runs a frame later. An ungated reset closes the
caldera in the same breath that opened it and the party never gets in.

**Slice 6 — act 4, the heart**

| ID | Hunk | Landmark | Count |
|----|------|----------|-------|
| S6-1 | **MUST**: the lava rescue stands down | `^function Fn\.pyreliskCalderaOpen\(islandId: string\?\): boolean$` | 1 |
| S6-2 | caldera + pillar-mask attributes | `^ATTR\.PY_(CALDERA\|PILLARS) = ` | 2 |
| S6-3 | heart constants | `^K\.PY_(HEART_BOSS\|PILLAR_COUNT\|PILLAR_STEP\|PILLAR_POOL) = ` | 4 |
| S6-4 | **MUST**: `Fn.spawnBossParts` keys by `arenaKey` | `^\t\tlocal arena = \(def\.arenaKey or def\.islandId\) and BossArenas\.items\[def\.arenaKey or def\.islandId\]$` | 1 |
| S6-5 | cadence step on **every** cooldown | `^\tcreature\.cooldowns\[a\.name\] = now \+ a\.p\.cooldown \* rage \* \(creature\.cooldownStep or 1\)$` | 1 |
| S6-5b | …written per pillar broken | `^\t\tcreature\.cooldownStep = K\.PY_PILLAR_STEP \^ down$` | 1 |
| S6-6 | `shardhurl` leaves the shoulder in act 3 | `^\t\tif \(state\.act or 1\) >= 3 then$` | 1 |
| S6-7a | heart placement helpers | `^function Fn\.pyreliskHeart(Vents\|Ground)\(` | 2 |
| S6-7b | the four heart handlers | `^K\.ATTACK_HANDLERS\.(ventspit\|heartpulse\|magmarain\|ventbarrage) = \{$` | 4 |
| S6-7c | the heart's updater | `^function Fn\.updatePyreliskHeart\(creature, def, now: number\)$` | 1 |
| S6-7d | the return path | `^K\.GIMMICKS\.pyreliskheart = \{$` | 1 |
| S6-8 | the shaft watch, ticked by the heart | `^\tFn\.pyreliskShaftWatch\(creature, def, now\)$` | 1 |

**S6-1 is the single highest-consequence line in the unit.** The lava rescue
fires at `K.PY_LAKE_R = 120`; the shaft the caldera opens is `K.PY_SHAFT_R = 100`
— *inside* it. Without this gate, on the exact frame a player finally does the
thing the whole act exists for, the function written to save them from the lava
reads them as having fallen in and teleports them back onto the rim path. Every
time, forever, and **nothing about it looks like a bug**: the rescue is working
perfectly, at the one moment it must not. It is a **level** test, not an edge —
gating on "the caldera just opened" would strand anybody who jumped a second
later, which is most of a party.

**S6-4 was found during slice 6 and is a scope addition, flagged not smuggled.**
`Fn.spawnBossParts` looked its socket list up as `BossArenas.items[def.islandId]`.
The heart's `islandId` is `"volcano"` *by design*, and `BossArenas.items.volcano`
has no `sockets` — so `offsets` came back nil, the plant fell through to the
even-ring branch, which reads `parts.ring`, which the heart's row does not carry
either. That is **arithmetic on nil**: no pillars, and a heart gated on
`partsDown` with no parts is a boss nothing can ever make vulnerable. It is the
identical expression, for the identical reason, that slice 5 put in
`BossService.arenaPosition` (BS2) — and it is **inert for every shipped boss**,
because none of them has an `arenaKey`.

### `src/Server/Services/BossService.luau` — 6 landmarks

| ID | Hunk | Landmark | Count |
|----|------|----------|-------|
| BS1 | "already in the destination room" | `^local ARENA_MOVE_HERE = 260$` | 1 |
| BS2 | `arenaPosition` resolves the **room** | `^\tlocal arenaKey = boss\.arenaKey or boss\.islandId$` | 1 |
| BS2b | …and the floor probe uses the same key | `^\t\treturn Vector3\.new\(center\.X, BossArenaService\.floorY\(arenaKey, boss\.arena\.radius\), center\.Z\)$` | 1 |
| BS3 | `handoff` does not pivot a roomed successor | `^\tif at and not next_\.arenaKey then$` | 1 |
| BS4a | `ArenaMove` gains an optional third argument | `^\tCreatureService\.ArenaMove\.Event:Connect\(function\(islandId: string, arenaKey: string, only: Player\?\)$` | 1 |
| BS4b | the recall ring is sized off the destination | `^\t\tlocal destination = Bosses\.byIsland\[arenaKey\]$` | 1 |

**BS2 is one line that fixes four things together** — the raise, `fightCenter`,
`sendHome` and the abandon reaper all come through `arenaPosition`. Without it
`handoff` raises the heart **on the Ashfall Throne's summit** while the party is
moved into an empty chamber 40,000 studs away. `arenaKey` is a field name this
lane **invented**; the design names none.

**BS3's asymmetry is load-bearing.** `handoff` uses the same field to decide
whether to honour the dying boss's death position, and that is what keeps
Admiral Wrack leaping down onto the sand rather than standing at an arena centre.

**BS4b was a live bug, found and fixed in this lane.** The listener passed
`ringPositions(arenaKey, n, 0)`, and `BossArenas.items.volcano` has no
`spawnPad`, so radius 0 probed the **centre column of the Ashfall Throne** — the
lava lake, non-collidable, and by then over an *open caldera*. The heart's
victory recall would have dropped the whole party 292 studs through the arena
into the sea. Inert for the Kraken on both of its fires, because a `spawnPad`
still overrides the radius.

### `src/Shared/Config/BossArenas.luau` — 4 landmarks

| ID | Hunk | Landmark | Count |
|----|------|----------|-------|
| BA1a | `Arena` type: `caldera` | `^\tcaldera: \{$` | 1 |
| BA1b | `Arena` type: `vents` | `^\tvents: \{ Vector3 \}\?,$` | 1 |
| BA2 | the volcano's caldera block | `^\t\tcaldera = \{$` | 1 |
| BA3 | the `pyrelisk_heart` arena row | `^\tpyrelisk_heart = \{$` | 1 |

**Every geometry number in BA2's `landing` and in all of BA3 is a PLACEHOLDER**,
carrying the comment `-- PLACEHOLDER: measured by the Pyrelisk mesh lane
(session 71) after the heart build's HANDOFF`. The object-name triple
(`_LakeFloor`, `_Shaft`, `_Lava`) is the **contract** and is not a placeholder.
`meshBottom = 584.0` is copied from the gullet and is therefore **wrong by
construction** — a mesh's own bbox floor, and two rooms do not share one. The
eight `sockets` are not even scattered; they were written so the row parses and
the count is visible. See §7 for the full owed list.

Landing this row makes `BossArenaService.init` build a **procedural stand-in**
at `(-20000, 0, 13000)` at the waterline — a 96-stud disc, a rim, eight socket
collars and the r94 barrier. That is exactly what `maelstrom_gullet` has been
doing since the Kraken's rework: inert, harmless, `verifyWaterline` stays silent,
and it disappears the moment `arena_pyrelisk_heart.glb` imports. Mentioned so it
is not mistaken for a bug when somebody sails past it.

### `src/Server/Services/BossArenaService.luau` — 5 landmarks

| ID | Hunk | Landmark | Count |
|----|------|----------|-------|
| BAS1 | `placeAuthored` returns the placed model | `^\treturn model` | 1 |
| BAS2a | the attribute name, server side | `^local CALDERA_ATTR = "PyreliskCaldera"$` | 1 |
| BAS2b | the geometry swap | `^local function applyCaldera\(model: Instance, arena, open: boolean\)$` | 1 |
| BAS2c | the listener, **which warns by name** | `^local function armCaldera\(model: Instance, arena, islandId: string\)$` | 1 |
| BAS3 | `init` arms it on the instance | `^\t\t\t\tarmCaldera\(placed, arena, islandId\)$` | 1 |

> **Pattern loosened 2026-09-12, and the reason is not cosmetic.** The anchor
> was `^\treturn model$` and it now reads `^\treturn model`, because the
> lifted-arena lane widened the signature to
> `return model, delta.Y, { lo = …, hi = … }`. The model is still the FIRST
> return and BAS1's claim is intact — but the old anchor reported **FAIL** on
> code that was correct, which is the worst thing an audit can do: one standing
> false negative and nobody reads the next real one. Found by running §4 after
> the act-3 cut. Not this lane's hunk; only the pattern was touched.

**BAS1 exists because the model's NAME is not guaranteed.** `arenaTemplate`
resolves a group by walking up from its `<model>_Base` part to the child of
`IslandPack`, so what the clone is actually *named* is whatever the artist
grouped the import under, and nothing has ever checked it. `init` arms the
listener on the **instance** it was handed, so this service is right regardless
— and `armCaldera` **warns by name** when `model.Name ~= arena.model` on an
arena with a `caldera` row, because `CreatureService` (which cannot require this
file) must find it by that name and would otherwise write the attribute to a
model nobody is listening to. **A caldera that never opens is a fight that stops
at act three with nothing in any log.**

`applyCaldera` flips `CanCollide`, `CanQuery` **and** `Transparency` on
`_LakeFloor`. The query flip is not cosmetic: left queryable, the plate is an
invisible sheet over an open hole, and `floorY` — which decides where a body is
*put* — answers with the height of a floor that is no longer there. That is a
mid-air spawn, and it is silent. (`_Lava` deliberately keeps its query; it is a
HAZARD_MARKER and it is what keeps the column answering at the rim path's own
height.)

### `tools/check_content.py` — 5 landmarks, and the file is **worktree-only**

Re-keyed by the act-3 cut: **four equalities → two**, plus the row-count
assertion, which moved 3 → 2.

| ID | Hunk | Landmark | Count |
|----|------|----------|-------|
| P1a | the **two** fractions are read out of Luau | `^_(flank\|arm) = _py_fraction\(` | 2 |
| P1b | the threshold equality | `K\.PY_FLANK_FRACTION \* 2 = ` | 1 |
| P1c | act-2 equality (now against `phases[2].below` itself) | `K\.PY_ARM_FRACTION \* 2 = ` | 1 |
| P1d | ~~act-3 equality~~ **REMOVED** with the constants it read | `K\.PY_ROCK_FRACTION \* 6` | **0** |
| P1d-n | **NEW**: the phases table is **two** rows, and a third that nothing can reach is a book that cannot be cast | `rows, not 2 - the Pyrelisk` | 1 |
| P1e | **the one that matters: the ledger CLOSES** — the second arm's chip can only be lethal if it does | `^                "the ledger closes",$` | 1 |

`git show HEAD:tools/check_content.py | grep -c PY_FLANK_FRACTION` → **0**.
The chip ledger (four equalities when this was written, **two** since the
act-3 cut) is **not in HEAD**; the file's uncommitted diff is
this unit's plus the audio lane's §9 families gate. **The ledger gate ships with
this unit.** Without it every chip-ledger failure is silent and presents as
something else: a stance banner firing in the middle of the arms, or a colossus
that will not die when its neck core does.

The closing equality is the one that matters most. Positive control C, re-run
after the act-3 cut against `K.PY_ARM_FRACTION` (the constant `PY_CORE_FRACTION`
it was first run against no longer exists): deleting it entirely makes the gate
**report the missing constant** instead of going quiet — a check whose input has
vanished otherwise prints a confident PASS. Three more controls were run with
it and all four fire: the arm fraction re-tuned to 0.30 (ledger does not close,
two problems), the 0.70 threshold moved to 0.65 (both equalities, from both
sides), and a family row deleted (the two-directional gate).

---

## 2. By-name row-set baseline: HEAD vs worktree

Produced by the brace-aware walker in §4, comparing against
`git show HEAD:<path>`. **REMOVED must always be empty** — it is the tripwire for
a reconstruct-commit that quietly drops a row. Executed, both tables.

### `Bosses.items` — HEAD **7** → worktree **9**

| Class | Rows | Lane (by content) |
|-------|------|-------------------|
| **NEW** | `pyrelisk_heart` | **Pyrelisk** |
| | `wrack_duel` | wrack lane |
| **REMOVED** | *(none)* | ✅ empty |
| **CHANGED** | `pyrelisk` | **Pyrelisk** — phases **0.70 only** (two rows; the 0.30 act-3 row and the `crownshed` row were added and then cut, 2026-09-12), `stances` 2, `parts` → the two arms, `seamCredit`, `seamStagger` / `stagger` / `weakStagger` deleted, `collapseFor`, `succeededBy` |
| | `admiral_wrack` | wrack lane |
| | `brinejaw` | starter-cove combo pass |
| | `kraken` | kraken lane |
| | `noctyss` | noctyss lane |
| | `rimefang` | rimefang lane |

### `Creatures.items` — HEAD **120** → worktree **129**

> **Was 131 before the act-3 cut (2026-09-12).** `pyrelisk_ventrock` and
> `pyrelisk_neckcore` were NEW in this unit and are now gone from it — the unit
> never had them in HEAD, so **REMOVED stays empty** and the tripwire is
> untripped. That is the distinction to hold: a row this unit added and then
> withdrew is not a dropped row.

| Class | Rows | Lane (by content) |
|-------|------|-------------------|
| **NEW** | `pyrelisk_arm`, `pyrelisk_heart`, `pyrelisk_pillar` | **Pyrelisk** (all `waters = "volcano"`) — `pyrelisk_ventrock` and `pyrelisk_neckcore` were here until the act-3 cut |
| | `wrack_admiral`, `wrack_figurehead`, `wrack_boom_tackle` | wrack lane (`waters = "wreck"`) |
| | `kraken_antibody`, `kraken_arm`, `kraken_polyp` | kraken lane (`waters = "maelstrom"`) |
| **REMOVED** | *(none)* | ✅ empty |
| **CHANGED** | `pyrelisk` | **Pyrelisk** — the drops move to `pyrelisk_heart` |
| | `admiral_wrack`, `wrack_battery` | wrack lane |
| | `choir_stalk`, `noctyss` | noctyss lane |
| | `kraken` | kraken lane |
| | `old_ribbonjaw`, `tollmaw` | island-population swap — trades two islands, rides its own commit, **not ours** |

### `CreatureFamilies.luau`

Untracked in full, so every row is "new" against HEAD and a set-diff is
meaningless. Comparison is by **membership**, executed:
**129 creature ids, 129 family rows, 0 creatures with no family, 0 families with
no creature** (131/131 before the act-3 cut). The unit's stake is now PF1, PF4
and PF5; PF2 and PF3 went with their creatures, in the same pass, because this
gate is two-directional in both directions — a family row for a creature that
no longer exists fails it just as loudly as the other way round.

---

## 3. The dependency statement — **one unit, or none**

No subset of this work is green. Each link below was checked against the current
worktree, not assumed.

1. **`Bosses.pyrelisk` → the new attack rows → the worktree CS handlers.**
   `crownshed` names a handler that exists **only** in the worktree
   `CreatureService` (D1). Commit `Bosses` without `CreatureService` and the row
   resolves to nothing — and an attack with no handler does not error, it
   silently does nothing.
2. **The chip ledger is a FOUR-file equality and `tools/check_content.py` is one
   of them.** The gate reads `K.PY_*_FRACTION` out of `CreatureService.luau` and
   `phases[].below` out of `Bosses.luau`, in two languages. Commit either Luau
   file without the other and the gate **fails loudly** — that is the good case.
   Commit both without `check_content.py` and it fails **silently forever**:
   the numbers can drift and nothing ever says so. The gate ships with the unit.
3. **`CreatureFamilies` rows ↔ `Creatures` rows — two-directional gate.**
   `check_content` §9 fails if a creature id has **no** family *and* if a family
   row names an id that doesn't exist. So `pyrelisk_arm` / `_ventrock` /
   `_neckcore` / `_heart` / `_pillar` must land **together with** PF1–PF5, in
   either order but never apart. The file belongs to the audio lane —
   coordinate, don't stage it.
4. **`Bosses.pyrelisk_heart` → `BossService` → `BossArenas` → `BossArenaService`,
   and the chain breaks in a different place at each cut.**
   - Heart row without BS2 (`arenaKey`): the heart is raised on the volcano
     summit and the party is moved to an empty room.
   - Heart row without BA3 (the arena row): `centerFor` returns nil and the
     raise falls back to the island's own offset at the waterline.
   - Heart row without S6-4 (`spawnBossParts` arenaKey): **arithmetic on nil**,
     no pillars, and a `partsDown` boss with no parts is invulnerable forever.
   - `succeededBy` without the heart row: `suppressDrops` fires on a boss with
     no successor and the whole fight pays out **zero**.
5. **The caldera is a three-file loop and every cut in it is silent.**
   `Fn.pyreliskOpenCaldera` (5b-A) writes `PyreliskCaldera` → `armCaldera`
   (BAS2c) listens → `applyCaldera` (BAS2b) swaps the geometry, keyed by BA2's
   object names. Land the writer without the listener and the attribute reads 1
   with a solid lake underneath. Land the listener without BA2 and it reports the
   objects missing. Land either without S6-1 and the lava rescue teleports every
   jumper back onto the rim forever.
6. **The mesh lane's slices 2 / 4 / 6 are a SEPARATE uncommitted unit, owned by
   session 71**, and the two units meet at the §7 attribute contract — not in any
   shared file. Theirs: `assets/boss_gen.py`, `assets/arena_gen.py`,
   `PyreliskPath.luau`, `PyreliskBodyController.luau`, `BossHudController.luau`,
   `WeatherController.luau`, `MusicController.luau`. **Neither unit blocks the
   other**, and that is deliberate. (It *was* deliberate via named warn-rails
   that fell back; as of 2026-09-12 their slice-2 FINAL has landed and **both
   rails are retired** — this unit now reads `armRocks` / `neckCorePoint`
   directly with no fallback at all. See §6.)

   The contract, in full — this is the whole interface between the two units:

   | attribute | model | writer (this unit) | reader (their unit) |
   |---|---|---|---|
   | `PyreliskAct` `1`–`4` | colossus (1–3), heart (4) | `Fn.pyreliskPublishAct` | BodyController, BossHud, Camera |
   | `PyreliskArmL` / `PyreliskArmR` | colossus | act 2, every frame | BodyController, BossHud |
   | `PyreliskRocks` | colossus | 6-bit mask, on plant and each death | BodyController |
   | `PyreliskCore` | colossus | act 3, every frame | BodyController, BossHud |
   | `PyreliskPillars` | heart | 8-bit mask, on plant and each death | client lane, BossHud |
   | `PyreliskCaldera` `0`\|`1` | arena | `Fn.pyreliskOpenCaldera` | BossArenaService, client VFX |
   | `PyreliskShaftFloor` | arena | `Fn.pyreliskOpenCaldera` | **server shaft watch only** — server-consumed, client-readable |

   Plus three **pack-contract function names** on `PyreliskPath`, which their
   unit owns and this one calls: `armRocks`, `neckCorePoint`, `climbSlabs`.
   **All three are shipped and live as of 2026-09-12** — the two warn-rails that
   stood in for the first two are retired, and the calls are now unguarded by
   any fallback (a missing one warns loudly and plants nothing). See §6.

   **`PyreliskShaftFloor` is RATIFIED into §7.2** (it is not pending): a number,
   on the arena model beside `PyreliskCaldera`; written by the colossus-side
   `Fn.pyreliskOpenCaldera`; read by the **server shaft watch only**; `nil` means
   *"the caldera never opened this fight — the shaft test must not run"*; and it
   is **cleared as a pair with `PyreliskCaldera` wherever that returns to 0**
   (the gimmick's close-then-recall, and `removeOwnedParts`). It exists because
   the depth half of the shaft test needs the arena's floor plane, the only thing
   that knows it is the colossus (`state.center.Y`), and the colossus is
   destroyed 1.5 s after the caldera opens while the creature that must keep
   watching the hole is the **heart**, in another room, which cannot ask it.
   Nor is it derivable: `BossArenas.volcano.center.Y` is `0` and `meshBottom` is
   the mesh's bbox, not the rim path. The pair-clear is landmark **5b-X** and is
   present (executed, 1).
7. **The bitmask counts are contracts, in both directions.** Six `armRocks`
   points ↔ six `PyreliskRocks` bits ↔ `K.PY_ROCK_COUNT = 6`. Eight
   `BossArenas.pyrelisk_heart.sockets` ↔ eight `PyreliskPillars` bits ↔
   `K.PY_PILLAR_COUNT = 8` ↔ `Bosses.pyrelisk_heart.parts.count = 8`. A ninth
   socket with no bit behind it is the failure mode a bitmask has, and it is
   silent. (The authored path additionally **asserts** `armRocks` returns exactly
   6 and warns-and-falls-back otherwise: a module handing back seven is not a
   bigger fight, it is a mask that stopped meaning what §7.1 says.)

> Every link in this chain has the same shape — **the value exists somewhere
> nothing reads it**, and it presents as a milder, different problem: a boss that
> pays nothing, a rescue that works perfectly at the wrong moment, an
> invulnerable heart, a lake that never opens. Not a crash. That is why the rule
> is *one unit or none*, and why the check is a landmark count rather than "did
> it build".

**Gate reminder:** `selene` / `check_compile` / `check_content` / `rojo build`
**cannot see any of this**, and neither can they see the 200-local limit —
`luau-compile -O0` (gate five) is the only check that does. All five gates
passing on a partial commit means nothing here. Two real defects in this work
were caught by gates rather than review (`def` undefined inside
`Fn.updatePyreliskHeart`, which `selene` reported as an **error**; a
`bossDef(creature)` call *above* `bossDef`'s own declaration, which
`luau-compile` was perfectly happy with and which would have thrown the first
time the heart died) — and both were fixed at the hunk source, not in the tree.

---

## 4. Inline re-run script

Save anywhere (it resolves the repo root itself) and run. It is read-only.
Expected output: **98 OK lines and `ALL LANDMARKS PRESENT`**, exit 0.

```sh
#!/bin/sh
# Pyrelisk redesign unit audit. Run from anywhere; it cds to the repo root.
root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "not a git checkout"; exit 1; }
cd "$root" || exit 1
B=src/Shared/Data/Bosses.luau
C=src/Shared/Data/Creatures.luau
F=src/Shared/Data/CreatureFamilies.luau
S=src/Server/Services/CreatureService.luau
V=src/Server/Services/BossService.luau
A=src/Shared/Config/BossArenas.luau
G=src/Server/Services/BossArenaService.luau
P=tools/check_content.py
fail=0; n=0
ck() { n=$((n+1)); got=$(grep -cE "$4" "$3" 2>/dev/null); got=${got:-0}
  if [ "$got" = "$1" ]; then printf 'OK   %-48s %s\n' "$2" "$got"
  else printf 'FAIL %-48s want %s got %s\n' "$2" "$1" "$got"; fail=1; fi; }
row() { n=$((n+1)); got=$(sed -n "/$4/,/^}/p" "$3" | grep -cE "$5"); got=${got:-0}
  if [ "$got" = "$1" ]; then printf 'OK   %-48s %s\n' "$2" "$got"
  else printf 'FAIL %-48s want %s got %s\n' "$2" "$1" "$got"; fail=1; fi; }

echo "--- Bosses.luau ---"
row 1 "PB1  pyrelisk phases[2] below 0.70"      $B '^Bosses.items.pyrelisk = [{]' '^		\{ below = 0\.70, '
row 0 "PB2  act-3 phase row REMOVED"            $B '^Bosses.items.pyrelisk = [{]' '^			below = 0\.30,$'
row 0 "PB3  act-3 book REMOVED"                 $B '^Bosses.items.pyrelisk = [{]' '^			attacks = \{ "ashfall", "ventbreath", "crownshed", "shardhurl" \},$'
row 1 "PB3n stances = 2 (was 3)"                $B '^Bosses.items.pyrelisk = [{]' '^	stances = 2,$'
row 1 "PB4  parts: pyrelisk_arm, count 2"       $B '^Bosses.items.pyrelisk = [{]' '^		row = "pyrelisk_arm",$'
row 0 "PB5  pyrelisk parts.regrow ABSENT"       $B '^Bosses.items.pyrelisk = [{]' '^		regrow = '
row 0 "PB6  pyrelisk parts.at ABSENT (mounts)"  $B '^Bosses.items.pyrelisk = [{]' '^		at = '
row 1 "PB7  handfall pays seamCredit 0.40"      $B '^Bosses.items.pyrelisk = [{]' '^			seamCredit = 0\.40,$'
row 0 "PB8a handfall weakStagger DELETED"       $B '^Bosses.items.pyrelisk = [{]' '^			weakStagger = '
row 1 "PB8b ...and its tombstone kept"          $B '^Bosses.items.pyrelisk = [{]' '.stagger. AND .weakStagger. ARE GONE'
ck  0 "PB9  seamStagger retired repo-file-wide" $B '^	seamStagger = '
row 0 "PB10 crownshed attack row REMOVED"       $B '^Bosses.items.pyrelisk = [{]' '^		crownshed = \{$'
row 1 "PB11 collapseFor 4.0"                    $B '^Bosses.items.pyrelisk = [{]' '^	collapseFor = 4\.0,$'
row 1 "PB12 succeededBy pyrelisk_heart"         $B '^Bosses.items.pyrelisk = [{]' '^	succeededBy = "pyrelisk_heart",$'
ck  1 "PB13 pyrelisk_heart row exists"          $B '^Bosses.items.pyrelisk_heart = \{$'
row 1 "PB14 heart islandId volcano"             $B '^Bosses.items.pyrelisk_heart = [{]' '^	islandId = "volcano",$'
row 1 "PB15 heart arenaKey"                     $B '^Bosses.items.pyrelisk_heart = [{]' '^	arenaKey = "pyrelisk_heart",$'
row 1 "PB16 heart summonable=false"             $B '^Bosses.items.pyrelisk_heart = [{]' '^	summonable = false,$'
row 1 "PB17 heart heartAs=pyrelisk"             $B '^Bosses.items.pyrelisk_heart = [{]' '^	heartAs = "pyrelisk",$'
row 1 "PB18 heart hitRadius 13 (x scale 2.0)"   $B '^Bosses.items.pyrelisk_heart = [{]' '^	hitRadius = 13,$'
row 1 "PB19 heart parts count 8"                $B '^Bosses.items.pyrelisk_heart = [{]' '^		count = 8,$'
row 1 "PB20 heart parts at sockets"             $B '^Bosses.items.pyrelisk_heart = [{]' '^		at = "sockets",$'
row 4 "PB21 heart four attack rows"             $B '^Bosses.items.pyrelisk_heart = [{]' '^		(ventspit|heartpulse|magmarain|ventbarrage) = \{$'

echo "--- Creatures.luau ---"
ck 1 "PC1  pyrelisk_arm row"        $C '^Creatures.items.pyrelisk_arm = \{$'
ck 0 "PC2  pyrelisk_ventrock REMOVED"   $C '^Creatures.items.pyrelisk_ventrock = \{$'
ck 0 "PC3  pyrelisk_neckcore REMOVED"   $C '^Creatures.items.pyrelisk_neckcore = \{$'
ck 1 "PC4  pyrelisk_heart row"      $C '^Creatures.items.pyrelisk_heart = \{$'
ck 1 "PC5  pyrelisk_pillar row"     $C '^Creatures.items.pyrelisk_pillar = \{$'
row 1 "PC6  heart gimmick pyreliskheart"  $C '^Creatures.items.pyrelisk_heart = [{]' '^	gimmick = \{ kind = "pyreliskheart" \},$'
row 1 "PC7  heart vulnerableWhen partsDown" $C '^Creatures.items.pyrelisk_heart = [{]' '^	vulnerableWhen = "partsDown",$'
row 1 "PC8  heart body.scale 2.0"           $C '^Creatures.items.pyrelisk_heart = [{]' '^		scale = 2\.0,$'

echo "--- CreatureFamilies.luau (untracked, audio lane's) ---"
ck 1 "PF1  pyrelisk_arm = leviathan"      $F '^	pyrelisk_arm = "leviathan",$'
ck 0 "PF2  pyrelisk_ventrock REMOVED"     $F '^	pyrelisk_ventrock = "elemental",$'
ck 0 "PF3  pyrelisk_neckcore REMOVED"     $F '^	pyrelisk_neckcore = "elemental",$'
ck 1 "PF4  pyrelisk_heart = elemental"    $F '^	pyrelisk_heart = "elemental",$'
ck 1 "PF5  pyrelisk_pillar = elemental"   $F '^	pyrelisk_pillar = "elemental",$'

echo "--- CreatureService.luau (slice 3: acts 1-2) ---"
ck 3 "CS1  ATTR.PY_ACT / ARM_L / ARM_R"     $S '^ATTR\.PY_(ACT|ARM_L|ARM_R) = '
ck 1 "CS2  K.PY_SEAM_METER_HP = 5400.0"     $S '^K\.PY_SEAM_METER_HP = 5400\.0$'
ck 1 "CS3a Fn.partyMult def (shared/kraken)" $S '^function Fn\.partyMult\(creature\): number$'
ck 1 "CS3b seamCredit divides by partyMult"  $S 'Fn\.pyreliskMeterFill\(creature, state, side, amount / \(K\.PY_SEAM_METER_HP \* Fn\.partyMult\(creature\)\)\)'
ck 1 "CS3c Fn.pyreliskMeterFill def"         $S '^function Fn\.pyreliskMeterFill\('
ck 2 "CS4a the two chip fractions"           $S '^K\.PY_(FLANK|ARM)_FRACTION = '
ck 0 "CS4a-z ROCK/CORE fractions REMOVED"    $S '^K\.PY_(ROCK|CORE)_FRACTION = '
ck 1 "X1  arm chip is 0.35 (was 0.20)"       $S '^K\.PY_ARM_FRACTION = 0\.35$'
ck 1 "CS4b K.PY_CHIP_FLOOR"                  $S '^K\.PY_CHIP_FLOOR = '
ck 6 "CS4c act-2 arm constants"              $S '^K\.PY_ARM_(WINDOW|SLUMP_EASE|POOL_GAP|POOL_R|POOL_ARM|POOL) = '
ck 13 "CS5 the act machine (13 Fn defs)"     $S '^function Fn\.pyrelisk(Chip|FlankBit|FlankPaid|MarkFlankPaid|BothFlanksBroken|UnscarredSide|PublishAct|ArmBars|PlantArm|DropArms|ArmsRetire|ArmsFailed|ArmsDone)\('
ck 1 "CS5b Fn.updatePyreliskArm(creature,now,dt)" $S '^function Fn\.updatePyreliskArm\(creature, now: number, _dt: number\)$'
ck 1 "CS6a flank chip on the scar transition" $S '^				if Fn\.pyreliskBothFlanksBroken\(state\) and not creature\.pyreliskArmsOut then$'
ck 2 "CS6b arm reconcile gated to act 2"      $S 'creature\.pyreliskArmsOut and \(creature\.pyreliskAct or 0\) == 2'
ck 1 "CS10 archetype updater row"             $S '^	pyreliskarm = Fn\.updatePyreliskArm,$'

echo "--- CreatureService.luau (slices 4 / 4b: ACT 3, CUT 2026-09-12 - all expected ZERO) ---"
ck 0 "S4-1 ATTR.PY_ROCKS / PY_CORE REMOVED"  $S '^ATTR\.PY_(ROCKS|CORE) = '
ck 0 "S4-4 rock/core constants REMOVED"      $S '^K\.PY_(ROCK_COUNT|ROCK_LIFT|ROCK_WEAVE|CORE_LIFT) = '
ck 1 "S4-4b K.PY_CALDERA_AT KEPT"            $S '^K\.PY_CALDERA_AT = 2\.5$'
ck 0 "S4-2 vent-swing minigame RETIRED"      $S '^(local pyreliskSwingAt|function Fn\.pyreliskVentSwing|K\.PY_VENT_REACH)'
ck 0 "S4-7 rock/core plant helpers REMOVED"  $S '^function Fn\.pyrelisk(RockPoints|CorePoint|PlantPart|PlantRocks|CoreBroken)\('
ck 2 "S4-10 def.collapseFor honoured KEPT"   $S 'def\.collapseFor or K\.COLLAPSE_TIME'
ck 0 "A1  Fn.pyreliskVentHazard REMOVED"     $S '^function Fn\.pyreliskVentHazard\('
ck 0 "A1b vent banding constants REMOVED"    $S '^K\.PY_VENT_(GAP|ARM|POOL) = '
ck 0 "A2  ramp plate/point helpers REMOVED"  $S '^function Fn\.pyreliskRamp(Plates|Points)\('
ck 0 "D1  crownshed handler REMOVED"         $S '^K\.ATTACK_HANDLERS\.crownshed = \{$'
ck 0 "D2  crownshed crown origin REMOVED"    $S '^		local head = PyreliskPath\.headCFrame\(state\)$'

echo "--- CreatureService.luau (the cut's own hunks) ---"
ck 1 "X2  K.PY_ACT_HEART = 3"                $S '^K\.PY_ACT_HEART = 3$'
ck 1 "X3  heart publishes the constant"      $S '^	if creature\.pyreliskAct ~= K\.PY_ACT_HEART then$'
ck 1 "X4  ArmsDone takes the body down"      $S '^	CreatureService\.damage\(creature, creature\.health, nil, \{ ignoreUntargetable = true \}\)$'
ck 1 "X5  mount gate: stagger + planted"     $S '^	if creature\.mode == "stagger" and \(state\.planted or 0\) ~= 0 and not creature\.collapsing then$'
ck 1 "X6  shardhurl always the fist"         $S '^		local hand = PyreliskPath\.fistPoint\(state, side\)$'
ck 0 "X8  no act 3 on the colossus"          $S 'Fn\.pyreliskPublishAct\(creature, 3\)'

echo "--- CreatureService.luau (slice 5b: caldera writer + shaft) ---"
ck 4 "5b-A caldera/shaft Fn set"             $S '^function Fn\.pyrelisk(ArenaModel|OpenCaldera|CloseCaldera|ShaftWatch)\('
ck 1 "5b-F ATTR.PY_SHAFT_FLOOR (ratified)"   $S '^ATTR\.PY_SHAFT_FLOOR = "PyreliskShaftFloor"$'
ck 4 "5b-C shaft constants"                  $S '^K\.PY_SHAFT_(R|DROP|GRACE|TICK) = '
ck 1 "5b-E the real caldera write at 2.5s"   $S '^		if not creature\.pyreliskCaldera and u \* fall >= K\.PY_CALDERA_AT then$'
ck 1 "5b-E2 shaft floor stamped on open"     $S '^		model:SetAttribute\(ATTR\.PY_SHAFT_FLOOR, floorY\)$'
ck 1 "5b-X shaft floor CLEARED with caldera" $S '^		model:SetAttribute\(ATTR\.PY_SHAFT_FLOOR, nil\)$'
ck 1 "5b-H removeOwnedParts reset"           $S '^		Fn\.pyreliskCloseCaldera\(heart and heart\.islandId\)$'
ck 1 "5b-J gimmick closes before recall"     $S '^			Fn\.pyreliskCloseCaldera\(def\.islandId\)$'

echo "--- CreatureService.luau (slice 6: act 4, the heart) ---"
ck 1 "S6-1 Fn.pyreliskCalderaOpen (MUST)"    $S '^function Fn\.pyreliskCalderaOpen\(islandId: string\?\): boolean$'
ck 2 "S6-2 ATTR.PY_CALDERA / PY_PILLARS"     $S '^ATTR\.PY_(CALDERA|PILLARS) = '
ck 4 "S6-3 heart constants"                  $S '^K\.PY_(HEART_BOSS|PILLAR_COUNT|PILLAR_STEP|PILLAR_POOL) = '
ck 1 "S6-4 spawnBossParts arenaKey (MUST)"   $S '^		local arena = \(def\.arenaKey or def\.islandId\) and BossArenas\.items\[def\.arenaKey or def\.islandId\]$'
ck 1 "S6-5 cadence step on every cooldown"   $S '^	creature\.cooldowns\[a\.name\] = now \+ a\.p\.cooldown \* rage \* \(creature\.cooldownStep or 1\)$'
ck 1 "S6-5b cooldownStep written per pillar" $S '^		creature\.cooldownStep = K\.PY_PILLAR_STEP \^ down$'
ck 0 "S6-6 shardhurl act-3 branch REMOVED"    $S '^		if \(state\.act or 1\) >= 3 then$'
ck 2 "S6-7a heart helpers"                   $S '^function Fn\.pyreliskHeart(Vents|Ground)\('
ck 4 "S6-7b the four heart handlers"         $S '^K\.ATTACK_HANDLERS\.(ventspit|heartpulse|magmarain|ventbarrage) = \{$'
ck 1 "S6-7c Fn.updatePyreliskHeart def"      $S '^function Fn\.updatePyreliskHeart\(creature, def, now: number\)$'
ck 1 "S6-7d K.GIMMICKS.pyreliskheart"        $S '^K\.GIMMICKS\.pyreliskheart = \{$'
ck 1 "S6-8 heart tick hook"                  $S '^	Fn\.pyreliskShaftWatch\(creature, def, now\)$'

echo "--- BossService.luau (slice 5) ---"
ck 1 "BS1  ARENA_MOVE_HERE = 260"            $V '^local ARENA_MOVE_HERE = 260$'
ck 1 "BS2  arenaPosition reads arenaKey"     $V '^	local arenaKey = boss\.arenaKey or boss\.islandId$'
ck 1 "BS2b floor probe on the same key"      $V '^		return Vector3\.new\(center\.X, BossArenaService\.floorY\(arenaKey, boss\.arena\.radius\), center\.Z\)$'
ck 1 "BS3  handoff does not pivot a roomed successor" $V '^	if at and not next_\.arenaKey then$'
ck 1 "BS4a ArenaMove optional third argument" $V '^	CreatureService\.ArenaMove\.Event:Connect\(function\(islandId: string, arenaKey: string, only: Player\?\)$'
ck 1 "BS4b recall ring sized off the destination" $V '^		local destination = Bosses\.byIsland\[arenaKey\]$'

echo "--- BossArenas.luau (slice 5) ---"
ck 1 "BA1a Arena type: caldera field"        $A '^	caldera: \{$'
ck 1 "BA1b Arena type: vents field"          $A '^	vents: \{ Vector3 \}\?,$'
ck 1 "BA2  volcano caldera block"            $A '^		caldera = \{$'
ck 1 "BA3  pyrelisk_heart arena row"         $A '^	pyrelisk_heart = \{$'

echo "--- BossArenaService.luau (slice 5) ---"
ck 1 "BAS1 placeAuthored returns the model"  $G '^	return model'
ck 1 "BAS2a CALDERA_ATTR"                    $G '^local CALDERA_ATTR = "PyreliskCaldera"$'
ck 1 "BAS2b applyCaldera"                    $G '^local function applyCaldera\(model: Instance, arena, open: boolean\)$'
ck 1 "BAS2c armCaldera (warns by name)"      $G '^local function armCaldera\(model: Instance, arena, islandId: string\)$'
ck 1 "BAS3 init arms the caldera"            $G '^				armCaldera\(placed, arena, islandId\)$'

echo "--- tools/check_content.py (the TWO-equality ledger, re-keyed 2026-09-12) ---"
ck 2 "P1a the two chip fractions read"       $P '^_(flank|arm) = _py_fraction\('
ck 1 "P1b threshold equality"                $P 'K\.PY_FLANK_FRACTION \* 2 = '
ck 1 "P1c act-2 equality"                    $P 'K\.PY_ARM_FRACTION \* 2 = '
ck 0 "P1d act-3 equality REMOVED"            $P 'K\.PY_ROCK_FRACTION \* 6'
ck 1 "P1d-n phases must be TWO rows"         $P 'rows, not 2 - the Pyrelisk'
ck 1 "P1e the ledger CLOSES"                 $P '^                "the ledger closes",$'

echo
echo "landmarks checked: $n"
if [ $fail = 0 ]; then echo "ALL LANDMARKS PRESENT"; else echo "*** MISSING PYRELISK HUNKS - SEE FAIL LINES ABOVE ***"; fi
exit $fail
```

Three portability notes, each learned by a script failing on it:

- In a `sed` **address**, `\{` opens an interval and errors with
  "braces not balanced" — match the Luau `{` as `[{]`.
- `grep -c` **exits 1 when the count is 0**, so `$(grep -c … || echo 0)` yields
  the string `"0\n0"` and every *expected-zero* landmark (PB5, PB6, PB8a, PB9,
  S4-2/3) reports a false FAIL. The script uses plain substitution instead. A
  false FAIL on a deletion check is exactly the kind of noise that gets an audit
  ignored. **Five of this unit's landmarks are expected-zero**, which is more
  than the Wrack unit had.
- **`cd "$(git rev-parse --show-toplevel)" || exit 1` does not fail when it
  should.** The Wrack script's opening line has this: outside a checkout,
  `git rev-parse` fails, the substitution collapses to `cd ""`, and `cd ""` is a
  **successful no-op** in `sh` — so the `|| exit 1` never fires and the whole
  audit runs against whatever directory you happened to be in, reporting
  cheerful `OK 0`s and `FAIL`s that mean nothing. This script captures the root
  into a variable and tests *that*.

### The by-name row-set walker (§2)

`Bosses.items.<id> = {` … matched, then **braces walked** — skipping `--` and
`--[[ ]]` comments and both quote styles — so a nested table never truncates the
row. Comments and blank lines are stripped before comparison, so a
comment-only edit is not reported as CHANGED.

```python
import re
def rows(text, prefix):
    out = {}
    pat = re.compile(r'^' + re.escape(prefix) +
                     r'\.items(?:\.([A-Za-z_]\w*)|\["([^"]+)"\])\s*=\s*\{', re.M)
    for m in pat.finditer(text):
        rid = m.group(1) or m.group(2)
        i, depth, n = m.end() - 1, 0, len(text)
        while i < n:
            c = text[i]
            if text[i:i+2] == '--':
                if text[i:i+4] == '--[[':
                    j = text.find(']]', i); i = (j + 2) if j >= 0 else n; continue
                j = text.find('\n', i); i = (j + 1) if j >= 0 else n; continue
            if c in '"\'':
                q = c; i += 1
                while i < n and text[i] != q:
                    i += 2 if text[i] == '\\' else 1
                i += 1; continue
            if c == '{': depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    out[rid] = text[m.start():i+1]; break
            i += 1
    return out
```

Drive it with `git show HEAD:src/Shared/Data/Bosses.luau` on one side and the
worktree file on the other; print NEW / REMOVED / CHANGED. **REMOVED non-empty
is a stop-everything result** — per the shared-file commit protocol it means a
reconstruct-commit dropped a row, and that loss is invisible to all five gates.

The families check is membership, not diff:

```sh
# 129 creature ids, 129 family rows, both directions empty (131/131 pre-cut)
```

---

## 5. The naming convention that will trip the next reader

**`CreatureService.luau` is at the Luau 200-local limit, and that is why nothing
in this unit looks like the rest of the project.**

HEAD calls the attack registry `local ATTACK_HANDLERS` and its helpers
`local function <name>`. The worktree calls them `K.ATTACK_HANDLERS` and
`Fn.<name>` — that is the **200-local register-limit consolidation**, not a
Pyrelisk change. A HEAD-vs-worktree grep under either name alone reports 0 and
looks like total loss. It is not.

**Top-level `local` count in `CreatureService.luau`: 101** (executed,
`grep -cE '^local '`). The trajectory across this work was 105 → 105 (slice 3,
zero added) → **101** (slice 4, which *bought four back* by retiring the
vent-swing minigame: `pyreliskSwingAt` plus the `InventoryService`, `Equipment`
and `Weapons` requires, all four audited by grep first — the only surviving
mentions of `Weapons` are in two comments) → 101 → 101 → 101.

**The rule: no new top-level `local` in this file, or in
`CreatureEventController.luau`.** Every symbol this unit adds is a field on
`ATTR`, `K` or `Fn`. If you need a new one, you must retire one. `luau-compile
-O0` (gate five) is the only check in the project that sees this; it took the
game down on 2026-09-06.

Two more naming notes:

- **`Fn.partyMult` is now SHARED with the kraken lane.** Slice 3 added it
  (factored out of `Fn.pyreliskSeamCredit`); the kraken lane then adopted it at
  three call sites, each replacing a `creature.healthMult` that **was never set
  on any record** — `spawn` reads only `extra.healthMult`, and the field is
  written nowhere. So the Kraken's arms, its dais adds and the gullet polyps had
  **never** been party-scaled. That fix is the kraken lane's and its three call
  sites carry their own comments; `Fn.partyMult`'s *definition* is this unit's
  and CS3a counts it once. **It cannot be moved, renamed or re-signatured
  without breaking three other lanes' hunks in the same file.**
- **`Fn.pyreliskRampPlates` is the single filter over `climbSlabs`.** The rocks
  (S4-7) and `crownshed`'s landings (A2) both go through it, deliberately: the
  plate names are the contract with `PyreliskPath` and belong in one place.

---

## 6. The two warn-rails — **RETIRED 2026-09-12**

Both are gone. The mesh lane's slice-2 FINAL is in the worktree,
`PyreliskPath.armRocks` and `PyreliskPath.neckCorePoint` are live and
measured-fed, and the two consumers now read them and **nothing else**.

| rail | status | what it does now |
|---|---|---|
| `Fn.pyreliskRockPoints` | **RETIRED** | reads `PyreliskPath.armRocks`; keeps the exactly-6 assert; **no fallback** — a missing/ill-shaped return warns loudly and plants nothing |
| `Fn.pyreliskCorePoint` | **RETIRED** | reads `PyreliskPath.neckCorePoint`; **no fallback** — a missing function warns loudly and returns nil |

**The fallbacks were deleted rather than kept behind a louder warning, and that
is the point of the change.** A derived second answer is worse than none: it is
reachable, plausible, and wrong in a way nobody can see from inside the fight —
six rocks on a route that is no longer the route, with the fight playable enough
that nothing ever gets reported. A missing module function is a bug in the
module and must read as one.

The exactly-6 assert **stays** even though six is now true by construction on
the module's side (`ROCK_TS` has six entries and the walk's `order == 3`
fall-through guarantees each yields a point). It is not doubt about today's
module — it is the contract `ATTR.PyreliskRocks` is written against, and the day
someone adds a seventh `t` the bit with no rock behind it is invisible.

### Verified against the mesh lane's sanity table, by execution

The live module was run against their own stubbed-Roblox harness
(`luau` + `gate.luau`'s driver, rebuilt over the **worktree** `PyreliskPath.luau`
rather than their inlined snapshot). Boss-local, act 3, planted side +1:

| point | r | y |
|---|---|---|
| rock 1 | 179.49 | 5.40 |
| rock 2 | 159.76 | 15.97 |
| rock 3 | 146.47 | 23.78 |
| rock 4 | 122.55 | 31.60 |
| rock 5 | 113.06 | 46.41 |
| rock 6 | 93.03 | 48.79 |
| neck core | 45.99 | 46.17 |
| fist | 192.00 | −11.81 |

**Every value matches the handed-over table exactly**, and `#armRocks == 6`.

## 6a. The chord audit (the fallen arm is not radial)

Measured off the same run: the arm's joints sweep **46.62° of bearing** from
fist (−24.61°) to shoulder (−71.23°), and the six rocks spread **29.07°**. A
radial arm would be ~0° on both. Everything this unit wrote was swept for a
"radial arm" assumption:

| site | verdict |
|---|---|
| `Fn.pyreliskRockPoints` | reads `armRocks` — the module walks the fallen bone chain ✅ |
| `Fn.pyreliskCorePoint` | reads `neckCorePoint` — body-local through `bodyCFrame` ✅ |
| `Fn.pyreliskRampPoints` (crownshed banding) | bands by **arc length along the actual plates** and places in **plate-local** space (`slab.cframe * CFrame.new(alongX, …, offZ)`) — follows the chord ✅ |
| `Fn.pyreliskRampPlates` | filters `climbSlabs` by plate name; no geometry of its own ✅ |
| `Fn.updatePyreliskArm` (arm lava pools) | scatters around **the arm creature's own point**, not a radial line ✅ |
| `Fn.pyreliskVentHazard` | `PyreliskPath.ventPoint` — body-local sites ✅ |
| `Fn.pyreliskShaftWatch` | arena centre + depth; no arm term ✅ |
| `Fn.pyreliskLavaWatch` | lake radius from arena centre; no arm term ✅ |
| heart room (`pyreliskHeartGround`, `ventbarrage`) | different arena, no arm ✅ |
| `Fn.pyreliskPlantArm` | the **only** radial expression left — see below ✅ |

**Nothing needed fixing.** `Fn.pyreliskPlantArm`'s band clamp survives the
distinction because it is **containment, not placement**: it asks only "is this
point on the walkable annulus", which is a true question about any point however
the limb got there, and it moves nothing that already is. Measured, the fist is
at **r 192.00** inside `[130, 222]`, so it is **inert** and its warn does not
fire. The comment there now says what it must never become — a *derivation*
("the arm runs from r X to r Y, so place things along that line").

**One consequence worth recording, not a defect:** because the arm pools scatter
around the arm creature's own point, and that point is the **fist**, the pools
cluster at the hand end and the upper ~two-thirds of the 150-stud limb gets
none. That is consistent with F-5 option (a) — "ship it as a sphere at the fist
and accept that you fight the hand" — which is the same decision `shotRadius =
14` already encodes. It becomes worth revisiting only if F-5's `hitAxis`
follow-on lands and the whole limb becomes shootable.

## 6b. `FaceAngle` stops at act 2

Anchor: the `K.RIG_POSE[creature.poseKind]` publish branch in `publishPose`
(the shared rigged-colossus publish; `grep -n 'ATTR.FACE_ANGLE' ` → the third
hit). Pyrelisk-only; every other rigged boss on that branch is untouched.

`PyreliskPath.frozen(state)` is true for `act >= 2` and ignores the field, so
from the moment the arms come down it was a number crossing the wire every frame
that nothing read. It is **cleared to nil rather than frozen at its last value**,
because the waste was never the real cost: a live `FaceAngle` on a body that
cannot turn is exactly the plausible-looking field a future reader picks up (a
HUD arrow, a "which way is it looking" VFX) and it would track the last
pre-freeze heading forever while the drawn body faced somewhere else.

## 6c. `pyrelisk_neckcore.shotRadius` — **RESOLVED 2026-09-12**, 11.0 → 13.0

**Measured 13.40 at the relocated site; the single source of position is
`PyreliskPath.neckCorePoint`.**

11 was sized off the neck's profile before the collar existed, against an
**on-axis site that sat inside the skull** — only 25–33% of the rock exposed, so
most of a capture aimed at it was buried in head. The mesh lane moved the site
to straddle the collar (authored `(4, 18, 160)`, mirrored by flank); it is now
**64% exposed** with an effective radius of **13.40**.

**Authored as 13.0, not 13.40, deliberately** — rounded DOWN so the capture
stays inside the exposed rock rather than reaching past it into the collar. That
is the same direction of error the Wrack's casemates are solved in, and the safe
one. *Do not round it up to "the measurement".*

**No server position change was needed, and that is the rail's retirement paying
off.** `Fn.pyreliskCorePoint` reads `PyreliskPath.neckCorePoint` at runtime with
no fallback, so the site moved without a line changing on the server — this row
owns only how big the thing you shoot at is. Had the derived fallback still been
in place, the server would have gone on planting the core at the old on-axis
point and the two lanes would have disagreed silently.

Landmark: `grep -n 'shotRadius = 13.0' src/Shared/Data/Creatures.luau` (one hit,
in `Creatures.items.pyrelisk_neckcore`). Re-derive from the BUILT object if the
rock is ever resized — measured off what was exported, never off the constant
that generated it.

### Two stale copies of the old number, found by grep and fixed

The field was changed before its prose was, and **the row carries the number
twice**: once on the field and once in the block comment above
`Creatures.items.pyrelisk_neckcore = {`, which still read "`shotRadius = 11.0`
against the neck's own profile". Both now say 13.0, and the outer one names
`PyreliskPath.neckCorePoint` as the single source of position so the next reader
does not go looking for a position in this row.

`docs/pyrelisk-fight-design.md:610` also carries `shotRadius = 11.0` in its §4.3
code block. **Left at its authored value and annotated `SUPERSEDED 2026-09-12`**
rather than edited: that document records what was designed, and silently
rewriting it would erase the fact that the number moved. The annotation is there
so nobody copies it forward.

**This is the second time in two slices that a replacement anchored at the
`function`/field line left a stale header above it describing the old
behaviour** (slice 7, §6, hit the same thing on both warn-rails). The rule is
now explicit: **anchor a replacement at the top of the comment block that
documents it, not at the line being changed** — comments are invisible to all
five gates, and a comment that contradicts the code beside it is worse than no
comment, because it is evidence.

## 7. Still open

> **AMENDED TWICE 2026-09-12. Item 0 was found by the act-3 cut and is now
> FIXED — the fight reaches the heart.**
>
> **0. `beginBossCollapse` sent the Pyrelisk down the Wrack's WRECK branch, so
> the caldera never opened. — FIXED 2026-09-12.** The gate was
> `def and def.succeededBy and creature.mode and creature.mode ~= "rising"`, and
> `succeededBy` means "this boss has a successor", not "this is a ship that
> wrecks" — the Pyrelisk has one (`pyrelisk_heart`). So the posed colossus took
> the ship's path: `creature.wrecking` set, `WRACK_WRECK` published on a rig
> that does not read it, the hold sized by `wreckFor` (absent → 2.5) rather than
> `collapseFor` (4.0) — and `Fn.updateBossCollapse` returned at its
> `if creature.wrecking` test **before** the `poseKind == "pyrelisk"` branch. So
> no collapse pose, **no `PyreliskCaldera`, no `PyreliskShaftFloor`, no shaft
> watch, nobody moved to the heart.** Every slice-5b landmark was present and
> correct, pointing at code that was never reached. True since slice 5b, silent,
> and the act-3 cut made it the only way the fight can end.
>
> **The fix is one condition:** the branch now tests
> `def.succeededBy and def.wreckFor` — the Wrack-specific data it actually
> consumes, on a field that exists on exactly one row
> (`Bosses.items.admiral_wrack`), so a boss opts INTO wrecking by carrying the
> number that sizes it. (`not def.pose` would have worked and is worse: a test
> for the absence of an unrelated field is one rename away from being wrong
> again.) `Fn.updateBossCollapse`'s `creature.wrecking` early return stays a
> flag, annotated: one writer, one clearer, so it cannot disagree with the gate
> the way the gate disagreed with its own body.
>
> **It is a WRACK-REGION hunk and it is on the Wrack unit's checklist**, which
> is where a committing lane will look for it:
> `docs/wrack-fight-handoff.md` **§5a**, landmarks **S22 / S22z**. Recorded in
> both records on purpose.
>
> **Verified by execution, both fights, both ways** (the trace runs against the
> live `Bosses.luau` rows): Admiral → wreck branch, 2.5 s hold, byte-identical,
> then `wrack_duel`; Pyrelisk → perch/collapse branch, 4.0 s, the pyrelisk
> branch RUNS, caldera at 2.5 s, shaft watch, `kill()`, the heart. With the gate
> reverted, the Pyrelisk takes the wreck branch and the caldera write is
> unreachable — the bug reproduced on demand.

Nothing else here blocks the commit. Everything else is downstream of it, and
every other item is *inert* rather than broken: the fight runs today, in a
stand-in room.

1. **`arena_pyrelisk_heart.glb` does not exist.** Until it imports, the heart
   room is `BossArenaService`'s procedural stand-in at the waterline, and
   `BossArenas.pyrelisk_heart`'s `center` / `meshBottom` / `floorRadius` /
   `sockets` / `vents` / `spawnPad` / `barrier` / `palette` are all
   PLACEHOLDERs. The fight runs; it is not in the right room and the pillars are
   on a plain circle. **`meshBottom = 584.0` is copied from the gullet and is
   wrong by construction.** Re-key every number from a HANDOFF line that is
   **already negated** (Roblox Z = −author Y) — this arena has had the
   mirrored-monolith bug once already, in its nine `stones`.
2. **The caldera objects are not exported.** `_LakeFloor`, `_Shaft`, `_Lava`
   don't exist yet, so `applyCaldera` reports them missing. The attribute flips
   and the shaft watch works; **no geometry actually changes yet.** `_Shaft` also
   needs **PreciseConvexDecomposition** at import or a default hull fills the
   tube solid and there is no shaft at all. And the exported group **must be
   named `PyreliskArena`** — `armCaldera` warns when it isn't, because
   `CreatureService` finds it by that name.
3. **`caldera.landing` is `(0, 0, 0)`** — a placeholder. The mesh lane owes the
   `_Shaft` HANDOFF line. **Do not derive it** from `PY_RIM_WORLD_Y` minus a
   120-stud depth; the depth is a free variable until the export prints it.
4. **The shaft has no floor.** `_Shaft` is authored walls-only, and its foot is
   ~100 studs under a rim path 292 up, so a fall `Fn.pyreliskShaftWatch` misses
   continues to the **sea**, ~170 studs further. Survivable (there is no fall
   damage anywhere in `src/` — grepped) but it is a player in open ocean 23,400
   studs from anywhere with a fight still running. A 0.5 s poll against a body in
   free fall is a coarse net. Worth a floor, or a much earlier trigger.
5. **Client-side is entirely untouched by this unit** and is session 71's: the
   `fallen` pose drawing, `PyreliskAct` gating, the `PyreliskRocks` /
   `PyreliskPillars` HUD, `PoseCenter` read **per frame** (never cached — the
   heart teleport strands the rig at the caldera otherwise), and the heart room's
   mood in `WeatherController.luau` **and `MusicController.luau`**. §8.1 of the
   design lists only the first of those two files; both run the identical scan
   over `BossArenas.items` keyed off `arena.islandId`, and the heart row's
   `islandId = "pyrelisk_heart"` will be returned by both and found by neither.
   Pre-existing (the gullet has the same hole) but the playtest note is a
   two-file claim written against one file.
6. **`PyreliskShaftFloor` — RATIFIED, nothing owed.** It is §7.2 contract, its
   writer and reader are in this unit, and its pair-clear is landmark 5b-X,
   executed and present. Listed here only because earlier drafts of this record
   carried it as pending; it is not.
7. Raised and deliberately not fixed in this unit, both needing another lane's
   review: the design's claim that the scarred-flank latch *prunes* `phases[2]`
   (it is implemented as a **preference**, which is what the mechanism can
   actually do — making the claim true needs a pool filter); and
   `Fn.pyreliskCoreBroken` leaving `creature.deathBlow` nil, because rock and
   core deaths are reconciled off the world rather than hooked into `kill()`.
   The payout is unaffected — every boss death here pays the fight's participant
   set, built at summon.

---

## 7a. The lifted-arena `spawnPad` hole — **FIXED 2026-09-12** (slice 5b)

**The landmark, in one sentence:** `BossArenaService.ringPositions` placed a
party on an authored `spawnPad` at `center + pad.offset`, and `center.Y` is 0 for
every row in `BossArenas.luau` by that file's own header — so on an arena pinned
above the waterline by `meshBottom` the room's LIFT never entered the sum and the
party was put down under its own floor.

Found by the Pyrelisk mesh lane while filling `pyrelisk_heart`, whose note on
that row states the diagnosis and correctly refuses to fix it there. It was
**not** a Pyrelisk bug: `maelstrom_gullet` has carried the identical hole since
the Kraken's rework, and the Tidebreak only ever looked right because a sea-level
arena's lift is zero.

**Why nothing shouted.** `verifyWaterline` probes from `World.WATER_Y + 200` down
400 studs — a window of −200…+200 — so a room whose floor is at 600 is entirely
outside it and the checker returns silent. It also checks the arena's GEOMETRY,
and the geometry was correct; it was the drop-in that was in the wrong world.
`verifyGround` uses `FLOOR_PROBE_TOP` (900) and can see such a room, but it has
no profile for either interior and returns on its first line.

**The lift, and where it comes from.**
`lift = meshBottom − the mesh's own authored bbox floor`, which is exactly
`delta.Y` inside `placeAuthored` — the number it already computes in order to do
the pivot. One line after that pivot it is unrecoverable, because the pivot is
what consumed it: the placed model's bbox floor now reads `meshBottom` and the
difference measures zero. So it is **kept, not re-derived**.

| arena | `meshBottom` | authored bbox floor | lift |
|---|---|---|---|
| every waterline-convention row | = its own bbox floor | — | **0** |
| `maelstrom_gullet` | 584.0 | −16 | **600** |
| `pyrelisk_heart` | 586.0 | −14 | **600** |
| `volcano` | −84.7 | −376.7 | 292 (disc branch — unaffected, it probes) |

**Anchors — `src/Server/Services/BossArenaService.luau`, five in-place inserts:**

1. `local arenaLift: { [string]: number } = {}`, beside `local arenaFolder`.
2. `placeAuthored` now ends `return model, delta.Y`.
3. `init`'s authored branch: `local placed, lift = placeAuthored(folder, arena, template)`.
4. …and `arenaLift[islandId] = lift` inside the existing `if placed then`.
5. `ringPositions`' pad branch:
   `local at = center + pad.offset + Vector3.new(0, arenaLift[islandId] or 0, 0)`.

**Recorded only on the authored path**, which is the same path that creates the
lift. An arena whose mesh is not imported is built by `buildFloor` at the
waterline, gets no entry, and every reader treats a missing entry as zero — so
the procedural fallback lands people exactly where it always did.

**Y at every `ArenaMove` destination in the project** (arithmetic of the code
path; `meshBottom` and `pad.offset.Y` parsed out of `BossArenas.luau`, not
retyped):

| fire | branch | before | after |
|---|---|---|---|
| Kraken `maelstrom` → `maelstrom_gullet` (`krakenSwallow`) | pad | **5.9** — 594 studs under the floor, inside the ocean slab | **605.9** on a floor datum of 600 |
| Kraken `gullet` → `maelstrom` (`K.GIMMICKS.krakenheart`) | pad | 20.9 | **20.9 — byte-identical**, lift 0 |
| Pyrelisk `volcano` → `pyrelisk_heart` (shaft watch / 30 s grace) | pad | **6.9** | **606.9** on a floor datum of 600 |
| Pyrelisk `heart` → `volcano` (`K.GIMMICKS.pyreliskheart`) | disc | `floorY` probe → rim path **295.5** | unchanged — the disc branch never used the pad |

**Sibling placement paths, read and ruled on:**

* **`centerFor`** — returns `arena.center`, Y 0. **No change, and the fix must
  not go here**: its contract is *where on the map*, not *how high*. Every caller
  already takes Y from somewhere else (`arenaPosition` and `ringPositions`' disc
  branch from `floorY`; the `ArenaMove` proximity test is XZ-only). Its Y must
  never be read as a height.
* **`floorY`** — a real downward raycast from `World.WATER_Y + FLOOR_PROBE_TOP`
  (900) through 1400 studs, so it finds a floor at 600 on its own and
  `SEA_LEVEL_BAND` (20) cannot snap it. **No change needed.** Caveat for the next
  room: 900 is the ceiling on how high an arena can be lifted before the probe
  starts below its own floor, and that failure would be silent.

### 7a.1 …and the guard rail — **the whole class is loud now** (slice 5c)

Kraken lane's follow-up, and the right instinct: the lift fix corrects the two
rooms that exist, but the *class* is "a placement computed in one frame and used
in another", and adding one term does nothing to make the next instance loud. So
every drop-in is now measured against the band its own arena actually occupies.

**The choke point is `ringPositions` itself, not a caller.** It has two callers
(`BossService.dropIn` on the summon and the `ArenaMove` listener on an act
break), and it is the single function that produces drop-in CFrames for *both*
its branches. Checking inside it covers every placement in the project; checking
in a caller would cover one of two.

**Anchors — `src/Server/Services/BossArenaService.luau`, seven in-place inserts:**

1. `local arenaBand: { [string]: { lo: number, hi: number } } = {}` — beside `arenaLift`.
2. `placeAuthored` now ends
   `return model, delta.Y, { lo = targetCenterY - boxSize.Y / 2, hi = targetCenterY + boxSize.Y / 2 }`
   — both numbers are ones it already computed for the pivot. After that pivot
   the model's bbox floor *is* `meshBottom` by construction, so this is the
   placed model's floor and ceiling in world Y with nothing measured twice.
3. `init`: `local placed, lift, band = placeAuthored(folder, arena, template)`.
4. `init`: `arenaBand[islandId] = band`, beside `arenaLift[islandId] = lift`.
5. `local BAND_TOLERANCE = 4.0` and `local function checkDropBand(islandId, y)`,
   immediately above `ringPositions`.
6. Pad branch: `checkDropBand(islandId, at.Y + 3.5)` before `return ring`.
7. Disc branch: `checkDropBand(islandId, floorY + 3.5)` before `return ring`.

**One check per ring, and it is complete rather than a sample:** every position
in either branch is built at one Y (`at.Y + 3.5`, or `floorY + 3.5`), so the ring
has exactly one height and checking it once checks all of it.

**Warn, never error.** This fires at the moment a fight starts; taking the fight
down is worse than an odd placement with a line in the log naming the arena.
Warn-by-name is the file's existing convention (`placeAuthored`'s uncoloured-part
count, `ringPositions`' own hazard-surface warning, `verifyGround`,
`verifyWaterline`). **No band, no check** — an arena built by `buildFloor` has no
imported mesh to bound, records nothing, and `checkDropBand` returns on its first
line. Inventing a bound for a procedural disc would be a false positive waiting
for the first arena that does not fit it.

`BAND_TOLERANCE = 4.0`: the ring adds 3.5 studs of settle clearance over
whatever it stood on, so a correct placement on the model's topmost surface sits
3.5 proud of `hi` by design and the tolerance must clear that. It does, by half a
stud — and the failures this exists for miss by **hundreds** (594, for the
gullet), so nothing turns on where between 4 and 500 the line is drawn.

**Every band, measured from the shipped `.glb` files** (glTF POSITION accessor
min/max, not retyped from any comment). This is also an independent check of the
whole lift argument — `lift = meshBottom − authored bbox floor` comes out at
exactly 0 for every waterline-convention arena, at exactly `PY_RIM_ABOVE_SEA` for
the volcano, and at exactly 600 for both sealed rooms:

| arena | `meshBottom` | authored bbox | lift | band [lo, hi] |
|---|---|---|---|---|
| `tropical` | −9.5 | −9.50 … 64.62 | **0** | [−9.5, 64.6] |
| `swamp` | −9.5 | −9.50 … 50.85 | **0** | [−9.5, 50.8] |
| `ice` | −9.5 | −9.50 … 24.27 | **0** | [−9.5, 24.3] |
| `gloom` | −9.5 | −9.50 … 46.00 | **0** | [−9.5, 46.0] |
| `wreck` | −13.5 | −13.50 … 47.35 | **0** | [−13.5, 47.3] |
| `maelstrom` | −15.4 | −15.40 … 70.00 | **0** | [−15.4, 70.0] |
| `volcano` | −84.7 | −376.74 … 32.00 | **292.0** | [−84.7, 324.0] |
| `maelstrom_gullet` | 584.0 | −16.00 … 91.16 | **600.0** | [584.0, 691.2] |
| `pyrelisk_heart` | 586.0 | −14.00 … 81.00 | **600.0** | [586.0, 681.0] |

The two measured floors (−16.000, −14.000) match those rows' own MEASURED
comments to the stud, which is what makes 584 and 586 the right two numbers
rather than a copied one.

**Control — run in `luau`, against `checkDropBand` extracted verbatim from the
built file** (not retyped) and the measured bands above:

| case | y | result |
|---|---|---|
| `maelstrom_gullet` pad + lift 600 | 605.9 | silent |
| `pyrelisk_heart` pad + lift 600 | 606.9 | silent |
| `maelstrom` pad (lift 0) | 20.9 | silent |
| `volcano` disc branch, `floorY` → rim path | 295.5 | silent |
| `tropical` / `swamp` / `ice` / `gloom` / `wreck`, sea level | 3.5 | silent ×5 |
| **`maelstrom_gullet` pad, lift term zeroed** | **5.9** | **WARN**, band [580.0, 695.2] |
| **`pyrelisk_heart` pad, lift term zeroed** | **6.9** | **WARN**, band [582.0, 685.0] |
| `maelstrom` pad, lift term zeroed (its lift is 0) | 20.9 | silent — correctly unaffected |
| an arena with no recorded band (procedural fallback) | 3.5 | silent — returns on line 1 |

**fired = 2, silent = 11.** Exactly the two rooms the bug lives in, and nothing
else. Harness: `scratchpad/pyrelisk-phases/slice5c/control.luau`.

## 8. Commit-time procedure

Per the shared-checkout rules — live sessions in every one of these files,
explicit paths only, `&&` not `;`, never `--amend`:

1. Run §4. Require **`ALL LANDMARKS PRESENT`**, exit 0, **98 checked**.
2. Re-run §2 and confirm **REMOVED is empty** for both tables, and that the
   families membership check is empty in **both** directions.
3. Run gate five, `luau-compile -O0`, on `CreatureService.luau` — the other four
   gates cannot see the 200-local limit. Confirm the count is still **101**
   (`grep -cE '^local ' src/Server/Services/CreatureService.luau`).
4. Run `python3 tools/check_content.py` **with the worktree copy of the file** —
   the ledger gate is part of this unit and is the only thing that checks the
   four-equality chip ledger.
5. Confirm with the audio lane before `CreatureFamilies.luau` is staged by
   **anyone**; it is their untracked file and five of our rows are in it (§3.3).
6. Stage **by explicit path only** — never `-A`, never `.`, never `-a`:

   ```sh
   git add src/Server/Services/CreatureService.luau \
           src/Server/Services/BossService.luau \
           src/Server/Services/BossArenaService.luau \
           src/Shared/Config/BossArenas.luau \
           src/Shared/Data/Bosses.luau \
           src/Shared/Data/Creatures.luau \
           tools/check_content.py \
           docs/pyrelisk-fight-handoff.md \
           docs/pyrelisk-fight-design.md
   ```

   (`src/Shared/Data/CreatureFamilies.luau` is added **only** by whoever owns it,
   in this same commit or an immediately adjacent one — see §3.3. It is
   **untracked**, so a reconstruct-commit flow that stages by
   `update-index --cacheinfo` against paths it knows about will **never** land
   it, and neither will a pathspec'd commit written from a diffstat.)

7. **Never reconstruct the commit from HEAD.** These files carry five other
   lanes' in-flight hunks. Before committing, diff the **staged symbol set**
   against the **worktree symbol set** for `CreatureService.luau` and
   `Bosses.luau`. The failure this catches is a reconstruct-commit that silently
   drops another lane's work from a shared file — invisible to all five gates.
8. Commit. Do not amend afterwards.

**Gates green at the last apply (2026-09-12):** `stylua --check` on our paths
only (never `stylua src` — a tree pass reformats other lanes' in-flight files
under them) · `selene src` **0 / 0 / 0** · `check_compile` OK, 152 files ·
`check_content` OK, 129 creatures / 9 bosses · `rojo build` OK.
(Re-run after the act-3 cut, 2026-09-12: `stylua --check` on the four `.luau`
paths OK · `selene src` 0 / 0 / 0 · `check_compile` OK, **155** files ·
`check_content` OK, **129** creatures / 9 bosses · `rojo build` OK · §4's own
audit 109 / 109.)

`stylua --check` on `CreatureService.luau` reports **22 long lines in
`Fn.armPortcullis` and the herding snap — the noctyss lane's**, present in the
base before this unit touched the file and verified to be diff-line-identical
before and after (22 = 22). **Not formatted by this lane, deliberately:** a
formatter run over another lane's in-flight file is a shared-file write. The
noctyss lane owes one `stylua` pass on their own paths.
