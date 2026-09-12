# Wrack fight — commit-time handoff record

> **THIS FILE IS UNTRACKED AND MUST STAY THAT WAY UNTIL THE UNIT LANDS.**
>
> It lives in `docs/` rather than a session scratchpad **because the last copy of
> this record was lost when `/private/tmp` was purged** — the checklist for a
> long-lived uncommitted unit cannot live somewhere a purge or a new session can
> take it. It is durable here; it is not staged.
>
> - **Do not `git add -A`, `git add .`, or `git commit -a`.** This is a shared
>   checkout with 7 live sessions.
> - When the CS/CEC consolidation commit is approved, this file is committed
>   **by explicit path, in the same commit as the unit**:
>   `git add docs/wrack-fight-handoff.md <the five unit paths> && git commit`.
> - Until then it is invisible to every gate and to every other lane, which is
>   correct: it describes work that is not in HEAD.

Regenerated **2026-09-12** by re-running the audit from scratch against the
current worktree. Every landmark below was **executed**, not transcribed.
Result: **52 / 52 landmarks present, 0 missing. Nothing was lost in the purge.**

---

## 0. What the unit is

The Wrack three-act fight: **four corner cannons → hull act with expose windows →
Admiral duel**. Implemented, gate-green, and **uncommitted**, spread across five
files. HEAD's `admiral_wrack` has **11** attack rows; the worktree has **15**
(verified by a brace-aware walk, not a regex).

Those five files **also** carry other lanes' uncommitted hunks (noctyss, kraken,
pyrelisk, rimefang, cutscene, audio, island-population). **Attribute by name,
never by offset.** A regex over a Luau table truncates on nested braces — the
row extractor in §4 walks braces and skips strings and comments.

---

## 1. Landmarks, per file

All counts below are the **executed** result on the current worktree. Every
pattern is line-anchored so it cannot drift when the shared files move.

> **Reading the patterns:** `\t` below stands for a **literal TAB** — Luau indents
> with tabs, and `grep -E` does **not** expand `\t`. The §4 script contains real
> tab characters; if you retype a landmark by hand, type a tab. `\|` is table
> escaping for `|` (alternation). Everything else is the pattern verbatim.

### `src/Shared/Data/Bosses.luau` — 10 hunks, 17 landmarks

| ID | Hunk | Landmark (`grep -cE` unless noted) | Count |
|----|------|------------------------------------|-------|
| B1 | `Boss` type: `succeededBy` field | `^\tsucceededBy: string\?,$` | 1 |
| B2 | `Boss` type: `heartAs` field | `^\theartAs: string\?,$` | 1 |
| B3 | `Boss` type: `summonable` field | `^\tsummonable: boolean\?,$` | 1 |
| B4 | `admiral_wrack` gains the `rigging` slot | `^\trigging = [{]$` | 1 |
| B5 | `admiral_wrack` gains the `acts` band block | `^\tacts = [{]$` | 1 |
| B6 | `admiral_wrack` hands off to the duel | `^\tsucceededBy = "wrack_duel",$` | 1 |
| B7 | `admiral_wrack` collapse length | `^\twreckFor = 2\.5,$` | 1 |
| B8 | **`regrow` DELETED** (row-scoped) | `^\t\tregrow = ` | **0** |
| B9 | …and its tombstone comment kept | `regrow. IS DELETED` | 1 |
| B10 | four new attack rows | `^\t\t(ladybelow\|ladybelowTriple\|boomsweep\|bilgeblow) = [{]$` | 4 |
| B11 | phases rewritten to 5 act bands (was 3) | `^\t\t\{ below = \|^\t\t\tbelow = ` | 5 |
| B12 | new `wrack_duel` row | `^Bosses.items.wrack_duel = [{]$` | 1 |
| B13 | duel is not summonable — **row-scoped since 2026-09-12**, see the note below | row-scoped `^\tsummonable = false,$` | 1 |
| B14 | duel banks its heart as the ship | `^\theartAs = "admiral_wrack",$` | 1 |
| B15 | duel arena keeps the wreck's guns | `^\twreckMounts = [{]$` | 1 |
| B16 | duel's six attack rows | `^\t\t(sabrelunge\|cleave\|cleaveDouble\|flintlock\|ripostestance\|lastbroadside) = [{]$` | 6 |
| B17 | `byIsland` builder skips successors | `^\tif boss\.summonable ~= false then$` | 1 |

B8, B10, B11 and B16 are **row-scoped**: `sed -n '/^Bosses.items.<id> = [{]/,/^}/p'`
first, then grep. (In a `sed` address `\{` opens an interval — use `[{]`.)

Attack-row count, executed: **HEAD 11 → worktree 15**
(`grapeshot broadside broadsideHeavy anchorsweep wisps powderrun powderrunTwin
ghostbraziers cannonoverload anchorline longboat` **+ `ladybelow ladybelowTriple
boomsweep bilgeblow`**).

> **B13 was scoped to the row on 2026-09-12, and it was reporting a FAIL on
> correct code.** The check was file-wide (`ck`) against `^\tsummonable = false,$`
> and wanted exactly 1. The Pyrelisk unit's `pyrelisk_heart` row carries the same
> field (its own PB16), so the count became **2** and this landmark failed for a
> reason that has nothing to do with the Wrack — while `wrack_duel`'s own field
> was present and correct the whole time. Now `row`-scoped to
> `Bosses.items.wrack_duel`, like B8/B9 beside it. Found by running §4 after an
> unrelated pass; **no code was touched.** A standing false FAIL in a durable
> audit is how the next real one goes unread — the same lesson the Pyrelisk
> record's BAS1 note records, on the same day.

### `src/Shared/Data/Creatures.luau` — 5 hunks, 6 landmarks

| ID | Hunk | Landmark | Count |
|----|------|----------|-------|
| C1 | new `wrack_admiral` row (the man) | `^Creatures.items.wrack_admiral = [{]$` | 1 |
| C2 | new `wrack_figurehead` row | `^Creatures.items.wrack_figurehead = [{]$` | 1 |
| C3 | new `wrack_boom_tackle` row | `^Creatures.items.wrack_boom_tackle = [{]$` | 1 |
| C4 | `wrack_battery` retune (4.5 → **4.0**) | row-scoped `^\tshotRadius = 4\.0,$` | 1 |
| C5a | `admiral_wrack` hp 58000 → **24000** | row-scoped `^\thealth = 24000,$` | 1 |
| C5b | `admiral_wrack` **rewards/drops removed** | row-scoped `^\t(rewards\|drops) = ` | **0** |

C5b is load-bearing and is **not** a deletion to "restore": the ship no longer
pays out, because `suppressDrops` (V1) routes the payout to `wrack_duel`. Putting
`rewards`/`drops` back double-pays the fight.

`wrack_battery` is also renamed **"Gun-Deck Battery" → "Flagship Cannon"** and
hp 2800 → 3600 in the same hunk.

### `src/Shared/Data/CreatureFamilies.luau` — untracked (audio lane's file)

| ID | Hunk | Landmark | Count |
|----|------|----------|-------|
| F1 | `wrack_admiral` sounds like a man | `^\twrack_admiral = "undead",$` | 1 |
| F2 | `wrack_figurehead` | `^\twrack_figurehead = "mechanical",$` | 1 |
| F3 | `wrack_boom_tackle` | `^\twrack_boom_tackle = "mechanical",$` | 1 |
| F4 | `admiral_wrack` (the ship) | `^\tadmiral_wrack = "leviathan",$` | 1 |

**This whole file is untracked and belongs to the audio lane.** The Wrack unit
does not own it and must not `git add` it — but the unit **cannot go green
without F1–F3**, because `check_content` §9 is two-directional (§3).

### `src/Server/Services/CreatureService.luau` — 21 hunks, 25 landmarks

| ID | Hunk | Landmark | Count |
|----|------|----------|-------|
| S1 | 13 new attack handlers | `^K\.ATTACK_HANDLERS\.(powderrun\|ghostbraziers\|cannonoverload\|anchorline\|longboat\|ladybelow\|boomsweep\|bilgeblow\|sabrelunge\|cleave\|ripostestance\|flintlock\|lastbroadside) = [{]$` | 13 |
| S2 | the 4 that existed at HEAD, K-renamed | `^K\.ATTACK_HANDLERS\.(grapeshot\|broadside\|wisps\|anchorsweep) = [{]$` | 4 |
| S3 | `Fn.wrack*` helper set (HEAD had 13 as `local function`) | `^function Fn\.wrack` | 34 |
| S4 | act-two stepper | `^function Fn\.wrackActStep\(` | 1 |
| S5 | kit stepper | `^function Fn\.wrackKitStep\(` | 1 |
| S6 | occluder build | `^function Fn\.wrackOccluder\(` | 1 |
| S7 | occluder teardown | `^function Fn\.wrackOccluderDrop\(` | 1 |
| S8 | duel riposte | `^function Fn\.wrackRiposte\(` | 1 |
| S9 | duel cleave beat | `^function Fn\.wrackCleaveBeat\(` | 1 |
| S10 | `rigging` reader + mesh fallback | `^function Fn\.wrackRigging\(` | 1 |
| S11 | hull repair | `^function Fn\.wrackRepair\(` | 1 |
| S12 | Lady-Below dive stepper | `^function Fn\.wrackLadyStep\(` | 1 |
| S13 | boom sweep stepper | `^function Fn\.wrackBoomStep\(` | 1 |
| S14 | hatch publish | `^function Fn\.wrackHatchPublish\(` | 1 |
| S15 | act-aware phase fraction | `^function Fn\.bossPhaseFraction\(` | 1 |
| S16 | …and its only call site | `Fn\.bossPhaseAttacks\(def, Fn\.bossPhaseFraction\(creature\)\)` | 1 |
| S17 | kit dispatch | `^\t\t\tFn\.wrackKitStep\(creature, now, dt\)$` | 1 |
| S18 | act dispatch, guarded on `succeededBy` | `^\t\t\t\tFn\.wrackActStep\(creature, actDef, now\)$` | 1 |
| S19 | occluder dispatch | `^\t\t\tFn\.wrackOccluder\(creature, def\)$` | 1 |
| S20 | occluder drop dispatch | `^\t\t\tFn\.wrackOccluderDrop\(creature\)$` | 1 |
| S21 | riposte dispatch | `^\t\tFn\.wrackRiposte\(creature, os\.clock\(\)\)$` | 1 |
| S22 | wreck branch, gated on the data it CONSUMES (see §5a) | `^\tif def and def\.succeededBy and def\.wreckFor and creature\.mode and creature\.mode ~= "rising" then$` | 1 |
| S22z | …and the old `succeededBy`-only gate is **GONE** | `^\tif def and def\.succeededBy and creature\.mode and creature\.mode ~= "rising" then$` | **0** |
| S23 | `holdExpose` window (act two's earned opening) | `^\tif a\.p\.expose and a\.p\.holdExpose then$` | 1 |
| S24 | **ring-regrow nil guard** (see §5) | `^[[:space:]]*and def\.parts\.regrow$` | 1 |

**Naming note that will trip the next reader:** HEAD calls the registry
`local ATTACK_HANDLERS` and the helpers `local function wrack*`. The worktree
calls them `K.ATTACK_HANDLERS` and `Fn.wrack*` — that is the **200-local
register-limit consolidation**, not a Wrack change. A HEAD-vs-worktree grep
under either name alone reports 0 and looks like total loss. It is not.
One helper, `wrackAim`, is *deliberately* still a bare `local function`
(65 references); it did not move to `Fn`.

**`wrackAim` aside:** do not "fix" it into `Fn.` — that is a new top-level local
budget question, and the two hot files are at the limit.

### `src/Server/Services/BossService.luau` — 5 hunks, 5 landmarks

| ID | Hunk | Landmark | Count |
|----|------|----------|-------|
| V1 | `suppressDrops` in the raise payload | `^\t\tsuppressDrops = boss\.succeededBy ~= nil,$` | 1 |
| V2 | `bossHere` skips non-summonable rows | `^\t\tif boss\.summonable ~= false and onIsland\(player, boss\.islandId\) then$` | 1 |
| V3 | `handoff()` — the act-three pivot | `^local function handoff\(boss, fight, at: Vector3\?, healthMult: number\?\)$` | 1 |
| V4 | `handoff()` call from the `onKilled` early branch | `^\t\t\thandoff\($` | 1 |
| V5 | heart banked under `heartAs` | `^\t\tlocal heartId = boss\.heartAs or boss\.id$` | 1 |

All five are **additive** — no HEAD line is deleted, which is why they look
harmless alone and are not (§3).

### `tools/check_content.py` — **no uncommitted Wrack hunk**

The Wrack cross-file gate (`wrack_battery.shotRadius` in Luau vs the number in
`WrackBodyController`) **is already committed**, at `b2f472c`. The file's
*current* uncommitted diff is the **audio lane's §9 families gate**, not ours.
The older record listed "check_content.py (1)" for the Wrack unit; that hunk has
since landed. Nothing here for this unit to carry — but see §3, the gate still
constrains us.

---

## 2. By-name row-set baseline: HEAD vs worktree

Produced by the brace-aware walker in §4, comparing against
`git show HEAD:<path>`. **REMOVED must always be empty** — it is the tripwire for
a reconstruct-commit that quietly drops a row.

### `Bosses.items` — HEAD **7** → worktree **8**

| Class | Rows | Lane (by content) |
|-------|------|-------------------|
| **NEW** | `wrack_duel` | **Wrack** |
| **REMOVED** | *(none)* | ✅ empty |
| **CHANGED** | `admiral_wrack` | **Wrack** — act bands, `rigging`, `acts`, `succeededBy`, `wreckFor`, `regrow` deleted, mounts retargeted to the four corners, 11 → 15 attacks |
| | `brinejaw` | starter-cove combo pass (`combo` block, phase merge) — **not ours** |
| | `kraken` | kraken lane |
| | `noctyss` | noctyss lane |
| | `pyrelisk` | pyrelisk lane |
| | `rimefang` | rimefang lane |

### `Creatures.items` — HEAD **120** → worktree **129**

| Class | Rows | Lane (by content) |
|-------|------|-------------------|
| **NEW** | `wrack_admiral`, `wrack_figurehead`, `wrack_boom_tackle` | **Wrack** (all `waters = "wreck"`) |
| | `kraken_antibody`, `kraken_arm`, `kraken_polyp` | kraken lane (`waters = "maelstrom"`) |
| | `pyrelisk_arm`, `pyrelisk_neckcore`, `pyrelisk_ventrock` | pyrelisk lane (`waters = "volcano"`) |
| **REMOVED** | *(none)* | ✅ empty |
| **CHANGED** | `admiral_wrack` | **Wrack** — hp 58000 → 24000, `rewards`/`drops` removed |
| | `wrack_battery` | **Wrack** — renamed "Flagship Cannon", hp 2800 → 3600, `shotRadius` 4.5 → **4.0** |
| | `choir_stalk` | noctyss lane (gloom; hp 2600 → 1900, scale 0.55 → 0.846) |
| | `kraken`, `noctyss`, `pyrelisk` | their own lanes |
| | `old_ribbonjaw`, `tollmaw` | **island-population swap, not the fight.** These two trade islands: `old_ribbonjaw` ice → **wreck** (hp 3800 → 14000), `tollmaw` wreck → **ice** (hp 14000 → 3800). It *touches* wreck content, so it reads like ours — it is not. It rides its own commit. |

### `CreatureFamilies.luau`

Untracked in full, so every row is "new" against HEAD and a set-diff is
meaningless. The unit's stake is exactly the four rows F1–F4 (§1), all present.
Comparison is by membership, not by diff: **129 worktree creature ids, and the
gate requires a family for each.**

---

## 3. The dependency statement — **one unit, or none**

No subset of this work is green. Each link below was checked against the current
worktree, not assumed.

1. **Bosses hunks → the four new attack rows → the worktree CS handlers.**
   `ladybelow`, `ladybelowTriple`, `boomsweep`, `bilgeblow` name handlers
   (`handler = "…"`) that exist **only** in the worktree `CreatureService`
   (S1). Commit `Bosses` without `CreatureService` and the rows resolve to
   nothing.
   **This failure already exists at HEAD and proves the point:** HEAD's
   `admiral_wrack` names five handlers — `powderrun`, `ghostbraziers`,
   `cannonoverload`, `anchorline`, `longboat` — that **HEAD does not define**
   (HEAD defines only `grapeshot`, `broadside`, `wisps`, `anchorsweep`). Those
   five are inert in HEAD right now. An attack with no handler does not error;
   it silently does nothing. All five arrive in S1.
2. **`Creatures.wrack_admiral` → `Bosses.wrack_duel`, via `check_content`.**
   `wrack_duel.creature = "wrack_admiral"`. The gate resolves every boss row's
   `creature` against `Creatures.items`. Ship `Bosses` without `Creatures` and
   the gate fails loudly (this one is the *good* case — it is caught).
3. **`CreatureFamilies` rows ↔ `Creatures` rows — two-directional gate.**
   `check_content` §9 fails if a creature id has **no** family *and* if a family
   row names an id that doesn't exist. So `wrack_admiral` /
   `wrack_figurehead` / `wrack_boom_tackle` must land **together with** F1–F3,
   in either order but never apart. The file belongs to the audio lane —
   coordinate, don't stage it.
4. **`BossService` sits on top of the party-scaling set and the cutscene lane's
   intro hooks.** `handoff()` (V3) is called from the `onKilled` early branch
   (V4) and takes `healthMult` — the party-scaling parameter. V1/V2/V5 are
   purely additive and pass every gate on their own **while paying the duel's
   rewards to nobody**: without `wrack_duel` present, `suppressDrops` fires on a
   boss with no successor and the fight pays out **zero**.
5. **The ship's `rewards`/`drops` deletion (C5b) is only correct with V1 + B12.**
   Any two of those three, without the third, is a silently unpaid boss.

> Every link in this chain has the same shape — **the value exists somewhere
> nothing reads it**, and it presents as a milder, different problem: an empty
> act, a boss that pays nothing, a cannon that never fires. Not a crash. That is
> why the rule is *one unit or none*, and why the check is a landmark count
> rather than "did it build".

**Gate reminder:** `selene` / `check_compile` / `check_content` / `rojo build`
**cannot see any of this**, and neither can they see the 200-local limit —
`luau-compile -O0` (gate five) is the only check that does. All five gates
passing on a partial commit means nothing here.

---

## 4. Inline re-run script

Save anywhere (it `cd`s to the repo root itself) and run. It is read-only.
Expected output: **52 OK lines and `ALL LANDMARKS PRESENT`**, exit 0.

```sh
#!/bin/sh
# Wrack fight unit audit. Run from the repo root. Every landmark must print OK.
cd "$(git rev-parse --show-toplevel)" || exit 1
B=src/Shared/Data/Bosses.luau
C=src/Shared/Data/Creatures.luau
F=src/Shared/Data/CreatureFamilies.luau
S=src/Server/Services/CreatureService.luau
V=src/Server/Services/BossService.luau
fail=0
ck() { # ck <want> <label> <file> <pattern>
  got=$(grep -cE "$4" "$3" 2>/dev/null); got=${got:-0}
  if [ "$got" = "$1" ]; then printf 'OK   %-46s %s\n' "$2" "$got"
  else printf 'FAIL %-46s want %s got %s\n' "$2" "$1" "$got"; fail=1; fi
}
row() { # row <want> <label> <file> <rowstart> <pattern>
  got=$(sed -n "/$4/,/^}/p" "$3" | grep -cE "$5"); got=${got:-0}
  if [ "$got" = "$1" ]; then printf 'OK   %-46s %s\n' "$2" "$got"
  else printf 'FAIL %-46s want %s got %s\n' "$2" "$1" "$got"; fail=1; fi
}
echo "--- Bosses.luau (10 hunks) ---"
ck 1 "B1  Boss type: succeededBy field"        $B '^	succeededBy: string\?,$'
ck 1 "B2  Boss type: heartAs field"            $B '^	heartAs: string\?,$'
ck 1 "B3  Boss type: summonable field"         $B '^	summonable: boolean\?,$'
ck 1 "B4  admiral_wrack rigging slot"          $B '^	rigging = \{$'
ck 1 "B5  admiral_wrack acts band"             $B '^	acts = \{$'
ck 1 "B6  admiral_wrack succeededBy"           $B '^	succeededBy = "wrack_duel",$'
ck 1 "B7  admiral_wrack wreckFor"              $B '^	wreckFor = 2\.5,$'
row 0 "B8  admiral_wrack regrow DELETED"       $B '^Bosses.items.admiral_wrack = [{]' '^		regrow = '
row 1 "B9  admiral_wrack regrow tombstone"     $B '^Bosses.items.admiral_wrack = [{]' 'regrow. IS DELETED'
row 4 "B10 admiral_wrack 4 new attack rows"    $B '^Bosses.items.admiral_wrack = [{]' '^		(ladybelow|ladybelowTriple|boomsweep|bilgeblow) = \{$'
row 5 "B11 admiral_wrack 5 act bands"          $B '^Bosses.items.admiral_wrack = [{]' '^		\{ below = |^			below = '
ck 1 "B12 wrack_duel row"                      $B '^Bosses.items.wrack_duel = \{$'
row 1 "B13 wrack_duel summonable=false"        $B '^Bosses.items.wrack_duel = [{]' '^	summonable = false,$'
ck 1 "B14 wrack_duel heartAs"                  $B '^	heartAs = "admiral_wrack",$'
ck 1 "B15 wrack_duel wreckMounts"              $B '^	wreckMounts = \{$'
row 6 "B16 wrack_duel 6 duel attack rows"      $B '^Bosses.items.wrack_duel = [{]' '^		(sabrelunge|cleave|cleaveDouble|flintlock|ripostestance|lastbroadside) = \{$'
ck 1 "B17 byIsland summonable guard"           $B '^	if boss\.summonable ~= false then$'
echo "--- Creatures.luau (5 hunks) ---"
ck 1 "C1  wrack_admiral row"                   $C '^Creatures.items.wrack_admiral = \{$'
ck 1 "C2  wrack_figurehead row"                $C '^Creatures.items.wrack_figurehead = \{$'
ck 1 "C3  wrack_boom_tackle row"               $C '^Creatures.items.wrack_boom_tackle = \{$'
row 1 "C4  wrack_battery shotRadius 4.0"       $C '^Creatures.items.wrack_battery = [{]' '^	shotRadius = 4\.0,$'
row 1 "C5a admiral_wrack health 24000"         $C '^Creatures.items.admiral_wrack = [{]' '^	health = 24000,$'
row 0 "C5b admiral_wrack rewards/drops gone"   $C '^Creatures.items.admiral_wrack = [{]' '^	(rewards|drops) = '
echo "--- CreatureFamilies.luau (untracked) ---"
ck 1 "F1  wrack_admiral = undead"              $F '^	wrack_admiral = "undead",$'
ck 1 "F2  wrack_figurehead = mechanical"       $F '^	wrack_figurehead = "mechanical",$'
ck 1 "F3  wrack_boom_tackle = mechanical"      $F '^	wrack_boom_tackle = "mechanical",$'
ck 1 "F4  admiral_wrack = leviathan"           $F '^	admiral_wrack = "leviathan",$'
echo "--- CreatureService.luau (20 hunks) ---"
ck 13 "S1  13 new K.ATTACK_HANDLERS"           $S '^K\.ATTACK_HANDLERS\.(powderrun|ghostbraziers|cannonoverload|anchorline|longboat|ladybelow|boomsweep|bilgeblow|sabrelunge|cleave|ripostestance|flintlock|lastbroadside) = \{$'
ck  4 "S2  4 pre-existing handlers (K-renamed)" $S '^K\.ATTACK_HANDLERS\.(grapeshot|broadside|wisps|anchorsweep) = \{$'
ck 34 "S3  Fn.wrack* definitions"              $S '^function Fn\.wrack'
ck  1 "S4  Fn.wrackActStep def"                $S '^function Fn\.wrackActStep\('
ck  1 "S5  Fn.wrackKitStep def"                $S '^function Fn\.wrackKitStep\('
ck  1 "S6  Fn.wrackOccluder def"               $S '^function Fn\.wrackOccluder\('
ck  1 "S7  Fn.wrackOccluderDrop def"           $S '^function Fn\.wrackOccluderDrop\('
ck  1 "S8  Fn.wrackRiposte def"                $S '^function Fn\.wrackRiposte\('
ck  1 "S9  Fn.wrackCleaveBeat def"             $S '^function Fn\.wrackCleaveBeat\('
ck  1 "S10 Fn.wrackRigging def"                $S '^function Fn\.wrackRigging\('
ck  1 "S11 Fn.wrackRepair def"                 $S '^function Fn\.wrackRepair\('
ck  1 "S12 Fn.wrackLadyStep def"               $S '^function Fn\.wrackLadyStep\('
ck  1 "S13 Fn.wrackBoomStep def"               $S '^function Fn\.wrackBoomStep\('
ck  1 "S14 Fn.wrackHatchPublish def"           $S '^function Fn\.wrackHatchPublish\('
ck  1 "S15 Fn.bossPhaseFraction def"           $S '^function Fn\.bossPhaseFraction\('
ck  1 "S16 bossPhaseFraction call site"        $S 'Fn\.bossPhaseAttacks\(def, Fn\.bossPhaseFraction\(creature\)\)'
ck  1 "S17 wrackKitStep dispatch"              $S '^			Fn\.wrackKitStep\(creature, now, dt\)$'
ck  1 "S18 wrackActStep dispatch"              $S '^				Fn\.wrackActStep\(creature, actDef, now\)$'
ck  1 "S19 wrackOccluder dispatch"             $S '^			Fn\.wrackOccluder\(creature, def\)$'
ck  1 "S20 wrackOccluderDrop dispatch"         $S '^			Fn\.wrackOccluderDrop\(creature\)$'
ck  1 "S21 wrackRiposte dispatch"              $S '^		Fn\.wrackRiposte\(creature, os\.clock\(\)\)$'
ck  1 "S22 wreck branch: succeededBy+wreckFor" $S '^	if def and def\.succeededBy and def\.wreckFor and creature\.mode and creature\.mode ~= "rising" then$'
ck  0 "S22z old succeededBy-only gate GONE"    $S '^	if def and def\.succeededBy and creature\.mode and creature\.mode ~= "rising" then$'
ck  1 "S23 holdExpose window"                  $S '^	if a\.p\.expose and a\.p\.holdExpose then$'
ck  1 "S24 ring-regrow nil guard (2026-09-12)" $S '^[[:space:]]*and def\.parts\.regrow$'
echo "--- BossService.luau (5 hunks) ---"
ck 1 "V1  suppressDrops in raise"              $V '^		suppressDrops = boss\.succeededBy ~= nil,$'
ck 1 "V2  summonable skip in bossHere"         $V '^		if boss\.summonable ~= false and onIsland\(player, boss\.islandId\) then$'
ck 1 "V3  handoff() definition"                $V '^local function handoff\(boss, fight, at: Vector3\?, healthMult: number\?\)$'
ck 1 "V4  handoff() call in onKilled"          $V '^			handoff\($'
ck 1 "V5  heartAs in heart award"              $V '^		local heartId = boss\.heartAs or boss\.id$'
echo
if [ $fail = 0 ]; then echo "ALL LANDMARKS PRESENT"; else echo "*** MISSING WRACK HUNKS - SEE FAIL LINES ABOVE ***"; fi
exit $fail
```

Two portability notes, both learned by the script failing on them here:

- In a `sed` **address**, `\{` opens an interval and errors with
  "braces not balanced" — match the Luau `{` as `[{]`.
- `grep -c` **exits 1 when the count is 0**, so `$(grep -c … || echo 0)` yields
  the string `"0\n0"` and every *expected-zero* landmark (B8, C5b) reports a
  false FAIL. The script uses plain substitution instead. A false FAIL on a
  deletion check is exactly the kind of noise that gets an audit ignored.

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

---

## 5a. Entry: the wreck branch's gate (landed 2026-09-12, worktree-only)

*The second entry of this shape, from the same neighbouring lane, for the same
structural reason: a Wrack-region hunk in a shared file, found by a lane that
does not own it, which must be on the committing lane's checklist or it is on
nobody's. Landmark **S22 / S22z**, executed.*

**The gate was `def and def.succeededBy and creature.mode and creature.mode ~=
"rising"`, and `succeededBy` is not what this branch is for.** It means "this
boss has a successor", not "this boss is a ship that wrecks" — and the Pyrelisk
has one (`succeededBy = "pyrelisk_heart"`, for the handoff to the heart). So the
**Pyrelisk took the Admiral's branch**: `creature.wrecking` set,
`ATTR.WRACK_WRECK` published on a rig that does not read it, the hold sized by
`wreckFor` (absent → 2.5) rather than its own `collapseFor` (4.0) — and
`Fn.updateBossCollapse` then returned at its `if creature.wrecking` test
**before** the `poseKind == "pyrelisk"` branch.

**What it cost, and none of it was visible.** No collapse pose; **no
`PyreliskCaldera`, no `PyreliskShaftFloor`, no shaft watch, and nobody ever
moved into the heart's chamber.** The heart was raised into a room the party had
no route to. Every landmark in the Pyrelisk unit's caldera/shaft slice was
present and correct — the code they point at was simply never reached.

**The fix, and why it is not `not def.pose`.** The branch now reads
`def.succeededBy and def.wreckFor`. Everything inside it is Wrack-specific —
`ATTR.WRACK_WRECK`, `creature.wrackKit`, and the `def.wreckFor` hold itself — and
`wreckFor` exists on exactly **one** row (`Bosses.items.admiral_wrack`). A boss
therefore opts **into** wrecking by carrying the number that sizes it, which is
the right shape for a gate. `not def.pose` would also have worked and is worse:
a branch that tests for the *absence of an unrelated field* is one rename away
from being wrong again. `Fn.updateBossCollapse`'s `creature.wrecking` early
return is left as a flag and **annotated with why**: that field has exactly one
writer (this branch) and one clearer, so it says precisely "this branch opened
this collapse" — re-deriving it from `def` there would recreate the same class
of bug, a gate and a body disagreeing about which fall this is.

**Verified by execution, both fights, both ways** (trace at
`…/scratchpad/pyrelisk-phases/cut-act3/trace/`, run against the **live**
`Bosses.luau` rows):

| | gate | result |
|---|---|---|
| `admiral_wrack` | FIXED | WRECK branch, hold **2.5 s**, early return — **byte-identical behaviour**, then `kill()` → BossService raises `wrack_duel` |
| `pyrelisk` | FIXED | PERCH/COLLAPSE branch, hold **4.0 s**, `poseKind == "pyrelisk"` branch RUNS → caldera at 2.5 s → shaft watch → `kill()` → the heart |
| `admiral_wrack` | REVERTED (control) | WRECK branch, 2.5 s — unchanged, as it must be |
| `pyrelisk` | REVERTED (control) | WRECK branch, 2.5 s, early return — **the caldera write is unreachable**, which is the bug reproduced |

`wreckFor` appears on one row and `succeededBy` on two, so the fix changes the
behaviour of exactly one boss: the Pyrelisk. **The Admiral's path is untouched
in logic; only comments were added around it.**

## 5. Entry: the ring-regrow nil guard (landed 2026-09-12, worktree-only)

*Folded in from the one surviving fragment of the purged record — a note the
pyrelisk runtime lane wrote into its own scratchpad because the path it was told
to append to no longer existed. It was right that a checklist entry living where
the committing lane never looks is not a checklist entry. That is why this file
is in `docs/`.*

**Why the Wrack unit owns it.** `admiral_wrack`'s `parts` block has had its
`regrow` **deliberately deleted** (B8) — the absence *is* the act boundary, so
nothing resets the gun-deck count and the fourth kill opens act three forever.
The generic ring-regrow clock in `Fn.updateBoss` did not allow for that: it
compared `now - creature.partsDownAt >= def.parts.regrow` with nothing checking
the field exists.

**What it did.** Not "the ring fails to regrow" — a comparison against `nil`,
which is a Luau error raised out of the boss's own update, **every frame, from
the moment the last gun deck falls**. That is the whole of act three.

**Why nobody hit it.** The Pyrelisk also has a `regrow`-less `parts` block, but
its entrenched branch returns unconditionally further up and never reaches the
line. The boss that has the deleted `regrow` *and* passes through this guard is
the Admiral, alone.

**The fix**, in place, one clause:

```lua
	if
		def.parts
		and def.parts.regrow
		and creature.partsAlive == 0
		and creature.partsDownAt
		and now - creature.partsDownAt >= def.parts.regrow
	then
```

`nil` means **never**, not *immediately* — hence the extra `and` rather than
`or math.huge`, which would read as a number and behave as a sentence.

**Landmark** — S24, executed, **1 hit**:

```sh
grep -cE '^[[:space:]]*and def\.parts\.regrow$' src/Server/Services/CreatureService.luau
```

Three lines in the file contain `def.parts.regrow`; the `$` anchor selects only
the guard. The other two are `Fn.updateChoir`'s
`((def.parts and def.parts.regrow) or 5)` and the explanatory comment above the
guard (which ends in a backtick, so `$` excludes it).

**Commit-time note.** This hunk is in `CreatureService.luau` — long-lived
uncommitted and shared across lanes. It is **not** part of the Pyrelisk unit and
is independent of every Pyrelisk hunk in that file. It rides whichever commit
lands the Wrack act work, or a standalone fix commit. **It is counted in the 20
CreatureService hunks above.**

**Gates when it landed:** `selene src` 0/0/0 · `check_compile` OK (152 files) ·
`check_content` OK · `rojo build` OK.

---

## 6. Commit-time procedure

Per the shared-checkout rules — 7 live sessions, explicit paths only, `&&` not
`;`, never `--amend`:

1. Run §4. Require **`ALL LANDMARKS PRESENT`**, exit 0.
2. Re-run §2 and confirm **REMOVED is empty** for both tables.
3. Run gate five, `luau-compile -O0`, on both hot files — the other four gates
   cannot see the 200-local limit, and this unit adds to `CreatureService`.
4. Confirm with the audio lane before `CreatureFamilies.luau` is staged by
   **anyone**; it is their untracked file and three of our rows are in it (§3.3).
5. Stage **by explicit path only** — never `-A`, never `.`, never `-a`:

   ```sh
   git add src/Server/Services/CreatureService.luau \
           src/Server/Services/BossService.luau \
           src/Shared/Data/Bosses.luau \
           src/Shared/Data/Creatures.luau \
           docs/wrack-fight-handoff.md
   ```

   (`src/Shared/Data/CreatureFamilies.luau` is added **only** by whoever owns it,
   in this same commit or an immediately adjacent one — see §3.3.)
6. **Before committing**, diff the staged symbol set against the worktree symbol
   set for the two hot files. The failure this catches is a reconstruct-commit
   that silently drops other lanes' hunks from a shared file.
7. Commit. Do not amend afterwards.
